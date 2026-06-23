-- ============================================================
-- GUI: MINIMAP BUTTON
-- ============================================================

local minimapButton = nil

function CreateMinimapButton()
    local btn = CreateFrame("Button", "BiSTrackerMinimapBtn", Minimap)
    btn:SetWidth(31); btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM"); btn:SetFrameLevel(8)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\BiSTracker\\images\\icon.tga")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("CENTER", btn, "CENTER", 1, -1)

    local borderTex = btn:CreateTexture(nil, "OVERLAY")
    borderTex:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    borderTex:SetWidth(56); borderTex:SetHeight(56)
    borderTex:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    local function UpdatePos(angle)
        BiSTrackerDB.minimapAngle = angle
        BiSTrackerDB.minimapFree  = nil
        btn:SetParent(Minimap)
        btn:ClearAllPoints()
        local edge = Minimap:GetWidth() / 2 + 5
        local rad  = math.rad(angle)
        local c    = math.cos(rad)
        local s    = math.sin(rad)
        local x, y
        if GetMinimapShape and GetMinimapShape() == "SQUARE" then
            local sqEdge = edge * 0.95
            local m = math.max(math.abs(c), math.abs(s))
            x = (m > 0) and (c / m * sqEdge) or 0
            y = (m > 0) and (s / m * sqEdge) or 0
        else
            x = c * edge
            y = s * edge
        end
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    -- Restore the saved position. Called at creation AND again on PLAYER_ENTERING_WORLD,
    -- because at ADDON_LOADED the minimap's final width and shape (GetMinimapShape, set by
    -- other addons that load later) aren't reliable yet, which would land the icon off-spot.
    local function ApplyPosition()
        if BiSTrackerDB.minimapFree and BiSTrackerDB.minimapFreeX then
            btn:SetParent(UIParent)
            btn:ClearAllPoints()
            btn:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
                BiSTrackerDB.minimapFreeX, BiSTrackerDB.minimapFreeY)
        else
            UpdatePos(BiSTrackerDB.minimapAngle or 45)
        end
    end
    ApplyPosition()
    BiSTracker_UpdateMinimapPosition = ApplyPosition

    btn:RegisterForClicks("LeftButtonUp")
    btn:SetScript("OnClick", function()
        if IsShiftKeyDown() or IsControlKeyDown() then return end
        if mainFrame and mainFrame:IsShown() then mainFrame:Hide()
        else BiSTracker_ShowMainFrame() end
    end)

    local dragMode = nil
    btn:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if IsShiftKeyDown() then
            dragMode = "shift"
            btn:SetParent(Minimap)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local scale  = btn:GetEffectiveScale()
                local cx, cy = GetCursorPosition()
                UpdatePos(math.deg(math.atan2((cy / scale) - my, (cx / scale) - mx)))
            end)
        elseif IsControlKeyDown() then
            dragMode = "ctrl"
            self:SetScript("OnUpdate", function()
                local scale = UIParent:GetEffectiveScale()
                local cx, cy = GetCursorPosition()
                btn:ClearAllPoints()
                btn:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
            end)
        else
            dragMode = nil
        end
    end)
    btn:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self:SetScript("OnUpdate", nil)
        if dragMode == "ctrl" then
            local scale = UIParent:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            local x, y = cx / scale, cy / scale
            btn:SetParent(UIParent)
            btn:ClearAllPoints()
            btn:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
            BiSTrackerDB.minimapFreeX = x
            BiSTrackerDB.minimapFreeY = y
            BiSTrackerDB.minimapFree  = true
        end
        dragMode = nil
    end)

    -- Custom table tooltip frame (created once, refreshed on hover)
    local TIP_PAD    = 6
    local COL_W_NAME = 90
    local COL_W_INST = 38
    local ROW_H      = 16
    local TITLE_H    = 20
    local ICON_SIZE  = 12
    local NUM_INST   = #INSTANCES
    local FRAME_W    = TIP_PAD * 2 + COL_W_NAME + NUM_INST * COL_W_INST

    local tipFrame = CreateFrame("Frame", nil, UIParent)
    tipFrame:SetFrameStrata("TOOLTIP")
    tipFrame:SetWidth(FRAME_W)
    tipFrame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    tipFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.8)
    tipFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
    tipFrame:Hide()

    -- Title row
    local titleLbl = tipFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleLbl:SetWidth(FRAME_W - TIP_PAD * 2); titleLbl:SetJustifyH("LEFT")
    titleLbl:SetPoint("TOPLEFT", tipFrame, "TOPLEFT", TIP_PAD, -TIP_PAD)
    titleLbl:SetText(
        "|cffff8000BiS|r Tracker" ..
        "|cffaaaaaa - |r" ..
        "|cffffffffClick to open|r" ..
        "|cffaaaaaa - Shift/Ctrl-Click to drag|r"
    )

    -- Column header row
    local HDR_Y = -(TIP_PAD + TITLE_H + 2)

    -- Instance-lock header widgets (column titles + separator). Collected so they can be
    -- hidden together when the "Minimap Popup" setting only allows the title row.
    local lockHeaderWidgets = {}

    local hdrName = tipFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrName:SetWidth(COL_W_NAME); hdrName:SetJustifyH("LEFT")
    hdrName:SetPoint("TOPLEFT", tipFrame, "TOPLEFT", TIP_PAD, HDR_Y)
    hdrName:SetText("Instance Locks")
    table.insert(lockHeaderWidgets, hdrName)

    for i, inst in ipairs(INSTANCES) do
        local lbl = tipFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetWidth(COL_W_INST); lbl:SetJustifyH("CENTER")
        lbl:SetPoint("TOPLEFT", tipFrame, "TOPLEFT",
            TIP_PAD + COL_W_NAME + (i - 1) * COL_W_INST, HDR_Y)
        lbl:SetText(inst.key)
        table.insert(lockHeaderWidgets, lbl)
    end

    -- Separator below column headers
    local sep2 = tipFrame:CreateTexture(nil, "ARTWORK")
    sep2:SetHeight(1)
    sep2:SetPoint("TOPLEFT",  tipFrame, "TOPLEFT",  TIP_PAD,  -(TIP_PAD + TITLE_H + ROW_H + 3))
    sep2:SetPoint("TOPRIGHT", tipFrame, "TOPRIGHT", -TIP_PAD, -(TIP_PAD + TITLE_H + ROW_H + 3))
    sep2:SetTexture(0.4, 0.4, 0.4, 0.8)
    table.insert(lockHeaderWidgets, sep2)

    -- Pre-allocated data rows
    local DATA_Y0      = TIP_PAD + TITLE_H + ROW_H + 5
    local MAX_TIP_ROWS = 20
    local tipRows = {}
    for r = 1, MAX_TIP_ROWS do
        local yCenter = -(DATA_Y0 + (r - 1) * ROW_H + ROW_H * 0.5)

        local nameLbl = tipFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameLbl:SetWidth(COL_W_NAME); nameLbl:SetJustifyH("LEFT")
        nameLbl:SetPoint("LEFT", tipFrame, "TOPLEFT", TIP_PAD, yCenter)
        nameLbl:Hide()

        local icons = {}
        for i = 1, NUM_INST do
            local cx = TIP_PAD + COL_W_NAME + (i - 1) * COL_W_INST + COL_W_INST * 0.5
            local tex = tipFrame:CreateTexture(nil, "OVERLAY")
            tex:SetWidth(ICON_SIZE); tex:SetHeight(ICON_SIZE)
            tex:SetPoint("CENTER", tipFrame, "TOPLEFT", cx, yCenter)
            tex:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
            tex:Hide()
            table.insert(icons, tex)
        end

        local bg = nil
        if r % 2 == 0 then
            bg = tipFrame:CreateTexture(nil, "BACKGROUND")
            bg:SetTexture(1, 1, 1)
            bg:SetAlpha(0.35)
            bg:SetPoint("TOPLEFT",     tipFrame, "TOPLEFT",   3, -(DATA_Y0 + (r - 1) * ROW_H))
            bg:SetPoint("BOTTOMRIGHT", tipFrame, "TOPRIGHT", -3, -(DATA_Y0 + r * ROW_H))
            bg:Hide()
        end

        table.insert(tipRows, { nameLbl = nameLbl, icons = icons, bg = bg })
    end

    -- Shown when no one is locked
    local noLockLbl = tipFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    noLockLbl:SetWidth(FRAME_W - TIP_PAD * 2); noLockLbl:SetJustifyH("CENTER")
    noLockLbl:SetPoint("TOPLEFT", tipFrame, "TOPLEFT", TIP_PAD, -(DATA_Y0 + ROW_H * 0.5))
    noLockLbl:SetText("|cff55ff55All instances available|r")
    noLockLbl:Hide()

    local function RefreshTip()
        -- Hide the lock table (headers, rows, no-lock label) up front; rebuilt below if shown.
        local showLocks = LS().minimapPopup
        for _, w in ipairs(lockHeaderWidgets) do
            if showLocks then w:Show() else w:Hide() end
        end
        for _, row in ipairs(tipRows) do
            row.nameLbl:Hide()
            for _, icon in ipairs(row.icons) do icon:Hide() end
            if row.bg then row.bg:Hide() end
        end
        noLockLbl:Hide()

        -- Popup disabled: show only the title row (Click to open / drag hints).
        if not showLocks then
            tipFrame:SetHeight(TIP_PAD + TITLE_H + TIP_PAD)
            return
        end

        local lockedChars = {}
        for _, char in pairs(BiSTrackerDB.characters) do
            if char.locks then
                for _, inst in ipairs(INSTANCES) do
                    if char.locks[inst.key] then
                        table.insert(lockedChars, char); break
                    end
                end
            end
        end
        table.sort(lockedChars, function(a, b) return (a.order or 999) < (b.order or 999) end)

        local numRows
        if #lockedChars == 0 then
            noLockLbl:Show()
            numRows = 1
        else
            numRows = math.min(#lockedChars, MAX_TIP_ROWS)
            for r = 1, numRows do
                local char = lockedChars[r]
                local row  = tipRows[r]
                row.nameLbl:SetText("|cff" .. GetActiveColor(char) .. (char.name or "?") .. "|r")
                row.nameLbl:Show()
                if row.bg then row.bg:Show() end
                for i, inst in ipairs(INSTANCES) do
                    if char.locks[inst.key] then row.icons[i]:Show() end
                end
            end
        end

        tipFrame:SetHeight(TIP_PAD + DATA_Y0 + numRows * ROW_H + TIP_PAD)
    end

    btn:SetScript("OnEnter", function()
        RefreshTip()   -- shows title always; lock table only if "Minimap Popup" is enabled
        tipFrame:ClearAllPoints()
        tipFrame:SetPoint("RIGHT", btn, "LEFT", -4, 0)
        tipFrame:Show()
    end)
    btn:SetScript("OnLeave", function() tipFrame:Hide() end)
    minimapButton = btn
end
