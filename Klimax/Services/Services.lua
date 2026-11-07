-- Services engine (phase 23, DYNAMIC_GUIDE_PLAN s6): turns needs (Services/Rules.lua and the class
-- module) into service stops in the plan, at the nearest provider, only where they pay off.
--
--   Sv.Read()                         -> the services snapshot (bags, durability, supplies, pet ...)
--   Sv.Provider(role, W, from, path)  -> nearest NPC (or mailbox) with a role, by travel cost
--   Sv.Apply(steps, x, W, wt, path)   -> the plan with service steps inserted (pure over its inputs)
--
-- A service step: {t = "S", k = "svc:<reason>", role, reasons, z, x, y, npc | obj, n, note, hint}.
-- AH, bank and mail are hints only; nothing is bought, sold, sent or posted for the player.
local _, K = ...
local L = K.L
local C = K.Compat

local Sv = K.Services or {}
K.Services = Sv
local Ru = Sv.Rules

Sv.WINDOW = 6           -- plan gaps considered for a stop (the first six steps)
Sv.FLIGHT_DETOUR = 120  -- seconds worth spending to learn a new flight path
Sv.HEARTH_SHARE = 5     -- of the first 8 quest steps in one zone: offer to bind the hearth there

local Sq = K.Plan.Sequence

-- ---- Reading -------------------------------------------------------------------------------------

function Sv.Read()
    local p = K.player or {}
    local supplies = K.Helpers and K.Helpers.CountSupplies and K.Helpers.CountSupplies() or {}
    local ranged = C.GetEquippedLink(18)
    local cls = ranged and C.ItemClass(ranged)
    local cdb = K.cdb or {}
    return {
        level = p.level or 1, class = p.class,
        money = C.GetMoney and C.GetMoney() or 0,
        freeSlots = K.Helpers and K.Helpers.FreeSlots and K.Helpers.FreeSlots() or nil,
        durability = C.GetDurability(),
        supplies = supplies,
        hasPet = C.HasPet(), petHappiness = C.PetHappiness(),
        hasMail = C.HasNewMail(),
        trainedAt = cdb.trainedAt, profTrained = cdb.profTrained or {}, visited = cdb.visited or {},
        rangedSubclass = cls and cls.classID == 2 and cls.subclassID or nil,
        taxiKnown = cdb.taxiKnown or {},
        bind = GetBindLocation and GetBindLocation() or nil,
    }
end

-- ---- Providers -----------------------------------------------------------------------------------

-- Points of a provider id for a role: mail is a mailbox object, every other role an NPC.
local function points(W, role, id)
    if role == "mail" then
        return W.objectPoints(id)
    end
    return W.npcPoints(id)
end

-- Nearest provider of `role` from point `from` ({m, x, y}), by travel cost. maps: optional list of
-- maps to search (default: from.m, then every compiled zone). Returns {id, m, x, y, cost} or nil.
function Sv.Provider(role, W, from, wt, path, maps)
    local search = maps
    if not search then
        search = { from.m }
        for _, m in ipairs(W.zoneIds()) do
            if m ~= from.m then
                search[#search + 1] = m
            end
        end
    end
    local best
    for _, m in ipairs(search) do
        local services = W.zoneServices(m)
        local ids = services and services[role]
        for _, id in ipairs(ids or {}) do
            for _, pt in ipairs(points(W, role, id) or {}) do
                local p = { m = pt[1], x = pt[2], y = pt[3] }
                local cost = Sq.Between(from, p, wt, path)
                if cost then
                    local closer = not best or cost < best.cost - 1e-9
                        or (math.abs(cost - best.cost) <= 1e-9 and id < best.id)
                    if closer then
                        best = { id = id, m = p.m, x = p.x, y = p.y, cost = cost }
                    end
                end
            end
        end
        -- the player's own zone has one: no need to look further
        if best and m == from.m and not maps then
            break
        end
    end
    return best
end

-- ---- Plan-context needs: flight paths and the hearth --------------------------------------------

local function knownNode(name, known)
    local head = (name or ""):lower():match("^([^,]+)") or ""
    for k in pairs(known or {}) do
        if tostring(k):lower():find(head, 1, true) then
            return true
        end
    end
    return false
end
Sv.KnownNode = knownNode

-- Maps of the first n quest steps of a plan, with counts.
local function planMaps(steps, n)
    local counts, order = {}, {}
    local seen = 0
    for _, s in ipairs(steps) do
        if s.t ~= "V" and s.t ~= "S" and s.z then
            if not counts[s.z] then
                order[#order + 1] = s.z
            end
            counts[s.z] = (counts[s.z] or 0) + 1
            seen = seen + 1
            if seen >= n then
                break
            end
        end
    end
    return counts, order
end

-- Needs that depend on the plan: an unknown flight master in the zones the plan visits, and binding
-- the hearth in the zone where most of the next quests are.
function Sv.PlanNeeds(steps, x, W, from)
    local out = {}
    local counts, order = planMaps(steps, 8)
    local maps = { from.m }
    for _, m in ipairs(order) do
        if m ~= from.m then
            maps[#maps + 1] = m
        end
    end
    local nodes = (W.travel and W.travel.nodes) or {}
    for _, m in ipairs(maps) do
        local services = W.zoneServices(m)
        for _, id in ipairs((services and services.fm) or {}) do
            local node = nodes[id]
            if node and not knownNode(node.n, x.taxiKnown) then
                out[#out + 1] = { role = "fm", reason = "flight", urgency = 0.5, maxDetour = Sv.FLIGHT_DETOUR,
                    maps = { m }, only = id }
                break
            end
        end
    end
    for _, m in ipairs(order) do
        if counts[m] >= Sv.HEARTH_SHARE then
            local hubs = W.zoneHubs and W.zoneHubs(m) or {}
            local bound = false
            for _, hub in ipairs(hubs) do
                if hub.name and x.bind and hub.name:lower() == tostring(x.bind):lower() then
                    bound = true
                end
            end
            if not bound and x.bind ~= nil then
                out[#out + 1] = { role = "inn", reason = "hearth", urgency = 0.3, maxDetour = 60, maps = { m } }
            end
            break
        end
    end
    return out
end

-- ---- Insertion -----------------------------------------------------------------------------------

local function stepPoint(s, from)
    if s and s.z and s.x then
        return { m = s.z, x = s.x, y = s.y }
    end
    return from
end

-- The plan gap (0 = before the first step) where a stop at p costs the least extra travel, within the
-- first Sv.WINDOW gaps. Returns gap, detour seconds.
function Sv.BestGap(steps, from, p, wt, path)
    local bestGap, bestDetour
    local last = math.min(#steps, Sv.WINDOW)
    for j = 0, last do
        local prev = (j == 0) and from or stepPoint(steps[j], from)
        local nextStep = steps[j + 1]
        local toP = Sq.Between(prev, p, wt, path) or wt.unreachable
        local detour
        if nextStep and j < last then
            local nxt = stepPoint(nextStep, from)
            detour = toP + (Sq.Between(p, nxt, wt, path) or wt.unreachable)
                - (Sq.Between(prev, nxt, wt, path) or wt.unreachable)
        else
            detour = toP
        end
        if not bestDetour or detour < bestDetour - 1e-9 then
            bestGap, bestDetour = j, detour
        end
    end
    return bestGap or 0, bestDetour or 0
end

local function note(reason, arg)
    local text = L["SVC_" .. reason] or reason
    if arg then
        text = string.format(text, arg)
    end
    return text
end

-- Inserts the service stops. steps: the quest plan; x: services snapshot; from: {m, x, y}.
-- Returns the new list (the input list is not changed).
function Sv.Apply(steps, x, W, wt, path, from, profile)
    local out = {}
    for i, s in ipairs(steps) do
        out[i] = s
    end
    local needs = Ru.Needs(x, profile)
    for _, need in ipairs(Sv.PlanNeeds(steps, x, W, from)) do
        needs[#needs + 1] = need
    end
    local front = 0   -- urgent stops (and place-less reminders) at the head of the plan
    for _, need in ipairs(needs) do
        if need.hint and not need.role then
            -- a reminder with no place (Feed Pet): first in the list, no arrow
            front = front + 1
            table.insert(out, front, { t = "S", k = "svc:" .. need.reason, reason = need.reason,
                reasons = { need.reason }, hint = true, note = note(need.reason), n = note(need.reason),
                why = { urgency = need.urgency } })
        else
            -- a provider that already serves a stop in the plan, when it has the role (plan order)
            local merged = false
            for _, step in ipairs(out) do
                local npc = not merged and step.t == "S" and step.npc and W.npc and W.npc(step.npc)
                for _, r in ipairs((npc and npc.r) or {}) do
                    if not merged and r == need.role then
                        step.reasons[#step.reasons + 1] = need.reason
                        step.note = step.note .. " " .. note(need.reason, need.arg)
                        merged = true
                    end
                end
            end
            if not merged then
                local prov
                if need.only then
                    local pts = W.npcPoints(need.only) or {}
                    if pts[1] then
                        prov = { id = need.only, m = pts[1][1], x = pts[1][2], y = pts[1][3] }
                    end
                else
                    prov = Sv.Provider(need.role, W, from, wt, path, need.maps)
                end
                if prov then
                    local gap, detour = Sv.BestGap(out, from, prov, wt, path)
                    if need.urgency >= 1 then
                        gap = front
                        front = front + 1
                    elseif gap < front then
                        gap = front
                    end
                    if need.urgency >= 1 or detour <= need.maxDetour then
                        local npc = need.role ~= "mail" and W.npc and W.npc(prov.id) or nil
                        local step = { t = "S", k = "svc:" .. need.reason, role = need.role, reason = need.reason,
                            reasons = { need.reason }, z = prov.m, x = prov.x, y = prov.y,
                            n = npc and npc.n or note(need.reason, need.arg), note = note(need.reason, need.arg),
                            hint = need.hint, el = x.level,
                            why = { urgency = need.urgency, detour = detour, provider = prov.id } }
                        if need.role == "mail" then
                            step.obj = prov.id
                        else
                            step.npc = prov.id
                        end
                        table.insert(out, gap + 1, step)
                    end
                end
            end
        end
    end
    return out
end

-- ---- Visits -------------------------------------------------------------------------------------

local function visited(key)
    K.cdb.visited = K.cdb.visited or {}
    K.cdb.visited[key] = true
    if K.Planner then
        K.Planner.dirty = true
    end
end
Sv.MarkVisited = visited

K.On("TRAINER_SHOW", function()
    local level = (K.player and K.player.level) or 1
    if C.IsTradeskillTrainer() then
        K.cdb.profVisitAt = level
    else
        K.cdb.trainedAt = level
        local pet = K.player and K.player.class == "HUNTER" and UnitExists and UnitExists("pet")
        if pet then
            visited("pettrainer")
        end
    end
    if K.Planner then
        K.Planner.dirty = true
    end
end)

K.On("PET_STABLE_SHOW", function()
    visited("stable" .. ((K.player and K.player.level) or 0))
end)

for _, event in ipairs({ "MERCHANT_SHOW", "MAIL_SHOW", "BANKFRAME_OPENED", "AUCTION_HOUSE_SHOW", "CONFIRM_BINDER",
    "TAXIMAP_OPENED", "UPDATE_INVENTORY_DURABILITY", "BAG_UPDATE" }) do
    K.On(event, function()
        if K.Planner then
            K.Planner.dirty = true
        end
    end)
end
