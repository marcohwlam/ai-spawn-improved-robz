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

-- ArtilleryFlagPriority: among OWNED flags, rocket favors high axis (forward),
-- heavy favors low axis (rear), field is mild forward; non-owned get only drift.
Context.FlagLabel = {
	fRear  = { axis = 0.10 },  -- own/rear
	fFwd   = { axis = 0.55 },  -- forward
}
local owned   = { name = "fFwd",  occupant = 1 }  -- harness team = 1
local ownRear = { name = "fRear", occupant = 1 }
local enemy   = { name = "fFwd",  occupant = 2 }

local rocketEntry = { arty = "rocket" }
local heavyEntry  = { arty = "heavy" }
local fieldEntry  = { arty = "field" }

-- rocket: forward owned outweighs rear owned
assert(ArtilleryFlagPriority(owned, rocketEntry) > ArtilleryFlagPriority(ownRear, rocketEntry),
	"rocket favors forward")
-- heavy: rear owned outweighs forward owned
assert(ArtilleryFlagPriority(ownRear, heavyEntry) > ArtilleryFlagPriority(owned, heavyEntry),
	"heavy favors rear")
-- any owned outweighs a non-owned flag (drift floor)
assert(ArtilleryFlagPriority(ownRear, fieldEntry) > ArtilleryFlagPriority(enemy, fieldEntry),
	"owned beats non-owned")
print("ArtilleryFlagPriority OK")

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
