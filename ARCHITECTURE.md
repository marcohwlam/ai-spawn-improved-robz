# Architecture

This document maps how the mod's runtime pieces fit together. For feature-level
rationale see `docs/superpowers/specs/` and `docs/superpowers/roadmap.md`; this file
is the structural map, not the history.

## Scope

Pure Lua bot-AI override for RobZ Realism 1.30.x. No new entities/assets — three
runtime surfaces only:

- `resource/script/multiplayer/bot.lua` — the bot brain (spawn selection, phases,
  waves, groups, routing, flags).
- `resource/script/multiplayer/bot.data.lua` — static config (unit roster, recharge
  timers, phase/purchase tables).
- `resource/script/multiplayer/flag_sectors.lua` — generated static data: per-map
  flag coordinates, sectors, and base positions (54/57 RobZ 1v1/2v2/3v3 maps).
- `resource/set/multiplayer/games/bots_generic.inc` — AI economy tuning (income,
  must load after RobZ's own copy).
- `resource/set/stuff/{gun,reactive}/` — artillery weapon presets with
  `PrepareTime=0` (removes indirect-fire wind-up); asset-level, not Lua.

`tools/*.py` are offline generators that produce `flag_sectors.lua` and pieces of
`bot.data.lua` from RobZ's own `.set`/map files — they run at dev time, never in-game.

## Module map

```
┌─────────────────────────────────────────────────────────────────────┐
│ Game engine (Men of War AS2)                                        │
│   calls: OnGameStart / OnGameQuant / OnGameSpawn / OnGameStop        │
└───────────────┬───────────────────────────────────────────────────┬─┘
                │                                                   │
                ▼                                                   │
┌─────────────────────────────┐   require   ┌──────────────────────┐│
│ bot.lua                     │◄────────────│ bot.data.lua         ││
│  - Context (mutable state)  │             │  - UnitClass roster  ││
│  - phase/wave/group engine  │   require   │  - Phases/           ││
│  - flag routing             │◄────────────│    FactionPhases     ││
│  - spawn selection          │             │  - Purchases         ││
└──────────────┬───────────────┘             └──────────────────────┘│
               │                              ┌──────────────────────┐
               └─────────────require──────────►│ flag_sectors.lua     │
                                               │  - per-map Sectors[] │
                                               │  - base coords       │
                                               └───────────▲──────────┘
                                                            │ generates
                                            ┌───────────────┴───────────┐
                                            │ tools/build_sectors.py     │
                                            │ tools/build_unit_meta.py   │
                                            │ tools/build_arty_roster.py │
                                            │ tools/build_aim_time.py    │
                                            │  (offline, dev-time only)  │
                                            └────────────────────────────┘
```

`bots_generic.inc` and the `set/stuff/gun|reactive` presets are independent
of the Lua stack — the engine reads them directly for economy/weapon tuning.
They only interact with `bot.lua` in that spawn *decisions* assume the income
curve `bots_generic.inc` provides.

## `Context` — the single mutable state blob

Everything the bot remembers between quants lives in one global table
(`bot.lua:4`): wave/backfill/trickle timers, `FieldUnits` (live squad tracking),
`Groups`/`SquadGroup` (group membership), `FlagLabel`/`FlagOwner` (routing labels
computed once at `OnGameStart`), and cooldown maps (`FailCooldown`, `LostStamp`).
There is no persistence across matches — `OnGameStart` re-seeds it every game.

## Data flow — one quant tick

```
OnGameQuant()
  │
  ├─ AdvanceClock()            update Context.GameClock from wall time
  ├─ TrackLostFlags()          stamp flags lost this tick (recapture priority)
  ├─ UpdateGroupTargets()      re-pick group target if stale/gone
  │
  ├─ wave in progress? ──no──► idle trickles (priority order, ≤1 spawn/tick):
  │                              MG defender → arty defender → officer/AT-rifle
  │                              keep-alive → neutral capper → deep-strike →
  │                              backfill toward deficit tier
  │  yes
  │  ▼
  ├─ AttemptSpawn("SPAWN")
  │    ├─ CurrentPhase(Elapsed())        EARLY/MID/LATE by game clock
  │    ├─ DecideTier(phase, field, ...)  heavy/medium/light/infantry ratio target
  │    ├─ GetUnitToSpawn(units)          picks a live unit off recharge/fail cooldown
  │    ├─ GroupToFill() / ManageGroups() assign the new squad into a group slot
  │    └─ Spawn(...) → engine            on success, push to SpawnQueue + FieldUnits
  │
  └─ (async) OnGameSpawn(args)           engine confirms a queued spawn; assigns
                                          the squad its group order via SetSquadOrder
```

`OnGameStart` runs once: `ReadMapName()` → `LabelFlags()` (OWN/CONTESTED/ENEMY +
distance rank) → `PartitionFlags()` (lateral split among teammates) →
`ManageGroups()` seed. These three populate `Context.FlagLabel`/`FlagOwner`, which
`PickGroupTarget`/`FlagTier`/`IsFrontier` read every quant without recomputing.

## Subsystems

### 1. Phase / tier / wave (spawn economy)
`CurrentPhase(elapsedSec)` walks `Context.Phases` (= `ResolvePhases(army)`, per
bot below) and returns the first phase whose `upto` bound isn't passed yet.
`ResolvePhases` overrides the global `Phases` table's boundaries with
`FactionPhases[army].mid`/`.late` when present — every shipped faction has an
entry (anchored to that faction's real RobZ unlock times), so the global
180s/480s bounds only apply as a fallback that never actually fires in play.
`DecideTier` picks the tier (target heavy:medium:light:infantry ratio, gated by
`tierEligible` and losing-state) → `GetUnitToSpawn` picks a specific live unit
whose spawn window is open (`unlock` ≤ elapsed < `retire`), skipping anything on
recharge (`bot.data.lua` `;Nsec` cooldown) or `FailCooldown` (benched after an
unaffordable spawn attempt). The optional `retire` field drops a weak-gun
`weight="medium"` tank once its gun can no longer penetrate the enemy armor on
the field, so it stops diluting the medium-armor pick share late-game. The same
`retire` field also gates `GetAtTankUnit` (the ATTank trickle picker), retiring
the open-top/gun-superseded tank destroyers (`marder_3m`, `marder_3m_ss`,
`su76`, `su76_guard`, `m10wolverine_eng`) once their armored, better-gunned
successor has unlocked.

Wave cadence: `WaveIntervalNow()` starts from `WaveIntervalSec = 110` seconds,
multiplied by the phase's `waveMult` (early 1.0 / mid 1.5 / late 2.25), then
scaled symmetrically by `FlagWinPct()` — (our flag share - enemy flag share),
clamped to ±150% — so winning *lengthens* the gap (bank MP for a stronger
follow-up) and losing *shortens* it, floored at `MinWaveIntervalSec = 35`.
Within a wave, spawns are spread across quants (`WaveSpawnSpacing`) because the
engine accepts ~1 `Spawn()` per tick; a burst-spawn wastes manpower on rejected
calls. A late-phase heavy-tank affordability guard (`HeavyFailStreakLimit`)
doubles every interval-gated cadence (`IntervalMult()`) for `SpawnSlowdownSec`
after repeated failed heavy spawns, instead of a hard stop — the field stays
active while MP banks toward the heavy.

An armor-bank window (`Context.ArmorBankUntil`, `ArmorBankSec`) generalises
the late-heavy slowdown: when a `min_income`-eligible armor unit fails
`Commands:Spawn` (the MP balance is drained), `GetUnitToSpawn` refuses to
downgrade to a cheaper tier for `ArmorBankSec` seconds, spawning armor if
affordable and otherwise nothing, so the balance banks toward it while the
cappers keep taking flags. Artillery upkeep bends to the flag score through
`ArtyCapNow()`: the baseline `ArtyCap` is 1, dropped to 0 while badly losing
(`FlagDeficit >= BadlyLosingDeficit`) or while the bank window is active,
freeing MP for the front line.

**Faction composition bias** applies a per-faction minimum-count floor
(`FactionBias` table, documented in
`docs/superpowers/specs/2026-07-06-faction-composition-bias-design.md`) across
10 categories (the 5 tiers plus `artillery`/`mortar`/`attank`/`mg`/`sniper`),
short-circuiting `DecideTier`, the DEFENDER (MG) call site, and a shared
`TryCappedTrickle` helper (artillery/mortar/attank/sniper) before the existing
ratio/cap logic runs. `FactionBias[army]` is keyed by phase name first, so a
faction can bias a *different* category per phase, not just a bigger floor on
the same one (e.g. `ger_ss` biases `attank` in mid, `heavy` in late). ATTank
and Sniper (like Mortar before them) are pulled out of the shared
`AuxPerCycle=2` aux batch into their own dedicated capped trickles.

### 2. Groups (`ManageGroups`, `ApportionArmor`, `PickGroupTarget`, `PickSubTarget`)
Up to `MaxGroups` (2) squads-of-squads share one attack target. `PickGroupTarget`
is the single lever for "where does this army push" — it applies the routing
filter stack below. `PickSubTarget` derives the second group's target relative to
the main group (split fronts, not duplicate targets). Aux units (support roles)
attach to a group without consuming its capacity.

### 3. Flag routing / frontier logic
`FlagTier(name)` ranks candidate flags: recapture (just lost) > contested
frontier > enemy frontier > deep enemy, gated by `IsFrontier` (a flag adjacent to
one this team already holds — synthesized from `flag_sectors.lua` coordinates,
not a real pathing graph). `GroupHomeGraceSec` keeps groups from beelining the
enemy base in the first 240s. The non-negotiable invariant (learned from a past
regression, see roadmap): the filter chain must never return `nil` while any
attackable flag exists — always fall back a stage rather than stall the group.

### 4. Trickles (between-wave, idle-only, ≤1 spawn/tick, priority-ordered)
MG point defense, artillery/mortar/tank-destroyer/sniper keep-alive (the latter
four share the `TryCappedTrickle` helper: cap, interval, live-count fn, unit
picker, optional `FactionBias` floor and `phaseGate`), officer/AT-rifle/
assault-gun/support-vehicle keep-alive, neutral-flag cappers (commit to one
flag until capped or lost — `CapperTarget`), airborne deep-strike (late-phase
only, gated separately from the normal wave/tier system), and ratio backfill.
Each has its own interval + cap constant near the top of `bot.lua`.

### 5. Offline data generation (`tools/`)
Python scripts read RobZ's own `.set`/mission files and emit generated Lua
tables — `flag_sectors.lua` (map flag coords/sectors/bases via
`build_sectors.py`), unit metadata (`build_unit_meta.py`), artillery roster
(`build_arty_roster.py`), and aim-time tuning (`build_aim_time.py`). These are
dev-time only; nothing in `bot.lua` shells out or regenerates data at runtime.
Each has a matching `test_build_*.py`.

### 6. Tests (`resource/script/multiplayer/tests/`)
Offline stock-Lua specs (no game engine) covering phase/tier decisions, group
routing, frontier/sector logic, the game clock, capper commitment, partition
logic, and an end-to-end integration spec through `GetUnitToSpawn`. Run via
`lua tests/<name>_spec.lua`; `harness.lua` is the shared assertion helper.

## Known gaps (tracked in roadmap, not yet closed)

- **Team-index / lateral partition**: `PartitionFlags` needs each bot's rank
  within its team to deconflict teammates' targets. The engine exposes no
  teammate roster and playerId is not reliably contiguous by team, so
  partition currently degrades to "own everything" (safe, non-crashing, just
  not deconflicted) whenever contiguity doesn't hold. A scratch-file
  roster-exchange channel is the proposed fix, not yet built.
- **Unit roster checker** (`docs/superpowers/plans/2026-07-01-unit-roster-check.md`):
  a dev-time CLI to validate faction rosters against `bot.data.lua`; in
  progress per `.superpowers/sdd/task-4-report.md`.
