-- Phase 27: explainability. The pure functions of Klimax/Plan/Explain.lua (forecast, "why not",
-- replan notes, tooltips) and the Plan view model, on small hand-made tables and on the real world.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K, Ex

setup(function()
    K = W.start()
    Ex = K.Plan.Explain
end)

local function env(over)
    local recs = {
        [1] = { n = "Alpha", lv = 10, rl = 8, xp = 500 },
        [2] = { n = "Beta", lv = 12, rl = 14, xp = 500 },
        [3] = { n = "Gamma", lv = 10, rl = 8, pa = { 1 } },
        [4] = { n = "Delta", lv = 10, rl = 8, ex = 7 },
        [5] = { n = "Epsilon", lv = 3, rl = 1, xp = 100 },
        [6] = { n = "Zeta", lv = 10, rl = 8, f = { "dungeon" } },
    }
    local states = { [1] = { "available" }, [2] = { "unavailable", "level" }, [3] = { "unavailable", "prereq" },
        [4] = { "unavailable", "exclusive" }, [5] = { "available" }, [6] = { "available" },
        [7] = { "completed" }, [8] = { "ignored", "skipped" }, [9] = { "broken", "curated" },
        [10] = { "active" } }
    recs[7] = { n = "Eta" }
    recs[8] = { n = "Theta" }
    recs[9] = { n = "Iota" }
    recs[10] = { n = "Kappa" }
    local e = {
        L = K.L, snap = { level = 10 }, wt = K.Plan.Weights.For(),
        zoneName = function(m) return ({ [1] = "Durotar", [2] = "The Barrens" })[m] end,
        hubs = function(m)
            if m == 1 then
                return { { name = "Razor Hill", x = 50, y = 50, r = 2 } }
            end
            return {}
        end,
        W = { questZone = function() return 1 end },
        rec = function(q) return recs[q] end,
        state = function(q)
            local s = states[q]
            if s then
                return s[1], s[2]
            end
            return "unknown", "untracked"
        end,
        plan = { steps = {} },
    }
    for k, v in pairs(over or {}) do
        e[k] = v
    end
    return e
end

describe("forecast", function()
    local plan = { steps = {
        { t = "A", z = 1, x = 50, y = 50, q = 1, n = "Alpha" },
        { t = "C", z = 1, x = 51, y = 51, q = 1, n = "Alpha" },
        { t = "T", z = 1, x = 50, y = 50, q = 1, n = "Alpha" },
        { t = "V", to = 2, why = { via = "walk" } },
        { t = "A", z = 2, x = 30, y = 30, q = 2, n = "Beta" },
    } }

    it("groups steps into stops by zone and hub, and lists the zone changes", function()
        local f = Ex.Forecast(plan, env())
        assert.equal(2, #f.segments)  -- Razor Hill, the Barrens
        assert.equal("Razor Hill", f.segments[1].hub)
        assert.equal(1, f.segments[1].counts.A)
        assert.equal(1, f.segments[1].counts.T)
        assert.equal(1, #f.changes)
        assert.equal(4, f.changes[1].at)
        assert.equal(2, f.changes[1].to)
    end)

    it("prints one line per stop and per change", function()
        local e = env()
        local lines = Ex.ForecastLines(Ex.Forecast(plan, e), e)
        assert.equal(3, #lines)
        assert.truthy(lines[1]:find("Razor Hill, Durotar", 1, true))
        assert.truthy(lines[3]:find("The Barrens", 1, true))
    end)

    it("is empty for no plan", function()
        local f = Ex.Forecast(nil, env())
        assert.are.same({}, f.segments)
    end)
end)

describe("why not", function()
    local function one(q, e)
        local lines = Ex.WhyNot(q, e or env())
        assert.is_true(#lines >= 1)
        return lines[1]
    end

    it("names the gate that hides a quest", function()
        assert.truthy(one(2):find("needs level 14, you are 10", 1, true))
        assert.truthy(one(3):find("finish first: Alpha", 1, true))
        assert.truthy(one(4):find("excludes", 1, true))
    end)

    it("says when it is done, skipped, curated broken or in the log", function()
        assert.truthy(one(7):find("already handed it in", 1, true))
        assert.truthy(one(8):find("you skipped", 1, true))
        assert.truthy(one(9):find("does not work on this server", 1, true))
        assert.truthy(one(10):find("quest log", 1, true))
    end)

    it("says grey and dungeon quests are left out, and that unknown ids are unknown", function()
        assert.truthy(one(5):find("grey", 1, true))
        assert.truthy(one(6):find("dungeon", 1, true))
        assert.truthy(one(999):find("not in the guide's data", 1, true))
    end)

    it("says where an available quest sits in the plan", function()
        local e = env({ plan = { steps = { { t = "A", q = 1, n = "Alpha", z = 1, x = 1, y = 1, why = {} } } } })
        assert.truthy(one(1, e):find("step 1", 1, true))
    end)
end)

describe("replan notes", function()
    local function plan(zone, first)
        local steps = { { t = "A", z = zone, q = 1, k = "plan:A:1" } }
        if first then
            table.insert(steps, 1, first)
        end
        return { steps = steps }
    end

    it("tells about a move to another zone for good", function()
        local text = Ex.ReplanNote(plan(1), plan(2), env())
        assert.truthy(text:find("Moving to The Barrens", 1, true))
        assert.truthy(text:find("Durotar", 1, true))
    end)

    it("stays quiet when the old zone still has work, or nothing changed", function()
        local both = { steps = { { t = "A", z = 2, q = 2 }, { t = "A", z = 1, q = 1 } } }
        assert.is_nil(Ex.ReplanNote(plan(1), both, env()))
        assert.is_nil(Ex.ReplanNote(plan(1), plan(1), env()))
        assert.is_nil(Ex.ReplanNote(nil, plan(2), env()))
    end)

    it("tells about an urgent stop that comes first", function()
        local stop = { t = "S", k = "svc:repair", note = "Repair your gear.", why = { urgency = 1 } }
        local text = Ex.ReplanNote(plan(1), plan(1, stop), env())
        assert.truthy(text:find("Repair your gear.", 1, true))
        assert.is_nil(Ex.ReplanNote(plan(1, stop), plan(1, stop), env()))
    end)
end)

describe("plan view model", function()
    it("lists the next steps with a why and a tooltip, and what is ahead", function()
        local e = env()
        local plan = { steps = {
            { t = "A", z = 1, x = 50, y = 50, q = 1, n = "Alpha", why = { xp = 500, colour = "yellow" } },
            { t = "V", to = 2, why = { via = "flight" } },
            { t = "A", z = 2, x = 30, y = 30, q = 2, n = "Beta", why = { xp = 600, spine = 1.15 } },
        } }
        local m = K.PlanView.Model(plan, e)
        assert.is_false(m.empty)
        assert.equal(3, #m.steps)
        assert.truthy(m.steps[1].why:find("500 XP", 1, true))
        assert.truthy(m.steps[3].why:find("on your route", 1, true))
        assert.is_true(#m.steps[1].tip >= 2)
        assert.is_true(#m.ahead >= 2)
    end)

    it("is empty without steps", function()
        assert.is_true(K.PlanView.Model({ steps = {} }, env()).empty)
        assert.is_true(K.PlanView.Model(nil, env()).empty)
    end)
end)

describe("the real world", function()
    it("finds quests by name and explains a high-level quest for a level 1 character", function()
        local found = K.Planner.FindQuests("Conscript of the Horde", 3)
        assert.is_true(#found >= 1)
        assert.is_true(#K.Planner.FindQuests("840", 3) == 1)
    end)
end)
