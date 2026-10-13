--[[
    Fits the lock to every car, one after another (dev mode; saving needs an admin).

        /lockpick_fitall           every car model that has no saved fit yet, A to Z
        /lockpick_fitall all       every car model, saved or not
        /lockpick_fitall review    the fits /lockpick_autofit wasn't sure about
        /lockpick_fitall sultan    just this one

    Each car is spawned where you stand (only on your screen) with the Lishi in its driver's door
    lock. Move the lock until it sits right; Enter saves it on the server (minigames/lockpick/fits.json,
    every player gets it at once) and brings up the next car.

        Arrows      along the door (left / right, up / down)
        Q / E       out of / into the door
        Scroll      tilt up / down (also numpad 8 / 5)
        Z / X       tilt left / right (also numpad 4 / 6)
        Shift       1 mm a press instead of 5 mm
        C           wide view: the lock against the whole door
        R           undo your changes (back to the saved fit, or the default spot)
        Enter       save, next car
        Backspace   skip this car without saving
        Esc         stop
]]

local cfg = Config.lockpick

if not cfg.enabled or not cfg.devMode then return end

local Rig = Lockpick.rig
local DOOR = 'dside_f'
local LEVER_OPEN, SHUTTER_OPEN = 52.0, 88.0 -- the lever out, the shutter pushed in: as when picking
local WIDE = 4.0                            -- wide view: the camera this many times further out
local KEY = { save = 191, skip = 194, stop = 200, wide = 26, reset = 45 }

-- Left out of the fitting runs (asking for one model by name still fits it). No door lock:
-- motorcycles (8), cycles (13), boats (14), helicopters (15), planes (16), trains (21). Not worth
-- fitting: industrial (10), utility (11), service (17), emergency (18), military (19),
-- commercial (20) and open wheel (22).
local SKIP_CLASS = {
    [8] = true, [13] = true, [14] = true, [15] = true, [16] = true, [21] = true,
    [10] = true, [11] = true, [17] = true, [18] = true, [19] = true, [20] = true, [22] = true,
}

local running = false
local scene   -- the lock and Lishi, moved from car to car
local spawned -- the car on screen
local home    -- where the player stood

local function say(text)
    print('[lockpick fit] ' .. text)
end

-- Shared with autofit.lua.
Lockpick.dev = Lockpick.dev or {}
local Dev = Lockpick.dev

---Car models, sorted, for which keep(model, savedFit) is true.
function Dev.carModels(keep)
    return DevCars.models(SKIP_CLASS, function(model) return keep(model, Lockpick.savedFits[model]) end)
end

---Car models to fit: unfitted ones, 'all', 'review' (auto fits marked for a look) or one model.
local function models(arg)
    if arg == 'review' then return Dev.carModels(function(_, saved) return saved and saved.check end) end
    if arg and arg ~= 'all' then return { arg:lower() } end
    return Dev.carModels(function(_, saved) return arg == 'all' or not saved end)
end

---Removes the car and the tool and gives the player back.
local function cleanup()
    TR.ui.hud.hide()
    if spawned and DoesEntityExist(spawned) then DeleteEntity(spawned) end
    if scene then scene:destroy() end
    spawned, scene = nil, nil

    local ped = PlayerPedId()
    if home then SetEntityCoordsNoOffset(ped, home.x, home.y, home.z, false, false, false) end
    home = nil
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
end

---A local, frozen, locked copy of the car where the player stands.
Dev.spawn = DevCars.spawn

---The lock and the Lishi as they sit while picking: lever out, shutter pushed in.
function Dev.spawnTool(scene)
    scene:spawn('bezel', 'tr_lp_bezel')
    scene:spawn('plug', 'tr_lp_plug')
    scene:spawn('shutter', 'tr_lp_shutter', Rig.shutterHinge, Mat.axis('x', SHUTTER_OPEN))
    scene:spawn('lishi', 'tr_lp_lishi')
    scene:spawn('pick', 'tr_lp_lishi_pick', vec3(0.0, Rig.wafers[#Rig.wafers] - Rig.tip.y, 0.0))
    local swing = Mat.axis('z', -LEVER_OPEN)
    scene:spawn('lever', 'tr_lp_lishi_lever', Rig.leverPivot - Mat.apply(swing, Rig.leverPivot), swing)
end

local function hud(model, index, total, wide)
    local fit, source = Lockpick.fit(model)
    local function mm(v) return ('%d mm'):format(math.floor(v * 1000 + 0.5)) end

    local tools = { { label = model, progress = ('%d / %d'):format(index, total), active = true } }
    if fit.x then
        -- Measured (or moved from measured): where it is in the car's space.
        tools[2] = { label = 'X', progress = mm(fit.x) }
        tools[3] = { label = 'Y', progress = mm(fit.y) }
        tools[4] = { label = 'Z', progress = mm(fit.z) }
    else
        tools[2] = { label = 'Back', progress = mm(fit.back) }
        tools[3] = { label = 'Up', progress = mm(fit.up) }
        tools[4] = { label = 'Out', progress = mm(fit.out) }
    end
    tools[5] = { label = 'Fit', progress = fit.check and (source .. ', check') or fit.auto and (source .. ', auto') or source }

    TR.ui.hud.set({
        tools = tools,
        hint = {
            text = 'Fit the lock',
            keys = {
                { key = 'Arrows', label = 'Move' },
                { key = 'Q/E', label = 'Out / in' },
                { key = 'Scroll', label = 'Tilt' },
                { key = 'Z/X', label = 'Tilt left / right' },
                { key = 'Shift', label = '1 mm' },
                { key = 'C', label = wide and 'Close view' or 'Wide view' },
                { key = 'R', label = 'Undo' },
                { key = 'Enter', label = 'Save' },
                { key = '⌫', label = 'Skip' },
                { key = 'Esc', label = 'Stop' },
            },
        },
    })
end

---Fits one car. Returns 'saved', 'skipped' or 'stop'.
local function fitOne(scene, vehicle, model, index, total)
    local cam = cfg.camera
    local wide = false

    local function place()
        local offset, pitch, yaw = Lockpick.placement(vehicle, DOOR)
        if offset then scene:setPlacement(offset, pitch, yaw) end
    end

    local function aim()
        if wide then scene:moveCamera(cam.pos * WIDE, cam.target) else scene:moveCamera(cam.pos, cam.target) end
    end

    while true do
        DisableAllControlActions(0)

        local moved = Lockpick.nudged(model, vehicle, true)
        if moved then
            Lockpick.liveFits[model] = moved
            place()
        end

        if IsDisabledControlJustPressed(0, KEY.reset) then
            Lockpick.liveFits[model] = nil
            place()
        elseif IsDisabledControlJustPressed(0, KEY.wide) then
            wide = not wide
            aim()
        elseif IsDisabledControlJustPressed(0, KEY.save) then
            -- Saved by hand: no longer marked for a check.
            local fit = {}
            for k, v in pairs(Lockpick.fit(model)) do fit[k] = v end
            fit.check = nil
            local ok, err = TR.callback.await('tr_minigames:lockpick:saveFit', model, fit)
            if ok then
                Lockpick.savedFits[model] = fit
                Lockpick.liveFits[model] = nil
                say('saved ' .. model)
                return 'saved'
            end
            TR.notify.send({ description = 'Not saved: ' .. tostring(err), type = 'error' })
        elseif IsDisabledControlJustPressed(0, KEY.skip) then
            Lockpick.liveFits[model] = nil
            return 'skipped'
        elseif IsDisabledControlJustPressed(0, KEY.stop) then
            Lockpick.liveFits[model] = nil
            return 'stop'
        end

        scene:update()
        scene:torch(cfg.torch or 0.6)
        hud(model, index, total, wide)
        Wait(0)
    end
end

local function run(arg)
    local list = models(arg)
    if #list == 0 then return say('every car already has a saved fit (use /lockpick_fitall all to redo them)') end
    say(('%d cars to fit'):format(#list))

    local ped = PlayerPedId()
    local at, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    home = at
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityVisible(ped, false, false)

    local saved, skipped = 0, 0

    for index, wanted in ipairs(list) do
        local vehicle = Dev.spawn(wanted, at, heading)
        spawned = vehicle

        if not vehicle then
            say(wanted .. ': could not load the model, skipped')
            skipped = skipped + 1
        else
            local model = Lockpick.modelName(vehicle)
            local offset, pitch, yaw = Lockpick.placement(vehicle, DOOR)

            if not offset then
                say(model .. ': no driver door handle or door bone, skipped')
                skipped = skipped + 1
            else
                if not scene then
                    scene = Scene.new(vehicle, offset, pitch, yaw)
                    Dev.spawnTool(scene)
                    scene:createCamera(cfg.camera.pos, cfg.camera.target, cfg.camera.fov)
                else
                    scene.entity = vehicle
                    scene:setPlacement(offset, pitch, yaw)
                end

                local result = fitOne(scene, vehicle, model, index, #list)
                if result == 'saved' then saved = saved + 1 else skipped = skipped + 1 end

                if result == 'stop' then
                    DeleteEntity(vehicle)
                    spawned = nil
                    break
                end
            end

            if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
            spawned = nil
        end
    end

    cleanup()
    say(('done: %d saved, %d skipped'):format(saved, skipped))
end

RegisterCommand('lockpick_fitall', function(_, args)
    if running then return say('already fitting') end
    if Lockpick.current then return say('finish picking first') end
    if TR.cache.vehicle then return say('get out of the car first') end

    running = true
    CreateThread(function()
        local ok, err = pcall(run, args[1])
        running = false
        if not ok then
            cleanup()
            say('stopped by an error: ' .. tostring(err))
        end
    end)
end, false)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and running then cleanup() end
end)
