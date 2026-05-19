local addonName, addon = ...

-- ============================================================
--  Modes — mirrors Hekili's Auto / Single / AOE / Cooldowns
--  paradigm, adapted for WindWalker.
-- ============================================================

addon.modes = {
    auto     = { label = "Auto",          aoeThreshold = 3, useCDs = false },
    single   = { label = "Single Target", aoeThreshold = 99, useCDs = false },
    aoe      = { label = "AOE",           aoeThreshold = 1, useCDs = false },
    cooldown = { label = "Cooldowns",     aoeThreshold = 3, useCDs = true  },
    mythic   = { label = "Mythic+",       aoeThreshold = 2, useCDs = true  },
    raid     = { label = "Raid",          aoeThreshold = 4, useCDs = true  },
}

function addon:GetModeData()
    return addon.modes[addon.state.mode] or addon.modes["auto"]
end

function addon:SetMode(mode)
    if addon.modes[mode] then
        addon.state.mode = mode
        if addon.db then addon.db.mode = mode end
        addon:Print("Mode → |cffffcc00" .. addon.modes[mode].label .. "|r")
        if addon.HUD and addon.HUD.UpdateModeLabel then
            addon.HUD:UpdateModeLabel()
        end
    else
        local valid = {}
        for k in pairs(addon.modes) do valid[#valid+1] = k end
        table.sort(valid)
        addon:Print("Unknown mode. Valid: " .. table.concat(valid, ", "))
    end
end

function addon:GetMode()
    return addon.state.mode
end

local modeOrder = { "auto", "single", "aoe", "cooldown", "mythic", "raid" }
function addon:CycleMode()
    local current = addon.state.mode
    for i, m in ipairs(modeOrder) do
        if m == current then
            local next = modeOrder[(i % #modeOrder) + 1]
            addon:SetMode(next)
            return
        end
    end
    addon:SetMode("auto")
end

function addon:EffectiveTargetCount()
    local modeData = self:GetModeData()
    local real     = self.state.targetCount or 1
    if modeData.aoeThreshold == 99 then return 1 end
    if modeData.aoeThreshold == 1  then return math.max(real, 2) end
    return real
end

function addon:UseCooldowns()
    return self:GetModeData().useCDs
end
