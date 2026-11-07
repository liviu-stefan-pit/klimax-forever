-- Class modules for the eight classes other than the Hunter (phase 24). Data first: level beats
-- (texts in Locale/enUS.lua as BEAT_<CLASS>_<level>[_n]), reagents to keep in the bags, supplies
-- the class makes itself, and class-specific needs. The trainer lists live in Data/TrainerFilters.lua
-- and the gear rules in Data/ClassWeights.lua. Shared rules (talent points, weapon master, reagents)
-- are in Class/Class.lua. docs/CLASS_BEATS.md is generated from these tables.
--
-- Beat: {lv, kind, remind}. kind: train | quest | talent | reagent | gear | mount | pet.
-- remind = true: the beat is also a one-time reminder in the plan when the level is reached.
-- Reagent: {item, from, min, role}: keep at least `min` from level `from`; bought at `role`.
local _, K = ...
local R = K.Class.Register

R("WARRIOR", {
    beats = {
        { lv = 1, kind = "train" }, { lv = 4, kind = "train" }, { lv = 6, kind = "train" },
        { lv = 8, kind = "train" }, { lv = 10, kind = "quest", remind = true }, { lv = 10, n = 2, kind = "talent" },
        { lv = 12, kind = "train" }, { lv = 20, kind = "gear" }, { lv = 24, kind = "train" },
        { lv = 30, kind = "quest", remind = true }, { lv = 40, kind = "mount", remind = true },
    },
})

R("PALADIN", {
    beats = {
        { lv = 1, kind = "train" }, { lv = 4, kind = "train" }, { lv = 8, kind = "train" },
        { lv = 10, kind = "talent" }, { lv = 12, kind = "quest", remind = true }, { lv = 20, kind = "train" },
        { lv = 40, kind = "mount", remind = true },
    },
})

R("ROGUE", {
    beats = {
        { lv = 1, kind = "train" }, { lv = 4, kind = "train" }, { lv = 8, kind = "train" },
        { lv = 10, kind = "talent" }, { lv = 16, kind = "quest", remind = true },
        { lv = 20, kind = "quest", remind = true }, { lv = 22, kind = "reagent" },
        { lv = 40, kind = "mount", remind = true },
    },
    reagents = {
        { item = 6947, from = 20, min = 10, role = "poison" },   -- Instant Poison
        { item = 5140, from = 22, min = 5, role = "reagent" },   -- Flash Powder (Vanish)
    },
})

R("PRIEST", {
    beats = {
        { lv = 1, kind = "train" }, { lv = 4, kind = "train" }, { lv = 6, kind = "train" },
        { lv = 10, kind = "train" }, { lv = 10, n = 2, kind = "talent" }, { lv = 12, kind = "train" },
        { lv = 14, kind = "train" }, { lv = 20, kind = "train" }, { lv = 40, kind = "mount", remind = true },
    },
})

R("SHAMAN", {
    beats = {
        { lv = 1, kind = "train" }, { lv = 4, kind = "quest", remind = true }, { lv = 8, kind = "train" },
        { lv = 10, kind = "quest", remind = true }, { lv = 10, n = 2, kind = "talent" },
        { lv = 20, kind = "quest", remind = true }, { lv = 20, n = 2, kind = "train" },
        { lv = 30, kind = "quest", remind = true }, { lv = 30, n = 2, kind = "reagent" },
        { lv = 40, kind = "mount", remind = true },
    },
    reagents = {
        { item = 17030, from = 30, min = 2, role = "reagent" },  -- Ankh (Reincarnation)
    },
})

R("MAGE", {
    beats = {
        { lv = 1, kind = "train" }, { lv = 4, kind = "train" }, { lv = 6, kind = "train" },
        { lv = 8, kind = "train" }, { lv = 10, kind = "talent" }, { lv = 20, kind = "train" },
        { lv = 20, n = 2, kind = "reagent" }, { lv = 40, kind = "mount", remind = true },
    },
    reagents = {
        { item = 17031, from = 20, min = 2, role = "reagent" },  -- Rune of Teleportation
        { item = 17032, from = 40, min = 2, role = "reagent" },  -- Rune of Portals
    },
    -- conjures its own: no food from level 6, no water from level 4
    makes = { water = 4, food = 6 },
})

R("WARLOCK", {
    beats = {
        { lv = 1, kind = "pet" }, { lv = 4, kind = "train" }, { lv = 8, kind = "train" },
        { lv = 10, kind = "quest", remind = true }, { lv = 10, n = 2, kind = "talent" },
        { lv = 20, kind = "quest", remind = true }, { lv = 30, kind = "quest", remind = true },
        { lv = 40, kind = "mount", remind = true },
    },
    countItems = { 6265 },   -- Soul Shard
    needs = function(x)
        local shards = x.items and x.items[6265] or nil
        if (x.level or 1) >= 10 and shards and shards < 3 then
            return { { reason = "shards", urgency = 0.3, hint = true } }
        end
        return {}
    end,
})

R("DRUID", {
    beats = {
        { lv = 1, kind = "train" }, { lv = 4, kind = "train" }, { lv = 8, kind = "train" },
        { lv = 10, kind = "quest", remind = true }, { lv = 10, n = 2, kind = "talent" },
        { lv = 16, kind = "quest", remind = true }, { lv = 20, kind = "train" },
        { lv = 20, n = 2, kind = "reagent" }, { lv = 30, kind = "train" }, { lv = 40, kind = "mount", remind = true },
    },
    reagents = {
        { item = 17034, from = 20, min = 1, role = "reagent" },  -- Maple Seed (Rebirth)
    },
})
