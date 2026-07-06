dofile((arg[0]:gsub("heavy_fail_pause_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- Late-game heavy-affordability guard: repeatedly failing to spawn a heavy tank should pause
-- ALL spawning for a while so MP can bank up, instead of continuing to drain MP on cheaper
-- tiers while the heavy never lands. Requires trying a few DIFFERENT heavies first, not just
-- retrying the same too-expensive one -- a single unit failing 3x in a row (still under its
-- own FailCooldown each time) says nothing about whether the OTHER heavies are affordable.

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
	Context.SpawnPauseUntil = 0
	Context.GameClock = 1000 -- late phase (default global Phases: late is anything >= 480)
end

-- Three DISTINCT heavies failing in a row trips the pause.
setup()
BotApi.Commands.Spawn = function() return false end
Context.SpawnInfo = { unit = "heavyA", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnPauseUntil, 0, "1 distinct heavy failure: not yet paused")
Context.SpawnInfo = { unit = "heavyB", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnPauseUntil, 0, "2 distinct heavy failures: still not paused")
Context.SpawnInfo = { unit = "heavyC", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnPauseUntil, 1150, "3rd DISTINCT heavy failure trips the 150s pause")
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
eq(Context.SpawnPauseUntil, 0, "a successful heavy spawn resets the streak, no pause")
BotApi.Commands.Spawn = function() return false end
Context.SpawnInfo = { unit = "heavyA", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
Context.SpawnInfo = { unit = "heavyB", class = UnitClass.HeavyTank }
AttemptSpawn("SPAWN")
eq(Context.SpawnPauseUntil, 0, "streak restarted from 1 after the earlier reset -- 2 distinct still not enough")
print("heavy success resets streak OK")

-- A roster with only ONE heavy type must still eventually pause (fallback ceiling), even
-- though it can never reach 3 DISTINCT failures.
setup()
BotApi.Commands.Spawn = function() return false end
Context.SpawnInfo = { unit = "onlyHeavy", class = UnitClass.HeavyTank }
for i = 1, 8 do AttemptSpawn("SPAWN") end
eq(Context.SpawnPauseUntil, 0, "single heavy type, 8 fails: fallback ceiling (9) not reached yet")
AttemptSpawn("SPAWN")
eq(Context.SpawnPauseUntil, 1150, "single heavy type, 9th fail: fallback ceiling trips the pause")
print("single-heavy-type fallback ceiling OK")

-- Early/mid phase heavy failures never trip the pause (guard is late-phase only).
setup()
Context.GameClock = 100 -- early phase
BotApi.Commands.Spawn = function() return false end
for i = 1, 3 do
	Context.SpawnInfo = { unit = "heavy" .. i, class = UnitClass.HeavyTank }
	AttemptSpawn("SPAWN")
end
eq(Context.SpawnPauseUntil, 0, "early phase: heavy fail streak never trips the pause")
print("early-phase heavy fails ignored OK")

-- Non-heavy tier failures never touch the streak or pause.
setup()
BotApi.Commands.Spawn = function() return false end
for i = 1, 5 do
	Context.SpawnInfo = { unit = "rifle" .. i, class = UnitClass.Infantry, inf = "rifle" }
	AttemptSpawn("SPAWN")
end
eq(Context.SpawnPauseUntil, 0, "non-heavy tier failures never trip the heavy-fail pause")
print("non-heavy failures ignored OK")

UpdateUnitToSpawn = realUpdateUnitToSpawn
BotApi.Commands.Spawn = function() return true end
print("heavy fail pause OK")
