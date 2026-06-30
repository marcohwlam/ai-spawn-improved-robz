# Artillery Pool Reference (RobZ 1.30.10)

Validated artillery roster derived from cbyyy2013 Better AI (RobZ 1.28.6) and corrected
to current RobZ 1.30.10 unit ids. Reference only — not wired into `bot.data.lua`.

Dropped (no current regular-MP equivalent): `sturmtiger` (hero-only), `bishop` (removed),
`m12gmc_vet` (folded into `m12gmc`), `203b4` (Guards-only -> `203b4_guard`),
`su152_guard` (cut -> `isu152_guard`).

Field defaults: `priority=1.0`, `min_team=1`, `min_income=2.0` (`2.5` when cost >= 1300),
`unlock` = RobZ value (also re-derivable via `build_unit_meta.py`).

## Roster (cost mp / unlock sec)

| Nation | Units |
|---|---|
| ger | wespe 750/900 · hummel 1280/1200 · sdkfz4 650/1200 · np_sdkfz251_1w 1500/1200 |
| ger2 | wespe_ger2 750/900 · sdkfz138_1 850/900 · sdkfz251_1_stuka 1500/1200 |
| ger_ss | wespe_ss 750/900 · hummel_ss 1280/1200 · sdkfz4_ss 650/1200 · np_sdkfz251_1w_ss 1600/1200 |
| eng | m7_eng 920/900 |
| usa | m7 920/900 · m12gmc 1350/1200 · m4a3c 900/1200 · np_t19 720/900 |
| rus | su122 550/1120 · su152 750/1120 · isu152 900/1120 · bm13 850/1200 · bm_8_24 500/900 · bm8-48 650/900 · np_bm31 1450/1200 · 280br5 1600/1200 |
| rus_guard | 203b4_guard 1300/1200 · bm13_guard 850/1200 · bm_8_24_guard 500/1200 · bm8-48_guard 650/900 · isu152_guard 1000/1120 · np_bm31_guard 1450/1200 · su122_guard 650/1120 |
| jap | ha-to 1100/1200 · ho-ni2 780/900 · ho-ro 960/1200 |

## Paste-ready Lua (bot.data.lua line format)

```lua
-- ger
{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe",            min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="hummel",           min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz4",           min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_sdkfz251_1w",   min_income=2.5, min_team=1, unlock=1200,},
-- ger2
{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe_ger2",       min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz138_1",       min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz251_1_stuka", min_income=2.5, min_team=1, unlock=1200,},
-- ger_ss
{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe_ss",         min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="hummel_ss",        min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="sdkfz4_ss",        min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_sdkfz251_1w_ss",min_income=2.5, min_team=1, unlock=1200,},
-- eng
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m7_eng",           min_income=2.0, min_team=1, unlock=900,},
-- usa
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m7",               min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m12gmc",           min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="m4a3c",            min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_t19",           min_income=2.0, min_team=1, unlock=900,},
-- rus
{priority=1.0, class=UnitClass.ArtilleryTank, unit="su122",            min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="su152",            min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="isu152",           min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm13",             min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm_8_24",          min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm8-48",           min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_bm31",          min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="280br5",           min_income=2.5, min_team=1, unlock=1200,},
-- rus_guard
{priority=1.0, class=UnitClass.ArtilleryTank, unit="203b4_guard",      min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm13_guard",       min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm_8_24_guard",    min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="bm8-48_guard",     min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="isu152_guard",     min_income=2.0, min_team=1, unlock=1120,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="np_bm31_guard",    min_income=2.5, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="su122_guard",      min_income=2.0, min_team=1, unlock=1120,},
-- jap
{priority=1.0, class=UnitClass.ArtilleryTank, unit="ha-to",            min_income=2.0, min_team=1, unlock=1200,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="ho-ni2",           min_income=2.0, min_team=1, unlock=900,},
{priority=1.0, class=UnitClass.ArtilleryTank, unit="ho-ro",            min_income=2.0, min_team=1, unlock=1200,},
```
