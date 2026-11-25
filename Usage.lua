-- AltStash 0.4.0 (usage tags since 0.3.8): what is an item used for? Quest / Crafting / Gear / Safe to sell tags for the Items view.
--   Quest    : a quest item (item class Quest or quest bind type), or an item objective of a quest in ANY saved character's
--              quest log (captured per character on login / quest log changes: AltStashDB.chars[key].quests, optional field).
--   Crafting : a reagent of a recipe known by any character (ProfTracker data).
--   Gear     : weapons / armour: never judged.
--   Quest done : 0.4.0: a quest item that the built-in quest database (QuestItemDB.lua) maps to quest IDs, where every quest
--              using it and every later step of those chains is completed on this character (or can't apply to it), none is
--              active on any character and no recipe uses it: safe to delete. Anything else stays "keep".
--   Safe to sell : none of the above, the character holds tradeable units and the item has a vendor or AH price.
-- It only knows quests that are in a quest log now and recipes ProfTracker has saved: not quests you haven't picked up,
-- not recipes you haven't learned.
local ADDON, AS = ...
local U = {}
AS.Usage = U

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end
local function Str(v) if type(v) == "string" and not IsSecret(v) and v ~= "" then return v end end
local function Num(v) if type(v) == "number" and not IsSecret(v) and v == v then return v end end

function U.Enabled() return not (AS.db and AS.db.settings and AS.db.settings.usage == false) end

U.CLASS_QUEST, U.CLASS_TRADE, U.CLASS_RECIPE = 12, 7, 9
U.GEAR = { [2] = true, [4] = true }
U.BIND_QUEST = 4

-- "Thorium Bar: 3/5" (Classic) or "3/5 Thorium Bar" (modern); "(Complete)" suffixes ignored
function U.ParseObjective(text)
    text = Str(text)
    if not text then return nil end
    text = text:gsub("%s*%(.-%)%s*$", "")
    local name, have, need = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)%s*$")
    if not name then have, need, name = text:match("^%s*(%d+)%s*/%s*(%d+)%s+(.-)%s*$") end
    if name and name ~= "" then return name, tonumber(have), tonumber(need) end
    return nil
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if r[1] then return unpack(r, 2) end
end

-- Read the logged-in character's quest log. Returns list { { id, title, items = { { name, have, need } } } } or nil.
function U.ReadQuestLog()
    local list = {}
    local Q = C_QuestLog
    if type(Q) == "table" and type(Q.GetNumQuestLogEntries) == "function" and type(Q.GetInfo) == "function" and type(Q.GetQuestObjectives) == "function" then
        local n = Num(Call(Q.GetNumQuestLogEntries)) or 0
        for i = 1, n do
            local info = Call(Q.GetInfo, i)
            if type(info) == "table" and not info.isHeader and Num(info.questID) then
                local q = { id = info.questID, title = Str(info.title) or ("Quest " .. info.questID), items = {} }
                local objs = Call(Q.GetQuestObjectives, info.questID)
                for _, o in ipairs(type(objs) == "table" and objs or {}) do
                    if type(o) == "table" and o.type == "item" then
                        local name, have, need = U.ParseObjective(o.text)
                        if name then q.items[#q.items + 1] = { name = name, have = Num(o.numFulfilled) or have, need = Num(o.numRequired) or need } end
                    end
                end
                list[#list + 1] = q
            end
        end
        return list
    end
    if type(GetNumQuestLogEntries) == "function" and type(GetQuestLogTitle) == "function" then
        local n = Num(Call(GetNumQuestLogEntries)) or 0
        for i = 1, n do
            local title, _, _, isHeader, _, _, _, qid = Call(GetQuestLogTitle, i)
            if Str(title) and not isHeader then
                local q = { id = Num(qid), title = title, items = {} }
                local nb = Num(Call(GetNumQuestLeaderBoards, i)) or 0
                for j = 1, nb do
                    local text, typ = Call(GetQuestLogLeaderBoard, j, i)
                    if typ == "item" then
                        local name, have, need = U.ParseObjective(text)
                        if name then q.items[#q.items + 1] = { name = name, have = have, need = need } end
                    end
                end
                list[#list + 1] = q
            end
        end
        return list
    end
    return nil
end

function AS.ScanQuests()
    if not (AS.db and AS._CurrentRecord) then return false end
    local rec = AS._CurrentRecord()
    if not rec then return false end
    local list = U.ReadQuestLog()
    if not list then return false end
    rec.quests, rec.questsAt = list, (type(time) == "function" and time()) or nil
    if U.CharFacts and AS.CurrentKey then pcall(U.CharFacts, AS.CurrentKey()) end
    U.MapQuestItems(rec, list)
    U.CheckCompleted(rec)
    U.Reset()
    return true
end

-- Account-wide map itemID -> { q = questID, title } (AltStashDB.questItems, optional): items seen as an objective of a quest
-- in the log (matched by name against this character's saved items) or as a quest item / starter in the bags.
function U.QuestMap()
    if not AS.db then return {} end
    AS.db.questItems = type(AS.db.questItems) == "table" and AS.db.questItems or {}
    return AS.db.questItems
end

function U.MapQuestItems(rec, list)
    local map = U.QuestMap()
    local byName = {}
    for id, it in pairs(type(rec.items) == "table" and rec.items or {}) do
        local n = Str(it.name) or (AS.ItemName and AS.ItemName(id, it))
        if Str(n) then byName[n:lower()] = id end
    end
    for _, q in ipairs(list or {}) do
        if q.id then
            for _, o in ipairs(q.items or {}) do
                local id = Str(o.name) and byName[o.name:lower()]
                if id then map[id] = { q = q.id, title = q.title } end
            end
        end
    end
    -- quest items / starters in the bags (modern C_Container.GetContainerItemQuestInfo; Classic GetContainerItemQuestInfo)
    local C = C_Container
    local qinfo = (type(C) == "table" and C.GetContainerItemQuestInfo) or GetContainerItemQuestInfo
    local nslots = (type(C) == "table" and C.GetContainerNumSlots) or GetContainerNumSlots
    local iid = (type(C) == "table" and C.GetContainerItemID) or GetContainerItemID
    if type(qinfo) == "function" and type(nslots) == "function" and type(iid) == "function" then
        for bag = 0, 4 do
            local n = Num(Call(nslots, bag)) or 0
            for slot = 1, n do
                local id = Num(Call(iid, bag, slot))
                if id then
                    local a, b2 = Call(qinfo, bag, slot)
                    local qid
                    if type(a) == "table" then qid = Num(a.questID) or Num(a.questId) else qid = Num(b2) end   -- classic: isQuestItem, questID, isActive
                    if qid and qid > 0 and not map[id] then
                        local title
                        for _, q in ipairs(list or {}) do if q.id == qid then title = q.title end end
                        map[id] = { q = qid, title = title }
                    end
                end
            end
        end
    end
    return map
end

local function IsCompleted(qid)
    local Q = C_QuestLog
    if type(Q) == "table" and type(Q.IsQuestFlaggedCompleted) == "function" then
        local ok, v = pcall(Q.IsQuestFlaggedCompleted, qid)
        if ok and type(v) == "boolean" then return v end
    end
    if type(IsQuestFlaggedCompleted) == "function" then
        local ok, v = pcall(IsQuestFlaggedCompleted, qid)
        if ok and v ~= nil then return v and true or false end
    end
    return nil
end
U._IsCompleted = IsCompleted

-- rec.questsDone[questID] = true for the mapped quests this character has completed (optional field)
function U.CheckCompleted(rec, justTurnedIn)
    rec.questsDone = type(rec.questsDone) == "table" and rec.questsDone or {}
    if Num(justTurnedIn) then rec.questsDone[justTurnedIn] = true end
    for _, m in pairs(U.QuestMap()) do
        if type(m) == "table" and Num(m.q) and not rec.questsDone[m.q] then
            if IsCompleted(m.q) == true then rec.questsDone[m.q] = true end
        end
    end
    if U.CacheDBCompletion then pcall(U.CacheDBCompletion, rec) end
end

function AS.OnQuestTurnedIn(questID)
    if not (AS.db and AS._CurrentRecord) then return end
    local rec = AS._CurrentRecord()
    if rec then U.CheckCompleted(rec, Num(questID)); U.Reset() end
end

------------------------------------------------------------------------
-- Index (rebuilt lazily; reset on every Items list build)
------------------------------------------------------------------------
local index, bagInfo
function U.Reset() index = nil; bagInfo = nil end

local function Label(key, rec)
    if AS.UniqueLabel and AS.db and AS.db.chars[key] then local ok, l = pcall(AS.UniqueLabel, key); if ok and l then return l end end
    return (rec and (rec.displayName or rec.name)) or tostring(key)
end

local function Build()
    local idx = { quest = {}, craft = {}, questChars = 0, chars = 0, activeQ = {} }
    for key, rec in pairs((AS.db and AS.db.chars) or {}) do
        idx.chars = idx.chars + 1
        if type(rec.quests) == "table" then
            idx.questChars = idx.questChars + 1
            for _, q in ipairs(rec.quests) do
                if q.id then idx.activeQ[q.id] = idx.activeQ[q.id] or Label(key, rec) end
                for _, it in ipairs(type(q.items) == "table" and q.items or {}) do
                    local k = Str(it.name) and it.name:lower()
                    if k then
                        local l = idx.quest[k]; if not l then l = {}; idx.quest[k] = l end
                        l[#l + 1] = { title = q.title, char = Label(key, rec), key = key, have = it.have, need = it.need }
                    end
                end
            end
        end
    end
    local PT = _G.ProfTracker
    if type(PT) == "table" and type(PT.db) == "table" and type(PT.db.chars) == "table" then
        for pkey, prec in pairs(PT.db.chars) do
            local who = (type(prec) == "table" and (prec.name or prec.displayName)) or tostring(pkey)
            for prof, map in pairs(type(prec) == "table" and type(prec.recipes) == "table" and prec.recipes or {}) do
                for _, r in pairs(type(map) == "table" and map or {}) do
                    if type(r) == "table" then
                        for _, g in ipairs(type(r.reagents) == "table" and r.reagents or {}) do
                            local id = Num(g.id)
                            if id then
                                local l = idx.craft[id]; if not l then l = {}; idx.craft[id] = l end
                                l[#l + 1] = { prof = prof, recipe = r.name, out = r.out, char = who, n = g.n }
                            end
                        end
                    end
                end
            end
        end
        idx.pt = true
    end
    return idx
end
function U.Index() if not index then index = Build() end return index end

-- 0.3.9: live quest info for the logged-in character's bags: itemID -> { questID, isActive, isQuestItem }.
-- Modern C_Container.GetContainerItemQuestInfo returns a table; Classic GetContainerItemQuestInfo returns isQuestItem, questID, isActive.
local bagInfoAt = -100
function U.BagQuestInfo()
    local now = (type(GetTime) == "function" and select(2, pcall(GetTime))) or 0
    if type(now) ~= "number" then now = 0 end
    if bagInfo and now - bagInfoAt < 2 then return bagInfo end       -- short cache: bags change, tooltips are hovered often
    bagInfo, bagInfoAt = {}, now
    local C = C_Container
    local qinfo = (type(C) == "table" and C.GetContainerItemQuestInfo) or GetContainerItemQuestInfo
    local nslots = (type(C) == "table" and C.GetContainerNumSlots) or GetContainerNumSlots
    local iid = (type(C) == "table" and C.GetContainerItemID) or GetContainerItemID
    if type(qinfo) ~= "function" or type(nslots) ~= "function" or type(iid) ~= "function" then return bagInfo end
    for bag = 0, 4 do
        local n = Num(Call(nslots, bag)) or 0
        for slot = 1, n do
            local id = Num(Call(iid, bag, slot))
            if id and not bagInfo[id] then
                local a, b2, c2 = Call(qinfo, bag, slot)
                local e
                if type(a) == "table" then e = { isQuestItem = a.isQuestItem and true or false, questID = Num(a.questID) or Num(a.questId), isActive = a.isActive and true or false }
                elseif a ~= nil or b2 ~= nil then e = { isQuestItem = a and true or false, questID = Num(b2), isActive = c2 and true or false } end
                if e then
                    if e.questID and e.questID <= 0 then e.questID = nil end
                    bagInfo[id] = e
                end
            end
        end
    end
    return bagInfo
end

function U.QuestTitle(qid)
    if not Num(qid) then return nil end
    for _, rec in pairs((AS.db and AS.db.chars) or {}) do
        for _, q in ipairs(type(rec.quests) == "table" and rec.quests or {}) do if q.id == qid and Str(q.title) then return q.title end end
    end
    local m = U.QuestMap()
    for _, e in pairs(m) do if type(e) == "table" and e.q == qid and Str(e.title) then return e.title end end
    local Q = C_QuestLog
    if type(Q) == "table" and type(Q.GetTitleForQuestID) == "function" then
        local ok, t = pcall(Q.GetTitleForQuestID, qid)
        if ok and Str(t) then return t end
    end
    return nil
end

-- Items received at a quest turn-in: QUEST_LOOT_RECEIVED (questID, itemLink) or your own loot message within a few seconds
-- of QUEST_TURNED_IN. Recorded as item -> quest (how = "reward"). Only quest-class items can later become "Quest done".
U.TURNIN_WINDOW = 5
local lastTurnIn
local function ItemIDFrom(link)
    if type(link) == "number" then return link end
    local id = type(link) == "string" and link:match("item:(%d+)")
    return id and tonumber(id) or nil
end
U._ItemIDFrom = ItemIDFrom
local function Now() if type(GetTime) == "function" then local ok, t = pcall(GetTime); if ok and Num(t) then return t end end return 0 end

function U.RecordReward(questID, item)
    local id, qid = ItemIDFrom(item), Num(questID)
    if not (id and qid) then return false end
    local map = U.QuestMap()
    local old = map[id]
    if type(old) == "table" and old.how ~= "reward" then return false end   -- an objective / bag-quest link is better evidence
    map[id] = { q = qid, title = U.QuestTitle(qid) or (lastTurnIn and lastTurnIn.q == qid and lastTurnIn.title) or nil, how = "reward" }
    U.Reset()
    return true
end

function AS.OnQuestTurnedInLoot(event, a1, a2)
    if event == "QUEST_TURNED_IN" then
        lastTurnIn = { q = Num(a1), t = Now(), title = U.QuestTitle(a1) }
    elseif event == "QUEST_LOOT_RECEIVED" then
        U.RecordReward(a1, a2)
    elseif event == "CHAT_MSG_LOOT" then
        if not (lastTurnIn and lastTurnIn.q) or Now() - lastTurnIn.t > U.TURNIN_WINDOW then return end
        local msg = Str(a1)
        if not msg then return end
        local mine = false
        for _, g in ipairs({ "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE" }) do
            local fmt = _G[g]
            if type(fmt) == "string" and AS.FormatToPattern and msg:match(AS.FormatToPattern(fmt)) then mine = true break end
        end
        if mine then U.RecordReward(lastTurnIn.q, msg) end
    end
end

------------------------------------------------------------------------
-- 0.4.0: cross-reference with the built-in quest database (QuestItemDB.lua, from QuestieDB Forever data).
-- "Quest done: safe to delete" only when the item maps to known quest IDs and EVERY quest that uses it, plus the
-- later steps of those chains, is completed on this character (or can't apply to it) and no character has one active.
-- The turn-in reward heuristic and the game's bag quest ID are evidence for "keep", never on their own for "safe".
------------------------------------------------------------------------
local CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8,
    WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12, EVOKER = 13 }
U.CHAIN_DEPTH = 12
U.ROLE_TEXT = { o = "objective", s = "given at accept", r = "required item", t = "starts the quest", w = "quest reward",
    g = "game quest link", f = "later chain step" }

function U.DB()
    local d = AS.QuestItemDB
    if type(d) == "table" and type(d.I) == "table" and type(d.Q) == "table" then return d end
    return nil
end

local dbItemMemo = {}
function U.SetDB(d) AS.QuestItemDB = d; dbItemMemo = {} end   -- tests / future data swaps
-- list { { q = questID, roles = "osrtw" } } for an item, or nil when the item isn't in the database
function U.DBItem(id)
    local D = U.DB()
    if not (D and Num(id)) then return nil end
    local m = dbItemMemo[id]
    if m ~= nil then return m or nil end
    local s = D.I[id]
    if type(s) ~= "string" then dbItemMemo[id] = false; return nil end
    local list = {}
    for q, roles in s:gmatch("(%d+):(%a+)") do list[#list + 1] = { q = tonumber(q), roles = roles } end
    dbItemMemo[id] = (#list > 0) and list or false
    return (#list > 0) and list or nil
end

function U.DBQuest(q)
    local D = U.DB()
    local e = D and Num(q) and D.Q[q]
    if type(e) ~= "table" then return nil end
    return { name = e[1], next = e[2], races = e[3], classes = e[4], repeatable = e[5] == 1, pre = e[6], preGroup = e[7],
        exclusiveTo = e[8], followers = e[9], breadcrumbFor = e[10] }
end

local function HasBit(mask, id)
    if not (Num(mask) and Num(id)) or id < 1 or mask <= 0 then return true end   -- unknown: assume it applies (keeps more)
    local b = 2 ^ (id - 1)
    return math.floor(mask / b) % 2 == 1
end
U._HasBit = HasBit

-- race / class IDs of a saved character (live for the logged-in one)
function U.CharFacts(charKey)
    local rec = charKey and AS.db and AS.db.chars and AS.db.chars[charKey]
    local race, class = rec and Num(rec.raceID), rec and (Num(rec.classID) or (Str(rec.classFile) and CLASS_IDS[rec.classFile]))
    if (charKey == nil or (AS.CurrentKey and charKey == AS.CurrentKey())) then
        if not race and type(UnitRace) == "function" then local _, _, r = Call(UnitRace, "player"); race = Num(r) end
        if type(UnitClass) == "function" then
            local _, f, c = Call(UnitClass, "player")
            class = Num(c) or (Str(f) and CLASS_IDS[f]) or class
            if rec and Num(c) then rec.classID = c end
        end
    end
    return race, class
end

function U.QuestApplies(q, race, class)
    local e = U.DBQuest(q)
    if not e then return true end
    if e.races and race and not HasBit(e.races, race) then return false end
    if e.classes and class and not HasBit(e.classes, class) then return false end
    return true
end

-- completed on that character? live for the logged-in character (cached as rec.questsDone), saved for alts
function U.QuestDoneOn(charKey, q)
    if not Num(q) then return false end
    local rec = charKey and AS.db and AS.db.chars and AS.db.chars[charKey]
    if rec and type(rec.questsDone) == "table" and rec.questsDone[q] then return true end
    if charKey == nil or (AS.CurrentKey and charKey == AS.CurrentKey()) then
        if IsCompleted(q) == true then
            if rec then rec.questsDone = type(rec.questsDone) == "table" and rec.questsDone or {}; rec.questsDone[q] = true end
            return true
        end
    end
    return false
end

function U.QuestName(q)
    local e = U.DBQuest(q)
    return (e and Str(e.name)) or U.QuestTitle(q) or ("quest " .. tostring(q))
end

-- state of one quest for one character: "active" | "done" | "na" (race/class) | "excl" (an exclusive alternative or the
-- breadcrumb's target is done) | "repeat" | "pending"
function U.QuestState(q, charKey, race, class, idx)
    idx = idx or U.Index()
    if idx.activeQ[q] then return "active", idx.activeQ[q] end
    local e = U.DBQuest(q)
    if e and e.repeatable and U.QuestApplies(q, race, class) then return "repeat" end
    if U.QuestDoneOn(charKey, q) then return "done" end
    if not U.QuestApplies(q, race, class) then return "na" end
    if e then
        for _, x in ipairs(type(e.exclusiveTo) == "table" and e.exclusiveTo or {}) do if U.QuestDoneOn(charKey, x) then return "excl" end end
        if Num(e.breadcrumbFor) and U.QuestDoneOn(charKey, e.breadcrumbFor) then return "excl" end
    end
    return "pending"
end

U.STATE_TEXT = { active = "active", done = "done", na = "not for this race/class", excl = "skipped (alternative done)",
    ["repeat"] = "repeatable", pending = "not done" }

-- Full cross-reference for one item on one character. Returns
-- { known = bool, list = { { q, roles, state, who, via, name } }, blocker = entry|nil, safe = bool, reason = text,
--   classPending = entry|nil (a class / race restricted quest still needs it) }
function U.QuestVerdict(id, charKey, live)
    local r = { list = {}, known = false, safe = false }
    if not Num(id) then r.reason = "unknown item"; return r end
    local idx = U.Index()
    local race, class = U.CharFacts(charKey)
    local seen = {}
    local function Add(q, roles, via, using)
        if not Num(q) or q <= 0 then return end
        local e = seen[q]
        if e then
            if roles and not e.roles:find(roles, 1, true) then e.roles = e.roles .. roles end
            if using then e.using = true end
            return e
        end
        local st, who = U.QuestState(q, charKey, race, class, idx)
        e = { q = q, roles = roles or "", state = st, who = who, via = via, using = using, name = U.QuestName(q), inDB = U.DBQuest(q) ~= nil }
        seen[q] = e
        r.list[#r.list + 1] = e
        return e
    end
    local dbl = U.DBItem(id)
    r.known = dbl ~= nil
    local starts = {}
    for _, d in ipairs(dbl or {}) do
        local using = d.roles:find("[osrt]") ~= nil
        Add(d.q, d.roles, nil, using)
        starts[#starts + 1] = d.q
    end
    -- runtime evidence from the game: bag quest link and quest-log objective matches (AltStashDB.questItems)
    live = live or ((charKey == nil or (AS.CurrentKey and charKey == AS.CurrentKey())) and U.BagQuestInfo()[id]) or nil
    if live and Num(live.questID) then local e = Add(live.questID, "g", nil, true); starts[#starts + 1] = live.questID; r.gameQuest = live.questID; if e and not e.inDB then r.unresolved = e end end
    local m = U.QuestMap()[id]
    if type(m) == "table" and Num(m.q) then
        if m.how == "reward" then r.rewardHint = m.q; local e = Add(m.q, "w", nil, false); starts[#starts + 1] = m.q
        else local e = Add(m.q, "g", nil, true); starts[#starts + 1] = m.q; if e and not e.inDB then r.unresolved = e end end
    end
    -- later chain steps (next quest in chain and direct follow-ups)
    local depth = { }
    local queue = {}
    for _, q in ipairs(starts) do if not depth[q] then depth[q] = 0; queue[#queue + 1] = q end end
    local qi = 1
    while queue[qi] do
        local q = queue[qi]; qi = qi + 1
        local e = U.DBQuest(q)
        if e and depth[q] < U.CHAIN_DEPTH then
            local nxt = {}
            if Num(e.next) then nxt[#nxt + 1] = e.next end
            for _, f in ipairs(type(e.followers) == "table" and e.followers or {}) do nxt[#nxt + 1] = f end
            for _, f in ipairs(nxt) do
                if not depth[f] then
                    depth[f] = depth[q] + 1; queue[#queue + 1] = f
                    Add(f, "f", q, false)
                end
            end
        end
    end
    -- blockers: active anywhere, or not done; a using quest that is repeatable keeps the item too
    local usedDone = false
    for _, e in ipairs(r.list) do
        local st = e.state
        if st == "done" and (e.using or e.roles:find("w", 1, true)) then usedDone = true end
        local blocks = st == "active" or st == "pending" or (st == "repeat" and e.using)
        if blocks then
            if not r.blocker or (e.using and not r.blocker.using) then r.blocker = e end
            if e.using and e.roles:find("[srt]") then   -- given / required / starter items of a class quest
                local d = U.DBQuest(e.q)
                if d and d.classes and not r.classPending then r.classPending = e end
            end
        end
    end
    if not r.known then r.reason = "Quest item: can't confirm, keep"
    elseif r.blocker then
        local b = r.blocker
        if b.state == "active" then r.reason = "Keep: needed for " .. b.name .. " (" .. b.q .. ", active on " .. tostring(b.who) .. ")"
        elseif b.state == "repeat" then r.reason = "Keep: used by repeatable quest " .. b.name .. " (" .. b.q .. ")"
        else r.reason = "Keep: quest chain not finished (" .. b.name .. ", " .. b.q .. ")" end
    elseif r.unresolved then r.reason = "Quest item: can't confirm, keep (quest " .. r.unresolved.q .. " isn't in the quest database)"
    elseif not usedDone then r.reason = "Quest item: can't confirm, keep (none of its quests completed on this character)"
    else r.safe = true; r.reason = "Quest done: safe to delete" end
    return r
end

-- manual keep list (AltStashDB.keep, optional): itemID -> true
function U.KeepList() if not AS.db then return {} end AS.db.keep = type(AS.db.keep) == "table" and AS.db.keep or {}; return AS.db.keep end
function U.IsKept(id) return AS.db and type(AS.db.keep) == "table" and Num(id) and AS.db.keep[id] == true or false end
function U.SetKept(id, on)
    if not Num(id) then return false end
    U.KeepList()[id] = on and true or nil
    U.Reset()
    return true
end
function U.ParseItemArg(arg)
    if type(arg) == "number" then return arg end
    arg = Str(arg)
    if not arg then return nil end
    local id = arg:match("item:(%d+)") or arg:match("^%s*(%d+)%s*$")
    return id and tonumber(id) or nil
end

-- cache completion of database quests for the items this character holds (so alts' verdicts work offline)
function U.CacheDBCompletion(rec)
    if not (type(rec) == "table" and U.DB()) then return 0 end
    rec.questsDone = type(rec.questsDone) == "table" and rec.questsDone or {}
    local n = 0
    for id in pairs(type(rec.items) == "table" and rec.items or {}) do
        for _, d in ipairs(U.DBItem(id) or {}) do
            local todo, depth = { d.q }, 0
            while #todo > 0 and depth <= U.CHAIN_DEPTH do
                local nxt = {}
                for _, q in ipairs(todo) do
                    if not rec.questsDone[q] and IsCompleted(q) == true then rec.questsDone[q] = true; n = n + 1 end
                    local e = U.DBQuest(q)
                    if e then
                        if Num(e.next) then nxt[#nxt + 1] = e.next end
                        for _, f in ipairs(type(e.followers) == "table" and e.followers or {}) do nxt[#nxt + 1] = f end
                        for _, x in ipairs(type(e.exclusiveTo) == "table" and e.exclusiveTo or {}) do
                            if not rec.questsDone[x] and IsCompleted(x) == true then rec.questsDone[x] = true; n = n + 1 end
                        end
                    end
                end
                todo, depth = nxt, depth + 1
            end
        end
    end
    return n
end

local function ItemInfoBits(id)
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(fn) ~= "function" then return nil end
    local ok, name, _, _, _, _, _, _, _, _, _, sell, classID, _, bindType = pcall(fn, id)
    if ok and name then return Num(sell), Num(classID), Num(bindType) end
end

-- Usage for one item record on one character. Returns
-- { verdict = "quest"|"craft"|"gear"|"safe"|nil, quests = {...}, questItem = bool, craft = {...}, vendor = copper|nil, tradeable = n }
function U.ItemUsage(id, it, name, charKey)
    if not U.Enabled() or type(id) ~= "number" then return nil end
    local idx = U.Index()
    local sell, cid, bind = ItemInfoBits(id)
    cid = (it and it.classID) or cid
    local u = { classID = cid, id = id }
    u.vendor = (sell and sell > 0) and sell or nil
    u.questItem = cid == U.CLASS_QUEST or bind == U.BIND_QUEST
    local key = Str(name) and name:lower()
    u.quests = key and idx.quest[key] or nil
    u.craft = idx.craft[id]
    local raw = it and ((it.bag or 0) + (it.bank or 0) + (it.mail or 0)) or 0
    local untrad = it and ((it.ubag or 0) + (it.ubank or 0) + (it.umail or 0)) or 0
    u.count, u.tradeable = raw, math.max(0, raw - untrad)
    -- live bag info (logged-in character only): the game's own quest link for the item
    local live = (charKey == nil or (AS.CurrentKey and charKey == AS.CurrentKey())) and U.BagQuestInfo()[id] or nil
    if live then
        u.live = live
        if live.isQuestItem then u.questItem = true end
        if live.questID then
            local map = U.QuestMap()
            local old = map[id]
            if type(old) ~= "table" or old.q ~= live.questID then map[id] = { q = live.questID, title = U.QuestTitle(live.questID), how = "bag" } end
            if live.isActive then u.liveActive = true end
            if not live.isActive and IsCompleted(live.questID) == true then
                local rec = charKey and AS.db and AS.db.chars[charKey]
                if rec then rec.questsDone = type(rec.questsDone) == "table" and rec.questsDone or {}; rec.questsDone[live.questID] = true end
                u.liveDone = true
            end
        end
    end
    -- 0.4.0: cross-reference every quest that uses the item (database + game evidence) and the later chain steps
    local qv
    if u.questItem or U.DBItem(id) then
        local ok, v = pcall(U.QuestVerdict, id, charKey, live)
        if ok and type(v) == "table" then qv = v end
    end
    u.qv = qv
    local m = U.QuestMap()[id]
    local focus = qv and (qv.blocker or (qv.list and qv.list[1])) or nil
    if focus then u.questID, u.questTitle = focus.q, focus.name
    elseif type(m) == "table" and Num(m.q) then u.questID, u.questTitle = m.q, m.title end
    if type(m) == "table" then u.how = m.how end
    if u.questID then
        u.activeOn = idx.activeQ[u.questID]
        if qv then for _, e in ipairs(qv.list) do if e.state == "active" then u.activeOn = e.who; u.activeQuest = e; break end end end
        u.done = qv and qv.safe or false
        if not u.done then
            for k, r in pairs(AS.db.chars) do
                if k ~= charKey and type(r.questsDone) == "table" and r.questsDone[u.questID] then u.doneBy = Label(k, r); break end
            end
        end
    end
    u.kept = U.IsKept(id)
    if u.quests or u.activeOn or u.liveActive then u.verdict = "quest"
    elseif u.kept then u.verdict = "keep"
    elseif u.questItem and qv and qv.safe and not u.craft then u.verdict = "done"
    elseif u.questItem then u.verdict = "quest"; u.unknownQuest = not (qv and qv.known); u.keepReason = qv and qv.reason or "Quest item: can't confirm, keep"
    elseif qv and qv.classPending then u.verdict = "quest"; u.keepReason = "Keep: " .. qv.classPending.name .. " (" .. qv.classPending.q .. ") still needs it"
    elseif u.craft then u.verdict = "craft"
    elseif cid and U.GEAR[cid] then u.verdict = "gear"
    elseif cid and cid ~= U.CLASS_RECIPE and u.tradeable > 0 then
        local ahp = AS.Prices and AS.Prices.Enabled() and AS.Prices.API() and AS.Prices.AHPrice(id) or nil
        u.ah = ahp
        if u.vendor or ahp then u.verdict = "safe" end
    end
    return u
end

U.TAG = { done = "|cff9acd32Quest done: safe to delete|r", quest = "|cffffd100Quest|r", keep = "|cffff9933Keep|r", craft = "|cff33d6c4Crafting|r", gear = "|cff888888Gear|r", safe = "|cff9acd32Safe to sell|r" }
function U.RowTag(u) return (type(u) == "table" and u.verdict and U.TAG[u.verdict]) or "" end

local function Money(c) return AS.Prices and AS.Prices.Money(c) or AS.FormatMoney(c) end

-- 0.3.9: one line for the game's own item tooltip. Returns text or nil.
local DASH = "\226\128\148"
function U.TooltipLine(u)
    if type(u) ~= "table" or not u.verdict then return nil end
    local v = u.verdict
    if v == "done" then return "|cff40ff40AltStash: Quest done " .. DASH .. " safe to delete|r" end
    if v == "quest" then
        local q = u.quests and u.quests[1]
        if q then
            local more = (#u.quests > 1) and string.format(" +%d more", #u.quests - 1) or ""
            return "|cffffd100AltStash: Needed for " .. tostring(q.title) .. " (" .. tostring(q.char) .. ")" .. more .. "|r"
        end
        if u.activeOn or u.liveActive then
            local who = u.activeOn or (AS.CurrentKey and AS.UniqueLabel and AS.UniqueLabel(AS.CurrentKey())) or "you"
            return "|cffffd100AltStash: Needed for " .. tostring(u.questTitle or U.QuestTitle(u.questID) or ("quest " .. tostring(u.questID))) .. " (" .. tostring(who) .. ")|r"
        end
        if u.keepReason then return "|cffffd100AltStash: " .. tostring(u.keepReason) .. "|r" end
        if u.questID then return "|cffffd100AltStash: Quest item for " .. tostring(u.questTitle or U.QuestTitle(u.questID) or ("quest " .. u.questID)) .. " (not completed yet)|r" end
        return "|cffffd100AltStash: Quest item: can't confirm, keep|r"
    end
    if v == "keep" then return "|cffff9933AltStash: Keep (marked by you)|r" end
    if v == "craft" then
        local n, seen = 0, {}
        for _, c in ipairs(u.craft or {}) do local k = tostring(c.prof) .. tostring(c.recipe); if not seen[k] then seen[k] = true; n = n + 1 end end
        return string.format("|cff33d6c4AltStash: Crafting reagent (%d recipe%s)|r", n, n == 1 and "" or "s")
    end
    if v == "safe" then return "|cff9acd32AltStash: Safe to sell|r" end
    return nil   -- gear: say nothing
end

-- 0.4.0: with Shift held, the quest IDs behind the verdict: "Quests: 2458 Deep Cover (done), 2478 ... (not done)"
function U.TooltipQuestLine(u)
    local qv = type(u) == "table" and u.qv
    if not (qv and qv.list and #qv.list > 0) then return nil end
    local parts = {}
    for i, e in ipairs(qv.list) do
        if i > 6 then parts[#parts + 1] = string.format("+%d more", #qv.list - 6); break end
        parts[#parts + 1] = string.format("%d %s (%s)", e.q, tostring(e.name), U.STATE_TEXT[e.state] or e.state)
    end
    return "|cff999999AltStash quests: " .. table.concat(parts, ", ") .. (qv.known and "" or " [not in quest database]") .. "|r"
end

-- usage for any item id from the current character's point of view (game tooltip)
function U.UsageForTooltip(id)
    if not (U.Enabled() and AS.db and type(id) == "number") then return nil end
    local key = AS.CurrentKey and AS.CurrentKey()
    local rec = key and AS.db.chars[key]
    local it = rec and rec.items and rec.items[id]
    if not it then
        local un = AS._IsUntradeable and AS._IsUntradeable(id, nil)
        it = { bag = 1, ubag = (un == true) and 1 or 0 }
    end
    local name = (AS.ItemName and AS.ItemName(id, it)) or nil
    return U.ItemUsage(id, it, name, key)
end

-- tooltip lines { text, r, g, b }
function U.TooltipLines(u)
    local L = {}
    if type(u) ~= "table" then return L end
    local function Add(t, r, g, b) L[#L + 1] = { t, r or 0.9, g or 0.9, b or 0.9 } end
    if u.verdict == "keep" then Add("Keep: you marked this item (/as unkeep to clear).", 1, 0.6, 0.2) end
    if u.verdict == "done" then
        Add("Quest done: every quest that uses it (and the rest of the chain) is completed on this character.", 0.6, 0.8, 0.2, true)
        Add("Safe to delete: no active quest on any character needs it and no saved recipe uses it.", 0.6, 0.8, 0.2, true)
    elseif u.keepReason then
        Add(tostring(u.keepReason), 1, 0.82, 0, true)
        if u.doneBy then Add("Completed by " .. tostring(u.doneBy) .. " (quest items are usually per character: not marked safe).", 0.6, 0.6, 0.6, true) end
    elseif u.questItem and u.questID then
        local st = u.activeOn and ("in " .. tostring(u.activeOn) .. "'s quest log") or "not completed on this character"
        Add("Quest item for \"" .. tostring(u.questTitle or ("quest " .. u.questID)) .. "\" (" .. st .. ")", 1, 0.82, 0, true)
        if u.doneBy then Add("Completed by " .. tostring(u.doneBy) .. " (quest items are usually per character: not marked safe).", 0.6, 0.6, 0.6, true) end
    elseif u.questItem then
        Add("Quest item (unknown quest): AltStash hasn't seen which quest it belongs to, so it isn't marked safe.", 1, 0.82, 0, true)
    end
    if u.qv and u.qv.list then
        for i, e in ipairs(u.qv.list) do
            if i > 6 then Add(string.format("  ... and %d more quest%s (/as questinfo %d)", #u.qv.list - 6, #u.qv.list - 6 == 1 and "" or "s", u.id or 0), 0.6, 0.6, 0.6); break end
            local ok = e.state == "done" or e.state == "na" or e.state == "excl"
            Add(string.format("  %d %s: %s", e.q, tostring(e.name), U.STATE_TEXT[e.state] or e.state), ok and 0.6 or 1, ok and 0.8 or 0.82, ok and 0.2 or 0)
        end
    end
    for i, q in ipairs(u.quests or {}) do
        if i > 4 then Add(string.format("  ... and %d more quest%s", #u.quests - 4, #u.quests - 4 == 1 and "" or "s"), 1, 0.82, 0); break end
        local prog = (q.have and q.need) and string.format(" %d/%d", q.have, q.need) or ""
        Add("Quest: " .. tostring(q.title) .. " (" .. tostring(q.char) .. ")" .. prog, 1, 0.82, 0)
    end
    if u.craft then
        local names, seen, chars, seenC = {}, {}, {}, {}
        for _, c in ipairs(u.craft) do
            local label = tostring(c.prof) .. ": " .. tostring(c.recipe or "?")
            if not seen[label] then seen[label] = true; names[#names + 1] = label end
            if not seenC[c.char] then seenC[c.char] = true; chars[#chars + 1] = c.char end
        end
        table.sort(names)
        local shown = {}
        for i = 1, math.min(3, #names) do shown[i] = names[i] end
        Add(string.format("Used in: %d recipe%s (%s%s)", #names, #names == 1 and "" or "s", table.concat(shown, ", "), #names > 3 and ", ..." or ""), 0.2, 0.84, 0.77)
        table.sort(chars)
        Add("Crafted by: " .. table.concat(chars, ", "), 0.2, 0.84, 0.77)
    elseif u.classID == U.CLASS_TRADE then
        Add("Trade Goods (crafting material, not used by your saved recipes)", 0.6, 0.6, 0.6)
    end
    if u.vendor then
        Add("Vendor sell price: " .. Money(u.vendor) .. " each" .. ((u.tradeable or 0) > 1 and (", " .. Money(u.vendor * u.tradeable) .. " for " .. u.tradeable) or ""), 1, 1, 1)
    end
    if u.verdict == "safe" then Add("Safe to sell: not needed by your saved quests or recipes.", 0.6, 0.8, 0.2)
    elseif u.verdict == "gear" then Add("Gear: AltStash doesn't judge equipment, check it yourself.", 0.6, 0.6, 0.6) end
    local idx = U.Index()
    if idx.questChars < idx.chars then Add(string.format("Quest logs saved for %d of %d characters (log in on the others once).", idx.questChars, idx.chars), 0.5, 0.5, 0.5) end
    if not idx.pt then Add("Recipes unknown: ProfTracker isn't loaded.", 0.5, 0.5, 0.5) end
    return L
end

-- 0.4.0: /as questinfo <item>: chat lines explaining the verdict for the logged-in character
function U.QuestInfoLines(id)
    local L = {}
    id = U.ParseItemArg(id)
    if not id then L[1] = "Use /as questinfo <item link or item ID>."; return L end
    local key = AS.CurrentKey and AS.CurrentKey()
    local u = U.UsageForTooltip(id)
    local name = (AS.ItemName and AS.ItemName(id, nil)) or ("item " .. id)
    local qv = (u and u.qv) or U.QuestVerdict(id, key)
    local verdict
    if u and u.verdict == "keep" then verdict = "Keep (marked by you)"
    elseif u and u.verdict == "done" then verdict = "Quest done: safe to delete"
    elseif u and u.verdict == "quest" and (u.quests or u.activeOn or u.liveActive) and not u.keepReason then verdict = "Needed for an active quest"
    elseif u and u.keepReason then verdict = u.keepReason
    elseif qv and qv.known then verdict = qv.reason .. ((u and not u.questItem) and " (not a quest-class item: judged as a normal item)" or "")
    else verdict = "Not in the quest database" end
    L[#L + 1] = string.format("%s (%d): %s", name, id, verdict)
    if qv and #qv.list > 0 then
        for _, e in ipairs(qv.list) do
            local roles = {}
            for c in tostring(e.roles):gmatch("%a") do roles[#roles + 1] = U.ROLE_TEXT[c] or c end
            local extra = e.via and (" after " .. e.via) or ""
            if e.state == "active" and e.who then extra = extra .. " (in " .. tostring(e.who) .. "'s log)" end
            L[#L + 1] = string.format("  %d %s [%s%s]: %s%s", e.q, tostring(e.name), table.concat(roles, ", "), extra, U.STATE_TEXT[e.state] or e.state, e.inDB and "" or " (not in database)")
        end
    else
        L[#L + 1] = "  No quest IDs known for this item."
    end
    local D = U.DB()
    L[#L + 1] = "  Data: " .. (D and (tostring(D.source) .. ", game quest log and bag quest info") or "built-in quest database not loaded; game data only")
    if U.IsKept(id) then L[#L + 1] = "  On your keep list (/as unkeep " .. id .. " to remove)." end
    return L
end
