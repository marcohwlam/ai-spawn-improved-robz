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

-- team a: f5/f6 are a-base (OWN); f4/f10 are b-base (ENEMY); f7 non-base (CONTESTED).
-- Rank still from raw axis: f10 (axis=0.60) rank 1, f5 (axis=0.32) rank 11.
Context.MapName = "2v2_bastogne"
BotApi.Instance.team = "a"; BotApi.Instance.playerId = 1
LabelFlags()
eq(Context.FlagLabel["f5"].sector, "OWN", "a f5 sector")   -- a-base
eq(Context.FlagLabel["f6"].sector, "OWN", "a f6 sector")   -- a-base
eq(Context.FlagLabel["f10"].sector, "ENEMY", "a f10 sector") -- b-base
eq(Context.FlagLabel["f4"].sector, "ENEMY", "a f4 sector")  -- b-base
eq(Context.FlagLabel["f7"].sector, "CONTESTED", "a f7 sector") -- non-base
eq(Context.FlagLabel["f10"].rank, 1, "a f10 rank")
eq(Context.FlagLabel["f5"].rank, 11, "a f5 rank")
local ownA = 0
for _, l in pairs(Context.FlagLabel) do if l.sector == "OWN" then ownA = ownA + 1 end end
assert(ownA == 2, "team a OWN count == base count (2), got " .. ownA)
assert(Context.FlagBases and Context.FlagBases.a1, "a bases populated")
print("sector team-a OK")

-- team b inverts orientation: ranks flip end-for-end (1<->11), f5/f6 become enemy-side.
-- f4/f10 are b-base (OWN); f5/f6 are a-base (ENEMY); f7 non-base (CONTESTED).
BotApi.Instance.team = "b"; BotApi.Instance.playerId = 3
LabelFlags()
eq(Context.FlagLabel["f4"].sector, "OWN", "b f4 sector")   -- b-base
eq(Context.FlagLabel["f10"].sector, "OWN", "b f10 sector") -- b-base
eq(Context.FlagLabel["f5"].sector, "ENEMY", "b f5 sector") -- a-base
eq(Context.FlagLabel["f7"].sector, "CONTESTED", "b f7 sector")
eq(Context.FlagLabel["f5"].rank, 1, "b f5 rank")
eq(Context.FlagLabel["f10"].rank, 11, "b f10 rank")
local ownB = 0
for _, l in pairs(Context.FlagLabel) do if l.sector == "OWN" then ownB = ownB + 1 end end
assert(ownB == 2, "team b OWN count == base count (2), got " .. ownB)
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
