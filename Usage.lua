-- AltStash 0.3.8: what is an item used for? Quest / Crafting / Gear / Safe to sell tags for the Items view.
--   Quest    : a quest item (item class Quest or quest bind type), or an item objective of a quest in ANY saved character's
--              quest log (captured per character on login / quest log changes: AltStashDB.chars[key].quests, optional field).
--   Crafting : a reagent of a recipe known by any character (ProfTracker data).
--   Gear     : weapons / armour: never judged.
--   Quest done : a quest item whose quest is known (seen as an objective / quest-starter) AND flagged completed on this
--              character, not needed by any active quest on any character and not a reagent: safe to delete.
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
    local u = { classID = cid }
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
    local m = U.QuestMap()[id]
    if type(m) == "table" and Num(m.q) then
        u.questID, u.questTitle = m.q, m.title        -- (only quest-class items can become "Quest done": a mapped Thorium Bar stays a normal item)
        u.activeOn = idx.activeQ[m.q]
        local rec = charKey and AS.db and AS.db.chars[charKey]
        u.done = (rec and type(rec.questsDone) == "table" and rec.questsDone[m.q] == true) or u.liveDone == true
        u.how = m.how
        if not u.done then
            for k, r in pairs(AS.db.chars) do
                if k ~= charKey and type(r.questsDone) == "table" and r.questsDone[m.q] then u.doneBy = Label(k, r); break end
            end
        end
    end
    if u.quests or u.activeOn or u.liveActive then u.verdict = "quest"
    elseif u.questItem and u.done and not u.craft then u.verdict = "done"
    elseif u.questItem then u.verdict = "quest"; u.unknownQuest = not u.questID
    elseif u.craft then u.verdict = "craft"
    elseif cid and U.GEAR[cid] then u.verdict = "gear"
    elseif cid and cid ~= U.CLASS_RECIPE and u.tradeable > 0 then
        local ahp = AS.Prices and AS.Prices.Enabled() and AS.Prices.API() and AS.Prices.AHPrice(id) or nil
        u.ah = ahp
        if u.vendor or ahp then u.verdict = "safe" end
    end
    return u
end

U.TAG = { done = "|cff9acd32Quest done: safe to delete|r", quest = "|cffffd100Quest|r", craft = "|cff33d6c4Crafting|r", gear = "|cff888888Gear|r", safe = "|cff9acd32Safe to sell|r" }
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
        if u.questID then return "|cffffd100AltStash: Quest item for " .. tostring(u.questTitle or U.QuestTitle(u.questID) or ("quest " .. u.questID)) .. " (not completed yet)|r" end
        return "|cffffd100AltStash: Quest item (unknown quest)|r"
    end
    if v == "craft" then
        local n, seen = 0, {}
        for _, c in ipairs(u.craft or {}) do local k = tostring(c.prof) .. tostring(c.recipe); if not seen[k] then seen[k] = true; n = n + 1 end end
        return string.format("|cff33d6c4AltStash: Crafting reagent (%d recipe%s)|r", n, n == 1 and "" or "s")
    end
    if v == "safe" then return "|cff9acd32AltStash: Safe to sell|r" end
    return nil   -- gear: say nothing
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
    if u.verdict == "done" then
        Add((u.how == "reward" and "Received when you turned in \"" or "Quest item for \"") .. tostring(u.questTitle or U.QuestTitle(u.questID) or ("quest " .. u.questID)) .. "\": completed on this character.", 0.6, 0.8, 0.2, true)
        Add("Safe to delete: no active quest on any character needs it and no saved recipe uses it.", 0.6, 0.8, 0.2, true)
    elseif u.questItem and u.questID then
        local st = u.activeOn and ("in " .. tostring(u.activeOn) .. "'s quest log") or "not completed on this character"
        Add("Quest item for \"" .. tostring(u.questTitle or ("quest " .. u.questID)) .. "\" (" .. st .. ")", 1, 0.82, 0, true)
        if u.doneBy then Add("Completed by " .. tostring(u.doneBy) .. " (quest items are usually per character: not marked safe).", 0.6, 0.6, 0.6, true) end
    elseif u.questItem then
        Add("Quest item (unknown quest): AltStash hasn't seen which quest it belongs to, so it isn't marked safe.", 1, 0.82, 0, true)
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
