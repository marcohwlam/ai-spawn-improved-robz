import os
import pytest
from build_gun_ratings import (
    resolve_ap_peak,
    gun_rating_for_weapons,
    build_ratings,
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
