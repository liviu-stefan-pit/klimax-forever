-- Options (UI overhaul phase 16): the option schema, K.Option / K.SetOption, and the settings panel.
-- The panel is registered in the game's Options > AddOns list when the client has the Settings API
-- (or the older interface options list); /klimax options and the window menu open it directly. When
-- neither API exists the same content opens as a standalone window. Everything is our own frames.
--
-- The schema (O.SECTIONS) is data: a section has a title and rows; a row is a "bool" (toggle switch)
-- or a "choice" (segmented control over a list of values). The pure helpers (NextValue, ToggledValue,
-- Format, Migrate) are tested without a client.
local _, K = ...
local L = K.L
local T = K.Theme

local O = {}
K.Options = O

local DEFAULTS = {
    arrow = true, arrowScale = 1, arrowLabel = true,
    hideInCombat = false, locked = false,
    bagThreshold = 3, fontScale = 1, scale = 1, alpha = 0.85, opportunities = true, toasts = true,
    animations = true,
}
O.DEFAULTS = DEFAULTS

-- Reads an option with its default. Safe before SavedVariables are loaded.
function K.Option(key)
    local db = K.db
    local v = db and db.options and db.options[key]
    if v == nil then
        return DEFAULTS[key]
    end
    return v
end

-- Stores an option and tells the listeners (live frames) that it changed.
function K.SetOption(key, value)
    if K.db then
        K.db.options = K.db.options or {}
        K.db.options[key] = value
    end
    for _, fn in ipairs(O.listeners) do
        fn(key, value)
    end
end

O.listeners = {}

-- fn(key, value) runs after every option change.
function O.OnChange(fn)
    O.listeners[#O.listeners + 1] = fn
end

-- ---- Schema ---------------------------------------------------------------------------------------

O.SECTIONS = {
    {
        id = "window", title = "SEC_WINDOW",
        rows = {
            { key = "locked", kind = "bool", label = "OPT_LOCK", tip = "OPT_LOCK_TIP" },
            { key = "hideInCombat", kind = "bool", label = "OPT_HIDE_COMBAT", tip = "OPT_HIDE_COMBAT_TIP" },
            { key = "animations", kind = "bool", label = "OPT_ANIMATIONS", tip = "OPT_ANIMATIONS_TIP" },
            { key = "scale", kind = "choice", label = "OPT_SCALE", values = { 0.8, 0.9, 1, 1.1, 1.25 } },
            { key = "alpha", kind = "choice", label = "OPT_ALPHA", values = { 0.4, 0.6, 0.85, 1 } },
            { key = "fontScale", kind = "choice", label = "OPT_FONT", values = { 0.85, 1, 1.15, 1.3 } },
        },
    },
    {
        id = "arrow", title = "SEC_ARROW",
        rows = {
            { key = "arrow", kind = "bool", label = "OPT_ARROW", tip = "OPT_ARROW_TIP" },
            { key = "arrowLabel", kind = "bool", label = "OPT_ARROW_LABEL", tip = "OPT_ARROW_LABEL_TIP" },
            { key = "arrowScale", kind = "choice", label = "OPT_ARROW_SCALE",
                values = { 0.75, 1, 1.25, 1.5 } },
        },
    },
    {
        id = "helpers", title = "SEC_HELPERS",
        rows = {
            { key = "toasts", kind = "bool", label = "OPT_TOASTS", tip = "OPT_TOASTS_TIP" },
            { key = "opportunities", kind = "bool", label = "OPT_OPPORTUNITIES", tip = "OPT_OPPORTUNITIES_TIP" },
            { key = "bagThreshold", kind = "choice", label = "OPT_BAG", values = { 1, 2, 3, 4, 5, 6 } },
        },
    },
}

-- Every row of every section, flat, in display order.
function O.AllRows()
    local out = {}
    for _, sec in ipairs(O.SECTIONS) do
        for _, row in ipairs(sec.rows) do
            out[#out + 1] = row
        end
    end
    return out
end

function O.Row(key)
    for _, row in ipairs(O.AllRows()) do
        if row.key == key then
            return row
        end
    end
    return nil
end

-- The value after current in values; the first value when current is not in the list.
function O.NextValue(values, current)
    for i = 1, #values do
        if values[i] == current then
            return values[i % #values + 1]
        end
    end
    return values[1]
end

-- The value a row would switch to.
function O.ToggledValue(row)
    local current = K.Option(row.key)
    if row.kind == "bool" then
        return not current
    end
    return O.NextValue(row.values, current)
end

-- Text of a choice value in a segmented control: 0.85 -> "85%" for the scale-like rows, else as is.
local PERCENT = { scale = true, alpha = true, fontScale = true, arrowScale = true }
function O.Format(row, value)
    if PERCENT[row.key] then
        return string.format("%d%%", math.floor(value * 100 + 0.5))
    end
    return tostring(value)
end

-- The segmented-control choices of a row: {value, text}.
function O.Choices(row)
    local out = {}
    for _, v in ipairs(row.values or {}) do
        out[#out + 1] = { value = v, text = O.Format(row, v) }
    end
    return out
end

-- Drops stored values that are not valid for their row (a hand-edited or old SavedVariables file), so
-- the panel never shows a segmented control with nothing selected. Returns the number of fixes.
function O.Migrate(options)
    local fixed = 0
    if type(options) ~= "table" then
        return 0
    end
    for _, row in ipairs(O.AllRows()) do
        local v = options[row.key]
        if v ~= nil then
            local ok = false
            if row.kind == "bool" then
                ok = type(v) == "boolean"
            else
                for _, allowed in ipairs(row.values) do
                    ok = ok or allowed == v
                end
            end
            if not ok then
                options[row.key] = nil
                fixed = fixed + 1
            end
        end
    end
    return fixed
end

-- Puts every option back to its default.
function O.ResetAll()
    if K.db then
        K.db.options = {}
    end
    for key, value in pairs(DEFAULTS) do
        for _, fn in ipairs(O.listeners) do
            fn(key, value)
        end
    end
end

-- ---- Panel ----------------------------------------------------------------------------------------

local ROW_H, PAD = 30, 16

-- Link buttons shown at the top of the panel: {text, fn}.
function O.Actions()
    return {
        { text = L.OPT_BTN_GUIDE, fn = function() if K.UI then K.UI.Show() end end },
        { text = L.OPT_BTN_PROFILE, fn = function() K.Profile.Command("") end },
        { text = L.MENU_RESYNC, fn = function() K.Resync() end },
        { text = L.OPT_BTN_RESET_POS, fn = function() if K.UI then K.UI.ResetPlacement() end end },
        { text = L.OPT_BTN_DEFAULTS, fn = function() O.ResetAll(); O.Refresh() end },
    }
end

local function buildContent(parent)
    local root = CreateFrame("Frame", nil, parent)
    root:SetAllPoints(parent)
    local title = T.Text(root, 20, T.c.text, "LEFT", true)
    title:SetPoint("TOPLEFT", root, "TOPLEFT", PAD, -PAD)
    title:SetText(L.ADDON_NAME)
    local sub = T.Text(root, 11, T.c.sub)
    sub:SetPoint("LEFT", title, "RIGHT", 10, -3)
    sub:SetText(string.format(L.OPT_VERSION, K.Compat.GetAddOnMetadata("Klimax", "Version") or "?"))

    local x = PAD
    root.actions = {}
    for i, a in ipairs(O.Actions()) do
        local b = T.Button(root, a.text, 0, 24, a.fn)
        b:SetPoint("TOPLEFT", root, "TOPLEFT", x, -52)
        x = x + (b:GetWidth() or 90) + 6
        root.actions[i] = b
    end

    local scroll = T.Scroll(root)
    scroll:SetPoint("TOPLEFT", root, "TOPLEFT", PAD, -90)
    scroll:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -PAD, PAD)
    root.scroll, root.controls = scroll, {}

    local y = 0
    for _, sec in ipairs(O.SECTIONS) do
        local head = T.Text(scroll.content, 12, T.c.accent, "LEFT", true)
        head:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 0, -y)
        head:SetText(string.upper(L[sec.title] or sec.title))
        local rule = scroll.content:CreateTexture(nil, "ARTWORK")
        rule:SetTexture(T.WHITE)
        T.Paint(rule, T.c.edge)
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 0, -(y + 20))
        rule:SetPoint("TOPRIGHT", scroll.content, "TOPRIGHT", 0, -(y + 20))
        y = y + 30
        for _, row in ipairs(sec.rows) do
            local tip = row.tip and L[row.tip] or nil
            local ctl
            if row.kind == "bool" then
                ctl = T.Toggle(scroll.content, L[row.label], function() return K.Option(row.key) end,
                    function(v) K.SetOption(row.key, v) end, tip)
                ctl:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 0, -y)
            else
                local lbl = T.Text(scroll.content, 12, T.c.text)
                lbl:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 0, -(y + 5))
                lbl:SetText(L[row.label])
                ctl = T.Segmented(scroll.content, O.Choices(row), function(v)
                    K.SetOption(row.key, v)
                    O.Refresh()
                end, tip)
                ctl:SetPoint("TOPRIGHT", scroll.content, "TOPRIGHT", -8, -y)
            end
            ctl.row = row
            root.controls[#root.controls + 1] = ctl
            y = y + ROW_H
        end
        y = y + 14
    end
    scroll:SetContentHeight(y)
    return root
end

-- Re-reads every control from the stored options.
function O.Refresh()
    local root = O.root
    if not root then
        return
    end
    for _, ctl in ipairs(root.controls) do
        if ctl.row.kind == "bool" then
            ctl:Refresh(false)
        else
            ctl:SetValue(K.Option(ctl.row.key))
        end
    end
end

local function ensureContent()
    if O.root then
        return
    end
    if O.panel then
        O.root = buildContent(O.panel)
    else
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("DIALOG")
        f:SetSize(460, 520)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
        f:SetClampedToScreen(true)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        T.Window(f)
        T.CloseOnEscape(f, "KlimaxOptionsFrame")
        local close = T.IconButton(f, "close", 24, function() f:Hide() end, L.TIP_CLOSE)
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
        O.window = f
        O.root = buildContent(f)
        f:Hide()
    end
    O.Refresh()
end

-- Registers the category in the client's add-on options. Returns true when it did.
function O.Register()
    if O.panel then
        return true
    end
    local canvas = Settings and Settings.RegisterCanvasLayoutCategory
    local legacy = InterfaceOptions_AddCategory
    if not (canvas or legacy) then
        return false
    end
    local panel = CreateFrame("Frame", nil)
    panel.name = L.ADDON_NAME
    O.panel = panel
    if canvas then
        local category = Settings.RegisterCanvasLayoutCategory(panel, L.ADDON_NAME)
        if Settings.RegisterAddOnCategory then
            Settings.RegisterAddOnCategory(category)
        end
        O.category = category
    else
        InterfaceOptions_AddCategory(panel)
    end
    panel:SetScript("OnShow", function()
        ensureContent()
        O.Refresh()
    end)
    return true
end

-- Opens the options: the add-on category when registered, else the standalone window.
function O.Open()
    if O.panel and O.category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(O.category:GetID())
        return "settings"
    elseif O.panel and InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(O.panel)
        InterfaceOptionsFrame_OpenToCategory(O.panel)  -- the client opens the wrong page on the first call
        return "legacy"
    end
    if not O.panel then
        ensureContent()
        if O.window then
            O.window:SetShown(not O.window:IsShown())
        end
    end
    return "window"
end

-- Applies migration at login, then registers the panel.
K.On("PLAYER_LOGIN", function()
    if K.db then
        O.Migrate(K.db.options)
    end
    O.Register()
end)
