dofile((arg[0]:gsub("bias_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- FactionBias: shipped per-faction minimum-count floors, grounded in each faction's
-- real-world doctrine (see docs/superpowers/specs/2026-07-06-faction-composition-bias-design.md).
eq(FactionBias.ger.medium,      1, "ger: Blitzkrieg armor spearhead")
eq(FactionBias.ger_ss.light,    1, "ger_ss: Panzergrenadier mechanized infantry")
eq(FactionBias.ger2.rifle,      1, "ger2: Ostfront defensive infantry attrition")
eq(FactionBias.usa.artillery,   1, "usa: King of Battle")
eq(FactionBias.rus.smg,         1, "rus: PPSh assault infantry waves")
eq(FactionBias.rus_guard.heavy, 1, "rus_guard: Guards' first pick of heavy armor")
eq(FactionBias.jap.mortar,      1, "jap: infiltration doctrine, light infantry weapons")
eq(FactionBias.eng.artillery,   1, "eng: colossal cracks artillery preparation")
print("FactionBias data OK")

-- DecideTier: a floor-unmet, tierEligible category wins outright, bypassing the weight/
-- deficit math -- even when that math would clearly favor a different tier.
local late = CurrentPhase(480) -- heavy1/medium2/light3/rifle1/smg1
local allOk = { heavy = true, medium = true, light = true, rifle = true, smg = true }
local empty = { heavy = 0, medium = 0, light = 0, rifle = 0, smg = 0, aux = 0 }
eq(DecideTier(late, empty, false, allOk, false, { rifle = 1 }), "rifle",
	"floor-unmet rifle wins even though light has the largest weight share on an empty field")

-- Floor short-circuit ignores the enemy-tanks armor bump and the losing-smg bump: both would
-- normally favor a different tier, but the unmet floor still wins.
eq(DecideTier(late, empty, true, allOk, true, { rifle = 1 }), "rifle",
	"floor wins regardless of enemyHasTanks/losing adjustments")

-- Floor met exactly (live == floor): not "unmet" -- normal weight/deficit selection resumes.
local metFloor = { heavy = 0, medium = 0, light = 0, rifle = 1, smg = 0, aux = 0 }
eq(DecideTier(late, metFloor, false, allOk, false, { rifle = 1 }), "light",
	"floor met exactly falls through to normal selection (light still dominates)")

-- Floor set on a tier NOT in tierEligible (not unlocked yet / faction has no such tier): the
-- floor must never force an unreachable tier -- this is the starvation-prevention case (an
-- infinitely-unmet floor on an ineligible tier must not block every other tier for the rest
-- of the phase, the same failure shape as the pre-fix PruneGroups group-starvation bug).
local mediumIneligible = { heavy = true, light = true, rifle = true, smg = true } -- no medium
eq(DecideTier(late, empty, false, mediumIneligible, false, { medium = 5 }), "light",
	"floor on an ineligible tier is never selected; normal selection proceeds among eligible tiers")

-- No bias table (nil) or an empty bias table: behavior is unchanged from before this feature.
eq(DecideTier(late, empty, false, allOk), "light", "nil bias: identical to pre-feature behavior")
eq(DecideTier(late, empty, false, allOk, false, {}), "light", "empty bias table: no floors, normal selection")
print("DecideTier floor OK")
