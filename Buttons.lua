local addonName, addon = ...

-- ============================================================
--  Buttons.lua — action-bar button registry
--
--  Ported from MaxDps/Buttons.lua and adapted for the WWElite
--  standalone (no Ace framework) architecture.
--
--  Responsibilities:
--    • Scan Blizzard and third-party action bars and build a
--      registry of spellID → {button, button, ...} mappings.
--    • Provide Fetch() which is called on login, spec change,
--      and bar layout events to rebuild the registry.
--    • Expose AddButton / FindButton for GlowManager use.
--
--  Supported bar add-ons (matching MaxDps coverage):
--    Blizzard default bars, LibActionButton-1.0 consumers
--    (ElvUI, Bartender4, Dominos, LUI, SyncUI, NDui, etc.),
--    ButtonForge, Neuron, QUI, DiabolicUI, AzeriteUI,
--    DragonflightUI, EllesmereUI.
-- ============================================================

local CustomGlow = LibStub and LibStub('LibCustomGlow-1.0', true)

local IsAddOnLoaded  = C_AddOns.IsAddOnLoaded
local GetItemSpell   = C_Item.GetItemSpell
local GetSpellInfo   = C_Spell and C_Spell.GetSpellInfo or _G.GetSpellInfo
local GetSpellName   = C_Spell and C_Spell.GetSpellName
local pairs          = pairs
local tinsert        = tinsert
local tremove        = tremove
local select         = select

-- ── Registry ──────────────────────────────────────────────────
-- addon.Spells     [spellID] = { button, ... }
-- addon.ItemSpells [itemID]  = itemSpellID
-- addon.Flags      [spellID] = bool  (cooldown/defensive glow state)
-- addon.SpellsGlowing [spellID] = 1  (next-spell glow state)
-- addon.FramePool  []  — recycled overlay frames
-- addon.Frames     []  — active overlay frames

addon.Spells        = addon.Spells        or {}
addon.ItemSpells    = addon.ItemSpells    or {}
addon.Flags         = addon.Flags         or {}
addon.SpellsGlowing = addon.SpellsGlowing or {}
addon.FramePool     = addon.FramePool     or {}
addon.Frames        = addon.Frames        or {}

-- Track LibActionButton variant names known to be loaded
local LABs = {
    ['LibActionButton-1.0']          = true,
    ['LibActionButton-1.0-ElvUI']    = true,
    ['LibActionButton-1.0-KkthnxUI'] = true,
    ['LibActionButton-1.0-NDui']     = true,
    ['LibActionButton-1.0-ls']       = true,
}

-- ── Low-level button registration ────────────────────────────

function addon:AddButton(spellId, button)
    if not spellId then return end
    if not self.Spells[spellId] then
        self.Spells[spellId] = {}
    end
    tinsert(self.Spells[spellId], button)
end

function addon:AddItemButton(button)
    local actionSlot = button:GetAttribute('action') or button.action
    if not actionSlot then return end
    if not (IsEquippedAction(actionSlot) or IsConsumableAction(actionSlot)) then return end
    local atype, itemId = GetActionInfo(actionSlot)
    if atype == 'item' and itemId then
        local _, itemSpellId = GetItemSpell(itemId)
        self.ItemSpells[itemId] = itemSpellId
        self:AddButton(itemSpellId, button)
    end
end

function addon:AddStandardButton(button)
    if not button then return end
    local btype = button:GetAttribute('type')
    if btype then
        local actionType = button:GetAttribute(btype)
        local spellId    = nil

        if btype == 'action' then
            local slot = button:GetAttribute('action')
            if not slot or slot == 0 then
                slot = button.GetPagedID and button:GetPagedID() or button.action
            end
            if not slot or slot == 0 then
                slot = button.CalculateAction and button:CalculateAction()
            end
            if slot and HasAction(slot) then
                btype, actionType = GetActionInfo(slot)
            else
                return
            end
        end

        if btype == 'macro' then
            spellId = actionType and GetMacroSpell(actionType)
            if not spellId then
                if button and not button.GetPagedID and button.id then
                    button.GetPagedID = function() return button.id end
                end
                local ms = button.GetPagedID and button:GetPagedID() or button.action
                spellId = ms and select(2, GetActionInfo(ms))
            end
        elseif btype == 'item' then
            self:AddItemButton(button)
            return
        elseif btype == 'spell' then
            local info = GetSpellInfo(actionType)
            spellId = info and info.spellID
        end

        if spellId and button then
            self:AddButton(spellId, button)
        end
    end

    -- Stance bar
    if button.Name and button.Name.GetName and button.Name.GetName(button):find('Stance') then
        local id = button:GetID()
        if id and id >= 1 and id <= GetNumShapeshiftForms() then
            local _, _, hasAction, spellID = GetShapeshiftFormInfo(id)
            if hasAction and spellID then self:AddButton(spellID, button) end
        end
    end

    -- Pet bar
    if button.Name and button.Name.GetName then
        if button.Name.GetName(button):match('^PetActionButton') then
            local id = button:GetID()
            if id then
                local _, _, _, _, _, _, spellId = GetPetActionInfo(id)
                if spellId then self:AddButton(spellId, button) end
            end
        end
    end

    -- Spell viewer frame (e.g. Conduit spells in 12.0.5)
    if button.viewerFrame and button.GetSpellID then
        local spellID = button:GetSpellID()
        if not issecretvalue(spellID) then self:AddButton(spellID, button) end
    end
end

-- ── Bar-specific fetchers ─────────────────────────────────────

function addon:FetchBlizzard()
    local bars = {
        'Action', 'MultiBarBottomLeft', 'MultiBarBottomRight',
        'MultiBarRight', 'MultiBarLeft', 'MultiBar5', 'MultiBar6', 'MultiBar7'
    }
    for _, barName in pairs(bars) do
        if _G[barName] or barName == 'Action' then
            for i = 1, 12 do
                local btn = _G[barName .. 'Button' .. i]
                if btn then self:AddStandardButton(btn) end
            end
        end
    end
    for i = 1, 10 do
        local btn = _G['StanceButton' .. i]
        if btn then self:AddStandardButton(btn) end
    end
    for i = 1, 10 do
        local btn = _G['PetActionButton' .. i]
        if btn then
            if not btn.GetPagedID and btn.id then
                btn.GetPagedID = function() return btn.id end
            end
            self:AddStandardButton(btn)
        end
    end
    -- Blizzard cooldown viewers (Midnight 12.0.5)
    local viewers = {
        { frame = _G['EssentialCooldownViewer'] },
        { frame = _G['UtilityCooldownViewer']   },
        { frame = _G['BuffIconCooldownViewer']  },
    }
    for _, v in ipairs(viewers) do
        if v.frame and v.frame.itemFramePool then
            for frame in v.frame.itemFramePool:EnumerateActive() do
                self:AddStandardButton(frame, true)
            end
        end
    end
end

function addon:FetchLibActionButton()
    local _, libs = LibStub and LibStub:IterateLibraries() or {}, {}
    if not libs then return end
    for libname in pairs(libs) do
        if libname:match('^LibActionButton%-1%.0') then
            local lib = LibStub(libname, true)
            if lib and lib.GetAllButtons then
                for button in pairs(lib:GetAllButtons()) do
                    local spellId = button:GetSpellId()
                    if spellId then self:AddButton(spellId, button) end
                    self:AddItemButton(button)
                end
            end
        end
    end
end

function addon:FetchBartender4()
    for i = 1, 10 do
        local btn = _G['BT4StanceButton' .. i]
        if btn then self:AddStandardButton(btn) end
    end
    for i = 1, 10 do
        local btn = _G['BT4PetButton' .. i]
        if btn then self:AddStandardButton(btn) end
    end
end

function addon:FetchElvUI()
    for i = 1, 10 do
        local btn = _G['ElvUI_StanceBarButton' .. i]
        if btn then self:AddStandardButton(btn) end
    end
end

function addon:FetchDominos()
    local ok, Ace = pcall(function()
        return LibStub and LibStub('AceAddon-3.0', true)
    end)
    if not ok or not Ace then return end
    local dom = Ace:GetAddon('Dominos', true)
    if not dom then return end
    local _, dominosButtons = dom.ActionButtons:GetAll()
    for button in pairs(dominosButtons) do
        if button and not button.GetPagedID and button.id then
            button.GetPagedID = function() return button.id end
        end
        if button then self:AddStandardButton(button) end
    end
    for i = 1, 10 do
        local btn = _G['DominosStanceButton' .. i]
        if btn then self:AddStandardButton(btn) end
    end
end

function addon:FetchLUI()
    local luiBars = {
        'LUIBarBottom1','LUIBarBottom2','LUIBarBottom3',
        'LUIBarBottom4','LUIBarBottom5','LUIBarBottom6',
        'LUIBarRight1','LUIBarRight2','LUIBarLeft1','LUIBarLeft2',
    }
    for _, bar in pairs(luiBars) do
        for i = 1, 12 do
            local btn = _G[bar .. 'Button' .. i]
            if btn then self:AddStandardButton(btn) end
        end
    end
end

function addon:FetchSyncUI()
    local syncbars = {
        SyncUI_ActionBar, SyncUI_MultiBar,
        SyncUI_SideBar and SyncUI_SideBar.Bar1,
        SyncUI_SideBar and SyncUI_SideBar.Bar2,
        SyncUI_SideBar and SyncUI_SideBar.Bar3,
        SyncUI_PetBar,
    }
    for _, bar in pairs(syncbars) do
        if bar then
            for i = 1, 12 do
                local btn = bar['Button' .. i]
                if btn then self:AddStandardButton(btn) end
            end
        end
    end
end

function addon:FetchDiabolic()
    for _, name in pairs({'EngineBar1','EngineBar2','EngineBar3','EngineBar4','EngineBar5'}) do
        for i = 1, 12 do
            local btn = _G[name .. 'Button' .. i]
            if btn then self:AddStandardButton(btn) end
        end
    end
end

function addon:FetchNeuron()
    for x = 1, 12 do
        for i = 1, 12 do
            local btn = _G['NeuronActionBar' .. x .. '_ActionButton' .. i]
            if btn then self:AddStandardButton(btn) end
        end
    end
end

function addon:FetchQUI()
    for x = 1, 12 do
        for i = 1, 12 do
            local btn = _G['QUI_Bar' .. x .. 'Button' .. i]
            if btn then self:AddStandardButton(btn) end
        end
    end
end

function addon:FetchButtonForge()
    local i = 1
    while true do
        local btn = _G['ButtonForge' .. i]
        if not btn then break end
        self:AddStandardButton(btn)
        i = i + 1
    end
end

function addon:FetchAzeriteUI()
    for b = 1, 8 do
        for i = 1, 12 do
            local btn = _G['AzeriteActionBar' .. b .. 'Button' .. i]
            if btn then
                if not btn.GetPagedID and btn.id then
                    btn.GetPagedID = function() return btn.id end
                end
                self:AddStandardButton(btn)
            end
        end
    end
    for b = 1, 10 do
        local btn = _G['AzeriteStanceBarButton' .. b]
        if btn then
            if not btn.GetPagedID and btn.id then
                btn.GetPagedID = function() return btn.id end
            end
            self:AddStandardButton(btn)
        end
    end
end

function addon:FetchDragonflightUI()
    for b = 1, 8 do
        local barName = 'DragonflightUIActionbarFrame' .. b
        if type(_G[barName]) == 'table' and _G[barName].buttonTable then
            for _, btn in pairs(_G[barName].buttonTable) do
                if btn then
                    if not btn.GetPagedID and btn.action then
                        btn.GetPagedID = function() return btn.action end
                    end
                    self:AddStandardButton(btn)
                end
            end
        end
    end
end

function addon:FetchEllesmereUI()
    for i = 1, 180 do
        local btn = _G['EABButton' .. i]
        if btn then self:AddStandardButton(btn) end
    end
end

-- ── Master Fetch ──────────────────────────────────────────────
-- Rebuilds the full button registry.  Called on login/spec change
-- and after bar layout events (debounced in Combat.lua).

function addon:Fetch(event)
    -- Clear existing registry
    self.Spells     = {}
    self.ItemSpells = {}

    self:FetchLibActionButton()
    self:FetchBlizzard()

    if IsAddOnLoaded('Bartender4')  then self:FetchBartender4()    end
    if IsAddOnLoaded('ElvUI')       then self:FetchElvUI()          end
    if IsAddOnLoaded('Dominos')     then self:FetchDominos()        end
    if IsAddOnLoaded('LUI')         then self:FetchLUI()            end
    if IsAddOnLoaded('SyncUI')      then self:FetchSyncUI()         end
    if IsAddOnLoaded('DiabolicUI')  then self:FetchDiabolic()       end
    if IsAddOnLoaded('Neuron')      then self:FetchNeuron()         end
    if IsAddOnLoaded('QUI')         then self:FetchQUI()            end
    if IsAddOnLoaded('ButtonForge') then self:FetchButtonForge()    end
    if IsAddOnLoaded('AzeriteUI') or IsAddOnLoaded('AzeriteUI5_JuNNeZ_Edition') then
        self:FetchAzeriteUI()
    end
    if IsAddOnLoaded('DragonflightUI') then self:FetchDragonflightUI() end
    if IsAddOnLoaded('EllesmereUIActionBars') then self:FetchEllesmereUI() end

    self:Print(string.format(
        "Buttons scanned — |cffffcc00%d|r spell IDs registered.",
        (function() local c=0; for _ in pairs(self.Spells) do c=c+1 end; return c end)()
    ))
end

-- ── Helpers ───────────────────────────────────────────────────

function addon:FindButton(spellId)
    return self.Spells[spellId]
end

-- Suppress Blizzard default activation-overlay glow so it doesn't
-- stack visually on top of our custom glow.
function addon:DisableBlizzardActivationGlow()
    if not ActionBarActionEventsFrame then return end
    ActionBarActionEventsFrame:UnregisterEvent('SPELL_ACTIVATION_OVERLAY_GLOW_SHOW')
    for LAB in pairs(LABs) do
        local lib = LibStub and LibStub(LAB, true)
        if lib and lib.eventFrame then
            lib.eventFrame:UnregisterEvent('SPELL_ACTIVATION_OVERLAY_GLOW_SHOW')
        end
    end
end

function addon:EnableBlizzardActivationGlow()
    if not ActionBarActionEventsFrame then return end
    ActionBarActionEventsFrame:RegisterEvent('SPELL_ACTIVATION_OVERLAY_GLOW_SHOW')
    for LAB in pairs(LABs) do
        local lib = LibStub and LibStub(LAB, true)
        if lib and lib.eventFrame then
            lib.eventFrame:RegisterEvent('SPELL_ACTIVATION_OVERLAY_GLOW_SHOW')
        end
    end
end
