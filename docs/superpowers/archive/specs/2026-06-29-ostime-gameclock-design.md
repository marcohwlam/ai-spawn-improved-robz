# os.time GameClock Design (replace calibrated-mq clock)

**Date:** 2026-06-29
**Status:** Approved design, ready for plan
**Goal:** Replace the runtime-calibrated `MatchQuants / QuantsPerSec` clock with a wall-clock
`GameClock` accumulated from `os.time()` between Quant events, so elapsed time equals real
game-seconds without depending on a one-shot quant-rate calibration.

## Background

The previous phase replaced a hardcoded `QuantsPerSec = 70` with a runtime calibration: at ~20s
into the match it set `Context.QuantsPerSec = MatchQuants / dtReal`, then computed
`Elapsed() = MatchQuants / QuantsPerSec`. In-game testing exposed a fatal flaw:

- A ~12-minute match logged `MatchQuants` 0→29018 over ~720s wall-clock — a true rate of ~40 q/s.
- But the calibration produced **10** q/s (clamped at the `QPS_MIN` floor), because the first ~20s
  of a match is engine load/init time where Quant events fire slowly (~10 q/s). The one-shot window
  measured that startup transient, not the steady-state rate.
- Result: `Elapsed()` ran ~4x too FAST (`t=2848` at real ~720s), the opposite of the original
  too-slow bug. Phases and unlocks fired ~4x too early in real time.

Root cause: the quant rate is not stable. It is slow during startup, faster in mid-game, and slows
again late as unit count grows. A single calibration cannot represent the whole match, and the
earliest window (the only one a one-shot can use before time gates matter) is the least
representative.

`os.time()` is already used in `bot.lua` (`math.randomseed`, and the calibration's own `dtReal`),
so a wall-clock approach needs no new capability.

### Two kinds of time consumer (both currently routed through the broken rate)

- **Absolute thresholds:** `CurrentPhase(Elapsed())` (early `<180`, mid `<480`), `unlockOk`
  (`Elapsed() >= unit.unlock`), `OfficerUnlock` (600s).
- **Relative intervals:** eight cadences compared as per-quant counters against `Q(sec)`
  (`Context.QuantCount >= Q(WaveIntervalSec)`, `DefenderCount`, `BackfillCount`, `NeutralCount`,
  `OfficerCount`, `AtRifleCount`), plus `FailCooldown`/`staleSince` quant deltas. With the rate
  wrong, these are wrong too (a "60s" wave at calibrated-10 fires every 600 quants = ~15s real at
  40 q/s). They must move onto the same corrected clock.

## Key insight

Accumulating `os.time()` deltas BETWEEN consecutive Quant events yields real game-seconds that is
**pause-immune** and **calibration-free**: Quant events fire only while the simulation advances
(frozen during a pause), so the accumulator only grows while the game actually runs, at the true
wall-clock rate, regardless of how many quants per second the engine happens to emit.

## Decisions

- **`GameClock` accumulator (chosen over plain `os.time() - StartTime`).** Plain wall-clock would
  advance during a pause while the sim is frozen; the accumulator only advances on Quant ticks, so a
  pause freezes it (the user's pause concern). Cost is one accumulator field and a clamp.
- **Single time source.** `Elapsed()` returns `GameClock`; every absolute AND relative time decision
  uses it. `QuantsPerSec`, `Q()`, the calibration block, the `CALIB_*`/`QPS_*`/`DEFAULT_QPS`
  constants, and the per-quant interval counters are all removed.
- **Relative intervals become second-deltas:** each periodic action stores its last-fire time in
  `Elapsed()` seconds and re-fires when `Elapsed() - last >= XxxIntervalSec`. `FailCooldown`,
  `LostStamp`, and `staleSince` store `Elapsed()` seconds instead of `MatchQuants`.
- **1-second resolution is sufficient:** all thresholds are second-scale (smallest is the 3s
  backfill / 5s neutral; waves are 60s). `os.time()` integer deltas (mostly 0, with a +1 each real
  second) accumulate to real seconds.

## Architecture

```
   OnGameStart                          OnGameQuant (every Quant)
   Context.StartTime = os.time()        local now = os.time()
   Context.GameClock = 0                if Context.LastWall then
   Context.LastWall  = os.time()            local d = now - Context.LastWall
        |                                    if d >= 0 and d <= PAUSE_CLAMP then
        |                                        Context.GameClock = Context.GameClock + d
        v                                    end          -- d > PAUSE_CLAMP = pause/huge hitch, skipped
   Elapsed():                           end
     return Context.GameClock           Context.LastWall = now
   (real game-seconds, pause-immune)
```

`PAUSE_CLAMP = 2` (seconds). Normal inter-quant `d` is 0 or 1; a pause or multi-second hitch
produces a large `d` that is skipped so the clock never jumps.

## Data flow (single source, all seconds)

```
   os.time() deltas (accumulated only on Quant ticks) ─► GameClock (seconds) = Elapsed()
                                                            ├─ CurrentPhase(Elapsed())         phase 180/480
                                                            ├─ unlockOk: Elapsed() >= unit.unlock
                                                            ├─ OfficerUnlock (600s)
                                                            └─ relative cadence:
                                                                 Elapsed() - lastFireTime >= XxxIntervalSec
```

## Components

1. **Clock state + accumulation** (`Context` init, `OnGameStart`, `OnGameQuant`).
   - Add `Context.GameClock = 0` and `Context.LastWall = nil`. Keep `Context.StartTime` (still useful
     for logging); remove `Context.QuantsPerSec`.
   - `OnGameStart`: set `StartTime`/`LastWall` to `os.time()`, `GameClock = 0`.
   - `OnGameQuant`: the accumulation block above, replacing the calibration block.
   - Add constant `PAUSE_CLAMP = 2`. Remove `CALIB_SEC`, `CALIB_MIN_Q`, `QPS_MIN`, `QPS_MAX`,
     `DEFAULT_QPS`.

2. **`Elapsed()`** — `return Context.GameClock`. (Drops the `mq / QuantsPerSec` and wall-fallback
   branches.) `Q()` is deleted.

3. **Absolute-threshold consumers** — unchanged in form; they already call `Elapsed()`. They simply
   now receive real game-seconds.

4. **Relative-interval consumers** — convert each from "per-quant counter vs `Q(sec)`" to
   "elapsed-second delta vs `IntervalSec`":
   - Replace the six counters (`QuantCount`, `DefenderCount`, `BackfillCount`, `NeutralCount`,
     `OfficerCount`, `AtRifleCount`) with last-fire timestamps (e.g. `Context.LastWaveTime`,
     `LastDefenderTime`, ...), each set to `Elapsed()` when its action fires, tested with
     `Elapsed() - last >= XxxIntervalSec`.
   - `WaveIntervalNow()` returns SECONDS (drop the `Q()` wrapping; keep the `waveMult`/deficit
     scaling and the `MinWaveIntervalSec` floor in seconds).
   - `FailCooldown[unit]` stores `Elapsed()`; the pool gate tests `Elapsed() - failed >= FailCooldownSec`.
   - `staleSince` stores `Elapsed()`; the prune tests `Elapsed() - staleSince > 3`.
   - `LostStamp[flag]` stores `Elapsed()`; its only uses are relative ordering (recapture priority),
     which a monotonic seconds value serves identically.

5. **Remove** `QuantsPerSec`, `Q()`, the calibration block, and the `CALIB_*`/`QPS_*`/`DEFAULT_QPS`
   constants. `MatchQuants` itself stays (still incremented; the accumulation reads it only via the
   Quant event firing, and other code may use the raw tick count) — confirm during planning whether
   any non-time consumer of `MatchQuants` remains; if none, it can also go, but that is not required.

## Error handling / edge cases

| Condition | Behavior |
|---|---|
| First Quant (`LastWall` nil) | No delta added; `LastWall` set. `GameClock` stays 0. |
| Pause / multi-second hitch (`d > PAUSE_CLAMP`) | Delta skipped; `GameClock` does not jump. Minor under-count of a long real hitch is acceptable. |
| `os.time()` non-monotonic (clock set back, `d < 0`) | `d >= 0` guard skips it; no negative accumulation. |
| Before any Quant fires | `Elapsed()` returns 0 (GameClock init). |
| Match never pauses (the common case) | `GameClock` tracks real seconds 1:1. |

## Testing

- **`clock_spec.lua`** (new): stub `os.time` to a controllable counter. Drive a sequence of
  `OnGameQuant` calls advancing the fake clock by 0/1 each tick, plus one tick with a large gap
  (simulated pause); assert `GameClock` equals the sum of the small deltas (the pause gap excluded)
  and `Elapsed()` returns it. Assert the first-quant (`LastWall` nil) adds nothing, and a backward
  `os.time` step adds nothing.
- **`interval` coverage** (in `clock_spec` or a sibling): with `Elapsed()` driven to known seconds,
  assert a periodic action does not re-fire before `IntervalSec` and does after.
- **`unlock_spec.lua` / `integration_spec.lua`**: drive time by setting `Context.GameClock` directly
  (replacing the `Context.QuantsPerSec = 1; MatchQuants = N` idiom). Assertions (unlock excluded
  before/after, ArmorLead bite) unchanged.
- Existing specs (`phase`, `frontier`, `mapname`, `partition`, `routing`, `sector`) stay green.
- **In-game probe** (manual gate): run one CTF match; confirm the bot's `t=` marker tracks real
  wall-clock minutes (e.g. `t≈600` at 10 real minutes, not 4x that), phases transition at real
  ~3/~8 min, and unlock-window units appear near their real unlock times.

## Out of scope

- The CP unit-cap gate (heavies unlocked-but-rejected) — its own deferred phase.
- Routing #4 (home defense) and #5 (group retarget) — separate handoff.
- Re-tuning phase boundaries / interval seconds — kept at current values, now on a correct clock.
