-- Step menu (phase 22, DYNAMIC_GUIDE_PLAN s4.5): right-click a step for Skip this quest, Skip only
-- this step, Mark done, Restore, Pin next, Why is this here?, Show NPC info and Point arrow here.
--
-- SM.Items and the text helpers are pure (specs test them); SM.Do runs an action; SM.Open shows the
-- menu as a plain frame of buttons (no Blizzard dropdown templates, so nothing is tainted).
local _, K = ...
local L = K.L
local T = K.Theme

local SM = {}
K.StepMenu = SM

SM.ORDER = { "skipQuest", "skipStep", "markDone", "restore", "pin", "unpin", "why", "npc", "arrow" }

local HIDDEN = { skipped = true, archived = true, cascade = true }

-- Menu entries for a step: an ordered list of keys. state: the step's effective state; stored: its
-- stored state; questSkipped: the quest is in the skip set; pinned: the step is the pin.
function SM.Items(step, state, stored, questSkipped, pinned)
    local items = {}
    local function add(key)
        items[#items + 1] = key
    end
    if step.q and not questSkipped then
        add("skipQuest")
    end
    if state == "pending" or state == "cascade" then
        add("skipStep")
    end
    if state == "pending" then
        add("markDone")
    end
    if questSkipped or HIDDEN[state] or stored == "hidden" or stored == "skipped" or stored == "archived" then
        add("restore")
    end
    if pinned then
        add("unpin")
    elseif state == "pending" then
        add("pin")
    end
    add("why")
    if step.npc then
        add("npc")
    end
    if step.z and step.x and step.y and state == "pending" then
        add("arrow")
    end
    return items
end

-- Lines for "Why is this here?" on a band step: what the game says about the quest and the step.
function SM.WhyLines(step, state)
    local lines = {}
    local name = step.n or step.note or ""
    lines[#lines + 1] = string.format(L.MENU_WHY_HEAD, name, step.q or 0)
    if step.q and K.State and K.State:Ready() then
        local qs, reason = K.State:Get(step.q)
        local text = L["QSTATE_" .. tostring(qs)] or tostring(qs)
        if reason then
            text = text .. " (" .. (L["QREASON_" .. reason] or reason) .. ")"
        end
        lines[#lines + 1] = string.format(L.MENU_WHY_STATE, text)
    end
    if step.ql and K.player and K.player.level then
        local colour = K.Plan.Score.Colour(step.ql, K.player.level, K.Plan.Weights.DEFAULT.levelSlack)
        lines[#lines + 1] = string.format(L.MENU_WHY_LEVEL, step.ql, L["PLAN_COLOUR_" .. colour] or colour)
    end
    lines[#lines + 1] = string.format(L.MENU_WHY_STEP, L["EFF_" .. tostring(state)] or tostring(state))
    -- the planner's view, when it plans this quest
    local plan = K.Planner and K.Planner.plan
    for n, s in ipairs(plan and plan.steps or {}) do
        if s.q == step.q and s.t == step.t then
            lines[#lines + 1] = string.format(L.MENU_WHY_PLAN, n, K.Planner.Why(s))
            break
        end
    end
    return lines
end

-- Lines for "Show NPC info": name, subtitle, roles and where it stands (compiled world data).
function SM.NpcLines(step)
    local npc = step.npc and K.WorldDB and K.WorldDB.Npc(step.npc)
    if not npc then
        return { L.MENU_NPC_NONE }
    end
    local lines = { string.format(L.MENU_NPC_HEAD, npc.n or "?", npc.sub and (" <" .. npc.sub .. ">") or "") }
    if npc.r and #npc.r > 0 then
        lines[#lines + 1] = string.format(L.MENU_NPC_ROLES, table.concat(npc.r, ", "))
    end
    for _, p in ipairs(npc.p or {}) do
        local zone = K.zones and K.zones[p[1]]
        lines[#lines + 1] = string.format(L.MENU_NPC_AT, zone and zone[1] or tostring(p[1]), p[2], p[3])
    end
    return lines
end

-- Skipped quests for the "Skipped" list: {q, name}, sorted by quest id.
function SM.SkippedQuests()
    local out = {}
    for q, v in pairs((K.cdb and K.cdb.skipQuests) or {}) do
        if v then
            local rec = K.WorldDB and K.WorldDB.Quest(q)
            local name = rec and rec.n
            if not name then
                for _, s in ipairs(K.Engine.steps or {}) do
                    if s.q == q and s.n then
                        name = s.n
                        break
                    end
                end
            end
            out[#out + 1] = { q = q, name = name or ("#" .. q) }
        end
    end
    table.sort(out, function(a, b) return a.q < b.q end)
    return out
end

-- ---- Actions ------------------------------------------------------------------------------------

local function refresh()
    if K.UI and K.UI.Refresh then
        K.UI.Refresh()
    end
end

local function printLines(lines)
    for _, line in ipairs(lines) do
        K.Print(line)
    end
end

-- Mark done: when the game disagrees, ask once per quest ("Keep it hidden?"); the answer is kept.
function SM.MarkDone(i)
    local E = K.Engine
    local step = E.steps[i]
    if not step then
        return false
    end
    K.cdb.hideAnswers = K.cdb.hideAnswers or {}
    if E.Contradicts(step) and not K.cdb.hideAnswers[step.q] then
        SM.pendingDone = i
        if StaticPopup_Show then
            StaticPopup_Show("KLIMAX_NOT_DONE")
        end
        return false
    end
    E:MarkDone(i)
    return true
end

-- The popup's Yes: remember the answer and hide the step.
function SM.ConfirmHidden()
    local i = SM.pendingDone
    SM.pendingDone = nil
    local step = i and K.Engine.steps[i]
    if not step then
        return
    end
    K.cdb.hideAnswers = K.cdb.hideAnswers or {}
    if step.q then
        K.cdb.hideAnswers[step.q] = true
    end
    K.Engine:MarkDone(i)
    refresh()
end

function SM.Do(key, i)
    local E = K.Engine
    local step = E.steps[i]
    if not step then
        return
    end
    if key == "skipQuest" then
        E:SkipQuest(step.q)
        K.Print(string.format(L.MENU_SKIPPED_QUEST, step.n or ("#" .. tostring(step.q))))
    elseif key == "skipStep" then
        E:Skip(i)
    elseif key == "markDone" then
        SM.MarkDone(i)
    elseif key == "restore" then
        if step.q then
            E:RestoreQuest(step.q)
        end
        E:Unskip(step.k)
    elseif key == "pin" then
        E:Pin(step.k)
    elseif key == "unpin" then
        E:Pin(nil)
    elseif key == "why" then
        printLines(SM.WhyLines(step, E.eff[i]))
    elseif key == "npc" then
        printLines(SM.NpcLines(step))
    elseif key == "arrow" then
        if K.UI then
            K.UI.focusKey = step.k
        end
    end
    refresh()
end

-- ---- Frame --------------------------------------------------------------------------------------

SM.frame = nil
local ROW_H, MENU_W = 20, 190

local function build()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetSize(MENU_W, ROW_H)
    T.Backdrop(f, T.colour.panel)
    f.title = T.Text(f, 12, T.colour.gold)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -4)
    f.title:SetWidth(MENU_W - 12)
    f.buttons = {}
    f:EnableMouse(true)
    f:Hide()
    return f
end

-- Opens the menu for step i next to `anchor` (a list row).
function SM.Open(i, anchor)
    local E = K.Engine
    local step = E.steps[i]
    if not step then
        return
    end
    local f = SM.frame or build()
    SM.frame = f
    local stored = E.routeId and K.cdb.stepState and K.cdb.stepState[E.routeId]
        and K.cdb.stepState[E.routeId][step.k] or nil
    local pin = K.cdb.pin
    local items = SM.Items(step, E.eff[i], stored, E.QuestSkipped(step.q), pin ~= nil and pin.k == step.k)
    items[#items + 1] = "close"
    f.title:SetText(step.n or step.note or "")
    for n, key in ipairs(items) do
        local b = f.buttons[n]
        if not b then
            b = T.Button(f, "", MENU_W - 8, ROW_H - 2)
            f.buttons[n] = b
        end
        b.label:SetText(L["MENU_" .. key] or key)
        b:SetScript("OnClick", function()
            f:Hide()
            if key ~= "close" then
                SM.Do(key, i)
            end
        end)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -(ROW_H + (n - 1) * ROW_H))
        b:Show()
    end
    for n = #items + 1, #f.buttons do
        f.buttons[n]:Hide()
    end
    f:SetHeight(ROW_H * (#items + 1) + 6)
    f:ClearAllPoints()
    if anchor then
        f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    f:Show()
    SM.openItems = items
    return items
end

function SM.Close()
    if SM.frame then
        SM.frame:Hide()
    end
end

-- The "Keep it hidden?" confirmation for Mark done.
if StaticPopupDialogs then
    StaticPopupDialogs["KLIMAX_NOT_DONE"] = {
        text = L.CONFIRM_NOT_DONE,
        button1 = L.YES,
        button2 = L.NO,
        OnAccept = function()
            SM.ConfirmHidden()
        end,
        OnCancel = function()
            SM.pendingDone = nil
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end
