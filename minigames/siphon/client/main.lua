local cfg = Config.siphon
local function t(key, vars) return TR.locale.t('siphon.' .. key, vars) end

if not cfg.enabled then return end

local REACH = 2.0 -- metres from the filler the player can start
local busy = false

local function notify(key, kind, vars)
    TR.notify.send({ description = t(key, vars), type = kind or 'error' })
end

---Electric cars have no fuel to siphon (the native needs game build 3258).
local function isElectric(vehicle)
    local ok, electric = pcall(GetIsVehicleElectric, GetEntityModel(vehicle))
    return ok and electric == true
end

-- The fillers of cars nearby, cached for a moment: a car without a petroltank bone needs a few rays.
local fillers = {}

local function fillerNear(vehicle, ped)
    local now = GetGameTimer()
    local cached = fillers[vehicle]
    if not cached or now - cached.at > 1000 then
        cached = { at = now, pos = Siphon.fillerOf(vehicle, ped) or false }
        fillers[vehicle] = cached
    end
    if not cached.pos then return false end
    local p = GetEntityCoords(ped)
    return #(vec3(p.x - cached.pos.x, p.y - cached.pos.y, 0.0)) <= REACH
end

---The car whose filler the player is standing at.
local function nearestFiller(ped)
    local pos, best, bestDist = GetEntityCoords(ped), nil, 6.0
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        local dist = #(GetEntityCoords(vehicle) - pos)
        if dist < bestDist and fillerNear(vehicle, ped) then best, bestDist = vehicle, dist end
    end
    return best
end

local function siphon()
    if busy then return end
    local ped = PlayerPedId()
    if TR.cache.vehicle or IsPedInAnyVehicle(ped, false) then return notify('in_vehicle') end

    local vehicle = nearestFiller(ped)
    if not vehicle then return notify('no_filler') end
    if isElectric(vehicle) then return notify('electric') end
    if not NetworkGetEntityIsNetworked(vehicle) then return notify('wrong_vehicle') end

    busy = true
    local ok, data = TR.callback.await('tr_minigames:siphon:start', VehToNet(vehicle), GetVehicleClass(vehicle))
    if not ok then
        busy = false
        return notify(data or 'try_again')
    end

    local result, litres, can, spilled = Siphon.run(vehicle, data)
    busy = false

    if result == 'done' then
        local vars = { n = ('%.1f'):format(litres or 0), can = math.floor((can or 0) + 0.5), spilled = ('%.1f'):format(spilled or 0) }
        if litres and litres > 0 then
            notify((spilled or 0) >= 0.1 and 'siphoned_spilled' or 'siphoned', 'success', vars)
        else
            notify((spilled or 0) >= 0.1 and 'all_spilled' or 'nothing', 'info', vars)
        end
    elseif result == 'gave_up' then
        notify('gave_up')
    elseif result == 'cancelled' then
        notify('cancelled', 'info')
    else
        notify(result or 'try_again')
    end
end

RegisterCommand(cfg.command, function() siphon() end, false)

-- Fuel another player spilled nearby: the same petrol puddles here (they burn).
RegisterNetEvent('tr_minigames:siphon:puddle', function(spills, litres)
    if not cfg.puddles or type(spills) ~= 'table' then return end
    for _, spill in ipairs(spills) do
        local at = type(spill) == 'table' and spill.at
        if type(at) == 'vector3' then
            local size = Clamp(0.3 + (tonumber(litres) or 0) * (tonumber(spill.share) or 1.0) * 0.12, 0.3, 1.4)
            local found, ground = GetGroundZFor_3dCoord(at.x, at.y, at.z + 1.0, false)
            AddPetrolDecal(at.x, at.y, found and ground or at.z, 2.0, size, 1.0)
        end
    end
end)

-- For an inventory's "use" action, e.g. ox_inventory: client = { export = 'tr_minigames.siphon' }
exports('siphon', function() siphon() end)

-- "Siphon fuel" at a car's filler, for servers with ox_target or qb-target. Not on tr_core's own
-- interaction (the default target), which would offer it at every car: there it's the command or the item's use.
local hasTarget, targetSystem = pcall(TR.system, 'target')
if cfg.target and hasTarget and targetSystem ~= 'tr_core' then
    TR.target.addGlobalVehicle({
        {
            name = 'tr_minigames:siphon',
            label = t('target'),
            icon = 'fa-solid fa-gas-pump',
            distance = 3.0,
            items = cfg.item or nil,
            canInteract = function(entity) return not busy and fillerNear(entity, PlayerPedId()) end,
            onSelect = function() siphon() end,
        },
    })
end

-- Live tuning of the camera: /siphon_cam <x> <y> <z> <targetX> <targetY> <targetZ> [fov]
if cfg.devMode then
    RegisterCommand('siphon_cam', function(_, args)
        local n = {}
        for i = 1, 7 do n[i] = tonumber(args[i]) end

        local cam = cfg.camera
        if n[6] then
            cam.pos, cam.target, cam.fov = vec3(n[1], n[2], n[3]), vec3(n[4], n[5], n[6]), n[7] or cam.fov
            local game = Siphon.current
            if game and game.props then
                game.props.scene:moveCamera(cam.pos, cam.target)
                game.props.scene.fovGoal = cam.fov
            end
        end

        print(('[siphon] camera = { pos = vec3(%.2f, %.2f, %.2f), target = vec3(%.2f, %.2f, %.2f), fov = %.1f },'):format(
            cam.pos.x, cam.pos.y, cam.pos.z, cam.target.x, cam.target.y, cam.target.z, cam.fov))
    end, false)
end
