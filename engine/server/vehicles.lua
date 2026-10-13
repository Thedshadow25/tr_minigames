--[[
    What class a vehicle is (GetVehicleClass), for the rules that depend on it: how hard a lock is and
    whether its alarm goes off, how big a tank is. The server has no native for it, so the player who
    starts a minigame says what its game shows, and a cheat could say anything (a 150 litre tank on a
    small car, the easiest lock, no alarm). Every client's game knows each model's class, though, so the
    server asks another player's (engine/client/vehicles.lua) and keeps the answer for that model.

        class = Vehicles.class(src, vehicle, claimed)   -- waits up to ASK_TIME the first time per model

    Only with nobody else online (or no answer in time) does the player's own word count, and then it
    isn't kept. The answer isn't trusted blindly either: a player saying otherwise is logged, not flagged,
    since the one asked could be the one lying.
]]

Vehicles = {}

local ASK_TIME = 3000 -- ms to wait for the other player's answer
local MAX_CLASS = 22

local known = {} ---@type table<integer, integer> model -> class, from another player's game

local function validClass(v)
    return math.type(v) == 'integer' and v >= 0 and v <= MAX_CLASS
end

---Someone online other than src, at random (so a cheat can't pick who answers), or nil.
local function someoneElse(src)
    local others = {}
    for _, id in ipairs(GetPlayers()) do
        local player = tonumber(id)
        if player and player ~= src then others[#others + 1] = player end
    end
    if #others > 0 then return others[math.random(#others)] end
end

---The class `player`'s game gives `model`, or nil (no valid answer within ASK_TIME).
function Vehicles.ask(player, model)
    local p = promise.new()
    -- Resolved with tables: a cfx promise ignores resolve(nil). The second resolve is ignored.
    CreateThread(function() p:resolve({ TR.callback.await('tr_minigames:vehicleClass', player, model) }) end)
    SetTimeout(ASK_TIME, function() p:resolve({}) end)
    local class = Citizen.Await(p)[1]
    if validClass(class) then return class end
end

---The vehicle's class: what another player's game says about its model, else what src claimed.
---@param claimed integer what src's game says (already checked to be 0..22)
function Vehicles.class(src, vehicle, claimed)
    local model = GetEntityModel(vehicle)
    local class = known[model]
    if class == nil then
        local player = someoneElse(src)
        class = player and Vehicles.ask(player, model)
        if class == nil then return claimed end
        known[model] = class
    end
    if class ~= claimed then
        TR.log.warn('%s (%d) said vehicle model %d is class %d, another player\'s game says %d', GetPlayerName(src), src,
            model, claimed, class)
    end
    return class
end
