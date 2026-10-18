--[[
    The minigames' sound effects. They play on the resource's own page (web/dist), which has an engine
    of its own for them: real recordings (web/dist/sounds, CC0, see CREDITS.txt there), the test light
    hum made live, and loops that follow what the player does. So they are registered as custom, and
    played like any TR.ui.sound, here and for the players watching (TR.mirror):

        TR.ui.sound.play('tick', Config.volume)
        TR.ui.sound.loop('hotwire:buzz', 'buzz', { pattern = 'pulse' }, Config.volume)   -- every frame
        TR.ui.sound.stop('hotwire:buzz')

    Sounds are 2D (not positional): meant for close-up minigames.
]]

local SOUNDS = {
    -- Hotwire
    'tick', 'screw_out', 'slip', 'cover', 'click', 'snip', 'nick', 'relay', 'arc', 'burn', 'sputter',
    -- Lockpick
    'lp_insert', 'lp_lever', 'lp_tension', 'lp_detent', 'lp_spring', 'lp_set', 'lp_overset', 'lp_drop',
    'lp_bend', 'lp_snap', 'lp_unlock', 'lp_remove', 'lp_shutter',
    -- Siphon
    'sf_can_down', 'sf_can_up', 'sf_cap_thread', 'sf_cap_off', 'sf_cap_dangle', 'sf_cap_on', 'sf_cap_tap',
    'sf_ratchet', 'sf_flap', 'sf_bump', 'sf_plop', 'sf_inhale', 'sf_cough', 'sf_drip', 'sf_hose_grab',
    'sf_hose_in', 'sf_hose_out', 'sf_hose_drop', 'sf_funnel_grab', 'sf_funnel_in', 'sf_funnel_out',
    'sf_funnel_down',

    -- Loops, with the params they follow
    'buzz',      -- the test light: { pattern = 'steady' | 'pulse' | 'flicker' | 'dim' }
    'crank',     -- the starter turning, with sparks
    'lp_scrape', -- the pick's hook dragging a wafer: { level }
    'sf_blow', 'sf_gurgle', 'sf_spill', 'sf_feed', -- the siphon's: { level }
    'sf_pour',   -- fuel into the can: { fill, level }
}

local list = {}
for _, name in ipairs(SOUNDS) do list[name] = { custom = true } end
TR.ui.sound.register(list)
