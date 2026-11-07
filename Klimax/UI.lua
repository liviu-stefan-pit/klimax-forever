-- Main window, step list, menu and options (PRD 7.4). Every frame here is ours: no secure
-- frames and no protected calls, so nothing can taint. Frames are built on PLAYER_LOGIN, never at
-- load time. The helpers (U.DisplayIndex, U.Model, U.ListRows, U.BandChoices, U.MenuItems,
-- U.NextValue) are plain functions so the busted specs can test them without a client.
local _, K = ...
local L = K.L
local A = K.Arrow

local U = {}
K.UI = U

local FONT = "Fonts\\FRIZQT__.TTF"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local WIDTH, HEIGHT = 300, 100
local LIST_ROWS = 16
local MENU_ROWS = 18
local ROW_H = 14
local TITLE_MAX = 40   -- bytes; one line at the title size
local NOTE_MAX = 92    -- bytes; two lines at the note size
local STATUS_MAX = 54  -- bytes; one line at the status size, for cursor-step hints

U.fonts = {}          -- font strings with a base size, rescaled by the font option
U.focusKey = nil      -- stable key of a pending step the user picked in the step list
U.listOffset = 0
U.combatHidden = false

-- ---- Options (account-wide, KlimaxDB.options) ----------------------------------------------

local DEFAULTS = {
    showOptional = true, showElite = true, autoAdvance = true, arrow = true,
    arrowDetached = false, hideInCombat = false, locked = false,
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

-- Option rows of the options window. Bool rows toggle; cycle rows step through values.
U.OPTION_ROWS = {
    { key = "showOptional", kind = "bool", label = "OPT_SHOW_OPTIONAL" },
    { key = "showElite", kind = "bool", label = "OPT_SHOW_ELITE" },
    { key = "autoAdvance", kind = "bool", label = "OPT_AUTO" },
    { key = "arrow", kind = "bool", label = "OPT_ARROW" },
    { key = "arrowDetached", kind = "bool", label = "OPT_ARROW_DETACH" },
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
-- The window has fixed-height text areas; clipping keeps long quest names and notes off the buttons.
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

-- The view model of the main window. kind is one of: none, done, gated, hidden, step.
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

-- Items of a menu page: { {text, fn}, ... }. Pages are "main" and "bands".
function U.MenuItems(page)
    if page == "bands" then
        local items = { { text = L.BTN_BACK, fn = function() U.SetMenuPage("main") end } }
        local cur = K.Engine.routeId
        for _, id in ipairs(U.BandChoices(cur)) do
            items[#items + 1] = {
                text = (id == cur and "> " or "  ") .. U.BandLabel(id),
                fn = function() U.JumpBand(id) end,
            }
        end
        return items
    end
    return {
        { text = L.MENU_RESET_BAND, fn = function() U.CloseMenu(); StaticPopup_Show("KLIMAX_RESET_BAND") end },
        { text = L.MENU_RESET_ALL, fn = function() U.CloseMenu(); StaticPopup_Show("KLIMAX_RESET_ALL") end },
        { text = L.MENU_BANDS, fn = function() U.SetMenuPage("bands") end },
        { text = L.MENU_STEPS, fn = function() U.CloseMenu(); U.ShowSteps() end },
        { text = L.MENU_OPTIONS, fn = function() U.CloseMenu(); U.ShowOptions() end },
        { text = L.MENU_AUDIT, fn = function() U.CloseMenu(); K.Audit.Run(true) end },
        { text = L.MENU_CLOSE, fn = function() U.CloseMenu() end },
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
    fs:SetFont(FONT, size, "")
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

local function tooltip(frame, text)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(text)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    backdrop(b, 0.15, 0.15, 0.15, 0.9)
    b.text = fontString(b, 10, "CENTER")
    b.text:SetAllPoints()
    b.text:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
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
        frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
end

-- A small popup window anchored to the right of the main window, with a title and a close button.
local function popup(height, title)
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(260, height)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetPoint("TOPLEFT", U.frame, "TOPRIGHT", 6, 0)
    backdrop(f, 0, 0, 0, 0.92)
    f.title = fontString(f, 11)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
    f.title:SetText(title)
    f:Hide()
    return f
end

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
    U.CloseMenu()
    U.focusKey = nil
    U.listOffset = 0
    local ok = K.Engine:JumpToBand(routeId)
    if not ok then
        K.Print(string.format(L.UNKNOWN_BAND, routeId))
    end
    U.Refresh()
end

function U.Toggle()
    uiState().shown = not U.Wanted()
    U.ApplyVisibility()
end

-- Shows the main window or hides it, and the arrow with it (combat hides both).
function U.ApplyVisibility()
    if not U.frame then
        return
    end
    local show = U.Wanted() and not U.combatHidden
    if show then
        U.frame:Show()
    else
        U.frame:Hide()
        U.CloseMenu()
    end
    A.allowed = show
    A.Update()
end

-- Re-applies every appearance option (scale, opacity, font size, arrow placement).
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
    A.Place(U.frame)
    U.ApplyVisibility()
    U.Refresh()
    U.RenderOptions()
end

-- ---- Main window refresh ----------------------------------------------------------------------

local EMPTY_TEXT = { none = "UI_NO_ROUTE", done = "UI_DONE", hidden = "UI_HIDDEN" }

function U.Refresh()
    local f = U.frame
    if not f then
        return
    end
    local m = U.Model(K.Engine)
    local ready = m.kind == "step"
    f.next:SetEnabled(ready)
    f.skip:SetEnabled(ready)
    if ready then
        f.action:SetText(m.action)
        f.title:SetText(U.Clip(m.title, TITLE_MAX))
        f.chip:SetText(m.tagText or "")
        local c = TAG_COLOR[m.tag] or { 1, 1, 1 }
        f.chip:SetTextColor(c[1], c[2], c[3])
        if m.checklist then
            local lines = {}
            for n = 1, math.min(#m.checklist, 2) do
                local item = m.checklist[n]
                lines[#lines + 1] = string.format("%s %s", STATE_MARK[item.state] or "[ ]", item.text)
            end
            if #m.checklist > 2 then
                lines[#lines + 1] = string.format("+ %d more", #m.checklist - 2)
            end
            f.note:SetText(table.concat(lines, "\n"))
            f.status:SetText(string.format(L.HUB_PROGRESS, m.hubDone, m.hubTotal))
        else
            f.note:SetText(U.Clip(m.note, NOTE_MAX))
            f.status:SetText(string.format(L.STEP_COUNT, m.stepNo, m.total))
        end
    else
        local text
        if m.kind == "gated" then
            text = string.format(L.UI_GATED, m.level)
        else
            text = L[EMPTY_TEXT[m.kind] or "UI_DONE"]
        end
        f.action:SetText("")
        f.title:SetText(text)
        f.chip:SetText("")
        f.note:SetText("")
        f.status:SetText("")
    end
    -- A cursor-step hint (bags, flight path, hearthstone, trainer, supplies) takes the status line.
    local hint = ready and K.Helpers and K.Helpers.CurrentHint()
    if hint then
        f.status:SetText(U.Clip(hint, STATUS_MAX))
        f.status:SetTextColor(1, 0.7, 0.3)
    else
        f.status:SetTextColor(0.6, 0.6, 0.6)
    end
    U.RefreshSteps()
    A.Update()
end

-- ---- Step list window -------------------------------------------------------------------------

function U.RefreshSteps()
    local sf = U.steps
    if not sf or not K.Engine.routeId then
        return
    end
    local rows = U.ListRows(K.Engine)
    local maxOff = math.max(0, #rows - LIST_ROWS)
    U.listOffset = math.max(0, math.min(U.listOffset, maxOff))
    for n = 1, LIST_ROWS do
        local r = U.listRows[n]
        local data = rows[U.listOffset + n]
        if data then
            r.index = data.index
            r.text:SetText(data.mark .. " " .. data.text)
            r.text:SetTextColor(data.color[1], data.color[2], data.color[3])
            r:Show()
        else
            r.index = nil
            r:Hide()
        end
    end
end

local function onRowClick(row, mouseButton)
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

local function buildSteps()
    local f = popup(LIST_ROWS * ROW_H + 40, L.LIST_TITLE)
    f.hint = fontString(f, 9)
    f.hint:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -20)
    f.hint:SetText(L.LIST_HINT)
    f:EnableMouseWheel(true)
    local function wheel(_, delta)
        U.listOffset = U.listOffset - delta * 3
        U.RefreshSteps()
    end
    f:SetScript("OnMouseWheel", wheel)
    U.listRows = {}
    for n = 1, LIST_ROWS do
        local r = CreateFrame("Button", nil, f)
        r:SetSize(244, ROW_H)
        r:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -34 - (n - 1) * ROW_H)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:EnableMouseWheel(true)
        r:SetScript("OnMouseWheel", wheel)
        r:SetScript("OnClick", function(self, mouseButton) onRowClick(self, mouseButton) end)
        r.text = fontString(r, 9)
        r.text:SetAllPoints()
        U.listRows[n] = r
    end
    U.steps = f
end

function U.ShowSteps()
    if not U.steps then
        return
    end
    U.steps:SetShown(not U.steps:IsShown())
    U.RefreshSteps()
end

-- ---- Menu -------------------------------------------------------------------------------------

function U.SetMenuPage(page)
    U.menuPage = page
    U.RenderMenu()
end

function U.RenderMenu()
    local items = U.MenuItems(U.menuPage or "main")
    for n = 1, MENU_ROWS do
        local b = U.menuRows[n]
        local it = items[n]
        if it then
            b.text:SetText(it.text)
            b:SetScript("OnClick", function() it.fn() end)
            b:Show()
        else
            b:Hide()
        end
    end
end

function U.CloseMenu()
    if U.menu then
        U.menu:Hide()
    end
end

function U.ToggleMenu()
    if not U.menu then
        return
    end
    if U.menu:IsShown() then
        U.menu:Hide()
    else
        U.menuPage = "main"
        U.RenderMenu()
        U.menu:Show()
    end
end

local function buildMenu()
    local f = popup(MENU_ROWS * 16 + 28, L.BTN_MENU)
    U.menuRows = {}
    for n = 1, MENU_ROWS do
        local b = button(f, "", 244, 15, function() end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22 - (n - 1) * 16)
        b.text:SetJustifyH("LEFT")
        U.menuRows[n] = b
    end
    U.menu = f
end

-- ---- Options window ---------------------------------------------------------------------------

function U.RenderOptions()
    local f = U.options
    if not f then
        return
    end
    for n, row in ipairs(U.OPTION_ROWS) do
        local b = f.rows[n]
        b.text:SetText(U.OptionText(row))
    end
end

function U.ShowOptions()
    if not U.options then
        return
    end
    U.options:SetShown(not U.options:IsShown())
    U.RenderOptions()
end

local function buildOptions()
    local f = popup(#U.OPTION_ROWS * 18 + 30, L.OPT_TITLE)
    f.rows = {}
    for n, row in ipairs(U.OPTION_ROWS) do
        local b = button(f, "", 244, 16, function()
            K.SetOption(row.key, U.ToggledValue(row))
            U.ApplyAll()
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22 - (n - 1) * 18)
        b.text:SetJustifyH("LEFT")
        f.rows[n] = b
    end
    U.options = f
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
    backdrop(f, 0, 0, 0, 0.8)

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
    -- Title strip (decoration only; dragging works on the whole window).
    local handle = CreateFrame("Frame", nil, f)
    handle:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    handle:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    handle:SetHeight(14)
    f.handle = handle
    handle.title = fontString(handle, 9)
    handle.title:SetPoint("LEFT", handle, "LEFT", 6, 0)
    handle.title:SetText(L.ADDON_NAME)

    f.action = fontString(f, 10)
    f.action:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -17)
    f.action:SetTextColor(0.6, 0.8, 1)

    f.chip = fontString(f, 10, "RIGHT")
    f.chip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -17)

    f.title = fontString(f, 12)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -30)
    f.title:SetWidth(WIDTH - 16)

    f.note = fontString(f, 10)
    f.note:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -46)
    f.note:SetWidth(WIDTH - 16)
    f.note:SetTextColor(0.8, 0.8, 0.8)

    f.status = fontString(f, 9)
    f.status:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -74)
    f.status:SetTextColor(0.6, 0.6, 0.6)

    local bw, gap = 66, 4
    local x = (WIDTH - (4 * bw + 3 * gap)) / 2
    f.next = button(f, L.BTN_NEXT, bw, 18, function() U.DoNext() end)
    f.skip = button(f, L.BTN_SKIP, bw, 18, function() U.DoSkip() end)
    f.sync = button(f, L.BTN_SYNC, bw, 18, function() K.Sync:RunAndReport() end)
    f.menu = button(f, L.BTN_MENU, bw, 18, function() U.ToggleMenu() end)
    local row = { f.next, f.skip, f.sync, f.menu }
    local tips = { L.TIP_NEXT, L.TIP_SKIP, L.TIP_SYNC, L.TIP_MENU }
    for n, b in ipairs(row) do
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x + (n - 1) * (bw + gap), 6)
        tooltip(b, tips[n])
    end
    return f
end

function U.Build()
    if U.frame then
        return
    end
    registerPopups()
    U.frame = buildMain()
    placeMain(U.frame)
    buildSteps()
    buildMenu()
    buildOptions()
    A.Build(U.frame)
    K.Engine:OnChange(function()
        U.Refresh()
    end)
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
