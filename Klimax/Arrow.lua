-- Direction arrow and distance (PRD 7.5).
--
-- The geometry (A.Compute) is pure so the busted specs can check it with stubbed positions.
-- The frame code only reads A.Read() and draws it.
--
-- Angle convention: bearing = atan2(-dx, dy) measured from north (+y), minus the player's facing.
-- A relative angle of 0 means straight ahead and a positive angle means the target is on the left.
-- The axis orientation of world coordinates is not verified in game yet (see docs/PROGRESS.md,
-- phase 07 smoke test). If the arrow mirrors left and right, flip the sign in A.Compute.
local _, K = ...
local L = K.L

local A = {}
K.Arrow = A

A.UPDATE_INTERVAL = 0.1                       -- 10 Hz (PRD 8)
A.TEXTURE = "Interface\\Minimap\\ROTATING-MINIMAPGUIDEARROW"
A.SIZE = 28
local TWO_PI = 2 * math.pi

-- Wraps an angle into (-pi, pi].
local function wrap(a)
    while a > math.pi do
        a = a - TWO_PI
    end
    while a <= -math.pi do
        a = a + TWO_PI
    end
    return a
end

-- Pure geometry. me and target are {cont = continent map id, x = yards, y = yards}; facing is
-- radians. Returns {kind = "arrow", rot, dist} or {kind = "travel"} when they are on different continents.
function A.Compute(me, target, facing)
    if me.cont ~= target.cont then
        return { kind = "travel" }
    end
    local dx, dy = target.x - me.x, target.y - me.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local rot = wrap(math.atan2(-dx, dy) - facing)
    return { kind = "arrow", rot = rot, dist = dist }
end

-- Player position in world yards: {cont, x, y, map}, or nil when there is no map position
-- (instances and some Classic zones), or when the world conversion is missing.
function A.PlayerWorld()
    local mapID = K.Compat.GetBestMapForPlayer()
    local pos = mapID and K.Compat.GetPlayerMapPosition(mapID)
    if not pos then
        return nil
    end
    local cont, wx, wy = K.Compat.GetWorldPos(mapID, pos.x, pos.y)
    if not cont then
        return nil
    end
    return { cont = cont, x = wx, y = wy, map = mapID }
end

-- The state the arrow should show now: {kind = "hidden" | "arrow" | "travel", rot, dist, zone}.
-- Reads the step the window is showing (K.UI.DisplayIndex), so the arrow follows focus.
function A.Read()
    local hidden = { kind = "hidden" }
    if not A.allowed or K.Option("arrow") == false or not K.UI then
        return hidden
    end
    local E = K.Engine
    local i = K.UI.DisplayIndex(E)
    local s = i and E.steps[i]
    if not s or not s.z or not s.x or not s.y then
        return hidden
    end
    local me = A.PlayerWorld()
    local facing = K.Compat.GetFacing()
    if not me or not facing then
        return hidden
    end
    local cont, tx, ty = K.Compat.GetWorldPos(s.z, s.x / 100, s.y / 100)
    if not cont then
        return hidden
    end
    local res = A.Compute(me, { cont = cont, x = tx, y = ty }, facing)
    local zone = K.zones and K.zones[s.z]
    res.zone = zone and zone[1] or "?"
    return res
end

-- ---- Frame -----------------------------------------------------------------------------------

A.frame = nil
A.allowed = true          -- set by the main window: false when the window is hidden or in combat

-- Anchors the arrow above the main window, or places it at its saved position when detached.
function A.Place(parent)
    local f = A.frame
    if not f then
        return
    end
    f:ClearAllPoints()
    local ui = K.cdb and K.cdb.ui
    local pos = ui and ui.arrowPos
    if K.Option("arrowDetached") and pos then
        f:SetPoint(pos.point, UIParent, pos.rel, pos.x, pos.y)
    elseif parent then
        f:SetPoint("BOTTOM", parent, "TOP", 0, 2)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    local draggable = K.Option("arrowDetached") and not K.Option("locked") or false
    f:SetMovable(draggable)
    f:EnableMouse(draggable)
    f:SetScale(K.Option("scale") or 1)
end

-- Builds the arrow frame once. parent is the main window (used when the arrow is attached).
function A.Build(parent)
    if A.frame then
        return
    end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(120, A.SIZE + 16)
    f:SetFrameStrata("MEDIUM")
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if K.Option("arrowDetached") and not K.Option("locked") then
            f:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, rel, x, y = f:GetPoint()
        K.cdb.ui = K.cdb.ui or {}
        K.cdb.ui.arrowPos = { point = point, rel = rel, x = x, y = y }
    end)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetSize(A.SIZE, A.SIZE)
    tex:SetPoint("TOP", f, "TOP", 0, 0)
    tex:SetTexture(A.TEXTURE)
    f.tex = tex

    local text = f:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    text:SetPoint("TOP", tex, "BOTTOM", 0, -1)
    text:SetTextColor(1, 1, 1)
    f.text = text

    A.frame = f
    A.Place(parent)
    f:Hide()
    return f
end

-- Draws A.Read() on the frame. Called at 10 Hz from the core ticker and after window changes.
function A.Update()
    local f = A.frame
    if not f then
        return
    end
    local r = A.Read()
    if r.kind == "arrow" then
        f.tex:SetRotation(r.rot)
        f.tex:Show()
        f.text:SetText(string.format(L.ARROW_YARDS, math.floor(r.dist + 0.5)))
        f:Show()
    elseif r.kind == "travel" then
        f.tex:Hide()
        f.text:SetText(string.format(L.ARROW_TRAVEL, r.zone))
        f:Show()
    else
        f:Hide()
    end
end

K.Every(A.UPDATE_INTERVAL, function()
    A.Update()
end)
