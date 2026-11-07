-- A small, non-blocking message that fades out (PRD 7.12). Used for on-the-way hints and the elite
-- reminder. It is our own frame: no secure frames, no protected calls. One toast is on screen at a
-- time; a new one replaces the old one.
local _, K = ...

local T = {}
K.Toast = T

local WHITE = "Interface\\Buttons\\WHITE8X8"
local FONT = "Fonts\\FRIZQT__.TTF"
local FADE = 1.0            -- seconds of fade at the end
local BUTTON_W, BUTTON_H = 120, 18

local frame        -- built on first use
local remaining = 0
local shownFor = 0

-- Keeps a text in the toast width. Pure, so the specs can check it.
function T.FormatLines(text, maxBytes)
    text = tostring(text or "")
    maxBytes = maxBytes or 220
    if #text > maxBytes then
        text = text:sub(1, maxBytes - 3) .. "..."
    end
    return text
end

-- Fade alpha for the time left: 1 while more than FADE seconds remain, then linear to 0.
function T.Alpha(left)
    if left >= FADE then
        return 0.95
    end
    if left <= 0 then
        return 0
    end
    return 0.95 * left / FADE
end

local function build()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(300, 64)
    f:SetFrameStrata("DIALOG")
    f:SetPoint("TOP", UIParent, "TOP", 0, -90)
    f:SetClampedToScreen(true)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0, 0, 0, 0.85)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(FONT, 10, "")
    f.text:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    f.text:SetWidth(284)
    f.text:SetJustifyH("LEFT")
    f.text:SetJustifyV("TOP")
    f.buttons = {}
    for n = 1, 2 do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(BUTTON_W, BUTTON_H)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8 + (n - 1) * (BUTTON_W + 8), 6)
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetFont(FONT, 10, "")
        b.text:SetAllPoints()
        b:Hide()
        f.buttons[n] = b
    end
    f:SetScript("OnUpdate", function(self, elapsed)
        remaining = remaining - elapsed
        if remaining <= 0 then
            self:Hide()
            return
        end
        self:SetAlpha(T.Alpha(remaining))
    end)
    f:Hide()
    return f
end

-- Shows text for `seconds`. actions is an optional list of up to two {text = string, fn = fn};
-- a button runs its fn and hides the toast.
function T.Show(text, seconds, actions)
    if not frame then
        frame = build()
    end
    shownFor = seconds or 8
    remaining = shownFor
    frame.text:SetText(T.FormatLines(text))
    for n, b in ipairs(frame.buttons) do
        local a = actions and actions[n]
        if a then
            b.text:SetText(a.text)
            b:SetScript("OnClick", function()
                frame:Hide()
                local ok, err = pcall(a.fn)
                if not ok then
                    K.Log("toast action failed", tostring(err))
                end
            end)
            b:Show()
        else
            b:Hide()
        end
    end
    frame:SetAlpha(0.95)
    frame:Show()
end

function T.Hide()
    if frame then
        frame:Hide()
    end
end

function T.IsShown()
    return frame ~= nil and frame:IsShown()
end
