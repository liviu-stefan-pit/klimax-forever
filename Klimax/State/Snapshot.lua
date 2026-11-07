-- Snapshot: what the game says about the character right now (phase 20, DYNAMIC_GUIDE_PLAN s4.2).
--
-- The snapshot is a plain table, so the reconciler and the planner can be tested without a client:
--   level, race, raceToken, class, faction, mapID, x, y (percent), bind, money, freeSlots,
--   log            {[questID] = {complete = bool, failed = bool, title, level}} (whole log, collapsed
--                  headers included when the client lets us expand them),
--   logPartial     true when some quests stayed hidden (log window open, or no expand API),
--   completed      {[questID] = true} from the completed-quest flags (see the scan below),
--   completedKnown false when the client has no completed-quest API at all,
--   scanned        true once the chunked flag scan has finished at least once,
--   seen           {[questID] = true}: quests this character has had in its log (saved, for
--                  "abandoned"),
--   skipped        {[questID] = true}: quests the player chose to skip (saved, phase 22 menu).
--
-- The completed set is built from the flag API over every quest the add-on knows (route quests and
-- compiled world quests), chunked across frames, and cached. QUEST_TURNED_IN adds to it at once; a
-- resync rescans everything.
local _, K = ...
local C = K.Compat

local Snap = {}
K.Snapshot = Snap

Snap.BATCH = 250          -- flag checks per frame slice
Snap.completed = {}       -- the cache
Snap.completedKnown = nil -- nil until the first scan has decided
Snap.scanned = false
Snap.scanGen = 0
Snap.scanning = false

-- ---- Quest universe -----------------------------------------------------------------------------

-- Every quest id the add-on can reason about: route quests, compiled world quests, equivalents.
function Snap.QuestIds()
    local seen, ids = {}, {}
    local function add(id)
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    for id in pairs((K.index and K.index.quests) or {}) do
        add(id)
    end
    local wi = K.WorldDB and K.WorldDB.index
    for id in pairs((wi and wi.quests) or {}) do
        add(id)
    end
    for _, group in ipairs((wi and wi.eq) or {}) do
        for _, id in ipairs(group) do
            add(id)
        end
    end
    table.sort(ids)
    return ids
end

-- ---- Quest log ----------------------------------------------------------------------------------

-- Reads the whole quest log. Returns log, partial (bool), hiddenCount.
function Snap.ReadLog()
    local lines, numQuests, hidden = C.GetFullQuestLogLines(false)
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
    hidden = hidden or math.max(0, (tonumber(numQuests) or visible) - visible)
    return log, hidden > 0, hidden
end

-- ---- Completed flags (chunked) ------------------------------------------------------------------

-- Scans the completed flags of `ids` (default: Snap.QuestIds()). Uses the per-quest flag API in
-- slices of Snap.BATCH per frame, or the GetQuestsCompleted set in one go. onDone(completed, known)
-- runs when the scan is finished. A newer scan supersedes an older one still running.
function Snap.ScanCompleted(onDone, ids)
    Snap.scanGen = Snap.scanGen + 1
    local gen = Snap.scanGen
    ids = ids or Snap.QuestIds()
    local kind = C.CompletedApiKind()
    local function finish(set, known)
        if gen ~= Snap.scanGen then
            return
        end
        Snap.completed = set
        Snap.completedKnown = known
        Snap.scanned = true
        Snap.scanning = false
        if onDone then
            onDone(set, known)
        end
    end
    Snap.scanning = true
    if kind == nil then
        finish({}, false)
        return
    end
    if kind == "set" then
        local set = {}
        for id, v in pairs(C.GetCompletedSet() or {}) do
            if v and tonumber(id) then
                set[tonumber(id)] = true
            end
        end
        finish(set, true)
        return
    end
    local set, n = {}, 0
    local function pump()
        if gen ~= Snap.scanGen then
            return
        end
        local stop = math.min(n + Snap.BATCH, #ids)
        for i = n + 1, stop do
            if C.IsQuestCompleted(ids[i]) then
                set[ids[i]] = true
            end
        end
        n = stop
        if n >= #ids then
            finish(set, true)
        else
            C_Timer.After(0, pump)
        end
    end
    pump()
end

-- QUEST_TURNED_IN: the cache learns the quest at once (no rescan).
function Snap.MarkCompleted(questID)
    questID = tonumber(questID)
    if questID then
        Snap.completed[questID] = true
    end
end

-- ---- Saved per-character sets -------------------------------------------------------------------

local function charSet(name)
    K.cdb = K.cdb or {}
    K.cdb[name] = K.cdb[name] or {}
    return K.cdb[name]
end

function Snap.Seen()
    return charSet("seenQuests")
end

function Snap.Skipped()
    return charSet("skipQuests")
end

-- ---- Build ----------------------------------------------------------------------------------------

-- Builds a snapshot from the live client and the cache. Every quest in the log is recorded as seen.
function Snap.Build()
    local p = K.player or {}
    local log, partial = Snap.ReadLog()
    local seen = Snap.Seen()
    for q in pairs(log) do
        seen[q] = true
    end
    local mapID = C.GetBestMapForPlayer()
    local pos = mapID and C.GetPlayerMapPosition(mapID)
    local free = 0
    if K.Helpers and K.Helpers.FreeSlots then
        free = K.Helpers.FreeSlots() or 0
    end
    return {
        level = p.level or (UnitLevel and UnitLevel("player")) or 1,
        race = p.race, raceToken = p.raceToken, class = p.class, faction = p.faction,
        mapID = mapID, x = pos and pos.x * 100 or nil, y = pos and pos.y * 100 or nil,
        bind = GetBindLocation and GetBindLocation() or nil,
        money = C.GetMoney and C.GetMoney() or 0,
        freeSlots = free,
        log = log, logPartial = partial,
        completed = Snap.completed,
        completedKnown = Snap.completedKnown,
        scanned = Snap.scanned,
        seen = seen,
        skipped = Snap.Skipped(),
    }
end
