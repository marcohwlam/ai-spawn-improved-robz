# AI Spawn Improved for RobZ 1.30.x — Design Spec

## Problem

The cbyyy2013 "Better AI Performed" mod (built for RobZ 1.28.6) crashes MoWAS2 on startup when loaded alongside RobZ 1.30.x. Root cause: cbyyy includes a `resource/entity` folder with custom effect definitions that conflict with RobZ 1.30.10's `entity.pak`. The mod.info warning even documents this ("delete the entity folder if the game is affected"). Additionally, the bot logic has minor bugs and global state issues worth cleaning up.

## Goal

A new, standalone Lua-only AI mod that:
- Works with RobZ Realism 1.30.x (game version 3.262) without crashes
- Improves spawn unit selection logic over cbyyy's baseline
- Carries forward useful patterns from the frontlines AI mod
- Contains no entity, texture, sound, or map assets

## Non-Goals

- Modifying RobZ entity stats or unit balance
- Supporting game versions other than 3.262
- Adding new factions beyond what cbyyy covered

## Mod Structure

```
mods/
└── ai-spawn-improved-robz/
    ├── mod.info
    └── resource/
        └── script/
            └── multiplayer/
                ├── bot.lua
                └── bot.data.lua
```

No other files. No entity, texture, sound, or interface assets.

## Architecture

```
┌────────────────────────────────────────────────────┐
│                  ai-spawn-improved                  │
│                                                    │
│  ┌─────────────────┐    ┌────────────────────────┐ │
│  │    bot.lua      │───▶│     bot.data.lua       │ │
│  │                 │    │                        │ │
│  │  PIter          │    │  MaxSquadSize          │ │
│  │  GetUnitToSpawn │    │  OrderRotationPeriod   │ │
│  │  CaptureFlag    │    │  FlagPriority          │ │
│  │  event hooks    │    │  UnitClass             │ │
│  └────────┬────────┘    │  Purchases[]           │ │
│           │             └────────────────────────┘ │
│           ▼                                        │
│  ┌─────────────────┐                              │
│  │    BotApi       │  (game engine, read-only)    │
│  │  .Commands      │                              │
│  │  .Scene.Flags   │                              │
│  │  .Scene.Squads  │                              │
│  │  .Events        │                              │
│  └─────────────────┘                              │
└────────────────────────────────────────────────────┘
```

## Data Flow

```
Game Engine
    │
    ├─[GameStart]──▶ PIter:new(Purchases)
    │                      │
    │               UpdateUnitToSpawn()
    │
    ├─[GameQuant]──▶ Spawn(SpawnInfo)
    │                 │fail        │success
    │                 ▼            ▼
    │          UpdateUnitToSpawn() (advance to next wave)
    │                 │
    │          GetNextUnitToSpawn(PIter)
    │                 │
    │          GetUnitToSpawn(units[army])
    │            ├─ filter: income threshold, team size threshold
    │            └─ weight adjust:
    │                 ├─ losing flags  → Infantry ×2.5, Tank ×2.0, ArtilleryTank ×2.5
    │                 ├─ winning flags → Sniper ×1.5, ATTank ×0.5, HeavyTank ×1.0
    │                 ├─ enemy has tanks → ATInfantry ×2.0, ATTank ×1.5
    │                 ├─ no enemy tanks  → ATInfantry ×0.3, suppress ATTank (0)
    │                 ├─ Airborne class  → suppress duplicate (local flag per spawn)
    │                 └─ Rare class      → suppress after first per spawn event
    │
    └─[GameSpawn]──▶ SetSquadOrder(CaptureFlag, squad, OrderRotationPeriod)
                           │
                      QuantTimer loop
                           │
                      GetFlagToCapture() — weighted random by FlagPriority
                           │
                      BotApi.Commands:CaptureFlag()
```

## bot.lua — Key Improvements Over cbyyy

### 1. No global state pollution
cbyyy's frontlines version uses `isAirborne` and `isRare` as bare globals, meaning they persist across spawn events unpredictably. The new implementation tracks these as fields on a per-spawn-event local or resets them cleanly in `OnGameSpawn`.

### 2. Correct IsNeutralFlag
The frontlines bot.lua has a copy-paste bug:
```lua
-- WRONG (frontlines):
function IsNeutralFlag(flag)
    return flag.occupant == BotApi.Instance.enemyTeam  -- same as IsEnemyFlag!
end
```
The new implementation correctly checks for neither team:
```lua
function IsNeutralFlag(flag)
    return flag.occupant ~= BotApi.Instance.team
       and flag.occupant ~= BotApi.Instance.enemyTeam
end
```

### 3. AT unit suppression when no armor threat
When `BotApi.Commands:EnemyHasTanks()` is false, AT infantry weight drops to 0.3x (cbyyy uses 0.5x) and ATTank is fully suppressed (weight 0). This frees slots for more useful units when armor is not a factor.

### 4. Rare unit throttle per spawn event
`isRare` resets to 0 at the start of each `OnGameSpawn`. Only one Rare unit spawns per spawn event. This matches frontlines behavior but implemented cleanly as a local reset rather than a persistent global.

### 5. Airborne duplicate prevention
`isAirborne` resets to 1 in `OnGameSpawn`. If the selected unit is Airborne class, the flag flips to 2 and subsequent Airborne selections in the same event return weight 0. Prevents double-Airborne waves.

## bot.data.lua — Content

Taken directly from cbyyy2013's bot.data.lua with these changes:
- `UnitClass` table extended to include `Airborne`, `Rare`, and `Howitzrer` (matching frontlines spellings for compatibility)
- Unit entity names unchanged — RobZ changes unit stats via entity.pak but does not rename entity IDs between minor versions
- If a unit fails to spawn in-game (silent failure, not a crash), that unit's entry can be commented out and tested incrementally

## mod.info

```
{Mod
    {Name "AI Spawn Improved for RobZ 1.30.x"}
    {Desc "Improved bot spawn logic for RobZ Realism 1.30.x. Lua-only, no entity assets. Based on cbyyy2013 Better AI and frontlines AI concepts."}
    {MinGameVersion "3.262"}
    {MaxGameVersion "3.262"}
}
```

No `FileId` (local mod, not uploaded to Workshop yet).

## Load Order

In-game Mods screen, enable in this order:
1. RobZ Realism mod 1.30.10
2. ai-spawn-improved-robz

Do NOT enable cbyyy2013's Better AI at the same time — it will reintroduce the entity conflict crash.

## Testing Checklist

- [ ] Game starts without crash with both RobZ 1.30.10 and this mod enabled
- [ ] AI spawns units in skirmish vs CPU match
- [ ] AT units suppressed when player has no armor on map
- [ ] AI prioritizes infantry when losing flag count
- [ ] No double-Airborne waves in a single spawn event
- [ ] Game version 3.262 confirmed in mod.info
