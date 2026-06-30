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

-- Base-tag model (revised spec 2026-06-29): f1 has no base tag -> CONTESTED (not ENEMY).
-- f8 (held by a) is in f1.nb, so f1 is frontier; f1 mine=true (shared band) -> tier 2.
-- f10 (base={"b"}) is ENEMY for team a -> tier 3. Tier 2 beats tier 3, f1 still wins.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f8 = "a", f1 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f1", "f1 (closer enemy) beats f10 (deeper enemy)")
eq(Context.LastPickTier, 2, "f1 picked at tier 2 (CONTESTED frontier; base-tag spec)")

-- Never-nil: a single deep enemy flag with no frontier still returns it (tier 3).
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f10", "lone deep enemy flag still targeted")

-- Tier 3 closest-distance ordering: own f5 (home secure), enemy holds two non-frontier
-- CONTESTED flags. f1 (d^2=5586701) is closer to f5 than f3 (d^2=5970989); tier 3 picks f1.
BotApi.Instance.playerId = 1
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f1", "tier3 picks the closer enemy flag")
eq(Context.LastPickTier, 3, "f1 picked at tier 3")

-- Tier 2 (CONTESTED frontier) beats tier 3 (ENEMY). Under base-tag labeling:
-- f6 is an a-base flag (OWN for team a); held by team a it makes f7 a frontier flag,
-- because f6 is in f7.nb ({"f1","f2","f4","f6"}). f7 has no base tag -> CONTESTED, and
-- falls in lateral band 1 (mine=true for playerId=1, teamSize=2). f10 is a b-base flag
-- -> ENEMY for team a, with no mine+CONTESTED+frontier qualification -> tier 3.
BotApi.Instance.playerId = 1
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f6 = "a", f7 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f7", "tier2 CONTESTED frontier beats tier3 ENEMY")
eq(Context.LastPickTier, 2, "f7 picked at tier 2")

-- Untrusted partition own-all: playerId=3 outside 1..teamSize makes PartitionFlags set
-- mine=true on every flag. Enemy holds f8 (CONTESTED, frontier via f5 in f8.nb), which
-- qualifies for tier 2 under own-all. PickGroupTarget must return non-nil.
BotApi.Instance.playerId = 3
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f8 = "b" })
LabelFlags(); PartitionFlags()
local ownall_pick = PickGroupTarget(nil)
eq(ownall_pick ~= nil, true, "own-all: tier2 still returns a target")

-- === Task 1: FlagTier, preemption, ReorderGroup ===

-- FlagTier matches the tier the inline classifier produced.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "b", f10 = "b" })   -- f5 OWN-sector held by enemy
LabelFlags(); PartitionFlags()
eq(FlagTier("f5"), 1, "FlagTier: enemy on OWN flag is tier 1")
eq(FlagTier("f10"), 3, "FlagTier: deep enemy flag is tier 3")
eq(FlagTier("f2"), nil, "FlagTier: neutral flag with no LostStamp is not a candidate")

-- Preemption: group 1 holding a tier-3 target switches when a tier-2 flag appears,
-- and ReorderGroup re-issues CaptureFlag to the member squad.
Context.LostStamp = {}
Context.Groups = {}
Context.SquadGroup = { s1 = 1 }
Context.FieldUnits = { s1 = { unit = "x" } }
BotApi.Scene.Flags = bastogne({ f10 = "b" })             -- only deep enemy -> tier 3
LabelFlags(); PartitionFlags()
Context.Groups[1] = { members = { s1 = true }, size = 5, target = "f10", pending = 0 }
local captured = {}
local realCapture = BotApi.Commands.CaptureFlag
BotApi.Commands.CaptureFlag = function(_, squad, flag) captured[squad] = flag end
-- f6 held by a (own base) makes f7 a frontier flag; enemy holds f7 -> tier 2.
BotApi.Scene.Flags = bastogne({ f6 = "a", f7 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()
UpdateGroupTargets()
eq(Context.Groups[1].target, "f7", "preempt: tier3 f10 -> tier2 f7")
eq(captured.s1, "f7", "ReorderGroup re-issued capture to member on switch")

-- No preemption within the same tier: a closer tier-3 flag does not displace the
-- current tier-3 target.
Context.Groups = {}
Context.SquadGroup = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })   -- f1,f3 tier-3 enemy
LabelFlags(); PartitionFlags()
Context.Groups[1] = { members = {}, size = 5, target = "f3", pending = 0 }
UpdateGroupTargets()
eq(Context.Groups[1].target, "f3", "same-tier closer candidate does not preempt")
BotApi.Commands.CaptureFlag = realCapture

-- === Task 2: PickSubTarget ===

-- Sub picks the objective nearest to the main target, excluding the main target.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })   -- f1,f3 are tier-3 objectives
LabelFlags(); PartitionFlags()
eq(PickSubTarget("f1"), "f3", "sub picks the other objective near main")

-- Only one objective on the map: sub falls back to the main target.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f10 = "b" })
LabelFlags(); PartitionFlags()
eq(PickSubTarget("f10"), "f10", "sub falls back to main target when no other objective")

-- No main target: sub returns nil.
eq(PickSubTarget(nil), nil, "sub returns nil without a main target")

-- Sub follows main: when the main target changes, the sub re-picks the nearest
-- remaining objective and re-orders its member.
Context.LostStamp = {}
Context.SquadGroup = { s2 = 2 }
Context.FieldUnits = { s2 = { unit = "y" } }
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })
LabelFlags(); PartitionFlags()
Context.Groups = {}
Context.Groups[1] = { members = {}, size = 5, target = "f1", pending = 0 }
Context.Groups[2] = { members = { s2 = true }, size = 3, target = "f1", pending = 0 }
local subCaptured = {}
local realCap2 = BotApi.Commands.CaptureFlag
BotApi.Commands.CaptureFlag = function(_, squad, flag) subCaptured[squad] = flag end
UpdateGroupTargets()
eq(Context.Groups[2].target, "f3", "sub retargets to the other objective near main")
eq(subCaptured.s2, "f3", "sub re-orders its member on retarget")
BotApi.Commands.CaptureFlag = realCap2

print("routing OK")
