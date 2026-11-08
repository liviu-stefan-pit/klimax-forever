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

local c = T.c
local W_W, ROW_H, PAD = 460, 30, 18
local VALUE_W = 210

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
    T.Window(f)
    T.CloseOnEscape(f, "KlimaxWizardFrame")
    f.title = T.Text(f, 18, c.text, "LEFT", true)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
    f.title:SetText(L.WIZARD_TITLE)
    f.title:SetWidth(W_W - 2 * PAD - 24)
    f.intro = T.Text(f, 12, c.sub)
    f.intro:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + 28))
    f.intro:SetWidth(W_W - 2 * PAD)
    f.intro:SetText(L.WIZARD_INTRO)

    local choices = {}
    for _, preset in ipairs(Pr.PRESETS) do
        choices[#choices + 1] = { value = preset.id, text = L["PRESET_" .. preset.id] or preset.id }
    end
    f.presets = T.Segmented(f, choices, function(id)
        Wz.draft = Pr.ApplyPreset(id)
        Wz.Refresh()
    end)
    f.presets:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + 62))

    f.rows, f.labels = {}, {}
    for n, field in ipairs(Pr.FIELDS) do
        local y = PAD + 100 + (n - 1) * ROW_H
        local lbl = T.Text(f, 12, c.sub)
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(y + 6))
        f.labels[n] = lbl
        local b = T.Button(f, "", VALUE_W, ROW_H - 4, function()
            local p = Pr.Normalize(Wz.draft)
            Wz.draft = Pr.Set(field.key, Pr.NextChoice(field.key, p[field.key]))
            Wz.Refresh()
        end, "ghost")
        b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y)
        f.rows[n] = b
    end
    f.preview = T.Text(f, 12, c.good)
    f.preview:SetWidth(W_W - 2 * PAD)
    f.done = T.Button(f, L.WIZARD_DONE, 110, 30, function()
        Pr.Save(Pr.Normalize(Wz.draft))
        f:Hide()
    end, "primary")
    f.done:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
    f:Hide()
    return f
end

function Wz.Refresh()
    local f = Wz.frame
    if not f then
        return
    end
    local p = Pr.Normalize(Wz.draft)
    f.presets:SetValue(p.preset)
    local rows = Wz.Rows(p)
    for n, row in ipairs(rows) do
        local field = Pr.FIELDS[n]
        f.labels[n]:SetText(L["PROFILE_" .. field.key] or field.key)
        f.rows[n]:SetLabel(L["PROFILE_" .. field.key .. "_" .. p[field.key]] or p[field.key])
        f.rows[n]:SetWidth(VALUE_W)
        f.rows[n].tip = row.text
    end
    local lines = Pr.Preview(Wz.draft)
    local top = PAD + 100 + #rows * ROW_H + 10
    f.preview:ClearAllPoints()
    f.preview:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top)
    f.preview:SetText(table.concat(lines, "\n"))
    local ph = f.preview:GetStringHeight()
    if not ph or ph <= 0 then
        ph = #lines * 15
    end
    f:SetHeight(top + ph + 16 + 30 + PAD)
end

function Wz.Open()
    Wz.frame = Wz.frame or build()
    Wz.draft = Pr.Get()
    if not Pr.Chosen() then
        Pr.Save(Wz.draft)  -- opening the wizard counts as choosing: it will not pop up again
    end
    Wz.Refresh()
    Wz.frame:Show()
    Wz.frame:SetAlpha(0)
    T.Animate("wizard", 0.22, function(p)
        Wz.frame:SetAlpha(T.Ease(p))
    end)
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
