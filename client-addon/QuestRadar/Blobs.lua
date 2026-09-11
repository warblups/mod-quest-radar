-- QuestRadar - Blobs.lua  (PROTOTYPE, off by default: /qr blobs)
--
-- Draws the quest search areas - the translucent blue shape the world map
-- shows when a quest is selected - on the minimap.
--
-- Why this can work at all: the client holds the quest_poi point lists in
-- memory and DrawQuestBlob() paints them, but NO Lua function returns their
-- geometry. The whole QuestPOIFrame surface on 3.3.5a is DrawQuestBlob,
-- GetNumTooltips, GetTooltipIndex and the four Set*Texture/Set*Alpha calls -
-- nothing that hands back a coordinate. So we never learn where the area is;
-- we let the client paint it for us and move the canvas instead.
--
-- The canvas is a QuestPOIFrame the size of the world map (1002x668, like
-- Blizzard's WorldMapBlobFrame). DrawQuestBlob maps normalised map coords
-- onto that rectangle. Scale it so its yards-per-pixel matches the minimap's,
-- anchor it so the player's own map position lands on the minimap centre, and
-- the painted area falls exactly where it belongs.
--
-- KNOWN RISK, and the whole point of the prototype: 3.3.5a has no
-- SetClipsChildren, and SetMaskTexture only masks the minimap's own terrain,
-- not frames drawn over it. If DrawQuestBlob does not confine itself to its
-- frame's rectangle, an area straddling the minimap edge will bleed outside.
-- Worth testing rather than assuming: the previous attempt at this feature
-- was never actually executed - its XML failed to parse, so the code never
-- ran and was never proven broken.

local QR = QuestRadar

local BLOB_W, BLOB_H = 1002, 668   -- WorldMapBlobFrame's size in WorldMapFrame.xml
local MAX_BLOBS = 8

-- Minimap diameter in yards per zoom level. Fixed client constants, copied
-- verbatim from !Astrolabe's private MinimapSize table - including its
-- 266 + 2/6 at zoom 3, where the exact figure would be 2/3. Matching the
-- library that places the icons matters more than being right on its behalf:
-- a different value here would drift the blobs against their own icons.
local MINIMAP_YARDS = {
    indoor  = { [0] = 300, 240, 180, 120, 80, 50 },
    outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 6, 200, 133 + 1 / 3 },
}

local blobs = {}
local shown = 0
local unsupported = false

local function GetBlob(index)
    if blobs[index] then return blobs[index] end
    if unsupported then return nil end

    -- QuestPOIFrame is a real widget type here (UI.xsd declares it, and
    -- WorldMapBlobFrame uses it), but guard anyway: a failure must degrade to
    -- "no blobs" rather than take the addon down with it.
    local ok, frame = pcall(CreateFrame, "QuestPOIFrame", "QuestRadarBlob" .. index, Minimap)
    if not ok or not frame or not frame.DrawQuestBlob then
        unsupported = true
        return nil
    end

    frame:SetWidth(BLOB_W)
    frame:SetHeight(BLOB_H)
    frame:SetFillTexture("Interface\\WorldMap\\UI-QuestBlob-Inside")
    frame:SetBorderTexture("Interface\\WorldMap\\UI-QuestBlob-Outside")
    frame:Hide()

    blobs[index] = frame
    return frame
end

function QR.HideBlobs()
    for i = 1, shown do
        if blobs[i] then blobs[i]:Hide() end
    end
    shown = 0
end

-- questIDs: the quests actually drawn as icons, in display order.
function QR.UpdateBlobs(questIDs, continent, zone)
    QR.HideBlobs()

    local db = QR.db
    if not db or not db.showBlobs or unsupported then return end
    if not questIDs or #questIDs == 0 then return end

    local A = QR.GetAstrolabe and QR.GetAstrolabe()
    if not A then return end

    local pC, pZ, px, py = A:GetCurrentPlayerPosition()
    if not pC or pC ~= continent or pZ ~= zone then return end

    -- Zone size in yards, straight out of Astrolabe's public ComputeDistance:
    -- the corner-to-corner deltas of the normalised map are its dimensions.
    local _, zoneW = A:ComputeDistance(continent, zone, 0, 0, continent, zone, 1, 0)
    local _, _, zoneH = A:ComputeDistance(continent, zone, 0, 0, continent, zone, 0, 1)
    if not zoneW or not zoneH or zoneW <= 0 or zoneH <= 0 then return end

    local sizes = A.minimapOutside and MINIMAP_YARDS.outdoor or MINIMAP_YARDS.indoor
    local diameter = sizes[Minimap:GetZoom()]
    if not diameter then return end

    -- Match the two scales: minimap pixels per yard over blob pixels per yard.
    local scale = (Minimap:GetWidth() / diameter) / (BLOB_W / zoneW)
    if scale <= 0 then return end

    local level = Minimap:GetFrameLevel() + 5   -- under the POI icons (+10)

    for i = 1, math.min(#questIDs, MAX_BLOBS) do
        local frame = GetBlob(i)
        if not frame then break end

        frame:SetScale(scale)
        frame:SetFrameLevel(level)
        frame:SetFillAlpha(db.blobAlpha or 96)
        frame:SetBorderAlpha(math.min(255, (db.blobAlpha or 96) + 64))

        -- Offsets are read in the frame's own (scaled) units, which is exactly
        -- the space the blob is painted in - so no division by scale here.
        -- Normalised y grows downward, hence the sign flip.
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", Minimap, "CENTER", -px * BLOB_W, py * BLOB_H)
        frame:Show()
        frame:DrawQuestBlob(questIDs[i], true)

        shown = i
    end
end
