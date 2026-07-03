dofile((arg[0]:gsub("arty_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- LiveArtyCount counts only ArtilleryTank entries in FieldUnits
Context.FieldUnits = {
	[1] = { class = UnitClass.ArtilleryTank, unit = "wespe" },
	[2] = { class = UnitClass.MG, unit = "mgs2(ger)" },
	[3] = { class = UnitClass.ArtilleryTank, unit = "hummel" },
}
eq(LiveArtyCount(), 2, "LiveArtyCount")

-- GetArtyUnit returns an ArtilleryTank row from the current army roster (harness army = "ger").
-- All of ger's arty subtypes unlock at 900/1200s, so past-unlock elapsed time is required.
Context.FieldUnits = {}
Context.GameClock = 1200
local u = GetArtyUnit()
assert(u ~= nil, "GetArtyUnit returned nil")
eq(u.class, UnitClass.ArtilleryTank, "GetArtyUnit class")

-- GetArtyUnit returns nil when the roster has no artillery
local saved = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = { { priority = 1.0, class = UnitClass.Infantry, unit = "x" } }
eq(GetArtyUnit(), nil, "GetArtyUnit nil when no arty")
Purchases[1].Units["ger"] = saved

-- GetArtyUnit is unlock-aware: before any subtype's unlock time, no candidate is eligible
-- (the ARTY trickle used to call this blind, wasting attempts on units the engine would
-- reject and, more importantly, letting an early-unlocking subtype win the priority pick
-- purely because a later-unlocking one wasn't excluded from consideration yet).
Context.GameClock = 0
eq(GetArtyUnit(), nil, "GetArtyUnit nil before any subtype unlocks")

-- Only wespe (unlock=900) is eligible at t=900; hummel/sdkfz4 (unlock=1200) are not yet.
Context.GameClock = 900
eq(GetArtyUnit().unit, "wespe", "GetArtyUnit only offers the unlocked subtype")

-- GetArtyUnit excludes a subtype already fielded live, so the ArtyCap>1 slack goes toward a
-- DIFFERENT subtype instead of a duplicate of whatever already won the last pick -- this is
-- what lets a low-priority, late-unlocking subtype (e.g. sdkfz4, the rocket halftrack) ever
-- get picked once wespe has already claimed a slot and survives for the rest of the match.
Context.GameClock = 1200
Context.FieldUnits = { [1] = { class = UnitClass.ArtilleryTank, unit = "wespe" } }
local picks = {}
for i = 1, 1, 1 do picks[GetArtyUnit().unit] = true end
eq(picks["wespe"], nil, "already-fielded subtype excluded from GetArtyUnit's pool")

Context.FieldUnits = { [1] = { class = UnitClass.ArtilleryTank, unit = "wespe" },
                        [2] = { class = UnitClass.ArtilleryTank, unit = "hummel" } }
eq(GetArtyUnit().unit, "sdkfz4", "only the un-fielded subtype remains once the other two are live")
Context.FieldUnits = {}
print("arty spawn helpers OK")

-- Trickle gate: a small re-implementation mirror would duplicate logic, so assert the
-- pieces the gate depends on instead. The gate spawns only when:
--   elapsed since LastArtyTime >= ArtyIntervalSec, phase ~= early, HeldFlagCount > 0, LiveArtyCount < ArtyCap.
-- Verify cap blocks at 1:
Context.FieldUnits = { [1] = { class = UnitClass.ArtilleryTank, unit = "wespe" } }
assert(LiveArtyCount() >= 1, "cap precondition")
-- Verify HeldFlagCount reflects owned flags (occupant == team). harness team = 1.
BotApi.Scene.Flags = { { name = "f1", occupant = 1 }, { name = "f2", occupant = 2 } }
eq(HeldFlagCount(), 1, "HeldFlagCount owned only")
print("arty trickle gate OK")

-- ArtyNearestTarget: distance to the nearest enemy-held or contested flag; nil when
-- there are no targets or no coords.
Context.FlagLabel = {
	T  = { sector = "ENEMY",     x = 0,    y = 0 },  -- enemy target at origin
	C  = { sector = "CONTESTED", x = 0,    y = 800 },
}
BotApi.Scene.Flags = { { name = "T", occupant = 2 } }    -- enemyTeam = 2
eq(ArtyNearestTarget(0, 2000), 2000, "nearest enemy target distance")
eq(ArtyNearestTarget(nil, nil), nil, "no coords -> nil")
BotApi.Scene.Flags = { { name = "T", occupant = 2 }, { name = "C", occupant = 0 } }
eq(ArtyNearestTarget(0, 2000), 1200, "contested counts; nearest of the two wins")
BotApi.Scene.Flags = {}
eq(ArtyNearestTarget(0, 2000), nil, "no targets present -> nil")
print("ArtyNearestTarget OK")

-- ArtilleryFlagPriority: a 1-D line with one enemy target at x=0 and owned flags behind
-- it. A flag qualifies only when its nearest target is in [ArtySafeMin=1500, reach]:
--   oClose @1200 -> too close (< SafeMin), always 0
--   oMid   @2000 -> in band for rocket (<=2200) and heavy
--   oFar   @3500 -> out of range for rocket (>2200) but in band for heavy (<=4000)
Context.FlagLabel = {
	T      = { sector = "ENEMY",     x = 0,    y = 0 },
	oClose = { sector = "OWN", axis = 0.60, x = 1200, y = 0 },
	oMid   = { sector = "OWN", axis = 0.45, x = 2000, y = 0 },
	oFar   = { sector = "OWN", axis = 0.20, x = 3500, y = 0 },
}
BotApi.Scene.Flags = {
	{ name = "T",      occupant = 2 },
	{ name = "oClose", occupant = 1 },  -- owned (harness team = 1)
	{ name = "oMid",   occupant = 1 },
	{ name = "oFar",   occupant = 1 },
}
local oClose = { name = "oClose", occupant = 1 }
local oMid   = { name = "oMid",   occupant = 1 }
local oFar   = { name = "oFar",   occupant = 1 }
local enemy  = { name = "T",      occupant = 2 }
local rocketEntry = { arty = "rocket" }  -- reach 2200
local heavyEntry  = { arty = "heavy"  }  -- reach 4000

eq(ArtilleryFlagPriority(oClose, rocketEntry), 0, "too close (< SafeMin) -> 0")
eq(ArtilleryFlagPriority(oClose, heavyEntry),  0, "too close -> 0 for heavy too")
eq(ArtilleryFlagPriority(oFar,   rocketEntry), 0, "out of rocket range -> 0")
eq(ArtilleryFlagPriority(enemy,  rocketEntry), 0, "non-owned flag -> 0")
assert(ArtilleryFlagPriority(oMid, rocketEntry) > 0, "rocket qualifies from oMid")
-- heavy: oMid and oFar both in band; rearmost (lower axis) scores higher.
assert(ArtilleryFlagPriority(oFar, heavyEntry) > ArtilleryFlagPriority(oMid, heavyEntry),
	"heavy prefers the rearmost flag still in its safe band")
print("ArtilleryFlagPriority safe-band OK")

-- ArtilleryTargetFlag: rocket -> the only qualifying flag (oMid); heavy -> the rearmost
-- qualifying flag (oFar).
eq(ArtilleryTargetFlag(rocketEntry), "oMid", "rocket holds the single in-band flag")
eq(ArtilleryTargetFlag(heavyEntry),  "oFar", "heavy holds the rearmost in-band flag")

-- No qualifying flag -> nil (park at base). Push the only owned flag inside SafeMin.
Context.FlagLabel = {
	T      = { sector = "ENEMY",     x = 0,    y = 0 },
	oClose = { sector = "OWN", axis = 0.60, x = 1000, y = 0 },  -- 1000 < SafeMin
}
BotApi.Scene.Flags = {
	{ name = "T",      occupant = 2 },
	{ name = "oClose", occupant = 1 },
}
eq(ArtilleryTargetFlag(rocketEntry), nil, "all flags too exposed -> park (nil)")
print("ArtilleryTargetFlag OK")

-- Edge: missing FlagLabel / nil entry never error and never qualify (no coords).
Context.FlagLabel = {}
BotApi.Scene.Flags = {}
eq(ArtilleryFlagPriority({ name = "fX", occupant = 1 }, rocketEntry), 0, "missing label -> 0")
Context.FlagLabel = { fField = { sector = "OWN", axis = 0.20 } }  -- no coords
eq(ArtilleryFlagPriority({ name = "fField", occupant = 1 }, nil), 0, "no coords -> 0")
print("ArtilleryFlagPriority edge cases OK")

-- CaptureFlag routes an artillery defender to its in-band flag, and issues NO order when
-- every held flag is too exposed (the piece stays parked at base).
local routed = nil
BotApi.Commands.CaptureFlag = function(_, squad, flagName) routed = flagName end
Context.SquadGroup = {}                                  -- not a group member
Context.Cappers = {}                                     -- not a capper
Context.FieldUnits = { [7] = { class = UnitClass.ArtilleryTank, unit = "bm13", arty = "rocket" } }
Context.FlagLabel = {
	T     = { sector = "ENEMY",     x = 0,    y = 0 },
	oMid  = { sector = "OWN", axis = 0.45, x = 2000, y = 0 },  -- in band for rocket
}
BotApi.Scene.Flags = { { name = "T", occupant = 2 }, { name = "oMid", occupant = 1 } }
routed = nil; CaptureFlag(7)
eq(routed, "oMid", "artillery routes to its safe-band flag")
-- now make the only owned flag too close: expect no order issued.
Context.FlagLabel = {
	T     = { sector = "ENEMY",     x = 0,    y = 0 },
	oNear = { sector = "OWN", axis = 0.55, x = 900, y = 0 },   -- < SafeMin
}
BotApi.Scene.Flags = { { name = "T", occupant = 2 }, { name = "oNear", occupant = 1 } }
routed = "UNSET"; CaptureFlag(7)
eq(routed, "UNSET", "artillery issues no order when no flag is safe -> parks at base")
print("CaptureFlag artillery routing OK")
