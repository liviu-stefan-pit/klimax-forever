-- Diagnostics: the raw quest log reader, /klimax dump and the fixture loader. The phase 18 known
-- failures are replayed on the plan engine in hunter_replay_spec.lua.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local Fx = require("fixture")

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
            -- Phase 20: the full read expands the collapsed header, reads quest 12 and collapses
            -- the header again.
            local log, _, _, hidden = K.Diag.ReadLog()
            assert.is_true(log[10].complete)
            assert.is_true(log[11].failed)
            assert.is_false(log[11].complete)
            assert.is_table(log[12])
            assert.are.equal(0, hidden)
            assert.is_true(W.state.logList[4].isCollapsed)
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
    local function started()
        local K = W.start({ skipRoutes = true })
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        return K
    end

    it("stores a snapshot of the character under Name-Realm", function()
        local K = started()
        W.state.names.player = "Tester"
        W.state.level, W.state.xp, W.state.xpMax = 3, 120, 900
        W.state.mapID, W.state.pos = 1411, { x = 0.42, y = 0.61 }
        W.state.completed[1] = true
        W.setQuestLog(2, false)
        K.cdb.skipQuests[77] = true
        K.Command("dump")
        local snap = K.db.dumps["Tester-Forever"]
        assert.is_table(snap)
        assert.are.equal(1, snap.schema)
        assert.are.equal("planner", snap.engineMode)
        assert.are.equal(3, snap.player.level)
        assert.are.equal(120, snap.player.xp)
        assert.are.equal("WARRIOR", snap.player.class)
        assert.are.equal(1411, snap.position.mapID)
        assert.are.equal(0.42, snap.position.x)
        assert.are.equal("C_QuestLog", snap.api.completed)
        assert.are.equal(2, snap.questLog[1].questID)
        assert.is_true(snap.engine.skipQuests[77])
        assert.is_table(snap.engine.plan)
        assert.is_table(snap.debugLog)
        assert.truthy(W.printed[#W.printed]:find("Tester-Forever", 1, true))
    end)

    it("has the top-level keys the offline converter reads", function()
        local K = started()
        local snap = K.Diag.Snapshot()
        for _, key in ipairs({ "schema", "addon", "engineMode", "player", "position", "api", "questLog",
            "completed", "completedKnown", "engine", "disagreements" }) do
            assert.is_not_nil(snap[key], key)
        end
    end)
end)

describe("fixture loader", function()
    it("installs the player, the quest log and the saved choices, then replays login", function()
        local fx = Fx.load("hunter15_synthetic")
        assert.is_true(fx.synthetic)
        local K = Fx.start(fx)
        assert.are.equal("HUNTER", K.player.class)
        assert.are.equal(15, K.player.level)
        assert.are.equal("plan", K.Engine.routeId)
        local log, _, numQuests, hidden = K.Diag.ReadLog()
        assert.are.equal(4, numQuests)
        assert.are.equal(0, hidden)        -- 751 sits under the collapsed Mulgore header; read anyway
        assert.is_true(log[751].complete)
        assert.is_true(log[853].failed)
        assert.is_true(K.Compat.IsQuestCompleted(870))
    end)
end)
