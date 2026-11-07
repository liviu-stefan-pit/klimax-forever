-- Phase 22: profile and presets, the first-run wizard, the step menu (skip quest, skip step, mark
-- done with confirmation, restore, pin, why, NPC info, arrow), the Skipped list and the saved-variable
-- migration.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K

local function demoRoute()
    return { id = "menu", faction = "horde", branch = "horde", lo = 1, hi = 10, steps = {
        { t = "A", k = "A1", q = 788, n = "Cutting Teeth", g = "m", z = 1411, x = 42.1, y = 68.3, npc = 3143, ql = 2 },
        { t = "C", k = "C1", q = 788, n = "Cutting Teeth", g = "m", z = 1411, x = 44.2, y = 65.3, ql = 2 },
        { t = "T", k = "T1", q = 788, n = "Cutting Teeth", g = "m", z = 1411, x = 42.1, y = 68.3, npc = 3143, ql = 2 },
        { t = "A", k = "A2", q = 789, n = "Sting of the Scorpid", g = "m", z = 1411, x = 42.1, y = 68.3, npc = 3143,
            ql = 3, po = { 788 } },
        { t = "B", k = "B1", z = 1411, x = 42.0, y = 68.0, note = "buy" },
    } }
end

local function start(opts)
    K = W.start(W.merge({ skipRoutes = true }, opts))
    W.registerRoute(demoRoute())
    W.registerIndex({ routes = {}, start = {}, quests = { [788] = { "menu" }, [789] = { "menu" } } })
    W.state.level, W.state.mapID, W.state.pos = 2, 1411, { x = 0.42, y = 0.68 }
    W.fire("PLAYER_LOGIN")
    K.Engine:Load("menu")
    K.cdb.routeId = "menu"
    W.flushTimers()
    return K
end

local function eff(k)
    return K.Engine.eff[K.Engine.byKey[k]]
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

    it("a level 12 Orc at Razor Hill: Speed leaves for Orgrimmar, Complete finishes Durotar first", function()
        local relaxed, speed, complete = planWith("relaxed"), planWith("speed"), planWith("completionist")
        assert.are_not.equal(relaxed, speed)
        assert.are_not.equal(speed, complete)
        assert.is_truthy(speed:find("plan:V:1454", 1, true))
        local cut = complete:find("plan:V:1454", 1, true) or (#complete + 1)
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
        items = SM.Items(K.Engine.steps[1], "skipped", "skipped", true, false)
        assert.are.same({ "restore", "why", "npc" }, items)
        items = SM.Items(K.Engine.steps[5], "pending", nil, false, true)
        assert.are.same({ "skipStep", "markDone", "unpin", "why", "arrow" }, items)
    end)

    it("skips a whole quest and restores it, across a /reload", function()
        start()
        K.StepMenu.Do("skipQuest", K.Engine.byKey.A1)
        assert.equal("skipped", eff("A1"))
        assert.equal("skipped", eff("T1"))
        assert.equal("unavailable", (K.State:Get(789)))   -- its follow-up needs it
        assert.equal(788, K.StepMenu.SkippedQuests()[1].q)
        K = W.reload({ skipRoutes = true })
        W.registerRoute(demoRoute())
        K.Engine:Load("menu")
        assert.equal("skipped", eff("A1"))
        assert.is_true(K.cdb.skipQuests[788])
        K.StepMenu.Do("restore", K.Engine.byKey.A1)
        assert.equal("pending", eff("A1"))
        K = W.reload({ skipRoutes = true })
        W.registerRoute(demoRoute())
        K.Engine:Load("menu")
        assert.equal("pending", eff("A1"))
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
        K.StepMenu.MarkDone(K.Engine.byKey.A1)
        assert.equal(K.Engine.byKey.A1, K.StepMenu.pendingDone)
        assert.equal("pending", eff("A1"))
        K.StepMenu.ConfirmHidden()
        assert.equal("skipped", eff("A1"))
        assert.is_true(K.cdb.hideAnswers[788])
        K.Engine:RestoreQuest(788)
        assert.is_true(K.StepMenu.MarkDone(K.Engine.byKey.A1))   -- answered before: no question
        assert.equal("skipped", eff("A1"))
    end)

    it("Mark done marks a step the game cannot contradict without asking", function()
        start()
        assert.is_true(K.StepMenu.MarkDone(K.Engine.byKey.B1))   -- a BUY step: no quest state
        assert.is_nil(K.StepMenu.pendingDone)
        assert.equal("done", eff("B1"))
        -- a COMPLETE whose objectives are not done is contradicted, so it asks
        W.setQuestLog(788, false)
        K.State:Refresh()
        assert.is_false(K.StepMenu.MarkDone(K.Engine.byKey.C1))
        assert.equal(K.Engine.byKey.C1, K.StepMenu.pendingDone)
    end)

    it("Pin next puts the step first in the guide and the plan", function()
        start()
        local i = K.Engine.byKey.B1
        K.StepMenu.Do("pin", i)
        assert.equal(i, K.Engine.cursor)
        K.State:Refresh()
        local plan = K.Planner:Get()
        assert.is_table(plan)
        K.StepMenu.Do("unpin", i)
        assert.are_not.equal(i, K.Engine.cursor)
    end)

    it("explains a step and shows its NPC", function()
        start()
        local lines = K.StepMenu.WhyLines(K.Engine.steps[1], "pending")
        assert.is_truthy(table.concat(lines, " "):find("available", 1, true))
        local npc = K.StepMenu.NpcLines(K.Engine.steps[1])
        assert.is_truthy(npc[1]:find("Gornek", 1, true))
        W.printed = {}
        K.StepMenu.Do("why", 1)
        assert.is_true(#W.printed >= 3)
    end)

    it("Point arrow here focuses the step", function()
        start()
        K.StepMenu.Do("arrow", K.Engine.byKey.B1)
        assert.equal("B1", K.UI.focusKey)
    end)

    it("opens as a frame with a Close entry", function()
        start()
        local items = K.StepMenu.Open(1, nil)
        assert.equal("close", items[#items])
    end)
end)

describe("saved-variable migration", function()
    it("turns skipped ACCEPT steps into quest skips (schema 2)", function()
        K = W.start({ skipRoutes = true, charDB = { version = 1, stepState = {
            band = { ["band:A:788:0"] = "skipped", ["band:C:790:0"] = "skipped", ["band:A:791:0"] = "done" },
        } } })
        assert.equal(2, K.cdb.version)
        assert.is_true(K.cdb.skipQuests[788])
        assert.is_nil(K.cdb.skipQuests[790])
        assert.is_nil(K.cdb.skipQuests[791])
        assert.equal("skipped", K.cdb.stepState.band["band:A:788:0"])
    end)
end)
