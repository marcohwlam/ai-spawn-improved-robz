#!/usr/bin/env python3
"""Asserts build_unit_meta scrapes and injects correctly. Run from the tools/ dir."""
import build_unit_meta as m

# --- scrape ---
FIX = '\n'.join([
    '{"pz5g"      ("v" c(60) t(44 heavy) s(ger) cp(30)) {level 1} {cost 1325} {fore -24.0}} ;1500sec',
    '{"pz4h_seq"  ("v_seq" c(10) t(all 44 45 medium) s(ger) cp(20)) {level 1} {cost 500}} ;950sec',
    '{"sdkfz182b" ("v" c(120) t(44 sheavy) s(ger) cp(40)) {level 1} {cost 2200}} ;2160sec',
    '{"kubel"     ("v" c(5) t(44 light) s(ger) cp(3)) {level 1} {cost 120}}',  # no ;sec
])
meta = m.parse_units(FIX)
assert meta["pz5g"] == {"unlock": 1500, "weight": "heavy"}, meta["pz5g"]
assert meta["pz4h_seq"] == {"unlock": 950, "weight": "medium"}, meta["pz4h_seq"]
assert meta["sdkfz182b"] == {"unlock": 2160, "weight": "sheavy"}, meta["sdkfz182b"]
assert meta["kubel"] == {"unlock": None, "weight": "light"}, meta["kubel"]
print("parse_units OK")

# --- inject: tank gets unlock + weight, recharge stripped ---
LINE_TANK = '\t\t\t\t{priority=2.0, class=UnitClass.Tank,          unit="pz4h_seq", recharge=950,             min_income=1.5,},'
out, rep = m.inject(LINE_TANK, {"pz4h_seq": {"unlock": 950, "weight": "medium"}})
assert "recharge=" not in out, out
assert "unlock=950" in out, out
assert 'weight="medium"' in out, out
assert "pz4h_seq" in rep["injected"], rep
# idempotent: second pass identical
out2, _ = m.inject(out, {"pz4h_seq": {"unlock": 950, "weight": "medium"}})
assert out2 == out, (out, out2)
print("inject tank OK")

# --- inject: heavy gets unlock, NO weight (TierOf reads heavy from class) ---
LINE_HEAVY = '\t\t\t\t{priority=1.5, class=UnitClass.HeavyTank,     unit="pz5g", recharge=1500,                 min_income=2.0, min_team=1,},'
out, rep = m.inject(LINE_HEAVY, {"pz5g": {"unlock": 1500, "weight": "heavy"}})
assert "recharge=" not in out, out
assert "unlock=1500" in out, out
assert "weight=" not in out, out
print("inject heavy OK")

# --- mismatch protection: recharge != unlock leaves the line untouched ---
LINE_BAD = '\t\t\t\t{class=UnitClass.Tank, unit="weird", recharge=42, min_income=1.0,},'
out, rep = m.inject(LINE_BAD, {"weird": {"unlock": 950, "weight": "light"}})
assert out == LINE_BAD, out
assert ("weird", 42, 950) in rep["mismatch"], rep["mismatch"]
print("inject mismatch OK")

# --- recharge=0 with no unlock: strip recharge, add no unlock field ---
LINE_ZERO = '\t\t\t\t{class=UnitClass.Infantry, unit="rifle", recharge=0, min_income=1.0,},'
out, rep = m.inject(LINE_ZERO, {"rifle": {"unlock": None, "weight": None}})
assert "recharge=" not in out, out
assert "unlock=" not in out, out
print("inject zero OK")

print("build_unit_meta test OK")
