# Flag Labeling System — Design Spec

**Date:** 2026-06-28
**Status:** Approved (design); pending spec review
**Mod:** ai-spawn-improved-robz (RobZ Realism 1.30.x, game 3.262)

## Goal

Give each AI bot a per-flag label at match start — OWN / CONTESTED / ENEMY, plus a
distance rank toward the enemy home — so later AI logic can answer: which flag is my
closest one to defend, which are contested, and which is closest to the enemy home.

This spec produces the labels only. It does not change targeting, capper, or defender
behavior. Consumption by AI logic is deliberately out of scope (see Out of Scope).

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
│     Sectors[fingerprint] = { f1 = {axis=0.50}, ... }          │
│        │                                                      │
│        ▼                                                      │
│  LabelFlags()  (called once from OnGameStart)                 │
│    1. read Scene.Flags names -> sort -> fingerprint string    │
│    2. look up Sectors[fingerprint]                            │
│         hit  -> orient by team(a/b), assign sector + rank     │
│         miss -> fallback C: every flag CONTESTED, rank nil    │
│    3. write Context.FlagLabel[name] = {sector=, rank=, axis=} │
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
- Emit a Lua fragment into `flag_sectors.lua` keyed by the fingerprint (below).
- The script is run by hand and its output is committed. It never ships to the game.

### 2. Data file — `resource/script/multiplayer/flag_sectors.lua`

A plain Lua table, `require`'d by `bot.lua`:

```lua
Sectors = {
  ["f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9"] = {   -- bastogne fingerprint
    f1={axis=0.50}, f2={axis=0.46}, f3={axis=0.49}, f4={axis=0.58},
    f5={axis=0.32}, f6={axis=0.33}, f7={axis=0.48}, f8={axis=0.51},
    f9={axis=0.51}, f10={axis=0.60}, f20={axis=0.51},
  },
}
```

Only `axis` is stored per flag. Sector thresholds and rank are derived at runtime so
they can be tuned without rebuilding the table.

### 3. Runtime labeler — `LabelFlags()` in `bot.lua`

- Called once from `OnGameStart`, after the flag list is available.
- Builds the fingerprint: collect `flag.name` for all `Scene.Flags`, sort
  ascending (string sort), join with `,`.
- Look up `Sectors[fingerprint]`.
- **Hit:** for each flag, read its stored `axis`. Orient by team:
  - `team == "a"`: `myAxis = axis` (0 = my home, 1 = enemy home).
  - `team == "b"`: `myAxis = 1 - axis` (invert, because B's home is the axis-1 end).
  - Sector from `myAxis`: `< 0.4` OWN, `> 0.6` ENEMY, else CONTESTED (thresholds are
    named constants, tunable).
  - Rank: sort the map's flags by `myAxis` descending; rank 1 = highest `myAxis` =
    closest to enemy home. Store the rank per flag.
- **Miss (fallback C):** every flag gets `sector = "CONTESTED"`, `rank = nil`,
  `axis = nil`; print one log line `SECTOR_FALLBACK fingerprint=<...>` so the unknown
  map can be added to the table later. Behavior degrades to today's logic (no sectoring).
- Output: `Context.FlagLabel[name] = { sector = "OWN"|"CONTESTED"|"ENEMY",
  rank = <int or nil>, axis = <number or nil> }`.

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

## Scope

**In scope (v1):**
- `tools/build_sectors.py` producing `flag_sectors.lua` for bastogne.
- `flag_sectors.lua` data file with the bastogne entry.
- `LabelFlags()` + `Context.FlagLabel` populated at `OnGameStart`.
- Fallback C for any unrecognized map.
- Tests (below).

**Out of scope (later specs):**
- Consuming `Context.FlagLabel` in PickGroupTarget / capper / defender logic.
- Extracting the other 44 RobZ maps (batch run of the same pipeline once v1 is proven).
- Per-player (a1 vs a2) sectoring — not achievable with the current API.
- Fingerprint collision disambiguation (not reachable with one map).

## Error Handling

- Build script: if a map has zero a-bases or zero b-bases, fail loudly and skip that
  map (do not emit a partial entry).
- Runtime: `LabelFlags()` must never error out the bot. If `Scene.Flags` is empty or
  the data file is missing, treat as a fallback-C miss. A flag present at runtime but
  absent from the matched table entry gets CONTESTED + nil rank.

## Testing

- **Build script:** assert bastogne yields 11 flags, f6/f5 axis < 0.4, f10 axis > 0.59,
  and that the third z-coordinate on base positions is parsed without error.
- **LabelFlags (unit, mocked Scene.Flags + team):**
  - bastogne fingerprint + team a: f10 sector ENEMY and rank 1; f5 OWN and rank 11.
  - bastogne fingerprint + team b: orientation inverts (f5/f6 become ENEMY-side, f10
    becomes OWN-side); rank 1 flips to the opposite end.
  - unknown fingerprint: every flag CONTESTED, rank nil, one SECTOR_FALLBACK log.
- Gates (existing): `luac -p bot.lua`, `luac -p bot.data.lua`, `luac -p flag_sectors.lua`,
  `lua tests/phase_spec.lua`, `lua tests/integration_spec.lua`.
