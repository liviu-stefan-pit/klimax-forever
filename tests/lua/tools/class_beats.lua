-- Renders docs/CLASS_BEATS.md from the class modules (Klimax/Class/*.lua), the trainer filters and
-- the locale (phase 24). Used by gen_class_beats.lua (writes the file) and by class_spec.lua (checks
-- the file is up to date).
local M = {}

M.ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
M.NAMES = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid" }

-- Loads the files the document needs into a fresh add-on table (no WoW API needed).
function M.Load(root)
    root = root or "Klimax/"
    local K = {}
    for _, file in ipairs({ "Locale/enUS.lua", "Class/Class.lua", "Class/Hunter.lua", "Class/Classes.lua",
        "Data/TrainerFilters.lua" }) do
        local chunk = assert(loadfile(root .. file))
        chunk("Klimax", K)
    end
    return K
end

local function itemName(id)
    local names = { [6947] = "Instant Poison", [5140] = "Flash Powder", [17030] = "Ankh",
        [17031] = "Rune of Teleportation", [17032] = "Rune of Portals", [17034] = "Maple Seed",
        [6265] = "Soul Shard" }
    return names[id] or ("item " .. id)
end

function M.Render(K)
    local L = K.L
    local out = {
        "# Klimax class beats (levels 1 to 40)",
        "",
        "Generated from `Klimax/Class/*.lua`, `Klimax/Data/TrainerFilters.lua` and `Klimax/Locale/enUS.lua`"
            .. " by `lua tests/lua/tools/gen_class_beats.lua`. Do not edit by hand; `tests/lua/class_spec.lua`"
            .. " fails when it is stale.",
        "",
        "Beats marked **reminder** also appear in the plan on that level. Reagents are kept in the bags from"
            .. " the level shown; the services engine adds a stop at the right vendor when they run low."
            .. " Class quests on the Forever server still need an in-game check (phase 24 checklist).",
    }
    for _, token in ipairs(M.ORDER) do
        local m = K.Class.Get(token)
        out[#out + 1] = ""
        out[#out + 1] = "## " .. M.NAMES[token]
        out[#out + 1] = ""
        out[#out + 1] = "| Level | Kind | Beat |"
        out[#out + 1] = "|---|---|---|"
        for _, beat in ipairs(m.beats or {}) do
            local text = L[K.Class.BeatKey(token, beat)] or "?"
            if beat.remind then
                text = text .. " **reminder**"
            end
            out[#out + 1] = string.format("| %d | %s | %s |", beat.lv, L["BEAT_KIND_" .. beat.kind] or beat.kind, text)
        end
        if m.reagents and #m.reagents > 0 then
            local parts = {}
            for _, r in ipairs(m.reagents) do
                parts[#parts + 1] = string.format("%s (from %d, keep %d)", itemName(r.item), r.from, r.min)
            end
            out[#out + 1] = ""
            out[#out + 1] = "Reagents: " .. table.concat(parts, "; ") .. "."
        end
        if m.makes then
            local parts = {}
            for _, reason in ipairs({ "water", "food" }) do
                if m.makes[reason] then
                    parts[#parts + 1] = string.format("%s from %d", reason, m.makes[reason])
                end
            end
            out[#out + 1] = ""
            out[#out + 1] = "Makes its own supplies: " .. table.concat(parts, ", ") .. "."
        end
        local bands = K.TrainerFilters[token] or {}
        for _, band in ipairs(bands) do
            out[#out + 1] = ""
            out[#out + 1] = string.format("Trainer from level %d: buy %s; can wait: %s.", band.from,
                table.concat(band.essential or {}, ", "), table.concat(band.skipForNow or {}, ", "))
        end
    end
    return table.concat(out, "\n") .. "\n"
end

return M
