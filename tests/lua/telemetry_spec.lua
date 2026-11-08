-- Phase 28: local telemetry and self-healing. The pure dwell and dialogue judgement, the record
-- store, and the round trip: two strikes hide a quest for the character and the planner moves on.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K, Tel

before_each(function()
    W.reset()
    K = W.loadAddon({ skipRoutes = true })
    K.db = {}
    K.cdb = {}
    K.player = { level = 12 }
    Tel = K.Telemetry
end)

local step = { t = "A", k = "plan:A:99", q = 99, n = "Lost Orders", npc = 500, z = 1413, x = 50, y = 50 }

describe("dwell", function()
    it("fires after DWELL seconds at the target, and only there", function()
        local pos = { m = 1413, x = 50.5, y = 50 }
        local state, hit = Tel.Dwell(nil, step, pos, 100)
        assert.is_false(hit)
        state, hit = Tel.Dwell(state, step, pos, 100 + Tel.DWELL - 1)
        assert.is_false(hit)
        state, hit = Tel.Dwell(state, step, pos, 100 + Tel.DWELL)
        assert.is_true(hit)
        assert.is_nil(state)
    end)

    it("resets when the player walks away, the step changes, or the step is not watchable", function()
        local state = Tel.Dwell(nil, step, { m = 1413, x = 50, y = 50 }, 0)
        assert.is_nil((Tel.Dwell(state, step, { m = 1413, x = 60, y = 50 }, 5)))
        assert.is_nil((Tel.Dwell(state, step, { m = 1411, x = 50, y = 50 }, 5)))
        local other = { t = "A", k = "plan:A:100", q = 100, npc = 501, z = 1413, x = 50, y = 50 }
        local next1 = Tel.Dwell(state, other, { m = 1413, x = 50, y = 50 }, 5)
        assert.equal("plan:A:100", next1.key)
        assert.is_nil((Tel.Dwell(nil, { t = "C", q = 1, z = 1, x = 1, y = 1 }, { m = 1, x = 1, y = 1 }, 0)))
    end)
end)

describe("dialogue judgement", function()
    it("an accept whose quest is not offered is not-offered", function()
        local talk = { npc = 500, titles = { "Something Else" }, quest = false }
        assert.equal("not-offered", Tel.Judge(step, talk))
    end)

    it("is quiet when the quest is offered, a quest window opened, or it was another NPC", function()
        assert.is_nil(Tel.Judge(step, { npc = 500, titles = { "lost orders" }, quest = false }))
        assert.is_nil(Tel.Judge(step, { npc = 500, titles = {}, quest = true }))
        assert.is_nil(Tel.Judge(step, { npc = 501, titles = {}, quest = false }))
        assert.is_nil(Tel.Judge(step, nil))
    end)

    it("a hand-in with no quest window is not-offered too", function()
        local turn = { t = "T", k = "plan:T:99", q = 99, npc = 500, z = 1413, x = 50, y = 50 }
        assert.equal("not-offered", Tel.Judge(turn, { npc = 500, titles = {}, quest = false }))
    end)
end)

describe("records and self-healing", function()
    it("counts repeats in one record and caps the list", function()
        local a = Tel.Record("dwell", step)
        local b = Tel.Record("dwell", step)
        assert.equal(a, b)
        assert.equal(2, a.n)
        assert.equal(12, a.level)
        for i = 1, Tel.MAX + 5 do
            Tel.Record("dwell", { t = "T", q = 1000 + i, npc = i, z = 1, x = 1, y = 1 })
        end
        assert.equal(Tel.MAX, #K.db.reports)
    end)

    it("hides the quest after the second strike and brings it back on restore", function()
        assert.is_false(Tel.Strike("dwell", step))
        assert.is_nil(K.cdb.brokenQuests)
        assert.is_true(Tel.Strike("dwell", step))
        assert.is_true(K.cdb.brokenQuests[99])
        assert.is_false(Tel.Strike("dwell", step))  -- already hidden
        local snap = { broken = K.cdb.brokenQuests, log = {}, completed = {}, level = 12 }
        local ctx = K.Reconciler.New(snap, { info = function() return { rl = 1 } end })
        local state, reason = K.Reconciler.State(ctx, 99)
        assert.equal("broken", state)
        assert.equal("reported", reason)
        assert.is_true(Tel.Restore(99))
        assert.is_nil(K.cdb.brokenQuests[99])
        assert.is_false(Tel.Restore(99))
    end)

    it("formats a record on one line", function()
        local r = Tel.Record("not-offered", step)
        local line = Tel.Format(r)
        assert.truthy(line:find("q99 A Lost Orders npc 500 map 1413 50.0,50.0 L12 not-offered x1", 1, true))
    end)

    it("/klimax report prints, clears and restores", function()
        local printed = {}
        K.Print = function(text) printed[#printed + 1] = text end
        Tel.Command("")
        assert.truthy(printed[1]:find("nothing to report", 1, true))
        Tel.Record("dwell", step)
        printed = {}
        Tel.Command("")
        assert.equal(2, #printed)
        Tel.Command("clear")
        assert.are.same({}, K.db.reports)
    end)
end)

describe("the planner moves on", function()
    it("a hidden quest is never planned", function()
        local Ca = K.Plan.Candidates
        local snap = { level = 12, mapID = 1, x = 50, y = 50, log = {} }
        local world = {
            zoneIds = function() return { 1 } end,
            zoneInfo = function() return { lv = { 10, 12, 14 } } end,
            zoneQuests = function() return { 99 } end,
            quest = function() return { n = "Lost Orders", lv = 12, rl = 10, xp = 500, sn = { 5 }, en = { 5 } } end,
            questZone = function() return 1 end,
            npcPoints = function() return { { 1, 50, 50 } } end,
            objectPoints = function() return nil end,
            travel = { adj = {}, links = {}, nodes = {}, cost = {} },
        }
        local function pool(broken)
            local s = { broken = broken, log = {}, completed = {}, level = 12 }
            local ctx = K.Reconciler.New(s, { info = function() return { rl = 10 } end })
            return Ca.Build(world, function(q) return K.Reconciler.State(ctx, q) end, snap, K.Plan.Weights.For())
        end
        assert.equal(1, #pool({}))
        assert.equal(0, #pool({ [99] = true }))
    end)
end)
