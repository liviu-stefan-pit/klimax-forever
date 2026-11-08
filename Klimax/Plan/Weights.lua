-- Planner weights (phase 21, DYNAMIC_GUIDE_PLAN s4.3). Every tunable number of the planner lives in
-- this one table; profiles (s4.4) and classes adjust a copy through Weights.For. The Python mirror
-- (pipeline/sim/planner.py) reads the same defaults from tests/vectors/planner/weights.json, which a
-- spec keeps equal to Weights.DEFAULT.
local _, K = ...
K.Plan = K.Plan or {}

local Wt = {}
K.Plan.Weights = Wt

Wt.DEFAULT = {
    lookahead = 12,          -- steps in a plan
    speed = 1.4,             -- seconds per map-% on foot (about 10 yards per %, 7 yards per second)
    accept = 8,              -- seconds at a quest giver
    turnin = 8,              -- seconds at a turn-in
    objective = 100,         -- seconds per objective (a kill or collect batch)
    eliteObjective = 2.0,    -- objective time multiplier for elite quests
    hop = 90,                -- seconds per zone border crossed on foot
    flight = 150,            -- seconds for a flight between two zones with flight masters
    minCost = 5,             -- floor for a task's cost, so a zero-distance task is not infinite
    unreachable = 100000,    -- cost of a zone the travel graph cannot reach
    -- difficulty colour multipliers (grey and red are never planned with 0)
    colour = { grey = 0, green = 0.75, yellow = 1.0, orange = 0.9, red = 0 },
    obligationActive = 1.3,  -- quest in the log, objectives not done: finish before walking away
    greyTurnin = 0.5,        -- value factor (of its XP) for handing in a quest that has turned grey
    obligationReady = 1.8,   -- quest in the log, ready to hand in
    here = 1.0,              -- map-%: accepts and turn-ins this close are taken before moving on
    near = 6.0,              -- map-%: a task this close is a pickup on the way
    nearBonus = 1.25,
    classQuest = 1.4,        -- quest limited to the player's class
    upgrade = 1.25,          -- a reward that is an upgrade for the class (record `ru`)
    chain = 0.1,             -- extra value when the quest opens a follow-up (record `nx`)
    -- risk multipliers by quest flag; 0 means never planned
    risk = { elite = 0.6, group = 0.4, dungeon = 0, raid = 0, pvp = 0, escort = 0.8, timed = 0.9 },
    leaveZone = 1.3,         -- hysteresis: a task in another zone must beat local ones by this factor
    stable = 1.15,           -- a new first step must beat the current one by this factor to replace it
    levelSlack = 4,          -- quests more than this many levels above the player are red
    zoneBelow = 6,           -- zones whose top level is this far below the player are not scanned
    localMin = 6,            -- fewer packets than this near the player: scan every zone in the band
    improvePasses = 3,       -- adjacent-swap improvement passes over the sequence
}

-- XP to reach the next level, levels 1 to 59 (Classic). The planner uses it to follow level-ups
-- during a plan (quests unlock, colours change).
Wt.LEVEL_XP = {
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600,
    8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200,
    25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
    50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700,
    95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500,
    153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,
}

local function copy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = copy(v)
    end
    return out
end
Wt.Copy = copy

-- Profile presets (s4.4): each setting maps to weight changes. Unknown or missing values keep the
-- defaults (the "Relaxed, solo, balanced" profile).
Wt.PROFILE = {
    pace = {
        relaxed = {},
        efficient = { leaveZone = 1.15, near = 4.0, colour = { green = 0.6 } },
        speed = { leaveZone = 1.0, near = 3.0, colour = { green = 0.4, orange = 1.0 } },
    },
    group = {
        solo = { risk = { group = 0 } },
        open = {},
        group = { risk = { group = 0.9, elite = 0.9 } },
    },
    dungeons = {
        never = { risk = { dungeon = 0 } },
        good = { risk = { dungeon = 0.5 } },
        always = { risk = { dungeon = 1.0 } },
    },
    elites = {
        skip = { risk = { elite = 0 } },
        easy = {},
        allow = { risk = { elite = 0.9 } },
    },
    completionist = {
        xp = { colour = { green = 0.6 } },
        balanced = {},
        finish = { colour = { green = 1.0, grey = 0.3 }, leaveZone = 1.6 },
    },
    travel = {
        free = {},
        walk = { flight = 100000 },
    },
}

-- Class adjustments (phase 24 fills these in): {CLASS = {weight overrides}}.
Wt.CLASS = {}

local function merge(into, over)
    for k, v in pairs(over) do
        if type(v) == "table" and type(into[k]) == "table" then
            merge(into[k], v)
        else
            into[k] = v
        end
    end
end
Wt.Merge = merge

-- Weights for a profile ({pace, group, dungeons, elites, completionist, travel}) and a class.
-- Settings are applied in a fixed order so the result does not depend on table order.
Wt.ORDER = { "pace", "group", "dungeons", "elites", "completionist", "travel" }
function Wt.For(profile, class)
    local w = copy(Wt.DEFAULT)
    profile = profile or {}
    for _, key in ipairs(Wt.ORDER) do
        local preset = Wt.PROFILE[key][profile[key] or ""]
        if preset then
            merge(w, preset)
        end
    end
    if class and Wt.CLASS[class] then
        merge(w, Wt.CLASS[class])
    end
    return w
end
