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

-- Talent rank at a grid position (tier=row, column); locale-independent. inspect=true
-- reads the NotifyInspect target. 0 if not found.
function GetTalentRankAt(tab, tier, column, inspect)
    for i = 1, GetNumTalents(tab, inspect) do
        local _, _, t, c, rank = GetTalentInfo(tab, i, inspect)
        if t == tier and c == column then return rank or 0 end
    end
    return 0
end

-- DK Blood: DPS takes Dancing Rune Weapon (tier 11, col 2); a tank skips it.
function ResolveBloodDK(inspect)
    if GetTalentRankAt(1, 11, 2, inspect) > 0 then return "Blood DK Dps" end
    return "Blood DK Tank"
end

-- Shaman tab 2: Enhancement takes Feral Spirit (tier 11, col 2); Spellhance skips it.
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

-- Unix timestamp of the most recent Wednesday 4:00 AM GMT (time() is already UTC).
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

-- On login: clear all char locks if a weekly reset passed since the stored one.
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

-- Split a spec's BiS entries into the detail-panel groups: weapons, col1 armor, col2.
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

-- Realm portion of a char key ("Name-Realm") — everything after the first "-".
function GetRealmFromKey(key)
    return (key and key:match("^.-%-(.+)$")) or ""
end

-- Assign a realmOrder index to every realm in use; new ones appended after the max,
-- ordered by their lowest char.order. Drives realm grouping in Main/Edit/export.
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

-- Realms in use, sorted by realmOrder (Main list, Edit list and export all agree).
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

-- Total GearScore. own=true reads the player's live inventory; own=false scores the
-- passed `gear` table (raid scan), with class/spec driving hunter/Titan's Grip weapon mods.
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
        -- Can't read a scanned player's equip locs; Fury must have Titan's Grip.
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

-- 6-char hex color (no #) for a GearScore, interpolated between GS_COLOR_STOPS.
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

-- Read an equipped slot. Returns (entry, resolved): nil/true = empty, nil/false = retry,
-- table/false = item found but ilvl not cached yet (name is read from the link at once).
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

    -- Auto-scans gated by General settings; manual /bis locks and /bis scan always work.
    if LS().autoScanLocks then ScanInstanceLocks() end
    if LS().autoScanGear  then ScanGear() end
end

-- ============================================================
-- SETTINGS  (universal helpers relocated from Settings.lua)
-- ============================================================
-- General-purpose helpers with no GUI and no Settings.lua-local state: raid/loot lookups over the
-- WoW API, a chat-channel wrapper, addon-message name chunking, and version-string parsing.

function GetMLName()
    local method, partyIdx, raidIdx = GetLootMethod()
    if method ~= "master" then return nil end
    if partyIdx == 0 then return UnitName("player") end
    if raidIdx then return (GetRaidRosterInfo(raidIdx)) end
    return nil
end

-- True if the poster is Raid Lead / Assist (rank >= 1) or the Master Looter.
function PosterIsOfficer(senderName)
    for i = 1, GetNumRaidMembers() do
        local n, r = GetRaidRosterInfo(i)
        if n == senderName then
            if r >= 1 then return true end
            break
        end
    end
    local ml = GetMLName()
    return ml ~= nil and senderName == ml
end

function RankOf(name)
    for i = 1, GetNumRaidMembers() do
        local n, rank = GetRaidRosterInfo(i)
        if n == name then return rank end
    end
    return nil
end

function IsOnline(name)
    for i = 1, GetNumRaidMembers() do
        local n, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
        if n == name then return online and true or false end
    end
    return false
end

function SendInChannel(msg, channel)
    if     channel == "say"         then SendChatMessage(msg, "SAY")
    elseif channel == "raidChat"    then SendChatMessage(msg, "RAID")
    elseif channel == "raidWarning" then SendChatMessage(msg, "RAID_WARNING")
    end
end

-- Split a name list into addon-message bodies of the form "<prefix>Name1;Name2;i/n", each within the
-- 255-byte cap (240 with margin). Always returns >=1 body ("<prefix>1/1" for an empty list).
function ChunkNames(prefix, names)
    local budget = 240 - #prefix - 8   -- 8 = room for the trailing ";i/n" marker
    local chunks, cur = {}, ""
    for _, name in ipairs(names) do
        local piece = (cur == "") and name or (";" .. name)
        if cur ~= "" and #cur + #piece > budget then
            chunks[#chunks + 1] = cur
            cur = name
        else
            cur = cur .. piece
        end
    end
    chunks[#chunks + 1] = cur
    local total, bodies = #chunks, {}
    for i = 1, total do
        local marker  = i .. "/" .. total
        local payload = chunks[i]
        bodies[i] = (payload == "") and (prefix .. marker) or (prefix .. payload .. ";" .. marker)
    end
    return bodies
end

-- Parse "1.7.10" -> {1,7,10}; ignores any non-numeric junk.
function ParseVersion(s)
    local t = {}
    for n in tostring(s):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- True if version string `a` is strictly older than `b` (numeric, component-wise; 1.7.9 < 1.7.10).
function VersionLess(a, b)
    local A, B = ParseVersion(a), ParseVersion(b)
    local n = math.max(#A, #B)
    for i = 1, n do
        local x, y = A[i] or 0, B[i] or 0
        if x ~= y then return x < y end
    end
    return false
end

-- Accept only plain dotted-numeric versions (reject letters / overlong junk from a bad actor).
function IsValidVersion(s)
    return type(s) == "string" and #s > 0 and #s <= 16 and s:match("^%d+[%d%.]*$") ~= nil
end

-- Split a presence message into (kind, version). Accepts the versioned form (HELLO:1.7.2) and the
-- bare legacy form (HELLO) sent by pre-1.7.2 clients, which have no version to report.
function ParsePresence(msg)
    if msg == "HELLO" then return "HELLO", nil end
    if msg == "SKIP"  then return "SKIP",  nil end
    if msg:sub(1, 6) == "HELLO:" then return "HELLO", msg:sub(7) end
    if msg:sub(1, 5) == "SKIP:"  then return "SKIP",  msg:sub(6) end
    return nil, nil
end
