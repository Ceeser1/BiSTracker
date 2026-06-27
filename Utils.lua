-- BiSTracker: Utility functions (no GUI, no local-only state from BiSTracker.lua)

function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[BiSTracker]|r " .. tostring(msg))
end

function GetCharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

function Trim(s)
    return s and s:match("^%s*(.-)%s*$") or ""
end

function GetActiveGear(char)
    if not char or not char.specs or not char.activeSpec then return {} end
    local s = char.specs[char.activeSpec]
    return (s and s.gear) or {}
end

function GetActiveColor(char)
    if not char or not char.specs or not char.activeSpec then return "aaaaaa" end
    local s = char.specs[char.activeSpec]
    return (s and s.color) or "aaaaaa"
end

-- 6-char hex string (no #) for a class's RAID_CLASS_COLORS entry; "aaaaaa" if unknown.
function ClassColorHex(class)
    local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not cc then return "aaaaaa" end
    return string.format("%02x%02x%02x", math.floor(cc.r * 255), math.floor(cc.g * 255), math.floor(cc.b * 255))
end

function CountSpecs(char)
    local n = 0
    if char and char.specs then
        for _ in pairs(char.specs) do n = n + 1 end
    end
    return n
end

-- Rank of the talent at a given grid position (tier=row, column), 1-indexed
-- from the top-left. talentIndex is a flat list, so we match on tier/column
-- (locale-independent, unlike the talent name). inspect=true reads the unit
-- currently under NotifyInspect. Returns 0 if not found / no points.
function GetTalentRankAt(tab, tier, column, inspect)
    for i = 1, GetNumTalents(tab, inspect) do
        local _, _, t, c, rank = GetTalentInfo(tab, i, inspect)
        if t == tier and c == column then return rank or 0 end
    end
    return 0
end

-- DK Blood tree (tab 1) doesn't say Tank vs DPS by points alone: a DPS build
-- takes Dancing Rune Weapon (tier 11, col 2, the 51-pointer); a tank skips it.
function ResolveBloodDK(inspect)
    if GetTalentRankAt(1, 11, 2, inspect) > 0 then return "Blood DK Dps" end
    return "Blood DK Tank"
end

-- Shaman Enhancement tree (tab 2): a real Enhancement build takes Feral Spirit
-- (tier 11, col 2, the 51-pointer); a Spellhance build skips it. Skilled => Enhancement.
function ResolveEnhanceShaman(inspect)
    if GetTalentRankAt(2, 11, 2, inspect) > 0 then return "Enhancement Shaman" end
    return "Spellhance Shaman"
end

function DetectSpec()
    local _, class = UnitClass("player")
    if not class then return "Unknown" end
    local trees = CLASS_TREES[class]
    if not trees then return class end
    local maxPts, maxTree = -1, 1
    for i = 1, GetNumTalentTabs() do
        local _, _, pts = GetTalentTabInfo(i)
        if pts and pts > maxPts then maxPts = pts; maxTree = i end
    end
    if class == "DEATHKNIGHT" and maxTree == 1 then return ResolveBloodDK(false) end
    if class == "SHAMAN"      and maxTree == 2 then return ResolveEnhanceShaman(false) end
    return trees[maxTree] or class
end

function ScanInstanceLocks()
    local key  = GetCharKey()
    local char = BiSTrackerDB.characters[key]
    if not char then
        if debugMode then Print("[Locks] No registered character found, skipping.") end
        return
    end
    local locks = {}
    for _, inst in ipairs(INSTANCES) do locks[inst.key] = false end
    local total = GetNumSavedInstances()
    if debugMode then Print("[Locks] Scanning " .. total .. " saved instance(s)...") end
    for i = 1, total do
        local iName, _, _, difficulty, locked, _, _, isRaid, maxPlayers = GetSavedInstanceInfo(i)
        if locked and isRaid and iName then
            local matched = false
            for _, inst in ipairs(INSTANCES) do
                if iName:find(inst.name, 1, true) and maxPlayers == inst.size and difficulty == inst.difficulty then
                    locks[inst.key] = true
                    matched = true
                    if debugMode then Print("[Locks] Locked: " .. inst.key .. " (" .. iName .. " " .. maxPlayers .. "-man diff=" .. difficulty .. ")") end
                end
            end
            if debugMode and not matched then
                Print("[Locks] Unrecognized raid: " .. iName .. " size=" .. maxPlayers .. " diff=" .. difficulty)
            end
        end
    end
    char.locks = locks
    char.locksUpdated = time()
    if debugMode then
        local locked = {}
        for k, v in pairs(locks) do if v then table.insert(locked, k) end end
        if #locked > 0 then
            table.sort(locked)
            Print("[Locks] Result: locked — " .. table.concat(locked, ", "))
        else
            Print("[Locks] Result: no locks found.")
        end
    end
end

-- ============================================================
-- WEEKLY RESET
-- ============================================================

-- Returns the Unix timestamp (UTC) of the most recent Wednesday 4:00 AM GMT.
-- time() in WoW returns a UTC Unix timestamp, so no timezone conversion needed.
-- Verified: Jan 1, 1970 was a Thursday, so Wednesday = offset 6 in (t/86400 % 7).
function GetLastWeeklyReset(now)
    now = now or time()
    local RESET_SECS = 4 * 3600  -- 4:00 AM = 14400 s into the day
    local adjusted   = now - RESET_SECS
    local days       = math.floor(adjusted / 86400)
    -- days % 7: 0=Thu 1=Fri 2=Sat 3=Sun 4=Mon 5=Tue 6=Wed
    local daysBack   = (days % 7 - 6 + 7) % 7
    return (days - daysBack) * 86400 + RESET_SECS
end

-- Returns the Unix timestamp of the next Wednesday 4:00 AM GMT after now.
function GetNextWeeklyReset(now)
    return GetLastWeeklyReset(now) + 7 * 86400
end

-- On login: if a weekly reset has occurred since the last stored reset,
-- clear all character lock data and update the stored timestamps.
function CheckAndApplyWeeklyReset()
    local now       = time()
    local lastReset = GetLastWeeklyReset(now)
    local nextReset = GetNextWeeklyReset(now)

    local db = BiSTrackerDB
    db.weeklyReset = db.weeklyReset or {}

    if (db.weeklyReset.lastReset or 0) < lastReset then
        for _, char in pairs(db.characters) do
            char.locks        = {}
            char.locksUpdated = nil
        end
        db.weeklyReset.lastReset = lastReset
        db.weeklyReset.nextReset = nextReset
        Print("Weekly reset detected — instance locks cleared for all characters.")
    else
        db.weeklyReset.nextReset = nextReset
    end
end

-- Returns false, "exact", or "wrong_ilvl".
-- expectedIlvl=0 skips the ilvl check.
function CheckItemStatus(gear, slotName, itemName, expectedIlvl)
    if not gear or not itemName then return false end
    local needle = Trim(itemName)
    local function evalItem(item)
        if not item or Trim(item.name) ~= needle then return false end
        if expectedIlvl and expectedIlvl > 0 and item.ilvl and item.ilvl > 0 and item.ilvl ~= expectedIlvl then
            return "wrong_ilvl"
        end
        return "exact"
    end
    local function best(a, b)
        if a == "exact" or b == "exact" then return "exact"
        elseif a == "wrong_ilvl" or b == "wrong_ilvl" then return "wrong_ilvl"
        else return false end
    end
    if slotName == "Ring" then
        return best(evalItem(gear["Ring 1"]), evalItem(gear["Ring 2"]))
    elseif slotName == "Trinket" then
        return best(evalItem(gear["Trinket 1"]), evalItem(gear["Trinket 2"]))
    elseif slotName == "Shield" then
        return evalItem(gear["Off Hand"]) or false
    elseif RANGED_SLOTS[slotName] then
        return evalItem(gear["Ranged"]) or false
    else
        return evalItem(gear[slotName]) or false
    end
end

-- Returns (total, hasBiS) for a character's active spec (or a named spec).
function GetBiSStatusForChar(charKey, specOverride)
    local char = BiSTrackerDB.characters[charKey]
    if not char then return nil end
    local specName  = specOverride or char.activeSpec
    if not specName then return nil end
    local specEntry = char.specs and char.specs[specName]
    if not specEntry then return nil end
    local specData  = ClassesBiS and ClassesBiS[specName]
    if not specData then return nil end
    local gear = specEntry.gear or {}
    local total, hasBiS = 0, 0
    for _, entry in ipairs(specData) do
        total = total + 1
        local slotName  = Trim(entry.slot)
        local bisStatus = entry.bis and CheckItemStatus(gear, slotName, Trim(entry.bis.name), entry.bis.ilvl)
        local altStatus = entry.alt and CheckItemStatus(gear, slotName, Trim(entry.alt.name), entry.alt.ilvl)
        if bisStatus == "exact" or altStatus == "exact" then
            hasBiS = hasBiS + 1
        end
    end
    return total, hasBiS
end

-- Colored "hasBiS/total" string for the BiS column (>=80% green, >=50% yellow, else red).
-- Returns a grey dash when there is no data.
function FormatBiSScore(hasBiS, total)
    if not total or total <= 0 then return "|cffaaaaaa-|r" end
    local pct = hasBiS / total
    local col = (pct >= 0.8) and "44ff44" or (pct >= 0.5 and "ffff44" or "ff6666")
    return "|cff" .. col .. hasBiS .. "/" .. total .. "|r"
end

-- Splits a spec's BiS entries into the three groups the two-column detail panels render:
-- weapons (column 1 top), col1 armor (Head–Wrist), and everything else (column 2).
function SplitBiSColumns(specData)
    local weapons, armor, col2 = {}, {}, {}
    for _, entry in ipairs(specData) do
        local s = Trim(entry.slot)
        if WEAPON_SLOTS[s] then table.insert(weapons, entry)
        elseif COL1_SLOTS[s] then table.insert(armor, entry)
        else table.insert(col2, entry) end
    end
    return weapons, armor, col2
end

function EnsureCharOrders()
    local maxOrder = BiSTrackerDB.nextCharId or 0
    for _, charData in pairs(BiSTrackerDB.characters) do
        if (charData.order or 0) > maxOrder then maxOrder = charData.order end
    end
    for _, charData in pairs(BiSTrackerDB.characters) do
        if not charData.order then
            maxOrder = maxOrder + 1
            charData.order = maxOrder
        end
    end
    BiSTrackerDB.nextCharId = maxOrder
end

-- Realm portion of a char key ("Name-Realm"). WoW names contain no "-", so the
-- realm is everything after the FIRST "-". "" if the key has no realm part.
function GetRealmFromKey(key)
    return (key and key:match("^.-%-(.+)$")) or ""
end

-- Ensure BiSTrackerDB.realmOrder has a display index for every realm currently
-- present among tracked characters. New realms are appended after the current max,
-- ordered by the lowest char.order they contain (so first-seen layout is sensible).
-- realmOrder drives realm grouping order in the Main/Edit views and the export.
function EnsureRealmOrders()
    BiSTrackerDB.realmOrder = BiSTrackerDB.realmOrder or {}
    local ro     = BiSTrackerDB.realmOrder
    local maxIdx = 0
    for _, idx in pairs(ro) do if idx > maxIdx then maxIdx = idx end end

    local realmMinOrder = {}
    for key, char in pairs(BiSTrackerDB.characters) do
        local realm = GetRealmFromKey(key)
        local o     = char.order or math.huge
        if not realmMinOrder[realm] or o < realmMinOrder[realm] then realmMinOrder[realm] = o end
    end

    local newRealms = {}
    for realm in pairs(realmMinOrder) do
        if not ro[realm] then table.insert(newRealms, realm) end
    end
    table.sort(newRealms, function(a, b) return realmMinOrder[a] < realmMinOrder[b] end)
    for _, realm in ipairs(newRealms) do
        maxIdx = maxIdx + 1
        ro[realm] = maxIdx
    end
end

-- Realms present among tracked characters, sorted by realmOrder. Used by the Main
-- list, Edit list and the export so all three agree on realm grouping order.
function GetSortedRealms()
    EnsureRealmOrders()
    local ro     = BiSTrackerDB.realmOrder
    local realms = {}
    local seen   = {}
    for key in pairs(BiSTrackerDB.characters) do
        local realm = GetRealmFromKey(key)
        if not seen[realm] then seen[realm] = true; table.insert(realms, realm) end
    end
    table.sort(realms, function(a, b) return (ro[a] or math.huge) < (ro[b] or math.huge) end)
    return realms
end

-- ============================================================
-- GEARSCORE (Mirrikat45 formula, ported from LibGearScore-1.0)
-- ============================================================

-- Heirlooms report a fixed item level; scale it by player level like the lib.
function GearScoreHeirloomLevel(level)
    level = level or UnitLevel("player") or 80
    if level < 60 then return level
    elseif level < 70 then return 3 * (level - 60) + 85
    elseif level <= 80 then return 4 * (level - 70) + 147
    else return 1 end
end

-- Score one item from its rarity, item level, and equip location.
function GearScoreItem(quality, ilvl, equipLoc)
    local slotMod = equipLoc and GS_SLOT_MOD[equipLoc]
    if not slotMod or not quality or not ilvl then return 0 end
    local qualityScale = 1
    if quality == 5 then     qualityScale = 1.3;   quality = 4      -- legendary
    elseif quality == 1 then qualityScale = 0.005; quality = 2      -- common
    elseif quality == 0 then qualityScale = 0.005; quality = 2      -- poor
    elseif quality == 7 then quality = 3; ilvl = GearScoreHeirloomLevel() end
    local f = (ilvl > 120 and GS_FORMULA.A or GS_FORMULA.B)[quality]
    if not f then return 0 end
    local score = math.floor(((ilvl - f.A) / f.B) * slotMod * GS_SCALE * qualityScale)
    return (score > 0) and score or 0
end

-- Total GearScore for a set of gear.
--   own == true  : reads the logged-in player's live equipped inventory (class auto-detected).
--   own == false : scores the passed-in `gear` table (keyed by slot name, from a raid scan)
--                  using its stored quality/ilvl/equipLoc, with `class`/`spec` driving the
--                  hunter and Titan's Grip weapon adjustments.
function ComputeGearScore(own, class, spec, gear)
    if own == nil then own = true end

    local classFile
    if own then
        local _, c = UnitClass("player"); classFile = c
    else
        classFile = class
    end
    local isHunter = (classFile == "HUNTER")

    -- Titan's Grip: a two-hander in the off-hand halves both weapon scores.
    local titanGrip = 1
    if own then
        local ohLink = GetInventoryItemLink("player", 17)
        if ohLink then
            local mhLink = GetInventoryItemLink("player", 16)
            local mhLoc  = mhLink and select(9, GetItemInfo(mhLink))
            local ohLoc  = select(9, GetItemInfo(ohLink))
            if mhLoc == "INVTYPE_2HWEAPON" or ohLoc == "INVTYPE_2HWEAPON" then
                titanGrip = 0.5
            end
        end
    else
        -- Can't read a scanned player's equip locations reliably; a Fury Warrior
        -- must have Titan's Grip, so apply the same weapon penalty.
        local isFury = (spec == "Fury Warrior")
        if isFury then titanGrip = 0.5 end
    end

    -- GEAR_SLOTS lists exactly the 17 scored slots (shirt/tabard excluded).
    local total = 0
    for _, slot in ipairs(GEAR_SLOTS) do
        local quality, ilvl, equipLoc
        if own then
            local link = GetInventoryItemLink("player", slot.id)
            if link then
                local _, _, q, il, _, _, _, _, eloc = GetItemInfo(link)
                quality, ilvl, equipLoc = q, il, eloc
            end
        else
            local item = gear and gear[slot.name]
            if item then quality, ilvl, equipLoc = item.quality, item.ilvl, item.equipLoc end
        end
        local score = GearScoreItem(quality, ilvl, equipLoc)
        if score > 0 then
            if isHunter then
                if slot.id == 16 or slot.id == 17 then
                    score = score * 0.3164      -- melee weapons matter little
                elseif slot.id == 18 then
                    score = score * 5.3224      -- ranged is the primary weapon
                end
            end
            if slot.id == 16 or slot.id == 17 then score = score * titanGrip end
            total = total + score
        end
    end
    return math.floor(total)
end

-- Returns a 6-char hex color string (no #) for the given GearScore value.
-- Linearly interpolates between GS_COLOR_STOPS so there are no hard step transitions.
function GetGearScoreColor(gs)
    gs = gs or 0
    local stops = GS_COLOR_STOPS
    if gs <= stops[1].gs then
        return string.format("%02x%02x%02x", stops[1].r, stops[1].g, stops[1].b)
    end
    if gs >= stops[#stops].gs then
        local s = stops[#stops]
        return string.format("%02x%02x%02x", s.r, s.g, s.b)
    end
    for i = 1, #stops - 1 do
        if gs >= stops[i].gs and gs < stops[i+1].gs then
            local t  = (gs - stops[i].gs) / (stops[i+1].gs - stops[i].gs)
            local r  = math.floor(stops[i].r + (stops[i+1].r - stops[i].r) * t)
            local g  = math.floor(stops[i].g + (stops[i+1].g - stops[i].g) * t)
            local b  = math.floor(stops[i].b + (stops[i+1].b - stops[i].b) * t)
            return string.format("%02x%02x%02x", r, g, b)
        end
    end
    return "9a9a9a"
end

-- ============================================================
-- GEAR SCAN (spec-aware)
-- ============================================================

-- Reads one of the player's equipped slots. Returns (entry, resolved):
--   entry = nil, resolved = true   -> slot is empty (caller should clear it)
--   entry = nil, resolved = false  -> link/info not ready yet (caller should retry)
--   entry = table, resolved = bool -> item found; resolved is false until GetItemInfo
--                                     caches the ilvl (needed for BiS check + GearScore).
-- The name comes from the link string (available immediately) so name-matching works at once.
local function ReadPlayerSlot(slotId)
    if not GetInventoryItemID("player", slotId) then return nil, true end
    local link = GetInventoryItemLink("player", slotId)
    if not link then return nil, false end
    local itemName = link:match("%[(.-)%]")
    if not itemName then return nil, false end
    local _, _, _, ilvl = GetItemInfo(link)
    local entry = { name=itemName, ilvl=ilvl or 0, link=link, id=tonumber(link:match("item:(%d+)")) or 0 }
    return entry, (ilvl ~= nil)
end

function ScanGear()
    local key  = GetCharKey()
    local char = BiSTrackerDB.characters[key]
    if not char or not char.activeSpec or not char.specs then return end

    local specEntry = char.specs[char.activeSpec]
    if not specEntry then return end

    specEntry.gear = specEntry.gear or {}
    scanRetryQueue = {}

    for _, slot in ipairs(GEAR_SLOTS) do
        local entry, resolved = ReadPlayerSlot(slot.id)
        if entry then
            specEntry.gear[slot.name] = entry
            if not resolved then table.insert(scanRetryQueue, { slot=slot, specKey=char.activeSpec }) end
        elseif resolved then
            specEntry.gear[slot.name] = nil               -- empty slot
        else
            table.insert(scanRetryQueue, { slot=slot, specKey=char.activeSpec })  -- not cached yet
        end
    end

    specEntry.gearScore = ComputeGearScore(true)

    if debugMode then
        local found = #GEAR_SLOTS - #scanRetryQueue
        Print("[GearScan] " .. found .. "/" .. #GEAR_SLOTS .. " slots scanned." ..
              (#scanRetryQueue > 0 and " Retrying " .. #scanRetryQueue .. " uncached..." or ""))
        Print("[GearScore] " .. (specEntry.gearScore or 0) ..
              (#scanRetryQueue > 0 and " (partial — items still caching)" or ""))
    end
end

-- Retries one queued slot. Returns true once the slot is resolved (item cached or
-- confirmed empty) so retryFrame can drop it; false to keep retrying.
function RetryUncachedSlot(entry)
    local slot    = entry.slot
    local specKey = entry.specKey
    local char    = BiSTrackerDB.characters[GetCharKey()]
    if not char or not char.specs or not char.specs[specKey] then return true end

    local gear = char.specs[specKey].gear
    local slotEntry, resolved = ReadPlayerSlot(slot.id)
    if slotEntry then
        gear[slot.name] = slotEntry
        return resolved
    elseif resolved then
        gear[slot.name] = nil   -- became empty
        return true
    end
    return false                -- link/info not ready yet
end

-- ============================================================
-- CHARACTER REGISTRATION (multi-spec)
-- ============================================================

function RegisterCharacter()
    local key  = GetCharKey()
    local name = UnitName("player")
    local _, class = UnitClass("player")
    local spec  = DetectSpec()
    local color = SPEC_COLORS[spec] or "aaaaaa"

    if not BiSTrackerDB.characters[key] then
        BiSTrackerDB.nextCharId = (BiSTrackerDB.nextCharId or 0) + 1
        BiSTrackerDB.characters[key] = {
            name      = name,
            class     = class,
            locks     = {},
            activeSpec = spec,
            specs     = { [spec] = { color=color, gear={}, gearScore=0 } },
            order     = BiSTrackerDB.nextCharId,
        }
        if debugMode then Print("New character registered: |cff" .. color .. name .. "|r (" .. spec .. ")") end
    else
        local char = BiSTrackerDB.characters[key]
        char.name  = name
        char.class = class
        char.specs  = char.specs or {}

        if not char.specs[spec] then
            char.specs[spec] = { color=color, gear={} }
            if debugMode then Print("New spec added for " .. name .. ": |cff" .. color .. spec .. "|r") end
        end
        char.activeSpec = spec
    end

    -- Automatic scans are gated by the General settings; manual /bis locks and /bis scan
    -- always work regardless.
    if LS().autoScanLocks then ScanInstanceLocks() end
    if LS().autoScanGear  then ScanGear() end
end
