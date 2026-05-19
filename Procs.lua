local addonName, addon = ...

-- ============================================================
--  Procs.lua — active proc / buff tracking + visual panel
--
--  Tracks key Windwalker buffs and surfaces them in a small
--  secondary panel alongside the main HUD.
--
--  Midnight note: CLEU is gone. We poll C_UnitAuras on a
--  UNIT_AURA event instead — this is the correct pattern.
-- ============================================================

addon.procs = {}

-- ── Tracked procs ─────────────────────────────────────────────
-- Each entry: spellID, short label, colour (r,g,b)
-- FIX: 196742 was listed as "BoK" proc, but that's a talent node ID.
--      The Blackout Kick! proc aura is 116768 (Combo Breaker).
--      196742 has been removed; 116768 already appears as "CB" above it.
local TRACKED = {
    { id = 116768,  label = "CB",     r=1,    g=0.8,  b=0,    desc="Combo Breaker (free BOK)" },
    { id = 116645,  label = "ToM",    r=0,    g=0.9,  b=1,    desc="Teachings of the Monastery" },
    { id = 325201,  label = "DoChiJ", r=0.6,  g=0.2,  b=1,    desc="Dance of Chi-Ji (free SCK)" },
    { id = 1249625, label = "Zenith", r=0.2,  g=0.8,  b=0.2,  desc="Zenith (replaces SEF)" },
    { id = 152173,  label = "Ser",    r=0.4,  g=0.8,  b=1,    desc="Serenity" },
    { id = 1261703, label = "TEB",    r=1,    g=0.75, b=0,    desc="Tigereye Brew stacks" },
    { id = 388682,  label = "TigerP", r=1,    g=0.3,  b=0.1,  desc="Tiger Power" },
    { id = 392979,  label = "JadeI",  r=0.4,  g=1,    b=0.5,  desc="Jade Ignition" },
}

-- Runtime state: spellID → { active, stacks, expiry, duration }
local procState = {}
for _, p in ipairs(TRACKED) do
    procState[p.id] = { active = false, stacks = 0, expiry = 0, duration = 0 }
end

-- ──────────────────────────────────────────────────────────────
--  Poll auras — called on UNIT_AURA for "player"
-- ──────────────────────────────────────────────────────────────
function addon:RefreshProcs()
    for _, p in ipairs(TRACKED) do
        local aura = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID(p.id)
        if aura then
            procState[p.id].active   = true
            procState[p.id].stacks   = aura.applications or 1
            procState[p.id].expiry   = aura.expirationTime or 0
            -- Record the full duration when the buff is first seen so
            -- the bar can scale correctly from 100% → 0% as it drains.
            -- aura.duration is provided by C_UnitAuras in Midnight.
            local dur = aura.duration or 0
            if dur > 0 then
                procState[p.id].duration = dur
            elseif procState[p.id].duration == 0 then
                procState[p.id].duration = 0  -- will use expiry-based heuristic
            end
        else
            procState[p.id].active   = false
            procState[p.id].stacks   = 0
            procState[p.id].expiry   = 0
            procState[p.id].duration = 0
        end
    end

    -- Push to visual panel if it exists
    if addon.ProcPanel and addon.ProcPanel.Refresh then
        addon.ProcPanel:Refresh(procState, TRACKED)
    end
end

-- Public getter for APL use
function addon:ProcActive(spellID)
    return procState[spellID] and procState[spellID].active
end

function addon:ProcStacks(spellID)
    return (procState[spellID] and procState[spellID].stacks) or 0
end

-- ──────────────────────────────────────────────────────────────
--  Event frame
-- ──────────────────────────────────────────────────────────────
local procFrame = CreateFrame("Frame")
procFrame:RegisterEvent("UNIT_AURA")
procFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

procFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_AURA" and unit ~= "player" then return end
    addon:RefreshProcs()
end)

-- ──────────────────────────────────────────────────────────────
--  Proc panel — small secondary frame showing active buffs
--  Built here; anchored relative to HUD in UI.lua
-- ──────────────────────────────────────────────────────────────
local PANEL_W   = 120
local PANEL_ROW = 14
local PANEL_PAD = 3
local FONT_PATH = "Fonts\\FRIZQT__.TTF"

local ProcPanel = CreateFrame("Frame", "WWEliteProcPanel", UIParent)
ProcPanel:SetFrameStrata("MEDIUM")
ProcPanel:SetSize(PANEL_W, PANEL_ROW * #TRACKED + PANEL_PAD * 2)
ProcPanel:SetClampedToScreen(true)
ProcPanel:Hide()

addon.ProcPanel = ProcPanel

-- Background
local pbg = ProcPanel:CreateTexture(nil, "BACKGROUND")
pbg:SetAllPoints()
pbg:SetColorTexture(0, 0, 0, 0.65)

-- One row per tracked proc
ProcPanel._rows = {}

for i, p in ipairs(TRACKED) do
    local row = CreateFrame("Frame", nil, ProcPanel)
    row:SetSize(PANEL_W - PANEL_PAD * 2, PANEL_ROW)
    row:SetPoint("TOPLEFT", ProcPanel, "TOPLEFT",
                 PANEL_PAD, -(PANEL_PAD + (i-1) * PANEL_ROW))

    -- Dim overlay when inactive
    local dimTex = row:CreateTexture(nil, "BACKGROUND")
    dimTex:SetAllPoints()
    dimTex:SetColorTexture(0, 0, 0, 0.45)
    row.dimTex = dimTex

    -- Label
    local label = row:CreateFontString(nil, "OVERLAY")
    label:SetFont(FONT_PATH, 9, "OUTLINE")
    label:SetPoint("LEFT", row, "LEFT", 2, 0)
    label:SetTextColor(p.r, p.g, p.b, 1)
    label:SetText(p.label)
    row.label = label

    -- Stack count (right side)
    local stacks = row:CreateFontString(nil, "OVERLAY")
    stacks:SetFont(FONT_PATH, 9, "OUTLINE")
    stacks:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    stacks:SetTextColor(1, 1, 1, 0.9)
    stacks:SetText("")
    row.stacks = stacks

    -- Duration bar (thin strip along the bottom)
    local bar = row:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("BOTTOMLEFT",  row, "BOTTOMLEFT",  0, 0)
    bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    bar:SetHeight(2)
    bar:SetColorTexture(p.r, p.g, p.b, 0.8)
    bar:SetWidth(0)
    row.bar    = bar
    row.barMax = PANEL_W - PANEL_PAD * 2

    row.spellID = p.id

    ProcPanel._rows[i] = row
end

-- ──────────────────────────────────────────────────────────────
--  Refresh — called by addon:RefreshProcs()
--
--  FIX: The panel previously hid itself when no procs were active
--       but never reshowed mid-combat when a new proc fired.
--       The visibility logic now handles all four cases:
--         • in combat + any active  → show
--         • in combat + none active → hide (keep panel out of the way
--           when everything is on cooldown)
--         • out of combat           → always hide
--       The key fix is that Show() is called here on every Refresh
--       when the conditions are met, so a proc that fires after a
--       quiet period correctly resurfaces the panel.
-- ──────────────────────────────────────────────────────────────
function ProcPanel:Refresh(state, tracked)
    local now = GetTime()
    local anyActive = false

    for i, row in ipairs(self._rows) do
        local p  = tracked[i]
        local ps = state[p.id]

        if ps and ps.active then
            anyActive = true
            row.dimTex:SetAlpha(0)
            row.label:SetTextColor(p.r, p.g, p.b, 1)

            -- Stack count
            if ps.stacks > 1 then
                row.stacks:SetText(tostring(ps.stacks))
            else
                row.stacks:SetText("")
            end

            -- Duration bar — scale against the aura's actual duration
            if ps.expiry > 0 then
                local remaining = ps.expiry - now
                local maxDur = ps.duration
                if maxDur <= 0 then
                    if not row._observedMax or remaining > row._observedMax then
                        row._observedMax = remaining
                    end
                    maxDur = row._observedMax or 30
                end
                local frac = math.max(0, math.min(1, remaining / maxDur))
                row.bar:SetWidth(frac * row.barMax)
            else
                -- Permanent / no-expiry buff — full bar
                row._observedMax = nil
                row.bar:SetWidth(row.barMax)
            end
        else
            row.dimTex:SetAlpha(0.7)
            row.label:SetTextColor(p.r * 0.4, p.g * 0.4, p.b * 0.4, 0.7)
            row.stacks:SetText("")
            row.bar:SetWidth(0)
            row._observedMax = nil  -- reset so next application starts fresh
        end
    end

    -- FIX: Always drive Show/Hide from here on every Refresh so the panel
    --      correctly reappears when a proc fires after all were inactive.
    if addon.state.inCombat then
        if anyActive then
            self:Show()
        else
            self:Hide()
        end
    else
        self:Hide()
    end
end

-- Anchor is set by UI.lua after the main HUD is positioned
function ProcPanel:AnchorTo(hudFrame)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", hudFrame, "TOPRIGHT", 6, 0)
end
