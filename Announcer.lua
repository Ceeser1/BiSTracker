-- ============================================================
-- ANNOUNCER / ADDON COMMS (background engine)
--
-- Child of Settings.lua: the announcer SETTINGS UI (checkboxes,
-- "Current Announcer" label, Whisper?/MS-Changed columns) lives
-- there; this file owns everything that runs in the background -
-- addon-message transport, version check, announcer election,
-- MS-Changed / no-whisper sync, and reacting to posted loot.
--
-- Shared state this file OWNS (globals, read by Settings/RaidScan):
--   currentAnnouncer, mscLocked, raidMSChanged, noWhisperUsers, whisperOn
-- Globals this file PROVIDES for the UI / RaidScan / events:
--   SendAddon, PresenceMsg, SaveWhisperOptOut, ScheduleNoWhisperBroadcast,
--   LoadWhisperOptOut, SaveMSChanged, LoadMSChanged, ScheduleMSChangedBroadcast,
--   BroadcastMSChanges, BiSTracker_RefreshAnnouncer, BiSTracker_AnnouncerInit,
--   BiSTracker_OnAddonMessage, BiSTracker_AnnouncerOnRoster, HandlePostedItem
-- Globals from Settings.lua this file USES:
--   LS(), UpdateAnnouncerUI(), BiSTracker_RefreshRaidList()
-- ============================================================

raidMSChanged            = {}  -- [playerName]=true: user flagged them as having changed Main Spec (global: RaidScan.lua wipes it)

-- De-dup cache for posted items (avoid reacting twice to the same repost).
local lastPostedItem = nil
local lastPostedTime = 0
local POST_CACHE_TTL = 120  -- seconds; a new item resets the window, same item is ignored within it

-- Announcer election / addon presence (session/raid state, never saved to DB).
local ADDON_PREFIX     = "BiSTracker"
local addonUsers       = {}    -- [playerName] = true: raid members confirmed running BiSTracker
local skipUsers        = {}    -- [playerName] = true: addon users who opted out of being announcer
currentAnnouncer = nil   -- elected announcer name; only this player runs announce/inform (global: Settings.lua UI reads it)

-- MS-Changed sync: only the announcer broadcasts; listeners reassemble all chunks of one
-- transmission before applying, so a name split into a later chunk is never wrongly unchecked.
local mscBuf = { from = nil, total = 0, seen = 0, parts = {} }  -- listener reassembly buffer
mscLocked = false  -- true once a listener applies an announcer broadcast: MS-Changed checkboxes disabled (global: Settings.lua raid list reads it)

-- "Announcer don't whisper me": each player broadcasts its own opt-out; everyone notes it, and the
-- announcer skips whispering opted-out players. On announcer handoff the outgoing announcer syncs
-- its accumulated ruleset to the newcomer (who may have missed earlier broadcasts).
noWhisperUsers = {}  -- (global: RaidScan.lua wipes it) [name] = true: player opted out of upgrade whispers (session set, all clients)
local nwsBuf = { from = nil, total = 0, seen = 0, parts = {} }  -- new-announcer handoff reassembly buffer
local nwLastSent = false    -- last opt-out value we actually broadcast (idempotency guard; false = default)
local wasInRaid = false     -- tracks the not-in-raid -> in-raid transition to broadcast on join
-- Announcer's per-player Whisper? overrides. Session-only (NOT persisted) so every session defaults
-- to "on" (whisper); the persistent off-authority is each player's own NW opt-out broadcast.
whisperOn = {}  -- (global: RaidScan.lua wipes it) [name] = false: announcer chose NOT to whisper this player (session; unset/true = whisper)

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
function SendAddon(msg, target)  -- global: Settings.lua UI sends presence on toggle
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
function PresenceMsg()  -- global: used with SendAddon by the Settings.lua UI
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
function ScheduleNoWhisperBroadcast()  -- global: called from the allow-whispers checkbox (Settings.lua)
    if not nwThrottlePending then
        nwThrottlePending = true; nwThrottleAccum = 0; nwThrottleFrame:Show()
    end
    -- Already pending: the running timer will pick up the latest allowWhispers value when it fires.
end

-- Persist each player's broadcast choice (per realm) so the announcer remembers who opted out across
-- relog, even if they don't re-broadcast. Only opt-outs are stored; absence = allowed (the default).
function SaveWhisperOptOut(name, optedOut)  -- global: called from the allow-whispers checkbox (Settings.lua)
    local store = BiSTrackerDB.whisperOptOut
    if not store or store.realm ~= GetRealmName() then
        store = { realm = GetRealmName(), names = {} }
        BiSTrackerDB.whisperOptOut = store
    end
    store.names[name] = optedOut and true or nil
end

-- Restore saved opt-out choices for players currently in the raid (same realm only).
function LoadWhisperOptOut()
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
function BroadcastMSChanges()  -- global: also called from RaidScan.lua (OnQueueDrained)
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
function ScheduleMSChangedBroadcast()  -- global: called from the MS-Changed checkboxes (Settings.lua)
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
function SaveMSChanged()  -- global: called from the MS-Changed checkboxes (Settings.lua)
    local names = {}
    for name, flagged in pairs(raidMSChanged) do
        if flagged then names[name] = true end
    end
    BiSTrackerDB.msChanged = { realm = GetRealmName(), names = names }
end

-- Restore saved "MS Changed" flags for players currently in the raid (same realm only). Merge-only:
-- unchecked flags are simply absent from the saved set, so nothing to clear on a fresh session.
function LoadMSChanged()  -- global: also called from RaidScan.lua (LoadSnapshotOnce)
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

    -- Opted out ("Never be Announcer"): never react.
    if LS().skipAnnouncer then return end
    -- STRICT gate for everything outward (announce say/raid/RW + inform whispers below): only the
    -- ELECTED announcer reacts. Must be strict equality -- the old `currentAnnouncer and ~=` form
    -- fell through when no announcer was elected yet (currentAnnouncer == nil), which made a
    -- freshly-relogged non-announcer react to posts until the HELLO/ANN election settled.
    if currentAnnouncer ~= UnitName("player") then return end

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
