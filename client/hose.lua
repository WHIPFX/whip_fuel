--[[
    whip_fuel — A PUMP TORN OFF ITS ISLAND, ON THIS GAME

    The hose itself is whip_rope's to draw (server/hose.lua makes it with the rope API). What is the pump's alone is
    here:

      TORN (whip_fuel:pumpTorn). A map pump will not leave its island (its root is built never to move, and every game
      has its own), so every game hides the island's pump and ONE loose copy stands where it stood (Config.Hose.TornModels:
      3D Clanker's whip_pump_torn), networked, which the hose is tied to and drags for real. It leaks a petrol trail for
      Config.Hose.LeakSeconds. (Config.Hose.FireAtBase sets the island alight: off, as a pump on fire blows up.)

      THE SWAP IS NEVER SEEN (server/hose.lua has the whole order). The game that drives the car makes the copy FROZEN
      exactly inside the island's pump (whip_fuel:makeTornCopy). Told the hose is on it
      (whip_fuel:tornCopyTied), it waits to see its own hose there, hides the island's pump, waits to see it gone, and
      only then lets the copy go. Every other game hides the island's pump the moment the copy reaches it
      (hideWhenHere), and wakes the copy only once it is let go (whip_fuel:pumpFree): it is never missing in between.

      ITS POWER. The copy is dead by itself (3D Clanker's: no lit sign, a dark screen, no lights). Its power is a
      prop of its own, its model's glow (Config.Hose.TornGlow: the lit sign and the canopy's lights, in the pump's own
      space), put on it as it comes away, with the pump's screen flashing ERROR (under its brand) over the side it was
      torn from. POWER_MS later
      both flicker out together, a dying tube (FLICKER), and are gone. Every game counts from when it came away (the
      server says how long ago), so they die together; a game that sees it later than that sees it dead.

      BACK (whip_fuel:pumpRepaired). The copy is gone (the server's), and the island's pump shows again.
]]

local LEAK_STEP = 0.5            -- metres the pump moves between drops of petrol
local FIRE_REACH = 200.0         -- metres: a game further from the pump than this lights no fire

local POWER_MS = 5000            -- lit this long after it comes away, then the flicker
--- The flicker, in ms: on, off, on, off ... from POWER_MS, then off for good (3D Clanker's dying tube).
local FLICKER = { 90, 70, 150, 60, 40, 220, 60, 120, 30, 400, 25 }
local FLICKER_MS = 0
for _, ms in ipairs(FLICKER) do FLICKER_MS = FLICKER_MS + ms end

--- [key] = { at, model, copyNetId, hidden, started, free, maker?, copy? }: its island's pump hidden here, its copy on
--- the hose. `maker`: this game made the copy (copy: the entity); `free`: the copy is let go (dragged).
local torn = {}

--- How long a game waits for the copy to reach it before hiding the island's pump anyway (a game too far away for the
--- copy to be sent to it: nobody there sees the swap).
local HIDE_WAIT_MS = 2000
--- The maker's waits, each a backstop only: for the copy to have its network id, for its hose to be on the copy here,
--- and for the island's pump to be gone after it is hidden. Past one, it goes on to the next step.
local NETWORKED_WAIT_MS = 1000
local TIED_WAIT_MS = 2000
local GONE_WAIT_MS = 500

--- A model hash as one number, whichever sign it came with.
local function unsigned(hash) return math.floor(tonumber(hash) or 0) % 4294967296 end

--- What a torn pump of this island model has: its glow prop (Config.Hose.TornGlow) and its screen's brand
--- (Config.PumpPanels). Looked up by the island pump's model hash.
local function powerOf(model)
    local m = unsigned(model)
    for name, glow in pairs(Config.Hose.TornGlow or {}) do
        if unsigned(GetHashKey(name)) == m then return glow, Config.PumpPanels and Config.PumpPanels[name] end
    end
    for name, brand in pairs(Config.PumpPanels or {}) do
        if unsigned(GetHashKey(name)) == m then return nil, brand end
    end
    return nil, nil
end

local function v3(t) return t and vector3(t.x + 0.0, t.y + 0.0, t.z + 0.0) or nil end

--- The torn pump's copy on this game, or nil.
local function copyOf(t)
    if not t.copyNetId or not NetworkDoesNetworkIdExist(t.copyNetId) then return nil end
    local e = NetworkGetEntityFromNetworkId(t.copyNetId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

--- Loose: dragged by the rope's own pull like any prop tied to one, and kept whole (it cannot be blown up, and is not
--- to be shot to pieces either). Only the game that runs it can.
local function wake(copy)
    SetEntityInvincible(copy, true)
    FreezeEntityPosition(copy, false)
    SetEntityDynamic(copy, true)
    ActivatePhysics(copy)
end

--- The copy's model loaded ahead on a game driving a car with a nozzle in it (client/tank.lua asks each second): torn
--- off, it is made that frame rather than after it streams in.
function Nozzle.readyTornCopy()
    -- (config.lua names each copy as a hash, `whip_pump_torn`; a name in quotes works too)
    for _, model in pairs(Config.Hose.TornModels or {}) do
        RequestModel(type(model) == 'number' and model or GetHashKey(tostring(model)))
    end
end

--- ITS GRIP. GTA gives the torn pump's model almost no grip on the ground (Josh, 11 Nov: pushed, it slid on as if on
--- ice, and crept by itself with nothing tied to it), and a model's surface is not a script's to change. So the game
--- that runs it slows its sliding itself while it is on the ground, as a heavy steel pump on concrete would: by GRIP
--- metres a second (Config.Hose.TornGrip), every second it slides, down to a stop. A stronger pull (the hose, a car)
--- still drags it, against that, and the car dragging it feels it (whip_rope shares the hose's pull by weight).

--- One frame of the copy's grip; answers whether it was sliding.
local function grip(copy)
    local g = tonumber(Config.Hose.TornGrip) or 6.0
    if g <= 0 or IsEntityInAir(copy) then return false end
    local v = GetEntityVelocity(copy)
    local speed = math.sqrt(v.x * v.x + v.y * v.y)
    if speed < 0.01 then return false end
    local kept = math.max(0.0, speed - g * GetFrameTime()) / speed
    SetEntityVelocity(copy, v.x * kept, v.y * kept, v.z)
    return true
end

--- The copy woken on whichever game comes to run it, once it is let go (it moves to the game nearest it as it is
--- dragged). Never before: till then it is frozen inside the island's pump. Its grip there too: every frame while it
--- slides, ten times a second while it stands.
local function wakeThread(key)
    CreateThread(function()
        local woken = nil   -- the copy entity woken already, on this game
        while torn[key] do
            local t = torn[key]
            local copy = t.free and copyOf(t)
            local mine = copy and NetworkGetEntityOwner(copy) == PlayerId()
            if mine and woken ~= copy then
                wake(copy)
                woken = copy
            end
            if mine and grip(copy) then Wait(0) else Wait(100) end
        end
    end)
end

--- The island's pump hidden on this game (the copy stands in for it: script objects are not hidden by this).
local function hide(t)
    if t.hidden then return end
    t.hidden = true
    CreateModelHideExcludingScriptObjects(t.at.x, t.at.y, t.at.z, 1.5, t.model, true)
end

--- Hidden the frame the copy is here, so the pump is never missing between the two: or after HIDE_WAIT_MS without it.
local function hideWhenHere(key)
    local t = torn[key]
    CreateThread(function()
        local giveUpAt = GetGameTimer() + HIDE_WAIT_MS
        while torn[key] == t and not t.hidden and not copyOf(t) and GetGameTimer() < giveUpAt do Wait(0) end
        if torn[key] == t then hide(t) end
    end)
end

--- A petrol trail behind the copy while it leaks, from where the pump stood: the island's fire runs along it.
local function leak(key, from)
    CreateThread(function()
        local untilAt = GetGameTimer() + (Config.Hose.LeakSeconds or 20) * 1000
        local last = from
        StartPetrolTrailDecals(1.0)
        AddPetrolTrailDecalInfo(from.x, from.y, from.z, 1.0)
        while GetGameTimer() < untilAt and torn[key] do
            Wait(100)
            local copy = copyOf(torn[key])
            if copy then
                local p = GetEntityCoords(copy)
                if #(p - last) >= LEAK_STEP then
                    local found, ground = GetGroundZFor_3dCoord(p.x, p.y, p.z + 1.0, false)
                    AddPetrolTrailDecalInfo(p.x, p.y, found and ground or p.z, 1.0)
                    last = p
                end
            end
        end
        EndPetrolTrailDecals()
    end)
end

--- The torn pump's power: on for POWER_MS from `startAt` (this game's clock), the flicker, then gone. The glow prop
--- and the pump's screen (client/pumps.lua) go together. Waits for the copy to be here, till the end.
local function powerDown(key, startAt)
    local t = torn[key]
    CreateThread(function()
        local endAt = startAt + POWER_MS + FLICKER_MS
        local copy
        while GetGameTimer() < endAt and torn[key] == t do
            copy = copyOf(t)
            if copy then break end
            Wait(100)
        end
        if not copy or GetGameTimer() >= endAt or torn[key] ~= t then return end

        -- The lights: its model's glow, on it at its own origin (the glow is in the pump's model space)
        local glowModel, brand = powerOf(t.model)
        local glow = nil
        if glowModel and IsModelInCdimage(glowModel) and exports.whip_core:LoadModel(glowModel, 2000) and DoesEntityExist(copy) then
            local p = GetEntityCoords(copy)
            glow = CreateObjectNoOffset(glowModel, p.x, p.y, p.z, false, false, false)
            SetEntityCollision(glow, false, false)
            AttachEntityToEntity(glow, copy, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
            SetModelAsNoLongerNeeded(glowModel)
        end
        -- The screen: ERROR over the side it was torn from, under its brand (a panel pump's: Config.PumpPanels)
        local held = brand ~= nil and Nozzle.screenHold(copy, key:sub(-1), brand)

        local function show(on)
            if glow and DoesEntityExist(glow) then SetEntityVisible(glow, on, false) end
            if held then Nozzle.screenShow(on) end
        end

        -- Lit, then the flicker: each step's time on or off, then the other way
        local on, at = true, startAt + POWER_MS
        for i = 0, #FLICKER do
            while GetGameTimer() < at and torn[key] == t do Wait(GetGameTimer() < at - 200 and 100 or 0) end
            if torn[key] ~= t then break end
            if i > 0 then
                on = not on
                show(on)
            end
            at = at + (FLICKER[i + 1] or 0)
        end

        if glow and DoesEntityExist(glow) then DeleteObject(glow) end
        if held then Nozzle.screenLetGo(copy) end
    end)
end

--- The island's pump as this game has it (a map prop), or nil once it is gone.
local function islandPump(t)
    local e = GetClosestObjectOfType(t.at.x, t.at.y, t.at.z, 1.0, t.model, false, false, false)
    if e and e ~= 0 and DoesEntityExist(e) and IsEntityVisible(e) then return e end
    return nil
end

--- Wait (from a thread) until `done()` answers, at most `ms`. Whether it did.
local function waitFor(done, ms)
    local untilAt = GetGameTimer() + ms
    while not done() do
        if GetGameTimer() >= untilAt then return false end
        Wait(0)
    end
    return true
end

--- This game drives the car that is tearing the pump off: the copy is made here, FROZEN, exactly inside the island's
--- pump (its place and turn as this game has them), and the server told once it is on the network (server/hose.lua
--- tornCopy). It can't be: told 0 and why, and the hose breaks off at the car. Nothing is hidden yet. (Its collision
--- stays on: frozen, it pushes nothing, and a prop's collision turned off and on again may not take its pull.)
RegisterNetEvent('whip_fuel:makeTornCopy', function(key, pumpEnd, tornModel)
    if type(key) ~= 'string' then return end
    -- The copy's model: a hash (config.lua's `whip_pump_torn`) or a name. Anything else is answered, never dropped:
    -- unanswered, the server holds the car for its whole wait
    if type(pumpEnd) ~= 'table' or (type(tornModel) ~= 'number' and type(tornModel) ~= 'string') then
        return TriggerServerEvent('whip_fuel:tornCopy', key, 0, 'the ask had no pump or no model')
    end
    local old = torn[key]
    if old then
        if old.started then return TriggerServerEvent('whip_fuel:tornCopy', key, 0, 'it is torn off already here') end
        -- From an ask the server gave up on (its answer lost): its copy goes, and this one is made afresh
        if old.copy and DoesEntityExist(old.copy) then DeleteEntity(old.copy) end
        torn[key] = nil
    end
    local at = v3(pumpEnd.worldPos)
    local model = tonumber(pumpEnd.model)
    local hash = at and model and exports.whip_core:LoadModel(tornModel, 1000)
    if not hash then return TriggerServerEvent('whip_fuel:tornCopy', key, 0, 'its model did not load') end
    local t = { at = at, model = model, maker = true }
    local fixed = islandPump(t)
    local pos = fixed and GetEntityCoords(fixed) or at
    local copy = CreateObjectNoOffset(hash, pos.x, pos.y, pos.z, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    if not copy or copy == 0 then return TriggerServerEvent('whip_fuel:tornCopy', key, 0, 'the game made no object') end
    FreezeEntityPosition(copy, true)
    SetEntityInvincible(copy, true)
    if fixed then
        local r = GetEntityRotation(fixed, 2)
        SetEntityRotation(copy, r.x, r.y, r.z, 2, true)
    else
        SetEntityHeading(copy, tonumber(pumpEnd.heading) or 0.0)
    end
    t.copy = copy
    torn[key] = t
    local networked = waitFor(function()
        return NetworkGetEntityIsNetworked(copy) and NetworkGetNetworkIdFromEntity(copy) ~= 0
    end, NETWORKED_WAIT_MS)
    t.copyNetId = NetworkGetNetworkIdFromEntity(copy)
    TriggerServerEvent('whip_fuel:tornCopy', key, t.copyNetId or 0,
        networked and '' or ('not on the network after %d ms'):format(NETWORKED_WAIT_MS))
end)

--- The server tied the hose to this game's copy: once this game's own hose is on it, the island's pump is hidden; once
--- that is gone, the copy is let go (unfrozen, woken) and the server told what was seen, so every game wakes it.
RegisterNetEvent('whip_fuel:tornCopyTied', function(key, ropeId)
    local t = type(key) == 'string' and torn[key]
    if not t or not t.maker or t.free then return end
    local copy = t.copy
    local tied = waitFor(function()
        local ok, e = pcall(function() return exports.whip_rope:GetRopeEndEntity(ropeId, 'origin') end)
        return ok and e == copy
    end, TIED_WAIT_MS)
    if torn[key] ~= t then return end
    hide(t)
    local gone = waitFor(function() return islandPump(t) == nil end, GONE_WAIT_MS)
    if torn[key] ~= t or not DoesEntityExist(copy) then return end
    t.free = true
    local owned = NetworkGetEntityOwner(copy) == PlayerId()
    if owned then wake(copy) end
    TriggerServerEvent('whip_fuel:tornCopyFree', key, tied, gone, owned)
end)

--- The server would not have the copy this game made (the nozzle was unplugged meanwhile, or the answer came too late):
--- forgotten here (the server deletes it), and the island's pump shown if it was hidden.
RegisterNetEvent('whip_fuel:tornCopyRefused', function(key)
    local t = type(key) == 'string' and torn[key]
    if not t or t.started then return end
    torn[key] = nil
    if t.hidden then RemoveModelHide(t.at.x, t.at.y, t.at.z, 1.5, t.model, false) end
end)

--- Let go by its maker (or the server's own clock): every game may wake it now.
RegisterNetEvent('whip_fuel:pumpFree', function(key)
    local t = type(key) == 'string' and torn[key]
    if t then t.free = true end
end)

RegisterNetEvent('whip_fuel:pumpTorn', function(key, pumpEnd, late, copyNetId, agoMs, free)
    if type(key) ~= 'string' or type(pumpEnd) ~= 'table' then return end
    local at = v3(pumpEnd.worldPos) or v3(pumpEnd.pos)
    local model = tonumber(pumpEnd.model)
    if not at or not model then return end

    -- The game that made the copy hides the island's pump itself, once its hose is on the copy (tornCopyTied); any
    -- other game hides it when the copy reaches it
    local t = torn[key]
    if t and t.started then return end
    if not t then
        t = { at = at, model = model }
        torn[key] = t
    end
    t.copyNetId, t.started = tonumber(copyNetId), true
    if free == true then t.free = true end
    if not t.maker then hideWhenHere(key) end
    wakeThread(key)

    -- Its power, from when it came away (a game coming in after that sees it dead)
    local ago = math.max(0, tonumber(agoMs) or 0)
    if ago < POWER_MS + FLICKER_MS then powerDown(key, GetGameTimer() - ago) end

    if not late and #(GetEntityCoords(PlayerPedId()) - at) < FIRE_REACH then
        if Config.Hose.FireAtBase == true then StartScriptFire(at.x, at.y, at.z, 25, false) end
        leak(key, at)
    end
end)

RegisterNetEvent('whip_fuel:pumpRepaired', function(pumpEnd)
    if type(pumpEnd) ~= 'table' then return end
    local at = v3(pumpEnd.worldPos) or v3(pumpEnd.pos)
    if not at then return end
    for key, t in pairs(torn) do
        if #(t.at - at) < 0.5 then
            torn[key] = nil
            if t.hidden then RemoveModelHide(t.at.x, t.at.y, t.at.z, 1.5, t.model, false) end
        end
    end
end)

-- whip_fuel stopping: every island pump this game hid shows again (the copies are the server's to delete)
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, t in pairs(torn) do
        if t.hidden then RemoveModelHide(t.at.x, t.at.y, t.at.z, 1.5, t.model, false) end
    end
end)
