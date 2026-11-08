-- Phase 25/26 simulation (a first cut of the phase 28 harness): virtual characters of every Horde start
-- branch and several classes follow the planner on the compiled world, doing every step it gives
-- (accept, finish, hand in) and gaining its XP. After each step the harness checks what the plan
-- promised: nothing impossible (level, prerequisite, race, class, exclusive gates), nothing twice,
-- every target placed on the map. Pure planner and reconciler; no WoW client.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local K
local R, Sc, Wt

local BRANCHES = {
    { name = "durotar", race = "Orc", token = "Orc", map = 1411, x = 52, y = 43 },
    { name = "durotar", race = "Troll", token = "Troll", map = 1411, x = 52, y = 43 },
    { name = "mulgore", race = "Tauren", token = "Tauren", map = 1412, x = 45, y = 60 },
    { name = "tirisfal", race = "Undead", token = "Scourge", map = 1420, x = 32, y = 65 },
    { name = "zephras", race = "Orc", token = "Orc", map = 2521, x = 40, y = 40 },
}
local CLASSES = { "WARRIOR", "HUNTER", "MAGE", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "DRUID", "PALADIN" }
local TARGET = 40
-- Levels 1 to 40 (phase 26): with the 21 compiled zones every branch reaches 40 on quests alone,
-- and the harness allows at most MAX_GRINDS rounds with no quest worth doing (a dead end).
local FLOOR = 40
local MAX_ROUNDS = 400
local MAX_GRINDS = 2
local GRIND_SHARE = 0.3
-- Kill XP earned on the way to the objectives, as a share of quest XP (an assumption: the harness
-- does not simulate mobs; a leveling guide's quest XP is typically two thirds to three quarters of
-- the total; kills are about equal to quests from 20 on, so 1.0 here).
local KILL_BONUS = 1.0

local function run(branch, class, profile, goldenLevels)
    local DB = K.WorldDB
    local index = DB.index
    local snap = { level = 1, xp = 0, race = branch.race, raceToken = branch.token, class = class,
        mapID = branch.map, x = branch.x, y = branch.y, log = {}, completed = {}, completedKnown = true,
        scanned = true, skipped = {}, seen = {} }
    local ctx
    local function fresh()
        ctx = R.New(snap, {
            info = DB.Quest,
            exGroup = function(id) return index.ex and index.ex[id] end,
            eqGroup = function(q)
                for _, g in ipairs(index.eq or {}) do
                    for _, id in ipairs(g) do
                        if id == q then return g end
                    end
                end
            end,
        })
    end
    local function state(q)
        return R.State(ctx, q)
    end
    local wt = Wt.For(profile, class)
    wt.spine = K.Planner.SpineFor(index.spine, branch.name)
    local World = K.Planner.World()
    local problems, turned, rounds, grinds = {}, 0, 0, 0
    local golden = {}
    local function bad(msg)
        problems[#problems + 1] = string.format("%s %s L%d: %s", branch.race, class, snap.level, msg)
    end
    while snap.level < TARGET and rounds < MAX_ROUNDS and #problems == 0 do
        rounds = rounds + 1
        fresh()
        local steps = K.Planner.Build(World, state, snap, wt)
        while goldenLevels and #goldenLevels > 0 and snap.level >= goldenLevels[1] do
            local keys = {}
            for i = 1, math.min(12, #steps) do
                keys[i] = steps[i].k
            end
            golden[tostring(table.remove(goldenLevels, 1))] = keys
        end
        local worked = false
        for _, s in ipairs(steps) do
            fresh()
            if s.t == "A" or s.t == "C" or s.t == "T" then
                local rec = DB.Quest(s.q)
                if not rec then
                    bad("step for unknown quest " .. tostring(s.q))
                    break
                end
                if type(s.x) ~= "number" or type(s.y) ~= "number" or not s.z
                    or s.x < 0 or s.x > 100 or s.y < 0 or s.y > 100 then
                    bad(s.k .. " has no valid target")
                    break
                end
                local st = state(s.q)
                if st == "completed" then
                    bad(s.k .. " is for a quest already completed")
                    break
                end
                if s.t == "A" then
                    local gate = R.Gate(ctx, s.q, rec)
                    if gate or st == "ignored" or st == "broken" then
                        bad(s.k .. " cannot be accepted: " .. tostring(gate or st))
                        break
                    end
                    snap.log[s.q] = { complete = (#(rec.o or {}) == 0) or nil }
                elseif s.t == "C" then
                    if not snap.log[s.q] then
                        bad(s.k .. " objectives without the quest in the log")
                        break
                    end
                    snap.log[s.q].complete = true
                else
                    if not snap.log[s.q] then
                        bad(s.k .. " turn-in without the quest in the log")
                        break
                    end
                    snap.log[s.q] = nil
                    snap.completed[s.q] = true
                    turned = turned + 1
                    snap.xp = snap.xp + math.floor((1 + KILL_BONUS) * Sc.XpAt(rec.xp or (index.xpl[rec.lv or 1] or 0), rec.lv or snap.level, snap.level))
                    while snap.level < 60 and snap.xp >= Wt.LEVEL_XP[snap.level] do
                        snap.xp = snap.xp - Wt.LEVEL_XP[snap.level]
                        snap.level = snap.level + 1
                    end
                end
                worked = true
                snap.mapID, snap.x, snap.y = s.z, s.x, s.y
            elseif s.t == "V" and s.z and s.x then
                snap.mapID, snap.x, snap.y = s.z, s.x, s.y
            end
        end
        if not worked then
            -- No quest worth doing: the character grinds a share of the next level (the plan view
            -- of phase 27 says so too). Bounded, and reported, so a dead end shows up in the test.
            if grinds >= MAX_GRINDS then
                break
            end
            grinds = grinds + 1
            snap.xp = snap.xp + math.floor(Wt.LEVEL_XP[snap.level] * GRIND_SHARE)
            while snap.level < 60 and snap.xp >= Wt.LEVEL_XP[snap.level] do
                snap.xp = snap.xp - Wt.LEVEL_XP[snap.level]
                snap.level = snap.level + 1
            end
        end
    end
    return { level = snap.level, turned = turned, grinds = grinds, golden = golden, problems = problems, rounds = rounds }
end

describe("simulated characters, levels 1 to 40 (phases 25 and 26)", function()
    setup(function()
        K = W.start()
        R, Sc, Wt = K.Reconciler, K.Plan.Score, K.Plan.Weights
    end)

    for _, branch in ipairs(BRANCHES) do
        for _, class in ipairs(CLASSES) do
            it(string.format("%s %s (%s) reaches %d without an impossible step", branch.race, class, branch.name, FLOOR), function()
                local res = run(branch, class)
                assert.is_true(#res.problems == 0, table.concat(res.problems, "; "))
                assert.is_true(res.turned > 100, "turned in only " .. res.turned)
                assert.is_true(res.turned < 500, "turned in " .. res.turned .. " quests: a curve that thin on XP")
                assert.is_true(res.level >= FLOOR, string.format("stopped at level %d after %d quests (%d grinds)", res.level, res.turned, res.grinds))
            end)
        end
    end
end)

-- Golden plans (phase 28): the default characters' first plan steps at levels 1, 10, 20, 30 and 39,
-- written by `python -m pipeline.sim.harness --golden` from the Python mirror. The Lua planner must
-- build the very same plans: a change to either side shows up as a reviewed diff of the file.
describe("golden plans", function()
    local json = require("dkjson")
    local f = assert(io.open("tests/golden/plans.json", "r"))
    local golden = assert(json.decode(f:read("*a"), 1, nil))
    f:close()
    local BY_NAME = { orc = BRANCHES[1], troll = BRANCHES[2], tauren = BRANCHES[3], undead = BRANCHES[4],
        zephras = BRANCHES[5] }
    local PROFILES = {
        relaxed = nil,
        speed = { pace = "speed", elites = "skip", completionist = "xp" },
        completionist = { pace = "relaxed", completionist = "finish", elites = "allow", dungeons = "good" },
    }
    setup(function()
        K = W.start()
        R, Sc, Wt = K.Reconciler, K.Plan.Score, K.Plan.Weights
    end)

    local names = {}
    for name in pairs(golden) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        it(name, function()
            local branch, class, profile = name:match("^(%a+)%-(%a+)%-(%a+)$")
            local want = golden[name]
            local res = run(BY_NAME[branch], class:upper(), PROFILES[profile], { 1, 10, 20, 30, 39 })
            for _, level in ipairs({ "1", "10", "20", "30", "39" }) do
                assert.are.same(want[level], res.golden[level], name .. " at level " .. level)
            end
        end)
    end
end)
