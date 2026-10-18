--[[
    The siphon's props.

        local props = SiphonProps.new(vehicle, place)
        props:setCan(pos, heading)     -- the can is down: its body, cap and strap; the hoses and funnel beside it
        props:update(dt)               -- every frame: steps the hoses, moves and draws everything
        props:mirrorState(set)         -- what players nearby need to draw it (SiphonProps.view)
        props:destroy()

    Filler space (rig.lua) is fixed to the car at the filler (props.scene): the bezel, flap, fuel cap
    and its strap. The can stands where the player put it; can space is its bottom middle, +X along
    the handle to the neck. The siphon and blow hoses are ropes (TR.rope) in world
    space, drawn as clear pieces stretched between their nodes, with the fuel inside the siphon hose.
    The game sets plain state on the props (caps, funnel, fuel, streams); update() draws it.
]]

SiphonProps = {}
SiphonProps.__index = SiphonProps

local RIG = Siphon.rig
local HOSE, FILLER, CAN, FUNNEL = RIG.hose, RIG.filler, RIG.can, RIG.funnel
local UP = vec3(0.0, 0.0, 1.0)
local IDENTITY = Mat.identity()

local SIPHON_NODE, BLOW_NODE = 0.05, 0.04  -- metres between the hoses' simulated nodes
local NECK_LIP = 0.035                     -- metres the siphon hose stands straight up out of the can's neck
local STRAP_PIECES = 6
local STREAM_PIECES = 8                    -- per stream of spilling fuel
local DROPS = 4
local CAP_SWING_DAMPING = 3.0              -- the fuel cap swinging on its strap settles in a second or so
-- The funnel in the can is turned so its wire hanger (funnel space -X) points off the can's side, not
-- over the handle.
local FUNNEL_TURN = Mat.axis('z', 90.0)
local FUNNEL_WALL = 0.003                  -- metres from its inside to its outside (the wall, and some room)
local BEND_SPEED = 300.0                   -- degrees a second the spout bends straight (or back)
local LAY_OUT = { 0.1, 0.45 }              -- metres out from the can the siphon hose's end is laid (by its slack)
local LAY_TURNS = { 0.0, 35.0, -35.0, 70.0, -70.0 } -- degrees off straight out tried when that spot is taken
local LAY_CLEAR = 0.1                      -- metres over the can (and the funnel in it) the end is carried
local SLIDE_STEP = 0.0008                  -- metres a collider pass moves hose resting on the can towards slideOff
SiphonProps.SPOUT = FUNNEL.spout.piece * FUNNEL.spout.pieces + FUNNEL.nozzle -- metres the spout reaches below its seat
SiphonProps.FUNNEL_HOLDS = FUNNEL.levels[#FUNNEL.levels][1]                  -- litres up to its rim
local RIM_ABOVE_NECK = FUNNEL.seat.z + FUNNEL.rim.top - CAN.neckPath[1].z     -- metres from its rim down to the neck's top
-- The siphon hose in the funnel is held from outside its rim, over it and down (else the free hose next
-- to the rim sags back into the bowl and its links cut through the rim): out from the rim's middle, up.
local OVER_RIM = { { FUNNEL.rim.radius + 0.06, 0.005 }, { FUNNEL.rim.radius + 0.015, 0.03 } }

local MODELS = {
    'tr_sf_filler', 'tr_sf_flap', 'tr_sf_fuelcap', 'tr_sf_can', 'tr_sf_canbody', 'tr_sf_cancap',
    'tr_sf_siphonseg', 'tr_sf_blowseg', 'tr_sf_sfend', 'tr_sf_bfend', 'tr_sf_strapseg', 'tr_sf_fuelseg', 'tr_sf_fuelfront',
    'tr_sf_funnel', 'tr_sf_bellows', 'tr_sf_nozzle', 'tr_sf_funnelpool',
}

---The funnel's bowl: its inside radius at height z (funnel space), from rig.lua's fill levels.
local function bowlRadius(z)
    local levels = FUNNEL.levels
    if z <= levels[1][2] then return levels[1][3] end
    for i = 2, #levels do
        local a, b = levels[i - 1], levels[i]
        if z <= b[2] then return Lerp(a[3], b[3], (z - a[2]) / math.max(1e-9, b[2] - a[2])) end
    end
    return levels[#levels][3]
end

-- Local objects ------------------------------------------------------------------------------

local shown = {} -- entity -> visible, so nothing is set twice
local placed = {} -- entity -> the matrix it was last given, so a still object costs no native

local function show(entity, visible)
    if shown[entity] == visible then return end
    shown[entity] = visible
    SetEntityVisible(entity, visible, false)
end

local function setMatrix(entity, fx, fy, fz, rx, ry, rz, ux, uy, uz, x, y, z)
    local m = placed[entity]
    if m then
        if m[1] == fx and m[2] == fy and m[3] == fz and m[4] == rx and m[5] == ry and m[6] == rz
            and m[7] == ux and m[8] == uy and m[9] == uz and m[10] == x and m[11] == y and m[12] == z then
            return
        end
        m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12] = fx, fy, fz, rx, ry, rz, ux, uy, uz, x, y, z
    else
        placed[entity] = { fx, fy, fz, rx, ry, rz, ux, uy, uz, x, y, z }
    end
    SetEntityMatrix(entity, fx, fy, fz, rx, ry, rz, ux, uy, uz, x, y, z)
end

local function spawn(model, at)
    local entity = CreateObjectNoOffset(joaat(model), at.x, at.y, at.z, false, false, false)
    SetEntityCollision(entity, false, false)
    FreezeEntityPosition(entity, true)
    SetEntityInvincible(entity, true)
    SetEntityLodDist(entity, 60)
    shown[entity] = true
    show(entity, false)
    return entity
end

local function delete(entity)
    shown[entity], placed[entity] = nil, nil
    if DoesEntityExist(entity) then DeleteEntity(entity) end
end

---Puts an object at pos, turned by rot (a Mat), and shows it.
local function put(entity, pos, rot)
    setMatrix(entity, rot.y.x, rot.y.y, rot.y.z, rot.x.x, rot.x.y, rot.x.z, rot.z.x, rot.z.y, rot.z.z, pos.x, pos.y, pos.z)
    show(entity, true)
end

---Stretches a 1 m piece (modelled along +Y from its origin) from a to b. `face`: the way its flat
---side faces (straps), else it keeps its X level.
local function stretch(entity, a, b, face)
    local d = b - a
    local len = #d
    if len < 0.0005 then return show(entity, false) end
    local y = d / len
    local x = Vec.cross(y, face or UP)
    if #x < 0.001 then x = Vec.cross(y, vec3(1.0, 0.0, 0.0)) end
    x = Vec.normalize(x)
    local z = Vec.cross(x, y)
    setMatrix(entity, d.x, d.y, d.z, x.x, x.y, x.z, z.x, z.y, z.z, a.x, a.y, a.z)
    show(entity, true)
end

---Puts a piece `unit` metres long (modelled along +Y from its origin) from a to b, stretched to fit.
local function span(entity, a, b, unit)
    local d = b - a
    local len = #d
    if len < 0.0005 then return show(entity, false) end
    local x = Vec.cross(d / len, UP)
    if #x < 0.001 then x = vec3(1.0, 0.0, 0.0) end
    x = Vec.normalize(x)
    local z = Vec.cross(x, d / len)
    local y = d / unit
    setMatrix(entity, y.x, y.y, y.z, x.x, x.y, x.z, z.x, z.y, z.z, a.x, a.y, a.z)
    show(entity, true)
end

---stretch() without a face, in numbers (no vectors made): the hoses' pieces, many a frame.
local function stretchXYZ(entity, ax, ay, az, bx, by, bz)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 0.0005 then return show(entity, false) end
    local yx, yy, yz = dx / len, dy / len, dz / len
    local xx, xy, xz = yy, -yx, 0.0 -- y x up
    local xl = math.sqrt(xx * xx + xy * xy)
    if xl < 0.001 then
        xx, xy, xz = 0.0, yz, -yy -- y x (1, 0, 0)
        xl = math.sqrt(xy * xy + xz * xz)
    end
    xx, xy, xz = xx / xl, xy / xl, xz / xl
    setMatrix(entity, dx, dy, dz, xx, xy, xz, xy * yz - xz * yy, xz * yx - xx * yz, xx * yy - xy * yx, ax, ay, az)
    show(entity, true)
end

---A polyline drawn with pieces (hidden past its end).
local function drawLine(pieces, points, face)
    for i, piece in ipairs(pieces) do
        if points and points[i + 1] then stretch(piece, points[i], points[i + 1], face) else show(piece, false) end
    end
end

---A strap `length` long from a to b: a curve whose middle is pushed along `sag` until it is as long
---as the strap (straight when pulled taut).
local function strapPoints(a, b, length, sag, n)
    local function curve(h)
        local c = (a + b) * 0.5 + sag * h
        local points = {}
        for k = 0, n do
            local t = k / n
            local u = 1.0 - t
            points[k + 1] = a * (u * u) + c * (2.0 * u * t) + b * (t * t)
        end
        return points
    end
    local function long(points)
        local total = 0.0
        for k = 2, #points do total = total + #(points[k] - points[k - 1]) end
        return total
    end

    if #(b - a) >= length then return curve(0.0) end
    local lo, hi, points = 0.0, length, nil
    for _ = 1, 12 do
        local h = (lo + hi) / 2
        points = curve(h)
        if long(points) > length then hi = h else lo = h end
    end
    return points
end

-- A hose ---------------------------------------------------------------------------------------

local HoseView = {}
HoseView.__index = HoseView

-- The hose is drawn along a smooth curve through its simulated nodes, in pieces this many times
-- shorter than the nodes are apart: a bend reads as a curve, not as a few straight sticks.
HoseView.SUB = 3
local REDRAW = 0.0003 -- metres a node moves before the pieces round it are drawn again

function HoseView.new(rope, segment, ring, at)
    local self = setmetatable({ rope = rope, pieces = {}, ends = {}, drawn = {}, dirty = {} }, HoseView)
    for i = 1, (rope.count - 1) * HoseView.SUB do self.pieces[i] = spawn(segment, at) end
    self.ends[1], self.ends[2] = spawn(ring, at), spawn(ring, at)
    return self
end

---The point `s` metres along the hose from end 1, on a smooth curve (Catmull-Rom) through its nodes,
---as x, y, z (no vectors made: the pieces are drawn with these, many a frame).
function HoseView:xyz(s)
    local p, n = self.rope.p, self.rope.count
    local f = math.max(0.0, math.min(s / self.rope.seg, n - 1))
    local i = math.min(math.floor(f), n - 2) -- between node i + 1 and node i + 2
    local t = f - i
    local p0, p1, p2, p3 = p[math.max(1, i)], p[i + 1], p[i + 2], p[math.min(n, i + 3)]
    local t2 = t * t
    local t3 = t2 * t
    local w0, w1 = (2.0 * t2 - t - t3) * 0.5, (2.0 - 5.0 * t2 + 3.0 * t3) * 0.5
    local w2, w3 = (t + 4.0 * t2 - 3.0 * t3) * 0.5, (t3 - t2) * 0.5
    return p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3,
        p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3,
        p0.z * w0 + p1.z * w1 + p2.z * w2 + p3.z * w3
end

---The same point as a vector.
function HoseView:at(s) return vec3(self:xyz(s)) end

---Stretches `piece` along the curve from s0 to s1 metres. Where the piece before ended at s0, its end
---point is used again, not worked out twice.
function HoseView:piece(piece, s0, s1)
    local ax, ay, az
    if self.lastS == s0 then ax, ay, az = self.lastX, self.lastY, self.lastZ else ax, ay, az = self:xyz(s0) end
    local bx, by, bz = self:xyz(s1)
    self.lastS, self.lastX, self.lastY, self.lastZ = s1, bx, by, bz
    stretchXYZ(piece, ax, ay, az, bx, by, bz)
end

---Does piece k (of the hose or the fuel in it) need drawing again: did a node its curve runs through move?
function HoseView:stale(k)
    local dirty, n = self.dirty, self.rope.count
    local j = (k - 1) // HoseView.SUB -- the curve through nodes j .. j + 3
    return dirty[math.max(1, j)] or dirty[j + 1] or dirty[j + 2] or dirty[math.min(n, j + 3)]
end

---Does piece k (from s0 to s1 metres along) reach into the span between metres a and b (either way round)?
local function across(k, per, a, b)
    return a ~= b and k * per >= math.min(a, b) and (k - 1) * per <= math.max(a, b)
end

---hidden: metres from end 1 not drawn (down inside the car, where the body may not hide it).
---Only what changed is drawn again: the pieces round nodes that moved more than REDRAW since they were
---drawn, and those the hidden length moved across.
function HoseView:draw(visible, hidden)
    local rope = self.rope
    hidden = hidden or 0.0
    local all = self.drawnVisible ~= visible
    local was = self.drawnHidden or hidden
    self.drawnVisible, self.drawnHidden, self.moved, self.all = visible, hidden, false, false
    -- Asleep, the hose doesn't move: drawn once, it stays as it is.
    if rope.asleep and self.drawnAsleep and not all and was == hidden then return end
    self.drawnAsleep = rope.asleep == true

    local p, n, drawn, dirty = rope.p, rope.count, self.drawn, self.dirty
    local any = all or was ~= hidden
    for i = 1, n do
        local moved = all or not drawn[i] or #(p[i] - drawn[i]) > REDRAW
        dirty[i] = moved
        if moved then drawn[i], any = p[i], true end
    end
    if not any then return end
    self.moved, self.all = true, all

    local per = rope.seg / HoseView.SUB
    self.lastS = nil
    for k, piece in ipairs(self.pieces) do
        if all or self:stale(k) or across(k, per, was, hidden) then
            local s1 = k * per
            if not visible or s1 <= hidden then
                show(piece, false)
            else
                self:piece(piece, math.max((k - 1) * per, hidden), s1)
            end
        end
    end
    for e, ring in ipairs(self.ends) do
        if visible and not (e == 1 and hidden > 0) then
            local i, j = e == 1 and 1 or n, e == 1 and 2 or n - 1
            if all or dirty[i] or dirty[j] or (e == 1 and was > 0) then put(ring, p[i], Mat.along(p[i] - p[j])) end
        else
            show(ring, false)
        end
    end
end

---Fuel inside the hose from `from` to `to` metres along it (from end 1), with a rounded front. Call it
---after draw() the same frame: only what changed (the hose round it, or its ends) is drawn again.
function HoseView:fuel(pieces, front, from, to, hidden)
    local rope = self.rope
    from = math.max(from, hidden or 0.0)
    local wasFrom, wasTo = self.fuelFrom, self.fuelTo
    if wasFrom == from and wasTo == to and not self.moved then return end
    self.fuelFrom, self.fuelTo = from, to
    local all = self.all or not wasFrom

    local per = rope.seg / HoseView.SUB
    self.lastS = nil
    for i, piece in ipairs(pieces) do
        if all or across(i, per, wasFrom, from) or across(i, per, wasTo, to) or (self.moved and self:stale(i)) then
            local s0, s1 = math.max((i - 1) * per, from), math.min(i * per, to)
            if s1 - s0 > 0.001 then self:piece(piece, s0, s1) else show(piece, false) end
        end
    end
    if to - from > 0.001 and to < rope.length - 0.001 then put(front, self:at(to), IDENTITY) else show(front, false) end
end

function HoseView:destroy()
    for _, entity in ipairs(self.pieces) do delete(entity) end
    for _, entity in ipairs(self.ends) do delete(entity) end
end
SiphonProps.HoseView = HoseView

-- Setup -----------------------------------------------------------------------------------------

---@param vehicle integer
---@param place table Siphon.placement
function SiphonProps.new(vehicle, place)
    local self = setmetatable({
        vehicle = vehicle,
        place = place,
        kitShown = false,
        flap = 0.0,                                                    -- degrees the flap is pushed in
        fuelCap = { turn = 0.0, out = 0.0 },                           -- see fuelCapPose
        canCap = { turn = 0.0, out = 0.0 },                            -- see canCapPose
        -- where: 'ground' / 'held' (at pos, turned rot) or 'can' (lift: metres up out of its seat).
        -- bend: degrees its spout is bent; level: litres of fuel standing in it.
        funnel = { where = 'ground', bend = FUNNEL.spout.rest, shownBend = FUNNEL.spout.rest, level = 0.0, lift = 0.0 },
        fuel = { from = 0.0, to = 0.0 },                               -- along the siphon hose from its tip
        streams = {},
        drops = {},
    }, SiphonProps)

    self.scene = Scene.new(vehicle, Siphon.frame(vehicle, place))
    self.scene:preload(MODELS)
    self.scene:spawn('filler', 'tr_sf_filler')
    self.scene:spawn('flap', 'tr_sf_flap', FILLER.flapHinge)
    self.scene:spawn('fuelcap', 'tr_sf_fuelcap', FILLER.cap.seat, FILLER.cap.rot)

    local at = GetEntityCoords(PlayerPedId())
    self.fuelStrap, self.canStrap, self.fuelPieces, self.streamPieces, self.dropEntities = {}, {}, {}, {}, {}
    for i = 1, STRAP_PIECES do
        self.fuelStrap[i] = spawn('tr_sf_strapseg', at)
        self.canStrap[i] = spawn('tr_sf_strapseg', at)
    end

    -- follow: the cheap solver (about a sixth of the work; tr_core's rope, followSolve).
    self.siphon = Rope.new(HOSE.siphonLength, SIPHON_NODE, { radius = HOSE.siphonRadius, bend = 0.25, follow = true, damping = 0.06 })
    self.blow = Rope.new(HOSE.blowLength, BLOW_NODE, { radius = HOSE.blowRadius, bend = 0.3, follow = true, damping = 0.06 })
    self.siphonView = HoseView.new(self.siphon, 'tr_sf_siphonseg', 'tr_sf_sfend', at)
    self.blowView = HoseView.new(self.blow, 'tr_sf_blowseg', 'tr_sf_bfend', at)
    for i = 1, (self.siphon.count - 1) * HoseView.SUB do self.fuelPieces[i] = spawn('tr_sf_fuelseg', at) end
    self.fuelFront = spawn('tr_sf_fuelfront', at)
    for i = 1, STREAM_PIECES * 2 do self.streamPieces[i] = spawn('tr_sf_fuelseg', at) end
    for i = 1, DROPS do self.dropEntities[i] = spawn('tr_sf_fuelfront', at) end
    self.funnelEntity, self.nozzleEntity = spawn('tr_sf_funnel', at), spawn('tr_sf_nozzle', at)
    self.poolEntity = spawn('tr_sf_funnelpool', at)
    self.spoutEntities = {}
    for i = 1, FUNNEL.spout.pieces do self.spoutEntities[i] = spawn('tr_sf_bellows', at) end
    self.carried = spawn('tr_sf_can', at)

    -- The hoses' ends go down channels: the filler neck (filler space, moves with the car) and the can's neck.
    self.siphonIn = function(s) return self.siphonPath(s) end
    self.siphonGuide = function(s) return self.guidePath(s) end
    self.blowIn = function(s) return self.blowPath(s) end
    self:updateChannels()

    local min, max = GetModelDimensions(GetEntityModel(vehicle))
    self.carMin, self.carMax = min, max
    self:startProfile()
    return self
end

function SiphonProps:updateChannels()
    local scene = self.scene
    local s, b = {}, {}
    for i, p in ipairs(FILLER.siphonPath) do s[i] = scene:toWorld(p) end
    for i, p in ipairs(FILLER.blowPath) do b[i] = scene:toWorld(p) end
    self.siphonPath, self.siphonDepth = Rope.path(s)
    self.blowPath, self.blowDepth = Rope.path(b)
    -- While it is fed the hand holds the hose straight out of the mouth along the neck, so it goes in
    -- the way the neck runs instead of hanging down from the mouth.
    local out = Vec.normalize(s[1] - s[2])
    table.insert(s, 1, s[1] + out * SiphonProps.GUIDE)
    self.guidePath = Rope.path(s)
end

---How much of a hose (metres from end 1) is down inside the filler past its mouth: not drawn, since the
---neck runs inside the car and the body doesn't hide it everywhere (by the wheel arch).
local INSIDE_SHOWN = 0.02 -- metres just past the mouth that still show (the paint covers the rest)
function SiphonProps:inside(rope)
    local e = rope.ends[1]
    if not e then return 0.0 end
    local outside = e.at == self.siphonGuide and SiphonProps.GUIDE or 0.0
    return math.max(0.0, e.fed - outside - INSIDE_SHOWN)
end

SiphonProps.GUIDE = 0.16 -- metres of hose the hand holds straight outside the filler while feeding

-- Spaces ----------------------------------------------------------------------------------------

function SiphonProps:filler(p) return self.scene:toWorld(p) end
function SiphonProps:toFiller(w) return Vec.unrotate(self.scene.rot, w - self.scene.pos) end
function SiphonProps:fillerDir(d) return Mat.apply(self.scene.rot, d) end
function SiphonProps:can(p) return self.canPos + Mat.apply(self.canRot, p) end
function SiphonProps:canDir(d) return Mat.apply(self.canRot, d) end

---The filler's mouth, where the hoses go in (world).
function SiphonProps:mouth() return self:filler(FILLER.siphonPath[1]) end
---The top of the can's open neck (world).
function SiphonProps:neckTop() return self:can(CAN.neckPath[1]) end

---Where the siphon hose goes into the can (world): the middle of the funnel's rim when the funnel is
---in, else the top of the neck.
function SiphonProps:canTarget()
    if self.funnel.where == 'can' then return self:can(FUNNEL.seat + vec3(0.0, 0.0, FUNNEL.rim.top)) end
    return self:neckTop()
end

---How far the hose goes down from canTarget() to the top of the neck (through the funnel).
function SiphonProps:aboveNeck()
    return self.funnel.where == 'can' and RIM_ABOVE_NECK or 0.0
end

---Where the hose is held over the funnel's rim before it goes down (world; none without the funnel), on
---the side the hose comes from: worked out when it goes in and kept till it is out.
function SiphonProps:overRim(top)
    if self.funnel.where ~= 'can' then return {} end
    local rope = self.siphon
    if not rope.ends[2] or not self.rimSide then
        local from = rope.p[math.max(1, rope.count - 5)] - top
        local side = vec3(from.x, from.y, 0.0)
        if #side < 0.01 then side = vec3(self:mouth().x - top.x, self:mouth().y - top.y, 0.0) end
        self.rimSide = #side > 1e-4 and side / #side or vec3(1.0, 0.0, 0.0)
    end
    local points = {}
    for k, o in ipairs(OVER_RIM) do points[k] = top + self.rimSide * o[1] + vec3(0.0, 0.0, o[2]) end
    return points
end

---The siphon hose's end `depth` metres down the can's neck (through the funnel when it is in). It comes
---up out of it a little before it bends over the rim (not through the side).
function SiphonProps:intoCan(depth)
    local top = self:canTarget()
    local guide = self:overRim(top)
    for _, p in ipairs({ top + vec3(0.0, 0.0, NECK_LIP), top, self:neckTop(), self:can(CAN.neckPath[2]) }) do
        guide[#guide + 1] = p
    end
    self.siphon:feed(2, Rope.path(guide), depth + self:overRimLength() + NECK_LIP + self:aboveNeck())
end

---How far the siphon hose's end is down the can's neck (0 when it isn't in).
function SiphonProps:canDepth()
    local e = self.siphon.ends[2]
    return e and math.max(0.0, e.fed - self:overRimLength() - NECK_LIP - self:aboveNeck()) or 0.0
end

---Metres of hose held over the funnel's rim before it goes down (as intoCan holds it).
function SiphonProps:overRimLength()
    if self.funnel.where ~= 'can' then return 0.0 end
    local a, b = OVER_RIM[1], OVER_RIM[2]
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) + math.sqrt(b[1] ^ 2 + (NECK_LIP - b[2]) ^ 2)
end

---Is a world point inside the car's box (grown by margin)?
function SiphonProps:insideCar(p, margin)
    local o = GetOffsetFromEntityGivenWorldCoords(self.vehicle, p.x, p.y, p.z)
    local min, max = self.carMin, self.carMax
    return o.x > min.x - margin and o.x < max.x + margin and o.y > min.y - margin and o.y < max.y + margin
end

-- The car's side, felt by the hoses ---------------------------------------------------------------
-- Rays at the car from outside on a grid in filler space record where its body is, a few a frame.

local PROFILE = { x0 = -0.75, dx = 0.15, nx = 11, z0 = 0.15, dz = 0.1 }

function SiphonProps:startProfile()
    local height = self.place.paint.z - self.place.ground
    local nz = math.ceil((height + PROFILE.z0) / PROFILE.dz) + 1
    self.profile = { x0 = PROFILE.x0, dx = PROFILE.dx, nx = PROFILE.nx, z0 = PROFILE.z0, dz = PROFILE.dz, nz = nz,
        total = PROFILE.nx * nz, next = 1, y = {} }
end

function SiphonProps:sampleProfile(budget)
    local pf = self.profile
    local ped = PlayerPedId()
    while budget > 0 and pf.next <= pf.total do
        local k = pf.next - 1
        local x, z = pf.x0 + (k % pf.nx) * pf.dx, pf.z0 - (k // pf.nx) * pf.dz
        local a, b = self:filler(vec3(x, -0.7, z)), self:filler(vec3(x, 0.35, z))
        local _, hit, pos, _, entity = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, 2, ped, 7))
        if (hit == true or hit == 1) and entity == self.vehicle then pf.y[k] = self:toFiller(pos).y end
        pf.next, budget = pf.next + 1, budget - 1
    end
end

---How far in (filler space y) the car's body is at x, z, or nil where there is none.
function SiphonProps:wallAt(x, z)
    local pf = self.profile
    local fx, fz = (x - pf.x0) / pf.dx, (pf.z0 - z) / pf.dz
    if fx < 0 or fz < 0 or fx > pf.nx - 1 or fz > pf.nz - 1 then return nil end
    local ix, iz = math.min(math.floor(fx), pf.nx - 2), math.min(math.floor(fz), pf.nz - 2)
    local u, v = fx - ix, fz - iz
    local function at(i, j) return pf.y[(iz + j) * pf.nx + ix + i] end
    local a, b, c, d = at(0, 0), at(1, 0), at(0, 1), at(1, 1)
    if a and b and c and d then return Lerp(Lerp(a, b, u), Lerp(c, d, u), v) end
    -- At an edge of the body: the nearest ray that hit it.
    if u < 0.5 then return v < 0.5 and a or c end
    return v < 0.5 and b or d
end

-- The ground ------------------------------------------------------------------------------------

local GROUND_STEP = 0.2
local GROUND_ROOM = 0.25 -- metres the ground not looked at yet may be higher than any that has been (a kerb)

---The ground round `centre`: props.ground(x, y) is its height there. Each 0.2 m cell is looked up the
---first time it is needed (a few at a time as the hoses move), not the whole area at once.
function SiphonProps:sampleGround(centre, half)
    local n = math.ceil(half * 2 / GROUND_STEP) + 1
    local x0, y0 = centre.x - half, centre.y - half
    local z, top = {}, centre.z
    self.groundTop = top + GROUND_ROOM -- the hoses' colliders skip the ground above this

    local function cell(i, j)
        local k = j * n + i
        local h = z[k]
        if h then return h end
        local found, g = GetGroundZFor_3dCoord(x0 + i * GROUND_STEP, y0 + j * GROUND_STEP, centre.z + 1.5, false)
        h = (found and math.abs(g - centre.z) < 1.5) and g or centre.z
        z[k] = h
        if h > top then
            top = h
            self.groundTop = top + GROUND_ROOM
        end
        return h
    end

    self.ground = function(x, y)
        local fx = Clamp((x - x0) / GROUND_STEP, 0.0, n - 1.001)
        local fy = Clamp((y - y0) / GROUND_STEP, 0.0, n - 1.001)
        local i, j = math.floor(fx), math.floor(fy)
        local u, v = fx - i, fy - j
        return Lerp(Lerp(cell(i, j), cell(i + 1, j), u), Lerp(cell(i, j + 1), cell(i + 1, j + 1), u), v)
    end
end

-- Colliders for the hoses -----------------------------------------------------------------------

local WHEELS = { wheel_lf = 0, wheel_rf = 1, wheel_lr = 2, wheel_rr = 3 } -- bone and wheel index

---The car's tyres near the filler, as cylinders across the car (the body profile's rays don't stop the
---hose on them: it would hang down through the tyre).
function SiphonProps:tyres()
    local vehicle, list = self.vehicle, {}
    local right = GetOffsetFromEntityInWorldCoords(vehicle, 1.0, 0.0, 0.0) - GetEntityCoords(vehicle)
    local paint = self.place.paint
    for bone, index in pairs(WHEELS) do
        local b = GetEntityBoneIndexByName(vehicle, bone)
        if b ~= -1 then
            local c = GetWorldPositionOfEntityBone(vehicle, b)
            if #(c - paint) < 2.5 then
                local radius = GetVehicleWheelTireColliderSize(vehicle, index)
                local width = GetVehicleWheelTireColliderWidth(vehicle, index)
                radius = (radius and radius > 0.15) and radius or 0.33
                width = (width and width > 0.05) and width or 0.2
                -- Its outer face is the side the filler is on.
                local out = Vec.dot(paint - c, right) >= 0 and right or -right
                local half = math.max(0.08, width / 2) + 0.01
                list[#list + 1] = { c = c, out = out, radius = radius + 0.01, half = half,
                    ball = math.sqrt((radius + 0.01) ^ 2 + half ^ 2) }
            end
        end
    end
    return list
end

-- The player's legs, felt by the hoses: capsules between live bones (so any pose, any ped) from the
-- hip to the knee, the knee to the ankle and the ankle to the toes, clothes allowed for.
local LEGS = {
    { 58271, 63931, 0.085 }, { 63931, 14201, 0.065 }, { 14201, 2108, 0.055 }, -- SKEL_L_Thigh, Calf, Foot, Toe0
    { 51826, 36864, 0.085 }, { 36864, 52301, 0.065 }, { 52301, 20781, 0.055 }, -- SKEL_R_*
}
local LEG_WAKE = 0.01 -- metres a leg moves before the sleeping hoses are checked against it
local LEG_NEAR = 0.02 -- metres from a leg a sleeping hose's node has to be for it to wake

---Is any node of the rope within LEG_NEAR of one of the legs?
local function nearLegs(rope, legs)
    local p, n = rope.p, rope.count
    local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
    for i = 1, n do
        local q = p[i]
        x0, y0, z0 = math.min(x0, q.x), math.min(y0, q.y), math.min(z0, q.z)
        x1, y1, z1 = math.max(x1, q.x), math.max(y1, q.y), math.max(z1, q.z)
    end
    for _, l in ipairs(legs) do
        local reach = l.r + rope.radius + LEG_NEAR
        local a, b = l.a, l.b
        if math.min(a.x, b.x) - reach <= x1 and math.max(a.x, b.x) + reach >= x0
            and math.min(a.y, b.y) - reach <= y1 and math.max(a.y, b.y) + reach >= y0
            and math.min(a.z, b.z) - reach <= z1 and math.max(a.z, b.z) + reach >= z0 then
            local ab = b - a
            local len2 = Vec.dot(ab, ab)
            for i = 1, n do
                local q = p[i]
                local c = a + ab * (len2 > 1e-8 and Clamp(Vec.dot(q - a, ab) / len2, 0.0, 1.0) or 0.0)
                if #(q - c) < reach then return true end
            end
        end
    end
    return false
end
SiphonProps.nearLegs = nearLegs

---Where the legs are this frame. A sleeping hose wakes when a leg that moved touches it, or was
---touching it (it may have to fall now).
function SiphonProps:updateLegs()
    local ped = PlayerPedId()
    local legs = {}
    local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
    for i, l in ipairs(LEGS) do
        local a, b, r = GetPedBoneCoords(ped, l[1], 0.0, 0.0, 0.0), GetPedBoneCoords(ped, l[2], 0.0, 0.0, 0.0), l[3]
        legs[i] = { a = a, b = b, r = r }
        x0, y0, z0 = math.min(x0, a.x - r, b.x - r), math.min(y0, a.y - r, b.y - r), math.min(z0, a.z - r, b.z - r)
        x1, y1, z1 = math.max(x1, a.x + r, b.x + r), math.max(y1, a.y + r, b.y + r), math.max(z1, a.z + r, b.z + r)
    end
    self.legs, self.legBox = legs, { x0 = x0, y0 = y0, z0 = z0, x1 = x1, y1 = y1, z1 = z1 }
    local woke = self.legsWoke
    local moved = not woke
    for i = 1, #legs do
        if moved then break end
        moved = #(woke[i].a - legs[i].a) > LEG_WAKE or #(woke[i].b - legs[i].b) > LEG_WAKE
    end
    if moved then
        for _, rope in ipairs({ self.siphon, self.blow }) do
            if rope.asleep and (not woke or nearLegs(rope, legs) or nearLegs(rope, woke)) then rope:wake() end
        end
        self.legsWoke = legs
    end
end

function SiphonProps:colliders()
    local function ground(p, r)
        local g = self.ground(p.x, p.y)
        if p.z < g + r then return vec3(p.x, p.y, g + r), true end
    end

    local function car(p, r)
        local q = self:toFiller(p)
        if q.y < -0.4 then return end
        local wall = self:wallAt(q.x, q.z)
        if wall and q.y > wall - r and q.y < wall + 0.15 then return self:filler(vec3(q.x, wall - r, q.z)), true end
    end

    -- Resting on top of something, once the hose has been put down it slides off towards slideOff.
    local function slid(x, y)
        local s = self.slideOff
        if not s then return x, y end
        return x + s.x * SLIDE_STEP, y + s.y * SLIDE_STEP
    end

    local hx, hy, top = CAN.size.x / 2, CAN.size.y / 2, CAN.top
    local neck, rim = CAN.neckPath[1], CAN.neckPath[1].z
    local neckR = CAN.cap.radius + 0.004 -- the threads (and the collar below them) are about the cap's size
    local canBall = math.sqrt(hx * hx + hy * hy) + 0.01 -- round the can, seen from above
    local function can(p, r)
        local c = self.canPos
        local dx, dy, reach = p.x - c.x, p.y - c.y, canBall + r
        if dx * dx + dy * dy > reach * reach then return end
        local q = Vec.unrotate(self.canRot, p - c)
        -- The neck stands up from the shoulder: out over the rim or off its side, whichever is nearer.
        local nx, ny = q.x - neck.x, q.y - neck.y
        local d = math.sqrt(nx * nx + ny * ny)
        if q.z < rim + r and q.z > top - 0.02 and d < neckR + r then
            local up, out = rim + r - q.z, neckR + r - d
            if up <= out or d < 1e-6 then
                local x, y = slid(q.x, q.y)
                return self:can(vec3(x, y, rim + r)), true
            end
            local k = (neckR + r) / d
            return self:can(vec3(neck.x + nx * k, neck.y + ny * k, q.z)), true
        end
        local dx, dy, dz = hx + r - math.abs(q.x), hy + r - math.abs(q.y), top + r - q.z
        if dx <= 0 or dy <= 0 or dz <= 0 or q.z < -0.05 then return end
        -- Out the shortest way: on top of it, or off a side.
        if dz <= dx and dz <= dy then
            local x, y = slid(q.x, q.y)
            return self:can(vec3(x, y, top + r)), true
        end
        if dx <= dy then return self:can(vec3(q.x + (q.x < 0 and -dx or dx), q.y, q.z)) end
        return self:can(vec3(q.x, q.y + (q.y < 0 and -dy or dy), q.z))
    end

    local tyres = self:tyres()
    local function tyre(p, r)
        for _, w in ipairs(tyres) do
            local q = p - w.c
            local ball = w.ball + r
            local far = q.x * q.x + q.y * q.y + q.z * q.z > ball * ball
            local along = far and 0.0 or Vec.dot(q, w.out)
            local radial = far and q or q - w.out * along
            local d = far and math.huge or #radial
            if along < w.half + r and along > -w.half - r and d < w.radius + r then
                -- Out onto the outer sidewall or the tread, whichever is nearer (never inside the car).
                local side, tread = w.half + r - along, w.radius + r - d
                if side <= tread or d < 1e-6 then return p + w.out * side, true end
                return w.c + w.out * along + radial * ((w.radius + r) / d), true
            end
        end
    end

    -- Round the legs: out from the nearest point of the bone, away from the car if it is right on it.
    local function leg(p, r)
        local box = self.legBox
        if not box or p.x < box.x0 - r or p.x > box.x1 + r or p.y < box.y0 - r or p.y > box.y1 + r
            or p.z < box.z0 - r or p.z > box.z1 + r then
            return
        end
        local touched = false
        for _, l in ipairs(self.legs) do
            local ab = l.b - l.a
            local len2 = Vec.dot(ab, ab)
            local c = l.a + ab * (len2 > 1e-8 and Clamp(Vec.dot(p - l.a, ab) / len2, 0.0, 1.0) or 0.0)
            local d = p - c
            local dist, reach = #d, l.r + r
            if dist < reach then
                p = c + (dist > 1e-6 and d / dist or self.place.outward) * reach
                touched = true
            end
        end
        if touched then return p, true end
    end

    -- The funnel in the can: its wall, from outside (over the rim or off the side) and from inside (in
    -- off it), and its inside's floor. The nodes down through it are in the guide, not collided.
    local rimTop, rimR = FUNNEL.rim.top, FUNNEL.rim.radius
    local funnelBall = math.max(rimR, FUNNEL.flange) + 0.01
    local function funnel(p, r)
        local f = self.funnel
        if f.where ~= 'can' or f.lift > 0.001 then return end
        local seat = self:can(FUNNEL.seat)
        local dx, dy, reach = p.x - seat.x, p.y - seat.y, funnelBall + r
        if dx * dx + dy * dy > reach * reach then return end
        local q = Vec.unrotate(self.canRot, p - seat) -- round, so its turn doesn't matter
        if q.z > rimTop + r or q.z < 0.0 then return end
        local d = math.sqrt(q.x * q.x + q.y * q.y)
        local inner = bowlRadius(q.z)
        local outer = math.max(math.min(inner + FUNNEL_WALL, rimR), q.z < 0.024 and FUNNEL.flange or 0.0)
        if d > outer + r then return end
        local function back(x, y, z) return self:can(FUNNEL.seat + vec3(x, y, z)), true end
        local function onRim()
            local x, y = slid(q.x, q.y)
            return back(x, y, rimTop + r)
        end
        local up = rimTop + r - q.z
        if d < (inner + outer) / 2 then
            -- Inside the bowl: in off its wall, or up over the rim when that is nearer.
            local into = d - (inner - r)
            if into <= 0.0 then return end
            if up < into then return onRim() end
            local k = math.max(0.0, inner - r) / math.max(d, 1e-6)
            return back(q.x * k, q.y * k, q.z)
        end
        local out = outer + r - d
        if up <= out then return onRim() end
        local k = (outer + r) / d
        return back(q.x * k, q.y * k, q.z)
    end

    -- Which of them a hose within box (Rope: colliders.select) can reach this step.
    local tyreBox
    for _, w in ipairs(tyres) do
        local b = w.ball
        tyreBox = tyreBox or { x0 = math.huge, y0 = math.huge, z0 = math.huge, x1 = -math.huge, y1 = -math.huge, z1 = -math.huge }
        tyreBox.x0, tyreBox.y0, tyreBox.z0 = math.min(tyreBox.x0, w.c.x - b), math.min(tyreBox.y0, w.c.y - b), math.min(tyreBox.z0, w.c.z - b)
        tyreBox.x1, tyreBox.y1, tyreBox.z1 = math.max(tyreBox.x1, w.c.x + b), math.max(tyreBox.y1, w.c.y + b), math.max(tyreBox.z1, w.c.z + b)
    end
    local function overlaps(a, b)
        return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0 and a.z0 <= b.z1 and a.z1 >= b.z0
    end
    local canHeight = math.max(CAN.size.z, rim, FUNNEL.seat.z + rimTop) + 0.02
    local active = {}
    local function select(box)
        local n = 0
        local function add(f) n = n + 1; active[n] = f end
        if not self.groundTop or box.z0 <= self.groundTop then add(ground) end
        add(car)
        local c = self.canPos
        if c then
            local reach = canBall + 0.02
            local lift = self.funnel and self.funnel.lift or 0.0
            if box.x0 <= c.x + reach and box.x1 >= c.x - reach and box.y0 <= c.y + reach and box.y1 >= c.y - reach
                and box.z0 <= c.z + canHeight + lift and box.z1 >= c.z - 0.05 then
                add(can)
                add(funnel)
            end
        end
        if tyreBox and overlaps(box, tyreBox) then add(tyre) end
        if self.legBox and overlaps(box, self.legBox) then add(leg) end
        for i = n + 1, #active do active[i] = nil end
        return active
    end

    return { ground, car, can, tyre, leg, funnel, select = select }
end

-- The can and the kit ------------------------------------------------------------------------------

---The ghost of the can where it would go (alpha), or hidden.
function SiphonProps:ghost(pos, heading)
    if not pos and not self.ghostEntity then return end
    if not self.ghostEntity then
        self.ghostEntity = spawn('tr_sf_can', pos)
        SetEntityAlpha(self.ghostEntity, 150, false)
    end
    if not pos then return show(self.ghostEntity, false) end
    put(self.ghostEntity, pos, Mat.axis('z', heading))
end

---The closed can in the player's hand, or hidden.
function SiphonProps:carry(pos, rot)
    self.carriedAt = pos and { pos = pos, rot = rot } or nil
    if not pos then return show(self.carried, false) end
    put(self.carried, pos, rot)
end

---The can is down at pos (its bottom middle), turned to heading: it opens up (body, cap, strap) and the
---hoses and the funnel are laid out beside it.
function SiphonProps:setCan(pos, heading)
    self.canPos, self.canRot = pos, Mat.axis('z', heading)
    if self.ghostEntity then delete(self.ghostEntity) end
    self.ghostEntity = nil
    show(self.carried, false)

    self.canBody = spawn('tr_sf_canbody', pos)
    self.canCapEntity = spawn('tr_sf_cancap', pos)
    put(self.canBody, pos, self.canRot)
    self.neckIn, self.neckDepth = Rope.path({ self:can(CAN.neckPath[1]), self:can(CAN.neckPath[2]) })

    local filler = self.place.paint
    local footing = vec3(filler.x, filler.y, self.place.ground)
    self:sampleGround((pos + footing) * 0.5, #(pos - footing) / 2 + 1.0)
    self.siphon.colliders = self:colliders()
    self.blow.colliders = self.siphon.colliders
    self:layKit()
end

---The can is picked up again: its body, cap and strap go (the closed can is in the hand).
function SiphonProps:liftCan()
    delete(self.canBody)
    delete(self.canCapEntity)
    self.canBody, self.canCapEntity = nil, nil
    drawLine(self.canStrap, nil)
end

---Puts the siphon hose (coiled), the blow hose and the funnel on the ground beside the can, on the side
---away from the player and clear of the car.
function SiphonProps:layKit()
    local can, filler = self.canPos, self.place.paint
    local f = vec3(filler.x - can.x, filler.y - can.y, 0.0)
    f = #f > 0.01 and Vec.normalize(f) or vec3(1.0, 0.0, 0.0)
    local s = vec3(-f.y, f.x, 0.0)
    local ped = GetEntityCoords(PlayerPedId())
    if Vec.dot(ped - can, s) > 0 then s = -s end

    local function spots(side)
        return can + side * 0.42, can + side * 0.3 + f * 0.32, can + side * 0.62 + f * 0.04, can + side * 0.3 - f * 0.42
    end
    local coil, blowA, blowB, funnel = spots(s)
    if self:insideCar(coil, 0.1) or self:insideCar(blowA, 0.1) or self:insideCar(funnel, 0.2) then
        coil, blowA, blowB, funnel = spots(-s)
    end

    local function onGround(p, lift) return vec3(p.x, p.y, self.ground(p.x, p.y) + lift) end

    -- The siphon hose in a loose flat coil, its filler end on the outside.
    local points, r, angle = {}, 0.21, math.atan(f.y, f.x)
    local length, step = 0.0, 0.03
    points[1] = onGround(coil + vec3(math.cos(angle), math.sin(angle), 0.0) * r, HOSE.siphonRadius)
    while length < HOSE.siphonLength + 0.1 do
        angle = angle + step / r
        r = math.max(0.07, r - step * 0.035)
        length = length + step
        points[#points + 1] = onGround(coil + vec3(math.cos(angle), math.sin(angle), 0.0) * r, HOSE.siphonRadius)
    end
    self.siphon:lay(points)

    local bow = (blowA + blowB) * 0.5 + s * 0.06
    self.blow:lay({ onGround(blowA, HOSE.blowRadius), onGround(bow, HOSE.blowRadius), onGround(blowB, HOSE.blowRadius) })

    -- The funnel on its side, its bowl away from the can.
    local away = funnel - can
    self.funnelSpot = { at = onGround(funnel, 0.0), heading = math.deg(math.atan(away.y, away.x)) }
    self:layFunnel()
    self.kitShown = true
end

-- The siphon hose's end put down off the can ---------------------------------------------------------
-- Let go of over the can once it is out, the hose would fall where it hangs: often off the far end,
-- pulling it across the top and over the cap that goes back on next. Its end is laid on the ground off
-- the side the hose comes down instead (nothing is pulled across the top that way), and whatever still
-- rests on the can, its funnel or its neck slides off towards that side (slideOff, the colliders above).

---Is p (world) on the can: over it and no lower than its shoulder (on it, on the funnel in it, or above)?
function SiphonProps:onCan(p)
    local q = Vec.unrotate(self.canRot, p - self.canPos)
    return math.abs(q.x) <= CAN.size.x / 2 + 0.005 and math.abs(q.y) <= CAN.size.y / 2 + 0.005 and q.z >= CAN.top - 0.02
end

---Straight out of the can's nearest side (or corner) from q (can space), level.
local function outOfCan(q)
    local ox, oy = math.abs(q.x) - CAN.size.x / 2, math.abs(q.y) - CAN.size.y / 2
    local sx, sy = q.x < 0.0 and -1.0 or 1.0, q.y < 0.0 and -1.0 or 1.0
    if ox > 0.0 and oy > 0.0 then return Vec.normalize(vec3(sx * ox, sy * oy, 0.0)) end
    if ox >= oy then return vec3(sx, 0.0, 0.0) end
    return vec3(0.0, sy, 0.0)
end

---Where the siphon hose's end goes down and how it is carried there: { path, length (Rope.path), at,
---slide (can space: the way the rest slides off) }, or nil when none of it is on the can.
function SiphonProps:hoseLay()
    local rope = self.siphon
    local n = rope.count
    -- The hose comes down off the can at the node before the first one (from end 1) that is on it.
    local first
    for i = 1, n do
        if self:onCan(rope.p[i]) then first = i; break end
    end
    if not first then return nil end
    local leave = rope.p[math.max(1, first - 1)]
    local q = Vec.unrotate(self.canRot, leave - self.canPos)
    local out = outOfCan(q)
    -- Out as far as the hose from there reaches along the ground (so it is drawn off the can, not across it).
    local slack = (n - first + 1) * rope.seg - math.max(0.0, leave.z - self.ground(leave.x, leave.y))
    local reach = Clamp(slack * 0.85, LAY_OUT[1], LAY_OUT[2])
    local hx, hy = CAN.size.x / 2 + 0.03, CAN.size.y / 2 + 0.03

    local function free(p)
        local c = Vec.unrotate(self.canRot, p - self.canPos)
        if math.abs(c.x) < hx and math.abs(c.y) < hy then return false end
        if self:insideCar(p, 0.05) then return false end
        if self.funnelSpot and #(p - self.funnelSpot.at) < 0.15 then return false end
        for _, l in ipairs(self.legs or {}) do
            local ab = l.b - l.a
            local len2 = Vec.dot(ab, ab)
            local k = len2 > 1e-8 and Clamp(Vec.dot(p - l.a, ab) / len2, 0.0, 1.0) or 0.0
            if #(p - (l.a + ab * k)) < l.r + 0.03 then return false end
        end
        return true
    end
    -- Straight out, or turned, or not as far, when the car, the player's legs or the funnel's spot is there.
    local function spot()
        local straight
        for _, scale in ipairs({ 1.0, 0.5 }) do
            for _, turn in ipairs(LAY_TURNS) do
                local dir = Mat.apply(Mat.axis('z', turn), out)
                local p = self:can(vec3(q.x, q.y, 0.0) + dir * math.max(LAY_OUT[1], reach * scale))
                p = vec3(p.x, p.y, self.ground(p.x, p.y) + rope.radius)
                if free(p) then return p end
                straight = straight or p
            end
        end
        return straight -- nowhere free
    end
    local at = spot()

    -- Up over the can (and the funnel in it), across, and down.
    local start = rope.pins[n] or rope.p[n]
    local high = self.funnel.where == 'can' and FUNNEL.seat.z + FUNNEL.rim.top or CAN.size.z
    local over = math.max(start.z, self:can(vec3(0.0, 0.0, high)).z + LAY_CLEAR)
    local path, length = Rope.path({ start, vec3(start.x, start.y, over), vec3(at.x, at.y, over), at })
    return { path = path, length = length, at = at, slide = out }
end

---Once the hose has been put down, a hose that fell asleep still resting on the can is woken: it carries
---on sliding off.
function SiphonProps:keepSliding()
    if not self.slideOff then return end
    for _, rope in ipairs({ self.siphon, self.blow }) do
        if rope.asleep then
            for i = 1, rope.count do
                if not rope.fixed[i] and self:onCan(rope.p[i]) then
                    rope:wake()
                    break
                end
            end
        end
    end
end

-- The funnel --------------------------------------------------------------------------------------
-- Funnel space (rig.lua): axis +Z, origin where its flange sits on the can's neck; its spout bends
-- towards +X. Its bellows are strung along the bend the way props/siphon/build.py does.

---The spout's joints (funnel space) bent `bend` degrees along an even arc, and its direction at the end.
function SiphonProps.spoutPoints(bend)
    local piece, pieces = FUNNEL.spout.piece, FUNNEL.spout.pieces
    local length = piece * pieces
    local k = math.rad(bend) / length
    local points = {}
    for i = 0, pieces do
        local s = i * piece
        points[i + 1] = math.abs(k) < 1e-9 and vec3(0.0, 0.0, -s) or vec3((1.0 - math.cos(k * s)) / k, 0.0, -math.sin(k * s) / k)
    end
    return points, vec3(math.sin(k * length), 0.0, -math.cos(k * length))
end

---How high fuel stands in the funnel with `litres` in it, and the bowl's radius there.
function SiphonProps.funnelLevel(litres)
    local levels = FUNNEL.levels
    for i = 2, #levels do
        local a, b = levels[i - 1], levels[i]
        if litres <= b[1] then
            local t = Clamp((litres - a[1]) / math.max(1e-9, b[1] - a[1]), 0.0, 1.0)
            return Lerp(a[2], b[2], t), Lerp(a[3], b[3], t)
        end
    end
    return levels[#levels][2], levels[#levels][3]
end

---Where the funnel is (world) and how it is turned, as its state puts it.
function SiphonProps:funnelPose()
    local f = self.funnel
    if f.where == 'can' then return self:can(FUNNEL.seat + vec3(0.0, 0.0, f.lift)), Mat.mul(self.canRot, FUNNEL_TURN) end
    return f.pos, f.rot
end

---Where the funnel is drawn now (it may be on its way somewhere).
function SiphonProps:funnelShown()
    local f = self.funnel
    if f.shownPos then return f.shownPos, f.shownRot end
    return self:funnelPose()
end

---The middle of its bowl (world), where it is picked up.
function SiphonProps:funnelCentre()
    local pos, rot = self:funnelShown()
    return pos + Mat.apply(rot, FUNNEL.hold)
end

---The tip of its nozzle (world).
function SiphonProps:nozzleTip()
    local pos, rot = self:funnelShown()
    local points, dir = SiphonProps.spoutPoints(self.funnel.shownBend)
    return pos + Mat.apply(rot, points[#points] + dir * FUNNEL.nozzle)
end

---Lays the funnel on its side at its spot by the kit, moving it there over `time` seconds (or at once).
function SiphonProps:layFunnel(time)
    local f, spot = self.funnel, self.funnelSpot
    local turn = Mat.axis('z', spot.heading)
    f.where, f.bend, f.lift = 'ground', FUNNEL.spout.rest, 0.0
    f.pos, f.rot = spot.at + Mat.apply(turn, FUNNEL.lie.at), Mat.mul(turn, FUNNEL.lie.rot)
    if time and f.shownPos then
        f.move = { pos = f.shownPos, rot = f.shownRot, t = 0.0, time = time, lift = vec3(0.0, 0.0, 0.08) }
    end
end

---The funnel in the hand, upright, the middle of its bowl at `centre` (world). Picked up, it turns
---upright on the way.
function SiphonProps:holdFunnel(centre)
    local f = self.funnel
    if f.where ~= 'held' then
        f.where, f.bend = 'held', FUNNEL.spout.rest
        if f.shownPos then f.move = { pos = f.shownPos, rot = f.shownRot, t = 0.0, time = 0.25 } end
    end
    f.rot = Mat.mul(self.canRot, FUNNEL_TURN)
    f.pos = centre - Mat.apply(f.rot, FUNNEL.hold)
end

---Into the can, `lift` metres up out of its seat (the game lowers it), its spout straightening.
function SiphonProps:seatFunnel(lift)
    local f = self.funnel
    f.where, f.bend, f.lift = 'can', 0.0, lift or 0.0
    if f.shownPos then f.move = { pos = f.shownPos, rot = f.shownRot, t = 0.0, time = 0.2 } end
end

-- Caps --------------------------------------------------------------------------------------------
-- A cap's state: turn (radians counter-clockwise from seated), out (metres backed out), or `hang`
-- (the fuel cap on its strap) / `off` (the can cap on the shoulder). `move` blends from where it was.

local function blended(cap, pos, rot, dt)
    local move = cap.move
    if move then
        move.t = math.min(1.0, move.t + dt / move.time)
        local k = move.t * move.t * (3 - 2 * move.t)
        pos = Vec.lerp(move.pos, pos, k) + (move.lift or vec3(0.0, 0.0, 0.0)) * math.sin(math.pi * k)
        rot = Mat.blend(move.rot, rot, k)
        if move.t >= 1.0 then cap.move = nil end
    end
    cap.shownPos, cap.shownRot = pos, rot
    return pos, rot
end

---Starts a cap moving smoothly from where it is shown now to wherever its state puts it.
---@param which 'fuelCap' | 'canCap'
---@param lift? vector3 how far it arcs out on the way (its space)
function SiphonProps:moveCap(which, time, lift)
    local cap = self[which]
    if not cap.shownPos then return end
    cap.move = { pos = cap.shownPos, rot = cap.shownRot, t = 0.0, time = time or 0.3, lift = lift }
end

---The middle of the fuel cap's face and of the can cap's top (world), for picking them and rings.
function SiphonProps:fuelCapCentre()
    local cap = self.fuelCap
    if not cap.shownPos then return self:filler(FILLER.cap.seat) end
    return self:filler(cap.shownPos + Mat.apply(cap.shownRot, vec3(0.0, 0.0, FILLER.cap.height * 0.6)))
end

function SiphonProps:canCapCentre()
    local cap = self.canCap
    if not cap.shownPos then return self:can(CAN.cap.seat) end
    return self:can(cap.shownPos + Mat.apply(cap.shownRot, vec3(0.0, 0.0, CAN.cap.height * 0.6)))
end

---The fuel cap: screwed (filler space), or hanging from its strap and swinging.
function SiphonProps:fuelCapPose(dt)
    local cap = self.fuelCap
    local def = FILLER.cap
    if cap.hang then
        local theta = cap.theta or 0.0
        local length = FILLER.tether.length * 0.96
        local eye = FILLER.tether.anchor + vec3(length * math.sin(theta), -0.010, -length * math.cos(theta))
        local rot = Mat.mul(Mat.axis('y', -math.deg(theta)), def.rot, Mat.axis('z', 90.0))
        return eye - Mat.apply(rot, def.eye), rot, eye
    end
    local rot = Mat.mul(def.rot, Mat.axis('z', math.deg(cap.turn)))
    local pos = def.seat + def.rot.z * cap.out
    return pos, rot, pos + Mat.apply(def.rot, def.eye) -- the strap's eye is on a swivel ring: it doesn't turn
end

---Lets the fuel cap drop onto its strap.
function SiphonProps:hangFuelCap()
    local cap = self.fuelCap
    local _, _, eye = self:fuelCapPose(0)
    local v = eye - FILLER.tether.anchor
    cap.hang, cap.theta, cap.omega = true, Clamp(math.atan(v.x, -v.z), -2.1, 2.1), 0.0
    self:moveCap('fuelCap', 0.12)
end

function SiphonProps:swingFuelCap(dt)
    local cap = self.fuelCap
    if not cap.hang or (cap.theta == 0.0 and cap.omega == 0.0) then return end
    if math.abs(cap.theta) < 0.002 and math.abs(cap.omega) < 0.01 then
        cap.theta, cap.omega = 0.0, 0.0
        return
    end
    local g = 9.81 / (FILLER.tether.length * 0.96)
    for _ = 1, 4 do
        local h = dt / 4
        cap.omega = cap.omega + (-g * math.sin(cap.theta) - CAP_SWING_DAMPING * cap.omega) * h
        cap.theta = cap.theta + cap.omega * h
    end
end

---The can cap: screwed (can space), or upside down on the shoulder.
function SiphonProps:canCapPose()
    local cap = self.canCap
    local def = CAN.cap
    if cap.off then return def.off, def.offRot, def.off + Mat.apply(def.offRot, def.eye) end
    local pos = def.seat + vec3(0.0, 0.0, cap.out)
    return pos, Mat.axis('z', math.deg(cap.turn)), pos + def.eye
end

-- Drawing -----------------------------------------------------------------------------------------

function SiphonProps:drawFiller(dt)
    local scene = self.scene
    local flap = scene:get('flap')
    flap.rot = Mat.axis('x', self.flap)

    self:swingFuelCap(dt)
    local pos, rot, eye = self:fuelCapPose(dt)
    self.fuelCap.pos, self.fuelCap.rot = pos, rot
    local part = scene:get('fuelcap')
    part.pos, part.rot = blended(self.fuelCap, pos, rot, dt)
    if self.fuelCap.move then eye = part.pos + Mat.apply(part.rot, FILLER.cap.eye) end

    self.fuelCap.eye = eye
    local drawn = self.fuelStrapDrawn
    if drawn and drawn.eye == eye and drawn.hang == self.fuelCap.hang and not scene.moved then return end
    self.fuelStrapDrawn = { eye = eye, hang = self.fuelCap.hang }
    local sag = self.fuelCap.hang and vec3(0.0, -1.0, 0.0) or vec3(0.0, -1.0, -0.3)
    local points = strapPoints(FILLER.tether.anchor, eye, FILLER.tether.length, Vec.normalize(sag), STRAP_PIECES)
    for k, p in ipairs(points) do points[k] = scene:toWorld(p) end
    drawLine(self.fuelStrap, points, self:fillerDir(vec3(0.0, -1.0, 0.0)))
end

function SiphonProps:drawCan(dt)
    if not self.canBody then return end
    local pos, rot, eye = self:canCapPose()
    self.canCap.pos, self.canCap.rot = pos, rot
    local p, r = blended(self.canCap, pos, rot, dt)
    if self.canCap.move then eye = p + Mat.apply(r, CAN.cap.eye) end
    put(self.canCapEntity, self:can(p), Mat.mul(self.canRot, r))
    self.canCap.eye = eye

    local drawn = self.canStrapDrawn
    if drawn and drawn.eye == eye and drawn.off == self.canCap.off and drawn.body == self.canBody then return end
    self.canStrapDrawn = { eye = eye, off = self.canCap.off, body = self.canBody }
    local sag = self.canCap.off and vec3(0.0, 0.0, 1.0) or Vec.normalize(vec3(-1.0, 0.0, 0.6))
    local points = strapPoints(CAN.tether.anchor, eye, CAN.tether.length, sag, STRAP_PIECES)
    for k, q in ipairs(points) do points[k] = self:can(q) end
    drawLine(self.canStrap, points, self:canDir(UP))
end

---The funnel's pieces (o.funnelEntity, nozzleEntity, poolEntity, spoutEntities) at pos turned rot (world),
---its spout bent `bend` degrees, `level` litres standing in it when it is in the can; nil pos hides it.
local function drawFunnelAt(o, pos, rot, bend, level, inCan)
    if not pos then
        show(o.funnelEntity, false)
        show(o.nozzleEntity, false)
        show(o.poolEntity, false)
        for _, piece in ipairs(o.spoutEntities) do show(piece, false) end
        return
    end
    put(o.funnelEntity, pos, rot)
    local points, dir = SiphonProps.spoutPoints(bend)
    for i, piece in ipairs(o.spoutEntities) do
        span(piece, pos + Mat.apply(rot, points[i]), pos + Mat.apply(rot, points[i + 1]), FUNNEL.spout.piece)
    end
    put(o.nozzleEntity, pos + Mat.apply(rot, points[#points]), Mat.along(Mat.apply(rot, dir)))

    -- Fuel standing in the bowl (upright, in the can): a disc as wide as the bowl at its level.
    if inCan and level > 0.002 then
        local z, r = SiphonProps.funnelLevel(level)
        local at = pos + rot.z * z
        local x, y = rot.x * r, rot.y * r
        setMatrix(o.poolEntity, y.x, y.y, y.z, x.x, x.y, x.z, rot.z.x, rot.z.y, rot.z.z, at.x, at.y, at.z)
        show(o.poolEntity, true)
    else
        show(o.poolEntity, false)
    end
end

function SiphonProps:drawFunnel(dt)
    local f = self.funnel
    if not self.kitShown or not (f.pos or f.where == 'can') then
        f.shownPos, f.shownRot = nil, nil
        return drawFunnelAt(self, nil)
    end
    local pos, rot = self:funnelPose()
    pos, rot = blended(f, pos, rot, dt)
    local step = BEND_SPEED * dt
    f.shownBend = f.shownBend + Clamp(f.bend - f.shownBend, -step, step)
    drawFunnelAt(self, pos, rot, f.shownBend, f.level, f.where == 'can')
end

---Drops of fuel falling from `at` (world) to the ground.
function SiphonProps:drip(at)
    for i, entity in ipairs(self.dropEntities) do
        if not self.drops[i] then
            self.drops[i] = { pos = at, v = 0.0 }
            return entity
        end
    end
end

function SiphonProps:drawDrops(dt)
    for i, entity in ipairs(self.dropEntities) do
        local drop = self.drops[i]
        if drop then
            drop.v = drop.v + 9.81 * dt
            drop.pos = drop.pos - vec3(0.0, 0.0, drop.v * dt)
            local floor = self.ground and self.ground(drop.pos.x, drop.pos.y) or -math.huge
            if drop.pos.z <= floor then
                self.drops[i] = nil
                show(entity, false)
            else
                put(entity, drop.pos, IDENTITY)
            end
        end
    end
end

local PHYSICS_STEP = 1 / 60 -- seconds: the hoses move at most this often, whatever the frame rate

---Moves the hoses on, at most PHYSICS_STEP apart: at 200 FPS they are worked out 60 times a second, not
---200 (the frames between draw them where they are). Below 60 FPS it is every frame, by the frame's time.
---@return boolean stepped
function SiphonProps:physics(dt)
    local due = (self.physicsDue or 0.0) + dt
    if due < PHYSICS_STEP then
        self.physicsDue = due
        return false
    end
    self.physicsDue = 0.0
    self:updateLegs()
    self:keepSliding()
    self.siphon:step(due)
    self.blow:step(due)
    return true
end

function SiphonProps:update(dt)
    self.scene:update()
    if self.scene.moved then self:updateChannels() end
    self:sampleProfile(12)

    if self.kitShown then self:physics(dt) end
    local hidden = self:inside(self.siphon)
    self.siphonView:draw(self.kitShown, hidden)
    self.blowView:draw(self.kitShown, self:inside(self.blow))
    if self.kitShown then
        self.siphonView:fuel(self.fuelPieces, self.fuelFront, self.fuel.from, self.fuel.to, hidden)
    else
        drawLine(self.fuelPieces, nil)
        show(self.fuelFront, false)
        self.siphonView.fuelFrom = nil -- drawn whole once it shows again
    end

    for k = 1, 2 do
        local pieces = {}
        for i = 1, STREAM_PIECES do pieces[i] = self.streamPieces[(k - 1) * STREAM_PIECES + i] end
        drawLine(pieces, self.streams[k])
    end

    self:drawFiller(dt)
    self:drawCan(dt)
    self:drawFunnel(dt)
    self:drawDrops(dt)
end

-- Players nearby ------------------------------------------------------------------------------------
-- Others see the props through the mirror (TR.mirror). The filler, flap and fuel cap
-- are scene props and go as they are. The rest (two hoses of a hundred and more pieces, the can, the
-- funnel, the fuel) goes as game state: lists of integers in filler space (the car's own frame, so it
-- all sits on their copy of the car), which SiphonView draws there, eased between the updates.
--
--   fcap   hang, strap eye (filler space)
--   carry  can in the hand: pos, rot
--   can    pos, rot, cap off, cap pos, cap rot and strap eye (can space)
--   h1 h2  the siphon and blow hoses' nodes
--   fuel   metres of each hose down the filler, the fuel in the siphon hose from, to
--   funnel pos, rot, spout bend (0.1 degree), litres in it (ml), in the can
--   s1 s2  the spilling streams' points

local MM, AXIS = 1000, 10000 -- positions in mm, rotation axes in ten-thousandths

local function int(v)
    if v ~= v then return 0 end
    return math.floor(Clamp(v, -9e6, 9e6) + 0.5)
end

local function packPos(list, p)
    local n = #list
    list[n + 1], list[n + 2], list[n + 3] = int(p.x * MM), int(p.y * MM), int(p.z * MM)
end

---A rotation as its Y and Z axes (no angles: nothing to go wrong pointing straight up).
local function packRot(list, m)
    local n = #list
    list[n + 1], list[n + 2], list[n + 3] = int(m.y.x * AXIS), int(m.y.y * AXIS), int(m.y.z * AXIS)
    list[n + 4], list[n + 5], list[n + 6] = int(m.z.x * AXIS), int(m.z.y * AXIS), int(m.z.z * AXIS)
end

local function readPos(list, i)
    return vec3(list[i] / MM, list[i + 1] / MM, list[i + 2] / MM)
end

local function readRot(list, i)
    local y = Vec.normalize(vec3(list[i], list[i + 1], list[i + 2]))
    local x = Vec.normalize(Vec.cross(y, vec3(list[i + 3], list[i + 4], list[i + 5])))
    return { x = x, y = y, z = Vec.cross(x, y) }
end

SiphonProps.packPos, SiphonProps.packRot, SiphonProps.readPos, SiphonProps.readRot = packPos, packRot, readPos, readRot

---What the props show that players nearby need: set(key, list | false) for each key above.
function SiphonProps:mirrorState(set)
    local rot = self.scene.rot
    local function pos(list, w) packPos(list, self:toFiller(w)) end
    local function turn(list, m) packRot(list, { y = Vec.unrotate(rot, m.y), z = Vec.unrotate(rot, m.z) }) end

    local fcap = { self.fuelCap.hang and 1 or 0 }
    packPos(fcap, self.fuelCap.eye or FILLER.tether.anchor)
    set('fcap', fcap)

    local carried = self.carriedAt
    if carried then
        local list = {}
        pos(list, carried.pos)
        turn(list, carried.rot)
        set('carry', list)
    else
        set('carry', false)
    end

    local cap = self.canCap
    if self.canBody and cap.shownPos then
        local list = {}
        pos(list, self.canPos)
        turn(list, self.canRot)
        list[#list + 1] = cap.off and 1 or 0
        packPos(list, cap.shownPos)
        packRot(list, cap.shownRot)
        packPos(list, cap.eye or cap.shownPos)
        set('can', list)
    else
        set('can', false)
    end

    if self.kitShown then
        -- Every node in filler space, in numbers (toFiller without making vectors: a hundred of them).
        local o, x, y, z = self.scene.pos, rot.x, rot.y, rot.z
        local ox, oy, oz = o.x, o.y, o.z
        for key, rope in pairs({ h1 = self.siphon, h2 = self.blow }) do
            local list, p = {}, rope.p
            for i = 1, rope.count do
                local q = p[i]
                local dx, dy, dz = q.x - ox, q.y - oy, q.z - oz
                local k = i * 3
                list[k - 2] = int((dx * x.x + dy * x.y + dz * x.z) * MM)
                list[k - 1] = int((dx * y.x + dy * y.y + dz * y.z) * MM)
                list[k] = int((dx * z.x + dy * z.y + dz * z.z) * MM)
            end
            set(key, list)
        end
        set('fuel', { int(self:inside(self.siphon) * MM), int(self:inside(self.blow) * MM),
            int(self.fuel.from * MM), int(self.fuel.to * MM) })
    else
        set('h1', false)
        set('h2', false)
        set('fuel', false)
    end

    local f = self.funnel
    if f.shownPos then
        local list = {}
        pos(list, f.shownPos)
        turn(list, f.shownRot)
        local n = #list
        list[n + 1], list[n + 2], list[n + 3] = int(f.shownBend * 10), int(f.level * MM), f.where == 'can' and 1 or 0
        set('funnel', list)
    else
        set('funnel', false)
    end

    for k = 1, 2 do
        local stream = self.streams[k]
        if stream then
            local list = {}
            for _, p in ipairs(stream) do pos(list, p) end
            set('s' .. k, list)
        else
            set('s' .. k, false)
        end
    end
end

local SiphonView = {}
SiphonView.__index = SiphonView

local EASE = 15.0 -- how fast what is drawn catches up with the updates (they come ~10 times a second)

---Someone else's siphon as a player nearby sees it, drawn from the mirror's game state on their copy
---of the car (scene: the replica's). Waits for the models, so call it from a thread.
function SiphonProps.view(scene)
    scene:preload(MODELS)
    local at = scene.pos
    local self = setmetatable({ scene = scene }, SiphonView)
    self.siphon, self.blow = Rope.new(HOSE.siphonLength, SIPHON_NODE), Rope.new(HOSE.blowLength, BLOW_NODE)
    self.siphonView = HoseView.new(self.siphon, 'tr_sf_siphonseg', 'tr_sf_sfend', at)
    self.blowView = HoseView.new(self.blow, 'tr_sf_blowseg', 'tr_sf_bfend', at)
    self.fuelPieces, self.fuelStrap, self.canStrap, self.streamPieces, self.spoutEntities = {}, {}, {}, {}, {}
    for i = 1, (self.siphon.count - 1) * HoseView.SUB do self.fuelPieces[i] = spawn('tr_sf_fuelseg', at) end
    for i = 1, STRAP_PIECES do self.fuelStrap[i], self.canStrap[i] = spawn('tr_sf_strapseg', at), spawn('tr_sf_strapseg', at) end
    for i = 1, STREAM_PIECES * 2 do self.streamPieces[i] = spawn('tr_sf_fuelseg', at) end
    for i = 1, FUNNEL.spout.pieces do self.spoutEntities[i] = spawn('tr_sf_bellows', at) end
    self.fuelFront, self.carried = spawn('tr_sf_fuelfront', at), spawn('tr_sf_can', at)
    self.canBody, self.canCapEntity = spawn('tr_sf_canbody', at), spawn('tr_sf_cancap', at)
    self.funnelEntity, self.nozzleEntity, self.poolEntity = spawn('tr_sf_funnel', at), spawn('tr_sf_nozzle', at), spawn('tr_sf_funnelpool', at)
    return self
end

---Eases toward a target pose ({ pos, rot }), there at once the first time.
local function ease(shown, target, k)
    if not shown then return target end
    if #(shown.pos - target.pos) < 0.0002 and #(shown.rot.y - target.rot.y) < 0.0005 and #(shown.rot.z - target.rot.z) < 0.0005 then
        return target
    end
    return { pos = Vec.lerp(shown.pos, target.pos, k), rot = Mat.blend(shown.rot, target.rot, k) }
end

---@param state table the replica's game state (keys above)
---@param fuelCap? table the replica's fuel cap part (filler space), for its strap
function SiphonView:draw(state, fuelCap, dt)
    local scene = self.scene
    local k = 1.0 - math.exp(-dt * EASE)
    local function world(list, i) return scene:toWorld(readPos(list, i)) end
    local function pose(list, i) return { pos = world(list, i), rot = Mat.mul(scene.rot, readRot(list, i + 3)) } end

    -- The hoses: eased node by node, then drawn as the player's are.
    local fuel = state.fuel
    for e, rope in ipairs({ self.siphon, self.blow }) do
        local list, view = state[e == 1 and 'h1' or 'h2'], e == 1 and self.siphonView or self.blowView
        if list and #list == rope.count * 3 then
            local settled = true
            for i = 1, rope.count do
                local target = world(list, i * 3 - 2)
                local p = rope.shown and Vec.lerp(rope.p[i], target, k) or target
                if #(target - p) > 0.0005 then settled = false else p = target end
                rope.p[i] = p
            end
            rope.shown, rope.asleep = true, settled
            view:draw(true, fuel and fuel[e] / MM or 0.0)
        else
            rope.shown, rope.asleep = false, false
            view:draw(false)
        end
    end
    if fuel and self.siphon.shown then
        self.siphonView:fuel(self.fuelPieces, self.fuelFront, fuel[3] / MM, fuel[4] / MM, fuel[1] / MM)
    else
        drawLine(self.fuelPieces, nil)
        show(self.fuelFront, false)
        self.siphonView.fuelFrom = nil -- drawn whole once it shows again
    end

    for s = 1, 2 do
        local list, points = state['s' .. s], nil
        if list then
            points = {}
            for i = 1, #list // 3 do points[i] = world(list, i * 3 - 2) end
        end
        local pieces = {}
        for i = 1, STREAM_PIECES do pieces[i] = self.streamPieces[(s - 1) * STREAM_PIECES + i] end
        drawLine(pieces, points)
    end

    -- The fuel cap's strap, to its eye.
    local fcap = state.fcap
    if fcap and fuelCap then
        local target = readPos(fcap, 2)
        self.fuelEye = self.fuelEye and Vec.lerp(self.fuelEye, target, k) or target
        local sag = fcap[1] == 1 and vec3(0.0, -1.0, 0.0) or vec3(0.0, -1.0, -0.3)
        local points = strapPoints(FILLER.tether.anchor, self.fuelEye, FILLER.tether.length, Vec.normalize(sag), STRAP_PIECES)
        for i, p in ipairs(points) do points[i] = scene:toWorld(p) end
        drawLine(self.fuelStrap, points, Mat.apply(scene.rot, vec3(0.0, -1.0, 0.0)))
    else
        drawLine(self.fuelStrap, nil)
    end

    local carry = state.carry
    if carry then
        self.carryPose = ease(self.carryPose, pose(carry, 1), k)
        put(self.carried, self.carryPose.pos, self.carryPose.rot)
    else
        self.carryPose = nil
        show(self.carried, false)
    end

    -- The can, its cap and the cap's strap (can space).
    local can = state.can
    if can then
        self.canPose = ease(self.canPose, pose(can, 1), k)
        self.capPose = ease(self.capPose, { pos = readPos(can, 11), rot = readRot(can, 14) }, k)
        local target = readPos(can, 20)
        self.canEye = self.canEye and Vec.lerp(self.canEye, target, k) or target
        local pos, rot = self.canPose.pos, self.canPose.rot
        put(self.canBody, pos, rot)
        put(self.canCapEntity, pos + Mat.apply(rot, self.capPose.pos), Mat.mul(rot, self.capPose.rot))
        local sag = can[10] == 1 and vec3(0.0, 0.0, 1.0) or Vec.normalize(vec3(-1.0, 0.0, 0.6))
        local points = strapPoints(CAN.tether.anchor, self.canEye, CAN.tether.length, sag, STRAP_PIECES)
        for i, q in ipairs(points) do points[i] = pos + Mat.apply(rot, q) end
        drawLine(self.canStrap, points, Mat.apply(rot, UP))
    else
        self.canPose, self.capPose, self.canEye = nil, nil, nil
        show(self.canBody, false)
        show(self.canCapEntity, false)
        drawLine(self.canStrap, nil)
    end

    local funnel = state.funnel
    if funnel then
        self.funnelPose = ease(self.funnelPose, pose(funnel, 1), k)
        drawFunnelAt(self, self.funnelPose.pos, self.funnelPose.rot, funnel[10] / 10, funnel[11] / MM, funnel[12] == 1)
    else
        self.funnelPose = nil
        drawFunnelAt(self, nil)
    end
end

function SiphonView:destroy()
    self.siphonView:destroy()
    self.blowView:destroy()
    for _, list in ipairs({ self.fuelPieces, self.fuelStrap, self.canStrap, self.streamPieces, self.spoutEntities }) do
        for _, entity in ipairs(list) do delete(entity) end
    end
    for _, entity in ipairs({ self.fuelFront, self.carried, self.canBody, self.canCapEntity, self.funnelEntity,
        self.nozzleEntity, self.poolEntity }) do
        delete(entity)
    end
end

function SiphonProps:destroy()
    self.siphonView:destroy()
    self.blowView:destroy()
    for _, list in ipairs({ self.fuelStrap, self.canStrap, self.fuelPieces, self.streamPieces, self.dropEntities, self.spoutEntities }) do
        for _, entity in ipairs(list) do delete(entity) end
    end
    -- Some of these are nil by now (ipairs would stop at the first).
    local single = table.pack(self.fuelFront, self.funnelEntity, self.nozzleEntity, self.poolEntity, self.carried,
        self.ghostEntity, self.canBody, self.canCapEntity)
    for i = 1, single.n do
        if single[i] then delete(single[i]) end
    end
    self.scene:destroy()
end
