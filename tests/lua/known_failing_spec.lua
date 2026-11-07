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
