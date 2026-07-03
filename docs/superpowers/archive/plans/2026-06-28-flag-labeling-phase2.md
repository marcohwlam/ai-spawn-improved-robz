# Flag Labeling — Phase 2 (Compute + Log) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute a lateral, non-overlapping flag partition between the two teammate bots from the Phase 1 coordinates, write it to `Context.FlagOwner`, and log it — without yet routing any units.

**Architecture:** At `OnGameStart`, after `LabelFlags()`, a new `PartitionFlags()` projects each labeled flag onto the axis perpendicular to the A→B base line (lateral position), splits flags into `teamSize` bands plus a shared central margin, derives this bot's team index from `playerId`, and marks each flag's band / shared / mine. It only computes and logs; no `CaptureFlag` order is issued. Two teammates running identical code over identical data compute an identical partition with no communication.

**Tech Stack:** Lua 5.1 (game engine; no `goto`), `luac` + `lua` offline gates, the existing `tests/harness.lua` harness.

Spec: `docs/superpowers/specs/2026-06-28-flag-labeling-design.md` (Phase 2 Design section). This plan is **compute + log only**. Wiring `Context.FlagOwner` / sector into actual unit routing (`CaptureFlag` / `PickGroupTarget` / `GetFlagToCapture`) is the step AFTER the in-game gate and is NOT in this plan.

## Gate posture

This plan is safe to build before the in-game gate. The gate verifies the playerId-contiguous-by-team assumption, which only matters once units act on the partition. To keep a future routing wire safe regardless, `PartitionFlags()` bakes in the collision-safe fallback now: if the derived `idx` falls outside `1..teamSize` (the assumption failed), every flag is marked `mine = true` (own-all = today's no-partition behavior). The `PART` log lines are exactly what the gate inspects.

## Global Constraints

- Engine is Lua 5.1: no `goto`, no bitops; use `table.insert` / numeric loops / `string.sub` as the existing code does.
- Mod working dir for gates: `resource/script/multiplayer/`. Gates that must pass after every task: `luac -p bot.lua`, `luac -p bot.data.lua`, `luac -p flag_sectors.lua`, `lua tests/phase_spec.lua`, `lua tests/integration_spec.lua`, `lua tests/sector_spec.lua`, `lua tests/partition_spec.lua`.
- `BotApi.Instance` exposes `team` (`"a"`/`"b"`), `playerId` (int), `teamSize` (players per team, int). No roster, no positions.
- This plan consumes Phase 1 outputs already in `bot.lua`: `Context.FlagLabel[name] = {sector, rank, axis, x, y}` and `Context.FlagBases = {a1={x,y}, a2={x,y}, b1={x,y}, b2={x,y}}` (both set by `LabelFlags()` at `OnGameStart`; `FlagBases` is `nil` on an unrecognized map).
- Compute + log ONLY. Do NOT call `BotApi.Commands:CaptureFlag` or modify `CaptureFlag` / `PickGroupTarget` / `GetFlagToCapture` / `UpdateGroupTargets`.
- Repo root for git: `/home/lamho/Documents/repos/ai-spawn-improved-robz` (symlinked into the Steam mods dir). Commit and push after each task.
- Tunable constant: `PartSharedHalfWidth = 0.15` (half-width, in normalized lateral units `[0,1]`, of the shared band around each internal band boundary).

## File Structure

- Modify: `resource/script/multiplayer/bot.lua` — add `PartSharedHalfWidth` constant, `PartitionFlags()`, `Context.FlagOwner` field, and the `PartitionFlags()` call in `OnGameStart`.
- Create: `resource/script/multiplayer/tests/partition_spec.lua` — unit tests over real bastogne data.

---

### Task 1: PartitionFlags computation + unit tests

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (add constant + `PartitionFlags()`; no wiring yet)
- Create: `resource/script/multiplayer/tests/partition_spec.lua`

**Interfaces:**
- Consumes: `Context.FlagLabel[name].{x,y}` and `Context.FlagBases` (set by Phase 1 `LabelFlags()`); `BotApi.Instance.{team, playerId, teamSize}`.
- Produces: `PartitionFlags()` populates `Context.FlagOwner[name] = { band = <int 1..teamSize>, shared = <bool>, mine = <bool>, lat = <number> }`. On an unrecognized map / missing data it leaves `Context.FlagOwner = {}` and logs `PART_FALLBACK`. Consumed by Task 2 (the `OnGameStart` call) and by the future routing step.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/partition_spec.lua`:

```lua
dofile((arg[0]:gsub("partition_spec%.lua$", "harness.lua")))

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

-- Phase 1 populates FlagLabel{x,y} + FlagBases for bastogne; reuse it as the input.
BotApi.Scene.Flags = bastogneFlags()
BotApi.Instance.team = "a"; BotApi.Instance.teamSize = 2

-- bot idx 1 (playerId 1) and idx 2 (playerId 2) of team a.
BotApi.Instance.playerId = 1; LabelFlags(); PartitionFlags()
local own1, band1 = {}, {}
for n, o in pairs(Context.FlagOwner) do own1[n] = o.mine; band1[n] = o.band end

BotApi.Instance.playerId = 2; PartitionFlags()
local own2 = {}
for n, o in pairs(Context.FlagOwner) do own2[n] = o.mine end

-- Determinism: bands are identical regardless of which bot computed them.
for n, o in pairs(Context.FlagOwner) do eq(o.band, band1[n], "band stable for " .. n) end

-- Coverage + de-confliction: every flag owned by at least one teammate; a flag owned by
-- BOTH iff it is shared; non-shared flags owned by exactly one.
for n, o in pairs(Context.FlagOwner) do
	assert(own1[n] or own2[n], "flag " .. n .. " owned by nobody")
	if o.shared then
		assert(own1[n] and own2[n], "shared flag " .. n .. " not owned by both")
	else
		assert(own1[n] ~= own2[n], "non-shared flag " .. n .. " not exclusive")
	end
end
print("partition coverage OK")

-- Untrusted idx (team a, playerId 3, teamSize 2 -> idx 3 out of 1..2): own-all fallback.
BotApi.Instance.playerId = 3; PartitionFlags()
for n, o in pairs(Context.FlagOwner) do eq(o.mine, true, "untrusted idx owns " .. n) end
print("partition untrusted-idx OK")

-- No bases (unrecognized map): empty FlagOwner, PART_FALLBACK, no error.
Context.FlagBases = nil
Context.FlagLabel = { zz1 = { sector = "CONTESTED" } }
PartitionFlags()
eq(next(Context.FlagOwner), nil, "fallback leaves FlagOwner empty")
print("partition fallback OK")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/partition_spec.lua`
Expected: FAIL — `attempt to call a nil value (global 'PartitionFlags')`.

- [ ] **Step 3: Add the constant and PartitionFlags() to bot.lua**

Add the constant next to the sector thresholds (after `local SectorEnemyMin = 0.6`):

```lua
-- Half-width (normalized lateral units [0,1]) of the SHARED band around each internal
-- teammate-band boundary. Flags within this margin belong to both teammates on purpose;
-- narrower = cleaner split, wider = more overlap/coverage. Tunable.
local PartSharedHalfWidth = 0.15
```

Add `PartitionFlags()` as a new top-level function (place it just after `LabelFlags()`):

```lua
-- Split the labeled flags laterally between teammate bots. Pure geometry over the Phase 1
-- coords: project each flag onto the axis perpendicular to A->B, band by normalized lateral
-- position, and mark band / shared / mine. Compute + log only -- issues no orders. Two
-- teammates compute an identical partition (same data, same teamSize); only `mine` differs.
-- Collision-safe: if this bot's idx is outside 1..teamSize (the playerId assumption failed),
-- every flag is marked mine (own-all = no partition). nil FlagBases => skip + PART_FALLBACK.
function PartitionFlags()
	Context.FlagOwner = {}
	local bases = Context.FlagBases
	local team = BotApi.Instance.team
	local pid = BotApi.Instance.playerId
	local teamSize = BotApi.Instance.teamSize
	if not bases or not teamSize or teamSize < 1 then
		print("[AISPAWN] PART_FALLBACK reason=no_bases")
		return
	end
	-- A-home and B-home centroids from the base spawns (names start with "a" / "b").
	local ax, ay, an, bx, by, bn = 0, 0, 0, 0, 0, 0
	for name, b in pairs(bases) do
		if string.sub(name, 1, 1) == "a" then ax = ax + b.x; ay = ay + b.y; an = an + 1
		elseif string.sub(name, 1, 1) == "b" then bx = bx + b.x; by = by + b.y; bn = bn + 1 end
	end
	if an == 0 or bn == 0 then
		print("[AISPAWN] PART_FALLBACK reason=missing_side")
		return
	end
	ax, ay, bx, by = ax / an, ay / an, bx / bn, by / bn
	-- Forward axis A->B = (fx, fy); lateral axis is the perpendicular (-fy, fx).
	local fx, fy = bx - ax, by - ay
	local px, py = -fy, fx
	-- Each labeled flag's signed lateral projection, relative to the A centroid.
	local flags = {}
	for name, lab in pairs(Context.FlagLabel) do
		if lab.x and lab.y then
			local lat = (lab.x - ax) * px + (lab.y - ay) * py
			flags[#flags + 1] = { name = name, lat = lat }
		end
	end
	if #flags == 0 then
		print("[AISPAWN] PART_FALLBACK reason=no_coords")
		return
	end
	-- Normalize lateral to [0,1] across the present flags.
	local lo, hi = flags[1].lat, flags[1].lat
	for _, f in ipairs(flags) do
		if f.lat < lo then lo = f.lat end
		if f.lat > hi then hi = f.lat end
	end
	local span = hi - lo
	-- This bot's team index, and whether it is in range (the gate-verified assumption).
	local idx = (team == "b") and (pid - teamSize) or pid
	local idxTrusted = (idx >= 1 and idx <= teamSize)
	for _, f in ipairs(flags) do
		local u = (span > 0) and ((f.lat - lo) / span) or 0.5
		local band = math.floor(u * teamSize) + 1
		if band > teamSize then band = teamSize end
		local shared = false
		for k = 1, teamSize - 1 do
			if math.abs(u - k / teamSize) <= PartSharedHalfWidth then shared = true; break end
		end
		local mine = (not idxTrusted) or shared or (band == idx)
		Context.FlagOwner[f.name] = { band = band, shared = shared, mine = mine, lat = f.lat }
		print("[AISPAWN] PART pid=" .. tostring(pid) .. " team=" .. tostring(team)
			.. " idx=" .. tostring(idx) .. " trusted=" .. tostring(idxTrusted)
			.. " " .. f.name .. " band=" .. band
			.. " shared=" .. tostring(shared) .. " mine=" .. tostring(mine))
	end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/partition_spec.lua`
Expected: `partition coverage OK`, `partition untrusted-idx OK`, `partition fallback OK`.

- [ ] **Step 5: Run the full gate suite**

Run:
```bash
cd resource/script/multiplayer
luac -p bot.lua && luac -p bot.data.lua && luac -p flag_sectors.lua \
  && lua tests/phase_spec.lua && lua tests/integration_spec.lua \
  && lua tests/sector_spec.lua && lua tests/partition_spec.lua
```
Expected: all OK lines, no errors.

- [ ] **Step 6: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/partition_spec.lua
git commit -m "Add PartitionFlags lateral teammate split (compute + log) with tests"
git push
```

---

### Task 2: Wire PartitionFlags into the match lifecycle

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (init `Context.FlagOwner`; call `PartitionFlags()` in `OnGameStart`)

**Interfaces:**
- Consumes: `PartitionFlags()` and `LabelFlags()` (must run after LabelFlags, which populates the inputs).
- Produces: populated `Context.FlagOwner` at the start of every match, and a `PART ...` debug line per flag in game.log (the in-game gate reads these alongside the `SECTOR ...` lines).

- [ ] **Step 1: Declare the new Context field**

In the global `Context = { ... }` table literal at the top of `bot.lua`, add this field
immediately after the `FlagBases = nil,` line from Phase 1:

```lua
	FlagOwner = {},    -- flag name -> {band, shared, mine, lat}; set by PartitionFlags at start
```

- [ ] **Step 2: Call PartitionFlags in OnGameStart**

In `function OnGameStart()`, the Phase 1 `LabelFlags()` call already exists (right after the
`print("[AISPAWN] START_PROBE ...)` statement). Add `PartitionFlags()` on the line
immediately after it, so the partition reads the labels `LabelFlags()` just wrote:

```lua
	LabelFlags()
	PartitionFlags()
```

- [ ] **Step 3: Verify the wiring compiles and all gates pass**

Run:
```bash
cd resource/script/multiplayer
luac -p bot.lua && luac -p bot.data.lua && luac -p flag_sectors.lua \
  && lua tests/phase_spec.lua && lua tests/integration_spec.lua \
  && lua tests/sector_spec.lua && lua tests/partition_spec.lua
```
Expected: all OK, no errors. (`OnGameStart` is not invoked by any offline test, so the
harness's integer `team`/empty `Scene.Flags` never reach `PartitionFlags`; in-game inputs
are always valid. `PartitionFlags` with a nil `Context.FlagBases` logs `PART_FALLBACK` and
returns without error.)

- [ ] **Step 4: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.lua
git commit -m "Call PartitionFlags at match start; init FlagOwner Context"
git push
```

---

## After Phase 2 (compute + log): the in-game gate still governs routing

Phase 2 computes and logs the partition but routes nothing. Before any routing step that
makes units act on `Context.FlagOwner`, run the self-hosted bastogne 2v2 gate (spec's
Phase 1→2 gate) and confirm from game.log:
1. `PART ...` lines appear with `trusted=true` for every bot (idx in range ⇒ playerId
   contiguous-by-team holds).
2. The two team-a bots show complementary `mine=true` sets (each owns its band + shared),
   and the two team-b bots likewise — i.e. no two teammates exclusively own the same flag.
3. `SECTOR ...` lines (Phase 1) are still sane (fingerprint matched, no `SECTOR_FALLBACK`).
Only after this passes should the routing-wire plan (consume `FlagOwner` + `sector` in
`CaptureFlag` / `PickGroupTarget` / `GetFlagToCapture`) be written.
