# Faction Composition Bias Design

**Date:** 2026-07-06
**Status:** Approved design, ready for plan
**Goal:** Let each faction guarantee a minimum field count for specific unit categories
(e.g. "ger medium armor +1", "usa artillery +1", "rus smg +1", "jap mortar +1") without
touching the existing ratio-driven composition logic for everything else.

## Background

Army composition is currently driven by two independent systems:

1. **Tier ratio** (`Phases[i].targets` in `bot.data.lua`, consumed by `DecideTier` in
   `bot.lua`): a weight table over 5 tiers (`heavy`/`medium`/`light`/`rifle`/`smg`).
   `DecideTier` picks whichever eligible tier has the largest deficit between its weight
   share and its actual field share. This scales naturally as the army grows across
   early/mid/late phases (`docs/superpowers/specs/2026-06-29-per-faction-phases-design.md`).
2. **Dedicated capped trickles**: artillery has its own path (`ArtyCap`, `ArtyIntervalSec`,
   `LiveArtyCount()`) outside the ratio/aux system entirely — a fixed ceiling with a cooldown,
   not a ratio. Mortars (`UnitClass.Mortar`) have no dedicated path at all today: `TierOf`
   returns `nil` for them, so they fall into the generic aux pool and compete with
   AT/MG/sniper/officer/AA for the fixed `AuxPerCycle = 2` batch — no tracking, no guarantee.

Requests like "ger armor +1" don't map cleanly onto either system: they're not a full
ratio re-tune (that would require re-balancing every phase for every faction, high
regression risk on a subsystem this project has already spent a full debugging session
stabilizing), and they're not a ceiling (they want *at least* N, not *at most* N).

## Decisions

- **Floor, not replacement.** The 5-tier ratio system stays exactly as-is; it remains the
  backbone because it's the only piece that scales correctly with army size across phases.
  A per-faction minimum-count floor is layered on top, expressed as a **short-circuit**, not
  a soft weight nudge — when a category is below its floor, that category is chosen
  outright, bypassing the weight/deficit math (including the tank-bias +0.15 and
  losing-smg-double adjustments). A soft nudge risks the floor being drowned out in a large
  army with a big weight spread, which would silently fail the "guarantee" contract.
- **7 categories, one data table.** `heavy`/`medium`/`light`/`rifle`/`smg` (existing tiers)
  plus two new categories, `artillery` and `mortar`. Categories omitted for a faction default
  to 0 (no floor, current behavior unchanged).
- **No new standalone gate function.** The floor check is inlined at each of the three
  existing decision points rather than added as an external pre-check layer:
  - Tier categories: inlined at the top of `DecideTier`.
  - Artillery: inlined as an `or` branch on the existing interval-cooldown condition at the
    ARTY call site.
  - Mortar: pulled out of the generic aux pool into its own dedicated capped-trickle path,
    sharing a new parameterized helper with artillery (see Components) rather than
    duplicating the ARTY pattern verbatim.
- **Floor values must not exceed their ceiling.** For `artillery`/`mortar`, a floor greater
  than `ArtyCap`/`MortarCap` is a data contradiction (the field would need to hold more units
  than it's allowed to). This is a self-test assertion at table-load time, not a runtime
  guard — it should never happen in shipped data.
- **All 8 factions are in scope for the data table** (`eng`, `ger`, `ger_ss`, `usa`, `rus`,
  `jap`, `ger2`, `rus_guard`), each independently keyed — `ger_ss`/`ger2`/`rus_guard` do not
  inherit `ger`/`rus`'s bias.

## Architecture

```
bot.data.lua                          bot.lua
+----------------------+              +--------------------------------+
| FactionBias[army]     |              | DecideTier(phase, field, ...)  |
|  = { heavy=N,         |------------->|   floor check inlined first -- |
|      medium=N,        |  tier cats   |   short-circuits weight/deficit|
|      light=N,         |              |   math when unmet              |
|      rifle=N,         |              +--------------------------------+
|      smg=N,           |
|      artillery=N,     |              +--------------------------------+
|      mortar=N }        |------------->| TryCappedTrickle(cfg)          |
+----------------------+  arty/mortar  |   shared helper: cap, interval,|
                           cats        |   live-count fn, unit picker,  |
                                       |   floor value                  |
                                       |   floor unmet -> ignore        |
                                       |   interval cooldown, still     |
                                       |   respects cap                 |
                                       +--------------------------------+
                                         instantiated twice:
                                           ARTY   (existing, refactored)
                                           MORTAR (new)
```

## Data flow

```
AttemptSpawn (tier path)
   phase = CurrentPhase(Elapsed())
   army = BotApi.Instance.army
   DecideTier(phase, GetFieldCounts(), ...)
       for each of heavy/medium/light/rifle/smg:
         if LiveCount(cat) < (FactionBias[army][cat] or 0): return cat  -- floor short-circuit
       -- else: existing weight/deficit selection, unchanged

Per-quant ARTY / MORTAR gate
   army = BotApi.Instance.army
   floorUnmet = LiveCount(cat) < (FactionBias[army][cat] or 0)
   if (floorUnmet or Elapsed() - lastTime >= interval) and LiveCount(cat) < cap:
       spawn via TryCappedTrickle
```

## Components

### 1. `FactionBias` table (bot.data.lua, new)

Default values are chosen to reflect each faction's real-world doctrine rather than picked
arbitrarily:

| Faction | Doctrine basis | Bias |
|---|---|---|
| `ger` | Blitzkrieg — armor as the offensive spearhead | `medium = 1` |
| `ger_ss` | Panzergrenadier doctrine — mechanized infantry riding with the armor, not extra armor itself | `light = 1` |
| `ger2` | Ostfront late-war defensive roster (`ost_straf_ppsh`/`ost_straf_mp28`/`home_guards` in RobZ's `ger2` squad set indicate improvised, captured-weapon penal/Volkssturm units) — static infantry attrition, not an armored spearhead | `rifle = 1` |
| `usa` | "King of Battle" — US doctrine's signature massed/TOT artillery fire support | `artillery = 1` |
| `rus` | Deep Battle doctrine's PPSh-armed assault infantry ("tommy gunner") waves | `smg = 1` |
| `rus_guard` | Guards formations received first pick of new heavy equipment (KV/IS series) | `heavy = 1` |
| `jap` | Infiltration/night-attack doctrine centered on light infantry weapons (knee mortars) over a weak tank arm | `mortar = 1` |
| `eng` | Montgomery's "colossal cracks" — heavy artillery preparation before every advance | `artillery = 1` |

```lua
-- FactionBias[army] is keyed by phase name first ({early={cat=N,...}, mid={...}, late={...}}),
-- so a faction can bias a *different* category per phase, not just a bigger floor on the same
-- one. A phase with no entry floors every category 0 (no-op).
-- Categories: heavy | medium | light | rifle | smg | artillery | mortar | attank | mg | sniper
FactionBias = {
    -- Blitzkrieg armor spearhead: medium from mid, heavy (Tiger/Panther-class) takes over the
    -- spearhead role late. MG42 teams anchoring the advance from the opening minutes.
    ger = {
        early = { mg = 1 },
        mid   = { medium = 1 },
        late  = { heavy = 1 },
    },
    -- Panzergrenadier mechanized infantry early; StuG/Hetzer/Jagdpanzer tank destroyers backing
    -- the infantry from mid (SS Panzerjäger doctrine); late-war SS divisions traded that
    -- mechanized mass for concentrated heavy armor (Tiger/King Tiger battalions).
    ger_ss = {
        early = { light = 1 },
        mid   = { attank = 1 },
        late  = { heavy = 1 },
    },
    -- Ostfront defensive infantry attrition early; reinforced with medium armor once it
    -- unlocks at the mid boundary, then scarce heavy armor (Tiger II) piecemeal late.
    ger2 = {
        early = { rifle = 1 },
        mid   = { medium = 1 },
        late  = { heavy = 1 },
    },
    -- King of Battle: US mass/TOT artillery fire support, sustained from mid.
    usa = {
        mid  = { artillery = 1 },
        late = { artillery = 1 },
    },
    -- PPSh assault infantry ("tommy gunner") waves throughout, backed by Soviet sniper
    -- doctrine (Lyudmila Pavlichenko-style marksmanship training) from the opening minutes;
    -- Deep Battle doctrine's massed T-34 armor sweeps join from mid, escalating late.
    rus = {
        early = { smg = 1, sniper = 1 },
        mid   = { smg = 1, medium = 1 },
        late  = { medium = 1, artillery = 1 },
    },
    -- Guards' elite marksmanship training from the opening minutes; by late-war T-34-85 mass
    -- production also reaches Guards formations alongside their IS-series heavies.
    rus_guard = {
        early = { sniper = 1 },
        mid   = { artillery = 1 },
        late  = { heavy = 1 },
    },
    -- Infiltration/night-attack doctrine centered on light infantry weapons throughout;
    -- Ho-Ni/Ha-To self-propelled artillery support joins from mid.
    jap = {
        early = { mortar = 1 },
        mid   = { mortar = 1, artillery = 1 },
        late  = { mortar = 1, artillery = 1 },
    },
    -- Montgomery's "colossal cracks" -- heavy artillery preparation, sustained from mid;
    -- Churchill/Firefly heavy armor joins the set-piece assault late.
    eng = {
        mid  = { artillery = 1 },
        late = { artillery = 1, heavy = 1 },
    },
}
```

`BiasFloor(bias, cat, phaseName)` (`bot.lua`) resolves `bias[phaseName][cat]`, defaulting to
0 when either the phase or the category is absent. `DecideTier`'s fixed tier-check order
(`heavy, medium, light, rifle, smg`) means that when a phase floors more than one category
(e.g. `ger.late`), the earlier tier in that order wins if both are simultaneously unmet --
same fixed-order tie-break rule as before, now also disambiguating across categories a single
phase entry introduces. `DecideTier` and the ARTY/MORTAR `TryCappedTrickle` call sites both
resolve through `BiasFloor`, keyed off the caller's current phase name.

### 2. `DecideTier` (bot.lua, modify)

Before the existing weight/deficit loop, iterate the tier categories **restricted to
`tierEligible`** (in a fixed order: `heavy, medium, light, rifle, smg`) and return the first
one whose live count in `field` is below `FactionBias[army][cat] or 0`.

This restriction is load-bearing, not cosmetic: `tierEligible` already encodes which tiers are
currently reachable for this phase/faction (e.g. Japan never has `heavy`; a tier whose first
unit hasn't unlocked yet is excluded during early phase per the per-faction-phase boundaries).
Scanning all floor entries unconditionally would let the floor force-select a tier that cannot
actually be spawned yet — `DecideTier` is the sole per-attempt selector for the tier path, so a
permanently-unmet floor on an unreachable tier would starve every other tier for the rest of
that phase (same failure shape as the pre-fix `PruneGroups` group-starvation bug from the
spawn-reliability work). Floors on a tier outside `tierEligible` are simply not evaluated until
that tier becomes eligible.

### 3. `TryCappedTrickle(cfg)` (bot.lua, new — extracted from existing ARTY logic)

Parameterized helper: `{ cap, intervalSec, lastTimeField, liveCountFn, unitPickerFn,
floorValue }`. Encapsulates the existing ARTY gate condition generalized with the floor `or`
branch:

```lua
function TryCappedTrickle(cfg)
    local live = cfg.liveCountFn()
    local floorUnmet = live < (cfg.floorValue or 0)
    if (floorUnmet or Elapsed() - (Context[cfg.lastTimeField] or 0) >= cfg.intervalSec)
        and live < cfg.cap then
        -- existing spawn-attempt body, using cfg.unitPickerFn()
    end
end
```

### 4. ARTY call site (bot.lua, modify)

Refactored to call `TryCappedTrickle` with `cap = ArtyCap`, `intervalSec = ArtyIntervalSec`,
`lastTimeField = "LastArtyTime"`, `liveCountFn = LiveArtyCount`, `unitPickerFn = GetArtyUnit`,
`floorValue = FactionBias[army].artillery`.

### 5. MORTAR call site (bot.lua, new)

New constants `MortarCap`, `MortarIntervalSec` (mirroring `ArtyCap`/`ArtyIntervalSec`), new
`LiveMortarCount()` (counts live `UnitClass.Mortar` squads, mirrors `LiveArtyCount`), new
`GetMortarUnit()` (mirrors `GetArtyUnit`, picks from the faction roster). Calls
`TryCappedTrickle` with `floorValue = FactionBias[army].mortar`.

### 6. Aux pool (bot.lua, modify)

`AuxEligible`/`collectAux()` drop any `UnitClass.Mortar` handling (mortars no longer flow
through the generic aux batch — they have their own dedicated path now). AT/MG/sniper/
officer/AA aux behavior is unchanged.

## Error handling / edge cases

| Condition | Behavior |
|---|---|
| `FactionBias[army]` absent | All 7 categories default to floor 0 — behavior identical to today. |
| Category floor set on a tier ineligible for the faction (e.g. `jap.heavy`) | No-op; `tierEligible` already excludes it from `DecideTier` consideration. |
| Category floor set on a tier not yet unlocked this phase (e.g. `ger.medium` during early phase) | No-op until the phase/unlock state makes it `tierEligible` — floor is never evaluated against an unreachable tier, so it cannot starve the other tiers in the meantime. |
| `FactionBias[army].artillery` or `.mortar` > `ArtyCap`/`MortarCap` | Data contradiction — caught by a load-time self-test assertion, not expected in shipped data. |
| Floor met exactly (`live == floor`) | Not "unmet" — normal ratio/interval logic resumes. |
| Multiple tier categories simultaneously below floor | Fixed category order (`heavy, medium, light, rifle, smg`) picks the first; no weighted tie-break — keeps the check deterministic and simple. |

## Testing

- **`bias_spec.lua`** (new):
  - `DecideTier` returns the floor-unmet tier before any weight/deficit calculation runs
    (mock a field where the ratio math would pick a *different* tier, assert the floor tier
    wins).
  - Floor short-circuit is unaffected by tank-bias (+0.15) and losing-smg-double adjustments.
  - A floor set on a tier absent from `tierEligible` (not yet unlocked / faction has no such
    tier) is never selected, and normal weight/deficit selection among the eligible tiers
    proceeds unimpeded — this is the regression test for the starvation risk called out above.
  - Floor met (`live == floor` and `live > floor`) falls through to normal weight/deficit
    selection.
  - `TryCappedTrickle`: floor-unmet bypasses the interval cooldown but still respects `cap`
    (boundary case: `live == cap` never spawns regardless of floor).
  - `LiveMortarCount()` counts only live `UnitClass.Mortar` squads.
  - Load-time self-test: every faction's `artillery`/`mortar` floor (if present) is `<=` its
    cap.
- **Existing specs regression**: `group_spec.lua`, `spawnlock_spec.lua`,
  `heavy_fail_pause_spec.lua`, `phase_spec.lua` — floor logic only changes *which* category
  is selected, never the spawn/confirm lifecycle, so these must stay green unchanged.
- **`tools/check_unit_roster.py`**: no changes needed — `FactionBias` doesn't introduce new
  `unit=` ids.
- **In-game probe** (manual gate): run one match per biased faction, confirm via
  `game.log` that the biased category reaches its floor faster than an unbiased baseline
  category of similar unlock cost, and that `ArtyCap`/`MortarCap` are never exceeded.

## Out of scope

- Re-tuning the global `Phases.targets` weight table itself.
- A UI/config surface for adjusting bias at runtime — this is a data-table edit in
  `bot.data.lua`, same workflow as `FactionPhases`.
- Tie-break weighting when multiple categories are simultaneously below floor (fixed order
  is sufficient for the current single-category-per-faction use cases; revisit if a faction
  ever needs multiple simultaneous floors that meaningfully conflict).
- Applying floors to aux-only categories other than mortar (AT/MG/sniper/officer/AA stay in
  the existing fixed-batch aux pool, unmodified).
