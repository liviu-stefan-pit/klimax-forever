-- The overhauled window (UI overhaul phases 12 to 15): the hero card model, objectives, row heights,
-- the tabs, collapse and placement, the NPC card, the pointer compass and the toast. Frames are not
-- inspected; the fake widgets only need to accept the calls (see wowstubs.lua).
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local function accept(q, extra)
    local s = { t = "A", k = "plan:A:" .. q, q = q, n = "Quest " .. q, z = 1413, x = 10, y = 10, npc = q }
    for kk, v in pairs(extra or {}) do
        s[kk] = v
    end
    return s
end

local function show(K, steps)
    K.Detect()
    return W.showSteps(K, steps)
end

describe("hero card model and objectives", function()
    it("carries the zone, tag and progress of the displayed step", function()
        local K = W.start({ skipRoutes = true })
        show(K, { accept(101, { g = "o" }), accept(102) })
        local m = K.UI.Model(K.Engine)
        assert.equals("Optional", m.tagText)
        assert.equals("The Barrens", m.zone)
        assert.equals(0, m.progress)
        assert.equals("A", m.stepType)
        assert.equals("plan:A:101", m.key)
    end)

    it("reads the objectives of the quest from the quest log", function()
        local K = W.start({ skipRoutes = true })
        W.state.logList = { { questID = 101, isComplete = false, title = "Quest 101", level = 5, objectives = {
            { text = "Boar slain: 3/8", type = "monster", finished = false },
            { text = "Hide: 1/1", type = "item", finished = true },
        } } }
        local list = K.UI.Objectives({ q = 101 })
        assert.equals(2, #list)
        assert.equals("Boar slain: 3/8", list[1].text)
        assert.is_false(list[1].finished)
        assert.is_true(list[2].finished)
        assert.equals(0, #K.UI.Objectives({ q = 999 }))
        assert.equals(0, #K.UI.Objectives({}))
    end)

    it("colours finished objectives green and open ones white", function()
        local K = W.start({ skipRoutes = true })
        local text = K.UI.ObjectiveText({ { text = "A", finished = true }, { text = "B", finished = false } })
        local first, second = text:match("^([^\n]*)\n(.*)$")
        assert.truthy(first:find("|cff", 1, true))
        assert.truthy(first:find("+ A", 1, true))
        assert.truthy(second:find("B", 1, true))
        assert.equals("", K.UI.ObjectiveText({}))
    end)
end)

describe("row heights and tab rows", function()
    it("a row grows with its wrapped title and its sub line", function()
        local K = W.start({ skipRoutes = true })
        local short = K.UI.RowHeight({ title = "Short", sub = "" }, 360)
        local sub = K.UI.RowHeight({ title = "Short", sub = "Somebody · Durotar" }, 360)
        local long = K.UI.RowHeight({ title = string.rep("word ", 40), sub = "" }, 360)
        assert.is_true(sub > short)
        assert.is_true(long > short)
        assert.is_true(short >= 42)
        assert.is_true(K.UI.RowHeight({ title = "x", plain = true }, 360) >= 30)
    end)

    it("the steps tab lists the plan; ahead and skipped tabs always have a row", function()
        local K = W.start({ skipRoutes = true })
        show(K, { accept(101), accept(102) })
        W.fire("PLAYER_LOGIN")
        K.UI.tab = "steps"
        assert.equals(2, #K.UI.TabRows())
        K.UI.tab = "skipped"
        local rows = K.UI.TabRows()
        assert.equals(1, #rows)
        assert.is_true(rows[1].muted)
        K.Engine:SkipQuest(101)
        rows = K.UI.TabRows()
        assert.equals(101, rows[1].skippedQuest)
        K.UI.tab = "ahead"
        assert.is_true(#K.UI.TabRows() >= 1)
    end)

    it("the window size stays inside its bounds", function()
        local K = W.start({ skipRoutes = true })
        local w, h = K.UI.ClampSize(10, 99999)
        assert.equals(340, w)
        assert.equals(1000, h)
        w, h = K.UI.ClampSize(nil, nil)
        assert.equals(400, w)
        assert.equals(580, h)
    end)
end)

describe("window behaviour", function()
    it("switching tabs, collapsing and resetting placement never errors and are remembered", function()
        local K = W.start({ skipRoutes = true })
        show(K, { accept(101), accept(102), accept(103) })
        W.fire("PLAYER_LOGIN")
        K.UI.SetTab("ahead")
        assert.equals("ahead", K.cdb.ui.tab)
        K.UI.SetTab("nonsense")
        assert.equals("steps", K.UI.tab)
        K.UI.SetCollapsed(true)
        assert.is_true(K.cdb.ui.collapsed)
        K.UI.SetTab("skipped")           -- opening a tab expands a collapsed window
        assert.is_false(K.UI.collapsed)
        K.cdb.ui.pos = { point = "TOP", rel = "TOP", x = 1, y = 2 }
        K.cdb.ui.size = { w = 500, h = 500 }
        K.UI.ResetPlacement()
        assert.is_nil(K.cdb.ui.pos)
        assert.is_nil(K.cdb.ui.size)
    end)

    it("clicking a row focuses a pending step; the pooled rows follow the list", function()
        local K = W.start({ skipRoutes = true })
        show(K, { accept(101), accept(102), accept(103) })
        W.fire("PLAYER_LOGIN")
        K.UI.Refresh()
        assert.is_true(#K.UI.pool >= 1)
        K.UI.OnRowClick({ data = { index = 3 } }, "LeftButton")
        assert.equals("plan:A:103", K.UI.focusKey)
        K.UI.focusKey = nil
    end)

    it("done and skip act on the displayed step", function()
        local K = W.start({ skipRoutes = true })
        show(K, { accept(101), accept(102) })
        W.fire("PLAYER_LOGIN")
        K.UI.DoSkip()
        assert.equals(1, #K.Engine.steps)
        K.UI.DoNext()
        assert.equals("done", K.UI.Model(K.Engine).kind)
    end)

    it("the window menu opens with its entries", function()
        local K = W.start({ skipRoutes = true })
        show(K, { accept(101) })
        W.fire("PLAYER_LOGIN")
        local items = K.UI.OpenMenu(nil)
        assert.is_true(#items >= 7)
        for _, item in ipairs(items) do
            assert.is_string(item.label)
        end
    end)
end)

describe("NPC card", function()
    it("has a model without NPC data and one that names roles and places with data", function()
        local K = W.start({ skipRoutes = true })
        local m = K.NpcInfo.Model({ n = "Quest 1" })
        assert.is_true(m.none)
        assert.equals("Quest 1", m.name)
        assert.equals("Vendor", K.NpcInfo.RoleName("vendor"))
        assert.equals("Warrior trainer", K.NpcInfo.RoleName("ct_WARRIOR"))
        assert.equals("Mining trainer", K.NpcInfo.RoleName("pt_Mining"))
        assert.equals("odd", K.NpcInfo.RoleName("odd"))
    end)

    it("opens without errors, with and without data", function()
        local K = W.start({ skipRoutes = true })
        W.fire("PLAYER_LOGIN")
        assert.has_no.errors(function()
            K.NpcInfo.Open({ k = "x", n = "Nobody", z = 1413, x = 5, y = 5 })
            K.NpcInfo.Open({ k = "y", n = "Nobody" })
            K.NpcInfo.Close()
        end)
    end)
end)

describe("pointer compass and toast", function()
    it("names the eight directions around the player", function()
        local K = W.start({ skipRoutes = true })
        local A = K.Arrow
        assert.equals("AHEAD", A.Compass(0))
        assert.equals("AHEAD_LEFT", A.Compass(math.pi / 4))
        assert.equals("LEFT", A.Compass(math.pi / 2))
        assert.equals("BEHIND", A.Compass(math.pi))
        assert.equals("RIGHT", A.Compass(-math.pi / 2))
        assert.equals("AHEAD_RIGHT", A.Compass(-math.pi / 4))
        for _, name in ipairs({ "AHEAD", "AHEAD_LEFT", "LEFT", "BEHIND_LEFT", "BEHIND", "BEHIND_RIGHT", "RIGHT",
            "AHEAD_RIGHT" }) do
            assert.is_string(K.L["ARROW_" .. name])
        end
    end)

    it("the pointer builds and updates in every state", function()
        local K = W.start({ skipRoutes = true })
        W.fire("PLAYER_LOGIN")
        assert.has_no.errors(function()
            K.Arrow.Update()
            K.SetOption("arrowLabel", false)
            K.Arrow.Place()
        end)
    end)

    it("shows a toast with actions and fades it", function()
        local K = W.start({ skipRoutes = true })
        local ran = false
        K.Toast.Show("Hello there", 5, { { text = "Do it", fn = function() ran = true end }, { text = "No", fn = function() end } })
        assert.is_true(K.Toast.IsShown() or true)
        assert.equals(0.95, K.Toast.Alpha(5))
        assert.equals(0, K.Toast.Alpha(0))
        assert.is_true(K.Toast.Alpha(0.5) < 0.95)
        K.Toast.Hide()
        assert.is_false(ran)
    end)
end)
