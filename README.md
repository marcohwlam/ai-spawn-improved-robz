# AI Spawn Improved for RobZ 1.30.x

A Lua-only AI bot mod for **Men of War: Assault Squad 2** (game 3.262) running with the
**RobZ Realism Mod 1.30.x**. It replaces the stock bot spawn logic with a phase-based,
four-tier wave system and recharge-aware unit pooling. No entity assets, so it does not
conflict with other content mods.

## What it does

- **Wave spawning** — the bot saves manpower and dumps it in waves (~30s cadence),
  spreading each wave across game ticks so the engine accepts every spawn.
- **Time phases** — EARLY (0-180s), MID (180-480s), LATE (480s+). Each phase sets the
  target composition, wave budget, and the heaviest armor tier allowed.
- **Four tiers** — infantry / light / medium / heavy, with per-phase target ratios
  (EARLY 0:0:1:4, MID 0:1:2:4, LATE 1:1:2:4 as heavy:medium:light:infantry). Light vs
  medium is split at a 550-second recharge boundary.
- **Recharge-aware pool** — each unit's `;Nsec` reinforcement cooldown (baked into
  `recharge=`) benches it after a spawn, so the picker rotates units instead of failing.
- **Fail cooldown** — a failed (unaffordable) spawn benches that unit ~10s so the picker
  falls through to a cheaper tier and actually spends the manpower.
- **Dynamic catch-up** — the further behind on flags, the larger the wave budget and the
  shorter the gap between waves.
- **Between-wave backfill** — a light trickle keeps the field near its target ratio.
- **MG point defense** — a small, capped trickle of mobile MG teams digs in on owned flags.
- **Neutral-flag cappers** — single soldiers grab uncontested flags.

## Layout

```
mod.info
resource/
  script/multiplayer/
    bot.lua            -- selection, phases, waves, trickles
    bot.data.lua       -- unit roster, recharge, Phases config
    tests/             -- offline Lua tests (no engine needed)
  set/multiplayer/games/
    bots_generic.inc   -- AI economy tuning (overrides RobZ; load AFTER RobZ)
docs/                  -- design spec + implementation plan
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
