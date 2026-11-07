-- Core: namespace, event dispatch, SavedVariables, player detection, debug log, slash commands.
local ADDON, K = ...
local L = K.L

K.name = ADDON
K.SCHEMA = 1
K.player = K.player or {}

-- Phase 18: which step engine runs. "legacy" is the band engine (Engine.lua with Sync and Audit).
-- A later engine registers itself in K.engines; until then any other value falls back to legacy.
-- The choice is KlimaxDB.options.engine, set with /klimax engine <name> and applied on /reload.
K.engines = K.engines or {}

function K.EngineMode()
    local want = K.db and K.db.options and K.db.options.engine
    if want and K.engines[want] then
        return want
    end
    return "legacy"
end

local function engineNames()
    local names = {}
    for name in pairs(K.engines) do
        names[#names + 1] = name
    end
    table.sort(names)
    return table.concat(names, ", ")
end

-- ---- Event frame and dispatcher -------------------------------------------------------------

K.frame = CreateFrame("Frame")
K.handlers = K.handlers or {}
K.tickers = K.tickers or {}

-- Registers fn for an event. The frame listens only to events that have at least one handler.
function K.On(event, fn)
    local list = K.handlers[event]
    if not list then
        list = {}
        K.handlers[event] = list
        K.frame:RegisterEvent(event)
    end
    list[#list + 1] = fn
end

-- Runs every handler for an event. A failing handler is logged, never raised to the game.
function K.Dispatch(event, ...)
    local list = K.handlers[event]
    if not list then
        return
    end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            K.Log("error in", event, tostring(err))
        end
    end
end

-- Runs fn every `interval` seconds from OnUpdate (no timers are created per call).
function K.Every(interval, fn)
    K.tickers[#K.tickers + 1] = { interval = interval, fn = fn, elapsed = 0 }
end

K.frame:SetScript("OnEvent", function(_, event, ...)
    K.Dispatch(event, ...)
end)

K.frame:SetScript("OnUpdate", function(_, elapsed)
    for i = 1, #K.tickers do
        local t = K.tickers[i]
        t.elapsed = t.elapsed + elapsed
        if t.elapsed >= t.interval then
            t.elapsed = 0
            local ok, err = pcall(t.fn)
            if not ok then
                K.Log("error in ticker", tostring(err))
            end
        end
    end
end)

-- ---- Debug log (ring buffer) ------------------------------------------------------------------

local RING_MAX = 200
local ring = {}
local ringPos = 0
local ringCount = 0

function K.Log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    ringPos = ringPos % RING_MAX + 1
    ring[ringPos] = string.format("%.1f %s", GetTime and GetTime() or 0, table.concat(parts, " "))
    if ringCount < RING_MAX then
        ringCount = ringCount + 1
    end
end

-- Log lines, oldest first.
function K.LogLines()
    local out = {}
    for i = 1, ringCount do
        out[i] = ring[((ringPos - ringCount + i - 1) % RING_MAX) + 1]
    end
    return out
end

function K.Print(msg)
    local text = "|cff33ff99Klimax|r: " .. tostring(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    else
        print(text)
    end
end

-- ---- SavedVariables ---------------------------------------------------------------------------

-- Brings an account-wide table up to the current schema. Each migration step is idempotent.
local function migrateAccount(db)
    db.version = db.version or 0
    if db.version < 1 then
        db.options = db.options or {}
        db.version = 1
    end
    db.options = db.options or {}
    return db
end

local function migrateCharacter(cdb)
    cdb.version = cdb.version or 0
    if cdb.version < 1 then
        cdb.stepState = cdb.stepState or {}
        cdb.version = 1
    end
    cdb.stepState = cdb.stepState or {}
    cdb.ignoredSuggestions = cdb.ignoredSuggestions or {}
    cdb.elitePending = cdb.elitePending or {}
    return cdb
end

function K.InitSavedVariables()
    KlimaxDB = migrateAccount(KlimaxDB or {})
    KlimaxCharDB = migrateCharacter(KlimaxCharDB or {})
    K.db = KlimaxDB
    K.cdb = KlimaxCharDB
    K.version = K.Compat.GetAddOnMetadata(ADDON, "Version") or "dev"
end

K.On("ADDON_LOADED", function(name)
    if name == ADDON then
        K.InitSavedVariables()
        K.Log("saved variables ready, schema", K.cdb.version)
    end
end)

-- ---- Player detection -------------------------------------------------------------------------

-- Reads faction, race, class token and level. Missing values stay nil; the caller decides what to do.
function K.Detect()
    local p = {}
    local factionLocal, factionEn = UnitFactionGroup("player")
    p.faction = factionEn or factionLocal
    local raceLocal, raceToken = UnitRace("player")
    p.race = raceLocal
    p.raceToken = raceToken
    local _, classToken = UnitClass("player")
    p.class = classToken
    p.level = UnitLevel("player") or 1
    K.player = p
    return p
end

-- ---- Slash commands ---------------------------------------------------------------------------

SLASH_KLIMAX1 = "/klimax"
SLASH_KLIMAX2 = "/kx"

-- Handles "/klimax ..."; returns nothing. The engine and sync are looked up at call time.
function K.Command(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        if K.UI then
            K.UI.Toggle()
        else
            K.Print(L.HELP)
        end
    elseif cmd == "debug" then
        K.DebugDump()
    elseif cmd == "sync" then
        K.Sync:RunAndReport()
    elseif cmd == "reset" then
        if rest:lower() == "all" then
            K.Engine:Reset("all")
            K.Print(L.RESET_ALL)
        else
            K.Engine:Reset("band")
            K.Print(string.format(L.RESET_BAND, K.Engine.routeId or "?"))
        end
    elseif cmd == "band" then
        local ok, reason = K.Engine:JumpToBand(rest)
        if not ok then
            K.Print(string.format(L.UNKNOWN_BAND, rest))
            K.Log("band jump failed", reason)
        end
    elseif cmd == "dev" then
        K.DevCommand(rest)
    elseif cmd == "dump" then
        K.Diag.Dump()
    elseif cmd == "audit" then
        if rest:lower() == "state" then
            K.Diag.ReportState()
        else
            K.Audit.Run(true)
        end
    elseif cmd == "engine" then
        K.EngineCommand(rest)
    else
        K.Print(L.HELP)
    end
end

SlashCmdList["KLIMAX"] = function(msg)
    K.Command(msg)
end

-- "/klimax engine" prints the selected engine; "/klimax engine <name>" selects a registered one.
function K.EngineCommand(rest)
    local name = (rest or ""):lower()
    if name == "" then
        K.Print(string.format(L.ENGINE_CURRENT, K.EngineMode(), engineNames()))
    elseif K.engines[name] then
        K.db.options = K.db.options or {}
        K.db.options.engine = name
        K.Print(string.format(L.ENGINE_SET, name))
    else
        K.Print(string.format(L.ENGINE_UNKNOWN, name, engineNames()))
    end
end

-- Dev-only helpers (phase 08). "dev level N" fakes the level for the engine and the elite module,
-- so the elite reminder can be tested without leveling. The character's real level is unchanged,
-- and the next login reads it again.
function K.DevCommand(rest)
    local sub, arg = (rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
    local n = tonumber(arg)
    if (sub or ""):lower() ~= "level" or not n or n < 1 or n > 60 then
        K.Print(L.DEV_USAGE)
        return
    end
    K.player = K.player or {}
    K.player.level = math.floor(n)
    K.Engine:Recompute()
    if K.Elite then
        K.Elite.Check()
    end
    K.Print(string.format(L.DEV_LEVEL, K.player.level))
end

-- Prints the detected player, route, cursor step and the last debug lines.
function K.DebugDump()
    local p = K.player or {}
    K.Print(string.format("player: %s %s %s lvl %s", tostring(p.faction), tostring(p.race),
        tostring(p.class), tostring(p.level)))
    local E = K.Engine
    K.Print("route: " .. tostring(E.routeId))
    if K.Arrow and K.UI then
        local a = K.Arrow.Read()
        K.Print(string.format("arrow: %s rot %s dist %s facing %s window %s",
            tostring(a.kind), tostring(a.rot), tostring(a.dist), tostring(K.Compat.GetFacing()),
            K.UI.frame and tostring(K.UI.frame:IsShown()) or "not built"))
    end
    local i, step, state = E:Current()
    if step then
        K.Print(string.format("step %d/%d [%s] %s %s", i, #E.steps, step.t, tostring(step.n or step.note), state))
    else
        K.Print("no current step")
    end
    local lines = K.LogLines()
    local from = math.max(1, #lines - 9)
    for n = from, #lines do
        K.Print(lines[n])
    end
end
