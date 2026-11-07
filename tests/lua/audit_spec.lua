-- Phase 09 login audit rules (PRD 7.10): the zone radar trigger, the obtainable filter for missed key
-- rewards, the ignore list and the cap of three suggestions.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

describe("zone radar", function()
    local A

    before_each(function()
        A = W.start({ skipRoutes = true }).Audit
    end)

    it("fires for Durotar (top level 13) at level 15 when the route's next step is elsewhere", function()
        assert.is_true(A.RadarFires(13, 15, 1411, 1413))
    end)

    it("does not fire below the margin, in the right zone, or without a target", function()
        assert.is_false(A.RadarFires(13, 14, 1411, 1413))
        assert.is_false(A.RadarFires(13, 15, 1411, 1411))
        assert.is_false(A.RadarFires(13, 15, 1411, nil))
        assert.is_false(A.RadarFires(nil, 15, 1411, 1413))
    end)
end)

describe("missed key rewards", function()
    local A, S, completed, ignored

    before_each(function()
        local K = W.start({ skipRoutes = true })
        A, S = K.Audit, K.Sync
        completed = { [10] = true }
        ignored = {}
    end)

    local function keyStep(q, extra)
        local s = { t = "A", k = "r:A:" .. q .. ":0", q = q, ql = 10, kr = true, rw = { item = 900 + q }, n = "Q" .. q }
        for key, value in pairs(extra or {}) do
            s[key] = value
        end
        return s
    end

    it("accepts an obtainable, useful key reward that is not grey", function()
        assert.is_true(A.Obtainable(keyStep(20), 16, completed, ignored))
    end)

    it("rejects a step that is done, ignored, grey, or not a key reward", function()
        assert.is_false(A.Obtainable(keyStep(10), 16, completed, ignored))
        ignored[20] = true
        assert.is_false(A.Obtainable(keyStep(20), 16, completed, ignored))
        ignored[20] = nil
        assert.is_false(A.Obtainable(keyStep(20), 30, completed, ignored)) -- 30 - 10 > 9: grey
        local plain = keyStep(20)
        plain.kr = nil
        assert.is_false(A.Obtainable(plain, 16, completed, ignored))
    end)

    it("needs its prerequisites: all of pa, and any of po", function()
        assert.is_false(A.Obtainable(keyStep(20, { pa = { 30 } }), 16, completed, ignored))
        assert.is_true(A.Obtainable(keyStep(20, { pa = { 10 } }), 16, completed, ignored))
        assert.is_false(A.Obtainable(keyStep(20, { po = { 30, 31 } }), 16, completed, ignored))
        assert.is_true(A.Obtainable(keyStep(20, { po = { 31, 10 } }), 16, completed, ignored))
    end)

    it("selects the best three by score, ties by quest id", function()
        local cands = {
            { quest = 1, score = 5 }, { quest = 2, score = 9 }, { quest = 3, score = 9 },
            { quest = 4, score = 1 }, { quest = 5, score = 7 },
        }
        local picked = A.SelectMissed(cands)
        assert.are.equal(3, #picked)
        assert.are.equal(2, picked[1].quest)
        assert.are.equal(3, picked[2].quest)
        assert.are.equal(5, picked[3].quest)
    end)

    it("returns fewer than three when there are fewer candidates", function()
        assert.are.equal(1, #A.SelectMissed({ { quest = 7, score = 1 } }))
        assert.are.equal(0, #A.SelectMissed({}))
    end)

    it("uses the sync's own grey rule (no separate formula)", function()
        assert.are.equal(S.IsGrey(10, 30), (30 - 10) > S.GreyRange(30))
    end)
end)
