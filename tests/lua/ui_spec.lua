-- UI state logic and options (phase 07): what the window shows, the step list rows, bands, the
-- menu pages, option cycling and the auto-advance switch. Frames are not inspected; the fake
-- widgets only need to accept the calls (see wowstubs.lua).
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local function route(id, steps, extra)
    local r = { id = id, faction = "horde", branch = "horde", lo = 1, hi = 5, steps = steps,
        entry = { z = 1413, x = 52, y = 30, lv = 1 } }
    for k, v in pairs(extra or {}) do
        r[k] = v
    end
    return r
end

-- Each accept gets its own NPC (npc = q) so steps do not group into a hub batch unless a test says so.
local function accept(k, q, extra)
    local s = { t = "A", k = k, q = q, n = "Quest " .. q, g = "m", z = 1413, x = 10, y = 10, npc = q }
    for kk, v in pairs(extra or {}) do
        s[kk] = v
    end
    return s
end

local function loadRoute(K, r)
    W.registerRoute(r)
    K.Detect()
    local ok, err = K.Engine:Load(r.id)
    assert.is_true(ok, err)
    return K
end

describe("window model", function()
    it("shows the cursor step with its action, title, tag and step count", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("m1", { accept("A1", 101, { note = "Go talk." }), accept("A2", 102) }))
        local m = K.UI.Model(K.Engine)
        assert.equals("step", m.kind)
        assert.equals(1, m.index)
        assert.equals("Accept", m.action)
        assert.equals("Quest 101", m.title)
        assert.equals("m", m.tag)
        assert.equals("Main", m.tagText)
        assert.equals("Go talk.", m.note)
        assert.equals(1, m.stepNo)
        assert.equals(2, m.total)
        assert.is_nil(m.checklist)
    end)

    it("shows a hub batch as a checklist with its progress", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("m2", {
            accept("A1", 101, { npc = 500 }), accept("A2", 102, { npc = 500 }), accept("A3", 103, { npc = 500 }),
        }))
        local m = K.UI.Model(K.Engine)
        assert.equals(3, #m.checklist)
        assert.equals(0, m.hubDone)
        assert.equals(3, m.hubTotal)
        -- Marking one step of the hub marks the whole batch, so the window has nothing left.
        K.Engine:MarkDone(2)
        assert.equals("done", K.Engine.eff[1])
        assert.equals("done", K.UI.Model(K.Engine).kind)
    end)

    it("reports done when nothing is left and gated when the next step needs a higher level", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("m3", { accept("A1", 101), accept("A2", 102, { ml = 9 }) }))
        K.Engine:Next()
        local m = K.UI.Model(K.Engine)
        assert.equals("gated", m.kind)
        assert.equals(9, m.level)
        K.player.level = 9
        K.Engine:Recompute()
        assert.equals("step", K.UI.Model(K.Engine).kind)
        K.Engine:Next()
        assert.equals("done", K.UI.Model(K.Engine).kind)
    end)

    it("reports none when no route is loaded", function()
        local K = W.start({ skipRoutes = true })
        assert.equals("none", K.UI.Model(K.Engine).kind)
    end)
end)

describe("display index, focus and options", function()
    it("a focused pending step is shown in place of the cursor; Next marks only that step", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("f1", { accept("A1", 101), accept("A2", 102), accept("A3", 103) }))
        K.UI.focusKey = "A3"
        assert.equals(3, K.UI.DisplayIndex(K.Engine))
        K.Engine:MarkDone(3)
        assert.equals("done", K.Engine.eff[3])
        assert.equals("pending", K.Engine.eff[1])
        assert.equals(1, K.Engine.cursor)
    end)

    it("a focus on a step that is no longer pending falls back to the cursor", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("f2", { accept("A1", 101), accept("A2", 102) }))
        K.Engine:MarkDone(2)
        K.UI.focusKey = "A2"
        assert.equals(1, K.UI.DisplayIndex(K.Engine))
    end)

    it("hides Optional steps when the option is off and shows the next visible step", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("o1", {
            accept("A1", 101),
            accept("A2", 102, { g = "o" }),
            accept("A3", 103),
        }))
        K.SetOption("showOptional", false)
        K.Engine:MarkDone(1)
        assert.equals(3, K.UI.DisplayIndex(K.Engine))
        assert.equals(2, K.Engine.cursor)   -- the engine still stops on the optional step
        K.SetOption("showOptional", true)
        assert.equals(2, K.UI.DisplayIndex(K.Engine))
    end)

    it("hides Optional-Elite steps with their own option", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("o2", { accept("A1", 101, { g = "e" }), accept("A2", 102) }))
        K.SetOption("showElite", false)
        assert.is_false(K.UI.StepShown(K.Engine.steps[1]))
        K.SetOption("showElite", true)
        assert.is_true(K.UI.StepShown(K.Engine.steps[1]))
    end)

    it("reports hidden when every remaining step is optional and the option is off", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("o3", { accept("A1", 101, { g = "o" }) }))
        K.SetOption("showOptional", false)
        assert.equals("hidden", K.UI.Model(K.Engine).kind)
    end)

    it("auto-advance off: quest events do not mark steps; manual Next still does", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("a1", { accept("A1", 101), accept("A2", 102) }))
        K.SetOption("autoAdvance", false)
        W.fire("QUEST_ACCEPTED", 1, 101)
        assert.equals("pending", K.Engine.eff[1])
        K.Engine:Next()
        assert.equals("done", K.Engine.eff[1])
    end)

    it("auto-advance on (default): a quest event marks the accept step", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("a2", { accept("A1", 101), accept("A2", 102) }))
        assert.is_true(K.Option("autoAdvance"))
        W.fire("QUEST_ACCEPTED", 1, 101)
        assert.equals("done", K.Engine.eff[1])
    end)
end)

describe("step list", function()
    it("marks the cursor, done, skipped and cascaded steps", function()
        local K = W.start({ skipRoutes = true })
        loadRoute(K, route("l1", { accept("A1", 101), accept("A2", 102), accept("A3", 102) }))
        K.Engine:Skip(1)
        local rows = K.UI.ListRows(K.Engine)
        assert.equals("[-]", rows[1].mark)
        assert.equals("skipped", rows[1].state)
        assert.equals("[>]", rows[2].mark)
        assert.equals(3, #rows)
        assert.equals("1. Accept  Quest 101", rows[1].text)
    end)
end)

describe("text clipping", function()
    it("returns short text unchanged and cuts long text with an ellipsis", function()
        local K = W.start({ skipRoutes = true })
        assert.equals("short", K.UI.Clip("short", 10))
        local out = K.UI.Clip(string.rep("a", 50), 20)
        assert.equals(20, #out)
        assert.equals("...", out:sub(-3))
    end)

    it("never cuts inside a UTF-8 character", function()
        local K = W.start({ skipRoutes = true })
        local text = string.rep("a", 16) .. "é" .. string.rep("b", 10)  -- é is two bytes
        local out = K.UI.Clip(text, 20)
        assert.is_true(#out <= 20)
        assert.is_nil(out:find("95$"))
        assert.equals("...", out:sub(-3))
    end)
end)

describe("bands and labels", function()
    it("lists the branch and shared bands in level order, and labels them with the zone", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute(route("b_dur_1", { accept("X1", 1) }, { id = "b_dur_1", branch = "durotar", lo = 1, hi = 5 }))
        W.registerRoute(route("b_hor_10", { accept("X2", 2) }, { id = "b_hor_10", lo = 10, hi = 15 }))
        W.registerRoute(route("b_tir_1", { accept("X3", 3) }, { id = "b_tir_1", branch = "tirisfal", lo = 1, hi = 5 }))
        local choices = K.UI.BandChoices("b_dur_1")
        assert.same({ "b_dur_1", "b_hor_10" }, choices)
        assert.equals("Lvl 10–15 · The Barrens", K.UI.BandLabel("b_hor_10"))
    end)

    it("the reset items are reset band, reset guide and audit", function()
        local K = W.start({ skipRoutes = true })
        local items = K.UI.ResetItems()
        assert.equals(3, #items)
        assert.equals(K.L.MENU_RESET_BAND, items[1].text)
        assert.equals(K.L.MENU_RESET_ALL, items[2].text)
        assert.equals(K.L.MENU_AUDIT, items[3].text)
    end)
end)

describe("sizing and scrolling helpers", function()
    it("a button is as wide as its text plus padding, and never below its minimum", function()
        local K = W.start({ skipRoutes = true })
        assert.equals(28 + 50, K.UI.ButtonWidth(50, 0))
        assert.equals(110, K.UI.ButtonWidth(20, 110))
        assert.equals(28 + 51, K.UI.ButtonWidth(50.2, 0))
        assert.equals(28, K.UI.ButtonWidth(nil, 0))
    end)

    it("scroll offsets stay inside the content", function()
        local K = W.start({ skipRoutes = true })
        assert.equals(0, K.UI.ClampScroll(-30, 500, 200))
        assert.equals(300, K.UI.ClampScroll(999, 500, 200))
        assert.equals(0, K.UI.ClampScroll(50, 100, 200))
    end)

    it("the current row is brought near the top third of the view", function()
        local K = W.start({ skipRoutes = true })
        assert.equals(300 - 60, K.UI.ScrollTarget(300, 1000, 180))
        assert.equals(0, K.UI.ScrollTarget(10, 1000, 180))
        assert.equals(820, K.UI.ScrollTarget(990, 1000, 180))
    end)
end)

describe("options", function()
    it("NextValue steps through a list and wraps; an unknown value gives the first", function()
        local K = W.start({ skipRoutes = true })
        local values = { 0.8, 1, 1.25 }
        assert.equals(1, K.UI.NextValue(values, 0.8))
        assert.equals(1.25, K.UI.NextValue(values, 1))
        assert.equals(0.8, K.UI.NextValue(values, 1.25))
        assert.equals(0.8, K.UI.NextValue(values, 42))
    end)

    it("bool rows flip and cycle rows move to the next value", function()
        local K = W.start({ skipRoutes = true })
        local rows = K.UI.OPTION_ROWS
        local byKey = {}
        for _, row in ipairs(rows) do
            byKey[row.key] = row
        end
        assert.is_false(K.UI.ToggledValue(byKey.showOptional))
        assert.equals(4, K.UI.ToggledValue(byKey.bagThreshold))
        K.SetOption("fontScale", 1.15)
        assert.equals(1.3, K.UI.ToggledValue(byKey.fontScale))
    end)

    it("options default when nothing is stored, and a stored value wins", function()
        local K = W.start({ skipRoutes = true })
        assert.is_true(K.Option("showOptional"))
        assert.equals(3, K.Option("bagThreshold"))
        K.SetOption("showOptional", false)
        assert.is_false(K.Option("showOptional"))
    end)

    it("the options text shows the state of a bool row and the value of a cycle row", function()
        local K = W.start({ skipRoutes = true })
        local rows = K.UI.OPTION_ROWS
        assert.equals("[x] " .. K.L.OPT_SHOW_OPTIONAL, K.UI.OptionText(rows[1]))
        assert.equals(K.L.OPT_BAG .. ": 3", K.UI.OptionText(rows[8]))
    end)
end)

describe("window lifecycle", function()
    it("builds on PLAYER_LOGIN without errors and toggles with the slash command", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "horde_test", faction = "horde", branch = "horde", lo = 1, hi = 5,
            entry = { z = 1413, x = 1, y = 1, lv = 1 },
            steps = { accept("A1", 101) } })
        W.fire("PLAYER_LOGIN")
        assert.is_not_nil(K.UI.frame)
        assert.is_not_nil(K.Arrow.frame)
        assert.is_true(K.UI.Wanted())
        K.Command("")
        assert.is_false(K.UI.Wanted())
        K.Command("")
        assert.is_true(K.UI.Wanted())
    end)

    it("hides in combat when the option is on and returns after combat", function()
        local K = W.start({ skipRoutes = true })
        W.fire("PLAYER_LOGIN")
        K.SetOption("hideInCombat", true)
        W.fire("PLAYER_REGEN_DISABLED")
        assert.is_true(K.UI.combatHidden)
        W.fire("PLAYER_REGEN_ENABLED")
        assert.is_false(K.UI.combatHidden)
    end)
end)
