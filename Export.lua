-- ============================================================
-- EXPORT
-- ============================================================

local exportFrame = nil

-- "0"=empty, "1"=BiS, "2"=Alt, "ItemID"=other (name resolved later; name only if no ID)
-- Strip the export delimiters from a free-text item name so they can't break parsing.
local function SanitizeName(name)
    return (tostring(name or ""):gsub("[%-;|~]", " "))  -- "~" is the checksum delimiter
end

-- Keyed polynomial checksum over a string (ASCII payload). Must match checksum_()
-- in the Apps Script importer. P = 2^31-1 keeps h*257 within Lua's exact double
-- range, so the result is identical to the JS computation.
local function ExportChecksum(s)
    local P, h = 2147483647, 0
    for i = 1, #s do
        h = (h * 257 + s:byte(i)) % P
    end
    return h
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
    -- Each entry has 4 ";"-separated sections:
    --   1) Name.Spec              ("." separated; class is implied by the spec)
    --   2) 17 gear slots          ("-" separated, GEAR_SLOTS order)
    --   3) GearScore              (integer; 0 if unknown/unscanned)
    --   4) 6-bit lock binary      (ICC25,ICC10,RS25,RS10,TOC25,TOC10; 1=locked)
    local charList = {}
    for charKey, charData in pairs(BiSTrackerDB.characters) do
        table.insert(charList, { key=charKey, data=charData })
    end
    -- Export grouped by realm first (realmOrder — the order realms are arranged in
    -- the Edit Chars list), then by each character's `order` within its realm. The
    -- sheet importer groups characters into "Account - Realm" blocks in the order
    -- each realm first appears, so this realm ordering drives the on-sheet layout.
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
        -- Sorted spec names for consistent ordering
        local specNames = {}
        if d.specs then
            for specName in pairs(d.specs) do table.insert(specNames, specName) end
            table.sort(specNames)
        end
        for _, specName in ipairs(specNames) do
            local specEntry = d.specs[specName]
            -- Spec fully written, spaces → "-" (e.g. "Marksman Hunter" → "Marksman-Hunter").
            -- The importer reverses it by swapping "-" back to spaces.
            local specLabel = (specName:gsub(" ", "-"))

            -- Character info, "." separated (Name.Spec.Realm). Realm comes from the
            -- char key ("Name-Realm"), fully written. Spec/realm "-" never collide
            -- with the gear split; class is encoded in the spec name itself.
            local realm = (entry.key:match("^.-%-(.+)$") or GetRealmName() or ""):gsub("[%.;|]", "")
            local info  = table.concat({ d.name or "?", specLabel, realm }, ".")

            -- 17 gear slots, "-" separated (GEAR_SLOTS order).
            local gear      = specEntry.gear or {}
            local gearParts = {}
            for _, slot in ipairs(GEAR_SLOTS) do
                table.insert(gearParts, GetSlotExportValue(slot.name, gear, specName))
            end
            local gearStr = table.concat(gearParts, "-")

            -- GearScore of the last-scanned equipped gear (per-spec).
            local gsStr = tostring(math.floor((specEntry.gearScore or 0)))

            -- 6-bit instance-lock binary (1=locked, 0=free).
            -- Order follows INSTANCES: ICC25, ICC10, RS25, RS10, TOC25, TOC10.
            local locks     = d.locks
            local lockParts = {}
            for _, inst in ipairs(INSTANCES) do
                table.insert(lockParts, (locks and locks[inst.key]) and "1" or "0")
            end
            local lockStr = table.concat(lockParts)

            table.insert(charStrings, info .. ";" .. gearStr .. ";" .. gsStr .. ";" .. lockStr)
        end
    end

    -- Format: "<account>;<entries>~<checksum>". The account alias (or "NoAccName"
    -- when unset) prefixes the export so the sheet can group characters by account
    -- (split off at the FIRST ";"). The keyed checksum covers the whole
    -- "<account>;<entries>" payload, so a tamper edit changes the hash and the
    -- importer rejects it. Must match Apps Script checksum_(). Delimiter chars are
    -- stripped from the alias so it can't break parsing.
    local exportStr
    if #charStrings > 0 then
        local accLabel = (BiSTrackerDB.accountAlias or ""):gsub("[;|~]", " ")
        accLabel = Trim(accLabel)
        if accLabel == "" then accLabel = "NoAccName" end
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

    -- A WoW EditBox does NOT clip its text/selection to its own frame, so a
    -- multi-line HighlightText() draws the highlight out to the EditBox's full
    -- width, spilling past the visible box. Hosting the EditBox in a ScrollFrame
    -- clips it to the scroll window (highlight stays inside) and adds vertical
    -- scrolling for long strings.
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
    -- Standard Blizzard scrolling-edit helpers (FrameXML, present in 3.3.5a) keep the
    -- scroll range correct and follow the cursor. Guarded so clipping still works
    -- (ScrollFrame clips regardless) even if the helper is ever unavailable.
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
