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
