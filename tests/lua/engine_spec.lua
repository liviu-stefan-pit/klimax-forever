-- Engine, sync, detection and compat specs for the Klimax add-on core (phase 06).
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

-- A synthetic route in the compiled shape (k, t, q, n, g, z, x, y, npc, pa, po, cl, ml, to).
local function demoSteps()
    return {
        { t = "A", k = "A101", q = 101, n = "One", g = "m", z = 1, x = 10, y = 10, npc = 500 },
        { t = "A", k = "A102", q = 102, n = "Two", g = "m", z = 1, x = 10, y = 10, npc = 500 },
        { t = "C", k = "C101", q = 101, n = "One", g = "m", z = 1, x = 20, y = 20 },
        { t = "T", k = "T101", q = 101, n = "One", g = "m", z = 1, x = 10, y = 10, npc = 500 },
        { t = "A", k = "A103", q = 103, n = "Three", g = "m", z = 1, x = 10, y = 10, npc = 501, pa = { 101 } },
        { t = "C", k = "C103", q = 103, n = "Three", g = "m", z = 1, x = 30, y = 30 },
        { t = "T", k = "T103", q = 103, n = "Three", g = "m", z = 1, x = 10, y = 10, npc = 501 },
        { t = "A", k = "A104", q = 104, n = "Hunter only", g = "o", z = 1, x = 40, y = 40, npc = 502, cl = { "HUNTER" } },
        { t = "A", k = "A105", q = 105, n = "Any-of", g = "m", z = 1, x = 50, y = 50, npc = 503, po = { 106 } },
        { t = "V", k = "V1", z = 1, x = 50, y = 50, note = "walk" },
        { t = "B", k = "B1", z = 1, x = 60, y = 60, note = "buy" },
        { t = "D", k = "D1", z = 1, x = 60, y = 60, to = "Orgrimmar" },
        { t = "H", k = "H1", z = 1, x = 60, y = 60, to = "Razor Hill" },
    }
end

local function registerDemo(id)
    W.registerRoute({ id = id or "demo_a", faction = "horde", branch = "horde", lo = 1, hi = 5, steps = demoSteps() })
end

local function loadDemo(id)
    local K = W.K
    K.Detect()
    local ok, err = K.Engine:Load(id or "demo_a")
    assert.is_true(ok, err)
    return K
end

local function keyOf(K, index)
    return K.Engine.steps[index].k
end

describe("filtering", function()
    it("keeps class-limited steps only for that class", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        W.state.class = "WARRIOR"
        loadDemo()
        assert.is_nil(K.Engine.byKey["A104"])
        W.state.class = "HUNTER"
        loadDemo()
        assert.is_not_nil(K.Engine.byKey["A104"])
    end)

    it("keeps race-limited steps only for that race", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "race_route", lo = 1, hi = 5, branch = "horde", steps = {
            { t = "A", k = "R1", q = 1, z = 1, x = 1, y = 1, npc = 1, ra = { "Troll" } },
            { t = "A", k = "R2", q = 2, z = 1, x = 1, y = 1, npc = 1 },
        } })
        W.state.race = "Orc"
        W.state.raceToken = "Orc"
        loadDemo("race_route")
        assert.equals(1, #K.Engine.steps)
        assert.equals("R2", K.Engine.steps[1].k)
    end)
end)

describe("cursor and batches", function()
    it("Next marks the whole ACCEPT batch at the hub and moves on", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        local i = K.Engine:Current()
        assert.equals(1, i)
        assert.same({ 1, 2 }, K.Engine:Batch(1))
        assert.equals(2, K.Engine:Next())
        assert.equals("C101", keyOf(K, K.Engine.cursor))
    end)

    it("groups only consecutive ACCEPT steps with the same NPC and zone", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        assert.same({ 5 }, K.Engine:Batch(5))
        assert.same({ 3 }, K.Engine:Batch(3))
    end)
end)

describe("skip, unskip and cascade", function()
    it("skipping an ACCEPT cascades its COMPLETE/TURNIN and the chain ACCEPT whose prerequisite died", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        local dependents = K.Engine:Skip(1)
        -- C101, T101 (same quest) and A103, C103, T103 (prerequisite 101 is unreachable)
        assert.equals(5, dependents)
        assert.equals("A102", keyOf(K, K.Engine.cursor))
        assert.equals("cascade", K.Engine.eff[K.Engine.byKey["A103"]])
        assert.equals("cascade", K.Engine.eff[K.Engine.byKey["T103"]])
    end)

    it("skipping a COMPLETE cascades only the later TURNIN of that quest", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        assert.equals(1, K.Engine:Skip(K.Engine.byKey["C103"]))
        assert.equals("cascade", K.Engine.eff[K.Engine.byKey["T103"]])
        assert.equals("pending", K.Engine.eff[K.Engine.byKey["A103"]])
    end)

    it("an any-of prerequisite blocks a chain only when every option is unreachable", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "any_of", lo = 1, hi = 5, branch = "horde", steps = {
            { t = "A", k = "P1", q = 200, z = 1, x = 1, y = 1, npc = 1 },
            { t = "A", k = "P2", q = 201, z = 1, x = 1, y = 1, npc = 2 },
            { t = "A", k = "Q1", q = 202, z = 1, x = 1, y = 1, npc = 3, po = { 200, 201 } },
            { t = "C", k = "Q2", q = 202, z = 1, x = 1, y = 1 },
        } })
        loadDemo("any_of")
        assert.equals(0, K.Engine:Skip(K.Engine.byKey["P1"]))
        assert.equals(2, K.Engine:Skip(K.Engine.byKey["P2"]))
        assert.equals("cascade", K.Engine.eff[K.Engine.byKey["Q1"]])
        assert.equals("cascade", K.Engine.eff[K.Engine.byKey["Q2"]])
    end)

    it("unskipping restores the cascaded steps and the cursor", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        K.Engine:Skip(1)
        assert.is_true(K.Engine:Unskip("A101"))
        assert.equals("pending", K.Engine.eff[K.Engine.byKey["C101"]])
        assert.equals("pending", K.Engine.eff[K.Engine.byKey["A103"]])
        assert.equals("A101", keyOf(K, K.Engine.cursor))
    end)

    it("unskip of a key that is not skipped does nothing", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        assert.is_false(K.Engine:Unskip("A101"))
    end)
end)

describe("reset", function()
    it("band reset clears the loaded route only; all clears every route", function()
        local K = W.start({ skipRoutes = true })
        registerDemo("demo_a")
        registerDemo("demo_b")
        loadDemo("demo_b")
        K.Engine:Next()
        loadDemo("demo_a")
        K.Engine:Next()
        K.Engine:Reset("band")
        assert.equals("pending", K.Engine.eff[1])
        assert.equals("done", K.cdb.stepState["demo_b"]["A101"])
        K.Engine:Reset("all")
        assert.is_nil(K.cdb.stepState["demo_b"])
        assert.equals(1, K.Engine.cursor)
    end)
end)

describe("auto-advance on events", function()
    it("QUEST_ACCEPTED (classic index, questID) completes the ACCEPT", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        W.fire("QUEST_ACCEPTED", 3, 101)
        assert.equals("done", K.Engine.eff[K.Engine.byKey["A101"]])
        assert.equals("pending", K.Engine.eff[K.Engine.byKey["A102"]])
    end)

    it("QUEST_TURNED_IN completes every step of that quest", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        W.fire("QUEST_TURNED_IN", 101, 0, 0)
        assert.equals("done", K.Engine.eff[K.Engine.byKey["C101"]])
        assert.equals("done", K.Engine.eff[K.Engine.byKey["T101"]])
    end)

    it("QUEST_LOG_UPDATE is throttled and checks the quest log", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        W.setQuestLog(102, false)
        W.setQuestLog(103, true)
        W.fire("QUEST_LOG_UPDATE")
        W.fire("QUEST_LOG_UPDATE")
        assert.equals(2, #W.timers)   -- one engine log check and one state refresh (phase 20)
        assert.equals("pending", K.Engine.eff[K.Engine.byKey["A102"]])
        W.flushTimers()
        assert.equals("done", K.Engine.eff[K.Engine.byKey["A102"]])
        assert.equals("done", K.Engine.eff[K.Engine.byKey["A103"]])
        assert.equals("done", K.Engine.eff[K.Engine.byKey["C103"]])
        assert.equals("pending", K.Engine.eff[K.Engine.byKey["T103"]])
    end)

    it("PLAYER_LEVEL_UP updates the level and un-gates a step", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "gated", lo = 1, hi = 5, branch = "horde", steps = {
            { t = "A", k = "G1", q = 300, z = 1, x = 1, y = 1, npc = 1, ml = 10 },
            { t = "A", k = "G2", q = 301, z = 1, x = 1, y = 1, npc = 2 },
        } })
        loadDemo("gated")
        assert.equals("G2", keyOf(K, K.Engine.cursor))
        W.fire("PLAYER_LEVEL_UP", 10)
        assert.equals(10, K.player.level)
        assert.equals("G1", keyOf(K, K.Engine.cursor))
    end)

    it("a travel step completes when the player is close to its point on the same map", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "travel", lo = 1, hi = 5, branch = "horde", steps = {
            { t = "V", k = "V1", z = 1, x = 50, y = 50 },
            { t = "A", k = "A1", q = 1, z = 1, x = 1, y = 1, npc = 1 },
        } })
        loadDemo("travel")
        assert.is_false(K.Engine:CheckPositionAt(2, 50, 50))
        assert.is_false(K.Engine:CheckPositionAt(1, 60, 60))
        W.state.pos = { x = 0.52, y = 0.49 }
        W.fire("ZONE_CHANGED_NEW_AREA")
        assert.equals("done", K.Engine.eff[1])
        assert.equals("A1", keyOf(K, K.Engine.cursor))
    end)

    it("taxi discovery completes a flight step for a known node, not an unknown one", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        W.state.taxi = { { name = "Ratchet", kind = "NONE" } }
        W.fire("TAXIMAP_OPENED")
        assert.equals("pending", K.Engine.eff[K.Engine.byKey["D1"]])
        W.state.taxi = { { name = "Orgrimmar", kind = "REACHABLE" } }
        W.fire("TAXIMAP_OPENED")
        assert.equals("done", K.Engine.eff[K.Engine.byKey["D1"]])
    end)

    it("logistics steps complete on their game events", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "logistics", lo = 1, hi = 5, branch = "horde", steps = {
            { t = "H", k = "H1", z = 1, x = 1, y = 1, to = "Razor Hill" },
            { t = "U", k = "U1", z = 1, x = 1, y = 1 },
            { t = "R", k = "R1", z = 1, x = 1, y = 1 },
            { t = "B", k = "B1", z = 1, x = 1, y = 1 },
            { t = "P", k = "P1", z = 1, x = 1, y = 1 },
        } })
        loadDemo("logistics")
        W.fire("CONFIRM_BINDER")
        W.flushTimers()
        assert.equals("U1", keyOf(K, K.Engine.cursor))
        W.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 8690)
        assert.equals("R1", keyOf(K, K.Engine.cursor))
        W.fire("TRAINER_SHOW")
        W.fire("TRAINER_CLOSED")
        assert.equals("B1", keyOf(K, K.Engine.cursor))
        W.fire("MERCHANT_CLOSED")
        assert.equals("P1", keyOf(K, K.Engine.cursor))
        W.fire("MERCHANT_CLOSED")
        assert.is_nil(K.Engine.cursor)
    end)
end)

describe("persistence by stable key", function()
    it("progress survives a route whose steps were reordered", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        K.Engine:Next()
        local reversed = demoSteps()
        local n = #reversed
        for i = 1, math.floor(n / 2) do
            reversed[i], reversed[n - i + 1] = reversed[n - i + 1], reversed[i]
        end
        W.registerRoute({ id = "demo_a", lo = 1, hi = 5, branch = "horde", steps = reversed })
        loadDemo()
        assert.equals("done", K.Engine.eff[K.Engine.byKey["A101"]])
        assert.equals("done", K.Engine.eff[K.Engine.byKey["A102"]])
        assert.equals("H1", keyOf(K, K.Engine.cursor))
    end)
end)

describe("sync from completed quests", function()
    local function syncSetup(opts)
        local K = W.start(W.merge(opts, { skipRoutes = true }))
        registerDemo()
        local ids = {}
        for id = 1, 450 do
            ids[id] = { "demo_a" }
        end
        W.registerIndex({ routes = {}, start = {}, quests = ids })
        W.state.completed = { [101] = true, [103] = true }
        loadDemo()
        return K
    end

    it("marks completed steps done across several frame slices, then places the cursor", function()
        local K = syncSetup()
        local calls = 0
        local marked
        K.Sync:Run(function(_, m)
            calls = calls + 1
            marked = m
        end)
        W.flushTimers()
        assert.equals(1, calls)
        assert.equals(6, marked)
        assert.equals("done", K.Engine.eff[K.Engine.byKey["C101"]])
        assert.equals("A102", keyOf(K, K.Engine.cursor))
    end)

    it("uses GetQuestsCompleted when IsQuestFlaggedCompleted is missing (legacy client)", function()
        local K = syncSetup({ legacy = true })
        W.unset("IsQuestFlaggedCompleted")
        assert.is_false(K.Compat.HasFlaggedCompletedApi())
        local marked
        K.Sync:Run(function(_, m)
            marked = m
        end)
        W.flushTimers()
        assert.equals(6, marked)
    end)

    it("never overwrites a step the player skipped", function()
        local K = syncSetup()
        K.Engine:Skip(K.Engine.byKey["A103"])
        K.Sync:Run()
        W.flushTimers()
        assert.equals("skipped", K.cdb.stepState["demo_a"]["A103"])
    end)
end)

describe("route choice", function()
    local function register(id, branch, lo, hi)
        W.registerRoute({ id = id, branch = branch, lo = lo, hi = hi, steps = {
            { t = "A", k = id .. "A", q = 1, z = 1, x = 1, y = 1, npc = 1 },
        } })
    end

    local function choose(race, level, faction)
        W.state.race = race
        W.state.raceToken = race
        W.state.level = level
        W.state.faction = faction or "Horde"
        local K = W.K
        K.Detect()
        return K.Engine.ChooseRoute(K.player)
    end

    before_each(function()
        W.start({ skipRoutes = true })
        register("horde_durotar_01-05", "durotar", 1, 5)
        register("horde_durotar_05-10", "durotar", 5, 10)
        register("horde_tirisfal_10-15", "tirisfal", 10, 15)
        register("horde_horde_10-15", "horde", 10, 15)
        register("horde_horde_15-20", "horde", 15, 20)
    end)

    it("starts each race on its branch at the band that contains the level", function()
        assert.equals("horde_durotar_01-05", (choose("Orc", 1)))
        assert.equals("horde_durotar_05-10", (choose("Troll", 5)))
        assert.equals("horde_durotar_05-10", (choose("Orc", 10)))
        assert.equals("horde_tirisfal_10-15", (choose("Undead", 12)))
    end)

    it("moves to the shared band from level 15, whatever the race", function()
        assert.equals("horde_horde_15-20", (choose("Tauren", 20)))
        assert.equals("horde_horde_15-20", (choose("Orc", 15)))
    end)

    it("does nothing for Alliance", function()
        local id, reason = choose("Human", 5, "Alliance")
        assert.is_nil(id)
        assert.equals("faction", reason)
    end)

    it("resumes a saved route before picking a new one", function()
        W.K.cdb.routeId = "horde_horde_15-20"
        local id, reason = choose("Orc", 1)
        assert.equals("horde_horde_15-20", id)
        assert.equals("resume", reason)
    end)
end)

describe("real generated route files", function()
    it("load with stable keys and the index and zone tables register", function()
        local K = W.start()
        local count = 0
        for id, route in pairs(K.routes) do
            count = count + 1
            assert.is_string(id)
            assert.is_table(route.steps)
            for _, s in ipairs(route.steps) do
                assert.is_string(s.k)
                assert.is_string(s.t)
            end
        end
        assert.is_true(count >= 18)
        assert.is_table(K.index.routes["horde_horde_10-15"])
        assert.equals("Durotar", K.zones[1411][1])
    end)

    it("chooses and loads a real band for a level 5 Orc warrior", function()
        local K = W.start()
        W.state.race = "Orc"
        W.state.raceToken = "Orc"
        W.state.level = 5
        W.fire("PLAYER_LOGIN")
        assert.equals("horde_durotar_05-10", K.Engine.routeId)
        assert.is_not_nil(K.Engine.cursor)
    end)

    it("finds a band by lo-hi, preferring the player's branch", function()
        local K = W.start()
        W.state.race = "Orc"
        W.state.raceToken = "Orc"
        K.Detect()
        assert.equals("horde_horde_10-15", K.Engine:FindBand("10-15"))
        assert.equals("horde_horde_10-15", K.Engine:FindBand("horde_horde_10-15"))
        assert.is_nil(K.Engine:FindBand("99-100"))
    end)
end)

describe("error handling and debugging", function()
    it("a failing handler is logged and does not raise into the game", function()
        local K = W.start({ skipRoutes = true })
        K.On("TEST_BOOM", function()
            error("boom")
        end)
        W.fire("TEST_BOOM")
        local found = false
        for _, line in ipairs(K.LogLines()) do
            if line:find("error in TEST_BOOM", 1, true) then
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("the debug log keeps the newest 200 lines", function()
        local K = W.start({ skipRoutes = true })
        for n = 1, 250 do
            K.Log("line", n)
        end
        local lines = K.LogLines()
        assert.equals(200, #lines)
        assert.truthy(lines[#lines]:find("line 250", 1, true))
    end)

    it("compat reports unknown quest state as nil instead of erroring", function()
        local K = W.start({ legacy = true, skipRoutes = true })
        W.unset("IsQuestFlaggedCompleted")
        assert.is_nil(K.Compat.IsQuestCompleted(1))
        assert.is_false(K.Compat.HasFlaggedCompletedApi())
    end)

    it("/klimax debug prints the player and the cursor step", function()
        local K = W.start({ skipRoutes = true })
        registerDemo()
        loadDemo()
        K.Command("debug")
        local joined = table.concat(W.printed, "\n")
        assert.truthy(joined:find("player:", 1, true))
        assert.truthy(joined:find("step 1/", 1, true))
    end)
end)
