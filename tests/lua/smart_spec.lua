-- Phase 08 smart features: reward scoring (upgrade against the sell-price fallback), trainer plan,
-- bag threshold, resupply, hearthstone and flight hints, opportunity cooldown and nameplate rares. Decisions are tested as pure functions; the reminder and the
-- opportunity scan are tested through the add-on's events, with a spy on K.Toast.Show.
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

-- Equipment used by the reward specs.
local sword = { name = "Sword of Hits", sellPrice = 900, id = 1001, info = {
    equipLoc = "INVTYPE_WEAPONMAINHAND", classID = 2, subclassID = 7, stats = { Str = 5, dps = 12 } } }
local leatherVest = { name = "Leather Vest", sellPrice = 1500, id = 1002, info = {
    equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 2, stats = { Sta = 2, armor = 20 } } }
local plate = { name = "Plate Breastplate", sellPrice = 2500, id = 1003, info = {
    equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 4, stats = { Sta = 9, armor = 60 } } }

describe("reward advisor", function()
    it("converts copper to a readable price", function()
        local K = W.start({ skipRoutes = true })
        assert.equals("1g 23s 45c", K.Rewards.Money(12345))
        assert.equals("0g 0s 0c", K.Rewards.Money(0))
    end)

    it("prefers a usable upgrade over the sell-price fallback", function()
        local K = W.start({ skipRoutes = true })
        local equipped = { [16] = { equipLoc = "INVTYPE_WEAPONMAINHAND", classID = 2, subclassID = 7,
            stats = { Str = 2, dps = 8 }, name = "Old Blade" } }
        local entries = {
            { index = 1, name = sword.name, sellPrice = sword.sellPrice, id = sword.id, info = sword.info },
            { index = 2, name = leatherVest.name, sellPrice = leatherVest.sellPrice, id = leatherVest.id,
              info = leatherVest.info },
        }
        local rec = K.Rewards.Evaluate(entries, "WARRIOR", 20, function(slot) return equipped[slot] end, nil)
        assert.equals("upgrade", rec.kind)
        assert.equals(1, rec.index)
        -- Sword score 5*1 + 12*3 = 41 against the equipped 2*1 + 8*3 = 26: about 58% better.
        assert.equals(58, rec.pct)
        assert.equals("Old Blade", rec.equipped)
    end)

    it("falls back to the highest sell price when no item is an upgrade", function()
        local K = W.start({ skipRoutes = true })
        local strong = {
            [16] = { equipLoc = "INVTYPE_WEAPONMAINHAND", classID = 2, subclassID = 7, stats = { Str = 10, dps = 20 } },
            [5] = { equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 2, stats = { Sta = 3, armor = 30 } },
        }
        local entries = {
            { index = 1, name = sword.name, sellPrice = sword.sellPrice, info = sword.info },
            { index = 2, name = leatherVest.name, sellPrice = leatherVest.sellPrice, info = leatherVest.info },
            -- Plate is not usable by a level 20 Warrior, but it has the highest sell price.
            { index = 3, name = plate.name, sellPrice = plate.sellPrice, info = plate.info },
        }
        local rec = K.Rewards.Evaluate(entries, "WARRIOR", 20, function(slot) return strong[slot] end, nil)
        assert.equals("sell", rec.kind)
        assert.equals(3, rec.index)
        assert.equals(2500, rec.sellPrice)
        assert.equals("No upgrades here. Take Plate Breastplate (sells for 0g 25s 0c)",
            K.Rewards.Message(rec))
    end)

    it("uses the route hint only while no item data is loaded", function()
        local K = W.start({ skipRoutes = true })
        local entries = {
            { index = 1, name = nil, id = 1001, info = nil },
            { index = 2, name = nil, id = 1002, info = nil },
        }
        local rec = K.Rewards.Evaluate(entries, "WARRIOR", 20, function() return nil end, 1002)
        assert.equals("hint", rec.kind)
        assert.equals(2, rec.index)
    end)

    it("never recommends an item the class cannot use well", function()
        local K = W.start({ skipRoutes = true })
        assert.is_nil(K.Rewards.Score(plate.info, "WARRIOR", 20))
        assert.is_not_nil(K.Rewards.Score(plate.info, "WARRIOR", 40))
        assert.is_nil(K.Rewards.Score(sword.info, "PRIEST", 20))
    end)
end)

describe("bag threshold", function()
    it("warns at or below the threshold only", function()
        local K = W.start({ skipRoutes = true })
        assert.is_true(K.Helpers.BagWarning(3, 3))
        assert.is_true(K.Helpers.BagWarning(1, 3))
        assert.is_false(K.Helpers.BagWarning(4, 3))
        assert.is_false(K.Helpers.BagWarning(nil, 3))
        assert.is_true(K.Helpers.BagWarning(1, 1))
    end)
end)

describe("resupply", function()
    it("lists what a class is short of before an excursion", function()
        local K = W.start({ skipRoutes = true })
        assert.same({ "food", "water", "ammo" }, K.Helpers.Resupply({ food = 0, water = 0, ammo = 0 }, "HUNTER"))
        assert.same({}, K.Helpers.Resupply({ food = 3, water = 3, ammo = 60 }, "HUNTER"))
        -- Warriors do not need water; only mana classes do.
        assert.same({ "food" }, K.Helpers.Resupply({ food = 0, water = 0 }, "WARRIOR"))
        assert.same({ "food", "water" }, K.Helpers.Resupply({ food = 1, water = 0 }, "MAGE"))
    end)

    it("tells water from food by name", function()
        local K = W.start({ skipRoutes = true })
        assert.is_true(K.Helpers.IsWater("Refreshing Spring Water"))
        assert.is_false(K.Helpers.IsWater("Tough Jerky"))
    end)
end)

describe("hearthstone and flight hints", function()
    it("reports the time left on a cooldown and nothing once ready", function()
        local K = W.start({ skipRoutes = true })
        assert.equals(500, K.Helpers.CooldownLeft(100, 600, 200))
        assert.equals(0, K.Helpers.CooldownLeft(100, 600, 900))
        assert.equals(0, K.Helpers.CooldownLeft(0, 0, 200))
        assert.equals(8, K.Helpers.Minutes(470))
    end)

    it("suggests a known flight node that matches the destination", function()
        local K = W.start({ skipRoutes = true })
        assert.equals("Crossroads, The Barrens",
            K.Helpers.FlyNode("crossroads", { "Razor Hill, Durotar", "Crossroads, The Barrens" }))
        assert.is_nil(K.Helpers.FlyNode("Ironforge", { "Razor Hill, Durotar" }))
    end)
end)

describe("trainer plan", function()
    it("plans the essentials the trainer offers now and checks the money", function()
        local K = W.start({ skipRoutes = true })
        local band = K.Trainer.Band("HUNTER", 1)
        assert.equals(1, band.from)
        local services = {
            { name = "Serpent Sting", category = "available", cost = 2000 },
            { name = "Raptor Strike", category = "available", cost = 1000 },
            { name = "Arcane Shot", category = "unavailable", cost = 500 },
        }
        local plan = K.Trainer.Plan(services, band, 1500)
        assert.equals("Raptor Strike", plan.essential[1].name)
        assert.equals(3000, plan.cost)
        assert.equals(1500, plan.short)
        assert.matches("Short by 0g 15s 0c", K.Trainer.MoneyLine(plan), 1, true)
    end)

    it("picks the band in force for the level", function()
        local K = W.start({ skipRoutes = true })
        assert.equals(30, K.Trainer.Band("HUNTER", 30).from)
        assert.equals(1, K.Trainer.Band("HUNTER", 29).from)
    end)
end)

describe("opportunity cooldown", function()
    it("holds a spawn back for the cooldown and releases it after", function()
        local K = W.start({ skipRoutes = true })
        local seen = {}
        local O = K.Opportunities
        assert.is_false(O.OnCooldown(seen, "rare:1", 100))
        O.Mark(seen, "rare:1", 100, 3600)
        assert.is_true(O.OnCooldown(seen, "rare:1", 200))
        assert.is_false(O.OnCooldown(seen, "rare:1", 3700))
    end)

    it("finds the nearest spawn within the radius", function()
        local K = W.start({ skipRoutes = true })
        local zones = { [1413] = { { 50, 52 }, { 10, 10 } } }
        assert.equals(1, K.Opportunities.Nearest(zones, 1413, 50, 50, 8))
        assert.is_nil(K.Opportunities.Nearest(zones, 1413, 30, 30, 8))
        assert.is_nil(K.Opportunities.Nearest(zones, 1420, 50, 50, 8))
    end)

    it("hints a rare once per spawn and not again during the cooldown", function()
        local K = W.start({ skipRoutes = true })
        local shown = spyToasts(K)
        K.player = { level = 15, class = "WARRIOR" }
        K.Rares = { { id = 1, name = "Rathorian", lo = 15, hi = 15, zones = { [1413] = { { 50, 50 } } }, drops = {} } }
        K.Chests = {}
        W.state.mapID = 1413
        W.state.pos = { x = 0.5, y = 0.5 }
        assert.is_true(K.Opportunities.Scan())
        assert.equals(1, #shown)
        assert.matches("Rathorian", shown[1].text, 1, true)
        assert.is_false(K.Opportunities.Scan())
        W.state.wall = W.state.wall + 3601
        assert.is_true(K.Opportunities.Scan())
        assert.equals(2, #shown)
    end)

    it("skips a rare that is too high or too grey for the player", function()
        local K = W.start({ skipRoutes = true })
        local shown = spyToasts(K)
        K.player = { level = 5, class = "WARRIOR" }
        K.Rares = { { id = 1, name = "Too Strong", lo = 15, hi = 15, zones = { [1413] = { { 50, 50 } } }, drops = {} } }
        K.Chests = {}
        W.state.mapID = 1413
        W.state.pos = { x = 0.5, y = 0.5 }
        assert.is_false(K.Opportunities.Scan())
        assert.equals(0, #shown)
    end)

    it("hints a rare nameplate once per name during its cooldown", function()
        local K = W.start({ skipRoutes = true })
        local shown = spyToasts(K)
        W.state.classification = { nameplate1 = "rare" }
        W.state.names = { nameplate1 = "Bloodmaw" }
        assert.is_true(K.Opportunities.OnNamePlate("nameplate1"))
        assert.is_false(K.Opportunities.OnNamePlate("nameplate1"))
        assert.matches("Bloodmaw", shown[1].text, 1, true)
        W.state.classification = { nameplate2 = "elite" }
        assert.is_false(K.Opportunities.OnNamePlate("nameplate2"))
    end)
end)

describe("compiled world", function()
    it("the hint for the current step does not throw, whatever step is current", function()
        local K = W.start({})
        W.fire("PLAYER_LOGIN")
        W.flushTimers()
        K.Engine:Recompute()
        assert.is_true(pcall(K.Helpers.CurrentHint))
        for _, s in ipairs(K.Engine.steps) do
            W.showSteps(K, { s })
            assert.is_true(pcall(K.Helpers.CurrentHint), s.k)
        end
    end)
end)

describe("dev level", function()
    it("fakes the level for the engine and says so", function()
        local K = W.start({ skipRoutes = true })
        K.Detect()
        K.DevCommand("level 18")
        assert.equals(18, K.player.level)
        assert.matches("level faked to 18", W.printed[#W.printed], 1, true)
        K.DevCommand("level 99")
        assert.equals(18, K.player.level)
    end)
end)
