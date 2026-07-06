dofile((arg[0]:gsub("airborne_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- EnemyFlagPct: enemy / total, 0 when empty.
BotApi.Scene.Flags = {}
eq(EnemyFlagPct(), 0, "no flags -> 0")
BotApi.Scene.Flags = {
	{ name = "f1", occupant = 2 }, { name = "f2", occupant = 2 },
	{ name = "f3", occupant = 2 }, { name = "f4", occupant = 1 },
}
eq(EnemyFlagPct(), 0.75, "3 of 4 enemy -> 0.75")
print("EnemyFlagPct OK")

-- GetAirborneUnit: returns an Airborne row from the harness ger roster.
local u = GetAirborneUnit()
assert(u ~= nil, "GetAirborneUnit returned nil")
eq(u.class, UnitClass.Airborne, "GetAirborneUnit class")
-- nil when the roster has no airborne.
local saved = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = { { priority = 1.0, class = UnitClass.Infantry, unit = "x" } }
eq(GetAirborneUnit(), nil, "GetAirborneUnit nil when no airborne")
Purchases[1].Units["ger"] = saved
print("GetAirborneUnit OK")

-- LiveAirborneCount: counts AirborneSquads entries.
Context.AirborneSquads = { [11] = true, [12] = true }
eq(LiveAirborneCount(), 2, "LiveAirborneCount")
Context.AirborneSquads = {}
eq(LiveAirborneCount(), 0, "LiveAirborneCount empty")
print("airborne helpers OK")

-- DeepStrikeTarget: pick the FURTHEST enemy-held ENEMY-sector flag (max axis).
Context.Groups = {}
Context.FlagLabel = {
	eNear = { sector = "ENEMY", axis = 0.60 },
	eDeep = { sector = "ENEMY", axis = 0.90 },
	mid   = { sector = "CONTESTED", axis = 0.50 },
	ours  = { sector = "OWN", axis = 0.10 },
}
BotApi.Scene.Flags = {
	{ name = "eNear", occupant = 2 },  -- enemy-held enemy base
	{ name = "eDeep", occupant = 2 },  -- enemy-held enemy base, deeper
	{ name = "mid",   occupant = 2 },  -- enemy-held but not a base (CONTESTED)
	{ name = "ours",  occupant = 1 },
}
eq(DeepStrikeTarget(), "eDeep", "furthest enemy base first")

-- After the deepest base is taken (now ours), the next-furthest base is chosen.
BotApi.Scene.Flags = {
	{ name = "eNear", occupant = 2 },
	{ name = "eDeep", occupant = 1 },  -- captured
	{ name = "mid",   occupant = 2 },
	{ name = "ours",  occupant = 1 },
}
eq(DeepStrikeTarget(), "eNear", "chain to next-furthest enemy base")

-- No enemy base left -> the main group target.
Context.Groups = { [1] = { target = "mainObjective" } }
BotApi.Scene.Flags = {
	{ name = "eNear", occupant = 1 },
	{ name = "eDeep", occupant = 1 },
	{ name = "ours",  occupant = 1 },
}
eq(DeepStrikeTarget(), "mainObjective", "no enemy base -> main group target")

-- No enemy base and no group -> nil.
Context.Groups = {}
eq(DeepStrikeTarget(), nil, "no base, no group -> nil")
print("DeepStrikeTarget OK")

-- CaptureFlag routes a tagged airborne squad to its DeepStrikeTarget.
local routed = nil
BotApi.Commands.CaptureFlag = function(_, squad, flagName) routed = flagName end
Context.SquadGroup = {}
Context.Cappers = {}
Context.FieldUnits = {}
Context.Groups = {}
Context.AirborneSquads = { [21] = true }
Context.FlagLabel = {
	eDeep = { sector = "ENEMY", axis = 0.90 },
	eNear = { sector = "ENEMY", axis = 0.60 },
}
BotApi.Scene.Flags = {
	{ name = "eDeep", occupant = 2 },
	{ name = "eNear", occupant = 2 },
}
routed = nil; CaptureFlag(21)
eq(routed, "eDeep", "airborne routes to furthest enemy base")

-- No enemy base and no group -> no order issued.
BotApi.Scene.Flags = { { name = "eDeep", occupant = 1 }, { name = "eNear", occupant = 1 } }
routed = "UNSET"; CaptureFlag(21)
eq(routed, "UNSET", "airborne issues no order when target nil")
print("CaptureFlag airborne routing OK")

-- OnGameSpawn tags a kind=="airborne" spawn into AirborneSquads.
Context.AirborneSquads = {}
Context.PendingSpawn = { kind = "airborne", info = { class = UnitClass.Airborne, unit = "elites_44_drop(ger)" } }
Context.SquadTimers = {}
OnGameSpawn({ squadId = 31 })
eq(Context.AirborneSquads[31], true, "OnGameSpawn tags airborne squad")
print("OnGameSpawn airborne OK")

-- DeepStrikeTrickle gate. Elapsed() == Context.GameClock; set it directly.
local spawned = {}
BotApi.Commands.Spawn = function(_, unit, size) spawned[#spawned + 1] = { unit = unit, size = size }; return true end
Context.Phases = ResolvePhases(BotApi.Instance.army)   -- ger: late after 1500s
Context.LastDeepStrikeTime = 0
Context.AirborneSquads = {}
Context.PendingSpawn = nil
Context.FailCooldown = {}

-- Not late yet (t=100): no spawn even when enemy owns everything.
BotApi.Scene.Flags = { { name = "f1", occupant = 2 }, { name = "f2", occupant = 2 } }
Context.GameClock = 100; spawned = {}; DeepStrikeTrickle()
eq(#spawned, 0, "no drop before late phase")

-- Late (t=2000) and enemy holds 100% (>65%): one drop, queued as airborne.
Context.GameClock = 2000; spawned = {}; Context.PendingSpawn = nil; Context.LastDeepStrikeTime = 0
DeepStrikeTrickle()
eq(#spawned, 1, "late + overrun -> one drop")
eq(Context.PendingSpawn.kind, "airborne", "queued as airborne")

-- Cooldown blocks an immediate second drop (LastDeepStrikeTime was just set to 2000).
spawned = {}; DeepStrikeTrickle()
eq(#spawned, 0, "cooldown blocks second drop")

-- Below threshold (enemy 50%): no drop even when late + cooldown ready.
Context.LastDeepStrikeTime = 0
Context.PendingSpawn = nil
BotApi.Scene.Flags = { { name = "f1", occupant = 2 }, { name = "f2", occupant = 1 } }
Context.GameClock = 2000; spawned = {}; DeepStrikeTrickle()
eq(#spawned, 0, "no drop below 65% threshold")
print("DeepStrikeTrickle OK")
