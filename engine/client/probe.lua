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
        local list = Probe.prepare(vehicle, samples, reference, lo, hi)  -- samples { u, v }; start(s): see there
        Probe.measure(list, rounds, inside)                         -- inside: the paint is between lo and hi
        Probe.toSurface(vehicle, list, reference, side)             -- sample.h
        Probe.draw()                                                -- every frame while running
        Probe.stopAsked, Probe.skipAsked                            -- set by the caller's keys
        Probe.stats                                                 -- { looks, ms, stale, caps, waits, frames, lost } so far
        Probe.finish()                                              -- camera off

    The game draws only so many markers a frame (about a hundred). Each frame shows one look: as
    many markers as that allows, the probe finds the exact number by itself. The page sees a frame
    a frame after it's drawn and its answer comes back a frame later, so a look isn't waited for:
    the next goes up while it's read, and every line of sight goes on to its next marker as soon as
    its answer is in. If the page turns out to see only every other frame, looks stay up two
    frames each for a while.

    Each look also draws corner markers: a row of five in a corner of the view, which say which look
    the frame read shows and whether it was drawn in full. What is measured has to stay inside 92% of
    the view (top to bottom) to keep clear of them. If they stop showing (something in front of the
    camera, the game's help text), the probe finds a corner where they do, says so and keeps it.
]]

Probe = {}

local ROUNDS = 10                     -- binary search steps: 35 cm down to a third of a millimetre
local SENTINELS = 5                   -- corner markers: two of the first four say which look it is, and one drawn last
local CODES = { 3, 5, 6, 9, 10, 12 }  -- which two: one marker missing or one too many never passes for another look
local MARKED = 3                      -- corner markers a look draws: two of the first four and the last
local DEPTH = 4                       -- looks up at once that aren't read yet (fewer than #CODES: see Probe.measure)
local CLOSE = 0.25                    -- they're this far in front of the camera to begin with
local READS = 10                      -- frames a look may wait for its answer before it counts as unanswered
local ROW = 8                         -- looks seen running whose frame before went by unread: the page sees every other frame
local TWICE = 100                     -- then this many looks stay up two frames each
local RETRIES = 4                     -- looks in a row that may go unanswered before measuring gives up
local SETTLE = 30                     -- frames the game may take to draw from where the camera was put
local MAGENTA = { 255, 0, 255 }
local CALIBRATOR = joaat('tr_lp_bezel') -- the lock's chrome ring: its face is flat from 8 to 12.6 mm out, at y = -2.5 mm

Probe.ROUNDS = ROUNDS
Probe.hooks = { say = print, phase = function() end }
Probe.stopAsked, Probe.skipAsked = false, false
Probe.drawList = nil                  -- { { world, size, color? }, ... } drawn every frame while set
Probe.view = {}                       -- the current camera: world position, axes, fov, metres per pixel
-- looks drawn, ms they took, frames read too early, times over the cap, frames waited for the camera,
-- frames measuring took, looks whose frame went by unread (drawn again)
Probe.stats = { looks = 0, ms = 0, stale = 0, caps = 0, waits = 0, frames = 0, lost = 0 }

local MAX_PER_FRAME = 2400
local perFrame = 400                  -- markers drawn at once (sentinels too): grows while the game draws them all and
local drawn, capped = 0, nil          -- homes in between the most it drew in full and the fewest it didn't
local settled = false                 -- found how many: said so
local reaches = {}                    -- calibrate(): view.reach for each camera set-up seen this session
local placeFor = {}                   -- recover(): where the corner markers show, for each camera set-up
local toldSettle = false              -- said the game never caught up with the camera
local cam

-- Where the corner markers can go: each corner close to the camera, then each halfway to what it
-- looks at. The first is where they go until Probe.recover() finds they don't show there.
local PLACES = {}
for _, depth in ipairs({ 'close', 'halfway' }) do
    for _, c in ipairs({ { 'top left', -1, 1 }, { 'top right', 1, 1 }, { 'bottom right', 1, -1 }, { 'bottom left', -1, -1 } }) do
        PLACES[#PLACES + 1] = { name = c[1], x = c[2], y = c[3], depth = depth }
    end
end

local function say(text) Probe.hooks.say(text) end

---Draws the markers in Probe.drawList: call every frame. Notes the frame each list is first drawn
---in (list.drawn: the page can see it from the next frame on) and in how many frames (list.shown).
function Probe.draw()
    -- Nothing of the game's over the frame: its help text sits in the top left.
    HideHelpTextThisFrame()
    ThefeedHideThisFrame()
    local list = Probe.drawList
    if not list then return end
    if not list.drawn then list.drawn = GetFrameCount() end
    list.shown = (list.shown or 0) + 1
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

---Puts the camera where `view` says: a new one if `fresh` (or there's none yet).
local function point(view, fresh)
    if fresh or not cam then
        local old = cam
        cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        SetCamUseShallowDofMode(cam, false)
        SetCamMotionBlurStrength(cam, 0.0)
        SetCamActive(cam, true)
        RenderScriptCams(true, false, 0, true, false)
        if old then DestroyCam(old, false) end
    end
    SetCamCoord(cam, view.from.x, view.from.y, view.from.z)
    PointCamAtCoord(cam, view.at.x, view.at.y, view.at.z)
    SetCamFov(cam, view.fov)
end

---Where each corner marker is on screen, as the game draws now (asked again for every frame read:
---right after the camera moves, the game can still be a frame behind).
local function project(view)
    for _, m in ipairs(view.sentinels) do
        local _, sx, sy = GetScreenCoordFromWorldCoord(m[1].x, m[1].y, m[1].z)
        m[3], m[4] = sx, sy
    end
end

---How far in front of the camera the corner markers at `place` are.
local function depthOf(view, place)
    return place.depth == 'close' and CLOSE or math.max(CLOSE, view.distance * 0.5)
end

---The corner markers at `place` (one of PLACES): a row of five at the very edge of the view, as big
---on screen wherever they are. Each is { world, size, sx, sy }.
local function placeSentinels(view, place)
    local depth = depthOf(view, place)
    local h = depth * math.tan(math.rad(view.fov) * 0.5)
    local w = h * GetAspectRatio(false)
    view.place, view.sentinels = place, {}
    for i = 1, SENTINELS do
        local p = view.from + view.forward * depth + view.right * (place.x * (0.96 - (i - 1) * 0.05) * w) + view.up * (place.y * 0.96 * h)
        view.sentinels[i] = { p, h * 0.03, -1.0, -1.0 }
    end
    project(view)
end

---Where the game puts the spot the camera looks at, and a spot above it, on screen: { x, y, x, y }.
local function landmarks(view)
    local above = view.at + view.up * (view.halfHeight * 0.8)
    local _, ax, ay = GetScreenCoordFromWorldCoord(view.at.x, view.at.y, view.at.z)
    local _, bx, by = GetScreenCoordFromWorldCoord(above.x, above.y, above.z)
    return { ax, ay, bx, by }
end

---Waits for the game's screen positions to be the camera's: right after it moves, they can be the
---old place's for some frames (more right after measuring), and every line of sight would be read
---at the wrong pixel. They are when the spot it looks at is in the middle of the screen and the
---spot above it where the view puts it (0.4 of the screen up).
local function settle(view)
    local want = { 0.5, 0.5, 0.5, 0.1 }
    local waited, got = 0, nil
    while true do
        got = landmarks(view)
        local off = 0.0
        for i = 1, 4 do off = math.max(off, math.abs(got[i] - want[i])) end
        if off < 0.004 or waited >= SETTLE then break end
        Wait(0)
        waited = waited + 1
    end
    Probe.stats.waits = Probe.stats.waits + waited
    if waited >= SETTLE and not toldSettle then
        toldSettle = true
        say(('the game\'s screen positions never matched the camera (after %d frames: the middle of the view at %.3f %.3f, a spot above it at %.3f %.3f; should be 0.5 0.5 and 0.5 0.1)'):format(
            SETTLE, got[1], got[2], got[3], got[4]))
    end
end

---Points the camera from `fromV` at `atV` (vehicle space), `halfHeight` metres of view above and
---below `atV`.
function Probe.aim(vehicle, fromV, atV, halfHeight)
    local from = GetOffsetFromEntityInWorldCoords(vehicle, fromV.x, fromV.y, fromV.z)
    local at = GetOffsetFromEntityInWorldCoords(vehicle, atV.x, atV.y, atV.z)
    local distance = #(at - from)
    local fov = math.deg(2.0 * math.atan(halfHeight / distance))

    local _, screenHeight = GetActiveScreenResolution()
    local forward = Vec.normalize(at - from)
    local right = Vec.normalize(Vec.cross(forward, vec3(0.0, 0.0, 1.0)))
    local view = {
        from = from, at = at, distance = distance, forward = forward, right = right, up = Vec.cross(right, forward), fov = fov,
        halfHeight = halfHeight,
        pixel = 2.0 * halfHeight / math.max(screenHeight, 480), -- metres per pixel at the surface
        setup = math.floor(fov / 5.0 + 0.5),                    -- set-ups this alike share where the corner markers go
    }
    Probe.view = view
    view.reach = Probe.markerSize() -- until Probe.calibrate measures it: a sphere marker's scale is its radius

    local known = placeFor[view.setup]
    point(view, known and known.fresh)
    Wait(0)
    Wait(0) -- the camera has to have rendered before screen positions are right
    settle(view)
    placeSentinels(view, known and known.place or PLACES[1])
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

local lastRead -- what the corner markers last read as, and what was drawn: for the log

---Do the corner markers show as drawn? Two looks with only them in: the first four, then the last
---alone (something in the corner that looks like a marker can't pass for them, and neither passes
---for a look: a look draws two of the first four).
local function cornerReads(view)
    for pass = 1, 2 do
        local list, want = {}, {}
        for i = 1, SENTINELS do
            want[i] = (i < SENTINELS) == (pass == 1)
            if want[i] then list[#list + 1] = view.sentinels[i] end
        end
        Probe.drawList = list
        Wait(0)
        local ok = false
        for _ = 1, 6 do
            project(view)
            local screen = {}
            for i = 1, SENTINELS do
                screen[#screen + 1] = view.sentinels[i][3]
                screen[#screen + 1] = view.sentinels[i][4]
            end
            local hits = TR.ui.probeFrame(screen)
            if hits then
                ok = true
                for i = 1, SENTINELS do
                    if (hits:sub(i, i) == '1') ~= want[i] then ok = false end
                end
                lastRead = ('%s for %s'):format(hits:sub(1, SENTINELS), pass == 1 and '11110' or '00001')
                if ok then break end
            end
            Wait(0)
        end
        if not ok then return false end
    end
    return true
end

---What the game says about the camera it draws from, for the log.
local function describeCamera(view)
    local parts = {}
    if GetFinalRenderedCamCoord then
        parts[#parts + 1] = ('drawn from %d mm off where it was put'):format(math.floor(#(GetFinalRenderedCamCoord() - view.from) * 1000 + 0.5))
    end
    if GetFinalRenderedCamFov then
        parts[#parts + 1] = ('a %.1f degree view (set to %.1f)'):format(GetFinalRenderedCamFov(), view.fov)
    end
    if GetFinalRenderedCamNearClip then
        parts[#parts + 1] = ('near clip %.2f m'):format(GetFinalRenderedCamNearClip())
    end
    return table.concat(parts, ', ')
end

---A look went unanswered: the corner markers didn't show as drawn, for longer than a late frame
---explains. Checks them again where they are, then tries the other places for them (PLACES), then
---all of them again with a new camera. What works is kept for this camera set-up, so it's looked
---for once a session, and said in the log with what the game said about its camera. False if they
---show nowhere.
function Probe.recover()
    local view = Probe.view
    if cornerReads(view) then return true end
    local first, read, camera = view.place, lastRead, describeCamera(view)
    local where = ('%s, %d cm from the camera'):format(first.name, math.floor(depthOf(view, first) * 100 + 0.5))

    for attempt = 1, 2 do
        if attempt == 2 then
            point(view, true)
            Wait(0)
            Wait(0)
            settle(view)
        end
        for _, place in ipairs(PLACES) do
            if attempt == 2 or place ~= first then
                placeSentinels(view, place)
                if cornerReads(view) then
                    placeFor[view.setup] = { place = place, fresh = attempt == 2 }
                    say(('the corner markers did not show %s (read %s; %s); they do %s, %d cm from the camera%s, so they go there now'):format(
                        where, read, camera, place.name, math.floor(depthOf(view, place) * 100 + 0.5), attempt == 2 and ', with a new camera each time' or ''))
                    return true
                end
            end
        end
    end
    placeSentinels(view, first)
    say(('the corner markers did not show %s (read %s; %s), nor anywhere else, with a new camera too'):format(where, read, camera))
    return false
end

---After a look of `total` markers: the game drew them all (ok) or not. `full`: the look was as
---big as allowed. Homes in on how many it draws.
local function drewAll(total, ok, full)
    if ok then
        drawn = math.max(drawn, total)
        if not full then return end -- a short look says nothing about more
        if not capped then
            perFrame = math.min(MAX_PER_FRAME, math.floor(perFrame * 1.5))
        elseif capped - drawn > 1 then
            perFrame = (drawn + capped) // 2
        else
            perFrame = drawn
            if not settled then say(('the game draws %d markers at a time'):format(perFrame)) end
            settled = true
        end
        return
    end
    Probe.stats.caps = Probe.stats.caps + 1
    settled = false
    -- Fewer than it drew before: something else draws markers too. Start the search again lower.
    if total <= drawn then drawn = math.floor(total * 0.8) end
    capped = math.min(capped or total, total)
    perFrame = math.max(12 + SENTINELS, drawn > 0 and (drawn + capped) // 2 or math.floor(total * 0.6))
    say(('the game drew fewer markers than asked; now %d at a time'):format(perFrame))
end

local probeCount = 0
local flying = {}  -- looks up whose frame hasn't been read, oldest first; kept from one measure to the next (the page can still show them)
local readAt       -- the frame the last read was asked in
local twice = 0    -- looks still to stay up two frames each (the page has been seeing every other frame)
local row = {}     -- for the last looks seen that were up one frame: whether the page saw the frame before

---Binary search along each sample's line of sight for where something hides the markers.
---Each sample needs: world (start of its line), dir (line of sight), lo, hi (search range along
---it) and sx, sy. Samples from several maps can go in at once.
---Afterwards s.mid is where the markers stopped showing, or s.hole / s.blocked is set; s.lo and
---s.hi are what the search narrowed them to.
---
---Each sample is read at s.hi first (still seen there: nothing is in the way, a gap or a hole),
---then at s.lo (hidden even there: something sticks out in front, a mirror), then `rounds` times
---halfway between. `inside`: the paint is expected between s.lo and s.hi (close looks), so the
---halves come first and an end is read only if the search never left it: same answers (a marker
---seen at a depth is seen at every depth in front of it), two reads fewer for most samples.
---
---Every frame a new look goes up while the ones before it are read (the corner markers say which
---look a frame shows), with each read whose last one is answered, fewest reads done first. Room
---left over goes to the read after one still being answered, as if the paint were where the line
---starts (the callers start them on the paint they expect): if it wasn't, that read is thrown
---away. So each sample reads the same depths in the same order as one look at a time would, just
---sooner. A look's frame the page missed (it saw a later one) is drawn again; if it only ever sees
---every other frame, looks stay up two frames each for a while. Up to DEPTH looks are unread at
---once, so the frame read is one of the last DEPTH + 1 looks, which never share their corner
---markers.
function Probe.measure(samples, rounds, inside)
    local size = Probe.markerSize()
    local stats, view = Probe.stats, Probe.view
    local started, startFrame = GetGameTimer(), GetFrameCount()
    local _, height = GetActiveScreenResolution()
    height = math.max(height, 480)
    local width = height * GetAspectRatio(false)
    local apart = 2.0 * size / view.pixel + 4.0 -- a marker's width in pixels and a margin
    local apart2 = apart * apart
    local last = rounds + 1                     -- reads: 0 at s.hi, 1 at s.lo, then the rounds
    local reach = view.reach                    -- a marker on the paint shows up to this far in

    -- Looks still up from before (the last measure's reads thrown away, or one stopped by Esc,
    -- Backspace or an error) say nothing now, but the page can still show them.
    for _, look in ipairs(flying) do look.dead = true end

    -- Per sample: its next read (0 at s.hi, 1 at s.lo, then the rounds, then inside an end), its
    -- place in the list, and its reads up and not answered, oldest first: { n, at, seen = the
    -- guess, lo, hi, over = the search would end there, dead = thrown away, look }.
    local step, order, chain = {}, {}, {}
    local ready = {}      -- samples with no read up, whose search isn't over
    local lo0, hi0 = {}, {} -- inside: where each search began
    for i, s in ipairs(samples) do
        local halves = inside and rounds > 0 and s.lo < s.hi
        step[s], order[s], chain[s], ready[i] = halves and 2 or 0, i, {}, s
        if halves then lo0[s], hi0[s] = s.lo, s.hi end
    end
    local left = #samples   -- searches not over
    local missed = {}       -- samples whose last read's frame went by unread
    local misses = 0        -- looks in a row that went unanswered
    local seenIn, lostIn = {}, {} -- frames with a look up only then: the page saw it, or it went by unread
    local shorts, shortest, gen = 0, nil, 0 -- reads that came back short since the last cap, the fewest markers asked of them

    ---inside: the end a search narrowed to lo..hi never left, or nil. Seen at every half: the paint
    ---is just inside s.hi, or there's a hole; hidden at every half: just past s.lo, or it's blocked.
    local function edge(s, lo, hi)
        if not hi0[s] then return end
        if hi == hi0[s] then return hi end
        if lo == lo0[s] then return lo end
    end

    ---The read after the ones up for `s` (each going as guessed), or nil if the search is over then.
    local function nextRead(s)
        local c = chain[s]
        local e = c[#c]
        local n, lo, hi = step[s], s.lo, s.hi
        if e then
            if e.over then return end
            n, lo, hi = e.n + 1, e.lo, e.hi
        end
        local at
        if n == 0 then at = s.hi elseif n == 1 then at = s.lo elseif n > last then at = edge(s, lo, hi) else at = (lo + hi) * 0.5 end
        local seen = at < reach
        local r = { n = n, at = at, seen = seen, lo = lo, hi = hi, over = n >= last }
        if n == 0 then
            r.over = r.over or seen
        elseif n == 1 then
            r.over = r.over or not seen
        elseif n <= last then
            if seen then r.lo = at else r.hi = at end
            if n == last and edge(s, r.lo, r.hi) then r.over = false end -- the end is read next
        end
        return r
    end

    local function waiting(a, b)
        if step[a] ~= step[b] then return step[a] < step[b] end
        return order[a] < order[b]
    end

    -- The next look: the reads waiting, fewest done first, then reads ahead in the room left, no
    -- two of its markers drawn close together (a seen marker next to a hidden one would show in
    -- its probe pixels and make it look seen too; samples on the same spot of the screen, from
    -- overlapping maps, go in different looks).
    local function putUp()
        local room = perFrame - MARKED
        local cells, reads = {}, {}
        local function fits(s)
            local x, y = s.sx * width, s.sy * height
            local cx, cy = math.floor(x / apart), math.floor(y / apart)
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local cell = cells[(cx + dx) * 65536 + cy + dy]
                    if cell then
                        for _, o in ipairs(cell) do
                            local ex, ey = o.sx * width - x, o.sy * height - y
                            if ex * ex + ey * ey < apart2 then return false end
                        end
                    end
                end
            end
            local key = cx * 65536 + cy
            cells[key] = cells[key] or {}
            cells[key][#cells[key] + 1] = s
            return true
        end

        table.sort(ready, waiting)
        local rest = {}
        for _, s in ipairs(ready) do
            if #reads < room and fits(s) then
                local r = nextRead(s)
                chain[s][1] = r
                reads[#reads + 1] = { s, r }
            else
                rest[#rest + 1] = s
            end
        end
        ready = rest
        if #reads < room then
            local ahead = {}
            for _, s in ipairs(samples) do
                local c = chain[s]
                local e = c[#c]
                if e and e.look and not e.over and #c < DEPTH then ahead[#ahead + 1] = s end
            end
            table.sort(ahead, function(a, b)
                if #chain[a] ~= #chain[b] then return #chain[a] < #chain[b] end
                return waiting(a, b)
            end)
            for _, s in ipairs(ahead) do
                if #reads >= room then break end
                if fits(s) then
                    local r = nextRead(s)
                    local c = chain[s]
                    c[#c + 1] = r
                    reads[#reads + 1] = { s, r }
                end
            end
        end
        if #reads == 0 then return end

        probeCount = probeCount + 1
        local code = CODES[probeCount % #CODES + 1]
        local list = {}
        for b = 1, SENTINELS - 1 do
            if (code >> (b - 1)) & 1 == 1 then list[#list + 1] = view.sentinels[b] end
        end
        for _, p in ipairs(reads) do
            local s = p[1]
            list[#list + 1] = { s.world + s.dir * p[2].at, size }
        end
        list[#list + 1] = view.sentinels[SENTINELS] -- last: if it shows, every marker was drawn
        Probe.drawList = list
        stats.looks = stats.looks + 1
        local look = { list = list, code = code, reads = reads, room = room, gen = gen, up = GetFrameCount() }
        look.span = twice > 0 and 2 or 1 -- frames it stays up at least (two while the page sees every other frame)
        twice = math.max(0, twice - 1)
        for _, p in ipairs(reads) do
            p[2].look = look
            -- Read again after its frame went by unread: this look stays up until its frame is read
            -- (else a frame missed now and then in step with the looks could miss it every time).
            if missed[p[1]] then look.hold = true end
        end
        flying[#flying + 1] = look
    end

    local function live(look)
        if look.dead then return false end
        for _, p in ipairs(look.reads) do
            if not p[2].dead then return true end
        end
        return false
    end

    -- A look whose frame won't be read: its reads again (the ones after them were guessed on them).
    -- `went`: its frame went by unread.
    local function back(look, went)
        if look.dead then return end
        for _, p in ipairs(look.reads) do
            local s, r = p[1], p[2]
            if not r.dead then
                for _, later in ipairs(chain[s]) do later.dead = true end
                chain[s] = {}
                ready[#ready + 1] = s
                if went then missed[s] = true end
            end
        end
    end

    -- What a look's frame says about each of its samples.
    local function answer(look, hits, from)
        for k, p in ipairs(look.reads) do
            local s, r = p[1], p[2]
            if not r.dead then
                local seen = hits:sub(from + k, from + k) == '1'
                local n = step[s]
                s.seen, missed[s] = seen, nil
                local over = false
                if n == 0 then
                    if seen then s.hole, over = true, true end
                elseif n == 1 then
                    if not seen then s.blocked, over = true, true end
                elseif n > last then
                    -- inside: the end the search never left. A hole or blocked keeps its whole range,
                    -- as when its end is read first.
                    if s.hi == hi0[s] then
                        if seen then s.hole, s.lo = true, lo0[s] end
                    elseif not seen then
                        s.blocked, s.hi = true, hi0[s]
                    end
                else
                    local mid = (s.lo + s.hi) * 0.5
                    if seen then s.lo = mid else s.hi = mid end
                end
                if not over and n >= last and not (n == last and edge(s, s.lo, s.hi)) then
                    over = true
                    if not s.hole and not s.blocked then s.mid = (s.lo + s.hi) * 0.5 end
                end
                step[s] = n + 1
                local c = chain[s]
                table.remove(c, 1)
                if over or seen ~= r.seen then
                    -- Over, or not as guessed: the reads after it went by the wrong depths.
                    for _, later in ipairs(c) do later.dead = true end
                    chain[s] = {}
                    if over then left = left - 1 else ready[#ready + 1] = s end
                elseif #c == 0 then
                    ready[#ready + 1] = s
                end
            end
        end
    end

    -- Reads the frame for the looks drawn before this frame (the page can't have the one drawn in
    -- it yet).
    local function read(now)
        project(view)
        local screen, from = {}, {}
        for b = 1, SENTINELS do
            screen[#screen + 1] = view.sentinels[b][3]
            screen[#screen + 1] = view.sentinels[b][4]
        end
        for _, look in ipairs(flying) do
            if look.list.drawn and look.list.drawn < now and live(look) then
                from[look] = #screen // 2
                for _, p in ipairs(look.reads) do
                    screen[#screen + 1] = p[1].sx
                    screen[#screen + 1] = p[1].sy
                end
            end
        end
        local hits = TR.ui.probeFrame(screen)
        if not hits then return end

        local code = 0
        for b = 1, SENTINELS - 1 do
            if hits:sub(b, b) == '1' then code = code | (1 << (b - 1)) end
        end
        local shown
        for i, look in ipairs(flying) do
            if look.code == code then shown = i break end
        end
        if not shown then
            stats.stale = stats.stale + 1 -- a frame from before them
            return
        end

        -- The ones before it went by unread: their reads again.
        for _ = 1, shown - 1 do
            local look = table.remove(flying, 1)
            if live(look) then
                stats.lost = stats.lost + 1
                if look.list.shown == 1 then lostIn[look.list.drawn] = true end
            end
            back(look, true)
        end
        local look = flying[1]
        if not from[look] then
            if not live(look) then table.remove(flying, 1) end
            return -- (or seen as soon as it was drawn: read again)
        end

        -- Up one frame only: the page saw that frame. Did it see the frame before too? If it never
        -- does (the look up then went by unread, ROW times running), it sees every other frame, and
        -- the next TWICE looks stay up two frames each.
        local list = look.list
        if list.shown == 1 and Probe.drawList ~= list then
            local d = list.drawn
            seenIn[d] = true
            if seenIn[d - 1] or lostIn[d - 1] then
                row[#row + 1] = seenIn[d - 1] == true
                if #row > ROW then table.remove(row, 1) end
                local any = false
                for _, saw in ipairs(row) do any = any or saw end
                if #row == ROW and not any then twice, row = TWICE, {} end
            end
        end

        local total = #look.list
        if hits:sub(SENTINELS, SENTINELS) == '1' then
            table.remove(flying, 1)
            misses = 0
            if shortest and total >= shortest then shorts, shortest = 0, nil end
            drewAll(total, true, #look.reads >= look.room)
            answer(look, hits, from[look])
        elseif #look.reads > 12 then
            -- The game drew fewer markers than asked (it's seen three times before it counts): the
            -- same reads again, fewer at a time once it counts.
            table.remove(flying, 1)
            back(look)
            if look.gen == gen then
                shorts, shortest = shorts + 1, math.min(shortest or total, total)
                if shorts >= 3 then
                    drewAll(shortest, false)
                    shorts, shortest, gen = 0, nil, gen + 1
                end
            end
        end
        -- (a short look of a few markers: the corner markers don't read right; it goes unanswered)
    end

    while left > 0 do
        if Probe.stopAsked then error('stopped', 0) end
        if Probe.skipAsked then error('skipped', 0) end

        -- Looks from before that the page has had READS frames to show are gone by now.
        local now = GetFrameCount()
        while flying[1] and flying[1].dead and now - flying[1].up > READS do table.remove(flying, 1) end

        -- The next look goes up once the one up now has been drawn as many frames as it stays up,
        -- or read if it's held.
        local top = flying[#flying]
        if #flying < DEPTH and (not top or (top.list.shown or 0) >= top.span and not top.hold) then putUp() end

        -- A frame read, once a frame, if it can show one of them; else the next frame.
        local drawnBefore = false
        for _, look in ipairs(flying) do
            if look.list.drawn and look.list.drawn < now then drawnBefore = true break end
        end
        if drawnBefore and readAt ~= now then
            readAt = now
            read(now)
        else
            Wait(0)
        end

        -- Now and then a frame isn't read in time (a hitch): the same reads again. If the corner
        -- markers don't show any more, recover() finds where they do.
        local oldest
        for _, look in ipairs(flying) do
            if live(look) then oldest = look break end
        end
        if oldest and GetFrameCount() - oldest.up > READS then
            for _, look in ipairs(flying) do back(look) end
            misses = misses + 1
            if not Probe.recover() then
                error('the markers can\'t be read from the game frame here (the corner markers show nowhere)', 0)
            end
            flying = {} -- the frames recover() read came after them all
            if misses > RETRIES then
                error('could not read the markers from the game frame (tr_core has to be up to date)', 0)
            end
        end
    end

    for _, look in ipairs(flying) do look.dead = true end
    stats.ms = stats.ms + GetGameTimer() - started
    stats.frames = stats.frames + GetFrameCount() - startFrame
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
---screen position. lo/hi: search range along the line, from the plane. start(s), if given: the
---vehicle x the line starts at instead (on a surface known roughly, the line meets it about where
---it was aimed; from a flat plane it's off by the line's slant times the depth).
function Probe.prepare(vehicle, samples, reference, lo, hi, start)
    local view = Probe.view
    local kept = {}
    for _, s in ipairs(samples) do
        local world = GetOffsetFromEntityInWorldCoords(vehicle, start and start(s) or reference.x, s.u, s.v)
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
