-- Phase 18 diagnostics: game-state rules, the engine-versus-game comparison, the raw quest log
-- reader, /klimax dump, /klimax audit state, mark provenance, the engine flag and the fixture
-- loader. These specs pass; the known-failing behaviour lives in known_failing_spec.lua.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local Fx = require("fixture")

local function demoRoute()
    return { id = "diag_a", faction = "horde", branch = "horde", lo = 1, hi = 5, steps = {
        { t = "A", k = "A1", q = 1, n = "One", g = "m", z = 1, x = 10, y = 10, npc = 50 },
        { t = "A", k = "A2", q = 2, n = "Two", g = "m", z = 1, x = 10, y = 10, npc = 50 },
        { t = "C", k = "C1", q = 1, n = "One", g = "m", z = 1, x = 20, y = 20 },
        { t = "T", k = "T1", q = 1, n = "One", g = "m", z = 1, x = 10, y = 10, npc = 50 },
        { t = "C", k = "C2", q = 2, n = "Two", g = "m", z = 1, x = 20, y = 20 },
        { t = "T", k = "T2", q = 2, n = "Two", g = "m", z = 1, x = 10, y = 10, npc = 50 },
        { t = "B", k = "B1", z = 1, x = 30, y = 30, note = "buy" },
    } }
end

local function startDemo(opts)
    local K = W.start(W.merge({ skipRoutes = true }, opts))
    W.registerRoute(demoRoute())
    K.Detect()
    assert(K.Engine:Load("diag_a"))
    K.cdb.routeId = "diag_a"
    return K
end

local function kinds(list)
    local out = {}
    for _, d in ipairs(list) do
        out[d.k] = d.kind
    end
    return out
end

describe("game state rules", function()
    local D

    before_each(function()
        D = W.start({ skipRoutes = true }).Diag
    end)

    it("reads completed, failed, objectives done, active, absent and unknown", function()
        local log = { [2] = { complete = true }, [3] = { complete = false }, [4] = { failed = true } }
        assert.are.equal("completed", D.GameState(1, log, { [1] = true }, true))
        assert.are.equal("objectives-done", D.GameState(2, log, {}, true))
        assert.are.equal("active", D.GameState(3, log, {}, true))
        assert.are.equal("failed", D.GameState(4, log, {}, true))
        assert.are.equal("absent", D.GameState(5, log, {}, true))
        assert.are.equal("unknown", D.GameState(5, log, {}, false))
    end)

    it("classifies every disagreement kind and stays quiet when the game is unknown", function()
        assert.are.equal("done-not-accepted", D.Classify({ t = "A" }, "done", "absent", true))
        assert.are.equal("done-not-complete", D.Classify({ t = "C" }, "done", "active", true))
        assert.are.equal("done-not-turned-in", D.Classify({ t = "T" }, "done", "objectives-done", true))
        assert.are.equal("stale-turnin", D.Classify({ t = "T" }, "pending", "completed", true))
        assert.are.equal("stale-step", D.Classify({ t = "A" }, "pending", "completed", true))
        assert.are.equal("pending-failed", D.Classify({ t = "T" }, "pending", "failed", true))
        assert.are.equal("turnin-not-in-log", D.Classify({ t = "T" }, "pending", "absent", true))
        assert.are.equal("complete-not-in-log", D.Classify({ t = "C" }, "pending", "absent", true))
        assert.are.equal("archived-in-log", D.Classify({ t = "T" }, "archived", "active", true))
        assert.is_nil(D.Classify({ t = "T" }, "pending", "absent", false))   -- not accepted yet
        assert.is_nil(D.Classify({ t = "A" }, "done", "active", true))
        assert.is_nil(D.Classify({ t = "T" }, "done", "completed", true))
        assert.is_nil(D.Classify({ t = "T" }, "done", "unknown", true))
    end)

    it("compares a step list with the game, in step order", function()
        local steps = demoRoute().steps
        local eff = { "done", "done", "done", "pending", "pending", "pending", "pending" }
        local log = { [1] = { complete = false } }
        local list = D.Disagreements(steps, eff, log, {}, true)
        local k = kinds(list)
        assert.are.equal("done-not-complete", k.C1)       -- marked done, objectives not done
        assert.are.equal("done-not-accepted", k.A2)       -- quest 2 is not in the log
        assert.are.equal("complete-not-in-log", k.C2)
        assert.are.equal("turnin-not-in-log", k.T2)
        assert.is_nil(k.T1)                               -- quest 1 is active: its turn-in is fine
        assert.are.equal("A2", list[1].k)
        assert.is_nil(list[1].uncertain)
        local hiddenList = D.Disagreements(steps, eff, log, {}, true, 1)
        assert.is_true(hiddenList[1].uncertain)
    end)
end)

describe("raw quest log reader", function()
    for _, legacy in ipairs({ true, false }) do
        it("reads headers, collapsed quests, failed flags and objectives (legacy=" .. tostring(legacy) .. ")", function()
            local K = W.start({ skipRoutes = true, legacy = legacy })
            W.state.logList = {
                { isHeader = true, title = "Durotar" },
                { questID = 10, title = "Ten", level = 5, isComplete = 1,
                    objectives = { { text = "Boars: 4/4", type = "monster", finished = true,
                        numFulfilled = 4, numRequired = 4 } } },
                { questID = 11, title = "Eleven", level = 6, isComplete = -1 },
                { isHeader = true, title = "Mulgore", isCollapsed = true },
                { questID = 12, title = "Twelve", level = 7 },
            }
            local lines, numQuests = K.Compat.GetQuestLogLines(true)
            assert.are.equal(4, #lines)        -- quest 12 is hidden by its collapsed header
            assert.are.equal(3, numQuests)
            assert.is_true(lines[1].header)
            assert.are.equal("Boars: 4/4", lines[2].objectives[1].text)
            assert.is_true(lines[2].objectives[1].finished)
            local log, _, _, hidden = K.Diag.ReadLog()
            assert.is_true(log[10].complete)
            assert.is_true(log[11].failed)
            assert.is_false(log[11].complete)
            assert.is_nil(log[12])
            assert.are.equal(1, hidden)
        end)
    end

    it("names the completed-quest API the client offers", function()
        local K = W.start({ skipRoutes = true })
        assert.are.equal("C_QuestLog", K.Compat.CompletedApiKind())
        K = W.start({ skipRoutes = true, legacy = true })
        assert.are.equal("global", K.Compat.CompletedApiKind())
        W.unset("IsQuestFlaggedCompleted")
        assert.are.equal("set", K.Compat.CompletedApiKind())
        W.unset("GetQuestsCompleted")
        assert.is_nil(K.Compat.CompletedApiKind())
    end)
end)

describe("/klimax dump", function()
    it("stores a snapshot of the character under Name-Realm", function()
        local K = startDemo()
        W.registerIndex({ routes = {}, start = {}, quests = { [1] = { "diag_a" }, [2] = { "diag_a" } } })
        W.state.names.player = "Tester"
        W.state.level, W.state.xp, W.state.xpMax = 3, 120, 900
        W.state.mapID, W.state.pos = 1411, { x = 0.42, y = 0.61 }
        W.state.completed[1] = true
        W.setQuestLog(2, false)
        K.Engine:MarkDone(1)   -- the A1/A2 batch
        K.Command("dump")
        local snap = K.db.dumps["Tester-Forever"]
        assert.is_table(snap)
        assert.are.equal(1, snap.schema)
        assert.are.equal("legacy", snap.engineMode)
        assert.are.equal(3, snap.player.level)
        assert.are.equal(120, snap.player.xp)
        assert.are.equal("WARRIOR", snap.player.class)
        assert.are.equal(1411, snap.position.mapID)
        assert.are.equal(0.42, snap.position.x)
        assert.are.equal("C_QuestLog", snap.api.completed)
        assert.are.same({ 1 }, snap.completed)
        assert.are.equal(2, snap.questLog[1].questID)
        assert.are.equal("diag_a", snap.engine.routeId)
        assert.are.equal("done", snap.engine.stepState.diag_a.A2)
        assert.are.equal("next-batch", snap.engine.markLog[2].src)
        assert.is_table(snap.disagreements)
        assert.is_table(snap.debugLog)
        assert.truthy(W.printed[#W.printed]:find("Tester-Forever", 1, true))
    end)

    it("has the top-level keys the offline converter reads", function()
        local K = startDemo()
        local snap = K.Diag.Snapshot()
        for _, key in ipairs({ "schema", "addon", "engineMode", "player", "position", "api", "questLog",
            "completed", "completedKnown", "engine", "disagreements" }) do
            assert.is_not_nil(snap[key], key)
        end
    end)
end)

describe("/klimax audit state", function()
    it("lists each disagreement with step key, quest, game state and engine state", function()
        local K = startDemo()
        W.setQuestLog(1, false)
        K.Engine:MarkDone(1)        -- marks A1 and A2: quest 2 was never accepted
        W.printed = {}
        K.Command("audit state")
        local text = table.concat(W.printed, "\n")
        assert.truthy(text:find("disagreement", 1, true))
        assert.truthy(text:find("A2 (quest 2): game absent, guide done", 1, true))
    end)

    it("says so when the guide agrees with the game", function()
        local K = startDemo()
        W.printed = {}
        K.Command("audit state")
        assert.truthy(W.printed[#W.printed]:find("agrees", 1, true))
    end)

    it("warns when the client has no completed-quest API", function()
        local K = startDemo({ legacy = true })
        W.unset("IsQuestFlaggedCompleted")
        W.unset("GetQuestsCompleted")
        W.printed = {}
        K.Command("audit state")
        assert.truthy(table.concat(W.printed, "\n"):find("no completed-quest API", 1, true))
    end)
end)

describe("mark provenance", function()
    it("records the source and the game state of every stored step state", function()
        local K = startDemo()
        W.setQuestLog(1, false)
        K.Engine:MarkDone(1)
        W.fire("QUEST_TURNED_IN", 1)
        W.fire("MERCHANT_CLOSED")
        local srcs = {}
        for _, m in ipairs(K.cdb.markLog) do
            srcs[m.k] = m.src
        end
        assert.are.equal("next", srcs.A1)
        assert.are.equal("next-batch", srcs.A2)
        assert.are.equal("turnedin-event", srcs.T1)
        assert.are.equal("absent", K.cdb.markLog[2].g)
    end)

    it("keeps at most MARKLOG_MAX entries", function()
        local K = startDemo()
        K.Diag.MARKLOG_MAX = 3
        for _ = 1, 5 do
            K.Diag.NoteMark("test", { k = "X", t = "N" }, "done")
        end
        assert.are.equal(3, #K.cdb.markLog)
    end)
end)

describe("engine flag", function()
    it("defaults to the legacy engine and ignores unknown names", function()
        local K = W.start({ skipRoutes = true })
        assert.are.equal("legacy", K.EngineMode())
        K.db.options.engine = "nope"
        assert.are.equal("legacy", K.EngineMode())
        assert.are.equal(K.Engine, K.engines.legacy)
    end)

    it("selects a registered engine; the legacy engine then does not start at login", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "horde_durotar_01-05", branch = "durotar", lo = 1, hi = 5, steps = {} })
        local started = false
        K.engines.next = { Start = function() started = true end }
        K.Command("engine next")
        assert.are.equal("next", K.db.options.engine)
        assert.are.equal("next", K.EngineMode())
        W.fire("PLAYER_LOGIN")
        assert.is_nil(K.Engine.routeId)
        assert.is_false(started)   -- a future engine wires its own login; nothing else starts
        K.Command("engine legacy")
        W.fire("PLAYER_LOGIN")
        assert.are.equal("horde_durotar_01-05", K.Engine.routeId)
    end)

    it("prints the current engine and rejects unknown ones", function()
        local K = W.start({ skipRoutes = true })
        K.Command("engine")
        assert.truthy(W.printed[#W.printed]:find("Engine: legacy", 1, true))
        K.Command("engine bogus")
        assert.truthy(W.printed[#W.printed]:find("Unknown engine bogus", 1, true))
        assert.is_nil(K.db.options.engine)
    end)
end)

describe("fixture loader", function()
    it("installs the player, the quest log and the saved state, then replays login", function()
        local fx = Fx.load("hunter15_synthetic")
        assert.is_true(fx.synthetic)
        local K = Fx.start(fx)
        assert.are.equal("HUNTER", K.player.class)
        assert.are.equal(15, K.player.level)
        assert.are.equal("horde_horde_10-15", K.Engine.routeId)
        local log, _, numQuests, hidden = K.Diag.ReadLog()
        assert.are.equal(4, numQuests)
        assert.are.equal(1, hidden)        -- 751 sits under the collapsed Mulgore header
        assert.is_nil(log[751])
        assert.is_true(log[853].failed)
        assert.is_true(K.Compat.IsQuestCompleted(870))
        assert.are.equal("done", Fx.stateOf(K, "horde_horde_10-15:T:845:0"))
    end)
end)
