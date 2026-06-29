# Flag Labeling System — Design Spec

**Date:** 2026-06-28
**Status:** Approved (design); pending spec review
**Mod:** ai-spawn-improved-robz (RobZ Realism 1.30.x, game 3.262)

## Goal

Give each AI bot a per-flag label at match start — OWN / CONTESTED / ENEMY, plus a
distance rank toward the enemy home — so later AI logic can answer: which flag is my
closest one to defend, which are contested, and which is closest to the enemy home.

The work is phased. Phase 1 produces the labels only and changes no unit behavior.
Phase 2 (designed here but built only after an in-game gate) consumes the labels to split
flags laterally between the two teammate bots so they stop contesting the same point.
Actually routing units from the partition is a following step, out of scope here.

## Hard Engine Constraints (verified, 2026-06-28)

These facts shape the whole design. Verified by probing the bot scripts and a real
match log (START_PROBE) plus map.pak extraction:

1. **No flag position at runtime.** A flag object exposes only `flag.name` and
   `flag.occupant`. There is no `flag.position` / `pos` / `x` / `y`.
2. **No map identity at runtime.** There is no API for the current map/mission/scene
   name or id. `BotApi.Scene` exposes only `Flags`, `Squads`, `IsSquadExists`.
3. **Team is absolute, not relative.** `BotApi.Instance.team` is the string `"a"` or
   `"b"`, matching the map's `{team a}` / `{team b}` spawn labels. The bot also has
   `enemyTeam`. Confirmed: USA spawned `team=a`, GER spawned `team=b`.
4. **Bases are not in `Scene.Flags`.** Only the capture flags (the `f`-named points)
   appear at runtime. In bastogne, `Scene.Flags` returns 11 entries (f1..f10, f20);
   the four base spawns (a1, a2, b1, b2) are absent.
5. **No per-player base identity.** Both teammates share the same `team` value
   (playerId 1 and 2 both reported `team=a`). Nothing distinguishes a1's occupant from
   a2's. Per-player spawn distinction is not achievable; only per-team orientation is.
6. **Coordinates exist offline only.** `map.pak/.../battle_zones.mi` is text and
   carries `{Position x y z}` plus `{name}`, `{team}`, `{visor SpawnPoint|MapPoint}`
   for every flag and base. This is the only source of spatial data.

Consequence: spatial sectoring requires precomputing from the offline `.mi`. A
runtime-only snapshot cannot sector the flags, because all capture flags start neutral
and the bases are not visible. The chosen approach (A + C below) follows from this.

## Architecture

```
┌─ OFFLINE (one-time build script, never runs in-game) ────────┐
│  tools/build_sectors.py                                       │
│    map.pak -> battle_zones.mi -> parse {name, Position, team} │
│    per f-flag: dA = min dist to a-bases, dB = min dist to b   │
│                axis = dA / (dA + dB)   (0 = at A home, 1 = B)  │
│    emit -> resource/script/multiplayer/flag_sectors.lua       │
└───────────────────────────────────────────────────────────────┘
                     │  (committed data file)
                     ▼
┌─ RUNTIME (mod, in-game) ──────────────────────────────────────┐
│  flag_sectors.lua   (require'd read-only data table)          │
│     Sectors[fp] = { bases={a1={x,y}..}, flags={f1={x,y,axis}}}│
│        │                                                      │
│        ▼                                                      │
│  LabelFlags()  (called once from OnGameStart)                 │
│    1. read Scene.Flags names -> sort -> fingerprint string    │
│    2. look up Sectors[fingerprint]                            │
│         hit  -> orient by team(a/b), assign sector + rank     │
│         miss -> fallback C: every flag CONTESTED, rank nil    │
│    3. write Context.FlagLabel[name]={sector,rank,axis,x,y}     │
│        │                                                      │
│        ▼                                                      │
│  Context.FlagLabel   (consumed by future AI logic; not wired  │
│                       in this spec)                           │
└───────────────────────────────────────────────────────────────┘
```

## Data Flow

```
battle_zones.mi          flag_sectors.lua          Context.FlagLabel
(coords, offline)        (axis per flag)           (sector+rank, per match)
─────────────────        ─────────────────         ──────────────────────
a1,a2,b1,b2 base ┐                                  team=a:
f1..f20 coords   ├─dist─► f6  axis=0.33 ──┐         f6  -> OWN
                 │        f1  axis=0.50    ├─team──► f1  -> CONTESTED
                 │        f10 axis=0.60 ──┘  a/b     f10 -> ENEMY, rank 1
                 │                            flip   (team=b inverts axis)
build_sectors.py          committed data     LabelFlags() at OnGameStart
```

## Components

### 1. Offline build script — `tools/build_sectors.py`

- Input: the RobZ `map.pak` path and a list of map dirs (v1: `2v2_bastogne` only).
- For each map, extract `battle_zones.mi`, parse every entity's `{name}` and the first
  `{Position x y [z]}` (note: base spawns carry a third z value; the parser must accept
  an optional third number — this bug was already hit and is called out here so the
  implementer avoids it).
- Bases are entities whose name matches `^[ab]%d+$` and/or `visor SpawnPoint`; group by
  the `{team}` letter. Capture flags are the `f`-named `visor MapPoint` entities.
- Compute per capture flag: `dA = min euclidean dist to a-bases`,
  `dB = min dist to b-bases`, `axis = dA / (dA + dB)`.
- Store **raw `x, y` per flag and per base** in addition to `axis`. Rationale: `axis`
  is a lossy 1D projection onto the A->B line; it discards the lateral (y) dimension and
  all pairwise flag-to-flag distances. bastogne already shows 8 flags collapsing to
  `axis ~= 0.5` while spread widely on y. Future atk/def logic will likely need 2D
  signals (which contested flag sits near a given spawn, flag clustering, flank side).
  Storing `x, y` (one parse the script already does) lets `LabelFlags()` derive those at
  load time without a pipeline rebuild. Do NOT store `z` (terrain height, unused) or a
  full distance matrix (derivable from `x, y` on load).
- Emit a Lua fragment into `flag_sectors.lua` keyed by the fingerprint (below).
- The script is run by hand and its output is committed. It never ships to the game.

### 2. Data file — `resource/script/multiplayer/flag_sectors.lua`

A plain Lua table, `require`'d by `bot.lua`. Each map entry carries a `bases` block
(the four spawn coordinates) and a `flags` block (`x, y, axis` per capture flag):

```lua
Sectors = {
  ["f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9"] = {   -- bastogne fingerprint
    bases = {
      a1={x=-4300, y=-647}, a2={x=-4300, y=746},
      b1={x= 3931, y=-646}, b2={x= 3986, y=746},
    },
    flags = {
      f1 ={x= -212, y=  -98, axis=0.50}, f2 ={x= -618, y=-2952, axis=0.46},
      f3 ={x= -288, y= 3674, axis=0.49}, f4 ={x=  573, y=-1945, axis=0.58},
      f5 ={x=-1738, y= 1707, axis=0.32}, f6 ={x=-1748, y=-1852, axis=0.33},
      f7 ={x= -357, y=-1284, axis=0.48}, f8 ={x= -101, y=  970, axis=0.51},
      f9 ={x=  -66, y= 2445, axis=0.51}, f10={x=  739, y= 1705, axis=0.60},
      f20={x=  -14, y= 5042, axis=0.51},
    },
  },
}
```

`axis` is a precomputed convenience; `x, y` (flags and bases) are the lossless source
for any 2D label derived later. Sector thresholds and rank are derived at runtime so
they can be tuned without rebuilding the table.

### 3. Runtime labeler — `LabelFlags()` in `bot.lua`

- Called once from `OnGameStart`, after the flag list is available.
- Builds the fingerprint: collect `flag.name` for all `Scene.Flags`, sort
  ascending (string sort), join with `,`.
- Look up `Sectors[fingerprint]`; the entry has `.bases` and `.flags`.
- **Hit:** for each flag, read its stored `entry.flags[name]` (`x, y, axis`). Orient by
  team:
  - `team == "a"`: `myAxis = axis` (0 = my home, 1 = enemy home).
  - `team == "b"`: `myAxis = 1 - axis` (invert, because B's home is the axis-1 end).
  - Sector from `myAxis`: `< 0.4` OWN, `> 0.6` ENEMY, else CONTESTED (thresholds are
    named constants, tunable).
  - Rank: sort the map's flags by `myAxis` descending; rank 1 = highest `myAxis` =
    closest to enemy home. Store the rank per flag.
  - Pass the raw `x, y` (and the `bases` block) straight through to the output so future
    atk/def logic can derive 2D signals at load without a rebuild. This spec computes no
    other 2D label yet (YAGNI).
- **Miss (fallback C):** every flag gets `sector = "CONTESTED"`, `rank = nil`,
  `axis/x/y = nil`; print one log line `SECTOR_FALLBACK fingerprint=<...>` so the unknown
  map can be added to the table later. Behavior degrades to today's logic (no sectoring).
- Output: `Context.FlagLabel[name] = { sector = "OWN"|"CONTESTED"|"ENEMY",
  rank = <int or nil>, axis = <number or nil>, x = <number or nil>, y = <number or nil> }`,
  plus `Context.FlagBases = entry.bases` (or nil on a miss).
- **Debug log (required for the Phase 1 -> 2 gate):** after labeling, print one line per
  flag, e.g. `SECTOR pid=<playerId> team=<a|b> <name> sector=<S> rank=<R> axis=<A>`, and
  on a miss the single `SECTOR_FALLBACK fingerprint=<...>`. These lines let the in-game
  test confirm correctness, determinism across teammates, and the playerId-by-team
  assumption without any other instrumentation.

## Fingerprint and Collision

- The fingerprint is the sorted, comma-joined set of capture-flag names actually
  present at runtime. It replaces the missing map-id API.
- v1 has a single map, so collisions are impossible. When more maps are added, two maps
  could share an identical flag-name set. Mitigation when it occurs: append the flag
  count, or a coarse hash of the flag positions, to the key. Not implemented in v1;
  recorded here as the known extension point.

## Orientation by Team

The table stores `axis` in absolute A->B terms (0 at side-A home, 1 at side-B home),
independent of which side the bot is on. At runtime the bot reads its own `team`:

- team a: enemy home is the axis=1 end, so `myAxis = axis`.
- team b: enemy home is the axis=0 end, so `myAxis = 1 - axis`.

This makes one stored value serve both sides correctly.

## Worked Example — bastogne (real extracted coordinates)

Bases: a1 (-4300, -647), a2 (-4300, 746), b1 (3931, -646), b2 (3986, 746).

| flag | x | y | dA | dB | axis | sector (team a) | rank to enemy (team a) |
|------|----|----|----|----|------|------|------|
| f10 | 739 | 1705 | 5129 | 3386 | 0.60 | ENEMY | 1 |
| f4 | 573 | -1945 | 5043 | 3601 | 0.58 | CONTESTED | 2 |
| f9 | -66 | 2445 | 4562 | 4394 | 0.51 | CONTESTED | 3 |
| f20 | -14 | 5042 | 6068 | 5871 | 0.51 | CONTESTED | 4 |
| f8 | -101 | 970 | 4205 | 4094 | 0.51 | CONTESTED | 5 |
| f1 | -212 | -98 | 4125 | 4179 | 0.50 | CONTESTED | 6 |
| f3 | -288 | 3674 | 4967 | 5181 | 0.49 | CONTESTED | 7 |
| f7 | -357 | -1284 | 3994 | 4336 | 0.48 | CONTESTED | 8 |
| f2 | -618 | -2952 | 4344 | 5100 | 0.46 | CONTESTED | 9 |
| f6 | -1748 | -1852 | 2822 | 5806 | 0.33 | OWN | 10 |
| f5 | -1738 | 1707 | 2737 | 5804 | 0.32 | OWN | 11 |

For team a: closest own flag to defend = f5 (rank 11), closest to enemy home = f10
(rank 1). For team b the same table is read with `myAxis = 1 - axis`, inverting both.

**Tuning note:** bastogne's bases sit far apart on x (+-4300) while most capture flags
cluster near the center, so fixed axis thresholds of 0.4 / 0.6 yield a CONTESTED-heavy
split (2 OWN, 1 ENEMY, 8 CONTESTED). The rank is the more useful signal and is
threshold-free. Thresholds are tunable constants; an alternative tertile split (divide
ranked flags into thirds) is noted as a future option, not adopted in v1.

## Scope and Phasing

This feature ships in two phases with an in-game verification gate between them. Phase 2
is NOT built until Phase 1 has been confirmed in a real match (see the gate below).

**Phase 1 — Labeling (this spec, build now):**
- `tools/build_sectors.py` producing `flag_sectors.lua` for bastogne.
- `flag_sectors.lua` data file with the bastogne entry (bases + flags x,y,axis).
- `LabelFlags()` + `Context.FlagLabel` / `Context.FlagBases` populated at `OnGameStart`.
- A debug log line per labeled flag (see gate) so the in-game test can confirm.
- Fallback C for any unrecognized map.
- Tests (below).

**Phase 1 -> 2 Verification Gate (in-game test, must pass before Phase 2):**
Run a self-hosted bastogne 2v2 with AI on both teams, then confirm from game.log:
1. `LabelFlags()` fired and the bastogne fingerprint matched (no `SECTOR_FALLBACK`).
2. Labels are sane: f10 ENEMY/rank 1 and f5 OWN/rank 11 for a team-a bot; inverted for
   a team-b bot.
3. **playerId is contiguous-by-team** (the load-bearing assumption for Phase 2): the two
   team-a bots report adjacent ids and the two team-b bots the next block (e.g. a=1,2 /
   b=3,4). Confirm across at least 2 matches, since only one sample exists today.
4. Both teammates compute identical raw labels for the same flag (determinism).
If 1, 2, 4 hold but 3 is violated, Phase 2 still proceeds but must use the collision-safe
fallback (below) instead of trusting `idx`.

**Phase 2 — Lateral Teammate Partition (gated, design below):**
- Consume the Phase 1 labels + stored coords to split flags laterally between the two
  teammate bots so they do not contest the same point.

**Out of scope (later specs):**
- Wiring the partition into PickGroupTarget / capper / defender order issuing (Phase 2
  produces the assignment; using it to actually route units is a following step).
- Extracting the other 44 RobZ maps (batch run of the same pipeline once v1 is proven).
- Per-player (a1 vs a2) spawn-aligned sectoring — not achievable with the current API
  (a bot cannot learn which physical base it spawned at).
- Fingerprint collision disambiguation (not reachable with one map).

## Phase 2 Design — Lateral Teammate Partition

`axis` (Phase 1) is the FORWARD depth (own -> enemy). Splitting the two teammates is an
ORTHOGONAL, lateral dimension. Phase 2 derives a lateral coordinate from the stored
coords and assigns each flag to a teammate slot.

```
                       enemy home (B)
                            ^
          OWN | CONTESTED | ENEMY     <- axis  (Phase 1: attack priority)
   bot idx1 <------+-------> bot idx2  <- lateral (Phase 2: who owns it)
                            v
                       own home (A)
```

**Algorithm (runs at OnGameStart, after LabelFlags):**

1. **Lateral coordinate.** From `Context.FlagBases`, compute the A-home centroid and
   B-home centroid; the A->B vector is the forward axis. Project each flag's `(x,y)` onto
   the axis PERPENDICULAR to A->B -> `lat` (signed lateral position). Projection (not raw
   y) keeps this correct on maps whose bases differ on y.
2. **Team index.** `team=="a"` -> `idx = playerId`; `team=="b"` -> `idx = playerId -
   teamSize`. Range `1..teamSize` (2 in 2v2). This is the assumption the gate verifies.
3. **Bands.** Sort flags by `lat`. Divide into `teamSize` outer bands plus a central
   SHARED band. `idx==1` claims the low-`lat` band, `idx==2` the high-`lat` band; the
   central band is claimed by both.
4. **Ownership.** Each bot acts only on flags in (its own band + the shared band).
   Because every bot runs identical code over identical data with an identical sort, the
   two bots compute the SAME partition with no communication -> they never target the
   same exclusive flag. De-confliction is structural, not negotiated.

**Worked example — bastogne, flags sorted by lateral (here y, since A->B is the x-axis):**

```
 y: -2952 -1945 -1852 -1284  -98   970  1705 1707 2445 3674 5042
    f2    f4    f6    f7    f1   f8   f10  f5   f9   f3   f20
   |----- idx1  (low y) -----|  |- shared -|  |----- idx2 (high y) -----|
        f2 f4 f6 f7             f1 f8 f10           f5 f9 f3 f20
```

idx1 owns the left flank (f2,f4,f6,f7), idx2 the right (f5,f9,f3,f20), f1/f8/f10 shared.

**Collision-safe fallback (used if the gate finds playerId not contiguous-by-team):**
if `idx` cannot be trusted, do not partition; every bot treats all flags as its own
(current behavior). This degrades to today's possible overlap, never worse.

**Band sizing:** shared band width is a tunable constant (default: central third of the
ranked flags is shared, outer thirds split). Wider shared band = more overlap but more
coverage; narrower = cleaner split but risk of an uncovered seam.

**Phase 2 tests:** with mocked coords + team/playerId, assert idx1 and idx2 receive
disjoint outer bands, the shared band appears in both, and the two teammates' assignments
union to the full flag set with overlap only in the shared band.

## Error Handling

- Build script: if a map has zero a-bases or zero b-bases, fail loudly and skip that
  map (do not emit a partial entry).
- Runtime: `LabelFlags()` must never error out the bot. If `Scene.Flags` is empty or
  the data file is missing, treat as a fallback-C miss. A flag present at runtime but
  absent from the matched table entry gets CONTESTED + nil rank.

## Testing

- **Build script:** assert bastogne yields 11 flags each with `x, y, axis`, a `bases`
  block with all four spawns (a1/a2/b1/b2), f6/f5 axis < 0.4, f10 axis > 0.59, and that
  the third z-coordinate on base positions is parsed without error.
- **LabelFlags (unit, mocked Scene.Flags + team):**
  - raw `x, y` pass through to `Context.FlagLabel` (e.g. f10 x=739, y=1705) and
    `Context.FlagBases` is populated with the four spawn coords.
  - bastogne fingerprint + team a: f10 sector ENEMY and rank 1; f5 OWN and rank 11.
  - bastogne fingerprint + team b: orientation inverts (f5/f6 become ENEMY-side, f10
    becomes OWN-side); rank 1 flips to the opposite end.
  - unknown fingerprint: every flag CONTESTED, rank nil, one SECTOR_FALLBACK log.
- Gates (existing): `luac -p bot.lua`, `luac -p bot.data.lua`, `luac -p flag_sectors.lua`,
  `lua tests/phase_spec.lua`, `lua tests/integration_spec.lua`.
