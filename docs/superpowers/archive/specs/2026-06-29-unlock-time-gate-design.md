# Unlock-Time Gate + recharge Decouple Design

**Date:** 2026-06-29
**Status:** Approved design, ready for plan
**Goal:** Gate the spawn pool on a per-unit unlock time so the bot stops attempting units before
RobZ unlocks them, and untangle the overloaded `recharge` field whose values are actually those
unlock times, by splitting its three roles into dedicated fields.

## Background

In Multiplayer Capture the Flag (`battle_zones`), RobZ Realism gates each unit behind an unlock
time: it cannot be spawned until that many seconds into the match. The bot has no model of this.
Its eligible-pool gate (`GetUnitToSpawn`, bot.lua:605-627) opens a tier by wall-clock phase only;
the heavy tier opens at the `late` boundary of 480s, but RobZ unlocks the German heavies at
1500-2160s. Between 480s and the real unlock, the bot pools a heavy, the picker selects it,
`BotApi.Commands:Spawn` is called, and the engine rejects it (`ok=false`). One match: 436 heavy
attempts, zero successes; the army never rebuilt.

### The real defect: `recharge` is three fields in one, holding unlock data

The `recharge` field in `bot.data.lua` does not hold cooldown durations. Its values are the RobZ
`;NNNNsec` unlock times, verified across the roster:

| Unit | bot.data `recharge` | RobZ `;NNNNsec` |
|---|---|---|
| pz4h_seq | 950 | ;950sec |
| pz5g | 1500 | ;1500sec |
| pz6e | 1750 | ;1750sec |
| sdkfz182b | 2160 | ;2160sec |

174 units have `recharge=0`; every non-zero value is a second-scale unlock time, not a 10-60s
cooldown. This single field is consumed in three unrelated ways:

1. **Timing (`cooled` gate, bot.lua:610-612):** `cooled = (last == nil) or (MatchQuants - last >= recharge*70)`.
2. **Tier weight (`TierOf`, bot.lua:328):** a `class=Tank` unit is `medium` if `recharge >= TierMediumRecharge` (550), else `light`. Heavier tanks unlock later, so their larger unlock-as-recharge crosses 550 and they read as medium. Unlock time is used as a proxy for tank tonnage.
3. **Storage:** the field is where the `;NNNNsec` value lives.

Why the "unlock via recharge" never worked, and is the 0/436 cause: in `cooled`, a never-spawned
unit has `last == nil`, so the first spawn bypasses the recharge term entirely. The unit is
attempted at the phase boundary (480s) and fails until RobZ actually unlocks it. After a spawn,
`recharge=1500` then locks re-spawn for 25 minutes, which was never the intent.

`recharge` has exactly two code consumers (bot.lua:328 and bot.lua:612) and `TierMediumRecharge`
exactly one (bot.lua:328, defined bot.data.lua:39). Nothing else reads them.

### Where the unlock and weight values come from in RobZ

- **Unlock:** the trailing `;NNNNsec` comment on each RobZ unit line. It matches the in-game
  anchors exactly (pz5g 1500, pz6bh/sdkfz182b 2160, pz4h_seq 950). No engine field or formula
  reproduces it (disproven: cost, cp, c(), fore, grow-budget); it is hand-tuned per unit, recorded
  only in the comment.
- **Weight:** the RobZ `t(...)` tag token, one of `light` / `medium` / `heavy` / `sheavy`
  (e.g. pz4h_seq `t(all 44 45 medium)`, pz5g `t(44 heavy)`, pz6bh `t(44 sheavy)`). This is RobZ's
  own authoritative tonnage class, the principled replacement for the recharge≥550 proxy.

## Decouple: one field becomes three

| Role | Old (overloaded) | New (dedicated) |
|---|---|---|
| Unlock timing | `recharge` via `cooled` (broken by `last==nil`) | `unlock` via a new `unlockOk` pool gate |
| Tier weight (Tank medium/light) | `recharge >= 550` in `TierOf` | `weight` (RobZ `t()` tag) in `TierOf` |
| Spawn cooldown | `recharge` (no real cooldown data exists; all values were unlock) | removed; `cooled` gate and `recharge` field deleted |

No real per-unit cooldown data exists, so the cooldown role has nothing to carry forward; the
`cooled` gate is removed. If a genuine re-spawn cooldown is ever wanted, it returns as its own
feature with real data.

## Scope

In scope:
- A generator that scrapes RobZ `;NNNNsec` and `t()` weight, injecting `unlock` and `weight` into
  `bot.data.lua`, cross-checking that existing `recharge == unlock`, then stripping `recharge`.
- `GetUnitToSpawn`: add the `unlockOk` term; remove the `cooled` term and its local.
- `TierOf`: Tank branch uses `weight` instead of `recharge >= TierMediumRecharge`.
- Remove the `TierMediumRecharge` constant.
- Python generator tests; Lua specs for the gate and for `TierOf`; in-game probe verification.

Out of scope (deferred to its own phase, by decision):
- The CP unit-cap gate (each live unit occupies `cp(N)` of a ~120 cap; a live Officer adds +40).
  Design note for that phase: the CP cap is DYNAMIC and cannot be a static per-unit field like
  `unlock`. The cap moves (a live Officer adds +40, lost on its death) and the consumed total
  moves every tick as units die and refund their `cp`. The gate must be evaluated against live
  state at the spawn-decision point: `consumed + unit.cp <= base + 40 * liveOfficers`, where
  `consumed` is the summed `cp` of this bot's live squads, recomputed each tick. The pool may hold
  several units that each fit individually; only one spawns per cycle, so the check belongs at
  spawn commitment and re-reads live cap and consumed each cycle.
- `min_income` semantics. It gates money `Income()`, unrelated to unlock or CP. Left as-is.
- Modes other than `battle_zones`. The gate is harmless elsewhere: a unit with no scraped `unlock`
  is available from t=0.

## Architecture

```
   tools/build_unit_meta.py             (offline; rerun when RobZ data changes)
        |  read RobZ gamelogic.pak -> set/multiplayer/units/**/*.set
        |  per unit line:  id (quoted token),  unlock = ;NNNNsec,  weight = t() tonnage token
        |  build map { id : {unlock, weight} }
        |  read bot.data.lua; for each line matching unit="<id>":
        |     assert existing recharge == unlock (warn on mismatch)   [first run only]
        |     inject/replace unlock=<sec>          (omit if no ;NNNNsec)
        |     inject/replace weight="<w>"          (only on class=UnitClass.Tank lines)
        |     strip the recharge=<n> token
        v
   bot.data.lua        units gain unlock + (Tank) weight; lose recharge; TierMediumRecharge removed
        |   { ..., unit="pz5g", class=UnitClass.HeavyTank, unlock=1500, min_income=2.0, ... }
        |   { ..., unit="pz4h_seq", class=UnitClass.Tank, weight="medium", unlock=950, ... }
        v
   bot.lua TierOf            Tank branch:  return (t.weight == "medium") and "medium" or "light"
   bot.lua GetUnitToSpawn    pool gate:    drop `cooled`; add `unlockOk`
        |   elapsed  = Context.MatchQuants / QuantsPerSec            (already computed, line 598)
        |   unlockOk = (unit.unlock == nil) or (elapsed >= unit.unlock)
        |   pool <- unit  iff  affordable and unlockOk and notRecentlyFailed
        |                       and capOk and phaseOk and eliteOk
        v
   A unit below its unlock time never enters the pool. Tank tier weight comes from RobZ, not
   from the (now removed) recharge proxy.
```

## Data flow

```
RobZ .set line:  {"pz4h_seq" ("v_seq" ... t(all 44 45 medium) ... ) {cost 500}} ;950sec
        |  build_unit_meta.py:  unlock <- /;\s*(\d+)\s*sec/ ;  weight <- tonnage token in t(...)
        v
meta map  { pz4h_seq={unlock=950, weight="medium"}, pz5g={unlock=1500, weight="heavy"}, ... }
        |  inject by anchor unit="<id>" into bot.data.lua ; strip recharge
        v
bot.data.lua  { unit="pz4h_seq", class=Tank, weight="medium", unlock=950 }
        |  loaded into units table
        v
TierOf(pz4h_seq):  class==Tank, weight=="medium"  -> "medium"
GetUnitToSpawn, per Quant:
   elapsed = MatchQuants / 70
        +-- elapsed <  unit.unlock  -> excluded (locked)
        +-- elapsed >= unit.unlock  -> eligible
        +-- unit.unlock == nil      -> eligible from t=0
```

## Components

1. **`tools/build_unit_meta.py`** (new; mirrors `tools/build_sectors.py`). Open the RobZ
   `gamelogic.pak` zip, read every text entry under `set/multiplayer/units/` (all factions).
   For each unit definition line extract: the unit id (first quoted token); `unlock` via
   `;\s*(\d+)\s*sec`; `weight` as the first of `sheavy|heavy|medium|light` appearing in the
   `t(...)` group. Build `{ id : {unlock, weight} }`; on a duplicate id with conflicting values
   keep the first and warn. Then edit `bot.data.lua` line by line, keyed on `unit="<id>"`:
   - If the line still has a `recharge=<n>` token, assert `n == unlock` for that id; on mismatch,
     do not strip and emit a warning naming the unit (protects against a real cooldown value).
   - Set/replace `unlock=<sec>` (omit the field entirely if the id has no `;NNNNsec`).
   - On `class=UnitClass.Tank` lines only, set/replace `weight="<w>"`.
   - Remove the `recharge=<n>` token (and its surrounding comma/space) once the assert passes.
   Write the file back. Idempotent: a second run finds no `recharge` token, skips the assert, and
   reproduces byte-identical `unlock`/`weight`. Print a report: counts injected/stripped, ids in
   bot.data with no RobZ match, recharge≠unlock mismatches, and Tank ids with no scraped weight.
   The RobZ pak path is a constant near the top with a `--robz-pak` override.

2. **`tools/test_build_unit_meta.py`** (new). From a fixture string of unit lines assert:
   `pz5g -> unlock 1500, weight heavy`; `pz4h_seq -> unlock 950, weight medium`;
   `sdkfz182b -> unlock 2160`; a line with no `;NNNNsec` yields no unlock. Injection: a sample
   bot.data Tank line with `recharge=950` gains `unlock=950 weight="medium"` and loses `recharge`;
   a second injection pass is byte-identical (idempotent); a line whose `recharge` differs from the
   scraped unlock is left with `recharge` intact and is reported.

3. **`bot.data.lua`** (modify, generator-produced). Each unit gains `unlock` where RobZ has one;
   each `class=UnitClass.Tank` gains `weight`; the `recharge` field is removed from all entries.
   The `TierMediumRecharge = 550` constant (line 39) is removed.

4. **`bot.lua` `TierOf`** (modify, line 327-328). Replace the Tank branch:
   ```lua
   elseif t.class == UnitClass.Tank then
       return (t.weight == "medium") and "medium" or "light"
   ```
   `HeavyTank -> "heavy"`, `Vehicle -> "light"`, and the infantry branches are unchanged.

5. **`bot.lua` `GetUnitToSpawn`** (modify, pool loop 605-627). Remove the `last`/`cooled` locals
   (610-612) and the `cooled` term from the conjunction. Add:
   ```lua
   local unlockOk = (unit.unlock == nil) or (elapsed >= unit.unlock)
   ...
   if affordable and unlockOk and notRecentlyFailed
       and capOk and phaseOk and eliteOk then
       table.insert(pool, unit)
   end
   ```
   `elapsed` is already in scope (bot.lua:598). `Context.LastSpawn` is still written elsewhere on
   spawn; only its read in the removed `cooled` term goes away. (Confirm during implementation that
   `Context.LastSpawn` has no other reader; if it has none, its bookkeeping write is dead and may
   be removed too, otherwise leave it.)

## Testing

- **`tools/test_build_unit_meta.py`** (Python): the scrape, inject, idempotency, strip, and
  mismatch-protection assertions above.
- **`unlock_spec.lua`** (Lua, new, in `resource/script/multiplayer/tests/`): a units table with one
  unit at `unlock=1500` and one with no `unlock`; drive the pool predicate at elapsed 1000 and 1600
  and assert the `unlock=1500` unit is absent at 1000, present at 1600, and the no-unlock unit and a
  `unlock == nil` unit are present at all times.
- **`tier_spec.lua`** (Lua, new): assert `TierOf` returns `medium` for a `class=Tank, weight="medium"`
  unit, `light` for `class=Tank, weight="light"` and for a Tank with no `weight`, and `heavy` for a
  `class=HeavyTank` unit. This pins the weight-based classification.
- **Existing specs** (`phase_spec`, `integration_spec`, `sector_spec`, `partition_spec`,
  `routing_spec`, `mapname_spec`, `frontier_spec`): stay green. Any fixture there that set `recharge`
  to obtain a `medium` tier must be updated to set `weight="medium"`; find these during
  implementation and convert them.
- **In-game probe verification** (the test gate before this phase is done): run one CTF match.
  Confirm (a) heavies produce no `ok=false` SPAWN lines before their unlock time, (b) at least one
  heavy reaches `ok=true` after its unlock time when headroom allows, and (c) the field composition
  (medium vs light tank mix) is sane after the `weight` reclassification. The existing SPAWN log line
  prints unit/ok/phase. If heavies still never spawn after unlock, that points at the deferred
  CP-cap constraint, not this gate.

## Error handling / edge cases

| Condition | Behavior |
|---|---|
| bot.data id absent from RobZ sets | No `unlock`/`weight`; unit available from t=0; Tank defaults to `light`; both listed in report |
| Unit line has no `;NNNNsec` | No `unlock` field; treated as available |
| `recharge` value differs from scraped unlock | Line left with `recharge` intact; reported; human reviews (guards a genuine cooldown) |
| Same id in multiple sets, conflicting values | Keep first; warn |
| `unit.unlock == nil` at runtime | `unlockOk` true; no behavior change |
| `class=Tank` with no scraped `weight` | `TierOf` returns `light` (the safe default); reported |

`unlockOk` is a nil check plus a numeric compare; no nil indexing. The generator never deletes
unit entries; it only edits the `unlock`, `weight`, and `recharge` tokens on matched lines.

## Decisions

- **Option B (full decouple), chosen over a minimal parallel `unlock` field.** The minimal option
  would duplicate the unlock value (in both `recharge` and `unlock`) and leave `recharge` driving a
  bogus 25-minute re-spawn lock and the tier classification. B splits the three roles into `unlock`,
  `weight`, and (removed) cooldown so each field means one thing.
- **Unlock source:** scrape RobZ `;NNNNsec`. **Weight source:** scrape the RobZ `t()` tonnage tag,
  RobZ's own authoritative class, replacing the recharge≥550 proxy. This can reclassify some tanks
  versus the old proxy; the generator reports the set and the in-game run verifies the composition.
- **`cooled`/`recharge` removed:** no real cooldown data exists; the role carried nothing forward.
- **CP unit-cap (officer +40) deferred** to its own phase as a live-state dynamic gate.
