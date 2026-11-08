-- Phase 29: the step engine over the planner. It shows the plan's steps, hides what the player hides,
-- keeps the choices by stable key, and follows the game through K.State. The planner itself is
-- tested in planner_spec.lua; here it is replaced by a fixed plan (W.showSteps) or run for real on the
-- compiled world.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K

local function accept(q, extra)
    local s = { t = "A", k = "plan:A:" .. q, q = q, n = "Quest " .. q, z = 1413, x = 10, y = 10, npc = q }
    for k, v in pairs(extra or {}) do
        s[k] = v
    end
    return s
end

local function started(steps)
    K = W.start({ skipRoutes = true })
    K.Detect()
    return W.showSteps(K, steps)
end

describe("steps and cursor", function()
    it("shows the plan in order, all pending, cursor on the first", function()
        local E = started({ accept(1), accept(2), accept(3) })
        assert.equal("plan", E.routeId)
        assert.equal(3, #E.steps)
        assert.equal(1, E.cursor)
        assert.equal("pending", E.eff[2])
        assert.equal(2, E.byKey["plan:A:2"])
        local i, step, state = E:Current()
        assert.equal(1, i)
        assert.equal(1, step.q)
        assert.equal("pending", state)
    end)

    it("an empty plan has no cursor", function()
        local E = started({})
        assert.is_nil(E.cursor)
        assert.is_nil(E:Current())
    end)

    it("groups consecutive accepts at one NPC into a hub batch", function()
        local E = started({ accept(1, { npc = 9 }), accept(2, { npc = 9 }), accept(3, { npc = 8 }),
            { t = "T", k = "plan:T:1", q = 1, z = 1413, x = 10, y = 10, npc = 9 } })
        assert.are.same({ 1, 2 }, E:Batch(2))
        assert.are.same({ 3 }, E:Batch(3))
        assert.are.same({ 4 }, E:Batch(4))
    end)

    it("adds a note from the planner's why and a name to travel steps", function()
        local E = started({ { t = "V", k = "plan:V:1413:1", to = 1413, z = 1411, x = 50, y = 50, why = { via = "flight" } },
            accept(1, { why = { xp = 700 } }) })
        assert.truthy(E.steps[1].n:find("Barrens", 1, true))
        assert.truthy(E.steps[1].note:find("another zone", 1, true))
        assert.truthy(E.steps[2].note:find("700 XP", 1, true))
    end)

    it("notifies observers when the plan changes", function()
        local E = started({ accept(1) })
        local n = 0
        E:OnChange(function() n = n + 1 end)
        E:Recompute()
        assert.equal(1, n)
    end)
end)

describe("player choices", function()
    it("Mark done hides the step and its hub batch; Unskip brings it back", function()
        local E = started({ accept(1, { npc = 9 }), accept(2, { npc = 9 }), accept(3) })
        assert.equal(2, E:MarkDone(1))
        assert.equal(1, #E.steps)
        assert.is_true(K.cdb.hiddenSteps["plan:A:1"])
        assert.is_true(E:Unskip("plan:A:2"))
        assert.equal(2, #E.steps)
        assert.is_false(E:Unskip("plan:A:404"))
    end)

    it("Skip hides one step and cascades nothing", function()
        local E = started({ accept(1), accept(2) })
        assert.equal(0, E:Skip(1))
        assert.equal(1, #E.steps)
        assert.equal(2, E.steps[1].q)
    end)

    it("Skip quest and Restore quest round-trip, and clear hidden steps of that quest", function()
        local E = started({ accept(1), accept(2) })
        assert.is_true(E:SkipQuest(1))
        assert.is_true(E.QuestSkipped(1))
        E:Skip(1)
        assert.is_true(E:RestoreQuest(1))
        assert.is_false(E.QuestSkipped(1))
        assert.is_nil(K.cdb.hiddenSteps["plan:A:1"])
        assert.is_false(E:SkipQuest(nil))
    end)

    it("Pin stores the quest, Pin(nil) clears it", function()
        local E = started({ accept(1), accept(2) })
        assert.is_true(E:Pin("plan:A:2"))
        assert.equal(2, K.cdb.pin.q)
        assert.is_false(E:Pin(nil))
        assert.is_nil(K.cdb.pin)
    end)

    it("Reset: band clears hidden steps and the pin, guide also the reports, all also the skips", function()
        local E = started({ accept(1) })
        K.cdb.skipQuests[5] = true
        K.cdb.brokenQuests[6] = true
        K.cdb.hiddenSteps["x"] = true
        K.cdb.pin = { q = 1 }
        E:Reset("band")
        assert.is_nil(K.cdb.hiddenSteps["x"])
        assert.is_nil(K.cdb.pin)
        assert.is_true(K.cdb.brokenQuests[6])
        E:Reset("guide")
        assert.is_nil(K.cdb.brokenQuests[6])
        assert.is_true(K.cdb.skipQuests[5])
        E:Reset("all")
        assert.is_nil(K.cdb.skipQuests[5])
    end)
end)

describe("Contradicts", function()
    it("is false before the state is ready or for steps without a quest", function()
        K = W.start({ skipRoutes = true })
        assert.is_false(K.Engine.Contradicts(accept(1)))
        assert.is_false(K.Engine.Contradicts({ t = "S", k = "svc:x" }))
    end)

    it("an accept is contradicted until the quest is in the log, a hand-in until it is completed", function()
        K = W.start({ skipRoutes = true })
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        local E = K.Engine
        assert.is_true(E.Contradicts(accept(788)))
        W.setQuestLog(788, false)
        K.State:Refresh()
        assert.is_false(E.Contradicts(accept(788)))
        assert.is_true(E.Contradicts({ t = "C", k = "c", q = 788 }))
        assert.is_true(E.Contradicts({ t = "T", k = "t", q = 788 }))
        W.setQuestLog(788, true)
        K.State:Refresh()
        assert.is_false(E.Contradicts({ t = "C", k = "c", q = 788 }))
    end)
end)

describe("start branch", function()
    it("follows the race, and Zephra's Isle wins on the isle or after its quests", function()
        K = W.start({ skipRoutes = true })
        assert.equal("durotar", K.Engine.BranchFor("Orc"))
        assert.equal("durotar", K.Engine.BranchFor("Troll"))
        assert.equal("mulgore", K.Engine.BranchFor("Tauren"))
        assert.equal("tirisfal", K.Engine.BranchFor("Scourge"))
        assert.is_nil(K.Engine.BranchFor("Human"))
        assert.equal("durotar", K.Engine.BranchForPlayer({ race = "Orc" }))
        W.state.mapID = 2521
        assert.equal("zephras", K.Engine.BranchForPlayer({ race = "Orc" }))
    end)
end)

describe("the real plan", function()
    it("starts at login, builds the plan from the game state and follows level-ups", function()
        K = W.start({ skipRoutes = true })
        W.state.level, W.state.mapID, W.state.pos = 2, 1411, { x = 0.42, y = 0.68 }
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        assert.equal("plan", K.Engine.routeId)
        assert.is_true(#K.Engine.steps > 0)
        local before = K.Engine.steps[1].k
        assert.is_string(before)
        W.state.level = 8
        W.fire("PLAYER_LEVEL_UP", 8)
        assert.equal(8, K.player.level)
        assert.is_true(#K.Engine.steps > 0)
    end)

    it("a turn-in in the game takes the quest out of the plan on the next refresh", function()
        K = W.start({ skipRoutes = true })
        W.state.level, W.state.mapID, W.state.pos = 2, 1411, { x = 0.42, y = 0.68 }
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        assert.is_not_nil(K.Engine.byKey["plan:A:788"])
        W.state.completed[788] = true
        W.fire("QUEST_TURNED_IN", 788, 0, 0)
        W.flushTimers()
        assert.is_nil(K.Engine.byKey["plan:A:788"])
    end)
end)
