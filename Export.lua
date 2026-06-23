-- ============================================================
-- EXPORT
-- ============================================================

local exportFrame = nil

-- "0"=empty, "1"=BiS, "2"=Alt, "ItemID"=other (name resolved later; name only if no ID)
-- Strip the export delimiters from a free-text item name so they can't break parsing.
local function SanitizeName(name)
    return (tostring(name or ""):gsub("[%-;|]", " "))
end

local function GetSlotExportValue(gearSlotName, gear, specName)
    local equipped = gear and gear[gearSlotName]
    if not equipped then return "0" end

    local specData = BiSTrackerData and BiSTrackerData.BiS and BiSTrackerData.BiS[specName]
    if not specData then
        local id = equipped.id or 0
        -- ID-only for "other" items (name resolved later via Wowhead);
        -- fall back to the sanitized name only if no ID is available.
        return id > 0 and tostring(id) or SanitizeName(equipped.name)
    end

    local function slotMatches(entrySlot)
        if gearSlotName == "Ring 1" or gearSlotName == "Ring 2" then return entrySlot == "Ring"
        elseif gearSlotName == "Trinket 1" or gearSlotName == "Trinket 2" then return entrySlot == "Trinket"
        elseif gearSlotName == "Off Hand" then return entrySlot == "Off Hand" or entrySlot == "Shield"
        elseif gearSlotName == "Ranged" then return RANGED_SLOTS[entrySlot] == true
        else return entrySlot == gearSlotName end
    end

    local equippedName = Trim(equipped.name)
    for _, entry in ipairs(specData) do
        if slotMatches(Trim(entry.slot)) then
            if entry.bis and Trim(entry.bis.name) == equippedName then return "1" end
            if entry.alt and Trim(entry.alt.name) == equippedName then return "2" end
        end
    end

    local id = equipped.id or 0
    -- ID-only for "other" items (name resolved later via Wowhead);
    -- fall back to the sanitized name only if no ID is available.
    return id > 0 and tostring(id) or SanitizeName(equipped.name)
end

function BiSTracker_ShowExportFrame()
    -- Build export string: one entry per character-spec combination, separated by |
    -- Each entry has 3 ";"-separated sections:
    --   1) Name.Spec              ("." separated; class is implied by the spec)
    --   2) 17 gear slots          ("-" separated, GEAR_SLOTS order)
    --   3) 6-bit lock binary      (ICC25,ICC10,RS25,RS10,TOC25,TOC10; 1=locked)
    local charList = {}
    for charKey, charData in pairs(BiSTrackerDB.characters) do
        table.insert(charList, { key=charKey, data=charData })
    end
    table.sort(charList, function(a, b) return (a.data.name or "") < (b.data.name or "") end)

    local charStrings = {}
    for _, entry in ipairs(charList) do
        local d = entry.data
        -- Sorted spec names for consistent ordering
        local specNames = {}
        if d.specs then
            for specName in pairs(d.specs) do table.insert(specNames, specName) end
            table.sort(specNames)
        end
        for _, specName in ipairs(specNames) do
            local specEntry = d.specs[specName]
            local specLabel = SPEC_EXPORT[specName] or specName

            -- Section 1: character info, "." separated (Name.Spec).
            -- Spec lives here so its "-" never collides with the gear split.
            -- Class is omitted: it's already encoded in the spec label suffix.
            local info = table.concat({ d.name or "?", specLabel }, ".")

            -- Section 2: 17 gear slots, "-" separated (GEAR_SLOTS order).
            local gear      = specEntry.gear or {}
            local gearParts = {}
            for _, slot in ipairs(GEAR_SLOTS) do
                table.insert(gearParts, GetSlotExportValue(slot.name, gear, specName))
            end
            local gearStr = table.concat(gearParts, "-")

            -- Section 3: 6-bit instance-lock binary (1=locked, 0=free).
            -- Order follows INSTANCES: ICC25, ICC10, RS25, RS10, TOC25, TOC10.
            local locks     = d.locks
            local lockParts = {}
            for _, inst in ipairs(INSTANCES) do
                table.insert(lockParts, (locks and locks[inst.key]) and "1" or "0")
            end
            local lockStr = table.concat(lockParts)

            table.insert(charStrings, info .. ";" .. gearStr .. ";" .. lockStr)
        end
    end

    local exportStr = (#charStrings > 0) and table.concat(charStrings, "|") or "(No characters tracked)"

    if exportFrame then
        exportFrame.eb:SetText(exportStr)
        exportFrame.eb:HighlightText()
        exportFrame:Show()
        return
    end

    local ef = CreateFrame("Frame", "BiSTrackerExportFrame", UIParent)
    ef:SetWidth(560); ef:SetHeight(310)
    ef:SetPoint("CENTER", UIParent, "CENTER")
    ef:SetFrameStrata("TOOLTIP")
    ef:SetMovable(true); ef:EnableMouse(true)
    ef:RegisterForDrag("LeftButton")
    ef:SetScript("OnDragStart", ef.StartMoving)
    ef:SetScript("OnDragStop",  ef.StopMovingOrSizing)
    ef:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize=26, insets={left=9,right=9,top=9,bottom=9},
    })

    local title = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", ef, "TOP", 0, -14); title:SetText("Export String")

    local closeBtn = CreateFrame("Button", nil, ef, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", ef, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() ef:Hide() end)

    local hint = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", ef, "TOPLEFT", 16, -40)
    hint:SetText("|cffaaaaaa Press Ctrl+C to copy the text.|r")

    local eb = CreateFrame("EditBox", nil, ef)
    eb:SetMultiLine(true); eb:SetMaxLetters(99999)
    eb:SetWidth(524); eb:SetHeight(210)
    eb:SetPoint("TOPLEFT", ef, "TOPLEFT", 16, -58)
    eb:SetFontObject(ChatFontNormal); eb:SetAutoFocus(true); eb:EnableMouse(true)
    local ebBg = eb:CreateTexture(nil, "BACKGROUND")
    ebBg:SetAllPoints(); ebBg:SetTexture(0, 0, 0, 0.6)
    eb:SetText(exportStr); eb:HighlightText()

    -- Done button below the text field
    local doneBtn = CreateFrame("Button", nil, ef, "UIPanelButtonTemplate")
    doneBtn:SetWidth(80); doneBtn:SetHeight(22)
    doneBtn:SetPoint("BOTTOM", ef, "BOTTOM", 0, 14)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function() ef:Hide() end)

    ef.eb      = eb
    exportFrame = ef
    tinsert(UISpecialFrames, "BiSTrackerExportFrame")
    ef:Show()
end
