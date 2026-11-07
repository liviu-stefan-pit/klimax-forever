-- K.State: the one place that knows the state of every quest (phase 20, plan s4.2).
--
--   K.State:Get(q)        -> state, reason (see State/Reconciler.lua)
--   K.State:Refresh(why)  -> rebuilds the snapshot from the game and notifies observers
--   K.State:OnChange(fn)  -> fn(why) after every refresh
--   K.State:Resync(done)  -> rescans every completed flag (chunked), refreshes, then done()
--
-- Refreshes come from the game: login, QUEST_LOG_UPDATE (throttled), QUEST_ACCEPTED,
-- QUEST_TURNED_IN (the flag cache learns the quest at once), QUEST_REMOVED and level ups.
-- Quest records come from the compiled world (K.WorldDB); a quest outside the compiled zones falls
-- back to what the band routes know about it (prerequisites and required level of its ACCEPT).
local _, K = ...
local Snap = K.Snapshot
local R = K.Reconciler

local St = {}
K.State = St

St.snap = nil
St.ctx = nil
St.observers = {}
St.THROTTLE = 0.5

-- ---- Lookups --------------------------------------------------------------------------------------

local routeMeta -- q -> {pa, po, rl, lv}, built from the band routes once
local eqOf      -- q -> equivalent group (Index.eq)

local function buildRouteMeta()
    routeMeta = {}
    local ids = {}
    for id in pairs(K.routes or {}) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        for _, s in ipairs(K.routes[id].steps or {}) do
            if s.q and s.t == "A" and not routeMeta[s.q] then
                routeMeta[s.q] = { pa = s.pa, po = s.po, rl = s.ml, lv = s.ql }
            end
        end
    end
end

local function buildEq()
    eqOf = {}
    local wi = K.WorldDB and K.WorldDB.index
    for _, group in ipairs((wi and wi.eq) or {}) do
        for _, q in ipairs(group) do
            eqOf[q] = group
        end
    end
end

-- Quest record: the compiled world record, else the route meta, else nil.
function St.Info(q)
    local rec = K.WorldDB and K.WorldDB.Quest and K.WorldDB.Quest(q)
    if rec then
        return rec
    end
    if not routeMeta then
        buildRouteMeta()
    end
    return routeMeta[q]
end

local function exGroup(id)
    local wi = K.WorldDB and K.WorldDB.index
    return wi and wi.ex and wi.ex[id] or nil
end

local function eqGroup(q)
    if not eqOf then
        buildEq()
    end
    return eqOf[q]
end

local function knownSet()
    if not St.universe then
        St.universe = {}
        for _, id in ipairs(Snap.QuestIds()) do
            St.universe[id] = true
        end
    end
    return St.universe
end

-- Quests the legacy guide believes accepted: an ACCEPT step stored as done in any band.
local function believedSet()
    local out = {}
    for _, states in pairs((K.cdb and K.cdb.stepState) or {}) do
        for key, v in pairs(states) do
            if v == "done" then
                local q = key:match(":A:(%d+):")
                if q then
                    out[tonumber(q)] = true
                end
            end
        end
    end
    return out
end

-- ---- Context ----------------------------------------------------------------------------------------

-- A reconciler context for a snapshot (exposed for specs and the planner).
function St.Context(snap)
    local believed = believedSet()
    local known = knownSet()
    return R.New(snap, {
        info = St.Info,
        exGroup = exGroup,
        eqGroup = eqGroup,
        known = function(q) return known[q] == true end,
        believed = function(q) return believed[q] == true end,
    })
end

-- ---- Reads ---------------------------------------------------------------------------------------------

function St:Ready()
    return self.ctx ~= nil
end

-- State and reason of quest q. Before the first refresh: nil.
function St:Get(q)
    if not self.ctx or not q then
        return nil
    end
    return R.State(self.ctx, q)
end

function St:OnChange(fn)
    self.observers[#self.observers + 1] = fn
end

local function notify(why)
    for _, fn in ipairs(St.observers) do
        local ok, err = pcall(fn, why)
        if not ok then
            K.Log("state observer error", tostring(err))
        end
    end
end

-- ---- Refresh ---------------------------------------------------------------------------------------

function St:Refresh(why)
    self.snap = Snap.Build()
    self.ctx = St.Context(self.snap)
    notify(why or "refresh")
    return self.snap
end

-- Rescans every completed flag (chunked across frames), then refreshes. onDone(snap) runs after.
function St:Resync(onDone)
    St.universe = nil
    routeMeta = nil
    eqOf = nil
    Snap.ScanCompleted(function()
        St:Refresh("resync")
        if onDone then
            onDone(St.snap)
        end
    end)
end

-- ---- Events ----------------------------------------------------------------------------------------

local queued = false
local function queueRefresh(why)
    if queued then
        return
    end
    queued = true
    C_Timer.After(St.THROTTLE, function()
        queued = false
        St:Refresh(why)
    end)
end
St.QueueRefresh = queueRefresh

K.On("PLAYER_LOGIN", function()
    if K.Detect then
        K.Detect()
    end
    St:Refresh("login")
    Snap.ScanCompleted(function()
        St:Refresh("scan")
    end)
end)

-- Our own header expand/collapse fires QUEST_LOG_UPDATE too; those echoes are ignored for a
-- moment, or a log with collapsed headers would refresh itself forever.
St.ECHO = 1.0
K.On("QUEST_LOG_UPDATE", function()
    local C = K.Compat
    if C.expanding then
        return
    end
    if C.lastExpand and GetTime and GetTime() - C.lastExpand < St.ECHO then
        return
    end
    queueRefresh("questlog")
end)

K.On("QUEST_ACCEPTED", function()
    queueRefresh("accepted")
end)

K.On("QUEST_REMOVED", function()
    queueRefresh("removed")
end)

K.On("QUEST_TURNED_IN", function(questID)
    Snap.MarkCompleted(questID)
    St:Refresh("turnedin")
end)

K.On("PLAYER_LEVEL_UP", function(level)
    K.player = K.player or {}
    K.player.level = tonumber(level) or K.player.level
    St:Refresh("level")
end)
