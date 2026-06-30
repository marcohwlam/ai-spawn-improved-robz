# Artillery Spawn and Placement Design

**Date:** 2026-06-29
**Status:** Approved design, pending implementation plan
**Scope:** One spec, two implementation phases (A: spawn selection, B: range-aware placement)

## Goal

Make the AI bot field artillery again, and place each piece where its range can
actually reach contested flags. Today artillery is defined in the roster but
hard-disabled in the spawn picker, and the defender router ignores range
entirely. This design re-enables artillery as a controlled trickle and routes
each piece by its range tier.

## Background

### Current state

- `UnitClass.ArtilleryTank` exists and every nation table in `bot.data.lua`
  already carries 1-2 artillery rows in the standard field format
  (`priority`, `class`, `unit`, `min_income`, `min_team`, `unlock`).
- The picker classifies artillery as aux (`TierOf` returns `nil`) but then
  explicitly drops it from the aux pool in `GetUnitToSpawn` /  `collectAux`
  (`and t.class ~= UnitClass.ArtilleryTank -- SPGs disabled (poor bot AI use)`).
  Result: no artillery ever spawns.
- `DefenderClasses[ArtilleryTank] = true`, so if artillery did spawn it would
  route through the defender branch of `CaptureFlag`. That branch picks an owned
  flag by `DefenderFlagPriority`, which weights by ownership only (owned 3.0,
  neutral 1.0, enemy 0.5) with no distance, axis, or sector term.

### Validated facts (this session)

- All 34 artillery unit ids in the corrected roster exist in their declared
  nation's RobZ 1.30.10 multiplayer unit sets
  (`set/multiplayer/units/<nation>/*.set`), and each carries the engine
  `artillery` tag. Validation source is the mp-set, not entity `.def` names
  (`_guard` / `_ss` suffixes are defined at the mp-set layer).
- Engine `artillery` tags subclassify each piece: `rocket`, `heavyart` / `heavy`,
  or plain `artillery` (field gun / SPG).
- Weapon ranges (engine units, from `set/stuff/gun/.presets` and
  `set/stuff/reactive/*.weapon`): heavy howitzer 400, medium/field 300,
  small 250, rockets 180-310.
- Coordinate scale: 1 weapon `range` unit ~= 10 `flag_sectors.lua` world units
  (`world_reach = range x 10`). Five independent cross-checks converge on this
  factor; firmly bounded to [8, 12].
- The aim-time-0 work (already shipped) sets `PrepareTime 0` on all artillery
  presets, so a placed piece fires without the original wind-up. This is what
  makes static artillery useful enough to re-enable.

### Coverage analysis (2v2_bastogne, representative)

`reach = range x 10`, world units. Contested = flags with axis in [0.4, 0.6].

| Tier | reach | Contested reachable FROM BASE | FROM forward owned flag (f6) |
|---|---|---|---|
| rocket 180 | 1800 | none | f2, f7 (2) |
| rocket 310 / small 250 / field 300 | 2500-3100 | none | f1, f2, f4, f7 (4) |
| heavy 400 | 4000 | f7 only (grazes 1) | f1, f2, f4, f7, f8 (5, deepest) |

Conclusions:

1. Artillery parked at base reaches nothing. The existing "route to an owned
   flag, not base" behavior is correct and necessary.
2. From a forward owned flag every tier reaches the contested center. The
   differentiator is how far forward each piece must sit: short rockets must be
   at the frontmost owned flag; heavy artillery reaches from any owned flag and
   can sit safely in the rear. This is a placement concern, not a
   spawn-selection concern.

## Architecture

```
+---------------------- DATA layer (tools/build_arty_roster.py -> bot.data.lua) ----------------------+
|  Each ArtilleryTank row carries:  unit  priority  min_income  min_team  unlock  arty="rocket|heavy|field"
|  arty subtype derived from RobZ .set t(...) tag:  rocket -> 0.3 / heavyart|heavy -> 0.5 / plain -> 0.8
|  priority is set from the subtype; the arty field is read by BOTH spawn (A) and routing (B).
|  Single source of truth: one offline generator writes the rows; runtime never re-derives the subtype.
+--------------------------------------------+-------------------------------------------------------+
                                             |
        +------------------- A: SPAWN -------+---------+          +------------ B: PLACEMENT -----------+
        | Artillery defender TRICKLE (mirrors the MG   |  spawn   | CaptureFlag defender branch          |
        | defender trickle in the idle-between-waves   | -------> |   if class == ArtilleryTank:         |
        | window):                                     | as a     |     priFn = closure over entry ->    |
        |   GetArtyUnit() weighted by priority         | "trickle"|     ArtilleryFlagPriority(flag,entry) |
        |   gate: ArtyIntervalSec=45, LiveArtyCount()  | (NOT a   |   rocket -> frontmost owned flag      |
        |   < ArtyCap=1, HeldFlagCount()>0, mid+late    | group    |   heavy  -> rear/safe owned flag      |
        |   -> standalone defender, kind="trickle"     | member)  |   field  -> mild forward owned flag   |
        | GetUnitToSpawn / picker UNCHANGED            |          |                                      |
        +---------------------------------------------+          +--------------------------------------+
```

Why a trickle, not a picker injection: every wave spawn fills an attack
`Group` (`Context.FillGroup` is always set in the wave driver), and group
membership overrides the defender role in `CaptureFlag` — a grouped piece
chases the group's attack target and dies. The ONLY standalone-defender path
is the idle-between-waves trickle (used today by MG defenders and officers,
`kind="trickle"`). Artillery must use that path to reach the defender router.

## Data flow

```
BUILD (offline):
  RobZ mp-set t(...) tag --> arty subtype --> {priority, arty=} --> written into each bot.data.lua nation row

RUNTIME SPAWN (Phase A) -- in OnGameQuant's idle-between-waves window (WaveRemaining == 0):
  priority chain, at most one spawn per tick:
    MG defender trickle (existing)
      -> ARTILLERY trickle (new):
           if Elapsed() - LastArtyTime >= ArtyIntervalSec (=45)
              AND CurrentPhase in {mid, late}
              AND HeldFlagCount() > 0
              AND LiveArtyCount() < ArtyCap (=1):
                u = GetArtyUnit()                       -- roster ArtilleryTank, GetRandomItem by priority
                if u: Spawn(u) ; queue {kind="trickle", info=u} ; LastArtyTime = Elapsed()
                      (on Spawn failure: FailCooldown[u.unit] = Elapsed())
      -> combat backfill (existing)
  GetUnitToSpawn / the wave picker is UNCHANGED; the L657 collectAux exclusion of
  ArtilleryTank STAYS (artillery must never enter a group fill).

RUNTIME ROUTE (Phase B):
  SetSquadOrder timer -> CaptureFlag(squad):
    group member?  -> follow group target      (artillery must NOT be here; see constraints)
    capper?        -> capper path
    IsDefender?    -> if class == ArtilleryTank:
                        priFn = function(flag) return ArtilleryFlagPriority(flag, entry) end
                      else priFn = DefenderFlagPriority
                      flag = GetFlagToCapture(BotApi.Scene.Flags, priFn)
                      CaptureFlag(squad, flag.name)

  ArtilleryFlagPriority(flag, entry), using Context.FlagLabel[flag.name].axis (1 = most forward):
    not owned        -> small drift weight (keeps idle pieces from freezing, matches current behavior)
    entry.arty rocket-> owned weight dominated by high axis (frontmost owned flag wins)
    entry.arty heavy -> owned weight favors low axis (rear/safe; 4000 reach still covers center)
    entry.arty field -> owned weight mild forward lean
```

## Components

### Phase A: spawn selection (`bot.lua` + data)

Artillery spawns as a standalone defender trickle modeled on the existing MG
defender trickle (`GetMGUnit` / `LiveMGCount` / `DefenderIntervalSec` /
`DefenderCap`). The wave picker (`GetUnitToSpawn`) is not touched.

| Component | Approach |
|---|---|
| Constants | `ArtyIntervalSec = 45`, `ArtyCap = 1` near `DefenderIntervalSec` / `DefenderCap` |
| Context field | `LastArtyTime = 0` in Context init (mirrors `LastDefenderTime`) |
| `GetArtyUnit()` | Mirror `GetMGUnit`: from `Purchases[1].Units[army]`, collect rows with `class == UnitClass.ArtilleryTank`, return `GetRandomItem(arty, function(t) return t.priority end)` (tag priority biases which piece); `nil` if none |
| `LiveArtyCount()` | Mirror `LiveMGCount`: count `Context.FieldUnits` entries with `class == UnitClass.ArtilleryTank` |
| Trickle block | In `OnGameQuant`'s idle window (the `else` after `WaveRemaining > 0`), add a branch after the MG defender branch and before backfill: gate on `Elapsed() - Context.LastArtyTime >= ArtyIntervalSec`, `CurrentPhase(Elapsed()).name ~= "early"`, `HeldFlagCount() > 0`, `LiveArtyCount() < ArtyCap`; spawn via `GetArtyUnit()`, queue `{kind = "trickle", info = u}`, set `LastArtyTime`; on failure set `FailCooldown` |

`GetUnitToSpawn`, `TierOf`, `collectAux` (including its `ArtilleryTank`
exclusion at L657), and `DefenderClasses[ArtilleryTank]` are all unchanged.

### Phase B: placement (`bot.lua`)

| Component | Approach |
|---|---|
| `ArtilleryFlagPriority(flag, entry)` | New priority function. Owned flags weighted by `Context.FlagLabel[flag.name].axis` per the subtype profile below; non-owned flags get a small drift weight so a piece with no owned flag in range still moves forward instead of idling |
| Defender branch change | In `CaptureFlag`, when the defender is `ArtilleryTank`, pass a closure `function(flag) return ArtilleryFlagPriority(flag, entry) end` to `GetFlagToCapture`. `GetFlagToCapture`'s signature is unchanged; it already takes a pluggable priority callback |

Routing profiles (axis: 1 = frontmost / closest to enemy home; tunable):

- rocket: owned weight rises steeply with axis, so the frontmost owned flag
  dominates the draw. Short reach forces forward placement; exposure is accepted.
- heavy: owned weight favors low axis (rear). Decided: rear-biased to survive,
  since 4000 reach still covers the contested center from a rear owned flag.
- field: owned weight has a mild forward lean (between rocket and heavy).

### Data layer: `tools/build_arty_roster.py`

- Build, per nation, the union of existing artillery rows and the validated
  reference roster; deduplicate by unit id.
- For each row, read the engine `t(...)` tag from the RobZ mp-set, derive the
  `arty` subtype, set `priority` from the subtype, and set `min_team = 1`,
  `min_income` / `unlock` from the reference values.
- Write the rows into each nation table in `bot.data.lua` (this generator
  edits `bot.data.lua`; spawn handling is no longer deferred).
- Fold in the unit-id validator from this session as a regression check so the
  script fails loudly if a RobZ update removes or renames an id.

## Constraints and error handling

- **Artillery must spawn standalone**, never seeded into an attack Group. Group
  membership overrides the defender role in `CaptureFlag`, so a grouped piece
  would chase the group's attack target and die. The trickle path satisfies this
  by construction: it spawns outside the wave/group-fill loop and queues
  `kind = "trickle"` (the same path MG defenders use), so `Context.SquadGroup`
  is never set for the piece and `CaptureFlag` reaches its defender branch.
- **Spawn failure** reuses the existing `FailCooldown` mechanism; no new error
  handling.
- **Unknown maps**: `LabelFlags` already falls back to all-CONTESTED, so
  `Context.FlagLabel[name].axis` is defined everywhere. With no OWN flags,
  `ArtilleryFlagPriority` degrades to owned-flat (current defender behavior),
  which is safe.
- **Phase A without Phase B (interim, if phases ship separately)**: short
  rockets may land on a rear owned flag and waste their fire. The rocket
  priority of 0.3 already throttles rocket spawn rate, limiting the waste.

## Testing

- Lua spec `arty_spec.lua`:
  - `LiveArtyCount` counts only `ArtilleryTank` entries in `FieldUnits`.
  - `GetArtyUnit` returns only `ArtilleryTank` rows and `nil` when the roster
    has none; with multiple it draws by priority.
  - The trickle gate respects `ArtyCap` (no spawn when `LiveArtyCount >= 1`),
    `ArtyIntervalSec` (no spawn before 45s elapsed since last), the mid/late
    phase gate (no spawn in early), and `HeldFlagCount() > 0`.
  - `ArtilleryFlagPriority` ranks owned flags correctly for each of the three
    subtypes (rocket favors high axis, heavy favors low axis, field in between),
    and gives non-owned flags only the drift weight.
- Python `test_build_arty_roster.py` (plain-assert, repo convention):
  - dedup of existing + reference rows.
  - `t(...)` tag -> `arty` subtype -> `priority` mapping.
  - the 34-id validator passes against the current RobZ mp-set.

## Open tuning knobs (defaults set, adjustable later)

- `ArtyIntervalSec = 45` (artillery trickle cadence; MG defenders are 20s).
- `ArtyCap = 1` (max live artillery fielded at once; MG cap is 3).
- Subtype priorities: rocket 0.3, heavy 0.5, field 0.8.
- Routing axis curves per subtype (steepness of the forward / rear bias).
