# Flag Labeling — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Label every capture flag OWN / CONTESTED / ENEMY plus a distance-to-enemy rank at match start, from precomputed per-map coordinates, written to `Context.FlagLabel` for later AI logic to consume.

**Architecture:** An offline Python script parses a map's `battle_zones.mi` (the only source of flag coordinates) and emits `flag_sectors.lua`, a table keyed by the map's sorted flag-name set (the runtime has no map-id API, so this set is the map fingerprint). At `OnGameStart`, `LabelFlags()` builds the same fingerprint from `BotApi.Scene.Flags`, looks up the table, orients each flag by the bot's team (`"a"`/`"b"`), and writes labels. Unknown maps fall back to all-CONTESTED.

**Tech Stack:** Lua 5.1 (game engine; no `goto`), Lua 5.5 / `luac` for offline gates, Python 3 for the build script, the existing `tests/harness.lua` offline test harness.

Spec: `docs/superpowers/specs/2026-06-28-flag-labeling-design.md`. This plan implements **Phase 1 only**. Phase 2 (lateral teammate partition) is gated on an in-game test and is not in this plan.

## Global Constraints

- Engine is Lua 5.1: no `goto`, no `//`, no bitops; use `table.insert` / numeric loops as the existing code does.
- Mod working dir for gates: `resource/script/multiplayer/`. Gates that must pass after every task: `luac -p bot.lua`, `luac -p bot.data.lua`, `luac -p flag_sectors.lua`, `lua tests/phase_spec.lua`, `lua tests/integration_spec.lua`, `lua tests/sector_spec.lua`.
- `BotApi.Instance.team` is the string `"a"` or `"b"` (absolute, matches map `{team}` labels). `enemyTeam` likewise. `playerId` is an integer.
- A runtime flag object exposes ONLY `flag.name` and `flag.occupant`. No position field. Base spawns (a1/a2/b1/b2) are NOT in `BotApi.Scene.Flags`.
- `flag_sectors.lua` defines a single global table `Sectors` (same global-table convention as `bot.data.lua`'s `Phases`).
- RobZ map archive on this machine: `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/map.pak`; bastogne internal path `map/multi/2v2_bastogne/battle_zones.mi`.
- Repo root for git: `/home/lamho/Documents/repos/ai-spawn-improved-robz` (symlinked into the Steam mods dir). Commit and push after each task.
- Sector thresholds (named constants): `SectorOwnMax = 0.4` (myAxis < ⇒ OWN), `SectorEnemyMin = 0.6` (myAxis > ⇒ ENEMY; between ⇒ CONTESTED).

## File Structure

- Create: `tools/build_sectors.py` — offline extractor (pak → battle_zones.mi → axis → Lua).
- Create: `tools/test_build_sectors.py` — asserts the bastogne extraction.
- Create: `resource/script/multiplayer/flag_sectors.lua` — GENERATED data table `Sectors`.
- Create: `resource/script/multiplayer/tests/sector_spec.lua` — runtime unit tests.
- Modify: `resource/script/multiplayer/bot.lua` — `require` the data file, add `FlagFingerprint()` + `LabelFlags()` + threshold constants + `Context.FlagLabel`/`FlagBases`, call `LabelFlags()` in `OnGameStart`.
- Modify: `resource/script/multiplayer/tests/harness.lua` — stub the `flag_sectors` require.

---

### Task 1: Offline build script + generated bastogne data

**Files:**
- Create: `tools/build_sectors.py`
- Create: `tools/test_build_sectors.py`
- Create: `resource/script/multiplayer/flag_sectors.lua` (generated, then committed)

**Interfaces:**
- Produces: `flag_sectors.lua` defining global `Sectors[fingerprint] = { bases = {a1={x,y},...}, flags = {f1={x,y,axis},...} }`. `fingerprint` is the sorted, comma-joined flag-name set, e.g. `"f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9"`. `axis = dA/(dA+dB)`, 0 at A home, 1 at B home.
- Produces (Python, for Task 1's own test): `parse_mi(text) -> (bases dict, flags dict)`, `compute(bases, flags) -> {name:(x,y,axis)}`, `fingerprint(flags) -> str`.

- [ ] **Step 1: Write the build script**

Create `tools/build_sectors.py`:

```python
#!/usr/bin/env python3
"""Offline flag-sector extractor. Reads each map's battle_zones.mi from a RobZ map.pak,
computes per-flag axis (0 = A home, 1 = B home), and emits a flag_sectors.lua table.
Run by hand; the output is committed. This script never ships to the game."""
import re, math, zipfile, argparse

def parse_mi(text):
    """Return (bases, flags): name -> (x, y). Bases are a#/b#; flags are f#.
    Position may carry a third z value, which is ignored."""
    bases, flags = {}, {}
    for block in re.split(r"\{Entity ", text):
        nm = re.search(r"\{name\s+(\w+)\}", block)
        ps = re.search(r"\{Position\s+(-?[\d.]+)\s+(-?[\d.]+)", block)
        if not (nm and ps):
            continue
        name = nm.group(1)
        x, y = float(ps.group(1)), float(ps.group(2))
        if re.match(r"^[ab]\d+$", name):
            bases[name] = (x, y)
        elif re.match(r"^f\d+$", name):
            flags[name] = (x, y)
    return bases, flags

def _dist(p, q):
    return math.hypot(p[0] - q[0], p[1] - q[1])

def compute(bases, flags):
    """Return {name: (x, y, axis)}. Fails loudly if a side has no base."""
    A = [v for k, v in bases.items() if k[0] == "a"]
    B = [v for k, v in bases.items() if k[0] == "b"]
    if not A or not B:
        raise SystemExit("map missing a-base or b-base; refusing partial entry")
    out = {}
    for name, p in flags.items():
        dA = min(_dist(p, a) for a in A)
        dB = min(_dist(p, b) for b in B)
        out[name] = (p[0], p[1], dA / (dA + dB))
    return out

def fingerprint(flags):
    return ",".join(sorted(flags.keys()))

def emit_lua(entries):
    """entries: list of (fingerprint, bases, computed)."""
    out = ["-- GENERATED by tools/build_sectors.py. Do not edit by hand.", "Sectors = {"]
    for fp, bases, comp in entries:
        out.append('  ["%s"] = {' % fp)
        out.append("    bases = {")
        for k in sorted(bases):
            x, y = bases[k]
            out.append("      %s={x=%d, y=%d}," % (k, round(x), round(y)))
        out.append("    },")
        out.append("    flags = {")
        for k in sorted(comp, key=lambda s: int(s[1:])):
            x, y, axis = comp[k]
            out.append("      %s={x=%d, y=%d, axis=%.2f}," % (k, round(x), round(y), axis))
        out.append("    },")
        out.append("  },")
    out.append("}")
    return "\n".join(out) + "\n"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pak", help="path to RobZ map.pak")
    ap.add_argument("maps", nargs="+", help="map dir names under map/multi/")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    entries = []
    with zipfile.ZipFile(a.pak) as z:
        for m in a.maps:
            text = z.read("map/multi/%s/battle_zones.mi" % m).decode("latin-1")
            bases, flags = parse_mi(text)
            entries.append((fingerprint(flags), bases, compute(bases, flags)))
    with open(a.out, "w") as f:
        f.write(emit_lua(entries))
    print("wrote", a.out, "entries:", len(entries))

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the extraction test**

Create `tools/test_build_sectors.py`:

```python
#!/usr/bin/env python3
"""Asserts build_sectors extracts bastogne correctly. Run from the tools/ dir."""
import zipfile, build_sectors as bs

PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
       "mods/robz realism mod 1.30.10/resource/map.pak")

with zipfile.ZipFile(PAK) as z:
    text = z.read("map/multi/2v2_bastogne/battle_zones.mi").decode("latin-1")

bases, flags = bs.parse_mi(text)
assert set(bases) == {"a1", "a2", "b1", "b2"}, bases
assert len(flags) == 11, len(flags)

comp = bs.compute(bases, flags)
assert len(comp) == 11, len(comp)
assert comp["f5"][2] < 0.4, comp["f5"]
assert comp["f6"][2] < 0.4, comp["f6"]
assert comp["f10"][2] > 0.59, comp["f10"]

assert bs.fingerprint(flags) == "f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9", bs.fingerprint(flags)
print("build_sectors test OK")
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd /home/lamho/Documents/repos/ai-spawn-improved-robz/tools && python3 test_build_sectors.py`
Expected: `build_sectors test OK`

- [ ] **Step 4: Generate the data file**

Run:
```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz/tools
python3 build_sectors.py \
  "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/map.pak" \
  2v2_bastogne \
  -o ../resource/script/multiplayer/flag_sectors.lua
```
Expected: `wrote ../resource/script/multiplayer/flag_sectors.lua entries: 1`

- [ ] **Step 5: Verify the generated Lua is valid and has the bastogne entry**

Run:
```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz/resource/script/multiplayer
luac -p flag_sectors.lua && grep -c 'f10={' flag_sectors.lua
```
Expected: no luac error; grep prints `1`. Open the file and confirm it contains
`["f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9"]`, a `bases` block with a1/a2/b1/b2, and a `flags`
block of 11 `f#={x=,y=,axis=}` entries.

- [ ] **Step 6: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add tools/build_sectors.py tools/test_build_sectors.py resource/script/multiplayer/flag_sectors.lua
git commit -m "Add offline flag-sector build script + generated bastogne data"
git push
```

---

### Task 2: Runtime FlagFingerprint + LabelFlags + unit tests

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (require data file + add constants + two functions)
- Modify: `resource/script/multiplayer/tests/harness.lua` (stub `flag_sectors` require)
- Create: `resource/script/multiplayer/tests/sector_spec.lua`

**Interfaces:**
- Consumes: global `Sectors` from `flag_sectors.lua` (Task 1); `BotApi.Scene.Flags` (list of `{name, occupant}`), `BotApi.Instance.team` / `playerId`.
- Produces: `FlagFingerprint() -> string`; `LabelFlags()` populates `Context.FlagLabel[name] = {sector, rank, axis, x, y}` and `Context.FlagBases`. Consumed by Task 3 (the `OnGameStart` call) and by future Phase 2.

- [ ] **Step 1: Stub the data-file require in the harness**

In `resource/script/multiplayer/tests/harness.lua`, the require shim currently handles
`bot.data`. Extend it to also load `flag_sectors`. Replace:

```lua
require = function(mod)
	if tostring(mod):find("bot%.data") then
		return dofile(MROOT .. "/bot.data.lua")
	end
	return realRequire(mod)
end
```

with:

```lua
require = function(mod)
	if tostring(mod):find("bot%.data") then
		return dofile(MROOT .. "/bot.data.lua")
	end
	if tostring(mod):find("flag_sectors") then
		return dofile(MROOT .. "/flag_sectors.lua")
	end
	return realRequire(mod)
end
```

- [ ] **Step 2: Write the failing test**

Create `resource/script/multiplayer/tests/sector_spec.lua`:

```lua
dofile((arg[0]:gsub("sector_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

local function bastogneFlags()
	local t = {}
	for _, n in ipairs({"f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f20"}) do
		t[#t + 1] = { name = n, occupant = 0 }
	end
	return t
end

-- fingerprint is sorted + comma-joined (string sort, so f10 < f2)
BotApi.Scene.Flags = bastogneFlags()
eq(FlagFingerprint(), "f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9", "fingerprint")

-- team a: f10 is closest to enemy home (rank 1, ENEMY); f5 is closest to own (rank 11, OWN)
BotApi.Instance.team = "a"; BotApi.Instance.playerId = 1
LabelFlags()
eq(Context.FlagLabel["f10"].sector, "ENEMY", "a f10 sector")
eq(Context.FlagLabel["f10"].rank, 1, "a f10 rank")
eq(Context.FlagLabel["f5"].sector, "OWN", "a f5 sector")
eq(Context.FlagLabel["f5"].rank, 11, "a f5 rank")
assert(Context.FlagBases and Context.FlagBases.a1, "a bases populated")
print("sector team-a OK")

-- team b inverts orientation: ranks flip end-for-end (1<->11), f5 becomes enemy-side
BotApi.Instance.team = "b"; BotApi.Instance.playerId = 3
LabelFlags()
eq(Context.FlagLabel["f5"].rank, 1, "b f5 rank")
eq(Context.FlagLabel["f5"].sector, "ENEMY", "b f5 sector")
eq(Context.FlagLabel["f10"].rank, 11, "b f10 rank")
print("sector team-b OK")

-- unknown map -> fallback C: all CONTESTED, no rank, no bases
BotApi.Scene.Flags = { { name = "zz1", occupant = 0 }, { name = "zz2", occupant = 0 } }
BotApi.Instance.team = "a"
LabelFlags()
eq(Context.FlagLabel["zz1"].sector, "CONTESTED", "miss zz1 sector")
eq(Context.FlagLabel["zz1"].rank, nil, "miss zz1 rank nil")
eq(Context.FlagBases, nil, "miss bases nil")
print("sector fallback OK")
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/sector_spec.lua`
Expected: FAIL — `attempt to call a nil value (global 'FlagFingerprint')` (functions not defined yet).

- [ ] **Step 4: Require the data file and add the constants and functions to bot.lua**

In `bot.lua`, line 1 is `require([[/script/multiplayer/bot.data]])`. Add the data-file
require immediately after it so the global `Sectors` is available (the harness stub from
Step 1 resolves it offline, the engine resolves it in-game):

```lua
require([[/script/multiplayer/bot.data]])
require([[/script/multiplayer/flag_sectors]])
```

Then add the two threshold constants next to the other top-level constants
(after `local MaxLiveSquads = 24`):

```lua
-- Flag-sector thresholds on the team-oriented axis (0 = own home, 1 = enemy home).
local SectorOwnMax   = 0.4  -- myAxis below this => OWN
local SectorEnemyMin = 0.6  -- myAxis above this => ENEMY; between the two => CONTESTED
```

Add these two functions as new top-level functions (place them just before
`function OnGameStart()`):

```lua
-- The sorted, comma-joined set of current flag names. The engine exposes no map id, so
-- this set is the map fingerprint used to look a precomputed sector table up.
function FlagFingerprint()
	local names = {}
	for _, flag in pairs(BotApi.Scene.Flags) do
		names[#names + 1] = flag.name
	end
	table.sort(names)
	return table.concat(names, ",")
end

-- Label every live flag OWN / CONTESTED / ENEMY plus a rank toward the enemy home,
-- from the precomputed Sectors table, oriented by this bot's team. Unknown maps fall
-- back to all-CONTESTED. Writes Context.FlagLabel and Context.FlagBases. Never errors.
function LabelFlags()
	Context.FlagLabel = {}
	Context.FlagBases = nil
	local fp = FlagFingerprint()
	local entry = Sectors and Sectors[fp]
	local team = BotApi.Instance.team
	local pid = BotApi.Instance.playerId
	if not entry then
		for _, flag in pairs(BotApi.Scene.Flags) do
			Context.FlagLabel[flag.name] = { sector = "CONTESTED" }
		end
		print("[AISPAWN] SECTOR_FALLBACK fingerprint=" .. fp)
		return
	end
	Context.FlagBases = entry.bases
	-- Collect present flags with a team-oriented axis (team b sees the axis reversed).
	local present = {}
	for _, flag in pairs(BotApi.Scene.Flags) do
		local d = entry.flags[flag.name]
		if d then
			local myAxis = (team == "b") and (1 - d.axis) or d.axis
			present[#present + 1] = { name = flag.name, myAxis = myAxis, x = d.x, y = d.y }
		else
			Context.FlagLabel[flag.name] = { sector = "CONTESTED" } -- present but unmapped
		end
	end
	-- Rank by myAxis descending; rank 1 = closest to enemy home. Tie-break by name so the
	-- two teammates compute an identical ranking regardless of pairs() iteration order.
	table.sort(present, function(p, q)
		if p.myAxis ~= q.myAxis then return p.myAxis > q.myAxis end
		return p.name < q.name
	end)
	for rank, p in ipairs(present) do
		local sector = "CONTESTED"
		if p.myAxis < SectorOwnMax then sector = "OWN"
		elseif p.myAxis > SectorEnemyMin then sector = "ENEMY" end
		Context.FlagLabel[p.name] = { sector = sector, rank = rank, axis = p.myAxis, x = p.x, y = p.y }
		print("[AISPAWN] SECTOR pid=" .. tostring(pid) .. " team=" .. tostring(team)
			.. " " .. p.name .. " sector=" .. sector .. " rank=" .. rank
			.. " axis=" .. string.format("%.2f", p.myAxis))
	end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/sector_spec.lua`
Expected: `sector team-a OK`, `sector team-b OK`, `sector fallback OK`.

- [ ] **Step 6: Run the full gate suite**

Run:
```bash
cd resource/script/multiplayer
luac -p bot.lua && luac -p bot.data.lua && luac -p flag_sectors.lua \
  && lua tests/phase_spec.lua && lua tests/integration_spec.lua && lua tests/sector_spec.lua
```
Expected: all print their OK lines, no errors.

- [ ] **Step 7: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/harness.lua resource/script/multiplayer/tests/sector_spec.lua
git commit -m "Add FlagFingerprint + LabelFlags with unit tests"
git push
```

---

### Task 3: Wire LabelFlags into the match lifecycle

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (init Context fields; call `LabelFlags()` in `OnGameStart`)

**Interfaces:**
- Consumes: `LabelFlags()` (Task 2), global `Sectors` (Task 1, required in bot.lua by Task 2).
- Produces: populated `Context.FlagLabel` / `Context.FlagBases` at the start of every match, and a `SECTOR ...` debug line per flag in game.log (the Phase 1→2 gate reads these).

- [ ] **Step 1: Declare the new Context fields**

In the `Context = { ... }` table literal at the top of `bot.lua`, add these two fields
next to the other state fields (e.g. after `LostStamp = {},`):

```lua
	FlagLabel = {},    -- flag name -> {sector, rank, axis, x, y}; set by LabelFlags at start
	FlagBases = nil,   -- the matched map's base coords, or nil on an unrecognized map
```

- [ ] **Step 2: Call LabelFlags in OnGameStart**

In `function OnGameStart()`, immediately after the `print("[AISPAWN] START_PROBE ...)`
statement (the flag list is already available there), add:

```lua
	LabelFlags()
```

- [ ] **Step 3: Verify the wiring compiles and all gates pass**

Run:
```bash
cd resource/script/multiplayer
luac -p bot.lua && luac -p bot.data.lua && luac -p flag_sectors.lua \
  && lua tests/phase_spec.lua && lua tests/integration_spec.lua && lua tests/sector_spec.lua
```
Expected: all OK, no errors. (The existing harness sets `BotApi.Instance.team = 1` and an
empty `Scene.Flags`; `LabelFlags` is only invoked directly by `sector_spec`, so loading
`bot.lua` under the harness must still succeed and the require of `flag_sectors` must
resolve via the Step-1 harness stub from Task 2.)

- [ ] **Step 4: Smoke-test that loading bot.lua triggers the data require**

Run: `cd resource/script/multiplayer && lua -e 'arg={[0]="tests/x"}; dofile("tests/harness.lua"); assert(Sectors, "Sectors global must be loaded via require"); print("require wiring OK")'`
Expected: `require wiring OK`

- [ ] **Step 5: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.lua
git commit -m "Call LabelFlags at match start; init FlagLabel/FlagBases Context"
git push
```

---

## After Phase 1: in-game verification gate

Before Phase 2 is planned or built, run a self-hosted bastogne 2v2 with AI on both teams
and confirm from game.log (per the spec's gate):
1. `SECTOR ...` lines appear and no `SECTOR_FALLBACK` (bastogne fingerprint matched).
2. For a team-a bot: `f10 sector=ENEMY rank=1` and `f5 sector=OWN rank=11`. For a team-b
   bot: inverted (`f5 ... rank=1`, `f10 ... rank=11`).
3. The two team-a bots show adjacent `playerId`s and the two team-b bots the next block
   (the playerId-contiguous-by-team assumption Phase 2 depends on). Confirm over ≥2 matches.
4. Both teammates print identical `sector`/`rank` for the same flag (determinism).

Only after this gate passes should the Phase 2 lateral-partition plan be written.
