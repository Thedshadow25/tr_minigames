--[[
    The siphon minigame.

        local result, litres, can, spilled = Siphon.run(vehicle, session)

    The setup, hands on (steps.lua): put the jerry can down, open it and put the funnel in its neck, open
    the car's fuel cap, drag the siphon hose to the filler and push it down the neck past the flap into
    the fuel, put the other end deep into the can through the funnel, add the blow hose. Then the blow
    method (this file): puffs push the fuel up and over until it runs by itself, the can fills (a full
    can backs up into the funnel, then runs over), E pulls the hose. Then everything is packed up again
    (steps.lua).

    The server decides how many puffs it takes, checks the setup took long enough and counts the litres
    from its own clock; this file shows it. Fuel that misses the can spills on the ground (and burns).

    result: 'done' (litres, can percent, spilled), 'gave_up', 'cancelled' or a reason.
]]

local cfg = Config.siphon
local RIG = Siphon.rig
local function t(key, vars) return TR.locale.t('siphon.' .. key, vars) end

local Game = {}
Game.__index = Game
Siphon.Game = Game -- for tests and steps.lua

local DICT = 'tr_sf_anims'
local FPS = 30
local PUFFS_IN_CLIP = 3          -- the blow clip loops three puffs of rising effort
-- Breath, in a puff's own time (0..1, see props/siphon/anim.py breath()): in until READY, blowing
-- from READY to BLOWN, the blow eases off by 1.
local READY, BLOWN = 0.36, 0.62
local INHALE_TIME = 0.9          -- seconds to breathe in
local EXHALE_TIME = 0.7          -- seconds for the blow to ease off after letting go
local BLOW_IN_TIME = 0.45        -- seconds for the cheeks to fill as the blow starts

-- The pressure meter while blowing: rises faster as it climbs, and each puff a little faster.
local PRESSURE_RATE = 0.42
local PRESSURE_GROWTH = 0.08     -- per good puff
local ZONE_WIDTH = { 0.2, 0.13 } -- the green zone: first puff, last puff
local FUEL_SPEED = 0.8           -- metres a second the fuel runs down the hose once it flows
local DECAL_EVERY = 400          -- ms between petrol decals while fuel spills

Game.DICT, Game.FPS = DICT, FPS

local KEY = {
    click = 24, alt = 25, blow = 22, use = 38, pause = 200, back = 194,
    up = 32, down = 33, left = 34, right = 35, wheelUp = 241, wheelDown = 242,
}
Game.KEY = KEY

local LOOPS = { 'blow', 'gurgle', 'pour', 'spill', 'feed' } -- their ids are 'siphon:<loop>'

local LIPS = { 61839, 20623 }   -- FB_UpperLip_045, FB_LowerLip_045
local RIGHT_HAND = 28422        -- PH_R_Hand
local LEFT_HAND = 60309         -- PH_L_Hand
-- Bones that would fill a close-up if the camera is right by them.
local BODY = { 31086, 39317, 24818, 24817, 11816, 40269, 45509, 28252, 61163, 57005, 18905, 36864, 63931 }

---@param name string sound on the resource's page (engine/client/sounds.lua)
---@param volume? number 0..1 of the usual
function Game.sound(name, volume)
    TR.ui.sound.play(name, Config.volume * (volume or 1.0))
    -- Players nearby hear it too (TR.mirror).
    local game = Siphon.current
    if game and game.mirror then game.mirror:sound(name) end
end
local sound = Game.sound

-- Setup -----------------------------------------------------------------------------------------

function Game.new(vehicle, session, place)
    local work = place.clip:gsub('blow', 'work')
    return setmetatable({
        vehicle = vehicle,
        session = session,
        place = place,
        clip = place.clip,
        work = work,
        now = GetGameTimer(),
        running = true,
        queue = {},
        loops = {},
        markers = {},
        cursor = 1,

        strikes = 0,
        progress = 0,     -- good puffs counted so far

        stage = 'inhale', -- while priming: inhale, ready, blowing, exhale; settle and rest once it runs
        puffIndex = 0,
        breath = 0.0,
        pressure = 0.0,
        zone = { 0.6, 0.8 },
        rate = PRESSURE_RATE,

        spilled = 0.0,    -- litres that missed the can (the hose jumped out of it)
        spills = {},      -- where, for the server: { { at, share } }
        canLitres = session.can / 100 * session.canLitres,
    }, Game)
end

function Game:setup()
    RequestAnimDict(DICT)
    local deadline = GetGameTimer() + 3000
    while not HasAnimDictLoaded(DICT) and GetGameTimer() < deadline do Wait(0) end
    if not HasAnimDictLoaded(DICT) then error('the siphon animations did not load', 0) end

    local ped = PlayerPedId()
    SetCurrentPedWeapon(ped, joaat('WEAPON_UNARMED'), true) -- the can comes out of the bag, not the hand
    ClearPedTasks(ped)

    self.props = SiphonProps.new(self.vehicle, self.place)
    -- Players nearby see it (TR.mirror; the server started the mirror with the session).
    self.mirror = Mirror.sender(self.props.scene, 'siphon')
    self.mirror.collect = function(sender) self:mirrorState(sender) end
    local pos, target, fov = self:shotPlace()
    self.props.scene:createCamera(pos, target, fov)
    self:go(Game.ORDER[1])
end

function Game:cleanup()
    if self.mirror then self.mirror:stop() end
    TR.ui.hud.hide()
    for _, id in ipairs(LOOPS) do TR.ui.sound.stop('siphon:' .. id) end
    if self.props then self.props:destroy() end
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    ClearPedTasks(ped)
    RemoveAnimDict(DICT)
end

-- Server requests -----------------------------------------------------------------------------
-- Sent one at a time, in order, without blocking the frame loop.

---@param fail? function called when it wasn't delivered (timeout, rate limit)
function Game:request(name, args, cb, fail)
    self.queue[#self.queue + 1] = { name = name, args = args, cb = cb, fail = fail }
    if self.pending then return end
    self.pending = true

    CreateThread(function()
        while #self.queue > 0 and self.running and not self.ending do
            local job = table.remove(self.queue, 1)
            local result = table.pack(TR.callback.await(job.name, table.unpack(job.args, 1, job.args.n or #job.args)))
            if not self.running or self.ending then break end

            if result[1] == false then
                -- The server ended the attempt (expired, moved away, ...).
                self:finish(result[2] or 'no_session')
                break
            elseif result[1] == nil then
                self:flash(result[2] or 'try_again', 'error')
                if job.fail then job.fail() end
            elseif job.cb then
                job.cb(table.unpack(result, 1, result.n))
            end
        end
        self.pending = false
    end)
end

-- Endings -------------------------------------------------------------------------------------

function Game:finish(result, delay)
    if self.ending then return end
    self.ending = true
    self.result = result
    self.endAt = self.now + (delay or 0)
end

function Game:cancel()
    CreateThread(function() TR.callback.await('tr_minigames:siphon:cancel') end)
    self:finish('cancelled')
end

---@param tone? 'default' | 'success' | 'error' | 'muted'
function Game:flash(key, tone, ms, vars)
    TR.ui.hud.flash(t(key, vars), tone, math.floor(ms or 1600))
end

-- Steps -----------------------------------------------------------------------------------------
-- steps.lua fills Game.steps[name] = { enter = fn(game), update = fn(game, dt) }.

Game.steps = {}
Game.ORDER = {}

function Game:go(name)
    -- A hose end on its way somewhere is let go of (the next step may not want it there).
    local s = self.sending
    if s then s.rope.pins[s.i], s.rope.pins[s.j] = nil, nil end
    self.step, self.stepAt, self.holding, self.sending, self.pulling = name, self.now, nil, nil, nil
    self.part, self.partAt, self.drips, self.warned = nil, nil, nil, nil
    self.closeUp, self.focus, self.cursor = false, nil, 1
    local step = Game.steps[name]
    if step and step.enter then step.enter(self) end
end

function Game:nextStep()
    for i, name in ipairs(Game.ORDER) do
        if name == self.step then return self:go(Game.ORDER[i + 1]) end
    end
end

---Seconds since the current step (or part of it) began.
function Game:since(at) return (self.now - (at or self.stepAt)) / 1000 end

-- Camera --------------------------------------------------------------------------------------
-- Shots are in filler space. Close-ups hide the player's ped when it would fill the frame.

---@param closeUp? boolean hide the player's ped when it is in the way
function Game:shot(pos, target, fov, closeUp, speed)
    local scene = self.props.scene
    scene:moveCamera(pos, target)
    scene.fovGoal = fov or 50.0
    scene.camSpeed = speed or 3.2
    self.closeUp, self.focus = closeUp or false, nil
end

---A shot of world points a and b together, from outside the car and a little above. lateral: how far
---round to their side it looks from (more keeps the player at the filler out of the way).
function Game:frame(a, b, closeUp, fov, height, lateral)
    local props = self.props
    local pa, pb = props:toFiller(a), props:toFiller(b or a)
    local target = (pa + pb) * 0.5
    local span = #(pa - pb)
    local side = target.x >= 0 and 1 or -1
    local dir = Vec.normalize(vec3(side * (lateral or 0.35), -1.0, height or 0.45))
    local dist = math.max(0.45, span * 1.15 + 0.35) * 50.0 / (fov or 50.0)
    self:shot(target + dir * dist, target, fov or 50.0, closeUp)
    self.focus = { a, b or a }
end

---Looking down at the can's neck (or the funnel in it) from outside the car.
function Game:canShot(fov)
    local neck = self.props:toFiller(self.props:canTarget())
    self:shot(neck + vec3(0.0, -0.26, 0.36), neck + vec3(0.0, 0.0, -0.04), fov or 45.0, true)
end

---Close on the filler from outside.
function Game:fillerShot(wide)
    local k = wide and 1.5 or 1.0
    self:shot(vec3(-0.09 * k, -0.34 * k, 0.07 * k), vec3(0.0, 0.0, -0.015 * k), 42.0, true)
end

---Over the player's shoulder, looking down at the ground beside the car.
function Game:shotPlace()
    local height = self.place.paint.z - self.place.ground
    return vec3(0.35, -2.9, 1.95 - height), vec3(0.0, -0.75, -height), 55.0
end

---In a close-up the ped is hidden when it is between the camera and what the shot is of (as the
---hotwire hides the driver's legs): the cursor is the player's hands.
function Game:hidePed()
    local scene = self.props.scene
    if not self.closeUp or not scene.camPos then return end
    local cam = scene:toWorld(scene.camPos)
    local focus = self.focus or { scene:toWorld(scene.camTarget) }
    local ped = PlayerPedId()
    for _, bone in ipairs(BODY) do
        local p = GetPedBoneCoords(ped, bone, 0.0, 0.0, 0.0)
        if #(p - cam) < 0.5 then return SetEntityLocallyInvisible(ped) end
        for _, target in ipairs(focus) do
            local line = target - cam
            local len2 = Vec.dot(line, line)
            local k = len2 > 0 and Clamp(Vec.dot(p - cam, line) / len2, 0.0, 1.0) or 0.0
            if #(p - (cam + line * k)) < 0.22 then return SetEntityLocallyInvisible(ped) end
        end
    end
end

-- Picking ---------------------------------------------------------------------------------------

---Where a world point is on screen (0..1), or nil behind the camera.
function Game:screen(world)
    return self.props.scene:project(self.props:toFiller(world))
end

---How big `r` metres across the view at a world point looks, as a fraction of the screen's height.
function Game:screenSize(world, r)
    local scene = self.props.scene
    local p = self.props:toFiller(world)
    local ax = scene:project(p)
    local bx = scene:project(p + scene.camRot.x * r)
    if not ax or not bx then return 0.0 end
    local w, h = GetActiveScreenResolution()
    return math.abs(bx - ax) * w / h
end

---Pixels from the cursor to a world point (huge when it is off screen).
function Game:pixels(world)
    local x, y = self:screen(world)
    if not x then return math.huge end
    return Scene.pixels(x, y, self.mx, self.my)
end

---The point under the cursor on the plane through `through` that faces the camera (world).
function Game:cursorAt(through)
    local props = self.props
    local scene = props.scene
    local origin, dir = scene:ray(self.mx, self.my)
    local p = props:toFiller(through)
    local n = scene.camRot.y
    local d = Vec.dot(dir, n)
    if math.abs(d) < 1e-4 then return through end
    return props:filler(origin + dir * (Vec.dot(p - origin, n) / d))
end

---Keeps a carried thing out of the car's body and above the ground.
function Game:keepOut(p, r)
    local props = self.props
    local q = props:toFiller(p)
    local wall = props:wallAt(q.x, q.z)
    if wall and q.y > wall - r and q.y < wall + 0.3 then p = props:filler(vec3(q.x, wall - r, q.z)) end
    if props.ground then
        local g = props.ground(p.x, p.y) + r
        if p.z < g then p = vec3(p.x, p.y, g) end
    end
    return p
end

---Turning a cap by circling the cursor round it. h: { screw, angle }. Returns the screw's events.
function Game:circle(h, centre)
    local cx, cy = self:screen(centre)
    if not cx then return {} end
    local w, hgt = GetActiveScreenResolution()
    local dx, dy = (self.mx - cx) * w, (self.my - cy) * hgt
    if dx * dx + dy * dy < 100 then return {} end -- too close to the middle to read a direction

    local angle = math.atan(dy, dx)
    local events = {}
    -- Screen y points down: a clockwise circle as seen raises the angle.
    if h.angle then events = h.screw:turn(-AngleDelta(h.angle, angle)) end
    h.angle = angle
    return events
end

---A ring marker on a world point this frame.
function Game:mark(id, world, marker)
    local x, y = self:screen(world)
    if not x then return end
    marker.id, marker.kind = id, marker.kind or 'ring'
    marker.x, marker.y = math.floor(x * 2000 + 0.5) / 2000, math.floor(y * 2000 + 0.5) / 2000
    self.markers[#self.markers + 1] = marker
end

-- The ped -------------------------------------------------------------------------------------

---Plays one of the tr_sf_anims clips. scrub: held still, moved by Game:scrub.
function Game:play(clip, flags, blend)
    TaskPlayAnim(PlayerPedId(), DICT, clip, blend or 4.0, -(blend or 4.0), -1, flags or 1, 0.0, false, false, false)
    self.playing, self.scrubbing = clip, false
end

---Holds clip at phase (0..1), starting it if it isn't playing.
function Game:scrub(clip, phase, flags)
    local ped = PlayerPedId()
    if self.playing ~= clip or not IsEntityPlayingAnim(ped, DICT, clip, 3) then self:play(clip, flags or 2, 8.0) end
    SetEntityAnimSpeed(ped, DICT, clip, 0.0)
    SetEntityAnimCurrentTime(ped, DICT, clip, Clamp(phase, 0.0, 0.999))
    self.scrubbing, self.scrubPhase = true, Clamp(phase, 0.0, 0.999)
end

function Game:hand() return GetPedBoneCoords(PlayerPedId(), RIGHT_HAND, 0.0, 0.0, 0.0) end

function Game:lips()
    local ped = PlayerPedId()
    return (GetPedBoneCoords(ped, LIPS[1], 0.0, 0.0, 0.0) + GetPedBoneCoords(ped, LIPS[2], 0.0, 0.0, 0.0)) * 0.5
end

---Walks the ped to `spot` facing `heading`. Returns a function that is true once it is there.
function Game:walkTo(spot, heading)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    TaskGoStraightToCoord(ped, spot.x, spot.y, spot.z, 1.0, 8000, heading, 0.05)
    local deadline = self.now + 8000
    return function()
        local c = GetEntityCoords(ped)
        if #(vec3(c.x - spot.x, c.y - spot.y, 0.0)) > 0.12 and self.now < deadline then return false end
        ClearPedTasks(ped)
        SetEntityCoordsNoOffset(ped, spot.x, spot.y, spot.z, false, false, false)
        SetEntityHeading(ped, heading)
        FreezeEntityPosition(ped, true)
        return true
    end
end

-- Spills ----------------------------------------------------------------------------------------

---Fuel running onto the ground at `at` (world): a petrol puddle that grows (flammable), once in a while.
---later: only note where it will spill (for the server), the puddle shows once it does.
function Game:puddle(at, key, share, later)
    self.decals = self.decals or {}
    local d = self.decals[key]
    if not d then
        d = { at = at, size = 0.25, next = 0 }
        self.decals[key] = d
        if #self.spills < 3 then self.spills[#self.spills + 1] = { at = at, share = share or 1.0 } end
    end
    if later or self.now < d.next or not cfg.puddles then return end
    d.next, d.size = self.now + DECAL_EVERY, math.min(1.4, d.size + 0.06)
    AddPetrolDecal(at.x, at.y, at.z, 2.0, d.size, 1.0)
end

-- Priming: the blow method ----------------------------------------------------------------------

---A new green zone for the next puff: narrower as the hose fills.
function Game:newZone()
    local k = Clamp(self.progress / math.max(1, self.session.puffs - 1), 0.0, 1.0)
    local width = Lerp(ZONE_WIDTH[1], ZONE_WIDTH[2], k)
    local from = 0.5 + math.random() * (0.82 - width - 0.5)
    self.zone = { from, from + width }
    self.rate = PRESSURE_RATE * (1.0 + PRESSURE_GROWTH * self.progress) * (0.9 + math.random() * 0.2)
end

---The player let go (or blew far too hard): judge the puff and tell the server.
function Game:release()
    local kind = 'good'
    if self.pressure >= self.zone[2] then
        kind = 'hard'
    elseif self.pressure < self.zone[1] then
        kind = 'weak'
    end

    self.stage = 'exhale'
    self.pressure = 0.0

    if kind == 'weak' then self:flash('weak', 'muted', 1200) end
    if kind == 'hard' then
        -- Fuel sprays back up the hose into the mouth: it falls back to the tank.
        self:flash('gulp', 'error', 1800)
        ShakeCam(self.props.scene.cam, 'SMALL_EXPLOSION_SHAKE', 0.12)
        sound('sf_cough')
    end
    if kind == 'good' then self.gurgleUntil = self.now + 1400 end

    self:request('tr_minigames:siphon:puff', { kind }, function(result, value)
        if result == 'more' then
            self.progress = value
            self:flash('good', 'success', 900)
        elseif result == 'gulp' then
            self.strikes, self.progress = value, 0.0
        elseif result == 'gave_up' then
            self.strikes = value
            self:finish('gave_up', 1500)
        elseif result == 'flowing' then
            self:go('flow')
        elseif result == 'not_ready' or result == 'too_soon' then
            return
        end
        self:newZone()
    end)
end

---Moves the breath along and scrubs the blow clip to it.
function Game:breathe(dt)
    local blow = self.step == 'prime' and not self.ending and (IsDisabledControlPressed(0, KEY.click) or IsDisabledControlPressed(0, KEY.blow))
    if self.step ~= 'prime' and (self.stage == 'inhale' or self.stage == 'ready') then self.stage = 'settle' end

    if self.stage == 'settle' then
        -- The fuel runs while breathing in: let the breath out without a blow.
        self.breath = math.max(0.0, self.breath - dt * READY / INHALE_TIME)
        if self.breath <= 0.0 then self.stage = 'rest' end
    elseif self.stage == 'inhale' then
        if self.breath == 0.0 then sound('sf_inhale', 0.6) end
        self.breath = math.min(READY, self.breath + dt * READY / INHALE_TIME)
        if self.breath >= READY then self.stage = 'ready' end
    elseif self.stage == 'ready' then
        if blow then self.stage, self.pressure = 'blowing', 0.0 end
    elseif self.stage == 'blowing' then
        self.breath = math.min(BLOWN, self.breath + dt * (BLOWN - READY) / BLOW_IN_TIME)
        self.pressure = math.min(1.0, self.pressure + dt * self.rate * (0.55 + self.pressure))
        if not blow or self.pressure >= 1.0 then self:release() end
    elseif self.stage == 'exhale' then
        self.breath = math.min(1.0, self.breath + dt * (1.0 - BLOWN) / EXHALE_TIME)
        if self.breath >= 1.0 then
            self.puffIndex, self.breath = (self.puffIndex + 1) % PUFFS_IN_CLIP, 0.0
            -- Once the fuel runs there is nothing left to blow: rest at the start of a puff.
            self.stage = self.step == 'prime' and 'inhale' or 'rest'
        end
    end

    self:scrub(self.clip, (self.puffIndex + self.breath) / PUFFS_IN_CLIP, 1)
end

---Pins the blow hose as the clip moves the hands: its end between the lips, held in the right fist below
---them and in the left fist out of the filler (offsets in ped space, rig.lua clips).
function Game:holdBlowHose(dt)
    local props, rope = self.props, self.props.blow
    local layout = RIG.clips[self.clip]
    local ped = PlayerPedId()
    local rot = Mat.axis('z', GetEntityHeading(ped))
    local mouth = self:lips() + Mat.apply(rot, layout.mouthFromLips + vec3(0.0, 0.012, 0.0))
    local fist = self:hand() + Mat.apply(rot, layout.gripFromHand)
    local left = GetPedBoneCoords(ped, LEFT_HAND, 0.0, 0.0, 0.0) + Mat.apply(rot, layout.leftGripFromHand)
    if not self.leftNode then
        -- The first node that reaches the left fist from where the hose comes out of the filler (a
        -- little slack, never stretched).
        local fed = rope.ends[1] and rope.ends[1].fed or 0.0
        local reach = fed + #(left - props:filler(RIG.filler.blowPath[1])) + 0.01
        self.leftNode = Clamp(math.ceil(reach / rope.seg) + 1, 2, rope.count - 5)
    end
    local k = Clamp((self.holdK or 0.0) + dt * 2.5, 0.0, 1.0)
    self.holdK = k
    local tip, grip, hold = rope.count, rope.count - 3, self.leftNode
    rope.pins[tip] = Vec.lerp(rope.p[tip], mouth, k)
    rope.pins[grip] = Vec.lerp(rope.p[grip], fist, k)
    rope.pins[hold] = Vec.lerp(rope.p[hold], left, k)
end

function Game:letGoBlowHose()
    local rope = self.props.blow
    rope.pins[rope.count], rope.pins[rope.count - 3] = nil, nil
    if self.leftNode then rope.pins[self.leftNode] = nil end
    self.holdK, self.leftNode = nil, nil
end

Game.steps.prime = {
    enter = function(self)
        local cam = cfg.camera
        self:shot(cam.pos, cam.target, cam.fov, false, 2.4)
        self.stage, self.breath, self.puffIndex, self.pressure = 'inhale', 0.0, 0, 0.0
        self:newZone()
    end,
    update = function(self, dt)
        self:breathe(dt)
        self:holdBlowHose(dt)
        -- Between puffs the hose is still: the fuel creeps up the neck, out of sight.
        local blowing = self.stage == 'blowing'
        self.loops.blow = blowing and { 'sf_blow', { level = 0.4 + 0.6 * self.pressure } } or nil
        if self.gurgleUntil and self.now < self.gurgleUntil then
            self.loops.gurgle = { 'sf_gurgle', { level = Clamp((self.gurgleUntil - self.now) / 1400, 0.0, 1.0) } }
        end

        local text = self.stage == 'blowing' and 'hint_release' or self.stage == 'ready' and 'hint_blow' or 'hint_breathe'
        self.hint = { text = t(text), sub = t('hint_prime'),
            keys = { { key = 'LMB', label = t('key_blow') }, { key = 'ESC', label = t('give_up') } } }
        self.meter = { label = t('pressure'), value = math.floor(self.pressure * 50 + 0.5) / 50, zone = self.zone,
            tone = self.pressure > self.zone[2] and 'danger' or 'accent' }
        self.strikeState = { label = t('gulps'), used = self.strikes, max = self.session.maxStrikes }

        -- One box per good puff it takes.
        local done = self.progress
        self.tools = {}
        for i = 1, self.session.puffs do self.tools[i] = { label = tostring(i), done = i <= done, active = i == done + 1 } end
    end,
}

-- Flow ------------------------------------------------------------------------------------------

local GOOD_DEPTH = 0.22 -- metres down the can's neck the hose has to be so the flow can't flick it out
Game.GOOD_DEPTH = GOOD_DEPTH

---Litres that have come out of the hose so far, by this client's clock (the server's count decides).
function Game:flowed()
    if not self.flowAt then return 0.0 end
    local seconds = (self.now - self.flowAt) / 1000
    local travel = (self.props.siphon.length - self.fed) / FUEL_SPEED
    return Clamp((seconds - travel) * self.session.flowRate, 0.0, self.session.available)
end

---Where fuel that runs down the can's end puddles (world).
function Game:canEnd()
    return self.props:can(vec3(RIG.can.size.x / 2 + 0.12, 0.0, 0.0))
end

function Game:stopFlow(reason)
    if self.stopping then return end
    self.stopping = true
    if reason then self:flash(reason, 'default', 2200) end
    -- What stands in the funnel can't go in the full can: it spills when the funnel comes out.
    if self.props.funnel.level > 0.02 then self:puddle(self:canEnd(), 'can', 0.5, true) end
    local spills = {}
    for i, s in ipairs(self.spills) do spills[i] = { at = s.at, share = s.share } end
    self:request('tr_minigames:siphon:stop', { self.spilled, spills, n = 2 }, function(_, litres, can, missed)
        self.litres, self.can, self.missed = litres, can, missed
        self:go('unpack')
    end, function() self.stopping = false end)
end

Game.steps.flow = {
    enter = function(self)
        self.flowAt = GetGameTimer()
        self.fed = self.props.siphon.ends[1] and self.props.siphon.ends[1].fed or 0.3
        self:flash('flowing', 'success', 2000)
        local props = self.props
        -- From the can's side, so the player at the filler doesn't stand in front of it.
        self:frame(props:mouth(), props:canTarget(), false, 50.0, 0.45, 1.6)
    end,
    update = function(self, dt)
        self:breathe(dt)
        self:holdBlowHose(dt)
        local props, rope = self.props, self.props.siphon
        local seconds = (self.now - self.flowAt) / 1000
        local front = math.min(rope.length, self.fed + seconds * FUEL_SPEED)
        props.fuel.from, props.fuel.to = 0.0, front
        local running = front >= rope.length - 0.001

        -- Into the can.
        local litres = self:flowed()
        local out = 0.0
        local into = litres - self.spilled
        props.streams[1] = nil

        -- The can is full: the fuel backs up into the funnel, then runs over its rim and off the can's end
        -- (the neck is by the end, the rim reaches past it).
        local room, funnel = self.session.room, props.funnel
        local extra = math.max(0.0, into - room)
        funnel.level = math.min(extra, SiphonProps.FUNNEL_HOLDS)
        if extra > 0.0 and not self.backingUp then
            self.backingUp = true
            self:flash('backing_up', 'error', 2600)
        end
        if extra > SiphonProps.FUNNEL_HOLDS and running then
            if not self.overflowing then
                self.overflowing = true
                self:flash('overflowing', 'error', 2600)
            end
            local f = RIG.funnel
            local x = f.seat.x + f.rim.radius
            props.streams[2] = {
                props:can(vec3(x - 0.004, 0.0, f.seat.z + f.rim.top + 0.002)), props:can(vec3(x + 0.002, 0.0, f.seat.z + f.rim.top - 0.012)),
                props:can(vec3(x + 0.003, 0.0, f.seat.z + 0.1)), props:can(vec3(x + 0.004, 0.0, 0.004)),
            }
            self:puddle(self:canEnd(), 'can', 0.5)
            out = 1.0
        else
            props.streams[2] = nil
        end

        if running then
            local fill = Clamp((self.canLitres + math.min(into, room)) / self.session.canLitres, 0.0, 1.0)
            self.loops.pour = { 'sf_pour', { fill = math.floor(fill * 50 + 0.5) / 50, level = 1.0 } }
        end
        if out > 0 then self.loops.spill = { 'sf_spill', { level = out } } end

        -- The tank is down to the reserve: air comes through and it stops.
        if not self.stopping and litres >= self.session.available - 1e-3 and running then
            self:stopFlow('dry')
        end

        if not self.stopping and (IsDisabledControlJustPressed(0, KEY.use) or IsDisabledControlJustPressed(0, KEY.pause)
                or IsDisabledControlJustPressed(0, KEY.back)) then
            self:stopFlow()
        end

        local inCan = self.canLitres + math.max(0.0, math.min(into, room))
        local keys = { { key = 'E', label = t('key_stop') } }
        self.hint = { text = t(self.overflowing and 'hint_overflow'
                or self.backingUp and 'hint_backing_up' or 'hint_flow'),
            sub = t('litres', { n = ('%.1f'):format(math.max(0.0, into)) }), keys = keys }
        self.meter = { label = t('can'), value = math.floor(inCan / self.session.canLitres * 100 + 0.5) / 100,
            tone = self.backingUp and 'danger' or 'accent' }
    end,
}

-- HUD -----------------------------------------------------------------------------------------
-- Drawn by the page (TR.ui.hud). The state is rebuilt every frame; only changes are sent.

local MARKERS_MOVING = 50 -- ms: while the camera moves, the markers on screen are sent this often (not every frame)

function Game:draw()
    if self.ending then return TR.ui.hud.hide() end
    -- While the camera glides to a new shot every marker moves on screen every frame, and each change is
    -- a message to the page: during the move they follow at 20 a second.
    local markers = #self.markers > 0 and self.markers or nil
    if markers and not self.props.scene:cameraSettled() then
        if self.markersAt and self.now - self.markersAt < MARKERS_MOVING then
            markers = self.markersSent
        else
            self.markersAt = self.now
        end
    end
    self.markersSent = markers
    TR.ui.hud.set({
        hint = self.hint,
        tools = self.tools,
        strikes = self.strikeState,
        meter = self.meter,
        markers = markers,
    })
end

---A loop's params rounded, so the mirror only sends changes that can be heard.
local function rounded(params)
    if not params then return nil end
    local out = {}
    for key, value in pairs(params) do out[key] = type(value) == 'number' and math.floor(value * 20 + 0.5) / 20 or value end
    return out
end

---Continuous sounds the step asked for this frame. The page only gets changes, and levels go in steps
---of 0.05 (the page glides between them): a level that changes every frame (blowing harder) would
---otherwise cross over to the page every frame.
function Game:soundLoops()
    local active = {}
    for _, id in ipairs(LOOPS) do
        local loop = not self.ending and self.loops[id]
        if loop then
            local params = rounded(loop[2])
            TR.ui.sound.loop('siphon:' .. id, loop[1], params, Config.volume)
            active[id] = { loop[1], params }
        else
            TR.ui.sound.stop('siphon:' .. id)
        end
    end
    if self.mirror then self.mirror:setLoops(active) end
end

-- Players nearby ----------------------------------------------------------------------------------
-- They see the props from what this game sends (TR.mirror, props.lua SiphonView) and the
-- player's ped at the same point of its clip: the network plays the clip for them, but not held where
-- the game scrubs it.

local CLIPS = { 'putdown' } -- every clip the game plays, in a fixed order: the mirror sends the number
for name in pairs(RIG.clips) do
    CLIPS[#CLIPS + 1] = name
    CLIPS[#CLIPS + 1] = (name:gsub('blow', 'work'))
end
table.sort(CLIPS)
local CLIP_NUMBER = {}
for i, name in ipairs(CLIPS) do CLIP_NUMBER[name] = i end
Game.CLIPS = CLIPS

---Game state for the mirror, at each of its updates.
function Game:mirrorState(sender)
    self.props:mirrorState(function(key, list) sender:setState(key, list) end)
    local clip = self.playing and CLIP_NUMBER[self.playing]
    if clip and self.scrubbing then
        sender:setState('ped', { clip, math.floor(self.scrubPhase * 1000 + 0.5) })
    else
        sender:setState('ped', false)
    end
end

---The player's ped on this client, or 0.
local function ownerPed(replica)
    local player = GetPlayerFromServerId(replica.owner)
    return player ~= -1 and GetPlayerPed(player) or 0
end

---Lets the ped's clip play on at its own speed again, if it was held.
local function releasePed(replica, entity)
    local held = replica.pedClip
    replica.pedClip = nil
    if held and entity ~= 0 and IsEntityPlayingAnim(entity, DICT, held, 3) then SetEntityAnimSpeed(entity, DICT, held, 1.0) end
end

---Holds the player's ped where its clip is scrubbed, eased (a clip that wraps round jumps).
local function holdPed(replica, dt)
    local ped = replica.state.ped
    local name = ped and CLIPS[ped[1]]
    local entity = ownerPed(replica)
    if replica.pedClip and replica.pedClip ~= name then releasePed(replica, entity) end
    if not name or entity == 0 or not HasAnimDictLoaded(DICT) or not IsEntityPlayingAnim(entity, DICT, name, 3) then
        replica.pedClip = nil
        return
    end
    local target = ped[2] / 1000
    local phase = replica.pedClip == name and replica.pedPhase or target
    if math.abs(target - phase) > 0.5 then phase = target end
    phase = Lerp(phase, target, 1.0 - math.exp(-dt * 15.0))
    replica.pedClip, replica.pedPhase = name, phase
    SetEntityAnimSpeed(entity, DICT, name, 0.0)
    SetEntityAnimCurrentTime(entity, DICT, name, Clamp(phase, 0.0, 0.999))
end

Mirror.effects.siphon = function(replica)
    local view = replica.siphon
    if view == nil then
        RequestAnimDict(DICT)
        local ok, made = pcall(SiphonProps.view, replica.scene)
        if not ok then TR.log.error('siphon mirror failed: %s', made) end
        view = ok and made or false
        replica.siphon = view
    end
    if not view then return end
    local dt = math.min(GetFrameTime(), 0.1)
    local _, fuelCap = replica:find('tr_sf_fuelcap')
    view:draw(replica.state, fuelCap, dt)
    holdPed(replica, dt)
end

Mirror.teardown.siphon = function(replica)
    releasePed(replica, ownerPed(replica))
    if replica.siphon then replica.siphon:destroy() end
    replica.siphon = nil
end

-- Loop ----------------------------------------------------------------------------------------

function Game:controls()
    DisableAllControlActions(0)
    EnableControlAction(0, 249, true) -- push to talk
    HideHudAndRadarThisFrame()
    SetMouseCursorActiveThisFrame()
    SetMouseCursorSprite(self.cursor)

    self.mx, self.my = GetDisabledControlNormal(0, 239), GetDisabledControlNormal(0, 240)
    self.down = IsDisabledControlPressed(0, KEY.click)
    self.pressed = IsDisabledControlJustPressed(0, KEY.click)
    self.altPressed = IsDisabledControlJustPressed(0, KEY.alt)
    self.wheel = (IsDisabledControlJustPressed(0, KEY.wheelUp) and 1 or 0) - (IsDisabledControlJustPressed(0, KEY.wheelDown) and 1 or 0)
    self.dmx, self.dmy = self.mx - (self.lastMx or self.mx), self.my - (self.lastMy or self.my)
    self.lastMx, self.lastMy = self.mx, self.my

    if self.ending then
        self.down, self.pressed, self.altPressed, self.wheel = false, false, false, 0
        return
    end

    -- ESC: gives up during the setup and priming, skips the rest of the pack-up. The flow stops itself.
    local escape = IsDisabledControlJustPressed(0, KEY.pause) or IsDisabledControlJustPressed(0, KEY.back)
    local step = Game.steps[self.step]
    if escape and step and step.packing then
        self.props.kitShown = false
        self:finish('done')
    elseif escape and self.step ~= 'flow' then
        self:cancel()
    end
end

---Held (or pressed this frame) keys, for steps.
function Game:key(name) return IsDisabledControlPressed(0, KEY[name]) end
function Game:keyPressed(name) return IsDisabledControlJustPressed(0, KEY[name]) end

---Why the attempt can't go on (a locale key), or nil while it can.
function Game:interrupted()
    if IsEntityDead(PlayerPedId()) then return 'no_session' end
    if not DoesEntityExist(self.vehicle) then return 'vehicle_gone' end
    if GetEntitySpeed(self.vehicle) >= 1.0 then return 'vehicle_moved' end
    -- An admin in dev mode may siphon a running car (the server allowed it).
    if not self.session.dev and GetIsVehicleEngineRunning(self.vehicle) then return 'engine_started' end
end

function Game:loop()
    while true do
        local dt = math.min(GetFrameTime(), 0.1)
        self.now = GetGameTimer()
        if self.ending and self.now >= self.endAt then break end

        local why = not self.ending and self:interrupted()
        if why then
            CreateThread(function() TR.callback.await('tr_minigames:siphon:cancel') end)
            self:finish(why)
        end

        self:controls()
        self.hint, self.meter, self.tools, self.strikeState = nil, nil, nil, nil
        self.markers, self.loops = {}, {}
        local step = Game.steps[self.step]
        if step and not self.ending then step.update(self, dt) end

        self.props:update(dt)
        self.mirror:tick(self.now)
        self:hidePed()
        self.props.scene:torch(self.closeUp and 1.2 or 0.0)
        self:draw()
        self:soundLoops()
        Wait(0)
    end
end

---Runs the minigame to the end. Blocks the calling thread.
---@return string result
---@return number? litres into the can
---@return number? can percent in the can afterwards
---@return number? spilled litres
function Siphon.run(vehicle, session)
    local place = Siphon.placement(vehicle, PlayerPedId())
    if not place then
        CreateThread(function() TR.callback.await('tr_minigames:siphon:cancel') end)
        return 'no_filler'
    end

    local game = Game.new(vehicle, session, place)
    Siphon.current = game
    local ok, err = pcall(function()
        game:setup()
        game:loop()
    end)
    game.running = false
    Siphon.current = nil
    game:cleanup()

    if not ok then
        TR.log.error('siphon minigame failed: %s', err)
        CreateThread(function() TR.callback.await('tr_minigames:siphon:cancel') end)
        return tostring(err):find('model') and 'missing_models' or 'try_again'
    end
    return game.result, game.litres, game.can, game.missed
end
