-- Trainer budget filter (PRD 7.7). On TRAINER steps the window text says what to learn and what can
-- wait. While a trainer window is open the plan of the visit (essentials, money check) is kept in
-- K.trainerPlan. Klimax only reads the trainer window; it never buys or clicks anything.
local _, K = ...
local L = K.L
local C = K.Compat

local T = {}
K.Trainer = T

local SHOW_TEXT = 4     -- essentials named in the window hint
local SHOW_SKIP = 2

-- The filter in force for a class at a level. Bands accumulate (phase 24 review): every band with
-- from <= level adds its essentials (earlier bands first, so the buying order keeps the basics
-- first) and its skips; a spell essential in any applying band is never listed as a skip. Returns
-- {from = the last applying band's level, essential = {...}, skipForNow = {...}} or nil.
function T.Band(class, level)
    local bands = K.TrainerFilters and K.TrainerFilters[class]
    if not bands then
        return nil
    end
    local out = { essential = {}, skipForNow = {} }
    local isEssential, seen = {}, {}
    for _, band in ipairs(bands) do
        if band.from <= (level or 1) then
            out.from = band.from
            for _, name in ipairs(band.essential or {}) do
                if not isEssential[name] then
                    isEssential[name] = true
                    out.essential[#out.essential + 1] = name
                end
            end
        end
    end
    if not out.from then
        return nil
    end
    for _, band in ipairs(bands) do
        if band.from <= (level or 1) then
            for _, name in ipairs(band.skipForNow or {}) do
                if not isEssential[name] and not seen[name] then
                    seen[name] = true
                    out.skipForNow[#out.skipForNow + 1] = name
                end
            end
        end
    end
    return out
end

-- Plans a trainer visit. services: list of {name, category, cost(copper)}. band: a Band result.
-- Only spells the trainer offers now (category "available") are planned. Essentials keep the band's
-- order, which is also the buying order when money is short (must-haves first).
-- Returns {essential = {{name, cost}...}, skip = {names...}, cost = copper, money = copper,
--          short = copper missing (0 when enough)}.
function T.Plan(services, band, money)
    local byName = {}
    for _, s in ipairs(services or {}) do
        if s.name then
            byName[s.name] = s
        end
    end
    local plan = { essential = {}, skip = {}, cost = 0, money = money or 0, short = 0 }
    if not band then
        return plan
    end
    for _, name in ipairs(band.essential or {}) do
        local s = byName[name]
        if s and s.category == "available" then
            plan.essential[#plan.essential + 1] = { name = name, cost = s.cost or 0 }
            plan.cost = plan.cost + (s.cost or 0)
        end
    end
    for _, name in ipairs(band.skipForNow or {}) do
        local s = byName[name]
        if s and s.category == "available" then
            plan.skip[#plan.skip + 1] = name
        end
    end
    if plan.cost > plan.money then
        plan.short = plan.cost - plan.money
    end
    return plan
end

-- Joins names with ", ", keeping at most `max` of them.
local function names(list, max)
    local out = {}
    for i = 1, math.min(#list, max) do
        out[#out + 1] = list[i]
    end
    return table.concat(out, ", ")
end

-- The window hint for a TRAINER step, from the band alone (no trainer window needed).
function T.Hint()
    local class = K.player and K.player.class
    local band = T.Band(class, (K.player and K.player.level) or 1)
    if not band then
        return nil
    end
    local essentials = {}
    for i, name in ipairs(band.essential or {}) do
        essentials[i] = name
    end
    if #essentials == 0 then
        return nil
    end
    local text = string.format(L.HINT_TRAIN, names(essentials, SHOW_TEXT))
    if band.skipForNow and #band.skipForNow > 0 then
        text = text .. string.format(L.HINT_TRAIN_SKIP, names(band.skipForNow, SHOW_SKIP))
    end
    return text
end

-- Money line for a plan: enough, or how much is missing and the order to buy in.
function T.MoneyLine(plan)
    if plan.short > 0 then
        local order = {}
        for _, e in ipairs(plan.essential) do
            order[#order + 1] = e.name
        end
        return string.format(L.TRAIN_SHORT, K.Rewards.Money(plan.short), names(order, 3))
    end
    return string.format(L.TRAIN_MONEY, K.Rewards.Money(plan.money), K.Rewards.Money(plan.cost))
end

-- ---- Trainer window ---------------------------------------------------------------------------

-- Reads every trainer row and returns the list of services.
function T.ReadServices()
    local services = {}
    local count = (GetNumTrainerServices and GetNumTrainerServices()) or 0
    for i = 1, count do
        local s = C.GetTrainerService(i)
        if s then
            services[#services + 1] = s
        end
    end
    return services
end

-- Plans the visit for the trainer window that is showing now (no window of our own: the money check
-- and the essentials live in the step text and /klimax). Returns the plan.
function T.Open()
    local class = K.player and K.player.class
    local band = T.Band(class, (K.player and K.player.level) or 1)
    local plan = T.Plan(T.ReadServices(), band, C.GetMoney())
    K.trainerPlan = plan
    return plan
end

function T.Close()
    K.trainerPlan = nil
end

K.On("TRAINER_SHOW", function()
    T.Open()
end)

K.On("TRAINER_CLOSED", function()
    T.Close()
end)
