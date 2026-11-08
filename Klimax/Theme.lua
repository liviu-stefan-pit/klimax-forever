-- Theme: the design system of every Klimax window (UI overhaul, phases 11 to 16). Flat dark surfaces,
-- one amber accent, 1 px borders, thin scrollbars, toggle switches, segmented controls and short
-- ease-out animations; the look of modern web-style add-ons rather than Blizzard frames. Nothing here
-- uses a Blizzard template or a secure frame, so it stays taint-free; every texture is a white pixel
-- tinted by vertex colour, and every glyph (close, menu, chevron, check) is drawn from rotated bars.
--
-- The maths (ease, lerp, layout, visible range, text lines) is pure so the busted specs can test it
-- without a client. The widget builders only need CreateFrame.
local _, K = ...

local T = {}
K.Theme = T

T.FONT = "Fonts\\FRIZQT__.TTF"       -- titles
T.FONT_BODY = "Fonts\\ARIALN.TTF"     -- body text: narrow and compact, like a web UI
T.WHITE = "Interface\\Buttons\\WHITE8X8"

-- ---- Palette ---------------------------------------------------------------------------------------

local accent = { 0.96, 0.74, 0.30 }

T.c = {
    bg = { 0.051, 0.059, 0.075, 0.97 },        -- window surface
    card = { 0.090, 0.102, 0.129, 1 },         -- raised card
    cardHover = { 0.125, 0.141, 0.176, 1 },
    cardActive = { 0.165, 0.137, 0.075, 1 },   -- the current step (accent tinted)
    edge = { 1, 1, 1, 0.09 },
    edgeStrong = { 1, 1, 1, 0.18 },
    accent = accent,
    accentSoft = { accent[1], accent[2], accent[3], 0.16 },
    text = { 0.92, 0.93, 0.95 },
    sub = { 0.62, 0.66, 0.72 },
    dim = { 0.42, 0.45, 0.50 },
    good = { 0.36, 0.82, 0.56 },
    bad = { 0.93, 0.42, 0.42 },
    info = { 0.46, 0.70, 1.00 },
    warn = { 1.00, 0.70, 0.30 },
    -- roles inside step text
    npc = { 0.45, 0.88, 0.52 },
    mob = { 0.95, 0.42, 0.40 },
    item = { 0.40, 0.85, 0.95 },
    quest = { 0.96, 0.96, 0.98 },
    onAccent = { 0.10, 0.08, 0.03 },
}
local c = T.c

-- Names kept for the windows written before the overhaul.
T.colour = {
    gold = c.accent, text = c.text, muted = c.sub, good = c.good, bad = c.bad,
    panel = c.bg, row = { 1, 1, 1, 0.05 }, rowHover = c.accentSoft, rule = c.edgeStrong,
}

-- The badge of each step kind: a glyph in a tinted square, and the colour of its stripe.
T.BADGE = {
    A = { "!", c.accent }, T = { "?", c.accent }, C = { "x", c.mob }, V = { ">", c.info },
    F = { ">", c.info }, D = { "*", c.info }, B = { "$", c.item }, R = { "+", c.good },
    H = { "o", c.info }, U = { "o", c.info }, P = { "+", c.good }, N = { "i", c.sub }, S = { "!", c.warn },
}
T.BADGE_DEFAULT = { "-", c.sub }

function T.Badge(kind)
    return T.BADGE[kind] or T.BADGE_DEFAULT
end

-- ---- Pure maths ------------------------------------------------------------------------------------

function T.Clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

function T.Lerp(a, b, t)
    return a + (b - a) * t
end

-- Ease-out cubic: fast start, soft landing. t in 0..1.
function T.Ease(t)
    t = T.Clamp(t, 0, 1)
    return 1 - (1 - t) ^ 3
end

function T.LerpColour(a, b, t)
    return {
        T.Lerp(a[1], b[1], t), T.Lerp(a[2], b[2], t), T.Lerp(a[3], b[3], t),
        T.Lerp(a[4] or 1, b[4] or 1, t),
    }
end

-- Width of a button for a label: the text plus padding on both sides, never below min.
function T.ButtonWidth(textWidth, min, pad)
    return math.max(min or 0, math.ceil(textWidth or 0) + 2 * (pad or 14))
end

-- How many lines text takes at a pixel width and font size. The estimate is a little generous (an
-- average glyph is about half the font size wide) and splits on spaces, like the client does.
function T.TextLines(text, width, size)
    text = tostring(text or "")
    if text == "" then
        return 0
    end
    local per = math.max(1, math.floor(width / (size * 0.5)))
    local lines = 0
    for para in (text .. "\n"):gmatch("(.-)\n") do
        local used, n = 0, 1
        for word in para:gmatch("%S+") do
            local len = #word
            if used == 0 then
                used = len
            elseif used + 1 + len <= per then
                used = used + 1 + len
            else
                n = n + 1
                used = len
            end
            while used > per do
                n = n + 1
                used = used - per
            end
        end
        lines = lines + n
    end
    return lines
end

-- Scroll offset kept inside the content: 0 up to (content height - view height).
function T.ClampScroll(offset, contentH, viewH)
    return math.max(0, math.min(offset, math.max(0, contentH - viewH)))
end

-- Offset that puts a row near the top third of the view, so the current step has context above it.
function T.ScrollTarget(rowTop, contentH, viewH)
    return T.ClampScroll(rowTop - viewH / 3, contentH, viewH)
end

-- Stacks rows: returns the top of every row and the total height. heights[i] is the row height.
function T.Layout(heights, gap)
    local tops, y = {}, 0
    gap = gap or 0
    for i = 1, #heights do
        tops[i] = y
        y = y + heights[i] + gap
    end
    return tops, math.max(0, y - gap)
end

-- The first and last row that intersect the view (plus overscan pixels on both sides). 0, -1 when
-- there are no rows. Only these rows need a frame (the list is virtualised).
function T.VisibleRange(tops, heights, offset, viewH, overscan)
    local n = #tops
    if n == 0 then
        return 0, -1
    end
    overscan = overscan or 0
    local lo, hi = offset - overscan, offset + viewH + overscan
    local first, last = nil, 0
    for i = 1, n do
        local top, bottom = tops[i], tops[i] + heights[i]
        if bottom >= lo and top <= hi then
            first = first or i
            last = i
        elseif top > hi then
            break
        end
    end
    if not first then
        return 0, -1
    end
    return first, last
end

-- ---- Animation -------------------------------------------------------------------------------------

local anims = {}
local driver

function T.AnimEnabled()
    return not (K.Option and K.Option("animations") == false)
end

-- Runs step(p) with p from 0 to 1 over dur seconds, then done(). A second animation with the same
-- key replaces the first. With animations off, or dur <= 0, it jumps straight to the end.
function T.Animate(key, dur, step, done)
    if not T.AnimEnabled() or not dur or dur <= 0 then
        anims[key] = nil
        step(1)
        if done then
            done()
        end
        return
    end
    anims[key] = { t = 0, dur = dur, step = step, done = done }
    step(0)
    if not driver then
        driver = CreateFrame("Frame")
        driver:SetScript("OnUpdate", function(_, dt)
            if not T.Advance(dt) then
                driver:Hide()
            end
        end)
    end
    driver:Show()
end

-- Advances every running animation by dt seconds. Returns true while any is left.
function T.Advance(dt)
    local finished = {}
    for key, a in pairs(anims) do
        a.t = a.t + dt
        local p = math.min(1, a.t / a.dur)
        a.step(p)
        if p >= 1 then
            finished[#finished + 1] = key
        end
    end
    for _, key in ipairs(finished) do
        local a = anims[key]
        anims[key] = nil
        if a and a.done then
            a.done()
        end
    end
    return next(anims) ~= nil
end

function T.Cancel(key)
    anims[key] = nil
end

function T.Animating()
    return next(anims) ~= nil
end

-- ---- Text and surfaces -----------------------------------------------------------------------------

T.fonts = {}          -- {fs, base}: rescaled by the font option

local function scale()
    return (K.Option and K.Option("fontScale")) or 1
end

-- A font string. size is the base size (the font option scales it). title = true uses the heading
-- font. c is a colour {r, g, b}.
function T.Text(parent, size, col, justify, title)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local font = title and T.FONT or T.FONT_BODY
    size = size or 12
    fs:SetFont(font, size * scale(), "")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetJustifyV("TOP")
    col = col or c.text
    fs:SetTextColor(col[1], col[2], col[3])
    T.fonts[#T.fonts + 1] = { fs = fs, base = size, font = font }
    return fs
end

function T.ApplyFontScale()
    local s = scale()
    for _, e in ipairs(T.fonts) do
        e.fs:SetFont(e.font, e.base * s, "")
    end
end

-- Paints a texture with a colour table {r, g, b, a}.
function T.Paint(tex, col, alphaMul)
    tex:SetVertexColor(col[1], col[2], col[3], (col[4] or 1) * (alphaMul or 1))
end

-- A solid background texture covering the frame.
function T.Backdrop(frame, col)
    local tex = frame:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(frame)
    tex:SetTexture(T.WHITE)
    T.Paint(tex, col)
    return tex
end

-- A filled rectangle with a 1 px border. Returns {bg, edges} with :SetFill(c) and :SetEdge(c).
function T.Surface(frame, fill, edge)
    local s = { edges = {} }
    s.bg = frame:CreateTexture(nil, "BACKGROUND")
    s.bg:SetAllPoints(frame)
    s.bg:SetTexture(T.WHITE)
    local function line(p1, p2, w, h)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetTexture(T.WHITE)
        t:SetPoint(p1, frame, p1, 0, 0)
        t:SetPoint(p2, frame, p2, 0, 0)
        if w then
            t:SetWidth(w)
        end
        if h then
            t:SetHeight(h)
        end
        s.edges[#s.edges + 1] = t
    end
    line("TOPLEFT", "TOPRIGHT", nil, 1)
    line("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    line("TOPLEFT", "BOTTOMLEFT", 1, nil)
    line("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    function s:SetFill(col)
        T.Paint(self.bg, col)
    end
    function s:SetEdge(col)
        for _, e in ipairs(self.edges) do
            T.Paint(e, col)
        end
        self.edge = col
    end
    s:SetFill(fill or c.card)
    s:SetEdge(edge or c.edge)
    return s
end

-- A soft shadow around a frame: a few outset layers of falling alpha.
function T.Shadow(frame, size)
    size = size or 6
    for i = 1, 3 do
        local t = frame:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(T.WHITE)
        t:SetVertexColor(0, 0, 0, 0.16 / i)
        local o = size * i / 3
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", -o, o)
        t:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", o, -o)
    end
end

-- The window chrome: shadow, surface, border. Returns the surface.
function T.Window(frame)
    T.Shadow(frame, 9)
    return T.Surface(frame, c.bg, c.edgeStrong)
end

-- ---- Tooltips --------------------------------------------------------------------------------------

-- Shows text (or a list of lines) in the game tooltip. The first line is white, the rest grey.
function T.ShowTip(owner, tip, anchor)
    if (type(tip) ~= "string" and type(tip) ~= "table") or not GameTooltip then
        return
    end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_TOP")
    if type(tip) == "table" then
        for i, line in ipairs(tip) do
            if i == 1 then
                GameTooltip:SetText(line, 1, 1, 1, 1, true)
            else
                GameTooltip:AddLine(line, 0.8, 0.8, 0.8, true)
            end
        end
    else
        GameTooltip:SetText(tip, 1, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

function T.HideTip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

-- ---- Glyphs (drawn from rotated bars, no texture files) --------------------------------------------

local QUARTER = math.pi / 4

-- A small icon centred in `frame`: kind is close, menu, chevron_down, chevron_up, check, plus, grip.
function T.Glyph(frame, kind, size, col)
    local g = { bars = {} }
    local function bar(len, thick, rot, ox, oy)
        local t = frame:CreateTexture(nil, "OVERLAY")
        t:SetTexture(T.WHITE)
        t:SetSize(len, thick)
        t:SetPoint("CENTER", frame, "CENTER", ox or 0, oy or 0)
        if rot and rot ~= 0 and t.SetRotation then
            t:SetRotation(rot)
        end
        g.bars[#g.bars + 1] = t
    end
    local s = size or 12
    local w = math.max(1.5, s / 8)
    if kind == "close" then
        bar(s * 1.2, w, QUARTER)
        bar(s * 1.2, w, -QUARTER)
    elseif kind == "menu" then
        bar(s, w, 0, 0, s * 0.34)
        bar(s, w, 0, 0, 0)
        bar(s, w, 0, 0, -s * 0.34)
    elseif kind == "chevron_down" then
        bar(s * 0.7, w, -QUARTER, -s * 0.22, 0)
        bar(s * 0.7, w, QUARTER, s * 0.22, 0)
    elseif kind == "chevron_up" then
        bar(s * 0.7, w, QUARTER, -s * 0.22, 0)
        bar(s * 0.7, w, -QUARTER, s * 0.22, 0)
    elseif kind == "check" then
        bar(s * 0.45, w, -QUARTER, -s * 0.24, -s * 0.12)
        bar(s * 0.9, w, QUARTER, s * 0.14, s * 0.06)
    elseif kind == "plus" then
        bar(s, w, 0)
        bar(s, w, math.pi / 2)
    elseif kind == "grip" then
        bar(s * 0.9, 1.5, QUARTER, s * 0.1, -s * 0.1)
        bar(s * 0.5, 1.5, QUARTER, s * 0.3, -s * 0.3)
    end
    function g:SetColour(col2)
        for _, b in ipairs(self.bars) do
            T.Paint(b, col2)
        end
    end
    function g:SetShown(on)
        for _, b in ipairs(self.bars) do
            if on then
                b:Show()
            else
                b:Hide()
            end
        end
    end
    g:SetColour(col or c.sub)
    return g
end

-- ---- Buttons ---------------------------------------------------------------------------------------

T.STYLES = {
    ghost = { fill = c.card, hover = c.cardHover, text = c.text, edge = c.edge },
    primary = { fill = c.accent, hover = { 1, 0.83, 0.47, 1 }, text = c.onAccent, edge = nil },
    quiet = { fill = { 1, 1, 1, 0 }, hover = { 1, 1, 1, 0.08 }, text = c.sub, edge = nil },
    danger = { fill = { 0.42, 0.15, 0.15, 1 }, hover = { 0.58, 0.2, 0.2, 1 }, text = c.text, edge = nil },
    tab = { fill = { 1, 1, 1, 0.04 }, hover = { 1, 1, 1, 0.10 }, text = c.sub, edge = nil },
}

local function paintButton(b)
    local st = T.STYLES[b.style] or T.STYLES.ghost
    local fill = st.fill
    if b.selected then
        fill = c.accentSoft
    elseif b.hover and not b.off then
        fill = st.hover
    end
    T.Paint(b.bg, fill)
    local tc = type(b.textColour) == "table" and b.textColour or st.text
    if b.selected then
        tc = c.accent
    end
    if b.off then
        tc = c.dim
    end
    b.label:SetTextColor(tc[1], tc[2], tc[3])
end

-- A flat button. style: ghost (default), primary, quiet, danger or tab. onClick(self, mouseButton).
-- A width of 0 or nil sizes the button from its label. b.tip is shown as a tooltip.
function T.Button(parent, text, w, h, onClick, style)
    local b = CreateFrame("Button", nil, parent)
    b.style, b.hover, b.off, b.selected = style or "ghost", false, false, false
    b.minW, b.autoW = w or 0, (w == nil or w == 0)
    b:SetHeight(h or 24)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints(b)
    b.bg:SetTexture(T.WHITE)
    b.label = T.Text(b, 12, c.text, "CENTER")
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    function b:SetLabel(label)
        self.text = label
        self.label:SetText(label or "")
        local tw = self.label:GetStringWidth()
        if self.autoW then
            self:SetWidth(T.ButtonWidth(tw, 0))
        elseif self.minW > 0 then
            local has = label and label ~= ""
            self:SetWidth(has and math.max(self.minW, T.ButtonWidth(tw, 0, 10)) or self.minW)
        end
    end
    function b:SetStyle(name)
        self.style = name
        paintButton(self)
    end
    function b:SetSelected(on)
        self.selected = on and true or false
        paintButton(self)
    end
    function b:SetDisabled(off)
        self.off = off and true or false
        self:SetEnabled(not self.off)
        paintButton(self)
    end
    b:SetScript("OnEnter", function(self)
        self.hover = true
        paintButton(self)
        T.ShowTip(self, self.tip)
    end)
    b:SetScript("OnLeave", function(self)
        self.hover = false
        paintButton(self)
        T.HideTip()
    end)
    b:SetScript("OnClick", function(self, mouseButton)
        if onClick and not self.off then
            onClick(self, mouseButton)
        end
    end)
    b:SetLabel(text or "")
    paintButton(b)
    return b
end

-- A square button holding a glyph (see T.Glyph).
function T.IconButton(parent, kind, size, onClick, tip)
    local b = T.Button(parent, "", size or 24, size or 24, onClick, "quiet")
    b.glyph = T.Glyph(b, kind, math.floor((size or 24) * 0.5), c.sub)
    b.tip = tip
    b:SetScript("OnEnter", function(self)
        self.hover = true
        paintButton(self)
        self.glyph:SetColour(c.text)
        T.ShowTip(self, self.tip)
    end)
    b:SetScript("OnLeave", function(self)
        self.hover = false
        paintButton(self)
        self.glyph:SetColour(c.sub)
        T.HideTip()
    end)
    return b
end

-- ---- Toggle switch ---------------------------------------------------------------------------------

local TRACK_W, TRACK_H, KNOB = 30, 16, 12

-- A labelled switch. get() returns the current state, set(v) stores it. b:Refresh() re-reads get().
function T.Toggle(parent, label, get, set, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(24)
    b.tip = tip
    local track = b:CreateTexture(nil, "ARTWORK")
    track:SetTexture(T.WHITE)
    track:SetSize(TRACK_W, TRACK_H)
    track:SetPoint("LEFT", b, "LEFT", 0, 0)
    local knob = b:CreateTexture(nil, "OVERLAY")
    knob:SetTexture(T.WHITE)
    knob:SetSize(KNOB, KNOB)
    b.text = T.Text(b, 12, c.text)
    b.text:SetPoint("LEFT", track, "RIGHT", 10, 0)
    b.text:SetText(label or "")
    -- Give the button an explicit size (track + gap + label) instead of leaving it at zero width.
    b:SetWidth(TRACK_W + 10 + math.ceil(b.text:GetStringWidth() or 0) + 4)
    b.pos = 0
    local function place(p)
        b.pos = p
        knob:ClearAllPoints()
        knob:SetPoint("LEFT", track, "LEFT", T.Lerp(2, TRACK_W - KNOB - 2, p), 0)
        T.Paint(track, T.LerpColour({ 1, 1, 1, 0.14 }, c.accent, p))
        T.Paint(knob, T.LerpColour(c.sub, c.onAccent, p))
    end
    function b:Refresh(animate)
        local on = get() and true or false
        self.on = on
        local from, to = self.pos, on and 1 or 0
        if animate and from ~= to then
            T.Animate("toggle" .. tostring(self), 0.14, function(p)
                place(T.Lerp(from, to, T.Ease(p)))
            end)
        else
            place(to)
        end
    end
    b:SetScript("OnClick", function(self)
        set(not get())
        self:Refresh(true)
    end)
    b:SetScript("OnEnter", function(self)
        self.text:SetTextColor(1, 1, 1)
        T.ShowTip(self, self.tip, "ANCHOR_RIGHT")
    end)
    b:SetScript("OnLeave", function(self)
        self.text:SetTextColor(c.text[1], c.text[2], c.text[3])
        T.HideTip()
    end)
    b:Refresh(false)
    return b
end

-- ---- Segmented control -----------------------------------------------------------------------------

-- A row of pills, one per choice {value, text}. onPick(value) is called on a click. The control
-- sizes itself from its labels; :SetValue(v) marks the selected pill.
function T.Segmented(parent, choices, onPick, tip)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(24)
    f.pills = {}
    for i, ch in ipairs(choices) do
        local b = T.Button(f, ch.text, 0, 24, function()
            onPick(ch.value)
        end, "tab")
        b.value = ch.value
        b.tip = tip
        f.pills[i] = b
    end
    -- Lays the pills side by side and sizes the control to hold them (call after a label changes).
    function f:Layout()
        local x = 0
        for _, b in ipairs(self.pills) do
            b:ClearAllPoints()
            b:SetPoint("LEFT", self, "LEFT", x, 0)
            x = x + (b:GetWidth() or 40) + 2
        end
        self:SetWidth(math.max(1, x - 2))
    end
    function f:SetValue(v)
        for _, b in ipairs(self.pills) do
            b:SetSelected(b.value == v)
        end
    end
    f:Layout()
    return f
end

-- ---- Chip and progress bar -------------------------------------------------------------------------

-- A small tinted label. :Set(text, colour) updates it; an empty text hides it.
function T.Chip(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(f)
    f.bg:SetTexture(T.WHITE)
    f.text = T.Text(f, size or 10, c.text, "CENTER")
    f.text:SetPoint("CENTER", f, "CENTER", 0, 0)
    function f:Set(text, col)
        if not text or text == "" then
            self:Hide()
            return
        end
        col = col or c.sub
        self.text:SetText(text)
        self.text:SetTextColor(col[1], col[2], col[3])
        T.Paint(self.bg, col, 0.16)
        self:SetSize(math.ceil(self.text:GetStringWidth() or 30) + 12, (size or 10) + 8)
        self:Show()
    end
    return f
end

-- A thin progress bar. :SetFraction(f, animate) moves the fill.
function T.Progress(parent, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(height or 4)
    f.track = T.Backdrop(f, { 1, 1, 1, 0.08 })
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetTexture(T.WHITE)
    T.Paint(f.fill, c.accent)
    f.fill:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.fill:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    f.frac, f.shown = 0, 0
    local function place(fr)
        f.shown = fr
        local w = f:GetWidth()
        if not w or w <= 0 then
            w = 100
        end
        f.fill:SetWidth(math.max(0.001, w * T.Clamp(fr, 0, 1)))
    end
    function f:SetFraction(fr, animate)
        local from = self.shown or 0
        self.frac = fr
        if animate and from ~= fr then
            T.Animate("progress" .. tostring(self), 0.35, function(p)
                place(T.Lerp(from, fr, T.Ease(p)))
            end)
        else
            place(fr)
        end
    end
    f:SetScript("OnSizeChanged", function(self)
        place(self.frac)
    end)
    return f
end

-- ---- Scroll area -----------------------------------------------------------------------------------

local BAR_W = 4

-- A scroll area with a thin scrollbar that follows the mouse wheel and can be dragged. Anchor it with
-- SetPoint; put children on s.content and call s:SetContentHeight(h). s.onScroll(offset) is called
-- when the offset changes (the virtualised list re-binds its rows there).
function T.Scroll(parent)
    local s = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, s)
    s:SetScrollChild(content)
    s.content, s.viewW, s.viewH, s.contentH, s.offset = content, 100, 100, 100, 0

    local bar = CreateFrame("Frame", nil, s)
    bar:SetWidth(BAR_W + 6)
    bar:SetPoint("TOPRIGHT", s, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", 0, 0)
    bar:EnableMouse(true)
    bar:SetFrameLevel((s:GetFrameLevel() or 1) + 8)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(T.WHITE)
    T.Paint(thumb, { 1, 1, 1, 0.22 })
    s.thumb, s.bar, s.thumbH, s.drag = thumb, bar, 24, false

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
        thumb:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -2, -y)
        thumb:Show()
    end

    function s:ScrollTo(y)
        local old = self.offset
        self.offset = T.ClampScroll(y, self.contentH, self.viewH)
        self:SetVerticalScroll(self.offset)
        paintThumb()
        if self.onScroll and self.offset ~= old then
            self.onScroll(self.offset)
        end
    end

    function s:SetContentHeight(h)
        self.contentH = math.max(h, self.viewH)
        content:SetHeight(self.contentH)
        self:ScrollTo(self.offset)
        paintThumb()
    end

    -- Re-reads the size after a resize and tells the owner.
    function s:Measure()
        local w, h = self:GetWidth(), self:GetHeight()
        if w and w > 0 then
            self.viewW = w - BAR_W - 6
        end
        if h and h > 0 then
            self.viewH = h
        end
        content:SetWidth(self.viewW)
        self.contentH = math.max(self.contentH, self.viewH)
        content:SetHeight(self.contentH)
        self:ScrollTo(self.offset)
        paintThumb()
    end

    function s:Wheel(delta)
        self:ScrollTo(self.offset - delta * 54)
        if self.onUserScroll then
            self.onUserScroll()
        end
    end

    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:Wheel(delta)
    end)
    s:SetScript("OnSizeChanged", function(self)
        self:Measure()
        if self.onResize then
            self.onResize()
        end
    end)
    bar:SetScript("OnMouseDown", function()
        s.drag = true
    end)
    bar:SetScript("OnMouseUp", function()
        s.drag = false
    end)
    bar:SetScript("OnUpdate", function(self)
        if not s.drag then
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
            if s.onUserScroll then
                s.onUserScroll()
            end
        end
    end)
    paintThumb()
    return s
end

-- ---- Resizing --------------------------------------------------------------------------------------

-- Min and max size of a resizable frame, whichever call this client has.
function T.SetResizeBounds(f, minW, minH, maxW, maxH)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(minW, minH, maxW, maxH)
    else
        f:SetMinResize(minW, minH)
        f:SetMaxResize(maxW, maxH)
    end
end

-- A corner grip that resizes `frame`. onDone() runs when the mouse is released.
function T.Grip(frame, onDone)
    local g = CreateFrame("Button", nil, frame)
    g:SetSize(16, 16)
    g:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    g.glyph = T.Glyph(g, "grip", 12, c.dim)
    g:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMRIGHT")
        g.glyph:SetColour(c.accent)
    end)
    g:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        g.glyph:SetColour(c.dim)
        if onDone then
            onDone()
        end
    end)
    return g
end

-- ---- Pop-up menu -----------------------------------------------------------------------------------

local MENU_W, MENU_ROW = 200, 24
local menu

local function buildMenu()
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:SetAllPoints(UIParent)
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:SetScript("OnClick", function()
        T.CloseMenu()
    end)
    catcher:Hide()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    T.Window(f)
    f:SetScript("OnHide", function()
        catcher:Hide()
    end)
    T.CloseOnEscape(f, "KlimaxMenuFrame")
    f.title = T.Text(f, 11, c.accent, "LEFT", true)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
    f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -8)
    f.rows = {}
    f:Hide()
    return { frame = f, catcher = catcher }
end

-- Opens a menu next to `anchor` (or the screen centre). items: {label, fn, checked, disabled, header}.
-- Returns the items. The menu closes on a pick, on a click anywhere else and with Escape.
function T.OpenMenu(anchor, title, items)
    menu = menu or buildMenu()
    local f = menu.frame
    local top = 10
    if title and title ~= "" then
        f.title:SetText(title)
        f.title:Show()
        top = 28
    else
        f.title:Hide()
    end
    local y = top
    for n, item in ipairs(items) do
        local row = f.rows[n]
        if not row then
            row = T.Button(f, "", MENU_W - 12, MENU_ROW, nil, "quiet")
            row.label:ClearAllPoints()
            row.label:SetPoint("LEFT", row, "LEFT", 10, 0)
            row.label:SetPoint("RIGHT", row, "RIGHT", -24, 0)
            row.label:SetJustifyH("LEFT")
            row.mark = T.Glyph(row, "check", 10, c.accent)
            f.rows[n] = row
        end
        row:SetWidth(MENU_W - 12)
        row.label:SetText(item.label)
        row.off = item.disabled and true or false
        row:SetEnabled(not row.off)
        row:SetScript("OnClick", function()
            T.CloseMenu()
            if item.fn and not item.disabled then
                item.fn()
            end
        end)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -y)
        row.mark:SetShown(item.checked and true or false)
        paintButton(row)
        row:Show()
        y = y + MENU_ROW
    end
    for n = #items + 1, #f.rows do
        f.rows[n]:Hide()
    end
    f:SetSize(MENU_W, y + 8)
    f:ClearAllPoints()
    if anchor then
        f:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    menu.catcher:Show()
    f:Show()
    f:SetAlpha(0)
    T.Animate("menu", 0.12, function(p)
        f:SetAlpha(T.Ease(p))
    end)
    return items
end

function T.CloseMenu()
    if menu then
        menu.frame:Hide()
        menu.catcher:Hide()
    end
end

function T.MenuOpen()
    return menu ~= nil and menu.frame:IsShown() and true or false
end

-- Makes a frame close with Escape (adds it to the client's special-frame list once).
function T.CloseOnEscape(frame, name)
    if UISpecialFrames and _G and name then
        _G[name] = frame
        tinsert(UISpecialFrames, name)
    end
end
