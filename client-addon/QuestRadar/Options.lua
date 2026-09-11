-- QuestRadar - Options.lua
--
-- Native options panel (Esc > Interface > AddOns > QuestRadar), alongside the
-- /qr commands. Both read and write the same QuestRadarDB, so there is no
-- Okay/Cancel: every control applies immediately, exactly like a command.
--
-- Standard Blizzard widgets only (InterfaceOptionsCheckButtonTemplate,
-- OptionsSliderTemplate, InterfaceOptions_AddCategory) - no Ace3, no
-- third-party dependency, matching the rest of the addon.

local QR = QuestRadar

local panel = CreateFrame("Frame", "QuestRadarOptionsPanel", UIParent)
panel.name = "QuestRadar"

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("QuestRadar")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
subtitle:SetJustifyH("LEFT")
subtitle:SetText("Objectifs de quete sur le minimap. Ces reglages sont aussi accessibles via /qr.")

-- 3.3.5 templates expose their label as the global <name>Text; newer ones use
-- the parentKey. Handle both so this survives a template change.
local function LabelOf(frame, suffix)
    local name = frame:GetName()
    return (suffix == "Text" and frame.Text) or (name and _G[name .. suffix])
end

local function CreateCheckbox(key, anchor, label, tooltip)
    local check = CreateFrame("CheckButton", "QuestRadarOptions" .. key, panel,
        "InterfaceOptionsCheckButtonTemplate")
    check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)

    local text = LabelOf(check, "Text")
    if text then text:SetText(label) end
    check.tooltipText = label
    check.tooltipRequirement = tooltip

    check:SetScript("OnClick", function(self)
        QR.db[key] = self:GetChecked() and true or false
        QR.ApplySettings()
    end)
    check:SetScript("OnShow", function(self)
        self:SetChecked(QR.db[key] and true or false)
    end)

    return check
end

local enabled = CreateCheckbox("enabled", subtitle, "Activer QuestRadar",
    "Affiche ou masque completement les icones d'objectifs.")

local onlyTracked = CreateCheckbox("onlyTracked", enabled, "Limiter aux quetes suivies",
    "N'affiche que les quetes cochees dans le suivi d'objectifs. Decoche, affiche toutes les quetes de la zone.")

local showCompleted = CreateCheckbox("showCompleted", onlyTracked, "Afficher les quetes terminees",
    "Affiche l'icone de rendu (?) pour les quetes pretes a etre rendues.")

local showOffscreen = CreateCheckbox("showOffscreen", showCompleted, "Afficher les objectifs hors de portee",
    "Les objectifs trop loin se collent au bord du minimap, legerement attenues.")

local showBlobs = CreateCheckbox("showBlobs", showOffscreen, "Zones de recherche (prototype)",
    "Dessine la zone translucide que la carte du monde affiche pour un objectif imprecis. Experimental : peut deborder du minimap.")

-- Icon size. The slider is only committed on release: dragging it would
-- otherwise rebuild every icon on each pixel of travel.
local scale = CreateFrame("Slider", "QuestRadarOptionsScale", panel, "OptionsSliderTemplate")
scale:SetPoint("TOPLEFT", showBlobs, "BOTTOMLEFT", 6, -24)
scale:SetMinMaxValues(0.5, 3)
scale:SetValueStep(0.1)
scale:SetWidth(200)

local scaleLow = LabelOf(scale, "Low")
local scaleHigh = LabelOf(scale, "High")
local scaleText = LabelOf(scale, "Text")
if scaleLow then scaleLow:SetText("0.5") end
if scaleHigh then scaleHigh:SetText("3") end

local function UpdateScaleLabel(value)
    if scaleText then
        scaleText:SetText(string.format("Taille des icones : %.1f", value))
    end
end

scale:SetScript("OnShow", function(self)
    self.settingValue = true
    self:SetValue(QR.db.scale or 1)
    UpdateScaleLabel(QR.db.scale or 1)
    self.settingValue = nil
end)

scale:SetScript("OnValueChanged", function(self, value)
    -- Round to the step: SetValueStep does not constrain the reported value on
    -- this client, so without this the label drifts to 1.2999999523163.
    value = math.floor(value * 10 + 0.5) / 10
    UpdateScaleLabel(value)
    if self.settingValue then return end
    QR.db.scale = value
    QR.ApplySettings()
end)

InterfaceOptions_AddCategory(panel)
