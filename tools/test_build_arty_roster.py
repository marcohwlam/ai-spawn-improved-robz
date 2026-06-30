#!/usr/bin/env python3
"""Asserts build_arty_roster classifies subtype, sets priority, renders rows,
merges+filters per nation, and rewrites a nation block. Run from tools/."""
import build_arty_roster as m

# --- subtype_of: tag substring -> subtype ---
assert m.subtype_of("artillery heavyart rocket 44") == "rocket"   # rocket wins
assert m.subtype_of("all artillery heavyart heavy 43 44 45") == "heavy"
assert m.subtype_of("artillery all heavy 44 45") == "heavy"
assert m.subtype_of("all artillery 43 44 45") == "field"
assert m.subtype_of("artillery 44") == "field"
assert m.subtype_of("all 44 45 artillery heavyart", "sdkfz251_1_stuka") == "rocket"  # override
assert m.subtype_of("all 44 45 artillery heavyart", "sdkfz138_1") == "heavy"          # not overridden
assert m.subtype_of("artillery 44") == "field"                                        # unit omitted still works
print("subtype_of OK")

# --- priority_of ---
assert m.priority_of("rocket") == 0.3
assert m.priority_of("heavy") == 0.5
assert m.priority_of("field") == 0.8
print("priority_of OK")

# --- render_row: exact Lua line, includes arty= and priority ---
row = m.render_row("wespe", "field", 2.0, 900)
assert row == ('\t\t\t\t{priority=0.8, class=UnitClass.ArtilleryTank, '
               'unit="wespe", min_income=2.0, min_team=1, unlock=900, arty="field",},'), repr(row)
rocket = m.render_row("bm13", "rocket", 2.0, 1200)
assert 'arty="rocket"' in rocket and 'priority=0.3' in rocket and 'unit="bm13"' in rocket, repr(rocket)
print("render_row OK")

# --- merge_nation: union of reference + existing, filtered by mpset, classified ---
mpset = {"wespe_ss": "all artillery 43 44 45", "hummel_ss": "all artillery heavyart heavy 43 44 45",
         "sdkfz4_ss": "all artillery heavyart rocket 44 45",
         "np_sdkfz251_1w_ss": "all artillery heavyart rocket 41 42 43 44 45"}
# ger_ss existing rows use wespe + stuh42, which are NOT in the ger_ss mp-set -> dropped
rows = m.merge_nation("ger_ss", ["wespe", "stuh42"], mpset)
assert len(rows) == 4, rows                      # only the 4 valid _ss units survive
assert any('unit="wespe_ss"' in r and 'arty="field"' in r for r in rows), rows
assert any('unit="hummel_ss"' in r and 'arty="heavy"' in r for r in rows), rows
assert any('unit="sdkfz4_ss"' in r and 'arty="rocket"' in r for r in rows), rows
assert not any('"stuh42"' in r or 'unit="wespe"' in r for r in rows), rows
print("merge_nation OK")

# --- rewrite_nation_block: replaces the contiguous arty run in place ---
sample = (
'\t\t\t["ger"] = {\n'
'\t\t\t\t{priority=2.0, class=UnitClass.Infantry, unit="riflemans(ger)",},\n'
'\t\t\t\t{priority=1.0, class=UnitClass.ArtilleryTank, unit="wespe", min_income=2.0, min_team=1, unlock=900,},\n'
'\t\t\t},\n'
'\t\t\t["usa"] = {\n'
'\t\t\t\t{priority=1.0, class=UnitClass.ArtilleryTank, unit="m7", min_income=2.0, min_team=1, unlock=900,},\n'
'\t\t\t},\n')
out = m.rewrite_nation_block(sample, "ger", ['\t\t\t\tROW_A', '\t\t\t\tROW_B'])
assert "ROW_A\n\t\t\t\tROW_B" in out, out
assert 'unit="wespe"' not in out, out          # old ger arty row gone
assert 'unit="riflemans(ger)"' in out, out     # non-arty row preserved
assert 'unit="m7"' in out, out                 # usa block untouched
print("rewrite_nation_block OK")

print("build_arty_roster test OK")
