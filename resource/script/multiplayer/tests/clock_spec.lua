dofile((arg[0]:gsub("clock_spec%.lua$", "harness.lua")))

local fake = 1000
os.time = function() return fake end

-- Fresh clock state.
Context.GameClock = 0
Context.LastWall = nil

-- First tick: LastWall nil -> no delta added, just records the wall.
AdvanceClock()
assert(Context.GameClock == 0, "first tick adds nothing, got " .. Context.GameClock)

-- 5 ticks advancing the fake clock by 1s each -> GameClock = 5.
for i = 1, 5 do fake = fake + 1; AdvanceClock() end
assert(Context.GameClock == 5, "5x +1s -> 5, got " .. Context.GameClock)
assert(Elapsed() == 5, "Elapsed returns GameClock, got " .. tostring(Elapsed()))

-- Several same-second ticks add 0 (1s os.time resolution).
fake = fake -- unchanged
for i = 1, 10 do AdvanceClock() end
assert(Context.GameClock == 5, "same-second ticks add 0, got " .. Context.GameClock)

-- A pause gap (d > PAUSE_CLAMP) is skipped, not jumped.
fake = fake + 300  -- 5-minute pause
AdvanceClock()
assert(Context.GameClock == 5, "pause gap skipped, got " .. Context.GameClock)
-- ...and the clock resumes cleanly afterward.
fake = fake + 1; AdvanceClock()
assert(Context.GameClock == 6, "resumes after pause, got " .. Context.GameClock)

-- A backward clock step (d < 0) adds nothing.
fake = fake - 1; AdvanceClock()
assert(Context.GameClock == 6, "backward step adds nothing, got " .. Context.GameClock)

print("clock OK")
