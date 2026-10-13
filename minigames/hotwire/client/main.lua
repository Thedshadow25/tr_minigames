local cfg = Config.hotwire
local function t(key, vars) return TR.locale.t('hotwire.' .. key, vars) end

if not cfg.enabled then return end

local busy = false

local function notify(key, kind)
    TR.notify.send({ description = t(key), type = kind or 'error' })
end

local function hotwire()
    if busy then return end

    local vehicle = TR.cache.vehicle
    if not vehicle then return end -- on foot the same key picks door locks (lockpick)
    if TR.cache.seat ~= -1 then return notify('not_driver') end

    busy = true
    TR.ui.textui.hide('tr_minigames:hotwire')
    local ok, data = TR.callback.await('tr_minigames:hotwire:start', VehToNet(vehicle))

    if not ok then
        busy = false
        return notify(data or 'try_again')
    end

    local result, extra = Hotwire.run(vehicle, data)
    busy = false

    if result == 'started' then
        notify('started', 'success')
    elseif result == 'failed' then
        notify('failed')
        if extra then notify('item_broke', 'warning') end
    elseif result == 'cancelled' then
        notify('cancelled', 'info')
    else
        notify(result or 'try_again')
    end
end

RegisterCommand(cfg.command, hotwire, false)
RegisterKeyMapping(cfg.command, t('keybind'), 'keyboard', cfg.key)

-- Prompt (TR.ui.textui) while sitting in a car you can't start. A hotwired car whose engine was
-- turned off counts too: it has to be wired again.
CreateThread(function()
    local PROMPT = 'tr_minigames:hotwire'

    while true do
        local vehicle = TR.cache.vehicle

        if vehicle and TR.cache.seat == -1 and not busy and not GetIsVehicleEngineRunning(vehicle)
            and not TR.keys.hasKeys(vehicle) then
            TR.ui.textui.show(PROMPT, {
                key = TR.ui.keyOf(cfg.command, cfg.key),
                text = t('prompt_hotwire'),
                sub = cfg.item and t('prompt_item') or nil,
            })
        else
            TR.ui.textui.hide(PROMPT)
        end

        Wait(250)
    end
end)

-- Live fitting of the column to the car you're in: /hotwire_rig <x> <y> <z> [pitch]
-- Prints a line for Config.hotwire.vehicleFits so the fit sticks for that model.
if cfg.devMode then
    RegisterCommand('hotwire_rig', function(_, args)
        local vehicle = TR.cache.vehicle
        if not vehicle then return print('[hotwire] sit in the car you want to fit') end

        local model, class = Hotwire.modelName(vehicle), GetVehicleClass(vehicle)
        local current = Hotwire.fit(model, class)
        local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])

        if x and y and z then
            cfg.vehicleFits[model] = { offset = vec3(x, y, z), pitch = tonumber(args[4]) or current.pitch }
            local game = Hotwire.current
            if game then game.scene:setPlacement(Hotwire.placement(vehicle)) end
        end

        local fit, source = Hotwire.fit(model, class)
        local o = fit.offset
        print(('[hotwire] %s (class %d) uses the %s fit'):format(model, class, source))
        local line = ("['%s'] = { offset = vec3(%.3f, %.3f, %.3f), pitch = %.1f },"):format(model, o.x, o.y, o.z, fit.pitch)
        print('[hotwire] add to Config.hotwire.vehicleFits: ' .. line)
        TR.notify.send({ description = line, type = 'info' })
    end, false)

    -- Live tuning of the camera for the current step: /hotwire_cam <x> <y> <z> <targetX> <targetY> <targetZ>
    RegisterCommand('hotwire_cam', function(_, args)
        local n = {}
        for i = 1, 6 do n[i] = tonumber(args[i]) end

        local game = Hotwire.current
        local wires = game and game.stage ~= 'screws'
        local cam = cfg.camera

        if n[6] then
            local pos, target = vec3(n[1], n[2], n[3]), vec3(n[4], n[5], n[6])
            if wires then cam.wiresPos, cam.wiresTarget = pos, target else cam.pos, cam.target = pos, target end
            if game then game.scene:moveCamera(pos, target) end
        end

        local pos, target = wires and cam.wiresPos or cam.pos, wires and cam.wiresTarget or cam.target
        print(('[hotwire] %s camera %.3f %.3f %.3f -> %.3f %.3f %.3f'):format(wires and 'wires' or 'cover',
            pos.x, pos.y, pos.z, target.x, target.y, target.z))
    end, false)
end
