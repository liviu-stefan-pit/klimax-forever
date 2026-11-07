-- Login audit (PRD 7.10): wrong zone and missed key rewards.
--
-- Runs on the first Klimax sync of a character, after a level jump of 3+ levels (the Sync sets
-- K.Sync.pendingAudit), and from Menu -> Audit. It shows one popup at a time:
--   * zone radar: the player stands in a zone meant for levels well below their own, and the
--     route's next step is somewhere else. The popup points at that step.
--   * missed key rewards: up to 3 suggestions from earlier bands, each with "Go there" (inserts
--     the quest's accept, complete and turn-in steps at the cursor) or "Ignore" (remembered).
--
-- The rules (A.RadarFires, A.Obtainable, A.SelectMissed) are pure and tested in busted.
local _, K = ...
local L = K.L
local C = K.Compat

local A = {}
K.Audit = A

A.RADAR_MARGIN = 2       -- zone top level this many levels below the player fires the radar
A.MAX_SUGGESTIONS = 3    -- at most this many missed rewards are offered

-- ---- Pure rules -------------------------------------------------------------------------------

-- True when the radar should fire: the player is at or above the zone's top level plus the margin,
-- and the route's target is in another zone. zoneMax is the zone's maxLevel from Zones.lua.
function A.RadarFires(zoneMax, level, mapID, targetZone)
    if not zoneMax or not level or not targetZone then
        return false
    end
    if targetZone == mapID then
        return false
    end
    return level >= zoneMax + A.RADAR_MARGIN
end

-- Whether a key-reward ACCEPT step of an earlier band is still obtainable: not done, not ignored,
-- not grey at this level, and its prerequisites are met (all of pa, any of po).
function A.Obtainable(step, level, completed, ignored)
    if not step.q or not step.kr or not step.rw or not step.rw.item then
        return false
    end
    if completed[step.q] or (ignored and ignored[step.q]) then
        return false
    end
    if K.Sync.IsGrey(step.ql, level) then
        return false
    end
    for _, p in ipairs(step.pa or {}) do
        if not completed[p] then
            return false
        end
    end
    if step.po and #step.po > 0 then
        local any = false
        for _, p in ipairs(step.po) do
            if completed[p] then
                any = true
                break
            end
        end
        if not any then
            return false
        end
    end
    return true
end

-- The best `max` candidates: highest score first, ties by quest id. cands: {quest, score, ...}.
function A.SelectMissed(cands, max)
    local list = {}
    for _, c in ipairs(cands) do
        list[#list + 1] = c
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.quest < b.quest
    end)
    local out = {}
    for i = 1, math.min(max or A.MAX_SUGGESTIONS, #list) do
        out[i] = list[i]
    end
    return out
end

-- ---- WoW side ---------------------------------------------------------------------------------

local function equippedInfo(slot)
    local link = C.GetEquippedLink(slot)
    local data = link and K.Rewards.ReadItem(link)
    return data and data.info or nil
end

-- Whether an item is useful now: a bag while there are free slots, or an upgrade over the
-- equipped item. Returns useful, score, name. Uncached items are not useful yet.
function A.Useful(itemID, class, level, freeSlots)
    local data = K.Rewards.ReadItem(itemID)
    if not data then
        return false, 0, nil
    end
    local info = data.info
    if info.classID == 1 then
        return (freeSlots or 0) > 0, 1, data.name
    end
    local score = K.Rewards.Score(info, class, level) or 0
    local rec = K.Rewards.Evaluate({
        { index = 1, id = itemID, name = data.name, sellPrice = data.sellPrice, info = info },
    }, class, level, equippedInfo, nil)
    return rec ~= nil and rec.kind == "upgrade", score, data.name
end

local function sortedRouteIds()
    local ids = {}
    for id in pairs(K.routes) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

-- Missed key-reward candidates from earlier bands of the loaded route's branch chain.
function A.Scan(level)
    local E = K.Engine
    local cur = E.routeId and K.routes[E.routeId]
    if not cur then
        return {}
    end
    local completed = (K.Sync.lastResult and K.Sync.lastResult.completed) or {}
    local ignored = K.cdb.ignoredSuggestions or {}
    local player = K.player or {}
    local free = K.Helpers and K.Helpers.FreeSlots and K.Helpers.FreeSlots() or 0
    local seen, cands = {}, {}
    for _, routeId in ipairs(sortedRouteIds()) do
        local r = K.routes[routeId]
        if r.lo and cur.lo and r.lo < cur.lo then
            for _, s in ipairs(r.steps or {}) do
                if s.q and not seen[s.q] and A.Obtainable(s, level, completed, ignored)
                    and not E:HasDetour(s.q) then
                    seen[s.q] = true
                    local useful, score, name = A.Useful(s.rw.item, player.class, level, free)
                    if useful then
                        cands[#cands + 1] = { quest = s.q, route = routeId, score = score,
                            title = s.n or tostring(s.q), item = name or tostring(s.rw.item) }
                    end
                end
            end
        end
    end
    return cands
end

-- Shows the best missed reward. Go there and Ignore both show the next one.
function A.ShowMissed(manual)
    local level = (K.player and K.player.level) or UnitLevel("player") or 1
    local top = A.SelectMissed(A.Scan(level), 1)[1]
    if not top then
        if manual then
            K.Print(L.AUDIT_NONE)
        end
        return false
    end
    K.Toast.Show(string.format(L.MISSED_TEXT, top.title, top.item), 30, {
        { text = L.MISSED_GO, fn = function()
            K.Engine:GoThere(top.quest, top.route)
            A.ShowMissed(false)
        end },
        { text = L.MISSED_IGNORE, fn = function()
            K.cdb.ignoredSuggestions = K.cdb.ignoredSuggestions or {}
            K.cdb.ignoredSuggestions[top.quest] = true
            A.ShowMissed(false)
        end },
    })
    K.Log("missed reward suggested", top.quest, top.route)
    return true
end

-- The audit (PRD 7.10): the radar first, otherwise the missed rewards.
function A.Run(manual)
    local E = K.Engine
    if not E.routeId or not K.player then
        if manual then
            K.Print(L.AUDIT_NONE)
        end
        return false
    end
    local level = K.player.level or UnitLevel("player") or 1
    local mapID = C.GetBestMapForPlayer()
    local zone = mapID and K.zones and K.zones[mapID]
    local _, cursor = E:Current()
    if zone and cursor and cursor.z and A.RadarFires(zone[3], level, mapID, cursor.z) then
        local target = K.zones[cursor.z]
        K.Toast.Show(string.format(L.RADAR_TEXT, zone[1], zone[2], zone[3],
            target and target[1] or tostring(cursor.z), cursor.x or 0, cursor.y or 0), 30)
        K.Log("zone radar fired", mapID, "for", cursor.z)
        return true
    end
    return A.ShowMissed(manual)
end

-- Runs after every completed-quest sync. The first sync of a character runs the audit, and so
-- does a sync after a jump of 3+ levels. A sync that asked a question (jump or gear) defers it.
K.Sync.afterSync[#K.Sync.afterSync + 1] = function()
    if K.Sync.asked then
        return
    end
    if K.Sync.pendingAudit or not K.cdb.auditDone then
        K.Sync.pendingAudit = nil
        K.cdb.auditDone = true
        A.Run(false)
    end
end
