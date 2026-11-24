-- AltStash: small read-only public API for other add-ons (e.g. ProfTracker).  Backward compatible: adds nothing to the saved data.
-- Access:  local API = _G.AltStash and _G.AltStash.API ; check API.apiVersion >= 1.
-- Every function is passive (reads the saved data) and returns plain tables (copies), so callers can't corrupt the saved data.
local ADDON, AS = ...

local API = { apiVersion = 1, minorVersion = 1, version = AS.version }   -- minorVersion 1: honorTradeableFilter may be "always"
AS.API = API

local function chars() return (AS.db and AS.db.chars) or {} end

-- honor: false/nil = raw counts; true = apply the user's "tradeable only" setting; "always" (minorVersion >= 1) = always hide
-- soulbound/untradeable units, whatever the setting is.
local function Counts(it, honor)
    if honor == "always" then
        return math.max(0, (it.bag or 0) - (it.ubag or 0)), math.max(0, (it.bank or 0) - (it.ubank or 0)), math.max(0, (it.mail or 0) - (it.umail or 0))
    end
    if honor and AS.EffectiveCounts then return AS.EffectiveCounts(it) end   -- applies the user's "tradeable only" setting
    return it.bag or 0, it.bank or 0, it.mail or 0
end

local function Info(key, rec)
    return {
        key = key, name = rec.name, displayName = AS.CharLabel(rec), realm = rec.realm,
        class = rec.class, classFile = rec.classFile, guid = (type(key) == "string" and key:match("^Player%-")) and key or nil,
        uniqueLabel = AS.UniqueLabel and AS.UniqueLabel(key) or AS.CharLabel(rec),
        scanned = { bag = rec.scanned and rec.scanned.bag, bank = rec.scanned and rec.scanned.bank, mail = rec.scanned and rec.scanned.mail },
    }
end

-- list of { key, guid, name, displayName, uniqueLabel, realm, class, classFile, scanned = {bag,bank,mail} }, sorted by name
function API.GetCharacters()
    local out = {}
    if not AS.db then return out end
    for _, key in ipairs(AS.SortedKeys()) do out[#out + 1] = Info(key, chars()[key]) end
    return out
end

-- key of the logged-in character (GUID, or the legacy key until it has been migrated), or nil
function API.GetCurrentKey() return AS.CurrentKey and AS.CurrentKey() or nil end

-- list of { key, name, displayName, uniqueLabel, realm, classFile, bag, bank, mail, total } for every character holding the item.
-- honorTradeableFilter (default false): true = the user's "tradeable only" setting hides soulbound units, as in the search window;
-- "always" = hide them regardless of the setting.
function API.GetCharacterCounts(itemID, honorTradeableFilter)
    local out = {}
    itemID = tonumber(itemID)
    if not itemID or not AS.db then return out end
    for _, key in ipairs(AS.SortedKeys()) do
        local rec = chars()[key]
        local it = rec.items and rec.items[itemID]
        if it then
            local bag, bank, mail = Counts(it, honorTradeableFilter)
            if bag + bank + mail > 0 then
                local e = Info(key, rec)
                e.bag, e.bank, e.mail, e.total = bag, bank, mail, bag + bank + mail
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- total, bag, bank, mail across all characters (same honorTradeableFilter meaning as above)
function API.GetTotalCount(itemID, honorTradeableFilter)
    local t, b, k, m = 0, 0, 0, 0
    for _, e in ipairs(API.GetCharacterCounts(itemID, honorTradeableFilter)) do
        t, b, k, m = t + e.total, b + e.bag, k + e.bank, m + e.mail
    end
    return t, b, k, m
end

-- count of one item on one character (key from GetCharacters/GetCharacterCounts): bag, bank, mail
function API.GetItemCount(key, itemID, honorTradeableFilter)
    local rec = chars()[key]
    local it = rec and rec.items and rec.items[tonumber(itemID) or -1]
    if not it then return 0, 0, 0 end
    return Counts(it, honorTradeableFilter)
end
