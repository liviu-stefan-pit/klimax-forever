-- Phase 21: the planner (Klimax/Plan). Pure scoring, transitions and sequencing; the shared vectors
-- in tests/vectors/planner (the Python mirror, pipeline/sim/planner.py, runs the same files); the
-- real compiled world on a level 1 Orc and on the level 15 Hunter fixture; plan stability.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local Fx = require("fixture")
local json = require("dkjson")

local VECTORS = "tests/vectors/planner/"
local VECTOR_NAMES = { "hub", "ready_here", "zone_change", "chain", "tie_break", "equivalent", "cluster", "relocate",
    "stable" }

local function readJson(path)
    local f = assert(io.open(path, "r"), path)
    local text = f:read("*a")
    f:close()
    return assert(json.decode(text, 1, nil))
end

-- JSON object keys are strings; quest, NPC and map ids are numbers in the add-on.
local function numKeys(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[tonumber(k) or k] = v
    end
    return out
end

-- World interface over a vector's plain tables.
local function vectorWorld(v)
    local w = v.world
    local zones = numKeys(w.zones)
    local quests = numKeys(w.quests)
    local npcs = numKeys(w.npcs)
    local objects = numKeys(w.objects)
    local questZone = {}
    local ids = {}
    for m, z in pairs(zones) do
        ids[#ids + 1] = m
        table.sort(z.quests)
        for _, q in ipairs(z.quests) do
            questZone[q] = m
        end
    end
    table.sort(ids)
    local travel = w.travel or {}
    travel.nodes = numKeys(travel.nodes)
    return {
        zoneIds = function() return ids end,
        zoneInfo = function(m) return zones[m] end,
        zoneQuests = function(m) return zones[m] and zones[m].quests or {} end,
        quest = function(q) return quests[q] end,
        questZone = function(q) return questZone[q] end,
        npcPoints = function(id) return npcs[id] end,
        objectPoints = function(id) return objects[id] end,
        xpl = w.xpl,
        travel = travel,
    }
end

local function vectorState(v)
    local states = numKeys(v.states)
    return function(q)
        local s = states[q]
        if s then
            return s[1], s[2]
        end
        return "available"
    end
end

local K
before_each(function()
    W.reset()
    K = W.loadAddon({ skipRoutes = true })
end)

local function keys(steps)
    local out = {}
    for _, s in ipairs(steps) do
        out[#out + 1] = s.k
    end
    return out
end

local function runVector(name)
    local v = readJson(VECTORS .. name .. ".json")
    local wt = K.Plan.Weights.For(nil, nil)
    if v.weights then
        K.Plan.Weights.Merge(wt, v.weights)
    end
    local prior
    if v.prior then
        prior = {}
        for _, k in ipairs(v.prior) do
            prior[k] = true
        end
    end
    local steps = K.Planner.Build(vectorWorld(v), vectorState(v), v.snapshot, wt, nil, prior)
    return keys(steps), v, steps
end

describe("planner vectors (shared with the Python mirror)", function()
    for _, name in ipairs(VECTOR_NAMES) do
        it(name, function()
            local got, v, steps = runVector(name)
            assert.are.same(v.expect, got, v.name)
            for k, at in pairs(v.expectAt or {}) do
                for _, step in ipairs(steps) do
                    if step.k == k then
                        assert.are.same(at, { step.x, step.y }, k)
                    end
                end
            end
        end)
    end

    it("weights.json matches Weights.DEFAULT and LEVEL_XP", function()
        local file = readJson(VECTORS .. "weights.json")
        assert.are.same(K.Plan.Weights.DEFAULT, file.default)
        assert.are.same(K.Plan.Weights.LEVEL_XP, file.levelXp)
        assert.are.same(K.Plan.Weights.PROFILE, file.profile)
        assert.are.same(K.Plan.Weights.ORDER, file.order)
    end)
end)

describe("scoring", function()
    it("colours a quest level for the player level", function()
        local Sc = K.Plan.Score
        assert.equal("red", Sc.Colour(20, 15, 4))
        assert.equal("orange", Sc.Colour(18, 15, 4))
        assert.equal("yellow", Sc.Colour(13, 15, 4))
        assert.equal("green", Sc.Colour(10, 15, 4))
        assert.equal("grey", Sc.Colour(8, 15, 4))
    end)

    it("computes Classic XP at level and multiplies the value terms", function()
        local Sc = K.Plan.Score
        assert.equal(1000, Sc.XpAt(1000, 10, 15))
        assert.equal(800, Sc.XpAt(1000, 10, 16))
        assert.equal(100, Sc.XpAt(1000, 10, 25))
        local wt = K.Plan.Weights.For()
        local v, terms = Sc.Value({ xp = 1000, lv = 15, classQuest = true, flags = { "elite" } }, 15, wt)
        assert.equal("yellow", terms.colour)
        assert.near(1000 * 1.0 * 0.6 * 1.4, v, 1e-6)
    end)

    it("applies profile presets in a fixed order", function()
        local wt = K.Plan.Weights.For({ elites = "skip", completionist = "finish", pace = "speed" })
        assert.equal(0, wt.risk.elite)
        assert.equal(1.0, wt.colour.green)       -- completionist overrides the pace preset
        assert.equal(1.6, wt.leaveZone)
        assert.equal(0.6, K.Plan.Weights.DEFAULT.risk.elite)   -- the defaults are untouched
    end)
end)

describe("the curated spine (phase 25)", function()
    local Sc = function() return K.Plan.Score end
    local spine = { onPath = 1.15, offPath = 0.6, dungeonWindow = 1.5, boost = { [840] = 1.3 },
        branches = { durotar = { { 1411, 1, 12 }, { 1413, 10, 24 } } },
        dungeons = { { n = "Wailing Caverns", m = 1413, lo = 17, hi = 24 } } }

    it("builds the branch table, or nothing for an unknown branch or world", function()
        local sp = K.Planner.SpineFor(spine, "durotar")
        assert.equal(2, #sp.rows)
        assert.equal(1.15, sp.on)
        assert.is_nil(K.Planner.SpineFor(spine, "elf"))
        assert.is_nil(K.Planner.SpineFor(nil, "durotar"))
    end)

    it("is neutral without a spine", function()
        assert.equal(1.0, Sc().Spine({ q = 1, m = 1411 }, 5, {}))
    end)

    it("prefers the home zone at its levels, then the next zone once the level fits", function()
        local wt = { spine = K.Planner.SpineFor(spine, "durotar") }
        assert.equal(1.15, Sc().Spine({ q = 1, m = 1411 }, 5, wt))
        assert.equal(0.6, Sc().Spine({ q = 1, m = 1411 }, 14, wt))   -- outgrown
        assert.equal(0.6, Sc().Spine({ q = 1, m = 1412 }, 5, wt))    -- another race's zone
        assert.equal(1.15, Sc().Spine({ q = 1, m = 1413 }, 14, wt))
        assert.near(1.15 * 1.3, Sc().Spine({ q = 840, m = 1411 }, 5, wt), 1e-9)
    end)

    it("boosts dungeon quests inside the window only", function()
        local wt = { spine = K.Planner.SpineFor(spine, "durotar") }
        local p = { q = 2, m = 1413, flags = { "dungeon" } }
        assert.near(1.15 * 1.5, Sc().Spine(p, 20, wt), 1e-9)
        assert.equal(1.15, Sc().Spine(p, 12, wt))
        assert.equal(1.15, Sc().Spine({ q = 2, m = 1413, flags = {} }, 20, wt))
    end)

    it("shows in the value terms and moves the value", function()
        local wt = K.Plan.Weights.For()
        local base = Sc().Value({ xp = 1000, lv = 5, m = 1411 }, 5, wt)
        wt.spine = K.Planner.SpineFor(spine, "durotar")
        local v, terms = Sc().Value({ xp = 1000, lv = 5, m = 1411 }, 5, wt)
        assert.equal(1.15, terms.spine)
        assert.near(base * 1.15, v, 1e-6)
    end)

    it("compiles into the world index", function()
        local sp = K.WorldDB.index.spine
        assert.is_table(sp)
        assert.is_table(sp.branches.zephras)
        assert.equal(1.15, sp.onPath)
    end)
end)

describe("transitions", function()
    it("finds the cheapest path over borders, boats and flights", function()
        local Tr = K.Plan.Transitions
        local wt = K.Plan.Weights.For()
        local travel = {
            cost = { zoneBorder = 60, boat = 300 },
            adj = { { 1, 2 }, { 2, 3 } },
            links = { { k = "boat", m = 1, to = 3, x = 10, y = 10 } },
            nodes = { [100] = { m = 1, x = 5, y = 5 }, [101] = { m = 4, x = 6, y = 6 } },
        }
        local g = Tr.Graph(travel, wt)
        local cost, edge = Tr.Path(g, 1, 3)
        assert.equal(300, cost)                  -- the boat (300) beats two borders (2 x 150)
        assert.equal("boat", edge.via)
        cost, edge = Tr.Path(g, 1, 4)
        assert.equal(wt.flight, cost)
        assert.equal("flight", edge.via)
        assert.is_nil(Tr.Path(g, 2, 99))
    end)
end)

-- Phase 31: a hand-in that completes another quest (its breadcrumb) keeps that quest in step.imp;
-- the improvement passes never move the accept of that quest after it. Same test in Python
-- (test_improvement_never_moves_an_accept_after_the_hand_in_that_implies_it).
describe("improvement passes and implied quests", function()
    it("never move an accept after the hand-in that implies its quest", function()
        local Sq = K.Plan.Sequence
        local wt = K.Plan.Weights.For()
        local path = K.Plan.Transitions.Cache({ cost = { zoneBorder = 60 }, adj = {}, links = {}, nodes = {} }, wt)
        local snap = { mapID = 1, x = 52, y = 50 }
        local function steps(imp)
            return {
                { t = "A", k = "plan:A:1", q = 1, z = 1, x = 20, y = 50 },
                { t = "T", k = "plan:T:2", q = 2, z = 1, x = 52, y = 50, imp = imp },
            }
        end
        assert.same({ "plan:T:2", "plan:A:1" }, keys(Sq.Improve(steps(nil), snap, wt, path)))
        assert.same({ "plan:A:1", "plan:T:2" }, keys(Sq.Improve(steps({ [1] = true }), snap, wt, path)))
        assert.same({ "plan:A:1", "plan:T:2" }, keys(Sq.Relocate(steps({ [1] = true }), snap, wt, path)))
    end)
end)

describe("the compiled world", function()
    local function login(level, mapID, x, y, race, class)
        K = W.start()
        W.state.level, W.state.race, W.state.raceToken, W.state.class = level, race or "Orc", race or "Orc", class or "WARRIOR"
        W.state.mapID, W.state.pos = mapID, { x = x / 100, y = y / 100 }
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        return K
    end

    it("plans a fresh Orc in the Valley of Trials: the first quest from Kaltunk, then the hub", function()
        login(1, 1411, 43.2, 68.6)
        local plan = K.Planner:Get()
        assert.is_true(#plan.steps >= 8)
        local first = plan.steps[1]
        assert.equal("A", first.t)
        assert.equal(4641, first.q)               -- Your Place In The World (Kaltunk)
        local seen = {}
        for _, s in ipairs(plan.steps) do
            assert.is_nil(seen[s.k], "step twice: " .. s.k)
            seen[s.k] = true
            assert.is_number(s.x)
            assert.is_number(s.z)
        end
        assert.is_true(plan.ms < 250, "replan took " .. plan.ms .. " ms")
    end)

    it("never plans a quest for another race or class", function()
        login(4, 1411, 42.0, 68.0, "Orc", "WARRIOR")
        for _, s in ipairs(K.Planner:Get().steps) do
            local rec = K.WorldDB.Quest(s.q)
            if rec and rec.cl then
                assert.is_true(K.Reconciler.HasBit(rec.cl, 1), "class quest " .. s.q)
            end
            if rec and rec.ra then
                assert.is_true(K.Reconciler.HasBit(rec.ra, 2), "race quest " .. s.q)
            end
        end
    end)

    it("explains every step and prints /klimax why", function()
        login(1, 1411, 43.2, 68.6)
        local plan = K.Planner:Get()
        for _, s in ipairs(plan.steps) do
            assert.is_true(#K.Planner.Why(s) > 0)
        end
        W.printed = {}
        K.Command("why 1")
        assert.is_true(#W.printed >= 3)
        W.printed = {}
        K.Command("plan")
        assert.is_true(#W.printed >= 2)
    end)

    it("keeps the first step when a replan finds nothing clearly better", function()
        login(1, 1411, 43.2, 68.6)
        local first = K.Planner:Get().steps[1].k
        W.state.pos = { x = 0.433, y = 0.686 }   -- a step aside
        K.State:Refresh("move")
        assert.equal(first, K.Planner:Get().steps[1].k)
    end)

    it("replans once the first step is done", function()
        login(1, 1411, 43.2, 68.6)
        local first = K.Planner:Get().steps[1]
        W.setQuestLog(first.q, false)
        K.State:Refresh("questlog")
        local now = K.Planner:Get().steps[1]
        assert.are_not.equal(first.k, now.k)
    end)

    it("plans the level 15 Hunter fixture from the capitals' and start zones' data", function()
        local fx = Fx.load("hunter15_synthetic")
        K = Fx.start(fx)
        local plan = K.Planner:Get()
        assert.is_table(plan)
        for _, s in ipairs(plan.steps) do
            local st = K.State:Get(s.q)
            assert.is_true(st ~= "completed" and st ~= "failed", s.k .. " is " .. tostring(st))
        end
    end)
end)
