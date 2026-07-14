dofile((arg[0]:gsub("phase_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- TierOf
eq(TierOf({class = UnitClass.Infantry, inf = "rifle"}), "rifle", "rifle inf is rifle")
eq(TierOf({class = UnitClass.Infantry, inf = "smg"}),   "smg",   "smg inf is smg")
eq(TierOf({class = UnitClass.Infantry, mech = true, inf = "smg"}), "smg",
	"mech infantry is still infantry, not armor -- must not share the light (armor) bucket")
eq(TierOf({class = UnitClass.Infantry}), "rifle", "plain inf defaults to rifle")
eq(TierOf({class = UnitClass.Infantry, flame = true}), nil, "flamer is aux")
eq(TierOf({class = UnitClass.Tank, weight = "light"}),  "light",  "light tank")
eq(TierOf({class = UnitClass.Tank}),                    "light",  "no weight defaults light")
eq(TierOf({class = UnitClass.Tank, weight = "medium"}), "medium", "medium tank")
eq(TierOf({class = UnitClass.Tank, weight = "heavy"}),  "heavy",  "heavy-tonnage tank (e.g. kv1)")
eq(TierOf({class = UnitClass.Tank, weight = "sheavy"}), "heavy",  "super-heavy-tonnage tank")
eq(TierOf({class = UnitClass.HeavyTank, recharge = 2160}), "heavy", "tiger heavy")
eq(TierOf({class = UnitClass.Vehicle, recharge = 30}), "light", "halftrack light")
eq(TierOf({class = UnitClass.Infantry, mech = true}), "rifle",
	"mech inf with no inf= field falls through to rifle, same as any other plain infantry")
eq(TierOf({class = UnitClass.ATInfantry}), nil, "AT is aux")
eq(TierOf({class = UnitClass.MG}), nil, "MG is aux")
eq(TierOf({class = UnitClass.Vehicle, support = true}), nil,
	"support=true vehicle (early ger halftrack) is aux, not light -- must not crowd out pz2l")
eq(TierOf({class = UnitClass.Tank, weight = "light"}), "light",
	"a real light tank is unaffected by the support-vehicle carve-out")
print("TierOf OK")

-- CurrentPhase
eq(CurrentPhase(0).name,   "early", "t0 early")
eq(CurrentPhase(179).name, "early", "179 early")
eq(CurrentPhase(180).name, "mid",   "180 mid")
eq(CurrentPhase(479).name, "mid",   "479 mid")
eq(CurrentPhase(480).name, "late",  "480 late")
eq(CurrentPhase(99999).name, "late","late stays late")

-- Per-phase group sizes (main prong / sub prong scale up through the game).
eq(CurrentPhase(0).mainGroup,   4, "early main 4")
eq(CurrentPhase(0).subGroup,    3, "early sub 3")
eq(CurrentPhase(180).mainGroup, 5, "mid main 5")
eq(CurrentPhase(180).subGroup,  4, "mid sub 4")
eq(CurrentPhase(480).mainGroup, 6, "late main 6")
eq(CurrentPhase(480).subGroup,  4, "late sub 4")

-- DecideTier: late composition (heavy 1, medium 2, light 2, rifle 1, smg 1; totalT 7 ->
-- light share 2/7, medium 2/7, every other tier 1/7). light and medium tie on target share;
-- an empty field resolves the tie via `targets` table iteration order (light first).
local late = CurrentPhase(480)
local allOk = { heavy = true, medium = true, light = true, rifle = true, smg = true }

-- Empty field: light and medium tie for the largest target share (2/7 each) -> either may
-- win depending on table iteration order; heavy/rifle/smg must still lose out.
local empty = { heavy = 0, medium = 0, light = 0, rifle = 0, smg = 0, aux = 0 }
local emptyPick = DecideTier(late, empty, false, allOk)
assert(emptyPick == "light" or emptyPick == "medium",
	"light/medium tie dominates an empty field, got " .. tostring(emptyPick))

-- Only rifle eligible (tanks on cooldown) -> rifle fallback.
eq(DecideTier(late, empty, false, { rifle = true }), "rifle", "fallback to eligible tier")

-- Light already filled + enemy tanks: the medium/heavy bump (+0.15) wins over the now-
-- satisfied light, leaning armor.
local lightFilled = { heavy = 0, medium = 0, light = 3, rifle = 0, smg = 0, aux = 0 }
local pick = DecideTier(late, lightFilled, true, allOk)
assert(pick == "medium" or pick == "heavy", "enemy tanks leans armor, got " .. tostring(pick))

-- Light already filled + losing: smg weight is bumped to 2, tying medium's own
-- target weight of 2 in late (heavy1/medium2/light2/rifle1/smg2) -> either may win
-- depending on table iteration order; light/heavy/rifle must still lose out.
local losingPick = DecideTier(late, lightFilled, false, allOk, true)
assert(losingPick == "smg" or losingPick == "medium",
	"losing smg bump ties medium, got " .. tostring(losingPick))

-- DecideTier: smg under-filled -> picks smg over rifle and light
-- Early targets are light=3, rifle=3, smg=1 (totalT 7); fill light and rifle to their
-- equal 3/7 shares so smg (1/7, still empty) is strictly the most under-filled.
local fRifled = { heavy = 0, medium = 0, light = 3, rifle = 3, smg = 0, aux = 0 }
local earlyOk = { light = true, rifle = true, smg = true }
local early = CurrentPhase(0)
eq(DecideTier(early, fRifled, false, earlyOk), "smg", "smg picked when rifle and light filled and smg empty")

-- DecideTier: losing bumps smg weight to 2 (totalT 8: light3/rifle3/smg2); with light and
-- rifle filled to their now-equal 3/8 shares, smg's 2/8 target is the largest deficit.
local fLosing = { heavy = 0, medium = 0, light = 3, rifle = 3, smg = 0, aux = 0 }
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
eq(ger[3].targets.heavy, 1, "ger late targets: heavy present")
eq(ger[3].targets.medium, 1, "ger late targets: medium trimmed to 1 via lateTargets (global is 2)")

local usa = ResolvePhases("usa")
eq(usa[1].upto, 530,  "usa early ends at 530")
eq(usa[2].upto, 1200, "usa mid ends at 1200")

-- eng: first heavy (820) is below first medium (750) + 300 floor, so floor governs.
local eng = ResolvePhases("eng")
eq(eng[2].upto, 1050, "eng mid->late uses the 300s floor (1050), not 820")

-- jap: no heavy tier -> late targets drop heavy and boost medium.
local jap = ResolvePhases("jap")
eq(jap[1].upto, 580,  "jap early ends at 580")
eq(jap[2].upto, 1270, "jap mid ends at chi-to 1270")
eq(jap[3].targets.heavy,  nil, "jap late has no heavy target")
eq(jap[3].targets.medium, 2,   "jap late medium boosted to 2")

-- unknown faction -> global Phases table (identity fallback).
assert(ResolvePhases("nonexistent") == Phases, "unknown army returns the global Phases table")
print("ResolvePhases OK")

-- CurrentPhase reads Context.Phases when set, falls back to global Phases when nil.
Context.Phases = ResolvePhases("jap")
eq(CurrentPhase(500).name,  "early", "jap 500 is early (< 580)")
eq(CurrentPhase(600).name,  "mid",   "jap 600 is mid (>= 580, < 1270)")
eq(CurrentPhase(1400).name, "late",  "jap 1400 is late (>= 1270)")
Context.Phases = nil
eq(CurrentPhase(180).name, "mid", "fallback to global Phases when Context.Phases is nil")
print("CurrentPhase faction OK")

-- FlagWinPct: (our share - enemy share) of all flags, in [-1,1], 0 when empty.
BotApi.Scene.Flags = {}
eq(FlagWinPct(), 0, "no flags -> 0")
BotApi.Scene.Flags = {
	{ name = "f1", occupant = 1 }, { name = "f2", occupant = 1 },
	{ name = "f3", occupant = 1 }, { name = "f4", occupant = 2 },
}
eq(FlagWinPct(), 0.5, "3 ours, 1 enemy of 4 -> (3-1)/4 = 0.5")
BotApi.Scene.Flags = {
	{ name = "f1", occupant = 2 }, { name = "f2", occupant = 2 },
	{ name = "f3", occupant = 2 }, { name = "f4", occupant = 1 },
}
eq(FlagWinPct(), -0.5, "1 ours, 3 enemy of 4 -> (1-3)/4 = -0.5")
BotApi.Scene.Flags = {
	{ name = "f1", occupant = 0 }, { name = "f2", occupant = 0 },
}
eq(FlagWinPct(), 0, "all neutral -> 0")
print("FlagWinPct OK")

-- WaveIntervalNow: symmetric around the phase-scaled base -- winning (positive FlagWinPct)
-- lengthens the gap, losing (negative) shortens it, floored at MinWaveIntervalSec.
Context.Phases = nil
BotApi.Scene.Flags = {}
Context.GameClock = 0 -- early phase, waveMult 1.0 -> base = WaveIntervalSec
eq(WaveIntervalNow(), WaveIntervalSec, "even (0 flags): base gap, unscaled")

BotApi.Scene.Flags = {
	{ name = "f1", occupant = 1 }, { name = "f2", occupant = 1 }, { name = "f3", occupant = 2 },
}
-- winPct = (2-1)/3 = 1/3 -> base * (1 + 1/3)
eq(WaveIntervalNow(), math.floor(WaveIntervalSec * (1 + 1/3)), "winning 1/3 lengthens the gap")

BotApi.Scene.Flags = {
	{ name = "f1", occupant = 2 }, { name = "f2", occupant = 2 }, { name = "f3", occupant = 1 },
}
-- winPct = (1-2)/3 = -1/3 -> base * (1 - 1/3)
eq(WaveIntervalNow(), math.floor(WaveIntervalSec * (1 - 1/3)), "losing 1/3 shortens the gap")

BotApi.Scene.Flags = {
	{ name = "f1", occupant = 2 }, { name = "f2", occupant = 2 }, { name = "f3", occupant = 2 },
	{ name = "f4", occupant = 2 },
} -- winPct = (0-4)/4 = -1 -> base * 0 = 0, floored at MinWaveIntervalSec
eq(WaveIntervalNow(), MinWaveIntervalSec, "losing every flag floors at MinWaveIntervalSec")
BotApi.Scene.Flags = {}
print("WaveIntervalNow OK")
