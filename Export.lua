-- ============================================================
-- EXPORT
-- ============================================================

local exportFrame = nil

-- Strip export delimiters from a free-text item name so they can't break parsing.
local function SanitizeName(name)
    return (tostring(name or ""):gsub("[%-;|~]", " "))  -- "~" is the checksum delimiter
end

-- Keyed polynomial checksum. Must match the Apps Script importer's checksum_()
-- (P = 2^31-1 keeps h*257 in Lua's exact double range, so Lua and JS agree).
local function ExportChecksum(s)
    local P, h = 2147483647, 0
    for i = 1, #s do
        h = (h * 257 + s:byte(i)) % P
    end
    return h
end

-- Export value for one slot: equipped item ID ("0" if empty; sanitized name only as a
-- fallback when an item has no ID). The sheet decides BiS/Alt/Other by matching the ID.
local function GetSlotExportValue(gearSlotName, gear)
    local it = gear and gear[gearSlotName]
    if not it then return "0" end
    local id = it.id or 0
    return id > 0 and tostring(id) or SanitizeName(it.name)
end

function BiSTracker_ShowExportFrame()
    -- One "|"-joined entry per char-spec; each is 4 ";"-fields:
    -- Name.Spec.Realm ; 17 gear IDs ("-") ; GearScore ; 6-bit lock binary.
    local charList = {}
    for charKey, charData in pairs(BiSTrackerDB.characters) do
        table.insert(charList, { key=charKey, data=charData })
    end
    -- Grouped by realmOrder, then char.order within each realm — drives the sheet's
    -- "Account - Realm" block layout.
    EnsureRealmOrders()
    local realmOrder = BiSTrackerDB.realmOrder or {}
    table.sort(charList, function(a, b)
        local ra = realmOrder[GetRealmFromKey(a.key)] or math.huge
        local rb = realmOrder[GetRealmFromKey(b.key)] or math.huge
        if ra ~= rb then return ra < rb end
        local ao, bo = a.data.order or math.huge, b.data.order or math.huge
        if ao ~= bo then return ao < bo end
        return (a.data.name or "") < (b.data.name or "")
    end)

    local charStrings = {}
    for _, entry in ipairs(charList) do
        local d = entry.data
        -- Sorted spec names for stable ordering
        local specNames = {}
        if d.specs then
            for specName in pairs(d.specs) do table.insert(specNames, specName) end
            table.sort(specNames)
        end
        for _, specName in ipairs(specNames) do
            local specEntry = d.specs[specName]
            -- Spec spaces → "-" (e.g. "Marksman Hunter" → "Marksman-Hunter"); importer reverses.
            local specLabel = (specName:gsub(" ", "-"))

            -- Name.Spec.Realm ("." separated); realm from the char key, class is in the spec.
            local realm = (entry.key:match("^.-%-(.+)$") or GetRealmName() or ""):gsub("[%.;|]", "")
            local info  = table.concat({ d.name or "?", specLabel, realm }, ".")

            -- 17 gear slots (GEAR_SLOTS order), each the equipped item ID; "-" separated.
            local gear      = specEntry.gear or {}
            local gearParts = {}
            for _, slot in ipairs(GEAR_SLOTS) do
                table.insert(gearParts, GetSlotExportValue(slot.name, gear))
            end
            local gearStr = table.concat(gearParts, "-")

            -- GearScore of the last-scanned equipped gear (per-spec).
            local gsStr = tostring(math.floor((specEntry.gearScore or 0)))

            -- 6-bit lock binary (1=locked), INSTANCES order: ICC25,ICC10,RS25,RS10,TOC25,TOC10.
            local locks     = d.locks
            local lockParts = {}
            for _, inst in ipairs(INSTANCES) do
                table.insert(lockParts, (locks and locks[inst.key]) and "1" or "0")
            end
            local lockStr = table.concat(lockParts)

            table.insert(charStrings, info .. ";" .. gearStr .. ";" .. gsStr .. ";" .. lockStr)
        end
    end

    -- Format: "<account>;<entries>~<checksum>". The alias (or "NoAccName") lets the sheet
    -- group by account; the checksum covers the whole payload so tampered strings are rejected.
    local exportStr
    if #charStrings > 0 then
        local accLabel = (BiSTrackerDB.accountAlias or ""):gsub("[;|~]", " ")
        accLabel = Trim(accLabel)
        if accLabel == "" then accLabel = "NoAccName" end
        -- Encode spaces as "^" so a space can't visually split the export in the sheet
        -- textbox (importer decodes "^"→space); a literal "^" is normalized to a space first.
        accLabel = accLabel:gsub("%^", " "):gsub(" ", "^")
        local payload = accLabel .. ";" .. table.concat(charStrings, "|")
        exportStr = payload .. "~" .. tostring(ExportChecksum(EXPORT_SECRET .. payload))
    else
        exportStr = "(No characters tracked)"
    end

    if exportFrame then
        exportFrame.eb:SetText(exportStr)
        exportFrame.eb:HighlightText()
        exportFrame:Show()
        return
    end

    local ef = CreateFrame("Frame", "BiSTrackerExportFrame", UIParent)
    ef:SetWidth(560); ef:SetHeight(154)
    -- Sit above the main window with a little gap (fall back to screen center).
    if mainFrame then
        ef:SetPoint("BOTTOM", mainFrame, "TOP", 0, 8)
    else
        ef:SetPoint("CENTER", UIParent, "CENTER")
    end
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
    ef:SetBackdropColor(0, 0, 0, 1) -- near-opaque window background

    local title = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", ef, "TOP", 0, -14); title:SetText("Export String for the Spreadsheet")

    local closeBtn = CreateFrame("Button", nil, ef, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", ef, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() ef:Hide() end)

    local hint = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", ef, "TOP", 0, -38)
    hint:SetText("|cffaaaaaaPress Ctrl+C to copy the text below|r")

    -- A WoW EditBox doesn't clip its selection, so HighlightText() spills past the box;
    -- hosting it in a ScrollFrame clips it and adds scrolling for long strings.
    local sf = CreateFrame("ScrollFrame", "BiSTrackerExportScroll", ef, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", ef, "TOPLEFT", 16, -66)
    sf:SetWidth(504); sf:SetHeight(46)

    local sfBg = sf:CreateTexture(nil, "BACKGROUND")
    sfBg:SetAllPoints(); sfBg:SetTexture(1, 1, 1, 0.05)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetMaxLetters(99999)
    eb:SetWidth(484); eb:SetHeight(46) -- narrower than sf so text clears the scrollbar
    eb:SetFontObject(ChatFontNormal); eb:SetAutoFocus(true); eb:EnableMouse(true)
    eb:SetTextColor(1, 1, 1) -- white text, readable over the dark window background
    eb:SetTextInsets(4, 4, 4, 4)
    eb:SetScript("OnEscapePressed", function() ef:Hide() end)
    -- Blizzard scrolling-edit helpers keep the scroll range correct; guarded in case absent.
    if ScrollingEdit_OnTextChanged then
        eb:SetScript("OnTextChanged",   function(self) ScrollingEdit_OnTextChanged(self, sf) end)
        eb:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
        sf:SetScript("OnUpdate",        function(self, elapsed) ScrollingEdit_OnUpdate(eb, elapsed, self) end)
    end
    sf:SetScrollChild(eb)
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
