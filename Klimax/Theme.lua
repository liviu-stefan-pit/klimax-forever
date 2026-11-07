-- Theme: colours, fonts and small frame helpers shared by the newer windows (phase 22 step menu and
-- wizard). The UI overhaul (UI_OVERHAUL_PLAN phase 11) extends this file; nothing here is a
-- Blizzard template, so it stays taint-free.
local _, K = ...

local T = {}
K.Theme = T

T.FONT = "Fonts\\FRIZQT__.TTF"
T.WHITE = "Interface\\Buttons\\WHITE8X8"

T.colour = {
    gold = { 1, 0.82, 0 },
    text = { 1, 1, 1 },
    muted = { 0.65, 0.65, 0.65 },
    good = { 0.35, 0.9, 0.35 },
    bad = { 0.95, 0.4, 0.4 },
    panel = { 0.05, 0.05, 0.06, 0.94 },
    row = { 1, 1, 1, 0.05 },
    rowHover = { 1, 0.82, 0, 0.18 },
    rule = { 0.6, 0.5, 0.2, 0.8 },
}

-- A solid background texture covering the frame.
function T.Backdrop(frame, c)
    local tex = frame:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(frame)
    tex:SetTexture(T.WHITE)
    tex:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    return tex
end

function T.Text(parent, size, c, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(T.FONT, size or 12, "")
    fs:SetJustifyH(justify or "LEFT")
    c = c or T.colour.text
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

-- A flat text button with a hover highlight. onClick(self, mouseButton).
function T.Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 120, h or 20)
    b.bg = T.Backdrop(b, T.colour.row)
    b.label = T.Text(b, 12)
    b.label:SetPoint("LEFT", b, "LEFT", 6, 0)
    b.label:SetText(text or "")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", function(self)
        local c = T.colour.rowHover
        self.bg:SetVertexColor(c[1], c[2], c[3], c[4])
    end)
    b:SetScript("OnLeave", function(self)
        local c = T.colour.row
        self.bg:SetVertexColor(c[1], c[2], c[3], c[4])
    end)
    b:SetScript("OnClick", function(self, mouseButton)
        if onClick then
            onClick(self, mouseButton)
        end
    end)
    return b
end
