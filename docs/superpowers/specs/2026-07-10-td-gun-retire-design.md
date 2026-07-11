# Tank-Destroyer Retirement Design

Date: 2026-07-10
Status: Approved for planning

## Gun verification (entity.pak `e2.pak` .def files)

| unit | gun | chassis |
|---|---|---|
| marder_3m (base marder_3h) | 75mm L/48-class (PaK40 lineage) | open-top (`"opened"` prop) |
| su76 | 76mm ZiS-3 | open-top (`"opened"` prop) |
| su85 | 85mm D-5S | closed casemate (60-80mm mantlet) |
| hetzer | 75mm PaK39 L/48 | closed casemate |
| stug3g | 75mm StuK40 L/48 | closed casemate |
| m10wolverine (base of m10wolverine_eng) | 3in/76mm M7 | enclosed rotating turret |
| achilles | 17-pounder (76.2mm, high velocity) | enclosed rotating turret |

Marder and SU-76 confirmed open-top; their armored successors carry an equal-or-better
gun. M10 -> Achilles is a strict gun upgrade (17-pdr penetration far exceeds the 3in M7
despite the shared nominal calibre), not a chassis upgrade.

## Problem

The gun-based tank retirement feature (merged, PR #19) added an optional `retire`
field that drops obsolete `weight="medium"` tanks from the main spawn pool. That gate
lives only in `GetUnitToSpawn` (the wave/backfill pool builder). Tank destroyers
(`UnitClass.ATTank`) are drawn by a separate trickle picker, `GetAtTankUnit`
(`bot.lua:635`), which honors `unlock` but never consults `retire`. So obsolete TDs
never fade out.

The observed symptom is the same death-spiral as the tank case: early open-topped TDs
(Marder III, SU-76) keep getting trickled onto the field after their armored,
same-or-better-gunned successors unlock. The open-top chassis dies to a stiff breeze,
wastes manpower, and never gives way to the survivable option.

## Principle

Retire a TD when a strictly better TD in the same faction has unlocked. For TDs the gun
is rarely the obsolescence driver (a TD's gun is its whole point and stays effective all
game); the driver is the **chassis**. Two retirement triggers, per the approved criterion
("open-top + gun upgrade both retire"):

1. **Survivability upgrade at equal-or-better gun.** An open-topped / thin-hulled TD is
   retired once an armored casemate TD carrying the same-class (or better) gun unlocks.
   Marder III (75mm PaK40, open-top) -> StuG/Hetzer (75mm L/48, armored casemate).
   SU-76 (76mm ZiS-3, open-top) -> SU-85 (85mm, armored casemate).
2. **Strict gun upgrade.** A TD is retired when a materially larger-calibre successor
   unlocks. M10 (3in/76mm) -> Achilles (17-pounder).

Retire time is aligned to the successor's `unlock`, matching the tank-retire convention.

## Mechanism

`GetAtTankUnit` already filters on `unlock`. Add the symmetric `retire` upper bound, one
line, mirroring `GetUnitToSpawn` (`bot.lua:1406-1407`):

```lua
for i, t in pairs(roster) do
    if t.class == UnitClass.ATTank
    and (t.unlock == nil or elapsed >= t.unlock)
    and (t.retire == nil or elapsed <  t.retire)   -- NEW
    and not live[t.unit] then
        table.insert(attanks, t)
    end
end
```

Units with no `retire` field are unaffected (backward compatible). The existing `retire`
data on tanks is untouched; this only extends the field's reach to the ATTank picker.

```
time axis ->
     unlock                       retire
       |<-------- eligible -------->|
-------+----------------------------+-------------
   enters AT trickle            drops from trickle (obsolete chassis)
```

## Retire dataset

Only open-top / gun-superseded TDs are listed. Everything else keeps its current
(no-`retire`) behavior. Timing aligned to the successor's unlock.

| faction | unit | gun | chassis | retire | successor (driver) |
|---|---|---|---|---|---|
| ger | marder_3m | 75mm PaK40 | open-top | 880 | hetzer (75 L/48, armored) |
| ger_ss | marder_3m_ss | 75mm PaK40 | open-top | 830 | stug3f (75 L/43, armored) |
| rus | su76 | 76mm ZiS-3 | open-top | 1170 | su85 (85mm, armored) |
| rus_guard | su76_guard | 76mm ZiS-3 | open-top | 1170 | su85_guard (85mm, armored) |
| eng | m10wolverine_eng | 3in/76mm | thin | 1500 | achilles (17-pdr) |

### Safety: never leave a faction with zero TDs

After each retire time the faction must still field at least one `ATTank` with no
`min_team` gate (so 1v1 still trickles a TD):

- ger after 880: hetzer, stug3g_seq, jagdpanzer_iv (all no min_team). OK.
- ger_ss after 830: stug3f, hetzer_ss, stug4g, jagdpanzer_iv_l48_ss. OK.
- rus after 1170: su85 (no min_team); isu122 is min_team. OK.
- rus_guard after 1170: su85_guard (no min_team); isu122_guard is min_team. OK.
- eng after 1500: achilles (no min_team). OK (single TD, but the superior one).

### Not retired (and why)

- **usa** m18 / m10wolverine (76mm): successor m36 (90mm) carries `min_team=1`, so it
  never spawns in 1v1. Retiring the 76mm TDs would leave usa with zero TDs in 1v1.
  Safety red line -> usa keeps all TDs.
- **ger2**: no open-top early TD; hetzer_ger2 / stug3g_ger2 are armored, nashorn unlocks
  late. Nothing obsolete.
- **jap** ho-ni1 / ho-ni_3: both open-top, both unlock 750, no armored successor. Japan
  kept everything in the tank-retire feature for the same no-successor reason. Keep.
- **ger / ger_ss armored 75 L/43 -> L/48** (stug3f -> stug4g): marginal gun bump on an
  already-armored chassis, not obsolescence. Keep.
- All heavy-casemate late TDs (jagdpanzer, jagdpanther, nashorn, isu122, m36): keep.

## Testing

- `retire` boundary in `GetAtTankUnit`: a TD with `retire=T` is returned at
  `elapsed = T-1` and never at `elapsed = T`.
- Regression: a TD with no `retire` field is returned exactly as before (unlock-gated
  only).
- Safety: at each faction's TD retire time, at least one non-`min_team` ATTank remains
  in the roster.
- Data: each listed retire value is strictly greater than that unit's own `unlock`
  (a unit must not retire before it unlocks).

## Out of scope

- Retiring TDs by gun calibre alone (TD guns stay effective; chassis drives it).
- usa 76mm TD retirement (blocked by the m36 `min_team` safety red line).
- Reclassifying ho-ni or su76 out of the ATTank trickle.
- Any change to the tank `retire` dataset from PR #19.
