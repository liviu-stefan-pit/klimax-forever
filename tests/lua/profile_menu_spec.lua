-- Phase 22: profile and presets, the first-run wizard, the step menu (skip quest, skip step, mark
-- done with confirmation, restore, pin, why, NPC info, arrow), the Skipped list and the saved-variable
-- migration.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K

-- A level 2 Orc at Razor Hill with the real compiled world: the plan starts with Cutting Teeth.
local function start(opts)
    K = W.start(W.merge({ skipRoutes = true }, opts))
    W.state.level, W.state.mapID, W.state.pos = 2, 1411, { x = 0.42, y = 0.68 }
    W.fire("PLAYER_LOGIN")
    W.flushTimers()
    K.Engine:Recompute()
    return K
end

local function stepKey(t, q)
    return "plan:" .. t .. ":" .. q
end

local function index(t, q)
    return K.Engine.byKey[stepKey(t, q)]
end

describe("profile", function()
    before_each(function()
        W.reset()
        K = W.loadAddon({ skipRoutes = true })
    end)

    it("fills defaults and drops unknown values", function()
        local p = K.Profile.Normalize({ pace = "warp", elites = "skip" })
        assert.equal("relaxed", p.pace)
        assert.equal("skip", p.elites)
        assert.equal("solo", p.group)
    end)

    it("applies presets over the defaults and cycles a setting", function()
        local p = K.Profile.Preset("speed")
        assert.equal("speed", p.pace)
        assert.equal("skip", p.elites)
        assert.equal("solo", p.group)
        assert.equal("allow", K.Profile.NextChoice("elites", "skip"))
        assert.equal("easy", K.Profile.NextChoice("elites", "allow"))
    end)

    it("previews the choices in plain language with a speed estimate", function()
        local lines, pct = K.Profile.Preview({ elites = "skip" })
        assert.equal(-10, pct)
        local text = table.concat(lines, " ")
        assert.is_truthy(text:find("skip elite quests", 1, true))
        assert.is_truthy(text:find("10% slower", 1, true))
    end)

    it("turns a profile into planner weights", function()
        local wt = K.Plan.Weights.For(K.Profile.Preset("speed"))
        assert.equal(0, wt.risk.elite)
        assert.equal(0, wt.risk.group)
        assert.equal(1.0, wt.leaveZone)
    end)
end)

describe("presets change the plan", function()
    local function planWith(preset)
        K = W.start()
        W.state.level, W.state.race, W.state.raceToken, W.state.class = 12, "Orc", "Orc", "WARRIOR"
        W.state.mapID, W.state.pos = 1411, { x = 0.52, y = 0.43 }
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        K.Profile.ApplyPreset(preset)
        local keys = {}
        for _, s in ipairs(K.Planner:Get().steps) do
            keys[#keys + 1] = s.k
        end
        return table.concat(keys, " ")
    end

    it("a level 12 Orc at Razor Hill: Speed leaves for the Barrens, Complete finishes Durotar first", function()
        local relaxed, speed, complete = planWith("relaxed"), planWith("speed"), planWith("completionist")
        assert.are_not.equal(relaxed, speed)
        assert.are_not.equal(speed, complete)
        assert.is_truthy(speed:find("plan:V:1413", 1, true))
        local cut = complete:find("plan:V:1413", 1, true) or (#complete + 1)
        assert.is_truthy(complete:sub(1, cut):find("plan:C:834", 1, true))
    end)

    it("the wizard opens once on the first login and saves a profile", function()
        K = W.start()
        assert.is_false(K.Profile.Chosen())
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        assert.is_true(K.Profile.Chosen())
        local rows = K.Wizard.Rows(K.Profile.Get())
        assert.equal(#K.Profile.FIELDS, #rows)
        assert.is_truthy(rows[1].text:find("Pace", 1, true))
    end)
end)

describe("step menu", function()
    it("offers the right entries for each state", function()
        start()
        local SM = K.StepMenu
        local items = SM.Items(K.Engine.steps[1], "pending", nil, false, false)
        assert.are.same({ "skipQuest", "skipStep", "markDone", "pin", "why", "npc", "arrow" }, items)
        items = SM.Items(K.Engine.steps[1], "pending", "hidden", true, false)
        assert.are.same({ "skipStep", "markDone", "restore", "pin", "why", "npc", "arrow" }, items)
        items = SM.Items({ t = "S", k = "svc:repair", z = 1, x = 1, y = 1 }, "pending", nil, false, true)
        assert.are.same({ "skipStep", "markDone", "unpin", "why", "arrow" }, items)
    end)

    it("the plan offers Cutting Teeth at Gornek", function()
        start()
        local first
        for _, s in ipairs(K.Engine.steps) do
            if s.t == "A" then
                first = s
                break
            end
        end
        assert.is_not_nil(first)
        assert.is_not_nil(index("A", 788))
        assert.are.equal("available", (K.State:Get(788)))
    end)

    it("skips a whole quest and restores it, across a /reload", function()
        start()
        K.StepMenu.Do("skipQuest", index("A", 788))
        assert.is_nil(index("A", 788))
        assert.equal("ignored", (K.State:Get(788)))
        assert.equal(788, K.StepMenu.SkippedQuests()[1].q)
        K = W.reload({ skipRoutes = true })
        assert.is_true(K.cdb.skipQuests[788])
        assert.is_nil(index("A", 788))
        K.Engine:RestoreQuest(788)
        assert.is_not_nil(index("A", 788))
        K = W.reload({ skipRoutes = true })
        assert.is_not_nil(index("A", 788))
        assert.is_nil(K.cdb.skipQuests[788])
    end)

    it("the planner never plans a skipped quest", function()
        start()
        K.Engine:SkipQuest(788)
        for _, s in ipairs(K.Planner:Get().steps) do
            assert.are_not.equal(788, s.q)
        end
    end)

    it("Mark done asks once when the game disagrees, then hides the step", function()
        start()
        local i = index("A", 788)
        K.StepMenu.MarkDone(i)
        assert.equal(i, K.StepMenu.pendingDone)
        assert.is_not_nil(index("A", 788))
        K.StepMenu.ConfirmHidden()
        assert.is_nil(index("A", 788))
        assert.is_true(K.cdb.hideAnswers[788])
        K.Engine:RestoreQuest(788)
        assert.is_not_nil(index("A", 788))
        assert.is_true(K.StepMenu.MarkDone(index("A", 788)))   -- answered before: no question
        assert.is_nil(index("A", 788))
    end)

    it("Mark done hides a step the game cannot contradict without asking", function()
        start()
        W.showSteps(K, { { t = "S", k = "svc:repair", n = "Repair", note = "Repair", reason = "repair" },
            { t = "C", k = "plan:C:788", q = 788, n = "Cutting Teeth", z = 1411, x = 44, y = 65 } })
        assert.is_true(K.StepMenu.MarkDone(1))   -- a service stop: no quest state
        assert.is_nil(K.StepMenu.pendingDone)
        assert.equal(1, #K.Engine.steps)
        -- a COMPLETE whose objectives are not done is contradicted, so it asks
        W.setQuestLog(788, false)
        K.State:Refresh()
        assert.is_false(K.StepMenu.MarkDone(1))
        assert.equal(1, K.StepMenu.pendingDone)
    end)

    it("Pin next puts the quest first in the guide and the plan", function()
        start()
        local pinned
        for i = #K.Engine.steps, 1, -1 do
            local s = K.Engine.steps[i]
            if s.t == "A" and s.q ~= 788 and K.State:Get(s.q) == "available" then
                pinned = i
                break
            end
        end
        assert.is_not_nil(pinned)
        local q = K.Engine.steps[pinned].q
        K.StepMenu.Do("pin", pinned)
        assert.equal(q, K.cdb.pin.q)
        assert.equal(q, K.Engine.steps[K.Engine.cursor].q)
        K.StepMenu.Do("unpin", 1)
        assert.is_nil(K.cdb.pin)
    end)

    it("explains a step and shows its NPC", function()
        start()
        local i = index("A", 788)
        local lines = K.StepMenu.WhyLines(K.Engine.steps[i], "pending")
        assert.is_truthy(table.concat(lines, " "):find("available", 1, true))
        local npc = K.StepMenu.NpcLines(K.Engine.steps[i])
        assert.is_truthy(npc[1]:find("Gornek", 1, true))
        W.printed = {}
        K.StepMenu.Do("why", i)
        assert.is_true(#W.printed >= 3)
    end)

    it("Point arrow here focuses the step", function()
        start()
        local i = index("A", 788)
        K.StepMenu.Do("arrow", i)
        assert.equal(stepKey("A", 788), K.UI.focusKey)
    end)

    it("opens as a frame with a Close entry", function()
        start()
        local items = K.StepMenu.Open(1, nil)
        assert.equal("close", items[#items])
    end)
end)

describe("saved-variable migration", function()
    it("turns skipped ACCEPT steps into quest skips (schema 2) and moves to the plan engine (schema 3)", function()
        K = W.start({ skipRoutes = true, charDB = { version = 1, routeId = "horde_horde_10-15", stepState = {
            band = { ["band:A:788:0"] = "skipped", ["band:C:790:0"] = "skipped", ["band:A:791:0"] = "done" },
        }, elitePending = { x = {} }, ignoredSuggestions = { [5] = true } } })
        assert.equal(3, K.cdb.version)
        assert.is_true(K.cdb.skipQuests[788])
        assert.is_nil(K.cdb.skipQuests[790])
        assert.is_nil(K.cdb.skipQuests[791])
        assert.equal("skipped", K.cdb.stepState.band["band:A:788:0"])   -- kept for the old add-on version
        assert.is_nil(K.cdb.routeId)
        assert.equal("horde_horde_10-15", K.cdb.legacyRoute)
        assert.is_nil(K.cdb.elitePending)
        assert.is_nil(K.cdb.ignoredSuggestions)
        assert.are.same({}, K.cdb.hiddenSteps)
        assert.are.same({}, K.cdb.brokenQuests)
    end)

    it("drops the engine choice and the options that only steered the band engine", function()
        K = W.start({ skipRoutes = true })
        _G.KlimaxDB = { version = 1, options = { engine = "legacy", showElite = false, autoAdvance = false,
            arrow = false } }
        K.InitSavedVariables()
        assert.equal(2, K.db.version)
        assert.is_nil(K.db.options.engine)
        assert.is_nil(K.db.options.showElite)
        assert.is_nil(K.db.options.autoAdvance)
        assert.is_false(K.db.options.arrow)
    end)

    it("Reset guide keeps the skipped quests; Reset all clears them", function()
        start()
        K.Engine:SkipQuest(788)
        K.cdb.brokenQuests[900] = true
        K.cdb.hiddenSteps["plan:A:1"] = true
        K.cdb.visited = { x = true }
        K.Command("reset guide")
        assert.is_true(K.cdb.skipQuests[788])
        assert.is_nil(K.cdb.brokenQuests[900])
        assert.is_nil(K.cdb.hiddenSteps["plan:A:1"])
        K.Command("reset all")
        assert.is_nil(K.cdb.skipQuests[788])
    end)
end)
