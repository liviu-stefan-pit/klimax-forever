-- Elite module (PRD 7.11). An optional-elite step is kept in the route with its chip. When the player
-- skips one that has revisitAt, it is stored in KlimaxCharDB.elitePending. When the player reaches
-- that level and is in the same zone, one reminder appears: "Add to route" or "Dismiss".
--
-- States: waiting (stored, not yet shown), reminded (shown once), added, dismissed.
local _, K = ...
local L = K.L
local C = K.Compat

local EL = {}
K.Elite = EL

EL.WAITING, EL.REMINDED, EL.ADDED, EL.DISMISSED = "waiting", "reminded", "added", "dismissed"

-- Whether a stored entry should be reminded now: waiting, at or past revisitAt, in its zone.
function EL.ShouldRemind(entry, level, mapID)
    if not entry or entry.state ~= EL.WAITING or not entry.revisitAt then
        return false
    end
    if level == nil or level < entry.revisitAt then
        return false
    end
    return mapID ~= nil and mapID == entry.z
end

-- Storage key: route and stable step key.
function EL.Key(routeId, k)
    return tostring(routeId) .. "|" .. tostring(k)
end

-- Called by the engine when a step is skipped. Stores optional-elite steps that have revisitAt.
-- Compiled steps carry revisitAt as `rv` (see pipeline/routes/compile_routes.py).
function EL.OnSkip(step, routeId)
    if not step or step.g ~= "e" or not step.rv or not routeId then
        return false
    end
    K.cdb.elitePending = K.cdb.elitePending or {}
    K.cdb.elitePending[EL.Key(routeId, step.k)] = {
        route = routeId, k = step.k, title = step.n or "?", revisitAt = step.rv, z = step.z,
        reward = step.rw and step.rw.why or nil, state = EL.WAITING,
    }
    K.Log("elite stored for revisit", step.n or "?", "at", step.revisitAt)
    return true
end

-- Puts a skipped step back into its route.
function EL.AddToRoute(entry)
    entry.state = EL.ADDED
    if K.Engine.routeId == entry.route then
        K.Engine:Unskip(entry.k)
    else
        local st = K.cdb.stepState and K.cdb.stepState[entry.route]
        if st then
            st[entry.k] = nil
        end
    end
end

function EL.Dismiss(entry)
    entry.state = EL.DISMISSED
end

-- Reminder text for an entry.
function EL.Text(entry)
    if entry.reward and entry.reward ~= "" then
        return string.format(L.ELITE_TEXT, entry.title, entry.reward)
    end
    return string.format(L.ELITE_TEXT_PLAIN, entry.title)
end

-- Shows the first entry due for a reminder. Only one reminder is shown per check.
function EL.Check()
    if not K.cdb or not K.cdb.elitePending then
        return false
    end
    local level = (K.player and K.player.level) or UnitLevel("player")
    local mapID = C.GetBestMapForPlayer()
    local keys = {}
    for key in pairs(K.cdb.elitePending) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local entry = K.cdb.elitePending[key]
        if EL.ShouldRemind(entry, level, mapID) then
            entry.state = EL.REMINDED
            K.Toast.Show(EL.Text(entry), 30, {
                { text = L.ELITE_ADD, fn = function() EL.AddToRoute(entry) end },
                { text = L.ELITE_DISMISS, fn = function() EL.Dismiss(entry) end },
            })
            return true
        end
    end
    return false
end

K.On("PLAYER_LEVEL_UP", function()
    EL.Check()
end)

K.On("ZONE_CHANGED_NEW_AREA", function()
    EL.Check()
end)

K.On("PLAYER_LOGIN", function()
    EL.Check()
end)
