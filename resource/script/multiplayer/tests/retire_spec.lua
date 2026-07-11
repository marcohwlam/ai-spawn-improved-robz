dofile((arg[0]:gsub("retire_spec%.lua$", "harness.lua")))

-- Two light units (Vehicle -> tier light, eligible every phase so only `retire` varies).
local units = {
	{ class = UnitClass.Vehicle, unit = "permanent", priority = 1.0 },                -- no retire, always eligible
	{ class = UnitClass.Vehicle, unit = "retiring",  priority = 1.0, retire = 1500 }, -- drops at 1500s
}

local function sample(seconds, pool)
	pool = pool or units
	Context.GameClock = seconds
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(pool)
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

-- Medium-tier units (Tank + weight="medium" -> tier medium, per TierOf) drive the
-- same gate through the actual tier the feature targets, not just light/Vehicle.
-- min_income=5 matches the harness's fixed BotApi.Commands:Income() of 5 so both
-- are affordable.
local mediumUnits = {
	{ class = UnitClass.Tank, weight = "medium", unit = "med_permanent", priority = 1.0,
	  min_income = 5 },                                                  -- no retire, always eligible
	{ class = UnitClass.Tank, weight = "medium", unit = "med_retiring", priority = 1.0,
	  min_income = 5, retire = 1500 },                                   -- drops at 1500s
}

-- Before retire: both medium units appear, confirming the tier resolves to medium
-- (TierOf: class==Tank, weight=="medium" -> "medium") and is reachable via DecideTier.
local medBefore = sample(1499, mediumUnits)
assert(medBefore["med_permanent"], "permanent medium tank should spawn before retire")
assert(medBefore["med_retiring"], "retiring medium tank should still spawn one second before its retire time")

-- At/after the retire boundary: the retiring medium tank is gone, its no-retire peer stays.
local medAt = sample(1500, mediumUnits)
assert(medAt["med_permanent"], "permanent medium tank should still spawn at the boundary")
assert(not medAt["med_retiring"], "retiring medium tank must NOT spawn at its retire time")

print("retire OK")
