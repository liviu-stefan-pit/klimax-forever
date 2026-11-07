-- Phase 09 level sync and login audit: grey-level formula, archive and gear verdicts, band jump
-- selection, the gear prompt and jump prompt being raised, detour insertion with stable keys, the
-- zone radar trigger and missed-reward selection. Pure rules are tested directly; the flows run
-- through the engine with a spy on K.Toast.Show.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

-- Replaces the toast with a recorder and returns the list it fills.
local function spyToasts(K)
    local shown = {}
    K.Toast.Show = function(text, seconds, actions)
        shown[#shown + 1] = { text = text, seconds = seconds, actions = actions }
    end
    return shown
end

-- A compiled-shape step for the level-sync specs.
local function acceptStep(route, q, ql, extra)
    local s = { t = "A", k = route .. ":A:" .. q .. ":0", q = q, ql = ql, g = "m", z = 1411, x = 10, y = 10 }
    for key, value in pairs(extra or {}) do
        s[key] = value
    end
    return s
end

local function band(id, lo, hi, branch, steps)
    return { id = id, faction = "horde", branch = branch or "horde", lo = lo, hi = hi, steps = steps or {},
        entry = { z = 1411, x = 10, y = 10, lv = lo }, exit = { z = 1413, x = 52, y = 30, lv = hi } }
end

describe("grey level", function()
    local S

    before_each(function()
        S = W.start({ skipRoutes = true }).Sync
    end)

    it("matches the Classic samples (5 at 9, 10 at 50, 12 at 60)", function()
        assert.are.equal(5, S.GreyRange(9))
        assert.are.equal(10, S.GreyRange(50))
        assert.are.equal(12, S.GreyRange(60))
    end)

    it("is continuous at the 39/40 boundary", function()
        assert.are.equal(8, S.GreyRange(39))
        assert.are.equal(8, S.GreyRange(40))
    end)

    it("calls a quest grey only when it is more than the range below the player", function()
        assert.is_true(S.IsGrey(3, 9))      -- 9 - 3 = 6 > 5
        assert.is_false(S.IsGrey(4, 9))     -- 9 - 4 = 5, not more than 5
        assert.is_false(S.IsGrey(nil, 30))  -- unknown quest level is never grey
        assert.is_false(S.IsGrey(0, 30))
    end)
end)

describe("archive and gear verdicts", function()
    local S

    before_each(function()
        S = W.start({ skipRoutes = true }).Sync
    end)

    it("archives a grey step without a key reward", function()
        assert.are.equal("archive", S.Verdict({ q = 1, ql = 2 }, 18, nil, false, nil))
    end)

    it("keeps non-grey, done, skipped and logged steps alone", function()
        assert.is_nil(S.Verdict({ q = 1, ql = 17 }, 18, nil, false, nil))
        assert.is_nil(S.Verdict({ q = 1, ql = 2 }, 18, "done", false, nil))
        assert.is_nil(S.Verdict({ q = 1, ql = 2 }, 18, "skipped", false, nil))
        assert.is_nil(S.Verdict({ q = 1, ql = 2 }, 18, nil, true, nil))
    end)

    it("asks about a grey key reward until the player answers", function()
        local key = { q = 2, ql = 3, kr = true }
        assert.are.equal("ask", S.Verdict(key, 18, nil, false, nil))
        assert.are.equal("keep", S.Verdict(key, 18, nil, false, "do"))
        assert.are.equal("archive", S.Verdict(key, 18, nil, false, "skip"))
    end)
end)

describe("band jump selection", function()
    local S

    before_each(function()
        S = W.start({ skipRoutes = true }).Sync
    end)

    it("proposes the later band when the level is 2 or more above the cursor", function()
        local cur = band("cur_1-5", 1, 5)
        local target = band("tgt_15-20", 15, 20)
        assert.are.equal(target, S.PlanJump(cur, target, 18, 15, nil))
    end)

    it("does nothing when the level is below the cursor plus two", function()
        local cur = band("cur_1-5", 1, 5)
        local target = band("tgt_15-20", 15, 20)
        assert.is_nil(S.PlanJump(cur, target, 16, 15, nil))
    end)

    it("does nothing for the same band, an earlier band, or after Stay", function()
        local cur = band("cur_1-5", 1, 5)
        local target = band("tgt_15-20", 15, 20)
        assert.is_nil(S.PlanJump(cur, cur, 18, 15, nil))
        assert.is_nil(S.PlanJump(target, cur, 18, 15, nil))
        assert.is_nil(S.PlanJump(cur, target, 18, 15, { ["tgt_15-20"] = 18 }))
    end)

    it("asks again once the level has gone past the level the player declined at", function()
        local cur = band("cur_1-5", 1, 5)
        local target = band("tgt_15-20", 15, 20)
        assert.are.equal(target, S.PlanJump(cur, target, 19, 15, { ["tgt_15-20"] = 18 }))
    end)
end)

describe("level sync flow", function()
    local routeA = "lvl_a_1-5"

    -- Current route at level 18: a grey quest (archived), a grey key reward (asked), a fresh step.
    local function setup(opts)
        local K = W.start({ skipRoutes = true })
        W.state.level = 18
        W.state.faction = "Horde"
        local steps = {
            acceptStep(routeA, 201, 2),
            acceptStep(routeA, 202, 3, { kr = true, rw = { item = 5, why = "a bag" } }),
            acceptStep(routeA, 203, 17),
        }
        W.registerRoute(band(routeA, 1, 5, "horde", steps))
        K.Detect()
        local ok, err = K.Engine:Load(routeA)
        assert.is_true(ok, err)
        return K, spyToasts(K), opts
    end

    it("archives grey steps and raises the gear prompt for a key reward", function()
        local K, shown = setup()
        K.Sync:LevelSync({ log = {}, completed = {} })
        local st = K.cdb.stepState[routeA]
        assert.are.equal("archived", st[routeA .. ":A:201:0"])
        assert.is_nil(st[routeA .. ":A:202:0"])
        assert.is_nil(st[routeA .. ":A:203:0"])
        assert.are.equal(1, #shown)
        assert.is_true(K.Sync.asked)
        assert.is_truthy(shown[1].text:find("a bag", 1, true))
    end)

    it("archives the key reward when the player answers Skip, and keeps it on Do it", function()
        local K, shown = setup()
        K.Sync:LevelSync({ log = {}, completed = {} })
        shown[1].actions[2].fn() -- Skip
        assert.are.equal("archived", K.cdb.stepState[routeA][routeA .. ":A:202:0"])

        local K2, shown2 = setup()
        K2.Sync:LevelSync({ log = {}, completed = {} })
        shown2[1].actions[1].fn() -- Do it
        assert.is_nil(K2.cdb.stepState[routeA][routeA .. ":A:202:0"])
        assert.are.equal(1, #shown2) -- the answer re-runs the sync; the key reward is not asked again
    end)

    it("proposes a jump and loads the band on Jump", function()
        local K, shown = setup()
        W.registerRoute(band("horde_jump_15-20", 15, 20, "horde", {}))
        K.Sync:LevelSync({ log = {}, completed = {} })
        local jump = shown[#shown]
        assert.is_truthy(jump.text:find("Jump", 1, true))
        jump.actions[1].fn()
        assert.are.equal("horde_jump_15-20", K.Engine.routeId)
    end)
end)

describe("detour insertion", function()
    local src = "src_1-5"
    local cur = "cur_5-10"

    local function setup()
        local K = W.start({ skipRoutes = true })
        W.state.level = 8
        W.registerRoute(band(src, 1, 5, "horde", {
            { t = "A", k = src .. ":A:301:0", q = 301, g = "m", z = 1411, x = 1, y = 1, n = "Bag quest" },
            { t = "C", k = src .. ":C:301:0", q = 301, g = "m", z = 1411, x = 2, y = 2, n = "Bag quest" },
            { t = "T", k = src .. ":T:301:0", q = 301, g = "m", z = 1411, x = 3, y = 3, n = "Bag quest" },
            { t = "A", k = src .. ":A:302:0", q = 302, g = "m", z = 1411, x = 4, y = 4, n = "Other" },
        }))
        W.registerRoute(band(cur, 5, 10, "horde", {
            { t = "A", k = cur .. ":A:401:0", q = 401, g = "m", z = 1413, x = 5, y = 5, n = "Now" },
        }))
        K.Detect()
        assert.is_true(K.Engine:Load(cur))
        return K
    end

    it("inserts accept, complete and turn-in with their original keys", function()
        local K = setup()
        local added = K.Engine:GoThere(301, src)
        assert.are.equal(3, added)
        assert.are.equal(src .. ":A:301:0", K.Engine.steps[1].k)
        assert.are.equal(src .. ":C:301:0", K.Engine.steps[2].k)
        assert.are.equal(src .. ":T:301:0", K.Engine.steps[3].k)
        assert.are.equal(1, K.Engine.byKey[src .. ":A:301:0"])
        assert.are.equal(4, K.Engine.byKey[cur .. ":A:401:0"])
    end)

    it("keeps the detour once after a reload and does not insert it twice", function()
        local K = setup()
        K.Engine:GoThere(301, src)
        assert.is_true(K.Engine:HasDetour(301))
        assert.are.equal(0, K.Engine:GoThere(301, src))
        K.Engine:Load(cur)
        assert.are.equal(4, #K.Engine.steps)
        assert.are.equal(src .. ":A:301:0", K.Engine.steps[1].k)
    end)

    it("keeps the state of a detour step when it is completed", function()
        local K = setup()
        K.Engine:GoThere(301, src)
        K.Engine:MarkDone(1)
        K.Engine:Load(cur)
        assert.are.equal("done", K.cdb.stepState[cur][src .. ":A:301:0"])
    end)
end)
