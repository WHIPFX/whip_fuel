# whip_fuel

Fuel for whip: a tank on every car that driving burns, petrol pumps (a nozzle on each side, paid at the pump), jerry
cans, and the pump's hose. Without this resource whip has no fuel at all, and cars just drive.

- **Needs:** whip_core. The hose needs whip_rope as well; without it, the pumps still fill a car.
- **Install:** it comes in the `[whip]` folder, and `ensure [whip]` starts it. Nothing to add to server.cfg, no SQL.
- **Settings:** `/whip` → Settings → Fuel (prices, how fast cars burn it, the stations and their map icons). Or
  `config.lua`.
