# Losing-Side MP Discipline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the losing bot from bleeding MP on cheap tanks and rear artillery, so it banks MP for a survivable force.

**Architecture:** Two features on `bot.lua`. (1) An armor-bank window: when a `min_income`-eligible armor unit fails `Commands:Spawn` (balance drained), open a window during which `GetUnitToSpawn` refuses to downgrade to a cheaper tier -- it spawns armor if affordable, else nothing, so MP accumulates. (2) A deficit-and-window-aware artillery cap: baseline lowered to 1, forced to 0 when badly losing or while the bank window is active.

**Tech Stack:** Lua 5.x. Offline harness (`tests/harness.lua`), bare-`assert`-with-`print("... OK")` specs.

## Global Constraints

- Run `luac -p bot.lua && luac -p bot.data.lua` before running specs.
- Run the whole suite before every commit that touches `bot.lua`:
  `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done` -- every spec prints `... OK`, no assertion errors. Specs run from `resource/script/multiplayer`.
- `ArmorBankSec = 90` (seconds). `BadlyLosingDeficit = 3`. `ArtyCap` baseline = `1`.
- The bank window may be opened ONLY by a `Commands:Spawn` failure of an armor-tier unit (`TierOf` in `heavy`/`medium`). A unit that fails is by construction one that passed `min_income` (only pooled units are picked), so no extra `min_income` check is needed; and a `min_income`-excluded unit is never picked, so it can never open the window. Do not add any deficit/losing condition to the window trigger.
- `TierOf`: `HeavyTank` -> `heavy`; `Tank` with `weight="medium"` -> `medium`; `Vehicle` -> `light`.
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Reference spec: `docs/superpowers/specs/2026-07-10-losing-mp-discipline-design.md`.

---

### Task 1: Armor no-downgrade MP banking

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` -- add constant near line 90; add `Context.ArmorBankUntil` init near line 1847; add bank-window gate in `GetUnitToSpawn` before the armor-lead block (~line 1455); add window trigger in `AttemptSpawn`'s `if not ok then` block (~line 1964).
- Test: `resource/script/multiplayer/tests/mp_discipline_spec.lua` (create)

**Interfaces:**
- Consumes: `GetUnitToSpawn(units)` (returns one unit or nil; reads `Context.GameClock` via `Elapsed()`); `AttemptSpawn(tag)` (spawns `Context.SpawnInfo`, reads `Context.FillGroup`/`Context.FieldUnits`); local `elapsed`, local `weightOf`, `byTier` table inside `GetUnitToSpawn`; `TierOf(unit)`.
- Produces: `Context.ArmorBankUntil` (elapsed-seconds timestamp; unit eligible for wave/backfill fill is armor-only while `Elapsed() < Context.ArmorBankUntil`). `ArmorBankSec` constant.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/mp_discipline_spec.lua`:

```lua
dofile((arg[0]:gsub("mp_discipline_spec%.lua$", "harness.lua")))

-- Tier reference: HeavyTank -> heavy, Tank+weight=medium -> medium, Vehicle -> light.
local heavy  = { class = UnitClass.HeavyTank, unit = "pz5g", priority = 1.0 }
local medium = { class = UnitClass.Tank, unit = "pz4h", priority = 1.0, weight = "medium" }
local light  = { class = UnitClass.Vehicle, unit = "lighttk", priority = 1.0 }

local function sample(units, seconds)
	Context.GameClock = seconds
	Context.FailCooldown = {}
	local seen = {}
	for i = 1, 200 do
		local pick = GetUnitToSpawn(units)
		if pick then seen[pick.unit] = true end
	end
	return seen
end

-- (A) Window inactive: the light unit is selectable (normal downgrade allowed).
Context.ArmorBankUntil = 0
local off = sample({ medium, light }, 1000)
assert(off["lighttk"], "with no bank window, light tier is selectable")

-- (B) Window active + armor present: only armor spawns, never the cheaper light.
Context.ArmorBankUntil = 5000
local on = sample({ medium, light }, 1000)   -- 1000 < 5000 => window active
assert(on["pz4h"], "in bank window, affordable armor still spawns")
assert(not on["lighttk"], "in bank window, must NOT downgrade to the light tier")

-- (C) Window active + NO armor affordable: spawn nothing (hard bank).
Context.ArmorBankUntil = 5000
Context.GameClock = 1000
Context.FailCooldown = {}
assert(GetUnitToSpawn({ light }) == nil, "in bank window with no armor, GetUnitToSpawn returns nil")

-- (D) Window trigger: an armor Spawn failure opens the window; a non-armor one does not.
BotApi.Commands.Spawn = function() return false end   -- force every spawn to fail
Context.FillGroup = nil
Context.FieldUnits = {}

Context.GameClock = 500
Context.ArmorBankUntil = 0
Context.SpawnInfo = heavy
AttemptSpawn("SPAWN")
assert(Context.ArmorBankUntil > 500, "armor Spawn failure opens the bank window")

Context.GameClock = 500
Context.ArmorBankUntil = 0
Context.SpawnInfo = light
AttemptSpawn("SPAWN")
assert(Context.ArmorBankUntil == 0, "non-armor Spawn failure must NOT open the bank window")

BotApi.Commands.Spawn = function() return true end    -- restore harness default
print("mp discipline OK")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/mp_discipline_spec.lua`
Expected: FAIL at assertion (B) `in bank window, must NOT downgrade to the light tier` (the gate does not exist yet, so the light unit still spawns).

- [ ] **Step 3: Add the `ArmorBankSec` constant**

In `resource/script/multiplayer/bot.lua`, after the `HeavyFailSlowdownMult` line (~line 90), add:

```lua
local ArmorBankSec = 90   -- seconds: after an affordable armor unit fails to spawn (MP balance
                          -- drained), refuse to downgrade to a cheaper tier for this long so MP
                          -- banks toward the armor. Self-ends the instant armor is affordable.
```

- [ ] **Step 4: Initialise `Context.ArmorBankUntil`**

In `resource/script/multiplayer/bot.lua`, after the `Context.SpawnSlowdownUntil = 0` line (~line 1847), add:

```lua
	Context.ArmorBankUntil = 0
```

- [ ] **Step 5: Add the bank-window gate in `GetUnitToSpawn`**

In `resource/script/multiplayer/bot.lua`, immediately AFTER the `weightOf` local function definition and BEFORE the armor-lead block (the line `if g and (g.armorLead or 0) > 0 then`, ~line 1456), insert:

```lua
	-- Armor-bank window: an affordable armor unit just failed to spawn (MP balance drained).
	-- Refuse to downgrade to a cheaper tier -- spawn armor if any is affordable now, else
	-- spawn nothing so MP accumulates for it. Wave + backfill both route through here, so
	-- both stop; the capper/defender/attank trickles use their own pickers and keep running,
	-- and the flag-capturing cappers keep lifting income while the balance recovers.
	if elapsed < (Context.ArmorBankUntil or 0) then
		if #byTier.heavy > 0 then
			return GetRandomItem(byTier.heavy, weightOf)
		elseif #byTier.medium > 0 then
			return GetRandomItem(byTier.medium, weightOf)
		else
			return nil
		end
	end
```

- [ ] **Step 6: Add the window trigger in `AttemptSpawn`**

In `resource/script/multiplayer/bot.lua`, find the failure tail of `AttemptSpawn` (~line 1964):

```lua
	if not ok then
		Context.FailCooldown[unit.unit] = Elapsed()
```

Immediately after that `Context.FailCooldown[unit.unit] = Elapsed()` line, add:

```lua
		-- An affordable armor unit (it passed min_income to be picked) failed to spawn =>
		-- the MP balance is drained. Open the bank window so GetUnitToSpawn stops downgrading
		-- to cheap tanks and banks toward this armor instead. Generalises the late-heavy
		-- HeavyFailSlowdown to all armor, every phase.
		local bankTier = TierOf(unit)
		if bankTier == "heavy" or bankTier == "medium" then
			Context.ArmorBankUntil = Elapsed() + ArmorBankSec
		end
```

- [ ] **Step 7: Syntax check and run the test**

Run: `cd resource/script/multiplayer && luac -p bot.lua && lua tests/mp_discipline_spec.lua`
Expected: `mp discipline OK`

- [ ] **Step 8: Run the full suite (regression)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
Expected: every spec prints `... OK`; no assertion errors. (`Context.ArmorBankUntil` defaults to 0, so no existing spec enters the window.)

- [ ] **Step 9: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/mp_discipline_spec.lua
git commit -m "Add armor no-downgrade MP banking

When a min_income-eligible armor unit fails Commands:Spawn (balance drained),
open a 90s window during which GetUnitToSpawn spawns armor if affordable else
nothing, instead of downgrading to a cheap tank. Wave and backfill both route
through GetUnitToSpawn so both bank; trickles keep running.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Artillery cap -- deficit and bank-window aware

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` -- `ArtyCap` value (line 148); add `BadlyLosingDeficit` constant near it; add `ArtyCapNow()` after `FlagDeficit` (~line 1181); change the artillery trickle `cap` (line 2164).
- Test: `resource/script/multiplayer/tests/arty_cap_spec.lua` (create)

**Interfaces:**
- Consumes: `FlagDeficit()` (returns enemy flags minus own flags; reads `BotApi.Scene.Flags`, `IsCapturedFlag`, `IsEnemyFlag`); `Context.ArmorBankUntil` (from Task 1); `Elapsed()`.
- Produces: `ArtyCapNow()` -> `0` while the bank window is active, `0` when `FlagDeficit() >= BadlyLosingDeficit`, else `1`. Used as the artillery trickle cap. The trickle's `if live >= cfg.cap then return false` hard-gates on it (the FactionBias floor cannot bypass the cap check), so cap `0` fully suppresses artillery.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/arty_cap_spec.lua`:

```lua
dofile((arg[0]:gsub("arty_cap_spec%.lua$", "harness.lua")))

-- FlagDeficit = (enemy-held flags) - (own-held flags). Drive it via BotApi.Scene.Flags.
-- IsCapturedFlag/IsEnemyFlag classify by `flag.occupant` vs BotApi.Instance.team/enemyTeam.
local function setFlags(ownCount, enemyCount)
	local flags = {}
	for i = 1, ownCount   do flags[#flags + 1] = { occupant = BotApi.Instance.team } end
	for i = 1, enemyCount do flags[#flags + 1] = { occupant = BotApi.Instance.enemyTeam } end
	BotApi.Scene.Flags = flags
end

Context.ArmorBankUntil = 0
Context.GameClock = 1000

-- Even flags (deficit 0): default cap 1.
setFlags(3, 3)
assert(FlagDeficit() == 0, "sanity: even flags => deficit 0")
assert(ArtyCapNow() == 1, "even/ahead: ArtyCapNow is 1")

-- Small deficit (1-2 behind): still 1.
setFlags(2, 4)
assert(FlagDeficit() == 2, "sanity: deficit 2")
assert(ArtyCapNow() == 1, "small deficit keeps ArtyCapNow at 1")

-- Badly losing (deficit >= 3): 0.
setFlags(1, 4)
assert(FlagDeficit() == 3, "sanity: deficit 3")
assert(ArtyCapNow() == 0, "badly losing (deficit>=3): ArtyCapNow is 0")

-- Bank window active overrides everything: 0 even when even on flags.
setFlags(3, 3)
Context.ArmorBankUntil = 5000   -- 1000 < 5000 => active
assert(ArtyCapNow() == 0, "bank window active: ArtyCapNow is 0 regardless of deficit")
Context.ArmorBankUntil = 0

-- Baseline constant lowered to 1.
assert(ArtyCap == 1, "ArtyCap baseline is 1")

print("arty cap OK")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/arty_cap_spec.lua`
Expected: FAIL -- `ArtyCapNow` is not defined yet (attempt to call a nil value), or `ArtyCap` is still 2.

- [ ] **Step 3: Lower `ArtyCap` and add `BadlyLosingDeficit`**

In `resource/script/multiplayer/bot.lua`, change line 148 from:

```lua
ArtyCap          = 2       -- max live artillery pieces the bot keeps fielded
```

to:

```lua
ArtyCap          = 1       -- baseline max live artillery (see ArtyCapNow for the live value)
BadlyLosingDeficit = 3     -- FlagDeficit at/above which artillery is dropped entirely
```

- [ ] **Step 4: Add `ArtyCapNow()`**

In `resource/script/multiplayer/bot.lua`, immediately after the `FlagDeficit` function (the line `end` closing it, ~line 1181), add:

```lua
-- Live artillery cap right now. Artillery is MP-heavy rear support: drop it to 0 while badly
-- losing (FlagDeficit >= BadlyLosingDeficit) so MP goes to the front line that retakes flags,
-- and to 0 while the armor-bank window is active (banking must not bleed MP into the rear).
-- Otherwise the baseline ArtyCap. The trickle's `live >= cap` check hard-gates on this, so a
-- FactionBias artillery floor cannot bypass a 0 cap.
function ArtyCapNow()
	if Elapsed() < (Context.ArmorBankUntil or 0) then return 0 end
	if FlagDeficit() >= BadlyLosingDeficit then return 0 end
	return ArtyCap
end
```

- [ ] **Step 5: Use `ArtyCapNow()` at the artillery trickle**

In `resource/script/multiplayer/bot.lua`, change the artillery trickle (line 2164) from:

```lua
			lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCap,
```

to:

```lua
			lastTimeField = "LastArtyTime", interval = ArtyIntervalSec, cap = ArtyCapNow(),
```

- [ ] **Step 6: Syntax check and run the test**

Run: `cd resource/script/multiplayer && luac -p bot.lua && lua tests/arty_cap_spec.lua`
Expected: `arty cap OK`

- [ ] **Step 7: Run the full suite (regression + ValidateFactionBias)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
Expected: every spec prints `... OK`. In particular the spec that calls `ValidateFactionBias()` must still pass: every faction's artillery floor is 1, and `1 <= ArtyCap (1)`, so no floor-exceeds-cap violation. If any violation appears, STOP and report -- do not lower a FactionBias floor without escalating.

- [ ] **Step 8: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/arty_cap_spec.lua
git commit -m "Cut artillery cap: baseline 1, zero when badly losing or banking

ArtyCap baseline 2->1. New ArtyCapNow() returns 0 while the armor-bank window
is active or FlagDeficit >= BadlyLosingDeficit (3), else 1. The trickle's
live>=cap check hard-gates on it, so a FactionBias floor cannot force arty
past a 0 cap.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Documentation

**Files:**
- Modify: `ARCHITECTURE.md` (the spawn-economy / trickle description).

**Interfaces:**
- Consumes/Produces: nothing executable.

- [ ] **Step 1: Read the target section**

Run: `grep -n "GetUnitToSpawn\|HeavyFailStreak\|artillery\|ArtyCap\|trickle" ARCHITECTURE.md`
Read the surrounding lines of the first `GetUnitToSpawn` / spawn-economy hit to find the paragraph that describes spawn selection and the trickle caps.

- [ ] **Step 2: Document the armor-bank window and artillery cap**

In `ARCHITECTURE.md`, in the spawn-economy subsystem description (near the `GetUnitToSpawn` / `HeavyFailSlowdown` text), add two sentences that match the surrounding prose style (no em dashes, professional English):

```
An armor-bank window (`Context.ArmorBankUntil`, `ArmorBankSec`) generalises the late-heavy
slowdown: when a `min_income`-eligible armor unit fails `Commands:Spawn` (the MP balance is
drained), `GetUnitToSpawn` refuses to downgrade to a cheaper tier for `ArmorBankSec` seconds,
spawning armor if affordable and otherwise nothing, so the balance banks toward it while the
cappers keep taking flags. Artillery upkeep bends to the flag score through `ArtyCapNow()`:
the baseline `ArtyCap` is 1, dropped to 0 while badly losing (`FlagDeficit >= BadlyLosingDeficit`)
or while the bank window is active, freeing MP for the front line.
```

Place it adjacent to the existing sentence about `GetUnitToSpawn` skipping recharge/`FailCooldown` units. Adjust wording to fit the paragraph you find.

- [ ] **Step 3: Verify docs did not break the build**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f"; done`
Expected: every spec prints `... OK` (docs-only change; this confirms nothing was touched in code).

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md
git commit -m "Document armor-bank window and deficit-aware artillery cap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Feature 1 trigger (armor Spawn-fail opens window) -> Task 1 Step 6, test (D). ✓
- Feature 1 gate (no downgrade; armor-or-nil) -> Task 1 Step 5, tests (B)(C). ✓
- Safety rule (only Spawn-fail of armor, never min_income exclusion) -> enforced structurally: only picked (min_income-passed) units reach AttemptSpawn's fail path; Global Constraints states it; no deficit condition on the trigger. ✓
- Self-recovery (window self-ends when armor affordable; bounded by ArmorBankSec + MaxWaveFails) -> gate returns armor when affordable (test B); constant bounds the window. ✓
- Scope (wave+backfill stop, capper/defender/attank keep) -> gate sits in GetUnitToSpawn which feeds wave+backfill only; trickles use separate pickers (documented, Task 1 Step 5 comment). ✓
- Feature 2 (ArtyCap 1; 0 when badly losing) -> Task 2, test. ✓
- ARTY frozen in bank window -> folded into `ArtyCapNow()` returning 0 in-window (Task 2 Step 4); hard-gated by `live >= cap`. ✓
- Docs -> Task 3. ✓

**Placeholder scan:** No TBD/TODO. Task 3 Step 1 instructs reading the target paragraph first because ARCHITECTURE.md prose must be matched; the inserted text is concrete. ✓

**Type consistency:** `Context.ArmorBankUntil` is a numeric elapsed-seconds timestamp set in Task 1 Step 6 and read in Task 1 Step 5 and Task 2 Step 4 (`ArtyCapNow`), all via `Elapsed() < (Context.ArmorBankUntil or 0)`. `ArtyCapNow()` returns an integer used as `cap`. `TierOf` return strings (`"heavy"`/`"medium"`) match the trigger and gate checks. `ArmorBankSec`/`BadlyLosingDeficit`/`ArtyCap` are the constant names used throughout. ✓
