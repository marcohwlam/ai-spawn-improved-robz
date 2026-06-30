# Per-Faction Phase Boundaries Design

**Date:** 2026-06-29
**Status:** Approved design, ready for plan
**Goal:** Replace the single global early/mid/late phase boundary set with per-faction
boundaries anchored to each faction's real unit unlock times, so phase composition targets
match what that faction can actually field at a given moment.

## Background

The bot paces spawn composition through three phases (`Phases` in `bot.data.lua`): early, mid,
late. Each phase carries an upper time bound `upto` (seconds), a `targets` composition ratio, and
`budget`/`waveMult`/`squadCap`. `CurrentPhase(elapsedSec)` walks `Phases` and returns the first
entry whose `upto` exceeds the elapsed time.

With the `os.time()` GameClock now tracking real seconds, the phase bounds can be compared against
RobZ's real per-unit unlock times. The current global bounds (`early<180`, `mid<480`, `late≥480`)
do not match the data:

- At 180s no tank of any class has unlocked (earliest light tank `ha-go`/`mk7` unlocks at 300s),
  so `early` ends before any tank exists.
- `late` begins at 480s, but the earliest medium unlocks at 530s (USA `m8`) and the German bot's
  first medium (`pz3_m`/`pz3n`) unlocks at 630s. The earliest heavy is 820s. So `late` opens its
  heavy/medium-weighted `targets` while those tiers are still locked.

Unlock times vary widely by faction. First medium ranges 530-750s; first heavy ranges 820-1750s;
Japan has no heavy-tier unit at all. A single global boundary set cannot fit all eight factions.

### First-unlock data per faction

`TierOf` (bot.lua) maps units to tiers: `HeavyTank` class or `Tank` with `weight="heavy"/"sheavy"`
→ `heavy`; `Tank` with `weight="medium"` → `medium`; other `Tank`/`Vehicle` → `light`.

| Faction    | first medium (s) | first HeavyTank-class (s) |
|------------|------------------|---------------------------|
| eng        | 750 (cromwell_mk_iv) | 820 (mk4) |
| ger        | 630 (pz3_m)      | 1500 (pz5g) |
| ger_ss     | 630 (pz3_m)      | 1500 (pz5g) |
| usa        | 530 (m8)         | 1200 (m4a3e2_jumbo) |
| rus        | 750 (t34_2)      | 830 (kv2) |
| jap        | 580 (chi-he)     | none |
| ger2       | 630 (pz3_ger2)   | 1750 (pz5g_ger2) |
| rus_guard  | 750 (m4a2)       | 1240 (kv85_guard) |

Note: the heavy anchor uses `HeavyTank` class only. `Tank` units tagged `weight="heavy"`
(`kv1` 750s, `pzkpfw756` 1120s) are not used as the boundary anchor; they would collapse the mid
window. Japan has neither a `HeavyTank` unit nor a `weight="heavy"` Tank, so it has no heavy tier.

## Decisions

- **Per-faction `upto` boundaries and per-faction `targets`.** `budget`, `waveMult`, and `squadCap`
  stay global (shared across factions, kept on the `Phases` template).
- **Boundary anchor rule (pure unlock + minimum-width floor):**
  - `early → mid` = faction's first medium unlock.
  - `mid → late` = `max(first HeavyTank-class unlock, first medium unlock + 300)`. The 300s floor
    guarantees mid spans at least ~5 waves; it only binds for eng (820 → 1050) and rus (830 →
    1050), whose heavies unlock right after their mediums.
  - Japan has no HeavyTank: its `mid → late` anchors to `chi-to` (1380s), the first of its two
    top-tier mediums.
- **`targets` change for Japan only (minimal change).** Japan's `late` targets drop `heavy=1` (it
  has no heavy unit to fill it) and shift that weight to `medium`. All other factions reuse the
  global `targets`.
- **Global `Phases` stays as the template + fallback.** Tests and any faction with no override get
  the global table unchanged.

### Resolved boundaries and targets

| Faction    | early.upto (mid start) | mid.upto (late start) | late.targets |
|------------|------------------------|------------------------|--------------|
| eng        | 750  | 1050 | global |
| ger        | 630  | 1500 | global |
| ger_ss     | 630  | 1500 | global |
| usa        | 530  | 1200 | global |
| rus        | 750  | 1050 | global |
| jap        | 580  | 1380 | `{ medium=2, light=2, rifle=3, smg=1 }` |
| ger2       | 630  | 1750 | global |
| rus_guard  | 750  | 1240 | global |

Global `late.targets` (unchanged): `{ heavy=1, medium=1, light=2, rifle=3, smg=1 }`.

## Architecture

```
bot.data.lua                          bot.lua
+------------------+                  +---------------------------+
| Phases (global)  | budget/waveMult/ | ResolvePhases(army)       |
|  budget,waveMult | squadCap/        |  clone global template +  |
|  squadCap,       | default targets  |  apply faction bounds /   |
|  default targets |----------------->|  lateTargets (once)       |
+------------------+                  |            |              |
+------------------+ mid/late/        |            v              |
| FactionPhases    | lateTargets      |   Context.Phases ---------+--> CurrentPhase(t)
|  [army]=mid,late |----------------->|                           |     (per-quant read)
|  jap: lateTargets|                  +---------------------------+
+------------------+
```

## Data flow

```
OnGameStart:  army = BotApi.Instance.army
                 |
                 v  ResolvePhases(army)
   FactionPhases[army].mid  --------------------> resolved[1].upto  (early end)
   FactionPhases[army].late --------------------> resolved[2].upto  (mid end)
   Phases[i].budget/waveMult/squadCap ----------> resolved[i]       (shared)
   Phases[i].targets (or jap lateTargets) ------> resolved[i].targets
                 |
                 v
         Context.Phases --(every quant)--> CurrentPhase(Elapsed()) --> targets/budget/...
```

## Components

### 1. `FactionPhases` table (bot.data.lua, new)

Keyed by faction key (the value of `BotApi.Instance.army`, matching the `Purchases[1].Units`
keys). Each entry carries `mid` and `late` (the two boundary seconds) and, for Japan only, a
`lateTargets` override.

```lua
FactionPhases = {
  ["eng"]       = { mid = 750, late = 1050 },
  ["ger"]       = { mid = 630, late = 1500 },
  ["ger_ss"]    = { mid = 630, late = 1500 },
  ["usa"]       = { mid = 530, late = 1200 },
  ["rus"]       = { mid = 750, late = 1050 },
  ["jap"]       = { mid = 580, late = 1380,
                    lateTargets = { medium = 2, light = 2, rifle = 3, smg = 1 } },
  ["ger2"]      = { mid = 630, late = 1750 },
  ["rus_guard"] = { mid = 750, late = 1240 },
}
```

### 2. `ResolvePhases(army)` (bot.lua, new pure function)

Returns a resolved 3-entry phase array for the given faction key. If `FactionPhases` has no entry
for `army`, returns the global `Phases` unchanged (fallback).

```lua
function ResolvePhases(army)
  local fp = FactionPhases and FactionPhases[army]
  if not fp then return Phases end
  return {
    { name = "early", upto = fp.mid,  targets = Phases[1].targets,
      budget = Phases[1].budget, waveMult = Phases[1].waveMult, squadCap = Phases[1].squadCap },
    { name = "mid",   upto = fp.late, targets = Phases[2].targets,
      budget = Phases[2].budget, waveMult = Phases[2].waveMult, squadCap = Phases[2].squadCap },
    { name = "late",  upto = 1000000000, targets = fp.lateTargets or Phases[3].targets,
      budget = Phases[3].budget, waveMult = Phases[3].waveMult, squadCap = Phases[3].squadCap },
  }
end
```

### 3. `OnGameStart` wiring (bot.lua, modify)

After the faction/army is known, set `Context.Phases = ResolvePhases(BotApi.Instance.army)`.

### 4. `CurrentPhase` (bot.lua, modify)

Iterate `Context.Phases or Phases` instead of the global `Phases`. The `or Phases` fallback keeps
existing specs (which never set `Context.Phases`) working against the global table.

```lua
function CurrentPhase(elapsedSec)
  local phases = Context.Phases or Phases
  for i = 1, #phases do
    if elapsedSec < phases[i].upto then return phases[i] end
  end
  return phases[#phases]
end
```

## Error handling / edge cases

| Condition | Behavior |
|---|---|
| `BotApi.Instance.army` not in `FactionPhases` | `ResolvePhases` returns global `Phases`; bot still paces on the global boundaries. |
| `Context.Phases` nil (tests, or before OnGameStart) | `CurrentPhase` falls back to global `Phases`. |
| `FactionPhases` table absent entirely | `ResolvePhases` guard `FactionPhases and ...` returns global `Phases`. |
| Match shorter than a faction's `mid`/`late` boundary | The bot never advances past early/mid; correct, because the higher-tier units are still locked in a short match. |

## Testing

- **`phase_spec.lua`** (new or extended):
  - `ResolvePhases("ger")` returns `early.upto = 630`, `mid.upto = 1500`, `late.upto = 1e9`,
    and `late.targets` equal to the global `late.targets` (heavy present).
  - `ResolvePhases("jap")` returns `mid.upto = 1380` and `late.targets` with no `heavy` key and
    `medium = 2`.
  - `ResolvePhases("usa")` returns `early.upto = 530`, `mid.upto = 1200`.
  - `ResolvePhases("nonexistent")` returns the global `Phases` table (identity).
  - `CurrentPhase` against a `Context.Phases` built for `jap`: `elapsed = 600` → `early`
    (600 < 580 is false, so this lands in mid — assert mid at 600, early at 500, late at 1400).
  - `budget`/`waveMult`/`squadCap` on each resolved entry equal the global `Phases` values.
- **Existing specs** (`unlock_spec`, `integration_spec`, `clock_spec`, `frontier`, `mapname`,
  `partition`, `routing`, `sector`): stay green. They drive time via `Context.GameClock` and never
  set `Context.Phases`, so `CurrentPhase` uses the global `Phases` fallback unchanged.
- **In-game probe** (manual gate): run one CTF match as a German bot (team B) past ~12 min;
  confirm the log's `phase=` transitions land near 630s (mid) and, in a long match, 1500s (late),
  and that medium production starts once mid opens.

## Out of scope

- Re-tuning `budget`/`waveMult`/`squadCap` (kept global, unchanged).
- Per-faction `targets` for any faction other than Japan (all others reuse global `targets`).
- The CP unit-cap gate (officer +40) — its own deferred phase.
- Routing (#4 home-defense) and group retarget (#5) — separate work items.
