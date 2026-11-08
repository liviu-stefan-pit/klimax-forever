-- Main window (UI overhaul phases 12 and 13). One resizable, scrollable window in the Klimax theme:
--
--   header   title, level and zone, menu / collapse / close
--   hero     the current step as a card: badge, action, title, note, live objectives, why, NPC link,
--            Done and Skip. It fades in when the step changes (the "dialogue" card)
--   tabs     Steps | Ahead | Skipped
--   list     the plan as cards, virtualised (only the visible rows have frames), current step
--            highlighted, auto-scrolled to, right-click for the step menu
--   footer   progress bar, step count, resize grip
--
-- Every frame is ours (no secure frames, no protected calls). Frames are built on PLAYER_LOGIN, never
-- at load time. The helpers (DisplayIndex, Model, ListRows, RowHeight, ObjectiveText, ResetItems...)
-- are plain functions so the busted specs test them without a client.
local _, K = ...
local L = K.L
local A = K.Arrow
local T = K.Theme
local c = T.c

local U = {}
K.UI = U

local DEFAULT_W, DEFAULT_H = 400, 580
local MIN_W, MIN_H, MAX_W, MAX_H = 340, 300, 720, 1000
local HEAD_H, FOOT_H, PAD = 46, 30, 12
local HERO_PAD = 14
local ROW_GAP = 4
local ROW_TEXT_L, ROW_TEXT_R = 46, 40
local OVERSCAN = 160

U.focusKey = nil      -- stable key of a pending step the user picked in the step list
U.combatHidden = false
U.tab = "steps"
U.collapsed = false
U.lastCursor = nil
U.userScrollAt = -100

U.TABS = { "steps", "ahead", "skipped" }

-- Pure aliases kept for the specs and the other windows.
U.ClampScroll = T.ClampScroll
U.ScrollTarget = T.ScrollTarget
U.ButtonWidth = T.ButtonWidth

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

local ACTION_KEY = {
    A = "ACT_ACCEPT", C = "ACT_COLLECT", T = "ACT_TURNIN", V = "ACT_TRAVEL", F = "ACT_FLY",
    D = "ACT_DISCOVER", B = "ACT_BUY", R = "ACT_TRAINER", H = "ACT_BIND", U = "ACT_HEARTH",
    P = "ACT_REPAIR", N = "ACT_NOTE", S = "ACT_STOP",
}
local TAG_KEY = { m = "TAG_MAIN", o = "TAG_OPTIONAL", e = "TAG_ELITE" }
local TAG_COLOUR = { m = c.accent, o = c.sub, e = c.mob }

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
    local cur = E.cursor
    if not cur then
        return nil
    end
    for i = cur, #steps do
        if E.eff[i] == "pending" and not gatedNow(steps[i]) and U.StepShown(steps[i]) then
            return i
        end
    end
    return nil
end

-- Zone name for a uiMapID, or "?".
function U.ZoneName(z)
    local zone = z and K.zones and K.zones[z]
    return zone and zone[1] or "?"
end

-- The name of the NPC of a step, or nil.
function U.NpcName(step)
    local npc = step and step.npc and K.WorldDB and K.WorldDB.Npc(step.npc)
    return npc and npc.n or nil
end

-- The quest's objective lines from the quest log: {text, finished}. Empty when the quest is not in
-- the log (an Accept step) or the step has no quest.
function U.Objectives(step)
    local out = {}
    if not (step and step.q and K.Compat and K.Compat.GetQuestLogLines) then
        return out
    end
    for _, line in ipairs((K.Compat.GetQuestLogLines(true))) do
        if line.questID == step.q then
            for _, o in ipairs(line.objectives or {}) do
                if o.text and o.text ~= "" then
                    out[#out + 1] = { text = o.text, finished = o.finished and true or false }
                end
            end
            break
        end
    end
    return out
end

local function hex(col)
    return string.format("%02x%02x%02x", math.floor(col[1] * 255 + 0.5), math.floor(col[2] * 255 + 0.5),
        math.floor(col[3] * 255 + 0.5))
end

-- Objective lines as one coloured string: finished ones green with a check, open ones white.
function U.ObjectiveText(list)
    local lines = {}
    for _, o in ipairs(list or {}) do
        if o.finished then
            lines[#lines + 1] = string.format("|cff%s+ %s|r", hex(c.good), o.text)
        else
            lines[#lines + 1] = string.format("|cff%s- |r%s", hex(c.dim), o.text)
        end
    end
    return table.concat(lines, "\n")
end

-- The planner's step for the same task as a displayed step (same kind and quest), or nil. Reads the
-- plan already built; it never forces a replan (phase 27: the "why" of a step card).
function U.PlanStepFor(step)
    local plan = K.Planner and K.Planner.plan
    if not (plan and step and step.q) then
        return nil
    end
    for _, ps in ipairs(plan.steps) do
        if ps.q == step.q and ps.t == step.t then
            return ps
        end
    end
    return nil
end

-- The view model of the hero card. kind is one of: none, done, gated, hidden, step.
function U.Model(E)
    local m = { kind = "none" }
    if not E.routeId then
        return m
    end
    if not E.cursor then
        m.kind = "done"
        for _, s in ipairs(E.steps) do
            if gatedNow(s) then
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
    m.key = s.k
    m.step = s
    m.stepType = s.t
    m.action = U.ActionLabel(s)
    m.title = s.n or ""
    m.tag = s.g
    m.tagText = s.g and L[TAG_KEY[s.g]] or nil
    m.note = s.note or ""
    if m.note == m.title then
        m.note = ""
    end
    m.planStep = U.PlanStepFor(s)
    m.why = m.planStep and K.Planner.Why(m.planStep) or ""
    m.stepNo = i
    m.total = #E.steps
    m.npc = U.NpcName(s)
    m.zone = (s.z or s.to) and U.ZoneName(s.z or s.to) or nil
    m.objectives = U.Objectives(s)
    m.progress = (i - 1) / math.max(1, #E.steps)
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
        m.progress = (i - 1 + done / #batch) / math.max(1, #E.steps)
    end
    return m
end

-- Rows of the Steps list for the loaded route. Each row: index, key, state, kind (step type), badge
-- glyph, title, sub (NPC and zone), num, current, text (plain one-liner for tooltips and specs).
function U.ListRows(E)
    local rows = {}
    for i, s in ipairs(E.steps) do
        local state = E.eff[i] or "pending"
        local badge = T.Badge(s.t)
        local sub = {}
        local npc = U.NpcName(s)
        if npc then
            sub[#sub + 1] = npc
        end
        if s.z or s.to then
            sub[#sub + 1] = U.ZoneName(s.z or s.to)
        end
        rows[#rows + 1] = {
            index = i, key = s.k, state = state, kind = s.t, glyph = badge[1], tint = badge[2],
            action = U.ActionLabel(s), title = s.n or s.note or "", sub = table.concat(sub, " · "),
            npc = npc, num = tostring(i), current = (i == E.cursor),
            text = string.format("%d. %s  %s", i, U.ActionLabel(s), s.n or s.note or ""),
        }
    end
    return rows
end

-- The height of a list row at a pixel width: padding, the title lines, and the sub line.
function U.RowHeight(d, width)
    local textW = width - (d.plain and 24 or (ROW_TEXT_L + ROW_TEXT_R))
    local lines = math.max(1, T.TextLines(d.title, textW, 12))
    local h = 16 + lines * 15
    if d.sub and d.sub ~= "" then
        h = h + 14
    end
    return math.max(d.plain and 30 or 42, h)
end

-- Rows of the Ahead tab: the stops coming up and the zone changes (phase 27 forecast).
function U.PlanRows()
    local plan = K.Engine.plan
    if not (plan and K.Planner and K.Plan.Explain) then
        return {}
    end
    local env = K.Planner.ExplainEnv()
    return K.Plan.Explain.ForecastLines(K.Plan.Explain.Forecast(plan, env), env)
end

-- Rows of the "Skipped" tab (phase 22): one per skipped quest, click to restore.
function U.SkippedRows()
    local rows = {}
    for _, item in ipairs(K.StepMenu and K.StepMenu.SkippedQuests() or {}) do
        rows[#rows + 1] = { q = item.q, text = string.format(L.SKIPPED_ROW, item.name, item.q) }
    end
    return rows
end

-- "Level 12 · The Barrens": the character's level and the zone of the first step of the plan.
function U.PlanLabel()
    local level = (K.player and K.player.level) or 1
    local _, step = K.Engine:Current()
    local z = step and (step.z or step.to)
    if z then
        return string.format(L.PLAN_LABEL, level, U.ZoneName(z))
    end
    return string.format(L.PLAN_LABEL_BARE, level)
end

-- The reset and resync actions, in page order: clear skipped steps, reset guide, resync.
function U.ResetItems()
    return {
        { text = L.MENU_RESET_BAND, fn = function() StaticPopup_Show("KLIMAX_RESET_BAND") end },
        { text = L.MENU_RESET_ALL, fn = function() StaticPopup_Show("KLIMAX_RESET_ALL") end },
        { text = L.MENU_RESYNC, fn = function() K.Resync() end },
    }
end

-- Saved window state (per character): shown, pos, size, tab, collapsed, arrowPos.
local function uiState()
    K.cdb = K.cdb or {}
    K.cdb.ui = K.cdb.ui or {}
    return K.cdb.ui
end

function U.Wanted()
    return uiState().shown ~= false
end

-- Window size kept inside the allowed bounds.
function U.ClampSize(w, h)
    return T.Clamp(math.floor((w or DEFAULT_W) + 0.5), MIN_W, MAX_W),
        T.Clamp(math.floor((h or DEFAULT_H) + 0.5), MIN_H, MAX_H)
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

-- Skips the displayed step.
function U.DoSkip()
    local m = U.Model(K.Engine)
    U.focusKey = nil
    if m.index then
        K.Engine:Skip(m.index)
    end
    U.Refresh()
end

function U.Toggle()
    uiState().shown = not U.Wanted()
    U.ApplyVisibility()
end

function U.Show()
    uiState().shown = true
    U.ApplyVisibility()
end

-- Shows the main window or hides it. The arrow is its own frame: only combat hides it.
function U.ApplyVisibility()
    if not U.frame then
        return
    end
    if U.Wanted() and not U.combatHidden then
        if not U.frame:IsShown() then
            U.frame:Show()
            U.frame:SetAlpha(0)
            T.Animate("window", 0.2, function(p)
                U.frame:SetAlpha(T.Ease(p) * K.Option("alpha"))
            end)
        end
    else
        U.frame:Hide()
    end
    A.allowed = not U.combatHidden
    A.Update()
end

local function savePos(frame)
    local point, _, rel, x, y = frame:GetPoint()
    uiState().pos = { point = point, rel = rel, x = x, y = y }
end

local function saveSize(frame)
    local w, h = frame:GetWidth(), frame:GetHeight()
    if w and h and not U.collapsed then
        local cw, ch = U.ClampSize(w, h)
        uiState().size = { w = cw, h = ch }
    end
end

local function placeMain(frame)
    frame:ClearAllPoints()
    local p = uiState().pos
    if p and p.point then
        frame:SetPoint(p.point, UIParent, p.rel, p.x, p.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    local sz = uiState().size
    local w, h = U.ClampSize(sz and sz.w, sz and sz.h)
    frame:SetSize(w, h)
end

-- Forgets the saved positions and sizes of the window and the arrow.
function U.ResetPlacement()
    local st = uiState()
    st.pos, st.size, st.arrowPos = nil, nil, nil
    U.collapsed = false
    st.collapsed = false
    if U.frame then
        placeMain(U.frame)
        U.Relayout()
    end
    A.Place()
end

-- ---- Row pool ---------------------------------------------------------------------------------

local function newRow(scroll)
    local r = CreateFrame("Button", nil, scroll.content)
    r.data, r.hover = false, false
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.surface = T.Surface(r, c.card, { 1, 1, 1, 0 })
    r.stripe = r:CreateTexture(nil, "ARTWORK")
    r.stripe:SetTexture(T.WHITE)
    r.stripe:SetWidth(3)
    r.stripe:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.stripe:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
    r.badgeBox = CreateFrame("Frame", nil, r)
    r.badgeBox:SetSize(24, 24)
    r.badgeBox:SetPoint("TOPLEFT", r, "TOPLEFT", 12, -9)
    r.badgeBg = r.badgeBox:CreateTexture(nil, "ARTWORK")
    r.badgeBg:SetAllPoints(r.badgeBox)
    r.badgeBg:SetTexture(T.WHITE)
    r.glyph = T.Text(r.badgeBox, 14, c.text, "CENTER", true)
    r.glyph:SetPoint("CENTER", r.badgeBox, "CENTER", 0, -1)
    r.check = T.Glyph(r.badgeBox, "check", 14, c.good)
    r.title = T.Text(r, 12, c.text)
    r.title:SetPoint("TOPLEFT", r, "TOPLEFT", ROW_TEXT_L, -8)
    r.sub = T.Text(r, 11, c.sub)
    r.num = T.Text(r, 10, c.dim, "RIGHT")
    r.num:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -10)
    r:EnableMouseWheel(true)
    r:SetScript("OnMouseWheel", function(_, delta)
        scroll:Wheel(delta)
    end)
    r:SetScript("OnEnter", function(self)
        self.hover = true
        U.PaintRow(self)
        local d = self.data
        if d and d.index and K.Engine.steps[d.index] then
            local ps = U.PlanStepFor(K.Engine.steps[d.index])
            if ps then
                T.ShowTip(self, K.Planner.Breakdown(ps), "ANCHOR_RIGHT")
            end
        end
    end)
    r:SetScript("OnLeave", function(self)
        self.hover = false
        U.PaintRow(self)
        T.HideTip()
    end)
    r:SetScript("OnClick", function(self, mouseButton)
        U.OnRowClick(self, mouseButton)
    end)
    return r
end

-- State look of a row: fill, stripe, title colour and badge tint.
local function rowLook(d)
    if d.plain then
        return c.card, c.edge, d.muted and c.sub or c.text
    end
    if d.current then
        return c.cardActive, c.accent, c.text
    end
    if d.focus then
        return { 0.10, 0.16, 0.24, 1 }, c.info, c.text
    end
    if d.state == "done" or d.state == "archived" then
        return c.card, c.dim, c.dim
    end
    if d.state == "skipped" then
        return c.card, c.bad, c.dim
    end
    if d.state == "cascade" then
        return c.card, c.warn, c.sub
    end
    return c.card, d.tint or c.sub, c.text
end

function U.PaintRow(r)
    local d = r.data
    if not d then
        return
    end
    local fill, stripe, text = rowLook(d)
    if r.hover then
        fill = d.current and c.cardActive or c.cardHover
    end
    r.surface:SetFill(fill)
    r.surface:SetEdge(d.current and { c.accent[1], c.accent[2], c.accent[3], 0.35 } or { 1, 1, 1, 0 })
    r.stripe:SetVertexColor(stripe[1], stripe[2], stripe[3], d.plain and 0 or 1)
    r.title:SetTextColor(text[1], text[2], text[3])
end

local function bindRow(r, d, top, h, width)
    r.data = d
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", U.listFrame.content, "TOPLEFT", 0, -top)
    r:SetSize(width, h)
    r.title:ClearAllPoints()
    r.sub:ClearAllPoints()
    if d.plain then
        r.badgeBox:Hide()
        r.num:SetText("")
        r.title:SetPoint("TOPLEFT", r, "TOPLEFT", 12, -8)
        r.title:SetWidth(width - 24)
    else
        r.badgeBox:Show()
        r.title:SetPoint("TOPLEFT", r, "TOPLEFT", ROW_TEXT_L, -8)
        r.title:SetWidth(width - ROW_TEXT_L - ROW_TEXT_R)
        r.num:SetText(d.num or "")
        local fill = d.tint or c.sub
        local finished = d.state == "done" or d.state == "archived"
        r.badgeBg:SetVertexColor(fill[1], fill[2], fill[3], finished and 0.08 or 0.18)
        r.glyph:SetText(d.glyph or "")
        r.glyph:SetTextColor(fill[1], fill[2], fill[3])
        r.glyph:SetShown(not finished)
        r.check:SetShown(finished)
    end
    r.title:SetText(d.title or "")
    if d.sub and d.sub ~= "" then
        r.sub:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -3)
        r.sub:SetWidth(width - ROW_TEXT_L - ROW_TEXT_R)
        r.sub:SetText(d.sub)
        r.sub:Show()
    else
        r.sub:SetText("")
        r.sub:Hide()
    end
    U.PaintRow(r)
    r:Show()
end

function U.OnRowClick(row, mouseButton)
    local d = row.data
    if not d then
        return
    end
    if d.skippedQuest then
        K.Engine:RestoreQuest(d.skippedQuest)
        U.Refresh()
        return
    end
    local idx = d.index
    if not idx then
        return
    end
    local E = K.Engine
    if mouseButton == "RightButton" then
        if K.StepMenu then
            K.StepMenu.Open(idx, row)
        end
        return
    elseif E.eff[idx] == "pending" then
        U.focusKey = E.steps[idx].k
    end
    U.Refresh()
end

-- ---- Virtualised list -------------------------------------------------------------------------

-- Row data of the active tab.
function U.TabRows()
    local E = K.Engine
    if U.tab == "ahead" then
        local rows = {}
        for _, line in ipairs(U.PlanRows()) do
            rows[#rows + 1] = { plain = true, title = line }
        end
        if #rows == 0 then
            rows[1] = { plain = true, muted = true, title = L.VIEW_EMPTY }
        end
        return rows
    elseif U.tab == "skipped" then
        local rows = {}
        for _, item in ipairs(U.SkippedRows()) do
            rows[#rows + 1] = { plain = true, title = item.text, skippedQuest = item.q }
        end
        if #rows == 0 then
            rows[1] = { plain = true, muted = true, title = L.SKIPPED_NONE }
        end
        return rows
    end
    if not E.routeId then
        return { { plain = true, muted = true, title = L.UI_NO_ROUTE } }
    end
    local rows = U.ListRows(E)
    local focusIdx = U.focusKey and E.byKey[U.focusKey]
    for _, d in ipairs(rows) do
        d.focus = (d.index == focusIdx) and not d.current
    end
    return rows
end

-- Binds the pooled rows to the part of the list in view.
function U.BindRows()
    local pg, list = U.listFrame, U.list
    if not (pg and list) then
        return
    end
    local scroll = pg
    local first, last = T.VisibleRange(list.tops, list.heights, scroll.offset, scroll.viewH, OVERSCAN)
    local used = 0
    for i = first, last do
        used = used + 1
        local r = U.pool[used]
        if not r then
            r = newRow(scroll)
            U.pool[used] = r
        end
        bindRow(r, list.rows[i], list.tops[i], list.heights[i], scroll.viewW)
    end
    for n = used + 1, #U.pool do
        U.pool[n].data = nil
        U.pool[n]:Hide()
    end
end

-- Lays the active tab out (row heights, tops, content height) and binds the visible rows. When the
-- current step changed (or the tab just opened) the list scrolls so it sits in the top third.
function U.RefreshList()
    local scroll = U.listFrame
    if not scroll then
        return
    end
    local rows = U.TabRows()
    local heights = {}
    for i, d in ipairs(rows) do
        heights[i] = U.RowHeight(d, scroll.viewW)
    end
    local tops, total = T.Layout(heights, ROW_GAP)
    U.list = { rows = rows, heights = heights, tops = tops }
    scroll:SetContentHeight(total)
    local E = K.Engine
    if U.tab == "steps" and (U.follow or E.cursor ~= U.lastCursor) then
        local recent = (GetTime and GetTime() or 0) - U.userScrollAt < 3
        if U.follow or not recent then
            for i, d in ipairs(rows) do
                if d.current then
                    scroll:ScrollTo(T.ScrollTarget(tops[i], total, scroll.viewH))
                    break
                end
            end
        end
    end
    U.follow = false
    U.lastCursor = E.cursor
    U.BindRows()
end

-- ---- Hero card --------------------------------------------------------------------------------

local EMPTY_TEXT = { none = "UI_NO_ROUTE", done = "UI_DONE", hidden = "UI_HIDDEN" }

-- Height of a font string holding text at a width: measured when the client can, else estimated.
local function textHeight(fs, text, width, size)
    fs:SetWidth(width)
    fs:SetText(text)
    if not text or text == "" then
        fs:Hide()
        return 0
    end
    fs:Show()
    local h = fs:GetStringHeight()
    if h and h > 0 then
        return h
    end
    return T.TextLines(text, width, size) * (size + 3)
end

local function heroWidth()
    local w = U.frame and U.frame:GetWidth()
    return (w or DEFAULT_W) - 2 * PAD
end

-- Fills the hero card from the model and sizes it. Returns its height.
function U.LayoutHero(m)
    local h = U.hero
    local innerW = heroWidth() - 2 * HERO_PAD
    local ready = m.kind == "step"
    h.done:SetDisabled(not ready)
    h.skip:SetDisabled(not ready)
    local y = 12
    local function place(el, gap, height)
        el:ClearAllPoints()
        el:SetPoint("TOPLEFT", h.body, "TOPLEFT", HERO_PAD, -y)
        y = y + height + (gap or 0)
    end
    if not ready then
        local text
        if m.kind == "gated" then
            text = string.format(L.UI_GATED, m.level)
        else
            text = L[EMPTY_TEXT[m.kind] or "UI_DONE"]
        end
        h.badge:Hide()
        h.action:SetText("")
        h.chip:Hide()
        h.count:SetText("")
        for _, el in ipairs({ h.note, h.objectives, h.why, h.hint, h.npc, h.zone }) do
            el:Hide()
        end
        local th = textHeight(h.title, text, innerW, 15)
        place(h.title, 0, th)
        h.title:SetTextColor(c.sub[1], c.sub[2], c.sub[3])
        h.done:Hide()
        h.skip:Hide()
        h.stripe:SetVertexColor(c.dim[1], c.dim[2], c.dim[3], 1)
        return y + 14
    end
    h.done:Show()
    h.skip:Show()
    h.badge:Show()
    local badge = T.Badge(m.stepType)
    h.badgeBg:SetVertexColor(badge[2][1], badge[2][2], badge[2][3], 0.2)
    h.glyph:SetText(badge[1])
    h.glyph:SetTextColor(badge[2][1], badge[2][2], badge[2][3])
    h.stripe:SetVertexColor(badge[2][1], badge[2][2], badge[2][3], 1)
    h.action:SetText(string.upper(m.action or ""))
    h.action:SetTextColor(badge[2][1], badge[2][2], badge[2][3])
    h.chip:Set(m.tagText, TAG_COLOUR[m.tag])
    h.count:SetText(m.checklist and string.format(L.HUB_COUNT, m.hubDone, m.hubTotal)
        or string.format(L.STEP_COUNT_SHORT, m.stepNo, m.total))
    y = y + 34

    h.title:SetTextColor(c.text[1], c.text[2], c.text[3])
    place(h.title, 8, textHeight(h.title, m.title, innerW, 17))
    place(h.note, 8, textHeight(h.note, m.note, innerW, 12))
    local objText = U.ObjectiveText(m.objectives)
    if m.checklist then
        local lines = {}
        for _, item in ipairs(m.checklist) do
            local done = item.state == "done"
            lines[#lines + 1] = { text = item.text, finished = done }
        end
        objText = U.ObjectiveText(lines)
    end
    place(h.objectives, 8, textHeight(h.objectives, objText, innerW, 12))
    place(h.why, 6, textHeight(h.why, m.why or "", innerW, 11))
    local hint = K.Helpers and K.Helpers.CurrentHint()
    place(h.hint, 6, textHeight(h.hint, hint and U.Clip(hint, 120) or "", innerW, 11))

    -- NPC link and zone
    h.npcName = m.npc
    if m.npc then
        h.npc:SetLabel(m.npc .. "  >")
        h.npc:Show()
        h.npc:ClearAllPoints()
        h.npc:SetPoint("TOPLEFT", h.body, "TOPLEFT", HERO_PAD, -y)
    else
        h.npc:Hide()
    end
    if m.zone then
        h.zone:SetText(m.zone)
        h.zone:Show()
        h.zone:ClearAllPoints()
        if m.npc then
            h.zone:SetPoint("LEFT", h.npc, "RIGHT", 10, 0)
        else
            h.zone:SetPoint("TOPLEFT", h.body, "TOPLEFT", HERO_PAD, -(y + 4))
        end
    else
        h.zone:Hide()
    end
    if m.npc or m.zone then
        y = y + 28
    end

    y = y + 4
    h.done:ClearAllPoints()
    h.done:SetPoint("TOPLEFT", h.body, "TOPLEFT", HERO_PAD, -y)
    h.skip:ClearAllPoints()
    h.skip:SetPoint("LEFT", h.done, "RIGHT", 8, 0)
    y = y + 32
    return y + 14
end

-- Redraws the hero card and moves the list below it. Animates when the step changed.
function U.RefreshHero(m)
    local h = U.hero
    if not h then
        return
    end
    m = m or U.Model(K.Engine)
    h.planStep = m.planStep
    local height = U.LayoutHero(m)
    h:SetHeight(height)
    U.heroH = height
    if m.key ~= U.heroKey then
        U.heroKey = m.key
        h.body:SetAlpha(0)
        T.Animate("hero", 0.28, function(p)
            local e = T.Ease(p)
            h.body:SetAlpha(e)
            h.body:ClearAllPoints()
            h.body:SetPoint("TOPLEFT", h, "TOPLEFT", 0, -(1 - e) * 8)
            h.body:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", 0, -(1 - e) * 8)
        end)
    end
    U.LayoutBody()
    return m
end

local function buildHero(f)
    local h = CreateFrame("Frame", nil, f)
    T.Surface(h, c.card, c.edge)
    h:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -HEAD_H)
    h:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -HEAD_H)
    h:SetHeight(200)
    h.stripe = h:CreateTexture(nil, "ARTWORK")
    h.stripe:SetTexture(T.WHITE)
    h.stripe:SetWidth(3)
    h.stripe:SetPoint("TOPLEFT", h, "TOPLEFT", 0, 0)
    h.stripe:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", 0, 0)
    local body = CreateFrame("Frame", nil, h)
    body:SetAllPoints(h)
    h.body = body

    h.badge = CreateFrame("Frame", nil, body)
    h.badge:SetSize(26, 26)
    h.badge:SetPoint("TOPLEFT", body, "TOPLEFT", HERO_PAD, -12)
    h.badgeBg = h.badge:CreateTexture(nil, "ARTWORK")
    h.badgeBg:SetAllPoints(h.badge)
    h.badgeBg:SetTexture(T.WHITE)
    h.glyph = T.Text(h.badge, 16, c.text, "CENTER", true)
    h.glyph:SetPoint("CENTER", h.badge, "CENTER", 0, -1)

    h.action = T.Text(body, 11, c.accent, "LEFT", true)
    h.action:SetPoint("LEFT", h.badge, "RIGHT", 10, 0)
    h.count = T.Text(body, 10, c.dim, "RIGHT")
    h.count:SetPoint("TOPRIGHT", body, "TOPRIGHT", -HERO_PAD, -18)
    h.chip = T.Chip(body, 10)
    h.chip:SetPoint("RIGHT", h.count, "LEFT", -8, 0)

    h.title = T.Text(body, 17, c.text, "LEFT", true)
    h.note = T.Text(body, 12, c.sub)
    h.objectives = T.Text(body, 12, c.text)
    h.why = T.Text(body, 11, { c.good[1], c.good[2], c.good[3] })
    h.hint = T.Text(body, 11, c.warn)
    h.zone = T.Text(body, 11, c.sub)

    h.npc = T.Button(body, "", 0, 22, function()
        local i = U.DisplayIndex(K.Engine)
        local step = i and K.Engine.steps[i]
        if step and K.NpcInfo then
            K.NpcInfo.Open(step, i)
        end
    end, "quiet")
    h.npc.textColour = c.npc
    h.npc:SetStyle("quiet")
    h.npc.tip = L.TIP_NPC

    h.done = T.Button(body, L.BTN_DONE, 130, 28, function() U.DoNext() end, "primary")
    h.done.tip = L.TIP_NEXT
    h.skip = T.Button(body, L.BTN_SKIP, 80, 28, function() U.DoSkip() end, "ghost")
    h.skip.tip = L.TIP_SKIP

    h:EnableMouse(true)
    h:SetScript("OnEnter", function(self)
        if self.planStep then
            T.ShowTip(self, K.Planner.Breakdown(self.planStep), "ANCHOR_RIGHT")
        end
    end)
    h:SetScript("OnLeave", T.HideTip)
    return h
end

-- ---- Header, tabs, footer ---------------------------------------------------------------------

-- Opens the window menu below the menu button.
function U.OpenMenu(anchor)
    local reset = U.ResetItems()
    local skippedN = #U.SkippedRows()
    local items = {
        { label = L.MENU_PLAN_AHEAD, fn = function() U.SetTab("ahead") end },
        { label = string.format(L.MENU_SKIPPED_LIST, skippedN), fn = function() U.SetTab("skipped") end },
        { label = L.MENU_PROFILE, fn = function() K.Profile.Command("") end },
        { label = reset[3].text, fn = reset[3].fn },
        { label = reset[1].text, fn = reset[1].fn },
        { label = reset[2].text, fn = reset[2].fn },
        { label = L.OPT_LOCK, checked = K.Option("locked"), fn = function()
            K.SetOption("locked", not K.Option("locked"))
        end },
        { label = L.MENU_OPTIONS, fn = function() K.Options.Open() end },
    }
    return T.OpenMenu(anchor, L.ADDON_NAME, items)
end

function U.SetTab(name)
    local valid = false
    for _, t in ipairs(U.TABS) do
        valid = valid or t == name
    end
    if not valid then
        name = "steps"
    end
    U.tab = name
    uiState().tab = name
    if U.collapsed then
        U.SetCollapsed(false)
    end
    U.follow = true
    if U.tabs then
        U.tabs:SetValue(name)
    end
    U.Refresh()
end

function U.SetCollapsed(on)
    U.collapsed = on and true or false
    uiState().collapsed = U.collapsed
    if not U.frame then
        return
    end
    if U.collapsed then
        saveSize(U.frame)
    else
        local sz = uiState().size
        local _, h = U.ClampSize(sz and sz.w, sz and sz.h)
        U.frame:SetHeight(h)
    end
    U.Relayout()
end

-- Positions the tabs, list and footer below the hero and sets the window height when collapsed.
function U.LayoutBody()
    local f = U.frame
    if not (f and U.hero and U.tabs) then
        return
    end
    local top = HEAD_H + (U.heroH or 200) + 10
    if U.collapsed then
        U.tabs:Hide()
        U.listFrame:Hide()
        U.footer:Hide()
        U.grip:Hide()
        f:SetHeight(top + 6)
        f.collapse.glyph:SetColour(c.accent)
        return
    end
    f.collapse.glyph:SetColour(c.sub)
    U.tabs:Show()
    U.listFrame:Show()
    U.footer:Show()
    U.grip:Show()
    U.tabs:ClearAllPoints()
    U.tabs:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top)
    U.listFrame:ClearAllPoints()
    U.listFrame:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(top + 32))
    U.listFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOT_H + 4)
    U.listFrame:Measure()
end

-- Re-flows everything after a resize, a collapse or a font change.
function U.Relayout()
    if not U.frame then
        return
    end
    U.RefreshHero()
    U.RefreshList()
end

local function updateFooter(m)
    local ft = U.footer
    if m.kind == "step" then
        ft.text:SetText(m.checklist and string.format(L.HUB_PROGRESS, m.hubDone, m.hubTotal)
            or string.format(L.STEP_COUNT, m.stepNo, m.total))
        ft.bar:SetFraction(m.progress or 0, true)
    else
        ft.text:SetText("")
        ft.bar:SetFraction(m.kind == "done" and 1 or 0, true)
    end
end

-- ---- Refresh ----------------------------------------------------------------------------------

function U.Refresh()
    local f = U.frame
    if not f then
        return
    end
    local m = U.Model(K.Engine)
    f.sub:SetText(K.Engine.routeId and U.PlanLabel() or "")
    U.RefreshHero(m)
    if U.tabs then
        U.tabs.pills[3]:SetLabel(string.format(L.TAB_SKIPPED_N, #U.SkippedRows()))
        U.tabs:Layout()
        U.tabs:SetValue(U.tab)
    end
    U.RefreshList()
    updateFooter(m)
    A.Update()
end

-- Re-applies every appearance option (scale, opacity, font size, lock, arrow).
function U.ApplyAll()
    if not U.frame then
        return
    end
    U.frame:SetScale(K.Option("scale"))
    U.frame:SetAlpha(K.Option("alpha"))
    T.ApplyFontScale()
    U.frame:EnableMouse(true)
    A.Place()
    U.ApplyVisibility()
    U.Refresh()
end

-- ---- Main frame -------------------------------------------------------------------------------

local function registerPopups()
    StaticPopupDialogs["KLIMAX_RESET_BAND"] = {
        text = L.CONFIRM_RESET_BAND,
        button1 = L.YES,
        button2 = L.NO,
        OnAccept = function()
            K.Engine:Reset("band")
            K.Print(L.RESET_BAND)
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
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    T.SetResizeBounds(f, MIN_W, MIN_H, MAX_W, MAX_H)
    T.Window(f)

    -- Drag by the header; a locked window ignores it.
    local head = CreateFrame("Frame", nil, f)
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    head:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    head:SetHeight(HEAD_H)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnDragStart", function()
        if not K.Option("locked") then
            f:StartMoving()
        end
    end)
    head:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        savePos(f)
    end)

    local mark = f:CreateTexture(nil, "ARTWORK")
    mark:SetTexture(T.WHITE)
    mark:SetSize(4, 22)
    mark:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -12)
    T.Paint(mark, c.accent)
    f.name = T.Text(head, 15, c.text, "LEFT", true)
    f.name:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 12, -9)
    f.name:SetText(L.ADDON_NAME)
    f.sub = T.Text(head, 11, c.sub)
    f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -2)
    f.sub:SetPoint("RIGHT", f, "RIGHT", -110, 0)

    f.close = T.IconButton(head, "close", 26, function() U.Toggle() end, L.TIP_CLOSE)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD + 4, -10)
    f.collapse = T.IconButton(head, "chevron_up", 26, function()
        U.SetCollapsed(not U.collapsed)
    end, L.TIP_COLLAPSE)
    f.collapse:SetPoint("RIGHT", f.close, "LEFT", -2, 0)
    f.menu = T.IconButton(head, "menu", 26, function(self) U.OpenMenu(self) end, L.TIP_MENU)
    f.menu:SetPoint("RIGHT", f.collapse, "LEFT", -2, 0)

    f:SetScript("OnSizeChanged", function()
        if U.hero and not U.resizing then
            U.resizing = true
            U.Relayout()
            U.resizing = false
        end
    end)
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
    U.pool = {}
    U.hero = buildHero(f)

    U.tabs = T.Segmented(f, {
        { value = "steps", text = L.TAB_STEPS },
        { value = "ahead", text = L.TAB_AHEAD },
        { value = "skipped", text = string.format(L.TAB_SKIPPED_N, 0) },
    }, function(v) U.SetTab(v) end)

    local scroll = T.Scroll(f)
    scroll.onScroll = function() U.BindRows() end
    scroll.onUserScroll = function() U.userScrollAt = GetTime and GetTime() or 0 end
    scroll.onResize = function()
        if U.list then
            U.RefreshList()
        end
    end
    U.listFrame = scroll

    local ft = CreateFrame("Frame", nil, f)
    ft:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    ft:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    ft:SetHeight(FOOT_H)
    ft.text = T.Text(ft, 11, c.sub)
    ft.text:SetPoint("BOTTOMLEFT", ft, "BOTTOMLEFT", PAD, 10)
    ft.bar = T.Progress(ft, 3)
    ft.bar:SetPoint("BOTTOMLEFT", ft, "BOTTOMLEFT", 0, 0)
    ft.bar:SetPoint("BOTTOMRIGHT", ft, "BOTTOMRIGHT", 0, 0)
    U.footer = ft
    U.grip = T.Grip(f, function()
        saveSize(f)
        U.Relayout()
    end)
    U.grip:SetFrameLevel((f:GetFrameLevel() or 1) + 10)

    U.collapsed = uiState().collapsed and true or false
    U.tab = uiState().tab or "steps"
    if U.tab ~= "steps" and U.tab ~= "ahead" and U.tab ~= "skipped" then
        U.tab = "steps"
    end
    A.Build()
    K.Engine:OnChange(function()
        U.Refresh()
    end)
    K.Options.OnChange(function()
        U.ApplyAll()
    end)
    U.follow = true
    U.ApplyAll()
end

-- ---- Events -----------------------------------------------------------------------------------

K.On("PLAYER_LOGIN", function()
    U.Build()
    U.Refresh()
end)

-- Objective counters change with the quest log: redraw the hero card (throttled by the ticker).
K.On("QUEST_LOG_UPDATE", function()
    U.objDirty = true
end)
K.On("UNIT_QUEST_LOG_CHANGED", function()
    U.objDirty = true
end)
K.Every(0.5, function()
    if U.objDirty and U.frame and U.frame:IsShown() then
        U.objDirty = false
        U.RefreshHero()
    end
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
