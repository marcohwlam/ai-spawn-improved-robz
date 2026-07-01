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
