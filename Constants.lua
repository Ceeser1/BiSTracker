-- BiSTracker: Static data and shared constants

-- ============================================================
-- RUNTIME CONSTANTS
-- ============================================================

INSTANCES = {
    { key="ICC25", label="ICC 25", name="Icecrown Citadel",     difficulty=2, size=25 },
    { key="ICC10", label="ICC 10", name="Icecrown Citadel",     difficulty=1, size=10 },
    { key="RS25",  label="RS 25",  name="The Ruby Sanctum",     difficulty=2, size=25 },
    { key="RS10",  label="RS 10",  name="The Ruby Sanctum",     difficulty=1, size=10 },
    { key="TOC25", label="TOC 25", name="Trial of the Crusader",difficulty=2, size=25 },
    { key="TOC10", label="TOC 10", name="Trial of the Crusader",difficulty=1, size=10 },
}

GEAR_SLOTS = {
    { id=1,  name="Head"      }, { id=2,  name="Neck"      }, { id=3,  name="Shoulders" },
    { id=5,  name="Chest"     }, { id=6,  name="Waist"     }, { id=7,  name="Legs"      },
    { id=8,  name="Feet"      }, { id=9,  name="Wrist"     }, { id=10, name="Hands"     },
    { id=11, name="Ring 1"    }, { id=12, name="Ring 2"    },
    { id=13, name="Trinket 1" }, { id=14, name="Trinket 2" },
    { id=15, name="Back"      }, { id=16, name="Main Hand" }, { id=17, name="Off Hand"  },
    { id=18, name="Ranged"    },
}

RANGED_SLOTS = { Crossbow=true, Sigil=true, Idol=true, Totem=true, Libram=true, Wand=true, Ranged=true }
COL1_SLOTS   = { Head=true, Neck=true, Shoulders=true, Back=true, Chest=true, Wrist=true }
WEAPON_SLOTS = {
    ["Main Hand"]=true, ["Off Hand"]=true, Shield=true,
    Crossbow=true, Sigil=true, Idol=true, Totem=true, Libram=true, Wand=true, Ranged=true
}

-- GearScore (Mirrikat45 / LibGearScore-1.0 port). Slot weight per equip location.
GS_SCALE    = 1.8618
GS_SLOT_MOD = {
    INVTYPE_RELIC=0.3164,          INVTYPE_TRINKET=0.5625,        INVTYPE_2HWEAPON=2.0,
    INVTYPE_WEAPONMAINHAND=1.0,    INVTYPE_WEAPONOFFHAND=1.0,     INVTYPE_RANGED=0.3164,
    INVTYPE_THROWN=0.3164,         INVTYPE_RANGEDRIGHT=0.3164,    INVTYPE_SHIELD=1.0,
    INVTYPE_WEAPON=1.0,            INVTYPE_HOLDABLE=1.0,          INVTYPE_HEAD=1.0,
    INVTYPE_NECK=0.5625,           INVTYPE_SHOULDER=0.75,         INVTYPE_CHEST=1.0,
    INVTYPE_ROBE=1.0,              INVTYPE_WAIST=0.75,            INVTYPE_LEGS=1.0,
    INVTYPE_FEET=0.75,             INVTYPE_WRIST=0.5625,          INVTYPE_HAND=0.75,
    INVTYPE_FINGER=0.5625,         INVTYPE_CLOAK=0.5625,          INVTYPE_BODY=0,
}
-- Per-rarity linear coefficients, split on item level 120.
GS_FORMULA = {
    A = { [4]={A=91.45, B=0.65},  [3]={A=81.375, B=0.8125}, [2]={A=73.0, B=1.0} },                       -- ilvl > 120
    B = { [4]={A=26.0,  B=1.2},   [3]={A=0.75,   B=1.8},    [2]={A=8.0,  B=2.0}, [1]={A=0.0, B=2.25} },  -- ilvl <= 120
}
-- Color gradient anchors for GetGearScoreColor() (RGB 0-255, interpolated linearly).
GS_COLOR_STOPS = {
    { gs=0,    r=154, g=154, b=154 },  -- Grey
    { gs=1000, r=255, g=255, b=255 },  -- White
    { gs=2000, r=30,  g=255, b=0   },  -- Green
    { gs=3000, r=0,   g=112, b=221 },  -- Blue
    { gs=4000, r=163, g=53,  b=238 },  -- Purple
    { gs=5000, r=255, g=128, b=0   },  -- Orange
    { gs=6000, r=255, g=100, b=100 },  -- Light Red
    { gs=6250, r=180, g=0,   b=0   },  -- Dark Red
}

DETAIL_LINE_H    = 14
DETAIL_COL_X     = { 5, 325 }
DETAIL_MAX_LINES = { 22, 24 }
ROW_H            = 22

CLASS_TREES = {
    DEATHKNIGHT = { "Blood DK Tank",       "Frost DK",           "Unholy DK",          "Blood DK Dps"        },
    WARRIOR      = { "Arms Warrior",        "Fury Warrior",       "Protection Warrior"  },
    PALADIN      = { "Holy Paladin",        "Protection Paladin", "Retribution Paladin" },
    ROGUE        = { "Assassination Rogue", "Combat Rogue",       "Subtlety Rogue"      },
    DRUID        = { "Balance Druid",       "Feral Combat Druid", "Restoration Druid"   },
    HUNTER       = { "Beast Mastery Hunter","Marksman Hunter",    "Survival Hunter"     },
    MAGE         = { "Arcane Mage",         "Fire Mage",          "Frost Mage"          },
    WARLOCK      = { "Affliction Warlock",  "Demonology Warlock", "Destruction Warlock" },
    PRIEST       = { "Discipline Priest",   "Holy Priest",        "Shadow Priest"       },
    SHAMAN       = { "Elemental Shaman",    "Enhancement Shaman", "Restoration Shaman", "Spellhance Shaman"   },
}

SPEC_COLORS = {
    ["Blood DK Tank"]="c41e3a", ["Unholy DK"]="c41e3a",       ["Frost DK"]="c41e3a",  ["Blood DK Dps"]="c41e3a",
    ["Fury Warrior"]="c69b6d",  ["Arms Warrior"]="c69b6d",    ["Protection Warrior"]="c69b6d",
    ["Holy Paladin"]="f48cba",  ["Protection Paladin"]="f48cba", ["Retribution Paladin"]="f48cba",
    ["Assassination Rogue"]="fff468", ["Combat Rogue"]="fff468", ["Subtlety Rogue"]="fff468",
    ["Balance Druid"]="ff7c0a", ["Feral Combat Druid"]="ff7c0a", ["Bear Druid"]="ff7c0a",
    ["Restoration Druid"]="ff7c0a",   ["Beast Mastery Hunter"]="abd473",
    ["Marksman Hunter"]="abd473", ["Survival Hunter"]="abd473",
    ["Arcane Mage"]="3fc7eb",   ["Fire Mage"]="3fc7eb",       ["Frost Mage"]="3fc7eb",
    ["Affliction Warlock"]="8788ee", ["Demonology Warlock"]="8788ee", ["Destruction Warlock"]="8788ee",
    ["Discipline Priest"]="f0ebe0", ["Holy Priest"]="f0ebe0", ["Shadow Priest"]="f0ebe0",
    ["Elemental Shaman"]="0070dd", ["Enhancement Shaman"]="0070dd",
    ["Restoration Shaman"]="0070dd", ["Spellhance Shaman"]="0070dd",
}

-- Export checksum secret. Must match EXPORT_SECRET in the sheet's Apps Script EXACTLY.
EXPORT_SECRET = "BiSTrk!2026#warmane"

CLASS_ORDER = {
    "DEATHKNIGHT","WARRIOR","PALADIN","ROGUE","DRUID",
    "HUNTER","MAGE","WARLOCK","PRIEST","SHAMAN"
}

CLASS_LABELS = {
    DEATHKNIGHT="Death Knight", WARRIOR="Warrior",   PALADIN="Paladin",
    ROGUE="Rogue",              DRUID="Druid",        HUNTER="Hunter",
    MAGE="Mage",                WARLOCK="Warlock",    PRIEST="Priest",
    SHAMAN="Shaman",
}

COLOR = {
    -- Rarity
    uncommon  = "|cff1eff00",
    rare      = "|cff0070dd",
    epic      = "|cffa335ee",
    legendary = "|cffff8000",
    -- UI
    green     = "|cff44ff44",
    red       = "|cffff4444",
    blue      = "|cff00ccff",
    white     = "|cffffffff",
    lgrey     = "|cffc4c4c4",
    grey      = "|cff999999",
    dgrey     = "|cff333333",
    lorange   = "|cffffa759",
}
