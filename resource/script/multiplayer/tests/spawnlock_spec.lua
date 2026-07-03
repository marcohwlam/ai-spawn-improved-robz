dofile((arg[0]:gsub("spawnlock_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- The engine accepts ~1 Spawn per quant tick; ClaimSpawnSlot/SpawnSlotFree serialize the
-- wave/capper/officer/AT-rifle/deep-strike trickles so at most one Commands:Spawn lands per
-- quant. Without this, two same-tick spawns desync the FIFO SpawnQueue and a later
-- OnGameSpawn pops the wrong descriptor -- e.g. a tank never gets a group/order and sits at
-- base (see the "capper not staying" / "tank stuck at base" bugs).

Context.MatchQuants = 5
eq(SpawnSlotFree(), true, "slot starts free at a fresh quant")

ClaimSpawnSlot()
eq(SpawnSlotFree(), false, "slot is claimed for the rest of this quant")

-- A second attempt in the SAME quant must see the slot as taken.
eq(SpawnSlotFree(), false, "still claimed on repeated checks within the same quant")

-- The next quant tick frees the slot again.
Context.MatchQuants = 6
eq(SpawnSlotFree(), true, "slot frees automatically on the next quant")

print("spawnlock OK")

-- SpawnPauseUntil (heavy-fail-streak affordability guard): while Elapsed() < SpawnPauseUntil,
-- SpawnSlotFree must return false regardless of the per-quant claim state, so every trickle
-- (they all gate on SpawnSlotFree) is paused, not just the wave driver.
Context.GameClock = 100
Context.MatchQuants = 7
Context.SpawnPauseUntil = 250
eq(SpawnSlotFree(), false, "paused: slot unavailable even on a fresh, unclaimed quant")

Context.GameClock = 250
eq(SpawnSlotFree(), true, "pause ends exactly at SpawnPauseUntil")

Context.GameClock = 0
Context.SpawnPauseUntil = 0
eq(SpawnSlotFree(), true, "SpawnPauseUntil=0 (default/unset) never blocks")
print("spawn pause gate OK")
