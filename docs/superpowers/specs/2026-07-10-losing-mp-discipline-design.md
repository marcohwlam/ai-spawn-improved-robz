# Losing-Side MP Discipline Design

Date: 2026-07-10
Status: Approved for planning

## Problem

Observed in a 2v2 match (UK vs German SS): the losing bot ran out of manpower (MP)
because it kept spawning cheap tanks that died, never banking enough MP to field a
survivable force. Two distinct leaks feed this:

1. **Armor tier downgrade.** When the bot cannot afford its chosen armor unit, it falls
   through to a cheaper tier and spawns a cheap tank instead of banking. The cheap tank
   dies, MP is spent, and the balance never recovers enough to afford real armor. A death
   spiral.

2. **Artillery upkeep while losing.** Artillery is expensive, indirect, and sits in the
   rear. Maintaining it while behind on flags spends MP that the bot needs for the
   front-line force that actually retakes flags.

### Economy model constraints (important)

The bot's only economic API is `BotApi.Commands:Income(playerId)` — an income **rate**, not
a spendable MP **balance**. Units have no cost field; affordability is proxied by
`min_income` (a threshold on the income rate). The engine holds the real MP balance; a
`Commands:Spawn` call that the balance cannot cover fails silently (no `OnGameSpawn`
confirmation, later logged as `SPAWN_LOST`).

Consequence: **`Spawn` success/failure is the only signal of the actual MP balance.** A unit
can pass its `min_income` rate gate yet still fail to spawn because the balance was drained
by cheap dribble. This is exactly what strands expensive armor.

## Feature 1: Armor no-downgrade MP banking

### Where the downgrade happens

`GetUnitToSpawn` builds `pool` (excludes units failing `min_income` and units on
`FailCooldown`), groups it into `byTier`, sets `tierEligible[tier]` where a tier has
candidates, and `DecideTier` picks a tier from the eligible set. When an armor unit fails
`Commands:Spawn`, `AttemptSpawn` benches it via `Context.FailCooldown[unit] = Elapsed()`.
On the next tick that armor unit is gone from `pool`; if it was the last affordable armor
unit, `byTier.heavy`/`byTier.medium` empties, `tierEligible` drops that tier, and
`DecideTier` selects a **lower** tier. The cheaper tank spawns. That is the leak.

### Fix

When an armor-tier unit (`TierOf == "heavy"` or `"medium"`) that **passed `min_income`**
fails `Commands:Spawn`, enter an armor-bank window instead of downgrading:

- Set `Context.ArmorBankUntil = Elapsed() + ArmorBankSec`.
- While the window is active, `GetUnitToSpawn` considers **only armor tiers**. If no armor
  tier is affordable this tick, it returns `nil` (spawn nothing — a hard bank), rather than
  substituting a cheaper tier or infantry.
- A `nil` return counts as a wave fail (`WaveFails`), so the wave ends after `MaxWaveFails`
  and the bot idles between waves; the engine MP balance recovers while idle. When the
  balance can cover the armor again, `Commands:Spawn` succeeds, the streak resets, and normal
  spawning resumes.

This generalizes the existing late-phase `HeavyFailSlowdown` (heavy-only, late-only) to the
whole armor tier (heavy + medium) in every phase, and it suppresses the tier downgrade
rather than merely slowing cadence.

### Safety rule (deadlock avoidance)

The window may trigger **only** on a `Spawn` failure of a `min_income`-eligible armor unit —
never on a `min_income` exclusion. A bot whose income rate is genuinely too low for armor
was never going to spawn armor this bracket; freezing it would spawn nothing and lose
harder. Keying strictly on balance-driven `Spawn` failure means an income-starved bot still
fields infantry and light units per the normal ratio and never freezes.

Self-recovery is guaranteed by two bounds already in the code: the window is finite
(`ArmorBankSec`), and `MaxWaveFails` ends any wedged wave. If armor is still unaffordable
when the window expires, normal behavior resumes for a tick and the cycle self-limits.

```
armor unit picked (passed min_income)
        |
   Commands:Spawn ok?
        |-- yes --> spawn, reset streak (normal)
        |-- no (balance drained) -->
             set Context.ArmorBankUntil = Elapsed() + ArmorBankSec
                    |
   while ArmorBankUntil active, GetUnitToSpawn:
        consider ARMOR tiers only
        armor affordable this tick?
            yes --> spawn armor, reset
            no  --> return nil  (HARD BANK: spawn nothing)
                       |
             WaveFails++ -> wave ends at MaxWaveFails -> idle -> MP balance recovers
                       |
             next wave: balance covers armor -> spawn succeeds
```

### Data flow

```
DecideTier ---------------------------------> tier
   ^                                             |
   | tierEligible (armor dropped when benched)   v
GetUnitToSpawn:                            cands = byTier[tier]
   build pool (min_income + FailCooldown filter)
   IF Context.ArmorBankUntil active AND no armor tier affordable:
        return nil   <-- NEW: no downgrade, hard bank
   ELSE return GetRandomItem(cands, weightOf)
                                                 |
AttemptSpawn(unit): Commands:Spawn -> ok? -------+
   on fail AND TierOf(unit) in {heavy,medium} AND min_income met:
        Context.ArmorBankUntil = Elapsed() + ArmorBankSec   <-- NEW trigger
```

## Feature 2: Artillery cap reduced, zeroed when badly losing

Artillery upkeep is wasteful when behind on flags. Two changes:

- Lower the baseline `ArtyCap` from `2` to `1` (one artillery piece is enough support).
- Add `ArtyCapNow()` and use it at the artillery trickle (`bot.lua` line 2164,
  `cap = ArtyCap`):

```
ArtyCapNow():
    FlagDeficit() >= BadlyLosingDeficit  -> 0   (badly losing: no artillery at all)
    otherwise                            -> 1   (default)
```

`BadlyLosingDeficit = 3` (a named, tunable constant). Only a large deficit zeroes artillery;
a small 1-2 flag deficit keeps the single piece for suppression. When badly losing, live
artillery is not replaced as it dies, freeing MP for the front-line force that retakes flags.

`FlagDeficit()` (= enemy flags - own flags) and `IsLosing()` already exist; `ArtyCapNow()`
reuses `FlagDeficit()` directly for the threshold.

## Testing

Feature 1:
- An armor unit that passes `min_income` but whose `Commands:Spawn` fails sets
  `Context.ArmorBankUntil`; a `min_income`-excluded armor unit does NOT (safety rule).
- While `ArmorBankUntil` is active and no armor is affordable, `GetUnitToSpawn` returns
  `nil` (no lower-tier substitute).
- While `ArmorBankUntil` is active and armor IS affordable, it spawns the armor.
- A successful armor spawn clears the streak / lets the window lapse.
- Income-starved case: armor excluded by `min_income`, window never set, infantry/light
  still spawn per ratio (no freeze).

Feature 2:
- `ArtyCapNow()` returns 1 at deficit <= 2, 0 at deficit >= `BadlyLosingDeficit` (3).
- The artillery trickle honors `ArtyCapNow()` (no new artillery while badly losing).
- Baseline `ArtyCap` is 1.

## Out of scope

- Targeting fixes (pushing armor into anti-tank ambush) — separate concern.
- A true MP-balance API or per-unit cost model (engine does not expose these).
- Reversing the losing-side wave cadence (`WaveIntervalNow`) — not changed here.
