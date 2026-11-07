-- Step engine: route loading and filtering, cursor, step state, skip cascade, grouping,
-- event-driven auto-advance and route choice (PRD 7.1 and 7.3).
--
-- Step state is stored per character by stable step key k, never by index:
--   KlimaxCharDB.stepState[routeId][k] = "done" | "skipped" | "archived"
-- Cascaded skips are derived from the stored states on every Recompute, so unskipping a step
-- restores the steps it had hidden. Nothing about cascades is saved.
local _, K = ...
local L = K.L

local E = {}
K.Engine = E

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
    self.cursor = nil
    if not self.routeId then
        notify(self)
        return
    end
    local st = charState(self.routeId)
    local dead = {}
    for i, s in ipairs(self.steps) do
        local m = st[s.k]
        local e = (m == "done" or m == "skipped" or m == "archived") and m or "pending"
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
        if self.eff[i] == "pending" and not gated(s) then
            self.cursor = i
            break
        end
    end
    K.cdb = K.cdb or {}
    K.cdb.routeId = self.routeId
    K.cdb.cursor = self.cursor and self.steps[self.cursor].k or nil
    notify(self)
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
    self:Recompute()
    return true
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
    local preferred = RACE_BRANCH[(K.player or {}).race] or "horde"
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
local function bandFor(branch, level)
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
    local branch = RACE_BRANCH[player.race] or RACE_BRANCH[player.raceToken]
    local id = branch and bandFor(branch, level)
    if id then
        return id, "branch"
    end
    id = bandFor("horde", level)
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
    for _, j in ipairs(self:Batch(i)) do
        if self.eff[j] == "pending" then
            st[self.steps[j].k] = "done"
            marked = marked + 1
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
    self:Recompute()
    return countEff(self, "cascade") - before
end

-- Clears a manual skip or archive by stable key. Cascaded steps come back on their own.
function E:Unskip(k)
    local st = charState(self.routeId)
    if st[k] == "skipped" or st[k] == "archived" then
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
local function markWhere(self, pred)
    if not self.routeId or not autoAdvanceOn() then
        return false
    end
    local st = charState(self.routeId)
    local changed = false
    for i, s in ipairs(self.steps) do
        if self.eff[i] == "pending" and pred(s) then
            st[s.k] = "done"
            changed = true
        end
    end
    if changed then
        self:Recompute()
    end
    return changed
end

-- Marks the cursor step done when its type is in `types` (a set of letters).
local function markCursorIf(self, types)
    local i = self.cursor
    if not i or not types[self.steps[i].t] or not autoAdvanceOn() then
        return false
    end
    charState(self.routeId)[self.steps[i].k] = "done"
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
    end)
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
    end)
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
    return markCursorIf(self, { H = true })
end

-- Throttled quest log checks: many QUEST_LOG_UPDATE events collapse into one check per second.
local logCheckQueued = false

K.On("QUEST_ACCEPTED", function(a, b)
    local questID = tonumber(b) or tonumber(a)
    if questID then
        markWhere(E, function(s) return s.q == questID and s.t == "A" end)
    end
end)

K.On("QUEST_TURNED_IN", function(questID)
    questID = tonumber(questID)
    if questID then
        markWhere(E, function(s) return s.q == questID end)
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
        markCursorIf(E, { U = true })
    end
end)

local trainerOpen = false
K.On("TRAINER_SHOW", function()
    trainerOpen = true
end)
K.On("TRAINER_CLOSED", function()
    if trainerOpen then
        trainerOpen = false
        markCursorIf(E, { R = true })
    end
end)

K.On("MERCHANT_CLOSED", function()
    markCursorIf(E, { B = true, P = true })
end)

K.Every(1, function()
    E:CheckPosition()
end)

K.On("PLAYER_LOGIN", function()
    E:Start()
end)
