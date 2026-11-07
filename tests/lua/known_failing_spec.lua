-- KNOWN FAILING (phase 18): the level 15 Hunter replay, with the CORRECT behaviour encoded.
--
-- These specs fail on the legacy engine, for the reasons listed in docs/PROGRESS.md (phase 18),
-- and are the acceptance tests for phases 20 (snapshot and reconciler) and 21 (planner). To keep
-- the default run green they are registered as PENDING unless KLIMAX_KNOWNFAIL is set:
--
--   tests/lua/busted.cmd tests/lua                 -> listed as pending ("KNOWN FAILING ...")
--   tests/lua/knownfail.cmd                        -> runs them; they are expected to FAIL
--
-- When a phase makes one pass, move it to a normal spec file (do not just delete the guard).
-- Category tags follow the phase 18 failure list: [state], [data], [ordering].
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local Fx = require("fixture")

local RUN = os.getenv("KLIMAX_KNOWNFAIL") ~= nil and os.getenv("KLIMAX_KNOWNFAIL") ~= ""

-- `it` when KLIMAX_KNOWNFAIL is set, otherwise a labelled pending entry.
local function known(name, fn)
    if RUN then
        it(name, fn)
    else
        pending("KNOWN FAILING " .. name)
    end
end

local R = "horde_horde_10-15:"

local function replay(mutate)
    local fx = Fx.load("hunter15_synthetic")
    if mutate then
        mutate(fx)
    end
    return Fx.start(fx), fx
end

local function inLog(K, q)
    local log = K.Diag.ReadLog()
    return log[q] ~= nil
end

describe("level 15 Hunter replay (synthetic fixture)", function()
    known("[state] KF1: Next on Thork's batch does not mark 872 accepted when the game never gave it", function()
        local K = replay()
        assert.are_not.equal("done", Fx.stateOf(K, R .. "A:872:0"),
            "872 needs 871 (skipped in Durotar) and is not in the log, yet its ACCEPT is done")
    end)

    known("[state] KF2: a quest in the log is not archived as outgrown (751 under a collapsed header)", function()
        local K = replay()
        assert.are_not.equal("archived", Fx.stateOf(K, R .. "T:751:0"),
            "751 is complete in the quest log (collapsed Mulgore header) but the level sync archived its turn-in")
    end)

    known("[state] KF3: no turn-in is pending for a quest the game shows failed or not in the log", function()
        local K = replay()
        local bad = {}
        for _, d in ipairs(K.Diag.Check()) do
            if d.kind == "turnin-not-in-log" or d.kind == "pending-failed" then
                bad[#bad + 1] = d.k .. " (" .. d.game .. ")"
            end
        end
        assert.are.same({}, bad)
    end)

    known("[state] KF4: the current step is never an objective or turn-in of a quest not in the log", function()
        local K = replay()
        local _, step = K.Engine:Current()
        assert.is_table(step)
        if step.t == "C" or step.t == "T" then
            assert.is_true(inLog(K, step.q), "cursor " .. step.k .. " is for quest " .. step.q .. ", not in the log")
        end
    end)

    known("[state] KF5: the guide agrees with the game for every quest step", function()
        local K = replay()
        local lines = {}
        for _, d in ipairs(K.Diag.Check()) do
            if d.q ~= 751 then   -- 751 is in the log, hidden by its collapsed header (KF2 covers it)
                lines[#lines + 1] = string.format("%s q%d game=%s engine=%s %s", d.k, d.q, d.game, d.engine, d.kind)
            end
        end
        assert.are.same({}, lines)
    end)

    known("[state] KF6: an ACCEPT whose prerequisite the game shows not completed is not the current step", function()
        local K = replay(function(fx)
            local st = fx.engine.stepState["horde_horde_10-15"]
            st[R .. "A:872:0"] = nil   -- the player did not press Next at Thork
        end)
        local _, step = K.Engine:Current()
        assert.are_not.equal(R .. "A:872:0", step.k, "871 is not completed, so 872 cannot be accepted")
    end)

    known("[state] KF7: without a completed-quest API, a turn-in for a quest not in the log is not shown", function()
        local K = replay(function(fx)
            fx.api.completed = nil
            fx.completedKnown = false
            local st = fx.engine.stepState["horde_horde_10-15"]
            for k in pairs(st) do
                if k:find(":T:", 1, true) then
                    st[k] = nil            -- the turn-ins were never seen by the add-on
                end
            end
        end)
        local stale = {}
        for i, s in ipairs(K.Engine.steps) do
            if s.t == "T" and K.Engine.eff[i] == "pending" and not inLog(K, s.q) then
                local accepted = false
                for j, a in ipairs(K.Engine.steps) do
                    if a.t == "A" and a.q == s.q and K.Engine.eff[j] == "done" then
                        accepted = true
                    end
                end
                if accepted and i <= (K.Engine.cursor or 0) + 20 then
                    stale[#stale + 1] = s.k
                end
            end
        end
        assert.are.same({}, stale)
    end)

    known("[data] KF8: the missed-reward audit offers nothing from another start branch, race or class", function()
        local K = replay()
        K.Audit.Useful = function() return true, 1, "item" end
        local wrong = {}
        for _, c in ipairs(K.Audit.Scan(15)) do
            if not (c.route:find("durotar", 1, true) or c.route:find("horde_horde", 1, true)) then
                wrong[#wrong + 1] = c.quest .. "@" .. c.route
            end
        end
        table.sort(wrong)
        assert.are.same({}, wrong)
    end)

    known("[state] KF10: a character who started on Zephra's Isle gets the Zephra's Isle branch", function()
        local K = W.start()
        W.state.level = 6
        W.state.mapID, W.state.pos = 2521, { x = 0.45, y = 0.44 }
        W.state.completed[92460] = true
        W.state.completed[92461] = true
        local id = K.Engine.ChooseRoute(K.Detect())
        assert.are.equal("horde_zephras_05-10", id)
    end)

    known("[ordering] KF9: a ready turn-in where the player stands comes before one across the map", function()
        local K = W.start({ skipRoutes = true })
        W.registerRoute({ id = "ord", faction = "horde", branch = "horde", lo = 10, hi = 15, steps = {
            { t = "T", k = "Tfar", q = 1, g = "m", z = 1411, x = 52, y = 43, npc = 1 },
            { t = "T", k = "Tnear", q = 2, g = "m", z = 1413, x = 52, y = 30, npc = 2 },
        } })
        W.setQuestLog(1, true)
        W.setQuestLog(2, true)
        W.state.mapID, W.state.pos = 1413, { x = 0.52, y = 0.30 }
        K.Detect()
        K.Engine:Load("ord")
        local _, step = K.Engine:Current()
        assert.are.equal("Tnear", step.k)
    end)
end)
