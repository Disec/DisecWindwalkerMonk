local addonName, addon = ...

-- ============================================================
--  MinimapButton.lua — Midnight 12.0 minimap button
--
--  Midnight removed the old Minimap ring pattern and replaced
--  it with the "Addon Compartment" — the small [...] button
--  beside the minimap that houses all addon icons.
--
--  We implement BOTH:
--    1. AddonCompartment callbacks (declared in the TOC via
--       AddonCompartmentFunc / AddonCompartmentFuncOnEnter /
--       AddonCompartmentFuncOnLeave).  This is how the addon
--       shows up in the Midnight minimap addon list.  No extra
--       frame needed — Blizzard creates the slot automatically
--       when the TOC fields are set.
--
--    2. A legacy standalone minimap ring button that is shown
--       only when the player explicitly enables it via
--       /wwelite minimap show.  Hidden by default so users who
--       rely on the Compartment don't get a duplicate icon.
--
--  The two systems share the same click/tooltip logic via the
--  shared helper functions below.
-- ============================================================

-- ──────────────────────────────────────────────────────────────
--  Shared helpers — used by both the Compartment and the ring btn
-- ──────────────────────────────────────────────────────────────

local function OnLeftClick()
    if not addon.HUD then return end
    if addon.HUD:IsShown() then
        addon.HUD:Hide()
        if addon.db then addon.db.hudShown = false end
        addon:Print("HUD hidden.")
    else
        addon.HUD:Show()
        if addon.db then addon.db.hudShown = true end
        addon:Print("HUD shown.")
    end
end

local function OnRightClick()
    addon:CycleMode()
end

local function ShowTooltip(owner, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("|cff00e5ffWindWalkerElite|r  v2.3")
    GameTooltip:AddLine("Left-click: toggle HUD", 1, 1, 1)
    GameTooltip:AddLine("Right-click: cycle mode", 1, 1, 1)
    local modeData = addon:GetModeData()
    if modeData then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Mode: |cffffcc00" .. modeData.label .. "|r")
    end
    GameTooltip:Show()
end

-- ──────────────────────────────────────────────────────────────
--  1. Addon Compartment callbacks (Midnight primary path)
--     Blizzard calls these by name from the global environment.
--     They receive (addonName, menuList, button) per the API.
-- ──────────────────────────────────────────────────────────────

function WindWalkerElite_OnAddonCompartmentClick(name, menuList, btn)
    local mouseBtn = btn and btn:GetMouseButton() or "LeftButton"
    if mouseBtn == "RightButton" then
        OnRightClick()
    else
        OnLeftClick()
    end
end

function WindWalkerElite_OnAddonCompartmentEnter(name, btn)
    ShowTooltip(btn or UIParent, "ANCHOR_LEFT")
end

function WindWalkerElite_OnAddonCompartmentLeave(name, btn)
    GameTooltip:Hide()
end

-- ──────────────────────────────────────────────────────────────
--  2. Legacy standalone minimap ring button
--     Kept for players who prefer it over the Compartment.
--     Hidden by default in Midnight; shown only when
--     db.minimapRingShown == true (separate key from the
--     Compartment's visibility which Blizzard controls).
-- ──────────────────────────────────────────────────────────────

local BUTTON_SIZE = 30
local DB_KEY      = "minimapAngle"
local DB_RING_KEY = "minimapRingShown"  -- distinct from Compartment visibility

local function GetMinimapRadius()
    local w = Minimap:GetWidth()
    return (w and w > 0) and (w / 2) or 80
end

local btn = CreateFrame("Button", "WWEliteMinimapBtn", Minimap)
btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
btn:SetFrameStrata("MEDIUM")
btn:SetFrameLevel(8)
btn:SetClampedToScreen(false)

-- Icon
local btnIcon = btn:CreateTexture(nil, "ARTWORK")
btnIcon:SetAllPoints()
btnIcon:SetTexture("Interface\\Icons\\ability_monk_tigerpalm")
btnIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

-- Border ring
local btnBorder = btn:CreateTexture(nil, "OVERLAY")
btnBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
btnBorder:SetSize(BUTTON_SIZE + 12, BUTTON_SIZE + 12)
btnBorder:SetPoint("CENTER")

-- Highlight
btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

-- ── Positioning ──────────────────────────────────────────────
local function PositionButton(angle)
    local rad    = math.rad(angle)
    local radius = GetMinimapRadius()
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(rad) * radius,
        math.sin(rad) * radius)
end

local function SaveAngle(angle)
    if addon.db then addon.db[DB_KEY] = angle end
end

local function LoadAngle()
    return (addon.db and addon.db[DB_KEY]) or 220
end

-- ── Drag ─────────────────────────────────────────────────────
local isDragging = false

btn:SetMovable(true)
btn:RegisterForDrag("LeftButton")
btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

btn:SetScript("OnDragStart", function(self)
    isDragging = true
    self:SetScript("OnUpdate", function()
        local mx, my   = Minimap:GetCenter()
        local cx, cy   = GetCursorPosition()
        local scale    = UIParent:GetEffectiveScale()
        cx, cy         = cx / scale, cy / scale
        local angle    = math.deg(math.atan2(cy - my, cx - mx))
        if angle < 0 then angle = angle + 360 end
        PositionButton(angle)
        SaveAngle(angle)
    end)
end)

btn:SetScript("OnDragStop", function(self)
    isDragging = false
    self:SetScript("OnUpdate", nil)
end)

-- ── Clicks ───────────────────────────────────────────────────
btn:SetScript("OnClick", function(self, mouseBtn)
    if isDragging then return end
    if mouseBtn == "RightButton" then OnRightClick()
    else OnLeftClick() end
end)

-- ── Tooltip ──────────────────────────────────────────────────
btn:SetScript("OnEnter", function(self) ShowTooltip(self, "ANCHOR_LEFT") end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ── Init / visibility ────────────────────────────────────────
local mmInitFrame = CreateFrame("Frame")
mmInitFrame:RegisterEvent("PLAYER_LOGIN")
mmInitFrame:SetScript("OnEvent", function()
    PositionButton(LoadAngle())
    -- Ring button is hidden by default in Midnight; only show
    -- when the player has explicitly opted in.
    if addon.db and addon.db[DB_RING_KEY] == true then
        btn:Show()
    else
        btn:Hide()
    end
end)

-- ── Public API ───────────────────────────────────────────────
-- Controls the legacy ring button only.
-- The Compartment slot is always present when the TOC fields are set;
-- it cannot be hidden from Lua — only the player can pin/unpin it.
function addon:ShowMinimapButton(show)
    if show then
        btn:Show()
        if addon.db then addon.db[DB_RING_KEY] = true end
        addon:Print("Minimap ring button shown. "
            .. "(The Addon Compartment slot is always available.)")
    else
        btn:Hide()
        if addon.db then addon.db[DB_RING_KEY] = false end
        addon:Print("Minimap ring button hidden. "
            .. "Use the [...] Addon Compartment next to the minimap instead.")
    end
end
