# Unit Roster Check Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `tools/check_unit_roster.py`, a one-shot offline script that cross-checks every `unit="..."` id in `resource/script/multiplayer/bot.data.lua` against the real RobZ `gamelogic.pak` roster data, and reports ids that don't exist (`NOT_FOUND`) or are registered under a different faction (`MISMATCH`).

**Architecture:** Four small pure functions plumbed together by a thin `main()`: (1) scan each faction's `.set` files inside `gamelogic.pak` for known-good ids, (2) extract every `unit="..."` id from `bot.data.lua` grouped by faction block, (3) cross-check each extracted id against the per-faction and cross-faction id sets, (4) print one line per problem. Read-only throughout; the tool never writes to `bot.data.lua`.

**Tech Stack:** Python 3 standard library only (`re`, `zipfile`, `argparse`, `sys`) — same as the existing `tools/build_sectors.py`, `tools/build_arty_roster.py`. Tests are plain `assert`-based scripts run directly with `python3`, matching `tools/test_build_sectors.py`'s existing convention (no pytest).

## Global Constraints

- Read-only: never modifies `bot.data.lua`. (spec: Scope)
- One-shot CLI script, run by hand, output to stdout. No CI/hook integration. (spec: Scope)
- Exact-id matching only; no whitelist for intentionally cross-faction-shared ids. (spec: Scope)
- Only checks `unit=` id existence and faction ownership — does not validate `min_income`/`min_team`/`unlock`/`weight`/`priority`. (spec: Scope)
- Only lists problems; does not suggest or auto-apply fixes. (spec: Scope)
- If a faction directory is missing from the pak, warn and skip that faction rather than crash. (spec: Error handling)
- If a line in `bot.data.lua` can't be parsed, skip it silently — heuristic extractor, not a full Lua parser. (spec: Error handling)

---

## File Structure

- Create: `tools/check_unit_roster.py` — the tool (scanner + extractor + checker + CLI).
- Create: `tools/test_check_unit_roster.py` — assert-based tests, run directly with `python3 tools/test_check_unit_roster.py` (same convention as `tools/test_build_sectors.py`).

Both files live flat in `tools/`, matching every existing tool in that directory (`build_sectors.py`/`test_build_sectors.py`, `build_arty_roster.py`/`test_build_arty_roster.py`, etc.) — one file per tool, one file per test, no shared helper module (YAGNI: there's no second consumer of these functions yet).

## Reference data (confirmed this session, do not re-derive)

- RobZ pak path used for all manual testing: `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/gamelogic.pak`
- Faction directories under `set/multiplayer/units/` in that pak: `eng`, `ger`, `ger_ss`, `ger2`, `usa`, `rus`, `rus_guard`, `jap` (plus an unrelated `axis_minor` directory — not a `bot.data.lua` faction key, do not include it).
- `bot.data.lua`'s faction-block keys (verified via `grep -n '^\s*\["[a-z_0-9]*"\]\s*=\s*{'`): `eng` (line 59), `ger` (line 99), `ger_ss` (line 154), `usa` (line 199), `rus` (line 244), `jap` (line 285), `ger2` (line 326), `rus_guard` (line 362). These are the ONLY blocks that should be scanned — the file also has a `FactionPhases` table (lines 43-51) with entries like `["ger"] = { mid = 630, late = 1500 },` that must NOT be mistaken for a unit block. The distinguishing feature: a real faction-unit block's opening line ends in `= {` with nothing else after it; `FactionPhases` entries have `mid = ..., late = ...` (and sometimes more) on the same line, so they never match a regex requiring end-of-line right after `{`.
- Roster `.set` file entry shapes (both confirmed by direct inspection this session):
  - Vehicles (e.g. `set/multiplayer/units/ger_ss/vehicles_44.set`): `{"pz3_ss" ("vs_ss" c(10) v1(pz3_m_ss) t(...) s(ger_ss) ...) {level 1} {cost ...} {fore ...}}` — the spawnable id the bot mod actually uses is the `v1(...)` value (`pz3_m_ss`), NOT the quoted button key (`pz3_ss`).
  - Squads (e.g. `set/multiplayer/units/rus/squads_43-45.set`): `("i_seq_with3types" side(rus) name(smgs) c(0) g(squad_2) ...)` — the spawnable id is the `name(...)` value (`smgs`), matching `bot.data.lua`'s `unit="smgs(rus)"` once the `(rus)` suffix is stripped.
  - Some vehicle entries lack `v1(...)` entirely and are referenced by their own quoted button key directly — include that as a third fallback id source.

---

### Task 1: Roster scanner — read known-good ids per faction from the pak

**Files:**
- Create: `tools/check_unit_roster.py` (new file, this task adds `FACTIONS`, `ID_PATTERNS`, `scan_faction_ids`, `build_roster_index`)
- Test: `tools/test_check_unit_roster.py` (new file, this task adds the roster-scanner tests)

**Interfaces:**
- Produces: `FACTIONS: list[str]` — the 8 faction keys above, in the exact order listed.
- Produces: `scan_faction_ids(pak_path: str, faction: str) -> tuple[set[str], list[str]]` — returns `(ids, matched_filenames)`. `ids` is every id found via any of `ID_PATTERNS` across every `.set` file under `set/multiplayer/units/<faction>/` in the pak. `matched_filenames` is the list of `.set` file paths that were scanned (empty list if the faction directory doesn't exist in the pak).
- Produces: `build_roster_index(pak_path: str, factions: list[str]) -> tuple[dict[str, set[str]], dict[str, list[str]]]` — returns `(index, files)` where `index[faction]` is the id set from `scan_faction_ids` and `files[faction]` is its matched filename list, for every faction in `factions`.

- [ ] **Step 1: Write the failing test**

Create `tools/test_check_unit_roster.py` with:

```python
#!/usr/bin/env python3
"""Asserts check_unit_roster scans the real RobZ pak correctly. Run from the tools/ dir."""
import check_unit_roster as cur

PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
       "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

# --- Task 1: roster scanner ---
ids, files = cur.scan_faction_ids(PAK, "ger_ss")
assert files, "expected at least one .set file for ger_ss"
assert "pz3_m_ss" in ids, "pz3_m_ss (v1 breed) should be found in ger_ss roster"
assert "hetzer_ss" in ids, "hetzer_ss (v1 breed) should be found in ger_ss roster"
assert "wespe_ss" in ids, "wespe_ss (v1 breed) should be found in ger_ss roster"

ids_rus, files_rus = cur.scan_faction_ids(PAK, "rus")
assert files_rus, "expected at least one .set file for rus"
assert "smgs" in ids_rus, "smgs (name()) should be found in rus roster"
assert "riflemans" in ids_rus, "riflemans (name()) should be found in rus roster"

missing_ids, missing_files = cur.scan_faction_ids(PAK, "not_a_real_faction")
assert missing_files == [], "nonexistent faction directory should yield no files"
assert missing_ids == set(), "nonexistent faction directory should yield no ids"

index, files_by_faction = cur.build_roster_index(PAK, cur.FACTIONS)
assert set(index.keys()) == set(cur.FACTIONS)
assert all(files_by_faction[f] for f in cur.FACTIONS), \
    "every real faction should have at least one .set file: %r" % {
        f: files_by_faction[f] for f in cur.FACTIONS if not files_by_faction[f]}
print("roster scanner test OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: `ModuleNotFoundError: No module named 'check_unit_roster'` (the file doesn't exist yet)

- [ ] **Step 3: Write minimal implementation**

Create `tools/check_unit_roster.py`:

```python
#!/usr/bin/env python3
"""Cross-checks unit="..." ids in bot.data.lua against the real RobZ roster
data per faction. Read-only report; never modifies bot.data.lua.
Run: python3 tools/check_unit_roster.py <gamelogic.pak> <bot.data.lua>"""
import re, sys, zipfile, argparse

FACTIONS = ["eng", "ger", "ger_ss", "ger2", "usa", "rus", "rus_guard", "jap"]

ID_PATTERNS = [
    re.compile(r'\bv1\(([A-Za-z0-9_\-.]+)\)'),     # vehicle breed reference
    re.compile(r'\bname\(([A-Za-z0-9_\-.]+)\)'),   # squad name id
    re.compile(r'\{"([A-Za-z0-9_\-.]+)"\s*\('),    # roster button key (fallback)
]

def scan_faction_ids(pak_path, faction):
    """Return (ids, matched_filenames) for set/multiplayer/units/<faction>/*.set."""
    ids = set()
    prefix = "set/multiplayer/units/%s/" % faction
    with zipfile.ZipFile(pak_path) as z:
        names = [n for n in z.namelist() if n.startswith(prefix) and n.endswith(".set")]
        for n in names:
            text = z.read(n).decode("latin-1")
            for pat in ID_PATTERNS:
                ids.update(pat.findall(text))
    return ids, names

def build_roster_index(pak_path, factions):
    """Return ({faction: set(ids)}, {faction: [set-file names]})."""
    index, files = {}, {}
    for f in factions:
        ids, names = scan_faction_ids(pak_path, f)
        index[f] = ids
        files[f] = names
    return index, files
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: `roster scanner test OK`

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/check_unit_roster.py tools/test_check_unit_roster.py
git commit -m "Add roster scanner for check_unit_roster tool"
```

---

### Task 2: bot.data.lua extraction

**Files:**
- Modify: `tools/check_unit_roster.py` (add `FACTION_BLOCK_RE`, `UNIT_RE`, `extract_bot_units`, `strip_suffix`)
- Modify: `tools/test_check_unit_roster.py` (append extraction tests)

**Interfaces:**
- Consumes: nothing from Task 1 (independent parsing logic).
- Produces: `extract_bot_units(bot_data_path: str) -> list[tuple[str, str, int]]` — list of `(faction, unit_id, line_number)` for every `unit="..."` entry found inside a `["faction"] = {` block. `line_number` is 1-indexed, matching the file's actual line count (for human cross-reference when reading a problem report).
- Produces: `strip_suffix(unit_id: str) -> str` — strips a trailing `(word)` annotation (e.g. `"grenadiers_elite(ger)"` -> `"grenadiers_elite"`); returns the input unchanged if there's no such suffix.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_check_unit_roster.py`:

```python
# --- Task 2: bot.data.lua extraction ---
import tempfile, os

SAMPLE_LUA = '''\
FactionPhases = {
\t["ger"]       = { mid = 630, late = 1500 },
\t["ger_ss"]    = { mid = 630, late = 1500 },
}

Purchases = {
\t{
\t\tUnits = {
\t\t\t["ger"] = {
\t\t\t\t{priority=2.0, class=UnitClass.Infantry, unit="volksgrens(ger)", line=true,},
\t\t\t\t{priority=1.5, class=UnitClass.Tank,     unit="pz2l", min_income=1.0,},
\t\t\t},
\t\t\t["ger_ss"] = {
\t\t\t\t{priority=1.0, class=UnitClass.Tank,     unit="pz3_m", min_income=1.0,},
\t\t\t},
\t\t},
\t},
}
'''

def _write_temp_lua(text):
    fd, path = tempfile.mkstemp(suffix=".lua")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    return path

path = _write_temp_lua(SAMPLE_LUA)
try:
    units = cur.extract_bot_units(path)
finally:
    os.remove(path)

assert ("ger", "volksgrens(ger)", 9) in units, units
assert ("ger", "pz2l", 10) in units, units
assert ("ger_ss", "pz3_m", 13) in units, units
# the FactionPhases single-line entries must NOT be picked up as unit blocks
assert not any(f in ("ger", "ger_ss") and u in ("mid", "late") for f, u, _ in units), units
assert len(units) == 3, units
print("bot.data.lua extraction test OK")

assert cur.strip_suffix("grenadiers_elite(ger)") == "grenadiers_elite"
assert cur.strip_suffix("light_mortar_ger") == "light_mortar_ger"
assert cur.strip_suffix("pz3_m") == "pz3_m"
print("strip_suffix test OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: `AttributeError: module 'check_unit_roster' has no attribute 'extract_bot_units'`

- [ ] **Step 3: Write minimal implementation**

Append to `tools/check_unit_roster.py`:

```python
FACTION_BLOCK_RE = re.compile(r'^\s*\["(\w+)"\]\s*=\s*\{\s*$')
UNIT_RE = re.compile(r'unit\s*=\s*"([^"]+)"')

def extract_bot_units(bot_data_path):
    """Return [(faction, id, lineno), ...] for every unit="..." entry inside a
    ["faction"] = { ... } block in bot.data.lua. A block opens on a line that
    ends in an unqualified "= {" (FACTION_BLOCK_RE) and closes when brace
    depth returns to zero. Single-line ["faction"] = { mid = ..., late = ... }
    entries (FactionPhases) never match FACTION_BLOCK_RE and are skipped."""
    out = []
    current = None
    depth = 0
    with open(bot_data_path) as fh:
        for lineno, line in enumerate(fh, start=1):
            if current is None:
                m = FACTION_BLOCK_RE.match(line)
                if m:
                    current = m.group(1)
                    depth = 1
                continue
            depth += line.count("{") - line.count("}")
            for um in UNIT_RE.finditer(line):
                out.append((current, um.group(1), lineno))
            if depth <= 0:
                current = None
    return out

def strip_suffix(unit_id):
    """Return the id with a trailing "(word)" annotation removed, or the id
    unchanged if it has none."""
    m = re.match(r'^(.+)\(\w+\)$', unit_id)
    return m.group(1) if m else unit_id
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: both new lines print `OK` with no assertion errors.

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/check_unit_roster.py tools/test_check_unit_roster.py
git commit -m "Add bot.data.lua unit extraction to check_unit_roster tool"
```

---

### Task 3: Cross-check logic

**Files:**
- Modify: `tools/check_unit_roster.py` (add `check`)
- Modify: `tools/test_check_unit_roster.py` (append cross-check tests)

**Interfaces:**
- Consumes: the shape of `build_roster_index`'s first return value (`dict[str, set[str]]`) from Task 1, and `extract_bot_units`'s return type (`list[tuple[str, str, int]]`) from Task 2.
- Produces: `check(roster_index: dict[str, set[str]], bot_units: list[tuple[str, str, int]]) -> list[dict]` — one dict per problem, in the shape `{"faction": str, "id": str, "line": int, "kind": "MISMATCH", "other": str}` or `{"faction": str, "id": str, "line": int, "kind": "NOT_FOUND"}`. Units whose id (or suffix-stripped form) is found in their own faction's roster set produce no entry.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_check_unit_roster.py`:

```python
# --- Task 3: cross-check logic ---
fake_index = {
    "ger":    {"pz2l", "volksgrens"},
    "ger_ss": {"pz3_m_ss", "hetzer_ss"},
    "rus":    {"smgs"},
}
fake_units = [
    ("ger", "volksgrens(ger)", 9),      # OK: suffix-stripped "volksgrens" is in ger's set
    ("ger", "pz2l", 10),                # OK: exact match in ger's set
    ("ger_ss", "pz3_m", 13),            # NOT_FOUND: bare "pz3_m" isn't in ger_ss, but...
    ("ger_ss", "hetzer_ss", 14),        # OK: exact match in ger_ss's set
    ("rus", "riflemans(rus)", 20),      # NOT_FOUND: not in rus's set or any other faction's
]
problems = cur.check(fake_index, fake_units)
by_line = {p["line"]: p for p in problems}
assert 9 not in by_line and 10 not in by_line and 14 not in by_line, problems
assert by_line[13]["kind"] == "NOT_FOUND", by_line[13]
assert by_line[20]["kind"] == "NOT_FOUND", by_line[20]
assert len(problems) == 2, problems

# MISMATCH case: an id that IS real, but under a different faction than claimed
mismatch_units = [("ger", "pz3_m_ss", 99)]   # "pz3_m_ss" only exists under ger_ss
mismatch_problems = cur.check(fake_index, mismatch_units)
assert len(mismatch_problems) == 1, mismatch_problems
assert mismatch_problems[0]["kind"] == "MISMATCH", mismatch_problems
assert mismatch_problems[0]["other"] == "ger_ss", mismatch_problems
print("cross-check test OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: `AttributeError: module 'check_unit_roster' has no attribute 'check'`

- [ ] **Step 3: Write minimal implementation**

Append to `tools/check_unit_roster.py`:

```python
def check(roster_index, bot_units):
    """Return a list of problem dicts: {faction, id, line, kind, other?}."""
    problems = []
    for faction, unit_id, lineno in bot_units:
        bare = strip_suffix(unit_id)
        candidates = {unit_id, bare}
        if candidates & roster_index.get(faction, set()):
            continue
        found_in = [f for f, ids in roster_index.items()
                    if f != faction and candidates & ids]
        if found_in:
            problems.append({"faction": faction, "id": unit_id, "line": lineno,
                              "kind": "MISMATCH", "other": found_in[0]})
        else:
            problems.append({"faction": faction, "id": unit_id, "line": lineno,
                              "kind": "NOT_FOUND"})
    return problems
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: `cross-check test OK`

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/check_unit_roster.py tools/test_check_unit_roster.py
git commit -m "Add cross-check logic to check_unit_roster tool"
```

---

### Task 4: CLI wiring + real-data integration test

**Files:**
- Modify: `tools/check_unit_roster.py` (add `main()` and `if __name__ == "__main__"` guard)
- Modify: `tools/test_check_unit_roster.py` (append integration test against the actual current repo files)

**Interfaces:**
- Consumes: `build_roster_index` (Task 1), `extract_bot_units` (Task 2), `check` (Task 3) — exact names/signatures as defined above.
- Produces: a runnable CLI: `python3 tools/check_unit_roster.py <gamelogic.pak> <bot.data.lua>`, exit code `0` with a summary line if no problems, exit code `1` with one line per problem (sorted by faction then line number) plus a summary count if any problems exist. Faction directories missing from the pak print a `WARNING:` line to stderr rather than crashing.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_check_unit_roster.py`:

```python
# --- Task 4: integration test against the real, current repo files ---
import subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOT_DATA = os.path.join(REPO_ROOT, "resource", "script", "multiplayer", "bot.data.lua")

# 4a. Direct function-level check: the CURRENT bot.data.lua (all ids fixed
# this session) should report zero problems against the real pak.
index, _ = cur.build_roster_index(PAK, cur.FACTIONS)
units = cur.extract_bot_units(BOT_DATA)
assert len(units) > 50, "sanity check: expected many unit= entries, got %d" % len(units)
problems = cur.check(index, units)
assert problems == [], "expected zero problems on current bot.data.lua, got:\n%r" % problems
print("integration (function-level) test OK: %d units, 0 problems" % len(units))

# 4b. CLI smoke test: running the script directly should exit 0 and print
# a "no problems" summary line, given the same clean current state.
result = subprocess.run(
    ["python3", "check_unit_roster.py", PAK, BOT_DATA],
    capture_output=True, text=True)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
assert "no problems found" in result.stdout, result.stdout
print("integration (CLI) test OK")

# 4c. CLI regression test: reintroduce the pre-fix ger_ss bug (unsuffixed
# "pz3_m" instead of "pz3_m_ss") in a temp copy and confirm it's caught.
with open(BOT_DATA) as f:
    real_text = f.read()
broken_text = real_text.replace(
    'unit="pz3_m_ss"', 'unit="pz3_m"', 1)
assert broken_text != real_text, "fixture assumption broke: pz3_m_ss not found in bot.data.lua"
broken_path = _write_temp_lua(broken_text)
try:
    result = subprocess.run(
        ["python3", "check_unit_roster.py", PAK, broken_path],
        capture_output=True, text=True)
finally:
    os.remove(broken_path)
assert result.returncode == 1, (result.returncode, result.stdout, result.stderr)
assert "MISMATCH" in result.stdout and "pz3_m" in result.stdout, result.stdout
print("integration (regression) test OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: `FileNotFoundError` or non-zero/garbled `subprocess.run` result, since `check_unit_roster.py` has no `main()`/CLI entry point yet (running it as a script currently does nothing because there's no `if __name__ == "__main__"` block).

- [ ] **Step 3: Write minimal implementation**

Append to `tools/check_unit_roster.py`:

```python
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pak", help="path to RobZ gamelogic.pak")
    ap.add_argument("bot_data", help="path to bot.data.lua")
    a = ap.parse_args()

    roster_index, roster_files = build_roster_index(a.pak, FACTIONS)
    for f in FACTIONS:
        if not roster_files[f]:
            print("WARNING: no roster .set files found for faction %r" % f, file=sys.stderr)

    bot_units = extract_bot_units(a.bot_data)
    problems = check(roster_index, bot_units)

    if not problems:
        print("check_unit_roster: no problems found (%d units checked)" % len(bot_units))
        return

    for p in sorted(problems, key=lambda p: (p["faction"], p["line"])):
        if p["kind"] == "MISMATCH":
            print("%s line %d: %s -- MISMATCH (belongs to %s)"
                  % (p["faction"], p["line"], p["id"], p["other"]))
        else:
            print("%s line %d: %s -- NOT_FOUND"
                  % (p["faction"], p["line"], p["id"]))
    print("%d problem(s) found out of %d units checked" % (len(problems), len(bot_units)))
    sys.exit(1)

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools && python3 test_check_unit_roster.py`
Expected: all test sections print their `OK` lines, ending with `integration (regression) test OK`, and the script exits 0.

- [ ] **Step 5: Run the full existing Lua test suite to confirm nothing else broke**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
Expected: every suite still prints its `OK` line (this task only adds new Python files under `tools/`, so this is a safety check, not expected to catch anything — but the plan's global convention this session has been to always re-run the full suite before committing).

- [ ] **Step 6: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/check_unit_roster.py tools/test_check_unit_roster.py
git commit -m "Wire up check_unit_roster CLI with real-data integration tests"
```

---

## Self-Review Notes

- **Spec coverage:** roster scan (Task 1), bot.data.lua extraction incl. suffix-stripping (Task 2), cross-check incl. MISMATCH/NOT_FOUND/OK (Task 3), CLI + stdout report + non-zero exit on problems + missing-faction warning (Task 4). All five `## Design` steps from the spec map onto these four tasks. `## Testing` section's request to reproduce a previously-fixed bug is covered by Task 4's regression sub-test (4c).
- **Placeholder scan:** no TBD/TODO; every step has complete, runnable code.
- **Type consistency:** `scan_faction_ids` returns `(set, list)` consistently used that way in Task 1's test and inside `build_roster_index`. `extract_bot_units` returns `list[tuple[str,str,int]]` consistently consumed by `check()` in Task 3 and the integration test in Task 4. `check()`'s problem-dict shape (`faction`/`id`/`line`/`kind`/`other`) is used identically in Task 3's test and Task 4's `main()`.
