# Axis Minor Faction Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bot field RobZ's ninth faction `axis_minor` at parity with the existing eight, via data and config only.

**Architecture:** All spawn mechanisms are already faction-agnostic and keyed off `Instance.army`. This adds `axis_minor`'s roster block, `FactionPhases`/`FactionBias` entries, and roster-checker coverage. No `bot.lua` changes.

**Tech Stack:** Lua (bot data + offline test harness), Python (roster checker).

## Global Constraints

- No `bot.lua` edits. If a unit needs new routing logic, drop it from v1 instead.
- `unlock` values are `round(c*(|fore|+1))` per `docs/REFERENCE.md`, on vehicle/gun rows only; infantry and aux-infantry rows carry no `unlock` (eligible from t=0).
- Squad-format ids take a `(axis_minor)` suffix; vehicle-format ids are bare. (Exact form per unit is given in the roster code below — do not re-derive.)
- `UnitClass.Howitzrer` is a dead class (no picker collects it); never use it.
- Heroes and single-soldier reinforcement fillers are excluded.
- Reference: full design at `docs/superpowers/specs/2026-07-14-axis-minor-faction-design.md`; roster/unlock research at `docs/research/2026-07-12-axis-minor-faction-support.md`.
- RobZ pak for the roster checker: `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/gamelogic.pak`.

---

### Task 1: Roster-checker faction wiring

**Files:**
- Modify: `tools/check_unit_roster.py:7`

**Interfaces:**
- Produces: `check_unit_roster.py` now scans `axis_minor` unit ids against RobZ.

- [ ] **Step 1: Add axis_minor to FACTIONS**

Change line 7 from:

```python
FACTIONS = ["eng", "ger", "ger_ss", "ger2", "usa", "rus", "rus_guard", "jap"]
```

to:

```python
FACTIONS = ["eng", "ger", "ger_ss", "ger2", "usa", "rus", "rus_guard", "jap", "axis_minor"]
```

- [ ] **Step 2: Run the checker against the real pak**

Run:
```bash
python3 tools/check_unit_roster.py "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/gamelogic.pak" resource/script/multiplayer/bot.data.lua
```
Expected: `no problems found (N units checked)`. (No axis_minor roster rows exist yet, so axis_minor contributes 0 rows to check; the run must still succeed and the unit count must be unchanged or higher.)

- [ ] **Step 3: Run the checker's own unit test**

Run: `python3 tools/test_check_unit_roster.py`
Expected: all tests pass (the FACTIONS constant widening does not break existing cases).

- [ ] **Step 4: Commit**

```bash
git add tools/check_unit_roster.py
git commit -m "check_unit_roster: add axis_minor to FACTIONS"
```

---

### Task 2: FactionPhases and FactionBias entries

**Files:**
- Modify: `resource/script/multiplayer/bot.data.lua` (FactionPhases block ~line 42-58; FactionBias block ~line 78-136)
- Create: `resource/script/multiplayer/tests/axis_minor_spec.lua`

**Interfaces:**
- Consumes: `ResolvePhases(army)` and `CurrentPhase(t)` from `bot.lua` (already faction-agnostic).
- Produces: `FactionPhases["axis_minor"]`, `FactionBias.axis_minor`.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/axis_minor_spec.lua`. Mirror the harness bootstrap used by `tests/phase_spec.lua` (require the harness, load `bot.data.lua` and `bot.lua` through it). Then:

```lua
-- axis_minor faction: phases and bias
local jap_style = ResolvePhases("axis_minor")
eq(jap_style[1].upto, 650,  "axis_minor early ends at 650 (turan1 first medium)")
eq(jap_style[2].upto, 1500, "axis_minor mid ends at 1500 (panther first heavy)")
eq(jap_style[3].upto, 1000000000, "axis_minor late is open-ended")
eq(jap_style[3].targets.heavy, nil, "axis_minor late drops the heavy tier")
eq(jap_style[3].targets.medium, 2, "axis_minor late medium target is 2")

assert(FactionBias.axis_minor ~= nil, "axis_minor has a FactionBias entry")
eq(FactionBias.axis_minor.early.rifle, 1, "axis_minor early floors rifle")
eq(FactionBias.axis_minor.mid.attank,  1, "axis_minor mid floors attank")
eq(FactionBias.axis_minor.late.attank, 1, "axis_minor late floors attank")
eq(FactionBias.axis_minor.late.medium, 1, "axis_minor late floors medium")
print("axis_minor phases/bias OK")
```

(Match the exact bootstrap and `eq` helper from `phase_spec.lua`; copy its top matter verbatim.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/axis_minor_spec.lua`
Expected: FAIL — `ResolvePhases("axis_minor")` falls back to the global `Phases` (early upto 180), so `eq(...650...)` errors.

- [ ] **Step 3: Add the FactionPhases entry**

In `bot.data.lua`, inside `FactionPhases = { ... }`, add after the `["rus_guard"]` line:

```lua
	["axis_minor"] = { mid = 650, late = 1500,
	                   lateTargets = { medium = 2, light = 2, rifle = 1, smg = 1 } },
```

- [ ] **Step 4: Add the FactionBias entry**

In `bot.data.lua`, inside `FactionBias = { ... }`, add after the `eng = { ... },` block (before the closing `}`):

```lua
	-- Second-line coalition (BUL/HUN/ROM/FIN/ITA): broad infantry defense early; weak, late
	-- tanks are met with tank destroyers and AT infantry rather than a tank spearhead; Turan
	-- mediums join the sustained TD presence late. No heavy floor (only 2 rare captured heavies).
	axis_minor = {
		early = { rifle = 1 },
		mid   = { attank = 1 },
		late  = { attank = 1, medium = 1 },
	},
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/axis_minor_spec.lua`
Expected: `axis_minor phases/bias OK`.

- [ ] **Step 6: Compile-check and commit**

```bash
luac -p resource/script/multiplayer/bot.data.lua
git add resource/script/multiplayer/bot.data.lua resource/script/multiplayer/tests/axis_minor_spec.lua
git commit -m "Add axis_minor FactionPhases and FactionBias"
```

---

### Task 3: Roster block

**Files:**
- Modify: `resource/script/multiplayer/bot.data.lua` (`Purchases[...].Units`, add `["axis_minor"]` after the `["rus_guard"]` block, ~line 553, before the `},` that closes `Units`)
- Modify: `resource/script/multiplayer/tests/axis_minor_spec.lua` (extend with roster assertions)

**Interfaces:**
- Consumes: `Purchases[1].Units[army]` shape (rows of `{priority, class, unit, ...}`), `UnitClass`.
- Produces: `Purchases[1].Units["axis_minor"]` roster.

- [ ] **Step 1: Extend the spec with a failing roster assertion**

Append to `tests/axis_minor_spec.lua`:

```lua
-- axis_minor roster present and well-formed
local function roster(army)
	for _, blk in ipairs(Purchases) do
		if blk.Units and blk.Units[army] then return blk.Units[army] end
	end
	return nil
end
local axm = roster("axis_minor")
assert(axm ~= nil and #axm > 0, "axis_minor roster block exists and is non-empty")
local hasMedium, hasHeavy, hasTD = false, false, false
for _, t in ipairs(axm) do
	if t.class == UnitClass.Tank and t.weight == "medium" then hasMedium = true end
	if t.class == UnitClass.HeavyTank then hasHeavy = true end
	if t.class == UnitClass.ATTank then hasTD = true end
	assert(t.class ~= UnitClass.Howitzrer, "axis_minor roster uses no dead Howitzrer class")
end
assert(hasMedium, "axis_minor has a medium tank (Turan)")
assert(hasHeavy,  "axis_minor has a captured heavy")
assert(hasTD,     "axis_minor has a tank destroyer")
print("axis_minor roster OK")
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/axis_minor_spec.lua`
Expected: FAIL — `roster("axis_minor")` returns nil (no block yet).

- [ ] **Step 3: Add the roster block**

Insert this block into `Purchases[1].Units`, immediately after the `["rus_guard"] = { ... },` block and before the `},` that closes `Units`:

```lua
			["axis_minor"] = {
				-- Six-nation coalition (BUL/HUN/ROM/FIN/ITA + captured German heavies). Whole
				-- roster fielded; late-phase heavy tier dropped (only 2 rare captured heavies).
				-- unlock = round(c*(|fore|+1)) per RobZ .set fields (see docs/REFERENCE.md).
				{priority=2.0, class=UnitClass.Infantry,   unit="Bulgarian_Infantry(axis_minor)", line=true, inf="rifle",},
				{priority=2.0, class=UnitClass.Infantry,   unit="romanian_rifle_squad(axis_minor)", line=true, inf="rifle",},
				{priority=2.5, class=UnitClass.Infantry,   unit="hungarian_smg_squad(axis_minor)", inf="smg", smg=true,},
				{priority=2.5, class=UnitClass.Infantry,   unit="Hungarian_Assualt_Infantry(axis_minor)", inf="smg", elite=true,},
				{priority=2.0, class=UnitClass.Infantry,   unit="Bersaglieri(axis_minor)", inf="rifle",},
				{priority=1.5, class=UnitClass.Infantry,   unit="Alpini(axis_minor)", inf="rifle",},
				{priority=1.0, class=UnitClass.Infantry,   unit="Paracadutisti(axis_minor)", inf="rifle", elite=true,},
				{priority=2.0, class=UnitClass.Infantry,   unit="fin_kaukopartio(axis_minor)", inf="rifle",},
				{priority=1.5, class=UnitClass.Infantry,   unit="Sissi(axis_minor)", inf="rifle",},
				{priority=1.0, class=UnitClass.Infantry,   unit="fin_pioneer(axis_minor)", inf="rifle", flame=true,},
				{priority=1.5, class=UnitClass.Infantry,   unit="Motorized_Hungarian_Rifles(axis_minor)", mech=true,},
				{priority=1.5, class=UnitClass.Infantry,   unit="Bersaglieri_Mot(axis_minor)", mech=true,},
				{priority=1.0, class=UnitClass.ATInfantry, unit="panzerfaust(axis_minor)",},
				{priority=1.0, class=UnitClass.ATInfantry, unit="panzershreck(axis_minor)",},
				{priority=1.0, class=UnitClass.ATInfantry, unit="pzb_at_Rifle(axis_minor)",},
				{priority=1.0, class=UnitClass.ATInfantry, unit="Boys_AT_Rifle(axis_minor)",},
				{priority=1.0, class=UnitClass.MG      ,   unit="solothurn_31m(axis_minor)",},
				{priority=1.0, class=UnitClass.MG      ,   unit="zb_vz26(axis_minor)",},
				{priority=1.0, class=UnitClass.MG      ,   unit="breda30_bers(axis_minor)",},
				{priority=0.8, class=UnitClass.Sniper,     unit="finnish_sniper(axis_minor)",},
				{priority=1.0, class=UnitClass.Infantry,   unit="flamers(axis_minor)", flame=true,},
				{priority=0.3, class=UnitClass.Officer,    unit="officer(axis_minor)",},
				{priority=0.8, class=UnitClass.Vehicle,    unit="fiataa35",             unlock=180, support=true,},
				{priority=1.5, class=UnitClass.Vehicle,    unit="csaba39m",             unlock=380,},
				{priority=1.5, class=UnitClass.Vehicle,    unit="ab41",                 unlock=310,},
				{priority=1.0, class=UnitClass.Vehicle,    unit="Lancia1ZM",            unlock=310,},
				{priority=1.0, class=UnitClass.Vehicle,    unit="csaba40m",             unlock=320,},
				{priority=1.0, class=UnitClass.Vehicle,    unit="panhard_rom",          unlock=360,},
				{priority=1.5, class=UnitClass.Tank,       unit="toldi1",               min_income=1.0, unlock=370, weight="light",},
				{priority=1.5, class=UnitClass.Tank,       unit="toldi2",               min_income=1.0, unlock=530, weight="light",},
				{priority=1.5, class=UnitClass.AATank,     unit="nimrod",               min_income=1.5, unlock=420,},
				{priority=1.0, class=UnitClass.AATank,     unit="m15_contraereo",       min_income=1.5, unlock=420,},
				{priority=2.0, class=UnitClass.Tank,          unit="turan1",               min_income=1.5, unlock=650, weight="medium",},
				{priority=2.0, class=UnitClass.Tank,          unit="turan2",               min_income=1.5, unlock=850, weight="medium",},
				{priority=2.0, class=UnitClass.Tank,          unit="turan3",               min_income=1.5, unlock=950, weight="medium",},
				{priority=1.0, class=UnitClass.HeavyTank,     unit="panther5g_hungarian",  min_income=2.0, min_team=1, unlock=1500,},
				{priority=1.0, class=UnitClass.HeavyTank,     unit="pz6e_hungarian",       min_income=2.0, min_team=1, unlock=1752,},
				{priority=1.5, class=UnitClass.ATTank,        unit="tacam_t60",            min_income=1.5, unlock=520,},
				{priority=1.5, class=UnitClass.ATTank,        unit="tacam_r2",             min_income=1.5, unlock=540,},
				{priority=1.5, class=UnitClass.ATTank,        unit="zrinyi1",              min_income=1.5, unlock=950,},
				{priority=1.0, class=UnitClass.ATTank,        unit="3ro",                  min_income=1.5, unlock=950,},
				{priority=1.0, class=UnitClass.ATTank,        unit="m9053",                min_income=2.0, min_team=1, unlock=1080,},
				{priority=1.5, class=UnitClass.ArtilleryTank, unit="m1139_seq", min_income=1.5, unlock=490, arty="field", assault=true,},
				{priority=1.5, class=UnitClass.ArtilleryTank, unit="m7518_seq", min_income=1.5, unlock=490, arty="field", assault=true,},
				{priority=1.5, class=UnitClass.ArtilleryTank, unit="bt42",      min_income=1.5, unlock=540, arty="field", assault=true,},
				{priority=1.5, class=UnitClass.ArtilleryTank, unit="zrinyi2",   min_income=1.5, unlock=950, arty="field", assault=true,},
				{priority=1.0, class=UnitClass.Mortar    ,   unit="sgrw_42", unlock=600,},
				{priority=1.0, class=UnitClass.Mortar    ,   unit="22",      unlock=180,},
			},
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/axis_minor_spec.lua`
Expected: `axis_minor phases/bias OK` and `axis_minor roster OK`.

- [ ] **Step 5: Validate every id against RobZ**

Run:
```bash
python3 tools/check_unit_roster.py "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/gamelogic.pak" resource/script/multiplayer/bot.data.lua
```
Expected: `no problems found (N units checked)` — every axis_minor `unit=` id (both `(axis_minor)`-suffixed squads and bare vehicles) resolves. If any id is reported MISSING/MISMATCH, fix that row's id form and re-run; do not proceed with a reported problem.

- [ ] **Step 6: Compile and run the full suite**

```bash
luac -p resource/script/multiplayer/bot.data.lua
cd resource/script/multiplayer && for f in tests/*_spec.lua; do lua "$f" >/dev/null 2>&1 || echo "FAIL $f"; done; echo "suite done"
```
Expected: `luac` prints nothing (compiles); the loop prints only `suite done` (no `FAIL` lines).

- [ ] **Step 7: Commit**

```bash
git add resource/script/multiplayer/bot.data.lua resource/script/multiplayer/tests/axis_minor_spec.lua
git commit -m "Add axis_minor spawn roster"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`

**Interfaces:**
- Consumes: nothing. Documentation only.

- [ ] **Step 1: Note the ninth faction in README**

Find where README enumerates the supported factions (search for `rus_guard` or `jap` or "faction"). Add `axis_minor` to that list with a one-line description:

> `axis_minor` — six-nation Axis coalition (Bulgarian, Hungarian, Romanian, Finnish, Italian, plus captured German heavies); infantry-heavy with late, tank-destroyer-led armor. Heavy tier is dropped from late-game composition (two rare captured heavies only).

If README has no faction list, add the line under the roster/composition section.

- [ ] **Step 2: Note it in ARCHITECTURE.md**

Find the faction/roster section (search for `FactionPhases` or `Purchases` or `bot.data.lua`). Add one sentence that `axis_minor` is supported as a data-only faction (roster + `FactionPhases` + `FactionBias`), with the heavy tier dropped like Japan, and towed howitzers deferred (Howitzrer is a dead class).

- [ ] **Step 3: Commit**

```bash
git add README.md ARCHITECTURE.md
git commit -m "Document axis_minor faction support"
```

---

## Self-Review

**Spec coverage:** Task 1 = roster-checker wiring (spec Component 4). Task 2 = FactionPhases + FactionBias (Components 2, 3). Task 3 = roster block (Component 1). Task 4 = README/ARCHITECTURE (spec Files). Towed howitzers correctly excluded (dead Howitzrer class). All spec sections covered.

**Placeholder scan:** every code step contains complete code (full roster block, exact entries, exact test bodies). The only "find the location" directions are for README/ARCHITECTURE doc insertion, which have no single canonical anchor.

**Type consistency:** `UnitClass.*` names match the enum in `bot.data.lua`; `weight="medium"`/`"light"`, `arty="field"`, `assault=true`, `support=true`, `min_income`, `min_team`, `unlock` all match fields used by shipped rows and documented in `docs/REFERENCE.md`. Squad ids carry `(axis_minor)`; vehicle ids are bare — per the verified id-form table.
