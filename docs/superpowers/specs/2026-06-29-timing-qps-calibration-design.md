# Timing Redesign + QPS Calibration Design

**Date:** 2026-06-29
**Status:** Approved design, ready for plan
**Goal:** Make the bot's elapsed-time clock match real seconds by calibrating the quant rate at
runtime, so per-unit unlock times and phase boundaries fire at the correct moment, and remove the
now-redundant `armorCap` tier ceiling.

## Background

The bot tracks match time with a quant counter `Context.MatchQuants` (incremented once per
`Quant` event) and converts it to seconds with a hardcoded `local QuantsPerSec = 70`. Every
absolute time decision uses `MatchQuants / QuantsPerSec`:

- `CurrentPhase(elapsed)` — early `<180s`, mid `<480s`, late beyond.
- `unlockOk = elapsed >= unit.unlock` — the per-unit unlock gate shipped in the previous phase.
- `OfficerUnlock = 600` seconds gate.

Measured against a real match's wall clock, `QuantsPerSec = 70` is wrong. A 15-minute match's log
showed `MatchQuants` reaching 25997 at wall-clock 00:14:51. A least-squares fit over 247
`(wall_second, mq)` pairs gives a true rate of **~32 quants/sec** (mq=0 at wall 74s, mq=25997 at
wall 891s), confirmed by the end anchors (mq=8994 @ 348s, mq=25997 @ 891s) within 3%.

Consequence: the bot's clock runs ~2.2x too slow. At a real 14 minutes the bot computes
`25997 / 70 = 371s = 6.2 min`. So:

- Unlock gates fire ~2.2x too late. `chi-ha57` (RobZ unlock 480s, ~8 min real) is not seen as
  unlocked by the bot until `mq = 480*70 = 33600`, i.e. ~19 min real, so it never spawns in a
  normal match. German heavies (1500-2160s) are even further out of reach.
- Phase boundaries stretch the same way: "early 0-180s" lasts ~8 min real, "late 480s+" needs
  ~25 min real, so a normal match stays in early/mid forever.

The unlock-gate logic shipped last phase is correct; it is fed a wrong `elapsed`. Fixing the clock
is what makes that feature work in game.

### Relative durations are stretched too

Eight interval/cooldown constants are defined as `seconds * 70` quants
(`WaveInterval = 60*70`, `MinWaveInterval = 10*70`, `NeutralInterval = 5*70`,
`FailCooldownQuants = 10*70`, `BackfillInterval = 3*70`, `DefenderInterval = 20*70`,
`OfficerInterval = 30*70`, `AtRifleInterval = 20*70`, plus an inline `3 * QuantsPerSec`
group-stale check). With the true rate ~32, each is ~2.2x too long in real time (a "10s" fail
bench is really ~22s), which slows spawn cadence and contributes to the observed German
under-production. Correcting the rate fixes all of them at once.

### `os.time()` is available

`os.time()` is already called (`math.randomseed(os.time() * hostId)` at OnGameStart), and a code
comment notes the sandbox is not fully locked. This makes a real-clock calibration possible.

### armorCap is now redundant

`TierRank`/`capRank`/`capOk` (bot.lua:601, 616) gate a unit out of the pool when its tier exceeds
the phase's `armorCap`. With the unlock gate in place, a heavy cannot enter the pool before its
unlock time anyway, and the phase `targets` ratio already restricts which tiers `DecideTier`
prefers per phase (early lists only light/rifle/smg). `TierRank` has no other consumer (only those
two lines). So `armorCap` is doubly redundant and is removed.

## Decisions

- **Runtime QPS calibration (chosen over hardcoding 32 or pure wall-clock).** A hardcoded rate can
  be wrong again on different hardware/player-count; pure `os.time()` elapsed would advance during
  a pause while the sim is frozen. Calibrating the quant rate once from `os.time()` self-corrects
  per run and keeps the clock on `MatchQuants` (sim ticks), so a pause freezes both.
- **Remove `armorCap`** and its `TierRank`/`capRank`/`capOk` machinery (decision A).
- **Relative intervals keep their `MatchQuants`-based stamps; the threshold becomes
  `seconds * QuantsPerSec` evaluated at runtime** via a `Q(sec)` helper (decision B). Stamps stay
  in `mq`; only the constant `70` becomes the calibrated rate.
- **One-shot calibration**, never re-calibrated (the sim tick rate is constant within a match).

## Architecture

```
   OnGameStart                                  OnGameQuant (per Quant, after mq increment)
   Context.StartTime    = os.time()             if Context.QuantsPerSec == nil then
   Context.QuantsPerSec = nil  (uncalibrated)       dtReal = os.time() - Context.StartTime
   Context.MatchQuants  = 0                          if dtReal >= CALIB_SEC and MatchQuants >= CALIB_MIN_Q then
        |                                                Context.QuantsPerSec =
        |                                                    clamp(MatchQuants / dtReal, QPS_MIN, QPS_MAX)
        v                                            end                      (one-shot)
   Elapsed():                                    end
     if Context.QuantsPerSec
        then MatchQuants / Context.QuantsPerSec
        else os.time() - Context.StartTime       <- wall fallback, governs only the first ~CALIB_SEC
   Q(sec):
     sec * (Context.QuantsPerSec or DEFAULT_QPS)  <- quant length of a duration, at runtime
```

## Data flow (single time source)

```
   MatchQuants (sim ticks) ─┐
                            ├─ Elapsed() seconds ─┬─ CurrentPhase(Elapsed())          phase boundaries
   os.time() ───────────────┘  (calibrated rate)  ├─ unlockOk: Elapsed() >= unit.unlock
                                                   ├─ OfficerUnlock (600s) comparison
                                                   └─ relative intervals:
                                                        MatchQuants - stamp >= Q(seconds)
```

## Components

1. **Calibration state + logic** (`OnGameStart`, `OnGameQuant`).
   - `OnGameStart`: set `Context.StartTime = os.time()`, `Context.QuantsPerSec = nil`. (`MatchQuants`
     already reset to 0 here.)
   - `OnGameQuant`: after the existing `Context.MatchQuants = Context.MatchQuants + 1`, if
     `Context.QuantsPerSec == nil`, compute `dtReal = os.time() - Context.StartTime`; when
     `dtReal >= CALIB_SEC` and `Context.MatchQuants >= CALIB_MIN_Q`, set
     `Context.QuantsPerSec = clamp(Context.MatchQuants / dtReal, QPS_MIN, QPS_MAX)`.
   - Constants: `CALIB_SEC = 20` (real seconds of window; ~20s gives <10% error against
     `os.time()`'s 1-second resolution), `CALIB_MIN_Q = 200` (guards a degenerate window),
     `QPS_MIN = 10`, `QPS_MAX = 200`, `DEFAULT_QPS = 32` (the provisional/fallback rate used by
     `Q()` before calibration and by the clamp fallback).

2. **`Elapsed()`** (new global) — returns match elapsed seconds.
   `if Context.QuantsPerSec then return Context.MatchQuants / Context.QuantsPerSec else return os.time() - Context.StartTime end`.
   Replaces every inline `Context.MatchQuants / QuantsPerSec` (phase lookups at ~385, 391, 507,
   517, 599; the `GetUnitToSpawn` `elapsed` local).

3. **`Q(sec)`** (new global) — duration in quants at the current rate.
   `return sec * (Context.QuantsPerSec or DEFAULT_QPS)`.
   The eight interval constants stop being `seconds * 70` literals and instead each comparison site
   uses `Q(seconds)`. The interval values move to named second-valued constants
   (`WaveIntervalSec = 60`, `MinWaveIntervalSec = 10`, `NeutralIntervalSec = 5`,
   `FailCooldownSec = 10`, `BackfillIntervalSec = 3`, `DefenderIntervalSec = 20`,
   `OfficerIntervalSec = 30`, `AtRifleIntervalSec = 20`), and the inline `3 * QuantsPerSec`
   group-stale check becomes `Q(3)`.

4. **Remove `armorCap`** — delete `capRank`/`capOk` (bot.lua:601, 616) and the `capOk` term from
   the pool conjunction (616, 623); delete the `armorCap` field from each `Phases` entry and the
   `TierRank` table (bot.data.lua). The pool gate becomes
   `affordable and unlockOk and notRecentlyFailed and phaseOk and eliteOk`.

5. **Remove the old `QuantsPerSec` constant** (bot.lua:81); its readers move to `Elapsed()` / `Q()`
   / `Context.QuantsPerSec`.

## Error handling / edge cases

| Condition | Behavior |
|---|---|
| Before calibration completes (first ~20s) | `Elapsed()` falls back to `os.time() - StartTime` (real seconds). Earliest phase/unlock threshold is far beyond 20s, so the fallback governs only a window where no time gate matters. |
| `os.time()` returns a bad/zero delta in the window | `dtReal >= CALIB_SEC` guard prevents division by a tiny number; `CALIB_MIN_Q` guards a stalled counter; the `clamp(QPS_MIN, QPS_MAX)` bounds a wild reading. |
| Calibration window overlaps a pause | `mq` freezes with the sim while `os.time()` advances, biasing the rate low. Accepted: the window is the first 20s of a match, where a pause is not expected; one-shot, so a later pause does not affect the (already-fixed) rate. |
| `Context.QuantsPerSec` still nil late (Quant never advanced enough) | `Elapsed()` keeps using the wall fallback (still real seconds); `Q()` uses `DEFAULT_QPS`. The bot still functions on real-clock time. |
| Pause after calibration | `Elapsed()` (mq-based) freezes with the sim — correct game-time behavior. |

## Testing

- **`calib_spec.lua`** (new): stub `os.time` to a controllable counter; drive `OnGameQuant`
  enough times; assert `Context.QuantsPerSec` is set once `dtReal >= CALIB_SEC` and equals
  `mq / dtReal`; assert a wild ratio is clamped to `[QPS_MIN, QPS_MAX]`; assert `Elapsed()` uses
  the wall fallback before calibration and `mq / QuantsPerSec` after.
- **`elapsed_spec.lua`** (new, or folded into `unlock_spec.lua`): with `Context.QuantsPerSec`
  set to a known value, assert a unit with `unlock = 480` is excluded at `Elapsed() = 400` and
  included at `Elapsed() = 500`; assert `CurrentPhase(Elapsed())` returns the right phase.
- **`phase_spec.lua` / `integration_spec.lua`**: any test that drove time by setting
  `Context.MatchQuants` with the old `/70` assumption must set `Context.QuantsPerSec` explicitly so
  `Elapsed()` is deterministic. The integration EARLY test asserted that a medium/heavy tank is not
  spawned early; with `armorCap` gone, the pool no longer excludes them by tier, and `ArmorLead`
  (which front-loads the heaviest available tier) would pick a tier-eligible medium that has no
  unlock. So the test's `medtk`/`heavytk` fixtures must carry an `unlock` beyond the early window
  (e.g. `unlock = 300`) with `Context.QuantsPerSec` set, so the unlock gate — the real in-game
  mechanism (real mediums unlock well after early) — keeps them out of the early pool. This makes
  the test verify exclusion-by-unlock rather than the removed armorCap.
- Existing specs (`frontier`, `mapname`, `partition`, `routing`, `sector`) stay green.
- **In-game probe** (manual gate): run one CTF match >~10 min; confirm the bot logs a calibrated
  `QuantsPerSec` near the true rate, that phase transitions and the earliest in-window unlocks
  (chi-ha57 at 480s, ho-ni1 at 750s) now occur at roughly their real-clock times, and that armor
  appears once unlocked.

## Out of scope

- Re-tuning phase boundaries or composition `targets`/`budget`/`squadCap` (kept as-is; they now
  pace on a correct clock). A later balance pass can adjust them.
- The CP unit-cap gate (officer +40) — still its own deferred phase.
- Routing issues (#4 home-defense) and group retarget (#5) — separate work items.
