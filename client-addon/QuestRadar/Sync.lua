-- QuestRadar - Sync.lua
--
-- Optional bridge to the mod-quest-radar AzerothCore module. Nothing here is
-- required: with no module on the realm the addon keeps running on the
-- client's own quest POI data, and this file just never receives an answer.
--
-- What the module buys us: 3.3.5a Lua exposes a single POI per quest
-- (QuestPOIGetIconInfo returns one position and the objective it belongs to),
-- so a quest with two distant objectives can only ever show one icon. The
-- module reads the same quest_poi tables server-side, where nothing forces
-- that collapse, and sends one entry per objective group.
--
-- Protocol, from src/QuestRadar.h - we send "REQ", it answers:
--   ME  <mapId> <x> <y>
--   OBJ <mapId> <questId> <poiId> <x> <y> <dist> <areaX> <areaY> <areaRadius>
--       <objectiveIndex> <title>          (one per objective group)
--   END <mapId> <count>
-- Coordinates are world yards, because a genuine 3.3.5a client has no
-- reliable way to know its own position in yards (no UnitPosition). We do not
-- need absolute positions though: the player appears in both frames of
-- reference, so a delta is enough to land back in normalised map coordinates -
-- see QuestRadar.lua's ServerObjectives().

local QR = QuestRadar

local PREFIX = "QuestRadar"
local REQUEST_THROTTLE = 3      -- seconds between two REQ, matches the module's own pacing
local STALE_AFTER = 15          -- server data older than this is ignored
local PROBE_GIVE_UP = 20        -- stop probing if nothing ever answers

QR.server = nil                 -- last complete sync, or nil
QR.moduleSeen = false           -- true once the module has answered at least once

local pendingObjectives = {}
local pendingX, pendingY
local lastRequest = 0
local firstRequest = 0

local function Split(message)
    local fields = {}
    for field in string.gmatch(message .. "\t", "([^\t]*)\t") do
        fields[#fields + 1] = field
    end
    return fields
end

-- `periodic` marks the idle heartbeat. Only that one gives up when nothing
-- ever answers: an event means something actually changed, and is always worth
-- one request even on a realm that stayed silent so far.
function QR.RequestSync(periodic)
    if not QR.db or not QR.db.useModule then return end
    -- SendAddonMessage needs a target, and UnitName("player") is nil until the
    -- player is in the world.
    if not UnitName("player") then return end

    if periodic and not QR.moduleSeen and firstRequest > 0
        and (GetTime() - firstRequest) > PROBE_GIVE_UP then
        return
    end

    local now = GetTime()
    if now - lastRequest < REQUEST_THROTTLE then return end
    lastRequest = now
    if firstRequest == 0 then firstRequest = now end

    SendAddonMessage(PREFIX, "REQ", "WHISPER", UnitName("player"))
end

local function OnMessage(message)
    local fields = Split(message)
    local kind = fields[1]

    if kind == "ME" then
        pendingX, pendingY = tonumber(fields[3]), tonumber(fields[4])
        pendingObjectives = {}

    elseif kind == "OBJ" then
        pendingObjectives[#pendingObjectives + 1] = {
            questId        = tonumber(fields[3]),
            poiId          = tonumber(fields[4]),
            x              = tonumber(fields[5]),
            y              = tonumber(fields[6]),
            distance       = tonumber(fields[7]),
            areaX          = tonumber(fields[8]),
            areaY          = tonumber(fields[9]),
            areaRadius     = tonumber(fields[10]),
            objectiveIndex = tonumber(fields[11]),
            title          = fields[12],
        }

    elseif kind == "END" then
        if pendingX and pendingY then
            QR.moduleSeen = true
            QR.server = {
                mapId      = tonumber(fields[2]),
                playerX    = pendingX,
                playerY    = pendingY,
                objectives = pendingObjectives,
                stamp      = GetTime(),
            }
            if QR.Invalidate then QR.Invalidate() end
        end
        pendingObjectives = {}
        pendingX, pendingY = nil, nil
    end
end

-- nil when there is no usable server data right now, so the caller falls back
-- to the client's own POI data.
function QR.GetServerData()
    if not QR.db or not QR.db.useModule then return nil end
    local data = QR.server
    if not data then return nil end
    if (GetTime() - data.stamp) > STALE_AFTER then return nil end
    return data
end

local frame = CreateFrame("Frame", "QuestRadarSyncFrame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_FINISHED")
frame:RegisterEvent("QUEST_LOG_UPDATE")

frame:SetScript("OnEvent", function(self, event, prefix, message)
    if event == "CHAT_MSG_ADDON" then
        if prefix == PREFIX and message then
            OnMessage(message)
        end
        return
    end
    QR.RequestSync()
end)

-- The player's own position is part of every answer, so it has to be
-- refreshed while moving, not only on events.
local elapsed = 0
frame:SetScript("OnUpdate", function(self, delta)
    elapsed = elapsed + delta
    if elapsed < REQUEST_THROTTLE then return end
    elapsed = 0
    QR.RequestSync(true)
end)
