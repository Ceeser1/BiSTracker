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
local raidScanFailed     = {}  -- [playerName]=true: dropped after MAX_REQUEUES; shows "Unable to scan" until next full scan

-- De-dup cache for posted items (avoid reacting twice to the same repost).
local lastPostedItem = nil
local lastPostedTime = 0
local POST_CACHE_TTL = 120  -- seconds; a new item resets the window, same item is ignored within it

-- Announcer election / addon presence (session/raid state, never saved to DB).
local ADDON_PREFIX     = "BiSTracker"
local addonUsers       = {}    -- [playerName] = true: raid members confirmed running BiSTracker
local skipUsers        = {}    -- [playerName] = true: addon users who opted out of being announcer
local currentAnnouncer = nil   -- elected announcer name; only this player runs announce/inform

-- MS-Changed sync: only the announcer broadcasts; listeners reassemble all chunks of one
-- transmission before applying, so a name split into a later chunk is never wrongly unchecked.
local mscBuf = { from = nil, total = 0, seen = 0, parts = {} }  -- listener reassembly buffer
local mscLocked = false  -- true once a listener applies an announcer broadcast: MS-Changed checkboxes disabled

-- "Announcer don't whisper me": each player broadcasts its own opt-out; everyone notes it, and the
-- announcer skips whispering opted-out players. On announcer handoff the outgoing announcer syncs
-- its accumulated ruleset to the newcomer (who may have missed earlier broadcasts).
local noWhisperUsers = {}   -- [name] = true: player opted out of upgrade whispers (session set, all clients)
local nwsBuf = { from = nil, total = 0, seen = 0, parts = {} }  -- new-announcer handoff reassembly buffer
local nwLastSent = false    -- last opt-out value we actually broadcast (idempotency guard; false = default)
local wasInRaid = false     -- tracks the not-in-raid -> in-raid transition to broadcast on join
-- Announcer's per-player Whisper? overrides. Session-only (NOT persisted) so every session defaults
-- to "on" (whisper); the persistent off-authority is each player's own NW opt-out broadcast.
local whisperOn = {}        -- [name] = false: announcer chose NOT to whisper this player (session; unset/true = whisper)

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

-- ============================================================
-- VERSION CHECK  (rides on the HELLO/SKIP presence heartbeat)
-- ============================================================
-- Presence messages carry the sender's version (HELLO:1.7.2 / SKIP:1.7.2). When we learn a peer is
-- running a newer version, we wait a few seconds to collect all replies (so a laggy client's reply
-- still counts), then tell the user ONCE per session which newest version is out there.
local ADDON_VERSION     = GetAddOnMetadata(ADDON_PREFIX, "Version") or "?"
local VER_COLLECT_DELAY = 3.0
local versionNotified   = false   -- have we already told the user this session? (spam guard)
local highestPeerVer    = nil     -- highest peer version string seen so far
local highestPeerName   = nil     -- name of the peer who reported highestPeerVer

-- Collection window: fires VER_COLLECT_DELAY after the first peer version is seen, then decides once.
local verFrame = CreateFrame("Frame")
local verAccum = 0
verFrame:Hide()
verFrame:SetScript("OnUpdate", function(self, elapsed)
    verAccum = verAccum + elapsed
    if verAccum < VER_COLLECT_DELAY then return end
    self:Hide()
    if highestPeerVer and VersionLess(ADDON_VERSION, highestPeerVer) then
        if not versionNotified then
            versionNotified = true
            if debugMode then Print("[Version] V" .. highestPeerVer .. " from " .. tostring(highestPeerName) .. " is newer. Notifying...") end
            Print(COLOR.legendary .. "A newer version (v" .. highestPeerVer .. ") of BiSTracker is available! Get it from github.com/Ceeser1/BiSTracker|r")
        end
    elseif debugMode then
        Print("[Version] V" .. ADDON_VERSION .. " is the latest.")
    end
end)

-- Note a peer's advertised version (from any HELLO/SKIP). Tracks the newest version + who reported
-- it and opens a short collection window; when it elapses we compare against our own version once.
-- No-op once we've already notified this session.
local function NoteVersion(ver, sender)
    if versionNotified then return end
    if not IsValidVersion(ver) then return end
    if not highestPeerVer or VersionLess(highestPeerVer, ver) then
        highestPeerVer  = ver
        highestPeerName = sender
    end
    if not verFrame:IsShown() then verAccum = 0; verFrame:Show() end   -- collect, then decide on elapse
end

-- Our own presence body, version-tagged: "HELLO:<ver>" (candidate) or "SKIP:<ver>" (opted out).
local function PresenceMsg()
    return (LS().skipAnnouncer and "SKIP:" or "HELLO:") .. ADDON_VERSION
end

-- Broadcast our own whisper decision to the raid (NW:1 = opted out / not allowed, NW:0 = allowed).
local function NW_Send()
    if GetNumRaidMembers() == 0 then return end
    local optedOut = not LS().allowWhispers
    SendAddon("NW:" .. (optedOut and "1" or "0"))
    nwLastSent = optedOut
end

-- 5s trailing throttle so spam-toggling the checkbox collapses into a single (settled) broadcast.
local nwThrottleFrame = CreateFrame("Frame")
local nwThrottleAccum = 0
local nwThrottlePending = false
nwThrottleFrame:Hide()
nwThrottleFrame:SetScript("OnUpdate", function(self, elapsed)
    nwThrottleAccum = nwThrottleAccum + elapsed
    if nwThrottleAccum >= 5.0 then
        nwThrottleAccum = 0; nwThrottlePending = false; self:Hide()
        if (not LS().allowWhispers) ~= nwLastSent then NW_Send() end   -- only if it actually changed
    end
end)
local function ScheduleNoWhisperBroadcast()
    if not nwThrottlePending then
        nwThrottlePending = true; nwThrottleAccum = 0; nwThrottleFrame:Show()
    end
    -- Already pending: the running timer will pick up the latest allowWhispers value when it fires.
end

-- Persist each player's broadcast choice (per realm) so the announcer remembers who opted out across
-- relog, even if they don't re-broadcast. Only opt-outs are stored; absence = allowed (the default).
local function SaveWhisperOptOut(name, optedOut)
    local store = BiSTrackerDB.whisperOptOut
    if not store or store.realm ~= GetRealmName() then
        store = { realm = GetRealmName(), names = {} }
        BiSTrackerDB.whisperOptOut = store
    end
    store.names[name] = optedOut and true or nil
end

-- Restore saved opt-out choices for players currently in the raid (same realm only).
local function LoadWhisperOptOut()
    local store = BiSTrackerDB.whisperOptOut
    if not store or not store.names or store.realm ~= GetRealmName() then return end
    local roster = { [UnitName("player")] = true }
    for i = 1, GetNumRaidMembers() do
        local n = GetRaidRosterInfo(i)
        if n then roster[n] = true end
    end
    local me = UnitName("player")
    for name, v in pairs(store.names) do
        -- Skip our own entry: the local player's whisper state is always derived from
        -- LS().allowWhispers, so a stale stored value must never override the live setting.
        if v and roster[name] and name ~= me then noWhisperUsers[name] = true end
    end
end

-- Announcer handoff: give the newly elected announcer our accumulated opt-out ruleset (directed
-- whisper), since a just-joined announcer missed the earlier NW broadcasts. Chunked, current-raid only.
local function SendNoWhisperHandoff(target)
    if GetNumRaidMembers() == 0 then return end
    local inRaid = {}
    for i = 1, GetNumRaidMembers() do
        local n = GetRaidRosterInfo(i)
        if n then inRaid[n] = true end
    end
    local names = {}
    for name, v in pairs(noWhisperUsers) do
        if v and inRaid[name] then names[#names + 1] = name end
    end
    if #names == 0 then return end   -- nothing opted out: nothing to hand off (merge-only semantics)
    for _, body in ipairs(ChunkNames("NWSYNC:", names)) do SendAddon(body, target) end
    if debugMode then Print("[NoWhisper] Handoff to |cffffff00" .. target .. "|r: " .. #names .. " opted-out member(s).") end
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
        local old = currentAnnouncer
        currentAnnouncer = name
        if debugMode then
            Print("[Announcer] A new announcer for this Raid got selected: |cffffffff" .. (name or "None") .. "|r")
        end
        -- Handoff: if I was the announcer and someone else took over, give them my whisper ruleset
        -- (a just-joined announcer missed the earlier NW broadcasts).
        if old == UnitName("player") and name and name ~= UnitName("player") then
            SendNoWhisperHandoff(name)
        end
        -- Announcer changed (None, us, or a different player): re-enable the MS-Changed checkboxes
        -- until this announcer's first broadcast re-locks listeners (ApplyMSChangedSet). Always refresh
        -- so the Whisper? column's read-only state (only the announcer may edit it) updates live too.
        mscLocked = false
        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()
        end
    end
    UpdateAnnouncerUI()
end

-- Run the election and adopt the result locally (SetAnnouncer also performs any whisper-ruleset
-- handoff). If I'm the winner, broadcast ANN so everyone else stands down -- UNLESS announce == false,
-- used on the HELLO path: receiving a HELLO can only ever make me lose/keep the role, never newly win
-- it, so my ANN there would be a pure re-affirmation. The newcomer learns the announcer via its own REQ.
function BiSTracker_RefreshAnnouncer(announce)
    local elected = ElectAnnouncer()
    SetAnnouncer(elected)
    if announce ~= false and elected and elected == UnitName("player") and GetNumRaidMembers() > 0 then
        SendAddon("ANN:" .. elected)
    end
end

-- Called 4s after entering world: advertise presence (SKIP if opted out, else HELLO) and elect.
function BiSTracker_AnnouncerInit()
    addonUsers[UnitName("player")] = true
    -- Presence (HELLO/SKIP) is broadcast by the roster hook's not-in-raid -> in-raid transition,
    -- which reliably fires at login-in-raid and on forming/joining a raid. We deliberately do NOT
    -- send it here: that would double the login broadcast and re-fire on every zone-in.
    BiSTracker_RefreshAnnouncer()
end

-- ============================================================
-- MS-CHANGED SYNC  (announcer broadcasts, listeners apply)
-- ============================================================
-- After each raid-scan queue finishes, the elected announcer broadcasts the set of players
-- it has flagged as "MS Changed". Listeners collect every chunk of one transmission, then set
-- their checkboxes to exactly that set (check listed names, uncheck the rest).

-- Announcer: broadcast the flagged raid members (chunked). An empty "MSC:1/1" tells listeners
-- to uncheck everyone.
local function BroadcastMSChanges()
    if currentAnnouncer ~= UnitName("player") then return end   -- only the announcer sends
    if GetNumRaidMembers() == 0 then return end

    -- Only broadcast members still in the raid (skip stale flags for players who left).
    local inRaid = {}
    for i = 1, GetNumRaidMembers() do
        local n = GetRaidRosterInfo(i)
        if n then inRaid[n] = true end
    end
    local names = {}
    for name, flagged in pairs(raidMSChanged) do
        if flagged and inRaid[name] then names[#names + 1] = name end
    end

    local bodies = ChunkNames("MSC:", names)
    for _, body in ipairs(bodies) do SendAddon(body) end
    if debugMode then
        Print("[MSChanged] Broadcast |cffffff00" .. #names .. "|r flagged member(s) in " .. #bodies .. " message(s).")
    end
end

-- 5s trailing throttle so the announcer toggling several MS-Changed boxes collapses into one
-- broadcast (in addition to the per-scan-queue-drain broadcast).
local mscThrottleFrame = CreateFrame("Frame")
local mscThrottleAccum = 0
local mscThrottlePending = false
mscThrottleFrame:Hide()
mscThrottleFrame:SetScript("OnUpdate", function(self, elapsed)
    mscThrottleAccum = mscThrottleAccum + elapsed
    if mscThrottleAccum >= 5.0 then
        mscThrottleAccum = 0; mscThrottlePending = false; self:Hide()
        BroadcastMSChanges()   -- self-guards: only sends if we're the announcer
    end
end)
local function ScheduleMSChangedBroadcast()
    if currentAnnouncer ~= UnitName("player") then return end   -- only the announcer broadcasts
    if not mscThrottlePending then
        mscThrottlePending = true; mscThrottleAccum = 0; mscThrottleFrame:Show()
    end
    -- Already pending: the running timer will broadcast the latest set when it fires.
end

-- Listener: apply an authoritative flagged-set — check listed names, uncheck every other
-- current raid member. Only touches players currently in the raid.
-- Persist the "MS Changed" flags immediately — they're a manual annotation, so save on every change
-- (not only when a scan queue drains). Stored per-realm, keyed by player name.
local function SaveMSChanged()
    local names = {}
    for name, flagged in pairs(raidMSChanged) do
        if flagged then names[name] = true end
    end
    BiSTrackerDB.msChanged = { realm = GetRealmName(), names = names }
end

-- Restore saved "MS Changed" flags for players currently in the raid (same realm only). Merge-only:
-- unchecked flags are simply absent from the saved set, so nothing to clear on a fresh session.
local function LoadMSChanged()
    local saved = BiSTrackerDB.msChanged
    if not saved or not saved.names then return end
    if saved.realm and saved.realm ~= GetRealmName() then return end
    local roster = { [UnitName("player")] = true }
    for i = 1, GetNumRaidMembers() do
        local n = GetRaidRosterInfo(i)
        if n then roster[n] = true end
    end
    for name, flagged in pairs(saved.names) do
        if flagged and roster[name] then raidMSChanged[name] = true end
    end
end

local function ApplyMSChangedSet(full)
    local changed = false
    for i = 1, GetNumRaidMembers() do
        local n = GetRaidRosterInfo(i)
        if n then
            local want = full[n] and true or nil
            if (raidMSChanged[n] and true or nil) ~= want then
                raidMSChanged[n] = want
                changed = true
            end
        end
    end
    if not mscLocked then mscLocked = true; changed = true end   -- bound to the announcer: disable checkboxes
    if changed and mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
        BiSTracker_RefreshRaidList()
    end
    SaveMSChanged()   -- persist the applied set so it survives relog/reload
end

-- Listener: parse one "MSC:" chunk, buffer it, and apply once the whole transmission arrives.
local function HandleMSChanged(sender, body)
    if sender == UnitName("player") then return end   -- never our own (RAID msgs don't echo anyway)
    if sender ~= currentAnnouncer then return end      -- only the elected announcer is authoritative

    local tokens = {}
    for tok in body:gmatch("[^;]+") do tokens[#tokens + 1] = tok end
    if #tokens == 0 then return end
    local idx, tot = tokens[#tokens]:match("^(%d+)/(%d+)$")   -- last token is the "i/n" marker
    idx, tot = tonumber(idx), tonumber(tot)
    if not idx or not tot or tot < 1 or idx < 1 or idx > tot then return end   -- malformed: drop

    local chunkNames = {}
    for k = 1, #tokens - 1 do chunkNames[#chunkNames + 1] = tokens[k] end

    -- Chunk 1 (or a sender/size change) starts a fresh assembly. A single sender's messages are
    -- delivered in order, so chunk 1 always leads; the parts[idx] guard drops any duplicate.
    if idx == 1 or mscBuf.from ~= sender or mscBuf.total ~= tot then
        mscBuf.from = sender; mscBuf.total = tot; mscBuf.seen = 0; mscBuf.parts = {}
    end
    if not mscBuf.parts[idx] then
        mscBuf.parts[idx] = chunkNames
        mscBuf.seen = mscBuf.seen + 1
    end

    if mscBuf.seen >= mscBuf.total then
        local full, count = {}, 0
        for ci = 1, mscBuf.total do
            local part = mscBuf.parts[ci]
            if part then for _, nm in ipairs(part) do
                if not full[nm] then full[nm] = true; count = count + 1 end
            end end
        end
        ApplyMSChangedSet(full)
        if debugMode then
            Print("[MSChanged] Received MS-Changed set from |cffffff00" .. sender .. "|r: " .. count .. " flagged member(s).")
        end
        mscBuf.from = nil; mscBuf.total = 0; mscBuf.seen = 0; mscBuf.parts = {}
    end
end

-- New announcer: reassemble a whisper-rules handoff and merge the opted-out names into our set.
-- Only the current announcer applies it, only from a known addon user, current-raid names only.
local function HandleNWSync(sender, body)
    if currentAnnouncer ~= UnitName("player") then return end   -- only the (new) announcer consumes a handoff
    if not addonUsers[sender] then return end                   -- from a raid addon user only

    local tokens = {}
    for tok in body:gmatch("[^;]+") do tokens[#tokens + 1] = tok end
    if #tokens == 0 then return end
    local idx, tot = tokens[#tokens]:match("^(%d+)/(%d+)$")
    idx, tot = tonumber(idx), tonumber(tot)
    if not idx or not tot or tot < 1 or idx < 1 or idx > tot then return end

    local chunkNames = {}
    for k = 1, #tokens - 1 do chunkNames[#chunkNames + 1] = tokens[k] end

    if idx == 1 or nwsBuf.from ~= sender or nwsBuf.total ~= tot then
        nwsBuf.from = sender; nwsBuf.total = tot; nwsBuf.seen = 0; nwsBuf.parts = {}
    end
    if not nwsBuf.parts[idx] then
        nwsBuf.parts[idx] = chunkNames
        nwsBuf.seen = nwsBuf.seen + 1
    end

    if nwsBuf.seen >= nwsBuf.total then
        local inRaid = {}
        for i = 1, GetNumRaidMembers() do
            local n = GetRaidRosterInfo(i)
            if n then inRaid[n] = true end
        end
        local merged = 0
        for ci = 1, nwsBuf.total do
            local part = nwsBuf.parts[ci]
            if part then
                for _, nm in ipairs(part) do
                    if inRaid[nm] and not noWhisperUsers[nm] then noWhisperUsers[nm] = true; merged = merged + 1 end
                end
            end
        end
        nwsBuf.from = nil; nwsBuf.total = 0; nwsBuf.seen = 0; nwsBuf.parts = {}
        if debugMode then Print("[NoWhisper] Handoff from |cffffff00" .. sender .. "|r merged; " .. merged .. " new opt-out(s).") end
    end
end

-- Incoming addon traffic (prefix-filtered in the event handler caller).
function BiSTracker_OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= ADDON_PREFIX or not msg or not sender or sender == "" then return end
    local newUser = (addonUsers[sender] == nil) and (sender ~= UnitName("player"))
    addonUsers[sender] = true
    local pKind, pVer = ParsePresence(msg)

    -- A presence BROADCAST (RAID) means the sender just (re)joined/relogged. Reply with our own
    -- version-tagged presence directly to them so they learn our version -- even when we already
    -- knew them (newUser=false on relog, since a logout doesn't remove them from the roster). We
    -- never reply to a directed WHISPER: that reply IS the answer, and replying again would loop.
    local isBroadcast = pKind and channel ~= "WHISPER" and sender ~= UnitName("player")

    if pKind == "HELLO" then
        NoteVersion(pVer, sender)           -- version check: note their version, notify if it beats ours
        skipUsers[sender] = nil             -- they're an active candidate again
        if isBroadcast then SendAddon(PresenceMsg(), sender) end   -- directed reply: our candidacy + version
        if newUser then BiSTracker_RefreshAnnouncer(false) end     -- new addon user: re-elect locally only; their own REQ fetches the ANN
    elseif pKind == "SKIP" then
        NoteVersion(pVer, sender)           -- version check: note their version, notify if it beats ours
        skipUsers[sender] = true            -- sender opted out of being announcer
        if isBroadcast then SendAddon(PresenceMsg(), sender) end   -- directed reply: our candidacy + version
        BiSTracker_RefreshAnnouncer()       -- re-elect (a new winner re-broadcasts ANN)
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
    elseif msg:sub(1, 4) == "MSC:" then
        HandleMSChanged(sender, msg:sub(5))
    elseif msg:sub(1, 7) == "NWSYNC:" then
        HandleNWSync(sender, msg:sub(8))                     -- announcer handoff of the whisper ruleset
    elseif msg:sub(1, 3) == "NW:" then
        local off = (msg:sub(4) == "1")
        noWhisperUsers[sender] = off and true or nil  -- a player's own opt-out decision
        SaveWhisperOptOut(sender, off)                -- save their choice so we remember it across relog
        if debugMode then
            Print("[NoWhisper] Received new whisperOn from |cffffff00" .. sender .. "|r: " .. (off and "False" or "True"))
        end
        if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
            BiSTracker_RefreshRaidList()   -- reflect the locked/unlocked Whisper? checkbox live
        end
    end
end

-- On roster change: prune leavers, then re-elect only if the announcer is gone or lost rights.
function BiSTracker_AnnouncerOnRoster()
    if GetNumRaidMembers() == 0 then
        for k in pairs(addonUsers) do addonUsers[k] = nil end
        for k in pairs(skipUsers)  do skipUsers[k]  = nil end
        for k in pairs(noWhisperUsers) do noWhisperUsers[k] = nil end
        addonUsers[UnitName("player")] = true
        wasInRaid = false
        SetAnnouncer(nil)
        return
    end
    -- Not-in-raid -> in-raid transition (login into a raid or joining one): broadcast our own
    -- opt-out, but only if it's set (absence means "whisper OK", so silent by default).
    if not wasInRaid then
        wasInRaid = true
        noWhisperUsers[UnitName("player")] = (not LS().allowWhispers) and true or nil
        if not LS().allowWhispers then NW_Send() end
        -- (Re)advertise our presence+version now that we're in a raid. Without this, forming/joining
        -- a raid after login would never emit a HELLO (login-time init already ran out of raid).
        SendAddon(PresenceMsg())
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
    for name in pairs(noWhisperUsers) do
        if name ~= UnitName("player") and not inRaid[name] then noWhisperUsers[name] = nil end
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
    local informed = {}   -- { {name, label}, ... }: say/raid recipients, combined into one line below
    for playerName, scanEntry in pairs(raidScanData) do
        local spec = scanEntry.spec
        -- Skip players flagged "MS Changed" (scanned gear no longer matches spec BiS), players who
        -- opted out themselves ("Don't whisper me"), and players we unchecked in the Whisper? column.
        if spec and bisResults[spec] and not raidMSChanged[playerName]
           and not noWhisperUsers[playerName] and whisperOn[playerName] ~= false then
            local label = GetNotifyUpgradeType(bisResults[spec], scanEntry.gear, itemName, postedIlvl)
            if label then
                if ls.informChannel == "whisper" then
                    SendChatMessage(itemLink .. " is " .. UpgradePhrase(label) .. " for you.", "WHISPER", nil, playerName)
                else
                    table.insert(informed, { name = playerName, label = label })
                end
            end
        end
    end
    -- Say/raid: one combined line "[Item] is an upgrade for A (BiS), B (Alt), C (pre-BiS), ..."
    -- instead of a chat message per player. Splits only if the 255-char chat cap is exceeded.
    if #informed > 0 then
        local rank = { ["BiS"] = 1, ["Alt BiS"] = 2, ["pre-BiS"] = 3, ["Alt pre-BiS"] = 4 }
        table.sort(informed, function(a, b)
            if rank[a.label] ~= rank[b.label] then return rank[a.label] < rank[b.label] end
            return a.name < b.name
        end)
        local prefix = itemLink .. " is an upgrade for "
        local line
        for _, p in ipairs(informed) do
            local piece = p.name .. " (" .. p.label .. ")"
            if not line then
                line = prefix .. piece
            elseif #line + 2 + #piece > 255 then
                SendInChannel(line, ls.informChannel)
                line = prefix .. piece
            else
                line = line .. ", " .. piece
            end
        end
        SendInChannel(line, ls.informChannel)
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
    local function WriteItem(c, lineIdx, yOff, gearSlot, label)
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
    local INTERVAL           = 1.5    -- idle gap between inspects; also the safety margin against
                                      -- ultra-late replies being misattributed (see GUID tracking below)
    local TALENT_TIMEOUT     = 2.5    -- max wait for inspect talent data before giving up on this target
    local REBUILD_INTERVAL   = 300.0  -- 5 minutes between full scans
    local MAX_REQUEUES       = 5      -- out-of-range re-queue cap before dropping (re-added next full scan)

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
            currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
            mainTimer = 0
            return true
        end
        return removed
    end

    -- Appends a single player to the queue and starts the scan immediately if idle.
    local function EnqueuePlayer(name, unitID, isSelf)
        raidScanFailed[name] = nil   -- retrying this player: clear any "Unable to scan" flag
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
        raidScanData = {}; raidScanQueue = {}; raidScanFailed = {}
        currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
        rebuildActive = false; rebuildTimer = 0
        fullScanInProgress = false; onlineStatus = {}
        snapshotLoadAttempted = false
        mainTimer = 0; inspectTimer = 0; connTimer = 0
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
        raidScanData = {}; raidScanQueue = {}; raidScanFailed = {}
        for k in pairs(raidMSChanged)  do raidMSChanged[k]  = nil end
        for k in pairs(noWhisperUsers) do noWhisperUsers[k] = nil end
        for k in pairs(whisperOn)      do whisperOn[k]      = nil end
        currentUnit = nil; currentName = nil; currentEntry = nil; currentGUID = nil
        rebuildActive = false; rebuildTimer = 0
        fullScanInProgress = false; onlineStatus = {}
        snapshotLoadAttempted = true   -- snapshot is gone; don't try to restore one
        mainTimer = 0; inspectTimer = 0; connTimer = 0
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
            raidScanData = {}; raidScanQueue = {}; raidScanFailed = {}
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
                local cancelled = RemoveFromQueue(name)
                if cancelled and #raidScanQueue == 0 then
                    rebuildActive = true; rebuildTimer = 0
                end
                if debugMode then Print("[RaidScan] " .. name .. " left the raid, removed.") end
            end
        end

        -- Queue players who just joined (online only)
        for name, info in pairs(currentRoster) do
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
                    -- No gear (out of range) or no spec (talents didn't arrive in time): retry rather
                    -- than store an empty/spec-less entry. Dropped after MAX_REQUEUES; next full sweep retries.
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

            -- Range gate: the server only answers NotifyInspect within ~28 yd. Requeue now
            -- instead of burning the TALENT_TIMEOUT wait on a target that can never answer.
            if not (CanInspect(unitID) and CheckInteractDistance(unitID, 1)) then
                entry.requeues = (entry.requeues or 0) + 1
                if entry.requeues < MAX_REQUEUES then
                    if debugMode then Print("[RaidScan] |cffffff00" .. entry.name .. "|r not inspectable (out of range?), re-queuing (" .. entry.requeues .. "/" .. MAX_REQUEUES .. ").") end
                    table.insert(raidScanQueue, entry)
                    -- No packet was sent, so skipping ahead is free: try the next player now.
                    -- Only when the requeued player is alone do we keep the INTERVAL pacing,
                    -- so a lone out-of-range player gets retries spread out instead of burning
                    -- all MAX_REQUEUES within a few frames.
                    if #raidScanQueue > 1 then mainTimer = INTERVAL end
                else
                    raidScanFailed[entry.name] = true   -- dropped after retries: show "Unable to scan"
                    if debugMode then Print("[RaidScan] |cffffff00" .. entry.name .. "|r not inspectable after " .. MAX_REQUEUES .. "x, dropping until next full scan.") end
                    if mainFrame and mainFrame:IsShown() and viewMode == "mlSettings" then
                        BiSTracker_RefreshRaidList()
                    end
                    mainTimer = INTERVAL   -- nothing was sent: move on to the next player now
                end
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
