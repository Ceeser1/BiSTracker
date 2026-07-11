# BiS Tracker

> **Interface:** 30300 (WotLK 3.3.5a) · **Version:** 1.7.4 · **Author:** Ceeser · No external addons/libraries needed.

---

## Summary

A World of Warcraft **Wrath of the Lich King (3.3.5a)** addon that tracks every character and spec(s): their **Best-in-Slot gear progress**, **raid lockouts / IDs**, and **GearScore**. It comes with a buildt-in BiS List and optional whole Raid scan for BiS Item announcing/whispering settings for Raid Leads. You can export all chars into a companion **Google Sheet** for a clean, account-wide overview outside of WoW for you or to share with others.

---

## How to Install

The Addon:
1. Download the [latest version](https://github.com/Ceeser1/BiSTracker/releases/latest) and extract the folder inside into your addons folder, like this: `World of Warcraft\Interface\AddOns\BiSTracker`
2. Restart the game. Enable **BiS Tracker** in the character-select screen under AddOns if needed.
3. Click the minimap icon (default top-right on the map) or type `/bis` to open it.

The Google Spreadsheet:
Go to the [BiS Tracker Sheet](https://docs.google.com/spreadsheets/d/16E2BoZUXbuwe9H5jIebFeOFoH8szSg6edmAKoHzn3Rc/edit?gid=1115566070#gid=1115566070) and follow the instructions.

---

## Features

### Track all your characters
Every character you log into is remembered automatically: name, class, realm, and each spec separately. All your alts across every realm live in one window, and you can reorder or remove characters, specs and realms you don't want.

### Shows your BiS progress
Your equipped gear is compared slot-by-slot against a built-in **Best-in-Slot list for 28 PvE specs**:

- 🟢 **Green**: You have the exact BiS item.
- 🟠 **Orange**: Right item, but a lower version (e.g. normal instead of heroic).
- 🔴 **Red**: The slot is missing its BiS/Alt item.

Each character also gets a BiS score like `12 / 17` so you can see progress at a glance. Many slots list a strong **Alt** (second choice) too.

### Raid lockouts
Shows which raids each character is saved to: **ICC 25/10, Ruby Sanctum 25/10, Trial of the Crusader 25/10** with a red mark for locked. Lockouts clear themselves automatically every Wednesday reset.

### All Classes BiS browser
A built-in, read-only list of the full BiS and Alt gear for **all 28 specs**, so you can look up any class without leaving the game.

### Raid scanning
Optionally scan your whole raid to see each member's spec, GearScore, and how their gear matches their own BiS list. Great for raid leaders checking the group and required for loot upgrade comparison by the addon.

### Loot announcer *(for raid leaders)*
When a raid leader, master looter or assistant links an item in raid chat, the addon can automatically post **who the item is Best-in-Slot (or a good Alt) for**.
If several people in the raid use the addon, only one is elected as the Announcer by the addon (Raid Lead > Master Looter > Assist), so chat never gets spammed.

### Upgrade notifications
Get told when a linked item is an upgrade the way you prefer:

- **Always notify me**: You're privately told whenever a posted item is an upgrade for your current spec, no matter who's announcing.
- **Allow announcer whispers**: Decide whether the raid's announcer is allowed to whisper you about upgrades. Turn it off and you'll never be whispered.

### Announcer raid controls *(announcer only)*
In the **Players in this Raid** list, whoever is the current announcer can tune notifications per member:

- **Whisper?**: Pick exactly which raid members get whispered about their upgrades.
- **MS Changed**: Mark a player who switched main spec. The addon then stops comparing posted items to their gear and won't whisper them, since their equipped gear doesnt match the spec being checked.

### Version Check / Update notifications
If someone in your raid is running a newer version of BiS Tracker, the addon lets you know it once that an update is available so you always know when to grab the latest version.

### Minimap button
A draggable minimap icon: **click** to open the main window, **hover** for a quick table of all your characters' raid lockouts. Shift-drag to move it around the minimap, Ctrl-drag to place it anywhere.

### Settings
A Settings window lets you toggle automatic gear/lockout scanning, the minimap lockout tooltip, your upgrade-notification preferences, the announcer options, and your **Account Alias** for the spreadsheet export.

### Slash commands

| Command | Action |
|---|---|
| `/bis` | Toggle the main window |
| `/bis scan` | Rescan equipped gear for the active spec |
| `/bis locks` | Refresh instance lockout status |
| `/bis export` | Open the export-string window |
| `/bis clear` | Clear all character data (keeps settings, alias & minimap position) |
| `/bis reset` | Reset all settings to default, including the account alias (keeps characters) |
| `/bis raidscan` | Force a full re-scan of the whole raid immediately |
| `/bis help` | List all commands |

---

## Companion Google Sheet

The optional **Google Sheet** gives you a clean, shareable, account-wide overview of all your gear outside the game.

1. In game, run `/bis export` or click the export button and copy the string it gives you.
2. Open the [BiS Tracker Sheet](https://docs.google.com/spreadsheets/d/16E2BoZUXbuwe9H5jIebFeOFoH8szSg6edmAKoHzn3Rc/edit?gid=258345729#gid=258345729), paste it into the [**Addon Tab**](https://docs.google.com/spreadsheets/d/16E2BoZUXbuwe9H5jIebFeOFoH8szSg6edmAKoHzn3Rc/edit?gid=937004181#gid=937004181), and click **Update All**.

The sheet then lists every character (grouped by account and realm) showing, per slot, whether you have the **BiS**, the **Alt**, or **something else** equipped with clickable Wowhead links and your raid lockouts. Every import can be undone, and you can share the link with friends or your guild. Set an **Account Alias** in the addon's Settings if using it for multiple accounts before exporting, never use your real account name.

---

## FAQ

**Does it work on retail / other expansions?**
No. It targets WoW 3.3.5a (WotLK) like the Warmane server.

**Will editing or deleting characters affect my characters in-game?**
No. The addon only **reads** your gear and lockouts. Any deletion is addon- or sheet-side only.

**Do all my raid members need the addon?**
No. Only **you** need it. You'll even get upgrade notifications without it, as long as the lead / master looter / assist has the addon set up.

**How does the announcer work?**
If multiple players with the addon is Raid Lead or has Assist, only one of them is chosen as the announcer (Lead > Master Looter > Assist). Having a single announcer prevents the addon from spamming if several people in the raid use it. Only the elected announcer's settings apply.

**Why set an Account Alias instead of my real account name?**
When you share your spreadsheet, anyone with the link can see your account name. Use an alias you'll remember instead of your real acc name. It's recommended for the spreadsheet, and required if you track multiple accounts in one sheet.
