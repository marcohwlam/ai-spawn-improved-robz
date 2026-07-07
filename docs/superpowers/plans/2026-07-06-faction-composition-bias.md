# Faction Composition Bias Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each faction guarantee a minimum field count for specific unit categories
(tier or artillery/mortar) as a short-circuit layered on top of the existing ratio system,
without replacing or re-tuning that system.

**Architecture:** A new `FactionBias[army]` data table (7 categories: the 5 existing tiers
plus new `artillery`/`mortar`) is consulted at three existing decision points. Tier
categories short-circuit inside `DecideTier`, restricted to `tierEligible` so an unmet floor
on a not-yet-unlocked tier can never starve the rest of a phase. Artillery and mortar share a
new `TryCappedTrickle` helper (extracted from the existing ARTY trickle) where an unmet floor
bypasses the interval cooldown but never the live-count cap.

**Tech Stack:** Stock Lua 5.x, no external dependencies. Offline spec tests via the
project's bare-`assert` harness (`tests/harness.lua`), run with the system `lua`/`luac`
binaries — no test framework, no package manager.

## Global Constraints

- Every step that changes `bot.lua` or `bot.data.lua` must pass `luac -p bot.lua` /
  `luac -p bot.data.lua` (syntax check) before running any spec.
- Run the full spec suite (`for f in tests/*_spec.lua; do lua "$f"; done`) before the final
  commit of each task — a change to `bot.lua`/`bot.data.lua` has no compiler-level
  cross-checking and can silently break an unrelated spec.
- All commands below run from `resource/script/multiplayer/` (the directory containing
  `bot.lua`, `bot.data.lua`, and `tests/`).
- `DecideTier`'s existing 5-argument call sites (in `tests/phase_spec.lua`) must keep working
  unchanged — the new `bias` parameter is the 6th, optional (nil-safe) argument.
- Never touch `Context.Phases`/`Phases`/`FactionPhases` weight tables — the ratio system is
  explicitly out of scope (see the design's "Decisions" section).

---

## Task 1: `FactionBias` data table

**Files:**
- Modify: `resource/script/multiplayer/bot.data.lua` (insert after `FactionPhases`, currently
  ending at line 52, before `Purchases = {` at line 54)
- Test: `resource/script/multiplayer/tests/bias_spec.lua` (new)

**Interfaces:**
- Produces: global `FactionBias` table, `FactionBias[army][category]` (category one of
  `heavy`/`medium`/`light`/`rifle`/`smg`/`artillery`/`mortar`), used by Task 2 (`DecideTier`)
  and Task 4 (`TryCappedTrickle` callers).

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/bias_spec.lua`:

```lua
dofile((arg[0]:gsub("bias_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- FactionBias: shipped per-faction minimum-count floors, grounded in each faction's
-- real-world doctrine (see docs/superpowers/specs/2026-07-06-faction-composition-bias-design.md).
eq(FactionBias.ger.medium,      1, "ger: Blitzkrieg armor spearhead")
eq(FactionBias.ger_ss.light,    1, "ger_ss: Panzergrenadier mechanized infantry")
eq(FactionBias.ger2.rifle,      1, "ger2: Ostfront defensive infantry attrition")
eq(FactionBias.usa.artillery,   1, "usa: King of Battle")
eq(FactionBias.rus.smg,         1, "rus: PPSh assault infantry waves")
eq(FactionBias.rus_guard.heavy, 1, "rus_guard: Guards' first pick of heavy armor")
eq(FactionBias.jap.mortar,      1, "jap: infiltration doctrine, light infantry weapons")
eq(FactionBias.eng.artillery,   1, "eng: colossal cracks artillery preparation")
print("FactionBias data OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: FAIL with `attempt to index a nil value (global 'FactionBias')`

- [ ] **Step 3: Add the `FactionBias` table**

In `resource/script/multiplayer/bot.data.lua`, insert immediately after the `FactionPhases`
table's closing `}` (line 52) and before `Purchases = {` (line 54):

```lua

-- Per-faction minimum-count floor: a category short-circuits DecideTier (tier categories) or
-- TryCappedTrickle's interval cooldown (artillery/mortar) once the field's live count for that
-- category drops below this value. Categories omitted default to 0 (no floor, unchanged
-- behavior). Categories: heavy | medium | light | rifle | smg | artillery | mortar. Values are
-- grounded in each faction's real-world doctrine -- see
-- docs/superpowers/specs/2026-07-06-faction-composition-bias-design.md for the rationale
-- behind each entry.
FactionBias = {
	ger       = { medium = 1 },      -- Blitzkrieg armor spearhead
	ger_ss    = { light = 1 },       -- Panzergrenadier mechanized infantry
	ger2      = { rifle = 1 },       -- Ostfront defensive infantry attrition
	usa       = { artillery = 1 },   -- King of Battle
	rus       = { smg = 1 },         -- PPSh assault infantry waves
	rus_guard = { heavy = 1 },       -- Guards' first pick of heavy armor
	jap       = { mortar = 1 },      -- Infiltration doctrine, light infantry weapons
	eng       = { artillery = 1 },   -- Colossal cracks artillery preparation
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: PASS, prints `FactionBias data OK`

- [ ] **Step 5: Syntax check and full suite**

Run: `cd resource/script/multiplayer && luac -p bot.data.lua && luac -p bot.lua`
Expected: no output (clean syntax)

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAILED: $f"; done`
Expected: every spec prints its own OK line(s); no `FAILED:` lines.

- [ ] **Step 6: Commit**

```bash
git add resource/script/multiplayer/bot.data.lua resource/script/multiplayer/tests/bias_spec.lua
git commit -m "$(cat <<'EOF'
Add FactionBias per-faction minimum-count floor data table

Values grounded in each faction's real-world doctrine; not yet consumed
by any spawn-decision code (wired in the following tasks).
EOF
)"
```

---

## Task 2: `DecideTier` floor short-circuit

**Files:**
- Modify: `resource/script/multiplayer/bot.lua:1107-1130` (`DecideTier` function)
- Modify: `resource/script/multiplayer/bot.lua:1259` (the one call site, inside
  `GetUnitToSpawn`)
- Test: `resource/script/multiplayer/tests/bias_spec.lua` (append)

**Interfaces:**
- Consumes: `FactionBias` (Task 1).
- Produces: `DecideTier(phase, field, enemyHasTanks, tierEligible, losing, bias)` — `bias` is
  a new, optional 6th parameter (a `FactionBias[army]`-shaped table or `nil`). Existing
  5-argument callers (`tests/phase_spec.lua`) are unaffected.

- [ ] **Step 1: Write the failing tests**

Append to `resource/script/multiplayer/tests/bias_spec.lua`:

```lua

-- DecideTier: a floor-unmet, tierEligible category wins outright, bypassing the weight/
-- deficit math -- even when that math would clearly favor a different tier.
local late = CurrentPhase(480) -- heavy1/medium2/light3/rifle1/smg1
local allOk = { heavy = true, medium = true, light = true, rifle = true, smg = true }
local empty = { heavy = 0, medium = 0, light = 0, rifle = 0, smg = 0, aux = 0 }
eq(DecideTier(late, empty, false, allOk, false, { rifle = 1 }), "rifle",
	"floor-unmet rifle wins even though light has the largest weight share on an empty field")

-- Floor short-circuit ignores the enemy-tanks armor bump and the losing-smg bump: both would
-- normally favor a different tier, but the unmet floor still wins.
eq(DecideTier(late, empty, true, allOk, true, { rifle = 1 }), "rifle",
	"floor wins regardless of enemyHasTanks/losing adjustments")

-- Floor met exactly (live == floor): not "unmet" -- normal weight/deficit selection resumes.
local metFloor = { heavy = 0, medium = 0, light = 0, rifle = 1, smg = 0, aux = 0 }
eq(DecideTier(late, metFloor, false, allOk, false, { rifle = 1 }), "light",
	"floor met exactly falls through to normal selection (light still dominates)")

-- Floor set on a tier NOT in tierEligible (not unlocked yet / faction has no such tier): the
-- floor must never force an unreachable tier -- this is the starvation-prevention case (an
-- infinitely-unmet floor on an ineligible tier must not block every other tier for the rest
-- of the phase, the same failure shape as the pre-fix PruneGroups group-starvation bug).
local mediumIneligible = { heavy = true, light = true, rifle = true, smg = true } -- no medium
eq(DecideTier(late, empty, false, mediumIneligible, false, { medium = 5 }), "light",
	"floor on an ineligible tier is never selected; normal selection proceeds among eligible tiers")

-- No bias table (nil) or an empty bias table: behavior is unchanged from before this feature.
eq(DecideTier(late, empty, false, allOk), "light", "nil bias: identical to pre-feature behavior")
eq(DecideTier(late, empty, false, allOk, false, {}), "light", "empty bias table: no floors, normal selection")
print("DecideTier floor OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: FAIL on the first new assertion — `DecideTier` currently ignores its (nonexistent)
6th argument entirely, so `{ rifle = 1 }` has no effect and `light` wins instead of the
expected `rifle`.

- [ ] **Step 3: Implement the floor short-circuit**

In `resource/script/multiplayer/bot.lua`, replace the `DecideTier` function (currently lines
1107-1130):

```lua
-- Choose the tier whose share is furthest below its target, among phase-allowed tiers
-- that actually have a spawnable candidate. enemyHasTanks adds a small armor lean.
-- losing bumps the smg weight to 2. `bias` (optional, a FactionBias[army]-shaped table) is
-- checked FIRST, restricted to tierEligible: a tier whose live count is below its floor wins
-- immediately, skipping the weight/deficit math (and the enemyHasTanks/losing adjustments)
-- below. The tierEligible restriction is load-bearing: it keeps the floor from ever forcing
-- a tier that hasn't unlocked yet for this phase/faction, which would otherwise starve every
-- other tier for the rest of the phase (same failure shape as the pre-fix PruneGroups
-- group-starvation bug from the spawn-reliability work). Pure: all inputs passed in, no
-- BotApi/Context reads.
function DecideTier(phase, field, enemyHasTanks, tierEligible, losing, bias)
	if bias then
		local order = { "heavy", "medium", "light", "rifle", "smg" }
		for i = 1, #order do
			local tier = order[i]
			if tierEligible[tier] and (field[tier] or 0) < (bias[tier] or 0) then
				return tier
			end
		end
	end

	local targets = phase.targets
	local totalT = 0
	for tier, w in pairs(targets) do
		totalT = totalT + ((losing and tier == "smg") and 2 or w)
	end
	local totalF = 0
	for tier in pairs(targets) do totalF = totalF + (field[tier] or 0) end

	local best, bestDeficit = nil, -1e9
	for tier, w in pairs(targets) do
		local ew = (losing and tier == "smg") and 2 or w
		local targetShare = ew / totalT
		local actualShare = (totalF > 0) and ((field[tier] or 0) / totalF) or 0
		local deficit = targetShare - actualShare
		if enemyHasTanks and (tier == "medium" or tier == "heavy") then
			deficit = deficit + 0.15
		end
		if (tierEligible[tier]) and deficit > bestDeficit then
			best, bestDeficit = tier, deficit
		end
	end
	return best or "rifle"
end
```

- [ ] **Step 4: Wire the call site**

In `resource/script/multiplayer/bot.lua:1259`, inside `GetUnitToSpawn`, change:

```lua
	local tier = DecideTier(phase, field, enemyHasTanks, tierEligible, FlagDeficit() > 0)
```

to:

```lua
	local tier = DecideTier(phase, field, enemyHasTanks, tierEligible, FlagDeficit() > 0,
		FactionBias[BotApi.Instance.army])
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: PASS, prints `FactionBias data OK` then `DecideTier floor OK`

- [ ] **Step 6: Syntax check and full suite**

Run: `cd resource/script/multiplayer && luac -p bot.data.lua && luac -p bot.lua`
Expected: no output

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAILED: $f"; done`
Expected: every spec prints its own OK line(s); no `FAILED:` lines. `tests/phase_spec.lua`'s
existing 5-argument `DecideTier` calls must still pass unchanged.

- [ ] **Step 7: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/bias_spec.lua
git commit -m "$(cat <<'EOF'
Short-circuit DecideTier on an unmet faction composition floor

Restricted to tierEligible so a floor on a not-yet-unlocked tier can
never starve every other tier for the rest of the phase.
EOF
)"
```

---

## Task 3: Extract `TryCappedTrickle` and refactor the ARTY trickle

**Files:**
- Modify: `resource/script/multiplayer/bot.lua:1903-1918` (the ARTY `elseif` branch)
- Modify: `resource/script/multiplayer/bot.lua` (new `TryCappedTrickle` function, placed
  immediately above the idle-tick chain that currently starts at line 1884 with `else --
  Idle between waves.`)
- Test: `resource/script/multiplayer/tests/bias_spec.lua` (append)

**Interfaces:**
- Consumes: `FactionBias` (Task 1), `Elapsed()`, `SpawnSlotFree()`, `ClaimSpawnSlot()`,
  `HeldFlagCount()`, `Context.FailCooldown`, `Context.SpawnInfo`, `UpdateUnitToSpawn()`,
  `Context.Purchase` (all pre-existing).
- Produces: `TryCappedTrickle(cfg)` where `cfg` is a table with fields
  `lastTimeField` (string, a `Context` key), `interval` (number, seconds),
  `cap` (number), `liveCountFn` (function, no args, returns number),
  `unitPickerFn` (function, no args, returns a unit table or nil), `label` (string, used in
  the `[AISPAWN]` print line), `floorValue` (number or nil — a faction's floor for this
  category), `phaseGate` (function returning boolean, or nil for "always allowed"). Returns
  `true` if it attempted a spawn this tick (whether or not the attempt itself succeeded, same
  semantics the existing `elseif` chain already relies on to guarantee at most one trickle
  attempt per tick), `false` otherwise. Used by the ARTY branch (this task) and the new
  MORTAR branch (Task 4).

- [ ] **Step 1: Write the failing tests**

Append to `resource/script/multiplayer/tests/bias_spec.lua`:

```lua

-- TryCappedTrickle: floor-unmet bypasses the interval cooldown but never the cap.
local savedGerRoster = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 1.0, class = UnitClass.ArtilleryTank, unit = "testarty", unlock = 0 },
}
Context.FieldUnits = {}
Context.LastArtyTime = 0
Context.GameClock = 1 -- 1s elapsed: far under ArtyIntervalSec(45), interval alone would block
Context.PendingSpawn = nil
Context.SpawnPauseUntil = 0
BotApi.Scene.Flags = { { name = "f1", occupant = 1 } }
local spawned = nil
local savedSpawn = BotApi.Commands.Spawn
BotApi.Commands.Spawn = function(unit) spawned = unit; return true end

local acted = TryCappedTrickle({
	lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
	liveCountFn = LiveArtyCount, unitPickerFn = GetArtyUnit, label = "ARTY",
	floorValue = 1,
})
eq(acted, true, "floor-unmet bypasses the interval cooldown")
eq(spawned, "testarty", "the floor-forced attempt actually spawns the unit")

-- Cap is never bypassed, even with an unmet floor.
Context.FieldUnits = { [1] = { class = UnitClass.ArtilleryTank, unit = "testarty" },
                        [2] = { class = UnitClass.ArtilleryTank, unit = "testarty" } } -- 2 live == ArtyCap
Context.LastArtyTime = 0
Context.GameClock = 1
spawned = nil
local actedAtCap = TryCappedTrickle({
	lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
	liveCountFn = LiveArtyCount, unitPickerFn = GetArtyUnit, label = "ARTY",
	floorValue = 5, -- absurdly high, would always be "unmet"
})
eq(actedAtCap, false, "cap still blocks even when the floor is unmet")
eq(spawned, nil, "no spawn attempted once the cap is reached")

-- With no floor (nil), behavior matches the pre-refactor ARTY gate exactly: blocked by the
-- interval cooldown when it hasn't elapsed yet.
Context.FieldUnits = {}
Context.LastArtyTime = 0
Context.GameClock = 1
spawned = nil
local actedNoFloor = TryCappedTrickle({
	lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
	liveCountFn = LiveArtyCount, unitPickerFn = GetArtyUnit, label = "ARTY",
})
eq(actedNoFloor, false, "no floor: interval cooldown still blocks exactly as before")
eq(spawned, nil, "no spawn attempted")

BotApi.Commands.Spawn = savedSpawn
Purchases[1].Units["ger"] = savedGerRoster
Context.FieldUnits = {}
print("TryCappedTrickle OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: FAIL with `attempt to call a nil value (global 'TryCappedTrickle')`

- [ ] **Step 3: Implement `TryCappedTrickle` and refactor the ARTY branch**

In `resource/script/multiplayer/bot.lua`, insert the following function immediately before
the idle-tick `else` block (the one containing the DEFENDER/ARTY/backfill `elseif` chain,
currently starting at line 1884):

```lua
-- Shared "capped keep-alive trickle" pattern: attempt at most one spawn of a capped,
-- cooldown-gated unit category. An optional per-faction floor (cfg.floorValue) bypasses the
-- interval cooldown -- but never the cap -- when the category's live count is currently below
-- that floor, so a faction's guaranteed minimum is reached faster than the normal keep-alive
-- cadence would allow. Returns true if it attempted a spawn this tick (regardless of whether
-- the attempt itself succeeded), so a caller's if/elseif chain treats this the same as any
-- other trickle branch (at most one attempt per tick). Used by the ARTY and MORTAR trickles.
function TryCappedTrickle(cfg)
	local live = cfg.liveCountFn()
	local floorUnmet = live < (cfg.floorValue or 0)
	local intervalOk = Elapsed() - Context[cfg.lastTimeField] >= cfg.interval
	if not (floorUnmet or intervalOk) then return false end
	if live >= cfg.cap then return false end
	if cfg.phaseGate and not cfg.phaseGate() then return false end
	if HeldFlagCount() <= 0 then return false end
	if not SpawnSlotFree() then return false end

	Context[cfg.lastTimeField] = Elapsed()
	local unit = cfg.unitPickerFn()
	if unit then
		Context.SpawnInfo = unit
		local ok = BotApi.Commands:Spawn(unit.unit, MaxSquadSize)
		print("[AISPAWN] " .. cfg.label .. " try=" .. tostring(unit.unit) .. " ok=" .. tostring(ok))
		if ok then
			ClaimSpawnSlot({ kind = "trickle", info = unit })
		else
			Context.FailCooldown[unit.unit] = Elapsed()
		end
		UpdateUnitToSpawn(Context.Purchase)
	end
	return true
end
```

Then replace the ARTY `elseif` branch (currently lines 1903-1918):

```lua
		elseif Elapsed() - Context.LastArtyTime >= ArtyIntervalSec
		and CurrentPhase(Elapsed()).name ~= "early"
		and HeldFlagCount() > 0 and LiveArtyCount() < ArtyCap and SpawnSlotFree() then
			Context.LastArtyTime = Elapsed()
			local art = GetArtyUnit()
			if art then
				Context.SpawnInfo = art -- routed as a defender (DefenderClasses[ArtilleryTank]=true)
				local ok = BotApi.Commands:Spawn(art.unit, MaxSquadSize)
				print("[AISPAWN] ARTY try=" .. tostring(art.unit) .. " ok=" .. tostring(ok))
				if ok then
					ClaimSpawnSlot({ kind = "trickle", info = art })
				else
					Context.FailCooldown[art.unit] = Elapsed()
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
```

with:

```lua
		elseif TryCappedTrickle({
			lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
			liveCountFn = LiveArtyCount, unitPickerFn = GetArtyUnit, label = "ARTY",
			phaseGate = function() return CurrentPhase(Elapsed()).name ~= "early" end,
			floorValue = FactionBias[BotApi.Instance.army] and FactionBias[BotApi.Instance.army].artillery,
		}) then
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: PASS through `TryCappedTrickle OK`

- [ ] **Step 5: Syntax check and full suite**

Run: `cd resource/script/multiplayer && luac -p bot.data.lua && luac -p bot.lua`
Expected: no output

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAILED: $f"; done`
Expected: every spec prints its own OK line(s); no `FAILED:` lines. `tests/arty_spec.lua` in
particular must be unaffected — it tests `GetArtyUnit`/`LiveArtyCount`/`ArtilleryTargetFlag`
directly, none of which changed.

- [ ] **Step 6: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/bias_spec.lua
git commit -m "$(cat <<'EOF'
Extract TryCappedTrickle from the ARTY trickle, add floor bypass

Behavior-preserving refactor when floorValue is nil/0; a faction's
artillery floor now bypasses ArtyIntervalSec (never ArtyCap) to reach
its minimum faster than the normal keep-alive cadence.
EOF
)"
```

---

## Task 4: Mortar dedicated capped trickle

**Files:**
- Modify: `resource/script/multiplayer/bot.lua:132` (add `MortarIntervalSec`/`MortarCap`
  constants next to `ArtyIntervalSec`/`ArtyCap`)
- Modify: `resource/script/multiplayer/bot.lua:229-237` (`DefenderClasses`, add
  `UnitClass.Mortar`)
- Modify: `resource/script/multiplayer/bot.lua:37` (the module-level `Context = {...}`
  default table, add `LastMortarTime = 0` next to `LastArtyTime = 0` — this is the value
  `TryCappedTrickle` reads before `OnGameStart` ever runs, e.g. in a spec that calls it
  directly without going through `OnGameStart`)
- Modify: `resource/script/multiplayer/bot.lua:1629` (`OnGameStart`, add
  `Context.LastMortarTime = 0` next to `Context.LastArtyTime = 0`, the per-match reset)
- Modify: `resource/script/multiplayer/bot.lua` (new `LiveMortarCount`/`GetMortarUnit`
  functions, placed immediately after `LiveArtyCount`, currently ending at line 549)
- Modify: `resource/script/multiplayer/bot.lua:1196-1202` (`collectAux`'s pool filter, add a
  `UnitClass.Mortar` exclusion)
- Modify: `resource/script/multiplayer/bot.lua` (new MORTAR `elseif` branch in the idle-tick
  chain, placed immediately after the ARTY branch from Task 3)
- Test: `resource/script/multiplayer/tests/bias_spec.lua` (append)

**Interfaces:**
- Consumes: `TryCappedTrickle` (Task 3), `FactionBias` (Task 1), `UnitClass.Mortar`
  (pre-existing in `bot.data.lua`).
- Produces: `LiveMortarCount()` (no args, returns number), `GetMortarUnit()` (no args,
  returns a unit table or nil).

- [ ] **Step 1: Write the failing tests**

Append to `resource/script/multiplayer/tests/bias_spec.lua`:

```lua

-- LiveMortarCount counts only Mortar-class FieldUnits entries.
Context.FieldUnits = {
	[1] = { class = UnitClass.Mortar, unit = "testmortar1" },
	[2] = { class = UnitClass.MG,     unit = "mgs2(ger)" },
	[3] = { class = UnitClass.Mortar, unit = "testmortar2" },
}
eq(LiveMortarCount(), 2, "LiveMortarCount counts only Mortar-class entries")
Context.FieldUnits = {}

-- GetMortarUnit mirrors GetArtyUnit: unlock-aware, excludes already-fielded subtypes.
local savedGerRoster2 = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 0.8, class = UnitClass.Mortar, unit = "mortarA", unlock = 300 },
	{ priority = 0.5, class = UnitClass.Mortar, unit = "mortarB", unlock = 600 },
}
Context.GameClock = 0
eq(GetMortarUnit(), nil, "GetMortarUnit nil before any subtype unlocks")
Context.GameClock = 300
eq(GetMortarUnit().unit, "mortarA", "GetMortarUnit only offers the unlocked subtype")
Context.GameClock = 600
Context.FieldUnits = { [1] = { class = UnitClass.Mortar, unit = "mortarA" } }
eq(GetMortarUnit().unit, "mortarB", "already-fielded subtype excluded once the other unlocks")
Context.FieldUnits = {}
Purchases[1].Units["ger"] = savedGerRoster2
print("LiveMortarCount / GetMortarUnit OK")

-- Mortars are pulled out of the generic aux batch pool into their own dedicated trickle;
-- GetUnitToSpawn's aux path must never offer one, even when it is otherwise the only other
-- aux candidate competing for an owed aux slot.
local auxUnits = {
	{ class = UnitClass.Sniper, unit = "snipertest", priority = 1.0 },
	{ class = UnitClass.Mortar, unit = "mortartest", priority = 1.0 },
}
Context.GameClock = 0
Context.Groups = {}
Context.FillGroup = nil
Context.FieldUnits = {}
Context.AuxOwed = 5
local auxPicks = {}
for i = 1, 30 do
	local pick = GetUnitToSpawn(auxUnits)
	if pick then auxPicks[pick.unit] = true end
end
eq(auxPicks["mortartest"], nil, "Mortar-class unit never wins the generic aux batch")
eq(auxPicks["snipertest"], true, "sniper remains aux-eligible")
Context.AuxOwed = 0
print("Mortar excluded from generic aux pool OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: FAIL with `attempt to call a nil value (global 'LiveMortarCount')`

- [ ] **Step 3: Add the Mortar constants**

In `resource/script/multiplayer/bot.lua`, immediately after the `ArtyCap` line (currently
line 132):

```lua
ArtyCap          = 2       -- max live artillery pieces the bot keeps fielded
-- Hand-carried mortar keep-alive, mirroring the artillery pattern above: its own cap+interval
-- pair, independent of the generic aux batch (which would otherwise let it compete with
-- AT/MG/sniper/officer/AA for a fixed AuxPerCycle=2 slot -- see the collectAux exclusion).
MortarIntervalSec = 45     -- seconds between mortar trickle checks
MortarCap         = 2      -- max live hand-carried mortars the bot keeps fielded
```

Note: `ArtyIntervalSec`/`ArtyCap` were already promoted from `local` to global in Task 3 (a
necessary deviation discovered there — `bot.lua` is loaded via `dofile` inside
`tests/harness.lua`, and Lua file-locals in a `dofile`d chunk are invisible to code outside
that chunk, e.g. a spec file that references the name directly). `MortarIntervalSec`/
`MortarCap` are declared global from the start here for the same reason: Task 5's test
references `MortarCap` by name directly from `tests/bias_spec.lua`.

- [ ] **Step 3b: Add `LastMortarTime` to the module-level `Context` default table**

In `resource/script/multiplayer/bot.lua`, immediately after `LastArtyTime = 0,` in the
module-level `Context = {...}` table (currently line 37):

```lua
	LastArtyTime = 0,     -- Elapsed() at last artillery defender trickle
	LastMortarTime = 0,   -- Elapsed() at last mortar keep-alive trickle
```

- [ ] **Step 4: Add Mortar to `DefenderClasses`**

In `resource/script/multiplayer/bot.lua`, in the `DefenderClasses` table (currently lines
229-237), add:

```lua
local DefenderClasses = {
	[UnitClass.ATInfantry]    = true,  -- AT teams anchor the line
	[UnitClass.ATTank]        = true,  -- tank destroyers overwatch
	[UnitClass.AATank]        = true,  -- AA covers the rear
	[UnitClass.ArtilleryTank] = true,  -- SPGs sit back
	[UnitClass.Sniper]        = true,
	[UnitClass.Officer]       = true,
	[UnitClass.MG]            = true,  -- MG teams dig in on owned flags
	[UnitClass.Mortar]        = true,  -- mortars sit back on owned flags, same as MG
}
```

- [ ] **Step 5: Add `Context.LastMortarTime` to `OnGameStart`**

In `resource/script/multiplayer/bot.lua`, immediately after `Context.LastArtyTime = 0`
(currently line 1629):

```lua
	Context.LastArtyTime = 0
	Context.LastMortarTime = 0
```

- [ ] **Step 6: Add `LiveMortarCount` and `GetMortarUnit`**

In `resource/script/multiplayer/bot.lua`, immediately after the `LiveArtyCount` function
(currently ending at line 549, right before the `GetAirborneUnit` comment):

```lua
-- Live hand-carried mortars we have fielded (the mortar keep-alive cap).
function LiveMortarCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.Mortar then n = n + 1 end
	end
	return n
end

-- A hand-carried mortar from the current faction roster, drawn by priority, or nil. Mirrors
-- GetArtyUnit: filters out subtypes not yet unlocked and any subtype already fielded live, so
-- with MortarCap > 1 the extra slot goes toward variety instead of a duplicate.
function GetMortarUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local elapsed = Elapsed()
	local live = {}
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.Mortar then live[entry.unit] = true end
	end
	local mortars = {}
	for i, t in pairs(roster) do
		if t.class == UnitClass.Mortar
		and (t.unlock == nil or elapsed >= t.unlock)
		and not live[t.unit] then
			table.insert(mortars, t)
		end
	end
	if #mortars == 0 then return nil end
	return GetRandomItem(mortars, function(t) return t.priority end)
end
```

- [ ] **Step 7: Exclude Mortar from the generic aux pool**

In `resource/script/multiplayer/bot.lua`, inside `GetUnitToSpawn`'s `collectAux` closure
(currently lines 1195-1206), change:

```lua
		for i, t in pairs(pool) do
			if TierOf(t) == nil and AuxEligible(t, enemyHasTanks) then
				if t.class ~= UnitClass.Airborne         -- airborne ONLY via the deep-strike trickle (late + losing gate)
				and not (t.class == UnitClass.Rare and Context.SpawnFlags.isRare)
				and t.class ~= UnitClass.Howitzrer
				and t.class ~= UnitClass.ArtilleryTank   -- SPGs disabled (poor bot AI use)
				and t.class ~= UnitClass.Officer         -- officers are parked by their own trickle
				and not (t.class == UnitClass.Vehicle and t.support) then -- support vehicles: own keep-alive trickle
					table.insert(out, t)
				end
			end
		end
```

to:

```lua
		for i, t in pairs(pool) do
			if TierOf(t) == nil and AuxEligible(t, enemyHasTanks) then
				if t.class ~= UnitClass.Airborne         -- airborne ONLY via the deep-strike trickle (late + losing gate)
				and not (t.class == UnitClass.Rare and Context.SpawnFlags.isRare)
				and t.class ~= UnitClass.Howitzrer
				and t.class ~= UnitClass.ArtilleryTank   -- SPGs disabled (poor bot AI use)
				and t.class ~= UnitClass.Officer         -- officers are parked by their own trickle
				and t.class ~= UnitClass.Mortar          -- mortars: own dedicated trickle (see TryCappedTrickle)
				and not (t.class == UnitClass.Vehicle and t.support) then -- support vehicles: own keep-alive trickle
					table.insert(out, t)
				end
			end
		end
```

- [ ] **Step 8: Add the MORTAR trickle branch**

In `resource/script/multiplayer/bot.lua`, immediately after the ARTY `elseif` branch's
closing `end` (the one introduced in Task 3, right before the `elseif Elapsed() -
Context.LastWaveTime >= BackfillQuietSec` branch), insert:

```lua
		elseif TryCappedTrickle({
			lastTimeField = "LastMortarTime", interval = MortarIntervalSec, cap = MortarCap,
			liveCountFn = LiveMortarCount, unitPickerFn = GetMortarUnit, label = "MORTAR",
			floorValue = FactionBias[BotApi.Instance.army] and FactionBias[BotApi.Instance.army].mortar,
		}) then
```

- [ ] **Step 9: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: PASS through `Mortar excluded from generic aux pool OK`

- [ ] **Step 10: Syntax check and full suite**

Run: `cd resource/script/multiplayer && luac -p bot.data.lua && luac -p bot.lua`
Expected: no output

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAILED: $f"; done`
Expected: every spec prints its own OK line(s); no `FAILED:` lines.

- [ ] **Step 11: Verify the unit roster checker still passes**

`FactionBias`/the new functions introduce no new `unit=` ids, but bot.data.lua changed, so
re-run the roster checker as a safety net:

Run: `cd tools && python3 check_unit_roster.py <gamelogic.pak path> ../resource/script/multiplayer/bot.data.lua`
(use the same `gamelogic.pak` path documented in `CLAUDE.md`/prior roster-check runs)
Expected: exits 0, no `NOT_FOUND`/`MISMATCH` lines.

- [ ] **Step 12: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/bias_spec.lua
git commit -m "$(cat <<'EOF'
Add a dedicated mortar keep-alive trickle, pulled out of the aux pool

Mortars previously competed with AT/MG/sniper/officer/AA for a fixed
AuxPerCycle=2 slot with no tracking or guarantee. They now share
TryCappedTrickle with artillery (own cap+interval, floor-bypassable).
EOF
)"
```

---

## Task 5: `ValidateFactionBias` self-test

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (new `ValidateFactionBias` function, placed
  immediately after the `FactionBias`-consuming code is complete — anywhere after Task 4's
  `MortarCap` definition; suggested location: immediately after `GetMortarUnit`)
- Test: `resource/script/multiplayer/tests/bias_spec.lua` (append)

**Interfaces:**
- Consumes: `FactionBias` (Task 1), `ArtyCap` (pre-existing), `MortarCap` (Task 4).
- Produces: `ValidateFactionBias()` (no args, returns an array of violation strings; empty
  array means every faction's data is consistent). Dev-time only — never called from
  `OnGameStart` or any runtime path, only from the test suite, so a bad data edit fails a
  spec run rather than crashing a live match.

- [ ] **Step 1: Write the failing test**

Append to `resource/script/multiplayer/tests/bias_spec.lua`:

```lua

-- ValidateFactionBias: a faction's artillery/mortar floor must never exceed that category's
-- cap (a floor above the cap could never be satisfied and would spin TryCappedTrickle's
-- floor-bypass forever without ever completing).
local savedBias = FactionBias
FactionBias = { ger = { artillery = ArtyCap + 1 } }
eq(#ValidateFactionBias(), 1, "one violation for a floor above its cap")
FactionBias = { ger = { artillery = ArtyCap } }
eq(#ValidateFactionBias(), 0, "floor exactly at the cap is not a violation")
FactionBias = { ger = { mortar = MortarCap + 1 } }
eq(#ValidateFactionBias(), 1, "one violation for a mortar floor above MortarCap")
FactionBias = savedBias
local shipped = ValidateFactionBias()
eq(#shipped, 0, "shipped FactionBias data has no floor exceeding its cap: "
	.. table.concat(shipped, "; "))
print("ValidateFactionBias OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: FAIL with `attempt to call a nil value (global 'ValidateFactionBias')`

- [ ] **Step 3: Implement `ValidateFactionBias`**

In `resource/script/multiplayer/bot.lua`, immediately after `GetMortarUnit` (added in Task 4):

```lua
-- Dev-time self-check: a faction's artillery/mortar floor must never exceed that category's
-- cap (ArtyCap/MortarCap) -- a floor above the cap could never be satisfied and would spin
-- TryCappedTrickle's floor-bypass forever. Not wired into OnGameStart (a shipped data mistake
-- should not crash the mod at match start); run from the test suite instead, same as
-- tools/check_unit_roster.py's roster-correctness checks. Pure. Returns a list of violation
-- strings; empty means every faction's data is consistent.
function ValidateFactionBias()
	local violations = {}
	local caps = { artillery = ArtyCap, mortar = MortarCap }
	for army, bias in pairs(FactionBias or {}) do
		for cat, cap in pairs(caps) do
			local floor = bias[cat]
			if floor and floor > cap then
				table.insert(violations, army .. "." .. cat .. ": floor " .. tostring(floor)
					.. " exceeds cap " .. tostring(cap))
			end
		end
	end
	return violations
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/bias_spec.lua`
Expected: PASS, all `bias_spec.lua` sections print their OK lines, ending with
`ValidateFactionBias OK`

- [ ] **Step 5: Syntax check and full suite**

Run: `cd resource/script/multiplayer && luac -p bot.data.lua && luac -p bot.lua`
Expected: no output

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAILED: $f"; done`
Expected: every spec prints its own OK line(s); no `FAILED:` lines.

- [ ] **Step 6: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/bias_spec.lua
git commit -m "$(cat <<'EOF'
Add ValidateFactionBias dev-time self-check

Catches a faction's artillery/mortar floor exceeding its live-count
cap, which would otherwise be an un-satisfiable, silently-broken
guarantee. Run only from the test suite, never at match start.
EOF
)"
```

---

## Task 6: Final full-suite regression and doc cross-check

**Files:**
- No source changes expected. Verification-only task.

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: nothing new — this task's deliverable is a verified-green repository state.

- [ ] **Step 1: Full spec suite**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAILED: $f"; done`
Expected: every spec prints its own OK line(s); no `FAILED:` lines. In particular confirm by
name: `bias_spec.lua`, `phase_spec.lua`, `arty_spec.lua`, `group_spec.lua`,
`spawnlock_spec.lua`, `heavy_fail_pause_spec.lua`, `integration_spec.lua`.

- [ ] **Step 2: Syntax check both runtime files**

Run: `cd resource/script/multiplayer && luac -p bot.lua && luac -p bot.data.lua`
Expected: no output.

- [ ] **Step 3: Confirm README/ARCHITECTURE cross-references still match reality**

Run: `grep -n "faction-composition-bias" /home/lamho/Documents/repos/ai-spawn-improved-robz/README.md /home/lamho/Documents/repos/ai-spawn-improved-robz/ARCHITECTURE.md`
Expected: one match in each file (added during brainstorming, before this plan existed).
Update the `README.md` bullet's `*(designed, not yet implemented — ...)*` qualifier to drop
"not yet implemented" now that Tasks 1-5 are done, and update the `ARCHITECTURE.md` "Known
gaps" entry to move this line out of the gaps list (it is no longer a gap) into subsystem
section 1 (`## Subsystems` / `### 1. Phase / tier / wave (spawn economy)`), one sentence
noting `FactionBias` and pointing at the design doc.

- [ ] **Step 4: Commit the doc updates**

```bash
git add README.md ARCHITECTURE.md
git commit -m "$(cat <<'EOF'
Mark faction composition bias as implemented in README/ARCHITECTURE

Tasks 1-5 of the implementation plan are complete and green; move the
cross-reference out of ARCHITECTURE's Known gaps into the spawn-economy
subsystem section.
EOF
)"
```

- [ ] **Step 5: In-game verification (manual gate, not automatable)**

Per the design's Testing section: run one match per biased faction (at minimum `ger` for the
tier-floor path and one of `usa`/`eng`/`jap` for the artillery/mortar-floor path), and confirm
via `game.log`:
- The biased category reaches its floor faster than an unbiased baseline category of similar
  unlock cost.
- `[AISPAWN] ARTY`/`[AISPAWN] MORTAR` lines appear and `LiveArtyCount`/`LiveMortarCount` never
  exceed `ArtyCap`/`MortarCap`.
- No new `SPAWN_LOST` or `stale_pending` regressions versus a baseline match without this
  feature (cross-check against the diagnostics added in the earlier spawn-reliability work
  this session).

This step has no pass/fail command — record the observation in a follow-up roadmap note if
anything looks off, per this repo's existing "deploy → observe game.log → diagnose" loop
(see `CLAUDE.md`'s "Manual in-game verification" section).
