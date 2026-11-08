-- Phase 24: class modules for all nine classes, the shared class rules (talents, weapon master,
-- reagents, beat reminders), supplies a class makes itself, cumulative trainer filters, the gear
-- advisor in the planner, and the generated docs/CLASS_BEATS.md.
package.path = "tests/lua/?.lua;tests/lua/tools/?.lua;" .. package.path
local W = require("wowstubs")
local Beats = require("class_beats")

local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local K
before_each(function()
    W.reset()
    K = W.loadAddon({ skipRoutes = true })
end)

local function x(over)
    local t = { level = 12, class = "WARRIOR", money = 0, freeSlots = 10, durability = 1,
        supplies = { food = 3, water = 3, ammo = 1000 }, visited = { weapon10 = true }, items = {} }
    for k, v in pairs(over or {}) do
        t[k] = v
    end
    return t
end

local function reasons(needs)
    local out = {}
    for _, n in ipairs(needs) do
        out[#out + 1] = n.reason
    end
    return out
end

describe("class modules", function()
    for _, token in ipairs(CLASSES) do
        it(token .. ": beats from 1 to 40, in level order, every text in the locale", function()
            local m = K.Class.Get(token)
            assert.is_table(m.beats)
            assert.is_true(#m.beats >= 6)
            local last = 0
            for _, beat in ipairs(m.beats) do
                assert.is_true(beat.lv >= last, token .. " beats out of order at " .. beat.lv)
                assert.is_true(beat.lv >= 1 and beat.lv <= 40)
                last = beat.lv
                local key = K.Class.BeatKey(token, beat)
                assert.is_string(K.L[key], "missing " .. key)
                assert.is_string(K.L["BEAT_KIND_" .. beat.kind], "missing kind " .. beat.kind)
            end
            assert.equal(1, m.beats[1].lv)
            assert.equal(40, m.beats[#m.beats].lv)
            assert.is_table(K.TrainerFilters[token])
            assert.is_table(K.ClassWeights[token])
        end)
    end
end)

describe("shared class rules", function()
    it("unspent talent points are a reminder from level 10", function()
        local Ru = K.Services.Rules
        assert.are.same({ "talents" }, reasons(Ru.Needs(x({ talentPoints = 2 }))))
        assert.are.same({}, reasons(Ru.Needs(x({ level = 9, talentPoints = 2 }))))
    end)

    it("the weapon master once around level 10", function()
        local Ru = K.Services.Rules
        assert.are.same({ "weapon" }, reasons(Ru.Needs(x({ level = 11, visited = {} }))))
        assert.are.same({}, reasons(Ru.Needs(x({ level = 13, visited = {} }))))
    end)

    it("reagents run low: Ankh for a level 30 Shaman, poisons and Flash Powder for a Rogue", function()
        local Ru = K.Services.Rules
        local needs = Ru.Needs(x({ class = "SHAMAN", level = 31, items = { [17030] = 0 } }))
        assert.are.same({ "reagent" }, reasons(needs))
        assert.equal("reagent", needs[1].role)
        needs = Ru.Needs(x({ class = "ROGUE", level = 23, items = { [6947] = 2, [5140] = 0 } }))
        assert.are.same({ "reagent", "reagent" }, reasons(needs))
        assert.equal("poison", needs[1].role)
        needs = Ru.Needs(x({ class = "SHAMAN", level = 29, items = { [17030] = 0 } }))
        assert.are.same({}, reasons(needs))
    end)

    it("a beat marked reminder shows on its level only", function()
        local Ru = K.Services.Rules
        local needs = Ru.Needs(x({ class = "WARLOCK", level = 20, items = { [6265] = 5 } }))
        assert.are.same({ "beat" }, reasons(needs))
        assert.equal("BEAT_WARLOCK_20", needs[1].beat)
        assert.are.same({}, reasons(Ru.Needs(x({ class = "WARLOCK", level = 21, items = { [6265] = 5 } }))))
    end)

    it("a Warlock keeps three Soul Shards", function()
        local Ru = K.Services.Rules
        assert.are.same({ "shards" }, reasons(Ru.Needs(x({ class = "WARLOCK", level = 13, items = { [6265] = 1 } }))))
    end)

    it("a Mage buys no water from level 4 and no food from level 6; a Priest does", function()
        local Ru = K.Services.Rules
        local empty = { food = 0, water = 0 }
        assert.are.same({ "food" }, reasons(Ru.Needs(x({ class = "MAGE", level = 5, supplies = empty }))))
        assert.are.same({}, reasons(Ru.Needs(x({ class = "MAGE", level = 7, supplies = empty }))))
        assert.are.same({ "food", "water" }, reasons(Ru.Needs(x({ class = "PRIEST", level = 7, supplies = empty }))))
    end)

    it("carries two stacks of food from level 20", function()
        local Ru = K.Services.Rules
        assert.are.same({}, reasons(Ru.Needs(x({ level = 19, supplies = { food = 1 } }))))
        assert.are.same({ "food" }, reasons(Ru.Needs(x({ level = 21, supplies = { food = 1 } }))))
    end)
end)

describe("trainer filters accumulate", function()
    it("a level 30 Warrior still buys Heroic Strike ranks, and the 30 band adds Intercept", function()
        local band = K.Trainer.Band("WARRIOR", 30)
        local set = {}
        for _, name in ipairs(band.essential) do
            set[name] = true
        end
        assert.is_true(set["Heroic Strike"])
        assert.is_true(set["Intercept"])
        assert.equal("Heroic Strike", band.essential[1])
        for _, name in ipairs(band.skipForNow) do
            assert.is_nil(set[name], name .. " is both essential and skip")
        end
    end)

    it("every class has early core spells in its first band", function()
        local early = { WARRIOR = "Overpower", ROGUE = "Backstab", PRIEST = "Mind Blast", MAGE = "Frost Nova",
            HUNTER = "Multi-Shot", SHAMAN = "Ghost Wolf", DRUID = "Entangling Roots", WARLOCK = "Drain Soul",
            PALADIN = "Hammer of Justice" }
        for token, spell in pairs(early) do
            local found = false
            for _, name in ipairs(K.Trainer.Band(token, 20).essential) do
                found = found or name == spell
            end
            assert.is_true(found, token .. " " .. spell)
        end
    end)
end)

describe("gear advisor", function()
    it("a quest whose reward is an upgrade scores higher", function()
        local Sc = K.Plan.Score
        local wt = K.Plan.Weights.For()
        local plain = Sc.Value({ xp = 1000, lv = 15 }, 15, wt)
        local up = Sc.Value({ xp = 1000, lv = 15, upgrade = true }, 15, wt)
        assert.near(plain * wt.upgrade, up, 1e-6)
    end)

    it("the planner asks the reward advisor and caches its answer", function()
        local calls = 0
        K.Rewards.Useful = function(item)
            calls = calls + 1
            return item == 4914, 1, "item"
        end
        K.Rewards.ReadItem = function() return { info = {} } end
        assert.is_true(K.Planner.RewardUpgrade({ rw = { 4915, 4914 } }))
        assert.is_true(K.Planner.RewardUpgrade({ rw = { 4915, 4914 } }))
        assert.equal(2, calls)
        assert.is_false(K.Planner.RewardUpgrade({ rw = { 4915 } }))
        W.fire("PLAYER_EQUIPMENT_CHANGED")
        assert.is_false(K.Planner.RewardUpgrade({ rw = { 4915 } }))
        assert.equal(3, calls)
    end)
end)

describe("docs/CLASS_BEATS.md", function()
    it("is up to date (lua tests/lua/tools/gen_class_beats.lua)", function()
        -- docs/ is local only (not in git), so a fresh clone has no file to compare.
        local f = io.open("docs/CLASS_BEATS.md", "rb")
        if not f then
            return
        end
        local text = f:read("*a")
        f:close()
        assert.equal(Beats.Render(Beats.Load()), text)
    end)
end)
