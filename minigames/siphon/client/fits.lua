--[[
    The filler fits every car model has (placement.lua uses them): from the server on join, and
    every time someone saves one with /filler_fitall or /filler_autofit (dev mode).

        local moved = Siphon.nudged(model, vehicle)   -- the fit moved by the key just pressed, or nil

    A fit is where filler space sits on the car: { x, y, z, pitch, yaw } in vehicle space.
]]

local cfg = Config.siphon

if not cfg.enabled then return end

CreateThread(function()
    -- On a restart the server side may not be up yet: ask again a few times.
    for _ = 1, 5 do
        local fits = TR.callback.await('tr_minigames:siphon:fits')
        if type(fits) == 'table' then
            for model, fit in pairs(fits) do Siphon.savedFits[model] = fit end
            return
        end
        Wait(3000)
    end
end)

RegisterNetEvent('tr_minigames:siphon:fitSaved', function(model, fit)
    Siphon.savedFits[model] = fit
end)

-- Dev keys that move the filler while fitting it: 5 mm a press, 1 mm with Shift held. Held down, a key
-- keeps moving it after HOLD seconds (SPEED a second, a fifth of that with Shift). In filler space:
-- +X to the right of a player facing the car, +Y into it, +Z up.
local NUDGE = {
    { 174, vec3(-1.0, 0.0, 0.0) }, { 175, vec3(1.0, 0.0, 0.0) }, -- arrow left / right: along the car
    { 34, vec3(-1.0, 0.0, 0.0) }, { 35, vec3(1.0, 0.0, 0.0) },   -- A / D
    { 172, vec3(0.0, 0.0, 1.0) }, { 173, vec3(0.0, 0.0, -1.0) }, -- arrow up / down
    { 32, vec3(0.0, 0.0, 1.0) }, { 33, vec3(0.0, 0.0, -1.0) },   -- W / S
    { 44, vec3(0.0, -1.0, 0.0) }, { 38, vec3(0.0, 1.0, 0.0) },   -- Q / E: out of / into the car
}

-- And turn it to sit flat on the paint: 1 degree a press, a quarter with Shift held.
local TURN = {
    { 241, 'pitch', 1, true }, { 242, 'pitch', -1, true }, -- scroll up / down: tip the face up / down (no holding)
    { 111, 'pitch', 1 }, { 112, 'pitch', -1 },             -- numpad 8 / 5
    { 20, 'yaw', -1 }, { 73, 'yaw', 1 },                   -- Z / X: turn the face left / right
    { 108, 'yaw', -1 }, { 109, 'yaw', 1 },                 -- numpad 4 / 6
}

local HOLD = 0.3
local SPEED = { move = 0.08, turn = 12.0 } -- metres, degrees a second
local heldFor = {}                         -- control -> seconds held down

---How far control `n` moves things this frame, in presses: 1 the frame it is pressed, then nothing
---until it has been held HOLD seconds, then `rate` presses a second.
local function presses(n, rate, tapOnly)
    if IsDisabledControlJustPressed(0, n) then
        heldFor[n] = 0.0
        return 1.0
    end
    if tapOnly or not IsDisabledControlPressed(0, n) then
        heldFor[n] = nil
        return 0.0
    end
    local dt = GetFrameTime()
    local before = heldFor[n] or 0.0
    heldFor[n] = before + dt
    if heldFor[n] < HOLD then return 0.0 end
    return rate * math.min(dt, heldFor[n] - HOLD)
end

local function copy(fit)
    return { x = fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = fit.yaw, both = fit.both }
end

---The fit moved by the dev key just pressed (read with controls disabled), or nil. Without a fit of
---its own the car's guess (petroltank bone or the flank above a wheel) is where it starts from.
---@param side? number the side the guess is on when the car has no petroltank bone
function Siphon.nudged(model, vehicle, side)
    local fine = IsDisabledControlPressed(0, 21)

    local function current()
        local fit = Siphon.fit(model)
        if fit then return copy(fit) end
        return Siphon.guessFit(vehicle, side)
    end

    -- Every key held counts (two at once move diagonally); nil when nothing moved.
    local fit
    local degrees = fine and 0.25 or 1.0
    for _, n in ipairs(TURN) do
        local k = presses(n[1], SPEED.turn / degrees * (fine and 0.2 or 1.0), n[4])
        if k > 0 then
            fit = fit or current()
            if not fit then return end
            fit[n[2]] = fit[n[2]] + n[3] * degrees * k
            fit.pitch = Clamp(fit.pitch, -45.0, 45.0)
        end
    end

    local step = fine and 0.001 or 0.005
    for _, n in ipairs(NUDGE) do
        local k = presses(n[1], SPEED.move / step * (fine and 0.2 or 1.0))
        if k > 0 then
            fit = fit or current()
            if not fit then return end
            local p = vec3(fit.x, fit.y, fit.z) + Mat.apply(Siphon.fitAxes(fit), n[2] * step * k)
            fit.x, fit.y, fit.z = p.x, p.y, p.z
        end
    end
    return fit
end

---The fit on the car's other flank: mirrored across the car's middle (for cars whose guess picked
---the wrong side).
function Siphon.mirrorFit(fit)
    return { x = -fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = -fit.yaw, both = fit.both }
end
