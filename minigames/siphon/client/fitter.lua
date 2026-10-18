--[[
    Fits the filler to every car, one after another (dev mode; saving needs an admin).

        /filler_fitall           every car model that has no saved fit yet, A to Z
        /filler_fitall all       every car model, saved or not
        /filler_fitall review    the fits /filler_autofit wasn't sure about
        /filler_fitall sultan    just this one

    Each car is spawned where you stand (only on your screen) with the filler (bezel, flap and cap)
    where the siphon would put it. Move it onto the car's own fuel door so the bezel sits flat on the
    paint; Enter saves it on the server (minigames/siphon/fits.json, every player gets it at once) and
    brings up the next car. The yellow dot is the car's petroltank bone, if it has one. A car without
    one is fitted on one flank and the fit is mirrored to the side the player stands (as its guess was).

    Models with the same body (baller4 and baller5: exactly the same size) share a fit: a car with no
    fit of its own copies one from the same body instead of coming up (here and in /filler_autofit),
    and saving a fit updates its copies. Fitting a copy by name makes it a fit of its own.

        Arrows/WASD along the car (left / right, up / down)
        Q / E       out of / into the car
        Scroll      tilt up / down (also numpad 8 / 5)
        Z / X       turn left / right (also numpad 4 / 6)
        Shift       1 mm (and a quarter degree) a press instead of 5 mm
        (held)      a move or turn key held down keeps going after a moment: 8 cm (12 degrees) a
                    second, a fifth of that with Shift; tap for small steps
        F           the other side of the car
        C           wide view: the filler against the whole car
        R           undo your changes (back to the saved fit, or the guess)
        Enter       save, next car
        Backspace   skip this car without saving
        Esc         stop
]]

local cfg = Config.siphon

if not cfg.enabled or not cfg.devMode then return end

local FILLER = Siphon.rig.filler
local KEY = { save = 191, skip = 194, stop = 200, wide = 26, reset = 45, side = 23 }
local CLOSE = { pos = vec3(0.10, -0.40, 0.08), target = vec3(0.0, 0.0, 0.0), fov = 40.0 }
local WIDE = 5.0 -- wide view: the camera this many times further out

local running = false
local scene   -- the filler, moved from car to car
local spawned -- the car on screen
local home    -- where the player stood

local function say(text)
    print('[filler fit] ' .. text)
end

-- Shared with autofit.lua.
Siphon.dev = Siphon.dev or {}
local Dev = Siphon.dev

---Electric cars have no filler (the native needs game build 3258).
function Dev.isElectric(hash)
    local ok, electric = pcall(GetIsVehicleElectric, hash)
    return ok and electric == true
end

-- Left out of the fitting runs, as in /lockpick_fitall (asking for one model by name still fits it, and
-- in game these cars still use their petroltank bone or the guess): the classes that can't be siphoned
-- (cfg.blockedClasses) and, not worth fitting, industrial (10), utility (11), service (17),
-- emergency (18), military (19), commercial (20) and open wheel (22).
local SKIP_CLASS = { [10] = true, [11] = true, [17] = true, [18] = true, [19] = true, [20] = true, [22] = true }
for class, blocked in pairs(cfg.blockedClasses) do SKIP_CLASS[class] = blocked or SKIP_CLASS[class] end

---Car models to fit, sorted, for which keep(model, savedFit) is true. Copies of another model's fit
---(same body) are left out: they follow that model (fitting one by name makes it its own).
function Dev.carModels(keep)
    return DevCars.models(SKIP_CLASS, function(model)
        local saved = Siphon.savedFits[model]
        return not Dev.isElectric(joaat(model)) and not (saved and saved.from) and keep(model, saved)
    end)
end

-- Same body ------------------------------------------------------------------------------------
-- Models with the same body (baller4 and baller5) are exactly the same size: the size to the mm is
-- the body's signature. A car without a fit of its own takes the fit of a model with the same body.

local sigs = {} -- model -> signature, worked out this session

---The model's body signature, or nil if it doesn't load.
function Dev.signature(model)
    if sigs[model] then return sigs[model] end
    local saved = Siphon.savedFits[model]
    if saved and saved.sig then
        sigs[model] = saved.sig
        return saved.sig
    end
    local hash = joaat(model)
    if not IsModelInCdimage(hash) then return end
    local loaded = HasModelLoaded(hash)
    if not loaded then
        RequestModel(hash)
        local deadline = GetGameTimer() + 3000
        while not HasModelLoaded(hash) do
            if GetGameTimer() > deadline then return end
            Wait(0)
        end
    end
    local min, max = GetModelDimensions(hash)
    if not loaded then SetModelAsNoLongerNeeded(hash) end
    local function mm(v) return math.floor(v * 1000 + 0.5) end
    sigs[model] = ('%d,%d,%d/%d,%d,%d'):format(mm(min.x), mm(min.y), mm(min.z), mm(max.x), mm(max.y), mm(max.z))
    return sigs[model]
end

---A saved fit of another model with the same body: model, fit (its own fit's source, not a copy).
function Dev.twin(model)
    local sig = Dev.signature(model)
    if not sig then return end
    local names = {}
    for other in pairs(Siphon.savedFits) do names[#names + 1] = other end
    table.sort(names)
    for _, other in ipairs(names) do
        local fit = Siphon.savedFits[other]
        if other ~= model and not fit.from and Dev.signature(other) == sig then return other, fit end
    end
end

---Saves `fit` for model on the server (with its body signature). Returns ok, err.
function Dev.save(model, fit)
    fit.sig = Dev.signature(model)
    local ok, err = TR.callback.await('tr_minigames:siphon:saveFit', model, fit)
    if ok then Siphon.savedFits[model] = fit end
    return ok, err
end

---Copies source's fit to `model` (same body) and keeps the copies of `source` in step with it.
local function copyOf(source, fit)
    return { x = fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = fit.yaw, auto = fit.auto, check = fit.check,
        both = fit.both, from = source }
end

---After saving source's own fit: every model copied from it gets the new one. Returns how many.
function Dev.updateCopies(source)
    local fit, n = Siphon.savedFits[source], 0
    for model, saved in pairs(Siphon.savedFits) do
        if saved.from == source and Dev.save(model, copyOf(source, fit)) then n = n + 1 end
    end
    if n > 0 then say(('  and %d model%s with the same body'):format(n, n == 1 and '' or 's')) end
    return n
end

---If a model with the same body has a fit, saves a copy of it for `model`. Returns the source model.
function Dev.copyTwin(model)
    local source, fit = Dev.twin(model)
    if source and Dev.save(model, copyOf(source, fit)) then
        say(('%s has the same body as %s: copied its fit'):format(model, source))
        return source
    end
end

---The car's petroltank bone (world), if it has one.
function Dev.bone(vehicle)
    for _, name in ipairs({ 'petroltank', 'petroltank_l', 'petroltank_r' }) do
        local bone = GetEntityBoneIndexByName(vehicle, name)
        if bone ~= -1 then return GetWorldPositionOfEntityBone(vehicle, bone), name end
    end
end

---The filler as it looks shut: bezel, flap and cap.
function Dev.spawnFiller(s)
    s:spawn('filler', 'tr_sf_filler')
    s:spawn('flap', 'tr_sf_flap', FILLER.flapHinge)
    s:spawn('fuelcap', 'tr_sf_fuelcap', FILLER.cap.seat, FILLER.cap.rot)
end

---Car models to fit: unfitted ones, 'all', 'review' (auto fits marked for a look) or one model.
local function models(arg)
    if arg == 'review' then return Dev.carModels(function(_, saved) return saved and saved.check end) end
    if arg and arg ~= 'all' then return { arg:lower() } end
    return Dev.carModels(function(_, saved) return arg == 'all' or not saved end)
end

---Removes the car and the filler and gives the player back.
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

local function hud(model, index, total, fit, source, wide, both)
    local function mm(v) return ('%d mm'):format(math.floor(v * 1000 + 0.5)) end
    local function deg(v) return ('%.1f°'):format(v) end

    TR.ui.hud.set({
        tools = {
            { label = model, progress = ('%d / %d'):format(index, total), active = true },
            { label = 'X', progress = mm(fit.x) },
            { label = 'Y', progress = mm(fit.y) },
            { label = 'Z', progress = mm(fit.z) },
            { label = 'Tilt', progress = deg(fit.pitch) },
            { label = 'Turn', progress = deg(fit.yaw) },
            { label = 'Fit', progress = fit.check and (source .. ', check') or fit.auto and (source .. ', auto') or source },
            { label = 'Sides', progress = both and 'both (mirrored)' or 'this one' },
        },
        hint = {
            text = 'Fit the filler on the car\'s fuel door',
            keys = {
                { key = 'WASD', label = 'Move (hold)' },
                { key = 'Q/E', label = 'Out / in' },
                { key = 'Scroll', label = 'Tilt' },
                { key = 'Z/X', label = 'Turn' },
                { key = 'Shift', label = 'Fine' },
                { key = 'F', label = 'Other side' },
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
local function fitOne(vehicle, model, index, total)
    local wide = false
    local side = -1 -- where the guess goes on a car without a petroltank bone (F flips it)

    ---The fit shown: live, saved, from the config or the guess.
    local function shown()
        local fit, source = Siphon.fit(model)
        if fit then return fit, source end
        local bone = Dev.bone(vehicle)
        return Siphon.guessFit(vehicle, side), bone and 'bone' or 'guess'
    end

    local function place()
        local fit = shown()
        if fit then scene:setPlacement(vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw) end
    end

    local function aim()
        if wide then scene:moveCamera(CLOSE.pos * WIDE, CLOSE.target) else scene:moveCamera(CLOSE.pos, CLOSE.target) end
    end

    place()
    aim()

    while true do
        DisableAllControlActions(0)
        HideHudAndRadarThisFrame()

        local moved = Siphon.nudged(model, vehicle, side)
        if moved then
            Siphon.liveFits[model] = moved
            place()
        end

        if IsDisabledControlJustPressed(0, KEY.reset) then
            Siphon.liveFits[model] = nil
            place()
        elseif IsDisabledControlJustPressed(0, KEY.side) then
            local fit = Siphon.fit(model)
            if fit then
                Siphon.liveFits[model] = Siphon.mirrorFit(fit)
            else
                side = -side
                if Dev.bone(vehicle) then
                    -- The bone fixes the guess's side: mirror it into a live fit instead.
                    local guess = shown()
                    if guess then Siphon.liveFits[model] = Siphon.mirrorFit(guess) end
                end
            end
            place()
        elseif IsDisabledControlJustPressed(0, KEY.wide) then
            wide = not wide
            aim()
        elseif IsDisabledControlJustPressed(0, KEY.save) then
            -- Saved by hand: no longer marked for a check.
            local fit = shown()
            if fit then
                local saving = { x = fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = fit.yaw, both = not Dev.bone(vehicle) or nil }
                local ok, err = Dev.save(model, saving)
                if ok then
                    Siphon.liveFits[model] = nil
                    say('saved ' .. model)
                    Dev.updateCopies(model)
                    return 'saved'
                end
                TR.notify.send({ description = 'Not saved: ' .. tostring(err), type = 'error' })
            end
        elseif IsDisabledControlJustPressed(0, KEY.skip) then
            Siphon.liveFits[model] = nil
            return 'skipped'
        elseif IsDisabledControlJustPressed(0, KEY.stop) then
            Siphon.liveFits[model] = nil
            return 'stop'
        end

        local bone = Dev.bone(vehicle)
        if bone then
            DrawMarker(28, bone.x, bone.y, bone.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.006, 0.006, 0.006, 255, 220, 0, 200,
                false, false, 2, false, nil, nil, false)
        end

        scene:update()
        scene:torch(0.6)
        local fit, source = shown()
        if fit then hud(model, index, total, fit, source, wide, not bone) end
        Wait(0)
    end
end

local function run(arg)
    local list = models(arg)
    if #list == 0 then return say('every car already has a saved fit (use /filler_fitall all to redo them)') end
    say(('%d cars to fit'):format(#list))

    local ped = PlayerPedId()
    local at, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    home = at
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityVisible(ped, false, false)

    local saved, skipped = 0, 0

    -- Asked for one model by name: fit that one, even if a model with the same body has a fit.
    local named = arg and arg ~= 'all' and arg ~= 'review'
    local copied = 0

    for index, wanted in ipairs(list) do
        local twin = not named and not Siphon.savedFits[wanted] and Dev.copyTwin(wanted)
        local vehicle = not twin and DevCars.spawn(wanted, at, heading) or nil
        spawned = vehicle

        if twin then
            copied = copied + 1
        elseif not vehicle then
            say(wanted .. ': could not load the model, skipped')
            skipped = skipped + 1
        else
            local model = Siphon.modelName(vehicle)
            local start = Siphon.fit(model) or Siphon.guessFit(vehicle, -1)

            if not start then
                say(model .. ': no petroltank bone and no rear wheel to guess from, skipped')
                skipped = skipped + 1
            else
                local offset = vec3(start.x, start.y, start.z)
                if not scene then
                    scene = Scene.new(vehicle, offset, start.pitch, start.yaw)
                    Dev.spawnFiller(scene)
                    scene:createCamera(CLOSE.pos, CLOSE.target, CLOSE.fov)
                else
                    scene.entity = vehicle
                    scene:setPlacement(offset, start.pitch, start.yaw)
                end

                local result = fitOne(vehicle, model, index, #list)
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
    say(('done: %d saved, %d copied from a model with the same body, %d skipped'):format(saved, copied, skipped))
end

RegisterCommand('filler_fitall', function(_, args)
    if running then return say('already fitting') end
    if Siphon.current then return say('finish siphoning first') end
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
