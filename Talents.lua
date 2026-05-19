local addonName, addon = ...

-- ============================================================
--  Talents.lua  (v2.3)
--
--  Changes vs previous:
--  • Debug print() replaced with addon:Print() gated behind
--    addon.db.debug — no more chat spam on every login/respec.
--  • Added hasCelestialConduit talent flag (443056) — the
--    Conduit of the Celestials hero talent changes FoF priority
--    significantly and is the current meta opener.
--  • Added hasParalysis flag (115078) — used by Engine.lua to
--    gate interrupt surfacing on whether player actually has
--    Paralysis available as an interrupt tool.
--  • CheckSpec: replaced bare print() with addon:Print() so
--    non-WW spec warning is formatted consistently.
-- ============================================================

local WW_SPEC_ID = 269

addon.talents = {
    isWindwalker           = false,

    hasWhirlingDragonPunch = false,
    hasStrikeOfWindlord    = false,
    hasSerenity            = false,
    hasDanceOfChiJi        = false,
    hasJadeIgnition        = false,
    hasLegSweep            = false,
    hasRushingJadeWind     = false,
    hasCelestialConduit    = false,   -- Conduit of the Celestials hero talent
    hasParalysis           = false,
    -- Midnight 12.0.5 specific
    hasZenith              = false,   -- replaces Storm, Earth & Fire
    hasSlicingWinds        = false,   -- strong AoE (Shado-Pan path)
    hasRevolvingWhirl      = false,   -- SCK also triggers Xuen's Battlegear in AoE
    hasEchoTechnique       = false,   -- ST alternative to Revolving Whirl
    hasCrashingFists       = false,   -- FoF damage +20% (redesigned 12.0.5)
    hasTigereeyeBrew       = false,   -- Apex: Zenith consumes stacks for Crit%
    -- InvokeXuen: Conduit-only spell in Midnight (not a standalone talent node).
    -- Kept as a flag so Procs.lua can track the active buff.
    hasInvokeXuenBuff      = false,
}

local TALENT_SPELLS = {
    WhirlingDragonPunch = 152175,
    StrikeOfWindlord    = 392983,
    Serenity            = 152173,
    DanceOfChiJi        = 325201,
    JadeIgnition        = 392979,
    LegSweep            = 119381,
    RushingJadeWind     = 116847,
    CelestialConduit    = 443056,
    Paralysis           = 115078,
    Zenith              = 1249625,
    SlicingWinds        = 404519,
    RevolvingWhirl      = 451524,
    EchoTechnique       = 1250042,
    CrashingFists       = 1248747,
    TigereeyeBrew       = 1261703,
}

-- ──────────────────────────────────────────────────────────────
--  Spec check
-- ──────────────────────────────────────────────────────────────
local function CheckSpec()
    local idx    = GetSpecialization()
    local specID = idx and select(1, GetSpecializationInfo(idx)) or nil
    addon.talents.isWindwalker = (specID == WW_SPEC_ID)

    if addon.HUD then
        if not addon.talents.isWindwalker then
            addon.HUD:Hide()
            if specID and addon.Print then
                addon:Print("Not Windwalker spec — HUD hidden.")
            end
        end
    end
end

-- ──────────────────────────────────────────────────────────────
--  Talent snapshot
-- ──────────────────────────────────────────────────────────────
function addon:SnapshotTalents()
    local t = addon.talents
    for flag, spellID in pairs(TALENT_SPELLS) do
        local key = "has" .. flag
        if t[key] ~= nil then
            t[key] = IsPlayerSpell(spellID) or false
        end
    end

    -- Debug output: only when db.debug is explicitly true
    if addon.db and addon.db.debug then
        addon:Print(string.format(
            "Talents: WDP=%s SOTWL=%s SEF=%s Xuen=%s Ser=%s DoChiJi=%s RJW=%s CC=%s",
            tostring(t.hasWhirlingDragonPunch),
            tostring(t.hasStrikeOfWindlord),
            tostring(t.hasSEF),
            tostring(t.hasInvokeXuen),
            tostring(t.hasSerenity),
            tostring(t.hasDanceOfChiJi),
            tostring(t.hasRushingJadeWind),
            tostring(t.hasCelestialConduit)
        ))
    end
end

-- ──────────────────────────────────────────────────────────────
--  Event frame
-- ──────────────────────────────────────────────────────────────
local talentFrame = CreateFrame("Frame")
talentFrame:RegisterEvent("PLAYER_LOGIN")
talentFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
talentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")

talentFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        if unit ~= "player" then return end
        CheckSpec()
        addon:SnapshotTalents()
    elseif event == "PLAYER_LOGIN" then
        CheckSpec()
        addon:SnapshotTalents()
    elseif event == "PLAYER_TALENT_UPDATE" then
        addon:SnapshotTalents()
    end
end)
