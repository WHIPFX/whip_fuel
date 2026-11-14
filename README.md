# whip_fuel

Fuel for [WHIP](https://github.com/WHIPFX/txAdmin-recipe). Every car has a tank that driving burns, every petrol pump
in the world works, and the jerry can carries fuel to a car. Without whip_fuel, WHIP has no fuel at all and cars just
drive.

## Features

- **A tank on every car,** saved with it, with an E-F gauge by the rev dial. An empty car's engine won't run, but the
  car still rolls and can be pushed. Electric cars use no fuel.
- **Every pump works.** Each side of each pump has its own nozzle. Players carry it to the car's filler, then choose
  how much at the pump and pay in cash or by bank. Fuel that doesn't fit is refunded.
- **The hose.** With [whip_rope](https://github.com/WHIPFX/whip_rope), a hose runs from the pump to the nozzle. Drive
  off with the nozzle in and the car tears a modern pump off its island and drags it, leaking a trail of petrol that
  burns. On an old pump, the hose snaps.
- **Spills.** Starting the pump with its nozzle on the ground or in a hand sprays fuel, and that side goes out of
  order for a minute.
- **Remastered pumps.** GTA's four modern pumps get a screen showing the fill, and the three old pumps' dials show the
  last sale.
- **Jerry cans.** Fill whip_gunny's jerry can at a pump and pour it into a car.
- **Map icons** for every fuel station, edited on a map in game.

## Requirements

- `whip_core`.
- Optional: [whip_rope](https://github.com/WHIPFX/whip_rope) for the hose. Without it, a car that drives off pulls the
  nozzle out and it goes back on its pump.
- Optional: [whip_gunny](https://github.com/WHIPFX/whip_gunny) for the jerry can.

## Installation

WHIP's txAdmin recipe installs it.

By hand, put `whip_fuel` in your `resources` folder and add this line to `server.cfg`, after `ensure whip_core`:

```cfg
ensure whip_fuel
```

There's no SQL to import.

whip_fuel streams its own versions of GTA's pump models (`prop_gas_pump_1a` to `1d`, `prop_gas_pump_old2`,
`prop_gas_pump_old3` and `prop_vintage_pump`). Another resource that streams the same models clashes with it.

## For players

| Where | Option | Does |
| --- | --- | --- |
| The pump's nozzle | **Take Nozzle**, **Put Nozzle Away** | Takes the nozzle off the pump, or hangs it back up |
| The car's filler | **Insert Nozzle**, **Remove Nozzle** | Puts the nozzle in the car, or takes it out |
| The pump | **Fill Up**, **Add 25%**, **50%** or **75%** | Pays (cash or bank) and starts the fill |
| The pump | **Stop Refuelling** | Stops the fill early |
| The pump, jerry can in hand | **Fill Jerry Can** | Fills the can, paid like a car |
| A car's door, jerry can in hand | **Refuel (jerry can)** | Pours the can into the car |

Walk more than 5 m from the pump with its nozzle and it drops. A nozzle left on the ground goes back on its pump
after 30 seconds.

## Configuration

**/whip > Settings > Fuel** has the fuel burn rate, the price, how fast a pump fills a tank, the gauge's place, the
fuel station map icons, and the hose. `config.lua` holds their defaults and the rest: the pumps' reach and timers,
the hose's physics, and the old pumps' dials. A value saved in game wins over `config.lua`.

| Setting | Default |
| --- | --- |
| Fuel price | $1 per percent of a tank. 0 makes fuel free. |
| Empty tank fills in | 120 seconds |
| Fuel burn | 0.03% of the tank a second, driving steadily. Idling burns about a third of that, flat out 2.5 times. |

The map icons only draw icons: refuelling works at every pump either way.

**A map with its own pumps:** add their models to `Config.PumpModels`. Set where the prompts sit on them in
`Config.PumpCircle` and `Config.NozzleCircle`, and where the hose leaves them in `Config.Hose.Outlets`.

## For developers

A car's fuel is the vehicle stat `fuel`, from 0 (empty) to 100 (full). Read and set it with whip_core's vehicle stat
exports, such as `exports.whip_core:SetVehicleStat(vehicleId, 'fuel', 100)`. See **Gas Station: fuel is a stat** in
WHIP's docs (`whip_core/docs.html`).

whip_fuel's pump hose is the worked example of whip_rope's rope API: `server/hose.lua`, described in the docs' **Rope
System**.

## License

whip_fuel is licensed under the GNU LGPL 3.0; see `LICENSE`. Third-party material is listed in `whip_core`'s
`NOTICE.md`.
