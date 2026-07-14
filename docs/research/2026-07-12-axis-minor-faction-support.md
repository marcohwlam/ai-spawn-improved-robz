# Axis Minor faction support: exploration report

**Date:** 2026-07-12
**Source:** RobZ Realism Mod 1.30.10 (`mods/robz realism mod 1.30.10/resource/gamelogic.pak`)
**Status:** Research only. No code changed. Scopes the work to make the bot spawn `axis_minor`.

## 1. What `axis_minor` is

RobZ ships a ninth playable faction, `axis_minor`, alongside the eight the bot already
supports (`eng ger ger_ss ger2 usa rus rus_guard jap`). It is a **multi-nation coalition**,
not a single army. Six nationalities share one roster, tagged by unit-id prefix:

| Prefix | Nation | Character |
|---|---|---|
| `axm_bul_` / `vs_bul` | Bulgaria | cheap line infantry, ZB MGs, ammo/support |
| `axm_hun_` / `v_hun` | Hungary | the armor core (Toldi, Turan, Zrinyi, Csaba, Nimrod) |
| `axm_rom_` / `v_rom` | Romania | tank destroyers (TACAM, Resita AT gun) |
| `axm_fin_` / `v_fin` | Finland | recon/infiltration infantry (Sissi, Kaukopartio), BT-42, snipers |
| `axm_ita_` / `v_ita` | Italy | Bersaglieri/Alpini/Para infantry, Semovente, AB41 |
| `axm_ger_` (captured) | German kit | Tiger I / Panther / Karl heroes crewed by Hungarians |

Roster files (the buyable spawn buttons the bot needs):
- `set/multiplayer/units/axis_minor/squads.set` (39 squad entries)
- `set/multiplayer/units/axis_minor/vehicles.set` (65 vehicle/gun entries)

All units are tagged `t(... 44 45)` (a 1944-45 faction) at `{level 1}`, i.e. no tech-level
gating. Timing is by per-unit unlock seconds (see §4).

## 2. Doctrine summary (drives FactionBias)

Axis Minor is **infantry-heavy with weak, late, fragmented armor**. It has:
- a broad infantry line across five nations (rifle, SMG, assault, recon, paratrooper),
- strong light armor / armored cars (Csaba, AB41, Toldi) but only mediocre mediums (Turan
  tops out at 135 mm AP, Zrinyi II assault gun at 206 mm),
- **no native heavy tank** — the only heavies are two captured German vehicles
  (`pz6e_hungarian` Tiger I, `panther5g_hungarian` Panther) at 1500 MP, late and rare,
- a deep tank-destroyer / assault-gun bench (TACAM, Resita, Semovente m9053, Zrinyi I).

This mirrors Japan's shape (no real heavy line), so the late-game composition should likely
**drop or de-weight the heavy tier** the way `FactionPhases["jap"].lateTargets` does.

## 3. Full roster, classified into the bot's `UnitClass` taxonomy

Gun-rating column = value already present in `gun_ratings.lua` (the extractor is army-wide,
so axis_minor armor was swept in with everyone else). Blank = unrated → `GunRatingMul`
returns neutral `1.0x` (safe, but worth verifying before release — see §5).

### 3a. Infantry (class `Infantry`)

| unit id | nation | tags to set | cost |
|---|---|---|---|
| `Bulgarian_Infantry` | BUL | `line=true, inf="rifle"` | 75 |
| `romanian_rifle_squad` | ROM | `line=true, inf="rifle"` | 114 |
| `hungarian_smg_squad` | HUN | `inf="smg", smg=true` | 84 |
| `Bersaglieri` | ITA | `inf="rifle"` | 158 |
| `Alpini` | ITA | `inf="rifle"` (has organic sniper) | 215 |
| `Paracadutisti` | ITA | `inf="rifle", elite=true` | 311 |
| `Hungarian_Assualt_Infantry` | HUN | `inf="smg", elite=true` (pzf + flamer) | 186 |
| `fin_kaukopartio` | FIN | `inf="rifle"` (recon) | 148 |
| `Sissi` | FIN | `inf="rifle"` (infiltration) | 159 |
| `fin_pioneer` | FIN | `inf="rifle", flame=true` | 220 |
| `Motorized_Hungarian_Rifles` | HUN | `mech=true` (v1=Botond) | 109 |
| `Bersaglieri_Mot` | ITA | `mech=true` (v1=fiat35) | 174 |

### 3b. Support / weapon-team infantry

| unit id | nation | class | tags | cost |
|---|---|---|---|---|
| `Boys_AT_Rifle` | FIN | `ATInfantry` | | 66 |
| `pzb_at_Rifle` | BUL | `ATInfantry` | | 101 |
| `panzerfaust` | HUN | `ATInfantry` | | 52 |
| `panzershreck` | ROM | `ATInfantry` | | 114 |
| `solothurn_31m` | HUN | `MG` | | 46 |
| `zb_vz26` | BUL | `MG` | | 44 |
| `breda30_alpini` / `breda30_bers` / `breda30_para` | ITA | `MG` | | 55-80 |
| `finnish_sniper` | FIN | `Sniper` | | 90 |
| `flamers` | FIN | `Infantry` | `flame=true` | 83 |
| `officer` / `officers_40` | FIN | `Officer` | | 0 |

### 3c. Light armor / armored cars (class `Vehicle`)

| unit id | nation | gun-rating | unlock | cost |
|---|---|---|---|---|
| `csaba39m` | HUN | 46 | — | 280 |
| `csaba40m` | HUN | — | — | 220 |
| `ab41` | ITA | — | — | 190 |
| `Lancia1ZM` | ITA | — | — | 140 |
| `panhard_rom` | ROM | 92 | — | 180 |
| `L35LF` | ITA | — (flame tankette) | — | 350 |
| `as423` / `fiat626_inf` / `botond` | ITA/BUL/HUN | transports | — | 75-120 |

### 3d. Light tanks & mediums (class `Tank`)

| unit id | nation | weight | gun-rating | unlock | cost |
|---|---|---|---|---|---|
| `toldi1` | HUN | light | 46 | — | 250 |
| `toldi2` | HUN | light | — | — | 260 |
| `turan1` | HUN | medium | 82 | — | 375 |
| `turan2` | HUN | medium | — | — | 425 |
| `turan3` | HUN | medium | 135 | — | 500 |
| `zrinyi2` | HUN | medium (assault gun) | 206 | — | 550 |
| `bt42` | FIN | light (assault gun) | — | 270 | 320 |
| `m1139_seq` / `m7518_seq` | ITA | medium (Semovente) | — | — | 260-280 |

### 3e. Tank destroyers (class `ATTank`)

| unit id | nation | gun-rating | unlock | cost |
|---|---|---|---|---|
| `tacam_t60` | ROM | 86 | 520 | 290 |
| `tacam_r2` | ROM | 86 | 540 | 300 |
| `zrinyi1` | HUN | 135 | — | 500 |
| `m9053` | ITA | 137 | 1080 | 850 |
| `3ro` | ITA | — | — | 700 |
| `m149` | ITA | — (SP gun) | — | 1100 |

### 3f. AA (class `AATank`)

| unit id | nation | gun-rating | cost |
|---|---|---|---|
| `nimrod` | HUN | — | 320 |
| `m15_contraereo` | ITA | 46 | 290 |
| `fiataa35` | ITA | 46 | 160 |

### 3g. Heavy tanks (class `HeavyTank`) — captured German, rare/late

| unit id | nation | gun-rating | cost |
|---|---|---|---|
| `pz6e_hungarian` (Tiger I) | HUN(capt) | 162 | 1500 |
| `panther5g_hungarian` (Panther) | HUN(capt) | 187 | 1500 |

### 3h. Artillery & mortars (class `Howitzrer` / `Mortar`)

| unit id | nation | class | unlock | cost |
|---|---|---|---|---|
| `sgrw_34` / `sgrw_42` | ROM | Mortar | — | 320/650 |
| `22` / `skoda_75mm_gebirgskanone` | ITA | Mortar | 180 | 170/320 |
| `bredaM31` / `bredasafat77_stan` | ITA | Mortar/AT gun | — | 75-100 |
| `37mm_bofors` | FIN | AT gun | — | 180 |
| `cannone9053` | ITA | Howitzrer | 900 | 750 |
| `obice14940` / `obice210` | ITA | Howitzrer | — | 750/900 |
| `flak36a_fin` / `155mm_mle1917` | FIN | Howitzrer | 1080 | 700/650 |
| `pak43_towed_hun` | HUN | Howitzrer/AT | 1200 | 850 |

### 3i. Exclude from bot spawn

- **Hero units** (`b(hero)`, cost 1-16): `SissiSP`, `white_death`, `Elite_Resita`,
  `Recon_in_Force`, `hungarian_mobile_unit`, `guard_the_flanks`, `vet_td`, `big_gun`,
  `tiger_ace_hun`, `karlthor`, `turan3_vet`. Map the existing factions' convention (heroes
  are not roster spawn candidates).
- **Single-soldier reinforcements** (cost 13): `carcano`, `zb_24rifle`, `orita`,
  `suomi_m31`, `danuvia` — fillers, not squads.
- **Utility** (`tankcrew`, `vet_tankcrew`, `sappers`, `vehic_supporter`, `Radioman`,
  `AP_Miners`, `AT_Miners`, ammo boxes).

## 4. Unlock timing — where RobZ actually stores it

**Finding: RobZ has no machine-readable unlock schedule. Per-unit unlock seconds exist only
as hand-written `;NNNsec` trailing comments on the `.set` lines.** Confirmed by:

- The unit tuple has no time field. `c()` is call cooldown, `sc()` is spawn cost (== `{cost}`),
  `cp()` is population, `b(vN)` is the buy tab. None equals the commented second value
  (`pz3_m`: `c(10) sc(270)` but `;630sec`).
- The MP game-mode configs (`combat.set`, `frontline.set`, `battle_zones.set`) define tabs
  (`{buttons "squad1 squad2 v1..v12 sf"}`) and a `{period 180}` wave, but no per-unit time gate.
- RobZ's own bot roster (`script/multiplayer/bot.data.lua` inside the pak) gates units by
  **year** (`period = "39 40 41 42"`), never by seconds. Its `["axis_minor"]` block is an
  **infantry-only stub** (28 infantry entries + one `as423` scout car, no armor/TD/artillery),
  so it offers no armor priorities or timings to copy either.

So the bot's `unlock=<sec>` for the existing eight factions was transcribed by hand from the
`;NNNsec` comments; where RobZ omitted the comment, the authors already derived the value by
tier/cost analogy. Comment coverage is partial even for shipped factions:

| faction | buyable lines | annotated `;NNNsec` | coverage |
|---|---|---|---|
| ger | 179 | 94 | 52% |
| usa | 133 | 77 | 57% |
| jap | 135 | 82 | 60% |
| **axis_minor** | 102 | 24 | **23%** |

## 4a. Unlock is computable — `unlock = round(c * (|fore| + 1))`

The `;NNNsec` comment is not the true source; it is a hand-written cache of a formula. Fitting
against every annotated line across all nine factions recovers the generative rule the RobZ
authors used:

```
unlock = round( c * (|fore| + 1) )      c = c(N) cooldown,  fore = |{fore N}| / |f(N)|
```

420 annotated lines match it exactly, 330 uncommented lines gain a value from it, and 102
comments **drift** from it (prefer the formula — see `docs/REFERENCE.md` "Deriving `unlock`").
Applied to the axis_minor combat roster (validated where a comment exists):

| unit | c | \|fore\| | unlock (formula) | note |
|---|---|---|---|---|
| `fiataa35` (AA) | 10 | 17 | 180 | == comment |
| `22` / `skoda_75mm` (mortar) | 30 | 5 | 180 | == comment |
| `ab41` / `Lancia1ZM` | 10 | 30 | 310 | |
| `csaba40m` | 10 | 31 | 320 | |
| `panhard_rom` | 10 | 35 | 360 | |
| `toldi1` | 10 | 36 | 370 | |
| `csaba39m` | 10 | 37 | 380 | |
| `resita_seq` (AT gun) | 10 | 38 | 390 | == comment |
| `nimrod` / `m15_contraereo` (AA) | 30 | 13 | 420 | |
| `m1139_seq` / `m7518_seq` (Semovente) | 10 | 48 | 490 | |
| `tacam_t60` (TD) | 10 | 51 | 520 | == comment |
| `toldi2` | 10 | 52 | 530 | |
| `tacam_r2` (TD) | 10 | 53 | 540 | == comment |
| `sgrw_42` (mortar) | 60 | 9 | 600 | |
| `turan1` | 10 | 64 | 650 | |
| `turan2` | 10 | 84 | 850 | |
| `cannone9053` (how) | 60 | 14 | 900 | == comment |
| `turan3` / `zrinyi1` / `zrinyi2` / `3ro` | 10 | 94 | 950 | |
| `flak36a_fin` (how) | 60 | 17 | 1080 | == comment |
| `m9053` (TD) | 60 | 17 | 1080 | == comment |
| `pak43_towed_hun` (how) | 60 | 19 | 1200 | == comment |
| `obice14940` / `m149` | 60 | 19-20 | 1200-1260 | |
| `panther5g_hungarian` (heavy) | 60 | 24 | 1500 | |
| `pz6e_hungarian` (Tiger, heavy) | 600 | 1.92 | 1752 | |

Needs judgment (formula does not cleanly apply):
- `bt42` — comment `;270`, formula 540: hand-override, use 270 (BT-42 is an early assault gun).
- `155mm_mle1917` — comment `;1080`, formula 660: c=60 drift, use 1080.
- `botond`, `fiat626_inf`, `L35LF` — `fore=0` sentinel: transports/flame tankette, assign
  early (~180-350) by class like other factions' equivalents.

Phase anchors fall out directly: first medium (Semovente 490 / Turan 650) sets `mid`; first
heavy (Panther 1500) sets `late`. Matches the Japan-like shape (§2) — heavy tier is a single
rare captured vehicle, so `lateTargets` should drop or de-weight `heavy`.

For completeness, the lines RobZ *did* annotate:

| annotated | unlock (s) |
|---|---|
| `22`, `skoda_75mm_gebirgskanone`, `fiataa35` | 180 |
| `bt42` | 270 |
| `resita_seq` | 390 |
| `tacam_t60` | 520 |
| `tacam_r2` | 540 |
| `Brixia45_seq` | 750 |
| `cannone9053` | 900 |
| `flak36a_fin`, `155mm_mle1917`, `m9053` | 1080 |
| `pak43_towed_hun` | 1200 |

**The core armor line (Toldi, Turan I/II/III, Zrinyi I/II, Csaba, Nimrod, the two heavies)
carries no `;NNN` comment.** This is the single biggest data gap (see §5).

## 5. What it takes to support the faction — checklist

| Area | File | Status / work |
|---|---|---|
| **Gun ratings** | `gun_ratings.lua` | Already present for most axis_minor armor (army-wide sweep). **Partial gaps**: `toldi2`, `csaba40m`, `nimrod`, `turan2`, `ab41`, `Lancia1ZM`, `L35LF`, `3ro`, `m149`, `bt42`, `m1139_seq`, `m7518_seq`, `zrinyi2`-variants unrated → neutral `1.0x`. Re-run `build_gun_ratings.py` and confirm each roster tank resolves. |
| **Roster table** | `bot.data.lua` | New `["axis_minor"]` block — the bulk of the work. Classify per §3, tag inf/smg/mech/flame/elite, set `weight=` on tanks, `unlock=`/`min_income=`. |
| **Phase boundaries** | `bot.data.lua` `FactionPhases` | `mid` = first medium unlock, `late` = first heavy unlock. **Blocked on §4** — the medium/heavy armor has no annotated unlock time. Likely shape: `{ mid = ~450, late = ~1000, lateTargets = drop/de-weight heavy like jap }`. |
| **Faction bias** | `bot.data.lua` `FactionBias` | New doctrine entry. Proposed: infantry + AT-infantry floor every phase; light-armor floor early/mid; a small medium floor late (no heavy floor — only 2 rare captured heavies). |
| **Roster checker** | `check_unit_roster.py:7` | Add `"axis_minor"` to `FACTIONS`. Squad ids are `side(axis_minor)`-tagged so `scan_side_tagged_ids` already handles them; vehicle ids come from the directory scan. |
| **Flag sectors** | `flag_sectors.lua` | No change — sector data is map-keyed, faction-independent. |
| **Other build tools** | `build_arty_roster.py`, `build_aim_time.py`, `build_unit_meta.py` | Confirm none hardcode a faction allow-list that excludes axis_minor (only `check_unit_roster.py` does). |

## 6. Open questions (decide before building the roster)

1. **Unlock schedule for the armor line.** ~~Blocker~~ **RESOLVED — see §4a.** The unlock
   time is computable from the `.set` fields via `unlock = round(c * (|fore| + 1))`; every
   axis_minor unit carries `c()` and `fore`, so no analogy or hand-authoring is needed for
   the armor line. Only a few `fore=0` sentinels and named hand-overrides need judgment.
2. **Multi-nation curation.** Six nationalities in one pool. Field the whole roster, or
   curate a coherent core so the bot does not mix Finnish Sissi + Italian Alpini + Bulgarian
   line in the same wave? The bot picks by priority/tier, so this is a priority-weighting
   choice, not a hard filter.
3. **Heavy tier.** Only two captured German heavies, both 1500 MP and rare. Follow Japan and
   drop `heavy` from `lateTargets`, leaning the spearhead on Turan/Zrinyi mediums instead.
4. **Assault guns vs TDs.** Zrinyi I/II, m9053, BT-42, Semovente blur the Tank/ATTank line.
   Decide which are main-group armor (`Tank`) vs escort/overwatch (`ATTank`) — matters for
   the TD-escort and armorLead logic added in v1.2.0.
