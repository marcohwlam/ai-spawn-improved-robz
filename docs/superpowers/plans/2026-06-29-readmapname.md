# ReadMapName Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify the loaded map by reading its name from game.log, replacing the colliding flag-name fingerprint as the sector-table key.

**Architecture:** A pure `ParseMapName(text)` extracts the map token from log text; `ReadMapName()` reads game.log from env-derived candidate paths and feeds it to the parser; `OnGameStart` caches the result in `Context.MapName`; `LabelFlags` looks up `Sectors[Context.MapName]` instead of `Sectors[FlagFingerprint()]`. The offline `build_sectors.py` is re-keyed by map name and `flag_sectors.lua` regenerated.

**Tech Stack:** Lua 5.1 (engine sandbox; NO `goto`), Python 3 (offline build tool), the project's offline Lua test harness.

## Global Constraints

- Engine runs Lua 5.1: no `goto`, no `bit` (use `bit32` if needed), no 5.2+ idioms. Lint with `luac -p`.
- Map name is the base token only: strip `multi/` prefix and the `:variant` suffix, e.g. `2v2_bastogne`. This must equal the map directory name used by `build_sectors.py`.
- Log path is derived from environment variables only. NO hardcoded username or Proton-specific path. Proton is covered by `USERPROFILE` (Wine returns `C:\users\steamuser`).
- Path candidate order (skip any whose env var is nil): `USERPROFILE + win_tail`, then `USERPROFILE + \OneDrive + win_tail`, then `HOME + nix_tail`.
- `win_tail` = `\Documents\my games\men of war - assault squad 2\log\game.log` (backslashes). `nix_tail` = `/Documents/my games/men of war - assault squad 2/log/game.log` (forward slashes).
- Map name replaces the fingerprint as the SOLE `Sectors` key. No fingerprint lookup fallback. Unknown/nil name -> existing all-CONTESTED / no-partition behavior.
- `FlagFingerprint()` is retained but only feeds the diagnostic `SECTOR_FALLBACK` log line.
- Every io path is `pcall`-wrapped; any failure returns nil. The bot never crashes; worst case is today's legacy behavior.
- No macOS path (the game has no macOS build).
- All public functions are GLOBAL (consistent with existing `LabelFlags`, `FlagFingerprint`, `Context`), so the offline test harness can call them.
- Tests run from `resource/script/multiplayer`: `lua tests/<spec>.lua`. Lint: `luac -p bot.lua`.
- RobZ map pak: `/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/map.pak`.

---

### Task 1: ParseMapName pure function

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (add `ParseMapName` next to `FlagFingerprint`, ~line 706)
- Test: `resource/script/multiplayer/tests/mapname_spec.lua` (create)

**Interfaces:**
- Produces: `ParseMapName(text) -> string|nil`. Scans `text` line by line, returns the token after `multi/` up to the first `:` or `"` from the LAST line containing `Starting "multi/`. Returns nil when `text` is nil or no line matches.

- [ ] **Step 1: Write the failing test**

Create `resource/script/multiplayer/tests/mapname_spec.lua`:

```lua
dofile((arg[0]:gsub("mapname_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- variant suffix stripped
eq(ParseMapName('Starting "multi/2v2_bastogne:battle_zones"'), "2v2_bastogne", "single")

-- last Starting line wins (log accumulates across matches)
local two = 'Starting "multi/2v2_bastogne:battle_zones"\nnoise\nStarting "multi/2v2_gsm_westland:battle_zones"\n'
eq(ParseMapName(two), "2v2_gsm_westland", "last wins")

-- no colon variant
eq(ParseMapName('Starting "multi/1v1_nikolaev"'), "1v1_nikolaev", "no colon")

-- surrounding noise, real-log shape
local noisy = '[00:00:53] foo\nStarting "multi/2v2_mamayev_kurgan:battle_zones"\n[00:00:54] bar\n'
eq(ParseMapName(noisy), "2v2_mamayev_kurgan", "noisy")

-- no match
eq(ParseMapName("no starting line here"), nil, "no match")
eq(ParseMapName(nil), nil, "nil input")

print("mapname OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/mapname_spec.lua`
Expected: FAIL with `attempt to call global 'ParseMapName' (a nil value)`.

- [ ] **Step 3: Write minimal implementation**

In `resource/script/multiplayer/bot.lua`, immediately AFTER the `FlagFingerprint` function (after its `end` on ~line 706), add:

```lua
-- Extract the loaded map's base name from game.log text. The engine writes
-- `Starting "multi/<X>:<variant>"` at match start; the LAST such line names the current
-- map. Returns the token between `multi/` and the first `:` or `"`, or nil. Pure (no io).
function ParseMapName(text)
	if not text then return nil end
	local found
	for line in text:gmatch("[^\r\n]+") do
		local tok = line:match('Starting "multi/([^:"]+)')
		if tok then found = tok end
	end
	return found
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/mapname_spec.lua`
Expected: `mapname OK`.

- [ ] **Step 5: Lint and commit**

```bash
cd resource/script/multiplayer && luac -p bot.lua
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/mapname_spec.lua
git commit -m "feat: ParseMapName pure extractor for game.log map line"
```

---

### Task 2: TailRead + ReadMapName (io layer)

**Files:**
- Modify: `resource/script/multiplayer/bot.lua` (add `TailRead` and `ReadMapName` after `ParseMapName`)
- Test: `resource/script/multiplayer/tests/mapname_spec.lua` (extend — add a TailRead-over-temp-file case)

**Interfaces:**
- Consumes: `ParseMapName(text)` from Task 1.
- Produces:
  - `TailRead(path) -> string|nil`. Opens `path`, reads the last 64KB; if that tail lacks `Starting "multi/` and the file is larger than the tail, re-reads the whole file. `pcall`-wrapped; nil on any failure or missing file.
  - `ReadMapName() -> string|nil`. Builds env-derived candidate paths and returns the first `ParseMapName(TailRead(path))` that is non-nil, else nil.

- [ ] **Step 1: Write the failing test**

Append to `resource/script/multiplayer/tests/mapname_spec.lua` (before the final `print("mapname OK")`, and move that print to the very end):

```lua
-- TailRead reads a real file and the parse pipeline recovers the map name.
do
	local tmp = os.tmpname()
	local f = assert(io.open(tmp, "w"))
	f:write('prologue line\nStarting "multi/2v2_testmap:battle_zones"\nepilogue line\n')
	f:close()
	eq(ParseMapName(TailRead(tmp)), "2v2_testmap", "tailread pipeline")
	eq(TailRead("/no/such/path/game.log"), nil, "tailread missing file")
	os.remove(tmp)
end

-- ReadMapName never errors and returns a string or nil regardless of environment.
do
	local r = ReadMapName()
	assert(r == nil or type(r) == "string", "ReadMapName returns string|nil")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd resource/script/multiplayer && lua tests/mapname_spec.lua`
Expected: FAIL with `attempt to call global 'TailRead' (a nil value)`.

- [ ] **Step 3: Write minimal implementation**

In `resource/script/multiplayer/bot.lua`, immediately AFTER the `ParseMapName` function, add:

```lua
local TAIL_BYTES = 65536
local MAP_TAIL_WIN = [[\Documents\my games\men of war - assault squad 2\log\game.log]]
local MAP_TAIL_NIX = [[/Documents/my games/men of war - assault squad 2/log/game.log]]

-- Read the last 64KB of a file (the current match's Starting line sits near the end).
-- If that tail has no Starting line and the file is bigger than the tail, re-read in full.
-- Returns the text, or nil on any failure. pcall-wrapped.
function TailRead(path)
	local ok, res = pcall(function()
		local f = io.open(path, "r")
		if not f then return nil end
		local size = f:seek("end")
		local from = size - TAIL_BYTES
		if from < 0 then from = 0 end
		f:seek("set", from)
		local text = f:read("*a")
		f:close()
		if text and from > 0 and not text:find('Starting "multi/', 1, true) then
			local g = io.open(path, "r")
			if g then text = g:read("*a"); g:close() end
		end
		return text
	end)
	return ok and res or nil
end

-- Resolve the loaded map name by reading game.log from env-derived candidate paths.
-- No hardcoded username; Proton is covered by USERPROFILE. First parse hit wins. nil if none.
function ReadMapName()
	if not (io and io.open and os and os.getenv) then return nil end
	local up = os.getenv("USERPROFILE")
	local home = os.getenv("HOME")
	local candidates = {}
	if up then
		candidates[#candidates + 1] = up .. MAP_TAIL_WIN
		candidates[#candidates + 1] = up .. [[\OneDrive]] .. MAP_TAIL_WIN
	end
	if home then candidates[#candidates + 1] = home .. MAP_TAIL_NIX end
	for _, path in ipairs(candidates) do
		local name = ParseMapName(TailRead(path))
		if name then return name end
	end
	return nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/mapname_spec.lua`
Expected: `mapname OK`.

- [ ] **Step 5: Lint and commit**

```bash
cd resource/script/multiplayer && luac -p bot.lua
git add resource/script/multiplayer/bot.lua resource/script/multiplayer/tests/mapname_spec.lua
git commit -m "feat: TailRead + ReadMapName resolve map name from game.log"
```

---

### Task 3: Re-key by map name and wire into LabelFlags

This task is atomic: the `Sectors` key change (`build_sectors.py` + regen) and the `LabelFlags` lookup change must land together, or the offline specs break in between.

**Files:**
- Modify: `tools/build_sectors.py:73` (key entries by map name, not fingerprint)
- Regenerate: `resource/script/multiplayer/flag_sectors.lua`
- Modify: `resource/script/multiplayer/bot.lua` (`LabelFlags` lookup + fallback log; `OnGameStart` caches `Context.MapName`)
- Test: `resource/script/multiplayer/tests/sector_spec.lua`, `resource/script/multiplayer/tests/partition_spec.lua`

**Interfaces:**
- Consumes: `ReadMapName()` from Task 2; `Sectors` keyed by map name.
- Produces: `Context.MapName` (string|nil) set in `OnGameStart`; `LabelFlags` reads it.

- [ ] **Step 1: Re-key build_sectors.py**

In `tools/build_sectors.py`, change line 73 from:

```python
            entries.append((fingerprint(flags), bases, compute(bases, flags)))
```

to:

```python
            entries.append((m, bases, compute(bases, flags)))
```

(`m` is the map directory name from the loop at line 70. `fingerprint()` stays defined — `tools/test_build_sectors.py` still asserts it.)

- [ ] **Step 2: Regenerate flag_sectors.lua**

Run:

```bash
cd tools && python3 build_sectors.py \
  "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/mods/robz realism mod 1.30.10/resource/map.pak" \
  2v2_bastogne 2v2_sidi_el-barrani 1v1_nikolaev 2v2_mamayev_kurgan \
  -o ../resource/script/multiplayer/flag_sectors.lua
```

Expected: `wrote ../resource/script/multiplayer/flag_sectors.lua entries: 4`.

Verify the keys are now map names:

```bash
grep -oE '^\s*\["[^"]+"\]' ../resource/script/multiplayer/flag_sectors.lua
```

Expected exactly:

```
  ["2v2_bastogne"]
  ["2v2_sidi_el-barrani"]
  ["1v1_nikolaev"]
  ["2v2_mamayev_kurgan"]
```

- [ ] **Step 3: Update sector_spec to set Context.MapName, run to verify it fails**

In `resource/script/multiplayer/tests/sector_spec.lua`:

Before the team-a block (the line `BotApi.Instance.team = "a"; BotApi.Instance.playerId = 1`), add:

```lua
Context.MapName = "2v2_bastogne"
```

In the fallback block at the end, change the map to an unrecognized one. Replace:

```lua
BotApi.Scene.Flags = { { name = "zz1", occupant = 0 }, { name = "zz2", occupant = 0 } }
BotApi.Instance.team = "a"
LabelFlags()
```

with:

```lua
BotApi.Scene.Flags = { { name = "zz1", occupant = 0 }, { name = "zz2", occupant = 0 } }
BotApi.Instance.team = "a"
Context.MapName = "zz_unknown_map"
LabelFlags()
```

Run: `cd resource/script/multiplayer && lua tests/sector_spec.lua`
Expected: FAIL on the team-a assertions (`a f10 sector expected ENEMY got CONTESTED`), because `LabelFlags` still looks up by fingerprint while `Sectors` is now keyed by map name.

- [ ] **Step 4: Change LabelFlags to look up by map name**

In `resource/script/multiplayer/bot.lua`, in `LabelFlags` (~line 714-722), change:

```lua
	local fp = FlagFingerprint()
	local entry = Sectors and Sectors[fp]
```

to:

```lua
	local fp = FlagFingerprint()
	local entry = Sectors and Context.MapName and Sectors[Context.MapName]
```

and change the fallback log line from:

```lua
		print("[AISPAWN] SECTOR_FALLBACK fingerprint=" .. fp)
```

to:

```lua
		print("[AISPAWN] SECTOR_FALLBACK map=" .. tostring(Context.MapName) .. " fp=" .. fp)
```

- [ ] **Step 5: Run sector_spec to verify it passes**

Run: `cd resource/script/multiplayer && lua tests/sector_spec.lua`
Expected: `sector team-a OK` / `sector team-b OK` / `sector fallback OK`.

- [ ] **Step 6: Update partition_spec, run to verify it passes**

In `resource/script/multiplayer/tests/partition_spec.lua`, change line 17 from:

```lua
BotApi.Instance.team = "a"; BotApi.Instance.teamSize = 2
```

to:

```lua
BotApi.Instance.team = "a"; BotApi.Instance.teamSize = 2
Context.MapName = "2v2_bastogne"
```

Run: `cd resource/script/multiplayer && lua tests/partition_spec.lua`
Expected: `partition coverage OK` / `partition untrusted-idx OK` / `partition fallback OK`.

- [ ] **Step 7: Wire ReadMapName into OnGameStart**

In `resource/script/multiplayer/bot.lua`, in `OnGameStart`, on the line immediately before the existing `LabelFlags()` call (currently after `MapProbe()`), add:

```lua
	Context.MapName = ReadMapName()
```

so the order reads:

```lua
	MapProbe()
	Context.MapName = ReadMapName()
	LabelFlags()
	PartitionFlags()
```

- [ ] **Step 8: Run the full gate**

```bash
cd resource/script/multiplayer && luac -p bot.lua && luac -p flag_sectors.lua
for t in phase_spec integration_spec sector_spec partition_spec mapname_spec; do lua tests/$t.lua || exit 1; done
cd ../../../tools && python3 test_build_sectors.py
```

Expected: all specs print their `OK` lines; `build_sectors test OK`.

- [ ] **Step 9: Commit**

```bash
git add tools/build_sectors.py resource/script/multiplayer/flag_sectors.lua \
  resource/script/multiplayer/bot.lua \
  resource/script/multiplayer/tests/sector_spec.lua \
  resource/script/multiplayer/tests/partition_spec.lua
git commit -m "feat: key Sectors by map name; LabelFlags uses Context.MapName from ReadMapName"
```

---

## Notes for the implementer

- `MapProbe()` stays in `OnGameStart` for now — it is diagnostic and harmless. Trimming it is a separate cleanup, out of scope here.
- Adding the 20 colliding maps' geometry to `flag_sectors.lua` is a separate follow-up (run `build_sectors.py` over their `.mi` files). This plan only re-keys the existing 4.
- After this plan, verify in a real self-hosted match: `grep "SECTOR_FALLBACK" game.log` should be ABSENT on a mapped map (e.g. bastogne) and the `SECTOR pid=...` lines should appear, confirming `ReadMapName` -> `Sectors[name]` resolved.
