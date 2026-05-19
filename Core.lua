local addonName, addon = ...

_G.WWElite = addon

WWEliteDB = WWEliteDB or {}

addon.state     = addon.state     or {}
addon.cooldowns = addon.cooldowns or {}

-- ── Spell ID registry ─────────────────────────────────────────
addon.spells = {
    TIGER_PALM             = 100780,
    BLACKOUT_KICK          = 100784,
    RISING_SUN_KICK        = 107428,
    FISTS_OF_FURY          = 113656,
    SPINNING_CRANE_KICK    = 101546,
    STRIKE_OF_THE_WINDLORD = 392983,
    WHIRLING_DRAGON_PUNCH  = 152175,
    TOUCH_OF_DEATH         = 115080,
    SPEAR_HAND_STRIKE      = 116705,
    -- Midnight 12.0.5
    ZENITH                 = 1249625,
    ZENITH_STOMP           = 1272696,
    SLICING_WINDS          = 404519,
    -- Defensive CDs
    TOUCH_OF_KARMA         = 122470,
    FORTIFYING_BREW        = 243435,
    DAMPEN_HARM            = 122278,
    DIFFUSE_MAGIC          = 122783,
    EXPEL_HARM             = 322101,
}

-- ── Saved-variable defaults ───────────────────────────────────
addon.defaults = {
    -- HUD / UI
    preview          = false,
    locked           = false,
    hudShown         = true,
    mode             = "auto",
    minimapAngle     = 220,
    minimapRingShown = false,
    -- Rotation engine
    rotationEnabled  = true,
    onCombatEnter    = false,   -- true = enable only in combat
    interval         = 0.1,    -- tick rate in seconds
    -- Glow style: "texture" | "pixel" | "autocast"
    glowStyle        = "texture",
    sizeMult         = 1.4,
    highlightColor   = { r=1, g=0.85, b=0, a=0.9 },   -- gold
    cooldownColor    = { r=0, g=1,    b=0, a=0.85 },   -- green
    -- Secondary glow channels
    enableCooldowns  = true,
    enableDefensives = true,
    enableInterrupts = true,
    -- Debug
    debug            = false,
    disabledSpells   = {},
}

-- ── DB init ───────────────────────────────────────────────────
function addon:InitDB()
    for k, v in pairs(self.defaults) do
        if WWEliteDB[k] == nil then
            WWEliteDB[k] = v
        end
    end
    addon.db         = WWEliteDB
    addon.state.mode = addon.db.mode or "auto"
end

-- ── Chat helper ───────────────────────────────────────────────
function addon:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00e5ffWWElite:|r " .. tostring(msg))
end

-- ── Rotation timer ────────────────────────────────────────────
-- A simple repeating C_Timer drives the main tick instead of
-- requiring AceTimer.  The timer handle is stored so it can be
-- cancelled cleanly on disable.

local rotationTimer = nil

function addon:EnableRotationTimer()
    if rotationTimer then return end  -- already running
    local interval = (addon.db and addon.db.interval) or 0.1
    rotationTimer = C_Timer.NewTicker(interval, function()
        addon:Tick()
    end)
end

function addon:DisableRotationTimer()
    if rotationTimer then
        rotationTimer:Cancel()
        rotationTimer = nil
    end
end

function addon:EnableRotation()
    if not (addon.db and addon.db.rotationEnabled) then return end
    addon:Fetch()
    addon:EnableRotationTimer()
    addon:Print("|cff00ff00Rotation enabled.|r")
end

function addon:DisableRotation()
    addon:DisableRotationTimer()
    addon:GlowClear()
    addon:DestroyAllOverlays()
    addon:Print("Rotation disabled.")
end

-- ── Main tick ─────────────────────────────────────────────────
-- Called every `interval` seconds.
-- 1. Update all secondary (cooldown/defensive/interrupt) glows.
-- 2. Ask the Engine for the next recommended spell.
-- 3. Apply the primary glow to that spell's action bar button.

function addon:Tick()
    -- Secondary glow channels (cooldowns, defensives, interrupt)
    if addon.TickCooldownGlows then
        addon:TickCooldownGlows()
    end

    -- Primary rotation suggestion
    if not addon.GetRecommendations then return end
    local mainSpell, _ = addon:GetRecommendations()
    if mainSpell and mainSpell ~= 0 then
        addon:GlowNextSpell(mainSpell)
    else
        addon:GlowClear()
    end
end

-- ── Bootstrap ─────────────────────────────────────────────────
-- Re-fetch bars on events that change action bar layout.
local fetchTimer = nil
local FETCH_EVENTS = {
    "SPELLS_CHANGED",
    "PLAYER_SPECIALIZATION_CHANGED",
    "UPDATE_SHAPESHIFT_FORM",
    "UPDATE_BONUS_ACTIONBAR",
    "PLAYER_ENTERING_WORLD",
}

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs(FETCH_EVENTS) do
    coreFrame:RegisterEvent(e)
end

coreFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" then
        addon:InitDB()

        -- Decide whether to auto-start the rotation
        if addon.db.onCombatEnter then
            -- Will be started by PLAYER_REGEN_DISABLED in Combat.lua
        else
            -- Start immediately after world entry
            C_Timer.After(1.5, function()
                addon:EnableRotation()
            end)
        end
        return
    end

    -- For spec/bar changes: debounce a Fetch so we don't hammer during load
    if event == "PLAYER_SPECIALIZATION_CHANGED" and unit ~= "player" then return end

    if fetchTimer then fetchTimer:Cancel() end
    fetchTimer = C_Timer.NewTimer(0.5, function()
        fetchTimer = nil
        if rotationTimer then   -- only re-fetch if rotation is active
            addon:Fetch(event)
        end
    end)
end)
