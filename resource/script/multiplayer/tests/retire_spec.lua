dofile((arg[0]:gsub("retire_spec%.lua$", "harness.lua")))

-- Two light units (Vehicle -> tier light, eligible every phase so only `retire` varies).
local units = {
	{ class = UnitClass.Vehicle, unit = "permanent", priority = 1.0 },                -- no retire, always eligible
	{ class = UnitClass.Vehicle, unit = "retiring",  priority = 1.0, retire = 1500 }, -- drops at 1500s
}

local function sample(seconds)
	Context.GameClock = seconds
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(units)
		if pick then seen[pick.unit] = true end
	end
	return seen
end

-- One second before retire: both units still appear.
local before = sample(1499)
assert(before["permanent"], "permanent unit should spawn before retire")
assert(before["retiring"], "retiring unit should still spawn one second before its retire time")

-- At the retire boundary: retiring unit is gone, permanent stays.
local at = sample(1500)
assert(at["permanent"], "permanent unit should still spawn at the boundary")
assert(not at["retiring"], "retiring unit must NOT spawn at its retire time")

-- Well after retire: still gone.
local after = sample(9999)
assert(after["permanent"], "nil-retire unit has no upper bound")
assert(not after["retiring"], "retiring unit stays retired arbitrarily late")

print("retire OK")
