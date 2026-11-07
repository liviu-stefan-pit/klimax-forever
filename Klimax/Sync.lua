-- Completed-quest sync (PRD 7.2) and level sync (PRD 7.9).
--
-- Phase 20: a sync is a resync of K.State (every completed flag rescanned in slices of frames, the
-- whole quest log read). The engine derives its quest steps from that state, so a sync stores
-- nothing. Then the level sync runs:
--   1. a band jump proposal when the level is ahead of the cursor (Jump / Stay),
--   2. outgrown steps (grey at the current level) are shown as archived; this is derived on every
--      Recompute (Engine questEff), never stored, so a quest in the log is never archived,
--   3. gear exception: an outgrown key reward asks "Do it or skip?",
--   4. a chat hint when the cursor step is in another zone.
--
-- The rules are pure functions (S.GreyRange, S.IsGrey, S.Verdict, S.PlanJump) so the busted specs
-- test them without a client. Triggers: the Sync button, login (via Engine:Start), and
-- PLAYER_LEVEL_UP when the level is 2+ above the cursor's expected level (S:OnLevelUp).
local _, K = ...
local L = K.L

local S = {}
K.Sync = S

S.BATCH = 200            -- quest checks per frame slice
S.JUMP_MIN_AHEAD = 2     -- levels above the cursor's expected level that trigger a sync and a jump
S.AUDIT_JUMP = 3         -- a jump of this many levels or more also runs the login audit
S.afterSync = {}
S.generation = 0

-- ---- Pure rules -------------------------------------------------------------------------------

-- Largest level difference at which a quest still gives XP (Classic). Samples from the
-- warcraft.wiki.gg GetQuestGreenRange page: 5 at level 9, 10 at level 50, 12 at level 60. The
-- formula is inferred from those samples and must be checked in game (see PROGRESS.md).
function S.GreyRange(level)
    level = tonumber(level) or 1
    if level <= 39 then
        return 5 + math.floor(level / 10)
    end
    return math.floor(level / 5)
end

-- A quest is grey when it is more than GreyRange levels below the player. Unknown level: not grey.
function S.IsGrey(questLevel, level)
    if not questLevel or questLevel <= 0 or not level then
        return false
    end
    return level - questLevel > S.GreyRange(level)
end

-- What to do with one step during a level sync. state: stored state (nil when pending). inLog:
-- the quest is in the player's log. choice: nil, "do" or "skip" (a stored gear answer).
-- Returns "archive", "keep", "ask" or nil (nothing to do).
function S.Verdict(step, level, state, inLog, choice)
    if not step.q or state ~= nil or inLog then
        return nil
    end
    if not S.IsGrey(step.ql, level) then
        return nil
    end
    if not step.kr then
        return "archive"
    end
    if choice == "do" then
        return "keep"
    end
    if choice == "skip" then
        return "archive"
    end
    return "ask"
end

-- The band to jump to, or nil. curRoute and targetRoute are route tables; cursorLevel is the
-- expected level of the cursor step (nil when there is none); declined maps a route id to the level
-- at which the player pressed Stay.
function S.PlanJump(curRoute, targetRoute, level, cursorLevel, declined)
    if not curRoute or not targetRoute or targetRoute.id == curRoute.id then
        return nil
    end
    if targetRoute.lo <= curRoute.lo or not level then
        return nil
    end
    local base = cursorLevel or curRoute.lo
    if level < base + S.JUMP_MIN_AHEAD then
        return nil
    end
    local said = declined and declined[targetRoute.id]
    if said and level <= said then
        return nil
    end
    return targetRoute
end

-- ---- Completed-quest sync -----------------------------------------------------------------------

-- Every quest id referenced by any route, sorted.
function S:QuestIds()
    local ids = {}
    for id in pairs(K.index.quests or {}) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

-- Legacy scan (used only when K.State is missing): checks completion for each id, yielding every
-- S.BATCH checks. Returns {completed = {[id] = true}, log = <Compat.GetQuestLog>, scanned = n}.
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

-- Applies a scan result. With K.State ready the engine derives its steps from the game state, so
-- nothing is stored and `marked` counts the steps that turned done since `before` (an E.eff copy
-- taken when the sync started). Without K.State (legacy), steps still pending are marked done.
-- Then runs the level sync and the hooks. Returns the number of steps marked.
function S:Apply(result, before)
    local E = K.Engine
    if not E.routeId then
        return 0
    end
    if K.State and K.State:Ready() then
        E:Recompute()
        local marked = 0
        for i = 1, #E.steps do
            if E.eff[i] == "done" and (before or {})[E.steps[i].k] ~= "done" then
                marked = marked + 1
            end
        end
        return S:Finish(result, marked)
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
                E.NoteMark("sync", s, "done")
                marked = marked + 1
            end
        end
    end
    E:Recompute()
    return S:Finish(result, marked)
end

-- Level sync and afterSync hooks after a scan. Returns marked.
function S:Finish(result, marked)
    S.lastResult = result
    S:LevelSync(result)
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
    local E = K.Engine
    if not E.routeId then
        return false
    end
    self.generation = self.generation + 1
    local gen = self.generation
    if K.State then
        local before = {}
        for i, s in ipairs(E.steps) do
            before[s.k] = E.eff[i]
        end
        K.State:Resync(function(snap)
            if gen ~= S.generation then
                return
            end
            local result = { completed = snap.completed, log = snap.log, scanned = #K.Snapshot.QuestIds() }
            local marked = S:Apply(result, before)
            K.Log("sync", result.scanned, "quests checked,", marked, "steps now done")
            if onDone then
                onDone(result, marked)
            end
        end)
        return true
    end
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

-- ---- Level sync -------------------------------------------------------------------------------

local function zoneName(mapID)
    local z = K.zones and mapID and K.zones[mapID]
    return z and z[1] or tostring(mapID)
end

-- Gear answers are stored per route and quest.
local function choiceKey(routeId, quest)
    return tostring(routeId) .. "|" .. tostring(quest)
end

-- Shows the gear exception prompt for one quest. Do it / Skip store the answer and re-run.
local function askGear(step, routeId)
    S.asked = true
    local name = (step.rw and step.rw.why) or L.GEAR_ITEM_FALLBACK
    if step.rw and step.rw.item then
        local data = K.Compat.GetItemInfo(step.rw.item)
        if data and data.name then
            name = data.name
        end
    end
    K.Toast.Show(string.format(L.GEAR_TEXT, name), 30, {
        { text = L.GEAR_DO, fn = function()
            K.cdb.gearChoice[choiceKey(routeId, step.q)] = "do"
            S:LevelSync(S.lastResult)
        end },
        { text = L.GEAR_SKIP, fn = function()
            K.cdb.gearChoice[choiceKey(routeId, step.q)] = "skip"
            S:LevelSync(S.lastResult)
        end },
    })
    K.Log("gear prompt", step.q, routeId)
end

-- Proposes a jump to the band for the current level. Jump loads it (and syncs again).
local function askJump(target, level, cursorLevel)
    local E = K.Engine
    S.asked = true
    local from = K.routes[E.routeId]
    K.Toast.Show(string.format(L.JUMP_TEXT, level, target.lo, target.hi), 30, {
        { text = L.JUMP_YES, fn = function()
            local size = level - (cursorLevel or (from and from.lo) or level)
            if size >= S.AUDIT_JUMP then
                S.pendingAudit = true
            end
            E:JumpToBand(target.id)
        end },
        { text = L.JUMP_NO, fn = function()
            K.cdb.declined = K.cdb.declined or {}
            K.cdb.declined[target.id] = level
            S:LevelSync(S.lastResult)
        end },
    })
    K.Log("jump proposed", target.id, "at level", level)
end

-- Chat hint when the cursor step is in another zone. The hint is not a route step.
local lastHint
local function travelHint(step)
    local mapID = K.Compat.GetBestMapForPlayer()
    if not step or not step.z or not mapID or mapID == step.z then
        lastHint = nil
        return
    end
    if lastHint == step.k then
        return
    end
    lastHint = step.k
    K.Print(string.format(L.TRAVEL_HINT, zoneName(step.z), step.x or 0, step.y or 0))
end

-- The level sync (PRD 7.9). Runs after every completed-quest sync. It asks at most one question
-- (a jump, or one gear prompt) per call; the player's answer runs it again.
function S:LevelSync(result)
    local E = K.Engine
    if not E.routeId or not K.player then
        return
    end
    local cdb = K.cdb
    S.asked = false
    local level = K.player.level or UnitLevel("player") or 1
    K.player.level = level
    local cur = K.routes[E.routeId]
    if not cur then
        return
    end
    local _, cursorStep = E:Current()
    local cursorLevel = cursorStep and cursorStep.el

    -- Step 2: band jump. A jump runs its own sync, so nothing else happens here.
    local targetId = E.BandFor(E.BranchFor(K.player.race) or "horde", level) or E.BandFor("horde", level)
    local target = S.PlanJump(cur, targetId and K.routes[targetId], level, cursorLevel, cdb.declined)
    if target then
        askJump(target, level, cursorLevel)
        return
    end

    -- Steps 3 and 4: outgrown steps are archived by the engine's derivation (phase 20: nothing is
    -- stored, so a quest that is in the log is never archived); ask about key rewards among them.
    local st = cdb.stepState[E.routeId] or {}
    cdb.stepState[E.routeId] = st
    cdb.gearChoice = cdb.gearChoice or {}
    local log = result and result.log or {}
    local derived = K.State and K.State:Ready()
    local asked = {}
    local gear
    for i, s in ipairs(E.steps) do
        if s.q then
            local stored = st[s.k]
            if derived and stored == nil and E.eff[i] ~= "pending" then
                stored = E.eff[i]  -- done, blocked or skipped by the game state: nothing to ask
            end
            local verdict = S.Verdict(s, level, stored, log[s.q] ~= nil,
                cdb.gearChoice[choiceKey(E.routeId, s.q)])
            if verdict == "archive" and not derived then
                st[s.k] = "archived"
                E.NoteMark("levelsync-archive", s, "archived")
            elseif verdict == "ask" and not asked[s.q] then
                asked[s.q] = true
                gear = gear or s
            end
        end
    end
    E:Recompute()
    if gear then
        askGear(gear, E.routeId)
        return
    end

    -- Step 5: cursor and travel hint.
    _, cursorStep = E:Current()
    travelHint(cursorStep)
end

-- Trigger: PLAYER_LEVEL_UP. Syncs when the level is 2+ above the cursor's expected level.
function S:OnLevelUp(level)
    K.Log("level up to", level)
    local _, step = K.Engine:Current()
    if not step or not step.el or level >= step.el + S.JUMP_MIN_AHEAD then
        self:Run()
    end
end

-- Counts how the effective states changed between two {key = state} maps (phase 20 report):
-- completed (now done), hidden (now skipped, archived, cascaded or blocked), available (now
-- pending after being something else). Returns changed, completed, hidden, available.
local HIDDEN = { skipped = true, archived = true, cascade = true, blocked = true }
function S.ChangeReport(before, after)
    local changed, completed, hidden, available = 0, 0, 0, 0
    for k, now in pairs(after) do
        local was = before[k]
        if was ~= nil and was ~= now then
            changed = changed + 1
            if now == "done" then
                completed = completed + 1
            elseif HIDDEN[now] then
                hidden = hidden + 1
            elseif now == "pending" then
                available = available + 1
            end
        end
    end
    return changed, completed, hidden, available
end

local function effByKey()
    local E = K.Engine
    local out = {}
    for i, s in ipairs(E.steps or {}) do
        out[s.k] = E.eff[i]
    end
    return out
end

-- Manual sync and /klimax resync: rebuilds everything from the game and reports what changed.
function S:RunAndReport()
    local before = effByKey()
    return self:Run(function(_, marked)
        if not (K.State and K.State:Ready()) then
            K.Print(string.format(L.SYNCED, marked))
            return
        end
        local changed, completed, hidden, available = S.ChangeReport(before, effByKey())
        if changed == 0 then
            K.Print(L.RESYNC_NONE)
        else
            K.Print(string.format(L.RESYNC_REPORT, changed, completed, hidden, available))
        end
    end)
end
