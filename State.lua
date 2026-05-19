local addonName, addon = ...

-- ============================================================
--  State.lua — fast resource & cooldown cache
--
--  Fixes vs original:
--  1. Registered UNIT_POWER_FREQUENT but the OnEvent handler
--     only branched on "UNIT_POWER_UPDATE".  The frequent event
--     therefore never updated chi.  Changed to match the actual
--     registered event name.
--
--  2. addon:SpellReady() was defined here AND in Utils.lua with
--     conflicting logic.  Utils.lua's version (which uses
--     SpellCooldownPct and honours the disabled-spells list) is
--     the canonical one.  Removed the duplicate from State.lua.
--
--  3. addon:HasBuff() hard-coded 393565 as "Dance of Chi-Ji"
--     but Dance of Chi-Ji is 325201.  Fixed.
--
--  4. CacheAuras was saving addon.safe.dance using spellID 393565
--     (wrong); updated to 325201 to match Procs.lua TRACKED table.
--
--  5. UNIT_POWER_UPDATE event was registered but the handler used
--     "UNIT_POWER_FREQUENT" as the branch key — they never matched.
--     Unified: register UNIT_POWER_FREQUENT (fires more often) and
--     branch on that string.
-- ============================================================

addon.cooldowns = addon.cooldowns or {}
addon.state     = addon.state     or {}
addon.safe      = addon.safe      or {}

local stateFrame = CreateFrame("Frame")

-- FIX: register UNIT_POWER_FREQUENT (not UPDATE) — it's the high-frequency
-- chi/energy event used by rotation addons.  UPDATE fires much less often.
stateFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
stateFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
stateFrame:RegisterEvent("UNIT_POWER_FREQUENT")
stateFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
stateFrame:RegisterEvent("UNIT_AURA")

local function SafeNumber(value)
    if not value then return 0 end
    local n = tonumber(value)
    return n or 0
end

-- ── Cooldown cache ───────────────────────────────────────────
-- Store raw startTime/duration from C_Spell for the Engine's
-- fallback path.  Never do arithmetic on duration here — it may
-- be a Secret Value.  Only used by SpellReady's last-resort branch.
local function CacheCooldowns()
    for _, spellID in pairs(addon.spells) do
        local info = C_Spell.GetSpellCooldown(spellID)
        if info then
            addon.cooldowns[spellID] = {
                startTime = SafeNumber(info.startTime),
                duration  = SafeNumber(info.duration),
            }
        end
    end
end

-- ── Chi cache ────────────────────────────────────────────────
local function CacheResources()
    addon.state.chi = SafeNumber(UnitPower("player", Enum.PowerType.Chi))
    -- NOTE: UnitPowerPercent() returns a Secret Value in Midnight combat.
    -- Do NOT store or compare it.  energyPct is intentionally not cached.
end

-- ── Target count (nameplate scan fallback) ───────────────────
-- Primary target counting is done by Combat.lua via NAME_PLATE events.
-- This is a fallback for the initial frame before any plates are seen.
local function CacheTargets()
    if (addon.state.targetCount or 0) > 0 then return end  -- Combat.lua owns this
    local plates = C_NamePlate.GetNamePlates()
    if plates then
        local count = 0
        for _, plate in pairs(plates) do
            local unit = plate.namePlateUnitToken
            if unit and UnitCanAttack("player", unit) and not UnitIsDead(unit) then
                count = count + 1
            end
        end
        addon.state.targetCount = math.max(1, count)
    else
        addon.state.targetCount = UnitExists("target") and 1 or 0
    end
end

-- ── Aura snapshot ────────────────────────────────────────────
-- FIX: original used 393565 for Dance of Chi-Ji — wrong ID.
-- Dance of Chi-Ji aura is 325201 (matches Procs.lua TRACKED).
local DANCE_OF_CHIJI = 325201

local function CacheAuras()
    addon.safe.dance = C_UnitAuras.GetPlayerAuraBySpellID(DANCE_OF_CHIJI) ~= nil
end

-- ── Event handler ────────────────────────────────────────────
stateFrame:SetScript("OnEvent", function(_, event, unit)
    -- FIX: original branched on "UNIT_POWER_FREQUENT" but had registered
    -- "UNIT_POWER_UPDATE" — they never matched, so chi never updated on
    -- the fast path.  Both strings now handled correctly.
    if event == "UNIT_POWER_FREQUENT" or event == "UNIT_POWER_UPDATE" then
        if unit == "player" then CacheResources() end

    elseif event == "PLAYER_TARGET_CHANGED" then
        CacheTargets()

    elseif event == "UNIT_AURA" then
        if unit == "player" then CacheAuras() end

    else
        -- SPELL_UPDATE_COOLDOWN, PLAYER_ENTERING_WORLD — full refresh
        CacheCooldowns()
        CacheResources()
        CacheTargets()
        CacheAuras()
    end
end)

-- ── Public API ───────────────────────────────────────────────
-- NOTE: addon:SpellReady() is defined in Utils.lua (canonical).
-- It is NOT redefined here to avoid the duplicate/conflict.

function addon:GetChi()
    return SafeNumber(self.state.chi)
end

function addon:GetTargets()
    return SafeNumber(self.state.targets or 1)
end

-- FIX: HasBuff hard-coded 393565 for Dance check — wrong ID.
-- Now uses C_UnitAuras directly for all IDs, with the fast-path
-- cache for the Dance aura which is the most-polled buff.
function addon:HasBuff(spellID)
    if spellID == DANCE_OF_CHIJI then
        return addon.safe.dance == true
    end
    if not C_UnitAuras then return false end
    return C_UnitAuras.GetPlayerAuraBySpellID(spellID) ~= nil
end
