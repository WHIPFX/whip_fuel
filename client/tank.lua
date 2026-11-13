--[[
    whip_fuel — THE TANK, ON THIS GAME

    Once a second in a car: GTA's own fuel gauge is set to the car's fuel (it drives GTA's low-fuel effects — the
    sputter, the backfire), and the DRIVER measures what the car burns and hands it to whip_core's ConsumeVehicleStat,
    exactly as any consumable stat is reported (its accumulator sends a running total: a dropped report loses
    nothing). The fuel itself is the server's: this only reads it. An empty tank's engine is held off by the server
    (server/tank.lua), which whip_core enforces here.

    ELECTRIC CARS have no fuel (whip_core's IsVehicleElectric: GTA's flag on the engine): nothing burns, no gauge, no
    nozzle or jerry can at them, and the server is told so it never holds one's engine for an empty tank.
]]

Tank = {}

local TOP_SPEED = 70.0   -- m/s (about 250 km/h): flat out burns 2.5 times the base rate

--- The tank's 0-100 as GTA's own fuel: spread over Config.Tank.GtaFloor to 100, so GTA never gets low enough to
--- misbehave (config.lua).
local function gtaLevel(fuel)
    local floor = math.max(0.0, math.min(50.0, tonumber(Config.Tank.GtaFloor) or 0.0))
    fuel = math.max(0.0, math.min(100.0, fuel + 0.0))
    return floor + fuel * (100.0 - floor) / 100.0
end

--- Is this car electric? whip_core's answer (GTA's flag on the car's model), kept for as long as the car is in this game:
--- it never changes on a car (prompts ask it every frame). Checked against the model, so a handle the game gives to
--- another car is asked again; not kept while whip_core cannot answer.
local electricSeen = {}   -- [entity] = { yes, model }
function Tank.isElectric(veh)
    if not veh or veh == 0 then return false end
    local model = GetEntityModel(veh)
    local e = electricSeen[veh]
    if e and e.model == model then return e.yes end
    if not Whip.isReady() then return false end
    local yes = exports.whip_core:IsVehicleElectric({ entity = veh }) == true
    electricSeen[veh] = { yes = yes, model = model }
    return yes
end

--- The fuel gauge's icon for each car (gaugeIcon, below): [entity] = { model, icon }, icon false for none. Up here so
--- the loop's sweep sees it.
local iconOf = {}

--- The vehicleIds whose electric engine the server has been told of, this session.
local told = {}

CreateThread(function()
    local sweepAt = 0
    while true do
        Wait(1000)
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and Whip.isReady() then
            local ref = { entity = veh }
            if Tank.isElectric(veh) then
                -- No fuel: the server is told once (it never holds this car's engine for an empty tank)
                local vehicleId = exports.whip_core:GetVehicleId(veh)
                if vehicleId and not told[vehicleId] then
                    told[vehicleId] = true
                    TriggerServerEvent('whip_fuel:electric', NetworkGetNetworkIdFromEntity(veh))
                end
            else
                -- Driving off with a nozzle in tears its pump off: its copy's model ready for it (client/hose.lua)
                if GetPedInVehicleSeat(veh, -1) == ped and Nozzle.inCar(veh) then Nozzle.readyTornCopy() end

                local fuel = exports.whip_core:GetVehicleStat(ref, 'fuel')
                if fuel then
                    -- GTA's own gauge, local and cosmetic, kept off its lowest values
                    SetVehicleFuelLevel(veh, gtaLevel(fuel))

                    -- Measured here, where speed and throttle already are, by the driver only
                    if fuel > 0 and GetPedInVehicleSeat(veh, -1) == ped and GetIsVehicleEngineRunning(veh) then
                        local speed    = GetEntitySpeed(veh)
                        local throttle = math.abs(GetVehicleThrottleOffset(veh))
                        local speedFactor    = 1.0 + (math.min(speed, TOP_SPEED) / TOP_SPEED) * 1.5
                        local throttleFactor = 0.3 + (throttle * 0.7)
                        -- A second's worth (this ticks once a second). A car whip has not taken on answers false:
                        -- nothing to burn against
                        exports.whip_core:ConsumeVehicleStat(ref, 'fuel',
                            (Config.Burn.Rate or 0.03) * speedFactor * throttleFactor)
                    end
                end
            end
        end
        -- Cars gone from this game: their answers forgotten
        local now = GetGameTimer()
        if now >= sweepAt then
            sweepAt = now + 30000
            for e in pairs(electricSeen) do
                if not DoesEntityExist(e) then electricSeen[e] = nil end
            end
            for e in pairs(iconOf) do
                if not DoesEntityExist(e) then iconOf[e] = nil end
            end
        end
    end
end)

--- The gauge's pump points to the side the car's filler is on (whip_core's 'fuel' point, when it is on one side of
--- the car whichever side you stand). No arrow where there is no filler, or none on a side (on its back, or the middle
--- of a motorbike's tank).
--- Kept for each car (the filler is where the car's model has it, and never moves): whip_core asks once a second while
--- a player sits in the car, and the point is a table made, packed and unpacked across the two resources each time.
--- Checked against the model, so a handle the game gives to another car is asked again.
local GAUGE_ICON = { left = 'fuel_left', right = 'fuel_right' }
local function gaugeIcon(entity)
    local model = GetEntityModel(entity)
    local known = iconOf[entity]
    if known and known.model == model then return known.icon or nil end
    local point = exports.whip_core:GetVehiclePoint({ entity = entity }, 'fuel')
    if type(point) ~= 'table' then return nil end   -- no answer (yet): asked again next time
    local icon = point.fixed and GAUGE_ICON[point.side] or false
    iconOf[entity] = { model = model, icon = icon }
    return icon or nil
end

-- No fuel gauge on an electric car; on the rest, its pump points to the filler
Whip.register(function()
    exports.whip_core:SetVehicleStatShown('fuel', function(entity) return not Tank.isElectric(entity) end)
    exports.whip_core:SetVehicleStatIcon('fuel', gaugeIcon)
end)
