# Axis Minor faction support: design

**Date:** 2026-07-14
**Status:** Design approved, pending spec review
**Prior research:** `docs/research/2026-07-12-axis-minor-faction-support.md` (roster, unlock formula)

## Goal

Make the bot field RobZ's ninth faction, `axis_minor`, at parity with the existing eight:
a full spawn roster, per-faction phase boundaries and doctrine bias, and roster-checker
coverage. Data and configuration only; no `bot.lua` logic changes.

## Approach

Every spawn mechanism (tier classification, trickles, gun-rating, armorLead, phase
resolution) is already faction-agnostic and keyed off `Instance.army`. Supporting a new
faction is purely: add its roster block, its `FactionPhases`/`FactionBias` entries, and
its name to the roster-checker's faction list. `bot.lua` is untouched.

`axis_minor` is a six-nation coalition (Bulgarian, Hungarian, Romanian, Finnish, Italian,
plus two captured German heavies). Per the approved decisions: field the **whole roster,
all nations mixed** (RobZ ships them as one faction), and **drop the heavy tier** in the
late-phase composition (Japan-style) since the only heavies are two rare captured vehicles.

## Non-goals

- No `bot.lua` changes. If a unit needs new routing logic, it is out of scope for v1.
- No new trickle types, caps, or cadence constants.
- Hero units and single-soldier reinforcement fillers are excluded from the roster.
- No Steam Workshop / release work in this spec (separate follow-up).

## Architecture

```
                 RobZ gamelogic.pak (read-only, offline reference)
                 set/multiplayer/units/axis_minor/{squads,vehicles}.set
                          │  classify by UnitClass + unlock = round(c*(|fore|+1))
                          ▼
   resource/script/multiplayer/bot.data.lua
     ├── Purchases[...]["axis_minor"]  = { <roster rows> }        (new; the bulk)
     ├── FactionPhases["axis_minor"]   = { mid, late, lateTargets } (heavy dropped)
     └── FactionBias["axis_minor"]     = { early, mid, late }       (doctrine floors)
                          │
   tools/check_unit_roster.py   FACTIONS += "axis_minor"   (validation wiring)
   resource/script/multiplayer/gun_ratings.lua   already covers axis_minor armor
   resource/script/multiplayer/bot.lua           UNCHANGED
```

## Data flow (spawn-time, identical to every other faction)

```
OnGameStart
   Instance.army = "axis_minor"
   ResolvePhases("axis_minor")  ──►  Context.Phases   (mid=650, late=1500, no heavy late)
        │
        ▼
OnGameQuant ──► DecideTier(elapsed, field)
        │           picks a tier from Context.Phases[phase].targets + FactionBias floor
        ▼
   GetUnitToSpawn ──► candidates = Purchases["axis_minor"] rows in that tier,
        │             filtered by  unlock (elapsed >= row.unlock)
        │                          min_income / min_team
        │             weighted by  priority * GunRatingMul(unit)  (gun-rating already keyed)
        ▼
   Commands:Spawn(unit)  ──►  same wave / trickle / armorLead path as all factions
```

## Component 1: roster block `Purchases[...]["axis_minor"]`

Class mapping and per-row fields, from the prior research and RobZ data. `unlock` is
`round(c*(|fore|+1))` (the formula merged in PR #23), applied **only to vehicle/gun rows**;
infantry and aux-infantry rows carry no `unlock` (eligible from t=0, matching every shipped
faction). `bt42` uses the formula value 540 (not its stale `;270` comment), per the
pure-formula policy.

### Infantry (no unlock gate)

| unit | class | tags | priority |
|---|---|---|---|
| `Bulgarian_Infantry` | Infantry | `line, inf="rifle"` | 2.0 |
| `romanian_rifle_squad` | Infantry | `line, inf="rifle"` | 2.0 |
| `hungarian_smg_squad` | Infantry | `inf="smg", smg=true` | 2.5 |
| `Hungarian_Assualt_Infantry` | Infantry | `inf="smg", elite=true` | 2.5 |
| `Bersaglieri` | Infantry | `inf="rifle"` | 2.0 |
| `Alpini` | Infantry | `inf="rifle"` | 1.5 |
| `Paracadutisti` | Infantry | `inf="rifle", elite=true` | 1.0 |
| `fin_kaukopartio` | Infantry | `inf="rifle"` | 2.0 |
| `Sissi` | Infantry | `inf="rifle"` | 1.5 |
| `fin_pioneer` | Infantry | `inf="rifle", flame=true` | 1.0 |
| `Motorized_Hungarian_Rifles` | Infantry | `mech=true` | 1.5 |
| `Bersaglieri_Mot` | Infantry | `mech=true` | 1.5 |

### Aux infantry (no unlock gate)

| unit | class | priority |
|---|---|---|
| `panzerfaust` | ATInfantry | 1.0 |
| `panzershreck` | ATInfantry | 1.0 |
| `pzb_at_Rifle` | ATInfantry | 1.0 |
| `Boys_AT_Rifle` | ATInfantry | 1.0 |
| `solothurn_31m` | MG | 1.0 |
| `zb_vz26` | MG | 1.0 |
| `breda30_bers` | MG | 1.0 |
| `finnish_sniper` | Sniper | 0.8 |
| `flamers` | Infantry (`flame=true`) | 1.0 |
| `officer` | Officer | 0.3 |

### Armor and guns (unlock = formula)

| unit | class | tags | unlock | min_income | priority |
|---|---|---|---|---|---|
| `fiataa35` | Vehicle | `support=true` | 180 | 1.0 | 0.8 |
| `ab41` | Vehicle | | 310 | 1.0 | 1.5 |
| `Lancia1ZM` | Vehicle | | 310 | 1.0 | 1.0 |
| `csaba40m` | Vehicle | | 320 | 1.0 | 1.0 |
| `panhard_rom` | Vehicle | | 360 | 1.0 | 1.0 |
| `csaba39m` | Vehicle | | 380 | 1.0 | 1.5 |
| `toldi1` | Tank | (light) | 370 | 1.0 | 1.5 |
| `nimrod` | AATank | | 420 | 1.5 | 1.0 |
| `m15_contraereo` | AATank | | 420 | 1.5 | 1.0 |
| `m1139_seq` | ArtilleryTank | `assault=true` | 490 | 1.5 | 1.5 |
| `m7518_seq` | ArtilleryTank | `assault=true` | 490 | 1.5 | 1.5 |
| `tacam_t60` | ATTank | | 520 | 1.5 | 1.5 |
| `toldi2` | Tank | (light) | 530 | 1.0 | 1.5 |
| `tacam_r2` | ATTank | | 540 | 1.5 | 1.5 |
| `bt42` | ArtilleryTank | `assault=true` | 540 | 1.5 | 1.5 |
| `turan1` | Tank | `weight="medium"` | 650 | 1.5 | 1.5 |
| `turan2` | Tank | `weight="medium"` | 850 | 1.5 | 2.0 |
| `turan3` | Tank | `weight="medium"` | 950 | 1.5 | 2.0 |
| `zrinyi2` | ArtilleryTank | `assault=true` | 950 | 1.5 | 1.5 |
| `zrinyi1` | ATTank | | 950 | 1.5 | 1.5 |
| `3ro` | ATTank | | 950 | 1.5 | 1.0 |
| `m9053` | ATTank | | 1080 | 1.5 | 1.0 |
| `sgrw_42` | Mortar | | 600 | 1.0 | 1.0 |
| `22` | Mortar | | 180 | 1.0 | 1.0 |

**Towed howitzers excluded from v1** (`cannone9053`, `obice14940`, `pak43_towed_hun`):
`UnitClass.Howitzrer` is collected by no picker and is explicitly excluded from the aux
pool in `bot.lua` (SPGs-disabled block), so a Howitzrer row never spawns — it is a dead
class. Routing them as non-assault `ArtilleryTank` (rear artillery) would make them live
but towed-gun behavior through the arty trickle is unverified. Left out of v1; axis_minor's
fire support is its assault guns (Semovente/Zrinyi II/BT-42) plus the two mortars. Adding
rear artillery is a follow-up.
| `panther5g_hungarian` | HeavyTank | `min_team=1` | 1500 | 2.0 | 1.0 |
| `pz6e_hungarian` | HeavyTank | `min_team=1` | 1752 | 2.0 | 1.0 |

Excluded (heroes, cost-1-16 `b(hero)`, single-soldier fillers): `tiger_ace_hun`, `karlthor`,
`SissiSP`, `white_death`, `Recon_in_Force`, `hungarian_mobile_unit`, `guard_the_flanks`,
`vet_td`, `big_gun`, `Elite_Resita`, `turan3_vet`, `carcano`, `orita`, `suomi_m31`,
`danuvia`, `zb_24rifle`, tankcrew/sapper/ammo/supply utility.

## Component 2: `FactionPhases["axis_minor"]`

```lua
["axis_minor"] = { mid = 650, late = 1500,
                   lateTargets = { medium = 2, light = 2, rifle = 1, smg = 1 } },
```

- `mid = 650` — first medium-tier tank (`turan1` at 650). The earlier Semovente assault
  guns (490) are `ArtilleryTank` (aux), so they do not set the medium boundary; `TierOf`
  returns nil for them.
- `late = 1500` — first heavy (captured Panther at 1500), but `lateTargets` **omits `heavy`**
  (Japan pattern): the two captured heavies stay in the pool as opportunistic picks, the
  late composition leans on Turan/Zrinyi mediums instead.

## Component 3: `FactionBias["axis_minor"]`

Doctrine: a second-line defensive coalition with weak, late tanks that leans on AT infantry
and tank destroyers rather than a tank spearhead.

```lua
axis_minor = {
    early = { rifle = 1 },              -- broad multi-national infantry defense
    mid   = { attank = 1 },             -- armor threat met by TDs/AT (their armor niche)
    late  = { attank = 1, medium = 1 }, -- Turan mediums alongside sustained TD presence
},
```

## Component 4: roster-checker wiring

`tools/check_unit_roster.py` line 7: add `"axis_minor"` to `FACTIONS`. Squad ids are
`side(axis_minor)`-tagged, already handled by `scan_side_tagged_ids`; vehicle ids come from
the per-directory scan. After the change the checker must report 0 problems for axis_minor.

## Testing

| Layer | Test | Asserts |
|---|---|---|
| compile | `luac -p bot.data.lua` | roster block parses |
| roster | `check_unit_roster.py <pak> bot.data.lua` | every axis_minor `unit=` id exists in RobZ; 0 mismatches |
| phases | `tests/axis_minor_spec.lua` | `ResolvePhases("axis_minor")` gives early ends 650, mid ends 1500; late `targets.heavy == nil`; roster block non-empty |
| regression | full `tests/*_spec.lua` | 25/25 still pass |

`tests/axis_minor_spec.lua` follows the harness bootstrap used by `phase_spec.lua`.

## Files

- Modify: `resource/script/multiplayer/bot.data.lua` (roster block, FactionPhases, FactionBias)
- Modify: `tools/check_unit_roster.py` (FACTIONS)
- Create: `resource/script/multiplayer/tests/axis_minor_spec.lua`
- Modify: `README.md`, `ARCHITECTURE.md` (note the ninth faction)

## Rollback / safety

The roster block, phase entry, and bias entry are additive and keyed by `"axis_minor"`.
No other faction reads them. Removing the three entries reverts to the prior behavior
(axis_minor bots fall through `ResolvePhases` to the global `Phases` table and have no
roster, i.e. the pre-change state). No shared constant, cap, or cadence is touched.
