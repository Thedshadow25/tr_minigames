# Installing tr_minigames

Everything a server owner needs to set up, besides dropping the resource in.

## 1. Resources

Start them in this order in `server.cfg`:

```cfg
ensure tr_core
ensure tr_minigames
```

## 2. Items

| Item | Minigame | Image |
|---|---|---|
| `wire_strippers` | Hotwire: needed to hotwire a car (can break on a failed attempt) | `images/wire_strippers.png` |
| `lishi_pick` | Lockpick: needed to pick a door lock (lost when it snaps) | `images/lishi_pick.png` |
| `siphon_hose` | Siphon: needed to siphon fuel (not used up). The fuel goes into GTA's jerry can (`WEAPON_PETROLCAN`), which ox_inventory and qb-core already have; the player needs one in their inventory with room in it | `images/siphon_hose.png` |

Change or remove the required item with `item` in `minigames/hotwire/config.lua` and
`minigames/lockpick/config.lua` and `minigames/siphon/config.lua` (`false` = no item needed).

### ox_inventory (ESX, Qbox, or QBCore with ox_inventory)

1. Paste the entries from [`ox_inventory/items.lua`](ox_inventory/items.lua) into
   `ox_inventory/data/items.lua`.
2. Copy `images/*.png` to `ox_inventory/web/images/`.
3. Restart the server (ox_inventory reads items at start).

Using the Lishi pick or the siphon hose from the inventory starts lockpicking or siphoning (the
`client.export` lines).

### qb-inventory (QBCore)

1. Paste the entries from [`qb-inventory/items.lua`](qb-inventory/items.lua) into
   `qb-core/shared/items.lua` (inside `QBShared.Items`).
2. Copy `images/*.png` to `qb-inventory/html/images/`.
3. Restart the server.

With qb-inventory the items aren't "usable" from the inventory: players start the minigames with
**G** (or `/hotwire`, `/lockpick`), `/siphon`, or the "Pick the lock" and "Siphon fuel" target options.

## 3. Optional

- A vehicle keys script (qbx/qb vehiclekeys, wasabi_carlock, MrNewbVehicleKeys, Renewed-Vehiclekeys)
  is picked up automatically by tr_core.
- Turn `devMode` off in the minigame configs on live servers (`minigames/<name>/config.lua`).
- After updating the resource, players need a full reconnect to load new props.
