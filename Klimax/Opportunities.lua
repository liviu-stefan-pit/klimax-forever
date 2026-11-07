-- On-the-way opportunities (PRD 7.12). Location-based hints for known rares and chests, plus an
-- optional nameplate check for rare mobs. Hints are short toasts with a cooldown per spawn, so the
-- player is not spammed. Nothing here detects live mobs except the nameplate rarity flag, which the
-- client exposes without any protected call.
local _, K = ...
local L = K.L
local C = K.Compat

local O = {}
K.Opportunities = O

O.RADIUS = 8.0          -- map percent: about 80 yards in a typical zone
O.COOLDOWN = 3600       -- seconds before the same spawn is hinted again
O.PLATE_COOLDOWN = 900  -- seconds before the same nameplate rare name is hinted again
O.RARE_ABOVE = 2        -- a rare up to this many levels above the player is shown
O.RARE_BELOW = 8        -- and down to this many below (grey-ish rares are not worth it)
O.SCAN_EVERY = 2        -- seconds between location scans

-- Whether a rare is worth a hint at the player's level.
function O.LevelOk(hi, level)
    return hi <= level + O.RARE_ABOVE and hi >= level - O.RARE_BELOW
end

-- Nearest spawn point of zones[mapID] within radius (map percent), as index and distance, or nil.
function O.Nearest(zones, mapID, x, y, radius)
    local pts = zones and zones[mapID]
    if not pts then
        return nil
    end
    local best, bestD
    for i, p in ipairs(pts) do
        local dx, dy = p[1] - x, p[2] - y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= radius and (not bestD or d < bestD) then
            best, bestD = i, d
        end
    end
    return best, bestD
end

-- Whether a key is still cooling down at time now. seen[key] holds the time it may fire again.
function O.OnCooldown(seen, key, now)
    local t = seen and seen[key]
    return t ~= nil and now < t
end

function O.Mark(seen, key, now, cooldown)
    seen[key] = now + cooldown
end

-- Stable key of a spawn point: entity kind, id, zone and the point rounded to a whole percent.
function O.SpawnKey(kind, id, mapID, x, y)
    return string.format("%s:%s:%d:%d:%d", kind, tostring(id), mapID, math.floor(x + 0.5), math.floor(y + 0.5))
end

local function seenTable()
    K.cdb.oppSeen = K.cdb.oppSeen or {}
    return K.cdb.oppSeen
end

local function enabled()
    return K.Option("opportunities") ~= false
end

-- Shows a hint for a key unless it is cooling down. Returns true when shown.
local function hint(key, cooldown, text)
    local seen = seenTable()
    local now = time and time() or 0
    if O.OnCooldown(seen, key, now) then
        return false
    end
    O.Mark(seen, key, now, cooldown)
    K.Toast.Show(text, 8)
    K.Log("opportunity", key)
    return true
end

local function rareText(r)
    local lvl = (r.lo == r.hi) and tostring(r.hi) or string.format("%d-%d", r.lo, r.hi)
    if r.drops and #r.drops > 0 then
        return string.format(L.OPP_RARE_DROPS, r.name, lvl, table.concat(r.drops, ", "))
    end
    return string.format(L.OPP_RARE, r.name, lvl)
end

-- Checks the player's position against the rares and chests of the current zone. One hint at most
-- per scan, so several spawns in reach do not stack.
function O.Scan()
    if not enabled() or not K.Rares or not K.Chests then
        return false
    end
    local mapID = C.GetBestMapForPlayer()
    local pos = mapID and C.GetPlayerMapPosition(mapID)
    if not pos then
        return false
    end
    local x, y = pos.x * 100, pos.y * 100
    local level = (K.player and K.player.level) or 1
    for _, r in ipairs(K.Rares) do
        local idx = r.zones[mapID] and O.LevelOk(r.hi, level) and O.Nearest(r.zones, mapID, x, y, O.RADIUS)
        if idx then
            local p = r.zones[mapID][idx]
            if hint(O.SpawnKey("rare", r.id, mapID, p[1], p[2]), O.COOLDOWN, rareText(r)) then
                return true
            end
        end
    end
    for _, c in ipairs(K.Chests) do
        local idx = c.zones[mapID] and O.Nearest(c.zones, mapID, x, y, O.RADIUS)
        if idx then
            local p = c.zones[mapID][idx]
            if hint(O.SpawnKey("chest", c.id, mapID, p[1], p[2]), O.COOLDOWN, string.format(L.OPP_CHEST, c.name)) then
                return true
            end
        end
    end
    return false
end

-- Nameplate rares (PRD 7.12, optional). Only the rarity flag is read; it is not a protected call.
function O.OnNamePlate(unit)
    if not enabled() or not unit then
        return false
    end
    local cls = UnitClassification and UnitClassification(unit)
    if cls ~= "rare" and cls ~= "rareelite" then
        return false
    end
    local name = (UnitName and UnitName(unit)) or "?"
    local seen = seenTable()
    local key = "plate:" .. name
    local now = time and time() or 0
    if O.OnCooldown(seen, key, now) then
        return false
    end
    O.Mark(seen, key, now, O.PLATE_COOLDOWN)
    K.Toast.Show(string.format(L.OPP_PLATE, name), 6)
    return true
end

K.Every(O.SCAN_EVERY, function()
    O.Scan()
end)

K.On("NAME_PLATE_UNIT_ADDED", function(unit)
    O.OnNamePlate(unit)
end)
