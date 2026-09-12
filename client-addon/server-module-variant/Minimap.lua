-- QuestRadar (client addon) - Minimap.lua
--
-- Draws, on the minimap, an icon (precise point) and, when the objective
-- isn't a precise spot, an area (translucent circle) per known quest
-- objective (QuestRadar.objectives / QuestRadar.playerX/Y /
-- QuestRadar.currentMapId, fed by Core.lua on every server sync - see the
-- comment at the top of this file for why a player/objective delta is used
-- rather than a map/continent coordinate system).
--
-- No external Lua library here (unlike earlier versions of this file which
-- relied on HereBeDragons-1.0/-Pins-1.0, cf. README.md for the history):
-- verified in-game, that lib depends on APIs absent from a genuine WotLK
-- 3.3.5.12340 client (GetWorldMapTransforms, GetAreaMaps, UnitPosition...),
-- meaning it actually targets Blizzard's modern "Classic" client. The
-- calculation below (minimap zoom -> radius in yards, rotation) reuses the
-- standard method from those libraries, adapted to only need a
-- player/objective delta already computed server-side. The only vendored
-- asset is Icons/glow.blp (an image, no code), for the area - see
-- Icons/README.md.
--
-- A native alternative (Blizzard's own QuestPOIFrame:DrawQuestBlob, the
-- exact polygon shape the world map draws for a quest's search area) was
-- tried here and reverted before ever reaching a live test: the reference
-- it was adapted from (mod-quest-radar-v2) dropped that same technique
-- entirely in its own next iteration, without saying why - strong enough a
-- signal of an unreliable native API on this client build to not risk it
-- here too. This hand-approximated circle is a known, already-tested
-- quantity instead.
--
-- The world map doesn't need to be handled here: WotLK already draws quest
-- POIs on it natively (unlike the minimap, which never did before
-- Cataclysm).

local Minimap = Minimap
local sin, cos, floor = math.sin, math.cos, math.floor

-- Minimap visible diameter, in yards, per zoom level (0 = fully zoomed out,
-- 5 = fully zoomed in) and whether indoors or outdoors. These are game
-- engine constants (identical to the ones used by classic minimap
-- libraries like HereBeDragons-Pins or Astrolabe), not data specific to any
-- one map/zone - so none of the mapId/continent correspondence issues hit
-- with HereBeDragons apply here.
local MINIMAP_DIAMETER_YARDS = {
    indoor = {
        [0] = 300,
        [1] = 240,
        [2] = 180,
        [3] = 120,
        [4] = 80,
        [5] = 50,
    },
    outdoor = {
        [0] = 466 + 2 / 3,
        [1] = 400,
        [2] = 333 + 1 / 3,
        [3] = 266 + 2 / 3,
        [4] = 200,
        [5] = 133 + 1 / 3,
    },
}

-- Round texture with a soft (gradient) edge, vendored from Questie-335 (a
-- Questie fork for a genuine WotLK 3.3.5.12340 client - see Icons/README.md
-- for the source and license). Unlike a solid color
-- (Texture:SetTexture(r,g,b,a), our first attempt), a real already-round
-- image doesn't leave square corners poking out of the minimap's circle -
-- WoW 3.3.5 has no native circular clip for addon textures. Reused both for
-- the icon badge (tinted gold) and for the area (tinted blue).
local ROUND_TEXTURE = "Interface\\AddOns\\QuestRadar\\Icons\\glow"

local ICON_SIZE = 20
-- Gold: like the numbered circle Blizzard natively shows on the world map
-- (QuestPOI) for the same objective.
local ICON_COLOR = { 1, 0.82, 0 }

-- The objective number is Blizzard's own numbered-icon overlay, not a
-- hand-drawn FontString (an earlier version of this file used one - a
-- digit ("2") occasionally rendered looking mirrored in-game at this
-- icon's small size). This is the exact texture/math the world map itself
-- uses for its yellow circled numbers (QuestPOI_DisplayButton/QuestPOI.xml
-- in wowgaming/3.3.5-interface-files, verified there rather than guessed):
-- an 8-columns-wide grid, with numbers occupying the bottom half of the
-- texture (yOffset starts at 0.5, i.e. rows 4-7 of an 8x8 grid - the top
-- half holds other, non-numeric POI markers Blizzard reuses this atlas
-- for). Since it's a stock client file, nothing needs to be vendored here.
local NUMBER_TEXTURE = "Interface\\WorldMap\\UI-QuestPoi-NumberIcons"
local NUMBER_ICONS_PER_ROW = 8
local NUMBER_ICON_SIZE = 0.125 -- 1/8th of the texture, per axis
local NUMBER_ROW_OFFSET = 0.5
local function SetIconNumber(icon, number)
    local buttonIndex = number - 1
    local col = buttonIndex % NUMBER_ICONS_PER_ROW
    local row = floor(buttonIndex / NUMBER_ICONS_PER_ROW)
    local xOffset = col * NUMBER_ICON_SIZE
    local yOffset = NUMBER_ROW_OFFSET + row * NUMBER_ICON_SIZE
    icon.number:SetTexCoord(xOffset, xOffset + NUMBER_ICON_SIZE, yOffset, yOffset + NUMBER_ICON_SIZE)
end

-- Below this radius (in yards), the area wouldn't be visually distinct from
-- the precise point - not worth drawing it.
local MIN_AREA_RADIUS_TO_DRAW = 15
-- Max on-screen size of an area, as a fraction of the minimap's diameter,
-- to avoid an area covering a large part of the continent filling the
-- whole screen.
local MAX_AREA_DIAMETER_FRACTION = 0.8

local ZONE_COLOR = { 0.4, 0.75, 1.0 }
local ZONE_ALPHA = 0.55

-- A color-per-quest palette (icon badge + area fill) and a dashed boundary
-- ring traced around the area's true radius were both tried here. Reverted
-- back to a single fixed gold/blue pair: in a hub with several tracked
-- quests at once, the different colors plus each quest's own ring
-- overlapping the others turned into visual noise (scattered,
-- mismatched-looking dots) rather than the clearer picture intended - worse
-- than what it was meant to improve on. Not worth re-attempting without
-- also capping how many zones can be shown at once.

-- icons[key] = frame (precise point); zones[key] = frame (area circle, or
-- nil if areaRadius was 0/too small for this group). `key` is
-- "<questId>:<poiId>", NOT poiId alone: `quest_poi.Id` is only unique
-- *within* a single quest (it restarts at 0 for every quest's own POI list,
-- cf. ObjectMgr::GetQuestPOIVector being looked up per-quest server-side) -
-- keying purely by poiId made two different quests that each have a single,
-- simple objective (by far the most common case, poiId 0 on both) collide
-- into the very same icon/zone frame, so only the last one processed each
-- refresh actually showed up (observed in-game: with two active quests on
-- the same map, only one of their two badges - "1"/"2" - ever appeared).
local function ObjKey(obj)
    return obj.questId .. ":" .. obj.poiId
end
local icons = {}
local zones = {}

-- Explicit levels, well above Minimap's own: the default child level
-- (parent + 1) turned out to be insufficient in-game (nothing showed up),
-- likely hidden behind other internal minimap elements (border, compass...)
-- that themselves use levels higher than Minimap+1. A large gap is forced
-- to be sure to stay above them, the icon above the area.
local function CreateIconFrame()
    local icon = CreateFrame("Frame", nil, Minimap)
    icon:SetFrameLevel(Minimap:GetFrameLevel() + 20)
    icon:SetSize(ICON_SIZE, ICON_SIZE)

    icon.badge = icon:CreateTexture(nil, "OVERLAY")
    icon.badge:SetAllPoints(icon)
    icon.badge:SetTexture(ROUND_TEXTURE)
    icon.badge:SetVertexColor(ICON_COLOR[1], ICON_COLOR[2], ICON_COLOR[3])

    -- Objective number (obj.objectiveIndex + 1) instead of a generic "?"
    -- icon: the same number natively shown in the yellow circle on the
    -- world map for this quest (cf. QuestPOI server-side, QuestRadar.h) -
    -- and, since NUMBER_TEXTURE above, drawn with Blizzard's own asset for
    -- it. Created above the badge (same OVERLAY sub-layer, but the texture
    -- was created first so it's drawn underneath); set via SetIconNumber
    -- once obj.objectiveIndex is known (RefreshIcons).
    icon.number = icon:CreateTexture(nil, "OVERLAY")
    icon.number:SetTexture(NUMBER_TEXTURE)
    icon.number:SetSize(ICON_SIZE * 0.7, ICON_SIZE * 0.7)
    icon.number:SetPoint("CENTER", icon, "CENTER")

    icon:EnableMouse(true)
    return icon
end

local function CreateZoneFrame()
    local zone = CreateFrame("Frame", nil, Minimap)
    -- +15, not +10: the initial +10 turned out to be insufficient in-game
    -- (icon visible but area invisible), same cause as for the icon
    -- (internal minimap elements at a higher level). Stays below the
    -- icon's level (+20) so the icon renders in front.
    zone:SetFrameLevel(Minimap:GetFrameLevel() + 15)
    zone.texture = zone:CreateTexture(nil, "OVERLAY")
    zone.texture:SetTexture(ROUND_TEXTURE)
    zone.texture:SetVertexColor(ZONE_COLOR[1], ZONE_COLOR[2], ZONE_COLOR[3])
    zone.texture:SetAlpha(ZONE_ALPHA)
    zone.texture:SetPoint("CENTER", zone, "CENTER")
    return zone
end

local function SetIconTooltip(frame, obj)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(obj.title or "?", 1, 1, 1)
        if obj.distance then
            GameTooltip:AddLine(string.format("%.0f yd", obj.distance), 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Computes, from an (objective - player) delta in yards, the normalized
-- position (fraction of the minimap radius, -1..1) and the minimap's
-- current on-screen dimensions.
--
-- Bug fixed here (observed in-game: an objective northwest of the player
-- on the world map showed up southwest on the minimap): WoW uses a
-- particular axis convention, +X = north and +Y = west (not the usual
-- screen frame of X=horizontal/Y=vertical). Libraries like HereBeDragons do
-- this conversion internally (they rename `UnitPosition`'s two raw values,
-- swapping their names) before exposing their own "world" coordinates; our
-- first version reused their display formula as-is but on our raw
-- (unswapped) coordinates, hence the north/south vs east/west inversion.
local function ComputeMinimapDelta(objX, objY, playerX, playerY)
    -- +X world = north => screen "up"; +Y world = west => screen "left",
    -- so screen "right" = -deltaY.
    local screenRight = playerY - objY
    local screenUp = objX - playerX

    if GetCVar("rotateMinimap") == "1" then
        local facing = GetPlayerFacing() or 0
        local s, c = sin(facing), cos(facing)
        local dx, dy = screenRight, screenUp
        screenRight = dx * c - dy * s
        screenUp = dx * s + dy * c
    end

    -- The WotLK minimap is always round (no square/corner shapes like on
    -- more recent clients), no need to handle GetMinimapShape here.
    local zoom = Minimap:GetZoom()
    local indoors = (GetCVar("minimapZoom") + 0 == zoom) and "outdoor" or "indoor"
    local diameter = MINIMAP_DIAMETER_YARDS[indoors][zoom] or MINIMAP_DIAMETER_YARDS.outdoor[0]
    local mapRadius = diameter / 2

    local diffX = screenRight / mapRadius
    local diffY = screenUp / mapRadius

    local minimapWidth = Minimap:GetWidth() / 2
    local minimapHeight = Minimap:GetHeight() / 2

    return diffX, diffY, minimapWidth, minimapHeight, mapRadius
end

-- Positions `icon` on the minimap. The icon is always shown, clamped to
-- the edge of the circle if the objective is out of range (like a TomTom
-- arrow) rather than disappearing.
local function PlaceIconOnMinimap(icon, objX, objY, playerX, playerY)
    local diffX, diffY, minimapWidth, minimapHeight = ComputeMinimapDelta(objX, objY, playerX, playerY)

    local distSq = diffX * diffX + diffY * diffY
    if distSq > 1 then
        local scale = distSq ^ 0.5
        diffX = diffX / scale
        diffY = diffY / scale
    end

    -- No negation on diffY: ComputeMinimapDelta already returns diffY in
    -- screen convention ("positive = upward"), unlike the raw world
    -- convention (see the comment in ComputeMinimapDelta).
    icon:ClearAllPoints()
    icon:SetPoint("CENTER", Minimap, "CENTER", diffX * minimapWidth, diffY * minimapHeight)
    icon:Show()
end

-- Positions and sizes an objective's area circle. Like the precise point,
-- it's clamped so it stays fully inside the minimap's round edge rather
-- than bleeding past it (see the clamp comment below) - but only up to a
-- margin: once the objective is truly far out of range, it hides instead
-- of sitting clamped at the edge forever (unlike the icon), since a big
-- area "stuck" flush against the border wouldn't make visual sense.
local function PlaceZoneOnMinimap(zone, areaX, areaY, areaRadius, playerX, playerY)
    local diffX, diffY, minimapWidth, minimapHeight, mapRadius = ComputeMinimapDelta(areaX, areaY, playerX, playerY)

    local radiusFraction = areaRadius / mapRadius
    local distSq = diffX * diffX + diffY * diffY

    -- Hide if the area's center is far past the edge (a margin of one area
    -- radius so it doesn't disappear too early while still partially
    -- visible).
    if distSq > (1 + radiusFraction) * (1 + radiusFraction) then
        zone:Hide()
        return
    end

    local diameterPx = math.min(
        radiusFraction * 2 * minimapWidth,
        MAX_AREA_DIAMETER_FRACTION * minimapWidth * 2)
    local radiusPx = diameterPx / 2

    -- Clamp the circle's *center* so the whole fill stays inside the
    -- minimap's own round edge, instead of just clamping how far past it
    -- the center may go (the old margin above only decided when to hide,
    -- not how far the visible circle could bleed past the round border into
    -- the square black corners behind it - observed in-game). Same idea as
    -- PlaceIconOnMinimap's edge clamp, just against a smaller radius
    -- (minimapWidth - radiusPx instead of the full minimapWidth), so a
    -- big/off-center area gets pulled inward rather than resized.
    local centerPx, centerPy = diffX * minimapWidth, diffY * minimapHeight
    local centerDistPx = (centerPx * centerPx + centerPy * centerPy) ^ 0.5
    local maxCenterDistPx = math.max(minimapWidth - radiusPx, 0)
    -- centerDistPx > 0 guard: without it, an objective centered exactly on
    -- the player (a real case - e.g. standing inside a small-radius area)
    -- divides by zero, and the resulting NaN fed into SetPoint below breaks
    -- rendering - observed in-game as icons/zones failing to (re)position
    -- at all, sometimes for every objective processed afterward in the same
    -- pass (one bad SetPoint call errors out of the whole loop).
    if centerDistPx > 0 and centerDistPx > maxCenterDistPx then
        local scale = maxCenterDistPx / centerDistPx
        centerPx = centerPx * scale
        centerPy = centerPy * scale
    end

    zone:SetSize(diameterPx, diameterPx)
    zone.texture:SetSize(diameterPx, diameterPx)

    zone:ClearAllPoints()
    zone:SetPoint("CENTER", Minimap, "CENTER", centerPx, centerPy)
    zone:Show()
end

local function HasArea(obj)
    return QuestRadar.db.showArea and obj.areaRadius and obj.areaRadius >= MIN_AREA_RADIUS_TO_DRAW
end

-- Is this quest currently tracked (checked in the "Objectives" tracker)?
-- Tracking is a 100% client-side state (the server has no notion of it),
-- indexed by position in the quest log - not by questId, hence the full
-- scan to find the matching index.
--
-- Two bugs fixed here, both found by comparing against the real 3.3.5
-- client's FrameXML sources (wowgaming/3.3.5-interface-files,
-- QuestLogFrame.lua) rather than guessing:
--  1. GetQuestLogTitle's real return order is title, level, questTag,
--     suggestedGroup, isHeader, isCollapsed, isComplete, isDaily, questID,
--     displayQuestID - isHeader is the 5th return value, not the 4th (with
--     the wrong position, `isHeader` actually held `suggestedGroup`, a
--     number that's almost never nil, so always "true" in Lua: everything
--     was mistaken for a header).
--  2. `GetQuestID()` (used here in an earlier version, with
--     `SelectQuestLogEntry`) doesn't exist at all on this client - verified
--     in-game. GetQuestLogTitle already returns the quest id directly (the
--     9th value above), no need to select the entry at all.
local function IsQuestTracked(questId)
    local numEntries = GetNumQuestLogEntries()
    for i = 1, numEntries do
        local _, _, _, _, isHeader, _, _, _, qid = GetQuestLogTitle(i)
        if not isHeader and qid == questId then
            return IsQuestWatched(i) and true or false
        end
    end
    return false
end

-- Hides and forgets every icon/area (module disabled, or no objective left
-- in the last sync).
local function ClearAll()
    for key, icon in pairs(icons) do
        icon:Hide()
        icons[key] = nil
    end
    for key, zone in pairs(zones) do
        zone:Hide()
        zones[key] = nil
    end
end

function QuestRadar.RefreshIcons()
    if not QuestRadar.db.enabled then
        ClearAll()
        return
    end

    local objectives = QuestRadar.objectives

    -- Objective groups to show (by ObjKey, not poiId alone - see the icons/
    -- zones comment above): present in the last sync, tracked if
    -- QuestRadar.db.onlyTracked is enabled (/qr tracked on|off) - otherwise
    -- everything the server knows for this map is shown -, and with an
    -- objectiveIndex >= 0 (a negative index, e.g. a generic quest turn-in
    -- spot, has no number to show - observed in-game: a numberless badge
    -- still showed up and was mistaken for a native NPC blip; not worth
    -- showing it at all).
    local shownKeys = {}
    for _, obj in ipairs(objectives) do
        local tracked = not QuestRadar.db.onlyTracked or IsQuestTracked(obj.questId)
        if tracked and obj.objectiveIndex and obj.objectiveIndex >= 0 then
            shownKeys[ObjKey(obj)] = true
        end
    end

    -- Removes icons/areas that shouldn't show anymore (quest turned
    -- in/abandoned, no longer tracked, or the area was disabled between
    -- two calls).
    for key, icon in pairs(icons) do
        if not shownKeys[key] then
            icon:Hide()
            icons[key] = nil
        end
    end
    for key, zone in pairs(zones) do
        if not shownKeys[key] or not QuestRadar.db.showArea then
            zone:Hide()
            zones[key] = nil
        end
    end

    if not QuestRadar.playerX or not QuestRadar.playerY then
        return
    end

    for _, obj in ipairs(objectives) do
      local key = ObjKey(obj)
      if shownKeys[key] then
        local icon = icons[key]
        if not icon then
            icon = CreateIconFrame()
            icons[key] = icon
        end
        SetIconTooltip(icon, obj)
        -- shownKeys already filters out negative objectiveIndex values (see
        -- above): obj.objectiveIndex is always >= 0 here.
        SetIconNumber(icon, obj.objectiveIndex + 1)
        -- Points to this group's stable center (areaX/areaY - simply
        -- equals (x,y) when it only has one point), not the precise
        -- nearest point (obj.x/obj.y): the latter can "jump" from one
        -- point to another within the same scattered group (e.g. several
        -- mobs) - observed in-game, the icon seemed to flee the player
        -- instead of getting closer. obj.distance (tooltip) still relies
        -- on the nearest point, which is correct for "how close am I to
        -- completing the objective".
        PlaceIconOnMinimap(icon, obj.areaX, obj.areaY, QuestRadar.playerX, QuestRadar.playerY)

        if HasArea(obj) then
            local zone = zones[key]
            if not zone then
                zone = CreateZoneFrame()
                zones[key] = zone
            end
            PlaceZoneOnMinimap(zone, obj.areaX, obj.areaY, obj.areaRadius, QuestRadar.playerX, QuestRadar.playerY)
        elseif zones[key] then
            zones[key]:Hide()
            zones[key] = nil
        end
      end
    end
end

-- Continuously repositions existing icons/areas: the player's own position
-- only refreshes every ~3s (cf. Core.lua, periodic server resync), but the
-- display should rotate/resize immediately if the player zooms/rotates
-- their minimap.
local updateFrame = CreateFrame("Frame")
local sinceLastRedraw = 0
local REDRAW_INTERVAL = 0.1
updateFrame:SetScript("OnUpdate", function(self, elapsed)
    sinceLastRedraw = sinceLastRedraw + elapsed
    if sinceLastRedraw < REDRAW_INTERVAL then
        return
    end
    sinceLastRedraw = 0

    if not QuestRadar.db.enabled then
        return
    end

    if not QuestRadar.playerX or not QuestRadar.playerY then
        return
    end

    for _, obj in ipairs(QuestRadar.objectives) do
        local key = ObjKey(obj)
        local icon = icons[key]
        if icon then
            PlaceIconOnMinimap(icon, obj.areaX, obj.areaY, QuestRadar.playerX, QuestRadar.playerY)
        end

        local zone = zones[key]
        if zone then
            PlaceZoneOnMinimap(zone, obj.areaX, obj.areaY, obj.areaRadius, QuestRadar.playerX, QuestRadar.playerY)
        end
    end
end)

-- Diagnostic called by the /qr command (Core.lua).
function QuestRadar.DebugInfo()
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cffffcc00[QuestRadar]|r [debug] player x=%s y=%s (mapId=%s) - minimap zoom=%s",
        tostring(QuestRadar.playerX), tostring(QuestRadar.playerY), tostring(QuestRadar.currentMapId),
        tostring(Minimap:GetZoom())))

    for _, obj in ipairs(QuestRadar.objectives) do
        local key = ObjKey(obj)
        local icon = icons[key]
        local zone = zones[key]
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cffffcc00[QuestRadar]|r [debug] quest %d poi=%s (%s) num=%s x=%.1f y=%.1f dist=%.1f areaRadius=%s tracked=%s: icon=%s zone=%s",
            obj.questId, tostring(obj.poiId), obj.title or "?", tostring((obj.objectiveIndex or 0) + 1), obj.x, obj.y, obj.distance or -1,
            tostring(obj.areaRadius), tostring(IsQuestTracked(obj.questId)),
            icon and "created" or "MISSING",
            zone and "created" or "none"))
    end
end
