-- A small, non-blocking notice (PRD 7.12) in the Klimax theme: a dark card with an accent stripe that
-- slides in from above, waits (it stays while the mouse is over it), then fades out. Used for
-- on-the-way hints, plan notes and the elite reminder. It is our own frame: no secure frames, no
-- protected calls. One toast is on screen at a time; a new one replaces the old one.
local _, K = ...
local T = K.Theme

local Ts = {}
K.Toast = Ts

local FADE = 1.0            -- seconds of fade at the end
local WIDTH, PAD = 340, 12
local TOP = -96
local SLIDE = 14            -- pixels the card travels while it appears

local frame        -- built on first use
local remaining = 0

-- Keeps a text in the toast width. Pure, so the specs can check it.
function Ts.FormatLines(text, maxBytes)
    text = tostring(text or "")
    maxBytes = maxBytes or 220
    if #text > maxBytes then
        text = text:sub(1, maxBytes - 3) .. "..."
    end
    return text
end

-- Fade alpha for the time left: full while more than FADE seconds remain, then linear to 0.
function Ts.Alpha(left)
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
    f:SetSize(WIDTH, 64)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    T.Window(f)
    f.stripe = f:CreateTexture(nil, "ARTWORK")
    f.stripe:SetTexture(T.WHITE)
    T.Paint(f.stripe, T.c.accent)
    f.stripe:SetWidth(3)
    f.stripe:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.stripe:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    f.head = T.Text(f, 10, T.c.accent, "LEFT", true)
    f.head:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, -10)
    f.head:SetText(string.upper(K.L.ADDON_NAME))
    f.text = T.Text(f, 12, T.c.text)
    f.text:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, -26)
    f.text:SetWidth(WIDTH - 2 * PAD - 8)
    f.close = T.IconButton(f, "close", 22, function() f:Hide() end)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    f.buttons = {}
    for n = 1, 2 do
        local b = T.Button(f, "", 0, 22, nil, n == 1 and "primary" or "ghost")
        b:Hide()
        f.buttons[n] = b
    end
    f:SetScript("OnUpdate", function(self, elapsed)
        if self.hover then
            remaining = math.max(remaining, FADE + 0.5)
            self:SetAlpha(0.95)
            return
        end
        remaining = remaining - elapsed
        if remaining <= 0 then
            self:Hide()
            return
        end
        if not self.entering then
            self:SetAlpha(Ts.Alpha(remaining))
        end
    end)
    f:SetScript("OnEnter", function(self)
        self.hover = true
    end)
    f:SetScript("OnLeave", function(self)
        self.hover = false
    end)
    f:Hide()
    return f
end

-- Shows text for `seconds`. actions is an optional list of up to two {text = string, fn = fn};
-- a button runs its fn and hides the toast.
function Ts.Show(text, seconds, actions)
    if not frame then
        frame = build()
    end
    remaining = seconds or 8
    frame.text:SetText(Ts.FormatLines(text))
    local textH = frame.text:GetStringHeight()
    if not textH or textH <= 0 then
        textH = T.TextLines(Ts.FormatLines(text), WIDTH - 2 * PAD - 8, 12) * 15
    end
    local x, hasButtons = PAD + 4, false
    for n, b in ipairs(frame.buttons) do
        local a = actions and actions[n]
        if a then
            hasButtons = true
            b:SetLabel(a.text)
            b:SetScript("OnClick", function()
                frame:Hide()
                local ok, err = pcall(a.fn)
                if not ok then
                    K.Log("toast action failed", tostring(err))
                end
            end)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(26 + textH + 10))
            x = x + (b:GetWidth() or 90) + 6
            b:Show()
        else
            b:Hide()
        end
    end
    frame:SetHeight(26 + textH + 12 + (hasButtons and 32 or 0))
    frame.hover = false
    frame.entering = true
    frame:ClearAllPoints()
    frame:Show()
    T.Animate("toast", 0.25, function(p)
        local e = T.Ease(p)
        frame:ClearAllPoints()
        frame:SetPoint("TOP", UIParent, "TOP", 0, TOP + (1 - e) * SLIDE)
        frame:SetAlpha(0.95 * e)
    end, function()
        frame.entering = false
    end)
end

function Ts.Hide()
    if frame then
        frame:Hide()
    end
end

function Ts.IsShown()
    return frame ~= nil and frame:IsShown()
end
