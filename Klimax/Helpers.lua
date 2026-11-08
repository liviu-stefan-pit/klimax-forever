-- Helpers (PRD 7.8): bag check, sell-greys button, resupply, flight-path suggestion and hearthstone
-- awareness. The decisions are pure functions so the busted specs can test them. Everything here
-- is our own frame or a read; the only action is the sell button, which runs on the player's click
-- while a merchant window is open (selling must come from a hardware event).
local _, K = ...
local L = K.L
local C = K.Compat

local H = {}
K.Helpers = H

H.FOOD_MIN = 2          -- food stacks in the bags before an excursion
H.WATER_MIN = 2         -- water stacks for mana classes
H.AMMO_MIN = 40         -- arrows or bullets for Hunters
H.BAG_CACHE = 2         -- seconds a free-slot count is reused
H.HEARTH_ITEM = 6948
H.BAGS = { 0, 1, 2, 3, 4 }

-- Mana classes need water. Warriors and Rogues do not.
H.MANA_CLASSES = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true,
    WARLOCK = true, DRUID = true }
H.AMMO_CLASSES = { HUNTER = true }

local ITEM_CLASS_CONSUMABLE, ITEM_SUBCLASS_FOOD = 0, 5
local ITEM_CLASS_PROJECTILE, PROJECTILE_ARROW, PROJECTILE_BULLET = 6, 2, 3
local QUALITY_POOR = 0
local WATER_WORDS = { "water", "dew", "juice", "nectar", "tea", "milk" }

-- ---- Pure logic -------------------------------------------------------------------------------

-- True when the free slot count is at or below the threshold (default 3, the option's default).
function H.BagWarning(free, threshold)
    if free == nil then
        return false
    end
    return free <= (threshold or 3)
end

-- Which resupply items are low for a class. counts = {food = n, water = n, ammo = n} (stacks, and
-- ammo items). Returns a list of "food", "water", "ammo" in that order.
function H.Resupply(counts, class)
    local low = {}
    counts = counts or {}
    if (counts.food or 0) < H.FOOD_MIN then
        low[#low + 1] = "food"
    end
    if H.MANA_CLASSES[class] and (counts.water or 0) < H.WATER_MIN then
        low[#low + 1] = "water"
    end
    if H.AMMO_CLASSES[class] and (counts.ammo or 0) < H.AMMO_MIN then
        low[#low + 1] = "ammo"
    end
    return low
end

-- Whether an item name is a drink rather than food (the DB has no drink flag).
function H.IsWater(name)
    local lower = tostring(name or ""):lower()
    for _, word in ipairs(WATER_WORDS) do
        if lower:find(word, 1, true) then
            return true
        end
    end
    return false
end

-- Seconds left on a cooldown given its start and duration. 0 when it is ready.
function H.CooldownLeft(start, duration, now)
    if not start or not duration or duration <= 0 then
        return 0
    end
    return math.max(0, start + duration - now)
end

-- The known taxi node whose name contains the destination, or nil. Case-insensitive.
function H.FlyNode(target, knownNames)
    if not target or target == "" then
        return nil
    end
    local want = target:lower()
    for _, name in ipairs(knownNames or {}) do
        if name:lower():find(want, 1, true) then
            return name
        end
    end
    return nil
end

-- Grey (poor quality) slots from a list of {bag, slot, quality}, in bag order.
function H.GreySlots(slots)
    local out = {}
    for _, s in ipairs(slots or {}) do
        if s.quality == QUALITY_POOR then
            out[#out + 1] = s
        end
    end
    return out
end

-- Minutes for the hearthstone message, rounded up.
function H.Minutes(seconds)
    return math.max(1, math.ceil(seconds / 60))
end

-- ---- WoW side: bags ---------------------------------------------------------------------------

local freeCache = { at = -math.huge, value = nil }

-- Free slots in the backpack and bags, cached for H.BAG_CACHE seconds. nil when unknown.
function H.FreeSlots()
    local now = GetTime and GetTime() or 0
    if now - freeCache.at < H.BAG_CACHE then
        return freeCache.value
    end
    local free, any = 0, false
    for _, bag in ipairs(H.BAGS) do
        local n = C.GetBagSlotCount(bag)
        if n then
            any = true
            for slot = 1, n do
                if not C.GetBagSlot(bag, slot) then
                    free = free + 1
                end
            end
        end
    end
    freeCache.at = now
    freeCache.value = any and free or nil
    return freeCache.value
end

-- Calls fn(bag, slot, item) for every occupied bag slot.
local function eachItem(fn)
    for _, bag in ipairs(H.BAGS) do
        local n = C.GetBagSlotCount(bag) or 0
        for slot = 1, n do
            local item = C.GetBagSlot(bag, slot)
            if item then
                fn(bag, slot, item)
            end
        end
    end
end

-- Food, water and ammo stacks in the bags.
function H.CountSupplies()
    local counts = { food = 0, water = 0, ammo = 0 }
    eachItem(function(_, _, item)
        local cls = C.ItemClass(item.link)
        if not cls then
            return
        end
        if cls.classID == ITEM_CLASS_CONSUMABLE and cls.subclassID == ITEM_SUBCLASS_FOOD then
            local name = item.link:match("%[(.-)%]")
            if H.IsWater(name) then
                counts.water = counts.water + 1
            else
                counts.food = counts.food + 1
            end
        elseif cls.classID == ITEM_CLASS_PROJECTILE and (cls.subclassID == PROJECTILE_ARROW
            or cls.subclassID == PROJECTILE_BULLET) then
            counts.ammo = counts.ammo + item.stack
        end
    end)
    return counts
end

-- Sells every grey item. Only called from the sell button's click, with a merchant open.
function H.SellGreys()
    local slots = {}
    eachItem(function(bag, slot, item)
        slots[#slots + 1] = { bag = bag, slot = slot, quality = item.quality }
    end)
    local sold = 0
    for _, s in ipairs(H.GreySlots(slots)) do
        if C.UseBagSlot(s.bag, s.slot) then
            sold = sold + 1
        end
    end
    K.Print(string.format(L.SOLD_GREYS, sold))
    return sold
end

-- ---- Hints for the cursor step ----------------------------------------------------------------

local seenHint = {}   -- stable step key -> true once its chat line was printed

-- The one-line hint for the cursor step, or nil. Pure except for the reads it makes.
function H.CurrentHint()
    local E = K.Engine
    local _, step = E:Current()
    if not step then
        return nil
    end
    if step.t == "S" and step.reason == "hearth" then
        local start, duration = C.GetItemCooldown(H.HEARTH_ITEM)
        local left = H.CooldownLeft(start, duration, GetTime and GetTime() or 0)
        if left > 0 then
            return string.format(L.HINT_HEARTH_CD, H.Minutes(left))
        end
        return nil
    end
    if step.t == "S" and step.reason == "trainer" and K.Trainer then
        return K.Trainer.Hint()
    end
    if step.t == "V" then
        local threshold = K.Option("bagThreshold") or 3
        local free = H.FreeSlots()
        if H.BagWarning(free, threshold) then
            if not seenHint[step.k] then
                seenHint[step.k] = true
                K.Print(string.format(L.HINT_BAGS, free))
            end
            return string.format(L.HINT_BAGS, free)
        end
    end
    if step.t == "V" and step.to then
        local node = H.FlyNode(step.to, K.cdb and K.cdb.taxiKnown and H.KnownNames())
        if node then
            return string.format(L.HINT_FLY, node)
        end
    end
    if step.t == "V" then
        local low = H.Resupply(H.CountSupplies(), K.player and K.player.class)
        if #low > 0 then
            return string.format(L.HINT_LOW, table.concat(low, ", "))
        end
    end
    return nil
end

-- Known taxi node names, as a list.
function H.KnownNames()
    local out = {}
    for name in pairs(K.cdb.taxiKnown or {}) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

-- ---- Sell button (merchant open only) ---------------------------------------------------------

local sellButton

local function buildSellButton()
    local b = CreateFrame("Button", nil, UIParent)
    b:SetSize(150, 18)
    b:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -220, 140)
    b:SetFrameStrata("DIALOG")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.15, 0.15, 0.15, 0.9)
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    b.text:SetAllPoints()
    b.text:SetText(L.SELL_GREYS)
    b:SetScript("OnClick", function()
        H.SellGreys()
    end)
    b:Hide()
    return b
end

K.On("MERCHANT_SHOW", function()
    sellButton = sellButton or buildSellButton()
    sellButton:Show()
end)

K.On("MERCHANT_CLOSED", function()
    if sellButton then
        sellButton:Hide()
    end
end)

-- Hearthstone cooldown and bind location are read when the cursor step asks for them (CurrentHint).
-- Taxi nodes are remembered while the taxi map is open, so the flight hint works later.
K.On("TAXIMAP_OPENED", function()
    K.cdb.taxiKnown = K.cdb.taxiKnown or {}
    for _, node in ipairs(C.ReadTaxiNodes()) do
        if node.known then
            K.cdb.taxiKnown[node.name] = true
        end
    end
end)
