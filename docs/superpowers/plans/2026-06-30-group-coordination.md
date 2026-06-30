# Group Coordination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make groups retarget preemptively and re-path immediately, split the force into a main and a sub prong on adjacent flags, and preserve the army-wide tier ratio with per-group armor distribution.

**Architecture:** All changes live in one file, `resource/script/multiplayer/bot.lua`. Task 1 adds tier-preemptive retargeting and an immediate re-order helper. Task 2 raises the group count to two with per-group sizes and an adjacency-based sub-group target. Task 3 switches the tier-ratio decision to army-wide counts and replaces the global armor front-load counter with a per-group, deficit-gated one. Tests are appended to `tests/routing_spec.lua` and `tests/integration_spec.lua`.

**Tech Stack:** Lua 5.1 (game engine embed). Offline test harness at `tests/harness.lua`.

## Global Constraints

- Lua 5.1 only. No `goto`. No `continue`. 32-bit engine.
- Run a spec from the multiplayer dir: `cd resource/script/multiplayer && lua tests/<name>_spec.lua`. A spec prints `... OK` and exits 0 on pass; an `error()` aborts with a stack trace.
- Comments and identifiers in professional English. No em dashes. Avoid the words delve, robust, comprehensive, nuanced, leverage.
- Do not change wave cadence, budgets, `waveMult`, `squadCap`, the aux cycle, or the defender/capper/artillery trickles. They are out of scope.
- `MaxSquadSize`, `OrderRotationPeriod` live in `bot.data.lua`; do not change them.

---

### Task 1: Tier-preemption retarget and immediate re-order

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`PickGroupTarget`, `UpdateGroupTargets`; add `FlagTier`, `ReorderGroup`)
- Test: `resource/script/multiplayer/tests/routing_spec.lua` (append)

**Interfaces:**
- Produces:
  - `FlagTier(name) -> number|nil` : the attack tier (1, 2, or 3) for a flag, or `nil` when the flag is not a valid candidate (neither enemy-held nor a recently-lost neutral).
  - `ReorderGroup(gi)` : re-issue `CaptureFlag` to every live member squad of group `gi`.
  - `PickGroupTarget(excludeName)` : unchanged signature and behavior; now delegates tier classification to `FlagTier`.
  - `UpdateGroupTargets()` : unchanged signature; group 1 now preempts to a strictly lower tier and re-orders on any target change.

**Context for the implementer:**
- `PickGroupTarget` currently classifies each candidate inline. The current body is:
  ```lua
  function PickGroupTarget(excludeName)
  	local team = BotApi.Instance.team
  	local enemy = BotApi.Instance.enemyTeam
  	local best
  	for _, flag in pairs(BotApi.Scene.Flags) do
  		local name = flag.name
  		if name ~= excludeName then
  			local held = flag.occupant == enemy
  			local attacking = flag.occupant ~= team and flag.occupant ~= enemy
  				and Context.LostStamp[name] ~= nil
  			if held or attacking then
  				local label = Context.FlagLabel[name] or {}
  				local owner = Context.FlagOwner[name]
  				local tier, key
  				if label.sector == "OWN" then
  					tier, key = 1, label.axis or 1
  				elseif owner and owner.mine and label.sector == "CONTESTED" and IsFrontier(name) then
  					tier, key = 2, label.axis or 1
  				else
  					local d = NearestOwnedDist(label)
  					if d then
  						tier, key = 3, d
  					else
  						local stamp = Context.LostStamp[name]
  						tier, key = 3, (stamp and -stamp or (1e9 - GetFlagPriority(flag)))
  					end
  				end
  				if not best or tier < best.tier
  				   or (tier == best.tier and key < best.key)
  				   or (tier == best.tier and key == best.key and name < best.name) then
  					best = { name = name, tier = tier, key = key }
  				end
  			end
  		end
  	end
  	Context.LastPickTier = best and best.tier
  	return best and best.name
  end
  ```
- `UpdateGroupTargets` current body:
  ```lua
  function UpdateGroupTargets()
  	local g1 = Context.Groups[1]
  	local g2 = Context.Groups[2]
  	if g1 then
  		local other = g2 and g2.target
  		if not g1.target or not FlagAttackable(g1.target) then
  			local newT = PickGroupTarget(other)
  			if newT and newT ~= g1.target then
  				print("[AISPAWN] GROUP_TARGET id=1 target=" .. tostring(newT)
  					.. " reason=" .. (Context.LostStamp[newT] and "recapture" or "priority")
  					.. " tier=" .. tostring(Context.LastPickTier) .. PidTag())
  			end
  			g1.target = newT
  		end
  	end
  	if g2 then
  		local other = g1 and g1.target
  		if not g2.target or not FlagAttackable(g2.target) then
  			local newT = PickGroupTarget(other)
  			if newT and newT ~= g2.target then
  				print("[AISPAWN] GROUP_TARGET id=2 target=" .. tostring(newT)
  					.. " reason=" .. (Context.LostStamp[newT] and "recapture" or "priority")
  					.. " tier=" .. tostring(Context.LastPickTier) .. PidTag())
  			end
  			g2.target = newT
  		end
  	end
  end
  ```
  Note: Task 2 rewrites the `g2` branch. In this task, only change the `g1` branch and add the two helpers. Leave the `g2` branch as-is so the existing two-group de-confliction still compiles (it is inert while `MaxGroups = 1`).
- `CaptureFlag(squad)` already reads the live group target through `Context.SquadGroup[squad]`. `BotApi.Scene:IsSquadExists(squad)` guards a dead squad. The test harness mocks `BotApi.Commands.CaptureFlag` as a no-op and `IsSquadExists` as `return true`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/routing_spec.lua`, before the final `print("routing OK")` line:

```lua
-- === Task 1: FlagTier, preemption, ReorderGroup ===

-- FlagTier matches the tier the inline classifier produced.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "b", f10 = "b" })   -- f5 OWN-sector held by enemy
LabelFlags(); PartitionFlags()
eq(FlagTier("f5"), 1, "FlagTier: enemy on OWN flag is tier 1")
eq(FlagTier("f10"), 3, "FlagTier: deep enemy flag is tier 3")
eq(FlagTier("f2"), nil, "FlagTier: neutral flag with no LostStamp is not a candidate")

-- Preemption: group 1 holding a tier-3 target switches when a tier-2 flag appears,
-- and ReorderGroup re-issues CaptureFlag to the member squad.
Context.LostStamp = {}
Context.Groups = {}
Context.SquadGroup = { s1 = 1 }
Context.FieldUnits = { s1 = { unit = "x" } }
BotApi.Scene.Flags = bastogne({ f10 = "b" })             -- only deep enemy -> tier 3
LabelFlags(); PartitionFlags()
Context.Groups[1] = { members = { s1 = true }, size = 5, target = "f10", pending = 0 }
local captured = {}
local realCapture = BotApi.Commands.CaptureFlag
BotApi.Commands.CaptureFlag = function(_, squad, flag) captured[squad] = flag end
-- f6 held by a (own base) makes f7 a frontier flag; enemy holds f7 -> tier 2.
BotApi.Scene.Flags = bastogne({ f6 = "a", f7 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
UpdateGroupTargets()
eq(Context.Groups[1].target, "f7", "preempt: tier3 f10 -> tier2 f7")
eq(captured.s1, "f7", "ReorderGroup re-issued capture to member on switch")

-- No preemption within the same tier: a closer tier-3 flag does not displace the
-- current tier-3 target.
Context.Groups = {}
Context.SquadGroup = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })   -- f1,f3 tier-3 enemy
LabelFlags(); PartitionFlags()
Context.Groups[1] = { members = {}, size = 5, target = "f3", pending = 0 }
UpdateGroupTargets()
eq(Context.Groups[1].target, "f3", "same-tier closer candidate does not preempt")
BotApi.Commands.CaptureFlag = realCapture
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: FAIL with an error like `attempt to call global 'FlagTier' (a nil value)`.

- [ ] **Step 3: Add `FlagTier` and refactor `PickGroupTarget`**

Insert `FlagTier` immediately above `PickGroupTarget`, then replace `PickGroupTarget` with the delegating version:

```lua
-- Classify a flag into the attack tier ladder, or nil when it is not a valid
-- candidate (not enemy-held and not a recently-lost neutral).
-- Tier 1: enemy holds/attacks an OWN-sector flag (home invaded).
-- Tier 2: a mine + frontier + CONTESTED flag the enemy holds (our lane front).
-- Tier 3: every other enemy/attacked flag (expand).
function FlagTier(name)
	local team = BotApi.Instance.team
	local enemy = BotApi.Instance.enemyTeam
	local flag
	for _, f in pairs(BotApi.Scene.Flags) do
		if f.name == name then flag = f; break end
	end
	if not flag then return nil end
	local held = flag.occupant == enemy
	local attacking = flag.occupant ~= team and flag.occupant ~= enemy
		and Context.LostStamp[name] ~= nil
	if not (held or attacking) then return nil end
	local label = Context.FlagLabel[name] or {}
	local owner = Context.FlagOwner[name]
	if label.sector == "OWN" then
		return 1
	elseif owner and owner.mine and label.sector == "CONTESTED" and IsFrontier(name) then
		return 2
	else
		return 3
	end
end

-- The group's attack flag, by the FlagTier ladder over candidates, excluding
-- excludeName. Within a tier, lower key wins (tier 1/2 by lane axis, tier 3 by
-- distance to our nearest owned flag, then recapture recency). Sets
-- Context.LastPickTier for logging. Returns nil only when no candidate exists.
function PickGroupTarget(excludeName)
	local best
	for _, flag in pairs(BotApi.Scene.Flags) do
		local name = flag.name
		if name ~= excludeName then
			local tier = FlagTier(name)
			if tier then
				local label = Context.FlagLabel[name] or {}
				local key
				if tier == 1 or tier == 2 then
					key = label.axis or 1
				else
					local d = NearestOwnedDist(label)
					if d then
						key = d
					else
						local stamp = Context.LostStamp[name]
						key = (stamp and -stamp or (1e9 - GetFlagPriority(flag)))
					end
				end
				if not best or tier < best.tier
				   or (tier == best.tier and key < best.key)
				   or (tier == best.tier and key == best.key and name < best.name) then
					best = { name = name, tier = tier, key = key }
				end
			end
		end
	end
	Context.LastPickTier = best and best.tier
	return best and best.name
end
```

- [ ] **Step 4: Add `ReorderGroup`**

Insert near `SetSquadOrder` (anywhere at file scope is fine; place it directly above `UpdateGroupTargets`):

```lua
-- Re-issue the capture order to every live member of a group immediately, so a
-- target change takes effect without waiting for the OrderRotationPeriod timer.
function ReorderGroup(gi)
	local g = Context.Groups[gi]
	if not g then return end
	for squad in pairs(g.members) do
		if BotApi.Scene:IsSquadExists(squad) then
			CaptureFlag(squad)
		end
	end
end
```

- [ ] **Step 5: Add preemption to the `g1` branch of `UpdateGroupTargets`**

Replace the `if g1 then ... end` block (leave the `g2` block untouched) with:

```lua
	if g1 then
		local other = g2 and g2.target
		local newT
		if not g1.target or not FlagAttackable(g1.target) then
			newT = PickGroupTarget(other)
		else
			local cand = PickGroupTarget(other)
			local ct = cand and FlagTier(cand)
			local gt = FlagTier(g1.target)
			if ct and gt and ct < gt then
				newT = cand
			end
		end
		if newT and newT ~= g1.target then
			print("[AISPAWN] GROUP_TARGET id=1 target=" .. tostring(newT)
				.. " reason=" .. (Context.LostStamp[newT] and "recapture" or "priority")
				.. " tier=" .. tostring(Context.LastPickTier) .. PidTag())
			g1.target = newT
			ReorderGroup(1)
		end
	end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: PASS, prints `routing OK`.

- [ ] **Step 7: Run the full suite (no regression)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAIL $f"; done`
Expected: every spec prints its `OK` line, no `FAIL` printed.

- [ ] **Step 8: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/routing_spec.lua
git commit -m "feat: tier-preemptive group retarget with immediate re-order"
```

---

### Task 2: Main and sub groups on adjacent flags

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`GroupSize`/`MaxGroups` constants, `ManageGroups`, `UpdateGroupTargets` g2 branch; add `PickSubTarget`)
- Test: `resource/script/multiplayer/tests/routing_spec.lua` (append)

**Interfaces:**
- Consumes: `FlagTier(name)` from Task 1.
- Produces:
  - `PickSubTarget(mainTarget) -> name|nil` : the attackable objective (FlagTier ~= nil) nearest to `mainTarget` by `FlagLabel` coords, excluding `mainTarget`; returns `mainTarget` when no other objective exists; returns `nil` when `mainTarget` is nil.
  - Group 1 size 5, group 2 size 3, `MaxGroups = 2`.

**Context for the implementer:**
- Current constants:
  ```lua
  local GroupSize = 8   -- target member count per group
  local MaxGroups = 1   -- live groups at a time (1 = single concentrated push; raise for more fronts)
  ```
- Current `ManageGroups`:
  ```lua
  function ManageGroups()
  	if not Context.Groups[1] then
  		local t = PickGroupTarget(nil)
  		Context.Groups[1] = { members = {}, size = GroupSize, target = t, pending = 0,
  			phase = CurrentPhase(Elapsed()).name }
  		print("[AISPAWN] GROUP_NEW id=1 target=" .. tostring(t) .. PidTag())
  	elseif MaxGroups >= 2 and not Context.Groups[2]
  	   and GroupMemberCount(Context.Groups[1]) >= Context.Groups[1].size then
  		local t = PickGroupTarget(Context.Groups[1].target)
  		Context.Groups[2] = { members = {}, size = GroupSize, target = t, pending = 0,
  			phase = CurrentPhase(Elapsed()).name }
  		print("[AISPAWN] GROUP_NEW id=2 target=" .. tostring(t) .. PidTag())
  	end
  end
  ```
- `NearestOwnedDist` shows the coord-distance pattern: `dx*dx + dy*dy` over `Context.FlagLabel[name].x/y`. `LabelFlags()` populates those coords in tests.

- [ ] **Step 1: Write the failing tests**

Append to `tests/routing_spec.lua`, before the final `print("routing OK")`:

```lua
-- === Task 2: PickSubTarget ===

-- Sub picks the objective nearest to the main target, excluding the main target.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })   -- f1,f3 are tier-3 objectives
LabelFlags(); PartitionFlags()
eq(PickSubTarget("f1"), "f3", "sub picks the other objective near main")

-- Only one objective on the map: sub falls back to the main target.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickSubTarget("f10"), "f10", "sub falls back to main target when no other objective")

-- No main target: sub returns nil.
eq(PickSubTarget(nil), nil, "sub returns nil without a main target")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: FAIL with `attempt to call global 'PickSubTarget' (a nil value)`.

- [ ] **Step 3: Add `PickSubTarget`**

Insert directly above `UpdateGroupTargets`:

```lua
-- The sub group's flag: the attackable objective nearest the main group's target
-- (by flag coords), excluding the main target. Falls back to the main target when
-- no other objective exists, so the sub never idles. nil when there is no main.
function PickSubTarget(mainTarget)
	if not mainTarget then return nil end
	local mainLabel = Context.FlagLabel[mainTarget]
	local best, bestKey
	for _, flag in pairs(BotApi.Scene.Flags) do
		local name = flag.name
		if name ~= mainTarget and FlagTier(name) ~= nil then
			local label = Context.FlagLabel[name]
			local key = 1e18
			if mainLabel and mainLabel.x and label and label.x then
				local dx, dy = label.x - mainLabel.x, label.y - mainLabel.y
				key = dx * dx + dy * dy
			end
			if not best or key < bestKey or (key == bestKey and name < best) then
				best, bestKey = name, key
			end
		end
	end
	return best or mainTarget
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: PASS, prints `routing OK`.

- [ ] **Step 5: Set the group counts and per-group sizes**

Replace the two constants:

```lua
local GroupSize = 8   -- target member count per group
local MaxGroups = 1   -- live groups at a time (1 = single concentrated push; raise for more fronts)
```

with:

```lua
local MainGroupSize = 5   -- main prong member count
local SubGroupSize  = 3   -- sub prong member count
local MaxGroups = 2       -- main + sub prongs on adjacent flags
```

In `ManageGroups`, set group 1's size to `MainGroupSize` and group 2's size to `SubGroupSize`:

```lua
function ManageGroups()
	if not Context.Groups[1] then
		local t = PickGroupTarget(nil)
		Context.Groups[1] = { members = {}, size = MainGroupSize, target = t, pending = 0,
			phase = CurrentPhase(Elapsed()).name }
		print("[AISPAWN] GROUP_NEW id=1 target=" .. tostring(t) .. PidTag())
	elseif MaxGroups >= 2 and not Context.Groups[2]
	   and GroupMemberCount(Context.Groups[1]) >= Context.Groups[1].size then
		local t = PickSubTarget(Context.Groups[1].target)
		Context.Groups[2] = { members = {}, size = SubGroupSize, target = t, pending = 0,
			phase = CurrentPhase(Elapsed()).name }
		print("[AISPAWN] GROUP_NEW id=2 target=" .. tostring(t) .. PidTag())
	end
end
```

- [ ] **Step 6: Switch the `g2` branch of `UpdateGroupTargets` to `PickSubTarget`**

Replace the `if g2 then ... end` block with:

```lua
	if g2 then
		local mainT = g1 and g1.target
		local newT = PickSubTarget(mainT)
		if newT and newT ~= g2.target then
			print("[AISPAWN] GROUP_TARGET id=2 target=" .. tostring(newT)
				.. " reason=sub" .. PidTag())
			g2.target = newT
			ReorderGroup(2)
		end
	end
```

- [ ] **Step 7: Add a sub-follows-main retarget test**

Append to `tests/routing_spec.lua`, before the final `print("routing OK")`:

```lua
-- Sub follows main: when the main target changes, the sub re-picks the nearest
-- remaining objective and re-orders its member.
Context.LostStamp = {}
Context.SquadGroup = { s2 = 2 }
Context.FieldUnits = { s2 = { unit = "y" } }
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })
LabelFlags(); PartitionFlags()
Context.Groups = {}
Context.Groups[1] = { members = {}, size = 5, target = "f1", pending = 0 }
Context.Groups[2] = { members = { s2 = true }, size = 3, target = "f1", pending = 0 }
local subCaptured = {}
local realCap2 = BotApi.Commands.CaptureFlag
BotApi.Commands.CaptureFlag = function(_, squad, flag) subCaptured[squad] = flag end
UpdateGroupTargets()
eq(Context.Groups[2].target, "f3", "sub retargets to the other objective near main")
eq(subCaptured.s2, "f3", "sub re-orders its member on retarget")
BotApi.Commands.CaptureFlag = realCap2
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: PASS, prints `routing OK`.

- [ ] **Step 9: Run the full suite (no regression)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAIL $f"; done`
Expected: every spec prints its `OK` line, no `FAIL` printed.

- [ ] **Step 10: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/routing_spec.lua
git commit -m "feat: split force into main and sub prongs on adjacent flags"
```

---

### Task 3: Army-wide ratio and per-group armor distribution

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (`GetUnitToSpawn` field line and armor front-load; `AttemptSpawn` armor decrement; wave-start block; add `TotalGroupCapacity`, `ArmorTargetCount`, `ApportionArmor`)
- Test: `resource/script/multiplayer/tests/routing_spec.lua` (append) and `resource/script/multiplayer/tests/integration_spec.lua` (rewrite)

**Interfaces:**
- Consumes: `MaxGroups`, group `.size` from Task 2; `CycleSize(phase)`, `GetFieldCounts()` (existing).
- Produces:
  - `TotalGroupCapacity() -> number` : sum of live group sizes.
  - `ArmorTargetCount(phase) -> number` : `round((heavyT + mediumT) / CycleSize(phase) * TotalGroupCapacity())`.
  - `ApportionArmor(phase)` : writes `g.armorLead` on each live group, distributing `heavyT + mediumT` by largest remainder over `g.size`.
  - Per-group `g.armorLead` replaces the global `Context.ArmorLead` for front-load.

**Context for the implementer:**
- `GetUnitToSpawn` resolves the fill group and the tier field:
  ```lua
  local g = Context.FillGroup and Context.Groups[Context.FillGroup]
  ...
  local field
  if g then field = CountByTier(g) else field = GetFieldCounts() end
  ```
- `GetUnitToSpawn` armor front-load:
  ```lua
  if Context.ArmorLead > 0 then
  	local lead = nil
  	if #byTier.heavy > 0 then lead = "heavy"
  	elseif #byTier.medium > 0 then lead = "medium" end
  	if lead then
  		return GetRandomItem(byTier[lead], weightOf)
  	else
  		Context.ArmorLead = 0 -- no armor available; resume normal selection
  	end
  end
  ```
- `AttemptSpawn` armor decrement (the fill group `g` is in scope from earlier in the function):
  ```lua
  local utier = TierOf(unit)
  if Context.ArmorLead > 0 and (utier == "heavy" or utier == "medium") then
  	Context.ArmorLead = Context.ArmorLead - 1
  end
  ```
- Wave-start block (inside `OnGameQuant`):
  ```lua
  		-- Front-load the phase's armor quota (heaviest first) before the ratio picker.
  		Context.ArmorLead = (phase.targets.heavy or 0) + (phase.targets.medium or 0)
  		ManageGroups()
  ```
- `GetFieldCounts()` returns `{ heavy, medium, light, rifle, smg, aux, total }` counting all of `Context.FieldUnits` except cappers. It counts the whole army, not one group, which is the point of the change.

- [ ] **Step 1: Write the failing unit tests (apportionment and target count)**

Append to `tests/routing_spec.lua`, before the final `print("routing OK")`:

```lua
-- === Task 3: ApportionArmor and ArmorTargetCount ===

Context.Groups = { [1] = { members = {}, size = 5 }, [2] = { members = {}, size = 3 } }

-- Late composition: armorTotal = heavy1 + medium1 = 2, split 5/3 -> main 1, sub 1.
ApportionArmor({ targets = { heavy = 1, medium = 1, light = 2, rifle = 2, smg = 1 } })
eq(Context.Groups[1].armorLead, 1, "late armor: main gets 1")
eq(Context.Groups[2].armorLead, 1, "late armor: sub gets 1")

-- Mid composition: armorTotal = 1 -> main 1, sub 0 (largest remainder gives the unit to main).
ApportionArmor({ targets = { medium = 1, light = 2, rifle = 2, smg = 1 } })
eq(Context.Groups[1].armorLead, 1, "mid armor: main gets 1")
eq(Context.Groups[2].armorLead, 0, "mid armor: sub gets 0")

-- Early composition: no armor target -> both 0.
ApportionArmor({ targets = { light = 1, rifle = 3, smg = 1 } })
eq(Context.Groups[1].armorLead, 0, "early: main armorLead 0")
eq(Context.Groups[2].armorLead, 0, "early: sub armorLead 0")

-- ArmorTargetCount rounds armorTotal / CycleSize * totalGroupCapacity (capacity 8 here).
eq(ArmorTargetCount({ targets = { heavy = 1, medium = 1, light = 2, rifle = 2, smg = 1 } }), 2,
	"late armor target count is 2")
eq(ArmorTargetCount({ targets = { medium = 1, light = 2, rifle = 2, smg = 1 } }), 1,
	"mid armor target count is 1")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: FAIL with `attempt to call global 'ApportionArmor' (a nil value)`.

- [ ] **Step 3: Add `TotalGroupCapacity`, `ArmorTargetCount`, `ApportionArmor`**

Insert above `ManageGroups`:

```lua
-- Sum of live group sizes: the standing-army size the ratio targets are scaled to.
function TotalGroupCapacity()
	local n = 0
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g then n = n + g.size end
	end
	return n
end

-- How many armor units the standing army should hold for this phase, scaled from
-- the phase's armor share to the total group capacity.
function ArmorTargetCount(phase)
	local armorTotal = (phase.targets.heavy or 0) + (phase.targets.medium or 0)
	local cap = TotalGroupCapacity()
	if cap == 0 then return 0 end
	return math.floor(armorTotal / CycleSize(phase) * cap + 0.5)
end

-- Distribute the phase's armor quota (heavy + medium target weights) across the live
-- groups by the largest-remainder method on group size, writing g.armorLead. Each
-- prong receives armor support rather than the main group taking all of it.
function ApportionArmor(phase)
	local armorTotal = (phase.targets.heavy or 0) + (phase.targets.medium or 0)
	local groups, cap = {}, 0
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g then groups[#groups + 1] = g; cap = cap + g.size end
	end
	if cap == 0 then return end
	local fracs, assigned = {}, 0
	for idx = 1, #groups do
		local exact = armorTotal * groups[idx].size / cap
		local f = math.floor(exact)
		groups[idx].armorLead = f
		fracs[idx] = exact - f
		assigned = assigned + f
	end
	local remainder = armorTotal - assigned
	while remainder > 0 do
		local bestIdx, bestFrac = nil, -1
		for idx = 1, #groups do
			if fracs[idx] > bestFrac then bestFrac = fracs[idx]; bestIdx = idx end
		end
		groups[bestIdx].armorLead = groups[bestIdx].armorLead + 1
		fracs[bestIdx] = -1
		remainder = remainder - 1
	end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua`
Expected: PASS, prints `routing OK`.

- [ ] **Step 5: Switch the tier field to army-wide and gate the front-load**

In `GetUnitToSpawn`, replace:

```lua
	local field
	if g then field = CountByTier(g) else field = GetFieldCounts() end
```

with:

```lua
	-- Army-wide composition: the tier ratio is enforced across the whole force, not
	-- per group, so splitting the force into prongs does not skew the ratio.
	local field = GetFieldCounts()
```

Then replace the armor front-load block:

```lua
	if Context.ArmorLead > 0 then
		local lead = nil
		if #byTier.heavy > 0 then lead = "heavy"
		elseif #byTier.medium > 0 then lead = "medium" end
		if lead then
			return GetRandomItem(byTier[lead], weightOf)
		else
			Context.ArmorLead = 0 -- no armor available; resume normal selection
		end
	end
```

with:

```lua
	-- Per-group armor lead, gated by the army-wide armor deficit. Front-loading leads
	-- with armor at the wave start but stops once the army meets its armor target, so
	-- surviving tanks across waves no longer crowd out infantry refills.
	if g and (g.armorLead or 0) > 0 then
		if (field.heavy + field.medium) < ArmorTargetCount(phase) then
			local lead = nil
			if #byTier.heavy > 0 then lead = "heavy"
			elseif #byTier.medium > 0 then lead = "medium" end
			if lead then
				return GetRandomItem(byTier[lead], weightOf)
			else
				g.armorLead = 0 -- no armor available; resume normal selection
			end
		else
			g.armorLead = 0 -- armor already at target; resume normal selection
		end
	end
```

- [ ] **Step 6: Decrement the per-group armor lead in `AttemptSpawn`**

Replace:

```lua
			local utier = TierOf(unit)
			if Context.ArmorLead > 0 and (utier == "heavy" or utier == "medium") then
				Context.ArmorLead = Context.ArmorLead - 1
			end
```

with:

```lua
			local utier = TierOf(unit)
			if g and (g.armorLead or 0) > 0 and (utier == "heavy" or utier == "medium") then
				g.armorLead = g.armorLead - 1
			end
```

- [ ] **Step 7: Apportion armor at wave start**

Replace the wave-start lines:

```lua
		-- Front-load the phase's armor quota (heaviest first) before the ratio picker.
		Context.ArmorLead = (phase.targets.heavy or 0) + (phase.targets.medium or 0)
		ManageGroups()
```

with:

```lua
		-- Build/refresh the groups, then split the phase's armor quota across them so
		-- each prong leads with armor (front-load is gated by the army-wide deficit).
		ManageGroups()
		ApportionArmor(phase)
```

- [ ] **Step 8: Rewrite `integration_spec.lua` for per-group armor and the deficit gate**

Replace the whole file `tests/integration_spec.lua` with:

```lua
-- Integration smoke test: exercise the real GetUnitToSpawn path offline.
dofile((arg[0]:gsub("integration_spec%.lua$", "harness.lua")))

-- Synthetic roster spanning all tiers.
local units = {
	{ class = UnitClass.Infantry,  unit = "rifle",   priority = 2.0 },
	{ class = UnitClass.Vehicle,   unit = "halftrk", priority = 1.0 },
	{ class = UnitClass.Tank,      unit = "lighttk", priority = 1.5, weight = "light" },             -- light, always available
	{ class = UnitClass.Tank,      unit = "medtk",   priority = 1.5, weight = "medium", unlock = 300 },
	{ class = UnitClass.HeavyTank, unit = "heavytk", priority = 1.0, unlock = 1500 },
}

-- EARLY phase: pin clock to t=0 so the unlock gate excludes medtk (unlock=300) and
-- heavytk (unlock=1500). No fill group, so no armor front-load; the pool filter alone
-- must keep medium/heavy out. If the unlockOk gate were removed, medtk/heavytk would
-- enter the pool; DecideTier would still not pick them (no medium/heavy target in early),
-- but the LATE check below is the front-load bite.
Context.GameClock = 0
Context.Groups = {}
Context.FillGroup = nil
Context.FieldUnits = {}
local seenEarly = {}
for i = 1, 200 do
	local pick = GetUnitToSpawn(units)
	assert(pick ~= nil, "early pick should not be nil")
	seenEarly[pick.unit] = true
end
assert(not seenEarly["medtk"],   "EARLY must not spawn medium tank")
assert(not seenEarly["heavytk"], "EARLY must not spawn heavy tank")
assert(seenEarly["rifle"] or seenEarly["halftrk"] or seenEarly["lighttk"], "EARLY spawns inf/light")
print("integration EARLY unlock-gate OK")

-- LATE phase: a fill group with an armor lead front-loads armor while the army is below
-- its armor target, then yields to the ratio once the army meets the target. The army
-- counts here live OUTSIDE the fill group, proving the field is army-wide (Task 3a).
Context.GameClock = 2000
Context.Groups = { [1] = { members = {}, size = 8 } }
Context.FillGroup = 1

-- Army has no armor yet -> front-load fires -> the heaviest available unit is chosen.
Context.FieldUnits = {}
Context.Groups[1].armorLead = 2
local leadPick = GetUnitToSpawn(units)
assert(leadPick.unit == "heavytk" or leadPick.unit == "medtk",
	"LATE: front-load leads with armor when the army is below target")

-- Army already holds 2 armor (in no group) -> deficit gate blocks the front-load ->
-- the pick is not armor.
Context.FieldUnits = {
	a1 = { class = UnitClass.HeavyTank, unit = "heavytk" },
	a2 = { class = UnitClass.Tank,      unit = "medtk", weight = "medium" },
}
Context.Groups[1].armorLead = 2
local gatedPick = GetUnitToSpawn(units)
assert(gatedPick.unit ~= "heavytk" and gatedPick.unit ~= "medtk",
	"LATE: army at armor target -> front-load gated, ratio picks non-armor")
print("integration LATE armor-gate OK")
print("integration OK")
```

- [ ] **Step 9: Run the changed specs to verify they pass**

Run: `cd resource/script/multiplayer && lua tests/routing_spec.lua && lua tests/integration_spec.lua`
Expected: PASS, prints `routing OK` then `integration ... OK` lines and `integration OK`.

- [ ] **Step 10: Run the full suite (no regression)**

Run: `cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" || echo "FAIL $f"; done`
Expected: every spec prints its `OK` line, no `FAIL` printed.

- [ ] **Step 11: Commit**

```bash
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/routing_spec.lua resource/script/multiplayer/tests/integration_spec.lua
git commit -m "feat: army-wide tier ratio with per-group armor distribution and deficit gate"
```

---

## Notes for the final review

- `Context.ArmorLead` (the old global counter, still initialized in the Context table and `OnGameStart`) is now unused. It is harmless dead state; removing its initialization is optional cleanup, not required for correctness. If removed, do it in Task 3 and confirm no other reader exists (`grep -n "Context.ArmorLead" bot.lua` returns only the init sites).
- The wave-end-on-groups-full behavior is unchanged: the standing army is still bounded by `TotalGroupCapacity()` (now 8 = 5 + 3), so total force size is the same as the previous single group of 8.
- Aux, capper, defender, and artillery trickles are untouched.
