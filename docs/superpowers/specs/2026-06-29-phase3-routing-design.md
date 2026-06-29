# Phase 3 — Routing Layer Design

**Date:** 2026-06-29
**Status:** Approved design, ready for plan
**Goal:** Make the group attack target obey a defensive-first priority ladder built from the
Phase 1 sector labels, Phase 2 lateral partition, and a new offline flag-adjacency graph, so
bots defend home, hold their lane's contested frontier, then expand to the nearest flag.

## Background

The engine's only movement primitive is `BotApi.Commands:CaptureFlag(squad, flagName)`; all
tactical intelligence lives in WHICH flag each squad is ordered to take. With `MaxGroups = 1`,
the single group's target (`PickGroupTarget`) drives the bulk of a bot's army, so that is the
sole routing lever this phase changes.

Today `PickGroupTarget` considers only enemy-occupied flags, prefers the most-recently-lost
(recapture), else by static priority. It has no notion of distance or adjacency, so a group can
be sent to a deep enemy flag and march past intermediate enemy flags without ever advancing the
front. This phase replaces that ordering with an explicit priority ladder.

Inputs already shipped:
- `Context.FlagLabel[name] = {sector, rank, axis, x, y}` — Phase 1. `sector` is team-oriented:
  `myAxis < 0.4` OWN, `0.4 <= myAxis < 0.6` CONTESTED, `myAxis >= 0.6` ENEMY.
- `Context.FlagOwner[name] = {band, shared, mine, lat}` — Phase 2 lateral partition. `mine` is
  this bot's left/right lane (plus shared middle margin). On an untrusted player slot the
  partition degrades to own-all (`mine == true` everywhere) — best-effort, not a blocker.
- `Context.LostStamp[name]` — existing per-flag timestamp of when this bot's team last lost it.

New input this phase: an offline flag-adjacency graph (`nb`) plus base adjacency (`base`),
precomputed into `flag_sectors.lua`.

## Decisions

- **Single lever:** only `PickGroupTarget` changes. Cappers (neutral-seeking),
  defenders (hold owned), and `GetFlagToCapture` are unchanged — different jobs.
- **Adjacency is precomputed offline** into `flag_sectors.lua` (no runtime distance math). On an
  unmapped map the graph is absent, so frontier logic no-ops and routing degrades to today's
  behavior.
- **Distance threshold 2000 units, with a 2-nearest-neighbor floor** so no flag is ever isolated
  on a differently-scaled map. Validated on bastogne (nearest-neighbor spacing 1074-1795; at 2000
  every flag has 2-4 neighbors, zero isolated; 1500 isolates f5/f6; 3000 over-connects).
- **Base adjacency uses the same 2-nearest floor:** each base labels its 2 nearest flags (unioned
  with any flag within 2000) with that base's team letter. Bases sit farther back than flags
  (bastogne's nearest flag-to-base is 2737 > 2000), so a pure distance rule would label none;
  the 2-nearest floor guarantees each base's home flags are marked (bastogne: a→f5,f6; b→f4,f8,f10).
- **Partition is best-effort:** trusted bots filter to `mine`; untrusted bots keep all (own-all).
  No team-index fix this phase (deferred; see roadmap).
- **The ladder is a tier score over a candidate set, not hard filters.** Tier 3 is a catch-all, so
  `PickGroupTarget` never returns nil while any candidate exists — the non-negotiable rule from
  this repo's history (a prior frontier filter was removed for returning nil and stalling squads
  at spawn).

## Candidate set

```
C = { enemy-occupied flags }  union  { neutral flags F where Context.LostStamp[F] ~= nil }
    minus excludeName
```

`enemyHeld(F)`   := `F.occupant == enemyTeam`
`enemyAttacking(F)` := `F.occupant` is neutral (neither team) AND `Context.LostStamp[F] ~= nil`
(the engine exposes no "under attack" state; a flag we recently held now gone neutral is the
detectable proxy for the enemy contesting it.)

Both are attackable: `CaptureFlag(squad, F)` on a neutral or enemy flag is a valid order
(`FlagAttackable` is `occupant ~= myTeam`).

## Priority ladder

For each `F` in `C`, assign a tier; pick the minimum tier, then the tie-break key.

| Tier | Condition | Meaning |
|---|---|---|
| 1 | `sector(F)==OWN` AND (`enemyHeld(F)` OR `enemyAttacking(F)`) | Home invaded or under attack — retake first, regardless of lane (collective defense) |
| 2 | `mine(F)` AND `frontier(F)` AND `sector(F)==CONTESTED` AND (`enemyHeld(F)` OR `enemyAttacking(F)`) | My lane's contested frontier under enemy control/attack |
| 3 | otherwise | My home + lane frontier are secure — expand to the closest next flag |

Tie-break within a tier:
- **Tier 1, 2:** `myAxis` ascending (closest to own home first), then `name`.
- **Tier 3:** distance from `F` to the nearest flag this bot's team currently owns, ascending
  (the literal "closest next flag"), then `name`. If coordinates are unavailable (unmapped map),
  fall back to today's ordering: most-recently-lost (`LostStamp` descending), then static
  `GetFlagPriority`, then `name`.

`frontier(F)` := any flag in `F.nb` is occupied by this bot's team, OR `F.base` lists this bot's
team letter (F is adjacent to our own base). Requires the offline graph; absent ⇒ false.

## Architecture

```
            OnGameStart                                  per-Quant
                |                                  (UpdateGroupTargets)
        +-------+--------+                                 |
   LabelFlags        PartitionFlags                        v
   FlagLabel{x,y,        FlagOwner{              PickGroupTarget(excludeName)
   sector,rank,          band,shared,mine}                 |
   axis, nb, base}            |               C = enemy-held  U  (neutral & LostStamp)
        ^                     |                             |
        |                     |                   tier(F):  1 home invaded/attacked
   flag_sectors.lua           |                             2 mine & frontier & CONTESTED
   (build_sectors.py          |                               & (held|attacked)
    emits nb + base)          |                             3 else -> closest next flag
        |                     |                             |
   IsFrontier(F) <------------+               pick min tier, then tie-break key
   reads FlagLabel.nb occupant                              |
   + FlagLabel.base vs my team                              v
                                              group.target  (nil only if C empty)
                                                            |
                                                            v
                                       CaptureFlag(squad) -> Commands:CaptureFlag
```

## Data flow

```
build_sectors.py:  for each flag  nb = {flags with dist < 2000}  U  {2 nearest}   (symmetric)
                                   base = { team letters whose base lists this flag among
                                            its 2 nearest, U any base within 2000 }
        |  (offline)
        v
flag_sectors.lua:  Sectors[map].flags[f] = {x, y, axis, nb={...}, base={...}}
        |  OnGameStart
        v
LabelFlags copies nb + base into Context.FlagLabel[f]   (alongside sector/rank/axis/x/y)
        |  runtime, per Quant
        v
PickGroupTarget: build C, score each F by tier + tie-break, return best
        |
        v
UpdateGroupTargets sets group.target  ->  CaptureFlag issues the order
```

## Components

1. **`build_sectors.py`** — for each flag compute `nb` (flags within 2000 units, unioned with the
   2 nearest, made symmetric) and `base` (list of team letters `"a"`/`"b"` whose base a1/a2/b1/b2
   counts this flag among its 2 nearest, unioned with any base within 2000 units). Emit both into
   each flag entry. Regenerate the 4 maps.
2. **`flag_sectors.lua` schema** — each flag entry gains `nb = {"f7","f8"}` and optional
   `base = {"a"}`. Generated file; data values for x/y/axis unchanged.
3. **`LabelFlags`** — copy `nb` and `base` from the matched sector entry into
   `Context.FlagLabel[name]` (today it copies sector/rank/axis/x/y). Unmapped/absent ⇒ no nb/base.
4. **`IsFrontier(name)`** (new global) — true if any neighbor in `Context.FlagLabel[name].nb` is
   occupied by `BotApi.Instance.team`, or `Context.FlagLabel[name].base` contains the team letter.
   Returns false when the flag has no label or no `nb` (unmapped map).
5. **`PickGroupTarget(excludeName)` rewrite** — build candidate set `C`, score each by the tier
   ladder + tie-break, return the best flag name. Returns nil only when `C` is empty. `excludeName`
   (the other group's target) is still excluded so two groups never converge.
6. **Tie-break helper** — distance from a flag to the nearest team-owned flag, using `FlagLabel`
   x/y; nil when coordinates are missing (triggers the unmapped fallback ordering).

## Error handling / never-stall

| Condition | Behavior |
|---|---|
| Unmapped map (no `nb`/coords) | `IsFrontier` false; tier 1 still works by sector if labels exist, else all flags fall to tier 3 with the legacy LostStamp/priority tie-break — identical to today |
| No team-owned flag yet (early game) | `frontier` empty; base-adjacent flags still qualify via `F.base`; otherwise tiers 1/2 yield nothing and tier 3 picks the nearest/priority flag |
| Candidate set `C` empty (no enemy or recently-lost neutral flag) | `PickGroupTarget` returns nil — same contract as today; `UpdateGroupTargets` leaves the target unset |
| Untrusted partition slot | `mine == true` everywhere; tier 2 still works on a wider lane (own-all), never errors |

`PickGroupTarget` never returns nil while `C` is non-empty. No `nil` indexing: every `FlagLabel`
/`FlagOwner` access is nil-guarded before use.

## Testing

- **`build_sectors` (python)** — assert bastogne `f1.nb` contains its two nearest (`f8`, `f7`);
  adjacency is symmetric (if `f1.nb` has `f8` then `f8.nb` has `f1`); no flag has empty `nb`;
  a base-adjacent flag's `base` lists the correct team letter.
- **`routing_spec` (lua, new)** — construct a bastogne scene with chosen occupants and assert:
  - Tier 1: an OWN-sector flag held by the enemy is picked over any frontier/expansion flag.
  - Tier 2: with home secure, a `mine` CONTESTED frontier flag held by the enemy is picked over a
    deeper enemy flag.
  - `enemyAttacking`: a neutral flag with a `LostStamp` entry is a valid tier-1/tier-2 candidate;
    a neutral flag without a `LostStamp` is NOT in `C`.
  - Tier 3: with home and lane frontier secure, the closest (least distance-to-owned) enemy flag
    is picked.
  - Never-nil: a scene with one deep enemy flag and no frontier still returns that flag.
  - Untrusted partition (idx out of range): `mine` own-all, tier 2 still reachable, no error.
- Existing specs (`phase_spec`, `integration_spec`, `sector_spec`, `partition_spec`,
  `mapname_spec`) stay green.

## Out of scope

- Team-index reliability (scratch-file roster channel) — partition stays best-effort; deferred
  per roadmap, decided at a later iteration.
- Multi-group routing — `MaxGroups = 1`, so only one group target is computed; the `excludeName`
  path remains but is exercised only if `MaxGroups` is raised later.
- Capper / defender / `GetFlagToCapture` behavior — unchanged.
- Adding the 20 colliding maps' geometry to the sector table — separate follow-up.
