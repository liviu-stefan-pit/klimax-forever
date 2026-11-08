-- Step engine (phase 29, DYNAMIC_GUIDE_PLAN s8): the window, the arrow and the step menu read the plan
-- the planner builds (Plan/Planner.lua) through this one object. The band engine, Sync and Audit of
-- the earlier phases are gone: the game is the truth (K.State) and the plan follows it.
--
--   E.steps      the plan's steps in order (A accept, C do, T hand in, V travel, S service stop),
--                with the steps the player hid taken out; E.byKey maps a stable key to its index
--   E.eff[i]     always "pending" (a step that is done leaves the plan on the next replan)
--   E.cursor     index of the step to show (1), or nil when there is nothing to plan
--   E:Current(), E:Batch(i), E:OnChange(fn)  reads and observers
--
-- Player choices are saved per character and by stable key, never by index:
--   KlimaxCharDB.skipQuests[q]   quests skipped (Snapshot "skipped": the reconciler hides them)
--   KlimaxCharDB.hiddenSteps[k]  single steps hidden ("mark done" and "skip step")
--   KlimaxCharDB.pin             {k, q}: the planner puts this quest first
local _, K = ...
local L = K.L

local E = {}
K.Engine = E

E.routeId = nil    -- non-nil once started; the window shows its "plan" label
E.steps = {}
E.eff = {}
E.byKey = {}
E.cursor = nil
E.observers = {}
E.plan = nil

local QUEST_STEP = { A = true, C = true, T = true }

-- Start branch by race (the curated spine is keyed by branch).
local RACE_BRANCH = {
    Orc = "durotar", Troll = "durotar",
    Tauren = "mulgore",
    Undead = "tirisfal", Scourge = "tirisfal",
}

-- Start branch that owns a race (nil for races without one).
function E.BranchFor(race)
    return RACE_BRANCH[race]
end

E.ZEPHRAS_MAP = 2521

-- Start branch of this character (phase 20, KF10): Zephra's Isle when the character stands there
-- or has handed in a Zephra's Isle quest (any race can start there), else the race's branch.
function E.BranchForPlayer(player)
    player = player or K.player or {}
    if K.Compat.GetBestMapForPlayer() == E.ZEPHRAS_MAP then
        return "zephras"
    end
    local zones = K.WorldDB and K.WorldDB.index and K.WorldDB.index.quests
    if zones then
        for q, done in pairs(K.Snapshot and K.Snapshot.completed or {}) do
            if done and zones[q] == E.ZEPHRAS_MAP then
                return "zephras"
            end
        end
    end
    return RACE_BRANCH[player.race] or RACE_BRANCH[player.raceToken]
end

-- ---- Saved choices ----------------------------------------------------------------------------

local function cdb(name)
    K.cdb = K.cdb or {}
    K.cdb[name] = K.cdb[name] or {}
    return K.cdb[name]
end

-- True when the player skipped quest q.
function E.QuestSkipped(q)
    return q ~= nil and K.cdb ~= nil and K.cdb.skipQuests ~= nil and K.cdb.skipQuests[q] == true
end

-- ---- Observers and reads ----------------------------------------------------------------------

local function notify(self)
    for i = 1, #self.observers do
        local ok, err = pcall(self.observers[i], self)
        if not ok then
            K.Log("observer error", tostring(err))
        end
    end
end

-- Registers fn(engine), called after every change of the plan or the cursor.
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

-- Indices of the ACCEPT batch that contains step i: consecutive ACCEPT steps with the same NPC and
-- zone (PRD 7.3, grouped hub loops). Other steps form a batch of one.
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

-- ---- Derivation -------------------------------------------------------------------------------

-- A plan step as the window shows it: the planner's step plus the text fields the cards use.
local function display(step)
    local out = {}
    for k, v in pairs(step) do
        out[k] = v
    end
    if step.t == "V" then
        local zone = K.zones and K.zones[step.to]
        out.n = L.TRAVEL_TO and string.format(L.TRAVEL_TO, zone and zone[1] or "?") or (zone and zone[1]) or ""
        out.note = K.Planner.Why(step)
    elseif step.t == "S" then
        out.n = step.n or step.note
        out.note = step.note
    else
        out.note = K.Planner.Why(step)
    end
    return out
end

-- Rebuilds the visible steps from the planner. Hidden steps are taken out; the cursor is the first.
function E:Recompute()
    local plan = K.Planner and K.Planner:Get()
    self.plan = plan
    local hide = cdb("hiddenSteps")
    local steps, eff, byKey = {}, {}, {}
    for _, s in ipairs((plan and plan.steps) or {}) do
        if not hide[s.k] then
            steps[#steps + 1] = display(s)
            eff[#steps] = "pending"
            byKey[s.k] = #steps
        end
    end
    self.steps, self.eff, self.byKey = steps, eff, byKey
    self.cursor = (#steps > 0) and 1 or nil
    notify(self)
end

-- ---- Start ------------------------------------------------------------------------------------

-- Login entry point: detect the player and build the first plan once the game state is ready.
function E:Start()
    local player = K.Detect()
    if player.faction == "Alliance" then
        K.Print(L.ALLIANCE_SOON)
        K.Log("alliance: no plan in v1")
        return false
    end
    self.routeId = "plan"
    K.cdb.routeId = nil
    self:Recompute()
    return true
end

-- ---- Player actions ---------------------------------------------------------------------------

-- True when the game state says a quest step is not done, so hiding it as "done" would be a lie
-- (phase 22: the step menu asks before hiding such a step).
function E.Contradicts(step)
    local State = K.State
    if not (State and State:Ready() and step and step.q and QUEST_STEP[step.t]) then
        return false
    end
    local qs = State:Get(step.q)
    if qs == "unknown" then
        return false
    end
    if step.t == "A" then
        return qs ~= "active" and qs ~= "objectives-done" and qs ~= "completed"
    elseif step.t == "C" then
        return qs ~= "objectives-done" and qs ~= "completed"
    end
    return qs ~= "completed"
end

local function refreshAfterChoice(self)
    if K.Planner then
        K.Planner.dirty = true
    end
    if K.State and K.State:Ready() then
        K.State:Refresh("choice")
    else
        self:Recompute()
    end
end

-- Skips a whole quest (every step, and the planner), and restores it.
function E:SkipQuest(q)
    if not q then
        return false
    end
    cdb("skipQuests")[q] = true
    refreshAfterChoice(self)
    return true
end

function E:RestoreQuest(q)
    if not q then
        return false
    end
    cdb("skipQuests")[q] = nil
    cdb("brokenQuests")[q] = nil
    local hide = cdb("hiddenSteps")
    for _, kind in ipairs({ "A", "C", "T" }) do
        hide["plan:" .. kind .. ":" .. q] = nil
    end
    refreshAfterChoice(self)
    return true
end

-- Pins the step with key k (nil clears the pin): the planner puts its quest first.
function E:Pin(k)
    if k then
        local i = self.byKey[k]
        local s = i and self.steps[i]
        K.cdb.pin = s and s.q and { k = k, q = s.q } or nil
    else
        K.cdb.pin = nil
    end
    if K.Planner then
        K.Planner.dirty = true
    end
    self:Recompute()
    return K.cdb.pin ~= nil
end

-- Hides the step at index i ("mark done"); for an ACCEPT the whole hub batch goes. Returns how many.
function E:MarkDone(i)
    local s = i and self.steps[i]
    if not s then
        return 0
    end
    local hide = cdb("hiddenSteps")
    local marked = 0
    for _, j in ipairs(self:Batch(i)) do
        hide[self.steps[j].k] = true
        marked = marked + 1
    end
    self:Recompute()
    return marked
end

-- Marks the cursor step done.
function E:Next()
    return self:MarkDone(self.cursor)
end

-- Skips step i (default: the cursor). A plan has no cascades, so it always returns 0.
function E:Skip(i)
    i = i or self.cursor
    local s = i and self.steps[i]
    if not s then
        return 0
    end
    cdb("hiddenSteps")[s.k] = true
    self:Recompute()
    return 0
end

-- Brings a hidden step back by stable key.
function E:Unskip(k)
    local hide = cdb("hiddenSteps")
    if hide[k] then
        hide[k] = nil
        self:Recompute()
        return true
    end
    return false
end

-- Resets choices. scope "band" clears the hidden steps and the pin; "guide" also the quests reported
-- broken and the service memory but keeps every skipped quest ("Reset guide and keep skips"); "all"
-- clears the skipped quests and the old band progress as well.
function E:Reset(scope)
    K.cdb = K.cdb or {}
    K.cdb.hiddenSteps = {}
    K.cdb.pin = nil
    if scope == "guide" or scope == "all" then
        K.cdb.brokenQuests = {}
        K.cdb.visited = {}
        K.cdb.trainedAt = nil
        K.cdb.hideAnswers = {}
    end
    if scope == "all" then
        K.cdb.skipQuests = {}
        K.cdb.stepState = {}
    end
    refreshAfterChoice(self)
    return true
end

-- ---- Events ---------------------------------------------------------------------------------------

-- Every plan change refreshes the visible steps; the planner is lazy, so the state change only marks
-- it dirty and the next read (here) rebuilds it.
if K.Planner then
    K.Planner:OnChange(function()
        if E.routeId and not E.rebuilding then
            E.rebuilding = true
            local plan = K.Planner.plan
            if plan ~= E.plan then
                E:Recompute()
            end
            E.rebuilding = false
        end
    end)
end

if K.State then
    K.State:OnChange(function()
        if E.routeId then
            E:Recompute()
        end
    end)
end

K.On("PLAYER_LEVEL_UP", function(level)
    K.player = K.player or {}
    K.player.level = tonumber(level) or UnitLevel("player") or K.player.level
    if E.routeId then
        E:Recompute()
    end
end)

-- The plan is lazy: movement marks it dirty, and this tick rebuilds it so the window follows.
K.Every(2, function()
    if E.routeId and K.Planner and K.Planner.dirty and K.State and K.State:Ready() then
        E:Recompute()
    end
end)

K.On("PLAYER_LOGIN", function()
    E:Start()
end)
