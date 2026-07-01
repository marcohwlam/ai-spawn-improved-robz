#!/usr/bin/env python3
"""Asserts check_unit_roster scans the real RobZ pak correctly. Run from the tools/ dir."""
import check_unit_roster as cur

PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
       "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

# --- Task 1: roster scanner ---
ids, files = cur.scan_faction_ids(PAK, "ger_ss")
assert files, "expected at least one .set file for ger_ss"
assert "pz3_m_ss" in ids, "pz3_m_ss (v1 breed) should be found in ger_ss roster"
assert "hetzer_ss" in ids, "hetzer_ss (v1 breed) should be found in ger_ss roster"
assert "wespe_ss" in ids, "wespe_ss (v1 breed) should be found in ger_ss roster"

ids_rus, files_rus = cur.scan_faction_ids(PAK, "rus")
assert files_rus, "expected at least one .set file for rus"
assert "smgs" in ids_rus, "smgs (name()) should be found in rus roster"
assert "riflemans" in ids_rus, "riflemans (name()) should be found in rus roster"

missing_ids, missing_files = cur.scan_faction_ids(PAK, "not_a_real_faction")
assert missing_files == [], "nonexistent faction directory should yield no files"
assert missing_ids == set(), "nonexistent faction directory should yield no ids"

index, files_by_faction = cur.build_roster_index(PAK, cur.FACTIONS)
assert set(index.keys()) == set(cur.FACTIONS)
assert all(files_by_faction[f] for f in cur.FACTIONS), \
    "every real faction should have at least one .set file: %r" % {
        f: files_by_faction[f] for f in cur.FACTIONS if not files_by_faction[f]}
print("roster scanner test OK")

# --- Task 2: bot.data.lua extraction ---
import tempfile, os

SAMPLE_LUA = '''\
FactionPhases = {
\t["ger"]       = { mid = 630, late = 1500 },
\t["ger_ss"]    = { mid = 630, late = 1500 },
}

Purchases = {
\t{
\t\tUnits = {
\t\t\t["ger"] = {
\t\t\t\t{priority=2.0, class=UnitClass.Infantry, unit="volksgrens(ger)", line=true,},
\t\t\t\t{priority=1.5, class=UnitClass.Tank,     unit="pz2l", min_income=1.0,},
\t\t\t},
\t\t\t["ger_ss"] = {
\t\t\t\t{priority=1.0, class=UnitClass.Tank,     unit="pz3_m", min_income=1.0,},
\t\t\t},
\t\t},
\t},
}
'''

def _write_temp_lua(text):
    fd, path = tempfile.mkstemp(suffix=".lua")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    return path

path = _write_temp_lua(SAMPLE_LUA)
try:
    units = cur.extract_bot_units(path)
finally:
    os.remove(path)

assert ("ger", "volksgrens(ger)", 10) in units, units
assert ("ger", "pz2l", 11) in units, units
assert ("ger_ss", "pz3_m", 14) in units, units
# the FactionPhases single-line entries must NOT be picked up as unit blocks
assert not any(f in ("ger", "ger_ss") and u in ("mid", "late") for f, u, _ in units), units
assert len(units) == 3, units
print("bot.data.lua extraction test OK")

assert cur.strip_suffix("grenadiers_elite(ger)") == "grenadiers_elite"
assert cur.strip_suffix("light_mortar_ger") == "light_mortar_ger"
assert cur.strip_suffix("pz3_m") == "pz3_m"
print("strip_suffix test OK")

# --- Task 3: cross-check logic ---
fake_index = {
    "ger":    {"pz2l", "volksgrens"},
    "ger_ss": {"pz3_m_ss", "hetzer_ss"},
    "rus":    {"smgs"},
}
fake_units = [
    ("ger", "volksgrens(ger)", 9),      # OK: suffix-stripped "volksgrens" is in ger's set
    ("ger", "pz2l", 10),                # OK: exact match in ger's set
    ("ger_ss", "pz3_m", 13),            # NOT_FOUND: bare "pz3_m" isn't in ger_ss, but...
    ("ger_ss", "hetzer_ss", 14),        # OK: exact match in ger_ss's set
    ("rus", "riflemans(rus)", 20),      # NOT_FOUND: not in rus's set or any other faction's
]
problems = cur.check(fake_index, fake_units)
by_line = {p["line"]: p for p in problems}
assert 9 not in by_line and 10 not in by_line and 14 not in by_line, problems
assert by_line[13]["kind"] == "NOT_FOUND", by_line[13]
assert by_line[20]["kind"] == "NOT_FOUND", by_line[20]
assert len(problems) == 2, problems

# MISMATCH case: an id that IS real, but under a different faction than claimed
mismatch_units = [("ger", "pz3_m_ss", 99)]   # "pz3_m_ss" only exists under ger_ss
mismatch_problems = cur.check(fake_index, mismatch_units)
assert len(mismatch_problems) == 1, mismatch_problems
assert mismatch_problems[0]["kind"] == "MISMATCH", mismatch_problems
assert mismatch_problems[0]["other"] == "ger_ss", mismatch_problems
print("cross-check test OK")
