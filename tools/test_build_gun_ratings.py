import os
import zipfile
import pytest
from build_gun_ratings import (
    resolve_ap_peak,
    gun_rating_for_weapons,
    build_ratings,
    _read_unit_ids,
)

# --- pure logic: no pak needed ---

def test_resolve_ap_peak_direct():
    gun_files = {
        "20mm_kwk30": '{from "pattern gun"\n{projectileDamage 46}\n'
                      '("damage_100" a(46) b(33) c(23) d(15) e(11) range(160))\n'
                      '{parameters "apcr" ("damage_100" a(64) b(33) c(23))}\n'
    }
    assert resolve_ap_peak("20mm_kwk30", gun_files) == 46

def test_resolve_ap_peak_ignores_apcr_block():
    # the apcr a(64) must NOT be returned; default AP a(46) wins
    gun_files = {
        "g": '("damage_100" a(46) b(33))\n{parameters "apcr" ("damage_100" a(64))}\n'
    }
    assert resolve_ap_peak("g", gun_files) == 46

def test_resolve_ap_peak_inheritance():
    gun_files = {
        "37mm_m6": '{from "37mm_m3"}\n',
        "37mm_m3": '{from "pattern gun"\n'
                   '("damage_170" a(78) b(69) c(59) d(51) e(43) range(180))}\n',
    }
    assert resolve_ap_peak("37mm_m6", gun_files) == 78

def test_resolve_ap_peak_no_ap_curve_returns_none():
    gun_files = {"mg": '{from "pattern gun"\n{projectileDamage 3}}\n'}
    assert resolve_ap_peak("mg", gun_files) is None

def test_gun_rating_max_over_weapons():
    gun_files = {
        "mg34": '{from "pattern gun"}\n',                       # no AP curve -> 0
        "50mm_kwk39": '("damage_170" a(97) b(79) c(62))\n',
    }
    # unit with coax MG + main gun -> main gun value
    assert gun_rating_for_weapons(["mg34", "50mm_kwk39"], gun_files) == 97

def test_gun_rating_empty_is_zero():
    assert gun_rating_for_weapons([], {}) == 0

def test_resolve_ap_peak_vet_suffix_fallback():
    # RobZ ships only "85mm_d5t_vet" on disk; units reference plain "85mm_d5t".
    gun_files = {
        "85mm_d5t_vet": '{from "85mm_zis53_vet"}\n',
        "85mm_zis53_vet": '("damage_170" a(97) b(79) c(62))\n',
    }
    assert resolve_ap_peak("85mm_d5t", gun_files) == 97

# --- variant-unit enumeration (v_ss / v_seq / v1 breed join) ---

def _make_gamelogic_zip(path, unit_set_text, gun_files):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("set/multiplayer/units/ger/vehicles_44-45.set", unit_set_text)
        for name, text in gun_files.items():
            z.writestr("set/stuff/gun/" + name, text)

def _make_entity_zip(path, defs):
    with zipfile.ZipFile(path, "w") as z:
        for base, weapons in defs.items():
            weapon_lines = "".join('{weapon "%s"}\n' % w for w in weapons)
            z.writestr("entity/-vehicle/car/%s/%s.def" % (base, base), weapon_lines)

def test_read_unit_ids_v_underscore_ss_enumerates_with_v1_breed(tmp_path):
    unit_set = (
        '{"sdkfz222"     ("v"    c(10) t(all 44 45) s(ger) b(v3)) {level 1}} ;base\n'
        '{"sdkfz222_ss"  ("v_ss" c(10) v1(sdkfz222) t(all 44 45) s(ger_ss) b(v3)) {level 1}} ;variant\n'
    )
    gl = tmp_path / "gamelogic.pak"
    _make_gamelogic_zip(gl, unit_set, {})
    breeds = _read_unit_ids(str(gl))
    assert breeds["sdkfz222"] == "sdkfz222"
    assert breeds["sdkfz222_ss"] == "sdkfz222"  # v1() breed, not its own id

def test_build_ratings_variant_unit_rating_matches_base(tmp_path):
    unit_set = (
        '{"sdkfz222"     ("v"    c(10) t(all 44 45) s(ger) b(v3)) {level 1}} ;base\n'
        '{"sdkfz222_ss"  ("v_ss" c(10) v1(sdkfz222) t(all 44 45) s(ger_ss) b(v3)) {level 1}} ;variant\n'
    )
    gun_files = {"20mm_kwk30": '("damage_100" a(46) b(33) c(23))\n'}
    gl = tmp_path / "gamelogic.pak"
    en = tmp_path / "entity.pak"
    _make_gamelogic_zip(gl, unit_set, gun_files)
    _make_entity_zip(en, {"sdkfz222": ["20mm_kwk30"]})
    ratings = build_ratings(str(gl), str(en))
    assert ratings["sdkfz222"] == 46
    assert ratings["sdkfz222_ss"] == 46  # variant inherits base's rating via v1() breed

# --- integration: real paks (skipped if absent) ---

ROBZ = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
        "mods/robz realism mod 1.30.10/resource")
GL = os.path.join(ROBZ, "gamelogic.pak")
EN = os.path.join(ROBZ, "entity.pak")

@pytest.mark.skipif(not (os.path.exists(GL) and os.path.exists(EN)),
                    reason="RobZ paks not present")
def test_build_ratings_real_anchors():
    ratings = build_ratings(GL, EN)
    assert ratings["sdkfz222"] == 46
    assert ratings["m5a1"] == 78
    assert ratings["pz3_m"] == 97

@pytest.mark.skipif(not (os.path.exists(GL) and os.path.exists(EN)),
                    reason="RobZ paks not present")
def test_build_ratings_real_variants_and_residual_base_units():
    ratings = build_ratings(GL, EN)
    # ger_ss (Waffen-SS) variant, resolved via v1(sdkfz222) breed join.
    assert ratings["sdkfz234_ss"] == 97
    # residual base-unit misses (v1-less "v" units whose breed .def basename
    # matched their id, but the AP gun needed the "_vet" filename fallback).
    assert ratings["is1"] > 0
    assert ratings["kv1"] > 0
    assert ratings["kv85"] > 0
