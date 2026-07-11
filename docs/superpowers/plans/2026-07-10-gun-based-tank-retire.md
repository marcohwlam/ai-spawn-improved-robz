# Gun-Based Tank Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire obsolete `weight="medium"` tanks from the spawn pool via a new time-based `retire` field, so weak-gunned early tanks stop diluting the medium-armor pick share late in the match.

**Architecture:** Add one optional `retire` field (seconds of elapsed match time) to unit entries, symmetric to the existing `unlock` field. A single line in the `GetUnitToSpawn` pool-eligibility filter drops a unit once `elapsed >= retire`. Apply the field to 11 verified weak-gun medium tanks across the German, US, British, and Soviet factions. Update ARCHITECTURE.md and README.md to document the new field.

**Tech Stack:** Lua 5.x. Offline test harness (`tests/harness.lua`), bare-`assert`-with-`print("... OK")` specs, no external framework.

## Global Constraints

- Run `luac -p bot.lua && luac -p bot.data.lua` (syntax check) before running specs.
- Run the whole suite before every commit that touches `bot.lua`/`bot.data.lua`:
  `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
- Specs are run from the `resource/script/multiplayer` directory: `lua tests/<name>_spec.lua`.
- `retire` semantics: a unit is eligible while `elapsed < retire`; it drops from the pool at `elapsed == retire`. Units with no `retire` field are never dropped (backward compatible).
- Only `weight="medium"` units get a `retire` value. Light-tier and HE/flame/heavy units are out of scope.
- Retire values (verified against `entity.pak` def ammo tables and the design spec):

  | unit | retire | faction |
  |---|---|---|
  | pz3_m | 950 | ger |
  | pz3n | 1300 | ger |
  | pz3_m_ss | 830 | ger_ss |
  | pz3n_ss | 1300 | ger_ss |
  | pz3_ger2 | 830 | ger2 |
  | t34_2_ger | 1750 | ger2 |
  | m4a3_75_seq | 1120 | usa |
  | t34_2_seq | 1170 | rus |
  | cromwell_mk_iv_seq | 1130 | eng |
  | m4a2 | 1170 | rus_guard |
  | t34_2_guard | 1170 | rus_guard |

- Reference: `docs/superpowers/specs/2026-07-10-gun-based-tank-retire-design.md`.

---

### Task 1: `retire` eligibility mechanism

**Files:**
- Modify: `resource/script/multiplayer/bot.lua:1391` (add `retireOk`), `resource/script/multiplayer/bot.lua:1402` (AND it into the pool gate)
- Test: `resource/script/multiplayer/tests/retire_spec.lua` (create)

**Interfaces:**
- Consumes: `GetUnitToSpawn(units)` — returns one eligible unit table or `nil`; reads `Context.GameClock` via `Elapsed()`. Existing eligibility locals in scope: `elapsed`, `affordable`, `unlockOk`, `notRecentlyFailed`, `phaseOk`, `eliteOk`.
- Produces: a `retire` field convention on unit entries — a unit is in the pool only while `elapsed < unit.retire` (or `unit.retire == nil`).

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/retire_spec.lua`:

```lua
dofile((arg[0]:gsub("retire_spec%.lua$", "harness.lua")))

-- Two light units (Vehicle -> tier light, eligible every phase so only `retire` varies).
local units = {
	{ class = UnitClass.Vehicle, unit = "permanent", priority = 1.0 },                -- no retire, always eligible
	{ class = UnitClass.Vehicle, unit = "retiring",  priority = 1.0, retire = 1500 }, -- drops at 1500s
}

local function sample(seconds)
	Context.GameClock = seconds
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(units)
		if pick then seen[pick.unit] = true end
	end
	return seen
end

-- One second before retire: both units still appear.
local before = sample(1499)
assert(before["permanent"], "permanent unit should spawn before retire")
assert(before["retiring"], "retiring unit should still spawn one second before its retire time")

-- At the retire boundary: retiring unit is gone, permanent stays.
local at = sample(1500)
assert(at["permanent"], "permanent unit should still spawn at the boundary")
assert(not at["retiring"], "retiring unit must NOT spawn at its retire time")

-- Well after retire: still gone.
local after = sample(9999)
assert(after["permanent"], "nil-retire unit has no upper bound")
assert(not after["retiring"], "retiring unit stays retired arbitrarily late")

print("retire OK")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/retire_spec.lua`
Expected: FAIL — the assertion `retiring unit must NOT spawn at its retire time` errors, because `retire` is not yet honored so `retiring` still appears at 1500s.

- [ ] **Step 3: Add the `retireOk` local**

In `resource/script/multiplayer/bot.lua`, after line 1391 (`local unlockOk = ...`), insert:

```lua
		local retireOk = (unit.retire == nil) or (elapsed < unit.retire)
```

- [ ] **Step 4: AND `retireOk` into the pool gate**

In `resource/script/multiplayer/bot.lua`, change the eligibility condition (was line 1402):

```lua
		if affordable and unlockOk and notRecentlyFailed and phaseOk and eliteOk then
```

to:

```lua
		if affordable and unlockOk and retireOk and notRecentlyFailed and phaseOk and eliteOk then
```

- [ ] **Step 5: Syntax check and run the test**

Run: `cd resource/script/multiplayer && luac -p bot.lua && lua tests/retire_spec.lua`
Expected: `retire OK`

- [ ] **Step 6: Run the full suite (regression)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
Expected: every spec prints its own `... OK` line; no assertion errors. Units without a `retire` field are unaffected.

- [ ] **Step 7: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/retire_spec.lua
git commit -m "Add time-based retire gate to spawn pool eligibility

New optional retire field on unit entries, symmetric to unlock: a unit
is eligible while elapsed < retire. nil retire keeps current behavior.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Apply `retire` to the 11 verified units

**Files:**
- Modify: `resource/script/multiplayer/bot.data.lua` at lines 230, 233, 309, 310, 365, 400, 491, 493, 528, 529, and 171 (add `retire=` to each listed unit)
- Test: `resource/script/multiplayer/tests/retire_data_spec.lua` (create)

**Interfaces:**
- Consumes: the roster table `Purchases[1].Units[army]` (global, loaded from `bot.data.lua`); each entry is a table with `unit`, `class`, `weight`, `unlock`, and now optionally `retire`.
- Produces: 11 medium-tank entries carrying the retire values from Global Constraints. A retired unit's tier stays `medium` (only its eligibility window changes).

- [ ] **Step 1: Write the failing data test**

Create `resource/script/multiplayer/tests/retire_data_spec.lua`:

```lua
dofile((arg[0]:gsub("retire_data_spec%.lua$", "harness.lua")))

local Units = Purchases[1].Units

local function find(army, id)
	for _, u in ipairs(Units[army]) do
		if u.unit == id then return u end
	end
	return nil
end

-- 1. Every listed unit carries its exact retire value.
local expected = {
	{ "ger",       "pz3_m",              950  },
	{ "ger",       "pz3n",               1300 },
	{ "ger_ss",    "pz3_m_ss",           830  },
	{ "ger_ss",    "pz3n_ss",            1300 },
	{ "ger2",      "pz3_ger2",           830  },
	{ "ger2",      "t34_2_ger",          1750 },
	{ "usa",       "m4a3_75_seq",        1120 },
	{ "rus",       "t34_2_seq",          1170 },
	{ "eng",       "cromwell_mk_iv_seq", 1130 },
	{ "rus_guard", "m4a2",               1170 },
	{ "rus_guard", "t34_2_guard",        1170 },
}
for _, e in ipairs(expected) do
	local army, id, want = e[1], e[2], e[3]
	local u = find(army, id)
	assert(u, "missing unit " .. id .. " in " .. army)
	assert(u.retire == want,
		id .. " retire expected " .. want .. " got " .. tostring(u.retire))
end

-- 2. Safety: no faction loses all its armor. For every army, at the latest retire
--    time present in its roster, at least one Tank/HeavyTank remains eligible
--    (retire nil or retire > that time).
local ARMOR = { Tank = true, HeavyTank = true }
for army, roster in pairs(Units) do
	local latest = 0
	for _, u in ipairs(roster) do
		if u.retire and u.retire > latest then latest = u.retire end
	end
	if latest > 0 then
		local survivors = 0
		for _, u in ipairs(roster) do
			local cls = (u.class == UnitClass.Tank and "Tank")
				or (u.class == UnitClass.HeavyTank and "HeavyTank") or nil
			if cls and ARMOR[cls] and (u.retire == nil or u.retire > latest) then
				survivors = survivors + 1
			end
		end
		assert(survivors > 0,
			army .. " has no armor left at its latest retire time " .. latest)
	end
end

-- 3. Japan retires nothing (no HeavyTank backup).
for _, u in ipairs(Units["jap"]) do
	assert(u.retire == nil, "jap unit " .. u.unit .. " must not retire")
end

print("retire data OK")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/retire_data_spec.lua`
Expected: FAIL — `pz3_m retire expected 950 got nil` (no retire fields added yet).

- [ ] **Step 3: Add `retire` to each unit (ger)**

In `resource/script/multiplayer/bot.data.lua`, add a `retire=` key inside the braces of each entry. Line 230 (`pz3_m`):

```lua
				{priority=1.0, class=UnitClass.Tank,       unit="pz3_m",               min_income=1.0, unlock=630, retire=950, weight="medium",},
```

Line 233 (`pz3n`):

```lua
				{priority=1.5, class=UnitClass.Tank,          unit="pz3n",                 min_income=1.5, unlock=630, retire=1300, weight="medium",},
```

- [ ] **Step 4: Add `retire` to each unit (ger_ss, ger2)**

Line 309 (`pz3_m_ss`):

```lua
				{priority=1.0, class=UnitClass.Tank,       unit="pz3_m_ss",            min_income=1.0, unlock=630, retire=830, weight="medium",},
```

Line 310 (`pz3n_ss`):

```lua
				{priority=1.5, class=UnitClass.Tank,          unit="pz3n_ss",              min_income=1.5, unlock=630, retire=1300, weight="medium",},
```

Line 491 (`pz3_ger2`):

```lua
				{priority=1.0, class=UnitClass.Tank,       unit="pz3_ger2",           min_income=1.0, unlock=630, retire=830, weight="medium",},
```

Line 493 (`t34_2_ger`):

```lua
				{priority=2.0, class=UnitClass.Tank,          unit="t34_2_ger",           min_income=1.5, unlock=750, retire=1750, weight="medium",},
```

- [ ] **Step 5: Add `retire` to each unit (usa, rus, eng, rus_guard)**

Line 365 (`m4a3_75_seq`):

```lua
				{priority=2.0, class=UnitClass.Tank,          unit="m4a3_75_seq",          min_income=1.5, unlock=750, retire=1120, weight="medium",},
```

Line 400 (`t34_2_seq`):

```lua
				{priority=2.0, class=UnitClass.Tank,          unit="t34_2_seq",            min_income=1.5, unlock=750, retire=1170, weight="medium",},
```

Line 171 (`cromwell_mk_iv_seq`):

```lua
				{priority=2.0, class=UnitClass.Tank,          unit="cromwell_mk_iv_seq",   min_income=1.5, unlock=750, retire=1130, weight="medium",},
```

Line 528 (`m4a2`):

```lua
				{priority=2.0, class=UnitClass.Tank,          unit="m4a2",           min_income=1.5, unlock=750, retire=1170, weight="medium",},
```

Line 529 (`t34_2_guard`):

```lua
				{priority=2.0, class=UnitClass.Tank,          unit="t34_2_guard",    min_income=1.5, unlock=750, retire=1170, weight="medium",},
```

- [ ] **Step 6: Syntax check and run the data test**

Run: `cd resource/script/multiplayer && luac -p bot.data.lua && lua tests/retire_data_spec.lua`
Expected: `retire data OK`

- [ ] **Step 7: Run the full suite (regression)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
Expected: every spec prints its `... OK`; no assertion errors. (Existing specs that spawn `ger`/`usa`/`rus` armor at late clocks still find a tank, because each faction keeps its long-gun and heavy entries.)

- [ ] **Step 8: Commit**

```bash
git add resource/script/multiplayer/bot.data.lua resource/script/multiplayer/tests/retire_data_spec.lua
git commit -m "Retire 11 obsolete medium tanks by gun effectiveness

Add retire values to weak-gun weight=medium tanks (5cm, short 75, 75 M3,
76 F-34) aligned to each faction's superior-gun successor unlock. Heavy
armor, HE/flame, light tiers, and the full Japanese roster keep no retire.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Documentation and architecture update

**Files:**
- Modify: `resource/script/multiplayer/bot.data.lua` (inline comment above the first `["eng"]` roster block)
- Modify: `ARCHITECTURE.md` (GetUnitToSpawn description, near line 110)
- Modify: `README.md` (roster description, near line 21)

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: nothing executable.

- [ ] **Step 1: Add an inline schema comment in bot.data.lua**

In `resource/script/multiplayer/bot.data.lua`, immediately above the `{--single full roster` line (line 140), insert:

```lua
-- Per-unit spawn-window fields: `unlock` = earliest elapsed seconds a unit may spawn;
-- `retire` = elapsed seconds at which a unit drops from the pool (obsolete gun). Both are
-- optional; omit for units that are eligible for the whole match. Only weight="medium"
-- weak-gun tanks carry `retire` -- they otherwise keep diluting the medium-armor pick
-- share long after their gun stops penetrating enemy armor.
```

- [ ] **Step 2: Update the GetUnitToSpawn description in ARCHITECTURE.md**

In `ARCHITECTURE.md`, find the sentence (near line 110):

```
`DecideTier` picks the tier (target heavy:medium:light:infantry ratio, gated by
`tierEligible` and losing-state) → `GetUnitToSpawn` picks a specific live unit,
skipping anything on recharge (`bot.data.lua` `;Nsec` cooldown) or
`FailCooldown` (benched after an unaffordable spawn attempt).
```

Replace it with:

```
`DecideTier` picks the tier (target heavy:medium:light:infantry ratio, gated by
`tierEligible` and losing-state) → `GetUnitToSpawn` picks a specific live unit
whose spawn window is open (`unlock` ≤ elapsed < `retire`), skipping anything on
recharge (`bot.data.lua` `;Nsec` cooldown) or `FailCooldown` (benched after an
unaffordable spawn attempt). The optional `retire` field drops a weak-gun
`weight="medium"` tank once its gun can no longer penetrate the enemy armor on
the field, so it stops diluting the medium-armor pick share late-game.
```

- [ ] **Step 3: Update the roster description in README.md**

In `README.md`, read the lines around line 21 first:

Run: `sed -n '15,28p' README.md`

Then, in the sentence that describes per-unit `unlock` times, append a clause noting the `retire` companion field. For example, if the line reads:

```
  (`FactionPhases`), anchored to that faction's real RobZ unlock times — e.g. usa
```

add a following sentence in the same paragraph:

```
  Weak-gun medium tanks also carry a `retire` time so they leave the spawn pool
  once a better-gunned successor unlocks, instead of dying uselessly late-game.
```

Match the surrounding markdown style (bullet vs prose) of the paragraph you are editing.

- [ ] **Step 4: Syntax check (docs touch bot.data.lua comment)**

Run: `cd resource/script/multiplayer && luac -p bot.data.lua`
Expected: no output (clean).

- [ ] **Step 5: Run the full suite (confirm comment did not break parsing)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
Expected: every spec prints its `... OK`.

- [ ] **Step 6: Commit**

```bash
git add resource/script/multiplayer/bot.data.lua ARCHITECTURE.md README.md
git commit -m "Document the retire spawn-window field

Explain retire in the bot.data.lua schema comment, the ARCHITECTURE
GetUnitToSpawn description, and the README roster section.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Mechanism (`retire` filter line) → Task 1. ✓
- Backward compatibility (nil retire unchanged) → Task 1 test step 6, Task 2 step 7. ✓
- Retire dataset (11 units, exact values) → Task 2, Global Constraints table. ✓
- Heavy-armor soak / HE / light / long-gun keeps → enforced by omission (only the 11 listed units get `retire`); verified by Task 2 safety test. ✓
- No-successor safety (Japan keeps all) → Task 2 test parts 2 and 3. ✓
- Testing (boundary, disappearance, regression, safety, Japan) → Task 1 + Task 2 tests. ✓
- Docs / architecture update → Task 3. ✓

**Placeholder scan:** No TBD/TODO. README step 3 shows the exact clause to add and instructs reading context first because the surrounding markdown style must be matched; the inserted text is concrete. ✓

**Type consistency:** `retire` is a numeric field on unit entries throughout; `Purchases[1].Units[army]` roster access matches `bot.lua` usage; `UnitClass.Tank` / `UnitClass.HeavyTank` names match `bot.data.lua`. The eligibility gate uses the existing `elapsed` local (not `Elapsed()`), matching the neighboring `unlockOk` line. ✓
