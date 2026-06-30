dofile((arg[0]:gsub("phase_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- TierOf
eq(TierOf({class = UnitClass.Infantry, inf = "rifle"}), "rifle", "rifle inf is rifle")
eq(TierOf({class = UnitClass.Infantry, inf = "smg"}),   "smg",   "smg inf is smg")
eq(TierOf({class = UnitClass.Infantry, mech = true, inf = "smg"}), "light", "mech smg is light")
eq(TierOf({class = UnitClass.Infantry}), "rifle", "plain inf defaults to rifle")
eq(TierOf({class = UnitClass.Infantry, flame = true}), nil, "flamer is aux")
eq(TierOf({class = UnitClass.Tank, weight = "light"}),  "light",  "light tank")
eq(TierOf({class = UnitClass.Tank}),                    "light",  "no weight defaults light")
eq(TierOf({class = UnitClass.Tank, weight = "medium"}), "medium", "medium tank")
eq(TierOf({class = UnitClass.Tank, weight = "heavy"}),  "heavy",  "heavy-tonnage tank (e.g. kv1)")
eq(TierOf({class = UnitClass.Tank, weight = "sheavy"}), "heavy",  "super-heavy-tonnage tank")
eq(TierOf({class = UnitClass.HeavyTank, recharge = 2160}), "heavy", "tiger heavy")
eq(TierOf({class = UnitClass.Vehicle, recharge = 30}), "light", "halftrack light")
eq(TierOf({class = UnitClass.Infantry, mech = true}), "light", "mech inf is light")
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

-- DecideTier: late composition is light-dominant (heavy 1, medium 1, light 3, rifle 1,
-- smg 1; totalT 7 -> light share 3/7, every other tier 1/7).
local late = CurrentPhase(480)
local allOk = { heavy = true, medium = true, light = true, rifle = true, smg = true }

-- Empty field: light has the largest target share -> picked first.
local empty = { heavy = 0, medium = 0, light = 0, rifle = 0, smg = 0, aux = 0 }
eq(DecideTier(late, empty, false, allOk), "light", "light dominates an empty field")

-- Only rifle eligible (tanks on cooldown) -> rifle fallback.
eq(DecideTier(late, empty, false, { rifle = true }), "rifle", "fallback to eligible tier")

-- Light already filled + enemy tanks: the medium/heavy bump (+0.15) wins over the now-
-- satisfied light, leaning armor.
local lightFilled = { heavy = 0, medium = 0, light = 3, rifle = 0, smg = 0, aux = 0 }
local pick = DecideTier(late, lightFilled, true, allOk)
assert(pick == "medium" or pick == "heavy", "enemy tanks leans armor, got " .. tostring(pick))

-- Light already filled + losing: smg weight is bumped to 2 (> every non-light tier),
-- so smg has the largest remaining deficit.
eq(DecideTier(late, lightFilled, false, allOk, true), "smg", "losing smg bump picks smg")

-- DecideTier: smg under-filled -> picks smg over rifle and light
-- Use light=1 so smg is strictly more under-filled (avoids tie with light).
local fRifled = { heavy = 0, medium = 0, light = 1, rifle = 3, smg = 0, aux = 0 }
local earlyOk = { light = true, rifle = true, smg = true }
local early = CurrentPhase(0)
eq(DecideTier(early, fRifled, false, earlyOk), "smg", "smg picked when rifle and light filled and smg empty")

-- DecideTier: losing bumps smg weight to 2; smg under-filled -> picks smg
local fLosing = { heavy = 0, medium = 0, light = 0, rifle = 3, smg = 0, aux = 0 }
eq(DecideTier(early, fLosing, false, earlyOk, true), "smg", "losing smg bump picks smg")
print("phase OK")

-- Group helpers: elite flag is orthogonal to tier, and empty-group helpers return zero.
eq(TierOf({class = UnitClass.Infantry, inf = "rifle", elite = true}), "rifle", "elite rifle still rifle tier")
eq(TierOf({class = UnitClass.Infantry, inf = "smg",   elite = true}), "smg",   "elite smg still smg tier")
assert(type(GroupMemberCount) == "function", "GroupMemberCount defined")
assert(type(GroupEliteCount)  == "function", "GroupEliteCount defined")
assert(type(ManageGroups)     == "function", "ManageGroups defined")
assert(type(GroupToFill)      == "function", "GroupToFill defined")
assert(type(CompactGroups)    == "function", "CompactGroups defined")
local emptyGroup = { members = {}, size = 8 }
eq(GroupMemberCount(emptyGroup), 0, "GroupMemberCount empty=0")
eq(GroupEliteCount(emptyGroup),  0, "GroupEliteCount empty=0")
print("group helpers OK")

-- PickGroupTarget: enemy-only, excludeName respected, nil when no enemies
do
	local savedFlags = BotApi.Scene.Flags
	local savedInst  = BotApi.Instance
	BotApi.Instance = { team = 1, enemyTeam = 2, army = "ger", teamSize = 8, hostId = 1, playerId = 1 }
	BotApi.Scene.Flags = {
		{ name = "alpha",   occupant = 2 },  -- enemy
		{ name = "bravo",   occupant = 2 },  -- enemy
		{ name = "neutral", occupant = 3 },  -- neutral (occupant ~= 1 and ~= 2)
		{ name = "owned",   occupant = 1 },  -- ours
	}
	local t = PickGroupTarget(nil)
	assert(t == "alpha" or t == "bravo",
		"PickGroupTarget returns an enemy flag, got " .. tostring(t))

	-- excludeName: when alpha is excluded, only bravo is a valid enemy
	local t2 = PickGroupTarget("alpha")
	eq(t2, "bravo", "PickGroupTarget excludes alpha")

	-- No enemy flags -> nil
	BotApi.Scene.Flags = {
		{ name = "neutral", occupant = 3 },
		{ name = "owned",   occupant = 1 },
	}
	local t3 = PickGroupTarget(nil)
	eq(t3, nil, "PickGroupTarget returns nil when no enemy flags")

	BotApi.Scene.Flags = savedFlags
	BotApi.Instance    = savedInst
end
print("PickGroupTarget OK")

-- ResolvePhases: per-faction boundaries; budget/waveMult/squadCap stay global.
local ger = ResolvePhases("ger")
eq(ger[1].name, "early", "ger p1 is early")
eq(ger[1].upto, 630,        "ger early ends at first medium 630")
eq(ger[2].upto, 1500,       "ger mid ends at first heavy 1500")
eq(ger[3].upto, 1000000000, "ger late is open-ended")
eq(ger[1].budget,   Phases[1].budget,   "ger early budget shared with global")
eq(ger[2].waveMult, Phases[2].waveMult, "ger mid waveMult shared with global")
eq(ger[3].squadCap, Phases[3].squadCap, "ger late squadCap shared with global")
eq(ger[3].targets.heavy, 1, "ger keeps global late targets (heavy present)")

local usa = ResolvePhases("usa")
eq(usa[1].upto, 530,  "usa early ends at 530")
eq(usa[2].upto, 1200, "usa mid ends at 1200")

-- eng: first heavy (820) is below first medium (750) + 300 floor, so floor governs.
local eng = ResolvePhases("eng")
eq(eng[2].upto, 1050, "eng mid->late uses the 300s floor (1050), not 820")

-- jap: no heavy tier -> late targets drop heavy and boost medium.
local jap = ResolvePhases("jap")
eq(jap[1].upto, 580,  "jap early ends at 580")
eq(jap[2].upto, 1380, "jap mid ends at chi-to 1380")
eq(jap[3].targets.heavy,  nil, "jap late has no heavy target")
eq(jap[3].targets.medium, 2,   "jap late medium boosted to 2")

-- unknown faction -> global Phases table (identity fallback).
assert(ResolvePhases("nonexistent") == Phases, "unknown army returns the global Phases table")
print("ResolvePhases OK")

-- CurrentPhase reads Context.Phases when set, falls back to global Phases when nil.
Context.Phases = ResolvePhases("jap")
eq(CurrentPhase(500).name,  "early", "jap 500 is early (< 580)")
eq(CurrentPhase(600).name,  "mid",   "jap 600 is mid (>= 580, < 1380)")
eq(CurrentPhase(1400).name, "late",  "jap 1400 is late (>= 1380)")
Context.Phases = nil
eq(CurrentPhase(180).name, "mid", "fallback to global Phases when Context.Phases is nil")
print("CurrentPhase faction OK")
