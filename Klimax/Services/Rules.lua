-- Service rules (phase 23, DYNAMIC_GUIDE_PLAN s6): pure functions from a services snapshot to the
-- needs the plan should serve. A need is
--   {role, reason, urgency (0..1), maxDetour (seconds), hint (true: a reminder, never automated),
--    once (key remembered after the visit), maps (only providers on these maps)}
-- urgency 1 means "now": the stop goes first whatever the detour. Otherwise the stop is inserted only
-- where the detour costs at most maxDetour seconds.
--
-- The services snapshot x: level, class, money (copper), freeSlots, durability (0..1 or nil),
-- supplies {food, water, ammo}, hasPet, petHappiness, hasMail, trainedAt (level of the last class
-- trainer visit), profTrained {[profession] = true}, visited {[key] = true}, rangedSubclass.
local _, K = ...

local Ru = {}
K.Services = K.Services or {}
K.Services.Rules = Ru

Ru.REPAIR_NOW, Ru.REPAIR_SOON = 0.25, 0.5
Ru.BAGS_SOON = 2
Ru.MANA = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true,
    DRUID = true }

-- Food and water stacks worth carrying at a level (phase 24): one early, two from level 20.
-- Riding: start saving at 36, learn it at 40 (copper).
Ru.RIDING_SAVE_FROM, Ru.RIDING_LEVEL, Ru.RIDING_COST = 36, 40, 900000

function Ru.Stacks(level)
    return (level or 1) >= 20 and 2 or 1
end

-- Rough cost in copper of a class trainer visit at a level (new ranks come at even levels).
function Ru.TrainCost(level)
    return 10 * level * level
end

local function add(out, need)
    out[#out + 1] = need
end

function Ru.Base(x, profile)
    local out = {}
    local level = x.level or 1
    if x.durability then
        if x.durability <= Ru.REPAIR_NOW then
            add(out, { role = "repair", reason = "repair", urgency = 1, maxDetour = 600 })
        elseif x.durability <= Ru.REPAIR_SOON then
            add(out, { role = "repair", reason = "repair", urgency = 0.5, maxDetour = 150 })
        end
    end
    if x.freeSlots then
        if x.freeSlots == 0 then
            add(out, { role = "vendor", reason = "sell", urgency = 1, maxDetour = 600 })
        elseif x.freeSlots <= Ru.BAGS_SOON then
            add(out, { role = "vendor", reason = "sell", urgency = 0.6, maxDetour = 150 })
        end
    end
    local supplies = x.supplies or {}
    local makes = K.Class.Makes(x.class, level)
    local stacks = Ru.Stacks(level)
    if level >= 4 and not makes.food and (supplies.food or 0) < stacks then
        add(out, { role = "food", reason = "food", urgency = (supplies.food or 0) == 0 and 0.4 or 0.2,
            maxDetour = 60 })
    end
    if level >= 4 and Ru.MANA[x.class or ""] and not makes.water and (supplies.water or 0) < stacks then
        add(out, { role = "water", reason = "water", urgency = (supplies.water or 0) == 0 and 0.4 or 0.2,
            maxDetour = 60 })
    end
    local trained = x.trainedAt or 1
    if x.class and level >= 4 and level % 2 == 0 and trained < level and (x.money or 0) >= Ru.TrainCost(level) then
        add(out, { role = "ct_" .. x.class, reason = "trainer", urgency = (level - trained >= 4) and 0.8 or 0.5,
            maxDetour = (level - trained >= 4) and 900 or 300 })
    end
    for _, prof in ipairs((profile and profile.professions) or {}) do
        if level >= 5 and not (x.profTrained and x.profTrained[prof]) then
            add(out, { role = "pt_" .. prof, reason = "profession", urgency = 0.4, maxDetour = 120, arg = prof })
        end
    end
    -- The 40 transition (phase 26): save gold for the riding skill and mount, then go and learn it.
    -- REVIEW: the cost is the classic one (about 90 gold for riding, mount included on this server).
    if level >= Ru.RIDING_SAVE_FROM and level <= Ru.RIDING_LEVEL then
        local ready = level >= Ru.RIDING_LEVEL and (x.money or 0) >= Ru.RIDING_COST
        add(out, { reason = ready and "riding" or "riding_save", urgency = ready and 0.7 or 0.15, hint = true })
    end
    if x.hasMail then
        add(out, { role = "mail", reason = "mail", urgency = 0.2, maxDetour = 30, hint = true })
    end
    if x.freeSlots and x.freeSlots <= 3 and level >= 10 then
        add(out, { role = "bank", reason = "bank", urgency = 0.2, maxDetour = 45, hint = true })
    end
    if level >= 10 and (x.money or 0) >= 10000 and x.freeSlots and x.freeSlots <= 6 then
        add(out, { role = "ah", reason = "ah", urgency = 0.1, maxDetour = 30, hint = true })
    end
    return out
end

-- Every need: the base rules, then the class module's, minus "once" needs already served. Sorted by
-- urgency (highest first), then reason, so the order is stable.
function Ru.Needs(x, profile)
    local out = Ru.Base(x, profile)
    for _, need in ipairs(K.Class.Needs(x.class, x, profile)) do
        out[#out + 1] = need
    end
    local kept = {}
    for _, need in ipairs(out) do
        if not (need.once and x.visited and x.visited[need.once]) then
            kept[#kept + 1] = need
        end
    end
    table.sort(kept, function(a, b)
        if a.urgency ~= b.urgency then
            return a.urgency > b.urgency
        end
        return a.reason < b.reason
    end)
    return kept
end
