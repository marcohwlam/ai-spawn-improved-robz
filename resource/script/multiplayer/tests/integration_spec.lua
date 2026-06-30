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

-- EARLY phase: pin clock to t=0 so unlock gate excludes medtk (unlock=300) and heavytk (unlock=1500).
-- Arm ArmorLead each iteration so the heaviest pool member is front-loaded. This makes the test
-- BITE: if the unlockOk gate were removed, medtk/heavytk would enter the pool and ArmorLead would
-- pick them here, tripping the assertions below. With the gate intact they never enter the pool,
-- ArmorLead finds no armor and falls through to normal (rifle/light) selection.
Context.QuantsPerSec = 1
Context.MatchQuants = 0
local seenEarly = {}
for i = 1, 200 do
	Context.ArmorLead = 1
	local pick = GetUnitToSpawn(units)
	assert(pick ~= nil, "early pick should not be nil")
	seenEarly[pick.unit] = true
end
assert(not seenEarly["medtk"],   "EARLY must not spawn medium tank")
assert(not seenEarly["heavytk"], "EARLY must not spawn heavy tank")
assert(seenEarly["rifle"] or seenEarly["halftrk"] or seenEarly["lighttk"], "EARLY spawns inf/light")
print("integration EARLY unlock-gate OK")
print("integration OK")
