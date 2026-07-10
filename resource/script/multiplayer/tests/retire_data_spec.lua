dofile((arg[0]:gsub("retire_data_spec%.lua$", "harness.lua")))

local Units = Purchases[1].Units

local function find(army, id)
	for _, u in ipairs(Units[army]) do
		if u.unit == id then return u end
	end
	return nil
end

-- 1. Every listed unit carries its exact retire value.
local expected = {
	{ "ger",       "pz3_m",              950  },
	{ "ger",       "pz3n",               1300 },
	{ "ger_ss",    "pz3_m_ss",           830  },
	{ "ger_ss",    "pz3n_ss",            1300 },
	{ "ger2",      "pz3_ger2",           830  },
	{ "ger2",      "t34_2_ger",          1750 },
	{ "usa",       "m4a3_75_seq",        1120 },
	{ "rus",       "t34_2_seq",          1170 },
	{ "eng",       "cromwell_mk_iv_seq", 1130 },
	{ "rus_guard", "m4a2",               1170 },
	{ "rus_guard", "t34_2_guard",        1170 },
}
for _, e in ipairs(expected) do
	local army, id, want = e[1], e[2], e[3]
	local u = find(army, id)
	assert(u, "missing unit " .. id .. " in " .. army)
	assert(u.retire == want,
		id .. " retire expected " .. want .. " got " .. tostring(u.retire))
end

-- 2. Safety: no faction loses all its armor. For every army, at the latest retire
--    time present in its roster, at least one Tank/HeavyTank remains eligible
--    (retire nil or retire > that time).
local ARMOR = { Tank = true, HeavyTank = true }
for army, roster in pairs(Units) do
	local latest = 0
	for _, u in ipairs(roster) do
		if u.retire and u.retire > latest then latest = u.retire end
	end
	if latest > 0 then
		local survivors = 0
		for _, u in ipairs(roster) do
			local cls = (u.class == UnitClass.Tank and "Tank")
				or (u.class == UnitClass.HeavyTank and "HeavyTank") or nil
			if cls and ARMOR[cls] and (u.retire == nil or u.retire > latest) then
				survivors = survivors + 1
			end
		end
		assert(survivors > 0,
			army .. " has no armor left at its latest retire time " .. latest)
	end
end

-- 3. Japan retires nothing (no HeavyTank backup).
for _, u in ipairs(Units["jap"]) do
	assert(u.retire == nil, "jap unit " .. u.unit .. " must not retire")
end

print("retire data OK")
