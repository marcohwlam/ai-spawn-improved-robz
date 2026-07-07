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

-- TryCappedTrickle: floor-unmet bypasses the interval cooldown but never the cap.
local savedGerRoster = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 1.0, class = UnitClass.ArtilleryTank, unit = "testarty", unlock = 0 },
}
Context.FieldUnits = {}
Context.LastArtyTime = 0
Context.GameClock = 1 -- 1s elapsed: far under ArtyIntervalSec(45), interval alone would block
Context.PendingSpawn = nil
Context.SpawnPauseUntil = 0
BotApi.Scene.Flags = { { name = "f1", occupant = 1 } }
local spawned = nil
local savedSpawn = BotApi.Commands.Spawn
BotApi.Commands.Spawn = function(_, unit) spawned = unit; return true end
local savedUpdateUnitToSpawn = UpdateUnitToSpawn
UpdateUnitToSpawn = function() end -- PIter/Purchases plumbing is irrelevant to these assertions

local acted = TryCappedTrickle({
	lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
	liveCountFn = LiveArtyCount, unitPickerFn = GetArtyUnit, label = "ARTY",
	floorValue = 1,
})
eq(acted, true, "floor-unmet bypasses the interval cooldown")
eq(spawned, "testarty", "the floor-forced attempt actually spawns the unit")

-- Cap is never bypassed, even with an unmet floor.
Context.FieldUnits = { [1] = { class = UnitClass.ArtilleryTank, unit = "testarty" },
                        [2] = { class = UnitClass.ArtilleryTank, unit = "testarty" } } -- 2 live == ArtyCap
Context.LastArtyTime = 0
Context.GameClock = 1
spawned = nil
local actedAtCap = TryCappedTrickle({
	lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
	liveCountFn = LiveArtyCount, unitPickerFn = GetArtyUnit, label = "ARTY",
	floorValue = 5, -- absurdly high, would always be "unmet"
})
eq(actedAtCap, false, "cap still blocks even when the floor is unmet")
eq(spawned, nil, "no spawn attempted once the cap is reached")

-- With no floor (nil), behavior matches the pre-refactor ARTY gate exactly: blocked by the
-- interval cooldown when it hasn't elapsed yet.
Context.FieldUnits = {}
Context.LastArtyTime = 0
Context.GameClock = 1
spawned = nil
local actedNoFloor = TryCappedTrickle({
	lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
	liveCountFn = LiveArtyCount, unitPickerFn = GetArtyUnit, label = "ARTY",
})
eq(actedNoFloor, false, "no floor: interval cooldown still blocks exactly as before")
eq(spawned, nil, "no spawn attempted")

BotApi.Commands.Spawn = savedSpawn
UpdateUnitToSpawn = savedUpdateUnitToSpawn
Purchases[1].Units["ger"] = savedGerRoster
Context.FieldUnits = {}
print("TryCappedTrickle OK")

-- LiveMortarCount counts only Mortar-class FieldUnits entries.
Context.FieldUnits = {
	[1] = { class = UnitClass.Mortar, unit = "testmortar1" },
	[2] = { class = UnitClass.MG,     unit = "mgs2(ger)" },
	[3] = { class = UnitClass.Mortar, unit = "testmortar2" },
}
eq(LiveMortarCount(), 2, "LiveMortarCount counts only Mortar-class entries")
Context.FieldUnits = {}

-- GetMortarUnit mirrors GetArtyUnit: unlock-aware, excludes already-fielded subtypes.
local savedGerRoster2 = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 0.8, class = UnitClass.Mortar, unit = "mortarA", unlock = 300 },
	{ priority = 0.5, class = UnitClass.Mortar, unit = "mortarB", unlock = 600 },
}
Context.GameClock = 0
eq(GetMortarUnit(), nil, "GetMortarUnit nil before any subtype unlocks")
Context.GameClock = 300
eq(GetMortarUnit().unit, "mortarA", "GetMortarUnit only offers the unlocked subtype")
Context.GameClock = 600
Context.FieldUnits = { [1] = { class = UnitClass.Mortar, unit = "mortarA" } }
eq(GetMortarUnit().unit, "mortarB", "already-fielded subtype excluded once the other unlocks")
Context.FieldUnits = {}
Purchases[1].Units["ger"] = savedGerRoster2
print("LiveMortarCount / GetMortarUnit OK")

-- Mortars are pulled out of the generic aux batch pool into their own dedicated trickle;
-- GetUnitToSpawn's aux path must never offer one, even when it is otherwise the only other
-- aux candidate competing for an owed aux slot.
local auxUnits = {
	{ class = UnitClass.Sniper, unit = "snipertest", priority = 1.0 },
	{ class = UnitClass.Mortar, unit = "mortartest", priority = 1.0 },
}
Context.GameClock = 0
Context.Groups = {}
Context.FillGroup = nil
Context.FieldUnits = {}
Context.AuxOwed = 5
local auxPicks = {}
for i = 1, 30 do
	local pick = GetUnitToSpawn(auxUnits)
	if pick then auxPicks[pick.unit] = true end
end
eq(auxPicks["mortartest"], nil, "Mortar-class unit never wins the generic aux batch")
eq(auxPicks["snipertest"], true, "sniper remains aux-eligible")
Context.AuxOwed = 0
print("Mortar excluded from generic aux pool OK")
