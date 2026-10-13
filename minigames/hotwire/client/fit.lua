--[[
    Where the steering column sits in a car: at its steering wheel, nudged by a per-model or
    per-class fit from the config (Config.hotwire.vehicleFits / classFits / rig).

        local scene = Scene.new(vehicle, Hotwire.placement(vehicle))
]]

local cfg = Config.hotwire

Hotwire = Hotwire or {}

---Spawn name of the vehicle's model, the key for vehicleFits.
function Hotwire.modelName(vehicle)
    return GetEntityArchetypeName(vehicle):lower()
end

---Offset and pitch for a vehicle: its model in vehicleFits, else its class in classFits (trucks,
---vans, ...), else the default rig.
---@return { offset: vector3, pitch: number } fit, string source
function Hotwire.fit(model, class)
    if cfg.vehicleFits[model] then return cfg.vehicleFits[model], 'model' end
    if cfg.classFits[class] then return cfg.classFits[class], 'class' end
    return cfg.rig, 'default'
end

---Where the column's rig space sits in the vehicle's own space.
---@return vector3
function Hotwire.anchor(vehicle)
    local wheel = Scene.boneOffset(vehicle, 'steeringwheel')
    if wheel then return wheel end

    -- No steering wheel bone: guess from the driver seat.
    return (Scene.boneOffset(vehicle, 'seat_dside_f') or vec3(-0.4, 0.0, 0.3)) + vec3(0.0, 0.45, 0.35)
end

---Offset and pitch for Scene.new / Scene:setPlacement.
---@return vector3 offset, number pitch
function Hotwire.placement(vehicle)
    local fit = Hotwire.fit(Hotwire.modelName(vehicle), GetVehicleClass(vehicle))
    return Hotwire.anchor(vehicle) + fit.offset, fit.pitch
end
