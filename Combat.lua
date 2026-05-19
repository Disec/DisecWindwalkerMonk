local addonName, addon = ...

-- ============================================================
--  Combat.lua — event handling, nameplate tracking, TTD
--
--  FIX (critical): The original file was truncated — it had
--  the event registration loop and two helper functions but
--  NO OnEvent handler.  Every registered event fired into
--  the void.  inCombat was never set, TTD was never updated,
--  HUD show/hide never triggered from combat transitions.
--  This is a complete rewrite of the missing half.
-- ============================================================

local combatFrame = CreateFrame("Frame")

local EVENTS = {
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_TARGET_CHANGED",
    "PLAYER_ENTERING_WORLD",
    "NAME_PLATE_UNIT_ADDED",
    "NAME_PLATE_UNIT_REMOVED",
    "UNIT_POWER_UPDATE",
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_HEALTH",
    "UNIT_DIED",
    "UNIT_AURA",
}
for _, e in ipairs(EVENTS) do combatFrame:RegisterEvent(e) end

-- ──────────────────────────────────────────────────────────────
--  Nameplate counter
--  Tracks visible hostile nameplates so the Engine knows how
--  many targets are genuinely in range for AoE decisions.
-- ──────────────────────────────────────────────────────────────
local nameplateUnits = {}   -- [unitToken] = true

local function RebuildNameplateCount()
    local count = 0
    for _ in pairs(nameplateUnits) do count = count + 1 end
    -- Always count at least the focused target if one exists.
    if UnitExists("target") then count = math.max(count, 1) end
    addon.state.targetCount = count
end

-- HUD visibility is owned entirely by UI.lua's OnUpdate tick.
-- Combat.lua only manages addon.state.inCombat; the HUD reads
-- that flag on every tick and shows/hides itself atomically.
-- This prevents the flicker that occurred when combat events and
-- target-change events raced against the update loop's partial state.

-- ──────────────────────────────────────────────────────────────
--  OnEvent — the missing handler
-- ──────────────────────────────────────────────────────────────
combatFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)

    -- ── Combat state ─────────────────────────────────────────
    if event == "PLAYER_REGEN_DISABLED" then
        addon.state.inCombat = true
        addon:ResetTTD()

    elseif event == "PLAYER_REGEN_ENABLED" then
        addon.state.inCombat = false
        addon:ResetTTD()
        -- Wipe proc panel on combat end
        if addon.ProcPanel then addon.ProcPanel:Hide() end

    -- ── World entry — full state refresh ─────────────────────
    elseif event == "PLAYER_ENTERING_WORLD" then
        addon.state.inCombat   = UnitAffectingCombat("player") or false
        addon.state.targetCount = 1
        wipe(nameplateUnits)
        addon:ResetTTD()
        addon:RefreshProcs()
        -- HUD visibility is driven by OnUpdate — no show/hide here

    -- ── Target changed ───────────────────────────────────────
    elseif event == "PLAYER_TARGET_CHANGED" then
        addon:ResetTTD()
        RebuildNameplateCount()

    -- ── Nameplate tracking ───────────────────────────────────
    -- FIX: original code declared nameplateUnits and RebuildNameplateCount
    -- but never wired them to the NAME_PLATE events, so targetCount was
    -- always 1.  AoE rotation never activated from nameplate data.
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- arg1 = unitToken (e.g. "nameplate1")
        if arg1 and UnitExists(arg1) and UnitCanAttack("player", arg1) then
            nameplateUnits[arg1] = true
        end
        RebuildNameplateCount()

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        nameplateUnits[arg1] = nil
        RebuildNameplateCount()

    -- ── Resource update ──────────────────────────────────────
    elseif event == "UNIT_POWER_UPDATE" then
        -- arg1 = unit, arg2 = powerType string
        if arg1 == "player" then
            addon:UpdateChi()
        end

    -- ── Health / TTD ─────────────────────────────────────────
    elseif event == "UNIT_HEALTH" then
        -- arg1 = unit
        if arg1 == "player" then
            addon:SnapshotPlayerHp()
        elseif arg1 == "target" then
            addon:SnapshotTTD()
        else
            -- Nameplate unit — per-unit TTD for AoE gating
            addon:SnapshotTTDUnit(arg1)
        end

    elseif event == "UNIT_DIED" then
        -- Clean up nameplate entry and TTD data for the dead unit
        if arg1 then
            nameplateUnits[arg1] = nil
            addon:PurgeTTDUnit(arg1)
            RebuildNameplateCount()
        end

    -- ── Aura refresh ─────────────────────────────────────────
    elseif event == "UNIT_AURA" then
        if arg1 == "player" then
            addon:RefreshProcs()
        end

    -- ── Spellcast events (interrupt surface / cast tracking) ─
    elseif event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- arg1 = unit — currently consumed by interrupt priority logic
        -- in the APL; no state change needed here beyond being available.
        _ = arg1  -- suppress unused warning
    end

end)
-- ── Combat-enter rotation auto-enable (mirrors MaxDps pattern) ─
-- This supplementary frame listens for combat transitions and
-- enables/disables the rotation when onCombatEnter mode is active.
-- It is separate from the main combatFrame above so the two
-- concerns stay independent and easy to reason about.

local combatAutoFrame = CreateFrame("Frame")
combatAutoFrame:RegisterEvent("PLAYER_REGEN_DISABLED")   -- entered combat
combatAutoFrame:RegisterEvent("PLAYER_REGEN_ENABLED")    -- left combat
combatAutoFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
combatAutoFrame:RegisterEvent("UNIT_EXITED_VEHICLE")

combatAutoFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Always snap talent / bar state on combat entry
        if addon.SnapshotTalents then addon:SnapshotTalents() end

        if addon.db and addon.db.onCombatEnter then
            addon:EnableRotation()
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if addon.db and addon.db.onCombatEnter then
            addon:DisableRotation()
        end

    elseif event == "UNIT_ENTERED_VEHICLE" then
        if unit == "player" then
            addon:DisableRotation()
        end

    elseif event == "UNIT_EXITED_VEHICLE" then
        if unit == "player" then
            C_Timer.After(0.5, function()
                addon:SnapshotTalents()
                addon:EnableRotation()
            end)
        end
    end
end)
