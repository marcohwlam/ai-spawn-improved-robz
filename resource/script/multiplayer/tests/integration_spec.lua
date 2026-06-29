-- Integration smoke test: exercise the real GetUnitToSpawn path offline.
dofile((arg[0]:gsub("integration_spec%.lua$", "harness.lua")))

-- Synthetic roster spanning all tiers.
local units = {
	{ class = UnitClass.Infantry,  unit = "rifle",   priority = 2.0, recharge = 0 },
	{ class = UnitClass.Vehicle,   unit = "halftrk", priority = 1.0, recharge = 30 },
	{ class = UnitClass.Tank,      unit = "lighttk", priority = 1.5, weight = "light" },  -- light
	{ class = UnitClass.Tank,      unit = "medtk",   priority = 1.5, weight = "medium" }, -- medium
	{ class = UnitClass.HeavyTank, unit = "heavytk", priority = 1.0, recharge = 2000 }, -- heavy
}

-- EARLY phase (MatchQuants=0 -> t=0 -> armorCap=light). Medium/heavy must never be chosen.
local seenEarly = {}
for i = 1, 200 do
	local pick = GetUnitToSpawn(units)
	assert(pick ~= nil, "early pick should not be nil")
	seenEarly[pick.unit] = true
end
assert(not seenEarly["medtk"],   "EARLY must not spawn medium tank")
assert(not seenEarly["heavytk"], "EARLY must not spawn heavy tank")
assert(seenEarly["rifle"] or seenEarly["halftrk"] or seenEarly["lighttk"], "EARLY spawns inf/light")
print("integration EARLY armorCap OK")
print("integration OK")
