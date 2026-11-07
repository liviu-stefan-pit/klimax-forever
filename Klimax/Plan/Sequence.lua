-- Planner sequencing (phase 21, plan s4.3 step 3). Greedy best score over the packets' next tasks
-- from a simulated position, level and XP, then an adjacent-swap pass that shortens the walk.
-- Pure and deterministic (fixed tie-breakers); mirrored in pipeline/sim/planner.py.
--
-- A packet's tasks run in order: A (accept at the giver), C (objectives, one stop at the first
-- spot, the walk through the other spots counted in its time), T (hand in at the finisher).
-- Score of a task = quest value x obligation / (travel to the task + the task + the rest of the
-- quest), divided by leaveZone when the task is in another zone, times nearBonus when it is a
-- pickup within `near` map-% of the current position. Two rules shape the flow:
--   * stop first: accepts and turn-ins within `here` map-% are taken before anything else
--     (the whole hub is picked up or handed in at once);
--   * turn in on the way back: a turn-in waits while an open objective on the same map is closer
--     than its NPC.
local _, K = ...
K.Plan = K.Plan or {}

local Sq = {}
K.Plan.Sequence = Sq

local Sc = K.Plan.Score
local Wt = K.Plan.Weights

Sq.KIND_ORDER = { T = 1, C = 2, A = 3 }

-- Cost in seconds between two points {m, x, y}: walking on one map, the travel graph otherwise.
-- Returns cost, edge (the first hop when the maps differ) or nil when unreachable.
local function between(a, b, wt, path)
    if a.m == b.m then
        return Sc.Dist(a.x, a.y, b.x, b.y) * wt.speed
    end
    local cost, edge = path(a.m, b.m)
    if not cost then
        return nil
    end
    return cost, edge
end
Sq.Between = between

local function spotsTime(p, wt, path)
    local spots = p.spots or {}
    local t = #spots * wt.objective * (p.elite and wt.eliteObjective or 1)
    for i = 2, #spots do
        t = t + (between(spots[i - 1], spots[i], wt, path) or wt.unreachable)
    end
    return t
end

-- The task of packet p at stage st: {kind, m, x, y, id, idKind, time}.
local function taskOf(p, st, wt, path)
    if st == "A" then
        local g = p.giver
        return { kind = "A", m = g.m, x = g.x, y = g.y, id = g.id, idKind = g.kind, time = wt.accept }
    elseif st == "C" then
        local s = p.spots[1]
        return { kind = "C", m = s.m, x = s.x, y = s.y, time = spotsTime(p, wt, path) }
    end
    local f = p.finisher
    return { kind = "T", m = f.m, x = f.x, y = f.y, id = f.id, idKind = f.kind, time = wt.turnin }
end

-- Seconds of the packet's stages after stage st (walks between its points included).
local function restOf(p, st, wt, path)
    local f = p.finisher
    if st == "T" then
        return 0
    end
    local spots = p.spots or {}
    if st == "C" then
        local last = spots[#spots]
        return (between(last, f, wt, path) or wt.unreachable) + wt.turnin
    end
    -- st == "A"
    if #spots == 0 then
        return (between(p.giver, f, wt, path) or wt.unreachable) + wt.turnin
    end
    return (between(p.giver, spots[1], wt, path) or wt.unreachable) + spotsTime(p, wt, path)
        + (between(spots[#spots], f, wt, path) or wt.unreachable) + wt.turnin
end

local function nextStage(p, st)
    if st == "A" then
        return (#(p.spots or {}) > 0) and "C" or "T"
    elseif st == "C" then
        return "T"
    end
    return "done"
end

-- A locked packet opens when the simulated level reaches its required level and its prerequisites
-- are done (all of pa, any of po). isDone(q) answers for the real game state.
local function unlocked(p, sim, isDone)
    if sim.level < (p.rl or 1) then
        return false
    end
    local function done(q)
        return sim.done[q] or isDone(q)
    end
    for _, q in ipairs(p.pa or {}) do
        if not done(q) then
            return false
        end
    end
    if p.po and #p.po > 0 then
        for _, q in ipairs(p.po) do
            if done(q) then
                return true
            end
        end
        return false
    end
    return true
end
Sq.Unlocked = unlocked

-- True when candidate a beats b.
local function better(a, b)
    if not b then
        return true
    end
    if math.abs(a.score - b.score) > 1e-9 * math.max(1, math.abs(b.score)) then
        return a.score > b.score
    end
    if math.abs(a.travel - b.travel) > 1e-9 then
        return a.travel < b.travel
    end
    if a.task.kind ~= b.task.kind then
        return Sq.KIND_ORDER[a.task.kind] < Sq.KIND_ORDER[b.task.kind]
    end
    return a.p.q < b.p.q
end

-- Per-packet constants for one run: the task and the rest of the quest for each stage, and the
-- value per simulated level (memoised).
local function prepare(pool, wt, path)
    local cache = {}
    for i, p in ipairs(pool) do
        local c = { task = {}, rest = {}, value = {} }
        for _, st in ipairs({ "A", "C", "T" }) do
            local ok = (st == "A" and p.giver) or (st == "C" and p.spots and p.spots[1]) or (st == "T")
            if ok then
                c.task[st] = taskOf(p, st, wt, path)
                c.rest[st] = restOf(p, st, wt, path)
            end
        end
        cache[i] = c
    end
    return cache
end

local function valueAt(c, p, level, wt)
    local v = c.value[level]
    if not v then
        local value, terms = Sc.Value(p, level, wt)
        v = { value, terms }
        c.value[level] = v
    end
    return v[1], v[2]
end

-- Scores every open task from the simulated state. Returns the best candidate or nil.
function Sq.Best(pool, stages, sim, wt, path, isDone, cache)
    cache = cache or prepare(pool, wt, path)
    local open = {}
    local nearestC
    for i, p in ipairs(pool) do
        local st = stages[i]
        if st ~= "done" and (not p.locked or sim.open[i] or unlocked(p, sim, isDone)) then
            local task = cache[i].task[st]
            open[#open + 1] = { i = i, p = p, st = st, task = task }
            if st == "C" and task.m == sim.m then
                local d = Sc.Dist(sim.x, sim.y, task.x, task.y)
                if not nearestC or d < nearestC then
                    nearestC = d
                end
            end
        end
    end
    local best, bestHere
    for _, o in ipairs(open) do
        local i, p, st, task = o.i, o.p, o.st, o.task
        local d = (task.m == sim.m) and Sc.Dist(sim.x, sim.y, task.x, task.y) or nil
        local here = d ~= nil and d <= wt.here and st ~= "C"
        local deferred = st == "T" and not here and nearestC ~= nil and (d == nil or nearestC < d)
        if not deferred then
            local travel, edge = between(sim, task, wt, path)
            if travel then
                local value, terms = valueAt(cache[i], p, sim.level, wt)
                local obligation = Sc.Obligation(st, wt)
                if value > 0 then
                    local rest = cache[i].rest[st]
                    local cost = math.max(travel + task.time + rest, wt.minCost)
                    local score = value * obligation / cost
                    local leave, near = false, false
                    if task.m ~= sim.m then
                        score = score / wt.leaveZone
                        leave = true
                    elseif Sc.Dist(sim.x, sim.y, task.x, task.y) <= wt.near then
                        score = score * wt.nearBonus
                        near = true
                    end
                    local c = { i = i, p = p, task = task, travel = travel, edge = edge, score = score,
                        why = { value = value, obligation = obligation, travel = travel, time = task.time,
                            rest = rest, cost = cost, leave = leave, near = near, here = here or nil,
                            xp = terms.xp, colour = terms.colour, risk = terms.risk, class = terms.class,
                            upgrade = terms.upgrade, chain = terms.chain, score = score } }
                    if here then
                        if better(c, bestHere) then
                            bestHere = c
                        end
                    elseif better(c, best) then
                        best = c
                    end
                end
            end
        end
    end
    return bestHere or best
end

local function levelUp(sim)
    while sim.level < 60 and Wt.LEVEL_XP[sim.level] and sim.xp >= Wt.LEVEL_XP[sim.level] do
        sim.xp = sim.xp - Wt.LEVEL_XP[sim.level]
        sim.level = sim.level + 1
    end
end

-- Plan steps from pool. snap: {level, xp, mapID, x, y}. path: Transitions.Cache. isDone(q): the
-- game state says q is handed in. first: optional quest id whose next task must come first (plan
-- stability). Returns the step list.
function Sq.Run(pool, snap, wt, path, isDone, first)
    isDone = isDone or function() return false end
    local sim = { m = snap.mapID, x = snap.x or 50, y = snap.y or 50, level = snap.level or 1,
        xp = snap.xp or 0, done = {}, open = {} }
    local stages = {}
    for i, p in ipairs(pool) do
        stages[i] = p.stage
    end
    local cache = prepare(pool, wt, path)
    local steps = {}
    while #steps < wt.lookahead do
        local best
        if first then
            for i, p in ipairs(pool) do
                if p.q == first and stages[i] ~= "done" then
                    local only = { p }
                    local c = Sq.Best(only, { stages[i] }, sim, wt, path, isDone, { cache[i] })
                    if c then
                        c.i = i
                        best = c
                    end
                end
            end
            first = nil
        end
        best = best or Sq.Best(pool, stages, sim, wt, path, isDone, cache)
        if not best then
            break
        end
        local p, task = best.p, best.task
        if task.m ~= sim.m then
            local e = best.edge or {}
            steps[#steps + 1] = { t = "V", k = "plan:V:" .. task.m .. ":" .. p.q, z = (e.x and sim.m) or task.m,
                x = e.x or task.x, y = e.y or task.y, to = task.m, via = e.via or "walk", q = p.q,
                el = sim.level, why = { travel = best.travel, via = e.via or "walk", to = task.m } }
            if #steps >= wt.lookahead then
                break
            end
        end
        local step = { t = task.kind, k = "plan:" .. task.kind .. ":" .. p.q, q = p.q, n = p.n, z = task.m,
            x = task.x, y = task.y, el = sim.level, score = best.score, why = best.why }
        if task.idKind == "n" then
            step.npc = task.id
        elseif task.idKind == "o" then
            step.obj = task.id
        end
        steps[#steps + 1] = step
        sim.m, sim.x, sim.y = task.m, task.x, task.y
        if p.locked then
            sim.open[best.i] = true
        end
        stages[best.i] = nextStage(p, stages[best.i])
        if stages[best.i] == "done" then
            sim.done[p.q] = true
            sim.xp = sim.xp + Sc.XpAt(p.xp or 0, p.lv or sim.level, sim.level)
            levelUp(sim)
        end
    end
    return Sq.Improve(steps, snap, wt, path)
end

-- Adjacent-swap improvement: two neighbouring steps of different quests on the same map trade
-- places when that shortens the walk, unless the second depends on the first (an accept after
-- the turn-in of its prerequisite). Up to wt.improvePasses passes.
function Sq.Improve(steps, snap, wt, path)
    local start = { m = snap.mapID, x = snap.x or 50, y = snap.y or 50 }
    local function pt(i)
        if i < 1 then
            return start
        end
        local s = steps[i]
        return { m = s.z, x = s.x, y = s.y }
    end
    local function leg(a, b)
        return between(a, b, wt, path) or wt.unreachable
    end
    for _ = 1, wt.improvePasses do
        local changed = false
        for i = 1, #steps - 1 do
            local a, b = steps[i], steps[i + 1]
            local movable = a.t ~= "V" and b.t ~= "V" and a.q ~= b.q and a.z == b.z
                and not (a.t == "T" and b.t == "A")
            if movable then
                local prev, nxt = pt(i - 1), steps[i + 2] and pt(i + 2) or nil
                local pa, pb = pt(i), pt(i + 1)
                local now = leg(prev, pa) + leg(pa, pb) + (nxt and leg(pb, nxt) or 0)
                local swapped = leg(prev, pb) + leg(pb, pa) + (nxt and leg(pa, nxt) or 0)
                if swapped < now - 1e-9 then
                    steps[i], steps[i + 1] = b, a
                    changed = true
                end
            end
        end
        if not changed then
            break
        end
    end
    return steps
end
