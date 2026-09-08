-- QuestRadar (client addon) - Core.lua
--
-- Gets, through the mod-quest-radar server module's communication bridge
-- (CHAT_MSG_ADDON / LANG_ADDON), the player's position and that of their
-- known quest objectives on the current map, and exposes them to
-- Minimap.lua for display on the minimap.
--
-- Protocol (must stay in sync with src/QuestRadar.h /
-- src/QuestRadarLoader.cpp server-side - see the doc above
-- QuestRadar_BuildAddonSyncMessages / QuestRadar_AddonCommsScript there):
--   Us -> Server (self-whisper, the only channel where LANG_ADDON is
--     allowed without a group/guild context): "QuestRadar\tREQ"
--   Server -> Us: "QuestRadar\tME\t<mapId>\t<x>\t<y>" (the player's position)
--                 then a series of
--                   "QuestRadar\tOBJ\t<mapId>\t<questId>\t<poiId>\t<x>\t<y>\t<dist>\t<areaX>\t<areaY>\t<areaRadius>\t<objectiveIndex>\t<title>"
--                 (one message per `quest_poi` objective group, not per
--                 quest: a quest with several distinct objectives (e.g.
--                 "kill X" AND "bring this back elsewhere") sends several
--                 "OBJ" messages with the same questId but a different
--                 poiId - poiId is the stable key used addon-side for an
--                 icon/area, cf. Minimap.lua. areaX/areaY/areaRadius
--                 describe the group's approximate "area" when it has
--                 several points - areaRadius is 0 otherwise, nothing more
--                 to draw than the x/y point)
--                 then a "QuestRadar\tEND\t<mapId>\t<count>"
--
-- No position data is hardcoded here: everything comes from the server, on
-- request (see this folder's README.md - a deliberate choice to stay
-- consistent with the quest_poi data actually loaded by THIS server,
-- including any custom additions).
--
-- Why the server also sends THE PLAYER'S OWN POSITION (mapId+x+y): a
-- genuine WotLK 3.3.5.12340 client has no reliable function to know its own
-- position in yards (`UnitPosition` doesn't exist - verified in-game,
-- unlike Blizzard's modern "Classic" client). Minimap.lua therefore just
-- computes a delta (objective - player) in the same frame of reference as
-- the server, without needing to know any map/continent/zone coordinate
-- system client-side.

QuestRadar = QuestRadar or {}
local QR = QuestRadar

local ADDON_PREFIX = "QuestRadar"

-- Persistent settings (SavedVariable "QuestRadarDB", declared in the .toc -
-- filled in by the client at ADDON_LOADED, see below). QuestRadar.db is the
-- stable name to use from other files (Minimap.lua): QuestRadarDB itself
-- doesn't exist until ADDON_LOADED.
local DB_DEFAULTS = {
    enabled     = true,  -- master switch (icon + area + server sync)
    showArea    = true,  -- show the translucent area circle in addition to the icon
    onlyTracked = true,  -- only show tracked quests (Objectives tracker)
}
QR.db = DB_DEFAULTS

-- State of the last completed sync - read by Minimap.lua.
QR.objectives = {}     -- array of { questId, x, y, distance, title }
QR.currentMapId = nil
QR.playerX = nil
QR.playerY = nil

-- Buffer for the sync currently in progress (between "ME" and "END").
local pendingObjectives = {}
local pendingMapId = nil
local pendingPlayerX, pendingPlayerY

-- Splits a "a\tb\tc" string into {"a","b","c"} - including empty fields
-- ("a\t\tc" -> {"a","","c"}). Written by hand (rather than a gmatch
-- pattern) so the behavior on edge cases (an empty field at the end of the
-- string) is explicit and easy to follow.
local function SplitTab(str)
    local fields = {}
    local start = 1
    while true do
        local sep = string.find(str, "\t", start, true)
        if not sep then
            table.insert(fields, string.sub(str, start))
            return fields
        end
        table.insert(fields, string.sub(str, start, sep - 1))
        start = sep + 1
    end
end

-- Checks that this payload's mapId matches the one for the sync currently
-- in progress (set on the first payload received, normally "ME"). If the
-- player changed maps while the payloads were being received, the
-- inconsistent batch is dropped: the next REQ (triggered by the zone
-- change itself) will start a clean sync.
local function IsConsistentMapId(mapId)
    if pendingMapId == nil then
        pendingMapId = mapId
        return true
    end
    return mapId == pendingMapId
end

local function OnAddonMessage(message)
    local fields = SplitTab(message)
    local kind = fields[1]

    if kind == "ME" then
        local mapId, x, y = fields[2], fields[3], fields[4]
        if not IsConsistentMapId(mapId) then
            return
        end
        pendingPlayerX = tonumber(x)
        pendingPlayerY = tonumber(y)
    elseif kind == "OBJ" then
        local mapId, questId, poiId, x, y, dist, areaX, areaY, areaRadius, objectiveIndex, title =
            fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9], fields[10], fields[11], fields[12]
        if not IsConsistentMapId(mapId) then
            return
        end
        table.insert(pendingObjectives, {
            questId        = tonumber(questId),
            poiId          = tonumber(poiId),
            x              = tonumber(x),
            y              = tonumber(y),
            distance       = tonumber(dist),
            areaX          = tonumber(areaX),
            areaY          = tonumber(areaY),
            areaRadius     = tonumber(areaRadius),
            objectiveIndex = tonumber(objectiveIndex),
            title          = title,
        })
    elseif kind == "END" then
        QR.currentMapId = tonumber(fields[2])
        QR.playerX = pendingPlayerX
        QR.playerY = pendingPlayerY
        QR.objectives = pendingObjectives

        pendingObjectives = {}
        pendingMapId = nil
        pendingPlayerX, pendingPlayerY = nil, nil

        if QR.RefreshIcons then
            QR.RefreshIcons()
        end
    end
end

-- Avoids spamming the server: several of the events listened to below
-- (QUEST_LOG_UPDATE in particular) can fire several times in a row for a
-- single real change.
local REQUEST_THROTTLE_SECONDS = 1.0
local lastRequestTime = 0

local function RequestSync()
    if not QR.db.enabled then
        return
    end
    local now = GetTime()
    if now - lastRequestTime < REQUEST_THROTTLE_SECONDS then
        return
    end
    lastRequestTime = now
    SendAddonMessage(ADDON_PREFIX, "REQ", "WHISPER", UnitName("player"))
end

local frame = CreateFrame("Frame", "QuestRadarEventFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")   -- login, hearthstone, zone loading
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")   -- zone change without a loading screen
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("QUEST_WATCH_LIST_CHANGED") -- a quest gets tracked/untracked
frame:RegisterEvent("CHAT_MSG_ADDON")

-- In addition to the events above, a sync is also requested every few
-- seconds: the server is the only source of the player's position (see the
-- comment at the top of this file), so without this the displayed position
-- would stay frozen until the player changes zone/quest.
local PERIODIC_RESYNC_SECONDS = 3.0
local sinceLastPeriodicSync = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    sinceLastPeriodicSync = sinceLastPeriodicSync + elapsed
    if sinceLastPeriodicSync >= PERIODIC_RESYNC_SECONDS then
        sinceLastPeriodicSync = 0
        RequestSync()
    end
end)

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= "QuestRadar" then
            return
        end
        -- QuestRadarDB (SavedVariable declared in the .toc) only exists
        -- from here on (still nil on first install). Missing settings are
        -- filled in without overwriting ones already saved.
        QuestRadarDB = QuestRadarDB or {}
        for key, defaultValue in pairs(DB_DEFAULTS) do
            if QuestRadarDB[key] == nil then
                QuestRadarDB[key] = defaultValue
            end
        end
        QR.db = QuestRadarDB
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix == ADDON_PREFIX then
            OnAddonMessage(message)
        end
        return
    end

    if event == "QUEST_WATCH_LIST_CHANGED" then
        -- Whether a quest is tracked is a 100% client-side state, the
        -- server has no notion of it: no need to re-sync, just re-filter/
        -- redraw with the data already received (cf.
        -- QuestRadar.db.onlyTracked in Minimap.lua).
        if QR.RefreshIcons then
            QR.RefreshIcons()
        end
        return
    end

    RequestSync()
end)

local function PrintMsg(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[QuestRadar]|r " .. string.format(fmt, ...))
end

local function PrintHelp()
    PrintMsg("Commands: /qr (sync + debug), /qr on|off (enable/disable), /qr zone on|off (show/hide the area), /qr tracked on|off (limit to tracked quests), /qr scan (quest log diagnostic), /qr help.")
end

-- Commands: /questradar or /qr, with or without an argument.
SLASH_QUESTRADAR1 = "/questradar"
SLASH_QUESTRADAR2 = "/qr"
SlashCmdList["QUESTRADAR"] = function(msg)
    -- Simple whitespace splitting (unlike SplitTab, dedicated to the
    -- network protocol above): /qr arguments have no empty fields to
    -- preserve, gmatch works perfectly fine here.
    local args = {}
    for word in (msg or ""):gmatch("%S+") do
        table.insert(args, word)
    end
    local cmd = (args[1] or ""):lower()

    if cmd == "on" or cmd == "off" then
        QR.db.enabled = (cmd == "on")
        PrintMsg("Module %s.", QR.db.enabled and "enabled" or "disabled")
        if QR.db.enabled then
            lastRequestTime = 0
            RequestSync()
        elseif QR.RefreshIcons then
            QR.RefreshIcons() -- immediately clears any displayed icons/areas
        end
        return
    end

    if cmd == "zone" then
        local sub = (args[2] or ""):lower()
        if sub == "on" or sub == "off" then
            QR.db.showArea = (sub == "on")
            PrintMsg("Area %s.", QR.db.showArea and "enabled" or "disabled")
            if QR.RefreshIcons then
                QR.RefreshIcons()
            end
        else
            PrintMsg("Usage: /qr zone on|off (currently %s).", QR.db.showArea and "on" or "off")
        end
        return
    end

    if cmd == "tracked" then
        local sub = (args[2] or ""):lower()
        if sub == "on" or sub == "off" then
            QR.db.onlyTracked = (sub == "on")
            PrintMsg("Limit to tracked quests: %s.", QR.db.onlyTracked and "yes" or "no")
            if QR.RefreshIcons then
                QR.RefreshIcons()
            end
        else
            PrintMsg("Usage: /qr tracked on|off (currently %s).", QR.db.onlyTracked and "on" or "off")
        end
        return
    end

    if cmd == "scan" then
        -- Diagnostic: raw dump of the quest log (index, header or not,
        -- questId, tracked) to understand why IsQuestTracked gets a given
        -- quest wrong (cf. Minimap.lua). Compare with the index shown by
        -- the in-game Objectives tracker / quest log.
        local numEntries = GetNumQuestLogEntries()
        PrintMsg("Quest log scan (%d entries):", numEntries)
        for i = 1, numEntries do
            -- GetQuestID() doesn't exist on this client (verified in-game):
            -- GetQuestLogTitle already returns the quest id as its 9th value.
            local title, level, questTag, suggestedGroup, isHeader, _, _, _, qid = GetQuestLogTitle(i)
            if isHeader then
                PrintMsg("  #%d [header] %s", i, tostring(title))
            else
                local watched = IsQuestWatched and IsQuestWatched(i) or "IsQuestWatched-missing"
                PrintMsg("  #%d %s (id=%s, tracked=%s)", i, tostring(title), tostring(qid), tostring(watched))
            end
        end
        return
    end

    if cmd == "help" then
        PrintHelp()
        return
    end

    if cmd ~= "" then
        PrintMsg("Unknown command: %s", cmd)
        PrintHelp()
        return
    end

    -- No argument: manual sync + diagnostic (legacy behavior).
    lastRequestTime = 0 -- force the request through despite the throttle
    RequestSync()
    PrintMsg("Sync requested - %d objective(s) on map %s (player: %s, %s). Module %s, area %s, tracked-only %s.",
        #QR.objectives, tostring(QR.currentMapId), tostring(QR.playerX), tostring(QR.playerY),
        QR.db.enabled and "enabled" or "disabled", QR.db.showArea and "on" or "off",
        QR.db.onlyTracked and "on" or "off")

    -- Detailed diagnostic (icon state) - see QuestRadar.DebugInfo in
    -- Minimap.lua.
    if QR.DebugInfo then
        QR.DebugInfo()
    end
end
