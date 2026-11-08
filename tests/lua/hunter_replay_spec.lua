-- The level 15 Hunter replay (phase 18 synthetic fixture) on the plan engine. These were the phase 18
-- known failures of the band engine (KF1-KF10); the plan follows the game, so each one is now a
-- statement about the plan: no step the game would refuse, nothing for a quest that is not in the
-- log, the right start branch.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")
local Fx = require("fixture")

local function replay(mutate)
    local fx = Fx.load("hunter15_synthetic")
    if mutate then
        mutate(fx)
    end
    local K = Fx.start(fx)
    K.Engine:Recompute()
    return K, fx
end

local function inLog(K, q)
    local log = K.Diag.ReadLog()
    return log[q] ~= nil
end

describe("level 15 Hunter replay (synthetic fixture) on the plan engine", function()
    it("the plan is built from the real world for this character", function()
        local K = replay()
        assert.are.equal("plan", K.Engine.routeId)
        assert.is_true(#K.Engine.steps > 0)
        assert.is_not_nil(K.Engine.cursor)
    end)

    it("[state] KF1/KF6: 872 needs 871, which the game does not show completed, so it is not first", function()
        local K = replay()
        local _, step = K.Engine:Current()
        assert.are_not.equal("plan:A:872", step.k)
        assert.are_not.equal("available", (K.State:Get(872)))
    end)

    it("[state] KF2: 751 is complete in the log under a collapsed header and is not lost", function()
        local K = replay()
        assert.are.equal("objectives-done", (K.State:Get(751)))
        assert.is_true(inLog(K, 751))
    end)

    it("[state] KF3/KF4/KF5: no objective or turn-in for a quest that is not in the log", function()
        local K = replay()
        local accepted = {}
        for i, s in ipairs(K.Engine.steps) do
            if s.t == "A" then
                accepted[s.q] = true
            elseif (s.t == "C" or s.t == "T") and not inLog(K, s.q) and not accepted[s.q] then
                error(string.format("step %d %s is for quest %d, not in the log", i, s.k, s.q))
            end
        end
    end)

    it("[state] KF3: a failed quest (853) gets no turn-in", function()
        local K = replay()
        assert.are.equal("failed", (K.State:Get(853)))
        for _, s in ipairs(K.Engine.steps) do
            assert.are_not.equal(853, s.q)
        end
    end)

    it("[state] KF7: without a completed-quest API, no turn-in for a quest not in the log is shown", function()
        local K = replay(function(fx)
            fx.api.completed = nil
            fx.completedKnown = false
        end)
        local accepted = {}
        for _, s in ipairs(K.Engine.steps) do
            if s.t == "A" then
                accepted[s.q] = true
            elseif s.t == "T" then
                assert.is_true(inLog(K, s.q) or accepted[s.q], "T for " .. tostring(s.q))
            end
        end
    end)

    it("[data] KF8: every accept is allowed for this race and class (the gates hold)", function()
        local K = replay()
        local R = K.Reconciler
        local ctx = K.State.ctx
        for _, s in ipairs(K.Engine.steps) do
            if s.t == "A" then
                local gate = R.Gate(ctx, s.q, K.WorldDB.Quest(s.q))
                assert.is_true(gate == nil or gate == "level" or gate == "prereq",
                    s.k .. " is gated by " .. tostring(gate))
            end
        end
    end)

    it("[state] KF10: a character who started on Zephra's Isle gets the Zephra's Isle branch", function()
        local K = W.start()
        W.state.level = 6
        W.state.mapID, W.state.pos = 2521, { x = 0.45, y = 0.44 }
        W.state.completed[92460] = true
        W.state.completed[92461] = true
        assert.are.equal("zephras", K.Engine.BranchForPlayer(K.Detect()))
        W.state.mapID = 1411
        K.Snapshot.completed = { [92460] = true }
        assert.are.equal("zephras", K.Engine.BranchForPlayer(K.Detect()))
        K.Snapshot.completed = {}
        assert.are.equal("durotar", K.Engine.BranchForPlayer(K.Detect()))
    end)

    it("[ordering] the first step is where the player is or the best score, never a fixed script", function()
        local K = replay()
        local _, step = K.Engine:Current()
        assert.is_not_nil(step.z)
        local plan = K.Planner:Get()
        assert.are.equal(plan.steps[1].k, step.k)
    end)
end)
