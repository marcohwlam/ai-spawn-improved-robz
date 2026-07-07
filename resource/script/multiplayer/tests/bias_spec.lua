dofile((arg[0]:gsub("bias_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- FactionBias: shipped per-faction minimum-count floors, grounded in each faction's
-- real-world doctrine (see docs/superpowers/specs/2026-07-06-faction-composition-bias-design.md).
eq(FactionBias.ger.medium,      1, "ger: Blitzkrieg armor spearhead")
eq(FactionBias.ger_ss.light,    1, "ger_ss: Panzergrenadier mechanized infantry")
eq(FactionBias.ger2.rifle,      1, "ger2: Ostfront defensive infantry attrition")
eq(FactionBias.usa.artillery,   1, "usa: King of Battle")
eq(FactionBias.rus.smg,         1, "rus: PPSh assault infantry waves")
eq(FactionBias.rus_guard.heavy, 1, "rus_guard: Guards' first pick of heavy armor")
eq(FactionBias.jap.mortar,      1, "jap: infiltration doctrine, light infantry weapons")
eq(FactionBias.eng.artillery,   1, "eng: colossal cracks artillery preparation")
print("FactionBias data OK")
