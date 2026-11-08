-- Reward advisor (PRD 7.6). On QUEST_COMPLETE it scores the reward choices and highlights ONE of
-- them. It never selects a reward and never clicks: the player always makes the choice.
--
-- Scoring and the decision are pure functions (K.Rewards.Score, K.Rewards.Evaluate) so the busted
-- specs can test them without a client. The WoW calls (item cache, equipped items, glow) are below.
local _, K = ...
local L = K.L
local C = K.Compat

local R = {}
K.Rewards = R

R.UPGRADE_RATIO = 1.05   -- a candidate must beat the equipped item by 5% (PRD 7.6)
R.DPS_WEIGHT = 3         -- points per unit of weapon DPS, for preferred weapon types
R.ARMOR_WEIGHT = 0.1     -- points per armour point, for usable armour

local ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR = 2, 4
local ARMOR_MISC = 0     -- armour class, subclass 0: rings, necks, trinkets, cloaks

-- GetItemStats keys to the short stat names used in ClassWeights.lua.
R.STAT_KEYS = {
    ITEM_MOD_STRENGTH_SHORT = "Str", ITEM_MOD_AGILITY_SHORT = "Agi", ITEM_MOD_STAMINA_SHORT = "Sta",
    ITEM_MOD_INTELLECT_SHORT = "Int", ITEM_MOD_SPIRIT_SHORT = "Spi",
}
R.DPS_KEY = "ITEM_MOD_DAMAGE_PER_SECOND_SHORT"   -- only if the client reports it
R.ARMOR_KEY = "ARMOR"

-- Equip location to the inventory slot compared against (the first slot of two-slot locations).
R.SLOT = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4, INVTYPE_CHEST = 5,
    INVTYPE_ROBE = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9,
    INVTYPE_HAND = 10, INVTYPE_FINGER = 11, INVTYPE_TRINKET = 13, INVTYPE_CLOAK = 15,
    INVTYPE_WEAPON = 16, INVTYPE_2HWEAPON = 16, INVTYPE_WEAPONMAINHAND = 16,
    INVTYPE_WEAPONOFFHAND = 17, INVTYPE_SHIELD = 17, INVTYPE_HOLDABLE = 17,
    INVTYPE_RANGED = 18, INVTYPE_RANGEDRIGHT = 18,
}

-- Copper as "12g 3s 4c" (the text version of the coin display).
function R.Money(copper)
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return string.format("%dg %ds %dc", g, s, c)
end

-- Short stats table from a GetItemStats table: {Str=.., Agi=.., armor=.., dps=..}.
function R.ShortStats(raw)
    local out = {}
    for key, value in pairs(raw or {}) do
        local short = R.STAT_KEYS[key]
        if short then
            out[short] = (out[short] or 0) + value
        end
    end
    out.dps = raw and raw[R.DPS_KEY] or nil
    out.armor = raw and raw[R.ARMOR_KEY] or nil
    return out
end

-- Whether a class can use an item well at a level. info = {equipLoc, classID, subclassID, stats}.
-- Armour must match the class's armour table (with the level gate). Weapons must be a preferred
-- type. Jewellery and cloaks (armour subclass 0) are usable by everyone.
function R.Usable(info, class, level)
    local cw = K.ClassWeights and K.ClassWeights[class]
    if not info or not cw or not info.equipLoc or info.equipLoc == "" or not R.SLOT[info.equipLoc] then
        return false
    end
    if info.classID == ITEM_CLASS_ARMOR and info.subclassID ~= ARMOR_MISC then
        local minLevel = cw.armor[info.subclassID]
        return minLevel ~= nil and level >= minLevel
    end
    if info.classID == ITEM_CLASS_WEAPON then
        return cw.weapons[info.subclassID] == true
    end
    return info.classID == ITEM_CLASS_ARMOR
end

-- Score of an item for a class at a level, or nil when the class cannot use it well.
-- Score = sum(stat * weight) + DPS * DPS_WEIGHT (preferred weapons) + armour * ARMOR_WEIGHT.
function R.Score(info, class, level)
    if not R.Usable(info, class, level) then
        return nil
    end
    local cw = K.ClassWeights[class]
    local stats = info.stats or {}
    local score = 0
    for stat, weight in pairs(cw.stats) do
        score = score + (stats[stat] or 0) * weight
    end
    if info.classID == ITEM_CLASS_WEAPON and stats.dps then
        score = score + stats.dps * R.DPS_WEIGHT
    end
    if info.classID == ITEM_CLASS_ARMOR and info.subclassID ~= ARMOR_MISC and stats.armor then
        score = score + stats.armor * R.ARMOR_WEIGHT
    end
    return score
end

-- Decides what to highlight. entries: list of {index, name, sellPrice, info} (info nil when the
-- item data is not cached yet). equippedInfo(slot) returns the equipped item's info or nil.
-- hintId is the route's reward.preferItem for this quest, if any.
-- Returns {kind="upgrade", index, name, pct, equipped} | {kind="sell", index, name, sellPrice}
--         | {kind="hint", index} | nil.
function R.Evaluate(entries, class, level, equippedInfo, hintId)
    local anyLoaded = false
    for _, e in ipairs(entries) do
        if e.info then
            anyLoaded = true
        end
    end
    if not anyLoaded then
        for _, e in ipairs(entries) do
            if hintId and e.id == hintId then
                return { kind = "hint", index = e.index, name = e.name or tostring(e.id) }
            end
        end
        return nil
    end

    local pick
    for _, e in ipairs(entries) do
        local score = e.info and R.Score(e.info, class, level)
        if score and score > 0 then
            local slot = R.SLOT[e.info.equipLoc]
            local cur = slot and equippedInfo(slot)
            local curScore = cur and R.Score(cur, class, level) or 0
            if curScore <= 0 or score > curScore * R.UPGRADE_RATIO then
                local pct = nil
                if curScore > 0 then
                    pct = math.floor((score / curScore - 1) * 100 + 0.5)
                end
                if not pick or score > pick.score then
                    pick = { index = e.index, name = e.name, pct = pct, score = score,
                             equipped = cur and cur.name or nil }
                end
            end
        end
    end
    if pick then
        return { kind = "upgrade", index = pick.index, name = pick.name, pct = pick.pct, equipped = pick.equipped }
    end

    local sell
    for _, e in ipairs(entries) do
        if e.info and e.sellPrice and e.sellPrice > 0 and (not sell or e.sellPrice > sell.sellPrice) then
            sell = e
        end
    end
    if sell then
        return { kind = "sell", index = sell.index, name = sell.name, sellPrice = sell.sellPrice }
    end
    return nil
end

-- The sentence shown for a recommendation.
function R.Message(rec)
    if not rec then
        return nil
    end
    if rec.kind == "upgrade" and rec.pct then
        return string.format(L.REWARD_UPGRADE, rec.name, rec.pct, rec.equipped or "item")
    elseif rec.kind == "upgrade" then
        return string.format(L.REWARD_NEW_SLOT, rec.name)
    elseif rec.kind == "sell" then
        return string.format(L.REWARD_SELL, rec.name, R.Money(rec.sellPrice))
    end
    return string.format(L.REWARD_HINT, rec.name or "?")
end

-- ---- WoW side ---------------------------------------------------------------------------------

-- Item info for a link, once the item is cached: {name, sellPrice, info = {...}}, or nil.
function R.ReadItem(link)
    local data = C.GetItemInfo(link)
    if not data then
        return nil
    end
    local cls = C.ItemClass(link) or {}
    local info = {
        equipLoc = data.equipLoc, classID = data.classID or cls.classID,
        subclassID = data.subclassID or cls.subclassID, stats = R.ShortStats(C.GetItemStats(link)),
    }
    return { name = data.name, sellPrice = data.sellPrice, info = info }
end

-- The reward the guide suggests for the quest whose reward frame is open, or nil: the first item of
-- the compiled quest's upgrade list (record `ru`, phase 24 gear advisor).
function R.HintFor(questID)
    local rec = questID and K.WorldDB and K.WorldDB.Quest and K.WorldDB.Quest(questID)
    return rec and rec.ru and rec.ru[1] or nil
end

local function equippedInfo(slot)
    local link = C.GetEquippedLink(slot)
    local data = link and R.ReadItem(link)
    return data and data.info or nil
end

-- Whether an item is useful now: a bag while there are free slots, or an upgrade over the equipped
-- item. Returns useful, score, name. Uncached items are not useful yet. (Phase 29: moved here from
-- the Audit module; the planner's gear advisor calls it.)
function R.Useful(itemID, class, level, freeSlots)
    local data = R.ReadItem(itemID)
    if not data then
        return false, 0, nil
    end
    local info = data.info
    if info.classID == 1 then
        return (freeSlots or 0) > 0, 1, data.name
    end
    local score = R.Score(info, class, level) or 0
    local rec = R.Evaluate({
        { index = 1, id = itemID, name = data.name, sellPrice = data.sellPrice, info = info },
    }, class, level, equippedInfo, nil)
    return rec ~= nil and rec.kind == "upgrade", score, data.name
end

local glow = {}   -- index -> texture on the reward button

function R.Clear()
    for _, tex in pairs(glow) do
        tex:Hide()
    end
end

-- Draws a gold glow on reward button i. Never clicks or selects it.
function R.Highlight(i)
    local button = _G["QuestInfoItem" .. tostring(i)]
    if not button or not button.CreateTexture then
        return
    end
    local tex = glow[i]
    if not tex then
        tex = button:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\Buttons\\WHITE8X8")
        tex:SetVertexColor(1, 0.82, 0, 0.35)
        glow[i] = tex
    end
    tex:Show()
end

-- Rebuilds the recommendation for the open reward frame and highlights it.
function R.Finish(entries, questID)
    local class = K.player and K.player.class
    local level = (K.player and K.player.level) or 1
    local rec = R.Evaluate(entries, class, level, function(slot)
        local link = C.GetEquippedLink(slot)
        local data = link and R.ReadItem(link)
        return data and data.info or nil
    end, R.HintFor(questID))
    R.Clear()
    if rec then
        R.Highlight(rec.index)
        local text = R.Message(rec)
        K.Print(text)
        K.Log("reward advice", rec.kind, rec.index)
    end
    return rec
end

-- Scans the reward choices on QUEST_COMPLETE. Uncached items are waited for with
-- ContinueOnItemLoad, then the decision is made once.
function R.Scan()
    R.Clear()
    local n = C.GetNumQuestChoices()
    if n < 2 then
        return
    end
    local questID = C.GetOpenQuestID()
    local entries = {}
    local pending = 0
    for i = 1, n do
        local link = C.GetQuestChoiceLink(i)
        local entry = { index = i, id = C.ItemIdFromLink(link), link = link }
        entries[i] = entry
        if link then
            local data = R.ReadItem(link)
            if data then
                entry.name, entry.sellPrice, entry.info = data.name, data.sellPrice, data.info
            elseif entry.id and Item and Item.CreateFromItemID then
                pending = pending + 1
                Item:CreateFromItemID(entry.id):ContinueOnItemLoad(function()
                    local loaded = R.ReadItem(link)
                    if loaded then
                        entry.name, entry.sellPrice, entry.info = loaded.name, loaded.sellPrice, loaded.info
                    end
                    pending = pending - 1
                    if pending == 0 then
                        R.Finish(entries, questID)
                    end
                end)
            end
        end
    end
    if pending == 0 then
        R.Finish(entries, questID)
    end
end

K.On("QUEST_COMPLETE", function()
    R.Scan()
end)

K.On("QUEST_FINISHED", function()
    R.Clear()
end)
