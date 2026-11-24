-- AltStash: main window (display only). 0.3.0: character-portrait tabs with per-character Items / Craftables lists.
local ADDON, AS = ...

local win, edit, content, scroll, check
local MAX_LINES = 400

local function ClassColored(rec, label)
    label = label or AS.CharLabel(rec)
    local c = RAID_CLASS_COLORS and rec.classFile and RAID_CLASS_COLORS[rec.classFile]
    if c then return string.format("|cff%02x%02x%02x%s|r", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), label) end
    return label
end

local function Locs(e)
    local p = {}
    if e.bag > 0 then p[#p + 1] = "bags " .. e.bag end
    if e.bank > 0 then p[#p + 1] = "bank " .. e.bank end
    if e.mail > 0 then p[#p + 1] = "mail " .. e.mail end
    if (e.auction or 0) > 0 then p[#p + 1] = "auction " .. e.auction end
    return table.concat(p, ", ")
end

local function Header(key, rec)
    local gold = type(rec.money) == "number" and AS.FormatMoney(rec.money) or "|cff888888gold unknown|r"
    return string.format("%s |cff888888%s|r  %s  |cff666666scanned: bags %s | bank %s | mail %s|r",
        ClassColored(rec, AS.UniqueLabel(key)), rec.realm or "", gold, AS.FormatAge(rec.scanned.bag), AS.FormatAge(rec.scanned.bank), AS.FormatAge(rec.scanned.mail))
end

local function EntryLines(lines, r)
    local total = 0
    for _, e in ipairs(r.entries) do
        if #lines < MAX_LINES then
            lines[#lines + 1] = string.format("   %s  x |cffffff00%d|r  |cff999999(%s)|r", e.link or ("[" .. e.name .. "]"), e.total, Locs(e))
        end
        total = total + e.total
    end
    return total
end

function AS.BuildText(query)
    local lines = {}
    query = query or ""
    local filt = AS.TypeFilter()
    local footer = "|cff33ccffTotal gold, all characters:|r " .. AS.TotalMoneyText() .. AS.AuctionFooter()
    local filterLine = filt ~= "all" and ("|cffffd100Type filter:|r " .. AS.TypeLabel(filt) .. "  |cff888888(/as type all to reset)|r") or nil
    local blank = query:match("^%s*$") ~= nil
    if blank and filt == "all" then
        local keys = AS.SortedKeys()
        if #keys == 0 then return "|cff888888Nothing saved yet. Open your bags, bank and mailbox on each character.|r" end
        lines[#lines + 1] = "|cff888888Type an item name above. Saved characters:|r"
        for _, k in ipairs(keys) do
            local rec = AS.db.chars[k]
            local n = 0
            for _, it in pairs(rec.items) do local a, b, c = AS.EffectiveCounts(it); if a + b + c > 0 then n = n + 1 end end
            lines[#lines + 1] = Header(k, rec) .. string.format("  |cffffff00%d|r items", n)
            for _, l in ipairs(AS.AuctionLines(rec, "   ") or {}) do lines[#lines + 1] = l end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = footer
        return table.concat(lines, "\n")
    end
    local results = AS.Search(query)
    if blank then
        -- type filter with an empty box: every character (gold + auction sections stay visible), items of that type under each
        local byKey = {}
        for _, r in ipairs(results) do byKey[r.key] = r end
        local grand = 0
        for _, k in ipairs(AS.SortedKeys()) do
            local rec = AS.db.chars[k]
            lines[#lines + 1] = Header(k, rec)
            if byKey[k] then grand = grand + EntryLines(lines, byKey[k])
            else lines[#lines + 1] = "   |cff666666(no items of this type)|r" end
            for _, l in ipairs(AS.AuctionLines(rec, "   ") or {}) do lines[#lines + 1] = l end
            lines[#lines + 1] = ""
        end
        if #lines >= MAX_LINES then lines[#lines + 1] = "|cff888888... list truncated, refine your search|r" end
        lines[#lines + 1] = footer
        table.insert(lines, 1, string.format("|cff33ccffTotal found: %d|r", grand))
        table.insert(lines, 1, filterLine)
        return table.concat(lines, "\n")
    end
    if #results == 0 then
        return (filterLine and (filterLine .. "\n") or "") .. "|cff888888No matches." .. (AS.TradeableOnly() and " (Tradeable-only filter is ON: soulbound items are hidden.)" or "") .. "|r\n\n" .. footer
    end
    local grand = 0
    for _, r in ipairs(results) do
        lines[#lines + 1] = Header(r.key, r.rec)
        grand = grand + EntryLines(lines, r)
        lines[#lines + 1] = ""
    end
    if #lines >= MAX_LINES then lines[#lines + 1] = "|cff888888... list truncated, refine your search|r" end
    lines[#lines + 1] = footer
    table.insert(lines, 1, string.format("|cff33ccffTotal found: %d|r", grand))
    if filterLine then table.insert(lines, 1, filterLine) end
    return table.concat(lines, "\n")
end
-- Type drop-down. Fallback chain (each step wrapped in pcall so a failure never breaks the window):
--   1) modern Menu system (MenuUtil + DropdownButton)  2) UIDropDownMenuTemplate  3) a simple custom popup list.
-- /as type <name|all> always works as a text fallback.
local function Indented(e) return string.rep("   ", e.depth or 0) .. e.label end

local function BuildMenuDropdown(parent)
    if type(MenuUtil) ~= "table" then error("no MenuUtil") end
    local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if not dd or type(dd.SetupMenu) ~= "function" then error("no DropdownButton") end
    dd:SetWidth(170)
    dd:SetDefaultText(AS.TypeLabel(AS.TypeFilter()))
    dd:SetupMenu(function(_, root)
        for _, e in ipairs(AS.TypeFilters()) do
            local id = e.id
            root:CreateRadio(Indented(e), function() return AS.TypeFilter() == id end, function() AS.SetTypeFilter(id, true) end, id)
        end
    end)
    return dd, "menu", function() pcall(dd.SetDefaultText, dd, AS.TypeLabel(AS.TypeFilter())); if dd.GenerateMenu then pcall(dd.GenerateMenu, dd) end end
end

local function BuildUDDDropdown(parent)
    if type(UIDropDownMenu_Initialize) ~= "function" or type(UIDropDownMenu_AddButton) ~= "function" then error("no UIDropDownMenu") end
    local dd = CreateFrame("Frame", "AltStashTypeDropDown", parent, "UIDropDownMenuTemplate")
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(dd, 140) end
    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, e in ipairs(AS.TypeFilters()) do
            local info = UIDropDownMenu_CreateInfo()
            local id = e.id
            info.text = Indented(e)
            info.checked = (AS.TypeFilter() == id)
            info.func = function() AS.SetTypeFilter(id, true); if CloseDropDownMenus then CloseDropDownMenus() end end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    local function refresh() if UIDropDownMenu_SetText then UIDropDownMenu_SetText(dd, AS.TypeLabel(AS.TypeFilter())) end end
    refresh()
    return dd, "udd", refresh
end

local function BuildPopupDropdown(parent)
    local btn = CreateFrame("Button", "AltStashTypeButton", parent, "UIPanelButtonTemplate")
    btn:SetSize(160, 22)
    local popup = CreateFrame("Frame", "AltStashTypePopup", parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    local list = AS.TypeFilters()
    popup:SetSize(190, #list * 18 + 12)
    popup:SetFrameStrata("DIALOG")
    popup:SetPoint("BOTTOMLEFT", btn, "TOPLEFT", 0, 2)
    if popup.SetBackdrop then
        popup:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        popup:SetBackdropColor(0, 0, 0, 0.95)
    end
    popup:Hide()
    local rows = {}
    for i, e in ipairs(list) do
        local row = CreateFrame("Button", nil, popup)
        row:SetSize(180, 18)
        row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 4 + (e.depth or 0) * 10, 0)
        fs:SetText(e.label)
        row.fs, row.id = fs, e.id
        row:SetScript("OnClick", function() AS.SetTypeFilter(e.id, true); popup:Hide() end)
        rows[i] = row
    end
    btn:SetScript("OnClick", function() popup:SetShown(not popup:IsShown()) end)
    local function refresh() btn:SetText("Type: " .. AS.TypeLabel(AS.TypeFilter())) end
    refresh()
    return btn, "popup", refresh
end

function AS.BuildTypeDropdown(parent)
    for _, builder in ipairs({ BuildMenuDropdown, BuildUDDDropdown, BuildPopupDropdown }) do
        local ok, frame, kind, refresh = pcall(builder, parent)
        if ok and frame then
            AS.typeDropdown = { frame = frame, kind = kind, refresh = refresh }
            return frame, kind
        end
    end
    AS.typeDropdown = nil
end

function AS.RefreshTypeDropdown()
    if AS.typeDropdown and AS.typeDropdown.refresh then AS.typeDropdown.refresh() end
end

------------------------------------------------------------------------
-- 0.3.0 window: title bar, character-portrait tabs, per-character Items / Craftables lists.
-- Display only: nothing here moves, uses or sends anything.
------------------------------------------------------------------------
local BACKDROP_TMPL = BackdropTemplateMixin and "BackdropTemplate" or nil
local WHITE = "Interface\\ChatFrame\\ChatFrameBackground"          -- plain white texture (tinted with SetBackdropColor)
local BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local BAG_ICON = "Interface\\Icons\\INV_Misc_Bag_07"

local W, H = 540, 580
local PAD = 12
local TITLE_H = 30
local TAB_SIZE, TAB_GAP = 40, 6
local TAB_Y = -(TITLE_H + 8)                          -- top of the tab row
local HEADER_Y = TAB_Y - TAB_SIZE - 12                -- character header
local SUB_Y = HEADER_Y - 44                           -- Items / Craftables sub-tabs
local LIST_TOP = SUB_Y - 26                           -- list inset
local FOOTER_H = 46
local ARROW_W = 22
local TABBAR_W = W - 2 * PAD - 2 * ARROW_W - 8
local VISIBLE_TABS = math.floor((TABBAR_W + TAB_GAP) / (TAB_SIZE + TAB_GAP))
local LIST_W = W - 2 * PAD - 12 - 26                  -- inset padding + scroll bar
local ROW_H = 22
local MAX_ROWS = 600

AS.CD_TICK = 30          -- seconds between live cooldown refreshes while the window is open
local ui = {}            -- widgets of the new window
local tabs = {}          -- tab buttons (pooled)
local rowPool = {}       -- list rows (pooled)
local tabOffset = 0      -- first visible tab index - 1
AS._ui = ui

local function SetBackdropSafe(f, bg, edge, edgeSize, inset, bgc, bc)
    if not f.SetBackdrop then return end
    f:SetBackdrop({ bgFile = bg, edgeFile = edge, tile = false, tileSize = 0, edgeSize = edgeSize or 12,
        insets = { left = inset or 3, right = inset or 3, top = inset or 3, bottom = inset or 3 } })
    if bgc then f:SetBackdropColor(bgc[1], bgc[2], bgc[3], bgc[4]) end
    if bc then f:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4]) end
end

local function ClassRGB(rec)
    local c = RAID_CLASS_COLORS and rec and rec.classFile and RAID_CLASS_COLORS[rec.classFile]
    if c then return c.r, c.g, c.b end
    return 1, 0.82, 0
end

------------------------------------------------------------------------
-- Item helpers (all nil-safe; item data may not be cached yet)
------------------------------------------------------------------------
local function ItemInfo(id)
    local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(f) ~= "function" or type(id) ~= "number" then return nil end
    local ok, name, link, quality = pcall(f, id)
    if ok then return name, link, quality end
end

local function ItemIcon(id)
    if type(id) ~= "number" then return QUESTION end
    if C_Item and C_Item.GetItemIconByID then
        local ok, t = pcall(C_Item.GetItemIconByID, id)
        if ok and t then return t end
    end
    if type(GetItemIcon) == "function" then
        local ok, t = pcall(GetItemIcon, id)
        if ok and t then return t end
    end
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if type(f) == "function" then
        local ok, _, _, _, _, icon = pcall(f, id)
        if ok and icon then return icon end
    end
    return QUESTION
end

local QHEX = { [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000", [6] = "ffe6cc80", [7] = "ff00ccff" }
local function ItemQuality(id)
    local _, _, q = ItemInfo(id)
    if type(q) == "number" then return q end
    if C_Item and C_Item.GetItemQualityByID and type(id) == "number" then
        local ok, q2 = pcall(C_Item.GetItemQualityByID, id)
        if ok and type(q2) == "number" then return q2 end
    end
end
local function QualityPrefix(q)
    if type(q) ~= "number" then return "|cffffffff" end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c and type(c.hex) == "string" and c.hex:find("^|c") then return c.hex end
    return "|c" .. (QHEX[q] or "ffffffff")
end

local FALLBACK_CLASS = { [0] = "Consumable", [1] = "Container", [2] = "Weapon", [3] = "Gem", [4] = "Armor", [5] = "Reagent",
    [7] = "Trade Goods", [9] = "Recipe", [12] = "Quest", [15] = "Miscellaneous" }
local CLASS_ORDER = { [7] = 1, [5] = 2, [0] = 3, [9] = 4, [2] = 5, [4] = 6, [3] = 7, [1] = 8, [12] = 9, [15] = 10 }
local function ClassLabel(cid)
    if cid == nil then return "Other" end
    local f = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
    if type(f) == "function" then
        local ok, n = pcall(f, cid)
        if ok and type(n) == "string" and n ~= "" then return n end
    end
    return FALLBACK_CLASS[cid] or "Other"
end

local function LocText(e)
    local p = {}
    if (e.bag or 0) > 0 then p[#p + 1] = "bags " .. e.bag end
    if (e.bank or 0) > 0 then p[#p + 1] = "bank " .. e.bank end
    if (e.mail or 0) > 0 then p[#p + 1] = "mail " .. e.mail end
    return table.concat(p, "  ")
end

------------------------------------------------------------------------
-- Portraits.
--   * The logged-in character: SetPortraitTexture(tex, "player") (live 3D portrait, the only unit that exists).
--   * Offline alts: WoW cannot render or save a portrait for a unit that isn't loaded, so the tab shows the race +
--     gender icon from the saved raceFile/sex (atlas "raceicon128-<race>-<sex>" / "raceicon-<race>-<sex>" when the
--     client has it, else RACE_ICON_TCOORDS on the character-create race sheet), then the class icon
--     (UI-Classes-Circles), then a question mark. Every step is feature-detected.
------------------------------------------------------------------------
local RACE_TOKEN = { Scourge = "undead", Undead = "undead", NightElf = "nightelf", BloodElf = "bloodelf", HighmountainTauren = "highmountain",
    LightforgedDraenei = "lightforged", DarkIronDwarf = "darkirondwarf", MagharOrc = "magharorc", VoidElf = "voidelf",
    ZandalariTroll = "zandalari", KulTiran = "kultiran", Nightborne = "nightborne" }
local CLASS_COORDS = { -- UI-Classes-Circles (identical to the client's CLASS_ICON_TCOORDS; used only if that global is missing)
    WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49609375, 0, 0.25 }, ROGUE = { 0.49609375, 0.7421875, 0, 0.25 },
    DRUID = { 0.7421875, 0.98828125, 0, 0.25 }, HUNTER = { 0, 0.25, 0.25, 0.5 }, SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
    PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 }, WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 }, PALADIN = { 0, 0.25, 0.5, 0.75 } }

local function AtlasExists(name)
    if not (C_Texture and type(C_Texture.GetAtlasInfo) == "function") then return false end
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return ok and info ~= nil
end

-- returns "live" | "race" | "class" | "unknown"
function AS.SetCharPortrait(tex, key, rec)
    if not tex then return "unknown" end
    tex:SetTexCoord(0, 1, 0, 1)
    if key == "all" then tex:SetTexture(BAG_ICON); return "icon" end
    if key and key == AS.CurrentKey() and type(SetPortraitTexture) == "function" then
        local ok = pcall(SetPortraitTexture, tex, "player")
        if ok then return "live" end
    end
    rec = rec or {}
    local male = rec.sex ~= 3
    if type(rec.raceFile) == "string" then
        local token = RACE_TOKEN[rec.raceFile] or rec.raceFile:lower()
        if tex.SetAtlas then
            for _, fmt in ipairs({ "raceicon128-%s-%s", "raceicon-%s-%s" }) do
                local name = string.format(fmt, token, male and "male" or "female")
                if AtlasExists(name) and pcall(tex.SetAtlas, tex, name) then return "race" end
            end
        end
        local rc = type(RACE_ICON_TCOORDS) == "table" and RACE_ICON_TCOORDS[rec.raceFile:upper() .. (male and "_MALE" or "_FEMALE")]
        if type(rc) == "table" and #rc >= 4 then
            tex:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races")
            tex:SetTexCoord(rc[1], rc[2], rc[3], rc[4])
            return "race"
        end
    end
    if rec.classFile then
        local c = (type(CLASS_ICON_TCOORDS) == "table" and CLASS_ICON_TCOORDS[rec.classFile]) or CLASS_COORDS[rec.classFile]
        if type(c) == "table" and #c >= 4 then
            tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
            tex:SetTexCoord(c[1], c[2], c[3], c[4])
            return "class"
        end
    end
    tex:SetTexture(QUESTION)
    return "unknown"
end

local function DescribeChar(rec)
    local parts = {}
    if type(rec.level) == "number" then parts[#parts + 1] = "Level " .. rec.level end
    if rec.race then parts[#parts + 1] = rec.race end
    if rec.class then parts[#parts + 1] = rec.class end
    return table.concat(parts, " ")
end

------------------------------------------------------------------------
-- Selection (saved in AltStashDB.settings: optional fields uiTab / uiView / craftNowOnly - schema stays 3)
------------------------------------------------------------------------
local function TabKeys()
    local keys = { "all" }
    if AS.db then for _, k in ipairs(AS.SortedKeys()) do keys[#keys + 1] = k end end
    return keys
end

function AS.SelectedTab()
    local s = AS.db and AS.db.settings
    local k = s and s.uiTab
    if k == "all" then return "all" end
    if k and AS.db.chars[k] then return k end
    local cur = AS.CurrentKey and AS.CurrentKey()
    if cur and AS.db and AS.db.chars[cur] then return cur end
    return "all"
end

local function View()
    local v = AS.db and AS.db.settings and AS.db.settings.uiView
    return (v == "crafts") and "crafts" or "items"
end

local function EnsureTabVisible(key)
    local keys = TabKeys()
    for i, k in ipairs(keys) do
        if k == key then
            if i <= tabOffset then tabOffset = i - 1
            elseif i > tabOffset + VISIBLE_TABS then tabOffset = i - VISIBLE_TABS end
        end
    end
end

function AS.SelectTab(key)
    if not AS.db then return end
    if key ~= "all" and not AS.db.chars[key] then key = "all" end
    AS.db.settings.uiTab = key
    EnsureTabVisible(key)
    if ui.scroll then ui.scroll:SetVerticalScroll(0) end
    AS.RefreshUI()
end

function AS.SetView(v)
    if not AS.db then return end
    AS.db.settings.uiView = (v == "crafts") and "crafts" or "items"
    if ui.scroll then ui.scroll:SetVerticalScroll(0) end
    AS.RefreshUI()
end

------------------------------------------------------------------------
-- Data for one character
------------------------------------------------------------------------
local function Query()
    local t = edit and edit:GetText() or ""
    return (t:lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

-- rows: { kind = "header"|"item"|"recipe"|"text", ... } ; returns rows, number of items shown
function AS.CharItemRows(key, query)
    local rows, n = {}, 0
    local rec = AS.db and AS.db.chars[key]
    if not rec then return rows, 0 end
    query = query or ""
    local blank = query == ""
    local wantId = query:match("^%d+$") and tonumber(query)
    local filt = AS.TypeFilter()
    if filt ~= "all" then pcall(AS.BackfillTypes) end
    local groups, order = {}, {}
    local P = AS.Prices
    local priced = P and P.Enabled() and P.API() ~= nil
    if priced then P.ResetMemo(); pcall(P.Hook) end
    local Us = AS.Usage
    local usage = Us and Us.Enabled()
    if usage then Us.Reset() end
    local safeOnly = usage and AS.db.settings.itemsSafeOnly == true
    local safeN, safeVendor, safeAH = 0, 0, 0
    for id, it in pairs(rec.items or {}) do
        local bag, bank, mail = AS.EffectiveCounts(it)
        if bag + bank + mail > 0 then
            local cid, sid = AS.ItemTypeOf(id, it)
            if AS.TypeMatches(filt, cid, sid) then
                local name = AS.DisplayName(id, it)
                if blank or (wantId and id == wantId) or name:lower():find(query, 1, true) then
                    local gk = cid or -1
                    local g = groups[gk]
                    if not g then g = { cid = cid, label = ClassLabel(cid), list = {} }; groups[gk] = g; order[#order + 1] = g end
                    local e = { kind = "item", id = id, name = name, bag = bag, bank = bank, mail = mail, total = bag + bank + mail }
                    if priced and P.ItemClassPriced(cid) then local okV, v = pcall(P.ItemValue, id, e.total); if okV then e.value = v end end
                    if usage then local okU, u = pcall(Us.ItemUsage, id, it, name, key); if okU then e.usage = u end end
                    local isSafe = e.usage and (e.usage.verdict == "safe" or e.usage.verdict == "done")
                    if isSafe then
                        safeN = safeN + 1
                        local tn = math.min(e.total, e.usage.tradeable or e.total)
                        if e.usage.vendor then safeVendor = safeVendor + e.usage.vendor * (e.usage.verdict == "done" and e.total or tn) end
                        if e.value and e.value.total then safeAH = safeAH + e.value.total end
                    end
                    if not safeOnly or isSafe then g.list[#g.list + 1] = e end
                    n = n + 1
                end
            end
        end
    end
    table.sort(order, function(a, b)
        local oa, ob = CLASS_ORDER[a.cid or -1] or 50, CLASS_ORDER[b.cid or -1] or 50
        if a.cid == nil then oa = 99 end
        if b.cid == nil then ob = 99 end
        if oa ~= ob then return oa < ob end
        return a.label < b.label
    end)
    if safeOnly then
        local parts = { string.format("|cff9acd32Safe to sell / delete:|r %d item%s", safeN, safeN == 1 and "" or "s") }
        if safeVendor > 0 then parts[#parts + 1] = "vendor " .. AS.FormatMoney(safeVendor) end
        if safeAH > 0 then parts[#parts + 1] = "AH " .. AS.FormatMoney(safeAH) end
        rows[#rows + 1] = { kind = "text", text = table.concat(parts, "  |cff888888\194\183|r  ") .. "\n|cff888888Not needed by any saved quest log or ProfTracker recipe. Quests you haven't picked up and recipes you haven't learned are unknown.|r", summary = true }
    end
    for _, g in ipairs(order) do
      if #g.list > 0 then
        table.sort(g.list, function(a, b) return a.name:lower() < b.name:lower() end)
        local units, worth, pricedN = 0, 0, 0
        for _, e in ipairs(g.list) do
            units = units + e.total
            if e.value and e.value.total then worth = worth + e.value.total; pricedN = pricedN + 1 end
        end
        local right = string.format("%d item%s, %d total", #g.list, #g.list == 1 and "" or "s", units)
        if pricedN > 0 then right = right .. "  |cff888888\194\183|r  AH |cffffffff" .. P.Short(worth) .. "|r" end
        rows[#rows + 1] = { kind = "header", text = g.label, right = right, worth = pricedN > 0 and worth or nil }
        for _, e in ipairs(g.list) do rows[#rows + 1] = e end
      end
    end
    if safeOnly and safeN == 0 and n > 0 then rows[#rows + 1] = { kind = "text", text = "|cff888888Nothing here is marked safe to sell or delete.|r" } end
    if n == 0 then
        local why
        if next(rec.items or {}) == nil then why = "Nothing saved for this character yet. Log in and open bags, bank and mailbox."
        elseif not blank or filt ~= "all" then why = "No items match the search / type filter."
        else why = "Nothing to show." end
        if AS.TradeableOnly() then why = why .. " (Tradeable only is ON: soulbound items are hidden.)" end
        rows[#rows + 1] = { kind = "text", text = "|cff888888" .. why .. "|r" }
    end
    local auc = AS.AuctionLines and AS.AuctionLines(rec, "") or nil
    if auc and #auc > 0 then
        rows[#rows + 1] = { kind = "header", text = "Auction House" }
        for _, l in ipairs(auc) do rows[#rows + 1] = { kind = "text", text = l } end
    end
    return rows, n
end

-- ProfTracker (optional companion add-on) owns recipe data: ProfTrackerDB.chars[guid].recipes[prof][recipeID].
-- Read lazily (both add-ons are loaded by the time the window is used); every call is pcall-wrapped.
local function PTAvailable()
    local PT = _G.ProfTracker
    if type(PT) == "table" and type(PT.db) == "table" and type(PT.db.chars) == "table" and type(PT.RecipeRows) == "function" then return PT end
end

-- 0.3.3 cooldowns (data captured by ProfTracker 0.1.4+: recipe.cd / recipe.cdGroup / char.cooldowns[recipeID].ready = epoch).
-- Works with older ProfTracker data too: no fields -> no cooldown shown.
local CLOCK = "Interface\\Icons\\INV_Misc_PocketWatch_01"
AS.CLOCK_ICON = CLOCK
function AS.FormatRemaining(secs)
    local PT = _G.ProfTracker
    if type(PT) == "table" and type(PT.FormatRemaining) == "function" then
        local ok, t = pcall(PT.FormatRemaining, secs)
        if ok and type(t) == "string" then return t end
    end
    secs = math.max(0, math.floor(tonumber(secs) or 0))
    if secs < 60 then return "<1m" end
    local d, h, m = math.floor(secs / 86400), math.floor(secs % 86400 / 3600), math.floor(secs % 3600 / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

-- { ready = epoch (0 = ready), at, src, group, known } or nil
-- 0.3.4: never display an impossible cooldown. Profession cooldowns are at most a few days; a ready time further out than
-- AS.CD_MAX is a GetTime() 32-bit wrap saved by ProfTracker 0.1.4 (shown as "50d 22h"): take the wrap off if that gives a
-- sane time, otherwise show it as not read yet. ProfTracker 0.1.5+ repairs the saved data itself.
AS.CD_MAX, AS.CD_WRAP = 7 * 86400, 4294967.296
local function SaneCd(info)
    if type(info) ~= "table" then return info end
    local ready = tonumber(info.ready) or 0
    local now = time()
    if ready > now + AS.CD_MAX + 60 then
        local r2 = math.floor(ready - AS.CD_WRAP + 0.5)
        if r2 <= now + AS.CD_MAX + 60 and r2 >= now - AS.CD_MAX then
            info.ready = r2 > now and r2 or 0
        else
            info.ready, info.known = 0, false
        end
        if type(info.remaining) == "number" then info.remaining = math.max(0, info.ready - now) end
    end
    return info
end
AS._SaneCd = SaneCd

function AS.RecipeCooldown(PT, prec, r)
    if type(prec) ~= "table" or type(r) ~= "table" then return nil end
    if type(PT) == "table" and type(PT.CooldownInfo) == "function" then
        local ok, info = pcall(PT.CooldownInfo, prec, r)
        if ok then return type(info) == "table" and SaneCd(info) or nil end
    end
    local c = type(prec.cooldowns) == "table" and prec.cooldowns[r.id] or nil   -- data without the helper
    if type(c) == "table" and type(c.ready) == "number" then return SaneCd({ ready = c.ready, at = c.at, src = c.src, group = r.cdGroup, known = true }) end
    if r.cd then return { ready = 0, group = r.cdGroup, known = false } end
    return nil
end

local function CdRemaining(cd)
    if type(cd) ~= "table" or type(cd.ready) ~= "number" then return 0 end
    return math.max(0, cd.ready - time())
end
AS._CdRemaining = CdRemaining

local function PTKeyFor(PT, key)
    if PT.db.chars[key] then return key end
    local rec = AS.db.chars[key]
    if not rec then return nil end
    for k, r in pairs(PT.db.chars) do
        if type(r) == "table" and ((rec.guid and r.guid == rec.guid) or (r.name == rec.name and r.realm == rec.realm and (not rec.classFile or r.classFile == rec.classFile))) then return k end
    end
end

-- Cooldown summary for one character (ProfTracker data): readyN, activeN, soonest remaining seconds. Shared groups count once;
-- only cooldowns actually read in game count (a transmute never seen is not reported as "ready").
function AS.CooldownSummary(key)
    local PT = PTAvailable()
    if not PT then return 0, 0, nil end
    local pkey = PTKeyFor(PT, key)
    local prec = pkey and PT.db.chars[pkey]
    if type(prec) ~= "table" then return 0, 0, nil end
    local seen, ready, active, soonest = {}, 0, 0, nil
    for _, map in pairs(type(prec.recipes) == "table" and prec.recipes or {}) do
        for id, r in pairs(type(map) == "table" and map or {}) do
            if type(r) == "table" and (r.cd or (type(prec.cooldowns) == "table" and prec.cooldowns[id])) then
                local cd = AS.RecipeCooldown(PT, prec, r)
                local gk = cd and (cd.group or id)
                if cd and cd.known and not seen[gk] then
                    seen[gk] = true
                    local rem = CdRemaining(cd)
                    if rem > 0 then active = active + 1; if not soonest or rem < soonest then soonest = rem end
                    else ready = ready + 1 end
                end
            end
        end
    end
    return ready, active, soonest
end

-- returns rows, number of recipes shown, number craftable now
function AS.CraftRows(key, query)
    local rows, shown, nowN = {}, 0, 0
    local PT = PTAvailable()
    if not PT then
        rows[#rows + 1] = { kind = "text", text = "|cffffd100Craftables come from the ProfTracker add-on, which isn't loaded.|r" }
        rows[#rows + 1] = { kind = "text", text = "|cff999999Enable ProfTracker in the AddOns list, then open each profession window once on every character to save its recipes.|r" }
        return rows, 0, 0
    end
    local pkey = PTKeyFor(PT, key)
    local prec = pkey and PT.db.chars[pkey]
    local profNames = {}
    if prec then
        local ok, list = pcall(PT.SortedProfs, prec)
        if ok and type(list) == "table" then profNames = list end
        for prof in pairs(prec.recipes or {}) do      -- recipe maps without a skill entry are still shown
            local seen = false
            for _, p in ipairs(profNames) do if p == prof then seen = true end end
            if not seen then profNames[#profNames + 1] = prof end
        end
    end
    pcall(PT.ResetMemo)
    local P = AS.Prices
    local priced = P and P.Enabled() and P.API() ~= nil
    if priced then P.ResetMemo(); pcall(P.Hook) end
    local profitOnly = priced and AS.db.settings.craftProfitOnly == true
    -- 0.3.6: "Profitable" also sorts by profit (highest first); the saved Sort setting is untouched, so unticking restores it
    local byProfit = priced and (profitOnly or AS.db.settings.craftSort == "profit")
    local nowOnly = AS.db.settings.craftNowOnly == true
    for _, prof in ipairs(profNames) do
        local map = prec.recipes and prec.recipes[prof]
        if type(map) == "table" and next(map) then
            local ok, list = pcall(PT.RecipeRows, pkey, prof, query, 1)
            if ok and type(list) == "table" then
                local items, can = {}, 0
                for _, rr in ipairs(list) do
                    local r, a = rr.recipe, rr.a or {}
                    local canAll = (a.known and a.canAll ~= math.huge) and (a.canAll or 0) or 0
                    if canAll > 0 then can = can + 1 end
                    local price
                    if priced then local okP, res = pcall(P.Analyze, r); if okP then price = res end end
                    if (not nowOnly or canAll > 0) and (not profitOnly or (price and price.status == "craft")) then
                        local name = r.name or "?"
                        if r.out and PT.MakesText then local okM, mt = pcall(PT.MakesText, r); if okM and mt then name = mt end end
                        items[#items + 1] = { kind = "recipe", id = r.out, name = name, recipe = r, a = a, canAll = canAll,
                            canOwn = (a.known and not a.noData and a.canOwn ~= math.huge) and (a.canOwn or 0) or nil, diff = r.diff,
                            cd = AS.RecipeCooldown(PT, prec, r), price = price }
                    end
                end
                table.sort(items, function(x, y)
                    if byProfit then
                        local px = (x.price and x.price.profit) or -math.huge
                        local py = (y.price and y.price.profit) or -math.huge
                        if px ~= py then return px > py end
                    end
                    local cx, cy = x.canAll > 0, y.canAll > 0
                    if cx ~= cy then return cx end
                    local dx, dy = x.diff or 4, y.diff or 4
                    if dx ~= dy then return dx < dy end
                    return (x.name or ""):lower() < (y.name or ""):lower()
                end)
                local p = prec.profs and prec.profs[prof]
                local skill = (p and p.level) and string.format("  |cffffffff%d/%d|r", p.level, p.max or 0) or ""
                rows[#rows + 1] = { kind = "header", text = prof .. skill, right = string.format("%d recipe%s, %d craftable now", #list, #list == 1 and "" or "s", can) }
                for _, e in ipairs(items) do rows[#rows + 1] = e end
                if #items == 0 then rows[#rows + 1] = { kind = "text", text = "|cff888888" .. (profitOnly and "No profitable recipes with the current Auctionator prices." or (nowOnly and "Nothing craftable right now with the saved materials." or "No recipes match the search.")) .. "|r" } end
                shown, nowN = shown + #items, nowN + can
            end
        end
    end
    if #rows > 0 and P and P.Enabled() and not priced then
        rows[#rows + 1] = { kind = "text", text = "|cff888888Craft-or-sell advice: install / enable Auctionator and scan the AH (or /as prices off to hide this).|r" }
    end
    if #rows == 0 then
        rows[#rows + 1] = { kind = "text", text = "|cff888888No recipes saved for this character yet. Log in on it and open each profession window once (ProfTracker saves them).|r" }
    end
    return rows, shown, nowN
end

------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------
local function ShowItemTooltip(owner, id)
    if not (GameTooltip and type(id) == "number") then return false end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local ok
    AS._rowTooltip = true            -- 0.3.9: our rows add the full usage block; skip the one-line game-tooltip version
    if GameTooltip.SetItemByID then ok = pcall(GameTooltip.SetItemByID, GameTooltip, id) end
    if not ok then ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. id) end
    AS._rowTooltip = nil
    return ok
end

local function RowOnEnter(self)
    local d = self.data
    if not d or not GameTooltip then return end
    if d.kind == "item" then
        if ShowItemTooltip(self, d.id) then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff33ccffAltStash:|r " .. LocText(d), 1, 1, 1)
            if d.usage and AS.Usage then
                local okL, lines = pcall(AS.Usage.TooltipLines, d.usage)
                if okL and type(lines) == "table" then
                    for _, l in ipairs(lines) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
                end
            end
            local v, P = d.value, AS.Prices
            if v and P then
                if v.missing then
                    GameTooltip:AddLine("AH price: none in Auctionator (scan the AH).", 0.6, 0.6, 0.6, true)
                else
                    GameTooltip:AddDoubleLine("AH price (Auctionator)", P.Money(v.unit) .. " each", 1, 0.82, 0, 1, 1, 1)
                    if (v.count or 1) > 1 then GameTooltip:AddDoubleLine("  x" .. v.count, P.Money(v.total), 0.9, 0.9, 0.9, 1, 1, 1) end
                    GameTooltip:AddDoubleLine("  after 5% AH cut", P.Money(v.net), 0.7, 0.7, 0.7, 1, 1, 1)
                    if v.stale then GameTooltip:AddLine("Price scanned " .. P.AgeText(v.age) .. ": may be old, rescan the AH.", 1, 0.6, 0.2, true)
                    else GameTooltip:AddLine("Price scanned " .. P.AgeText(v.age), 0.6, 0.6, 0.6) end
                end
            end
            GameTooltip:Show()
        end
    elseif d.kind == "recipe" then
        local r, a = d.recipe or {}, d.a or {}
        if not (r.out and ShowItemTooltip(self, r.out)) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(r.name or d.name or "?", 1, 0.82, 0)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Recipe: " .. tostring(r.name or "?"), 1, 0.82, 0)
        for _, e in ipairs(a.reagents or {}) do
            local have = e.haveAll or 0
            local col = have >= (e.need or 0) and "|cff40ff40" or "|cffff5050"
            GameTooltip:AddDoubleLine(string.format("  %s x%d", tostring(e.name or "?"), e.need or 0), col .. have .. " have|r", 0.9, 0.9, 0.9)
        end
        if a.known then
            GameTooltip:AddLine(string.format("Can make %d with all characters' materials%s", d.canAll or 0,
                d.canOwn and string.format(" (%d from this character's own)", d.canOwn) or ""), 0.6, 0.8, 1, true)
        else
            GameTooltip:AddLine("Reagents not saved yet (reopen the profession window).", 0.6, 0.6, 0.6, true)
        end
        if d.cd then
            local rem = CdRemaining(d.cd)
            local shared = d.cd.group and (" (shared with all " .. d.cd.group .. "s)") or ""
            if rem > 0 then
                local at = (type(date) == "function") and date("%a %b %d, %H:%M", d.cd.ready) or ""
                GameTooltip:AddLine("Cooldown: " .. AS.FormatRemaining(rem) .. " left" .. shared, 1, 0.38, 0.25, true)
                GameTooltip:AddLine("Ready at " .. at .. " (your local time)", 1, 0.6, 0.4)
            else
                GameTooltip:AddLine("Cooldown: Ready" .. shared, 0.25, 1, 0.25, true)
                if not d.cd.known then GameTooltip:AddLine("Not read yet: log in on this character once (ProfTracker 0.1.4+).", 0.6, 0.6, 0.6, true) end
            end
            if type(d.cd.at) == "number" then GameTooltip:AddLine("Checked " .. AS.FormatAge(d.cd.at), 0.6, 0.6, 0.6) end
        end
        if d.price and AS.Prices then
            local okL, lines = pcall(AS.Prices.TooltipLines, d.price, function(id)
                local info = ItemInfo(id); return (type(info) == "string" and info) or ("item " .. tostring(id)) end)
            if okL and type(lines) == "table" and #lines > 0 then
                GameTooltip:AddLine(" ")
                for _, l in ipairs(lines) do
                    if l[2] then GameTooltip:AddDoubleLine(l[1], l[2], l[3], l[4], l[5], 1, 1, 1)
                    else GameTooltip:AddLine(l[1], l[3], l[4], l[5], true) end
                end
            end
        end
        GameTooltip:Show()
    end
end

local function RowOnLeave() if GameTooltip then GameTooltip:Hide() end end

local function RowOnClick(self)
    local d = self.data
    local id = d and (d.kind == "item" and d.id or (d.kind == "recipe" and d.recipe and d.recipe.out))
    if not id then return end
    if type(IsModifiedClick) == "function" and IsModifiedClick("CHATLINK") and type(ChatEdit_InsertLink) == "function" then
        local link = AS.ItemLink(id)
        if link then pcall(ChatEdit_InsertLink, link) end
    end
end

local function GetRow(i)
    local row = rowPool[i]
    if row then return row end
    row = CreateFrame("Button", nil, ui.holder)
    row:SetHeight(ROW_H)
    row:SetWidth(LIST_W)
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.035)
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(0.3, 0.6, 1, 0.15)
    row.dif = row:CreateTexture(nil, "ARTWORK")          -- recipe skill-up difficulty (orange/yellow/green/white) bar
    row.dif:SetWidth(3)
    row.dif:SetPoint("TOPLEFT", 0, -2)
    row.dif:SetPoint("BOTTOMLEFT", 0, 2)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.count:SetPoint("RIGHT", -6, 0)
    row.count:SetJustifyH("RIGHT")
    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.detail:SetPoint("RIGHT", row.count, "LEFT", -10, 0)
    row.detail:SetJustifyH("RIGHT")
    row.detail:SetTextColor(0.6, 0.6, 0.6)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.detail, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end
    row.line = row:CreateTexture(nil, "ARTWORK")
    row.line:SetHeight(1)
    row.line:SetPoint("BOTTOMLEFT", 2, 1)
    row.line:SetPoint("BOTTOMRIGHT", -2, 1)
    row.line:SetColorTexture(1, 0.82, 0, 0.35)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("TOPLEFT", 8, -3)
    row.text:SetWidth(LIST_W - 16)
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)
    row:SetScript("OnClick", RowOnClick)
    rowPool[i] = row
    return row
end

local function FillRow(row, d, stripe)
    row.data = d
    local k = d.kind
    local isEntry = (k == "item" or k == "recipe")
    row.icon:SetShown(isEntry)
    row.dif:SetShown(k == "recipe")
    row.line:SetShown(k == "header")
    row.text:SetShown(k == "text")
    row.name:SetShown(k ~= "text")
    row.count:SetShown(k ~= "text")
    row.detail:SetShown(k ~= "text")
    row.stripe:SetShown(isEntry and stripe)
    row.hl:SetShown(isEntry)
    row:EnableMouse(isEntry)
    local h = ROW_H
    if k ~= "text" then row.text:SetText("") end
    if k == "header" then
        row.name:SetFontObject("GameFontNormal")
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", 4, -1)
        row.name:SetPoint("RIGHT", row.detail, "LEFT", -8, 0)
        row.name:SetText(d.text or "")
        row.detail:SetText(d.right or "")
        row.count:SetText("")
        h = ROW_H + 4
    elseif k == "text" then
        row.name:SetText(""); row.detail:SetText(""); row.count:SetText("")
        row.text:SetText(d.text or "")
        local sh = row.text:GetStringHeight()
        if type(sh) ~= "number" then sh = 12 end
        h = math.max(16, math.floor(sh + 6))
    else
        row.name:SetFontObject("GameFontHighlight")
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.detail, "LEFT", -8, 0)
        row.icon:SetTexture(ItemIcon(d.id))
        if k == "item" then
            row.name:SetText(QualityPrefix(ItemQuality(d.id)) .. (d.name or "?") .. "|r")
            local loc = LocText(d)
            if d.value and AS.Prices then
                local okT, pt = pcall(AS.Prices.ItemRowText, d.value)
                if okT and pt and pt ~= "" then loc = pt .. "   " .. loc end
            elseif d.usage and (d.usage.verdict == "safe" or d.usage.verdict == "done") and d.usage.vendor and AS.Prices then
                loc = "|cff888888vendor|r " .. AS.Prices.Short(d.usage.vendor) .. "   " .. loc
            end
            if d.usage and AS.Usage then
                local tag = AS.Usage.RowTag(d.usage)
                if tag ~= "" then loc = tag .. "   " .. loc end
            end
            row.detail:SetText(loc)
            row.count:SetText("|cffffd100" .. (d.total or 0) .. "|r")
        else
            local diffCol = (_G.ProfTracker and _G.ProfTracker.DIFF and d.diff and _G.ProfTracker.DIFF[d.diff]) and _G.ProfTracker.DIFF[d.diff].color or "aaaaaa"
            local name = d.id and (QualityPrefix(ItemQuality(d.id)) .. (d.name or "?") .. "|r") or ("|cffffffff" .. (d.name or "?") .. "|r")
            local hex = tostring(diffCol)
            local cr, cg, cb = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
            row.dif:SetColorTexture((cr or 170) / 255, (cg or 170) / 255, (cb or 170) / 255, 1)
            row.name:SetText(name)
            local cdText = ""
            if d.cd then
                local rem = CdRemaining(d.cd)
                if rem > 0 then
                    cdText = "|T" .. CLOCK .. ":12:12:0:0|t |cffff6040" .. AS.FormatRemaining(rem) .. "|r"
                else
                    cdText = "|cff40ff40Ready|r"
                end
            end
            if d.price and AS.Prices then
                local okT, pt = pcall(AS.Prices.RowText, d.price)
                if okT and pt and pt ~= "" then cdText = (cdText ~= "" and (cdText .. "   ") or "") .. pt end
            end
            if not (d.a and d.a.known) then
                row.detail:SetText(cdText ~= "" and (cdText .. "   |cff888888reagents not saved|r") or "reagents not saved")
                row.count:SetText("|cff888888?|r")
            else
                local mats = d.canOwn and ("own mats: " .. d.canOwn) or ""
                row.detail:SetText(cdText ~= "" and (cdText .. (mats ~= "" and ("   " .. mats) or "")) or mats)
                row.count:SetText((d.canAll > 0 and "|cff40ff40" or "|cff777777") .. "x" .. d.canAll .. "|r")
            end
        end
    end
    row:SetHeight(h)
    return h
end

local function RenderRows(rows)
    local y, stripe = 0, false
    local n = math.min(#rows, MAX_ROWS)
    for i = 1, n do
        local row = GetRow(i)
        local d = rows[i]
        if d.kind == "header" then stripe = false else stripe = not stripe end
        if d.kind == "header" and i > 1 then y = y + 6 end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", ui.holder, "TOPLEFT", 0, -y)
        local h = FillRow(row, d, stripe)
        row:Show()
        y = y + h
    end
    for i = n + 1, #rowPool do rowPool[i]:Hide(); rowPool[i].data = nil end
    if #rows > MAX_ROWS then
        local row = GetRow(n + 1)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", ui.holder, "TOPLEFT", 0, -y)
        y = y + FillRow(row, { kind = "text", text = "|cff888888... list truncated, refine your search|r" }, false)
        row:Show()
    end
    ui.holder:SetHeight(math.max(y + 8, 10))
end

------------------------------------------------------------------------
-- Tabs
------------------------------------------------------------------------
local function TabOnEnter(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    if self.key == "all" then
        GameTooltip:AddLine("All characters", 1, 0.82, 0)
        GameTooltip:AddLine("Search every character's bags, bank and mail at once.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("Total gold: " .. AS.TotalMoneyText(), 1, 1, 1)
    else
        local rec = AS.db.chars[self.key]
        if not rec then return end
        local r, g, b = ClassRGB(rec)
        GameTooltip:AddLine(AS.UniqueLabel(self.key), r, g, b)
        local desc = DescribeChar(rec)
        if desc ~= "" then GameTooltip:AddLine(desc, 1, 1, 1) end
        if rec.realm then GameTooltip:AddLine(rec.realm, 0.6, 0.6, 0.6) end
        GameTooltip:AddLine("Gold: " .. (type(rec.money) == "number" and AS.FormatMoney(rec.money) or "unknown"), 1, 1, 1)
        local sc = rec.scanned or {}
        GameTooltip:AddLine(string.format("Scanned: bags %s, bank %s, mail %s", AS.FormatAge(sc.bag), AS.FormatAge(sc.bank), AS.FormatAge(sc.mail)), 0.6, 0.6, 0.6)
        if self.key == AS.CurrentKey() then GameTooltip:AddLine("This character", 0.25, 1, 0.25) end
        if (self.cdReady or 0) > 0 then GameTooltip:AddLine("Profession cooldowns ready: " .. self.cdReady, 0.25, 1, 0.25) end
        if (self.cdActive or 0) > 0 then
            GameTooltip:AddLine(string.format("On cooldown: %d (next ready in %s)", self.cdActive, AS.FormatRemaining(self.cdSoonest or 0)), 1, 0.38, 0.25)
        end
        local mi = self.matchInfo
        if mi and (mi.total or 0) > 0 then
            local q = (edit and edit:GetText() or ""):gsub("|", "||")
            local parts = {}
            if (mi.items or 0) > 0 then parts[#parts + 1] = mi.items .. " item" .. (mi.items == 1 and "" or "s") end
            if (mi.recipes or 0) > 0 then parts[#parts + 1] = mi.recipes .. " recipe" .. (mi.recipes == 1 and "" or "s") end
            GameTooltip:AddLine(string.format("Matches \"%s\": %s", q, table.concat(parts, ", ")), 0.2, 1, 0.2)
        end
        if not rec.guid and not tostring(self.key):find("^Player%-") then GameTooltip:AddLine("Old entry: updates when this character next logs in", 0.6, 0.6, 0.6, true) end
    end
    GameTooltip:Show()
end

-- Tab look (0.3.2): selected = gold border + gold underline + glow (as in 0.3.0); mouse over = the standard hover shine;
-- search match (search box has text and the character has a matching item/recipe) = green outline just OUTSIDE the tab,
-- so a selected tab that matches shows both (green outline around the gold border, gold underline below).
local MATCH_RGB = { 0.2, 1, 0.2 }
AS.TAB_MATCH_RGB = MATCH_RGB
function AS.StyleTab(b)
    if not b then return end
    local sel, match = b.selected and true or false, (b.matchCount or 0) > 0
    b.state = (sel and "selected" or "normal") .. (match and "+match" or "")
    if b.glow then b.glow:SetShown(sel) end
    if b.bar then b.bar:SetShown(sel) end
    for _, t in ipairs(b.ring or {}) do
        if match then t:SetVertexColor(MATCH_RGB[1], MATCH_RGB[2], MATCH_RGB[3], 1); t:Show() else t:Hide() end
    end
    if b.SetBackdropBorderColor then
        if sel then b:SetBackdropBorderColor(1, 0.82, 0, 1)
        else
            local rec = b.key and b.key ~= "all" and AS.db and AS.db.chars[b.key] or nil
            if rec then local r, g, bl = ClassRGB(rec); b:SetBackdropBorderColor(r * 0.6, g * 0.6, bl * 0.6, 1)
            else b:SetBackdropBorderColor(0.4, 0.4, 0.4, 1) end
        end
    end
end

-- Search matches per character: key -> { items = n, recipes = m, total = n + m }. Items use AS.Search (same name / item-id
-- matching, tradeable and type filters as the All characters view); recipes (ProfTracker, optional) match on the recipe
-- name or its output item name. Empty search -> empty table. Recomputed on every refresh (typing / data change); this is a
-- plain table walk over the saved data, cheap enough not to need throttling (event refreshes are already debounced).
local function RecipeNameMatches(PT, r, q, wantId)
    if wantId and (r.id == wantId or r.out == wantId) then return true end
    if type(r.name) == "string" and r.name:lower():find(q, 1, true) then return true end
    if r.out and PT.ItemName then
        local ok, n = pcall(PT.ItemName, r.out)
        if ok and type(n) == "string" and n:lower():find(q, 1, true) then return true end
    end
    return false
end
function AS.SearchMatches(query)
    query = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local out = {}
    if query == "" or not AS.db then return out end
    local ok, res = pcall(AS.Search, query)
    if ok and type(res) == "table" then
        for _, r in ipairs(res) do
            local n = #(r.entries or {})
            if n > 0 then out[r.key] = { items = n, recipes = 0, total = n } end
        end
    end
    local PT = _G.ProfTracker
    if type(PT) == "table" and type(PT.db) == "table" and type(PT.db.chars) == "table" then
        local wantId = query:match("^%d+$") and tonumber(query)
        for key, rec in pairs(AS.db.chars) do
            local pr = PT.db.chars[key]
            if not pr then
                for _, c in pairs(PT.db.chars) do
                    if type(c) == "table" and c.name == rec.name and c.realm == rec.realm then pr = c; break end
                end
            end
            local m = 0
            for _, map in pairs((type(pr) == "table" and pr.recipes) or {}) do
                for _, r in pairs(type(map) == "table" and map or {}) do
                    if type(r) == "table" and RecipeNameMatches(PT, r, query, wantId) then m = m + 1 end
                end
            end
            if m > 0 then
                local e = out[key] or { items = 0, recipes = 0, total = 0 }
                e.recipes, e.total = m, e.items + m
                out[key] = e
            end
        end
    end
    return out
end

local function CreateTab(i)
    local b = CreateFrame("Button", nil, ui.tabBar, BACKDROP_TMPL)
    b:SetSize(TAB_SIZE, TAB_SIZE)
    SetBackdropSafe(b, WHITE, BORDER, 12, 3, { 0, 0, 0, 0.75 }, { 0.4, 0.4, 0.4, 1 })
    b.portrait = b:CreateTexture(nil, "ARTWORK")
    b.portrait:SetPoint("TOPLEFT", 4, -4)
    b.portrait:SetPoint("BOTTOMRIGHT", -4, 4)
    b.glow = b:CreateTexture(nil, "OVERLAY")
    b.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    b.glow:SetBlendMode("ADD")
    b.glow:SetPoint("TOPLEFT", 2, -2)
    b.glow:SetPoint("BOTTOMRIGHT", -2, 2)
    b.glow:Hide()
    b.bar = b:CreateTexture(nil, "OVERLAY")              -- selected: gold underline (below the green match ring)
    b.bar:SetColorTexture(1, 0.82, 0, 1)
    b.bar:SetHeight(3)
    b.bar:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 3, -5)
    b.bar:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", -3, -5)
    b.bar:Hide()
    -- 0.3.2: green search-match outline, 2px, just outside the tab border
    b.ring = {}
    local function edge(p1, x1, y1, p2, x2, y2, horiz)
        local t = b:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 1)
        t:SetPoint(p1, b, p1, x1, y1)
        t:SetPoint(p2, b, p2, x2, y2)
        if horiz then t:SetHeight(2) else t:SetWidth(2) end
        t:Hide()
        b.ring[#b.ring + 1] = t
    end
    edge("TOPLEFT", -2, 2, "TOPRIGHT", 2, 2, true)
    edge("BOTTOMLEFT", -2, -2, "BOTTOMRIGHT", 2, -2, true)
    edge("TOPLEFT", -2, 2, "BOTTOMLEFT", -2, -2, false)
    edge("TOPRIGHT", 2, 2, "BOTTOMRIGHT", 2, -2, false)
    b.cdIcon = b:CreateTexture(nil, "OVERLAY")          -- 0.3.3: a profession cooldown is ready on this character
    b.cdIcon:SetSize(13, 13)
    b.cdIcon:SetPoint("TOPLEFT", 3, -3)
    b.cdIcon:SetTexture(AS.CLOCK_ICON)
    b.cdIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.cdIcon:Hide()
    b.levelBg = b:CreateTexture(nil, "OVERLAY")
    b.levelBg:SetColorTexture(0, 0, 0, 0.75)
    b.level = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.level:SetPoint("BOTTOMRIGHT", -3, 3)
    b.levelBg:SetPoint("TOPLEFT", b.level, "TOPLEFT", -2, 1)
    b.levelBg:SetPoint("BOTTOMRIGHT", b.level, "BOTTOMRIGHT", 2, -1)
    b:SetScript("OnClick", function(self) if self.key then AS.SelectTab(self.key) end end)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", TabOnEnter)
    b:SetScript("OnLeave", RowOnLeave)
    b:EnableMouseWheel(true)
    b:SetScript("OnMouseWheel", function(_, delta) AS.ScrollTabs(-delta) end)
    tabs[i] = b
    return b
end

function AS.ScrollTabs(delta)
    local n = #TabKeys()
    tabOffset = math.max(0, math.min(tabOffset + (delta or 0), math.max(0, n - VISIBLE_TABS)))
    AS.RefreshUI()
end

local function RefreshTabs(selected, forcePortraits)
    local keys = TabKeys()
    local n = #keys
    tabOffset = math.max(0, math.min(tabOffset, math.max(0, n - VISIBLE_TABS)))
    local overflow = n > VISIBLE_TABS
    ui.prev:SetShown(overflow)
    ui.next:SetShown(overflow)
    if overflow then
        if tabOffset > 0 then ui.prev:Enable() else ui.prev:Disable() end
        if tabOffset + VISIBLE_TABS < n then ui.next:Enable() else ui.next:Disable() end
    end
    local cur = AS.CurrentKey()
    local matches = AS.SearchMatches(edit and edit:GetText() or "")
    for i = 1, math.max(n, #tabs) do
        local key = keys[i]
        local b = tabs[i] or (key and CreateTab(i))
        if b then
            local slot = i - tabOffset
            if key and slot >= 1 and slot <= VISIBLE_TABS then
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", ui.tabBar, "TOPLEFT", (slot - 1) * (TAB_SIZE + TAB_GAP), 0)
                local rec = key ~= "all" and AS.db.chars[key] or nil
                local pk = tostring(key) .. "|" .. tostring(key == cur) .. "|" .. tostring(rec and rec.raceFile) .. "|" .. tostring(rec and rec.sex)
                if forcePortraits or b.portraitKey ~= pk then
                    b.key = key
                    b.portraitKind = AS.SetCharPortrait(b.portrait, key, rec)
                    b.portraitKey = pk
                end
                b.key = key
                b.level:SetText(rec and type(rec.level) == "number" and tostring(rec.level) or "")
                b.levelBg:SetShown(rec ~= nil and type(rec.level) == "number")
                b.selected = (key == selected)
                local m = key ~= "all" and matches[key] or nil
                b.matchCount, b.matchInfo = m and m.total or 0, m
                if key ~= "all" then
                    local okS, rdy, act, soon = pcall(AS.CooldownSummary, key)
                    if okS then b.cdReady, b.cdActive, b.cdSoonest = rdy, act, soon else b.cdReady, b.cdActive, b.cdSoonest = 0, 0, nil end
                else b.cdReady, b.cdActive, b.cdSoonest = 0, 0, nil end
                b.cdIcon:SetShown((b.cdReady or 0) > 0)
                AS.StyleTab(b)
                b:Show()
            else
                b.selected, b.matchCount, b.matchInfo = false, 0, nil
                AS.StyleTab(b)
                b:Hide()
            end
        end
    end
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------
local function SetSubTab(btn, label, selected)
    btn.label:SetText(label)
    btn.label:SetTextColor(selected and 1 or 0.65, selected and 0.82 or 0.65, selected and 0 or 0.65)
    btn.bar:SetShown(selected)
    local w = btn.label:GetStringWidth()
    if type(w) ~= "number" then w = 60 end
    btn:SetWidth(math.max(70, math.floor(w + 20)))
end

function AS.RefreshUI(forcePortraits)
    if not win or not win:IsShown() or not AS.db then return end
    if check then check:SetChecked(AS.TradeableOnly()) end
    if AS.RefreshTypeDropdown then pcall(AS.RefreshTypeDropdown) end
    local key = AS.SelectedTab()
    RefreshTabs(key, forcePortraits)
    ui.total:SetText("Total gold: " .. AS.TotalMoneyText())
    if ui.placeholder then ui.placeholder:SetShown((edit:GetText() or "") == "" and not (edit.HasFocus and edit:HasFocus())) end

    if key == "all" then
        ui.charName:SetText("All characters")
        ui.charName:SetTextColor(1, 0.82, 0)
        ui.charDesc:SetText("Type in the search box to find an item on any character.")
        ui.charGold:SetText("")
        ui.charScan:SetText("")
        ui.headerIcon:SetTexture(BAG_ICON)
        ui.headerIcon:SetTexCoord(0, 1, 0, 1)
        ui.headerKey = "all"
        ui.subItems:Hide(); ui.subCrafts:Hide(); ui.nowCheck:Hide(); ui.profitCheck:Hide(); ui.sortBtn:Hide(); ui.safeCheck:Hide()
        for i = 1, #rowPool do rowPool[i]:Hide() end
        content:Show()
        content:SetText(AS.BuildText(edit:GetText()))
        local sh = content:GetStringHeight()
        ui.holder:SetHeight(math.max((type(sh) == "number" and sh or 0) + 8, 10))
        return
    end

    local rec = AS.db.chars[key]
    content:Hide()
    content:SetText("")
    local r, g, b = ClassRGB(rec)
    ui.charName:SetText(AS.UniqueLabel(key))
    ui.charName:SetTextColor(r, g, b)
    local desc = DescribeChar(rec)
    ui.charDesc:SetText((desc ~= "" and desc or "Level/race saved on next login") .. (rec.realm and ("  |cff888888" .. rec.realm .. "|r") or ""))
    ui.charGold:SetText(type(rec.money) == "number" and AS.FormatMoney(rec.money) or "|cff888888gold unknown|r")
    local sc = rec.scanned or {}
    ui.charScan:SetText(string.format("bags %s  |  bank %s  |  mail %s", AS.FormatAge(sc.bag), AS.FormatAge(sc.bank), AS.FormatAge(sc.mail)))
    local hk = tostring(key) .. "|" .. tostring(rec.raceFile) .. "|" .. tostring(rec.sex)
    if forcePortraits or ui.headerKey ~= hk then AS.SetCharPortrait(ui.headerIcon, key, rec); ui.headerKey = hk end

    local q = Query()
    local itemRows, nItems = AS.CharItemRows(key, q)
    local okC, craftRows, nCraft, nNow = pcall(AS.CraftRows, key, q)
    if not okC then craftRows, nCraft, nNow = { { kind = "text", text = "|cffff5050Couldn't read ProfTracker data: " .. tostring(craftRows) .. "|r" } }, 0, 0 end
    local view = View()
    ui.subItems:Show(); ui.subCrafts:Show()
    SetSubTab(ui.subItems, string.format("Items (%d)", nItems), view == "items")
    SetSubTab(ui.subCrafts, PTAvailable() and string.format("Craftables (%d)", nCraft or 0) or "Craftables", view == "crafts")
    ui.nowCheck:SetShown(view == "crafts" and PTAvailable() ~= nil)
    ui.nowCheck:SetChecked(AS.db.settings.craftNowOnly == true)
    local priced = view == "crafts" and PTAvailable() ~= nil and AS.Prices and AS.Prices.Enabled() and AS.Prices.API() ~= nil
    ui.safeCheck:SetShown(view == "items" and AS.Usage ~= nil and AS.Usage.Enabled())
    ui.safeCheck:SetChecked(AS.db.settings.itemsSafeOnly == true)
    ui.profitCheck:SetShown(priced and true or false)
    ui.profitCheck:SetChecked(AS.db.settings.craftProfitOnly == true)
    ui.sortBtn:SetShown(priced and true or false)
    local forced = AS.db.settings.craftProfitOnly == true
    ui.sortBtn.label:SetText(forced and "|cff888888Sort: profit|r" or (AS.db.settings.craftSort == "profit" and "|cffffd100Sort: profit|r" or "|cffaaaaaaSort: default|r"))
    RenderRows(view == "crafts" and craftRows or itemRows)
end

function AS.IsShown() return win and win:IsShown() end
function AS.SetShown(show) if not win then return end; win:SetShown(show); if show then AS.RefreshUI(true) end end
function AS.SetSearch(text) if edit then edit:SetText(text or ""); AS.RefreshUI() end end

local function SavePos()
    local p, _, rp, x, y = win:GetPoint(1)
    AS.db.pos = { p, rp, x, y }
end

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
function AS.InitUI()
    win = CreateFrame("Frame", "AltStashFrame", UIParent, BACKDROP_TMPL)
    win:SetSize(W, H)
    win:SetFrameStrata("MEDIUM")
    if win.SetToplevel then win:SetToplevel(true) end
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)
    SetBackdropSafe(win, WHITE, BORDER, 16, 4, { 0.05, 0.05, 0.07, 0.94 }, { 0.6, 0.6, 0.65, 1 })
    local pos = AS.db.pos
    if type(pos) == "table" and pos[1] then win:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0) else win:SetPoint("CENTER", UIParent, "CENTER", -300, 0) end
    local cdTick = 0
    win:SetScript("OnShow", function() cdTick = 0; AS.RefreshUI(true) end)
    -- live cooldown countdown: cheap refresh every AS.CD_TICK seconds, only while the window is shown (OnUpdate stops when hidden)
    win:SetScript("OnUpdate", function(_, elapsed)
        cdTick = cdTick + (tonumber(elapsed) or 0)
        if cdTick >= (AS.CD_TICK or 30) then cdTick = 0; AS.RefreshUI() end
    end)

    -- title bar
    local tb = win:CreateTexture(nil, "BORDER")
    tb:SetPoint("TOPLEFT", 4, -4)
    tb:SetPoint("TOPRIGHT", -4, -4)
    tb:SetHeight(TITLE_H - 4)
    tb:SetColorTexture(0.13, 0.13, 0.18, 1)
    local tline = win:CreateTexture(nil, "ARTWORK")
    tline:SetPoint("TOPLEFT", tb, "BOTTOMLEFT", 0, 0)
    tline:SetPoint("TOPRIGHT", tb, "BOTTOMRIGHT", 0, 0)
    tline:SetHeight(1)
    tline:SetColorTexture(1, 0.82, 0, 0.45)
    local ticon = win:CreateTexture(nil, "ARTWORK")
    ticon:SetSize(18, 18)
    ticon:SetPoint("LEFT", tb, "LEFT", 6, 0)
    ticon:SetTexture(BAG_ICON)
    ticon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", ticon, "RIGHT", 6, 0)
    title:SetText("AltStash")
    local ver = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ver:SetPoint("LEFT", title, "RIGHT", 6, -1)
    ver:SetText("v" .. tostring(AS.version))

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("RIGHT", tb, "RIGHT", 4, 0)
    close:SetScript("OnClick", function() win:Hide() end)

    edit = CreateFrame("EditBox", "AltStashSearchBox", win, "InputBoxTemplate")
    edit:SetSize(190, 20)
    edit:SetPoint("RIGHT", close, "LEFT", -6, 0)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(60)
    edit:SetScript("OnTextChanged", function() if ui.scroll then ui.scroll:SetVerticalScroll(0) end; AS.RefreshUI() end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusGained", function() if ui.placeholder then ui.placeholder:Hide() end end)
    edit:SetScript("OnEditFocusLost", function(self) if ui.placeholder then ui.placeholder:SetShown((self:GetText() or "") == "") end end)
    ui.placeholder = edit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.placeholder:SetPoint("LEFT", 2, 0)
    ui.placeholder:SetText("Search items...")

    -- tab row (+ scroll arrows when there are more characters than fit)
    ui.prev = CreateFrame("Button", nil, win)
    ui.prev:SetSize(ARROW_W, ARROW_W)
    ui.prev:SetPoint("TOPLEFT", PAD, TAB_Y - (TAB_SIZE - ARROW_W) / 2)
    ui.prev:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
    ui.prev:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
    ui.prev:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Disabled")
    ui.prev:SetScript("OnClick", function() AS.ScrollTabs(-1) end)
    ui.next = CreateFrame("Button", nil, win)
    ui.next:SetSize(ARROW_W, ARROW_W)
    ui.next:SetPoint("TOPRIGHT", -PAD, TAB_Y - (TAB_SIZE - ARROW_W) / 2)
    ui.next:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    ui.next:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    ui.next:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Disabled")
    ui.next:SetScript("OnClick", function() AS.ScrollTabs(1) end)
    ui.tabBar = CreateFrame("Frame", nil, win)
    ui.tabBar:SetPoint("TOPLEFT", PAD + ARROW_W + 4, TAB_Y)
    ui.tabBar:SetSize(TABBAR_W, TAB_SIZE + 6)
    ui.tabBar:EnableMouseWheel(true)
    ui.tabBar:SetScript("OnMouseWheel", function(_, delta) AS.ScrollTabs(-delta) end)

    -- character header
    local hdr = CreateFrame("Frame", nil, win, BACKDROP_TMPL)
    hdr:SetPoint("TOPLEFT", PAD, HEADER_Y)
    hdr:SetPoint("TOPRIGHT", -PAD, HEADER_Y)
    hdr:SetHeight(38)
    SetBackdropSafe(hdr, WHITE, nil, 0, 0, { 1, 1, 1, 0.04 })
    ui.headerIcon = hdr:CreateTexture(nil, "ARTWORK")
    ui.headerIcon:SetSize(30, 30)
    ui.headerIcon:SetPoint("LEFT", 4, 0)
    ui.charName = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.charName:SetPoint("TOPLEFT", ui.headerIcon, "TOPRIGHT", 8, 0)
    ui.charDesc = hdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.charDesc:SetPoint("BOTTOMLEFT", ui.headerIcon, "BOTTOMRIGHT", 8, 0)
    ui.charGold = hdr:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.charGold:SetPoint("TOPRIGHT", -6, -4)
    ui.charGold:SetJustifyH("RIGHT")
    ui.charScan = hdr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.charScan:SetPoint("BOTTOMRIGHT", -6, 4)
    ui.charScan:SetJustifyH("RIGHT")

    -- Items / Craftables sub-tabs
    local function SubTab(label, view)
        local b = CreateFrame("Button", nil, win)
        b:SetHeight(22)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.label:SetPoint("CENTER", 0, 1)
        b.label:SetText(label)
        b.bar = b:CreateTexture(nil, "ARTWORK")
        b.bar:SetColorTexture(1, 0.82, 0, 1)
        b.bar:SetHeight(2)
        b.bar:SetPoint("BOTTOMLEFT", 4, 0)
        b.bar:SetPoint("BOTTOMRIGHT", -4, 0)
        b:SetHighlightTexture(WHITE, "ADD")
        local hl = b:GetHighlightTexture()
        if hl then hl:SetVertexColor(1, 1, 1, 0.08) end
        b:SetScript("OnClick", function() AS.SetView(view) end)
        return b
    end
    ui.subItems = SubTab("Items", "items")
    ui.subItems:SetPoint("TOPLEFT", PAD, SUB_Y)
    ui.subCrafts = SubTab("Craftables", "crafts")
    ui.subCrafts:SetPoint("LEFT", ui.subItems, "RIGHT", 6, 0)
    ui.nowCheck = CreateFrame("CheckButton", "AltStashCraftNowCheck", win, "UICheckButtonTemplate")
    ui.nowCheck:SetSize(22, 22)
    ui.nowCheck:SetPoint("TOPRIGHT", -PAD - 74, SUB_Y)
    local nowText = ui.nowCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nowText:SetPoint("LEFT", ui.nowCheck, "RIGHT", 2, 0)
    nowText:SetText("Can make now")
    ui.nowCheck:SetScript("OnClick", function(self) AS.db.settings.craftNowOnly = self:GetChecked() and true or false; AS.RefreshUI() end)
    -- 0.3.8: Items view "Safe to sell / delete" filter
    ui.safeCheck = CreateFrame("CheckButton", "AltStashSafeCheck", win, "UICheckButtonTemplate")
    ui.safeCheck:SetSize(22, 22)
    ui.safeCheck:SetPoint("TOPRIGHT", -PAD - 112, SUB_Y)
    local safeText = ui.safeCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    safeText:SetPoint("LEFT", ui.safeCheck, "RIGHT", 1, 0)
    safeText:SetText("Safe to sell / delete")
    ui.safeCheck:SetScript("OnClick", function(self) AS.db.settings.itemsSafeOnly = self:GetChecked() and true or false; AS.RefreshUI() end)
    ui.safeCheck:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Safe to sell / delete", 1, 0.82, 0)
        GameTooltip:AddLine("Only items not needed by any quest in your characters' saved quest logs and not used by any saved ProfTracker recipe (plus quest items whose quest this character has completed). Gear is never listed. Quests not picked up yet and recipes not learned are unknown to AltStash.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ui.safeCheck:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    -- 0.3.5 (Auctionator prices): "Profitable" filter + profit sort toggle; shown only in Craftables with Auctionator loaded
    ui.profitCheck = CreateFrame("CheckButton", "AltStashProfitCheck", win, "UICheckButtonTemplate")
    ui.profitCheck:SetSize(22, 22)
    ui.profitCheck:SetPoint("RIGHT", ui.nowCheck, "LEFT", -64, 0)
    local profitText = ui.profitCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profitText:SetPoint("LEFT", ui.profitCheck, "RIGHT", 1, 0)
    profitText:SetText("Profitable")
    ui.profitCheck:SetScript("OnClick", function(self) AS.db.settings.craftProfitOnly = self:GetChecked() and true or false; AS.RefreshUI() end)
    ui.profitCheck:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Profitable only", 1, 0.82, 0)
        GameTooltip:AddLine("Show only recipes where crafting and selling nets more than selling the materials, highest profit first (Auctionator prices, after the 5% AH cut and deposits).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ui.profitCheck:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    ui.sortBtn = CreateFrame("Button", "AltStashSortButton", win)
    ui.sortBtn:SetSize(62, 18)
    ui.sortBtn:SetPoint("RIGHT", ui.profitCheck, "LEFT", -6, 0)
    ui.sortBtn.label = ui.sortBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.sortBtn.label:SetPoint("CENTER")
    ui.sortBtn:SetHighlightTexture(WHITE, "ADD")
    local shl = ui.sortBtn:GetHighlightTexture()
    if shl then shl:SetVertexColor(1, 1, 1, 0.08) end
    ui.sortBtn:SetScript("OnClick", function()
        if AS.db.settings.craftProfitOnly == true then return end   -- Profitable on: always by profit
        if AS.db.settings.craftSort == "profit" then AS.db.settings.craftSort = nil else AS.db.settings.craftSort = "profit" end
        AS.RefreshUI()
    end)
    ui.sortBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Sort Craftables", 1, 0.82, 0)
        GameTooltip:AddLine("Click to switch between craftable-first and highest profit first for the full list.", 1, 1, 1, true)
        if AS.db.settings.craftProfitOnly == true then GameTooltip:AddLine("Profitable is ticked: sorted by profit (untick to use this setting again).", 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
    end)
    ui.sortBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- list inset + scroll frame
    local inset = CreateFrame("Frame", nil, win, BACKDROP_TMPL)
    inset:SetPoint("TOPLEFT", PAD, LIST_TOP)
    inset:SetPoint("BOTTOMRIGHT", -PAD, FOOTER_H)
    SetBackdropSafe(inset, WHITE, BORDER, 12, 3, { 0, 0, 0, 0.45 }, { 0.35, 0.35, 0.4, 1 })
    ui.inset = inset
    scroll = CreateFrame("ScrollFrame", "AltStashScroll", inset, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    ui.scroll = scroll
    local holder = CreateFrame("Frame", nil, scroll)
    holder:SetSize(LIST_W, 10)
    scroll:SetScrollChild(holder)
    ui.holder = holder
    content = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    content:SetPoint("TOPLEFT", 4, -2)
    content:SetWidth(LIST_W - 8)
    content:SetJustifyH("LEFT")
    content:SetJustifyV("TOP")
    content.holder = holder

    -- footer
    check = CreateFrame("CheckButton", "AltStashTradeableCheck", win, "UICheckButtonTemplate")
    check:SetPoint("BOTTOMLEFT", PAD - 2, 14)
    check:SetSize(24, 24)
    check:SetChecked(AS.TradeableOnly())
    local ctext = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ctext:SetPoint("LEFT", check, "RIGHT", 2, 0)
    ctext:SetText("Tradeable only")
    check:SetScript("OnClick", function(self) AS.SetTradeable(self:GetChecked() and true or false, true) end)
    check:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Tradeable only")
        GameTooltip:AddLine("Hide soulbound / untradeable items (they are still saved).", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    check:SetScript("OnLeave", RowOnLeave)

    local tlabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tlabel:SetPoint("BOTTOMLEFT", 150, 22)
    tlabel:SetText("Type:")
    pcall(AS.BuildTypeDropdown, win)
    if AS.typeDropdown and AS.typeDropdown.frame then
        local f = AS.typeDropdown.frame
        if AS.typeDropdown.kind == "udd" then f:SetPoint("BOTTOMLEFT", 165, 10) else f:SetPoint("BOTTOMLEFT", 186, 15) end
    end
    ui.total = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.total:SetPoint("BOTTOMRIGHT", -PAD - 2, 22)
    ui.total:SetJustifyH("RIGHT")

    -- live portrait of the logged-in character can change (gear/helm/shapeshift): refresh it while the window is open
    local ev = CreateFrame("Frame", nil, win)
    pcall(ev.RegisterEvent, ev, "UNIT_PORTRAIT_UPDATE")
    pcall(ev.RegisterEvent, ev, "PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", function(_, event, unit)
        if event == "UNIT_PORTRAIT_UPDATE" and unit ~= "player" then return end
        if win:IsShown() then AS.RefreshUI(true) end
    end)

    if UISpecialFrames then tinsert(UISpecialFrames, "AltStashFrame") end
    win:Hide()
end
