--[[
    whip_fuel — FUEL CANS

    The jerry can is whip_gunny's item: gunny registers `jerry_can`, equips it as GTA's petrol can, and keeps the fuel
    in hand and the fuel on the item the same (pouring a trail on the ground uses it up). Any item can be a fuel can:
    one whose definition has `fuelCapacity` (how much of a car's tank a FULL can holds, in percent of a tank). Its
    metadata `fuel` is how full the can is, 0-100%. gunny's jerry can: fuelCapacity 30.

    What is here: pouring the can in hand into a car (the doors' "Refuel (jerry can)": whip_fuel:pourCan), and
    filling it at a pump ("Fill Jerry Can": whip_fuel:fillCan). Which can: the one in hand, and only that one (gunny
    says what a player holds when it draws a weapon: whip_core's SetHeldItem).
]]

--- [source] = true while a can is being filled (its bar is up): no pouring it meanwhile.
local filling = {}

--- The fuel can in the player's hand: { addr, item, capacity, level } — or nil when they hold nothing, or something
--- that is not a fuel can.
local function heldCan(src)
    local held = exports.whip_core:GetHeldItem(src)
    if type(held) ~= 'table' or not held.item then return nil end
    local def = exports.whip_core:GetItemDef(held.item)
    local capacity = type(def) == 'table' and tonumber(def.fuelCapacity)
    if not capacity or capacity <= 0 then return nil end
    local level = tonumber(type(held.metadata) == 'table' and held.metadata.fuel) or 0
    return { addr = held.addr, item = held.item, metadata = held.metadata, capacity = capacity,
             level = math.max(0, math.min(100, level)) }
end

-- ============================================
-- Pouring a can into a car
-- ============================================

--- How long pouring takes (the server runs the bar).
local function pourMs() return math.max(500, math.floor((tonumber(Config.JerryCan.PourSeconds) or 3) * 1000)) end

--- Pour the can in hand into this car: as much as it holds, or as the tank takes. The tank first, and the can only
--- emptied once the fuel went in (a car gone mid-pour must not take the can's fuel into nothing). The can stays,
--- empty or not: it is filled again at a pump.
local function pourCan(src, _, netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false, 'That vehicle is gone'
    end
    local reach = (Config.Pump.CarReach or 5.0) + 1.0

    --- Asked before the bar and again after it (long enough to walk off, or for the car to be driven away).
    local function refusal()
        if not DoesEntityExist(entity) then return 'That vehicle is gone' end
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 or #(GetEntityCoords(ped) - GetEntityCoords(entity)) > reach then
            return 'Too far from that vehicle'
        end
        if filling[src] then return 'Paying — wait a moment' end
        local can = heldCan(src)
        if not can then return 'Take your jerry can out first' end
        if can.level <= 0 then return 'Your jerry can is empty' end
        return nil, can
    end
    local why, held = refusal()
    if not held then return false, why end

    -- A street car whip has never seen is taken on: its tank needs somewhere to keep the fuel
    ---@type number|false|nil
    local vehicleId = Fuel.vehicleIdOf(entity)   -- as whip_core's index confirms it (server/pumps.lua)
    if not vehicleId then
        local err
        vehicleId, err = exports.whip_core:AdoptVehicle({ entity = entity, player = src })
        if not vehicleId then return false, err or 'That vehicle cannot be refuelled' end
    end
    if TankOf(vehicleId) >= 100.0 then return false, 'Vehicle is already full' end

    -- Through Whip.core: a bar whip_core stops in the middle of is answered (false), not waited on for ever
    local done = Whip.core:Progress(src, {
        label = 'Refueling...', duration = pourMs(), canCancel = true,
        near = { vehicle = vehicleId, range = reach },
        item = { item = held.item, metadata = held.metadata },   -- the can's picture in the bar's disc
    })
    if not done then return end

    local can
    why, can = refusal()
    if not can then return false, why end

    local current = TankOf(vehicleId)
    if current >= 100.0 then return false, 'Vehicle is already full' end
    -- In the tank's units: a full can holds `capacity` of them
    local inCan = can.level / 100 * can.capacity
    local transfer = math.min(inCan, 100.0 - current)
    if transfer <= 0 then return false, 'Nothing to transfer' end

    local target = math.min(100.0, current + transfer)
    local poured, pourErr = exports.whip_core:SetVehicleStat(vehicleId, 'fuel', target, 'jerry_can')
    if not poured then return false, pourErr or 'Could not fill that vehicle' end

    -- What is left in the can, as how full it is (to two decimals: a can poured to the last drop reads 0). Not quiet:
    -- the push is what tells whip_gunny the can in hand is lighter.
    local left = math.max(0, inCan - transfer)
    exports.whip_core:SetItemMetadata(can.addr, { fuel = math.floor(left / can.capacity * 10000) / 100 })

    exports.whip_core:NotifyPlayer(src, ('Refueled +%d%% (tank now %d%%)'):format(math.floor(transfer + 0.5),
        math.floor(target)), 'success')
end

-- ============================================
-- Filling a can at a pump
-- ============================================
--
-- With the can in hand, the pump's circle offers "Fill Jerry Can", cash or bank, and it fills there and then. Priced
-- as the pump prices a car, by the unit, so a can holding 30 of a tank costs 30 percent's worth. Paid at the END of
-- the bar, so a fill that is stopped costs nothing and needs no change.

--- What filling this can costs: the tank units it takes, whole and rounded up (the pump's way), at the pump's price.
local function canQuote(can)
    local units = math.max(0, math.ceil((100 - can.level) / 100 * can.capacity - 1e-9))
    local each = math.max(0, math.floor(tonumber(Config.Pump.Price) or 1))
    return units, units * each
end

--- Why the player could not pay `price` by `payment` now, or nil when they look able to: said before the bar rather
--- than after it. The charge decides.
local function cannotPay(src, price, payment)
    if price <= 0 then return nil end
    if payment == 'cash' then
        local cash = tonumber(exports.whip_core:GetPlayerCash(src)) or 0
        return cash < price and ('Not enough cash: it is $%d'):format(price) or nil
    end
    local acct = exports.whip_core:GetDefaultBankAccount(src)
    if type(acct) ~= 'table' then return 'You have no bank account' end
    if (tonumber(acct.balance) or 0) < price then return ('Not enough in the bank: it is $%d'):format(price) end
    return nil
end

--- The bar is the server's, and can outlast a callback's wait, so this is an event: its refusals and its result are
--- said to the player, and whip_fuel:canFillEnded tells the pump's circle it is over either way.
local function fillCan(src, _, payment, x, y, z)
    local function finish(ok, why)
        TriggerClientEvent('whip_fuel:canFillEnded', src)
        if ok then return end
        return false, why
    end
    if Fuel.handOf(src) then return finish(false, 'Put the nozzle down first') end
    if filling[src] then return finish(false, 'Already filling') end

    local can = heldCan(src)
    if not can then return finish(false, 'Hold the jerry can you want to fill') end
    local units, price = canQuote(can)
    if units <= 0 then return finish(false, 'Your jerry can is already full') end
    local short = cannotPay(src, price, payment)
    if short then return finish(false, short) end

    local reach = (Config.Pump.Reach or 3.0) + 2.0
    filling[src] = true
    local speed = 100 / math.max(1, tonumber(Config.Pump.FullSeconds) or 120)   -- the pump's flow, percent a second
    local done = Whip.core:Progress(src, {   -- answered false if whip_core stops mid-bar (filling[src] let go)
        label = ('Filling the jerry can — $%d'):format(price),
        duration = math.max(1000, math.ceil(units / speed * 1000)),
        canCancel = true,
        near = { coords = vector3(x, y, z), range = reach },
        item = { item = can.item, metadata = can.metadata },   -- the can's picture in the bar's disc
    })
    if not done then
        filling[src] = nil
        return finish(true)   -- stopped, walked off or gone: nothing was paid
    end

    -- After the bar: a can still there to fill (read again: the pockets may have changed during it)
    can = heldCan(src)
    if not can then filling[src] = nil return finish(false, 'You put the jerry can away') end
    units, price = canQuote(can)
    if units <= 0 then filling[src] = nil return finish(false, 'Your jerry can is already full') end

    -- The fuel and the payment land together: inside this handler whip_core writes the can's change with the charge,
    -- so both happen or neither does. Refused, the can goes back to what it held.
    local was = can.level
    exports.whip_core:SetItemMetadata(can.addr, { fuel = 100 })
    local receipt, payErr = exports.whip_core:ChargePlayer(src, price, { method = payment, reason = 'Fuel: jerry can' })
    filling[src] = nil
    if not receipt then
        exports.whip_core:SetItemMetadata(can.addr, { fuel = was })
        return finish(false, payErr or 'Payment failed')
    end
    exports.whip_core:NotifyPlayer(src, ('Jerry can filled: $%d'):format(price), 'success')
    return finish(true)
end

Whip.register(function()
    exports.whip_core:SecureEvent('whip_fuel:pourCan', {
        rateLimit = 2000,
        params = { { 'netId', 'id', 1, 4294967295 } },
    }, pourCan)

    -- Every refusal ends the client's fill (onReject says it is over), or the animation would loop until the
    -- client's 60 s backstop. A burst of 2 lets a quick second press (after a "Not enough cash") reach it.
    exports.whip_core:SecureEvent('whip_fuel:fillCan', {
        rateLimit = 1000,
        burst     = 2,
        onReject  = function(src) TriggerClientEvent('whip_fuel:canFillEnded', src) end,
        params = {
            { 'payment', 'enum', { 'cash', 'bank' } },
            { 'x', 'number', -20000.0, 20000.0 },
            { 'y', 'number', -20000.0, 20000.0 },
            { 'z', 'number',  -2000.0,  2000.0 },
        },
        -- The pump's point as the client sends it: what this does and does not prove is at takeNozzle
        -- (server/pumps.lua)
        near = {
            at    = function(_, _, _, x, y, z) return x, y, z end,
            range = function() return (Config.Pump.Reach or 3.0) + 2.0 end,
        },
    }, fillCan)
end)

AddEventHandler('playerDropped', function() filling[source] = nil end)
