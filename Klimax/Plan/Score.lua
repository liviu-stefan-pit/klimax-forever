-- Planner scoring (phase 21, plan s4.3 step 2). Pure functions; the Python mirror
-- (pipeline/sim/planner.py) implements the same formulas, and the shared vectors in
-- tests/vectors/planner keep the two in step.
local _, K = ...
K.Plan = K.Plan or {}

local Sc = {}
K.Plan.Score = Sc

-- Largest level gap at which a quest still gives XP (same formula as Sync.GreyRange).
function Sc.GreyRange(level)
    if level <= 39 then
        return 5 + math.floor(level / 10)
    end
    return math.floor(level / 5)
end

-- Difficulty colour of a quest level for a player level: red, orange, yellow, green or grey.
function Sc.Colour(questLevel, level, slack)
    local diff = (questLevel or level) - level
    if diff > (slack or 4) then
        return "red"
    elseif diff >= 3 then
        return "orange"
    elseif diff >= -2 then
        return "yellow"
    elseif level - (questLevel or level) > Sc.GreyRange(level) then
        return "grey"
    end
    return "green"
end

-- Classic quest XP at a player level (pipeline/world/quests.py xp_at_level).
function Sc.XpAt(base, questLevel, level)
    local diff = level - questLevel
    local factor
    if diff <= 5 then
        factor = 1.0
    elseif diff == 6 then
        factor = 0.8
    elseif diff == 7 then
        factor = 0.6
    elseif diff == 8 then
        factor = 0.4
    elseif diff == 9 then
        factor = 0.2
    else
        factor = 0.1
    end
    return math.floor(math.floor(base * factor) / 5) * 5
end

function Sc.Dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- Risk multiplier of a quest's flags (product of the weights of every flag it has).
function Sc.Risk(flags, wt)
    local m = 1.0
    for _, f in ipairs(flags or {}) do
        local r = wt.risk[f]
        if r then
            m = m * r
        end
    end
    return m
end

-- Curated spine factor (phase 25): wt.spine = {rows = {{map, lo, hi}, ...}, on, off, boost = {[q]},
-- dungeons = {{m, lo, hi}, ...}, window}. A quest in a zone of the character's branch at its level
-- is on path; any other zone is off path; key quests get their boost; a dungeon's quests inside its
-- window get the window factor. 1.0 without a spine.
function Sc.Spine(packet, level, wt)
    local sp = wt.spine
    if not sp then
        return 1.0
    end
    local f = sp.off
    for _, row in ipairs(sp.rows or {}) do
        if row[1] == packet.m and level >= row[2] and level <= row[3] then
            f = sp.on
            break
        end
    end
    local boost = sp.boost and sp.boost[packet.q]
    if boost then
        f = f * boost
    end
    if sp.dungeons then
        for _, d in ipairs(sp.dungeons) do
            if d.m == packet.m and level >= d.lo and level <= d.hi then
                for _, flag in ipairs(packet.flags or {}) do
                    if flag == "dungeon" then
                        f = f * sp.window
                        break
                    end
                end
                break
            end
        end
    end
    return f
end

-- Value of finishing a quest at `level`, before obligations and distance. Returns value and the
-- terms (for /klimax why). packet: {xp, lv, flags, classQuest, upgrade, chain}.
function Sc.Value(packet, level, wt)
    local colour = Sc.Colour(packet.lv, level, wt.levelSlack)
    local xp = Sc.XpAt(packet.xp or 0, packet.lv or level, level)
    local terms = { xp = xp, colour = colour, colourMult = wt.colour[colour] or 0,
        risk = Sc.Risk(packet.flags, wt), class = 1.0, upgrade = 1.0, chain = 1.0 }
    if packet.classQuest then
        terms.class = wt.classQuest
    end
    if packet.upgrade then
        terms.upgrade = wt.upgrade
    end
    if packet.chain then
        terms.chain = 1.0 + wt.chain
    end
    local spine = Sc.Spine(packet, level, wt)
    if spine ~= 1.0 then
        terms.spine = spine
    end
    local value = xp * terms.colourMult * terms.risk * terms.class * terms.upgrade * terms.chain * spine
    return value, terms
end

-- Obligation multiplier of the quest's stage: ready to hand in, in progress, or not taken yet.
function Sc.Obligation(stage, wt)
    if stage == "T" then
        return wt.obligationReady
    elseif stage == "C" then
        return wt.obligationActive
    end
    return 1.0
end
