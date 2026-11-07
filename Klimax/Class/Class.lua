-- Class modules (phase 23 interface, phase 24 content; DYNAMIC_GUIDE_PLAN s8).
--
-- A class module is a table registered with K.Class.Register(token, module). Every field is optional:
--   needs(x, profile)  -> list of service needs (see Services/Rules.lua) for this class, from the
--                         services snapshot x (supplies, pet, ammo kind, level, money ...)
--   weights            -> planner weight overrides for this class (Plan/Weights.CLASS)
--   beats              -> level-by-level class beats {level, text, quest?, train?} (phase 24)
--   ammo(x)            -> "arrow", "bullet" or nil: the ammo the equipped ranged weapon fires
-- K.Class.Get(token) returns the module or an empty one, so callers never check for nil.
local _, K = ...

local Cl = {}
K.Class = Cl

Cl.modules = {}
local EMPTY = {}

function Cl.Register(token, module)
    Cl.modules[token] = module
    if module.weights and K.Plan and K.Plan.Weights then
        K.Plan.Weights.CLASS[token] = module.weights
    end
    return module
end

function Cl.Get(token)
    return Cl.modules[token or ""] or EMPTY
end

-- Locale key of a beat: BEAT_<CLASS>_<level> or BEAT_<CLASS>_<level>_<n>.
function Cl.BeatKey(token, beat)
    return "BEAT_" .. tostring(token) .. "_" .. beat.lv .. (beat.n and ("_" .. beat.n) or "")
end

-- Needs every class shares (phase 24): unspent talent points, the weapon master once around level
-- 10, the module's reagents, and a reminder on the level of a beat marked remind.
function Cl.Shared(m, x)
    local out = {}
    local level = x.level or 1
    if level >= 10 and (x.talentPoints or 0) > 0 then
        out[#out + 1] = { reason = "talents", urgency = 0.5, hint = true }
    end
    if level >= 10 and level <= 12 then
        out[#out + 1] = { role = "weapon", reason = "weapon", urgency = 0.2, maxDetour = 60, once = "weapon10" }
    end
    for _, r in ipairs(m.reagents or {}) do
        local have = x.items and x.items[r.item]
        if level >= r.from and have and have < r.min then
            out[#out + 1] = { role = r.role, reason = "reagent", urgency = 0.4, maxDetour = 120, arg = r.item }
        end
    end
    for _, beat in ipairs(m.beats or {}) do
        if beat.remind and beat.lv == level then
            out[#out + 1] = { reason = "beat", urgency = 0.35, hint = true, beat = Cl.BeatKey(x.class, beat) }
        end
    end
    return out
end

-- Supplies the class makes itself at this level (a mage conjures water and food): reason -> true.
function Cl.Makes(token, level)
    local out = {}
    for reason, from in pairs(Cl.Get(token).makes or {}) do
        if (level or 1) >= from then
            out[reason] = true
        end
    end
    return out
end

-- Every item id the class module wants counted in the bags (reagents, soul shards).
function Cl.Items(token)
    local m = Cl.Get(token)
    local out = {}
    for _, r in ipairs(m.reagents or {}) do
        out[#out + 1] = r.item
    end
    for _, id in ipairs(m.countItems or {}) do
        out[#out + 1] = id
    end
    return out
end

-- Needs from the shared class rules and the player's class module.
function Cl.Needs(token, x, profile)
    local m = Cl.Get(token)
    local out = Cl.Shared(m, x)
    if type(m.needs) == "function" then
        for _, need in ipairs(m.needs(x, profile) or {}) do
            out[#out + 1] = need
        end
    end
    return out
end
