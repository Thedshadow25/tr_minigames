--[[
    Fits the lock to every car by itself (dev mode; saving needs an admin).

        /lockpick_autofit           every car model that has no saved fit yet
        /lockpick_autofit redo      also redo the ones fitted automatically before (not manual ones)
        /lockpick_autofit all       the same as redo
        /lockpick_autofit sultan    just this one
        /lockpick_autofit sultan show   and show its door map for 8 s (works with the others too)

    Scripts can't see a car's bodywork, only its collision, which can sit centimetres inside the
    paint, and door handles have no collision at all. So this measures what is drawn: the camera
    looks straight at the driver's door, small magenta markers are drawn along each line of sight,
    and the resource's page reads the frame (TR.ui.probeFrame) to see which are hidden behind the door. A binary
    search per line finds the paint to under a millimetre: a depth map of the door around the
    handle. doormap.lua finds the door's surface (as it curves around each place), the handle (and
    its pocket) and the car's own lock if it has one; otherwise the flattest spots close to the
    handle (ahead of it first). A finer map of each says how the lock would sit there: tilted to
    rest on the paint's high points, so nothing pokes through it.

    Each fit is saved like a manual one (minigames/lockpick/fits.json). Fits it isn't sure about
    are marked `check`: go through them with /lockpick_fitall review. Esc stops after the car
    on screen, Backspace skips it.
]]

local cfg = Config.lockpick

if not cfg.enabled or not cfg.devMode then return end

local DOOR, SIDE = 'dside_f', -1      -- the driver's door; out of it is the car's -X
local OUT = vec3(SIDE * 1.0, 0.0, 0.0)
local RADIUS = 0.0195                 -- the bezel (13.5 mm) and a margin, clear of the handle
local ON_PAINT = 0.0015               -- the plug's face this far out from the paint
local COARSE, FINE = 0.010, 0.006     -- sample spacing of the door map and of the spot's map
local COARSE_WIDE = 0.015             -- the door map's spacing when it has to cover the whole door
local OUT_REACH, IN_REACH = 0.20, 0.15 -- the door map searches this far out of / into the door from the handle's bone
local ROUNDS = Probe.ROUNDS           -- binary search steps: 35 cm down to a third of a millimetre
local BEZEL = 0.0145                  -- what the lock rests on: the bezel's radius and a millimetre
local ROUGH, TRIES = 0.004, 3         -- spots worth a closer look: this flat on the door map; how many
local KNOB_WINDOW, KNOB_STEP = 0.05, 0.005   -- the close look at what may be the car's own lock
local SNUG, UNEVEN = 0.001, 0.006     -- mean gap under the bezel that's good; largest gap at all

local running = false
local show = false                    -- /lockpick_autofit <model> show: see the door map
local wide = false                    -- C: the fitted lock shown against the whole door instead of up close
local preview                         -- while a fit is shown: aims the camera at it (again after C)
local WIDE, CLOSE = 4.0, 1.6          -- the preview camera this many times the picking camera's distance
local status                          -- the run's progress on the HUD: { model, index, total, started, phase }

local function say(text)
    print('[lockpick autofit] ' .. text)
end

local function minutes(ms)
    local s = math.floor(ms / 1000 + 0.5)
    if s < 60 then return ('%d s'):format(s) end
    return ('%d min %02d s'):format(s // 60, s % 60)
end

---The run's progress, bottom middle: which car, how many are left and what it is doing. Kept
---below the door map, out of the way of the markers (the frame probe doesn't see the UI anyway).
local function progress(phase)
    if not status then return end
    status.phase = phase or status.phase
    local done, left = status.index - 1, status.total - status.index
    local eta = ''
    if done > 0 and left > 0 then
        eta = ' (about ' .. minutes((GetGameTimer() - status.started) / done * (left + 1)) .. ' to go)'
    end
    TR.ui.hud.set({
        meter = {
            label = ('Car %d of %d, %d left after it'):format(status.index, status.total, left),
            value = done / status.total,
        },
        hint = {
            text = status.model,
            sub = status.phase .. eta,
            keys = {
                { key = 'C', label = wide and 'Zoom in' or 'Zoom out' },
                { key = 'Esc', label = 'Stop' },
                { key = '⌫', label = 'Skip car' },
            },
        },
    })
end

-- Drawing -------------------------------------------------------------------------------------

local function drawThread()
    CreateThread(function()
        while running do
            HideHudAndRadarThisFrame()
            DisableAllControlActions(0)
            if IsDisabledControlJustPressed(0, 200) then Probe.stopAsked = true end
            if IsDisabledControlJustPressed(0, 194) then Probe.skipAsked = true end
            if IsDisabledControlJustPressed(0, 26) then
                -- Only the fitted lock's view moves: the measuring camera has to stay where it is.
                wide = not wide
                if preview then preview() end
                progress()
            end
            Probe.draw()
            Wait(0)
        end
    end)
end

-- Measuring (engine/client/probe.lua) in door space: h out of the driver's door.

local measure, prepare, aim, calibrate = Probe.measure, Probe.prepare, Probe.aim, Probe.calibrate

local function toDoor(vehicle, samples, reference)
    Probe.toSurface(vehicle, samples, reference, SIDE)
end

-- Showing the door map ----------------------------------------------------------------------

---For tuning: the door map for 8 s. Green is plain skin, red something else (the handle, trim, a
---seam), yellow the handle's box, blue the spots it will look at closer (the biggest is first),
---white what may be the car's own lock.
local function showMap(vehicle, map, reference, box, candidates, knobs)
    local list = {}
    local function at(u, v, h) return GetOffsetFromEntityInWorldCoords(vehicle, reference.x + SIDE * h, u, v) end
    for _, s in ipairs(map.samples) do
        if s.h then list[#list + 1] = { at(s.u, s.v, s.h + 0.002), 0.003, color = s.feature and { 255, 40, 40 } or { 40, 255, 40 } } end
    end
    local h = 0.0
    for _, s in ipairs(map.samples) do if s.h then h = s.h break end end
    for _, c in ipairs({ { box.u0, box.v0 }, { box.u0, box.v1 }, { box.u1, box.v0 }, { box.u1, box.v1 } }) do
        list[#list + 1] = { at(c[1], c[2], h + 0.01), 0.006, color = { 255, 220, 0 } }
    end
    for k, c in ipairs(candidates) do
        list[#list + 1] = { at(c.u, c.v, h + 0.01), k == 1 and 0.008 or 0.005, color = { 40, 120, 255 } }
    end
    for _, c in ipairs(knobs) do
        list[#list + 1] = { at(c.u, c.v, h + 0.015), 0.007, color = { 255, 255, 255 } }
    end

    Probe.drawList = list
    local stopAt = GetGameTimer() + 8000
    while GetGameTimer() < stopAt and not Probe.stopAsked and not Probe.skipAsked do Wait(0) end
    Probe.drawList = nil
end

-- One car -------------------------------------------------------------------------------------

---Where collision says the door is at (u, v): a first guess of the paint, for cars without a handle bone.
local function collisionX(vehicle, u, v) return Probe.collisionX(vehicle, u, v, SIDE) end

local place

---Fits one car. Returns the fit and notes, or nil and why.
local function fitCar(vehicle)
    local handle = Scene.boneOffset(vehicle, 'handle_' .. DOOR)
    local hinge = Scene.boneOffset(vehicle, 'door_' .. DOOR)
    if not handle and not hinge then return nil, 'no driver door' end

    -- The area to map, and a reference plane (x = constant) near the paint. The handle's bone can
    -- sit anywhere from the grip to deep in the door, so the search reaches well out and in.
    local region, reference, distance, step
    if handle then
        -- Further down than up: older cars have their own lock under the handle.
        region = { u0 = handle.y - 0.30, u1 = handle.y + 0.30, v0 = handle.z - 0.22, v1 = handle.z + 0.09 }
        reference, distance, step = handle, 0.9, COARSE
    else
        -- No handle bone: map most of the door and find the handle in it.
        region = { u0 = hinge.y - 1.15, u1 = hinge.y - 0.08, v0 = hinge.z - 0.32, v1 = hinge.z + 0.10 }
        local cu, cv = (region.u0 + region.u1) * 0.5, (region.v0 + region.v1) * 0.5
        local x = collisionX(vehicle, cu, cv)
        if not x then
            local min = GetModelDimensions(GetEntityModel(vehicle))
            x = SIDE < 0 and min.x or -min.x
        end
        reference, distance, step = vec3(x, cu, cv), 1.6, COARSE_WIDE
    end

    local center = vec3(reference.x, (region.u0 + region.u1) * 0.5, (region.v0 + region.v1) * 0.5)
    local halfHeight = math.max((region.v1 - region.v0) * 0.5, (region.u1 - region.u0) * 0.5 / GetAspectRatio(false)) * 1.25
    aim(vehicle, center + OUT * distance, center, halfHeight)
    local skinX = collisionX(vehicle, center.y, center.z) or center.x
    calibrate(GetOffsetFromEntityInWorldCoords(vehicle, skinX + SIDE * 0.08, center.y, center.z))

    -- The door map.
    progress('Mapping the door')
    local map = DoorMap.grid(region.u0, region.u1, region.v0, region.v1, step)
    local samples = prepare(vehicle, map.samples, reference, function() return -OUT_REACH end, function() return IN_REACH end)
    measure(samples, ROUNDS)
    toDoor(vehicle, samples, reference)

    local found, blocked = 0, 0
    for _, s in ipairs(map.samples) do
        if s.h then found = found + 1 elseif s.blocked then blocked = blocked + 1 end
    end
    say(('  door map: paint at %d of %d points (%d mm apart), %d in front of it all'):format(
        found, #map.samples, math.floor(step * 1000 + 0.5), blocked))
    if found < #map.samples * 0.2 then
        -- Almost nothing measured: the markers can't be told apart in the frame, or the door isn't there.
        return nil, ('found the door at only %d of %d points'):format(found, #map.samples)
    end

    -- The door's surface as it curves around each place (one smooth curve can't follow a round
    -- old door), then what stands out of it or sits in it.
    progress('Finding the handle')
    local global = DoorMap.fitSkin(map)
    if not global then return nil, 'no door surface' end
    local skin = DoorMap.localSkin(map, global, nil, function() Wait(0) end)
    DoorMap.mark(map, skin)

    local anchor = handle and { u = handle.y, v = handle.z } or nil
    local box = DoorMap.findHandle(map, anchor)
    if not box then return nil, 'no handle found' end
    say(('  handle %s: %d x %d mm'):format(box.found and 'found' or 'not seen, guessed at its bone',
        math.floor((box.u1 - box.u0) * 1000), math.floor((box.v1 - box.v0) * 1000)))

    -- The best few spots on the door map get a finer map of their own, and the lock is seated on
    -- each: tilted to rest on the paint's high points, so nothing pokes through it.
    local candidates = DoorMap.pick(map, DoorMap.spots(box, RADIUS), RADIUS, ROUGH, TRIES)
    local knobs, passed = DoorMap.lockCandidates(map, box)
    for _, c in ipairs(passed) do
        say(('  passed over something standing out %d mm from the handle: %s'):format(math.floor(c.distance * 1000), c.why))
    end
    say(('  %d small thing(s) standing out near the handle that may be the car\'s own lock'):format(#knobs))
    if show then showMap(vehicle, map, reference, box, candidates, knobs) end

    -- Finer maps: every place worth a closer look is measured in one go (as fast as just one),
    -- then gone through in order.
    local function closer(places, window, step, shape, lo, hi, rounds)
        local fines, all = {}, {}
        for k, c in ipairs(places) do
            local fine = DoorMap.grid(c.u - window, c.u + window, c.v - window, c.v + window, step)
            local skinH = skin.height(c.u, c.v)
            local list = prepare(vehicle, shape(fine, c), reference,
                function() return -skinH + lo end, function() return -skinH + hi end)
            for _, s in ipairs(list) do all[#all + 1] = s end
            fines[k] = { map = fine, list = list }
        end
        measure(all, rounds)
        for _, f in ipairs(fines) do toDoor(vehicle, f.list, reference) end
        return fines
    end

    -- The car has a lock of its own (a round knob by the handle): ours goes right over it.
    local knobFines = {}
    if #knobs > 0 then
        progress("Looking closer at the car's own lock")
        knobFines = closer({ table.unpack(knobs, 1, math.min(#knobs, 3)) }, KNOB_WINDOW, KNOB_STEP,
            function(fine) return fine.samples end, -0.10, 0.02, ROUNDS) -- knobs stick out a lot
    end
    for k, f in ipairs(knobFines) do
        local c, fine = knobs[k], f.map

        local knob, why = DoorMap.findKnob(fine, c, KNOB_WINDOW)
        local seat = knob and DoorMap.seat(fine.samples, knob, BEZEL)
        if seat then
            say(('  the car has its own lock here (%d mm across, %.1f mm proud): the lock goes over it'):format(
                math.floor(knob.radius * 2000 + 0.5), knob.height * 1000))
            seat.spot = { u = knob.u, v = knob.v, side = 'own' }
            return place(vehicle, reference, seat, handle, box, true)
        end
        say(('  something small stands out %d mm from the handle, but it is not a lock (%s)'):format(
            math.floor(c.distance * 1000), knob and 'missing paint under it' or why))
    end

    local best
    progress('Looking closer at the spots next to the handle')
    local discs = {}
    closer(candidates, RADIUS, FINE, function(fine, spot)
        local disc = DoorMap.near(fine, spot, RADIUS)
        discs[#discs + 1] = disc
        return disc
    end, -0.025, 0.025, 7)
    for k, spot in ipairs(candidates) do
        local disc = discs[k]
        local seat = DoorMap.seat(disc, spot, BEZEL)
        if seat then
            say(('  spot %s the handle: %.1f mm gap under the bezel on average, %.1f mm at most'):format(
                spot.side, seat.gap * 1000, seat.worst * 1000))
            seat.spot = spot
            if not best or seat.gap + seat.worst * 0.5 < best.gap + best.worst * 0.5 then best = seat end
            if seat.gap <= SNUG and seat.worst <= SNUG * 2.5 then break end
        else
            say(('  spot %s the handle: something missing under it (an edge or a gap)'):format(spot.side))
        end
    end
    if not best then return nil, 'no spot next to the handle to put the lock on' end
    if best.worst > UNEVEN then return nil, ('too uneven next to the handle (%.1f mm gaps)'):format(best.worst * 1000) end

    return place(vehicle, reference, best, handle, box, false)
end

---The fit for a lock seated as `best` says (DoorMap.seat, with best.spot), and notes on it.
function place(vehicle, reference, best, handle, box, onOwnLock)
    local spot = best.spot
    local outward = Vec.normalize(vec3(SIDE * 1.0, -best.b, -best.c))
    local at = vec3(reference.x + SIDE * best.a, spot.u, spot.v) + outward * ON_PAINT
    local into = outward * -1.0
    say(('  %s: lock %s, tilted %.1f deg up and %.1f deg along (reach %.1f mm)'):format(
        Lockpick.modelName(vehicle), onOwnLock and "over the car's own lock" or (spot.side .. ' the handle'), math.deg(math.asin(Clamp(-into.z, -1.0, 1.0))),
        math.deg(math.atan(best.b)), Probe.view.reach * 1000))

    local notes = {}
    if not handle then notes[#notes + 1] = 'no handle bone' end
    if not box.found then notes[#notes + 1] = 'handle not seen' end
    if spot.side ~= 'front' and not onOwnLock then notes[#notes + 1] = 'lock ' .. spot.side .. ' the handle' end
    if not onOwnLock and (best.gap > SNUG or best.worst > SNUG * 2.5) then
        notes[#notes + 1] = ('uneven paint, up to %.1f mm under the bezel'):format(best.worst * 1000)
    end

    return {
        x = at.x, y = at.y, z = at.z,
        pitch = math.deg(math.asin(Clamp(into.z, -1.0, 1.0))),
        yaw = math.deg(math.atan(-into.x, into.y)),
        auto = true,
        check = #notes > 0 or nil,
    }, table.concat(notes, ', ')
end

-- The run -------------------------------------------------------------------------------------

local function run(arg)
    local Dev = Lockpick.dev
    local list
    -- Fits made by hand are never overwritten: they took someone a long time.
    if arg == 'redo' or arg == 'all' then
        list = Dev.carModels(function(_, saved) return not saved or saved.auto end)
    elseif arg then
        list = { arg:lower() }
    else
        list = Dev.carModels(function(_, saved) return not saved end)
    end
    if #list == 0 then return say('nothing to fit') end
    say(('%d cars to fit. Esc stops, Backspace skips a car.'):format(#list))

    local ped = PlayerPedId()
    local home, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityVisible(ped, false, false)
    NetworkOverrideClockTime(12, 0, 0) -- daylight on this screen only, so the markers read clearly

    local scene, vehicle
    local fitted, checks, failed = 0, 0, {}
    local started = GetGameTimer()

    local ok, err = pcall(function()
        for index, wanted in ipairs(list) do
            if Probe.stopAsked then break end
            Probe.skipAsked = false

            status = { model = wanted, index = index, total = #list, started = started, phase = 'Loading the car' }
            progress()
            vehicle = Dev.spawn(wanted, home, heading)
            -- The next car's model loads while this one is measured.
            local nextModel = list[index + 1] and joaat(list[index + 1])
            if nextModel and IsModelInCdimage(nextModel) then RequestModel(nextModel) end

            if not vehicle then
                failed[#failed + 1] = wanted .. ' (model did not load)'
            else
                SetVehicleColours(vehicle, 12, 12) -- matte black: nothing in the paint looks like a marker
                SetVehicleDoorShut(vehicle, 0, true)
                Wait(700)                          -- the close-up model streams in

                if scene then for id in pairs(scene.parts) do scene:setVisible(id, false) end end

                local model = Lockpick.modelName(vehicle)
                status.model = model
                say(('%s (%d / %d)'):format(model, index, #list))
                local done, fit, note = pcall(fitCar, vehicle)
                if not done then
                    if fit ~= 'skipped' then error(fit, 0) end -- stopped, or the frame can't be read
                    fit, note = nil, 'skipped'
                end
                local own = Lockpick.savedFits[model]
                if fit and own and not own.auto then
                    say(('%s has a fit made by hand; kept that one (this one was not saved)'):format(model))
                    fit = nil
                    failed[#failed + 1] = model .. ' (has a fit made by hand, kept)'
                elseif fit then
                    local saved = TR.callback.await('tr_minigames:lockpick:saveFit', model, fit)
                    if saved then
                        Lockpick.savedFits[model] = fit
                        fitted = fitted + 1
                        if fit.check then checks = checks + 1 end
                        say(('%s fitted%s'):format(model, note ~= '' and (' (check: ' .. note .. ')') or ''))

                        -- Show the result for a moment.
                        if not scene then
                            scene = Scene.new(vehicle, vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw)
                            Dev.spawnTool(scene)
                        else
                            scene.entity = vehicle
                            scene:setPlacement(vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw)
                        end
                        for id in pairs(scene.parts) do scene:setVisible(id, true) end
                        Probe.drawList = nil
                        preview = function()
                            local cam = Probe.camera()
                            local from = scene:toWorld(cfg.camera.pos * (wide and WIDE or CLOSE))
                            local at = scene:toWorld(cfg.camera.target)
                            SetCamCoord(cam, from.x, from.y, from.z)
                            PointCamAtCoord(cam, at.x, at.y, at.z)
                            SetCamFov(cam, cfg.camera.fov)
                        end
                        preview()
                        progress('Fitted')
                        Wait(600)
                        preview = nil
                    else
                        failed[#failed + 1] = model .. ' (not saved: are you an admin?)'
                    end
                else
                    failed[#failed + 1] = ('%s (%s)'):format(model, note)
                    say(('%s: %s'):format(model, note))
                end

                Probe.drawList = nil
                DeleteEntity(vehicle)
                vehicle = nil
            end
        end
    end)

    if vehicle and DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
    if scene then scene:destroy() end
    Probe.finish()
    status = nil
    TR.ui.hud.hide()
    NetworkClearClockTimeOverride()
    SetEntityCoordsNoOffset(ped, home.x, home.y, home.z, false, false, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)

    if not ok and err ~= 'stopped' then say('stopped by an error: ' .. tostring(err)) end
    say(('done in %d s: %d fitted (%d to check with /lockpick_fitall review), %d not fitted'):format(
        (GetGameTimer() - started) // 1000, fitted, checks, #failed))
    for _, line in ipairs(failed) do say('  not fitted: ' .. line) end
    if #failed > 0 then say('fit those by hand with /lockpick_fitall') end
end

RegisterCommand('lockpick_autofit', function(_, args)
    if running then return say('already running') end
    if Lockpick.current then return say('finish picking first') end
    if TR.cache.vehicle then return say('get out of the car first') end
    if not TR.ui.probeFrame then
        return say('needs the latest tr_core: ensure tr_core, then tr_minigames')
    end

    -- `show` can go anywhere; the other word picks the cars.
    local what
    show = false
    for _, word in ipairs(args) do
        word = word:lower()
        if word == 'show' then show = true
        else what = what or word end
    end

    running, preview = true, nil
    Probe.stopAsked, Probe.skipAsked = false, false
    Probe.hooks = { say = say, phase = progress }
    drawThread()
    CreateThread(function()
        local ok, err = pcall(run, what)
        if not ok then say('error: ' .. tostring(err)) end
        running, status = false, nil
    end)
end, false)
