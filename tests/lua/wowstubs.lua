-- Minimal fake WoW API for the busted specs.
--
-- W.reset() installs fresh globals and state. W.loadAddon() loads the add-on exactly as the
-- client does: the files listed in Klimax/Klimax.toc, in order, each called with
-- (addonName, addonTable). Tests drive the game through W.state, W.fire(event, ...) and
-- W.flushTimers(). Nothing here touches the network or the file system beyond reading the TOC.
local W = {}

local ROOT = "Klimax/"

W.state = {}
W.printed = {}
W.timers = {}
W.frames = {}

local function newState()
    return {
        faction = "Horde",
        race = "Orc",
        raceToken = "Orc",
        class = "WARRIOR",
        level = 1,
        mapID = 1,
        pos = { x = 0.5, y = 0.5 },
        bind = "Razor Hill",
        taxi = {},
        completed = {},   -- questID -> true (IsQuestFlaggedCompleted and GetQuestsCompleted)
        -- array of {questID = n, isComplete = true | 1 | -1 | nil, title = string, level = n,
        -- objectives = {{text, type, finished, numFulfilled, numRequired}}} or a header line
        -- {isHeader = true, title = string, isCollapsed = bool}. A collapsed header hides the quests
        -- under it, as the client does (phase 18).
        logList = {},
        xp = 0, xpMax = 1000, rested = nil,
        zoneText = "Durotar", subzoneText = "",
        realm = "Forever",
        time = 0,
        wall = 1000000,   -- time() in seconds
        classification = {},
        names = {},
        facing = 0,       -- GetPlayerFacing (radians)
        contOf = {},      -- uiMapID -> continent id (default 1)
    }
end

-- A widget with the methods the add-on calls. Create* returns another widget; any other
-- method is a no-op that returns nil. Frames and textures store nothing: specs check logic
-- through the add-on's pure functions, not through widget text.
local widgetMeta = {}
widgetMeta.__index = function(_, name)
    if name:sub(1, 6) == "Create" then
        return function()
            return setmetatable({}, widgetMeta)
        end
    end
    return function() end
end

local function fakeFrame()
    local frame = setmetatable({ events = {}, scripts = {} }, widgetMeta)
    function frame:RegisterEvent(event)
        self.events[event] = true
    end
    function frame:SetScript(name, fn)
        self.scripts[name] = fn
    end
    return frame
end

-- Quest log helpers used by tests.
function W.setQuestLog(questID, isComplete)
    for _, entry in ipairs(W.state.logList) do
        if entry.questID == questID then
            entry.isComplete = isComplete
            return
        end
    end
    W.state.logList[#W.state.logList + 1] = { questID = questID, isComplete = isComplete, title = "Quest " .. questID }
end

function W.clearQuestLog()
    W.state.logList = {}
end

-- Installs the globals. opts.legacy = true removes the C_QuestLog API and provides the Classic
-- globals (IsQuestFlaggedCompleted, GetQuestsCompleted, GetNumQuestLogEntries, GetQuestLogTitle).
function W.reset(opts)
    opts = opts or {}
    W.state = newState()
    W.printed = {}
    W.timers = {}
    W.frames = {}
    W.K = nil

    KlimaxDB = nil
    KlimaxCharDB = nil
    SlashCmdList = {}

    CreateFrame = function()
        local f = fakeFrame()
        W.frames[#W.frames + 1] = f
        return f
    end

    StaticPopupDialogs = {}
    StaticPopup_Show = function() end
    GameTooltip = setmetatable({}, widgetMeta)
    UIParent = setmetatable({}, widgetMeta)
    GetPlayerFacing = function()
        return W.state.facing
    end
    -- World positions: yards = map percent * 1000, continent from state.contOf (default 1).
    CreateVector2D = function(x, y)
        return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
    end

    C_Timer = {
        After = function(_, fn)
            W.timers[#W.timers + 1] = fn
        end,
    }

    DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, msg)
            W.printed[#W.printed + 1] = msg
        end,
    }

    local function isCompleted(questID)
        return W.state.completed[questID] or false
    end

    -- Visible quest log lines (collapsed headers hide their quests) and the total quest count.
    local function logEntries()
        local visible, quests = {}, 0
        local collapsed = false
        for _, e in ipairs(W.state.logList) do
            if e.isHeader then
                collapsed = e.isCollapsed and true or false
                visible[#visible + 1] = e
            else
                quests = quests + 1
                if not collapsed then
                    visible[#visible + 1] = e
                end
            end
        end
        return visible, quests
    end

    local function objectivesAt(i)
        local e = logEntries()[i]
        return e and e.objectives or {}
    end

    if opts.legacy then
        C_QuestLog = nil
        IsQuestFlaggedCompleted = isCompleted
        GetQuestsCompleted = function()
            local set = {}
            for id, v in pairs(W.state.completed) do
                if v then
                    set[id] = true
                end
            end
            return set
        end
        GetNumQuestLogEntries = function()
            local visible, quests = logEntries()
            return #visible, quests
        end
        GetQuestLogTitle = function(i)
            local e = logEntries()[i]
            if not e then
                return nil
            end
            -- title, level, suggestedGroup, isHeader, isCollapsed, isComplete, frequency, questID
            if e.isHeader then
                return e.title, 0, 0, true, e.isCollapsed and true or false, nil, 0, nil
            end
            return e.title, e.level or 1, 0, false, false, e.isComplete, 0, e.questID
        end
        GetNumQuestLeaderBoards = function(i)
            return #objectivesAt(i)
        end
        GetQuestLogLeaderBoard = function(j, i)
            local o = objectivesAt(i)[j]
            if not o then
                return nil
            end
            return o.text, o.type, o.finished
        end
    else
        IsQuestFlaggedCompleted = nil
        GetNumQuestLeaderBoards = nil
        GetQuestLogLeaderBoard = nil
        GetQuestsCompleted = nil
        GetNumQuestLogEntries = nil
        GetQuestLogTitle = nil
        C_QuestLog = {
            IsQuestFlaggedCompleted = isCompleted,
            GetNumQuestLogEntries = function()
                local visible, quests = logEntries()
                return #visible, quests
            end,
            GetInfo = function(i)
                local e = logEntries()[i]
                if not e then
                    return nil
                end
                if e.isHeader then
                    return { title = e.title, isHeader = true, isCollapsed = e.isCollapsed and true or false }
                end
                return { questID = e.questID, isComplete = e.isComplete, title = e.title, isHeader = false,
                    level = e.level or 1 }
            end,
            GetQuestObjectives = function(questID)
                for _, e in ipairs(W.state.logList) do
                    if e.questID == questID then
                        return e.objectives or {}
                    end
                end
                return {}
            end,
        }
    end

    -- Header expand/collapse (Classic globals, both API shapes). index is a visible line index;
    -- 0 means every header. W.state.expandCalls counts the calls for the specs.
    W.state.expandCalls = 0
    ExpandQuestHeader = function(i)
        W.state.expandCalls = W.state.expandCalls + 1
        if i == 0 then
            for _, e in ipairs(W.state.logList) do
                if e.isHeader then
                    e.isCollapsed = false
                end
            end
            return
        end
        local e = logEntries()[i]
        if e and e.isHeader then
            e.isCollapsed = false
        end
    end
    CollapseQuestHeader = function(i)
        local e = logEntries()[i]
        if e and e.isHeader then
            e.isCollapsed = true
        end
    end

    C_AddOns = {
        GetAddOnMetadata = function(_, field)
            if field == "Version" then
                return "0.6.0"
            end
            return nil
        end,
    }

    UnitFactionGroup = function()
        return W.state.faction, W.state.faction
    end
    UnitRace = function()
        return W.state.race, W.state.raceToken
    end
    UnitClass = function()
        return "Warrior", W.state.class
    end
    UnitLevel = function()
        return W.state.level
    end
    UnitXP = function()
        return W.state.xp
    end
    UnitXPMax = function()
        return W.state.xpMax
    end
    GetXPExhaustion = function()
        return W.state.rested
    end
    GetRealZoneText = function()
        return W.state.zoneText
    end
    GetSubZoneText = function()
        return W.state.subzoneText
    end
    GetRealmName = function()
        return W.state.realm
    end

    C_Map = {
        GetBestMapForUnit = function()
            return W.state.mapID
        end,
        GetPlayerMapPosition = function()
            return W.state.pos.x, W.state.pos.y
        end,
        GetWorldPosFromMapPos = function(mapID, vec)
            local cont = W.state.contOf[mapID] or 1
            return cont, CreateVector2D(vec.x * 1000, vec.y * 1000)
        end,
    }

    NumTaxiNodes = function()
        return #W.state.taxi
    end
    TaxiNodeName = function(i)
        return W.state.taxi[i] and W.state.taxi[i].name
    end
    TaxiNodeGetType = function(i)
        return W.state.taxi[i] and W.state.taxi[i].kind
    end
    GetBindLocation = function()
        return W.state.bind
    end
    GetTime = function()
        return W.state.time
    end
    -- Wall clock in seconds (the add-on's persistent cooldowns use time(), not GetTime()).
    time = function()
        return W.state.wall
    end
    -- Nameplate rarity: state.classification[unit] and state.names[unit] (phase 08).
    UnitClassification = function(unit)
        return W.state.classification[unit]
    end
    UnitName = function(unit)
        return W.state.names[unit] or unit
    end
end

-- Loads every file listed in Klimax/Klimax.toc, in order. opts.skipRoutes leaves out Routes/.
-- Returns the add-on table K (the same table every file receives).
function W.loadAddon(opts)
    opts = opts or {}
    local K = {}
    W.K = K
    local toc = assert(io.open(ROOT .. "Klimax.toc", "r"))
    local lines = {}
    for line in toc:lines() do
        lines[#lines + 1] = line
    end
    toc:close()
    for _, raw in ipairs(lines) do
        local line = raw:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local isRoute = line:find("Routes", 1, true) ~= nil
            if not (opts.skipRoutes and isRoute) then
                local path = ROOT .. line:gsub("\\", "/")
                local chunk, err = loadfile(path)
                assert(chunk, err)
                chunk("Klimax", K)
            end
        end
    end
    return K
end

-- Sends an event to the add-on's event frame (the first frame created by Core).
function W.fire(event, ...)
    local frame = W.frames[1]
    assert(frame, "no frame: call W.loadAddon first")
    frame.scripts.OnEvent(frame, event, ...)
end

-- Runs the OnUpdate script once with the given elapsed seconds (drives K.Every tickers).
function W.tick(elapsed)
    local frame = W.frames[1]
    frame.scripts.OnUpdate(frame, elapsed)
end

-- Runs queued C_Timer callbacks until none are left (callbacks may queue more).
function W.flushTimers()
    local guard = 0
    while #W.timers > 0 do
        local fn = table.remove(W.timers, 1)
        fn()
        guard = guard + 1
        assert(guard < 100000, "timer loop does not end")
    end
end

-- Removes a global. Specs must use this instead of assigning globals themselves: busted runs
-- spec code in an isolated copy of the globals, which the add-on never sees.
function W.unset(name)
    _G[name] = nil
end

-- Shallow copy of two option tables (b wins on conflicts).
function W.merge(a, b)
    local out = {}
    for k, v in pairs(a or {}) do
        out[k] = v
    end
    for k, v in pairs(b or {}) do
        out[k] = v
    end
    return out
end

-- Registers a route table the way the generated files do.
function W.registerRoute(route)
    Klimax_RegisterRoute(route)
end

-- Registers an index the way Index.lua does.
function W.registerIndex(index)
    Klimax_RegisterIndex(index)
end

-- Loads the add-on, then runs ADDON_LOADED so SavedVariables are initialised.
function W.start(opts)
    W.reset(opts)
    if opts and opts.charDB then
        KlimaxCharDB = opts.charDB
    end
    local K = W.loadAddon(opts)
    W.fire("ADDON_LOADED", "Klimax")
    return K
end

-- Simulates /reload (phase 22): keeps the game state and both saved-variable tables, loads the
-- add-on again, logs in and runs every queued timer.
function W.reload(opts)
    local db, cdb, state = KlimaxDB, KlimaxCharDB, W.state
    W.reset(opts)
    W.state = state
    KlimaxDB, KlimaxCharDB = db, cdb
    local K = W.loadAddon(opts)
    W.fire("ADDON_LOADED", "Klimax")
    W.fire("PLAYER_LOGIN")
    W.flushTimers()
    return K
end

return W
