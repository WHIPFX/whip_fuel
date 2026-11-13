--[[
    whip_fuel — THE PUMP'S HOSE

    With whip_rope running (and Config.Hose.Enabled), a hose runs from the pump to its nozzle wherever it is: a rope
    of whip_rope's rope API (exports.whip_rope:CreateRope), locked (nobody grabs, ties, coils or hangs off it), in
    3D Clanker's rubber look. A hose is its nozzle's, by the nozzle's key, not a player's. Without whip_rope there is no
    hose, and a car that drives off with the nozzle in simply pulls it out (server/pumps.lua).

    THE PUMP TORN OFF. A car that drives off with the nozzle in pulls on the hose like any rope. The hose is watched
    (Config.Hose.BreakStretch): pulled that far, whip_rope says so (whip_rope:ropeStretched, checked against where its
    ends really are). A pump with a loose copy (Config.Hose.TornModels) comes away: the fill ends (Fuel.pumpTorn),
    every game hides the island's pump and the copy is dragged on the hose (client/hose.lua) till both its nozzles are
    back (whip_fuel:pumpBack). A pump with none breaks the hose off at the car (Fuel.breakaway). Its pump blown up where
    it stands: both its nozzles go back (Fuel.pumpDestroyed).

    ITS OTHER SIDE, still out as it comes away (server/pumps.lua says): its hose is tied to the torn pump too. In
    another car, that car is on the pump: the two cars and the pump pull on one another (each rope pulls both its
    ends; on the pump their pulls add up). In a hand, whip_rope drags its holder along behind the pump, and they let go
    (whip_rope's Config.Drag; client/pumps.lua drops the nozzle).
]]

local ROPE = 'whip_rope'

--- [key] = { id, origin, tailType }: each nozzle's hose, its pump end and what its other end is on
local hoses = {}
--- [hose id] = its nozzle's key
local keyOfId = {}
--- [pump prefix] = { key (the side that tore it), pump = that hose's pump end, copyNetId, at = GetGameTimer() it came
--- away } while that pump is off its island
local torn = {}

local function ropeRunning() return GetResourceState(ROPE) == 'started' end

--- A hose is drawn: the setting, and whip_rope there to draw it.
Fuel.hoseDrawn = function() return Config.Hose.Enabled ~= false and ropeRunning() end

--- This nozzle has its hose now. Not the same as hoseDrawn: a hose whip_rope refused, or one an admin cleared, is
--- none, and its car pulls the nozzle out as with no hose at all (server/pumps.lua's clock).
Fuel.hasHose = function(key) return Fuel.hoseDrawn() and hoses[key] ~= nil end

--- A model hash as one number, whichever sign it came with.
local function unsigned(hash) return math.floor(tonumber(hash) or 0) % 4294967296 end

--- A model given as a hash (config.lua's `whip_pump_torn`) or a name, as one number.
local function hashOf(model)
    return unsigned(type(model) == 'number' and model or GetHashKey(tostring(model)))
end

--- Config.Hose.Outlets and .TornModels by model hash, and each listed pump's name (worked out again when they change
--- in /whip).
local outletsByModel, tornByModel, nameByModel = {}, {}, {}
local function byModel()
    outletsByModel, tornByModel, nameByModel = {}, {}, {}
    for name, list in pairs(Config.Hose.Outlets or {}) do
        outletsByModel[unsigned(GetHashKey(name))] = list
        nameByModel[unsigned(GetHashKey(name))] = name
    end
    for name, model in pairs(Config.Hose.TornModels or {}) do tornByModel[unsigned(GetHashKey(name))] = model end
end
byModel()
Whip.onConfigChanged('Hose', byModel)

--- Where on this pump side `side`'s hose leaves ('A' or 'B'), in the pump's own space: the outlet nearest that side's
--- own nozzle (Config.NozzleCircle: side B's is side A's turned half round). By the side, never by where the player
--- stood: a modern pump's two outlets sit corner to corner, so from toward one end of a face the other side's outlet,
--- over the pump's top, was the nearer. A pump not in Config.Hose.Outlets: OutletHeight straight up.
local function outletOf(model, side)
    local list = outletsByModel[unsigned(model)]
    if not list or #list == 0 then return vector3(0.0, 0.0, Config.Hose.OutletHeight or 1.1) end
    local n = Pumps.placingOf(nameByModel[unsigned(model)], true).offset
    local nx, ny = n.x, n.y
    if side == 'B' then nx, ny = -nx, -ny end
    local best, bestD = list[1], math.huge
    for _, o in ipairs(list) do
        local d = (o.x - nx) ^ 2 + (o.y - ny) ^ 2
        if d < bestD then best, bestD = o, d end
    end
    return best
end

--- The hose's pump end: the pump itself (a map prop, by its model where it stands; an anchor, never dragged: `still`)
--- when known, else a fixed point at the pump. `side`: whose outlet it comes from ('A' or 'B', the key's).
local function pumpEnd(pump, side)
    local at = type(pump.at) == 'table' and pump.at
    if tonumber(pump.model) and at then
        local o = outletOf(pump.model, side)
        local h = math.rad(tonumber(pump.heading) or 0.0)
        local c, s = math.cos(h), math.sin(h)
        return {
            type = 'object', netId = 0, model = tonumber(pump.model), still = true,
            worldPos = { x = at.x + 0.0, y = at.y + 0.0, z = at.z + 0.0 }, heading = tonumber(pump.heading) or 0.0,
            offset = { x = o.x, y = o.y, z = o.z },
            point = { x = at.x + o.x * c - o.y * s, y = at.y + o.x * s + o.y * c, z = at.z + o.z },
        }
    end
    return { type = 'fixed', pos = { x = pump.x + 0.0, y = pump.y + 0.0, z = pump.z + 0.0 } }
end

--- `world` in the car's own space (its heading only, and where this server last saw it: rough, a fallback).
local function inCarSpace(veh, world)
    local c = GetEntityCoords(veh)
    local h = math.rad(GetEntityHeading(veh))
    local dx, dy = world.x - c.x, world.y - c.y
    return { x = dx * math.cos(h) + dy * math.sin(h), y = -dx * math.sin(h) + dy * math.cos(h), z = world.z - c.z }
end

--- Where the hose goes into the nozzle, in the nozzle's own space (3D Clanker's measure of prop_cs_fuel_nozle).
local NOZZLE_HOSE_END = { x = 0.0, y = -0.027, z = -0.200 }

--- Where a hose ends on a car with a nozzle in it, in the car's space: the nozzle's back as the inserting game tied it
--- (`offset`, whip_fuel:nozzleInserted's hoseOffset); without one, the nozzle as this server last saw it, else the car.
local function hoseOnCar(veh, nozzle, offset)
    if type(offset) == 'table' and tonumber(offset.x) and tonumber(offset.y) and tonumber(offset.z) then
        return { x = offset.x + 0.0, y = offset.y + 0.0, z = offset.z + 0.0 }
    end
    local at = (nozzle and nozzle ~= 0 and DoesEntityExist(nozzle)) and GetEntityCoords(nozzle) or GetEntityCoords(veh)
    return inCarSpace(veh, at)
end

--- A key's hose drawn from its pump (the key's own side's outlet) to `tail` (an end, as the rope API takes it). Any old
--- one for the key goes first.
local function draw(key, pump, tail)
    local old = hoses[key]
    if old then
        hoses[key], keyOfId[old.id] = nil, nil
        pcall(function() exports[ROPE]:RemoveRope(old.id) end)
    end
    if not Fuel.hoseDrawn() then return end
    local origin = pumpEnd(pump, key:sub(-1))
    local ok, id = pcall(function()
        return exports[ROPE]:CreateRope({
            kind = 'hose', player = tail.heldBy or tail.player,
            origin = origin, tail = tail,
            length = Config.Hose.Length or 3.0,
            link = Config.Hose.LinkLength,
            locked = true,
            look = { model = Config.Hose.Model, modelNoShadow = Config.Hose.ModelNoShadow, thickness = 1.0 },
            collide = { spacing = Config.Hose.CollisionCheckSpacing or 1, vehicles = Config.Hose.CollideWithVehicles },
            heldAt = { model = 'prop_cs_fuel_nozle', offset = NOZZLE_HOSE_END },
            watch = { stretch = Config.Hose.BreakStretch or 0.35, holdMs = Config.Hose.BreakHoldMs or 250, broken = true },
            -- Never longer than this: a torn pump (or the nozzle on the ground, or a second car) is dragged along
            maxStretch = Config.Hose.MaxStretch or 0.3,
        })
    end)
    if not ok or not id then
        print(('[whip_fuel] no hose for %s: %s'):format(key, tostring(id)))
        return
    end
    hoses[key] = { id = id, origin = origin, tailType = tail.type, tailNetId = tail.netId }
    keyOfId[id] = key
end

--- Move a hose's tail.
local function tailTo(key, e)
    local h = hoses[key]
    if not h then return end
    h.tailType, h.tailNetId = e.type, e.netId
    pcall(function() exports[ROPE]:SetRopeEnd(h.id, 'tail', e) end)
end

-- ============================================================================
-- FOLLOWING THE NOZZLE (server/pumps.lua's events)
-- ============================================================================

AddEventHandler('whip_fuel:nozzleTaken', function(e)
    if type(e) ~= 'table' or type(e.pump) ~= 'table' or type(e.key) ~= 'string' then return end
    local src = tonumber(e.source)
    if not src then return end
    draw(e.key, e.pump, { type = 'held', heldBy = src })
end)

AddEventHandler('whip_fuel:nozzleInserted', function(e)
    if type(e) ~= 'table' or not hoses[e.key] then return end
    local veh = NetworkGetEntityFromNetworkId(tonumber(e.vehicleNetId) or 0)
    local nozzle = NetworkGetEntityFromNetworkId(tonumber(e.nozzleNetId) or 0)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    tailTo(e.key, { type = 'vehicle', netId = tonumber(e.vehicleNetId), offset = hoseOnCar(veh, nozzle, e.hoseOffset) })
end)

--- Into a hand: out of a car, or picked up off the ground.
local function toHand(e)
    local src = type(e) == 'table' and tonumber(e.source)
    if src then tailTo(e.key, { type = 'held', heldBy = src }) end
end
AddEventHandler('whip_fuel:nozzleRemoved', toHand)
AddEventHandler('whip_fuel:nozzlePickedUp', toHand)

--- On the ground: the hose ends at the back of the nozzle lying there, which it can drag.
AddEventHandler('whip_fuel:nozzleDropped', function(e)
    local netId = type(e) == 'table' and tonumber(e.nozzleNetId)
    if netId then tailTo(e.key, { type = 'object', netId = netId, offset = NOZZLE_HOSE_END }) end
end)

--- A hose's pump end moved onto the torn pump's copy, at that hose's own outlet (each side has its own), with what the
--- copy weighs (Config.Hose.TornMass: the rope can't read it, and pulls by it).
local function toCopy(h, copyNetId)
    pcall(function()
        exports[ROPE]:SetRopeEnd(h.id, 'origin', { type = 'object', netId = copyNetId, offset = h.origin.offset,
            mass = tonumber(Config.Hose.TornMass) or 1400 })
    end)
end

--- The pump off its island. A map pump will not move (its root is built never to, and every game has its own), so
--- every game hides the island's pump and ONE loose copy (Config.Hose.TornModels: whip_pump_torn) stands in for it,
--- networked, the hose tied to it: the hose drags it for real, like any prop on a rope. Its other side's hose, when
--- that nozzle is still out (in a car, in a hand), is tied to it too. It stays off its island till both its nozzles are
--- back (whip_fuel:pumpBack).
---
--- THE SWAP IS NEVER SEEN, in this order:
---   1. The hose pulled hard enough (whip_rope:ropeStretched): the game that drives the car makes the copy, FROZEN,
---      exactly inside the island's pump (the same model space, place and turn), and says so (askForCopy, tornCopy).
---   2. The pump is torn (Fuel.pumpTorn): its hoses' pump ends move onto the copy, still frozen (an anchor, as the
---      island's pump was), and that game is told (whip_fuel:tornCopyTied).
---   3. That game sees its hose on the copy, hides the island's pump, sees it gone, and only then lets the copy go
---      (client/hose.lua): dragged from then on, and the server told (tornCopyFree), so whichever game runs it later
---      wakes it too.
--- Every other game hides its island's pump when the copy reaches it (inside the island's, it looks the same).
---
--- Each step prints one line in the server console (tearSay), so a tear that stops shows where.
local madeCopy = {}   -- [pump prefix] = { netId, src }: the copy and its maker, for Fuel.pumpTorn's nozzleTorn

--- How long after the hose is on the copy the server lets it go itself, if its maker never says (its game gone).
local FREE_WAIT_MS = 4000

--- One line in the server console for a step of a pump coming away.
local function tearSay(key, fmt, ...)
    print(('[whip_fuel] torn pump %s: ' .. fmt):format(key, ...))
end

--- The copy let go: every game wakes it when it runs it (it was frozen till its island's pump was gone). `how`: who
--- let it go, for the console.
local function free(prefix, how)
    local t = torn[prefix]
    if not t or t.free then return end
    t.free = true
    tearSay(t.key, '%s', how)
    TriggerClientEvent('whip_fuel:pumpFree', -1, t.key)
end

AddEventHandler('whip_fuel:nozzleTorn', function(e)
    local key = type(e) == 'table' and e.key
    local h = key and hoses[key]
    local prefix = key and Pumps.prefixOf(key)
    local made = prefix and madeCopy[prefix]
    if prefix then madeCopy[prefix] = nil end
    if not h or not made or torn[prefix] then return end
    local o = h.origin
    local t = { key = key, pump = o, copyNetId = made.netId, maker = made.src, at = GetGameTimer() }
    torn[prefix] = t
    -- The last arguments: how long ago it came away (ms), so every game's lights die together, and whether it is let
    -- go yet (client/hose.lua)
    TriggerClientEvent('whip_fuel:pumpTorn', -1, key, o, false, made.netId, 0, false)
    toCopy(h, made.netId)
    -- The other side, still out: its car is on the pump now, or its holder is dragged along by it (whip_rope)
    local other = type(e.other) == 'table' and hoses[e.other.key]
    if other then toCopy(other, made.netId) end
    -- Its maker hides the island's pump once its hose is on the copy, then lets it go
    TriggerClientEvent('whip_fuel:tornCopyTied', made.src, key, h.id)
    SetTimeout(FREE_WAIT_MS, function()
        if torn[prefix] == t then
            free(prefix, ('let go by the server: no word from its maker in %d ms'):format(FREE_WAIT_MS))
        end
    end)
end)

--- A torn pump back on its island (neither nozzle out: server/pumps.lua): its copy gone, the island's pump on every
--- game again.
local function repair(prefix)
    local t = torn[prefix]
    if not t then return end
    torn[prefix] = nil
    local copy = t.copyNetId and NetworkGetEntityFromNetworkId(t.copyNetId)
    if copy and copy ~= 0 and DoesEntityExist(copy) then DeleteEntity(copy) end
    TriggerClientEvent('whip_fuel:pumpRepaired', -1, t.pump)
end

AddEventHandler('whip_fuel:pumpBack', function(e)
    if type(e) == 'table' and type(e.prefix) == 'string' then repair(e.prefix) end
end)

--- Back on its pump: its hose gone.
AddEventHandler('whip_fuel:nozzleReturned', function(e)
    if type(e) ~= 'table' or type(e.key) ~= 'string' then return end
    local h = hoses[e.key]
    if not h then return end
    hoses[e.key], keyOfId[h.id] = nil, nil
    if ropeRunning() then pcall(function() exports[ROPE]:RemoveRope(h.id) end) end
end)

-- ============================================================================
-- THE PULL, AND THE PUMP BLOWN UP (whip_rope's notices)
-- ============================================================================

--- How long the car's game has to make the torn pump's copy and say so. No answer: the pump stays, and the hose breaks
--- off at the car as a pump with no copy's does.
local COPY_WAIT_MS = 3000

--- [pump prefix] = { key, src, model, at, token } while the car's game is making the copy
local asked = {}
local askToken = 0

--- The pump comes away: the game that drives the car makes the copy inside the island's pump (client/hose.lua
--- whip_fuel:makeTornCopy) and answers with it (whip_fuel:tornCopy, below). A car no game runs: the hose breaks off
--- at it.
local function askForCopy(key, h)
    local prefix = Pumps.prefixOf(key)
    if asked[prefix] then return end
    local car = h.tailNetId and NetworkGetEntityFromNetworkId(h.tailNetId)
    local driver = car and car ~= 0 and DoesEntityExist(car) and NetworkGetEntityOwner(car)
    if not driver or driver <= 0 or not GetPlayerName(driver) then
        tearSay(key, 'no game runs the car, so the hose breaks off at it')
        return Fuel.breakaway(key)
    end
    askToken = askToken + 1
    local a = { key = key, src = driver, model = tornByModel[unsigned(h.origin.model)], at = h.origin.worldPos,
                token = askToken, askedAt = GetGameTimer() }
    asked[prefix] = a
    tearSay(key, 'asked %s (%d) to make the copy', GetPlayerName(driver), driver)
    TriggerClientEvent('whip_fuel:makeTornCopy', driver, key, h.origin, a.model)
    SetTimeout(COPY_WAIT_MS, function()
        if asked[prefix] ~= a or a.answered then return end
        asked[prefix] = nil
        tearSay(key, 'no answer from %d in %d ms, so the hose breaks off at the car', driver, COPY_WAIT_MS)
        Fuel.breakaway(key)
    end)
end

--- The car's game made the copy (`netId`; 0: it could not, and `why`). Only the game asked, for the pump it was asked
--- about, and only a copy its own game made, of the torn model, at the pump: anything else is refused, and the hose
--- breaks off. Refused, or too late: a copy its game made goes (its game forgets it: tornCopyRefused).
local function tornCopy(src, _, key, netId, why)
    local prefix = key:match(Pumps.KEY_PATTERN) and Pumps.prefixOf(key)
    local a = prefix and asked[prefix]
    -- Still asked while it is looked at (the hose keeps saying it is stretched: not asked twice), answered (the clock
    -- above lets it be)
    local mine = a and a.src == src and a.key == key and not a.answered
    if mine then a.answered = true end
    -- Its game's word can come before the copy itself does: waited for a moment
    local copy, deadline = nil, GetGameTimer() + 1500
    while netId > 0 do
        copy = NetworkGetEntityFromNetworkId(netId)
        if copy and copy ~= 0 and DoesEntityExist(copy) then break end
        copy = nil
        if GetGameTimer() > deadline then break end
        Wait(50)
    end
    local made = copy and NetworkGetFirstEntityOwner(copy) == src
    -- Why it is refused, for the console (nil: it is the copy asked for)
    local refusal
    if not mine then
        refusal = 'not asked for (or answered already, or too late)'
    elseif netId <= 0 then
        -- (one line: client text never starts a new one in the console)
        refusal = ('its game could not make it (%s)'):format(
            type(why) == 'string' and why ~= '' and why:gsub('%c', ' ') or 'no reason given')
    elseif not copy then
        refusal = ('copy %d never reached the server'):format(netId)
    elseif not made then
        refusal = ('copy %d was not made by that game'):format(netId)
    elseif unsigned(GetEntityModel(copy)) ~= hashOf(a.model) then
        refusal = ('copy %d is not a %s'):format(netId, tostring(a.model))
    else
        local d = #(GetEntityCoords(copy) - vector3(a.at.x, a.at.y, a.at.z))
        if d >= 3.0 then refusal = ('copy %d is %.1f m from the pump'):format(netId, d) end   -- frozen where it is
    end
    local ok = refusal == nil
    if mine then asked[prefix] = nil end
    if ok then
        SetEntityOrphanMode(copy, 2)   -- KeepEntity: it stays when its maker leaves; repair() decides when it goes
        madeCopy[prefix] = { netId = netId, src = src }
        if Fuel.pumpTorn(key) then
            tearSay(key, 'torn off with copy %d from %d, %d ms after asking: the hose is on it', netId, src,
                GetGameTimer() - a.askedAt)
            return
        end
        madeCopy[prefix] = nil         -- unplugged meanwhile: no pump to drag
        refusal = 'the nozzle came out of the car meanwhile'
    end
    tearSay(key, 'copy from %d refused: %s%s', src, refusal, (mine and not ok) and ', so the hose breaks off at the car' or '')
    if made then
        local m = unsigned(GetEntityModel(copy))
        for _, model in pairs(Config.Hose.TornModels or {}) do
            if hashOf(model) == m then DeleteEntity(copy) break end
        end
    end
    TriggerClientEvent('whip_fuel:tornCopyRefused', src, key)
    if mine and not ok then Fuel.breakaway(key) end
end

--- Its maker let the copy go (the island's pump gone on its game): every game wakes it now. Only its maker says.
--- What its game saw, for the console: its hose on the copy (`tied`), the island's pump gone (`gone`), and whether it
--- ran the copy then (`owned`: it wakes it itself; else the game that does wakes it on pumpFree).
local function tornCopyFree(src, _, key, tied, gone, owned)
    local prefix = key:match(Pumps.KEY_PATTERN) and Pumps.prefixOf(key)
    local t = prefix and torn[prefix]
    if not (t and t.maker == src and t.key == key) then return end
    local function seen(yes) return yes and 'yes' or 'NO, gone on after the wait' end
    free(prefix, ('let go by its maker %d ms after it came away. Its hose seen on the copy: %s. The island pump seen gone: %s. It ran the copy: %s')
        :format(GetGameTimer() - t.at, seen(tied), seen(gone), owned and 'yes' or 'NO'))
end

Whip.register(function()
    exports.whip_core:SecureEvent('whip_fuel:tornCopy', {
        rateLimit = 250, burst = 2, whileDead = true,
        params = { { 'key', 'string', 64 }, { 'netId', 'int', 0, 4294967295, 0 }, { 'why', 'string', 40, '' } },
    }, tornCopy)
    exports.whip_core:SecureEvent('whip_fuel:tornCopyFree', {
        rateLimit = 250, burst = 2, whileDead = true,
        params = { { 'key', 'string', 64 }, { 'tied', 'bool', false }, { 'gone', 'bool', false },
                   { 'owned', 'bool', false } },
    }, tornCopyFree)
end)

--- A hose pulled past BreakStretch: only while its nozzle is in a car and its pump still on its island (on a torn
--- pump the hoses just pull: the cars and the pump on one another).
AddEventHandler('whip_rope:ropeStretched', function(id, resource)
    if resource ~= GetCurrentResourceName() then return end
    local key = keyOfId[id]
    local h = key and hoses[key]
    if not h or torn[Pumps.prefixOf(key)] or h.tailType ~= 'vehicle' then return end
    -- A pump with a loose copy comes away; any other's hose breaks off at the car (Config.Hose.TornModels)
    if h.origin.type == 'object' and tornByModel[unsigned(h.origin.model)] then
        askForCopy(key, h)
    else
        Fuel.breakaway(key)
    end
end)

--- Its pump blown up where it stands: nothing holds the hose, so its nozzle goes back (a car with it in is free).
AddEventHandler('whip_rope:ropeEndBroken', function(id, which, resource)
    if resource ~= GetCurrentResourceName() or which ~= 'origin' then return end
    local key = keyOfId[id]
    if key and not torn[Pumps.prefixOf(key)] then Fuel.pumpDestroyed(key) end
end)

-- ============================================================================
-- COMING AND GOING
-- ============================================================================

-- A game that comes in while a pump is off: it is gone from its island there too, until it is back
AddEventHandler('whip_core:player:loaded', function(e)
    local src = type(e) == 'table' and tonumber(e.source)
    if not src then return end
    for _, t in pairs(torn) do
        TriggerClientEvent('whip_fuel:pumpTorn', src, t.key, t.pump, true, t.copyNetId, GetGameTimer() - t.at, t.free == true)
    end
end)

--- A hose for every nozzle out that has none: whip_rope back, or Config.Hose.Enabled turned on in /whip.
local function drawMissing()
    for _, n in ipairs(Fuel.nozzlesOut()) do
        local tail
        if hoses[n.key] then
            -- (has its hose)
        elseif n.state == 'hand' and n.holder then
            tail = { type = 'held', heldBy = n.holder }
        elseif (n.state == 'car' or n.state == 'torn') and n.car then
            local veh = NetworkGetEntityFromNetworkId(n.car.netId)
            local obj = NetworkGetEntityFromNetworkId(n.car.objNetId or 0)
            if veh and veh ~= 0 and DoesEntityExist(veh) then
                tail = { type = 'vehicle', netId = n.car.netId, offset = hoseOnCar(veh, obj, n.car.hoseOffset) }
            end
        elseif n.objNetId then
            tail = { type = 'object', netId = n.objNetId, offset = NOZZLE_HOSE_END }
        end
        if tail then
            draw(n.key, n.pump, tail)
            local t, h = torn[Pumps.prefixOf(n.key)], hoses[n.key]
            if t and h then toCopy(h, t.copyNetId) end
        end
    end
end

-- whip_rope stopping takes its ropes with it; starting again, every nozzle out has its hose drawn again
AddEventHandler('onResourceStop', function(res)
    if res == ROPE then hoses, keyOfId = {}, {} end
end)
AddEventHandler('onResourceStart', function(res)
    if res ~= ROPE then return end
    CreateThread(function()
        Wait(1000)   -- its own registrations first
        drawMissing()
    end)
end)

-- Hoses turned on in /whip: drawn for the nozzles already out. Off: taken away (their cars pull them out after)
Whip.onConfigChanged('Hose.Enabled', function(on)
    if on ~= false then
        if ropeRunning() then CreateThread(drawMissing) end
        return
    end
    for key, h in pairs(hoses) do
        hoses[key], keyOfId[h.id] = nil, nil
        if ropeRunning() then pcall(function() exports[ROPE]:RemoveRope(h.id) end) end
    end
end)

-- whip_rope took one of ours away itself (an admin's /clearropes): forgotten, so the nozzle is one with no hose
AddEventHandler('whip_rope:ropeRemoved', function(id, resource)
    if resource ~= GetCurrentResourceName() then return end
    local key = keyOfId[id]
    if not key then return end
    keyOfId[id] = nil
    if hoses[key] and hoses[key].id == id then hoses[key] = nil end
end)

-- whip_fuel stopping: the torn pumps' copies go (each game puts its island's pump back: client/hose.lua); its ropes
-- go with it (the rope API's own rule)
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for prefix in pairs(torn) do repair(prefix) end
end)
