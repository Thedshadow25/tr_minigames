-- Where the filler sits on each car model, made in game with /filler_autofit (client/autofit.lua) or
-- /filler_fitall (client/fitter.lua) and kept in minigames/siphon/fits.json. Every client gets them
-- on join and when one is saved. Siphon.fit picks a saved fit over Config.siphon.vehicleFits.
--
--   { x, y, z, pitch, yaw, auto?, check?, both?, sig?, from? }
--       filler space on the car (vehicle space, as Scene.new takes it); `auto`: measured, `check`: the
--       measuring wasn't sure, `both`: mirrored to either flank, `sig`: the model's body (its size to
--       the mm), `from`: copied from that model, which has the same body (kept in step with it)

local cfg = Config.siphon

if not cfg.enabled then return end

local FILE = 'minigames/siphon/fits.json'
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
    local pitch, yaw = num(fit.pitch, 90), num(fit.yaw, 360)
    if not (x and y and z and pitch and yaw) then return end
    local sig = type(fit.sig) == 'string' and #fit.sig <= 80 and fit.sig:match('^[%d%-%.,/]+$') and fit.sig or nil
    local from = type(fit.from) == 'string' and #fit.from <= 64 and fit.from:match('^[%w_%-]+$') and fit.from or nil
    return { x = x, y = y, z = z, pitch = pitch, yaw = yaw, auto = fit.auto == true or nil, check = fit.check == true or nil,
        both = fit.both == true or nil, sig = sig, from = from }
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
    local flags = (f.auto and ', "auto": true' or '') .. (f.check and ', "check": true' or '') .. (f.both and ', "both": true' or '')
        .. (f.from and (', "from": "%s"'):format(f.from) or '') .. (f.sig and (', "sig": "%s"'):format(f.sig) or '')
    return ('{ "x": %.4f, "y": %.4f, "z": %.4f, "pitch": %.2f, "yaw": %.2f%s }'):format(f.x, f.y, f.z, f.pitch, f.yaw, flags)
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

TR.callback.register('tr_minigames:siphon:fits', function()
    return fits
end, {
    schema = {},
    rateLimit = { max = 2, window = 5000 },
})

TR.callback.register('tr_minigames:siphon:saveFit', function(src, model, fit)
    if not (cfg.devMode and TR.player.isAdmin(src)) then return false, 'not_allowed' end

    fit = clean(fit)
    if not fit then return false, 'invalid_args' end

    fits[model] = fit
    save()

    TriggerClientEvent('tr_minigames:siphon:fitSaved', -1, model, fit)
    TR.log.info('%s saved the filler fit of %s', GetPlayerName(src), model)
    return true
end, {
    schema = { { type = 'string', min = 1, max = 64, pattern = '^[%w_%-]+$' }, 'table' },
    rateLimit = { max = 5, window = 1000 },
})
