# Group Coordination Design

**Date:** 2026-06-30
**File touched:** `resource/script/multiplayer/bot.lua` (single file)
**Tests:** `resource/script/multiplayer/tests/routing_spec.lua`

## Problem

Three coupled defects in the group targeting and spawn system:

1. **Slow retarget.** A group only re-picks its flag when the current target is
   captured or becomes unreachable (`UpdateGroupTargets`). A group pushing an
   enemy rear flag (tier 3) ignores a higher-priority threat that appears, for
   example losing a contested flag (tier 2) or the home being invaded (tier 1).
   Even when the target does change, member squads only re-path on the
   `OrderRotationPeriod` timer (3 minutes), so a target switch is cosmetic for
   up to 3 minutes.

2. **Single concentrated blob.** `MaxGroups = 1`, so one group of 8 units
   attacks one flag. The stack paths to a single point and artillery wipes it.

3. **Per-group ratio breaks under small caps.** `DecideTier` balances the army
   composition using the fill group's own current counts (`CountByTier(g)`), so
   each group independently tries to reach `phase.targets`. A group smaller than
   the phase `CycleSize` (early 5, mid 6, late 7) cannot hold one full
   composition cycle, so the high-weight tiers that front-load first squeeze
   infantry out. `ArmorLead` compounds this: it is a global per-wave counter and
   the fill order fills the main group first, so all front-loaded armor lands in
   the main group and the sub group becomes naked infantry.

## Goals

- A group switches target the moment a strictly higher-priority (lower tier)
  objective appears, and its squads re-path immediately.
- Split the standing force into a main and a sub prong on adjacent flags so a
  single artillery strike cannot catch the whole force.
- Preserve the army-wide tier ratio (including the infantry share) regardless of
  how the force is split across groups.

## Decisions

- **Force split:** main group size 5, sub group size 3 (total 8, unchanged from
  the current single group of 8). `MaxGroups = 2`.
- **Split applies in every phase**, including early. The sub group only exists
  once the main group is full (existing `ManageGroups` gate), so the early ramp
  is naturally concentrated until 5 units exist.
- **Preemption policy:** switch only when a strictly lower tier number becomes
  available. Same-tier distance differences do not trigger a switch, which
  removes distance flapping.
- **Sub group target:** the attackable flag nearest (by `FlagLabel` x/y) to the
  main group's target. The sub group does not run tier preemption on its own; it
  follows the main group.
- **Army ratio:** `DecideTier` uses army-wide counts, not per-group counts.
- **Armor distribution:** `ArmorLead` becomes per-group, apportioned by the
  largest-remainder method, so each prong receives armor support.
- **Infantry protection:** the armor front-load is gated by the army-wide armor
  deficit, so surviving tanks across waves no longer force fresh armor and
  starve infantry refills.
- **Aux is unchanged.** `AuxOwed` / `RatioCount` are already army-wide counters,
  aux units are `TierOf == nil` and touch neither the tier field nor
  `ArmorLead`. No aux change is in scope.

## Component Design

```
                         GROUP COORDINATION
  ┌──────────────────────────────────────────────────────────────┐
  │ ManageGroups        build g1 (size 5) and g2 (size 3)         │
  │ apportionArmor()    largest-remainder split of armorTotal     │
  │                      across live groups -> g.armorLead         │
  ├──────────────────────────────────────────────────────────────┤
  │ UpdateGroupTargets  per quant:                                 │
  │   g1 (main): FlagTier preemption -> PickGroupTarget            │
  │   g2 (sub):  PickSubTarget(g1.target) = nearest attackable     │
  │   on any target change -> ReorderGroup(gi)                     │
  ├──────────────────────────────────────────────────────────────┤
  │ FlagTier(name)      extracted tier classifier (shared by       │
  │                     PickGroupTarget and the preemption check)  │
  │ PickSubTarget(t)    nearest attackable flag to t; t if none    │
  │ ReorderGroup(gi)    immediate CaptureFlag on every member      │
  ├──────────────────────────────────────────────────────────────┤
  │ GetUnitToSpawn      field = army-wide GetFieldCounts()         │
  │   armor front-load gated by army-wide armor deficit            │
  │   armor pick decrements the fill group's g.armorLead           │
  └──────────────────────────────────────────────────────────────┘
```

## Data Flow

```
 flag owner change (OnGameQuant: LostStamp / PrevOwned)
        │  every quant
        ▼
 UpdateGroupTargets
   ├─ g1 main: target gone? -> PickGroupTarget(other)
   │           target alive but FlagTier(cand) < FlagTier(g1.target)? -> switch
   ├─ g2 sub:  g1.target changed or g2.target gone?
   │           -> PickSubTarget(g1.target) = nearest attackable flag
   └─ any g.target changed -> ReorderGroup(gi)
                                 └─ for each member squad: CaptureFlag(squad)
                                       └─ engine re-paths immediately

 WAVE start (OnGameQuant)
   ManageGroups()                         build / refresh g1, g2
   apportionArmor(phase)                  armorTotal = heavyT + mediumT
                                          largest-remainder by g.size -> g.armorLead
   fill loop: GroupToFill() -> FillGroup  main filled before sub
        ▼
   GetUnitToSpawn(FillGroup = gi)
     field = GetFieldCounts()             army-wide, ratio decoupled from caps
     armorTargetCount = round(armorTotal / CycleSize * totalGroupCapacity)
     if gi.armorLead > 0 and (field.heavy + field.medium) < armorTargetCount:
         lead with armor (gi's share)     ordering hint, quantity bounded by deficit
     else:
         DecideTier(field, ...) -> tier   army-wide deficit pick (usually infantry)
        ▼
   AttemptSpawn ok:
     armor spawned -> gi.armorLead -= 1
     RatioCount += 1 (army-wide, unchanged); aux cycle unchanged
```

## Tasks

The tasks are ordered by dependency. Task 2 establishes the two-group structure
that Task 3 apportions armor across.

### Task 1: Tier preemption retarget and immediate re-order

- Extract the tier classifier from `PickGroupTarget` into `FlagTier(name)`
  returning the tier number (1, 2, or 3) for a flag, or `nil` when the flag is
  not a valid candidate (neither enemy-held nor a lost neutral). `PickGroupTarget`
  calls `FlagTier` so the two cannot diverge.
- In `UpdateGroupTargets`, when the current target is still attackable, compute
  `cand = PickGroupTarget(other)` and switch only when
  `FlagTier(cand) < FlagTier(g.target)`.
- Add `ReorderGroup(gi)` that iterates the group's member squads and calls
  `CaptureFlag(squad)` immediately. Call it whenever a group's target changes
  (preemption or the existing target-gone path).

### Task 2: Main and sub groups on adjacent flags

- `MaxGroups = 2`.
- `ManageGroups` assigns per-group sizes: group 1 size 5, group 2 size 3
  (replace the single `GroupSize` constant usage in group construction).
- Add `PickSubTarget(mainTarget)`: scan attackable flags, return the one nearest
  to `mainTarget` by `FlagLabel` x/y. Return `mainTarget` when there is no
  distinct candidate or coordinates are missing.
- In `UpdateGroupTargets`, the group 2 branch uses `PickSubTarget(g1.target)`
  instead of `PickGroupTarget(other)`. A group 2 target change triggers
  `ReorderGroup(2)`.

### Task 3: Army-wide ratio and per-group armor distribution

- In `GetUnitToSpawn`, set `field = GetFieldCounts()` unconditionally. Keep the
  fill group `g` for the elite cap and the armor lead only.
- Replace the global `Context.ArmorLead` with a per-group `g.armorLead`:
  - `apportionArmor(phase)` runs at wave start after `ManageGroups`. It computes
    `armorTotal = (heavyT or 0) + (mediumT or 0)` and distributes it across live
    groups by the largest-remainder method on `g.size`, writing `g.armorLead`.
  - The front-load branch fires only when `g.armorLead > 0` and the army-wide
    armor count is below `armorTargetCount = round(armorTotal / CycleSize(phase)
    * totalGroupCapacity)`, where `totalGroupCapacity` is the sum of live group
    sizes. Otherwise set `g.armorLead = 0` and fall through to `DecideTier`.
  - The armor-spawn decrement in `AttemptSpawn` decrements the fill group's
    `g.armorLead` instead of the global counter.

## Edge Cases

- **Sub has no distinct flag** (one enemy flag on the map): `PickSubTarget`
  returns the main target, both prongs converge. Acceptable; this is not a blob
  scenario.
- **Group with no live members** (just created, units not spawned yet):
  `ReorderGroup` loops over an empty member set, a no-op.
- **Preempted target captured by an ally next tick**: `FlagAttackable` is false,
  the normal re-pick path runs.
- **Early phase**: `armorTotal = 0`, so `apportionArmor` sets every
  `g.armorLead = 0` and the front-load never fires. Tasks 3b and 3c are no-ops
  in early.
- **Losing-state fast waves**: unaffected; the wave cadence and budget
  multiplier are untouched.

## Testing

All in `routing_spec.lua` unless noted.

- **Preemption:** a tier-3 current target with a tier-2 candidate available
  switches and calls `ReorderGroup`; a same-tier closer candidate does not
  switch.
- **FlagTier:** returns the same tier the inline classifier produced for OWN,
  CONTESTED-frontier, and expansion flags; `nil` for a non-candidate flag.
- **Sub target:** `PickSubTarget` returns the attackable flag nearest the main
  target; returns the main target when no distinct candidate exists.
- **Group sizes:** group 1 caps at 5, group 2 caps at 3.
- **Army-wide ratio:** with a fill group set, `DecideTier` reads army-wide
  counts (a unit in the other group counts toward the field).
- **Armor apportionment:** late -> main 1 / sub 1; mid -> main 1 / sub 0;
  early -> main 0 / sub 0 (largest-remainder).
- **Front-load deficit gate:** with army armor already at the target count, the
  front-load does not fire and `DecideTier` runs instead.
- **Regression:** a captured target re-picks and re-orders; two groups stay
  de-conflicted on distinct flags.
```
