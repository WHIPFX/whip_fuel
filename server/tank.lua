--[[
    whip_fuel — THE TANK

    'fuel' is a vehicle stat like any other (whip_core's vehicle stats): on every car, saved with it, sent live to
    everyone sitting in it, its gauge round the rev dial. Registered here; without whip_fuel there is none. A car
    with no fuel saved yet (a street car, a new car never driven) has a full tank.

    Burning it is the stat's `consume`: the driver's game measures it (client/tank.lua) and reports it, and the server
    believes at most 2.5 × Config.Burn.Rate a second. An empty tank holds the engine off (whip_core's
    HoldVehicleEngine: it will not start, a running one stops, the car still rolls) until there is fuel in it.
    Electric cars have no fuel: they burn none, and a driver's game says so, so theirs is never held.
]]

--- [vehicleId] = true while this resource holds that car's engine off. Forgotten when whip_core restarts (its
--- holds go with it), and filled again from every car's fuel as the stat is registered.
local held = {}

--- [vehicleId] = true: an electric car, a driver's game says (client/tank.lua). It has no fuel: never held for an
--- empty tank. (A game could claim a petrol car is electric; it could as well report no burn. Nothing new.)
local electric = {}

--- A car's tank `value` held or let go. No value (nil: the stat not registered yet, as while whip_core brings
--- cars back at its start) is not empty: an unknown is never a hold, and nothing would come back to let it go.
local function follow(vehicleId, value)
    vehicleId = tonumber(vehicleId)
    if not vehicleId or value == nil then return end
    local empty = (tonumber(value) or 0) <= 0 and not electric[vehicleId]
    if empty and not held[vehicleId] then
        held[vehicleId] = true
        exports.whip_core:HoldVehicleEngine(vehicleId, 'empty', 'Out of fuel')
    elseif not empty and held[vehicleId] then
        held[vehicleId] = nil
        exports.whip_core:ReleaseVehicleEngine(vehicleId, 'empty')
    end
end

local function register()
    local ok, why = exports.whip_core:RegisterVehicleStat('fuel', {
        default = 100, min = 0, max = 100,
        persist = true,
        hud = {
            label = 'Fuel',
            icon  = Config.Tank.GaugeIcon,
            color = '#f59e0b',
            order = Config.Tank.GaugeOrder or 1,
        },
        -- E and F at the gauge's ends instead of a percentage (Config.Tank.GaugeEnds; false: the percentage)
        display = type(Config.Tank.GaugeEnds) == 'table' and { ends = Config.Tank.GaugeEnds } or nil,
        -- NOT clearAtMin: an empty tank is still a tank (the stat stays at 0, the gauge shows it)
        consume = {
            maxRate    = math.abs(Config.Burn.Rate or 0.03) * 2.5,
            interval   = Config.Burn.ReportEvery or 5,
            driverOnly = true,   -- a passenger must not drain the tank
        },
    })
    if not ok then print(('[whip_fuel] the fuel stat was refused: %s'):format(tostring(why))) end
    return ok
end

--- A driver's game says this car is electric: no fuel, so never held off for an empty tank.
local function onElectric(src, _, netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return end
    if GetVehiclePedIsIn(GetPlayerPed(src), false) ~= entity then return end   -- said from inside it
    local vehicleId = Fuel.vehicleIdOf(entity)   -- as whip_core's index confirms it (server/pumps.lua)
    if not vehicleId or electric[vehicleId] then return end
    electric[vehicleId] = true
    follow(vehicleId, 100)   -- a hold it had (an empty tank from before) let go
end

--- Every change from here on, and every car whip has now, as its tank reads: one with only the default too (a car
--- that does not carry the stat is full).
local function listen()
    exports.whip_core:OnVehicleStatChanged('fuel', function(vehicleId, value) follow(vehicleId, value) end, { now = 'all' })
end

Whip.register(function()
    -- Let go of what this resource held (a hold made before this, while whip_core was starting, would otherwise
    -- be forgotten here and kept there), then every car's fuel again from the stat
    for vehicleId in pairs(held) do exports.whip_core:ReleaseVehicleEngine(vehicleId, 'empty') end
    held = {}
    if not register() then return end
    listen()
    exports.whip_core:SecureEvent('whip_fuel:electric', {
        rateLimit = 1000, burst = 3,
        params = { { 'netId', 'id', 1, 4294967295 } },
    }, onElectric)
end)

-- A car brought out (a garage, a restart) or taken on: its tank looked at, in case it is empty
for _, name in ipairs({ 'whip_core:vehicle:spawned', 'whip_core:vehicle:registered' }) do
    AddEventHandler(name, function(e)
        local vehicleId = type(e) == 'table' and tonumber(e.vehicleId)
        if not vehicleId then return end
        follow(vehicleId, exports.whip_core:GetVehicleStat(vehicleId, 'fuel'))
    end)
end

-- The gauge or the burn changed in /whip → Settings: the stat registered again with it
Whip.onConfigChanged('Tank', function() if Whip.isReady() then register() end end)
Whip.onConfigChanged('Burn', function() if Whip.isReady() then register() end end)

--- The tank: { level, max } of a car by vehicleId, read through the stat (an absent value is the default: a street
--- car whip has never written to is full).
function TankOf(vehicleId)
    local level = vehicleId and exports.whip_core:GetVehicleStat(vehicleId, 'fuel')
    if level == nil then level = 100.0 end
    return math.max(0.0, math.min(100.0, tonumber(level) or 0.0)), 100.0
end
