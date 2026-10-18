--[[
    Where the filler goes on a car's flank. /filler_autofit measures the flank (engine/client/probe.lua)
    and this picks the spot and says how the bezel sits on it. Pure maths, no natives; the tests are in
    tests/siphon.lua and tests/probe.lua.

    GTA's cars have no fuel door to find, so the filler goes on plain paint where a filler usually
    is. Without a petroltank bone, a wide map of the whole rear quarter (a DoorMap grid,
    minigames/lockpick/client/doormap.lua, samples about 5 cm apart, with the doors and the glass
    off) says where that is on this body: FillerMap.place. A lorry's bone is on its side tank, but
    can be at its end or inside it: a wide map along the tank says where its face is, and the
    filler goes in its middle (FillerMap.nearest, opts.middle). A coarse map round the place
    (samples a few centimetres apart) says where the paint is whole and smooth over the bezel's
    size. A close look at the best of those spots (a disc of samples a few millimetres apart) says
    what the bezel rests on.

    Flank space as in the probe: u along the car, v up, h out of the flank. A sample with h nil is
    missing: s.hole (nothing there: a gap, the wheel arch, glass) or s.blocked (something in the way).

        local place = FillerMap.place(wide, wheel)                       -- { u, v, h, target, archTop, panelTop, ... }
        local place = FillerMap.nearest(wide, bone, { middle = true })   -- { u, v, h, target, tank, ... }: on what the bone is on
        local spots = FillerMap.spots(coarse, anchor)                    -- best first: { u, v, distance, rough }
        local height = FillerMap.surface(coarse.samples, spot, 0.09)     -- the paint round a spot: height(u, v)
        local disc, new = FillerMap.disc(cache, anchor, spot, radius, step) -- the samples under the bezel; new: not measured yet
        local verdict = FillerMap.judge(disc, spot, radius)              -- { ok, seat, why, rimGap, rimOff, rimHoles, ... }
]]

FillerMap = {}

local TURN = math.atan(0.5) -- the disc's rows run at this angle: a seam along or up the car crosses each row somewhere else
local RIM = 0.012           -- the bezel's outer ring this wide: a gap shows only there, under the rest it's hidden
local RING_IN = 0.0015      -- a ring of samples this far in from the rim,
local RING_STEP = 0.0025    -- this far apart: a panel gap running out from under the bezel can't slip between them
local CLEAR = 0.008         -- the lattice inside the ring keeps this far from it, so its markers and the ring's can go in one look
local SEAM = 0.0012         -- under the rim, this far off the paint's own smooth curve is something else (a lip, a body line, a seam)
local ROOM_STEP = 0.01      -- with room round the bezel: a ring of samples that far out, this far apart (an opening, glass, a flare can't slip between)

-- FillerMap.place: what counts as the body's skin and where a filler usually is (what the hand fits show).
local SEED = 0.05           -- the skin grows from the outermost paint of columns this close to the flank's usual level
local LEAN = 0.8            -- to neighbours no deeper or prouder than this much of the spacing (under 40 degrees),
local CLIMB, BEND = 1.7, 0.012 -- or up to this much (60 degrees) where the surface goes on as it was going (within this)
local STEEP = 1.19          -- going up the panel, the skin leaning in more than this (50 degrees) ends it: over the shoulder
local GAP = 0.25            -- the wheel arch's top: the first skin this close over the tyre,
local LIFTED = 0.60         -- or this close on a lifted body (none that close), with a panel over it the filler fits on
-- Where the hand fits are (36 cars fitted by hand): over the back of the wheel arch, never in front
-- of 0.4 tyre radii behind the wheel's middle, some well behind the arch (SUVs, pickups); at a
-- steady height over the arch's top, lower on a short panel; never over the panel's top, never
-- facing the ground.
local BEHIND = 0.9          -- the filler's middle this many tyre radii behind the wheel's middle
local FORWARD = 0.4         -- and never less than this
local OVER_ARCH = 0.15      -- this far over the top of the wheel arch,
local UNDER_TOP = 0.085     -- but at least this far under the top of the panel
local AHEAD, BACK, UP = 0.12, 0.25, 0.035 -- moving it this far forward, back, or up or down costs the same (how far the hand fits are from there each way)

-- FillerMap.nearest: round a petroltank bone off the car's middle (a lorry's side tank).
local NEAR = 0.2            -- what the bone is on comes this close to it, along and up the flank,
local PAST_BONE = 0.15      -- and isn't further into the car than this past it (the frame, the cab through a door opening are)
local FLAT = 10.0           -- a millimetre off a plane under the bezel costs as much as a centimetre further from the bone
local ROWS = 0.07           -- opts.middle: the tank's ends, in the rows this close to the height of the place nearest the bone

local function median(list)
    if #list == 0 then return end
    table.sort(list)
    local n = #list
    if n % 2 == 1 then return list[(n + 1) // 2] end
    return (list[n // 2] + list[n // 2 + 1]) * 0.5
end

---How far the rim of a bezel of `radius` at c lifts off the paint where it curves away the most
---(the bezel rests on the middle of a bulge): from a quadratic through `samples`. nil if too few.
local function lift(samples, c, radius)
    if #samples < 10 then return end
    local coef = DoorMap.leastSquares(samples, function(u, v)
        local du, dv = u - c.u, v - c.v
        return { 1.0, du, dv, du * du, du * dv, dv * dv }
    end, function() return true end)
    if not coef then return end
    local p, q, r = coef[4], coef[5], coef[6]
    local most = p + r - math.sqrt((p - r) ^ 2 + q * q) -- the most convex way: h = most / 2 * t^2 along it
    return math.max(0.0, -most) * radius * radius * 0.5
end

---Grows a piece of skin over a wide map from `queue` (samples in it already: isIn(s)) to the samples
---next to it, as long as the surface carries on (see FillerMap.place; `steep`: also up a steep
---panel, where it goes on as it was going). add(s) puts a sample in it; skip(s) ones never go in.
local function grow(map, queue, isIn, add, skip, steep)
    local step, at = map.step, map.at
    local carry = math.max(0.02, step * LEAN)
    local function sample(i, j)
        local column = at[i]
        return column and column[j]
    end
    local function joins(s, n, di, dj)
        if not n or isIn(n) or not n.h or skip(n) then return false end
        local rise = math.abs(n.h - s.h)
        if rise <= carry then return true end
        if not steep or rise > step * CLIMB then return false end
        local behind = sample(s.i - di, s.j - dj)
        if behind and isIn(behind) and behind.h and math.abs(n.h - (2.0 * s.h - behind.h)) <= BEND then return true end
        local past = sample(n.i + di, n.j + dj)
        return past ~= nil and past.h ~= nil and not skip(past) and math.abs(past.h - 2.0 * n.h + s.h) <= BEND
    end
    local ways = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
    repeat
        local grew, head = false, 1
        while head <= #queue do
            local s = queue[head]
            head = head + 1
            for _, way in ipairs(ways) do
                local n = sample(s.i + way[1], s.j + way[2])
                if joins(s, n, way[1], way[2]) then
                    add(n)
                    grew = true
                    queue[#queue + 1] = n
                end
            end
        end
        -- Again from all of it: a sample in line with skin behind joins once that is skin, whichever
        -- way the growth got there.
        queue = {}
        if grew then
            for _, s in ipairs(map.samples) do
                if isIn(s) then queue[#queue + 1] = s end
            end
        end
    until not grew
end

---The best of `fitting` (sorted, best first), with the next best elsewhere (opts.apart from it and
---each other, opts.others of them) as best.others: a map this coarse can't see a tight curve or a
---body line, the close look can, and then the filler tries there.
local function withOthers(fitting, opts)
    local best = fitting[1]
    best.others = {}
    local apart = opts.apart or 0.12
    for _, c in ipairs(fitting) do
        if #best.others >= (opts.others or 2) then break end
        local alone = (c.u - best.u) ^ 2 + (c.v - best.v) ^ 2 >= apart * apart
        for _, o in ipairs(best.others) do
            if (c.u - o.u) ^ 2 + (c.v - o.v) ^ 2 < apart * apart then alone = false end
        end
        if alone then best.others[#best.others + 1] = c end
    end
    return best
end

---Where the filler goes on this body, from a wide map of the rear quarter (a DoorMap grid: s.i, s.j,
---s.gu, s.gv where aimed; s.u, s.v, s.h where measured; s.du, s.dv: how far its line of sight
---drifts along the flank per metre in, if it isn't square). The bezel and opts.room round it have
---to be on the body's skin, all one smooth surface (within opts.rough of a plane) and not tilted or
---turned more than the filler may be: not on the tyre, the wheel arch or its lip, a door or window
---opening or the cabin seen through it, a crease or over the shoulder, nor facing the ground more
---than opts.maxDown. Of those places the one nearest where a filler usually is: over the back of the
---wheel arch, 15 cm over it (8.5 cm or more under the panel's top, never over it); if not there,
---further back sooner than further forward, and never in front of 0.4 tyre radii behind the wheel's
---middle. Sets s.skin on the samples.
---@param map table the wide map, measured
---@param wheel { u: number, v: number, r: number } the rear wheel's middle and its tyre's radius
---@param opts? { bezel?: number, room?: number, rough?: number, maxTilt?: number, maxTurn?: number, maxDown?: number, rearmost?: number }
---@return table? place { u, v, h, plane, cost, fits, target = { u, v }, archTop, arch, panelTop }, or nil and why (arch: 'lifted' or 'guessed' if not the usual)
function FillerMap.place(map, wheel, opts)
    opts = opts or {}
    local step, at = map.step, map.at
    local columns = #at
    local clear = (opts.bezel or 0.053) + (opts.room or 0.02) -- from the bezel's middle to anything that isn't skin
    local rough = opts.rough or 0.007
    local maxTilt = math.tan(math.rad(opts.maxTilt or 45.0))
    local maxTurn = math.tan(math.rad(opts.maxTurn or 35.0))
    local maxDown = math.tan(math.rad(opts.maxDown or opts.maxTilt or 45.0))
    local tyreTop = wheel.v + wheel.r

    -- The skin: the body's outside, all one surface. It grows from the outermost paint in each
    -- column (from the wheel's upper half up: the sill and the bumper stick out on their own) to
    -- the samples next to it, as long as the surface carries on: the tyre, the wheel well, a door
    -- or window opening and the cabin are a step in from it, and the tail wraps round too steeply.
    -- On a steep panel (a supercar's quarter leaning in at 45 degrees) each row is more than that
    -- in from the last, so it also carries on where the surface goes on as it was going: in line
    -- with the skin behind, or with the sample past the next one.
    -- The tyre is never skin, however near the paint it is (or however far in the sill tucks).
    local function tyre(s)
        local u, v = s.h and s.u or s.gu, s.h and s.v or s.gv
        return (u - wheel.u) ^ 2 + (v - wheel.v) ^ 2 < (wheel.r + 0.01) ^ 2
    end
    local outer, all = {}, {}
    for i = 1, columns do
        for _, s in ipairs(at[i]) do
            s.skin = false
            if s.h and s.gv >= wheel.v + wheel.r * 0.5 and not tyre(s) and (not outer[i] or s.h > outer[i]) then outer[i] = s.h end
        end
        if outer[i] then all[#all + 1] = outer[i] end
    end
    local typical = median(all)
    if not typical then return nil, 'found no paint on the rear quarter' end
    local queue = {}
    for i = 1, columns do
        if outer[i] and outer[i] >= typical - SEED then
            for _, s in ipairs(at[i]) do
                if s.h and s.gv >= wheel.v + wheel.r * 0.5 and s.h >= outer[i] - 0.01 and not tyre(s) then
                    s.skin = true
                    queue[#queue + 1] = s
                end
            end
        end
    end
    grow(map, queue, function(s) return s.skin end, function(s) s.skin = true end, tyre, true)

    -- Where each sample is on the flank: a skin sample where it was measured, anything else where
    -- its line of sight crosses the skin's usual depth (seen at an angle, a door opening's far side
    -- is well off its edge).
    local function where(s)
        if s.skin then return s.u, s.v end
        local depth = -math.max(typical, s.h or typical)
        return s.gu + (s.du or 0.0) * depth, s.gv + (s.dv or 0.0) * depth
    end

    -- The top of the wheel arch: the first skin over the tyre in the columns by the wheel's middle
    -- (the gap over the tyre and the wheel well are deeper; the arch's lip is skin). On a lifted
    -- body the gap is far taller: if no column has skin within GAP over the tyre, the first skin
    -- within LIFTED, where most of them have it with a panel over it the filler fits on (a bed's
    -- side); else a guess.
    local tops, lifted, by = {}, {}, 0
    for i = 1, columns do
        local column = at[i]
        if math.abs(column[1].gu - wheel.u) <= wheel.r * 0.4 then
            by = by + 1
            for j, s in ipairs(column) do
                if s.gv > tyreTop and s.skin then
                    local below = column[j - 1]
                    local top = math.max(tyreTop, below and (s.gv + below.gv) * 0.5 or s.gv)
                    if s.gv <= tyreTop + GAP then
                        tops[#tops + 1] = top
                    elseif s.gv <= tyreTop + LIFTED then
                        local last = s
                        for k = j + 1, #column do
                            if not column[k].skin then break end
                            last = column[k]
                        end
                        if last.gv - s.gv + step >= 2.0 * clear then lifted[#lifted + 1] = top end
                    end
                    break
                end
            end
        end
    end
    local archTop, arch = median(tops), nil
    if not archTop and #lifted > 0 and #lifted * 2 >= by then archTop, arch = median(lifted), 'lifted' end
    if not archTop then archTop, arch = tyreTop + 0.06, 'guessed' end

    -- The top of the panel near where the filler's middle would be along the car: up from the arch's
    -- height as long as it's skin and doesn't lean in over 50 degrees (into a window opening, over
    -- the shoulder; measured where the samples are, not where they were aimed). Only columns where
    -- the panel is tall enough for the bezel and its room: over a door opening there's just the
    -- arch's lip.
    local targetU = wheel.u - BEHIND * wheel.r
    local panels = {}
    for i = 1, columns do
        local first, top
        for _, s in ipairs(at[i]) do
            if s.gv >= archTop - step * 0.5 then
                if not s.skin or (top and top.h - s.h > STEEP * math.max(0.001, s.v - top.v)) then break end
                first, top = first or s, s
            end
        end
        if top and top.gv - first.gv + step >= 2.0 * clear then panels[#panels + 1] = { u = top.gu, top = top.gv + step * 0.5 } end
    end
    table.sort(panels, function(a, b) return math.abs(a.u - targetU) < math.abs(b.u - targetU) end)
    local near = {}
    for k = 1, math.min(5, #panels) do near[k] = panels[k].top end
    local panelTop = median(near) or (archTop + 0.35)

    -- Every place the bezel and its room fit, a centimetre and a half apart, its middle no higher
    -- than the panel's top; the nearest to the target. Skin's edge is somewhere between a skin
    -- sample and the next one, so anything else has to be half a step further off as well.
    local need = clear + step * 0.5
    local target = { u = targetU, v = math.max(math.min(panelTop - UNDER_TOP, archTop + OVER_ARCH), archTop + need) }
    local u0, v0 = at[1][1].gu, at[1][1].gv
    local u1, v1 = at[columns][1].gu, at[1][#at[1]].gv
    local span = math.ceil((need + 0.05) / step) + 1 -- lines of sight seen at an angle land a few centimetres off their grid
    local fitting = {}
    for cu = math.max(u0 + need, opts.rearmost or -math.huge), math.min(u1 - need, wheel.u - wheel.r * FORWARD), 0.015 do
        for cv = tyreTop, math.min(v1 - need, panelTop), 0.015 do
            local ci, cj = math.floor((cu - u0) / step + 0.5) + 1, math.floor((cv - v0) / step + 0.5) + 1
            local under, whole = {}, true
            for i = math.max(1, ci - span), math.min(columns, ci + span) do
                local column = at[i]
                for j = math.max(1, cj - span), math.min(#column, cj + span) do
                    local s = column[j]
                    local su, sv = where(s)
                    if (su - cu) ^ 2 + (sv - cv) ^ 2 <= need * need then
                        if not s.skin then whole = false break end
                        under[#under + 1] = s
                    end
                end
                if not whole then break end
            end
            local plane = whole and #under >= 5 and DoorMap.fitPlane(under)
            -- (plane.c > 0: it leans out going up, facing the ground)
            if plane and plane.worst <= rough and -plane.c <= maxTilt and plane.c <= maxDown and math.abs(plane.b) <= maxTurn then
                fitting[#fitting + 1] = {
                    u = cu, v = cv, h = plane.a + plane.b * cu + plane.c * cv, plane = plane,
                    cost = ((cu - target.u) / (cu > target.u and AHEAD or BACK)) ^ 2 + ((cv - target.v) / UP) ^ 2 + plane.worst * 20.0,
                }
            end
        end
    end
    if #fitting == 0 then return nil, 'no plain panel on the rear quarter big enough for the filler' end
    table.sort(fitting, function(a, b) return a.cost < b.cost end)

    -- The best, and the next best elsewhere.
    local best = withOthers(fitting, opts)
    best.fits, best.target, best.archTop, best.arch, best.panelTop = #fitting, target, archTop, arch, panelTop
    return best
end

---The place nearest `anchor` (a petroltank bone off the car's middle: { u, v, h }, h out of the
---flank as the map's) on what the bone is on, where the bezel and opts.room round it fit on one
---smooth surface, from a wide map round it (as FillerMap.place takes). A lorry's bone is on its side
---tank, at its end or inside it; the tank is a curve (round, or flat faces) with straps and a step on
---it, and the frame, a battery box, a wheel and the cab are round it. So each surface with paint
---within NEAR of the bone (along and up the flank) and no more than PAST_BONE further into the car
---than it is grown, the one passing nearest the bone first, as the skin is but only where it
---carries on gently (up a steep part, an edge seen end on could join the tank to the cab). The
---filler fits where the bezel and its room are all on one, within opts.rough of a smooth curve (a
---quadratic: a round tank is no plane), not tilted or turned more than the filler may be and not
---facing the ground more than opts.maxDown. The place nearest the bone by way of its
---surface wins (from the bone to where that passes nearest it, and on to the place: a step on the
---tank is too small, the front tyre's wall further off), and a millimetre off a plane under the
---bezel costs as much as a centimetre further (FLAT). With opts.middle (a side tank: the hand fits
---are well along it from the bone, at its end), the place nearest the middle of that surface along
---the car at the height of the one nearest the bone (FillerMap.run) instead. Sets s.skin on that surface.
---@param map table the wide map, measured
---@param anchor { u: number, v: number, h: number }
---@param opts? { bezel?: number, room?: number, rough?: number, maxTilt?: number, maxTurn?: number, maxDown?: number, apart?: number, others?: number, middle?: boolean }
---@return table? place { u, v, h, cost, fits, away, target = { u, v }, tank, others }, or nil and why (away: how far the bone is from that surface; tank: FillerMap.run's, with opts.middle)
function FillerMap.nearest(map, anchor, opts)
    opts = opts or {}
    local step, at = map.step, map.at
    local columns = #at
    local clear = (opts.bezel or 0.053) + (opts.room or 0.02)
    local rough = opts.rough or 0.007
    local maxTilt = math.tan(math.rad(opts.maxTilt or 45.0))
    local maxTurn = math.tan(math.rad(opts.maxTurn or 35.0))
    local maxDown = math.tan(math.rad(opts.maxDown or opts.maxTilt or 45.0))

    -- What the bone may be on: paint near it, not well behind it. Nearest the bone first.
    local near = {}
    for _, s in ipairs(map.samples) do
        s.skin, s.piece = false, nil
        if s.h and s.h >= anchor.h - PAST_BONE and (s.u - anchor.u) ^ 2 + (s.v - anchor.v) ^ 2 <= NEAR * NEAR then
            s.away = math.sqrt((s.u - anchor.u) ^ 2 + (s.v - anchor.v) ^ 2 + (s.h - anchor.h) ^ 2)
            near[#near + 1] = s
        end
    end
    if #near == 0 then
        return nil, ('found no paint within %d cm of the bone (short of %d cm further into the car)'):format(math.floor(NEAR * 100 + 0.5), math.floor(PAST_BONE * 100 + 0.5))
    end
    table.sort(near, function(a, b) return a.away < b.away end)

    -- Each surface is grown from the nearest of them not on one yet: a step on the tank is one, its
    -- face another (the step stands out more than the skin carries on over).
    local pieces = {}
    for _, seed in ipairs(near) do
        if not seed.piece then
            local k = #pieces + 1
            local piece = { seed, away = seed.away }
            seed.piece = k
            grow(map, { seed }, function(s) return s.piece == k end, function(s)
                s.piece = k
                piece[#piece + 1] = s
            end, function(s) return s.piece ~= nil and s.piece ~= k end)
            pieces[k] = piece
        end
    end

    -- Every place the bezel and its room fit on one, a centimetre and a half apart. As in
    -- FillerMap.place, anything that isn't on it is where its line of sight crosses its usual depth.
    local need = clear + step * 0.5
    local span = math.ceil((need + 0.05) / step) + 1
    local u0, v0 = at[1][1].gu, at[1][1].gv
    local u1, v1 = at[columns][1].gu, at[1][#at[1]].gv
    local function quadratic(cu, cv)
        return function(u, v)
            local du, dv = u - cu, v - cv
            return { 1.0, du, dv, du * du, du * dv, dv * dv }
        end
    end
    local function places(k, piece)
        local fitting = {}
        local depths, lu, hu, lv, hv = {}, math.huge, -math.huge, math.huge, -math.huge
        for _, s in ipairs(piece) do
            depths[#depths + 1] = s.h
            lu, hu, lv, hv = math.min(lu, s.u), math.max(hu, s.u), math.min(lv, s.v), math.max(hv, s.v)
        end
        local typical = median(depths)
        local function where(s)
            if s.piece == k then return s.u, s.v end
            local depth = -math.max(typical, s.h or typical)
            return s.gu + (s.du or 0.0) * depth, s.gv + (s.dv or 0.0) * depth
        end
        for cu = math.max(u0, lu) + need, math.min(u1, hu) - need, 0.015 do
            for cv = math.max(v0, lv) + need, math.min(v1, hv) - need, 0.015 do
                local ci, cj = math.floor((cu - u0) / step + 0.5) + 1, math.floor((cv - v0) / step + 0.5) + 1
                local under, whole = {}, true
                for i = math.max(1, ci - span), math.min(columns, ci + span) do
                    local column = at[i]
                    for j = math.max(1, cj - span), math.min(#column, cj + span) do
                        local s = column[j]
                        local su, sv = where(s)
                        if (su - cu) ^ 2 + (sv - cv) ^ 2 <= need * need then
                            if s.piece ~= k then whole = false break end
                            under[#under + 1] = s
                        end
                    end
                    if not whole then break end
                end
                local terms = quadratic(cu, cv)
                local coef = whole and #under >= 10 and DoorMap.leastSquares(under, terms, function() return true end)
                if coef then
                    local worst, bezel = 0.0, {}
                    for _, s in ipairs(under) do
                        local t, h = terms(s.u, s.v), 0.0
                        for n = 1, 6 do h = h + coef[n] * t[n] end
                        worst = math.max(worst, math.abs(s.h - h))
                        if (s.u - cu) ^ 2 + (s.v - cv) ^ 2 <= (need - (opts.room or 0.02)) ^ 2 then bezel[#bezel + 1] = s end
                    end
                    -- Its slopes at the middle: along the car (turned), up it (leaning out going up: facing the ground).
                    local turn, lean = coef[2], coef[3]
                    -- How flat it is under the bezel itself: on a tank of flat faces, a face's middle beats the corner between two.
                    local plane = DoorMap.fitPlane(bezel)
                    if plane and worst <= rough and math.abs(turn) <= maxTurn and -lean <= maxTilt and lean <= maxDown then
                        fitting[#fitting + 1] = {
                            u = cu, v = cv, h = coef[1], worst = worst, flat = plane.worst,
                            cost = math.sqrt((cu - anchor.u) ^ 2 + (cv - anchor.v) ^ 2) + plane.worst * FLAT,
                        }
                    end
                end
            end
        end
        return fitting
    end

    -- The best place on each, and of those the one nearest the bone by way of its surface: from the
    -- bone to where that passes nearest it, and on to the place.
    local best, on
    for k, piece in ipairs(pieces) do
        local fitting = places(k, piece)
        if #fitting > 0 then
            table.sort(fitting, function(a, b) return a.cost < b.cost end)
            if not best or piece.away + fitting[1].cost < best.away + best.fitting[1].cost then
                best, on = { away = piece.away, fitting = fitting }, k
            end
        end
    end
    if not best then return nil, ('no smooth surface near the bone big enough for the filler (%d tried)'):format(#pieces) end
    local target, tank = { u = anchor.u, v = anchor.v }, nil
    if opts.middle then
        tank = FillerMap.run(map, on, best.fitting[1])
        if tank then
            -- On the tank's face, in its middle along the car, as high as the place nearest the bone.
            target = { u = tank.middle, v = best.fitting[1].v }
            for _, c in ipairs(best.fitting) do
                c.cost = math.sqrt((c.u - target.u) ^ 2 + (c.v - target.v) ^ 2) + c.flat * FLAT
            end
            table.sort(best.fitting, function(a, b) return a.cost < b.cost end)
        end
    end
    local place = withOthers(best.fitting, opts) -- the next best on the same surface
    for _, s in ipairs(map.samples) do s.skin = s.piece == on end
    place.fits, place.away, place.target, place.tank = #best.fitting, best.away, target, tank
    return place
end

---How far surface `k` of a wide map (s.piece, as FillerMap.nearest grows them) runs along the car
---round `at`: in each row within ROWS of its height, from its sample there nearest `at` (where it
---was measured: seen at an angle, a line of sight lands off its grid) each way until the surface
---ends (one sample off it doesn't end it: a strap, a bolt). The middle values: { lo, hi, middle,
---rows, openLo, openHi } (open: it ran to the map's end that way, and may go on), or nil if no row
---has it there.
function FillerMap.run(map, k, at)
    local step, cols = map.step, map.at
    local columns = #cols
    local function on(i, j) return i >= 1 and i <= columns and cols[i][j].piece == k end
    local los, his, openLo, openHi = {}, {}, 0, 0
    for j, s in ipairs(cols[1]) do
        local ci, nearest = nil, step * 1.5
        if math.abs(s.gv - at.v) <= ROWS then
            for i = 1, columns do
                local d = on(i, j) and math.abs(cols[i][j].u - at.u)
                if d and d < nearest then ci, nearest = i, d end
            end
        end
        if ci then
            local lo, hi = ci, ci
            while on(lo - 1, j) or on(lo - 2, j) do lo = on(lo - 1, j) and lo - 1 or lo - 2 end
            while on(hi + 1, j) or on(hi + 2, j) do hi = on(hi + 1, j) and hi + 1 or hi + 2 end
            los[#los + 1] = cols[lo][j].u - step * 0.5
            his[#his + 1] = cols[hi][j].u + step * 0.5
            if lo == 1 then openLo = openLo + 1 end
            if hi == columns then openHi = openHi + 1 end
        end
    end
    if #los == 0 then return end
    local rows = #los
    local lo, hi = median(los), median(his)
    return { lo = lo, hi = hi, middle = (lo + hi) * 0.5, rows = rows, openLo = openLo * 2 > rows, openHi = openHi * 2 > rows }
end

---Spots for the filler's middle within opts.halfU / halfV of `anchor`, best first. Every sample
---under the bezel (`radius`) and most of opts.room round it has paint, the paint under it is within
---`rough` of a plane and tilted / turned no more than the filler may be; the closer to the anchor
---and the flatter, the better, and worse for each sample a little further out without paint (an
---opening's edge may be closer than it) or off the bezel's plane (the arch's lip, a door's edge).
---With opts.uneven: none where the paint curves so much the bezel's rim would lift more than that
---off it (a fender's bulge). At most opts.count, none within opts.apart of a better one.
---@param map table a DoorMap grid, measured
---@param anchor { u: number, v: number }
---@param opts? { halfU?: number, halfV?: number, step?: number, radius?: number, room?: number, rough?: number, weight?: number, count?: number, apart?: number, maxTilt?: number, maxTurn?: number, uneven?: number }
---@return { u: number, v: number, distance: number, rough: number, plane: table }[]
function FillerMap.spots(map, anchor, opts)
    opts = opts or {}
    local halfU, halfV, step = opts.halfU or 0.07, opts.halfV or 0.045, opts.step or 0.01
    local radius, rough = opts.radius or 0.053, opts.rough or 0.006
    local count, apart = opts.count or 3, opts.apart or 0.025
    local maxTilt = math.tan(math.rad(opts.maxTilt or 45.0))
    local maxTurn = math.tan(math.rad(opts.maxTurn or 35.0))
    local reach = radius + map.step * 0.5 -- a sample this close stands for paint that may be under the rim
    local around = reach + (opts.room or 0.0)
    -- No opening this close: within the room for sure (a slanting line of sight may find glass or
    -- an opening a little past where it was aimed). Closer looks see the rest.
    local keep = math.max(radius, radius + (opts.room or 0.0) - map.step * 0.5)

    local found = {}
    local nu, nv = math.floor(halfU / step + 1e-6), math.floor(halfV / step + 1e-6)
    for i = -nu, nu do
        for j = -nv, nv do
            local c = { u = anchor.u + i * step, v = anchor.v + j * step }
            local under, ring, maybe, whole = {}, {}, 0, true
            for _, s in ipairs(map.samples) do
                local du, dv = s.u - c.u, s.v - c.v
                local d2 = du * du + dv * dv
                if not s.h and d2 <= keep * keep then
                    whole = false
                    break
                elseif d2 <= reach * reach then
                    if s.h then under[#under + 1] = s else maybe = maybe + 1 end
                elseif d2 <= around * around then
                    if s.h then ring[#ring + 1] = s else maybe = maybe + 1 end
                end
            end
            local plane = whole and #under >= 6 and DoorMap.fitPlane(under)
            local curved = plane and opts.uneven and (lift(under, c, radius) or 0.0) > opts.uneven
            if plane and not curved and plane.worst <= rough and math.abs(plane.c) <= maxTilt and math.abs(plane.b) <= maxTurn then
                for _, s in ipairs(ring) do
                    if math.abs(s.h - (plane.a + plane.b * s.u + plane.c * s.v)) > rough then maybe = maybe + 1 end
                end
                c.distance = math.sqrt((i * step) ^ 2 + (j * step) ^ 2)
                c.rough, c.plane = plane.worst, plane
                c.rank = c.distance + plane.worst * (opts.weight or 8.0) + maybe * 0.01
                found[#found + 1] = c
            end
        end
    end
    table.sort(found, function(a, b) return a.rank < b.rank end)

    local out = {}
    for _, c in ipairs(found) do
        local alone = true
        for _, o in ipairs(out) do
            if (o.u - c.u) ^ 2 + (o.v - c.v) ^ 2 < apart * apart then alone = false break end
        end
        if alone then
            out[#out + 1] = c
            if #out >= count then break end
        end
    end
    return out
end

---The paint round c: a quadratic through the measured samples within `radius` of it (a plane if
---there are only a few), refitted without what's far off it (a seam, a badge): further than
---`floor` (default 1.5 mm) and three times the typical. Returns height(u, v), or nil if too
---little was measured there.
function FillerMap.surface(samples, c, radius, floor)
    local near = {}
    for _, s in ipairs(samples) do
        if s.h and (s.u - c.u) ^ 2 + (s.v - c.v) ^ 2 <= radius * radius then near[#near + 1] = s end
    end
    local terms
    if #near >= 10 then
        terms = function(u, v)
            local du, dv = u - c.u, v - c.v
            return { 1.0, du, dv, du * du, du * dv, dv * dv }
        end
    elseif #near >= 5 then
        terms = function(u, v) return { 1.0, u - c.u, v - c.v } end
    else
        return
    end
    local function value(coef, u, v)
        local t, h = terms(u, v), 0.0
        for k = 1, #coef do h = h + coef[k] * t[k] end
        return h
    end

    local coef
    local keep = function() return true end
    for _ = 1, 3 do
        local fit = DoorMap.leastSquares(near, terms, keep)
        if not fit then break end
        coef = fit
        local res = {}
        for k, s in ipairs(near) do res[k] = math.abs(s.h - value(fit, s.u, s.v)) end
        table.sort(res)
        local limit = math.max(floor or 0.0015, 3.0 * res[(#res + 1) // 2])
        keep = function(s) return math.abs(s.h - value(fit, s.u, s.v)) <= limit end
    end
    if not coef then return end
    return function(u, v) return value(coef, u, v) end
end

---The samples under a bezel of `radius` at c: a close ring just inside the rim and inside it a
---lattice `step` apart, laid from `origin` (the same for every spot on a flank, so spots close
---together share samples; `cache` keeps them by their place on it). With `room`: a ring of samples
---that far round the rim too (s.room), where there has to be plain paint. Returns every sample, and
---the ones not measured yet. Each sample: { u, v, gu, gv } (gu, gv: where it was aimed; u, v move
---to the hit).
function FillerMap.disc(cache, origin, c, radius, step, room)
    local cu, su = math.cos(TURN), math.sin(TURN)
    local du, dv = c.u - origin.u, c.v - origin.v
    local a0, b0 = (du * cu + dv * su) / step, (dv * cu - du * su) / step
    local n = math.ceil(radius / step) + 1
    local all, new = {}, {}
    local r = radius - RING_IN
    local inner = r - CLEAR

    -- The ring first: the probe packs its markers into fewer looks that way. A multiple of 12
    -- samples, so every third or fourth one (one look's worth) comes round evenly.
    local count = 12 * math.ceil(2.0 * math.pi * r / RING_STEP / 12)
    for k = 1, count do
        local a = (k - 0.5) * 2.0 * math.pi / count
        local u, v = c.u + math.cos(a) * r, c.v + math.sin(a) * r
        local s = { u = u, v = v, gu = u, gv = v, ring = true }
        all[#all + 1] = s
        new[#new + 1] = s
    end
    if room and room > 0.0 then
        local out = radius + room
        local around = 12 * math.ceil(2.0 * math.pi * out / ROOM_STEP / 12)
        for k = 1, around do
            local a = (k - 0.5) * 2.0 * math.pi / around
            local u, v = c.u + math.cos(a) * out, c.v + math.sin(a) * out
            local s = { u = u, v = v, gu = u, gv = v, room = true }
            all[#all + 1] = s
            new[#new + 1] = s
        end
    end

    for a = math.floor(a0) - n, math.ceil(a0) + n do
        for b = math.floor(b0) - n, math.ceil(b0) + n do
            local u = origin.u + (a * cu - b * su) * step
            local v = origin.v + (a * su + b * cu) * step
            if (u - c.u) ^ 2 + (v - c.v) ^ 2 <= inner * inner then
                local key = a * 65536 + b
                local s = cache[key]
                if not s then
                    s = { u = u, v = v, gu = u, gv = v }
                    cache[key] = s
                    new[#new + 1] = s
                end
                all[#all + 1] = s
            end
        end
    end
    return all, new
end

---How a bezel of `radius` at c would sit on the measured disc (DoorMap.seat: resting on the
---paint's high points). Only its rim shows how it sits: it's ok when nothing stands out under it,
---and under its rim the paint is there (but for opts.holes, a share), plain (its own smooth curve)
---and nowhere more than opts.uneven from the rim; round it (the disc's room ring) there's paint.
---Under the rest of it, seams and dips are hidden. Otherwise `why` says what's wrong, and `bad`
---where ({ u, v, kind }): kind 'blocked' (something stands out), 'hole' (no paint under the rim or
---round it), 'line' (off the paint's own curve: a lip, a body line, a seam; inside the rim too,
---where it's hidden but runs on) or 'gap' (the rim lifts off a curve). score: lower is better, to
---pick the least bad when none is ok.
---@return { ok: boolean, seat: table?, why: string?, score: number, holes: number, rimHoles: number, rimOff: number, rimGap: number, blocked: integer, roomOut: number, bad: table[] }
function FillerMap.judge(disc, c, radius, opts)
    opts = opts or {}
    local uneven = opts.uneven or 0.003
    local present, holes, blocked, rim, rimHoles, bad = {}, 0, 0, 0, 0, {}
    local under, around, out = 0, 0, 0
    for _, s in ipairs(disc) do
        local d = math.sqrt((s.gu - c.u) ^ 2 + (s.gv - c.v) ^ 2)
        local onRim = not s.room and d >= radius - RIM
        if onRim then rim = rim + 1 end
        if s.room then
            -- Round the bezel: an opening, glass, a flare or a lip more than the search's window off the paint.
            around = around + 1
            if not s.h then
                out = out + 1
                bad[#bad + 1] = { u = s.gu, v = s.gv, kind = s.blocked and 'blocked' or 'hole' }
            end
        elseif s.h then
            under = under + 1
            present[#present + 1] = s
        elseif s.blocked then
            under = under + 1
            blocked = blocked + 1
            bad[#bad + 1] = { u = s.gu, v = s.gv, kind = 'blocked' }
        else
            under = under + 1
            holes = holes + 1
            if onRim then
                rimHoles = rimHoles + 1
                bad[#bad + 1] = { u = s.gu, v = s.gv, kind = 'hole' }
            end
        end
    end

    local seat = #present >= 6 and DoorMap.seat(present, c, radius) or nil
    local smooth = #present >= 10 and FillerMap.surface(present, c, radius, 0.0006)
    local rimGap, off, rimPresent = 0.0, 0, 0
    for _, s in ipairs(present) do
        if (s.gu - c.u) ^ 2 + (s.gv - c.v) ^ 2 < (radius - RIM) ^ 2 then
            -- Hidden under this bezel, but a line or a seam here runs on: the next spot's rim keeps off it.
            if smooth and math.abs(s.h - smooth(s.u, s.v)) > (opts.seam or SEAM) then bad[#bad + 1] = { u = s.u, v = s.v, kind = 'line' } end
        else
            rimPresent = rimPresent + 1
            local du, dv = s.u - c.u, s.v - c.v
            local wrong
            if seat and du * du + dv * dv <= radius * radius then
                local gap = seat.a + seat.b * du + seat.c * dv - s.h
                rimGap = math.max(rimGap, gap)
                if gap > uneven then wrong = 'gap' end
            end
            if smooth and math.abs(s.h - smooth(s.u, s.v)) > (opts.seam or SEAM) then
                off = off + 1
                wrong = 'line'
            end
            if wrong then bad[#bad + 1] = { u = s.u, v = s.v, kind = wrong } end
        end
    end

    local v = {
        seat = seat, blocked = blocked, rimGap = rimGap, bad = bad,
        holes = under > 0 and holes / under or 1.0,
        rimHoles = rim > 0 and rimHoles / rim or 1.0,
        rimOff = rimPresent > 0 and off / rimPresent or 0.0,
        roomOut = around > 0 and out / around or 0.0,
    }
    if under == 0 then
        v.why = 'nothing measured there'
    elseif blocked > 0 then
        v.why = ('something stands out under the bezel (%d point%s)'):format(blocked, blocked == 1 and '' or 's')
    elseif v.rimHoles > (opts.holes or 0.02) then
        v.why = ('no paint under %d%% of the bezel\'s rim'):format(math.floor(v.rimHoles * 100 + 0.5))
    elseif out > 0 then
        v.why = ('no plain paint round %d%% of the bezel (an opening, glass, a flare or a lip close to it)'):format(math.max(1, math.floor(v.roomOut * 100 + 0.5)))
    elseif v.holes > 0.4 or not seat then
        v.why = ('no paint under %d%% of the bezel'):format(math.floor(v.holes * 100 + 0.5))
    elseif v.rimOff > (opts.off or 0.01) then
        v.why = ('a lip, a body line or a seam under %d%% of the bezel\'s rim'):format(math.floor(v.rimOff * 100 + 0.5))
    elseif rimGap > uneven then
        v.why = ('a gap of up to %.1f mm under the bezel\'s rim'):format(rimGap * 1000)
    end
    v.ok = v.why == nil
    v.score = blocked * 0.01 + v.rimHoles * 0.1 + v.roomOut * 0.05 + v.rimOff * 0.05 + (seat and rimGap or 0.05)
    return v
end
