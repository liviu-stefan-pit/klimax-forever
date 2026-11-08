-- Smart engine research slice: calibration of the objective time (Weights.LearnUpdate / ApplyLearned,
-- shared with the Python mirror through tests/vectors/learn.json), the live learner, the nearest-cluster
-- pick, the shared-camp discount and the plan-stability bonus.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local json = require("dkjson")

local function readJson(path)
    local f = assert(io.open(path, "r"), path)
    local text = f:read("*a")
    f:close()
    return assert(json.decode(text, 1, nil))
end

local K
before_each(function()
    W.reset()
    K = W.loadAddon({ skipRoutes = true })
    K.db = {}
    K.cdb = {}
end)

describe("learned weights (shared vector)", function()
    local v = readJson("tests/vectors/learn.json")

    it("updates the running mean like the Python mirror", function()
        local entry
        for i, x in ipairs(v.samples) do
            entry = K.Plan.Weights.LearnUpdate(entry, x, v.default)
            assert.near(v.means[i], entry.m, 1e-9)
        end
        assert.equal(#v.samples, entry.n)
    end)

    it("applies only enough samples, clamped", function()
        for _, case in ipairs(v.apply) do
            local wt = K.Plan.Weights.For(nil, nil, case.learned)
            assert.near(case.objective, wt.objective, 1e-9, case.name)
        end
    end)

    it("leaves the weights alone when nothing is learned", function()
        assert.are.same(K.Plan.Weights.DEFAULT, K.Plan.Weights.For(nil, nil, nil))
        assert.are.same(K.Plan.Weights.DEFAULT, K.Plan.Weights.For(nil, nil, {}))
    end)
end)

describe("learner", function()
    it("recognises the objective area and rejects unusable samples", function()
        local Ln = K.Learner
        local step = { t = "C", z = 5, x = 50, y = 50 }
        assert.is_true(Ln.Arrived(step, { m = 5, x = 51, y = 51 }))
        assert.is_false(Ln.Arrived(step, { m = 5, x = 60, y = 50 }))
        assert.is_false(Ln.Arrived(step, { m = 6, x = 50, y = 50 }))
        assert.is_false(Ln.Arrived({ t = "A", z = 5, x = 50, y = 50 }, { m = 5, x = 50, y = 50 }))
        assert.near(40, Ln.PerObjective(120, 3), 1e-9)
        assert.is_nil(Ln.PerObjective(3, 1))
        assert.is_nil(Ln.PerObjective(5000, 1))
    end)

    it("observes without touching its input and feeds the plan weights", function()
        local Ln = K.Learner
        local a = Ln.Observe(nil, 60)
        local b = Ln.Observe(a, 60)
        local c = Ln.Observe(b, 60)
        assert.equal(1, a.objective.n)
        assert.equal(3, c.objective.n)
        assert.is_true(K.Plan.Weights.For(nil, nil, c).objective < 100)
        assert.equal(100, K.Plan.Weights.For(nil, nil, b).objective)
    end)

    it("reset forgets what was learned", function()
        K.cdb.learned = K.Learner.Observe(nil, 60)
        K.Learner.Command("reset")
        assert.is_nil(K.cdb.learned)
        K.Learner.Command("off")
        assert.is_false(K.Learner.Enabled())
        K.Learner.Command("on")
        assert.is_true(K.Learner.Enabled())
    end)
end)

describe("camps and stability", function()
    local function world(quests)
        local rec = {}
        for q, at in pairs(quests) do
            rec[q] = { n = "Q" .. q, lv = 2, rl = 1, xp = 100, sn = { 10 }, en = { 10 },
                o = { { k = "c", at = at } } }
        end
        local ids = {}
        for q in pairs(quests) do
            ids[#ids + 1] = q
        end
        table.sort(ids)
        return {
            zoneIds = function() return { 1 } end,
            zoneInfo = function() return { lv = { 1, 3, 6 } } end,
            zoneQuests = function() return ids end,
            quest = function(q) return rec[q] end,
            questZone = function() return 1 end,
            npcPoints = function() return { { 1, 10, 50 } } end,
            objectPoints = function() return nil end,
            travel = { adj = {}, links = {}, nodes = {}, cost = { zoneBorder = 60 } },
        }
    end
    local snap = { level = 2, xp = 0, mapID = 1, x = 50, y = 50 }
    local camp = { [1] = { { 1, 70, 50, 2 } }, [2] = { { 1, 73, 50, 2 } } }
    local function active() return "active" end

    it("picks the cluster nearest to the player, not the first listed", function()
        local Ca = K.Plan.Candidates
        local spots = Ca.ObjectiveSpots({ o = { { at = { { 1, 95, 50, 2 }, { 1, 58, 50, 2 } } } } },
            { m = 1, x = 50, y = 50 })
        assert.equal(58, spots[1].x)
        -- the walk chains: the second objective is measured from the first spot
        spots = Ca.ObjectiveSpots({ o = { { at = { { 1, 60, 50 } } }, { at = { { 1, 10, 50 }, { 1, 62, 50 } } } } },
            { m = 1, x = 50, y = 50 })
        assert.equal(62, spots[2].x)
    end)

    it("discounts the time of an objective at the camp already being worked", function()
        local wt = K.Plan.Weights.For()
        local steps = K.Planner.Build(world(camp), active, snap, wt)
        local by = {}
        for _, s in ipairs(steps) do
            by[s.k] = s
        end
        -- whichever is worked second shares the camp of the first (the walk order may be improved later)
        local shared = by["plan:C:1"].why.shared and by["plan:C:1"] or by["plan:C:2"]
        local first = shared == by["plan:C:1"] and by["plan:C:2"] or by["plan:C:1"]
        assert.is_true(shared.why.shared)
        assert.is_nil(first.why.shared)
        assert.near(wt.objective * wt.shareTime, shared.why.time, 1e-9)
    end)

    it("scores tasks of the previous plan higher and builds the prior from a plan", function()
        local wt = K.Plan.Weights.For()
        local w = world(camp)
        local steps = K.Planner.Build(w, active, snap, wt, nil, { ["plan:C:2"] = true })
        for _, s in ipairs(steps) do
            if s.k == "plan:C:2" then
                assert.is_true(s.why.kept)
            end
        end
        local prior = K.Planner.PriorKeys({ steps = { { t = "V", k = "plan:V:1:1" }, { t = "C", k = "plan:C:1" } } })
        assert.are.same({ ["plan:C:1"] = true }, prior)
        assert.is_nil(K.Planner.PriorKeys(nil))
    end)

    it("never delays a hand-in when relocating", function()
        local steps = {
            { t = "C", k = "c1", q = 1, z = 1, x = 10, y = 50 },
            { t = "T", k = "t1", q = 1, z = 1, x = 90, y = 50 },
            { t = "C", k = "c2", q = 2, z = 1, x = 12, y = 50 },
        }
        local out = K.Plan.Sequence.Relocate(steps, { mapID = 1, x = 10, y = 50 }, K.Plan.Weights.For(), function() end)
        assert.equal("t1", out[2].k)
    end)
end)
