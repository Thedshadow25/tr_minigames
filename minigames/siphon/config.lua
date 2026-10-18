-- Fuel siphon settings. Values every server owner may want to change. Keep logic out of this file.
Config.siphon = {
    enabled = true, -- false turns the siphon minigame off

    command = 'siphon',
    target = true, -- add a "Siphon fuel" option to cars when ox_target or qb-target runs

    item = 'siphon_hose', -- item needed to siphon (not used up), false for none
    -- The fuel goes into GTA's jerry can. The player needs one that isn't full; the fullest one that
    -- still has room is filled. ox_inventory keeps a can's fuel in its durability (0..100, as ox_fuel
    -- does); qb-inventory in info.ammo (GTA's 0..4500).
    can = { item = 'WEAPON_PETROLCAN', litres = 20 },

    -- Admins can siphon any car, even a locked one or one with its engine running, and get the
    -- placement tools (/filler_fitall, /filler_autofit). Keep it off on a live server.
    devMode = false,

    -- Where the filler sits on a car model, when the one found (the car's petroltank bone, or a guess on
    -- the flank above a rear wheel) is off. Fits saved with /filler_fitall or /filler_autofit
    -- (minigames/siphon/fits.json) win over these. { x, y, z, pitch, yaw }: on the paint, in the car's
    -- own space; yaw about -90 on the left flank, 90 on the right.
    vehicleFits = {},

    vehicleTypes = { automobile = true }, -- GetVehicleType values with a filler to siphon from
    -- GetVehicleClass values that can't be siphoned: 8 motorcycles, 13 cycles, 14 boats, 15 helicopters,
    -- 16 planes, 21 trains. Electric cars are refused on the client (GetIsVehicleElectric).
    blockedClasses = { [8] = true, [13] = true, [14] = true, [15] = true, [16] = true, [21] = true },
    reach = 4.0, -- metres from the car's middle the player may be (the filler is checked on the client)

    -- Tank sizes turn the fuel scripts' 0..100 into litres. By GetVehicleClass, tankLitres for the rest.
    tankLitres = 60,
    classTank = { [0] = 45, [1] = 60, [2] = 80, [3] = 55, [4] = 70, [5] = 55, [6] = 65, [7] = 75, [9] = 85, [10] = 120,
        [11] = 80, [12] = 90, [17] = 90, [18] = 75, [19] = 120, [20] = 150 },
    reserve = 5, -- percent the hose can't reach: the last of the tank stays in the car

    -- Setup: set the can down, open it and put the funnel in, open the filler, push the siphon hose down
    -- the filler neck into the fuel, put the other end down into the can, and the blow hose in the filler.
    minSetupTime = 8,  -- seconds the setup takes at least (anything faster is refused)

    -- Priming: blow into the thin hose until the fuel crests and runs. `puffs` good puffs are needed (a
    -- random number from the range). A puff that is too hard pushes fuel into the player's mouth (a
    -- strike); at maxStrikes they give up, coughing.
    puffs = { 3, 5 },
    maxStrikes = 3,
    minPuffTime = 1.5, -- seconds between puffs (the clip's puff is 2 s); faster ones are ignored

    flowRate = 0.25,   -- litres per second once the fuel runs (20 litres in 80 s)
    -- Fuel that misses the can (it overflows, or a hose end too shallow in it jumps out) is lost, and
    -- leaves a flammable puddle everyone near sees (GTA's petrol decal) when puddles is on.
    puddles = true,
    timeLimit = 480,   -- seconds before an attempt expires
    cooldown = 20,     -- seconds before the same player can start again
    carCooldown = 120, -- seconds before anyone can siphon a car that was just siphoned

    -- Camera while blowing, from the filler, turned like the player (who faces
    -- the car): +X to the player's right, +Y into the car, +Z up. Behind the player's left shoulder,
    -- looking down the hose. Tune live with /siphon_cam (devMode).
    camera = { pos = vec3(-0.95, -1.35, 0.30), target = vec3(-0.12, -0.25, -0.30), fov = 50.0 },
}
