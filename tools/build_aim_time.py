#!/usr/bin/env python3
"""Offline artillery aim-time zeroer for AI Spawn Improved.
Reads RobZ 1.30.10 gamelogic.pak; for every weapon file under set/stuff/gun/ and
set/stuff/reactive/ that contains a PrepareTime token, writes a copy under
resource/set/stuff/<same path> with every `PrepareTime N` rewritten to `PrepareTime 0`.
Run by hand; output is committed; never ships as source. Re-run after a RobZ update.
Deliberately excludes rifle/sniper aim, demolition timers, rifle grenades, and off-map
flareguns (those also use PrepareTime but are not unit artillery)."""
import os, re, zipfile, argparse

ROBZ_PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
            "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

_PREP = re.compile(rb"PrepareTime\s+[0-9.]+")
_TARGET_PREFIXES = ("set/stuff/gun/", "set/stuff/reactive/")

def is_target(name):
    """True if this pak entry is an artillery weapon file we should override."""
    return name.startswith(_TARGET_PREFIXES) and not name.endswith("/")

def flip_prepare(data):
    """bytes -> (bytes, count): rewrite every `PrepareTime N` to `PrepareTime 0`."""
    return _PREP.subn(b"PrepareTime 0", data)

def generate(pak_path, out_root, write=True):
    report = {"written": [], "skipped_no_prepare": 0, "subs": {}}
    with zipfile.ZipFile(pak_path) as z:
        for name in z.namelist():
            if not is_target(name):
                continue
            data = z.read(name)
            if b"PrepareTime" not in data:
                report["skipped_no_prepare"] += 1
                continue
            new, n = flip_prepare(data)
            report["written"].append(name)
            report["subs"][name] = n
            if write:
                dest = os.path.join(out_root, name)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(new)
    return report

def check(pak_path, out_root):
    drift = []
    with zipfile.ZipFile(pak_path) as z:
        for name in z.namelist():
            if not is_target(name):
                continue
            data = z.read(name)
            if b"PrepareTime" not in data:
                continue
            new, _ = flip_prepare(data)
            dest = os.path.join(out_root, name)
            try:
                with open(dest, "rb") as f:
                    cur = f.read()
            except FileNotFoundError:
                drift.append(name)
                continue
            if cur != new:
                drift.append(name)
    return drift

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--robz-pak", default=ROBZ_PAK)
    ap.add_argument("--out-root", default="../resource")
    ap.add_argument("--check", action="store_true",
                    help="report drift instead of writing; nonzero exit on drift")
    args = ap.parse_args()
    if args.check:
        drift = check(args.robz_pak, args.out_root)
        if drift:
            print("DRIFT:", *drift, sep="\n  ")
            raise SystemExit(1)
        print("in sync")
        return
    rep = generate(args.robz_pak, args.out_root, write=True)
    print("written:", len(rep["written"]))
    print("skipped (no PrepareTime):", rep["skipped_no_prepare"])
    print("total substitutions:", sum(rep["subs"].values()))

if __name__ == "__main__":
    main()
