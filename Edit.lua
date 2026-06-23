-- ============================================================
-- GUI: EDIT LIST
-- ============================================================

local editRowPool  = {}
local editEmptyRow = nil

function BiSTracker_RefreshEditList()
    if not mainFrame then return end
    local content = mainFrame.editContent

    for _, row in ipairs(editRowPool) do row:Hide() end
    if editEmptyRow then editEmptyRow:Hide() end

    EnsureCharOrders()

    -- Build list of all character+spec pairs
    local entries = {}
    for charKey, charData in pairs(BiSTrackerDB.characters) do
        if charData.specs then
            local specNames = {}
            for specName in pairs(charData.specs) do table.insert(specNames, specName) end
            table.sort(specNames)
            for _, specName in ipairs(specNames) do
                table.insert(entries, { key=charKey, data=charData, spec=specName })
            end
        end
    end
    -- Sort by DB insertion order, then spec name within same char
    table.sort(entries, function(a, b)
        local ao = a.data.order or 0
        local bo = b.data.order or 0
        if ao ~= bo then return ao < bo end
        return a.spec < b.spec
    end)

    -- Ordered list of unique char keys (for Up/Down logic)
    local uniqueChars = {}
    local seenKeys = {}
    for _, e in ipairs(entries) do
        if not seenKeys[e.key] then
            seenKeys[e.key] = true
            table.insert(uniqueChars, e.key)
        end
    end

    if #entries == 0 then
        if not editEmptyRow then
            editEmptyRow = CreateFrame("Frame", nil, content)
            editEmptyRow.lbl = editEmptyRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            editEmptyRow.lbl:SetPoint("CENTER")
        end
        editEmptyRow:SetWidth(632); editEmptyRow:SetHeight(40)
        editEmptyRow:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -10)
        editEmptyRow.lbl:SetText("|cffaaaaaaNo characters tracked yet.|r")
        editEmptyRow:Show()
        content:SetHeight(50)
        return
    end

    local prevKey = nil
    local y = -2
    for rowIdx, entry in ipairs(entries) do
        local row = editRowPool[rowIdx]
        if not row then
            row = CreateFrame("Frame", nil, content)
            row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints()
            row.nameLbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.nameLbl:SetPoint("LEFT", row, "LEFT", 8, 0)
            row.nameLbl:SetWidth(138); row.nameLbl:SetJustifyH("LEFT")
            row.specLbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.specLbl:SetPoint("LEFT", row, "LEFT", 190, 0)
            row.specLbl:SetWidth(141); row.specLbl:SetJustifyH("LEFT")
            row.bisLbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.bisLbl:SetPoint("LEFT", row, "LEFT", 326, 0)
            row.bisLbl:SetWidth(50); row.bisLbl:SetJustifyH("CENTER")
            row.upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.upBtn:SetWidth(26); row.upBtn:SetHeight(18)
            row.upBtn:SetPoint("LEFT", row, "LEFT", 440, 0)
            row.upBtn:SetText("^")
            row.downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.downBtn:SetWidth(26); row.downBtn:SetHeight(18)
            row.downBtn:SetPoint("LEFT", row, "LEFT", 469, 0)
            row.downBtn:SetText("v")
            row.deleteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.deleteBtn:SetWidth(60); row.deleteBtn:SetHeight(18)
            row.deleteBtn:SetPoint("LEFT", row, "LEFT", 559, 0)
            row.deleteBtn:SetText("Delete")
            table.insert(editRowPool, row)
        end

        -- Class-colored background
        local cc = entry.data.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.data.class]
        local rr, gg, bb = cc and cc.r or 0.4, cc and cc.g or 0.4, cc and cc.b or 0.4
        row.bg:SetTexture(rr * 0.35, gg * 0.35, bb * 0.35, (rowIdx % 2 == 0) and 0.50 or 0.35)

        local isFirstForChar = (entry.key ~= prevKey)
        prevKey = entry.key

        -- Name: show char name on first spec row, ==> on subsequent rows for same char
        local hexCol = ClassColorHex(entry.data.class)
        if isFirstForChar then
            row.nameLbl:SetText("|cff" .. hexCol .. (entry.data.name or "?") .. "|r")
        else
            row.nameLbl:SetText("|cffaaaaaa   ==>|r")
        end
        row.specLbl:SetText(entry.spec)

        -- BiS count
        local total, hasBiS = GetBiSStatusForChar(entry.key, entry.spec)
        row.bisLbl:SetText(FormatBiSScore(hasBiS, total))

        -- Up/Down buttons only on first spec row per character
        local capturedKey = entry.key
        if isFirstForChar then
            local charIdx = 0
            for idx, ck in ipairs(uniqueChars) do
                if ck == entry.key then charIdx = idx; break end
            end
            if charIdx <= 1            then row.upBtn:Disable()   else row.upBtn:Enable()   end
            if charIdx >= #uniqueChars then row.downBtn:Disable() else row.downBtn:Enable() end
            row.upBtn:Show(); row.downBtn:Show()
            local capturedIdx    = charIdx
            local capturedUnique = uniqueChars
            row.upBtn:SetScript("OnClick", function()
                local above = BiSTrackerDB.characters[capturedUnique[capturedIdx - 1]]
                local self_ = BiSTrackerDB.characters[capturedKey]
                if above and self_ then above.order, self_.order = self_.order, above.order end
                BiSTracker_RefreshEditList()
            end)
            row.downBtn:SetScript("OnClick", function()
                local below = BiSTrackerDB.characters[capturedUnique[capturedIdx + 1]]
                local self_ = BiSTrackerDB.characters[capturedKey]
                if below and self_ then below.order, self_.order = self_.order, below.order end
                BiSTracker_RefreshEditList()
            end)
        else
            row.upBtn:Hide(); row.downBtn:Hide()
        end

        -- Delete button
        local capturedSpec = entry.spec
        row.deleteBtn:SetScript("OnClick", function()
            local char = BiSTrackerDB.characters[capturedKey]
            if not char then return end
            if char.specs then char.specs[capturedSpec] = nil end
            if not next(char.specs or {}) then
                BiSTrackerDB.characters[capturedKey] = nil
            elseif char.activeSpec == capturedSpec then
                for specName in pairs(char.specs) do char.activeSpec = specName; break end
            end
            if detailPanels[capturedKey] then detailPanels[capturedKey]:Hide(); detailPanels[capturedKey] = nil end
            expandedChars[capturedKey] = nil
            BiSTracker_RefreshEditList()
        end)

        row:SetWidth(632); row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        row:Show()
        y = y - ROW_H
    end

    content:SetHeight(math.abs(y) + 10)
end
