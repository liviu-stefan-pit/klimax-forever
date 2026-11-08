-- Save-state fixtures for the busted specs (phase 18).
--
-- A fixture is the JSON written by `python -m pipeline fixture` from a `/klimax dump` (or a
-- hand-built file with the same shape, see tests/README.md). Fx.start(fx) installs it in
-- the WoW stubs (player, position, quest log, completed quests, saved variables), loads the whole
-- add-on, logs in and lets the state scan finish, so a spec can
-- replay what the character saw. JSON is read with dkjson, which ships with busted.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local json = require("dkjson")

local Fx = {}

Fx.DIR = "tests/fixtures/"

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deepCopy(v)
    end
    return out
end

-- JSON object keys are strings. Step-state keys are strings already; the add-on reads the
-- tables below with number keys, so they are converted back.
local function numberKeys(map)
    local out = {}
    for k, v in pairs(map or {}) do
        out[tonumber(k) or k] = v
    end
    return out
end

-- Reads tests/fixtures/<name>.json (or a path) and returns the decoded table.
function Fx.load(name)
    local path = name:find("[/\\]") and name or (Fx.DIR .. name .. ".json")
    local f = assert(io.open(path, "r"), "fixture not found: " .. path)
    local text = f:read("*a")
    f:close()
    local data, _, err = json.decode(text, 1, nil)
    assert(data, "bad fixture JSON in " .. path .. ": " .. tostring(err))
    return data
end

-- The quest log lines of a fixture in the shape of W.state.logList.
function Fx.logList(fx)
    local out = {}
    for _, line in ipairs(fx.questLog or {}) do
        if line.header then
            out[#out + 1] = { isHeader = true, title = line.title, isCollapsed = line.collapsed or false }
        else
            local objectives = {}
            for _, o in ipairs(line.objectives or {}) do
                objectives[#objectives + 1] = { text = o.text, type = o.type, finished = o.finished,
                    numFulfilled = o.have, numRequired = o.need }
            end
            out[#out + 1] = { questID = line.questID, title = line.title, level = line.level,
                isComplete = line.complete, objectives = objectives }
        end
    end
    return out
end

-- The character's SavedVariables rebuilt from the fixture's engine block. Phase 29: only the
-- player's choices carry over (skipped quests); the old band progress is not read any more.
function Fx.charDB(fx)
    local e = fx.engine or {}
    return {
        version = 3,
        skipQuests = numberKeys(e.skipQuests),
        hiddenSteps = deepCopy(e.hiddenSteps or {}),
        brokenQuests = numberKeys(e.brokenQuests),
    }
end

-- Installs the fixture in fresh stubs and loads the add-on. opts.login = false stops before
-- PLAYER_LOGIN (the caller then fires it); opts.skipRoutes is passed to the loader.
-- Returns the add-on table K.
function Fx.start(fx, opts)
    opts = opts or {}
    local api = fx.api or {}
    W.reset({ legacy = api.questLog ~= "C_QuestLog" })
    local p = fx.player or {}
    local s = W.state
    s.faction = p.faction or s.faction
    s.race = p.race or s.race
    s.raceToken = p.raceToken or p.race or s.raceToken
    s.class = p.class or s.class
    s.level = p.level or s.level
    s.xp, s.xpMax, s.rested = p.xp or 0, p.xpMax or 1000, p.rested
    local pos = fx.position or {}
    s.mapID = pos.mapID or s.mapID
    s.pos = { x = pos.x or 0.5, y = pos.y or 0.5 }
    s.zoneText = pos.zone or s.zoneText
    s.subzoneText = pos.subzone or ""
    s.logList = Fx.logList(fx)
    s.completed = {}
    for _, id in ipairs(fx.completed or {}) do
        s.completed[id] = true
    end
    for _, id in ipairs(fx.completedSet or {}) do
        s.completed[id] = true
    end
    -- The client's completed-quest API as recorded by the dump.
    if api.completed == nil and fx.completedKnown == false then
        W.unset("IsQuestFlaggedCompleted")
        W.unset("GetQuestsCompleted")
        if C_QuestLog then
            C_QuestLog.IsQuestFlaggedCompleted = nil
        end
    elseif api.completed == "set" then
        W.unset("IsQuestFlaggedCompleted")
    end
    KlimaxDB = { version = 1, options = deepCopy(fx.options or {}) }
    KlimaxCharDB = Fx.charDB(fx)
    local K = W.loadAddon({ skipRoutes = opts.skipRoutes })
    W.fire("ADDON_LOADED", "Klimax")
    if opts.login ~= false then
        Fx.login()
    end
    return K
end

-- PLAYER_LOGIN and the first QUEST_LOG_UPDATE the client sends after it, each followed by every
-- queued timer (the login sync runs in frame slices, the log check after a one-second timer).
function Fx.login()
    W.fire("PLAYER_LOGIN")
    W.flushTimers()
    W.fire("QUEST_LOG_UPDATE")
    W.flushTimers()
end

-- Index of the plan step with stable key k, or nil.
function Fx.indexOf(K, k)
    return K.Engine.byKey[k]
end

Fx.W = W
return Fx
