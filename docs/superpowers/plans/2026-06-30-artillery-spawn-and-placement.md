# Artillery Spawn and Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-enable AI artillery as a standalone defender trickle, place each piece by its range tier, and merge the validated artillery roster into `bot.data.lua`.

**Architecture:** Three layers. (1) A data generator `tools/build_arty_roster.py` writes one artillery row per unit into each nation table of `bot.data.lua`, tagging each with an `arty` subtype and a tag-derived `priority`. (2) Phase A adds an artillery defender trickle to `bot.lua`, modeled on the existing MG defender trickle, so artillery spawns standalone (never a group member). (3) Phase B adds a range-aware placement function that routes each piece to an owned flag by its `arty` subtype, using the per-flag `axis` already computed by `LabelFlags`.

**Tech Stack:** Lua 5.x (game scripts, offline test harness via `lua tests/*.lua`), Python 3 (offline generators, plain-`assert` tests run from `tools/`).

## Global Constraints

- Spawn mechanism is a standalone defender **trickle** in `OnGameQuant`'s idle-between-waves window (mirrors the MG defender trickle). The wave picker `GetUnitToSpawn` is NOT modified. The `collectAux` exclusion of `UnitClass.ArtilleryTank` STAYS.
- Trickle gate constants (exact): `ArtyIntervalSec = 45`, `ArtyCap = 1`. Gate also requires `CurrentPhase(Elapsed()).name ~= "early"` (mid + late only) and `HeldFlagCount() > 0`.
- `arty` subtype is derived from the RobZ mp-set engine `t(...)` tag: contains `rocket` -> `"rocket"`; else contains `heavyart` or `heavy` -> `"heavy"`; else -> `"field"`.
- Subtype priority (exact): `rocket` -> `0.3`, `heavy` -> `0.5`, `field` -> `0.8`.
- Roster is the 34 validated units below; every artillery row carries `min_team=1`, plus `min_income`/`unlock` from the roster table. Each row also carries `arty="rocket|heavy|field"`.
- Merge rule: per nation, `merged = (existing artillery rows UNION reference roster)`, deduped by unit id, then DROP any id not present in that nation's RobZ mp-set (`set/multiplayer/units/<nation>/*.set`). Dropping logs a warning.
- Routing: `axis` from `Context.FlagLabel[name].axis` is team-oriented; **low axis = own/rear, high axis = enemy/forward** (`SectorOwnMax=0.4`, `SectorEnemyMin=0.6`). rocket -> highest-axis owned flag; heavy -> lowest-axis owned flag; field -> mild forward. Non-owned flags get only a small drift weight.
- RobZ pak path (same constant used by sibling generators): `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/gamelogic.pak`.
- Lua tests run from `resource/script/multiplayer/` as `lua tests/<name>_spec.lua` (harness stubs `BotApi`, loads `bot.data.lua` + `flag_sectors.lua` + `bot.lua`). Python tests run from `tools/` as `python3 test_<name>.py`. File I/O is latin-1, byte-preserving.
- Every commit ends with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

### Reference roster (nation, unit, min_income, unlock)

```
ger:       wespe 2.0/900, hummel 2.0/1200, sdkfz4 2.0/1200, np_sdkfz251_1w 2.5/1200
ger2:      wespe_ger2 2.0/900, sdkfz138_1 2.0/900, sdkfz251_1_stuka 2.5/1200
ger_ss:    wespe_ss 2.0/900, hummel_ss 2.0/1200, sdkfz4_ss 2.0/1200, np_sdkfz251_1w_ss 2.5/1200
eng:       m7_eng 2.0/900
usa:       m7 2.0/900, m12gmc 2.5/1200, m4a3c 2.0/1200, np_t19 2.0/900
rus:       su122 2.0/1120, su152 2.0/1120, isu152 2.0/1120, bm13 2.0/1200, bm_8_24 2.0/900, bm8-48 2.0/900, np_bm31 2.5/1200, 280br5 2.5/1200
rus_guard: 203b4_guard 2.5/1200, bm13_guard 2.0/1200, bm_8_24_guard 2.0/1200, bm8-48_guard 2.0/900, isu152_guard 2.0/1120, np_bm31_guard 2.5/1200, su122_guard 2.0/1120
jap:       ha-to 2.0/1200, ho-ni2 2.0/900, ho-ro 2.0/1200
```

---

## File Structure

- `tools/build_arty_roster.py` (new) — pure functions to classify subtype/priority, merge+filter per nation, render a Lua artillery row, and rewrite each nation's artillery span in `bot.data.lua`. Reads the RobZ mp-set for tag classification and id validation.
- `tools/test_build_arty_roster.py` (new) — plain-`assert` tests for the pure functions.
- `resource/script/multiplayer/bot.data.lua` (modified by the generator) — artillery rows replaced per nation.
- `resource/script/multiplayer/bot.lua` (modified) — Phase A trickle (Task 2), Phase B placement (Task 3).
- `resource/script/multiplayer/tests/arty_spec.lua` (new) — Lua tests for `GetArtyUnit`, `LiveArtyCount`, the trickle gate, and `ArtilleryFlagPriority`.

---

## Task 1: Artillery roster generator + bot.data.lua merge

**Files:**
- Create: `tools/build_arty_roster.py`
- Create: `tools/test_build_arty_roster.py`
- Modify (by running the generator): `resource/script/multiplayer/bot.data.lua`

**Interfaces:**
- Produces: module `build_arty_roster` with `subtype_of(tag:str)->str`, `priority_of(subtype:str)->float`, `render_row(unit:str, sub:str, min_income:float, unlock:int)->str`, `merge_nation(nation:str, existing_ids:list[str], mpset_ids:set[str])->list[str]`, `rewrite_nation_block(text:str, nation:str, rows:list[str])->str`, and `ROSTER` (dict nation -> list of `(unit, min_income, unlock)`).
- Consumes (Task 2/3): the `arty="..."` field written onto each row is read at runtime by `GetArtyUnit` weighting and `ArtilleryFlagPriority`.

- [ ] **Step 1: Write the failing test for subtype/priority/render**

Create `tools/test_build_arty_roster.py`:

```python
#!/usr/bin/env python3
"""Asserts build_arty_roster classifies subtype, sets priority, renders rows,
merges+filters per nation, and rewrites a nation block. Run from tools/."""
import build_arty_roster as m

# --- subtype_of: tag substring -> subtype ---
assert m.subtype_of("artillery heavyart rocket 44") == "rocket"   # rocket wins
assert m.subtype_of("all artillery heavyart heavy 43 44 45") == "heavy"
assert m.subtype_of("artillery all heavy 44 45") == "heavy"
assert m.subtype_of("all artillery 43 44 45") == "field"
assert m.subtype_of("artillery 44") == "field"
print("subtype_of OK")

# --- priority_of ---
assert m.priority_of("rocket") == 0.3
assert m.priority_of("heavy") == 0.5
assert m.priority_of("field") == 0.8
print("priority_of OK")

# --- render_row: exact Lua line, includes arty= and priority ---
row = m.render_row("wespe", "field", 2.0, 900)
assert row == ('\t\t\t\t{priority=0.8, class=UnitClass.ArtilleryTank, '
               'unit="wespe", min_income=2.0, min_team=1, unlock=900, arty="field",},'), repr(row)
rocket = m.render_row("bm13", "rocket", 2.0, 1200)
assert 'arty="rocket"' in rocket and 'priority=0.3' in rocket and 'unit="bm13"' in rocket, repr(rocket)
print("render_row OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools && python3 test_build_arty_roster.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'build_arty_roster'`.

- [ ] **Step 3: Write the pure functions**

Create `tools/build_arty_roster.py`:

```python
#!/usr/bin/env python3
"""Offline artillery-roster generator. Merges the validated artillery roster with
the existing artillery rows in bot.data.lua, drops ids not present in each nation's
RobZ mp-set, classifies each by its engine t() tag, and rewrites the per-nation
artillery span in bot.data.lua. Run by hand; the output is committed. Never ships
to the game."""
import re, zipfile, argparse, sys, os

ROBZ_PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
            "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

# nation -> [(unit, min_income, unlock)]
ROSTER = {
    "ger":       [("wespe",2.0,900),("hummel",2.0,1200),("sdkfz4",2.0,1200),("np_sdkfz251_1w",2.5,1200)],
    "ger2":      [("wespe_ger2",2.0,900),("sdkfz138_1",2.0,900),("sdkfz251_1_stuka",2.5,1200)],
    "ger_ss":    [("wespe_ss",2.0,900),("hummel_ss",2.0,1200),("sdkfz4_ss",2.0,1200),("np_sdkfz251_1w_ss",2.5,1200)],
    "eng":       [("m7_eng",2.0,900)],
    "usa":       [("m7",2.0,900),("m12gmc",2.5,1200),("m4a3c",2.0,1200),("np_t19",2.0,900)],
    "rus":       [("su122",2.0,1120),("su152",2.0,1120),("isu152",2.0,1120),("bm13",2.0,1200),
                  ("bm_8_24",2.0,900),("bm8-48",2.0,900),("np_bm31",2.5,1200),("280br5",2.5,1200)],
    "rus_guard": [("203b4_guard",2.5,1200),("bm13_guard",2.0,1200),("bm_8_24_guard",2.0,1200),
                  ("bm8-48_guard",2.0,900),("isu152_guard",2.0,1120),("np_bm31_guard",2.5,1200),
                  ("su122_guard",2.0,1120)],
    "jap":       [("ha-to",2.0,1200),("ho-ni2",2.0,900),("ho-ro",2.0,1200)],
}

_PRIORITY = {"rocket": 0.3, "heavy": 0.5, "field": 0.8}

def subtype_of(tag):
    """Map a RobZ t() tag string to an arty subtype."""
    if "rocket" in tag: return "rocket"
    if "heavyart" in tag or "heavy" in tag: return "heavy"
    return "field"

def priority_of(subtype):
    return _PRIORITY[subtype]

def render_row(unit, subtype, min_income, unlock):
    """One bot.data.lua artillery row (4 tabs of indent, matching the nation tables)."""
    return ('\t\t\t\t{priority=%s, class=UnitClass.ArtilleryTank, unit="%s", '
            'min_income=%s, min_team=1, unlock=%d, arty="%s",},'
            % (priority_of(subtype), unit, min_income, unlock, subtype))

# --- RobZ mp-set scraping (tag classification + id validation) ---
_RX_Q = re.compile(r'\{"([^"]+)"')
_RX_N = re.compile(r'\bname\(([^)]+)\)')

def nation_mpset(z, nation):
    """Return {unit_id: tag_string} for one nation's mp unit sets."""
    out = {}
    for n in z.namelist():
        if n.startswith("set/multiplayer/units/%s/" % nation) and n.endswith(".set"):
            d = z.read(n).decode("latin-1")
            for uid in set(_RX_Q.findall(d)) | set(s.strip() for s in _RX_N.findall(d)):
                i = d.find('"%s"' % uid)
                if i < 0: i = d.find("name(%s)" % uid)
                mt = re.search(r't\(([^)]*)\)', d[i:i+400]) if i >= 0 else None
                out[uid] = mt.group(1) if mt else ""
    return out

def merge_nation(nation, existing_ids, mpset):
    """Return rendered rows for one nation. Union of reference + existing ids, deduped,
    filtered to ids present in mpset, classified by tag. mpset maps id -> tag string."""
    ref = {u: (mi, ul) for (u, mi, ul) in ROSTER.get(nation, [])}
    order = [u for (u, _, _) in ROSTER.get(nation, [])]
    for u in existing_ids:
        if u not in ref:
            order.append(u)
    rows, seen = [], set()
    for u in order:
        if u in seen: continue
        seen.add(u)
        if u not in mpset:
            print("DROP %s/%s: not in mp-set" % (nation, u), file=sys.stderr)
            continue
        sub = subtype_of(mpset[u])
        mi, ul = ref.get(u, (2.0, 900))
        rows.append(render_row(u, sub, mi, ul))
    return rows

# --- bot.data.lua rewrite ---
def existing_arty_ids(text, nation):
    """Unit ids on the ArtilleryTank rows inside one nation block."""
    block = _nation_block(text, nation)
    return re.findall(r'class=UnitClass\.ArtilleryTank, unit="([^"]+)"', block)

def _nation_block_span(text, nation):
    """Return (start, end) char offsets of one nation table body, or raise. End is the
    next nation header (so the span is scoped to this nation only)."""
    key = '["%s"] = {' % nation
    s = text.find(key)
    if s < 0: raise SystemExit("nation %s not found" % nation)
    nxt = re.search(r'\n\s*\["[a-z0-9_]+"\] = \{', text[s + len(key):])
    e = (s + len(key) + nxt.start()) if nxt else len(text)
    return s, e

def _nation_block(text, nation):
    s, e = _nation_block_span(text, nation)
    return text[s:e]

def rewrite_nation_block(text, nation, rows):
    """Replace the contiguous run of ArtilleryTank lines in one nation block with rows.
    Existing artillery rows are contiguous per nation (verified); replace that slice in place."""
    lines = text.split("\n")
    key = '["%s"] = {' % nation
    start = next((i for i, ln in enumerate(lines) if key in ln), None)
    if start is None: raise SystemExit("nation %s not found" % nation)
    arty = [i for i in range(start, len(lines))
            if "class=UnitClass.ArtilleryTank" in lines[i]]
    # stop collecting at the next nation header (contiguity guard within this block)
    nxt = next((i for i in range(start + 1, len(lines))
                if re.match(r'\s*\["[a-z0-9_]+"\] = \{', lines[i])), len(lines))
    arty = [i for i in arty if i < nxt]
    if not arty:
        raise SystemExit("no ArtilleryTank rows in nation %s" % nation)
    first, last = arty[0], arty[-1]
    if last - first + 1 != len(arty):
        raise SystemExit("ArtilleryTank rows not contiguous in %s" % nation)
    return "\n".join(lines[:first] + rows + lines[last + 1:])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--robz-pak", default=ROBZ_PAK)
    ap.add_argument("--bot-data", default="../resource/script/multiplayer/bot.data.lua")
    ap.add_argument("--check", action="store_true", help="validate only; do not write")
    a = ap.parse_args()
    z = zipfile.ZipFile(a.robz_pak)
    text = open(a.bot_data, encoding="latin-1").read()
    total = 0
    for nation in ROSTER:
        mpset = nation_mpset(z, nation)
        existing = existing_arty_ids(text, nation)
        rows = merge_nation(nation, existing, mpset)
        total += len(rows)
        if not a.check:
            text = rewrite_nation_block(text, nation, rows)
    if a.check:
        print("validated", total, "rows across", len(ROSTER), "nations")
        return
    open(a.bot_data, "w", encoding="latin-1").write(text)
    print("wrote", a.bot_data, "rows:", total)

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify subtype/priority/render pass**

Run: `cd tools && python3 test_build_arty_roster.py`
Expected: prints `subtype_of OK`, `priority_of OK`, `render_row OK`.

- [ ] **Step 5: Add merge + rewrite tests**

Append to `tools/test_build_arty_roster.py`:

```python
# --- merge_nation: union of reference + existing, filtered by mpset, classified ---
mpset = {"wespe_ss": "all artillery 43 44 45", "hummel_ss": "all artillery heavyart heavy 43 44 45",
         "sdkfz4_ss": "all artillery heavyart rocket 44 45",
         "np_sdkfz251_1w_ss": "all artillery heavyart rocket 41 42 43 44 45"}
# ger_ss existing rows use wespe + stuh42, which are NOT in the ger_ss mp-set -> dropped
rows = m.merge_nation("ger_ss", ["wespe", "stuh42"], mpset)
assert len(rows) == 4, rows                      # only the 4 valid _ss units survive
assert any('unit="wespe_ss"' in r and 'arty="field"' in r for r in rows), rows
assert any('unit="hummel_ss"' in r and 'arty="heavy"' in r for r in rows), rows
assert any('unit="sdkfz4_ss"' in r and 'arty="rocket"' in r for r in rows), rows
assert not any('"stuh42"' in r or 'unit="wespe"' in r for r in rows), rows
print("merge_nation OK")

# --- rewrite_nation_block: replaces the contiguous arty run in place ---
sample = (
'\t\t\t["ger"] = {\n'
'\t\t\t\t{priority=2.0, class=UnitClass.Infantry, unit="riflemans(ger)",},\n'
'\t\t\t\t{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe", min_income=2.0, min_team=1, unlock=900,},\n'
'\t\t\t},\n'
'\t\t\t["usa"] = {\n'
'\t\t\t\t{priority=1.0, class=UnitClass.ArtilleryTank, unit="m7", min_income=2.0, min_team=1, unlock=900,},\n'
'\t\t\t},\n')
out = m.rewrite_nation_block(sample, "ger", ['\t\t\t\tROW_A', '\t\t\t\tROW_B'])
assert "ROW_A\n\t\t\t\tROW_B" in out, out
assert 'unit="wespe"' not in out, out          # old ger arty row gone
assert 'unit="riflemans(ger)"' in out, out     # non-arty row preserved
assert 'unit="m7"' in out, out                 # usa block untouched
print("rewrite_nation_block OK")
```

- [ ] **Step 6: Run the full test suite**

Run: `cd tools && python3 test_build_arty_roster.py`
Expected: all five `... OK` lines print, no assertion error.

- [ ] **Step 7: Validate against the real RobZ pak (no write)**

Run: `cd tools && python3 build_arty_roster.py --check`
Expected: `validated 34 rows across 8 nations` on stdout, and on stderr exactly the drops for ger_ss (`DROP ger_ss/wespe`, `DROP ger_ss/stuh42`). If any other DROP appears, STOP and report — an id in the roster is wrong.

- [ ] **Step 8: Write bot.data.lua**

Run: `cd tools && python3 build_arty_roster.py`
Expected: `wrote ../resource/script/multiplayer/bot.data.lua rows: 34`.

- [ ] **Step 9: Verify the result loads and is well-formed**

Run: `cd resource/script/multiplayer && lua -e 'dofile("bot.data.lua"); print("loaded")'`
Expected: prints `loaded` (no Lua syntax error). Then:
Run: `grep -c 'arty="' resource/script/multiplayer/bot.data.lua`
Expected: `34`.

- [ ] **Step 10: Commit**

```bash
git add tools/build_arty_roster.py tools/test_build_arty_roster.py resource/script/multiplayer/bot.data.lua
git commit -m "feat: merge validated artillery roster into bot.data.lua

build_arty_roster.py writes 34 artillery rows (arty subtype + tag-derived
priority) into each nation table, dropping ids absent from the RobZ mp-set
(ger_ss wespe/stuh42). Reference roster + existing rows, deduped and filtered.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Phase A — artillery defender trickle

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (constants near `DefenderIntervalSec`; `Context` init; new `GetArtyUnit`/`LiveArtyCount`; trickle branch in `OnGameQuant` idle window)
- Create/Modify: `resource/script/multiplayer/tests/arty_spec.lua`

**Interfaces:**
- Consumes: `bot.data.lua` rows from Task 1 (each artillery row has `class=UnitClass.ArtilleryTank` and `arty=`). `GetRandomItem(items, getRate)`, `Context.FieldUnits`, `Purchases[1].Units[army]`, `Elapsed()`, `CurrentPhase(s).name`, `HeldFlagCount()` (all existing in `bot.lua`).
- Produces (Task 3): standalone artillery squads (queued `kind="trickle"`, never in `Context.SquadGroup`) that reach the defender branch of `CaptureFlag`.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/arty_spec.lua`:

```lua
dofile((arg[0]:gsub("arty_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- LiveArtyCount counts only ArtilleryTank entries in FieldUnits
Context.FieldUnits = {
	[1] = { class = UnitClass.ArtilleryTank, unit = "wespe" },
	[2] = { class = UnitClass.MG, unit = "mgs2(ger)" },
	[3] = { class = UnitClass.ArtilleryTank, unit = "hummel" },
}
eq(LiveArtyCount(), 2, "LiveArtyCount")

-- GetArtyUnit returns an ArtilleryTank row from the current army roster (harness army = "ger")
local u = GetArtyUnit()
assert(u ~= nil, "GetArtyUnit returned nil")
eq(u.class, UnitClass.ArtilleryTank, "GetArtyUnit class")

-- GetArtyUnit returns nil when the roster has no artillery
local saved = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = { { priority = 1.0, class = UnitClass.Infantry, unit = "x" } }
eq(GetArtyUnit(), nil, "GetArtyUnit nil when no arty")
Purchases[1].Units["ger"] = saved
print("arty spawn helpers OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/arty_spec.lua`
Expected: FAIL with `attempt to call a nil value (global 'LiveArtyCount')`.

- [ ] **Step 3: Add constants and Context field**

In `bot.lua`, after the line `local DefenderCap      = 3       -- max live MG teams the bot keeps fielded`, add:

```lua
local ArtyIntervalSec  = 45      -- seconds between artillery trickle checks (rarer than MG)
local ArtyCap          = 1       -- max live artillery pieces the bot keeps fielded
```

In the `Context` table initializer, after the line `LastDefenderTime = 0, -- Elapsed() at last MG defender trickle`, add:

```lua
	LastArtyTime = 0,     -- Elapsed() at last artillery defender trickle
```

- [ ] **Step 4: Add GetArtyUnit and LiveArtyCount**

In `bot.lua`, immediately after the `LiveMGCount` function (it ends with `return n` / `end`), add:

```lua
-- An artillery unit from the current faction roster, drawn by priority, or nil.
function GetArtyUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local arty = {}
	for i, t in pairs(roster) do
		if t.class == UnitClass.ArtilleryTank then table.insert(arty, t) end
	end
	if #arty == 0 then return nil end
	return GetRandomItem(arty, function(t) return t.priority end)
end

-- Live artillery pieces we have fielded (the artillery cap).
function LiveArtyCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.ArtilleryTank then n = n + 1 end
	end
	return n
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/arty_spec.lua`
Expected: prints `arty spawn helpers OK`.

- [ ] **Step 6: Add the trickle branch in the idle window**

In `bot.lua`, inside `OnGameQuant`, the idle-between-waves `else` block contains an MG defender branch (`if Elapsed() - Context.LastDefenderTime >= DefenderIntervalSec ...`) followed by `elseif Elapsed() - Context.LastBackfillTime >= BackfillIntervalSec then`. Insert a new `elseif` for artillery BETWEEN the MG branch's closing `end` and the backfill `elseif`, so the chain is MG -> artillery -> backfill:

```lua
		elseif Elapsed() - Context.LastArtyTime >= ArtyIntervalSec
		and CurrentPhase(Elapsed()).name ~= "early"
		and HeldFlagCount() > 0 and LiveArtyCount() < ArtyCap then
			Context.LastArtyTime = Elapsed()
			local art = GetArtyUnit()
			if art then
				Context.SpawnInfo = art -- routed as a defender (DefenderClasses[ArtilleryTank]=true)
				local ok = BotApi.Commands:Spawn(art.unit, MaxSquadSize)
				print("[AISPAWN] ARTY try=" .. tostring(art.unit) .. " ok=" .. tostring(ok))
				if ok then
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "trickle", info = art }
				else
					Context.FailCooldown[art.unit] = Elapsed()
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
```

(The new `elseif` attaches to the existing MG `if`; do not add a new `if`. The backfill `elseif` now follows the artillery `elseif`.)

- [ ] **Step 7: Add the trickle-gate test**

Append to `tests/arty_spec.lua`:

```lua
-- Trickle gate: a small re-implementation mirror would duplicate logic, so assert the
-- pieces the gate depends on instead. The gate spawns only when:
--   elapsed since LastArtyTime >= ArtyIntervalSec, phase ~= early, HeldFlagCount > 0, LiveArtyCount < ArtyCap.
-- Verify cap blocks at 1:
Context.FieldUnits = { [1] = { class = UnitClass.ArtilleryTank, unit = "wespe" } }
assert(LiveArtyCount() >= 1, "cap precondition")
-- Verify HeldFlagCount reflects owned flags (occupant == team). harness team = 1.
BotApi.Scene.Flags = { { name = "f1", occupant = 1 }, { name = "f2", occupant = 2 } }
eq(HeldFlagCount(), 1, "HeldFlagCount owned only")
print("arty trickle gate OK")
```

- [ ] **Step 8: Run all Lua specs**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || exit 1; done`
Expected: every spec prints its OK lines and the loop exits 0 (no `error(...)`).

- [ ] **Step 9: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/arty_spec.lua
git commit -m "feat: artillery defender trickle (Phase A)

Standalone artillery trickle in the idle-between-waves window, mirroring the MG
defender trickle: GetArtyUnit (priority-weighted) + LiveArtyCount, gated by
ArtyIntervalSec=45, ArtyCap=1, mid+late, HeldFlagCount>0. Spawns kind=trickle so
artillery is never a group member. Picker untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Phase B — range-aware artillery placement

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`ArtilleryFlagPriority`; defender branch of `CaptureFlag`)
- Modify: `resource/script/multiplayer/tests/arty_spec.lua`

**Interfaces:**
- Consumes: `Context.FlagLabel[name].axis` (set by `LabelFlags`; low = own/rear, high = enemy/forward), `IsCapturedFlag(flag)`, `Context.FieldUnits[squad].arty` (the subtype written by Task 1), `GetFlagToCapture(flags, getPriority)`, `IsDefender(squad)` (all existing).
- Produces: artillery squads routed to an owned flag chosen by subtype.

- [ ] **Step 1: Write the failing routing test**

Append to `tests/arty_spec.lua`:

```lua
-- ArtilleryFlagPriority: among OWNED flags, rocket favors high axis (forward),
-- heavy favors low axis (rear), field is mild forward; non-owned get only drift.
Context.FlagLabel = {
	fRear  = { axis = 0.10 },  -- own/rear
	fFwd   = { axis = 0.55 },  -- forward
}
local owned   = { name = "fFwd",  occupant = 1 }  -- harness team = 1
local ownRear = { name = "fRear", occupant = 1 }
local enemy   = { name = "fFwd",  occupant = 2 }

local rocketEntry = { arty = "rocket" }
local heavyEntry  = { arty = "heavy" }
local fieldEntry  = { arty = "field" }

-- rocket: forward owned outweighs rear owned
assert(ArtilleryFlagPriority(owned, rocketEntry) > ArtilleryFlagPriority(ownRear, rocketEntry),
	"rocket favors forward")
-- heavy: rear owned outweighs forward owned
assert(ArtilleryFlagPriority(ownRear, heavyEntry) > ArtilleryFlagPriority(owned, heavyEntry),
	"heavy favors rear")
-- any owned outweighs a non-owned flag (drift floor)
assert(ArtilleryFlagPriority(ownRear, fieldEntry) > ArtilleryFlagPriority(enemy, fieldEntry),
	"owned beats non-owned")
print("ArtilleryFlagPriority OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/arty_spec.lua`
Expected: FAIL with `attempt to call a nil value (global 'ArtilleryFlagPriority')`.

- [ ] **Step 3: Add ArtilleryFlagPriority**

In `bot.lua`, immediately after `DefenderFlagPriority` (it ends with `end`), add:

```lua
-- Artillery defenders weight OWNED flags by forwardness, scaled to the piece's reach.
-- axis is team-oriented: low = own/rear, high = enemy/forward. Short rockets must sit
-- on the frontmost owned flag to reach the contested center; heavy artillery reaches
-- from the rear, so it favors a safer rear owned flag. Non-owned flags get only a
-- small drift weight so a piece with no owned flag in reach still moves forward.
function ArtilleryFlagPriority(flag, entry)
	if not IsCapturedFlag(flag) then return 0.05 end
	local label = Context.FlagLabel[flag.name]
	local axis = (label and label.axis) or 0.5
	local sub = entry and entry.arty
	if sub == "rocket" then return 0.1 + 3.0 * axis
	elseif sub == "heavy" then return 0.1 + 3.0 * (1 - axis)
	else return 0.1 + 1.0 * axis end          -- field (and any untagged artillery): mild forward
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/arty_spec.lua`
Expected: prints `ArtilleryFlagPriority OK` (and all earlier OK lines).

- [ ] **Step 5: Wire artillery into the defender branch of CaptureFlag**

In `bot.lua`, the defender branch of `CaptureFlag` currently reads:

```lua
	-- Defenders (MG, AT, sniper, etc.) hold owned flags.
	if IsDefender(squad) then
		local flag = GetFlagToCapture(BotApi.Scene.Flags, DefenderFlagPriority)
		if flag then BotApi.Commands:CaptureFlag(squad, flag.name) end
		return
	end
```

Replace it with:

```lua
	-- Defenders (MG, AT, sniper, etc.) hold owned flags. Artillery uses a range-aware
	-- priority so each piece sits where its reach covers the contested center.
	if IsDefender(squad) then
		local entry = Context.FieldUnits[squad]
		local priFn = DefenderFlagPriority
		if entry and entry.class == UnitClass.ArtilleryTank then
			priFn = function(flag) return ArtilleryFlagPriority(flag, entry) end
		end
		local flag = GetFlagToCapture(BotApi.Scene.Flags, priFn)
		if flag then BotApi.Commands:CaptureFlag(squad, flag.name) end
		return
	end
```

- [ ] **Step 6: Add an integration assertion for the defender branch**

Append to `tests/arty_spec.lua`:

```lua
-- CaptureFlag routes an artillery defender to its preferred owned flag.
-- Capture the engine call by stubbing BotApi.Commands:CaptureFlag.
local routed = nil
BotApi.Commands.CaptureFlag = function(_, squad, flagName) routed = flagName end
Context.SquadGroup = {}                                  -- not a group member
Context.Cappers = {}                                     -- not a capper
Context.FieldUnits = { [7] = { class = UnitClass.ArtilleryTank, unit = "bm13", arty = "rocket" } }
Context.FlagLabel = { fRear = { axis = 0.10 }, fFwd = { axis = 0.55 } }
BotApi.Scene.Flags = { { name = "fRear", occupant = 1 }, { name = "fFwd", occupant = 1 } }
math.randomseed(1)
local fwd = 0
for i = 1, 200 do routed = nil; CaptureFlag(7); if routed == "fFwd" then fwd = fwd + 1 end end
assert(fwd > 150, "rocket should mostly route to the forward owned flag, got " .. fwd .. "/200")
print("CaptureFlag artillery routing OK")
```

- [ ] **Step 7: Run all Lua specs**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || exit 1; done`
Expected: every spec prints its OK lines and the loop exits 0.

- [ ] **Step 8: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/arty_spec.lua
git commit -m "feat: range-aware artillery placement (Phase B)

ArtilleryFlagPriority routes each piece to an owned flag by its arty subtype:
rocket -> frontmost owned (high axis), heavy -> rear/safe owned (low axis),
field -> mild forward; non-owned flags get only a drift weight. Wired into the
defender branch of CaptureFlag via a per-entry closure; GetFlagToCapture unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- Line numbers drift; anchor edits on the quoted surrounding code, not on absolute line numbers.
- Do not modify `GetUnitToSpawn`, `TierOf`, `collectAux`, or `DefenderClasses`. Artillery is intentionally kept out of the wave picker.
- The `arty` field on a unit row flows from `bot.data.lua` (Task 1) to `Context.FieldUnits[squad].arty` at spawn time through the existing field-unit registration. If Task 3's routing test sees `entry.arty == nil` in live play, confirm the spawn registration copies the full roster row (it does today — `Context.FieldUnits[squadId] = info`).
