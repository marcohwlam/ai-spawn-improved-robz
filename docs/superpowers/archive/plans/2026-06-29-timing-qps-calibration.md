# Timing Redesign + QPS Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Calibrate the quant rate at runtime so the bot's elapsed clock matches real seconds (fixing unlock/phase gates that fired ~2.2x too late), and remove the now-redundant `armorCap` tier ceiling.

**Architecture:** Add `Context.StartTime`/`Context.QuantsPerSec`; calibrate once early-game from `os.time()`; route every time decision through new `Elapsed()` (seconds) and `Q(sec)` (quant-length) helpers; delete `armorCap`/`TierRank`/`capOk`.

**Tech Stack:** Lua 5.1 (game engine; no `goto`), plain-Lua specs run with stock `lua`.

## Global Constraints

- Lua 5.1, 32-bit engine, no `goto`.
- Run Lua specs from `resource/script/multiplayer/`: `lua tests/<name>_spec.lua` (each `dofile`s `tests/harness.lua`, which loads `bot.lua` with a stubbed `BotApi`; the harness does NOT stub `os`, so `os.time` is the real clock unless a spec overrides it).
- Run the whole suite: `for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done` — every spec prints its `OK` line.
- Calibration constants (verbatim): `CALIB_SEC = 20`, `CALIB_MIN_Q = 200`, `QPS_MIN = 10`, `QPS_MAX = 200`, `DEFAULT_QPS = 32`.
- `Elapsed()` = `Context.QuantsPerSec and (Context.MatchQuants / Context.QuantsPerSec) or (os.time() - (Context.StartTime or os.time()))`.
- `Q(sec)` = `sec * (Context.QuantsPerSec or DEFAULT_QPS)`.
- Calibration is one-shot (never recalibrates) and runs in `OnGameQuant` after the `MatchQuants` increment.
- Interval durations move to second-valued constants and use `Q(sec)` at the comparison site; the `MatchQuants`-based stamps stay as-is.
- `armorCap`, `TierRank`, `capRank`, `capOk` are removed entirely.
- Commit after each task; push branch `feat/timing-qps-calibration` after each task.

## File Structure

- `resource/script/multiplayer/bot.lua` (modify) — constants block (44-81), `Context` init (~30), `Elapsed()`/`Q()` (new, placed after the constants block), `OnGameStart` (~1043), `OnGameQuant` (~1139), all `MatchQuants / QuantsPerSec` sites, all interval comparison sites, the `armorCap` pool gate (601/616/623).
- `resource/script/multiplayer/bot.data.lua` (modify) — remove `armorCap` from each `Phases` entry and the `TierRank` table.
- `resource/script/multiplayer/tests/calib_spec.lua` (new) — calibration + `Elapsed()`/`Q()`.
- `resource/script/multiplayer/tests/unlock_spec.lua` (modify) — drive time via `Context.QuantsPerSec`.
- `resource/script/multiplayer/tests/integration_spec.lua` (modify) — give the medium/heavy fixtures an `unlock`, set `Context.QuantsPerSec`.

Two tasks: Task 1 replaces the time base (calibration + `Elapsed`/`Q` + rewire every consumer). Task 2 removes `armorCap`. A reviewer could approve the clock fix while rejecting the armorCap removal, so they are separate.

---

### Task 1: Calibrated `Elapsed()` / `Q()` time base

**Files:**
- Modify: `resource/script/multiplayer/bot.lua`
- Create: `resource/script/multiplayer/tests/calib_spec.lua`
- Modify: `resource/script/multiplayer/tests/unlock_spec.lua`

**Interfaces:**
- Produces: global `Elapsed() -> number` (match seconds) and `Q(sec) -> number` (quant length); `Context.StartTime` (os.time at match start), `Context.QuantsPerSec` (number once calibrated, else nil).

- [ ] **Step 1: Write the failing calibration spec**

Create `resource/script/multiplayer/tests/calib_spec.lua`:

```lua
dofile((arg[0]:gsub("calib_spec%.lua$", "harness.lua")))

-- Controllable os.time stub.
local fakeNow = 1000
os.time = function() return fakeNow end

-- Fresh match state.
Context.StartTime = os.time()
Context.QuantsPerSec = nil
Context.MatchQuants = 0

-- Before calibration: Elapsed() uses the wall fallback (os.time - StartTime).
fakeNow = 1005
assert(Elapsed() == 5, "pre-calib Elapsed uses wall delta, got " .. tostring(Elapsed()))
assert(Q(10) == 10 * 32, "pre-calib Q uses DEFAULT_QPS 32, got " .. tostring(Q(10)))

-- Drive quants; calibration fires once dtReal >= 20 and mq >= 200.
-- Simulate ~32 q/s: advance mq by 32 for each +1s of fake time.
Context.MatchQuants = 0
fakeNow = 1000
Context.StartTime = 1000
for s = 1, 25 do
	fakeNow = 1000 + s
	for i = 1, 32 do
		Context.MatchQuants = Context.MatchQuants + 1
		-- inline the calibration check the same way OnGameQuant does:
		if Context.QuantsPerSec == nil then
			local dt = os.time() - Context.StartTime
			if dt >= 20 and Context.MatchQuants >= 200 then
				local raw = Context.MatchQuants / dt
				Context.QuantsPerSec = math.max(10, math.min(200, raw))
			end
		end
	end
end
assert(Context.QuantsPerSec ~= nil, "should have calibrated")
assert(Context.QuantsPerSec >= 30 and Context.QuantsPerSec <= 34,
	"calibrated rate ~32, got " .. tostring(Context.QuantsPerSec))

-- After calibration Elapsed() = mq / QuantsPerSec.
Context.QuantsPerSec = 40
Context.MatchQuants = 4000
assert(Elapsed() == 100, "post-calib Elapsed = mq/QPS, got " .. tostring(Elapsed()))
assert(Q(10) == 400, "post-calib Q = sec*QPS, got " .. tostring(Q(10)))

-- Clamp guards a wild ratio.
assert(math.max(10, math.min(200, 5)) == 10, "clamp low")
assert(math.max(10, math.min(200, 999)) == 200, "clamp high")
print("calib OK")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/calib_spec.lua`
Expected: FAIL — `Elapsed`/`Q` are not defined yet (`attempt to call a nil value (global 'Elapsed')`).

- [ ] **Step 3: Rename interval constants to seconds, add calibration constants and time helpers**

Make TARGETED edits in `bot.lua` (do NOT block-replace the 44-81 range — it contains other locals like `OfficerCap`, `AtRifleCap` and explanatory comments that must survive). Change each `* 70` interval constant to a seconds-valued constant, one line at a time:

- `local WaveInterval    = 60 * 70 -- quants between wave starts (~60s at ~70 quant/sec)` → `local WaveIntervalSec     = 60   -- seconds between wave starts`
- `local MinWaveInterval = 10 * 70 -- floor: never faster than ~10s even when far behind` → `local MinWaveIntervalSec  = 10   -- floor: never faster than ~10s even when far behind`
- `local NeutralInterval = 5 * 70  -- ~5s between capper checks` → `local NeutralIntervalSec  = 5    -- seconds between capper checks`
- `local FailCooldownQuants = 10 * 70 -- ~10s bench after a failed spawn` → `local FailCooldownSec     = 10   -- seconds bench after a failed spawn`
- `local BackfillInterval = 3 * 70 -- ~3s between idle backfill spawns` → `local BackfillIntervalSec = 3    -- seconds between idle backfill spawns`
- `local DefenderInterval = 20 * 70 -- ~20s between defender checks` → `local DefenderIntervalSec = 20   -- seconds between defender checks`
- `local OfficerInterval = 30 * 70 -- quants between officer checks (~30s)` → `local OfficerIntervalSec  = 30   -- seconds between officer checks`
- `local AtRifleInterval = 20 * 70 -- ~20s between checks` → `local AtRifleIntervalSec  = 20   -- seconds between AT-rifle keep-alive checks`

Leave `OfficerUnlock = 600`, `OfficerCap`, `AtRifleCap`, `MaxGroups`, `GroupSize`, and every comment untouched. Do NOT remove `local QuantsPerSec = 70` yet (Step 6 removes it once its readers are rewired).

Replace the `local QuantsPerSec = 70` comment-and-constant region by INSERTING the calibration constants immediately ABOVE the `local QuantsPerSec = 70` line (keep that line for now):

```lua
-- Quant-rate calibration. The Quant event rate is NOT a fixed 70/sec; it is measured once
-- per match from os.time() and stored in Context.QuantsPerSec. Until then, Elapsed() uses a
-- wall-clock fallback and Q() uses DEFAULT_QPS.
local CALIB_SEC   = 20   -- real seconds of calibration window
local CALIB_MIN_Q = 200  -- minimum quants before trusting the ratio
local QPS_MIN     = 10   -- clamp floor for a calibrated rate
local QPS_MAX     = 200  -- clamp ceiling
local DEFAULT_QPS = 32   -- provisional rate before calibration (measured ~32)
```

Then add the two helpers immediately after the constants block (before `CurrentPhase`):

```lua
-- Match elapsed seconds. Uses the calibrated quant rate once available; before calibration,
-- falls back to wall-clock (os.time), which only governs the first ~CALIB_SEC of a match.
function Elapsed()
	if Context.QuantsPerSec then
		return Context.MatchQuants / Context.QuantsPerSec
	end
	return os.time() - (Context.StartTime or os.time())
end

-- Quant length of a duration in seconds, at the current (or provisional) rate.
function Q(sec)
	return sec * (Context.QuantsPerSec or DEFAULT_QPS)
end
```

In the `Context` table (near line 30), add two fields after `MatchQuants = 0,`:

```lua
	StartTime = nil,   -- os.time() at match start; set in OnGameStart
	QuantsPerSec = nil,-- calibrated quant rate; nil until the calibration window closes
```

- [ ] **Step 4: Set StartTime in OnGameStart and calibrate in OnGameQuant**

In `OnGameStart`, next to `Context.MatchQuants = 0` (line 1043), add:

```lua
	Context.StartTime = os.time()
	Context.QuantsPerSec = nil
```

In `OnGameQuant`, immediately after `Context.MatchQuants = Context.MatchQuants + 1` (line 1139), add:

```lua
	if Context.QuantsPerSec == nil then
		local dtReal = os.time() - (Context.StartTime or os.time())
		if dtReal >= CALIB_SEC and Context.MatchQuants >= CALIB_MIN_Q then
			Context.QuantsPerSec = math.max(QPS_MIN, math.min(QPS_MAX, Context.MatchQuants / dtReal))
		end
	end
```

- [ ] **Step 5: Run the calibration spec to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/calib_spec.lua`
Expected: PASS, `calib OK`.

- [ ] **Step 6: Rewire every elapsed-time consumer to `Elapsed()` and remove the old constant**

In `bot.lua`, replace ALL occurrences of the exact substring `Context.MatchQuants / QuantsPerSec` with `Elapsed()`. This rewrites lines 385, 391, 507, 517, 599 (`local elapsed = Elapsed()`), 1083, 1097, 1127, 1158, 1169 (`math.floor(Elapsed())`), 1259 (`Elapsed() >= OfficerUnlock`), 1281. Then delete the now-unused `local QuantsPerSec = 70` line. Verify with `grep -n "MatchQuants / QuantsPerSec" bot.lua` → no matches, and `grep -n "local QuantsPerSec" bot.lua` → no matches.

- [ ] **Step 7: Rewire the relative-interval sites to `Q(sec)`**

In `bot.lua`, make these exact edits:
- Line ~450 (group-stale): `Context.MatchQuants - g.staleSince > 3 * QuantsPerSec` → `Context.MatchQuants - g.staleSince > Q(3)`
- In `WaveIntervalNow` (~508): `local base = WaveInterval * (phase.waveMult or 1.0)` → `local base = Q(WaveIntervalSec) * (phase.waveMult or 1.0)`
- (~511): `return math.max(MinWaveInterval, math.floor(base / (1.0 + 0.25 * deficit)))` → `return math.max(Q(MinWaveIntervalSec), math.floor(base / (1.0 + 0.25 * deficit)))`
- (~614, pool gate): `or (Context.MatchQuants - failed >= FailCooldownQuants)` → `or (Context.MatchQuants - failed >= Q(FailCooldownSec))`
- (~1212): `if Context.DefenderCount >= DefenderInterval` → `if Context.DefenderCount >= Q(DefenderIntervalSec)`
- (~1227): `elseif Context.BackfillCount >= BackfillInterval then` → `elseif Context.BackfillCount >= Q(BackfillIntervalSec) then`
- (~1238): `if Context.NeutralCount >= NeutralInterval then` → `if Context.NeutralCount >= Q(NeutralIntervalSec) then`
- (~1257): `if Context.OfficerCount >= OfficerInterval then` → `if Context.OfficerCount >= Q(OfficerIntervalSec) then`
- (~1279): `if Context.AtRifleCount >= AtRifleInterval then` → `if Context.AtRifleCount >= Q(AtRifleIntervalSec) then`

Verify the old names are gone: `grep -nE "FailCooldownQuants|[^.]QuantsPerSec|[0-9]+ \* 70" bot.lua` → no matches (every `QuantsPerSec` is now `Context.QuantsPerSec`, preceded by a dot; no `* 70` literals; no `FailCooldownQuants`). And `grep -nE "Q\((Wave|MinWave|Neutral|FailCooldown|Backfill|Defender|Officer|AtRifle)" bot.lua` → shows the eight `Q(...Sec)` call sites plus `Q(3)`.

- [ ] **Step 8: Make `unlock_spec.lua` deterministic under `Elapsed()`**

In `resource/script/multiplayer/tests/unlock_spec.lua`, change the `sample` helper so time is driven through `Context.QuantsPerSec` (set to 1, so `Elapsed()` returns `MatchQuants` directly as seconds):

```lua
local function sample(seconds)
	Context.QuantsPerSec = 1
	Context.MatchQuants = seconds
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(units)
		if pick then seen[pick.unit] = true end
	end
	return seen
end
```

Update the three call sites to pass seconds, not `*70`:
```lua
local early = sample(1000)   -- before unlock 1500
...
local late = sample(1600)    -- after unlock 1500
...
local zero = sample(0)
```

- [ ] **Step 9: Run the whole Lua suite**

Run from `resource/script/multiplayer`:
```bash
for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done
```
Expected: every spec prints its `OK` line (`calib`, `unlock`, `phase`, `integration`, `frontier`, `mapname`, `partition`, `routing`, `sector`). No `attempt to call a nil value` and no `attempt to perform arithmetic on a nil value`.

- [ ] **Step 10: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.lua \
        resource/script/multiplayer/tests/calib_spec.lua \
        resource/script/multiplayer/tests/unlock_spec.lua
git commit -m "feat: runtime QPS calibration; route time through Elapsed()/Q()"
git push origin feat/timing-qps-calibration
```

---

### Task 2: Remove `armorCap`

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (pool gate 599-623)
- Modify: `resource/script/multiplayer/bot.data.lua` (`Phases` entries; `TierRank`)
- Modify: `resource/script/multiplayer/tests/integration_spec.lua`

**Interfaces:**
- Consumes: `Elapsed()` and the `unlock` gate from Task 1 / the prior phase.
- Produces: a pool gate with no tier ceiling — `affordable and unlockOk and notRecentlyFailed and phaseOk and eliteOk`.

- [ ] **Step 1: Update the integration test to exclude armor via `unlock`, not `armorCap`**

In `resource/script/multiplayer/tests/integration_spec.lua`, the EARLY test asserts a medium/heavy tank is not spawned early. With `armorCap` gone the pool no longer excludes them by tier, and `ArmorLead` would pick a tier-eligible medium with no unlock. Give the medium/heavy fixtures an `unlock` beyond the early window and pin the clock. Change the unit table (lines ~5-11) to:

```lua
local units = {
	{ class = UnitClass.Infantry,  unit = "rifle",   priority = 2.0 },
	{ class = UnitClass.Vehicle,   unit = "halftrk", priority = 1.0 },
	{ class = UnitClass.Tank,      unit = "lighttk", priority = 1.5, weight = "light" },             -- light, always available
	{ class = UnitClass.Tank,      unit = "medtk",   priority = 1.5, weight = "medium", unlock = 300 },
	{ class = UnitClass.HeavyTank, unit = "heavytk", priority = 1.0, unlock = 1500 },
}
```

Before the 200-iteration loop (line ~14), pin the clock to t=0 seconds:
```lua
Context.QuantsPerSec = 1
Context.MatchQuants = 0
```

- [ ] **Step 2: Run the integration test to verify it fails (or still passes by luck) then is correct**

Run: `cd resource/script/multiplayer && lua tests/integration_spec.lua`
Expected: PASS — at `Elapsed() = 0`, `medtk` (unlock 300) and `heavytk` (unlock 1500) are excluded by `unlockOk`, so the existing `assert(not seenEarly["medtk"])` / `assert(not seenEarly["heavytk"])` hold; `rifle`/`halftrk`/`lighttk` still spawn. (If it errors on `armorCap`/`TierRank` being absent, that is Step 3's removal — run this again after Step 3.)

- [ ] **Step 3: Remove the `armorCap` pool gate from `GetUnitToSpawn`**

In `bot.lua`, delete the `capRank` local (line 601 `local capRank = TierRank[phase.armorCap]`) and the `capOk` local (line 616 `local capOk = (tier == nil) or (TierRank[tier] <= capRank) -- aux not capped`). The `tier` local (`local tier = TierOf(unit)`) is still used by `byTier`/`tierEligible` below, so KEEP it. Change the pool conjunction (line 623) from:

```lua
		if affordable and unlockOk and notRecentlyFailed and capOk and phaseOk and eliteOk then
```
to:
```lua
		if affordable and unlockOk and notRecentlyFailed and phaseOk and eliteOk then
```

- [ ] **Step 4: Remove `armorCap` and `TierRank` from the data**

In `bot.data.lua`, delete ` armorCap = "...",` from each of the three `Phases` entries (lines 30-32) and delete the `TierRank = { ... }` table (line 36) and its preceding comment (line 35). Verify `grep -nE "armorCap|TierRank|capRank|capOk" bot.lua bot.data.lua` → no matches.

- [ ] **Step 5: Run the whole Lua suite**

Run from `resource/script/multiplayer`:
```bash
for s in tests/*_spec.lua; do echo "== $s"; lua "$s" || break; done
```
Expected: all specs print `OK`. `phase_spec` (which references `CurrentPhase`/phases) and `integration_spec` pass with armor excluded by `unlock`, not `armorCap`.

- [ ] **Step 6: Commit**

```bash
cd /home/lamho/Documents/repos/ai-spawn-improved-robz
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/bot.data.lua \
        resource/script/multiplayer/tests/integration_spec.lua
git commit -m "feat: remove armorCap tier ceiling (redundant with unlock gate)"
git push origin feat/timing-qps-calibration
```

---

## In-game verification (manual gate, after both tasks)

Run one CTF (`battle_zones`) match >~10 minutes. Confirm in the debug log:
- A calibrated rate is reached and the `t=` elapsed marker (line ~1169) now tracks real minutes (e.g. `t=` near 600 at ~10 real minutes, not ~270).
- Phase transitions occur at real ~3 min (mid) and ~8 min (late).
- The earliest in-window unlocks (`chi-ha57` 480s, `ho-ni1` 750s, `pz4h_seq` 950s) now produce spawns near their real-clock unlock times; armor appears once unlocked.
- The German under-production from the stretched wave/cooldown intervals eases (waves ~60s apart in real time, not ~130s).

If armor still fails to spawn after unlock, that is the deferred CP unit-cap (officer +40) phase, not this one.
