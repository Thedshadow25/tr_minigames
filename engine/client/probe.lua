--[[
    Measures what the game draws (dev tools: the autofits). Scripts can't see a car's bodywork, only
    its collision, which can sit centimetres inside the paint. So a camera looks at the car, small
    magenta markers are drawn along each line of sight, and the resource's page reads the frame
    (TR.ui.probeFrame) to see which are hidden behind the paint. A binary search per line finds the
    paint to under a millimetre.

    Surface space (the car's flank): u along the car (vehicle y), v up (vehicle z), h out of the
    flank from a reference plane x = reference.x. `side` is which flank: -1 the left (driver's), 1 the right.

        Probe.hooks = { say = print, phase = function(text) end }  -- log and progress
        Probe.aim(vehicle, from, at, halfHeight)                    -- vehicle space; halfHeight metres at `at`
        Probe.calibrate(nearWorld)                                  -- once per camera set-up a session
        local list = Probe.prepare(vehicle, samples, reference, lo, hi)  -- samples { u, v }
        Probe.measure(list, rounds)
        Probe.toSurface(vehicle, list, reference, side)             -- sample.h
        Probe.draw()                                                -- every frame while running
        Probe.stopAsked, Probe.skipAsked                            -- set by the caller's keys
        Probe.finish()                                              -- camera off
]]

Probe = {}

local ROUNDS = 10                     -- binary search steps: 35 cm down to a third of a millimetre
local SENTINELS = 4                   -- 3 bits of the probe's number, and one drawn last
local RETRIES = 4                     -- frames in a row that may go unread before measuring gives up
local MAGENTA = { 255, 0, 255 }
local CALIBRATOR = joaat('tr_lp_bezel') -- the lock's chrome ring: its face is flat from 8 to 12.6 mm out, at y = -2.5 mm

Probe.ROUNDS = ROUNDS
Probe.hooks = { say = print, phase = function() end }
Probe.stopAsked, Probe.skipAsked = false, false
Probe.drawList = nil                  -- { { world, size, color? }, ... } drawn every frame while set
Probe.view = {}                       -- the current camera: world position, axes, fov, metres per pixel

local perFrame = 400                  -- markers drawn at once: grows while the game draws them all,
local maxPerFrame = 2400              -- up to this; both come down if the game draws fewer than asked
local reaches = {}                    -- calibrate(): view.reach for each camera set-up seen this session
local cam

local function say(text) Probe.hooks.say(text) end

---Draws the markers in Probe.drawList: call every frame.
function Probe.draw()
    local list = Probe.drawList
    if not list then return end
    for i = 1, #list do
        local m = list[i]
        local p, d = m[1], m[2]
        local c = m.color or MAGENTA
        DrawMarker(28, p.x, p.y, p.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, d, d, d, c[1], c[2], c[3], 255,
            false, false, 2, false, nil, nil, false)
    end
end

-- Camera --------------------------------------------------------------------------------------

---The scripted camera the probe looks through (created by Probe.aim).
function Probe.camera() return cam end

---Points the camera from `fromV` at `atV` (vehicle space), `halfHeight` metres of view above and
---below `atV`.
function Probe.aim(vehicle, fromV, atV, halfHeight)
    local from = GetOffsetFromEntityInWorldCoords(vehicle, fromV.x, fromV.y, fromV.z)
    local at = GetOffsetFromEntityInWorldCoords(vehicle, atV.x, atV.y, atV.z)
    local distance = #(at - from)
    local fov = math.deg(2.0 * math.atan(halfHeight / distance))

    if not cam then
        cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        SetCamUseShallowDofMode(cam, false)
        SetCamMotionBlurStrength(cam, 0.0)
        RenderScriptCams(true, false, 0, true, false)
    end
    SetCamCoord(cam, from.x, from.y, from.z)
    PointCamAtCoord(cam, at.x, at.y, at.z)
    SetCamFov(cam, fov)

    local _, screenHeight = GetActiveScreenResolution()
    local forward = Vec.normalize(at - from)
    local right = Vec.normalize(Vec.cross(forward, vec3(0.0, 0.0, 1.0)))
    local view = {
        from = from, forward = forward, right = right, up = Vec.cross(right, forward), fov = fov,
        pixel = 2.0 * halfHeight / math.max(screenHeight, 480), -- metres per pixel at the surface
    }
    Probe.view = view

    Wait(0)
    Wait(0) -- the camera has to have rendered before screen positions are right

    -- Sentinels: big markers close to the camera in the top left corner, always in view.
    local near = 0.25
    local h = near * math.tan(math.rad(fov) * 0.5)
    local w = h * GetAspectRatio(false)
    view.sentinels = {}
    for i = 1, SENTINELS do
        local p = from + forward * near + view.right * (-w * 0.92 + (i - 1) * w * 0.07) + view.up * (h * 0.9)
        local _, sx, sy = GetScreenCoordFromWorldCoord(p.x, p.y, p.z)
        view.sentinels[i] = { p, h * 0.04, sx, sy }
    end
end

---Gives the game its camera back.
function Probe.finish()
    Probe.drawList = nil
    if cam then
        RenderScriptCams(false, false, 0, true, false)
        DestroyCam(cam, false)
        cam = nil
    end
end

function Probe.markerSize()
    return math.max(0.0035, Probe.view.pixel * 7.0)
end

-- Probing -------------------------------------------------------------------------------------

local probeCount = 0

---Draws markers at `points` ({ world }) and reads which are seen. Returns '1'/'0' per point, or
---nil and why: 'cap' (the game drew fewer markers than asked) or 'frame' (no answer).
local function look(points, size)
    local view = Probe.view
    probeCount = probeCount + 1
    local k = probeCount % 7 + 1 -- never 0: a frame without any markers can't pass for this one
    local list, screen = {}, {}

    for b = 0, 2 do
        if (k >> b) & 1 == 1 then list[#list + 1] = view.sentinels[b + 1] end
    end
    for b = 1, SENTINELS do
        screen[#screen + 1] = view.sentinels[b][3]
        screen[#screen + 1] = view.sentinels[b][4]
    end
    for _, p in ipairs(points) do
        list[#list + 1] = { p.world, size }
        screen[#screen + 1] = p.sx
        screen[#screen + 1] = p.sy
    end
    list[#list + 1] = view.sentinels[SENTINELS] -- last: if it shows, every marker was drawn

    -- One frame is usually enough to get them on screen; if the frame read is older, the
    -- sentinels say so and it reads again.
    Probe.drawList = list
    Wait(0)

    local short = 0
    for _ = 1, 20 do
        local hits = TR.ui.probeFrame(screen)
        if hits then
            local ok = true
            for b = 0, 2 do
                if (hits:sub(b + 1, b + 1) == '1') ~= ((k >> b) & 1 == 1) then ok = false end
            end
            if ok then
                if hits:sub(SENTINELS, SENTINELS) == '1' then return hits:sub(SENTINELS + 1) end
                short = short + 1
                if short >= 3 then return nil, 'cap' end
            end
        end
        Wait(0)
    end
    return nil, 'frame'
end

---Splits samples into groups whose markers are never drawn close together: a seen marker next to
---a hidden one would show in its probe pixels and make it look seen too. Samples on the same
---spot of the screen (overlapping maps) land in different groups.
local function spaceOut(list)
    local _, height = GetActiveScreenResolution()
    height = math.max(height, 480)
    local width = height * GetAspectRatio(false)
    local apart = 2.0 * Probe.markerSize() / Probe.view.pixel + 4.0 -- a marker's width in pixels and a margin
    local apart2 = apart * apart

    local groups, cells = {}, {}
    for _, s in ipairs(list) do
        local x, y = s.sx * width, s.sy * height
        local cx, cy = math.floor(x / apart), math.floor(y / apart)
        local g = 1
        while true do
            local grid = cells[g]
            if not grid then
                grid = {}
                cells[g], groups[g] = grid, {}
            end
            local clear = true
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local cell = grid[(cx + dx) * 65536 + cy + dy]
                    if cell then
                        for _, o in ipairs(cell) do
                            local ex, ey = o.sx * width - x, o.sy * height - y
                            if ex * ex + ey * ey < apart2 then clear = false break end
                        end
                    end
                    if not clear then break end
                end
                if not clear then break end
            end
            if clear then
                local key = cx * 65536 + cy
                grid[key] = grid[key] or {}
                grid[key][#grid[key] + 1] = s
                groups[g][#groups[g] + 1] = s
                break
            end
            g = g + 1
        end
    end
    return groups
end

---Binary search along each sample's line of sight for where something hides the markers.
---Each sample needs: world (start of its line), dir (line of sight), lo, hi (search range along
---it) and sx, sy. Samples from several maps can go in at once.
---Afterwards s.mid is where the markers stopped showing, or s.hole / s.blocked is set.
function Probe.measure(samples, rounds)
    local size = Probe.markerSize()
    local misses = 0
    local groups = spaceOut(samples)

    local function run(active, at)
        for _, all in ipairs(groups) do
            local group = {}
            for _, s in ipairs(all) do
                if active[s] then group[#group + 1] = s end
            end
            local i = 1
            while i <= #group do
                if Probe.stopAsked then error('stopped', 0) end
                if Probe.skipAsked then error('skipped', 0) end
                local chunk = {}
                for k = i, math.min(#group, i + perFrame - 1) do
                    local s = group[k]
                    chunk[#chunk + 1] = { world = s.world + s.dir * at(s), sx = s.sx, sy = s.sy }
                end

                local hits, why = look(chunk, size)
                if not hits then
                    if why == 'cap' and perFrame > 12 then
                        -- Fewer at a time from now on, and never back up to this many.
                        maxPerFrame = math.max(12, math.floor(#chunk * 0.6))
                        perFrame = math.min(perFrame, maxPerFrame)
                        say(('the game drew fewer markers than asked; now %d at a time'):format(perFrame))
                    else
                        -- Now and then a frame isn't read in time (the camera just moved, a hitch):
                        -- give it a moment and try the same markers again before giving up.
                        misses = misses + 1
                        if misses > RETRIES then
                            error('could not read the markers from the game frame (tr_core has to be up to date)', 0)
                        end
                        say(('no answer from the game frame; trying again (%d / %d)'):format(misses, RETRIES))
                        Wait(250 * misses)
                    end
                else
                    misses = 0
                    for k = 1, #chunk do group[i + k - 1].seen = hits:sub(k, k) == '1' end
                    i = i + #chunk
                    -- All drawn: try more at once next time (fewer frames per pass).
                    if #chunk == perFrame then perFrame = math.min(maxPerFrame, math.floor(perFrame * 1.5)) end
                end
            end
        end
    end

    local function set(list)
        local t = {}
        for _, s in ipairs(list) do t[s] = true end
        return t
    end

    -- Furthest in first: still seen there means nothing is in the way (a gap or a hole).
    run(set(samples), function(s) return s.hi end)
    local active = {}
    for _, s in ipairs(samples) do
        if s.seen then s.hole = true else active[#active + 1] = s end
    end

    -- Nearest out: hidden even there means something sticks out in front (a mirror).
    run(set(active), function(s) return s.lo end)
    local search = {}
    for _, s in ipairs(active) do
        if s.seen then search[#search + 1] = s else s.blocked = true end
    end

    local searching = set(search)
    for _ = 1, rounds do
        run(searching, function(s) return (s.lo + s.hi) * 0.5 end)
        for _, s in ipairs(search) do
            local mid = (s.lo + s.hi) * 0.5
            if s.seen then s.lo = mid else s.hi = mid end
        end
    end

    for _, s in ipairs(samples) do
        if not s.hole and not s.blocked then s.mid = (s.lo + s.hi) * 0.5 end
    end
end

---Turns measured samples into surface space: s.u, s.v and s.h (out from the reference plane).
---A marker keeps showing a little past the paint (about its radius, plus whatever the game's
---anti-aliasing adds); view.reach is that distance, measured by Probe.calibrate().
function Probe.toSurface(vehicle, samples, reference, side)
    local out = vec3(side * 1.0, 0.0, 0.0)
    for _, s in ipairs(samples) do
        if s.mid then
            local w = s.world + s.dir * (s.mid - Probe.view.reach)
            local p = GetOffsetFromEntityGivenWorldCoords(vehicle, w.x, w.y, w.z)
            s.h = Vec.dot(p - reference, out)
            s.u, s.v = p.y, p.z
        end
    end
end

---Measures how far past a surface the markers keep showing (view.reach) on a surface whose place
---is known exactly: the bezel prop, held at `near` (world, a little in front of the car), facing
---the camera. It only depends on the marker's size and the camera's scale, which are the same for
---most cars, so each set-up is measured once a session.
function Probe.calibrate(near)
    local view = Probe.view
    local key = ('%.5f %.7f'):format(Probe.markerSize(), view.pixel)
    if reaches[key] then
        view.reach = reaches[key]
        return
    end
    view.reach = Probe.markerSize() -- if this fails: a sphere marker's scale is its radius
    Probe.hooks.phase('Calibrating the markers')

    if not HasModelLoaded(CALIBRATOR) then
        RequestModel(CALIBRATOR)
        local deadline = GetGameTimer() + 5000
        while not HasModelLoaded(CALIBRATOR) and GetGameTimer() < deadline do Wait(0) end
        if not HasModelLoaded(CALIBRATOR) then return say('the calibration prop did not load; using the default') end
    end

    local object = CreateObjectNoOffset(CALIBRATOR, near.x, near.y, near.z, false, false, false)
    SetEntityCollision(object, false, false)
    FreezeEntityPosition(object, true)
    local f = view.forward
    SetEntityRotation(object, math.deg(math.asin(Clamp(f.z, -1.0, 1.0))), 0.0, math.deg(math.atan(-f.x, f.y)), 2, false)
    for _ = 1, 4 do Wait(0) end

    local samples = {}
    for k = 1, 8 do
        local a = (k - 0.5) * math.pi / 4.0
        local face = GetOffsetFromEntityInWorldCoords(object, math.cos(a) * 0.0103, -0.0025, math.sin(a) * 0.0103)
        local _, sx, sy = GetScreenCoordFromWorldCoord(face.x, face.y, face.z)
        local dir = Vec.normalize(face - view.from)
        samples[k] = { world = face - dir * 0.02, dir = dir, lo = 0.0, hi = 0.04, sx = sx, sy = sy }
    end

    local ok, err = pcall(Probe.measure, samples, ROUNDS + 1)
    DeleteEntity(object)
    if not ok then error(err, 0) end

    local sum, n = 0.0, 0
    for _, s in ipairs(samples) do
        if s.mid then sum, n = sum + (s.mid - 0.02), n + 1 end
    end
    if n >= 4 then
        view.reach = Clamp(sum / n, 0.0, Probe.markerSize() * 3.0)
        reaches[key] = view.reach
    else
        say('the calibration missed the prop; using the default')
    end
end

---Gets every sample ready: its point on the reference plane (x = reference.x), line of sight and
---screen position. lo/hi: search range along the line, from the plane.
function Probe.prepare(vehicle, samples, reference, lo, hi)
    local view = Probe.view
    local kept = {}
    for _, s in ipairs(samples) do
        local world = GetOffsetFromEntityInWorldCoords(vehicle, reference.x, s.u, s.v)
        local onScreen, sx, sy = GetScreenCoordFromWorldCoord(world.x, world.y, world.z)
        if onScreen then
            s.world, s.dir = world, Vec.normalize(world - view.from)
            s.sx, s.sy = sx, sy
            s.lo, s.hi = lo(s), hi(s)
            kept[#kept + 1] = s
        else
            s.hole = true
        end
    end
    return kept
end

---Where collision says the flank is at (u, v) on `side`: a first guess of the paint (x, vehicle space).
function Probe.collisionX(vehicle, u, v, side)
    local from = GetOffsetFromEntityInWorldCoords(vehicle, side * 3.0, u, v)
    local to = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, u, v)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 2, PlayerPedId(), 7)
    local _, hit, at, _, entity = GetShapeTestResult(ray)
    if (hit == true or hit == 1) and entity == vehicle then return GetOffsetFromEntityGivenWorldCoords(vehicle, at.x, at.y, at.z).x end
end
