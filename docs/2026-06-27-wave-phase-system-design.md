# Wave Phase System Design

**Goal:** Drive the AI bot's wave composition through time-based phases and a four-tier
unit ratio, and make the spawn pool recharge-aware so the engine's per-unit cooldown
no longer wastes wave attempts.

**Scope:** Modifies `bot.lua` (selection logic) and `bot.data.lua` (per-unit recharge
data plus a phase config table). No engine or asset changes. Builds on the existing
wave spawner, capper trickle, and FieldUnits tracking.

---

## Background and findings

Three data facts, verified against the RobZ `.set` files, shape this design:

1. **`c(N)` is not an unlock time.** The baked `unlock=` values (taken from `c(N)`)
   are wrong. `c(N)` is a small coarse code (0/10/60/120), not a per-unit availability
   time. There is no "available at time T" field in the unit definitions. Units are
   available from match start, gated only by manpower cost and a recharge cooldown.

2. **`;Nsec` trailing comment = recharge cooldown.** After a unit is summoned it cannot
   be summoned again until `;Nsec` elapses. The value scales with unit power:
   supply trucks `;0sec`, light vehicles `;30-460sec`, medium tanks `;630-1200sec`,
   heavy tanks `;1620-2160sec`. Infantry squads carry no `;Nsec`; they use an inline
   `f(1.0)` factor and recharge effectively immediately.

3. **Recharge splits armor tiers cleanly inside `class=Tank`.** Light tanks
   (ke-nu 360, pz2l 420, m5a1 460) sit below medium tanks (pz3 630, cromwell 750,
   pz4h 950). The split point is **550 seconds**. `HeavyTank` is already its own class.

Consequence for the previous "phase by armor unlock time" idea: there is no unlock
time to key on, so phases use **fixed time bands** instead. Recharge is repurposed for
two jobs at once: a cooldown gate, and the light/medium tier boundary.

---

## Global Constraints

- Lua 5.1 (game engine). No external libraries. Syntax-check with `luac -p`.
- Read-only BotApi: cannot read the real manpower balance (`Income()` is a rate, not a
  pool). "Out of manpower" is inferred from consecutive Spawn failures.
- Engine accepts at most ~1 Spawn per quant tick; wave spawns must be spread across
  quants (already implemented).
- Quant rate is ~70/sec (verified). `QuantsPerSec = 70`.
- Cappers (single-soldier neutral-flag grabbers) stay exempt from the ratio and from
  recharge tracking. Unchanged by this design.

---

## Component diagram

```
                         OnGameQuant (each quant)
                                |
        +-----------------------+------------------------+
        v                       v                        v
  +-------------+      +------------------+       +----------------+
  | CurrentPhase|      |   Wave Driver    |       | Capper Trickle |
  | t -> phase  |      | 1 spawn / 7 quant|       | 5s, neutral pt |
  +------+------+      +--------+---------+       +-------+--------+
         |                      |                         |
         | phase params         | needs a unit            | single line inf
         v                      v                         v
  +--------------------------------------------+    Spawn(unit, 1)
  |            GetUnitToSpawn (pool)            |
  |  filters:                                  |
  |   (1) phase.armorCap   (block tiers > cap) |
  |   (2) recharge-aware   (skip cooling units)|<-- Context.LastSpawn[unit]
  |   (3) min_team / min_income                |
  |  select:                                   |
  |   DecideTier(phase.targets, field)         |<-- GetFieldCounts (no cappers)
  |   weighted pick within tier                |
  +----------------------+---------------------+
                         v
                  Spawn(unit, 32)
                         |
                         v  GameSpawn event
       LastSpawn[unit]=now ; FieldUnits[id]=entry
```

## Data flow

```
bot.data.lua
  Phases = {
    early = { upto=180,  targets={light=1,             infantry=4}, budget=12, armorCap="light"  },
    mid   = { upto=480,  targets={medium=1, light=2,   infantry=4}, budget=20, armorCap="medium" },
    late  = { upto=1e9,  targets={heavy=1, medium=1, light=2, infantry=4}, budget=30, armorCap="heavy" },
  }
  per unit: recharge=N   (baked from .set ;Nsec ; infantry recharge=0)
        |
        v
  each quant:  t = MatchQuants / 70
        |        t < 180        -> EARLY
        |        180 <= t < 480 -> MID
        |        t >= 480       -> LATE
        v
  field-state correction (never changes phase):
        IsLosing()      -> budget *= 1.5
        EnemyHasTanks() -> +0.15 deficit weight to medium & heavy (where allowed)
        |
        v
  pool filter: armorCap (tier <= cap) + recharge (now-LastSpawn >= recharge*70)
               + min_team + min_income
        |
        v
  DecideTier: pick tier with largest (target_share - actual_share) among
              phase-allowed tiers that have an eligible candidate; fallback infantry
        |
        v
  Spawn ok -> LastSpawn[unit]=now -> unit benched for recharge seconds
```

---

## Tier classification

A single function `TierOf(entry)` maps a unit to one of four tiers, or `nil` for aux.

```
TierOf(t):
  if t.class == Infantry and not t.flame   -> "infantry"
  elseif t.class == HeavyTank              -> "heavy"
  elseif t.class == Tank:
      if (t.recharge or 0) >= 550          -> "medium"
      else                                 -> "light"
  elseif t.class == Vehicle                -> "light"
  else                                     -> nil   -- aux: AT, MG, sniper, officer, AA, artillery, flame
```

Only the four named tiers participate in the ratio. Everything returning `nil` is
auxiliary and continues to be injected by the existing aux mechanism (`AuxChance`,
`AuxDivisor` cap, `AuxEligible` trigger). Cappers never reach `TierOf` for counting;
they are skipped in `GetFieldCounts`.

`armorCap` ordering for the phase gate: `infantry < light < medium < heavy`. A unit is
pool-eligible only if its tier rank is `<=` the phase's `armorCap` rank. Aux units are
not gated by `armorCap` (an AT team is allowed in EARLY against enemy armor).

---

## Phase composition targets

| Phase | Time band | heavy | medium | light | infantry | budget | armorCap |
|-------|-----------|-------|--------|-------|----------|--------|----------|
| EARLY | 0–180s    | –     | –      | 1     | 4        | 12     | light    |
| MID   | 180–480s  | –     | 1      | 2     | 4        | 20     | medium   |
| LATE  | 480s+     | 1     | 1      | 2     | 4        | 30     | heavy    |

`spacing` (quants between spawns inside a wave) stays constant at 7.

---

## Spawn selection: DecideTier

Replaces the old `DecideCategory` (the 4:1 core:tank rule).

```
DecideTier(phase, field):
  targets = phase.targets
  total_t = sum(targets values)                 -- e.g. LATE = 8
  total_f = sum(field[tier] for tier in targets) -- live units in the four tiers
  best, bestDeficit = nil, -1
  for tier, tgt in targets:
      target_share = tgt / total_t
      actual_share = (total_f > 0) and (field[tier] / total_f) or 0
      deficit = target_share - actual_share
      if EnemyHasTanks() and (tier == "medium" or tier == "heavy"):
          deficit = deficit + 0.15            -- field-state lean toward armor
      if deficit > bestDeficit and TierHasEligibleCandidate(tier):
          best, bestDeficit = tier, deficit
  return best or "infantry"                     -- infantry is always eligible
```

`TierHasEligibleCandidate(tier)` is true when the pool (after armorCap, recharge,
min_team, min_income filters) contains at least one unit whose `TierOf` equals `tier`.
This prevents picking a tier with nothing to spawn (e.g. all mediums on cooldown),
which would otherwise burn a wave slot on a guaranteed failure.

Within the chosen tier, the existing weighted pick applies: `priority`, times 1.5 for
`HeavyTank` / `ATTank` / `ATInfantry` when `EnemyHasTanks()`.

---

## Recharge-aware pool

- **Data:** every vehicle/tank entry in `bot.data.lua` gains `recharge=N` (seconds),
  baked from the `.set` `;Nsec` comment. Infantry and aux infantry get `recharge=0`.
  This replaces the wrong `unlock=` field, which is removed.
- **Tracking:** `Context.LastSpawn` is a table `unit -> MatchQuants`. On a successful
  `GameSpawn`, set `Context.LastSpawn[entry.unit] = Context.MatchQuants`.
- **Filter:** in `GetUnitToSpawn`, a unit is eligible only if
  `Context.MatchQuants - (Context.LastSpawn[unit.unit] or -1e9) >= (unit.recharge or 0) * QuantsPerSec`.
- **Cappers** do not record `LastSpawn` and are not subject to the filter, so map
  control always has bodies.

Effect: after a medium tank spawns, it is benched for its recharge, so the wave moves
to the next eligible unit instead of retrying the same locked one and tripping the
consecutive-failure detector.

---

## Field-state correction

Applied per wave; never changes the phase.

- `IsLosing()` (own flags < enemy flags): `WaveBudget = floor(phase.budget * 1.5)`.
- `EnemyHasTanks()`: `+0.15` to the deficit of `medium` and `heavy` tiers inside
  `DecideTier`, but only where `armorCap` already allows them. In EARLY (cap = light),
  the armor response is AT infantry via the unchanged aux path, not tanks.

---

## Integration points in bot.lua

1. `OnGameStart`: reset `Context.LastSpawn = {}`. No threshold computation (time bands
   are constants `EARLY_UPTO = 180`, `MID_UPTO = 480`).
2. New `CurrentPhase()` returns the phase table for the current `MatchQuants/70`.
3. New `TierOf(entry)` and updated `GetFieldCounts` to count by the four tiers
   (cappers skipped, aux not counted).
4. New `DecideTier(phase, field)` replaces `DecideCategory`.
5. `GetUnitToSpawn`: add the `armorCap` tier gate and the recharge gate to the pool
   filter; collect candidates by tier; call `DecideTier`.
6. Wave start in `OnGameQuant`: `WaveBudget` and spacing read from the current phase;
   apply the `IsLosing` multiplier.
7. `OnGameSpawn`: record `Context.LastSpawn[entry.unit]` for non-capper spawns.

---

## Debug logging

Extend the per-spawn line and wave markers so the next game can be reviewed:

- `WAVE` line adds `phase=<early|mid|late>` and `budget=<n>`.
- Per-spawn line adds `tier=<heavy|medium|light|infantry|aux>` and replaces the old
  `M/T/A` triple with the four tier counts `H=<n> Md=<n> L=<n> I=<n>`.
- Keep `CAPPER try=.. ok=..`.

Logging is removed once the phase and recharge behavior is confirmed in a real match.

---

## Testing

Lua has no unit-test harness here; verification is by syntax check plus in-game log
review.

1. `luac -p bot.lua` and `luac -p bot.data.lua` after every edit — must print nothing.
2. Static check: a small Lua snippet that loads `bot.data.lua` and asserts
   `TierOf` buckets a known sample correctly (pz2l -> light, cromwell -> medium,
   tiger -> heavy, riflemans -> infantry, sdkfz251 -> light).
3. In-game: play one match, then review the log for
   (a) phase transitions at ~180s and ~480s,
   (b) tier counts trending toward the per-phase target vector,
   (c) light tanks (pz2l class) actually appearing in EARLY/MID,
   (d) waves no longer ending early from recharge-driven failures,
   (e) leftover manpower near zero at match end.

---

## Out of scope

- Reading the real manpower pool (no API).
- Per-faction phase tuning (time bands are global; revisit only if a faction misbehaves).
- Aux composition tuning (snipers vs MGs vs AT mix) beyond the existing mechanism.
- Re-deriving phase boundaries from data (no unlock data exists; bands are fixed).
