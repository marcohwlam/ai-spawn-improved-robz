# AI Spawn Improved for RobZ 1.30.x

A Lua-only AI bot mod for **Men of War: Assault Squad 2** (game 3.262) running with the
**RobZ Realism Mod 1.30.x**. It replaces the stock bot spawn logic with a phase-based,
four-tier wave system and recharge-aware unit pooling. No entity assets, so it does not
conflict with other content mods.

## What it does

See `ARCHITECTURE.md` for the full structural map (module diagram, per-quant data
flow, subsystem breakdown). Summary:

### Spawn economy
- **Wave spawning** — the bot saves manpower and dumps it in waves. Base cadence is
  60s and stretches to 90s (mid) / 135s (late) via each phase's `waveMult`, compressed
  down toward a 10s floor the further behind on flags the team is
  (`WaveIntervalNow`). Each wave spreads its spawns across game ticks so the engine
  accepts every one instead of rejecting a burst.
- **Time phases** — EARLY/MID/LATE, boundaries resolved per-faction
  (`FactionPhases`), anchored to that faction's real RobZ unlock times — e.g. usa
  mid=530s/late=1200s, ger mid=630s/late=1500s, jap mid=580s/late=1380s. The global
  `Phases` table (180/480) is only a fallback for a faction with no `FactionPhases`
  entry; every shipped faction has one, so 180/480 never actually applies in play.
  Each phase sets the target composition, wave budget, and the heaviest armor tier
  allowed.
- **Four tiers** — infantry / light / medium / heavy, with per-phase target ratios
  (EARLY 0:0:1:4, MID 0:1:2:4, LATE 1:1:2:4 as heavy:medium:light:infantry). Light vs
  medium is split at a 550-second recharge boundary.
- **Recharge-aware pool** — each unit's `;Nsec` reinforcement cooldown (baked into
  `recharge=`) benches it after a spawn, so the picker rotates units instead of failing.
- **Fail cooldown** — a failed (unaffordable) spawn benches that unit ~10s so the picker
  falls through to a cheaper tier and actually spends the manpower.
- **Dynamic catch-up** — the further behind on flags, the larger the wave budget and the
  shorter the gap between waves.
- **Faction composition bias** *(designed, not yet implemented — see
  `docs/superpowers/specs/2026-07-06-faction-composition-bias-design.md`)* — a per-faction
  minimum-count floor (e.g. ger medium armor, usa artillery, rus smg, jap mortar) grounded
  in each faction's real-world doctrine, layered as a short-circuit on top of the existing
  tier ratio rather than replacing it.

### Groups and routing
- **Group system** — up to 2 squads-of-squads share one attack target each
  (`ManageGroups`, `PickGroupTarget`). `ApportionArmor` front-loads each group's tier
  budget with armor when the army is behind on flags. `PickSubTarget` gives the second
  group its own front instead of duplicating the main group's target. Aux (support)
  units attach to a group without consuming its capacity.
- **Flag labeling** — at match start, every flag is tagged OWN/CONTESTED/ENEMY plus an
  enemy-distance rank (`LabelFlags`), from per-map coordinate data in
  `flag_sectors.lua` (54 of 57 RobZ 1v1/2v2/3v3 maps).
- **Frontier-first targeting** — `PickGroupTarget`/`FlagTier` rank candidates as
  recapture (just lost) > contested frontier > enemy frontier > deep enemy, where
  "frontier" means adjacent to a flag the team already holds (`IsFrontier`, adjacency
  synthesized from flag coordinates). This keeps the advance coherent instead of
  routing squads past intermediate enemy flags onto a deep, unsupported target.
  Never returns nil while any attackable flag exists — falls back a stage instead of
  stalling the group.
- **Home grace period** — for the first 240s, groups ignore their own home-sector
  flags and push forward rather than reinforcing base.
- **Lateral partition** — teammates' targets are split laterally to reduce overlap
  (`PartitionFlags`); currently degrades safely to "own everything" when the engine's
  playerId ordering isn't contiguous by team (see `ARCHITECTURE.md` Known gaps).

### Idle trickles (between waves, priority order, at most one spawn per tick)
- **MG point defense** — a small, capped trickle of mobile MG teams digs in on owned
  flags.
- **Artillery defenders** — rarer capped trickle of self-propelled/towed artillery.
- **Officer / AT-rifle keep-alive** — replaces these roles if they die off, without
  competing with the main wave budget.
- **Neutral-flag cappers** — single soldiers grab uncontested flags and commit to
  their target flag until it's capped or lost, instead of re-picking every rotation.
- **Airborne deep-strike** — a capped, late-phase-only trickle dropped near enemy
  bases; gated separately from the normal tier/wave system so it never floods early.
- **Ratio backfill** — keeps the field's composition near its phase target between
  waves.

## Layout

```
mod.info
ARCHITECTURE.md         -- structural map: modules, data flow, subsystems
resource/
  script/multiplayer/
    bot.lua            -- selection, phases, waves, groups, routing, trickles
    bot.data.lua       -- unit roster, recharge, Phases/FactionPhases/Purchases config
    flag_sectors.lua   -- generated per-map flag coords, sectors, base positions
    tests/             -- offline Lua tests (no engine needed)
  set/multiplayer/games/
    bots_generic.inc   -- AI economy tuning (overrides RobZ; load AFTER RobZ)
  set/stuff/gun/, set/stuff/reactive/
                       -- artillery weapon presets with PrepareTime=0
tools/                 -- offline Python generators (flag_sectors, unit meta,
                          artillery roster, aim-time), each with a test_*.py
docs/                  -- design specs, implementation plans, roadmap
```

## Tests

The pure selection functions run offline with stock Lua (5.x):

```sh
cd resource/script/multiplayer
luac -p bot.lua && luac -p bot.data.lua
lua tests/phase_spec.lua        # TierOf / CurrentPhase / DecideTier
lua tests/integration_spec.lua  # armorCap gating through GetUnitToSpawn
```

## Install

Load order matters: this mod must load **after** RobZ Realism so its
`bots_generic.inc` override wins. The mod folder lives in the game's `mods/`
directory (here, via a symlink to this repo).

## Notes

- `recharge=` values are derived from RobZ's `.set` `;Nsec` reinforcement timers, not
  the misleading `c(N)` field.
- Self-propelled artillery (`ArtilleryTank`) and the bugged static MG emplacements are
  excluded from spawning.
