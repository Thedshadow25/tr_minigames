-- Where the lock sits on each car model, made in game with /lockpick_autofit (client/autofit.lua)
-- or /lockpick_fitall (client/fitter.lua) and kept in minigames/lockpick/fits.json. Every client
-- gets them on join and when one is saved. Lockpick.fit picks a saved fit over
-- Config.lockpick.vehicleFits.
--
-- Two kinds:
--   { back, up, out }                      from the handle's bone, onto the door's collision (by hand)
--   { x, y, z, pitch, yaw, auto?, check? }  exactly where, in the car's space (measured; `check`:
--                                            the measuring wasn't sure, have a look)

local cfg = Config.lockpick

if not cfg.enabled then return end

local FILE = 'minigames/lockpick/fits.json'
local resource = GetCurrentResourceName()

local fits = {}

local function num(v, limit)
    v = tonumber(v)
    if v and v == v and math.abs(v) <= limit then return v end
end

---A clean copy of a fit, or nil if it isn't one.
local function clean(fit)
    if type(fit) ~= 'table' then return end

    local x, y, z = num(fit.x, 10), num(fit.y, 10), num(fit.z, 10)
    if x and y and z then
        local pitch, yaw = num(fit.pitch, 90), num(fit.yaw, 360)
        if not (pitch and yaw) then return end
        return { x = x, y = y, z = z, pitch = pitch, yaw = yaw, auto = fit.auto == true or nil, check = fit.check == true or nil }
    end

    local back, up, out = num(fit.back, 2), num(fit.up, 2), num(fit.out, 2)
    if back and up and out then return { back = back, up = up, out = out } end
end

local function load()
    local raw = LoadResourceFile(resource, FILE)
    if not raw or raw == '' then return end

    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        return TR.log.error('%s is not valid JSON; the fits in it are ignored until it is fixed', FILE)
    end

    for model, fit in pairs(data) do fits[model] = clean(fit) end
end

local function encode(f)
    if f.x then
        local flags = (f.auto and ', "auto": true' or '') .. (f.check and ', "check": true' or '')
        return ('{ "x": %.4f, "y": %.4f, "z": %.4f, "pitch": %.2f, "yaw": %.2f%s }'):format(f.x, f.y, f.z, f.pitch, f.yaw, flags)
    end
    return ('{ "back": %.3f, "up": %.3f, "out": %.3f }'):format(f.back, f.up, f.out)
end

---One model per line, sorted, so the file reads (and diffs) well.
local function save()
    local models = {}
    for model in pairs(fits) do models[#models + 1] = model end
    table.sort(models)

    local lines = {}
    for i, model in ipairs(models) do lines[i] = ('  "%s": %s'):format(model, encode(fits[model])) end

    SaveResourceFile(resource, FILE, '{\n' .. table.concat(lines, ',\n') .. '\n}\n', -1)
end

load()

TR.callback.register('tr_minigames:lockpick:fits', function()
    return fits
end, {
    schema = {},
    rateLimit = { max = 2, window = 5000 },
})

TR.callback.register('tr_minigames:lockpick:saveFit', function(src, model, fit)
    if not (cfg.devMode and TR.player.isAdmin(src)) then return false, 'not_allowed' end

    fit = clean(fit)
    if not fit then return false, 'invalid_args' end

    fits[model] = fit
    save()

    TriggerClientEvent('tr_minigames:lockpick:fitSaved', -1, model, fit)
    TR.log.info('%s saved the lock fit of %s', GetPlayerName(src), model)
    return true
end, {
    schema = { { type = 'string', min = 1, max = 64, pattern = '^[%w_%-]+$' }, 'table' },
    rateLimit = { max = 5, window = 1000 },
})
