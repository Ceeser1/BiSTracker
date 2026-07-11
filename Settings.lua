-- ============================================================
-- LOOT SETTINGS + RAID UI  (engines live elsewhere: RaidScan.lua = scanning, Announcer.lua = announcer/comms)
-- ============================================================

local lsWidgets          = {}
local lsRaidRowPool      = {}
local lsRaidDetailPanels = {}
local expandedRaidMembers = {}
local lsGeneralCollapsed  = false  -- General Settings section collapse state
local lsExportCollapsed   = false  -- Export Settings section collapse state
local lsAnnounceCollapsed = false  -- Announce Settings section collapse state
-- Raid scan state + engine live in RaidScan.lua (globals: raidScanData /
-- raidScanOOR / raidScanFailed / raidScanQueue, plus the raidScanFrame methods).
-- The announcer/comms engine (election, version check, MS-Changed + whisper sync, loot
-- post reactions) lives in Announcer.lua (globals: currentAnnouncer / mscLocked / raidMSChanged
-- / noWhisperUsers / whisperOn and the Save/Load/Schedule + handler functions).


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
    if ls.allowWhispers   == nil then ls.allowWhispers   = true       end  -- allow announcer upgrade whispers (default on)
    -- Settings-window section collapse state (persist so it survives relog; default expanded)
    if ls.genCollapsed    == nil then ls.genCollapsed    = false      end
    if ls.expCollapsed    == nil then ls.expCollapsed    = false      end
    if ls.annCollapsed    == nil then ls.annCollapsed    = false      end
    return ls
end

function UpdateAnnouncerUI()  -- global: called by SetAnnouncer in Announcer.lua
    if lsWidgets.announcerLbl then
        lsWidgets.announcerLbl:SetText(
            COLOR.legendary .. "Current selected Announcer for this Raid:|r "
            .. (currentAnnouncer and (COLOR.white .. currentAnnouncer .. "|r")
                                  or  (COLOR.grey .. "None|r")))
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
    if lsWidgets.cbAllowWhisper  then lsWidgets.cbAllowWhisper:SetChecked(ls.allowWhispers)  end
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

-- Wipe all user settings back to their LS() defaults (incl. the account alias) and refresh the
-- open settings window. Characters/realms are left untouched. Used by /bis reset.
function BiSTracker_ResetSettings()
    BiSTrackerDB.lootSettings = nil
    BiSTrackerDB.accountAlias = nil
    LS()   -- rebuild lootSettings with defaults
    -- Section collapse state is mirrored in these file-locals; re-expand to match the defaults.
    lsGeneralCollapsed  = false
    lsExportCollapsed   = false
    lsAnnounceCollapsed = false
    LootSettings_SyncUI()   -- refresh widgets/alias/layout (no-op if the window isn't built yet)
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

    -- Write one gear line. Empty slots still show as white "Empty"; the sole exception is Off Hand,
    -- which is hidden when empty (2H weapons / no shield are normal, not a missing item).
    local COL_W = { DETAIL_COL_X[2] - DETAIL_COL_X[1] - 8, 626 - DETAIL_COL_X[2] - 8 }
    local function WriteItem(c, lineIdx, yOff, gearSlot)
        local label = gearSlot   -- display label defaults to the slot name (Ranged overrides it below)
        local item  = gear[gearSlot]
        local empty = not item or not item.name
        if empty and gearSlot == "Off Hand" then return lineIdx, yOff end
        if not empty and gearSlot == "Ranged" then label = RangedLabel(item) end
        lineIdx = lineIdx + 1
        if lineIdx > DETAIL_MAX_LINES[c] then return lineIdx, yOff end
        local row = panel.lines[c][lineIdx]
        row.indic:Hide()
        row.name:ClearAllPoints()
        row.name:SetPoint("TOPLEFT", panel, "TOPLEFT", DETAIL_COL_X[c], yOff)
        row.name:SetWidth(COL_W[c])
        if empty then
            row.name:SetText("|cffaaaaaa[" .. label .. "]|r " .. COLOR.white .. "Empty|r")
        else
            local col     = SlotColor(gearSlot)
            local ilvlStr = (item.ilvl and item.ilvl > 0) and " (" .. item.ilvl .. ")" or ""
            local prefix  = (item.alt and not item.bis) and (COLOR.blue .. "(Alt)|r ") or ""
            row.name:SetText("|cffaaaaaa[" .. label .. "]|r " .. prefix .. col .. item.name .. ilvlStr .. "|r")
        end
        row.name:Show()
        yOff = yOff - DETAIL_LINE_H
        return lineIdx, yOff
    end

    -- Slot order matches the two-column layout of the main window
    local COL1_GEAR = {
        "Main Hand", "Off Hand", "Ranged",
        false,   -- blank spacer between weapons and armor
        "Head", "Neck", "Shoulders", "Back", "Chest", "Wrist",
    }
    local COL2_GEAR = {
        "Hands", "Waist", "Legs", "Feet",
        "Ring 1", "Ring 2", "Trinket 1", "Trinket 2",
    }

    local colHeights = { 0, 0 }
    do
        local lineIdx, yOff = 0, -4
        for _, s in ipairs(COL1_GEAR) do
            if not s then
                if lineIdx > 0 then yOff = yOff - DETAIL_LINE_H end   -- blank spacer row (only after real rows)
            else
                lineIdx, yOff = WriteItem(1, lineIdx, yOff, s)
            end
        end
        colHeights[1] = math.abs(yOff) + 6
    end
    do
        local lineIdx, yOff = 0, -4
        for _, s in ipairs(COL2_GEAR) do lineIdx, yOff = WriteItem(2, lineIdx, yOff, s) end
        colHeights[2] = math.abs(yOff) + 6
    end

    local panelH = math.max(colHeights[1], colHeights[2], 20)
    panel:SetHeight(panelH)
    panel.sep:SetHeight(panelH - 6)
end

-- Enable/disable a raid-list checkbox, tinting the interactive (non-read-only) ones green (#aaffaa)
-- so it's obvious at a glance which checkboxes the viewer can actually change.
local function SetRaidCheckEnabled(check, enabled)
    local nt = check:GetNormalTexture()
    if enabled then
        check:Enable()
        if nt then nt:SetVertexColor(0, 1, 0) end            -- #00ff00
    else
        check:Disable()
        if nt then nt:SetVertexColor(1, 1, 1) end            -- default (greyed by the disabled texture)
    end
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
            row.nameLbl:SetWidth(110); row.nameLbl:SetJustifyH("LEFT")   -- 40px narrower to free space
            row.specLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.specLbl:SetPoint("LEFT", row, "LEFT", 110, 0)            -- moved 40px left
            row.specLbl:SetWidth(150); row.specLbl:SetJustifyH("LEFT")
            row.whisperCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.whisperCheck:SetWidth(18); row.whisperCheck:SetHeight(18)
            row.whisperCheck:ClearAllPoints()
            row.whisperCheck:SetPoint("CENTER", row, "LEFT", 263, 0)     -- centered under "Whisper?" header
            row.msCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.msCheck:SetWidth(18); row.msCheck:SetHeight(18)
            row.msCheck:ClearAllPoints()
            row.msCheck:SetPoint("CENTER", row, "LEFT", 358, 0)   -- centered under "MS Changed*" header
            row.bisLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.bisLbl:SetPoint("LEFT", row, "LEFT", 413, 0)
            row.bisLbl:SetWidth(80); row.bisLbl:SetJustifyH("CENTER")   -- centered at 453
            row.gsLbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.gsLbl:SetPoint("LEFT", row, "LEFT", 508, 0)
            row.gsLbl:SetWidth(80); row.gsLbl:SetJustifyH("CENTER")     -- centered at 548
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

        -- Whisper? checkbox: checked = whisper. Default ON; the only persistent off-authority is the
        -- player's own "Don't whisper me" broadcast. The announcer's manual override is session-only.
        -- Own row included: it's gated by noWhisperUsers[self], which the "Allow announcer whispers"
        -- setting drives. The Whisper? box only ever sets whisperOn (whether to actually whisper),
        -- never the allow gate.
        local wName = m.name
        if noWhisperUsers[wName] then
            -- Opted out (own setting, or another player's broadcast): locked off for everyone.
            row.whisperCheck:SetChecked(false)
            SetRaidCheckEnabled(row.whisperCheck, false)
        elseif currentAnnouncer == nil or currentAnnouncer == UnitName("player") then
            -- The announcer edits these; when no announcer is elected yet (fresh raid / after
            -- clearing the snapshot) everyone is editable and defaults to ON.
            row.whisperCheck:SetChecked(whisperOn[wName] ~= false)
            SetRaidCheckEnabled(row.whisperCheck, true)
        else
            -- Listener: read-only. The announcer's per-player picks aren't broadcast, so show the
            -- default (whisper) for anyone who hasn't opted out.
            row.whisperCheck:SetChecked(true)
            SetRaidCheckEnabled(row.whisperCheck, false)
        end
        row.whisperCheck:SetScript("OnClick", function(self)
            whisperOn[wName] = self:GetChecked() and true or false
        end)
        row.whisperCheck:Show()

        -- MS Changed checkbox: one per player, state kept for the session (unchecked by default).
        local msName = m.name
        row.msCheck:SetChecked(raidMSChanged[msName] and true or false)
        row.msCheck:SetScript("OnClick", function(self)
            raidMSChanged[msName] = self:GetChecked() and true or false
            SaveMSChanged()               -- persist immediately, don't wait for the next scan-queue drain
            ScheduleMSChangedBroadcast()  -- announcer: push the change to listeners (5s throttle)
        end)
        -- Listeners bound to an announcer's broadcast can't edit; enabled when no announcer / we're it.
        SetRaidCheckEnabled(row.msCheck, not mscLocked)
        row.msCheck:Show()

        local scanEntry = raidScanData[m.name]
        if scanEntry and scanEntry.spec then
            row.specLbl:SetText("|cffaaaaaa" .. scanEntry.spec .. "|r")
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
            if scanEntry or raidScanFailed[m.name] then
                -- A genuine failure, OR a stored entry whose spec never resolved (e.g. an old snapshot
                -- from before the spec-detection fix). A class name isn't a spec, so show "Unable to
                -- scan" rather than falling back to the bare class.
                row.specLbl:SetText("|cffcc6666Unable to scan|r")
                row.bisLbl:SetText("|cffcc6666-|r")   -- failed: red dash, not the neutral "loading" grey
                row.gsLbl:SetText("|cffcc6666-|r")
            elseif raidScanOOR[m.name] then
                row.specLbl:SetText("|cffcc9944Out of range, retrying...|r")
                row.bisLbl:SetText("|cffaaaaaa-|r")
                row.gsLbl:SetText("|cff666666-|r")
            else
                row.specLbl:SetText(LS().scanRaid and "|cff666666Scanning...|r" or "|cff666666Not scanned|r")
                row.bisLbl:SetText("|cffaaaaaa-|r")
                row.gsLbl:SetText("|cff666666-|r")
            end
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
        note:SetText(COLOR.grey .. "* If players changed MS the Addon wont compare posted items to their gear nor informs them for possible upgrades since their spec doesn't match desired items.|r")
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
    local GEN_BODY_H = 204   -- General Settings body height (incl. empty row after notify + trailing empty row)
    local BODY_H     = 312   -- Announce Settings body height
    local RAID_H     = 44

    -- Restore persisted collapse state for the three settings sections.
    local ls0 = LS()
    lsGeneralCollapsed  = ls0.genCollapsed and true or false
    lsExportCollapsed   = ls0.expCollapsed and true or false
    lsAnnounceCollapsed = ls0.annCollapsed and true or false

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

    -- empty spacer row at -118

    local cbAllowWhisper = CB(genBody, 10, -140)
    FS(genBody, 28,  -140, COLOR.white .. " Allow announcer whispers|r")
    FS(genBody, 190, -140, COLOR.grey .. "(If enabled, the announcer may whisper you when a posted item is an upgrade)|r")

    local cbSkipAnnouncer = CB(genBody, 10, -162)
    FS(genBody, 28,  -162, COLOR.white .. " Never be Announcer|r")
    FS(genBody, 190, -162, COLOR.grey .. "(If enabled, you can never be the announcer of the raid)|r")

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
    annInfo:SetText(COLOR.lgrey .. "Only the Announcer is able to auto-react to posted items nand edit Whisper? + MS Changes at 'Players in this Raid'. Must have lead or assist. Hierarchy: Raid Lead > Master Looter > Assist|r")
    local announcerLbl = FS(body, 10, -80, COLOR.legendary .. "Current selected Announcer for this Raid:|r " .. COLOR.grey .. "None|r")
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
    raidSpecHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 110, -26)   -- moved 40px left to free space
    raidSpecHdr:SetText(COLOR.legendary .. "Spec|r")
    -- Four columns evenly spread across the 340px between Spec's end (260) and the toggle button (600):
    -- 85px slots centered at 303 / 388 / 473 / 558 (headers 80px wide, centered on those points).
    local raidWhisperHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidWhisperHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 223, -26)
    raidWhisperHdr:SetWidth(80); raidWhisperHdr:SetJustifyH("CENTER")
    raidWhisperHdr:SetText(COLOR.legendary .. "Whisper?|r")
    local raidMsHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidMsHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 318, -26)
    raidMsHdr:SetWidth(80); raidMsHdr:SetJustifyH("CENTER")
    raidMsHdr:SetText(COLOR.legendary .. "MS Changed*|r")
    local raidBisHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidBisHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 413, -26)
    raidBisHdr:SetWidth(80); raidBisHdr:SetJustifyH("CENTER")
    raidBisHdr:SetText(COLOR.legendary .. "BiS Items|r")
    local raidGsHdr = raidHdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidGsHdr:SetPoint("TOPLEFT", raidHdrFrame, "TOPLEFT", 508, -26)
    raidGsHdr:SetWidth(80); raidGsHdr:SetJustifyH("CENTER")
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
    lsWidgets.cbAllowWhisper  = cbAllowWhisper
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
        LS().genCollapsed = lsGeneralCollapsed
        UpdateLayout()
        BiSTracker_RefreshRaidList()
    end)
    expCollapseBtn:SetScript("OnClick", function()
        lsExportCollapsed = not lsExportCollapsed
        LS().expCollapsed = lsExportCollapsed
        UpdateLayout()
        BiSTracker_RefreshRaidList()
    end)
    annCollapseBtn:SetScript("OnClick", function()
        lsAnnounceCollapsed = not lsAnnounceCollapsed
        LS().annCollapsed = lsAnnounceCollapsed
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
    -- Allow announcer whispers: update instantly (responsive + persisted), then broadcast on a 5s throttle.
    cbAllowWhisper:SetScript("OnClick", function()
        local allow = cbAllowWhisper:GetChecked() and true or false
        LS().allowWhispers = allow
        noWhisperUsers[UnitName("player")] = (not allow) and true or nil   -- opted out only if NOT allowed
        SaveWhisperOptOut(UnitName("player"), not allow)             -- persist our own choice too
        ScheduleNoWhisperBroadcast()
        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()   -- gate changed: refresh our own Whisper? row
        end
    end)
    -- Skip Announcer: re-advertise candidacy to the raid (SKIP/HELLO) and re-elect.
    cbSkipAnnouncer:SetScript("OnClick", function()
        LS().skipAnnouncer = cbSkipAnnouncer:GetChecked() and true or false
        if GetNumRaidMembers() > 0 then
            SendAddon(PresenceMsg())
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

