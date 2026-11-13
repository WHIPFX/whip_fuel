--[[
    whip_fuel — THE FUEL STATIONS' MAP ICONS

    Only icons: refuelling works at every pump in the world whether its station is listed or not (Config.Stations).
    Drawn when a character loads (and again for a new one), and again when the list or the icon changes in /whip.
]]

local blips = {}

local function clear()
    for _, blip in ipairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    blips = {}
end

local function draw()
    clear()
    local icon = Config.StationIcon or {}
    for _, station in ipairs(Config.Stations or {}) do
        local pos = station.pos
        if pos then
            local blip = AddBlipForCoord(pos.x + 0.0, pos.y + 0.0, pos.z + 0.0)
            SetBlipSprite(blip, icon.Sprite or 361)
            SetBlipColour(blip, icon.Colour or 1)
            SetBlipScale(blip, 0.8)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(station.label or 'Gas Station')
            EndTextCommandSetBlipName(blip)
            blips[#blips + 1] = blip
        end
    end
end

local function loaded() return Whip.isReady() and exports.whip_core:IsPlayerLoaded() end

AddEventHandler('whip_core:player:loaded', draw)
AddEventHandler('whip_core:player:logout', clear)
Whip.onConfigChanged('Stations', function() if loaded() then draw() end end)
Whip.onConfigChanged('StationIcon', function() if loaded() then draw() end end)

-- Started under a loaded character
CreateThread(function()
    if Whip.ready(30000) and exports.whip_core:IsPlayerLoaded() then draw() end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clear() end
end)
