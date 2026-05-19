local addonName, addon = ...

-- ============================================================
--  EncounterDB — per-encounter tuning profiles
--
--  Profiles are consulted by the APL for threshold tweaks.
--  All values are plain Lua numbers — no Secret Values involved.
--
--  Previously, profile selection was coupled to addon.state.mode,
--  which meant modes like "cooldown", "single", and "aoe" always
--  fell through to the "default" profile even inside a Mythic+
--  dungeon or raid.
--
--  Now: encounter context is detected from the actual instance
--  type via IsInInstance(), and the rotation mode is consulted
--  only as an explicit override when the player has set "mythic"
--  or "raid" mode manually (preserving that intentional behaviour).
--  All other modes get the profile that matches where they are.
-- ============================================================

addon.encounters = {

    -- Mythic+ — punish casters, aggressive AOE, use all CDs
    mythicPlus = {
        interruptPriority   = true,    -- surface interrupt above all else
        defensiveThreshold  = 0.40,    -- pop Touch of Karma below 40% HP
        aoeFocus            = true,
        holdBurstForPacks   = true,    -- hold SEF for multi-target packs
    },

    -- Raid — conservative defensives, hold burst for burn phases
    raid = {
        interruptPriority   = false,
        defensiveThreshold  = 0.65,    -- earlier defensive usage in raid
        burstWindows        = true,    -- respect burn/lust windows
        holdBurstForPacks   = false,
    },

    -- Default / open world — no special handling
    default = {
        interruptPriority   = false,
        defensiveThreshold  = 0.30,
        burstWindows        = false,
        holdBurstForPacks   = false,
    },
}

-- ──────────────────────────────────────────────────────────────
--  Encounter profile resolution
--
--  Priority order:
--    1. Explicit mode override ("mythic" or "raid") — player chose
--       this deliberately, respect it regardless of instance type.
--    2. Actual instance type from IsInInstance():
--         "party"  → Mythic+ / 5-man dungeon → mythicPlus profile
--         "raid"   → any raid instance        → raid profile
--    3. Fallback to default (open world, scenarios, etc.)
-- ──────────────────────────────────────────────────────────────
function addon:GetEncounterProfile()
    local mode = addon.state.mode

    -- Explicit overrides honour the player's manual mode selection.
    if mode == "mythic" then
        return addon.encounters.mythicPlus
    elseif mode == "raid" then
        return addon.encounters.raid
    end

    -- For all other modes, use actual instance context.
    local inInstance, instanceType = IsInInstance()
    if inInstance then
        if instanceType == "party" then
            -- Covers Mythic+, normal/heroic 5-mans
            return addon.encounters.mythicPlus
        elseif instanceType == "raid" then
            return addon.encounters.raid
        end
        -- "pvp", "arena", "scenario" → fall through to default
    end

    return addon.encounters.default
end

-- Convenience: is interrupt priority active for the current encounter?
function addon:InterruptPriority()
    return self:GetEncounterProfile().interruptPriority
end

-- Defensive threshold (0-1 HP fraction)
function addon:DefensiveThreshold()
    return self:GetEncounterProfile().defensiveThreshold
end
