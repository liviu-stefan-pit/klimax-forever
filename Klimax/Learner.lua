-- Calibration of the plan to this player (smart engine research s3.1). Nothing leaves the machine.
--
-- The planner assumes `objective` seconds per quest objective (100 by default). This module measures
-- how long the character really takes: from the moment the player stands at the objective area of a
-- quest in the log until the log says its objectives are done, divided by the number of objectives.
-- Each sample moves a running mean (Weights.LearnUpdate); after a few samples Weights.For puts the
-- clamped mean into the plan, so a fast player gets shorter estimates and a careful one longer.
--   /klimax learn           -> prints learned and default values
--   /klimax learn off | on  -> stops or resumes measuring (the saved mean is kept)
--   /klimax learn reset     -> forgets what was learned
local _, K = ...
local L = K.L

local Ln = {}
K.Learner = Ln

Ln.NEAR = 3.0      -- map-%: "at the objective area"
Ln.MIN = 5         -- seconds per objective below this is not a real sample
Ln.MAX = 600       -- ... and above this the player was away
Ln.TICK = 2.0

-- ---- Pure parts ----------------------------------------------------------------------------------------

-- True when pos {m, x, y} is at the area of an objective (C) step.
function Ln.Arrived(step, pos)
    if not (step and step.t == "C" and step.z and pos and pos.m == step.z) then
        return false
    end
    return K.Plan.Score.Dist(pos.x, pos.y, step.x, step.y) <= Ln.NEAR
end

-- Seconds per objective for one finished quest, or nil when the sample is not usable.
function Ln.PerObjective(elapsed, objectives)
    local per = elapsed / math.max(objectives or 1, 1)
    if per < Ln.MIN or per > Ln.MAX then
        return nil
    end
    return per
end

-- New learned table after one sample (the input is not changed).
function Ln.Observe(learned, per)
    local Wt = K.Plan.Weights
    local out = {}
    for k, v in pairs(learned or {}) do
        out[k] = v
    end
    out.objective = Wt.LearnUpdate(out.objective, per, Wt.DEFAULT.objective)
    return out
end

-- ---- Runtime -----------------------------------------------------------------------------------------

Ln.arrive = {}     -- quest id -> GetTime() when the player reached its objective area

local function now()
    return GetTime and GetTime() or 0
end

local function store()
    K.cdb = K.cdb or {}
    return K.cdb
end

function Ln.Enabled()
    return not store().learnOff
end

-- Notes the quests whose objective area the player stands in (the planner's C steps).
function Ln.Tick()
    local plan = K.Planner and K.Planner.plan
    local snap = K.State and K.State:Ready() and K.State.snap
    if not (plan and snap and Ln.Enabled()) then
        return
    end
    local m = K.Compat.GetBestMapForPlayer()
    local p = m and K.Compat.GetPlayerMapPosition(m)
    if not p then
        return
    end
    local pos = { m = m, x = p.x * 100, y = p.y * 100 }
    for _, step in ipairs(plan.steps) do
        local entry = step.q and snap.log and snap.log[step.q]
        if entry and not entry.complete and Ln.Arrived(step, pos) and not Ln.arrive[step.q] then
            Ln.arrive[step.q] = now()
        end
    end
end

-- A refresh: quests that left the log are forgotten, quests whose objectives are now done give a sample.
function Ln.OnState()
    local snap = K.State and K.State.snap
    if not (snap and snap.log) then
        return
    end
    for q, since in pairs(Ln.arrive) do
        local entry = snap.log[q]
        if not entry then
            Ln.arrive[q] = nil
        elseif entry.complete then
            Ln.arrive[q] = nil
            local rec = K.WorldDB and K.WorldDB.Quest and K.WorldDB.Quest(q)
            local per = Ln.PerObjective(now() - since, rec and rec.o and #rec.o or 1)
            if per and Ln.Enabled() then
                store().learned = Ln.Observe(store().learned, per)
                if K.Planner then
                    K.Planner.dirty = true
                end
            end
        end
    end
end

if K.State and K.State.OnChange then
    K.State:OnChange(Ln.OnState)
end
K.Every(Ln.TICK, Ln.Tick)

-- ---- Command ----------------------------------------------------------------------------------------

function Ln.Command(rest)
    local sub = (rest or ""):match("^%s*(%S*)"):lower()
    if sub == "reset" then
        store().learned = nil
        Ln.arrive = {}
        if K.Planner then
            K.Planner.dirty = true
        end
        K.Print(L.LEARN_RESET)
    elseif sub == "off" or sub == "on" then
        store().learnOff = (sub == "off") or nil
        K.Print(sub == "off" and L.LEARN_OFF or L.LEARN_ON)
    else
        local e = store().learned and store().learned.objective
        local def = K.Plan.Weights.DEFAULT.objective
        if e then
            local used = K.Plan.Weights.ApplyLearned({ objective = def }, store().learned).objective
            K.Print(string.format(L.LEARN_LINE, e.m, e.n, def, used))
        else
            K.Print(string.format(L.LEARN_NONE, def))
        end
    end
end
