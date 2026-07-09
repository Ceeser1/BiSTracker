# BiS Tracker

> **Interface:** 30300 (WotLK 3.3.5a) · **Version:** 1.7.2 · **Author:** Ceeser · No external addons/libraries needed.

---

## Summary

A World of Warcraft **Wrath of the Lich King (3.3.5a)** addon that tracks every character and spec(s): their **Best-in-Slot gear progress**, **raid lockouts / IDs**, and **GearScore**. It comes with a buildt-in BiS List and optional whole Raid scan for BiS Item announcing/whispering settings for Raid Leads. You can export all chars into a companion **Google Sheet** for a clean, account-wide overview outside of WoW for you or to share with others. 

---

## How to Install

The Addon:
1. Download the [latest version](https://github.com/Ceeser1/BiSTracker/releases/tag/v1.7) and extract the folder inside into your addons folder, like this: `World of Warcraft\Interface\AddOns\BiSTracker`
2. Restart the game. Enable **BiS Tracker** in the character-select screen under AddOns if needed.
3. Click the minimap icon (default top-right on the map) or type `/bis` to open it.

The Google Spreadsheet:
Go to the [BiS Tracker Sheet](https://docs.google.com/spreadsheets/d/16E2BoZUXbuwe9H5jIebFeOFoH8szSg6edmAKoHzn3Rc/edit?gid=1115566070#gid=1115566070) and follow the instructions.

---

## Table of Contents

- [A. The Addon](#a-the-addon)
  - [In Short](#in-short)
  - [Character & spec tracking](#character--spec-tracking)
  - [BiS comparison](#bis-comparison)
  - [GearScore](#gearscore)
  - [Instance lockouts & weekly reset](#instance-lockouts--weekly-reset)
  - [Main window](#main-window)
  - [All Classes BiS browser](#all-classes-bis-browser)
  - [Raid scanning](#raid-scanning)
  - [Loot announcer & upgrade notifications](#loot-announcer--upgrade-notifications)
  - [Minimap button](#minimap-button)
  - [Settings](#settings)
  - [Slash commands](#slash-commands)
- [B. The Google Sheet](#b-the-google-sheet)
  - [Sheet layout](#sheet-layout)
  - [Import buttons](#import-buttons)
  - [Character deletion](#character-deletion-update-all-only)
  - [Sheet menu](#sheet-menu)
  - [Tamper-evident checksum](#tamper-evident-checksum)
- [C. How the Addon and Sheet Work Together](#c-how-the-addon-and-sheet-work-together)
  - [The workflow](#the-workflow)
  - [The export string](#the-export-string)
  - [BiS / Alt / Other matching](#bis--alt--other-matching)
  - [Multi-account & multi-realm](#multi-account--multi-realm)
- [FAQ](#faq)

---

## A. The Addon

### In Short

BiS Tracker watches your equipped gear and compares it slot-by-slot against a curated **Best-in-Slot list for 28 specs** across all classes. It remembers every character and spec you log into, scans your raid lockouts, calculates your GearScore, and can scan an entire raid's gear live. Everything is shown in a single in-game window.

**Supported specs (28 PvE / Raid Specs):**

| Class | Specs |
|---|---|
| Death Knight | Blood (Tank), Blood (DPS), Frost, Unholy |
| Warrior | Fury, Protection |
| Paladin | Retribution, Protection, Holy |
| Rogue | Combat, Assassination |
| Druid | Feral (Cat), Feral (Bear), Balance, Restoration |
| Hunter | Marksman, Survival |
| Mage | Fire, Arcane |
| Warlock | Demonology, Affliction |
| Priest | Shadow, Holy, Discipline |
| Shaman | Restoration, Elemental, Enhancement, Spellhancer |

### Character & spec tracking

- **Automatic registration**: Every character you log into is added automatically (name, class, realm).
- **Multi-spec aware**: The addon detects your active spec from your talent point distribution and tracks **each spec separately**, with its own gear snapshot and GearScore. Switching dual-spec and re-scanning simply adds/updates the second spec.
- **Account-wide**: All your alts on every realm are remembered in one place (saved in `BiSTrackerDB`).
- **Edit Chars view**: Free management like reorder characters and whole realms (Up/Down), and remove characters, specs, realms you no longer want tracked.

### BiS comparison

Each character's equipped gear is checked against its spec's BiS list. The result is colored three ways:

- 🟢 **Green `+`**: The exact BiS item (correct name **and** item level) is equipped.
- 🟠 **Orange `+`**: The right item but the **wrong/lower item level** (e.g. normal instead of heroic).
- 🔴 **Red `-`**: The slot is missing its BiS item.

A per-character **BiS score** (e.g. `12/17`) summarizes how many slots are exact BiS or Alt-BiS, color-coded green / yellow / red by amount. Many slots also carry an **alternative ("Alt")** item: a strong second choice which is tracked independently.

### GearScore

A native 3.3.5a port of the **GearScore** formula by Mirrikat45 / LibGearScore. It's computed from your live equipped gear and shown in the main list's **GS** column with a color gradient. GearScore is stored **per spec** for the current character. Other Chars keep their last scanned value.

### Instance lockouts & weekly reset

- Scans your **raid lockouts / IDs** for the tracked instances: **ICC 25/10, Ruby Sanctum 25/10, Trial of the Crusader 25/10**. A red **`X`** marks a locked instance.
- **Automatic weekly reset**: Locks clear automatically every **Wednesday 4:00 AM GMT** (the Warmane reset), so the display is always current without a manual refresh.

### Main window

- A sortable, realm-grouped character list. You can expand/collapse each realm to see tracked characters and expand/collapse chars to see equipped gear.
- A **spec-cycle button** per row to switch between a character's tracked specs.
- An **expandable detail panel** per character showing every slot with its BiS/Alt status and color indicators.
- Top-bar buttons: **Edit Chars**, **All Classes BiS**, **Settings**, and **Export**.

### All Classes BiS browser

A built-in, read-only reference of the **entire BiS list for all 28 specs** the Addon comes with. Expand any spec to see its full slot-by-slot BiS and Alt items with item levels.

### Raid scanning

When enabled, the addon can **inspect every member of your raid** and build a live picture of their gear:

- Detects each member's **spec** and calculates **GearScore**.
- Compares their gear to **their** spec's BiS list, flagging BiS and Alt items.
- Handles players out of inspect range by re-queuing them, and tracks **online/offline** transitions.
- Performs a **full roster sweep every 5 minutes**, with immediate individual scans when someone joins or reconnects.
- Results appear in the Settings view's raid list, each member expandable to a full gear breakdown.

### Loot announcer & upgrade notifications

When a raid leader / assistant / master looter with assist **posts an item link** in raid chat or as a raid warning, BiS Tracker can react automatically.

- **Distributed announcer election**: If several raid members run the addon, only **one** is elected to respond, by hierarchy: **Raid Lead → Master Looter → Assistant**. The election is resilient to people joining, leaving, reconnecting, and changing rank. Having only one elected Announcer prevents the Addon from being able to spam chat if multiple players use it.
- **Announce**: The elected announcer can post "BiS for `<specs>`" and/or "Alternative for `<specs>`" to Say / Raid Chat / Raid Warning, telling the raid who the item is best for.
- **Inform players**: Optionally whisper (or announce) the specific raid members for whom the posted item is an upgrade.
- **Always notify me**: Independently of the announcer role, you can always be told privately when a posted item is an upgrade for **your** current spec.
- **Never be Announcer**: Opt out of the election entirely.

### Minimap button

A draggable minimap icon:

- **Click** to open the main window.
- **Shift-drag** to move it around the minimap edge, **Ctrl-drag** to place it anywhere on screen.
- **Hover** for a tooltip showing a compact **raids lockout table** for all your characters (toggleable in Settings).

### Settings

A dedicated Settings view with three collapsible sections:

- **General**: Toggle auto gear scan, auto lockout scan, the minimap IDs popup, "Always notify me for upgrades", and "Never be announcer".
- **Export**: Set your **Account Alias** (used to group your characters by account in the spreadsheet. Never use your real account name there.
- **Announcer**: Full control over what the announcer listens to, what it announces and in which channel, whether to scan raid members, and whether/how to inform players of upgrades.

### Slash commands

| Command | Action |
|---|---|
| `/bis` | Toggle the main window |
| `/bis scan` | Rescan equipped gear for the active spec |
| `/bis locks` | Refresh instance lockout status |
| `/bis export` | Open the export-string window |
| `/bis clear` | Clear all character data (keeps settings, alias & minimap position) |
| `/bis reset` | Reset all settings to default, including the account alias (keeps characters) |
| `/bis raidscan` | Force a full re-scan of the whole raid immediatly |
| `/bis debug` | Toggle debug messages |
| `/bis help` | List all commands |

---

## B. The Google Sheet

The companion **Google Sheet** turns the addon's export string into a clean, shareable, account-wide gear sheet.

### Sheet layout

It has two main areas:
- **"Classes BiS Tab"**: The master reference: every spec's BiS and Alt item for each slot, with each item as a clickable **Wowhead link**. This is the source of truth the importer matches against.
- **"My Characters Tab"**: Your imported characters, grouped under **`Account - Realm - N Chars`** headers. Each character block shows, per slot, whether you have the **BiS**, the **Alt**, or **something else ("Other")** equipped. Slots are being checked on/off automatically from your export. Groups and the Classes BiS reference can be collapsed/expanded.

### Importing

On the **Addon Tab** you paste your export string into a textbox and click one of three buttons:

| Button | What it does |
|---|---|
| **Update All** | Full sync: adds/updates every character & spec in the string, updates **equipment + lockouts**, and **deletes** characters that are no longer in the string. |
| **Update Equipment** | Updates only the gear and checkmarks. |
| **Update Instance Locks** | Updates only your characters raid-lockouts. |

Every import takes an automatic **backup** (undoable) and logs an entry with a timestamp to the "Your last Updates" list.

### Character deletion (Update All only)

**Update All** treats the export string as the complete truth for **that account**: any of the account's characters/specs/realms missing from the string are removed. Before anything is written, a **YES/NO confirmation lists exactly which characters will be deleted** (cancel = no changes). Other accounts and any legacy/ungrouped blocks are never touched. **Update Equipment** and **Update Instance Locks** never delete chars/accounts/realms.

### Sheet menu

A custom **"BisTracker Sheet Functions"** menu provides:

- Collapse / Expand all (My Characters)
- Collapse / Expand all (Classes BiS)
- **Undo Last Changes**: revert the most recent import/delete in full.
- **Delete All Characters**: wipe the entire "My Characters" area (all accounts and characters) after a confirmation. It snapshots first (so it's undoable), logs "Deleted All Chars", and writes a notice into the last-update box.

> The three `Update…` actions are intentionally **not** in the menu: they run only from the Addon-tab buttons to prevent accidental full syncs.

### Tamper-evident checksum

Every export string ends with a **checksum**. The sheet recomputes it on import and **rejects any string that was edited by hand**, so the data in the sheet always reflects a genuine in-game export.

---

## C. How the Addon and Sheet Work Together

### The workflow

1. In game, run `/bis export` (or click **Export** in the main window). The addon builds a single-line string describing **all** your tracked characters and specs.
2. Copy it (Ctrl-A, Ctrl-C in the export textbox).
3. In the Google Sheet's **Addon tab**, paste it into the textbox and click **Update All** (or a partial update).
4. The sheet validates the checksum, then rebuilds your "My Characters" section.

### The export string

The string is a compact, self-contained snapshot:

```
<account>;<entry>|<entry>|...~<checksum>
```

- **`<account>`**: your Account Alias (set in Settings → Export), so the sheet can group characters per account.
- **Each `<entry>`** is one character-spec: `Name.Spec.Realm; <17 equipped item IDs>; <GearScore>; <6 lockout bits>`.
- **`<checksum>`**: keyed hash over everything before it; the sheet's identical algorithm verifies it.

Gear is exported as **item IDs**, which keeps the string short and lets the sheet decide BiS/Alt/Other purely by item identity (see below).

### BiS / Alt / Other matching

The addon doesn't tell the sheet "this is BiS": it just sends **which items you have equipped**. The sheet then matches each equipped item ID against the **Wowhead item links** in the "Classes BiS" reference for that spec:

- Matches the row's **BiS** item → ticks **BiS**.
- Matches the row's **Alt** item → ticks **Alt**.
- Matches neither → ticks **Other**.

This is the sheet-side mirror of the addon's in-game comparison, and it transparently handles slot quirks (Shield ↔ Off-hand, relic/ranged slots, and the two-slot Ring/Trinket pairs where a single row can legitimately show **both** BiS and Alt if you have both equipped).

### Multi-account & multi-realm

Because the saved data is account-wide, one player can run **several accounts** and **many realms**:

- The **Account Alias** prefix lets the sheet keep each account's characters in their own `Account - Realm` groups.
- Realm is carried per character, so alts are grouped under the right realm automatically.
- **Update All** only ever adds/updates/deletes **within the account named in the string**: importing one account never disturbs another.

---

## FAQ

**Does it work on retail / other expansions?**
No. It targets WoW 3.3.5a (WotLK) like the Warmane server.

**Will edit/delete chars affect my characters in-game?**
No. The addon only **reads** your gear and lockouts. The only "deletion" is addon or sheet-side.

**Do all my raid members need the addon?**
No. Only **you** having it is fine, you dont even need it to get informed for upgrades if the lead/master looter/assist has the addon and settings set up.

**How does the Announcer system works?**
If a player with the addon has Raid Lead or Assist he may be selected as the Announcer. Hierarchy: Lead > Master Looter > Assist.
Having an announcer prevents the Addon from spamming if multiple players with raid ranks are using it. Only the settings of the selected Announcer count.

**Why should I set an Account Alias instead of my real account name?**
Its recommended if you are using the companion Spreadsheet and required if you use one spreadsheet for multiple accounts.
When you share your spreadsheet link, everybody with that link can see your account name(s), so use an alias you can remember, not your real acc name.

---

*BiS Tracker: by Ceeser. Built for the Warmane WotLK community.*
