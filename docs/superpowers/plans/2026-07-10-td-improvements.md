# TD Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the `retire` field to tank destroyers so obsolete open-top/gun-superseded TDs fade out, and make TDs escort the main assault group instead of overwatching rear flags.

**Architecture:** Two independent behavior changes on `bot.lua` / `bot.data.lua`, one per task/commit. Feature 1 adds a `retire` upper bound to the `GetAtTankUnit` trickle picker plus `retire` data on 5 TDs. Feature 2 extends `TryCappedTrickle` with optional group-escort attachment and points the `ATTANK` trickle at the main group.

**Tech Stack:** Lua 5.x mod, offline test harness (`tests/harness.lua`), run each spec with `lua tests/<name>_spec.lua` from `resource/script/multiplayer`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-td-gun-retire-design.md`. Every requirement below traces to it.
- Feature 1 retire dataset (exact seconds), aligned to each successor's `unlock`:
  - `marder_3m` retire=880, `marder_3m_ss` retire=830, `su76` retire=1170, `su76_guard` retire=1170, `m10wolverine_eng` retire=1500.
- Do NOT add `retire` to any other TD. usa (m18/m10wolverine), ger2, jap TDs, and all armored/heavy TDs keep their current no-`retire` behavior.
- Feature 2: the `ATTANK` trickle attaches to the MAIN group only (`groupSlot = 1, aux = true`). Do NOT touch the sub group.
- Feature 2: a group-escort trickle must NOT spawn (and must NOT stamp its `lastTimeField`) when the target group does not exist.
- Feature 2: do NOT change `AtTankCap`, `AtTankIntervalSec`, the `enemyHasTanks` phaseGate, or the attank FactionBias floor.
- Every other `TryCappedTrickle` caller (ARTY, MORTAR, SNIPER) must keep claiming `kind="trickle"` unchanged (no `groupSlot` in their configs).
- Tests: bare `assert` / a local `eq` helper, end each spec with `print("... OK")`, mirror the existing `retire_spec.lua` and `bias_spec.lua` patterns. All 22 existing specs plus the 2 new ones must pass.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Task 1: TD retirement (Feature 1)

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`GetAtTankUnit`, ~line 645)
- Modify: `resource/script/multiplayer/bot.data.lua` (5 TD rows + schema comment ~line 140)
- Test: `resource/script/multiplayer/tests/td_retire_spec.lua` (new)
- Modify: `ARCHITECTURE.md`

**Interfaces:**
- Consumes: `GetAtTankUnit()` (roster ATTank picker, unlock-gated), `Elapsed()`, `UnitClass.ATTank`, `Purchases[1].Units[army]`, `Context.FieldUnits`.
- Produces: `GetAtTankUnit` now also drops a candidate once `elapsed >= t.retire`. No new public symbol.

- [ ] **Step 1: Write the failing test** — `resource/script/multiplayer/tests/td_retire_spec.lua`

```lua
dofile((arg[0]:gsub("td_retire_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- GetAtTankUnit must honor `retire` symmetrically to `unlock`: a TD is a candidate only
-- while unlock <= elapsed < retire.
local saved = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = {
	{ priority = 1.0, class = UnitClass.ATTank, unit = "td_perm",     unlock = 0 },              -- no retire
	{ priority = 1.0, class = UnitClass.ATTank, unit = "td_retiring", unlock = 0, retire = 1000 },
}
BotApi.Instance.army = "ger"
Context.FieldUnits = {}

-- One second before retire: both are reachable.
Context.GameClock = 999
local before = {}
for i = 1, 200 do before[GetAtTankUnit().unit] = true end
eq(before["td_perm"], true, "no-retire TD offered before boundary")
eq(before["td_retiring"], true, "retiring TD still offered one second before retire")

-- At the retire boundary: retiring TD gone, only the permanent one remains.
Context.GameClock = 1000
local at = {}
for i = 1, 200 do at[GetAtTankUnit().unit] = true end
eq(at["td_perm"], true, "no-retire TD still offered at boundary")
eq(at["td_retiring"], nil, "retiring TD must NOT be offered at its retire time")

-- Retiring the only remaining TD yields nil (no candidates).
Purchases[1].Units["ger"] = {
	{ priority = 1.0, class = UnitClass.ATTank, unit = "solo", unlock = 0, retire = 500 },
}
Context.GameClock = 500
eq(GetAtTankUnit(), nil, "GetAtTankUnit nil when every ATTank is retired")

Purchases[1].Units["ger"] = saved
print("td retire OK")
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd resource/script/multiplayer && lua tests/td_retire_spec.lua`
Expected: FAIL on the boundary assertion (`retiring TD must NOT be offered`) because `GetAtTankUnit` ignores `retire`.

- [ ] **Step 3: Add the `retire` gate to `GetAtTankUnit`**

In `resource/script/multiplayer/bot.lua`, the loop currently reads:

```lua
	for i, t in pairs(roster) do
		if t.class == UnitClass.ATTank
		and (t.unlock == nil or elapsed >= t.unlock)
		and not live[t.unit] then
			table.insert(attanks, t)
		end
	end
```

Add the symmetric `retire` upper bound:

```lua
	for i, t in pairs(roster) do
		if t.class == UnitClass.ATTank
		and (t.unlock == nil or elapsed >= t.unlock)
		and (t.retire == nil or elapsed <  t.retire)   -- obsolete-chassis fade-out (see bot.data.lua)
		and not live[t.unit] then
			table.insert(attanks, t)
		end
	end
```

- [ ] **Step 4: Add `retire` to the 5 obsolete TD rows in `bot.data.lua`**

Append `retire=<sec>,` to each row (keep every other field byte-identical):

- Line ~184 `m10wolverine_eng`: add `retire=1500,`
- Line ~244 `marder_3m`: add `retire=880,`
- Line ~322 `marder_3m_ss`: add `retire=830,`
- Line ~413 `su76`: add `retire=1170,`
- Line ~532 `su76_guard`: add `retire=1170,`

Example (marder_3m):

```lua
				{priority=1.5, class=UnitClass.ATTank,        unit="marder_3m",            min_income=1.5, unlock=750, retire=880,},
```

- [ ] **Step 5: Extend the `retire` schema comment** (`bot.data.lua` ~line 142)

The comment currently ends "Only weight=\"medium\" weak-gun tanks carry `retire` ...". Replace that sentence so it also covers TDs:

```lua
	-- `retire` = elapsed seconds at which a unit drops from the pool (obsolete gun). Both are
	-- optional; omit for units that are eligible for the whole match. weight="medium" weak-gun
	-- tanks and open-top / gun-superseded tank destroyers (UnitClass.ATTank) carry `retire`:
	-- the tanks otherwise keep diluting the medium-armor pick share, and the TDs keep getting
	-- trickled onto the field long after their armored, better-gunned successor unlocked.
```

- [ ] **Step 6: Run the new test and the full suite**

Run: `cd resource/script/multiplayer && lua tests/td_retire_spec.lua && for f in tests/*_spec.lua; do lua "$f" >/dev/null 2>&1 && echo "PASS $f" || echo "FAIL $f"; done`
Expected: `td retire OK`, then 23 PASS lines, 0 FAIL.

- [ ] **Step 7: Document in `ARCHITECTURE.md`**

Add a short note where the tank `retire` feature is documented: the `retire` field now also gates `GetAtTankUnit` (the ATTank trickle picker), retiring open-top / gun-superseded TDs (`marder_3m`, `marder_3m_ss`, `su76`, `su76_guard`, `m10wolverine_eng`) when their armored / better-gunned successor unlocks. Match the surrounding prose style; no em dashes; two sentences is enough.

- [ ] **Step 8: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/bot.data.lua \
  resource/script/multiplayer/tests/td_retire_spec.lua ARCHITECTURE.md
git commit -m "Retire obsolete tank destroyers by chassis/gun obsolescence

Extend the retire field to the GetAtTankUnit trickle picker and tag the
open-top marders / su76 and the gun-superseded m10wolverine_eng so they
fade out when their armored, better-gunned successor unlocks.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: TD follows the main group (Feature 2)

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`TryCappedTrickle` ~line 2080; `ATTANK` config ~line 2213; `DefenderClasses` ~line 267)
- Test: `resource/script/multiplayer/tests/td_follow_group_spec.lua` (new)
- Modify: `ARCHITECTURE.md`

**Interfaces:**
- Consumes: `TryCappedTrickle(cfg)`, `ClaimSpawnSlot(descriptor)` (sets `Context.PendingSpawn = descriptor`), `Context.Groups`, `Context.PendingSpawn`, `HeldFlagCount()`, `SpawnSlotFree()`.
- Produces: `TryCappedTrickle` accepts optional `cfg.groupSlot` (integer) and `cfg.aux` (bool). With `groupSlot` set it (a) returns `false` without stamping `lastTimeField` when `Context.Groups[groupSlot]` is absent, and (b) on a successful spawn claims `{ kind = "group", slot = groupSlot, aux = (cfg.aux == true) }` instead of `{ kind = "trickle" }`. Behavior with no `groupSlot` is unchanged.

- [ ] **Step 1: Write the failing test** — `resource/script/multiplayer/tests/td_follow_group_spec.lua`

```lua
dofile((arg[0]:gsub("td_follow_group_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- Drive TryCappedTrickle directly. Neutralize every gate except the group-existence check:
--  * liveCountFn = 0 and cap = 99  -> under cap
--  * floorValue = 0                -> floor met (relies on intervalOk instead)
--  * lastTimeField reset to 0 with a large clock -> intervalOk true
--  * one captured flag             -> HeldFlagCount() > 0
--  * PendingSpawn nil              -> SpawnSlotFree() true
local stubUnit = { class = UnitClass.ATTank, unit = "stub_td" }
local function baseCfg(extra)
	local cfg = {
		lastTimeField = "LastAtTankTime", interval = 1, cap = 99,
		liveCountFn = function() return 0 end,
		unitPickerFn = function() return stubUnit end,
		label = "ATTANK", floorValue = 0,
	}
	for k, v in pairs(extra or {}) do cfg[k] = v end
	return cfg
end
local function reset()
	Context.PendingSpawn = nil
	Context.LastAtTankTime = 0
	Context.GameClock = 1000
	BotApi.Scene.Flags = { { occupant = BotApi.Instance.team } }  -- one held flag
end

-- (A) No groupSlot: legacy path still claims kind="trickle".
reset()
Context.Groups = {}
local firedA = TryCappedTrickle(baseCfg())
eq(firedA, true, "trickle fires when gates pass")
eq(Context.PendingSpawn.kind, "trickle", "no groupSlot -> kind trickle (regression)")

-- (B) groupSlot set but the group is absent: does NOT fire and does NOT stamp lastTimeField.
reset()
Context.Groups = {}                                   -- no main group
local firedB = TryCappedTrickle(baseCfg({ groupSlot = 1, aux = true }))
eq(firedB, false, "escort trickle skips when its group is absent")
eq(Context.LastAtTankTime, 0, "skipped escort must NOT consume the interval")
eq(Context.PendingSpawn, nil, "skipped escort claims no slot")

-- (C) groupSlot set and the group exists: claims kind="group", slot=1, aux=true.
reset()
Context.Groups = { [1] = { members = {}, auxMembers = {}, target = "f1" } }
local firedC = TryCappedTrickle(baseCfg({ groupSlot = 1, aux = true }))
eq(firedC, true, "escort trickle fires when its group exists")
eq(Context.PendingSpawn.kind, "group", "escort claims a group slot")
eq(Context.PendingSpawn.slot, 1, "escort attaches to the main group")
eq(Context.PendingSpawn.aux, true, "escort is an aux member")

-- (D) ATTank is no longer a defender class (it now follows the group).
eq(DefenderClasses[UnitClass.ATTank], nil, "ATTank removed from DefenderClasses")
eq(DefenderClasses[UnitClass.MG], true, "MG stays a defender")

Context.Groups = {}
print("td follow group OK")
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd resource/script/multiplayer && lua tests/td_follow_group_spec.lua`
Expected: FAIL — `TryCappedTrickle` has no `groupSlot` handling, so case (B)/(C) behave wrong and `DefenderClasses[UnitClass.ATTank]` is still `true`.

- [ ] **Step 3: Extend `TryCappedTrickle`** (`bot.lua` ~line 2080)

Add the group-existence guard before the `lastTimeField` stamp, and branch the claim on `cfg.groupSlot`:

```lua
function TryCappedTrickle(cfg)
	local live = cfg.liveCountFn()
	local floorUnmet = live < (cfg.floorValue or 0)
	local intervalOk = Elapsed() - Context[cfg.lastTimeField] >= cfg.interval * IntervalMult()
	if not (floorUnmet or intervalOk) then return false end
	if live >= cfg.cap then return false end
	if cfg.phaseGate and not cfg.phaseGate() then return false end
	if HeldFlagCount() <= 0 then return false end
	if not SpawnSlotFree() then return false end
	-- An escort trickle rides a group and follows its target; if that group does not exist
	-- yet, skip WITHOUT stamping lastTimeField so it fires promptly once the group forms.
	if cfg.groupSlot and not Context.Groups[cfg.groupSlot] then return false end

	Context[cfg.lastTimeField] = Elapsed()
	local unit = cfg.unitPickerFn()
	if not unit then return false end
	Context.SpawnInfo = unit
	local ok = BotApi.Commands:Spawn(unit.unit, MaxSquadSize)
	print("[AISPAWN] " .. cfg.label .. " try=" .. tostring(unit.unit) .. " ok=" .. tostring(ok))
	if ok then
		if cfg.groupSlot then
			ClaimSpawnSlot({ kind = "group", info = unit, slot = cfg.groupSlot, aux = cfg.aux == true })
		else
			ClaimSpawnSlot({ kind = "trickle", info = unit })
		end
	else
		Context.FailCooldown[unit.unit] = Elapsed()
	end
	UpdateUnitToSpawn(Context.Purchase)
	return true
end
```

- [ ] **Step 4: Point the `ATTANK` trickle at the main group** (`bot.lua` ~line 2213)

Add `groupSlot = 1, aux = true` to the ATTANK config (leave ARTY/MORTAR/SNIPER configs untouched):

```lua
		elseif TryCappedTrickle({
			lastTimeField = "LastAtTankTime", interval = AtTankIntervalSec, cap = AtTankCap,
			liveCountFn = LiveAtTankCount, unitPickerFn = GetAtTankUnit, label = "ATTANK",
			phaseGate = function() return BotApi.Commands:EnemyHasTanks() end,
			floorValue = BiasFloor(FactionBias[BotApi.Instance.army], "attank", CurrentPhase(Elapsed()).name),
			groupSlot = 1, aux = true,   -- escort the main group and follow its target
		}) then
```

- [ ] **Step 5: Remove `ATTank` from `DefenderClasses`** (`bot.lua` ~line 269)

Delete the line:

```lua
	[UnitClass.ATTank]        = true,  -- tank destroyers overwatch
```

(Leave `ATInfantry`, `AATank`, `ArtilleryTank`, `Sniper` in place.) A grouped TD routes by membership; removing this only changes the orphan case to a forward push instead of a rear hold.

- [ ] **Step 6: Run the new test and the full suite**

Run: `cd resource/script/multiplayer && lua tests/td_follow_group_spec.lua && for f in tests/*_spec.lua; do lua "$f" >/dev/null 2>&1 && echo "PASS $f" || echo "FAIL $f"; done`
Expected: `td follow group OK`, then 24 PASS lines, 0 FAIL. Pay attention to `bias_spec.lua` (it exercises `GetAtTankUnit` / `LiveAtTankCount`) and `group_spec.lua` — both must still pass.

- [ ] **Step 7: Document in `ARCHITECTURE.md`**

Add a note: `TryCappedTrickle` now takes optional `groupSlot`/`aux`; the ATTANK trickle uses `groupSlot=1, aux=true` so tank destroyers escort the main group and follow its target (via the `kind="group"` landing path in `OnGameSpawn`) instead of holding a rear flag as a defender. Note that `ATTank` was removed from `DefenderClasses` accordingly. Match surrounding style; no em dashes.

- [ ] **Step 8: Commit**

```bash
git add resource/script/multiplayer/bot.lua \
  resource/script/multiplayer/tests/td_follow_group_spec.lua ARCHITECTURE.md
git commit -m "Tank destroyers escort the main group instead of overwatching

Add optional groupSlot/aux to TryCappedTrickle and route the ATTANK
trickle to the main group as an aux escort, so TDs follow the assault
target. Remove ATTank from DefenderClasses; the escort only spawns once
the main group exists.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- Spec coverage: Feature 1 (retire gate + 5-row dataset + schema comment) -> Task 1. Feature 2 (TryCappedTrickle groupSlot/aux + ATTANK config + DefenderClasses removal) -> Task 2. Both testing sections mapped to the two new specs. Covered.
- Placeholder scan: none; every code and test block is complete.
- Type consistency: `groupSlot`/`aux` field names match between `TryCappedTrickle`, the ATTANK config, and the `td_follow_group_spec` assertions; `retire` matches `GetAtTankUnit` and the data rows. `Context.PendingSpawn` descriptor keys (`kind`/`slot`/`aux`) match `ClaimSpawnSlot` and `OnGameSpawn`.
