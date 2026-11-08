-- Compatibility layer and registration bootstrap.
--
-- Loaded before the Data files, so the registration functions that the generated files call exist
-- before those files run. Every API wrapper degrades to nil (or a safe default) when the
-- client does not provide the function, and never raises an error.
local _, K = ...

K.zones = K.zones or {}

-- ---- Registration (called by the generated Lua files) ----------------------------------------

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

-- ---- Phase 18 diagnostics: raw quest log, XP, zone text ----------------------------------------

-- Which completed-quest API the client offers: "C_QuestLog", "global", "set" or nil.
function C.CompletedApiKind()
    if C_QuestLog and type(C_QuestLog.IsQuestFlaggedCompleted) == "function" then
        return "C_QuestLog"
    end
    if type(IsQuestFlaggedCompleted) == "function" then
        return "global"
    end
    if type(GetQuestsCompleted) == "function" then
        return "set"
    end
    return nil
end

-- Objectives of a quest as a list of {text, type, finished, have, need}. Uses
-- C_QuestLog.GetQuestObjectives(questID) when present, else the Classic leaderboard of log line i.
local function objectivesOf(questID, logIndex)
    local out = {}
    if C_QuestLog and type(C_QuestLog.GetQuestObjectives) == "function" and questID then
        local list = call2(C_QuestLog.GetQuestObjectives, questID)
        if type(list) == "table" then
            for _, o in ipairs(list) do
                out[#out + 1] = { text = o.text, type = o.type, finished = o.finished and true or false,
                    have = o.numFulfilled, need = o.numRequired }
            end
            return out
        end
    end
    if type(GetNumQuestLeaderBoards) == "function" and type(GetQuestLogLeaderBoard) == "function" then
        local n = call2(GetNumQuestLeaderBoards, logIndex) or 0
        for j = 1, n do
            local ok, text, kind, finished = pcall(GetQuestLogLeaderBoard, j, logIndex)
            if ok then
                out[#out + 1] = { text = text, type = kind, finished = finished and true or false }
            end
        end
    end
    return out
end

-- Every visible line of the quest log, headers included, exactly as the client reports it:
-- {index, title, level, header, collapsed, complete (raw value: true, 1, -1 or nil), questID,
-- objectives (only when withObjectives is true)}. Also returns the client's own quest count (the
-- second return of GetNumQuestLogEntries), which includes quests hidden under collapsed headers.
function C.GetQuestLogLines(withObjectives)
    local lines = {}
    local numQuests
    if C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function"
        and type(C_QuestLog.GetInfo) == "function" then
        local n, q = call2(C_QuestLog.GetNumQuestLogEntries)
        numQuests = q
        for i = 1, n or 0 do
            local info = call2(C_QuestLog.GetInfo, i)
            if type(info) == "table" then
                lines[#lines + 1] = { index = i, title = info.title, level = info.level,
                    header = info.isHeader and true or false, collapsed = info.isCollapsed and true or false,
                    complete = info.isComplete, failed = info.isFailed, questID = info.questID,
                    objectives = (withObjectives and not info.isHeader) and objectivesOf(info.questID, i) or nil }
            end
        end
    elseif type(GetNumQuestLogEntries) == "function" and type(GetQuestLogTitle) == "function" then
        local n, q = call2(GetNumQuestLogEntries)
        numQuests = q
        for i = 1, n or 0 do
            local ok, title, level, _, isHeader, isCollapsed, isComplete, _, questID = pcall(GetQuestLogTitle, i)
            if ok and title then
                lines[#lines + 1] = { index = i, title = title, level = level, header = isHeader and true or false,
                    collapsed = isCollapsed and true or false, complete = isComplete, questID = questID,
                    objectives = (withObjectives and not isHeader) and objectivesOf(questID, i) or nil }
            end
        end
    end
    return lines, numQuests
end

-- True while the player has the quest log window open (then its headers are left alone).
local function questLogShown()
    return QuestLogFrame ~= nil and type(QuestLogFrame.IsShown) == "function" and QuestLogFrame:IsShown() and true
        or false
end

local function countQuests(lines)
    local n = 0
    for _, line in ipairs(lines) do
        if not line.header and line.questID then
            n = n + 1
        end
    end
    return n
end

-- Phase 20: the whole quest log, including quests under collapsed headers. When the client hides
-- quests (its count is larger than the visible quests), every header is expanded, the log is read,
-- and the headers that were collapsed are collapsed again (bottom-up, so indices stay valid). This
-- is skipped while the quest log window is open. Returns lines, numQuests, hidden (quests still
-- not visible after the read: 0 unless the expand was not possible).
C.expanding = false
function C.GetFullQuestLogLines(withObjectives)
    local lines, numQuests = C.GetQuestLogLines(withObjectives)
    local hidden = math.max(0, (tonumber(numQuests) or 0) - countQuests(lines))
    if hidden == 0 or C.expanding or type(ExpandQuestHeader) ~= "function" or questLogShown() then
        return lines, numQuests, hidden
    end
    local collapsed = {}
    for _, line in ipairs(lines) do
        if line.header and line.collapsed and line.title then
            collapsed[line.title] = true
        end
    end
    C.expanding = true
    C.lastExpand = GetTime and GetTime() or 0
    pcall(ExpandQuestHeader, 0)
    local full, fullCount = C.GetQuestLogLines(withObjectives)
    if type(CollapseQuestHeader) == "function" then
        for i = #full, 1, -1 do
            local line = full[i]
            if line.header and line.title and collapsed[line.title] then
                pcall(CollapseQuestHeader, line.index)
                line.collapsed = true
            end
        end
    end
    C.expanding = false
    local stillHidden = math.max(0, (tonumber(fullCount) or 0) - countQuests(full))
    return full, fullCount, stillHidden
end

-- Current XP, XP to the next level, and rested XP (each nil when unknown).
function C.GetXP()
    return call2(UnitXP, "player"), call2(UnitXPMax, "player"), call2(GetXPExhaustion)
end

-- Zone and subzone names as the client shows them.
function C.GetZoneTexts()
    return call2(GetRealZoneText), call2(GetSubZoneText)
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
    -- Blizzard's world vector has x = north and y = west. Return x = east, y = north, which is
    -- what Arrow.Compute expects.
    return cont, -wy, wx
end

-- ---- Phase 08 wrappers: bags, items, trainers, reward choices, hearthstone ------------------

-- Number of slots in a bag, or nil.
function C.GetBagSlotCount(bag)
    local fn
    if C_Container and type(C_Container.GetContainerNumSlots) == "function" then
        fn = C_Container.GetContainerNumSlots
    else
        fn = GetContainerNumSlots
    end
    return call2(fn, bag)
end

-- A bag slot as {link, stack, quality}, or nil when the slot is empty or unreadable.
function C.GetBagSlot(bag, slot)
    if C_Container and type(C_Container.GetContainerItemInfo) == "function" then
        local info = call2(C_Container.GetContainerItemInfo, bag, slot)
        if type(info) == "table" and info.hyperlink then
            return { link = info.hyperlink, stack = info.stackCount or 1, quality = info.quality or 0 }
        end
        return nil
    end
    if type(GetContainerItemInfo) == "function" then
        local ok, _, count, _, quality, _, _, link = pcall(GetContainerItemInfo, bag, slot)
        if ok and link then
            return { link = link, stack = count or 1, quality = quality or 0 }
        end
    end
    return nil
end

-- Uses (sells, at a merchant) the item in a bag slot. Only called from a user click.
function C.UseBagSlot(bag, slot)
    local fn
    if C_Container and type(C_Container.UseContainerItem) == "function" then
        fn = C_Container.UseContainerItem
    else
        fn = UseContainerItem
    end
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, bag, slot)
end

-- Item class and subclass IDs of a link, read without the item cache: {classID, subclassID}.
function C.ItemClass(link)
    if type(GetItemInfoInstant) ~= "function" or not link then
        return nil
    end
    -- Returns: ok, itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID.
    local res = { pcall(GetItemInfoInstant, link) }
    if res[1] and res[7] then
        return { classID = res[7], subclassID = res[8] }
    end
    return nil
end

-- Item data of a link once it is cached: {name, sellPrice, equipLoc, classID, subclassID}, or nil.
function C.GetItemInfo(link)
    if type(GetItemInfo) ~= "function" or not link then
        return nil
    end
    local ok, name, _, quality, _, _, _, _, _, equipLoc, _, sellPrice, classID, subclassID = pcall(GetItemInfo, link)
    if not ok or not name then
        return nil
    end
    return {
        name = name, quality = quality, sellPrice = sellPrice or 0, equipLoc = equipLoc,
        classID = classID, subclassID = subclassID,
    }
end

-- Stat table of a link (keys like ITEM_MOD_STRENGTH_SHORT), or nil.
function C.GetItemStats(link)
    if type(GetItemStats) ~= "function" or not link then
        return nil
    end
    local ok, stats = pcall(GetItemStats, link)
    if ok and type(stats) == "table" then
        return stats
    end
    return nil
end

-- ---- Phase 23 services readings -----------------------------------------------------------------

-- Lowest durability of the equipped items as a fraction (0 to 1), or nil when nothing has
-- durability (or the API is missing). Slots 1 to 18.
function C.GetDurability()
    if type(GetInventoryItemDurability) ~= "function" then
        return nil
    end
    local low
    for slot = 1, 18 do
        local ok, cur, max = pcall(GetInventoryItemDurability, slot)
        if ok and cur and max and max > 0 then
            local f = cur / max
            if not low or f < low then
                low = f
            end
        end
    end
    return low
end

-- Phase 28 telemetry: the NPC the player is talking to (creature id from its GUID) and the titles of
-- the quests that NPC offers. Both are nil/empty when the client cannot tell.
function C.TalkingNpcId()
    if type(UnitGUID) ~= "function" then
        return nil
    end
    for _, unit in ipairs({ "npc", "target" }) do
        local ok, guid = pcall(UnitGUID, unit)
        if ok and type(guid) == "string" then
            local id = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)")
            if id then
                return tonumber(id)
            end
        end
    end
    return nil
end

function C.OfferedQuestTitles()
    local out = {}
    if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
        local ok, list = pcall(C_GossipInfo.GetAvailableQuests)
        for _, q in ipairs(ok and list or {}) do
            out[#out + 1] = q.title
        end
    elseif type(GetGossipAvailableQuests) == "function" then
        -- the old API returns seven values per quest, the title first
        local packed = { pcall(GetGossipAvailableQuests) }
        if packed[1] then
            for i = 2, #packed, 7 do
                out[#out + 1] = packed[i]
            end
        end
    end
    if type(GetNumAvailableQuests) == "function" and type(GetAvailableTitle) == "function" then
        for i = 1, GetNumAvailableQuests() do
            out[#out + 1] = GetAvailableTitle(i)
        end
    end
    return out
end

function C.HasPet()
    if type(UnitExists) ~= "function" then
        return nil
    end
    local ok, exists = pcall(UnitExists, "pet")
    return ok and exists and true or false
end

-- Pet happiness: 1 unhappy, 2 content, 3 happy; nil without a pet or the API.
function C.PetHappiness()
    if type(GetPetHappiness) ~= "function" then
        return nil
    end
    local ok, h = pcall(GetPetHappiness)
    return ok and h or nil
end

function C.HasNewMail()
    if type(HasNewMail) ~= "function" then
        return false
    end
    local ok, mail = pcall(HasNewMail)
    return ok and mail and true or false
end

-- Unspent talent points (Classic: first return of UnitCharacterPoints), or nil.
function C.GetTalentPoints()
    if type(UnitCharacterPoints) ~= "function" then
        return nil
    end
    local ok, points = pcall(UnitCharacterPoints, "player")
    return ok and points or nil
end

-- How many of an item the bags hold, or nil.
function C.GetItemCount(itemID)
    if type(GetItemCount) ~= "function" or not itemID then
        return nil
    end
    local ok, n = pcall(GetItemCount, itemID)
    return ok and n or nil
end

function C.IsTradeskillTrainer()
    if type(IsTradeskillTrainer) ~= "function" then
        return false
    end
    local ok, yes = pcall(IsTradeskillTrainer)
    return ok and yes and true or false
end

-- Item ID inside a link, or nil.
function C.ItemIdFromLink(link)
    local id = link and tostring(link):match("item:(%d+)")
    return tonumber(id)
end

-- Link of the equipped item in an inventory slot, or nil.
function C.GetEquippedLink(slotID)
    if type(GetInventoryItemLink) ~= "function" or not slotID then
        return nil
    end
    local ok, link = pcall(GetInventoryItemLink, "player", slotID)
    if ok then
        return link
    end
    return nil
end

-- Number of quest reward choices on the open quest frame.
function C.GetNumQuestChoices()
    return call2(GetNumQuestChoices) or 0
end

-- Link of quest reward choice i, or nil.
function C.GetQuestChoiceLink(i)
    if type(GetQuestItemLink) ~= "function" then
        return nil
    end
    local ok, link = pcall(GetQuestItemLink, "choice", i)
    if ok then
        return link
    end
    return nil
end

-- ID of the quest whose reward frame is open, or nil.
function C.GetOpenQuestID()
    return call2(GetQuestID)
end

-- Trainer service i as {name, category, cost}. cost is copper; category is available,
-- unavailable, used or header. Returns nil when the trainer window has no such row.
function C.GetTrainerService(i)
    if type(GetTrainerServiceInfo) ~= "function" then
        return nil
    end
    local ok, name, _, category = pcall(GetTrainerServiceInfo, i)
    if not ok or not name then
        return nil
    end
    local okCost, cost = pcall(GetTrainerServiceCost, i)
    local req
    if type(GetTrainerServiceLevelReq) == "function" then
        local okReq, level = pcall(GetTrainerServiceLevelReq, i)
        req = okReq and tonumber(level) or nil
    end
    return { name = name, category = category, cost = (okCost and tonumber(cost)) or 0, req = req }
end

-- Cooldown of an item as start, duration (seconds), or nil when unknown.
function C.GetItemCooldown(itemID)
    if type(GetItemCooldown) ~= "function" then
        return nil
    end
    local ok, start, duration = pcall(GetItemCooldown, itemID)
    if ok and type(start) == "number" then
        return start, duration or 0
    end
    return nil
end

-- Taxi nodes known to the character: {name, known} list, read while the taxi map is open.
function C.ReadTaxiNodes()
    local nodes = {}
    local count = (call2(NumTaxiNodes) or 0)
    for n = 1, count do
        local ok, name = pcall(TaxiNodeName, n)
        local okKind, kind = pcall(TaxiNodeGetType, n)
        if ok and name then
            nodes[#nodes + 1] = { name = name, known = okKind and kind ~= nil and kind ~= "NONE" }
        end
    end
    return nodes
end

-- Copper in the character's bags and purse.
function C.GetMoney()
    return call2(GetMoney) or 0
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
