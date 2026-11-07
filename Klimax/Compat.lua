-- Compatibility layer and registration bootstrap.
--
-- Loaded before Data and Routes, so the registration functions that the generated files call
-- exist before those files run. Every API wrapper degrades to nil (or a safe default) when the
-- client does not provide the function, and never raises an error.
local _, K = ...

K.routes = K.routes or {}
K.zones = K.zones or {}
K.index = K.index or { routes = {}, start = {}, quests = {} }

-- ---- Registration (called by the generated Lua files) ----------------------------------------

function Klimax_RegisterRoute(route)
    if type(route) == "table" and route.id then
        K.routes[route.id] = route
    end
end

function Klimax_RegisterIndex(index)
    if type(index) == "table" then
        K.index = index
        K.index.routes = index.routes or {}
        K.index.start = index.start or {}
        K.index.quests = index.quests or {}
    end
end

function Klimax_RegisterZones(zones)
    if type(zones) == "table" then
        K.zones = zones
    end
end

-- ---- API wrappers ----------------------------------------------------------------------------

local C = {}
K.Compat = C

-- Calls fn(...) under pcall and returns its first two results, or nil when fn is missing or fails.
local function call2(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return nil
end

-- Returns true or false when the quest flag is known, nil when no API is available.
-- Classic-era clients expose IsQuestFlaggedCompleted as a global; newer ones use C_QuestLog.
function C.HasFlaggedCompletedApi()
    return (C_QuestLog and type(C_QuestLog.IsQuestFlaggedCompleted) == "function")
        or type(IsQuestFlaggedCompleted) == "function"
end

function C.IsQuestCompleted(questID)
    local fn
    if C_QuestLog and type(C_QuestLog.IsQuestFlaggedCompleted) == "function" then
        fn = C_QuestLog.IsQuestFlaggedCompleted
    else
        fn = IsQuestFlaggedCompleted
    end
    local flagged = call2(fn, questID)
    if flagged == nil then
        return nil
    end
    return flagged and true or false
end

-- Returns a set {[questID] = true} from GetQuestsCompleted, or nil when that API is missing.
function C.GetCompletedSet()
    local set = call2(GetQuestsCompleted)
    if type(set) == "table" then
        return set
    end
    return nil
end

-- Returns {[questID] = {complete = bool, title = string}} for every quest in the log.
-- Uses the modern C_QuestLog iteration when present, else the Classic GetQuestLogTitle loop.
function C.GetQuestLog()
    local log = {}
    if C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function"
        and type(C_QuestLog.GetInfo) == "function" then
        local n = call2(C_QuestLog.GetNumQuestLogEntries) or 0
        for i = 1, n do
            local info = call2(C_QuestLog.GetInfo, i)
            if type(info) == "table" and info.questID and not info.isHeader then
                log[info.questID] = { complete = info.isComplete and true or false, title = info.title }
            end
        end
    elseif type(GetNumQuestLogEntries) == "function" and type(GetQuestLogTitle) == "function" then
        local n = call2(GetNumQuestLogEntries) or 0
        for i = 1, n do
            local ok, title, _, _, isHeader, _, isComplete, _, questID = pcall(GetQuestLogTitle, i)
            if ok and questID and not isHeader then
                log[questID] = { complete = isComplete and true or false, title = title }
            end
        end
    end
    return log
end

-- Free slots in a bag, or nil when no container API is available.
function C.GetContainerFreeSlots(bag)
    local fn
    if C_Container and type(C_Container.GetContainerNumFreeSlots) == "function" then
        fn = C_Container.GetContainerNumFreeSlots
    else
        fn = GetContainerNumFreeSlots
    end
    return call2(fn, bag)
end

-- Addon metadata field (for example "Version"), or nil.
function C.GetAddOnMetadata(name, field)
    local fn
    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        fn = C_AddOns.GetAddOnMetadata
    else
        fn = GetAddOnMetadata
    end
    return call2(fn, name, field)
end

-- Position of the player on a map as {x, y} in 0..1, or nil.
function C.GetPlayerMapPosition(mapID)
    if not (C_Map and type(C_Map.GetPlayerMapPosition) == "function") then
        return nil
    end
    local a, b = call2(C_Map.GetPlayerMapPosition, mapID, "player")
    if type(a) == "table" and type(a.GetXY) == "function" then
        local ok, x, y = pcall(a.GetXY, a)
        if ok and x then
            return { x = x, y = y }
        end
        return nil
    end
    if type(a) == "number" and type(b) == "number" then
        return { x = a, y = b }
    end
    return nil
end

function C.GetBestMapForPlayer()
    if C_Map and type(C_Map.GetBestMapForUnit) == "function" then
        return call2(C_Map.GetBestMapForUnit, "player")
    end
    return nil
end

-- Facing of the player in radians (0 = north, counter-clockwise), or nil.
function C.GetFacing()
    return (call2(GetPlayerFacing))
end

-- World position in yards for a map position given in 0..1: continent map id, x, y; or nil.
-- Needs C_Map.GetWorldPosFromMapPos and CreateVector2D. Without them the arrow stays hidden.
local function worldPos(mapID, x, y)
    local cont, vec = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
    if not cont or type(vec) ~= "table" then
        return nil
    end
    local wx, wy
    if type(vec.GetXY) == "function" then
        wx, wy = vec:GetXY()
    else
        wx, wy = vec.x, vec.y
    end
    if type(wx) ~= "number" or type(wy) ~= "number" then
        return nil
    end
    return cont, wx, wy
end

function C.GetWorldPos(mapID, x, y)
    if not (C_Map and type(C_Map.GetWorldPosFromMapPos) == "function" and type(CreateVector2D) == "function") then
        return nil
    end
    local ok, cont, wx, wy = pcall(worldPos, mapID, x, y)
    if not ok or not cont then
        return nil
    end
    return cont, wx, wy
end
