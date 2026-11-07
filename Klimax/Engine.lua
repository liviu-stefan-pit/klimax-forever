-- Step engine: route loading and filtering, cursor, step state, skip cascade, grouping,
-- event-driven auto-advance and route choice (PRD 7.1 and 7.3).
--
-- Step state is stored per character by stable step key k, never by index:
--   KlimaxCharDB.stepState[routeId][k] = "done" | "skipped" | "archived" | "hidden"
-- Cascaded skips are derived from the stored states on every Recompute, so unskipping a step
-- restores the steps it had hidden. Nothing about cascades is saved.
--
-- Phase 20: for ACCEPT, COMPLETE and TURNIN steps the game is the truth. Once K.State is ready,
-- a quest step's effective state is derived from the reconciler's quest state (questEff below);
-- the stored state only counts for player choices (skip, hide) and for quests the game cannot
-- decide (untracked, no completed-quest API, scan not finished). Effective states are:
--   pending | done | skipped | archived | cascade | blocked
-- "blocked" means the quest cannot be done right now (prerequisite, exclusive, failed, needs an
-- accept that is not in this band); it is never the cursor and comes back when the game changes.
local _, K = ...
local L = K.L

local E = {}
K.Engine = E
-- Phase 18: this step engine is the "legacy" engine. It stays selectable by K.EngineMode() so a
-- later engine can be compared with it (see Core.lua).
K.engines = K.engines or {}
K.engines.legacy = E

E.routeId = nil
E.raw = nil
E.steps = {}     -- steps of the loaded route that apply to this character (class and race)
E.byKey = {}     -- stable key -> index into E.steps
E.eff = {}       -- index -> pending | done | skipped | archived | cascade
E.cursor = nil   -- index into E.steps of the step to show, or nil when nothing is left
E.observers = {}

local TRAVEL_RADIUS = 3.0   -- map percent; about 30 yards in a typical zone
local HEARTH_SPELL = 8690

-- Race name (UnitRace, English) to the start branch that owns it (PRD 2, phase 05 decisions).
local RACE_BRANCH = {
    Orc = "durotar", Troll = "durotar",
    Tauren = "mulgore",
    Undead = "tirisfal", Scourge = "tirisfal",
}

-- ---- Helpers ----------------------------------------------------------------------------------

-- Phase 18 instrumentation: every state the engine stores is reported to K.Diag (when loaded)
-- with its source, so a dump can show why a step was marked. It never changes what is stored.
local function noteMark(source, step, state)
    if K.Diag and K.Diag.NoteMark then
        K.Diag.NoteMark(source, step, state)
    end
end
E.NoteMark = noteMark

local function contains(list, value)
    if type(list) ~= "table" or value == nil then
        return false
    end
    for i = 1, #list do
        if list[i] == value then
            return true
        end
    end
    return false
end

-- Class and race filters (phase 06 task 2). A race- or class-limited step needs a matching player.
local function applies(step, player)
    if step.cl and not contains(step.cl, player.class) then
        return false
    end
    if step.ra and not (contains(step.ra, player.race) or contains(step.ra, player.raceToken)) then
        return false
    end
    return true
end

-- Auto-advance can be switched off in the options (phase 07). Manual Next, Skip and sync still work.
local function autoAdvanceOn()
    return K.Option == nil or K.Option("autoAdvance") ~= false
end

-- Per-character state table for one route, created on demand.
local function charState(routeId)
    K.cdb = K.cdb or {}
    K.cdb.stepState = K.cdb.stepState or {}
    local t = K.cdb.stepState[routeId]
    if not t then
        t = {}
        K.cdb.stepState[routeId] = t
    end
    return t
end

local function gated(step)
    local level = (K.player and K.player.level) or 1
    return step.ml ~= nil and level < step.ml
end

local QUEST_STEP = { A = true, C = true, T = true }

-- Effective state of a quest step from the reconciler's quest state (phase 20). m is the stored
-- state (nil when none). hasAccept: the loaded route has an ACCEPT step for the quest. Returns the
-- effective state and true when the step is held back only by its level (shown, never cursor).
local function questEff(s, m, qs, why, hasAccept)
    if m == "skipped" then
        return "skipped"
    end
    if qs == "broken" then
        return "cascade"
    elseif qs == "ignored" then
        return "skipped"
    elseif qs == "completed" then
        return "done"
    elseif qs == "objectives-done" then
        return s.t == "T" and "pending" or "done"
    elseif qs == "active" then
        return s.t == "A" and "done" or "pending"
    elseif qs == "failed" then
        return s.t == "A" and "done" or "blocked"
    end
    if m == "hidden" then
        return "skipped"
    end
    if qs == "unknown" then
        if why == "no-completed-api" and s.t ~= "A" then
            -- accepted earlier, not in the log, and the game cannot say it was handed in
            return "blocked"
        end
        return (m == "done" or m == "archived") and m or "pending"
    end
    if qs == "available" or qs == "abandoned" then
        if m == "archived" then
            return "archived"
        end
        if s.t ~= "A" and not hasAccept then
            return "blocked"
        end
        local level = (K.player and K.player.level) or 1
        local gear = K.cdb and K.cdb.gearChoice
        local choice = gear and gear[tostring(E.routeId) .. "|" .. tostring(s.q)]
        if K.Sync and K.Sync.Verdict(s, level, nil, false, choice) == "archive" then
            return "archived"
        end
        return "pending"
    end
    if qs == "unavailable" then
        if why == "level" then
            return "pending", true
        end
        return "blocked"
    end
    return (m == "done" or m == "archived") and m or "pending"
end
E.QuestEff = questEff

-- True when no prerequisite of an ACCEPT can be met: all of `pa` are unreachable, or all of `po`.
local function prereqsUnreachable(step, dead)
    if step.pa then
        for _, p in ipairs(step.pa) do
            if dead[p] then
                return true
            end
        end
    end
    if step.po and #step.po > 0 then
        for _, p in ipairs(step.po) do
            if not dead[p] then
                return false
            end
        end
        return true
    end
    return false
end

local function sortedRouteIds()
    local ids = {}
    for id in pairs(K.routes) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

local function notify(self)
    for i = 1, #self.observers do
        local ok, err = pcall(self.observers[i], self)
        if not ok then
            K.Log("observer error", tostring(err))
        end
    end
end

-- ---- Observers and reads ----------------------------------------------------------------------

-- Registers fn(engine), called after every change of state or cursor.
function E:OnChange(fn)
    self.observers[#self.observers + 1] = fn
end

-- Returns index, step, effective state of the cursor step, or nil.
function E:Current()
    local i = self.cursor
    if not i then
        return nil
    end
    return i, self.steps[i], self.eff[i]
end

-- Indices of the ACCEPT batch that contains step i: consecutive ACCEPT steps with the same
-- NPC and zone (PRD 7.3, grouped hub loops). Non-ACCEPT steps form a batch of one.
function E:Batch(i)
    local s = self.steps[i]
    if not s or s.t ~= "A" then
        return { i }
    end
    local function same(other)
        return other and other.t == "A" and s.npc ~= nil and other.npc == s.npc and other.z == s.z
    end
    local first, last = i, i
    while first > 1 and same(self.steps[first - 1]) do
        first = first - 1
    end
    while last < #self.steps and same(self.steps[last + 1]) do
        last = last + 1
    end
    local out = {}
    for j = first, last do
        out[#out + 1] = j
    end
    return out
end

local function countEff(self, state)
    local n = 0
    for i = 1, #self.steps do
        if self.eff[i] == state then
            n = n + 1
        end
    end
    return n
end

-- ---- Derivation -------------------------------------------------------------------------------

-- Recomputes effective states and the cursor from the stored states. One ordered pass:
--   * a skipped step makes its quest unreachable for the rest of the route,
--   * a later step of an unreachable quest (COMPLETE, TURNIN, ACCEPT) is cascaded,
--   * an ACCEPT whose prerequisites are unreachable is cascaded and its quest becomes unreachable,
--   * a done step proves its quest reachable again.
function E:Recompute()
    self.eff = {}
    self.levelHeld = {}
    self.cursor = nil
    if not self.routeId then
        notify(self)
        return
    end
    local st = charState(self.routeId)
    local State = K.State
    local truth = State and State:Ready()
    local hasAccept = {}
    if truth then
        for _, s in ipairs(self.steps) do
            if s.t == "A" and s.q then
                hasAccept[s.q] = true
            end
        end
    end
    local dead = {}
    for i, s in ipairs(self.steps) do
        local m = st[s.k]
        local e
        if truth and s.q and QUEST_STEP[s.t] then
            local qs, why = State:Get(s.q)
            local held
            e, held = questEff(s, m, qs, why, hasAccept[s.q])
            self.levelHeld[i] = held or nil
        else
            e = (m == "done" or m == "skipped" or m == "archived") and m or "pending"
            if m == "hidden" then
                e = "skipped"
            end
        end
        if e == "pending" and s.q and dead[s.q] then
            e = "cascade"
        elseif e == "pending" and s.t == "A" and prereqsUnreachable(s, dead) then
            e = "cascade"
        end
        if e == "skipped" or e == "cascade" then
            if s.q then
                dead[s.q] = true
            end
        elseif e == "done" then
            if s.q then
                dead[s.q] = nil
            end
        end
        self.eff[i] = e
    end
    for i, s in ipairs(self.steps) do
        if self.eff[i] == "pending" and not gated(s) and not self.levelHeld[i] then
            self.cursor = i
            break
        end
    end
    -- Phase 21 (KF9): a turn-in that is ready where the player stands comes first.
    local here = self.cursor and E.ReadyTurnInHere(self)
    if here then
        self.cursor = here
    end
    K.cdb = K.cdb or {}
    K.cdb.routeId = self.routeId
    K.cdb.cursor = self.cursor and self.steps[self.cursor].k or nil
    notify(self)
end

E.NEAR_READY = 5.0  -- map-%: about 50 yards

-- Index of a pending TURNIN, in route order, whose quest is ready to hand in and whose NPC stands
-- within NEAR_READY of the player on the same map; nil when the cursor step is already that close.
function E.ReadyTurnInHere(self)
    local mapID = K.Compat.GetBestMapForPlayer()
    local pos = mapID and K.Compat.GetPlayerMapPosition(mapID)
    if not pos then
        return nil
    end
    local px, py = pos.x * 100, pos.y * 100
    local function near(s)
        if s.z ~= mapID or not s.x or not s.y then
            return false
        end
        local dx, dy = s.x - px, s.y - py
        return dx * dx + dy * dy <= E.NEAR_READY * E.NEAR_READY
    end
    if near(self.steps[self.cursor]) then
        return nil
    end
    local log
    for i, s in ipairs(self.steps) do
        if s.t == "T" and self.eff[i] == "pending" and not self.levelHeld[i] and near(s) then
            local ready
            if K.State and K.State:Ready() then
                ready = K.State:Get(s.q) == "objectives-done"
            else
                log = log or K.Compat.GetQuestLog()
                ready = log[s.q] ~= nil and log[s.q].complete
            end
            if ready then
                return i
            end
        end
    end
    return nil
end

-- Rebuilds stable key -> index for a step list.
local function keyIndex(list)
    local out = {}
    for i, s in ipairs(list) do
        out[s.k] = i
    end
    return out
end

-- ---- Loading ----------------------------------------------------------------------------------

-- Loads a registered route, filtered to the current player. Returns true or false, reason.
function E:Load(routeId)
    local raw = K.routes[routeId]
    if not raw then
        return false, "unknown route"
    end
    local player = K.player or {}
    self.routeId = routeId
    self.raw = raw
    self.steps = {}
    self.byKey = {}
    for _, s in ipairs(raw.steps or {}) do
        if applies(s, player) then
            self.steps[#self.steps + 1] = s
            self.byKey[s.k] = #self.steps
        end
    end
    self.byKey = keyIndex(self.steps)
    self:ReplayDetours()
    self:Recompute()
    return true
end

-- Steps of quest `quest` in route `srcRoute` that a detour needs: accept, complete, turn in,
-- in route order, filtered to this character. The original step tables are reused, so their
-- stable keys (and saved states) do not change.
function E:DetourSteps(quest, srcRoute)
    local raw = K.routes[srcRoute]
    local out = {}
    for _, s in ipairs(raw and raw.steps or {}) do
        if s.q == quest and (s.t == "A" or s.t == "C" or s.t == "T") and applies(s, K.player or {}) then
            out[#out + 1] = s
        end
    end
    return out
end

-- Index of the first step with no stored state (where a new detour goes).
local function firstOpen(self)
    local st = charState(self.routeId)
    for i, s in ipairs(self.steps) do
        if st[s.k] == nil then
            return i
        end
    end
    return #self.steps + 1
end

-- Splices a detour's steps in at `index`, skipping keys already present. Returns the count.
local function splice(self, index, quest, srcRoute)
    local added = 0
    for _, s in ipairs(self:DetourSteps(quest, srcRoute)) do
        if not self.byKey[s.k] then
            table.insert(self.steps, index + added, s)
            added = added + 1
        end
    end
    self.byKey = keyIndex(self.steps)
    return added
end

-- Re-inserts the detours saved for this route (called from Load, so they survive a reload).
function E:ReplayDetours()
    local saved = K.cdb and K.cdb.detours and K.cdb.detours[self.routeId] or {}
    for _, d in ipairs(saved) do
        splice(self, firstOpen(self), d.q, d.src)
    end
end

-- "Go there" (PRD 7.10): inserts the accept, complete and turn-in steps of a quest from an
-- earlier band at the cursor. Saved per route, so it is replayed on the next load.
-- Returns the number of steps inserted; 0 when the quest is already detoured or unknown.
function E:GoThere(quest, srcRoute)
    if not self.routeId or not quest then
        return 0
    end
    K.cdb.detours = K.cdb.detours or {}
    local list = K.cdb.detours[self.routeId] or {}
    for _, d in ipairs(list) do
        if d.q == quest then
            return 0
        end
    end
    local index = self.cursor or firstOpen(self)
    local added = splice(self, index, quest, srcRoute)
    if added == 0 then
        return 0
    end
    list[#list + 1] = { q = quest, src = srcRoute }
    K.cdb.detours[self.routeId] = list
    self:Recompute()
    return added
end

-- True when a quest already has a detour in the loaded route.
function E:HasDetour(quest)
    for _, d in ipairs((K.cdb.detours or {})[self.routeId] or {}) do
        if d.q == quest then
            return true
        end
    end
    return false
end

-- Archives every pending step of a quest (PRD 7.9). Done and skipped steps keep their state.
-- Returns the number of steps archived.
function E:ArchiveQuest(quest)
    local st = charState(self.routeId)
    local n = 0
    for i, s in ipairs(self.steps) do
        if s.q == quest and self.eff[i] == "pending" then
            st[s.k] = "archived"
            noteMark("archive-quest", s, "archived")
            n = n + 1
        end
    end
    if n > 0 then
        self:Recompute()
    end
    return n
end

-- Route id for a band spec: a route id, or "lo-hi". For a shared band the player's branch wins,
-- then "horde", then the first id in sorted order.
function E:FindBand(spec)
    spec = tostring(spec or ""):match("^%s*(.-)%s*$")
    if K.routes[spec] then
        return spec
    end
    local lo, hi = spec:match("^(%d+)%-(%d+)$")
    if not lo then
        return nil
    end
    lo, hi = tonumber(lo), tonumber(hi)
    local preferred = E.BranchForPlayer(K.player) or "horde"
    local best, bestRank
    for _, id in ipairs(sortedRouteIds()) do
        local r = K.routes[id]
        if r.lo == lo and r.hi == hi then
            local rank = (r.branch == preferred) and 0 or ((r.branch == "horde") and 1 or 2)
            if not bestRank or rank < bestRank then
                best, bestRank = id, rank
            end
        end
    end
    return best
end

-- Loads a band (by id or "lo-hi"), stores it as the character's route and runs a sync.
function E:JumpToBand(spec)
    local routeId = self:FindBand(spec)
    if not routeId then
        return false, "no band matches " .. tostring(spec)
    end
    local ok, reason = self:Load(routeId)
    if not ok then
        return false, reason
    end
    K.cdb.routeId = routeId
    if K.Sync then
        K.Sync:Run()
    end
    return true
end

-- Band for a branch and level. A band with level < hi wins; a boundary level falls to the next band.
-- Start branch that owns a race (nil for shared-only races).
function E.BranchFor(race)
    return RACE_BRANCH[race]
end

E.ZEPHRAS_MAP = 2521

-- Start branch of this character (phase 20, KF10): Zephra's Isle when the character stands there
-- or has handed in a Zephra's Isle quest (any race can start there), else the race's branch.
function E.BranchForPlayer(player)
    player = player or K.player or {}
    local mapID = K.Compat.GetBestMapForPlayer()
    if mapID == E.ZEPHRAS_MAP then
        return "zephras"
    end
    local cache = K.Snapshot and K.Snapshot.completed or {}
    local checked = 0
    for _, id in ipairs(sortedRouteIds()) do
        local r = K.routes[id]
        if r.branch == "zephras" then
            for _, s in ipairs(r.steps or {}) do
                if s.t == "T" and s.q and checked < 60 then
                    checked = checked + 1
                    if cache[s.q] or K.Compat.IsQuestCompleted(s.q) then
                        return "zephras"
                    end
                end
            end
        end
    end
    return RACE_BRANCH[player.race] or RACE_BRANCH[player.raceToken]
end

function E.BandFor(branch, level)
    local best, bestLo
    for _, id in ipairs(sortedRouteIds()) do
        local r = K.routes[id]
        if r.branch == branch and r.lo and r.hi and r.lo <= level and level <= r.hi then
            if level < r.hi then
                return id
            end
            if not best or r.lo > bestLo then
                best, bestLo = id, r.lo
            end
        end
    end
    return best
end

-- Picks the route for this player (PRD 7.1): resume a saved route, otherwise the race branch
-- band for the level, otherwise the shared Horde band. Returns routeId, reason or nil, reason.
function E.ChooseRoute(player)
    if player.faction ~= "Horde" then
        return nil, "faction"
    end
    local cdb = K.cdb or {}
    if cdb.routeId and K.routes[cdb.routeId] then
        return cdb.routeId, "resume"
    end
    local level = player.level or 1
    local branch = E.BranchForPlayer(player)
    local id = branch and E.BandFor(branch, level)
    if id then
        return id, "branch"
    end
    id = E.BandFor("horde", level)
    if id then
        return id, "shared"
    end
    return nil, "no band"
end

-- Login entry point: detect the player, choose the route, load it and sync.
function E:Start()
    local player = K.Detect()
    if player.faction == "Alliance" then
        K.Print(L.ALLIANCE_SOON)
        K.Log("alliance: no route in v1")
        return false
    end
    local id, reason = E.ChooseRoute(player)
    if not id then
        K.Print(string.format(L.NO_ROUTE, player.level or 1))
        K.Log("no route", reason, tostring(player.race), tostring(player.level))
        return false
    end
    local ok, err = self:Load(id)
    if not ok then
        K.Log("load failed", id, err)
        return false
    end
    K.cdb.routeId = id
    if reason == "resume" then
        K.Print(string.format(L.RESUMED, id))
    else
        K.Print(string.format(L.STARTED, id, player.level or 1))
    end
    K.Log("route", id, reason)
    if K.Sync then
        K.Sync:Run()
    end
    return true
end

-- ---- Player actions ---------------------------------------------------------------------------

-- Marks the cursor step done. For an ACCEPT, the whole hub batch is marked done.
-- Returns the number of steps marked.
function E:Next()
    return self:MarkDone(self.cursor)
end

-- Marks the step at index i and its hub batch done (phase 07: the UI can act on a focused step
-- that is not the cursor). Returns the number of steps marked.
function E:MarkDone(i)
    local s = i and self.steps[i]
    if not s then
        return 0
    end
    local st = charState(self.routeId)
    local marked = 0
    local State = K.State
    local truth = State and State:Ready()
    for _, j in ipairs(self:Batch(i)) do
        local step = self.steps[j]
        if self.eff[j] == "pending" then
            local qs = truth and step.q and QUEST_STEP[step.t] and State:Get(step.q) or nil
            local contradicts = qs == "available" or qs == "abandoned" or qs == "unavailable"
            if not contradicts then
                st[step.k] = "done"
                noteMark(j == i and "next" or "next-batch", step, "done")
                marked = marked + 1
            elseif j == i then
                -- Phase 20: the game says this quest is not in the log. Next never claims it done;
                -- it hides the step instead (restorable like a skip). Batch members are left alone.
                st[step.k] = "hidden"
                noteMark("next-hidden", step, "hidden")
                marked = marked + 1
            end
        end
    end
    self:Recompute()
    return marked
end

-- Skips step i (default: the cursor). Returns the number of dependent steps cascaded.
function E:Skip(i)
    i = i or self.cursor
    local s = i and self.steps[i]
    if not s or self.eff[i] ~= "pending" and self.eff[i] ~= "cascade" then
        return 0
    end
    local before = countEff(self, "cascade")
    charState(self.routeId)[s.k] = "skipped"
    noteMark("skip", s, "skipped")
    if K.Elite then
        K.Elite.OnSkip(s, self.routeId)
    end
    self:Recompute()
    return countEff(self, "cascade") - before
end

-- Clears a manual skip or archive by stable key. Cascaded steps come back on their own.
function E:Unskip(k)
    local st = charState(self.routeId)
    if st[k] == "skipped" or st[k] == "archived" or st[k] == "hidden" then
        st[k] = nil
        self:Recompute()
        return true
    end
    return false
end

-- Resets progress. scope "band" clears the loaded route; "all" clears every route.
function E:Reset(scope)
    K.cdb = K.cdb or {}
    K.cdb.stepState = K.cdb.stepState or {}
    if scope == "all" then
        K.cdb.stepState = {}
    elseif self.routeId then
        K.cdb.stepState[self.routeId] = {}
    end
    if self.routeId then
        self:Recompute()
    end
    return true
end

-- Marks every pending step that satisfies pred as done. Returns true when something changed.
local function markWhere(self, pred, source)
    if not self.routeId or not autoAdvanceOn() then
        return false
    end
    local st = charState(self.routeId)
    local changed = false
    for i, s in ipairs(self.steps) do
        if self.eff[i] == "pending" and pred(s) then
            st[s.k] = "done"
            noteMark(source, s, "done")
            changed = true
        end
    end
    if changed then
        self:Recompute()
    end
    return changed
end

-- Marks the cursor step done when its type is in `types` (a set of letters).
local function markCursorIf(self, types, source)
    local i = self.cursor
    if not i or not types[self.steps[i].t] or not autoAdvanceOn() then
        return false
    end
    charState(self.routeId)[self.steps[i].k] = "done"
    noteMark(source, self.steps[i], "done")
    self:Recompute()
    return true
end

-- ---- Auto-advance (PRD 7.3) -------------------------------------------------------------------

-- Checks the ACCEPT and COMPLETE steps against the quest log. Used by QUEST_LOG_UPDATE.
function E:CheckQuestLog(log)
    log = log or K.Compat.GetQuestLog()
    return markWhere(self, function(s)
        local e = s.q and log[s.q]
        if not e then
            return false
        end
        if s.t == "A" then
            return true
        end
        return s.t == "C" and e.complete
    end, "questlog")
end

-- Marks TRAVEL steps done when the player stands within TRAVEL_RADIUS of the cursor step.
-- Coordinates are map percent (route values), so x and y are passed in percent too.
function E:CheckPositionAt(mapID, x, y)
    local i = self.cursor
    if not i or not autoAdvanceOn() then
        return false
    end
    local s = self.steps[i]
    if s.t ~= "V" or s.z ~= mapID or not s.x or not s.y then
        return false
    end
    local dx, dy = x - s.x, y - s.y
    if dx * dx + dy * dy <= TRAVEL_RADIUS * TRAVEL_RADIUS then
        charState(self.routeId)[s.k] = "done"
        noteMark("position", s, "done")
        self:Recompute()
        return true
    end
    return false
end

function E:CheckPosition()
    local i = self.cursor
    if not i or self.steps[i].t ~= "V" then
        return false
    end
    local mapID = K.Compat.GetBestMapForPlayer()
    local pos = mapID and K.Compat.GetPlayerMapPosition(mapID)
    if not pos then
        return false
    end
    return self:CheckPositionAt(mapID, pos.x * 100, pos.y * 100)
end

-- Marks FLY/discover steps done for every known taxi node whose name contains the step's `to`.
-- nodes is a list of {name = string, known = bool}, read from the taxi map by ScanTaxi.
function E:MarkFlightPaths(nodes)
    return markWhere(self, function(s)
        if s.t ~= "D" or not s.to then
            return false
        end
        local want = s.to:lower()
        for _, node in ipairs(nodes) do
            if node.known and node.name and node.name:lower():find(want, 1, true) then
                return true
            end
        end
        return false
    end, "taxi")
end

-- Hearth bind: the cursor H step is done when the bind location matches its `to` (or has none).
function E:HearthBound(location)
    local i = self.cursor
    if not i or self.steps[i].t ~= "H" then
        return false
    end
    local s = self.steps[i]
    if s.to and location ~= s.to then
        return false
    end
    return markCursorIf(self, { H = true }, "bind")
end

-- Throttled quest log checks: many QUEST_LOG_UPDATE events collapse into one check per second.
local logCheckQueued = false

-- Classic sends (logIndex, questID); a lone argument is a log index, not a quest id (phase 18 H1h),
-- and the state refresh reads the log anyway.
K.On("QUEST_ACCEPTED", function(_, b)
    local questID = tonumber(b)
    if questID then
        markWhere(E, function(s) return s.q == questID and s.t == "A" end, "accepted-event")
    end
end)

K.On("QUEST_TURNED_IN", function(questID)
    questID = tonumber(questID)
    if questID then
        markWhere(E, function(s) return s.q == questID end, "turnedin-event")
    end
end)

K.On("QUEST_LOG_UPDATE", function()
    if logCheckQueued then
        return
    end
    logCheckQueued = true
    C_Timer.After(1, function()
        logCheckQueued = false
        E:CheckQuestLog()
    end)
end)

K.On("PLAYER_LEVEL_UP", function(level)
    K.player = K.player or {}
    K.player.level = tonumber(level) or UnitLevel("player") or K.player.level
    E:Recompute()
    if K.Sync then
        K.Sync:OnLevelUp(K.player.level)
    end
end)

K.On("ZONE_CHANGED_NEW_AREA", function()
    E:CheckPosition()
end)

K.On("TAXIMAP_OPENED", function()
    local nodes = {}
    local count = NumTaxiNodes and NumTaxiNodes() or 0
    for n = 1, count do
        local kind = TaxiNodeGetType and TaxiNodeGetType(n)
        nodes[#nodes + 1] = { name = TaxiNodeName and TaxiNodeName(n), known = kind ~= nil and kind ~= "NONE" }
    end
    E:MarkFlightPaths(nodes)
end)

K.On("CONFIRM_BINDER", function()
    C_Timer.After(1, function()
        E:HearthBound(GetBindLocation and GetBindLocation())
    end)
end)

K.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit == "player" and tonumber(spellID) == HEARTH_SPELL then
        markCursorIf(E, { U = true }, "hearth-cast")
    end
end)

local trainerOpen = false
K.On("TRAINER_SHOW", function()
    trainerOpen = true
end)
K.On("TRAINER_CLOSED", function()
    if trainerOpen then
        trainerOpen = false
        markCursorIf(E, { R = true }, "trainer-closed")
    end
end)

K.On("MERCHANT_CLOSED", function()
    markCursorIf(E, { B = true, P = true }, "merchant-closed")
end)

K.Every(1, function()
    E:CheckPosition()
end)

-- Phase 20: every refresh of the game state re-derives the quest steps.
if K.State then
    K.State:OnChange(function()
        if E.routeId then
            E:Recompute()
        end
    end)
end

-- Only the selected engine starts (phase 18 flag). Today "legacy" is the only one registered.
K.On("PLAYER_LOGIN", function()
    if not K.EngineMode or K.EngineMode() == "legacy" then
        E:Start()
    end
end)
