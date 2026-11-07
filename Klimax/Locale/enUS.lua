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
    HELP = "Commands: /klimax (show or hide) | debug | sync | reset [all] | band <lo-hi> | dev level <1-60>"
        .. " | audit [state] | dump | engine [name]",
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
    TIP_NEXT = "Mark this step done. A hub batch is marked done together.",
    TIP_SKIP = "Skip this step. Later steps that depend on it are skipped too.",
    TIP_SYNC = "Re-read your completed quests from the game.",
    TAB_GUIDE = "Guide",
    TAB_STEPS = "Steps",
    TAB_BANDS = "Bands",
    TAB_OPTIONS = "Options",
    TIP_CLOSE = "Hide the window. /klimax shows it again.",
    MORE_STEPS = "+ %d more",
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
    MENU_AUDIT = "Audit",
    BAND_LABEL = "Lvl %d–%d · %s",
    CONFIRM_RESET_BAND = "Reset progress for this band? Its done and skipped steps come back.",
    CONFIRM_RESET_ALL = "Reset progress for the whole guide? This cannot be undone.",
    YES = "Yes",
    NO = "No",

    -- step list
    LIST_HINT = "Click a pending step to focus it. Right-click a skipped step to un-skip.",

    -- options
    OPT_SHOW_OPTIONAL = "Show Optional steps",
    OPT_SHOW_ELITE = "Show Optional · Elite steps",
    OPT_AUTO = "Auto-advance on quest events",
    OPT_ARROW = "Arrow",
    OPT_ARROW_SCALE = "Arrow size",
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
    -- phase 09 level sync and audit (Sync.lua, Audit.lua)
    JUMP_TEXT = "You're level %d. Jump to Lvl %d-%d?",
    JUMP_YES = "Jump",
    JUMP_NO = "Stay",
    GEAR_TEXT = "Low level but rewards a great %s for you. Do it or skip?",
    GEAR_ITEM_FALLBACK = "upgrade",
    GEAR_DO = "Do it",
    GEAR_SKIP = "Skip",
    TRAVEL_HINT = "Next step is in %s (%d, %d).",
    RADAR_TEXT = "You're in a low-level zone (%s, levels %d-%d). Head to %s (%d, %d) to continue.",
    MISSED_TEXT = "Missed reward: %s is still worth it (%s). Go there?",
    MISSED_GO = "Go there",
    MISSED_IGNORE = "Ignore",
    AUDIT_NONE = "Audit: nothing to fix right now.",

    -- phase 18 diagnostics (Diag.lua, Core.lua)
    DUMP_SAVED = "Dump saved for %s: %d quest log line(s), %d completed route quest(s), %d disagreement(s)."
        .. " /reload or log out, then send WTF/Account/<account>/SavedVariables/Klimax.lua.",
    AUDIT_STATE_HEAD = "State audit: %d disagreement(s) between the guide and the game in %s:",
    AUDIT_STATE_LINE = "%s (quest %d): game %s, guide %s. %s",
    AUDIT_STATE_UNCERTAIN = " (may be under a collapsed header)",
    AUDIT_STATE_MORE = "... and %d more. /klimax dump saves the full list.",
    AUDIT_STATE_CLEAN = "State audit: the guide agrees with the game for every quest step in %s.",
    AUDIT_STATE_NO_API = "State audit: this client has no completed-quest API, so turn-ins cannot be checked.",
    AUDIT_STATE_HIDDEN = "State audit: %d quest(s) are hidden under collapsed quest log headers."
        .. " Expand all headers for an exact check.",
    ENGINE_CURRENT = "Engine: %s (available: %s).",
    ENGINE_SET = "Engine set to %s. /reload to apply.",
    ENGINE_UNKNOWN = "Unknown engine %s (available: %s).",
    DIAG_done_not_accepted = "Marked done, but the quest is not in your log and not completed.",
    DIAG_done_not_complete = "Marked done, but the quest's objectives are not complete.",
    DIAG_done_not_turned_in = "Marked done, but the game does not show the quest as turned in.",
    DIAG_stale_turnin = "Still shown, but the quest was already turned in.",
    DIAG_stale_step = "Still shown, but the quest was already turned in.",
    DIAG_pending_failed = "Still shown, but the quest has failed. Abandon and re-accept it.",
    DIAG_turnin_not_in_log = "Turn-in shown, but the quest is not in your log.",
    DIAG_complete_not_in_log = "Objective shown, but the quest is not in your log.",
    DIAG_archived_in_log = "Archived as outgrown, but the quest is still in your log.",
}
