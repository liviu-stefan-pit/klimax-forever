-- Plan view (phase 27, DYNAMIC_GUIDE_PLAN s8): a window with the next steps and a "why" for each, the
-- stops coming up (hubs and zone changes). /klimax view toggles it. The model is pure so the specs
-- check it; the frame only draws it. Nothing here is a Blizzard template (taint-free).
local _, K = ...
local L = K.L
local T = K.Theme

local V = {}
K.PlanView = V

V.MAX_STEPS = 8
V.MAX_AHEAD = 6

-- The window's rows from a plan: {steps = {{n, text, why, tip}}, ahead = {lines}, empty = bool}. Pure.
function V.Model(plan, env)
    local m = { steps = {}, ahead = {}, empty = true }
    if not plan or not plan.steps or #plan.steps == 0 then
        return m
    end
    m.empty = false
    local Ex = K.Plan.Explain
    for i = 1, math.min(V.MAX_STEPS, #plan.steps) do
        local s = plan.steps[i]
        local what = env.L[Ex.KIND[s.t]] or s.t
        local name = s.n or (s.to and env.zoneName(s.to)) or ""
        m.steps[#m.steps + 1] = {
            n = i, step = s, text = string.format("%d. %s  %s", i, what, name),
            why = K.Planner.Why(s), tip = Ex.Tip(s, env),
        }
    end
    local lines = Ex.ForecastLines(Ex.Forecast(plan, env), env)
    for i = 1, math.min(V.MAX_AHEAD, #lines) do
        m.ahead[#m.ahead + 1] = lines[i]
    end
    return m
end

local WIDTH, ROW = 440, 38
local c = T.c

local function build()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(WIDTH, 100)
    f:SetPoint("CENTER", UIParent, "CENTER", 260, 0)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    T.Window(f)
    T.CloseOnEscape(f, "KlimaxPlanViewFrame")
    f.title = T.Text(f, 17, c.text, "LEFT", true)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    f.title:SetText(L.VIEW_TITLE)
    f.close = T.IconButton(f, "close", 24, function() f:Hide() end, L.VIEW_CLOSE)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    f.rows = {}
    f.aheadHead = T.Text(f, 11, c.accent, "LEFT", true)
    f.aheadHead:SetText(string.upper(L.VIEW_AHEAD))
    f.aheadLines = {}
    f.empty = T.Text(f, 12, c.sub)
    f.empty:SetWidth(WIDTH - 28)
    f.empty:SetText(L.VIEW_EMPTY)
    f:Hide()
    return f
end

local function row(f, n)
    local r = f.rows[n]
    if r then
        return r
    end
    r = CreateFrame("Button", nil, f)
    r:SetSize(WIDTH - 28, ROW)
    r.surface = T.Surface(r, c.card, { 1, 1, 1, 0 })
    r.stripe = r:CreateTexture(nil, "ARTWORK")
    r.stripe:SetTexture(T.WHITE)
    T.Paint(r.stripe, c.accent)
    r.stripe:SetWidth(3)
    r.stripe:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.stripe:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
    r.text = T.Text(r, 12, c.text)
    r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 12, -5)
    r.why = T.Text(r, 10, c.sub)
    r.why:SetPoint("TOPLEFT", r, "TOPLEFT", 12, -20)
    r.why:SetWidth(WIDTH - 52)
    r:SetScript("OnEnter", function(self)
        self.surface:SetFill(c.cardHover)
        T.ShowTip(self, self.tip, "ANCHOR_RIGHT")
    end)
    r:SetScript("OnLeave", function(self)
        self.surface:SetFill(c.card)
        T.HideTip()
    end)
    f.rows[n] = r
    return r
end

function V.Refresh()
    local f = V.frame
    if not f or not f:IsShown() then
        return
    end
    local plan = K.Planner and K.Planner:Get()
    local m = V.Model(plan, K.Planner.ExplainEnv())
    local y = -46
    for n = 1, #f.rows do
        f.rows[n]:Hide()
    end
    f.empty:Hide()
    f.aheadHead:Hide()
    for _, fs in ipairs(f.aheadLines) do
        fs:Hide()
    end
    if m.empty then
        f.empty:ClearAllPoints()
        f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y)
        f.empty:Show()
        y = y - 40
    end
    for n, item in ipairs(m.steps) do
        local r = row(f, n)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y)
        r.text:SetText(item.text)
        r.why:SetText(item.why)
        r.tip = item.tip
        r:Show()
        y = y - ROW - 2
    end
    if #m.ahead > 0 then
        f.aheadHead:ClearAllPoints()
        f.aheadHead:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y - 4)
        f.aheadHead:Show()
        y = y - 22
        for n, line in ipairs(m.ahead) do
            local fs = f.aheadLines[n]
            if not fs then
                fs = T.Text(f, 11, c.sub)
                fs:SetWidth(WIDTH - 28)
                f.aheadLines[n] = fs
            end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y)
            fs:SetText(line)
            fs:Show()
            y = y - 16
        end
    end
    f:SetHeight(-y + 14)
end

function V.Toggle()
    if not V.frame then
        V.frame = build()
    end
    if V.frame:IsShown() then
        V.frame:Hide()
    else
        V.frame:Show()
        V.Refresh()
    end
end

if K.Planner then
    K.Planner:OnChange(function()
        V.Refresh()
    end)
end
