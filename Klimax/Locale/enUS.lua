-- Klimax UI and message strings (English). Route notes live in the route files.
local _, K = ...

K.L = {
    ADDON_NAME = "Klimax",
    ALLIANCE_SOON = "Alliance routes are coming in a later version. Klimax stays hidden for this character.",
    NO_ROUTE = "No route covers level %d yet for this character.",
    STARTED = "Route: %s (level %d). Type /klimax debug for details.",
    RESUMED = "Resumed route: %s.",
    SYNCED = "Sync done: %d step(s) marked complete from your quest log.",
    RESET_BAND = "Progress reset for %s.",
    RESET_ALL = "All Klimax progress reset.",
    SKIPPED = "Skipped 1 step (%d dependent step(s) skipped too).",
    UNKNOWN_BAND = "Unknown band %s. Try a route id like horde_horde_10-15, or a band like 10-15.",
    HELP = "Commands: /klimax (show or hide) | debug | sync | reset [all] | band <lo-hi> | dev level <1-60>",
    DEV_USAGE = "Dev: /klimax dev level <1-60> fakes the level for the engine.",
    DEV_LEVEL = "Dev: level faked to %d (your real character is unchanged).",

    -- actions (step type)
    ACT_ACCEPT = "Accept",
    ACT_COLLECT = "Kill / collect",
    ACT_TURNIN = "Turn in",
    ACT_TRAVEL = "Travel",
    ACT_FLY = "Fly",
    ACT_DISCOVER = "Discover flight path",
    ACT_BUY = "Buy",
    ACT_TRAINER = "Trainer",
    ACT_BIND = "Set hearthstone",
    ACT_HEARTH = "Use hearthstone",
    ACT_REPAIR = "Repair",
    ACT_NOTE = "Note",
    ACT_NONE = "Step",

    -- tag chips
    TAG_MAIN = "Main",
    TAG_OPTIONAL = "Optional",
    TAG_ELITE = "Optional · Elite",

    -- main window
    BTN_NEXT = "Next",
    BTN_SKIP = "Skip",
    BTN_SYNC = "Sync",
    BTN_MENU = "Menu",
    BTN_BACK = "Back",
    BTN_CLOSE = "Close",
    TIP_NEXT = "Mark this step done. A hub batch is marked done together.",
    TIP_SKIP = "Skip this step. Later steps that depend on it are skipped too.",
    TIP_SYNC = "Re-read your completed quests from the game.",
    TIP_MENU = "Reset, bands, step list and options.",
    STEP_COUNT = "Step %d of %d",
    HUB_PROGRESS = "Hub: %d of %d done",
    UI_NO_ROUTE = "No route for this character yet.",
    UI_DONE = "Nothing left in this band. Pick the next one from the menu.",
    UI_HIDDEN = "The remaining steps are hidden by your options.",
    UI_GATED = "Waiting for level %d.",

    -- arrow
    ARROW_YARDS = "%d yd",
    ARROW_TRAVEL = "Travel to %s",

    -- menu
    MENU_RESET_BAND = "Reset this band",
    MENU_RESET_ALL = "Reset whole guide",
    MENU_BANDS = "Band / zone",
    MENU_STEPS = "Step list",
    MENU_OPTIONS = "Options",
    MENU_AUDIT = "Audit (arrives in phase 09)",
    MENU_CLOSE = "Close",
    AUDIT_LATER = "The login audit arrives in a later phase.",
    BAND_LABEL = "Lvl %d–%d · %s",
    CONFIRM_RESET_BAND = "Reset progress for this band? Its done and skipped steps come back.",
    CONFIRM_RESET_ALL = "Reset progress for the whole guide? This cannot be undone.",
    YES = "Yes",
    NO = "No",

    -- step list
    LIST_TITLE = "Steps",
    LIST_HINT = "Click: focus a pending step. Right-click: un-skip.",

    -- options
    OPT_TITLE = "Klimax options",
    OPT_SHOW_OPTIONAL = "Show Optional steps",
    OPT_SHOW_ELITE = "Show Optional · Elite steps",
    OPT_AUTO = "Auto-advance on quest events",
    OPT_ARROW = "Arrow",
    OPT_ARROW_DETACH = "Detach arrow",
    OPT_HIDE_COMBAT = "Hide in combat",
    OPT_LOCK = "Lock window",
    OPT_BAG = "Bag-check threshold",
    OPT_FONT = "Font scale",
    OPT_SCALE = "Window scale",
    OPT_ALPHA = "Window opacity",
    OPT_OPPORTUNITIES = "On-the-way hints (rares, chests)",

    -- phase 08: reward advisor
    REWARD_UPGRADE = "Take %s: about %d%% better than your %s",
    REWARD_NEW_SLOT = "Take %s: it fills an empty slot",
    REWARD_SELL = "No upgrades here. Take %s (sells for %s)",
    REWARD_HINT = "The route suggests %s",

    -- phase 08: trainer
    HINT_TRAIN = "Train: %s",
    HINT_TRAIN_SKIP = " | skip: %s",
    TRAIN_TITLE = "Trainer: essentials",
    TRAIN_MONEY = "You have %s. Essentials cost %s.",
    TRAIN_SHORT = "Short by %s. Buy in this order: %s.",

    -- phase 08: helpers
    HINT_BAGS = "Bags almost full (%d free): sell greys first",
    HINT_FLY = "Fly to %s instead of walking",
    HINT_LOW = "Low on %s: restock before this trip",
    HINT_HEARTH_CD = "Hearthstone ready in %d min: walk or fly",
    HINT_HEARTH_BIND = "Bound to %s, the route expects %s",
    SELL_GREYS = "Sell grey items",
    SOLD_GREYS = "Sold %d grey item(s).",

    -- phase 08: opportunities and elites
    OPP_RARE = "Rare nearby: %s (lvl %s)",
    OPP_RARE_DROPS = "Rare nearby: %s (lvl %s). Can drop: %s",
    OPP_CHEST = "Chest nearby: %s",
    OPP_PLATE = "Rare mob nearby: %s",
    ELITE_TEXT = "You can now solo %s. Rewards %s.",
    ELITE_TEXT_PLAIN = "You can now solo %s.",
    ELITE_ADD = "Add to route",
    ELITE_DISMISS = "Dismiss",
}
