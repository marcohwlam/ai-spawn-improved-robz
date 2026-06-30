#!/usr/bin/env python3
"""Asserts build_aim_time filters paths and zeroes PrepareTime. Run from tools/."""
import build_aim_time as m

# --- is_target ---
assert m.is_target("set/stuff/gun/.presets") is True
assert m.is_target("set/stuff/gun/105mm_m2a1_2") is True
assert m.is_target("set/stuff/reactive/380mm_rw61_2.weapon") is True
assert m.is_target("set/stuff/reactive/.presets") is True
assert m.is_target("set/stuff/gun/") is False            # dir entry
assert m.is_target("set/stuff/rifle/sniper/em2_vet") is False
assert m.is_target("set/stuff/explosive/dynamite") is False
assert m.is_target("set/stuff/pistol/artillery_105_flaregun") is False
assert m.is_target("set/stuff/grenade/grenade_ap.pattern") is False
print("is_target OK")

# --- flip_prepare ---
out, n = m.flip_prepare(b"\t{PrepareTime 5}\n")
assert out == b"\t{PrepareTime 0}\n", out
assert n == 1, n
out, n = m.flip_prepare(b"{PrepareTime 2.5}{PrepareTime 0.0001}")
assert out == b"{PrepareTime 0}{PrepareTime 0}", out
assert n == 2, n
# already zero: still matches once, result unchanged
out, n = m.flip_prepare(b"{PrepareTime 0}")
assert out == b"{PrepareTime 0}", out
assert n == 1, n
# no token: untouched, zero subs
out, n = m.flip_prepare(b"{range 250 250}")
assert out == b"{range 250 250}", out
assert n == 0, n
# byte preservation around the token
out, n = m.flip_prepare(b"{Mode aim}\n\t\t{PrepareTime 0.1}\n{Cursor x}")
assert out == b"{Mode aim}\n\t\t{PrepareTime 0}\n{Cursor x}", out
print("flip_prepare OK")

import io, os, tempfile, zipfile

def _make_pak(path, entries):
    with zipfile.ZipFile(path, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data)

# --- generate: only target files with PrepareTime are written and flipped ---
with tempfile.TemporaryDirectory() as tmp:
    pak = os.path.join(tmp, "gamelogic.pak")
    out = os.path.join(tmp, "resource")
    _make_pak(pak, {
        "set/stuff/gun/.presets":        b"{range 250 250}\n{PrepareTime 5}\n",
        "set/stuff/reactive/x.weapon":   b"{PrepareTime 0.1}\n",
        "set/stuff/gun/no_prep":         b"{range 100 100}\n",          # target, no token
        "set/stuff/rifle/sniper/s_vet":  b"{PrepareTime 2.5}\n",        # excluded
    })
    rep = m.generate(pak, out, write=True)
    assert sorted(rep["written"]) == ["set/stuff/gun/.presets",
                                      "set/stuff/reactive/x.weapon"], rep
    assert rep["skipped_no_prepare"] == 1, rep
    with open(os.path.join(out, "set/stuff/gun/.presets"), "rb") as f:
        body = f.read()
    assert body == b"{range 250 250}\n{PrepareTime 0}\n", body
    assert not os.path.exists(os.path.join(out, "set/stuff/rifle/sniper/s_vet"))
    # check: freshly written tree is in sync
    assert m.check(pak, out) == [], m.check(pak, out)
    # tamper one file -> check reports drift
    with open(os.path.join(out, "set/stuff/reactive/x.weapon"), "wb") as f:
        f.write(b"{PrepareTime 9}\n")
    assert m.check(pak, out) == ["set/stuff/reactive/x.weapon"], m.check(pak, out)
print("generate/check OK")
