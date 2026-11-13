fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'whip_fuel'
description 'Fuel for whip: a tank on every car that driving burns, petrol pumps (a nozzle on each side, paid at the pump), jerry cans, and the hose (with whip_rope).'
author 'Whippy'
version '1.0.0'

-- Without this resource whip has no fuel at all: cars just drive. Everything here goes through whip_core's exports.
-- Whip.register re-runs our registrations whenever whip_core starts; Whip.configPage puts config.lua in /whip.
shared_script '@whip_core/lib/satellite.lua'
shared_script 'config.lua'
shared_script 'shared/settings.lua'   -- config.lua as a page in /whip → Settings → Fuel
shared_script 'shared/pumps.lua'      -- what both sides say about a pump: its sides, its keys

client_scripts {
    '@whip_core/client/world_quad.lua',   -- whip's quad in the world (the 3D prompts' own): the pumps' screens
    'client/tank.lua',     -- burning fuel as you drive, GTA's own gauge
    'client/pumps.lua',    -- the pump's circle, its holsters and screen, the nozzle in your hand, the spill
    'client/car.lua',      -- the nozzle at a car's filler, the jerry can at its doors
    'client/hose.lua',     -- a pump torn off its island: hidden there, its copy dragged, the petrol it leaks
    'client/stations.lua', -- the fuel stations' map icons
    'client/dials.lua',    -- the old pumps' rolling counters: each one's last sale (after pumps.lua: its faces)
}

server_scripts {
    'server/tank.lua',       -- the fuel stat, and the engine held off on an empty tank
    'server/pumps.lua',      -- the nozzles, the fills, the money
    'server/jerry_can.lua',  -- pouring a can into a car, filling one at a pump
    'server/hose.lua',       -- the pump's hose, on whip_rope's rope API when it runs
}

-- The modern pumps' screen (client/pumps.lua) and the old pumps' dials (client/dials.lua), DUI pages
files {
    'html/pump3d/*.html',
}

-- THE FOUR MODERN PUMPS (3D Clanker's remaster, stream/fuel_pump/): prop_gas_pump_1a RON, 1b Globe Oil, 1c LTD and 1d
-- Xero replaced on every forecourt, each with an LCD and a prompt panel on each face and no hose of its own; their
-- 1024 px textures are built into the models, under whip_ names. whip_pump_lcd: a screen prop for laying over one
-- pump's LCD, no longer used (every busy side's screen is drawn from one atlas now: client/pumps.lua).
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_lcd.ytyp'
-- whip_pump_torn (the LTD) and _1a / _1b / _1d: the same pumps, 1,400 kg and loose, for one a car tears off its island
-- and drags on its hose. Dead by themselves (no lit sign, a dark screen, no lights): their power is whip_pump_torn_glow
-- (_1a / _1b / _1d), put on for their last seconds (client/hose.lua).
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn_1a.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn_1b.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn_1d.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn_glow.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn_glow_1a.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn_glow_1b.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/fuel_pump/whip_pump_torn_glow_1d.ytyp'
-- The hose piece (3D Clanker's whip_hose_seg and its no-shadow twin: whip_rope's rope piece, in rubber).
data_file 'DLC_ITYP_REQUEST' 'stream/hose/whip_hose_seg.ytyp'
-- THE THREE OLD PUMPS (3D Clanker's, stream/classic_pump/): prop_gas_pump_old2 (Xero), _old3 (Ltd, now old2's model
-- with two hoses) and prop_vintage_pump (Globe Oil) replaced on every forecourt, their dial windows at zero, their
-- 1024 px textures built in. whip_oldpump_dial_1..4 / whip_vintage_dial_1..4: the overlays that show one pump's last sale
-- each, over its window (client/dials.lua).
data_file 'DLC_ITYP_REQUEST' 'stream/classic_pump/whip_oldpump_dial.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/classic_pump/whip_vintage_dial.ytyp'

dependencies { 'whip_core' }
