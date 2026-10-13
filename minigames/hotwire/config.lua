-- Hotwire settings. Values every server owner may want to change. Keep logic out of this file.
Config.hotwire = {
    enabled = true, -- false turns the hotwire minigame off

    command = 'hotwire',
    key = 'G', -- default key; players can rebind it in Settings > Key Bindings > FiveM

    item = 'wire_strippers', -- item needed to hotwire, false for none
    breakChance = 0.35,      -- chance the item breaks when an attempt fails

    -- Admins can hotwire any car, even one they have keys for or that is running, and get the
    -- prop tuning tools (/hotwire_rig, /hotwire_cam). Keep it off on a live server.
    devMode = false,

    vehicleTypes = { automobile = true }, -- GetVehicleType values that can be hotwired
    maxStrikes = 3,
    timeLimit = 240, -- seconds before an attempt expires
    minTime = 10,    -- seconds; a faster success is rejected as cheating
    minRewireTime = 5, -- same, when the cover was already off from an earlier attempt
    minReconnectTime = 3, -- same, when the car was hotwired before (only twisting and cranking left)

    -- Give keys (through TR.keys) after a successful hotwire. Off: the car only starts, and turning the
    -- engine off means wiring it again (the cover stays off). With zyke_vehiclekeys a hotwired car runs
    -- without keys. The other supported keys scripts keep the engine off for players without keys, so
    -- turn this on when you run one of those.
    giveKeys = false,

    screws = {
        turns = 4,      -- full turns to undo a screw
        maxSpeed = 3.5, -- turns per second before the screwdriver slips
    },
    strip = {
        maxSpeed = 0.05, -- metres per second you can pull the insulation before nicking the copper
    },
    crank = {
        earliest = 900, -- ms: the engine can catch from a random time between earliest and latest
        latest = 2200,
        window = 800,   -- ms the engine stays catchable; holding past it burns the starter wire
    },

    alarmTime = 30,  -- seconds the alarm sounds after a failed attempt
    shockDamage = 8, -- health lost to a short circuit

    -- Where the column sits, from the vehicle's steering wheel. Tune live with /hotwire_rig.
    rig = { offset = vec3(0.0, 0.03, -0.08), pitch = -18.0 },

    -- Bigger vehicles sit the column lower and further back, so the cover would clip into their dash.
    -- By GetVehicleClass: 9 off-road, 10 industrial, 11 utility, 12 vans, 17 service, 20 commercial.
    classFits = {
        [9] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [10] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [11] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [12] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [17] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [20] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
    },

    -- Single models that still don't fit, by model name. These win over classFits. /hotwire_rig prints these lines.
    vehicleFits = {
        -- ['sultan'] = { offset = vec3(0.0, 0.01, -0.09), pitch = -20.0 },
    },

    -- Camera in rig space: looking up at the cover, then down at the wires once it is off.
    camera = {
        pos = vec3(0.02, -0.17, -0.30), target = vec3(0.0, 0.10, -0.07),
        wiresPos = vec3(0.03, -0.36, -0.21), wiresTarget = vec3(0.0, 0.08, -0.15),
        fov = 46.0,
    },

    sparks = { asset = 'core', name = 'ent_sht_electrical_box', scale = 0.12 },
}
