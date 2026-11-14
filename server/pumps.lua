--[[
    Server side of the pumps: take a nozzle off a pump, put it in a car, pay at the pump for what goes in.
    Every side of every pump has its own nozzle (shared/pumps.lua names them), kept here only while out of its holster.

    Where a nozzle is (`state`):
      'hand'    in a player's hand (`holder`)
      'car'     in a car's filler (`car`)
      'ground'  on the ground (`objNetId`); goes back after Config.Pump.GroundSeconds. Starting the pump with it here
                sprays fuel (the spill)
      'torn'    in a car whose pump was torn off its island (server/hose.lua), till unplugged
      'dead'    on the ground after that; gone after Config.Pump.TornMinutes, then the island has its pump back

    Taking a nozzle is free. The payer chooses cash or bank at the fill and pays all of it (HoldMoney); what goes in
    is spent (SpendMoneyHold) and the rest comes back (SettleMoneyHold). Every game is told about every busy side
    (whip_fuel:face); the holder is told what is in their hand (whip_fuel:hand).

    Server events other resources can hear (`pump` = { x, y, z, model, at, heading }):
      whip_fuel:nozzleTaken { source, key, pump }
      whip_fuel:nozzleInserted { source, key, pump, vehicleNetId, nozzleNetId, hoseOffset? }
      whip_fuel:nozzleRemoved { source, key, pump }
      whip_fuel:nozzleDropped { key, nozzleNetId, dead? }
      whip_fuel:nozzlePickedUp { source, key, pump }
      whip_fuel:nozzleTorn { key, pump, nozzleNetId, other? }   `other`: the pump's other side { key, state, holder? }
      whip_fuel:nozzleReturned { key, reason, pump }
      whip_fuel:pumpBack { prefix }                             a torn pump is back on its island
]]

Fuel = Fuel or {}

--- [key] = { key, pump = { x, y, z, model, at, heading }, state, holder?, car?, objNetId?, since, touched, pour? }
local nozzles = {}

--- [source] = the key of the nozzle in their hand
local hands = {}

--- [key] = GetGameTimer() that side works again: out of order after a spill (Config.Pump.ErrorSeconds)
local errorUntil = {}

--- [pump prefix] = true while that pump is torn off its island: neither side works till it is back
local pumpGone = {}

--- [pump prefix] = { p = dollars, u = percent of a tank }: each pump's last sale, shown on the classic pumps' drums.
local lastSale = {}

--- Every pour gets a number, and its tick thread stops when its nozzle's pour is no longer its own, so a fill stopped
--- and restarted never runs two threads into one tank.
local pourToken = 0

--- The nozzle in the hand, for everyone: a held prop (whip_core's HoldProps).
--- Attached to PH_R_Hand (28422) rather than SKEL_R_Hand: PH_ bones are prop attachment points, so the offset only nudges.
local NOZZLE_PROP = {
    model  = 'prop_cs_fuel_nozle',
    bone   = 28422,
    offset = { x = 0.13, y = 0.05, z = 0.02 },
    rot    = { x = -80.0, y = 0.0, z = 15.0 },
}

--- A nozzle held on a torn pump is let go after this at the latest (whip_rope's drag lets go long before).
local TORN_HAND_MS = 30000

local function groundMs()  return (tonumber(Config.Pump.GroundSeconds) or 30) * 1000 end
local function idleMs()    return (tonumber(Config.Pump.IdleMinutes) or 5) * 60000 end
local function tornMs()    return (tonumber(Config.Pump.TornMinutes) or 5) * 60000 end
local function sprayS()    return math.max(1, tonumber(Config.Pump.SpraySeconds) or 10) end
local function errorMs()   return (tonumber(Config.Pump.ErrorSeconds) or 60) * 1000 end
local function leash()     return Config.Pump.Leash or 5.0 end
local function pumpReach() return (Config.Pump.Reach or 3.0) + 2.0 end
local function carReach()  return (Config.Pump.CarReach or 5.0) + 1.0 end
--- Percent of a tank a second: a full tank in Config.Pump.FullSeconds
local function rate()      return 100 / math.max(1, tonumber(Config.Pump.FullSeconds) or 120) end
--- The rate is a fraction (100/120), so its sums come out a hair short: without this a full tank took a 121st tick
local POUR_EPS = 1e-6
local function perUnit()   return math.max(0, math.floor(tonumber(Config.Pump.Price) or 1)) end

--- Is player `src` within `range` of a point? Off their ped, here.
local function near(src, x, y, z, range)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return #(GetEntityCoords(ped) - vector3(x + 0.0, y + 0.0, z + 0.0)) <= range
end

local function notify(src, text, kind, ms)
    exports.whip_core:NotifyPlayer(src, text, kind or 'info', ms)
end

-- Pricing

--- What it costs to fill a tank at `level` right now.
--- Counted in whole percent so the charge and the change are exact integers: a tank at 47.3% is billed for 53.
---@return number units, number price, number perUnit
local function quoteFor(level)
    local units = math.max(0, math.ceil(100 - level))
    local each = perUnit()
    return units, units * each, each
end

--- How many whole percent a choice at the pump pours: the tank's worth ('full'), or 25 / 50 / 75 percent of the
--- tank added, never more than it takes.
local function unitsFor(amount, need)
    if amount == 'full' then return need end
    return math.min(need, math.ceil(100 * (tonumber(amount) or 0) / 100))
end

--- What the spill costs (Config.Pump.SpraySeconds of fuel at the pump's speed): its units and price.
local function sprayCost()
    local units = math.ceil(rate() * sprayS())
    local each = perUnit()
    return units, units * each, each
end

-- The car

--- whip's id for this car as whip_core's index confirms it (GetVehicle { entity = }), or nil for a street car whip has
--- never taken on. Never the raw whipVehicleId stamp, which could charge another car's record.
local function vehicleIdOf(entity)
    local ok, v = pcall(function() return exports.whip_core:GetVehicle({ entity = entity }) end)
    return ok and type(v) == 'table' and tonumber(v.vehicleId) or nil
end
Fuel.vehicleIdOf = vehicleIdOf

--- Turn the network id the client sent into a car to charge for. The client sends only a network id; every number the
--- transaction depends on is read here.
---@param lookOnly boolean|nil  a price check: a street car whip has never seen is not taken on
---@param pump table|nil  the nozzle's pump: the car's reach from the pump counts (the hose)
---@return number|nil entity, number|nil vehicleId, string|nil why
local function resolveTarget(src, netId, lookOnly, pump)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil, nil, 'That vehicle is gone' end
    if GetEntityType(entity) ~= 2 then return nil, nil, 'That is not a vehicle' end

    -- A metre of slack on top of the range the client may aim from, so a fill is not refused because the car
    -- rolled slightly while the request was in flight.
    local vc = GetEntityCoords(entity)
    if pump then
        if #(vc - vector3(pump.x, pump.y, pump.z)) > leash() + 1.0 then
            return nil, nil, 'The hose does not reach that far'
        end
    elseif not near(src, vc.x, vc.y, vc.z, carReach()) then
        return nil, nil, 'Too far from that vehicle'
    end

    local vehicleId = vehicleIdOf(entity)
    if vehicleId or lookOnly then return entity, vehicleId, nil end

    -- Taken on at the pump (its tank has somewhere to keep its fuel), counted against the player's street cars
    local adopted, why = exports.whip_core:AdoptVehicle({ entity = entity, player = src })
    if not adopted then return nil, nil, why or 'Cannot refuel that' end
    return entity, adopted, nil
end

-- What every game is told

--- A hash as one unsigned number, so the server's and GetHashKey's spellings compare (the nozzle's is past 2^31:
--- GetEntityModel and GetHashKey give it with different signs).
local function uhash(h) return (math.tointeger(h) or 0) & 0xFFFFFFFF end

--- The nozzle's model, to know the object a player's game put in a car is a nozzle.
local NOZZLE_HASH = uhash(GetHashKey(NOZZLE_PROP.model))

--- What every game is told about a side: nil when its nozzle is in its holster and it works.
---   n     where its nozzle is ('hand', 'car', 'ground', 'torn', 'dead'), nil in its holster
---   h     the holder, while 'hand'
---   car   the car's network id, while 'car' / 'torn'
---   obj   the nozzle's network id on the ground, while 'ground' / 'dead'
---   p     a pour running: { e = seconds in, s = seconds it takes, u = percent of a tank paid for, c = $ a percent,
---         spray = true for the spill }
---   sp    what starting the spill costs now, while its nozzle is in a hand or on the ground
---   err   seconds it stays out of order
---   gone  its pump is torn off its island
local function faceInfo(key)
    local n = nozzles[key]
    local untilMs = errorUntil[key]
    local errLeft = untilMs and math.ceil((untilMs - GetGameTimer()) / 1000) or 0
    local gone = pumpGone[Pumps.prefixOf(key)] == true
    if not n and errLeft <= 0 and not gone then return nil end
    local info = { err = errLeft > 0 and errLeft or nil, gone = gone or nil }
    if n then
        info.n = n.state
        info.h = n.holder
        info.car = n.car and n.car.netId or nil
        info.obj = n.objNetId
        local pour = n.pour
        if pour then
            info.p = { e = (GetGameTimer() - pour.startedMs) / 1000, s = pour.seconds, u = pour.unitsPaid,
                       c = pour.pricePerUnit, spray = pour.spray or nil }
        elseif n.state == 'hand' or n.state == 'ground' then
            local _, price = sprayCost()
            info.sp = price
        end
    end
    return info
end

--- Every game told what this side is now.
local function faceSync(key)
    TriggerClientEvent('whip_fuel:face', -1, key, faceInfo(key))
end

--- The player told what is in their hand: a nozzle's key and its pump's point (their game's walk-away leash), or
--- nothing.
local function tellHand(src, key)
    local n = key and nozzles[key]
    TriggerClientEvent('whip_fuel:hand', src, n and key or nil, n and { x = n.pump.x, y = n.pump.y, z = n.pump.z } or nil)
end

-- The nozzle's objects

--- The networked object a client just made, once the server has heard of it: the call naming it can arrive a moment
--- before the object does.
local function awaitEntity(netId, ms)
    local deadline = GetGameTimer() + ms
    while true do
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end
        if GetGameTimer() > deadline then return nil end
        Wait(50)
    end
end

--- A nozzle object by its network id, when it still is one (an id is used again once its entity is gone).
local function nozzleObject(netId)
    local obj = netId and NetworkGetEntityFromNetworkId(netId)
    if obj and obj ~= 0 and DoesEntityExist(obj) and uhash(GetEntityModel(obj)) == NOZZLE_HASH then return obj end
    return nil
end

local function deleteNozzleObject(netId)
    local obj = nozzleObject(netId)
    if obj then DeleteEntity(obj) end
end
Fuel.deleteNozzleObject = deleteNozzleObject

--- Is this network id a nozzle's here (in a car, on the ground)? Then no client's word moves or deletes it.
local function isRecorded(netId)
    for _, n in pairs(nozzles) do
        if n.objNetId == netId or (n.car and n.car.objNetId == netId) then return true end
    end
    return false
end

--- The entity a client named as one its own game just made (a nozzle dropped, unplugged, put in a car): only when
--- that game made it (NetworkGetFirstEntityOwner) and no nozzle here is it. A client names its own, never another's.
local function madeBy(src, netId)
    local obj = netId and netId > 0 and NetworkGetEntityFromNetworkId(netId)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    if NetworkGetFirstEntityOwner(obj) ~= src or isRecorded(netId) then return nil end
    return obj
end

--- A nozzle a client's game made that the server is not keeping: deleted. Anything else it names is left alone.
local function deleteMadeBy(src, netId)
    local obj = madeBy(src, netId)
    if obj and uhash(GetEntityModel(obj)) == NOZZLE_HASH then DeleteEntity(obj) end
end

--- A networked, loose nozzle lying at `at` (a vector3), made here.
---@return number|nil netId
local function makeGroundNozzle(at)
    local obj = CreateObjectNoOffset(GetHashKey(NOZZLE_PROP.model), at.x, at.y, at.z, true, true, false)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    FreezeEntityPosition(obj, false)
    return NetworkGetNetworkIdFromEntity(obj)
end

-- Settle: the only place a pour ends

--- What a pour has used so far, in money: rounded up to whole dollars, never more than was paid.
local function spentOf(pour)
    local paid = pour.unitsPaid * pour.pricePerUnit
    return math.min(paid, math.ceil(pour.unitsGiven * pour.pricePerUnit - 1e-9))
end

--- Why a fill stopped by itself, said before its sums.
local WHY = {
    moved   = 'The car moved away. ',
    gone    = 'The car is gone. ',
    wrecked = 'The car is wrecked. ',
}

--- End the pour running on this nozzle: what did not go in comes back and the payer is told. Safe when nothing is
--- pouring. A spill that ends puts its side out of order.
---@param reason string  'done' | 'stopped' | 'moved' | 'gone' | 'wrecked' | 'torn' | 'returned' | 'disconnected'
function Fuel.settle(key, reason)
    local nozzle = nozzles[key]
    local pour = nozzle and nozzle.pour
    if not pour then return end
    nozzle.pour = nil
    nozzle.touched = GetGameTimer()

    local paid = pour.unitsPaid * pour.pricePerUnit
    local res = pour.holdId and exports.whip_core:SettleMoneyHold(pour.holdId, spentOf(pour))
    -- false: whip_core settled it already (the payer left, or it stopped), and said so itself
    if type(res) == 'table' and reason ~= 'disconnected' and GetPlayerPed(pour.payer) ~= 0 then
        local refund = tonumber(res.refunded) or 0
        local delivered = math.floor(pour.unitsGiven + 0.5)
        if pour.spray then
            -- What went out, against what was paid: the spent part and any change, so the sums are on screen. A fill
            -- whose nozzle was pulled out mid-fill says what went in before it spilled.
            local text = ('Fuel spilled: %d%% of a tank, $%d of the $%d paid'):format(delivered, paid - refund, paid)
            if pour.filled then
                local filled = math.floor(pour.filled + 0.5)
                text = ('Filled +%d%%, then %d%% spilled: $%d of the $%d paid'):format(filled,
                    math.max(0, delivered - filled), paid - refund, paid)
            end
            if refund > 0 then
                text = text .. (res.paidNow and (' — $%d back'):format(refund)
                    or (' — your $%d change comes back next time you join'):format(refund))
            end
            notify(pour.payer, text, 'error')
        elseif refund > 0 and res.paidNow then
            notify(pour.payer, (WHY[reason] or '') .. ('Stopped at +%d%% — $%d refunded'):format(delivered, refund), 'success')
        elseif refund > 0 then
            notify(pour.payer, (WHY[reason] or '') .. ('Stopped at +%d%% — your $%d change comes back next time you join')
                :format(delivered, refund), 'success')
        else
            notify(pour.payer, ('Filled +%d%% for $%d'):format(delivered, paid), 'success')
        end
    end

    if pour.spray then errorUntil[key] = GetGameTimer() + errorMs() end
    faceSync(key)
    -- The pump's last sale, what went out of it, for every game's drums (client/dials.lua). After the face: a game
    -- that heard the sale while the pour still showed would roll its drums down for a new one.
    local prefix = Pumps.prefixOf(key)
    lastSale[prefix] = { p = spentOf(pour), u = math.floor(pour.unitsGiven * 10 + 0.5) / 10 }
    TriggerClientEvent('whip_fuel:sale', -1, prefix, lastSale[prefix])
end

--- A fill still pumping when its nozzle comes out of the car keeps pumping as a spill till someone stops it at the
--- pump or what was paid for runs out. Its holder cannot put it away or into a car meanwhile.
local function spill(key)
    local nozzle = nozzles[key]
    local pour = nozzle and nozzle.pour
    if not pour or pour.spray then return end
    pour.spray, pour.filled = true, pour.unitsGiven
    faceSync(key)
end

-- Moving a nozzle: back, to a hand, to the ground

--- The nozzle back in its holster: its pour settled, its objects gone, its holder's hand empty.
---@param reason string  'put away' | 'ground' (untouched) | 'idle' (a car, untouched) | 'gone' | 'pulled' |
---                      'expired' (a torn pump's, its time up) | 'logout' | 'torn' (the other side of a torn pump) |
---                      'destroyed' | 'world' (its holder moved to another world)
function Fuel.returnNozzle(key, reason)
    local nozzle = nozzles[key]
    if not nozzle then return end
    Fuel.settle(key, reason == 'logout' and 'disconnected' or 'returned')
    nozzles[key] = nil
    if nozzle.holder then
        if hands[nozzle.holder] == key then hands[nozzle.holder] = nil end
        exports.whip_core:DropHeldProps(nozzle.holder, 'nozzle')
        if reason ~= 'logout' then tellHand(nozzle.holder, nil) end
    end
    if nozzle.car then deleteNozzleObject(nozzle.car.objNetId) end
    if nozzle.objNetId then deleteNozzleObject(nozzle.objNetId) end
    faceSync(key)
    TriggerEvent('whip_fuel:nozzleReturned', { key = key, reason = reason, pump = nozzle.pump })
    -- A torn pump whose last nozzle this was: back on its island
    local prefix, other = Pumps.prefixOf(key), Pumps.otherSide(key)
    if pumpGone[prefix] and not nozzles[other] then
        pumpGone[prefix] = nil
        faceSync(key)
        faceSync(other)
        TriggerEvent('whip_fuel:pumpBack', { prefix = prefix })
    end
end

--- Into `src`'s hand (empty), from wherever it was.
local function toHand(key, src)
    local nozzle = nozzles[key]
    nozzle.state, nozzle.holder, nozzle.car, nozzle.objNetId = 'hand', src, nil, nil
    nozzle.since = GetGameTimer()
    hands[src] = key
    exports.whip_core:HoldProps(src, { NOZZLE_PROP }, 'nozzle')   -- in their hand, for everyone
    tellHand(src, key)
    faceSync(key)
end

--- Out of its holder's hand onto the ground where they stand (dropped, walked off with, died with).
--- `madeNetId`: the nozzle their game made where the hand was (it falls at once); kept if valid, else the server makes one.
local function handToGround(key, madeNetId)
    local nozzle = nozzles[key]
    local src = nozzle and nozzle.holder
    if not nozzle or nozzle.state ~= 'hand' then return end
    local ped = src and GetPlayerPed(src)
    local at = ped and ped ~= 0 and GetEntityCoords(ped) or vector3(nozzle.pump.x, nozzle.pump.y, nozzle.pump.z)
    local netId = nil
    if madeNetId and awaitEntity(madeNetId, 1000) then
        local obj = madeBy(src, madeNetId)
        if obj and uhash(GetEntityModel(obj)) == NOZZLE_HASH and #(GetEntityCoords(obj) - at) < 4.0 then
            netId = madeNetId
        else
            deleteMadeBy(src, madeNetId)
        end
    end
    -- Read again after the wait: picked up or gone back meanwhile
    if nozzles[key] ~= nozzle or nozzle.state ~= 'hand' then
        if netId then deleteNozzleObject(netId) end
        return
    end
    netId = netId or makeGroundNozzle(vector3(at.x, at.y, at.z + 0.3))
    if not netId then return Fuel.returnNozzle(key, 'ground') end
    hands[src] = nil
    exports.whip_core:DropHeldProps(src, 'nozzle')
    tellHand(src, nil)
    -- Let go behind a torn pump (dragged along by it): nobody's now, gone with the pump (Config.Pump.TornMinutes)
    local dead = pumpGone[Pumps.prefixOf(key)] == true
    nozzle.state, nozzle.holder, nozzle.objNetId, nozzle.since = dead and 'dead' or 'ground', nil, netId, GetGameTimer()
    faceSync(key)
    TriggerEvent('whip_fuel:nozzleDropped', { key = key, nozzleNetId = netId, dead = dead or nil })
end

--- The nozzle in this car, if one is (in it, or a torn pump's).
local function nozzleInCar(netId)
    for key, n in pairs(nozzles) do
        if n.car and n.car.netId == netId and (n.state == 'car' or n.state == 'torn') then return key, n end
    end
    return nil
end

--- The key of the nozzle in `src`'s hand, or nil (a jerry can is not filled with a nozzle in hand).
function Fuel.handOf(src) return hands[src] end

--- Every nozzle out of its holster now: { key, state, holder?, car?, objNetId?, pump } (the hose drawn again for each
--- when whip_rope starts).
function Fuel.nozzlesOut()
    local out = {}
    for key, n in pairs(nozzles) do
        out[#out + 1] = { key = key, state = n.state, holder = n.holder, car = n.car, objNetId = n.objNetId, pump = n.pump }
    end
    return out
end

-- Pour: one tick per second

--- The pour ended by whip_core (its money settled already: the payer left, whip_core stopping): nothing to settle.
local function lostPour(key)
    local nozzle = nozzles[key]
    if not nozzle or not nozzle.pour then return end
    local spray = nozzle.pour.spray
    nozzle.pour = nil
    nozzle.touched = GetGameTimer()
    if spray then errorUntil[key] = GetGameTimer() + errorMs() end
    faceSync(key)
end

local function runPour(key, token)
    while true do
        Wait(1000)

        local nozzle = nozzles[key]
        local pour = nozzle and nozzle.pour
        if not pour or pour.token ~= token then return end

        if pour.spray then
            -- Spraying, in a hand or on the floor (dropped or picked up, it carries on; into a car, it stops)
            if nozzle.state ~= 'ground' and nozzle.state ~= 'hand' then return Fuel.settle(key, 'stopped') end
            pour.unitsGiven = pour.unitsGiven + math.min(rate(), pour.unitsPaid - pour.unitsGiven)
            if not exports.whip_core:SpendMoneyHold(pour.holdId, spentOf(pour)) then return lostPour(key) end
            if pour.unitsGiven >= pour.unitsPaid - POUR_EPS then return Fuel.settle(key, 'done') end
        else
            -- Still in that car
            if nozzle.state ~= 'car' or not nozzle.car or nozzle.car.netId ~= pour.netId then
                return Fuel.settle(key, 'stopped')
            end
            local entity = NetworkGetEntityFromNetworkId(pour.netId)
            if not entity or entity == 0 or not DoesEntityExist(entity) then return Fuel.settle(key, 'gone') end
            -- Still the car being filled: the pour finds the car by netId and fills it by vehicleId, and a car garaged
            -- mid-pour leaves its netId free for another (a different entity: its handle is another).
            if entity ~= pour.entity then return Fuel.settle(key, 'gone') end
            -- Blown up or sunk: nothing more goes into it
            if exports.whip_core:IsVehicleWrecked(pour.vehicleId) then return Fuel.settle(key, 'wrecked') end

            -- The car may move only Config.Pump.CarMayRoll from where it stood when the fill began.
            local carAt = GetEntityCoords(entity)
            if #(carAt - pour.startAt) > (tonumber(Config.Pump.CarMayRoll) or 1.5) then
                return Fuel.settle(key, 'moved')
            end

            -- One tick's worth, never more than is left to deliver. The tank is read fresh each tick, since an engine
            -- or a jerry can also change it. The money hold is checked first: fuel put in after the payer left would
            -- be unpaid.
            if not exports.whip_core:GetMoneyHold(pour.holdId) then return lostPour(key) end
            local step = math.min(rate(), pour.unitsPaid - pour.unitsGiven)
            local current = TankOf(pour.vehicleId)
            local target = math.min(100.0, current + step)
            pour.unitsGiven = pour.unitsGiven + step

            -- The ordinary stat setter: it clamps, replicates, saves and tells its listeners (an empty tank's engine
            -- let go, server/tank.lua)
            exports.whip_core:SetVehicleStat(pour.vehicleId, 'fuel', target, 'refuel:pump')
            if not exports.whip_core:SpendMoneyHold(pour.holdId, spentOf(pour)) then return lostPour(key) end

            if target >= 100.0 - POUR_EPS or pour.unitsGiven >= pour.unitsPaid - POUR_EPS then
                return Fuel.settle(key, 'done')
            end
        end
    end
end

-- Asked by the player's game
-- Each answers true or `false, why`; a success with several values is one table read by name.

--- A face key the client named: a real one's shape, and busy now. Nil and why otherwise.
local function nozzleNamed(key)
    if type(key) ~= 'string' or not key:match(Pumps.KEY_PATTERN) then return nil, 'No such pump' end
    local n = nozzles[key]
    if not n then return nil, 'That nozzle is on its pump' end
    return n
end

--- Is `src` at this nozzle's pump?
local function atPump(src, nozzle)
    local p = nozzle.pump
    return near(src, p.x, p.y, p.z, pumpReach())
end

--- Take a side's nozzle off its pump. Free: whoever fills with it pays at the pump.
--- The server keeps no list of pumps (the client finds them by model), so the pump point is the client's word; every
--- money check still runs here.
local function takeNozzle(src, _, side, x, y, z, model, ex, ey, ez, eh)
    if hands[src] then return false, 'You are already holding a nozzle' end
    if model == 0 or #(vector3(ex, ey, ez) - vector3(x, y, z)) >= 3.0 then return false, 'No pump there' end

    local at = { x = ex, y = ey, z = ez }
    local key = Pumps.keyOf(at, side)
    if pumpGone[Pumps.prefixOf(key)] then return false, 'This pump is gone' end
    if errorUntil[key] then return false, 'This pump is out of order' end
    local busy = nozzles[key]
    if busy then
        return false, busy.state == 'ground' and 'Its nozzle is on the ground' or 'That nozzle is in use'
    end

    nozzles[key] = {
        key = key,
        -- The point taken at; .model, .at and .heading the pump itself (the hose ties to it)
        pump = { x = x, y = y, z = z, model = model, at = at, heading = eh },
        since = GetGameTimer(), touched = GetGameTimer(),
    }
    toHand(key, src)
    TriggerEvent('whip_fuel:nozzleTaken', { source = src, key = key, pump = nozzles[key].pump })
    return true
end

--- The nozzle in the hand back on its pump (the client offers it at its own side only).
local function nozzleAway(src)
    local key = hands[src]
    local nozzle = key and nozzles[key]
    if not nozzle then return end
    if not atPump(src, nozzle) then return false, 'Too far from its pump' end
    if nozzle.pour then return false, 'Stop the pump first' end
    Fuel.returnNozzle(key, 'put away')
end

--- The holder's game says they dropped it, walked further than the hose reaches, or died: the nozzle goes on the
--- ground (`netId`: the one their game made, 0 for none). The clock below catches a game that never says.
local function dropNozzle(src, _, netId)
    local key = hands[src]
    if key then
        handToGround(key, netId > 0 and netId or nil)
    elseif netId > 0 then
        deleteMadeBy(src, netId)   -- only one their own game made
    end
end

-- The nozzle left the hand without its holder or this file asking (whip_core:heldProps:lost):
--   'replaced'  something else was put in the hand: it goes on the ground where they stand
--   'world'     they were moved to another world: back on its pump
AddEventHandler('whip_core:heldProps:lost', function(e)
    if type(e) ~= 'table' or e.tag ~= GetCurrentResourceName() .. ':nozzle' then return end
    local key = hands[tonumber(e.source) or -1]
    if not key then return end
    if e.reason == 'world' then Fuel.returnNozzle(key, 'world') else handToGround(key, nil) end
end)

--- "Insert Nozzle" at the car's filler (client/car.lua): the player's game makes the nozzle there, tied to the car,
--- and the hand is empty for another. Then at the pump: how much and how to pay (start).
local function insertNozzle(src, _, netId, nozzleNetId, ox, oy, oz)
    local key = hands[src]
    local nozzle = key and nozzles[key]
    if not nozzle then return false, 'You are not holding a nozzle' end
    if nozzle.pour then return false, 'Stop the pump first' end
    -- A torn pump or an out-of-order side does nothing (as at take): its nozzle only goes back
    if pumpGone[Pumps.prefixOf(key)] then return false, 'This pump is gone' end
    if errorUntil[key] then return false, 'This pump is out of order' end
    if nozzleInCar(netId) then return false, 'There is a nozzle in that car already' end
    local p = nozzle.pump
    if not near(src, p.x, p.y, p.z, leash() + 2.0) then return false, 'The hose does not reach that far' end

    local entity, _, why = resolveTarget(src, netId, true)
    if not entity then return false, why or 'Cannot refuel that' end
    local obj = awaitEntity(nozzleNetId, 1500) and madeBy(src, nozzleNetId)   -- the one their game just made
    if not obj or uhash(GetEntityModel(obj)) ~= NOZZLE_HASH
        or not DoesEntityExist(entity) or #(GetEntityCoords(obj) - GetEntityCoords(entity)) > 6.0 then
        return false, 'The nozzle did not go in'
    end
    -- Read again after the wait: the nozzle can have gone back or gone in elsewhere meanwhile.
    if hands[src] ~= key or nozzles[key] ~= nozzle or nozzleInCar(netId) then return false, 'The nozzle did not go in' end

    -- The back of the nozzle in the car's own space, from its game (the server's copy of the car can lag). Within the
    -- car's reach, or none.
    local hoseOffset = nil
    if #vector3(ox, oy, oz) > 0.01 and #vector3(ox, oy, oz) <= 15.0 then hoseOffset = { x = ox, y = oy, z = oz } end

    hands[src] = nil
    exports.whip_core:DropHeldProps(src, 'nozzle')
    tellHand(src, nil)
    nozzle.state, nozzle.holder = 'car', nil
    nozzle.car = { netId = netId, objNetId = nozzleNetId, hoseOffset = hoseOffset }
    nozzle.since, nozzle.touched = GetGameTimer(), GetGameTimer()
    faceSync(key)
    TriggerEvent('whip_fuel:nozzleInserted', {
        source = src, key = key, pump = nozzle.pump, vehicleNetId = netId, nozzleNetId = nozzleNetId,
        hoseOffset = hoseOffset,
    })
    return true
end

--- The nozzle out of this car: into the hand (whatever is pouring stops first), or, a torn pump's, onto the ground
--- for good (`made`: the one the player's game made there for it, 0: none).
local function removeNozzle(src, _, netId, made)
    local key, nozzle = nozzleInCar(netId)
    if not nozzle then
        deleteMadeBy(src, made)
        return false, 'There is no nozzle in that car'
    end
    if hands[src] then return false, 'Your hands are full' end
    local entity = NetworkGetEntityFromNetworkId(netId)
    local carAt = entity and entity ~= 0 and DoesEntityExist(entity) and GetEntityCoords(entity) or nil
    if carAt and not near(src, carAt.x, carAt.y, carAt.z, carReach()) then
        deleteMadeBy(src, made)
        return false, 'Too far from that vehicle'
    end

    if nozzle.state == 'torn' then
        -- A torn pump's: unplugged, it lies by the car, nobody's, till the pump is back (Config.Pump.TornMinutes)
        local obj = nozzleObject(nozzle.car.objNetId)
        local at = obj and GetEntityCoords(obj) or carAt or vector3(nozzle.pump.x, nozzle.pump.y, nozzle.pump.z)
        local mine = made > 0 and awaitEntity(made, 1000) and madeBy(src, made)
        if mine and (uhash(GetEntityModel(mine)) ~= NOZZLE_HASH or #(GetEntityCoords(mine) - at) > 4.0) then
            deleteMadeBy(src, made)
            mine = nil
        end
        if nozzle.state ~= 'torn' then
            if mine then DeleteEntity(mine) end
            return false, 'The nozzle is not in that car now'
        end
        deleteNozzleObject(nozzle.car.objNetId)
        nozzle.state, nozzle.car, nozzle.since = 'dead', nil, GetGameTimer()
        nozzle.objNetId = mine and made or makeGroundNozzle(vector3(at.x, at.y, at.z + 0.2))
        faceSync(key)
        TriggerEvent('whip_fuel:nozzleDropped', { key = key, nozzleNetId = nozzle.objNetId, dead = true })
        return true
    end

    deleteMadeBy(src, made)   -- (only a torn pump's is unplugged onto the ground)
    -- Pulled out while it still pumps: it goes on pumping, out of the nozzle in their hand, everywhere (spill)
    local pumping = nozzle.pour ~= nil and not nozzle.pour.spray
    if not pumping then Fuel.settle(key, 'stopped') end
    deleteNozzleObject(nozzle.car.objNetId)
    toHand(key, src)
    if pumping then
        spill(key)
        notify(src, 'It is still pumping — stop it at the pump', 'error')
    end
    TriggerEvent('whip_fuel:nozzleRemoved', { source = src, key = key, pump = nozzle.pump })
    return true
end

--- A nozzle on the ground picked up (not a torn pump's).
local function pickUp(src, _, key)
    local nozzle, why = nozzleNamed(key)
    if not nozzle then return false, why end
    if nozzle.state ~= 'ground' then return false, nozzle.state == 'dead' and 'It is no use now' or 'It is not on the ground' end
    if hands[src] then return false, 'Your hands are full' end
    local obj = nozzleObject(nozzle.objNetId)
    local at = obj and GetEntityCoords(obj)
    if not at or not near(src, at.x, at.y, at.z, 3.0) then return false, 'Too far away' end
    -- (A spill carries on in the hand: catch it if you can)
    deleteNozzleObject(nozzle.objNetId)
    toHand(key, src)
    TriggerEvent('whip_fuel:nozzlePickedUp', { source = src, key = key, pump = nozzle.pump })
    return true
end

--- Price the car a nozzle is in, for the pump's amounts ("Fill Up  $50"). False and why for anything the player
--- could not fill.
local function quote(src, _, netId)
    local _, nozzle = nozzleInCar(netId)
    if not nozzle or nozzle.state ~= 'car' then return false, 'There is no nozzle in that car' end
    if not atPump(src, nozzle) then
        local entity = NetworkGetEntityFromNetworkId(netId)
        local c = entity and entity ~= 0 and DoesEntityExist(entity) and GetEntityCoords(entity)
        if not c or not near(src, c.x, c.y, c.z, carReach() + 2.0) then return false, 'Too far away' end
    end
    -- Look only: taking a car on (a record, a trunk, a pinned entity) to show a price would be waste. That waits for
    -- the fill itself (start). Its reach is from the pump: the hose.
    local entity, vehicleId, why = resolveTarget(src, netId, true, nozzle.pump)
    if not entity then return false, why or 'Cannot refuel that' end
    local units, price, each = quoteFor(TankOf(vehicleId))
    return { units = units, price = price, perUnit = each, tank = 100 }
end

--- Start filling the car this side's nozzle is in, by the amount chosen, paid now by `payment`; Fuel.settle gives
--- back what did not go in. Whoever starts it pays.
local function startFill(src, _, key, amount, payment)
    local nozzle, why = nozzleNamed(key)
    if not nozzle then return false, why end
    if not atPump(src, nozzle) then return false, 'Too far from the pump' end
    if nozzle.state ~= 'car' then return false, 'Put the nozzle in a car first' end
    if nozzle.pour or nozzle.starting then return false, 'Already refuelling' end
    if pumpGone[Pumps.prefixOf(key)] then return false, 'This pump is gone' end
    if errorUntil[key] then return false, 'This pump is out of order' end
    local netId = nozzle.car.netId

    -- Held from here to the pour: finding the car and taking the money both wait, and a second start in that gap
    -- must not charge again.
    nozzle.starting = true
    local function refuse(text) nozzle.starting = nil return false, text end

    -- A full tank (where every street car starts) is answered before the car is taken on
    local seen, seenId, seenWhy = resolveTarget(src, netId, true, nozzle.pump)
    if not seen then return refuse(seenWhy or 'Cannot refuel that') end
    if quoteFor(TankOf(seenId)) <= 0 then return refuse('That tank is already full') end

    local entity, vehicleId, err = resolveTarget(src, netId, false, nozzle.pump)
    if not entity then return refuse(err or 'Cannot refuel that') end
    ---@cast vehicleId -nil -- not a look: a car found is taken on
    if exports.whip_core:IsVehicleWrecked(vehicleId) then return refuse('That car is wrecked') end

    local need, _, each = quoteFor(TankOf(vehicleId))
    if need <= 0 then return refuse('That tank is already full') end
    local units = unitsFor(amount, need)
    local price = units * each

    -- All of it, now; the car's row held unwritten till the end, so fuel given and not yet paid for is never saved
    local holdId, payErr = exports.whip_core:HoldMoney(src, price, { method = payment, reason = 'Fuel', vehicle = vehicleId })
    nozzle.starting = nil
    if not holdId then return false, payErr or 'Payment failed' end

    -- The nozzle may have come out of the car (or gone back) while the payment was being taken: all of it back.
    if nozzles[key] ~= nozzle or nozzle.state ~= 'car' or not nozzle.car or nozzle.car.netId ~= netId then
        exports.whip_core:SettleMoneyHold(holdId, 0)
        return false, 'The nozzle is not in that car now'
    end

    pourToken = pourToken + 1
    local token = pourToken
    nozzle.pour = {
        payer        = src,
        holdId       = holdId,
        vehicleId    = vehicleId,
        netId        = netId,
        entity       = entity,  -- the car itself: another under its netId later is not it (runPour)
        unitsPaid    = units,   -- paid for; settle gives back what did not go in
        unitsGiven   = 0,
        pricePerUnit = each,
        token        = token,
        startAt      = GetEntityCoords(entity),   -- where the car stood, for runPour's "it moved away"
        startedMs    = GetGameTimer(),
        seconds      = math.ceil(units / rate() - POUR_EPS),
    }
    nozzle.touched = GetGameTimer()
    faceSync(key)
    CreateThread(function() runPour(key, token) end)
    return { seconds = nozzle.pour.seconds, price = price }
end

--- The spill: with this side's nozzle on the ground or in a hand, "Start Refuelling" sprays fuel out of it, paid like a
--- fill (Config.Pump.SpraySeconds of it), till stopped or run out; then the side is out of order.
local function startSpray(src, _, key, payment)
    local nozzle, why = nozzleNamed(key)
    if not nozzle then return false, why end
    if not atPump(src, nozzle) then return false, 'Too far from the pump' end
    local function loose() return nozzle.state == 'ground' or nozzle.state == 'hand' end
    if not loose() then return false, 'Its nozzle is in a car' end
    if nozzle.pour or nozzle.starting then return false, 'Already running' end
    if pumpGone[Pumps.prefixOf(key)] then return false, 'This pump is gone' end
    if errorUntil[key] then return false, 'This pump is out of order' end

    local units, price, each = sprayCost()
    nozzle.starting = true
    local holdId, payErr = exports.whip_core:HoldMoney(src, price, { method = payment, reason = 'Fuel' })
    nozzle.starting = nil
    if not holdId then return false, payErr or 'Payment failed' end
    if nozzles[key] ~= nozzle or not loose() then
        exports.whip_core:SettleMoneyHold(holdId, 0)
        return false, 'Its nozzle is in a car now'
    end

    pourToken = pourToken + 1
    local token = pourToken
    nozzle.pour = {
        spray = true, payer = src, holdId = holdId,
        unitsPaid = units, unitsGiven = 0, pricePerUnit = each, token = token,
        startedMs = GetGameTimer(), seconds = sprayS(),
    }
    nozzle.touched = GetGameTimer()
    faceSync(key)
    CreateThread(function() runPour(key, token) end)
    return { seconds = sprayS(), price = price }
end

--- "Stop Refuelling" at the pump: anyone there may stop it (the change goes to whoever paid).
local function stopFill(src, _, key)
    local nozzle = nozzleNamed(key)
    if not nozzle or not nozzle.pour then return end
    if not atPump(src, nozzle) then return false, 'Too far from the pump' end
    Fuel.settle(key, 'stopped')
end

--- Every busy side now: a game that has just loaded a character missed the changes before it.
local function faces()
    local out, seen = {}, {}
    for key in pairs(nozzles) do seen[key] = true end
    for key in pairs(errorUntil) do seen[key] = true end
    for prefix in pairs(pumpGone) do seen[prefix .. '_A'], seen[prefix .. '_B'] = true, true end
    for key in pairs(seen) do
        local info = faceInfo(key)
        if info then out[key] = info end
    end
    return out
end

local CAR_ID = { 'netId', 'id', 1, 4294967295 }
local KEY = { 'key', 'string', 64 }
local PAYMENT = { 'payment', 'enum', { 'cash', 'bank' } }

Whip.register(function()
    local secure = exports.whip_core
    -- These two are what the pumps' screens show, read at a character's load: not actions, so a character that
    -- loads dead is answered too (whileDead), or its pumps stay blank all session.
    secure:SecureCallback('whip_fuel:faces', { rateLimit = 2000, whileDead = true }, faces)
    -- Every pump's last sale, at a character's load (the ones after it come as whip_fuel:sale)
    secure:SecureCallback('whip_fuel:sales', { rateLimit = 2000, whileDead = true }, function() return lastSale end)
    secure:SecureCallback('whip_fuel:takeNozzle', {
        rateLimit = 750,
        params = {
            { 'side', 'enum', { 'A', 'B' } },
            { 'x', 'number', -20000.0, 20000.0 },
            { 'y', 'number', -20000.0, 20000.0 },
            { 'z', 'number',  -2000.0,  2000.0 },
            -- The pump itself, for the hose (a map prop: the client's word, kept only when beside the point above)
            { 'model', 'number', -2147483648, 4294967295, 0 },
            { 'ex', 'number', -20000.0, 20000.0, 0.0 },
            { 'ey', 'number', -20000.0, 20000.0, 0.0 },
            { 'ez', 'number',  -2000.0,  2000.0, 0.0 },
            { 'eh', 'number', -720.0, 720.0, 0.0 },
        },
        near = {
            at    = function(_, _, _, x, y, z) return x, y, z end,
            range = function() return pumpReach() end,   -- asked at each take: a change in /whip reaches it
        },
    }, takeNozzle)
    secure:SecureEvent('whip_fuel:nozzleAway', { rateLimit = 250, burst = 3, whileDead = true }, nozzleAway)
    secure:SecureEvent('whip_fuel:drop', {
        rateLimit = 500, burst = 2, whileDead = true,
        params = { { 'netId', 'int', 0, 4294967295, 0 } },
    }, dropNozzle)
    secure:SecureCallback('whip_fuel:insert', {
        rateLimit = 750,
        params = {
            CAR_ID, { 'nozzleNetId', 'id', 1, 4294967295 },
            -- The nozzle's back, where the hose goes in, in the car's own space (insertNozzle keeps it within 15 m)
            { 'ox', 'number', -50.0, 50.0, 0.0 },
            { 'oy', 'number', -50.0, 50.0, 0.0 },
            { 'oz', 'number', -50.0, 50.0, 0.0 },
        },
    }, insertNozzle)
    secure:SecureCallback('whip_fuel:remove', {
        rateLimit = 750, whileDead = true,
        params = { CAR_ID, { 'made', 'int', 0, 4294967295, 0 } },
    }, removeNozzle)
    secure:SecureCallback('whip_fuel:pickUp', { rateLimit = 750, params = { KEY } }, pickUp)
    secure:SecureCallback('whip_fuel:quote', { rateLimit = 250, burst = 4, params = { CAR_ID } }, quote)
    secure:SecureCallback('whip_fuel:start', {
        rateLimit = 1000,
        params = { KEY, { 'amount', 'enum', { 'full', '25', '50', '75' }, 'full' }, PAYMENT },
    }, startFill)
    secure:SecureCallback('whip_fuel:spray', { rateLimit = 1000, params = { KEY, PAYMENT } }, startSpray)
    secure:SecureEvent('whip_fuel:stop', { rateLimit = 250, burst = 3, whileDead = true, params = { KEY } }, stopFill)
end)

-- The hose's say (server/hose.lua)

--- Is a hose drawn (hoseDrawn), and does this nozzle have one (hasHose), so dealing with a car that drives off with it
--- in? Without one, the car simply pulls the nozzle out (the clock below). server/hose.lua answers.
Fuel.hoseDrawn = Fuel.hoseDrawn or function() return false end
Fuel.hasHose = Fuel.hasHose or function() return false end

--- A car tore the pump off its island with this nozzle in it: the pour ends (paid for what went in) and the nozzle
--- stays in the car, the pump on its hose, till unplugged. The pump's other side:
---   in another car    stays in it, its fill ended ('torn' as well)
---   in a hand         stays there, whip_rope drags its holder along (Config.Drag); when they let go it lies 'dead'
---   anywhere else     goes back
function Fuel.pumpTorn(key)
    local nozzle = type(key) == 'string' and nozzles[key]
    if not nozzle or nozzle.state ~= 'car' then return false end
    Fuel.settle(key, 'torn')
    local now = GetGameTimer()
    local other = Pumps.otherSide(key)
    local o, stays = nozzles[other], nil
    if o and o.state == 'car' then
        Fuel.settle(other, 'torn')
        o.state, o.since = 'torn', now
        stays = { key = other, state = 'car' }
    elseif o and o.state == 'hand' then
        Fuel.settle(other, 'torn')   -- a spill in the hand stops: no pump to pour from
        o.since = now                -- (held on a torn pump since: the clock's backstop)
        stays = { key = other, state = 'hand', holder = o.holder }
    elseif o then
        Fuel.returnNozzle(other, 'torn')
    end
    pumpGone[Pumps.prefixOf(key)] = true
    nozzle.state, nozzle.since = 'torn', now
    faceSync(key)
    faceSync(other)
    TriggerEvent('whip_fuel:nozzleTorn', { key = key, pump = nozzle.pump, nozzleNetId = nozzle.car.objNetId, other = stays })
    return true
end

--- A car drove off with this nozzle in it from a pump that does not come away (Config.Hose.TornModels): the hose
--- breaks off at the car, the fill ends, and the nozzle drops where it was (anyone's to pick up).
function Fuel.breakaway(key)
    local nozzle = type(key) == 'string' and nozzles[key]
    if not nozzle or nozzle.state ~= 'car' then return false end
    -- Still pumping: it goes on, out of the nozzle on the ground, thrashing (spill, below)
    local pumping = nozzle.pour ~= nil and not nozzle.pour.spray
    if not pumping then Fuel.settle(key, 'torn') end
    local obj = nozzleObject(nozzle.car.objNetId)
    local car = NetworkGetEntityFromNetworkId(nozzle.car.netId)
    local at = obj and GetEntityCoords(obj)
        or (car and car ~= 0 and DoesEntityExist(car) and GetEntityCoords(car))
        or vector3(nozzle.pump.x, nozzle.pump.y, nozzle.pump.z)
    deleteNozzleObject(nozzle.car.objNetId)
    local netId = makeGroundNozzle(vector3(at.x, at.y, at.z + 0.2))
    if not netId then return Fuel.returnNozzle(key, 'pulled') end
    nozzle.state, nozzle.car, nozzle.objNetId, nozzle.since = 'ground', nil, netId, GetGameTimer()
    faceSync(key)
    if pumping then spill(key) end
    TriggerEvent('whip_fuel:nozzleDropped', { key = key, nozzleNetId = netId })
    return true
end

--- This nozzle's pump was blown up where it stands: no hose holds to it, so both its sides' nozzles go back, and a
--- car with one in is free. (A torn-off pump's are left to their own clock.)
function Fuel.pumpDestroyed(key)
    if type(key) ~= 'string' or not key:match(Pumps.KEY_PATTERN) then return false end
    local prefix = Pumps.prefixOf(key)
    for _, side in ipairs({ '_A', '_B' }) do
        local n = nozzles[prefix .. side]
        if n and n.state ~= 'torn' and n.state ~= 'dead' then Fuel.returnNozzle(prefix .. side, 'destroyed') end
    end
    return true
end

-- The clock: nozzles left about

CreateThread(function()
    while true do
        Wait(500)
        local now = GetGameTimer()
        local back, toGround = {}, {}
        for key, n in pairs(nozzles) do
            if n.state == 'hand' then
                -- The holder gone, or walked off further than the hose reaches. On a torn pump the leash means
                -- nothing (whip_rope drags them); held longer than TORN_HAND_MS, it is let go here.
                local p = n.pump
                local ped = GetPlayerPed(n.holder)
                if not ped or ped == 0 then
                    back[#back + 1] = { key, 'logout' }
                elseif pumpGone[Pumps.prefixOf(key)] then
                    if now - n.since > TORN_HAND_MS then toGround[#toGround + 1] = key end
                elseif not near(n.holder, p.x, p.y, p.z, leash() + 3.0) then
                    toGround[#toGround + 1] = key
                end
            elseif n.state == 'ground' then
                if not n.pour and (now - n.since > groundMs() or not nozzleObject(n.objNetId)) then
                    back[#back + 1] = { key, 'ground' }
                end
            elseif n.state == 'car' then
                local car = NetworkGetEntityFromNetworkId(n.car.netId)
                if not car or car == 0 or not DoesEntityExist(car) then
                    back[#back + 1] = { key, 'gone' }
                elseif not n.pour and now - n.touched > idleMs() then
                    back[#back + 1] = { key, 'idle' }
                elseif not Fuel.hasHose(key) then
                    -- No hose on it: a car that drives off with it pulls it out, and it goes back
                    local p = n.pump
                    if #(GetEntityCoords(car) - vector3(p.x, p.y, p.z)) > leash() + 1.0 then back[#back + 1] = { key, 'pulled' } end
                end
            elseif n.state == 'torn' then
                -- The car gone with it: as if unplugged, gone in Config.Pump.TornMinutes
                local car = NetworkGetEntityFromNetworkId(n.car.netId)
                if not car or car == 0 or not DoesEntityExist(car) then
                    n.state, n.car, n.since = 'dead', nil, now
                    faceSync(key)
                end
            elseif n.state == 'dead' then
                if now - n.since > tornMs() then back[#back + 1] = { key, 'expired' } end
            end
        end
        if Whip.isReady() then
            for _, key in ipairs(toGround) do handToGround(key) end
            for _, b in ipairs(back) do Fuel.returnNozzle(b[1], b[2]) end
        end

        for key, untilMs in pairs(errorUntil) do
            if now >= untilMs then
                errorUntil[key] = nil
                faceSync(key)
            end
        end
    end
end)

-- Leaving, stopping

--- `src` is going (logout, a disconnect): the nozzle in their hand goes back on its pump. Their pours were settled
--- by whip_core before their save (its money holds); the nozzles they put in cars stay: those are the pumps'.
local function playerGone(src)
    local key = hands[src]
    if key and Whip.isReady() then Fuel.returnNozzle(key, 'logout') end
    hands[src] = nil
    for k, n in pairs(nozzles) do
        if n.pour and n.pour.payer == src then lostPour(k) end
    end
end

AddEventHandler('whip_core:player:logout', function(e) if type(e) == 'table' and e.source then playerGone(e.source) end end)
AddEventHandler('playerDropped', function() playerGone(source) end)

--- Everything put back where it was: every nozzle object gone, every game told its sides are free.
local function clearAll()
    local keys = {}
    for key in pairs(nozzles) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        local n = nozzles[key]
        pcall(Fuel.settle, key, 'disconnected')
        if n.car then deleteNozzleObject(n.car.objNetId) end
        if n.objNetId then deleteNozzleObject(n.objNetId) end
        nozzles[key] = nil
        TriggerEvent('whip_fuel:nozzleReturned', { key = key, reason = 'logout', pump = n.pump })
    end
    for prefix in pairs(pumpGone) do TriggerEvent('whip_fuel:pumpBack', { prefix = prefix }) end
    hands, pumpGone, errorUntil = {}, {}, {}
    TriggerClientEvent('whip_fuel:reset', -1)
end

-- whip_fuel stopping (whip_core stopping stops it first): the pours settled (for what went in), the nozzles' objects gone
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearAll()
end)
