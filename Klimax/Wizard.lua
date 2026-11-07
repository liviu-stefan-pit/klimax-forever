-- First-run wizard and profile editor (phase 22, DYNAMIC_GUIDE_PLAN s4.4). Shows once per character
-- (until a profile is chosen), and again with /klimax profile. Preset buttons on top, one row per
-- setting (click to cycle), a plain-language preview, and Done. Every change is saved and replans.
local _, K = ...
local L = K.L
local T = K.Theme
local Pr = K.Profile

local Wz = {}
K.Wizard = Wz

Wz.SHOW_DELAY = 3  -- seconds after login, so the world has loaded

-- Row texts for a profile: {key, text}, in field order. Pure.
function Wz.Rows(p)
    p = Pr.Normalize(p)
    local rows = {}
    for _, f in ipairs(Pr.FIELDS) do
        local label = L["PROFILE_" .. f.key] or f.key
        local value = L["PROFILE_" .. f.key .. "_" .. p[f.key]] or p[f.key]
        rows[#rows + 1] = { key = f.key, text = string.format("%s: %s", label, value) }
    end
    return rows
end

-- The working copy edited by the window (saved on every change).
Wz.draft = nil

local W_W, ROW_H = 380, 20

local function build()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(W_W, 120)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    T.Backdrop(f, T.colour.panel)
    f.title = T.Text(f, 15, T.colour.gold)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
    f.title:SetText(L.WIZARD_TITLE)
    f.intro = T.Text(f, 11, T.colour.muted)
    f.intro:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
    f.intro:SetWidth(W_W - 20)
    f.intro:SetText(L.WIZARD_INTRO)
    f.presets, f.rows = {}, {}
    local x = 10
    for n, preset in ipairs(Pr.PRESETS) do
        local b = T.Button(f, L["PRESET_" .. preset.id] or preset.id, 70, ROW_H, function()
            Wz.draft = Pr.ApplyPreset(preset.id)
            Wz.Refresh()
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -52)
        f.presets[n] = b
        x = x + 72
    end
    for n, field in ipairs(Pr.FIELDS) do
        local b = T.Button(f, "", W_W - 20, ROW_H - 2, function()
            local p = Pr.Normalize(Wz.draft)
            Wz.draft = Pr.Set(field.key, Pr.NextChoice(field.key, p[field.key]))
            Wz.Refresh()
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -(78 + (n - 1) * ROW_H))
        f.rows[n] = b
    end
    local top = 78 + #Pr.FIELDS * ROW_H + 6
    f.preview = T.Text(f, 11, T.colour.good)
    f.preview:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -top)
    f.preview:SetWidth(W_W - 20)
    f.done = T.Button(f, L.WIZARD_DONE, 80, ROW_H + 2, function()
        Pr.Save(Pr.Normalize(Wz.draft))
        f:Hide()
    end)
    f.done:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 8)
    f:Hide()
    return f
end

function Wz.Refresh()
    local f = Wz.frame
    if not f then
        return
    end
    local rows = Wz.Rows(Wz.draft)
    for n, row in ipairs(rows) do
        f.rows[n].label:SetText(row.text)
    end
    local lines = Pr.Preview(Wz.draft)
    f.preview:SetText(table.concat(lines, "\n"))
    local h = 78 + #rows * ROW_H + 14 + #lines * 14 + 36
    f:SetHeight(h)
end

function Wz.Open()
    Wz.frame = Wz.frame or build()
    Wz.draft = Pr.Get()
    if not Pr.Chosen() then
        Pr.Save(Wz.draft)  -- opening the wizard counts as choosing: it will not pop up again
    end
    Wz.Refresh()
    Wz.frame:Show()
end

-- First login of a character without a profile: open the wizard once the world has loaded.
K.On("PLAYER_LOGIN", function()
    if Pr.Chosen() or (K.Option and K.Option("wizard") == false) then
        return
    end
    C_Timer.After(Wz.SHOW_DELAY, function()
        if not Pr.Chosen() then
            Wz.Open()
        end
    end)
end)
