dofile((arg[0]:gsub("frontier_spec%.lua$", "harness.lua")))

local function bastogneFlags(occ)
	local t = {}
	for _, n in ipairs({"f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f20"}) do
		t[#t + 1] = { name = n, occupant = occ[n] or 0 }
	end
	return t
end

-- team a, bastogne; nobody owns anything yet
BotApi.Instance.team = "a"; BotApi.Instance.playerId = 1
BotApi.Scene.Flags = bastogneFlags({})
Context.MapName = "2v2_bastogne"
LabelFlags()

-- LabelFlags must carry the adjacency graph onto FlagLabel
assert(Context.FlagLabel["f1"].nb, "f1 has nb")
assert(#Context.FlagLabel["f1"].nb > 0, "f1 nb non-empty")

-- No owned flags and no base adjacency for f10 -> not frontier
-- (f10 is deep; it is not adjacent to a-base and we own nothing)
assert(IsFrontier("f10") == false, "f10 not frontier when nothing owned")

-- Own f8 (a neighbor of f1); now f1 becomes frontier
BotApi.Scene.Flags = bastogneFlags({ f8 = "a" })
LabelFlags()
assert(IsFrontier("f1") == true, "f1 frontier once neighbor f8 owned")

-- Base adjacency: a flag whose base list includes 'a' is frontier for team a with nothing owned
local baseAdjFlag
for n, lbl in pairs(Context.FlagLabel) do
	if lbl.base then for _, t in ipairs(lbl.base) do if t == "a" then baseAdjFlag = n end end end
end
assert(baseAdjFlag, "some flag is a-base adjacent")
BotApi.Scene.Flags = bastogneFlags({})
LabelFlags()
assert(IsFrontier(baseAdjFlag) == true, "base-adjacent flag is frontier for its team")

-- Unknown flag / no label -> false, no error
assert(IsFrontier("nonexistent") == false, "no label -> not frontier")

print("frontier OK")
