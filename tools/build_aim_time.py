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
