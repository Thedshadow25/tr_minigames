-- The server owns every siphon attempt: who may start, how many puffs prime the hose, and how much
-- fuel came out. An attempt goes setup -> prime -> flow. The client reports puffs and the fuel it
-- spilled; the litres come from the server's own clock (flow time x flow rate),
-- capped by the fuel above the reserve. What doesn't fit in the can (or the client says missed it)
-- spills on the ground.

local cfg = Config.siphon

if not cfg.enabled then return end

Mirror.allowProps('tr_sf_')

local QB_FULL_CAN = 4500 -- GTA's petrol can ammo when full (qb-inventory keeps it in info.ammo)
local SPILL_REACH = 6.0  -- metres from the player a spill can be
local PUDDLE_RANGE = 80.0

local sessions = {} ---@type table<integer, table>
local cooldowns = {} ---@type table<integer, integer> player -> os.time() they can start again

---@param class integer
local function tankLitres(class)
    return cfg.classTank[class] or cfg.tankLitres
end

-- Jerry cans ---------------------------------------------------------------------------------------

local qbCans = TR.system('inventory') == 'qb_inventory'

---Percent of fuel in a can's metadata. ox_inventory gives a new can durability 100 (full); a qb can
---without ammo is empty.
local function canFuel(metadata)
    if qbCans then return math.min(100, (tonumber(metadata.ammo) or 0) / QB_FULL_CAN * 100) end
    return math.min(100, tonumber(metadata.durability) or 100)
end

local function withFuel(metadata, percent)
    local copy = {}
    for key, value in pairs(metadata) do copy[key] = value end
    if qbCans then
        copy.ammo = math.floor(percent / 100 * QB_FULL_CAN + 0.5)
    else
        copy.durability = math.floor(percent * 10 + 0.5) / 10
        copy.ammo = copy.durability
    end
    return copy
end

---The can to fill: the fullest that still has room (topping one up beats starting another).
---@return TRSlot? slot
---@return number fuel percent
---@return number room litres
local function pickCan(src)
    local best, bestFuel
    for _, slot in ipairs(TR.inventory.getSlots(src, cfg.can.item)) do
        local fuel = canFuel(slot.metadata)
        if fuel < 99.5 and (not best or fuel > bestFuel) then best, bestFuel = slot, fuel end
    end
    if not best then return nil, 0, 0 end
    return best, bestFuel, (100 - bestFuel) / 100 * cfg.can.litres
end

-- Attempts -----------------------------------------------------------------------------------------

local function isLocked(vehicle)
    return GetVehicleDoorLockStatus(vehicle) > 1
end

local function nearVehicle(src, vehicle)
    local ped = GetPlayerPed(src)
    return #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) <= cfg.reach and GetVehiclePedIsIn(ped, false) == 0
end

---Returns the player's running attempt, ending it when it is no longer valid. Fuel that was running
---when it ends spills: nothing reaches the can.
local function current(src)
    local s = sessions[src]
    if not s then return nil, 'no_session' end

    local reason
    if os.time() - s.started > cfg.timeLimit then
        reason = 'expired'
    elseif not DoesEntityExist(s.vehicle) then
        reason = 'vehicle_gone'
    elseif not nearVehicle(src, s.vehicle) then
        reason = 'moved_away'
    elseif not s.dev and GetIsVehicleEngineRunning(s.vehicle) then
        reason = 'engine_started'
    end

    if reason then
        sessions[src] = nil
        return nil, reason
    end

    return s
end

---Ends an attempt. `siphoned`: fuel came out, so the car rests too (carCooldown).
local function finish(src, s, siphoned)
    sessions[src] = nil
    cooldowns[src] = os.time() + cfg.cooldown
    if siphoned then Entity(s.vehicle).state:set('tr_siphoned', os.time() + cfg.carCooldown, true) end
end

TR.callback.register('tr_minigames:siphon:start', function(src, netId, class)
    if sessions[src] and current(src) then return false, 'busy' end
    if (cooldowns[src] or 0) > os.time() then return false, 'cooldown' end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'no_vehicle' end
    if not cfg.vehicleTypes[GetVehicleType(vehicle)] then return false, 'wrong_vehicle' end
    if not nearVehicle(src, vehicle) then return false, 'too_far' end
    if GetPedInVehicleSeat(vehicle, -1) ~= 0 then return false, 'occupied' end

    local siphoned = Entity(vehicle).state.tr_siphoned
    if type(siphoned) == 'number' and siphoned > os.time() then return false, 'just_siphoned' end

    local dev = cfg.devMode and TR.player.isAdmin(src)
    if not dev then
        if isLocked(vehicle) then return false, 'locked' end -- the fuel door opens from inside
        if GetIsVehicleEngineRunning(vehicle) then return false, 'engine_on' end
    end

    if cfg.item and not TR.inventory.hasItem(src, cfg.item) then return false, 'no_item' end
    local can, canFuelNow, room = pickCan(src)
    if not can then return false, 'no_can' end

    -- The class sets the tank's size (litres per percent): checked against another player's game.
    class = Vehicles.class(src, vehicle, class)
    if cfg.blockedClasses[class] then return false, 'wrong_vehicle' end

    -- Asks the car's driver with client side fuel scripts, so the car may have changed meanwhile.
    local fuel = TR.fuel.get(vehicle)
    if not fuel then return false, 'no_fuel_info' end
    if not DoesEntityExist(vehicle) or sessions[src] then return false, 'busy' end

    local tank = tankLitres(class)
    local available = math.max(0, fuel - cfg.reserve) / 100 * tank
    if available < 0.1 then return false, 'empty' end

    local puffs = math.random(cfg.puffs[1], cfg.puffs[2])
    Mirror.start(src, vehicle, { active = function() return sessions[src] ~= nil end, maxDuration = cfg.timeLimit + 10 })
    sessions[src] = {
        vehicle = vehicle,
        tank = tank,
        dev = dev,
        started = os.time(),
        setupAt = GetGameTimer(),
        phase = 'setup', -- setup, prime, flow
        progress = 0,    -- good puffs so far
        needed = puffs,
        strikes = 0,
        lastPuff = -math.huge,
    }

    return true, {
        puffs = puffs,
        maxStrikes = cfg.maxStrikes,
        dev = dev,             -- an admin in dev mode: the engine may run
        flowRate = cfg.flowRate,
        available = available, -- litres that can come out before the tank is down to the reserve
        room = room,           -- litres the can still holds; more spills over its neck
        canLitres = cfg.can.litres,
        can = canFuelNow,      -- percent already in the can
        tank = fuel,           -- percent in the car's tank: how deep the fuel is in the neck
    }
end, {
    schema = {
        { type = 'integer', min = 1 },
        { type = 'integer', min = 0, max = 22 },
    },
    rateLimit = { max = 2, window = 2000 },
})

-- The setup is done: the funnel in the can, both hoses in.
TR.callback.register('tr_minigames:siphon:ready', function(src)
    local s, reason = current(src)
    if not s then return false, reason end
    if s.phase ~= 'setup' then return 'ignored' end
    if GetGameTimer() - s.setupAt < cfg.minSetupTime * 1000 then return 'too_soon' end

    s.phase = 'prime'
    return 'ok'
end, {
    schema = {},
    rateLimit = { max = 2, window = 1000 },
})

-- A puff into the blow hose, as the client judged it: 'good', 'weak' (nothing happens) or 'hard'
-- (fuel surges into the player's mouth: a strike, and the fuel falls back to the tank). The fuel runs
-- once there have been as many good puffs as it needs.
TR.callback.register('tr_minigames:siphon:puff', function(src, kind)
    local s, reason = current(src)
    if not s then return false, reason end
    if s.phase == 'flow' then return 'flowing' end
    if s.phase ~= 'prime' then return 'not_ready' end

    local now = GetGameTimer()
    if now - s.lastPuff < cfg.minPuffTime * 1000 then return 'too_soon' end
    s.lastPuff = now

    if kind == 'hard' then
        s.strikes, s.progress = s.strikes + 1, 0
        if s.strikes >= cfg.maxStrikes then
            finish(src, s)
            return 'gave_up', s.strikes
        end
        return 'gulp', s.strikes
    elseif kind == 'weak' then
        return 'weak', s.progress
    end

    s.progress = s.progress + 1
    if s.progress < s.needed then return 'more', s.progress end

    s.phase, s.flowStart = 'flow', now
    return 'flowing'
end, {
    schema = { { type = 'string', enum = { 'good', 'weak', 'hard' } } },
    rateLimit = { max = 3, window = 1000 },
})

---Sends a puddle of spilled fuel to every player near it (the spiller drew theirs as it spilled).
local function puddles(src, spills, litres)
    if not cfg.puddles or litres < 0.2 or not spills then return end
    local ped = GetEntityCoords(GetPlayerPed(src))
    local valid = {}
    for _, spill in ipairs(spills) do
        if #(spill.at - ped) <= SPILL_REACH then
            valid[#valid + 1] = { at = spill.at, share = math.max(0.0, math.min(1.0, spill.share or 1.0)) }
        end
    end
    if #valid == 0 then return end
    for _, id in ipairs(GetPlayers()) do
        local player = tonumber(id)
        if player ~= src and #(GetEntityCoords(GetPlayerPed(player)) - ped) <= PUDDLE_RANGE then
            TriggerClientEvent('tr_minigames:siphon:puddle', player, valid, litres)
        end
    end
end

-- The player pulls the hose (or the tank ran dry). The fuel that ran since the hose primed leaves the
-- car; what fits goes in the can, the rest (and what the client says missed the can) spills.
-- spilled: litres that missed the can. spills: { { at = vector3, share = 0..1 } } where it went.
TR.callback.register('tr_minigames:siphon:stop', function(src, spilled, spills)
    local s, reason = current(src)
    if not s then return false, reason end
    if s.phase ~= 'flow' then
        sessions[src] = nil
        return false, 'not_flowing'
    end

    -- Ended now, so a second stop or a new start can't slip in while the fuel script answers.
    sessions[src], cooldowns[src] = nil, os.time() + cfg.cooldown
    local seconds = (GetGameTimer() - s.flowStart) / 1000

    local can, fuel, room = pickCan(src)
    local carFuel = can and TR.fuel.get(s.vehicle)
    if not carFuel then
        finish(src, s)
        return false, can and 'no_fuel_info' or 'no_can'
    end

    local out = math.min(seconds * cfg.flowRate, math.max(0, carFuel - cfg.reserve) / 100 * s.tank)
    local taken = TR.fuel.take(s.vehicle, out / s.tank * 100) / 100 * s.tank
    if taken <= 0 then
        finish(src, s)
        return true, 0, fuel, 0
    end

    local missed = math.max(0.0, math.min(tonumber(spilled) or 0.0, taken))
    local kept = math.min(taken - missed, room)
    missed = taken - kept
    local canNow = math.min(100, fuel + kept / cfg.can.litres * 100)
    if kept > 0 and not TR.inventory.setMetadata(src, can.slot, withFuel(can.metadata, canNow)) then
        -- The fuel is out of the car but couldn't go into the can: put it back.
        TR.fuel.set(s.vehicle, carFuel)
        finish(src, s)
        return false, 'no_can'
    end

    finish(src, s, true)
    puddles(src, spills, missed)
    local plate = TR.keys.plate(s.vehicle)
    TriggerEvent('tr_minigames:siphon:siphoned', src, NetworkGetNetworkIdFromEntity(s.vehicle), plate, kept, missed)
    TR.log.info('%s siphoned %.1f l from %s (%.1f l spilled)', GetPlayerName(src), kept, plate, missed)
    return true, kept, canNow, missed
end, {
    schema = {
        { type = 'number', min = 0, max = 200, optional = true },
        { type = 'array', max = 3, optional = true, items = { type = 'table', fields = { at = 'vector3', share = 'number?' }, strict = true } },
    },
    rateLimit = { max = 2, window = 1000 },
})

TR.callback.register('tr_minigames:siphon:cancel', function(src)
    local s = sessions[src]
    if s then finish(src, s) end
    return true
end, {
    schema = {},
    rateLimit = { max = 2, window = 1000 },
})

AddEventHandler('playerDropped', function()
    sessions[source] = nil
    cooldowns[source] = nil
end)

-- Hook for logs, XP, stress or police scripts: a player siphoned fuel out of a car into a jerry can.
-- litres went into the can; spilled is what ended up on the ground.
-- AddEventHandler('tr_minigames:siphon:siphoned', function(src, netId, plate, litres, spilled) end)
