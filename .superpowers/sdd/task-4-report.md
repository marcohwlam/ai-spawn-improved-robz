# Task 4 Report

## Status: DONE

Commit: `d682582`

---

## Step 1: Python assertions

Appended to `tools/test_build_sectors.py`:

```python
# --- bastogne after renorm: each team has an OWN home flag ---
rn = bs.renorm(bs.compute(bases, flags), bs.adjacency(bases, flags))
assert rn["f5"][2] < 0.4 and rn["f6"][2] < 0.4, (rn["f5"], rn["f6"])   # team-a home OWN
assert rn["f10"][2] > 0.6 and rn["f4"][2] > 0.6, (rn["f10"], rn["f4"]) # team-b home OWN
adj = bs.adjacency(bases, flags)
a_n = sum(1 for n in flags if adj[n][1] == ["a"])
b_n = sum(1 for n in flags if adj[n][1] == ["b"])
assert a_n == b_n and a_n >= 1, (a_n, b_n)
print("bastogne renorm OK")
```

All prints including `bastogne renorm OK` passed.

---

## Step 2: Regenerated flag_sectors.lua

Command:
```bash
python3 tools/build_sectors.py \
  "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/map.pak" \
  2v2_bastogne 2v2_sidi_el-barrani 1v1_nikolaev 2v2_mamayev_kurgan \
  -o resource/script/multiplayer/flag_sectors.lua
```
Output: `wrote resource/script/multiplayer/flag_sectors.lua entries: 4`

---

## Step 3: Regenerated bastogne block

```
  ["2v2_bastogne"] = {
    bases = {
      a1={x=-4300, y=-647},
      a2={x=-4300, y=746},
      b1={x=3931, y=-646},
      b2={x=3986, y=746},
    },
    flags = {
      f1={x=-212, y=-98, axis=0.63, nb={"f7","f8"}},
      f2={x=-618, y=-2952, axis=0.50, nb={"f4","f6","f7"}},
      f3={x=-288, y=3674, axis=0.60, nb={"f9","f20"}},
      f4={x=573, y=-1945, axis=0.93, nb={"f2","f7"}, base={"b"}},
      f5={x=-1738, y=1707, axis=0.00, nb={"f8","f9"}, base={"a"}},
      f6={x=-1748, y=-1852, axis=0.02, nb={"f2","f7"}, base={"a"}},
      f7={x=-357, y=-1284, axis=0.56, nb={"f1","f2","f4","f6"}},
      f8={x=-101, y=970, axis=0.66, nb={"f1","f5","f9","f10"}},
      f9={x=-66, y=2445, axis=0.67, nb={"f3","f5","f8","f10","f20"}},
      f10={x=739, y=1705, axis=1.00, nb={"f8","f9"}, base={"b"}},
      f20={x=-14, y=5042, axis=0.67, nb={"f3","f9"}},
    },
  },
```

Eyeball checks:
- f5 axis=0.00, f6 axis=0.02 — both near 0.00 (team-a home OWN) ✓
- f4 axis=0.93 ✓
- f10 axis=1.00 ✓
- base={"a"}: f5, f6 (count=2); base={"b"}: f4, f10 (count=2) — equal ✓

---

## Step 4: sector_spec.lua additions

Added per brief:

**team-a block** (before `assert(Context.FlagBases...`):
```lua
local ownA = 0
for _, l in pairs(Context.FlagLabel) do if l.sector == "OWN" then ownA = ownA + 1 end end
assert(ownA >= 1, "team a must have >=1 OWN flag, got " .. ownA)
```

**team-b block** (before `print("sector team-b OK")`):
```lua
eq(Context.FlagLabel["f10"].sector, "OWN", "b f10 sector")
eq(Context.FlagLabel["f4"].sector, "OWN", "b f4 sector")
local ownB = 0
for _, l in pairs(Context.FlagLabel) do if l.sector == "OWN" then ownB = ownB + 1 end end
assert(ownB >= 1, "team b must have >=1 OWN flag, got " .. ownB)
```

---

## Step 5: Lua specs — all passed

| Spec | Result |
|---|---|
| sector_spec.lua | PASS |
| routing_spec.lua | PASS (after expectation update — see below) |
| frontier_spec.lua | PASS |
| partition_spec.lua | PASS |
| integration_spec.lua | PASS |
| phase_spec.lua | PASS |
| mapname_spec.lua | PASS |

---

## Stale expectation updated: routing_spec.lua

**Why it failed:** With two-point renorm, f1's axis became 0.63 (ENEMY for team a, up from what was previously CONTESTED ~0.5 range). The tier-2 path requires a CONTESTED flag; with f1 now ENEMY, the pick of f1 still occurs but at tier 3 (distance ordering within ENEMY).

**Before:**
```lua
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
```

**After:**
```lua
-- After two-point renorm (task-4 plan), f1 axis=0.63 is ENEMY for team a (not CONTESTED).
-- Both f1 and f10 are ENEMY; f1 wins tier 3 because it is closer to our front than f10.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f8 = "a", f1 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f1", "f1 (closer enemy) beats f10 (deeper enemy)")
eq(Context.LastPickTier, 3, "f1 picked at tier 3")
```

This is a correct data-driven update: the tier changed because f1's axis moved from ~0.5 (CONTESTED boundary) to 0.63 (ENEMY) due to the renorm anchoring. The routing logic itself is unchanged; only the tier classification of f1 changed. No production logic was touched.

---

## Follow-up: tier-2 CONTESTED-frontier coverage restored (commit 2b29b64)

### Problem

The routing_spec stale-expectation fix (above) corrected the f1+f10 test to tier 3, but in doing so dropped the only test that exercised the tier-2 (CONTESTED frontier beats ENEMY) ordering path. The follow-up review flagged this gap.

### Added test case

Inserted in `resource/script/multiplayer/tests/routing_spec.lua` before the ownall test:

```lua
-- Tier 2 (CONTESTED frontier) beats tier 3 (ENEMY): post-renorm coverage for f7.
-- f6 (axis=0.02, OWN for team a) held by team a makes f7 a frontier flag, because f6
-- is in f7.nb ({"f1","f2","f4","f6"}). f7 (axis=0.56) is CONTESTED (0.4 <= 0.56 < 0.6)
-- and falls in lateral band 1 (mine=true for playerId=1, teamSize=2). f10 (axis=1.00,
-- ENEMY) is also enemy-held but has no mine+CONTESTED+frontier qualification -> tier 3.
BotApi.Instance.playerId = 1
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f6 = "a", f7 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f7", "tier2 CONTESTED frontier beats tier3 ENEMY")
eq(Context.LastPickTier, 2, "f7 picked at tier 2")
```

### Why this yields tier 2 vs tier 3

| Flag | axis | myAxis (team a) | sector | mine (pid=1) | IsFrontier | tier |
|---|---|---|---|---|---|---|
| f7 | 0.56 | 0.56 | CONTESTED (0.4<=x<0.6) | true (band=1) | true (neighbor f6 held by team a) | **2** |
| f10 | 1.00 | 1.00 | ENEMY (>=0.6) | true (shared, u~0.58) | N/A (ENEMY disqualifies tier-2) | 3 |

- f7 satisfies all three tier-2 conditions: `owner.mine`, `sector==CONTESTED`, `IsFrontier`.
- f10 is ENEMY, so it falls through to tier 3 regardless of mine/frontier status.
- Tier 2 < tier 3, so f7 wins.

### Spec output

```
routing OK
```

```
sector team-b OK
sector fallback OK
```

Both specs passed with no collateral breakage.
