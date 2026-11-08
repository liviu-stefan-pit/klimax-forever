-- Local telemetry and runtime self-healing (phase 28, DYNAMIC_GUIDE_PLAN s8). Nothing is sent anywhere.
--
-- When a step's target is not where the data said, the add-on stores a record in the saved
-- variables and, after two strikes for the same quest, hides that quest for this character so the
-- planner picks the next best step:
--   * dwell:       the player stood at the target of an accept or hand-in step for DWELL seconds and
--                  the step did not complete (the NPC is not there, or does not offer the quest);
--   * not-offered: the player talked to the target NPC and the quest was not on offer (accept), or
--                  the NPC had nothing to hand in (turn-in).
-- /klimax report prints the records (paste them into an issue; the next data refresh consumes them as
-- corrections), /klimax report restore <quest> brings a hidden quest back, /klimax report clear
-- empties the list. Records live in KlimaxDB.reports (account-wide, capped at MAX).
local _, K = ...
local L = K.L

local Tel = {}
K.Telemetry = Tel

Tel.MAX = 200          -- records kept
Tel.DWELL = 40         -- seconds at the target before a dwell strike
Tel.NEAR = 1.5         -- map-%: "at the target"
Tel.STRIKES = 2        -- strikes for one quest before it is hidden
Tel.TICK = 1.0
Tel.SETTLE = 1.0       -- seconds to wait for a quest window after a gossip window closes

-- ---- Pure parts ----------------------------------------------------------------------------------------

-- The steps a strike can be about: an accept or a hand-in at a known NPC.
function Tel.Watchable(step)
    return step ~= nil and (step.t == "A" or step.t == "T") and step.q ~= nil and step.npc ~= nil
        and step.z ~= nil and step.x ~= nil
end

-- Dwell tracker. state: {key, since} (kept by the caller); returns the new state and true when the
-- player has now waited long enough at the step's target. pos: {m, x, y} or nil; now: seconds.
function Tel.Dwell(state, step, pos, now)
    if not (Tel.Watchable(step) and pos and pos.m == step.z) then
        return nil, false
    end
    local dx, dy = pos.x - step.x, pos.y - step.y
    if math.sqrt(dx * dx + dy * dy) > Tel.NEAR then
        return nil, false
    end
    if not state or state.key ~= step.k then
        return { key = step.k, since = now }, false
    end
    if now - state.since >= Tel.DWELL then
        return nil, true
    end
    return state, false
end

-- True when quest `title` is on a list of offered titles (case-insensitive).
function Tel.Offered(titles, title)
    local want = (title or ""):lower()
    for _, t in ipairs(titles or {}) do
        if tostring(t):lower() == want then
            return true
        end
    end
    return false
end

-- What the dialogue with the step's NPC showed. talk: {npc, titles, quest (a quest window opened)}.
-- Returns "not-offered" when the step was about this NPC and the quest was not there, else nil.
function Tel.Judge(step, talk)
    if not (Tel.Watchable(step) and talk and talk.npc == step.npc) or talk.quest then
        return nil
    end
    if step.t == "A" and not Tel.Offered(talk.titles, step.n) then
        return "not-offered"
    end
    if step.t == "T" then
        return "not-offered"
    end
    return nil
end

-- One line per record, for /klimax report.
function Tel.Format(r)
    return string.format("q%d %s%s npc %s map %s %.1f,%.1f L%d %s x%d", r.q, r.stage, r.name and (" " .. r.name) or "",
        tostring(r.npc), tostring(r.m), r.x or 0, r.y or 0, r.level or 0, r.kind, r.n or 1)
end

-- ---- Storage -----------------------------------------------------------------------------------------

local function reports()
    K.db = K.db or {}
    K.db.reports = K.db.reports or {}
    return K.db.reports
end

local function broken()
    K.cdb = K.cdb or {}
    K.cdb.brokenQuests = K.cdb.brokenQuests or {}
    return K.cdb.brokenQuests
end

local function version()
    local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if fn then
        local ok, v = pcall(fn, K.name or "Klimax", "Version")
        if ok then
            return v
        end
    end
    return nil
end

-- Stores (or counts again) the record for this step and kind. Returns the record.
function Tel.Record(kind, step)
    local list = reports()
    for _, r in ipairs(list) do
        if r.q == step.q and r.stage == step.t and r.kind == kind and r.npc == step.npc then
            r.n = (r.n or 1) + 1
            return r
        end
    end
    local r = { q = step.q, stage = step.t, kind = kind, npc = step.npc, name = step.n, m = step.z,
        x = step.x, y = step.y, level = (K.player and K.player.level) or 0, n = 1, v = version(),
        at = time and time() or 0 }
    list[#list + 1] = r
    while #list > Tel.MAX do
        table.remove(list, 1)
    end
    return r
end

-- A strike against a step. After Tel.STRIKES records of the same kind the quest is hidden for this
-- character (Reconciler state "broken"/"reported") and the plan is rebuilt. Returns true when it was
-- hidden by this call.
function Tel.Strike(kind, step)
    local r = Tel.Record(kind, step)
    if (r.n or 1) < Tel.STRIKES then
        return false
    end
    if broken()[step.q] then
        return false
    end
    broken()[step.q] = true
    if K.Print then
        K.Print(string.format(L.REPORT_HIDDEN, step.n or tostring(step.q)))
    end
    if K.State and K.State.Refresh and K.State:Ready() then
        K.State:Refresh("broken")
    end
    if K.Planner then
        K.Planner.dirty = true
    end
    return true
end

-- ---- Watching --------------------------------------------------------------------------------------

Tel.dwell = nil
Tel.talk = nil

local function currentStep()
    local plan = K.Planner and K.Planner.plan
    if not plan then
        return nil
    end
    for _, s in ipairs(plan.steps) do
        if s.t ~= "V" then
            return s
        end
    end
    return nil
end

local function tick()
    local step = currentStep()
    local m = K.Compat.GetBestMapForPlayer()
    local p = m and K.Compat.GetPlayerMapPosition(m)
    local pos = p and { m = m, x = p.x * 100, y = p.y * 100 } or nil
    local state, hit = Tel.Dwell(Tel.dwell, step, pos, GetTime and GetTime() or 0)
    Tel.dwell = state
    if hit then
        Tel.Strike("dwell", step)
    end
end
Tel.Tick = tick

local function opened()
    Tel.talk = { npc = K.Compat.TalkingNpcId(), titles = K.Compat.OfferedQuestTitles(), quest = false }
end

local function questWindow()
    -- a quest window follows the gossip window of the same NPC: both count as "the quest was there"
    if Tel.talk then
        Tel.talk.quest = true
    end
    if Tel.closing then
        Tel.closing.quest = true
    end
end

-- The dialogue closed. The verdict waits a moment: when a gossip window hands over to a quest
-- window, QUEST_DETAIL or QUEST_PROGRESS arrives right after GOSSIP_CLOSED.
local function closed()
    local talk = Tel.talk
    Tel.talk = nil
    if not talk then
        return
    end
    Tel.closing = talk
    C_Timer.After(Tel.SETTLE, function()
        if Tel.closing ~= talk then
            return
        end
        Tel.closing = nil
        local step = currentStep()
        local kind = Tel.Judge(step, talk)
        if kind then
            Tel.Strike(kind, step)
        end
    end)
end

K.On("GOSSIP_SHOW", opened)
K.On("QUEST_GREETING", opened)
K.On("QUEST_DETAIL", questWindow)
K.On("QUEST_PROGRESS", questWindow)
K.On("QUEST_COMPLETE", questWindow)
K.On("GOSSIP_CLOSED", closed)
K.On("QUEST_FINISHED", closed)
K.Every(Tel.TICK, tick)

-- ---- Commands ----------------------------------------------------------------------------------------

function Tel.Restore(q)
    if broken()[q] then
        broken()[q] = nil
        local list = reports()
        for i = #list, 1, -1 do
            if list[i].q == q then
                table.remove(list, i)
            end
        end
        if K.State and K.State.Refresh and K.State:Ready() then
            K.State:Refresh("restore")
        end
        K.Print(string.format(L.REPORT_RESTORED, q))
        return true
    end
    K.Print(string.format(L.REPORT_NOT_HIDDEN, q))
    return false
end

-- /klimax report [clear | restore <quest>]
function Tel.Command(rest)
    local sub, arg = (rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
    sub = (sub or ""):lower()
    if sub == "clear" then
        K.db = K.db or {}
        K.db.reports = {}
        K.Print(L.REPORT_CLEARED)
    elseif sub == "restore" then
        Tel.Restore(tonumber(arg))
    else
        local list = reports()
        if #list == 0 then
            K.Print(L.REPORT_EMPTY)
            return
        end
        K.Print(string.format(L.REPORT_HEAD, #list))
        for _, r in ipairs(list) do
            K.Print(Tel.Format(r))
        end
    end
end
