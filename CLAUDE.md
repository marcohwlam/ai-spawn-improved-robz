# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A pure-Lua bot-AI override mod for **Men of War: Assault Squad 2** (game 3.262), designed to run on top of the **RobZ Realism Mod 1.30.x**. It ships no new entities/assets — it replaces stock bot spawn logic with a phase-based, four-tier wave system, group-based flag routing, and recharge-aware unit pooling. Load order matters: this mod must load **after** RobZ Realism so its `bots_generic.inc` override wins.

Read `ARCHITECTURE.md` first — it's the authoritative structural map (module diagram, per-quant data flow, subsystem breakdown). `README.md` has a feature-level summary and install notes. This file only covers what those two don't: commands and repo-specific conventions.

## Commands

### Lua tests (offline, no game engine required, stock Lua 5.x)

```sh
cd resource/script/multiplayer
luac -p bot.lua && luac -p bot.data.lua   # syntax check before running specs
for f in tests/*_spec.lua; do lua "$f"; done   # run the whole suite
lua tests/phase_spec.lua                  # run a single spec
```

Specs use a bare-`assert`-with-print-OK style (no external framework); `tests/harness.lua` is the shared assertion helper. Always run the full suite before committing a change to `bot.lua`/`bot.data.lua`/`flag_sectors.lua` — these files have no compiler-level cross-checking and a change to one routing function can silently break another spec.

### Python tools (offline dev-time generators, one script per concern, run manually)

```sh
cd tools
python3 build_sectors.py <map.pak> <map_name> [<map_name> ...] -o ../resource/script/multiplayer/flag_sectors.lua
python3 check_unit_roster.py <gamelogic.pak> ../resource/script/multiplayer/bot.data.lua
python3 test_build_sectors.py        # each build_*.py has a matching test_build_*.py, run directly
python3 test_check_unit_roster.py
```

No pytest — tests are plain scripts with bare `assert` statements, printing an `OK` line per section on success. All of these read live game data from the installed RobZ mod's `.pak` (zip) archives at a hardcoded path under `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/` — they are dev-time only and never run in-game. `build_sectors.py` aborts the whole batch (`SystemExit`) if any single map lacks clear a-base/b-base markers; run failing maps individually to isolate them, then re-batch the maps that succeed.

### Manual in-game verification

There's no automated in-game test. After a behavioral change, the practical verification loop is: deploy (the mod folder is a symlink into the game's `mods/` directory), play or observe a match, and cross-check `game.log` (`ReadMapName()`/`[AISPAWN]` log lines) against expected behavior.

## Architecture (see ARCHITECTURE.md for full detail)

Three Lua runtime files, one `require`ing the next, all reloaded fresh every match (`OnGameStart` re-seeds the single mutable `Context` table — no persistence across matches):

- `bot.lua` — the bot brain: phase/tier/wave spawn economy, groups, flag routing, idle trickles. All state lives in one global `Context` table.
- `bot.data.lua` — static config: `UnitClass` roster (per-faction unit pools with `unit=`/`priority=`/`unlock=`/etc.), `Phases`/`FactionPhases` (per-faction EARLY/MID/LATE boundaries), `Purchases`.
- `flag_sectors.lua` — generated static data (via `tools/build_sectors.py`): per-map flag coordinates, OWN/CONTESTED/ENEMY sector labels, base positions. Covers 54/57 RobZ 1v1/2v2/3v3 maps; 3 maps have no clear base markers and are uncovered.

`resource/set/multiplayer/games/bots_generic.inc` (AI economy tuning) and `resource/set/stuff/{gun,reactive}/` (artillery `PrepareTime=0` presets) are asset/config-level, independent of the Lua stack — the engine reads them directly.

### Non-negotiable invariant

The flag-routing filter chain (`PickGroupTarget`/`FlagTier`/`IsFrontier`) must never return `nil` while any attackable flag exists — always fall back a stage rather than stall a group. This was a past regression; don't reintroduce it.

### Data-correctness discipline (learned the hard way this project's history)

`bot.data.lua`'s `unit=` ids are hand-typed strings referencing RobZ's own packed roster data (`gamelogic.pak`, `set/multiplayer/units/<faction>/*.set`). Two bug classes recur and are silent until someone plays a match and notices a unit never spawns:

1. **Nonexistent id** — a typo or guessed id matching nothing in the real roster.
2. **Wrong-faction id** — a real id, but registered under a different faction (e.g. a `ger_ss` roster entry that's actually `ger`'s unsuffixed id). RobZ sometimes multiplexes one faction's units inside a sibling faction's `.set` file (tagged `side(<faction>) name(<id>)`) rather than a dedicated per-faction file — verify against the *tag*, not just which directory a file lives in.

**Never guess a `unit=` id.** Verify against the actual `.set` file content in the installed pak before editing `bot.data.lua`. `tools/check_unit_roster.py` automates this cross-check — run it after any roster edit; it exits non-zero and lists `NOT_FOUND`/`MISMATCH` problems if anything is wrong. The actual spawnable id is usually a `v1(...)` breed reference or squad `name(...)` value, not necessarily the `.set` file's button key.

### Design docs

`docs/superpowers/archive/specs/` holds approved design specs for shipped features (one per feature), `docs/superpowers/archive/plans/` holds their implementation plans, `docs/superpowers/roadmap.md` tracks known gaps and future work. `ARCHITECTURE.md`'s "Known gaps" section lists the currently-open ones (lateral partition degradation, in-progress work). New, not-yet-shipped design specs go in `docs/superpowers/specs/` (created fresh per feature) until the feature ships, then move to the archive.
