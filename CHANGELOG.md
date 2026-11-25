# Changelog

All notable changes to AltStash. Newest first.

## v0.4.0

- More accurate "Quest done: safe to delete": a built-in quest database (QuestItemDB.lua, from QuestieDB Forever data) cross-references every quest that uses an item and the later steps of its chain. An item is safe only when all of them are completed on that character and none is active on any character.
- Class-quest, starter and unresolved items now show "Keep: quest chain not finished (quest, ID)" or "Quest item: can't confirm, keep". A quest turn-in reward alone never makes an item safe.
- New commands: `/as keep`, `/as unkeep`, and `/as questinfo` (quest IDs, completion and the reason behind the verdict).
- Hold Shift over an item to see its quest IDs on the tooltip. The Items-view tags and the Safe to sell / delete filter use the same rules.

## v0.3.9

- Hovering an item in bags, the bank, or a chat link adds one AltStash line to the game tooltip: quest done (safe to delete), needed for a quest, crafting reagent, or safe to sell.
- Leftover quest items are identified from the game's quest link, quest-log objectives, and items received at a quest turn-in.

## v0.3.8

- Items view tags: Quest, Quest done (safe to delete), Crafting, Gear, and Safe to sell.
- "Safe to sell / delete" filter checkbox, with vendor and AH value totals.
- Saves each character's quest log so completed-quest leftovers can be marked safe.

## v0.3.7

- Auctionator AH sell value on Trade Goods, Consumables, Reagents, Gems, and Recipes in the Items view.

## v0.3.6

- The Profitable checkbox also sorts recipes by profit, highest first.

## v0.3.5

- Craft-or-sell advice from Auctionator scanned prices, including the 5% AH cut and the auction deposit.
- `/as prices`, `/as deposit`, and `/as mindeposit` control the advice and deposit assumptions.

## v0.3.4

- Fix: profession cooldown countdowns could show about 49.7 days too long (for example "50d 22h") because of a GetTime() wrap. Times more than 7 days out are corrected or hidden. Use with ProfTracker 0.1.5+.

## v0.3.3

- Craftables show profession cooldowns (transmutes, Mooncloth, Salt Shaker, and any recipe reported on cooldown), with time remaining or Ready. Needs ProfTracker 0.1.4+.
- Character tabs show a clock when a cooldown is ready.

## v0.3.2

- While the search box has text, every character tab with a matching item or recipe gets a green outline.

## v0.3.0

- Redesigned window: character portrait tabs, an All characters tab, Items and Craftables sub-tabs, and a cleaner draggable frame whose position is saved.

## v0.2.1

- Public API `honorTradeableFilter = "always"`, so ProfTracker can count only tradeable items on other characters.

## v0.2.0

- Read-only public API (`AltStash.API`) for other add-ons.

## v0.1.1

- Tradeable-only flags on scanned items (older saved data is treated as tradeable until that character is scanned again).

## v0.1.0

- First version: scan bags, bank, and mail; search across characters; "Alts have" tooltip lines.
