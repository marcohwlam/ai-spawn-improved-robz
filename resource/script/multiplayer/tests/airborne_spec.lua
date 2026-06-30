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
