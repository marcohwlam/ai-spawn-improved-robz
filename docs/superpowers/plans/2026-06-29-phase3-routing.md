# Phase 3 Routing Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `PickGroupTarget`'s ordering with a defensive-first tier ladder fed by the Phase 1 sector labels, Phase 2 partition, and a new offline flag-adjacency graph.

**Architecture:** `build_sectors.py` precomputes per-flag neighbors (`nb`) and base adjacency (`base`) into `flag_sectors.lua`. `LabelFlags` copies them into `Context.FlagLabel`. A new `IsFrontier` reads them at runtime. `PickGroupTarget` scores every candidate flag by a 3-tier ladder and returns the best.

**Tech Stack:** Lua 5.1 (engine sandbox; NO `goto`), Python 3 (offline tool), the project's offline Lua test harness.

## Global Constraints

- Engine runs Lua 5.1: no `goto`, no 5.2+ idioms. Lint with `luac -p bot.lua` and `luac -p flag_sectors.lua` from `resource/script/multiplayer`.
- Only `PickGroupTarget` changes behavior. Cappers, defenders, and `GetFlagToCapture` are untouched.
- `sector` thresholds (already in code, do not change): `myAxis < 0.4` OWN, `0.4 <= myAxis < 0.6` CONTESTED, `myAxis >= 0.6` ENEMY.
- Adjacency threshold: `2000` units, unioned with the `2` nearest neighbors (floor), symmetric. Base adjacency: a flag lists a team letter if that team's base is within `2000` units.
- Candidate set `C` = enemy-occupied flags UNION neutral flags with a `Context.LostStamp` entry, minus `excludeName`.
- `enemyHeld(F)` = `occupant == enemyTeam`. `enemyAttacking(F)` = occupant is neither team AND `Context.LostStamp[F] ~= nil`.
- Tier ladder: **1** `sector==OWN` AND (held OR attacking) [unpartitioned]; **2** `mine` AND `frontier` AND `sector==CONTESTED` AND (held OR attacking); **3** otherwise.
- Tie-break: tiers 1/2 by `myAxis` ascending then name; tier 3 by distance-to-nearest-owned ascending then name; if no coordinates, fall back to most-recently-lost (`LostStamp` desc) then `GetFlagPriority` then name.
- `frontier(F)` = a neighbor in `F.nb` is occupied by this bot's team, OR `F.base` contains this bot's team letter. Absent graph (unmapped map) ⇒ false.
- `PickGroupTarget` returns nil ONLY when `C` is empty. Tier 3 is the catch-all; never return nil while a candidate exists. (Repo history: a prior frontier filter was removed for returning nil and stalling squads.)
- All `FlagLabel`/`FlagOwner` accesses are nil-guarded; no `Sectors[nil]`/`table[nil]` indexing.
- RobZ map pak: `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/map.pak`. The 4 maps: `2v2_bastogne 2v2_sidi_el-barrani 1v1_nikolaev 2v2_mamayev_kurgan`.
- Tests run from `resource/script/multiplayer`: `lua tests/<spec>.lua`. Python tests from `tools`: `python3 test_build_sectors.py`.

---

### Task 1: Offline adjacency graph (build_sectors.py + regen)

**Files:**
- Modify: `tools/build_sectors.py` (add `adjacency`, thread it through `main`/`emit_lua`)
- Modify: `tools/test_build_sectors.py` (assert adjacency on bastogne)
- Regenerate: `resource/script/multiplayer/flag_sectors.lua`

**Interfaces:**
- Produces: each flag entry in `flag_sectors.lua` gains `nb={"f7","f8"}` (sorted by flag number) and, when applicable, `base={"a"}` (sorted team letters). x/y/axis values unchanged.

- [ ] **Step 1: Write the failing python test**

In `tools/test_build_sectors.py`, append before the final `print(...)` line:

```python
adj = bs.adjacency(bases, flags)
nb_f1 = adj["f1"][0]
assert "f8" in nb_f1 and "f7" in nb_f1, nb_f1            # f1's two nearest (1074, 1195)
assert all(len(adj[n][0]) > 0 for n in flags), "no flag may be isolated"
# symmetry: if f1 lists f8, f8 lists f1
assert "f1" in adj["f8"][0], adj["f8"][0]
# base adjacency: f5/f6 sit near a-side; at least one flag lists team 'a'
assert any("a" in adj[n][1] for n in flags), "some flag should be a-base adjacent"
print("adjacency test OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools && python3 test_build_sectors.py`
Expected: FAIL with `AttributeError: module 'build_sectors' has no attribute 'adjacency'`.

- [ ] **Step 3: Implement adjacency + thread it through**

In `tools/build_sectors.py`, add after the `compute` function (after line 38):

```python
THRESH = 2000.0
KFLOOR = 2

def adjacency(bases, flags):
    """Return {name: (nb_list, base_list)}. nb = flags within THRESH unioned with the
    KFLOOR nearest, made symmetric. base = sorted team letters whose base is within THRESH."""
    names = list(flags.keys())
    nb = {n: set() for n in names}
    for a in names:
        dists = sorted((_dist(flags[a], flags[b]), b) for b in names if b != a)
        for d, b in dists:
            if d < THRESH:
                nb[a].add(b)
        for d, b in dists[:KFLOOR]:
            nb[a].add(b)
    for a in names:                      # symmetrize
        for b in list(nb[a]):
            nb[b].add(a)
    base = {n: set() for n in names}
    for n in names:
        for bname, bp in bases.items():
            if _dist(flags[n], bp) < THRESH:
                base[n].add(bname[0])
    key = lambda s: int(s[1:])
    return {n: (sorted(nb[n], key=key), sorted(base[n])) for n in names}
```

Change `emit_lua` (replace the whole function) to accept and emit adjacency:

```python
def emit_lua(entries):
    """entries: list of (key, bases, computed, adj)."""
    out = ["-- GENERATED by tools/build_sectors.py. Do not edit by hand.", "Sectors = {"]
    for mapkey, bases, comp, adj in entries:
        out.append('  ["%s"] = {' % mapkey)
        out.append("    bases = {")
        for k in sorted(bases):
            x, y = bases[k]
            out.append("      %s={x=%d, y=%d}," % (k, round(x), round(y)))
        out.append("    },")
        out.append("    flags = {")
        for k in sorted(comp, key=lambda s: int(s[1:])):
            x, y, axis = comp[k]
            nb, base = adj[k]
            nbstr = ",".join('"%s"' % n for n in nb)
            line = '      %s={x=%d, y=%d, axis=%.2f, nb={%s}' % (k, round(x), round(y), axis, nbstr)
            if base:
                line += ", base={%s}" % ",".join('"%s"' % t for t in base)
            line += "},"
            out.append(line)
        out.append("    },")
        out.append("  },")
    out.append("}")
    return "\n".join(out) + "\n"
```

Change the `main` loop body (the `entries.append(...)` line) to:

```python
            entries.append((m, bases, compute(bases, flags), adjacency(bases, flags)))
```

- [ ] **Step 4: Run the python test to verify it passes**

Run: `cd tools && python3 test_build_sectors.py`
Expected: `build_sectors test OK` and `adjacency test OK`.

- [ ] **Step 5: Regenerate flag_sectors.lua**

Run:

```bash
cd tools && python3 build_sectors.py \
  "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/map.pak" \
  2v2_bastogne 2v2_sidi_el-barrani 1v1_nikolaev 2v2_mamayev_kurgan \
  -o ../resource/script/multiplayer/flag_sectors.lua
```

Expected: `wrote ../resource/script/multiplayer/flag_sectors.lua entries: 4`.

Verify the new fields are present and keys are still the 4 map names:

```bash
grep -c 'nb={' ../resource/script/multiplayer/flag_sectors.lua    # expect 35 (total flags across 4 maps)
grep -oE '^\s*\["[^"]+"\]' ../resource/script/multiplayer/flag_sectors.lua
```

Expected keys: `["2v2_bastogne"]`, `["2v2_sidi_el-barrani"]`, `["1v1_nikolaev"]`, `["2v2_mamayev_kurgan"]`.

- [ ] **Step 6: Lint and commit**

```bash
cd ../resource/script/multiplayer && luac -p flag_sectors.lua
cd ../../../  # repo root
git add tools/build_sectors.py tools/test_build_sectors.py resource/script/multiplayer/flag_sectors.lua
git commit -m "feat: offline flag adjacency (nb + base) in flag_sectors"
```

---

### Task 2: LabelFlags carries nb/base + IsFrontier

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`LabelFlags` copies nb/base; add `IsFrontier`)
- Test: `resource/script/multiplayer/tests/frontier_spec.lua` (create)

**Interfaces:**
- Consumes: `Context.FlagLabel[name]` now needs `nb` (list) and `base` (list) fields; they come from `Sectors[map].flags[name].nb/base` produced in Task 1.
- Produces: `IsFrontier(name) -> bool` global. True if any flag in `Context.FlagLabel[name].nb` is occupied by `BotApi.Instance.team`, or `Context.FlagLabel[name].base` contains the team letter. False if the flag has no label or no `nb`.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/frontier_spec.lua`:

```lua
dofile((arg[0]:gsub("frontier_spec%.lua$", "harness.lua")))

local function bastogneFlags(occ)
	local t = {}
	for _, n in ipairs({"f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f20"}) do
		t[#t + 1] = { name = n, occupant = occ[n] or 0 }
	end
	return t
end

-- team a, bastogne; nobody owns anything yet
BotApi.Instance.team = "a"; BotApi.Instance.playerId = 1
BotApi.Scene.Flags = bastogneFlags({})
Context.MapName = "2v2_bastogne"
LabelFlags()

-- LabelFlags must carry the adjacency graph onto FlagLabel
assert(Context.FlagLabel["f1"].nb, "f1 has nb")
assert(#Context.FlagLabel["f1"].nb > 0, "f1 nb non-empty")

-- No owned flags and no base adjacency for f10 -> not frontier
-- (f10 is deep; it is not adjacent to a-base and we own nothing)
assert(IsFrontier("f10") == false, "f10 not frontier when nothing owned")

-- Own f8 (a neighbor of f1); now f1 becomes frontier
BotApi.Scene.Flags = bastogneFlags({ f8 = "a" })
LabelFlags()
assert(IsFrontier("f1") == true, "f1 frontier once neighbor f8 owned")

-- Base adjacency: a flag whose base list includes 'a' is frontier for team a with nothing owned
local baseAdjFlag
for n, lbl in pairs(Context.FlagLabel) do
	if lbl.base then for _, t in ipairs(lbl.base) do if t == "a" then baseAdjFlag = n end end end
end
assert(baseAdjFlag, "some flag is a-base adjacent")
BotApi.Scene.Flags = bastogneFlags({})
LabelFlags()
assert(IsFrontier(baseAdjFlag) == true, "base-adjacent flag is frontier for its team")

-- Unknown flag / no label -> false, no error
assert(IsFrontier("nonexistent") == false, "no label -> not frontier")

print("frontier OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/frontier_spec.lua`
Expected: FAIL — either `f1 has nb` assertion (LabelFlags does not yet copy nb) or `attempt to call global 'IsFrontier'`.

- [ ] **Step 3: Make LabelFlags carry nb/base**

In `resource/script/multiplayer/bot.lua`, in `LabelFlags`, change the present-flag collection (the `present[#present + 1] = {...}` line, ~732) to include nb/base:

```lua
			present[#present + 1] = { name = flag.name, myAxis = myAxis, x = d.x, y = d.y,
				nb = d.nb, base = d.base }
```

and change the `Context.FlagLabel[p.name] = {...}` assignment (~747) to:

```lua
		Context.FlagLabel[p.name] = { sector = sector, rank = rank, axis = p.myAxis,
			x = p.x, y = p.y, nb = p.nb, base = p.base }
```

- [ ] **Step 4: Add IsFrontier**

In `resource/script/multiplayer/bot.lua`, immediately AFTER the `LabelFlags` function's `end`, add:

```lua
-- A flag is on the frontier if a neighbor is held by our team, or it is adjacent to our base.
-- Needs the offline adjacency graph (Context.FlagLabel[name].nb/base); false without it.
function IsFrontier(name)
	local label = Context.FlagLabel[name]
	if not label or not label.nb then return false end
	local team = BotApi.Instance.team
	if label.base then
		for _, t in ipairs(label.base) do
			if t == team then return true end
		end
	end
	for _, nbname in ipairs(label.nb) do
		for _, flag in pairs(BotApi.Scene.Flags) do
			if flag.name == nbname and flag.occupant == team then return true end
		end
	end
	return false
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/frontier_spec.lua`
Expected: `frontier OK`.

- [ ] **Step 6: Run existing specs (no regression) and commit**

```bash
cd resource/script/multiplayer
for t in sector_spec partition_spec mapname_spec phase_spec integration_spec; do lua tests/$t.lua || exit 1; done
luac -p bot.lua
cd ../../../
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/frontier_spec.lua
git commit -m "feat: LabelFlags carries nb/base; add IsFrontier"
```

---

### Task 3: PickGroupTarget tier ladder

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (add `NearestOwnedDist`; rewrite `PickGroupTarget`; log the tier in `UpdateGroupTargets`)
- Test: `resource/script/multiplayer/tests/routing_spec.lua` (create)

**Interfaces:**
- Consumes: `IsFrontier(name)` (Task 2); `Context.FlagLabel[name].{sector,axis,x,y}`; `Context.FlagOwner[name].mine`; `Context.LostStamp[name]`.
- Produces: `PickGroupTarget(excludeName) -> string|nil` (same signature; new ordering). `NearestOwnedDist(label) -> number|nil` helper. `Context.LastPickTier` set for the log line.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/routing_spec.lua`:

```lua
dofile((arg[0]:gsub("routing_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

local function bastogne(occ)
	local t = {}
	for _, n in ipairs({"f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f20"}) do
		t[#t + 1] = { name = n, occupant = occ[n] or 0 }   -- 0 = neutral
	end
	return t
end

-- team a setup; enemy is team "b"
BotApi.Instance.team = "a"; BotApi.Instance.enemyTeam = "b"
BotApi.Instance.teamSize = 2; BotApi.Instance.playerId = 1
Context.MapName = "2v2_bastogne"
Context.LostStamp = {}

-- Tier 1: enemy holds an OWN-sector flag (f5 is OWN for team a) -> retaken first,
-- even though enemy also holds a deep flag f10.
BotApi.Scene.Flags = bastogne({ f5 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f5", "tier1 home invaded beats deep flag")

-- enemyAttacking: a neutral flag with a LostStamp is a candidate; without one it is not.
-- Enemy holds nothing; f6 (OWN) is neutral but recently lost -> tier 1 candidate.
Context.LostStamp = { f6 = 100 }
BotApi.Scene.Flags = bastogne({})            -- all neutral
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f6", "neutral+LostStamp OWN flag is tier1")

-- A neutral flag with NO LostStamp is not a candidate -> nil when nothing else qualifies.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({})
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), nil, "no enemy and no recently-lost -> nil")

-- Tier 2 over Tier 3: home secure; enemy holds a CONTESTED flag in our lane that is
-- frontier (we own a neighbor) plus a deeper enemy flag. The frontier-lane one wins.
-- We own f8; f1 is CONTESTED, neighbor of f8, in lane. Enemy holds f1 and f10.
-- f1 is the only tier-2 candidate (CONTESTED, neighbor of owned f8 -> frontier, and mine
-- for playerId 1 per the partition); f10 is tier 3 (ENEMY sector). f1 must win.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f8 = "a", f1 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f1", "tier2 lane frontier beats tier3 deep flag")
eq(Context.LastPickTier, 2, "f1 picked at tier 2")

-- Never-nil: a single deep enemy flag with no frontier still returns it (tier 3).
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f10", "lone deep enemy flag still targeted")

print("routing OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: FAIL on the first `eq` (current `PickGroupTarget` uses recapture/priority, not the tier ladder) or on `Context.LastPickTier`.

- [ ] **Step 3: Add NearestOwnedDist and rewrite PickGroupTarget**

In `resource/script/multiplayer/bot.lua`, REPLACE the whole `PickGroupTarget` function (the comment line `-- The group's attack flag...` through its `end`) with:

```lua
-- Squared distance from a flag's coords to the nearest flag our team currently owns.
-- nil when the flag has no coords or we own no coord-bearing flag (triggers legacy ordering).
function NearestOwnedDist(label)
	if not (label and label.x) then return nil end
	local team = BotApi.Instance.team
	local best
	for _, flag in pairs(BotApi.Scene.Flags) do
		if flag.occupant == team then
			local o = Context.FlagLabel[flag.name]
			if o and o.x then
				local dx, dy = label.x - o.x, label.y - o.y
				local d = dx * dx + dy * dy
				if not best or d < best then best = d end
			end
		end
	end
	return best
end

-- The group's attack flag, by a defensive-first tier ladder over candidates
-- (enemy-held flags + neutral flags we recently lost), excluding excludeName.
-- Tier 1: enemy holds/attacks an OWN-sector flag (home invaded; any lane).
-- Tier 2: a mine + frontier + CONTESTED flag the enemy holds/attacks (our lane's front).
-- Tier 3: everything else -> closest next flag (expand). Tier 3 is the catch-all, so this
-- returns nil only when no candidate exists. Sets Context.LastPickTier for logging.
function PickGroupTarget(excludeName)
	local team = BotApi.Instance.team
	local enemy = BotApi.Instance.enemyTeam
	local best
	for _, flag in pairs(BotApi.Scene.Flags) do
		local name = flag.name
		if name ~= excludeName then
			local held = flag.occupant == enemy
			local attacking = flag.occupant ~= team and flag.occupant ~= enemy
				and Context.LostStamp[name] ~= nil
			if held or attacking then
				local label = Context.FlagLabel[name] or {}
				local owner = Context.FlagOwner[name]
				local tier, key
				if label.sector == "OWN" then
					tier, key = 1, label.axis or 1
				elseif owner and owner.mine and label.sector == "CONTESTED" and IsFrontier(name) then
					tier, key = 2, label.axis or 1
				else
					local d = NearestOwnedDist(label)
					if d then
						tier, key = 3, d
					else
						local stamp = Context.LostStamp[name]
						tier, key = 3, (stamp and -stamp or (1e9 - GetFlagPriority(flag)))
					end
				end
				if not best or tier < best.tier
				   or (tier == best.tier and key < best.key)
				   or (tier == best.tier and key == best.key and name < best.name) then
					best = { name = name, tier = tier, key = key }
				end
			end
		end
	end
	Context.LastPickTier = best and best.tier
	return best and best.name
end
```

- [ ] **Step 4: Log the tier in UpdateGroupTargets**

In `resource/script/multiplayer/bot.lua`, in `UpdateGroupTargets`, both `print("[AISPAWN] GROUP_TARGET ...)` lines currently end with:

```lua
						.. " reason=" .. (Context.LostStamp[newT] and "recapture" or "priority") .. PidTag())
```

Change BOTH occurrences to append the tier:

```lua
						.. " reason=" .. (Context.LostStamp[newT] and "recapture" or "priority")
						.. " tier=" .. tostring(Context.LastPickTier) .. PidTag())
```

- [ ] **Step 5: Run the routing test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: `routing OK`.

- [ ] **Step 6: Full gate**

```bash
cd resource/script/multiplayer && luac -p bot.lua && luac -p flag_sectors.lua
for t in phase_spec integration_spec sector_spec partition_spec mapname_spec frontier_spec routing_spec; do lua tests/$t.lua || exit 1; done
cd ../../../tools && python3 test_build_sectors.py
```

Expected: every spec prints its OK line; `build_sectors test OK` and `adjacency test OK`.

- [ ] **Step 7: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/routing_spec.lua
git commit -m "feat: PickGroupTarget defensive-first tier ladder (frontier + partition + sector)"
```

---

## Notes for the implementer

- `Context.LostStamp` must already be a table before `PickGroupTarget` runs; it is initialized in the bot's normal startup. The tests set it explicitly.
- Do NOT touch capper/defender/`GetFlagToCapture` logic.
- After this plan, verify in a real self-hosted bastogne match: `grep "GROUP_TARGET" game.log` should show `tier=1/2/3` values, and a group whose home flag is taken should retarget to it (tier 1).
