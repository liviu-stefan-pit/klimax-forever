-- Trainer budget filter (PRD 7.7). On TRAINER steps the window text says what to learn and what can
-- wait. While a trainer window is open, a small list of the essentials it offers is shown with the
-- money check. Klimax only reads the trainer window; it never buys or clicks anything.
local _, K = ...
local L = K.L
local C = K.Compat

local T = {}
K.Trainer = T

local SHOW_TEXT = 4     -- essentials named in the window hint
local SHOW_SKIP = 2
local LIST_ROWS = 9

-- The filter band in force for a class at a level: the last band with from <= level.
function T.Band(class, level)
    local bands = K.TrainerFilters and K.TrainerFilters[class]
    if not bands then
        return nil
    end
    local best
    for _, band in ipairs(bands) do
        if band.from <= (level or 1) then
            best = band
        end
    end
    return best
end

-- Plans a trainer visit. services: list of {name, category, cost(copper)}. band: a Band result.
-- Only spells the trainer offers now (category "available") are planned. Essentials keep the band's
-- order, which is also the buying order when money is short (must-haves first).
-- Returns {essential = {{name, cost}...}, skip = {names...}, cost = copper, money = copper,
--          short = copper missing (0 when enough)}.
function T.Plan(services, band, money)
    local byName = {}
    for _, s in ipairs(services or {}) do
        if s.name then
            byName[s.name] = s
        end
    end
    local plan = { essential = {}, skip = {}, cost = 0, money = money or 0, short = 0 }
    if not band then
        return plan
    end
    for _, name in ipairs(band.essential or {}) do
        local s = byName[name]
        if s and s.category == "available" then
            plan.essential[#plan.essential + 1] = { name = name, cost = s.cost or 0 }
            plan.cost = plan.cost + (s.cost or 0)
        end
    end
    for _, name in ipairs(band.skipForNow or {}) do
        local s = byName[name]
        if s and s.category == "available" then
            plan.skip[#plan.skip + 1] = name
        end
    end
    if plan.cost > plan.money then
        plan.short = plan.cost - plan.money
    end
    return plan
end

-- Joins names with ", ", keeping at most `max` of them.
local function names(list, max)
    local out = {}
    for i = 1, math.min(#list, max) do
        out[#out + 1] = list[i]
    end
    return table.concat(out, ", ")
end

-- The window hint for a TRAINER step, from the band alone (no trainer window needed).
function T.Hint()
    local class = K.player and K.player.class
    local band = T.Band(class, (K.player and K.player.level) or 1)
    if not band then
        return nil
    end
    local essentials = {}
    for i, name in ipairs(band.essential or {}) do
        essentials[i] = name
    end
    if #essentials == 0 then
        return nil
    end
    local text = string.format(L.HINT_TRAIN, names(essentials, SHOW_TEXT))
    if band.skipForNow and #band.skipForNow > 0 then
        text = text .. string.format(L.HINT_TRAIN_SKIP, names(band.skipForNow, SHOW_SKIP))
    end
    return text
end

-- Money line for a plan: enough, or how much is missing and the order to buy in.
function T.MoneyLine(plan)
    if plan.short > 0 then
        local order = {}
        for _, e in ipairs(plan.essential) do
            order[#order + 1] = e.name
        end
        return string.format(L.TRAIN_SHORT, K.Rewards.Money(plan.short), names(order, 3))
    end
    return string.format(L.TRAIN_MONEY, K.Rewards.Money(plan.money), K.Rewards.Money(plan.cost))
end

-- ---- Trainer window frame ---------------------------------------------------------------------

local frame

local function build()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(260, 40 + LIST_ROWS * 14 + 16)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetPoint("LEFT", UIParent, "LEFT", 20, 0)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0, 0, 0, 0.88)
    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    f.title:SetText(L.TRAIN_TITLE)
    f.money = f:CreateFontString(nil, "OVERLAY")
    f.money:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    f.money:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -24)
    f.money:SetWidth(244)
    f.money:SetJustifyH("LEFT")
    f.rows = {}
    for n = 1, LIST_ROWS do
        local fs = f:CreateFontString(nil, "OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -40 - (n - 1) * 14)
        fs:SetWidth(244)
        fs:SetJustifyH("LEFT")
        f.rows[n] = fs
    end
    f:Hide()
    return f
end

-- Reads every trainer row and returns the list of services.
function T.ReadServices()
    local services = {}
    local count = (GetNumTrainerServices and GetNumTrainerServices()) or 0
    for i = 1, count do
        local s = C.GetTrainerService(i)
        if s then
            services[#services + 1] = s
        end
    end
    return services
end

-- Opens the list for the window that is showing now.
function T.Open()
    local class = K.player and K.player.class
    local band = T.Band(class, (K.player and K.player.level) or 1)
    local plan = T.Plan(T.ReadServices(), band, C.GetMoney())
    K.trainerPlan = plan
    frame = frame or build()
    frame.money:SetText(T.MoneyLine(plan))
    local rows = {}
    for _, e in ipairs(plan.essential) do
        rows[#rows + 1] = string.format("+ %s  (%s)", e.name, K.Rewards.Money(e.cost))
    end
    for _, name in ipairs(plan.skip) do
        rows[#rows + 1] = string.format("- %s  (skip for now)", name)
    end
    for n = 1, LIST_ROWS do
        frame.rows[n]:SetText(rows[n] or "")
    end
    frame:Show()
    return plan
end

function T.Close()
    if frame then
        frame:Hide()
    end
end

K.On("TRAINER_SHOW", function()
    T.Open()
end)

K.On("TRAINER_CLOSED", function()
    T.Close()
end)
