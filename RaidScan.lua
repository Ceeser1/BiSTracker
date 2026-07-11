-- ============================================================
-- RAID SCAN (background engine)
--
-- Child of Settings.lua: the "Players in this Raid" UI (list
-- rows, detail panels, checkboxes) lives there; this file owns
-- everything that runs in the background - the inspect queue,
-- out-of-range parking, snapshot persistence and the scan frame.
--
-- Shared state this file OWNS (globals, read by Settings.lua):
--   raidScanData, raidScanOOR, raidScanFailed, raidScanQueue,
--   raidScanFrame (declared in BiSTracker.lua, assigned here)
-- Globals from other files this file USES:
--   LS(), BiSTracker_RefreshRaidList()  (Settings.lua)
--   LoadMSChanged(), LoadWhisperOptOut(), BroadcastMSChanges(),
--   raidMSChanged, noWhisperUsers, whisperOn  (Announcer.lua)
-- ============================================================

raidScanData   = {}  -- [playerName] = { spec, class, gear={} }
raidScanOOR    = {}  -- [playerName] = queue entry: parked ONLY for being out of inspect range.
                     -- Re-checked as a whole every OOR_POLL and pushed back to the queue front
                     -- once in range. Shows "Out of range, retrying...".
raidScanFailed = {}  -- [playerName]=true: an inspect returned no gear/talents MAX_REQUEUES times
                     -- in a row, so it was dropped. Shows "Unable to scan" until the next full scan.
raidScanQueue  = {}  -- FIFO of { unitID, name, isSelf, requeues }: members waiting to be inspected

do
    raidScanFrame = CreateFrame("Frame")
    local mainTimer        = 0
    local inspectTimer     = 0
    local currentUnit      = nil
    local currentName      = nil
    local currentEntry     = nil
    local rebuildTimer       = 0
    local rebuildActive      = false
    local fullScanInProgress = false  -- true while draining a full-roster queue (vs individual joins)
    local snapshotLoadAttempted = false  -- seed panel from the saved snapshot once per raid (first roster update)
    local onlineStatus       = {}     -- onlineStatus[name] = bool; last-known connection state
    local connTimer          = 0
    local CONN_POLL          = 2.0    -- seconds between connection-status polls
    -- raidScanOOR (file-scope, so the raid-list render can read it) parks ONLY out-of-range players.
    -- ALL of it is swept every OOR_POLL; entries back in range jump to the queue front. It keeps
    -- retrying indefinitely (out of range isn't a failure); only a full queue rebuild clears it.
    local oorTimer           = 0
    local OOR_POLL           = 10.0   -- seconds between out-of-range sweeps (whole table at once)
    local INTERVAL           = 1.5    -- idle gap between inspects; also the safety margin against
                                      -- ultra-late replies being misattributed (see GUID tracking below)
    local TALENT_TIMEOUT     = 2.5    -- max wait for inspect talent data before giving up on this target
    local REBUILD_INTERVAL   = 300.0  -- 5 minutes between full scans
    local MAX_REQUEUES       = 5      -- incomplete-inspect (no gear/talents) re-queue cap before dropping
                                      -- to "Unable to scan"; re-attempted on the next full scan

    -- Inspect-buffer ownership tracking. The 3.3.5 client keeps ONE global inspect buffer:
    -- GetTalentTabInfo(tab, true) has no unit argument and returns whatever the last answered
    -- NotifyInspect (ours, another addon's like GearScore, or the Blizzard inspect UI) put
    -- there. Before reading talents we must prove the buffer belongs to OUR target, otherwise
    -- a stale/foreign buffer gets attributed to the wrong player (e.g. Combat rogue stored as
    -- Subtlety because the previous target's tab-3-heavy talents were still readable).
    --   currentGUID      = who WE asked about (set when we send NotifyInspect)
    --   lastNotifyGUID   = who the most recent NotifyInspect from ANY source asked about
    --   talentsReadyGUID = whose data provably sits in the buffer (INSPECT_TALENT_READY arrived)
    local currentGUID      = nil
    local lastNotifyGUID   = nil
    local talentsReadyGUID = nil

    hooksecurefunc("NotifyInspect", function(unit)
        lastNotifyGUID   = UnitGUID(unit)
        talentsReadyGUID = nil   -- new request in flight: buffer ownership unknown until READY fires
    end)

    raidScanFrame:RegisterEvent("INSPECT_TALENT_READY")
    raidScanFrame:SetScript("OnEvent", function()
        talentsReadyGUID = lastNotifyGUID   -- the buffer now holds the last requested player's talents
    end)

    -- Total talent points readable from the inspect buffer; 0 until real data arrived. Sanity
    -- check on top of the GUID ownership above (INSPECT_TALENT_READY can fire a moment before
    -- the data is actually queryable).
    local function InspectTalentPoints()
        local total = 0
        for tab = 1, GetNumTalentTabs(true) do
            local _, _, pts = GetTalentTabInfo(tab, true)
            total = total + (pts or 0)
        end
        return total
    end

    local function DetectInspectSpec(classFile)
        if not classFile then return nil end
        local trees = CLASS_TREES[classFile]
        if not trees then return nil end
        local maxPoints, maxTab = 0, 1
        for tab = 1, GetNumTalentTabs(true) do
            local _, _, pts = GetTalentTabInfo(tab, true)
            if (pts or 0) > maxPoints then maxPoints = pts; maxTab = tab end
        end
        if debugMode then
            if maxPoints == 0 then
                Print("[SpecDetect] " .. classFile .. ": no talent points read (inspect data not ready)")
            else
                Print("[SpecDetect] " .. classFile .. ": top tree |cffffff00" .. (trees[maxTab] or ("tab " .. maxTab)) .. "|r (tab " .. maxTab .. ", " .. maxPoints .. " pts)")
            end
        end
        if maxPoints == 0 then return nil end
        if classFile == "DEATHKNIGHT" and maxTab == 1 then return ResolveBloodDK(true) end
        if classFile == "SHAMAN"      and maxTab == 2 then return ResolveEnhanceShaman(true) end
        return trees[maxTab]
    end

    -- Replaces raidScanQueue with a fresh full-roster queue (self first).
    local function BuildFullQueue()
        fullScanInProgress = true
        raidScanQueue = {}
        raidScanFailed = {}   -- a full sweep re-attempts everyone: clear stale "Unable to scan" flags
        raidScanOOR = {}      -- and drop all out-of-range parking
        oorTimer = 0
        local playerName = UnitName("player")
        table.insert(raidScanQueue, { unitID="player", name=playerName, isSelf=true })
        for i = 1, GetNumRaidMembers() do
            local n, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
            if n and n ~= playerName and online then
                table.insert(raidScanQueue, { unitID="raid"..i, name=n })
            end
        end
        return #raidScanQueue
    end

    -- Persist the current scan results as a per-realm snapshot so a relog, crash, or
    -- character switch can show the full raid instantly instead of rescanning everyone
    -- from scratch. Called whenever a scan queue drains (see OnQueueDrained).
    local function SaveRaidSnapshot()
        if not next(raidScanData) then return end   -- nothing scanned yet: keep any existing snapshot
        local members = {}
        for name, data in pairs(raidScanData) do members[name] = data end  -- shallow copy of the map
        BiSTrackerDB.raidSnapshot = { realm = GetRealmName(), time = time(), members = members }
        -- (MS-Changed flags are persisted separately via SaveMSChanged, saved on every change.)
    end

    -- Seed raidScanData from the saved snapshot, keeping only players currently in the raid
    -- (and only if the snapshot was taken on this realm). Returns how many were restored.
    local function LoadRaidSnapshot()
        local snap = BiSTrackerDB.raidSnapshot
        if not snap or not snap.members then return 0 end
        if snap.realm and snap.realm ~= GetRealmName() then return 0 end
        local roster = { [UnitName("player")] = true }
        for i = 1, GetNumRaidMembers() do
            local n = GetRaidRosterInfo(i)
            if n then roster[n] = true end
        end
        local loaded = 0
        for name, data in pairs(snap.members) do
            if roster[name] and not raidScanData[name] then
                raidScanData[name] = data
                loaded = loaded + 1
            end
        end
        if debugMode and loaded > 0 then
            local age = snap.time and (time() - snap.time) or 0
            Print("[RaidScan] Snapshot restored: |cffffff00" .. loaded .. "|r member(s) (" .. age .. "s old). Rescanning in background...")
        end
        return loaded
    end

    -- Restore the saved snapshot + MS-Changed flags once per raid session, from whichever kickoff
    -- runs first: RAID_ROSTER_UPDATE (join) or TriggerRebuild (login/reload — RAID_ROSTER_UPDATE
    -- often doesn't fire on a /reload). Returns how many gear entries were restored.
    local function LoadSnapshotOnce()
        if snapshotLoadAttempted then return 0 end
        snapshotLoadAttempted = true
        LoadMSChanged()
        LoadWhisperOptOut()                 -- restore saved whisper opt-out choices for current members
        local loaded = LoadRaidSnapshot()   -- prints "Snapshot restored: N" when loaded > 0
        if debugMode and loaded == 0 then
            Print(BiSTrackerDB.raidSnapshot
                and "[RaidScan] Snapshot found but no members matched the current raid."
                or  "[RaidScan] No saved snapshot to restore.")
        end
        return loaded
    end

    -- Returns true when a player is already being inspected, queued, or parked out of range.
    local function IsQueued(name)
        if currentName == name then return true end
        if raidScanOOR[name] then return true end
        for _, e in ipairs(raidScanQueue) do
            if e.name == name then return true end
        end
        return false
    end

    -- Remove a player from the queue / cancel their in-progress inspection; true if either happened.
    -- Also unparks them from the out-of-range table (side effect only: parked players don't count as
    -- "removed" for the caller's queue-drained check).
    local function RemoveFromQueue(name)
        local newQueue = {}
        local removed = false
        for _, e in ipairs(raidScanQueue) do
            if e.name ~= name then table.insert(newQueue, e) else removed = true end
        end
        raidScanQueue = newQueue
        raidScanOOR[name] = nil
        if currentName == name then
            currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
            mainTimer = 0
            return true
        end
        return removed
    end

    -- Appends a single player to the queue and starts the scan immediately if idle.
    local function EnqueuePlayer(name, unitID, isSelf)
        raidScanFailed[name] = nil   -- retrying this player: clear any "Unable to scan" flag
        raidScanOOR[name]    = nil   -- and any out-of-range parking
        local entry = { unitID=unitID, name=name, isSelf=isSelf or false }
        local idle = #raidScanQueue == 0 and currentUnit == nil
        table.insert(raidScanQueue, entry)
        if idle then
            -- Individual scan: start it now, but DON'T reset the 5-min full-scan countdown.
            fullScanInProgress = false
            mainTimer = INTERVAL
        end
    end

    -- On queue empty: a full scan restarts the 5-min countdown; an individual scan keeps it.
    local function OnQueueDrained()
        if fullScanInProgress then
            fullScanInProgress = false
            rebuildActive = true; rebuildTimer = 0
            if debugMode then Print("[RaidScan] Full scan complete. Next full scan in 5 minutes.") end
        else
            if not rebuildActive then rebuildActive = true; rebuildTimer = 0 end
            if debugMode then
                local remaining = math.max(0, math.ceil(REBUILD_INTERVAL - rebuildTimer))
                Print("[RaidScan] Individual Scan complete. Next full Scan scheduled in |cffffff00" .. remaining .. "|r seconds.")
            end
        end
        SaveRaidSnapshot()      -- persist the freshest full picture of the raid
        BroadcastMSChanges()    -- announcer pushes the MS-Changed set to listeners
    end

    -- Reacts to a single member's online/offline transition (driven by polling).
    local function HandleConnectionChange(name, unitID, online)
        if online then
            if debugMode then Print("[RaidScan] |cffffff00" .. name .. "|r came back online.") end
            if not IsQueued(name) then
                local hasData   = raidScanData[name] ~= nil
                local queueIdle = #raidScanQueue == 0 and currentUnit == nil
                -- Have data and nothing running: let the 5-min timer rescan naturally.
                if not (hasData and queueIdle) then
                    EnqueuePlayer(name, unitID, false)
                    if not raidScanFrame:IsShown() then raidScanFrame:Show() end
                end
            end
        else
            if debugMode then Print("[RaidScan] |cffffff00" .. name .. "|r went offline.") end
            local removed = RemoveFromQueue(name)
            if removed and currentUnit == nil and #raidScanQueue == 0 then
                OnQueueDrained()
            end
        end
        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()
        end
    end

    -- Poll roster connection status (no UNIT_CONNECTION in 3.3.5a); fire on transitions.
    local function PollConnectionChanges()
        local playerName = UnitName("player")
        local seen = {}
        for i = 1, GetNumRaidMembers() do
            local n, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
            if n and n ~= playerName then
                seen[n] = true
                local now = online and true or false
                local was = onlineStatus[n]
                if was == nil then
                    onlineStatus[n] = now            -- first sighting: record, no message
                elseif was ~= now then
                    onlineStatus[n] = now
                    HandleConnectionChange(n, "raid"..i, now)
                end
            end
        end
        for n in pairs(onlineStatus) do
            if not seen[n] then onlineStatus[n] = nil end
        end
    end

    raidScanFrame:Hide()

    raidScanFrame:SetScript("OnShow", function()
        mainTimer = INTERVAL
    end)

    -- Force an immediate full-roster queue rebuild (used on login/reload).
    function raidScanFrame:TriggerRebuild()
        if GetNumRaidMembers() == 0 then
            self:Hide()   -- not in a raid: nothing to scan, stay quiet
            return
        end
        LoadSnapshotOnce()   -- login/reload kickoff: seed the panel before the full rescan
        rebuildActive = false; rebuildTimer = 0
        currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
        local total = BuildFullQueue()
        mainTimer = INTERVAL
        if debugMode then Print("[RaidScan] Queue rebuilt: |cffffff00" .. total .. "|r member(s).") end
    end

    -- Stop scanning entirely: clear the queue + any in-progress inspection, drop results, hide.
    function raidScanFrame:Stop()
        raidScanData = {}; raidScanQueue = {}; raidScanFailed = {}; raidScanOOR = {}
        currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
        rebuildActive = false; rebuildTimer = 0
        fullScanInProgress = false; onlineStatus = {}
        snapshotLoadAttempted = false
        mainTimer = 0; inspectTimer = 0; connTimer = 0; oorTimer = 0
        self:Hide()
        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()
        end
    end

    -- [Debug] Drop the persisted snapshot AND the live in-memory scan results, then start a
    -- fresh rescan. Wiping raidScanData is essential: OnQueueDrained -> SaveRaidSnapshot would
    -- otherwise re-persist the still-loaded members on the next drain, so clearing only the DB
    -- lets a background scan resurrect the snapshot before the next /reload. Returns whether a
    -- snapshot actually existed. Used by /bis crs.
    function raidScanFrame:ClearSnapshot()
        local had = (BiSTrackerDB.raidSnapshot or BiSTrackerDB.msChanged or BiSTrackerDB.whisperOptOut) ~= nil
        -- Drop every restorable raid store, or LoadSnapshotOnce would resurrect MS-Changed /
        -- whisper opt-outs on the next raid even though the gear snapshot is gone.
        BiSTrackerDB.raidSnapshot  = nil
        BiSTrackerDB.msChanged     = nil
        BiSTrackerDB.whisperOptOut = nil
        raidScanData = {}; raidScanQueue = {}; raidScanFailed = {}; raidScanOOR = {}
        for k in pairs(raidMSChanged)  do raidMSChanged[k]  = nil end
        for k in pairs(noWhisperUsers) do noWhisperUsers[k] = nil end
        for k in pairs(whisperOn)      do whisperOn[k]      = nil end
        currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
        rebuildActive = false; rebuildTimer = 0
        fullScanInProgress = false; onlineStatus = {}
        snapshotLoadAttempted = true   -- snapshot is gone; don't try to restore one
        mainTimer = 0; inspectTimer = 0; connTimer = 0; oorTimer = 0
        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()
        end
        if LS().scanRaid and GetNumRaidMembers() > 0 then
            self:TriggerRebuild()   -- fresh full rescan; nothing to restore now
        else
            self:Hide()
        end
        return had
    end

    -- Called on RAID_ROSTER_UPDATE: detects joins and leaves incrementally.
    function raidScanFrame:HandleRosterUpdate()
        if not LS().scanRaid then return end
        if GetNumRaidMembers() == 0 then
            raidScanData = {}; raidScanQueue = {}; raidScanFailed = {}; raidScanOOR = {}
            currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
            rebuildActive = false; rebuildTimer = 0
            fullScanInProgress = false; onlineStatus = {}
            snapshotLoadAttempted = false   -- re-arm snapshot load for the next raid we join
            self:Hide()
            return
        end

        -- First roster update this session (or after leaving/rejoining) while in a raid:
        -- restore the last snapshot so the panel shows the full raid instantly, then run a
        -- normal full rescan in the background to refresh every member from scratch.
        if not snapshotLoadAttempted then
            if LoadSnapshotOnce() > 0 then
                self:TriggerRebuild()
                if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
                    BiSTracker_RefreshRaidList()
                end
                return
            end
        end

        local playerName = UnitName("player")
        local currentRoster = { [playerName] = { unitID="player", online=true } }
        for i = 1, GetNumRaidMembers() do
            local n, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
            if n then currentRoster[n] = { unitID="raid"..i, online=online } end
        end

        -- Remove players who left
        for name in pairs(raidScanData) do
            if not currentRoster[name] then
                raidScanData[name] = nil
                raidScanFailed[name] = nil
                local cancelled = RemoveFromQueue(name)   -- also unparks from raidScanOOR
                if cancelled and #raidScanQueue == 0 then
                    rebuildActive = true; rebuildTimer = 0
                end
                if debugMode then Print("[RaidScan] " .. name .. " left the raid, removed.") end
            end
        end

        -- Queue players who just joined (online only)
        for name, info in pairs(currentRoster) do
            -- Skip players with data, dropped ones ("Unable to scan" persists until the next full
            -- scan), and anyone already queued or parked (IsQueued covers the OOR parking).
            if not raidScanData[name] and not raidScanFailed[name] and not IsQueued(name) then
                if info.online then
                    EnqueuePlayer(name, info.unitID, name == playerName)
                    if debugMode then Print("[RaidScan] " .. name .. " joined, queued for scan.") end
                else
                    if debugMode then Print("[RaidScan] " .. name .. " joined but is offline, skipping.") end
                end
            end
        end

        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()
        end
    end

    raidScanFrame:SetScript("OnUpdate", function(self, elapsed)
        if not LS().scanRaid then self:Hide(); return end
        if GetNumRaidMembers() == 0 then self:Hide(); return end

        -- Poll connection changes (UNIT_CONNECTION doesn't exist in 3.3.5a)
        connTimer = connTimer + elapsed
        if connTimer >= CONN_POLL then
            connTimer = 0
            PollConnectionChanges()
        end

        -- Sweep the WHOLE out-of-range table every OOR_POLL (not per-entry): players back in
        -- inspect range jump to the front of the main queue, leavers are dropped, the rest stay
        -- parked. Runs even during an in-progress inspect; releases wait for it to finish.
        oorTimer = oorTimer + elapsed
        if oorTimer >= OOR_POLL then
            oorTimer = 0
            local refresh = false
            for name, e in pairs(raidScanOOR) do
                local online, unitID = false, nil
                for i = 1, GetNumRaidMembers() do
                    local n, _, _, _, _, _, _, onl = GetRaidRosterInfo(i)
                    if n == name then online = onl; unitID = "raid"..i; break end
                end
                if not unitID then
                    raidScanOOR[name] = nil   -- left the raid: drop
                    refresh = true
                    if debugMode then Print("[RaidScan] |cffffff00" .. name .. "|r left the raid, dropped from out-of-range list.") end
                elseif online and CanInspect(unitID) and CheckInteractDistance(unitID, 1) then
                    e.unitID = unitID
                    table.insert(raidScanQueue, 1, e)   -- back in range: next up
                    raidScanOOR[name] = nil
                    refresh = true
                    if currentUnit == nil then mainTimer = INTERVAL end   -- idle: inspect them right away
                    if debugMode then Print("[RaidScan] |cffffff00" .. name .. "|r back in inspect range, scanning next.") end
                end
                -- else: still out of range / offline -> stays parked
            end
            if refresh and mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
                BiSTracker_RefreshRaidList()
            end
        end

        -- Wait for in-progress inspection to finish
        if currentUnit then
            inspectTimer = inspectTimer + elapsed
            local isSelf = currentEntry and currentEntry.isSelf
            -- Talents count as loaded only when the buffer provably belongs to OUR target:
            -- READY fired for their GUID (no other addon's request overwrote it) and real
            -- points are readable. points>0 alone could be a stale/foreign buffer.
            local talentsLoaded = isSelf or (currentGUID ~= nil and talentsReadyGUID == currentGUID and InspectTalentPoints() > 0)
            if talentsLoaded or inspectTimer >= TALENT_TIMEOUT then
                inspectTimer = 0
                -- Re-resolve the unit by name before reading gear: positional raidN IDs can
                -- remap if the roster shifted during the inspect wait.
                if not isSelf then
                    for i = 1, GetNumRaidMembers() do
                        if GetRaidRosterInfo(i) == currentName then currentUnit = "raid"..i; break end
                    end
                end
                local gear = {}
                local slotCount = 0
                for _, slot in ipairs(GEAR_SLOTS) do
                    local link = GetInventoryItemLink(currentUnit, slot.id)
                    if link then
                        local iName = link:match("%[(.-)%]")
                        local _, _, quality, ilvl, _, _, subType, _, equipLoc = GetItemInfo(link)
                        if iName then
                            gear[slot.name] = { name=iName, ilvl=ilvl or 0, quality=quality, equipLoc=equipLoc, subType=subType }
                            slotCount = slotCount + 1
                        end
                    end
                end
                local classL
                if currentEntry and currentEntry.isSelf then
                    local _, cf = UnitClass("player"); classL = cf
                else
                    for i = 1, GetNumRaidMembers() do
                        local n, _, _, _, _, cl = GetRaidRosterInfo(i)
                        if n == currentName then classL = cl; break end
                    end
                end
                local spec = nil
                if isSelf then
                    spec = DetectSpec()
                elseif talentsLoaded then
                    -- Buffer ownership verified (READY for their GUID + points>0): this reads
                    -- THIS target's real data, not a stale/foreign buffer.
                    spec = DetectInspectSpec(classL)
                elseif debugMode then
                    Print("[SpecDetect] " .. (classL or "?") .. ": no owned talent data within " .. TALENT_TIMEOUT .. "s, retrying")
                end
                if not spec then
                    local charKey = currentName .. "-" .. GetRealmName()
                    if BiSTrackerDB.characters[charKey] then
                        spec = BiSTrackerDB.characters[charKey].activeSpec
                    end
                end

                if (slotCount == 0 or not spec) and not (currentEntry and currentEntry.isSelf) then
                    -- Inspect came back with no gear or no spec (talents didn't arrive): re-queue to the
                    -- END of the inspect queue and retry, up to MAX_REQUEUES. This is NOT the out-of-range
                    -- path (the pre-inspect range gate handles that); a player who keeps failing here
                    -- becomes "Unable to scan" and is dropped until the next full sweep re-attempts them.
                    if currentEntry then
                        currentEntry.requeues = (currentEntry.requeues or 0) + 1
                        if currentEntry.requeues < MAX_REQUEUES then
                            if debugMode then Print("[RaidScan] |cffffff00" .. currentName .. "|r incomplete (slots=" .. slotCount .. " spec=" .. tostring(spec) .. "), re-queuing (" .. currentEntry.requeues .. "/" .. MAX_REQUEUES .. ").") end
                            table.insert(raidScanQueue, currentEntry)
                        else
                            raidScanFailed[currentName] = true   -- dropped after retries: show "Unable to scan"
                            if debugMode then Print("[RaidScan] |cffffff00" .. currentName .. "|r still incomplete after " .. MAX_REQUEUES .. "x, dropping until next full scan.") end
                        end
                    end
                else
                    -- Annotate each gear item with bis/alt flags for this player's spec
                    local specBiS = spec and ClassesBiS and ClassesBiS[spec]
                    if specBiS then
                        for _, entry in ipairs(specBiS) do
                            local slotKey = Trim(entry.slot)
                            local gearSlots
                            if     slotKey == "Ring"    then gearSlots = { "Ring 1", "Ring 2" }
                            elseif slotKey == "Trinket" then gearSlots = { "Trinket 1", "Trinket 2" }
                            elseif slotKey == "Shield"  then gearSlots = { "Off Hand" }
                            elseif RANGED_SLOTS[slotKey] then gearSlots = { "Ranged" }
                            else                              gearSlots = { slotKey }
                            end
                            local function tryAnnotate(item, iName, iIlvl, flag)
                                if not item or not item.name or not iName then return end
                                if Trim(item.name) ~= Trim(iName) then return end
                                iIlvl = iIlvl or 0
                                local myIlvl = item.ilvl or 0
                                if iIlvl == 0 or myIlvl == 0 or myIlvl == iIlvl then item[flag] = true end
                            end
                            for _, gs in ipairs(gearSlots) do
                                local item = gear[gs]
                                if entry.bis then tryAnnotate(item, entry.bis.name, entry.bis.ilvl, "bis") end
                                if entry.alt then tryAnnotate(item, entry.alt.name, entry.alt.ilvl, "alt") end
                            end
                        end
                    end
                    raidScanData[currentName] = { spec=spec, class=classL, gear=gear }
                    raidScanFailed[currentName] = nil   -- scanned OK: clear any prior "Unable to scan"
                    raidScanOOR[currentName]    = nil   -- and any out-of-range parking
                    if debugMode then
                        local specStr  = spec and ("|cffaaaaaa" .. spec .. "|r") or ("|cff666666class:" .. (classL or "?") .. "|r")
                        local queueStr = #raidScanQueue > 0 and ("|cffaaaaaa" .. #raidScanQueue .. " left|r") or "|cff44ff44done|r"
                        Print("[RaidScan] |cffffff00" .. currentName .. "|r  spec=" .. specStr .. "  slots=" .. slotCount .. "  " .. queueStr)
                    end
                end

                currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
                mainTimer = 0

                if #raidScanQueue == 0 then
                    OnQueueDrained()
                end

                if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
                    BiSTracker_RefreshRaidList()
                end
            end
            return
        end

        -- 5-min countdown to the next full rebuild; runs alongside individual scans so a
        -- single joiner doesn't push the next full sweep back.
        if rebuildActive then
            rebuildTimer = rebuildTimer + elapsed
            if rebuildTimer >= REBUILD_INTERVAL and #raidScanQueue == 0 and currentUnit == nil then
                rebuildActive = false; rebuildTimer = 0
                local total = BuildFullQueue()
                mainTimer = INTERVAL
                if debugMode then Print("[RaidScan] 5-min timer elapsed. Rebuilding queue: |cffffff00" .. total .. "|r member(s).") end
                return
            end
        end

        -- Nothing queued: make sure the full-scan countdown is running, then idle.
        if #raidScanQueue == 0 then
            if not rebuildActive then rebuildActive = true; rebuildTimer = 0 end
            return
        end

        -- Advance the inter-inspection delay
        mainTimer = mainTimer + elapsed
        if mainTimer < INTERVAL then return end
        mainTimer = 0

        local entry = table.remove(raidScanQueue, 1)

        if not entry.isSelf then
            -- Re-resolve the unit by name: positional raidN IDs shift on every roster change,
            -- and this entry may have been queued minutes ago. Also picks up online state.
            local online, unitID = false, nil
            for i = 1, GetNumRaidMembers() do
                local n, _, _, _, _, _, _, onl = GetRaidRosterInfo(i)
                if n == entry.name then online = onl; unitID = "raid"..i; break end
            end
            if not unitID or not online then
                if debugMode then Print("[RaidScan] Skipping |cffffff00" .. entry.name .. "|r (" .. (unitID and "offline" or "left raid") .. ").") end
                if #raidScanQueue == 0 then
                    OnQueueDrained()      -- last entry was a skip: finish the queue properly
                else
                    mainTimer = INTERVAL  -- check next entry immediately
                end
                return
            end
            entry.unitID = unitID

            -- Range gate: the server only answers NotifyInspect within ~28 yd. Park the entry
            -- in the out-of-range table (swept as a whole every OOR_POLL) instead of burning
            -- main-queue retries; it jumps back to the queue front once in range.
            if not (CanInspect(unitID) and CheckInteractDistance(unitID, 1)) then
                raidScanOOR[entry.name] = entry
                if debugMode then Print("[RaidScan] |cffffff00" .. entry.name .. "|r out of inspect range, parked (re-checked every " .. OOR_POLL .. "s).") end
                if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
                    BiSTracker_RefreshRaidList()   -- show "Out of range, retrying..." right away
                end
                mainTimer = INTERVAL   -- nothing was sent: move on to the next player now
                if #raidScanQueue == 0 then OnQueueDrained() end
                return
            end
        end

        currentUnit  = entry.unitID
        currentName  = entry.name
        currentEntry = entry
        currentGUID  = nil
        if not entry.isSelf then currentGUID = UnitGUID(entry.unitID) end   -- whose talents we're asking for
        inspectTimer = 0
        if debugMode then Print("[RaidScan] Inspecting |cffffff00" .. currentName .. "|r (" .. entry.unitID .. ")...") end
        if not entry.isSelf then
            ClearInspectPlayer()   -- hygiene: drop the previous buffer (ownership is enforced via GUID anyway)
            NotifyInspect(entry.unitID)
        end
    end)
end
