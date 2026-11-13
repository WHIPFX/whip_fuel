--[[
    whip_fuel — SETTINGS

    Every car has a tank. Driving burns it; an empty car's engine will not run (it still rolls, and can be pushed).
    Fill it at any petrol pump in the world, or pour a jerry can into it. Take this resource away and there is no
    fuel at all: cars just drive.

    Most of this is also in game: /whip → Settings → Fuel. What is saved there wins over this file.

      1. The tank           GTA's lowest fuel, the gauge
      2. Burning it         how fast
      3. The pumps          price, speed, the nozzle's rules
      4. The pump's circle  which models are pumps, where the circle sits on each
      5. The hose           (only with whip_rope running)
      6. Jerry cans
      7. Map icons          the fuel stations
      8. The old pumps' dials   the classic pumps' rolling counters
]]

Config = {}

-- ============================================================================
-- 1. THE TANK
-- ============================================================================
-- A car's fuel is a percentage: 0 is empty, 100 is a full tank. It is saved with the car, and a car with none saved
-- yet (a street car, a new car never driven) has a full tank.

Config.Tank = {
    -- GTA's own fuel misbehaves when it gets very low (near 1%, a car can start driving backwards), so it is never
    -- let down there: the tank's 0 to 100 is spread over GtaFloor to 100 of GTA's. The tank still runs from empty to
    -- full; an empty car's engine is held off by whip_fuel, not by GTA. 0 turns this off.
    GtaFloor = 5,

    -- The gauge round the rev dial (bottom right of the screen). Order: its place among the gauges, lowest at the
    -- bottom. Icon: an SVG path.
    GaugeOrder = 1,
    -- The gauge's ends, as a car's fuel gauge: E at the empty end, F at the full end, and no number. Set it to false
    -- to show the tank as a percentage instead.
    GaugeEnds = { 'E', 'F' },
    GaugeIcon = 'M19.77 7.23l.01-.01-3.72-3.72L15 4.56l2.11 2.11c-.94.36-1.61 1.26-1.61 2.33a2.5 2.5 0 0 0 2.5 2.5c.36 0 .69-.08 1-.21v7.21c0 .55-.45 1-1 1s-1-.45-1-1V14a2 2 0 0 0-2-2h-1V5a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v16h10v-7.5h1.5v5a2.5 2.5 0 0 0 5 0V9c0-.69-.28-1.32-.73-1.77zM12 10H6V5h6v5z',
}

-- ============================================================================
-- 2. BURNING IT
-- ============================================================================
-- The driver's game measures what the car burns and tells the server. The server believes at most 2.5 times Rate a
-- second (a car flat out), so raising Rate raises that limit with it.

Config.Burn = {
    Rate = 0.03,        -- Percent of the tank a second, driving steadily. Idling burns about a third of it, flat out 2.5 times
    ReportEvery = 5,    -- Seconds between reports. Passengers' gauges move this often
}

-- ============================================================================
-- 3. THE PUMPS
-- ============================================================================
-- Every side of every pump has its own nozzle. Take it (free), put it in the car's filler, then at the pump choose
-- how much and pay (cash or bank). It fills while you do as you please; what does not go in is paid back.

Config.Pump = {
    Price = 1,           -- $ for one percent of a tank, so a half-empty tank costs $50. 0: fuel is free
    FullSeconds = 120,   -- Seconds to fill an empty tank. Less takes less: half a tank, 60. A jerry can fills at the same flow

    Reach = 3.0,         -- How far from a pump the server still lets you take its nozzle
    Leash = 5.0,         -- Walk further than this from the pump with its nozzle and it drops on the ground
    CarReach = 5.0,      -- How close to a car you stand to put a nozzle in or take it out (the server allows 1 m more)
    CarMayRoll = 1.5,    -- How far a car may move while it fills. Further, and the fill stops ("The car moved away")
    HoldWalk = 'clipset@move@trash_fast_turn',   -- The walk while a nozzle is in the hand (the trash-bag walk). nil: their own

    GroundSeconds = 30,  -- A nozzle left on the ground goes back on its pump after this
    IdleMinutes = 5,     -- A nozzle left in a car with nothing done at its pump goes back after this
    TornMinutes = 5,     -- A pump a car tore off: once its nozzle is unplugged, it is gone after this, and back on its island

    -- THE SPILL: "Start Refuelling" with that side's nozzle on the ground or in someone's hand sprays fuel out of it
    -- (paid for, like a fill) for up to SpraySeconds. On the ground it thrashes about; in a hand it goes where the
    -- nozzle points. Then that side of the pump is out of order for ErrorSeconds, its screen flashing an error.
    SpraySeconds = 10,
    ErrorSeconds = 60,
}

-- ============================================================================
-- 4. THE PUMP'S CIRCLE
-- ============================================================================

-- The pumps refuelling works on. Every pump of these in the world works: there is no list of stations to keep.
-- Add a model if your map has pumps GTA does not.
Config.PumpModels = {
    'prop_gas_pump_1a',
    'prop_gas_pump_1b',
    'prop_gas_pump_1c',
    'prop_gas_pump_1d',
    'prop_gas_pump_old2',
    'prop_gas_pump_old3',
    'prop_vintage_pump',
}

Config.PumpCircle = {
    SeenFrom = 3.5,      -- How far away a pump's circle fades in
    UsableFrom = 1.5,    -- How close you must be to use it. Keep it short, or the pump takes E from the car door beside it

    -- Where the circle sits on a pump, measured from the pump itself in metres: vector3(to the side, out from its
    -- face, up), and which way it faces (heading, degrees). The other side of the pump is worked out from it.
    -- Don't guess: stand at a pump, type /actionplace whip_fuel:pump, aim where the circle should go and press E. It
    -- copies a line to paste into PlacingByModel (out above 0 goes with heading 0, out below 0 with heading 180).
    Placing = { offset = vector3(0.0, 0.4, 1.0), heading = 0.0 },   -- any pump not listed below
    PlacingByModel = {
        -- The four modern pumps (3D Clanker's remaster, stream/fuel_pump/): at the left of the black panel beside the
        -- screen, 2 cm out of it, so its words have the panel to their right. The panel is the same on all four.
        prop_gas_pump_1a = { offset = vector3(0.05, -0.26, 1.2855), heading = 180.0 },
        prop_gas_pump_1b = { offset = vector3(0.05, -0.26, 1.2855), heading = 180.0 },
        prop_gas_pump_1c = { offset = vector3(0.05, -0.26, 1.2855), heading = 180.0 },
        prop_gas_pump_1d = { offset = vector3(0.05, -0.26, 1.2855), heading = 180.0 },
        -- The two old pumps (3D Clanker's, stream/classic_pump/: old3 is old2's model now): in the gap under the dials,
        -- at its left, 2 cm out of the glass, so its words run along the gap.
        prop_gas_pump_old2 = { offset = vector3(-0.25, -0.372, 0.974), heading = 180.0 },
        prop_gas_pump_old3 = { offset = vector3(-0.25, -0.372, 0.974), heading = 180.0 },
    },
}

-- The nozzle's own circle (Josh, 2 Nov): Take Nozzle and Put Nozzle Away are on a circle where each side's nozzle
-- hangs; paying, filling and stopping stay on the pump's circle above. It is seen from and used from as far as the
-- pump's circle. Placed the same way: stand at a pump, type /actionplace whip_fuel:nozzle, aim at the nozzle and
-- press E, and paste the line it copies into PlacingByModel.
Config.NozzleCircle = {
    -- Any pump not listed below. A guess: measure the pump with /actionplace whip_fuel:nozzle.
    Placing = { offset = vector3(0.35, -0.45, 0.8), heading = 180.0 },
    -- Each listed model's circle, about 10 cm out from its nozzle's grip, facing the player (3D Clanker measured them).
    -- The other side's is the same turned half round. `single = true`: the pump has one nozzle, so only this circle.
    PlacingByModel = {
        -- The four modern pumps: just out from the nozzle in side A's holster (client/pumps.lua HOLSTERS).
        prop_gas_pump_1a = { offset = vector3(0.345, -0.47, 0.75), heading = 180.0 },
        prop_gas_pump_1b = { offset = vector3(0.345, -0.47, 0.75), heading = 180.0 },
        prop_gas_pump_1c = { offset = vector3(0.345, -0.47, 0.75), heading = 180.0 },
        prop_gas_pump_1d = { offset = vector3(0.345, -0.47, 0.75), heading = 180.0 },
        -- The two old pumps hang their nozzles on their sides: side A's on the right (+x), B's on the left.
        prop_gas_pump_old2 = { offset = vector3(0.62, 0.0, 1.07), heading = 270.0 },
        prop_gas_pump_old3 = { offset = vector3(0.62, 0.0, 1.07), heading = 270.0 },
        -- The vintage pump has one nozzle, on its left near the front.
        prop_vintage_pump = { offset = vector3(-0.40, -0.05, 1.02), heading = 90.0, single = true },
    },
}

-- The pumps with whip's screen and empty holsters (3D Clanker's remaster of GTA's four modern pumps), and the brand
-- each one's screen shows. A nozzle sits in each holster of these, and the side being used nearest you shows how it is
-- going on its screen. A pump not listed here works the same, without them.
Config.PumpPanels = {
    prop_gas_pump_1a = 'RON',
    prop_gas_pump_1b = 'GLOBE OIL',
    prop_gas_pump_1c = 'LTD',
    prop_gas_pump_1d = 'XERO',
}

-- ============================================================================
-- 5. THE HOSE (needs whip_rope)
-- ============================================================================
-- With whip_rope running, a hose runs from the pump to its nozzle. A car that drives off with the nozzle in pulls
-- on it, and tears the pump off its island (or, a pump that does not come away, snaps the nozzle off). Without
-- whip_rope, a car that drives off simply pulls the nozzle out, and it goes back on its pump.

Config.Hose = {
    Enabled = true,           -- false: no hose even with whip_rope (the nozzle is pulled out instead)
    Length = 3.0,             -- metres (Config.Pump.Leash is how far the hand may go)
    LinkLength = 0.125,       -- metres between its nodes (a rope's are 0.25): shorter, more nodes, more work

    -- The world around it: every Nth node probed (1 = all), and cars as well as the map and props, so it lies on
    -- them and slides off them. Costs a little while one is out.
    CollisionCheckSpacing = 1,
    CollideWithVehicles = true,

    -- Its pieces: 3D Clanker's rubber hose (2.8 cm), the no-shadow one when whip_rope's shadows are off.
    Model = `whip_hose_seg`,
    ModelNoShadow = `whip_hose_seg_ns`,

    -- Where the hose leaves each pump, in the pump's own space (metres: right, forward, up). A pump with two
    -- sides has two; the hose comes from the one nearer where the nozzle was taken. Measured off the models by
    -- 3D Clanker (C:\WhipShare\fuel_pumps_20261029\FINDINGS.md, 6a), each about 4 cm clear of the pump's own collision
    -- (C:\WhipShare\whip_fuel_pumps_fix_20261112): a start inside or touching it has the hose fight its way out.
    Outlets = {
        prop_gas_pump_1a   = { vector3(0.346, -0.258, 2.072), vector3(-0.347, 0.256, 2.059) },
        prop_gas_pump_1b   = { vector3(0.346, -0.251, 2.173), vector3(-0.347, 0.245, 2.176) },
        prop_gas_pump_1c   = { vector3(0.346, -0.228, 2.170), vector3(-0.347, 0.216, 2.170) },
        prop_gas_pump_1d   = { vector3(0.346, -0.255, 2.060), vector3(-0.347, 0.247, 2.045) },
        prop_gas_pump_old2 = { vector3(0.410, -0.006, 0.648), vector3(-0.410, 0.006, 0.648) },
        prop_gas_pump_old3 = { vector3(0.410, -0.006, 0.648), vector3(-0.410, 0.006, 0.648) },   -- old2's model now
        prop_vintage_pump  = { vector3(-0.273, 0.047, 1.212) },
    },
    -- Any other pump (a custom map's): straight up from its origin, this many metres.
    OutletHeight = 1.1,

    -- Stretched this far past its length (0.35 = 35%) for BreakHoldMs, the pump comes away.
    BreakStretch = 0.35,
    BreakHoldMs = 250,
    -- Stretched past this (0.3 = 30% longer), the hose draws its two ends together by weight: a car dragging a torn pump
    -- feels its TornMass, and a second car or the nozzle on the ground is dragged along. It never stretches past twice
    -- this (whip_rope's Config.Coupling.HardCeiling). A car driving off with the pump still on its island is never held
    -- back by it: the pump comes away at BreakStretch.
    MaxStretch = 0.3,

    -- What comes away, by the pump's model: a loose copy the hose drags for real (3D Clanker's: each modern pump at
    -- 1,400 kg, nothing breaks off it, it does not explode, dead by itself), the island's own pump hidden meanwhile. A
    -- pump not here does not come away: its hose breaks off at the car instead, and the nozzle drops.
    TornModels = {
        prop_gas_pump_1a = `whip_pump_torn_1a`,
        prop_gas_pump_1b = `whip_pump_torn_1b`,
        prop_gas_pump_1c = `whip_pump_torn`,
        prop_gas_pump_1d = `whip_pump_torn_1d`,
    },
    -- What those copies weigh (kg): their models' own weight, told to the hose. The game can't read a prop's weight,
    -- and the rope's own guess from the pump's size (about 360 kg) let it fling a 1,400 kg pump about like a light one.
    -- Change it only with the models.
    TornMass = 1400,
    -- How hard a torn pump grips the ground (m/s²: how fast it slows while it slides; 6 is about steel on concrete).
    -- The game gives the models almost none (they slide like on ice), so whip_fuel holds it back itself. Higher: it
    -- stops sooner and drags heavier behind a car. 0: the game's own (none).
    TornGrip = 6.0,
    -- Its power for its last seconds, by the pump's model: the lit sign and the canopy's lights, put on the copy as it
    -- comes away, flickering out a few seconds later (client/hose.lua). A pump not here has none.
    TornGlow = {
        prop_gas_pump_1a = `whip_pump_torn_glow_1a`,
        prop_gas_pump_1b = `whip_pump_torn_glow_1b`,
        prop_gas_pump_1c = `whip_pump_torn_glow`,
        prop_gas_pump_1d = `whip_pump_torn_glow_1d`,
    },

    -- THE PUMP'S OTHER SIDE when it comes away. Its nozzle in another car: that car is on the pump's hose too, so the
    -- two cars and the pump pull on one another. Its nozzle in someone's hand: whip_rope drags them along behind the
    -- pump, falling, then they let go (whip_rope's Config.Drag: how long; at once if they die). Anywhere else: it goes
    -- back.

    -- The torn pump leaks petrol behind it for this long (seconds): a trail that burns.
    LeakSeconds = 20,
    -- true: the island it stood on catches fire. Off: a pump on fire blows up before it can be dragged away.
    FireAtBase = false,
}

-- ============================================================================
-- 6. JERRY CANS
-- ============================================================================
-- Any item whose definition has `fuelCapacity` is a fuel can: how much of a tank a FULL can holds (whip_gunny's
-- jerry_can holds 30, in whip_gunny/config/data.lua). With one in hand, a car's doors offer "Refuel (jerry can)", and
-- a pump "Fill Jerry Can" (priced as the pump prices a car: a can of 30 costs 30 percent's worth).

Config.JerryCan = {
    PourSeconds = 3,     -- How long pouring a can into a car takes
}

-- ============================================================================
-- 7. MAP ICONS
-- ============================================================================
-- THIS LIST ONLY DRAWS ICONS. Refuelling works at every pump whether its station is listed or not, so deleting an
-- entry hides the icon and nothing else. Below is every station on GTA's own map.

Config.StationIcon = {
    Sprite = 361,   -- the petrol pump
    Colour = 1,     -- red
}

Config.Stations = {
    { pos = vector3(49.42,    2778.79,  58.04),  label = 'Gas Station' },
    { pos = vector3(263.89,   2606.46,  44.98),  label = 'Gas Station' },
    { pos = vector3(1039.96,  2671.13,  39.55),  label = 'Gas Station' },
    { pos = vector3(1207.26,  2660.18,  37.90),  label = 'Gas Station' },
    { pos = vector3(2539.69,  2594.19,  37.94),  label = 'Gas Station' },
    { pos = vector3(2679.86,  3263.95,  55.24),  label = 'Gas Station' },
    { pos = vector3(2005.06,  3773.89,  32.40),  label = 'Gas Station' },
    { pos = vector3(1785.18,  3330.37,  41.34),  label = 'Gas Station' },
    { pos = vector3(1687.16,  4929.39,  42.08),  label = 'Gas Station' },
    { pos = vector3(1701.31,  6416.03,  32.76),  label = 'Gas Station' },
    { pos = vector3(179.86,   6602.84,  31.87),  label = 'Gas Station' },
    { pos = vector3(-94.46,   6419.59,  31.49),  label = 'Gas Station' },
    { pos = vector3(-2554.996, 2334.40, 33.08),  label = 'Gas Station' },
    { pos = vector3(-1800.38,  803.66, 138.65),  label = 'Gas Station' },
    { pos = vector3(-1437.62, -276.75,  46.21),  label = 'Gas Station' },
    { pos = vector3(-2096.24, -320.29,  13.17),  label = 'Gas Station' },
    { pos = vector3(-724.62,  -935.16,  19.21),  label = 'Gas Station' },
    { pos = vector3(-526.02, -1211.00,  18.18),  label = 'Gas Station' },
    { pos = vector3(-70.21,  -1761.79,  29.53),  label = 'Gas Station' },
    { pos = vector3(265.65,  -1261.31,  29.29),  label = 'Gas Station' },
    { pos = vector3(176.63,  -1562.03,  29.26),  label = 'Gas Station' },
    { pos = vector3(-319.29, -1471.72,  30.55),  label = 'Gas Station' },
    { pos = vector3(819.65,  -1028.85,  26.40),  label = 'Gas Station' },
    { pos = vector3(1208.95, -1402.57,  35.22),  label = 'Gas Station' },
    { pos = vector3(1181.38,  -330.85,  69.32),  label = 'Gas Station' },
    { pos = vector3(620.84,    269.10, 103.09),  label = 'Gas Station' },
    { pos = vector3(2581.32,   362.04, 108.47),  label = 'Gas Station' },
}

-- ============================================================================
-- 8. THE OLD PUMPS' DIALS
-- ============================================================================
-- GTA's three old pumps (prop_gas_pump_old2, _old3 and prop_vintage_pump: 3D Clanker's, stream/classic_pump/) show
-- TOTAL SALE, GALLONS and LITERS on rolling drums: a pump's last sale till the next fill there, which rolls them down
-- to 0 and up again as it pours. Kept till the server restarts.

Config.ClassicDials = {
    Enabled = true,       -- false: the old pumps' counters stay at 0
    LitresPerTank = 60,   -- A full tank in litres, for the LITERS and GALLONS drums (fuel is a percentage of a tank)
    SeenFrom = 80.0,      -- A pump further than this shows 0 (its dial is made only nearer)
}
