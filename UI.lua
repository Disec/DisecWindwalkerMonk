local addonName, addon = ...

-- ============================================================
--  UI.lua — HUD + slash commands  (v2.5)
--
--  v2.5 changes:
--    • Added slash commands for new glow settings:
--        /wwelite glow texture|pixel|autocast
--        /wwelite cooldowns on|off
--        /wwelite defensives on|off
--        /wwelite interrupts on|off
--        /wwelite combat        — toggle onCombatEnter mode
--        /wwelite enable / disable  — manual rotation toggle
--        /wwelite bars          — re-scan action bars now
--    • /wwelite status shows rotation state and button count.
--    • Version bump to v2.5.
-- ============================================================

SLASH_WWELITE1 = "/wwelite"
SLASH_WWELITE2 = "/wwe"

local UPDATE_RATE = 0.05
local elapsed     = 0

local PARALYSIS         = 115078
local SPEAR_HAND_STRIKE = 116705

-- ── HUD frame ────────────────────────────────────────────────
local HUD = CreateFrame("Frame", "WWEliteHUD", UIParent)
HUD:SetSize(220, 90)
HUD:SetPoint("CENTER", UIParent, "CENTER", 0, -140)
HUD:SetMovable(true)
HUD:EnableMouse(true)
HUD:RegisterForDrag("LeftButton")
HUD:SetFrameStrata("HIGH")
HUD:SetClampedToScreen(true)

local hudBG = HUD:CreateTexture(nil, "BACKGROUND")
hudBG:SetAllPoints()
hudBG:SetColorTexture(0, 0, 0, 0.55)

HUD:SetScript("OnDragStart", function(self)
    if addon.db and addon.db.locked then return end
    self:StartMoving()
end)
HUD:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local _, _, _, x, y = self:GetPoint()
    if addon.db then addon.db.hudX = x; addon.db.hudY = y end
end)

-- Main icon
local main = CreateFrame("Frame", nil, HUD)
main:SetSize(72, 72)
main:SetPoint("LEFT", HUD, "LEFT", 8, 0)

main.icon = main:CreateTexture(nil, "ARTWORK")
main.icon:SetAllPoints()
main.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

main.glow = main:CreateTexture(nil, "OVERLAY")
main.glow:SetPoint("CENTER", main.icon, "CENTER", 0, 0)
main.glow:SetSize(86, 86)
main.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
main.glow:SetBlendMode("ADD")
main.glow:SetAlpha(0.85)
main.glow:Hide()

main.cooldown = CreateFrame("Cooldown", nil, main, "CooldownFrameTemplate")
main.cooldown:SetAllPoints()

main.keybind = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
main.keybind:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -4, 4)
main.keybind:SetTextColor(1, 1, 1, 1)
main.keybind:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")

main.interruptLabel = main:CreateFontString(nil, "OVERLAY")
main.interruptLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
main.interruptLabel:SetPoint("TOP", main, "TOP", 0, 10)
main.interruptLabel:SetTextColor(1, 0.2, 0.2, 1)
main.interruptLabel:SetText("KICK!")
main.interruptLabel:Hide()

-- Queue icons
local queueFrames = {}
for i = 1, 3 do
    local f = CreateFrame("Frame", nil, HUD)
    f:SetSize(44, 44)
    if i == 1 then
        f:SetPoint("LEFT", main, "RIGHT", 12, 10)
    else
        f:SetPoint("LEFT", queueFrames[i-1], "RIGHT", 6, 0)
    end
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.dim = f:CreateTexture(nil, "OVERLAY")
    f.dim:SetAllPoints()
    f.dim:SetColorTexture(0, 0, 0, 0.45)
    f.dim:Hide()
    queueFrames[i] = f
end

-- Mode label
local modeLabel = HUD:CreateFontString(nil, "OVERLAY")
modeLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
modeLabel:SetPoint("BOTTOMRIGHT", HUD, "BOTTOMRIGHT", -4, 3)
modeLabel:SetTextColor(1, 0.85, 0, 0.9)

-- Rotation-active indicator (small dot bottom-left)
local rotDot = HUD:CreateFontString(nil, "OVERLAY")
rotDot:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
rotDot:SetPoint("BOTTOMLEFT", HUD, "BOTTOMLEFT", 4, 3)

-- ── Helpers ───────────────────────────────────────────────────
local function SetIcon(frame, spellID)
    if not spellID then frame:Hide(); return end
    local tex = C_Spell.GetSpellTexture(spellID)
    if tex then
        frame.icon:SetTexture(tex)
        frame:Show()
    else
        frame:Hide()
    end
end

local function IsSpellReadyOrSoon(spellID)
    if not spellID then return false end
    return addon:SpellCooldownPct(spellID) == 0
end

-- ── HUD update ────────────────────────────────────────────────
local function UpdateHUD()
    if not addon.GetRecommendations then return end
    local mainSpell, nextQueue = addon:GetRecommendations()

    -- Rotation-active dot
    if addon.rotationTimer ~= nil then
        rotDot:SetText("|cff00ff00●|r")
    else
        rotDot:SetText("|cffff4444●|r")
    end

    if not mainSpell then
        main.glow:Hide()
        main.interruptLabel:Hide()
        main.icon:SetTexture(nil)
        main.keybind:SetText("")
        for i = 1, 3 do queueFrames[i]:Hide() end
        return
    end

    SetIcon(main, mainSpell)
    main.keybind:SetText(addon:GetSpellKeybind(mainSpell))
    main.glow:Show()

    -- Interrupt colour treatment (Paralysis or Spear Hand Strike in primary slot)
    if mainSpell == PARALYSIS or mainSpell == SPEAR_HAND_STRIKE then
        main.glow:SetVertexColor(1, 0.15, 0.15, 0.9)
        main.interruptLabel:Show()
    else
        main.glow:SetVertexColor(1, 0.82, 0, 0.85)
        main.interruptLabel:Hide()
    end

    local info = addon:SpellCooldownInfo(mainSpell)
    if info and info.startTime and info.duration and info.startTime > 0 then
        main.cooldown:SetCooldown(info.startTime, info.duration)
    else
        main.cooldown:SetCooldown(0, 0)
    end

    for i = 1, 3 do
        local spellID = nextQueue and nextQueue[i]
        if spellID then
            SetIcon(queueFrames[i], spellID)
            queueFrames[i].dim:SetShown(not IsSpellReadyOrSoon(spellID))
        else
            queueFrames[i]:Hide()
        end
    end

    local modeData = addon:GetModeData()
    if modeData then modeLabel:SetText(modeData.label) end
end

function HUD:UpdateModeLabel()
    local modeData = addon:GetModeData()
    if modeData then modeLabel:SetText(modeData.label) end
end

-- ── OnUpdate ──────────────────────────────────────────────────
HUD:SetScript("OnUpdate", function(self, delta)
    elapsed = elapsed + delta
    if elapsed < UPDATE_RATE then return end
    elapsed = 0

    local isWW    = addon.talents and addon.talents.isWindwalker
    local preview = addon.db and addon.db.preview
    local shouldShow = isWW and (addon.state.inCombat or preview)

    if not shouldShow then
        if self:IsShown() then
            main.glow:Hide()
            main.interruptLabel:Hide()
            self:Hide()
        end
        return
    end

    if not self:IsShown() then self:Show() end
    UpdateHUD()
end)

-- ── Slash commands ────────────────────────────────────────────
SlashCmdList["WWELITE"] = function(msg)
    msg = string.lower(msg or ""):match("^%s*(.-)%s*$")

    -- ── Preview / combat-only ──────────────────────────────────
    if msg == "preview" then
        addon.db.preview = true
        addon:Print("Preview mode |cFF00FF00ON|r — HUD visible outside combat.")

    elseif msg == "nopreview" or msg == "combatonly" then
        addon.db.preview = false
        addon:Print("Preview mode |cFFFF0000OFF|r — combat only.")

    -- ── Rotation on/off ───────────────────────────────────────
    elseif msg == "enable" then
        addon.db.rotationEnabled = true
        addon:EnableRotation()

    elseif msg == "disable" then
        addon.db.rotationEnabled = false
        addon:DisableRotation()

    -- ── onCombatEnter toggle ──────────────────────────────────
    elseif msg == "combat" then
        addon.db.onCombatEnter = not addon.db.onCombatEnter
        addon:Print("Combat-only mode: " ..
            (addon.db.onCombatEnter and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))

    -- ── Re-scan bars ──────────────────────────────────────────
    elseif msg == "bars" or msg == "fetch" then
        addon:Fetch("manual")
        addon:Print("Action bars re-scanned.")

    -- ── Lock / reset / hud toggle ─────────────────────────────
    elseif msg == "lock" then
        addon.db.locked = not addon.db.locked
        HUD:EnableMouse(not addon.db.locked)
        addon:Print("HUD " .. (addon.db.locked and "|cFFFF0000LOCKED|r" or "|cFF00FF00UNLOCKED|r"))

    elseif msg == "reset" then
        HUD:ClearAllPoints()
        HUD:SetPoint("CENTER", UIParent, "CENTER", 0, -140)
        addon.db.hudX = nil; addon.db.hudY = nil
        addon:Print("HUD position reset.")

    elseif msg == "hud" then
        if HUD:IsShown() then
            HUD:Hide(); addon.db.hudShown = false
            addon:Print("HUD hidden.")
        else
            HUD:Show(); addon.db.hudShown = true
            addon:Print("HUD shown.")
        end

    -- ── Glow style ────────────────────────────────────────────
    elseif msg:match("^glow%s") then
        local style = msg:match("^glow%s+(%S+)$")
        if style == "texture" or style == "pixel" or style == "autocast" then
            addon.db.glowStyle = style
            addon:Print("Glow style set to |cffffcc00" .. style .. "|r.")
        else
            addon:Print("Usage: /wwelite glow texture|pixel|autocast")
        end

    -- ── Secondary glow toggles ────────────────────────────────
    elseif msg:match("^cooldowns%s") then
        local val = msg:match("^cooldowns%s+(%S+)$")
        addon.db.enableCooldowns = (val == "on")
        addon:Print("Cooldown glows: " .. (addon.db.enableCooldowns and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))

    elseif msg:match("^defensives%s") then
        local val = msg:match("^defensives%s+(%S+)$")
        addon.db.enableDefensives = (val == "on")
        addon:Print("Defensive glows: " .. (addon.db.enableDefensives and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))

    elseif msg:match("^interrupts%s") then
        local val = msg:match("^interrupts%s+(%S+)$")
        addon.db.enableInterrupts = (val == "on")
        addon:Print("Interrupt glows: " .. (addon.db.enableInterrupts and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))

    -- ── Mode ──────────────────────────────────────────────────
    elseif msg:match("^mode%s") then
        local modeName = msg:match("^mode%s+(%S+)$")
        if modeName then
            addon:SetMode(modeName)
        else
            addon:Print("Usage: /wwelite mode <auto|single|aoe|cooldown|mythic|raid>")
        end

    -- ── SimC ──────────────────────────────────────────────────
    elseif msg == "simcshow" then
        addon:ShowSimcImport()

    elseif msg:match("^import%s") then
        local apl = msg:match("^import%s+(.+)$")
        if apl then addon:ImportSimc(apl)
        else addon:Print("Usage: /wwelite import <SimC APL string>") end

    -- ── Minimap ───────────────────────────────────────────────
    elseif msg == "minimap" or msg == "minimap show" then
        addon:ShowMinimapButton(true)
    elseif msg == "minimap hide" then
        addon:ShowMinimapButton(false)

    -- ── Debug ─────────────────────────────────────────────────
    elseif msg == "debug" then
        addon.db.debug = not addon.db.debug
        addon:Print("Debug mode " .. (addon.db.debug and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))

    -- ── Version ───────────────────────────────────────────────
    elseif msg == "version" then
        addon:Print("v2.5 — Midnight 12.0.5 (Zenith, bar glows, MaxDPS glow channels)")

    -- ── Status ────────────────────────────────────────────────
    elseif msg == "status" then
        local isWW = addon.talents and addon.talents.isWindwalker
        local t    = addon.talents or {}
        local btnCount = (function()
            local c = 0
            for _ in pairs(addon.Spells or {}) do c = c + 1 end
            return c
        end)()
        addon:Print("=== WWElite v2.5 Status ===")
        addon:Print("Windwalker: " .. tostring(isWW))
        addon:Print("Rotation:   " .. (addon.rotationTimer and "|cff00ff00RUNNING|r" or "|cffff4444STOPPED|r"))
        addon:Print("Mode:       " .. tostring(addon.state.mode))
        addon:Print("In combat:  " .. tostring(addon.state.inCombat))
        addon:Print("onCombat:   " .. tostring(addon.db.onCombatEnter))
        addon:Print("Chi:        " .. tostring(addon:GetChi()))
        addon:Print("Targets:    " .. tostring(addon:EffectiveTargetCount()))
        addon:Print("TTD:        " .. string.format("%.1f s", addon:GetTimeToDie()))
        addon:Print("Target HP:  " .. string.format("%.0f%%", addon.state.targetHpPct or 100))
        addon:Print("Bar spells: " .. btnCount .. " spell IDs registered")
        addon:Print("Glow style: " .. tostring(addon.db.glowStyle))
        addon:Print(string.format(
            "Talents: WDP=%s SOTWL=%s Zenith=%s Ser=%s SlicWind=%s",
            tostring(t.hasWhirlingDragonPunch), tostring(t.hasStrikeOfWindlord),
            tostring(t.hasZenith), tostring(t.hasSerenity), tostring(t.hasSlicingWinds)
        ))

    -- ── Help (default) ────────────────────────────────────────
    elseif msg == "" or msg == "help" then
        addon:Print("|cff00e5ffWWElite v2.5|r — commands:")
        addon:Print("  enable / disable       — toggle rotation")
        addon:Print("  combat                 — toggle combat-only mode")
        addon:Print("  bars                   — re-scan action bars")
        addon:Print("  preview / combatonly   — HUD visibility")
        addon:Print("  lock / reset / hud     — HUD controls")
        addon:Print("  mode <name>            — auto|single|aoe|cooldown|mythic|raid")
        addon:Print("  glow texture|pixel|autocast")
        addon:Print("  cooldowns on|off  |  defensives on|off  |  interrupts on|off")
        addon:Print("  status / debug / version / minimap")
    end
end

-- ── Init ─────────────────────────────────────────────────────
local uiLoader = CreateFrame("Frame")
uiLoader:RegisterEvent("PLAYER_LOGIN")
uiLoader:SetScript("OnEvent", function()
    addon.HUD = HUD

    if addon.db and addon.db.hudX then
        HUD:ClearAllPoints()
        HUD:SetPoint("CENTER", UIParent, "CENTER", addon.db.hudX, addon.db.hudY or -140)
    end

    if addon.db and addon.db.locked then HUD:EnableMouse(false) end

    if addon.ProcPanel and addon.ProcPanel.AnchorTo then
        addon.ProcPanel:AnchorTo(HUD)
    end

    HUD:Hide()
    addon:Print("v2.5 loaded. Type |cffffcc00/wwelite|r for commands.")
end)
