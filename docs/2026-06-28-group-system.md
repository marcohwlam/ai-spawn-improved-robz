# Group System Implementation Plan

> Executed via subagent-driven-development. Spec:
> `docs/superpowers/specs/2026-06-28-group-system-design.md` (the authoritative mechanics;
> each task implements the cited sections). Lua 5.5 tooling (`lua`/`luac`), engine is 5.1 —
> no `goto`. Gates after every task: `luac -p bot.lua && luac -p bot.data.lua &&
> lua tests/phase_spec.lua && lua tests/integration_spec.lua`.

**Goal:** Replace loose ratio spawning with up to two ratio-generated combined-arms groups
(size 8) that share de-conflicted objectives, backfill losses, and auto-upgrade by phase.

**Architecture:** Reuse the existing pool/DecideTier/recharge/fail-cooldown machinery as the
per-group unit selector; layer group membership, a group manager, per-group targeting, and
flag-loss tracking on top. Infantry splits into rifle/smg sub-tiers.

**Paths:** mod dir `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/ai-spawn-improved-robz/resource/script/multiplayer/` (bot.lua, bot.data.lua, tests/). Repo (symlinked): `/home/lamho/Documents/repos/ai-spawn-improved-robz`.

---

## Task 1 — Phase A: rifle/smg + elite tags, 5-tier composition
**Spec:** "Tier system", "Unit tagging", "Tier table". **Files:** bot.data.lua, bot.lua, tests/phase_spec.lua.
**Deliverable (bot still works on the improved 5-tier ratio):**
- bot.data: tag every `class=UnitClass.Infantry` (non-flame) with `inf="rifle"` or `inf="smg"`
  (smg = name contains smg/sturm/storm/shock/assault/pzgren_mech-no; rifle = the rest), and
  `elite=true` on elite assault squads (name contains elite/storm/para/shock + guards elite).
  Mech infantry keep `mech=true` and are NOT given an `inf` tag dependence (mech→light).
  Validate every infantry name still resolves in RobZ.
- bot.data `Phases`: replace `infantry=N` with `rifle=3, smg=1` per the spec tier table
  (EARLY {light=1,rifle=3,smg=1}; MID {medium=1,light=2,rifle=3,smg=1}; LATE {heavy=1,medium=1,light=2,rifle=3,smg=1}).
- bot.lua `TierOf`: return "rifle"/"smg" for infantry per the rules (mech→light first; inf=="smg"→smg; else rifle).
- bot.lua `DecideTier`: when `FlagDeficit()>0`, treat the `smg` target weight as 2 (losing bump).
  (DecideTier already iterates `phase.targets`; add the smg bump.)
- tests/phase_spec.lua: assert TierOf rifle vs smg vs mech→light; DecideTier picks smg over
  rifle when smg is under-filled; losing bumps smg.
**Gate:** all gates pass; `grep -c 'inf="rifle"\|inf="smg"' bot.data.lua` ~= infantry count.

## Task 2 — Phase B: group structures, manager, spawner (the group engine)
**Spec:** "Group data structure", "Component diagram", "Data flow", "Elite cap", "Locked parameters".
**Files:** bot.lua, tests/phase_spec.lua.
**Deliverable:**
- `Context.Groups = {}` (array, ≤2), `Context.SquadGroup = {}`; reset in OnGameStart.
- Membership handoff: a pending-group marker set by the group spawner before Spawn, consumed
  in `OnGameSpawn` (mirrors `isCapper`/`PendingCapper`): records `SquadGroup[squadId]=idx`
  and adds to `Groups[idx].members`.
- `countByTier(group)` -> {heavy,medium,light,rifle,smg} over the group's live members.
- Group manager (in OnGameQuant, replacing the old wave-fill): create group #1 when 0 groups;
  create #2 only when #1 is full (members==size, size=8); dissolve a group when it has 0 members.
- Group spawner: each in-wave spawn tick, pick the first group under size, run the existing
  pool selection + `DecideTier(phase, countByTier(g), ...)` for that group, **excluding a 2nd
  elite** if the group already has one live elite member; Spawn it tagged to that group.
- Pure-function test: `countByTier` and the elite-exclusion helper.
**Gate:** all gates pass; offline test of countByTier/elite-exclusion green.

## Task 3 — Phase B: flag-loss tracking, per-group targeting, CaptureFlag routing
**Spec:** "Targeting", "Data flow". **Files:** bot.lua, tests/phase_spec.lua.
**Deliverable:**
- `Context.PrevOwned`, `Context.LostStamp`; each quant update them (flag was ours, now enemy → stamp).
- `PickGroupTarget(excludeName)` -> enemy-held flag, most-recently-lost first, never neutral,
  excluding the other group's target; nil if none. (Pure-ish: reads Scene.Flags + LostStamp.)
- On group creation, set `group.target = PickGroupTarget(<other group's target>)`.
- Each quant per group: if `group.target` not attackable → re-pick (exclude other group's target).
- `CaptureFlag(squad)` routing: member → attack its group's target (fallback normal); elif
  capper → CapperFlagPriority; elif defender → DefenderFlagPriority; else GetFlagPriority.
- Offline test: PickGroupTarget prefers a recently-lost enemy flag; excludes neutral and the
  excluded name (inject a stub flag set).
**Gate:** all gates pass; targeting test green.

## Task 4 — Phase B: per-group backfill, phase-upgrade verify, remove old standalone, debug logs
**Spec:** "What is removed / kept / added", "Debug logging", "Data flow".
**Files:** bot.lua. **Deliverable:**
- Per-group backfill: when idle (between waves) and a group is under size, backfill one toward
  the ratio (same selector) — replaces the old global ratio backfill.
- Remove the old standalone: global per-wave ratio fill, `WaveTarget`/`SquadTarget`,
  `SmgLead` lead, the old global backfill. (Keep ArmorLead applied to a group's fill, the aux
  per-cycle injection charged to the filling group, the 4 trickles, flag helpers, harness.)
- Phase upgrade is implicit (DecideTier reads CurrentPhase); add a `GROUP_UP` log when a
  group's filling phase changes from the last logged phase for that group.
- Debug logs: `GROUP_NEW id target`, `GROUP_FILL id tier try ok size=cur/max`,
  `GROUP_UP id phase`, `GROUP_TARGET id target reason`, `GROUP_END id`; WAVE line gains `groups=`.
**Gate:** all gates pass; grep shows the GROUP_* prints; no references to removed symbols remain.

---

## Self-review notes
- Spec coverage: tiers/tags (T1), group engine+elite cap (T2), targeting+flag-loss (T3),
  backfill+upgrade+removal+logs (T4). All spec sections mapped.
- After T1 the bot runs on the improved 5-tier ratio (a working checkpoint). T2-T4 layer groups.
- High coupling in bot.lua: tasks run sequentially (one subagent at a time), reviewed between.
