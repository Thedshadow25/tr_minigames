-- Lockpick settings. Values every server owner may want to change. Keep logic out of this file.
Config.lockpick = {
    enabled = true, -- false turns the lockpick minigame off

    command = 'lockpick',
    key = 'G', -- default key (same as hotwire: G on foot picks a door, G in the driver's seat hotwires)
    prompt = true, -- show "Press G to pick the lock" next to a locked door
    target = true, -- add a "Pick the lock" option to car doors when ox_target or qb-target runs

    item = 'lishi_pick', -- item needed to pick a lock, false for none
    breakChance = 1.0,   -- chance the pick is lost when it snaps (the tip stays in the lock)

    -- Admins can pick any car's lock, even an unlocked one or one they have keys for, and get the
    -- lock fitting tools (/lockpick_autofit, /lockpick_fitall, /lockpick_rig, /lockpick_cam).
    -- Turn it on only while setting up; keep it off on a live server.
    devMode = false,

    vehicleTypes = { automobile = true }, -- GetVehicleType values that have a door lock to pick
    doors = { 'dside_f' }, -- which doors have a lock cylinder: dside_f, pside_f, dside_r, pside_r
    reach = 1.3,           -- metres from a door's lock you can start picking

    maxStrikes = 3,  -- the pick bends this many times, then snaps
    timeLimit = 180, -- seconds before an attempt expires
    minTime = 6,     -- seconds; a faster success is rejected as cheating
    jamTime = 120,   -- seconds a lock stays jammed by a snapped pick tip

    -- Every lock has 8 wafer positions; cheaper locks leave some of them empty. A car keeps the same
    -- lock until the server restarts, so whoever decoded it can pick it again faster.
    --   wafers     how many positions have a wafer
    --   overset    mm a set wafer can be pushed past its shear line before it jams (smaller = harder)
    --   speed      mm per second a binding wafer gives under the pick (smaller = slower, more careful)
    difficulty = {
        easy = { wafers = 4, overset = 1.0, speed = 3.2 },
        medium = { wafers = 5, overset = 0.8, speed = 2.8 },
        hard = { wafers = 6, overset = 0.6, speed = 2.4 },
        expert = { wafers = 7, overset = 0.45, speed = 2.0 },
    },
    defaultDifficulty = 'medium',
    -- By GetVehicleClass: 0 compacts, 1 sedans, 2 SUVs, 3 coupes, 4 muscle, 5 sports classics,
    -- 6 sports, 7 super, 9 off-road, 12 vans, 18 emergency, 19 military.
    classDifficulty = {
        [0] = 'easy', [1] = 'medium', [2] = 'medium', [3] = 'medium', [4] = 'easy', [5] = 'easy',
        [6] = 'hard', [7] = 'expert', [9] = 'easy', [12] = 'easy', [18] = 'expert', [19] = 'expert',
    },

    -- Car alarm. A failed attempt always sets it off. After a success it goes off when the door is
    -- opened, with this chance per vehicle class (defaultAlarm for the rest).
    alarmTime = 30, -- seconds
    defaultAlarm = 0.2,
    classAlarm = { [0] = 0.05, [1] = 0.15, [4] = 0.1, [5] = 0.05, [6] = 0.45, [7] = 0.7, [12] = 0.05, [18] = 1.0 },

    -- Controls. Mouse movement while holding LMB lifts the pick.
    liftSensitivity = 1.0,

    -- Where the lock sits on a door, from the door handle's bone: back (towards the car's rear), up,
    -- and out (away from the door). The door's surface is found with a ray, so `out` is a nudge.
    -- Tune live with /lockpick_rig.
    -- The handle's bone is the middle of the grip and handles aren't in the car's collision, so the
    -- default puts the lock just ahead of the handle (negative back), clear of it, on the side the
    -- camera looks from. `out` lifts the bezel off the collision skin, which sits a little inside
    -- the paint on most cars.
    rig = { back = -0.115, up = 0.0, out = 0.004 },
    followSurface = true, -- turn the lock to sit flat on the door (curved doors lean in at the top)

    -- Single models that need a different spot, by model name. /lockpick_rig prints these lines.
    vehicleFits = {
        -- ['sultan'] = { back = 0.06, up = 0.01, out = 0.0 },
    },

    -- Camera in lock space (+Y into the door): the whole Lishi and the lock in view, with room for
    -- the lever to swing out. Tune live with /lockpick_cam.
    camera = { pos = vec3(-0.136, -0.269, 0.071), target = vec3(0.0, -0.045, 0.002), fov = 46.0 },

    -- A soft light from the camera so the lock can be read at night. Much brighter than this
    -- washes the metal out. 0 turns it off.
    torch = 0.6,
}
