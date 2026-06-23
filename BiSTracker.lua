-- BiSTracker v1.3
-- Author: Ceeser

local ADDON_NAME = "BiSTracker"


-- ============================================================
-- STATE
-- ============================================================

BiSTrackerDB = BiSTrackerDB or { characters = {} }

mainFrame      = nil
raidScanFrame  = nil   -- assigned in GUI/Loot.lua
raidScanQueue  = {}
detailPanels   = {}
expandedChars  = {}
viewMode       = "main"

scanRetryQueue = {}  -- each entry: { slot=slot, specKey=specName }
local retryTimer     = 0
local RETRY_INTERVAL = 3.0

debugMode = false   -- toggle in-game with /bis debug


-- ============================================================
-- DELAYED INIT
-- ============================================================

-- Declare these before any SetScript closures that reference them as upvalues
local lastGearScanTime = 0
local SCAN_COOLDOWN    = 5     -- min seconds between auto-scans from gear changes
local equippedSnapshot = {}

local function BuildEquippedSnapshot()
    local snap = {}
    for _, slot in ipairs(GEAR_SLOTS) do
        snap[slot.id] = GetInventoryItemID("player", slot.id) or 0
    end
    return snap
end

local function EquippedChanged(snap)
    for _, slot in ipairs(GEAR_SLOTS) do
        if (snap[slot.id] or 0) ~= (equippedSnapshot[slot.id] or 0) then
            return true
        end
    end
    return false
end

local initDelayFrame = CreateFrame("Frame")
local initAccum      = 0
initDelayFrame:Hide()
initDelayFrame:SetScript("OnUpdate", function(self, elapsed)
    initAccum = initAccum + elapsed
    if initAccum >= 4 then
        initAccum = 0; self:Hide()
        RegisterCharacter()
        lastGearScanTime = GetTime()
        equippedSnapshot = BuildEquippedSnapshot()
        if LS().scanRaid and not raidScanFrame:IsShown() then
            raidScanQueue = {}
            raidScanFrame:Show()
            raidScanFrame:TriggerRebuild()
        end
        BiSTracker_AnnouncerInit()
    end
end)

local rescanFrame    = CreateFrame("Frame")
local rescanAccum    = 0
local rescanDelay    = 1.0
local rescanWithSpec = false  -- true when triggered by UNIT_INVENTORY_CHANGED
rescanFrame:Hide()
rescanFrame:SetScript("OnUpdate", function(self, elapsed)
    rescanAccum = rescanAccum + elapsed
    if rescanAccum >= rescanDelay then
        rescanAccum = 0; self:Hide()
        if rescanWithSpec then
            -- Re-detect spec on the live character; add as new spec if not seen before
            local key  = GetCharKey()
            local char = BiSTrackerDB.characters[key]
            if char then
                local spec  = DetectSpec()
                local color = SPEC_COLORS[spec] or "aaaaaa"
                char.specs  = char.specs or {}
                if not char.specs[spec] then
                    char.specs[spec] = { color=color, gear={} }
                    if debugMode then Print("New spec added for " .. (char.name or "?") .. ": |cff" .. color .. spec .. "|r") end
                end
                if char.activeSpec ~= spec then
                    char.activeSpec = spec
                end
            end
        end
        if debugMode then Print("Scanning gear...") end
        ScanGear()
        lastGearScanTime  = GetTime()
        equippedSnapshot  = BuildEquippedSnapshot()
        if mainFrame and mainFrame:IsShown() then BiSTracker_RefreshList() end
    end
end)

function QueueRescan(delay, detectSpec)
    rescanDelay    = delay
    rescanAccum    = 0
    rescanWithSpec = detectSpec or false
    rescanFrame:Show()
end


-- ============================================================
-- EVENTS
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_RAID")
eventFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        BiSTrackerDB = BiSTrackerDB or { characters = {} }
        debugMode = (BiSTrackerDB.debugMode == true)   -- restore saved debug state
        CreateMinimapButton()
        Print("Loaded! Use |cffaaaaaa/bis|r or click the minimap icon.")

    elseif event == "PLAYER_LOGIN" then
        RequestRaidInfo()
        CheckAndApplyWeeklyReset()
    elseif event == "PLAYER_ENTERING_WORLD" then
        initAccum = 0; initDelayFrame:Show()
        -- Re-apply minimap icon position now that frame sizes/shape are reliable
        if BiSTracker_UpdateMinimapPosition then BiSTracker_UpdateMinimapPosition() end
    elseif event == "UPDATE_INSTANCE_INFO" then
        -- intentionally no-op: lock scan runs via initDelayFrame on PLAYER_ENTERING_WORLD
    elseif event == "UNIT_INVENTORY_CHANGED" and arg1 == "player" then
        local snap = BuildEquippedSnapshot()
        if next(equippedSnapshot) == nil then
            equippedSnapshot = snap
        elseif EquippedChanged(snap) then
            equippedSnapshot = snap
            -- Only auto-rescan if enabled; otherwise the user rescans via /bis scan.
            if LS().autoScanGear then
                if debugMode then Print("Equipped gear changed - queuing spec+gear scan...") end
                local sinceLastScan = GetTime() - lastGearScanTime
                local delay = (sinceLastScan < SCAN_COOLDOWN) and (SCAN_COOLDOWN - sinceLastScan + 0.5) or 1.0
                QueueRescan(delay, true)
            end
        end
    elseif event == "RAID_ROSTER_UPDATE" then
        if debugMode then Print("[RaidScan] New Raid Roster received.") end
        if LS().scanRaid then
            if not raidScanFrame:IsShown() then raidScanFrame:Show() end
            raidScanFrame:HandleRosterUpdate()
        end
        BiSTracker_AnnouncerOnRoster()
    elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_WARNING" then
        HandlePostedItem(arg2 or "", arg1 or "")
    elseif event == "CHAT_MSG_ADDON" then
        BiSTracker_OnAddonMessage(arg1, arg2, arg3, arg4)
    end
end)


-- ============================================================
-- RETRY FRAME
-- ============================================================

local retryFrame = CreateFrame("Frame")
retryFrame:SetScript("OnUpdate", function(self, elapsed)
    if #scanRetryQueue == 0 then return end
    retryTimer = retryTimer + elapsed
    if retryTimer >= RETRY_INTERVAL then
        retryTimer = 0
        local remaining = {}
        local anyResolved = false
        for _, entry in ipairs(scanRetryQueue) do
            local resolved = RetryUncachedSlot(entry)
            if resolved then anyResolved = true
            else table.insert(remaining, entry) end
        end
        scanRetryQueue = remaining
        if anyResolved then
            local char = BiSTrackerDB.characters[GetCharKey()]
            if char and char.activeSpec and char.specs and char.specs[char.activeSpec] then
                char.specs[char.activeSpec].gearScore = ComputeGearScore(true)
            end
            if mainFrame and mainFrame:IsShown() then BiSTracker_RefreshList() end
        end
    end
end)


-- ============================================================
-- SLASH COMMANDS
-- ============================================================

SLASH_BISTRACKER1 = "/bis"
SlashCmdList["BISTRACKER"] = function(msg)
    local cmd = msg and msg:lower():match("^%s*(.-)%s*$") or ""
    if cmd == "scan" then
        ScanGear()
        if mainFrame and mainFrame:IsShown() then BiSTracker_RefreshList() end
    elseif cmd == "locks" then
        ScanInstanceLocks(); Print("Instance lockouts refreshed.")
    elseif cmd == "export" then
        BiSTracker_ShowExportFrame()
    elseif cmd == "spec" then
        Print("Spec: " .. DetectSpec())
    elseif cmd == "gs" then
        Print("|cffffff00GearScore breakdown:|r")
        local anyUncached = false
        for _, slot in ipairs(GEAR_SLOTS) do
            local link = GetInventoryItemLink("player", slot.id)
            if link then
                local _, _, quality, ilvl, _, _, _, _, equipLoc = GetItemInfo(link)
                if ilvl and equipLoc then
                    DEFAULT_CHAT_FRAME:AddMessage(string.format(
                        "  %s: q=%s ilvl=%s %s -> |cffffffff%d|r",
                        slot.name, tostring(quality), tostring(ilvl), tostring(equipLoc),
                        GearScoreItem(quality, ilvl, equipLoc)))
                else
                    anyUncached = true
                    DEFAULT_CHAT_FRAME:AddMessage("  " .. slot.name ..
                        ": |cffff4444GetItemInfo not cached yet|r " .. link)
                end
            end
        end
        Print("Total ComputeGearScore(): |cffffffff" .. ComputeGearScore(true) .. "|r")
        if anyUncached then
            Print("Some items aren't cached yet — auto-retry is active; run |cffaaaaaa/bis gs|r again shortly.")
        end
    elseif cmd == "debug" then
        debugMode = not debugMode
        BiSTrackerDB.debugMode = debugMode   -- persist across sessions
        Print("Debug mode " .. (debugMode and "|cff44ff44ON|r" or "|cffff4444OFF|r"))
    elseif cmd == "fakelocks" or cmd:match("^fakelocks %d$") then
        local key  = GetCharKey()
        local char = BiSTrackerDB.characters[key]
        if not char then Print("No character registered yet."); return end
        local idx = tonumber(cmd:match("(%d)$"))
        if idx then
            local inst = INSTANCES[idx]
            if not inst then Print("Invalid index. Use 1-" .. #INSTANCES .. "."); return end
            char.locks = char.locks or {}
            char.locks[inst.key] = true
            char.locksUpdated = time()
            Print("Fake lock applied: |cffffffff" .. inst.label .. "|r (" .. idx .. ") for " .. (char.name or key))
        else
            char.locks = {}
            for _, inst in ipairs(INSTANCES) do
                char.locks[inst.key] = true
            end
            char.locksUpdated = time()
            Print("Fake locks applied for |cffffffff" .. (char.name or key) .. "|r — all instances marked locked.")
        end
        if mainFrame and mainFrame:IsShown() then BiSTracker_RefreshList() end
    elseif cmd == "weekreset" then
        if BiSTrackerDB.weeklyReset then BiSTrackerDB.weeklyReset.lastReset = 0 end
        CheckAndApplyWeeklyReset()
        if mainFrame and mainFrame:IsShown() then BiSTracker_RefreshList() end
    elseif cmd == "help" then
        Print("|cffffff00BiSTracker commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis|r - Toggle main window")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis scan|r - Rescan equipped gear")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis locks|r - Refresh instance lockouts")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis export|r - Show export string")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis spec|r - Print currently detected spec")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis gs|r - [Debug] Print GearScore breakdown")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis debug|r - Toggle debug messages")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis reset|r - Clear all character data")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis fakelocks|r - [Debug] Lock all instances for current char")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis fakelocks 1-6|r - [Debug] Lock one instance (1=ICC25 2=ICC10 3=RS25 4=RS10 5=TOC25 6=TOC10)")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis weekreset|r - [Debug] Force weekly reset (clears all locks)")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa/bis help|r - Show this help")
    elseif cmd == "reset" then
        local angle = BiSTrackerDB.minimapAngle
        local freeX = BiSTrackerDB.minimapFreeX
        local freeY = BiSTrackerDB.minimapFreeY
        local free  = BiSTrackerDB.minimapFree
        local ls    = BiSTrackerDB.lootSettings
        local dbg   = BiSTrackerDB.debugMode
        BiSTrackerDB = { characters={}, minimapAngle=angle, minimapFreeX=freeX, minimapFreeY=freeY, minimapFree=free, lootSettings=ls, debugMode=dbg }
        expandedChars = {}; detailPanels = {}
        Print("Character database cleared.")
    else
        if mainFrame and mainFrame:IsShown() then mainFrame:Hide()
        else BiSTracker_ShowMainFrame() end
    end
end
