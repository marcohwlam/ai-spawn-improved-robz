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
