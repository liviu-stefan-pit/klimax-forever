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
        logList = {},     -- array of {questID = n, isComplete = bool, title = string}
        time = 0,
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

    local function logEntries()
        return W.state.logList
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
            return #logEntries(), 0
        end
        GetQuestLogTitle = function(i)
            local e = logEntries()[i]
            if not e then
                return nil
            end
            -- title, level, suggestedGroup, isHeader, isCollapsed, isComplete, frequency, questID
            return e.title, 1, 0, false, false, e.isComplete, 0, e.questID
        end
    else
        IsQuestFlaggedCompleted = nil
        GetQuestsCompleted = nil
        GetNumQuestLogEntries = nil
        GetQuestLogTitle = nil
        C_QuestLog = {
            IsQuestFlaggedCompleted = isCompleted,
            GetNumQuestLogEntries = function()
                return #logEntries()
            end,
            GetInfo = function(i)
                local e = logEntries()[i]
                if not e then
                    return nil
                end
                return { questID = e.questID, isComplete = e.isComplete, title = e.title, isHeader = false }
            end,
        }
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
    local K = W.loadAddon(opts)
    W.fire("ADDON_LOADED", "Klimax")
    return K
end

return W
