local addonName, addon = ...

-- ============================================================
--  GlowManager.lua — action-bar glow system
--
--  Ported from MaxDps/Buttons.lua (Glow, HideGlow, GlowSpell,
--  GlowNextSpell, GlowClear, GlowCooldown, GlowCooldownMidnight,
--  GlowDefensiveHPMidnight, GlowInterruptMidnight) and adapted
--  for WWElite's standalone architecture.
--
--  Three independent glow channels:
--    1. NEXT SPELL glow  — the primary rotation suggestion.
--       Gold overlay on the button for the recommended spell.
--    2. COOLDOWN glow    — offensive cooldowns ready to use.
--       Green overlay, fades as the CD runs down.
--    3. DEFENSIVE glow   — defensive cooldowns (HP-scaled colour).
--       Red→yellow→green scale based on player HP.
--    4. INTERRUPT glow   — Spear Hand Strike when target is casting.
--       Red overlay, brightness tracks cast duration.
--
--  Glow style: "custom" (LibCustomGlow pixel or auto-cast) when
--  LibCustomGlow-1.0 is available, otherwise the built-in texture
--  overlay system (identical to MaxDps's non-custom path).
--
--  Settings keys (in addon.db):
--    glowStyle          "texture" | "pixel" | "autocast"  (default "texture")
--    highlightColor     {r,g,b,a}   next-spell overlay colour
--    cooldownColor      {r,g,b,a}   cooldown overlay colour
--    sizeMult           number      overlay size multiplier  (default 1.4)
--    enableCooldowns    bool        show offensive CD glows
--    enableDefensives   bool        show defensive CD glows
--    enableInterrupts   bool        show interrupt glow
--    disableBlizzGlow   bool        suppress default activation glow
-- ============================================================

local CustomGlow = LibStub and LibStub('LibCustomGlow-1.0', true)

local CreateColor   = CreateColor
local GetTime       = GetTime
local pairs         = pairs
local tinsert       = tinsert
local tremove       = tremove
local select        = select
local math_max      = math.max
local math_min      = math.min

-- Default colours used before db is initialised
local DEFAULT_HIGHLIGHT = { r=1,    g=0.85, b=0,    a=0.9  }  -- gold
local DEFAULT_COOLDOWN  = { r=0,    g=1,    b=0,    a=0.85 }  -- green
local DEFAULT_INTERRUPT = { r=1,    g=0,    b=0,    a=1    }  -- red

-- ── DB helpers ────────────────────────────────────────────────

local function DB(key, default)
    if addon.db and addon.db[key] ~= nil then return addon.db[key] end
    return default
end

local function HighlightColor() return DB('highlightColor', DEFAULT_HIGHLIGHT) end
local function CooldownColor()  return DB('cooldownColor',  DEFAULT_COOLDOWN)  end
local function SizeMult()       return DB('sizeMult', 1.4) end
local function GlowStyle()      return DB('glowStyle', 'texture') end
local function GetTexture()
    local t = DB('texture', '')
    if not t or t == '' then t = 'Interface\\Cooldown\\ping4' end
    return t
end

-- ── Overlay frame pool ────────────────────────────────────────

local function CreateOverlay(parent, id, overlayType, color)
    local frame = tremove(addon.FramePool)
    if not frame then
        frame = CreateFrame('Frame', 'WWEliteOverlay_' .. id, parent)
    end

    local mult = SizeMult()
    frame:SetParent(parent)
    frame:SetFrameStrata('HIGH')
    frame:SetPoint('CENTER', 0, 0)
    frame:SetWidth(parent:GetWidth()  * mult)
    frame:SetHeight(parent:GetHeight() * mult)

    -- Number/rank text (used by empowered spells if ever needed)
    if not frame.overlayText then
        local fs = frame:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
        fs:SetPoint('CENTER', frame, 'CENTER')
        local font, _, flags = fs:GetFont()
        fs:SetFont(font, 28, flags)
        fs:SetText('')
        fs:SetTextColor(1, 1, 1, 1)
        frame.overlayText = fs
    end
    frame.overlayText:SetText('')

    -- Texture
    if not frame.texture then
        local t = frame:CreateTexture('WWEliteGlowTex', 'OVERLAY')
        t:SetBlendMode('ADD')
        frame.texture = t
    end
    frame.texture:SetTexture(GetTexture())
    frame.texture:SetAllPoints(frame)

    -- Apply colour
    local c = color
    if not c then
        if overlayType == 'normal' then
            c = HighlightColor()
        elseif overlayType == 'cooldown' then
            c = CooldownColor()
        else
            c = DEFAULT_HIGHLIGHT
        end
    end
    if c then frame.texture:SetVertexColor(c.r, c.g, c.b, c.a or 1) end

    frame.ovType = overlayType
    tinsert(addon.Frames, frame)
    return frame
end

-- ── Low-level Glow / HideGlow ─────────────────────────────────

local function GlowPixel(button, id, color)
    if not CustomGlow then return end
    local col = color and {color.r, color.g, color.b, color.a or 1} or nil
    local style = GlowStyle()
    if style == 'pixel' then
        CustomGlow.PixelGlow_Start(button, col, nil, nil, nil, nil, 0, 0, false, id)
    else
        -- autocast style
        CustomGlow.AutoCastGlow_Start(button, col, nil, nil, nil, 0, 0, id)
    end
end

local function StopPixel(button, id)
    if not CustomGlow then return end
    local style = GlowStyle()
    if style == 'pixel' then
        CustomGlow.PixelGlow_Stop(button, id)
    else
        CustomGlow.AutoCastGlow_Stop(button, id)
    end
end

function addon:Glow(button, id, overlayType, color, alpha)
    local style = GlowStyle()
    if style ~= 'texture' and CustomGlow then
        GlowPixel(button, id, color)
        return
    end

    -- Texture overlay path (default)
    if not button.WWEliteOverlays then button.WWEliteOverlays = {} end

    if button.WWEliteOverlays[id] then
        local ov = button.WWEliteOverlays[id]
        ov:Show()
        if color then
            ov.texture:SetVertexColor(color.r, color.g, color.b, alpha or (color.a or 1))
        end
        ov.overlayText:SetText('')
    else
        local ov = CreateOverlay(button, id, overlayType, color)
        button.WWEliteOverlays[id] = ov
        ov:Show()
        if color and alpha then
            ov.texture:SetVertexColor(color.r, color.g, color.b, alpha)
        end
    end
end

function addon:HideGlow(button, id)
    local style = GlowStyle()
    if style ~= 'texture' and CustomGlow then
        StopPixel(button, id)
        return
    end
    if button.WWEliteOverlays and button.WWEliteOverlays[id] then
        button.WWEliteOverlays[id]:Hide()
    end
end

-- ── Overlay management ────────────────────────────────────────

function addon:DestroyAllOverlays()
    for _, frame in pairs(addon.Frames) do
        if frame:GetParent() then
            frame:GetParent().WWEliteOverlays = nil
        end
        frame:ClearAllPoints()
        frame:Hide()
        frame:SetParent(UIParent)
    end
    for k, frame in pairs(addon.Frames) do
        tinsert(addon.FramePool, frame)
        addon.Frames[k] = nil
    end
    addon.Flags = {}
end

-- ── GlowIndependent / ClearGlowIndependent ───────────────────
-- Used by cooldown, defensive, and interrupt channels.

function addon:GlowIndependent(spellId, id, color, alpha, glowType)
    local buttons = addon.Spells[spellId]
    if not buttons then return end
    for _, button in pairs(buttons) do
        local enabledKey = (glowType == 'defensive') and 'enableDefensives' or 'enableCooldowns'
        if DB(enabledKey, true) then
            self:Glow(button, id, glowType or 'cooldown', color, alpha)
        end
    end
end

function addon:ClearGlowIndependent(spellId, id)
    local buttons = addon.Spells[spellId]
    if not buttons then return end
    for _, button in pairs(buttons) do
        self:HideGlow(button, id)
    end
end

-- ── Next-spell glow (primary rotation suggestion) ─────────────

function addon:GlowSpell(spellId)
    if not spellId or spellId == 0 then return end
    local found = false

    -- Direct ID match
    if addon.Spells[spellId] then
        for _, button in pairs(addon.Spells[spellId]) do
            self:Glow(button, 'next', 'normal')
        end
        addon.SpellsGlowing[spellId] = 1
        found = true
    end

    -- Base spell fallback
    if not found then
        local baseID = FindBaseSpellByID and FindBaseSpellByID(spellId)
        if baseID and addon.Spells[baseID] then
            for _, button in pairs(addon.Spells[baseID]) do
                self:Glow(button, 'next', 'normal')
            end
            addon.SpellsGlowing[baseID] = 1
            found = true
        end
    end

    -- Override/rank fallback
    if not found then
        local overrideID = FindSpellOverrideByID and FindSpellOverrideByID(spellId)
        if overrideID and addon.Spells[overrideID] then
            for _, button in pairs(addon.Spells[overrideID]) do
                self:Glow(button, 'next', 'normal')
            end
            addon.SpellsGlowing[overrideID] = 1
            found = true
        end
    end

    -- Name-based fallback (handles talent overrides)
    if not found then
        C_Spell.RequestLoadSpellData(spellId)
        local searchName = GetSpellName and GetSpellName(spellId)
        if searchName then
            for sid, buttons in pairs(addon.Spells) do
                local n = GetSpellName and GetSpellName(sid)
                if n and n == searchName then
                    for _, button in pairs(buttons) do
                        self:Glow(button, 'next', 'normal')
                    end
                    addon.SpellsGlowing[sid] = 1
                    found = true
                end
            end
        end
    end
end

function addon:GlowNextSpell(spellId)
    self:GlowClear()
    self:GlowSpell(spellId)
end

function addon:GlowClear()
    for spellId, v in pairs(addon.SpellsGlowing) do
        if v == 1 then
            local buttons = addon.Spells[spellId]
            if buttons then
                for _, button in pairs(buttons) do
                    self:HideGlow(button, 'next')
                end
            end
            addon.SpellsGlowing[spellId] = 0
        end
    end
end

-- ── Cooldown glow (Midnight colour-curve version) ─────────────
-- Mirrors MaxDps:GlowCooldownMidnight.
-- Applies a green→yellow→red colour that tracks remaining CD.

local glowCDCurve
local glowCDGreen

local function EnsureCDCurve()
    if glowCDCurve then return end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return end
    glowCDCurve = C_CurveUtil.CreateColorCurve()
    glowCDCurve:SetType(Enum.LuaCurveType.Linear)
    glowCDCurve:AddPoint(0.0, CreateColor(1, 0, 0, 1))
    glowCDCurve:AddPoint(0.3, CreateColor(1, 1, 0, 0.5))
    glowCDCurve:AddPoint(0.7, CreateColor(0, 1, 0, 0))
    glowCDGreen = CreateColor(0, 1, 0, 1)
end

function addon:GlowCooldownMidnight(spellId, condition)
    if not DB('enableCooldowns', true) then
        if addon.Flags[spellId] then
            addon.Flags[spellId] = false
            self:ClearGlowIndependent(spellId, spellId)
        end
        return
    end
    EnsureCDCurve()
    if addon.Flags[spellId] == nil then addon.Flags[spellId] = false end

    if condition then
        local alpha = 1
        if glowCDCurve then
            local duration = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(spellId)
            local durColor = duration and duration:EvaluateRemainingDuration(glowCDCurve)
            if durColor then alpha = select(4, durColor:GetRGBA()) end
        end
        addon.Flags[spellId] = true
        self:GlowIndependent(spellId, spellId, glowCDGreen or DEFAULT_COOLDOWN, alpha, 'cooldown')
    else
        addon.Flags[spellId] = false
        self:ClearGlowIndependent(spellId, spellId)
    end
end

-- ── Defensive glow (HP-scaled Midnight version) ───────────────
-- Mirrors MaxDps:GlowDefensiveHPMidnight.
-- Colour tracks player HP: green when healthy → red when low.

local glowDefCurve
local glowDefReverse

local function EnsureDefCurves()
    if glowDefCurve then return end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return end
    glowDefCurve = C_CurveUtil.CreateColorCurve()
    glowDefCurve:SetType(Enum.LuaCurveType.Linear)
    glowDefCurve:AddPoint(0.3, CreateColor(1, 0, 0, 1))
    glowDefCurve:AddPoint(0.5, CreateColor(1, 1, 0, 0.5))
    glowDefCurve:AddPoint(1.0, CreateColor(0, 1, 0, 0))

    glowDefReverse = C_CurveUtil.CreateColorCurve()
    glowDefReverse:SetType(Enum.LuaCurveType.Linear)
    glowDefReverse:AddPoint(0.3, CreateColor(0, 1, 0, 1))
    glowDefReverse:AddPoint(0.5, CreateColor(1, 1, 0, 0.5))
    glowDefReverse:AddPoint(1.0, CreateColor(1, 0, 0, 1))
end

function addon:GlowDefensiveHP(spellId)
    if not DB('enableDefensives', true) then
        if addon.Flags[spellId] then
            addon.Flags[spellId] = false
            self:ClearGlowIndependent(spellId, spellId)
        end
        return
    end
    EnsureDefCurves()
    if addon.Flags[spellId] == nil then addon.Flags[spellId] = false end

    if UnitIsDeadOrGhost('player') then
        addon.Flags[spellId] = false
        self:ClearGlowIndependent(spellId, spellId)
        return
    end

    local color
    -- Purifying Brew: colour against stagger not HP
    if spellId == 119582 and glowDefReverse then
        local stagger  = UnitStagger  and UnitStagger('player')
        local maxHP    = UnitHealthMax and UnitHealthMax('player')
        local ok1 = not (issecretvalue and issecretvalue(stagger))
        local ok2 = not (issecretvalue and issecretvalue(maxHP))
        if ok1 and ok2 and stagger and maxHP and maxHP > 0 then
            color = glowDefReverse:Evaluate(stagger / maxHP)
        end
    end
    if not color and glowDefCurve then
        color = UnitHealthPercent and UnitHealthPercent('player', false, glowDefCurve) or DEFAULT_HIGHLIGHT
    end

    local alpha = 1
    if glowDefCurve then
        local duration = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(spellId)
        local durColor = duration and duration:EvaluateRemainingDuration(glowDefCurve)
        if durColor then alpha = select(4, durColor:GetRGBA()) end
    end

    addon.Flags[spellId] = true
    self:GlowIndependent(spellId, spellId, color, alpha, 'defensive')
end

-- ── Interrupt glow ────────────────────────────────────────────
-- Spear Hand Strike (116705) when target is casting interruptible.
-- Mirrors MaxDps:GlowInterruptMidnight.

local glowIntCurve

local function EnsureIntCurve()
    if glowIntCurve then return end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return end
    glowIntCurve = C_CurveUtil.CreateColorCurve()
    glowIntCurve:SetType(Enum.LuaCurveType.Linear)
    glowIntCurve:AddPoint(0.0, CreateColor(1, 0, 0, 1))
    glowIntCurve:AddPoint(0.3, CreateColor(1, 1, 0, 0.5))
    glowIntCurve:AddPoint(0.7, CreateColor(0, 1, 0, 0))
end

function addon:GlowInterrupt(spellId)
    if not DB('enableInterrupts', true) then return end
    EnsureIntCurve()
    if addon.Flags[spellId] == nil then addon.Flags[spellId] = false end

    -- Is the target casting something interruptible?
    local castName, _, _, _, _, _, _, notInterruptible = UnitCastingInfo('target')
    local chanName, _, _, _, _, _, notInterruptibleCh   = UnitChannelInfo('target')
    local casting = (castName and not notInterruptible) or (chanName and not notInterruptibleCh)

    if casting then
        local alpha = 1
        if glowIntCurve then
            local duration = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(spellId)
            local durColor = duration and duration:EvaluateRemainingDuration(glowIntCurve)
            if durColor then alpha = select(4, durColor:GetRGBA()) end
        end
        addon.Flags[spellId] = true
        self:GlowIndependent(spellId, spellId, DEFAULT_INTERRUPT, alpha)
    else
        addon.Flags[spellId] = false
        self:ClearGlowIndependent(spellId, spellId)
    end
end

-- ── Windwalker-specific cooldown tick ─────────────────────────
-- Called every rotation tick to update all secondary glows.
-- Mirrors the pattern in MaxDps_Monk/Specialization/Windwalker.lua.

-- Offensive CDs — glow when spell is usable (not on cooldown)
local WW_OFFENSIVE_CDS = {
    -- Midnight 12.0.5
    [1249625] = true,   -- Zenith (replaces SEF)
    [152173]  = true,   -- Serenity
    [115080]  = true,   -- Touch of Death
    [113656]  = true,   -- Fists of Fury (major window)
    [152175]  = true,   -- Whirling Dragon Punch
    [392983]  = true,   -- Strike of the Windlord
    [123904]  = true,   -- Invoke Xuen (Conduit version)
    [386276]  = true,   -- Bonedust Brew
}

-- Defensive CDs — use HP-scaled glow
local WW_DEFENSIVE_CDS = {
    [122470]  = true,   -- Touch of Karma
    [243435]  = true,   -- Fortifying Brew (WW)
    [122278]  = true,   -- Dampen Harm
    [122783]  = true,   -- Diffuse Magic
    [322101]  = true,   -- Expel Harm
}

local SPEAR_HAND_STRIKE = 116705

function addon:TickCooldownGlows()
    -- Offensive
    if DB('enableCooldowns', true) then
        for spellId in pairs(WW_OFFENSIVE_CDS) do
            local usable = addon:SpellReady(spellId)
            self:GlowCooldownMidnight(spellId, usable)
        end
    end

    -- Defensive
    if DB('enableDefensives', true) then
        for spellId in pairs(WW_DEFENSIVE_CDS) do
            self:GlowDefensiveHP(spellId)
        end
    end

    -- Interrupt
    if DB('enableInterrupts', true) then
        self:GlowInterrupt(SPEAR_HAND_STRIKE)
    end

    -- Trinkets
    if addon.ItemSpells then
        local slot1 = GetInventoryItemID('player', 13)
        local slot2 = GetInventoryItemID('player', 14)
        for itemId, spellId in pairs(addon.ItemSpells) do
            if itemId == slot1 or itemId == slot2 then
                local cd = C_Item.GetItemCooldown and C_Item.GetItemCooldown(itemId) or 0
                local usable = (cd == 0) and C_Item.IsUsableItem and C_Item.IsUsableItem(itemId)
                self:GlowCooldownMidnight(spellId, usable)
            end
        end
    end
end
