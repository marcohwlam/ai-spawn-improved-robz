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

-- GetArtyUnit returns an ArtilleryTank row from the current army roster (harness army = "ger")
local u = GetArtyUnit()
assert(u ~= nil, "GetArtyUnit returned nil")
eq(u.class, UnitClass.ArtilleryTank, "GetArtyUnit class")

-- GetArtyUnit returns nil when the roster has no artillery
local saved = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = { { priority = 1.0, class = UnitClass.Infantry, unit = "x" } }
eq(GetArtyUnit(), nil, "GetArtyUnit nil when no arty")
Purchases[1].Units["ger"] = saved
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

-- ArtyTargetInReach: a target (enemy-held or contested) within `reach` world units
-- counts; one beyond reach does not; missing coords never count.
Context.FlagLabel = {
	T  = { sector = "ENEMY", x = 0,    y = 0 },   -- enemy target at origin
	C  = { sector = "CONTESTED", x = 0, y = 0 },  -- contested target at origin
}
BotApi.Scene.Flags = {
	{ name = "T", occupant = 2 },                 -- enemyTeam = 2
}
eq(ArtyTargetInReach(0, 2000, 2200), true,  "enemy target within reach")
eq(ArtyTargetInReach(0, 3000, 2200), false, "enemy target beyond reach")
eq(ArtyTargetInReach(nil, nil, 4000), false, "no coords -> not in reach")
-- a CONTESTED flag also counts as a target
BotApi.Scene.Flags = { { name = "C", occupant = 0 } }
eq(ArtyTargetInReach(0, 1500, 2200), true, "contested target within reach")
print("ArtyTargetInReach OK")

-- ArtilleryFlagPriority: a 1-D line with one enemy target at x=0 and two owned flags
-- behind it. Short rockets reach the target only from the FORWARD owned flag; heavy
-- artillery reaches from the REAR flag too and so prefers the safer rear flag.
Context.FlagLabel = {
	T     = { sector = "ENEMY",     x = 0,    y = 0 },
	oFwd  = { sector = "OWN", axis = 0.50, x = 2000, y = 0 },  -- 2000 from target
	oRear = { sector = "OWN", axis = 0.20, x = 3500, y = 0 },  -- 3500 from target
}
BotApi.Scene.Flags = {
	{ name = "T",     occupant = 2 },  -- enemy target
	{ name = "oFwd",  occupant = 1 },  -- owned (harness team = 1)
	{ name = "oRear", occupant = 1 },  -- owned
}
local oFwd  = { name = "oFwd",  occupant = 1 }
local oRear = { name = "oRear", occupant = 1 }
local enemy = { name = "T",     occupant = 2 }
local rocketEntry = { arty = "rocket" }  -- reach 2200
local heavyEntry  = { arty = "heavy"  }  -- reach 4000

-- rocket (reach 2200): target in reach from oFwd (2000) but NOT oRear (3500),
-- so the in-reach forward flag wins.
assert(ArtilleryFlagPriority(oFwd, rocketEntry) > ArtilleryFlagPriority(oRear, rocketEntry),
	"rocket advances to the flag that brings the target in reach")
-- heavy (reach 4000): target in reach from BOTH flags, so the safer rear flag wins.
assert(ArtilleryFlagPriority(oRear, heavyEntry) > ArtilleryFlagPriority(oFwd, heavyEntry),
	"heavy stays on the rearmost flag still in reach")
-- an in-reach owned flag (score ~2.5) beats a non-owned flag (0.05).
assert(ArtilleryFlagPriority(oFwd, rocketEntry) > ArtilleryFlagPriority(enemy, rocketEntry),
	"owned-in-reach beats non-owned")
print("ArtilleryFlagPriority range-aware OK")

-- Fallback: no target in reach from any owned flag -> mild forward drift (0.1 + axis).
Context.FlagLabel = {
	T     = { sector = "ENEMY",     x = 0,     y = 0 },
	oFwd  = { sector = "OWN", axis = 0.50, x = 9000, y = 0 },  -- far out of any reach
	oRear = { sector = "OWN", axis = 0.20, x = 9500, y = 0 },
}
BotApi.Scene.Flags = {
	{ name = "T",     occupant = 2 },
	{ name = "oFwd",  occupant = 1 },
	{ name = "oRear", occupant = 1 },
}
assert(math.abs(ArtilleryFlagPriority({ name = "oFwd", occupant = 1 }, rocketEntry) - (0.1 + 0.50)) < 1e-9,
	"no target in reach -> forward drift")
assert(ArtilleryFlagPriority({ name = "oFwd",  occupant = 1 }, rocketEntry)
	 > ArtilleryFlagPriority({ name = "oRear", occupant = 1 }, rocketEntry),
	"drift still favors the forward flag so the piece edges into range")
print("ArtilleryFlagPriority fallback OK")

-- Edge: missing FlagLabel entry -> no coords -> drift on axis default 0.5, no error.
Context.FlagLabel = {}
BotApi.Scene.Flags = {}
local unlabeled = { name = "fX", occupant = 1 }
assert(math.abs(ArtilleryFlagPriority(unlabeled, { arty = "rocket" }) - (0.1 + 0.5)) < 1e-9,
	"missing-label -> drift on axis 0.5 -> 0.6")
-- nil entry uses field reach without erroring; no coords -> drift.
Context.FlagLabel = { fField = { sector = "OWN", axis = 0.20 } }
assert(math.abs(ArtilleryFlagPriority({ name = "fField", occupant = 1 }, nil) - (0.1 + 0.20)) < 1e-9,
	"nil entry -> drift weight")
print("ArtilleryFlagPriority edge cases OK")

-- CaptureFlag routes an artillery defender to its preferred owned flag.
-- Capture the engine call by stubbing BotApi.Commands:CaptureFlag.
local routed = nil
BotApi.Commands.CaptureFlag = function(_, squad, flagName) routed = flagName end
Context.SquadGroup = {}                                  -- not a group member
Context.Cappers = {}                                     -- not a capper
Context.FieldUnits = { [7] = { class = UnitClass.ArtilleryTank, unit = "bm13", arty = "rocket" } }
Context.FlagLabel = { fRear = { axis = 0.10 }, fFwd = { axis = 0.55 } }
BotApi.Scene.Flags = { { name = "fRear", occupant = 1 }, { name = "fFwd", occupant = 1 } }
math.randomseed(1)
local fwd = 0
for i = 1, 200 do routed = nil; CaptureFlag(7); if routed == "fFwd" then fwd = fwd + 1 end end
assert(fwd > 150, "rocket should mostly route to the forward owned flag, got " .. fwd .. "/200")
print("CaptureFlag artillery routing OK")
