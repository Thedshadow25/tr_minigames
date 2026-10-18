fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'tr_minigames'
author 'TR Scripts'
description 'Physical minigames with custom 3D props'
version '1.1.0'

-- Layout: engine/ is shared by every minigame (the 3D engine itself is in tr_core, see
-- engine/core.lua); each minigame has minigames/<name>/ (code) and stream/<name>/ (built props).
-- Add a minigame's files below. web/dist/ is the resource's own page:
-- the HUD, the prompts and the sounds (web/dist/sounds, CC0 recordings, see its CREDITS.txt).

shared_scripts {
    '@tr_core/init.lua',
    'config.lua',
    'engine/core.lua',

    'minigames/hotwire/config.lua',
    'minigames/hotwire/rig.lua',

    'minigames/lockpick/config.lua',
    'minigames/lockpick/rig.lua',

    'minigames/siphon/config.lua',
    'minigames/siphon/rig.lua',
}

server_scripts {
    'engine/server/vehicles.lua',

    'minigames/hotwire/server/main.lua',

    'minigames/lockpick/server/main.lua',
    'minigames/lockpick/server/fits.lua',

    'minigames/siphon/server/main.lua',
    'minigames/siphon/server/fits.lua',
}

client_scripts {
    'engine/client/sounds.lua',
    'engine/client/vehicles.lua',
    'engine/client/probe.lua',
    'engine/client/devcars.lua',

    'minigames/hotwire/client/fit.lua',
    'minigames/hotwire/client/game.lua',
    'minigames/hotwire/client/main.lua',

    'minigames/lockpick/client/door.lua',
    'minigames/lockpick/client/game.lua',
    'minigames/lockpick/client/main.lua',
    'minigames/lockpick/client/fitter.lua',
    'minigames/lockpick/client/doormap.lua',
    'minigames/lockpick/client/autofit.lua',

    'minigames/siphon/client/placement.lua',
    'minigames/siphon/client/fits.lua',
    'minigames/siphon/client/mechanics.lua',
    'minigames/siphon/client/props.lua',
    'minigames/siphon/client/game.lua',
    'minigames/siphon/client/steps.lua',
    'minigames/siphon/client/main.lua',
    'minigames/siphon/client/fillermap.lua',
    'minigames/siphon/client/fitter.lua',
    'minigames/siphon/client/autofit.lua',
}

ui_page 'web/dist/index.html'

files {
    'locales/*.json',
    'web/dist/index.html',
    'web/dist/assets/*',
    'web/dist/sounds/*.wav',
    'stream/**/*.ytyp',
}

-- Each minigame's ytyp registers its props so they can be spawned.
data_file 'DLC_ITYP_REQUEST' 'stream/hotwire/tr_hotwire.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/lockpick/tr_lockpick.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/siphon/tr_siphon.ytyp'

-- Sounds the page makes itself and frame probes on the resource's own page came with tr_core 1.3.0.
tr_core_version '1.3.0'

dependencies {
    'tr_core',
    '/onesync',
}
