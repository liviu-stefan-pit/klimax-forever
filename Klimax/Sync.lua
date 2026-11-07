-- Completed-quest sync (PRD 7.2): checks every quest the routes reference, in slices of frames,
-- then marks the matching steps of the loaded route done and places the cursor.
--
-- Level sync, the level-up prompt and the login audit come in phase 09. Their hooks are:
--   K.Sync:OnLevelUp(level)   called by the engine on PLAYER_LEVEL_UP (stub logs for now)
--   K.Sync.afterSync          list of fn(result, marked), called after every applied sync
local _, K = ...
local L = K.L

local S = {}
K.Sync = S

S.BATCH = 200            -- quest checks per frame slice
S.afterSync = {}
S.generation = 0

-- Every quest id referenced by any route, sorted.
function S:QuestIds()
    local ids = {}
    for id in pairs(K.index.quests or {}) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

-- Coroutine body: checks completion for each id, yielding every S.BATCH checks. Returns
-- {completed = {[id] = true}, log = <Compat.GetQuestLog>, scanned = n} when finished.
local function scanner(ids)
    return coroutine.create(function()
        local flagged = K.Compat.HasFlaggedCompletedApi()
        local set = (not flagged) and K.Compat.GetCompletedSet() or nil
        local completed = {}
        local n = 0
        for _, questID in ipairs(ids) do
            if flagged then
                if K.Compat.IsQuestCompleted(questID) then
                    completed[questID] = true
                end
            elseif set and set[questID] then
                completed[questID] = true
            end
            n = n + 1
            if n % S.BATCH == 0 then
                coroutine.yield(n, #ids)
            end
        end
        return { completed = completed, log = K.Compat.GetQuestLog(), scanned = n }
    end)
end

-- Marks steps of the loaded route done from a scan result. Only steps still pending (no stored
-- state) are touched, so skips and archives survive. Returns the number of steps marked.
function S:Apply(result)
    local E = K.Engine
    if not E.routeId then
        return 0
    end
    K.cdb.stepState = K.cdb.stepState or {}
    local st = K.cdb.stepState[E.routeId] or {}
    K.cdb.stepState[E.routeId] = st
    local marked = 0
    for _, s in ipairs(E.steps) do
        local q = s.q
        if q and st[s.k] == nil then
            local entry = result.log[q]
            local done = false
            if s.t == "A" then
                done = result.completed[q] or entry ~= nil
            elseif s.t == "C" then
                done = result.completed[q] or (entry ~= nil and entry.complete)
            elseif s.t == "T" then
                done = result.completed[q]
            end
            if done then
                st[s.k] = "done"
                marked = marked + 1
            end
        end
    end
    E:Recompute()
    for _, fn in ipairs(self.afterSync) do
        local ok, err = pcall(fn, result, marked)
        if not ok then
            K.Log("afterSync hook error", tostring(err))
        end
    end
    return marked
end

-- Runs a sync for the loaded route. onDone(result, marked) runs when it has been applied.
-- A newer Run supersedes an older one still in progress.
function S:Run(onDone)
    if not K.Engine.routeId then
        return false
    end
    self.generation = self.generation + 1
    local gen = self.generation
    local co = scanner(self:QuestIds())
    local function pump()
        if gen ~= S.generation then
            return
        end
        local ok, value = coroutine.resume(co)
        if not ok then
            K.Log("sync failed", tostring(value))
            return
        end
        if coroutine.status(co) == "dead" then
            local marked = S:Apply(value)
            K.Log("sync", value.scanned, "quests checked,", marked, "steps marked")
            if onDone then
                onDone(value, marked)
            end
        else
            C_Timer.After(0, pump)
        end
    end
    pump()
    return true
end

-- Phase 09 hook. For now it only logs the level change.
function S:OnLevelUp(level)
    K.Log("level up to", level, "(level sync arrives in phase 09)")
end

-- Manual sync: prints how many steps it marked.
function S:RunAndReport()
    return self:Run(function(_, marked)
        K.Print(string.format(L.SYNCED, marked))
    end)
end
