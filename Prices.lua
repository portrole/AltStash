-- AltStash 0.3.5: craft-or-sell advice from Auctionator's scanned prices.
-- Uses ONLY Auctionator's public API (Auctionator.API.v1.*), every call feature-detected and pcall-wrapped; Auctionator is
-- optional (## OptionalDeps). Never reads Auctionator's saved variables. All money values are copper.
--
-- Logic (same comparison whether you already own the materials or not):
--   sell mats  = what the reagents would net on the AH: AH price x qty - 5% cut - deposit
--                (reagents with no AH price but a known vendor price, e.g. vials: their vendor cost, no cut / deposit)
--   craft      = what the crafted items net: AH price x yield - 5% cut - deposit
--   profit     = craft - sell mats.   "Craft & sell" when profit >= max(1s, 5% of sell mats); "Sell mats" when profit is
--                that far below zero; otherwise "Even". "No data" when the crafted item or a reagent has no price.
--   Deposits are counted on both sides as money at risk (refunded when the auction sells, lost if it expires / is cancelled).
--   Deposit per auction = max(minimum deposit, rate x vendor sell price x stack) for a full stack of the item, shared per item.
local ADDON, AS = ...
local P = {}
AS.Prices = P

P.CALLER = "AltStash"
P.CUT = 0.05                 -- faction AH cut
P.MIN_PROFIT = 100           -- 1 silver
P.MIN_PCT = 0.05             -- 5% of the materials' value
P.STALE_DAYS = 3
-- deposit rate of vendor sell price per duration (hours). WoW: Forever / Classic: 2h 5%, 8h 20%, 24h 60%.
-- 12h / 48h are the modern durations (15% / 60%), accepted in case the client offers them.
P.DEPOSIT_RATE = { [2] = 0.05, [8] = 0.20, [24] = 0.60, [12] = 0.15, [48] = 0.60 }
P.DEFAULT_HOURS = 24
P.DEFAULT_MIN_DEPOSIT = 100  -- Forever launched with a 1 silver minimum deposit per auction (announced to go back to 1c)

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end
local function Num(v) if type(v) == "number" and not IsSecret(v) and v == v then return v end end

function P.API()
    local A = type(Auctionator) == "table" and Auctionator.API
    local v1 = type(A) == "table" and A.v1
    if type(v1) == "table" and type(v1.GetAuctionPriceByItemID) == "function" then return v1 end
    return nil
end

function P.Enabled()
    return not (AS.db and AS.db.settings and AS.db.settings.prices == false)
end

local function Settings() return (AS.db and AS.db.settings) or {} end
function P.Hours()
    local h = tonumber(Settings().ahHours)
    return (h and P.DEPOSIT_RATE[h]) and h or P.DEFAULT_HOURS
end
function P.MinDeposit()
    local m = tonumber(Settings().ahMinDeposit)
    return (m and m >= 0) and math.floor(m) or P.DEFAULT_MIN_DEPOSIT
end

local memo = {}
function P.ResetMemo() memo = {} end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, P.CALLER, ...)
    if ok then return a end
end

-- AH price (copper per item), age in days (nil = unknown / older than Auctionator keeps), exact flag
function P.AHPrice(id)
    if type(id) ~= "number" then return nil end
    local m = memo["ah" .. id]
    if m then return m[1], m[2] end
    local v1 = P.API()
    local price, age
    if v1 then
        price = Num(Call(v1.GetAuctionPriceByItemID, id))
        if price and price <= 0 then price = nil end
        age = Num(Call(v1.GetAuctionAgeByItemID, id))
    end
    memo["ah" .. id] = { price, age }
    return price, age
end

-- price to BUY from a vendor (Auctionator records it when you visit a vendor)
function P.VendorBuy(id)
    if type(id) ~= "number" then return nil end
    local m = memo["vb" .. id]
    if m then return m[1] end
    local v1 = P.API()
    local v = v1 and Num(Call(v1.GetVendorPriceByItemID, id)) or nil
    if v and v <= 0 then v = nil end
    memo["vb" .. id] = { v }
    return v
end

-- vendor SELL price and max stack from item info (nil while the item isn't cached)
function P.ItemSellInfo(id)
    if type(id) ~= "number" then return nil end
    local m = memo["si" .. id]
    if m then return m[1], m[2] end
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local sell, stack
    if type(fn) == "function" then
        local ok, name, _, _, _, _, _, _, st, _, _, sp = pcall(fn, id)
        if ok and name then sell, stack = Num(sp), Num(st) end
    end
    memo["si" .. id] = { sell, stack }
    return sell, stack
end

-- Client deposit API (modern AH, commodities by item id). Classic CalculateAuctionDeposit only works for the item placed in
-- the auction sell slot, so it can't price arbitrary items; the formula below is used instead.
local DUR_INDEX = { [2] = 1, [8] = 2, [24] = 3, [12] = 1, [48] = 3 }
P._depCache = {}
local function ClientDeposit(id, hours, qty)
    local A = C_AuctionHouse
    if type(A) ~= "table" or type(A.CalculateCommodityDeposit) ~= "function" then return nil end
    local key = id .. ":" .. hours .. ":" .. qty
    if P._depCache[key] ~= nil then return P._depCache[key] or nil end
    local ok, v = pcall(A.CalculateCommodityDeposit, id, DUR_INDEX[hours] or 3, qty)
    v = ok and Num(v) or nil
    if v and v < 0 then v = nil end
    P._depCache[key] = v or false
    return v
end

-- Deposit for qty items, posted in full stacks: share of max(min, rate x sell x stack) per stack. Returns copper, source.
function P.Deposit(id, qty)
    qty = tonumber(qty) or 1
    if qty <= 0 then return 0, "none" end
    local hours = P.Hours()
    local sell, stack = P.ItemSellInfo(id)
    stack = (stack and stack >= 1) and math.floor(stack) or 1
    local perStack = ClientDeposit(id, hours, stack)
    local src = "client"
    if not perStack then
        perStack = math.floor((sell or 0) * stack * P.DEPOSIT_RATE[hours])
        src = sell and "formula" or "minimum (sell price unknown)"
    end
    perStack = math.max(P.MinDeposit(), perStack)
    return perStack * qty / stack, src
end

local function NetSale(price, qty, id)
    local gross = price * qty
    local cut = gross * P.CUT
    local dep = P.Deposit(id, qty)
    return gross - cut - dep, cut, dep
end

-- Full analysis for one recipe: nil when prices are off / Auctionator missing / recipe has no item output.
-- Returns { status = "craft"|"mats"|"even"|"nodata", profit, matsNet, craftNet, buyCost, lines = {...}, stale, maxAge }
function P.Analyze(r)
    if not (P.Enabled() and P.API()) or type(r) ~= "table" or type(r.out) ~= "number" then return nil end
    local res = { reagents = {}, missing = {} }
    local maxAge, stale = 0, false
    local v1 = P.API()
    local hasAge = type(v1.GetAuctionAgeByItemID) == "function"
    local function Age(a)
        if a == nil then if hasAge then stale = true; res.ageUnknown = true end elseif a > maxAge then maxAge = a end
        if a and a > P.STALE_DAYS then stale = true end
    end
    local matsNet, matsCut, matsDep, buyCost = 0, 0, 0, 0
    for _, g in ipairs(type(r.reagents) == "table" and r.reagents or {}) do
        local id, n = g.id, tonumber(g.n) or 1
        local ah, age = P.AHPrice(id)
        local vend = P.VendorBuy(id)
        local e = { id = id, n = n }
        if vend and (not ah or vend <= ah) then
            e.src, e.unit, e.net = "vendor", vend, vend * n               -- keep / buy at the vendor: no cut, no deposit
            buyCost = buyCost + vend * n
        elseif ah then
            local net, cut, dep = NetSale(ah, n, id)
            e.src, e.unit, e.net, e.cut, e.dep, e.age = "ah", ah, net, cut, dep, age
            matsCut, matsDep = matsCut + cut, matsDep + dep
            buyCost = buyCost + ah * n
            Age(age)
        else
            e.src = "none"; res.missing[#res.missing + 1] = id
        end
        res.reagents[#res.reagents + 1] = e
        matsNet = matsNet + (e.net or 0)
    end
    local yield = tonumber(r.outN) or 1
    if r.outMax and tonumber(r.outMax) and r.outMax > yield then yield = (yield + r.outMax) / 2 end
    local outP, outAge = P.AHPrice(r.out)
    res.yield, res.outUnit, res.outAge = yield, outP, outAge
    if not outP then res.missing[#res.missing + 1] = r.out end
    if #res.missing > 0 or #res.reagents == 0 then res.status = "nodata"; return res end
    Age(outAge)
    local craftNet, cut, dep = NetSale(outP, yield, r.out)
    res.craftGross, res.craftCut, res.craftDep, res.craftNet = outP * yield, cut, dep, craftNet
    res.matsNet, res.matsCut, res.matsDep, res.buyCost = matsNet, matsCut, matsDep, buyCost
    res.profit = math.floor(craftNet - matsNet + 0.5)
    res.buyProfit = math.floor(craftNet - buyCost + 0.5)
    res.stale, res.maxAge = stale, maxAge
    local th = math.max(P.MIN_PROFIT, math.abs(matsNet) * P.MIN_PCT)
    if res.profit >= th then res.status = "craft" elseif res.profit <= -th then res.status = "mats" else res.status = "even" end
    return res
end

-- Compact money "1g 20s" with coin colours (rows); 0 -> "0c"
function P.Short(c)
    c = math.floor(math.abs(tonumber(c) or 0) + 0.5)
    local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "|cffffd100g|r" end
    if s > 0 and #t < 2 then t[#t + 1] = s .. "|cffc7c7cfs|r" end
    if (cc > 0 or #t == 0) and #t < 2 and g == 0 then t[#t + 1] = cc .. "|cffeda55fc|r" end
    return table.concat(t, " ")
end

function P.Money(c)
    c = math.floor((tonumber(c) or 0) + 0.5)
    local neg = c < 0
    return (neg and "-" or "") .. AS.FormatMoney(math.abs(c))
end

-- row text: status word + profit
function P.RowText(res)
    if type(res) ~= "table" then return "" end
    local st = res.stale and "|cff888888*|r" or ""
    if res.status == "craft" then return "|cff40ff40+" .. P.Short(res.profit) .. "|r" .. st end
    if res.status == "mats" then return "|cffff8040sell mats|r" .. st end
    if res.status == "even" then return "|cffaaaaaaeven|r" .. st end
    return "|cff666666no price|r"
end

P.STATUS_TEXT = { craft = "Craft & sell", mats = "Sell the materials", even = "About even", nodata = "No data" }

-- tooltip breakdown lines: { left, right, r, g, b }
function P.TooltipLines(res, nameOf)
    local L = {}
    if type(res) ~= "table" then return L end
    nameOf = nameOf or function(id) return "item " .. tostring(id) end
    local function Add(l, rt, r, g, b) L[#L + 1] = { l, rt, r or 0.9, g or 0.9, b or 0.9 } end
    Add("|cffffd100Auction prices (Auctionator)|r", nil)
    for _, e in ipairs(res.reagents or {}) do
        if e.src == "ah" then Add(string.format("  %s %s x%d", nameOf(e.id), P.Money(e.unit), e.n), P.Money(e.unit * e.n))
        elseif e.src == "vendor" then Add(string.format("  %s (vendor) %s x%d", nameOf(e.id), P.Money(e.unit), e.n), P.Money(e.unit * e.n))
        else Add(string.format("  %s x%d", nameOf(e.id), e.n), "|cffff5050no price|r") end
    end
    if res.status == "nodata" then
        Add("No AH price for " .. (#(res.missing or {}) == 1 and "1 item" or (#(res.missing or {}) .. " items")) .. ": scan the AH with Auctionator.", nil, 0.6, 0.6, 0.6)
        return L
    end
    Add("  AH cut 5% / deposit (mats)", "-" .. P.Money(res.matsCut) .. " / -" .. P.Money(res.matsDep), 0.7, 0.7, 0.7)
    Add("Sell mats nets", P.Money(res.matsNet))
    local y = res.yield == math.floor(res.yield) and tostring(res.yield) or string.format("%.1f", res.yield)
    Add(string.format("Crafted: %s x%s", P.Money(res.outUnit), y), P.Money(res.craftGross))
    Add("  AH cut 5%", "-" .. P.Money(res.craftCut), 0.7, 0.7, 0.7)
    Add(string.format("  Deposit (%dh)", P.Hours()), "-" .. P.Money(res.craftDep), 0.7, 0.7, 0.7)
    Add("Craft & sell nets", P.Money(res.craftNet))
    local col = res.status == "craft" and { 0.25, 1, 0.25 } or (res.status == "mats" and { 1, 0.5, 0.25 } or { 0.7, 0.7, 0.7 })
    Add("Profit vs selling mats", (res.profit >= 0 and "+" or "") .. P.Money(res.profit), col[1], col[2], col[3])
    Add("Advice: " .. P.STATUS_TEXT[res.status], nil, col[1], col[2], col[3])
    Add("If you buy the mats: " .. (res.buyProfit >= 0 and "+" or "") .. P.Money(res.buyProfit), nil, 0.6, 0.8, 1)
    Add("Deposits are refunded when an auction sells, lost if it expires or is cancelled.", nil, 0.6, 0.6, 0.6)
    local age = res.ageUnknown and "unknown" or (res.maxAge == 0 and "today" or (res.maxAge .. " day" .. (res.maxAge == 1 and "" or "s") .. " ago"))
    if res.stale then Add("Prices may be old (oldest scan " .. age .. "): rescan the AH.", nil, 1, 0.6, 0.2)
    else Add("Oldest price scanned " .. age, nil, 0.6, 0.6, 0.6) end
    return L
end

-- 0.3.7 Items view: AH value of what a character holds. Shown for groups where AH prices make sense (trade goods,
-- consumables, reagents, gems, recipes); gear / bags / quest / misc are skipped (prices vary per roll / mostly unsellable).
P.ITEM_CLASSES = { [7] = true, [0] = true, [5] = true, [3] = true, [9] = true }
function P.ItemClassPriced(cid) return cid ~= nil and P.ITEM_CLASSES[cid] == true end

-- nil when prices are off / Auctionator missing; { missing = true } without a price; else unit, total, net (after 5% cut), age, stale
function P.ItemValue(id, count)
    if not (P.Enabled() and P.API()) or type(id) ~= "number" then return nil end
    count = tonumber(count) or 1
    local unit, age = P.AHPrice(id)
    if not unit then return { missing = true } end
    local v1 = P.API()
    local stale = (age == nil and type(v1.GetAuctionAgeByItemID) == "function") or (age ~= nil and age > P.STALE_DAYS)
    local total = unit * count
    return { unit = unit, total = total, net = math.floor(total * (1 - P.CUT) + 0.5), age = age, stale = stale, count = count }
end

function P.ItemRowText(v)
    if type(v) ~= "table" then return "" end
    if v.missing then return "|cff666666no price|r" end
    local st = v.stale and "|cff888888*|r" or ""
    if (v.count or 1) <= 1 then return "|cffffffff" .. P.Short(v.unit) .. "|r" .. st end
    return "|cffffffff" .. P.Short(v.unit) .. "|r |cff888888ea \194\183|r |cffffffff" .. P.Short(v.total) .. "|r" .. st
end

function P.AgeText(age)
    if age == nil then return "unknown" end
    if age == 0 then return "today" end
    return age .. " day" .. (age == 1 and "" or "s") .. " ago"
end

-- refresh when Auctionator finishes a scan (public API, if this Auctionator has it)
function P.Hook()
    if P._hooked then return end
    local v1 = P.API()
    if v1 and type(v1.RegisterForDBUpdate) == "function" then
        P._hooked = pcall(v1.RegisterForDBUpdate, P.CALLER, function()
            P.ResetMemo()
            if AS.IsShown and AS.IsShown() and AS.RefreshUI then pcall(AS.RefreshUI) end
        end)
    end
end
