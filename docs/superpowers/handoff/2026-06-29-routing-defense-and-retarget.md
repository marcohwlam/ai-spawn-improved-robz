# Handoff: #4 GER home-defense routing + #5 group retarget when stuck

**Date:** 2026-06-29
**Status:** Not started. Investigation/design notes for a fresh session.
**Scope:** Two separate routing/behavior issues observed in a real CTF (battle_zones) match.
Each should get its own brainstorm → spec → plan → SDD cycle (they are independent; #4 is a
correctness bug, #5 is a new behavior). Do NOT batch them into one design without checking.

## Cross-cutting dependency: the QPS timing fix

A separate in-flight phase (`docs/superpowers/specs/2026-06-29-timing-qps-calibration-design.md`,
branch `feat/timing-qps-calibration`) fixes that `QuantsPerSec = 70` is ~2.2x too high (real
~32). Any "too long" / time-window logic in #5 is measured in quants and is currently stretched
~2.2x in real time. Prefer landing the QPS fix first, and express #5's time windows via the new
`Elapsed()` (seconds) / `Q(sec)` helpers introduced there rather than raw `MatchQuants` deltas.

## System map (relevant code, `resource/script/multiplayer/bot.lua`)

- **Routing target selection:** `PickGroupTarget(excludeName)` at **bot.lua:1369-1406**. Tier
  ladder (shipped Phase 3, spec `docs/superpowers/specs/2026-06-29-phase3-routing-design.md`):
  - Candidate set = flags where `held` (`occupant == enemyTeam`) OR `attacking`
    (`occupant` neutral — neither team — AND `Context.LostStamp[name] ~= nil`).
  - **Tier 1** (`label.sector == "OWN"`): home invaded/attacked, retake first, key = `axis`.
  - **Tier 2** (`owner.mine and label.sector == "CONTESTED" and IsFrontier(name)`): our lane's
    contested frontier, key = `axis`.
  - **Tier 3** (else): expand to closest owned-adjacent flag (`NearestOwnedDist`), key = distance;
    fallback key = LostStamp/priority on unmapped maps.
  - Picks min tier, then min key, then name. Sets `Context.LastPickTier`.
- **Target refresh:** `UpdateGroupTargets()` at **bot.lua:397-424**. For each live group, re-picks
  ONLY when `not g.target or not FlagAttackable(g.target)` — i.e. it sticks with the current
  target until that flag is captured (no longer attackable) or otherwise resolves. `MaxGroups = 1`
  (bot.lua:84), so there is a single group with a single shared target driving most of the army.
- **Sector labeling:** `LabelFlags()` at **bot.lua:770-815**. `myAxis` is team-oriented (0 = own
  home, 1 = enemy home). `SectorOwnMax = 0.4` → OWN; `SectorEnemyMin = 0.6` → ENEMY; between →
  CONTESTED (bot.lua:94-95, 804-806). Unmapped/absent flag → `{sector = "CONTESTED"}`.
- **Partition (lane ownership):** `PartitionFlags()` at **bot.lua:840-897**. `FlagOwner[name] =
  {band, shared, mine, lat}`. `idxTrusted = idx in 1..teamSize`; on an untrusted slot
  `mine = true` everywhere (own-all). Best-effort; see "known issues".
- **Frontier:** `IsFrontier(name)` at **bot.lua:817** — true if a neighbor flag is occupied by
  this team, or the flag is base-adjacent to this team. Needs the offline adjacency graph
  (`flag_sectors.lua`); absent ⇒ false.
- **Group prune / staleSince:** `PruneGroups()` at **bot.lua:438-458**. NOTE: `g.staleSince`
  (449-450) is for reaping an EMPTY group whose pending spawn never landed — it is NOT a
  target-age or retarget timer. Do not confuse it with #5.

## Issue #4 — GER bot not defending home first

**Symptom:** In a real match GER did not prioritize retaking/defending its home flags when
invaded. (Observed by the user; not yet isolated in logs.)

**Root-cause hypotheses to investigate (ranked):**

1. **"Under attack while still owned" is invisible.** Tier 1 only fires when the home flag is
   `held` (enemy occupies it) or `attacking` (neutral + we have a LostStamp). A home flag that is
   still `occupant == team` but with enemy units approaching/contesting is NOT a candidate at all
   (the candidate filter at 1376-1379 requires `held or attacking`). The engine exposes only
   `occupant`, no "contested/under-attack" flag. So the bot can only react AFTER home flips to
   neutral/enemy, never pre-emptively. This is likely the core of "not defending home first."
   - Possible fix directions: treat a flag as defend-worthy when an enemy squad is near it (needs
     a proximity check via `Scene.Squads` positions vs flag position — the routing spec deliberately
     avoided this; revisit), OR accept reactive-only defense and make the reaction faster (see #2).
2. **Single-group latency.** `MaxGroups = 1` and `UpdateGroupTargets` only re-picks when the
   current target becomes unattackable. If the group is mid-attack on a tier-3 expansion flag when
   home is invaded, it will NOT abandon that attack to defend home until the current target is
   captured/lost. So even when a home flag flips to enemy (tier-1 eligible), the switch is delayed.
   This couples tightly with #5 (force a re-pick when a higher-priority target appears). Consider:
   re-pick every refresh if a strictly-lower-tier candidate than the current target exists, not only
   when the current target is unattackable.
3. **Team-b (GER) sector asymmetry.** The flag-labeling ledger noted the team-b sector boundary is
   not mirror-symmetric with team-a (e.g. a flag that is ENEMY for team-a came out CONTESTED for
   team-b). If GER's home flags are mis-labeled (not OWN), tier 1 never triggers for them. VERIFY:
   in a GER (team b) run, dump `Context.FlagLabel` and confirm GER's home flags get `sector=="OWN"`.
   Relevant deferred note: "OWN myAxis<=SectorOwnMax" boundary (ledger, Phase 1 Minor #1).
4. **Partition untrusted → own-all** does not break tier 1 (tier 1 ignores `owner.mine`), so this is
   likely NOT the cause, but confirm `FlagLabel` is populated for GER at all (LabelFlags ran, no
   SECTOR_FALLBACK).

**First diagnostic step:** run/capture a GER-perspective match and grep the log for `SECTOR`,
`GROUP_TARGET ... tier=`, and the home flags' `occupant` over time. Confirm whether (a) home flips
to enemy and (b) a tier=1 GROUP_TARGET is then chosen, and how long the switch takes.

## Issue #5 — group should switch target flag if it can't cap for too long AND is losing units fast

**Symptom:** The group commits to a target it cannot capture, bleeding units, instead of giving up
and retargeting.

**Current behavior:** `UpdateGroupTargets` keeps `g.target` until it is captured or becomes
unattackable. There is no give-up path on "stuck too long" or "losing members fast."

**Design starting points (for the brainstorm):**

- **Track target age:** record when `g.target` was set (in `Elapsed()` seconds, post-QPS-fix).
  If `Elapsed() - g.targetSince > STUCK_SEC` without capture, force a re-pick.
- **Track loss rate:** count group members lost while on the current target (hook the existing
  squad-death/membership-decrement path; see `GroupMemberCount` and where members are removed). If
  members lost within a window exceeds a threshold, force a re-pick.
- **Avoid thrashing back to the same flag:** on give-up, add the abandoned flag to a short
  per-flag cooldown (like `FailCooldown` for units) so `PickGroupTarget` skips it for
  `GIVEUP_COOLDOWN_SEC`; otherwise the same tier math re-selects it immediately. Pass it as the
  `excludeName`-style exclusion, or add a `Context.FlagAvoid[name] = until` checked in the
  candidate filter (1375-1379).
- **Interaction with #4:** a forced re-pick is also the mechanism that lets a tier-1 home-defense
  target pre-empt an in-progress tier-3 attack. Consider designing the "force re-pick" trigger to
  cover BOTH "stuck/bleeding" (#5) and "a strictly-better-tier candidate appeared" (#4 latency).
- **Thresholds are time-based** → must use the post-QPS-fix `Elapsed()`/`Q(sec)`; otherwise
  "too long" is ~2.2x off.

**Open questions for the user (resolve in the brainstorm):**
- Define "too long" (e.g. 45-60s without capture?) and "losing units fast" (e.g. ≥3 members lost
  in 20s?). These need tuning, ideally validated in-game.
- On give-up, retarget to the next-best tier (which may be the same home-defense flag) or
  specifically to a SAFER/closer flag? The cooldown-exclusion approach handles this.

## Suggested order

1. Land the QPS timing fix first (gives a correct `Elapsed()` for #5's windows).
2. #4 brainstorm — decide reactive-only vs proximity-based home defense, and whether to add the
   "re-pick when a better-tier candidate appears" pre-emption (which also helps #5).
3. #5 brainstorm — target-age + loss-rate give-up with an anti-thrash cooldown, reusing any
   pre-emption mechanism from #4.

## Reference docs
- Phase 3 routing design: `docs/superpowers/specs/2026-06-29-phase3-routing-design.md`
- Flag labeling (Phase 1) + partition (Phase 2) specs in `docs/superpowers/specs/`
- SDD ledger with deferred Minors (team-b sector asymmetry, 3v3 shared-band, present-but-unmapped
  flag): `.superpowers/sdd/progress.md`
