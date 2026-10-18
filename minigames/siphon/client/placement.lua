--[[
    Where a ped siphons a car: the filler, the paint over it, which clip fits its height, and where the
    ped stands so the clip's hands are at the filler (the hoses go in where the clip has them).

        local place = Siphon.placement(vehicle, ped)
        -- place.spot (ped root), place.heading, place.clip, place.paint, place.normal, place.ground, place.source
        local offset, pitch, yaw = Siphon.frame(vehicle, place)   -- filler space on the car (Scene.new)

    A car with a fit (made with /filler_fitall or /filler_autofit, client/fits.lua) uses it. Other cars
    with a petroltank bone use that, the rest a guess on the body's flank above a rear wheel. Both lie
    inside the body, so a ray from outside finds the paint.
]]

Siphon = Siphon or {}

-- Fits by model: where filler space sits on the car, { x, y, z, pitch, yaw } in vehicle space (as
-- Scene.new takes it), `auto` if /filler_autofit measured it, `check` if it wasn't sure, `both` for a
-- car without a petroltank bone: measured on one flank, mirrored to the side the player stands. live: being
-- tuned right now (/filler_fitall), until the resource restarts. saved: kept by the server in
-- minigames/siphon/fits.json. Then Config.siphon.vehicleFits.
Siphon.liveFits = Siphon.liveFits or {}
Siphon.savedFits = Siphon.savedFits or {}

---Spawn name of the vehicle's model, the key for fits.
function Siphon.modelName(vehicle)
    return GetEntityArchetypeName(vehicle):lower()
end

---@return table? fit, string? source
function Siphon.fit(model)
    if Siphon.liveFits[model] then return Siphon.liveFits[model], 'live' end
    if Siphon.savedFits[model] then return Siphon.savedFits[model], 'saved' end
    local fits = Config.siphon.vehicleFits
    if fits and fits[model] then return fits[model], 'config' end
end

---Filler space's axes (in vehicle space) for a fit: +Y into the car.
function Siphon.fitAxes(fit)
    return Mat.mul(Mat.axis('z', fit.yaw), Mat.axis('x', fit.pitch))
end

-- One clip every 5 cm of filler height (props/siphon/anim.py VARIANTS: blow_75 kneels for paint 0.75 m
-- above the ground ... blow_150 stands upright): the paint this high above the ground.
local CLIPS = {}
for name, clip in pairs(Siphon.rig.clips) do CLIPS[#CLIPS + 1] = { name = name, height = clip.fillerHeight } end
table.sort(CLIPS, function(a, b) return a.height < b.height end)

---@param height number metres the paint is above the ground
function Siphon.clipFor(height)
    local best = CLIPS[1]
    for _, clip in ipairs(CLIPS) do
        if math.abs(clip.height - height) < math.abs(best.height - height) then best = clip end
    end
    return best.name
end

local function hitCar(a, b, vehicle, ignore)
    local _, hit, pos, normal, entity = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(a.x, a.y, a.z, b.x, b.y, b.z, -1, ignore, 7))
    if (hit == true or hit == 1) and entity == vehicle then return pos, normal end   -- builds differ: 1 or true
end

---The rear wheel on `side` (-1 left, 1 right) in vehicle space: { x, y, z, r }, r the tyre's radius.
---nil if the car has none.
function Siphon.rearWheel(vehicle, side)
    local right = side > 0
    local wheel = GetEntityBoneIndexByName(vehicle, right and 'wheel_rr' or 'wheel_lr')
    if wheel == -1 then return end
    local wp = GetWorldPositionOfEntityBone(vehicle, wheel)
    local w = GetOffsetFromEntityGivenWorldCoords(vehicle, wp.x, wp.y, wp.z)
    local radius = GetVehicleWheelTireColliderSize(vehicle, right and 3 or 2)
    if not radius or radius < 0.2 or radius > 0.8 then radius = 0.33 end
    return { x = w.x, y = w.y, z = w.z, r = radius }
end

---The filler without a fit: a petroltank bone, or a guess off the rear wheel on the side `ped` is
---standing (or `side`: -1 left, 1 right).
local function boneOrGuess(vehicle, ped, side)
    for _, name in ipairs({ 'petroltank', 'petroltank_l', 'petroltank_r' }) do
        local bone = GetEntityBoneIndexByName(vehicle, name)
        if bone ~= -1 then return GetWorldPositionOfEntityBone(vehicle, bone), name end
    end

    local right
    if side then
        right = side > 0
    else
        local pos = GetEntityCoords(ped)
        right = GetOffsetFromEntityGivenWorldCoords(vehicle, pos.x, pos.y, pos.z).x >= 0
    end
    local wheelName = right and 'wheel_rr' or 'wheel_lr'
    local w = Siphon.rearWheel(vehicle, right and 1 or -1)
    if not w then return end

    -- Fuel caps sit on the body's flank above the wheel arch, a little behind the wheel's middle. Rays
    -- in from the side at a few heights find the flank: on low, wide cars (Adder) the body curves in
    -- above the fender, so a fixed height would go over it and hit the engine cover.
    local radius = w.r
    local s, y = right and 1 or -1, w.y - radius * 0.5
    local preferred = w.z + radius + 0.2
    local outs, widest = {}, -math.huge
    for z = w.z + radius + 0.03, preferred + 0.1, 0.02 do
        local a = GetOffsetFromEntityInWorldCoords(vehicle, s * (math.abs(w.x) + 1.5), y, z)
        local b = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, y, z)
        local hit = hitCar(a, b, vehicle, ped or PlayerPedId())
        if hit then
            local out = s * GetOffsetFromEntityGivenWorldCoords(vehicle, hit.x, hit.y, hit.z).x
            outs[#outs + 1] = { z = z, out = out }
            if out > widest then widest = out end
        end
    end

    local height = preferred
    if #outs > 0 then
        -- The highest spot, up to the preferred height, that is still on the flank (within 3 cm of the widest).
        height = nil
        for _, h in ipairs(outs) do
            if h.out >= widest - 0.03 and h.z <= preferred and (not height or h.z > height) then height = h.z end
        end
        if not height then
            for _, h in ipairs(outs) do if h.out == widest then height = h.z end end
        end
    end
    return GetOffsetFromEntityInWorldCoords(vehicle, w.x, y, height), wheelName .. ' (guess)'
end

---The filler in world space and what it came from: the model's fit, a petroltank bone, or a guess
---off the rear wheel on the side `ped` is standing.
---@return vector3? filler
---@return string? source
---@return table? fit
function Siphon.fillerOf(vehicle, ped)
    local fit, source = Siphon.fit(Siphon.modelName(vehicle))
    if fit and fit.both and ped then
        -- Fitted on one flank: mirrored to the other when the player stands there.
        local pos = GetEntityCoords(ped)
        local right = GetOffsetFromEntityGivenWorldCoords(vehicle, pos.x, pos.y, pos.z).x >= 0
        if right ~= (fit.x >= 0) then fit = { x = -fit.x, y = fit.y, z = fit.z, pitch = fit.pitch, yaw = -fit.yaw, both = true } end
    end
    if fit then return GetOffsetFromEntityInWorldCoords(vehicle, fit.x, fit.y, fit.z), 'fit (' .. source .. ')', fit end
    return boneOrGuess(vehicle, ped)
end

---Where the ped goes to siphon `vehicle`, or nil and a reason ('no_filler').
---@return table? place { spot, heading, clip, paint, normal, ground, outward, filler, source, onPaint, side }
---@return string? reason
function Siphon.placement(vehicle, ped)
    local filler, source, fit = Siphon.fillerOf(vehicle, ped)
    if not filler then return nil, 'no_filler' end

    -- Face the side of the car the filler is on, and find the paint there (a fit is on it already).
    local side = GetOffsetFromEntityGivenWorldCoords(vehicle, filler.x, filler.y, filler.z).x >= 0 and 1 or -1
    local carFwd = GetEntityForwardVector(vehicle)
    local outward = vec3(carFwd.y, -carFwd.x, 0.0) * side
    local paint, normal
    if fit then
        local rot = Mat.fromEuler(GetEntityRotation(vehicle, 2))
        paint, normal = filler, Mat.apply(rot, Siphon.fitAxes(fit).y * -1.0)
    else
        paint, normal = hitCar(filler + outward * 1.5, filler - outward * 0.6, vehicle, ped)
    end
    local onPaint = paint ~= nil
    paint, normal = paint or filler, normal or outward

    local heading = (GetEntityHeading(vehicle) + 90.0 * side) % 360.0
    local beside = paint + outward * 0.1 -- the ground just outside the car, under the filler
    local found, ground = GetGroundZFor_3dCoord(beside.x, beside.y, beside.z + 1.0, false)
    ground = found and ground or filler.z - 0.8

    -- Every clip has the paint at the same spot ahead of the ped (rig.lua clips.*.filler, ped space:
    -- +X right, +Y forward); the ped stands so it is on the paint.
    local clip = Siphon.clipFor(paint.z - ground)
    local at = Siphon.rig.clips[clip].filler
    local rad = math.rad(heading)
    local forward, right = vec3(-math.sin(rad), math.cos(rad), 0.0), vec3(math.cos(rad), math.sin(rad), 0.0)
    local spot = paint - right * at.x - forward * at.y
    spot = vec3(spot.x, spot.y, ground + 1.0)

    return {
        spot = spot,
        heading = heading,
        forward = forward,
        right = right,
        clip = clip,
        paint = paint,
        normal = normal,
        side = side,
        ground = ground,
        outward = outward,
        filler = filler,
        source = source,
        onPaint = onPaint,
        fit = fit,
    }
end

local MAX_YAW, MAX_PITCH = 25.0, 10.0 -- degrees the filler may turn from square to the car's side with the paint

---Filler space on the car, for Scene.new(vehicle, offset, pitch, yaw): its origin on the paint at the
---filler, +Y into the car along the paint's normal (within a few degrees of square to the car's
---side, so an odd hit can't turn it away), +X to the right of a player facing it.
---@return vector3 offset, number pitch, number yaw
function Siphon.frame(vehicle, place)
    local fit = place.fit
    if fit then return vec3(fit.x, fit.y, fit.z), fit.pitch, fit.yaw end
    local rot = Mat.fromEuler(GetEntityRotation(vehicle, 2))
    local offset = Vec.unrotate(rot, place.paint - GetEntityCoords(vehicle))
    local n = Vec.unrotate(rot, place.normal)

    local square = 90.0 * place.side
    local flat = math.sqrt(n.x * n.x + n.y * n.y)
    local yaw = flat > 0.2 and math.deg(math.atan(n.x, -n.y)) or square
    yaw = square + Clamp((yaw - square + 180.0) % 360.0 - 180.0, -MAX_YAW, MAX_YAW)
    local pitch = Clamp(math.deg(math.asin(Clamp(-n.z, -1.0, 1.0))), -MAX_PITCH, MAX_PITCH)
    return offset, pitch, yaw
end

---Where filler space would sit on `vehicle` without a fit, as a fit: on the petroltank bone, or the
---guess on `side` (-1 left, 1 right). nil if the car has neither.
function Siphon.guessFit(vehicle, side)
    local filler = boneOrGuess(vehicle, nil, side)
    if not filler then return end
    side = GetOffsetFromEntityGivenWorldCoords(vehicle, filler.x, filler.y, filler.z).x >= 0 and 1 or -1
    local carFwd = GetEntityForwardVector(vehicle)
    local outward = vec3(carFwd.y, -carFwd.x, 0.0) * side
    local paint, normal = hitCar(filler + outward * 1.5, filler - outward * 0.6, vehicle, PlayerPedId())
    local offset, pitch, yaw = Siphon.frame(vehicle, { paint = paint or filler, normal = normal or outward, side = side })
    return { x = offset.x, y = offset.y, z = offset.z, pitch = pitch, yaw = yaw }
end

---Is `ped` at a filler of `vehicle` (near enough to start)?
---@param reach number metres from the spot the ped would siphon from
function Siphon.atFiller(vehicle, ped, reach)
    local filler = Siphon.fillerOf(vehicle, ped)
    if not filler then return false end
    local pos = GetEntityCoords(ped)
    return #(vec3(pos.x - filler.x, pos.y - filler.y, 0.0)) <= reach
end
