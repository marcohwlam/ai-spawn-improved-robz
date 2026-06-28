# Wave Phase System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bot's single 4:1 core:tank ratio with time-based phases driving a four-tier unit composition, and make the spawn pool recharge-aware so per-unit cooldowns stop wasting wave attempts.

**Architecture:** `bot.data.lua` gains a per-unit `recharge=N` field (baked from RobZ `.set` `;Nsec`) and a `Phases` config table. `bot.lua` gains `TierOf`, `CurrentPhase`, `DecideTier`, a recharge/armorCap pool filter, and `LastSpawn` cooldown tracking. Selection is now: phase -> per-tier deficit -> weighted pick within tier, gated by armorCap + recharge.

**Tech Stack:** Lua 5.1 (game engine), verified with `luac -p`. Offline tests run with system `lua5.1`/`lua` against pure functions using a stub harness.

## Global Constraints

- Lua 5.1 only. No external libraries. Every edited Lua file must pass `luac -p` with no output.
- Read-only BotApi. No manpower-balance read; "out of manpower" is inferred from consecutive Spawn failures (already implemented).
- Engine accepts ~1 Spawn per quant; wave spawns are spread across quants (already implemented).
- `QuantsPerSec = 70` (verified quant rate).
- Light/medium tank boundary: recharge `550` seconds. `TierOf`: infantry / light / medium / heavy, else `nil` (aux).
- Phase time bands (seconds): EARLY `0-180`, MID `180-480`, LATE `480+`.
- Phase composition targets (heavy:medium:light:infantry): EARLY `0:0:1:4`, MID `0:1:2:4`, LATE `1:1:2:4`.
- Phase budgets: EARLY `12`, MID `20`, LATE `30`. Wave spacing constant `7` quants.
- Field correction (never changes phase): `IsLosing()` -> budget x1.5; `EnemyHasTanks()` -> +0.15 deficit to medium & heavy.
- Cappers stay exempt from the ratio and from recharge tracking.

**Paths (absolute):**
- Mod root: `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz`
- `BOT_LUA` = `<modroot>/resource/script/multiplayer/bot.lua`
- `BOT_DATA` = `<modroot>/resource/script/multiplayer/bot.data.lua`
- `SETS` = `/tmp/robzunits/set/multiplayer/units` (extracted RobZ unit definitions)
- `TESTS` = `<modroot>/resource/script/multiplayer/tests` (new; offline harness)

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `bot.data.lua` | Unit roster + `recharge=` per unit + `Phases` config table | Modify |
| `bot.lua` | `TierOf`, `CurrentPhase`, `DecideTier`, pool filter, `LastSpawn`, wave/log wiring | Modify |
| `tests/phase_spec.lua` | Offline assertions for pure functions (`TierOf`, `DecideTier`, `CurrentPhase`) | Create |
| `tests/harness.lua` | Stub `require` + `BotApi`, load `bot.lua`, expose globals | Create |

`DecideTier`, `TierOf`, and `CurrentPhase` are written as **pure functions** (all engine
data passed in as arguments) so they are testable offline without the engine.

---

## Task 1: Bake `recharge=` into bot.data.lua and remove `unlock=`

**Files:**
- Modify: `BOT_DATA` (every `unit="..."` line)
- Read: `SETS/**/*.set`

**Interfaces:**
- Produces: every roster entry has `recharge=<seconds>` (integer, `0` for infantry/aux and any unit with no `;Nsec`). The `unlock=` field is removed from every entry.

- [ ] **Step 1: Back up the data file**

```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.data.lua" /tmp/bot.data.pre_recharge.lua
```

- [ ] **Step 2: Generate the unit -> recharge map from the .set files**

Create `/tmp/gen_recharge.sh` with this content, then run it. It scans every `.set`
line that has a trailing `;Nsec` comment, extracts the leading quoted unit name and the
seconds, and writes `name<TAB>seconds`. Vehicle names are unique enough to map directly.

```bash
#!/usr/bin/env bash
set -euo pipefail
SETS="/tmp/robzunits/set/multiplayer/units"
grep -rhoE '^\{"[^"]+".*;[0-9]+sec' "$SETS" 2>/dev/null \
  | sed -E 's/^\{"([^"]+)".*;([0-9]+)sec.*/\1\t\2/' \
  | sort -u > /tmp/recharge_map.tsv
echo "rows: $(wc -l < /tmp/recharge_map.tsv)"
```

Run:
```bash
bash /tmp/gen_recharge.sh
```
Expected: prints `rows: <N>` with N in the hundreds. Sanity check three known values:
```bash
grep -E '^(pz2l|cromwell_mk_vi|is2)\b' /tmp/recharge_map.tsv
```
Expected: `pz2l` -> `420`, `cromwell_mk_vi` -> `750`, `is2` -> `2160` (or close per data).

- [ ] **Step 3: Rewrite bot.data.lua — replace `unlock=N` with `recharge=N`**

Create `/tmp/bake_recharge.lua` and run it with `lua`/`lua5.1`. It loads the TSV map,
then for every `unit="X"` line replaces an existing `unlock=<n>` token (and trailing
optional comma/space) with `recharge=<map[X] or 0>`; if no `unlock=` token exists it
inserts `recharge=` right after the `unit="X",` token.

```lua
local DATA = "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.data.lua"
local MAP  = "/tmp/recharge_map.tsv"

local recharge = {}
for line in io.lines(MAP) do
  local name, sec = line:match("^(.-)\t(%d+)$")
  if name then recharge[name] = tonumber(sec) end
end

local out = {}
for line in io.lines(DATA) do
  local name = line:match('unit="([^"]+)"')
  if name then
    local r = recharge[name] or 0
    -- drop any existing unlock=<n> (with optional following ", ")
    line = line:gsub("%s*unlock=%d+,?", "")
    -- ensure a single recharge=<n> right after the unit="..." token
    line = line:gsub("(unit=\"[^\"]+\",)", "%1 recharge=" .. r .. ",", 1)
    -- if unit had no trailing comma form, fall back: insert before closing brace
    if not line:match("recharge=") then
      line = line:gsub("}%s*,?%s*$", " recharge=" .. r .. "},")
    end
  end
  out[#out+1] = line
end

local f = assert(io.open(DATA, "w"))
f:write(table.concat(out, "\n"))
if not out[#out]:match("\n$") then f:write("\n") end
f:close()
print("rewrote " .. #out .. " lines")
```

Run:
```bash
lua5.1 /tmp/bake_recharge.lua || lua /tmp/bake_recharge.lua
```
Expected: `rewrote <N> lines`.

- [ ] **Step 4: Verify syntax and spot-check the bake**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
luac -p bot.data.lua && echo OK
grep -nE 'unit="pz2l"|unit="riflemans\(eng\)"|unlock=' bot.data.lua | head
```
Expected: `OK`. `pz2l` line shows `recharge=420` and NO `unlock=`. `riflemans(eng)` shows `recharge=0`. The `grep ... unlock=` part returns no rows (all `unlock=` removed).

- [ ] **Step 5: Commit**

Not a git repo (`git: false` in this environment). Skip commit; instead snapshot:
```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.data.lua" /tmp/bot.data.post_recharge.lua
```

---

## Task 2: Add the `Phases` config table to bot.data.lua

**Files:**
- Modify: `BOT_DATA` (top of file, after the `UnitClass` table)

**Interfaces:**
- Produces: global `Phases` (array of 3 phase tables, ordered early->late) with fields
  `name`, `upto` (seconds, last is huge), `targets` (table tier->weight), `budget`,
  `armorCap` (`"light"|"medium"|"heavy"`).

- [ ] **Step 1: Insert the Phases table**

Add immediately after the closing `}` of the `UnitClass` table in `bot.data.lua`:

```lua
-- Wave phase config. `upto` is the exclusive upper time bound in seconds; the last
-- phase uses a huge bound. `targets` is the desired composition weight per tier;
-- only tiers listed participate. `armorCap` is the heaviest tier allowed to spawn.
Phases = {
	{ name = "early", upto = 180,        targets = {                       light = 1, infantry = 4 }, budget = 12, armorCap = "light"  },
	{ name = "mid",   upto = 480,        targets = {            medium = 1, light = 2, infantry = 4 }, budget = 20, armorCap = "medium" },
	{ name = "late",  upto = 1000000000, targets = { heavy = 1, medium = 1, light = 2, infantry = 4 }, budget = 30, armorCap = "heavy"  },
}

-- Tier rank for the armorCap gate (higher = heavier). Aux units are not gated here.
TierRank = { infantry = 0, light = 1, medium = 2, heavy = 3 }

-- Recharge seconds at/above which a class=Tank unit counts as medium (else light).
TierMediumRecharge = 550
```

- [ ] **Step 2: Verify syntax**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
luac -p bot.data.lua && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Snapshot**

```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.data.lua" /tmp/bot.data.post_phases.lua
```

---

## Task 3: Offline test harness + `TierOf` + four-tier `GetFieldCounts`

**Files:**
- Create: `TESTS/harness.lua`
- Create: `TESTS/phase_spec.lua`
- Modify: `BOT_LUA` (add `TierOf`, rewrite `GetFieldCounts`)

**Interfaces:**
- Produces: `TierOf(entry) -> "infantry"|"light"|"medium"|"heavy"|nil`.
- Produces: `GetFieldCounts() -> { heavy, medium, light, infantry, aux, total, antitank }`
  counting `Context.FieldUnits` by `TierOf`, skipping cappers; `aux` counts `TierOf==nil`.

- [ ] **Step 1: Write the harness**

Create `TESTS/harness.lua`. It stubs `require` (to load the real `bot.data.lua`) and
`BotApi` (so the `Subscribe` calls at the bottom of `bot.lua` do not error), then loads
`bot.lua`, exposing its global functions.

```lua
-- Offline harness: load bot.lua without the game engine.
local MROOT = "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"

local realRequire = require
require = function(mod)
	if tostring(mod):find("bot%.data") then
		return dofile(MROOT .. "/bot.data.lua")
	end
	return realRequire(mod)
end

local noop = function() end
BotApi = {
	Events = { Subscribe = noop, GameStart = 1, GameEnd = 2, Quant = 3, NonQuant = 4, GameSpawn = 5,
	           SetTimer = noop, KillTimer = noop, SetQuantTimer = noop, KillQuantTimer = noop },
	Commands = { Income = function() return 5 end, EnemyHasTanks = function() return false end,
	             Spawn = function() return true end, CaptureFlag = noop, SayChat = noop },
	Instance = { team = 1, enemyTeam = 2, army = "ger", teamSize = 8, hostId = 1, playerId = 1 },
	Scene = { Flags = {}, Squads = {}, IsSquadExists = function() return true end },
}

dofile(MROOT .. "/bot.lua")
return _G
```

- [ ] **Step 2: Write failing tests for TierOf**

Create `TESTS/phase_spec.lua`:

```lua
dofile((arg[0]:gsub("phase_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- TierOf
eq(TierOf({class = UnitClass.Infantry}), "infantry", "rifle is infantry")
eq(TierOf({class = UnitClass.Infantry, flame = true}), nil, "flamer is aux")
eq(TierOf({class = UnitClass.Tank, recharge = 420}), "light", "pz2l light")
eq(TierOf({class = UnitClass.Tank, recharge = 550}), "medium", "550 is medium")
eq(TierOf({class = UnitClass.Tank, recharge = 950}), "medium", "pz4h medium")
eq(TierOf({class = UnitClass.HeavyTank, recharge = 2160}), "heavy", "tiger heavy")
eq(TierOf({class = UnitClass.Vehicle, recharge = 30}), "light", "halftrack light")
eq(TierOf({class = UnitClass.ATInfantry}), nil, "AT is aux")
eq(TierOf({class = UnitClass.MG}), nil, "MG is aux")
print("TierOf OK")
```

- [ ] **Step 3: Run tests, verify they fail**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
lua5.1 tests/phase_spec.lua || lua tests/phase_spec.lua
```
Expected: error mentioning `TierOf` is nil / attempt to call a nil value (function not defined yet).

- [ ] **Step 4: Implement TierOf and rewrite GetFieldCounts**

In `bot.lua`, replace the existing `CategoryOf` function (currently lines ~139-147) and
the existing `GetFieldCounts` (currently lines ~149-161) with:

```lua
-- Four-tier classification. Aux (AT, MG, sniper, officer, AA, artillery, flamer)
-- returns nil and never counts toward the ratio.
function TierOf(t)
	if t.class == UnitClass.Infantry and not t.flame then
		return "infantry"
	elseif t.class == UnitClass.HeavyTank then
		return "heavy"
	elseif t.class == UnitClass.Tank then
		if (t.recharge or 0) >= TierMediumRecharge then return "medium" else return "light" end
	elseif t.class == UnitClass.Vehicle then
		return "light"
	else
		return nil
	end
end

function GetFieldCounts()
	local c = { heavy = 0, medium = 0, light = 0, infantry = 0, aux = 0, total = 0, antitank = 0 }
	for squadId, entry in pairs(Context.FieldUnits) do
		if Context.Cappers[squadId] then goto continue end -- cappers never count
		c.total = c.total + 1
		local tier = TierOf(entry)
		if tier then c[tier] = c[tier] + 1 else c.aux = c.aux + 1 end
		local cl = entry.class
		if cl == UnitClass.ATInfantry or cl == UnitClass.ATTank
		or cl == UnitClass.Tank or cl == UnitClass.HeavyTank then
			c.antitank = c.antitank + 1
		end
		::continue::
	end
	return c
end
```

- [ ] **Step 5: Run tests, verify TierOf passes**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
luac -p bot.lua && lua5.1 tests/phase_spec.lua || lua tests/phase_spec.lua
```
Expected: `luac` prints nothing, test prints `TierOf OK`.

- [ ] **Step 6: Snapshot**

```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.lua" /tmp/bot.post_tierof.lua
```

---

## Task 4: `CurrentPhase` + `DecideTier` (replace `DecideCategory`)

**Files:**
- Modify: `BOT_LUA` (replace `DecideCategory`, add `CurrentPhase`, `DecideTier`)
- Modify: `TESTS/phase_spec.lua` (append tests)

**Interfaces:**
- Consumes: `Phases`, `TierRank` (from bot.data); `TierOf`, `GetFieldCounts`.
- Produces: `CurrentPhase(elapsedSec) -> phase table` (pure: takes seconds, no Context read).
- Produces: `DecideTier(phase, field, enemyHasTanks, tierEligible) -> tier string`. `field`
  is a counts table; `tierEligible` is a table `tier->bool` of which tiers have a
  spawnable candidate. Pure (no BotApi/Context reads).

- [ ] **Step 1: Append failing tests**

Add to `TESTS/phase_spec.lua` before the final print:

```lua
-- CurrentPhase
eq(CurrentPhase(0).name,   "early", "t0 early")
eq(CurrentPhase(179).name, "early", "179 early")
eq(CurrentPhase(180).name, "mid",   "180 mid")
eq(CurrentPhase(479).name, "mid",   "479 mid")
eq(CurrentPhase(480).name, "late",  "480 late")
eq(CurrentPhase(99999).name, "late","late stays late")

-- DecideTier: empty field, all eligible -> infantry has the largest absolute deficit
local late = CurrentPhase(480)
local empty = { heavy = 0, medium = 0, light = 0, infantry = 0, aux = 0 }
local allOk = { heavy = true, medium = true, light = true, infantry = true }
eq(DecideTier(late, empty, false, allOk), "infantry", "empty field wants infantry first")

-- DecideTier: infantry satisfied -> next deficit is light (weight 2)
local f2 = { heavy = 0, medium = 0, light = 0, infantry = 4, aux = 0 }
eq(DecideTier(late, f2, false, allOk), "light", "after infantry, light")

-- DecideTier: only infantry eligible (tanks on cooldown) -> infantry
eq(DecideTier(late, f2, false, { infantry = true }), "infantry", "fallback to eligible tier")

-- DecideTier: enemy tanks bumps medium/heavy deficit
local f3 = { heavy = 1, medium = 1, light = 2, infantry = 4, aux = 0 }
local pick = DecideTier(late, f3, true, allOk)
assert(pick == "medium" or pick == "heavy", "enemy tanks leans armor, got " .. tostring(pick))
print("phase OK")
```

- [ ] **Step 2: Run, verify failure**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
lua5.1 tests/phase_spec.lua || lua tests/phase_spec.lua
```
Expected: error on `CurrentPhase` being nil (not yet defined).

- [ ] **Step 3: Implement CurrentPhase and DecideTier**

In `bot.lua`, replace `DecideCategory` (currently lines ~232-245) with:

```lua
-- Pick the active phase for an elapsed time in seconds.
function CurrentPhase(elapsedSec)
	for i = 1, #Phases do
		if elapsedSec < Phases[i].upto then return Phases[i] end
	end
	return Phases[#Phases]
end

-- Choose the tier whose share is furthest below its target, among phase-allowed tiers
-- that actually have a spawnable candidate. enemyHasTanks adds a small armor lean.
-- Pure: all inputs passed in, no BotApi/Context reads.
function DecideTier(phase, field, enemyHasTanks, tierEligible)
	local targets = phase.targets
	local totalT = 0
	for _, w in pairs(targets) do totalT = totalT + w end
	local totalF = 0
	for tier in pairs(targets) do totalF = totalF + (field[tier] or 0) end

	local best, bestDeficit = nil, -1e9
	for tier, w in pairs(targets) do
		local targetShare = w / totalT
		local actualShare = (totalF > 0) and ((field[tier] or 0) / totalF) or 0
		local deficit = targetShare - actualShare
		if enemyHasTanks and (tier == "medium" or tier == "heavy") then
			deficit = deficit + 0.15
		end
		if (tierEligible[tier]) and deficit > bestDeficit then
			best, bestDeficit = tier, deficit
		end
	end
	return best or "infantry"
end
```

- [ ] **Step 4: Run, verify pass**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
luac -p bot.lua && (lua5.1 tests/phase_spec.lua || lua tests/phase_spec.lua)
```
Expected: `TierOf OK` then `phase OK`.

- [ ] **Step 5: Snapshot**

```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.lua" /tmp/bot.post_decidetier.lua
```

---

## Task 5: Pool filter (armorCap + recharge) and tier candidate selection in `GetUnitToSpawn`

**Files:**
- Modify: `BOT_LUA` (`GetUnitToSpawn`, currently lines ~264-317)

**Interfaces:**
- Consumes: `TierOf`, `CurrentPhase`, `DecideTier`, `TierRank`, `Context.LastSpawn`,
  `Context.MatchQuants`, `QuantsPerSec`.
- Produces: `GetUnitToSpawn(units)` returns a chosen entry honoring phase armorCap, recharge cooldown, tier deficit, and aux injection.

- [ ] **Step 1: Replace GetUnitToSpawn body**

Replace the whole `GetUnitToSpawn` function with:

```lua
function GetUnitToSpawn(units)
	if not units then return nil end

	local teamSize = BotApi.Instance.teamSize
	local income = BotApi.Commands:Income(BotApi.Instance.playerId)
	local enemyHasTanks = BotApi.Commands:EnemyHasTanks()
	local elapsed = Context.MatchQuants / QuantsPerSec
	local phase = CurrentPhase(elapsed)
	local capRank = TierRank[phase.armorCap]

	-- Build the eligible pool: affordable, off-cooldown, and within the phase armor cap.
	local pool = {}
	for i, unit in pairs(units) do
		local affordable = teamSize >= (unit.min_team or 0)
			and income >= (unit.min_income or -1)
		local last = Context.LastSpawn[unit.unit]
		local cooled = (last == nil)
			or (Context.MatchQuants - last >= (unit.recharge or 0) * QuantsPerSec)
		local tier = TierOf(unit)
		local capOk = (tier == nil) or (TierRank[tier] <= capRank) -- aux not capped
		if affordable and cooled and capOk then
			table.insert(pool, unit)
		end
	end
	if #pool == 0 then return nil end

	-- Aux injection (unchanged mechanism): aux is separate from the four-tier ratio.
	local field = GetFieldCounts()
	local armyCount = field.heavy + field.medium + field.light + field.infantry
	local function collectAux()
		local out = {}
		for i, t in pairs(pool) do
			if TierOf(t) == nil and AuxEligible(t, enemyHasTanks) then
				if not (t.class == UnitClass.Airborne and Context.SpawnFlags.isAirborne)
				and not (t.class == UnitClass.Rare and Context.SpawnFlags.isRare)
				and t.class ~= UnitClass.Howitzrer then
					table.insert(out, t)
				end
			end
		end
		return out
	end
	if field.aux < armyCount / AuxDivisor and math.random() < AuxChance then
		local aux = collectAux()
		if #aux > 0 then
			return GetRandomItem(aux, function(t) return t.priority end)
		end
	end

	-- Which tiers have a candidate in the pool right now?
	local tierEligible, byTier = {}, { heavy = {}, medium = {}, light = {}, infantry = {} }
	for i, t in pairs(pool) do
		local tier = TierOf(t)
		if tier then
			tierEligible[tier] = true
			table.insert(byTier[tier], t)
		end
	end

	local tier = DecideTier(phase, field, enemyHasTanks, tierEligible)
	local cands = byTier[tier]
	if not cands or #cands == 0 then cands = pool end

	return GetRandomItem(cands, function(t)
		local mul = 1.0
		if enemyHasTanks then
			if t.class == UnitClass.HeavyTank then mul = mul * 1.5
			elseif t.class == UnitClass.ATTank then mul = mul * 1.5
			elseif t.class == UnitClass.ATInfantry then mul = mul * 1.5 end
		end
		return t.priority * mul
	end)
end
```

- [ ] **Step 2: Verify syntax**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
luac -p bot.lua && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Verify pure-function tests still pass (no regression)**

```bash
lua5.1 tests/phase_spec.lua || lua tests/phase_spec.lua
```
Expected: `TierOf OK` then `phase OK`.

- [ ] **Step 4: Snapshot**

```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.lua" /tmp/bot.post_pool.lua
```

---

## Task 6: Wave wiring — `LastSpawn` tracking, phase budget, IsLosing multiplier

**Files:**
- Modify: `BOT_LUA` (`Context` table, `OnGameStart`, `OnGameQuant` wave start, `OnGameSpawn`)

**Interfaces:**
- Consumes: `CurrentPhase`, `IsLosing`, `Context.MatchQuants`.
- Produces: `Context.LastSpawn` table maintained; wave `budget`/`spacing` come from the current phase; budget x1.5 when losing.

- [ ] **Step 1: Add LastSpawn to the Context table**

In the `Context` table near the top of `bot.lua`, add the field (next to `Cappers`):

```lua
	LastSpawn = {},    -- unit name -> MatchQuants of its last successful spawn (recharge gate)
```

- [ ] **Step 2: Reset LastSpawn in OnGameStart**

In `OnGameStart`, add alongside the other resets:

```lua
	Context.LastSpawn = {}
```

- [ ] **Step 3: Record LastSpawn on spawn**

In `OnGameSpawn`, inside the non-capper branch (the `else` that sets `FieldUnits`), after
`Context.FieldUnits[args.squadId] = Context.SpawnInfo`, add:

```lua
		if Context.SpawnInfo then Context.LastSpawn[Context.SpawnInfo.unit] = Context.MatchQuants end
```

- [ ] **Step 4: Drive wave budget/spacing from the phase**

In `OnGameQuant`, at the wave-start block (where `Context.WaveRemaining = WaveBudget`),
replace the fixed assignment with phase-driven values plus the losing multiplier:

```lua
	if Context.QuantCount >= WaveInterval and Context.WaveRemaining == 0 then
		Context.QuantCount = 0
		local phase = CurrentPhase(Context.MatchQuants / QuantsPerSec)
		local budget = phase.budget
		if IsLosing() then budget = math.floor(budget * 1.5) end
		Context.WaveRemaining = budget
		Context.WaveFails = 0
		Context.WaveCooldown = 0
		print("[AISPAWN] WAVE mq=" .. tostring(Context.MatchQuants)
			.. " t=" .. tostring(math.floor(Context.MatchQuants / QuantsPerSec))
			.. " phase=" .. phase.name .. " budget=" .. tostring(budget))
	end
```

Leave `WaveSpawnSpacing` as the existing constant `7` (spacing is constant per the spec).
The module-level `WaveBudget` constant is now unused; remove its declaration line and its
comment to avoid confusion.

- [ ] **Step 5: Verify syntax and no-regression**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
luac -p bot.lua && (lua5.1 tests/phase_spec.lua || lua tests/phase_spec.lua)
```
Expected: `luac` silent, tests print `TierOf OK` / `phase OK`.

- [ ] **Step 6: Snapshot**

```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.lua" /tmp/bot.post_wave.lua
```

---

## Task 7: Debug logging — phase + four tier counts

**Files:**
- Modify: `BOT_LUA` (per-spawn debug print in `OnGameQuant`)

**Interfaces:**
- Produces: per-spawn log line with `phase=`, `tier=`, and `H=/Md=/L=/I=` counts.

- [ ] **Step 1: Update the per-spawn print**

In `OnGameQuant`, in the in-wave spawn block, replace the existing per-spawn `print(...)`
(the one starting `"[AISPAWN] mq="`) with:

```lua
				local field = GetFieldCounts()
				print("[AISPAWN] mq=" .. tostring(Context.MatchQuants)
					.. " phase=" .. CurrentPhase(Context.MatchQuants / QuantsPerSec).name
					.. " income=" .. tostring(BotApi.Commands:Income(BotApi.Instance.playerId))
					.. " squads=" .. tostring(LiveSquadCount())
					.. " H=" .. tostring(field.heavy)
					.. " Md=" .. tostring(field.medium)
					.. " L=" .. tostring(field.light)
					.. " I=" .. tostring(field.infantry)
					.. " A=" .. tostring(field.aux)
					.. " tier=" .. tostring(TierOf(Context.SpawnInfo))
					.. " try=" .. tostring(Context.SpawnInfo.unit)
					.. " ok=" .. tostring(ok))
```

- [ ] **Step 2: Verify syntax**

```bash
cd "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer"
luac -p bot.lua && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Final full check**

```bash
luac -p bot.lua && luac -p bot.data.lua && (lua5.1 tests/phase_spec.lua || lua tests/phase_spec.lua) && echo ALL_OK
```
Expected: `TierOf OK`, `phase OK`, `ALL_OK`.

- [ ] **Step 4: Snapshot**

```bash
cp "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/bot.lua" /tmp/bot.post_logging.lua
```

---

## Manual in-game verification (after all tasks)

Play one match, then review the game log (`.../my games/men of war - assault squad 2/log/game.log`) for:
1. `phase=early` before ~180s, `phase=mid` 180-480s, `phase=late` after 480s.
2. Tier counts trending to targets: EARLY mostly `I` with some `L`; MID adds `Md`; LATE adds `H`.
3. Light tanks (e.g. `pz2l`) actually appearing in `try=` lines during EARLY/MID.
4. Waves not ending early from recharge failures (fewer `ok=false` clusters than before).
5. Leftover manpower near zero at match end (no 3000+ idle pool).

If a tier never appears or a faction misbehaves, adjust `Phases` targets/budgets or the
`550` boundary in `bot.data.lua` only.

---

## Self-review notes

- Spec coverage: phases (T2), tiers (T3), DecideTier+CurrentPhase (T4), armorCap+recharge pool (T5), LastSpawn+budget+IsLosing (T6), logging (T7), recharge data + unlock removal (T1). All spec sections mapped.
- Cappers: untouched; still skipped in `GetFieldCounts` (T3) and never recorded in `LastSpawn` (T6 only records non-capper branch).
- Field-correction EnemyHasTanks +0.15 applies only to tiers that are also `tierEligible` (T4/T5), which already enforces armorCap, so EARLY never picks medium/heavy.
