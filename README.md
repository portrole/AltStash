# AltStash 0.4.0

Find an item across all your characters' **bags, bank and mail** (e.g. a crafting reagent you know one of your alts is holding).
Passive only: it reads what the client already shows you and saves it to SavedVariables. It never moves, uses, loots, sends or
clicks anything, calls no protected functions, and does not read the screen.

Built for the **WoW: Forever** client 1.60.1 (`## Interface: 16001`).

Originally started by **Jojo**, a helper bot, and extended by **Demnock**.

## Requirements
- WoW: Forever client 1.60.1
- Optional: **ProfTracker** — Craftables, profession cooldowns, and crafting-usage tags
- Optional: **Auctionator** — craft-or-sell advice and AH sell values in the Items list

## Window (0.3.0 redesign)
- **Title bar** with the search box and a close button; the whole frame is draggable and its position is saved (`AltStashDB.pos`); Esc closes it.
- **Character tabs along the top**, one per saved character, plus a first **All characters** tab (bag icon) that keeps the old cross-character search view. Hover a tab for name, level / race / class, realm, gold and scan ages. The selected tab has a gold border and gold underline; hovering shows the standard highlight. **Search highlight (0.3.2):** while the search box has text, every character tab with a match gets a **green outline** (drawn just outside the tab, so a selected tab that matches shows green around its gold border plus the gold underline). A match = at least one item found by the same search the All characters view uses (item name substring or exact item id, honouring the Tradeable-only and Type filters, active auction listings included), or, with ProfTracker loaded, a saved recipe whose name or output item matches. It updates as you type, scrolled-off tabs show the right state when they come back, the tab tooltip shows "Matches \"text\": N items, M recipes", and clearing the box removes all green. The All characters tab is never green; a level badge sits in the corner. If there are more characters than fit (9 plus All), arrow buttons appear and the mouse wheel scrolls the tab row. The selected tab is remembered (`settings.uiTab`).
- **Portraits:** the logged-in character uses the live 3D portrait (`SetPortraitTexture(tex, "player")`, refreshed on `UNIT_PORTRAIT_UPDATE`). WoW can't render or cache a portrait for a character that isn't logged in, so **offline alts show a race + gender icon** from data saved at their last login (`raceicon128-<race>-<sex>` / `raceicon-<race>-<sex>` atlas if the client has it, else `RACE_ICON_TCOORDS` on the character-create race sheet), then the **class icon** (`UI-Classes-Circles`), then a question mark. Characters saved before 0.3.0 show the class icon until you log in on them once.
- **Character header:** portrait, class-coloured name, "Level 56 Undead Paladin", realm, gold, and scan ages for bags / bank / mail.
- **Items / Craftables sub-tabs:**
  - *Items:* grouped by item type (Trade Goods, Reagent, Consumable, ...), each row with the item icon, a quality-coloured name, where it is (bags / bank / mail) and the total. Hover for the item tooltip (plus the "Alts have" lines); Shift-click links the item in chat. Active auction listings are listed in an "Auction House" section at the end.
  - *Craftables:* read from the **ProfTracker** add-on's saved recipes (optional; `_G.ProfTracker`, read-only). For each profession: skill level, then every learned recipe with its output icon, a coloured bar for skill-up difficulty (orange / yellow / green / white) and **how many you can make** with the tradeable materials of all your characters (the "own mats" number = this character's own bags/bank/mail). Craftable recipes are listed first; "Only what I can make" hides the rest. Hover a recipe for the output item tooltip, reagents and how many of each you have. Without ProfTracker the tab says how to enable it.
  - *Cooldowns (0.3.3, needs ProfTracker 0.1.4+):* recipes with a cooldown (transmutes, Mooncloth, Refined Deeprock Salt / Salt Shaker, or any recipe the game has reported on cooldown) show a clock icon and the time left (e.g. `17h 23m`) in red/orange, or a green **Ready**. Shared cooldowns (all transmutes) show on every transmute. Hover for "Ready at <day date, time>" in your local time, whether it is shared, and when it was last checked. Works for offline alts: ProfTracker saves the absolute ready time (epoch seconds), so the countdown stays right after you log out. The list refreshes every 30 s while the window is open. A small clock icon in a character tab's top-left corner = at least one profession cooldown is ready on that character (tooltip: "Profession cooldowns ready: N", "On cooldown: N (next ready in ...)"). Data from an older ProfTracker without cooldown fields simply shows no cooldowns. *0.3.4 fix:* times more than 7 days out (the "50d 22h" bug from ProfTracker 0.1.4, caused by a 32-bit GetTime() wrap) are corrected or hidden; use ProfTracker 0.1.5+, which also repairs the saved data.
- The search box, the Tradeable-only checkbox and the item-type drop-down apply to every tab.
- New saved fields (all optional, schema stays **3**, older data loads unchanged): per character `race`, `raceFile`, `raceID`, `sex`, `level` (updated at login and on `PLAYER_LEVEL_UP`); settings `uiTab`, `uiView`, `craftNowOnly`.

## What is it used for? Safe to sell / delete (0.3.8)

Each row in a character's **Items** list gets a usage tag, explained in the tooltip:

- **Quest** (yellow): a quest item (item class Quest or quest bind type), or an item that is an objective of a quest in **any** of your characters' saved quest logs (tooltip: `Quest: Scarlet Menace (Demnock) 3/10`). A quest item that isn't in the quest database says **Quest item: can't confirm, keep** and is never marked safe (0.4.0).
- **Quest done: safe to delete** (green): since 0.4.0 only when the built-in quest database maps the item to quest IDs **and** every quest that uses it, plus the later steps of those chains, is completed on that character (`C_QuestLog.IsQuestFlaggedCompleted` / Classic `IsQuestFlaggedCompleted`), **and** none is active on any character, **and** no saved recipe uses it. See "Quest database cross-reference (0.4.0)" below. Completed only by another character is noted but not marked safe (quest items are usually per character).
- **Keep** (orange): you marked the item with `/as keep`; never shown as safe.
- **Crafting** (teal): a reagent of a recipe known by any character (ProfTracker data). Tooltip: `Used in: 2 recipes (Alchemy: Major Mana Potion, ...)` and `Crafted by: Demnock, ...`. Unused trade goods say "Trade Goods (crafting material, not used by your saved recipes)".
- **Gear** (grey): weapons / armour are never judged.
- **Safe to sell** (green-grey): none of the above, the character holds tradeable units, and the item has a vendor or Auctionator price. The vendor sell price is shown on the row (when there's no AH price) and in the tooltip.
- No tag: soulbound misc items (e.g. Hearthstone), recipes (an alt might learn it), items whose info isn't loaded yet.
- **Safe to sell / delete** checkbox (Items view): only Safe to sell and Quest done items, with a summary line (count, vendor value, AH value with Auctionator). `/as usage off` hides everything. The All characters tab (plain text) has no tags.

**On the game's own item tooltip (0.3.9).** Hovering any item anywhere (bags, bank, chat links) adds one AltStash line, from the logged-in character's point of view: green **AltStash: Quest done — safe to delete**, yellow **AltStash: Needed for <quest> (<character>)**, **AltStash: Keep: quest chain not finished (<quest>, <ID>)**, **AltStash: Quest item: can't confirm, keep**, orange **AltStash: Keep (marked by you)**, teal **AltStash: Crafting reagent (N recipes)** or **AltStash: Safe to sell** (gear: no line). It's added through the same hook as "Alts have" (`TooltipDataProcessor`, or `OnTooltipSetItem` on older clients) and is skipped inside AltStash's own window, which shows the full details. `/as usage off` turns it off.

**Leftover quest items (0.3.9).** To know which quest a leftover item belongs to, AltStash uses, in order: the game's own link for items in your bags (`C_Container.GetContainerItemQuestInfo` / Classic `GetContainerItemQuestInfo`: quest ID and whether that quest is active), quest objectives in your logs, and items you **received at a quest turn-in** (`QUEST_LOOT_RECEIVED`, or your own "You receive item" loot message within 5 seconds of `QUEST_TURNED_IN`). Since 0.4.0 these are only extra evidence; the safe / keep decision follows the quest database rules below.

**How the data is collected:** each character's quest log is saved on login and whenever it changes (`QUEST_LOG_UPDATE`, `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN`; modern `C_QuestLog.GetInfo` / `GetQuestObjectives`, Classic `GetQuestLogTitle` / `GetQuestLogLeaderBoard`). Item objectives are matched **by item name**. Quest items seen in the bags (`GetContainerItemQuestInfo`) and objectives are remembered as item -> quest (`AltStashDB.questItems`), and each character's completed state for those quests is saved (`chars[..].questsDone`). Optional fields; schema stays 3.

**Limits (please read):** AltStash only knows quests that are (or were, while it ran) in a saved quest log, and recipes ProfTracker has saved. Since 0.4.0 the built-in quest database covers quests you haven't picked up and later chain steps for quest items in it; it still can't know recipes you haven't learned yet. Characters you haven't logged in on since 0.3.8 have no saved quest log (the tooltip says how many are missing). In the Classic quest API, quests under a collapsed quest-log header may be skipped. Treat "Safe to sell" as "not needed by anything AltStash knows about".

## Quest database cross-reference (0.4.0)

0.3.8 / 0.3.9 linked each item to **one** quest and called it safe once that quest was completed. That was wrong for chains: an item received when you turned in step 1 (or given for step 2) was marked "safe" while a later step that you hadn't picked up yet still needed it. Example (rogue level 20, Horde): *Fizzule's Whistle* (8066) arrives when you turn in **Deep Cover** (2458) and is required by **Mission: Possible But Not Probable** (2478); 0.3.9 linked it to 2458 only.

0.4.0 ships `QuestItemDB.lua`, an item -> quest lookup with chain data, and uses these rules:

- Every quest that uses the item is collected: from the database (objective, item given when you accept, required item, quest starter, quest-reward hint) **and** from the game (bag quest link, quest-log objectives). The later steps of those chains (next quest in the chain and direct follow-ups) are added too.
- Quests that can't apply to the character (race / class masks) and quests whose exclusive alternative (or breadcrumb target) is done are skipped. A repeatable quest that uses the item always keeps it.
- **Quest done: safe to delete** only when the item is in the database, every remaining quest is completed on this character and none is active on any character.
- Otherwise: **Keep: quest chain not finished (<next quest>, <ID>)**, **Keep: needed for ...**, or **Quest item: can't confirm, keep** (not in the database, or a quest ID the database doesn't know). The turn-in heuristic and the game's bag quest ID can keep an item, but never make it safe on their own. When in doubt, AltStash keeps.
- Non-quest-class items (cloth, tools, ...) are judged as before, except that an item given or required by a **class** quest you still have to do shows **Keep**.
- The Items-view tags, the **Safe to sell / delete** filter and the game-tooltip line use the same rules. Hold **Shift** over an item to see the quest IDs and each one's state on the tooltip.
- Completion is read live for the logged-in character and saved per character (`chars[..].questsDone`) for the quests of the items it holds, so alts are judged from their last login (unknown = not done = keep).

**Data source and license.** `QuestItemDB.lua` is generated from **QuestieDB** 1.1.6, Forever flavor (baked data, build commit `4377c981ac`, https://github.com/Questie/QuestieDB), which converts the Classic Era data for WoW Forever and adds Forever corrections. It contains only quest-related items: 4,072 items (2,992 of them quest-class) and 4,735 quests (name, next quest, race / class masks, repeatable flag, prerequisites, exclusiveTo, follow-ups, breadcrumbs). QuestieDB / Questie data historically had no license; the QuestieDB team allows copying under **GPLv3** terms but can't promise that for every historic contributor ("when in doubt, all rights reserved"). If you redistribute AltStash with this file, do it under GPLv3-compatible terms, credit QuestieDB, and don't use the Questie name or logo. AltStash is not affiliated with Questie.

**Limits.** QuestieDB's Forever data is a converted Era baseline plus Forever corrections: brand-new Forever quests or reworked chains that aren't in it yet show "can't confirm, keep" (or rely on the game's own quest link). Race / class masks for new Forever races come from QuestieDB. Use `/as questinfo <item>` to see exactly why an item got its verdict, and `/as keep <item>` to protect anything you're unsure about.

## Craft or sell? (0.3.5, needs Auctionator)

With **Auctionator** loaded (optional; listed in `## OptionalDeps`) and an AH scan done, every recipe in **Craftables** gets advice, using only Auctionator's public API (`Auctionator.API.v1.GetAuctionPriceByItemID`, `GetAuctionAgeByItemID`, `GetVendorPriceByItemID`, `RegisterForDBUpdate`; never its saved variables):

- Row: green **+1g 20s** = craft and sell (profit shown), orange **sell mats** = the materials are worth more, grey **even**, dim **no price** = Auctionator has no price for the crafted item or a reagent. A grey `*` = a price is older than 3 days (or its age is unknown): rescan.
- Tooltip breakdown: each reagent's AH price x quantity (vendor reagents such as vials at their vendor price), AH cut and deposit on the materials, "Sell mats nets", crafted item price x yield, AH cut 5%, deposit, "Craft & sell nets", **Profit vs selling mats**, the advice, "If you buy the mats" (profit when you buy every reagent at the AH / vendor price) and the oldest scan age.
- **Profitable** checkbox (0.3.6): shows only recipes advised "Craft & sell", **sorted by profit, highest first**. Unticking brings back the full list in your saved order. The **Sort: profit / default** button stays for ordering the full list (greyed while Profitable is ticked). Cooldown recipes (transmutes) still show, with both the cooldown and the advice. Without Auctionator a one-line note appears at the bottom of Craftables (`/as prices off` hides everything).

**Items view AH value (0.3.7).** With Auctionator, each character's Items list shows the AH price for **Trade Goods, Consumables, Reagents, Gems and Recipes** (gear, bags, quest and misc items are skipped: their prices depend on the roll or they rarely sell): unit price, plus the total for the count held when it is more than 1 (e.g. `12s 40c ea · 2g 48s`), a grey `*` when the price is older than 3 days, dim `no price` when Auctionator has none. The group header adds the AH value of the priced items (`AH 31g 20s`). The item tooltip shows the price each, the total, the total after the 5% AH cut and the scan age. Same toggle: `/as prices off`. These are Auctionator's last scanned prices, not a guarantee of what will sell.

**The logic (simple on purpose).** Both choices are valued as "sell it on the AH now", so it is the same comparison whether you already own the materials or would buy them:
- *Sell mats* = sum over reagents of (AH price x qty - 5% cut - deposit). Reagents with no AH price but a known vendor price count at that vendor price (you would simply not buy / keep them; no cut, no deposit).
- *Craft & sell* = crafted AH price x yield (average for a min-max yield) - 5% cut - deposit.
- *Profit* = craft - sell mats. **Craft & sell** when profit is at least the larger of 1 silver and 5% of the materials' value; **Sell mats** when it is that far below zero; otherwise **Even**.
- **Deposits** are counted on both sides as money at risk: refunded when the auction sells, lost if it expires or you cancel. Per auction: max(minimum deposit, rate x vendor sell price x stack), items posted in full stacks (max stack size), so a craft's share is per item. Rates (WoW: Forever / Classic faction AH): **2h 5%, 8h 20%, 24h 60%** of the vendor sell price; default **24h** (`/as deposit 2|8|24`; 12/48 accepted for modern AHs at 15%/60%). Minimum deposit per auction defaults to **1 silver** (Forever launched with it; Blizzard announced a return to 1c): `/as mindeposit <copper>`. If the client has `C_AuctionHouse.CalculateCommodityDeposit` it is used instead of the formula (Classic's `CalculateAuctionDeposit` only works for the item in the sell slot, so it can't be used here). An item whose vendor price isn't cached yet uses the minimum deposit.
- Prices are Auctionator's last scanned (lowest) buyout per item; the advice is only as fresh as your last scan. No undercutting, sell-through rate or neutral AH (15% cut) is modelled.

## Features
- Saves per character: realm, name, class, last-scanned time per location, and for each item: item id, **name**, and counts in **bags / bank / mail**. Item links are not stored (smaller SavedVariables); they are built from the item id when shown.
- Small movable search window: type in the box, results filter live (case-insensitive substring of the item name; all-digit text matches an item id). Results are grouped by character, in class colour, with counts, location and how long ago each location was scanned. Empty box = list of saved characters.
- Item tooltips get an **"Alts have: Name x N (bags, bank, mail)"** section (other characters only).
- Data schema version (`AltStashDB.schemaVersion`, currently 3). Version 1 data (full links) is migrated automatically with counts kept; schema 3 re-keys characters by GUID (see "Character names and keys"); a save from a newer version is never touched or overwritten.
- Items whose name the client hasn't cached yet show as `Item <id>`; AltStash asks the client for the data (`C_Item.RequestLoadItemDataByID`) and the real name appears on the next refresh.

- **Tradeable only** filter (default ON, saved): hides soulbound / untradeable items so you only see things you can move between alts. Applied at *display* time (search window, `/as list` counts and the tooltip), so `/as tradeable off` or the window checkbox takes effect immediately without re-scanning anyone. Non-tradeable items are still stored, just flagged.

- **Item type filter** (drop-down at the bottom of the window, saved): All types; Trade Goods with its subclasses (Cloth, Leather, Metal & Stone, Herb, Meat/Cooking, Elemental, Enchanting, Parts, Jewelcrafting, plus "Other trade goods" for any other trade-goods subclass); Gem, Consumable, Weapon, Armor, Container, Recipe, Quest, Miscellaneous, Reagent and "Other types" so nothing is unreachable. Labels are the game's own localized names (`GetItemClassInfo` / `GetItemSubClassInfo`). Classic has no separate "Fish" subclass (fish are Cooking/Meat or Consumable), so there is no Fish entry. Works with the text box *and* the tradeable filter; with an empty box it lists matching items grouped by character (gold and auction sections stay visible). Item class/subclass come from `GetItemInfoInstant` (synchronous), are stored per item at scan time, and are back-filled for already-saved items on login, so you don't need to revisit alts. Drop-down uses the modern Menu system if present, else `UIDropDownMenuTemplate`, else a simple popup list; `/as type <name|all>` always works.

- **Public API for other add-ons** (0.2.0, read-only, adds nothing to the saved data): `AltStash.API` (`apiVersion = 1`, `version`) with `GetCharacters()`, `GetCharacterCounts(itemID [, honorTradeableFilter])` (per character: bag/bank/mail/total + names), `GetTotalCount(itemID [, honorTradeableFilter])` (total, bag, bank, mail), `GetItemCount(key, itemID [, honorTradeableFilter])` and `GetCurrentKey()`. `honorTradeableFilter` (default false): `true` applies the user's "tradeable only" setting, `"always"` (API minorVersion 1, AltStash 0.2.1) hides soulbound units regardless of the setting. Used by ProfTracker (OptionalDeps).

## Commands (`/as` or `/altstash`)
| Command | Does |
|---|---|
| `/as` | Toggle the AltStash window |
| `/as char <name>` / `/as char all` | Open the window on that character's tab / the All characters tab |
| `/as show` / `hide` | Show / hide it |
| `/as search <text>` | Open the window filtered by `<text>` |
| `/as tradeable on\|off` | Toggle the tradeable-only filter (no argument shows the current state). Also a checkbox in the window |
| `/as type <name\|all>` | Filter by item type, e.g. `/as type cloth`, `/as type herb`, `/as type armor`; `/as type all` resets; no argument lists the types |
| `/as list` | Saved characters and scan ages |
| `/as reset <character>` | Forget one character: full display name, first or second name, `Name-Realm`, or the `[suffix]` shown in lists. If several match, nothing is removed and the matches are listed with their GUID suffix |
| `/as auctions on|off` | Show/hide the saved auction-listings section (default on; data is kept while hidden) |
| `/as auctions clear [character]` | Forget settled auction history (sold / expired / cancelled mails, "gone" entries) and the sold total; active listings stay |
| `/as debugauctions` | Print every key/value returned by `GetOwnedAuctions`, `GetAuctionInfoByID`, `GetOwnedAuctionInfo`, `GetTimeLeftBandInfo` and the legacy owner calls (open the AH first) - paste it if time left is unknown |
| `/as debugname` | Print raw UnitName/UnitFullName/GetUnitName/candidate second-name API values (paste it to confirm how Forever exposes the second name) |
| `/as prices on\|off` | Show/hide Auctionator craft-or-sell advice and AH item values |
| `/as usage on\|off` | Show/hide Quest / Crafting / Safe to sell tags and the bag-tooltip line |
| `/as keep <item link or ID>` | Never show the item as safe to sell / delete (no argument lists your keep list) |
| `/as unkeep <item link or ID\|all>` | Remove an item (or everything) from the keep list |
| `/as questinfo <item link or ID>` | Print the item's quest IDs, names, roles, per-quest completion on this character and the verdict reason |
| `/as deposit 2\|8\|24` | Auction duration used for deposit estimates (default 24h) |
| `/as mindeposit <copper>` | Minimum deposit per auction (default 100 = 1 silver) |
| `/as help` | Command list |

## Gold
- Each character's money (copper, `GetMoney()`) is saved with a `goldUpdated` time on login, on `PLAYER_MONEY` (debounced 0.3s) and on every scan. Optional fields, so the schema stays 3; old entries show "gold unknown" until that character logs in.
- Shown in the window header for each character (also with an empty search box), in `/as list`, with a total across all characters at the bottom of both. Uses `GetCoinTextureString` when present, else plain "12g 3s 4c". Not affected by the tradeable filter.

## Auction listings (own auctions)
- Read passively while the AH window is open: `AUCTION_HOUSE_SHOW` -> debounced read, and `OWNED_AUCTIONS_UPDATED` (legacy: `AUCTION_OWNED_LIST_UPDATE`) -> read. The add-on never calls `QueryOwnedAuctions`; the AH window's own Auctions tab triggers the update. An empty list is only trusted when it comes from the server update event (or `HasFullOwnedAuctionResults()` is true), so opening the AH never wipes stored listings by accident.
- Saved per character (optional fields, schema stays 3): `auctions = { {itemID, name, quantity, buyoutCopper, bidCopper, status "active"|"sold", timeLeftBand 0..3} }` and `ahScanned`.
- Shown under each character in the window (even with an empty search box) and in `/as list`: active count, each `Name x qty - buyout (time band)`, `Sold: Name x qty - price`, snapshot age; plus total buyout value tied up (active listings with a buyout) at the bottom. Searching by item name/id also matches active listings and labels them `auction N`. Not affected by the tradeable filter.
- Verified (warcraft.wiki.gg, Forever 1.60.1): `C_AuctionHouse.GetOwnedAuctions`, `GetNumOwnedAuctions`, `OWNED_AUCTIONS_UPDATED`, `Enum.AuctionStatus`, `Enum.AuctionHouseTimeLeftBand`. Unverified for Forever: the legacy `GetNumAuctionItems/GetAuctionItemInfo("owner")` fallback, `GetItemCommodityStatus` (used to treat commodity `buyoutAmount` as a per-unit price), and `HasFullOwnedAuctionResults`.
- Time left is derived from, in order: `timeLeftSeconds` (shown as "~1h 30m left", with an estimate from the snapshot age), the `timeLeft` band, `C_AuctionHouse.GetAuctionInfoByID(auctionID)` (documented fields have no time, tried defensively), `C_AuctionHouse.GetOwnedAuctionInfo(index)`, then legacy `GetAuctionItemTimeLeft("owner", index)`. Bands are shown as ranges: under 30m / up to 2h / up to 12h / up to 48h. If a listing never gets any time info it shows "time left unknown (first seen X ago)" - the end time is never invented, because the chosen duration isn't observable without hooking the post action. Listings are tracked by auctionID; first-seen time and any time info the client once gave are kept across scans.
- **Auctions that finish while the AH is closed:** each mailbox scan reads the mail *headers* (`GetInboxHeaderInfo`: subject, money, daysLeft; returned items are only read via `GetInboxItem`, nothing is opened or taken) and matches subjects against the game's own globals `AUCTION_SOLD/EXPIRED/REMOVED/WON/OUTBID_MAIL_SUBJECT`, converted to Lua patterns (locale independent, nothing hardcoded). Sold, expired and cancelled mails are saved per character with item name, quantity (from returned attachments, or a "(N)" suffix if the client adds one), payout (header `money`, i.e. after the AH fee; "price unknown" if already taken), days left and a mailKey. A mail is recognised again by subject + expiry time (money is not part of the match, so taking the money neither loses nor double counts a sale).
- **Vanished listings:** a listing active in the previous snapshot but missing from a later one becomes "Gone, status unknown" and leaves the tied-up total. A later sold/expired/cancelled mail settles it to "Sold" (price) or "Expired/returned" only when unambiguous: same item (and quantity when the mail has one), mail first seen no earlier than the listing, equal numbers of listings and mails with the same outcome. Otherwise it stays "gone, status unknown". A "gone" listing that reappears is restored. `GetInboxInvoiceInfo` is deliberately not used (it is meant for an opened mail).
- "Sold total since cleared" adds up sold payouts per character (and overall in the footer); `/as auctions clear` resets it.
- Data only updates when you open the AH (listings) or mailbox (sales/returns) on each character.

## Character names and keys
- Characters are saved under `UnitGUID("player")` (stable and unique), so two characters with the same first name on one realm never collide. Name fields (`name`, `firstName`, `secondName`, `displayName`) and `realm` are for display only and refreshed on every scan.
- Forever characters have a first name and a second name. VERIFIED in game (1.60.1, `/as debugname`): `UnitName("player")` / `UnitFullName` / `UnitNameUnmodified` return TWO values, first name and second name (NOT the realm); `GetUnitName("player", true|false)` returns "First Second". The realm comes from `GetRealmName()` ("Classic Beta PvE") / `GetNormalizedRealmName()` ("ClassicBetaPvE"). No dedicated second-name API exists (UnitSurname etc. are absent). A character with no second name returns nil for the second value and is shown by its first name only.
- If two saved characters still share a label, lists/results/tooltips add `[GUID suffix]`.
- Schema 3 migration: old `Name-Realm` entries are kept as-is (still listed and searchable, marked "old entry") and are moved to the GUID key the next time that character logs in (old entries only know the first name, so the FIRST name + realm + class must match; the realm is accepted spaced or normalized; the old key is removed). If several old entries match one login, the most recently scanned is claimed and the rest are kept. Caveat: if two characters with the same first name already shared one old entry, the first one to log in claims it and its next scans overwrite the mixed data.

## When data updates (important)
- **Bags**: on login and whenever bags change (`BAG_UPDATE_DELAYED`).
- **Bank**: only while the bank window is open (`BANKFRAME_OPENED`, `PLAYERBANKSLOTS_CHANGED`, bag updates). Visit the bank on each alt once; the last-seen bank contents are kept afterwards.
- **Mail**: only while the mailbox is open (`MAIL_SHOW` always triggers a scan, plus `MAIL_INBOX_UPDATE`); attachments in the inbox are recorded. An empty mailbox clears the stored mail counts.
- So an alt you haven't logged in since installing AltStash has no data. The "scanned … ago" age on each line shows how stale it is.

## How "tradeable" is decided
Per stack, at scan time (stored as counts of untradeable units, so mixed stacks - some bound, some not - are handled exactly):
1. `isBound` from `C_Container.GetContainerItemInfo` is the soulbound check. `true` = untradeable, `false` = tradeable.
2. Account / Warband bind types (`bindType` 7, 8, 9 from `C_Item.GetItemInfo`) are always treated as tradeable (mailable between your own characters), even if `isBound` is true.
3. Where `isBound` isn't available (mail attachments, legacy API) it falls back to `bindType`: Bind-on-Pickup (1) and Quest (4) = untradeable; Bind-on-Equip, Bind-on-Use, none = tradeable.
4. Quest items are never excluded just for being quest-class/quest-related; only if actually bound. Crafting materials and unbound BoE/BoU items are kept.
5. If the item data isn't cached or a field is missing, the stack is treated as tradeable (unknown).
Data saved by 0.1.1 or earlier has no flags and is shown as tradeable until that character is scanned again (bags: automatically on login/bag change; bank/mail: next visit). Schema stays at 2 (new fields are optional).

## Not covered
Equipped gear, guild bank, Warband/account bank tabs, auction house listings, items you've sent that haven't arrived. Mail beyond what the inbox lists (the client shows ~50 messages) isn't seen.

## Future ideas
- Key items by suffix / random enchant (e.g. "of the Eagle" variants) instead of base item id only. Not done yet: variants are currently merged under one item id.
- Clickable item links / shift-click to chat in the results.

## APIs used (WoW Forever 1.60.1) - see the project report
Verified on warcraft.wiki.gg as available in Forever 1.60.1: `C_Container.GetContainerNumSlots`, `C_Container.GetContainerItemInfo` (including `isBound`), `C_Item.GetItemInfo` (classID, bindType - the page lists Forever 1.60.1), `GetInboxItem`, `GetInboxItemLink`, `GetInboxNumItems`, events `BANKFRAME_OPENED`, `BAG_UPDATE_DELAYED`, `MAIL_INBOX_UPDATE`, `PLAYERBANKSLOTS_CHANGED`.
Feature-detected at runtime with fallbacks: legacy `GetContainerNumSlots` / `GetContainerItemInfo`; tooltip via `TooltipDataProcessor.AddTooltipPostCall` (else `GameTooltip:HookScript("OnTooltipSetItem")`), all in `pcall`; bank bag ids derived from `NUM_BAG_SLOTS`, `NUM_REAGENTBAG_SLOTS`, `NUM_BANKBAGSLOTS` and `Enum.BagIndex` when present.

## Install
Unzip the release (`AltStash-v0.4.0.zip`) into `Interface/AddOns`, so you have `Interface/AddOns/AltStash/AltStash.toc`. On the Forever client that is typically `World of Warcraft/_classic_beta_/Interface/AddOns/`. Restart the game or `/reload`.

## License

AltStash Copyright (C) 2026 Demnock.

AltStash is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation, version 3 of the License (GPL-3.0). It is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the [LICENSE](LICENSE) file for the full text (kept verbatim so GitHub detects it) and [NOTICE](NOTICE) for the copyright notice.

## Credits

- **Jojo** started AltStash.
- **QuestieDB** (https://github.com/Questie/QuestieDB) is the source of the quest and item data in `QuestItemDB.lua`
  (QuestieDB 1.1.6, Forever data, commit 4377c981ac), used under the GPLv3 terms its team allows. AltStash is not
  affiliated with or endorsed by the QuestieDB team.

## Changelog
See [CHANGELOG.md](CHANGELOG.md).
