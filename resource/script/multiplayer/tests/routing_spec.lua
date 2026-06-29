dofile((arg[0]:gsub("routing_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

local function bastogne(occ)
	local t = {}
	for _, n in ipairs({"f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f20"}) do
		t[#t + 1] = { name = n, occupant = occ[n] or 0 }   -- 0 = neutral
	end
	return t
end

-- team a setup; enemy is team "b"
BotApi.Instance.team = "a"; BotApi.Instance.enemyTeam = "b"
BotApi.Instance.teamSize = 2; BotApi.Instance.playerId = 1
Context.MapName = "2v2_bastogne"
Context.LostStamp = {}

-- Tier 1: enemy holds an OWN-sector flag (f5 is OWN for team a) -> retaken first,
-- even though enemy also holds a deep flag f10.
BotApi.Scene.Flags = bastogne({ f5 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f5", "tier1 home invaded beats deep flag")

-- enemyAttacking: a neutral flag with a LostStamp is a candidate; without one it is not.
-- Enemy holds nothing; f6 (OWN) is neutral but recently lost -> tier 1 candidate.
Context.LostStamp = { f6 = 100 }
BotApi.Scene.Flags = bastogne({})            -- all neutral
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f6", "neutral+LostStamp OWN flag is tier1")

-- A neutral flag with NO LostStamp is not a candidate -> nil when nothing else qualifies.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({})
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), nil, "no enemy and no recently-lost -> nil")

-- Tier 2 over Tier 3: home secure; enemy holds a CONTESTED flag in our lane that is
-- frontier (we own a neighbor) plus a deeper enemy flag. The frontier-lane one wins.
-- We own f8; f1 is CONTESTED, neighbor of f8, in lane. Enemy holds f1 and f10.
-- f1 is the only tier-2 candidate (CONTESTED, neighbor of owned f8 -> frontier, and mine
-- for playerId 1 per the partition); f10 is tier 3 (ENEMY sector). f1 must win.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f8 = "a", f1 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f1", "tier2 lane frontier beats tier3 deep flag")
eq(Context.LastPickTier, 2, "f1 picked at tier 2")

-- Never-nil: a single deep enemy flag with no frontier still returns it (tier 3).
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f10", "lone deep enemy flag still targeted")

print("routing OK")
