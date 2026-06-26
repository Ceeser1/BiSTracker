-- ============================================================
-- GUI: EDIT LIST
-- ============================================================

local editRowPool         = {}
local editRealmHeaderPool = {}   -- Edit list realm-group header rows (pooled by index)
local editEmptyRow        = nil

local REALM_HDR_H = 22           -- height of a realm-group header row

-- Pooled realm-group header for the Edit list: dark grey bar, centered realm name,
-- Up/Down buttons to move the whole realm (and all its characters) in export order.
local function GetOrCreateEditRealmHeader(idx)
    local rh = editRealmHeaderPool[idx]
    if not rh then
        rh = CreateFrame("Frame", nil, mainFrame.editContent)
        rh.bg = rh:CreateTexture(nil, "BACKGROUND"); rh.bg:SetAllPoints()
        -- Left side (same offset as the character-name column) to keep the realm
        -- move controls distinct from the per-character Up/Down on the right.
        rh.upBtn = CreateFrame("Button", nil, rh, "UIPanelButtonTemplate")
        rh.upBtn:SetWidth(26); rh.upBtn:SetHeight(18)
        rh.upBtn:SetPoint("LEFT", rh, "LEFT", 4, 0); rh.upBtn:SetText("^")
        rh.downBtn = CreateFrame("Button", nil, rh, "UIPanelButtonTemplate")
        rh.downBtn:SetWidth(26); rh.downBtn:SetHeight(18)
        rh.downBtn:SetPoint("LEFT", rh.upBtn, "RIGHT", 3, 0); rh.downBtn:SetText("v")
        -- Realm name floats left next to the button(s); anchored per-refresh
        -- (depends on whether the move buttons are shown).
        rh.lbl = rh:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rh.lbl:SetJustifyH("LEFT")
        editRealmHeaderPool[idx] = rh
    end
    return rh
end

function BiSTracker_RefreshEditList()
    if not mainFrame then return end
    local content = mainFrame.editContent

    for _, row in ipairs(editRowPool)         do row:Hide() end
    for _, rh  in ipairs(editRealmHeaderPool) do rh:Hide()  end
    if editEmptyRow then editEmptyRow:Hide() end

    EnsureCharOrders()

    -- Group characters by realm; sort each realm's chars by their order field.
    local byRealm, total = {}, 0
    for charKey, charData in pairs(BiSTrackerDB.characters) do
        if charData.specs then
            local realm = GetRealmFromKey(charKey)
            byRealm[realm] = byRealm[realm] or {}
            table.insert(byRealm[realm], { key=charKey, data=charData })
            total = total + 1
        end
    end
    for _, list in pairs(byRealm) do
        table.sort(list, function(a, b) return (a.data.order or 0) < (b.data.order or 0) end)
    end
    local realms     = GetSortedRealms()
    local multiRealm = (#realms > 1)

    if total == 0 then
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

    local y      = -2
    local rowIdx = 0
    local rhIdx  = 0

    for realmIdx, realm in ipairs(realms) do
        local charList = byRealm[realm] or {}

        -- Ordered unique char keys within this realm (for the char Up/Down swap).
        local realmCharKeys = {}
        for _, c in ipairs(charList) do table.insert(realmCharKeys, c.key) end

        -- Realm-group header with Up/Down (only when more than one realm exists).
        rhIdx = rhIdx + 1
        local rh = GetOrCreateEditRealmHeader(rhIdx)
        rh:SetWidth(632); rh:SetHeight(REALM_HDR_H)
        rh:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        rh.bg:SetTexture(0, 0, 0, 1)
        rh.lbl:SetText(COLOR.legendary .. (realm ~= "" and realm or "Unknown Realm") .. "|r")
        if multiRealm then
            rh.upBtn:Show(); rh.downBtn:Show()
            if realmIdx <= 1        then rh.upBtn:Disable()   else rh.upBtn:Enable()   end
            if realmIdx >= #realms  then rh.downBtn:Disable() else rh.downBtn:Enable() end
            local capR, capRealms, capIdx = realm, realms, realmIdx
            local function swapRealm(otherRealm)
                if not otherRealm then return end
                local ro = BiSTrackerDB.realmOrder
                ro[capR], ro[otherRealm] = ro[otherRealm], ro[capR]
                BiSTracker_RefreshEditList()
            end
            rh.upBtn:SetScript("OnClick",   function() swapRealm(capRealms[capIdx - 1]) end)
            rh.downBtn:SetScript("OnClick", function() swapRealm(capRealms[capIdx + 1]) end)
        else
            rh.upBtn:Hide(); rh.downBtn:Hide()
        end
        -- Realm name left-floated: next to the move buttons (6px gap) when shown,
        -- else at the character-name offset (x=4) so it still floats left.
        rh.lbl:ClearAllPoints()
        if multiRealm then
            rh.lbl:SetPoint("LEFT", rh.downBtn, "RIGHT", 6, 0)
        else
            rh.lbl:SetPoint("LEFT", rh, "LEFT", 4, 0)
        end
        rh:Show()
        y = y - REALM_HDR_H

        -- Character + spec rows for this realm.
        for _, c in ipairs(charList) do
            local entryKey  = c.key
            local charData  = c.data
            local specNames = {}
            for specName in pairs(charData.specs) do table.insert(specNames, specName) end
            table.sort(specNames)

            for sIdx, specName in ipairs(specNames) do
                rowIdx = rowIdx + 1
                local row = editRowPool[rowIdx]
                if not row then
                    row = CreateFrame("Frame", nil, content)
                    row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints()
                    row.nameLbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    row.nameLbl:SetPoint("LEFT", row, "LEFT", 4, 0)
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
                    row.deleteBtn:SetPoint("LEFT", row, "LEFT", 563, 0)
                    row.deleteBtn:SetText("Delete")
                    table.insert(editRowPool, row)
                end

                -- Class-colored background
                local cc = charData.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[charData.class]
                local rr, gg, bb = cc and cc.r or 0.4, cc and cc.g or 0.4, cc and cc.b or 0.4
                row.bg:SetTexture(rr * 0.35, gg * 0.35, bb * 0.35, 0.35)

                local isFirstForChar = (sIdx == 1)

                -- Name: char name on first spec row, ==> on subsequent rows for same char
                local hexCol = ClassColorHex(charData.class)
                if isFirstForChar then
                    row.nameLbl:SetText("|cff" .. hexCol .. (charData.name or "?") .. "|r")
                else
                    row.nameLbl:SetText("|cffaaaaaa   ==>|r")
                end
                row.specLbl:SetText(specName)

                -- BiS count
                local bisTotal, hasBiS = GetBiSStatusForChar(entryKey, specName)
                row.bisLbl:SetText(FormatBiSScore(hasBiS, bisTotal))

                -- Up/Down buttons only on first spec row per character; they reorder
                -- characters WITHIN this realm (swap order with the adjacent char).
                local capturedKey = entryKey
                if isFirstForChar then
                    local charIdx = 0
                    for idx, ck in ipairs(realmCharKeys) do
                        if ck == entryKey then charIdx = idx; break end
                    end
                    if charIdx <= 1               then row.upBtn:Disable()   else row.upBtn:Enable()   end
                    if charIdx >= #realmCharKeys  then row.downBtn:Disable() else row.downBtn:Enable() end
                    row.upBtn:Show(); row.downBtn:Show()
                    local capturedIdx    = charIdx
                    local capturedKeys   = realmCharKeys
                    row.upBtn:SetScript("OnClick", function()
                        local above = BiSTrackerDB.characters[capturedKeys[capturedIdx - 1]]
                        local self_ = BiSTrackerDB.characters[capturedKey]
                        if above and self_ then above.order, self_.order = self_.order, above.order end
                        BiSTracker_RefreshEditList()
                    end)
                    row.downBtn:SetScript("OnClick", function()
                        local below = BiSTrackerDB.characters[capturedKeys[capturedIdx + 1]]
                        local self_ = BiSTrackerDB.characters[capturedKey]
                        if below and self_ then below.order, self_.order = self_.order, below.order end
                        BiSTracker_RefreshEditList()
                    end)
                else
                    row.upBtn:Hide(); row.downBtn:Hide()
                end

                -- Delete button
                local capturedSpec = specName
                row.deleteBtn:SetScript("OnClick", function()
                    local char = BiSTrackerDB.characters[capturedKey]
                    if not char then return end
                    if char.specs then char.specs[capturedSpec] = nil end
                    if not next(char.specs or {}) then
                        BiSTrackerDB.characters[capturedKey] = nil
                    elseif char.activeSpec == capturedSpec then
                        for sn in pairs(char.specs) do char.activeSpec = sn; break end
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
        end
    end

    content:SetHeight(math.abs(y) + 10)
end
