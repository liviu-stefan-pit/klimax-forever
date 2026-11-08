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

local WIDTH, ROW = 420, 30

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
    T.Backdrop(f, T.colour.panel)
    f.title = T.Text(f, 15, T.colour.gold)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
    f.title:SetText(L.VIEW_TITLE)
    f.close = T.Button(f, L.VIEW_CLOSE, 60, 18, function() f:Hide() end)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
    f.rows = {}
    f.aheadHead = T.Text(f, 12, T.colour.gold)
    f.aheadHead:SetText(L.VIEW_AHEAD)
    f.aheadLines = {}
    f.empty = T.Text(f, 11, T.colour.muted)
    f.empty:SetWidth(WIDTH - 20)
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
    r:SetSize(WIDTH - 20, ROW)
    r.bg = T.Backdrop(r, T.colour.row)
    r.text = T.Text(r, 12)
    r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 6, -3)
    r.why = T.Text(r, 10, T.colour.muted)
    r.why:SetPoint("TOPLEFT", r, "TOPLEFT", 6, -16)
    r.why:SetWidth(WIDTH - 32)
    r:SetScript("OnEnter", function(self)
        if self.tip and GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for i, line in ipairs(self.tip) do
                if i == 1 then
                    GameTooltip:SetText(line, 1, 1, 1, 1, true)
                else
                    GameTooltip:AddLine(line, 0.8, 0.8, 0.8, true)
                end
            end
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
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
    local y = -30
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
        f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y)
        f.empty:Show()
        y = y - 40
    end
    for n, item in ipairs(m.steps) do
        local r = row(f, n)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y)
        r.text:SetText(item.text)
        r.why:SetText(item.why)
        r.tip = item.tip
        r:Show()
        y = y - ROW - 2
    end
    if #m.ahead > 0 then
        f.aheadHead:ClearAllPoints()
        f.aheadHead:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y - 4)
        f.aheadHead:Show()
        y = y - 22
        for n, line in ipairs(m.ahead) do
            local fs = f.aheadLines[n]
            if not fs then
                fs = T.Text(f, 11, T.colour.muted)
                fs:SetWidth(WIDTH - 20)
                f.aheadLines[n] = fs
            end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y)
            fs:SetText(line)
            fs:Show()
            y = y - 16
        end
    end
    f:SetHeight(-y + 10)
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
