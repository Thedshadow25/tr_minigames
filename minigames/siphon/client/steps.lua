--[[
    The siphon's setup and pack-up, one step at a time (game.lua runs them, the blow method and the
    flow are in game.lua). Each step is { enter = fn(game), update = fn(game, dt), packing? }.

    Setup:   place, carry, putdown, cancap, funnel, walk, fillercap, hose, feed, canhose, blowhose
    Blowing: prime, flow
    Pack-up: unpack, fillercapon, walkcan, canout, funnelout, cancapon, pickup (ESC skips the rest)
]]

local RIG = Siphon.rig
local FILLER, CAN, PUTDOWN, FUNNEL = RIG.filler, RIG.can, RIG.putdown, RIG.funnel
local Game = Siphon.Game
local steps = Game.steps
local sound = Game.sound
local FPS = Game.FPS
local function t(key, vars) return TR.locale.t('siphon.' .. key, vars) end

Game.ORDER = {
    'place', 'carry', 'putdown', 'cancap', 'funnel', 'walk', 'fillercap', 'hose', 'feed', 'canhose', 'blowhose',
    'prime', 'flow',
    'unpack', 'fillercapon', 'walkcan', 'canout', 'funnelout', 'cancapon', 'pickup',
}

local DOWN = vec3(0.0, 0.0, -1.0)
local HOLD_FRAME = PUTDOWN.release + 4 -- the putdown clip held here: crouched by the can, hand off the bar
local PLACE_MAX = 1.0                  -- metres along the ground from the filler the can may stand
local ROTATE = 15.0                    -- degrees the can turns per wheel notch
local PULL_SPEED = 0.3
local WHEEL_STEP = 0.02
local SEND_TIME = 0.75                 -- seconds a clicked hose end takes to its hole
local FEED_SPEED = 0.32                -- metres a second a hose goes down the filler by itself
local FEED_PAST = 0.07                 -- metres past where it reaches the fuel it is pushed
local CAN_SPEED = 0.25                 -- metres a second it goes down into the can (and comes out)
local CAN_PAST = 0.03                  -- metres deeper than the flow needs (Game.GOOD_DEPTH) it goes
local BENDS = { 0.12, 0.22 }           -- metres down the filler neck where the hose bumps round a bend
local BLOW_DEPTH = 0.09
local SEAT_HIGH = 0.03                 -- metres over the neck the nozzle's tip is when the funnel is lined up
local DROP_TIME = 0.4                  -- seconds it slides down into the neck
local STRAIGHTEN = 0.15                -- metres from over the neck the spout starts to straighten
local LAY_TIME = 0.9                   -- seconds the siphon hose's end takes from over the can to the ground

-- The setup's checklist on the HUD: which steps belong to which entry.
local GROUPS = {
    { label = 'tool_can', from = 'place', to = 'cancap' },
    { label = 'tool_funnel', from = 'funnel', to = 'funnel' },
    { label = 'tool_cap', from = 'walk', to = 'fillercap' },
    { label = 'tool_hose', from = 'hose', to = 'canhose' },
    { label = 'tool_blow', from = 'blowhose', to = 'blowhose' },
}

local function indexOf(name)
    for i, step in ipairs(Game.ORDER) do if step == name then return i end end
    return 0
end

local function checklist(self)
    local at = indexOf(self.step)
    local tools = {}
    for i, group in ipairs(GROUPS) do
        local from, to = indexOf(group.from), indexOf(group.to)
        tools[i] = { label = t(group.label), done = at > to, active = at >= from and at <= to }
    end
    self.tools = tools
end

local function hint(self, key, keys, sub)
    keys = keys or {}
    local packing = steps[self.step] and steps[self.step].packing
    keys[#keys + 1] = { key = 'ESC', label = t(packing and 'key_skip' or 'give_up') }
    self.hint = { text = t(key), sub = sub, keys = keys }
    if not packing and indexOf(self.step) < indexOf('prime') then checklist(self) end
end

-- Shared hands ------------------------------------------------------------------------------------

---Turning a cap of `radius` metres: hold LMB on it and circle. h = { screw }. Returns the screw's events.
function Game:screwStep(h, centre, radius)
    local events = {}
    -- The ring goes round the cap's rim as it is on screen, and anywhere on the cap picks it.
    local size = self:screenSize(centre, radius * 1.15)
    local _, height = GetActiveScreenResolution()
    if self.holding == h and not self.down then self.holding = nil end
    if not h.screw.done and self.holding ~= h then
        h.angle = nil
        if self:pixels(centre) < math.max(28, size * height) then
            self.cursor = 3
            if self.pressed then self.holding = h end
        end
    end
    if self.holding == h then
        self.cursor = 4
        events = self:circle(h, centre)
    end
    self:mark('cap', centre, { progress = math.floor(h.screw:progress() * 28) / 28, spin = self.holding == h,
        clockwise = h.screw.way == 'on', size = math.floor(size * 1000 + 0.5) / 1000 })
    return events
end

---The way a hose end is carried from `from` to a hole at `target` it goes into along `into` (world): up
---off where it lies, over, and down in line with the hole. A smooth curve (Rope.path: at(s), length).
function Game.sendPath(from, target, into)
    local before = target - into * 0.08 -- just outside the hole, lined up with it
    local up = math.max(from.z, before.z) + 0.15
    local a, b = vec3(from.x, from.y, up), before - into * 0.12 + vec3(0.0, 0.0, 0.04)
    local points = {}
    for k = 0, 16 do
        local t = k / 16
        local u = 1.0 - t
        points[#points + 1] = from * (u * u * u) + a * (3.0 * u * u * t) + b * (3.0 * u * t * t) + before * (t * t * t)
    end
    points[#points + 1] = target
    return Rope.path(points)
end

---Hose end e (1 or 2) of `rope`: clicked, it goes to `target` (world) by itself and lines up to go in along
---`into`. `label`: what its marker says. Returns true the frame it gets there (its pins let go).
function Game:sendEnd(dt, rope, e, target, into, label)
    local i = e == 1 and 1 or rope.count
    local j = e == 1 and 2 or rope.count - 1
    local s = self.sending
    if not s then
        self:mark('end', rope.p[i], { kind = 'label', text = label })
        if self:pixels(rope.p[i]) < 40 then
            self.cursor = 3
            if self.pressed then
                local at, length = Game.sendPath(rope.p[i], target, into)
                self.sending = { at = at, length = length, t = 0.0, rope = rope, i = i, j = j }
                sound('sf_hose_grab', 0.7)
            end
        end
        return false
    end

    s.t = math.min(1.0, s.t + dt / SEND_TIME)
    local k = s.t * s.t * (3.0 - 2.0 * s.t)
    local pin = s.at(s.length * k)
    local ahead = s.at(math.min(s.length, s.length * k + 0.03))
    local dir = #(ahead - pin) > 1e-4 and Vec.normalize(ahead - pin) or into
    rope.pins[i], rope.pins[j] = pin, pin - dir * rope.seg -- the hose comes behind the end, the way it goes
    if s.t < 1.0 then return false end
    rope.pins[i], rope.pins[j] = nil, nil
    self.sending = nil
    return true
end

---How deep the siphon hose can go into the can (past the top of its neck) with what is left of it
---outside the filler, down through the funnel.
function Game:canReach()
    local props, rope = self.props, self.props.siphon
    local fed = rope.ends[1] and rope.ends[1].fed or 0.0
    local span = #(props:mouth() - props:canTarget())
    return Clamp(rope.length - fed - span * 1.08 - 0.05 - props:aboveNeck() - props:overRimLength(), 0.0,
        props.neckDepth - 0.005)
end

---The can in the right hand while it is carried and set down, by the putdown clip's frame. Over the
---last frames before it is let go it settles exactly where it was meant to go.
function Game:carryCan(frame)
    local ped = PlayerPedId()
    local heading = GetEntityHeading(ped)
    local f = Clamp(frame, 0.0, PUTDOWN.release)
    local i = math.floor(f)
    local list = PUTDOWN.canFromHand
    local offset = Vec.lerp(list[i + 1], list[math.min(i + 2, #list)], f - i)
    local pos = self:hand() + Mat.apply(Mat.axis('z', heading), offset)
    local rot = Mat.axis('z', heading + PUTDOWN.canHeading)

    local settle = Clamp((f - (PUTDOWN.release - 6)) / 6, 0.0, 1.0)
    if settle > 0 and self.canPos then
        pos = Vec.lerp(pos, self.canPos, settle)
        rot = Mat.blend(rot, Mat.axis('z', self.canHeading), settle)
    end
    self.props:carry(pos, rot)
end

---Where the player stands to put the can down at pos turned to canHeading, and which way they face.
function Game:standSpot(pos, canHeading)
    local heading = canHeading - PUTDOWN.canHeading
    local rest = PUTDOWN.canRest
    local spot = pos - Mat.apply(Mat.axis('z', heading), vec3(rest.x, rest.y, 0.0))
    return vec3(spot.x, spot.y, pos.z - rest.z), heading
end

-- Place: where the can goes -------------------------------------------------------------------------

local function probe(a, b, flags, ignore)
    local _, hit, pos, _, entity = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, flags, ignore, 7))
    if hit == true or hit == 1 then return pos, entity end
end

---The ground under the cursor (world), or nil; and 'spot_car' when it points at the car.
function Game:spotUnderCursor()
    local props = self.props
    local origin, dir = props.scene:ray(self.mx, self.my)
    local pos, entity = probe(props:filler(origin), props:filler(origin + dir * 12.0), 1 | 2 | 16, PlayerPedId())
    if not pos then return nil end
    if entity == self.vehicle then return pos, 'spot_car' end
    local found, ground = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z + 0.5, false)
    return vec3(pos.x, pos.y, found and ground or pos.z)
end

---Would the can at pos turned to heading be in the ped's legs once it kneels (or stands) at the filler?
---The legs are capsules from the clip (rig.lua body, ped space), the can a box from the ground up.
function Game:canInLegs(pos, heading)
    local place = self.place
    local body = RIG.clips[place.clip] and RIG.clips[place.clip].body
    if not body then return false end
    local ped, can = Mat.axis('z', place.heading), Mat.axis('z', heading)
    local hx, hy, top = CAN.size.x / 2, CAN.size.y / 2, CAN.size.z
    for _, c in ipairs(body) do
        local a, b, r = place.spot + Mat.apply(ped, c[1]), place.spot + Mat.apply(ped, c[2]), c[3]
        for k = 0, 8 do
            local q = Vec.unrotate(can, Vec.lerp(a, b, k / 8) - pos)
            if math.abs(q.x) < hx + r and math.abs(q.y) < hy + r and q.z > -r and q.z < top + r then return true end
        end
    end
    return false
end

---Can the can stand at pos turned to heading? Returns ok, or false and why.
function Game:checkSpot(pos, heading)
    local props, place = self.props, self.place
    local rot = Mat.axis('z', heading)
    local hx, hy = CAN.size.x / 2, CAN.size.y / 2
    local corners = { vec3(-hx, -hy, 0.0), vec3(hx, -hy, 0.0), vec3(-hx, hy, 0.0), vec3(hx, hy, 0.0) }

    for _, c in ipairs(corners) do
        if props:insideCar(pos + Mat.apply(rot, c), 0.04) then return false, 'spot_car' end
    end
    local paint = place.paint
    if #(vec3(pos.x - paint.x, pos.y - paint.y, 0.0)) > PLACE_MAX then return false, 'spot_far' end
    if math.abs(pos.z - place.ground) > 0.35 then return false, 'spot_uneven' end
    for _, c in ipairs(corners) do
        local p = pos + Mat.apply(rot, c)
        local found, ground = GetGroundZFor_3dCoord(p.x, p.y, pos.z + 0.4, false)
        if not found or math.abs(ground - pos.z) > 0.06 then return false, 'spot_uneven' end
    end

    local ped = PlayerPedId()
    if probe(pos + vec3(0.0, 0.0, CAN.size.z + 0.2), pos + vec3(0.0, 0.0, 0.06), 1 | 2 | 16, ped) then
        return false, 'spot_blocked'
    end
    -- The hose's way from the filler to the can's neck.
    local mouth = props:mouth() + props:fillerDir(vec3(0.0, -0.06, 0.0))
    if probe(mouth, pos + Mat.apply(rot, CAN.neckPath[1]) + vec3(0.0, 0.0, 0.05), 1 | 16, ped) then
        return false, 'spot_blocked'
    end

    if self:canInLegs(pos, heading) then return false, 'spot_legs' end

    local stand = self:standSpot(pos, heading)
    if props:insideCar(stand, 0.3) then return false, 'spot_no_room' end
    if probe(stand, stand + (pos - stand) * 0.8, 1 | 2 | 16, ped) then return false, 'spot_no_room' end
    return true
end

steps.place = {
    enter = function(self)
        self.canHeading = self.place.heading + PUTDOWN.canHeading -- the player faces the car to put it down
        local pos, target, fov = self:shotPlace()
        self:shot(pos, target, fov, false, 2.6)
    end,
    update = function(self, dt)
        if self.wheel ~= 0 then self.canHeading = self.canHeading + self.wheel * ROTATE end
        if self:key('left') then self.canHeading = self.canHeading + 90.0 * dt end
        if self:key('right') then self.canHeading = self.canHeading - 90.0 * dt end

        local pos, why = self:spotUnderCursor()
        local ok = false
        if pos and not why then
            local last = self.checked
            if last and #(last.pos - pos) < 0.01 and math.abs(last.heading - self.canHeading) < 0.5 then
                ok, why = last.ok, last.why
            else
                ok, why = self:checkSpot(pos, self.canHeading)
                self.checked = { pos = pos, heading = self.canHeading, ok = ok, why = why }
            end
        end

        self.props:ghost(pos, self.canHeading)
        if pos then
            local r, g, b = 90, 200, 120
            if not ok then r, g, b = 230, 80, 70 end
            DrawMarker(25, pos.x, pos.y, pos.z + 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.62, 0.62, 0.62, r, g, b, 150,
                false, false, 2, false, nil, nil, false)
        end

        if self.pressed then
            if ok then
                self.canPos = pos
                self.props:ghost(nil)
                return self:go('carry')
            end
            self:flash(why or 'spot_none', 'muted', 1400)
        end

        hint(self, 'hint_place', { { key = 'LMB', label = t('key_place') }, { key = 'A/D', label = t('key_rotate') } },
            t(why or 'place_sub'))
    end,
}

-- Carry and put the can down ---------------------------------------------------------------------

steps.carry = {
    enter = function(self)
        self.stand, self.pedHeading = self:standSpot(self.canPos, self.canHeading)
        self.arrived = self:walkTo(self.stand, self.pedHeading)
        self:play('putdown', 49, 4.0) -- upper body only: the arm holds the can while the legs walk
        self:frame(self.canPos + vec3(0.0, 0.0, 0.3), GetEntityCoords(PlayerPedId()), false, 55.0, 0.55)
    end,
    update = function(self)
        self:scrub('putdown', 0.0, 49)
        self:carryCan(0)
        if self.arrived() then return self:go('putdown') end
        hint(self, 'hint_carry')
    end,
}

steps.putdown = {
    enter = function(self)
        self.frameAt = 0.0
        self:play('putdown', 2, 8.0)
    end,
    update = function(self, dt)
        local before = self.frameAt
        self.frameAt = math.min(HOLD_FRAME, before + dt * FPS)
        self:scrub('putdown', self.frameAt / PUTDOWN.length, 2)
        if self.frameAt < PUTDOWN.release then
            self:carryCan(self.frameAt)
        elseif before < PUTDOWN.release then
            self.props:setCan(self.canPos, self.canHeading)
            sound('sf_can_down')
            sound('sf_hose_drop', 0.5)
        end
        if self.frameAt >= HOLD_FRAME then return self:go('cancap') end
        hint(self, 'hint_putdown')
    end,
}

-- Open the can -------------------------------------------------------------------------------------

steps.cancap = {
    enter = function(self)
        self.screwing = { screw = Siphon.Screw.new(CAN.cap.turns, 'off') }
        self:canShot()
    end,
    update = function(self)
        self:scrub('putdown', HOLD_FRAME / PUTDOWN.length, 2)
        local props = self.props
        local cap, screw = props.canCap, self.screwing.screw
        for _, e in ipairs(self:screwStep(self.screwing, props:canCapCentre(), CAN.cap.radius)) do
            if e == 'tick' then sound('sf_cap_thread', 0.8) end
            if e == 'free' then
                sound('sf_cap_off')
                cap.off = true
                props:moveCap('canCap', 0.45, vec3(0.0, 0.0, 0.05))
                self.partAt = self.now
            end
        end
        if not cap.off then cap.turn, cap.out = screw:rotation(), CAN.cap.travel * screw:progress() end
        if self.partAt and self:since(self.partAt) > 0.6 then return self:go('funnel') end
        hint(self, 'hint_cancap', { { key = 'LMB', label = t('key_turn') } })
    end,
}

-- The funnel into the can's neck: picked up off the ground, carried over the neck (the spout
-- straightening as it lines up) and let go, it slides down into it.

---Where the middle of the funnel's bowl is once it is lined up over the neck, ready to drop in (world).
function Game:funnelOver()
    return self.props:can(FUNNEL.seat + vec3(0.0, 0.0, SiphonProps.SPOUT + SEAT_HIGH) + FUNNEL.hold)
end

---Keeps the funnel held by the middle of its bowl at p clear of the ground and of the can (its bent
---spout hangs below the bowl).
function Game:funnelClear(p)
    local props = self.props
    p = self:keepOut(p, 0.2)
    local q = Vec.unrotate(props.canRot, p - props.canPos)
    local hx, hy = CAN.size.x / 2 + 0.1, CAN.size.y / 2 + 0.1
    if math.abs(q.x) < hx and math.abs(q.y) < hy and q.z < CAN.size.z + 0.15 then
        p = props:can(vec3(q.x, q.y, CAN.size.z + 0.15))
    end
    return p
end

steps.funnel = {
    enter = function(self)
        self:frame(self:funnelOver(), self.props:funnelCentre(), true, 50.0, 0.6)
    end,
    update = function(self)
        self:scrub('putdown', HOLD_FRAME / PUTDOWN.length, 2)
        local props = self.props
        local funnel = props.funnel

        if self.part == 'drop' then
            -- Straight up over the neck, then down into it.
            local k = Clamp((self:since(self.partAt) - 0.2) / DROP_TIME, 0.0, 1.0)
            funnel.lift = (SiphonProps.SPOUT + SEAT_HIGH) * (1.0 - k * k * (3.0 - 2.0 * k))
            if k >= 1.0 then
                sound('sf_funnel_in')
                self.part, self.partAt = 'in', self.now
            end
            return hint(self, 'hint_funnel')
        elseif self.part == 'in' then
            if self:since(self.partAt) > 0.35 then return self:go('walk') end
            return hint(self, 'hint_funnel')
        end

        if self.holding and not self.down then
            -- Let go away from the neck: it goes back down where it lay.
            self.holding = nil
            props:layFunnel(0.35)
            sound('sf_funnel_down', 0.6)
        end
        if not self.holding then
            local centre = props:funnelCentre()
            self:mark('funnel', centre, { kind = 'label', text = t('label_funnel') })
            if self:pixels(centre) < 40 then
                self.cursor = 3
                if self.pressed then
                    self.holding = { funnel = true }
                    props:holdFunnel(centre)
                    sound('sf_funnel_grab', 0.7)
                end
            end
            return hint(self, 'hint_funnel', { { key = 'LMB', label = t('key_drag') } })
        end

        self.cursor = 4
        local over = self:funnelOver()
        local at = self:funnelClear(self:cursorAt(over))
        props:holdFunnel(at)
        -- Lining up over the neck, the spout bends straight to go in.
        local off = vec3(at.x - over.x, at.y - over.y, 0.0)
        funnel.bend = FUNNEL.spout.rest * Clamp((#off - 0.04) / STRAIGHTEN, 0.0, 1.0)
        self:mark('target', over, { progress = 1.0 })
        if #(at - over) < 0.04 or self:pixels(over) < 30 then
            self.holding = nil
            props:seatFunnel(SiphonProps.SPOUT + SEAT_HIGH)
            self.part, self.partAt = 'drop', self.now
        end
        hint(self, 'hint_funnel', { { key = 'LMB', label = t('key_drag') } })
    end,
}

-- To the filler and open it ------------------------------------------------------------------------

steps.walk = {
    enter = function(self)
        self.frameAt, self.arrived = HOLD_FRAME, nil
        self:frame(self.props:mouth(), GetEntityCoords(PlayerPedId()), false, 50.0, 0.4)
    end,
    update = function(self, dt)
        if not self.arrived then
            self.frameAt = self.frameAt + dt * FPS
            self:scrub('putdown', self.frameAt / PUTDOWN.length, 2)
            if self.frameAt >= PUTDOWN.length then self.arrived = self:walkTo(self.place.spot, self.place.heading) end
        elseif self.arrived() then
            self:play(self.work, 1, 4.0)
            return self:go('fillercap')
        end
        hint(self, 'hint_walk')
    end,
}

steps.fillercap = {
    enter = function(self)
        self.screwing, self.ratchets = { screw = Siphon.Screw.new(FILLER.cap.turns, 'off', true) }, 0
        self:fillerShot()
    end,
    update = function(self)
        local props = self.props
        local cap, screw = props.fuelCap, self.screwing.screw
        if not cap.hang then
            for _, e in ipairs(self:screwStep(self.screwing, props:fuelCapCentre(), FILLER.cap.radius)) do
                if e == 'tick' then sound('sf_cap_thread', 0.8) end
                if e == 'ratchet' then
                    sound('sf_ratchet')
                    self.ratchets = self.ratchets + 1
                    if self.ratchets % 4 == 2 then self:flash('wrong_way', 'muted') end
                end
                if e == 'free' then
                    sound('sf_cap_off')
                    sound('sf_cap_dangle', 0.8) -- let go on its strap, it swings against the car
                    props:hangFuelCap()
                    self.partAt = self.now
                end
            end
            if not cap.hang then cap.turn, cap.out = screw:rotation(), FILLER.cap.travel * screw:progress() end
        end
        if self.partAt and self:since(self.partAt) > 0.7 then return self:go('hose') end
        hint(self, 'hint_fillercap', { { key = 'LMB', label = t('key_turn') } })
    end,
}

-- The siphon hose: into the filler, down into the fuel, the other end into the can ----------------------

steps.hose = {
    enter = function(self)
        local props = self.props
        self:frame(props:mouth(), props.siphon.p[1], true, 50.0, 0.4)
    end,
    update = function(self, dt)
        local props = self.props
        local rope = props.siphon
        if self:sendEnd(dt, rope, 1, props:mouth(), props:fillerDir(vec3(0.0, 1.0, 0.0)), t('label_hose')) then
            rope:feed(1, props.siphonIn, 0.0)
            sound('sf_hose_in')
            return self:go('feed')
        end
        hint(self, 'hint_hose', { { key = 'LMB', label = t('key_take') } })
    end,
}

steps.feed = {
    enter = function(self)
        local props = self.props
        local bottom = props.siphonDepth - 0.02
        local fuelAt = Lerp(0.62, 0.30, Clamp(self.session.tank / 100, 0.0, 1.0))
        -- Pushed in like the can end: the flap and the neck's bends only bump it on the way down.
        self.feed = Siphon.Feed.new({ fuelAt = math.min(fuelAt, bottom - 0.08), bottom = bottom })
        self.feedGoal = math.min(self.feed.fuelAt + FEED_PAST, bottom)
        self:fillerShot(true)
    end,
    update = function(self, dt)
        local feed, props = self.feed, self.props
        local was = feed.depth
        local ds = math.min(FEED_SPEED * dt, self.feedGoal - was)
        local events = ds > 0 and feed:push(ds) or {}

        for _, e in ipairs(events) do
            if e == 'fuel' then
                sound('sf_plop')
                self:flash('in_fuel', 'success', 1800)
            end
            if e == 'bottom' then sound('sf_bump', 0.6) end
        end
        -- The flap gives as the tip goes by it, and a bend in the neck now and then.
        if was < FILLER.flapAt and feed.depth >= FILLER.flapAt then sound('sf_flap') end
        for _, at in ipairs(BENDS) do
            if was < at and feed.depth >= at then sound('sf_bump', 0.4) end
        end

        props.siphon:feed(1, props.siphonGuide, feed.depth + props.GUIDE)
        local open = FILLER.flapOpen * Clamp((feed.depth - FILLER.flapAt) / 0.02, 0.0, 1.0)
        props.flap = Lerp(props.flap, open, Clamp(dt * 15.0, 0.0, 1.0))
        if feed.depth ~= was then self.loops.feed = { 'sf_feed', { level = 0.7 } } end

        if feed.depth >= self.feedGoal - 1e-6 then
            self.partAt = self.partAt or self.now
            if self:since(self.partAt) > 0.4 then return self:go('canhose') end
        end

        local cm = math.floor(feed.depth * 100)
        self.meter = { label = t('tank_depth'), value = math.floor(feed.depth / feed.bottom * 50 + 0.5) / 50,
            zone = { (feed.fuelAt + 0.03) / feed.bottom, 1.0 } }
        hint(self, 'hint_feed', nil, t(feed.inFuel and 'deeper' or 'feed_sub', { cm = cm }))
    end,
}

steps.canhose = {
    enter = function(self)
        local rope = self.props.siphon
        rope:feed(1, self.props.siphonIn, self.feed.depth) -- the hand lets go of the hose outside the filler
        self:frame(self.props:canTarget(), rope.p[rope.count], true, 50.0, 0.6)
    end,
    update = function(self, dt)
        local props = self.props
        local rope = props.siphon
        if not self.part then
            if self:sendEnd(dt, rope, 2, props:canTarget(), DOWN, t('label_hose')) then
                props:intoCan(0.0)
                self.canDepth, self.part = 0.0, 'push'
                -- Deep enough that the flow can't flick it out, as far as the hose reaches.
                self.canGoal = math.min(Game.GOOD_DEPTH + CAN_PAST, self:canReach())
                sound('sf_hose_in')
                self:canShot()
            end
            return hint(self, 'hint_canhose', { { key = 'LMB', label = t('key_take') } })
        end

        local depth = math.min(self.canGoal, self.canDepth + CAN_SPEED * dt)
        if depth ~= self.canDepth then self.loops.feed = { 'sf_feed', { level = 0.6 } } end
        self.canDepth = depth
        props:intoCan(depth)
        if depth >= self.canGoal then
            self.partAt = self.partAt or self.now
            if self:since(self.partAt) > 0.35 then return self:go('blowhose') end
        end
        self.meter = { label = t('can_depth'), value = math.floor(depth / props.neckDepth * 50 + 0.5) / 50,
            zone = { Game.GOOD_DEPTH / props.neckDepth, 1.0 } }
        hint(self, 'hint_canpush')
    end,
}

-- The blow hose: in, the setup is done ----------------------------------------------------------------

steps.blowhose = {
    enter = function(self)
        self:frame(self.props:mouth(), self.props.blow.p[1], true, 50.0, 0.4)
    end,
    update = function(self, dt)
        local props = self.props
        if not self.part then
            if self:sendEnd(dt, props.blow, 1, props:mouth(), props:fillerDir(vec3(0.0, 1.0, 0.0)), t('label_blow')) then
                self.part, self.blowDepth = 'in', 0.0
                sound('sf_hose_in', 0.8)
            end
            return hint(self, 'hint_blowhose', { { key = 'LMB', label = t('key_take') } })
        end

        self.blowDepth = math.min(BLOW_DEPTH, self.blowDepth + dt * 0.25)
        props.blow:feed(1, props.blowIn, self.blowDepth)
        if self.blowDepth < BLOW_DEPTH then
            self.loops.feed = { 'sf_feed', { level = 0.4 } }
        elseif not self.asking and self.now >= (self.askAt or 0) then
            -- All set: the server starts the priming (it refuses a setup done faster than anyone could).
            self.asking = true
            self:request('tr_minigames:siphon:ready', {}, function(result)
                self.asking = false
                if result == 'ok' or result == 'ignored' then
                    self:go('prime')
                elseif result == 'too_soon' then
                    self.askAt = self.now + 1000
                end
            end, function()
                self.asking, self.askAt = false, self.now + 1000
            end)
        end
        hint(self, 'hint_blowhose')
    end,
}

-- Pack-up ------------------------------------------------------------------------------------------------

steps.unpack = {
    packing = true,
    enter = function(self)
        local props = self.props
        self.pullFrom = props.siphon.ends[1] and props.siphon.ends[1].fed or 0.0
        self.blowFrom = props.blow.ends[1] and props.blow.ends[1].fed or 0.0
        self:letGoBlowHose()
        props.streams[1], props.streams[2] = nil, nil
        self:play(self.work, 1, 4.0)
        self:fillerShot(true)
    end,
    update = function(self, dt)
        local props = self.props
        local seconds = self:since()
        local k = Clamp(seconds / 1.4, 0.0, 1.0)
        local fed = self.pullFrom * (1.0 - k)
        if k < 1.0 then
            props.siphon:feed(1, props.siphonIn, fed)
            self.loops.feed = { 'sf_feed', { level = 0.8 } }
        elseif props.siphon.ends[1] then
            props.siphon:feed(1, nil)
            sound('sf_drip', 0.7)
        end
        local kb = Clamp(seconds / 0.5, 0.0, 1.0)
        if kb < 1.0 then
            props.blow:feed(1, props.blowIn, self.blowFrom * (1.0 - kb))
        elseif props.blow.ends[1] then
            props.blow:feed(1, nil)
        end

        -- What is left in the hose runs on into the can; the flap springs shut behind it.
        props.fuel.from = math.min(props.fuel.to, props.fuel.from + dt * 1.4)
        if fed < FILLER.flapAt + 0.01 and props.flap > 1.0 then
            if props.flap > 30.0 and not self.flapShut then
                self.flapShut = true
                sound('sf_flap', 0.8)
            end
            props.flap = Lerp(props.flap, 0.0, Clamp(dt * 20.0, 0.0, 1.0))
        end

        if seconds > 1.8 then return self:go('fillercapon') end
        hint(self, 'hint_unpack')
    end,
}

steps.fillercapon = {
    packing = true,
    enter = function(self)
        self.screwing = { screw = Siphon.Screw.new(FILLER.cap.turns, 'on', true, 2) }
        self.props.flap = 0.0
        self:fillerShot()
    end,
    update = function(self)
        local props = self.props
        local cap, screw = props.fuelCap, self.screwing.screw
        if cap.hang then
            local centre = props:fuelCapCentre()
            self:mark('cap', centre, { kind = 'label', text = t('label_cap') })
            if self:pixels(centre) < 40 then
                self.cursor = 3
                if self.pressed then
                    cap.hang, cap.turn, cap.out = false, screw:rotation(), FILLER.cap.travel
                    props:moveCap('fuelCap', 0.3)
                    sound('sf_cap_tap')
                end
            end
            return hint(self, 'hint_fillercapon', { { key = 'LMB', label = t('key_take') } })
        end

        for _, e in ipairs(self:screwStep(self.screwing, props:fuelCapCentre(), FILLER.cap.radius)) do
            if e == 'tick' then sound('sf_cap_thread', 0.8) end
            if e == 'snug' then self:flash('click_it', 'default', 1800) end
            if e == 'ratchet' then sound('sf_ratchet') end
            if e == 'seated' then
                sound('sf_cap_on')
                self.partAt = self.now
            end
        end
        -- Every frame, the one it seats in too: else it stays a part-turn up.
        cap.turn, cap.out = screw:rotation(), FILLER.cap.travel * (1.0 - screw:progress())
        if self.partAt and self:since(self.partAt) > 0.5 then return self:go('walkcan') end
        hint(self, 'hint_screw_on', { { key = 'LMB', label = t('key_turn') } })
    end,
}

steps.walkcan = {
    packing = true,
    enter = function(self)
        self.arrived, self.frameAt = self:walkTo(self.stand, self.pedHeading), nil
        self:frame(self.props:canTarget(), GetEntityCoords(PlayerPedId()), false, 55.0, 0.55)
    end,
    update = function(self, dt)
        if not self.frameAt then
            if self.arrived() then self.frameAt = PUTDOWN.length end
        else
            -- Crouch down by the can.
            self.frameAt = math.max(HOLD_FRAME, self.frameAt - dt * FPS)
            self:scrub('putdown', self.frameAt / PUTDOWN.length, 2)
            if self.frameAt <= HOLD_FRAME then return self:go('canout') end
        end
        hint(self, 'hint_walkcan')
    end,
}

steps.canout = {
    packing = true,
    enter = function(self)
        self:canShot()
        self.canDepth = self.props:canDepth()
        self.laying = nil
    end,
    update = function(self, dt)
        self:scrub('putdown', HOLD_FRAME / PUTDOWN.length, 2)
        local props = self.props
        local rope = props.siphon
        local n = rope.count

        if not self.part then
            if not rope.ends[2] then
                self.part, self.partAt = 'out', self.now -- it was never put back after it jumped out
            elseif not self.pulling then
                self:mark('end', props:canTarget(), { kind = 'label', text = t('label_hose') })
                if self:pixels(props:canTarget()) < 40 then
                    self.cursor = 3
                    if self.pressed then
                        self.pulling = true
                        sound('sf_hose_grab', 0.6)
                    end
                end
            else
                self.loops.feed = { 'sf_feed', { level = 0.6 } }
                self.canDepth = math.max(0.0, self.canDepth - CAN_SPEED * 1.4 * dt)
                if self.canDepth <= 0.0 then
                    rope:feed(2, nil)
                    rope.pins[n] = props:canTarget() + vec3(0.0, 0.0, 0.1)
                    self.part, self.partAt = 'out', self.now
                    sound('sf_hose_out')
                else
                    props:intoCan(self.canDepth)
                end
            end
            return hint(self, 'hint_canout', { { key = 'LMB', label = t('key_take') } })
        end

        -- Held over the can a moment so the last of the fuel drips into it, then laid on the ground off the
        -- side the hose comes down (not across the top, where the cap goes back on).
        local seconds = self:since(self.partAt)
        local drips = math.floor(seconds / 0.3)
        if rope.pins[n] and not self.laying and drips > (self.drips or 0) and drips <= 3 then
            self.drips = drips
            props:drip(rope.p[n])
            sound('sf_drip', 0.6)
        end
        if self.laying == nil and (seconds > 1.0 or not rope.pins[n]) then
            self.laying = props:hoseLay() or false -- false: none of it is on the can, it stays where it is
            self.layAt = self.now
        end
        local lay = self.laying
        if lay then
            local k = Clamp(self:since(self.layAt) / LAY_TIME, 0.0, 1.0)
            if not lay.down then
                rope.pins[n] = lay.path(lay.length * k * k * (3.0 - 2.0 * k))
                if k >= 1.0 then
                    lay.down = true
                    props.slideOff = lay.slide
                    sound('sf_hose_drop', 0.6)
                end
            elseif self:since(self.layAt) > LAY_TIME + 0.15 then
                rope.pins[n] = nil
            end
            if self:since(self.layAt) > LAY_TIME + 0.4 then return self:go('funnelout') end
        elseif lay == false then
            rope.pins[n] = nil
            if self:since(self.layAt) > 0.3 then return self:go('funnelout') end
        end
        hint(self, 'hint_canout')
    end,
}

steps.funnelout = {
    packing = true,
    enter = function(self)
        self:canShot()
    end,
    update = function(self, dt)
        self:scrub('putdown', HOLD_FRAME / PUTDOWN.length, 2)
        local props = self.props
        local funnel = props.funnel
        if not self.part and funnel.where ~= 'can' then return self:go('cancapon') end -- it never went in

        -- Fuel standing in it runs out as it comes up: into the full can, and over its end.
        if funnel.level > 0.0 and funnel.lift > 0.0 then
            funnel.level = math.max(0.0, funnel.level - dt * 0.8)
            local neck = props:neckTop()
            local side = props:can(vec3(CAN.size.x / 2 + 0.006, 0.0, CAN.top - 0.02))
            local foot = props:can(vec3(CAN.size.x / 2 + 0.02, 0.0, 0.004))
            props.streams[2] = funnel.level > 0.0
                and { neck, Vec.lerp(neck, side, 0.5) + vec3(0.0, 0.0, 0.01), side, Vec.lerp(side, foot, 0.5), foot } or nil
            self:puddle(self:canEnd(), 'can', 0.5)
            self.loops.spill = { 'sf_spill', { level = 0.7 } }
        end

        if not self.part then
            local out = SiphonProps.SPOUT + SEAT_HIGH
            local pull = -self.wheel * WHEEL_STEP
            if self:key('down') then pull = pull + PULL_SPEED * dt end
            if self.down then pull = pull - self.dmy * 0.5 end
            local was = funnel.lift
            funnel.lift = Clamp(was + Clamp(pull, -0.03, 0.03), 0.0, out)
            if was <= 0.0 and funnel.lift > 0.0 then sound('sf_funnel_out') end
            if funnel.lift >= out then self.part, self.partAt = 'out', self.now end
            self:mark('funnel', props:funnelCentre(), { kind = 'label', text = t('label_funnel') })
            return hint(self, 'hint_funnelout', { { key = 'S', label = t('key_pull') } })
        end

        -- Held over the can a moment while the spout drips, then put down by the kit.
        local seconds = self:since(self.partAt)
        local drips = math.floor(seconds / 0.3)
        if drips > (self.drips or 0) and drips <= 2 then
            self.drips = drips
            props:drip(props:nozzleTip())
            sound('sf_drip', 0.5)
        end
        if seconds > 0.9 and funnel.where == 'can' then
            funnel.level = 0.0
            props.streams[2] = nil
            props:layFunnel(0.45)
            sound('sf_funnel_down', 0.6)
        end
        if seconds > 1.4 then return self:go('cancapon') end
        hint(self, 'hint_funnelout')
    end,
}

steps.cancapon = {
    packing = true,
    enter = function(self)
        self.screwing = { screw = Siphon.Screw.new(CAN.cap.turns, 'on') }
        self:canShot()
    end,
    update = function(self)
        self:scrub('putdown', HOLD_FRAME / PUTDOWN.length, 2)
        local props = self.props
        local cap, screw = props.canCap, self.screwing.screw
        if cap.off then
            local centre = props:canCapCentre()
            self:mark('cap', centre, { kind = 'label', text = t('label_cap') })
            if self:pixels(centre) < 36 then
                self.cursor = 3
                if self.pressed then
                    cap.off, cap.turn, cap.out = false, screw:rotation(), CAN.cap.travel
                    props:moveCap('canCap', 0.4, vec3(0.0, 0.0, 0.05))
                    sound('sf_cap_tap')
                end
            end
            return hint(self, 'hint_cancapon', { { key = 'LMB', label = t('key_take') } })
        end

        for _, e in ipairs(self:screwStep(self.screwing, props:canCapCentre(), CAN.cap.radius)) do
            if e == 'tick' then sound('sf_cap_thread', 0.8) end
            if e == 'seated' then
                sound('sf_cap_on')
                self.partAt = self.now
            end
        end
        -- Every frame, the one it seats in too: else it stays a part-turn up.
        cap.turn, cap.out = screw:rotation(), CAN.cap.travel * (1.0 - screw:progress())
        if self.partAt and self:since(self.partAt) > 0.4 then return self:go('pickup') end
        hint(self, 'hint_screw_on', { { key = 'LMB', label = t('key_turn') } })
    end,
}

steps.pickup = {
    packing = true,
    enter = function(self)
        self.props.kitShown = false -- the hoses and the funnel go back in the bag
        sound('sf_hose_grab', 0.6)
        self.frameAt, self.lifted = HOLD_FRAME, false
        self:frame(self.props:neckTop(), GetEntityCoords(PlayerPedId()), false, 55.0, 0.55)
    end,
    update = function(self, dt)
        self.frameAt = math.max(0.0, self.frameAt - dt * FPS)
        self:scrub('putdown', self.frameAt / PUTDOWN.length, 2)
        if self.frameAt <= PUTDOWN.release and not self.lifted then
            self.lifted = true
            self.props:liftCan()
            sound('sf_can_up')
        end
        if self.lifted then self:carryCan(self.frameAt) end
        if self.frameAt <= 0.0 then
            self.props:carry(nil) -- and back in the bag
            return self:finish('done', 200)
        end
        hint(self, 'hint_pickup')
    end,
}
