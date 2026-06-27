// BiSTracker Sheet Script — "My Characters" (full) + "Classes BiS" (collapse only).

// ===== Sheet names =====
const SHEET_CHARS = "My Characters";
const SHEET_BIS   = "Classes BiS";
const SHEET_ADDON = "Addon";            // paste cell + buttons
const BACKUP_SHEET = "_MyCharsBackup";  // hidden one-level undo snapshot

// Row on "Classes BiS" holding the styled group-header template (copied on import).
const GROUP_TEMPLATE_ROW = 555;

// ===== Column map (shared by both sheets) =====
const COL_GROUP_LABEL  = 1;   // A — "Account - Realm" group-header text
const COL_SLOT         = 2;   // B — slot name (data) / character name (header)
const COL_BIS_CHECK    = 6;   // F — BiS checkbox (E holds the icon)
const COL_BIS_NAME     = 7;   // G — BiS item name / "X / Y BiS" header
const COL_LOGS         = 8;   // H — "UwU Logs" link
const COL_GROUP_TOGGLE = 9;   // I — group collapse checkbox (TRUE = expanded)
const COL_ALT_CHECK    = 13;  // M — Alt checkbox
const COL_ALT_NAME     = 14;  // N — Alt item name
const COL_OTH_CHECK    = 26;  // Z — Other checkbox
const COL_OTH_NAME     = 27;  // AA — Other item / date stamp
const COL_TOGGLE       = 28;  // AB — block expand/collapse toggle (header only)

// Instance-lock checkbox/label column pairs (bit order = export lock bits).
const LOCK_PAIRS = [
  { check: 11, label: 12, inst: "ICC25" }, // K/L
  { check: 13, label: 14, inst: "ICC10" }, // M/N
  { check: 15, label: 16, inst: "RS25"  }, // O/P
  { check: 17, label: 18, inst: "RS10"  }, // Q/R
  { check: 19, label: 20, inst: "ToC25" }, // S/T
  { check: 21, label: 22, inst: "ToC10" }, // U/V
];

// ===== Colors =====
const COLOR_HAVE   = "#c8e1be"; // light green — selected cells
const COLOR_GREY   = "#D3D3D3";
const COLOR_LOCKED = "#ff2e2e";
const COLOR_PREBIS = "#e8821e"; // orange — Other item that matches BiS/Alt name (wrong ilvl)

// ===== Addon import config =====
const PASTE_CELL        = "C4";       // merged C4:L9 — value lives top-left
const LAST_STRING_CELL  = "C14";      // applied-string box anchor
const LAST_STRING_RANGE = "C14:L19";  // full applied-string box
const UNDO_PLACEHOLDER  = "Nothing to Undo..";
const LOG_ROW      = 4;   // "Your last Updates" log: rows 4..9, newest first
const LOG_LEN      = 6;
const LOG_COL_TYPE = 23;  // W — update type
const LOG_COL_TIME = 24;  // X — timestamp

// Timestamps use Warmane server time (GMT), identical for all players.
const UPDATE_TZ  = "GMT";
const UPDATE_24H = true;

const ADDON_DOWNLOAD_URL = "https://www.google.com"; // placeholder
const UWU_SERVER  = "Icecrown";                       // realm fallback for older exports
const EXPORT_SECRET = "BiSTrk!2026#warmane";          // MUST match the addon's Constants.lua

// Matches a trailing " - <n> GS" suffix on the "X / Y BiS" header (group 1 = the number).
const GS_SUFFIX = /\s*-\s*(\d+)\s*GS\s*$/i;

// Sheet slot name (col B) -> 1-based export gear index. Aliases: Shield->Off Hand,
// any ranged relic -> Ranged. Ring/Trinket are matched by item ID instead (see below).
const SLOT_EXPORT_IDX = {
  "Head": 1, "Neck": 2, "Shoulders": 3, "Chest": 4, "Waist": 5,
  "Legs": 6, "Leggs": 6, "Feet": 7, "Wrist": 8, "Hands": 9, "Back": 14,
  "Main Hand": 15, "Off Hand": 16, "Shield": 16,
  "Ranged": 17, "Crossbow": 17, "Bow": 17, "Gun": 17, "Thrown": 17, "Wand": 17,
  "Idol": 17, "Libram": 17, "Totem": 17, "Sigil": 17, "Relic": 17,
};
const RING_IDX    = [10, 11]; // two slots, matched to rows by item ID
const TRINKET_IDX = [12, 13];

// UwU Logs spec param = per-class talent-tree index (1/2/3), keyed by display spec name.
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

// ===== Row classification =====

// A character header carries "X / Y BiS" text in col G.
function isHeaderRow(sheet, row) {
  const val = sheet.getRange(row, COL_BIS_NAME).getValue().toString().toLowerCase();
  return val.indexOf("/") >= 0 && val.indexOf("bis") >= 0;
}

function isCheckbox(sheet, row, col) {
  const val = sheet.getRange(row, col).getValue();
  return val === true || val === false;
}

// All character-header rows (1-based) on a sheet — single column read.
function headerRows_(sheet) {
  const last = sheet.getLastRow();
  if (last < 1) return [];
  const col = sheet.getRange(1, COL_BIS_NAME, last, 1).getValues();
  const rows = [];
  for (let i = 0; i < col.length; i++) {
    const v = (col[i][0] || "").toString().toLowerCase();
    if (v.indexOf("/") >= 0 && v.indexOf("bis") >= 0) rows.push(i + 1);
  }
  return rows;
}

// A group header ("Account - Realm", My Characters): col A holds a " - " string and the
// row is neither a character header nor the protected title row 1.
function isGroupHeader_(sheet, row) {
  if (row <= 1 || isHeaderRow(sheet, row)) return false;
  const a = sheet.getRange(row, COL_GROUP_LABEL).getValue();
  return typeof a === "string" && a.indexOf(" - ") >= 0;
}

// ===== Group labels =====

// Canonical "Account - Realm" key (used for matching). Unset account -> "NoAccName".
function groupLabel_(account, realm) {
  account = (account || "").toString().trim() || "NoAccName";
  realm   = (realm   || "").toString().trim();
  return account + " - " + realm;
}

// Display label: canonical + " - <N> Char(s)" (count is display-only, stripped on parse).
function groupLabelWithCount_(canonicalLabel, charCount) {
  return canonicalLabel + " - " + charCount + " Char" + (charCount === 1 ? "" : "s");
}

// Split a group label into {account, realm} on the LAST " - "; drops the count suffix first.
function parseGroupLabel_(label) {
  label = (label || "").toString().trim().replace(/\s*-\s*\d+\s*chars?\s*$/i, "").trim();
  const i = label.lastIndexOf(" - ");
  if (i < 0) return { account: label, realm: "" };
  return { account: label.slice(0, i).trim(), realm: label.slice(i + 3).trim() };
}

// ===== Menus =====
function onOpen() {
  const ui = SpreadsheetApp.getUi();
  ui.createMenu("BiS Chars Sheet Functions")
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
  ui.createMenu("Get The Addon").addItem("Open download page", "getTheAddon").addToUi();

  const ss = SpreadsheetApp.getActiveSpreadsheet();
  initSheet(ss.getSheetByName(SHEET_CHARS), true);  // reset expired locks + collapse
  initSheet(ss.getSheetByName(SHEET_BIS),   false); // collapse only
}

// Open the addon download page in a new tab (Apps Script can't navigate directly).
function getTheAddon() {
  const url = JSON.stringify(ADDON_DOWNLOAD_URL);
  const html = HtmlService.createHtmlOutput(
    '<div style="font-family:Arial,sans-serif;font-size:14px;padding:6px;">' +
      'Opening the addon page in a new tab…<br><br>' +
      'If nothing happens, <a href=' + url + ' target="_blank" rel="noopener">click here</a>.' +
    '</div><script>window.open(' + url + ',"_blank");</script>'
  ).setWidth(330).setHeight(110);
  SpreadsheetApp.getUi().showModalDialog(html, "Get The Addon");
}

// Collapse every block; on full init also reset expired instance locks.
function initSheet(sheet, fullInit) {
  if (!sheet) return;
  headerRows_(sheet).forEach(r => {
    if (fullInit) resetExpiredLocks_(sheet, r);
    setBlockVisible_(sheet, r, false);
    sheet.getRange(r, COL_TOGGLE).setValue(false);
  });
}

// ===== Collapse / expand =====
function collapseChars() { setAllBlocks_(SHEET_CHARS, false); }
function expandChars()   { setAllBlocks_(SHEET_CHARS, true);  }
function collapseBiS()   { setAllBlocks_(SHEET_BIS,   false); }
function expandBiS()     { setAllBlocks_(SHEET_BIS,   true);  }

function setAllBlocks_(sheetName, expand) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(sheetName);
  if (!sheet) return;
  headerRows_(sheet).forEach(r => {
    sheet.getRange(r, COL_TOGGLE).setValue(expand);
    setBlockVisible_(sheet, r, expand);
  });
}

// ===== Block geometry =====

// Last row of a block — stops before the next character or group header.
function findDataEnd(sheet, headerRow) {
  const lastRow = sheet.getLastRow();
  for (let r = headerRow + 1; r <= lastRow; r++) {
    if (isHeaderRow(sheet, r) || isGroupHeader_(sheet, r)) return r - 1;
  }
  return lastRow;
}

// The character header above a data row (-1 if none).
function findHeaderRow(sheet, dataRow) {
  for (let r = dataRow - 1; r >= 1; r--) {
    if (isHeaderRow(sheet, r)) return r;
  }
  return -1;
}

// Show/hide a block's rows including its trailing spacer (so blocks stack when collapsed).
function setBlockVisible_(sheet, headerRow, expand) {
  const start = headerRow + 1;
  const count = findDataEnd(sheet, headerRow) - start + 1;
  if (count < 1) return;
  expand ? sheet.showRows(start, count) : sheet.hideRows(start, count);
}

// ===== onEdit — routes checkbox clicks =====
function onEdit(e) {
  const sheet = e.range.getSheet();
  const name  = sheet.getName();
  if (name !== SHEET_CHARS && name !== SHEET_BIS) return;
  if (e.value !== "TRUE" && e.value !== "FALSE") return; // boolean (checkbox) edits only

  const row     = e.range.getRow();
  const col     = e.range.getColumn();
  const checked = e.value === "TRUE";

  // Group collapse — checkbox on an "Account - Realm" header (My Characters only).
  if (name === SHEET_CHARS && isGroupHeader_(sheet, row)) {
    setGroupVisible_(sheet, row, checked);
    return;
  }

  if (isHeaderRow(sheet, row)) {
    if (col === COL_TOGGLE) { setBlockVisible_(sheet, row, checked); return; }
    if (name === SHEET_CHARS) {
      const lock = LOCK_PAIRS.find(p => p.check === col);
      if (lock) handleInstanceLock(sheet, row, lock, checked);
    }
    return;
  }

  // Data-row BiS / Alt / Other checkbox.
  const nameCol = { [COL_BIS_CHECK]: COL_BIS_NAME, [COL_ALT_CHECK]: COL_ALT_NAME, [COL_OTH_CHECK]: COL_OTH_NAME }[col];
  if (!nameCol) return;
  handleCheckbox(sheet, row, col, nameCol, checked);
  const header = findHeaderRow(sheet, row);
  if (header > 0) updateCounters(sheet, header);
}

// ===== Cell write helpers =====

// Set a checkbox and tint its paired name cell (green = on, grey = off).
function setCheckCell_(sheet, row, checkCol, nameCol, on) {
  sheet.getRange(row, checkCol).setValue(on);
  sheet.getRange(row, nameCol).setBackground(on ? COLOR_HAVE : COLOR_GREY);
}

// Set a lock checkbox and tint its label cell (red = locked, grey = free).
function setLockCell_(sheet, row, lock, locked) {
  sheet.getRange(row, lock.check).setValue(locked);
  sheet.getRange(row, lock.label).setBackground(locked ? COLOR_LOCKED : COLOR_GREY);
}

// Write the Other cell (AA): "" clears it; a numeric token becomes a Wowhead link (orange
// when it matches this row's BiS/Alt = pre-BiS); a non-numeric token is plain text.
function writeOtherCell_(sheet, row, token, nameMap) {
  const t = (token == null) ? "" : String(token);
  const cell = sheet.getRange(row, COL_OTH_NAME);
  cell.setBackground(t === "" ? COLOR_GREY : COLOR_HAVE);
  if (t === "") { cell.setValue(""); return; }
  if (/^\d+$/.test(t)) {
    const label = (nameMap && nameMap[t]) ? nameMap[t] : t;
    cell.setRichTextValue(otherRichText_(label, t, isPreBiSName_(sheet, row, label)));
  } else {
    cell.setValue(t);
  }
}

// ===== Checkbox logic — mutual exclusion of BiS / Alt / Other =====
function handleCheckbox(sheet, row, checkedCol, nameCol, isChecked) {
  sheet.getRange(row, nameCol).setBackground(isChecked ? COLOR_HAVE : COLOR_GREY);
  if (!isChecked) return;

  // Ring/Trinket rows allow BiS + Alt at once (both equipped); BiS/Alt then only clear
  // Other. Every other row clears the two siblings. Other always clears BiS + Alt.
  const slot   = (sheet.getRange(row, COL_SLOT).getValue() || "").toString().trim();
  const paired = (slot === "Ring" || slot === "Trinket");
  const all = [[COL_BIS_CHECK, COL_BIS_NAME], [COL_ALT_CHECK, COL_ALT_NAME], [COL_OTH_CHECK, COL_OTH_NAME]];
  const others = (paired && (checkedCol === COL_BIS_CHECK || checkedCol === COL_ALT_CHECK))
    ? [[COL_OTH_CHECK, COL_OTH_NAME]]
    : all.filter(p => p[0] !== checkedCol);

  others.forEach(p => { if (isCheckbox(sheet, row, p[0])) setCheckCell_(sheet, row, p[0], p[1], false); });
}

// ===== Counters — "X / Y BiS [- <n> GS]" in col G =====
function updateCounters(sheet, headerRow) {
  const dataEnd = findDataEnd(sheet, headerRow);
  let count = 0, total = 0, ringChecks = 0, trinketChecks = 0;

  for (let r = headerRow + 2; r <= dataEnd; r++) {
    const slot = (sheet.getRange(r, COL_SLOT).getValue() || "").toString().trim();
    if (!slot) continue; // spacer
    total++;
    const bis = sheet.getRange(r, COL_BIS_CHECK).getValue() === true;
    const alt = isCheckbox(sheet, r, COL_ALT_CHECK) && sheet.getRange(r, COL_ALT_CHECK).getValue() === true;
    // Ring/Trinket may have both boxes checked; cap each group at its 2 physical slots.
    if (slot === "Ring")         ringChecks    += (bis ? 1 : 0) + (alt ? 1 : 0);
    else if (slot === "Trinket") trinketChecks += (bis ? 1 : 0) + (alt ? 1 : 0);
    else if (bis || alt)         count++;
  }
  count += Math.min(ringChecks, 2) + Math.min(trinketChecks, 2);

  // Preserve any existing GS suffix so a manual toggle doesn't wipe the imported score.
  const m = sheet.getRange(headerRow, COL_BIS_NAME).getValue().toString().match(GS_SUFFIX);
  const suffix = m ? ` - ${m[1]} GS` : "";
  sheet.getRange(headerRow, COL_BIS_NAME).setValue(`${count} / ${total} BiS${suffix}`);
}

// Write/strip the imported GearScore as the " - <n> GS" suffix on the header (gs<=0 strips).
function setHeaderGearScore_(sheet, header, gs) {
  const base = sheet.getRange(header, COL_BIS_NAME).getValue().toString().replace(GS_SUFFIX, "").trim();
  sheet.getRange(header, COL_BIS_NAME).setValue((gs && gs > 0) ? `${base} - ${gs} GS` : base);
}

// ===== Instance locks — weekly Wednesday reset =====
function handleInstanceLock(sheet, row, lock, isLocked) {
  resetExpiredLocks_(sheet, row);
  sheet.getRange(row, lock.label).setBackground(isLocked ? COLOR_LOCKED : COLOR_GREY);
  sheet.getRange(row, COL_OTH_NAME).setValue(new Date());
}

// Most recent Wednesday 00:00 (local), the weekly lock-reset boundary.
function lastWeeklyReset_() {
  const now = new Date();
  const day = now.getDay();
  const back = day >= 3 ? day - 3 : day + 4;
  const wed = new Date(now);
  wed.setDate(now.getDate() - back);
  wed.setHours(0, 0, 0, 0);
  return wed;
}

// Clear a header's locks if its stamped date predates the last weekly reset.
function resetExpiredLocks_(sheet, headerRow) {
  const raw = sheet.getRange(headerRow, COL_OTH_NAME).getValue();
  let stored = null;
  if (raw instanceof Date) {
    stored = raw;
  } else if (typeof raw === "string" && raw.length > 0) {
    const parts = raw.split(" ")[0].split(".");
    if (parts.length === 3) stored = new Date(parts[2], parts[1] - 1, parts[0]);
  }
  const lastReset = lastWeeklyReset_();
  if (!stored || isNaN(stored) || stored >= lastReset) return;

  LOCK_PAIRS.forEach(p => setLockCell_(sheet, headerRow, p, false));
  const tz  = Session.getScriptTimeZone();
  const now = Utilities.formatDate(new Date(), tz, "dd.MM.yyyy");
  const wed = Utilities.formatDate(lastReset, tz, "dd.MM.");
  sheet.getRange(headerRow, COL_OTH_NAME).setValue(`${now} (ID Reset ${wed})`);
}

// ===== Addon string: read / parse / verify =====

// Read the pasted addon string from Addon!C4 ("" if empty/missing).
function readAddonString_() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_ADDON);
  if (!sheet) return "";
  const raw = sheet.getRange(PASTE_CELL).getValue();
  return (raw == null) ? "" : raw.toString().trim();
}

// Parse one entry "Name.Spec.Realm;<17 gear>;<gs>;<6 lock bits>".
// -> {ok, name, spec, realm, gear[17], gs, locks[6]} or {ok:false, error}.
function parseEntry_(s) {
  const fail = error => ({ ok: false, error });
  s = (s || "").trim();
  if (s === "") return fail("empty entry");

  const sections = s.split(";");
  const info = (sections[0] || "").split(".");
  if (info.length < 2) return fail(`bad "Name.Spec.Realm" segment: "${sections[0]}"`);
  const name  = info[0].trim();
  const spec  = info[1].trim();
  const realm = info.slice(2).join(".").trim();
  if (name === "" || spec === "") return fail(`empty name or spec: "${sections[0]}"`);

  const gear = (sections[1] || "").split("-");
  if (gear.length !== 17) return fail(`expected 17 gear slots, got ${gear.length} (${name})`);

  const gsRaw = (sections[2] || "").trim();
  if (!/^\d+$/.test(gsRaw)) return fail(`bad GearScore "${gsRaw}" (need a number) (${name})`);

  const locks = (sections[3] || "").trim();
  if (!/^[01]{6}$/.test(locks)) return fail(`bad lock bits "${locks}" (need 6× 0/1) (${name})`);

  return { ok: true, name, spec, realm, gear, gs: parseInt(gsRaw, 10), locks: locks.split("") };
}

// Parse the whole paste: strip the leading "<account>;" prefix, then validate every entry.
// ok only when there is >=1 entry and ALL are valid.
function parseAddonString_(raw) {
  const result = { ok: false, account: "", entries: [], errors: [] };
  raw = (raw || "").trim();
  if (raw === "") { result.errors.push("paste cell is empty"); return result; }

  const firstSep = raw.indexOf(";");
  if (firstSep < 0) { result.errors.push("missing account prefix"); return result; }

  // The addon encodes alias spaces as "^" so a space can't visually break the string.
  result.account = raw.slice(0, firstSep).trim().split("^").join(" ") || "NoAccName";

  raw.slice(firstSep + 1).split("|").forEach((piece, i) => {
    piece = piece.trim();
    if (piece === "") return; // tolerate stray separators
    const parsed = parseEntry_(piece);
    if (parsed.ok) result.entries.push(parsed);
    else result.errors.push(`entry ${i + 1}: ${parsed.error}`);
  });

  if (result.entries.length === 0 && result.errors.length === 0) result.errors.push("no entries found");
  result.ok = result.errors.length === 0 && result.entries.length > 0;
  return result;
}

// Keyed polynomial checksum (ASCII). MUST match the addon's ExportChecksum() exactly.
function checksum_(s) {
  const P = 2147483647;
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 257 + s.charCodeAt(i)) % P;
  return h;
}

// Split "<payload>~<checksum>" and verify against EXPORT_SECRET. -> {ok, payload} | {ok:false, error}.
function verifyChecksum_(raw) {
  raw = (raw || "").trim();
  const msg = "The exported string was edited, is corrupt or invalid. Try exporting again.";
  const sep = raw.lastIndexOf("~");
  if (sep < 0) return { ok: false, error: msg };
  const payload = raw.slice(0, sep);
  if (String(checksum_(EXPORT_SECRET + payload)) !== raw.slice(sep + 1).trim()) return { ok: false, error: msg };
  return { ok: true, payload };
}

// ===== Lookup helpers =====

// Export spec label -> sheet display name ("Marksman-Hunter" -> "Marksman Hunter").
function normalizeSpec_(s) {
  return (s || "").trim().replace(/-/g, " ").trim();
}

// Export gear token for a sheet slot name, or null (unknown / Ring / Trinket).
function resolveGear_(slotName, gearArr) {
  slotName = (slotName || "").toString().trim();
  if (slotName === "" || slotName === "Ring" || slotName === "Trinket") return null;
  const idx = SLOT_EXPORT_IDX[slotName];
  if (!idx || idx < 1 || idx > gearArr.length) return null;
  return gearArr[idx - 1];
}

// Spec a block represents, from its col-A in-cell icon alt-text (prefer description;
// ignore Google's generic "Bild"/"Image" title). "" if none.
function blockSpec_(sheet, headerRow) {
  const val = sheet.getRange(headerRow, 1).getValue();
  if (!val || typeof val.getAltTextDescription !== "function") return "";
  const desc = (val.getAltTextDescription() || "").trim();
  if (desc !== "") return desc;
  const title = (val.getAltTextTitle() || "").trim();
  const tl = title.toLowerCase();
  return (title !== "" && tl !== "bild" && tl !== "image") ? title : "";
}

// Existing character block for name+spec under this account (ungrouped blocks match any
// account). -> {header, dataEnd} | null.
function findCharBlock_(sheet, name, spec, account) {
  name = (name || "").toString().trim();
  const groups = scanGroups_(sheet);
  for (const g of groups) {
    if (g.headerRow > 0 && g.account !== account) continue;
    for (const c of g.chars) {
      if (c.name === name && c.spec === spec) return { header: c.header, dataEnd: c.dataEnd };
    }
  }
  return null;
}

// Classes BiS template block for a spec (icon alt-text or col-B label). -> {header, dataEnd} | null.
function findTemplateBlock_(bisSheet, spec) {
  const lastRow = bisSheet.getLastRow();
  for (let r = 1; r <= lastRow; r++) {
    if (!isHeaderRow(bisSheet, r)) continue;
    const label = bisSheet.getRange(r, COL_SLOT).getValue().toString().trim();
    if (blockSpec_(bisSheet, r) === spec || label === spec) return { header: r, dataEnd: findDataEnd(bisSheet, r) };
  }
  return null;
}

// ===== Wowhead item-name resolution (for "Other" items) =====

// Item name from a Wowhead JSON tooltip response ("" on failure).
function parseWowheadName_(text) {
  try {
    const obj = JSON.parse(text);
    return (obj && obj.name) ? String(obj.name).trim() : "";
  } catch (e) {
    return "";
  }
}

// Unique numeric item IDs across all entries (gear is item IDs; "0"/"1"/"2" skipped).
function collectOtherIds_(entries) {
  const seen = {}, ids = [];
  entries.forEach(e => e.gear.forEach(t => {
    if (/^\d+$/.test(t) && t !== "0" && t !== "1" && t !== "2" && !seen[t]) { seen[t] = true; ids.push(t); }
  }));
  return ids;
}

// Resolve item IDs to names: cache-first (Document Properties "wh_<id>"), then one
// batched fetchAll for the rest. -> {id: name}; unresolved ids are simply absent.
function resolveItemNames_(ids) {
  const map = {};
  if (!ids || ids.length === 0) return map;

  const props  = PropertiesService.getDocumentProperties();
  const cached  = props.getProperties();
  const toFetch = [];
  ids.forEach(id => {
    const hit = cached["wh_" + id];
    if (hit) map[id] = hit;
    else toFetch.push(id);
  });
  if (toFetch.length === 0) return map;

  let responses = [];
  try {
    responses = UrlFetchApp.fetchAll(toFetch.map(id => ({
      url: "https://nether.wowhead.com/wotlk/tooltip/item/" + id,
      muteHttpExceptions: true,
    })));
  } catch (e) {
    return map; // network failure -> leave unresolved
  }

  const toSave = {};
  responses.forEach((resp, i) => {
    if (resp && resp.getResponseCode() === 200) {
      const name = parseWowheadName_(resp.getContentText());
      if (name) { map[toFetch[i]] = name; toSave["wh_" + toFetch[i]] = name; }
    }
  });
  if (Object.keys(toSave).length > 0) { try { props.setProperties(toSave, false); } catch (e) {} }
  return map;
}

// ===== UwU Logs link (header col H) =====
function applyUwuLink_(sheet, header, charName, specDisplay, realm) {
  const id     = SPEC_UWU_ID[specDisplay] || 0;
  const server = (realm && realm.trim() !== "") ? realm.trim() : UWU_SERVER;
  const url    = "https://uwu-logs.xyz/character?name=" + encodeURIComponent(charName) +
                 "&server=" + encodeURIComponent(server) + "&spec=" + id;
  const rt = SpreadsheetApp.newRichTextValue()
    .setText("UwU Logs")
    .setLinkUrl(url)
    .setTextStyle(SpreadsheetApp.newTextStyle().setForegroundColor("#000000").build())
    .build();
  sheet.getRange(header, COL_LOGS).setRichTextValue(rt);
}

// ===== Rich-text / item-id helpers =====

// Wowhead item ID from a cell's hyperlink (whole-cell or text run). -> id string | null.
function extractItemId_(sheet, row, col) {
  const rtv = sheet.getRange(row, col).getRichTextValue();
  if (!rtv) return null;
  let url = rtv.getLinkUrl();
  if (!url) {
    for (const run of rtv.getRuns()) { const u = run.getLinkUrl(); if (u) { url = u; break; } }
  }
  if (!url) return null;
  const m = url.toString().match(/item=(\d+)/);
  return m ? m[1] : null;
}

// Displayed text of a cell (linked item name for a Wowhead-link cell).
function cellText_(sheet, row, col) {
  const rtv = sheet.getRange(row, col).getRichTextValue();
  return rtv ? rtv.getText() : sheet.getRange(row, col).getDisplayValue();
}

// True when an Other item's name equals this row's BiS or Alt name (same item, wrong ilvl).
function isPreBiSName_(sheet, row, name) {
  const norm = s => String(s == null ? "" : s).trim().toLowerCase();
  const target = norm(name);
  if (!target) return false;
  return target === norm(cellText_(sheet, row, COL_BIS_NAME)) || target === norm(cellText_(sheet, row, COL_ALT_NAME));
}

// Other cell rich text: item name linked to Wowhead, orange when pre-BiS.
function otherRichText_(label, id, preBiS) {
  const b = SpreadsheetApp.newRichTextValue().setText(label).setLinkUrl("https://www.wowhead.com/wotlk/item=" + id);
  if (preBiS) b.setTextStyle(SpreadsheetApp.newTextStyle().setForegroundColor(COLOR_PREBIS).build());
  return b.build();
}

// ===== Apply gear / locks to a block =====

// Set one data row to "none"|"bis"|"alt"|"oth" (mutually exclusive).
function applySlotChoice_(sheet, row, choice, otherText, nameMap) {
  [[COL_BIS_CHECK, COL_BIS_NAME, "bis"],
   [COL_ALT_CHECK, COL_ALT_NAME, "alt"],
   [COL_OTH_CHECK, COL_OTH_NAME, "oth"]].forEach(c => {
    if (isCheckbox(sheet, row, c[0])) setCheckCell_(sheet, row, c[0], c[1], c[2] === choice);
  });
  writeOtherCell_(sheet, row, choice === "oth" ? otherText : "", nameMap);
}

// Set a Ring/Trinket row: BiS and Alt are independent (both may be on); Other clears both.
function applyPairedRow_(sheet, row, bisOn, altOn, othId, nameMap) {
  const oth = (othId != null && othId !== "");
  if (oth) { bisOn = false; altOn = false; }
  if (isCheckbox(sheet, row, COL_BIS_CHECK)) setCheckCell_(sheet, row, COL_BIS_CHECK, COL_BIS_NAME, bisOn);
  if (isCheckbox(sheet, row, COL_ALT_CHECK)) setCheckCell_(sheet, row, COL_ALT_CHECK, COL_ALT_NAME, altOn);
  if (isCheckbox(sheet, row, COL_OTH_CHECK)) sheet.getRange(row, COL_OTH_CHECK).setValue(oth);
  writeOtherCell_(sheet, row, oth ? othId : "", nameMap);
}

// Ring/Trinket import — match equipped item IDs to rows' BiS/Alt link IDs (order-independent).
// A row may match both; leftover equipped IDs become Other; the rest are cleared.
function applyPairedSlots_(sheet, header, dataEnd, slotName, exportIdx, gearArr, nameMap) {
  const rows = [];
  for (let r = header + 2; r <= dataEnd; r++) {
    if ((sheet.getRange(r, COL_SLOT).getValue() || "").toString().trim() === slotName) rows.push(r);
  }
  if (rows.length === 0) return;

  const equipped = exportIdx.map(i => {
    const tok = (i >= 1 && i <= gearArr.length) ? String(gearArr[i - 1]) : "";
    return (/^\d+$/.test(tok) && tok !== "0") ? { id: tok, used: false } : null;
  });
  const info = rows.map(r => ({
    row: r, bis: false, alt: false, othId: null,
    bisId: extractItemId_(sheet, r, COL_BIS_NAME),
    altId: extractItemId_(sheet, r, COL_ALT_NAME),
  }));

  const take = targetId => {
    if (!targetId) return false;
    for (const eq of equipped) { if (eq && !eq.used && eq.id === targetId) { eq.used = true; return true; } }
    return false;
  };

  info.forEach(ri => { if (take(ri.bisId)) ri.bis = true; }); // pass 1: BiS by ID
  info.forEach(ri => { if (take(ri.altId)) ri.alt = true; }); // pass 2: Alt by ID

  let next = 0; // pass 3: leftover equipped IDs -> Other
  info.forEach(ri => {
    if (ri.bis || ri.alt) return;
    while (next < equipped.length && (!equipped[next] || equipped[next].used)) next++;
    if (next < equipped.length) { ri.othId = equipped[next].id; equipped[next].used = true; next++; }
  });

  info.forEach(ri => applyPairedRow_(sheet, ri.row, ri.bis, ri.alt, ri.othId, nameMap));
}

// Write all gear for a block, refresh its counter, and stamp the imported GearScore.
// Each token is the equipped item ID ("0" = empty); BiS/Alt/Other decided by ID match.
function applyGear_(sheet, header, gearArr, nameMap, gs) {
  const dataEnd = findDataEnd(sheet, header);
  for (let r = header + 2; r <= dataEnd; r++) {
    const slotName = sheet.getRange(r, COL_SLOT).getValue();
    if (!slotName) continue;
    const token = resolveGear_(slotName, gearArr);
    if (token === null) continue; // unknown / Ring / Trinket (handled below)
    const t = String(token);
    if (t === "0") { applySlotChoice_(sheet, r, "none", null, nameMap); continue; }
    const bisId = extractItemId_(sheet, r, COL_BIS_NAME);
    const altId = extractItemId_(sheet, r, COL_ALT_NAME);
    if (bisId && t === bisId)      applySlotChoice_(sheet, r, "bis", null, nameMap);
    else if (altId && t === altId) applySlotChoice_(sheet, r, "alt", null, nameMap);
    else                           applySlotChoice_(sheet, r, "oth", t,   nameMap);
  }
  applyPairedSlots_(sheet, header, dataEnd, "Ring",    RING_IDX,    gearArr, nameMap);
  applyPairedSlots_(sheet, header, dataEnd, "Trinket", TRINKET_IDX, gearArr, nameMap);
  updateCounters(sheet, header);
  setHeaderGearScore_(sheet, header, gs);
}

// Write the 6 instance-lock bits (order = LOCK_PAIRS) onto a header.
function applyLocks_(sheet, header, locksArr) {
  LOCK_PAIRS.forEach((p, i) => setLockCell_(sheet, header, p, locksArr[i] === "1"));
}

// Stamp the header's "Updated" date (col AA) — the marker read by resetExpiredLocks_.
function stampUpdatedDate_(sheet, header) {
  sheet.getRange(header, COL_OTH_NAME).setValue(new Date());
}

// ===== Account-group structure (My Characters) =====

// Last non-empty data row of a block (trims trailing spacers).
function trimmedEnd_(sheet, header, dataEnd) {
  let end = dataEnd;
  while (end > header && sheet.getRange(end, COL_SLOT).getValue().toString().trim() === "") end--;
  return end;
}

// Collapse/expand a whole account group; on expand, individually-collapsed chars stay so.
function setGroupVisible_(sheet, groupHeaderRow, expand) {
  const lastRow = sheet.getLastRow();
  let end = lastRow;
  for (let r = groupHeaderRow + 1; r <= lastRow; r++) {
    if (isGroupHeader_(sheet, r)) { end = r - 1; break; }
  }
  const start = groupHeaderRow + 1;
  if (end < start) return;
  if (!expand) { sheet.hideRows(start, end - start + 1); return; }
  sheet.showRows(start, end - start + 1);
  for (let r = start; r <= end; r++) {
    if (isHeaderRow(sheet, r) && sheet.getRange(r, COL_TOGGLE).getValue() !== true) setBlockVisible_(sheet, r, false);
  }
}

// Scan "My Characters" into ordered account groups. Blocks before any group header go
// into a synthetic leading group (headerRow=-1). Returns
// [{headerRow, account, realm, label, endRow, chars:[{header, dataEnd, name, spec}]}].
function scanGroups_(sheet) {
  const lastRow = sheet.getLastRow();
  const groups = [];
  let cur = null;
  for (let r = 2; r <= lastRow; r++) {
    if (isHeaderRow(sheet, r)) {
      if (!cur) { cur = { headerRow: -1, account: "", realm: "", label: "", chars: [] }; groups.push(cur); }
      cur.chars.push({
        header: r, dataEnd: findDataEnd(sheet, r),
        name: sheet.getRange(r, COL_SLOT).getValue().toString().trim(),
        spec: blockSpec_(sheet, r),
      });
    } else if (isGroupHeader_(sheet, r)) {
      const pg = parseGroupLabel_(sheet.getRange(r, COL_GROUP_LABEL).getValue().toString().trim());
      cur = { headerRow: r, account: pg.account, realm: pg.realm, label: groupLabel_(pg.account, pg.realm), chars: [] };
      groups.push(cur);
    }
  }
  for (let i = 0; i < groups.length; i++) {
    groups[i].endRow = (i + 1 < groups.length) ? groups[i + 1].headerRow - 1 : lastRow;
  }
  return groups;
}

// This account's chars (realm+name+spec) absent from the export — i.e. what Update All
// will DELETE. -> [{realm, name, spec}] in sheet order.
function findDeletions_(charsSheet, account, entries) {
  const desired = {};
  entries.forEach(e => {
    const realm = (e.realm && e.realm.trim() !== "") ? e.realm.trim() : UWU_SERVER;
    desired[realm + "||" + e.name.trim() + "||" + normalizeSpec_(e.spec)] = true;
  });
  const out = [];
  scanGroups_(charsSheet).forEach(g => {
    if (g.headerRow <= 0 || g.account !== account) return;
    g.chars.forEach(c => {
      if (!desired[g.realm + "||" + c.name + "||" + c.spec]) out.push({ realm: g.realm, name: c.name, spec: c.spec });
    });
  });
  return out;
}

// Rebuild one account's region of "My Characters" to match the export: groups in first-
// appearance realm order, characters in export order. Missing groups/characters are copied
// from the Classes BiS templates; this account's chars absent from the export are dropped
// (and any emptied group with them); other accounts are untouched. copyTo carries
// values/format/checkboxes/icons/merges; visibility + gear/locks/links are applied after.
// -> {updated, created, deleted, removed:[], problems}.
function rebuildAccount_(charsSheet, bisSheet, account, entries, nameMap, opts) {
  const result = { updated: 0, created: 0, deleted: 0, removed: [], problems: [] };
  const numCols = COL_TOGGLE; // every block spans A:AB
  if (numCols > charsSheet.getMaxColumns()) {
    charsSheet.insertColumnsAfter(charsSheet.getMaxColumns(), numCols - charsSheet.getMaxColumns());
  }

  // 1) Desired groups (realm = group; first-appearance order).
  const desiredOrder = [];
  const desiredByLabel = {};
  entries.forEach(e => {
    const realm = (e.realm && e.realm.trim() !== "") ? e.realm.trim() : UWU_SERVER;
    const label = groupLabel_(account, realm);
    if (!desiredByLabel[label]) { desiredByLabel[label] = { label, realm, entries: [] }; desiredOrder.push(desiredByLabel[label]); }
    desiredByLabel[label].entries.push(e);
  });

  // 2) Current state for this account (assumed contiguous).
  const groups    = scanGroups_(charsSheet);
  const accGroups = groups.filter(g => g.headerRow > 0 && g.account === account);
  const exists    = accGroups.length > 0;

  const existingChars = {}; // "realm||name||spec" -> {header, dataEnd, realm, name, spec, used}
  accGroups.forEach(g => g.chars.forEach(c => {
    const key = g.realm + "||" + c.name + "||" + c.spec;
    if (!existingChars[key]) existingChars[key] = { header: c.header, dataEnd: c.dataEnd, realm: g.realm, name: c.name, spec: c.spec, used: false };
  }));
  const existingGroupByLabel = {};
  accGroups.forEach(g => { if (!existingGroupByLabel[g.label]) existingGroupByLabel[g.label] = g; });

  // Block row count including its one trailing spacer (the styled divider).
  const blkRows = (sheet, header, dataEnd) => {
    const ce = trimmedEnd_(sheet, header, dataEnd);
    return (ce < dataEnd ? ce + 1 : ce) - header + 1;
  };

  // Resolve a character to a copy source: reuse an existing block (preserves manual edits),
  // else a Classes BiS template. null when neither exists.
  const charSource = (name, spec, entry, realm) => {
    const ex = existingChars[realm + "||" + name + "||" + spec];
    if (ex && !ex.used) {
      ex.used = true;
      return { kind: "existing", header: ex.header, rows: blkRows(charsSheet, ex.header, ex.dataEnd), name, spec, entry: entry || null };
    }
    if (entry) {
      const tmpl = findTemplateBlock_(bisSheet, spec);
      if (!tmpl) return null;
      return { kind: "new", tmplHeader: tmpl.header, rows: blkRows(bisSheet, tmpl.header, tmpl.dataEnd), name, spec, entry };
    }
    return null;
  };

  // 3) Ordered plan of groups -> character sources.
  const plan = [];
  desiredOrder.forEach(dg => {
    const exG = existingGroupByLabel[dg.label];
    const chars = [];
    dg.entries.forEach(e => {
      const spec = normalizeSpec_(e.spec);
      const cs = charSource(e.name, spec, e, dg.realm);
      if (!cs) { result.problems.push(`${e.name} (${spec}): no matching block on "${SHEET_BIS}"`); return; }
      chars.push(cs);
    });
    plan.push({ label: dg.label, headerExisting: exG ? exG.headerRow : -1, chars });
  });

  // 4) Mark this account's chars absent from the export as consumed (left out of the plan,
  //    so step 8's region delete drops them). Record them for the summary.
  accGroups.forEach(g => g.chars.forEach(c => {
    const key = g.realm + "||" + c.name + "||" + c.spec;
    if (!existingChars[key] || existingChars[key].used) return;
    existingChars[key].used = true;
    result.deleted++;
    result.removed.push(`${c.name} (${c.spec || "?"})` + (g.realm ? ` [${g.realm}]` : ""));
  }));

  // 5) New region row count (each char block carries its own spacer; +1 per group header).
  let newRows = 0;
  plan.forEach(p => { newRows += 1; p.chars.forEach(c => { newRows += c.rows; }); });
  if (newRows <= 0) return result;

  // 6) Reserve the region. Existing account -> insert a hole before its region (sources
  //    shift down by newRows, old region deleted after). New account -> append below all.
  let regionStart, oldRows, offset;
  if (exists) {
    regionStart = accGroups[0].headerRow;
    const lastG = accGroups[accGroups.length - 1];
    // Bottom-most account: getLastRow ignores the value-less black trailing spacer, so
    // extend by one to include it (else the delete orphans that divider).
    let oldEnd = lastG.endRow;
    if (lastG.endRow >= charsSheet.getLastRow()) oldEnd = Math.min(charsSheet.getLastRow() + 1, charsSheet.getMaxRows());
    oldRows = oldEnd - regionStart + 1;
    charsSheet.insertRowsBefore(regionStart, newRows);
    offset = newRows;
  } else {
    const lastRow = charsSheet.getLastRow();
    // First account -> directly under the protected title; otherwise keep one divider row.
    regionStart = (groups.length > 0) ? (lastRow + 2) : (lastRow + 1);
    oldRows = 0; offset = 0;
    const need = regionStart + newRows - 1;
    if (need > charsSheet.getMaxRows()) charsSheet.insertRowsAfter(charsSheet.getMaxRows(), need - charsSheet.getMaxRows());
  }
  charsSheet.getRange(regionStart, 1, newRows, numCols).clearFormat();

  // 7) Fill top-down (copy + label/name + toggle). Record where each char lands.
  let cursor = regionStart;
  plan.forEach(p => {
    if (p.headerExisting > 0) {
      charsSheet.getRange(p.headerExisting + offset, 1, 1, numCols).copyTo(charsSheet.getRange(cursor, 1, 1, numCols));
    } else {
      bisSheet.getRange(GROUP_TEMPLATE_ROW, 1, 1, numCols).copyTo(charsSheet.getRange(cursor, 1, 1, numCols));
    }
    const seenNames = {};
    p.chars.forEach(c => { seenNames[c.name] = true; });
    charsSheet.getRange(cursor, COL_GROUP_LABEL).setValue(groupLabelWithCount_(p.label, Object.keys(seenNames).length));
    charsSheet.getRange(cursor, COL_GROUP_TOGGLE).setValue(true); // new header starts expanded
    cursor += 1;
    p.chars.forEach(c => {
      if (c.kind === "existing") {
        charsSheet.getRange(c.header + offset, 1, c.rows, numCols).copyTo(charsSheet.getRange(cursor, 1, c.rows, numCols));
      } else {
        bisSheet.getRange(c.tmplHeader, 1, c.rows, numCols).copyTo(charsSheet.getRange(cursor, 1, c.rows, numCols));
        charsSheet.getRange(cursor, COL_TOGGLE).setValue(true);
      }
      charsSheet.getRange(cursor, COL_SLOT).setValue(c.name);
      c.placed = cursor;
      cursor += c.rows;
    });
  });

  // 8) Drop the old (now shifted) region.
  if (exists && oldRows > 0) charsSheet.deleteRows(regionStart + newRows, oldRows);

  // 9) Apply visibility + per-character export data.
  for (let r = regionStart; r < regionStart + newRows; r++) {
    if (isHeaderRow(charsSheet, r)) setBlockVisible_(charsSheet, r, charsSheet.getRange(r, COL_TOGGLE).getValue() === true);
  }
  plan.forEach(p => p.chars.forEach(c => {
    if (!c.entry) return;
    if (opts.gear)  applyGear_(charsSheet, c.placed, c.entry.gear, nameMap, c.entry.gs);
    if (opts.locks) applyLocks_(charsSheet, c.placed, c.entry.locks);
    applyUwuLink_(charsSheet, c.placed, c.name, c.spec, c.entry.realm);
    stampUpdatedDate_(charsSheet, c.placed);
    if (c.kind === "existing") result.updated++; else result.created++;
  }));

  return result;
}

// ===== Import buttons =====

// Run `body(ui)` holding the script lock, with standard busy/error alerts.
function withScriptLock_(label, body) {
  const ui = SpreadsheetApp.getUi();
  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(30000);
  } catch (e) {
    ui.alert(label, "Another action is already running. Try again shortly.", ui.ButtonSet.OK);
    return;
  }
  try {
    body(ui);
  } catch (err) {
    ui.alert(label + " — error", String(err && err.stack ? err.stack : err), ui.ButtonSet.OK);
  } finally {
    lock.releaseLock();
  }
}

// YES/NO confirmation listing the characters Update All will delete. -> true if confirmed.
function confirmDeletions_(ui, label, account, toDelete) {
  const n = toDelete.length;
  const list = toDelete.slice(0, 15)
    .map(d => "• " + d.name + " (" + (d.spec || "?") + ")" + (d.realm ? " [" + d.realm + "]" : "")).join("\n");
  const more = n > 15 ? "\n…and " + (n - 15) + " more" : "";
  const resp = ui.alert(label + " — confirm deletions",
    n + " character" + (n === 1 ? "" : "s") + ' under "' + account + '" are not in this export and will be DELETED:\n\n'
    + list + more + "\n\nProceed?", ui.ButtonSet.YES_NO);
  return resp === ui.Button.YES;
}

// Shared core for the three import buttons. Validates the paste FIRST (checksum + format)
// and aborts with an alert before any writes. opts = {label, logType, gear, locks, reorder}.
// reorder = full group-aware rebuild (Update All); else update existing blocks in place.
function runUpdate_(opts) {
  withScriptLock_(opts.label, ui => {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const charsSheet = ss.getSheetByName(SHEET_CHARS);
    const bisSheet   = ss.getSheetByName(SHEET_BIS);
    if (!charsSheet || !bisSheet) {
      ui.alert(opts.label, `Missing a required sheet ("${SHEET_CHARS}" or "${SHEET_BIS}").`, ui.ButtonSet.OK);
      return;
    }

    const raw   = readAddonString_();
    const check = verifyChecksum_(raw);
    if (!check.ok) { ui.alert(opts.label + " — invalid addon string", "Nothing was changed.\n\n" + check.error, ui.ButtonSet.OK); return; }
    const parsed = parseAddonString_(check.payload);
    if (!parsed.ok) {
      ui.alert(opts.label + " — invalid addon string", "Nothing was changed.\n\n" + parsed.errors.slice(0, 10).join("\n"), ui.ButtonSet.OK);
      return;
    }
    const account = parsed.account;

    // Update All deletes this account's chars missing from the export — confirm first.
    if (opts.reorder) {
      const toDelete = findDeletions_(charsSheet, account, parsed.entries);
      if (toDelete.length > 0 && !confirmDeletions_(ui, opts.label, account, toDelete)) {
        ui.alert(opts.label, "Cancelled. Nothing was changed.", ui.ButtonSet.OK);
        return;
      }
    }

    snapshotForUndo_(ss);
    const nameMap = opts.gear ? resolveItemNames_(collectOtherIds_(parsed.entries)) : {};

    let updated = 0, created = 0, deleted = 0, skipped = 0;
    const problems = [];

    if (opts.reorder) {
      const r = rebuildAccount_(charsSheet, bisSheet, account, parsed.entries, nameMap, opts);
      updated = r.updated; created = r.created; deleted = r.deleted;
      r.problems.forEach(p => problems.push(p));
    } else {
      parsed.entries.forEach(entry => {
        const spec  = normalizeSpec_(entry.spec);
        const block = findCharBlock_(charsSheet, entry.name, spec, account);
        if (!block) { problems.push(`${entry.name} (${spec}): no block yet — run "Update All" first`); skipped++; return; }
        if (opts.gear)  applyGear_(charsSheet, block.header, entry.gear, nameMap, entry.gs);
        if (opts.locks) applyLocks_(charsSheet, block.header, entry.locks);
        applyUwuLink_(charsSheet, block.header, entry.name, spec, entry.realm);
        stampUpdatedDate_(charsSheet, block.header);
        updated++;
      });
    }

    if (updated + created + deleted > 0) {
      recordUpdate_(ss, opts.logType, raw);
      ss.getSheetByName(SHEET_ADDON).getRange(PASTE_CELL).clearContent();
    }

    const summary = `Updated ${updated}, created ${created}`
      + (deleted ? `, deleted ${deleted}` : "") + (skipped ? `, skipped ${skipped}` : "");
    if (problems.length) ui.alert(opts.label + " — done with warnings", summary + "\n\n" + problems.slice(0, 10).join("\n"), ui.ButtonSet.OK);
    else ss.toast(summary, opts.label, 5);
  });
}

// Button entry points (assigned to drawings / menu items — keep these names).
function updateAll()           { runUpdate_({ label: "Update All",            logType: "Everything",     gear: true,  locks: true,  reorder: true  }); }
function updateEquipment()     { runUpdate_({ label: "Update Equipment",      logType: "Characters",     gear: true,  locks: false, reorder: false }); }
function updateInstanceLocks() { runUpdate_({ label: "Update Instance Locks", logType: "Instance Locks", gear: false, locks: true,  reorder: false }); }

// ===== Update log + undo =====

// Server-time stamp, e.g. "26.06.26 21:38 ST (GMT)".
function formatUpdateStamp_(ss) {
  const tz = UPDATE_TZ || ss.getSpreadsheetTimeZone() || Session.getScriptTimeZone();
  return Utilities.formatDate(new Date(), tz, UPDATE_24H ? "dd.MM.yy HH:mm" : "dd.MM.yy hh:mm a") + " ST (GMT)";
}

// Style the applied-string box: top-left, size 12, black.
function styleStringBox_(sheet) {
  sheet.getRange(LAST_STRING_RANGE)
    .setFontSize(12).setFontColor("#000000").setFontWeight("normal").setFontStyle("normal")
    .setHorizontalAlignment("left").setVerticalAlignment("top");
}

// Fill the applied-string box with the "Nothing to Undo.." placeholder (centered, grey).
function showUndoPlaceholder_(sheet) {
  sheet.getRange(LAST_STRING_CELL).setValue(UNDO_PLACEHOLDER);
  sheet.getRange(LAST_STRING_RANGE)
    .setFontSize(32).setFontColor(COLOR_GREY).setFontWeight("normal").setFontStyle("normal")
    .setHorizontalAlignment("center").setVerticalAlignment("middle");
}

// Record one update: set the applied-string box + push [type, time] onto the log (newest first).
function recordUpdate_(ss, logType, raw) {
  const sheet = ss.getSheetByName(SHEET_ADDON);
  if (!sheet) return;
  if (raw) {
    sheet.getRange(LAST_STRING_CELL).setValue(raw);
    styleStringBox_(sheet);
  }
  const range = sheet.getRange(LOG_ROW, LOG_COL_TYPE, LOG_LEN, 2);
  range.setValues([[logType, formatUpdateStamp_(ss)]].concat(range.getValues()).slice(0, LOG_LEN));
}

// Full-sheet snapshot of "My Characters" for one-level undo (replaces any prior backup).
function snapshotForUndo_(ss) {
  const src = ss.getSheetByName(SHEET_CHARS);
  if (!src) return;
  const old = ss.getSheetByName(BACKUP_SHEET);
  if (old) ss.deleteSheet(old);
  const backup = src.copyTo(ss);
  backup.setName(BACKUP_SHEET);
  backup.hideSheet();
}

// Revert "My Characters" from the snapshot, pop the top log entry. No snapshot -> no-op.
function undoLastChanges() {
  withScriptLock_("Undo Last Changes", ui => {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const backup = ss.getSheetByName(BACKUP_SHEET);
    if (!backup) { ui.alert("Undo Last Changes", "Nothing to undo.", ui.ButtonSet.OK); return; }

    const cur = ss.getSheetByName(SHEET_CHARS);
    const pos = cur ? cur.getIndex() : 1;
    if (cur) ss.deleteSheet(cur);
    const restored = backup.copyTo(ss);
    restored.setName(SHEET_CHARS);
    restored.showSheet();
    ss.setActiveSheet(restored);
    ss.moveActiveSheet(pos);
    ss.deleteSheet(backup);

    const addon = ss.getSheetByName(SHEET_ADDON);
    if (addon) {
      const range = addon.getRange(LOG_ROW, LOG_COL_TYPE, LOG_LEN, 2);
      range.setValues(range.getValues().slice(1).concat([["", ""]]));
      showUndoPlaceholder_(addon);
    }
    ss.toast("Reverted the last update.", "Undo Last Changes", 5);
  });
}
