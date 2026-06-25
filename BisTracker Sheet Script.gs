// ============================================================
// Custom Functions — Works on "My Characters" (full)
//                      + "Classes BiS" (collapse only)
// ============================================================

const SHEET_CHARS = "My Characters";
const SHEET_BIS   = "Classes BiS";

// ── Shared column map (same layout on both sheets) ───────────
const COL_SLOT      = 2;   // B — slot name
const COL_BIS_CHECK = 6;   // F — BiS checkbox (E holds the item icon)
const COL_BIS_NAME  = 7;   // G — BiS item name / "X/Y BiS" header
const COL_LOGS      = 8;   // H — "UwU Logs" link (header) / "From" (data rows)
const COL_ALT_CHECK = 13;  // M — Alt-BiS checkbox (data) / ICC10 lock (header)
const COL_ALT_NAME  = 14;  // N — Alt-BiS item name
const COL_OTH_CHECK = 26;  // Z — Other checkbox
const COL_OTH_NAME  = 27;  // AA — Other items / date (header)
const COL_TOGGLE    = 28;  // AB — expand/collapse toggle (header only)

const LOCK_PAIRS = [
  { check: 11, label: 12, inst: "ICC25" }, // K/L
  { check: 13, label: 14, inst: "ICC10" }, // M/N
  { check: 15, label: 16, inst: "RS25"  }, // O/P
  { check: 17, label: 18, inst: "RS10"  }, // Q/R
  { check: 19, label: 20, inst: "ToC25" }, // S/T
  { check: 21, label: 22, inst: "ToC10" }, // U/V
];

const COLOR_HAVE   = "#b6d7a8";
const COLOR_GREY   = "#D3D3D3";
const COLOR_LOCKED = "#ff2e2e";

// ============================================================
// ADDON IMPORT — config for the "Update All" button
// ============================================================
const SHEET_ADDON = "Addon";   // tab holding the paste cell + buttons
const PASTE_CELL  = "C4";      // merged C4:L9 — getValue() reads the top-left

// "Last Addon update String" record box (full string) + the "Your last Updates"
// log (update type + local timestamp), newest at the top.
const LAST_STRING_CELL  = "C14";      // anchor of the box showing the most recently applied string
const LAST_STRING_RANGE = "C14:L19";  // full merged box (used for alignment/font styling)
const UNDO_PLACEHOLDER  = "Nothing to Undo.."; // shown in the box after an undo
const LOG_ROW      = 4;         // top row of the log = row 4
const LOG_LEN      = 6;         // rows 4..9 (6 entries); anything past row 9 is dropped
const LOG_COL_TYPE = 23;        // W — update type ("Instance Locks"/"Characters"/"Everything")
const LOG_COL_TIME = 24;        // X — local date+time stamp

// Hidden full-sheet snapshot of "My Characters" for one-level "Undo Last Changes".
const BACKUP_SHEET = "_MyCharsBackup";

// "Get The Addon" download link — placeholder for now (points to Google).
const ADDON_DOWNLOAD_URL = "https://www.google.com";

// Addon export gear order (17 values, 1-based) — must match GEAR_SLOTS in the addon:
//   1 Head  2 Neck  3 Shoulders  4 Chest  5 Waist  6 Legs  7 Feet  8 Wrist
//   9 Hands 10 Ring1 11 Ring2 12 Trinket1 13 Trinket2 14 Back 15 MainHand 16 OffHand 17 Ranged
// Sheet rows use slot NAMES (col B); map each to its export index. Aliases:
//   Shield -> Off Hand (16); any ranged-type relic -> Ranged (17).
const SLOT_EXPORT_IDX = {
  "Head": 1, "Neck": 2, "Shoulders": 3, "Chest": 4, "Waist": 5,
  "Legs": 6, "Leggs": 6,   // "Leggs" = the sheet's spelling of the Legs slot
  "Feet": 7, "Wrist": 8, "Hands": 9, "Back": 14, "Main Hand": 15,
  "Off Hand": 16, "Shield": 16,
  "Ranged": 17, "Crossbow": 17, "Bow": 17, "Gun": 17, "Thrown": 17, "Wand": 17,
  "Idol": 17, "Libram": 17, "Totem": 17, "Sigil": 17, "Relic": 17,
};
// Ring/Trinket appear twice per block — resolved by order of appearance (see resolveGear_).
const RING_IDX    = [10, 11];
const TRINKET_IDX = [12, 13];

// The export sends the spec fully written with "-" for spaces (e.g.
// "Marksman-Hunter"); normalizeSpec_ just swaps "-" back to spaces, which equals
// the sheet's display spec name. No lookup table needed.

// Fallback UwU Logs realm — used only when an entry's exported realm is missing
// (e.g. an older export). Normally each character's own realm from the export is used.
const UWU_SERVER = "Icecrown";

// Shared secret for the export integrity checksum. Must match EXPORT_SECRET in the
// addon's Constants.lua EXACTLY (change in both, or every import is rejected).
const EXPORT_SECRET = "BiSTrk!2026#warmane";

// UwU Logs spec param = per-class talent-tree index (1=tree1, 2=tree2, 3=tree3;
// see github.com/Ridepad/uwu-logs c_player_classes.py). Keyed by DISPLAY spec
// name (what normalizeSpec_ returns). Hybrids map onto their underlying tree.
const SPEC_UWU_ID = {
  "Blood DK Tank": 1, "Blood DK Dps": 1, "Frost DK": 2, "Unholy DK": 3,
  "Balance Druid": 1, "Feral Combat Druid": 2, "Bear Druid": 2, "Restoration Druid": 3,
  "Beast Mastery Hunter": 1, "Marksman Hunter": 2, "Survival Hunter": 3,
  "Arcane Mage": 1, "Fire Mage": 2, "Frost Mage": 3,
  "Holy Paladin": 1, "Protection Paladin": 2, "Retribution Paladin": 3,
  "Discipline Priest": 1, "Holy Priest": 2, "Shadow Priest": 3,
  "Assassination Rogue": 1, "Combat Rogue": 2, "Subtlety Rogue": 3,
  "Elemental Shaman": 1, "Enhancement Shaman": 2, "Spellhance Shaman": 2, "Restoration Shaman": 3,
  "Affliction Warlock": 1, "Demonology Warlock": 2, "Destruction Warlock": 3,
  "Arms Warrior": 1, "Fury Warrior": 2, "Protection Warrior": 3,
};

// ============================================================
// HEADER ROW DETECTION — "X / Y BiS" text in col G
// ============================================================
function isHeaderRow(sheet, row) {
  const val = sheet.getRange(row, COL_BIS_NAME).getValue().toString();
  return val.includes("/") && val.toLowerCase().includes("bis");
}

function isCheckbox(sheet, row, col) {
  const val = sheet.getRange(row, col).getValue();
  return val === true || val === false;
}

// ============================================================
// ON OPEN
// ============================================================
function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu("BiS Chars Sheet Functions")
    .addItem("Collapse All (My Characters)", "collapseChars")
    .addItem("Expand All (My Characters)",   "expandChars")
    .addSeparator()
    .addItem("Collapse All (Classes BiS)",   "collapseBiS")
    .addItem("Expand All (Classes BiS)",     "expandBiS")
    .addSeparator()
    .addItem("Update All (from Addon paste)", "updateAll")
    .addItem("Update Equipment only",         "updateEquipment")
    .addItem("Update Instance Locks only",    "updateInstanceLocks")
    .addSeparator()
    .addItem("Undo Last Changes",             "undoLastChanges")
    .addToUi();

  // Separate top-level menu next to "BiS Chars Sheet Functions" — acts as a
  // "Get The Addon" button (a menu needs >=1 item, so it carries a single one).
  SpreadsheetApp.getUi()
    .createMenu("Get The Addon")
    .addItem("Open download page", "getTheAddon")
    .addToUi();

  // Reset expired instance locks + collapse both sheets on open
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  initSheet(ss.getSheetByName(SHEET_CHARS), true);  // full init
  initSheet(ss.getSheetByName(SHEET_BIS),   false); // collapse only
}

// "Get The Addon" — Apps Script can't navigate the browser directly, so open a
// tiny dialog that auto-opens the download page in a new tab (with a click-here
// fallback if the popup is blocked). URL is a placeholder for now (ADDON_DOWNLOAD_URL).
function getTheAddon() {
  const url = JSON.stringify(ADDON_DOWNLOAD_URL);
  const html = HtmlService.createHtmlOutput(
    '<div style="font-family:Arial,sans-serif;font-size:14px;padding:6px;">' +
      'Opening the addon page in a new tab…<br><br>' +
      'If nothing happens, <a href=' + url + ' target="_blank" rel="noopener">click here</a>.' +
    '</div>' +
    '<script>window.open(' + url + ',"_blank");</script>'
  ).setWidth(330).setHeight(110);
  SpreadsheetApp.getUi().showModalDialog(html, "Get The Addon");
}

function initSheet(sheet, fullInit) {
  if (!sheet) return;
  const lastRow = sheet.getLastRow();
  for (let r = 1; r <= lastRow; r++) {
    if (isHeaderRow(sheet, r)) {
      if (fullInit) checkAndResetExpiredLocks(sheet, r);
      applyVisibility(sheet, r, false); // collapse
      sheet.getRange(r, COL_TOGGLE).setValue(false);
    }
  }
}

// ============================================================
// COLLAPSE / EXPAND — per sheet
// ============================================================
function collapseChars() { setAllSpecs(SHEET_CHARS, false); }
function expandChars()   { setAllSpecs(SHEET_CHARS, true);  }
function collapseBiS()   { setAllSpecs(SHEET_BIS,   false); }
function expandBiS()     { setAllSpecs(SHEET_BIS,   true);  }

function setAllSpecs(sheetName, expand) {
  const sheet   = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(sheetName);
  if (!sheet) return;
  const lastRow = sheet.getLastRow();
  for (let r = 1; r <= lastRow; r++) {
    if (isHeaderRow(sheet, r)) {
      sheet.getRange(r, COL_TOGGLE).setValue(expand);
      applyVisibility(sheet, r, expand);
    }
  }
}

// ============================================================
// HELPERS
// ============================================================
function findDataEnd(sheet, headerRow) {
  const lastRow = sheet.getLastRow();
  for (let r = headerRow + 1; r <= lastRow; r++) {
    if (isHeaderRow(sheet, r)) return r - 1;
  }
  return lastRow;
}

function findHeaderRow(sheet, dataRow) {
  for (let r = dataRow - 1; r >= 1; r--) {
    if (isHeaderRow(sheet, r)) return r;
  }
  return -1;
}

function applyVisibility(sheet, headerRow, expand) {
  const start = headerRow + 1;
  const end   = findDataEnd(sheet, headerRow); // row before the next header = the spacer
  const count = end - start + 1;
  if (count < 1) return;
  // Include the trailing spacer row in the range so it collapses/expands WITH the
  // character — when collapsed, characters stack directly under one another.
  expand ? sheet.showRows(start, count) : sheet.hideRows(start, count);
}

// ============================================================
// ON EDIT — routes by sheet name
// ============================================================
function onEdit(e) {
  const sheet = e.range.getSheet();
  const name  = sheet.getName();

  // Only act on these two sheets
  if (name !== SHEET_CHARS && name !== SHEET_BIS) return;

  const row       = e.range.getRow();
  const col       = e.range.getColumn();
  const val       = e.value;
  const isChecked = val === "TRUE";

  // Only act on boolean changes (checkbox clicks)
  if (val !== "TRUE" && val !== "FALSE") return;

  if (isHeaderRow(sheet, row)) {
    // ── TOGGLE — works on BOTH sheets ──────────────────────
    if (col === COL_TOGGLE) {
      applyVisibility(sheet, row, isChecked);
      return;
    }

    // ── INSTANCE LOCKS — only on "My Characters" ───────────
    if (name === SHEET_CHARS) {
      const lock = LOCK_PAIRS.find(p => p.check === col);
      if (lock) handleInstanceLock(sheet, row, lock, isChecked);
    }

  } else {
    // ── CHECKBOX LOGIC — both sheets (BiS count works on each) ──
    if (col === COL_BIS_CHECK) {
      handleCheckbox(sheet, row, COL_BIS_CHECK, COL_BIS_NAME, isChecked);
    } else if (col === COL_ALT_CHECK) {
      handleCheckbox(sheet, row, COL_ALT_CHECK, COL_ALT_NAME, isChecked);
    } else if (col === COL_OTH_CHECK) {
      handleCheckbox(sheet, row, COL_OTH_CHECK, COL_OTH_NAME, isChecked);
    } else {
      return;
    }

    const headerRow = findHeaderRow(sheet, row);
    if (headerRow > 0) updateCounters(sheet, headerRow);
  }
}

// ============================================================
// CHECKBOX LOGIC — mutual exclusion of E, M, Z
// ============================================================
function handleCheckbox(sheet, row, checkedCol, nameCol, isChecked) {
  sheet.getRange(row, nameCol).setBackground(isChecked ? COLOR_HAVE : COLOR_GREY);
  if (!isChecked) return;

  const others = [
    { check: COL_BIS_CHECK, name: COL_BIS_NAME },
    { check: COL_ALT_CHECK, name: COL_ALT_NAME },
    { check: COL_OTH_CHECK, name: COL_OTH_NAME },
  ].filter(p => p.check !== checkedCol);

  others.forEach(pair => {
    if (isCheckbox(sheet, row, pair.check)) {
      sheet.getRange(row, pair.check).setValue(false);
      sheet.getRange(row, pair.name).setBackground(COLOR_GREY);
    }
  });
}

// ============================================================
// COUNTERS — "X / Y BiS - <n> GS" in G of header row
// ============================================================
function updateCounters(sheet, headerRow) {
  const dataEnd = findDataEnd(sheet, headerRow);
  let count = 0, total = 0;

  for (let r = headerRow + 2; r <= dataEnd; r++) {
    const slotVal = sheet.getRange(r, COL_SLOT).getValue();
    if (!slotVal) continue; // skip spacer rows
    total++;
    const bis = sheet.getRange(r, COL_BIS_CHECK).getValue() === true;
    const alt = isCheckbox(sheet, r, COL_ALT_CHECK) &&
                sheet.getRange(r, COL_ALT_CHECK).getValue() === true;
    if (bis || alt) count++;
  }

  // Preserve any existing " - <n> GS" suffix so a manual checkbox toggle
  // (which calls this) doesn't wipe the imported GearScore.
  const cur    = sheet.getRange(headerRow, COL_BIS_NAME).getValue().toString();
  const m      = cur.match(/-\s*(\d+)\s*GS\s*$/i);
  const suffix = m ? ` - ${m[1]} GS` : "";
  sheet.getRange(headerRow, COL_BIS_NAME).setValue(`${count} / ${total} BiS${suffix}`);
}

// Write the imported GearScore as a " - <n> GS" suffix on the "X / Y BiS"
// header (col G). gs<=0 (unknown) → strip the suffix, leaving just the BiS count.
function setHeaderGearScore_(sheet, header, gs) {
  const cur  = sheet.getRange(header, COL_BIS_NAME).getValue().toString();
  const base = cur.replace(/\s*-\s*\d+\s*GS\s*$/i, "").trim(); // drop old GS suffix
  const text = (gs && gs > 0) ? `${base} - ${gs} GS` : base;
  sheet.getRange(header, COL_BIS_NAME).setValue(text);
}

// ============================================================
// INSTANCE LOCK — red label + date stamp
// ============================================================
function handleInstanceLock(sheet, row, lock, isLocked) {
  checkAndResetExpiredLocks(sheet, row);
  sheet.getRange(row, lock.label).setBackground(isLocked ? COLOR_LOCKED : COLOR_GREY);
  sheet.getRange(row, COL_OTH_NAME).setValue(new Date());
}

// ============================================================
// ID RESET — Wednesday weekly reset
// ============================================================
function getLastWednesday() {
  const now      = new Date();
  const day      = now.getDay();
  const daysBack = day >= 3 ? day - 3 : day + 4;
  const wed      = new Date(now);
  wed.setDate(now.getDate() - daysBack);
  wed.setHours(0, 0, 0, 0);
  return wed;
}

function checkAndResetExpiredLocks(sheet, headerRow) {
  const raw = sheet.getRange(headerRow, COL_OTH_NAME).getValue();
  let storedDate = null;

  if (raw instanceof Date) {
    storedDate = raw;
  } else if (typeof raw === "string" && raw.length > 0) {
    const parts = raw.split(" ")[0].split(".");
    if (parts.length === 3) storedDate = new Date(parts[2], parts[1] - 1, parts[0]);
  }

  if (!storedDate || isNaN(storedDate) || storedDate >= getLastWednesday()) return;

  LOCK_PAIRS.forEach(p => {
    sheet.getRange(headerRow, p.check).setValue(false);
    sheet.getRange(headerRow, p.label).setBackground(COLOR_GREY);
  });

  const now = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "dd.MM.yyyy");
  const wed = Utilities.formatDate(getLastWednesday(), Session.getScriptTimeZone(), "dd.MM.");
  sheet.getRange(headerRow, COL_OTH_NAME).setValue(`${now} (ID Reset ${wed})`);
}

// ============================================================
// ADDON IMPORT — "Update All" button
// ============================================================

// C1 — read the pasted addon string from Addon!C4 (merged C4:L9; the value
// lives in the top-left cell). Returns the trimmed string ("" if empty/missing).
function readAddonString_() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_ADDON);
  if (!sheet) return "";
  const raw = sheet.getRange(PASTE_CELL).getValue();
  return (raw === null || raw === undefined) ? "" : raw.toString().trim();
}

// C2 — parse ONE entry: "Name.Spec;<17 gear>;<gearscore>;<6 lock bits>".
// Returns {ok, name, spec, gear[17], gs, locks[6], error}. On failure ok=false +
// a human-readable error (used to abort the whole import before any writes).
function parseEntry_(s) {
  const fail = (error) => ({ ok: false, error: error });
  s = (s || "").trim();
  if (s === "") return fail("empty entry");

  const sections = s.split(";");

  const info = (sections[0] || "").split(".");
  if (info.length < 2) {
    return fail(`bad "Name.Spec.Realm" segment: "${sections[0]}"`);
  }
  const name  = info[0].trim();
  const spec  = info[1].trim();
  const realm = info.slice(2).join(".").trim(); // "" if the export omitted a realm
  if (name === "" || spec === "") return fail(`empty name or spec: "${sections[0]}"`);

  const gear = (sections[1] || "").split("-");
  if (gear.length !== 17) {
    return fail(`expected 17 gear slots, got ${gear.length} (${name})`);
  }

  const gsRaw = (sections[2] || "").trim();
  if (!/^\d+$/.test(gsRaw)) {
    return fail(`bad GearScore "${gsRaw}" (need a number) (${name})`);
  }
  const gs = parseInt(gsRaw, 10);

  const locks = (sections[3] || "").trim();
  if (!/^[01]{6}$/.test(locks)) {
    return fail(`bad lock bits "${locks}" (need 6× 0/1) (${name})`);
  }

  return { ok: true, name: name, spec: spec, realm: realm, gear: gear, gs: gs, locks: locks.split("") };
}

// C3 — parse the WHOLE paste: split on "|", validate every entry.
// This is the gate: ok is true only if there is >=1 entry and ALL are valid.
// Returns {ok, entries:[parsed], errors:["entry N: ..."]}.
function parseAddonString_(raw) {
  const result = { ok: false, entries: [], errors: [] };
  raw = (raw || "").trim();
  if (raw === "") {
    result.errors.push("paste cell is empty");
    return result;
  }

  const parts = raw.split("|");
  for (let i = 0; i < parts.length; i++) {
    const piece = parts[i].trim();
    if (piece === "") continue; // tolerate stray/trailing separators
    const parsed = parseEntry_(piece);
    if (parsed.ok) {
      result.entries.push(parsed);
    } else {
      result.errors.push(`entry ${i + 1}: ${parsed.error}`);
    }
  }

  if (result.entries.length === 0 && result.errors.length === 0) {
    result.errors.push("no entries found");
  }
  result.ok = result.errors.length === 0 && result.entries.length > 0;
  return result;
}

// Keyed polynomial checksum over a string (ASCII). Must match the addon's
// ExportChecksum() exactly. P = 2^31-1 keeps h*257 within exact double range.
function checksum_(s) {
  const P = 2147483647;
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h * 257 + s.charCodeAt(i)) % P;
  }
  return h;
}

// Split "<payload>~<checksum>" and verify it against EXPORT_SECRET. The checksum
// makes hand-edited exports detectable: any change to the payload yields a
// different hash. Returns {ok, payload} or {ok:false, error}.
function verifyChecksum_(raw) {
  raw = (raw || "").trim();
  const msg = "The exported string was edited, is corrupt or invalid. Try exporting again.";
  const sep = raw.lastIndexOf("~");
  if (sep < 0) return { ok: false, error: msg };
  const payload = raw.slice(0, sep);
  const given   = raw.slice(sep + 1).trim();
  if (String(checksum_(EXPORT_SECRET + payload)) !== given) {
    return { ok: false, error: msg };
  }
  return { ok: true, payload: payload };
}

// C4a — turn the export spec label into the sheet's display name (icon alt-text):
// swap "-" back to spaces (the export wrote the full spec name with "-" for spaces).
function normalizeSpec_(s) {
  s = (s || "").trim();
  return s.replace(/-/g, " ").trim();
}

// C4b — given a sheet slot name (col B) and the 17-token export gear array,
// return the token for that slot. Ring/Trinket appear twice per block and are
// resolved by order of appearance, tracked in `counters` ({ring,trinket}),
// which the caller resets per block and this function mutates. Returns the
// token string, or null when the slot name is unknown / index out of range.
function resolveGear_(slotName, gearArr, counters) {
  slotName = (slotName || "").toString().trim();
  if (slotName === "") return null;

  let idx; // 1-based export index
  if (slotName === "Ring") {
    idx = RING_IDX[counters.ring];
    counters.ring++;
  } else if (slotName === "Trinket") {
    idx = TRINKET_IDX[counters.trinket];
    counters.trinket++;
  } else {
    idx = SLOT_EXPORT_IDX[slotName];
  }

  if (!idx || idx < 1 || idx > gearArr.length) return null;
  return gearArr[idx - 1];
}

// C5a — the spec a block represents, read from the col-A in-cell icon's
// alt-text. The spec name lives in the DESCRIPTION; the Title is usually
// Google's generic default ("Bild"/"Image"), so prefer Description and ignore
// that default. "" if no image / no usable alt-text.
function blockSpec_(sheet, headerRow) {
  const val = sheet.getRange(headerRow, 1).getValue();
  if (!val || typeof val.getAltTextDescription !== "function") return "";

  const desc = (val.getAltTextDescription() || "").trim();
  if (desc !== "") return desc;

  const title = (val.getAltTextTitle() || "").trim();
  const tl = title.toLowerCase();
  if (title !== "" && tl !== "bild" && tl !== "image") return title;
  return "";
}

// C5b — find an existing character block in "My Characters":
// col-B header text == name AND col-A icon alt-text == spec (display name).
// Returns {header, dataEnd} or null.
function findCharBlock_(sheet, name, spec) {
  const lastRow = sheet.getLastRow();
  for (let r = 2; r <= lastRow; r++) { // skip protected title row 1
    if (!isHeaderRow(sheet, r)) continue;
    const label = sheet.getRange(r, COL_SLOT).getValue().toString().trim();
    if (label === name && blockSpec_(sheet, r) === spec) {
      return { header: r, dataEnd: findDataEnd(sheet, r) };
    }
  }
  return null;
}

// C5c — find the template block for a spec on "Classes BiS" (col-A icon
// alt-text == spec). Returns {header, dataEnd} or null.
function findTemplateBlock_(bisSheet, spec) {
  const lastRow = bisSheet.getLastRow();
  for (let r = 1; r <= lastRow; r++) {
    if (!isHeaderRow(bisSheet, r)) continue;
    const label = bisSheet.getRange(r, COL_SLOT).getValue().toString().trim();
    if (blockSpec_(bisSheet, r) === spec || label === spec) {
      return { header: r, dataEnd: findDataEnd(bisSheet, r) };
    }
  }
  return null;
}

// C5d — first free row to append a NEW character block in "My Characters":
// after the last block + one spacer row. Never returns the protected row 1.
function findAppendRow_(sheet) {
  const lastRow = sheet.getLastRow();
  let lastHeader = -1;
  for (let r = 2; r <= lastRow; r++) {
    if (isHeaderRow(sheet, r)) lastHeader = r;
  }
  // First character sits directly under the protected title (no gap). Later
  // blocks keep exactly one spacer row between them: the previous block's
  // trailing spacer is formatting-only so getLastRow/findDataEnd don't count it,
  // hence +2 steps past it.
  if (lastHeader === -1) return Math.max(lastRow + 1, 2);
  return Math.max(findDataEnd(sheet, lastHeader) + 2, 2);
}

// ── Wowhead name resolution for "Other" items ───────────────

// Wowhead WotLK item page URL.
function wowheadItemUrl_(id) {
  return "https://www.wowhead.com/wotlk/item=" + id;
}

// Extract the item name from a Wowhead JSON tooltip response. "" on failure.
function parseWowheadName_(text) {
  try {
    const obj = JSON.parse(text);
    return (obj && obj.name) ? String(obj.name).trim() : "";
  } catch (e) {
    return "";
  }
}

// Gather the unique numeric "Other" item IDs across all parsed entries. The
// codes "0"/"1"/"2" are empty/BiS/Alt — every other numeric token is an item ID.
function collectOtherIds_(entries) {
  const seen = {};
  const ids  = [];
  entries.forEach(entry => {
    entry.gear.forEach(token => {
      if (/^\d+$/.test(token) && token !== "0" && token !== "1" && token !== "2" && !seen[token]) {
        seen[token] = true;
        ids.push(token);
      }
    });
  });
  return ids;
}

// Resolve item IDs to names: cache-first (Document Properties, key "wh_<id>"),
// then ONE batched fetchAll for the rest (item names are immutable, so the cache
// never needs invalidation). Returns an {id: name} map; unresolved ids are simply
// absent and the caller falls back to the bare ID at write time.
function resolveItemNames_(ids) {
  const map = {};
  if (!ids || ids.length === 0) return map;

  const props   = PropertiesService.getDocumentProperties();
  const cached   = props.getProperties();
  const toFetch  = [];
  ids.forEach(id => {
    const hit = cached["wh_" + id];
    if (hit) map[id] = hit;
    else toFetch.push(id);
  });

  if (toFetch.length > 0) {
    const requests = toFetch.map(id => ({
      url: "https://nether.wowhead.com/wotlk/tooltip/item/" + id,
      muteHttpExceptions: true,
    }));
    let responses = [];
    try {
      responses = UrlFetchApp.fetchAll(requests);
    } catch (e) {
      responses = []; // network failure → leave ids unresolved (graceful)
    }
    const toSave = {};
    responses.forEach((resp, i) => {
      const id = toFetch[i];
      if (resp && resp.getResponseCode() === 200) {
        const name = parseWowheadName_(resp.getContentText());
        if (name) { map[id] = name; toSave["wh_" + id] = name; }
      }
    });
    if (Object.keys(toSave).length > 0) {
      try { props.setProperties(toSave, false); } catch (e) {}
    }
  }

  return map;
}

// ── UwU Logs character link (header col H) ──────────────────

// Build the UwU Logs character URL for a char name + display spec + realm
// (falls back to UWU_SERVER when the realm is empty).
function uwuLogsUrl_(charName, specDisplay, realm) {
  const id  = SPEC_UWU_ID[specDisplay] || 0; // 0 = base/unknown
  const server = (realm && realm.trim() !== "") ? realm.trim() : UWU_SERVER;
  return "https://uwu-logs.xyz/character?name=" + encodeURIComponent(charName) +
         "&server=" + encodeURIComponent(server) + "&spec=" + id;
}

// Turn the header's col-H "UwU Logs" cell into a hyperlink for this char/spec/realm.
// Force black text so it doesn't render as the default hyperlink blue.
function applyUwuLink_(sheet, header, charName, specDisplay, realm) {
  const url   = uwuLogsUrl_(charName, specDisplay, realm);
  const black = SpreadsheetApp.newTextStyle().setForegroundColor("#000000").build();
  const rt    = SpreadsheetApp.newRichTextValue()
    .setText("UwU Logs")
    .setLinkUrl(url)
    .setTextStyle(black)
    .build();
  sheet.getRange(header, COL_LOGS).setRichTextValue(rt);
}

// C6a — set one data row to a single choice ("none"|"bis"|"alt"|"oth"),
// enforcing mutual exclusion (mirrors handleCheckbox). Only touches cells that
// actually hold a checkbox. For "oth" with a numeric item ID, writes the item
// NAME into AA as a hyperlink to Wowhead (falls back to the ID as the label when
// the name is unknown); otherwise clears AA so a stale Other name never lingers.
function applySlotChoice_(sheet, row, choice, otherText, nameMap) {
  const cells = [
    { check: COL_BIS_CHECK, name: COL_BIS_NAME, key: "bis" },
    { check: COL_ALT_CHECK, name: COL_ALT_NAME, key: "alt" },
    { check: COL_OTH_CHECK, name: COL_OTH_NAME, key: "oth" },
  ];
  cells.forEach(c => {
    if (!isCheckbox(sheet, row, c.check)) return;
    const on = (c.key === choice);
    sheet.getRange(row, c.check).setValue(on);
    sheet.getRange(row, c.name).setBackground(on ? COLOR_HAVE : COLOR_GREY);
  });

  if (choice === "oth") {
    const token = otherText == null ? "" : String(otherText);
    if (/^\d+$/.test(token)) {
      const label = (nameMap && nameMap[token]) ? nameMap[token] : token;
      const url   = wowheadItemUrl_(token);
      const rt    = SpreadsheetApp.newRichTextValue().setText(label).setLinkUrl(url).build();
      sheet.getRange(row, COL_OTH_NAME).setRichTextValue(rt);
    } else {
      sheet.getRange(row, COL_OTH_NAME).setValue(token); // non-numeric fallback name, no link
    }
  } else {
    sheet.getRange(row, COL_OTH_NAME).setValue(""); // clear stale Other name (also clears any link)
  }
}

// C6b — write all gear tokens for a block, refresh its "X / Y BiS" counter, and
// stamp the imported GearScore as the " - <n> GS" suffix on that header.
//   "0" empty | "1" BiS | "2" Alt | anything else = Other item ID (→ AA).
function applyGear_(sheet, header, gearArr, nameMap, gs) {
  const dataEnd  = findDataEnd(sheet, header);
  const counters = { ring: 0, trinket: 0 };
  for (let r = header + 2; r <= dataEnd; r++) { // header+1 = label row
    const slotName = sheet.getRange(r, COL_SLOT).getValue();
    if (!slotName) continue; // spacer row
    const token = resolveGear_(slotName, gearArr, counters);
    if (token === null) continue; // unknown slot — leave untouched
    if (token === "0")      applySlotChoice_(sheet, r, "none", null,  nameMap);
    else if (token === "1") applySlotChoice_(sheet, r, "bis",  null,  nameMap);
    else if (token === "2") applySlotChoice_(sheet, r, "alt",  null,  nameMap);
    else                    applySlotChoice_(sheet, r, "oth",  token, nameMap);
  }
  updateCounters(sheet, header);
  setHeaderGearScore_(sheet, header, gs); // GS travels with gear (Update All / Equipment)
}

// C6c — write the 6 instance-lock bits onto a block's header row + date stamp.
// Bit order matches LOCK_PAIRS: ICC25, ICC10, RS25, RS10, ToC25, ToC10.
function applyLocks_(sheet, header, locksArr) {
  for (let i = 0; i < LOCK_PAIRS.length; i++) {
    const p      = LOCK_PAIRS[i];
    const locked = locksArr[i] === "1";
    sheet.getRange(header, p.check).setValue(locked);
    sheet.getRange(header, p.label).setBackground(locked ? COLOR_LOCKED : COLOR_GREY);
  }
}

// Stamp the header's "Updated" date (col AA) to now — the "last updated" marker
// shown on the header AND the reference read by checkAndResetExpiredLocks.
function stampUpdatedDate_(sheet, header) {
  sheet.getRange(header, COL_OTH_NAME).setValue(new Date());
}

// C7 — copy a "Classes BiS" template block onto "My Characters" at appendRow.
// Full-width copyTo carries values, formatting, checkboxes AND the in-cell
// class icon (CellImage, whose alt-text keeps identifying the spec). Then the
// new header's col B is renamed from the spec name to the character name, and
// the block is marked expanded (col AB toggle = TRUE) with its rows shown.
// Returns the new header row (== appendRow).
function copyTemplate_(bisSheet, charsSheet, tmplHeader, tmplDataEnd, appendRow, charName) {
  const numRows = tmplDataEnd - tmplHeader + 1;
  const numCols = bisSheet.getMaxColumns();

  // Grow the destination grid if needed — an almost-empty "My Characters" can have
  // fewer rows/columns than a block, which would make copyTo throw "destination
  // outside the sheet's dimensions".
  const needRows = appendRow + numRows - 1;
  if (needRows > charsSheet.getMaxRows()) {
    charsSheet.insertRowsAfter(charsSheet.getMaxRows(), needRows - charsSheet.getMaxRows());
  }
  if (numCols > charsSheet.getMaxColumns()) {
    charsSheet.insertColumnsAfter(charsSheet.getMaxColumns(), numCols - charsSheet.getMaxColumns());
  }

  const src  = bisSheet.getRange(tmplHeader, 1, numRows, numCols);
  const dest = charsSheet.getRange(appendRow, 1, numRows, numCols);
  src.copyTo(dest); // values + format + checkboxes + in-cell images
  charsSheet.getRange(appendRow, COL_SLOT).setValue(charName);   // spec name → char name
  charsSheet.getRange(appendRow, COL_TOGGLE).setValue(true);     // mark expanded
  applyVisibility(charsSheet, appendRow, true);                  // keep rows shown to match
  return appendRow;
}

// Scan every character block in "My Characters" top-to-bottom.
// Returns [{header, dataEnd, name, spec, key}] (key = "name spec").
function scanBlocks_(sheet) {
  const lastRow = sheet.getLastRow();
  const blocks  = [];
  for (let r = 2; r <= lastRow; r++) {
    if (!isHeaderRow(sheet, r)) continue;
    const name = sheet.getRange(r, COL_SLOT).getValue().toString().trim();
    const spec = blockSpec_(sheet, r);
    blocks.push({ header: r, dataEnd: findDataEnd(sheet, r), name: name, spec: spec, key: name + " " + spec });
  }
  return blocks;
}

// Reorder "My Characters" blocks to match desiredKeys (the export's character
// order). Blocks whose key isn't in desiredKeys (e.g. a character no longer
// exported) are kept and appended after, in their current order. No-op when the
// order already matches. Strategy: re-copy each block (full-width copyTo preserves
// values/format/checkboxes/in-cell icons/merges) to fresh rows below the current
// content in the target order, then delete the originals so the rebuilt region
// slides up into place. Row visibility (which copyTo can't carry) is restored from
// each block's toggle checkbox afterwards. A new character that sits between two
// existing ones in the export thus lands at that same spot here.
function reorderBlocks_(charsSheet, desiredKeys) {
  const blocks = scanBlocks_(charsSheet);
  if (blocks.length < 2) return;

  const byKey = {};
  blocks.forEach(b => { if (byKey[b.key] === undefined) byKey[b.key] = b; });

  const seen   = {};
  const target = [];
  desiredKeys.forEach(k => { if (byKey[k] && !seen[k]) { seen[k] = true; target.push(byKey[k]); } });
  blocks.forEach(b => { if (!seen[b.key]) { seen[b.key] = true; target.push(b); } });

  // Already in the desired order → nothing to do (the "no mismatch" fast path).
  if (target.length === blocks.length && target.every((b, i) => b.header === blocks[i].header)) return;

  const numCols       = charsSheet.getMaxColumns();
  const firstBlockRow = blocks[0].header;
  const appendStart   = charsSheet.getLastRow() + 2; // clear gap below current content
  let   cursor        = appendStart;

  target.forEach(b => {
    // Trim trailing spacer rows (empty slot col) so every block keeps exactly one
    // gap row — otherwise a middle block's existing spacer + our added spacer would
    // make gaps grow on each reorder.
    let end = b.dataEnd;
    while (end > b.header && charsSheet.getRange(end, COL_SLOT).getValue().toString().trim() === "") end--;
    const rows = end - b.header + 1;
    const need = cursor + rows - 1;
    if (need > charsSheet.getMaxRows()) {
      charsSheet.insertRowsAfter(charsSheet.getMaxRows(), need - charsSheet.getMaxRows());
    }
    charsSheet.getRange(b.header, 1, rows, numCols)
              .copyTo(charsSheet.getRange(cursor, 1, rows, numCols));
    cursor += rows + 1; // one spacer row between blocks
  });

  // Remove the originals (and the gap above the rebuilt region); the rebuilt blocks
  // shift up to start exactly at firstBlockRow.
  charsSheet.deleteRows(firstBlockRow, appendStart - firstBlockRow);

  scanBlocks_(charsSheet).forEach(b => {
    applyVisibility(charsSheet, b.header, charsSheet.getRange(b.header, COL_TOGGLE).getValue() === true);
  });
}

// C8 — shared core for the three import buttons. Validates the paste FIRST and
// aborts with an alert (no partial writes) if anything is malformed.
//   opts = { label, gear, locks, create, reorder }
//     gear/locks — which sections to write per character
//     create     — if true, missing characters are created from the Classes BiS
//                  template; if false (partial buttons), missing chars are skipped
//                  (they need a full "Update All" first to exist).
//     reorder    — if true, after writing, reorder "My Characters" blocks to match
//                  the export's character order (new chars land at their position).
// NOTE: when the "Undo Last Changes" feature is built (full-snapshot design),
// take the My Characters backup here, at the top of the try block.
function runUpdate_(opts) {
  const ui   = SpreadsheetApp.getUi();
  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(30000);
  } catch (e) {
    ui.alert(opts.label, "Another update is already running. Try again shortly.", ui.ButtonSet.OK);
    return;
  }

  try {
    const ss         = SpreadsheetApp.getActiveSpreadsheet();
    const charsSheet = ss.getSheetByName(SHEET_CHARS);
    const bisSheet   = ss.getSheetByName(SHEET_BIS);
    if (!charsSheet || !bisSheet) {
      ui.alert(opts.label, `Missing a required sheet ("${SHEET_CHARS}" or "${SHEET_BIS}").`, ui.ButtonSet.OK);
      return;
    }

    // Integrity gate — verify the checksum, then validate the payload. Either
    // failure aborts before touching anything.
    const raw   = readAddonString_();
    const check = verifyChecksum_(raw);
    if (!check.ok) {
      ui.alert(opts.label + " — invalid addon string", "Nothing was changed.\n\n" + check.error, ui.ButtonSet.OK);
      return;
    }
    const parsed = parseAddonString_(check.payload);
    if (!parsed.ok) {
      ui.alert(opts.label + " — invalid addon string",
        "Nothing was changed.\n\n" + parsed.errors.slice(0, 10).join("\n"),
        ui.ButtonSet.OK);
      return;
    }

    // Snapshot "My Characters" BEFORE any writes so "Undo Last Changes" can revert it.
    snapshotForUndo_(ss);

    // Only fetch Wowhead names when gear is actually being written.
    const nameMap = opts.gear ? resolveItemNames_(collectOtherIds_(parsed.entries)) : {};

    let updated = 0, created = 0, skipped = 0;
    const problems = [];

    parsed.entries.forEach(entry => {
      const spec  = normalizeSpec_(entry.spec);
      const block = findCharBlock_(charsSheet, entry.name, spec);

      let header;
      if (block) {
        header = block.header;
      } else if (opts.create) {
        const tmpl = findTemplateBlock_(bisSheet, spec);
        if (!tmpl) {
          problems.push(`${entry.name} (${spec}): no matching block on "${SHEET_BIS}"`);
          skipped++;
          return;
        }
        header = copyTemplate_(bisSheet, charsSheet, tmpl.header, tmpl.dataEnd,
                               findAppendRow_(charsSheet), entry.name);
        created++;
      } else {
        problems.push(`${entry.name} (${spec}): no block yet — run "Update All" first`);
        skipped++;
        return;
      }

      if (opts.gear)  applyGear_(charsSheet, header, entry.gear, nameMap, entry.gs);
      if (opts.locks) applyLocks_(charsSheet, header, entry.locks);
      applyUwuLink_(charsSheet, header, entry.name, spec, entry.realm);
      stampUpdatedDate_(charsSheet, header);
      if (block) updated++;
    });

    // Reorder blocks to mirror the export's character order (Update All only).
    if (opts.reorder && updated + created > 0) {
      reorderBlocks_(charsSheet, parsed.entries.map(e => e.name + " " + normalizeSpec_(e.spec)));
    }

    // On a run that changed something: log the update (type + time in "Your last
    // Updates", full string in the Last box) and clear the paste cell.
    if (updated + created > 0) {
      recordUpdate_(ss, opts.logType, raw);
      ss.getSheetByName(SHEET_ADDON).getRange(PASTE_CELL).clearContent();
    }

    const summary = `Updated ${updated}, created ${created}` + (skipped ? `, skipped ${skipped}` : "");
    if (problems.length) {
      ui.alert(opts.label + " — done with warnings",
        summary + "\n\n" + problems.slice(0, 10).join("\n"), ui.ButtonSet.OK);
    } else {
      ss.toast(summary, opts.label, 5);
    }
  } catch (err) {
    ui.alert(opts.label + " — error", String(err && err.stack ? err.stack : err), ui.ButtonSet.OK);
  } finally {
    lock.releaseLock();
  }
}

// Button entry points (assign these to the sheet's drawings / menu items).
function updateAll()           { runUpdate_({ label: "Update All",            logType: "Everything",     gear: true,  locks: true,  create: true,  reorder: true }); }
function updateEquipment()     { runUpdate_({ label: "Update Equipment",      logType: "Characters",     gear: true,  locks: false, create: false }); }
function updateInstanceLocks() { runUpdate_({ label: "Update Instance Locks", logType: "Instance Locks", gear: false, locks: true,  create: false }); }

// True if the spreadsheet's locale region conventionally uses a 12-hour (am/pm)
// clock. Apps Script runs server-side and CANNOT read the user's PC clock setting,
// so this is derived from the spreadsheet locale (e.g. en_US → 12h, de_DE → 24h).
function uses12hClock_(ss) {
  const loc = (ss.getSpreadsheetLocale() || Session.getActiveUserLocale() || "").toLowerCase();
  return /(^en$)|_(us|ca|au|nz|ph|in|pk)$/.test(loc);
}

// Local date+time stamp: "dd.MM.yy HH:mm" (24h) or "dd.MM.yy hh:mm a" (12h am/pm),
// in the spreadsheet's timezone.
function formatUpdateStamp_(ss) {
  const tz = ss.getSpreadsheetTimeZone() || Session.getScriptTimeZone();
  const pattern = uses12hClock_(ss) ? "dd.MM.yy hh:mm a" : "dd.MM.yy HH:mm";
  return Utilities.formatDate(new Date(), tz, pattern);
}

// Style the "Last Update String" box for displaying a pasted/applied string:
// top-left aligned, font size 12, black.
function styleStringBox_(sheet) {
  sheet.getRange(LAST_STRING_RANGE)
    .setFontSize(12)
    .setFontColor("#000000")
    .setFontWeight("normal")
    .setFontStyle("normal")
    .setHorizontalAlignment("left")
    .setVerticalAlignment("top");
}

// Fill the "Last Update String" box with the "Nothing to Undo.." placeholder:
// centered horizontally + vertically, font size 32, light grey.
function showUndoPlaceholder_(sheet) {
  sheet.getRange(LAST_STRING_CELL).setValue(UNDO_PLACEHOLDER);
  sheet.getRange(LAST_STRING_RANGE)
    .setFontSize(32)
    .setFontColor(COLOR_GREY)
    .setFontWeight("normal")
    .setFontStyle("normal")
    .setHorizontalAlignment("center")
    .setVerticalAlignment("middle");
}

// Record one update event: set the "Last Addon update String" box to the full
// applied string, and push [type, local timestamp] onto the "Your last Updates"
// log (W4:X9, newest first; entries past row 9 are dropped).
function recordUpdate_(ss, logType, raw) {
  const sheet = ss.getSheetByName(SHEET_ADDON);
  if (!sheet) return;

  if (raw) {
    sheet.getRange(LAST_STRING_CELL).setValue(raw);
    styleStringBox_(sheet); // left-top, size 12, black (overrides any placeholder styling)
  }

  const range = sheet.getRange(LOG_ROW, LOG_COL_TYPE, LOG_LEN, 2); // W4:X9
  const cur   = range.getValues();                                  // [[type, time], ...]
  const next  = [[logType, formatUpdateStamp_(ss)]].concat(cur).slice(0, LOG_LEN);
  range.setValues(next);
}

// Full-sheet snapshot of "My Characters" for one-level Undo. Replaces any prior
// backup; taken before a run writes anything. A sheet copy faithfully preserves
// gear, locks, links, in-cell icons, checkboxes, merges and formatting.
function snapshotForUndo_(ss) {
  const src = ss.getSheetByName(SHEET_CHARS);
  if (!src) return;
  const old = ss.getSheetByName(BACKUP_SHEET);
  if (old) ss.deleteSheet(old);
  const backup = src.copyTo(ss);
  backup.setName(BACKUP_SHEET);
  backup.hideSheet();
}

// "Undo Last Changes" — revert "My Characters" from the snapshot, then remove the
// top "Your last Updates" entry (the update just undone). GUARD: if there is no
// snapshot, do NOTHING (never touch the sheet or its title row). One level deep.
function undoLastChanges() {
  const ui   = SpreadsheetApp.getUi();
  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(30000);
  } catch (e) {
    ui.alert("Undo Last Changes", "Another action is running. Try again shortly.", ui.ButtonSet.OK);
    return;
  }
  try {
    const ss     = SpreadsheetApp.getActiveSpreadsheet();
    const backup = ss.getSheetByName(BACKUP_SHEET);
    if (!backup) {
      ui.alert("Undo Last Changes", "Nothing to undo.", ui.ButtonSet.OK);
      return; // no snapshot → leave My Characters (incl. row 1) untouched
    }

    // Restore the sheet from the snapshot.
    const cur = ss.getSheetByName(SHEET_CHARS);
    const pos = cur ? cur.getIndex() : 1;
    if (cur) ss.deleteSheet(cur);
    const restored = backup.copyTo(ss);
    restored.setName(SHEET_CHARS);
    restored.showSheet();
    ss.setActiveSheet(restored);
    ss.moveActiveSheet(pos);
    ss.deleteSheet(backup); // one snapshot consumed

    // Pop the top entry from the "Your last Updates" log (the update just undone),
    // and reset the "Last Update String" box to the "Nothing to Undo.." placeholder.
    const addon = ss.getSheetByName(SHEET_ADDON);
    if (addon) {
      const range = addon.getRange(LOG_ROW, LOG_COL_TYPE, LOG_LEN, 2);
      range.setValues(range.getValues().slice(1).concat([["", ""]]));
      showUndoPlaceholder_(addon);
    }

    ss.toast("Reverted the last update.", "Undo Last Changes", 5);
  } catch (err) {
    ui.alert("Undo Last Changes — error", String(err && err.stack ? err.stack : err), ui.ButtonSet.OK);
  } finally {
    lock.releaseLock();
  }
}