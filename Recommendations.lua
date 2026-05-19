local addonName, addon = ...

-- ============================================================
--  Recommendations.lua  (v2.3)
--
--  Single authoritative definition of GetRecommendations() and
--  GetNextAction().  Rotation.lua is removed from the TOC.
--
--  New in v2.3:
--  • Interrupt injection: when Engine.interruptReady is true,
--    Paralysis (115078) is inserted at queue position 1 and
--    the normal queue shifts to positions 2–4.  This surfaces
--    the kick without disrupting the chi simulation (Engine
--    never spends chi for it).
--  • addon.state.lastSpell is updated only from the *non-interrupt*
--    primary spell so Combo Strike tracking doesn't stutter on
--    interrupt frames.
-- ============================================================

function addon:GetRecommendations()
    local queue     = addon.Engine:BuildQueue()
    local mainSpell = queue[1]

    -- Update last-spell for Combo Strike tracking.
    -- We record the first non-interrupt spell so that an interrupt
    -- frame doesn't reset Combo Strike state to Paralysis (which is
    -- not in the normal rotation).
    addon.state.lastSpell = mainSpell

    -- Build the remainder list (slots 2–4 from Engine)
    local rest = {}
    for i = 2, #queue do rest[#rest + 1] = queue[i] end

    -- ── Interrupt injection ──────────────────────────────────
    -- If Engine flagged an interrupt as ready, push Paralysis to
    -- slot 1 and demote the normal main spell to slot 2.
    -- The UI will show Paralysis with a distinct visual treatment
    -- (the glow turns red) when it occupies the primary slot.
    if addon.Engine.interruptReady then
        table.insert(rest, 1, mainSpell)   -- push normal main → slot 2
        mainSpell = addon.Engine.PARALYSIS -- interrupt is now slot 1
    end

    return mainSpell, rest
end

-- Convenience: just the next single action
function addon:GetNextAction()
    local spell, _ = self:GetRecommendations()
    return spell
end
