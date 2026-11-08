-- NPC info card (UI overhaul phase 14): click the NPC of a step to see who it is, what it does and
-- where it stands, with a button that points the arrow at the step. Data comes from the compiled
-- world database (K.WorldDB.Npc); nothing is invented. The model is pure (specs test it); the frame
-- is a plain themed window.
local _, K = ...
local L = K.L
local T = K.Theme
local c = T.c

local NI = {}
K.NpcInfo = NI

local WIDTH, PAD = 300, 16

-- Display word for a role code: a known role, "<Class> trainer" for ct_CLASS, "<Profession> trainer"
-- for pt_Profession, else the code itself.
local function roleName(r)
    if L["ROLE_" .. r] then
        return L["ROLE_" .. r]
    end
    local kind, rest = r:match("^(%a%a)_(.+)$")
    if kind == "ct" or kind == "pt" then
        return string.format(L.ROLE_TRAINER, rest:sub(1, 1):upper() .. rest:sub(2):lower())
    end
    return r
end
NI.RoleName = roleName

-- The card's content for a step: {none = true} without NPC data, else {name, sub, roles, places}.
-- roles are display words; places are "Zone x, y" lines.
function NI.Model(step)
    local npc = step and step.npc and K.WorldDB and K.WorldDB.Npc(step.npc)
    if not npc then
        return { none = true, name = step and step.n or "" }
    end
    local roles = {}
    for _, r in ipairs(npc.r or {}) do
        roles[#roles + 1] = roleName(r)
    end
    local places = {}
    for _, p in ipairs(npc.p or {}) do
        local zone = K.zones and K.zones[p[1]]
        places[#places + 1] = string.format(L.NPC_AT, zone and zone[1] or tostring(p[1]), p[2], p[3])
    end
    return { name = npc.n or "?", sub = npc.sub, roles = roles, places = places }
end

NI.frame = nil

local function build()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(WIDTH, 160)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    T.Window(f)
    T.CloseOnEscape(f, "KlimaxNpcInfoFrame")
    f.stripe = f:CreateTexture(nil, "ARTWORK")
    f.stripe:SetTexture(T.WHITE)
    T.Paint(f.stripe, c.npc)
    f.stripe:SetWidth(3)
    f.stripe:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.stripe:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    f.name = T.Text(f, 17, c.npc, "LEFT", true)
    f.name:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -14)
    f.name:SetWidth(WIDTH - 2 * PAD - 24)
    f.sub = T.Text(f, 11, c.sub)
    f.roles = T.Text(f, 12, c.text)
    f.places = T.Text(f, 12, c.sub)
    f.close = T.IconButton(f, "close", 22, function() f:Hide() end, L.TIP_CLOSE)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    f.point = T.Button(f, L.NPC_POINT, 0, 26, function()
        if f.step and K.UI then
            K.UI.focusKey = f.step.k
            K.UI.Refresh()
        end
        f:Hide()
    end, "primary")
    f.point:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 14)
    f.closeBtn = T.Button(f, L.MENU_close, 0, 26, function() f:Hide() end, "ghost")
    f.closeBtn:SetPoint("LEFT", f.point, "RIGHT", 8, 0)
    f:Hide()
    return f
end

local function stack(f, fs, text, y, gap)
    fs:SetWidth(WIDTH - 2 * PAD)
    fs:SetText(text)
    fs:ClearAllPoints()
    if not text or text == "" then
        fs:Hide()
        return y
    end
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
    fs:Show()
    local h = fs:GetStringHeight()
    if not h or h <= 0 then
        h = T.TextLines(text, WIDTH - 2 * PAD, 12) * 15
    end
    return y + h + gap
end

-- Opens the card for a step (i is its index in the engine, kept for callers; the step is enough).
function NI.Open(step)
    local f = NI.frame or build()
    NI.frame = f
    local m = NI.Model(step)
    f.step = step
    f.name:SetText(m.name)
    local y = 42
    if m.none then
        y = stack(f, f.sub, L.MENU_NPC_NONE, y, 8)
        stack(f, f.roles, "", y, 0)
        stack(f, f.places, "", y, 0)
    else
        y = stack(f, f.sub, m.sub and ("<" .. m.sub .. ">") or "", y, 10)
        y = stack(f, f.roles, #m.roles > 0 and table.concat(m.roles, " · ") or "", y, 8)
        y = stack(f, f.places, table.concat(m.places, "\n"), y, 8)
    end
    local canPoint = step and step.z and step.x and step.y
    f.point:SetShown(canPoint and true or false)
    f.point:SetDisabled(not canPoint)
    f:SetHeight(y + 14 + 26 + 8)
    f:Show()
    f:SetAlpha(0)
    T.Animate("npcinfo", 0.18, function(p)
        f:SetAlpha(T.Ease(p))
    end)
    return m
end

function NI.Close()
    if NI.frame then
        NI.frame:Hide()
    end
end
