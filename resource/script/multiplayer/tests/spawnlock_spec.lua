dofile((arg[0]:gsub("spawnlock_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- The engine confirms a Spawn() call asynchronously via OnGameSpawn, not within the same
-- quant it was issued. ClaimSpawnSlot/SpawnSlotFree allow only ONE unconfirmed spawn at a
-- time, so whichever squad OnGameSpawn fires for next is unambiguously that spawn -- see the
-- SpawnSlotFree comment for the FIFO-desync bug class this replaced (a tank spawn's
-- descriptor getting consumed by an unrelated capper/officer confirmation, corrupting
-- tier-ratio accounting for as long as the mislabeled squad stayed alive).
local PendingSpawnTimeoutQuants = 20 -- must match the local of the same name in bot.lua

Context.MatchQuants = 5
eq(SpawnSlotFree(), true, "slot starts free at a fresh quant")

ClaimSpawnSlot({ kind = "trickle", info = { unit = "x" } })
eq(SpawnSlotFree(), false, "slot is claimed once a spawn is pending")

-- A second attempt in the SAME quant must see the slot as taken.
eq(SpawnSlotFree(), false, "still claimed on repeated checks within the same quant")

-- Unlike the old per-quant lock, the NEXT quant tick does NOT free the slot on its own --
-- the pending spawn is still unconfirmed, so a second Spawn() must not be allowed to race it.
Context.MatchQuants = 6
eq(SpawnSlotFree(), false, "slot stays claimed across quants until OnGameSpawn confirms it")

-- OnGameSpawn confirming the pending spawn clears it.
OnGameSpawn({ squadId = 1 })
eq(Context.PendingSpawn, nil, "OnGameSpawn consumes the pending descriptor")
eq(SpawnSlotFree(), true, "slot frees once the pending spawn is confirmed")

print("spawnlock OK")

-- Safety net: if the engine drops a confirmation outright, the pending slot must not wedge
-- spawning forever -- it times out after PendingSpawnTimeoutQuants.
Context.MatchQuants = 10
ClaimSpawnSlot({ kind = "trickle", info = { unit = "y" } })
Context.MatchQuants = 10 + PendingSpawnTimeoutQuants
eq(SpawnSlotFree(), false, "not yet timed out at exactly the threshold")
Context.MatchQuants = 10 + PendingSpawnTimeoutQuants + 1
eq(SpawnSlotFree(), true, "pending spawn times out and frees the slot")
eq(Context.PendingSpawn, nil, "timed-out pending spawn is cleared")
print("spawn timeout OK")

-- SpawnPauseUntil (heavy-fail-streak affordability guard): while Elapsed() < SpawnPauseUntil,
-- SpawnSlotFree must return false regardless of the pending-spawn state, so every trickle
-- (they all gate on SpawnSlotFree) is paused, not just the wave driver.
Context.PendingSpawn = nil
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

-- A timed-out non-aux group fill must release the group's pending count immediately, not
-- leave it to PruneGroups' separate 3s staleSince timer to discover the leak later -- that
-- redundant second timeout meant a group could sit unable to accept new fills for several
-- extra seconds after the lost confirmation was already known.
Context.Groups = { [1] = { members = {}, auxMembers = {}, size = 4, pending = 1 } }
Context.MatchQuants = 20
ClaimSpawnSlot({ kind = "group", info = { unit = "z" }, slot = 1, aux = false })
Context.MatchQuants = 20 + PendingSpawnTimeoutQuants + 1
eq(SpawnSlotFree(), true, "timed-out non-aux group fill frees the slot")
eq(Context.Groups[1].pending, 0, "timed-out non-aux group fill releases the group's pending count")

-- An aux fill's timeout must NOT touch pending (aux was never counted toward it).
Context.Groups = { [1] = { members = {}, auxMembers = {}, size = 4, pending = 1 } }
Context.MatchQuants = 40
ClaimSpawnSlot({ kind = "group", info = { unit = "z" }, slot = 1, aux = true })
Context.MatchQuants = 40 + PendingSpawnTimeoutQuants + 1
eq(SpawnSlotFree(), true, "timed-out aux group fill frees the slot")
eq(Context.Groups[1].pending, 1, "timed-out aux group fill leaves the group's pending count untouched")
print("spawn-loss pending cleanup OK")
