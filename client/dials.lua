--[[
    whip_fuel — THE CLASSIC PUMPS' DIALS (3D Clanker's, stream/classic_pump/)

    GTA's three old pumps (prop_gas_pump_old2 Xero, _old3 Ltd, prop_vintage_pump Globe Oil) have mechanical counters:
    TOTAL SALE, GALLONS and LITERS, on drums that roll like an odometer. Each pump keeps showing its last sale (the
    server's word, whip_fuel:sale) till the next fill there, which rolls every drum down to 0 and up again as it pours.

    The pump's own dial is baked at zero: a texture swapped on it would show one sale on every pump of that model. So a
    pump with something to show wears an overlay (whip_oldpump_dial_<n>, whip_vintage_dial_<n>, in the pump's own
    space: tied at offset 0), and overlay n shows cell n of its kind's one DUI (html/pump3d/oldpump_dial.html?atlas=):
    four cells, so the four nearest pumps of a kind within Config.ClassicDials.SeenFrom that have a sale or a fill.
    No station has more than four of one kind. One browser per kind, made on first use and let go a while after its
    last overlay (whip's DUI rule); a message only when a dial changes.

    Fuel is a percentage of a tank, so the litres are Config.ClassicDials.LitresPerTank of every 100.
]]

local TICK_MS = 1000         -- how often the nearest pumps are looked at
local POUR_TICK_MS = 500     -- ... and the drums told, while one of them pours
local RELEASE_MS = 10000     -- a kind's browser goes this long after its last overlay

--- The two kinds of dial, each one DUI of four cells and four overlays. `txd` / `tex`: the overlays' texture, swapped
--- for the browser's.
local KINDS = {
    bands = {
        url = 'html/pump3d/oldpump_dial.html?atlas=bands', w = 1536, h = 1088,
        txd = 'whip_oldpump_dial', tex = 'whip_oldpump_dial_live', runtime = 'whip_oldpump_dui',
        overlay = 'whip_oldpump_dial_%d',
    },
    vintage = {
        url = 'html/pump3d/oldpump_dial.html?atlas=vintage', w = 960, h = 1104,
        txd = 'whip_vintage_dial', tex = 'whip_vintage_dial_live', runtime = 'whip_vintage_dui',
        overlay = 'whip_vintage_dial_%d',
    },
}

--- The pumps that have dials, by model: their kind and their look in it (old2 / old3 share the bands).
local MODELS = {
    { name = 'prop_gas_pump_old2', kind = 'bands', look = 'old2' },
    { name = 'prop_gas_pump_old3', kind = 'bands', look = 'old3' },
    { name = 'prop_vintage_pump', kind = 'vintage', look = 'vintage' },
}
for _, m in ipairs(MODELS) do m.hash = GetHashKey(m.name) end

local sales = {}   -- [pump prefix] = { p = dollars, u = percent }: the server's word
local state = {}   -- [kind name] = { dui, slots = { [1..4] = slot }, idleSince }
local running = false

local function core() return exports.whip_core end
local function cfg() return Config.ClassicDials or {} end

--- Where a pump stands, from its prefix ('pump_<x>_<y>_<z>', tenths of a metre: shared/pumps.lua).
local function pumpAt(prefix)
    local x, y, z = prefix:match('^pump_(%-?%d+)_(%-?%d+)_(%-?%d+)$')
    if not x then return nil end
    return vector3(tonumber(x) / 10, tonumber(y) / 10, tonumber(z) / 10)
end

--- The classic pump standing at `at` on this game, and which model it is, or nil.
local function classicAt(at)
    for _, m in ipairs(MODELS) do
        local e = GetClosestObjectOfType(at.x, at.y, at.z, 0.6, m.hash, false, false, false)
        if e and e ~= 0 and DoesEntityExist(e) then return e, m end
    end
    return nil
end

--- The fill running at a pump (either side's pour, Nozzle.faces) and how far it has got: dollars and percent, or nil.
local function pouringAt(prefix)
    for _, side in ipairs({ 'A', 'B' }) do
        local key = prefix .. '_' .. side
        local info = Nozzle.faces[key]
        local p = info and info.p
        if p and (p.s or 0) > 0 then
            local since = (GetGameTimer() - (Nozzle.faceAt[key] or GetGameTimer())) / 1000
            local units = (tonumber(p.u) or 0) * math.min(1.0, ((p.e or 0) + since) / p.s)
            return { p = math.ceil(units * (tonumber(p.c) or 0) - 1e-9), u = units }
        end
    end
    return nil
end

--- What a dial reads for a sale: { price, liters }.
local function reading(sale)
    return { price = sale and sale.p or 0, liters = (sale and sale.u or 0) * (tonumber(cfg().LitresPerTank) or 60) / 100 }
end

local function send(k, msg)
    if k.dui then SendDuiMessage(k.dui, json.encode(msg)) end
end

-- ============================================
-- A kind's browser
-- ============================================

--- Up, and swapped onto its overlays' texture (before any overlay is made: README). Yields the first time; false
--- when it cannot be.
local function ensure(name)
    local k = state[name]
    if k and k.dui then return true end
    local def = KINDS[name]
    k = k or { slots = {} }
    state[name] = k
    if k.making then return false end
    k.making = true
    -- AddReplaceTexture finds the texture it swaps only in a dictionary in memory right then (pumps.lua's screen)
    -- (whip_core's loader, not a hand-written loop: audit 20, FUEL-1)
    local loaded = core():LoadTextureDict(def.txd, 2000)
    local dui = loaded and HasStreamedTextureDictLoaded(def.txd)
        and CreateDui(('nui://%s/%s'):format(GetCurrentResourceName(), def.url), def.w, def.h) or nil
    local deadline = GetGameTimer() + 5000
    while dui and not IsDuiAvailable(dui) and GetGameTimer() < deadline do Wait(50) end
    k.making = false
    if not dui or not IsDuiAvailable(dui) then
        if dui then DestroyDui(dui) end
        SetStreamedTextureDictAsNoLongerNeeded(def.txd)
        return false
    end
    CreateRuntimeTextureFromDuiHandle(CreateRuntimeTxd(def.runtime), 'dials', GetDuiHandle(dui))
    AddReplaceTexture(def.txd, def.tex, def.runtime, 'dials')
    k.dui, k.idleSince = dui, nil
    return true
end

local function release(name)
    local k = state[name]
    if not k or not k.dui then return end
    local def = KINDS[name]
    RemoveReplaceTexture(def.txd, def.tex)
    SetStreamedTextureDictAsNoLongerNeeded(def.txd)
    DestroyDui(k.dui)
    k.dui, k.idleSince = nil, nil
end

-- ============================================
-- A pump's slot
-- ============================================

local function freeSlot(name, i)
    local k = state[name]
    local s = k and k.slots[i]
    if not s then return end
    k.slots[i] = nil
    if s.obj and DoesEntityExist(s.obj) then DeleteObject(s.obj) end
    SetModelAsNoLongerNeeded(s.overlay)
end

--- Pump `prefix` (entity `pump`, model `m`) into a free slot of its kind: its overlay, its look and its reading.
local function takeSlot(m, prefix, pump)
    if not ensure(m.kind) then return end
    local k, def = state[m.kind], KINDS[m.kind]
    local i
    for n = 1, 4 do if not k.slots[n] then i = n break end end
    if not i or not DoesEntityExist(pump) then return end
    local overlay = GetHashKey(def.overlay:format(i))
    if not core():LoadModel(overlay, 2000) or not DoesEntityExist(pump) or k.slots[i] then return end
    local at = GetEntityCoords(pump)
    local obj = CreateObjectNoOffset(overlay, at.x, at.y, at.z, false, false, false)
    if not obj or obj == 0 then return end
    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(obj, pump, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    k.slots[i] = { prefix = prefix, pump = pump, obj = obj, overlay = overlay, pouring = false }
    k.idleSince = nil
    local pour = pouringAt(prefix)
    -- A fill already running: from 0 (it rolls up on the next tick); else the last sale at once
    send(k, { slot = i - 1, pump = m.kind == 'bands' and m.look or nil, set = reading(not pour and sales[prefix] or nil) })
    k.slots[i].pouring = pour ~= nil
end

-- ============================================
-- The look round
-- ============================================

--- Which pumps should wear a dial now, nearest first, per kind: { [kind] = { { prefix, pump, m, d } ... } } (at most 4).
local function wanted(me)
    local range = tonumber(cfg().SeenFrom) or 80.0
    local seen, out = {}, {}
    local function consider(prefix)
        if seen[prefix] then return end
        seen[prefix] = true
        local at = pumpAt(prefix)
        if not at then return end
        local d = #(at - me)
        if d > range then return end
        local pump, m = classicAt(at)
        if not pump or HasObjectBeenBroken(pump) then return end
        local list = out[m.kind] or {}
        out[m.kind] = list
        list[#list + 1] = { prefix = prefix, pump = pump, m = m, d = d }
    end
    for prefix, sale in pairs(sales) do
        if (sale.p or 0) > 0 or (sale.u or 0) > 0 then consider(prefix) end
    end
    for key, info in pairs(Nozzle.faces) do
        if info.p then consider(Pumps.prefixOf(key)) end
    end
    for _, list in pairs(out) do
        table.sort(list, function(a, b) return a.d < b.d end)
        for i = #list, 5, -1 do list[i] = nil end
    end
    return out
end

local function round(me, now)
    local want = wanted(me)
    local anyPour = false
    for name in pairs(KINDS) do
        local k = state[name]
        local list = want[name] or {}
        local keep = {}
        for _, w in ipairs(list) do keep[w.prefix] = w end
        -- Gone out of range, out of the top four, broken or streamed out: its slot is free
        if k then
            for i = 1, 4 do
                local s = k.slots[i]
                if s and (not keep[s.prefix] or keep[s.prefix].pump ~= s.pump or not DoesEntityExist(s.pump)) then
                    freeSlot(name, i)
                end
            end
        end
        for _, w in ipairs(list) do
            local has = false
            for i = 1, 4 do if k and k.slots[i] and k.slots[i].prefix == w.prefix then has = true end end
            if not has then
                takeSlot(w.m, w.prefix, w.pump)
                k = state[name]
            end
        end
        -- The pours: a fill starting rolls the drums down to 0, then up with it
        if k then
            local used = false
            for i = 1, 4 do
                local s = k.slots[i]
                if s then
                    used = true
                    local pour = pouringAt(s.prefix)
                    if pour then
                        anyPour = true
                        if not s.pouring then
                            s.pouring = true
                            send(k, { slot = i - 1, reset = true })
                        end
                        send(k, { slot = i - 1, sale = reading(pour), seconds = POUR_TICK_MS / 1000 })
                    end
                end
            end
            if used then
                k.idleSince = nil
            elseif k.dui then
                k.idleSince = k.idleSince or now
                if now - k.idleSince > RELEASE_MS then release(name) end
            end
        end
    end
    return anyPour
end

local function run()
    if running then return end
    running = true
    CreateThread(function()
        while true do
            local anyPour = false
            if cfg().Enabled ~= false and Whip.isReady() then
                anyPour = round(GetEntityCoords(PlayerPedId()), GetGameTimer())
            else
                for name in pairs(KINDS) do
                    for i = 1, 4 do freeSlot(name, i) end
                    release(name)
                end
            end
            Wait(anyPour and POUR_TICK_MS or TICK_MS)
        end
    end)
end

-- ============================================
-- What the server says
-- ============================================

--- A pump's sale ended: its dial rolls to what went out, and keeps it.
RegisterNetEvent('whip_fuel:sale', function(prefix, sale)
    if type(prefix) ~= 'string' or type(sale) ~= 'table' then return end
    sales[prefix] = { p = tonumber(sale.p) or 0, u = tonumber(sale.u) or 0 }
    for name, k in pairs(state) do
        for i = 1, 4 do
            local s = k.slots[i]
            if s and s.prefix == prefix then
                s.pouring = false
                send(k, { slot = i - 1, sale = reading(sales[prefix]), seconds = 0.5 })
            end
        end
    end
end)

--- Every pump's last sale, at a character's load.
local function salesFetch()
    CreateThread(function()
        if not Whip.ready(30000) then return end
        local all = core():Callback('whip_fuel:sales')
        if type(all) ~= 'table' then return end
        for prefix, sale in pairs(all) do
            if type(prefix) == 'string' and type(sale) == 'table' then
                sales[prefix] = { p = tonumber(sale.p) or 0, u = tonumber(sale.u) or 0 }
            end
        end
    end)
end

AddEventHandler('whip_core:player:loaded', salesFetch)
CreateThread(function()
    if Whip.ready(30000) and core():IsPlayerLoaded() then salesFetch() end
end)
run()

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for name in pairs(KINDS) do
        for i = 1, 4 do freeSlot(name, i) end
        release(name)
    end
end)
