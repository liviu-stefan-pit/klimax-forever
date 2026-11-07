-- Main window (PRD 7.4): one tabbed window with Guide, Steps, Bands and Options pages. Every frame
-- here is ours: no secure frames and no protected calls, so nothing can taint. Frames are built on
-- PLAYER_LOGIN, never at load time. The helpers (U.DisplayIndex, U.Model, U.ListRows, U.BandChoices,
-- U.ResetItems, U.NextValue, U.ButtonWidth, U.ClampScroll, U.ScrollTarget) are plain functions so the
-- busted specs can test them without a client.
local _, K = ...
local L = K.L
local A = K.Arrow

local U = {}
K.UI = U

local FONT = "Fonts\\FRIZQT__.TTF"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local WIDTH, HEIGHT = 380, 470
local PAD = 8
local PAGE_W = WIDTH - 2 * PAD
local PAGE_TOP = 62
local PAGE_H = HEIGHT - PAGE_TOP - PAD
local BAR_W = 10
local BTN_H = 26
local BTN_PAD = 14        -- horizontal padding inside a button, each side
local ROW_MIN = 24
local STATUS_MAX = 80     -- bytes; one hint line on the Guide page
local CHECKLIST_MAX = 10

local TABS = { "guide", "steps", "bands", "options" }
local TAB_LABEL = { guide = "TAB_GUIDE", steps = "TAB_STEPS", bands = "TAB_BANDS", options = "TAB_OPTIONS" }

local BASE, HOVER, ACTIVE = { 0.16, 0.16, 0.16, 0.95 }, { 0.3, 0.3, 0.3, 0.95 }, { 0.55, 0.42, 0.05, 0.95 }

U.fonts = {}          -- font strings with a base size, rescaled by the font option
U.buttons = {}        -- auto-sized buttons, re-measured when the font scale changes
U.focusKey = nil      -- stable key of a pending step the user picked in the step list
U.combatHidden = false
U.tab = "guide"
U.pages = {}
U.lastCursor = nil

-- ---- Options (account-wide, KlimaxDB.options) ----------------------------------------------

local DEFAULTS = {
    showOptional = true, showElite = true, autoAdvance = true, arrow = true, arrowScale = 1,
    hideInCombat = false, locked = false,
    bagThreshold = 3, fontScale = 1, scale = 1, alpha = 0.85, opportunities = true,
}

-- Reads an option with its default. Safe before SavedVariables are loaded.
function K.Option(key)
    local db = K.db
    local v = db and db.options and db.options[key]
    if v == nil then
        return DEFAULTS[key]
    end
    return v
end

function K.SetOption(key, value)
    if K.db then
        K.db.options = K.db.options or {}
        K.db.options[key] = value
    end
end

-- Option rows of the options page. Bool rows toggle; cycle rows step through values.
U.OPTION_ROWS = {
    { key = "showOptional", kind = "bool", label = "OPT_SHOW_OPTIONAL" },
    { key = "showElite", kind = "bool", label = "OPT_SHOW_ELITE" },
    { key = "autoAdvance", kind = "bool", label = "OPT_AUTO" },
    { key = "arrow", kind = "bool", label = "OPT_ARROW" },
    { key = "arrowScale", kind = "cycle", label = "OPT_ARROW_SCALE", values = { 0.75, 1, 1.25, 1.5 } },
    { key = "hideInCombat", kind = "bool", label = "OPT_HIDE_COMBAT" },
    { key = "locked", kind = "bool", label = "OPT_LOCK" },
    { key = "bagThreshold", kind = "cycle", label = "OPT_BAG", values = { 1, 2, 3, 4, 5, 6 } },
    { key = "fontScale", kind = "cycle", label = "OPT_FONT", values = { 0.85, 1, 1.15, 1.3 } },
    { key = "scale", kind = "cycle", label = "OPT_SCALE", values = { 0.8, 0.9, 1, 1.1, 1.25 } },
    { key = "alpha", kind = "cycle", label = "OPT_ALPHA", values = { 0.4, 0.6, 0.85, 1 } },
    { key = "opportunities", kind = "bool", label = "OPT_OPPORTUNITIES" },
}

-- The value after current in values; the first value when current is not in the list.
function U.NextValue(values, current)
    for i = 1, #values do
        if values[i] == current then
            return values[i % #values + 1]
        end
    end
    return values[1]
end

-- The value a row would switch to.
function U.ToggledValue(row)
    local current = K.Option(row.key)
    if row.kind == "bool" then
        return not current
    end
    return U.NextValue(row.values, current)
end

function U.OptionText(row)
    local v = K.Option(row.key)
    if row.kind == "bool" then
        return string.format("[%s] %s", v and "x" or " ", L[row.label])
    end
    return string.format("%s: %s", L[row.label], tostring(v))
end

-- ---- Pure view logic --------------------------------------------------------------------------

-- Cuts text to at most max bytes, ending with "..." and never inside a UTF-8 character.
function U.Clip(text, max)
    text = tostring(text or "")
    if #text <= max then
        return text
    end
    local cut = max - 3
    while cut > 0 do
        local b = text:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return text:sub(1, cut) .. "..."
end

-- Width of a button for a label: the text plus padding on both sides, never below min.
-- Buttons size themselves from their text so a label is never cut off.
function U.ButtonWidth(textWidth, min)
    return math.max(min or 0, math.ceil(textWidth or 0) + 2 * BTN_PAD)
end

-- Scroll offset kept inside the content: 0 up to (content height - view height).
function U.ClampScroll(offset, contentH, viewH)
    return math.max(0, math.min(offset, math.max(0, contentH - viewH)))
end

-- Offset that puts a row near the top third of the view, so the current step has context above it.
function U.ScrollTarget(rowTop, contentH, viewH)
    return U.ClampScroll(rowTop - viewH / 3, contentH, viewH)
end

local ACTION_KEY = {
    A = "ACT_ACCEPT", C = "ACT_COLLECT", T = "ACT_TURNIN", V = "ACT_TRAVEL", F = "ACT_FLY",
    D = "ACT_DISCOVER", B = "ACT_BUY", R = "ACT_TRAINER", H = "ACT_BIND", U = "ACT_HEARTH",
    P = "ACT_REPAIR", N = "ACT_NOTE",
}
local TAG_KEY = { m = "TAG_MAIN", o = "TAG_OPTIONAL", e = "TAG_ELITE" }
local TAG_COLOR = { m = { 1, 0.82, 0 }, o = { 0.62, 0.62, 0.62 }, e = { 1, 0.27, 0.27 } }
local STATE_MARK = { done = "[x]", skipped = "[-]", archived = "[a]", cascade = "[~]", pending = "[ ]" }
local STATE_COLOR = {
    done = { 0.5, 0.5, 0.5 }, skipped = { 0.9, 0.35, 0.35 }, archived = { 0.5, 0.5, 0.5 },
    cascade = { 0.7, 0.55, 0.3 }, pending = { 1, 1, 1 },
}

function U.ActionLabel(step)
    return L[ACTION_KEY[step.t] or "ACT_NONE"]
end

-- Optional and Optional-Elite steps can be hidden by options. Main steps are always shown.
function U.StepShown(step)
    if step.g == "o" then
        return K.Option("showOptional") ~= false
    end
    if step.g == "e" then
        return K.Option("showElite") ~= false
    end
    return true
end

local function gatedNow(step)
    local level = (K.player and K.player.level) or 1
    return step.ml ~= nil and level < step.ml
end

-- Index the window shows: the focused step when it is still pending, else the engine cursor,
-- else the next pending step after it that the options show. nil when there is none.
function U.DisplayIndex(E)
    local steps = E.steps
    if U.focusKey then
        local i = E.byKey[U.focusKey]
        if i and E.eff[i] == "pending" and U.StepShown(steps[i]) then
            return i
        end
    end
    local c = E.cursor
    if not c then
        return nil
    end
    for i = c, #steps do
        if E.eff[i] == "pending" and not gatedNow(steps[i]) and U.StepShown(steps[i]) then
            return i
        end
    end
    return nil
end

-- The view model of the Guide page. kind is one of: none, done, gated, hidden, step.
function U.Model(E)
    local m = { kind = "none" }
    if not E.routeId then
        return m
    end
    if not E.cursor then
        m.kind = "done"
        for i, s in ipairs(E.steps) do
            if E.eff[i] == "pending" and gatedNow(s) then
                m.kind = "gated"
                m.level = s.ml
                break
            end
        end
        return m
    end
    local i = U.DisplayIndex(E)
    if not i then
        m.kind = "hidden"
        return m
    end
    local s = E.steps[i]
    m.kind = "step"
    m.index = i
    m.step = s
    m.action = U.ActionLabel(s)
    m.title = s.n or ""
    m.tag = s.g
    m.tagText = s.g and L[TAG_KEY[s.g]] or nil
    m.note = s.note or ""
    m.stepNo = i
    m.total = #E.steps
    local batch = E:Batch(i)
    if #batch > 1 then
        m.checklist = {}
        local done = 0
        for _, j in ipairs(batch) do
            local state = E.eff[j] or "pending"
            if state == "done" then
                done = done + 1
            end
            m.checklist[#m.checklist + 1] = { index = j, text = E.steps[j].n or "", state = state }
        end
        m.hubDone = done
        m.hubTotal = #batch
    end
    return m
end

-- Rows of the step list for the loaded route: { index, key, state, mark, text, color }.
function U.ListRows(E)
    local rows = {}
    for i, s in ipairs(E.steps) do
        local state = E.eff[i] or "pending"
        local mark = STATE_MARK[state] or "[ ]"
        if i == E.cursor then
            mark = "[>]"
        end
        rows[#rows + 1] = {
            index = i, key = s.k, state = state, mark = mark,
            text = string.format("%d. %s  %s", i, U.ActionLabel(s), s.n or s.note or ""),
            color = (i == E.cursor) and { 1, 0.82, 0 } or STATE_COLOR[state] or { 1, 1, 1 },
        }
    end
    return rows
end

-- Zone name for a uiMapID, or "?".
function U.ZoneName(z)
    local zone = z and K.zones and K.zones[z]
    return zone and zone[1] or "?"
end

-- "Lvl 10–15 · The Barrens" for a loaded route id.
function U.BandLabel(routeId)
    local r = K.routes[routeId]
    if not r then
        return routeId
    end
    local z = r.entry and r.entry.z
    return string.format(L.BAND_LABEL, r.lo or 0, r.hi or 0, U.ZoneName(z))
end

-- Band ids the character can pick: its own branch and the shared horde bands, in level order.
function U.BandChoices(currentId)
    local cur = currentId and K.routes[currentId]
    local branch = cur and cur.branch or "horde"
    local out = {}
    for id, r in pairs(K.routes) do
        if r.branch == branch or r.branch == "horde" then
            out[#out + 1] = id
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = K.routes[a], K.routes[b]
        if ra.lo ~= rb.lo then
            return ra.lo < rb.lo
        end
        return a < b
    end)
    return out
end

-- The reset and audit actions, in page order: reset band, reset guide, audit.
function U.ResetItems()
    return {
        { text = L.MENU_RESET_BAND, fn = function() StaticPopup_Show("KLIMAX_RESET_BAND") end },
        { text = L.MENU_RESET_ALL, fn = function() StaticPopup_Show("KLIMAX_RESET_ALL") end },
        { text = L.MENU_AUDIT, fn = function() K.Audit.Run(true) end },
    }
end

-- Wanted visibility: the saved flag, shown by default.
local function uiState()
    K.cdb = K.cdb or {}
    K.cdb.ui = K.cdb.ui or {}
    return K.cdb.ui
end

function U.Wanted()
    return uiState().shown ~= false
end

-- ---- Frame helpers ----------------------------------------------------------------------------

local function fontString(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size * (K.Option("fontScale") or 1), "")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetJustifyV("TOP")
    U.fonts[#U.fonts + 1] = { fs = fs, base = size }
    return fs
end

local function backdrop(frame, r, g, b, a)
    local t = frame:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetTexture(WHITE)
    t:SetVertexColor(r, g, b, a)
    return t
end

local function paint(b)
    local c = b.active and ACTIVE or (b.hover and not b.off and HOVER) or BASE
    b.bg:SetVertexColor(c[1], c[2], c[3], c[4])
end

-- A button that sizes itself from its label. tip is optional tooltip text.
function U.Button(parent, text, minW, onClick, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(BTN_H)
    b.bg = backdrop(b, BASE[1], BASE[2], BASE[3], BASE[4])
    b.text = fontString(b, 12, "CENTER")
    b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.minW, b.w, b.active, b.hover, b.off = minW or 0, minW or 0, false, false, false
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        self.hover = true
        paint(self)
        if tip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.hover = false
        paint(self)
        GameTooltip:Hide()
    end)
    function b:SetLabel(label)
        self.label = label
        self.text:SetText(label)
        self.w = U.ButtonWidth(self.text:GetStringWidth(), self.minW)
        self:SetWidth(self.w)
    end
    b:SetLabel(text)
    U.buttons[#U.buttons + 1] = b
    return b
end

function U.SetButtonEnabled(b, on)
    b:SetEnabled(on)
    b.off = not on
    if on then
        b.text:SetTextColor(1, 1, 1)
    else
        b.text:SetTextColor(0.5, 0.5, 0.5)
    end
    paint(b)
end

-- Lays buttons out left to right from the bottom-left of parent.
local function layoutRow(list, parent, gap, y)
    local x = 0
    for _, b in ipairs(list) do
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x, y)
        x = x + b.w + gap
    end
end

-- Re-measures every button for the current font scale and re-lays the rows that hold them.
function U.Relayout()
    for _, b in ipairs(U.buttons) do
        b:SetLabel(b.label)
    end
    if U.tabButtons then
        local x = 0
        for _, b in ipairs(U.tabButtons) do
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", U.frame, "TOPLEFT", PAD + x, -34)
            x = x + b.w + 4
        end
    end
    if U.guideButtons then
        layoutRow(U.guideButtons, U.pages.guide, 6, 0)
    end
    if U.bandButtons then
        layoutRow(U.bandButtons, U.pages.bands, 6, 0)
    end
end

-- Saves a frame's position (relative to UIParent) under key in the character's ui table.
local function savePos(frame, key)
    local point, _, rel, x, y = frame:GetPoint()
    uiState()[key] = { point = point, rel = rel, x = x, y = y }
end

local function placeMain(frame)
    frame:ClearAllPoints()
    local p = uiState().pos
    if p and p.point then
        frame:SetPoint(p.point, UIParent, p.rel, p.x, p.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- A scroll area of the given size inside parent, with a draggable thumb and mouse-wheel support.
-- Put children on s.content; call s:SetContentHeight(h) after laying them out.
local function scroller(parent, w, h)
    local viewW = w - BAR_W - 4
    local s = CreateFrame("ScrollFrame", nil, parent)
    s:SetSize(viewW, h)
    local content = CreateFrame("Frame", nil, s)
    content:SetSize(viewW, h)
    s:SetScrollChild(content)
    s.content, s.viewW, s.viewH, s.contentH, s.offset, s.thumbH = content, viewW, h, h, 0, h

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(BAR_W, h)
    bar:SetPoint("TOPLEFT", s, "TOPRIGHT", 4, 0)
    backdrop(bar, 0.08, 0.08, 0.08, 0.9)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(WHITE)
    thumb:SetVertexColor(0.65, 0.52, 0.15, 0.95)
    bar.drag = false
    bar:EnableMouse(true)

    local function paintThumb()
        local range = s.contentH - s.viewH
        if range <= 0 then
            thumb:Hide()
            return
        end
        s.thumbH = math.max(24, s.viewH * s.viewH / s.contentH)
        local y = (s.viewH - s.thumbH) * s.offset / range
        thumb:ClearAllPoints()
        thumb:SetSize(BAR_W, s.thumbH)
        thumb:SetPoint("TOP", bar, "TOP", 0, -y)
        thumb:Show()
    end

    function s:ScrollTo(y)
        self.offset = U.ClampScroll(y, self.contentH, self.viewH)
        self:SetVerticalScroll(self.offset)
        paintThumb()
    end

    function s:SetContentHeight(ch)
        self.contentH = math.max(ch, self.viewH)
        content:SetHeight(self.contentH)
        self:ScrollTo(self.offset)
    end

    function s:Wheel(delta)
        self:ScrollTo(self.offset - delta * 48)
    end

    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta) self:Wheel(delta) end)
    bar:SetScript("OnMouseDown", function(self) self.drag = true end)
    bar:SetScript("OnMouseUp", function(self) self.drag = false end)
    bar:SetScript("OnUpdate", function(self)
        if not self.drag then
            return
        end
        local _, cy = GetCursorPosition()
        local top = self:GetTop()
        if not cy or not top then
            return
        end
        local y = top - cy / self:GetEffectiveScale() - s.thumbH / 2
        local travel = s.viewH - s.thumbH
        if travel > 0 then
            s:ScrollTo(y / travel * (s.contentH - s.viewH))
        end
    end)
    paintThumb()
    return s
end

-- A pooled list row inside a scroller: a full-width button with a wrapped label and a highlight.
local function newRow(s, onClick)
    local r = CreateFrame("Button", nil, s.content)
    r:SetWidth(s.viewW)
    r.hl = backdrop(r, 1, 1, 1, 0.04)
    r.text = fontString(r, 12)
    r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 6, -5)
    r.text:SetWidth(s.viewW - 12)
    r.index, r.id = false, false
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:EnableMouseWheel(true)
    r:SetScript("OnMouseWheel", function(_, delta) s:Wheel(delta) end)
    r:SetScript("OnClick", function(self, mouseButton) onClick(self, mouseButton) end)
    return r
end

-- Sets a row's label and colour, stacks it at y, and returns the height it took.
local function fillRow(r, y, text, color, shade)
    r.text:SetText(text)
    r.text:SetTextColor(color[1], color[2], color[3])
    r.hl:SetVertexColor(shade[1], shade[2], shade[3], shade[4])
    local h = math.max(ROW_MIN, math.ceil(r.text:GetStringHeight() or 14) + 10)
    r:SetHeight(h)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", r:GetParent(), "TOPLEFT", 0, -y)
    r:Show()
    return h
end

local SHADE = { { 1, 1, 1, 0.03 }, { 1, 1, 1, 0.08 } }
local SHADE_CURRENT, SHADE_FOCUS = { 0.6, 0.45, 0.05, 0.45 }, { 0.2, 0.4, 0.6, 0.45 }

-- ---- Actions ----------------------------------------------------------------------------------

-- Marks the displayed step done (and its hub batch).
function U.DoNext()
    local m = U.Model(K.Engine)
    U.focusKey = nil
    if m.index then
        K.Engine:MarkDone(m.index)
    end
    U.Refresh()
end

-- Skips the displayed step; reports how many dependent steps went with it.
function U.DoSkip()
    local m = U.Model(K.Engine)
    U.focusKey = nil
    if m.index then
        local n = K.Engine:Skip(m.index)
        if n > 0 then
            K.Print(string.format(L.SKIPPED, n))
        end
    end
    U.Refresh()
end

function U.JumpBand(routeId)
    U.focusKey = nil
    U.lastCursor = nil
    local ok = K.Engine:JumpToBand(routeId)
    if not ok then
        K.Print(string.format(L.UNKNOWN_BAND, routeId))
    end
    U.ShowTab("guide")
    U.Refresh()
end

function U.Toggle()
    uiState().shown = not U.Wanted()
    U.ApplyVisibility()
end

-- Shows the main window or hides it. The arrow is its own frame: only combat hides it.
function U.ApplyVisibility()
    if not U.frame then
        return
    end
    if U.Wanted() and not U.combatHidden then
        U.frame:Show()
    else
        U.frame:Hide()
    end
    A.allowed = not U.combatHidden
    A.Update()
end

-- Re-applies every appearance option (scale, opacity, font size, arrow size).
function U.ApplyAll()
    if not U.frame then
        return
    end
    U.frame:SetScale(K.Option("scale"))
    U.frame:SetAlpha(K.Option("alpha"))
    for _, e in ipairs(U.fonts) do
        e.fs:SetFont(FONT, e.base * K.Option("fontScale"), "")
    end
    U.frame:EnableMouse(not K.Option("locked"))
    U.Relayout()
    A.Place()
    U.ApplyVisibility()
    U.Refresh()
end

-- ---- Guide page -------------------------------------------------------------------------------

local EMPTY_TEXT = { none = "UI_NO_ROUTE", done = "UI_DONE", hidden = "UI_HIDDEN" }

local function checklistText(list)
    local lines = {}
    for n = 1, math.min(#list, CHECKLIST_MAX) do
        lines[#lines + 1] = string.format("%s %s", STATE_MARK[list[n].state] or "[ ]", list[n].text)
    end
    if #list > CHECKLIST_MAX then
        lines[#lines + 1] = string.format(L.MORE_STEPS, #list - CHECKLIST_MAX)
    end
    return table.concat(lines, "\n")
end

local function refreshGuide(m)
    local g = U.pages.guide
    local ready = m.kind == "step"
    U.SetButtonEnabled(g.next, ready)
    U.SetButtonEnabled(g.skip, ready)
    if ready then
        g.action:SetText(m.action)
        g.title:SetText(m.title)
        g.chip:SetText(m.tagText or "")
        local c = TAG_COLOR[m.tag] or { 1, 1, 1 }
        g.chip:SetTextColor(c[1], c[2], c[3])
        g.note:SetText(m.note)
        if m.checklist then
            g.list:SetText(checklistText(m.checklist))
            g.status:SetText(string.format(L.HUB_PROGRESS, m.hubDone, m.hubTotal))
        else
            g.list:SetText("")
            g.status:SetText(string.format(L.STEP_COUNT, m.stepNo, m.total))
        end
    else
        local text
        if m.kind == "gated" then
            text = string.format(L.UI_GATED, m.level)
        else
            text = L[EMPTY_TEXT[m.kind] or "UI_DONE"]
        end
        g.action:SetText("")
        g.title:SetText(text)
        g.chip:SetText("")
        g.note:SetText("")
        g.list:SetText("")
        g.status:SetText("")
    end
    -- A cursor-step hint (bags, flight path, hearthstone, trainer, supplies) takes the status line.
    local hint = ready and K.Helpers and K.Helpers.CurrentHint()
    if hint then
        g.status:SetText(U.Clip(hint, STATUS_MAX))
        g.status:SetTextColor(1, 0.7, 0.3)
    else
        g.status:SetTextColor(0.6, 0.6, 0.6)
    end
end

local function buildGuide(parent)
    local g = CreateFrame("Frame", nil, parent)
    g:SetSize(PAGE_W, PAGE_H)
    g:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -PAGE_TOP)

    g.action = fontString(g, 12)
    g.action:SetPoint("TOPLEFT", g, "TOPLEFT", 0, 0)
    g.action:SetTextColor(0.6, 0.8, 1)

    g.chip = fontString(g, 12, "RIGHT")
    g.chip:SetPoint("TOPRIGHT", g, "TOPRIGHT", 0, 0)

    g.title = fontString(g, 17)
    g.title:SetPoint("TOPLEFT", g, "TOPLEFT", 0, -22)
    g.title:SetWidth(PAGE_W)

    g.note = fontString(g, 12)
    g.note:SetPoint("TOPLEFT", g.title, "BOTTOMLEFT", 0, -10)
    g.note:SetWidth(PAGE_W)
    g.note:SetTextColor(0.85, 0.85, 0.85)

    g.list = fontString(g, 12)
    g.list:SetPoint("TOPLEFT", g.note, "BOTTOMLEFT", 0, -12)
    g.list:SetWidth(PAGE_W)

    g.status = fontString(g, 11)
    g.status:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 0, BTN_H + 10)
    g.status:SetWidth(PAGE_W)
    g.status:SetTextColor(0.6, 0.6, 0.6)

    g.next = U.Button(g, L.BTN_NEXT, 110, function() U.DoNext() end, L.TIP_NEXT)
    g.skip = U.Button(g, L.BTN_SKIP, 80, function() U.DoSkip() end, L.TIP_SKIP)
    g.sync = U.Button(g, L.BTN_SYNC, 80, function() K.Sync:RunAndReport() end, L.TIP_SYNC)
    U.guideButtons = { g.next, g.skip, g.sync }
    return g
end

-- ---- Steps page -------------------------------------------------------------------------------

local function onStepClick(row, mouseButton)
    local idx = row.index
    if not idx then
        return
    end
    local E = K.Engine
    local step = E.steps[idx]
    local state = E.eff[idx]
    if mouseButton == "RightButton" then
        if state == "skipped" or state == "archived" then
            E:Unskip(step.k)
        end
    elseif state == "pending" then
        U.focusKey = step.k
    end
    U.Refresh()
end

function U.RefreshSteps()
    local pg = U.pages.steps
    local E = K.Engine
    if not pg or U.tab ~= "steps" or not E.routeId then
        return
    end
    local rows = U.ListRows(E)
    local focusIdx = U.focusKey and E.byKey[U.focusKey]
    local y, cursorTop = 0, nil
    for n, data in ipairs(rows) do
        local r = pg.rows[n]
        if not r then
            r = newRow(pg.scroll, onStepClick)
            pg.rows[n] = r
        end
        r.index = data.index
        local shade = SHADE[n % 2 + 1]
        if data.index == E.cursor then
            shade = SHADE_CURRENT
            cursorTop = y
        elseif data.index == focusIdx then
            shade = SHADE_FOCUS
        end
        y = y + fillRow(r, y, data.mark .. " " .. data.text, data.color, shade)
    end
    for n = #rows + 1, #pg.rows do
        pg.rows[n].index = false
        pg.rows[n]:Hide()
    end
    pg.scroll:SetContentHeight(y)
    if cursorTop and (pg.follow or E.cursor ~= U.lastCursor) then
        pg.scroll:ScrollTo(U.ScrollTarget(cursorTop, y, pg.scroll.viewH))
    end
    pg.follow = false
    U.lastCursor = E.cursor
end

local function buildSteps(parent)
    local pg = CreateFrame("Frame", nil, parent)
    pg:SetSize(PAGE_W, PAGE_H)
    pg:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -PAGE_TOP)
    pg.hint = fontString(pg, 11)
    pg.hint:SetPoint("TOPLEFT", pg, "TOPLEFT", 0, 0)
    pg.hint:SetWidth(PAGE_W)
    pg.hint:SetTextColor(0.6, 0.6, 0.6)
    pg.hint:SetText(L.LIST_HINT)
    pg.scroll = scroller(pg, PAGE_W, PAGE_H - 36)
    pg.scroll:SetPoint("TOPLEFT", pg, "TOPLEFT", 0, -36)
    pg.rows, pg.follow = {}, true
    return pg
end

-- ---- Bands page -------------------------------------------------------------------------------

local function onBandClick(row)
    if row.id then
        U.JumpBand(row.id)
    end
end

function U.RefreshBands()
    local pg = U.pages.bands
    if not pg or U.tab ~= "bands" then
        return
    end
    local cur = K.Engine.routeId
    local y, curTop = 0, nil
    local ids = U.BandChoices(cur)
    for n, id in ipairs(ids) do
        local r = pg.rows[n]
        if not r then
            r = newRow(pg.scroll, onBandClick)
            pg.rows[n] = r
        end
        r.id = id
        local shade, color = SHADE[n % 2 + 1], { 1, 1, 1 }
        if id == cur then
            shade, color, curTop = SHADE_CURRENT, { 1, 0.82, 0 }, y
        end
        y = y + fillRow(r, y, U.BandLabel(id), color, shade)
    end
    for n = #ids + 1, #pg.rows do
        pg.rows[n].id = false
        pg.rows[n]:Hide()
    end
    pg.scroll:SetContentHeight(y)
    if curTop and pg.follow then
        pg.scroll:ScrollTo(U.ScrollTarget(curTop, y, pg.scroll.viewH))
    end
    pg.follow = false
end

local function buildBands(parent)
    local pg = CreateFrame("Frame", nil, parent)
    pg:SetSize(PAGE_W, PAGE_H)
    pg:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -PAGE_TOP)
    pg.scroll = scroller(pg, PAGE_W, PAGE_H - BTN_H - 10)
    pg.scroll:SetPoint("TOPLEFT", pg, "TOPLEFT", 0, 0)
    pg.rows, pg.follow = {}, true
    local items = U.ResetItems()
    pg.resetBand = U.Button(pg, items[1].text, 0, items[1].fn)
    pg.resetAll = U.Button(pg, items[2].text, 0, items[2].fn)
    U.bandButtons = { pg.resetBand, pg.resetAll }
    return pg
end

-- ---- Options page -----------------------------------------------------------------------------

local function onOptionClick(row)
    local def = row.index and U.OPTION_ROWS[row.index]
    if def then
        K.SetOption(def.key, U.ToggledValue(def))
        U.ApplyAll()
    end
end

function U.RefreshOptions()
    local pg = U.pages.options
    if not pg or U.tab ~= "options" then
        return
    end
    local y = 0
    for n, def in ipairs(U.OPTION_ROWS) do
        local r = pg.rows[n]
        if not r then
            r = newRow(pg.scroll, onOptionClick)
            pg.rows[n] = r
        end
        r.index = n
        y = y + fillRow(r, y, U.OptionText(def), { 1, 1, 1 }, SHADE[n % 2 + 1])
    end
    pg.scroll:SetContentHeight(y)
end

local function buildOptions(parent)
    local pg = CreateFrame("Frame", nil, parent)
    pg:SetSize(PAGE_W, PAGE_H)
    pg:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -PAGE_TOP)
    pg.scroll = scroller(pg, PAGE_W, PAGE_H - BTN_H - 10)
    pg.scroll:SetPoint("TOPLEFT", pg, "TOPLEFT", 0, 0)
    pg.rows = {}
    local audit = U.ResetItems()[3]
    pg.audit = U.Button(pg, audit.text, 0, audit.fn)
    pg.audit:SetPoint("BOTTOMLEFT", pg, "BOTTOMLEFT", 0, 0)
    return pg
end

-- ---- Tabs and refresh -------------------------------------------------------------------------

function U.ShowTab(name)
    local valid = false
    for _, t in ipairs(TABS) do
        valid = valid or t == name
    end
    if not valid then
        name = "guide"
    end
    U.tab = name
    uiState().tab = name
    for _, t in ipairs(TABS) do
        local pg = U.pages[t]
        if pg then
            pg:SetShown(t == name)
        end
    end
    for i, b in ipairs(U.tabButtons or {}) do
        b.active = TABS[i] == name
        paint(b)
    end
    if U.pages.steps then
        U.pages.steps.follow = true
    end
    if U.pages.bands then
        U.pages.bands.follow = true
    end
    U.Refresh()
end

function U.Refresh()
    local f = U.frame
    if not f then
        return
    end
    local m = U.Model(K.Engine)
    f.band:SetText(K.Engine.routeId and U.BandLabel(K.Engine.routeId) or "")
    refreshGuide(m)
    U.RefreshSteps()
    U.RefreshBands()
    U.RefreshOptions()
    A.Update()
end

-- ---- Main frame -------------------------------------------------------------------------------

local function registerPopups()
    StaticPopupDialogs["KLIMAX_RESET_BAND"] = {
        text = L.CONFIRM_RESET_BAND,
        button1 = L.YES,
        button2 = L.NO,
        OnAccept = function()
            K.Engine:Reset("band")
            K.Print(string.format(L.RESET_BAND, K.Engine.routeId or "?"))
            U.focusKey = nil
            U.Refresh()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs["KLIMAX_RESET_ALL"] = {
        text = L.CONFIRM_RESET_ALL,
        button1 = L.YES,
        button2 = L.NO,
        OnAccept = function()
            K.Engine:Reset("all")
            K.Print(L.RESET_ALL)
            U.focusKey = nil
            U.Refresh()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local function buildMain()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    backdrop(f, 0, 0, 0, 0.85)

    -- Drag: left-drag anywhere on the window that is not a button. Locked windows ignore drags.
    -- The window takes mouse input only while unlocked, so a locked window does not block the world.
    f:EnableMouse(not K.Option("locked"))
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if not K.Option("locked") then
            f:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        savePos(f, "pos")
    end)

    -- Header: name, band label, close button, and a rule under it.
    f.name = fontString(f, 15)
    f.name:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 2, -10)
    f.name:SetText(L.ADDON_NAME)
    f.name:SetTextColor(1, 0.82, 0)
    f.band = fontString(f, 11)
    f.band:SetPoint("LEFT", f.name, "RIGHT", 12, 0)
    f.band:SetWidth(WIDTH - 130)
    f.band:SetTextColor(0.75, 0.75, 0.75)
    f.close = U.Button(f, "X", 26, function() U.Toggle() end, L.TIP_CLOSE)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -6)
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetTexture(WHITE)
    rule:SetVertexColor(0.6, 0.5, 0.2, 0.8)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -32)
    rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -32)
    return f
end

function U.Build()
    if U.frame then
        return
    end
    registerPopups()
    local f = buildMain()
    U.frame = f
    placeMain(f)
    U.tabButtons = {}
    for i, t in ipairs(TABS) do
        U.tabButtons[i] = U.Button(f, L[TAB_LABEL[t]], 70, function() U.ShowTab(t) end)
    end
    U.pages.guide = buildGuide(f)
    U.pages.steps = buildSteps(f)
    U.pages.bands = buildBands(f)
    U.pages.options = buildOptions(f)
    A.Build()
    K.Engine:OnChange(function()
        U.Refresh()
    end)
    U.ShowTab(uiState().tab or "guide")
    U.ApplyAll()
end

-- ---- Events -----------------------------------------------------------------------------------

K.On("PLAYER_LOGIN", function()
    U.Build()
    U.Refresh()
end)

K.On("PLAYER_REGEN_DISABLED", function()
    if K.Option("hideInCombat") and U.frame then
        U.combatHidden = true
        U.ApplyVisibility()
    end
end)

K.On("PLAYER_REGEN_ENABLED", function()
    if U.combatHidden then
        U.combatHidden = false
        U.ApplyVisibility()
    end
end)
