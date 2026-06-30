dofile((arg[0]:gsub("sector_spec%.lua$", "harness.lua")))

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

-- fingerprint is sorted + comma-joined (string sort, so f10 < f2)
BotApi.Scene.Flags = bastogneFlags()
eq(FlagFingerprint(), "f1,f10,f2,f20,f3,f4,f5,f6,f7,f8,f9", "fingerprint")

-- team a: f10 is closest to enemy home (rank 1, ENEMY); f5 is closest to own (rank 11, OWN)
Context.MapName = "2v2_bastogne"
BotApi.Instance.team = "a"; BotApi.Instance.playerId = 1
LabelFlags()
eq(Context.FlagLabel["f10"].sector, "ENEMY", "a f10 sector")
eq(Context.FlagLabel["f10"].rank, 1, "a f10 rank")
eq(Context.FlagLabel["f5"].sector, "OWN", "a f5 sector")
eq(Context.FlagLabel["f5"].rank, 11, "a f5 rank")
local ownA = 0
for _, l in pairs(Context.FlagLabel) do if l.sector == "OWN" then ownA = ownA + 1 end end
assert(ownA >= 1, "team a must have >=1 OWN flag, got " .. ownA)
assert(Context.FlagBases and Context.FlagBases.a1, "a bases populated")
print("sector team-a OK")

-- team b inverts orientation: ranks flip end-for-end (1<->11), f5 becomes enemy-side
BotApi.Instance.team = "b"; BotApi.Instance.playerId = 3
LabelFlags()
eq(Context.FlagLabel["f5"].rank, 1, "b f5 rank")
eq(Context.FlagLabel["f5"].sector, "ENEMY", "b f5 sector")
eq(Context.FlagLabel["f10"].rank, 11, "b f10 rank")
eq(Context.FlagLabel["f10"].sector, "OWN", "b f10 sector")
eq(Context.FlagLabel["f4"].sector, "OWN", "b f4 sector")
local ownB = 0
for _, l in pairs(Context.FlagLabel) do if l.sector == "OWN" then ownB = ownB + 1 end end
assert(ownB >= 1, "team b must have >=1 OWN flag, got " .. ownB)
print("sector team-b OK")

-- unknown map -> fallback C: all CONTESTED, no rank, no bases
BotApi.Scene.Flags = { { name = "zz1", occupant = 0 }, { name = "zz2", occupant = 0 } }
BotApi.Instance.team = "a"
Context.MapName = "zz_unknown_map"
LabelFlags()
eq(Context.FlagLabel["zz1"].sector, "CONTESTED", "miss zz1 sector")
eq(Context.FlagLabel["zz1"].rank, nil, "miss zz1 rank nil")
eq(Context.FlagBases, nil, "miss bases nil")
print("sector fallback OK")
