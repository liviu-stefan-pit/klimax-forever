-- Phase 18 diagnostics: save-state dump, engine-versus-game comparison and mark provenance.
--
--   /klimax dump         stores a snapshot of the character (quest log, completed quests, level and
--                        XP, class, race, position, the engine's step state) in
--                        KlimaxDB.dumps["Name-Realm"]. After /reload or logout the file
--                        WTF/Account/<account>/SavedVariables/Klimax.lua holds it; the offline
--                        converter (`python -m pipeline fixture`) turns it into a JSON test fixture.
--   /klimax audit state  lists every step where the engine's belief and the game's quest state
--                        disagree (step key, quest id, game state, engine state).
--
-- Every state the engine stores is also recorded with its source in KlimaxCharDB.markLog (a ring
-- of D.MARKLOG_MAX entries), so a dump shows why a step was marked. Nothing here changes what the
-- engine stores or shows. D.GameState and D.Disagreements are pure and tested in busted.
local _, K = ...
local L = K.L
local C = K.Compat

local D = {}
K.Diag = D

D.DUMP_SCHEMA = 1
D.MARKLOG_MAX = 300
D.REPORT_MAX = 15

-- ---- Pure rules -------------------------------------------------------------------------------

-- Game state of one quest. log: {[questID] = {complete = bool, failed = bool}}; completed:
-- {[questID] = true}; completedKnown: false when the client has no completed-quest API.
-- Returns "completed", "failed", "objectives-done", "active", "absent" or "unknown".
function D.GameState(q, log, completed, completedKnown)
    if completed and completed[q] then
        return "completed"
    end
    local e = log and log[q]
    if e then
        if e.failed then
            return "failed"
        end
        return e.complete and "objectives-done" or "active"
    end
    if completedKnown == false then
        return "unknown"
    end
    return "absent"
end

local IN_LOG = { active = true, ["objectives-done"] = true, failed = true }

-- The kind of disagreement between a step's effective state and the game state of its quest, or
-- nil when they agree. believedAccepted: the engine thinks the quest was accepted (an ACCEPT step
-- for it is done, or the route has no ACCEPT step for it).
function D.Classify(step, state, game, believedAccepted)
    if game == "unknown" then
        return nil
    end
    local t = step.t
    if state == "done" then
        if t == "A" and game == "absent" then
            return "done-not-accepted"
        elseif t == "C" and (game == "active" or game == "absent" or game == "failed") then
            return "done-not-complete"
        elseif t == "T" and game ~= "completed" then
            return "done-not-turned-in"
        end
    elseif state == "pending" then
        if game == "completed" then
            return t == "T" and "stale-turnin" or "stale-step"
        elseif (t == "T" or t == "C") and game == "failed" then
            return "pending-failed"
        elseif (t == "T" or t == "C") and game == "absent" and believedAccepted then
            return t == "T" and "turnin-not-in-log" or "complete-not-in-log"
        end
    elseif state == "archived" and IN_LOG[game] then
        return "archived-in-log"
    end
    return nil
end

-- Every disagreement for a step list. eff: index -> effective state (engine E.eff). hidden: quests
-- hidden under collapsed headers; when there are any, a disagreement based on "absent" is flagged
-- uncertain (the quest may be one of them). Returns a list of {i, k, q, t, engine, game, kind,
-- uncertain} in step order.
function D.Disagreements(steps, eff, log, completed, completedKnown, hidden)
    local accepted = {}
    local hasAccept = {}
    for i, s in ipairs(steps) do
        if s.q and s.t == "A" then
            hasAccept[s.q] = true
            if eff[i] == "done" then
                accepted[s.q] = true
            end
        end
    end
    local out = {}
    for i, s in ipairs(steps) do
        if s.q and (s.t == "A" or s.t == "C" or s.t == "T") then
            local game = D.GameState(s.q, log, completed, completedKnown)
            local believed = accepted[s.q] or not hasAccept[s.q]
            local kind = D.Classify(s, eff[i], game, believed)
            if kind then
                out[#out + 1] = { i = i, k = s.k, q = s.q, t = s.t, engine = eff[i], game = game, kind = kind,
                    uncertain = (game == "absent" and (hidden or 0) > 0) or nil }
            end
        end
    end
    return out
end

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
    local ids = {}
    for id in pairs(K.index.quests or {}) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
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

-- Disagreements for the loaded route against the live game.
function D.Check()
    local E = K.Engine
    local log, _, _, hidden = D.ReadLog()
    local completed, known = D.ReadCompleted()
    return D.Disagreements(E.steps or {}, E.eff or {}, log, completed, known, hidden), known, hidden
end

-- ---- Mark provenance --------------------------------------------------------------------------

-- Called by the engine for every stored state (Engine.lua noteMark). Records the source and the
-- game state of the quest at that moment; sync marks skip the game read (they come from it).
function D.NoteMark(source, step, state)
    local cdb = K.cdb
    if not cdb or not step then
        return
    end
    cdb.markLog = cdb.markLog or {}
    local game
    if step.q and source ~= "sync" then
        local log, _, _, hidden = D.ReadLog()
        local done = C.IsQuestCompleted(step.q)
        local set = (done == nil) and C.GetCompletedSet() or nil
        if set then
            done = set[step.q] and true or false
        end
        game = D.GameState(step.q, log, done and { [step.q] = true } or {}, done ~= nil)
        if game == "absent" and hidden > 0 then
            game = "absent-or-hidden"
        end
    end
    local list = cdb.markLog
    list[#list + 1] = {
        k = step.k, q = step.q, t = step.t, st = state, src = source or "?",
        lv = K.player and K.player.level, g = game,
    }
    while #list > D.MARKLOG_MAX do
        table.remove(list, 1)
    end
    if game and step.q then
        local kind = D.Classify(step, state, game, true)
        if kind then
            K.Log("mark disagrees", step.k, step.q, game, source or "?", kind)
        end
    end
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

-- A save-state snapshot of the character, as a plain table (see the header comment).
function D.Snapshot()
    local p = K.Detect()
    local E = K.Engine
    local xp, xpMax, rested = C.GetXP()
    local mapID = C.GetBestMapForPlayer()
    local pos = mapID and C.GetPlayerMapPosition(mapID)
    local zone, subzone = C.GetZoneTexts()
    local log, lines, numQuests, hidden = D.ReadLog(true)
    local completed, known, flagged, setList = D.ReadCompleted()
    local cursorIndex, cursorStep = E:Current()
    local cdb = K.cdb or {}
    local disagreements = D.Disagreements(E.steps or {}, E.eff or {}, log, completed, known, hidden)
    return {
        schema = D.DUMP_SCHEMA,
        addon = K.version,
        engineMode = K.EngineMode and K.EngineMode() or "legacy",
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
            stepState = copy(cdb.stepState),
            detours = copy(cdb.detours),
            declined = copy(cdb.declined),
            gearChoice = copy(cdb.gearChoice),
            ignoredSuggestions = copy(cdb.ignoredSuggestions),
            elitePending = copy(cdb.elitePending),
            auditDone = cdb.auditDone,
            markLog = copy(cdb.markLog),
        },
        options = copy(K.db and K.db.options),
        disagreements = disagreements,
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
    K.Print(string.format(L.DUMP_SAVED, key, #(snap.questLog or {}), #(snap.completed or {}),
        #snap.disagreements))
    return snap, key
end

-- /klimax audit state: prints the disagreements for the loaded route.
function D.ReportState()
    local E = K.Engine
    if not E.routeId then
        K.Print(L.AUDIT_NONE)
        return {}
    end
    local list, known, hidden = D.Check()
    if not known then
        K.Print(L.AUDIT_STATE_NO_API)
    end
    if hidden and hidden > 0 then
        K.Print(string.format(L.AUDIT_STATE_HIDDEN, hidden))
    end
    if #list == 0 then
        K.Print(string.format(L.AUDIT_STATE_CLEAN, E.routeId))
        return list
    end
    K.Print(string.format(L.AUDIT_STATE_HEAD, #list, E.routeId))
    for n = 1, math.min(#list, D.REPORT_MAX) do
        local d = list[n]
        local label = L["DIAG_" .. (d.kind:gsub("-", "_"))] or d.kind
        K.Print(string.format(L.AUDIT_STATE_LINE, d.k, d.q, d.game, d.engine, label)
            .. (d.uncertain and L.AUDIT_STATE_UNCERTAIN or ""))
    end
    if #list > D.REPORT_MAX then
        K.Print(string.format(L.AUDIT_STATE_MORE, #list - D.REPORT_MAX))
    end
    return list
end
