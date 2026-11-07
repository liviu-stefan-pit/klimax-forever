-- Reconciler: the quest state of every quest, derived from the snapshot (phase 20, plan s4.2).
--
-- Pure functions over plain tables, so the specs run them without a client. A context holds the
-- snapshot and three lookups:
--   info(q)      -> quest record ({pa, po, ex, eq, rl, re, mx, ra, cl, pv, cx, lv}) or nil,
--   exGroup(id)  -> members of an exclusive group (Index.ex),
--   eqGroup(q)   -> the curated equivalent ids of q (Index.eq), or nil,
--   known(q)     -> true when q is in the add-on's quest universe (its flag was scanned),
--   believed(q)  -> true when the guide believes q was accepted (an ACCEPT stored as done).
--
-- States (R.STATES): completed, objectives-done, active, failed, ignored, broken, unknown,
-- abandoned, available, unavailable. State() also returns a reason:
--   unknown:     "no-completed-api" | "log-partial" | "not-scanned" | "untracked"
--   unavailable: "race" | "class" | "level" | "maxlevel" | "exclusive" | "prereq"
--   ignored:     "skipped" | "curated"
-- Rules, in order (each one is a spec in tests/lua/state_spec.lua):
--   1. curated broken -> broken;
--   2. completed: the flag, an equivalent's flag, or implied by a completed later link
--      (chain predecessors `pv` and all-of prerequisites `pa` of a completed quest are completed);
--   3. in the log: failed, objectives-done or active (the game always wins over skips);
--   4. skipped by the player, or curated skip -> ignored;
--   4b. a quest outside the add-on's universe (flag never scanned) -> unknown "untracked";
--   5. gates: race, class, level, max level, exclusive group taken, prerequisites;
--   6. not in the log but the character had it (seen, or the guide believed it accepted):
--      unknown when the game cannot tell turned-in from abandoned, else abandoned;
--   7. otherwise available.
local _, K = ...

local R = {}
K.Reconciler = R

R.STATES = {
    "completed", "objectives-done", "active", "failed", "ignored", "broken", "unknown", "abandoned",
    "available", "unavailable",
}

-- requiredRaces bits (ChrRaces order) and requiredClasses bits (1 << (classId - 1)).
R.RACE_BITS = {
    Human = 1, Orc = 2, Dwarf = 4, NightElf = 8, Undead = 16, Scourge = 16, Tauren = 32, Gnome = 64,
    Troll = 128,
}
R.CLASS_BITS = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128, WARLOCK = 256,
    DRUID = 1024,
}

-- Lua 5.1 has no bit operators; masks stay below 2^53, so arithmetic is exact.
function R.HasBit(mask, bit)
    if not mask or not bit then
        return true
    end
    return math.floor(mask / bit) % 2 == 1
end

local function none()
    return nil
end

-- New context. lookups: {info, exGroup, eqGroup, known, believed} (all optional).
function R.New(snap, lookups)
    lookups = lookups or {}
    return {
        snap = snap,
        info = lookups.info or none,
        exGroup = lookups.exGroup or none,
        eqGroup = lookups.eqGroup or none,
        known = lookups.known or function() return true end,
        believed = lookups.believed or function() return false end,
        memo = {},
        implied = nil,
    }
end

-- Quests implied completed by completed later links: chain predecessors and all-of prerequisites,
-- transitively. Built once per context.
local function implied(ctx)
    if ctx.implied then
        return ctx.implied
    end
    local out = {}
    local stack = {}
    for q, v in pairs(ctx.snap.completed or {}) do
        if v then
            stack[#stack + 1] = q
        end
    end
    while #stack > 0 do
        local q = table.remove(stack)
        local rec = ctx.info(q)
        if rec then
            for _, list in ipairs({ rec.pv or {}, rec.pa or {} }) do
                for _, p in ipairs(list) do
                    if not out[p] then
                        out[p] = true
                        stack[#stack + 1] = p
                    end
                end
            end
        end
    end
    ctx.implied = out
    return out
end

-- True when the game (or an equivalent, or a completed later link) shows q handed in.
function R.Completed(ctx, q)
    local completed = ctx.snap.completed or {}
    if completed[q] then
        return true
    end
    local eq = ctx.eqGroup(q)
    if eq then
        for _, other in ipairs(eq) do
            if completed[other] then
                return true
            end
        end
    end
    return implied(ctx)[q] == true
end

-- A prerequisite counts as met when it is completed, or when the game cannot tell (no completed
-- API, scan not finished, or a quest outside the add-on's universe): unknown never blocks.
local function prereqMet(ctx, p)
    if R.Completed(ctx, p) then
        return true
    end
    return ctx.snap.completedKnown ~= true or not ctx.known(p)
end

-- First failing gate, or nil. rec may be nil (nothing to check).
function R.Gate(ctx, q, rec)
    if not rec then
        return nil
    end
    local snap = ctx.snap
    if rec.ra and snap.race then
        local bit = R.RACE_BITS[snap.raceToken or ""] or R.RACE_BITS[snap.race]
        if bit and not R.HasBit(rec.ra, bit) then
            return "race"
        end
    end
    if rec.cl and snap.class then
        local bit = R.CLASS_BITS[snap.class]
        if bit and not R.HasBit(rec.cl, bit) then
            return "class"
        end
    end
    local need = math.max(rec.re or 0, rec.rl or 0)
    if snap.level and need > snap.level then
        return "level"
    end
    if rec.mx and snap.level and snap.level > rec.mx then
        return "maxlevel"
    end
    if rec.ex then
        for _, other in ipairs(ctx.exGroup(rec.ex) or {}) do
            if other ~= q and (R.Completed(ctx, other) or (snap.log and snap.log[other])) then
                return "exclusive"
            end
        end
    end
    for _, p in ipairs(rec.pa or {}) do
        if not prereqMet(ctx, p) then
            return "prereq"
        end
    end
    if rec.po and #rec.po > 0 then
        local any = false
        for _, p in ipairs(rec.po) do
            if prereqMet(ctx, p) then
                any = true
                break
            end
        end
        if not any then
            return "prereq"
        end
    end
    return nil
end

local function compute(ctx, q)
    local snap = ctx.snap
    local rec = ctx.info(q)
    if rec and rec.cx == "broken" then
        return "broken", "curated"
    end
    if R.Completed(ctx, q) then
        return "completed"
    end
    local e = snap.log and snap.log[q]
    if e then
        if e.failed then
            return "failed"
        end
        return e.complete and "objectives-done" or "active"
    end
    if snap.skipped and snap.skipped[q] then
        return "ignored", "skipped"
    end
    if rec and rec.cx == "skip" then
        return "ignored", "curated"
    end
    if not ctx.known(q) then
        -- outside the add-on's universe: its flag was never scanned, so "absent" proves nothing
        return "unknown", "untracked"
    end
    local gate = R.Gate(ctx, q, rec)
    local hadIt = (snap.seen and snap.seen[q]) or ctx.believed(q)
    if hadIt then
        if snap.completedKnown == false then
            return "unknown", "no-completed-api"
        elseif not snap.scanned then
            return "unknown", "not-scanned"
        elseif snap.logPartial then
            return "unknown", "log-partial"
        end
        if not gate then
            return "abandoned"
        end
    end
    if gate then
        return "unavailable", gate
    end
    return "available"
end

-- State and reason of quest q (memoised per context).
function R.State(ctx, q)
    local m = ctx.memo[q]
    if m then
        return m[1], m[2]
    end
    local state, reason = compute(ctx, q)
    ctx.memo[q] = { state, reason }
    return state, reason
end

-- True for the states that mean "the quest is in the player's log".
local IN_LOG = { active = true, ["objectives-done"] = true, failed = true }
function R.InLog(state)
    return IN_LOG[state] == true
end

-- True for the states the player can act on now (take, re-take, progress or turn in).
local ACTIONABLE = { available = true, abandoned = true, active = true, ["objectives-done"] = true }
function R.Actionable(state)
    return ACTIONABLE[state] == true
end
