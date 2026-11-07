-- Planner candidates (phase 21, plan s4.3 step 1): one work packet per quest the character can
-- act on (accept, finish the objectives, hand in), with its positions and value. Pure; mirrored in
-- pipeline/sim/planner.py.
--
-- World interface (W): zoneIds() sorted uiMaps, zoneInfo(m) {lv = {lo, med, hi}}, zoneQuests(m)
-- sorted quest ids, quest(q) record, questZone(q) uiMap, npcPoints(id) / objectPoints(id) lists
-- of {m, x, y}, xpl (estimated base XP per quest level). state(q) -> state, reason (K.State).
-- snap: {level, mapID, x, y, log}.
local _, K = ...
K.Plan = K.Plan or {}

local Ca = {}
K.Plan.Candidates = Ca

local Sc = K.Plan.Score

local INF = math.huge

-- Nearest point of a list of entity ids to pos (same map first, then the lower id). Returns
-- {m, x, y, id, kind} or nil.
local function nearest(W, npcs, objects, pos)
    local best, bestD
    local function consider(points, id, kind)
        for _, p in ipairs(points or {}) do
            local d = (p[1] == pos.m) and Sc.Dist(p[2], p[3], pos.x, pos.y) or INF
            if not best or d < bestD or (d == bestD and (kind < best.kind or (kind == best.kind and id < best.id))) then
                best = { m = p[1], x = p[2], y = p[3], id = id, kind = kind }
                bestD = d
            end
        end
    end
    for _, id in ipairs(npcs or {}) do
        consider(W.npcPoints(id), id, "n")
    end
    for _, id in ipairs(objects or {}) do
        consider(W.objectPoints(id), id, "o")
    end
    return best
end
Ca.Nearest = nearest

-- Objective spots: the first spawn cluster of each placed objective, in record order.
local function objectiveSpots(rec)
    local out = {}
    for _, o in ipairs(rec.o or {}) do
        local at = o.at and o.at[1]
        if at then
            out[#out + 1] = { m = at[1], x = at[2], y = at[3], r = at[4] or 0 }
        end
    end
    return out
end

local function hasFlag(rec, flag)
    for _, f in ipairs(rec.f or {}) do
        if f == flag then
            return true
        end
    end
    return false
end
Ca.HasFlag = hasFlag

-- Maps one step away from m on the travel graph (borders, boats and zeppelins; not flights).
local function neighbours(travel, m)
    local out = {}
    for _, pair in ipairs(travel.adj or {}) do
        if pair[1] == m then
            out[pair[2]] = true
        elseif pair[2] == m then
            out[pair[1]] = true
        end
    end
    for _, link in ipairs(travel.links or {}) do
        if link.m == m then
            out[link.to] = true
        end
    end
    return out
end

-- Zones worth scanning: the zones of quests in the log, and either the current zone and its
-- neighbours in the level band (wide = false) or every zone in the level band (wide = true).
function Ca.Zones(W, snap, wt, wide)
    local level = snap.level or 1
    local want = {}
    local close = neighbours(W.travel or {}, snap.mapID)
    for _, m in ipairs(W.zoneIds()) do
        local info = W.zoneInfo(m)
        local lv = info and info.lv
        local inBand = lv and lv[3] >= level - wt.zoneBelow and lv[1] <= level + wt.levelSlack
        if m == snap.mapID or (inBand and (wide or close[m])) then
            want[m] = true
        end
    end
    for q in pairs(snap.log or {}) do
        local m = W.questZone(q)
        if m then
            want[m] = true
        end
    end
    local out = {}
    for m in pairs(want) do
        out[#out + 1] = m
    end
    table.sort(out)
    return out
end

-- Stage of a quest from its state: "A" (to accept), "C" (objectives to do), "T" (hand in), or nil.
-- Returns stage, locked (true when the quest is waiting for a prerequisite or a level).
function Ca.Stage(state, reason, rec)
    if state == "available" or state == "abandoned" then
        return "A", false
    elseif state == "active" then
        if #(rec.o or {}) == 0 then
            return "T", false
        end
        return "C", false
    elseif state == "objectives-done" then
        return "T", false
    elseif state == "unavailable" and (reason == "prereq" or reason == "level") then
        return "A", true
    end
    return nil
end

-- One packet, or nil when the quest cannot be planned (a position is missing, or it is not worth it).
function Ca.Packet(W, q, rec, stage, locked, snap, wt)
    local pos = { m = snap.mapID, x = snap.x or 50, y = snap.y or 50 }
    local p = {
        q = q, n = rec.n, lv = rec.lv or snap.level, stage = stage, locked = locked or nil,
        pa = rec.pa, po = rec.po, rl = math.max(rec.rl or 1, rec.re or 1),
        xp = rec.xp or (W.xpl and W.xpl[rec.lv or 1]) or 0,
        flags = rec.f, classQuest = rec.cl ~= nil, upgrade = rec.ru ~= nil and #rec.ru > 0,
        chain = rec.nx ~= nil, elite = hasFlag(rec, "elite"),
    }
    if stage == "A" then
        p.giver = nearest(W, rec.sn, rec.so, pos)
        if not p.giver then
            return nil
        end
    end
    local spots = objectiveSpots(rec)
    if stage == "A" or stage == "C" then
        if #(rec.o or {}) > 0 and #spots == 0 then
            return nil
        end
        p.spots = spots
    end
    p.finisher = nearest(W, rec.en, rec.eo, (stage == "T") and pos or (spots[1] or p.giver or pos))
    if not p.finisher then
        return nil
    end
    -- worth it at the level the quest can first be taken
    local level = math.max(snap.level or 1, locked and p.rl or 0)
    local value = Sc.Value(p, level, wt)
    if value <= 0 and stage == "A" then
        return nil
    end
    return p
end

-- Every packet the character can act on, sorted by quest id. The scan starts near the player and
-- widens to the whole level band when fewer than wt.localMin packets are found.
function Ca.Build(W, state, snap, wt)
    local pool = Ca.Collect(W, state, snap, wt, false)
    if #pool < wt.localMin then
        pool = Ca.Collect(W, state, snap, wt, true)
    end
    return pool
end

function Ca.Collect(W, state, snap, wt, wide)
    local pool = {}
    local seen = {}
    for _, m in ipairs(Ca.Zones(W, snap, wt, wide)) do
        for _, q in ipairs(W.zoneQuests(m)) do
            if not seen[q] then
                seen[q] = true
                local rec = W.quest(q)
                local st, reason = state(q)
                local stage, locked = Ca.Stage(st, reason, rec or {})
                if rec and stage then
                    local p = Ca.Packet(W, q, rec, stage, locked, snap, wt)
                    if p then
                        pool[#pool + 1] = p
                    end
                end
            end
        end
    end
    table.sort(pool, function(a, b) return a.q < b.q end)
    return pool
end
