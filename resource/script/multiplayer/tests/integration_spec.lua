-- Integration smoke test: exercise the real GetUnitToSpawn path offline.
dofile((arg[0]:gsub("integration_spec%.lua$", "harness.lua")))

-- Synthetic roster spanning all tiers.
local units = {
	{ class = UnitClass.Infantry,  unit = "rifle",   priority = 2.0 },
	{ class = UnitClass.Vehicle,   unit = "halftrk", priority = 1.0 },
	{ class = UnitClass.Tank,      unit = "lighttk", priority = 1.5, weight = "light" },             -- light, always available
	{ class = UnitClass.Tank,      unit = "medtk",   priority = 1.5, weight = "medium", unlock = 300 },
	{ class = UnitClass.HeavyTank, unit = "heavytk", priority = 1.0, unlock = 1500 },
}

-- EARLY phase: pin clock to t=0 so the unlock gate excludes medtk (unlock=300) and
-- heavytk (unlock=1500). No fill group, so no armor front-load; the pool filter alone
-- must keep medium/heavy out. If the unlockOk gate were removed, medtk/heavytk would
-- enter the pool; DecideTier would still not pick them (no medium/heavy target in early),
-- but the LATE check below is the front-load bite.
Context.GameClock = 0
Context.Groups = {}
Context.FillGroup = nil
Context.FieldUnits = {}
local seenEarly = {}
for i = 1, 200 do
	local pick = GetUnitToSpawn(units)
	assert(pick ~= nil, "early pick should not be nil")
	seenEarly[pick.unit] = true
end
assert(not seenEarly["medtk"],   "EARLY must not spawn medium tank")
assert(not seenEarly["heavytk"], "EARLY must not spawn heavy tank")
assert(seenEarly["rifle"] or seenEarly["halftrk"] or seenEarly["lighttk"], "EARLY spawns inf/light")
print("integration EARLY unlock-gate OK")

-- LATE phase: a fill group with an armor lead front-loads armor while the army is below
-- its armor target, then yields to the ratio once the army meets the target. The army
-- counts here live OUTSIDE the fill group, proving the field is army-wide (Task 3a).
Context.GameClock = 2000
Context.Groups = { [1] = { members = {}, size = 8 } }
Context.FillGroup = 1

-- Army has no armor yet -> front-load fires -> the heaviest available unit is chosen.
Context.FieldUnits = {}
Context.Groups[1].armorLead = 2
local leadPick = GetUnitToSpawn(units)
assert(leadPick.unit == "heavytk" or leadPick.unit == "medtk",
	"LATE: front-load leads with armor when the army is below target")

-- Army already holds 3 armor (in no group) -> deficit gate blocks the front-load ->
-- the pick is not armor. (Armor target for an 8-cap group in late is now
-- floor((heavy1+medium2)/8*8+0.5) = 3, up from 2 before the medium weight bump.)
Context.FieldUnits = {
	a1 = { class = UnitClass.HeavyTank, unit = "heavytk" },
	a2 = { class = UnitClass.Tank,      unit = "medtk", weight = "medium" },
	a3 = { class = UnitClass.Tank,      unit = "medtk", weight = "medium" },
}
Context.Groups[1].armorLead = 2
local gatedPick = GetUnitToSpawn(units)
assert(gatedPick.unit ~= "heavytk" and gatedPick.unit ~= "medtk",
	"LATE: army at armor target -> front-load gated, ratio picks non-armor")
print("integration LATE armor-gate OK")
print("integration OK")
