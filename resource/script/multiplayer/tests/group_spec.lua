dofile((arg[0]:gsub("group_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- GroupMemberCount counts only non-aux (combat) members; aux ride along uncounted.
local g = { members = { [1] = true, [2] = true, [3] = true }, auxMembers = { [3] = true }, size = 2, pending = 0 }
eq(GroupMemberCount(g), 2, "aux member excluded from the cap count")
g.auxMembers = {}
eq(GroupMemberCount(g), 3, "no aux -> all members count")
print("GroupMemberCount OK")

-- GroupToFill: a size-2 group with 2 combat members is full even with extra aux riding along.
Context.Groups = { [1] = { members = { [1] = true, [2] = true, [3] = true }, auxMembers = { [3] = true }, size = 2, pending = 0 } }
eq(GroupToFill(), nil, "2 combat + 1 aux -> full (aux does not count)")
-- Drop a combat member: 1 combat + 1 aux < size 2 -> still needs filling.
Context.Groups[1].members[2] = nil
eq(GroupToFill(), 1, "1 combat + 1 aux -> still open")
print("GroupToFill OK")

-- OnGameSpawn: a combat group spawn decrements pending and counts toward the cap.
BotApi.Commands.CaptureFlag = function() end
Context.SquadTimers = {}
Context.SquadGroup = {}
Context.FieldUnits = {}
Context.AirborneSquads = {}
Context.Groups = { [1] = { members = {}, auxMembers = {}, size = 5, pending = 1, target = "f1" } }
Context.SpawnQueue = { { kind = "group", info = { class = UnitClass.Infantry }, slot = 1, aux = false } }
OnGameSpawn({ squadId = 41 })
eq(Context.Groups[1].members[41], true, "combat member added")
eq(Context.Groups[1].auxMembers[41], nil, "combat member not tagged aux")
eq(Context.Groups[1].pending, 0, "combat spawn decrements pending")
eq(GroupMemberCount(Context.Groups[1]), 1, "combat member counts toward cap")
print("OnGameSpawn combat OK")

-- OnGameSpawn: an aux group spawn rides along, does NOT touch pending, does NOT fill the cap.
Context.Groups = { [1] = { members = {}, auxMembers = {}, size = 5, pending = 2, target = "f1" } }
Context.SpawnQueue = { { kind = "group", info = { class = UnitClass.MG }, slot = 1, aux = true } }
OnGameSpawn({ squadId = 42 })
eq(Context.Groups[1].members[42], true, "aux member added (follows the group target)")
eq(Context.Groups[1].auxMembers[42], true, "aux member tagged")
eq(Context.Groups[1].pending, 2, "aux spawn leaves pending unchanged")
eq(GroupMemberCount(Context.Groups[1]), 0, "aux member does not fill the cap")
-- The aux member still has SquadGroup set, so CaptureFlag routes it to the group target.
eq(Context.SquadGroup[42], 1, "aux member is a group member (follows target)")
print("OnGameSpawn aux ride-along OK")
