-- Phase 23: service rules, the Hunter class module, provider search, insertion where it pays off,
-- flight paths and the hearth, visits; and the phase's "done when": full bags and low durability
-- put one sell-and-repair stop at the nearest provider.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K

local function x(over)
    local t = { level = 12, class = "WARRIOR", money = 0, freeSlots = 10, durability = 1,
        supplies = { food = 3, water = 3, ammo = 1000 }, visited = { weapon10 = true }, profTrained = {},
        taxiKnown = {} }
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

-- A small world: map 1 with a vendor/repair NPC near the quests, a food vendor far away, a flight
-- master and an inn; map 2 next door with another repair NPC.
local function world()
    local npcs = {
        [10] = { n = "Smith", r = { "repair", "vendor" }, p = { { 1, 52, 42 } } },
        [11] = { n = "Cook", r = { "food", "vendor" }, p = { { 1, 90, 90 } } },
        [12] = { n = "Wind Rider", r = { "fm" }, p = { { 1, 53, 44 } } },
        [13] = { n = "Innkeeper", r = { "inn" }, p = { { 1, 51, 41 } } },
        [20] = { n = "Far Smith", r = { "repair", "vendor" }, p = { { 2, 10, 10 } } },
    }
    local services = {
        [1] = { repair = { 10 }, vendor = { 10, 11 }, food = { 11 }, fm = { 12 }, inn = { 13 } },
        [2] = { repair = { 20 }, vendor = { 20 } },
    }
    return {
        zoneIds = function() return { 1, 2 } end,
        zoneServices = function(m) return services[m] end,
        zoneHubs = function(m) return m == 1 and { { id = "z:n13", name = "Hilltop", x = 51, y = 41 } } or {} end,
        npcPoints = function(id) return npcs[id] and npcs[id].p end,
        objectPoints = function() return nil end,
        npc = function(id) return npcs[id] end,
        travel = { adj = { { 1, 2 } }, links = {}, nodes = { [12] = { m = 1, x = 53, y = 44, n = "Hilltop, Plains" } },
            cost = { zoneBorder = 60 } },
    }
end

local function questSteps()
    local steps = {}
    for i = 1, 8 do
        steps[i] = { t = (i % 2 == 1) and "A" or "T", k = "plan:" .. i, q = i, z = 1, x = 50 + i * 0.5, y = 40 }
    end
    return steps
end

before_each(function()
    W.reset()
    K = W.loadAddon({ skipRoutes = true })
end)

describe("service rules", function()
    it("repair and sell: now when broken or full, soon when low", function()
        local Ru = K.Services.Rules
        local needs = Ru.Needs(x({ level = 9, durability = 0.1, freeSlots = 0 }))
        assert.are.same({ "repair", "sell" }, reasons(needs))
        assert.equal(1, needs[1].urgency)
        needs = Ru.Needs(x({ level = 9, durability = 0.4, freeSlots = 2 }))
        assert.are.same({ "sell", "repair" }, reasons(needs))
        assert.are.same({}, reasons(Ru.Needs(x())))
    end)

    it("food for everyone, water for mana classes", function()
        local Ru = K.Services.Rules
        assert.are.same({ "food" }, reasons(Ru.Needs(x({ supplies = { food = 0, water = 0 } }))))
        assert.are.same({ "food", "water" },
            reasons(Ru.Needs(x({ class = "PRIEST", supplies = { food = 0, water = 0 } }))))
    end)

    it("the class trainer at even levels, when the gold covers it", function()
        local Ru = K.Services.Rules
        assert.are.same({}, reasons(Ru.Needs(x({ level = 12, trainedAt = 10, money = 100 }))))
        assert.are.same({ "trainer" }, reasons(Ru.Needs(x({ level = 12, trainedAt = 10, money = 5000 }))))
        assert.are.same({}, reasons(Ru.Needs(x({ level = 13, trainedAt = 10, money = 5000 }))))
        local needs = Ru.Needs(x({ level = 14, trainedAt = 8, money = 5000 }))
        assert.equal(0.8, needs[1].urgency)
        assert.equal("ct_WARRIOR", needs[1].role)
    end)

    it("professions from the profile, and the hints (mail, bank, auction house)", function()
        local Ru = K.Services.Rules
        local needs = Ru.Needs(x({ hasMail = true, freeSlots = 3, money = 20000, trainedAt = 12 }),
            { professions = { "Herbalism" } })
        assert.are.same({ "profession", "bank", "mail", "ah" }, reasons(needs))
        assert.equal("pt_Herbalism", needs[1].role)
        assert.is_true(needs[2].hint)
    end)
end)

describe("Hunter module", function()
    it("buys the ammo the ranged weapon fires", function()
        local Ru = K.Services.Rules
        local needs = Ru.Needs(x({ class = "HUNTER", rangedSubclass = 3, supplies = { food = 3, water = 3, ammo = 20 } }))
        assert.equal("bullet", needs[1].role)
        assert.equal(0.9, needs[1].urgency)
        needs = Ru.Needs(x({ class = "HUNTER", rangedSubclass = 2, supplies = { food = 3, water = 3, ammo = 150 } }))
        assert.equal("arrow", needs[1].role)
    end)

    it("reminds to feed an unhappy pet, and visits the stable once at 10 and 20", function()
        local Ru = K.Services.Rules
        local needs = Ru.Needs(x({ class = "HUNTER", level = 10, hasPet = true, petHappiness = 1 }))
        assert.are.same({ "feedpet", "beat", "pettrainer", "stable" }, reasons(needs))
        needs = Ru.Needs(x({ class = "HUNTER", level = 11, hasPet = true, petHappiness = 3,
            visited = { stable10 = true, pettrainer = true, weapon10 = true } }))
        assert.are.same({}, reasons(needs))
    end)
end)

describe("insertion", function()
    local function apply(xx, steps, from)
        local wt = K.Plan.Weights.For()
        local Wd = world()
        local path = K.Plan.Transitions.Cache(Wd.travel, wt)
        return K.Services.Apply(steps or questSteps(), xx, Wd, wt, path, from or { m = 1, x = 50, y = 40 }, {})
    end

    it("one stop for sell and repair at the nearest provider, first when urgent", function()
        local out = apply(x({ level = 9, durability = 0.1, freeSlots = 0, taxiKnown = { ["Hilltop, Plains"] = true },
            supplies = { food = 0, water = 3, ammo = 0 } }))
        local s = out[1]
        assert.equal("S", s.t)
        assert.equal(10, s.npc)                 -- the Smith on this map, not the Far Smith
        assert.are.same({ "repair", "sell" }, s.reasons)
        local count = 0
        for _, step in ipairs(out) do
            if step.t == "S" then
                count = count + 1
            end
        end
        assert.equal(1, count)                  -- the far food vendor is not worth it
    end)

    it("a low-urgency stop is skipped when the provider is too far out of the way", function()
        local out = apply(x({ supplies = { food = 0, water = 3, ammo = 0 } }))
        for _, step in ipairs(out) do
            assert.are_not.equal("food", step.reason)
        end
    end)

    it("a stop that pays off goes where the detour is smallest", function()
        local out = apply(x({ durability = 0.45 }))
        local at
        for i, step in ipairs(out) do
            if step.reason == "repair" then
                at = i
            end
        end
        assert.is_number(at)
        assert.is_true(at > 1)                  -- on the way, not first
    end)

    it("an unknown flight path on the way is learned; a known one is not", function()
        local out = apply(x({ taxiKnown = {} }))
        local found = false
        for _, step in ipairs(out) do
            found = found or step.reason == "flight"
        end
        assert.is_true(found)
        out = apply(x({ taxiKnown = { ["Hilltop, Plains"] = true } }))
        for _, step in ipairs(out) do
            assert.are_not.equal("flight", step.reason)
        end
    end)

    it("binds the hearth where the next quests are", function()
        local out = apply(x({ bind = "Somewhere Else", taxiKnown = { ["Hilltop, Plains"] = true } }))
        local found
        for _, step in ipairs(out) do
            if step.reason == "hearth" then
                found = step
            end
        end
        assert.is_table(found)
        assert.equal(13, found.npc)
        out = apply(x({ bind = "Hilltop", taxiKnown = { ["Hilltop, Plains"] = true } }))
        for _, step in ipairs(out) do
            assert.are_not.equal("hearth", step.reason)
        end
    end)

    it("a place-less reminder (Feed Pet) comes first without a target", function()
        local out = apply(x({ class = "HUNTER", hasPet = true, petHappiness = 1, level = 12,
            visited = { pettrainer = true }, taxiKnown = { ["Hilltop, Plains"] = true } }))
        assert.equal("feedpet", out[1].reason)
        assert.is_nil(out[1].z)
    end)
end)

describe("the real world: full bags and low durability at Razor Hill", function()
    it("puts one sell-and-repair stop first, at a Razor Hill provider, not in Orgrimmar", function()
        K = W.start()
        W.state.level, W.state.race, W.state.raceToken, W.state.class = 9, "Orc", "Orc", "WARRIOR"
        W.state.mapID, W.state.pos = 1411, { x = 0.52, y = 0.43 }
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        local real = K.Services.Read
        K.Services.Read = function()
            local t = real()
            t.freeSlots, t.durability = 0, 0.12
            return t
        end
        K.Planner:Replan("test")
        local s = K.Planner.plan.steps[1]
        assert.equal("S", s.t)
        assert.equal(1411, s.z)
        assert.is_true(math.abs(s.x - 52) < 6 and math.abs(s.y - 43) < 6, "provider at " .. s.x .. "," .. s.y)
        local roles = {}
        for _, r in ipairs(K.WorldDB.Npc(s.npc).r) do
            roles[r] = true
        end
        assert.is_true(roles.repair and roles.vendor)
        table.sort(s.reasons)
        assert.are.same({ "repair", "sell" }, s.reasons)
    end)

    it("a class trainer visit clears the trainer stop", function()
        K = W.start()
        W.state.level, W.state.class = 12, "WARRIOR"
        W.state.mapID, W.state.pos = 1411, { x = 0.52, y = 0.43 }
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        local real = K.Services.Read
        K.Services.Read = function()
            local t = real()
            t.money, t.freeSlots, t.durability = 100000, 10, 1
            return t
        end
        local function hasTrainer()
            for _, s in ipairs(K.Planner:Get().steps) do
                if s.reason == "trainer" then
                    return true
                end
            end
            return false
        end
        K.cdb.trainedAt = 2
        K.Planner.dirty = true
        assert.is_true(hasTrainer())
        W.fire("TRAINER_SHOW")
        assert.equal(12, K.cdb.trainedAt)
        assert.is_false(hasTrainer())
    end)
end)
