--[[---------------------------------------------------------------------------
QuestRadar - Cataclysm-style quest objective icons on the WotLK 3.3.5a minimap.

Every API used below was checked against the real 3.3.5a (12340) interface,
using the client own FrameXML as the reference
(github.com/wowgaming/3.3.5-interface-files). The three things that are easy
to get wrong on this client, and that broke earlier versions:

 1. POI coordinates are NOT live. QuestPOIGetIconInfo() only answers once
    QuestMapUpdateAllQuests() has rebuilt the POI list for the *current world
    map* - exactly what WorldMapFrame_UpdateQuests() and
    WatchFrame_GetCurrentMapQuests() both do before reading it. Skip that call
    and the radar silently stays empty forever.

 2. Quest ids come from QuestPOIGetQuestIDByVisibleIndex(i), which also hands
    back the quest log index. Completed quests take the first visible indexes,
    which is how the world map ends up numbering the rest 1..n.
    QuestPOIGetIconInfo(questID) then returns completed, posX, posY, objective
    with posX/posY normalised (0-1) to that map - the same frame of reference
    as GetPlayerMapPosition().

 3. Turning a normalised map delta into minimap pixels needs the zone size in
    yards, which this client exposes nowhere. Multiplying the delta by a
    constant (what earlier versions did) is wrong by the ratio between zone
    sizes, so icons ended up bunched in the centre or pinned to the rim
    depending on the zone. !Astrolabe owns that table and also handles minimap
    zoom, rotation, shape and edge clamping, so the projection is delegated to
    it rather than approximated here.
---------------------------------------------------------------------------]]--

local VERSION = "0.7.0"

local POI_PARENT_NAME = "QuestRadarPOIFrame"
local MAX_POIS = 32     -- UI-QuestPoi-NumberIcons only carries the numbers 1..32
local REFRESH_THROTTLE = 0.35
local EDGE_THROTTLE = 0.1
local EDGE_ALPHA = 0.65
local POI_SIZE = 32     -- QuestPOITemplate is 32x32

local DEFAULTS = {
    enabled = true,
    showCompleted = true,
    showOffscreen = true,
    onlyTracked = true,
    useModule = true,   -- use the mod-quest-radar server module when present
    scale = 1,
}

-- Minimal shared namespace, so Options.lua can read the settings and ask for
-- them to be applied. Everything else stays local to this file.
QuestRadar = QuestRadar or {}
local QR = QuestRadar

local DB
local Astrolabe
local holders = {}      -- Astrolabe positions these; the Blizzard POI button rides inside
local active = {}       -- holder -> true, currently handed to Astrolabe
local pending = true
local sinceRefresh, sinceEdge = 0, 0
local refreshing = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuestRadar|r " .. msg)
end

local function InitDB()
    QuestRadarDB = QuestRadarDB or {}
    for key, value in pairs(DEFAULTS) do
        if QuestRadarDB[key] == nil then
            QuestRadarDB[key] = value
        end
    end
    DB = QuestRadarDB
    -- Re-point every time: SavedVariables are restored after this file runs,
    -- which replaces the global table wholesale.
    QR.db = DB
end

-- !Astrolabe keeps itself out of the global namespace, so it has to be pulled
-- out of DongleStub - which raises rather than returning nil when absent.
local function GetAstrolabe()
    if Astrolabe then return Astrolabe end
    if not DongleStub then return nil end
    local ok, lib = pcall(DongleStub, "Astrolabe-0.4")
    if ok and type(lib) == "table" and lib.PlaceIconOnMinimap then
        Astrolabe = lib
    end
    return Astrolabe
end

--------------------------------------------------------------------------------
-- Icon plumbing
--------------------------------------------------------------------------------

-- Blizzard POI buttons are created under a named frame and cached by name. We
-- only need that frame as a namespace: each button is reparented to its own
-- holder right away, so the holder can be scaled without disturbing the offsets
-- Astrolabe computes (SetPoint offsets are read in the frame own scale).
local poiParent = CreateFrame("Frame", POI_PARENT_NAME, Minimap)
poiParent:SetWidth(1)
poiParent:SetHeight(1)
poiParent:SetPoint("CENTER", Minimap, "CENTER", 0, 0)

local function GetHolder(index)
    local holder = holders[index]
    if not holder then
        holder = CreateFrame("Frame", nil, Minimap)
        holder:Hide()
        holders[index] = holder
    end
    -- Recomputed every time, not just at creation: UI suites raise the minimap
    -- after we start (ElvUI does Minimap:SetFrameLevel(+2) in its Initialize),
    -- which would otherwise leave our icons buried under it.
    holder:SetFrameLevel(Minimap:GetFrameLevel() + 10)
    -- Astrolabe reads GetWidth() to inset the icon from the minimap edge.
    local size = POI_SIZE * DB.scale
    holder:SetWidth(size)
    holder:SetHeight(size)
    return holder
end

local function POI_OnEnter(self)
    if not self.questTitle then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(self.questTitle, 1, 1, 1)
    if self.questLogIndex then
        for i = 1, GetNumQuestLeaderBoards(self.questLogIndex) do
            local text, _, finished = GetQuestLogLeaderBoard(i, self.questLogIndex)
            if text then
                if finished then
                    GameTooltip:AddLine(text, 0.5, 0.5, 0.5, true)
                else
                    GameTooltip:AddLine(text, 1, 1, 1, true)
                end
            end
        end
    end
    GameTooltip:Show()
end

local function POI_OnLeave()
    GameTooltip:Hide()
end

local function POI_OnClick(self)
    if self.questId and WorldMap_OpenToQuest then
        WorldMap_OpenToQuest(self.questId)
    elseif self.questLogIndex then
        QuestLog_SetSelection(self.questLogIndex)
        ShowUIPanel(QuestLogFrame)
    end
end

local function AttachPOI(holder, button, questLogIndex, questTitle)
    button:SetParent(holder)
    button:ClearAllPoints()
    button:SetPoint("CENTER", holder, "CENTER", 0, 0)
    button:SetScale(DB.scale)
    button:SetFrameLevel(holder:GetFrameLevel() + 1)
    button.questLogIndex = questLogIndex
    button.questTitle = questTitle
    if not button.questRadarHooked then
        button:SetScript("OnEnter", POI_OnEnter)
        button:SetScript("OnLeave", POI_OnLeave)
        button:SetScript("OnClick", POI_OnClick)
        button.questRadarHooked = true
    end
    button:Show()
    holder.poi = button
end

local function ReleaseAll()
    local lib = Astrolabe
    for holder in pairs(active) do
        if lib then lib:RemoveIconFromMinimap(holder) end
        holder:Hide()
        holder.poi = nil
    end
    table.wipe(active)
    if QuestPOI_HideAllButtons then
        QuestPOI_HideAllButtons(POI_PARENT_NAME)
    end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local lastCounts = { quests = 0, pois = 0, placed = 0, source = "client" }

-- Mirrors WorldMapFrame_UpdateQuests: a negative isComplete means the quest
-- failed, and a quest with no objectives is complete once the gold is there.
local function IsQuestComplete(questLogIndex, isComplete)
    if isComplete and isComplete < 0 then
        return false
    end
    if isComplete then
        return true
    end
    if GetNumQuestLeaderBoards(questLogIndex) == 0
        and GetMoney() >= (GetQuestLogRequiredMoney(questLogIndex) or 0) then
        return true
    end
    return false
end

-- One entry per icon to draw, whichever source produced it:
--   { questID, questLogIndex, title, posX, posY, complete }
-- with posX/posY normalised (0-1) to the current map. Keeping both sources in
-- this one shape is the whole point: the drawing below, and with it Astrolabe's
-- zoom/rotation/shape/edge handling and Blizzard's own artwork, is written once.

-- The client only ever reports one POI per quest.
local function CollectNative()
    -- QuestPOIUpdateIcons() must come between the rebuild and the first
    -- QuestPOIGetIconInfo() read - that is the order WorldMapFrame_UpdateQuests()
    -- uses, and without it the icon info comes back empty.
    local numPOIs = QuestMapUpdateAllQuests() or 0
    QuestPOIUpdateIcons()

    local out = {}
    for i = 1, numPOIs do
        local questID, questLogIndex = QuestPOIGetQuestIDByVisibleIndex(i)
        if questID and questLogIndex and questLogIndex > 0 then
            local _, posX, posY = QuestPOIGetIconInfo(questID)
            if posX and posY and (posX > 0 or posY > 0) then
                local title, _, _, _, isHeader, _, isComplete = GetQuestLogTitle(questLogIndex)
                if not isHeader then
                    out[#out + 1] = {
                        questID = questID,
                        questLogIndex = questLogIndex,
                        title = title,
                        posX = posX,
                        posY = posY,
                        complete = IsQuestComplete(questLogIndex, isComplete),
                    }
                end
            end
        end
    end
    return out, numPOIs
end

local function QuestLogIndexByID()
    local byID = {}
    for i = 1, GetNumQuestLogEntries() or 0 do
        local _, _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
        if not isHeader and questID and questID > 0 then
            byID[questID] = i
        end
    end
    return byID
end

-- The module reports one entry per objective group, which is what the client
-- cannot do. Returns nil when there is nothing usable, so the caller falls
-- back to CollectNative.
local function CollectServer(lib, continent, zone)
    local data = QR.GetServerData and QR.GetServerData()
    if not data or not data.objectives or #data.objectives == 0 then return nil end

    local pC, pZ, px, py = lib:GetCurrentPlayerPosition()
    if not pC or pC ~= continent or pZ ~= zone or not px then return nil end

    -- The module speaks world yards; the rest of this addon speaks normalised
    -- map coordinates. We never need absolute positions to bridge the two: the
    -- player exists in both frames, so a delta suffices. Zone dimensions come
    -- from Astrolabe's public ComputeDistance - the corner-to-corner deltas of
    -- the normalised map are its size in yards.
    local _, zoneW = lib:ComputeDistance(continent, zone, 0, 0, continent, zone, 1, 0)
    local _, _, zoneH = lib:ComputeDistance(continent, zone, 0, 0, continent, zone, 0, 1)
    if not zoneW or not zoneH or zoneW <= 0 or zoneH <= 0 then return nil end

    local byID = QuestLogIndexByID()
    local out = {}

    for _, obj in ipairs(data.objectives) do
        local questLogIndex = obj.questId and byID[obj.questId]
        if questLogIndex then
            local _, _, _, _, _, _, isComplete = GetQuestLogTitle(questLogIndex)
            local complete = IsQuestComplete(questLogIndex, isComplete)

            -- A negative objectiveIndex is the quest_poi convention for "not a
            -- numbered objective", typically a turn-in spot. Drawing it as a
            -- numberless badge was tried in the bridge-based variant and read
            -- as a native NPC blip, so it is only worth showing as the turn-in
            -- icon, and only once the quest is actually complete.
            local numbered = (obj.objectiveIndex or -1) >= 0
            if numbered or complete then
                -- Point at the group's stable centre rather than its nearest
                -- point: within a scattered group the nearest point changes as
                -- the player moves, which made the icon appear to flee.
                local ox = (obj.areaRadius and obj.areaRadius > 0 and obj.areaX) or obj.x
                local oy = (obj.areaRadius and obj.areaRadius > 0 and obj.areaY) or obj.y
                if ox and oy then
                    -- WoW world axes: +X is north, +Y is west. So map east is
                    -- -deltaY and map south is -deltaX. Getting this wrong put
                    -- objectives in the opposite corner once already; see
                    -- ComputeMinimapDelta in the bridge-based variant.
                    local east  = data.playerY - oy
                    local north = ox - data.playerX
                    out[#out + 1] = {
                        questID = obj.questId,
                        questLogIndex = questLogIndex,
                        title = obj.title,
                        posX = px + east / zoneW,
                        posY = py - north / zoneH,
                        complete = complete,
                    }
                end
            end
        end
    end

    if #out == 0 then return nil end
    return out
end

-- Returns false when it could not run and should be retried.
local function Refresh()
    InitDB()
    local lib = GetAstrolabe()

    if not DB.enabled or not lib then
        ReleaseAll()
        return true
    end

    -- POI data is read off whatever zone the world map currently points at, so
    -- refreshing means moving it back to the player. Do not do that under the
    -- player feet while they have the map open - retry once it is closed.
    if WorldMapFrame and WorldMapFrame:IsShown() then
        return false
    end

    refreshing = true
    SetMapToCurrentZone()
    local continent, zone = GetCurrentMapContinent(), GetCurrentMapZone()

    ReleaseAll()

    -- Instances, battlegrounds and the continent-level view have no zone POIs.
    if not continent or continent < 1 or not zone or zone < 1 then
        lastCounts.quests = GetNumQuestLogEntries() or 0
        lastCounts.pois, lastCounts.placed = 0, 0
        refreshing = false
        return true
    end

    -- The module's richer data when it is there, the client's own otherwise.
    local entries, numPOIs = CollectServer(lib, continent, zone)
    local source = "module"
    if not entries then
        entries, numPOIs = CollectNative()
        source = "client"
    end

    local numeric, completeIn, placed = 0, 0, 0

    for _, entry in ipairs(entries) do
        if placed >= MAX_POIS then break end

        local tracked = not DB.onlyTracked or IsQuestWatched(entry.questLogIndex)
        if tracked and (not entry.complete or DB.showCompleted) then
            -- The counters only advance for icons we actually draw, so the
            -- numbers match the objectives tracker sitting next to the minimap.
            -- That is what WatchFrame does too; the world map numbers every
            -- quest on the map instead, so the two can differ when something is
            -- untracked. They are labels, not identities - the module's gain is
            -- the number of icons, not what is written in them.
            local button
            if entry.complete then
                completeIn = completeIn + 1
                button = QuestPOI_DisplayButton(POI_PARENT_NAME, QUEST_POI_COMPLETE_IN, completeIn, entry.questID)
            else
                numeric = numeric + 1
                button = QuestPOI_DisplayButton(POI_PARENT_NAME, QUEST_POI_NUMERIC, numeric, entry.questID)
            end
            if button then
                local holder = GetHolder(placed + 1)
                AttachPOI(holder, button, entry.questLogIndex, entry.title)
                if lib:PlaceIconOnMinimap(holder, continent, zone, entry.posX, entry.posY) == 0 then
                    placed = placed + 1
                    active[holder] = true
                else
                    holder:Hide()
                    button:Hide()
                    holder.poi = nil
                end
            end
        end
    end

    lastCounts.quests = GetNumQuestLogEntries() or 0
    lastCounts.pois = numPOIs or #entries
    lastCounts.placed = placed
    lastCounts.source = source
    refreshing = false
    return true
end

-- Astrolabe repositions every registered icon on its own, every frame, so all
-- that is left is reacting to icons reaching (or leaving) the minimap edge.
local function UpdateEdgeState()
    local lib = Astrolabe
    if not lib then return end
    for holder in pairs(active) do
        if not lib:GetDistanceToIcon(holder) then
            -- Astrolabe dropped it (the player left the continent).
            holder:Hide()
            holder.poi = nil
            active[holder] = nil
        elseif lib:IsIconOnEdge(holder) then
            if DB.showOffscreen then
                holder:SetAlpha(EDGE_ALPHA)
                holder:Show()
            else
                holder:Hide()
            end
        else
            holder:SetAlpha(1)
            holder:Show()
        end
    end
end

local function Invalidate()
    pending = true
end
QR.Invalidate = Invalidate

--------------------------------------------------------------------------------
-- Driver
--------------------------------------------------------------------------------

local driver = CreateFrame("Frame", "QuestRadarDriver", UIParent)

driver:SetScript("OnEvent", function(self, event)
    -- QuestMapUpdateAllQuests() can fire quest events straight back at us.
    if refreshing then return end
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        InitDB()
        if not GetAstrolabe() then
            Print("|cffff4040!Astrolabe introuvable|r - Interface\\AddOns\\!Astrolabe doit etre present et active.")
        end
    end
    Invalidate()
end)

driver:SetScript("OnUpdate", function(self, elapsed)
    if not DB then return end

    sinceRefresh = sinceRefresh + elapsed
    if pending and sinceRefresh >= REFRESH_THROTTLE then
        sinceRefresh = 0
        if Refresh() then
            pending = false
        end
    end

    sinceEdge = sinceEdge + elapsed
    if sinceEdge >= EDGE_THROTTLE then
        sinceEdge = 0
        UpdateEdgeState()
    end
end)

driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("QUEST_LOG_UPDATE")
driver:RegisterEvent("QUEST_POI_UPDATE")
driver:RegisterEvent("QUEST_WATCH_UPDATE")
driver:RegisterEvent("ZONE_CHANGED")
driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")

-- Checking or unchecking a quest in the tracker fires no event on 3.3.5a:
-- QUEST_WATCH_LIST_CHANGED is a Cataclysm event and is absent from wow.exe
-- 12340. Blizzard's own UI calls AddQuestWatch/RemoveQuestWatch directly
-- (QuestLogFrame.lua, WatchFrame.lua, WorldMapFrame.lua), so hooking the two
-- is the only way to react immediately.
hooksecurefunc("AddQuestWatch", Invalidate)
hooksecurefunc("RemoveQuestWatch", Invalidate)

InitDB()

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function ApplyScale()
    local size = POI_SIZE * DB.scale
    for _, holder in pairs(holders) do
        holder:SetWidth(size)
        holder:SetHeight(size)
        if holder.poi then holder.poi:SetScale(DB.scale) end
    end
end

-- Single entry point for Options.lua: re-read the settings and make the
-- minimap match them straight away.
function QR.ApplySettings()
    InitDB()
    ApplyScale()
    if DB.enabled then
        Invalidate()
    else
        ReleaseAll()
    end
end

local function Status()
    local lib = GetAstrolabe()
    local continent, zone = GetCurrentMapContinent(), GetCurrentMapZone()
    Print("v" .. VERSION
        .. " | actif=" .. tostring(DB.enabled)
        .. " | !Astrolabe=" .. (lib and "ok" or "|cffff4040absent|r")
        .. " | echelle=" .. tostring(DB.scale))
    Print("carte: continent=" .. tostring(continent) .. " zone=" .. tostring(zone)
        .. " (" .. tostring(GetZoneText()) .. ")")
    Print("quetes=" .. lastCounts.quests
        .. " | objectifs annonces=" .. lastCounts.pois
        .. " | icones placees=" .. lastCounts.placed
        .. " | filtre=" .. (DB.onlyTracked and "quetes suivies" or "toutes"))
    Print("source=" .. lastCounts.source
        .. " | module serveur=" .. (not DB.useModule and "desactive"
            or (QR.moduleSeen and "detecte" or "pas de reponse")))
    if lastCounts.pois == 0 then
        Print("0 POI: si la carte du monde n affiche pas non plus de pastilles numerotees, "
            .. "la table quest_poi du monde est vide cote serveur.")
    end
end

local function Toggle(value)
    DB.enabled = value
    if DB.enabled then
        Invalidate()
    else
        ReleaseAll()
    end
    Print(DB.enabled and "active." or "desactive.")
end

SLASH_QUESTRADAR1 = "/qr"
SLASH_QUESTRADAR2 = "/questradar"
SlashCmdList["QUESTRADAR"] = function(msg)
    InitDB()
    msg = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))
    local cmd, arg = string.match(msg, "^(%S*)%s*(.*)$")

    if cmd == "" or cmd == "toggle" then
        Toggle(not DB.enabled)
    elseif cmd == "on" then
        Toggle(true)
    elseif cmd == "off" then
        Toggle(false)
    elseif cmd == "status" or cmd == "debug" then
        Status()
    elseif cmd == "completed" then
        DB.showCompleted = not DB.showCompleted
        Invalidate()
        Print("quetes terminees: " .. (DB.showCompleted and "affichees" or "masquees"))
    elseif cmd == "tracked" then
        DB.onlyTracked = not DB.onlyTracked
        Invalidate()
        Print(DB.onlyTracked
            and "seules les quetes suivies sont affichees"
            or "toutes les quetes de la zone sont affichees")
    elseif cmd == "module" then
        DB.useModule = not DB.useModule
        Invalidate()
        Print("module serveur: " .. (DB.useModule and "utilise si present" or "ignore"))
    elseif cmd == "edge" or cmd == "arrows" then
        DB.showOffscreen = not DB.showOffscreen
        Print("objectifs hors de portee (colles au bord): "
            .. (DB.showOffscreen and "affiches" or "masques"))
    elseif cmd == "scale" then
        local value = tonumber(arg)
        if value and value >= 0.5 and value <= 3 then
            DB.scale = value
            ApplyScale()
            Invalidate()
            Print("echelle des icones = " .. value)
        else
            Print("echelle: une valeur entre 0.5 et 3")
        end
    else
        Print("/qr [on|off] | status | tracked | completed | edge | module | scale <0.5-3>")
    end
end
