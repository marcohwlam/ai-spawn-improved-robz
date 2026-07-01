# Unit Roster Check Tool — Design

## Problem

`bot.data.lua`'s per-faction `Purchases[i].Units[faction]` tables reference unit ids by hand-typed string literal. This session surfaced two recurring bug classes that are invisible until someone plays a match and notices a unit never spawns:

1. **Nonexistent id** — a typo or guessed id that matches nothing in the actual RobZ roster data (e.g. an early guess of `light_mortar(ger)` when the real id is `light_mortar_ger`).
2. **Wrong-faction id** — an id that is real but registered under a *different* faction's roster, typically from copy-pasting a sibling faction's block without re-pointing the ids (e.g. `ger_ss`'s Tank/HeavyTank/ATTank entries were verbatim `ger` ids; RobZ registers separate SS-owned breeds like `pz3_m_ss`, `hetzer_ss`, `pz5a`, `pz6h`, `pz6bh_ss` that were never used).

Both classes were found this session only through manual, ad-hoc agent searches into the RobZ mod's packed `.pak` (zip) game data. This tool turns that manual process into a repeatable, offline script.

## Scope

- Read-only check. Never modifies `bot.data.lua`.
- One-shot CLI script, run by hand, output to stdout — matching the existing `tools/build_sectors.py` convention (no CI/hook integration).
- Exact-id matching only, no whitelist for intentionally-shared ids (per user decision — cross-faction shares like `pz2l`/`sdkfz222` being valid for both `ger` and `ger_ss` will simply show as OK since they're present in both factions' roster data).
- Only checks `unit=` id existence and faction ownership. Does not validate other fields (`min_income`, `min_team`, `unlock`, `weight`, `priority`, etc.) — out of scope per user decision.
- Only lists problems; does not suggest or auto-apply fixes.

## Inputs

- `resource/script/multiplayer/bot.data.lua` (this repo) — source of unit ids to check, grouped by faction key (`ger`, `ger_ss`, `ger2`, `rus`, `rus_guard`, `jap`, `eng`, `usa`).
- RobZ mod's `gamelogic.pak` (path supplied as a CLI arg, same pattern as `build_sectors.py`'s `pak` arg) — source of ground-truth roster data, under `set/multiplayer/units/<faction>/*.set`.

## Design

### Architecture

```
+----------------------+       +---------------------------+
| gamelogic.pak (zip)   |       | bot.data.lua (Lua table)  |
| set/multiplayer/      |       | Purchases[i].Units[fac] = |
|   units/<faction>/*.set|      |   { unit="...", ... }     |
+-----------+-----------+       +-------------+-------------+
            |                                 |
            v                                 v
   +-----------------+             +----------------------+
   | roster scanner   |             | bot-data extractor   |
   | -> per-faction   |             | -> [(faction, id,    |
   |    id set        |             |     line#), ...]     |
   +--------+---------+             +----------+-----------+
            |                                  |
            +----------------+-----------------+
                             v
                    +-------------------+
                    |  cross-checker     |
                    |  id in own faction?|
                    |  id in other one?  |
                    |  id nowhere?       |
                    +---------+----------+
                              v
                    +-------------------+
                    | report (stdout)    |
                    | OK / MISMATCH /    |
                    | NOT_FOUND per id   |
                    +-------------------+
```

### Data flow

1. **Roster scan.** For each known faction directory under `set/multiplayer/units/<faction>/` in `gamelogic.pak`, read every `.set` file in that directory and collect every quoted token that plausibly identifies a spawnable unit: roster button keys (`{"<id>" (...)}`) and breed references inside `v1(...)`/`v(...)`/`c1(...)` macros. Build `roster_ids[faction] = set(...)`.
2. **Bot-data extraction.** Parse `bot.data.lua` line by line, tracking the current `["faction"] = {` block, and extract every `unit="..."` value with its line number. Strip a trailing `(faction)` annotation (the bot mod's own convention) before comparison, since that suffix is not always part of the real RobZ id (confirmed this session: real ids sometimes use it, e.g. `grenadiers_elite(ger)`, and sometimes don't, e.g. `light_mortar_ger`, `pz2l`) — the comparison must try both the raw string and the suffix-stripped form against roster data.
3. **Cross-check.** For each `(faction, id, line)`:
   - if `id` (or its suffix-stripped form) is in `roster_ids[faction]` → OK, no output.
   - elif it is in some other faction's `roster_ids[other]` → report `MISMATCH`: this faction is using an id owned by `other`.
   - else → report `NOT_FOUND`: id does not appear in any faction's roster data at all.
4. **Report.** Print one line per problem, grouped by faction: `<faction> line <N>: <id> — MISMATCH (belongs to <other>)` or `<faction> line <N>: <id> — NOT_FOUND`.

## Error handling

- If a faction directory doesn't exist in the pak (e.g. a faction key in `bot.data.lua` that has no RobZ roster folder), report it as a warning and skip that faction's cross-check rather than crashing.
- If `bot.data.lua` can't be parsed for a given line, skip it silently (this is a heuristic string extractor, not a full Lua parser) — the tool is a review aid, not a build-breaking gate.

## Testing

- Manual: run against current `bot.data.lua` + the installed RobZ pak, confirm it reproduces (as MISMATCH) all of the id problems already found and fixed this session (the pre-fix `ger_ss` tank ids, the earlier wrong mortar suffix guess), by temporarily checking out the pre-fix versions of those entries.
- No automated test suite entry needed — this is an offline dev tool like `build_sectors.py`, not part of the Lua bot's runtime (`tests/*_spec.lua` covers runtime behavior only).
