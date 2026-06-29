dofile((arg[0]:gsub("unlock_spec%.lua$", "harness.lua")))

-- Two light units (Vehicle -> tier light, eligible in every phase so only `unlock` varies).
local units = {
	{ class = UnitClass.Vehicle, unit = "freetk",   priority = 1.0 },              -- always available
	{ class = UnitClass.Vehicle, unit = "lockedtk", priority = 1.0, unlock = 1500 }, -- unlocks at 1500s
}

local function sample(quants)
	Context.MatchQuants = quants
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(units)
		if pick then seen[pick.unit] = true end
	end
	return seen
end

-- Before unlock (elapsed 1000s): locked unit must never appear; free unit does.
local early = sample(1000 * 70)
assert(early["freetk"], "free unit should spawn before unlock")
assert(not early["lockedtk"], "locked unit must NOT spawn before its unlock time")

-- After unlock (elapsed 1600s): locked unit becomes eligible.
local late = sample(1600 * 70)
assert(late["lockedtk"], "locked unit should spawn after its unlock time")

-- unit.unlock == nil is available at t=0.
local zero = sample(0)
assert(zero["freetk"], "nil-unlock unit available from t=0")
print("unlock OK")
