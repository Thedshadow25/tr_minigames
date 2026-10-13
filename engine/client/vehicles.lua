-- Answers the server's question what class a vehicle model is (engine/server/vehicles.lua): the
-- server has no native for it, and checks what the player starting a minigame says against this.
TR.callback.register('tr_minigames:vehicleClass', function(model)
    if math.type(model) ~= 'integer' or not IsModelInCdimage(model) or not IsModelAVehicle(model) then return nil end
    return GetVehicleClassFromName(model)
end)
