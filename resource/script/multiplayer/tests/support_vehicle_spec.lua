dofile((arg[0]:gsub("support_vehicle_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- GetSupportVehicleUnit: only support=true Vehicle rows are candidates, and only once unlocked.
Purchases = { { Units = { ger = {
	{ priority = 1.0, class = UnitClass.Vehicle, unit = "plain_halftrack", unlock = 180 },              -- not support: never a candidate
	{ priority = 1.0, class = UnitClass.Tank,    unit = "some_tank", support = true, unlock = 0 },       -- wrong class: never a candidate
	{ priority = 1.0, class = UnitClass.Vehicle, unit = "support_early", support = true, unlock = 0 },
	{ priority = 1.0, class = UnitClass.Vehicle, unit = "support_late",  support = true, unlock = 500 },
} } } }
BotApi.Instance.army = "ger"

Context.GameClock = 0
eq(GetSupportVehicleUnit().unit, "support_early", "only the unlocked support vehicle is offered")

Context.GameClock = 500
local seen = {}
for i = 1, 20 do seen[GetSupportVehicleUnit().unit] = true end
eq(seen["support_early"], true, "support_early still eligible once support_late unlocks too")
eq(seen["support_late"], true, "support_late becomes eligible once its own unlock passes")
eq(seen["plain_halftrack"], nil, "non-support Vehicle never offered by GetSupportVehicleUnit")
eq(seen["some_tank"], nil, "non-Vehicle class never offered even with support=true")

-- GetSupportVehicleUnit returns nil when the roster has no support vehicle at all.
Purchases[1].Units["ger"] = { { priority = 1.0, class = UnitClass.Infantry, unit = "x" } }
eq(GetSupportVehicleUnit(), nil, "nil when roster has no support vehicle")

-- LiveSupportVehicleCount: counts only Vehicle-class FieldUnits entries tagged support=true.
Context.FieldUnits = {
	[1] = { class = UnitClass.Vehicle, unit = "support_early", support = true },
	[2] = { class = UnitClass.Vehicle, unit = "plain_halftrack" },              -- not support: excluded
	[3] = { class = UnitClass.Tank,    unit = "some_tank" },                    -- wrong class: excluded
	[4] = { class = UnitClass.Vehicle, unit = "support_late", support = true },
}
eq(LiveSupportVehicleCount(), 2, "LiveSupportVehicleCount counts only support=true Vehicle entries")
Context.FieldUnits = {}

print("support vehicle OK")
