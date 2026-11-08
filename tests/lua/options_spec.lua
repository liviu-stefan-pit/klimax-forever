-- The option schema, defaults, events and migration (UI overhaul phase 16), and the panel opening.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

describe("option values", function()
    it("default when nothing is stored, and a stored value wins", function()
        local K = W.start({ skipRoutes = true })
        assert.is_true(K.Option("arrow"))
        assert.is_true(K.Option("toasts"))
        assert.is_true(K.Option("animations"))
        assert.equals(3, K.Option("bagThreshold"))
        K.SetOption("arrow", false)
        assert.is_false(K.Option("arrow"))
    end)

    it("every row of the schema has a default and a label, and choice rows hold their default", function()
        local K = W.start({ skipRoutes = true })
        local O = K.Options
        for _, row in ipairs(O.AllRows()) do
            assert.is_not_nil(O.DEFAULTS[row.key], row.key)
            assert.is_string(K.L[row.label], row.label)
            if row.tip then
                assert.is_string(K.L[row.tip], row.tip)
            end
            if row.kind == "choice" then
                local found = false
                for _, v in ipairs(row.values) do
                    found = found or v == O.DEFAULTS[row.key]
                end
                assert.is_true(found, row.key)
            end
        end
        for _, sec in ipairs(O.SECTIONS) do
            assert.is_string(K.L[sec.title], sec.title)
        end
    end)

    it("every previous option is still reachable in the panel", function()
        local K = W.start({ skipRoutes = true })
        for _, key in ipairs({ "arrow", "arrowScale", "hideInCombat", "locked", "bagThreshold", "fontScale",
            "scale", "alpha", "opportunities", "toasts" }) do
            assert.is_not_nil(K.Options.Row(key), key)
        end
    end)
end)

describe("option helpers", function()
    it("NextValue steps through a list and wraps; an unknown value gives the first", function()
        local K = W.start({ skipRoutes = true })
        local values = { 0.8, 1, 1.25 }
        assert.equals(1, K.Options.NextValue(values, 0.8))
        assert.equals(1.25, K.Options.NextValue(values, 1))
        assert.equals(0.8, K.Options.NextValue(values, 1.25))
        assert.equals(0.8, K.Options.NextValue(values, 42))
    end)

    it("bool rows flip and choice rows move to the next value", function()
        local K = W.start({ skipRoutes = true })
        assert.is_false(K.Options.ToggledValue(K.Options.Row("arrow")))
        assert.equals(4, K.Options.ToggledValue(K.Options.Row("bagThreshold")))
        K.SetOption("fontScale", 1.15)
        assert.equals(1.3, K.Options.ToggledValue(K.Options.Row("fontScale")))
    end)

    it("formats scale-like values as percentages and the rest as is", function()
        local K = W.start({ skipRoutes = true })
        local O = K.Options
        assert.equals("85%", O.Format(O.Row("alpha"), 0.85))
        assert.equals("125%", O.Format(O.Row("scale"), 1.25))
        assert.equals("4", O.Format(O.Row("bagThreshold"), 4))
        local choices = O.Choices(O.Row("alpha"))
        assert.equals(4, #choices)
        assert.equals("40%", choices[1].text)
        assert.equals(0.4, choices[1].value)
    end)

    it("migration drops values that are not valid for their row", function()
        local K = W.start({ skipRoutes = true })
        local options = { arrow = "yes", scale = 1.1, alpha = 0.5, bagThreshold = 3, unknown = 7 }
        assert.equals(2, K.Options.Migrate(options))
        assert.is_nil(options.arrow)
        assert.is_nil(options.alpha)
        assert.equals(1.1, options.scale)
        assert.equals(3, options.bagThreshold)
        assert.equals(7, options.unknown)       -- keys outside the schema are left alone
        assert.equals(0, K.Options.Migrate(nil))
    end)
end)

describe("option events and the panel", function()
    it("listeners hear every change, and Defaults restores every option", function()
        local K = W.start({ skipRoutes = true })
        local heard = {}
        K.Options.OnChange(function(key, value) heard[key] = value end)
        K.SetOption("scale", 1.25)
        assert.equals(1.25, heard.scale)
        K.Options.ResetAll()
        assert.equals(1, K.Option("scale"))
        assert.equals(1, heard.scale)
    end)

    it("changing an option applies it to the live window", function()
        local K = W.start({ skipRoutes = true })
        W.fire("PLAYER_LOGIN")
        assert.has_no.errors(function()
            K.SetOption("fontScale", 1.3)
            K.SetOption("locked", true)
            K.SetOption("arrowLabel", false)
        end)
    end)

    it("opens the standalone window when the client has no settings API", function()
        local K = W.start({ skipRoutes = true })
        W.fire("PLAYER_LOGIN")
        assert.is_false(K.Options.Register())
        assert.equals("window", K.Options.Open())
        assert.is_not_nil(K.Options.window)
        K.Command("options")
    end)

    it("registers in the add-on options when the Settings API exists", function()
        local K = W.start({ skipRoutes = true })
        local opened
        W.setGlobal("Settings", {
            RegisterCanvasLayoutCategory = function() return { GetID = function() return 7 end } end,
            RegisterAddOnCategory = function() end,
            OpenToCategory = function(id) opened = id end,
        })
        assert.is_true(K.Options.Register())
        assert.equals("settings", K.Options.Open())
        assert.equals(7, opened)
        W.setGlobal("Settings", nil)
    end)
end)
