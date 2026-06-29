# ReadMapName Design

**Date:** 2026-06-29
**Status:** Approved design, ready for plan
**Goal:** Identify the loaded map by name so flag-sector intelligence works on every map, replacing the flag-name fingerprint that collides across 20 of 24 maps.

## Problem

The bot sandbox exposes no map/mission/scene name API (confirmed: `root` is an empty
table, every speculative global returns nil). The previous map key was a fingerprint of
the sorted flag names. That fingerprint is ambiguous: of 24 RobZ 1v1/2v2 maps only 4 have
unique flag-name sets; the other 20 share 3 collision groups, so they cannot be told apart
and would load the wrong map's geometry.

In-game probing proved the engine writes the loaded map into `game.log`:

```
Starting "multi/2v2_bastogne:battle_zones"
```

and that the bot sandbox has full `io`/`os` access. Reading that line yields an unambiguous
map identity for all maps, including modded maps never enumerated offline (verified:
`2v2_gsm_westland` was read correctly though it is not in the sector table).

## Decisions

- **Map name replaces the fingerprint as the only sector-table key.** `Sectors` is keyed by
  map name. There is no fingerprint lookup fallback. If the name cannot be read or is absent
  from the table, the bot uses the existing all-CONTESTED / no-partition fallback (today's
  legacy behavior). Chosen for simplicity; the fingerprint path added complexity that only
  ever helped the 4 unique maps.
- **Log path is derived from environment, never hardcoded.** No baked-in username or
  Proton-specific path. Proton is covered by `USERPROFILE` (Wine returns
  `C:\users\steamuser`); native Windows is covered by the same variable.
- **Map name is the base token**, e.g. `2v2_bastogne`, stripped of the `:battle_zones`
  variant suffix and the `multi/` prefix. This matches the map directory name that
  `build_sectors.py` already uses.
- **Game has no macOS build** — no macOS path is attempted.

## Architecture

```
                 OnGameStart()
                      |
        +-------------+--------------+
        v             v              v
  ReadMapName()   LabelFlags()   PartitionFlags()
        |             |              |
        |   read Context.MapName <---+ (shared)
        |
        +- resolve path from env candidates (ordered)
        +- tailRead(path): open, seek end-64KB, read tail
        +- ParseMapName(text)   <-- pure, unit-testable
                  |
                  +- last  Starting "multi/<X>:..."  -> "<X>"

  Sectors[mapname]  <-- flag_sectors.lua (re-keyed by build_sectors.py)
```

## Data flow

```
game.log (engine-written, before bot OnGameStart)
   |  'Starting "multi/2v2_bastogne:battle_zones"'
   v
env-derived path candidates (first that parses wins)
   v
tailRead (last 64KB; full-file scan only if tail has no hit)
   v
ParseMapName  -->  "2v2_bastogne"  -->  Context.MapName
                                             |
                         +-------------------+
                         v                   v
             Sectors["2v2_bastogne"]?   (nil -> all-CONTESTED + SECTOR_FALLBACK log)
                         |
              +----------+----------+
              v                     v
        LabelFlags             PartitionFlags
        (sector/rank/axis)     (lateral split)
```

## Components

### `ParseMapName(text)` — pure function
- Input: a string (log text).
- Scans lines, keeps the **last** line containing `Starting "multi/`.
- Extracts the token after `multi/` up to the first `:` or `"`.
- Returns the token (e.g. `2v2_bastogne`), or `nil` if no matching line.
- Pure: no `io`. This is the unit-tested seam.

### `ReadMapName()` — io wrapper
- Builds an ordered candidate path list from environment (see below).
- For each candidate (skipping any whose env var is nil): `tailRead` then `ParseMapName`;
  the first candidate that yields a non-nil name wins.
- Everything wrapped in `pcall`; on any failure returns `nil`.

Path candidates (constant tails; `\` for Windows-style bases, `/` for nix bases):

```
TAIL_WIN = [[\Documents\my games\men of war - assault squad 2\log\game.log]]
TAIL_NIX =  [[/Documents/my games/men of war - assault squad 2/log/game.log]]

1. os.getenv("USERPROFILE") .. TAIL_WIN                 -- Windows native + Proton
2. os.getenv("USERPROFILE") .. [[\OneDrive]] .. TAIL_WIN -- Windows + OneDrive-redirected Documents
3. os.getenv("HOME") .. TAIL_NIX                        -- hypothetical native Linux build
```

### `tailRead(path)` — bounded read
- `io.open(path, "r")`; `seek("end")` for size; `seek("set", max(0, size - 65536))`;
  read remainder; close.
- Returns the tail text, or escalates to a full read if the tail has no `Starting "multi/`
  line (covers a single match that logged more than 64KB after its Starting line).
- `pcall`-wrapped.

### `OnGameStart` integration
- Set `Context.MapName = ReadMapName()` **before** `LabelFlags()` and `PartitionFlags()`.

### `LabelFlags` change
- Look up `Sectors[Context.MapName]` instead of `Sectors[FlagFingerprint()]`.
- Unmapped/nil name: unchanged all-CONTESTED fallback, log
  `SECTOR_FALLBACK map=<name|nil> fp=<fingerprint>` (fingerprint kept for diagnostics only).

### `FlagFingerprint`
- Retained, but only feeds the diagnostic `SECTOR_FALLBACK` log line. No longer keys lookup.

### `build_sectors.py` change
- Key each entry by the map directory name (`m`) instead of `fingerprint(flags)`.
- Regenerate `flag_sectors.lua` for the 4 current maps: `2v2_bastogne`,
  `2v2_sidi_el-barrani`, `1v1_nikolaev`, `2v2_mamayev_kurgan`.

## Error handling

| Condition | Behavior |
|---|---|
| `USERPROFILE` and `HOME` both nil | All candidates skipped, `ReadMapName` returns nil |
| File missing / unreadable / seek fails | `pcall` catches, that candidate yields nil, try next |
| File opens but has no `Starting "multi/"` line | That candidate yields nil, try next |
| Tail has no hit but full file does | Full-file scan returns the name |
| `Context.MapName` nil or not in `Sectors` | all-CONTESTED + no-partition fallback (legacy) |

The bot never crashes on any path failure; the worst case is today's legacy behavior.

## Testing

- **`ParseMapName` unit tests** (pure, no io): multiple `Starting "multi/..."` lines (assert
  the last wins), a line with `:variant` suffix (assert suffix stripped), a `multi/<X>"`
  line with no colon, and text with no match (assert nil).
- **`sector_spec` / `partition_spec`**: set `Context.MapName = "2v2_bastogne"`, key the test
  `Sectors` by map name, keep the existing bastogne assertions.
- **`ReadMapName` / `tailRead`** (io): not unit-tested; the in-game MAPPROBE already confirmed
  the read works on Proton and the env candidates resolve.

## Out of scope

- Adding the 20 colliding maps' geometry to the sector table (separate task: run
  `build_sectors.py` over those `.mi` files).
- Phase 3 routing (consuming the labels in flag selection).
- macOS support (no game build exists).
