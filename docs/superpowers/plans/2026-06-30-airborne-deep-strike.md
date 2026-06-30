# Airborne Deep-Strike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a late-game comeback mechanic that drops elite airborne squads on a dedicated cooldown when the enemy holds >65% of flags, sending them at the deepest enemy base and chaining inward, then folding into the main group target.

**Architecture:** A new independent trickle (`DeepStrikeTrickle`) in `OnGameQuant`, gated on late phase + enemy flag percentage + its own cooldown + a live cap. Spawned airborne squads are tagged in `Context.AirborneSquads` (never group members) and routed by a new `DeepStrikeTarget` branch in `CaptureFlag`. Mirrors the existing MG/artillery trickle and capper-routing patterns.

**Tech Stack:** Lua (Men of War Assault Squad 2 bot script). Offline test harness runs specs with `lua tests/<name>_spec.lua` from `resource/script/multiplayer`.

## Global Constraints

- All edits are in `resource/script/multiplayer/bot.lua`; tests in `resource/script/multiplayer/tests/airborne_spec.lua`.
- Run tests from the `resource/script/multiplayer` directory (the harness sets `MROOT="."`).
- Spawn API is `BotApi.Commands:Spawn(unitName, squadSize)` — no location parameter.
- Tunables (verbatim): `DeepStrikePct = 0.65`, `DeepStrikeIntervalSec = 180`, `DeepStrikeCap = 2`.
- Airborne units are roster rows with `class == UnitClass.Airborne` (the `*_drop(...)` units).
- Enemy base flags are `Context.FlagLabel[name].sector == "ENEMY"`; depth is `Context.FlagLabel[name].axis` (team-oriented, high = deep in enemy territory).
- Harness `army = "ger"`; the ger roster has `elites_44_drop(ger)` (Airborne, priority 2.0). Harness `team = 1`, `enemyTeam = 2`.
- All 11 existing specs must still pass after every task.

---

### Task 1: Constants, Context fields, and spawn/count helpers

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (constants near line 77; Context fields near lines 22 and 1276; helpers after `LiveArtyCount` near line 386; `EnemyFlagPct` after `FlagDeficit` near line 692)
- Test: `resource/script/multiplayer/tests/airborne_spec.lua` (create)

**Interfaces:**
- Produces:
  - `GetAirborneUnit()` -> a roster table row with `class == UnitClass.Airborne`, drawn by priority, or `nil`.
  - `LiveAirborneCount()` -> integer count of `Context.AirborneSquads` entries.
  - `EnemyFlagPct()` -> number in `[0,1]`, `enemyFlags / totalFlags`, `0` when no flags.
  - Constants `DeepStrikePct`, `DeepStrikeIntervalSec`, `DeepStrikeCap`.
  - `Context.AirborneSquads` (table, `squadId -> true`), `Context.LastDeepStrikeTime` (number).

- [ ] **Step 1: Add the constants.** After line 77 (`local ArtyCap = 1 ...`), before line 81 (`local ArtyReach`), insert:

```lua
local DeepStrikePct        = 0.65   -- trigger deep-strike when enemy holds > this share of all flags
local DeepStrikeIntervalSec = 180   -- seconds between airborne drops (frontline-equivalent of c(900) x 0.2)
local DeepStrikeCap        = 2      -- max live airborne squads kept fielded
```

- [ ] **Step 2: Add the Context fields.** After line 22 (`LastArtyTime = 0, ...`), insert:

```lua
	LastDeepStrikeTime = 0, -- Elapsed() at last airborne deep-strike drop
	AirborneSquads = {},    -- squadId -> true, elite airborne squads sent at enemy bases
```

- [ ] **Step 3: Add the spawn/count helpers.** After `LiveArtyCount()` (ends near line 386), insert:

```lua
-- An airborne (paradrop) unit from the current faction roster, drawn by priority, or nil.
function GetAirborneUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local drops = {}
	for i, t in pairs(roster) do
		if t.class == UnitClass.Airborne then table.insert(drops, t) end
	end
	if #drops == 0 then return nil end
	return GetRandomItem(drops, function(t) return t.priority end)
end

-- Live airborne squads we have fielded (the deep-strike cap).
function LiveAirborneCount()
	local n = 0
	for squadId in pairs(Context.AirborneSquads) do n = n + 1 end
	return n
end
```

- [ ] **Step 4: Add `EnemyFlagPct`.** After `FlagDeficit()` (ends near line 692), insert:

```lua
-- Share of all flags currently held by the enemy, in [0,1]. 0 when there are no flags.
function EnemyFlagPct()
	local enemy, total = 0, 0
	for i, flag in pairs(BotApi.Scene.Flags) do
		total = total + 1
		if IsEnemyFlag(flag) then enemy = enemy + 1 end
	end
	if total == 0 then return 0 end
	return enemy / total
end
```

- [ ] **Step 5: Write the failing test.** Create `resource/script/multiplayer/tests/airborne_spec.lua`:

```lua
dofile((arg[0]:gsub("airborne_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- EnemyFlagPct: enemy / total, 0 when empty.
BotApi.Scene.Flags = {}
eq(EnemyFlagPct(), 0, "no flags -> 0")
BotApi.Scene.Flags = {
	{ name = "f1", occupant = 2 }, { name = "f2", occupant = 2 },
	{ name = "f3", occupant = 2 }, { name = "f4", occupant = 1 },
}
eq(EnemyFlagPct(), 0.75, "3 of 4 enemy -> 0.75")
print("EnemyFlagPct OK")

-- GetAirborneUnit: returns an Airborne row from the harness ger roster.
local u = GetAirborneUnit()
assert(u ~= nil, "GetAirborneUnit returned nil")
eq(u.class, UnitClass.Airborne, "GetAirborneUnit class")
-- nil when the roster has no airborne.
local saved = Purchases[1].Units["ger"]
Purchases[1].Units["ger"] = { { priority = 1.0, class = UnitClass.Infantry, unit = "x" } }
eq(GetAirborneUnit(), nil, "GetAirborneUnit nil when no airborne")
Purchases[1].Units["ger"] = saved
print("GetAirborneUnit OK")

-- LiveAirborneCount: counts AirborneSquads entries.
Context.AirborneSquads = { [11] = true, [12] = true }
eq(LiveAirborneCount(), 2, "LiveAirborneCount")
Context.AirborneSquads = {}
eq(LiveAirborneCount(), 0, "LiveAirborneCount empty")
print("airborne helpers OK")
```

- [ ] **Step 6: Run the test to verify it passes.**

Run: `cd resource/script/multiplayer && lua tests/airborne_spec.lua`
Expected: prints `EnemyFlagPct OK`, `GetAirborneUnit OK`, `airborne helpers OK` with no error.

- [ ] **Step 7: Run the full suite.**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" >/dev/null 2>&1 && echo "PASS $f" || echo "FAIL $f"; done`
Expected: all 12 specs PASS.

- [ ] **Step 8: Commit.**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/airborne_spec.lua
git commit -m "Airborne deep-strike: constants, context, spawn/count helpers"
```

---

### Task 2: DeepStrikeTarget (furthest enemy base, then main group target)

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (add after `ArtilleryTargetFlag`, which ends near line 290 in the artillery helper block — place it just before `IsDefender`)
- Test: `resource/script/multiplayer/tests/airborne_spec.lua` (append)

**Interfaces:**
- Consumes: `Context.FlagLabel[name].sector`, `Context.FlagLabel[name].axis`, `IsEnemyFlag`, `Context.Groups`.
- Produces: `DeepStrikeTarget()` -> flag-name string of the furthest enemy-held `sector=="ENEMY"` flag (max `axis`, tiebreak by name ascending); when no enemy base remains, `Context.Groups[1] and Context.Groups[1].target`; otherwise `nil`.

Note: the spec lists a distance tiebreak; this implementation uses a name tiebreak instead. Axis values are effectively unique per flag, so the tiebreak rarely fires, and a name tiebreak keeps the function deterministic across teammates without scanning coords.

- [ ] **Step 1: Write the failing test.** Append to `tests/airborne_spec.lua`:

```lua
-- DeepStrikeTarget: pick the FURTHEST enemy-held ENEMY-sector flag (max axis).
Context.Groups = {}
Context.FlagLabel = {
	eNear = { sector = "ENEMY", axis = 0.60 },
	eDeep = { sector = "ENEMY", axis = 0.90 },
	mid   = { sector = "CONTESTED", axis = 0.50 },
	ours  = { sector = "OWN", axis = 0.10 },
}
BotApi.Scene.Flags = {
	{ name = "eNear", occupant = 2 },  -- enemy-held enemy base
	{ name = "eDeep", occupant = 2 },  -- enemy-held enemy base, deeper
	{ name = "mid",   occupant = 2 },  -- enemy-held but not a base (CONTESTED)
	{ name = "ours",  occupant = 1 },
}
eq(DeepStrikeTarget(), "eDeep", "furthest enemy base first")

-- After the deepest base is taken (now ours), the next-furthest base is chosen.
BotApi.Scene.Flags = {
	{ name = "eNear", occupant = 2 },
	{ name = "eDeep", occupant = 1 },  -- captured
	{ name = "mid",   occupant = 2 },
	{ name = "ours",  occupant = 1 },
}
eq(DeepStrikeTarget(), "eNear", "chain to next-furthest enemy base")

-- No enemy base left -> the main group target.
Context.Groups = { [1] = { target = "mainObjective" } }
BotApi.Scene.Flags = {
	{ name = "eNear", occupant = 1 },
	{ name = "eDeep", occupant = 1 },
	{ name = "ours",  occupant = 1 },
}
eq(DeepStrikeTarget(), "mainObjective", "no enemy base -> main group target")

-- No enemy base and no group -> nil.
Context.Groups = {}
eq(DeepStrikeTarget(), nil, "no base, no group -> nil")
print("DeepStrikeTarget OK")
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `cd resource/script/multiplayer && lua tests/airborne_spec.lua`
Expected: FAIL with `attempt to call a nil value (global 'DeepStrikeTarget')`.

- [ ] **Step 3: Implement `DeepStrikeTarget`.** Insert before `function IsDefender(squad)`:

```lua
-- The flag an airborne deep-strike squad should attack: the FURTHEST enemy-held flag in
-- the enemy base sector (max team-axis = deepest in enemy territory; tiebreak by name so
-- teammates agree). As each base falls it stops being enemy-held, so successive calls roll
-- inward through the remaining bases. When no enemy base remains, fold into the main group
-- target (Context.Groups[1]); nil if there is nothing to attack.
function DeepStrikeTarget()
	local best, bestAxis
	for i, flag in pairs(BotApi.Scene.Flags) do
		local label = Context.FlagLabel[flag.name]
		if label and label.sector == "ENEMY" and IsEnemyFlag(flag) then
			local axis = label.axis or 0.5
			if not best or axis > bestAxis or (axis == bestAxis and flag.name < best) then
				best, bestAxis = flag.name, axis
			end
		end
	end
	if best then return best end
	return Context.Groups[1] and Context.Groups[1].target
end
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `cd resource/script/multiplayer && lua tests/airborne_spec.lua`
Expected: prints `DeepStrikeTarget OK` (plus the Task 1 lines) with no error.

- [ ] **Step 5: Run the full suite.**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" >/dev/null 2>&1 && echo "PASS $f" || echo "FAIL $f"; done`
Expected: all 12 specs PASS.

- [ ] **Step 6: Commit.**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/airborne_spec.lua
git commit -m "Airborne deep-strike: DeepStrikeTarget furthest-base selection"
```

---

### Task 3: Route airborne squads (CaptureFlag branch, OnGameSpawn tag, cleanup)

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`CaptureFlag` near line 1681; `OnGameSpawn` near line 1732; dead-squad cleanup near line 1565)
- Test: `resource/script/multiplayer/tests/airborne_spec.lua` (append)

**Interfaces:**
- Consumes: `DeepStrikeTarget`, `Context.AirborneSquads`, `FlagAttackable`, `BotApi.Commands:CaptureFlag`.
- Produces: airborne squads (tagged in `Context.AirborneSquads`) route to `DeepStrikeTarget()`; `OnGameSpawn` sets the tag on `kind == "airborne"` spawns; dead-squad cleanup clears the tag.

- [ ] **Step 1: Write the failing test.** Append to `tests/airborne_spec.lua`:

```lua
-- CaptureFlag routes a tagged airborne squad to its DeepStrikeTarget.
local routed = nil
BotApi.Commands.CaptureFlag = function(_, squad, flagName) routed = flagName end
Context.SquadGroup = {}
Context.Cappers = {}
Context.FieldUnits = {}
Context.Groups = {}
Context.AirborneSquads = { [21] = true }
Context.FlagLabel = {
	eDeep = { sector = "ENEMY", axis = 0.90 },
	eNear = { sector = "ENEMY", axis = 0.60 },
}
BotApi.Scene.Flags = {
	{ name = "eDeep", occupant = 2 },
	{ name = "eNear", occupant = 2 },
}
routed = nil; CaptureFlag(21)
eq(routed, "eDeep", "airborne routes to furthest enemy base")

-- No enemy base and no group -> no order issued.
BotApi.Scene.Flags = { { name = "eDeep", occupant = 1 }, { name = "eNear", occupant = 1 } }
routed = "UNSET"; CaptureFlag(21)
eq(routed, "UNSET", "airborne issues no order when target nil")
print("CaptureFlag airborne routing OK")

-- OnGameSpawn tags a kind=="airborne" spawn into AirborneSquads.
Context.AirborneSquads = {}
Context.SpawnQueue = { { kind = "airborne", info = { class = UnitClass.Airborne, unit = "elites_44_drop(ger)" } } }
Context.SquadTimers = {}
OnGameSpawn({ squadId = 31 })
eq(Context.AirborneSquads[31], true, "OnGameSpawn tags airborne squad")
print("OnGameSpawn airborne OK")
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `cd resource/script/multiplayer && lua tests/airborne_spec.lua`
Expected: FAIL at `airborne routes to furthest enemy base` (routed is nil, branch not present).

- [ ] **Step 3: Add the airborne branch to `CaptureFlag`.** In `CaptureFlag`, after the group-member block (the `if gi and Context.Groups[gi] ... return end` ending near line 1680) and BEFORE the `-- Cappers chase neutral flags` block, insert:

```lua
	-- Airborne deep-strike squads: drive at the deepest enemy base, then the main target.
	if Context.AirborneSquads[squad] then
		local name = DeepStrikeTarget()
		if name and FlagAttackable(name) then BotApi.Commands:CaptureFlag(squad, name) end
		return
	end
```

- [ ] **Step 4: Add the `kind == "airborne"` case to `OnGameSpawn`.** In `OnGameSpawn`, extend the dispatch chain (after the `elseif d and d.kind == "group" ...` block ending near line 1740) by adding:

```lua
	elseif d and d.kind == "airborne" then
		Context.AirborneSquads[args.squadId] = true
```

So the chain reads `if ... kind == "capper" ... elseif ... kind == "group" ... elseif ... kind == "airborne" then ... end`.

- [ ] **Step 5: Clear the tag in dead-squad cleanup.** In `OnGameQuant`, in the cleanup loop (near line 1565, after `Context.Cappers[squadId] = nil`), add:

```lua
			Context.AirborneSquads[squadId] = nil
```

- [ ] **Step 6: Run the test to verify it passes.**

Run: `cd resource/script/multiplayer && lua tests/airborne_spec.lua`
Expected: prints `CaptureFlag airborne routing OK` and `OnGameSpawn airborne OK` with no error.

- [ ] **Step 7: Run the full suite.**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" >/dev/null 2>&1 && echo "PASS $f" || echo "FAIL $f"; done`
Expected: all 12 specs PASS.

- [ ] **Step 8: Commit.**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/airborne_spec.lua
git commit -m "Airborne deep-strike: route squads, tag on spawn, clear on death"
```

---

### Task 4: DeepStrikeTrickle gate and OnGameQuant wiring

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`DeepStrikeTrickle` defined before `OnGameQuant` near line 1377; call inside `OnGameQuant` after the AT-rifle trickle near line 1557; Context reset near line 1276)
- Test: `resource/script/multiplayer/tests/airborne_spec.lua` (append)

**Interfaces:**
- Consumes: `EnemyFlagPct`, `CurrentPhase`, `Elapsed`, `LiveAirborneCount`, `GetAirborneUnit`, `BotApi.Commands:Spawn`, the three `DeepStrike*` constants, `Context.LastDeepStrikeTime`, `Context.SpawnQueue`, `Context.FailCooldown`, `MaxSquadSize`.
- Produces: `DeepStrikeTrickle()` — when late phase AND `EnemyFlagPct() > DeepStrikePct` AND cooldown elapsed AND `LiveAirborneCount() < DeepStrikeCap`, spawns one airborne unit and queues `{ kind = "airborne", info = u }`.

- [ ] **Step 1: Write the failing test.** Append to `tests/airborne_spec.lua`. `Elapsed()` returns `Context.GameClock` (confirmed in `clock_spec.lua`), so set the clock directly. `ResolvePhases("ger")` puts the late phase after 1500s. Stub `Spawn` to record calls.

```lua
-- DeepStrikeTrickle gate. Elapsed() == Context.GameClock; set it directly.
local spawned = {}
BotApi.Commands.Spawn = function(_, unit, size) spawned[#spawned + 1] = { unit = unit, size = size }; return true end
Context.Phases = ResolvePhases(BotApi.Instance.army)   -- ger: late after 1500s
Context.LastDeepStrikeTime = 0
Context.AirborneSquads = {}
Context.SpawnQueue = {}
Context.FailCooldown = {}

-- Not late yet (t=100): no spawn even when enemy owns everything.
BotApi.Scene.Flags = { { name = "f1", occupant = 2 }, { name = "f2", occupant = 2 } }
Context.GameClock = 100; spawned = {}; DeepStrikeTrickle()
eq(#spawned, 0, "no drop before late phase")

-- Late (t=2000) and enemy holds 100% (>65%): one drop, queued as airborne.
Context.GameClock = 2000; spawned = {}; Context.SpawnQueue = {}; Context.LastDeepStrikeTime = 0
DeepStrikeTrickle()
eq(#spawned, 1, "late + overrun -> one drop")
eq(Context.SpawnQueue[1].kind, "airborne", "queued as airborne")

-- Cooldown blocks an immediate second drop (LastDeepStrikeTime was just set to 2000).
spawned = {}; DeepStrikeTrickle()
eq(#spawned, 0, "cooldown blocks second drop")

-- Below threshold (enemy 50%): no drop even when late + cooldown ready.
Context.LastDeepStrikeTime = 0
BotApi.Scene.Flags = { { name = "f1", occupant = 2 }, { name = "f2", occupant = 1 } }
Context.GameClock = 2000; spawned = {}; DeepStrikeTrickle()
eq(#spawned, 0, "no drop below 65% threshold")
print("DeepStrikeTrickle OK")
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `cd resource/script/multiplayer && lua tests/airborne_spec.lua`
Expected: FAIL with `attempt to call a nil value (global 'DeepStrikeTrickle')`.

- [ ] **Step 3: Implement `DeepStrikeTrickle`.** Insert immediately before `function OnGameQuant()` (near line 1377):

```lua
-- Late-game comeback: when the enemy holds more than DeepStrikePct of all flags, drop an
-- elite airborne squad on its own cooldown (capped). The squad is queued as kind="airborne"
-- so OnGameSpawn tags it for the deep-strike router instead of a group. Mirrors the MG/arty
-- trickle shape; runs as an independent trickle because its trigger differs from theirs.
function DeepStrikeTrickle()
	if Elapsed() - Context.LastDeepStrikeTime < DeepStrikeIntervalSec then return end
	if CurrentPhase(Elapsed()).name ~= "late" then return end
	if EnemyFlagPct() <= DeepStrikePct then return end
	if LiveAirborneCount() >= DeepStrikeCap then return end
	local u = GetAirborneUnit()
	if not u then return end
	Context.LastDeepStrikeTime = Elapsed()
	Context.SpawnInfo = u
	local ok = BotApi.Commands:Spawn(u.unit, MaxSquadSize)
	print("[AISPAWN] DEEPSTRIKE try=" .. tostring(u.unit) .. " ok=" .. tostring(ok)
		.. " pct=" .. string.format("%.2f", EnemyFlagPct()))
	if ok then
		Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "airborne", info = u }
	else
		Context.FailCooldown[u.unit] = Elapsed()
	end
end
```

- [ ] **Step 4: Wire it into `OnGameQuant`.** After the AT-rifle trickle block (the `if Elapsed() - Context.LastAtRifleTime ... end` ending near line 1557) and BEFORE the dead-squad cleanup loop (`for squadId in pairs(Context.FieldUnits) do`), insert:

```lua
	DeepStrikeTrickle()
```

- [ ] **Step 5: Add the Context reset.** In the reset block (near line 1276, after `Context.LastArtyTime = 0`), insert:

```lua
	Context.LastDeepStrikeTime = 0
	Context.AirborneSquads = {}
```

- [ ] **Step 6: Run the test to verify it passes.**

Run: `cd resource/script/multiplayer && lua tests/airborne_spec.lua`
Expected: prints `DeepStrikeTrickle OK` (plus all earlier lines) with no error.

- [ ] **Step 7: Run the full suite.**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" >/dev/null 2>&1 && echo "PASS $f" || echo "FAIL $f"; done`
Expected: all 12 specs PASS.

- [ ] **Step 8: Commit.**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/airborne_spec.lua
git commit -m "Airborne deep-strike: trickle gate and OnGameQuant wiring"
```

---

## Notes for the implementer

- `Elapsed()` returns `Context.GameClock` (see `clock_spec.lua`), so tests set the clock with `Context.GameClock = N`. Everything else uses fields already exercised by `arty_spec.lua` and `capper_spec.lua`.
- Keep the existing artillery/MG trickle style: `print("[AISPAWN] ...")`, `FailCooldown` on spawn failure, `Context.SpawnInfo = u` before `Spawn`.
- Do not let airborne squads become group members: they are queued with no `slot`, so `OnGameSpawn` never assigns `Context.SquadGroup`, and the `CaptureFlag` airborne branch sits before the group/capper/defender branches only by squad tag (the group branch still wins if a squad were somehow both — it cannot be here).
