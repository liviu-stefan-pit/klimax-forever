-- Phase 19: the compiled world data (Klimax/World) loads through Klimax/WorldDB.lua, lazily.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

describe("WorldDB", function()
    local K
    before_each(function()
        W.reset()
        K = W.loadAddon()
    end)

    it("registers the index, the travel graph and every zone without building them", function()
        local DB = K.WorldDB
        assert.is_table(DB.index)
        assert.is_table(DB.travel)
        assert.equal("horde", DB.index.faction)
        local ids = DB.ZoneIds()
        assert.is_true(#ids >= 4)
        for _, id in ipairs(ids) do
            assert.is_false(DB.IsBuilt(id))
        end
    end)

    it("builds a zone on first lookup and resolves quests and NPCs through the index", function()
        local DB = K.WorldDB
        local q, uiMap = DB.Quest(788)
        assert.equal("Cutting Teeth", q.n)
        assert.equal(1411, uiMap)
        assert.is_true(DB.IsBuilt(1411))
        assert.is_false(DB.IsBuilt(1412))
        local npc = DB.Npc(3143)
        assert.equal("Gornek", npc.n)
        assert.same(DB.Zone(1411), DB.Zone(1411))
    end)

    it("returns nil for unknown ids", function()
        assert.is_nil(K.WorldDB.Quest(-1))
        assert.is_nil(K.WorldDB.Zone(999999))
    end)

    it("carries curated tips and shows them as the hint of that quest's steps (phase 30)", function()
        local q = K.WorldDB.Quest(851)
        assert.is_string(q.tip)
        assert.matches("Verog", q.tip, 1, true)
        local hint = K.Helpers.QuestTip({ t = "C", q = 851 })
        assert.equal(string.format(K.L.HINT_TIP, q.tip), hint)
        assert.is_true(#hint <= 120)
        assert.is_nil(K.Helpers.QuestTip({ t = "C", q = 788 }))
        assert.is_nil(K.Helpers.QuestTip({ t = "V" }))
        assert.is_nil(K.Helpers.QuestTip(nil))
    end)

    it("marks quests Blizzard disabled as broken (phase 30: Vorsha the Lasher)", function()
        assert.equal("broken", K.WorldDB.Quest(6641).cx)
    end)

    it("lists hubs and services per zone", function()
        local zone = K.WorldDB.Zone(1411)
        assert.is_true(#zone.hubs > 0)
        assert.is_table(zone.services)
        for _, hub in ipairs(zone.hubs) do
            assert.is_string(hub.id)
            assert.is_number(hub.x)
        end
    end)
end)
