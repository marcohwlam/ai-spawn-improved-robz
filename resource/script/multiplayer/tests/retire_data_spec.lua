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

-- 2. Safety: the medium-weight tank tier is never emptied at any retire boundary.
--    A HeavyTank surviving at time T proves nothing about the medium tier (no
--    HeavyTank ever carries `retire`), so checking Tank+HeavyTank together at only
--    the single latest retire time hides the real risk: a boundary where every
--    medium tank has retired. Instead, for every army and for EACH distinct
--    `retire` value T present in that army's roster, assert at least one
--    weight=="medium" Tank remains eligible at T (retire nil or retire > T).
for army, roster in pairs(Units) do
	local retireTimes = {}
	for _, u in ipairs(roster) do
		if u.retire then retireTimes[u.retire] = true end
	end
	for t in pairs(retireTimes) do
		local survivors = 0
		for _, u in ipairs(roster) do
			if u.class == UnitClass.Tank and u.weight == "medium"
				and (u.retire == nil or u.retire > t) then
				survivors = survivors + 1
			end
		end
		assert(survivors > 0,
			army .. " has no medium tank left at retire time " .. t)
	end
end

-- 3. Japan retires nothing (no HeavyTank backup).
for _, u in ipairs(Units["jap"]) do
	assert(u.retire == nil, "jap unit " .. u.unit .. " must not retire")
end

print("retire data OK")
