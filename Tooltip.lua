-- AltStash: item tooltip addition ("Alts have: Name x N"). Display only.
local ADDON, AS = ...

local MAX_LINES = 8

local function AddAltLines(tooltip, itemID)
    if not (AS.db and itemID) then return end
    if issecretvalue and issecretvalue(itemID) then return end
    if not tooltip or not tooltip.AddLine then return end
    local me = AS.CurrentKey()
    local holders, total = {}, 0
    for _, h in ipairs(AS.Holders(itemID)) do
        if h.key ~= me then
            local n = h.bag + h.bank + h.mail
            if n > 0 then holders[#holders + 1] = { h = h, n = n }; total = total + n end
        end
    end
    if #holders == 0 then return end
    table.sort(holders, function(a, b) return AS.UniqueLabel(a.h.key):lower() < AS.UniqueLabel(b.h.key):lower() end)
    tooltip:AddLine(" ")
    tooltip:AddLine(string.format("|cff33ccffAlts have:|r %d total", total))
    for i = 1, math.min(#holders, MAX_LINES) do
        local h = holders[i].h
        local parts = {}
        if h.bag > 0 then parts[#parts + 1] = "bags " .. h.bag end
        if h.bank > 0 then parts[#parts + 1] = "bank " .. h.bank end
        if h.mail > 0 then parts[#parts + 1] = "mail " .. h.mail end
        local label = AS.UniqueLabel(h.key)
        local c = RAID_CLASS_COLORS and h.rec.classFile and RAID_CLASS_COLORS[h.rec.classFile]
        local name = c and string.format("|cff%02x%02x%02x%s|r", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), label) or label
        tooltip:AddLine(string.format("  %s x %d  |cff999999(%s)|r", name, holders[i].n, table.concat(parts, ", ")))
    end
    if #holders > MAX_LINES then tooltip:AddLine(string.format("  |cff999999+%d more characters|r", #holders - MAX_LINES)) end
end
AS._AddAltLines = AddAltLines

-- 0.3.9: one usage line (Quest done - safe to delete / Needed for ... / Crafting reagent / Safe to sell) on the game's
-- item tooltip, from the logged-in character's point of view. Skipped inside AltStash's own rows (they show the details).
local function AddUsageLine(tooltip, itemID)
    if AS._rowTooltip or not (AS.db and AS.Usage and AS.Usage.Enabled()) then return end
    if type(itemID) ~= "number" or (issecretvalue and issecretvalue(itemID)) then return end
    if not tooltip or not tooltip.AddLine then return end
    local u = AS.Usage.UsageForTooltip(itemID)
    local line = u and AS.Usage.TooltipLine(u)
    if line then tooltip:AddLine(line, 1, 1, 1, true) end
end
AS._AddUsageLine = AddUsageLine

local function AddAll(tooltip, itemID)
    AddAltLines(tooltip, itemID)
    local ok = pcall(AddUsageLine, tooltip, itemID)
    if not ok then AS.tooltipErrors = (AS.tooltipErrors or 0) + 1 end
end
AS._AddAllTooltipLines = AddAll

local hooked = false
function AS.InitTooltip()
    if hooked then return end
    -- Preferred (modern client API, 10.0.2+): TooltipDataProcessor post-call.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
        and Enum.TooltipDataType.Item then
        local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
            if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
            local ok2 = pcall(function() AddAll(tooltip, data and data.id) end)
            if not ok2 then AS.tooltipErrors = (AS.tooltipErrors or 0) + 1 end
        end)
        if ok then hooked = "TooltipDataProcessor"; return end
    end
    -- Fallback (pre-10.0.2 style): GameTooltip OnTooltipSetItem script.
    local function legacy(tooltip)
        pcall(function()
            local _, link = tooltip:GetItem()
            local id = link and tonumber(tostring(link):match("item:(%d+)"))
            AddAll(tooltip, id)
        end)
    end
    local okA = pcall(function() GameTooltip:HookScript("OnTooltipSetItem", legacy) end)
    pcall(function() ItemRefTooltip:HookScript("OnTooltipSetItem", legacy) end)
    if okA then hooked = "OnTooltipSetItem" end
end
function AS.TooltipHookKind() return hooked end
