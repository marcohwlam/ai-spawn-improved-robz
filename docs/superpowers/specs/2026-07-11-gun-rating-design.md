# Gun-Rating: field the best-penetration gun vs enemy armor

**Date:** 2026-07-11
**Status:** Design approved, pending spec review

## Goal

When the enemy fields armor, make the spawn picker prefer the highest armor-penetration
unit available within the tier it already chose, so the main push carries the best gun
that is unlocked at that moment instead of feeding out-gunned light vehicles into enemy
tanks.

## Problem (validated against RobZ data)

The picker chooses uniformly-by-priority within a tier. It has no notion of gun quality,
so an obsolete weak-gunned vehicle competes on equal footing with a superior-gunned one
even when the enemy has armor that the weak gun cannot penetrate.

Real RobZ numbers (default-AP peak penetration, from `set/stuff/gun/`):

| Unit | Gun | AP peak pen | Range |
|---|---|---|---|
| sdkfz222 | 2cm KwK30 | 46mm | 160m |
| m5a1 (US Stuart) | 37mm M6 | 78mm (APCR 107) | 180m |
| pz3_m | 5cm KwK39 | 97mm (APCR 150) | 190m |

The US 37mm out-penetrates and out-ranges the German 2cm; the German 5cm beats the 37mm.
The picker cannot express this ordering today.

## Non-goals (explicit scope boundary)

- **Does NOT create a gun that is not unlocked.** German has no 5cm before 630s; the
  460-630s "Stuart window" remains open. That is a roster/timing question, out of scope.
- **AP only.** No HE / anti-infantry rating in v1. Tanks are dual-purpose and infantry
  tiers already cover anti-inf. (User decision.)
- **No range term.** Penetration only.
- **No per-group role tracking.** The boost lives in the existing within-tier weighting
  hook, applied army-wide; groups keep their current member model.
- Does not change `DecideTier` (tier choice), `retire` (obsolete fade-out), bias floors,
  or the trickle system. Gun-rating layers on top of within-tier candidate weighting only.

## Architecture

Three components. An offline tool extracts penetration from RobZ into a generated Lua
table; the bot loads that table and consults it inside the existing candidate-weighting
function, gated on the enemy actually fielding tanks.

```
                         RobZ Realism Mod paks (read-only, offline)
                         ┌───────────────────────────────────────────┐
                         │ gamelogic.pak                             │
                         │   set/multiplayer/units/<faction>/*.set   │  unit_id -> breed
                         │   set/stuff/gun/<weapon>   (+ {from ...})  │  weapon -> AP pen
                         │ entity.pak                                │
                         │   entity/-vehicle/**/<unit>.def           │  breed -> weapon(s)
                         └───────────────────────────────────────────┘
                                          │  (build step, run by hand like flag_sectors)
                                          v
                         tools/build_gun_ratings.py  + test_build_gun_ratings.py
                                          │
                                          v
                         resource/script/multiplayer/gun_ratings.lua   (GENERATED)
                             return { sdkfz222 = 46, m5a1 = 78, pz3_m = 97, ... }
                                          │  (dofile at load, like flag_sectors.lua)
                                          v
   ┌──────────────────────────── bot.lua ────────────────────────────┐
   │ DecideTier(...)  ── picks a tier (UNCHANGED) ──► candidate list  │
   │                                                        │         │
   │ weightOf(t):                                           v         │
   │   mul = <existing priority/context weighting>                    │
   │   if EnemyHasTanks() and GunRating[t.unit] then                  │
   │       mul = mul * clamp(GunRating[t.unit]/REF, MIN, MAX)         │
   │   return t.priority * mul                                        │
   └─────────────────────────────────────────────────────────────────┘
```

## Data flow (spawn-time decision)

```
enemy fields tanks?
   │ no ──────────────────────────► weightOf unchanged; picker behaves exactly as today
   │ yes
   v
DecideTier already chose tier T ──► candidates = non-retired, unlocked units in tier T
   │
   v
for each candidate t:
   base = t.priority * <existing context mul>
   r    = GunRating[t.unit]            (nil for infantry / unrated => no change)
   apMul= r and clamp(r / GunRatingRef, GunRatingMulMin, GunRatingMulMax) or 1.0
   weight(t) = base * apMul
   │
   v
GetRandomItem(candidates, weight)  ──►  high-penetration unit drawn more often
   │
   v  (example, light tier, enemy has Stuarts, all unlocked)
   sdkfz222 r=46  apMul=clamp(46/60)=0.77
   (once 630s) pz3_m r=97 apMul=clamp(97/60)=1.62   ──► 5cm dominates the draw,
                                                         2cm fades without being banned
```

## Component 1: extraction tool

**File:** `tools/build_gun_ratings.py` (+ `tools/test_build_gun_ratings.py`)

Follows the existing `tools/build_aim_time.py` / `build_unit_meta.py` pattern (Python
`zipfile`, regex over plaintext pak members, offline, unit-tested).

Steps:
1. Open RobZ `gamelogic.pak`; for each `set/multiplayer/units/<faction>/*.set`, extract
   `unit_id` and its entity/breed reference.
2. Open RobZ `entity.pak`; resolve each unit to its `entity/-vehicle/**/<unit>.def`;
   parse the `{Weaponry}` block for every `{weapon "NAME" ...}`.
3. For each weapon NAME, read `set/stuff/gun/NAME`, resolving single-parent inheritance
   (`{from "PARENT"}`) up the chain; extract the **default-AP** curve's peak band value
   `a(...)` from `("damage_NNN" a(...) ...)`. Ignore APCR/HEAT/FG variants in v1.
4. **gun_rating(unit) = max over the unit's weapons of that weapon's default-AP `a`.**
   This makes the main gun win over coax MGs / secondary weapons automatically, and
   correctly rates HE-only / MG-only units near zero as anti-tank.
5. Emit `resource/script/multiplayer/gun_ratings.lua`:
   `return { <unit_id> = <int mm>, ... }` sorted by key, with a generated-file header
   comment naming the tool and the RobZ version.

**Test (`test_build_gun_ratings.py`):**
- sdkfz222 → 46, m5a1 → 78, pz3_m → 97 (exact, from the real paks).
- inheritance resolves: 37mm_m6 (`{from "37mm_m3"}`) yields the parent's penetration.
- an MG-only / HE-only unit rates low (assert < an AT gun in the same tier).
- unit with a coax MG plus a main gun takes the main gun's value (max rule).

## Component 2: generated table

**File:** `resource/script/multiplayer/gun_ratings.lua` (generated, committed, like
`flag_sectors.lua`). Loaded once at bot load: `GunRating = dofile(".../gun_ratings.lua")`
next to the existing `flag_sectors` load. Missing key => nil => no boost (safe default).

## Component 3: picker integration (bot.lua)

In `weightOf` (the within-tier candidate weighter, ~line 1458-1468), append one factor:

```lua
-- Constants (near other tuning constants)
GunRatingRef    = 60    -- mm; reference penetration (roughly a medium's flank)
GunRatingMulMin = 0.5
GunRatingMulMax = 1.8

-- inside weightOf(t), after existing mul is computed:
local r = GunRating[t.unit]
if r and BotApi.Commands:EnemyHasTanks() then
    local apMul = r / GunRatingRef
    if apMul < GunRatingMulMin then apMul = GunRatingMulMin end
    if apMul > GunRatingMulMax then apMul = GunRatingMulMax end
    mul = mul * apMul
end
```

Properties:
- No enemy armor => `EnemyHasTanks()` false => picker byte-for-byte unchanged.
- Bounded [0.5, 1.8] => biases the draw, never bans a unit, never zeroes a tier.
- Layers cleanly: DecideTier, retire filtering, and bias floors all run before weightOf,
  so this only reshuffles probabilities among already-eligible candidates.
- `EnemyHasTanks()` already exists (used by the ATTANK trickle gate).

**Test (`tests/gun_rating_spec.lua`, offline harness):**
- With `EnemyHasTanks` stubbed false: weight(t) equals the pre-change weight (no-op).
- With it true and two candidates (rating 46 vs 97): the 97 unit's weight/priority ratio
  exceeds the 46 unit's by the expected clamped factor.
- Unrated unit (GunRating[t.unit] == nil) with enemy tanks: weight unchanged.
- Clamp boundaries: rating 20 -> 0.5x floor; rating 200 -> 1.8x ceiling.

## Testing summary

| Layer | Test | Asserts |
|---|---|---|
| tool | test_build_gun_ratings.py | real RobZ pens (46/78/97), inheritance, max-rule, MG low |
| bot | tests/gun_rating_spec.lua | no-op when no enemy armor, monotonic boost, clamp, nil-safe |
| build | `luac -p bot.lua && luac -p bot.data.lua` | compiles with new load + weightOf branch |

## Rollback / safety

- The generated table and the `weightOf` branch are additive. Deleting `gun_ratings.lua`
  (or shipping it empty) makes every lookup nil => the boost is a no-op => stock behavior.
- No change to any spawn count, cap, cadence, tier ratio, or unlock/retire time.

## Files

- Create: `tools/build_gun_ratings.py`, `tools/test_build_gun_ratings.py`
- Create (generated): `resource/script/multiplayer/gun_ratings.lua`
- Create: `resource/script/multiplayer/tests/gun_rating_spec.lua`
- Modify: `resource/script/multiplayer/bot.lua` (load table; `weightOf` branch; constants)
- Modify: `ARCHITECTURE.md` (document gun-rating in the picker/weighting section)
- Modify: `README.md` (one line under spawn economy)
