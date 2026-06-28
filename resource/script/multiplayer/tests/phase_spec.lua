dofile((arg[0]:gsub("phase_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- TierOf
eq(TierOf({class = UnitClass.Infantry}), "infantry", "rifle is infantry")
eq(TierOf({class = UnitClass.Infantry, flame = true}), nil, "flamer is aux")
eq(TierOf({class = UnitClass.Tank, recharge = 420}), "light", "pz2l light")
eq(TierOf({class = UnitClass.Tank, recharge = 550}), "medium", "550 is medium")
eq(TierOf({class = UnitClass.Tank, recharge = 950}), "medium", "pz4h medium")
eq(TierOf({class = UnitClass.HeavyTank, recharge = 2160}), "heavy", "tiger heavy")
eq(TierOf({class = UnitClass.Vehicle, recharge = 30}), "light", "halftrack light")
eq(TierOf({class = UnitClass.ATInfantry}), nil, "AT is aux")
eq(TierOf({class = UnitClass.MG}), nil, "MG is aux")
print("TierOf OK")

-- CurrentPhase
eq(CurrentPhase(0).name,   "early", "t0 early")
eq(CurrentPhase(179).name, "early", "179 early")
eq(CurrentPhase(180).name, "mid",   "180 mid")
eq(CurrentPhase(479).name, "mid",   "479 mid")
eq(CurrentPhase(480).name, "late",  "480 late")
eq(CurrentPhase(99999).name, "late","late stays late")

-- DecideTier: empty field, all eligible -> infantry has the largest absolute deficit
local late = CurrentPhase(480)
local empty = { heavy = 0, medium = 0, light = 0, infantry = 0, aux = 0 }
local allOk = { heavy = true, medium = true, light = true, infantry = true }
eq(DecideTier(late, empty, false, allOk), "infantry", "empty field wants infantry first")

-- DecideTier: infantry satisfied -> next deficit is light (weight 2)
local f2 = { heavy = 0, medium = 0, light = 0, infantry = 4, aux = 0 }
eq(DecideTier(late, f2, false, allOk), "light", "after infantry, light")

-- DecideTier: only infantry eligible (tanks on cooldown) -> infantry
eq(DecideTier(late, f2, false, { infantry = true }), "infantry", "fallback to eligible tier")

-- DecideTier: enemy tanks bumps medium/heavy deficit
local f3 = { heavy = 1, medium = 1, light = 2, infantry = 4, aux = 0 }
local pick = DecideTier(late, f3, true, allOk)
assert(pick == "medium" or pick == "heavy", "enemy tanks leans armor, got " .. tostring(pick))
print("phase OK")
