-- luacheck configuration for Klimax (WoW Forever, Lua 5.1 client)
std = "lua51"

-- The add-on is a single Lua environment: keep warnings for shadowing and unused values.
max_line_length = 120
ignore = {
    "212/self", -- unused argument 'self' in methods
}

-- Globals the add-on writes to (SavedVariables and cross-file route registration).
globals = {
    "KlimaxDB",
    "KlimaxCharDB",
    "Klimax_RegisterRoute",
    "Klimax_RegisterIndex",
    "Klimax_RegisterZones",
    "SLASH_KLIMAX1",
    "SLASH_KLIMAX2",
    "SlashCmdList",
}

-- WoW API the add-on reads (PRD §7). Add to this list only when a new API is used.
read_globals = {
    -- frames and UI
    "CreateFrame", "UIParent", "GameTooltip", "DEFAULT_CHAT_FRAME", "StaticPopupDialogs",
    "StaticPopup_Show", "UIErrorsFrame", "Minimap",
    -- player and faction
    "UnitFactionGroup", "UnitRace", "UnitClass", "UnitLevel", "UnitName",
    "UnitClassification", "GetPlayerFacing", "GetBindLocation",
    -- map
    "C_Map",
    -- quests
    "C_QuestLog", "GetNumQuestLogEntries", "GetQuestLogTitle", "GetQuestsCompleted",
    "GetQuestItemLink", "GetQuestLogIndexByID", "QuestUtils_IsQuestWatched",
    -- items, bags, inventory
    "C_Container", "GetContainerNumFreeSlots", "GetContainerNumSlots",
    "GetContainerItemLink", "GetContainerItemInfo", "UseContainerItem",
    "GetItemInfo", "GetItemStats", "GetItemCooldown", "GetItemCount",
    "GetInventoryItemLink", "GetItemInfoInstant", "Item", "ItemLocation",
    "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink",
    "BuyMerchantItem", "SellItem",
    -- spells, trainers, flight paths, hearthstone
    "GetSpellInfo", "IsSpellKnown", "GetNumTrainerServices", "GetTrainerServiceInfo",
    "GetMoney", "NumTaxiNodes", "TaxiNodeName", "TaxiNodeGetType",
    -- timing and utilities
    "GetTime", "C_Timer", "CreateColor", "date", "time",
    "strsplit", "strtrim", "wipe", "tinsert", "tremove", "format", "floor", "abs", "sqrt",
    "atan2", "min", "max", "random", "pairs", "ipairs", "select", "type",
    "tostring", "tonumber", "unpack", "print", "geterrorhandler", "debugstack",
    "hooksecurefunc", "InterfaceOptionsFrame_OpenToCategory", "Settings",
    -- events and frames for the step engine
    "C_Timer",
}

-- Files that are generated or vendored are not linted.
exclude_files = {
    "Klimax/Routes/**",
}
