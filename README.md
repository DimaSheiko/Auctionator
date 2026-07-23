# Auctionator (3.3.5a — customized build)

A fork of **Auctionator 2.6.8** for World of Warcraft **3.3.5a (WotLK)** with a
set of quality-of-life features and fixes on top of the original addon.

> Based on Auctionator by **Zirco** (<http://auctionator-addon.com>). All original
> code belongs to its authors; this repository only adds the changes listed below.

## What this build adds

### Slot / inventory-type filter in Advanced Search
The Advanced Search dialog gains a third **Slot** dropdown below Category and
Subcategory. Pick e.g. *Armor → Mail → Head* to let the auction house filter by
inventory slot server-side. The dropdown auto-populates from the selected
category/subcategory and stays empty for categories that have no slots (shields,
trade goods, ...), matching the native auction house behavior.

### Pawn integration — score column
When the [Pawn](https://www.curseforge.com/wow/addons/pawn) addon is installed,
the search results table shows a sortable **Pawn** column with each item's score
for your active specialization:

- Scores are read through Pawn's public API only — none of Pawn's math is copied.
- The active scale is auto-detected from your dominant talent tree.
- Values use the same decimals Pawn shows in its tooltip.
- Click the column header to sort high↔low (best on top first).
- Scores fill in automatically (async), without needing to hover each row.

### Full value vs. difference-vs-equipped
A new **Pawn** options tab lets you switch the column between:

- **Full score** — the item's absolute Pawn value, or
- **Difference vs. equipped** — the gain/loss compared to what you have equipped
  in that slot (green for an upgrade, red for a downgrade). Empty slot → full value.

Comparisons respect item type: a one-hand weapon is only compared against an
equipped weapon, never a shield, even though they share the same slot.

### Scale selector
The Pawn options tab includes a scale dropdown: **Automatic** (detect by spec)
plus every scale of your class, so you can score items against another spec
(e.g. compare gear for an off-spec). The choice is saved **per character**, and a
scale that doesn't belong to the character's class is ignored.

## Fixes included

- **Buying random-suffix items** — a pre-existing bug in the original addon:
  items like *"Wolf Rider's Boots of Spirit"* could not be bought from the
  results list because the buy re-scan queried the full name, but the server
  only indexes the base name. It now queries by the base name (from the itemLink
  suffix) while still matching the exact variant.

- **Lua error on shift-click** — a pre-existing bug in the original addon: its
  replacement for `ChatEdit_InsertLink` called `strfind` on the argument without
  checking it, so a `nil` link raised *"bad argument #1 to 'strfind'"* and aborted
  the click. It now falls through to the original function.

## Slash commands

| Command | Effect |
|---|---|
| `/atr pawnscale` | Show the detected active Pawn scale |
| `/atr pawnscale "Wowhead":Xxx` | Force a specific scale |
| `/atr pawnscale auto` | Back to automatic detection |
| `/atr pawndiff [on\|off]` | Toggle / set the difference-vs-equipped mode |

## Installation

Copy the `Auctionator` folder into `World of Warcraft/Interface/AddOns/`, then
fully restart the game. A newly installed addon is not picked up by `/reload` —
you have to relaunch the client.

- **Requires:** WoW client 3.3.5a (Interface 30300).
- **Optional:** Pawn (for the score column).

## Files added by this build

- `AuctionatorPawn.lua` — all Pawn contact, isolated in one file.
- Changes across `Auctionator.lua`, `AuctionatorScan.lua`, `AuctionatorShop.lua`,
  `AuctionatorLocalize.lua`, `AuctionatorBuy.lua`, `AuctionatorConfig.lua`,
  `Auctionator.xml`, and `AuctionatorConfig.xml`.
