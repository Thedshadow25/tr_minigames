--[[
    The hotwire minigame.

        local result, extra = Hotwire.run(vehicle, session)

    Steps: undo the three screws on the column cover, then use the test light to find the
    battery, ignition and starter wires, strip their ends, twist battery + ignition together and
    hold the starter against the pair until the engine catches. The server knows which wire is
    which; this file only animates the props and reports what the player did.

    result: 'started', 'failed' (extra = item broke), 'cancelled' or a reason the attempt ended.
]]

local cfg = Config.hotwire
local Rig = Hotwire.rig
local function t(key, vars) return TR.locale.t('hotwire.' .. key, vars) end


local Game = {}
Game.__index = Game

local SCREW_PITCH = 0.0035 -- metres a screw backs out per turn
local SLEEVE = Rig.sleeveLength
local COPPER = Rig.copperLength
local TIP_Y = Rig.wires[1].top.y + Rig.wires[1].tip.y
local UP = vec3(0.0, 0.0, 1.0)

local TOOLS = { 'probe', 'strippers', 'hand' }
local TOOL_MODELS = { probe = 'tr_hw_probe', strippers = 'tr_hw_strippers' }
local ANIM_DICT, ANIM = 'veh@std@ds@base', 'hotwire'

local KEY = { click = 24, tool = { 157, 158, 160 }, scrollUp = 241, scrollDown = 242, pause = 200, back = 194 }

-- Sound effects play on the resource's page (TR.ui.sound); names are listed in engine/client/sounds.lua.
---Length of a polyline.
local function pathLength(path)
    local length = 0.0
    for k = 2, #path do length = length + Vec.length(path[k] - path[k - 1]) end
    return length
end

local function sound(name)
    TR.ui.sound.play(name, Config.volume)

    -- Players nearby hear it too (TR.mirror).
    local game = Hotwire.current
    if game and game.mirror then game.mirror:sound(name) end
end

local LOOPS = { 'buzz', 'crank' } -- their ids are 'hotwire:<loop>'

-- Setup -----------------------------------------------------------------------------------------

function Game.new(vehicle, session)
    local self = setmetatable({
        vehicle = vehicle,
        session = session,
        scene = Scene.new(vehicle, Hotwire.placement(vehicle)),
        stage = 'screws',
        tool = 'screwdriver',
        strikes = 0,
        screws = {},
        wires = {},
        falling = {},
        running = true,
        now = GetGameTimer(),
        cursor = 1,
        advanced = {}, -- tools that already handed over to the next one
    }, Game)

    for i = 1, #Rig.screws do self.screws[i] = { turns = 0.0, out = false } end

    for i, def in ipairs(Rig.wires) do
        self.wires[i] = {
            def = def, length = pathLength(def.path), flop = 80.0, sleeve = 0.0, tension = 0.0,
            bend = 0.0, bendGoal = 0.0, -- 0: its own resting shape, 1: bent to reach `endGoal`
        }
        self:shapeWire(i)
    end

    return self
end

function Game:setup()
    local models = { 'tr_hw_column', 'tr_hw_shroud', 'tr_hw_screw', 'tr_hw_screwdriver', 'tr_hw_probe', 'tr_hw_probe_glow',
        'tr_hw_strippers', 'tr_hw_copper', 'tr_hw_twist' }
    for _, def in ipairs(Rig.wires) do
        models[#models + 1] = 'tr_hw_wire_' .. def.color
        models[#models + 1] = 'tr_hw_sleeve_' .. def.color
        models[#models + 1] = 'tr_hw_seg_' .. def.color
    end
    self.scene:preload(models)

    local scene = self.scene
    local cam = cfg.camera
    scene:spawn('column', 'tr_hw_column')

    if self.session.coverOff then
        -- Wired before and the engine was turned off: the cover is still off, so go straight to the wires.
        for _, s in ipairs(self.screws) do s.out = true end
        for i, w in ipairs(self.wires) do
            w.flop = 0.0
            self:shapeWire(i) -- hanging, so tips (and a restored twist) start in the right place
        end
        self:spawnWires()
        self:startWires()
        self:restoreWires(self.session.wires, self.session.twisted)
        scene:createCamera(cam.wiresPos, cam.wiresTarget, cam.fov)
    else
        scene:spawn('shroud', 'tr_hw_shroud')
        for i in ipairs(Rig.screws) do scene:spawn('screw' .. i, 'tr_hw_screw', Rig.screws[i]) end
        scene:spawn('tool', 'tr_hw_screwdriver')
        scene:createCamera(cam.pos, cam.target, cam.fov)
    end

    SetVehicleEngineOn(self.vehicle, false, true, true)

    RequestAnimDict(ANIM_DICT)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(ANIM_DICT) and GetGameTimer() < deadline do Wait(0) end
    TaskPlayAnim(PlayerPedId(), ANIM_DICT, ANIM, 4.0, -4.0, -1, 49, 0.0, false, false, false)
end

function Game:cleanup()
    TR.ui.hud.hide()
    for _, id in ipairs(LOOPS) do TR.ui.sound.stop('hotwire:' .. id) end
    self.scene:destroy()
    StopAnimTask(PlayerPedId(), ANIM_DICT, ANIM, 2.0)
    RemoveAnimDict(ANIM_DICT)
end

-- Server requests -----------------------------------------------------------------------------

---Calls the server without blocking the frame loop. cb gets the callback's results.
function Game:request(cb, name, ...)
    if self.pending then return end
    self.pending = true

    local args = table.pack(...)

    CreateThread(function()
        local result = table.pack(TR.callback.await(name, table.unpack(args, 1, args.n)))
        self.pending = false
        if not self.running or self.ending then return end

        if result[1] == nil then
            -- Not delivered (timeout, rate limit): nothing changed on the server.
            return self:flash(t(result[2] or 'try_again'), 'error')
        elseif result[1] == false then
            -- The server ended the attempt (expired, left the vehicle, ...).
            return self:finish(result[2] or 'no_session')
        end

        if result[1] == 'failed' then return self:fail(result[3]) end
        if math.type(result[2]) == 'integer' then self.strikes = result[2] end
        if cb then cb(table.unpack(result, 1, result.n)) end
    end)
end

-- Endings -------------------------------------------------------------------------------------

function Game:finish(result, extra, delay)
    if self.ending then return end
    self.ending = true
    self.holding = nil
    self.result, self.extra = result, extra
    self.endAt = self.now + (delay or 0)
end

function Game:fail(itemBroke)
    sound('arc')
    self.strikes = self.session.maxStrikes
    self.scene:sparks(self:wireEnd(1), cfg.sparks, 2.0)
    SetVehicleAlarm(self.vehicle, true)
    SetVehicleAlarmTimeLeft(self.vehicle, cfg.alarmTime * 1000)
    StartVehicleAlarm(self.vehicle)
    self:finish('failed', itemBroke, 1500)
end

function Game:succeed()
    self:flash(t('started'), 'success', 2500)
    self.engineAt = self.now + 350
    self:finish('started', nil, 2200)
end

function Game:cancel()
    CreateThread(function() TR.callback.await('tr_minigames:hotwire:cancel') end)
    self:finish('cancelled')
end

---@param tone? 'default' | 'success' | 'error' | 'muted'
function Game:flash(text, tone, duration)
    TR.ui.hud.flash(text, tone, duration)
end

-- Geometry ------------------------------------------------------------------------------------

function Game:screwPos(i)
    return Rig.screws[i] + vec3(0.0, 0.0, -self.screws[i].turns * SCREW_PITCH)
end

-- Wire shape ------------------------------------------------------------------------------------
-- At rest a wire is its solid model. Once moved it bends: it is drawn as a chain of short links
-- along a curve from its top to wherever its end has to be, bowing toward the camera so it passes
-- in front of the other wires. Its length never changes, so a far reach pulls it taut.

local LINKS = 10
local LINK = Rig.segmentLength
local FORWARD = 0.012   -- metres a moved wire's end comes toward the camera, in front of the others
local TWIST_GAP = 0.0068 -- metres between the centres of two twisted wires: the insulation just touches
local TWIST_DROP = 0.006 -- metres from the insulation ends down to where the copper twist starts
local LIFT = vec3(0.0, -0.015, 0.0)

---n + 1 points spaced evenly along a polyline.
local function resample(points, n)
    local lengths, total = { 0.0 }, 0.0
    for k = 2, #points do
        total = total + Vec.length(points[k] - points[k - 1])
        lengths[k] = total
    end

    local out, k = {}, 2
    for j = 0, n do
        local at = total * j / n
        while k < #points and lengths[k] < at do k = k + 1 end
        local span = lengths[k] - lengths[k - 1]
        out[j + 1] = Vec.lerp(points[k - 1], points[k], span > 1e-9 and (at - lengths[k - 1]) / span or 0.0)
    end
    return out
end

local function bezier(p0, p1, p2, p3, steps)
    local points = {}
    for j = 0, steps do
        local t = j / steps
        local u = 1.0 - t
        points[j + 1] = p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)
    end
    return points
end

---A curve of the wire's length from its top to `finish`, leaving the connector the way it rests
---and arriving pointing down. Bows toward the camera the further it reaches sideways.
local function bentShape(top, start, finish, length, arrive)
    local reach = finish - top
    local far = length * 0.97
    if Vec.length(reach) > far then finish = top + Vec.normalize(reach) * far end

    local bow = vec3(0.0, -math.min(0.03, math.abs(finish.x - top.x) * 0.35), 0.0)
    local up = arrive and arrive * -1.0 or vec3(0.0, 0.0, 1.0)

    -- Longer handles make the curve sag more; find the sag that matches the wire's length.
    local lo, hi = 0.0, length
    local points
    for _ = 1, 14 do
        local handle = (lo + hi) / 2
        -- The extra pull at the start brings it forward right from the connector, clear of its neighbours.
        points = bezier(top, top + start * handle + bow + LIFT, finish + up * handle + bow, finish, 24)
        if pathLength(points) > length then hi = handle else lo = handle end
    end
    return points
end

---Rotation whose -Z runs along `along` (from a link's top to its bottom).
local function linkRot(along)
    local z = Vec.normalize(along) * -1.0
    local x = Vec.cross(vec3(0.0, 1.0, 0.0), z)
    x = Vec.length(x) > 1e-6 and Vec.normalize(x) or vec3(1.0, 0.0, 0.0)
    return { x = x, y = Vec.cross(z, x), z = z }
end

---Works out wire i's points for this frame (top to insulation end) and the frame at its end.
function Game:shapeWire(i)
    local w = self.wires[i]
    local def = w.def
    local drop = Mat.axis('x', w.flop)

    local rest = {}
    for k, p in ipairs(def.path) do rest[k] = def.top + Mat.apply(drop, p) end
    local points = resample(rest, LINKS)

    if w.bend > 0.001 and w.endPos then
        local bent = resample(bentShape(def.top, Vec.normalize(points[2] - points[1]), w.endPos, w.length, w.arrive), LINKS)
        for k = 1, #points do points[k] = Vec.lerp(points[k], bent[k], w.bend) end
    end

    w.points = points
    local along = Vec.normalize(points[#points] - points[#points - 1])
    -- A twisted wire's end follows its arrival angle exactly, so its copper meets the twist's middle.
    if w.arrive then along = Vec.lerp(along, w.arrive, w.bend) end
    w.rot = w.bend > 0.001 and linkRot(along) or drop
end

function Game:wireRot(i) return self.wires[i].rot end

---Where the insulation ends (top of the sleeve / copper).
function Game:wireTip(i)
    local points = self.wires[i].points
    return points[#points]
end

---Bends wire i so its insulation end goes to `tip`.
function Game:reach(i, tip)
    local w = self.wires[i]
    w.endGoal = tip
    w.endPos = w.endPos or self:wireTip(i)
    w.bendGoal = 1.0
end

---Lets wire i fall back to its resting shape.
function Game:release(i)
    self.wires[i].bendGoal = 0.0
end

---The very end of the wire: the sleeve's end, or the middle of the bare copper.
function Game:wireEnd(i)
    local w = self.wires[i]
    local depth = w.stripped and COPPER * 0.6 or SLEEVE
    return self:wireTip(i) + Mat.apply(self:wireRot(i), vec3(0.0, 0.0, -depth))
end

function Game:wirePoints(i)
    local points = {}
    for k, p in ipairs(self.wires[i].points) do points[k] = p end
    points[#points + 1] = self:wireEnd(i)
    return points
end

---Nearest wire to the cursor within maxPixels, optionally filtered.
function Game:hoverWire(maxPixels, filter)
    local best, index, point, along = maxPixels, nil, nil, nil

    for i, w in ipairs(self.wires) do
        if not filter or filter(w, i) then
            local d, p, a = self.scene:nearestOnLine(self:wirePoints(i), self.mx, self.my)
            if d < best then best, index, point, along = d, i, p, a end
        end
    end

    return index, point, along
end

---Wire end nearest the cursor (or another screen point) within maxPixels.
function Game:hoverEnd(maxPixels, filter, sx, sy)
    local best, index = maxPixels, nil
    sx, sy = sx or self.mx, sy or self.my

    for i, w in ipairs(self.wires) do
        if not filter or filter(w, i) then
            local x, y = self.scene:project(self:wireEnd(i))
            if x then
                local d = Scene.pixels(x, y, sx, sy)
                if d < best then best, index = d, i end
            end
        end
    end

    return index
end

---The bare copper wire j is closest to the cursor or to screen point (sx, sy), within maxPixels.
---Wires hang at different lengths, so ends rarely line up exactly; any part of the copper counts.
function Game:hoverCopper(maxPixels, exclude, sx, sy)
    local best, index = maxPixels, nil

    for j, w in ipairs(self.wires) do
        if j ~= exclude and w.stripped and not w.twisted then
            local tip = self:wireTip(j)
            local copper = { tip, tip + Mat.apply(self:wireRot(j), vec3(0.0, 0.0, -COPPER)) }
            local d = math.min(
                (self.scene:nearestOnLine(copper, self.mx, self.my)),
                sx and (self.scene:nearestOnLine(copper, sx, sy)) or math.huge
            )
            if d < best then best, index = d, j end
        end
    end

    return index
end

---Orientation for a hand tool whose working end points along +Y: body toward the camera.
function Game:aimTool(pos, side)
    local from = self.scene:cameraPosition() + vec3(side or 0.06, 0.0, -0.05)
    return Mat.look(pos - from, UP)
end

-- Input ---------------------------------------------------------------------------------------

function Game:controls()
    DisableAllControlActions(0)
    EnableControlAction(0, 249, true) -- push to talk
    HideHudAndRadarThisFrame()
    SetMouseCursorActiveThisFrame()
    SetMouseCursorSprite(self.cursor)
    -- Only once the camera is down by the column, where the driver's legs would block the view.
    if Vec.length(self.scene.camPos - self.scene.camGoalPos) < 0.35 then
        SetEntityLocallyInvisible(PlayerPedId())
    end

    self.mx, self.my = GetDisabledControlNormal(0, 239), GetDisabledControlNormal(0, 240)
    self.down = IsDisabledControlPressed(0, KEY.click)
    self.pressed = IsDisabledControlJustPressed(0, KEY.click)

    if self.ending then
        self.down, self.pressed = false, false
        return
    end

    if IsDisabledControlJustPressed(0, KEY.pause) or IsDisabledControlJustPressed(0, KEY.back) then
        return self:cancel()
    end

    if self.stage == 'wires' and not self.holding then
        for i, key in ipairs(KEY.tool) do
            if IsDisabledControlJustPressed(0, key) then self:setTool(TOOLS[i]) end
        end

        local index = 1
        for i, tool in ipairs(TOOLS) do if tool == self.tool then index = i end end
        if IsDisabledControlJustPressed(0, KEY.scrollDown) then self:setTool(TOOLS[index % #TOOLS + 1]) end
        if IsDisabledControlJustPressed(0, KEY.scrollUp) then self:setTool(TOOLS[(index - 2) % #TOOLS + 1]) end
    end
end

function Game:setTool(tool)
    if self.tool == tool then return end
    self.advanced[self.tool] = self.advanced[self.tool] or self:stepDone(self.tool)
    self.tool = tool
    for name in pairs(TOOL_MODELS) do self.scene:setVisible(name, name == tool) end
    self.scene:setVisible('glow', false)
    sound('click')
end

-- Step 1: screws ------------------------------------------------------------------------------

function Game:screwStep(dt)
    local scene = self.scene
    local h = self.holding

    if h and not self.down then
        self.holding, h = nil, nil
    end

    local hovered
    if not h then
        for i, s in ipairs(self.screws) do
            local x, y = scene:project(self:screwPos(i))
            if not s.out and x and Scene.pixels(x, y, self.mx, self.my) < 30 then hovered = i end
        end

        if hovered and self.pressed then
            h = { screw = hovered, speed = 0.0, wrong = 0.0, ticks = 0 }
            self.holding = h
        end
    end

    if h then self:turnScrew(h, dt) end

    local driver = scene:get('tool')
    if not driver then return end

    local target = h and h.screw or hovered
    self.ringScrew = target

    if target then
        -- On a screw: seated in its PH2 recess, almost in line with it like a real screwdriver. The lean
        -- pivots at the recess mouth so the tip fits exactly where it shows.
        local lean = Mat.axis('x', 6.0)
        driver.pos = self:screwPos(target) + vec3(0.0, 0.0, Rig.screwFace) + Mat.apply(lean, vec3(0.0, 0.0, Rig.driveDepth))
        driver.rot = Mat.mul(lean, Mat.axis('z', -self.screws[target].turns * 360.0))
    else
        -- Between screws the handle leans away so it doesn't hide the cover.
        driver.pos = scene:onPlane(self.mx, self.my, 'z', Rig.screws[1].z - 0.012)
        driver.rot = Mat.mul(Mat.axis('y', 15.0), Mat.axis('x', 28.0))
    end

    self.cursor = target and 3 or 1
end

---Circling the mouse counter-clockwise around the screw undoes it.
function Game:turnScrew(h, dt)
    local s = self.screws[h.screw]
    local cx, cy = self.scene:project(self:screwPos(h.screw))
    if not cx then return end

    local w, hgt = GetActiveScreenResolution()
    local dx, dy = (self.mx - cx) * w, (self.my - cy) * hgt
    if dx * dx + dy * dy < 100 then return end -- too close to the centre to read a direction

    local angle = math.atan(dy, dx)

    if h.angle then
        -- Screen y points down, so a clockwise circle increases the angle.
        local loosen = -AngleDelta(h.angle, angle) / (math.pi * 2)
        s.turns = Clamp(s.turns + loosen, 0.0, cfg.screws.turns)
        h.speed = Lerp(h.speed, math.abs(loosen) / math.max(dt, 0.001), 0.15)

        if loosen < 0 then
            h.wrong = h.wrong - loosen
            if h.wrong > 0.5 then
                h.wrong = 0.0
                self:flash(t('wrong_way'), 'muted')
            end
        end

        local ticks = math.floor(s.turns * 8) -- a notch every eighth of a turn
        if ticks ~= h.ticks then
            h.ticks = ticks
            sound('tick')
        end

        if h.speed > cfg.screws.maxSpeed then
            s.turns = math.max(0.0, s.turns - 0.35)
            self.holding = nil
            self:flash(t('slipped'), 'error')
            sound('slip')
            ShakeCam(self.scene.cam, 'SMALL_EXPLOSION_SHAKE', 0.03)
            return
        end
    end

    h.angle = angle

    if s.turns >= cfg.screws.turns then
        s.out = true
        self.holding = nil
        self:drop('screw' .. h.screw)
        sound('screw_out')

        for _, other in ipairs(self.screws) do
            if not other.out then return end
        end

        self:request(function() self:openCover() end, 'tr_minigames:hotwire:cover')
    end
end

---Lets a prop fall out of the rig and disappear.
function Game:drop(id, push)
    local part = self.scene:get(id)
    if not part then return end
    self.falling[#self.falling + 1] = { id = id, vel = push or vec3(0.0, -0.05, 0.0), spin = math.random(-400, 400), age = 0.0 }
end

function Game:openCover()
    sound('cover')
    self.stage = 'opening'
    self.coverAge = 0.0
    self.scene:remove('tool')
    self.cursor = 1

    local cam = cfg.camera
    self.scene:moveCamera(cam.wiresPos, cam.wiresTarget)
end

function Game:coverStep(dt)
    self.coverAge = self.coverAge + dt
    local k = math.min(self.coverAge / 0.9, 1.0)
    local shroud = self.scene:get('shroud')

    if shroud then
        shroud.pos = vec3(0.0, -0.04 * k, -0.4 * k * k)
        shroud.rot = Mat.axis('x', -40.0 * k)
    end

    if k > 0.3 and not self.wiresOut then
        self:spawnWires()
        self.wiresAge = 0.0 -- they drop out and swing
    end

    if k >= 1.0 then
        self.scene:remove('shroud')
        self:startWires()
    end
end

function Game:spawnWires()
    self.wiresOut = true
    local scene = self.scene
    for i, w in ipairs(self.wires) do
        local color = w.def.color
        scene:spawn('wire' .. i, 'tr_hw_wire_' .. color, w.def.top, Mat.axis('x', w.flop))
        scene:spawn('sleeve' .. i, 'tr_hw_sleeve_' .. color, self:wireTip(i), self:wireRot(i))
    end
end

---Hands the player the test light: the wires step begins.
function Game:startWires()
    local scene = self.scene
    scene:spawn('probe', 'tr_hw_probe', vec3(0.0, TIP_Y - 0.02, -0.15))
    scene:spawn('strippers', 'tr_hw_strippers', vec3(0.0, TIP_Y - 0.02, -0.15))
    scene:spawn('glow', 'tr_hw_probe_glow')
    scene:setVisible('strippers', false)
    scene:setVisible('glow', false)
    self.tool = 'probe'
    self.stage = 'wires'
end

---Hotwired before: the wires found then are still labelled and bare, and battery and ignition are
---still twisted together. Only the starter is left for the hands.
function Game:restoreWires(list, twisted)
    if type(list) ~= 'table' or #list == 0 then return end

    local scene = self.scene
    for _, entry in ipairs(list) do
        local i, w = entry.wire, self.wires[entry.wire]
        if w then
            w.reading, w.asked, w.stripped = entry.reading, true, true
            scene:remove('sleeve' .. i)
            scene:spawn('copper' .. i, 'tr_hw_copper', self:wireTip(i), self:wireRot(i))
        end
    end

    if self:stepDone('probe') and self:stepDone('strippers') then
        self.advanced.probe, self.advanced.strippers = true, true
        self:setTool('hand')
        if type(twisted) == 'table' and self.wires[twisted[1]] and self.wires[twisted[2]] then
            -- Already twisted last time: the ends start where they meet, with the twist in place.
            self:joinWires(twisted[1], twisted[2])
            for _, i in ipairs(twisted) do
                local w = self.wires[i]
                w.bend, w.endPos = 1.0, w.endGoal
                self:shapeWire(i)
            end
            local top = (self:wireTip(twisted[1]) + self:wireTip(twisted[2])) * 0.5 + vec3(0.0, 0.0, -TWIST_DROP)
            self.scene:spawn('twist', 'tr_hw_twist', top)
            self.twistAge = 1.0
        end
        self:flash(t('rewired'), 'default', 2600)
    end
end

-- Step 2: wires -------------------------------------------------------------------------------

local function glowLevel(reading, now)
    if reading == 'steady' then return 1.0 end
    if reading == 'dim' then return 0.3 end
    if reading == 'pulse' then return 0.5 + 0.5 * math.sin(now / 160.0) end
    if reading == 'flicker' then return (math.floor(now / 55) * 7919) % 5 < 2 and 1.0 or 0.05 end
    return 0.0
end

-- Players nearby light the test light's bulb themselves, from the hum's pattern, so it flickers
-- at the right rhythm instead of at the update rate (TR.mirror).
Mirror.effects.hotwire = function(replica, now)
    local n, bulb, target = replica:find('tr_hw_probe_glow')
    if not n then return end

    local buzz = replica.loops.buzz
    local glow = buzz and glowLevel(buzz[2] and buzz[2].pattern, now) or 0.0
    target.ownVisibility = true
    replica.scene:setVisible(n, glow > 0.45)
    if glow > 0.02 then replica.scene:light(bulb.pos, 255, 170, 70, 0.12, 6.0 * glow) end
end

function Game:probeStep()
    local scene = self.scene
    local probe = scene:get('probe')
    local i, point = self:hoverWire(16)

    self.glow = 0.0
    self.probing = nil

    if i then
        local cam = scene:cameraPosition()
        probe.pos = point + Vec.normalize(cam - point) * 0.0035

        local w = self.wires[i]
        if self.pressed then sound('click') end
        if self.down then
            self.probing = w.reading or 'none'
            if w.reading == nil and not w.asked then
                w.asked = true
                self:request(function(_, reading) w.reading = reading end, 'tr_minigames:hotwire:probe', i)
            end
            self.glow = glowLevel(w.reading, self.now)
        end
    else
        probe.pos = scene:onPlane(self.mx, self.my, 'y', TIP_Y - 0.008)
    end

    probe.rot = self:aimTool(probe.pos, 0.07)

    local glow = scene:get('glow')
    glow.pos = probe.pos + Mat.apply(probe.rot, Rig.probeBulb)
    glow.rot = probe.rot
    scene:setVisible('glow', self.glow > 0.45)
end

function Game:stripStep(dt)
    local scene = self.scene
    local tool = scene:get('strippers')
    local h = self.holding

    if h and not self.down then
        self.holding, h = nil, nil
    end

    if not h then
        local i = self:hoverWire(18, function(w) return not w.stripped end)

        if i then
            local w = self.wires[i]
            tool.pos = self:wireTip(i) + Mat.apply(self:wireRot(i), vec3(0.0, 0.0, -0.003 - w.sleeve))

            if self.pressed then
                if not scene:get('copper' .. i) then
                    scene:spawn('copper' .. i, 'tr_hw_copper', self:wireTip(i), self:wireRot(i))
                end
                local p = scene:onPlane(self.mx, self.my, 'y', self:wireTip(i).y)
                h = { wire = i, startZ = p.z + w.sleeve }
                self.holding = h
            end
        else
            tool.pos = scene:onPlane(self.mx, self.my, 'y', TIP_Y - 0.008)
        end

        self.cursor = i and 3 or 1
    end

    if h then
        self.cursor = 4
        local w = self.wires[h.wire]
        local p = scene:onPlane(self.mx, self.my, 'y', self:wireTip(h.wire).y)
        local before = w.sleeve

        w.sleeve = math.max(w.sleeve, Clamp(h.startZ - p.z, 0.0, SLEEVE + 0.01))

        local speed = (w.sleeve - before) / math.max(dt, 0.001)
        local limit = cfg.strip.maxSpeed

        if speed > limit then
            w.tension = w.tension + (speed / limit - 1.0) * dt * 5.0
        else
            w.tension = math.max(0.0, w.tension - dt * 1.5)
        end

        tool.pos = self:wireTip(h.wire) + Mat.apply(self:wireRot(h.wire), vec3(0.0, 0.0, -0.003 - w.sleeve))

        if w.tension >= 1.0 then
            w.tension, w.sleeve = 0.0, 0.0
            self.holding = nil
            self:flash(t('nicked'), 'error')
            sound('nick')
            self:request(nil, 'tr_minigames:hotwire:nick', h.wire)
        elseif w.sleeve >= SLEEVE + 0.002 then
            w.stripped, w.tension = true, 0.0
            self.holding = nil
            self:drop('sleeve' .. h.wire)
            sound('snip')
            self:request(nil, 'tr_minigames:hotwire:strip', h.wire)
        end
    end

    tool.rot = self:aimTool(tool.pos, -0.07)
end

local function bare(w) return w.stripped and not w.twisted end

function Game:handStep()
    local h = self.holding

    if not h then
        local i = self:hoverEnd(26, bare)
        self.cursor = i and 3 or 1

        if i and self.pressed then
            self.holding = { wire = i }
        elseif self.pressed and self:hoverWire(16, function(w) return not w.stripped end) then
            self:flash(t('strip_first'), 'muted')
        end
        return
    end

    self.cursor = 4
    local scene = self.scene
    local w = self.wires[h.wire]

    -- The wire bends so its end follows the cursor, in front of the other wires.
    local depth = w.stripped and COPPER * 0.6 or SLEEVE
    self:reach(h.wire, scene:onPlane(self.mx, self.my, 'y', TIP_Y - FORWARD) + vec3(0.0, 0.0, depth))

    local ex, ey = scene:project(self:wireEnd(h.wire))
    if not ex then return end

    if not self.twistPoint then
        h.target = self:hoverCopper(30, h.wire, ex, ey)

        if not self.down then
            self.holding = nil
            self:release(h.wire)
            if h.target then
                local a, b = h.wire, h.target
                self:request(function(result) self:onTwist(result, a, b) end, 'tr_minigames:hotwire:twist', a, b)
            end
        end
        return
    end

    -- Battery and ignition are twisted: touching the starter to them cranks the engine.
    -- Contact when the wire's end or the cursor is on the twist.
    local tx, ty = scene:project(self.twistPoint)
    local contact = tx and math.min(Scene.pixels(ex, ey, tx, ty), Scene.pixels(self.mx, self.my, tx, ty)) < 32

    if contact and not h.crankStart then
        h.crankStart, h.nextSpark = self.now, 0
        ShakeCam(scene.cam, 'ROAD_VIBRATION_SHAKE', 0.4)
    end

    if h.crankStart then
        local held = self.now - h.crankStart

        if self.now >= h.nextSpark then
            h.nextSpark = self.now + math.random(90, 220)
            scene:sparks(self.twistPoint, cfg.sparks, 0.6)
        end

        if not contact or not self.down or held > self.session.crank.closes + 600 then
            local wire = h.wire
            StopCamShaking(scene.cam, false)
            self.holding = nil
            self:release(wire)
            self:request(function(result) self:onCrank(result, wire) end, 'tr_minigames:hotwire:crank', wire, math.floor(held))
        end
    elseif not self.down then
        self.holding = nil
        self:release(h.wire)
    end
end

---Brings the ends of wires a and b together and twists their copper.
function Game:joinWires(a, b)
    local wa, wb = self.wires[a], self.wires[b]
    local ra, rb = wa.def.top + wa.def.tip, wb.def.top + wb.def.tip

    -- The ends meet side by side (each keeps its side) in front of the other wires, at the
    -- height of the higher end; the longer wire sags a little more. The copper twist sits between.
    local side = ra.x < rb.x and -1.0 or 1.0
    local z = math.max(self:wireTip(a).z, self:wireTip(b).z)
    local meet = vec3((ra.x + rb.x) / 2, TIP_Y - FORWARD, z)

    -- Like real twisted wires the pair forms a Y: each comes in leaning toward the other so its bare
    -- copper runs into the twist, which starts just below the insulation.
    local half = TWIST_GAP / 2
    local lean = Vec.normalize(vec3(half, 0.0, -math.sqrt(COPPER * COPPER - half * half)))
    wa.twisted, wb.twisted = true, true
    wa.arrive = vec3(-side * lean.x, 0.0, lean.z)
    wb.arrive = vec3(side * lean.x, 0.0, lean.z)
    self:reach(a, meet + vec3(side * half, 0.0, 0.0))
    self:reach(b, meet - vec3(side * half, 0.0, 0.0))
    self.twistWires = { a, b }
    self.twistAge = 0.0
end

function Game:onTwist(result, a, b)
    if result == 'twisted' then
        self:joinWires(a, b)
        self:flash(t('twisted'), 'success')
        sound('relay')
    elseif result == 'short' then
        self.scene:sparks(self:wireEnd(a), cfg.sparks, 1.5)
        ApplyDamageToPed(PlayerPedId(), cfg.shockDamage, false)
        self:flash(t('short'), 'error')
        sound('arc')
    else
        self:flash(t('nothing'), 'muted')
    end
end

function Game:onCrank(result, wire)
    if result == 'started' then return self:succeed() end

    if result == 'overcrank' then
        self.scene:sparks(self:wireEnd(wire), cfg.sparks, 1.5)
        self:flash(t('overcrank'), 'error')
        sound('burn')
    elseif result == 'sputter' then
        self:flash(t('sputter'), 'muted')
        sound('sputter')
    else
        self:flash(t('nothing'), 'muted')
    end
end

-- Progress ------------------------------------------------------------------------------------
-- The wires step moves to the next tool on its own once the current one has done its job. The
-- player can still switch back and forth with 1-3 or the scroll wheel; each hand-off happens once.

local NEEDED = { steady = true, pulse = true, flicker = true } -- battery, ignition, starter
local AUTO_DELAY = 900 -- ms to see the result before the tool changes

---Whether a tool's job is finished, for the check mark on its slot.
function Game:stepDone(tool)
    local found, stripped = self:progress()
    if tool == 'probe' then return found == 3 end
    if tool == 'strippers' then return stripped == 3 end
    return false
end

---How many of the three wires that matter the test light has found, and how many of those are stripped.
function Game:progress()
    local found, stripped = 0, 0
    for _, w in ipairs(self.wires) do
        if NEEDED[w.reading] then
            found = found + 1
            if w.stripped then stripped = stripped + 1 end
        end
    end
    return found, stripped
end

function Game:autoAdvance()
    if self.stage ~= 'wires' or self.holding or self.pending then
        self.autoAt = nil
        return
    end

    local found, stripped = self:progress()
    local next, message
    if self.tool == 'probe' and found == 3 and not self.advanced.probe then
        next, message = 'strippers', 'next_strip'
    elseif self.tool == 'strippers' and stripped == 3 and not self.advanced.strippers then
        next, message = 'hand', 'next_hand'
    end

    if not next then
        self.autoAt = nil
        return
    end

    self.autoAt = self.autoAt or self.now + AUTO_DELAY
    if self.now < self.autoAt then return end

    self.autoAt = nil
    self.advanced[self.tool] = true
    self:setTool(next)
    self:flash(t(message), 'default', 2200)
end

-- Animation -----------------------------------------------------------------------------------

---Shows wire i as its solid model at rest, or as a chain of links when it is bent.
function Game:drawWire(i)
    local scene, w = self.scene, self.wires[i]
    local wire = scene:get('wire' .. i)
    if not wire then return end

    local bent = w.bend > 0.01
    if bent and not w.links then
        w.links = true
        for n = 1, LINKS do scene:spawn(('link%d_%d'):format(i, n), 'tr_hw_seg_' .. w.def.color) end
    end

    scene:setVisible('wire' .. i, not bent)
    wire.rot = Mat.axis('x', w.flop)
    if not w.links then return end

    local points = w.points
    for n = 1, LINKS do
        local id = ('link%d_%d'):format(i, n)
        local link = scene:get(id)
        if link then
            scene:setVisible(id, bent)
            if bent then
                local rot = linkRot(points[n + 1] - points[n])
                link.rot = rot
                -- The last link ends exactly at the insulation end, so it never covers the copper.
                link.pos = n == LINKS and points[n + 1] + Mat.apply(rot, vec3(0.0, 0.0, LINK)) or points[n]
            end
        end
    end
end

function Game:animate(dt)
    local scene = self.scene

    for i, s in ipairs(self.screws) do
        local part = not s.out and scene:get('screw' .. i)
        if part then
            part.pos = self:screwPos(i)
            part.rot = Mat.axis('z', -s.turns * 360.0)
        end
    end

    if self.wiresAge then
        self.wiresAge = self.wiresAge + dt
        local a = self.wiresAge
        local swing = 80.0 * math.exp(-4.5 * a)
        if swing < 0.05 then self.wiresAge = nil end -- swung out: they hang still
        for _, w in ipairs(self.wires) do w.flop = self.wiresAge and swing * math.cos(a * 9.0) or 0.0 end
    end

    -- Eases stop at their goal, and a wire is only reshaped and redrawn when something about it changed:
    -- resting wires cost nothing.
    local k = Clamp(dt * 10.0, 0.0, 1.0)
    for i, w in ipairs(self.wires) do
        w.bend = Lerp(w.bend, w.bendGoal, Clamp(dt * 8.0, 0.0, 1.0))
        if w.bend < 0.002 and w.bendGoal == 0.0 then w.bend, w.endPos = 0.0, nil end
        if w.bend > 0.999 and w.bendGoal == 1.0 then w.bend = 1.0 end
        if w.endGoal and w.endPos then
            w.endPos = #(w.endPos - w.endGoal) < 1e-4 and w.endGoal or Vec.lerp(w.endPos, w.endGoal, k)
        end
        local shaped = w.shaped
        if not shaped or shaped.bend ~= w.bend or shaped.flop ~= w.flop or shaped.endPos ~= w.endPos
            or shaped.arrive ~= w.arrive or shaped.out ~= self.wiresOut then
            w.shaped = { bend = w.bend, flop = w.flop, endPos = w.endPos, arrive = w.arrive, out = self.wiresOut }
            self:shapeWire(i)
            self:drawWire(i)
        end

        local rot, tip = self:wireRot(i), self:wireTip(i)
        local sleeve, copper = scene:get('sleeve' .. i), scene:get('copper' .. i)

        if sleeve and not w.stripped then
            sleeve.pos = tip + Mat.apply(rot, vec3(0.0, 0.0, -w.sleeve))
            sleeve.rot = rot
        end
        if copper then
            copper.pos, copper.rot = tip, rot
        end
    end

    -- Once the twisted wires have come together, the copper twist appears just below their ends.
    -- Their bare copper stays, angled into the twist, so the joint looks wound rather than glued on.
    if self.twistAge then
        self.twistAge = self.twistAge + dt
        local a, b = self.twistWires[1], self.twistWires[2]
        local top = (self:wireTip(a) + self:wireTip(b)) * 0.5 + vec3(0.0, 0.0, -TWIST_DROP)
        self.twistPoint = top + vec3(0.0, 0.0, -0.008)

        if self.twistAge > 0.35 and not scene:get('twist') then
            scene:spawn('twist', 'tr_hw_twist', top)
            sound('click')
        end

        local twist = scene:get('twist')
        if twist then twist.pos = top end
    end

    for n = #self.falling, 1, -1 do
        local f = self.falling[n]
        local part = scene:get(f.id)
        f.age = f.age + dt

        if not part or f.age > 0.9 then
            scene:remove(f.id)
            table.remove(self.falling, n)
        else
            f.vel = f.vel + vec3(0.0, 0.0, -9.8 * dt)
            part.pos = part.pos + f.vel * dt
            part.rot = Mat.mul(part.rot, Mat.axis('x', f.spin * dt))
        end
    end

    if self.engineAt and self.now >= self.engineAt then
        self.engineAt = nil
        SetVehicleNeedsToBeHotwired(self.vehicle, false)
        SetVehicleEngineOn(self.vehicle, true, false, true)
    end
end

function Game:effects()
    local scene = self.scene
    scene:torch()

    if self.glow and self.glow > 0.02 and self.tool == 'probe' then
        local glow = scene:get('glow')
        if glow then scene:light(glow.pos, 255, 170, 70, 0.12, 6.0 * self.glow) end
    end
end

-- Sound loops ---------------------------------------------------------------------------------
-- Continuous sounds that follow what the player is doing. The page only gets changes.

function Game:soundLoops()
    local h = self.holding
    local active = {}

    if not self.ending then
        -- Test light hum, in the bulb's rhythm.
        if self.tool == 'probe' and self.probing then active.buzz = { 'buzz', { pattern = self.probing } } end

        -- Starter wire on the twist.
        if h and h.crankStart then active.crank = { 'crank' } end
    end

    for _, id in ipairs(LOOPS) do
        local loop = active[id]
        if loop then
            TR.ui.sound.loop('hotwire:' .. id, loop[1], loop[2], Config.volume)
        else
            TR.ui.sound.stop('hotwire:' .. id)
        end
    end

    if self.mirror then self.mirror:setLoops(active) end
end

-- HUD -----------------------------------------------------------------------------------------
-- Drawn by the page (TR.ui.hud). The state is rebuilt every frame; only changes are sent.

---Screen position rounded so tiny camera drift doesn't resend the HUD every frame.
local function screen(x, y)
    return math.floor(x * 2000 + 0.5) / 2000, math.floor(y * 2000 + 0.5) / 2000
end

function Game:hint()
    local keys = { { key = 'ESC', label = t('give_up') } }
    if self.stage == 'screws' then return { text = t('hint_screws'), keys = keys } end
    if self.stage ~= 'wires' then return end

    table.insert(keys, 1, { key = '1-3', label = t('switch_tool') })

    if self.tool == 'probe' then return { text = t('hint_probe'), sub = t('legend'), keys = keys } end
    if self.tool == 'strippers' then return { text = t('hint_strippers'), keys = keys } end
    return { text = t(self.twistPoint and 'hint_crank' or 'hint_twist'), keys = keys }
end

function Game:markers()
    local markers = {}

    local function add(marker, pos)
        local x, y = self.scene:project(pos)
        if not x then return end
        marker.x, marker.y = screen(x, y)
        markers[#markers + 1] = marker
    end

    -- What the test light showed on each wire, under its end.
    if self.stage == 'wires' then
        for i, w in ipairs(self.wires) do
            if w.reading and not w.twisted then
                add({ id = 'reading' .. i, kind = 'label', text = t('reading_' .. w.reading) },
                    self:wireEnd(i) + vec3(0.0, 0.0, -0.012))
            end
        end
    end

    -- Unscrewing: a ring around the screw under the cursor shows direction and progress.
    if self.stage == 'screws' and self.ringScrew then
        local turns = self.screws[self.ringScrew].turns
        add({ id = 'screw', kind = 'ring', spin = true, progress = math.floor(turns / cfg.screws.turns * 28) / 28 },
            self:screwPos(self.ringScrew))
    end

    -- Dragging a wire: ring the wire end it will connect to on release.
    local held = self.holding
    if held and held.target and self.tool == 'hand' then
        add({ id = 'target', kind = 'ring', progress = 1.0 }, self:wireEnd(held.target))
    end

    return #markers > 0 and markers or nil
end

function Game:meter()
    local h = self.holding
    if h and h.wire and self.tool == 'strippers' then
        local tension = math.floor(self.wires[h.wire].tension * 50 + 0.5) / 50
        return { value = tension, tone = tension > 0.6 and 'danger' or 'accent' }
    elseif h and h.crankStart then
        -- The page fills the bar by itself; a new crankStart restarts it.
        local crank = self.session.crank
        local scale = crank.closes + 800
        return { label = t('crank'), zone = { crank.opens / scale, crank.closes / scale }, duration = scale, run = h.crankStart }
    end
end

function Game:draw()
    -- Once it's decided only the result message stays up.
    if self.ending then return TR.ui.hud.hide() end

    local tools
    if self.stage == 'wires' then
        local found, stripped = self:progress()
        local counts = { probe = found, strippers = stripped }
        tools = {}
        for i, tool in ipairs(TOOLS) do
            local done = self:stepDone(tool)
            tools[i] = {
                key = tostring(i),
                label = t('tool_' .. tool),
                active = tool == self.tool,
                done = done,
                progress = not done and counts[tool] and ('%d/3'):format(counts[tool]) or nil,
            }
        end
    end

    TR.ui.hud.set({
        hint = self:hint(),
        tools = tools,
        strikes = { label = t('strikes'), used = self.strikes, max = self.session.maxStrikes },
        meter = self:meter(),
        markers = self:markers(),
    })
end

-- Loop ----------------------------------------------------------------------------------------

function Game:stillDriving()
    local ped = PlayerPedId()
    return DoesEntityExist(self.vehicle) and GetPedInVehicleSeat(self.vehicle, -1) == ped and not IsEntityDead(ped)
end

function Game:loop()
    while true do
        local dt = GetFrameTime()
        self.now = GetGameTimer()

        if self.ending and self.now >= self.endAt then break end
        if not self.ending and not self:stillDriving() then
            CreateThread(function() TR.callback.await('tr_minigames:hotwire:cancel') end)
            self:finish('left_vehicle')
        end

        self:controls()
        if not self.ending then self:autoAdvance() end

        if not self.ending then
            if self.stage == 'screws' then
                self:screwStep(dt)
            elseif self.stage == 'opening' then
                self:coverStep(dt)
            elseif self.tool == 'probe' then
                self:probeStep()
            elseif self.tool == 'strippers' then
                self:stripStep(dt)
            else
                self:handStep()
            end
        end

        self:animate(dt)
        self.scene:update()
        self:effects()
        self:draw()
        self:soundLoops()
        self.mirror:tick(self.now)
        Wait(0)
    end
end

Hotwire.Game = Game -- for tests

---Runs the minigame to the end. Blocks the calling thread.
---@return string result, any extra
function Hotwire.run(vehicle, session)
    local game = Game.new(vehicle, session)
    game.mirror = Mirror.sender(game.scene, 'hotwire')
    game.scene.mirror = game.mirror
    Hotwire.current = game
    local ok, err = pcall(function()
        game:setup()
        game:loop()
    end)

    game.running = false
    Hotwire.current = nil
    game.mirror:stop()
    game:cleanup()

    if not ok then
        TR.log.error('hotwire minigame failed: %s', err)
        CreateThread(function() TR.callback.await('tr_minigames:hotwire:cancel') end)
        return tostring(err):find('model') and 'missing_models' or 'try_again'
    end

    return game.result, game.extra
end
