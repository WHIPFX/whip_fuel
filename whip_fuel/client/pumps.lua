--[[
    Pumps on this game: a circle on each pump side and one on each side's nozzle. Each side has its own nozzle, and
    its circles offer what that nozzle allows:

      in its holster      nozzle: Take Nozzle; pump: Fill Jerry Can with the can in hand
      in a car            pump: amounts, then cash or bank; the pump fills the car, its screen shows progress
      filling             pump: Stop Refuelling
      in your hand        nozzle: Put Nozzle Away
      on the ground       pump: Start Refuelling (the spill); the side is then out of order a while
]]

Nozzle = {}

-- Tuning

local NOZZLE_HASH = GetHashKey('prop_cs_fuel_nozle')
Nozzle.HASH = NOZZLE_HASH

--- The hand bone (PH_R_Hand) the nozzle is tied to.
local HAND_BONE = 28422

--- The back of the nozzle, where a hose goes in, and its spout's tip, in the prop's own space.
Nozzle.HOSE_END = vector3(0.0, -0.027, -0.200)
local NOZZLE_SPOUT = vector3(0.002, 0.241, 0.160)
Nozzle.SPOUT = NOZZLE_SPOUT   -- client/car.lua: the tip goes in at a car's filler

local REFUEL_ANIM_DICT = 'timetable@gardener@filling_can'
local REFUEL_ANIM_CLIP = 'gar_ig_5_filling_can'

--- How often the pump thread wakes: the leash, the prices, the pump's screen.
local TICK_MS = 500

--- How long a price is trusted before it is asked for again.
local QUOTE_TTL_MS = 8000

--- How long before asking again about a car the server would not price.
local QUOTE_MISS_RETRY_MS = 2000

--- A car counts as "in view" for this long after something last asked about it.
local WANTED_TTL_MS = 1500

--- A car with a nozzle in it nearer than this is priced.
local QUOTE_RANGE = 15.0

--- After taking the nozzle, "Put Nozzle Away" ignores E for this long, so a double-tap does not hand it back.
local PUT_AWAY_GRACE_MS = 750

-- State

--- The nozzle in my hand: its side's key ('pump_<x>_<y>_<z>_A'), and where its pump is (the walk-away leash).
local myPump = nil
Nozzle.myKey = nil

--- What every busy side is doing, from the server: [key] = { n, h, car, obj, p, sp, err, gone }, and when each word came.
local faces, faceAt = {}, {}
Nozzle.faces = faces
Nozzle.faceAt = faceAt

--- Run after the nozzle in my hand or a side's word changes.
Nozzle.changed = function() end

--- A call to the server is in flight: its options ignore E till it answers.
Nozzle.busy = false
local starting = false   -- a fill or a spill being paid for

--- A jerry can is being filled at a pump, from the press until the server says it ended.
Nozzle.filling = false

--- When the walk-away was last told to the server (once, not every tick).
local dropSentAt = 0

--- No "Put Nozzle Away" before this game time.
local putAwayAfter = 0

--- Bumped on logout, so a server answer that lands under the next character is ignored.
local charEpoch = 0

--- What each nearby car costs to fill, by entity: { model, netId, units, price, perUnit, tank, at }, or { miss = true,
--- model, at } when the server would not price it.
local quotes = {}
Nozzle.quotes = quotes

--- [veh] = when something last asked about it. Only these get priced.
local wanted = {}

--- A quote is in flight. One at a time: the server allows a few a second.
local quoteInFlight = false

local myServerId = GetPlayerServerId(PlayerId())

local function core() return exports.whip_core end

--- The car (or any entity) with this network id on this game, or nil.
local function entityOf(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end
Nozzle.entityOf = entityOf

--- The key of the side whose nozzle is in this car (in it, or a torn pump's), or nil.
function Nozzle.inCar(veh)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    for key, i in pairs(faces) do
        if i.car == netId and (i.n == 'car' or i.n == 'torn') then return key end
    end
    return nil
end

--- The nozzle out of the hand at once on this game, without waiting for the server's drop.
function Nozzle.detach()
    if Whip.isReady() then core():DropOwnHeldProp(NOZZLE_HASH, 'nozzle') end
end

--- The pump a prop's prompt is on: its prefix ('pump_<x>_<y>_<z>', where it stands).
local function prefixOfEntity(entity)
    return Pumps.prefixOf(Pumps.keyOf(GetEntityCoords(entity), 'A'))
end

--- A pump blown up where it stands offers nothing, and its holsters and screen go.
local function pumpBroken(e)
    return e ~= nil and e ~= 0 and DoesEntityExist(e) and HasObjectBeenBroken(e)
end

--- The nozzle in a ped's hand, or nil.
local function heldNozzleOf(ped)
    local hand = GetPedBoneCoords(ped, HAND_BONE, 0.0, 0.0, 0.0)
    local obj = GetClosestObjectOfType(hand.x, hand.y, hand.z, 0.6, NOZZLE_HASH, false, false, false)
    if obj and obj ~= 0 and IsEntityAttachedToEntity(obj, ped) then return obj end
    return nil
end

--- A networked, loose nozzle made at `at` turned `rot` (it falls at once). Its network id, or 0.
function Nozzle.makeLoose(at, rot)
    local hash = core():LoadModel(NOZZLE_HASH, 1000)
    if not hash then return 0, nil end
    local obj = CreateObject(hash, at.x, at.y, at.z, true, true, false)
    if not obj or obj == 0 then return 0, nil end
    if rot then SetEntityRotation(obj, rot.x, rot.y, rot.z, 2, true) end
    SetEntityDynamic(obj, true)
    ActivatePhysics(obj)
    return NetworkGetNetworkIdFromEntity(obj), obj
end

--- GTA's petrol can: the jerry can in hand (whip_gunny equips it).
local JERRY_CAN = GetHashKey('WEAPON_PETROLCAN')

--- The same can as whip_gunny's item: what `require = { held = ... }` names.
Nozzle.JERRY_CAN_ITEM = 'jerry_can'

--- The jerry can in hand? `withFuel`: with some fuel in it, too (what pouring needs).
function Nozzle.jerryCanInHand(withFuel)
    local ped = PlayerPedId()
    if GetSelectedPedWeapon(ped) ~= JERRY_CAN then return false end
    return not withFuel or GetAmmoInPedWeapon(ped, JERRY_CAN) > 0
end

-- The panel pumps' holsters
-- Panel pumps (Config.PumpPanels) have empty holsters, so each game puts a nozzle in both holsters of every one it
-- tracks, on this game only: made as the pump comes into range, gone as it leaves.

--- Where the nozzle sits in each holster, in the pump's own space: side A looks along -y, side B along +y.
local HOLSTERS = {
    A = { pos = vector3(0.3447, -0.3744, 0.7044), rot = vector3(0.251, -0.076, 0.066) },
    B = { pos = vector3(-0.3447, 0.3655, 0.7044), rot = vector3(0.259, -0.077, -179.934) },
}

local holsters = {}   -- [prefix] = { pump = entity, brand, A = object, B = object }: every panel pump tracked

--- A pump's two holster nozzles shown or hidden, as their sides are.
local function holsterShow(prefix)
    local h = holsters[prefix]
    if not h then return end
    for side in pairs(HOLSTERS) do
        local obj = h[side]
        if obj and DoesEntityExist(obj) then
            -- Out of its holster, or its pump torn off its island
            local i = faces[prefix .. '_' .. side]
            SetEntityVisible(obj, not (i and (i.n or i.gone)), false)
        end
    end
end

--- Nozzles into both holsters of a panel pump just found.
local function holsterAdd(pump, model)
    if not DoesEntityExist(pump) or pumpBroken(pump) then return end
    local prefix = prefixOfEntity(pump)
    if holsters[prefix] then return end
    local h = { pump = pump, brand = Config.PumpPanels and Config.PumpPanels[model] }
    holsters[prefix] = h
    if not core():LoadModel(NOZZLE_HASH, 3000) then return end
    if holsters[prefix] ~= h or not DoesEntityExist(pump) then return end
    local p = GetEntityCoords(pump)
    for side, at in pairs(HOLSTERS) do
        local obj = CreateObjectNoOffset(NOZZLE_HASH, p.x, p.y, p.z, false, false, false)
        SetEntityCollision(obj, false, false)
        AttachEntityToEntity(obj, pump, 0, at.pos.x, at.pos.y, at.pos.z, at.rot.x, at.rot.y, at.rot.z,
            false, false, false, false, 2, true)
        h[side] = obj
    end
    SetModelAsNoLongerNeeded(NOZZLE_HASH)
    holsterShow(prefix)
end

--- A panel pump out of range (or blown up): its holsters' nozzles gone.
local function holsterDrop(prefix)
    local h = holsters[prefix]
    if not h then return end
    holsters[prefix] = nil
    for side in pairs(HOLSTERS) do
        if h[side] and DoesEntityExist(h[side]) then DeleteObject(h[side]) end
    end
end

--- Pumps blown up where they stand lose their holster nozzles (and so their screen).
local function holstersCheck()
    local gone = {}
    for prefix, h in pairs(holsters) do
        if not DoesEntityExist(h.pump) or pumpBroken(h.pump) then gone[#gone + 1] = prefix end
    end
    for _, prefix in ipairs(gone) do holsterDrop(prefix) end
end

-- The panel pumps' screens
-- Every busy side near you draws what its nozzle is doing over its LCD, on this game only. All screens come from one
-- browser (html/pump3d/pump_lcd.html) laid out as an atlas of cells: the nearest busy side takes the full-size cell,
-- the rest half-size ones, up to SCREEN_RANGE. Each is drawn as a world quad (WorldQuad). The browser is made when a
-- screen is first wanted and given back SCREEN_IDLE_MS after the last one went.

local SCREEN_TXD, SCREEN_TEX = 'whip_pump_dui', 'screen'
--- The atlas (pixels), and its cells { x, y, w, h }: the first full size (640 x 512), the rest half.
local ATLAS_W, ATLAS_H = 1280, 1024
local CELLS = { { 0, 0, 640, 512 } }
for i = 0, 3 do CELLS[#CELLS + 1] = { 640 + (i % 2) * 320, (i // 2) * 256, 320, 256 } end
for i = 0, 7 do CELLS[#CELLS + 1] = { (i % 4) * 320, 512 + (i // 4) * 256, 320, 256 } end
for _, c in ipairs(CELLS) do
    c.u0, c.v0, c.u1, c.v1 = c[1] / ATLAS_W, c[2] / ATLAS_H, (c[1] + c[3]) / ATLAS_W, (c[2] + c[4]) / ATLAS_H
end
--- Each side's LCD in the pump's own space: its centre 2 mm out of the face, which way the viewer's right is across
--- it, and its size in metres.
local SCREEN_AT = {
    A = { x = -0.2744, y = -0.2419, z = 1.249, right = 1.0 },   -- looks along the pump's -y
    B = { x = 0.2744, y = 0.2419, z = 1.249, right = -1.0 },    -- along its +y
}
local SCREEN_W, SCREEN_H = 0.38, 0.304
--- A busy side further than this shows nothing on your game.
local SCREEN_RANGE = 20.0
--- The thank-you screen stays up this long after a side is done.
local SCREEN_THANKS_MS = 4000
--- The browser is given back this long after the last screen went.
local SCREEN_IDLE_MS = 15000
--- A browser that would not come up is not asked for again for this long.
local SCREEN_RETRY_MS = 30000

local screenDui, screenUp = nil, false
local screenWantedAt, screenRefusedAt = 0, -SCREEN_RETRY_MS
--- What is on screen: [key] = { cell, pump, side, brand, number, quad, moves, text, sent, thanksAt, visible }. A torn
--- pump's error screen has the key 'torn'.
local shown = {}
local screenHeld = nil   -- a torn pump's ERROR (Nozzle.screenHold): { pump, side, brand, visible }
local drawing = false

--- Every screen gone, and the browser.
local function screenRelease()
    shown = {}
    screenUp = false
    if screenDui then DestroyDui(screenDui) end
    screenDui = nil
end

--- The browser made (not waited on: screens draw once it is up).
local function screenEnsure()
    if screenDui then return true end
    if GetGameTimer() - screenRefusedAt < SCREEN_RETRY_MS then return false end
    local cells = {}
    for i, c in ipairs(CELLS) do cells[i] = ('%d,%d,%d,%d'):format(c[1], c[2], c[3], c[4]) end
    local dui = CreateDui(('nui://%s/html/pump3d/pump_lcd.html?atlas=%dx%d&cells=%s'):format(GetCurrentResourceName(),
        ATLAS_W, ATLAS_H, table.concat(cells, ';')), ATLAS_W, ATLAS_H)
    if not dui then
        screenRefusedAt = GetGameTimer()
        return false
    end
    screenDui, screenUp = dui, false
    CreateThread(function()
        local deadline = GetGameTimer() + 5000
        while screenDui == dui and not IsDuiAvailable(dui) and GetGameTimer() < deadline do Wait(50) end
        if screenDui ~= dui then return end
        if not IsDuiAvailable(dui) then
            screenRefusedAt = GetGameTimer()
            screenRelease()
            return
        end
        -- The texture is made once the page is up, or the screen is blank.
        CreateRuntimeTextureFromDuiHandle(CreateRuntimeTxd(SCREEN_TXD), SCREEN_TEX, GetDuiHandle(dui))
        screenUp = true
        for _, s in pairs(shown) do
            if s.text then
                SendDuiMessage(dui, s.text)
                s.sent = s.text
            end
        end
    end)
    return true
end

--- Where side `side`'s LCD is on `pump` now: { centre, right, up } in the world, for WorldQuad.draw.
local function lcdQuad(pump, side)
    local at = SCREEN_AT[side]
    local r, f, u, p = GetEntityMatrix(pump)
    return {
        p.x + r.x * at.x + f.x * at.y + u.x * at.z, p.y + r.y * at.x + f.y * at.y + u.y * at.z,
        p.z + r.z * at.x + f.z * at.y + u.z * at.z,
        r.x * at.right, r.y * at.right, r.z * at.right,
        u.x, u.y, u.z,
    }
end

--- Each frame while anything is on screen: every screen from its cell.
local function drawScreens()
    if drawing then return end
    drawing = true
    CreateThread(function()
        while next(shown) do
            if screenUp then
                for _, s in pairs(shown) do
                    if s.visible ~= false and DoesEntityExist(s.pump) then
                        local q = s.moves and lcdQuad(s.pump, s.side) or s.quad
                        local c = CELLS[s.cell]
                        WorldQuad.draw(SCREEN_TXD, SCREEN_TEX, q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8], q[9],
                            SCREEN_W, SCREEN_H, c.u0, c.v0, c.u1, c.v1, 255, 255, 255, 255)
                    end
                end
            end
            Wait(0)
        end
        drawing = false
    end)
end

--- The pump's number: from where it stands, odd on one side and even on the other.
local function pumpNumber(pump, side)
    local p = GetEntityCoords(pump)
    return (math.floor(math.abs(p.x) + math.abs(p.y)) % 8 + 1) * 2 - (side == 'A' and 1 or 0)
end

--- What a busy side's screen says.
local function screenMessage(key, info)
    local now = GetGameTimer()
    local since = (now - (faceAt[key] or now)) / 1000
    if info.p then
        local p = math.min(1.0, ((info.p.e or 0) + since) / math.max(1, info.p.s or 1))
        return { state = 'fueling', progress = math.floor(p * 20) / 20 }
    end
    if info.err then return { state = 'error', seconds = math.max(0, math.ceil(info.err - since)) } end
    if info.n == 'car' then
        local q = quotes[entityOf(info.car)]
        if q and not q.miss then
            if (q.units or 0) > 0 then return { state = 'pay', price = q.units * (q.perUnit or 0) } end
            return { state = 'return_nozzle' }   -- full: the nozzle can come out
        end
        return { state = 'nozzle_out' }
    end
    if info.n == 'ground' then return { state = 'return_nozzle' } end
    if info.n == 'hand' then return { state = 'nozzle_out' } end
    return { state = 'idle' }
end

--- Which sides are on screen, in which cell, saying what: every busy side within SCREEN_RANGE, a side just done, and a
--- torn pump's error. The nearest takes the full-size cell, the rest keep their cell or take a free one. Distance is
--- measured to each side's own screen.
local function screenTick()
    local now = GetGameTimer()
    local me = GetEntityCoords(PlayerPedId())
    local want = {}
    --- `key`'s screen on `pump` (reused while it is on the same pump), and how far it is.
    local function sideAt(key, pump, side, moves)
        local old = shown[key]
        local q = (not moves and old and old.pump == pump and old.quad) or lcdQuad(pump, side)
        local dx, dy, dz = q[1] - me.x, q[2] - me.y, q[3] - me.z
        return q, math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    for key, info in pairs(faces) do
        if not info.gone then
            local h = holsters[Pumps.prefixOf(key)]
            -- The pump's middle first, so a far pump costs nothing.
            if h and h.pump and DoesEntityExist(h.pump) and #(GetEntityCoords(h.pump) - me) < SCREEN_RANGE + 1.0 then
                local side = key:sub(-1)
                local q, d = sideAt(key, h.pump, side)
                if d < SCREEN_RANGE then
                    want[#want + 1] = { key = key, d = d, quad = q, pump = h.pump, side = side, brand = h.brand,
                                        msg = screenMessage(key, info) }
                end
            end
        end
    end
    -- Done: thank-you a moment where it was.
    for key, s in pairs(shown) do
        if key ~= 'torn' and not faces[key] and DoesEntityExist(s.pump) then
            s.thanksAt = s.thanksAt or now
            local q, d = sideAt(key, s.pump, s.side)
            if now - s.thanksAt < SCREEN_THANKS_MS and d < SCREEN_RANGE then
                want[#want + 1] = { key = key, d = d, quad = q, pump = s.pump, side = s.side, brand = s.brand,
                                    msg = { state = 'thanks' }, thanksAt = s.thanksAt }
            end
        end
    end
    local held = screenHeld
    if held and DoesEntityExist(held.pump) then
        local _, d = sideAt('torn', held.pump, held.side, true)
        if d < SCREEN_RANGE then
            want[#want + 1] = { key = 'torn', d = d, pump = held.pump, side = held.side, brand = held.brand,
                                msg = { state = 'error' }, moves = true }
        end
    end

    if #want == 0 then
        if screenUp then
            for _, s in pairs(shown) do SendDuiMessage(screenDui, json.encode({ cell = s.cell - 1, state = 'off' })) end
        end
        if next(shown) then shown = {} end
        if screenDui and now - screenWantedAt > SCREEN_IDLE_MS then screenRelease() end
        return
    end
    screenWantedAt = now
    if not screenEnsure() then return end
    table.sort(want, function(a, b) return a.d < b.d end)

    -- Cells: the nearest the full-size one; the rest keep a half-size one they had, else take the first free.
    local n = math.min(#want, #CELLS)
    local cellOf, taken = {}, {}
    for i = 1, n do
        local old = shown[want[i].key]
        local cell = (i == 1 and 1) or (old and old.cell ~= 1 and old.cell) or nil
        if cell then cellOf[i], taken[cell] = cell, true end
    end
    local free = 2
    for i = 2, n do
        if not cellOf[i] then
            while taken[free] do free = free + 1 end
            cellOf[i], taken[free] = free, true
        end
    end

    local was = shown
    shown = {}
    for i = 1, n do
        local w = want[i]
        local old = was[w.key]
        local same = old and old.pump == w.pump
        local s = {
            cell = cellOf[i], pump = w.pump, side = w.side, brand = w.brand, moves = w.moves, thanksAt = w.thanksAt,
            number = same and old.number or pumpNumber(w.pump, w.side),
            quad = (not w.moves) and w.quad or nil,
            visible = w.key ~= 'torn' or held.visible,
        }
        local msg = w.msg
        msg.cell, msg.pump, msg.brand = s.cell - 1, s.number, s.brand or 'LTD'
        s.text = json.encode(msg)
        s.sent = old and old.cell == s.cell and old.sent or nil
        if screenUp and s.text ~= s.sent then
            SendDuiMessage(screenDui, s.text)
            s.sent = s.text
        end
        shown[w.key] = s
    end
    -- Cells no side has now: off
    if screenUp then
        for _, s in pairs(was) do
            if not taken[s.cell] then SendDuiMessage(screenDui, json.encode({ cell = s.cell - 1, state = 'off' })) end
        end
    end
    drawScreens()
end

--- A pump torn off its island: error over side `side` of `pump` (its loose copy), under its `brand`, till
--- Nozzle.screenLetGo. False when it has no screen.
function Nozzle.screenHold(pump, side, brand)
    if not pump or not DoesEntityExist(pump) or not SCREEN_AT[side] then return false end
    screenHeld = { pump = pump, side = side, brand = brand, visible = true }
    screenTick()
    return true
end

--- The held screen shown or hidden (the torn pump's power flickering out).
function Nozzle.screenShow(on)
    if not screenHeld then return end
    screenHeld.visible = on
    if shown.torn then shown.torn.visible = on end
end

--- The torn pump's power gone: its screen too.
function Nozzle.screenLetGo(pump)
    if not screenHeld or screenHeld.pump ~= pump then return end
    screenHeld = nil
    screenTick()
end

-- The spill: fuel on the floor
-- A spill (the server's pour with `spray`) comes out of the nozzle in a hand or on the ground and shows on every game
-- near it: the pour out of the spout, and petrol decals where the stream lands (which burn). In a hand it goes where
-- the nozzle points and shakes the holder's view; on the ground the nozzle lashes about on its hose.

local SPRAY_RANGE = 60.0
local SPRAY_DECAL_MS = 200   -- a petrol decal where the stream lands this often
local SPRAY_KICK_MS = 70     -- the loose nozzle kicked this often
local SPRAY_THRUST = 1.8     -- back out of the spout, each kick (an impulse on a ~1 kg nozzle)
local SPRAY_THRASH = 1.7     -- and that much again, any way at all
local SPRAY_LIFT = { 0.8, 2.6 }   -- and up
local SPRAY_TOP_SPEED = 12.0 -- m/s: no more kicks past it (its hose holds it, mostly)
local STREAM_SPEED = 7.0     -- m/s out of the spout, for where the stream lands

local sprays = {}            -- [key] = { fx, obj, decalAt, kickAt, shaking }
local sprayRunning = false

local function sprayStop(key)
    local s = sprays[key]
    if s and s.fx then StopParticleFxLooped(s.fx, false) end
    if s and s.shaking then StopGameplayCamShaking(false) end
    sprays[key] = nil
end

--- The nozzle a spraying side's fuel comes out of: on the ground, or in its holder's hand.
local function sprayNozzle(key, info)
    if info.n == 'ground' then return entityOf(info.obj) end
    if info.n ~= 'hand' or not info.h then return nil end
    local ped
    if info.h == myServerId then
        ped = PlayerPedId()
    else
        -- Whip.playerIndex, not GetPlayerFromServerId alone: on Enhanced an unknown player answers 0, often the local player.
        local p = Whip.playerIndex(info.h)
        ped = p and NetworkIsPlayerActive(p) and GetPlayerPed(p) or nil
    end
    if not ped or ped == 0 then return nil end
    local s = sprays[key]
    if s and s.obj and DoesEntityExist(s.obj) and IsEntityAttachedToEntity(s.obj, ped) then return s.obj end
    return heldNozzleOf(ped)
end

--- Where the stream out of this nozzle lands: along the spout, falling, the first thing it meets. Or nil.
local function streamLands(obj)
    local tip = GetOffsetFromEntityInWorldCoords(obj, NOZZLE_SPOUT.x, NOZZLE_SPOUT.y, NOZZLE_SPOUT.z)
    local ahead = GetOffsetFromEntityInWorldCoords(obj, NOZZLE_SPOUT.x, NOZZLE_SPOUT.y + 1.0, NOZZLE_SPOUT.z)
    local v = (ahead - tip) * STREAM_SPEED
    local from = tip
    for i = 1, 16 do
        local t = i * 0.08
        local to = tip + v * t + vector3(0.0, 0.0, -4.9 * t * t)
        local _, hit, at = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z,
            to.x, to.y, to.z, 1 + 16, obj, 4))
        if hit == 1 then return at end
        from = to
    end
    return nil
end

--- One thread while anything sprays near here, every frame.
local function startSprayThread()
    if sprayRunning then return end
    sprayRunning = true
    CreateThread(function()
        local function r(a, b) return a + math.random() * (b - a) end
        while true do
            local any = false
            local now = GetGameTimer()
            local me = GetEntityCoords(PlayerPedId())
            for key, info in pairs(faces) do
                local obj = info.p and info.p.spray and sprayNozzle(key, info) or nil
                if obj and #(GetEntityCoords(obj) - me) < SPRAY_RANGE then
                    any = true
                    local s = sprays[key]
                    if not s then
                        s = { decalAt = 0, kickAt = 0 }
                        sprays[key] = s
                    end
                    if not s.fx or s.obj ~= obj then
                        if s.fx then StopParticleFxLooped(s.fx, false) end
                        s.fx = nil
                        RequestNamedPtfxAsset('core')
                        if HasNamedPtfxAssetLoaded('core') then
                            UseParticleFxAsset('core')
                            s.fx = StartParticleFxLoopedOnEntity('weap_petrol_can', obj, NOZZLE_SPOUT.x, NOZZLE_SPOUT.y,
                                NOZZLE_SPOUT.z, 0.0, 0.0, 0.0, 1.0, false, false, false)
                            s.obj = obj
                        end
                    end
                    if now >= s.decalAt then
                        s.decalAt = now + SPRAY_DECAL_MS
                        local at = streamLands(obj)
                        if at then AddPetrolDecal(at.x, at.y, at.z, 2.0, 1.5, 0.8) end
                    end
                    -- In my own hand: the view shakes with it
                    local mine = info.n == 'hand' and info.h == myServerId
                    if mine and not s.shaking then
                        ShakeGameplayCam('HAND_SHAKE', 1.2)
                        s.shaking = true
                    elseif not mine and s.shaking then
                        StopGameplayCamShaking(false)
                        s.shaking = false
                    end
                    -- On the ground: the hose nobody is holding
                    if info.n == 'ground' and now >= s.kickAt and NetworkGetEntityOwner(obj) == PlayerId()
                        and #GetEntityVelocity(obj) < SPRAY_TOP_SPEED then
                        s.kickAt = now + SPRAY_KICK_MS
                        local tip = GetOffsetFromEntityInWorldCoords(obj, NOZZLE_SPOUT.x, NOZZLE_SPOUT.y, NOZZLE_SPOUT.z)
                        local back = GetOffsetFromEntityInWorldCoords(obj, 0.0, -1.0, 0.0) - GetEntityCoords(obj)
                        local f = back * SPRAY_THRUST
                            + vector3(r(-SPRAY_THRASH, SPRAY_THRASH), r(-SPRAY_THRASH, SPRAY_THRASH), r(SPRAY_LIFT[1], SPRAY_LIFT[2]))
                        -- At the spout's tip, so it spins as well as flies
                        local o = tip - GetEntityCoords(obj)
                        ApplyForceToEntity(obj, 1, f.x, f.y, f.z, o.x, o.y, o.z, 0, false, true, true, false, true)
                    end
                elseif sprays[key] then
                    sprayStop(key)
                end
            end
            for key in pairs(sprays) do
                if not faces[key] then sprayStop(key) end
            end
            if not any and next(sprays) == nil then break end
            Wait(0)
        end
        sprayRunning = false
    end)
end

-- A nozzle on the ground: "Pick Up Nozzle"

local groundPrompts = {}   -- [key] = the network id its prompt rides

local function groundId(key) return 'ground:' .. key end

--- The side's ground nozzle has its prompt while it lies there (not a torn pump's), and none otherwise.
local function groundPrompt(key)
    local info = faces[key]
    local want = info and info.n == 'ground' and info.obj or nil
    local had = groundPrompts[key]
    if had == want then return end
    if had and Whip.isReady() then core():RemoveAction(groundId(key)) end
    groundPrompts[key] = nil
    if not want or not Whip.isReady() then return end
    local ok = core():AddAction({
        id = groundId(key),
        at = { netId = want, offset = vector3(0.0, 0.0, 0.25) },
        label = 'Pick Up Nozzle',
        icon = 'nozzle',
        seeFrom = 4.0,
        reach = 1.8,
        canInteract = function()
            local i = faces[key]
            return i ~= nil and i.n == 'ground' and not Nozzle.myKey and not Nozzle.busy
        end,
        onSelect = function(ctx)
            if Nozzle.busy or Nozzle.myKey then return end
            Nozzle.busy = true
            -- A weapon in the hands is put away first, or it would drop the nozzle
            if not core():FreeHands() then
                Nozzle.busy = false
                ctx.refuse('Your hands are full')
                return
            end
            local ok2, why = core():Callback('whip_fuel:pickUp', key)
            Nozzle.busy = false
            if ok2 ~= true then ctx.refuse(why or 'Could not pick it up') end
        end,
    })
    if ok then groundPrompts[key] = want end
end

-- The nozzle in your hand
-- X drops it; the fists are put away meanwhile. Anything else in the hands (a weapon, the phone, getting into a car,
-- being knocked down) drops it too. One thread, while it is in your hand.

local HOLD_HINT = '[X] Drop the nozzle'

local UNARMED = GetHashKey('WEAPON_UNARMED')

--- Held off while the nozzle is in your hand: the fists (attacks, melee, R) and aiming them.
local HOLD_BLOCKED = { 24, 25, 140, 141, 142, 143, 257, 263, 264 }

--- The list whip_core holds off for the nozzle (BlockControls 'nozzle'), nil for none; asked again till it takes it.
local blockedAs = nil
local function blockFor(list)
    if list == blockedAs then return end
    local ok
    if list then ok = Whip.call('BlockControls', 'nozzle', { controls = list }) else ok = Whip.call('UnblockControls', 'nozzle') end
    if ok == true or not list then blockedAs = list end
end

local holding = false

--- The nozzle out of my hand onto the ground, made here so it falls at once. X, the leash, death.
local function dropNozzle()
    if not Nozzle.myKey then return end
    local now = GetGameTimer()
    if now - dropSentAt < 1500 then return end
    dropSentAt = now
    CreateThread(function()
        local ped = PlayerPedId()
        local held = heldNozzleOf(ped)
        local at = held and GetEntityCoords(held) or GetPedBoneCoords(ped, HAND_BONE, 0.0, 0.0, 0.0)
        local rot = held and GetEntityRotation(held, 2) or nil
        Nozzle.detach()
        local netId, obj = Nozzle.makeLoose(at, rot)
        if obj then SetEntityVelocity(obj, GetEntityVelocity(ped)) end   -- it carries on a little with you
        TriggerServerEvent('whip_fuel:drop', netId)
    end)
end

-- The hose pulled from my hand by whip_rope (dragged along behind a torn pump, then let go): the nozzle drops there
AddEventHandler('whip_rope:pulledFromHand', function(_, _, resource)
    if resource == GetCurrentResourceName() and Nozzle.myKey then dropNozzle() end
end)

local function startHoldThread()
    if holding then return end
    holding = true
    CreateThread(function()
        core():ShowText(HOLD_HINT, { position = 'bottom', icon = 'nozzle' })
        -- The hold walk while it is in the hand
        local walk = Config.Pump.HoldWalk
        if walk then core():SetWalkOverride(walk) end
        while Nozzle.myKey do
            local ped = PlayerPedId()
            -- Fists away, and X drops it
            blockFor(HOLD_BLOCKED)
            if IsDisabledControlJustPressed(0, 73) or IsControlJustPressed(0, 73) then dropNozzle() end
            -- Getting into a car, knocked down, or a weapon drawn drops it. (Dragged behind a torn pump, whip_rope
            -- lets go itself: whip_rope:pulledFromHand.)
            local mine = faces[Nozzle.myKey]
            if GetSelectedPedWeapon(ped) ~= UNARMED or IsPedInAnyVehicle(ped, true)
                or (IsPedRagdoll(ped) and not (mine and mine.gone)) then
                dropNozzle()
            end
            Wait(0)
        end
        blockFor(nil)
        if Whip.isReady() then
            core():HideText()
            if walk then core():SetWalkOverride(nil) end
        end
        holding = false
    end)
end

-- Something else needs the hands (whip_core's FreeHands: the phone coming out): the nozzle drops
local function onFreeHands()
    if not Nozzle.myKey then return end
    dropNozzle()
end

-- What the server says

--- The pump's and nozzle's circles, re-added with what can apply now.
local refreshCircles

--- Something a circle or a car offer reads changed: each puts up what can apply now.
local function stateChanged()
    if refreshCircles then refreshCircles() end
    Nozzle.changed()
end

--- One side changed: its holster, ground prompt, spill; the price of a car whose fill ended.
local function faceChanged(key, info)
    local old = faces[key]
    faces[key] = type(info) == 'table' and info or nil
    faceAt[key] = GetGameTimer()
    if old and old.p and old.car and not (info and info.p) then
        local veh = entityOf(old.car)
        if veh then quotes[veh] = nil end   -- the price is stale the moment fuel moves
    end
    holsterShow(Pumps.prefixOf(key))
    groundPrompt(key)
    if info and info.p and info.p.spray then startSprayThread() end
    stateChanged()
end

RegisterNetEvent('whip_fuel:face', function(key, info)
    if type(key) ~= 'string' then return end
    faceChanged(key, info)
end)

--- What is in my hand: a nozzle's key and its pump's point, or nothing.
RegisterNetEvent('whip_fuel:hand', function(key, pump)
    Nozzle.myKey = type(key) == 'string' and key or nil
    myPump = Nozzle.myKey and type(pump) == 'table' and vector3(pump.x + 0.0, pump.y + 0.0, pump.z + 0.0) or nil
    if Nozzle.myKey then startHoldThread() else Nozzle.detach() end
    stateChanged()
end)

--- Every busy side now, at a character's load.
local function facesFetch()
    CreateThread(function()
        if not Whip.ready(30000) then return end
        local list = core():Callback('whip_fuel:faces')
        if type(list) ~= 'table' then return end
        local keys = {}
        for key in pairs(faces) do keys[key] = true end
        for key in pairs(list) do keys[key] = true end
        for key in pairs(keys) do
            if type(key) == 'string' then faceChanged(key, list[key]) end
        end
    end)
end

--- Everything forgotten: the server cleared every nozzle (whip_fuel stopping).
RegisterNetEvent('whip_fuel:reset', function()
    for key in pairs(faces) do faceChanged(key, nil) end
    Nozzle.myKey, myPump = nil, nil
    Nozzle.detach()
    stateChanged()
end)

-- At the pump

--- The side a pump circle is on, as the server names them (shared/pumps.lua), cached by circle, prop and face.
local keyCache = {}
local function keyOfCtx(ctx)
    local e = ctx.entity
    if not e or e == 0 or not DoesEntityExist(e) then return nil end
    local cacheKey = tostring(ctx.id) .. '#' .. tostring(ctx.prop) .. '#' .. tostring(ctx.face)
    local k = keyCache[cacheKey]
    if k then return k end
    k = Pumps.keyOf(GetEntityCoords(e), Pumps.sideOfFace(ctx.model, ctx.face, ctx.id ~= 'pump'))
    keyCache[cacheKey] = k
    return k
end

local function free() return not Nozzle.busy and not starting and not Nozzle.filling end

--- Ask the server for this side's nozzle, and say what happened on the circle.
local function takeNozzle(ctx)
    if Nozzle.myKey or Nozzle.busy then return end
    local e = ctx.entity
    if not e or not DoesEntityExist(e) then return end
    local key = keyOfCtx(ctx)
    local at, model, heading = GetEntityCoords(e), GetEntityModel(e), GetEntityHeading(e)
    local epoch = charEpoch
    Nozzle.busy = true
    -- A weapon in the hands is put away first, or it would drop the nozzle
    if not core():FreeHands() then
        Nozzle.busy = false
        ctx.flash(230, 70, 70)
        ctx.status('Your hands are full', 2500)
        return
    end
    local ok, why = core():Callback('whip_fuel:takeNozzle', key:sub(-1), at.x, at.y, at.z, model, at.x, at.y, at.z, heading)
    Nozzle.busy = false

    -- A different character now: hand the nozzle back rather than leave one nobody knows about.
    if epoch ~= charEpoch then
        if ok == true then TriggerServerEvent('whip_fuel:nozzleAway') end
        return
    end
    if ok ~= true then
        ctx.flash(230, 70, 70)
        ctx.status(why or 'No answer from the pump', 2500)
        return
    end
    -- The server says so too (whip_fuel:hand); this turns the circle at once.
    Nozzle.myKey, myPump = key, at
    putAwayAfter = GetGameTimer() + PUT_AWAY_GRACE_MS
    startHoldThread()
    ctx.flash(60, 220, 90)
    ctx.status('Nozzle out', 2000)
end

--- This side's nozzle in a car: pour `amount` ('full', '25', '50', '75'), paid now by `payment`, change back at the end.
local function startPumping(ctx, key, amount, payment)
    if starting then return end
    starting = true
    -- { seconds, price }, or false and why
    local res, why = core():Callback('whip_fuel:start', key, amount, payment)
    starting = false
    if type(res) ~= 'table' then
        local i = faces[key]
        local veh = i and entityOf(i.car)
        if veh then quotes[veh] = nil end   -- the server disagreed with the price (a full tank, a car gone)
        ctx.flash(230, 70, 70)
        ctx.status(why or 'Cannot refuel that', 2500)
        return
    end
    ctx.flash(60, 220, 90)
    ctx.status(('Refuelling — $%d'):format(res.price or 0), 2500)
end

--- The spill: this side's nozzle on the ground or in a hand, started anyway (paid for).
local function startSpray(ctx, key, payment)
    if starting then return end
    starting = true
    local res, why = core():Callback('whip_fuel:spray', key, payment)
    starting = false
    if type(res) ~= 'table' then
        ctx.flash(230, 70, 70)
        ctx.status(why or 'Nothing happened', 2500)
    end
end

-- The jerry can's animation
local function playRefuelAnim()
    if not core():LoadAnimDict(REFUEL_ANIM_DICT, 2000) then return end
    -- 49 = loop + upper body + legs free: walking away ends a fill.
    TaskPlayAnim(PlayerPedId(), REFUEL_ANIM_DICT, REFUEL_ANIM_CLIP, 8.0, -8.0, -1, 49, 0, false, false, false)
end

local function stopRefuelAnim()
    StopAnimTask(PlayerPedId(), REFUEL_ANIM_DICT, REFUEL_ANIM_CLIP, 3.0)
    RemoveAnimDict(REFUEL_ANIM_DICT)
end

--- Fill the can in hand at this pump. The server runs the bar and takes the money (whip_fuel:fillCan);
--- whip_fuel:canFillEnded closes it here.
local function fillCan(ctx, payment)
    if Nozzle.filling or Nozzle.myKey or Nozzle.busy then return end
    local e = ctx.entity
    if not e or not DoesEntityExist(e) then return end
    local at = GetEntityCoords(e)
    Nozzle.filling = true
    playRefuelAnim()
    TriggerServerEvent('whip_fuel:fillCan', payment, at.x, at.y, at.z)
    -- Backstop: an answer lost to a restart must not leave the pump refusing for good.
    local epoch = charEpoch
    SetTimeout(60000, function()
        if Nozzle.filling and epoch == charEpoch then
            Nozzle.filling = false
            stopRefuelAnim()
        end
    end)
end

RegisterNetEvent('whip_fuel:canFillEnded', function()
    if not Nozzle.filling then return end
    Nozzle.filling = false
    stopRefuelAnim()
end)

--- Cash or bank: the two choices under every option that is paid for (a Back comes first, by itself).
local PAY = {
    { id = 'cash', icon = 'cash', label = 'Pay Cash' },
    { id = 'bank', icon = 'bank', label = 'Pay by Bank' },
}

--- One of the pump's amounts while its nozzle is in a car: 'full', or '25' / '50' / '75' percent of the tank added.
--- Priced from the car's quote. An amount that would fill the tank anyway is not offered.
local function amountOption(amount)
    local function unitsNow(key)
        local i = faces[key]
        local q = i and i.n == 'car' and quotes[entityOf(i.car)]
        if not q or q.miss then return nil, q end
        if amount == 'full' then return q.units, q end
        return math.min(q.units, math.ceil((q.tank or 100) * tonumber(amount) / 100)), q
    end
    return {
        id    = 'fill' .. amount,
        icon  = 'fuel',
        label = function(ctx)
            local n, q = unitsNow(keyOfCtx(ctx))
            if amount == 'full' then
                return n and ('Fill Up  $%d'):format(n * (q.perUnit or 0)) or 'Fill Up'
            end
            return ('Add %s%%  $%d'):format(amount, (n or 0) * ((q and q.perUnit) or 0))
        end,
        canInteract = function(ctx)
            local key = keyOfCtx(ctx)
            local i = key and faces[key]
            if not i or i.n ~= 'car' or i.p or i.err or not free() then return false end
            local n, q = unitsNow(key)
            if amount == 'full' then return n ~= 0 end
            return n ~= nil and n > 0 and n < q.units
        end,
        options = PAY,
        onSelect = function(ctx) startPumping(ctx, keyOfCtx(ctx), amount, ctx.option) end,
    }
end

--- What a side's state is: its face info (nil while its nozzle hangs idle) and its key.
local function info(ctx)
    local key = keyOfCtx(ctx)
    return key and faces[key], key
end

--- What the nozzle's circle offers: Take Nozzle while it hangs there, Put Nozzle Away while it is in your hand.
--- `hand`: a nozzle is in the hand.
---@param hand boolean
local function nozzleOptions(hand)
    if not hand then
        return { {
            id    = 'take',
            icon  = 'nozzle',
            label = 'Take Nozzle',
            canInteract = function(ctx) return info(ctx) == nil and not Nozzle.myKey and free() end,
            onSelect = takeNozzle,
        } }
    end
    return {
        {
            id    = 'putaway',
            icon  = 'nozzle',
            label = 'Put Nozzle Away',
            -- Not while it sprays: stop the pump first
            canInteract = function(ctx)
                local i, key = info(ctx)
                return key ~= nil and Nozzle.myKey == key and not (i and i.p)
            end,
            -- The grace is here, not in the condition, or the circle would blink out and back.
            onSelect = function()
                if not Nozzle.myKey or GetGameTimer() < putAwayAfter then return end
                Nozzle.detach()
                TriggerServerEvent('whip_fuel:nozzleAway')
            end,
        },
    }
end

--- What a pump's circle offers, from what its side's nozzle is doing. With no busy side near (`busy` false), only
--- Fill Jerry Can: everything else needs a nozzle out of its holster.
---@param busy boolean
local function pumpOptions(busy)
    local fill = {
        -- The jerry can in hand is filled here (fillCan).
        id    = 'fillcan',
        icon  = 'fuel',
        label = 'Fill Jerry Can',
        require = { held = Nozzle.JERRY_CAN_ITEM },
        canInteract = function(ctx)
            local i = info(ctx)
            return not Nozzle.myKey and free() and Nozzle.jerryCanInHand() and not (i and (i.err or i.gone))
        end,
        options = PAY,
        -- No hand press: filling plays its own looped animation, which the press would cut short
        press = false,
        onSelect = function(ctx) fillCan(ctx, ctx.option) end,
    }
    if not busy then return { fill } end
    return {
        fill,
        -- Its nozzle in a car: how much (startPumping). Full first, so E is the quick path.
        {
            id    = 'tankfull',
            icon  = 'fuel',
            label = 'Tank Is Full',
            canInteract = function(ctx)
                local i = info(ctx)
                local q = i and i.n == 'car' and not i.p and quotes[entityOf(i.car)]
                return q and not q.miss and q.units == 0 or false
            end,
            onSelect = function() end,
        },
        amountOption('full'),
        amountOption('25'),
        amountOption('50'),
        amountOption('75'),
        {
            id    = 'stop',
            icon  = 'fuel',
            label = 'Stop Refuelling',
            canInteract = function(ctx) local i = info(ctx) return i ~= nil and i.p ~= nil end,
            onSelect = function(ctx) TriggerServerEvent('whip_fuel:stop', keyOfCtx(ctx)) end,
        },
        {
            -- The spill: its nozzle on the ground or in a hand, sprayed where it points
            id    = 'spray',
            icon  = 'fuel',
            label = function(ctx)
                local i = info(ctx)
                return i and i.sp and ('Start Refuelling  $%d'):format(i.sp) or 'Start Refuelling'
            end,
            canInteract = function(ctx)
                local i = info(ctx)
                return i ~= nil and (i.n == 'ground' or i.n == 'hand') and not i.p and not i.err and free()
            end,
            options = PAY,
            onSelect = function(ctx) startSpray(ctx, keyOfCtx(ctx), ctx.option) end,
        },
        {
            -- Out of order after a spill, or its pump torn off: said, and nothing to do
            id    = 'broken',
            icon  = 'fuel',
            label = function(ctx) local i = info(ctx) return i and i.gone and 'Pump Gone' or 'Out of Order' end,
            canInteract = function(ctx) local i = info(ctx) return i ~= nil and (i.err ~= nil or i.gone == true) and not i.p end,
            onSelect = function() end,
        },
    }
end

-- The circles: only what can apply is on them
-- Every canInteract check crosses into this resource, so each circle carries only what can apply and is added again
-- when that changes (refreshCircles):
--   the pump's circle   busy options only while a side within BUSY_NEAR is busy; else just Fill Jerry Can
--   the nozzle's        Take Nozzle with empty hands, Put Nozzle Away with one in the hand
--   a blown-up pump     checked inside each option (onWhole)
-- The holsters follow an action of their own that is never re-added (addHolsterWatch).

--- A busy side nearer than this (metres) puts the pump's busy options up.
local BUSY_NEAR = 25.0

--- [key] = where its pump stands, read off the key once (tenths of a metre: shared/pumps.lua); false for none.
local keyPos = {}
local function posOfKey(key)
    local p = keyPos[key]
    if p == nil then
        local x, y, z = key:match('^pump_(%-?%d+)_(%-?%d+)_(%-?%d+)_')
        p = x and vector3(tonumber(x) / 10.0, tonumber(y) / 10.0, tonumber(z) / 10.0) or false
        keyPos[key] = p
    end
    return p or nil
end

--- Is a side within BUSY_NEAR busy (its nozzle out of the holster, a spill, out of order)? `faces` holds busy sides only.
local function busySideNear()
    local me = GetEntityCoords(PlayerPedId())
    for key in pairs(faces) do
        local p = posOfKey(key)
        if p and #(p - me) < BUSY_NEAR then return true end
    end
    return false
end

--- A blown-up pump offers nothing.
local function onWhole(options)
    for _, o in ipairs(options) do
        local own = o.canInteract
        o.canInteract = function(ctx) return not pumpBroken(ctx.entity) and own(ctx) end
    end
    return options
end

--- The panel pumps' holster nozzles as each pump comes into range (within 50 m) and leaves: onFound / onLost on a
--- hidden action, added once.
local function addHolsterWatch()
    local ok, why = core():AddAction({
        id = 'pumpHolsters',
        at = { model = Config.PumpModels },
        label = 'Pump',
        enabled = false,
        onSelect = function() end,   -- (required of every action; switched off, it is never chosen)
        onFound = function(ctx)
            if ctx.entity and Config.PumpPanels and Config.PumpPanels[ctx.model] then holsterAdd(ctx.entity, ctx.model) end
        end,
        onLost = function(ctx) if ctx.coords then holsterDrop(Pumps.prefixOf(Pumps.keyOf(ctx.coords, 'A'))) end end,
    })
    if not ok then print(('[whip_fuel] the pumps\' holsters were refused: %s'):format(tostring(why))) end
end

--- The pump's circle: on every pump model, both sides. `busy`: with its busy options (pumpOptions).
---@param busy boolean
local function addPumpCircle(busy)
    local c = Config.PumpCircle
    local perModel = {}
    for model, p in pairs(c.PlacingByModel or {}) do
        perModel[model] = { offset = p.offset, heading = p.heading }
    end
    local ok, why = Whip.call('AddAction', {
        id = 'pump',
        at = {
            model = Config.PumpModels,
            faces = 2,
            offset = c.Placing and c.Placing.offset or vector3(0.0, 0.4, 1.0),
            heading = c.Placing and c.Placing.heading or 0.0,
            perModel = perModel,
        },
        label = 'Pump',
        icon = 'fuel',
        -- The hand towards the pump's screen after each option (whip_core's hand press: looks only).
        press = true,
        seeFrom = c.SeenFrom or 3.5,
        -- Short, or the pump would win E from the car door you are refuelling.
        reach = c.UsableFrom or 1.5,
        options = onWhole(pumpOptions(busy)),
    })
    if not ok then print(('[whip_fuel] the pumps\' circle was refused: %s'):format(tostring(why))) end
end

--- The nozzle's own circle, on each side's nozzle (Config.NozzleCircle). `hand`: a nozzle is in the hand.
---@param hand boolean
local function addNozzleCircles(hand)
    -- Seen and used from as far as the pump's. A pump with one nozzle (`single`) gets one circle ('nozzle1'); others two.
    local c = Config.PumpCircle
    local n = Config.NozzleCircle or {}
    local twoModels, oneModels, nPerModel = {}, {}, {}
    for _, model in ipairs(Config.PumpModels or {}) do
        local p = n.PlacingByModel and n.PlacingByModel[model]
        if p and p.single then oneModels[#oneModels + 1] = model else twoModels[#twoModels + 1] = model end
    end
    for model, p in pairs(n.PlacingByModel or {}) do
        nPerModel[model] = { offset = p.offset, heading = p.heading }
    end
    local function nozzleAction(id, models, faceCount)
        if #models == 0 then Whip.call('RemoveAction', id) return end
        local okN, whyN = Whip.call('AddAction', {
            id = id,
            at = {
                model = models,
                faces = faceCount,
                offset = n.Placing and n.Placing.offset or vector3(0.35, -0.45, 0.8),
                heading = n.Placing and n.Placing.heading or 180.0,
                perModel = nPerModel,
            },
            label = 'Nozzle',
            icon = 'nozzle',
            press = true,
            seeFrom = c.SeenFrom or 3.5,
            reach = c.UsableFrom or 1.5,
            options = onWhole(nozzleOptions(hand)),
        })
        if not okN then print(('[whip_fuel] the nozzles\' circle (%s) was refused: %s'):format(id, tostring(whyN))) end
    end
    nozzleAction('nozzle', twoModels, 2)
    nozzleAction('nozzle1', oneModels, 1)
end

--- What each circle was last added with (nil: not since whip_core was ready or the placing changed).
local circlesBusy, circlesHand = nil, nil

--- Re-adds a circle whose options should change. Cheap when nothing changed. `force`: both.
refreshCircles = function(force)
    if not Whip.isReady() then return end
    local busy, hand = busySideNear(), Nozzle.myKey ~= nil
    if force or busy ~= circlesBusy then
        circlesBusy = busy
        addPumpCircle(busy)
    end
    if force or hand ~= circlesHand then
        circlesHand = hand
        addNozzleCircles(hand)
    end
end

--- Everything at the pumps, as whip_core is ready and when its models or placing change in /whip.
local function addPumps()
    keyCache = {}
    addHolsterWatch()
    refreshCircles(true)
end

Whip.register(function()
    addPumps()
    core():RegisterClientHook('freeHands', onFreeHands)
    -- whip_core restarted: its prompts went with it
    groundPrompts = {}
    for key in pairs(faces) do groundPrompt(key) end
end)

for _, path in ipairs({ 'PumpModels', 'PumpCircle', 'NozzleCircle' }) do
    Whip.onConfigChanged(path, function() if Whip.isReady() then addPumps() end end)
end

-- What each car costs
-- A label is read inside the prompt loop and must not block, so prices are kept ready in `quotes` and fetched in the
-- background for cars with a nozzle in them near here.

--- Price one car that needs it, in its own thread.
local function serveOneQuote()
    if quoteInFlight then return end
    local now = GetGameTimer()
    local pick = nil
    for veh, at in pairs(wanted) do
        if now - at > WANTED_TTL_MS or not DoesEntityExist(veh) then
            wanted[veh] = nil   -- nobody has asked about it for a while
        elseif not pick then
            local q = quotes[veh]
            local model = GetEntityModel(veh)
            local stale = (not q)
                -- Handles are reused: the model shows it is a different car.
                or q.model ~= model
                or (q.miss and now - q.at > QUOTE_MISS_RETRY_MS)
                or (not q.miss and now - q.at > QUOTE_TTL_MS)
            if stale then pick = veh end
        end
    end
    -- Prices for cars that have gone.
    for veh in pairs(quotes) do
        if not wanted[veh] and not DoesEntityExist(veh) then quotes[veh] = nil end
    end
    if not pick then return end

    local model = GetEntityModel(pick)
    local netId = NetworkGetNetworkIdFromEntity(pick)
    if not netId or netId <= 0 then
        quotes[pick] = { miss = true, model = model, at = now }
        return
    end
    quoteInFlight = true
    CreateThread(function()
        local result = core():Callback('whip_fuel:quote', netId)
        quoteInFlight = false
        if type(result) == 'table' then
            quotes[pick] = {
                model = model, netId = netId,
                units = tonumber(result.units) or 0,
                price = tonumber(result.price) or 0,
                perUnit = tonumber(result.perUnit) or 0,   -- the pump's amounts price from these
                tank  = tonumber(result.tank) or 100,
                at    = GetGameTimer(),
            }
        else
            quotes[pick] = { miss = true, model = model, at = GetGameTimer() }
        end
    end)
end

-- The pump thread
-- One thread, twice a second: the nozzle in your hand (walked off with it, or dead: it goes on the ground), the prices
-- of cars with nozzles in near here, and the pump's screen.

-- Whether a character is loaded is tracked from events (below), not asked each pass: an export call costs whip_core.
local charLoaded = false

CreateThread(function()
    while true do
        Wait(TICK_MS)
        if Whip.isReady() and charLoaded then
            local now = GetGameTimer()
            local ped = PlayerPedId()
            local me = GetEntityCoords(ped)
            -- Dead, or walked off further than the hose reaches. (Not on a torn pump: whip_rope drags you along.)
            local mine = Nozzle.myKey and faces[Nozzle.myKey]
            local away = myPump and #(me - myPump) > (Config.Pump.Leash or 5.0) and not (mine and mine.gone)
            if Nozzle.myKey and (core():IsPlayerDead() or away) then
                dropNozzle()
            end
            holstersCheck()
            refreshCircles()   -- walked near a busy side, or away from one
            for _, info in pairs(faces) do
                if info.n == 'car' and info.car then
                    local veh = entityOf(info.car)
                    if veh and #(GetEntityCoords(veh) - me) < QUOTE_RANGE then wanted[veh] = now end
                end
            end
            serveOneQuote()
            screenTick()
        end
    end
end)

-- Coming and going

AddEventHandler('whip_core:player:logout', function()
    charLoaded = false
    -- The epoch first, so a take-nozzle answer still in flight is ignored.
    charEpoch = charEpoch + 1
    Nozzle.busy, starting = false, false
    if Nozzle.filling then
        Nozzle.filling = false   -- the server's bar ends with the logout, and nothing is paid
        stopRefuelAnim()
    end
    -- The server puts the nozzle in the hand back; nothing to ask it
    Nozzle.myKey, myPump = nil, nil
    Nozzle.detach()
    stateChanged()
    screenRelease()   -- (the pump thread waits for the next character: its screens would stay up meanwhile)
end)

-- A new character learns what every pump is doing.
AddEventHandler('whip_core:player:loaded', function(...)
    charLoaded = true
    facesFetch(...)
end)

-- whip_fuel started under a loaded character: what every pump is doing
CreateThread(function()
    if Whip.ready(30000) and core():IsPlayerLoaded() then
        charLoaded = true
        facesFetch()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- The looping animation belongs to the ped and must be stopped here.
    if Nozzle.filling then stopRefuelAnim() end
    Nozzle.detach()
    screenRelease()
    for key in pairs(sprays) do sprayStop(key) end
    for _, h in pairs(holsters) do
        for side in pairs(HOLSTERS) do
            if h[side] and DoesEntityExist(h[side]) then DeleteObject(h[side]) end
        end
    end
    -- The prompts go with whip_core's own stop handler for this resource's actions
end)
