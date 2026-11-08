-- Phase 20: snapshot, reconciler and K.State. The reconciler rules are pure; each rule listed in
-- Klimax/State/Reconciler.lua has a spec here.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K, R

local function snap(over)
    local s = {
        level = 15, race = "Orc", raceToken = "Orc", class = "HUNTER",
        log = {}, completed = {}, completedKnown = true, scanned = true, logPartial = false,
        seen = {}, skipped = {},
    }
    for k, v in pairs(over or {}) do
        s[k] = v
    end
    return s
end

local function ctx(s, records, extra)
    extra = extra or {}
    return R.New(s, {
        info = function(q) return records and records[q] end,
        exGroup = extra.exGroup,
        eqGroup = extra.eqGroup,
        known = extra.known,
        believed = extra.believed,
    })
end

local function state(s, records, q, extra)
    return R.State(ctx(s, records, extra), q)
end

before_each(function()
    W.reset()
    K = W.loadAddon({ skipRoutes = true })
    R = K.Reconciler
end)

describe("reconciler rules", function()
    it("1: a curated broken quest is broken, whatever the game says", function()
        assert.equal("broken", state(snap({ completed = { [1] = true } }), { [1] = { cx = "broken" } }, 1))
    end)

    it("2: completed from the flag, an equivalent's flag, or a completed later link", function()
        assert.equal("completed", state(snap({ completed = { [1] = true } }), {}, 1))
        local eq = { 5, 6 }
        assert.equal("completed", state(snap({ completed = { [6] = true } }), {}, 5,
            { eqGroup = function(q) return (q == 5 or q == 6) and eq or nil end }))
        -- 3 is completed; its chain predecessor 2 and its all-of prerequisite 1 are implied
        local recs = { [3] = { pv = { 2 } }, [2] = { pa = { 1 } } }
        local c = ctx(snap({ completed = { [3] = true } }), recs)
        assert.equal("completed", R.State(c, 2))
        assert.equal("completed", R.State(c, 1))
    end)

    it("3: the log wins: failed, objectives-done, active (even over a player skip)", function()
        local s = snap({ log = { [1] = { failed = true }, [2] = { complete = true }, [3] = {} },
            skipped = { [3] = true } })
        assert.equal("failed", state(s, {}, 1))
        assert.equal("objectives-done", state(s, {}, 2))
        assert.equal("active", state(s, {}, 3))
    end)

    it("4: a player skip or a curated skip is ignored", function()
        assert.equal("ignored", state(snap({ skipped = { [1] = true } }), {}, 1))
        local st, why = state(snap(), { [1] = { cx = "skip" } }, 1)
        assert.equal("ignored", st)
        assert.equal("curated", why)
    end)

    it("4b: a quest outside the universe is unknown (its flag was never scanned)", function()
        local st, why = state(snap(), {}, 1, { known = function() return false end })
        assert.equal("unknown", st)
        assert.equal("untracked", why)
    end)

    it("5: gates: race, class, level, max level, exclusive, prerequisites", function()
        local recs = {
            [1] = { ra = 32 },               -- Tauren only
            [2] = { cl = 1 },                -- Warrior only
            [3] = { rl = 20 },
            [4] = { mx = 10 },
            [5] = { ex = 5 },
            [7] = { pa = { 100, 101 } },
            [8] = { po = { 100, 101 } },
            [9] = { ra = 2 + 128, cl = 4, rl = 10 },
        }
        local extra = { exGroup = function() return { 5, 6 } end }
        local s = snap({ completed = { [6] = true, [100] = true } })
        local function check(q, want, why)
            local st, reason = state(s, recs, q, extra)
            assert.equal(want, st, "quest " .. q)
            assert.equal(why, reason, "quest " .. q)
        end
        check(1, "unavailable", "race")
        check(2, "unavailable", "class")
        check(3, "unavailable", "level")
        check(4, "unavailable", "maxlevel")
        check(5, "unavailable", "exclusive")
        check(7, "unavailable", "prereq")
        check(8, "available", nil)
        check(9, "available", nil)
    end)

    it("5: a prerequisite the game cannot decide never blocks", function()
        local recs = { [7] = { pa = { 100 } } }
        assert.equal("available", state(snap({ completedKnown = false }), recs, 7))
        assert.equal("available", state(snap(), recs, 7, { known = function(q) return q ~= 100 end }))
    end)

    it("6: a quest the character had: abandoned, or unknown when the game cannot tell", function()
        local seen = { [1] = true }
        assert.equal("abandoned", state(snap({ seen = seen }), {}, 1))
        local st, why = state(snap({ seen = seen, completedKnown = false }), {}, 1)
        assert.equal("unknown", st)
        assert.equal("no-completed-api", why)
        st, why = state(snap({ seen = seen, scanned = false }), {}, 1)
        assert.equal("not-scanned", why)
        st, why = state(snap({ seen = seen, logPartial = true }), {}, 1)
        assert.equal("log-partial", why)
        -- the guide's own belief counts as "had it"
        assert.equal("abandoned", state(snap(), {}, 2, { believed = function(q) return q == 2 end }))
        -- an abandoned quest that is no longer allowed is unavailable
        assert.equal("unavailable", state(snap({ seen = seen }), { [1] = { mx = 10 } }, 1))
    end)

    it("7: otherwise available", function()
        assert.equal("available", state(snap(), {}, 42))
    end)

    it("HasBit works on large masks without bit operators", function()
        assert.is_true(R.HasBit(8589934770, 2))
        assert.is_false(R.HasBit(8589934770, 1))
        assert.is_true(R.HasBit(nil, 4))
    end)
end)

describe("snapshot and K.State", function()
    local function login(opts)
        K = W.start(W.merge({ skipRoutes = true }, opts))
        W.setUniverse(K, { 10, 11, 12 })
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        return K
    end

    it("scans the completed flags in slices across frames", function()
        K = W.start({ skipRoutes = true })
        K.Snapshot.BATCH = 100
        local ids = {}
        for id = 1, 300 do
            ids[id] = id
        end
        W.setUniverse(K, ids)
        W.state.completed[10] = true
        local done
        K.Snapshot.ScanCompleted(function(set, known)
            done = { set = set, known = known }
        end)
        assert.is_nil(done)            -- the first slice ran, the rest wait for the next frames
        assert.is_true(#W.timers > 0)
        W.flushTimers()
        assert.is_true(done.known)
        assert.is_true(done.set[10])
    end)

    it("learns a turn-in at once and refreshes", function()
        login()
        local changes = 0
        K.State:OnChange(function() changes = changes + 1 end)
        assert.equal("available", K.State:Get(12))
        W.fire("QUEST_TURNED_IN", 12, 0, 0)
        assert.equal("completed", K.State:Get(12))
        assert.equal(1, changes)
    end)

    it("records quests seen in the log, so a dropped quest is abandoned", function()
        login()
        W.setQuestLog(11, false)
        W.fire("QUEST_LOG_UPDATE")
        W.flushTimers()
        assert.equal("active", K.State:Get(11))
        assert.is_true(K.cdb.seenQuests[11])
        W.state.logList = {}
        W.fire("QUEST_REMOVED", 11)
        W.flushTimers()
        assert.equal("abandoned", K.State:Get(11))
    end)

    it("reads a quest under a collapsed header and leaves the header collapsed", function()
        login()
        W.state.logList = {
            { isHeader = true, title = "Mulgore", isCollapsed = true },
            { questID = 10, title = "Ten", isComplete = true },
        }
        K.State:Refresh()
        assert.equal("objectives-done", K.State:Get(10))
        assert.is_true(W.state.logList[1].isCollapsed)
        assert.is_false(K.State.snap.logPartial)
    end)

    it("knows when the client has no completed-quest API", function()
        login({ legacy = true })
        W.unset("IsQuestFlaggedCompleted")
        W.unset("GetQuestsCompleted")
        K.State:Resync()
        W.flushTimers()
        assert.is_false(K.State.snap.completedKnown)
    end)

    it("finds records in the compiled world before the route meta", function()
        login()
        local rec = K.State.Info(788)
        assert.equal("Cutting Teeth", rec.n)
    end)
end)
