# Design: #4 Home-defense sectors via symmetric offline data

**Date:** 2026-06-29
**Branch:** `feat/home-defense-sectors`
**Status:** Approved design. Ready for implementation plan.
**Related:** Handoff `docs/superpowers/handoff/2026-06-29-routing-defense-and-retarget.md`
(issue #4). Issue #5 (stuck-target retarget) is a separate brainstorm.

## Problem

In a real `2v2_bastogne` CTF match, the GER bot (team b) never prioritized retaking or
defending its home flags. Root cause confirmed from `game.log`: team b had **zero OWN
sectors**, so the tier-1 home-defense candidate filter in `PickGroupTarget`
(`bot.lua:1369-1406`, requires `label.sector == "OWN"`) never fired for GER.

### Why team b had no OWN flag

`LabelFlags` (`bot.lua:804-806`) classifies a flag by the offline `axis` scalar
(0 = A home, 1 = B home); team a uses `myAxis = axis`, team b uses `myAxis = 1 - axis`.
Cut points: `myAxis < 0.4` → OWN, `>= 0.6` → ENEMY, else CONTESTED.

`axis` is the distance-normalized position between the two home bases
(`axis = dA / (dA + dB)`, `build_sectors.py:compute`). Bastogne is geometrically
asymmetric: team a's home flags sit deep in its half, but team b's home flags sit barely
past midfield.

Observed labels (from `game.log`):

| flag | base tag | raw axis | team-a (USA) | team-b (GER) `1-axis` |
|---|---|---|---|---|
| f5 | a | 0.32 | **OWN** | ENEMY 0.68 |
| f6 | a | 0.33 | **OWN** | ENEMY 0.67 |
| f4 | b | 0.58 | CONTESTED | CONTESTED 0.42 |
| f8 | b | 0.51 | CONTESTED | CONTESTED 0.49 |
| f10 | b | 0.60 | ENEMY | CONTESTED 0.40 |

Team a gets 2 OWN flags; team b gets 0. Tier-1 home defense is dead for GER.

## Decision summary

| Question | Decision |
|---|---|
| OWN classification fix | Per-team two-point axis renormalization (not base-tag override, not runtime proximity) |
| Where renorm runs | Offline in `build_sectors.py`; runtime `LabelFlags` unchanged |
| Equal base count per team | Trim each side's base set to `N = min(countA, countB)` by farthest-drop |

Rationale: keep `axis` the single runtime source of truth and keep all map-geometry logic
in the offline tool. `bot.lua` is not touched, so routing behavior changes only through
reviewable data in `flag_sectors.lua`.

Note: symmetric base count is an independent fairness/correctness goal requested by the
user. It is not strictly required for #4 (renorm anchors per side regardless of count), but
it interacts with renorm because the renorm anchors are the base flags.

## Scope

- Edit `tools/build_sectors.py` only (offline generator).
- Regenerate `resource/script/multiplayer/flag_sectors.lua` for all 4 maps.
- `resource/script/multiplayer/bot.lua` is UNCHANGED.

## Architecture

```
              OFFLINE (build_sectors.py)                 RUNTIME (bot.lua, UNCHANGED)
  ┌───────────────────────────────────────────┐   ┌────────────────────────────────┐
  │ parse_mi  → bases{a#,b#}, flags{f#:(x,y)}  │   │ require flag_sectors.lua        │
  │ compute   → raw axis = dA/(dA+dB)          │   │                                 │
  │ adjacency:                                 │   │ LabelFlags():                   │
  │   ① dedupe: each flag → nearer side only   │   │   myAxis = team=="a"            │
  │   ② trim:   N = min(cntA,cntB) per side    │──►│            ? axis' : 1 - axis'  │
  │   ③ renorm: homeA=min axisₐ, homeB=max ax_b│   │   OWN  if myAxis < 0.4          │
  │     axis' = clamp01((axis-homeA)/          │   │   ENEMY if myAxis >= 0.6        │
  │                     (homeB-homeA))         │   │   else CONTESTED                │
  │   guard: homeA < homeB else SystemExit     │   │ → tier-1 fires for BOTH teams   │
  │ emit_lua  → flag_sectors.lua (axis', base) │   └────────────────────────────────┘
  └───────────────────────────────────────────┘
```

## Data flow

```
  map.pak/<map>/battle_zones.mi
        │ parse_mi
        ▼
  bases{a#,b#}   flags{f#:(x,y)}
        │ compute
        ▼
  raw axis (per flag) + nb adjacency graph
        │ adjacency
        │   ① assign each flag to its nearer base side  → base ∈ {a} | {b} (never both)
        │   ② countA, countB → N = min; keep N nearest per side, drop farthest
        │   ③ homeA = min(axis) over a-base flags
        │      homeB = max(axis) over b-base flags
        │      assert homeA < homeB        (else SystemExit, fail loud)
        ▼
  axis' = clamp01((axis - homeA) / (homeB - homeA))
        │ emit_lua
        ▼
  flag_sectors.lua   (stores axis', symmetric single-team base tags)
        │ require  (runtime, no code change)
        ▼
  LabelFlags → each team's deepest base flag maps to myAxis ≈ 0 → OWN
```

## Components

### `compute` (unchanged)
Still emits raw `axis = dA / (dA + dB)`. Renorm consumes this downstream so the raw
distance metric stays the single geometric input.

### `adjacency` (changed)
1. **Dedupe.** Build the per-base candidate sets as today (within `THRESH`, unioned with
   `KFLOOR` nearest). Then for any flag that ends up tagged for both `a` and `b`, keep only
   the nearer side by min distance to that side's nearest base. Exact-tie tie-break: team `a`
   wins (`da <= db` → a), which is deterministic.
2. **Trim to symmetric count.** `countA`, `countB` from the deduped sets. `N = min(countA,
   countB)`. Keep the `N` nearest flags to each side (by min distance to that side's bases),
   drop the rest. `assert N >= 1`.
3. Emit single-team `base` tags from the trimmed sets.

### renorm (new — post-step after `adjacency`, before `emit_lua`)
Renorm must run after `adjacency` because it reads the trimmed base sets; `compute` runs
earlier and only has raw axis.
- `homeA = min(axis of a-base flags)`, `homeB = max(axis of b-base flags)` using the
  trimmed base sets.
- `assert homeA < homeB` else `SystemExit("renorm anchors crossed: homeA>=homeB")`.
- For every flag: `axis' = clamp01((axis - homeA) / (homeB - homeA))`.
- `emit_lua` writes `axis'` in the `axis=` field.

### `bot.lua` (unchanged)
`LabelFlags` keeps `SectorOwnMax = 0.4` / `SectorEnemyMin = 0.6` on the stored axis. No
runtime cost added.

## Bastogne before → after (team-b / GER perspective)

| flag | base (after trim) | raw axis | old GER label | axis' | new GER label |
|---|---|---|---|---|---|
| f10 | b | 0.60 | CONTESTED 0.40 | 1.00 | **OWN** 0.00 |
| f4 | b | 0.58 | CONTESTED 0.42 | 0.93 | **OWN** 0.07 |
| f8 | — (dropped) | 0.51 | CONTESTED 0.49 | 0.68 | OWN 0.32 |
| f9 | — | 0.51 | CONTESTED 0.49 | 0.68 | OWN 0.32 |
| f20 | — | 0.51 | CONTESTED 0.49 | 0.68 | OWN 0.32 |
| f3 | — | 0.49 | CONTESTED 0.51 | 0.61 | OWN 0.39 |
| f7 | — | 0.48 | CONTESTED 0.52 | 0.57 | CONTESTED 0.43 |
| f1 | — | 0.50 | CONTESTED 0.50 | 0.64 | OWN 0.36 |
| f2 | — | 0.46 | CONTESTED 0.54 | 0.50 | CONTESTED 0.50 |
| f5 | a | 0.32 | ENEMY 0.68 | 0.00 | ENEMY 1.00 |
| f6 | a | 0.33 | ENEMY 0.67 | 0.04 | ENEMY 0.96 |

The home flags (f4, f10) become OWN for GER — the fix. Known side effect: two-point
anchoring on an asymmetric map compresses the CONTESTED band, pushing several midfield
flags toward OWN (team b) / ENEMY (team a). This is accepted; the full table is reviewed
here before regen. team-a OWN set stays {f5, f6}; ENEMY widens.

## Testing

### Python unit — `tools/test_build_sectors.py` (new, no map.pak needed)
Synthetic asymmetric fixture (a-flags deep, b-flags near midline, mirroring bastogne):
- no flag carries both `a` and `b` after dedupe;
- `countA == countB`;
- after renorm, each team has `>= 1` flag with `myAxis < 0.4` (a home OWN flag exists);
- crossed-anchor input triggers the `homeA < homeB` `SystemExit`.

### Lua sector spec (extend existing fixture)
Load regenerated bastogne data:
- team a `LabelFlags` → f5, f6 are OWN;
- team b `LabelFlags` → f4, f10 are OWN;
- each team has `>= 1` OWN flag (regression guard against #4 recurring).

### Regression
Existing `routing_spec` tier tests (tier-3, own-all) must stay green. If renorm changes
bastogne tier classification, update fixture expectations and note it in this spec's
changelog.

## Implementation / verification steps (for the plan)
1. **Baseline regen first, no logic change:** run the generator against the current pak and
   diff against committed `flag_sectors.lua`. Confirm the pak reproduces today's data
   (geometry/flag-set match) before layering changes. If the diff is non-trivial, stop and
   reconcile — the pak may differ from the one used originally.
2. Implement dedupe → trim → renorm + guards in `build_sectors.py` (TDD against
   `test_build_sectors.py`).
3. Regenerate:
   `python tools/build_sectors.py "mods/robz realism mod 1.30.10/resource/map.pak" \
     2v2_bastogne 2v2_sidi_el-barrani 1v1_nikolaev 2v2_mamayev_kurgan \
     -o resource/script/multiplayer/flag_sectors.lua`
4. Verify per map: both teams' base counts equal, each team has an OWN flag.
5. Run Python + Lua specs; confirm all green. Commit the `flag_sectors.lua` diff.

## Out of scope
- Issue #5 (stuck/bleeding target give-up) — separate brainstorm.
- The handoff's "force re-pick when a better-tier candidate appears" pre-emption (single-
  group latency). Not needed for #4: once GER has OWN flags, tier-1 wins on the next
  `UpdateGroupTargets` re-pick. Revisit during #5, which shares that mechanism.
- Proximity / under-attack-while-still-owned pre-emptive defense (needs runtime squad
  positions; the routing spec deliberately avoided it).
