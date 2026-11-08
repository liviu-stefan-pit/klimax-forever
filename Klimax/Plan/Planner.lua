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
    function W.npc(id)
        return DB.Npc(id)
    end
    function W.zoneServices(m)
        local zone = DB.Zone(m)
        return zone and zone.services
    end
    function W.zoneHubs(m)
        local zone = DB.Zone(m)
        return zone and zone.hubs
    end
    function W.objectPoints(id)
        local o = DB.Object(id)
        return o and o.p
    end
    W.xpl = index.xpl
    W.travel = DB and DB.travel or {}
    -- Phase 24 gear advisor: a reward that is an upgrade for this character right now.
    function W.upgrade(_, rec)
        return P.RewardUpgrade(rec)
    end
    return W
end

-- Upgrade cache: item id -> true/false for the current level and gear (cleared on changes). An item
-- the client has not cached yet counts as no upgrade until it is.
P.upgradeCache = {}
function P.RewardUpgrade(rec)
    if not (rec and rec.rw and K.Rewards and K.Rewards.Useful) then
        return false
    end
    local p = K.player or {}
    for _, item in ipairs(rec.rw) do
        local known = P.upgradeCache[item]
        if known == nil then
            local ok, useful = pcall(K.Rewards.Useful, item, p.class, p.level or 1, 99)
            known = ok and useful and true or false
            local data = K.Rewards and K.Rewards.ReadItem and K.Rewards.ReadItem(item)
            if data then
                P.upgradeCache[item] = known
            end
        end
        if known then
            return true
        end
    end
    return false
end

local function clearUpgrades()
    P.upgradeCache = {}
    P.dirty = true
end
K.On("PLAYER_EQUIPMENT_CHANGED", clearUpgrades)
K.On("PLAYER_LEVEL_UP", clearUpgrades)

-- ---- Building -------------------------------------------------------------------------------------

local function profile()
    if K.Profile then
        return K.Profile.Get()
    end
    return (K.cdb and K.cdb.profile) or {}
end

-- The curated spine (phase 25) for one branch: the rows of its zones and the shared factors, or nil
-- when the world has no spine or the branch is unknown. Pure.
function P.SpineFor(spine, branch)
    local rows = spine and branch and spine.branches and spine.branches[branch]
    if not rows then
        return nil
    end
    return { rows = rows, on = spine.onPath, off = spine.offPath, boost = spine.boost,
        dungeons = spine.dungeons, window = spine.dungeonWindow }
end

-- Pure build: a plan for a world, a state function, a snapshot and weights. first: quest id whose
-- next task is forced first (stability). Exposed for specs and the vectors.
function P.Build(W, state, snap, wt, first)
    local pool = Ca.Build(W, state, snap, wt)
    local path = Tr.Cache(W.travel, wt)
    local function isDone(q)
        return state(q) == "completed"
    end
    local steps = Sq.Run(pool, snap, wt, path, isDone, first)
    if #steps == 0 then
        -- nothing doable near the player: look at every zone in the level band (phase 26)
        local wide = Ca.Collect(W, state, snap, wt, true)
        if #wide > #pool then
            pool = wide
            steps = Sq.Run(pool, snap, wt, path, isDone, first)
        end
    end
    return steps, pool
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
    local branch = K.Engine and K.Engine.BranchForPlayer and K.Engine.BranchForPlayer(K.player)
    wt.spine = P.SpineFor(K.WorldDB.index.spine, branch)
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
    -- Phase 23: service stops (repair, sell, supplies, trainers, flight paths, hearth, hints).
    if K.Services and K.Services.Apply then
        local from = { m = snap.mapID, x = snap.x or 50, y = snap.y or 50 }
        local ok, res = pcall(K.Services.Apply, steps, K.Services.Read(), W, wt,
            K.Plan.Transitions.Cache(W.travel, wt), from, profile())
        if ok then
            steps = res
        else
            K.Log("services failed", tostring(res))
        end
    end
    local previous = self.plan
    self.plan = { steps = steps, built = why or "replan", level = snap.level, ms = clock() - t0,
        at = { m = snap.mapID, x = snap.x, y = snap.y } }
    if previous then
        pcall(P.NoteReplan, previous, self.plan)
    end
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

local KIND = { A = "PLAN_ACCEPT", C = "PLAN_COMPLETE", T = "PLAN_TURNIN", V = "PLAN_TRAVEL", S = "PLAN_SERVICE" }

local function yards(seconds, wt)
    return math.floor(seconds / wt.speed * 10 + 0.5)
end

-- One line: what to do and why it is here.
function P.Why(step)
    local wt = Wt.DEFAULT
    local w = step.why or {}
    if step.t == "S" then
        return step.note or ""
    end
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
    if w.spine and w.spine > 1 then
        parts[#parts + 1] = L.PLAN_WHY_ONROUTE
    elseif w.spine and w.spine < 1 then
        parts[#parts + 1] = L.PLAN_WHY_OFFROUTE
    end
    return table.concat(parts, ", ")
end

-- Lines of the score breakdown of a step (for /klimax why).
function P.Breakdown(step)
    local w = step.why or {}
    local lines = { string.format(L.PLAN_WHY_HEAD, L[KIND[step.t]] or step.t, step.n or "", step.q or 0, P.Why(step)) }
    if step.t == "S" then
        lines[#lines + 1] = string.format(L.PLAN_WHY_SERVICE, w.urgency or 0, w.detour or 0)
    elseif step.t ~= "V" then
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

-- ---- Phase 27: forecast, "why not" and replan notes -------------------------------------------------

local Ex = K.Plan.Explain

-- The environment the pure explain functions read: locale, names, quest state and the plan.
function P.ExplainEnv()
    local W = P.World()
    local snap = K.State and K.State.snap or {}
    local wt = Wt.For(profile(), snap.class)
    local branch = K.Engine and K.Engine.BranchForPlayer and K.Engine.BranchForPlayer(K.player)
    wt.spine = K.WorldDB and K.WorldDB.index and P.SpineFor(K.WorldDB.index.spine, branch) or nil
    return {
        L = L, W = W, snap = snap, wt = wt, plan = P.plan,
        zoneName = function(m)
            local zone = K.zones and K.zones[m]
            return zone and zone[1] or nil
        end,
        hubs = W.zoneHubs,
        state = function(q)
            if K.State and K.State.Get then
                return K.State:Get(q)
            end
            return nil
        end,
        rec = W.quest,
    }
end

function P.PrintForecast()
    local plan = P:Get()
    if not plan or #plan.steps == 0 then
        K.Print(L.VIEW_EMPTY)
        return
    end
    local env = P.ExplainEnv()
    for _, line in ipairs(Ex.ForecastLines(Ex.Forecast(plan, env), env)) do
        K.Print(line)
    end
end

-- Quest ids matching a user's text: the number itself, or compiled quests whose name contains it.
function P.FindQuests(text, limit)
    local id = tonumber(text)
    if id then
        return { id }
    end
    local needle = (text or ""):lower()
    local out = {}
    if needle == "" or not K.WorldDB then
        return out
    end
    for _, m in ipairs(K.WorldDB.ZoneIds()) do
        for _, q in ipairs(P.World().zoneQuests(m)) do
            local rec = K.WorldDB.Quest(q)
            if rec and rec.n and rec.n:lower():find(needle, 1, true) then
                out[#out + 1] = q
            end
        end
    end
    table.sort(out)
    while limit and #out > limit do
        table.remove(out)
    end
    return out
end

function P.PrintWhyNot(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then
        K.Print(L.WHYNOT_USAGE)
        return
    end
    if not (K.State and K.State:Ready()) then
        K.Print(L.PLAN_EMPTY)
        return
    end
    P:Get()
    local found = P.FindQuests(text, 6)
    if #found == 0 then
        K.Print(string.format(L.WHYNOT_NONE, text))
        return
    end
    local env = P.ExplainEnv()
    if #found > 1 then
        K.Print(string.format(L.WHYNOT_MANY, #found, text, #found))
    end
    for _, q in ipairs(found) do
        for _, line in ipairs(Ex.WhyNot(q, env)) do
            K.Print(line)
        end
    end
end

-- Replan toast: only for moves worth telling (a new zone for good, an urgent stop first).
P.lastToast = nil
function P.NoteReplan(old, new)
    if K.Option and K.Option("toasts") == false then
        return nil
    end
    local text = Ex.ReplanNote(old, new, P.ExplainEnv())
    if text and text ~= P.lastToast and K.Toast and K.Toast.Show then
        P.lastToast = text
        K.Toast.Show(text, 8)
    end
    return text
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
