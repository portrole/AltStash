-- AltStash: Core (data model, passive inventory scans, search, slash commands)
-- PASSIVE ONLY: reads bag/bank/mail contents the client already shows you and stores them in SavedVariables.
-- It never moves/uses/loots/sends anything, never calls protected functions, never reads the screen.
local ADDON, AS = ...
_G.AltStash = AS

AS.SCHEMA = 3            -- bump when the saved-data layout changes (see Migrate)
local DEBOUNCE = 0.3      -- seconds to coalesce bursts of events before scanning

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffAltStash:|r " .. tostring(msg)) end
AS.Print = Print
AS.version = "0.4.0"

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end

------------------------------------------------------------------------
-- API compatibility (C_Container when present, legacy globals otherwise)
------------------------------------------------------------------------
local function NumSlots(bag)
    local f = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not f then return 0 end
    local ok, n = pcall(f, bag)
    return (ok and tonumber(n)) or 0
end

-- returns itemID, link, count   (nil if the slot is empty)
local function SlotItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" then
            local link = info.hyperlink
            if (not link) and C_Container.GetContainerItemLink then link = C_Container.GetContainerItemLink(bag, slot) end
            return info.itemID, link, info.stackCount or 1, info.itemName, info.isBound
        elseif ok and info == nil then
            return nil
        end
    end
    if GetContainerItemInfo then -- legacy multi-return: texture, count, locked, quality, readable, lootable, link, ...
        local ok, tex, count, _, _, _, _, link, _, _, itemID, isBound = pcall(GetContainerItemInfo, bag, slot)
        if ok and tex then return itemID, link, count or 1, nil, isBound end
    end
    return nil
end

local function GetItemInfoCompat(id)
    if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(id) end
    if GetItemInfo then return GetItemInfo(id) end
end

local requested = {}      -- itemIDs we've already asked the client to load (don't spam requests)
local function RequestItem(id)
    if requested[id] then return end
    requested[id] = true
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
end

-- Bind types (Enum.ItemBind): 0 none, 1 BoP, 2 BoE, 3 BoU, 4 Quest, 7 Account, 8 Warband, 9 Warband-until-equipped
local BIND_BOP, BIND_QUEST = 1, 4
local ACCOUNT_BINDS = { [7] = true, [8] = true, [9] = true } -- mailable between your own characters

-- Returns true (untradeable), false (tradeable) or nil (unknown -> treated as tradeable).
--   isBound : from C_Container.GetContainerItemInfo (reliable soulbound check); nil when the source has none (mail, legacy API)
local function IsUntradeable(itemID, isBound)
    local info = { GetItemInfoCompat(itemID) } -- 12 = classID, 14 = bindType (nil if uncached)
    local classID, bindType = info[12], info[14]
    if bindType and ACCOUNT_BINDS[bindType] then return false end   -- account/warband bound: still mailable to your alts
    if isBound == true then return true end                          -- soulbound (includes bound quest items)
    if isBound == false then return false end                        -- reliably not bound (BoE/BoU/unbound BoP/materials/quest mats)
    -- isBound unknown: fall back to bind type
    if bindType == nil then return nil end
    if bindType == BIND_BOP or bindType == BIND_QUEST then return true end
    return false
end
AS._IsUntradeable = IsUntradeable

local function ItemIDFromLink(link)
    return link and tonumber(tostring(link):match("item:(%d+)"))
end
local function NameFromLink(link)
    return link and tostring(link):match("%[(.-)%]")
end

------------------------------------------------------------------------
-- Saved data
------------------------------------------------------------------------
-- v1 -> v2: v1 stored the full item link per entry; v2 stores only the name (link is built on demand).
local function MigrateV1toV2(db)
    for _, rec in pairs(db.chars or {}) do
        rec.items = rec.items or {}
        rec.scanned = rec.scanned or {}
        for _, it in pairs(rec.items) do
            if it.link then
                it.name = it.name or NameFromLink(it.link)
                it.link = nil
            end
            it.bag, it.bank, it.mail = it.bag or 0, it.bank or 0, it.mail or 0
        end
    end
end

-- Returns true if db is usable/writable. Never touches data written by a newer schema.
local function Migrate(db)
    if not db.schemaVersion then
        db.schemaVersion = AS.SCHEMA
        db.chars = db.chars or {}
        db.settings = { tradeableOnly = true, auctions = true, typeFilter = "all" }
        return true
    end
    if db.schemaVersion > AS.SCHEMA then
        return false
    end
    db.chars = db.chars or {}
    db.settings = db.settings or {}
    if db.settings.tradeableOnly == nil then db.settings.tradeableOnly = true end
    if db.settings.auctions == nil then db.settings.auctions = true end
    if db.settings.typeFilter == nil then db.settings.typeFilter = "all" end
    if db.schemaVersion < 2 then
        MigrateV1toV2(db)
        db.schemaVersion = 2
    end
    if db.schemaVersion < 3 then
        -- v3: characters are keyed by UnitGUID("player"). Old "Name-Realm" entries are kept as they are and are
        -- re-keyed to the GUID the next time that character logs in (see ClaimLegacy). Nothing is moved here.
        db.schemaVersion = 3
    end
    return true
end
AS._Migrate = Migrate

function AS.CharKey(name, realm) return name .. "-" .. realm end -- legacy (schema <= 2) key

------------------------------------------------------------------------
-- Character names (VERIFIED in game on Forever 1.60.1 via /as debugname):
--   UnitName / UnitFullName / UnitNameUnmodified("player") return TWO values: first name, SECOND NAME (surname).
--   The second return is NOT the realm. Realm comes from GetRealmName() / GetNormalizedRealmName().
--   GetUnitName("player", true|false) returns the full "First Second" string.
-- A character with no second name returns nil/"" as the second value.
------------------------------------------------------------------------
local function CleanStr(v)
    if type(v) == "string" and v ~= "" and not IsSecret(v) then return v end
end

-- Names of a unit (default "player"): { name = first, firstName, secondName (or nil), displayName }
function AS.ComputeNames(unit)
    unit = unit or "player"
    local n1, n2 = UnitName(unit)
    local first, second = CleanStr(n1), CleanStr(n2)
    if not first or first == "Unknown" then return nil end
    local display
    if second then
        display = first .. " " .. second
    end
    local okG, g = pcall(GetUnitName, unit, true)
    g = okG and CleanStr(g) or nil
    -- GetUnitName gives the client's own formatting of the full name; use it when it is consistent with first/second
    if g and g:sub(1, #first) == first and (not second or g:find(second, 1, true)) and not g:find("-", 1, true) then
        display = g
    end
    display = display or first
    return { name = first, firstName = first, secondName = second, displayName = display, source = "UnitName returns (first, second)" }
end

function AS.CharLabel(rec) return rec.displayName or rec.name or "?" end

function AS.KeySuffix(key)
    key = tostring(key)
    if key:find("^Player%-") then return key:sub(-6) end
    local h = 0 -- legacy Name-Realm key: short stable hash so two old entries never share a suffix
    for i = 1, #key do h = (h * 31 + key:byte(i)) % 9973 end
    return string.format("old%04d", h)
end

-- Label that is unique among saved characters: appends [GUID suffix] only if two characters share a label.
function AS.UniqueLabel(key)
    local rec = AS.db.chars[key]
    if not rec then return tostring(key) end
    local label = AS.CharLabel(rec)
    local n = 0
    local lower = label:lower()
    for k, r in pairs(AS.db.chars) do
        if AS.CharLabel(r):lower() == lower then n = n + 1 end
    end
    if n > 1 then label = label .. " [" .. AS.KeySuffix(key) .. "]" end
    return label
end

-- GUID of the logged-in character, or nil
function AS.CurrentGUID()
    local g = UnitGUID and UnitGUID("player")
    if type(g) == "string" and g ~= "" and not IsSecret(g) then return g end
end

local function RealmNorm(r) return (tostring(r or ""):gsub("[%s%-']", ""):lower()) end
AS._RealmNorm = RealmNorm

-- Old (schema <= 2, no guid) entries that belong to the given character. Old entries only know the FIRST name, and the
-- realm may have been stored spaced ("Classic Beta PvE") or normalized ("ClassicBetaPvE"); both are accepted.
local function LegacyCandidates(names, realm, classFile)
    local cands = {}
    local first = names.firstName or names.name
    local okN, normRealm = pcall(GetNormalizedRealmName)
    local wantRealm = { [RealmNorm(realm)] = true }
    if okN and CleanStr(normRealm) then wantRealm[RealmNorm(normRealm)] = true end
    for key, rec in pairs(AS.db.chars) do
        if not rec.guid and not key:find("^Player%-") then
            local kname, krealm = key:match("^(.-)%-(.+)$")
            local nameOk = (rec.name or kname) == first or rec.name == names.displayName
            if nameOk and wantRealm[RealmNorm(rec.realm or krealm)] and (not rec.classFile or not classFile or rec.classFile == classFile) then
                cands[#cands + 1] = key
            end
        end
    end
    return cands
end

-- Key of the current character if it already has a record (GUID key, else an unclaimed legacy Name-Realm key)
function AS.CurrentKey()
    if not AS.db then return nil end
    local guid = AS.CurrentGUID()
    if guid and AS.db.chars[guid] then return guid end
    local names, realm = AS.ComputeNames(), GetRealmName()
    if names and realm then
        local _, classFile = UnitClass("player")
        local cands = LegacyCandidates(names, realm, classFile)
        table.sort(cands)
        if cands[1] then return cands[1] end
    end
    return guid
end

local function LastScan(rec)
    local m = 0
    for _, t in pairs(rec.scanned or {}) do if type(t) == "number" and t > m then m = t end end
    return m
end

-- Move a legacy (Name-Realm keyed) record to the GUID key when that character logs in.
-- Safe rules: only records without a guid that match name+realm (and class when known); if several match,
-- the most recently scanned one is claimed and the others are KEPT under their old keys (nothing is merged away).
local function ClaimLegacy(guid, names, realm, classFile)
    local db = AS.db
    local cands = LegacyCandidates(names, realm, classFile)
    if #cands == 0 then return nil end
    table.sort(cands, function(a, b)
        local la, lb = LastScan(db.chars[a]), LastScan(db.chars[b])
        if la ~= lb then return la > lb end
        return a < b
    end)
    local key = cands[1]
    local rec = db.chars[key]
    db.chars[guid] = rec
    db.chars[key] = nil
    rec.guid = guid
    rec.migratedFrom = key
    if #cands > 1 then
        Print("Note: " .. (#cands - 1) .. " other old saved entr" .. (#cands > 2 and "ies" or "y") .. " for " .. names.name ..
            " were kept under their old keys (use /as list, /as reset to clean up).")
    end
    return rec
end
AS._ClaimLegacy = ClaimLegacy

local function CurrentRecord()
    local names = AS.ComputeNames()
    local realm = GetRealmName()
    if not names or not realm then return nil end
    local className, classFile = UnitClass("player")
    local guid = AS.CurrentGUID()
    local key, rec
    if guid then
        key = guid
        rec = AS.db.chars[guid]
        if not rec then rec = ClaimLegacy(guid, names, realm, classFile) end
        if not rec then rec = { items = {}, scanned = {} }; AS.db.chars[guid] = rec end
        rec.guid = guid
    else
        -- no GUID available (should not happen on login): fall back to the legacy key so nothing breaks
        key = AS.CharKey(names.name, realm)
        rec = AS.db.chars[key]
        if not rec then rec = { items = {}, scanned = {} }; AS.db.chars[key] = rec end
    end
    rec.items = rec.items or {}; rec.scanned = rec.scanned or {}
    rec.name, rec.realm = names.name, realm
    rec.firstName, rec.secondName, rec.displayName, rec.nameSource = names.firstName, names.secondName, names.displayName, names.source
    rec.class, rec.classFile = className, classFile
    local okN, norm = pcall(GetNormalizedRealmName)
    rec.realmNorm = okN and CleanStr(norm) or nil
    AS.StoreIdentity(rec)
    AS.StoreMoney(rec)
    return rec, key
end

-- 0.3.0: optional race / sex / level fields for the window's character tabs (portrait fallback for offline alts).
-- Optional fields, so the schema stays 3; entries saved before 0.3.0 get them the next time that character logs in.
--   race (localized), raceFile (e.g. "Scourge" for Undead), raceID, sex (UnitSex: 1 unknown, 2 male, 3 female), level
AS._CurrentRecord = function() return CurrentRecord() end   -- 0.3.8: used by the quest-log capture (Usage.lua)

function AS.StoreIdentity(rec, newLevel)
    if not rec then return end
    if type(UnitRace) == "function" then
        local ok, rName, rFile, rID = pcall(UnitRace, "player")
        if ok then
            rec.race, rec.raceFile = CleanStr(rName) or rec.race, CleanStr(rFile) or rec.raceFile
            if type(rID) == "number" and not IsSecret(rID) then rec.raceID = rID end
        end
    end
    if type(UnitSex) == "function" then
        local ok, sx = pcall(UnitSex, "player")
        if ok and type(sx) == "number" and not IsSecret(sx) then rec.sex = sx end
    end
    local lvl = newLevel
    if type(lvl) ~= "number" and type(UnitLevel) == "function" then
        local ok, l = pcall(UnitLevel, "player")
        if ok then lvl = l end
    end
    if type(lvl) == "number" and not IsSecret(lvl) and lvl > 0 then rec.level = lvl end
end

-- Money (copper). Optional per-character fields `money` + `goldUpdated`; absent on old entries (shown as "gold unknown"),
-- so no schema bump is needed. Not affected by the tradeable filter.
function AS.StoreMoney(rec)
    if type(GetMoney) ~= "function" then return end
    local ok, m = pcall(GetMoney)
    if ok and type(m) == "number" and not IsSecret(m) and m >= 0 then
        rec.money, rec.goldUpdated = m, time()
    end
end

function AS.ScanMoney()
    if not AS.db then return end
    local rec = CurrentRecord(); if not rec then return end -- CurrentRecord stores the money
end

-- Refresh name fields of the current character's EXISTING record without scanning (runs at login).
function AS.RefreshCurrentNames()
    if not AS.db then return end
    local key = AS.CurrentKey()
    local rec = key and AS.db.chars[key]
    local names = AS.ComputeNames()
    local realm = GetRealmName()
    if not rec or not names or not realm then return end
    rec.name, rec.realm = names.name, realm
    rec.firstName, rec.secondName, rec.displayName, rec.nameSource = names.firstName, names.secondName, names.displayName, names.source
    AS.StoreIdentity(rec)
end

AS.index = nil           -- itemID -> list of per-character counts (rebuilt lazily)
local function Dirty() AS.index = nil end

-- Replace one location's counts for a record with `found` (id -> {link=, count=})
local function ApplyLocation(rec, loc, found)
    local ukey = "u" .. loc
    for _, it in pairs(rec.items) do it[loc] = 0; it[ukey] = nil end
    for id, f in pairs(found) do
        local it = rec.items[id]
        if not it then it = { bag = 0, bank = 0, mail = 0 }; rec.items[id] = it end
        it[loc] = f.count
        if f.untrad and f.untrad > 0 then it[ukey] = f.untrad end -- units that are soulbound/untradeable (absent = none/unknown)
        if f.name then it.name = f.name end
        if not it.classID then AS.StoreType(id, it) end
    end
    for id, it in pairs(rec.items) do
        if (it.bag or 0) + (it.bank or 0) + (it.mail or 0) <= 0 then rec.items[id] = nil end
    end
    rec.scanned[loc] = time()
    Dirty()
end

local function Add(found, id, link, count, name, isBound)
    id = id or ItemIDFromLink(link)
    if not id or IsSecret(id) then return end
    local f = found[id]
    if not f then f = { count = 0, untrad = 0 }; found[id] = f end
    local n = tonumber(count) or 1
    f.count = f.count + n
    if IsUntradeable(id, isBound) == true then f.untrad = f.untrad + n end
    if not f.name then
        local n = NameFromLink(link) or name
        if type(n) == "string" and n ~= "" then f.name = n end
    end
end

------------------------------------------------------------------------
-- Container ids
------------------------------------------------------------------------
local function BagIds()
    local ids = {}
    for b = 0, (NUM_BAG_SLOTS or 4) do ids[#ids + 1] = b end
    if (NUM_REAGENTBAG_SLOTS or 0) > 0 then ids[#ids + 1] = (NUM_BAG_SLOTS or 4) + 1 end
    return ids
end

-- Bank: -1 (main bank), then the bank-bag / bank-tab ids. Works for the Classic layout (5..11) and the
-- modern layout (reagent bag shifts them up; 11.2 bank tabs). Warband/account bank tabs are never included.
local function BankIds()
    local bag = {}
    for _, b in ipairs(BagIds()) do bag[b] = true end
    local skip = {}
    local E = Enum and Enum.BagIndex
    if E then
        for i = 1, 5 do local v = E["AccountBankTab_" .. i]; if v then skip[v] = true end end
        if E.Accountbanktab then skip[E.Accountbanktab] = true end
    end
    local set, ids = {}, {}
    local function add(b) if b and not bag[b] and not skip[b] and not set[b] then set[b] = true; ids[#ids + 1] = b end end
    add(-1)
    local first = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0) + 1
    for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do add(b) end
    if E then
        for i = 1, 7 do add(E["BankBag_" .. i]) end
        for i = 1, 6 do add(E["CharacterBankTab_" .. i]) end
    end
    return ids
end
AS._BagIds, AS._BankIds = BagIds, BankIds

------------------------------------------------------------------------
-- Scans
------------------------------------------------------------------------
local state = { bankOpen = false, mailOpen = false, ahOpen = false }
AS.state = state

local function ScanContainers(ids)
    local found, totalSlots = {}, 0
    for _, bag in ipairs(ids) do
        local n = NumSlots(bag)
        totalSlots = totalSlots + n
        for slot = 1, n do
            local id, link, count, nm, bound = SlotItem(bag, slot)
            if id or link then Add(found, id, link, count, nm, bound) end
        end
    end
    return found, totalSlots
end

function AS.ScanBags()
    if not AS.db then return end
    local rec = CurrentRecord(); if not rec then return end
    local found, slots = ScanContainers(BagIds())
    if slots <= 0 then return end -- container data not ready yet; keep the old record
    ApplyLocation(rec, "bag", found)
end

function AS.ScanBank()
    if not AS.db or not state.bankOpen then return end
    local rec = CurrentRecord(); if not rec then return end
    local found, slots = ScanContainers(BankIds())
    if slots <= 0 then return end
    ApplyLocation(rec, "bank", found)
end

function AS.ScanMail()
    if not AS.db or not state.mailOpen or not GetInboxNumItems then return end
    local n = GetInboxNumItems()
    if type(n) ~= "number" then return end -- failed/nil read: keep stored mail; a real 0 clears it
    local rec = CurrentRecord(); if not rec then return end
    local found = {}
    local maxAtt = ATTACHMENTS_MAX_RECEIVE or 16
    for i = 1, n do
        for j = 1, maxAtt do
            local name, itemID, _, count = GetInboxItem(i, j)
            if name or itemID then
                local link = GetInboxItemLink and GetInboxItemLink(i, j)
                Add(found, itemID, link, count, name)
            end
        end
    end
    ApplyLocation(rec, "mail", found)
    pcall(AS.ScanAuctionMail, rec, n) -- read-only: auction sold/expired/cancelled mails (headers only)
end


------------------------------------------------------------------------
-- Auction listings (the character's OWN auctions). Passive reads only, and only while the AH window is open.
-- VERIFIED on warcraft.wiki.gg for Forever 1.60.1: C_AuctionHouse.GetOwnedAuctions (OwnedAuctionInfo[]: auctionID, itemKey,
--   itemLink?, status, quantity, timeLeftSeconds?, timeLeft?, bidAmount?, buyoutAmount?, bidder?), C_AuctionHouse.GetNumOwnedAuctions,
--   event OWNED_AUCTIONS_UPDATED, Enum.AuctionStatus (0 Active, 1 Sold), Enum.AuctionHouseTimeLeftBand (0..3).
-- NOT verified for Forever: the legacy fallback GetNumAuctionItems/GetAuctionItemInfo("owner") (Classic-era API) and
--   GetItemCommodityStatus. We never call QueryOwnedAuctions (reported to interfere with the sell tab); the AH window's own
--   queries fire OWNED_AUCTIONS_UPDATED, which we just read.
-- Saved (optional, no schema bump): rec.auctions = { {itemID,name,quantity,buyoutCopper,bidCopper,status="active"|"sold",
--   timeLeftBand=0..3,commodity=true?}, ... }, rec.ahScanned = time.
------------------------------------------------------------------------
function AS.AuctionsEnabled()
    return not (AS.db and AS.db.settings and AS.db.settings.auctions == false)
end

-- Time left. VERIFIED (wiki, Forever 1.60.1): OwnedAuctionInfo.timeLeftSeconds? and .timeLeft? are both optional;
-- GetAuctionInfoByID returns AuctionInfo (itemKey, itemLink, minBid, bidAmount, buyoutAmount, bidder - no time fields documented);
-- GetOwnedAuctionInfo(index) returns OwnedAuctionInfo?. In game the band (timeLeft) came back nil, so every source is tried in order.
local function BandFromSeconds(secs)
    if secs <= 1800 then return 0 elseif secs <= 7200 then return 1 elseif secs <= 43200 then return 2 end
    return 3
end

local function TimeFrom(t)
    if type(t) ~= "table" then return nil end
    local secs, band = tonumber(t.timeLeftSeconds), tonumber(t.timeLeft)
    if secs and IsSecret(secs) then secs = nil end
    if band and (IsSecret(band) or band < 0 or band > 3) then band = nil end
    return secs, band
end

-- returns secs (maybe nil), band (maybe nil), source name (nil when nothing is available)
function AS.DeriveTimeLeft(a, index)
    local secs, band = TimeFrom(a)
    if secs then return secs, BandFromSeconds(secs), "timeLeftSeconds" end      -- (1)
    if band then return nil, band, "timeLeft" end                               -- (2)
    if C_AuctionHouse then
        if type(C_AuctionHouse.GetAuctionInfoByID) == "function" and a.auctionID then   -- (3)
            local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, a.auctionID)
            if ok then
                secs, band = TimeFrom(info)
                if secs then return secs, BandFromSeconds(secs), "GetAuctionInfoByID" end
                if band then return nil, band, "GetAuctionInfoByID" end
            end
        end
        if type(C_AuctionHouse.GetOwnedAuctionInfo) == "function" and index then        -- (4)
            local ok, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, index)
            if ok then
                secs, band = TimeFrom(info)
                if secs then return secs, BandFromSeconds(secs), "GetOwnedAuctionInfo" end
                if band then return nil, band, "GetOwnedAuctionInfo" end
            end
        end
    end
    if type(GetAuctionItemTimeLeft) == "function" and index then                          -- (5) legacy 1..4
        local ok, t = pcall(GetAuctionItemTimeLeft, "owner", index)
        if ok and type(t) == "number" and t >= 1 and t <= 4 then return nil, t - 1, "GetAuctionItemTimeLeft" end
    end
    return nil, nil, nil
end

local function ModernOwned()
    if C_AuctionHouse and type(C_AuctionHouse.GetOwnedAuctions) == "function" then
        local ok, list = pcall(C_AuctionHouse.GetOwnedAuctions)
        if ok and type(list) == "table" then
            local out = {}
            for i, a in ipairs(list) do
                local id = a.itemKey and a.itemKey.itemID
                if type(id) == "number" and not IsSecret(id) then
                    local e = { auctionID = tonumber(a.auctionID), itemID = id, quantity = tonumber(a.quantity) or 1,
                        buyoutCopper = tonumber(a.buyoutAmount) or 0, bidCopper = tonumber(a.bidAmount) or 0,
                        status = (a.status == 1) and "sold" or "active" }
                    e.name = NameFromLink(a.itemLink)
                    e.timeLeftSeconds, e.timeLeftBand, e.timeSource = AS.DeriveTimeLeft(a, i)
                    if C_AuctionHouse.GetItemCommodityStatus then
                        local okC, cs = pcall(C_AuctionHouse.GetItemCommodityStatus, id)
                        if okC and cs == 2 then e.commodity = true end -- unit price listing (buyoutAmount is per unit)
                    end
                    out[#out + 1] = e
                end
            end
            return out
        end
    end
end

local function LegacyOwned()
    if type(GetNumAuctionItems) ~= "function" or type(GetAuctionItemInfo) ~= "function" then return nil end
    local ok, batch = pcall(GetNumAuctionItems, "owner")
    if not ok or type(batch) ~= "number" then return nil end
    local out = {}
    for i = 1, batch do
        local okI, name, _, count, _, _, _, _, minBid, _, buyout, bidAmount, _, _, _, _, saleStatus, itemId = pcall(GetAuctionItemInfo, "owner", i)
        if okI and type(itemId) == "number" and itemId > 0 then
            local band
            if type(GetAuctionItemTimeLeft) == "function" then
                local okT, t = pcall(GetAuctionItemTimeLeft, "owner", i)
                if okT and type(t) == "number" and t >= 1 and t <= 4 then band = t - 1 end -- legacy 1..4 -> 0..3
            end
            local sold = saleStatus == 1
            out[#out + 1] = { itemID = itemId, name = (type(name) == "string" and name ~= "") and name or nil,
                quantity = tonumber(count) or 0, buyoutCopper = tonumber(buyout) or 0,
                bidCopper = tonumber(sold and bidAmount or minBid) or 0, status = sold and "sold" or "active", timeLeftBand = band, timeSource = band and "GetAuctionItemTimeLeft" or nil }
        end
    end
    return out
end

local function FullOwnedResults()
    if C_AuctionHouse and type(C_AuctionHouse.HasFullOwnedAuctionResults) == "function" then
        local ok, v = pcall(C_AuctionHouse.HasFullOwnedAuctionResults)
        return ok and v == true
    end
    return false
end

-- acceptEmpty: an empty list is trusted only when it came from the server's update event (or the client says the
-- owned results are complete); otherwise an empty read just means "not loaded yet" and must not wipe stored listings.
function AS.ScanAuctions(acceptEmpty)
    if not AS.db or not state.ahOpen then return end
    local list = ModernOwned() or LegacyOwned()
    if type(list) ~= "table" then return end
    if #list == 0 and not (acceptEmpty or FullOwnedResults()) then return end
    local rec = CurrentRecord(); if not rec then return end
    for _, e in ipairs(list) do
        if not e.name then
            local n = GetItemInfoCompat(e.itemID)
            if type(n) == "string" and n ~= "" then e.name = n else RequestItem(e.itemID) end
        end
    end
    -- carry over what we learned about the same listing earlier (first-seen time, and any time info the client later stops giving)
    local now = time()
    local prev = {}
    for _, p in ipairs(rec.auctions or {}) do prev[AS.ListingKey(p)] = p end
    for _, e in ipairs(list) do
        local p = prev[AS.ListingKey(e)]
        e.firstSeen = (p and p.firstSeen) or now
        if e.timeLeftSeconds or e.timeLeftBand then
            e.timeAt = now
        elseif p and (p.timeLeftSeconds or p.timeLeftBand) then
            e.timeLeftSeconds, e.timeLeftBand, e.timeAt = p.timeLeftSeconds, p.timeLeftBand, p.timeAt or rec.ahScanned
            e.timeSource = (p.timeSource or "earlier scan") .. " (kept)"
        end
    end
    -- listings that were active last time but are gone now: sold/expired/cancelled while we weren't looking.
    -- Status stays unknown until a matching mail is seen (SettleGone); we never guess.
    local newKeys = {}
    for _, e in ipairs(list) do newKeys[AS.ListingKey(e)] = true end
    rec.auctionGone = rec.auctionGone or {}
    for i = #rec.auctionGone, 1, -1 do -- a "gone" listing that shows up again was just a partial read: restore it
        if newKeys[rec.auctionGone[i].key] then table.remove(rec.auctionGone, i) end
    end
    for _, p in ipairs(rec.auctions or {}) do
        if p.status == "active" and not newKeys[AS.ListingKey(p)] then
            rec.auctionGone[#rec.auctionGone + 1] = { key = AS.ListingKey(p), itemID = p.itemID, name = p.name, quantity = p.quantity,
                buyoutCopper = p.buyoutCopper, bidCopper = p.bidCopper, commodity = p.commodity,
                firstSeen = p.firstSeen or rec.ahScanned or now, goneAt = now }
        end
    end
    rec.auctions = list
    rec.ahScanned = now
    AS.SettleGone(rec)
end

------------------------------------------------------------------------
-- Auction mail (read-only). VERIFIED (wiki): GetInboxHeaderInfo(index) exists in Forever 1.60.1 and returns
--   packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, hasItem, wasRead, wasReturned, ...
-- Subjects are matched against the game's own global strings (AUCTION_SOLD_MAIL_SUBJECT etc., "%s" = item name),
-- converted to Lua patterns, so it works in any locale. We never open mail, take items/money, or read mail text.
-- GetInboxInvoiceInfo is NOT used (wiki: details of an AH invoice; it is meant for an opened mail - not clearly safe here).
-- The header `money` of a sold mail is the payout (after the AH fee) while it is still attached.
------------------------------------------------------------------------
local MAIL_KINDS = {
    { "sold", "AUCTION_SOLD_MAIL_SUBJECT" }, { "expired", "AUCTION_EXPIRED_MAIL_SUBJECT" },
    { "removed", "AUCTION_REMOVED_MAIL_SUBJECT" }, { "won", "AUCTION_WON_MAIL_SUBJECT" },
    { "outbid", "AUCTION_OUTBID_MAIL_SUBJECT" },
}

-- "Auction successful: %s" (or positional "%1$s") -> "^Auction successful: (.+)$"; "%%" is a literal percent; every
-- Lua pattern magic character in the (localized) text is escaped.
function AS.FormatToPattern(fmt)
    local out, i, n = {}, 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" then
            local rest = fmt:sub(i + 1)
            local pos = rest:match("^(%d+)%$[sd]")
            if pos then out[#out + 1] = "(.+)"; i = i + 1 + #pos + 2
            elseif rest:sub(1, 1) == "s" then out[#out + 1] = "(.+)"; i = i + 2
            elseif rest:sub(1, 1) == "d" then out[#out + 1] = "%d+"; i = i + 2
            elseif rest:sub(1, 1) == "%" then out[#out + 1] = "%%"; i = i + 2
            else out[#out + 1] = "%%"; i = i + 1 end
        else
            if c:match("[%^%$%(%)%.%[%]%*%+%-%?]") then out[#out + 1] = "%" .. c else out[#out + 1] = c end
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

-- returns kind ("sold"|"expired"|"removed"|"won"|"outbid"), item name captured from the subject; nil if not an auction mail
function AS.ClassifyAuctionSubject(subject)
    if type(subject) ~= "string" or IsSecret(subject) then return nil end
    for _, k in ipairs(MAIL_KINDS) do
        local fmt = _G[k[2]]
        if type(fmt) == "string" and fmt ~= "" then
            local ok, cap = pcall(string.match, subject, AS.FormatToPattern(fmt))
            if ok and cap then return k[1], cap end
        end
    end
end

local MAIL_MATCH_SECONDS = 1800 -- same mail seen again: same subject and expiry within this many seconds
local MAIL_KEEP = 100

function AS.ScanAuctionMail(rec, n)
    if type(GetInboxHeaderInfo) ~= "function" then return end
    local now = time()
    rec.auctionMail = rec.auctionMail or {}
    local seenThisScan = {}
    local maxAtt = ATTACHMENTS_MAX_RECEIVE or 16
    for i = 1, n do
        local ok, _, _, _, subject, money, _, daysLeft = pcall(GetInboxHeaderInfo, i)
        local kind, name
        if ok then kind, name = AS.ClassifyAuctionSubject(subject) end
        if kind == "sold" or kind == "expired" or kind == "removed" then
            name = name:gsub("^%[(.*)%]$", "%1")
            local qty
            local base, q = name:match("^(.-)%s*%((%d+)%)$") -- count suffix, if the client adds one (unverified)
            if base and base ~= "" then name, qty = base, tonumber(q) end
            local itemID, attQty
            if kind ~= "sold" and type(GetInboxItem) == "function" then -- returned items are attached: read (never take) them
                for j = 1, maxAtt do
                    local okI, an, aid, _, ac = pcall(GetInboxItem, i, j)
                    if okI and (an or aid) then
                        itemID = itemID or aid
                        attQty = (attQty or 0) + (tonumber(ac) or 1)
                    end
                end
                qty = attQty or qty
            end
            money = tonumber(money) or 0
            daysLeft = tonumber(daysLeft) or 30
            local expiresAt = now + daysLeft * 86400
            -- same mail as one already recorded? (money is NOT part of the match: taking it empties the header)
            local best, bestD
            for _, r in ipairs(rec.auctionMail) do
                if not seenThisScan[r] and r.kind == kind and tostring(r.name):lower() == name:lower() then
                    local d = math.abs((r.expiresAt or 0) - expiresAt)
                    if d <= MAIL_MATCH_SECONDS and (not bestD or d < bestD) then best, bestD = r, d end
                end
            end
            if best then
                seenThisScan[best] = true
                if money > (best.money or 0) then
                    if kind == "sold" then rec.soldTotal = (rec.soldTotal or 0) + (money - (best.money or 0)) end
                    best.money = money
                end
                best.daysLeft, best.lastSeen = daysLeft, now
                best.quantity = best.quantity or qty
                best.itemID = best.itemID or itemID
            else
                local r = { kind = kind, name = name, itemID = itemID, quantity = qty, money = money, daysLeft = daysLeft,
                    expiresAt = expiresAt, firstSeen = now, lastSeen = now,
                    mailKey = string.format("%s|%s|%d", kind, name, math.floor(expiresAt)) }
                rec.auctionMail[#rec.auctionMail + 1] = r
                seenThisScan[r] = true
                if kind == "sold" then rec.soldTotal = (rec.soldTotal or 0) + money; rec.soldSince = rec.soldSince or now end
            end
        end
    end
    -- keep history bounded: drop the oldest entries beyond MAIL_KEEP
    table.sort(rec.auctionMail, function(a, b) return (a.firstSeen or 0) < (b.firstSeen or 0) end)
    while #rec.auctionMail > MAIL_KEEP do table.remove(rec.auctionMail, 1) end
    AS.SettleGone(rec)
end

-- Match "gone, status unknown" listings with recorded auction mails. Only settles when unambiguous:
--  * a mail can only belong to a listing first seen no later than the mail (older mails are history of other sales);
--  * same item (name or id) and, when the mail's quantity is known, the same quantity;
--  * #listings == #mails in the group and all those mails are the same kind (sold/expired/removed); otherwise keep "gone".
function AS.SettleGone(rec)
    if not rec.auctionGone or #rec.auctionGone == 0 or not rec.auctionMail then return end
    local gone, mails = rec.auctionGone, rec.auctionMail
    local function sameItem(g, m)
        if g.itemID and m.itemID then return g.itemID == m.itemID end
        return tostring(AS.AuctionName(g)):lower() == tostring(m.name):lower()
    end
    local function eligible(g, m) return not m.consumed and sameItem(g, m) and (m.firstSeen or 0) >= (g.firstSeen or 0) end
    local settled = {}
    local function settle(gs, ms)
        table.sort(gs, function(a, b) return (a.firstSeen or 0) < (b.firstSeen or 0) end)
        table.sort(ms, function(a, b) return (a.firstSeen or 0) < (b.firstSeen or 0) end)
        local sameQty = true
        for i = 2, #gs do if gs[i].quantity ~= gs[1].quantity then sameQty = false end end
        for i, m in ipairs(ms) do
            m.consumed = true
            m.fromListing = true
            if not m.quantity and sameQty then m.quantity = gs[1].quantity end
            if m.kind ~= "sold" then m.buyoutCopper = gs[i].buyoutCopper end
        end
        for _, g in ipairs(gs) do settled[g] = true end
    end
    -- pass 1: mails with a known quantity pair with listings of that quantity
    local byGroup = {}
    for _, m in ipairs(mails) do
        if m.quantity and not m.consumed then
            local gs = {}
            for _, g in ipairs(gone) do if not settled[g] and eligible(g, m) and g.quantity == m.quantity then gs[#gs + 1] = g end end
            if #gs > 0 then
                local id = tostring(m.itemID or tostring(m.name):lower()) .. ":" .. m.quantity
                byGroup[id] = byGroup[id] or { gs = gs, ms = {} }
                table.insert(byGroup[id].ms, m)
            end
        end
    end
    for _, grp in pairs(byGroup) do
        local k = grp.ms[1].kind
        local same = true
        for _, m in ipairs(grp.ms) do if m.kind ~= k then same = false end end
        if same and #grp.gs == #grp.ms then settle(grp.gs, grp.ms) end
    end
    -- pass 2: mails without a known quantity pair with the remaining listings of the same item
    local byItem = {}
    for _, m in ipairs(mails) do
        if not m.quantity and not m.consumed then
            local gs = {}
            for _, g in ipairs(gone) do if not settled[g] and eligible(g, m) then gs[#gs + 1] = g end end
            if #gs > 0 then
                local id = tostring(m.itemID or tostring(m.name):lower())
                byItem[id] = byItem[id] or { gs = gs, ms = {} }
                table.insert(byItem[id].ms, m)
            end
        end
    end
    for _, grp in pairs(byItem) do
        local k = grp.ms[1].kind
        local same = true
        for _, m in ipairs(grp.ms) do if m.kind ~= k then same = false end end
        if same and #grp.gs == #grp.ms then settle(grp.gs, grp.ms) end
    end
    for i = #gone, 1, -1 do if settled[gone[i]] then table.remove(gone, i) end end
end

-- /as auctions clear [character]: forget settled history (sold/expired/cancelled mails, "gone" entries, sold total); active listings stay.
function AS.ClearAuctionHistory(text)
    local keys = {}
    if text and text ~= "" then
        local key, why = AS.FindChar(text)
        if not key then Print(why); return end
        keys[1] = key
    else
        for k in pairs(AS.db.chars) do keys[#keys + 1] = k end
    end
    local n = 0
    for _, k in ipairs(keys) do
        local r = AS.db.chars[k]
        n = n + #(r.auctionMail or {}) + #(r.auctionGone or {})
        r.auctionMail, r.auctionGone, r.soldTotal, r.soldSince = nil, nil, nil, nil
    end
    Print(string.format("Cleared %d settled auction record%s (sold / expired / cancelled / gone) for %s. Active listings are kept.", n, n == 1 and "" or "s",
        #keys == 1 and AS.UniqueLabel(keys[1]) or "all characters"))
    if AS.RefreshUI then AS.RefreshUI() end
end

function AS.ListingKey(a)
    if a.auctionID then return "A" .. a.auctionID end
    return string.format("L%d:%d:%d", a.itemID or 0, a.quantity or 0, a.buyoutCopper or 0)
end

-- Name for a listing: stored, else client cache (stored), else "Item <id>" + data request.
function AS.AuctionName(a)
    if a.name then return a.name end
    local n = GetItemInfoCompat(a.itemID)
    if type(n) == "string" and n ~= "" then a.name = n; return n end
    RequestItem(a.itemID)
    return "Item " .. a.itemID
end

local TIME_BANDS = { [0] = "under 30m", [1] = "up to 2h", [2] = "up to 12h", [3] = "up to 48h" }
function AS.TimeBandText(b) return TIME_BANDS[b] or "time left unknown" end

local function FmtDur(secs)
    secs = math.max(0, math.floor(secs))
    local h, m = math.floor(secs / 3600), math.floor(secs / 60) % 60
    if h > 0 then return m > 0 and (h .. "h " .. m .. "m") or (h .. "h") end
    if m > 0 then return m .. "m" end
    return "<1m"
end
AS._FmtDur = FmtDur

-- Time-left text for a saved listing: seconds (with an estimate that accounts for the snapshot age), else the band range,
-- else "time left unknown (first seen X ago)". Never invents an end time.
function AS.TimeLeftText(a, now)
    now = now or time()
    if a.timeLeftSeconds then
        local age = now - (a.timeAt or now)
        if age < 60 then return "~" .. FmtDur(a.timeLeftSeconds) .. " left" end
        local rem = a.timeLeftSeconds - age
        if rem <= 0 then return "should have ended (reported ~" .. FmtDur(a.timeLeftSeconds) .. " left, " .. AS.FormatAge(a.timeAt) .. ")" end
        return "about " .. FmtDur(rem) .. " left (reported ~" .. FmtDur(a.timeLeftSeconds) .. ", " .. AS.FormatAge(a.timeAt) .. ")"
    end
    if a.timeLeftBand then return AS.TimeBandText(a.timeLeftBand) .. (a.timeAt and (now - a.timeAt) >= 60 and (" as of " .. AS.FormatAge(a.timeAt)) or "") end
    return "time left unknown" .. (a.firstSeen and (" (first seen " .. AS.FormatAge(a.firstSeen) .. ")") or "")
end

-- Total price of a listing (commodity listings store a per-unit price).
function AS.ListingValue(a)
    local p = a.buyoutCopper or 0
    if a.commodity then p = p * (a.quantity or 1) end
    return p
end

-- Active listings across all characters: count, buyout value tied up, listings without buyout
function AS.AuctionTotals()
    local value, n, nobuy = 0, 0, 0
    for _, rec in pairs(AS.db.chars) do
        for _, a in ipairs(rec.auctions or {}) do
            if a.status == "active" then
                n = n + 1
                if (a.buyoutCopper or 0) > 0 then value = value + AS.ListingValue(a) else nobuy = nobuy + 1 end
            end
        end
    end
    return value, n, nobuy
end

function AS.AuctionTotalText()
    local value, n, nobuy = AS.AuctionTotals()
    local txt = string.format("%s in %d active listing%s", AS.FormatMoney(value), n, n == 1 and "" or "s")
    if nobuy > 0 then txt = txt .. string.format(" (%d without buyout not counted)", nobuy) end
    return txt
end

-- Lines describing a character's listings (nil when hidden or never seen). `indent` is prepended to each line.
function AS.AuctionLines(rec, indent)
    if not AS.AuctionsEnabled() then return nil end
    local hasList = type(rec.auctions) == "table"
    local mails, gone = rec.auctionMail or {}, rec.auctionGone or {}
    if not hasList and #mails == 0 and #gone == 0 then return nil end
    indent = indent or "   "
    local active, sold = {}, {}
    for _, a in ipairs(rec.auctions or {}) do
        if a.status == "sold" then sold[#sold + 1] = a else active[#active + 1] = a end
    end
    local byName = function(x, y) return AS.AuctionName(x):lower() < AS.AuctionName(y):lower() end
    table.sort(active, byName); table.sort(sold, byName)
    local lines = { string.format("%s|cffffd100Auctions:|r %d active%s%s", indent, #active,
        #sold > 0 and (", " .. #sold .. " pending payout") or "",
        hasList and string.format("  |cff666666(snapshot %s)|r", AS.FormatAge(rec.ahScanned)) or "  |cff666666(AH not opened yet)|r") }
    for _, a in ipairs(active) do
        local price = (a.buyoutCopper or 0) > 0 and (AS.FormatMoney(a.buyoutCopper) .. (a.commodity and " ea" or "")) or "no buyout"
        lines[#lines + 1] = string.format("%s  %s x %d - buyout %s (%s)", indent, AS.AuctionName(a), a.quantity or 1, price, AS.TimeLeftText(a))
    end
    for _, a in ipairs(sold) do
        local p = (a.buyoutCopper or 0) > 0 and AS.ListingValue(a) or (a.bidCopper or 0)
        lines[#lines + 1] = string.format("%s  |cff00ff00Sold (payout pending):|r %s%s - %s", indent, AS.AuctionName(a),
            (a.quantity or 0) > 0 and (" x " .. a.quantity) or "", AS.FormatMoney(p))
    end
    local function qtyText(q) return (q and q > 0) and (" x " .. q) or "" end
    local function newest(list, kinds)
        local out = {}
        for _, m in ipairs(list) do if kinds[m.kind] then out[#out + 1] = m end end
        table.sort(out, function(a, b) return (a.firstSeen or 0) > (b.firstSeen or 0) end)
        return out
    end
    for _, m in ipairs(newest(mails, { sold = true })) do
        lines[#lines + 1] = string.format("%s  |cff00ff00Sold:|r %s%s - %s (%s)", indent, m.name, qtyText(m.quantity),
            (m.money or 0) > 0 and AS.FormatMoney(m.money) or "price unknown", AS.FormatAge(m.firstSeen))
    end
    for _, m in ipairs(newest(mails, { expired = true, removed = true })) do
        lines[#lines + 1] = string.format("%s  |cffffa500Expired/returned:|r %s%s%s (%s)", indent, m.name, qtyText(m.quantity),
            m.kind == "removed" and " [cancelled]" or "", AS.FormatAge(m.firstSeen))
    end
    table.sort(gone, function(a, b) return (a.goneAt or 0) > (b.goneAt or 0) end)
    for _, g in ipairs(gone) do
        lines[#lines + 1] = string.format("%s  |cffaaaaaaGone, status unknown:|r %s%s (%s)", indent, AS.AuctionName(g), qtyText(g.quantity), AS.FormatAge(g.goneAt))
    end
    if (rec.soldTotal or 0) > 0 then
        lines[#lines + 1] = string.format("%s  Sold total since cleared: %s", indent, AS.FormatMoney(rec.soldTotal))
    end
    return lines
end

-- Footer line for the window: "\n<Buyout value ...>" (empty when auctions are hidden)
function AS.SoldTotal()
    local t = 0
    for _, rec in pairs(AS.db.chars) do t = t + (rec.soldTotal or 0) end
    return t
end

function AS.AuctionFooter()
    if not AS.AuctionsEnabled() then return "" end
    local f = "\n|cff33ccffBuyout tied up in auctions (active):|r " .. AS.AuctionTotalText()
    local sold = AS.SoldTotal()
    if sold > 0 then f = f .. "\n|cff33ccffSold since cleared (from mail):|r " .. AS.FormatMoney(sold) end
    return f
end

-- /as debugauctions : raw owned-auction data from every API, so the real Forever behaviour can be checked
function AS.DebugAuctions()
    local function str(v)
        local ok, t = pcall(tostring, v)
        if not ok then return "<secret/unprintable>" end
        if type(v) == "string" then return string.format("%q", t) end
        return t .. " (" .. type(v) .. ")"
    end
    local function dump(label, t, indent, depth)
        indent = indent or "      "; depth = depth or 0
        if type(t) ~= "table" then print(indent .. label .. " = " .. str(t)); return end
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        print(indent .. label .. " = table (" .. #keys .. " keys)")
        for _, k in ipairs(keys) do
            local v = t[k]
            if type(v) == "table" and depth < 3 then dump(tostring(k), v, indent .. "  ", depth + 1)
            else print(indent .. "  " .. tostring(k) .. " = " .. str(v)) end
        end
    end
    local function call(label, fn, ...)
        if type(fn) ~= "function" then print("      " .. label .. ": (not available)"); return end
        local res = { pcall(fn, ...) }
        if not res[1] then print("      " .. label .. ": error: " .. tostring(res[2])); return end
        if res[2] == nil then print("      " .. label .. ": nil"); return end
        for i = 2, #res do dump(label .. (#res > 2 and ("[" .. (i - 1) .. "]") or ""), res[i]) end
    end
    Print("debugauctions (paste this output). AH open (as seen by AltStash): " .. tostring(state.ahOpen))
    local C = C_AuctionHouse
    print("  C_AuctionHouse available: " .. tostring(type(C) == "table"))
    if type(C) == "table" then
        call("GetNumOwnedAuctions()", C.GetNumOwnedAuctions)
        call("HasFullOwnedAuctionResults()", C.HasFullOwnedAuctionResults)
        for b = 0, 3 do call("GetTimeLeftBandInfo(" .. b .. ")", C.GetTimeLeftBandInfo, b) end
        local ok, list = pcall(C.GetOwnedAuctions or function() end)
        if not ok then print("  GetOwnedAuctions error: " .. tostring(list))
        elseif type(list) ~= "table" then print("  GetOwnedAuctions() returned " .. str(list))
        else
            print("  GetOwnedAuctions() returned " .. #list .. " auction(s)")
            for i, a in ipairs(list) do
                print("  --- owned auction #" .. i)
                dump("GetOwnedAuctions()[" .. i .. "] (every key via pairs)", a)
                if type(a) == "table" then
                    local absent = {}
                    for _, k in ipairs({ "auctionID", "itemLink", "timeLeftSeconds", "timeLeft", "bidAmount", "buyoutAmount", "bidder" }) do
                        if a[k] == nil then absent[#absent + 1] = k end
                    end
                    print("      (fields absent/nil on this entry: " .. (#absent > 0 and table.concat(absent, ", ") or "none") .. ")")
                    call("GetAuctionInfoByID(" .. tostring(a.auctionID) .. ")", C.GetAuctionInfoByID, a.auctionID)
                    call("GetOwnedAuctionInfo(" .. i .. ")", C.GetOwnedAuctionInfo, i)
                    local secs, band, src = AS.DeriveTimeLeft(a, i)
                    print(string.format("      AltStash derives: timeLeftSeconds=%s band=%s source=%s", tostring(secs), tostring(band), tostring(src or "NONE (time left unknown)")))
                end
            end
        end
    end
    call('GetNumAuctionItems("owner")', GetNumAuctionItems, "owner")
    if type(GetNumAuctionItems) == "function" then
        local ok, n = pcall(GetNumAuctionItems, "owner")
        for i = 1, (ok and tonumber(n)) or 0 do
            print("  --- legacy owner item #" .. i)
            call('GetAuctionItemTimeLeft("owner", ' .. i .. ")", GetAuctionItemTimeLeft, "owner", i)
            call('GetAuctionItemInfo("owner", ' .. i .. ")", GetAuctionItemInfo, "owner", i)
        end
    else
        print('  GetNumAuctionItems: (not available)')
    end
    local rec = AS.db and AS.db.chars[AS.CurrentKey() or ""]
    if rec and rec.auctions then
        print("  Saved snapshot: " .. #rec.auctions .. " listing(s), scanned " .. AS.FormatAge(rec.ahScanned))
        for i, a in ipairs(rec.auctions) do
            print(string.format("    #%d %s x %s %s: time source=%s secs=%s band=%s firstSeen=%s -> %s", i, AS.AuctionName(a), tostring(a.quantity), a.status,
                tostring(a.timeSource), tostring(a.timeLeftSeconds), tostring(a.timeLeftBand), AS.FormatAge(a.firstSeen), AS.TimeLeftText(a)))
        end
    end
end

function AS.SetAuctions(on)
    AS.db.settings.auctions = on and true or false
    if AS.RefreshUI then AS.RefreshUI() end
    Print("Auction listings display " .. (on and "ON." or "OFF (hidden; saved data is kept)."))
end


------------------------------------------------------------------------
-- Item types. VERIFIED (wiki, Forever 1.60.1): C_Item.GetItemInfoInstant / GetItemInfoInstant (synchronous, no item cache needed:
-- itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subClassID), C_Item.GetItemClassInfo(classID) and
-- C_Item.GetItemSubClassInfo(classID, subClassID) (localized names). Saved per item as optional fields classID / subClassID.
-- Class/subclass numbers are from the wiki's ItemType page (Trade goods = class 7: Parts 1, Jewelcrafting 4, Cloth 5, Leather 6,
-- Metal & Stone 7, Cooking(Meat) 8, Herb 9, Elemental 10, Other 11, Enchanting 12, Materials 13). All labels come from the client.
-- UNVERIFIED: the exact subclass list/names in Forever's client (the menu only offers subclasses whose name the client returns;
-- everything else is reachable via "Other trade goods" / "Other types").
------------------------------------------------------------------------
local ICLASS = Enum and Enum.ItemClass or {}
local C_TRADE = ICLASS.Tradegoods or 7
local TG_SUBS = { 5, 6, 7, 9, 8, 10, 12, 1, 4, 13 }            -- offered trade-goods subclasses (menu order)
local CLASS_MENU = { ICLASS.Gem or 3, ICLASS.Consumable or 0, ICLASS.Weapon or 2, ICLASS.Armor or 4, ICLASS.Container or 1,
    ICLASS.Recipe or 9, ICLASS.Questitem or 12, ICLASS.Miscellaneous or 15, ICLASS.Reagent or 5 }
local FALLBACK_CLASS = { [0] = "Consumable", [1] = "Container", [2] = "Weapon", [3] = "Gem", [4] = "Armor", [5] = "Reagent",
    [7] = "Trade Goods", [9] = "Recipe", [12] = "Quest", [15] = "Miscellaneous" }  -- only used if the client has no GetItemClassInfo at all

local function ClassName(cid)
    local f = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
    if type(f) ~= "function" then return FALLBACK_CLASS[cid] end
    local ok, n = pcall(f, cid)
    if ok and type(n) == "string" and n ~= "" then return n end
end
local function SubClassName(cid, sid)
    local f = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
    if type(f) ~= "function" then return nil end
    local ok, n = pcall(f, cid, sid)
    if ok and type(n) == "string" and n ~= "" then return n end
end

-- classID, subClassID for an item id (synchronous), or nil
function AS.ClassOf(itemID)
    if type(itemID) ~= "number" then return nil end
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(f) ~= "function" then return nil end
    local ok, _, _, _, _, _, cid, sid = pcall(f, itemID)
    if ok and type(cid) == "number" and not IsSecret(cid) then return cid, (type(sid) == "number" and sid or 0) end
end

local typeMemo = {}    -- itemID -> {classID, subClassID} | false (unknown), per session, so unknown ids are not retried
local function ListingType(id)
    local m = typeMemo[id]
    if m == nil then
        local c, sb = AS.ClassOf(id)
        m = c and { c, sb } or false
        typeMemo[id] = m
    end
    if m then return m[1], m[2] end
end

function AS.StoreType(id, it)
    if it.classID then return true end
    local c, sb = ListingType(id)
    if c then it.classID, it.subClassID = c, sb; return true end
    return false
end

-- Fill classID/subClassID for saved items that lack them (no need to visit each alt again). Returns number filled.
function AS.BackfillTypes()
    local n = 0
    if not AS.db then return 0 end
    for _, rec in pairs(AS.db.chars) do
        for id, it in pairs(rec.items or {}) do
            if not it.classID and AS.StoreType(id, it) then n = n + 1 end
        end
    end
    return n
end

local typeOffered
function AS.TypeOffered()
    if typeOffered then return typeOffered end
    local o = { subs = {}, classes = {}, list = { { id = "all", label = "All types", depth = 0 } } }
    local list, seen = o.list, {}
    list[#list + 1] = { id = "c:" .. C_TRADE, label = ClassName(C_TRADE) or "Trade goods", depth = 0 }
    o.classes[C_TRADE] = true
    for _, sid in ipairs(TG_SUBS) do
        local n = SubClassName(C_TRADE, sid)
        if n and not seen[n:lower()] then
            seen[n:lower()] = true
            o.subs[sid] = true
            list[#list + 1] = { id = "s:" .. C_TRADE .. ":" .. sid, label = n, depth = 1 }
        end
    end
    list[#list + 1] = { id = "t:other", label = "Other trade goods", depth = 1 }
    for _, cid in ipairs(CLASS_MENU) do
        local n = ClassName(cid)
        if n and not o.classes[cid] then
            o.classes[cid] = true
            list[#list + 1] = { id = "c:" .. cid, label = n, depth = 0 }
        end
    end
    list[#list + 1] = { id = "t:otherclass", label = "Other types", depth = 0 }
    typeOffered = o
    return o
end
function AS.TypeFilters() return AS.TypeOffered().list end
function AS._ResetTypeCache() typeOffered = nil; typeMemo = {} end

local function ValidFilter(f)
    return type(f) == "string" and (f == "all" or f == "t:other" or f == "t:otherclass" or f:match("^c:%d+$") or f:match("^s:%d+:%d+$")) and true or false
end
function AS.TypeFilter()
    local f = AS.db and AS.db.settings and AS.db.settings.typeFilter
    if ValidFilter(f) then return f end
    return "all"
end
function AS.TypeLabel(f)
    for _, e in ipairs(AS.TypeFilters()) do if e.id == f then return e.label end end
    return "All types"
end

function AS.TypeMatches(filter, cid, sid)
    if filter == "all" then return true end
    local o = AS.TypeOffered()
    if filter == "t:other" then return cid == C_TRADE and not o.subs[sid or -1] end
    if filter == "t:otherclass" then return cid == nil or not o.classes[cid] end
    local c = filter:match("^c:(%d+)$")
    if c then return cid == tonumber(c) end
    local c2, s2 = filter:match("^s:(%d+):(%d+)$")
    if c2 then return cid == tonumber(c2) and sid == tonumber(s2) end
    return true
end

-- type of a saved item entry (fills the optional fields lazily)
function AS.ItemTypeOf(id, it)
    if it and not it.classID then AS.StoreType(id, it) end
    if it and it.classID then return it.classID, it.subClassID end
    return nil
end

function AS.SetTypeFilter(id, silent)
    if not ValidFilter(id) then id = "all" end
    AS.db.settings.typeFilter = id
    if id ~= "all" then pcall(AS.BackfillTypes) end
    if AS.RefreshTypeDropdown then pcall(AS.RefreshTypeDropdown) end
    if AS.RefreshUI then AS.RefreshUI() end
    if not silent then Print("Type filter: " .. AS.TypeLabel(id) .. (id == "all" and "" or "  (/as type all to reset)")) end
end

-- text -> filter id (for /as type <name|all>)
function AS.FindTypeFilter(text)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "no type given" end
    if text == "all" or text == "reset" or text == "none" or text == "all types" then return "all" end
    local list, exact, part = AS.TypeFilters(), {}, {}
    for _, e in ipairs(list) do
        local l = e.label:lower()
        if l == text or e.id == text then exact[#exact + 1] = e.id
        elseif l:find(text, 1, true) then part[#part + 1] = e end
    end
    if #exact == 1 then return exact[1] end
    if #exact == 0 and #part == 1 then return part[1].id end
    local names = {}
    for _, e in ipairs(#exact > 1 and {} or part) do names[#names + 1] = e.label end
    if #names == 0 then
        for _, e in ipairs(list) do names[#names + 1] = e.label end
        return nil, "unknown type '" .. text .. "'. Types: all, " .. table.concat(names, ", ")
    end
    return nil, "'" .. text .. "' is ambiguous: " .. table.concat(names, ", ")
end

------------------------------------------------------------------------
-- Index / search
------------------------------------------------------------------------
function AS.TradeableOnly()
    return not (AS.db and AS.db.settings and AS.db.settings.tradeableOnly == false)
end

-- Counts for display, honouring the "tradeable only" filter (stored raw counts minus untradeable units).
-- Entries without untradeable flags (older data, unknown items) count fully.
function AS.EffectiveCounts(it)
    local bag, bank, mail = it.bag or 0, it.bank or 0, it.mail or 0
    if AS.TradeableOnly() then
        bag = math.max(0, bag - (it.ubag or 0))
        bank = math.max(0, bank - (it.ubank or 0))
        mail = math.max(0, mail - (it.umail or 0))
    end
    return bag, bank, mail
end

local function BuildIndex()
    local idx = {}
    for key, rec in pairs(AS.db.chars) do
        for id, it in pairs(rec.items) do
            local bag, bank, mail = AS.EffectiveCounts(it)
            if bag + bank + mail > 0 then
                local l = idx[id]; if not l then l = {}; idx[id] = l end
                l[#l + 1] = { key = key, rec = rec, bag = bag, bank = bank, mail = mail }
            end
        end
    end
    AS.index = idx
    return idx
end

-- itemID -> list of { key, rec, bag, bank, mail }  (all characters)
function AS.Holders(itemID)
    local idx = AS.index or BuildIndex()
    return idx[itemID] or {}
end

-- Name for an item id: stored name, else the client's cache (then stored), else nil + a data-load request.
function AS.ItemName(id, it)
    if it and it.name then return it.name end
    local n = GetItemInfoCompat(id)
    if type(n) == "string" and n ~= "" then
        if it then it.name = n end
        return n
    end
    RequestItem(id)
    return nil
end

-- Display name: real name, or "Item <id>" until the client has the data.
function AS.DisplayName(id, it) return AS.ItemName(id, it) or ("Item " .. id) end

-- Item link built on demand from the item id (nil if the client hasn't cached the item yet).
function AS.ItemLink(id)
    local _, link = GetItemInfoCompat(id)
    if type(link) == "string" then return link end
    return nil
end

-- Called when the client delivers item data: fill stored names for that id.
function AS.OnItemInfo(id)
    if type(id) ~= "number" then return false end
    local n = GetItemInfoCompat(id)
    if type(n) ~= "string" or n == "" then return false end
    local changed = false
    for _, rec in pairs(AS.db.chars) do
        local it = rec.items[id]
        if it and it.name ~= n then it.name = n; changed = true end
    end
    for _, rec in pairs(AS.db.chars) do
        for _, a in ipairs(rec.auctions or {}) do
            if a.itemID == id and a.name ~= n then a.name = n; changed = true end
        end
    end
    if changed then Dirty() end
    return changed
end

-- Ask the client for names of items we stored without one (current character's items, after scans).
function AS.ResolveNames()
    for _, rec in pairs(AS.db.chars) do
        for id, it in pairs(rec.items) do
            if not it.name then AS.ItemName(id, it) end
        end
    end
end

local function SortedKeys()
    local keys = {}
    for k in pairs(AS.db.chars) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local la, lb = AS.CharLabel(AS.db.chars[a]):lower(), AS.CharLabel(AS.db.chars[b]):lower()
        if la ~= lb then return la < lb end
        return a < b
    end)
    return keys
end
AS.SortedKeys = SortedKeys

-- Returns list of { key, rec, entries = { {id, link, name, bag, bank, mail, total}, ... } }, case-insensitive
-- substring match on item name (or exact item id when the text is all digits). Characters with no match are omitted.
function AS.Search(text)
    local out = {}
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local filt = AS.TypeFilter()
    local blank = text == ""
    if blank and filt == "all" then return out end
    if filt ~= "all" then pcall(AS.BackfillTypes) end
    local wantId = text:match("^%d+$") and tonumber(text)
    local aucOn = AS.AuctionsEnabled()
    for _, key in ipairs(SortedKeys()) do
        local rec = AS.db.chars[key]
        local entries, byId = {}, {}
        for id, it in pairs(rec.items) do
            local bag, bank, mail = AS.EffectiveCounts(it)
            if bag + bank + mail > 0 then
                local cid, sid = AS.ItemTypeOf(id, it)
                if AS.TypeMatches(filt, cid, sid) then
                    local name = AS.DisplayName(id, it)
                    if blank or (wantId and id == wantId) or name:lower():find(text, 1, true) then
                        local e = { id = id, link = AS.ItemLink(id), name = name, bag = bag, bank = bank, mail = mail, auction = 0, total = bag + bank + mail }
                        entries[#entries + 1] = e; byId[id] = e
                    end
                end
            end
        end
        if aucOn then -- active listings are a location too ("auction"); not touched by the tradeable filter
            for _, a in ipairs(rec.auctions or {}) do
                if a.status == "active" then
                    local name = AS.AuctionName(a)
                    local lc, ls = ListingType(a.itemID)
                    if AS.TypeMatches(filt, lc, ls) and (blank or (wantId and a.itemID == wantId) or name:lower():find(text, 1, true)) then
                        local e = byId[a.itemID]
                        if not e then
                            e = { id = a.itemID, link = AS.ItemLink(a.itemID), name = name, bag = 0, bank = 0, mail = 0, auction = 0, total = 0 }
                            entries[#entries + 1] = e; byId[a.itemID] = e
                        end
                        e.auction = e.auction + (a.quantity or 1); e.total = e.total + (a.quantity or 1)
                    end
                end
            end
        end
        if #entries > 0 then
            table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
            out[#out + 1] = { key = key, rec = rec, entries = entries }
        end
    end
    return out
end

function AS.SetTradeable(on, silent)
    AS.db.settings.tradeableOnly = on and true or false
    Dirty()
    -- refresh flags for the current character (old data has none); alts update on their next visit
    local q = AS._Queue
    if q then
        q("bag"); if state.bankOpen then q("bank") end; if state.mailOpen then q("mail") end
        q("ui")
    end
    if AS.RefreshUI then AS.RefreshUI() end
    if not silent then
        Print("Tradeable-only filter " .. (on and "ON: hiding soulbound / untradeable items." or "OFF: showing everything.") ..
            " Applies immediately. This character is being re-scanned; alts get their tradeable flags on their next visit.")
    end
end

-- "12g 3s 4c" style text; uses the client's coin-texture string when available.
function AS.FormatMoney(copper)
    if type(copper) ~= "number" then return "gold unknown" end
    if GetCoinTextureString then
        local ok, txt = pcall(GetCoinTextureString, copper)
        if ok and type(txt) == "string" and txt ~= "" then return txt end
    end
    local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if g > 0 or sv > 0 then parts[#parts + 1] = sv .. "s" end
    parts[#parts + 1] = c .. "c"
    return table.concat(parts, " ")
end

-- Sum over all saved characters. Returns total copper, number of characters with known gold, number unknown.
function AS.TotalMoney()
    local total, known, unknown = 0, 0, 0
    for _, rec in pairs(AS.db.chars) do
        if type(rec.money) == "number" then total = total + rec.money; known = known + 1 else unknown = unknown + 1 end
    end
    return total, known, unknown
end

function AS.TotalMoneyText()
    local total, known, unknown = AS.TotalMoney()
    local txt = AS.FormatMoney(total)
    if unknown > 0 then txt = txt .. string.format(" (%d character%s gold unknown)", unknown, unknown == 1 and "" or "s") end
    return txt
end

function AS.FormatAge(ts)
    if not ts then return "never" end
    local d = time() - ts
    if d < 0 then d = 0 end
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

-- Case-insensitive character lookup. Accepts the full display name, either part of the name (first / second),
-- Name-Realm, the full key (GUID) or the [GUID suffix] shown in lists. Returns key, or nil + reason (ambiguous
-- input returns the list of matches in the reason, each with its GUID suffix).
function AS.FindChar(text)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("^%[(.*)%]$", "%1"):gsub("^#", "")
    if text == "" then return nil, "no character given" end
    local matches = {}
    for key, rec in pairs(AS.db.chars) do
        local terms = {}
        local function add(t) if t and t ~= "" then terms[tostring(t):lower()] = true end end
        add(key); add(rec.name); add(rec.firstName); add(rec.secondName); add(rec.displayName)
        if rec.realm then
            add((rec.name or "") .. "-" .. rec.realm); add((rec.displayName or "") .. "-" .. rec.realm)
        end
        if rec.firstName and rec.secondName then add(rec.firstName .. " " .. rec.secondName) end
        local suffix = AS.KeySuffix(key):lower()
        if #suffix >= 4 then add(suffix) end
        if terms[text] then matches[#matches + 1] = key end
    end
    if #matches == 0 then return nil, "no saved character matches '" .. text .. "'" end
    if #matches > 1 then
        table.sort(matches)
        local parts = {}
        for _, k in ipairs(matches) do
            local r = AS.db.chars[k]
            parts[#parts + 1] = string.format("%s (%s, %s) [%s]", AS.CharLabel(r), r.class or "?", r.realm or "?", AS.KeySuffix(k))
        end
        return nil, "'" .. text .. "' matches " .. #matches .. " characters - nothing removed. Use the full name or the [suffix]: " .. table.concat(parts, "; ")
    end
    return matches[1]
end

function AS.ResetChar(text)
    local key, why = AS.FindChar(text)
    if not key then Print(why); return end
    local label = AS.UniqueLabel(key)
    AS.db.chars[key] = nil
    Dirty()
    Print("Removed saved data for " .. label .. ". (It is re-created if you play that character again.)")
    if AS.RefreshUI then AS.RefreshUI() end
end

------------------------------------------------------------------------
-- Events (debounced)
------------------------------------------------------------------------
local pending = { bag = false, bank = false, mail = false, ui = false, money = false, ah = false, quest = false }
local ahAcceptEmpty = false
local timer = 0
local f = CreateFrame("Frame")
AS.eventFrame = f

local function Queue(what) pending[what] = true; timer = DEBOUNCE; f:Show() end
AS._Queue = Queue

local function Flush()
    if not AS.db then return end
    local did = false
    if pending.money then pending.money = false; pcall(AS.ScanMoney); did = true end
    if pending.ah then pending.ah = false; local ae = ahAcceptEmpty; ahAcceptEmpty = false; pcall(AS.ScanAuctions, ae); did = true end
    if pending.bag then pending.bag = false; pcall(AS.ScanBags); did = true end
    if pending.bank then pending.bank = false; pcall(AS.ScanBank); did = true end
    if pending.mail then pending.mail = false; pcall(AS.ScanMail); did = true end
    if pending.quest then pending.quest = false; if AS.ScanQuests then pcall(AS.ScanQuests) end; did = true end   -- 0.3.8
    if did then pcall(AS.ResolveNames) end
    if pending.ui then pending.ui = false; did = true end
    if did and AS.RefreshUI then AS.RefreshUI() end
end
AS._Flush = Flush

f:SetScript("OnUpdate", function(self, elapsed)
    timer = timer - elapsed
    if timer <= 0 then
        Flush()
        if not (pending.bag or pending.bank or pending.mail or pending.ui) then self:Hide() end
    end
end)

for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "GET_ITEM_INFO_RECEIVED", "PLAYER_MONEY",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do f:RegisterEvent(ev) end
pcall(f.RegisterEvent, f, "PLAYER_LEVEL_UP")              -- 0.3.0: keep the saved level (tab badge / tooltip) current
-- not present on every client / may be renamed: registering is wrapped
pcall(f.RegisterEvent, f, "OWNED_AUCTIONS_UPDATED")      -- modern owned-auction list updated
pcall(f.RegisterEvent, f, "AUCTION_OWNED_LIST_UPDATE")   -- legacy equivalent
pcall(f.RegisterEvent, f, "PLAYERBANKSLOTS_CHANGED")
pcall(f.RegisterEvent, f, "PLAYERBANKBAGSLOTS_CHANGED")
-- 0.3.8: quest log (objective items for the Items view usage tags); each is optional on this client
for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "UNIT_QUEST_LOG_CHANGED",
    "QUEST_LOOT_RECEIVED", "CHAT_MSG_LOOT" }) do pcall(f.RegisterEvent, f, ev) end   -- 0.3.9: turn-in rewards

f:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        AltStashDB = AltStashDB or {}
        AS.db = AltStashDB
        if not Migrate(AS.db) then
            Print("Saved data is from a newer AltStash (schema " .. tostring(AS.db.schemaVersion) .. "); running read-only without saving scans.")
            AS.db = { schemaVersion = AS.SCHEMA, chars = {} } -- throwaway so nothing newer gets overwritten
        end
        if AS.InitUI then AS.InitUI() end
        if AS.InitTooltip then AS.InitTooltip() end
    elseif event == "PLAYER_LOGIN" then
        pcall(AS.RefreshCurrentNames)
        pcall(AS.BackfillTypes)   -- types for already-saved items (alts need no revisit)
        Queue("money"); Queue("bag"); Queue("quest")
        Print("loaded. /as for the search window, /as help for commands.")
    elseif event == "AUCTION_HOUSE_SHOW" then
        state.ahOpen = true; Queue("ah")   -- debounced passive read; an empty result is not trusted yet
    elseif event == "AUCTION_HOUSE_CLOSED" then
        state.ahOpen = false
    elseif event == "OWNED_AUCTIONS_UPDATED" or event == "AUCTION_OWNED_LIST_UPDATE" then
        if state.ahOpen then ahAcceptEmpty = true; Queue("ah") end
    elseif event == "PLAYER_MONEY" then
        Queue("money")
    elseif event == "PLAYER_LEVEL_UP" then
        if AS.db then
            local key = AS.CurrentKey()
            local rec = key and AS.db.chars[key]
            if rec then pcall(AS.StoreIdentity, rec, tonumber(a1)) end
        end
        Queue("ui")
    elseif event == "BAG_UPDATE_DELAYED" then
        Queue("bag"); if state.bankOpen then Queue("bank") end
    elseif event == "BANKFRAME_OPENED" then
        state.bankOpen = true; Queue("bank"); Queue("bag")
    elseif event == "BANKFRAME_CLOSED" then
        state.bankOpen = false
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED" then
        if state.bankOpen then Queue("bank") end
    elseif event == "MAIL_SHOW" then
        state.mailOpen = true
        Queue("mail") -- always; an empty mailbox clears stale mail counts
    elseif event == "MAIL_INBOX_UPDATE" then
        if state.mailOpen then Queue("mail") end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if AS.db and AS.OnItemInfo(a1) then Queue("ui") end
    elseif event == "MAIL_CLOSED" then
        state.mailOpen = false
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_TURNED_IN" then
        if event == "QUEST_TURNED_IN" and AS.OnQuestTurnedIn then pcall(AS.OnQuestTurnedIn, a1) end
        if event == "QUEST_TURNED_IN" and AS.OnQuestTurnedInLoot then pcall(AS.OnQuestTurnedInLoot, event, a1) end
        Queue("quest")
    elseif event == "QUEST_LOOT_RECEIVED" or event == "CHAT_MSG_LOOT" then
        if AS.OnQuestTurnedInLoot then pcall(AS.OnQuestTurnedInLoot, event, a1, a2) end
    elseif event == "UNIT_QUEST_LOG_CHANGED" then
        if a1 == "player" then Queue("quest") end
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
local function Help()
    Print("commands:")
    print("  /as  or  /altstash        - toggle the AltStash window")
    print("  /as show | hide")
    print("  /as search <text>         - open the window filtered by item name")
    print("  /as tradeable on|off      - hide soulbound/untradeable items (currently " .. (AS.TradeableOnly() and "ON" or "OFF") .. ")")
    print("  /as auctions on|off       - show/hide your saved auction listings (currently " .. (AS.AuctionsEnabled() and "ON" or "OFF") .. "; updates when the AH is opened)")
    print("  /as auctions clear [char] - forget settled auction history (sold / expired / gone) and the sold total; active listings stay")
    print("  /as type <name|all>       - filter by item type (e.g. cloth, herb, gem, armor); currently: " .. AS.TypeLabel(AS.TypeFilter()))
    print("  /as char <name>  |  all   - open the window on that character's tab (or the All characters tab)")
    print("  /as list                  - saved characters and when each was last scanned")
    print("  /as prices on|off         - craft-or-sell advice from Auctionator prices in Craftables (needs Auctionator + an AH scan)")
    print("  /as usage on|off          - Quest / Crafting / Safe to sell tags in the Items view")
    print("  /as keep <item>           - never show an item as safe to sell / delete (no item: list)")
    print("  /as unkeep <item|all>     - remove an item from the keep list")
    print("  /as questinfo <item>      - quest IDs, completion and the reason behind an item's verdict")
    print("  /as deposit 2|8|24        - auction duration used for deposit estimates (now " .. (AS.Prices and AS.Prices.Hours() or 24) .. "h)")
    print("  /as mindeposit <copper>   - minimum deposit per auction (now " .. AS.FormatMoney(AS.Prices and AS.Prices.MinDeposit() or 100) .. ")")
    print("  /as sort profit|default   - Craftables order")
    print("  /as reset <character>     - forget one character (full name, first or second name, Name-Realm or [suffix]; asks you to be specific if ambiguous)")
    print("  /as debugauctions         - print raw owned-auction API values (open the AH first; paste if time left is unknown)")
    print("  /as debugname             - print raw name API values (for checking first/second name support)")
    print("  /as help")
end

function AS.ListChars()
    local keys = SortedKeys()
    if #keys == 0 then Print("No characters saved yet."); return end
    for _, k in ipairs(keys) do
        local r = AS.db.chars[k]
        local n = 0
        for _, it in pairs(r.items) do local a, b, c = AS.EffectiveCounts(it); if a + b + c > 0 then n = n + 1 end end
        print(string.format("  %s - %s (%s): %s%s - %d items - bags %s, bank %s, mail %s%s", AS.UniqueLabel(k), r.realm or "?", r.class or "?",
            AS.FormatMoney(r.money), r.goldUpdated and (" (" .. AS.FormatAge(r.goldUpdated) .. ")") or "", n,
            AS.FormatAge(r.scanned.bag), AS.FormatAge(r.scanned.bank), AS.FormatAge(r.scanned.mail),
            r.guid and "" or "  |cff999999(old entry: re-keys when that character next logs in)|r"))
        for _, line in ipairs(AS.AuctionLines(r, "      ") or {}) do print(line) end
    end
    print("  Total gold, all characters: " .. AS.TotalMoneyText())
    if AS.AuctionsEnabled() then
        print("  Buyout value tied up in auctions (active only): " .. AS.AuctionTotalText())
        local sold = AS.SoldTotal()
        if sold > 0 then print("  Sold since cleared (from auction mail): " .. AS.FormatMoney(sold) .. "  (/as auctions clear to reset)") end
    end
end

-- /as debugname : raw name values so the real Forever behaviour can be confirmed
function AS.DebugName()
    local function show(label, ...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = string.format("%q", tostring((select(i, ...)))) end
        print(string.format("  %-34s %s", label, #parts > 0 and table.concat(parts, ", ") or "(nothing)"))
    end
    local function try(label, fn, ...)
        if type(fn) ~= "function" then print(string.format("  %-34s (not available)", label)); return end
        local res = { pcall(fn, ...) }
        if not res[1] then print(string.format("  %-34s error: %s", label, tostring(res[2]))); return end
        show(label, unpack(res, 2))
    end
    Print("debugname (paste this output):")
    try('UnitName("player")', UnitName, "player")
    try('UnitFullName("player")', UnitFullName, "player")
    try('UnitNameUnmodified("player")', UnitNameUnmodified, "player")
    try('GetUnitName("player", true)', GetUnitName, "player", true)
    try('GetUnitName("player", false)', GetUnitName, "player", false)
    try('UnitGUID("player")', UnitGUID, "player")
    try("GetRealmName()", GetRealmName)
    try("GetNormalizedRealmName()", GetNormalizedRealmName)
    try('GetCVar("UnitSurnameOwn")', GetCVar, "UnitSurnameOwn")
    if type(C_NameUtil) == "table" then
        local names = {}
        for k, v in pairs(C_NameUtil) do if type(v) == "function" then names[#names + 1] = k end end
        table.sort(names)
        print("  C_NameUtil functions: " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
        local raw = UnitName and UnitName("player")
        for _, k in ipairs(names) do
            if k:find("^Get") then try("C_NameUtil." .. k .. '("player")', C_NameUtil[k], "player") end
        end
        if raw and C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator then
            try("C_NameUtil.ReplaceSurnameSeparator...", C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator, raw)
        end
    else
        print("  C_NameUtil: (not available)")
    end
    local raw = UnitName and UnitName("player")
    if type(raw) == "string" then
        local bytes = {}
        for i = 1, #raw do local b = raw:byte(i); if b > 127 or not raw:sub(i, i):match("%w") then bytes[#bytes + 1] = i .. ":" .. string.format("0x%02X", b) end end
        print("  non-alphanumeric/UTF-8 bytes in UnitName: " .. (#bytes > 0 and table.concat(bytes, " ") or "(none)"))
    end
    local nm = AS.ComputeNames()
    if nm then
        print(string.format("  AltStash computes: first=%q second=%q display=%q realm=%q", tostring(nm.firstName), tostring(nm.secondName), tostring(nm.displayName), tostring(GetRealmName and GetRealmName())))
        print("  (second name = 2nd return of UnitName; the realm is NOT taken from UnitName)")
    end
end

SLASH_ALTSTASH1 = "/altstash"
SLASH_ALTSTASH2 = "/as"
SlashCmdList["ALTSTASH"] = function(msg)
    if not AS.db then return end
    msg = msg or ""
    local cmd, arg = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "toggle" then AS.SetShown(not AS.IsShown())
    elseif cmd == "show" then AS.SetShown(true)
    elseif cmd == "hide" then AS.SetShown(false)
    elseif cmd == "search" or cmd == "find" then AS.SetShown(true); AS.SetSearch(arg)
    elseif cmd == "tradeable" then
        local a = arg:lower()
        if a == "on" or a == "1" then AS.SetTradeable(true)
        elseif a == "off" or a == "0" then AS.SetTradeable(false)
        else Print("Tradeable-only filter is " .. (AS.TradeableOnly() and "ON" or "OFF") .. ". Use /as tradeable on|off.") end
    elseif cmd == "auctions" then
        local a = arg:lower()
        local sub, subarg = arg:match("^(%S+)%s*(.-)$")
        if sub and sub:lower() == "clear" then AS.ClearAuctionHistory(subarg)
        elseif a == "on" or a == "1" then AS.SetAuctions(true)
        elseif a == "off" or a == "0" then AS.SetAuctions(false)
        else Print("Auction listings display is " .. (AS.AuctionsEnabled() and "ON" or "OFF") .. ". Use /as auctions on|off.") end
    elseif cmd == "type" or cmd == "filter" then
        if arg == "" then
            Print("Type filter: " .. AS.TypeLabel(AS.TypeFilter()) .. ". Use /as type <name|all>. Types: all, " ..
                (function() local t = {} for _, e in ipairs(AS.TypeFilters()) do if e.id ~= "all" then t[#t + 1] = e.label end end return table.concat(t, ", ") end)())
        else
            local id, why = AS.FindTypeFilter(arg)
            if id then AS.SetTypeFilter(id); AS.SetShown(true) else Print(why) end
        end
    elseif cmd == "char" or cmd == "tab" then
        if arg == "" or arg:lower() == "all" then AS.SetShown(true); if AS.SelectTab then AS.SelectTab("all") end
        else
            local key, why = AS.FindChar(arg)
            if key then AS.SetShown(true); if AS.SelectTab then AS.SelectTab(key) end else Print(why) end
        end
    elseif cmd == "prices" then
        local a = arg:lower()
        if a == "on" or a == "1" then AS.db.settings.prices = nil elseif a == "off" or a == "0" then AS.db.settings.prices = false end
        local P = AS.Prices
        Print("Craft-or-sell advice is " .. ((P and P.Enabled()) and "ON" or "OFF") .. ((P and P.API()) and " (Auctionator found)" or " (Auctionator not loaded)") ..
            ". Deposit: " .. (P and P.Hours() or 24) .. "h, minimum " .. AS.FormatMoney(P and P.MinDeposit() or 100) .. " per auction. Use /as prices on|off, /as deposit 2|8|24, /as mindeposit <copper>.")
        if AS.RefreshUI then AS.RefreshUI() end
    elseif cmd == "usage" then
        local a = arg:lower()
        if a == "on" or a == "1" then AS.db.settings.usage = nil elseif a == "off" or a == "0" then AS.db.settings.usage = false end
        Print("Item usage tags (Quest / Crafting / Safe to sell) are " .. ((AS.Usage and AS.Usage.Enabled()) and "ON" or "OFF") .. ". Use /as usage on|off.")
        if AS.RefreshUI then AS.RefreshUI() end
    elseif cmd == "deposit" then
        local h = tonumber(arg)
        if h and AS.Prices and AS.Prices.DEPOSIT_RATE[h] then AS.db.settings.ahHours = h; Print("AH deposit estimated for " .. h .. "h auctions (" .. math.floor(AS.Prices.DEPOSIT_RATE[h] * 100 + 0.5) .. "% of vendor price).")
        else Print("Use /as deposit 2|8|24 (12|48 on modern auction houses). Now: " .. (AS.Prices and AS.Prices.Hours() or 24) .. "h.") end
        if AS.RefreshUI then AS.RefreshUI() end
    elseif cmd == "mindeposit" then
        local c = tonumber(arg)
        if c and c >= 0 then AS.db.settings.ahMinDeposit = math.floor(c); Print("Minimum deposit per auction: " .. AS.FormatMoney(math.floor(c)) .. ".")
        else Print("Use /as mindeposit <copper> (100 = 1 silver, 1 = 1 copper). Now: " .. AS.FormatMoney(AS.Prices and AS.Prices.MinDeposit() or 100) .. ".") end
        if AS.RefreshUI then AS.RefreshUI() end
    elseif cmd == "sort" then
        local a = arg:lower()
        if a == "profit" then AS.db.settings.craftSort = "profit" elseif a == "default" or a == "off" then AS.db.settings.craftSort = nil end
        Print("Craftables sort: " .. (AS.db.settings.craftSort == "profit" and "profit" or "default") .. ". Use /as sort profit|default.")
        if AS.RefreshUI then AS.RefreshUI() end
    elseif cmd == "keep" or cmd == "unkeep" then
        local U = AS.Usage
        if not U then return end
        if cmd == "unkeep" and arg:lower() == "all" then AS.db.keep = nil; Print("Keep list cleared."); if AS.RefreshUI then AS.RefreshUI() end; return end
        local id = U.ParseItemArg(arg)
        if not id then
            local ids = {}
            for k in pairs(U.KeepList()) do ids[#ids + 1] = k end
            table.sort(ids)
            local names = {}
            for i, k in ipairs(ids) do if i > 20 then names[#names + 1] = "..."; break end names[#names + 1] = ((AS.ItemName and AS.ItemName(k, nil)) or "item") .. " (" .. k .. ")" end
            Print("Keep list: " .. (#ids > 0 and table.concat(names, ", ") or "(empty)") .. ". Use /as keep <item link or ID>, /as unkeep <item link or ID|all>.")
            return
        end
        U.SetKept(id, cmd == "keep")
        Print(((AS.ItemName and AS.ItemName(id, nil)) or ("item " .. id)) .. (cmd == "keep" and " is on your keep list: never shown as safe to sell / delete." or " removed from your keep list."))
        if AS.RefreshUI then AS.RefreshUI() end
    elseif cmd == "questinfo" or cmd == "qi" then
        if AS.Usage and AS.Usage.QuestInfoLines then for _, l in ipairs(AS.Usage.QuestInfoLines(arg)) do Print(l) end end
    elseif cmd == "list" then AS.ListChars()
    elseif cmd == "reset" then AS.ResetChar(arg)
    elseif cmd == "debugname" then AS.DebugName()
    elseif cmd == "debugauctions" then AS.DebugAuctions()
    else Help() end
end
