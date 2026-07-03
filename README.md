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

## Key feature diagrams

### Win/loss-reactive wave scaling
`FlagDeficit()` (enemy-held flags minus ours) drives both wave budget and cadence in one
direction only today — fight harder when behind. There is no symmetric "ease off + dig in"
half yet when ahead; see `docs/superpowers/specs/` for the pending design.

```
FlagDeficit() > 0 (losing)          FlagDeficit() == 0          FlagDeficit() < 0 (ahead)
        |                                   |                            |
        v                                   v                            v
  budget x(1.0 + 0.25*deficit)         budget x1.0                 budget x1.0 (unchanged)
  capped at x2.5                       base wave interval           base wave interval
        |
        v
  interval / (1.0 + 0.25*deficit)
  floored at MinWaveIntervalSec
```

### Frontier-first targeting + capture-settle grace
```
PickGroupTarget() candidate ranking (best to worst):
  1. recapture       flag we just lost           (LostStamp within window)
  2. contested front  neutral/contested, adjacent to a flag we hold (IsFrontier)
  3. enemy frontier   enemy-held, adjacent to a flag we hold
  4. deep enemy       enemy-held, not adjacent to anything we hold  (last resort)

  occupant flips to us ──► FlagJustCaptured() holds it at tier "contested front"
                            for CaptureSettleSec=30s, so the group/capper doesn't
                            immediately drop it and leapfrog to a deeper target
                            before the position is actually secure.
```

### Assault guns vs backline artillery (two disjoint pools, one flag)
```
                    ArtilleryTank roster entry
                              |
                assault=true? ----------------- no --------------.
                    |                                            |
                    v                                            v
        GetAssaultGunUnit()                              GetArtyUnit()
        (stuh42, brummbar, su122, ...)                    (wespe, hummel, sdkfz4, ...)
                    |                                            |
                    v                                            v
        escorts Context.Groups[1]                    sits on rearmost owned flag
        (main group), follows ITS target              in ArtyReach safe-band,
        -- direct-fire close support                   fires at ArtyNearestTarget
                    |                                    -- indirect-fire backline
                    v
        AssaultGunCap=1 per DESIGNATED
        bot instance (odd playerId half
        of a teammate pair, so a 2-bot
        team fields ~1, not 2)
```

### Support vehicles: dedicated trickle, not the crowded aux pool
```
generic aux pool (collectAux):           dedicated keep-alive trickle:
  ~7 duplicate MG entries                  GetSupportVehicleUnit()
  + AT entries + sniper/flame/officer      -> SupportVehicleCap=1 guaranteed slot
  + AuxPerCycle=2 picks per full cycle      -> unlock-correct per faction
       |                                         (250/9, 251/9, 234/3, ...)
       v
  support=true Vehicle EXCLUDED here  ─────────────┘
  (would otherwise lose almost every draw)
```

### Late-game heavy-tank affordability guard
```
AttemptSpawn(heavy tier, late phase)
        |
   spawn fails? ── no ──► reset HeavyFailStreak, ConsecutiveHeavyFails
        | yes
        v
   record this unit id in HeavyFailStreak{}
        |
   3 DISTINCT heavy ids failed?  ── or ──  9 consecutive fails (single-heavy-type roster)?
        |                                             |
        └─────────────────── either ──────────────────┘
                              |
                              v
              SpawnPauseUntil = now + 150s
              -> SpawnSlotFree() returns false for every trickle
                 (wave/backfill/capper/officer/AT-rifle/assault-gun/
                  support-vehicle/arty/deep-strike/defender) until it elapses,
                 letting MP bank up instead of draining on filler tiers.
```

### Crash-safe unit cap
```
per bot instance:  OwnedSquadCount()  <  CurrentSquadCap()
                    (combat=1, aux=0.5)   (24 early / 26 mid / 28 late)
                          |
        2v2 (<=4 bot instances): ~96 weighted / ~130-160 real squads
        under the ~200-squad level that OOM'd the 32-bit engine.
        Lower MaxLiveSquads for bigger team games.
```

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
docs/                  -- roadmap.md + superpowers/specs (pending) and
                          superpowers/archive (shipped design specs, plans, handoff)
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
