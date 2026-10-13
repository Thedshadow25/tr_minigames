--[[
    The lockpick minigame: a Lishi 2-in-1 pick in a car door's wafer lock.

        local result, extra = Lockpick.run(vehicle, door, session)

    How a wafer lock is picked, and how this plays:
      - RMB holds light turning tension on the plug. Under tension one wafer at a time binds.
      - A/D or the scroll wheel moves the pick between the lock's 8 wafer positions (the knob slides
        one detent per position). Some positions are empty on cheaper locks.
      - Holding LMB and pushing the mouse up lifts the wafer at the pick. A free wafer is springy. A
        binding one is stiff and only gives slowly; lifted to its shear line it clicks, the plug
        turns a hair and the wafer stays set. Then the next one binds.
      - Pushing a set wafer past the line oversets it: it jams until the tension is let off, and
        letting off drops every set wafer.
      - Pushing hard against a wafer that won't move (the pressure meter in the red) bends the
        pick. The third bend snaps it and the tip stays in the lock.
      - The reading plate on the tool shows where the pick is: the red pointer's column is the
        wafer, its height on the depth lines is the lift.

    The server knows the lock (which positions are filled, each wafer's depth, the binding order) and
    tells this file what the pick feels at a wafer when the player first touches it.

    result: 'opened' (extra = alarm armed), 'failed' (extra = item lost), 'cancelled' or a reason.
]]

local cfg = Config.lockpick
local Rig = Lockpick.rig
local function t(key, vars) return TR.locale.t('lockpick.' .. key, vars) end

local Game = {}
Game.__index = Game

local POSITIONS = #Rig.wafers
local STEP = Rig.depthStep
local MAX_LIFT = (Rig.depths + 0.9) * STEP -- the hook's travel: a little past the deepest line
local SPAN = 0.0012           -- metres the finger can get ahead of a wafer that doesn't move: full pressure
local AHEAD = SPAN * 1.3      -- the finger can't get further ahead than this
local PENDING_LIFT = 0.0006   -- how far a wafer moves before the server has said what it is
local STRAIN_FROM = 0.75      -- pressure where the pick starts to bend
local LIFT_GAIN = 0.004       -- metres of lift per unit of mouse movement
local TENSION_ROLL = 2.2      -- degrees the plug turns under tension
local GIVE_ROLL = 0.5         -- and a little more for every set wafer
local LEVER_OPEN = 52.0       -- degrees the lever swings out to uncover the reading plate
local INSERT_FROM = -0.036    -- the tool's Y before it goes in: blade tip just outside the keyway
local SHUTTER_OPEN = 88.0     -- degrees the dust shutter swings in when the blade pushes it

local KEY = { lift = 24, tension = 25, deeper = { 241, 35 }, shallower = { 242, 34 }, pause = 200, back = 194 }
local ANIM_DICT, ANIM = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@', 'machinic_loop_mechandplayer'
local LOOPS = { 'scrape' } -- their ids are 'lockpick:<loop>'

local function ease(k)
    k = Clamp(k, 0.0, 1.0)
    return k * k * (3.0 - 2.0 * k)
end

-- Sound effects play on the resource's page (TR.ui.sound); names are listed in engine/client/sounds.lua.
local function sound(name)
    TR.ui.sound.play(name, Config.volume)

    -- Players nearby hear it too (TR.mirror).
    local game = Lockpick.current
    if game and game.mirror then game.mirror:sound(name) end
end

-- Setup -----------------------------------------------------------------------------------------

function Game.new(vehicle, door, session, offset, pitch, yaw)
    return setmetatable({
        vehicle = vehicle,
        door = door,
        session = session,
        scene = Scene.new(vehicle, offset, pitch, yaw),
        phase = 'insert',
        phaseAt = GetGameTimer(),
        now = GetGameTimer(),
        running = true,
        queue = {},

        pos = POSITIONS, -- the pick rests at the deepest wafer
        slide = 0.0,     -- the pick's Y in tool space, eased toward its position
        finger = 0.0,    -- where the player is pushing the hook to
        lift = 0.0,      -- where the hook is
        pressure = 0.0,
        strain = 0.0,
        rate = 0.0,      -- how fast a stiff wafer is giving, for the scrape

        tension = false,
        epoch = 0,       -- one per grip on the tension; the server drops set wafers on a new one
        roll = 0.0,      -- degrees the plug (and the tool in it) has turned
        insert = INSERT_FROM,
        swing = 0.0,
        shutter = 0.0,

        feel = {},       -- position -> { key, kind } what the server said the pick feels there
        empty = {},      -- positions known to have no wafer
        depths = {},     -- depth of every wafer felt binding or set: the player's decode
        set = {},
        setCount = 0,
        jammed = nil,    -- position of an overset wafer
        toldEmpty = {},
        strikes = 0,
    }, Game)
end

---Walks the player up to the door, facing the lock.
function Game:approach()
    local ped = PlayerPedId()
    local lock = self.scene:toWorld(vec3(0.0, 0.0, 0.0))
    local out = Mat.apply(self.scene.rot, vec3(0.0, -1.0, 0.0))
    local spot = lock + Vec.normalize(vec3(out.x, out.y, 0.0)) * 0.55
    local heading = GetHeadingFromVector_2d(lock.x - spot.x, lock.y - spot.y)
    local function away()
        local c = GetEntityCoords(ped)
        return #(vec3(c.x - spot.x, c.y - spot.y, 0.0))
    end

    if away() > 0.12 then
        TaskGoStraightToCoord(ped, spot.x, spot.y, GetEntityCoords(ped).z, 1.0, 3000, heading, 0.05)
        local deadline = GetGameTimer() + 3000
        while away() > 0.15 and GetGameTimer() < deadline do
            DisableAllControlActions(0)
            EnableControlAction(0, 1, true)
            EnableControlAction(0, 2, true)
            Wait(0)
        end
    end

    TaskAchieveHeading(ped, heading, 500)
    local deadline = GetGameTimer() + 500
    while GetGameTimer() < deadline do
        DisableAllControlActions(0)
        Wait(0)
    end
end

function Game:setup()
    local scene = self.scene
    scene:preload({ 'tr_lp_bezel', 'tr_lp_plug', 'tr_lp_shutter', 'tr_lp_lishi', 'tr_lp_lishi_pick', 'tr_lp_lishi_lever',
        'tr_lp_pick_broken' })

    RequestAnimDict(ANIM_DICT)
    self:approach()

    scene:spawn('bezel', 'tr_lp_bezel')
    scene:spawn('plug', 'tr_lp_plug')
    scene:spawn('shutter', 'tr_lp_shutter', Rig.shutterHinge)
    scene:spawn('lishi', 'tr_lp_lishi')
    scene:spawn('pick', 'tr_lp_lishi_pick')
    scene:spawn('lever', 'tr_lp_lishi_lever')
    self:animate(0.0)

    local cam = cfg.camera
    scene:createCamera(cam.pos, cam.target, cam.fov)

    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(ANIM_DICT) and GetGameTimer() < deadline do Wait(0) end
    TaskPlayAnim(PlayerPedId(), ANIM_DICT, ANIM, 3.0, -3.0, -1, 1, 0.0, false, false, false)

    self.phase, self.phaseAt = 'insert', GetGameTimer()
    sound('lp_insert')
end

function Game:cleanup()
    TR.ui.hud.hide()
    for _, id in ipairs(LOOPS) do TR.ui.sound.stop('lockpick:' .. id) end
    self.scene:destroy()
    StopAnimTask(PlayerPedId(), ANIM_DICT, ANIM, 2.0)
    RemoveAnimDict(ANIM_DICT)
end

-- Server requests -----------------------------------------------------------------------------
-- Sent one at a time, in order, without blocking the frame loop.

---@param name string callback name
---@param args any[]
---@param cb? fun(...) gets the callback's results
---@param lost? fun() called when the request didn't get through (timeout, rate limit)
function Game:request(name, args, cb, lost)
    self.queue[#self.queue + 1] = { name = name, args = args, cb = cb, lost = lost }
    if self.pending then return end
    self.pending = true

    CreateThread(function()
        while #self.queue > 0 and self.running and not self.ending do
            local job = table.remove(self.queue, 1)
            local result = table.pack(TR.callback.await(job.name, table.unpack(job.args)))
            if not self.running or self.ending then break end

            if result[1] == nil then
                -- Not delivered: nothing changed on the server.
                if job.lost then job.lost() end
            elseif result[1] == false then
                -- The server ended the attempt (expired, moved away, ...).
                self:finish(result[2] or 'no_session')
                break
            elseif job.cb then
                job.cb(table.unpack(result, 1, result.n))
            end
        end
        self.pending = false
    end)
end

-- Endings -------------------------------------------------------------------------------------

function Game:finish(result, extra, delay)
    if self.ending then return end
    self.ending = true
    self.result, self.extra = result, extra
    self.endAt = self.now + (delay or 0)
end

---Takes the tool out of the lock, then ends with `result`.
function Game:leave(result, extra)
    if self.phase == 'withdraw' then return end
    self.phase, self.phaseAt = 'withdraw', self.now
    self.leaving = { result, extra }
    self.tension, self.finger, self.rate, self.pressure = false, 0.0, 0.0, 0.0
    sound('lp_remove')
end

function Game:cancel()
    CreateThread(function() TR.callback.await('tr_minigames:lockpick:cancel') end)
    self:leave('cancelled')
end

---@param tone? 'default' | 'success' | 'error' | 'muted'
function Game:flash(text, tone, duration)
    TR.ui.hud.flash(text, tone, duration)
end

-- What the pick feels ------------------------------------------------------------------------

---Everything the server's answer depends on: tension (and which grip), set wafers, a jam.
function Game:feelKey()
    return ('%d:%d:%d'):format(self.tension and self.epoch or 0, self.setCount, self.jammed or 0)
end

---What the hook feels at position `pos`: 'empty', 'spring', 'binding', 'set', 'stuck' or
---'pending' while the server is asked (the first touch after anything changed).
function Game:feelAt(pos)
    if self.empty[pos] then return 'empty' end
    if self.jammed == pos then return 'stuck' end
    if self.set[pos] then return 'set' end

    local key = self:feelKey()
    local known = self.feel[pos]
    if known and known.key == key then return known.kind end

    local entry = { key = key, kind = 'pending' }
    self.feel[pos] = entry
    self:request('tr_minigames:lockpick:probe', { pos, self.tension and self.epoch or 0 }, function(kind, depth)
        if self.feel[pos] ~= entry then return end -- things moved on meanwhile
        if kind == 'stale' then
            self.feel[pos] = nil
            return
        end
        if kind == 'empty' then self.empty[pos] = true end
        if math.type(depth) == 'integer' then self.depths[pos] = depth end
        entry.kind = kind
    end, function()
        if self.feel[pos] == entry then self.feel[pos] = nil end
    end)

    return 'pending'
end

---Height of a wafer's shear line above the hook's rest.
local function shearLine(depth) return depth * STEP end

-- Actions ---------------------------------------------------------------------------------------

function Game:setTension(on)
    if on == self.tension then return end
    self.tension = on

    if on then
        self.epoch = self.epoch + 1
        sound('lp_tension')
        return
    end

    -- Letting off: the plug springs back and every set wafer drops.
    local dropped = self.setCount > 0 or self.jammed
    self.set, self.setCount, self.jammed = {}, 0, nil
    if dropped then
        sound('lp_drop')
        self:flash(t('dropped'), 'muted')
    end
end

function Game:move(step)
    local pos = Clamp(self.pos + step, 1, POSITIONS)
    sound('lp_detent')
    if pos == self.pos then return end -- the knob against its stop
    self.pos = pos
    self.strain = 0.0
end

---The binding wafer reached its shear line: it clicks and stays up, the plug gives a hair.
function Game:setWafer(pos)
    self.set[pos] = true
    self.setCount = self.setCount + 1
    sound('lp_set')

    local epoch = self.epoch
    self:request('tr_minigames:lockpick:set', { pos, epoch, math.floor(self.lift * 1e6 + 0.5) }, function(result, armed)
        if result == 'open' then return self:open(armed) end
        if result == 'slipped' and self.epoch == epoch and self.set[pos] then
            -- The server disagrees (a grip it saw differently): the wafer drops again.
            self.set[pos] = nil
            self.setCount = self.setCount - 1
        end
    end)
end

---Pushed past the shear line: the wafer jams the plug until the tension is let off.
function Game:overset(pos)
    if self.set[pos] then
        self.set[pos] = nil
        self.setCount = self.setCount - 1
    end
    self.jammed = pos
    sound('lp_overset')
    self:flash(t('overset'), 'error', 2200)
    self:request('tr_minigames:lockpick:overset', { pos, self.epoch })
end

---Forced a wafer that wouldn't move: the pick bends. The third bend snaps it.
function Game:bend()
    self.strain, self.finger = 0.0, 0.0
    self.gripLost = true -- let go of LMB before lifting again
    self.strikes = self.strikes + 1
    sound('lp_bend')
    ShakeCam(self.scene.cam, 'SMALL_EXPLOSION_SHAKE', 0.035)

    self:request('tr_minigames:lockpick:bend', { self.pos }, function(result, strikes, lost)
        if math.type(strikes) == 'integer' then self.strikes = strikes end
        if result == 'snapped' then return self:snap(lost) end
        self:flash(t('bent'), 'error')
    end)
end

---The pick's tip snaps off and stays in the lock.
function Game:snap(lost)
    sound('lp_snap')
    ShakeCam(self.scene.cam, 'SMALL_EXPLOSION_SHAKE', 0.07)
    self:flash(t('snapped'), 'error', 2500)

    local roll = Mat.axis('y', self.roll)
    local at = vec3(0.0, self.slide + Rig.tip.y - 0.006, self.lift)
    self.scene:spawn('broken', 'tr_lp_pick_broken', Mat.apply(roll, at), roll)
    self:leave('failed', lost)
end

---Every wafer is set: the plug turns and the door unlocks.
function Game:open(armed)
    self.phase, self.phaseAt = 'turn', self.now
    self.armed = armed
    self.tension, self.finger, self.rate, self.pressure = false, 0.0, 0.0, 0.0
    self:flash(t('turning'), 'success', 2500)
end

-- Picking -------------------------------------------------------------------------------------

function Game:controls()
    DisableAllControlActions(0)
    EnableControlAction(0, 249, true) -- push to talk
    HideHudAndRadarThisFrame()
    -- Once the camera is at the lock, where the player's own arms would be in the way.
    if self.scene.cam and Vec.length(self.scene.camPos - self.scene.camGoalPos) < 0.3 then
        SetEntityLocallyInvisible(PlayerPedId())
    end

    self.holding = false
    if self.ending or self.phase ~= 'pick' then return end

    if IsDisabledControlJustPressed(0, KEY.pause) or IsDisabledControlJustPressed(0, KEY.back) then
        return self:cancel()
    end

    if cfg.devMode then self:nudgeFit() end
    self:setTension(IsDisabledControlPressed(0, KEY.tension))

    local lmb = IsDisabledControlPressed(0, KEY.lift)
    if not lmb then self.gripLost = false end
    self.holding = lmb and not self.gripLost

    -- The pick only slides along the keyway while the hook is down.
    if not self.holding and self.lift < 0.0003 then
        for _, key in ipairs(KEY.deeper) do
            if IsDisabledControlJustPressed(0, key) then self:move(1) end
        end
        for _, key in ipairs(KEY.shallower) do
            if IsDisabledControlJustPressed(0, key) then self:move(-1) end
        end
    end

    if self.holding then
        local dy = GetDisabledControlUnboundNormal(0, 2) -- mouse down is positive
        self.finger = Clamp(self.finger - dy * LIFT_GAIN * cfg.liftSensitivity, 0.0, self.lift + AHEAD)
    else
        self.finger = 0.0
    end
end

-- Dev mode: fit the lock to this car while picking (keys in Lockpick.nudged). Each press goes
-- through /lockpick_rig, which moves the lock and prints the vehicleFits line.
function Game:nudgeFit()
    local model = Lockpick.modelName(self.vehicle)
    local moved = Lockpick.nudged(model, self.vehicle)
    if not moved then return end

    if moved.x then
        -- A measured fit: move it in place (save it with /lockpick_fitall <model>).
        Lockpick.liveFits[model] = moved
        self.scene:setPlacement(Lockpick.placement(self.vehicle, self.door))
        return
    end
    ExecuteCommand(('lockpick_rig %.3f %.3f %.3f'):format(moved.back, moved.up, moved.out))
end

---Moves the hook toward the finger the way the wafer under it allows, and works out the pressure.
function Game:pickStep(dt)
    local pos = self.pos
    local finger, lift = self.finger, self.lift
    local follow = Clamp(dt * 25.0, 0.0, 1.0)
    local pressure, top, rate = 0.0, MAX_LIFT, 0.0

    if not self.holding then
        lift = math.max(0.0, lift - dt * 0.03) -- the springs push the hook back down
        self.lift, self.pressure, self.rate = lift, 0.0, 0.0
        self.touching = lift > 0.0003
        self.strain = math.max(0.0, self.strain - dt)
        return
    end

    local kind = self:feelAt(pos)
    local depth = self.depths[pos]

    if kind == 'binding' and depth then
        -- Stiff: it only gives at the lock's speed, however hard the player pushes.
        if finger <= lift then
            lift = finger
        else
            local step = math.min(finger - lift, self.session.speed * dt)
            lift, rate = lift + step, step / math.max(dt, 0.001)
        end
        pressure = (finger - lift) / SPAN
        top = lift
        if lift >= shearLine(depth) then
            self.lift = lift
            self:setWafer(pos)
        end
    elseif kind == 'set' and depth then
        -- Set wafers float loose; push one past the line and it oversets.
        lift = lift + (finger - lift) * follow
        pressure = 0.05
        if lift > shearLine(depth) + self.session.overset then self:overset(pos) end
    elseif kind == 'stuck' then
        -- An overset wafer won't move at all.
        top = shearLine(depth or Rig.depths) + self.session.overset
        lift = lift + (math.min(finger, top) - lift) * follow
    elseif kind == 'empty' then
        lift = lift + (math.min(finger, MAX_LIFT) - lift) * follow
        if lift > MAX_LIFT * 0.97 and not self.toldEmpty[pos] then
            self.toldEmpty[pos] = true
            sound('lp_detent')
            self:flash(t('empty'), 'muted')
        end
    else
        -- A free wafer (or one the server hasn't described yet): springy, light.
        if kind == 'pending' then top = PENDING_LIFT end
        lift = lift + (math.min(finger, top) - lift) * follow
        if kind == 'spring' and lift > 0.0003 and not self.touching then sound('lp_spring') end
        pressure = 0.12 + 0.3 * lift / MAX_LIFT
    end

    -- Pushing on after the hook can't go higher is pushing against metal.
    if finger > top then pressure = math.max(pressure, (finger - top) / SPAN) end

    if pressure > STRAIN_FROM then
        self.strain = self.strain + (pressure - STRAIN_FROM) * dt * 5.0
    else
        self.strain = math.max(0.0, self.strain - dt * 0.8)
    end

    self.lift, self.pressure, self.rate = math.max(lift, 0.0), Clamp(pressure, 0.0, 1.0), rate
    self.touching = self.lift > 0.0003
    if self.strain >= 1.0 then self:bend() end
end

-- Animation -----------------------------------------------------------------------------------

---Places a part that sits in the tool (tool space) where the tool is now.
function Game:toolPart(id, pos, rot)
    local part = self.scene:get(id)
    if not part then return end
    local roll = Mat.axis('y', self.roll)
    part.pos = vec3(0.0, self.insert, 0.0) + Mat.apply(roll, pos)
    part.rot = Mat.mul(roll, rot or Mat.identity())
end

function Game:animate(dt)
    local age = self.now - self.phaseAt
    local k = Clamp(dt * 10.0, 0.0, 1.0)
    local roll = 0.0

    if self.phase == 'insert' then
        -- The blade slides in, then the lever swings out to uncover the plate.
        self.insert = Lerp(INSERT_FROM, 0.0, ease(age / 900))
        self.swing = LEVER_OPEN * ease((age - 950) / 350)
        if age >= 950 and not self.leverOut then
            self.leverOut = true
            sound('lp_lever')
        end
        if age >= 1350 then self.phase, self.phaseAt = 'pick', self.now end
    elseif self.phase == 'pick' then
        if self.tension then roll = TENSION_ROLL + GIVE_ROLL * self.setCount end
    elseif self.phase == 'turn' then
        -- A quarter turn throws the lock; back again so the tool can come out.
        if age < 650 then
            roll = Lerp(TENSION_ROLL, 90.0, ease(age / 600))
        elseif age < 950 then
            roll = 90.0
        else
            roll = Lerp(90.0, 0.0, ease((age - 950) / 450))
        end
        if age >= 600 and not self.unlocked then
            self.unlocked = true
            sound('lp_unlock')
        end
        if age >= 1450 then self:leave('opened', self.armed) end
    elseif self.phase == 'withdraw' then
        self.swing = LEVER_OPEN * (1.0 - ease(age / 250))
        self.insert = Lerp(0.0, INSERT_FROM - 0.004, ease((age - 250) / 550))
        if age >= 900 then self:finish(self.leaving[1], self.leaving[2]) end
    end

    -- A stiff wafer giving makes the whole tool shiver a little.
    local shiver = self.rate > 0.0 and (math.random() - 0.5) * 0.3 or 0.0
    self.roll = self.phase == 'turn' and roll or Lerp(self.roll, roll, k) + shiver
    if math.abs(self.roll - roll) < 0.001 then self.roll = roll end -- there: the plug stops being moved
    local slide = Rig.wafers[self.pos] - Rig.tip.y
    self.slide = math.abs(self.slide - slide) < 1e-6 and slide or Lerp(self.slide, slide, Clamp(dt * 18.0, 0.0, 1.0))

    -- The blade pushes the dust shutter in once its tip reaches the plug's face; it springs back
    -- shut when the blade is out.
    local tip = self.insert + Rig.bladeLength
    local shutter = SHUTTER_OPEN * Clamp(tip / 0.004, 0.0, 1.0)
    if self.shutter > 1.0 and shutter <= 1.0 then sound('lp_shutter') end
    self.shutter = shutter

    local scene = self.scene
    local plugRoll = Mat.axis('y', self.roll)
    local plug = scene:get('plug')
    if plug then plug.rot = plugRoll end
    local flap = scene:get('shutter')
    if flap then
        flap.pos = Mat.apply(plugRoll, Rig.shutterHinge)
        flap.rot = Mat.mul(plugRoll, Mat.axis('x', self.shutter))
    end

    local jitter = self.rate > 0.0 and (math.random() - 0.5) * 0.00008 or 0.0
    self:toolPart('lishi', vec3(0.0, 0.0, 0.0))
    self:toolPart('pick', vec3(0.0, self.slide, self.lift + jitter))
    local pivot = Rig.leverPivot
    local swing = Mat.axis('z', -self.swing)
    self:toolPart('lever', pivot - Mat.apply(swing, pivot), swing)

    -- The camera breathes a little, like a held head.
    local cam = cfg.camera
    if scene.cam then
        local s = self.now / 1000.0
        scene.camGoalPos = cam.pos + vec3(math.sin(s * 0.8) * 0.0012, math.sin(s * 0.6) * 0.0008, math.sin(s * 1.1) * 0.0009)
    end
end

-- Sound loops ---------------------------------------------------------------------------------

function Game:soundLoops()
    local active = {}

    -- The hook dragging a stiff wafer up.
    if not self.ending and self.phase == 'pick' and self.rate > 0.0 then
        local level = math.floor(Clamp(self.rate / self.session.speed, 0.0, 1.0) * 10 + 0.5) / 10
        active.scrape = { 'lp_scrape', { level = math.max(level, 0.2) } }
    end

    for _, id in ipairs(LOOPS) do
        local loop = active[id]
        if loop then
            TR.ui.sound.loop('lockpick:' .. id, loop[1], loop[2], Config.volume)
        else
            TR.ui.sound.stop('lockpick:' .. id)
        end
    end

    if self.mirror then self.mirror:setLoops(active) end
end

-- HUD -----------------------------------------------------------------------------------------
-- Drawn by the page (TR.ui.hud). The state is rebuilt every frame; only changes are sent.

function Game:hint()
    local keys = {
        { key = 'RMB', label = t('key_tension') },
        { key = 'LMB', label = t('key_lift') },
        { key = 'A/D', label = t('key_move') },
        { key = 'ESC', label = t('give_up') },
    }

    local text
    if self.jammed then
        text = t('hint_jammed')
    elseif not self.tension then
        text = t('hint_tension')
    elseif self.setCount == 0 then
        text = t('hint_feel')
    else
        text = t('hint_next')
    end

    return { text = text, keys = keys }
end

function Game:draw()
    if self.ending or self.phase ~= 'pick' then return TR.ui.hud.hide() end

    -- One slot per wafer position, like a locksmith's notes: set ones are checked, decoded ones
    -- show their depth, empty ones a dash.
    local slots = {}
    for i = 1, POSITIONS do
        local depth = self.depths[i]
        slots[i] = {
            label = tostring(i),
            active = i == self.pos,
            done = self.set[i] == true,
            progress = self.empty[i] and '–' or depth and t('depth_short', { n = depth }) or nil,
        }
    end

    local meter
    if self.holding or self.pressure > 0.02 then
        local value = math.floor(self.pressure * 40 + 0.5) / 40
        meter = { label = t('pressure'), value = value, tone = value > STRAIN_FROM and 'danger' or 'accent' }
    end

    TR.ui.hud.set({
        hint = self:hint(),
        tools = slots,
        strikes = { label = t('bends'), used = self.strikes, max = self.session.maxStrikes },
        meter = meter,
    })
end

-- Loop ----------------------------------------------------------------------------------------

function Game:stillThere()
    local ped = PlayerPedId()
    if IsEntityDead(ped) or not DoesEntityExist(self.vehicle) then return false end
    if GetVehiclePedIsIn(ped, false) ~= 0 or GetEntitySpeed(self.vehicle) > 1.0 then return false end
    return #(GetEntityCoords(ped) - self.scene:toWorld(vec3(0.0, 0.0, 0.0))) < 2.0
end

function Game:loop()
    while true do
        local dt = GetFrameTime()
        self.now = GetGameTimer()

        if self.ending and self.now >= self.endAt then break end
        if not self.ending and not self:stillThere() then
            CreateThread(function() TR.callback.await('tr_minigames:lockpick:cancel') end)
            self:finish('moved_away')
        end

        self:controls()
        if not self.ending and self.phase == 'pick' then self:pickStep(dt) end

        self:animate(dt)
        self.scene:update()
        self.scene:torch(cfg.torch or 0.6)
        self:draw()
        self:soundLoops()
        self.mirror:tick(self.now)
        Wait(0)
    end
end

Lockpick.Game = Game -- for tests

---Runs the minigame to the end. Blocks the calling thread.
---@return string result, any extra
function Lockpick.run(vehicle, door, session)
    local offset, pitch, yaw = Lockpick.placement(vehicle, door)
    if not offset then
        CreateThread(function() TR.callback.await('tr_minigames:lockpick:cancel') end)
        return 'no_lock'
    end

    local game = Game.new(vehicle, door, session, offset, pitch, yaw)
    game.mirror = Mirror.sender(game.scene, 'lockpick')
    game.scene.mirror = game.mirror
    Lockpick.current = game

    local ok, err = pcall(function()
        game:setup()
        game:loop()
    end)

    game.running = false
    Lockpick.current = nil
    game.mirror:stop()
    game:cleanup()

    if not ok then
        TR.log.error('lockpick minigame failed: %s', err)
        CreateThread(function() TR.callback.await('tr_minigames:lockpick:cancel') end)
        return tostring(err):find('model') and 'missing_models' or 'try_again'
    end

    return game.result, game.extra
end
