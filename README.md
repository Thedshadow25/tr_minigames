# tr_minigames

Physical minigames for FiveM, each played by hand on its own custom 3D props: no progress bars and no
skill-check circles. Players nearby see the props and particles and hear the sounds too.

- **Hotwiring**: unscrew the steering column's cover, find the wires with a test light, strip them,
  twist battery and ignition together and crank the starter.
- **Lockpicking**: pick a car door's wafer lock with a Lishi-style pick, one wafer at a time, by feel.

The server decides every step of both, so a modified client can't skip the puzzle.

## Requirements

- [tr_core](https://github.com/Thedshadow25/tr_core) 1.3.0 or newer. It is the only resource needed:
  the HUD, the prompts and the sounds are on tr_minigames' own page.
- OneSync.
- ESX, QBCore or Qbox, with ox_inventory or qb-inventory. ox_target or qb-target is optional (it adds
  "Pick the lock" on door handles). tr_core finds what the server runs by itself.

## Installing

1. Put the folder in your resources as `tr_minigames` and start it after tr_core:

   ```cfg
   ensure tr_core
   ensure tr_minigames
   ```

2. Add the two items (`wire_strippers`, `lishi_pick`) and their icons: [install/README.md](install/README.md)
   has the entries for ox_inventory and qb-inventory.
3. Settings are in `config.lua` (sound volume, how far the props and sounds carry) and in each
   minigame's `minigames/<name>/config.lua`, where it can also be turned off (`enabled = false`).
   Text is in `locales/en.json`.

After updating the resource, players need a full reconnect to load new props.

## Hotwiring

Sit in the driver's seat of a car you have no keys for and press **G** (`/hotwire`, rebindable).
The camera drops under the steering column:

1. **Cover**: hold LMB on each screw and circle the mouse counter-clockwise. Too fast and the
   screwdriver slips.
2. **Test light** (`1`): hold LMB on a wire. Steady = battery, pulsing = ignition, flickering =
   starter; the rest are dim or dead. Which colour is which is random every attempt.
3. **Strippers** (`2`): grab a wire end and pull down slowly. Pulling too fast nicks the copper (a strike).
4. **Hands** (`3`): drag the bare battery wire onto the bare ignition wire to twist them, then hold
   the starter against the twist and let go inside the green part of the meter.

Three strikes (nicks, shorts, a burnt starter wire) and the alarm goes off; the strippers may break.
The server decides every step, so a modified client can't skip the puzzle. The on-screen hints,
tools, strikes and meters are drawn on the resource's own page (`TR.ui.hud`).

- Needs the `wire_strippers` item. Item entries for ox_inventory and qb-inventory plus the icon are
  in `install/` (see its README).
- Settings are in `minigames/hotwire/config.lua` (`Config.hotwire`).
- `devMode` (off by default) lets admins hotwire any car, even one with keys or a running engine,
  and turns on `/hotwire_rig` and `/hotwire_cam`. Turn it off on live servers.
- Hotwired cars get `Entity(vehicle).state.tr_hotwired = true`. By default (`giveKeys = false`) the car
  only starts: no keys, and once its engine is off it has to be wired again. The cover stays off
  (`state.tr_hotwire_cover`), the wires stay found and stripped, and battery and ignition stay
  twisted, so wiring it again is only cranking the starter on the twist (`minReconnectTime`). After a
  tr_minigames restart the server has forgotten the wires, so that attempt starts at the test light. With zyke_vehiclekeys the car runs without
  keys (`TR.keys.startEngine`). The other supported keys scripts keep the engine off for players
  without keys, so set `giveKeys = true` when you run one of those.
- Without a keys script everyone "has keys", so only admins in `devMode` can hotwire.
- Players near the car see the props and sparks and hear the sounds (quieter further away). The
  hotwiring player's client sends what changed about 10 times a second; the server keeps the latest
  state, checks it (only `tr_hw_*` models, positions near the column) and passes it on to players
  within `Config.mirror.range` (`config.lua`). See `tr_core/modules/mirror`.
- `/hotwire_rig <x> <y> <z> [pitch]` (dev mode) moves the column live, so you can fit it to a car's
  interior. Copy the printed line into `vehicleFits`.

## Lockpicking

Stand at the driver's door of a locked car and press **G** (`/lockpick`, rebindable), use the
`lishi_pick` item, or pick "Pick the lock" on the door handle with ox_target / qb-target. The player
walks up to the lock, the camera moves in close, and a Lishi-style 2-in-1 pick goes into the keyway.
The lock is a real wafer lock: 8 positions, some empty, each wafer cut to one of 4 depths.

- **RMB** (hold): light turning tension. Without tension nothing binds; letting go drops every set wafer.
- **Scroll** or **A / D**: move the pick to the next wafer. The pointer on the plate shows which one.
- **LMB** (hold) + push the mouse up: lift the wafer under the hook.

With tension on, one wafer binds at a time. Free wafers feel springy and light; the binding one is
stiff (the pressure meter climbs and you hear it drag). Once you've felt it, the HUD shows how deep
it's cut (`d1` to `d4`), and the pointer on the plate reads the hook's lift against the same depth
lines, the way a real Lishi is read. Lift it slowly until it clicks at the shear line: it stays up,
the plug gives a hair, and the next wafer binds. Lift a wafer too far and it oversets: it jams the plug until you let off the tension and start over. Push on
against a wafer that won't move and the pick bends: three bends (`maxStrikes`) and it snaps. The tip
stays jammed in the lock for a while (`jamTime`), the item is lost (`breakChance`) and the alarm
goes off. When every wafer is set the plug turns a quarter and the door unlocks (no keys: hotwire
next). Some cars have an alarm that goes off when the door opens (`classAlarm`).

The server holds the lock (which wafers, their depths and the binding order) and checks every
click, so a modified client can't pick it faster than a person could. A car keeps the same lock
(by plate) until the server restarts. Picking needs light hands, not speed.

- Needs the `lishi_pick` item. Item entries for ox_inventory and qb-inventory plus the icon are
  in `install/` (see its README).
- Settings are in `minigames/lockpick/config.lua` (`Config.lockpick`). How hard the lock is
  (wafer count, how much overset it forgives, how stiff it is) depends on the vehicle class
  (`difficulty`, `classDifficulty`).
- `devMode` (off by default) lets admins pick cars they have keys for and turns on the fitting
  tools below. Turn it on while setting up, off on live servers.
- **G** is shared with hotwiring: on foot it picks a door lock, in the driver's seat it hotwires.
- For police scripts: `AddEventHandler('tr_minigames:lockpick:alarm', function(src, netId, coords, reason) end)`
  on the server fires when the pick snaps (`reason = 'failed'`) or an alarmed car is opened (`'opened'`).
- For logs, XP or stress: `AddEventHandler('tr_minigames:lockpick:picked', function(src, netId, plate) end)`
  on the server fires when a player picks a lock (the door is unlocked).
- **Fitting every car automatically**: `/lockpick_autofit` (dev mode, saving needs an admin, on
  foot) fits the lock to every car model on the server that has no fit yet, addon and escrowed cars
  included, with nobody at the keyboard (a few seconds a car). Scripts can't see a car's
  bodywork, only its collision (which can sit centimetres inside the paint, and handles have none),
  so it measures what is drawn: tiny magenta markers along lines of sight into the driver's door,
  and the resource's page reads the game frame to see which the door hides. That gives a depth map of the door
  to under a millimetre, a point every centimetre. What stands out is judged against the paint
  around it (the door's own curve at each place), so round old doors that roll over under the
  window and tuck under at the bottom read as well as flat modern ones; the handle and its pocket
  stand out, and trim strips and body lines along the door don't confuse it. Cars with a lock of
  their own (the round knob by the handle on older cars) get ours right over it. Otherwise the
  flattest spots near the handle (ahead of it first) get a finer map, and the lock is seated there
  like a real one: tilted to rest on the paint's high points, so nothing pokes through it, even on
  curved or uneven doors. `/lockpick_autofit redo` (or `all`)
  refits cars fitted automatically before (fits made by hand are never overwritten), `<model>` one
  car; add `show` (`/lockpick_autofit blade show`) to see the door map it read for 8 s. A bar at
  the bottom shows the car it is on, how many are left, what it is doing and roughly how long the
  rest will take. Esc stops (run it again to carry on), Backspace skips a car. It prints what it
  found for each car to F8; at the end it lists the cars it couldn't fit, and fits it wasn't sure
  about are marked `check`.
- **Fitting by hand**: `/lockpick_fitall` brings up every car without a fit, one after another,
  with the Lishi in the driver's door lock; `/lockpick_fitall review` brings up the auto fits marked
  `check`. Arrows move the lock along the door, Q / E out of / into it (Shift for 1 mm steps),
  the scroll wheel (or numpad 8 / 5) tips its face up / down and Z / X (or numpad 4 / 6) tilt it
  left / right (1°, Shift ¼°; while picking in dev mode only the numpad, the wheel moves the pick), C
  toggles a wide view, R undoes your changes, Enter saves and shows the next car, Backspace skips,
  Esc stops. `/lockpick_fitall all` goes through every car, `/lockpick_fitall <model>` one.
- Fits from both are saved to `minigames/lockpick/fits.json` (one line per model) and reach every
  player straight away; they win over `vehicleFits` in the config. Ship that file with the script
  so customers start with every vanilla car fitted.
- `/lockpick_rig <back> <up> [out]` (dev mode) moves the lock live along the door (from the
  handle: back, up, out from the skin), so you can fit it to a car. Copy the printed line into
  `vehicleFits`. While picking in dev mode, the arrow keys (along the door) and Q / E
  (out/in) nudge it 5 mm a press and print the same line. `/lockpick_cam <x> <y> <z> <targetX> <targetY> <targetZ>` tunes the camera.

## Development

The page in `web/dist` is built: nothing to compile to run the resource. Its source, the Blender scripts
the props are generated from and the tests are in the TR Scripts development repository, not in this one.

## License

Copyright (C) 2026 TR Scripts

tr_minigames is free software: you can redistribute it and/or modify it under the terms of the GNU
General Public License as published by the Free Software Foundation, either version 3 of the License,
or (at your option) any later version. It is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See [LICENSE](LICENSE) for the details.

Third-party parts keep their own licences: the sound effects are CC0 recordings from freesound.org
(`web/dist/sounds/CREDITS.txt`), and the libraries and font built into the page are listed with their
licences in `web/dist/THIRD_PARTY_NOTICES.txt`.
