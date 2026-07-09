dofile((arg[0]:gsub("bias_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- FactionBias: shipped per-faction minimum-count floors, grounded in each faction's
-- real-world doctrine (see docs/superpowers/specs/2026-07-06-faction-composition-bias-design.md).
-- FactionBias[army] is keyed by phase name first, so a faction can bias a *different*
-- category per phase, not just a bigger floor on the same one. A phase with no entry floors
-- every category 0 (no-op).
eq(BiasFloor(FactionBias.ger, "mg", "early"),           1, "ger: MG42 teams anchoring the advance from the opening minutes")
eq(BiasFloor(FactionBias.ger, "mg", "mid"),             0, "ger: no mg floor after early")
eq(BiasFloor(FactionBias.ger, "medium", "early"),       0, "ger: no early entry, medium not yet eligible anyway")
eq(BiasFloor(FactionBias.ger, "medium", "mid"),         1, "ger: Blitzkrieg armor spearhead (mid)")
eq(BiasFloor(FactionBias.ger, "medium", "late"),        0, "ger: medium spearhead floor drops late")
eq(BiasFloor(FactionBias.ger, "heavy", "mid"),          0, "ger: heavy not yet part of the spearhead in mid")
eq(BiasFloor(FactionBias.ger, "heavy", "late"),         1, "ger: heavy (Tiger/Panther-class) joins the spearhead late")
eq(BiasFloor(FactionBias.ger_ss, "light", "early"),     1, "ger_ss: Panzergrenadier mechanized infantry (early)")
eq(BiasFloor(FactionBias.ger_ss, "light", "mid"),       0, "ger_ss: light floor drops after early")
eq(BiasFloor(FactionBias.ger_ss, "attank", "early"),    0, "ger_ss: no attank floor yet in early")
eq(BiasFloor(FactionBias.ger_ss, "attank", "mid"),      1, "ger_ss: StuG/Hetzer/Jagdpanzer Panzerjäger doctrine from mid")
eq(BiasFloor(FactionBias.ger_ss, "light", "late"),      0, "ger_ss: light mechanized floor drops late")
eq(BiasFloor(FactionBias.ger_ss, "heavy", "late"),      1, "ger_ss: late-war SS trades mechanized mass for concentrated heavy armor")
eq(BiasFloor(FactionBias.ger2, "rifle", "early"),       1, "ger2: Ostfront defensive infantry attrition (early)")
eq(BiasFloor(FactionBias.ger2, "medium", "mid"),        1, "ger2: reinforced with medium armor once it unlocks at mid")
eq(BiasFloor(FactionBias.ger2, "heavy", "late"),        1, "ger2: scarce heavy armor (Tiger II) piecemeal late")
eq(BiasFloor(FactionBias.usa, "artillery", "early"),    0, "usa: arty gated out of early anyway")
eq(BiasFloor(FactionBias.usa, "artillery", "late"),     1, "usa: King of Battle, sustained from mid (late)")
eq(BiasFloor(FactionBias.rus, "smg", "mid"),            1, "rus: PPSh assault infantry waves (mid)")
eq(BiasFloor(FactionBias.rus, "sniper", "early"),       1, "rus: Soviet sniper marksmanship doctrine (early)")
eq(BiasFloor(FactionBias.rus, "sniper", "mid"),         0, "rus: no sniper floor after early")
eq(BiasFloor(FactionBias.rus, "medium", "early"),       0, "rus: no massed-armor floor yet in early")
eq(BiasFloor(FactionBias.rus, "medium", "mid"),         1, "rus: Deep Battle massed T-34 sweeps join from mid")
eq(BiasFloor(FactionBias.rus, "medium", "late"),        1, "rus: massed armor sweeps hold late")
eq(BiasFloor(FactionBias.rus, "smg", "late"),           0, "rus: smg floor drops late -- doctrine shifts to artillery prep")
eq(BiasFloor(FactionBias.rus, "artillery", "mid"),      0, "rus: no artillery floor yet in mid")
eq(BiasFloor(FactionBias.rus, "artillery", "late"),     1, "rus: massed artillery preparation joins late")
eq(BiasFloor(FactionBias.rus_guard, "sniper", "early"), 1, "rus_guard: elite marksmanship training from the opening minutes")
eq(BiasFloor(FactionBias.rus_guard, "sniper", "mid"),   0, "rus_guard: no sniper floor after early")
eq(BiasFloor(FactionBias.rus_guard, "artillery", "early"), 0, "rus_guard: no artillery floor yet in early")
eq(BiasFloor(FactionBias.rus_guard, "artillery", "mid"),   1, "rus_guard: Guards artillery support (Katyusha/M7) from mid")
eq(BiasFloor(FactionBias.rus_guard, "artillery", "late"),  0, "rus_guard: artillery floor drops late -- doctrine shifts to heavy armor")
eq(BiasFloor(FactionBias.rus_guard, "heavy", "mid"),    0, "rus_guard: no heavy floor in mid anymore")
eq(BiasFloor(FactionBias.rus_guard, "heavy", "late"),   1, "rus_guard: Guards' heavy-armor priority holds late")
eq(BiasFloor(FactionBias.rus_guard, "medium", "mid"),   0, "rus_guard: no medium floor yet in mid")
eq(BiasFloor(FactionBias.rus_guard, "medium", "late"),  0, "rus_guard: no medium floor -- pure heavy-armor doctrine")
eq(BiasFloor(FactionBias.jap, "mortar", "early"),       1, "jap: infiltration doctrine, light infantry weapons (early)")
eq(BiasFloor(FactionBias.jap, "artillery", "early"),    0, "jap: no arty floor yet in early")
eq(BiasFloor(FactionBias.jap, "artillery", "mid"),      1, "jap: Ho-Ni/Ha-To SPG support joins from mid")
eq(BiasFloor(FactionBias.jap, "artillery", "late"),     1, "jap: SPG support holds late")
eq(BiasFloor(FactionBias.eng, "artillery", "mid"),      1, "eng: colossal cracks artillery preparation (mid)")
eq(BiasFloor(FactionBias.eng, "artillery", "late"),     1, "eng: colossal cracks, sustained from mid (late)")
eq(BiasFloor(FactionBias.eng, "heavy", "mid"),          0, "eng: no heavy floor yet in mid")
eq(BiasFloor(FactionBias.eng, "heavy", "late"),         1, "eng: Churchill/Firefly heavy armor joins late")
print("FactionBias data OK")

-- BiasFloor: nil bias, a bias with no entry for the given phase, and a phase entry with no
-- entry for the given category all default to 0.
eq(BiasFloor(nil, "medium", "late"), 0, "nil bias: floor 0")
eq(BiasFloor({}, "medium", "late"), 0, "empty bias: floor 0")
eq(BiasFloor({ late = { medium = 2 } }, "medium", "mid"), 0, "missing phase entry defaults to 0")
eq(BiasFloor({ late = { medium = 2 } }, "heavy", "late"), 0, "missing category in a present phase defaults to 0")
eq(BiasFloor({ late = { medium = 2 } }, "medium", "late"), 2, "present phase+category resolves")
print("BiasFloor OK")

-- DecideTier: a floor-unmet, tierEligible category wins outright, bypassing the weight/
-- deficit math -- even when that math would clearly favor a different tier.
local late = CurrentPhase(480) -- heavy1/medium2/light2/rifle1/smg1
local allOk = { heavy = true, medium = true, light = true, rifle = true, smg = true }
local empty = { heavy = 0, medium = 0, light = 0, rifle = 0, smg = 0, aux = 0 }
eq(DecideTier(late, empty, false, allOk, false, { late = { rifle = 1 } }), "rifle",
	"floor-unmet rifle wins even though light has the largest weight share on an empty field")

-- Floor short-circuit ignores the enemy-tanks armor bump and the losing-smg bump: both would
-- normally favor a different tier, but the unmet floor still wins.
eq(DecideTier(late, empty, true, allOk, true, { late = { rifle = 1 } }), "rifle",
	"floor wins regardless of enemyHasTanks/losing adjustments")

-- Floor met exactly (live == floor): not "unmet" -- normal weight/deficit selection resumes.
-- light and medium tie for the largest deficit (2/7 target share each, both empty).
local metFloor = { heavy = 0, medium = 0, light = 0, rifle = 1, smg = 0, aux = 0 }
local metFloorPick = DecideTier(late, metFloor, false, allOk, false, { late = { rifle = 1 } })
assert(metFloorPick == "light" or metFloorPick == "medium",
	"floor met exactly falls through to normal selection (light/medium tie), got "
		.. tostring(metFloorPick))

-- Floor set on a tier NOT in tierEligible (not unlocked yet / faction has no such tier): the
-- floor must never force an unreachable tier -- this is the starvation-prevention case (an
-- infinitely-unmet floor on an ineligible tier must not block every other tier for the rest
-- of the phase, the same failure shape as the pre-fix PruneGroups group-starvation bug).
local mediumIneligible = { heavy = true, light = true, rifle = true, smg = true } -- no medium
eq(DecideTier(late, empty, false, mediumIneligible, false, { late = { medium = 5 } }), "light",
	"floor on an ineligible tier is never selected; normal selection proceeds among eligible tiers")

-- No bias table (nil) or an empty bias table: behavior is unchanged from before this feature.
-- light and medium tie for the largest target share on an empty field.
local nilBiasPick = DecideTier(late, empty, false, allOk)
assert(nilBiasPick == "light" or nilBiasPick == "medium",
	"nil bias: identical to pre-feature behavior (light/medium tie), got " .. tostring(nilBiasPick))
local emptyBiasPick = DecideTier(late, empty, false, allOk, false, {})
assert(emptyBiasPick == "light" or emptyBiasPick == "medium",
	"empty bias table: no floors, normal selection (light/medium tie), got " .. tostring(emptyBiasPick))
print("DecideTier floor OK")

-- Per-phase floor with a different category per phase: the same bias table forces a
-- different tier depending on which phase is passed in, even with tierEligible identical
-- across both calls -- this is the "different type by phase" case, not just a bigger number.
local early = CurrentPhase(50) -- early phase, light3/rifle3/smg1
local phasedBias = { mid = { medium = 1 }, late = { medium = 2, heavy = 1 } }
local earlyPick = DecideTier(early, empty, false, allOk, false, phasedBias)
eq(earlyPick ~= "medium" and earlyPick ~= "heavy", true,
	"early: bias table has no early entry, so no category short-circuits (picked "
		.. tostring(earlyPick) .. ")")
eq(DecideTier(late, empty, false, allOk, false, phasedBias), "heavy",
	"late: heavy is unmet AND checked first in tier order, so it wins over medium (also unmet)")
local midPhase = CurrentPhase(300) -- mid phase, medium2/light3/rifle1/smg1
eq(DecideTier(midPhase, empty, false, allOk, false, phasedBias), "medium",
	"mid: only medium has a floor this phase (heavy has none in mid), so medium wins")
print("DecideTier per-phase category shift OK")

-- TryCappedTrickle: floor-unmet bypasses the interval cooldown but never the cap.
local savedGerRoster = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 1.0, class = UnitClass.ArtilleryTank, unit = "testarty", unlock = 0 },
}
Context.FieldUnits = {}
Context.LastArtyTime = 0
Context.GameClock = 1 -- 1s elapsed: far under ArtyIntervalSec(45), interval alone would block
Context.PendingSpawn = nil
Context.SpawnSlowdownUntil = 0
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
BotApi.Scene.Flags = {}
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

-- LiveAtTankCount counts only ATTank-class FieldUnits entries.
Context.FieldUnits = {
	[1] = { class = UnitClass.ATTank, unit = "testtd1" },
	[2] = { class = UnitClass.MG,     unit = "mgs2(ger)" },
	[3] = { class = UnitClass.ATTank, unit = "testtd2" },
}
eq(LiveAtTankCount(), 2, "LiveAtTankCount counts only ATTank-class entries")
Context.FieldUnits = {}

-- GetAtTankUnit mirrors GetArtyUnit/GetMortarUnit: unlock-aware, excludes already-fielded
-- subtypes.
local savedGerRoster3 = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 0.8, class = UnitClass.ATTank, unit = "tdA", unlock = 300 },
	{ priority = 0.5, class = UnitClass.ATTank, unit = "tdB", unlock = 600 },
}
Context.GameClock = 0
eq(GetAtTankUnit(), nil, "GetAtTankUnit nil before any subtype unlocks")
Context.GameClock = 300
eq(GetAtTankUnit().unit, "tdA", "GetAtTankUnit only offers the unlocked subtype")
Context.GameClock = 600
Context.FieldUnits = { [1] = { class = UnitClass.ATTank, unit = "tdA" } }
eq(GetAtTankUnit().unit, "tdB", "already-fielded subtype excluded once the other unlocks")
Context.FieldUnits = {}
Purchases[1].Units["ger"] = savedGerRoster3
print("LiveAtTankCount / GetAtTankUnit OK")

-- LiveSniperCount counts only Sniper-class FieldUnits entries.
Context.FieldUnits = {
	[1] = { class = UnitClass.Sniper, unit = "testsnipe1" },
	[2] = { class = UnitClass.MG,     unit = "mgs2(ger)" },
	[3] = { class = UnitClass.Sniper, unit = "testsnipe2" },
}
eq(LiveSniperCount(), 2, "LiveSniperCount counts only Sniper-class entries")
Context.FieldUnits = {}

-- GetSniperUnit mirrors GetArtyUnit/GetMortarUnit/GetAtTankUnit: unlock-aware, excludes
-- already-fielded subtypes.
local savedGerRoster4 = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 0.8, class = UnitClass.Sniper, unit = "snipeA", unlock = 300 },
	{ priority = 0.5, class = UnitClass.Sniper, unit = "snipeB", unlock = 600 },
}
Context.GameClock = 0
eq(GetSniperUnit(), nil, "GetSniperUnit nil before any subtype unlocks")
Context.GameClock = 300
eq(GetSniperUnit().unit, "snipeA", "GetSniperUnit only offers the unlocked subtype")
Context.GameClock = 600
Context.FieldUnits = { [1] = { class = UnitClass.Sniper, unit = "snipeA" } }
eq(GetSniperUnit().unit, "snipeB", "already-fielded subtype excluded once the other unlocks")
Context.FieldUnits = {}
Purchases[1].Units["ger"] = savedGerRoster4
print("LiveSniperCount / GetSniperUnit OK")

-- Mortars are pulled out of the generic aux batch pool into their own dedicated trickle;
-- GetUnitToSpawn's aux path must never offer one, even when it is otherwise the only other
-- aux candidate competing for an owed aux slot. MG is the control (still generic-aux-eligible,
-- unlike Sniper/ATTank/Mortar which all have their own dedicated trickles now).
BotApi.Scene.Flags = {} -- FlagDeficit()==0 -> IsLosing()==false -> MG stays AuxEligible
local auxUnits = {
	{ class = UnitClass.MG,     unit = "mgtest", priority = 1.0 },
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
eq(auxPicks["mgtest"], true, "MG remains aux-eligible")
Context.AuxOwed = 0
print("Mortar excluded from generic aux pool OK")

-- Tank destroyers (ATTank) are likewise pulled out of the generic aux batch pool into their
-- own dedicated trickle; GetUnitToSpawn's aux path must never offer one.
local attankAuxUnits = {
	{ class = UnitClass.MG,     unit = "mgtest2", priority = 1.0 },
	{ class = UnitClass.ATTank, unit = "attanktest", priority = 1.0 },
}
Context.GameClock = 0
Context.Groups = {}
Context.FillGroup = nil
Context.FieldUnits = {}
Context.AuxOwed = 5
local attankAuxPicks = {}
for i = 1, 30 do
	local pick = GetUnitToSpawn(attankAuxUnits)
	if pick then attankAuxPicks[pick.unit] = true end
end
eq(attankAuxPicks["attanktest"], nil, "ATTank-class unit never wins the generic aux batch")
eq(attankAuxPicks["mgtest2"], true, "MG remains aux-eligible")
Context.AuxOwed = 0
print("ATTank excluded from generic aux pool OK")

-- Snipers are likewise pulled out of the generic aux batch pool into their own dedicated
-- trickle; GetUnitToSpawn's aux path must never offer one.
local sniperAuxUnits = {
	{ class = UnitClass.MG,     unit = "mgtest3", priority = 1.0 },
	{ class = UnitClass.Sniper, unit = "snipertest3", priority = 1.0 },
}
Context.GameClock = 0
Context.Groups = {}
Context.FillGroup = nil
Context.FieldUnits = {}
Context.AuxOwed = 5
local sniperAuxPicks = {}
for i = 1, 30 do
	local pick = GetUnitToSpawn(sniperAuxUnits)
	if pick then sniperAuxPicks[pick.unit] = true end
end
eq(sniperAuxPicks["snipertest3"], nil, "Sniper-class unit never wins the generic aux batch")
eq(sniperAuxPicks["mgtest3"], true, "MG remains aux-eligible")
Context.AuxOwed = 0
print("Sniper excluded from generic aux pool OK")

-- ValidateFactionBias: a faction's artillery/mortar floor must never exceed that category's
-- cap (a floor above the cap could never be satisfied and would spin TryCappedTrickle's
-- floor-bypass forever without ever completing).
local savedBias = FactionBias
FactionBias = { ger = { late = { artillery = ArtyCap + 1 } } }
eq(#ValidateFactionBias(), 1, "one violation for a floor above its cap")
FactionBias = { ger = { late = { artillery = ArtyCap } } }
eq(#ValidateFactionBias(), 0, "floor exactly at the cap is not a violation")
FactionBias = { ger = { late = { mortar = MortarCap + 1 } } }
eq(#ValidateFactionBias(), 1, "one violation for a mortar floor above MortarCap")
FactionBias = { ger = { late = { attank = AtTankCap + 1 } } }
eq(#ValidateFactionBias(), 1, "one violation for an attank floor above AtTankCap")
FactionBias = { ger = { early = { mg = DefenderCap + 1 } } }
eq(#ValidateFactionBias(), 1, "one violation for an mg floor above DefenderCap")
FactionBias = { rus = { early = { sniper = SniperCap + 1 } } }
eq(#ValidateFactionBias(), 1, "one violation for a sniper floor above SniperCap")
FactionBias = savedBias
local shipped = ValidateFactionBias()
eq(#shipped, 0, "shipped FactionBias data has no floor exceeding its cap: "
	.. table.concat(shipped, "; "))
print("ValidateFactionBias OK")

-- TryCappedTrickle: when every gate condition (interval/floor, cap, phase, held-flag,
-- spawn-slot) passes but unitPickerFn finds nothing spawnable right now (e.g. everything
-- unlocked-but-unaffordable, or benched by FailCooldown), the function must fall through
-- (return false) instead of claiming the idle-tick window -- otherwise it silently blocks
-- BACKFILL (and, before ARTY, DEFENDER) from ever getting a turn on quants where the
-- category has an unmet floor but no candidate. See the 2026-07-06 final-review fix.
Context.FieldUnits = {}
Context.LastArtyTime = 0
Context.GameClock = 1 -- far under ArtyIntervalSec: only the unmet floor should let this through
Context.PendingSpawn = nil
Context.SpawnSlowdownUntil = 0
BotApi.Scene.Flags = { { name = "f1", occupant = 1 } }
local actedNoUnit = TryCappedTrickle({
	lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
	liveCountFn = LiveArtyCount,
	unitPickerFn = function() return nil end, -- no spawnable unit right now
	label = "ARTY",
	floorValue = 1,
})
eq(actedNoUnit, false, "no spawnable unit: falls through instead of claiming the idle-tick window")
BotApi.Scene.Flags = {}
print("TryCappedTrickle no-unit fallthrough OK")
