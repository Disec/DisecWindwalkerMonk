local addonName, addon = ...

-- ============================================================
--  SimcImport — SimulationCraft APL import
--
--  Hekili's signature feature was importing SimC APL strings
--  directly from raidbots.com sims.  This module provides the
--  hook to do that.
--
--  The parser here handles the most common SimC action-line
--  patterns used for Windwalker.  A full SimC parser is outside
--  the scope of a single addon file, but this provides:
--    • Storage and display of the raw import
--    • Basic tokenisation of action= lines into a priority list
--    • A way to replace the hardcoded APL with a SimC-derived one
-- ============================================================

addon.simcImport = {}

-- Stores the last raw SimC string the user pasted
addon.simcImport.rawText = nil

-- Parsed priority list (list of spell-name strings, in order)
addon.simcImport.parsedList = nil

-- ──────────────────────────────────────────────────────────────
--  Parse a SimC APL string into an ordered list of action names
-- ──────────────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────────
--  Parse a SimC APL string into an ordered list of action entries.
--  Each entry: { name = "spell_name", condition = "if=..." | nil }
-- ──────────────────────────────────────────────────────────────
local function parseSimcAPL(aplText)
    local actions = {}
    for line in aplText:gmatch("[^\n]+") do
        -- Match lines like:  actions=rising_sun_kick
        --                    actions+=/blackout_kick,if=chi>=2&buff.serenity.down
        --                    actions.aoe=spinning_crane_kick,if=active_enemies>=3
        local action = line:match("^%s*actions[^=]*=/?([%w_]+)")
        if action and action ~= "call_action_list" and action ~= "run_action_list" then
            -- Extract the full if= clause (everything after the first comma)
            -- This preserves complex conditions like if=chi>=2&cooldown.fists_of_fury.remains>2
            local condition = line:match(",(.+)$")
            table.insert(actions, { name = action, condition = condition })
        end
    end
    return actions
end

-- ──────────────────────────────────────────────────────────────
--  Public API
-- ──────────────────────────────────────────────────────────────

-- Called from /wwelite import (see UI.lua) or programmatically
function addon:ImportSimc(aplText)
    if type(aplText) ~= "string" or #aplText == 0 then
        self:Print("SimC import: empty or invalid input.")
        return
    end

    self.simcImport.rawText   = aplText
    self.simcImport.parsedList = parseSimcAPL(aplText)

    local count = #self.simcImport.parsedList
    self:Print(string.format(
        "SimC APL imported — |cffffcc00%d|r action lines parsed. "
        .. "Type |cffffcc00/wwelite simcshow|r to review.",
        count
    ))
end

-- Dump the parsed list to chat for inspection
function addon:ShowSimcImport()
    local list = self.simcImport.parsedList
    if not list or #list == 0 then
        self:Print("No SimC APL imported yet.")
        return
    end
    self:Print("Parsed SimC priority list:")
    for i, entry in ipairs(list) do
        local cond = entry.condition and ("|cff888888  [" .. entry.condition .. "]|r") or ""
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("  |cff888888%2d.|r |cffffcc00%s|r%s", i, entry.name, cond)
        )
    end
end

-- Returns the parsed list (or nil)
function addon:GetSimcList()
    return self.simcImport.parsedList
end

-- Returns just the ordered name list (legacy / export use)
function addon:GetSimcNameList()
    local list = self.simcImport.parsedList
    if not list then return nil end
    local names = {}
    for _, entry in ipairs(list) do
        names[#names+1] = entry.name
    end
    return names
end
