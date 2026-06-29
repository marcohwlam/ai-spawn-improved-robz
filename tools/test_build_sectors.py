#!/usr/bin/env python3
"""Asserts build_sectors extracts bastogne correctly. Run from the tools/ dir."""
import zipfile, build_sectors as bs

PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
       "mods/robz realism mod 1.30.10/resource/map.pak")

with zipfile.ZipFile(PAK) as z:
    text = z.read("map/multi/2v2_bastogne/battle_zones.mi").decode("latin-1")

bases, flags = bs.parse_mi(text)
assert set(bases) == {"a1", "a2", "b1", "b2"}, bases
assert len(flags) == 11, len(flags)

comp = bs.compute(bases, flags)
assert len(comp) == 11, len(comp)
assert comp["f5"][2] < 0.4, comp["f5"]
assert comp["f6"][2] < 0.4, comp["f6"]
assert comp["f10"][2] > 0.59, comp["f10"]

assert bs.fingerprint(flags) == "f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9", bs.fingerprint(flags)
print("build_sectors test OK")
