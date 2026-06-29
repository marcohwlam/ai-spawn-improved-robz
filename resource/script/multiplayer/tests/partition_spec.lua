dofile((arg[0]:gsub("partition_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

local function bastogneFlags()
	local t = {}
	for _, n in ipairs({"f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f20"}) do
		t[#t + 1] = { name = n, occupant = 0 }
	end
	return t
end

-- Phase 1 populates FlagLabel{x,y} + FlagBases for bastogne; reuse it as the input.
BotApi.Scene.Flags = bastogneFlags()
BotApi.Instance.team = "a"; BotApi.Instance.teamSize = 2
Context.MapName = "2v2_bastogne"

-- bot idx 1 (playerId 1) and idx 2 (playerId 2) of team a.
BotApi.Instance.playerId = 1; LabelFlags(); PartitionFlags()
local own1, band1 = {}, {}
for n, o in pairs(Context.FlagOwner) do own1[n] = o.mine; band1[n] = o.band end

BotApi.Instance.playerId = 2; PartitionFlags()
local own2 = {}
for n, o in pairs(Context.FlagOwner) do own2[n] = o.mine end

-- Determinism: bands are identical regardless of which bot computed them.
for n, o in pairs(Context.FlagOwner) do eq(o.band, band1[n], "band stable for " .. n) end

-- Coverage + de-confliction: every flag owned by at least one teammate; a flag owned by
-- BOTH iff it is shared; non-shared flags owned by exactly one.
for n, o in pairs(Context.FlagOwner) do
	assert(own1[n] or own2[n], "flag " .. n .. " owned by nobody")
	if o.shared then
		assert(own1[n] and own2[n], "shared flag " .. n .. " not owned by both")
	else
		assert(own1[n] ~= own2[n], "non-shared flag " .. n .. " not exclusive")
	end
end
print("partition coverage OK")

-- Untrusted idx (team a, playerId 3, teamSize 2 -> idx 3 out of 1..2): own-all fallback.
BotApi.Instance.playerId = 3; PartitionFlags()
for n, o in pairs(Context.FlagOwner) do eq(o.mine, true, "untrusted idx owns " .. n) end
print("partition untrusted-idx OK")

-- No bases (unrecognized map): empty FlagOwner, PART_FALLBACK, no error.
Context.FlagBases = nil
Context.FlagLabel = { zz1 = { sector = "CONTESTED" } }
PartitionFlags()
eq(next(Context.FlagOwner), nil, "fallback leaves FlagOwner empty")
print("partition fallback OK")
