# Airborne Deep-Strike Design

**Date:** 2026-06-30
**Status:** Approved design, pending implementation plan
**Scope:** One spec, one implementation phase. A late-game comeback mechanic that
drops airborne squads onto enemy base flags when the bot is being overrun.

## Goal

When the bot is losing badly in the late game, field elite airborne ("drop")
squads on a dedicated cooldown and send them straight at the enemy base flags,
chaining from one captured base to the next. Once every enemy base is taken, the
airborne squads fold into the main offensive and attack the main group target.

## Background

### Trigger intent

The bot should reach for airborne only as a comeback tool: late phase, and the
enemy holds more than 65% of all flags. Airborne is expensive and rare, so it
trickles on its own cooldown independent of the wave economy.

### Validated facts (this session)

- `BotApi.Commands:Spawn(unit, size)` takes only a unit name and a squad size.
  **There is no location parameter** -- the script cannot choose where a unit
  spawns; the engine places it. The `Context.SpawnFlags.isAirborne` flag is only
  a same-tick dedup gate (`bot.lua:800, 851, 1727`), not a placement control.
  So "spawn on the enemy base" is not literally possible. Airborne `*_drop`
  units instead deploy via the engine's parachute animation
  (`airborne_spawner` entity) after a short descent delay; we spawn the unit and
  immediately order it to attack the enemy base flag.
- Every faction roster carries `UnitClass.Airborne` `*_drop` rows
  (`bot.data.lua:77-78, 127, 176, 219-221, 260, 308`): `paratroopers_drop(eng)`,
  `stormtroopers_drop(eng)`, `elites_44_drop(ger)`, `elites_44_drop(ger_ss)`,
  `elites_drop(usa)`, `elites_101st_drop(usa)`, `paramarines_drop(usa)`,
  `paras_drop(rus)`, `elites_drop(jap)`.
- Each drop unit's call-in cooldown is `c(900)` = `{charge}` = 900 seconds. The
  mod author annotates a parallel `c(900)` line `;15 mins`, confirming `c()` is a
  seconds-valued cooldown. Effective cooldown is `900 x chargeFactor`: `x1` in
  standard custom (900s), `x0.2` in frontline (180s), `x0` in wave mode. The
  `c()` charge gates the human call-in menu; the bot's `Spawn()` API is not hard-
  gated by it (MG/artillery trickles call `Spawn()` freely). The bot's own
  cooldown is therefore a design choice, set to the frontline-equivalent value.
- `FlagAttackable(name)` returns true for any flag not owned by us
  (`bot.lua:1581`), so enemy base flags are valid `CaptureFlag` targets.
- Enemy base flags are labeled `sector == "ENEMY"` in `Context.FlagLabel`
  (`bot.lua:990`); flag world coords `x, y` are present for distance ranking.

### Tunables (approved)

| Constant | Value | Meaning |
|---|---|---|
| `DeepStrikePct` | 0.65 | trigger when `enemyFlags / totalFlags > 0.65` |
| `DeepStrikeIntervalSec` | 180 | cooldown between drops (frontline-equivalent of `c(900) x 0.2`) |
| `DeepStrikeCap` | 2 | max live airborne squads kept fielded |

## Architecture

```
                          OnGameQuant (main tick)
                                   |
                 +-----------------+------------------+
        existing trickles                  NEW: DeepStrikeTrickle()
      (MG / arty / capper / officer)                 |
                                          gate ALL of:
                                            CurrentPhase == "late"
                                            EnemyFlagPct() > DeepStrikePct (0.65)
                                            Elapsed - LastDeepStrikeTime >= 180
                                            LiveAirborneCount() < DeepStrikeCap (2)
                                                       |
                                          GetAirborneUnit()  <-- roster UnitClass.Airborne
                                                       |            (drawn by priority)
                                          Spawn(unit, MaxSquadSize)
                                          (isAirborne set; engine parachutes it in)
                                                       |
                                          queue { kind = "airborne", info = u }
                                          LastDeepStrikeTime = Elapsed()
                                          (on Spawn failure: FailCooldown[u.unit])
                                                       |
                                                 OnGameSpawn
                                          Context.AirborneSquads[id] = true
                                                       |
                                          every OrderRotationPeriod: CaptureFlag(squad)
                                                       |
                          +------------------(NEW airborne branch)----------------+
                          |  before the group / capper / defender branches        |
                          |  name = DeepStrikeTarget()                             |
                          |     -> enemy-HELD sector=="ENEMY" flag nearest our     |
                          |        territory (else none left? main group target)   |
                          |  if name and FlagAttackable(name): CaptureFlag         |
                          +-------------------------------------------------------+
```

## Data flow

```
[Scene.Flags] --count enemy/total--> EnemyFlagPct() ----+
[Elapsed]     --CurrentPhase-------> "late"? -----------+
[LastDeepStrikeTime] --cooldown elapsed (>=180)?--------+--> ALL true --> spawn
[AirborneSquads]     --LiveAirborneCount() < 2?---------+                  |
                                                                           v
                                       queue {kind="airborne"} ------> OnGameSpawn
                                                                           | AirborneSquads[id]=true
                                                                           v
   each OrderRotationPeriod:  CaptureFlag(squad) --> DeepStrikeTarget():
        scan Scene.Flags: IsEnemyFlag(flag) AND FlagLabel[name].sector == "ENEMY"
           -> rank by distance to our NEAREST owned flag (the same metric tier-3 of
              PickGroupTarget uses); if we own no flag, rank by axis ascending
              (closest-to-us enemy base first). No squad position API exists, so the
              target is anchored to our territory, not the individual squad.
           -> chain: as each enemy base falls it stops being enemy-held, so the next
              call naturally returns the next-nearest enemy base
        no enemy-held ENEMY flag remains:
           -> return Context.Groups[1] and Context.Groups[1].target  (main group target)
        target nil or not FlagAttackable: issue no order this tick (retry next rotation)

   dead-squad cleanup (OnGameQuant): Context.AirborneSquads[id] = nil
```

## Components

New constants (top-of-file, with the other tunables):
- `DeepStrikePct = 0.65`, `DeepStrikeIntervalSec = 180`, `DeepStrikeCap = 2`.

New `Context` fields:
- `LastDeepStrikeTime = 0` -- `Elapsed()` of the last airborne drop.
- `AirborneSquads = {}` -- `squadId -> true` for live deep-strike squads.

New functions:
- `GetAirborneUnit()` -- mirrors `GetArtyUnit` (`bot.lua:368`): collect roster
  rows where `class == UnitClass.Airborne`, return one by priority, or nil.
- `LiveAirborneCount()` -- count `Context.AirborneSquads` entries (the cap).
- `EnemyFlagPct()` -- `enemy / total` over `BotApi.Scene.Flags`; 0 when no flags.
- `DeepStrikeTarget()` -- enemy-held `sector == "ENEMY"` flag ranked by distance
  to our nearest owned flag (axis ascending when we own none); when no enemy base
  remains, `Context.Groups[1]` target; else nil. No per-squad position is read.
- `DeepStrikeTrickle()` -- the gated spawn block; called from `OnGameQuant`.

Touch points in existing code:
- `OnGameQuant` (`bot.lua:1377`): call `DeepStrikeTrickle()` as an independent
  trickle (runs even during a wave, like the capper/officer trickles), since its
  trigger differs from the MG/arty idle trickles.
- `OnGameSpawn` (`bot.lua:1723`): add a `kind == "airborne"` case that sets
  `Context.AirborneSquads[args.squadId] = true`. Airborne squads do NOT join a
  group (`d.slot` is absent), so they route through the new CaptureFlag branch.
- `CaptureFlag` (`bot.lua:1673`): add an airborne branch BEFORE the group branch
  -- if `Context.AirborneSquads[squad]`, route by `DeepStrikeTarget`.
- Dead-squad cleanup (`bot.lua:1559`): also clear `Context.AirborneSquads[id]`.

## Testing

New `tests/airborne_spec.lua` (mirrors `arty_spec.lua` / `capper_spec.lua`):
1. `EnemyFlagPct` -- counts enemy/total correctly; 0 with no flags; >0.65 case.
2. `GetAirborneUnit` -- returns an Airborne row from the harness roster; nil when
   the roster has no airborne.
3. `LiveAirborneCount` -- counts only `AirborneSquads` entries.
4. `DeepStrikeTarget` -- with two enemy `sector=="ENEMY"` flags returns the
   nearest; after the nearest is owned, returns the next; with no enemy base left
   returns `Context.Groups[1].target`; nil when neither exists.
5. `CaptureFlag` airborne routing -- a registered airborne squad is ordered to
   its DeepStrikeTarget; falls back to the main group target; issues no order
   when the target is nil / not attackable.
6. Trigger gate assertions -- the pieces `DeepStrikeTrickle` depends on
   (`EnemyFlagPct > 0.65`, `CurrentPhase == "late"`, cooldown, cap), mirroring
   the arty trickle-gate test style.

All 11 existing specs must continue to pass.

## Out of scope

- True paradrop placement at chosen coordinates (engine does not expose it).
- Changing game data / unit `.def` files.
- Airborne participation in the normal wave/group economy (deep-strike squads are
  standalone, never group members).
- Retreat / survival logic for the airborne squad after its run.
