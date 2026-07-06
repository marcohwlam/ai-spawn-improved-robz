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

-- GroupToFill must count PENDING (queued, not-yet-landed) fills too, not just live members.
-- A wave drives several AttemptSpawn calls across quants before any of them resolve via
-- OnGameSpawn; without this, the same under-cap group keeps getting picked on every one of
-- those calls and overshoots its size well past cap (observed ballooning a size-3 sub group
-- to 6-8 members in one wave) while a co-existing group is starved of that wave's budget.
Context.Groups = { [1] = { members = {}, auxMembers = {}, size = 3, pending = 3 } }
eq(GroupToFill(), nil, "0 live + 3 pending == size 3 -> full, not re-selected")
Context.Groups[1].pending = 2
eq(GroupToFill(), 1, "0 live + 2 pending < size 3 -> still open for exactly 1 more")
print("GroupToFill OK")

-- OnGameSpawn: a combat group spawn decrements pending and counts toward the cap.
BotApi.Commands.CaptureFlag = function() end
Context.SquadTimers = {}
Context.SquadGroup = {}
Context.FieldUnits = {}
Context.AirborneSquads = {}
Context.Groups = { [1] = { members = {}, auxMembers = {}, size = 5, pending = 1, target = "f1" } }
Context.PendingSpawn = { kind = "group", info = { class = UnitClass.Infantry }, slot = 1, aux = false }
OnGameSpawn({ squadId = 41 })
eq(Context.Groups[1].members[41], true, "combat member added")
eq(Context.Groups[1].auxMembers[41], nil, "combat member not tagged aux")
eq(Context.Groups[1].pending, 0, "combat spawn decrements pending")
eq(GroupMemberCount(Context.Groups[1]), 1, "combat member counts toward cap")
print("OnGameSpawn combat OK")

-- OnGameSpawn: an aux group spawn rides along, does NOT touch pending, does NOT fill the cap.
Context.Groups = { [1] = { members = {}, auxMembers = {}, size = 5, pending = 2, target = "f1" } }
Context.PendingSpawn = { kind = "group", info = { class = UnitClass.MG }, slot = 1, aux = true }
OnGameSpawn({ squadId = 42 })
eq(Context.Groups[1].members[42], true, "aux member added (follows the group target)")
eq(Context.Groups[1].auxMembers[42], true, "aux member tagged")
eq(Context.Groups[1].pending, 2, "aux spawn leaves pending unchanged")
eq(GroupMemberCount(Context.Groups[1]), 0, "aux member does not fill the cap")
-- The aux member still has SquadGroup set, so CaptureFlag routes it to the group target.
eq(Context.SquadGroup[42], 1, "aux member is a group member (follows target)")
print("OnGameSpawn aux ride-along OK")

-- AttemptSpawn must claim a pending-spawn descriptor on every successful Spawn, even when
-- there is no group to attach to (FillGroup unset/pruned). Skipping this silently desyncs
-- the next OnGameSpawn for every OTHER trickle -- e.g. the next officer spawn inherits THIS
-- combat unit's leftover descriptor and gets sent to attack, while this unit inherits the
-- officer's and sits parked at base forever.
Context.FillGroup = nil
Context.Groups = {}
Context.PendingSpawn = nil
Context.SpawnInfo = { unit = "riflemans(ger)", class = UnitClass.Infantry, inf = "rifle" }
Context.RatioCount = 0
Context.AuxOwed = 0
Context.FailCooldown = {}
local realUpdateUnitToSpawn = UpdateUnitToSpawn
UpdateUnitToSpawn = function() end -- PIter/Purchases plumbing is irrelevant to this assertion
AttemptSpawn("SPAWN")
UpdateUnitToSpawn = realUpdateUnitToSpawn
assert(Context.PendingSpawn ~= nil, "AttemptSpawn claims a pending spawn even with no group to fill")
eq(Context.PendingSpawn.kind, "trickle", "no-group spawn queues as a plain trickle descriptor")
print("AttemptSpawn no-group push OK")
