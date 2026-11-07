-- Trainer filters for solo leveling (PRD 7.7). Curated by hand. Spells are matched by NAME against
-- the trainer window (GetTrainerServiceInfo), so no spell IDs are needed. A name that does not
-- appear is simply ignored.
--
-- Shape: K.TrainerFilters[CLASS] = list of bands { from = level, essential = {...}, skipForNow = {...} }.
-- The band in force is the last one whose `from` is at or below the player's level.
--   essential   spells worth the gold for a solo leveler at that point
--   skipForNow  spells that can wait (utility, group or pet-only, or low value while leveling)
--
-- REVIEW: this is a first pass for all nine classes. Please sanity-check ONE class (Hunter is
-- the suggested one) before the others are trusted.
local _, K = ...

K.TrainerFilters = {
    HUNTER = {
        { from = 1,
          essential = {
              "Raptor Strike",
              "Serpent Sting",
              "Arcane Shot",
              "Hunter's Mark",
              "Aspect of the Hawk",
              "Aspect of the Monkey",
              "Mend Pet",
              "Concussive Shot",
          },
          skipForNow = { "Eyes of the Beast", "Aspect of the Pack", "Feed Pet" } },
        { from = 30,
          essential = {
              "Multi-Shot",
              "Wing Clip",
              "Aspect of the Cheetah",
              "Scare Beast",
              "Aspect of the Hawk",
          },
          skipForNow = { "Eyes of the Beast", "Aspect of the Pack", "Feed Pet", "Track Humanoids" } },
    },
    WARRIOR = {
        { from = 1,
          essential = {
              "Heroic Strike",
              "Charge",
              "Bloodrage",
              "Battle Shout",
              "Thunder Clap",
              "Rend",
              "Demoralizing Shout",
              "Hamstring",
          },
          skipForNow = { "Berserker Rage", "Intercept", "Retaliation", "Disarm" } },
        { from = 30,
          essential = { "Overpower", "Sunder Armor", "Execute", "Cleave", "Bloodthirst" },
          skipForNow = { "Pummel", "Shield Bash", "Berserker Rage" } },
    },
    PALADIN = {
        { from = 1,
          essential = {
              "Holy Light",
              "Flash of Light",
              "Seal of Righteousness",
              "Judgement",
              "Blessing of Might",
              "Devotion Aura",
          },
          skipForNow = { "Hammer of Justice", "Divine Protection" } },
        { from = 30,
          essential = { "Consecration", "Seal of Command", "Holy Shield", "Blessing of Kings" },
          skipForNow = { "Blessing of Freedom", "Blessing of Sanctuary" } },
    },
    ROGUE = {
        { from = 1,
          essential = {
              "Sinister Strike",
              "Eviscerate",
              "Slice and Dice",
              "Kick",
              "Gouge",
              "Stealth",
              "Ambush",
          },
          skipForNow = { "Pick Lock", "Sprint", "Detect Traps" } },
        { from = 30,
          essential = { "Backstab", "Kidney Shot", "Riposte", "Blade Flurry", "Adrenaline Rush" },
          skipForNow = { "Pick Pocket", "Vanish" } },
    },
    PRIEST = {
        { from = 1,
          essential = {
              "Power Word: Shield",
              "Lesser Heal",
              "Heal",
              "Smite",
              "Shadow Word: Pain",
              "Renew",
              "Holy Fire",
          },
          skipForNow = { "Fear Ward", "Shadowguard", "Inner Fire" } },
        { from = 30,
          essential = { "Mind Blast", "Psychic Scream", "Prayer of Healing", "Mana Burn" },
          skipForNow = { "Shackle Undead", "Fear Ward" } },
    },
    SHAMAN = {
        { from = 1,
          essential = {
              "Lightning Bolt",
              "Healing Wave",
              "Flame Shock",
              "Earth Shock",
              "Rockbiter Weapon",
              "Stoneskin Totem",
              "Searing Totem",
              "Lightning Shield",
          },
          skipForNow = { "Ghost Wolf", "Water Walking" } },
        { from = 30,
          essential = { "Frost Shock", "Chain Lightning", "Windfury Weapon", "Grounding Totem" },
          skipForNow = { "Totemic Call", "Far Sight" } },
    },
    MAGE = {
        { from = 1,
          essential = {
              "Frostbolt",
              "Fireball",
              "Arcane Missiles",
              "Frost Armor",
              "Fire Blast",
              "Conjure Food",
              "Conjure Water",
              "Arcane Explosion",
          },
          skipForNow = { "Dampen Magic", "Amplify Magic", "Remove Curse" } },
        { from = 30,
          essential = { "Frost Nova", "Blink", "Polymorph", "Evocation", "Ice Barrier" },
          skipForNow = { "Conjure Mana Gem", "Portal: Orgrimmar", "Portal: Undercity" } },
    },
    WARLOCK = {
        { from = 1,
          essential = {
              "Shadow Bolt",
              "Corruption",
              "Curse of Agony",
              "Immolate",
              "Drain Life",
              "Life Tap",
              "Fear",
              "Summon Imp",
          },
          skipForNow = { "Create Healthstone", "Eye of Kilrogg", "Ritual of Summoning" } },
        { from = 30,
          essential = {
              "Siphon Life",
              "Death Coil",
              "Searing Pain",
              "Summon Voidwalker",
              "Curse of Recklessness",
          },
          skipForNow = { "Enslave Demon", "Create Soulstone", "Summon Succubus" } },
    },
    DRUID = {
        { from = 1,
          essential = {
              "Wrath",
              "Healing Touch",
              "Moonfire",
              "Rejuvenation",
              "Thorns",
              "Mark of the Wild",
              "Cat Form",
              "Bear Form",
          },
          skipForNow = { "Dash", "Prowl", "Hibernate" } },
        { from = 30,
          essential = { "Starfire", "Entangling Roots", "Regrowth", "Feral Charge", "Faerie Fire (Feral)" },
          skipForNow = { "Aquatic Form", "Travel Form", "Track Humanoids" } },
    },
}
