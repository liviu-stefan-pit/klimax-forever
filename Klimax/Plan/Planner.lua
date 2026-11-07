-- K.Planner: the dynamic plan (phase 21, plan s4.3). Builds the next steps from the compiled world
-- (K.WorldDB) and the game state (K.State), keeps them stable between changes, and explains them.
--
--   K.Planner:Get()        -> plan {steps, built, level, ms} (rebuilt when dirty)
--   K.Planner:Replan(why)  -> builds a new plan now, keeping the first step unless the new one is
--                             clearly better (Weights.stable) or the first step is locked
--   K.Planner.Why(step)    -> one line explaining a step; /klimax why [n] prints the breakdown
--   /klimax plan           -> prints the next steps
--
-- The plan is lazy: state changes and movement only mark it dirty, so it costs nothing until the
-- UI (phases 22 and 27) or a command asks for it.
local _, K = ...
local L = K.L
K.Plan = K.Plan or {}

local P = {}
K.Planner = P

local Ca, Sq, Tr, Wt = K.Plan.Candidates, K.Plan.Sequence, K.Plan.Transitions, K.Plan.Weights

P.plan = nil
P.dirty = true
P.MOVE_REPLAN = 4.0  -- map-%: moving this far since the last plan marks it dirty
P.observers = {}

-- ---- World adapter over K.WorldDB -------------------------------------------------------------

local zoneQuestCache = {}

function P.World()
    local DB = K.WorldDB
    local index = DB and DB.index or {}
    local W = {}
    function W.zoneIds()
        return DB and DB.ZoneIds() or {}
    end
    function W.zoneInfo(m)
        return index.zones and index.zones[m]
    end
    function W.zoneQuests(m)
        local list = zoneQuestCache[m]
        if not list then
            list = {}
            local zone = DB.Zone(m)
            for q in pairs((zone and zone.quests) or {}) do
                list[#list + 1] = q
            end
            table.sort(list)
            zoneQuestCache[m] = list
        end
        return list
    end
    function W.quest(q)
        return DB.Quest(q)
    end
    function W.questZone(q)
        return index.quests and index.quests[q]
    end
    function W.npcPoints(id)
        local n = DB.Npc(id)
        return n and n.p
    end
    function W.objectPoints(id)
        local o = DB.Object(id)
        return o and o.p
    end
    W.xpl = index.xpl
    W.travel = DB and DB.travel or {}
    return W
end

-- ---- Building -------------------------------------------------------------------------------------

local function profile()
    if K.Profile then
        return K.Profile.Get()
    end
    return (K.cdb and K.cdb.profile) or {}
end

-- Pure build: a plan for a world, a state function, a snapshot and weights. first: quest id whose
-- next task is forced first (stability). Exposed for specs and the vectors.
function P.Build(W, state, snap, wt, first)
    local pool = Ca.Build(W, state, snap, wt)
    local path = Tr.Cache(W.travel, wt)
    local function isDone(q)
        return state(q) == "completed"
    end
    return Sq.Run(pool, snap, wt, path, isDone, first), pool
end

local function clock()
    if debugprofilestop then
        return debugprofilestop()
    end
    return os.clock() * 1000
end

local function stateFn()
    return function(q)
        return K.State:Get(q)
    end
end

-- True when the current first step must not change: in combat, or working on its objectives.
function P.Locked(step, snap)
    if not step then
        return false
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        return true
    end
    if step.t == "C" and snap.mapID == step.z and snap.x then
        local d = K.Plan.Score.Dist(snap.x, snap.y, step.x, step.y)
        return d <= P.MOVE_REPLAN * 2
    end
    return false
end

function P:Replan(why)
    if not (K.State and K.State:Ready() and K.WorldDB and K.WorldDB.index) then
        return nil
    end
    local t0 = clock()
    local snap = K.State.snap
    local wt = Wt.For(profile(), snap.class)
    local W = P.World()
    local state = stateFn()
    local pin = K.cdb and K.cdb.pin
    local pinned = pin and pin.q and state(pin.q) ~= "completed" and pin.q or nil
    local steps = P.Build(W, state, snap, wt, pinned)
    -- Stability: keep the old first step unless the new one beats it clearly, or it is locked.
    local old = self.plan and self.plan.steps[1]
    local new = steps[1]
    if not pinned and old and new and old.k ~= new.k and old.q and old.t ~= "V" then
        local keep = P.Locked(old, snap)
        if not keep then
            local forced = P.Build(W, state, snap, wt, old.q)
            local f1 = forced[1]
            if f1 and f1.k == old.k and (new.score or 0) < (f1.score or 0) * wt.stable then
                keep = true
            end
            if keep and f1 and f1.k == old.k then
                steps = forced
            end
        elseif K.State:Get(old.q) ~= "completed" then
            steps = P.Build(W, state, snap, wt, old.q)
        end
    end
    self.plan = { steps = steps, built = why or "replan", level = snap.level, ms = clock() - t0,
        at = { m = snap.mapID, x = snap.x, y = snap.y } }
    self.dirty = false
    for _, fn in ipairs(self.observers) do
        pcall(fn, self.plan)
    end
    return self.plan
end

function P:Get()
    if self.dirty or not self.plan then
        self:Replan("get")
    end
    return self.plan
end

function P:OnChange(fn)
    self.observers[#self.observers + 1] = fn
end

-- ---- Explanations -----------------------------------------------------------------------------------

local KIND = { A = "PLAN_ACCEPT", C = "PLAN_COMPLETE", T = "PLAN_TURNIN", V = "PLAN_TRAVEL" }

local function yards(seconds, wt)
    return math.floor(seconds / wt.speed * 10 + 0.5)
end

-- One line: what to do and why it is here.
function P.Why(step)
    local wt = Wt.DEFAULT
    local w = step.why or {}
    if step.t == "V" then
        return string.format(L.PLAN_WHY_TRAVEL, L["PLAN_VIA_" .. (w.via or "walk")] or w.via or "")
    end
    local parts = {}
    if step.t == "T" then
        parts[#parts + 1] = L.PLAN_WHY_READY
    elseif step.t == "C" then
        parts[#parts + 1] = L.PLAN_WHY_INLOG
    end
    if w.colour then
        parts[#parts + 1] = L["PLAN_COLOUR_" .. w.colour] or w.colour
    end
    if w.xp then
        parts[#parts + 1] = string.format(L.PLAN_WHY_XP, w.xp)
    end
    if w.here then
        parts[#parts + 1] = L.PLAN_WHY_NEAR
    elseif w.travel then
        parts[#parts + 1] = string.format(L.PLAN_WHY_AWAY, yards(w.travel, wt))
    end
    if w.leave then
        parts[#parts + 1] = L.PLAN_WHY_LEAVE
    end
    return table.concat(parts, ", ")
end

-- Lines of the score breakdown of a step (for /klimax why).
function P.Breakdown(step)
    local w = step.why or {}
    local lines = { string.format(L.PLAN_WHY_HEAD, L[KIND[step.t]] or step.t, step.n or "", step.q or 0, P.Why(step)) }
    if step.t ~= "V" then
        lines[#lines + 1] = string.format(L.PLAN_WHY_TERMS, w.xp or 0, w.colour or "?", w.risk or 1, w.class or 1,
            w.upgrade or 1, w.chain or 1, w.value or 0)
        lines[#lines + 1] = string.format(L.PLAN_WHY_COST, w.obligation or 1, w.travel or 0, w.time or 0,
            w.rest or 0, w.score or 0)
    end
    return lines
end

-- ---- Commands ---------------------------------------------------------------------------------------

function P.PrintPlan(n)
    local plan = P:Get()
    if not plan or #plan.steps == 0 then
        K.Print(L.PLAN_EMPTY)
        return
    end
    K.Print(string.format(L.PLAN_HEAD, #plan.steps, plan.ms or 0))
    for i = 1, math.min(n or 10, #plan.steps) do
        local s = plan.steps[i]
        K.Print(string.format("%d. %s %s - %s", i, L[KIND[s.t]] or s.t, s.n or (K.zones and K.zones[s.to]
            and K.zones[s.to][1]) or "", P.Why(s)))
    end
end

function P.PrintWhy(n)
    local plan = P:Get()
    local step = plan and plan.steps[tonumber(n) or 1]
    if not step then
        K.Print(L.PLAN_EMPTY)
        return
    end
    for _, line in ipairs(P.Breakdown(step)) do
        K.Print(line)
    end
end

-- ---- Events -----------------------------------------------------------------------------------------

local function markDirty()
    P.dirty = true
end

if K.State then
    K.State:OnChange(markDirty)
end

K.Every(2, function()
    local plan = P.plan
    if not plan or P.dirty then
        return
    end
    local mapID = K.Compat.GetBestMapForPlayer()
    local pos = mapID and K.Compat.GetPlayerMapPosition(mapID)
    if not pos then
        return
    end
    local at = plan.at
    if mapID ~= at.m or not at.x or K.Plan.Score.Dist(pos.x * 100, pos.y * 100, at.x, at.y) > P.MOVE_REPLAN then
        if K.State and K.State:Ready() then
            K.State.snap.mapID, K.State.snap.x, K.State.snap.y = mapID, pos.x * 100, pos.y * 100
        end
        P.dirty = true
    end
end)
