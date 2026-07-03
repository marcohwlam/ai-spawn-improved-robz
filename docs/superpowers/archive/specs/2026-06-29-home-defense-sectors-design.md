# Design: #4 Home-defense sectors via symmetric base-tag labeling

**Date:** 2026-06-29 (revised after renorm approach was rejected)
**Branch:** `feat/home-defense-sectors`
**Status:** Approved design (revised). Ready for implementation plan update.
**Related:** Handoff `docs/superpowers/handoff/2026-06-29-routing-defense-and-retarget.md`
(issue #4). Issue #5 (stuck-target retarget) is a separate brainstorm.

## Problem

In a real `2v2_bastogne` CTF match the GER bot (team b) never prioritized retaking or
defending its home flags. Root cause confirmed from `game.log`: team b had **zero OWN
sectors**, so the tier-1 home-defense candidate filter in `PickGroupTarget`
(`bot.lua:1410`, requires `label.sector == "OWN"`) never fired for GER.

### Why team b had no OWN flag

`LabelFlags` classified a flag by the offline `axis` scalar (0 = A home, 1 = B home);
team a used `myAxis = axis`, team b used `myAxis = 1 - axis`, with cut points
`myAxis < 0.4` → OWN, `>= 0.6` → ENEMY. `axis` is the distance-normalized position between
the two home bases. Bastogne is geometrically asymmetric: team a's home flags sit deep in
its half (`axis` 0.32, 0.33 → OWN), but team b's home flags sit barely past midfield
(`axis` 0.58, 0.60 → from b's view 0.42, 0.40 → never crossed the 0.4 OWN cut). Team a got
2 OWN flags, team b got 0.

## Rejected approach: two-point axis renormalization

The first revision of this design renormalized `axis` per team so each side's deepest base
flag anchored to OWN. It was implemented and then rejected because it **shifts the neutral
divider off the true map center**.

The renorm mapped `[homeA, homeB]` (the base-flag axis extremes) onto `[0, 1]`. On an
asymmetric map this pushes the true geometric center (raw `axis` 0.5, equidistant from both
bases) to an off-center value (bastogne: 0.5 → 0.64). The result: one team "owns" most of
the map. Measured on bastogne, team a got 2 OWN and team b got 7 OWN — the map was tilted,
not balanced. Renorm is reverted entirely.

Key realization: team b always reads `1 - axis`, and the cut points are symmetric about 0.5,
so per-team labels are *already* mirror images for any transform. The real requirement is
that the neutral divider stay at the true center AND that home flags reach OWN. The cleanest
way to satisfy both, with provably equal OWN counts on every map, is to drive the sector
label from the offline base tags rather than an axis threshold.

## Decision summary

| Question | Decision |
|---|---|
| OWN/ENEMY classification | Driven by the offline `base` tag, not an axis threshold |
| OWN count per team | Equals the symmetric per-team base-flag count (varies 2-6 by map; equal both teams) |
| Equal base count per team | Trim each side's base set to `N = min(countA, countB)` (kept from prior revision) |
| `axis` role | Retained only for intra-tier ranking; no longer decides sector |

Verified base-flag counts across a 16-map sample (post dedupe+trim): N varies — 2 on small
maps (gazala, nikolaev, bastogne, karelia, yard, anzio, river), 3 on docklands / bulge /
omaha-beach / town / fields / iwo_jima / port, 4 on moskow, 6 on volga_river. Always equal
between the two teams on every map sampled. So OWN count is computed per map, never hard-coded.

## Scope

- `tools/build_sectors.py`: keep dedupe + symmetric trim (already implemented); **revert the
  `renorm` step** so emitted `axis` is the raw distance-normalized value again.
- `resource/script/multiplayer/bot.lua`: `LabelFlags` derives `sector` from `base`, not from
  the axis cut points. Remove the now-unused `SectorOwnMax` / `SectorEnemyMin` constants.
- Regenerate `resource/script/multiplayer/flag_sectors.lua` (raw axis + symmetric base tags).

## Architecture

```
              OFFLINE (build_sectors.py)                 RUNTIME (bot.lua, CHANGED)
  ┌───────────────────────────────────────────┐   ┌──────────────────────────────────┐
  │ parse_mi → bases{a#,b#}, flags{f#:(x,y)}   │   │ require flag_sectors.lua          │
  │ compute  → raw axis = dA/(dA+dB)           │   │                                   │
  │ adjacency:                                 │   │ LabelFlags():                     │
  │   ① dedupe: each flag → nearer side only   │──►│   for each present flag p:        │
  │   ② trim:   N = min(cntA,cntB) per side    │   │     if p.base == myTeam  → OWN    │
  │   (NO renorm — emit raw axis)              │   │     elif p.base (enemy)  → ENEMY  │
  │ emit_lua → flag_sectors.lua (raw axis,     │   │     else                 → CONTEST│
  │            symmetric single-team base tags)│   │   rank by myAxis (axis still used │
  └───────────────────────────────────────────┘   │        only for ordering)         │
                                                   │ → OWN count = base count (equal)  │
                                                   │ → tier-1 fires for BOTH teams     │
                                                   └──────────────────────────────────┘
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
        │   ① assign each flag to its nearer base side  → base ∈ {a} | {b} | none
        │   ② countA, countB → N = min; keep N nearest per side, drop farthest
        ▼
  flag_sectors.lua   (RAW axis, symmetric single-team base tags)
        │ require  (runtime)
        ▼
  LabelFlags:
        sector = base==myTeam ? OWN : base ? ENEMY : CONTESTED
        myAxis = team=="a" ? axis : 1-axis        (ranking only)
        ▼
  OWN set = my base flags → tier-1 home defense fires for both teams, equal OWN counts
```

## Components

### `tools/build_sectors.py`
- `compute` (unchanged): raw `axis = dA / (dA + dB)`.
- `adjacency` (unchanged from the prior revision): dedupe cross-team base tags, trim each
  side to `N = min(countA, countB)` nearest flags. Single-team base tags only.
- **Revert `renorm`:** delete the `renorm` function and restore `main()` to emit
  `compute(...)` output directly (raw axis). `emit_lua` unchanged.

### `resource/script/multiplayer/bot.lua` — `LabelFlags`
Replace the axis-threshold sector block (currently lines 823-825) with a base-tag rule.
`team = BotApi.Instance.team` is already in scope (line 794); each present flag already
carries `base = d.base` (line 811), a single-team list `{"a"}` / `{"b"}` or `nil`:

```lua
for rank, p in ipairs(present) do
    local sector = "CONTESTED"
    if p.base and p.base[1] then
        sector = (p.base[1] == team) and "OWN" or "ENEMY"
    end
    Context.FlagLabel[p.name] = { sector = sector, rank = rank, axis = p.myAxis,
        x = p.x, y = p.y, nb = p.nb, base = p.base }
    -- existing SECTOR print unchanged
end
```

Remove the unused `SectorOwnMax` / `SectorEnemyMin` constants (lines 115-116). `myAxis` and
`rank` are retained: `myAxis` still orders flags (rank 1 = nearest enemy home) and tier-1 /
tier-3 still sort candidates by it.

### Routing interaction (no bot.lua routing change)
`PickGroupTarget` (bot.lua:1410-1412) uses only `sector == "OWN"` (tier 1) and
`sector == "CONTESTED" and IsFrontier and owner.mine` (tier 2). `ENEMY` is not used in tier
selection. Under the new labels: OWN = each team's base flags (tier-1 home defense, now live
for both teams); the midfield becomes CONTESTED (was a mixed axis gradient), widening tier-2
eligibility for frontier flags in our lane; only the enemy's base flags are ENEMY and fall
to tier 3. This is an accepted behavior change — midfield is genuinely contested, and
focusing tier-1 strictly on home flags is the intent of #4.

## Bastogne labels (new model)

base after trim: f5, f6 = a; f4, f10 = b. Symmetric, mirror-equal counts.

| flag | base | team-a (USA) | team-b (GER) |
|---|---|---|---|
| f5 | a | OWN | ENEMY |
| f6 | a | OWN | ENEMY |
| f4 | b | ENEMY | OWN |
| f10 | b | ENEMY | OWN |
| f1, f2, f3, f7, f8, f9, f20 | — | CONTESTED | CONTESTED |

Counts: USA OWN 2 / CON 7 / ENE 2; GER OWN 2 / CON 7 / ENE 2 — exactly equal.

## Testing

### Python unit — `tools/test_build_sectors.py`
- Keep the dedupe + symmetric-trim assertions.
- **Remove the renorm tests** (renorm is deleted).
- Add: after generation, emitted `axis` equals the raw `compute` value (renorm gone), and
  each map's a-base count equals its b-base count.

### Lua sector spec — `tests/sector_spec.lua`
Rewrite the sector assertions for the base-tag model on regenerated bastogne:
- team a: f5, f6 OWN; f4, f10 ENEMY; a sample midfield flag (e.g. f7) CONTESTED.
- team b: f4, f10 OWN; f5, f6 ENEMY; f7 CONTESTED.
- both teams: OWN count == base count and equal to each other.
- Keep the existing fallback (unknown map → all CONTESTED) and rank checks (rank still from
  `myAxis`).

### Routing spec — `tests/routing_spec.lua`
Update expectations for the new labels. The tier-1 home-defense and tier-2 CONTESTED-frontier
scenarios still hold (f6 OWN as home, f7 CONTESTED frontier). Adjust any expectation that
depended on a midfield flag being ENEMY.

### Regression
All other Lua specs (frontier, partition, integration, phase, mapname) stay green.

## Implementation / verification steps (for the plan)
1. Revert `renorm` in `build_sectors.py`; remove its tests.
2. Change `LabelFlags` to the base-tag rule; remove `SectorOwnMax` / `SectorEnemyMin`.
3. Regenerate `flag_sectors.lua` (raw axis, symmetric base tags) for all 4 maps.
4. Rewrite `sector_spec.lua`; update `routing_spec.lua`; confirm Python + all Lua specs green.
5. Verify per map: a-base count == b-base count, and both teams' OWN set == their base flags.

## Out of scope
- Issue #5 (stuck/bleeding target give-up) — separate brainstorm.
- Wider OWN "backfield" zones (N greater than base count) — current decision sets OWN exactly
  to the base flags; revisit only if home defense needs a deeper zone.
- Proximity / under-attack-while-still-owned pre-emptive defense (needs runtime squad
  positions).
