# Unlock-Time Gate + recharge Decouple Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate the spawn pool on a per-unit unlock time scraped from RobZ, and split the
overloaded `recharge` field into `unlock` (timing) and `weight` (tank tonnage), removing the
broken cooldown role.

**Architecture:** An offline Python generator scrapes each RobZ unit's `;NNNNsec` unlock comment
and `t()` tonnage tag and rewrites `bot.data.lua` (adds `unlock`, adds `weight` on tanks, strips
`recharge`). `bot.lua` gains a `unlockOk` pool gate, classifies tanks by `weight` instead of
`recharge`, and drops the `cooled` gate and its `Context.LastSpawn` bookkeeping.

**Tech Stack:** Lua 5.1 (game engine; no `goto`), Python 3 (offline generator only), busted-style
plain-Lua specs run with the stock `lua` interpreter.

## Global Constraints

- Target Lua is 5.1 on a 32-bit engine. No `goto`. Generator is Python 3, offline only, never
  shipped to the game.
- Run Lua specs from `resource/script/multiplayer/`: `lua tests/<name>_spec.lua` (each spec
  `dofile`s `harness.lua`, which loads `bot.lua` with a stubbed `BotApi`).
- Run Python tests from `tools/`: `python3 test_build_unit_meta.py` (asserts, prints `OK`).
- RobZ pak path (verbatim): `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/gamelogic.pak`. Unit sets live under `set/multiplayer/units/`. Pak entries decode as `latin-1`.
- Unlock source: the trailing `;NNNNsec` comment. Weight source: the first of
  `sheavy|heavy|medium|light` (check `sheavy` before `heavy`) inside the `t(...)` group.
- The generator must be idempotent: a second run on already-migrated `bot.data.lua` produces a
  byte-identical file.
- Scope is `battle_zones` (Capture the Flag). The CP unit-cap gate (officer +40) is a separate
  future phase and is NOT in this plan.
- Commit after each task; push the branch `feat/unlock-time-gate` after each task.

## File Structure

- `tools/build_unit_meta.py` (new) — scrape RobZ + rewrite `bot.data.lua`. Mirrors the existing
  `tools/build_sectors.py` style (stdlib only: `re`, `zipfile`, `argparse`).
- `tools/test_build_unit_meta.py` (new) — fixture-based asserts for scrape + inject + idempotency.
- `resource/script/multiplayer/bot.lua` (modify) — `TierOf` tank branch; `GetUnitToSpawn` pool
  loop; remove `Context.LastSpawn`.
- `resource/script/multiplayer/bot.data.lua` (modify) — generator-produced: `unlock`/`weight` in,
  `recharge` out; remove the `TierMediumRecharge` constant.
- `resource/script/multiplayer/tests/unlock_spec.lua` (new) — the gate behavior.
- `resource/script/multiplayer/tests/phase_spec.lua` (modify) — convert the three `recharge`-based
  `TierOf` tank assertions to `weight`.
- `resource/script/multiplayer/tests/integration_spec.lua` (modify) — give the two synthetic tank
  units a `weight`.

Task order is code-first then data: Task 1 builds the tool, Task 2 changes `bot.lua` and the Lua
specs (driven by synthetic fixtures, independent of real data), Task 3 runs the generator against
the real `bot.data.lua` and verifies in game. Between Task 2 and Task 3 the real `bot.data.lua` is
transiently un-migrated; nothing ships until the branch is reviewed and merged.

---

### Task 1: RobZ unit-meta generator

**Files:**
- Create: `tools/build_unit_meta.py`
- Test: `tools/test_build_unit_meta.py`

**Interfaces:**
- Produces (consumed by Task 3 and the test):
  - `parse_units(text: str) -> dict[str, dict]` — maps unit id to `{"unlock": int|None, "weight": str|None}`.
  - `inject(bot_data_text: str, meta: dict) -> tuple[str, dict]` — returns the rewritten
    `bot.data.lua` text and a `report` dict with keys `injected` (list of ids), `mismatch`
    (list of `(id, recharge, unlock)`), `no_match` (list of ids in bot.data absent from `meta`),
    `tanks_no_weight` (list of Tank ids with no scraped weight).
  - `scrape_pak(pak_path: str) -> dict` — opens the zip, reads every `set/multiplayer/units/`
    entry as latin-1, merges `parse_units`, keeps the first value on a conflicting duplicate id.

- [ ] **Step 1: Write the failing test**

Create `tools/test_build_unit_meta.py`:

```python
#!/usr/bin/env python3
"""Asserts build_unit_meta scrapes and injects correctly. Run from the tools/ dir."""
import build_unit_meta as m

# --- scrape ---
FIX = '\n'.join([
    '{"pz5g"      ("v" c(60) t(44 heavy) s(ger) cp(30)) {level 1} {cost 1325} {fore -24.0}} ;1500sec',
    '{"pz4h_seq"  ("v_seq" c(10) t(all 44 45 medium) s(ger) cp(20)) {level 1} {cost 500}} ;950sec',
    '{"sdkfz182b" ("v" c(120) t(44 sheavy) s(ger) cp(40)) {level 1} {cost 2200}} ;2160sec',
    '{"kubel"     ("v" c(5) t(44 light) s(ger) cp(3)) {level 1} {cost 120}}',  # no ;sec
])
meta = m.parse_units(FIX)
assert meta["pz5g"] == {"unlock": 1500, "weight": "heavy"}, meta["pz5g"]
assert meta["pz4h_seq"] == {"unlock": 950, "weight": "medium"}, meta["pz4h_seq"]
assert meta["sdkfz182b"] == {"unlock": 2160, "weight": "sheavy"}, meta["sdkfz182b"]
assert meta["kubel"] == {"unlock": None, "weight": "light"}, meta["kubel"]
print("parse_units OK")

# --- inject: tank gets unlock + weight, recharge stripped ---
LINE_TANK = '\t\t\t\t{priority=2.0, class=UnitClass.Tank,          unit="pz4h_seq", recharge=950,             min_income=1.5,},'
out, rep = m.inject(LINE_TANK, {"pz4h_seq": {"unlock": 950, "weight": "medium"}})
assert "recharge=" not in out, out
assert "unlock=950" in out, out
assert 'weight="medium"' in out, out
assert "pz4h_seq" in rep["injected"], rep
# idempotent: second pass identical
out2, _ = m.inject(out, {"pz4h_seq": {"unlock": 950, "weight": "medium"}})
assert out2 == out, (out, out2)
print("inject tank OK")

# --- inject: heavy gets unlock, NO weight (TierOf reads heavy from class) ---
LINE_HEAVY = '\t\t\t\t{priority=1.5, class=UnitClass.HeavyTank,     unit="pz5g", recharge=1500,                 min_income=2.0, min_team=1,},'
out, rep = m.inject(LINE_HEAVY, {"pz5g": {"unlock": 1500, "weight": "heavy"}})
assert "recharge=" not in out, out
assert "unlock=1500" in out, out
assert "weight=" not in out, out
print("inject heavy OK")

# --- mismatch protection: recharge != unlock leaves the line untouched ---
LINE_BAD = '\t\t\t\t{class=UnitClass.Tank, unit="weird", recharge=42, min_income=1.0,},'
out, rep = m.inject(LINE_BAD, {"weird": {"unlock": 950, "weight": "light"}})
assert out == LINE_BAD, out
assert ("weird", 42, 950) in rep["mismatch"], rep["mismatch"]
print("inject mismatch OK")

# --- recharge=0 with no unlock: strip recharge, add no unlock field ---
LINE_ZERO = '\t\t\t\t{class=UnitClass.Infantry, unit="rifle", recharge=0, min_income=1.0,},'
out, rep = m.inject(LINE_ZERO, {"rifle": {"unlock": None, "weight": None}})
assert "recharge=" not in out, out
assert "unlock=" not in out, out
print("inject zero OK")

print("build_unit_meta test OK")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd tools && python3 test_build_unit_meta.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'build_unit_meta'`.

- [ ] **Step 3: Write the generator**

Create `tools/build_unit_meta.py`:

```python
#!/usr/bin/env python3
"""Offline unit-meta extractor for the CTF (battle_zones) bot.
Scrapes each RobZ unit's unlock time (trailing ;NNNNsec comment) and tonnage (t() tag),
then rewrites bot.data.lua: adds unlock=, adds weight= on UnitClass.Tank lines, strips
recharge=. Run by hand; output is committed. Never ships to the game."""
import re, zipfile, argparse

ROBZ_PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
            "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

_UNIT_ID = re.compile(r'^\s*\{"([A-Za-z0-9_]+)"')
_UNLOCK = re.compile(r';\s*(\d+)\s*sec')
_TTAG = re.compile(r'\bt\(([^)]*)\)')
_WEIGHTS = ("sheavy", "heavy", "medium", "light")  # sheavy before heavy (substring)

def parse_units(text):
    """unit id -> {'unlock': int|None, 'weight': str|None} for each unit definition line."""
    out = {}
    for line in text.splitlines():
        mid = _UNIT_ID.match(line)
        if not mid:
            continue
        uid = mid.group(1)
        mu = _UNLOCK.search(line)
        unlock = int(mu.group(1)) if mu else None
        weight = None
        mt = _TTAG.search(line)
        if mt:
            tags = mt.group(1)
            for w in _WEIGHTS:
                if re.search(r'\b' + w + r'\b', tags):
                    weight = w
                    break
        out.setdefault(uid, {"unlock": unlock, "weight": weight})
    return out

def scrape_pak(pak_path):
    meta = {}
    with zipfile.ZipFile(pak_path) as z:
        for name in z.namelist():
            if name.startswith("set/multiplayer/units/") and name.endswith(".set"):
                text = z.read(name).decode("latin-1")
                for uid, val in parse_units(text).items():
                    meta.setdefault(uid, val)  # keep first
    return meta

_BD_ID = re.compile(r'unit="([A-Za-z0-9_]+)"')
_RECHARGE = re.compile(r'\s*recharge=(\d+),')
_UNLOCK_FIELD = re.compile(r'\s*unlock=\d+,')
_WEIGHT_FIELD = re.compile(r'\s*weight="[^"]*",')

def _inject_line(line, info):
    """Rewrite a single bot.data unit line. Returns (new_line, action) where action is
    'injected' | 'mismatch' | 'skip'. info is the meta entry for this line's id."""
    unlock = info.get("unlock")
    weight = info.get("weight")
    is_tank = "class=UnitClass.Tank," in line
    mr = _RECHARGE.search(line)
    if mr:
        expected = unlock if unlock is not None else 0
        if int(mr.group(1)) != expected:
            return line, "mismatch"
    # strip any prior recharge/unlock/weight tokens (idempotency)
    new = _RECHARGE.sub("", line)
    new = _UNLOCK_FIELD.sub("", new)
    new = _WEIGHT_FIELD.sub("", new)
    # insert fresh fields just before the closing '},'
    add = ""
    if unlock is not None:
        add += " unlock=%d," % unlock
    if is_tank and weight is not None:
        add += ' weight="%s",' % weight
    if add:
        new = re.sub(r'\},\s*$', add + "},", new, count=1)
    return new, "injected"

def inject(bot_data_text, meta):
    report = {"injected": [], "mismatch": [], "no_match": [], "tanks_no_weight": []}
    out_lines = []
    for line in bot_data_text.splitlines(keepends=True):
        mid = _BD_ID.search(line)
        if not mid:
            out_lines.append(line)
            continue
        uid = mid.group(1)
        if uid not in meta:
            report["no_match"].append(uid)
            out_lines.append(line)
            continue
        body = line.rstrip("\n")
        nl = "\n" if line.endswith("\n") else ""
        new_body, action = _inject_line(body, meta[uid])
        if action == "mismatch":
            mr = _RECHARGE.search(body)
            report["mismatch"].append((uid, int(mr.group(1)), meta[uid].get("unlock")))
            out_lines.append(line)
            continue
        report["injected"].append(uid)
        if "class=UnitClass.Tank," in body and meta[uid].get("weight") is None:
            report["tanks_no_weight"].append(uid)
        out_lines.append(new_body + nl)
    return "".join(out_lines), report

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--robz-pak", default=ROBZ_PAK)
    ap.add_argument("--bot-data", default="../resource/script/multiplayer/bot.data.lua")
    args = ap.parse_args()
    meta = scrape_pak(args.robz_pak)
    with open(args.bot_data, encoding="utf-8") as f:
        text = f.read()
    out, rep = inject(text, meta)
    with open(args.bot_data, "w", encoding="utf-8") as f:
        f.write(out)
    print("injected:", len(rep["injected"]))
    print("mismatch (recharge != unlock):", rep["mismatch"])
    print("no RobZ match:", sorted(set(rep["no_match"])))
    print("tanks with no weight:", sorted(set(rep["tanks_no_weight"])))

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tools && python3 test_build_unit_meta.py`
Expected: PASS, ending `build_unit_meta test OK`.

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/build_unit_meta.py tools/test_build_unit_meta.py
git commit -m "feat: RobZ unit-meta generator (unlock + weight scrape, recharge strip)"
git push -u origin feat/unlock-time-gate
```

---

### Task 2: bot.lua decouple + Lua specs

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`TierOf` 320-333; pool loop 605-627; remove
  `Context.LastSpawn` at 31, 1058, 1458)
- Modify: `resource/script/multiplayer/bot.data.lua:39` (remove `TierMediumRecharge`)
- Create: `resource/script/multiplayer/tests/unlock_spec.lua`
- Modify: `resource/script/multiplayer/tests/phase_spec.lua:13-15`
- Modify: `resource/script/multiplayer/tests/integration_spec.lua:8-9`

**Interfaces:**
- Consumes (from Task 1, runtime): `bot.data.lua` units carry `unlock` (number, optional) and
  `weight` (`"medium"`/`"light"` on tanks, optional). This task does NOT depend on the real data
  being migrated yet; it is driven by synthetic fixtures.
- Produces: `TierOf(t)` returns `"medium"` for `class=Tank` with `t.weight=="medium"`, else
  `"light"`; the pool gate excludes a unit while `elapsed < unit.unlock`.

- [ ] **Step 1: Write the failing gate spec**

Create `resource/script/multiplayer/tests/unlock_spec.lua`:

```lua
dofile((arg[0]:gsub("unlock_spec%.lua$", "harness.lua")))

-- Two light units (Vehicle -> tier light, eligible in every phase so only `unlock` varies).
local units = {
	{ class = UnitClass.Vehicle, unit = "freetk",   priority = 1.0 },              -- always available
	{ class = UnitClass.Vehicle, unit = "lockedtk", priority = 1.0, unlock = 1500 }, -- unlocks at 1500s
}

local function sample(quants)
	Context.MatchQuants = quants
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(units)
		if pick then seen[pick.unit] = true end
	end
	return seen
end

-- Before unlock (elapsed 1000s): locked unit must never appear; free unit does.
local early = sample(1000 * 70)
assert(early["freetk"], "free unit should spawn before unlock")
assert(not early["lockedtk"], "locked unit must NOT spawn before its unlock time")

-- After unlock (elapsed 1600s): locked unit becomes eligible.
local late = sample(1600 * 70)
assert(late["lockedtk"], "locked unit should spawn after its unlock time")

-- unit.unlock == nil is available at t=0.
local zero = sample(0)
assert(zero["freetk"], "nil-unlock unit available from t=0")
print("unlock OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/unlock_spec.lua`
Expected: FAIL — `lockedtk` is spawned before 1500s because no `unlockOk` gate exists yet
(assertion "locked unit must NOT spawn before its unlock time").

- [ ] **Step 3: Add the `unlockOk` gate and remove `cooled` in `GetUnitToSpawn`**

In `resource/script/multiplayer/bot.lua`, replace the pool loop (lines 605-627):

```lua
	-- Build the eligible pool: affordable, unlocked, and within the phase armor cap.
	local pool = {}
	for i, unit in pairs(units) do
		local affordable = teamSize >= (unit.min_team or 0)
			and income >= (unit.min_income or -1)
		local unlockOk = (unit.unlock == nil) or (elapsed >= unit.unlock)
		local failed = Context.FailCooldown[unit.unit]
		local notRecentlyFailed = (failed == nil)
			or (Context.MatchQuants - failed >= FailCooldownQuants)
		local tier = TierOf(unit)
		local capOk = (tier == nil) or (TierRank[tier] <= capRank) -- aux not capped
		local phaseOk = (unit.phase == nil) or (unit.phase == phase.name) -- per-unit phase lock
		-- Elite infantry only spawns in early. From mid on, tanks dominate the field and
		-- elite inf just feeds them, so ban elite outside early. In early, still cap at 1/group.
		local elitePhaseOk = (not unit.elite) or (phase.name == "early")
		local eliteCapOk = not (g and unit.elite and GroupEliteCount(g) >= 1)
		local eliteOk = elitePhaseOk and eliteCapOk
		if affordable and unlockOk and notRecentlyFailed and capOk and phaseOk and eliteOk then
			table.insert(pool, unit)
		end
	end
	if #pool == 0 then return nil end
```

(`elapsed` is already computed at bot.lua:598. The `last`/`cooled` locals are gone.)

- [ ] **Step 4: Run the gate spec to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/unlock_spec.lua`
Expected: PASS, `unlock OK`.

- [ ] **Step 5: Switch `TierOf` to `weight` and update its specs**

In `bot.lua`, replace the Tank branch (lines 327-328):

```lua
	elseif t.class == UnitClass.Tank then
		return (t.weight == "medium") and "medium" or "light"
```

In `tests/phase_spec.lua`, replace lines 13-15:

```lua
eq(TierOf({class = UnitClass.Tank, weight = "light"}),  "light",  "light tank")
eq(TierOf({class = UnitClass.Tank}),                    "light",  "no weight defaults light")
eq(TierOf({class = UnitClass.Tank, weight = "medium"}), "medium", "medium tank")
```

In `tests/integration_spec.lua`, replace lines 8-9 (add `weight`, drop the now-ignored `recharge`):

```lua
	{ class = UnitClass.Tank,      unit = "lighttk", priority = 1.5, weight = "light" },  -- light
	{ class = UnitClass.Tank,      unit = "medtk",   priority = 1.5, weight = "medium" }, -- medium
```

- [ ] **Step 6: Remove the dead `TierMediumRecharge` constant and `Context.LastSpawn`**

In `bot.data.lua`, delete line 39 (`TierMediumRecharge = 550`).

In `bot.lua`, delete these three `Context.LastSpawn` lines (now unreferenced; the only reader was
the removed `cooled` gate):
- line 31: `	LastSpawn = {},    -- unit.unit -> MatchQuants tick of last spawn (recharge tracking)`
- line 1058: `	Context.LastSpawn = {}`
- line 1458: `		Context.LastSpawn[info.unit] = Context.MatchQuants` (leaves the surrounding
  `if info then ... end` block intact via its remaining `Context.FieldUnits` write).

- [ ] **Step 7: Run the whole Lua suite**

Run from `resource/script/multiplayer`:
```bash
for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done
```
Expected: every spec prints its `OK` line; `unlock_spec`, `phase_spec`, `integration_spec` all
pass. No `attempt to index nil` and no reference to `TierMediumRecharge` or `LastSpawn`.

- [ ] **Step 8: Grep for stragglers**

Run from `resource/script/multiplayer`:
```bash
grep -n "TierMediumRecharge\|LastSpawn\|\.recharge\|cooled" bot.lua bot.data.lua
```
Expected: no matches in `bot.lua`. `bot.data.lua` may still show `recharge=` on unit lines (those
are stripped by the generator in Task 3); it must NOT show `TierMediumRecharge`.

- [ ] **Step 9: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/bot.data.lua \
        resource/script/multiplayer/tests/unlock_spec.lua \
        resource/script/multiplayer/tests/phase_spec.lua \
        resource/script/multiplayer/tests/integration_spec.lua
git commit -m "feat: unlockOk pool gate; TierOf by weight; drop cooled/LastSpawn/TierMediumRecharge"
git push origin feat/unlock-time-gate
```

---

### Task 3: Migrate bot.data and verify

**Files:**
- Modify: `resource/script/multiplayer/bot.data.lua` (generator-produced: `unlock`/`weight` in,
  `recharge` out)

**Interfaces:**
- Consumes: `tools/build_unit_meta.py` (Task 1), the `bot.lua` changes (Task 2).
- Produces: the shipped `bot.data.lua` with real unlock/weight values.

- [ ] **Step 1: Run the generator against the real data**

Run:
```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz/tools
python3 build_unit_meta.py
```
Expected: prints `injected: <N>` (the count of bot.data unit lines matched), and the three report
lists.

- [ ] **Step 2: Verify the report is clean**

Inspect the printed report. Required:
- `mismatch (recharge != unlock): []` — every existing `recharge` equalled the scraped unlock,
  confirming `recharge` was unlock data. If this list is non-empty, STOP: those lines were left
  untouched; report the units to the human before proceeding (a non-empty list means `recharge`
  held something other than unlock for that unit, which contradicts the spec's premise).
- `tanks with no weight: []` — every `class=UnitClass.Tank` line received a `weight`. A non-empty
  list means those tanks will classify as `light` by default; report them to the human.
- `no RobZ match:` may list bot.data ids absent from RobZ (acceptable; they default to available,
  no `unlock`). Note them.

- [ ] **Step 3: Spot-check the migrated data**

Run from `resource/script/multiplayer`:
```bash
grep -nE 'unit="(pz5g|pz6e|sdkfz182b|pz4h_seq)"' bot.data.lua
grep -c "recharge=" bot.data.lua
```
Expected: `pz5g` shows `unlock=1500`, `pz6e` `unlock=1750`, `sdkfz182b` `unlock=2160`, `pz4h_seq`
`unlock=950` and `weight="medium"`; the heavies carry `unlock` but no `weight`. `recharge=` count
is `0` (all stripped) unless Step 2 reported a mismatch (then it equals the mismatch count).

- [ ] **Step 4: Confirm idempotency**

Run:
```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz/tools
python3 build_unit_meta.py
cd ../resource/script/multiplayer && git diff --stat bot.data.lua
```
Expected: the second generator run leaves `bot.data.lua` byte-identical (no diff from the
post-Step-1 state).

- [ ] **Step 5: Run the whole Lua suite against the migrated data**

Run from `resource/script/multiplayer`:
```bash
for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done
```
Expected: all specs print their `OK` line. (The harness now loads the migrated `bot.data.lua`; a
load error or `nil` weight surfaces here.)

- [ ] **Step 6: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.data.lua
git commit -m "data: migrate bot.data to unlock/weight (recharge stripped) via build_unit_meta"
git push origin feat/unlock-time-gate
```

- [ ] **Step 7: In-game probe verification (manual gate)**

Symlink/copy the mod into the game `mods/ai-spawn-improved-robz`, run one CTF (`battle_zones`)
match, then inspect the debug log:
- No `SPAWN` line with `ok=false` for a heavy (`pz5g`/`pz6e`/`sdkfz182b`/`pz6bh`) at a `phase=late`
  timestamp earlier than its unlock (1500/1750/2160s). Locked heavies should be absent from the
  attempt stream entirely.
- At least one heavy reaches `ok=true` after its unlock time when headroom allows.
- Field composition looks sane after the `weight` reclassification (a believable medium/light tank
  mix; not all-light, not all-medium).

If heavies still never reach `ok=true` after their unlock time, that is the deferred CP unit-cap
constraint (officer +40), not this gate — record it for the next phase; do not change this gate.

---

## Notes for the next phase (not in this plan)

The CP unit-cap gate is deferred. It is a DYNAMIC, live-state check, not a static field: the cap
moves (a live Officer adds +40, lost on its death) and consumed CP moves every tick as units die
and refund `cp`. Its gate is `consumed + unit.cp <= base + 40 * liveOfficers`, evaluated at the
spawn-decision point each cycle. See the spec's "Out of scope" note.
