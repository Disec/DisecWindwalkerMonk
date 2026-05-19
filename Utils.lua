local addonName, addon = ...

-- ============================================================
--  Utils.lua — Midnight 12.0+ safe state accessors
--
--  Fixes vs original:
--  1. SpellReady is now the single authoritative definition.
--     State.lua no longer defines it (its copy was removed there).
--
--  2. GetSpellCooldownRemainingPercent is not a real Midnight API.
--     The actual API is C_Spell.GetSpellCooldown() whose duration
--     field is a Secret Value that cannot be compared arithmetically
--     but CAN be checked for == 0 (which returns a plain bool).
--     SpellReady now uses the pcall-equality trick (same pattern
--     HekiLight uses) as the primary path, with the pct% API as
--     an optional enhancement if Blizzard adds it.
--
--  3. Added addon:SnapshotTargetHp() so Touch of Death gating in
--     Engine.lua has a plain HP percent to work with.
--
--  4. GetKeybind() (used in UI.lua) was iterating pairs() over the
--     return of FindSpellActionButtons — but that API returns an
--     array (ipairs), not a hash.  Using pairs() on an array in
--     Lua works, but the iteration order is not guaranteed; more
--     importantly the original indexed buttonID as a key and called
--     "ACTIONBUTTON" .. buttonID assuming it was 1-12, which is
--     wrong when the spell is on a multi-bar.  Kept the approach
--     simple and correct: skip RA slots, look up SLOT_BINDINGS
--     analogous to HekiLight.
-- ============================================================

-- ──────────────────────────────────────────────────────────────
--  Time
-- ──────────────────────────────────────────────────────────────
function addon:GetTime()
    return GetTime()
end

-- ──────────────────────────────────────────────────────────────
--  Combat state
-- ──────────────────────────────────────────────────────────────
function addon:IsInCombat()
    return self.state.inCombat or false
end

-- ──────────────────────────────────────────────────────────────
--  Target count
-- ──────────────────────────────────────────────────────────────
function addon:GetTargetCount()
    return self.state.targetCount or 1
end

-- ──────────────────────────────────────────────────────────────
--  Time-to-die (seconds) — target
-- ──────────────────────────────────────────────────────────────
--  Health helpers
--
--  UnitHealthPercent() is a Secret Value in Midnight combat —
--  ANY arithmetic or comparison on it taints and errors.
--
--  UnitHealth() and UnitHealthMax() return plain integers and are
--  safe to use.  We compute our own fraction: hp / hpMax.
--  Both calls are wrapped in pcall as a belt-and-suspenders guard.
-- ──────────────────────────────────────────────────────────────
local function SafeHealthPct(unit)
    local hp, hpMax
    pcall(function()
        hp    = UnitHealth(unit)
        hpMax = UnitHealthMax(unit)
    end)
    if not hp or not hpMax or hpMax == 0 then return nil end
    -- Plain integer division — no Secret Values involved.
    return (hp / hpMax) * 100
end

local TTD_HISTORY_SEC = 10
local ttdSnapshots    = {}

function addon:SnapshotTTD()
    if not UnitExists("target") or UnitIsDead("target") then
        self:ResetTTD()
        return
    end
    local now = GetTime()
    local pct = SafeHealthPct("target")
    if not pct then return end

    -- Cache for ToD gating (plain number, safe to compare)
    self.state.targetHpPct = pct

    table.insert(ttdSnapshots, { time = now, pct = pct })
    while ttdSnapshots[1] and (now - ttdSnapshots[1].time) > TTD_HISTORY_SEC do
        table.remove(ttdSnapshots, 1)
    end
    if #ttdSnapshots < 2 then
        self.state.timeToDie = 999
        return
    end
    local oldest = ttdSnapshots[1]
    local newest = ttdSnapshots[#ttdSnapshots]
    local dt   = newest.time - oldest.time
    local dpct = oldest.pct - newest.pct
    if dt <= 0 or dpct <= 0 then
        self.state.timeToDie = 999
        return
    end
    local ttd = newest.pct / (dpct / dt)
    self.state.timeToDie = (ttd > 0) and ttd or 999
end

-- ── Per-unit TTD (nameplate AoE gating) ─────────────────────
local unitTTDSnapshots = {}

function addon:SnapshotTTDUnit(unit)
    if not UnitExists(unit) or UnitIsDead(unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local now = GetTime()
    local pct = SafeHealthPct(unit)
    if not pct then return end
    if not unitTTDSnapshots[guid] then unitTTDSnapshots[guid] = {} end
    local snaps = unitTTDSnapshots[guid]
    table.insert(snaps, { time = now, pct = pct })
    while snaps[1] and (now - snaps[1].time) > TTD_HISTORY_SEC do
        table.remove(snaps, 1)
    end
end

function addon:GetTTDForUnit(unit)
    if unit == "target" then return self:GetTimeToDie() end
    if not UnitExists(unit) or UnitIsDead(unit) then return 0 end
    local guid = UnitGUID(unit)
    if not guid then return 999 end
    local snaps = unitTTDSnapshots[guid]
    if not snaps or #snaps < 2 then return 999 end
    local oldest = snaps[1]
    local newest = snaps[#snaps]
    local dt   = newest.time - oldest.time
    local dpct = oldest.pct - newest.pct
    if dt <= 0 or dpct <= 0 then return 999 end
    local ttd = newest.pct / (dpct / dt)
    return (ttd > 0) and ttd or 999
end

function addon:PurgeTTDUnit(unit)
    local guid = unit and UnitGUID(unit)
    if guid then unitTTDSnapshots[guid] = nil end
end

function addon:GetTimeToDie()
    return self.state.timeToDie or 999
end

function addon:ResetTTD()
    ttdSnapshots = {}
    self.state.timeToDie   = 999
    self.state.targetHpPct = 100
end

-- ──────────────────────────────────────────────────────────────
--  Player HP — uses UnitHealth/UnitHealthMax, not UnitHealthPercent
-- ──────────────────────────────────────────────────────────────
function addon:SnapshotPlayerHp()
    local pct = SafeHealthPct("player")
    if pct then self.state.playerHpPct = pct end
end

function addon:GetPlayerHpPct()
    return self.state.playerHpPct or 100
end

-- ──────────────────────────────────────────────────────────────
--  Chi
-- ──────────────────────────────────────────────────────────────
function addon:UpdateChi()
    self.state.chi = UnitPower("player", Enum.PowerType.Chi) or 0
end

function addon:GetChi()
    return self.state.chi or 0
end

-- NOTE: UpdateEnergy / GetEnergyPct removed.
-- UnitPowerPercent() returns a Secret Value in Midnight combat.
-- Storing or comparing it causes taint errors. Do not re-add.

-- ──────────────────────────────────────────────────────────────
--  Cooldown APIs
--
--  FIX: C_Spell.GetSpellCooldownRemainingPercent is not a real
--  Midnight API.  The reliable Midnight-safe pattern (from HekiLight)
--  is the pcall-equality trick: comparing cd.duration == 0 either
--  succeeds (plain 0 → spell is ready) or throws (Secret Value → on CD).
-- ──────────────────────────────────────────────────────────────
function addon:SpellCooldownPct(spellID)
    -- Optional enhanced API (may exist in future patches)
    if C_Spell and C_Spell.GetSpellCooldownRemainingPercent then
        local ok, pct = pcall(C_Spell.GetSpellCooldownRemainingPercent, spellID)
        if ok and type(pct) == "number" then return pct end
    end
    -- pcall-equality trick (HekiLight pattern)
    local ready = false
    pcall(function()
        local cd = C_Spell.GetSpellCooldown(spellID)
        if cd and cd.duration == 0 then ready = true end
    end)
    return ready and 0 or 1
end

function addon:SpellCooldownInfo(spellID)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil end
    return C_Spell.GetSpellCooldown(spellID)
end

-- ── Canonical SpellReady ─────────────────────────────────────
-- Single definition; State.lua no longer duplicates this.
function addon:SpellReady(spellID)
    if not spellID then return false end
    -- Honour per-spell disable list
    if addon.db and addon.db.disabledSpells and addon.db.disabledSpells[spellID] then
        return false
    end
    return self:SpellCooldownPct(spellID) == 0
end

-- ──────────────────────────────────────────────────────────────
--  Buff checks (C_UnitAuras replaces UnitBuff in Midnight)
-- ──────────────────────────────────────────────────────────────
function addon:GetPlayerBuff(spellID)
    if not C_UnitAuras then return nil end
    return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

function addon:HasBuff(spellID)
    return self:GetPlayerBuff(spellID) ~= nil
end

-- ──────────────────────────────────────────────────────────────
--  Target casting (interrupt surface)
-- ──────────────────────────────────────────────────────────────
function addon:TargetIsCasting()
    local name, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("target")
    if name and not notInterruptible then return true end
    local cname, _, _, _, _, _, _, notInterruptibleCh = UnitChannelInfo("target")
    if cname and not notInterruptibleCh then return true end
    return false
end

-- ──────────────────────────────────────────────────────────────
--  Keybind lookup (safe, mirrors HekiLight's approach)
--  Filters out Rotation-Assistant slots so only real bar bindings
--  are returned, and falls back gracefully when no bind is found.
-- ──────────────────────────────────────────────────────────────
function addon:GetSpellKeybind(spellID)
    if not spellID then return "" end
    local slots = C_ActionBar.FindSpellActionButtons(spellID)
    if slots then
        for _, slot in ipairs(slots) do
            -- Skip Rotation Assistant virtual slots
            if not (C_ActionBar.IsAssistedCombatAction and
                    C_ActionBar.IsAssistedCombatAction(slot)) then
                local bind = GetBindingKey("ACTIONBUTTON" .. slot)
                if bind and bind ~= "" then
                    -- Abbreviate modifiers for compact display
                    bind = bind:gsub("ALT%-",   "A-")
                               :gsub("CTRL%-",  "C-")
                               :gsub("SHIFT%-", "S-")
                    return bind
                end
            end
        end
    end
    return ""
end
