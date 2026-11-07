-- Hunter class module (phase 23 services; phase 24 adds beats and training).
-- Ammo by the equipped ranged weapon, Feed Pet when the pet is unhappy, the stable master at the
-- level-10 and level-20 pet moments, and the pet trainer after taming.
local _, K = ...

local H = {}

H.beats = {
    { lv = 1, kind = "train" }, { lv = 4, kind = "train" }, { lv = 6, kind = "train" },
    { lv = 8, kind = "train" }, { lv = 10, kind = "quest", remind = true }, { lv = 10, n = 2, kind = "pet" },
    { lv = 10, n = 3, kind = "talent" }, { lv = 12, kind = "train" }, { lv = 18, kind = "train" },
    { lv = 20, kind = "train" }, { lv = 20, n = 2, kind = "pet" }, { lv = 40, kind = "mount", remind = true },
}

H.AMMO_LOW = 200       -- arrows or bullets: below this, buy on the way
H.AMMO_CRITICAL = 60   -- below this, buy now
-- Ranged weapon subclasses (item class 2): bows and crossbows fire arrows, guns fire bullets.
H.ARROW_WEAPONS = { [2] = true, [18] = true }
H.BULLET_WEAPONS = { [3] = true }

function H.ammo(x)
    local sub = x.rangedSubclass
    if H.BULLET_WEAPONS[sub] then
        return "bullet"
    end
    if H.ARROW_WEAPONS[sub] then
        return "arrow"
    end
    return x.level and x.level >= 1 and "arrow" or nil
end

function H.needs(x)
    local out = {}
    local ammo = (x.supplies and x.supplies.ammo) or 0
    local kind = H.ammo(x)
    if kind and ammo < H.AMMO_LOW then
        out[#out + 1] = { role = kind, reason = "ammo", urgency = ammo < H.AMMO_CRITICAL and 0.9 or 0.4,
            maxDetour = ammo < H.AMMO_CRITICAL and 240 or 90 }
    end
    if x.hasPet and x.petHappiness == 1 then
        out[#out + 1] = { reason = "feedpet", urgency = 0.8, hint = true }
    end
    local level = x.level or 1
    if (level == 10 or level == 20) and not (x.visited and x.visited["stable" .. level]) then
        out[#out + 1] = { role = "stable", reason = "stable", urgency = 0.2, maxDetour = 45, once = "stable" .. level }
    end
    if level >= 10 and x.hasPet and not (x.visited and x.visited.pettrainer) then
        out[#out + 1] = { role = "pettrainer", reason = "pettrainer", urgency = 0.3, maxDetour = 90,
            once = "pettrainer" }
    end
    return out
end

K.Class.Register("HUNTER", H)
