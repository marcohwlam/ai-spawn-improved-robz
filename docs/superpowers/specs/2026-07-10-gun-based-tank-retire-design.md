# Gun-Based Tank Retirement Design

Date: 2026-07-10
Status: Approved for planning

## Problem

The bot keeps spawning obsolete medium tanks late into the match. The reported case:
German (`ger`) keeps fielding the Panzer III N (short 75mm KwK 37 L/24) at ~33% of its
medium-armor picks even at the 25-40 minute mark, where it cannot penetrate enemy medium
or heavy armor and dies immediately.

### Root cause

Medium-tier tank selection collects every `weight="medium"` entry that is currently
unlocked and affordable into one priority-weighted pool (`bot.lua`, `GetRandomItem(cands, weightOf)`
near line 1483). Entries have a `min_income` floor and an `unlock` time floor, but no
upper bound. An early weak-gunned tank therefore stays in the pool for the entire match and
keeps diluting the pick share of the stronger tanks that unlock later.

Only `weight="medium"` units are affected. Light-tier units (no `weight` field) are selected
in a separate tier and do not crowd the medium pool, so they are out of scope.

## Principle

Retire a medium tank when its main gun can no longer penetrate the enemy armor that is on
the field by that time. Gun effectiveness, not chassis age, drives the decision:

- Autocannon / MG / scout guns (20-40mm): anti-infantry role, never retire.
- HE howitzer / close-support / flame (95mm CS, 105mm, 120mm, 152mm HE, flame): anti-infantry
  role, not an anti-tank gun, never retire.
- Short 75 L/24 (HEAT-limited): retire when your own long-gun medium is well established.
- 45-57mm AT: retire when a strict gun upgrade unlocks.
- Medium 75 (M3 L/40) and 76mm F-34: retire when an 85mm+ successor unlocks.
- Long 75 (L/43-48), US 76mm, 77mm, 85mm and larger high-velocity AT: effective all game, keep.

### Two overrides (approved)

1. **Heavy-armor soak.** A `HeavyTank`-class unit with a weak gun is kept regardless of gun,
   because its armor lets it absorb fire and contribute. Applies to: `kv1`, `m4a3e2_jumbo`,
   `mk4`, `churchill_mk_vii`, `pzkpfw756`.
2. **No-successor safety.** Never retire a unit if doing so leaves the faction with no
   medium-or-heavy armor at that time. Japan has no `HeavyTank` entries and a compressed
   medium tree, so Japan keeps every unit.

## Mechanism

Add an optional `retire` field (seconds of elapsed match time), symmetric to the existing
`unlock` field. One line in the pool eligibility filter (`bot.lua`, near line 1389):

```lua
local unlockOk = (unit.unlock == nil) or (elapsed >= unit.unlock)
local retireOk = (unit.retire == nil) or (elapsed <  unit.retire)   -- NEW
```

`retireOk` is AND-ed into the affordability/eligibility conjunction that gates entry into the
pool. Units with no `retire` field are unaffected (backward compatible).

```
time axis ->
     unlock                       retire
       |<-------- eligible -------->|
-------+----------------------------+-------------
     enters pool                 drops from pool (obsolete)
```

### Data flow

```
DecideTier -> build pool --[for each unit]-->
    affordable? - unlockOk? - retireOk? - phaseOk? - failCooldown?
         '-- all true -> byTier[tier]
                              '-- GetRandomItem(cands, weightOf)
    retired units never enter byTier.medium -> their priority share disappears
```

## Retire dataset

Timing is aligned to the unlock time of the successor that makes each unit obsolete.
Only `weight="medium"` weak-gunned units are listed. Everything else keeps its current
(no-`retire`) behavior.

| faction | unit | gun | retire | successor driving the timing |
|---|---|---|---|---|
| ger | pz3_m | 5cm KwK 39 L/60 | 950 | pz4h L/48 |
| ger | pz3n | short 75 L/24 | 1300 | Panther band |
| ger_ss | pz3_m_ss | 5cm L/60 | 830 | pz4g L/43 |
| ger_ss | pz3n_ss | short 75 L/24 | 1300 | Panther band |
| ger2 | pz3_ger2 | 5cm L/60 | 830 | pz4j L/48 |
| ger2 | t34_2_ger | 76mm F-34 | 1750 | Panther (pz5g_ger2) |
| usa | m4a3_75_seq | 75mm M3 L/40 | 1120 | m4a3e8 76mm |
| rus | t34_2_seq | 76mm F-34 | 1170 | t34_3 85mm |
| eng | cromwell_mk_iv_seq | 75mm ROQF | 1130 | m4a1_76w_eng 76mm |
| rus_guard | m4a2 | 75mm M3 (lend-lease) | 1170 | t34_3_guard 85mm |
| rus_guard | t34_2_guard | 76mm F-34 | 1170 | t34_3_guard 85mm |

### Verified keeps (do not add `retire`)

Confirmed against `entity.pak` unit `.def` ammo tables:

- `t34_3` / `t34_3_seq` / `t34_3_guard` — 85mm (`bullet85 aphebc`), not 76mm.
- `m4a3e8_seq` — 76mm (`bullet76 apcbc/hvap`), not 75mm.
- `pz4g` (ger_ss) — long 75 L/43 (`bullet75 ger apcbc`), a real AT gun.
- `cromwell_mk_vi` — 95mm CS howitzer (`bullet95 heat`), HE support.
- Heavy-armor soak keeps: `kv1`, `m4a3e2_jumbo`, `mk4`, `churchill_mk_vii`, `pzkpfw756`.
- All light-tier tanks, all HE/flame support tanks, and the entire Japanese roster.

## Testing

- `retire` boundary: a unit with `retire=T` is in the pool at `elapsed = T-1` and absent at
  `elapsed = T`.
- A retired weak-gun medium disappears from `byTier.medium` after its retire time while its
  long-gun successors remain.
- Regression: a unit with no `retire` field is selected exactly as before across all phases.
- Safety: at each faction's latest retire time, the medium+heavy pool is non-empty.
- Japan: no unit is retired.

## Out of scope

- Reclassifying short-75 support tanks out of the medium armor tier (the pinned `retire=1300`
  handles the reported symptom without a tier change).
- Retire values for light-tier units (they do not dilute the medium pool).
- New unit additions to fill any faction roster gaps.
