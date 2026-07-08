-- ============================================================
-- LOOT SETTINGS + RAID SCAN
-- ============================================================

local lsWidgets          = {}
local lsRaidRowPool      = {}
local lsRaidDetailPanels = {}
local expandedRaidMembers = {}
local raidMSChanged      = {}   -- [playerName]=true: user flagged them as having changed Main Spec
local lsGeneralCollapsed  = false  -- General Settings section collapse state
local lsExportCollapsed   = false  -- Export Settings section collapse state
local lsAnnounceCollapsed = false  -- Announce Settings section collapse state
local raidScanData       = {}  -- [playerName] = { spec, class, gear={} }

-- De-dup cache for posted items (avoid reacting twice to the same repost).
local lastPostedItem = nil
local lastPostedTime = 0
local POST_CACHE_TTL = 120  -- seconds; a new item resets the window, same item is ignored within it

-- Announcer election / addon presence (session/raid state, never saved to DB).
local ADDON_PREFIX     = "BiSTracker"
local addonUsers       = {}    -- [playerName] = true: raid members confirmed running BiSTracker
local skipUsers        = {}    -- [playerName] = true: addon users who opted out of being announcer
local currentAnnouncer = nil   -- elected announcer name; only this player runs announce/inform

function LS()
    BiSTrackerDB.lootSettings = BiSTrackerDB.lootSettings or {}
    local ls = BiSTrackerDB.lootSettings
    if ls.reactTo         == nil then ls.reactTo         = "nothing"  end
    if ls.announceNone    == nil then ls.announceNone    = true       end
    if ls.announceBiS     == nil then ls.announceBiS     = false      end
    if ls.announceAlt     == nil then ls.announceAlt     = false      end
    if ls.announceChannel == nil then ls.announceChannel = "raidChat" end
    if ls.scanRaid        == nil then ls.scanRaid        = false      end
    if ls.informPlayers   == nil then ls.informPlayers   = false      end
    if ls.informChannel   == nil then ls.informChannel   = "whisper"  end
    if ls.notifyMySpec    == nil then ls.notifyMySpec    = false      end
    -- General settings (default to current/automatic behavior so existing users are unaffected)
    if ls.autoScanGear    == nil then ls.autoScanGear    = true       end
    if ls.autoScanLocks   == nil then ls.autoScanLocks   = true       end
    if ls.skipAnnouncer   == nil then ls.skipAnnouncer   = false      end
    if ls.minimapPopup    == nil then ls.minimapPopup    = true       end
    return ls
end

local function GetMLName()
    local method, partyIdx, raidIdx = GetLootMethod()
    if method ~= "master" then return nil end
    if partyIdx == 0 then return UnitName("player") end
    if raidIdx then return (GetRaidRosterInfo(raidIdx)) end
    return nil
end

-- True if the poster is Raid Lead / Assist (rank >= 1) or the Master Looter.
local function PosterIsOfficer(senderName)
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

-- ============================================================
-- ANNOUNCER ELECTION + ADDON PRESENCE
-- ============================================================
-- One member is elected to react/announce so multiple addon users don't all respond.
-- Hierarchy: Raid Lead > Master Looter (Assist+) > Assist; only BiSTracker users qualify.

-- Throttled outgoing addon-message queue (avoid burst -> server spam disconnect).
local outQueue   = {}
local OUT_INTERVAL = 0.3
local outAccum   = 0
local outFrame   = CreateFrame("Frame")
outFrame:Hide()
outFrame:SetScript("OnUpdate", function(self, elapsed)
    outAccum = outAccum + elapsed
    if outAccum < OUT_INTERVAL then return end
    outAccum = 0
    local m = table.remove(outQueue, 1)
    if m then SendAddonMessage(ADDON_PREFIX, m.msg, m.chan, m.target) end
    if #outQueue == 0 then self:Hide() end
end)
local function SendAddon(msg, target)
    table.insert(outQueue, { msg = msg, chan = target and "WHISPER" or "RAID", target = target })
    outFrame:Show()
end

-- Throttle for "who is the announcer?" requests (sent by newcomers on joining a raid).
local lastReqTime  = 0
local REQ_THROTTLE = 10

local function HasAddon(name)
    if name == UnitName("player") then return true end
    return addonUsers[name] == true
end

-- Opted out of being announcer: self reads the live setting, others from SKIP/HELLO.
local function SkipsAnnouncer(name)
    if name == UnitName("player") then return LS().skipAnnouncer and true or false end
    return skipUsers[name] == true
end

local function RankOf(name)
    for i = 1, GetNumRaidMembers() do
        local n, rank = GetRaidRosterInfo(i)
        if n == name then return rank end
    end
    return nil
end

local function IsOnline(name)
    for i = 1, GetNumRaidMembers() do
        local n, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
        if n == name then return online and true or false end
    end
    return false
end

-- Pick the announcer by hierarchy among online addon users.
local function ElectAnnouncer()
    if GetNumRaidMembers() == 0 then return nil end
    local rlName
    local assists = {}
    for i = 1, GetNumRaidMembers() do
        local name, rank, _, _, _, _, _, online = GetRaidRosterInfo(i)
        if name and online then
            if rank == 2 then rlName = name end
            if rank >= 1 and HasAddon(name) and not SkipsAnnouncer(name) then
                table.insert(assists, { name = name, idx = i })
            end
        end
    end
    -- 1) Raid Lead (if running the addon, not opted out)
    if rlName and HasAddon(rlName) and not SkipsAnnouncer(rlName) then return rlName end
    -- 2) Master Looter (if running the addon AND has Assist or Lead, not opted out)
    local ml = GetMLName()
    if ml and HasAddon(ml) and (RankOf(ml) or 0) >= 1 and not SkipsAnnouncer(ml) then return ml end
    -- 3) any Assist with the addon (lowest raid index)
    table.sort(assists, function(a, b) return a.idx < b.idx end)
    if assists[1] then return assists[1].name end
    return nil
end

-- True if candidate `a` outranks `b` by ElectAnnouncer's hierarchy (rank/ML/roster index
-- only — values every client shares), so it can validate an ANN from a just-joined member.
local function AnnouncerBeats(a, b)
    local function priority(name)
        local rank = RankOf(name)
        if not rank then return -1 end             -- not in the raid
        if rank == 2 then return 3 end             -- Raid Lead
        if name == GetMLName() and rank >= 1 then return 2 end  -- Master Looter w/ assist+
        if rank >= 1 then return 1 end             -- Assist
        return 0                                    -- regular member
    end
    local pa, pb = priority(a), priority(b)
    if pa ~= pb then return pa > pb end
    -- Same tier (e.g. two assists): lower raid index wins, matching ElectAnnouncer.
    local ia, ib
    for i = 1, GetNumRaidMembers() do
        local n = GetRaidRosterInfo(i)
        if n == a then ia = i end
        if n == b then ib = i end
    end
    return (ia and ib and ia < ib) or false
end

local function UpdateAnnouncerUI()
    if lsWidgets.announcerLbl then
        lsWidgets.announcerLbl:SetText(
            COLOR.legendary .. "Current selected Announcer for this Raid:|r "
            .. (currentAnnouncer and (COLOR.white .. currentAnnouncer .. "|r")
                                  or  (COLOR.grey .. "None|r")))
    end
end

local function SetAnnouncer(name)
    if currentAnnouncer ~= name then
        currentAnnouncer = name
        if debugMode then
            Print("[Announcer] A new announcer for this Raid got selected: |cffffffff" .. (name or "None") .. "|r")
        end
    end
    UpdateAnnouncerUI()
end

-- Run the election; if I'm the winner, broadcast it so everyone else stands down.
function BiSTracker_RefreshAnnouncer()
    local elected = ElectAnnouncer()
    SetAnnouncer(elected)
    if elected and elected == UnitName("player") and GetNumRaidMembers() > 0 then
        SendAddon("ANN:" .. elected)
    end
end

-- Called 4s after entering world: advertise presence (SKIP if opted out, else HELLO) and elect.
function BiSTracker_AnnouncerInit()
    addonUsers[UnitName("player")] = true
    if GetNumRaidMembers() > 0 then
        SendAddon(LS().skipAnnouncer and "SKIP" or "HELLO")
    end
    BiSTracker_RefreshAnnouncer()
end

-- Incoming addon traffic (prefix-filtered in the event handler caller).
function BiSTracker_OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= ADDON_PREFIX or not msg or not sender or sender == "" then return end
    local newUser = (addonUsers[sender] == nil) and (sender ~= UnitName("player"))
    addonUsers[sender] = true

    if msg == "HELLO" then
        skipUsers[sender] = nil             -- they're an active candidate again
        if newUser then
            SendAddon(LS().skipAnnouncer and "SKIP" or "HELLO", sender)  -- directed reply: my candidacy status
            BiSTracker_RefreshAnnouncer()   -- re-elect; broadcasts ANN to the whole raid if I win (newcomer included)
        end
    elseif msg == "SKIP" then
        -- Sender opted out: record and re-elect (a new winner re-broadcasts ANN).
        skipUsers[sender] = true
        BiSTracker_RefreshAnnouncer()
    elseif msg:sub(1, 4) == "ANN:" then
        local name = msg:sub(5)
        if name ~= "" then
            addonUsers[name] = true
            -- Don't blindly trust a just-joined member's claim: if our election names a
            -- more authoritative announcer, re-assert it (re-broadcasts ANN only if it's us).
            local mine = ElectAnnouncer()
            if mine and mine ~= name and AnnouncerBeats(mine, name) then
                BiSTracker_RefreshAnnouncer()
            else
                SetAnnouncer(name)
            end
        end
    elseif msg == "REQ" then
        -- Newcomer asking who the announcer is; only the announcer answers (whole raid re-syncs).
        if currentAnnouncer == UnitName("player") then
            SendAddon("ANN:" .. currentAnnouncer)
        end
    end
end

-- On roster change: prune leavers, then re-elect only if the announcer is gone or lost rights.
function BiSTracker_AnnouncerOnRoster()
    if GetNumRaidMembers() == 0 then
        for k in pairs(addonUsers) do addonUsers[k] = nil end
        for k in pairs(skipUsers)  do skipUsers[k]  = nil end
        addonUsers[UnitName("player")] = true
        SetAnnouncer(nil)
        return
    end
    local inRaid = {}
    for i = 1, GetNumRaidMembers() do
        local n = GetRaidRosterInfo(i)
        if n then inRaid[n] = true end
    end
    for name in pairs(addonUsers) do
        if name ~= UnitName("player") and not inRaid[name] then addonUsers[name] = nil end
    end
    for name in pairs(skipUsers) do
        if not inRaid[name] then skipUsers[name] = nil end
    end
    local valid = currentAnnouncer and IsOnline(currentAnnouncer)
              and (RankOf(currentAnnouncer) or -1) >= 1
              and HasAddon(currentAnnouncer)
              and not SkipsAnnouncer(currentAnnouncer)
    if not valid then BiSTracker_RefreshAnnouncer() end

    -- Just joined / don't know the announcer yet: ask. Only the announcer replies.
    if currentAnnouncer == nil then
        local now = GetTime()
        if now - lastReqTime >= REQ_THROTTLE then
            lastReqTime = now
            SendAddon("REQ")
        end
    end
end

local function LookupItemInBiS(itemName)
    -- Returns { [specName] = { {slotName, alt, bisName, bisIlvl, altName, altIlvl}, ... } }
    local results = {}
    if not ClassesBiS then return results end
    local needle = Trim(itemName)
    for specName, specData in pairs(ClassesBiS) do
        for _, entry in ipairs(specData) do
            local isBiS = entry.bis and Trim(entry.bis.name) == needle
            local isAlt = entry.alt and Trim(entry.alt.name) == needle
            if isBiS or isAlt then
                results[specName] = results[specName] or {}
                table.insert(results[specName], {
                    slotName = entry.slot,
                    alt      = isAlt and not isBiS,
                    bisName  = entry.bis and entry.bis.name,
                    bisIlvl  = entry.bis and entry.bis.ilvl,
                    altName  = entry.alt and entry.alt.name,
                    altIlvl  = entry.alt and entry.alt.ilvl,
                })
            end
        end
    end
    return results
end

local function SendInChannel(msg, channel)
    if     channel == "say"         then SendChatMessage(msg, "SAY")
    elseif channel == "raidChat"    then SendChatMessage(msg, "RAID")
    elseif channel == "raidWarning" then SendChatMessage(msg, "RAID_WARNING")
    end
end

-- Personal upgrade label for a posted item vs my gear: "BiS"|"Alt BiS"|"pre-BiS"|
-- "Alt pre-BiS", or nil if not an upgrade. bisEntries = bisResults[mySpec].
local function GetNotifyUpgradeType(bisEntries, myGear, itemName, postedIlvl)
    local needle = Trim(itemName)

    local function slotItems(slotName)
        if slotName == "Ring"    then return myGear["Ring 1"],    myGear["Ring 2"]    end
        if slotName == "Trinket" then return myGear["Trinket 1"], myGear["Trinket 2"] end
        return myGear[slotName]
    end
    -- Item the posted one would replace: empty slot wins (nil), else the weaker ring/trinket.
    local function replaceTarget(a, b, twoSlot)
        if twoSlot then
            if not a or not b then return nil end
            return (a.ilvl <= b.ilvl) and a or b
        end
        return a
    end
    local function ownsPosted(it)
        return it and Trim(it.name) == needle and (postedIlvl == 0 or it.ilvl == postedIlvl)
    end

    local rank = { ["BiS"] = 4, ["Alt BiS"] = 3, ["pre-BiS"] = 2, ["Alt pre-BiS"] = 1 }
    local best, bestRank = nil, 0

    for _, e in ipairs(bisEntries) do
        local twoSlot = (e.slotName == "Ring" or e.slotName == "Trinket")
        local a, b    = slotItems(e.slotName)
        local eq      = replaceTarget(a, b, twoSlot)

        -- Cancel: I already own the posted item at the same ilvl.
        local alreadyHave = ownsPosted(a) or (twoSlot and ownsPosted(b))

        -- Cancel: my comparison item is already the BiS for this slot.
        local eqIsBis = eq and e.bisName and Trim(eq.name) == Trim(e.bisName)
                        and (not e.bisIlvl or e.bisIlvl == 0 or eq.ilvl >= e.bisIlvl)

        if not alreadyHave and not eqIsBis then
            local isBisName = e.bisName and needle == Trim(e.bisName)
            local isAltName = e.altName and needle == Trim(e.altName)

            local label, matchName, effIlvl
            if isBisName then
                matchName = Trim(e.bisName)
                effIlvl   = (postedIlvl > 0) and postedIlvl or (e.bisIlvl or 0)
                if e.bisIlvl and e.bisIlvl > 0 and effIlvl < e.bisIlvl then
                    label = "pre-BiS"
                else
                    label = "BiS"
                end
            elseif isAltName then
                matchName = Trim(e.altName)
                effIlvl   = (postedIlvl > 0) and postedIlvl or (e.altIlvl or 0)
                if e.altIlvl and e.altIlvl > 0 and effIlvl < e.altIlvl then
                    label = "Alt pre-BiS"
                else
                    label = "Alt BiS"
                end
            end

            if label then
                -- Upgrade if nothing equipped, a different item, or a lower-ilvl item.
                local upgrade = (not eq)
                    or (Trim(eq.name) ~= matchName)
                    or (eq.ilvl < effIlvl)
                if upgrade and rank[label] > bestRank then
                    best, bestRank = label, rank[label]
                end
            end
        end
    end

    return best
end

-- "a BiS upgrade" / "an Alt BiS upgrade" / "a pre-BiS upgrade" / "an Alt pre-BiS upgrade"
local function UpgradePhrase(label)
    return ((label:sub(1, 3) == "Alt") and "an " or "a ") .. label .. " upgrade"
end

function HandlePostedItem(sender, message)
    local ls = LS()

    -- Capture the FULL link (colour wrapper + |r); SendChatMessage rejects a bare relink.
    local itemLink = message:match("|c%x+|Hitem:.-|h%[.-%]|h|r")
    if not itemLink then return end
    local itemName = itemLink:match("%[(.-)%]")
    if not itemName then return end
    local postedIlvl = select(4, GetItemInfo(itemLink)) or 0

    local bisResults = LookupItemInBiS(itemName)
    if not next(bisResults) then return end

    -- De-dup: ignore the same item reposted within POST_CACHE_TTL; a new item resets the window.
    local now = GetTime()
    if lastPostedItem and (now - lastPostedTime) >= POST_CACHE_TTL then
        lastPostedItem = nil
    end
    if lastPostedItem == itemName then return end
    lastPostedItem = itemName
    lastPostedTime = now

    -- Always-notify-self: independent of announcer role, but only for officer posters.
    if ls.notifyMySpec then
        if PosterIsOfficer(sender) then
            local myKey  = GetCharKey()
            local myChar = BiSTrackerDB.characters[myKey]
            local mySpec = myChar and myChar.activeSpec
            if mySpec and bisResults[mySpec] then
                local myGear      = GetActiveGear(myChar)
                local upgradeType = GetNotifyUpgradeType(bisResults[mySpec], myGear, itemName, postedIlvl)
                if upgradeType then
                    Print(itemLink .. " is a " .. upgradeType .. " upgrade for you!")
                end
            end
        end
    end

    -- Opted out ("Never be Announcer"): never react, even when no one is elected.
    if LS().skipAnnouncer then return end
    -- Otherwise only the elected announcer reacts (so addon users don't all respond).
    if currentAnnouncer and currentAnnouncer ~= UnitName("player") then return end

    -- Announce + Inform: react only to officer-posted loot (the announcer handles "who").
    if ls.reactTo == "nothing"     then return end
    if not PosterIsOfficer(sender) then return end

    -- Announce
    if not ls.announceNone and (ls.announceBiS or ls.announceAlt) then
        local seenBiS, seenAlt = {}, {}
        local bisSpecs, altSpecs = {}, {}
        for specName, entries in pairs(bisResults) do
            for _, e in ipairs(entries) do
                if not e.alt and ls.announceBiS and not seenBiS[specName] then
                    seenBiS[specName] = true; table.insert(bisSpecs, specName)
                elseif e.alt and ls.announceAlt and not seenAlt[specName] then
                    seenAlt[specName] = true; table.insert(altSpecs, specName)
                end
            end
        end
        if #bisSpecs > 0 or #altSpecs > 0 then
            table.sort(bisSpecs); table.sort(altSpecs)
            local parts = {}
            if #bisSpecs > 0 then table.insert(parts, "BiS for " .. table.concat(bisSpecs, ", ")) end
            if #altSpecs > 0 then table.insert(parts, "Alternative for " .. table.concat(altSpecs, ", ")) end
            SendInChannel(itemLink .. " is " .. table.concat(parts, ". ") .. ".", ls.announceChannel)
        end
    end

    -- Inform players: same BiS/Alt/pre-BiS/Alt pre-BiS logic as "always notify me".
    if not ls.informPlayers then return end
    for playerName, scanEntry in pairs(raidScanData) do
        local spec = scanEntry.spec
        -- Skip players flagged "MS Changed": their scanned gear no longer matches their spec's BiS.
        if spec and bisResults[spec] and not raidMSChanged[playerName] then
            local label = GetNotifyUpgradeType(bisResults[spec], scanEntry.gear, itemName, postedIlvl)
            if label then
                local msg = itemLink .. " is " .. UpgradePhrase(label) .. " for you."
                if ls.informChannel == "whisper" then
                    SendChatMessage(msg, "WHISPER", nil, playerName)
                else
                    SendInChannel(playerName .. " " .. msg, ls.informChannel)
                end
            end
        end
    end
end

function LootSettings_SyncUI()
    if not lsWidgets.cbReactNone then return end
    local ls = LS()
    if lsWidgets.cbNotifySelf    then lsWidgets.cbNotifySelf:SetChecked(ls.notifyMySpec)     end
    if lsWidgets.cbAutoScanGear  then lsWidgets.cbAutoScanGear:SetChecked(ls.autoScanGear)   end
    if lsWidgets.cbAutoScanLocks then lsWidgets.cbAutoScanLocks:SetChecked(ls.autoScanLocks) end
    if lsWidgets.cbSkipAnnouncer then lsWidgets.cbSkipAnnouncer:SetChecked(ls.skipAnnouncer) end
    if lsWidgets.cbMinimapPopup  then lsWidgets.cbMinimapPopup:SetChecked(ls.minimapPopup)   end
    if lsWidgets.aliasBox        then lsWidgets.aliasBox:SetText(BiSTrackerDB.accountAlias or "") end
    lsWidgets.cbReactNone:SetChecked(  ls.reactTo == "nothing")
    lsWidgets.cbReactRC:SetChecked(    ls.reactTo == "raidChat")
    lsWidgets.cbReactRW:SetChecked(    ls.reactTo == "raidWarning")
    lsWidgets.cbAnnNone:SetChecked(    ls.announceNone)
    lsWidgets.cbAnnBiS:SetChecked(     ls.announceBiS)
    lsWidgets.cbAnnAlt:SetChecked(     ls.announceAlt)
    lsWidgets.cbAnnSay:SetChecked(     ls.announceChannel == "say")
    lsWidgets.cbAnnRC:SetChecked(      ls.announceChannel == "raidChat")
    lsWidgets.cbAnnRW:SetChecked(      ls.announceChannel == "raidWarning")
    lsWidgets.cbScan:SetChecked(       ls.scanRaid)
    lsWidgets.cbInform:SetChecked(     ls.informPlayers)
    lsWidgets.cbInfWh:SetChecked(      ls.informChannel == "whisper")
    lsWidgets.cbInfSay:SetChecked(     ls.informChannel == "say")
    lsWidgets.cbInfRC:SetChecked(      ls.informChannel == "raidChat")
    UpdateAnnouncerUI()
    if lsWidgets.updateLayout then lsWidgets.updateLayout() end
end

local function GetOrCreateRaidDetailPanel(playerName)
    if lsRaidDetailPanels[playerName] then return lsRaidDetailPanels[playerName] end
    local mlContent = mainFrame and mainFrame.mlContent
    if not mlContent then return nil end
    local panel = CreateFrame("Frame", nil, mlContent)
    panel:SetWidth(626); panel:SetHeight(1)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, 0)
    bg:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 2, 0)   -- extend 2px past the right edge
    bg:SetTexture(0.05, 0.05, 0.05, 0.72)
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetWidth(1)
    sep:SetPoint("TOPLEFT", panel, "TOPLEFT", DETAIL_COL_X[2] - 6, -3)
    sep:SetTexture(0.35, 0.35, 0.35, 1)
    panel.sep = sep
    panel.lines = {}
    for c = 1, 2 do
        panel.lines[c] = {}
        for r = 1, DETAIL_MAX_LINES[c] do
            local indic = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            indic:Hide()
            local nameLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameLbl:SetJustifyH("LEFT"); nameLbl:Hide()
            panel.lines[c][r] = { indic=indic, name=nameLbl }
        end
    end
    lsRaidDetailPanels[playerName] = panel
    return panel
end

local function UpdateRaidDetailPanel(panel, scanEntry)
    for c = 1, 2 do
        for r = 1, DETAIL_MAX_LINES[c] do
            panel.lines[c][r].indic:Hide()
            panel.lines[c][r].name:Hide()
        end
    end

    local specName = scanEntry.spec
    local specData = specName and ClassesBiS and ClassesBiS[specName]
    local gear     = scanEntry.gear or {}

    -- Find the BiS entry for a given gear slot name
    local function FindBisEntry(gearSlot)
        if not specData then return nil end
        for _, entry in ipairs(specData) do
            local s = Trim(entry.slot)
            if s == gearSlot then return entry
            elseif s == "Ring"    and (gearSlot == "Ring 1" or gearSlot == "Ring 2")       then return entry
            elseif s == "Trinket" and (gearSlot == "Trinket 1" or gearSlot == "Trinket 2") then return entry
            elseif s == "Shield"  and gearSlot == "Off Hand"                               then return entry
            elseif RANGED_SLOTS[s] and gearSlot == "Ranged"                                then return entry
            end
        end
        return nil
    end

    -- Return the color for one item vs one BiS entry (nil-safe)
    local function ItemColor(item, bisEntry)
        if not item or not item.name or not bisEntry then return COLOR.white end
        local name = Trim(item.name)
        local ilvl = item.ilvl or 0
        local function check(bName, bIlvl)
            if not bName or Trim(bName) ~= name then return nil end
            bIlvl = bIlvl or 0
            if bIlvl == 0 or ilvl == 0 or ilvl == bIlvl then return COLOR.green end
            return COLOR.lorange
        end
        return check(bisEntry.bis and bisEntry.bis.name, bisEntry.bis and bisEntry.bis.ilvl)
            or check(bisEntry.alt and bisEntry.alt.name, bisEntry.alt and bisEntry.alt.ilvl)
            or COLOR.white
    end

    -- Check one item against ALL BiS entries for that slot type (handles multiple ring/trinket entries)
    local function SlotColor(gearSlot)
        local bisSlot
        if gearSlot == "Ring 1"    or gearSlot == "Ring 2"    then bisSlot = "Ring"
        elseif gearSlot == "Trinket 1" or gearSlot == "Trinket 2" then bisSlot = "Trinket"
        end
        if bisSlot then
            if not specData then return COLOR.white end
            local item = gear[gearSlot]
            local best = COLOR.white
            for _, entry in ipairs(specData) do
                if Trim(entry.slot) == bisSlot then
                    local c = ItemColor(item, entry)
                    if c == COLOR.green   then return COLOR.green end
                    if c == COLOR.lorange then best = COLOR.lorange end
                end
            end
            return best
        end
        return ItemColor(gear[gearSlot], FindBisEntry(gearSlot))
    end

    -- Ranged/relic slot: show the specific type (Sigil, Wand, Bow, ...) from the item subclass.
    local RANGED_LABEL = {
        sigil="Sigil", sigils="Sigil", libram="Libram", librams="Libram",
        idol="Idol", idols="Idol", totem="Totem", totems="Totem",
        wand="Wand", wands="Wand", bow="Bow", bows="Bow", gun="Gun", guns="Gun",
        crossbow="Crossbow", crossbows="Crossbow", thrown="Thrown",
    }
    local function RangedLabel(item)
        local st = item and item.subType
        return (st and RANGED_LABEL[st:lower()]) or "Ranged"
    end

    -- Write one equipped item line; skips if slot is empty
    local COL_W = { DETAIL_COL_X[2] - DETAIL_COL_X[1] - 8, 626 - DETAIL_COL_X[2] - 8 }
    local function WriteItem(c, lineIdx, yOff, gearSlot, label)
        local item = gear[gearSlot]
        if not item or not item.name then return lineIdx, yOff end
        if gearSlot == "Ranged" then label = RangedLabel(item) end
        lineIdx = lineIdx + 1
        if lineIdx > DETAIL_MAX_LINES[c] then return lineIdx, yOff end
        local row = panel.lines[c][lineIdx]
        row.indic:Hide()
        row.name:ClearAllPoints()
        row.name:SetPoint("TOPLEFT", panel, "TOPLEFT", DETAIL_COL_X[c], yOff)
        row.name:SetWidth(COL_W[c])
        local col    = SlotColor(gearSlot)
        local ilvlStr = (item.ilvl and item.ilvl > 0) and " (" .. item.ilvl .. ")" or ""
        local prefix  = (item.alt and not item.bis) and (COLOR.blue .. "(Alt)|r ") or ""
        row.name:SetText("|cffaaaaaa[" .. label .. "]|r " .. prefix .. col .. item.name .. ilvlStr .. "|r")
        row.name:Show()
        yOff = yOff - DETAIL_LINE_H
        return lineIdx, yOff
    end

    -- Slot order matches the two-column layout of the main window
    local COL1_GEAR = {
        { "Main Hand",  "Main Hand"  },
        { "Off Hand",   "Off Hand"   },
        { "Ranged",     "Ranged"     },
        { false,        false        },   -- blank spacer between weapons and armor
        { "Head",       "Head"       },
        { "Neck",       "Neck"       },
        { "Shoulders",  "Shoulders"  },
        { "Back",       "Back"       },
        { "Chest",      "Chest"      },
        { "Wrist",      "Wrist"      },
    }
    local COL2_GEAR = {
        { "Hands",      "Hands"      },
        { "Waist",      "Waist"      },
        { "Legs",       "Legs"       },
        { "Feet",       "Feet"       },
        { "Ring 1",     "Ring 1"     },
        { "Ring 2",     "Ring 2"     },
        { "Trinket 1",  "Trinket 1"  },
        { "Trinket 2",  "Trinket 2"  },
    }

    local colHeights = { 0, 0 }
    do
        local lineIdx, yOff = 0, -4
        for _, s in ipairs(COL1_GEAR) do
            if not s[1] then
                if lineIdx > 0 then yOff = yOff - DETAIL_LINE_H end   -- blank spacer row (only after real rows)
            else
                lineIdx, yOff = WriteItem(1, lineIdx, yOff, s[1], s[2])
            end
        end
        colHeights[1] = math.abs(yOff) + 6
    end
    do
        local lineIdx, yOff = 0, -4
        for _, s in ipairs(COL2_GEAR) do lineIdx, yOff = WriteItem(2, lineIdx, yOff, s[1], s[2]) end
        colHeights[2] = math.abs(yOff) + 6
    end

    local panelH = math.max(colHeights[1], colHeights[2], 20)
    panel:SetHeight(panelH)
    panel.sep:SetHeight(panelH - 6)
end

function BiSTracker_RefreshRaidList()
    local mlContent = mainFrame and mainFrame.mlContent
    if not mlContent or not mlContent.raidListY then return end
    local startY = mlContent.raidListY

    for _, row   in ipairs(lsRaidRowPool)          do row:Hide()   end
    for _, panel in pairs(lsRaidDetailPanels)      do panel:Hide() end
    if mlContent.emptyRaidRow then mlContent.emptyRaidRow:Hide() end

    local members = {}
    for i = 1, GetNumRaidMembers() do
        local n, _, _, _, _, classL, _, online = GetRaidRosterInfo(i)
        if n then table.insert(members, { name=n, class=classL, online=online }) end
    end
    table.sort(members, function(a, b) return (a.name or "") < (b.name or "") end)

    local cumY  = 0  -- cumulative height used (positive, subtracted from startY)
    local rowIdx = 0
    for _, m in ipairs(members) do
        rowIdx = rowIdx + 1
        local row = lsRaidRowPool[rowIdx]
        if not row then
            row = CreateFrame("Frame", nil, mlContent)
            row:SetHeight(ROW_H); row:SetWidth(626)
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetPoint("TOPLEFT",     row, "TOPLEFT",     0, 0)
            bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 2, 0)   -- extend 2px past the right edge
            bg:SetTexture(0, 0, 0, (rowIdx % 2 == 0) and 0.2 or 0.08)
            row.nameLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.nameLbl:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.nameLbl:SetWidth(150); row.nameLbl:SetJustifyH("LEFT")
            row.specLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.specLbl:SetPoint("LEFT", row, "LEFT", 150, 0)
            row.specLbl:SetWidth(150); row.specLbl:SetJustifyH("LEFT")
            row.msCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.msCheck:SetWidth(18); row.msCheck:SetHeight(18)
            row.msCheck:ClearAllPoints()
            row.msCheck:SetPoint("CENTER", row, "LEFT", 320, 0)   -- centered under "MS Changed*" header
            row.bisLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.bisLbl:SetPoint("LEFT", row, "LEFT", 390, 0)
            row.bisLbl:SetWidth(90); row.bisLbl:SetJustifyH("CENTER")
            row.gsLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.gsLbl:SetPoint("LEFT", row, "LEFT", 493, 0)
            row.gsLbl:SetWidth(90); row.gsLbl:SetJustifyH("CENTER")
            row.toggleBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.toggleBtn:SetWidth(26); row.toggleBtn:SetHeight(18)
            row.toggleBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            lsRaidRowPool[rowIdx] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", mlContent, "TOPLEFT", 0, startY - cumY)
        row:Show()
        cumY = cumY + ROW_H

        local classColor = ClassColorHex(m.class)
        if m.online then
            row.nameLbl:SetText("|cff" .. classColor .. (m.name or "?") .. "|r")
        else
            row.nameLbl:SetText("|cff666666" .. (m.name or "?") .. "|r")
        end

        -- MS Changed checkbox: one per player, state kept for the session (unchecked by default).
        local msName = m.name
        row.msCheck:SetChecked(raidMSChanged[msName] and true or false)
        row.msCheck:SetScript("OnClick", function(self)
            raidMSChanged[msName] = self:GetChecked() and true or false
        end)
        row.msCheck:Show()

        local scanEntry = raidScanData[m.name]
        if scanEntry then
            row.specLbl:SetText("|cffaaaaaa" .. (scanEntry.spec or scanEntry.class or "?") .. "|r")
            local spec     = scanEntry.spec
            local specData = spec and ClassesBiS and ClassesBiS[spec]
            if specData then
                local total, has = 0, 0
                for _, entry in ipairs(specData) do
                    total = total + 1
                    local slotN = Trim(entry.slot)
                    local bisS  = entry.bis and CheckItemStatus(scanEntry.gear, slotN, Trim(entry.bis.name), entry.bis.ilvl)
                    local altS  = entry.alt and CheckItemStatus(scanEntry.gear, slotN, Trim(entry.alt.name), entry.alt.ilvl)
                    if bisS == "exact" or altS == "exact" then has = has + 1 end
                end
                row.bisLbl:SetText(FormatBiSScore(has, total))
            else
                row.bisLbl:SetText("|cffaaaaaa-|r")
            end

            -- GearScore (own=false: scores the scanned gear with class/spec adjustments)
            local gs = ComputeGearScore(false, scanEntry.class, spec, scanEntry.gear)
            if gs and gs > 0 then
                row.gsLbl:SetText("|cff" .. GetGearScoreColor(gs) .. gs .. "|r")
            else
                row.gsLbl:SetText("|cff666666-|r")
            end

            -- Toggle button: only meaningful when we have scan data
            local isExpanded  = expandedRaidMembers[m.name]
            local capturedName = m.name
            row.toggleBtn:SetText(isExpanded and "^" or "v")
            row.toggleBtn:Show()
            row.toggleBtn:SetScript("OnClick", function()
                expandedRaidMembers[capturedName] = not expandedRaidMembers[capturedName]
                BiSTracker_RefreshRaidList()
            end)

            if isExpanded then
                local panel = GetOrCreateRaidDetailPanel(m.name)
                if panel then
                    UpdateRaidDetailPanel(panel, scanEntry)
                    panel:ClearAllPoints()
                    panel:SetPoint("TOPLEFT", mlContent, "TOPLEFT", 0, startY - cumY)
                    panel:Show()
                    cumY = cumY + panel:GetHeight()
                end
            end
        else
            row.specLbl:SetText(LS().scanRaid and "|cff666666Scanning...|r" or "|cff666666Not scanned|r")
            row.bisLbl:SetText("|cffaaaaaa-|r")
            row.gsLbl:SetText("|cff666666-|r")
            row.toggleBtn:Hide()
        end
    end

    if rowIdx == 0 then
        -- Dedicated frame (not a pool slot) so reused member rows never inherit this
        -- stripped layout that lacks a toggleBtn.
        local row = mlContent.emptyRaidRow
        if not row then
            row = CreateFrame("Frame", nil, mlContent)
            row:SetHeight(ROW_H); row:SetWidth(626)
            row.nameLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.nameLbl:SetPoint("LEFT", row, "LEFT", 8, 0); row.nameLbl:SetWidth(200)
            mlContent.emptyRaidRow = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", mlContent, "TOPLEFT", 0, startY)
        row:Show()
        row.nameLbl:SetText("|cffaaaaaa Not in a raid.|r")
        cumY = ROW_H
    end

    -- Grey note under the list explaining the MS Changed* column.
    local note = mlContent.raidNote
    if not note then
        note = mlContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        note:SetWidth(600); note:SetJustifyH("LEFT")
        note:SetText(COLOR.grey .. "* If players changed MS the Addon will not compare posted items to their gear and not inform them for possible upgrades since their spec doesn't match desired items.|r")
        local nf, _, nfl = note:GetFont()
        if nf then note:SetFont(nf, 9, nfl) end   -- smaller than GameFontNormalSmall
        mlContent.raidNote = note
    end
    note:ClearAllPoints()
    note:SetPoint("TOPLEFT", mlContent, "TOPLEFT", 8, startY - cumY - 8)
    note:Show()
    cumY = cumY + math.max(note:GetStringHeight(), 48) + 14

    mlContent:SetHeight(math.abs(startY) + cumY + 20)
end

function BuildLootSettingsUI(c)
    local HEADER_H   = 22
    local GEN_BODY_H = 160   -- General Settings body height (incl. empty row after notify + trailing empty row)
    local BODY_H     = 312   -- Announce Settings body height
    local RAID_H     = 44

    -- Generic builders, bound to an explicit parent frame (two collapsible bodies exist).
    local function MakeSep(parent, y)
        local line = parent:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("TOPLEFT",  parent, "TOPLEFT",   5, y)
        line:SetPoint("TOPRIGHT", parent, "TOPRIGHT",  -5, y)
        line:SetTexture(0.3, 0.3, 0.3, 0.8)
    end
    local function CB(parent, x, y)
        local btn = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        btn:SetWidth(16); btn:SetHeight(16)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        return btn
    end
    local function FS(parent, x, y, text)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        fs:SetText(text)
        return fs
    end
    -- Section header bar (bg + title + collapse button); returns the frame and its button.
    local function MakeHeader(title)
        local hf = CreateFrame("Frame", nil, c)
        hf:SetWidth(636); hf:SetHeight(HEADER_H)
        local bg = hf:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetTexture(0.2, 0.2, 0.2, 0.9)
        local lbl = hf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOP", hf, "TOP", 0, -5)
        lbl:SetText(COLOR.legendary .. title .. "|r")
        local btn = CreateFrame("Button", nil, hf, "UIPanelButtonTemplate")
        btn:SetWidth(26); btn:SetHeight(18)
        btn:SetPoint("TOPRIGHT", hf, "TOPRIGHT", -20, -2)
        return hf, btn
    end

    -- ============ General Settings ============
    local genHeader, genCollapseBtn = MakeHeader("General Settings")
    local genBody = CreateFrame("Frame", nil, c)
    genBody:SetWidth(636); genBody:SetHeight(GEN_BODY_H)

    local cbNotifySelf = CB(genBody, 10, -8)
    FS(genBody, 28, -8, COLOR.lorange .. "Always notify me if a posted item is an upgrade for my current spec/gear|r")

    -- empty row after "Always notify me..." before the scan toggles
    local cbAutoScanGear = CB(genBody, 10, -52)
    FS(genBody, 28,  -52, COLOR.white .. " Auto-Scan Gear|r")
    FS(genBody, 190, -52, COLOR.grey .. "(If disabled you need to manually use /bis scan)|r")

    local cbAutoScanLocks = CB(genBody, 10, -74)
    FS(genBody, 28,  -74, COLOR.white .. " Auto-Scan Instance Locks|r")
    FS(genBody, 190, -74, COLOR.grey .. "(If disabled you need to manually use /bis locks)|r")

    local cbMinimapPopup = CB(genBody, 10, -96)
    FS(genBody, 28,  -96, COLOR.white .. " Minimap Popup|r")
    FS(genBody, 190, -96, COLOR.grey .. "(If disabled, hovering the minimap icon wont show your characters instance locks)|r")

    local cbSkipAnnouncer = CB(genBody, 10, -118)
    FS(genBody, 28,  -118, COLOR.white .. " Never be Announcer|r")
    FS(genBody, 190, -118, COLOR.grey .. "(If enabled, you can never be the announcer of the raid)|r")

    -- ============ Export Settings ============
    local EXP_BODY_H = 150
    local expHeader, expCollapseBtn = MakeHeader("Export Settings")
    local expBody = CreateFrame("Frame", nil, c)
    expBody:SetWidth(636); expBody:SetHeight(EXP_BODY_H)

    -- Account Alias row: label, input box and warning on one line, 12px gaps.
    local aliasLabel = expBody:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aliasLabel:SetPoint("LEFT", expBody, "TOPLEFT", 12, -22)
    aliasLabel:SetText(COLOR.white .. "Account Alias:|r")

    local aliasBox = CreateFrame("EditBox", nil, expBody, "InputBoxTemplate")
    aliasBox:SetAutoFocus(false)
    aliasBox:SetWidth(159); aliasBox:SetHeight(20)   -- ~25% of the 636-wide body
    aliasBox:SetPoint("LEFT", aliasLabel, "RIGHT", 12, 0)
    aliasBox:SetMaxLetters(20)

    -- Greyed placeholder shown only when empty (3.3.5a EditBoxes have no native one).
    local aliasPlaceholder = aliasBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aliasPlaceholder:SetPoint("CENTER", aliasBox, "CENTER", 0, -1)
    aliasPlaceholder:SetText(COLOR.grey .. "Main Account?|r")
    local function UpdateAliasPlaceholder()
        if aliasBox:GetText() == "" then aliasPlaceholder:Show() else aliasPlaceholder:Hide() end
    end

    aliasBox:SetScript("OnTextChanged",   function(self) BiSTrackerDB.accountAlias = self:GetText(); UpdateAliasPlaceholder() end)
    aliasBox:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
    aliasBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    UpdateAliasPlaceholder()

    local aliasWarn = expBody:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    aliasWarn:SetPoint("LEFT", aliasBox, "RIGHT", 12, 0)
    aliasWarn:SetText("|cffff2020DO NOT USE YOUR REAL ACCOUNT NAME.|r")

    local aliasInfo1 = expBody:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aliasInfo1:SetPoint("TOPLEFT", expBody, "TOPLEFT", 10, -48)
    aliasInfo1:SetWidth(616); aliasInfo1:SetJustifyH("LEFT")
    aliasInfo1:SetText(COLOR.lgrey .. "Give this account an alias like Main/Second/XYZ's Account/Whatever. This is only relevant for exporting into your BisTracker Sheet if you are using multiple accounts.|r")

    local aliasInfo2 = expBody:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    aliasInfo2:SetPoint("TOPLEFT", expBody, "TOPLEFT", 10, -88)
    aliasInfo2:SetWidth(616); aliasInfo2:SetJustifyH("LEFT")
    aliasInfo2:SetText(COLOR.grey .. "Why its important? The sheet is designed to support multiple accounts. If you are using the sheet for multiple accounts in a single sheet/copy, when pasting the export string to update your characters and no account name is set for multiple accounts it will delete chars that are not existing in the current export string.|r")

    -- ============ Announce Settings ============
    local annHeader, annCollapseBtn = MakeHeader("Announcer Settings")
    local body = CreateFrame("Frame", nil, c)
    body:SetWidth(636); body:SetHeight(BODY_H)

    -- Description
    local desc = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT", body, "TOPLEFT", 10, -8)
    desc:SetWidth(616); desc:SetJustifyH("CENTER")
    desc:SetText(COLOR.lgrey .. " The Settings below only apply if you are chosen as the Announcer|r")

    MakeSep(body, -24)

    -- Announcer info + current announcer
    local annInfo = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    annInfo:SetPoint("TOPLEFT", body, "TOPLEFT", 10, -32)
    annInfo:SetWidth(616); annInfo:SetJustifyH("CENTER")
    annInfo:SetText(COLOR.lgrey .. "Only the Announcer is able to auto-react to posted items. Must have lead or assist. Hierarchy: Raid Lead > Master Looter > Assist|r")
    local announcerLbl = FS(body, 10, -64, COLOR.legendary .. "Current selected Announcer for this Raid:|r " .. COLOR.grey .. "None|r")
    announcerLbl:SetWidth(616); announcerLbl:SetJustifyH("LEFT")

    -- Section 1
    FS(body, 10, -100, COLOR.blue .. "Where are the Items be posted?|r")
    FS(body, 10, -116, COLOR.white .. "Listen to:|r")
    local cbReactNone = CB(body, 73,  -116)
    FS(body, 91,  -116, COLOR.lgrey .. " Nothing|r")
    FS(body, 138, -116, COLOR.white .. "or|r")
    local cbReactRC   = CB(body, 152, -116)
    FS(body, 170, -116, COLOR.lgrey .. " Raid Chat|r")
    FS(body, 228, -116, COLOR.white .. "or|r")
    local cbReactRW   = CB(body, 242, -116)
    FS(body, 260, -116, COLOR.lgrey .. " Raid Warning|r")
    MakeSep(body, -132)

    -- Section 2
    FS(body, 10,  -144, COLOR.blue .. "What to respond?|r")
    FS(body, 10,  -160, COLOR.white .. "Announce:|r")
    local cbAnnNone = CB(body, 73,  -160)
    FS(body, 91,  -160, COLOR.lgrey .. " Nothing|r")
    FS(body, 138, -160, COLOR.white .. "or|r")
    local cbAnnBiS  = CB(body, 152, -160)
    FS(body, 170, -160, COLOR.lgrey .. " BiS for Specs|r")
    FS(body, 238, -160, COLOR.white .. "and/or|r")
    local cbAnnAlt  = CB(body, 273, -160)
    FS(body, 291, -160, COLOR.lgrey .. " Alt for Specs|r")
    FS(body, 28,  -176, COLOR.white .. " in Channel:|r")
    local cbAnnSay  = CB(body, 106, -176)
    FS(body, 124, -176, COLOR.lgrey .. " Say|r")
    FS(body, 148, -176, COLOR.white .. "or|r")
    local cbAnnRC   = CB(body, 162, -176)
    FS(body, 180, -176, COLOR.lgrey .. " Raid Chat|r")
    FS(body, 237, -176, COLOR.white .. "or|r")
    local cbAnnRW   = CB(body, 251, -176)
    FS(body, 269, -176, COLOR.lgrey .. " Raid Warning|r")
    MakeSep(body, -192)

    -- Section 3
    FS(body, 10,  -204, COLOR.blue .. "Check all players gear? (They will be in the list below)|r")
    local cbScan = CB(body, 10, -220)
    FS(body, 28,  -220, COLOR.lgrey .. " Scan Raid Members|r")
    FS(body, 148, -220, COLOR.grey .. "(It will scan 1 player per 10 seconds to prevent server request spam)|r")
    MakeSep(body, -236)

    -- Section 4
    FS(body, 10,  -248, COLOR.blue .. "Inform Players if a posted Item is an upgrade? Requires Scan Raid Members|r")
    local cbInform = CB(body, 10, -264)
    FS(body, 28,  -264, COLOR.lgrey .. " Inform Players|r")
    FS(body, 148, -264, COLOR.grey .. "(It can not take care about MS Changes)|r")
    FS(body, 28,  -280, COLOR.white .. " in:|r")
    local cbInfWh  = CB(body, 50,  -280)
    FS(body, 68,  -280, COLOR.lgrey .. " Whisper|r")
    FS(body, 116, -280, COLOR.white .. "or|r")
    local cbInfSay = CB(body, 130, -280)
    FS(body, 148, -280, COLOR.lgrey .. " Say|r")
    FS(body, 172, -280, COLOR.white .. "or|r")
    local cbInfRC  = CB(body, 186, -280)
    FS(body, 204, -280, COLOR.lgrey .. " Raid Chat|r")
    MakeSep(body, -296)

    -- Raid header frame (repositions when body collapses)
    local raidHdrFrame = CreateFrame("Frame", nil, c)
    raidHdrFrame:SetWidth(636); raidHdrFrame:SetHeight(RAID_H)

    local raidBg = raidHdrFrame:CreateTexture(nil, "BACKGROUND")
    raidBg:SetHeight(22)
    raidBg:SetPoint("TOPLEFT",  raidHdrFrame, "TOPLEFT",  0, 0)
    raidBg:SetPoint("TOPRIGHT", raidHdrFrame, "TOPRIGHT", 0, 0)
    raidBg:SetTexture(0.2, 0.2, 0.2, 0.9)

    local raidTitleLbl = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    raidTitleLbl:SetPoint("TOP", raidHdrFrame, "TOP", 0, -5)
    raidTitleLbl:SetText(COLOR.legendary .. "Players in this Raid|r")

    local raidCharHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidCharHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 8, -26)
    raidCharHdr:SetText(COLOR.legendary .. "Character|r")
    local raidSpecHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidSpecHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 150, -26)
    raidSpecHdr:SetText(COLOR.legendary .. "Spec|r")
    local raidMsHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidMsHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 280, -26)
    raidMsHdr:SetWidth(80); raidMsHdr:SetJustifyH("CENTER")
    raidMsHdr:SetText(COLOR.legendary .. "MS Changed*|r")
    local raidBisHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidBisHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 390, -26)
    raidBisHdr:SetWidth(90); raidBisHdr:SetJustifyH("CENTER")
    raidBisHdr:SetText(COLOR.legendary .. "BiS Items|r")
    local raidGsHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidGsHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 493, -26)
    raidGsHdr:SetWidth(90); raidGsHdr:SetJustifyH("CENTER")
    raidGsHdr:SetText(COLOR.legendary .. "GearScore|r")
    local raidSep = raidHdrFrame:CreateTexture(nil, "ARTWORK")
    raidSep:SetHeight(1)
    raidSep:SetPoint("TOPLEFT",  raidHdrFrame, "TOPLEFT",   5, -40)
    raidSep:SetPoint("TOPRIGHT", raidHdrFrame, "TOPRIGHT",  -5, -40)
    raidSep:SetTexture(0.3, 0.3, 0.3, 0.8)

    -- Stack the collapsible sections, then the raid header; collapsing slides the rest up.
    local function UpdateLayout()
        local y = 0
        genHeader:ClearAllPoints();  genHeader:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
        genCollapseBtn:SetText(lsGeneralCollapsed and "v" or "^")
        y = y - HEADER_H
        if lsGeneralCollapsed then
            genBody:Hide()
        else
            genBody:ClearAllPoints(); genBody:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y); genBody:Show()
            y = y - GEN_BODY_H
        end
        expHeader:ClearAllPoints();  expHeader:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
        expCollapseBtn:SetText(lsExportCollapsed and "v" or "^")
        y = y - HEADER_H
        if lsExportCollapsed then
            expBody:Hide()
        else
            expBody:ClearAllPoints(); expBody:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y); expBody:Show()
            y = y - EXP_BODY_H
        end
        annHeader:ClearAllPoints();  annHeader:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
        annCollapseBtn:SetText(lsAnnounceCollapsed and "v" or "^")
        y = y - HEADER_H
        if lsAnnounceCollapsed then
            body:Hide()
        else
            body:ClearAllPoints(); body:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y); body:Show()
            y = y - BODY_H
        end
        raidHdrFrame:ClearAllPoints(); raidHdrFrame:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
        y = y - RAID_H
        c.raidListY = y
    end
    lsWidgets.updateLayout = UpdateLayout
    UpdateLayout()

    -- Widget refs
    lsWidgets.announcerLbl    = announcerLbl
    lsWidgets.cbNotifySelf    = cbNotifySelf
    lsWidgets.cbAutoScanGear  = cbAutoScanGear
    lsWidgets.cbAutoScanLocks = cbAutoScanLocks
    lsWidgets.cbSkipAnnouncer = cbSkipAnnouncer
    lsWidgets.cbMinimapPopup  = cbMinimapPopup
    lsWidgets.aliasBox        = aliasBox
    lsWidgets.cbReactNone   = cbReactNone;   lsWidgets.cbReactRC    = cbReactRC
    lsWidgets.cbReactRW     = cbReactRW
    lsWidgets.cbAnnNone     = cbAnnNone;     lsWidgets.cbAnnBiS     = cbAnnBiS
    lsWidgets.cbAnnAlt      = cbAnnAlt;      lsWidgets.cbAnnSay     = cbAnnSay
    lsWidgets.cbAnnRC       = cbAnnRC;       lsWidgets.cbAnnRW      = cbAnnRW
    lsWidgets.cbScan        = cbScan;        lsWidgets.cbInform     = cbInform
    lsWidgets.cbInfWh       = cbInfWh;       lsWidgets.cbInfSay     = cbInfSay
    lsWidgets.cbInfRC       = cbInfRC

    -- Collapse toggles (independent per section)
    genCollapseBtn:SetScript("OnClick", function()
        lsGeneralCollapsed = not lsGeneralCollapsed
        UpdateLayout()
        BiSTracker_RefreshRaidList()
    end)
    expCollapseBtn:SetScript("OnClick", function()
        lsExportCollapsed = not lsExportCollapsed
        UpdateLayout()
        BiSTracker_RefreshRaidList()
    end)
    annCollapseBtn:SetScript("OnClick", function()
        lsAnnounceCollapsed = not lsAnnounceCollapsed
        UpdateLayout()
        BiSTracker_RefreshRaidList()
    end)

    -- General settings: plain boolean toggles
    cbAutoScanGear:SetScript("OnClick", function()
        LS().autoScanGear = cbAutoScanGear:GetChecked() and true or false
    end)
    cbAutoScanLocks:SetScript("OnClick", function()
        LS().autoScanLocks = cbAutoScanLocks:GetChecked() and true or false
    end)
    cbMinimapPopup:SetScript("OnClick", function()
        LS().minimapPopup = cbMinimapPopup:GetChecked() and true or false
    end)
    -- Skip Announcer: re-advertise candidacy to the raid (SKIP/HELLO) and re-elect.
    cbSkipAnnouncer:SetScript("OnClick", function()
        LS().skipAnnouncer = cbSkipAnnouncer:GetChecked() and true or false
        if GetNumRaidMembers() > 0 then
            SendAddon(LS().skipAnnouncer and "SKIP" or "HELLO")
        end
        BiSTracker_RefreshAnnouncer()
    end)

    -- Radio: reactTo
    local function setReactTo(val)
        LS().reactTo = val
        cbReactNone:SetChecked(val == "nothing")
        cbReactRC:SetChecked(val == "raidChat")
        cbReactRW:SetChecked(val == "raidWarning")
    end
    cbReactNone:SetScript("OnClick", function()
        if cbReactNone:GetChecked() then setReactTo("nothing") else cbReactNone:SetChecked(true) end
    end)
    cbReactRC:SetScript("OnClick", function()
        if cbReactRC:GetChecked() then setReactTo("raidChat") else cbReactRC:SetChecked(true) end
    end)
    cbReactRW:SetScript("OnClick", function()
        if cbReactRW:GetChecked() then setReactTo("raidWarning") else cbReactRW:SetChecked(true) end
    end)

    -- Notify self
    cbNotifySelf:SetScript("OnClick", function()
        LS().notifyMySpec = cbNotifySelf:GetChecked() and true or false
    end)

    -- Announce: Nothing exclusive with BiS/Alt
    local function checkAnnNone()
        if not cbAnnBiS:GetChecked() and not cbAnnAlt:GetChecked() then
            cbAnnNone:SetChecked(true); LS().announceNone = true
        end
    end
    cbAnnNone:SetScript("OnClick", function()
        if cbAnnNone:GetChecked() then
            cbAnnBiS:SetChecked(false); cbAnnAlt:SetChecked(false)
            LS().announceNone = true; LS().announceBiS = false; LS().announceAlt = false
        else cbAnnNone:SetChecked(true) end
    end)
    cbAnnBiS:SetScript("OnClick", function()
        if cbAnnBiS:GetChecked() then
            cbAnnNone:SetChecked(false); LS().announceNone = false; LS().announceBiS = true
        else LS().announceBiS = false; checkAnnNone() end
    end)
    cbAnnAlt:SetScript("OnClick", function()
        if cbAnnAlt:GetChecked() then
            cbAnnNone:SetChecked(false); LS().announceNone = false; LS().announceAlt = true
        else LS().announceAlt = false; checkAnnNone() end
    end)

    -- Radio: announceChannel
    local function setAnnCh(val)
        LS().announceChannel = val
        cbAnnSay:SetChecked(val == "say"); cbAnnRC:SetChecked(val == "raidChat"); cbAnnRW:SetChecked(val == "raidWarning")
    end
    cbAnnSay:SetScript("OnClick", function() if cbAnnSay:GetChecked() then setAnnCh("say")         else cbAnnSay:SetChecked(true) end end)
    cbAnnRC:SetScript("OnClick",  function() if cbAnnRC:GetChecked()  then setAnnCh("raidChat")    else cbAnnRC:SetChecked(true)  end end)
    cbAnnRW:SetScript("OnClick",  function() if cbAnnRW:GetChecked()  then setAnnCh("raidWarning") else cbAnnRW:SetChecked(true)  end end)

    -- Scan / Inform dependency
    cbScan:SetScript("OnClick", function()
        local on = cbScan:GetChecked() and true or false
        LS().scanRaid = on
        if on then
            raidScanFrame:Show()
            raidScanFrame:TriggerRebuild()   -- start (or restart) the full scan immediately
        else
            raidScanFrame:Stop()             -- end the queue and stop updating
            if LS().informPlayers then cbInform:SetChecked(false); LS().informPlayers = false end
        end
    end)
    cbInform:SetScript("OnClick", function()
        local on = cbInform:GetChecked() and true or false
        LS().informPlayers = on
        if on and not LS().scanRaid then
            cbScan:SetChecked(true); LS().scanRaid = true
            raidScanFrame:Show(); raidScanFrame:TriggerRebuild()
        end
    end)

    -- Radio: informChannel
    local function setInfCh(val)
        LS().informChannel = val
        cbInfWh:SetChecked(val == "whisper"); cbInfSay:SetChecked(val == "say"); cbInfRC:SetChecked(val == "raidChat")
    end
    cbInfWh:SetScript("OnClick",  function() if cbInfWh:GetChecked()  then setInfCh("whisper")  else cbInfWh:SetChecked(true)  end end)
    cbInfSay:SetScript("OnClick", function() if cbInfSay:GetChecked() then setInfCh("say")      else cbInfSay:SetChecked(true) end end)
    cbInfRC:SetScript("OnClick",  function() if cbInfRC:GetChecked()  then setInfCh("raidChat") else cbInfRC:SetChecked(true)  end end)
end

-- ============================================================
-- RAID SCAN FRAME
-- ============================================================

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
    local INTERVAL           = 10.0
    local WAIT               = 1.5
    local REBUILD_INTERVAL   = 300.0  -- 5 minutes between full scans
    local MAX_REQUEUES       = 5      -- out-of-range re-queue cap before dropping (re-added next full scan)

    local function DetectInspectSpec(classFile)
        if not classFile then return nil end
        local trees = CLASS_TREES[classFile]
        if not trees then return nil end
        local maxPoints, maxTab = 0, 1
        for tab = 1, GetNumTalentTabs(true) do
            local _, _, pts = GetTalentTabInfo(tab, true)
            if (pts or 0) > maxPoints then maxPoints = pts; maxTab = tab end
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
        local msChanged = {}
        for name, flagged in pairs(raidMSChanged) do
            if flagged then msChanged[name] = true end  -- persist the "MS Changed" checkboxes
        end
        BiSTrackerDB.raidSnapshot = { realm = GetRealmName(), time = time(), members = members, msChanged = msChanged }
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
        if snap.msChanged then
            for name, flagged in pairs(snap.msChanged) do
                if flagged and roster[name] then raidMSChanged[name] = true end
            end
        end
        if debugMode and loaded > 0 then
            local age = snap.time and (time() - snap.time) or 0
            Print("[RaidScan] Snapshot restored: |cffffff00" .. loaded .. "|r member(s) (" .. age .. "s old). Rescanning in background...")
        end
        return loaded
    end

    -- Returns true when a player is already being inspected or is in the queue.
    local function IsQueued(name)
        if currentName == name then return true end
        for _, e in ipairs(raidScanQueue) do
            if e.name == name then return true end
        end
        return false
    end

    -- Remove a player from the queue / cancel their in-progress inspection; true if either happened.
    local function RemoveFromQueue(name)
        local newQueue = {}
        local removed = false
        for _, e in ipairs(raidScanQueue) do
            if e.name ~= name then table.insert(newQueue, e) else removed = true end
        end
        raidScanQueue = newQueue
        if currentName == name then
            currentUnit = nil; currentName = nil; currentEntry = nil
            mainTimer = 0
            return true
        end
        return removed
    end

    -- Appends a single player to the queue and starts the scan immediately if idle.
    local function EnqueuePlayer(name, unitID, isSelf)
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
        SaveRaidSnapshot()   -- persist the freshest full picture of the raid
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
        rebuildActive = false; rebuildTimer = 0
        currentUnit = nil; currentName = nil; currentEntry = nil
        local total = BuildFullQueue()
        mainTimer = INTERVAL
        if debugMode then Print("[RaidScan] Queue rebuilt: |cffffff00" .. total .. "|r member(s).") end
    end

    -- Stop scanning entirely: clear the queue + any in-progress inspection, drop results, hide.
    function raidScanFrame:Stop()
        raidScanData = {}; raidScanQueue = {}
        currentUnit = nil; currentName = nil; currentEntry = nil
        rebuildActive = false; rebuildTimer = 0
        fullScanInProgress = false; onlineStatus = {}
        snapshotLoadAttempted = false
        mainTimer = 0; inspectTimer = 0; connTimer = 0
        self:Hide()
        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()
        end
    end

    -- Called on RAID_ROSTER_UPDATE: detects joins and leaves incrementally.
    function raidScanFrame:HandleRosterUpdate()
        if not LS().scanRaid then return end
        if GetNumRaidMembers() == 0 then
            raidScanData = {}; raidScanQueue = {}
            currentUnit = nil; currentName = nil; currentEntry = nil
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
            snapshotLoadAttempted = true
            if LoadRaidSnapshot() > 0 then
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
                local cancelled = RemoveFromQueue(name)
                if cancelled and #raidScanQueue == 0 then
                    rebuildActive = true; rebuildTimer = 0
                end
                if debugMode then Print("[RaidScan] " .. name .. " left the raid, removed.") end
            end
        end

        -- Queue players who just joined (online only)
        for name, info in pairs(currentRoster) do
            if not raidScanData[name] and not IsQueued(name) then
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

        -- Wait for in-progress inspection to finish
        if currentUnit then
            inspectTimer = inspectTimer + elapsed
            if inspectTimer >= WAIT then
                inspectTimer = 0
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
                if currentEntry and currentEntry.isSelf then
                    spec = DetectSpec()
                else
                    spec = DetectInspectSpec(classL)
                end
                if not spec then
                    local charKey = currentName .. "-" .. GetRealmName()
                    if BiSTrackerDB.characters[charKey] then
                        spec = BiSTrackerDB.characters[charKey].activeSpec
                    end
                end

                if slotCount == 0 and not (currentEntry and currentEntry.isSelf) then
                    if currentEntry then
                        currentEntry.requeues = (currentEntry.requeues or 0) + 1
                        if currentEntry.requeues < MAX_REQUEUES then
                            if debugMode then Print("[RaidScan] |cffffff00" .. currentName .. "|r out of range, re-queuing (" .. currentEntry.requeues .. "/" .. MAX_REQUEUES .. ").") end
                            table.insert(raidScanQueue, currentEntry)
                        elseif debugMode then
                            Print("[RaidScan] |cffffff00" .. currentName .. "|r out of range " .. MAX_REQUEUES .. "x, dropping until next full scan.")
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
                    if debugMode then
                        local specStr  = spec and ("|cffaaaaaa" .. spec .. "|r") or ("|cff666666class:" .. (classL or "?") .. "|r")
                        local queueStr = #raidScanQueue > 0 and ("|cffaaaaaa" .. #raidScanQueue .. " left|r") or "|cff44ff44done|r"
                        Print("[RaidScan] |cffffff00" .. currentName .. "|r  spec=" .. specStr .. "  slots=" .. slotCount .. "  " .. queueStr)
                    end
                end

                currentUnit = nil; currentName = nil; currentEntry = nil
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

        -- Skip offline players (they may have disconnected after being queued)
        if not entry.isSelf then
            local online = false
            for i = 1, GetNumRaidMembers() do
                local n, _, _, _, _, _, _, onl = GetRaidRosterInfo(i)
                if n == entry.name then online = onl; break end
            end
            if not online then
                if debugMode then Print("[RaidScan] Skipping |cffffff00" .. entry.name .. "|r (offline).") end
                if #raidScanQueue == 0 then
                    OnQueueDrained()      -- last entry was a skip: finish the queue properly
                else
                    mainTimer = INTERVAL  -- check next entry immediately
                end
                return
            end
        end

        currentUnit  = entry.unitID
        currentName  = entry.name
        currentEntry = entry
        inspectTimer = 0
        if debugMode then Print("[RaidScan] Inspecting |cffffff00" .. currentName .. "|r (" .. entry.unitID .. ")...") end
        if not entry.isSelf then NotifyInspect(entry.unitID) end
    end)
end
