-- ============================================================
-- GUI: DETAIL PANEL
-- ============================================================

local rowPool            = {}
local realmHeaderPool    = {}   -- Main list realm-group header rows (pooled by index)
local collapsedRealms    = {}   -- [realm] = true → realm group collapsed in Main list (session-only)
local allBisRowPool      = {}
local allBisDetailPanels = {}
local expandedSpecs      = {}

local REALM_HDR_H = 22          -- height of a realm-group header row

local function GetOrCreateDetailPanel(charKey)
    if detailPanels[charKey] then return detailPanels[charKey] end

    local content = mainFrame.content
    local panel   = CreateFrame("Frame", nil, content)
    panel:SetWidth(632); panel:SetHeight(1)

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetTexture(0.05, 0.05, 0.05, 0.72)

    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetWidth(1)
    sep:SetPoint("TOPLEFT", panel, "TOPLEFT", DETAIL_COL_X[2] - 5, -3)
    sep:SetTexture(0.35, 0.35, 0.35, 1)
    panel.sep = sep

    panel.lines = {}
    for c = 1, 2 do
        panel.lines[c] = {}
        for r = 1, DETAIL_MAX_LINES[c] do
            local indic = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            indic:Hide()
            local name = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            name:SetJustifyH("LEFT"); name:Hide()
            panel.lines[c][r] = { indic=indic, name=name }
        end
    end

    detailPanels[charKey] = panel
    return panel
end

local function UpdateDetailPanel(panel, charData)
    for c = 1, 2 do
        for r = 1, DETAIL_MAX_LINES[c] do
            panel.lines[c][r].indic:Hide()
            panel.lines[c][r].name:Hide()
        end
    end

    local specName = charData.activeSpec
    local specData = specName and ClassesBiS and ClassesBiS[specName]
    local gear     = GetActiveGear(charData)

    if not specData then panel:SetHeight(20); return end

    local function ItemLabel(name, ilvl, isAlt)
        local prefix = isAlt and "(Alt) " or ""
        local suffix = (ilvl and ilvl > 0) and " (" .. ilvl .. ")" or ""
        return prefix .. name .. suffix
    end

    local function WriteSlotEntry(c, lineIdx, yOff, entry)
        local colX     = DETAIL_COL_X[c]
        local slotName = Trim(entry.slot)
        local bisName  = entry.bis and Trim(entry.bis.name) or nil
        local altName  = entry.alt and Trim(entry.alt.name) or nil
        local bisIlvl  = entry.bis and entry.bis.ilvl or 0
        local altIlvl  = entry.alt and entry.alt.ilvl or 0
        local bisStatus = bisName and CheckItemStatus(gear, slotName, bisName, bisIlvl)
        local altStatus = altName and CheckItemStatus(gear, slotName, altName, altIlvl)

        if bisName then
            lineIdx = lineIdx + 1
            if lineIdx > DETAIL_MAX_LINES[c] then return lineIdx, yOff end
            local row = panel.lines[c][lineIdx]
            row.indic:ClearAllPoints(); row.name:ClearAllPoints()
            row.indic:SetPoint("TOPLEFT", panel, "TOPLEFT", colX, yOff)
            row.name:SetPoint("TOPLEFT",  panel, "TOPLEFT", colX + 14, yOff)
            row.name:SetWidth(296)
            local label = ItemLabel(bisName, bisIlvl, false)
            if bisStatus == "exact" then
                row.indic:SetText(COLOR.green .. "+|r"); row.name:SetText(COLOR.green .. label .. "|r")
            elseif bisStatus == "wrong_ilvl" then
                row.indic:SetText(COLOR.lorange .. "+|r"); row.name:SetText(COLOR.lorange .. label .. "|r")
            else
                row.indic:SetText(COLOR.red .. "-|r"); row.name:SetText(COLOR.white .. label .. "|r")
            end
            row.indic:Show(); row.name:Show()
            yOff = yOff - DETAIL_LINE_H
        end

        if altName then
            lineIdx = lineIdx + 1
            if lineIdx > DETAIL_MAX_LINES[c] then return lineIdx, yOff end
            local row = panel.lines[c][lineIdx]
            row.indic:ClearAllPoints(); row.name:ClearAllPoints()
            row.indic:SetPoint("TOPLEFT", panel, "TOPLEFT", colX + 10, yOff)
            row.name:SetPoint("TOPLEFT",  panel, "TOPLEFT", colX + 24, yOff)
            row.name:SetWidth(282)
            local label = ItemLabel(altName, altIlvl, true)
            if altStatus == "exact" then
                row.indic:SetText(COLOR.green .. "+|r"); row.name:SetText(COLOR.green .. label .. "|r")
            elseif altStatus == "wrong_ilvl" then
                row.indic:SetText(COLOR.lorange .. "+|r"); row.name:SetText(COLOR.lorange .. label .. "|r")
            else
                row.indic:SetText(COLOR.red .. "-|r"); row.name:SetText(COLOR.grey .. label .. "|r")
            end
            row.indic:Show(); row.name:Show()
            yOff = yOff - DETAIL_LINE_H
        end

        return lineIdx, yOff
    end

    local weapons, armor, col2 = SplitBiSColumns(specData)

    local colHeights = { 0, 0 }

    do  -- Column 1: weapons top, gap, then Head-Wrist
        local lineIdx, yOff = 0, -4
        for _, entry in ipairs(weapons) do lineIdx, yOff = WriteSlotEntry(1, lineIdx, yOff, entry) end
        if #weapons > 0 and #armor > 0 then yOff = yOff - DETAIL_LINE_H end
        for _, entry in ipairs(armor)   do lineIdx, yOff = WriteSlotEntry(1, lineIdx, yOff, entry) end
        colHeights[1] = math.abs(yOff) + 6
    end

    do  -- Column 2: Hands through Trinkets
        local lineIdx, yOff = 0, -4
        for _, entry in ipairs(col2) do lineIdx, yOff = WriteSlotEntry(2, lineIdx, yOff, entry) end
        colHeights[2] = math.abs(yOff) + 6
    end

    local panelH = math.max(colHeights[1], colHeights[2])
    panel:SetHeight(panelH)
    panel.sep:SetHeight(panelH - 6)
end

-- ============================================================
-- GUI: MAIN FRAME
-- ============================================================

function BiSTracker_ShowMainFrame()
    if mainFrame then
        viewMode = "main"
        mainFrame.editScrollFrame:Hide()
        mainFrame.mlScrollFrame:Hide()
        mainFrame.allBisScrollFrame:Hide()
        mainFrame.scrollFrame:Show()
        for _, lbl in ipairs(mainFrame.headerLabels)     do lbl:Show() end
        for _, lbl in ipairs(mainFrame.editHeaderLabels) do lbl:Hide() end
        mainFrame.editCharsBtn:SetText("Edit Chars")
        mainFrame.allClassesBisBtn:Enable()
        mainFrame.mlSettingsBtn:Enable()
        mainFrame.exportBtn:Enable()
        BiSTracker_RefreshList()
        mainFrame:Show()
        return
    end

    local f = CreateFrame("Frame", "BiSTrackerMainFrame", UIParent)
    f:SetWidth(680); f:SetHeight(420)
    f:SetPoint("CENTER", UIParent, "CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize=26, insets={left=9,right=9,top=9,bottom=9},
    })

    local windowBg = f:CreateTexture(nil, "ARTWORK")
    windowBg:SetPoint("TOPLEFT",     f, "TOPLEFT",     10, -10)
    windowBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    windowBg:SetTexture(0, 0, 0, 0.5)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14); title:SetText("|cffff8000BiS|r Tracker")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetWidth(80); exportBtn:SetHeight(22)
    exportBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -10)
    exportBtn:SetText("Export"); exportBtn:SetScript("OnClick", BiSTracker_ShowExportFrame)

    local mlSettingsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mlSettingsBtn:SetWidth(90); mlSettingsBtn:SetHeight(22)
    mlSettingsBtn:SetPoint("TOPRIGHT", exportBtn, "TOPLEFT", -4, 0)
    mlSettingsBtn:SetText("Settings")

    local editCharsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    editCharsBtn:SetWidth(80); editCharsBtn:SetHeight(22)
    editCharsBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -10)
    editCharsBtn:SetText("Edit Chars")

    local allClassesBisBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    allClassesBisBtn:SetWidth(110); allClassesBisBtn:SetHeight(22)
    allClassesBisBtn:SetPoint("TOPLEFT", editCharsBtn, "TOPRIGHT", 4, 0)
    allClassesBisBtn:SetText("All Classes BiS")

    local function SwitchView(mode)
        viewMode = mode
        f.scrollFrame:Hide(); f.editScrollFrame:Hide()
        f.mlScrollFrame:Hide(); f.allBisScrollFrame:Hide()
        for _, lbl in ipairs(f.headerLabels)     do lbl:Hide() end
        for _, lbl in ipairs(f.editHeaderLabels) do lbl:Hide() end
        local inSub = (mode ~= "main")
        if inSub then
            allClassesBisBtn:Disable(); mlSettingsBtn:Disable(); exportBtn:Disable()
        else
            allClassesBisBtn:Enable();  mlSettingsBtn:Enable();  exportBtn:Enable()
        end
        if mode == "main" then
            for _, lbl in ipairs(f.headerLabels) do lbl:Show() end
            f.scrollFrame:Show()
            BiSTracker_RefreshList()
            editCharsBtn:SetText("Edit Chars")
        elseif mode == "editChars" then
            for _, lbl in ipairs(f.editHeaderLabels) do lbl:Show() end
            BiSTracker_RefreshEditList()
            f.editScrollFrame:Show()
            editCharsBtn:SetText("< Back")
        elseif mode == "mlSettings" then
            f.mlScrollFrame:Show()
            editCharsBtn:SetText("< Back")
            LootSettings_SyncUI()
            BiSTracker_RefreshRaidList()
        elseif mode == "allClassesBis" then
            BiSTracker_RefreshAllClassesBis()
            f.allBisScrollFrame:Show()
            editCharsBtn:SetText("< Back")
        end
    end

    editCharsBtn:SetScript("OnClick", function()
        SwitchView(viewMode == "main" and "editChars" or "main")
    end)
    mlSettingsBtn:SetScript("OnClick", function()
        if viewMode ~= "mlSettings" then SwitchView("mlSettings") end
    end)
    allClassesBisBtn:SetScript("OnClick", function()
        if viewMode ~= "allClassesBis" then SwitchView("allClassesBis") end
    end)

    f.editCharsBtn     = editCharsBtn
    f.allClassesBisBtn = allClassesBisBtn
    f.mlSettingsBtn    = mlSettingsBtn
    f.exportBtn        = exportBtn

    -- Column headers. CWIDTH: cols 3-10 are fixed-width + centered; 1-2 keep defaults.
    local COL    = { 12, 126, 260, 304, 344, 384, 424, 464, 503, 553 }
    local HEADS  = { "Character", "Spec", "ICC25", "ICC10", "RS25", "RS10", "TOC25", "TOC10", "BiS", "GS" }
    local CWIDTH = { [3]=38, [4]=38, [5]=38, [6]=38, [7]=38, [8]=38, [9]=50, [10]=50 }
    f.headerLabels = {}
    for i = 1, #HEADS do
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", COL[i], -42)
        lbl:SetText(COLOR.legendary .. HEADS[i] .. "|r")
        if CWIDTH[i] then lbl:SetWidth(CWIDTH[i]); lbl:SetJustifyH("CENTER") end
        table.insert(f.headerLabels, lbl)
    end

    local div = f:CreateTexture(nil, "ARTWORK"); div:SetHeight(1)
    div:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -54)
    div:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -54)
    div:SetTexture(0.5, 0.5, 0.5, 0.8)
    f.headerDiv = div

    -- Edit mode column headers (hidden until Edit is activated)
    local EDIT_COL   = { 10, 195, 336, 569 }
    local EDIT_HEADS = { "Character", "Spec", "BiS", "Remove?" }
    local EDIT_WIDTH = { 180, 180, 50, 67 }
    local EDIT_JUST  = { "LEFT", "LEFT", "CENTER", "CENTER" }
    f.editHeaderLabels = {}
    for i = 1, #EDIT_HEADS do
        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", f, "TOPLEFT", EDIT_COL[i], -42)
        lbl:SetText(COLOR.legendary .. EDIT_HEADS[i] .. "|r")
        lbl:SetWidth(EDIT_WIDTH[i])
        lbl:SetJustifyH(EDIT_JUST[i])
        lbl:Hide()
        table.insert(f.editHeaderLabels, lbl)
    end

    local sf = CreateFrame("ScrollFrame", "BiSTrackerScrollFrame", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",       10, -58)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  -28,  10)

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(636); content:SetHeight(1)
    sf:SetScrollChild(content)

    local sf2 = CreateFrame("ScrollFrame", "BiSTrackerEditScrollFrame", f, "UIPanelScrollFrameTemplate")
    sf2:SetPoint("TOPLEFT",     f, "TOPLEFT",       10, -58)
    sf2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  -28,  10)
    local editContent = CreateFrame("Frame", nil, sf2)
    editContent:SetWidth(636); editContent:SetHeight(1)
    sf2:SetScrollChild(editContent)
    sf2:Hide()

    local sf3 = CreateFrame("ScrollFrame", "BiSTrackerMLScrollFrame", f, "UIPanelScrollFrameTemplate")
    sf3:SetPoint("TOPLEFT",     f, "TOPLEFT",       10, -58)
    sf3:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  -28,  10)
    local mlContent = CreateFrame("Frame", nil, sf3)
    mlContent:SetWidth(636); mlContent:SetHeight(1)
    sf3:SetScrollChild(mlContent)
    BuildLootSettingsUI(mlContent)
    sf3:Hide()

    local sf4 = CreateFrame("ScrollFrame", "BiSTrackerAllBisScrollFrame", f, "UIPanelScrollFrameTemplate")
    sf4:SetPoint("TOPLEFT",     f, "TOPLEFT",       10, -58)
    sf4:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",  -28,  10)
    local allBisContent = CreateFrame("Frame", nil, sf4)
    allBisContent:SetWidth(636); allBisContent:SetHeight(1)
    sf4:SetScrollChild(allBisContent)
    sf4:Hide()

    f.content = content; f.scrollFrame = sf
    f.editContent = editContent; f.editScrollFrame = sf2
    f.mlContent = mlContent; f.mlScrollFrame = sf3
    f.allBisContent = allBisContent; f.allBisScrollFrame = sf4
    mainFrame = f
    tinsert(UISpecialFrames, "BiSTrackerMainFrame")
    BiSTracker_RefreshList()
    f:Show()
end

-- ============================================================
-- GUI: CHARACTER LIST
-- ============================================================

-- x positions for the 9 FontString columns inside each row frame
local HEADER_COL = { 0, 114, 248, 292, 332, 372, 412, 452, 489, 539 }

local mainEmptyRow = nil

-- Pooled Main-list realm header (dark grey bar, realm name, collapse toggle).
local function GetOrCreateRealmHeader(idx)
    local rh = realmHeaderPool[idx]
    if not rh then
        rh = CreateFrame("Frame", nil, mainFrame.content)
        rh.bg = rh:CreateTexture(nil, "BACKGROUND"); rh.bg:SetAllPoints()
        -- Collapse toggle on the left (distinct from the per-character toggle on the right).
        rh.toggleBtn = CreateFrame("Button", nil, rh, "UIPanelButtonTemplate")
        rh.toggleBtn:SetWidth(26); rh.toggleBtn:SetHeight(18)
        rh.toggleBtn:SetPoint("LEFT", rh, "LEFT", 4, 0)
        -- Realm name floats left next to the toggle.
        rh.lbl = rh:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rh.lbl:SetPoint("LEFT", rh.toggleBtn, "RIGHT", 6, 0); rh.lbl:SetJustifyH("LEFT")
        realmHeaderPool[idx] = rh
    end
    return rh
end

function BiSTracker_RefreshList()
    if not mainFrame then return end
    local content = mainFrame.content

    for _, row   in ipairs(rowPool)        do row:Hide()   end
    for _, rh    in ipairs(realmHeaderPool) do rh:Hide()    end
    for _, panel in pairs(detailPanels)    do panel:Hide() end
    if mainEmptyRow then mainEmptyRow:Hide() end

    EnsureCharOrders()

    -- Group characters by realm; sort each realm's chars by their order field.
    local byRealm, total = {}, 0
    for k, v in pairs(BiSTrackerDB.characters) do
        local realm = GetRealmFromKey(k)
        byRealm[realm] = byRealm[realm] or {}
        table.insert(byRealm[realm], { key=k, data=v })
        total = total + 1
    end
    for _, list in pairs(byRealm) do
        table.sort(list, function(a, b) return (a.data.order or 0) < (b.data.order or 0) end)
    end
    local realms = GetSortedRealms()

    local y      = -2
    local rowIdx = 0
    local rhIdx  = 0

    for _, realm in ipairs(realms) do
        local list = byRealm[realm] or {}

        -- Realm-group header.
        rhIdx = rhIdx + 1
        local rh = GetOrCreateRealmHeader(rhIdx)
        rh:SetWidth(632); rh:SetHeight(REALM_HDR_H)
        rh:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        rh.bg:SetTexture(0, 0, 0, 1)
        rh.lbl:SetText(COLOR.legendary .. (realm ~= "" and realm or "Unknown Realm") .. "|r")
        local collapsed = collapsedRealms[realm]
        rh.toggleBtn:SetText(collapsed and "v" or "^")
        local capturedRealm = realm
        rh.toggleBtn:SetScript("OnClick", function()
            collapsedRealms[capturedRealm] = not collapsedRealms[capturedRealm]
            BiSTracker_RefreshList()
        end)
        rh:Show()
        y = y - REALM_HDR_H

        if collapsed then list = {} end -- collapsed realm: render no character rows

    for _, entry in ipairs(list) do
        rowIdx = rowIdx + 1
        local charKey    = entry.key
        local charData   = entry.data
        local isExpanded = expandedChars[charKey]
        local activeSpec = charData.activeSpec or "Unknown"
        local specColor  = GetActiveColor(charData)

        local row = rowPool[rowIdx]
        if not row then
            row = CreateFrame("Frame", nil, content)
            row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints()
            row.lbls = {}
            local RW = { 60, 121, 36, 36, 36, 36, 36, 36, 50, 50 }  -- per-column widths; cols 1-2 left, rest centered
            for i = 1, 10 do
                local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                lbl:SetPoint("LEFT", row, "LEFT", HEADER_COL[i] + 4, 0)
                lbl:SetWidth(RW[i])
                lbl:SetJustifyH(i <= 2 and "LEFT" or "CENTER")
                row.lbls[i] = lbl
            end
            -- Lock status icons for columns 3-8
            row.lockIcons = {}
            local lockColX = { 248, 292, 332, 372, 412, 452 }
            for li = 1, 6 do
                local tex = row:CreateTexture(nil, "OVERLAY")
                tex:SetPoint("TOPLEFT",     row, "TOPLEFT", lockColX[li] + 10, -3)
                tex:SetPoint("BOTTOMRIGHT", row, "TOPLEFT", lockColX[li] + 26, -19)
                tex:SetBlendMode("BLEND")
                row.lockIcons[li] = tex
            end
            -- Toggle expand/collapse button
            row.toggleBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.toggleBtn:SetWidth(26); row.toggleBtn:SetHeight(18)
            row.toggleBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            -- Cycle spec button
            row.cycleBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.cycleBtn:SetWidth(22); row.cycleBtn:SetHeight(16)
            row.cycleBtn:SetPoint("LEFT", row, "LEFT", 90, 0)
            table.insert(rowPool, row)
        end

        row:SetWidth(632); row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        row:Show()

        local hex = specColor
        local rr  = (tonumber(hex:sub(1,2), 16) or 68) / 255
        local gg  = (tonumber(hex:sub(3,4), 16) or 68) / 255
        local bb  = (tonumber(hex:sub(5,6), 16) or 68) / 255
        row.bg:SetTexture(rr*0.4, gg*0.4, bb*0.4, (rowIdx % 2 == 0) and 0.45 or 0.30)

        row.lbls[1]:SetText("|cff" .. specColor .. (charData.name or "?") .. "|r")
        row.lbls[2]:SetText(activeSpec)
        -- Lock columns 3-8, one per INSTANCES entry (single source of truth for the keys)
        for i, inst in ipairs(INSTANCES) do
            row.lbls[2+i]:SetText("")
            local icon = row.lockIcons[i]
            if charData.locks and charData.locks[inst.key] then
                icon:SetTexture("Interface\\AddOns\\BiSTracker\\images\\no.tga")
            else
                icon:SetTexture("Interface\\AddOns\\BiSTracker\\images\\yes.tga")
            end
            icon:Show()
        end
        local total, hasBiS = GetBiSStatusForChar(charKey)
        row.lbls[9]:SetText(FormatBiSScore(hasBiS, total))
        local activeSpecData = charData.specs and charData.activeSpec and charData.specs[charData.activeSpec]
        local gs = (activeSpecData and activeSpecData.gearScore) or 0
        row.lbls[10]:SetText(gs > 0 and ("|cff" .. GetGearScoreColor(gs) .. gs .. "|r") or (COLOR.grey .. "-|r"))

        -- Toggle expand button
        row.toggleBtn:SetText(isExpanded and "^" or "v")
        local capturedKey = charKey
        row.toggleBtn:SetScript("OnClick", function()
            expandedChars[capturedKey] = not expandedChars[capturedKey]
            BiSTracker_RefreshList()
        end)

        -- Cycle spec button
        row.cycleBtn:SetText(">")
        row.cycleBtn:Show()
        if CountSpecs(charData) > 1 then
            row.cycleBtn:Enable()
            local capturedKey2 = charKey
            row.cycleBtn:SetScript("OnClick", function()
                local char = BiSTrackerDB.characters[capturedKey2]
                if not char or not char.specs then return end
                local names = {}
                for n in pairs(char.specs) do table.insert(names, n) end
                table.sort(names)
                local curIdx = 1
                for i, n in ipairs(names) do
                    if n == char.activeSpec then curIdx = i; break end
                end
                char.activeSpec = names[(curIdx % #names) + 1]
                if detailPanels[capturedKey2] then detailPanels[capturedKey2]:Hide() end
                BiSTracker_RefreshList()
            end)
        else
            row.cycleBtn:Disable()
            row.cycleBtn:SetScript("OnClick", nil)
        end

        y = y - ROW_H

        if isExpanded then
            local panel = GetOrCreateDetailPanel(charKey)
            UpdateDetailPanel(panel, charData)
            panel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            panel:Show()
            y = y - panel:GetHeight()
        end
    end -- chars in this realm

    end -- realms

    if total == 0 then
        if not mainEmptyRow then
            mainEmptyRow = CreateFrame("Frame", nil, content)
            mainEmptyRow.lbl = mainEmptyRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            mainEmptyRow.lbl:SetPoint("CENTER")
        end
        mainEmptyRow:SetWidth(632); mainEmptyRow:SetHeight(40)
        mainEmptyRow:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -10)
        mainEmptyRow.lbl:SetText("|cffaaaaaaNo characters tracked yet. Log in with a character.|r")
        mainEmptyRow:Show()
        y = -50
    end

    content:SetHeight(math.abs(y) + 10)
end

-- ============================================================
-- GUI: ALL CLASSES BiS
-- ============================================================

local function GetOrCreateAllBisDetailPanel(specName)
    if allBisDetailPanels[specName] then return allBisDetailPanels[specName] end
    local content = mainFrame.allBisContent
    local panel = CreateFrame("Frame", nil, content)
    panel:SetWidth(632); panel:SetHeight(1)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetTexture(0.05, 0.05, 0.05, 0.72)
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetWidth(1)
    sep:SetPoint("TOPLEFT", panel, "TOPLEFT", DETAIL_COL_X[2] - 5, -3)
    sep:SetTexture(0.35, 0.35, 0.35, 1)
    panel.sep = sep
    panel.lines = {}
    for c = 1, 2 do
        panel.lines[c] = {}
        for r = 1, DETAIL_MAX_LINES[c] do
            local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetJustifyH("LEFT"); lbl:Hide()
            panel.lines[c][r] = lbl
        end
    end
    allBisDetailPanels[specName] = panel
    return panel
end

local function UpdateAllBisDetailPanel(panel, specName)
    for c = 1, 2 do
        for r = 1, DETAIL_MAX_LINES[c] do panel.lines[c][r]:Hide() end
    end
    local specData = ClassesBiS and ClassesBiS[specName]
    if not specData then panel:SetHeight(20); return end

    local COL_W = { DETAIL_COL_X[2] - DETAIL_COL_X[1] - 8, 632 - DETAIL_COL_X[2] - 8 }

    local function WriteEntry(c, lineIdx, yOff, entry)
        local colX     = DETAIL_COL_X[c]
        local slotName = Trim(entry.slot)
        local bisName  = entry.bis and Trim(entry.bis.name) or nil
        local altName  = entry.alt and Trim(entry.alt.name) or nil
        local bisIlvl  = entry.bis and entry.bis.ilvl or 0
        local altIlvl  = entry.alt and entry.alt.ilvl or 0

        if bisName then
            lineIdx = lineIdx + 1
            if lineIdx > DETAIL_MAX_LINES[c] then return lineIdx, yOff end
            local lbl = panel.lines[c][lineIdx]
            lbl:ClearAllPoints()
            lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", colX + 4, yOff)
            lbl:SetWidth(COL_W[c])
            local iStr = (bisIlvl > 0) and " |cffaaaaaa(" .. bisIlvl .. ")|r" or ""
            lbl:SetText("|cffaaaaaa[" .. slotName .. "]|r |cffffcc00" .. bisName .. "|r" .. iStr)
            lbl:Show()
            yOff = yOff - DETAIL_LINE_H
        end

        if altName then
            lineIdx = lineIdx + 1
            if lineIdx > DETAIL_MAX_LINES[c] then return lineIdx, yOff end
            local lbl = panel.lines[c][lineIdx]
            lbl:ClearAllPoints()
            lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", colX + 14, yOff)
            lbl:SetWidth(COL_W[c] - 10)
            local iStr = (altIlvl > 0) and " |cffaaaaaa(" .. altIlvl .. ")|r" or ""
            lbl:SetText("|cffaaaaaa(Alt) " .. altName .. "|r" .. iStr)
            lbl:Show()
            yOff = yOff - DETAIL_LINE_H
        end

        return lineIdx, yOff
    end

    local weapons, armor, col2 = SplitBiSColumns(specData)

    local colHeights = { 0, 0 }
    do
        local lineIdx, yOff = 0, -4
        for _, entry in ipairs(weapons) do lineIdx, yOff = WriteEntry(1, lineIdx, yOff, entry) end
        if #weapons > 0 and #armor > 0 then yOff = yOff - DETAIL_LINE_H end
        for _, entry in ipairs(armor)   do lineIdx, yOff = WriteEntry(1, lineIdx, yOff, entry) end
        colHeights[1] = math.abs(yOff) + 6
    end
    do
        local lineIdx, yOff = 0, -4
        for _, entry in ipairs(col2) do lineIdx, yOff = WriteEntry(2, lineIdx, yOff, entry) end
        colHeights[2] = math.abs(yOff) + 6
    end

    local panelH = math.max(colHeights[1], colHeights[2])
    panel:SetHeight(panelH)
    panel.sep:SetHeight(panelH - 6)
end

function BiSTracker_RefreshAllClassesBis()
    if not mainFrame then return end
    local content = mainFrame.allBisContent

    for _, row   in ipairs(allBisRowPool)        do row:Hide()   end
    for _, panel in pairs(allBisDetailPanels)    do panel:Hide() end

    local rowIdx = 0
    local function GetRow()
        rowIdx = rowIdx + 1
        local row = allBisRowPool[rowIdx]
        if not row then
            row = CreateFrame("Frame", nil, content)
            row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints()
            row.nameLbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.nameLbl:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.countLbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.countLbl:SetPoint("CENTER", row, "CENTER", 0, 0)
            row.countLbl:SetJustifyH("CENTER")
            row.toggleBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.toggleBtn:SetWidth(26); row.toggleBtn:SetHeight(18)
            row.toggleBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            table.insert(allBisRowPool, row)
        end
        return row
    end

    local y = -2
    for _, classKey in ipairs(CLASS_ORDER) do
        local trees = CLASS_TREES[classKey]
        if trees then
            local classSpecs = {}
            for _, specName in ipairs(trees) do
                if ClassesBiS and ClassesBiS[specName] then
                    table.insert(classSpecs, specName)
                end
            end

            if #classSpecs > 0 then
                -- Class header row
                local hdr = GetRow()
                hdr:SetWidth(632); hdr:SetHeight(22)
                hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
                hdr.bg:SetTexture(0.2, 0.2, 0.2, 0.9)
                hdr.nameLbl:SetText(COLOR.legendary .. (CLASS_LABELS[classKey] or classKey) .. "|r")
                hdr.countLbl:SetText("")
                hdr.toggleBtn:Hide()
                hdr:Show()
                y = y - 22

                for sIdx, specName in ipairs(classSpecs) do
                    local specData   = ClassesBiS[specName]
                    local isExpanded = expandedSpecs[specName]

                    local specRow = GetRow()
                    specRow:SetWidth(632); specRow:SetHeight(ROW_H)
                    specRow:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
                    specRow.bg:SetTexture(0.06, 0.06, 0.06, (sIdx % 2 == 0) and 0.50 or 0.35)
                    local specColor = SPEC_COLORS[specName] or "aaaaaa"
                    specRow.nameLbl:SetText("  |cff" .. specColor .. specName .. "|r")
                    specRow.countLbl:SetText("|cffaaaaaa" .. #specData .. " items|r")
                    specRow.toggleBtn:SetText(isExpanded and "^" or "v")
                    specRow.toggleBtn:Show()
                    local capturedSpec = specName
                    specRow.toggleBtn:SetScript("OnClick", function()
                        expandedSpecs[capturedSpec] = not expandedSpecs[capturedSpec]
                        BiSTracker_RefreshAllClassesBis()
                    end)
                    specRow:Show()
                    y = y - ROW_H

                    if isExpanded then
                        local panel = GetOrCreateAllBisDetailPanel(capturedSpec)
                        UpdateAllBisDetailPanel(panel, capturedSpec)
                        panel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
                        panel:Show()
                        y = y - panel:GetHeight()
                    end
                end

                y = y - 4
            end
        end
    end

    content:SetHeight(math.abs(y) + 10)
end
