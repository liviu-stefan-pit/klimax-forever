-- The theme's pure maths and the widget kit (UI overhaul phase 11): easing, layout, the visible
-- range of the virtualised list, text line estimates, animations and the widget builders, which only
-- need to run without errors against the fake client.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local function near(a, b, eps)
    assert.is_true(math.abs(a - b) <= (eps or 1e-9), tostring(a) .. " vs " .. tostring(b))
end

describe("theme maths", function()
    local T
    before_each(function()
        T = W.start({ skipRoutes = true }).Theme
    end)

    it("ease runs from 0 to 1, fast at first, and clamps outside", function()
        near(0, T.Ease(0))
        near(1, T.Ease(1))
        assert.is_true(T.Ease(0.5) > 0.5)
        near(0, T.Ease(-3))
        near(1, T.Ease(7))
    end)

    it("lerp and colour lerp interpolate", function()
        near(15, T.Lerp(10, 20, 0.5))
        local mid = T.LerpColour({ 0, 0, 0, 0 }, { 1, 0.5, 1, 1 }, 0.5)
        near(0.5, mid[1])
        near(0.25, mid[2])
        near(0.5, mid[4])
    end)

    it("stacks rows and finds the visible range", function()
        local heights = { 40, 40, 80, 40, 40, 40 }
        local tops, total = T.Layout(heights, 4)
        assert.same({ 0, 44, 88, 172, 216, 260 }, tops)
        assert.equals(300, total)
        -- rows 1 and 2 end at 40 and 84, so a view from 90 to 150 starts at row 3
        local first, last = T.VisibleRange(tops, heights, 90, 60, 0)
        assert.equals(3, first)
        assert.equals(3, last)
    end)

    it("visible range handles empty lists, the end of the list and overscan", function()
        local f, l = T.VisibleRange({}, {}, 0, 100, 0)
        assert.equals(0, f)
        assert.equals(-1, l)
        local heights = { 50, 50, 50, 50 }
        local tops = T.Layout(heights, 0)
        f, l = T.VisibleRange(tops, heights, 0, 60, 0)
        assert.equals(1, f)
        assert.equals(2, l)
        f, l = T.VisibleRange(tops, heights, 150, 500, 0)
        assert.equals(3, f)
        assert.equals(4, l)
        f, l = T.VisibleRange(tops, heights, 100, 10, 60)
        assert.equals(1, f)
        assert.equals(4, l)
    end)

    it("text lines wrap on spaces and count paragraphs", function()
        assert.equals(0, T.TextLines("", 200, 12))
        assert.equals(1, T.TextLines("short", 200, 12))
        assert.equals(2, T.TextLines("a\nb", 200, 12))
        -- 100 px at size 12 is 16 characters per line
        assert.equals(2, T.TextLines("aaaaaaaaaa bbbbbbbbbb", 100, 12))
        assert.is_true(T.TextLines(string.rep("w", 200), 100, 12) >= 12)
    end)

    it("scroll helpers clamp and aim at the top third", function()
        assert.equals(0, T.ClampScroll(-30, 500, 200))
        assert.equals(300, T.ClampScroll(999, 500, 200))
        assert.equals(0, T.ClampScroll(50, 100, 200))
        assert.equals(240, T.ScrollTarget(300, 1000, 180))
    end)

    it("a button is as wide as its text plus padding, never below its minimum", function()
        assert.equals(78, T.ButtonWidth(50, 0))
        assert.equals(110, T.ButtonWidth(20, 110))
        assert.equals(70, T.ButtonWidth(50, 0, 10))
        assert.equals(28, T.ButtonWidth(nil, 0))
    end)

    it("every step kind has a badge, and an unknown kind falls back", function()
        for _, kind in ipairs({ "A", "T", "C", "V", "F", "D", "B", "R", "H", "U", "P", "N", "S" }) do
            assert.is_table(T.BADGE[kind])
        end
        assert.equals("-", T.Badge("?")[1])
    end)
end)

describe("animations", function()
    it("run to the end over their duration and then call done", function()
        local K = W.start({ skipRoutes = true })
        local T = K.Theme
        local last, done = nil, 0
        T.Animate("t1", 1, function(p) last = p end, function() done = done + 1 end)
        assert.equals(0, last)
        assert.is_true(T.Advance(0.4))
        near(0.4, last)
        assert.is_false(T.Advance(0.7))
        assert.equals(1, last)
        assert.equals(1, done)
        assert.is_false(T.Animating())
    end)

    it("a new animation with the same key replaces the old one", function()
        local K = W.start({ skipRoutes = true })
        local T = K.Theme
        local a, b = 0, 0
        T.Animate("k", 1, function() a = a + 1 end)
        T.Animate("k", 1, function() b = b + 1 end)
        T.Advance(0.5)
        assert.equals(1, a)    -- only the initial step(0)
        assert.equals(2, b)
        T.Cancel("k")
        assert.is_false(T.Animating())
    end)

    it("jump to the end when animations are off", function()
        local K = W.start({ skipRoutes = true })
        local T = K.Theme
        K.SetOption("animations", false)
        local last
        T.Animate("off", 5, function(p) last = p end)
        assert.equals(1, last)
        assert.is_false(T.Animating())
    end)
end)

describe("widget kit", function()
    it("builds every widget against the fake client without errors", function()
        local K = W.start({ skipRoutes = true })
        local T = K.Theme
        local parent = CreateFrame("Frame")
        local clicked = 0
        local b = T.Button(parent, "Go", 0, 24, function() clicked = clicked + 1 end, "primary")
        b.scripts.OnClick(b, "LeftButton")
        b:SetDisabled(true)
        b.scripts.OnClick(b, "LeftButton")
        assert.equals(1, clicked)
        T.IconButton(parent, "close", 24, function() end, "tip")
        for _, kind in ipairs({ "close", "menu", "chevron_down", "chevron_up", "check", "plus", "grip" }) do
            T.Glyph(parent, kind, 12, T.c.sub):SetColour(T.c.good)
        end
        local state = false
        local toggle = T.Toggle(parent, "Label", function() return state end, function(v) state = v end, "tip")
        toggle.scripts.OnClick(toggle)
        assert.is_true(state)
        local picked
        local seg = T.Segmented(parent, { { value = 1, text = "a" }, { value = 2, text = "b" } },
            function(v) picked = v end)
        seg:SetValue(2)
        seg.pills[1].scripts.OnClick(seg.pills[1])
        assert.equals(1, picked)
        T.Chip(parent, 10):Set("Optional", T.c.sub)
        T.Progress(parent, 4):SetFraction(0.5, true)
        local s = T.Scroll(parent)
        s:SetContentHeight(1000)
        s:ScrollTo(300)
        assert.equals(300, s.offset)
        s:Wheel(-1)
        assert.is_true(s.offset > 300)
        s:ScrollTo(99999)
        assert.equals(s.contentH - s.viewH, s.offset)
        T.Window(parent)
        T.Grip(parent)
    end)

    it("the pop-up menu opens and closes", function()
        local K = W.start({ skipRoutes = true })
        local T = K.Theme
        assert.has_no.errors(function()
            T.OpenMenu(nil, "Title", { { label = "One", fn = function() end }, { label = "Two", checked = true } })
            T.CloseMenu()
        end)
    end)

    it("scroll offsets notify the owner only when they change", function()
        local K = W.start({ skipRoutes = true })
        local s = K.Theme.Scroll(CreateFrame("Frame"))
        local calls = 0
        s.onScroll = function() calls = calls + 1 end
        s:SetContentHeight(1000)
        s:ScrollTo(100)
        s:ScrollTo(100)
        assert.equals(1, calls)
    end)
end)
