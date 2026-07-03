# Artillery Aim-Time Zero + Pool Reference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an offline generator that zeroes artillery `PrepareTime` in RobZ weapon presets, plus a validated artillery-pool reference document.

**Architecture:** A hand-run Python generator (`tools/build_aim_time.py`) reads RobZ 1.30.10 `gamelogic.pak`, filters to `set/stuff/gun/**` and `set/stuff/reactive/**`, rewrites `PrepareTime N` to `PrepareTime 0`, and writes the result under `resource/set/stuff/`. A separate static doc lists the corrected artillery roster. The two deliverables share no state.

**Tech Stack:** Python 3 stdlib (`re`, `zipfile`, `os`, `argparse`); plain-assert test scripts run from `tools/`; Lua data format for the reference snippets.

## Global Constraints

- Only `PrepareTime` may change in generated weapon files; every other byte identical to the 1.30.10 source.
- Override scope is exactly `set/stuff/gun/**` and `set/stuff/reactive/**`. Never emit `rifle/**`, `grenade/**`, `explosive/**`, or `pistol/**`.
- Generator is offline, output committed, never shipped as source; re-runnable after a RobZ update.
- File I/O uses `latin-1` to preserve bytes (matches `build_unit_meta.py`).
- Tests are plain `assert` scripts run as `python test_*.py` from `tools/` (no pytest/unittest framework).
- RobZ pak path constant: `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/gamelogic.pak`.
- Deliverable 2 does NOT modify `bot.data.lua`; it is a reference document only.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: Pure transform + path-filter functions

**Files:**
- Create: `tools/build_aim_time.py`
- Test: `tools/test_build_aim_time.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `is_target(name: str) -> bool` — True for a pak entry under `set/stuff/gun/` or `set/stuff/reactive/` that is a file (not a `/`-terminated dir).
  - `flip_prepare(data: bytes) -> tuple[bytes, int]` — returns data with every `PrepareTime <number>` rewritten to `PrepareTime 0`, and the substitution count.
  - Module constant `ROBZ_PAK: str`.

- [ ] **Step 1: Write the failing test**

Create `tools/test_build_aim_time.py`:

```python
#!/usr/bin/env python3
"""Asserts build_aim_time filters paths and zeroes PrepareTime. Run from tools/."""
import build_aim_time as m

# --- is_target ---
assert m.is_target("set/stuff/gun/.presets") is True
assert m.is_target("set/stuff/gun/105mm_m2a1_2") is True
assert m.is_target("set/stuff/reactive/380mm_rw61_2.weapon") is True
assert m.is_target("set/stuff/reactive/.presets") is True
assert m.is_target("set/stuff/gun/") is False            # dir entry
assert m.is_target("set/stuff/rifle/sniper/em2_vet") is False
assert m.is_target("set/stuff/explosive/dynamite") is False
assert m.is_target("set/stuff/pistol/artillery_105_flaregun") is False
assert m.is_target("set/stuff/grenade/grenade_ap.pattern") is False
print("is_target OK")

# --- flip_prepare ---
out, n = m.flip_prepare(b"\t{PrepareTime 5}\n")
assert out == b"\t{PrepareTime 0}\n", out
assert n == 1, n
out, n = m.flip_prepare(b"{PrepareTime 2.5}{PrepareTime 0.0001}")
assert out == b"{PrepareTime 0}{PrepareTime 0}", out
assert n == 2, n
# already zero: still matches once, result unchanged
out, n = m.flip_prepare(b"{PrepareTime 0}")
assert out == b"{PrepareTime 0}", out
assert n == 1, n
# no token: untouched, zero subs
out, n = m.flip_prepare(b"{range 250 250}")
assert out == b"{range 250 250}", out
assert n == 0, n
# byte preservation around the token
out, n = m.flip_prepare(b"{Mode aim}\n\t\t{PrepareTime 0.1}\n{Cursor x}")
assert out == b"{Mode aim}\n\t\t{PrepareTime 0}\n{Cursor x}", out
print("flip_prepare OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools && python test_build_aim_time.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'build_aim_time'`

- [ ] **Step 3: Write minimal implementation**

Create `tools/build_aim_time.py`:

```python
#!/usr/bin/env python3
"""Offline artillery aim-time zeroer for AI Spawn Improved.
Reads RobZ 1.30.10 gamelogic.pak; for every weapon file under set/stuff/gun/ and
set/stuff/reactive/ that contains a PrepareTime token, writes a copy under
resource/set/stuff/<same path> with every `PrepareTime N` rewritten to `PrepareTime 0`.
Run by hand; output is committed; never ships as source. Re-run after a RobZ update.
Deliberately excludes rifle/sniper aim, demolition timers, rifle grenades, and off-map
flareguns (those also use PrepareTime but are not unit artillery)."""
import os, re, zipfile, argparse

ROBZ_PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
            "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

_PREP = re.compile(rb"PrepareTime\s+[0-9.]+")
_TARGET_PREFIXES = ("set/stuff/gun/", "set/stuff/reactive/")

def is_target(name):
    """True if this pak entry is an artillery weapon file we should override."""
    return name.startswith(_TARGET_PREFIXES) and not name.endswith("/")

def flip_prepare(data):
    """bytes -> (bytes, count): rewrite every `PrepareTime N` to `PrepareTime 0`."""
    return _PREP.subn(b"PrepareTime 0", data)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools && python test_build_aim_time.py`
Expected: PASS — prints `is_target OK` then `flip_prepare OK`

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/build_aim_time.py tools/test_build_aim_time.py
git commit -m "feat: aim-time generator pure functions (is_target, flip_prepare)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Pak generation, check mode, and CLI

**Files:**
- Modify: `tools/build_aim_time.py`
- Test: `tools/test_build_aim_time.py` (append cases)

**Interfaces:**
- Consumes: `is_target`, `flip_prepare` from Task 1.
- Produces:
  - `generate(pak_path: str, out_root: str, write: bool=True) -> dict` — iterates pak entries; for each target entry containing `PrepareTime`, computes the flipped bytes and (if `write`) writes to `os.path.join(out_root, name)` creating dirs. Returns `{"written": [name,...], "skipped_no_prepare": int, "subs": {name: count}}`.
  - `check(pak_path: str, out_root: str) -> list[str]` — returns the list of target paths whose committed file is missing or differs from a fresh regenerate (empty list = in sync).
  - `main()` — argparse CLI: `--robz-pak` (default `ROBZ_PAK`), `--out-root` (default `../resource`), `--check` flag.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_build_aim_time.py`:

```python
import io, os, tempfile, zipfile

def _make_pak(path, entries):
    with zipfile.ZipFile(path, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data)

# --- generate: only target files with PrepareTime are written and flipped ---
with tempfile.TemporaryDirectory() as tmp:
    pak = os.path.join(tmp, "gamelogic.pak")
    out = os.path.join(tmp, "resource")
    _make_pak(pak, {
        "set/stuff/gun/.presets":        b"{range 250 250}\n{PrepareTime 5}\n",
        "set/stuff/reactive/x.weapon":   b"{PrepareTime 0.1}\n",
        "set/stuff/gun/no_prep":         b"{range 100 100}\n",          # target, no token
        "set/stuff/rifle/sniper/s_vet":  b"{PrepareTime 2.5}\n",        # excluded
    })
    rep = m.generate(pak, out, write=True)
    assert sorted(rep["written"]) == ["set/stuff/gun/.presets",
                                      "set/stuff/reactive/x.weapon"], rep
    assert rep["skipped_no_prepare"] == 1, rep
    with open(os.path.join(out, "set/stuff/gun/.presets"), "rb") as f:
        body = f.read()
    assert body == b"{range 250 250}\n{PrepareTime 0}\n", body
    assert not os.path.exists(os.path.join(out, "set/stuff/rifle/sniper/s_vet"))
    # check: freshly written tree is in sync
    assert m.check(pak, out) == [], m.check(pak, out)
    # tamper one file -> check reports drift
    with open(os.path.join(out, "set/stuff/reactive/x.weapon"), "wb") as f:
        f.write(b"{PrepareTime 9}\n")
    assert m.check(pak, out) == ["set/stuff/reactive/x.weapon"], m.check(pak, out)
print("generate/check OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools && python test_build_aim_time.py`
Expected: FAIL with `AttributeError: module 'build_aim_time' has no attribute 'generate'`

- [ ] **Step 3: Write minimal implementation**

Append to `tools/build_aim_time.py`:

```python
def generate(pak_path, out_root, write=True):
    report = {"written": [], "skipped_no_prepare": 0, "subs": {}}
    with zipfile.ZipFile(pak_path) as z:
        for name in z.namelist():
            if not is_target(name):
                continue
            data = z.read(name)
            if b"PrepareTime" not in data:
                report["skipped_no_prepare"] += 1
                continue
            new, n = flip_prepare(data)
            report["written"].append(name)
            report["subs"][name] = n
            if write:
                dest = os.path.join(out_root, name)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(new)
    return report

def check(pak_path, out_root):
    drift = []
    with zipfile.ZipFile(pak_path) as z:
        for name in z.namelist():
            if not is_target(name):
                continue
            data = z.read(name)
            if b"PrepareTime" not in data:
                continue
            new, _ = flip_prepare(data)
            dest = os.path.join(out_root, name)
            try:
                with open(dest, "rb") as f:
                    cur = f.read()
            except FileNotFoundError:
                drift.append(name)
                continue
            if cur != new:
                drift.append(name)
    return drift

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--robz-pak", default=ROBZ_PAK)
    ap.add_argument("--out-root", default="../resource")
    ap.add_argument("--check", action="store_true",
                    help="report drift instead of writing; nonzero exit on drift")
    args = ap.parse_args()
    if args.check:
        drift = check(args.robz_pak, args.out_root)
        if drift:
            print("DRIFT:", *drift, sep="\n  ")
            raise SystemExit(1)
        print("in sync")
        return
    rep = generate(args.robz_pak, args.out_root, write=True)
    print("written:", len(rep["written"]))
    print("skipped (no PrepareTime):", rep["skipped_no_prepare"])
    print("total substitutions:", sum(rep["subs"].values()))

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools && python test_build_aim_time.py`
Expected: PASS — ends with `generate/check OK`

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/build_aim_time.py tools/test_build_aim_time.py
git commit -m "feat: aim-time generate/check + CLI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Generate the override tree, update mod.info, verify

**Files:**
- Create (generated): `resource/set/stuff/gun/**`, `resource/set/stuff/reactive/**`
- Modify: `mod.info`

**Interfaces:**
- Consumes: `build_aim_time.py` CLI from Task 2.
- Produces: committed override files; updated mod `Desc`.

- [ ] **Step 1: Generate the tree**

Run:
```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz/tools
python build_aim_time.py
```
Expected: prints `written: N` (N > 0), `skipped (no PrepareTime): M`, `total substitutions: K`.

- [ ] **Step 2: Verify only PrepareTime changed vs RobZ source**

Run this checker (compares every generated file to its pak source; only `PrepareTime` lines may differ):
```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz/tools
python - <<'PY'
import zipfile, build_aim_time as m
pak = m.ROBZ_PAK
bad = []
with zipfile.ZipFile(pak) as z:
    for name in z.namelist():
        if not m.is_target(name):
            continue
        data = z.read(name)
        if b"PrepareTime" not in data:
            continue
        with open("../resource/" + name, "rb") as f:
            cur = f.read()
        base = data.decode("latin-1").splitlines()
        got  = cur.decode("latin-1").splitlines()
        if len(base) != len(got):
            bad.append((name, "line count")); continue
        for b, g in zip(base, got):
            if b != g and "PrepareTime" not in b:
                bad.append((name, b.strip(), g.strip())); break
print("MISMATCHES:", bad if bad else "none")
PY
```
Expected: `MISMATCHES: none`

- [ ] **Step 3: Confirm check mode is clean**

Run: `cd /home/lamho/Documents/repos/ai-spawn-improved-robz/tools && python build_aim_time.py --check`
Expected: prints `in sync`, exit 0.

- [ ] **Step 4: Update mod.info Desc**

Modify `mod.info` — replace the `Desc` value with:

```
{Desc "Improved bot spawn logic plus AI income boost for RobZ Realism 1.30.x. Now also ships artillery weapon presets with PrepareTime=0 (set/stuff/gun, set/stuff/reactive) so artillery fires without the indirect-fire wind-up. Load AFTER RobZ. Based on cbyyy2013 Better AI and frontlines AI concepts."}
```

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/set/stuff mod.info
git commit -m "feat: ship artillery PrepareTime=0 overrides (gun, reactive)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Artillery pool reference document

**Files:**
- Create: `docs/artillery-pool-reference.md`

**Interfaces:**
- Consumes: nothing (static data validated against RobZ 1.30.10).
- Produces: a reference doc; no code consumes it.

- [ ] **Step 1: Write the reference document**

Create `docs/artillery-pool-reference.md` with exactly this content:

````markdown
# Artillery Pool Reference (RobZ 1.30.10)

Validated artillery roster derived from cbyyy2013 Better AI (RobZ 1.28.6) and corrected
to current RobZ 1.30.10 unit ids. Reference only — not wired into `bot.data.lua`.

Dropped (no current regular-MP equivalent): `sturmtiger` (hero-only), `bishop` (removed),
`m12gmc_vet` (folded into `m12gmc`), `203b4` (Guards-only -> `203b4_guard`),
`su152_guard` (cut -> `isu152_guard`).

Field defaults: `priority=1.0`, `min_team=1`, `min_income=2.0` (`2.5` when cost >= 1300),
`unlock` = RobZ value (also re-derivable via `build_unit_meta.py`).

## Roster (cost mp / unlock sec)

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

## Paste-ready Lua (bot.data.lua line format)

```lua
-- ger
{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe",            min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="hummel",           min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz4",           min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_sdkfz251_1w",   min_income=2.5, min_team=1, unlock=1200,},
-- ger2
{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe_ger2",       min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz138_1",       min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz251_1_stuka", min_income=2.5, min_team=1, unlock=1200,},
-- ger_ss
{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe_ss",         min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="hummel_ss",        min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz4_ss",        min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_sdkfz251_1w_ss",min_income=2.5, min_team=1, unlock=1200,},
-- eng
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m7_eng",           min_income=2.0, min_team=1, unlock=900,},
-- usa
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m7",               min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m12gmc",           min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m4a3c",            min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_t19",           min_income=2.0, min_team=1, unlock=900,},
-- rus
{priority=1.0, class=UnitClass.ArtilleryTank, unit="su122",            min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="su152",            min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="isu152",           min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm13",             min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm_8_24",          min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm8-48",           min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_bm31",          min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="280br5",           min_income=2.5, min_team=1, unlock=1200,},
-- rus_guard
{priority=1.0, class=UnitClass.ArtilleryTank, unit="203b4_guard",      min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm13_guard",       min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm_8_24_guard",    min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm8-48_guard",     min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="isu152_guard",     min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_bm31_guard",    min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="su122_guard",      min_income=2.0, min_team=1, unlock=1120,},
-- jap
{priority=1.0, class=UnitClass.ArtilleryTank, unit="ha-to",            min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="ho-ni2",           min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="ho-ro",            min_income=2.0, min_team=1, unlock=1200,},
```
````

- [ ] **Step 2: Sanity-check the unit ids resolve in RobZ**

Run (asserts every `unit="..."` in the doc exists in RobZ 1.30.10 unit sets):
```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
python - <<'PY'
import re, zipfile
pak = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
       "mods/robz realism mod 1.30.10/resource/gamelogic.pak")
ids = set(re.findall(r'unit="([^"]+)"', open("docs/artillery-pool-reference.md").read()))
present = set()
with zipfile.ZipFile(pak) as z:
    for n in z.namelist():
        if n.startswith("set/multiplayer/units/") and n.endswith(".set"):
            present |= set(re.findall(r'^\s*\{"([^"]+)"', z.read(n).decode("latin-1"), re.M))
missing = sorted(ids - present)
print("MISSING:", missing if missing else "none")
PY
```
Expected: `MISSING: none`

- [ ] **Step 3: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add docs/artillery-pool-reference.md
git commit -m "docs: artillery pool reference (current RobZ ids + paste-ready Lua)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- D1 file selection rule -> Task 1 `is_target` + Global Constraints. ✓
- D1 transform (PrepareTime->0 only) -> Task 1 `flip_prepare`, Task 3 Step 2 verifier. ✓
- D1 tooling `build_aim_time.py` (generate, --check, latin-1, re-runnable) -> Tasks 1-2. ✓
- D1 output location + mod.info -> Task 3. ✓
- D1 version sync (`--check`) -> Task 2 `check`, Task 3 Step 3. ✓
- D2 missing-unit handling + roster + Lua defaults + reference-only -> Task 4. ✓
- Testing (transform, exclusion, idempotency, diff-only-PrepareTime) -> Task 1 tests, Task 2 tests, Task 3 Step 2. ✓

**Placeholder scan:** No TBD/TODO; all code and doc content is literal. ✓

**Type consistency:** `is_target`, `flip_prepare`, `generate`, `check`, `main`, `ROBZ_PAK` used identically across Tasks 1-3. Default `--out-root ../resource` matches the `../resource/` + pak-name join used by the Task 3 verifier. ✓
