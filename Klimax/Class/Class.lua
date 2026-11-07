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

-- Needs from the player's class module (empty list when it has none).
function Cl.Needs(token, x, profile)
    local m = Cl.Get(token)
    if type(m.needs) ~= "function" then
        return {}
    end
    return m.needs(x, profile) or {}
end
