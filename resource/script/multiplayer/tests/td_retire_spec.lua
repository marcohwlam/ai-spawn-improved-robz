dofile((arg[0]:gsub("td_retire_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- GetAtTankUnit must honor `retire` symmetrically to `unlock`: a TD is a candidate only
-- while unlock <= elapsed < retire.
local saved = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 1.0, class = UnitClass.ATTank, unit = "td_perm",     unlock = 0 },              -- no retire
	{ priority = 1.0, class = UnitClass.ATTank, unit = "td_retiring", unlock = 0, retire = 1000 },
}
BotApi.Instance.army = "ger"
Context.FieldUnits = {}

-- One second before retire: both are reachable.
Context.GameClock = 999
local before = {}
for i = 1, 200 do before[GetAtTankUnit().unit] = true end
eq(before["td_perm"], true, "no-retire TD offered before boundary")
eq(before["td_retiring"], true, "retiring TD still offered one second before retire")

-- At the retire boundary: retiring TD gone, only the permanent one remains.
Context.GameClock = 1000
local at = {}
for i = 1, 200 do at[GetAtTankUnit().unit] = true end
eq(at["td_perm"], true, "no-retire TD still offered at boundary")
eq(at["td_retiring"], nil, "retiring TD must NOT be offered at its retire time")

-- Retiring the only remaining TD yields nil (no candidates).
Purchases[1].Units["ger"] = {
	{ priority = 1.0, class = UnitClass.ATTank, unit = "solo", unlock = 0, retire = 500 },
}
Context.GameClock = 500
eq(GetAtTankUnit(), nil, "GetAtTankUnit nil when every ATTank is retired")

Purchases[1].Units["ger"] = saved
print("td retire OK")
