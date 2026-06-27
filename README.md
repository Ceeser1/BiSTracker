# BiS Tracker

A World of Warcraft **Wrath of the Lich King (3.3.5a)** addon that tracks every character and spec on your account(s): their **Best-in-Slot gear progress**, **raid lockouts / IDs**, and **GearScore**: and exports it all into a companion **Google Sheet** for a clean, account-wide overview.

> **Interface:** 30300 (WotLK 3.3.5a) · **Version:** 1.5 · **Author:** Ceeser · Pure Lua 5.1, no external libraries.

---

## Table of Contents

- [A. The Addon](#a-the-addon)
  - [At a glance](#at-a-glance)
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
- [Installation](#installation)
- [FAQ](#faq)

---

## A. The Addon

### At a glance

BiS Tracker watches your equipped gear and compares it slot-by-slot against a curated **Best-in-Slot list for 28 specs** across all ten classes. It remembers every character and spec you log into, scans your raid lockouts, calculates your GearScore, and can scan an entire raid's gear live. Everything is shown in a single in-game window and can be exported to a Google Sheet.

**Supported specs (28):**

| Class | Specs |
|---|---|
| Death Knight | Blood (Tank), Blood (DPS), Frost, Unholy |
| Warrior | Fury, Protection |
| Paladin | Retribution, Protection, Holy |
| Rogue | Combat, Assassination |
| Druid | Feral (Cat), Bear, Balance, Restoration |
| Hunter | Marksman, Survival |
| Mage | Fire, Arcane |
| Warlock | Demonology, Affliction |
| Priest | Shadow, Holy, Discipline |
| Shaman | Restoration, Elemental, Enhancement, Spellhance |

### Character & spec tracking

- **Automatic registration**: every character you log into is added automatically (name, class, realm).
- **Multi-spec aware**: the addon detects your active spec from your talent point distribution and tracks **each spec separately**, with its own gear snapshot and GearScore. Switching dual-spec and re-scanning simply adds/updates the second spec.
- **Account-wide**: all your alts on every realm are remembered in one place (saved in `BiSTrackerDB`).
- **Edit Chars view**: rename-free management: reorder characters and whole realms (Up/Down), and remove characters or specs you no longer want tracked.

### BiS comparison

Each character's equipped gear is checked against its spec's BiS list. The result is shown three ways:

- 🟢 **Green `+`**: the exact BiS item (correct name **and** item level) is equipped.
- 🟠 **Orange `+`**: the right item but the **wrong difficulty/item level** (e.g. normal instead of heroic).
- 🔴 **Red `-`**: the slot is missing its BiS item.

A per-character **BiS score** (e.g. `12/17`) summarizes how many slots are exact BiS, color-coded green / yellow / red by completion percentage. Many slots also carry an **alternative ("Alt")** item: a strong second choice: which is tracked independently.

> Ring and Trinket slots are handled as pairs (two physical slots each), so having the BiS in one ring slot and the Alt in the other both count correctly.

### GearScore

A native 3.3.5a port of the well-known **GearScore** formula (Mirrikat45 / LibGearScore). It's computed from your live equipped gear and shown in the main list's **GS** column with a smooth color gradient (grey → white → green → blue → purple → orange → red as the number climbs). GearScore is stored **per spec** for the current character; offline alts keep their last scanned value.

### Instance lockouts & weekly reset

- Scans your **raid save status** for the tracked instances: **ICC 25/10, Ruby Sanctum 25/10, Trial of the Crusader 25/10**.
- A red **`X`** marks a locked instance; empty means available.
- **Automatic weekly reset**: locks clear automatically every **Wednesday 4:00 AM GMT** (the Warmane reset), so the display is always current without a manual refresh.

### Main window

A single 680×420 window with:

- A sortable, **realm-grouped** character list (collapse/expand each realm).
- Columns: Character · Spec · the six instance lockouts · BiS score · GearScore.
- A **spec-cycle button** per row to flip between a character's specs.
- An **expandable detail panel** per character showing every slot with its BiS/Alt status and color indicators, laid out in two columns.
- Top-bar buttons: **Edit Chars**, **All Classes BiS**, **Settings**, and **Export**.

### All Classes BiS browser

A built-in, read-only reference of the **entire BiS list for all 28 specs**: expand any spec to see its full slot-by-slot BiS and Alt items with item levels. No character needed; it's a pure lookup of the data the addon ships with.

### Raid scanning

When enabled, the addon can **inspect every member of your raid** and build a live picture of their gear:

- Detects each member's **spec** (via talent inspection) and **GearScore**.
- Compares their gear to **their** spec's BiS list, flagging BiS and Alt items.
- Handles players out of inspect range by re-queuing them, and tracks **online/offline** transitions by polling the roster (WotLK has no connection event).
- Performs a **full roster sweep every 5 minutes**, with immediate individual scans when someone joins or reconnects.
- Results appear in the Settings view's raid list, each member expandable to a full gear breakdown.

### Loot announcer & upgrade notifications

When a raid leader / assistant / master looter **posts an item link** in raid chat or as a raid warning, BiS Tracker can react automatically: but it's careful not to spam:

- **Distributed announcer election**: if several raid members run the addon, exactly **one** is elected to respond, by hierarchy: **Raid Lead → Master Looter → Assistant**. The election is resilient to people joining, leaving, reconnecting, and changing rank, and it converges to a single announcer across all clients.
- **Announce**: the elected announcer can post "BiS for `<specs>`" and/or "Alternative for `<specs>`" to Say / Raid / Raid Warning, telling the raid who the item is best for.
- **Inform players**: optionally whisper (or announce) the specific raid members for whom the posted item is an upgrade, using the live raid-scan data.
- **Always notify me**: independently of the announcer role, you can always be told privately when a posted item is an upgrade for **your** spec ("BiS", "Alt BiS", "pre-BiS", "Alt pre-BiS").
- **Never be Announcer**: opt out of the election entirely.

### Minimap button

A draggable minimap icon:

- **Click** to open the main window.
- **Shift-drag** to move it around the minimap edge; **Ctrl-drag** to place it anywhere on screen.
- **Hover** for a tooltip showing a compact **lockout table** for all your characters (toggleable in Settings).

### Settings

A dedicated Settings view with three collapsible sections:

- **General**: toggle auto gear scan, auto lockout scan, the minimap popup, "always notify me", and "never be announcer".
- **Export**: set your **Account Alias** (used to group your characters by account in the sheet; never use your real account name).
- **Announcer**: full control over what the announcer listens to, what it announces and in which channel, whether to scan raid members, and whether/how to inform players of upgrades.

### Slash commands

| Command | Action |
|---|---|
| `/bis` | Toggle the main window |
| `/bis scan` | Rescan equipped gear for the active spec |
| `/bis locks` | Refresh instance lockout status |
| `/bis export` | Open the export-string window |
| `/bis spec` | Print the currently detected spec |
| `/bis gs` | Print a per-slot GearScore breakdown (debug) |
| `/bis debug` | Toggle debug messages |
| `/bis reset` | Clear all character data (keeps settings & minimap position) |
| `/bis weekreset` | Force a weekly lockout reset (debug) |
| `/bis fakelocks [1-6]` | Mark instances as locked for testing (debug) |
| `/bis help` | List all commands |

---

## B. The Google Sheet

The companion **Google Sheet** (driven by an Apps Script) turns the addon's export string into a clean, shareable, account-wide gear sheet. It has two main areas:

### Sheet layout

- **"Classes BiS"**: the master reference: every spec's BiS and Alt item for each slot, with each item as a clickable **Wowhead link**. This is the source of truth the importer matches against.
- **"My Characters"**: your imported characters, grouped under **`Account - Realm - N Chars`** headers. Each character block shows, per slot, whether you have the **BiS**, the **Alt**, or **something else ("Other")** equipped: checked off automatically from your export. Groups and the Classes BiS reference can be collapsed/expanded.

### Import buttons

On the **Addon tab** you paste your export string into a textbox and click one of three buttons:

| Button | What it does |
|---|---|
| **Update All** | Full sync: adds/updates every character & spec in the string, updates **equipment + lockouts**, and **deletes** characters that are no longer in the string. |
| **Update Equipment** | Updates only the gear checkmarks; never deletes. |
| **Update Instance Locks** | Updates only the raid-lockout columns; never deletes. |

Every import takes an automatic **backup** (undoable) and logs an entry with a timestamp to the "Your last Updates" list.

### Character deletion (Update All only)

**Update All** treats the export string as the complete truth for **that account**: any of the account's characters/specs/realms missing from the string are removed. Before anything is written, a **YES/NO confirmation lists exactly which characters will be deleted** (cancel = no changes). Other accounts and any legacy/ungrouped blocks are never touched. **Update Equipment** and **Update Instance Locks** never delete.

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

```
In-game:  /bis export  ──►  copy the string
                                   │
Browser:  Addon tab ──► paste into the textbox ──► click "Update All"
                                   │
                                   ▼
          "My Characters" rebuilt: every char/spec grouped by Account - Realm,
          each slot ticked as BiS / Alt / Other, lockouts filled in.
```

1. In game, run `/bis export` (or click **Export** in the main window). The addon builds a single-line string describing **all** your tracked characters and specs.
2. Copy it (Ctrl-A, Ctrl-C in the export box).
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

This is the sheet-side mirror of the addon's in-game comparison, and it transparently handles slot quirks (Shield ↔ Off-hand, relic/ranged slots, and the two-slot Ring/Trinket pairs: where a single row can legitimately show **both** BiS and Alt if you have both equipped).

### Multi-account & multi-realm

Because the saved data is account-wide, one player can run **several Warmane accounts** and **many realms**:

- The **Account Alias** prefix lets the sheet keep each account's characters in their own `Account - Realm` groups.
- Realm is carried per character, so alts are grouped under the right realm automatically.
- **Update All** only ever adds/updates/deletes **within the account named in the string**: importing one account never disturbs another.

---

## Installation

1. Download the addon and extract it so the folder is:
   `World of Warcraft\Interface\AddOns\BiSTracker\`
   (the folder must contain `BiSTracker.toc`).
2. Restart the game or `/reload`. Enable **BiS Tracker** at the character-select AddOns screen if needed.
3. Type `/bis` or click the minimap icon to open it.

> The companion Google Sheet's Apps Script is maintained alongside the addon. Copy the sheet template, open **Extensions → Apps Script**, and paste in the script if you're setting one up yourself.

## FAQ

**Does it work on retail / other expansions?**
No: it targets WoW 3.3.5a (WotLK) and the Warmane server specifically.

**Will it edit or delete my gear / characters in-game?**
No. The addon only **reads** your gear and lockouts. The only "deletion" is sheet-side and only affects rows in your Google Sheet (always undoable, always confirmed).

**Do all my raid mates need the addon?**
No. Raid scanning inspects anyone; the announcer system only needs **you** to have it. If several people run it, only one is elected to respond.

**Why should I set an Account Alias instead of my real account name?**
Because it's visible to everybody you share your sheet with. The alias labels grouped chars per account in the sheet. Just pick something you can remember/refer to.

---

*BiS Tracker: by Ceeser. Built for the Warmane WotLK community.*
