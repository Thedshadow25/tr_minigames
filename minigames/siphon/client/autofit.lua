--[[
    Fits the filler to every car by itself (dev mode; saving needs an admin).

        /filler_autofit                 every car model that has no saved fit yet
        /filler_autofit redo            also redo the ones fitted automatically before (not manual ones)
        /filler_autofit all             the same as redo
        /filler_autofit sultan          just this one
        /filler_autofit compare         fits the cars fitted by hand again and says how far off it is
                                        from each hand fit (and how far the guess was); saves nothing
        /filler_autofit compare sultan  the same for one car
        /filler_autofit sultan show     and show what it measured for 8 s (works with the others too)
        /filler_forceauto               every car again, replacing the fits made by hand too (a car
                                        that can't be fitted keeps its old fit)

    Scripts only see a car's collision, which can sit centimetres inside or outside the paint, so this
    measures what is drawn (engine/client/probe.lua). GTA's cars have no fuel door, so the filler goes
    on plain paint where a filler usually is: on the car's petroltank bone, or where the body's rear
    quarter says (also when the bone is in the car's middle, marked to check). Only one flank is
    measured: the bone's, or the left one. A car without a bone gets
    its fit mirrored to the side the player stands (`both`). Per car:

    0. Without a bone: the doors, the boot lid and the glass come off (they're put back after), and a
       wide map of the whole rear quarter, from in front of the rear wheel to the tail and from the
       wheel's middle up, a sample every 5 cm or so (more apart on bigger cars). FillerMap.place
       (fillermap.lua) finds the wheel arch's top (on a lifted body far over the tyre) and the
       panel's top on it, and picks the place nearest where a filler usually is (over the back of
       the wheel arch, 15 cm over it; if not there, further back sooner than further forward) where
       the bezel and some room round it are on plain paint: never on the arch or its lip, a door, a
       window or past the tail light, over the panel's top or facing the ground.
       With a bone ahead of the rear wheel (a lorry's side tank, at its end or inside it; the tank
       can be well inside the box its mirrors make, and collision can miss it): a wide map along the
       tank instead, from the wheel behind it to the one ahead (at most 1.6 m from the bone), and
       FillerMap.nearest picks the place in the middle of what the bone is on (the tank's face, not
       its step, the cab or a wheel), as high as the place on it nearest the bone.
    1. A coarse map round that place (or another bone), a sample every 28 mm, searched from just
       outside the car's bounding box to 30 cm inside. With such a bone, if too little paint is
       found there, the bezel sits well nowhere round it or the search ended short of the bone: a
       wide map round the bone (1 m along, 90 cm up, searched to 30 cm past it), and
       FillerMap.nearest picks the place nearest the bone on what it's on.
    2. FillerMap.spots: where the paint under the bezel is whole and smooth, and doesn't curve so
       much the bezel's rim would lift off it. None round a wide map's pick: on to the next pick.
    3. A close look at the best spot: the bezel's disc and its rim, a few millimetres a sample, and a
       ring of samples 2 cm round it (an opening, glass, a flare or a lip there shows), searched 6 mm
       either side of the paint the coarse map has there. The bezel rests on it as a real one would
       (DoorMap.seat). If it doesn't sit well there, the next spot (three at most), clear of what
       was wrong (a body line found under one is kept off the next one's rim); then the wide map's
       next best places (two more at most, 12 cm or more apart).

    Each fit is saved like a manual one (minigames/siphon/fits.json). Fits it isn't sure about are
    marked `check`: go through them with /filler_fitall review. Esc stops after the car on screen,
    Backspace skips it. C zooms out: the run waits on the next fitted car, seen against the whole
    car, until C is pressed again. Stand somewhere open: the camera goes up to 2.5 m out from the
    car's side (2.7 m along a lorry's side tank).
]]

local cfg = Config.siphon

if not cfg.enabled or not cfg.devMode then return end

local WIDE_POINTS = 440                 -- the wide map of the rear quarter: about this many samples
local WIDE_STEP = 0.035                 -- at least this far apart
local WIDE_DEEP = 0.45                  -- searched from just outside the bounding box to this far into it
local WIDE_ROUNDS = 7                   -- binary search steps over that: under 4 mm
local WIDE_FOV = 40.0                   -- its camera's view, top to bottom
local BONE_U, BONE_V = 0.5, 0.45        -- the wide map round a bone (when the coarse map there doesn't do): this far along and up / down
                                        -- from it (a round tank's outer face from a bone on its top or bottom)
local BONE_POINTS = 600                 -- about this many samples
local TANK_REACH = 1.6                  -- a side tank (a bone ahead of the rear wheel): mapped along from the wheel behind it to the one
                                        -- ahead (clear of their tyres), at most this far from the bone, to find its ends
local TANK_STEP = 0.045                 -- a sample this far apart
local PAST_BONE = 0.30                  -- searched from just outside the bounding box to this far past the bone (not past the car's middle)
local GRAIN = 0.004                     -- in enough binary search steps to get under this
local MAX_DOWN = 15.0                   -- the filler faces the ground at most this much (not on a round tank's lower half)
local LIGHT = 0.20                      -- the filler's middle at least this far in front of the tail light
local IN_WAY = 0.25                     -- this share of it hidden even outside the car's box: is something in the way?
local HALF_U, HALF_V = 0.126, 0.098     -- the coarse map: this far along the car and up / down from the anchor
local COARSE = 0.028                    -- its sample spacing
local COARSE_ROUNDS = 11                -- binary search steps over its range: about a quarter of a millimetre
local OUTSIDE = 0.02                    -- its search starts this far outside the bounding box
local DEEP = 0.30                       -- and ends this far into the car from the collision
local SEARCH_U, SEARCH_V = 0.07, 0.045  -- the filler's middle may move this far from the anchor
local SURFACE = 0.09                    -- the paint round a spot is fitted to the coarse map this far round it
local BEZEL = 0.053                     -- what the filler rests on: the bezel's radius and a millimetre
local ROOM = 0.02                       -- plain paint at least this far round the bezel (from the arch's lip, a door, a window)
local FINE = 0.009                      -- sample spacing under the bezel (and a ring of them round its rim)
local WINDOW = 0.006                    -- searched this far either side of the paint the coarse map has there
local FINE_ROUNDS = 6                   -- binary search steps over that: under a fifth of a millimetre
local SPOTS = 3                         -- spots looked at closely, at most
local APART = 0.012                     -- this far apart at least
local STRAIGHT = 0.006                  -- a line found under one whose points are all this close to a straight line runs on along it
local ON_PAINT = 0.0008                 -- the bezel's back this far out from the paint
local UNEVEN = 0.003                    -- largest gap under the bezel's rim that's fine
local MAX_PITCH, MAX_YAW = 45.0, 35.0   -- tilt / turn from square to the car's side it may have
local CLOSE, WIDE = 1.6, 5.0            -- the preview camera this many times the fitter's distance
local SHOWN = 400                       -- ms each fitted car is shown (zoomed out: until C)
local VIEW = { pos = vec3(0.10, -0.40, 0.08), target = vec3(0.0, 0.0, 0.0), fov = 40.0 }

local running = false
local show = false                      -- /filler_autofit <model> show: see what it measured
local wide = false                      -- C: wait on the next fitted car, zoomed out on it, until C again
local preview                           -- while a fit is shown: aims the camera at it (again after C)
local status                            -- the run's progress on the HUD: { model, index, total, started, phase, holding }
local spawnHeading                      -- the car's heading as spawned: its left flank faces the measuring spot
local slowDetail = 0                    -- cars in a row the game never said its close-up model was in for
local fixedWait = false                 -- after three of those: a fixed wait instead

local function say(text)
    print('[filler autofit] ' .. text)
end

local function minutes(ms)
    local s = math.floor(ms / 1000 + 0.5)
    if s < 60 then return ('%d s'):format(s) end
    return ('%d min %02d s'):format(s // 60, s % 60)
end

local function mm(m) return math.floor(m * 1000 + 0.5) end

---The run's progress, bottom middle: which car, how many are left and what it is doing.
local function progress(phase)
    if not status then return end
    status.phase = phase or status.phase
    local done, left = status.index - 1, status.total - status.index
    local eta = ''
    if done > 0 and left > 0 then
        eta = ' (about ' .. minutes((GetGameTimer() - status.started) / done * (left + 1)) .. ' to go)'
    end
    local sub = status.phase .. eta
    if wide and not status.holding then sub = sub .. '. Zooms out on it when it is fitted' end
    TR.ui.hud.set({
        meter = {
            label = ('Car %d of %d, %d left after it'):format(status.index, status.total, left),
            value = done / status.total,
        },
        hint = {
            text = status.model,
            sub = sub,
            keys = {
                { key = 'C', label = status.holding and 'Zoom in, next car' or wide and 'Zoom in' or 'Zoom out' },
                { key = 'Esc', label = 'Stop' },
                { key = '⌫', label = 'Skip car' },
            },
        },
    })
end

local function drawThread()
    CreateThread(function()
        while running do
            HideHudAndRadarThisFrame()
            DisableAllControlActions(0)
            if IsDisabledControlJustPressed(0, 200) then Probe.stopAsked = true end
            if IsDisabledControlJustPressed(0, 194) then Probe.skipAsked = true end
            if IsDisabledControlJustPressed(0, 26) then
                -- Only the fitted filler's view moves: the measuring camera has to stay where it is.
                wide = not wide
                if preview then preview() end
                progress()
            end
            Probe.draw()
            Wait(0)
        end
    end)
end

---How much of a step along this line of sight goes into the car (it's never quite square). `out`:
---out of the flank, in the world.
local function along(s, out) return math.max(0.5, -Vec.dot(s.dir, out)) end

---Every flank is measured from the same spot: the car turns so this flank faces where its left one
---did. From the other side of the car the light, the game's exposure and whatever stands there can
---keep the markers from reading. Returns `out` (out of the flank) in the world.
local function face(vehicle, side)
    spawnHeading = spawnHeading or GetEntityHeading(vehicle)
    local heading = (spawnHeading + (side > 0 and 180.0 or 0.0)) % 360.0
    if math.abs(AngleDelta(math.rad(GetEntityHeading(vehicle)), math.rad(heading))) > 0.01 then
        SetEntityHeading(vehicle, heading)
        Wait(0)
        Wait(0)
    end
    return GetOffsetFromEntityInWorldCoords(vehicle, side * 1.0, 0.0, 0.0) - GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 0.0, 0.0)
end

---Takes the doors, the boot lid and the glass off while the car is measured: the filler never goes
---on a door or a window, and with them off their openings read as openings (a window can read as
---paint). SetVehicleFixed puts them back.
local function strip(vehicle)
    for door = 0, 5 do
        if door ~= 4 and GetIsDoorValid(vehicle, door) then SetVehicleDoorBroken(vehicle, door, true) end
    end
    for window = 0, 7 do RemoveVehicleWindow(vehicle, window) end
    Wait(0)
    Wait(0)
end

---Where a bone of the car is, vehicle space; nil if it has none.
local function boneAt(vehicle, name)
    local index = GetEntityBoneIndexByName(vehicle, name)
    if index == -1 then return end
    local p = GetWorldPositionOfEntityBone(vehicle, index)
    return GetOffsetFromEntityGivenWorldCoords(vehicle, p.x, p.y, p.z)
end

-- Showing what it measured ------------------------------------------------------------------------

---Draws `list` for `ms` (Esc and Backspace still work).
local function hold(list, ms)
    Probe.drawList = list
    local stopAt = GetGameTimer() + ms
    while GetGameTimer() < stopAt and not Probe.stopAsked and not Probe.skipAsked do Wait(0) end
    Probe.drawList = nil
    if Probe.stopAsked then error('stopped', 0) end
    if Probe.skipAsked then error('skipped', 0) end
end

---For tuning: the wide map, for 6 s. Green is the body's skin, orange something deeper (the tyre,
---the wheel well, a door opening), red nothing (or something in the way). Yellow is where a filler
---usually is on this body, white the place picked.
local function showWide(vehicle, w)
    local list = {}
    local size = Probe.markerSize()
    local function at(u, v, h) return GetOffsetFromEntityInWorldCoords(vehicle, w.reference.x + w.side * h, u, v) end
    for _, s in ipairs(w.map.samples) do
        local color = s.skin and { 40, 255, 40 } or s.h and { 255, 150, 0 } or { 255, 40, 40 }
        list[#list + 1] = { at(s.h and s.u or s.gu, s.h and s.v or s.gv, (s.h or 0.0) + 0.004), size, color = color }
    end
    local place = w.place
    if place then
        list[#list + 1] = { at(place.target.u, place.target.v, place.h + 0.02), size * 2.0, color = { 255, 220, 0 } }
        list[#list + 1] = { at(place.u, place.v, place.h + 0.02), size * 2.0, color = { 255, 255, 255 } }
    end
    hold(list, 6000)
end

---For tuning: what it measured, for 8 s. The coarse map in green (paint) and red (none: a gap,
---the wheel arch); the bezel's samples where it went in green, red where the paint isn't there or
---stands out and orange under a gap at the rim. Yellow is where it started from (the bone or the
---wide map's pick), blue the spots it found, white where the filler went.
local function showMap(vehicle, f)
    local list = {}
    local function at(reference, u, v, h) return GetOffsetFromEntityInWorldCoords(vehicle, reference.x + f.side * h, u, v) end
    local level = f.height(f.anchor.u, f.anchor.v)
    for _, s in ipairs(f.coarse.samples) do
        list[#list + 1] = { at(f.reference, s.u, s.v, (s.h or level) + 0.002), 0.003, color = s.h and { 40, 255, 40 } or { 255, 40, 40 } }
    end
    local seat, c = f.best.seat, f.best.spot
    for _, s in ipairs(f.best.disc) do
        local color = { 40, 255, 40 }
        if not s.h then
            color = { 255, 40, 40 }
        elseif seat then
            local gap = seat.a + seat.b * (s.u - c.u) + seat.c * (s.v - c.v) - s.h
            if gap > UNEVEN and (s.gu - c.u) ^ 2 + (s.gv - c.v) ^ 2 >= (BEZEL - 0.012) ^ 2 then color = { 255, 150, 0 } end
        end
        list[#list + 1] = { at(f.discRef, s.gu, s.gv, (s.h or 0.0) + 0.001), 0.0015, color = color }
    end
    list[#list + 1] = { at(f.reference, f.anchor.u, f.anchor.v, level + 0.01), 0.006, color = { 255, 220, 0 } }
    for _, spot in ipairs(f.spots) do
        list[#list + 1] = { at(f.reference, spot.u, spot.v, (spot.h or level) + 0.008), 0.004, color = { 40, 120, 255 } }
    end
    list[#list + 1] = { at(f.discRef, c.u, c.v, (seat and seat.a or 0.0) + 0.01), 0.005, color = { 255, 255, 255 } }
    hold(list, 8000)
end

-- Wide maps ------------------------------------------------------------------------------------

---Maps the flank on `side` wide, u0 to u1 along and v0 to v1 up (vehicle space): about opts.points
---samples, WIDE_STEP or more apart, searched from just outside the bounding box to opts.deep into
---it in opts.rounds steps. Returns { map, reference, side, holes, blocked, inWay } (inWay: why, if
---something stands between the camera and the car).
local function mapWide(vehicle, side, u0, u1, v0, v1, opts)
    local outWorld = face(vehicle, side)
    local min, max = GetModelDimensions(GetEntityModel(vehicle))
    local outer = side < 0 and -min.x or max.x
    local step = math.max(WIDE_STEP, math.sqrt((u1 - u0) * (v1 - v0) / opts.points))
    local map = DoorMap.grid(u0, u1, v0, v1, step)

    -- Seen square on from far enough out to take it all in. Its depths only need to be good to a few
    -- millimetres, so the markers' reach isn't calibrated for this camera (it's about their size).
    local reference = vec3(side * outer, (u0 + u1) * 0.5, (v0 + v1) * 0.5)
    local halfHeight = math.max((v1 - v0) * 0.5, (u1 - u0) * 0.5 / GetAspectRatio(false)) * 1.08
    local distance = halfHeight / math.tan(math.rad(WIDE_FOV * 0.5))
    Probe.aim(vehicle, reference + vec3(side * distance, 0.0, 0.0), reference, halfHeight)

    progress(opts.phase)
    local list = Probe.prepare(vehicle, map.samples, reference,
        function(s) return -OUTSIDE / along(s, outWorld) end, function(s) return opts.deep / along(s, outWorld) end)
    for _, s in ipairs(list) do
        -- How far each line of sight drifts along the flank per metre in (it's square only in the middle).
        local a = GetOffsetFromEntityGivenWorldCoords(vehicle, s.world.x, s.world.y, s.world.z)
        local b = s.world + s.dir
        b = GetOffsetFromEntityGivenWorldCoords(vehicle, b.x, b.y, b.z)
        local inward = math.max(0.1, side * (a.x - b.x))
        s.du, s.dv = (b.y - a.y) / inward, (b.z - a.z) / inward
    end
    Probe.measure(list, opts.rounds)
    Probe.toSurface(vehicle, list, reference, side)

    -- Hidden even just outside the car's box: a part of the car sticks out there, or something
    -- stands between the camera and the car (it's measured from up to 2.5 m out). If a lot are,
    -- where they're hidden from says which.
    local blocked, holes = {}, 0
    for _, s in ipairs(map.samples) do
        if s.blocked then blocked[#blocked + 1] = s elseif s.hole then holes = holes + 1 end
    end
    local inWay
    if #blocked >= #map.samples * IN_WAY then
        local between = {}
        for _, s in ipairs(blocked) do
            local far = #(s.world - Probe.view.from) - 0.3
            between[#between + 1] = { world = s.world, dir = s.dir, sx = s.sx, sy = s.sy, lo = -far, hi = s.lo, far = far, start = s.lo }
        end
        Probe.measure(between, 5)
        -- How far in front of where its search started each is hidden from (the search narrows lo and hi).
        local outside = {}
        for _, b in ipairs(between) do
            local out = b.blocked and b.far + b.start or b.mid and b.start - b.mid
            if out and out > 0.15 then outside[#outside + 1] = out end
        end
        if #outside >= #between * 0.5 then
            table.sort(outside)
            inWay = ('something stands between the camera and the car, about %.1f m out from its side (stand somewhere open, %.1f m clear on the car\'s %s)'):format(
                outside[(#outside + 1) // 2], distance + 0.3, side < 0 and 'left' or 'right')
        end
    end
    return { map = map, reference = reference, side = side, holes = holes, blocked = #blocked, inWay = inWay }
end

---The rear quarter on `side`, mapped wide, and where on it the filler goes (FillerMap.place).
---`wheel`: Siphon.rearWheel. Returns { map, reference, side, place } (place nil and `why` if
---there's nowhere for it) and the looks it took.
local function mapQuarter(vehicle, side, wheel)
    local stats = Probe.stats
    local looks0 = stats.looks

    -- From in front of the rear wheel to the tail, from the wheel's middle to the top of the flank.
    local min, max = GetModelDimensions(GetEntityModel(vehicle))
    local u0, u1 = min.y + 0.02, math.min(max.y - 0.02, wheel.y + wheel.r + 0.1)
    local v0, v1 = wheel.z, math.min(max.z - 0.02, wheel.z + wheel.r + 1.0)
    local w = mapWide(vehicle, side, u0, u1, v0, v1, { points = WIDE_POINTS, deep = WIDE_DEEP, rounds = WIDE_ROUNDS, phase = 'Mapping the rear quarter' })

    -- Not past the tail light (its bone is in the lamp; the lamp reaches forward round the corner).
    local light = boneAt(vehicle, side < 0 and 'taillight_l' or 'taillight_r')
    local rearmost = light and light.y < wheel.y - wheel.r and light.y + LIGHT or nil
    w.place, w.why = FillerMap.place(w.map, { u = wheel.y, v = wheel.z, r = wheel.r }, {
        bezel = BEZEL, room = ROOM, rearmost = rearmost, maxTilt = MAX_PITCH, maxTurn = MAX_YAW, maxDown = MAX_DOWN,
    })
    if w.inWay then w.place, w.why = nil, w.inWay end
    w.inWay = w.inWay ~= nil
    return w, stats.looks - looks0
end

---Where along the car (vehicle y) the wheels on `side` are.
local function wheelsOn(vehicle, side)
    local list = {}
    for _, name in ipairs({ 'f', 'm1', 'm2', 'm3', 'r' }) do
        local index = GetEntityBoneIndexByName(vehicle, ('wheel_%s%s'):format(side < 0 and 'l' or 'r', name))
        if index ~= -1 then
            local p = GetWorldPositionOfEntityBone(vehicle, index)
            list[#list + 1] = GetOffsetFromEntityGivenWorldCoords(vehicle, p.x, p.y, p.z).y
        end
    end
    return list
end

---Round a petroltank bone off the car's middle (`bone`, vehicle space), mapped wide on its side, and
---the place on what it's on nearest it (FillerMap.nearest): for a lorry whose bone is at its side
---tank's end or inside it, and whose tank can be well inside the bounding box (the mirrors stick
---out much further), where collision may miss it. Searched to PAST_BONE past the bone. With `tank`
---(a side tank: the tyre's radius), along it from the wheel behind it to the one ahead, clear of
---their tyres and at most TANK_REACH from the bone, and the place in the tank's middle there.
---Returns { map, reference, side, place } (place nil and `why` if there's nowhere for it) and the
---looks it took.
local function mapBone(vehicle, side, bone, tank)
    local stats = Probe.stats
    local looks0 = stats.looks
    local min, max = GetModelDimensions(GetEntityModel(vehicle))
    local outer = side < 0 and -min.x or max.x
    local u0, u1 = bone.y - BONE_U, bone.y + BONE_U
    if tank then
        u0, u1 = bone.y - TANK_REACH, bone.y + TANK_REACH
        for _, y in ipairs(wheelsOn(vehicle, side)) do
            if y < bone.y then u0 = math.max(u0, y + tank) else u1 = math.min(u1, y - tank) end
        end
    end
    u0, u1 = math.max(min.y + 0.02, u0), math.min(max.y - 0.02, u1)
    local v0, v1 = math.max(min.z + 0.02, bone.z - BONE_V), math.min(max.z - 0.02, bone.z + BONE_V)
    local deep = Clamp(outer - side * bone.x + PAST_BONE, WIDE_DEEP, outer)
    local rounds = math.max(WIDE_ROUNDS, math.ceil(math.log((deep + OUTSIDE) / GRAIN, 2)))
    local points = tank and (u1 - u0) * (v1 - v0) / (TANK_STEP * TANK_STEP) or BONE_POINTS
    local w = mapWide(vehicle, side, u0, u1, v0, v1, { points = points, deep = deep, rounds = rounds, phase = tank and 'Mapping the tank' or 'Mapping round the bone' })

    w.place, w.why = FillerMap.nearest(w.map, { u = bone.y, v = bone.z, h = side * bone.x - outer }, {
        bezel = BEZEL, room = ROOM, maxTilt = MAX_PITCH, maxTurn = MAX_YAW, maxDown = MAX_DOWN, middle = tank ~= nil,
    })
    if w.inWay then w.place, w.why = nil, w.inWay end
    w.inWay = w.inWay ~= nil
    return w, stats.looks - looks0
end

-- One flank ------------------------------------------------------------------------------------

---A line found under a bezel (a body line, a seam, a lip) runs on past what was seen of it: if
---its points lie along one straight line over 3 cm or more, that line ({ u, v, du, dv }), else nil.
local function straight(points)
    if #points < 2 then return end
    local mu, mv = 0.0, 0.0
    for _, p in ipairs(points) do mu, mv = mu + p.u / #points, mv + p.v / #points end
    local suu, suv, svv = 0.0, 0.0, 0.0
    for _, p in ipairs(points) do
        local du, dv = p.u - mu, p.v - mv
        suu, suv, svv = suu + du * du, suv + du * dv, svv + dv * dv
    end
    local angle = 0.5 * math.atan(2.0 * suv, suu - svv)
    local cu, cv = math.cos(angle), math.sin(angle)
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(points) do
        local du, dv = p.u - mu, p.v - mv
        if math.abs(dv * cu - du * cv) > STRAIGHT then return end
        lo, hi = math.min(lo, du * cu + dv * cv), math.max(hi, du * cu + dv * cv)
    end
    if hi - lo >= 0.03 then return { u = mu, v = mv, du = cu, dv = cv } end
end

---Measures the flank on `side` round anchor (u, v; x: where the paint is, if known; name: what it
---is, for the log; known: what close looks round other places on this flank found, kept off and
---added to) and seats the filler on the best spot near it. Returns { fit, notes, sits, score,
---deepest } (deepest: how far from the car's middle the search ended) or nil and why.
local function fitFlank(vehicle, side, anchor)
    local started, stats = GetGameTimer(), Probe.stats
    local looks0, ms0, stale0, waits0, frames0, lost0 = stats.looks, stats.ms, stats.stale, stats.waits, stats.frames, stats.lost
    local outWorld = face(vehicle, side)

    -- Where to look from: where the wide map found the paint, or where collision says it is (it's
    -- often on it, sometimes some centimetres either way). The search runs from outside the
    -- bounding box to well inside it, so the paint is found wherever it really is.
    local out = vec3(side * 1.0, 0.0, 0.0)
    local min, max = GetModelDimensions(GetEntityModel(vehicle))
    local outer = side < 0 and -min.x or max.x
    local x = anchor.x or Probe.collisionX(vehicle, anchor.u, anchor.v, side) or side * outer
    if side * x > outer then x = side * outer end
    local reference = vec3(x, anchor.u, anchor.v)

    local halfHeight = math.max(HALF_V, HALF_U / GetAspectRatio(false)) * 1.25
    Probe.aim(vehicle, reference + out * 0.9, reference, halfHeight)
    Probe.calibrate(GetOffsetFromEntityInWorldCoords(vehicle, side * (outer + 0.04), anchor.u, anchor.v))

    -- 1. The coarse map.
    progress('Mapping the flank')
    local coarse = DoorMap.grid(anchor.u - HALF_U, anchor.u + HALF_U, anchor.v - HALF_V, anchor.v + HALF_V, COARSE)
    local outside = outer + OUTSIDE - side * x
    local list = Probe.prepare(vehicle, coarse.samples, reference,
        function(s) return -outside / along(s, outWorld) end, function(s) return DEEP / along(s, outWorld) end)
    Probe.measure(list, COARSE_ROUNDS)
    Probe.toSurface(vehicle, list, reference, side)
    local coarseLooks = stats.looks - looks0

    local found = 0
    for _, s in ipairs(coarse.samples) do if s.h then found = found + 1 end end
    if found < #coarse.samples * 0.3 then return nil, ('found the paint at only %d of %d points'):format(found, #coarse.samples) end

    -- 2. Where the bezel could go, best first. All of them: a line the close look finds rules out
    -- the near ones, and the way past it is often a few worse ones further on.
    local spots = FillerMap.spots(coarse, anchor, {
        halfU = SEARCH_U, halfV = SEARCH_V, radius = BEZEL, room = ROOM, count = math.huge, apart = 0.008, maxTilt = MAX_PITCH, maxTurn = MAX_YAW,
        uneven = UNEVEN,
    })
    local fallback = #spots == 0
    if fallback then
        -- Round a wide map's pick, the next pick is the better bet: its close looks aren't spent here.
        if anchor.strict then return nil, ('no whole, smooth paint round the %s'):format(anchor.name) end
        spots = { { u = anchor.u, v = anchor.v, distance = 0.0 } }
    end

    -- 3. A close look at the best until the bezel sits well on one (SPOTS at most), with a ring
    -- of samples ROOM round it for the room there. After one it doesn't, the next keeps clear of
    -- what was wrong under or round that one: something standing out or no paint (an opening,
    -- glass) ROOM from its rim, a line (a lip, a body line, a seam) from under it, and if what was
    -- seen of it is straight, all along it (it runs on); where the rim lifted off a curve, from
    -- under its rim.
    progress('Seating the filler')
    local known = anchor.known or { problems = {}, lines = {} }
    local cache, discRef, best, tried, problems, lines, looked = {}, nil, nil, 0, known.problems, known.lines, {}
    local function usable(spot)
        for _, o in ipairs(looked) do
            if (o.u - spot.u) ^ 2 + (o.v - spot.v) ^ 2 < APART * APART then return false end
        end
        for _, l in ipairs(lines) do
            if math.abs((spot.v - l.v) * l.du - (spot.u - l.u) * l.dv) <= BEZEL + 0.004 then return false end
        end
        for _, p in ipairs(problems) do
            local d = math.sqrt((p.u - spot.u) ^ 2 + (p.v - spot.v) ^ 2)
            if p.kind == 'hole' or p.kind == 'blocked' then
                if d < BEZEL + ROOM then return false end
            elseif d <= BEZEL + 0.004 and (p.kind == 'line' or d >= BEZEL - 0.016) then
                return false
            end
        end
        return true
    end
    while tried < SPOTS do
        local spot
        for _, s in ipairs(spots) do
            if usable(s) then spot = s break end
        end
        if not spot then break end
        looked[#looked + 1] = spot
        local height = FillerMap.surface(coarse.samples, spot, SURFACE)
        if height then
            tried = tried + 1
            spot.h = height(spot.u, spot.v)
            discRef = discRef or vec3(reference.x + side * spot.h, anchor.u, anchor.v)
            -- Each line of sight starts on the paint the coarse map has where it's aimed, so it meets
            -- the paint there (from a flat plane, on a tilted panel, the rim's would land millimetres
            -- off its circle). Its markers stop showing their reach past that.
            local disc, new = FillerMap.disc(cache, anchor, spot, BEZEL, FINE, ROOM)
            local ready = Probe.prepare(vehicle, new, discRef,
                function(s) return Probe.view.reach - WINDOW / along(s, outWorld) end,
                function(s) return Probe.view.reach + WINDOW / along(s, outWorld) end,
                function(s) return reference.x + side * height(s.u, s.v) end)
            Probe.measure(ready, FINE_ROUNDS, true)
            Probe.toSurface(vehicle, ready, discRef, side)

            local verdict = FillerMap.judge(disc, spot, BEZEL, { uneven = UNEVEN })
            verdict.spot, verdict.disc, verdict.index = spot, disc, tried
            if verdict.ok then
                best = verdict
                break
            end
            say(('  spot %d, %+d mm along and %+d mm up from the %s: %s'):format(tried, mm(spot.u - anchor.u), mm(spot.v - anchor.v), anchor.name, verdict.why))
            local line = {}
            for _, p in ipairs(verdict.bad) do
                problems[#problems + 1] = p
                if p.kind == 'line' then line[#line + 1] = p end
            end
            lines[#lines + 1] = straight(line)
            if not best or verdict.score < best.score then best = verdict end
        end
    end
    local what = anchor.name
    if not best and #looked == 0 then return nil, ('no spot round the %s clear of what close looks found'):format(what) end
    if not best then return nil, ('too little paint measured round the %s'):format(what) end
    if not best.seat then return nil, best.why end

    local seat, centre = best.seat, best.spot
    local outward = Vec.normalize(vec3(side * 1.0, -seat.b, -seat.c))
    local at = vec3(discRef.x + side * seat.a, centre.u, centre.v) + outward * ON_PAINT
    local into = outward * -1.0
    local pitch = math.deg(math.asin(Clamp(into.z, -1.0, 1.0)))
    local yaw = math.deg(math.atan(-into.x, into.y))

    local notes = {}
    if fallback then notes[#notes + 1] = ('no whole, smooth paint near the %s: seated on it'):format(what) end
    if not best.ok then notes[#notes + 1] = best.why end

    -- Within what the siphon's scene handles (the hoses, the funnel and the camera are laid out square-ish).
    local square = 90.0 * side
    local turn = (yaw - square + 180.0) % 360.0 - 180.0
    if math.abs(pitch) > MAX_PITCH or math.abs(turn) > MAX_YAW then
        notes[#notes + 1] = ('the paint is turned %.0f / tilted %.0f degrees: limited'):format(turn, pitch)
        pitch = Clamp(pitch, -MAX_PITCH, MAX_PITCH)
        yaw = square + Clamp(turn, -MAX_YAW, MAX_YAW)
    end

    say(('  %s flank: paint at %d of %d coarse points; spot %d of %d looked at, %d mm from the %s: rim gap %.1f mm, mean gap %.1f mm, tilted %.1f, turned %.1f (reach %.1f mm)'):format(
        side < 0 and 'left' or 'right', found, #coarse.samples, best.index, tried, mm(centre.distance or 0.0), what,
        best.rimGap * 1000, seat.gap * 1000, pitch, turn, Probe.view.reach * 1000))
    say(('  %d looks (coarse %d, close %d) in %d frames, %.1f s, %d frames read too early, %d looks drawn again (frame missed), %d frames waited for the camera to move; %.1f s in all'):format(
        stats.looks - looks0, coarseLooks, stats.looks - looks0 - coarseLooks, stats.frames - frames0, (stats.ms - ms0) / 1000,
        stats.stale - stale0, stats.lost - lost0, stats.waits - waits0, (GetGameTimer() - started) / 1000))

    if show then
        showMap(vehicle, {
            side = side, anchor = anchor, reference = reference, discRef = discRef, coarse = coarse,
            spots = spots, best = best, height = FillerMap.surface(coarse.samples, anchor, SURFACE) or function() return 0.0 end,
        })
    end

    return {
        fit = { x = at.x, y = at.y, z = at.z, pitch = pitch, yaw = yaw, auto = true, check = #notes > 0 or nil },
        notes = notes,
        sits = best.ok and not fallback, score = best.score, -- the bezel sits well; how badly it doesn't
        deepest = side * x - DEEP,
    }
end

---Seats the filler round a wide map's pick, or round its next best places if it doesn't sit well
---there (a curve or a line the wide map is too coarse to see); if nowhere round any of them is
---smooth, round the first all the same, to be checked. `where`: where the places are, for the log;
---`names`: what the first and the next picks are called. Returns the result, why if none and the
---pick it went on.
local function fitPicks(vehicle, wide, where, names)
    local place, side = wide.place, wide.side
    local picks = { place }
    for _, other in ipairs(place.others) do picks[#picks + 1] = other end
    local known = { problems = {}, lines = {} } -- what the close looks found: a body line runs on to the next pick too
    local result, why, picked
    for k, pick in ipairs(picks) do
        if k > 1 then
            say(('  the next best place %s: %+d mm along and %+d mm up from the first'):format(
                where, mm(pick.u - place.u), mm(pick.v - place.v)))
        end
        local name = k == 1 and names[1] or names[2]
        local r, w = fitFlank(vehicle, side, { u = pick.u, v = pick.v, x = wide.reference.x + side * pick.h, name = name, strict = true, known = known })
        if r and (not result or (r.sits and not result.sits) or (r.sits == result.sits and r.score < result.score)) then
            result, picked = r, pick
        end
        if not r then say(('  %s'):format(w)) end
        why = why or w
        if r and r.sits then break end
    end
    if not result then
        -- Nowhere smooth round any of them: seated round the first all the same, to be checked.
        result, why = fitFlank(vehicle, side, { u = place.u, v = place.v, x = wide.reference.x + side * place.h, name = names[1] })
        picked = result and place
    end
    return result, why, picked
end

-- One car --------------------------------------------------------------------------------------

---A side tank's bone `b` (vehicle space) on `side`: the tank mapped along from the wheel behind it to
---the one ahead (mapBone), the filler in its middle along the car, as high as the place on it nearest
---the bone. If nothing on it will do, on the paint round the bone, to be checked. Returns the fit,
---notes and the tank ({ lo, hi, middle, v, openLo, openHi, bone }, vehicle y and z; nil if its ends
---weren't found), or nil, why and the tank.
local function fitTank(vehicle, b, boneName, side, wheel)
    local near, looks = mapBone(vehicle, side, b, wheel.r)
    if show then showWide(vehicle, near) end
    local p, tank = near.place, nil
    local result, why
    local head = ('  the %s bone is ahead of the rear wheel (a side tank)'):format(boneName)
    if p then
        local skin = 0
        for _, s in ipairs(near.map.samples) do if s.skin then skin = skin + 1 end end
        local ends = ', its ends not found at that height'
        if p.tank then
            local t = p.tank
            tank = { lo = t.lo, hi = t.hi, middle = t.middle, v = p.target.v, openLo = t.openLo, openHi = t.openHi, bone = b }
            ends = (', at the height of the place on it nearest the bone it runs from %+d to %+d mm along from the bone%s'):format(
                mm(t.lo - b.y), mm(t.hi - b.y), (t.openLo or t.openHi) and (' (on past the map %s)'):format(t.openLo and 'behind' or 'ahead') or '')
        end
        say(('%s: the tank (%d mm from the bone) at %d of %d points (%d looks; %d with no paint, %d hidden outside the car\'s box)%s; the bezel fits in %d places on it, picked one %d mm from %s'):format(
            head, mm(p.away), skin, #near.map.samples, looks, near.holes, near.blocked, ends, p.fits,
            mm(math.sqrt((p.u - p.target.u) ^ 2 + (p.v - p.target.v) ^ 2)), p.tank and 'its middle' or 'the bone'))
        result, why = fitPicks(vehicle, near, 'on the tank', { 'place on the tank', 'next place on the tank' })
    else
        say(('%s: %s (%d looks; %d of %d points with no paint, %d hidden outside the car\'s box)'):format(
            head, near.why, looks, near.holes, #near.map.samples, near.blocked))
        why = near.why
    end
    if not result and not near.inWay then
        -- Nothing on the tank: round the bone, to be checked.
        local r = fitFlank(vehicle, side, { u = b.y, v = b.z, name = 'bone' })
        if r then
            table.insert(r.notes, 1, ('nothing on the tank would do (%s): fitted round the %s bone'):format(why, boneName))
            r.fit.check = true
            result = r
        end
    end
    if not result then return nil, ('round the %s bone: %s'):format(boneName, why), tank end
    return result.fit, table.concat(result.notes, ', '), tank
end

---Fits a car round its petroltank bone `b` (vehicle space, off the car's middle), on the bone's side:
---on the paint there if the bezel sits well on it. A bone ahead of the rear wheel is a lorry's side
---tank (no car's filler is): fitTank. Otherwise, if it's inside what it's on (too little paint round
---it, nothing smooth) or further into the bounding box than the search reached (it starts at the
---box, the mirrors stick out far, and collision can miss it): on the surface the bone is on, mapped
---wide round it (mapBone). Returns the fit and notes, or nil and why (and fitTank's tank).
local function fitBone(vehicle, b, boneName)
    local side = b.x >= 0 and 1 or -1
    local wheel = Siphon.rearWheel(vehicle, side)
    if wheel and b.y > wheel.y + wheel.r then return fitTank(vehicle, b, boneName, side, wheel) end
    local result, why = fitFlank(vehicle, side, { u = b.y, v = b.z, name = 'bone' })
    -- What the bone is on is outward of it: a search that ended short of it may have found something
    -- standing out in front of that instead (a step), or nothing.
    local short = result and result.deepest > side * b.x
    if result and result.sits and not short then return result.fit, table.concat(result.notes, ', ') end
    local trouble = not result and why
        or short and ('the search ended %d mm short of it (collision missed what it is on?)'):format(mm(result.deepest - side * b.x))
        or table.concat(result.notes, ', ')
    say(('  round the %s bone: %s; mapping wide round it'):format(boneName, trouble))

    local near, looks = mapBone(vehicle, side, b)
    if show then showWide(vehicle, near) end
    local other, otherWhy
    local p = near.place
    if p then
        local skin = 0
        for _, s in ipairs(near.map.samples) do if s.skin then skin = skin + 1 end end
        say(('  round the bone: what it is on (%d mm from it) at %d of %d points (%d looks; %d with no paint, %d hidden outside the car\'s box); the bezel fits in %d places on it, picked one %d mm from the bone (%+d mm along, %+d mm up)'):format(
            mm(p.away), skin, #near.map.samples, looks, near.holes, near.blocked, p.fits, mm(math.sqrt((p.u - b.y) ^ 2 + (p.v - b.z) ^ 2)),
            mm(p.u - b.y), mm(p.v - b.z)))
        other, otherWhy = fitPicks(vehicle, near, 'near the bone', { 'place near the bone', 'next place near the bone' })
    else
        say(('  round the bone: %s (%d looks; %d of %d points with no paint, %d hidden outside the car\'s box)'):format(
            near.why, looks, near.holes, #near.map.samples, near.blocked))
    end

    -- One the bezel sits well on; else the least bad, to be checked. A fit from a search that ended
    -- short of the bone only if nothing came of the wide map.
    local pick = result
    if other and (other.sits or not result or short or other.score <= result.score) then pick = other end
    if not pick then
        return nil, ('round the %s bone: %s; round it wide: %s'):format(boneName, why, p and otherWhy or near.why)
    end
    if pick == result and short then
        table.insert(pick.notes, 1, ('the search ended %d mm short of the %s bone and nothing round it would do: maybe not on what it is on'):format(
            mm(result.deepest - side * b.x), boneName))
        pick.fit.check = true
    end
    return pick.fit, table.concat(pick.notes, ', ')
end

---Fits one car. Its doors and glass come off for it (SetVehicleFixed puts them back). Returns the
---fit, notes and what the wide map found ({ wheel, archTop, panelTop, target, tail, picked }, vehicle
---space; with a side tank fitTank's tank, with another bone nil), or nil, why and that. If the bezel doesn't sit well round the wide map's
---pick (a curve or a line it's too coarse to see), it tries the next best places on it.
local function fitCar(vehicle)
    local bone, boneName = Siphon.dev.bone(vehicle)
    local middle -- a bone in the car's middle: not where the filler goes on a flank (the hand fits say so)
    if bone then
        local b = GetOffsetFromEntityGivenWorldCoords(vehicle, bone.x, bone.y, bone.z)
        if math.abs(b.x) >= 0.15 then
            strip(vehicle)
            return fitBone(vehicle, b, boneName)
        end
        middle = ('the %s bone is in the car\'s middle: placed by the rear quarter'):format(boneName)
    end

    -- No bone: where the left flank's rear quarter says, mirrored to whichever side the player stands.
    local wheel = Siphon.rearWheel(vehicle, -1)
    if not wheel then return nil, 'no petroltank bone and no rear wheel to start from' end
    -- If the wide map finds nowhere (its collision rays: before the doors come off). With a bone the
    -- guess is the bone, in the middle here: no guess then.
    local guess = not middle and Siphon.guessFit(vehicle, -1)
    strip(vehicle)
    local wide, looks = mapQuarter(vehicle, -1, wheel)
    local place, anchor, quarter = wide.place, nil, nil
    if place then
        local skin = 0
        for _, s in ipairs(wide.map.samples) do if s.skin then skin = skin + 1 end end
        say(('  rear quarter: skin at %d of %d points (%d looks; %d with no paint, %d hidden outside the car\'s box); arch top %d mm over the tyre%s, panel top %d mm over the arch; the bezel fits in %d places, aimed %.2f tyre radii behind the wheel\'s middle and %d mm over the arch, picked one %d mm from there'):format(
            skin, #wide.map.samples, looks, wide.holes, wide.blocked, mm(place.archTop - wheel.z - wheel.r),
            place.arch == 'lifted' and ' (a lifted body: no skin within 25 cm of the tyre)' or place.arch == 'guessed' and ' (guessed: not found)' or '',
            mm(place.panelTop - place.archTop), place.fits,
            (wheel.y - place.target.u) / wheel.r, mm(place.target.v - place.archTop),
            mm(math.sqrt((place.u - place.target.u) ^ 2 + (place.v - place.target.v) ^ 2))))
        local min = GetModelDimensions(GetEntityModel(vehicle))
        quarter = { wheel = wheel, archTop = place.archTop, panelTop = place.panelTop, target = place.target, tail = min.y }
    else
        say(('  rear quarter: %s (%d looks; %d of %d points with no paint, %d hidden outside the car\'s box)%s'):format(
            wide.why, looks, wide.holes, #wide.map.samples, wide.blocked, guess and not wide.inWay and '; starting from the guess' or ''))
        if not guess or wide.inWay then return nil, wide.why end
        anchor = { u = guess.y, v = guess.z, x = guess.x, name = 'guess' }
    end
    if show then showWide(vehicle, wide) end

    local result, why
    if place then
        result, why, quarter.picked = fitPicks(vehicle, wide, 'on the rear quarter', { 'wide map\'s pick', 'wide map\'s next pick' })
    else
        result, why = fitFlank(vehicle, -1, anchor)
    end
    if not result then return nil, why, quarter end
    if not place then
        table.insert(result.notes, 1, wide.why)
        result.fit.check = true
    end
    if middle then
        table.insert(result.notes, 1, middle)
        result.fit.check = true
    end
    result.fit.both = true
    return result.fit, table.concat(result.notes, ', '), quarter
end

Siphon.dev.fitCar = fitCar -- tests/probe.lua runs it on a made-up car

---Waits for the car's close-up model: the probe reads the depth of the model that's drawn. False
---if the game never said it was in.
local function closeUp(vehicle)
    if fixedWait or not RequestVehicleHighDetailModel or not IsVehicleHighDetail then
        Wait(700)
        return true
    end
    RequestVehicleHighDetailModel(vehicle)
    local deadline = GetGameTimer() + 2000
    while not IsVehicleHighDetail(vehicle) do
        if GetGameTimer() > deadline then
            slowDetail = slowDetail + 1
            if slowDetail >= 3 then
                fixedWait = true
                say('the game never says the close-up model is in: waiting 700 ms a car from now on')
            end
            return false
        end
        Wait(0)
    end
    slowDetail = 0
    Wait(0) -- and drawn once
    return true
end

-- Comparing with the hand fits -------------------------------------------------------------------

---How far `fit` is from the hand fit (mirrored to its side if it's for both): { distance, along,
---up, out, tilt, turn }, metres and degrees.
local function offBy(fit, hand)
    if hand.both and (hand.x >= 0) ~= (fit.x >= 0) then hand = Siphon.mirrorFit(hand) end
    local side = fit.x >= 0 and 1 or -1
    local d = { along = fit.y - hand.y, up = fit.z - hand.z, out = side * (fit.x - hand.x) }
    d.distance = math.sqrt(d.along ^ 2 + d.up ^ 2 + d.out ^ 2)
    d.tilt = fit.pitch - hand.pitch
    d.turn = (fit.yaw - hand.yaw + 180.0) % 360.0 - 180.0
    return d
end

local function describe(d)
    return ('%d mm off (along %+d, up %+d, out %+d), tilt %+.1f, turn %+.1f'):format(
        mm(d.distance), mm(d.along), mm(d.up), mm(d.out), d.tilt, d.turn)
end

local function sorted(list, key)
    local values = {}
    for _, d in ipairs(list) do values[#values + 1] = math.abs(d[key]) end
    table.sort(values)
    return values
end

local function at(values, share)
    if #values == 0 then return 0.0 end
    return values[math.max(1, math.ceil(#values * share))]
end

local function summary(name, list)
    if #list == 0 then return end
    local distance = sorted(list, 'distance')
    local within10, within20 = 0, 0
    for _, v in ipairs(distance) do
        if v <= 0.010 then within10 = within10 + 1 end
        if v <= 0.020 then within20 = within20 + 1 end
    end
    local tilt, turn = sorted(list, 'tilt'), sorted(list, 'turn')
    say(('%s: %d mm off in the middle, %d mm for the worst tenth, %d mm at most; %d of %d within 10 mm, %d within 20 mm; tilt %.1f / turn %.1f degrees off in the middle'):format(
        name, mm(at(distance, 0.5)), mm(at(distance, 0.9)), mm(distance[#distance]), within10, #list, within20,
        at(tilt, 0.5), at(turn, 0.5)))
end

---Where a fit is on the rear quarter the wide map found (`quarter` from fitCar): tyre radii behind
---the wheel's middle, metres over the arch's top, under the panel's top and in front of the tail.
local function onQuarter(quarter, fit)
    local w = quarter.wheel
    return { behind = (w.y - fit.y) / w.r, over = fit.z - quarter.archTop, under = quarter.panelTop - fit.z, tail = fit.y - quarter.tail }
end

local function middle(list, key)
    local values = {}
    for _, q in ipairs(list) do values[#values + 1] = q[key] end
    table.sort(values)
    return at(values, 0.5)
end

-- The run --------------------------------------------------------------------------------------

local function run(arg, compare, force)
    local Dev = Siphon.dev
    local list
    if force then
        -- Every car, the fits made by hand too (copies follow their model's).
        list = Dev.carModels(function() return true end)
    elseif compare then
        -- The fits made by hand (copies follow their model's).
        list = {}
        for model, fit in pairs(Siphon.savedFits) do
            if not fit.auto and not fit.from and (not arg or model == arg:lower()) then list[#list + 1] = model end
        end
        table.sort(list)
        if #list == 0 then return say(arg and (arg .. ' has no fit made by hand to compare with') or 'no fits made by hand to compare with') end
    elseif arg == 'redo' or arg == 'all' then
        -- Fits made by hand are never overwritten: they took someone a long time.
        list = Dev.carModels(function(_, saved) return not saved or saved.auto end)
    elseif arg then
        list = { arg:lower() }
    else
        list = Dev.carModels(function(_, saved) return not saved end)
    end
    if #list == 0 then return say('nothing to fit') end
    say(('%d cars to %s. Esc stops, Backspace skips a car, C zooms out on the next one.'):format(#list, compare and 'compare' or 'fit'))

    local ped = PlayerPedId()
    local home, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityVisible(ped, false, false)
    NetworkOverrideClockTime(12, 0, 0) -- daylight on this screen only, so the markers read clearly

    local scene, vehicle
    local fitted, checks, copied, failed, replaced = 0, 0, 0, {}, 0
    local named = compare or (not force and arg and arg ~= 'redo' and arg ~= 'all') -- by name: measured even with a twin
    local unread = 0 -- cars in a row the game frame couldn't be read for
    local started = GetGameTimer()
    local against, guesses, hands = {}, {}, {} -- compare: how far off the new fits and the guesses are, where the hand fits are

    local ok, err = pcall(function()
        for index, wanted in ipairs(list) do
            if Probe.stopAsked then break end
            Probe.skipAsked = false
            local carStarted, carFrames = GetGameTimer(), Probe.stats.frames

            status = { model = wanted, index = index, total = #list, started = started, phase = 'Loading the car' }
            progress()
            -- A model with the same body has a fit already: copy it instead of measuring.
            local twin = not named and not Siphon.savedFits[wanted] and Dev.copyTwin(wanted)
            if twin then copied = copied + 1 end
            vehicle = not twin and DevCars.spawn(wanted, home, heading) or nil
            spawnHeading = heading
            -- The next car's model loads while this one is measured.
            local nextModel = list[index + 1] and joaat(list[index + 1])
            if nextModel and IsModelInCdimage(nextModel) then RequestModel(nextModel) end

            if twin then
                -- copied
            elseif not vehicle then
                failed[#failed + 1] = wanted .. ' (model did not load)'
            elseif Dev.isElectric(GetEntityModel(vehicle)) then
                failed[#failed + 1] = wanted .. ' (electric: no filler)'
            else
                SetVehicleColours(vehicle, 12, 12) -- matte black: nothing in the paint looks like a marker
                local detailed = closeUp(vehicle)

                if scene then for id in pairs(scene.parts) do scene:setVisible(id, false) end end

                local model = Siphon.modelName(vehicle)
                status.model = model
                say(('%s (%d / %d)'):format(model, index, #list))
                local guess = compare and Siphon.guessFit(vehicle, -1) -- before the doors come off
                local done, fit, note, quarter = pcall(fitCar, vehicle)
                SetVehicleFixed(vehicle) -- the doors and the glass back on
                if done then
                    unread = 0
                else
                    if fit == 'stopped' then error(fit, 0) end
                    -- Skipped, or the game frame couldn't be read for this car: on to the next one.
                    if fit ~= 'skipped' then unread = unread + 1 end
                    if unread >= 3 then error('three cars in a row could not be measured: ' .. tostring(fit), 0) end
                    fit, note = nil, tostring(fit)
                end
                if fit and not detailed then
                    fit.check = true
                    note = (note ~= '' and (note .. ', ') or '') .. 'the game never said the close-up model was in'
                end

                local own = Siphon.savedFits[model]
                local shown = false
                if fit and compare then
                    local d = offBy(fit, own)
                    against[#against + 1] = d
                    local g = guess and offBy(guess, own)
                    if g then guesses[#guesses + 1] = g end
                    say(('  vs the hand fit (%.1f s, %d frames measuring): %s%s'):format((GetGameTimer() - carStarted) / 1000, Probe.stats.frames - carFrames, describe(d),
                        note ~= '' and (' (check: ' .. note .. ')') or ''))
                    if g then say(('  the guess was %s'):format(describe(g))) end
                    shown = true
                elseif fit and own and not own.auto and not force then
                    say(('%s has a fit made by hand; kept that one (this one was not saved)'):format(model))
                    failed[#failed + 1] = model .. ' (has a fit made by hand, kept)'
                elseif fit then
                    local saved = Dev.save(model, fit)
                    if saved then
                        Dev.updateCopies(model)
                        fitted = fitted + 1
                        if own and not own.auto then replaced = replaced + 1 end
                        if fit.check then checks = checks + 1 end
                        say(('%s fitted in %.1f s (%d frames measuring)%s'):format(model, (GetGameTimer() - carStarted) / 1000, Probe.stats.frames - carFrames,
                            note ~= '' and (' (check: ' .. note .. ')') or ''))
                        shown = true
                    else
                        failed[#failed + 1] = model .. ' (not saved: are you an admin?)'
                    end
                else
                    local kept = own and (own.auto and '; kept its old automatic fit' or '; kept its fit made by hand') or ''
                    failed[#failed + 1] = ('%s (%s%s)'):format(model, note, kept)
                    say(('%s: %s%s'):format(model, note, kept))
                end
                if compare and quarter and quarter.bone and own then
                    -- A side tank: where the hand fit is along it (also when this car wasn't fitted).
                    local t = quarter
                    say(('  on the tank, the hand fit is %d mm from its back end and %d mm from its front end (%d%% of the way from the back; the tank %d mm long%s), %+d mm up from the height aimed at; the bone %+d mm along from it'):format(
                        mm(own.y - t.lo), mm(t.hi - own.y), math.floor((own.y - t.lo) / math.max(0.001, t.hi - t.lo) * 100 + 0.5), mm(t.hi - t.lo),
                        (t.openLo or t.openHi) and (', running on past the map ' .. (t.openLo and 'behind' or 'ahead')) or '',
                        mm(own.z - t.v), mm(t.bone.y - own.y)))
                elseif compare and quarter and own then
                    -- Where the hand fit is on this body, in the terms the wide map picks by (also
                    -- when this car wasn't fitted).
                    local h = onQuarter(quarter, own)
                    hands[#hands + 1] = h
                    local p = quarter.picked and onQuarter(quarter, { y = quarter.picked.u, z = quarter.picked.v })
                    say(('  on the rear quarter, the hand fit is %.2f tyre radii behind the wheel\'s middle, %d mm over the arch, %d mm under the panel\'s top and %d mm in front of the tail (the wheel\'s middle %d mm); %s'):format(
                        h.behind, mm(h.over), mm(h.under), mm(h.tail), mm(quarter.wheel.y - quarter.tail),
                        p and ('picked: %.2f, %d mm, %d mm, %d mm'):format(p.behind, mm(p.over), mm(p.under), mm(p.tail)) or 'nothing picked'))
                end

                if shown then
                    -- Show the result: a moment, or zoomed out until C.
                    local offset = vec3(fit.x, fit.y, fit.z)
                    if not scene then
                        scene = Scene.new(vehicle, offset, fit.pitch, fit.yaw)
                        Dev.spawnFiller(scene)
                    else
                        scene.entity = vehicle
                        scene:setPlacement(offset, fit.pitch, fit.yaw)
                    end
                    for id in pairs(scene.parts) do scene:setVisible(id, true) end
                    Probe.drawList = nil
                    preview = function()
                        local cam = Probe.camera()
                        if not cam then return end
                        local from = scene:toWorld(VIEW.pos * (wide and WIDE or CLOSE))
                        local target = scene:toWorld(VIEW.target)
                        SetCamCoord(cam, from.x, from.y, from.z)
                        PointCamAtCoord(cam, target.x, target.y, target.z)
                        SetCamFov(cam, VIEW.fov)
                    end
                    preview()
                    status.holding = wide
                    progress(wide and 'Fitted. C zooms back in and goes on to the next car' or 'Fitted')
                    local shownUntil = GetGameTimer() + SHOWN
                    while (wide or GetGameTimer() < shownUntil) and not Probe.stopAsked and not Probe.skipAsked do Wait(0) end
                    status.holding = false
                    preview = nil
                end

                Probe.drawList = nil
                DeleteEntity(vehicle)
                vehicle = nil
            end
            if vehicle and DoesEntityExist(vehicle) then
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
    local seconds = (GetGameTimer() - started) / 1000
    if compare then
        say(('compared %d cars in %d s (%.1f s a car), %d could not be fitted'):format(#against, math.floor(seconds),
            seconds / math.max(1, #against + #failed), #failed))
        summary('the autofit', against)
        summary('the guess', guesses)
        if #hands > 0 then
            say(('the hand fits on the rear quarters (middle values of %d): %.2f tyre radii behind the wheel\'s middle, %d mm over the arch, %d mm under the panel\'s top, %d mm in front of the tail'):format(
                #hands, middle(hands, 'behind'), mm(middle(hands, 'over')), mm(middle(hands, 'under')), mm(middle(hands, 'tail'))))
        end
    else
        say(('done in %d s: %d fitted (%d to check with /filler_fitall review%s), %d copied from a model with the same body, %d not fitted'):format(
            math.floor(seconds), fitted, checks, force and (', %d of them replacing fits made by hand'):format(replaced) or '', copied, #failed))
    end
    for _, line in ipairs(failed) do say('  not fitted: ' .. line) end
    if #failed > 0 and not compare then say('fit those by hand with /filler_fitall <model>') end
end

---Starts a run (`force`: /filler_forceauto), unless something's in the way.
local function start(args, force)
    if running then return say('already running') end
    if Siphon.current then return say('finish siphoning first') end
    if TR.cache.vehicle then return say('get out of the car first') end
    if not TR.ui.probeFrame then
        return say('needs the latest tr_core: ensure tr_core, then tr_minigames')
    end

    -- `show` and `compare` can go anywhere; the other word picks the cars.
    local what, compare
    show = false
    for _, word in ipairs(args) do
        word = word:lower()
        if word == 'show' then show = true
        elseif word == 'compare' and not force then compare = true
        elseif not force then what = what or word end
    end

    running, preview, wide = true, nil, false
    Probe.stopAsked, Probe.skipAsked = false, false
    Probe.hooks = { say = say, phase = progress }
    drawThread()
    CreateThread(function()
        local ok, err = pcall(run, what, compare, force)
        if not ok then say('error: ' .. tostring(err)) end
        running, status = false, nil
    end)
end

RegisterCommand('filler_autofit', function(_, args) start(args, false) end, false)
-- Every car fitted again, the fits made by hand replaced too (the release's fits.json).
RegisterCommand('filler_forceauto', function(_, args) start(args, true) end, false)
