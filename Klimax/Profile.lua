-- Profile: how this character wants to level (phase 22, DYNAMIC_GUIDE_PLAN s4.4).
--
-- Saved per character in KlimaxCharDB.profile. The planner reads it through Plan/Weights.For
-- (pace, group, dungeons, elites, completionist, travel change weights); the other settings are kept
-- for the services (phase 23) and class modules (phase 24). Any change replans at once.
local _, K = ...
local L = K.L

local Pr = {}
K.Profile = Pr

-- Settings in display order: key, choices (first is the default).
Pr.FIELDS = {
    { key = "pace", choices = { "relaxed", "efficient", "speed" } },
    { key = "group", choices = { "solo", "open", "group" } },
    { key = "dungeons", choices = { "never", "good", "always" } },
    { key = "elites", choices = { "easy", "skip", "allow" } },
    { key = "completionist", choices = { "balanced", "xp", "finish" } },
    { key = "gold", choices = { "balanced", "ignore", "farm" } },
    { key = "travel", choices = { "free", "walk" } },
    { key = "rewards", choices = { "advisor", "off" } },
    { key = "rested", choices = { "plan", "ignore" } },
    { key = "session", choices = { "normal", "short", "long" } },
}

-- Named presets: the settings they change (the rest keep their defaults).
Pr.PRESETS = {
    { id = "relaxed", values = {} },
    { id = "efficient", values = { pace = "efficient", elites = "easy", completionist = "xp" } },
    { id = "speed", values = { pace = "speed", elites = "skip", completionist = "xp", rested = "ignore" } },
    { id = "completionist",
        values = { pace = "relaxed", completionist = "finish", elites = "allow", dungeons = "good" } },
    { id = "group", values = { group = "group", dungeons = "always", elites = "allow" } },
}

-- Rough effect of a setting on leveling speed, in percent (negative = slower), for the preview.
Pr.SPEED = {
    pace = { efficient = 10, speed = 20 },
    elites = { skip = -10, allow = 5 },
    dungeons = { always = 5 },
    completionist = { xp = 5, finish = -20 },
    travel = { walk = -15 },
}

function Pr.Defaults()
    local p = {}
    for _, f in ipairs(Pr.FIELDS) do
        p[f.key] = f.choices[1]
    end
    p.professions = {}
    return p
end

local function field(key)
    for _, f in ipairs(Pr.FIELDS) do
        if f.key == key then
            return f
        end
    end
    return nil
end

-- A profile with every field filled in (unknown values fall back to the default).
function Pr.Normalize(p)
    local out = Pr.Defaults()
    for k, v in pairs(p or {}) do
        local f = field(k)
        if f then
            for _, c in ipairs(f.choices) do
                if c == v then
                    out[k] = v
                end
            end
        elseif k ~= "professions" then
            out[k] = v
        end
    end
    if type((p or {}).professions) == "table" then
        out.professions = p.professions
    end
    return out
end

-- The values of a preset applied to the defaults.
function Pr.Preset(id)
    for _, preset in ipairs(Pr.PRESETS) do
        if preset.id == id then
            local p = Pr.Defaults()
            for k, v in pairs(preset.values) do
                p[k] = v
            end
            p.preset = id
            return p
        end
    end
    return nil
end

-- The next choice of a field after `current` (cycles).
function Pr.NextChoice(key, current)
    local f = field(key)
    if not f then
        return current
    end
    for i, c in ipairs(f.choices) do
        if c == current then
            return f.choices[i % #f.choices + 1]
        end
    end
    return f.choices[1]
end

-- Plain-language preview lines and the estimated speed change in percent.
function Pr.Preview(p)
    p = Pr.Normalize(p)
    local lines, pct = {}, 0
    for _, f in ipairs(Pr.FIELDS) do
        local text = L["PROFILE_PREVIEW_" .. f.key .. "_" .. p[f.key]]
        if text then
            lines[#lines + 1] = text
        end
        local effect = Pr.SPEED[f.key] and Pr.SPEED[f.key][p[f.key]]
        if effect then
            pct = pct + effect
        end
    end
    if pct < 0 then
        lines[#lines + 1] = string.format(L.PROFILE_SLOWER, -pct)
    elseif pct > 0 then
        lines[#lines + 1] = string.format(L.PROFILE_FASTER, pct)
    else
        lines[#lines + 1] = L.PROFILE_SAME
    end
    return lines, pct
end

-- ---- Saved profile ------------------------------------------------------------------------------

function Pr.Get()
    K.cdb = K.cdb or {}
    if not K.cdb.profile then
        return Pr.Defaults()
    end
    return Pr.Normalize(K.cdb.profile)
end

-- True once the player has chosen a profile (the wizard ran or a setting was changed).
function Pr.Chosen()
    return K.cdb ~= nil and K.cdb.profile ~= nil
end

Pr.observers = {}
function Pr.OnChange(fn)
    Pr.observers[#Pr.observers + 1] = fn
end

local function changed()
    if K.Planner then
        K.Planner.dirty = true
    end
    for _, fn in ipairs(Pr.observers) do
        pcall(fn, K.cdb.profile)
    end
end

function Pr.Save(p)
    K.cdb = K.cdb or {}
    K.cdb.profile = Pr.Normalize(p)
    K.cdb.profile.preset = p.preset
    changed()
    return K.cdb.profile
end

function Pr.Set(key, value)
    local p = Pr.Get()
    p[key] = value
    p.preset = nil
    return Pr.Save(p)
end

function Pr.ApplyPreset(id)
    local p = Pr.Preset(id)
    if p then
        Pr.Save(p)
    end
    return p
end

-- "/klimax profile [preset]": prints the profile, or applies a preset.
function Pr.Command(rest)
    rest = (rest or ""):lower()
    if rest ~= "" then
        if not Pr.ApplyPreset(rest) then
            K.Print(string.format(L.PROFILE_UNKNOWN, rest))
            return
        end
        K.Print(string.format(L.PROFILE_SET, rest))
    elseif K.Wizard then
        K.Wizard.Open()
        return
    end
    local p = Pr.Get()
    local parts = {}
    for _, f in ipairs(Pr.FIELDS) do
        parts[#parts + 1] = f.key .. "=" .. p[f.key]
    end
    K.Print(table.concat(parts, ", "))
end
