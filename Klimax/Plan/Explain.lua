-- Plan explanations (phase 27, DYNAMIC_GUIDE_PLAN s4.3 and s8): everything a tester needs to answer
-- "why is it sending me here?" from the add-on alone. All functions are pure over plain tables, so
-- the specs run them without a client.
--
--   Ex.Forecast(plan, env)        -> {segments = {...}, changes = {...}}: the next stops by zone and hub
--   Ex.WhyNot(q, env)             -> list of lines: why quest q is hidden, or where it sits in the plan
--   Ex.ReplanNote(old, new, env)  -> toast text for the interesting replans only, or nil
--   Ex.Tip(step, env)             -> tooltip lines for a step card
--
-- env: {L = locale table, zoneName(m) -> string, hubs(m) -> hub list, W = planner world adapter,
--       state(q) -> state, reason, rec(q) -> quest record, snap, wt, plan}.
local _, K = ...
K.Plan = K.Plan or {}

local Ex = {}
K.Plan.Explain = Ex

local KIND = { A = "PLAN_ACCEPT", C = "PLAN_COMPLETE", T = "PLAN_TURNIN", V = "PLAN_TRAVEL", S = "PLAN_SERVICE" }
Ex.KIND = KIND

local function zoneName(env, m)
    local name = env.zoneName and env.zoneName(m)
    return name or ("map " .. tostring(m))
end

-- Name of the hub nearest to (x, y) in zone m, or nil. Only hubs of the compiled world have names.
local function hubName(env, m, x, y)
    local hubs = env.hubs and env.hubs(m)
    local best, bestD
    for _, hub in ipairs(hubs or {}) do
        if hub.name and hub.x and x then
            local dx, dy = hub.x - x, hub.y - y
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then
                best, bestD = hub, d
            end
        end
    end
    -- a hub counts as "the place" only when the step is inside or just outside its radius
    if best and bestD and bestD <= ((best.r or 0) + 6) ^ 2 then
        return best.name
    end
    return nil
end

-- ---- Forecast -------------------------------------------------------------------------------------

-- The plan as stops: consecutive steps in one zone and hub make one stop. A stop lists the kinds of
-- work (accepts, objectives, hand-ins) and the quests. changes lists the zone changes with the
-- step number where each happens.
function Ex.Forecast(plan, env)
    local out = { segments = {}, changes = {} }
    if not plan or not plan.steps then
        return out
    end
    local last
    for i, s in ipairs(plan.steps) do
        if s.t == "V" then
            if s.to then
                out.changes[#out.changes + 1] = { at = i, from = last and last.m or nil, to = s.to,
                    via = (s.why and s.why.via) or s.via or "walk" }
            end
        else
            local m = s.z
            local hub = m and hubName(env, m, s.x, s.y) or nil
            if not last or last.m ~= m or last.hub ~= hub then
                last = { m = m, hub = hub, first = i, counts = { A = 0, C = 0, T = 0, S = 0 }, quests = {} }
                out.segments[#out.segments + 1] = last
            end
            last.counts[s.t] = (last.counts[s.t] or 0) + 1
            last.last = i
            if s.n and s.q then
                last.quests[#last.quests + 1] = s.n
            end
        end
    end
    return out
end

-- One printable line per stop: "steps 1-4: Splintertree Post, Ashenvale (2 accepts, 1 hand-in)".
function Ex.ForecastLines(forecast, env)
    local L = env.L
    local lines = {}
    for _, seg in ipairs(forecast.segments) do
        local where = zoneName(env, seg.m)
        if seg.hub then
            where = seg.hub .. ", " .. where
        end
        local bits = {}
        if seg.counts.A > 0 then
            bits[#bits + 1] = string.format(L.VIEW_ACCEPTS, seg.counts.A)
        end
        if seg.counts.C > 0 then
            bits[#bits + 1] = string.format(L.VIEW_OBJECTIVES, seg.counts.C)
        end
        if seg.counts.T > 0 then
            bits[#bits + 1] = string.format(L.VIEW_TURNINS, seg.counts.T)
        end
        if seg.counts.S > 0 then
            bits[#bits + 1] = string.format(L.VIEW_STOPS, seg.counts.S)
        end
        local range = (seg.first == seg.last) and tostring(seg.first) or (seg.first .. "-" .. seg.last)
        lines[#lines + 1] = string.format(L.VIEW_STOP, range, where, table.concat(bits, ", "))
    end
    for _, c in ipairs(forecast.changes) do
        lines[#lines + 1] = string.format(L.VIEW_CHANGE, c.at, zoneName(env, c.to),
            L["PLAN_VIA_" .. (c.via or "walk")] or c.via or "")
    end
    return lines
end

-- ---- Why not X? ----------------------------------------------------------------------------------

local function questName(env, q)
    local rec = env.rec(q)
    return (rec and rec.n) or ("#" .. tostring(q))
end

local function planIndex(plan, q)
    for i, s in ipairs((plan and plan.steps) or {}) do
        if s.q == q and s.t ~= "V" and s.t ~= "S" then
            return i, s
        end
    end
    return nil
end

local GATE_KEY = {
    race = "WHYNOT_RACE", class = "WHYNOT_CLASS", maxlevel = "WHYNOT_MAXLEVEL",
}

-- Lines explaining why quest q is not (or is) in the plan. Always at least one line.
function Ex.WhyNot(q, env)
    local L = env.L
    local rec = env.rec(q)
    local lines = {}
    local function add(key, ...)
        lines[#lines + 1] = string.format(L[key], ...)
    end
    if not rec then
        add("WHYNOT_UNKNOWN", q)
        return lines
    end
    local name = questName(env, q)
    local state, reason = env.state(q)
    local snap = env.snap or {}
    local idx, step = planIndex(env.plan, q)
    if state == "completed" then
        add("WHYNOT_DONE", name)
    elseif state == "broken" then
        add(reason == "curated" and "WHYNOT_BROKEN_CURATED" or "WHYNOT_BROKEN_REPORTED", name)
    elseif state == "ignored" then
        add(reason == "curated" and "WHYNOT_CURATED_SKIP" or "WHYNOT_SKIPPED", name)
    elseif state == "active" or state == "objectives-done" or state == "failed" then
        if idx then
            add("WHYNOT_INLOG_PLANNED", name, idx, K.Planner and K.Planner.Why and K.Planner.Why(step) or "")
        else
            add("WHYNOT_INLOG", name)
        end
    elseif state == "unavailable" then
        if reason == "level" then
            add("WHYNOT_LEVEL", name, math.max(rec.rl or 1, rec.re or 1), snap.level or 1)
        elseif reason == "prereq" then
            local missing = {}
            for _, p in ipairs(rec.pa or {}) do
                if env.state(p) ~= "completed" then
                    missing[#missing + 1] = questName(env, p)
                end
            end
            if #missing == 0 and rec.po and #rec.po > 0 then
                for _, p in ipairs(rec.po) do
                    missing[#missing + 1] = questName(env, p)
                end
                add("WHYNOT_PREREQ_ANY", name, table.concat(missing, ", "))
            else
                add("WHYNOT_PREREQ", name, table.concat(missing, ", "))
            end
        elseif reason == "exclusive" then
            add("WHYNOT_EXCLUSIVE", name)
        elseif GATE_KEY[reason] then
            add(GATE_KEY[reason], name)
        else
            add("WHYNOT_UNAVAILABLE", name, tostring(reason))
        end
    elseif state == "unknown" then
        add("WHYNOT_UNTRACKED", name, tostring(reason))
    elseif idx then
        add("WHYNOT_PLANNED", name, idx, K.Planner and K.Planner.Why and K.Planner.Why(step) or "")
    else
        -- available but not planned: grey or red, off the route, unplaced or simply later
        local wt = env.wt
        local level = snap.level or 1
        local Sc = K.Plan.Score
        local colour = Sc and Sc.Colour(rec.lv, level, wt and wt.levelSlack) or "yellow"
        if colour == "grey" or colour == "red" then
            add("WHYNOT_COLOUR", name, L["PLAN_COLOUR_" .. colour] or colour, rec.lv or 0, level)
        elseif rec.f and Ex.hasRiskZero(rec.f, wt) then
            add("WHYNOT_RISK", name)
        else
            local spine = Sc and wt and wt.spine and Sc.Spine({ q = q, m = env.W and env.W.questZone(q),
                flags = rec.f }, level, wt) or 1
            if spine < 1 then
                add("WHYNOT_OFFPATH", name, zoneName(env, env.W and env.W.questZone(q)))
            else
                add("WHYNOT_LATER", name)
            end
        end
    end
    return lines
end

-- True when one of the quest flags has a risk multiplier of 0 (dungeon, raid, pvp: never planned).
function Ex.hasRiskZero(flags, wt)
    for _, f in ipairs(flags or {}) do
        if wt and wt.risk and wt.risk[f] == 0 then
            return true
        end
    end
    return false
end

-- ---- Replan notes (toasts) -----------------------------------------------------------------------

local function firstWorkStep(plan)
    for _, s in ipairs((plan and plan.steps) or {}) do
        if s.t ~= "V" and s.t ~= "S" then
            return s
        end
    end
    return nil
end

local function planHasZone(plan, m)
    for _, s in ipairs((plan and plan.steps) or {}) do
        if s.t ~= "V" and s.z == m then
            return true
        end
    end
    return false
end

-- Toast text when the new plan is interesting compared to the old one, else nil. Interesting: the
-- plan moves to another zone for good (the old zone has no more work in the new plan), or an
-- urgent service stop (repair, sell) comes first. A plain reorder is never worth a toast.
function Ex.ReplanNote(old, new, env)
    local L = env.L
    local was, now = firstWorkStep(old), firstWorkStep(new)
    if not (was and now) or not was.z or not now.z then
        return nil
    end
    local head = new and new.steps and new.steps[1]
    if head and head.t == "S" and head.why and (head.why.urgency or 0) >= 1
        and not (old and old.steps and old.steps[1] and old.steps[1].k == head.k) then
        return string.format(L.TOAST_SERVICE, head.note or head.n or "")
    end
    if was.z ~= now.z and not planHasZone(new, was.z) then
        local m = now.z
        return string.format(L.TOAST_MOVE, zoneName(env, m), zoneName(env, was.z))
    end
    return nil
end

-- ---- Tooltips ----------------------------------------------------------------------------------------

-- Lines for a step card tooltip: what, where and why.
function Ex.Tip(step, env)
    local L = env.L
    local lines = {}
    local head = string.format("%s %s", L[KIND[step.t]] or step.t, step.n or "")
    lines[#lines + 1] = head
    local why = K.Planner and K.Planner.Why and K.Planner.Why(step) or ""
    if why ~= "" then
        lines[#lines + 1] = why
    end
    if step.z then
        lines[#lines + 1] = zoneName(env, step.z)
    end
    return lines
end
