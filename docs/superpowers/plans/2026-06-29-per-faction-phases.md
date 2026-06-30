# Per-Faction Phase Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve each faction's early/mid/late phase boundaries (and Japan's late composition) from its real unit unlock times, replacing the single global boundary set.

**Architecture:** A new `FactionPhases` data table holds each faction's `mid`/`late` boundary seconds (and Japan's `lateTargets`). A pure `ResolvePhases(army)` clones the global `Phases` template and applies those overrides; `OnGameStart` stores the result in `Context.Phases`; `CurrentPhase` reads `Context.Phases or Phases`. The global `Phases` stays unchanged as template and fallback.

**Tech Stack:** Lua 5.1 (engine has NO `goto`, 32-bit). Offline test harness driven with `lua tests/<name>_spec.lua`, plain `assert`/`error`.

## Global Constraints

- Lua 5.1 only. No `goto`. No new external dependencies.
- `budget`, `waveMult`, `squadCap` stay global (on the `Phases` template); only `upto` and (Japan) `targets` vary per faction.
- Faction keys match `Purchases[1].Units` / `BotApi.Instance.army`: `eng`, `ger`, `ger_ss`, `usa`, `rus`, `jap`, `ger2`, `rus_guard`.
- Resolved boundaries (verbatim): eng 750/1050, ger 630/1500, ger_ss 630/1500, usa 530/1200, rus 750/1050, jap 580/1380, ger2 630/1750, rus_guard 750/1240.
- Japan `late.targets` (verbatim): `{ medium = 2, light = 2, rifle = 3, smg = 1 }` (no `heavy` key).
- Global `late.targets` (unchanged): `{ heavy = 1, medium = 1, light = 2, rifle = 3, smg = 1 }`.
- Output artifacts in professional English. No em dashes. No banned words (delve/robust/comprehensive/nuanced/leverage/certainly).
- Run tests from `resource/script/multiplayer/`: `lua tests/<name>_spec.lua`.

---

### Task 1: `FactionPhases` data + `ResolvePhases(army)` pure function

**Files:**
- Modify: `resource/script/multiplayer/bot.data.lua` (add `FactionPhases` after the `Phases` block, ends at line 33)
- Modify: `resource/script/multiplayer/bot.lua` (add `ResolvePhases` next to `CurrentPhase`, ~line 554)
- Test: `resource/script/multiplayer/tests/phase_spec.lua` (append a `ResolvePhases` section before the final group-helper section)

**Interfaces:**
- Consumes: global `Phases` (array of 3 entries, each `{ name, upto, targets, budget, waveMult, squadCap }`) from `bot.data.lua`.
- Produces: `FactionPhases` (table keyed by faction string → `{ mid = <number>, late = <number>, lateTargets = <table?> }`); `ResolvePhases(army)` returning a 3-entry phase array, or the global `Phases` table itself when `army` has no entry.

- [ ] **Step 1: Write the failing test**

Append to `resource/script/multiplayer/tests/phase_spec.lua`, immediately after the `print("phase OK")` line:

```lua
-- ResolvePhases: per-faction boundaries; budget/waveMult/squadCap stay global.
local ger = ResolvePhases("ger")
eq(ger[1].name, "early", "ger p1 is early")
eq(ger[1].upto, 630,        "ger early ends at first medium 630")
eq(ger[2].upto, 1500,       "ger mid ends at first heavy 1500")
eq(ger[3].upto, 1000000000, "ger late is open-ended")
eq(ger[1].budget,   Phases[1].budget,   "ger early budget shared with global")
eq(ger[2].waveMult, Phases[2].waveMult, "ger mid waveMult shared with global")
eq(ger[3].squadCap, Phases[3].squadCap, "ger late squadCap shared with global")
eq(ger[3].targets.heavy, 1, "ger keeps global late targets (heavy present)")

local usa = ResolvePhases("usa")
eq(usa[1].upto, 530,  "usa early ends at 530")
eq(usa[2].upto, 1200, "usa mid ends at 1200")

-- eng: first heavy (820) is below first medium (750) + 300 floor, so floor governs.
local eng = ResolvePhases("eng")
eq(eng[2].upto, 1050, "eng mid->late uses the 300s floor (1050), not 820")

-- jap: no heavy tier -> late targets drop heavy and boost medium.
local jap = ResolvePhases("jap")
eq(jap[1].upto, 580,  "jap early ends at 580")
eq(jap[2].upto, 1380, "jap mid ends at chi-to 1380")
eq(jap[3].targets.heavy,  nil, "jap late has no heavy target")
eq(jap[3].targets.medium, 2,   "jap late medium boosted to 2")

-- unknown faction -> global Phases table (identity fallback).
assert(ResolvePhases("nonexistent") == Phases, "unknown army returns the global Phases table")
print("ResolvePhases OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/phase_spec.lua`
Expected: FAIL with an error like `attempt to call global 'ResolvePhases' (a nil value)`.

- [ ] **Step 3: Add the `FactionPhases` data table**

In `resource/script/multiplayer/bot.data.lua`, immediately after the `Phases = { ... }` block (the `}` on line 33), insert:

```lua

-- Per-faction phase boundaries (seconds), anchored to real RobZ unlock times.
--   early -> mid = faction's first medium unlock.
--   mid   -> late = max(first HeavyTank-class unlock, first medium + 300s floor).
-- The 300s floor only binds eng (820 -> 1050) and rus (830 -> 1050), whose heavies
-- unlock right after their mediums. Japan has no HeavyTank unit, so its late anchors
-- to chi-to (1380) and its late composition drops the heavy tier (see lateTargets).
-- budget/waveMult/squadCap are NOT here; they stay shared on the global Phases template.
FactionPhases = {
	["eng"]       = { mid = 750, late = 1050 },
	["ger"]       = { mid = 630, late = 1500 },
	["ger_ss"]    = { mid = 630, late = 1500 },
	["usa"]       = { mid = 530, late = 1200 },
	["rus"]       = { mid = 750, late = 1050 },
	["jap"]       = { mid = 580, late = 1380,
	                  lateTargets = { medium = 2, light = 2, rifle = 3, smg = 1 } },
	["ger2"]      = { mid = 630, late = 1750 },
	["rus_guard"] = { mid = 750, late = 1240 },
}
```

- [ ] **Step 4: Add the `ResolvePhases` function**

In `resource/script/multiplayer/bot.lua`, immediately before `function CurrentPhase(elapsedSec)` (currently line 554), insert:

```lua
-- Build a faction-resolved phase array from the global Phases template: apply this
-- faction's mid/late boundaries and (Japan) its late targets, keeping the shared
-- budget/waveMult/squadCap. Returns the global Phases table unchanged when the faction
-- has no entry. Pure: depends only on its argument and the module-level Phases/FactionPhases.
function ResolvePhases(army)
	local fp = FactionPhases and FactionPhases[army]
	if not fp then return Phases end
	return {
		{ name = "early", upto = fp.mid, targets = Phases[1].targets,
		  budget = Phases[1].budget, waveMult = Phases[1].waveMult, squadCap = Phases[1].squadCap },
		{ name = "mid", upto = fp.late, targets = Phases[2].targets,
		  budget = Phases[2].budget, waveMult = Phases[2].waveMult, squadCap = Phases[2].squadCap },
		{ name = "late", upto = 1000000000, targets = fp.lateTargets or Phases[3].targets,
		  budget = Phases[3].budget, waveMult = Phases[3].waveMult, squadCap = Phases[3].squadCap },
	}
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/phase_spec.lua`
Expected: PASS, ending with `ResolvePhases OK` (and the existing `TierOf OK`, `phase OK`, `group helpers OK`, `PickGroupTarget OK` lines still print).

- [ ] **Step 6: Commit**

```bash
git add resource/script/multiplayer/bot.data.lua resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/phase_spec.lua
git commit -m "feat: per-faction phase boundaries via FactionPhases + ResolvePhases"
```

---

### Task 2: Wire `Context.Phases` and make `CurrentPhase` faction-aware

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`CurrentPhase` ~line 554; `OnGameStart` ~line 1032)
- Test: `resource/script/multiplayer/tests/phase_spec.lua` (append a `CurrentPhase` faction-aware section after `ResolvePhases OK`)

**Interfaces:**
- Consumes: `ResolvePhases(army)` from Task 1; `Context` table; `BotApi.Instance.army`.
- Produces: `Context.Phases` (a resolved phase array set in `OnGameStart`); `CurrentPhase(elapsedSec)` now reads `Context.Phases or Phases`.

- [ ] **Step 1: Write the failing test**

Append to `resource/script/multiplayer/tests/phase_spec.lua`, immediately after the `print("ResolvePhases OK")` line:

```lua
-- CurrentPhase reads Context.Phases when set, falls back to global Phases when nil.
Context.Phases = ResolvePhases("jap")
eq(CurrentPhase(500).name,  "early", "jap 500 is early (< 580)")
eq(CurrentPhase(600).name,  "mid",   "jap 600 is mid (>= 580, < 1380)")
eq(CurrentPhase(1400).name, "late",  "jap 1400 is late (>= 1380)")
Context.Phases = nil
eq(CurrentPhase(180).name, "mid", "fallback to global Phases when Context.Phases is nil")
print("CurrentPhase faction OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/phase_spec.lua`
Expected: FAIL at `jap 600 is mid` — `CurrentPhase` still reads the global `Phases` (mid ends at 480), so `CurrentPhase(600)` returns `late`, not `mid`.

- [ ] **Step 3: Make `CurrentPhase` read `Context.Phases`**

In `resource/script/multiplayer/bot.lua`, replace the `CurrentPhase` body (currently):

```lua
function CurrentPhase(elapsedSec)
	for i = 1, #Phases do
		if elapsedSec < Phases[i].upto then return Phases[i] end
	end
	return Phases[#Phases]
end
```

with:

```lua
function CurrentPhase(elapsedSec)
	local phases = Context.Phases or Phases
	for i = 1, #phases do
		if elapsedSec < phases[i].upto then return phases[i] end
	end
	return phases[#phases]
end
```

- [ ] **Step 4: Wire `Context.Phases` in `OnGameStart`**

In `resource/script/multiplayer/bot.lua`, in `OnGameStart`, immediately after the line `Context.Purchase = PIter:new(Purchases)`, insert:

```lua
	Context.Phases = ResolvePhases(BotApi.Instance.army)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/phase_spec.lua`
Expected: PASS, ending with `CurrentPhase faction OK`.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do echo "== $f =="; lua "$f" || break; done`
Expected: every spec prints its OK lines and none aborts. The existing `phase_spec` `CurrentPhase` assertions (179 early, 180 mid, 480 late) still pass because no spec sets `Context.Phases` during those checks, so the global `Phases` fallback governs.

- [ ] **Step 7: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/phase_spec.lua
git commit -m "feat: CurrentPhase reads Context.Phases; OnGameStart resolves per-faction phases"
```

---

## Self-Review

**Spec coverage:**
- `FactionPhases` table → Task 1 Step 3. ✓
- `ResolvePhases(army)` pure function + fallback → Task 1 Step 4, tested Step 1. ✓
- `OnGameStart` wiring → Task 2 Step 4. ✓
- `CurrentPhase` reads `Context.Phases or Phases` → Task 2 Step 3, tested Step 1. ✓
- Japan late-targets drop heavy → Task 1 data + test (`jap[3].targets.heavy == nil`). ✓
- 300s floor (eng/rus) → Task 1 test (`eng[2].upto == 1050`). ✓
- Existing specs stay green → Task 2 Step 6. ✓
- Resolved boundary values match the spec table → Task 1 data Step 3 + assertions. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code and exact commands. ✓

**Type consistency:** `ResolvePhases` returns the same entry shape `{ name, upto, targets, budget, waveMult, squadCap }` as global `Phases`; `CurrentPhase` consumes `.upto`/`.name`; `Context.Phases` set in Task 2 matches `ResolvePhases` return. `FactionPhases` entry shape `{ mid, late, lateTargets? }` consumed only inside `ResolvePhases`. ✓
