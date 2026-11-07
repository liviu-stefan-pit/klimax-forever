-- Class item rules for the reward advisor (PRD 7.6). Curated by hand, leveling-oriented, not
-- min-max. Explainable on purpose: a stat weight says how much one point of that stat is worth
-- to a leveling character of that class.
--
-- Fields per class:
--   armor     [armorSubclassID] = minimum level to wear it. Absent means never usable.
--             Armor subclasses: 1 cloth, 2 leather, 3 mail, 4 plate, 6 shield.
--   weapons   [weaponSubclassID] = true for preferred weapon types. Other weapons get no DPS term.
--             Weapon subclasses: 0 1H axe, 1 2H axe, 2 bow, 3 gun, 4 1H mace, 5 2H mace,
--             6 polearm, 7 1H sword, 8 2H sword, 10 staff, 13 fist, 15 dagger, 16 thrown,
--             18 crossbow, 19 wand.
--   stats     weight per stat name (Str, Agi, Sta, Int, Spi). Used as Σ stat × weight.
--
-- Mail and plate rules follow the phase 08 brief: mail at 40 for Hunter and Shaman, plate at 40
-- for Warrior and Paladin. Paladin mail at 40 is the same rule as Hunter and Shaman.
-- Reviewed in phase 24 (offline, against Classic weapon skills): Paladins gain two-handed axes and
-- polearms, Hunters fist weapons and staves, Warriors staves; Shaman weights lean to Enhancement
-- (Strength) for leveling. Still to confirm on the Forever server (phase 24 in-game checklist).
local _, K = ...

local CLOTH, LEATHER, MAIL, PLATE, SHIELD = 1, 2, 3, 4, 6

K.ClassWeights = {
    WARRIOR = {
        armor = { [LEATHER] = 1, [MAIL] = 1, [PLATE] = 40, [SHIELD] = 1 },
        weapons = {
            [0] = true,
            [1] = true,
            [4] = true,
            [5] = true,
            [6] = true,
            [7] = true,
            [8] = true,
            [10] = true,
            [13] = true,
            [15] = true,
        },
        stats = { Str = 1.0, Agi = 0.6, Sta = 0.4 },
    },
    PALADIN = {
        armor = { [LEATHER] = 1, [MAIL] = 40, [PLATE] = 40, [SHIELD] = 1 },
        weapons = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true },
        stats = { Str = 1.0, Sta = 0.6, Int = 0.3, Spi = 0.2 },
    },
    HUNTER = {
        armor = { [LEATHER] = 1, [MAIL] = 40 },
        weapons = {
            [0] = true,
            [1] = true,
            [2] = true,
            [3] = true,
            [6] = true,
            [7] = true,
            [8] = true,
            [10] = true,
            [13] = true,
            [15] = true,
            [18] = true,
        },
        stats = { Agi = 1.0, Sta = 0.5, Str = 0.2, Int = 0.2 },
    },
    ROGUE = {
        armor = { [LEATHER] = 1 },
        weapons = {
            [0] = true,
            [4] = true,
            [7] = true,
            [15] = true,
            [16] = true,
            [2] = true,
            [3] = true,
            [18] = true,
        },
        stats = { Agi = 1.0, Str = 0.4, Sta = 0.4 },
    },
    PRIEST = {
        armor = { [CLOTH] = 1 },
        weapons = { [4] = true, [10] = true, [15] = true, [19] = true },
        stats = { Spi = 1.0, Int = 0.8, Sta = 0.5 },
    },
    SHAMAN = {
        armor = { [LEATHER] = 1, [MAIL] = 40, [SHIELD] = 1 },
        weapons = { [0] = true, [4] = true, [10] = true, [13] = true, [15] = true },
        stats = { Str = 0.8, Int = 0.6, Sta = 0.6, Agi = 0.5, Spi = 0.2 },
    },
    MAGE = {
        armor = { [CLOTH] = 1 },
        weapons = { [7] = true, [10] = true, [15] = true, [19] = true },
        stats = { Int = 1.0, Sta = 0.5, Spi = 0.3 },
    },
    WARLOCK = {
        armor = { [CLOTH] = 1 },
        weapons = { [7] = true, [10] = true, [15] = true, [19] = true },
        stats = { Int = 0.8, Sta = 0.6, Spi = 0.3 },
    },
    DRUID = {
        armor = { [CLOTH] = 1, [LEATHER] = 1 },
        weapons = { [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
        stats = { Int = 0.5, Sta = 0.6, Agi = 0.6, Str = 0.4, Spi = 0.4 },
    },
}
