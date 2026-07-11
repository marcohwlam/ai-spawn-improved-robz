dofile((arg[0]:gsub("mp_discipline_spec%.lua$", "harness.lua")))

-- Tier reference: HeavyTank -> heavy, Tank+weight=medium -> medium, Vehicle -> light.
local heavy  = { class = UnitClass.HeavyTank, unit = "pz5g", priority = 1.0 }
local medium = { class = UnitClass.Tank, unit = "pz4h", priority = 1.0, weight = "medium" }
local light  = { class = UnitClass.Vehicle, unit = "lighttk", priority = 1.0 }

local function sample(units, seconds)
	Context.GameClock = seconds
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(units)
		if pick then seen[pick.unit] = true end
	end
	return seen
end

-- Sample time chosen inside the "early" phase (elapsed < 180 for the default global Phases
-- fallback, since Context.Phases is never set by this spec -- CurrentPhase falls back to the
-- global Phases template). Early's targets are { light, rifle, smg } -- medium has no entry,
-- so DecideTier can never select it -- only light is ever chosen. This gives a deterministic,
-- unambiguous baseline for "is light selectable" that isn't entangled with FactionBias floors
-- or phase.targets tie-breaking (both of which make tier selection deterministic per fixed
-- state, so a 200-call sample at a later elapsed cannot itself prove two tiers are reachable).

-- (A) Window inactive: the light unit is selectable (normal downgrade allowed).
Context.ArmorBankUntil = 0
local off = sample({ medium, light }, 100)
assert(off["lighttk"], "with no bank window, light tier is selectable")

-- (B) Window active + armor present: only armor spawns, never the cheaper light.
Context.ArmorBankUntil = 5000
local on = sample({ medium, light }, 100)   -- 100 < 5000 => window active
assert(on["pz4h"], "in bank window, affordable armor still spawns")
assert(not on["lighttk"], "in bank window, must NOT downgrade to the light tier")

-- (C) Window active + NO armor affordable: spawn nothing (hard bank).
Context.ArmorBankUntil = 5000
Context.GameClock = 100
Context.FailCooldown = {}
assert(GetUnitToSpawn({ light }) == nil, "in bank window with no armor, GetUnitToSpawn returns nil")

-- (D) Window trigger: an armor Spawn failure opens the window; a non-armor one does not.
local realUpdateUnitToSpawn = UpdateUnitToSpawn
UpdateUnitToSpawn = function() end -- PIter/Purchases plumbing is irrelevant to these assertions
BotApi.Commands.Spawn = function() return false end   -- force every spawn to fail
Context.FillGroup = nil
Context.FieldUnits = {}

Context.GameClock = 500
Context.ArmorBankUntil = 0
Context.SpawnInfo = heavy
AttemptSpawn("SPAWN")
assert(Context.ArmorBankUntil > 500, "armor Spawn failure opens the bank window")

Context.GameClock = 500
Context.ArmorBankUntil = 0
Context.SpawnInfo = light
AttemptSpawn("SPAWN")
assert(Context.ArmorBankUntil == 0, "non-armor Spawn failure must NOT open the bank window")

BotApi.Commands.Spawn = function() return true end    -- restore harness default
UpdateUnitToSpawn = realUpdateUnitToSpawn
print("mp discipline OK")
