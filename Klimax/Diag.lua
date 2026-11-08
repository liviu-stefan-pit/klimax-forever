-- Diagnostics: the save-state dump.
--
--   /klimax dump         stores a snapshot of the character (quest log, completed quests, level and
--                        XP, class, race, position, the plan and the player's choices) in
--                        KlimaxDB.dumps["Name-Realm"]. After /reload or logout the file
--                        WTF/Account/<account>/SavedVariables/Klimax.lua holds it; the offline
--                        converter (`python -m pipeline fixture`) turns it into a JSON test fixture.
--
-- Phase 29: the engine-versus-game comparison, the audit report and the mark log belonged to the band
-- engine and are gone; the game is the truth now (K.State). Nothing here changes what the add-on
-- stores or shows.
local _, K = ...
local L = K.L
local C = K.Compat

local D = {}
K.Diag = D

D.DUMP_SCHEMA = 1

-- ---- Reading the game -------------------------------------------------------------------------

-- The quest log as {[questID] = {complete, failed, title, level}} plus the raw lines, the client's
-- quest count and how many quests are hidden under collapsed headers (count minus visible quests).
-- A raw complete value of -1 (Classic) means failed, 1 or true complete. Objectives are read only
-- when withObjectives is true (the dump); the per-mark check skips them.
function D.ReadLog(withObjectives)
    local lines, numQuests = C.GetFullQuestLogLines(withObjectives)
    local log = {}
    local visible = 0
    for _, line in ipairs(lines) do
        if not line.header and line.questID then
            local raw = line.complete
            local failed = raw == -1 or line.failed == true
            log[line.questID] = { complete = (raw == 1 or raw == true) and not failed, failed = failed,
                title = line.title, level = line.level }
            visible = visible + 1
        end
    end
    local hidden = math.max(0, (tonumber(numQuests) or visible) - visible)
    return log, lines, numQuests, hidden
end

-- Completed flags for every quest the routes reference, plus the full GetQuestsCompleted set when
-- the client has one. Returns completed ({[id] = true}), known (false: no API), the sorted list
-- of flagged route quests and the sorted list from the set (or nil).
function D.ReadCompleted()
    local kind = C.CompletedApiKind()
    local completed, flagged = {}, {}
    local set = C.GetCompletedSet()
    local setList
    if set then
        setList = {}
        for id, v in pairs(set) do
            if v and tonumber(id) then
                setList[#setList + 1] = tonumber(id)
            end
        end
        table.sort(setList)
    end
    for _, id in ipairs(K.Snapshot.QuestIds()) do
        local done
        if kind == "C_QuestLog" or kind == "global" then
            done = C.IsQuestCompleted(id)
        elseif set then
            done = set[id] and true or false
        end
        if done then
            completed[id] = true
            flagged[#flagged + 1] = id
        end
    end
    return completed, kind ~= nil, flagged, setList
end

-- ---- Dump -------------------------------------------------------------------------------------

local function copy(value, depth)
    if type(value) ~= "table" then
        return value
    end
    if (depth or 0) > 8 then
        return nil
    end
    local out = {}
    for key, v in pairs(value) do
        out[key] = copy(v, (depth or 0) + 1)
    end
    return out
end

-- Keys of the plan's steps, in order (the dump shows what the add-on was telling the player).
local function planKeys(E)
    local keys = {}
    for i, step in ipairs(E.steps or {}) do
        keys[i] = step.k
    end
    return keys
end

-- A save-state snapshot of the character, as a plain table (see the header comment).
function D.Snapshot()
    local p = K.Detect()
    local E = K.Engine
    local xp, xpMax, rested = C.GetXP()
    local mapID = C.GetBestMapForPlayer()
    local pos = mapID and C.GetPlayerMapPosition(mapID)
    local zone, subzone = C.GetZoneTexts()
    local _, lines, numQuests, hidden = D.ReadLog(true)
    local _, known, flagged, setList = D.ReadCompleted()
    local cursorIndex, cursorStep = E:Current()
    local cdb = K.cdb or {}
    return {
        schema = D.DUMP_SCHEMA,
        addon = K.version,
        engineMode = "planner",
        captured = date and date("%Y-%m-%d %H:%M:%S") or nil,
        player = {
            name = UnitName and UnitName("player") or nil,
            realm = GetRealmName and GetRealmName() or nil,
            faction = p.faction, race = p.race, raceToken = p.raceToken, class = p.class, level = p.level,
            xp = xp, xpMax = xpMax, rested = rested,
        },
        position = { mapID = mapID, x = pos and pos.x, y = pos and pos.y, zone = zone, subzone = subzone },
        api = {
            completed = C.CompletedApiKind(),
            questLog = (C_QuestLog and type(C_QuestLog.GetInfo) == "function") and "C_QuestLog" or "classic",
            numQuests = numQuests,
            hiddenQuests = hidden,
        },
        questLog = lines,
        completed = flagged,
        completedSet = setList,
        completedKnown = known,
        engine = {
            routeId = E.routeId,
            cursorKey = cursorStep and cursorStep.k or nil,
            cursorIndex = cursorIndex,
            plan = planKeys(E),
            skipQuests = copy(cdb.skipQuests),
            hiddenSteps = copy(cdb.hiddenSteps),
            brokenQuests = copy(cdb.brokenQuests),
            pin = copy(cdb.pin),
            visited = copy(cdb.visited),
        },
        options = copy(K.db and K.db.options),
        disagreements = {},
        debugLog = K.LogLines(),
    }
end

-- /klimax dump: stores the snapshot in KlimaxDB.dumps under "Name-Realm".
function D.Dump()
    local snap = D.Snapshot()
    local key = tostring(snap.player.name or "?") .. "-" .. tostring(snap.player.realm or "?")
    K.db = K.db or {}
    K.db.dumps = K.db.dumps or {}
    K.db.dumps[key] = snap
    K.Print(string.format(L.DUMP_SAVED, key, #(snap.questLog or {}), #(snap.completed or {}), 0))
    return snap, key
end
