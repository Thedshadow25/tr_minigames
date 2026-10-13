-- Settings shared by every minigame in the bundle. Each minigame has its own file as well:
-- minigames/<name>/config.lua (Config.<name>), where it can also be turned off.
Config = {
    volume = 0.8, -- sound effects, 0..1

    -- Players near a minigame see its props and particles and hear its sounds.
    mirror = {
        range = 30.0,      -- metres within which players see the props
        soundRange = 12.0, -- metres the sounds carry (quieter the further away)
        rate = 100,        -- ms between updates the playing player sends
    },
}
