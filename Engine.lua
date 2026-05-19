local addonName, addon = ...

-- ============================================================
--  Engine.lua — Windwalker priority engine  (v2.3)
--
--  Changes vs previous version:
--
--  [BUG] ToD HP gate used addon:GetPlayerHpPct() (player HP) instead
--        of addon.state.targetHpPct (target HP). Now uses target HP
--        directly — the variable SnapshotTTD() keeps up to date.
--
--  [BUG] CopyState() captured state.dance via HasBuff() but never
--        captured Serenity or ToM stacks, so the Serenity sub-priority
--        and ToM chi delta were never reachable mid-simulation.
--        Both are now snapshotted into sim state at copy time.
--
--  [FEATURE] Serenity sub-priority: when Serenity is active chi costs
--        are effectively zero (Blizzard refunds them). The rotation
--        priority during Serenity is RSK > FoF > BOK spam, ignoring
--        chi cost entirely. Added a dedicated Serenity branch that
--        fires before the normal priority list when the buff is up.
--
--  [FEATURE] Teachings of the Monastery (ToM) stack awareness:
--        ToM (116645) each stack makes the next Tiger Palm free AND
--        reduces RSK cooldown by 1 s. When stacks are present, Tiger
--        Palm moves up the priority so stacks don't cap and waste.
--        Chi delta for TP is adjusted: still +2, free on consume.
--        Simulation marks stacks consumed on TP casts.
--
--  [FEATURE] Combo Breaker (CB, 116768) proc awareness: CB gives a
--        free Blackout Kick. When the proc is active BOK leapfrogs
--        ahead of the normal filler position (free = always cast it).
--
--  [FEATURE] Two-phase cooldown tracking for long CDs (FoF, SOTWL,
--        WDP): GetSpellBaseCooldown() seeds a plain-Lua end-time on
--        UNIT_SPELLCAST_SUCCEEDED for the player, so the queue
--        simulation can reason about cooldown windows without
--        touching Secret Values. Out-of-combat, the table is
--        re-seeded from the live API for accuracy.
--
--  [REMOVED] Energy pooling gate: UnitPowerPercent() is a Secret Value
--        in Midnight combat. Comparing it causes taint (441x errors).
--        Removed entirely — chi management via priority list is sufficient.
--
--  [FEATURE] Interrupt surface: when the encounter profile says
--        interruptPriority = true and the target is casting an
--        interruptible spell, Paralysis (115078) is inserted at the
--        front of the queue as a reminder. We do NOT auto-kick — just
--        surface the interrupt as the first suggestion.
--
--  [FIX] SCK AoE threshold respects the mode's aoeThreshold rather
--        than the hardcoded ">=3". EffectiveTargetCount() already
--        bakes mode into the count, so the comparison is kept at >=3
--        which is correct for auto/mythic mode; single-target mode
--        sets effective count to 1 which naturally disables SCK.
-- ============================================================

local spells = addon.spells

-- Additional spell IDs used only in Engine (not in Core.lua registry)
local PARALYSIS       = 115078   -- interrupt / CC
local SERENITY_BUFF   = 152173   -- Serenity active buff
local TOM_BUFF        = 116645   -- Teachings of the Monastery stacks
local CB_BUFF         = 116768   -- Combo Breaker (free BOK proc)

-- Midnight 12.0.5 new spells / cooldowns
local ZENITH          = 1249625  -- replaces SEF; major cooldown
local ZENITH_STOMP    = 1272696  -- activated during Zenith (generates 2 Chi each)
local TIGEREYE_BREW   = 1261703  -- Apex talent: stacks crit%, consumed by Zenith
local SLICING_WINDS   = 404519   -- strong AoE filler when talented (Shado-Pan path)
local REVOLVING_WHIRL = 451524   -- talent: SCK also triggers Xuen's Battlegear in AoE

local engine = {}

-- ──────────────────────────────────────────────────────────────
--  Two-phase cooldown end-time table
--  Populated from GetSpellBaseCooldown() on cast (taint-free),
--  corrected from live API out-of-combat.
-- ──────────────────────────────────────────────────────────────
local cdEndTime = {}   -- [spellID] = GetTime() timestamp when CD ends

-- Seed a cooldown end time from the base (static) cooldown.
-- Called on UNIT_SPELLCAST_SUCCEEDED for the player.
local function SeedCooldownFromBase(spellID)
    local base = GetSpellBaseCooldown and GetSpellBaseCooldown(spellID)
    if base and base > 0 then
        cdEndTime[spellID] = GetTime() + (base / 1000)
    end
end

-- Re-seed all tracked CDs from the live API (out of combat only,
-- where Secret Value comparisons are safe because combat taint
-- has cleared).
local function ReseedCooldownsOutOfCombat()
    for _, spellID in pairs(addon.spells) do
        pcall(function()
            local cd = C_Spell.GetSpellCooldown(spellID)
            if cd and cd.startTime and cd.duration then
                -- duration == 0 means ready; anything else is on CD.
                -- We can compare startTime + duration as plain math
                -- outside combat without taint.
                if cd.duration ~= 0 then
                    cdEndTime[spellID] = cd.startTime + cd.duration
                else
                    cdEndTime[spellID] = 0
                end
            end
        end)
    end
end

-- Plain-Lua cooldown check: is this spell off CD per our cached timestamps?
-- Falls back to SpellCooldownPct if no timestamp is present.
local function CdReady(spellID)
    local t = cdEndTime[spellID]
    if t then
        return GetTime() >= t
    end
    -- Fallback: pcall-equality trick
    return addon:SpellCooldownPct(spellID) == 0
end

-- ── Spell-cast listener for seeding ──────────────────────────
local castFrame = CreateFrame("Frame")
castFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
castFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
castFrame:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "PLAYER_REGEN_ENABLED" then
        ReseedCooldownsOutOfCombat()
        return
    end
    if unit ~= "player" then return end
    -- Seed base CD for any known spell
    if spellID then
        SeedCooldownFromBase(spellID)
    end
end)

-- ──────────────────────────────────────────────────────────────
--  Simulation state snapshot
-- ──────────────────────────────────────────────────────────────
local function CopyState()
    local tomAura   = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(TOM_BUFF)
    local serAura   = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(SERENITY_BUFF)
    local cbAura    = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(CB_BUFF)
    local zenAura   = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(ZENITH)
    local tebAura   = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(TIGEREYE_BREW)

    return {
        chi        = addon:GetChi(),
        targets    = addon:EffectiveTargetCount(),
        lastSpell  = addon.state.lastSpell or 0,
        dance      = addon:HasBuff(325201),
        serenity   = serAura ~= nil,
        zenith     = zenAura ~= nil,                  -- Zenith active window
        -- ZenithStomp charges remaining (2 per Zenith cast)
        zenithStompCharges = zenAura and 2 or 0,
        -- Tigereye Brew stacks (influences Zenith value; tracked for gating)
        tebStacks  = tebAura and (tebAura.applications or 0) or 0,
        tomStacks  = tomAura and (tomAura.applications or 1) or 0,
        cbProc     = cbAura ~= nil,
    }
end

local function SpendChi(state, amount)
    state.chi = math.max(0, state.chi - amount)
end

local function GainChi(state, amount)
    state.chi = math.min(6, state.chi + amount)
end

local function ComboStrike(state, spellID)
    return state.lastSpell ~= spellID
end

-- Chi delta table.  Serenity refunds costs at the C level; we
-- approximate by setting all costs to 0 when serenity = true inside
-- ApplyChiDelta.  TP still generates.
local CHI_DELTA = {
    [spells.TIGER_PALM]             =  2,   -- generates chi
    [spells.BLACKOUT_KICK]          = -1,
    [spells.RISING_SUN_KICK]        = -2,
    [spells.FISTS_OF_FURY]          = -3,
    [spells.SPINNING_CRANE_KICK]    = -2,
    [spells.STRIKE_OF_THE_WINDLORD] = -2,   -- costs 2 Chi
    [spells.WHIRLING_DRAGON_PUNCH]  =  0,
    [spells.TOUCH_OF_DEATH]         =  0,
    [ZENITH_STOMP]                  =  2,   -- generates 2 Chi per press (up to 3×/Zenith)
    [SLICING_WINDS]                 =  0,   -- strong AoE filler; no chi cost
}

local function ApplyChiDelta(state, spellID)
    local delta = CHI_DELTA[spellID]
    if not delta then return end

    -- Serenity: all chi spenders are refunded (net 0 cost).
    -- TP still generates normally.
    if state.serenity and delta < 0 then
        delta = 0
    end

    -- Teachings of the Monastery: if stacks present and casting TP,
    -- consume a stack (the free proc). Chi generation is unchanged.
    if spellID == spells.TIGER_PALM and state.tomStacks > 0 then
        state.tomStacks = state.tomStacks - 1
        -- TP is free with ToM; chi generated is still +2.
    end

    -- Combo Breaker proc consumed on BOK cast
    if spellID == spells.BLACKOUT_KICK and state.cbProc then
        state.cbProc = false  -- consumed
        delta = 0             -- free cast
    end

    if delta > 0 then
        GainChi(state, delta)
    elseif delta < 0 then
        SpendChi(state, -delta)
    end
end

-- ──────────────────────────────────────────────────────────────
--  Serenity sub-priority
--  During Serenity chi costs are refunded; the rotation becomes
--  RSK > FoF > BOK spam on Combo Strike.  SCK replaces BOK on AoE.
--  Touch of Death and interrupt remain above this block.
-- ──────────────────────────────────────────────────────────────
local function GetSerenitySpell(state)
    -- Rising Sun Kick — highest priority in Serenity
    if addon:SpellReady(spells.RISING_SUN_KICK)
    and ComboStrike(state, spells.RISING_SUN_KICK) then
        return spells.RISING_SUN_KICK
    end

    -- Fists of Fury
    if addon:SpellReady(spells.FISTS_OF_FURY)
    and ComboStrike(state, spells.FISTS_OF_FURY) then
        return spells.FISTS_OF_FURY
    end

    -- AoE: SCK on 3+ targets
    if state.targets >= 3 and state.dance then
        return spells.SPINNING_CRANE_KICK
    end
    if state.targets >= 3 then
        return spells.SPINNING_CRANE_KICK
    end

    -- Dance of Chi-Ji proc
    if state.dance then
        return spells.SPINNING_CRANE_KICK
    end

    -- Filler: Blackout Kick (Combo Strike)
    if ComboStrike(state, spells.BLACKOUT_KICK) then
        return spells.BLACKOUT_KICK
    end

    -- Absolute filler (Combo Strike violation fallback)
    return spells.RISING_SUN_KICK
end

-- ──────────────────────────────────────────────────────────────
--  Main priority logic (one step of the APL)
-- ──────────────────────────────────────────────────────────────
function engine:GetNextSpell(state)
    local t = addon.talents or {}

    -- ── Touch of Death ───────────────────────────────────────
    -- Gate: target HP < player max HP (approximated as <20%) OR TTD < 10s.
    -- ComboStrike not required — ToD doesn't break Hit Combo in Midnight.
    if addon:SpellReady(spells.TOUCH_OF_DEATH) then
        local ttd      = addon:GetTimeToDie()
        local targetHp = addon.state.targetHpPct or 100
        if ttd < 10 or targetHp < 20 then
            return spells.TOUCH_OF_DEATH
        end
    end

    -- ── Zenith window — dedicated sub-priority ───────────────
    -- Zenith replaces SEF in Midnight.  During the Zenith window:
    --   Priority: SOTWL > WDP > RSK > FoF > ZenithStomp > BOK/SCK
    --   ZenithStomp occupies the BOK/SCK filler slot and generates
    --   2 Chi per press.  Prioritise it over naked BOK/SCK fillers.
    if state.zenith then
        if t.hasStrikeOfWindlord and addon:SpellReady(spells.STRIKE_OF_THE_WINDLORD)
        and state.chi >= 2
        and ComboStrike(state, spells.STRIKE_OF_THE_WINDLORD) then
            return spells.STRIKE_OF_THE_WINDLORD
        end
        if t.hasWhirlingDragonPunch and CdReady(spells.WHIRLING_DRAGON_PUNCH)
        and ComboStrike(state, spells.WHIRLING_DRAGON_PUNCH) then
            return spells.WHIRLING_DRAGON_PUNCH
        end
        if addon:SpellReady(spells.RISING_SUN_KICK) and state.chi >= 2
        and ComboStrike(state, spells.RISING_SUN_KICK) then
            return spells.RISING_SUN_KICK
        end
        if addon:SpellReady(spells.FISTS_OF_FURY) and state.chi >= 3
        and ComboStrike(state, spells.FISTS_OF_FURY) then
            return spells.FISTS_OF_FURY
        end
        -- Dance of Chi-Ji proc — always consume even in Zenith
        if state.dance and ComboStrike(state, spells.SPINNING_CRANE_KICK) then
            return spells.SPINNING_CRANE_KICK
        end
        -- ZenithStomp: filler that generates Chi; use over naked BOK/TP
        -- It does NOT count for Mastery/Hit Combo, so it's safe between
        -- any two spells and fills gaps without breaking Combo Strike.
        if state.zenithStompCharges and state.zenithStompCharges > 0
        and addon:SpellReady(ZENITH_STOMP) then
            return ZENITH_STOMP
        end
        -- Combo Breaker free BOK during Zenith
        if state.cbProc then
            return spells.BLACKOUT_KICK
        end
        if ComboStrike(state, spells.BLACKOUT_KICK) and state.chi >= 1 then
            return spells.BLACKOUT_KICK
        end
        return spells.TIGER_PALM
    end

    -- ── Serenity branch (if talented) ────────────────────────
    if state.serenity then
        return GetSerenitySpell(state)
    end

    -- ── Interrupt surface ────────────────────────────────────
    -- Flagged by BuildQueue(); handled in Recommendations.lua.

    -- ── Strike of the Windlord ───────────────────────────────
    -- Highest priority damaging GCD outside of cooldown windows
    -- (per Method 12.0.5 guide — SOTWL #1 in normal priority).
    -- Requires 2 Chi and Combo Strike.
    if t.hasStrikeOfWindlord and addon:SpellReady(spells.STRIKE_OF_THE_WINDLORD)
    and state.chi >= 2
    and ComboStrike(state, spells.STRIKE_OF_THE_WINDLORD) then
        return spells.STRIKE_OF_THE_WINDLORD
    end

    -- ── WDP — requires BOTH RSK and FoF on CD ────────────────
    -- Also fires when Dance of Chi-Ji stacks < 2 (avoids wasting the proc window).
    if t.hasWhirlingDragonPunch and CdReady(spells.WHIRLING_DRAGON_PUNCH)
    and ComboStrike(state, spells.WHIRLING_DRAGON_PUNCH) then
        local rskOnCd = not CdReady(spells.RISING_SUN_KICK)
        local fofOnCd = not CdReady(spells.FISTS_OF_FURY)
        -- Fire when both are on CD, OR when DoChiJi stacks are < 2
        -- (holding WDP for the proc wastes the cd window)
        if (rskOnCd and fofOnCd) or (state.dance == false) then
            return spells.WHIRLING_DRAGON_PUNCH
        end
    end

    -- ── Dance of Chi-Ji proc — free SCK ──────────────────────
    -- Free + empowered; consume ahead of FoF/RSK on ST and AoE.
    -- Per 12.0.5: SCK also now triggers Xuen's Battlegear, making
    -- the proc even more valuable.
    if state.dance and ComboStrike(state, spells.SPINNING_CRANE_KICK) then
        return spells.SPINNING_CRANE_KICK
    end

    -- ── Combo Breaker proc — free BOK ────────────────────────
    if state.cbProc then
        return spells.BLACKOUT_KICK
    end

    -- ── Teachings of the Monastery — TP to avoid chi overcap ─
    if state.tomStacks > 0 and state.chi >= 5 then
        return spells.TIGER_PALM
    end

    -- ── Fists of Fury ────────────────────────────────────────
    -- Priority: FoF > RSK in normal rotation (Method 12.0.5).
    -- Requires >=3 Chi and Combo Strike.
    if addon:SpellReady(spells.FISTS_OF_FURY)
    and state.chi >= 3
    and ComboStrike(state, spells.FISTS_OF_FURY) then
        return spells.FISTS_OF_FURY
    end

    -- ── Rising Sun Kick ──────────────────────────────────────
    if addon:SpellReady(spells.RISING_SUN_KICK)
    and state.chi >= 2
    and ComboStrike(state, spells.RISING_SUN_KICK) then
        return spells.RISING_SUN_KICK
    end

    -- ── Slicing Winds — AoE filler (Shado-Pan / talented) ───
    -- Per Icy Veins 12.0.5: most AoE damage is in FoF + Slicing Winds.
    -- SCK is weak in AoE and should NOT be used freely outside DoChiJi proc.
    if t.hasSlicingWinds and addon:SpellReady(SLICING_WINDS)
    and state.targets >= 2
    and ComboStrike(state, SLICING_WINDS) then
        return SLICING_WINDS
    end

    -- ── AoE: SCK without proc — demoted per 12.0.5 ──────────
    -- SCK without the DoChiJi proc is very weak in Midnight 12.0.5
    -- and should only be used as a last resort in AoE to avoid
    -- breaking Combo Strike.  It sits below BOK now.
    -- (Do NOT use this path in single-target — it burns chi for little gain.)
    if state.targets >= 4 and state.chi >= 2
    and ComboStrike(state, spells.SPINNING_CRANE_KICK) then
        return spells.SPINNING_CRANE_KICK
    end

    -- ── Filler: Blackout Kick ────────────────────────────────
    if state.chi >= 1 and ComboStrike(state, spells.BLACKOUT_KICK) then
        return spells.BLACKOUT_KICK
    end

    -- ── Generator: Tiger Palm ────────────────────────────────
    return spells.TIGER_PALM
end

-- ──────────────────────────────────────────────────────────────
--  Interrupt readiness flag
--  Set by BuildQueue() before building the queue.  Checked by
--  Recommendations.lua to insert Paralysis at slot 1 when true.
-- ──────────────────────────────────────────────────────────────
engine.interruptReady = false
engine.PARALYSIS      = PARALYSIS

-- ──────────────────────────────────────────────────────────────
--  Queue builder — simulate 4 steps ahead
-- ──────────────────────────────────────────────────────────────
function engine:BuildQueue()
    -- Refresh chi from live API before simulating
    addon:UpdateChi()

    -- Check interrupt surface before queue (doesn't consume chi)
    local profile = addon:GetEncounterProfile()
    self.interruptReady = profile.interruptPriority
                       and addon:TargetIsCasting()
                       and addon:SpellReady(PARALYSIS)

    local sim   = CopyState()
    local queue = {}

    for i = 1, 4 do
        local spellID = self:GetNextSpell(sim)
        queue[i]      = spellID
        sim.lastSpell = spellID
        ApplyChiDelta(sim, spellID)
        -- Consume dance proc after SCK
        if spellID == spells.SPINNING_CRANE_KICK then
            sim.dance = false
        end
        -- Consume a ZenithStomp charge
        if spellID == ZENITH_STOMP and sim.zenithStompCharges then
            sim.zenithStompCharges = math.max(0, sim.zenithStompCharges - 1)
        end
    end

    return queue
end

addon.Engine = engine
