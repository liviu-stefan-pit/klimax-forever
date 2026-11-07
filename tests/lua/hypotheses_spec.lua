-- Phase 18 hypothesis evidence. Each spec shows, on the legacy engine, one mechanism that can
-- produce a symptom from the level 15 Hunter report (docs/DYNAMIC_GUIDE_PLAN.md s1). They PASS
-- because they assert what the legacy engine does today; the verdicts are in docs/PROGRESS.md
-- (phase 18). The correct behaviour is encoded in known_failing_spec.lua.
--
--   H1  wrong "done" marks come from event/sync heuristics, not from the game's quest state
--   H2  stale turn-ins to places that do not make sense
--   H3  the order is a fixed script, blind to where the player is
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local Fx = require("fixture")

local function start(steps, opts)
    local K = W.start(W.merge({ skipRoutes = true }, opts))
    W.registerRoute({ id = "hyp", faction = "horde", branch = "horde", lo = 1, hi = 20, steps = steps })
    K.Detect()
    assert(K.Engine:Load("hyp"))
    K.cdb.routeId = "hyp"
    return K
end

local function state(K, k)
    return K.Engine.eff[K.Engine.byKey[k]]
end

describe("H1 wrong done marks", function()
    it("H1a: Next on an ACCEPT marks the whole NPC batch, even a quest the game never gave", function()
        -- Thork at the Crossroads gives 872 (needs 871) and 5041 back to back.
        local K = start({
            { t = "A", k = "A872", q = 872, g = "m", z = 1413, x = 51.5, y = 30.9, npc = 3429, po = { 871 } },
            { t = "A", k = "A5041", q = 5041, g = "m", z = 1413, x = 51.5, y = 30.9, npc = 3429 },
            { t = "C", k = "C872", q = 872, g = "m", z = 1413, x = 58, y = 25 },
        })
        W.setQuestLog(5041, false)      -- only 5041 could be accepted
        K.Engine:Next()
        assert.are.equal("done", state(K, "A872"))
        assert.are.equal("C872", K.Engine.steps[K.Engine.cursor].k)   -- objective of a quest not in the log
    end)

    it("H1b: a stored done is never re-checked, so an abandoned quest keeps its turn-in", function()
        local K = start({
            { t = "A", k = "A877", q = 877, g = "m", z = 1413, x = 52.3, y = 31.9, npc = 3448 },
            { t = "T", k = "T877", q = 877, g = "m", z = 1413, x = 52.3, y = 31.9, npc = 3448 },
        })
        W.setQuestLog(877, false)
        W.fire("QUEST_ACCEPTED", 1, 877)
        W.clearQuestLog()               -- abandoned
        K.Sync:Run()
        W.flushTimers()
        assert.are.equal("done", state(K, "A877"))
        assert.are.equal("T877", K.Engine.steps[K.Engine.cursor].k)
    end)

    it("H1c: a failed quest (Classic isComplete = -1) counts as complete", function()
        local K = start({
            { t = "A", k = "A1", q = 1, g = "m", z = 1, x = 1, y = 1, npc = 1 },
            { t = "C", k = "C1", q = 1, g = "m", z = 1, x = 5, y = 5 },
            { t = "T", k = "T1", q = 1, g = "m", z = 1, x = 1, y = 1, npc = 1 },
        }, { legacy = true })
        W.setQuestLog(1, -1)
        K.Engine:CheckQuestLog()
        assert.are.equal("done", state(K, "C1"))
        assert.are.equal("T1", K.Engine.steps[K.Engine.cursor].k)
    end)

    it("H1d: a quest under a collapsed header looks absent, so the level sync archives it", function()
        local K = start({
            { t = "A", k = "A751", q = 751, g = "o", ql = 8, z = 1412, x = 52, y = 53 },
            { t = "T", k = "T751", q = 751, g = "o", ql = 8, z = 1412, x = 54.8, y = 64.3, npc = 2988 },
        })
        K.cdb.stepState.hyp = { A751 = "done" }
        K.Engine:Recompute()
        W.state.logList = {
            { isHeader = true, title = "Mulgore", isCollapsed = true },
            { questID = 751, title = "The Ravaged Caravan", isComplete = 1 },
        }
        W.state.level = 15
        K.player.level = 15
        K.Sync:LevelSync({ completed = {}, log = K.Compat.GetQuestLog() })
        assert.are.equal("archived", state(K, "T751"))
    end)

    it("H1e: archived steps are drawn in the same colour as done steps", function()
        local f = assert(io.open("Klimax/UI.lua", "r"))
        local src = f:read("*a")
        f:close()
        local colors = assert(src:match("local STATE_COLOR = (%b{})"))
        assert.are.equal(colors:match("done = (%b{})"), colors:match("archived = (%b{})"))
    end)

    it("H1f: closing any merchant or trainer marks the cursor BUY or TRAINER step", function()
        local K = start({
            { t = "B", k = "B1", z = 1413, x = 51.7, y = 29.9, note = "ammo at the Crossroads" },
            { t = "R", k = "R1", z = 1454, x = 66, y = 18, note = "Hunter trainer, Orgrimmar" },
        })
        W.fire("MERCHANT_CLOSED")       -- any vendor, anywhere
        assert.are.equal("done", state(K, "B1"))
        W.fire("TRAINER_SHOW")          -- a profession trainer, say
        W.fire("TRAINER_CLOSED")
        assert.are.equal("done", state(K, "R1"))
    end)

    it("H1g: prerequisites are checked only inside the loaded band", function()
        -- 871 was skipped in Durotar 05-10; the 10-15 band still offers 872, which needs it.
        local K = start({
            { t = "A", k = "A872", q = 872, g = "m", z = 1413, x = 51.5, y = 30.9, npc = 3429, po = { 871 } },
        })
        assert.are.equal("pending", state(K, "A872"))
        assert.are.equal(1, K.Engine.cursor)
    end)

    it("H1h: QUEST_ACCEPTED with only a log index would be read as a quest id", function()
        local K = start({
            { t = "A", k = "A2", q = 2, g = "m", z = 1, x = 1, y = 1, npc = 1 },
        })
        W.fire("QUEST_ACCEPTED", 2)     -- (questLogIndex) only, if a client sent that
        assert.are.equal("done", state(K, "A2"))
    end)
end)

describe("H2 stale turn-ins", function()
    it("H2a: without a completed-quest API, a quest turned in while the add-on was off stays", function()
        local K = start({
            { t = "A", k = "A870", q = 870, g = "m", z = 1413, x = 52.3, y = 31.9, npc = 3448 },
            { t = "T", k = "T870", q = 870, g = "m", z = 1413, x = 52.3, y = 31.9, npc = 3448 },
        }, { legacy = true })
        K.cdb.stepState.hyp = { A870 = "done" }
        W.unset("IsQuestFlaggedCompleted")
        W.unset("GetQuestsCompleted")
        W.state.completed[870] = true
        W.registerIndex({ routes = {}, start = {}, quests = { [870] = { "hyp" } } })
        K.Sync:Run()
        W.flushTimers()
        assert.are.equal("pending", state(K, "T870"))
    end)

    it("H2b: a turn-in's place is fixed at compile time and never checked against the game", function()
        local fx = Fx.load("hunter15_synthetic")
        local K = Fx.start(fx)
        local i = K.Engine.byKey["horde_horde_10-15:T:853:0"]
        local s = K.Engine.steps[i]
        -- 853 failed in the log, yet its turn-in in Thunder Bluff is still pending, with fixed coordinates.
        assert.are.equal("pending", K.Engine.eff[i])
        assert.are.equal(1456, s.z)
        assert.are.same({ 22.8, 20.9 }, { s.x, s.y })
    end)

    it("H2c: the missed-reward audit ignores the start branch, race and class", function()
        local fx = Fx.load("hunter15_synthetic")
        local K = Fx.start(fx)
        K.Audit.Useful = function() return true, 1, "item" end
        local offered = {}
        for _, c in ipairs(K.Audit.Scan(15)) do
            offered[c.quest] = c.route
        end
        assert.are.equal("horde_zephras_05-10", offered[92880])   -- Zephra's Isle, never visited by this Orc
        assert.are.equal("horde_mulgore_05-10", offered[744])      -- Mulgore/Thunder Bluff branch
        assert.are.equal("horde_mulgore_05-10", offered[760])      -- Tauren only
        assert.are.equal("horde_tirisfal_05-10", offered[1822])    -- Warrior only
        -- Go there inserts the Zephra's Isle accept and turn-in into the Barrens band.
        local added = K.Engine:GoThere(92880, "horde_zephras_05-10")
        assert.are.equal(2, added)
        local _, cursor = K.Engine:Current()
        assert.are.equal(2521, cursor.z)
    end)
end)

describe("H2 start branch", function()
    it("H2d: the start branch comes from the race, so a Zephra's Isle Orc is sent to Durotar", function()
        local K = W.start()
        W.state.level = 6
        W.state.mapID, W.state.pos = 2521, { x = 0.45, y = 0.44 }   -- standing on Zephra's Isle
        W.state.completed[92460] = true                              -- first Zephra's Isle quests done
        W.state.completed[92461] = true
        local id = K.Engine.ChooseRoute(K.Detect())
        assert.are.equal("horde_durotar_05-10", id)
    end)
end)

describe("H3 fixed order", function()
    it("H3a: the cursor is the first pending step in route order, wherever the player stands", function()
        local K = start({
            { t = "T", k = "Tfar", q = 1, g = "m", z = 1411, x = 52, y = 43, npc = 1 },   -- Razor Hill
            { t = "T", k = "Tnear", q = 2, g = "m", z = 1413, x = 52, y = 30, npc = 2 },  -- Crossroads
        })
        W.setQuestLog(1, true)
        W.setQuestLog(2, true)
        W.state.mapID, W.state.pos = 1413, { x = 0.52, y = 0.30 }
        K.Engine:CheckPosition()
        assert.are.equal("Tfar", K.Engine.steps[K.Engine.cursor].k)
    end)

    it("H3b: at level 15 the band offers a jump only when the cursor is two levels behind", function()
        local fx = Fx.load("hunter15_synthetic")
        local K = Fx.start(fx)
        local _, step = K.Engine:Current()
        assert.are.equal(10, step.el)   -- level-10 content while the player is 15
        assert.are.equal(15, K.cdb.declined["horde_horde_15-20"])
    end)
end)
