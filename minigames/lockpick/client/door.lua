--[[
    Where a door's lock cylinder sits: at the rear end of its handle, flat on the door skin.

        local offset, pitch, yaw = Lockpick.placement(vehicle, 'dside_f')
        local scene = Scene.new(vehicle, offset, pitch, yaw)
        local vehicle, door = Lockpick.nearestDoor()

    Lock space (rig space): origin at the plug's face, +Y into the door, +Z up. The spot starts at
    the handle's bone, moved by Config.lockpick.rig (or a vehicleFits entry); a ray then finds the
    door's surface there so the bezel sits on the paint, turned to match the door's curve.
]]

local cfg = Config.lockpick

Lockpick = Lockpick or {}

-- Which side of the car a door is on (the vehicle's X), and its index for the door natives.
local SIDE = { dside_f = -1, dside_r = -1, pside_f = 1, pside_r = 1 }
Lockpick.doorIndex = { dside_f = 0, pside_f = 1, dside_r = 2, pside_r = 3 }

---Spawn name of the vehicle's model, the key for vehicleFits.
function Lockpick.modelName(vehicle)
    return GetEntityArchetypeName(vehicle):lower()
end

-- Fits by model. live: being tuned right now (/lockpick_rig, the fitters), until the resource
-- restarts. saved: made with /lockpick_autofit or /lockpick_fitall, kept by the server in
-- minigames/lockpick/fits.json.
-- A fit is { back, up, out } from the handle's bone onto the door's collision, or, when measured,
-- { x, y, z, pitch, yaw } exactly where the lock goes in the car's space (driver's door only).
Lockpick.liveFits = {}
Lockpick.savedFits = {}
Lockpick.fitDoor = 'dside_f' -- the door measured fits are for

---@return table fit, string source
function Lockpick.fit(model)
    if Lockpick.liveFits[model] then return Lockpick.liveFits[model], 'live' end
    if Lockpick.savedFits[model] then return Lockpick.savedFits[model], 'saved' end
    if cfg.vehicleFits[model] then return cfg.vehicleFits[model], 'config' end
    return cfg.rig, 'default'
end

CreateThread(function()
    -- On a restart the server side may not be up yet: ask again a few times.
    for _ = 1, 5 do
        local fits = TR.callback.await('tr_minigames:lockpick:fits')
        if type(fits) == 'table' then
            for model, fit in pairs(fits) do Lockpick.savedFits[model] = fit end
            return
        end
        Wait(3000)
    end
end)

RegisterNetEvent('tr_minigames:lockpick:fitSaved', function(model, fit)
    Lockpick.savedFits[model] = fit
end)

-- Dev keys that move a lock while fitting it: 5 mm a press, 1 mm with Shift held.
local NUDGE = {
    { 174, 'back', -1 }, { 175, 'back', 1 }, -- arrow left / right: along the door
    { 172, 'up', 1 }, { 173, 'up', -1 },     -- arrow up / down
    { 44, 'out', 1 }, { 38, 'out', -1 },     -- Q / E: out of / into the door
}

-- And turn it to sit flat on a curved door: 1 degree a press, a quarter with Shift held.
local TURN = {
    { 111, 'pitch', -1 }, { 112, 'pitch', 1 }, -- numpad 8 / 5: tip the face up / down
    { 108, 'yaw', -1 }, { 109, 'yaw', 1 },     -- numpad 4 / 6: turn the face forward / back
}
-- In the fitters, also the scroll wheel and Z / X (picking uses the wheel to move the pick).
local WHEEL = {
    { 241, 'pitch', -1 }, { 242, 'pitch', 1 }, -- scroll up / down: tip the face up / down
    { 20, 'yaw', -1 }, { 73, 'yaw', 1 },       -- Z / X: tilt the face left (to the car's front) / right
}

local function mm(v) return math.floor(v * 1000 + 0.5) / 1000 end

---Lock space's axes for a measured fit, in the car's space.
local function fitAxes(fit)
    return Mat.mul(Mat.axis('z', fit.yaw), Mat.axis('x', fit.pitch))
end

---The model's fit moved by the nudge key just pressed, or nil. Read with controls disabled.
---Turning needs `vehicle`: a fit from the handle (back, up, out) becomes a measured one there.
---`wheel`: the scroll wheel tips it as well.
function Lockpick.nudged(model, vehicle, wheel)
    local fine = IsDisabledControlPressed(0, 21)
    local turns = TURN
    if wheel then
        turns = {}
        for _, n in ipairs(TURN) do turns[#turns + 1] = n end
        for _, n in ipairs(WHEEL) do turns[#turns + 1] = n end
    end
    for _, n in ipairs(turns) do
        if IsDisabledControlJustPressed(0, n[1]) then
            local fit = Lockpick.fit(model)
            if not fit.x then
                -- (Not `vehicle and placement(...)`: that would keep only the first of its results.)
                if not vehicle then return end
                local offset, pitch, yaw = Lockpick.placement(vehicle, Lockpick.fitDoor)
                if not offset then return end
                fit = { x = offset.x, y = offset.y, z = offset.z, pitch = pitch, yaw = yaw }
            end
            local turned = { x = fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = fit.yaw }
            turned[n[2]] = turned[n[2]] + n[3] * (fine and 0.25 or 1.0)
            turned.pitch = Clamp(turned.pitch, -60.0, 60.0)
            return turned
        end
    end

    local step = fine and 0.001 or 0.005
    for _, n in ipairs(NUDGE) do
        if IsDisabledControlJustPressed(0, n[1]) then
            local fit = Lockpick.fit(model)

            if fit.x then
                -- In lock space: back is +X (towards the car's rear on the driver's side), out is -Y.
                local axes = fitAxes(fit)
                local dir = n[2] == 'back' and axes.x or n[2] == 'up' and axes.z or axes.y * -1.0
                local p = vec3(fit.x, fit.y, fit.z) + dir * (n[3] * step)
                return { x = p.x, y = p.y, z = p.z, pitch = fit.pitch, yaw = fit.yaw }
            end

            local moved = { back = fit.back, up = fit.up, out = fit.out }
            moved[n[2]] = mm(moved[n[2]] + n[3] * step)
            return moved
        end
    end
end

---The door's handle in vehicle space; without a handle bone, a guess from the door's hinge.
local function handle(vehicle, door)
    local spot = Scene.boneOffset(vehicle, 'handle_' .. door)
    if spot then return spot end

    local hinge = Scene.boneOffset(vehicle, 'door_' .. door)
    if hinge then return hinge + vec3(0.0, -0.62, 0.05) end -- most of the way back, below the window
end

---Lock space turned to face into the door: yaw for Scene, and its axes in vehicle space.
local function facing(door)
    local yaw = SIDE[door] < 0 and -90.0 or 90.0
    return yaw, Mat.axis('z', yaw)
end

---A ray along `into` (vehicle space) through `spot`: where it meets the door, and the door's normal.
---@return vector3? hit, vector3? normal both in vehicle space
local function surface(vehicle, spot, into)
    local from = GetOffsetFromEntityInWorldCoords(vehicle, spot.x - into.x * 0.25, spot.y - into.y * 0.25, spot.z - into.z * 0.25)
    local to = GetOffsetFromEntityInWorldCoords(vehicle, spot.x + into.x * 0.2, spot.y + into.y * 0.2, spot.z + into.z * 0.2)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 2, PlayerPedId(), 7)
    local _, hit, at, normal, entity = GetShapeTestResult(ray)
    if not hit or entity ~= vehicle then return end

    local rot = Mat.fromEuler(GetEntityRotation(vehicle, 2))
    return GetOffsetFromEntityGivenWorldCoords(vehicle, at.x, at.y, at.z), Vec.unrotate(rot, normal)
end

---Offset, pitch and yaw for Scene.new / Scene:setPlacement, or nil if the door has no handle.
---@return vector3? offset, number pitch, number yaw
function Lockpick.placement(vehicle, door)
    local fit = Lockpick.fit(Lockpick.modelName(vehicle))
    if fit.x and door == Lockpick.fitDoor then return vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw end
    if fit.x then fit = cfg.rig end

    local spot = handle(vehicle, door)
    if not spot then return end
    local yaw, rot = facing(door)
    local pitch = 0.0
    spot = spot + vec3(0.0, -fit.back, fit.up)

    local hit, normal = surface(vehicle, spot, rot.y)
    if hit then
        local depth = Vec.dot(hit - spot, rot.y)
        if math.abs(depth) < 0.12 then spot = spot + rot.y * depth end

        -- Sit flat on the paint: lock space's +Y goes straight into the door.
        if cfg.followSurface then
            local into = Vec.normalize(normal * -1.0)
            pitch = Clamp(math.deg(math.asin(Clamp(into.z, -1.0, 1.0))), -25.0, 25.0)
            local turned = math.deg(math.atan(-into.x, into.y))
            yaw = yaw + Clamp(math.deg(AngleDelta(math.rad(yaw), math.rad(turned))), -30.0, 30.0)
        end
    end

    rot = Mat.mul(Mat.axis('z', yaw), Mat.axis('x', pitch))
    return spot - rot.y * fit.out, pitch, yaw
end

---Where a door's lock is in the world (roughly: the handle moved by the fit), for distance checks.
function Lockpick.lockCoords(vehicle, door)
    local fit = Lockpick.fit(Lockpick.modelName(vehicle))
    if fit.x and door == Lockpick.fitDoor then return GetOffsetFromEntityInWorldCoords(vehicle, fit.x, fit.y, fit.z) end
    if fit.x then fit = cfg.rig end

    local spot = handle(vehicle, door)
    if not spot then return end

    return GetOffsetFromEntityInWorldCoords(vehicle, spot.x, spot.y - fit.back, spot.z + fit.up)
end

---Whether the player is outside the door (not on the far side of the car, not inside it).
local function outside(vehicle, door, coords)
    local lock = Lockpick.lockCoords(vehicle, door)
    if not lock then return false end

    local me = GetOffsetFromEntityGivenWorldCoords(vehicle, coords.x, coords.y, coords.z)
    local at = GetOffsetFromEntityGivenWorldCoords(vehicle, lock.x, lock.y, lock.z)
    return (me.x - at.x) * SIDE[door] > 0.1, #(coords - lock)
end

---The lockable door nearest to the player within reach.
---@return integer? vehicle, string? door, number? distance
function Lockpick.nearestDoor()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local best, bestVehicle, bestDoor = cfg.reach, nil, nil

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if #(GetEntityCoords(vehicle) - coords) < 6.0 then
            for _, door in ipairs(cfg.doors) do
                local isOutside, distance = outside(vehicle, door, coords)
                if isOutside and distance < best then
                    best, bestVehicle, bestDoor = distance, vehicle, door
                end
            end
        end
    end

    return bestVehicle, bestDoor, bestVehicle and best or nil
end

---Whether the door is locked (lock status 2 and up: locked, locked for players, breakable, ...).
function Lockpick.isLocked(vehicle)
    return GetVehicleDoorLockStatus(vehicle) > 1
end
