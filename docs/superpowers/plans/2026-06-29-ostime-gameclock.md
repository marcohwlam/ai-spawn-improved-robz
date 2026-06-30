# os.time GameClock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the runtime-calibrated `MatchQuants / QuantsPerSec` clock with a `GameClock` that accumulates `os.time()` deltas between Quant events, so elapsed time equals real game-seconds without calibration, and move all relative intervals onto elapsed-second deltas.

**Architecture:** Task 1 adds the `GameClock` accumulator (`AdvanceClock()`) and repoints `Elapsed()` to it — fixing absolute time (phase/unlock) — while leaving the old quant-rate machinery in place for intervals. Task 2 migrates the relative intervals to second-deltas and removes `QuantsPerSec`/`Q()`/calibration/counters.

**Tech Stack:** Lua 5.1 (no `goto`), plain-Lua specs run with stock `lua`.

## Global Constraints

- Lua 5.1, 32-bit engine, no `goto`. The work happens in the worktree `/home/lamho/Documents/repos/ai-spawn-ostime-clock` (branch `feat/os-time-clock`); do all edits/tests/git there, never in the shared repo dir.
- Run specs from `resource/script/multiplayer/`: `lua tests/<name>_spec.lua`; full suite `for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done` — every spec prints its `OK`.
- `AdvanceClock()`: `local now = os.time(); if Context.LastWall then local d = now - Context.LastWall; if d >= 0 and d <= PAUSE_CLAMP then Context.GameClock = Context.GameClock + d end end; Context.LastWall = now`.
- `PAUSE_CLAMP = 2` (seconds). `Elapsed()` returns `Context.GameClock`.
- Relative interval thresholds keep their current second values (Wave 60, MinWave 10, Neutral 5, FailCooldown 10, Backfill 3, Defender 20, Officer 30, AtRifle 20; group-stale 3). After Task 2: `QuantsPerSec`, `Q`, the calibration block, `CALIB_SEC`/`CALIB_MIN_Q`/`QPS_MIN`/`QPS_MAX`/`DEFAULT_QPS`, and the six per-quant counters are gone.
- Commit after each task; push branch `feat/os-time-clock` after each task.

## File Structure

- `resource/script/multiplayer/bot.lua` (modify) — `Context` init (15-35), constants (83-87), `Elapsed()` (92-97), `Q()` (100-101), `WaveIntervalNow` (527-533), pool fail-gate (632-634), group-stale (470-471), `OnGameStart` (1061-1080), `OnGameQuant` (1160-1310).
- `resource/script/multiplayer/tests/clock_spec.lua` (new) — `AdvanceClock`/`Elapsed` + an interval-delta case.
- `resource/script/multiplayer/tests/unlock_spec.lua` (modify) — drive time via `Context.GameClock`.
- `resource/script/multiplayer/tests/integration_spec.lua` (modify) — drive time via `Context.GameClock`.

---

### Task 1: GameClock accumulator (fix absolute time)

**Files:**
- Modify: `resource/script/multiplayer/bot.lua`
- Create: `resource/script/multiplayer/tests/clock_spec.lua`

**Interfaces:**
- Produces: global `AdvanceClock()`; `Elapsed()` returns `Context.GameClock` (real game-seconds); `Context.GameClock` (number), `Context.LastWall` (os.time of last Quant). `PAUSE_CLAMP` constant.

- [ ] **Step 1: Write the failing clock spec**

Create `resource/script/multiplayer/tests/clock_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/clock_spec.lua`
Expected: FAIL — `AdvanceClock` undefined (`attempt to call a nil value (global 'AdvanceClock')`).

- [ ] **Step 3: Add `PAUSE_CLAMP`, `AdvanceClock()`, and repoint `Elapsed()`**

In `bot.lua` constants area (near line 87, after the existing `DEFAULT_QPS` line — leave the
`CALIB_*`/`QPS_*`/`DEFAULT_QPS` lines for Task 2), add:

```lua
local PAUSE_CLAMP = 2  -- seconds; an inter-quant os.time gap larger than this is a pause/hitch, skipped
```

Replace the body of `Elapsed()` (lines 92-97) with:

```lua
-- Match elapsed seconds: a wall-clock accumulator advanced only on Quant ticks (see AdvanceClock),
-- so it tracks real game-seconds and is pause-immune (frozen while the sim is paused).
function Elapsed()
	return Context.GameClock
end

-- Accumulate real seconds between consecutive Quant events. A gap > PAUSE_CLAMP (pause / multi-second
-- hitch) or a backward clock step is skipped so the clock never jumps.
function AdvanceClock()
	local now = os.time()
	if Context.LastWall then
		local d = now - Context.LastWall
		if d >= 0 and d <= PAUSE_CLAMP then
			Context.GameClock = Context.GameClock + d
		end
	end
	Context.LastWall = now
end
```

(Leave `Q()` at lines ~100-101 untouched — Task 2 removes it. It still serves the intervals.)

- [ ] **Step 4: Add the clock fields and wire `OnGameStart` / `OnGameQuant`**

In the `Context` table, after `MatchQuants = 0,` (line 30) add:

```lua
	GameClock = 0,     -- real game-seconds since match start (AdvanceClock accumulates this)
	LastWall = nil,    -- os.time() at the last Quant tick
```

(Leave the existing `StartTime` and `QuantsPerSec` fields; Task 2 removes `QuantsPerSec`.)

In `OnGameStart`, next to `Context.StartTime = os.time()` (line 1063), add:

```lua
	Context.GameClock = 0
	Context.LastWall = os.time()
```

In `OnGameQuant`, immediately after `Context.MatchQuants = Context.MatchQuants + 1` (line 1160) and before the existing calibration block, add the call:

```lua
	AdvanceClock()
```

(Leave the calibration block at 1162-1166 in place for Task 2 — it still feeds `Q()` via
`Context.QuantsPerSec`. `Elapsed()` now ignores it.)

- [ ] **Step 5: Run the clock spec to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/clock_spec.lua`
Expected: PASS, `clock OK`.

- [ ] **Step 6: Make the time-driven specs use `GameClock`**

`unlock_spec.lua` and `integration_spec.lua` currently set `Context.QuantsPerSec = 1` and
`Context.MatchQuants = N` to drive `Elapsed()`. `Elapsed()` now returns `Context.GameClock`, so set
that instead.

In `tests/unlock_spec.lua` `sample` helper, replace the two lines that set `QuantsPerSec`/`MatchQuants` with:
```lua
	Context.GameClock = seconds
```
(keep the rest: `Context.FailCooldown = {}` and the loop.)

In `tests/integration_spec.lua`, replace the clock-pin lines `Context.QuantsPerSec = 1` /
`Context.MatchQuants = 0` (before the EARLY loop) with:
```lua
Context.GameClock = 0
```

- [ ] **Step 7: Run the whole suite**

Run from `resource/script/multiplayer`:
```bash
for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done
```
Expected: every spec prints `OK` (`clock`, `unlock`, `integration`, `phase`, `frontier`, `mapname`, `partition`, `routing`, `sector`). No `attempt to call a nil value`.

- [ ] **Step 8: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-ostime-clock
git add resource/script/multiplayer/bot.lua \
        resource/script/multiplayer/tests/clock_spec.lua \
        resource/script/multiplayer/tests/unlock_spec.lua \
        resource/script/multiplayer/tests/integration_spec.lua
git commit -m "feat: GameClock (os.time accumulator) for real game-seconds elapsed"
git push origin feat/os-time-clock
```

---

### Task 2: Migrate intervals to second-deltas; remove the quant-rate machinery

**Files:**
- Modify: `resource/script/multiplayer/bot.lua`

**Interfaces:**
- Consumes: `Elapsed()` (seconds) and `Context.GameClock` from Task 1.
- Produces: relative cadences gated on `Elapsed() - lastFireTime >= XxxIntervalSec`; `QuantsPerSec`/`Q`/calibration/counters removed.

- [ ] **Step 1: Replace the six per-quant counters with last-fire timestamps**

In the `Context` table, replace the six counter fields (`QuantCount`, `NeutralCount`,
`BackfillCount`, `DefenderCount`, `OfficerCount`, `AtRifleCount` — lines 15, 20-24) with last-fire
time fields initialised to 0:

```lua
	LastWaveTime = 0,     -- Elapsed() at last wave start
	LastNeutralTime = 0,  -- Elapsed() at last neutral-capper trickle
	LastBackfillTime = 0, -- Elapsed() at last idle backfill
	LastDefenderTime = 0, -- Elapsed() at last MG defender trickle
	LastOfficerTime = 0,  -- Elapsed() at last officer keep-alive
	LastAtRifleTime = 0,  -- Elapsed() at last AT-rifle keep-alive
```

In `OnGameStart`, replace the six counter resets (`Context.QuantCount = 0` at 1061, and
`Context.NeutralCount`/`BackfillCount`/`DefenderCount`/`OfficerCount`/`AtRifleCount = 0` at
1069-1073) with:

```lua
	Context.LastWaveTime = 0
	Context.LastNeutralTime = 0
	Context.LastBackfillTime = 0
	Context.LastDefenderTime = 0
	Context.LastOfficerTime = 0
	Context.LastAtRifleTime = 0
```

- [ ] **Step 2: Convert each cadence check to a second-delta**

In `OnGameQuant` and helpers, make these exact edits:

- Delete the increment lines: `Context.QuantCount = Context.QuantCount + 1` (1161),
  `Context.BackfillCount = Context.BackfillCount + 1` (1237),
  `Context.DefenderCount = Context.DefenderCount + 1` (1238),
  `Context.NeutralCount = Context.NeutralCount + 1` (1264),
  `Context.OfficerCount = Context.OfficerCount + 1` (1283),
  `Context.AtRifleCount = Context.AtRifleCount + 1` (1305).

- Wave (1183-1184):
  `if Context.QuantCount >= WaveIntervalNow() and Context.WaveRemaining == 0 then` →
  `if Elapsed() - Context.LastWaveTime >= WaveIntervalNow() and Context.WaveRemaining == 0 then`
  and `Context.QuantCount = 0` → `Context.LastWaveTime = Elapsed()`.

- "No idle backfill while a wave is running" (1205): `Context.BackfillCount = 0` →
  `Context.LastBackfillTime = Elapsed()` (pushes the next backfill out by a full interval).

- Defender (1239-1241): `if Context.DefenderCount >= Q(DefenderIntervalSec)` →
  `if Elapsed() - Context.LastDefenderTime >= DefenderIntervalSec` and the reset
  `Context.DefenderCount = 0` → `Context.LastDefenderTime = Elapsed()`.

- Backfill (1254-1255): `elseif Context.BackfillCount >= Q(BackfillIntervalSec) then` →
  `elseif Elapsed() - Context.LastBackfillTime >= BackfillIntervalSec then` and
  `Context.BackfillCount = 0` → `Context.LastBackfillTime = Elapsed()`.

- Neutral (1265-1266): `if Context.NeutralCount >= Q(NeutralIntervalSec) then` →
  `if Elapsed() - Context.LastNeutralTime >= NeutralIntervalSec then` and
  `Context.NeutralCount = 0` → `Context.LastNeutralTime = Elapsed()`.

- Officer (1284-1285): `if Context.OfficerCount >= Q(OfficerIntervalSec) then` →
  `if Elapsed() - Context.LastOfficerTime >= OfficerIntervalSec then` and
  `Context.OfficerCount = 0` → `Context.LastOfficerTime = Elapsed()`.

- AtRifle (1306-1307): `if Context.AtRifleCount >= Q(AtRifleIntervalSec) then` →
  `if Elapsed() - Context.LastAtRifleTime >= AtRifleIntervalSec then` and
  `Context.AtRifleCount = 0` → `Context.LastAtRifleTime = Elapsed()`.

- [ ] **Step 3: Convert `WaveIntervalNow`, the fail-gate, the stamps to seconds**

- `WaveIntervalNow` (529, 532): `local base = Q(WaveIntervalSec) * (phase.waveMult or 1.0)` →
  `local base = WaveIntervalSec * (phase.waveMult or 1.0)`; and
  `return math.max(Q(MinWaveIntervalSec), math.floor(base / (1.0 + 0.25 * deficit)))` →
  `return math.max(MinWaveIntervalSec, math.floor(base / (1.0 + 0.25 * deficit)))`.

- Pool fail-gate (634): `or (Context.MatchQuants - failed >= Q(FailCooldownSec))` →
  `or (Elapsed() - failed >= FailCooldownSec)`. And both `FailCooldown` writes —
  `Context.FailCooldown[unit.unit] = Context.MatchQuants` (1137) and
  `Context.FailCooldown[mg.unit] = Context.MatchQuants` (1250) — become `= Elapsed()`.

- Group-stale (470-471): `g.staleSince = g.staleSince or Context.MatchQuants` →
  `g.staleSince = g.staleSince or Elapsed()`; `if Context.MatchQuants - g.staleSince > Q(3) then` →
  `if Elapsed() - g.staleSince > 3 then`.

- LostStamp write (1173): `Context.LostStamp[flag.name] = Context.MatchQuants` → `= Elapsed()`.
  (Its readers at 427/439 are nil-checks and the routing tier-3 `-stamp` ordering — a monotonic
  seconds value serves identically.)

- [ ] **Step 4: Remove the quant-rate machinery**

- Delete `Q()` (lines ~100-101).
- Delete the calibration block in `OnGameQuant` (the `if Context.QuantsPerSec == nil then ... end`
  at 1162-1166).
- Delete the constants `CALIB_SEC`, `CALIB_MIN_Q`, `QPS_MIN`, `QPS_MAX`, `DEFAULT_QPS` and their
  comment block (83-87, and the comment at ~81-82).
- Delete the `QuantsPerSec = nil,` field from `Context` (32) and `Context.QuantsPerSec = nil` from
  `OnGameStart` (1064).
- Verify: `grep -nE "QuantsPerSec|[^A-Za-z]Q\(|QuantCount|NeutralCount|BackfillCount|DefenderCount|OfficerCount|AtRifleCount|CALIB_|QPS_MIN|QPS_MAX|DEFAULT_QPS" bot.lua` → no matches.

- [ ] **Step 5: Run the whole suite**

Run from `resource/script/multiplayer`:
```bash
for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done
```
Expected: all specs print `OK`. No `attempt to call a nil value (global 'Q')`, no arithmetic-on-nil.

- [ ] **Step 6: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-ostime-clock
git add resource/script/multiplayer/bot.lua
git commit -m "feat: intervals on GameClock seconds; remove QuantsPerSec/Q/calibration/counters"
git push origin feat/os-time-clock
```

---

## In-game verification (manual gate, after both tasks)

Run one CTF (`battle_zones`) match. Confirm in the debug log:
- The bot's `t=` marker (`math.floor(Elapsed())`) tracks real wall-clock minutes (e.g. `t≈600` at
  10 real minutes, NOT ~4x that). This is the core fix — the prior calibrated clock ran ~4x fast.
- Phases transition at real ~3 min (mid) and ~8 min (late); unlock-window units (chi-ha57 480s,
  ho-ni1 750s, pz4h_seq 950s) appear near their real unlock times.
- Wave cadence ~60s real between waves.

If a heavy is unlocked-but-still-fails-to-spawn, that remains the deferred CP unit-cap phase, not
this clock.
