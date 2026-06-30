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

# --- synthetic dedupe + symmetric trim (no pak) ---
def _synthetic_trim():
    # a-bases deep-left, b-base just right of center: a gets 2, b gets 3 -> trim to 2
    bases = {"a1": (-4000, 0), "b1": (200, 0)}
    flags = {"f1": (-3500, 0), "f2": (-3400, 100),
             "f3": (100, 0), "f4": (150, 100), "f5": (50, 0)}
    return bases, flags

def _synthetic_overlap():
    # f2 and f3 land in both bases' tag sets; dedupe sends f2->a (1000<1100),
    # f3->b (200<1900). Counts are symmetric (2/2) so pure trim keeps f2.
    bases = {"a1": (-1000, 0), "b1": (1100, 0)}
    flags = {"f1": (-900, 0), "f2": (0, 0), "f3": (900, 0), "f4": (1000, 0)}
    return bases, flags

b, f = _synthetic_trim()
adj = bs.adjacency(b, f)
a_set = [n for n in f if adj[n][1] == ["a"]]
b_set = [n for n in f if adj[n][1] == ["b"]]
assert len(a_set) == len(b_set), (a_set, b_set)          # symmetric count
assert all(adj[n][1] in ([], ["a"], ["b"]) for n in f)    # no a+b overlap
assert set(a_set) == {"f1", "f2"}, a_set
assert set(b_set) == {"f3", "f4"}, b_set                  # f5 trimmed (farthest)

b, f = _synthetic_overlap()
adj = bs.adjacency(b, f)
assert adj["f2"][1] == ["a"], adj["f2"][1]                # dedupe: f2 -> nearer side a
assert adj["f3"][1] == ["b"], adj["f3"][1]                # dedupe: f3 -> nearer side b
a_set = [n for n in f if adj[n][1] == ["a"]]
b_set = [n for n in f if adj[n][1] == ["b"]]
assert len(a_set) == len(b_set) == 2, (a_set, b_set)      # symmetric, f2 survives trim
print("dedupe+trim test OK")

adj = bs.adjacency(bases, flags)
nb_f1 = adj["f1"][0]
assert "f8" in nb_f1 and "f7" in nb_f1, nb_f1            # f1's two nearest (1074, 1195)
assert all(len(adj[n][0]) > 0 for n in flags), "no flag may be isolated"
# symmetry: if f1 lists f8, f8 lists f1
assert "f1" in adj["f8"][0], adj["f8"][0]
# base adjacency: f5/f6 sit near a-side; at least one flag lists team 'a'
assert any("a" in adj[n][1] for n in flags), "some flag should be a-base adjacent"
print("adjacency test OK")

# --- raw axis preserved + symmetric base count (bastogne) ---
adj = bs.adjacency(bases, flags)
a_n = sum(1 for n in flags if adj[n][1] == ["a"])
b_n = sum(1 for n in flags if adj[n][1] == ["b"])
assert a_n == b_n and a_n >= 1, (a_n, b_n)
comp = bs.compute(bases, flags)
assert comp["f5"][2] < 0.4 and comp["f10"][2] > 0.59, (comp["f5"], comp["f10"])
print("bastogne base+axis OK")
