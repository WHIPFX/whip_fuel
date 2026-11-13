-- ============================================
-- whip_fuel — the settings page in /whip → Settings → Fuel
-- ============================================
-- What an owner changes, as a page in game (Whip.configPage). config.lua is the default; saved values win and
-- are written into Config on both sides, and take effect at once. The pumps' reaches and timers, the circles'
-- placing, the hose's stretch and the old pumps' dials are config.lua's alone.

local HOSE = { path = 'Hose.Enabled', equals = true }

Whip.configPage({
    label = 'Fuel',
    groups = {
        { label = 'Fuel', settings = {
            { key = 'Burn.Rate', type = 'number', min = 0.001, max = 1, step = 0.005, unit = '%/s', label = 'Fuel burn',
              help = 'The base burn, in percent of the tank a second: idling burns about a third of it, steady driving about this, flat out about 2.5 times. The server\'s limit on what a driver may report follows it.' },
            { key = 'Pump.Price', type = 'int', min = 0, max = 1000, unit = '$ per %', label = 'Fuel price',
              help = 'The price of one percent of a tank, so 1 makes a half-empty tank cost $50. 0 makes fuel free.' },
            { key = 'Pump.FullSeconds', type = 'int', min = 5, max = 900, unit = 's', label = 'Empty tank fills in',
              help = 'Seconds a pump takes to fill an empty tank. Less takes less: half a tank, half the time. A jerry can fills at the same flow.' },
            { key = 'Tank.GaugeOrder', type = 'int', min = 1, max = 99, label = 'Gauge place',
              help = 'Its place among the gauges round the rev dial, lowest at the bottom.' },
            { key = 'Stations', type = 'records', maxItems = 200, widget = 'mapPoints',
              marker = { sprite = (Config.StationIcon or {}).Sprite or 361, colour = (Config.StationIcon or {}).Colour or 1,
                         name = 'Gas Station' },
              fields = {
                  { key = 'pos', type = 'vec3', limits = { x = { -4000, 8000 }, y = { -7000, 8000 }, z = { -200, 2000 } },
                    here = true, label = 'Where' },
                  { key = 'label', type = 'string', maxLen = 50, label = 'Name' },
              },
              label = 'Fuel station map icons',
              help = 'One map icon per station. Refuelling works at every pump whether its station is listed or not; this only draws the icons. Edit on the map: drag an icon to move it, click one to rename or remove it, or add one where you stand.' },
        } },
        { label = 'The hose', settings = {
            { key = 'Hose.Enabled', type = 'bool', label = 'A hose from the pump',
              help = 'Needs whip_rope running. A car that drives off with the nozzle in pulls on it and tears the pump off its island. Off (or without whip_rope): the car simply pulls the nozzle out, and it goes back on its pump.' },
            { key = 'Hose.Length', type = 'number', min = 1, max = 10, step = 0.5, unit = 'm', label = 'Hose length', shownWhen = HOSE,
              help = 'Hoses taken out from now on.' },
            { key = 'Hose.LeakSeconds', type = 'int', min = 0, max = 120, unit = 's', label = 'A torn pump leaks for', shownWhen = HOSE,
              help = 'It leaves a trail of petrol behind it this long: a trail that burns.' },
            { key = 'Hose.FireAtBase', type = 'bool', label = 'Its island catches fire', shownWhen = HOSE,
              help = 'Off by default: a pump on fire blows up before it can be dragged away.' },
        } },
    },
})
