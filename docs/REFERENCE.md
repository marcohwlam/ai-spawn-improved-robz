# Reference

Filesystem paths, log locations, RobZ data sources, and a glossary of game/API and
mod-internal terms. Two sections: [Paths](#paths) and [Glossary](#glossary).

## Paths

Authoritative values discovered by inspection. Prefer these over re-derivation.

| What | Path |
|---|---|
| Repo (source of truth) | `/home/lamho/Documents/repos/ai-spawn-improved-robz` |
| Deployed mod (game reads this; symlinked to repo) | `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/` |
| Bot brain (spawn logic) | `resource/script/multiplayer/bot.lua` |
| Bot static data (unit roster, fields) | `resource/script/multiplayer/bot.data.lua` |
| Generated per-map flag data | `resource/script/multiplayer/flag_sectors.lua` |
| Offline test harness + specs | `resource/script/multiplayer/tests/` (harness.lua + `*_spec.lua`) |
| Run a test | `cd resource/script/multiplayer && lua tests/<name>_spec.lua` |
| AI economy tuning (income rates) | `resource/set/multiplayer/games/bots_generic.inc` |
| LIVE game log (THE log to read after a match) | `/mnt/storage/steam/steamapps/compatdata/244450/pfx/drive_c/users/steamuser/Documents/my games/men of war - assault squad 2/log/game.log` |
| Game profile / replays | `/mnt/storage/steam/steamapps/compatdata/244450/pfx/drive_c/users/steamuser/Documents/my games/men of war - assault squad 2/profiles/45105821/` |
| Stale/unused log (do NOT use; last written 2026-06-28) | `/home/lamho/mowas-aispawn.log` |
| Game install dir | `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2` |
| Base game entity paks (unit `.def` gun/ammo tables; zip format) | `resource/entity/{e1,e2,c1,c2}.pak` under the game install |
| RobZ Realism Mod (base mod this AI runs alongside; source of real unit MP costs) | `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/` |
| RobZ resource paks | `<robz>/resource/{entity,gamelogic,...}.pak` (zip) |
| RobZ MP breed sets (infantry perks/skins; NOT vehicle cost) | inside RobZ `gamelogic.pak` under `set/breed/mp/<faction>/*.set` |
| Steam AppID | `244450` |
| Proton prefix | `/mnt/storage/steam/steamapps/compatdata/244450/pfx/` |
| Steam Workshop content | `/mnt/storage/steam/steamapps/workshop/content/244450/` |

### Notes on unit MP cost

Unit MP cost (the real manpower price) is NOT in the entity `.def` files and NOT in the
base-game breed sets. The authoritative source is the RobZ mod's multiplayer economy
resources (RobZ `gamelogic.pak`). The exact cost-table file is still to be pinpointed.

The engine exposes NO API to read the current MP balance. The only economic reads
available to the bot are the income RATE (`BotApi.Commands:Income`) and the pass/fail
result of `BotApi.Commands:Spawn`.

### Extracting a file from a pak

Paks are zip archives:

```sh
cd <dir with pak>
unzip -o <file>.pak '<glob>' -d <outdir>
```

Internal vehicle paths begin with a literal leading dash (e.g. `-vehicle/...`), so match
by suffix rather than full path: `unzip -o entity.pak '*name.def' -d out`.

## Glossary

Grounded in `bot.lua`, `bot.data.lua`, and `ARCHITECTURE.md`. Where the code and prior
notes disagree, the code wins and the correction is called out.

### Data fields (`bot.data.lua` unit rows)

| Field | Meaning |
|---|---|
| `unlock` | Earliest elapsed match-seconds a unit may spawn (time gate). Checked as `elapsed >= unit.unlock` in `GetUnitToSpawn`. Omit = eligible from t=0. |
| `retire` | Elapsed seconds at which a unit drops from the spawn pool (obsolete gun/chassis). Checked as `elapsed < unit.retire`. See correction below. |
| `min_income` | A threshold on the income RATE, used as an affordability proxy in pool eligibility: a unit is eligible only while `income >= min_income`. See "why this is imperfect" below. |
| `min_team` | Minimum `teamSize` for the unit to be eligible (`teamSize >= unit.min_team`). Gates expensive units (most heavy tanks) to team games; `min_team=2` restricts to 2v2+. Omit = 0. |
| `priority` | Weight for the weighted-random pick (`GetRandomItem`) within whatever candidate set the unit lands in (its tier bucket, or an aux picker). Higher = picked more often. Not a hard order. |
| `weight` | On `UnitClass.Tank` rows only: sub-classifies the tank for `TierOf`. `"heavy"`/`"sheavy"` -> heavy tier; `"medium"` -> medium tier; absent/other -> light tier. |
| `class` | The unit's `UnitClass` (infantry, tank, heavy-tank, at-tank, artillery-tank, mg, mortar, sniper, officer, vehicle, airborne, ...). Drives tier classification, which picker collects it, and defender routing. |
| `arty` | Artillery subtype (`"field"`/`"heavy"`/`"rocket"`) on `ArtilleryTank` rows. Selects firing reach (`ArtyReach`) for rear-flag placement. |
| `assault` | On `ArtilleryTank` rows: marks a direct-fire close-support gun (StuH42, Brummbär, SU-122, ...) that escorts the main group via the assault-gun trickle, instead of parking at a rear artillery flag. Excluded from `GetArtyUnit`. |
| `support` | Marks a scout/utility half-track routed to the aux pool and to its own support-vehicle keep-alive trickle. `TierOf` returns nil for it, so it never fills a "light" tank slot. |
| Other row flags | `line` (cheap line infantry, used by capper/line pickers), `inf="rifle"/"smg"` (infantry sub-tier for the ratio), `mech=true` (mounted infantry; still infantry, leaned toward from mid), `elite=true` (early-only, capped 1/group), `flame=true`. |

Correction: a prior note said `retire` "now applies to weight=medium tanks AND tank
destroyers (`UnitClass.ATTank` via `GetAtTankUnit`)." The source does not support the
tank-destroyer half. `GetUnitToSpawn`'s `retireOk` check is generic (it honors `retire`
on any row that carries it), but in the shipped `bot.data.lua` the `retire` field is
present only on `weight="medium"` `Tank` rows. `GetAtTankUnit` (the tank-destroyer
picker) does not read `retire` at all, so no tank destroyer currently retires.

Why `min_income` is an imperfect affordability proxy: it gates on the income RATE (MP per
unit time), not on the current MP balance and not on the unit's cost. A unit can pass
`income >= min_income` and still fail `Commands:Spawn` because the actual MP balance is
drained. The rate says "the economy is large enough that this unit is plausibly
affordable over time"; it cannot say "you can pay for it right now."

### Economy / API terms (`bot.lua`)

| Term | Meaning |
|---|---|
| `Elapsed()` / `Context.GameClock` | Match-seconds clock. `AdvanceClock` accumulates real seconds between quant ticks, skipping gaps > `PAUSE_CLAMP` (2s) and backward steps, so it is pause-immune (frozen while the sim is paused). |
| `BotApi.Commands:Income(playerId)` | The income RATE (MP per unit time). The only economic read the engine exposes. There is no balance-read API. |
| `BotApi.Commands:Spawn(unit, count)` | Issues a spawn; returns true/false. A false return (or a claimed-but-unconfirmed spawn) is the ONLY real signal that the MP balance could not cover the unit. Confirmed asynchronously later via `OnGameSpawn`. |
| `BotApi.Commands:EnemyHasTanks()` | True if the enemy fields armor. Adds an armor lean in `DecideTier` and gates the AT-infantry / tank-destroyer trickles. |
| `BotApi.Commands:CaptureFlag(squad, flagName)` | Orders a squad to capture a flag. Used by group routing and cappers. |
| `BotApi.Scene.Flags` | This bot's view of every flag; each has `.name` and `.occupant` (the only fields the engine exposes). `.occupant` compared against `Instance.team` / `Instance.enemyTeam` yields captured / enemy / neutral. |
| `BotApi.Scene.Squads` | Every squad this bot currently controls (scoped to this player, not the whole match). |
| `BotApi.Scene:IsSquadExists(squad)` | Liveness check before re-issuing an order to a squad. |
| `BotApi.Instance` | This bot's identity: `.team`, `.enemyTeam`, `.army` (faction key, e.g. `ger_ss`), `.teamSize`, `.hostId`, `.playerId`. |

Events (engine callbacks):

| Event | Role |
|---|---|
| `OnGameStart` | Once per match. Re-seeds `Context`, reads the map, labels/partitions flags, seeds groups. No state persists across matches. |
| `OnGameQuant` | Per-tick brain. Advances the clock, tracks lost flags, updates group targets, drives the in-progress wave or the idle trickles. |
| `OnGameSpawn` | Async spawn confirmation. The engine confirms a `Spawn` here, typically 1+ quants after it was issued, and the squad gets its group/role assignment. |
| `OnGameStop` | End of match. |

The engine confirms a `Spawn` asynchronously, so the bot never assumes a spawn landed in
the same quant it was requested (see the spawn-confirmation gate below).

### Core concepts (`bot.lua`)

Tiers and `TierOf(t)`: reduces a unit row to a ratio tier, or nil for aux.
- `HeavyTank` -> `heavy`.
- `Tank` with `weight="heavy"`/`"sheavy"` -> `heavy`; `weight="medium"` -> `medium`; otherwise -> `light`.
- `Vehicle` -> `light`.
- Infantry (non-flame) -> `smg` or `rifle` by the `inf` field; `mech=true` stays infantry, not light.
- Aux classes (`ATTank`, `ATInfantry`, `MG`, `Sniper`, `Officer`, `AATank`, `ArtilleryTank`, flamer, and `support=true` vehicles) -> nil, and do not count toward the infantry:tank ratio.

Groups:
- `Context.Groups[1]` is the main prong, `Context.Groups[2]` the sub prong (max `MaxGroups`=2). The sub is created only once the main is full.
- Group members follow `group.target` (a flag name), re-issued when the target changes.
- `auxMembers` ride along with a group without filling its combat cap (`GroupMemberCount` excludes them), so an escort MG/AT does not consume a 5/3 combat slot.
- `Context.SquadGroup` maps squadId -> group index.

Trickles (between-wave, idle-only, at most one spawn per tick, priority-ordered): capper,
defender (MG), attank (tank destroyers), arty, mortar, sniper, officer, AT-rifle,
assault-gun escort, support-vehicle, airborne deep-strike. Each has its own cap and
interval constant. The arty/mortar/attank/sniper trickles share the `TryCappedTrickle`
helper (cap, interval, live-count fn, unit picker, optional `FactionBias` floor and
`phaseGate`).

Phases: `early` / `mid` / `late`, resolved per-faction by `ResolvePhases` (from
`FactionPhases`) and selected by `CurrentPhase(Elapsed())`. Each phase carries tier
`targets` (tier -> weight), a `budget` (units attempted per wave), a `waveMult` (wave-gap
stretch: early 1.0 / mid 1.5 / late 2.25), a `squadCap`, and group sizes. Time bounds are
the per-faction `mid`/`late` seconds.

Flag economy:
- `FlagDeficit()` = enemy flags minus own flags (negative = ahead).
- `IsLosing()` = `FlagDeficit() > 0`.
- `FlagWinPct()` = (our flag share − enemy flag share), clamped to ±1.5; feeds the wave cadence (winning lengthens the gap to bank MP, losing shortens it).

Caps (constants near the top of `bot.lua`):

| Cap | Value | Meaning |
|---|---|---|
| `ArtyCap` / `ArtyCapNow()` | 1 | Baseline live artillery; `ArtyCapNow` drops it to 0 while badly losing (`FlagDeficit >= BadlyLosingDeficit`=3) or while the armor-bank window is active. |
| `MortarCap` | 2 | Live hand-carried mortars. |
| `AtTankCap` | 1 | Live tank destroyers. |
| `DefenderCap` | 3 | Live MG teams. |
| `SniperCap` | 1 | Live snipers. |
| `OfficerCap` | 1 | Live officers (parked at spawn). |
| `MaxLiveSquads` | 24 | Hard ceiling on this bot's own live squads (aux counts 0.5); a phase's `squadCap` overrides per phase. |

Armor-bank window (`Context.ArmorBankUntil`, `ArmorBankSec`=90s): opened when a
`min_income`-eligible armor unit fails `Commands:Spawn` (the MP balance is drained).
While active, `GetUnitToSpawn` refuses to downgrade below the armor tiers (heavy/medium)
- it spawns armor if any is affordable, otherwise nothing, so MP banks toward it while
cappers keep lifting income. `ArtyCapNow` also zeroes artillery during the window. This
generalizes the older late-heavy slowdown (`SpawnSlowdownUntil`, `HeavyFailStreakLimit`)
to all armor, every phase.

Spawn-confirmation gate: only ONE unconfirmed spawn may be in flight at a time.
`SpawnSlotFree()` returns false while `Context.PendingSpawn` is set, blocking every
trickle and wave spawn until `OnGameSpawn` clears it, so the next confirmation is
unambiguously the one just issued. `PendingSpawnTimeoutQuants`=20: if no confirmation
arrives within 20 quants, the pending spawn is declared lost (`SPAWN_LOST`) and the slot
frees. This single-slot rule (not a FIFO) prevents out-of-order confirmations from
tagging the wrong squad with the wrong class.

### Log-line vocabulary

Every bot line is prefixed `[AISPAWN]`. Multiple AI bots write to one shared `game.log`,
so most lines carry `pid=<playerId>` for attribution.

Spawn-attempt lines (`try=<unit> ok=<bool>`, where `ok` is the engine's accept/reject of
`Commands:Spawn`):

| Tag | Emitted by | Meaning |
|---|---|---|
| `SPAWN` | wave fill (`AttemptSpawn("SPAWN")`) | A per-unit wave spawn attempt. Also carries `phase`, `income`, `squads`, and the field tier counts `H/Md/L/R/S/A`. |
| `BACKFILL` | idle backfill (`AttemptSpawn("BACKFILL")`) | A between-wave ratio-refill attempt, same line shape as `SPAWN`. |
| `CAPPER` | neutral-flag capper trickle | Single-soldier spawn sent to grab a neutral flag. |
| `DEFENDER` | MG defender trickle | MG team dug in on an owned flag. |
| `ATTANK` | tank-destroyer trickle | Via `TryCappedTrickle`, label `ATTANK`. |
| `ARTY` | backline artillery trickle | Via `TryCappedTrickle`, label `ARTY`. |
| `MORTAR` | mortar keep-alive | Via `TryCappedTrickle`, label `MORTAR`. |
| `SNIPER` | sniper keep-alive | Via `TryCappedTrickle`, label `SNIPER`. |
| `OFFICER` | officer keep-alive | Officer parked at spawn. |
| `ATRIFLE` | AT-rifle keep-alive | Anti-half-track AT rifle escort. |
| `ASSAULTGUN` | assault-gun escort trickle | Direct-fire close-support gun escorting the main group. |
| `SUPPORTVEH` | support-vehicle keep-alive | Support half-track escort. |
| `DEEPSTRIKE` | airborne deep-strike | Late-phase paradrop at an enemy base. |

Correction: a prior note grouped the wave attempt line under `WAVE ... try= ok=`. In the
source, `[AISPAWN] WAVE ...` is the wave-START header (`mq`, `t`, `phase`, `budget`,
`deficit`, `groups`) and carries no `try=`. The per-unit wave attempts are logged with
tag `SPAWN`.

Lifecycle / bookkeeping lines:

| Line | Meaning |
|---|---|
| `WAVE mq=... budget=... deficit=... groups=N` | A wave started (header, not a spawn attempt). |
| `CONFIRM squad=... kind=... unit=...` | `OnGameSpawn` confirmed a spawn and assigned it. |
| `CLAIM mq=... kind=... unit=... slot=... aux=...` | A spawn slot was claimed, pending confirmation. |
| `WAVE_END reason=<max_fails:<r>\|no_group_to_fill\|squad_cap> groups=N` | Why a wave ended: `max_fails` (MaxWaveFails=6 consecutive failed spawns, MP treated as spent; `r` is the last attempt result), `no_group_to_fill` (no group had a free slot), or `squad_cap` (`OwnedSquadCount` hit the phase `squadCap`). |
| `SPAWN_LOST try=<unit>` | A claimed spawn was NOT confirmed within `PendingSpawnTimeoutQuants` (20 quants). IMPORTANT: this means the engine never confirmed the spawn (it did not land), NOT that a deployed unit died. The AISPAWN log has no kill/death events. |
| `SPAWNSLOWDOWN heavy-fail-streak until=<t>` | The late-phase heavy-fail slowdown tripped; every interval-gated cadence doubles until time `t`. |
| `GROUP_NEW id=N target=...` | A group was created. |
| `GROUP_TARGET id=N target=... reason=<recapture\|priority\|stuck\|sub>` | A group re-picked its target. |
| `GROUP_FILL id=N tier=... try=... ok=... size=<n/cap>` | A wave/aux fill was assigned to a group; `size` is committed fills (live members + pending) over the group cap. |
| `GROUP_UP id=N phase=...` | A group advanced into a new phase. |
| `GROUP_END id=N [reason=stale_pending]` | A group was pruned (empty, or a stale pending fill was reclaimed). |
| `ASSAULTGUN_SPAWNED squad=...` | An assault-gun escort's `OnGameSpawn` landed. |
| `SECTOR` / `SECTOR_FALLBACK` / `PART` / `PART_FALLBACK` / `MAPPROBE` / `START_PROBE` | Startup flag-labeling, partition, and map-probe diagnostics (one-time, at `OnGameStart`). |

### How to read a match

Extract the `[AISPAWN]` lines from the live `game.log`, then grep for `WAVE_END`
reasons, `ok=false`, and `SPAWN_LOST` to see where the economy stalled or a spawn failed
to land.
