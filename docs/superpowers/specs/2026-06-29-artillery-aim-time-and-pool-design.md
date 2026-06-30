# Artillery Aim-Time Zero + Pool Reference — Design Spec

Date: 2026-06-29
Status: Approved (pending written-spec review)
Repo: ai-spawn-improved-robz

## 1. Overview

Two independent deliverables, both sourced from cbyyy2013's "Better AI Performed" mod
(based on RobZ 1.28.6) and re-derived against the currently installed RobZ Realism
1.30.10 so the values are correct for the live game.

1. **Aim-time-0 weapon override** — ship weapon preset files that set artillery
   `PrepareTime` to `0`, removing the indirect-fire wind-up that prevents AI artillery
   from firing.
2. **Artillery pool reference artifact** — a corrected, current-RobZ artillery unit
   list (names, cost, unlock) the maintainer integrates into spawn logic separately.

### Goals

- AI (and player) artillery fires without the multi-second prepare delay.
- Provide a validated artillery roster keyed to current RobZ 1.30.10 unit ids.

### Non-goals

- Spawn-logic integration of the artillery list. The maintainer owns spawn; this spec
  produces a reference artifact only and does NOT edit `bot.data.lua`.
- Indirect-fire order issuance by the bot. Out of scope.
- Any range / accuracy / damage balance change. Only `PrepareTime` is touched.

## 2. Background

`PrepareTime` is a weapon-layer property in MoW:AS2 (`set/stuff/...` weapon defs). It
is NOT reachable from bot Lua, so the only way to change it is to ship overriding
weapon files. RobZ 1.30.10 findings (scraped from `gamelogic.pak`):

- Indirect-fire howitzer presets in `set/stuff/gun/.presets` carry `PrepareTime 5`
  (and `2.5`); `set/stuff/reactive/.presets` carries `PrepareTime 5`. These are the
  real AI-blocking delays.
- Most individual direct-fire guns already sit at `PrepareTime 0.0001` or `0.1`
  (effectively instant) in 1.30.10.
- `PrepareTime` is ALSO used by non-artillery: sniper aim (`rifle/sniper/*` 2.5–3.5s),
  demolition timers (`explosive/dynamite*` 7–10s), rifle grenades, and off-map
  artillery flare call-ins (`pistol/*flaregun` 6s). A blanket flip would corrupt these.

## 3. Deliverable 1 — Aim-Time-0 Weapon Override

### 3.1 File selection rule

Flip `PrepareTime` to `0` for every file under, and only under:

- `set/stuff/gun/**`   (cannon / howitzer guns, includes `.presets`)
- `set/stuff/reactive/**`  (rockets, mortars, includes `.presets` and `*.weapon`)

Explicitly EXCLUDED (left untouched, never shipped):

- `set/stuff/rifle/**` (incl. `rifle/sniper/**`)
- `set/stuff/grenade/**`
- `set/stuff/explosive/**`
- `set/stuff/pistol/**` (off-map artillery flareguns — maintainer chose to exclude)
- every other `set/stuff` subtree

Scope choice: COMPLETE — every `gun/` and `reactive/` file that contains a
`PrepareTime` token is shipped, including the ones already near-zero (`0.1`,
`0.0001`). Rationale: a single deterministic rule, no per-file cherry-picking, and the
generated tree is a clean "PrepareTime=0 across all tube/rocket artillery" overlay.

### 3.2 Transform

For each selected file, replace every `PrepareTime <number>` with `PrepareTime 0`.
No other byte changes. The output file is otherwise identical to its 1.30.10 source,
so a diff against base shows only `PrepareTime` lines.

### 3.3 Tooling — `tools/build_aim_time.py`

Mirrors the existing `tools/build_unit_meta.py` conventions: offline, run by hand,
output committed, never ships as source; re-run after a RobZ update.

Behavior:

1. Open RobZ 1.30.10 `gamelogic.pak` (same path constant as `build_unit_meta.py`).
2. For each entry whose name starts with `set/stuff/gun/` or `set/stuff/reactive/`
   AND whose bytes contain `PrepareTime`:
   - read, regex-replace `PrepareTime\s+[0-9.]+` -> `PrepareTime 0`,
   - write to `resource/set/stuff/<same relative path>` under the repo.
3. Print a report: files written, count of `PrepareTime` substitutions per file, and
   any file skipped because it matched an excluded subtree (sanity, should be none).
4. `--check` mode: regenerate to memory and assert the committed tree matches; exits
   nonzero on drift (for CI / pre-commit verification).

Encoding: `latin-1` read/write (same as `build_unit_meta.py`) to preserve bytes.

### 3.4 Output location & mod.info

- Generated files land under `resource/set/stuff/gun/` and `resource/set/stuff/reactive/`.
- `mod.info` `Desc` updated: the mod is no longer script-only; note it now ships
  artillery weapon presets (PrepareTime=0) and must load AFTER RobZ.

### 3.5 Version sync

The override freezes whatever 1.30.10 shipped EXCEPT `PrepareTime`. If RobZ changes a
gun's range/accuracy in a future version, the stale override would mask it. Mitigation:
`build_aim_time.py` is re-runnable; `--check` flags drift. Document "re-run on RobZ
update" in `tools/` and README.

### 3.6 Data flow

```
RobZ 1.30.10 gamelogic.pak
        |
        v
 [build_aim_time.py]  --- filter: gun/** , reactive/**  (exclude rifle,grenade,explosive,pistol)
        |                   --- transform: PrepareTime N -> 0
        v
 resource/set/stuff/gun/**         (committed)
 resource/set/stuff/reactive/**    (committed)
        |
        v
 game loads mod AFTER RobZ  -->  artillery fires with zero prepare delay
```

## 4. Deliverable 2 — Artillery Pool Reference Artifact

### 4.1 Source & validation

37 candidate ids from Better AI (1.28.6), validated against RobZ 1.30.10 unit sets
(`set/multiplayer/units/<nation>/vehicles_*.set`): 31 exist, 6 missing.

Missing-unit handling — the suggested replacements were all already present in the
roster, so duplicates are dropped rather than substituted:

| Missing id | Nation | Reason | Resolution |
|---|---|---|---|
| sturmtiger | ger, ger_ss | hero-only (`hero9_ger`), not in regular MP | omit |
| bishop | eng | removed | eng artillery = `m7_eng` only |
| m12gmc_vet | usa | veteran variant folded into `m12gmc` | omit |
| 203b4 | rus | moved to Guards roster | keep `203b4_guard` only |
| su152_guard | rus_guard | cut | use existing `isu152_guard` |

### 4.2 Final roster (current RobZ ids, cost mp / unlock sec)

| Nation | Units |
|---|---|
| ger | wespe 750/900 · hummel 1280/1200 · sdkfz4 650/1200 · np_sdkfz251_1w 1500/1200 |
| ger2 | wespe_ger2 750/900 · sdkfz138_1 850/900 · sdkfz251_1_stuka 1500/1200 |
| ger_ss | wespe_ss 750/900 · hummel_ss 1280/1200 · sdkfz4_ss 650/1200 · np_sdkfz251_1w_ss 1600/1200 |
| eng | m7_eng 920/900 |
| usa | m7 920/900 · m12gmc 1350/1200 · m4a3c 900/1200 · np_t19 720/900 |
| rus | su122 550/1120 · su152 750/1120 · isu152 900/1120 · bm13 850/1200 · bm_8_24 500/900 · bm8-48 650/900 · np_bm31 1450/1200 · 280br5 1600/1200 |
| rus_guard | 203b4_guard 1300/1200 · bm13_guard 850/1200 · bm_8_24_guard 500/1200 · bm8-48_guard 650/900 · isu152_guard 1000/1120 · np_bm31_guard 1450/1200 · su122_guard 650/1120 |
| jap | ha-to 1100/1200 · ho-ni2 780/900 · ho-ro 960/1200 |

### 4.3 Output format

A single committed reference document: `docs/artillery-pool-reference.md`, containing:

1. The roster table above (human reference).
2. A paste-ready Lua block per nation, in the existing `bot.data.lua` line format:

   ```lua
   {priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe", min_income=2.0, min_team=1, unlock=900,},
   ```

   Field defaults:
   - `priority = 1.0`
   - `min_income = 2.0`, raised to `2.5` for cost >= 1300
   - `min_team = 1`
   - `unlock` = validated value (also re-derivable via `build_unit_meta.py`)

The document is a reference only. It does NOT modify `bot.data.lua`.

## 5. Architecture

```
ai-spawn-improved-robz/
  tools/
    build_aim_time.py        <- NEW: generator (offline, re-runnable)
    test_build_aim_time.py   <- NEW: unit tests
  resource/set/stuff/
    gun/**                   <- NEW: generated PrepareTime=0 overrides
    reactive/**              <- NEW: generated PrepareTime=0 overrides
  docs/
    artillery-pool-reference.md  <- NEW: roster + paste-ready Lua
  mod.info                   <- EDIT: Desc notes shipped weapon presets
```

Two units of work, no shared state: the generator (D1) and the reference doc (D2) are
produced independently and can be reviewed independently.

## 6. Testing

- `tools/test_build_aim_time.py` (unittest, mirrors `test_build_unit_meta.py`):
  - a `gun/` sample with `PrepareTime 5` -> output `PrepareTime 0`, all other lines byte-identical.
  - a file with multiple `PrepareTime` tokens -> all flipped.
  - an excluded path (`rifle/sniper/...`) -> never emitted.
  - idempotency: running on already-zero input yields no further change.
- Verification after generation: diff each generated file against its 1.30.10 source;
  the only differing lines must be `PrepareTime`. `build_aim_time.py --check` enforces
  the committed tree equals a fresh regenerate.

## 7. Risks / Tradeoffs

- **Global effect.** The override applies to player and all factions, not AI-only.
  Accepted: matches Better AI behavior and there is no weapon-layer way to scope to AI.
- **Breaks "script-only" identity.** The mod now ships weapon assets. Accepted;
  documented in `mod.info` and README.
- **Version drift.** Mitigated by the re-runnable generator and `--check`.
- **AI may still not indirect-fire.** Zeroing prepare time is necessary but the bot
  must still order fire for indirect use; direct-fire-capable artillery (Wespe, SU-122,
  etc.) benefits immediately. Out of scope here; flagged for the spawn work.
