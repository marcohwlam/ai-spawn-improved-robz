dofile((arg[0]:gsub("heavy_fail_slowdown_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- Late-game heavy-affordability guard: repeatedly failing to spawn a heavy tank should slow
-- down EVERY interval-gated spawn cadence for a while (IntervalMult doubles every interval,
-- a -100% rate change) so MP can bank up toward the heavy, instead of continuing to drain MP
-- at full speed on cheaper tiers while the heavy never lands. This replaced an earlier hard
-- SpawnSlotFree() pause -- the field must never go fully empty during the window, just slow
-- down. Requires trying a few DIFFERENT heavies first, not just retrying the same
-- too-expensive one -- a single unit failing 3x in a row (still under its own FailCooldown
-- each time) says nothing about whether the OTHER heavies are affordable.

local realUpdateUnitToSpawn = UpdateUnitToSpawn
UpdateUnitToSpawn = function() end -- PIter/Purchases plumbing is irrelevant to these assertions

local function setup()
	Context.FillGroup = nil
	Context.Groups = {}
	Context.PendingSpawn = nil
	Context.RatioCount = 0
	Context.AuxOwed = 0
	Context.FailCooldown = {}
	Context.ConsecutiveHeavyFails = 0
	Context.HeavyFailStreak = {}
	Context.SpawnSlowdownUntil = 0
	Context.GameClock = 1000 -- late phase (default global Phases: late is anything >= 480)
end

-- Three DISTINCT heavies failing in a row trips the slowdown.
setup()
BotApi.Commands.Spawn = function() return false end
Context.SpawnInfo = { unit = "heavyA", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnSlowdownUntil, 0, "1 distinct heavy failure: not yet slowed down")
Context.SpawnInfo = { unit = "heavyB", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnSlowdownUntil, 0, "2 distinct heavy failures: still not slowed down")
Context.SpawnInfo = { unit = "heavyC", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnSlowdownUntil, 1150, "3rd DISTINCT heavy failure trips the 150s slowdown window")
print("distinct-heavy-streak trip OK")

-- A heavy SUCCESS resets the streak.
setup()
BotApi.Commands.Spawn = function() return false end
Context.SpawnInfo = { unit = "heavyA", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
Context.SpawnInfo = { unit = "heavyB", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
BotApi.Commands.Spawn = function() return true end
Context.SpawnInfo = { unit = "heavyC", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnSlowdownUntil, 0, "a successful heavy spawn resets the streak, no slowdown")
BotApi.Commands.Spawn = function() return false end
Context.SpawnInfo = { unit = "heavyA", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
Context.SpawnInfo = { unit = "heavyB", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnSlowdownUntil, 0, "streak restarted from 1 after the earlier reset -- 2 distinct still not enough")
print("heavy success resets streak OK")

-- A roster with only ONE heavy type must still eventually trip the slowdown (fallback
-- ceiling), even though it can never reach 3 DISTINCT failures.
setup()
BotApi.Commands.Spawn = function() return false end
Context.SpawnInfo = { unit = "onlyHeavy", class = UnitClass.HeavyTank }
for i = 1, 8 do AttemptSpawn("SPAWN") end
eq(Context.SpawnSlowdownUntil, 0, "single heavy type, 8 fails: fallback ceiling (9) not reached yet")
AttemptSpawn("SPAWN")
eq(Context.SpawnSlowdownUntil, 1150, "single heavy type, 9th fail: fallback ceiling trips the slowdown")
print("single-heavy-type fallback ceiling OK")

-- Early/mid phase heavy failures never trip the slowdown (guard is late-phase only).
setup()
Context.GameClock = 100 -- early phase
BotApi.Commands.Spawn = function() return false end
for i = 1, 3 do
	Context.SpawnInfo = { unit = "heavy" .. i, class = UnitClass.HeavyTank }
	AttemptSpawn("SPAWN")
end
eq(Context.SpawnSlowdownUntil, 0, "early phase: heavy fail streak never trips the slowdown")
print("early-phase heavy fails ignored OK")

-- Non-heavy tier failures never touch the streak or slowdown.
setup()
BotApi.Commands.Spawn = function() return false end
for i = 1, 5 do
	Context.SpawnInfo = { unit = "rifle" .. i, class = UnitClass.Infantry, inf = "rifle" }
	AttemptSpawn("SPAWN")
end
eq(Context.SpawnSlowdownUntil, 0, "non-heavy tier failures never trip the heavy-fail slowdown")
print("non-heavy failures ignored OK")

UpdateUnitToSpawn = realUpdateUnitToSpawn
BotApi.Commands.Spawn = function() return true end
print("heavy fail slowdown streak-trigger OK")

-- IntervalMult: 1.0 normally, HeavyFailSlowdownMult (2.0, a -100% rate change) while the
-- window is active, back to 1.0 once it expires. Every *IntervalSec check site multiplies by
-- this -- verified here at the function level rather than re-testing every call site.
Context.GameClock = 0
Context.SpawnSlowdownUntil = 0
eq(IntervalMult(), 1.0, "no active slowdown: multiplier 1.0")
Context.SpawnSlowdownUntil = 100
Context.GameClock = 50
eq(IntervalMult(), 2.0, "inside the slowdown window: multiplier 2.0 (-100% rate change)")
Context.GameClock = 100
eq(IntervalMult(), 1.0, "exactly at the window's end: no longer active")
Context.SpawnSlowdownUntil = 0
print("IntervalMult OK")

-- Unlike the old hard pause, the slowdown window must NOT block SpawnSlotFree() outright --
-- the field should keep receiving spawns (just slower via IntervalMult at each interval
-- check), not go fully empty.
Context.PendingSpawn = nil
Context.SpawnSlowdownUntil = 1000
Context.GameClock = 0
eq(SpawnSlotFree(), true, "slowdown window active: SpawnSlotFree is still true, not a hard block")
Context.SpawnSlowdownUntil = 0
print("slowdown does not hard-block SpawnSlotFree OK")
