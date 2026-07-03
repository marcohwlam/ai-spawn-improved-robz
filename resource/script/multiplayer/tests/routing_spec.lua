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
Context.GameClock = 240   -- past GroupHomeGraceSec: home recapture is active for the assertions below

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

-- Natural frontline: own f5 (rear secure), enemy holds two DEEP CONTESTED flags (f1, f3).
-- f8 is a still-NEUTRAL frontier flag (f5 is in f8.nb), so it is a tier-2 group target and
-- beats the deeper enemy flags -- groups fight at the contested boundary, they do not march
-- past a neutral center into deeper enemy ground.
BotApi.Instance.playerId = 1
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f1 = "b", f3 = "b" })
LabelFlags(); PartitionFlags()
eq(PickGroupTarget(nil), "f8", "neutral frontier (frontline) beats deeper enemy flags")
eq(Context.LastPickTier, 2, "frontline flag picked at tier 2")

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

-- Tier 2.5: a mine+CONTESTED lane flag whose IsFrontier neighbor isn't held by us YET (a
-- transient frontier gap -- see the "attacked enemy home instead of the frontline" bug),
-- but we already hold ground elsewhere (home f5). Must rank ahead of a genuine tier-3
-- ENEMY flag so the group never leapfrogs the frontline straight at the enemy base.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "a", f4 = "b" })
LabelFlags(); PartitionFlags()
Context.FlagOwner["f2"] = { mine = true } -- force lane ownership, isolate from band geometry
eq(IsFrontier("f2"), false, "f2's neighbors (f4 enemy, f6/f7 unheld) are not ours yet")
eq(FlagTier("f2"), 2.5, "FlagTier: CONTESTED lane flag with unconfirmed frontier is tier 2.5")
eq(FlagTier("f4"), 3, "FlagTier: f4 (ENEMY base flag) is still tier 3")

-- Guard: tier 2.5 requires holding ground somewhere first. With nothing captured anywhere
-- (matches the "no enemy and no recently-lost -> nil" invariant below), the same lane flag
-- must stay nil, not jump to 2.5.
BotApi.Scene.Flags = bastogne({})
LabelFlags(); PartitionFlags()
Context.FlagOwner["f2"] = { mine = true }
eq(FlagTier("f2"), nil, "tier 2.5 requires HeldFlagCount() > 0; holding nothing yields nil")

-- Restore the f5/f10 scene the Home grace block below depends on (Tier 2.5 block above
-- swapped in different flag states).
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f5 = "b", f10 = "b" })
LabelFlags(); PartitionFlags()

-- Home grace: in the first GroupHomeGraceSec, groups ignore OWN (home) flags entirely and
-- push forward; the deep enemy flag is still a target. After the grace, home returns tier 1.
Context.GameClock = 100   -- inside the grace window
eq(FlagTier("f5"), nil, "FlagTier: OWN flag is NOT a group target during the home grace")
eq(FlagTier("f10"), 3, "FlagTier: deep enemy flag still tier 3 during the grace")
eq(PickGroupTarget(nil), "f10", "during grace, groups push to the deep flag, not home")
Context.GameClock = 240   -- restore post-grace for the assertions that follow
eq(FlagTier("f5"), 1, "FlagTier: OWN flag is tier 1 again after the grace")

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

-- No preemption within the same tier: a closer tier-3 flag does not displace the current
-- tier-3 target. Own nothing so there is no neutral frontier (tier-2) flag in play; f4 and
-- f10 are both deep ENEMY-sector tier-3 flags.
Context.Groups = {}
Context.SquadGroup = {}
BotApi.Scene.Flags = bastogne({ f4 = "b", f10 = "b" })   -- f4,f10 tier-3 enemy, no owned flag
LabelFlags(); PartitionFlags()
Context.Groups[1] = { members = {}, size = 5, target = "f4", pending = 0 }
UpdateGroupTargets()
eq(Context.Groups[1].target, "f4", "same-tier closer candidate does not preempt")
BotApi.Commands.CaptureFlag = realCapture

-- Stuck timeout: a group that has held the same still-attackable, non-preemptable
-- target for more than GroupTargetStuckSec (480s) is forced to re-pick, excluding
-- the stuck flag, even though nothing else about the target changed.
Context.LostStamp = {}
Context.Groups = {}
Context.SquadGroup = { s3 = 1 }
Context.FieldUnits = { s3 = { unit = "x" } }
BotApi.Scene.Flags = bastogne({ f4 = "b", f10 = "b" })   -- f4,f10 tier-3 enemy, no owned flag
LabelFlags(); PartitionFlags()
local stuckCaptured = {}
local realCap3 = BotApi.Commands.CaptureFlag
BotApi.Commands.CaptureFlag = function(_, squad, flag) stuckCaptured[squad] = flag end

-- Under the timeout: no re-pick even though f10 is an equal-tier candidate.
Context.Groups[1] = { members = { s3 = true }, size = 5, target = "f4", pending = 0, targetSince = 0 }
Context.GameClock = 479
UpdateGroupTargets()
eq(Context.Groups[1].target, "f4", "under 480s stuck: no re-pick")
eq(stuckCaptured.s3, nil, "under 480s stuck: no re-order issued")

-- Past the timeout: forced re-pick lands on the only other tier-3 candidate (f10),
-- excluding the stuck flag (f4) itself.
Context.GameClock = 481
UpdateGroupTargets()
eq(Context.Groups[1].target, "f10", "past 480s stuck: forced re-pick excludes f4")
eq(stuckCaptured.s3, "f10", "past 480s stuck: ReorderGroup re-issued capture to member")
eq(Context.Groups[1].targetSince, 481, "past 480s stuck: targetSince resets on re-pick")
BotApi.Commands.CaptureFlag = realCap3

-- Stuck timeout with a live sub group: the forced re-pick must exclude the sub group's
-- target too, not just the stuck flag, so group 1 can never just be handed group 2's own
-- objective (PickGroupTarget's second exclude param).
Context.LostStamp = {}
Context.Groups = {}
Context.SquadGroup = { s3 = 1 }
Context.FieldUnits = { s3 = { unit = "x" } }
BotApi.Scene.Flags = bastogne({ f4 = "b", f10 = "b", f1 = "b" }) -- three tier-3 enemy flags, no owned flag
LabelFlags(); PartitionFlags()
local dualCaptured = {}
local realCap4 = BotApi.Commands.CaptureFlag
BotApi.Commands.CaptureFlag = function(_, squad, flag) dualCaptured[squad] = flag end
Context.Groups[1] = { members = { s3 = true }, size = 5, target = "f4", pending = 0, targetSince = 0 }
Context.Groups[2] = { members = {}, size = 3, target = "f10", pending = 0 }
Context.GameClock = 481
UpdateGroupTargets()
eq(Context.Groups[1].target, "f1", "past 480s stuck with sub group: re-pick excludes stuck flag AND sub target")
eq(dualCaptured.s3, "f1", "past 480s stuck with sub group: ReorderGroup re-issued to the non-excluded flag")
BotApi.Commands.CaptureFlag = realCap4

-- === Task 2: PickSubTarget ===

-- Sub picks the objective nearest to the main target, excluding the main target.
Context.LostStamp = {}
BotApi.Scene.Flags = bastogne({ f1 = "b", f3 = "b" })   -- no owned flag: f1,f3 are the only (tier-3) objectives
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
BotApi.Scene.Flags = bastogne({ f1 = "b", f3 = "b" })   -- no owned flag: f1,f3 are the only objectives
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

-- === Task 3: ApportionArmor and ArmorTargetCount ===

Context.Groups = { [1] = { members = {}, size = 5 }, [2] = { members = {}, size = 3 } }

-- Late composition: armorTotal = heavy1 + medium1 = 2, split 5/3 -> main 1, sub 1.
ApportionArmor({ targets = { heavy = 1, medium = 1, light = 2, rifle = 2, smg = 1 } })
eq(Context.Groups[1].armorLead, 1, "late armor: main gets 1")
eq(Context.Groups[2].armorLead, 1, "late armor: sub gets 1")

-- Mid composition: armorTotal = 1 -> main 1, sub 0 (largest remainder gives the unit to main).
ApportionArmor({ targets = { medium = 1, light = 2, rifle = 2, smg = 1 } })
eq(Context.Groups[1].armorLead, 1, "mid armor: main gets 1")
eq(Context.Groups[2].armorLead, 0, "mid armor: sub gets 0")

-- Early composition: no armor target -> both 0.
ApportionArmor({ targets = { light = 1, rifle = 3, smg = 1 } })
eq(Context.Groups[1].armorLead, 0, "early: main armorLead 0")
eq(Context.Groups[2].armorLead, 0, "early: sub armorLead 0")

-- ArmorTargetCount rounds armorTotal / CycleSize * totalGroupCapacity (capacity 8 here).
eq(ArmorTargetCount({ targets = { heavy = 1, medium = 1, light = 2, rifle = 2, smg = 1 } }), 2,
	"late armor target count is 2")
eq(ArmorTargetCount({ targets = { medium = 1, light = 2, rifle = 2, smg = 1 } }), 1,
	"mid armor target count is 1")

-- === TrackLostFlags: own->neutral stamps LostStamp (react before full enemy capture) ===
-- A flag owned last tick that drops to neutral (enemy mid-capture) must be stamped now,
-- not only when the enemy fully owns it. The stamp makes FlagTier treat the own-sector
-- flag as tier 1 immediately.
BotApi.Instance.team = "a"; BotApi.Instance.enemyTeam = "b"
Context.GameClock = 240
Context.LostStamp = {}
Context.PrevOwned = {}

-- Tick 1: f6 is ours -> no stamp, recorded as previously owned.
BotApi.Scene.Flags = bastogne({ f6 = "a" })
TrackLostFlags()
eq(Context.LostStamp["f6"], nil, "TrackLostFlags: still-owned flag is not stamped")
eq(Context.PrevOwned["f6"], true, "TrackLostFlags: owned flag recorded as previously owned")

-- Tick 2: f6 drops to neutral (occupant 0) -> stamped at the current clock.
BotApi.Scene.Flags = bastogne({})
TrackLostFlags()
eq(Context.LostStamp["f6"], 240, "TrackLostFlags: own->neutral stamps LostStamp now")

-- A flag never owned (f2 stayed neutral both ticks) is not stamped.
eq(Context.LostStamp["f2"], nil, "TrackLostFlags: never-owned neutral flag is not stamped")

-- End to end: the freshly-stamped neutral own flag is a tier 1 target.
LabelFlags(); PartitionFlags()
eq(FlagTier("f6"), 1, "own->neutral flag escalates to tier 1 before enemy capture")
eq(PickGroupTarget(nil), "f6", "group retakes the own flag being captured")

-- === TrackLostFlags / FlagJustCaptured: the symmetric case -- occupant flipping to us is
-- not proof the capture is secure (the engine flag object exposes only name+occupant, no
-- progress %), so a settle grace keeps a just-captured flag as a valid target instead of it
-- falling straight to nil the instant occupant flips. ===
Context.GameClock = 300
Context.PrevOwned = {}
Context.CapturedStamp = {}

-- Tick 1: f8 is neutral -> no stamp, recorded as not-owned.
BotApi.Scene.Flags = bastogne({})
TrackLostFlags()
eq(Context.CapturedStamp["f8"], nil, "TrackLostFlags: still-neutral flag is not stamped")

-- Tick 2: f8 flips to ours -> stamped at the current clock.
BotApi.Scene.Flags = bastogne({ f8 = "a" })
TrackLostFlags()
eq(Context.CapturedStamp["f8"], 300, "TrackLostFlags: neutral->owned stamps CapturedStamp now")

-- A flag already owned coming into this tick (no transition) is not (re-)stamped.
Context.PrevOwned["f6"] = true
BotApi.Scene.Flags = bastogne({ f6 = "a", f8 = "a" })
TrackLostFlags()
eq(Context.CapturedStamp["f6"], nil, "TrackLostFlags: already-owned flag is not stamped")

-- FlagJustCaptured: true only within CaptureSettleSec of the stamp AND still owned by us.
eq(FlagJustCaptured("f8"), true, "FlagJustCaptured: true right after capture")
Context.GameClock = 300 + 29
eq(FlagJustCaptured("f8"), true, "FlagJustCaptured: still true just under the settle window")
Context.GameClock = 300 + 30
eq(FlagJustCaptured("f8"), false, "FlagJustCaptured: false once the settle window elapses")

-- Stale stamp: captured, then lost again -- must not read as settling off the old stamp.
Context.GameClock = 305
BotApi.Scene.Flags = bastogne({ f6 = "a" })  -- f8 no longer occupied by us
eq(FlagJustCaptured("f8"), false, "FlagJustCaptured: false if no longer owned, even inside the time window")

-- FlagTier: a just-captured flag scores tier 2 (holds as a valid target) instead of falling
-- through to nil, so neither PickGroupTarget nor PickSubTarget drop it as a candidate the
-- instant it flips -- this is what stops a group from leapfrogging straight to a deep tier-3
-- enemy flag the moment its own capture completes, before any group re-pick even happens.
Context.CapturedStamp = { f9 = 300 }
Context.GameClock = 310
BotApi.Scene.Flags = bastogne({ f9 = "a" })
eq(FlagTier("f9"), 2, "just-captured flag scores tier 2, not nil, during the settle window")

-- === End-to-end reproduction of the reported bug: a group capping a frontier flag (f7) must
-- not leapfrog to a deep enemy flag (f10, tier 3, confirmed to STAY tier 3 even once f7 is
-- owned -- unlike f1, which turns out to be a neighbor of f7 and flips to tier 2 itself once
-- f7 is ours) the instant f7's occupant flips to us, before the capture is secure.
-- UpdateGroupTargets is the exact function that made the wrong call in the field log (target
-- switched f7 (tier 2.5) -> a tier-3 flag, reason=priority, only ~10s after f7 was set as the
-- target -- not a stuck timeout). ===
Context.Groups = {}
Context.SquadGroup = { s2 = 1 }
Context.FieldUnits = { s2 = { unit = "x" } }
-- f6 has been ours since before this scenario starts (home base) -- primed directly rather
-- than via TrackLostFlags(), which would otherwise (incorrectly, as a test artifact of the
-- fresh PrevOwned={} reset) stamp CapturedStamp["f6"] as if it were JUST captured too.
Context.PrevOwned = { f6 = true }
Context.CapturedStamp = {}
Context.LostStamp = {}
Context.GameClock = 400
local realCapture2 = BotApi.Commands.CaptureFlag
BotApi.Commands.CaptureFlag = function() end

-- Minimal, isolated flag set (not the full bastogne() 11-flag fixture): several of its other
-- neutral flags turn out to ALSO score tier 2 once f7 is owned (frontier-adjacency chains
-- through the map's neighbor graph), which would make PickGroupTarget's axis tie-break
-- nondeterministic noise unrelated to what this test is actually checking. f6 is our home
-- base, f7 is mid-cap in our lane (frontier), f10 is the deep-enemy tier-3 fallback.
local function flag(name, occ) return { name = name, occupant = occ } end
BotApi.Scene.Flags = { flag("f6", "a"), flag("f7", 0), flag("f10", "b") }
LabelFlags(); PartitionFlags()
Context.Groups[1] = { members = { s2 = true }, size = 5, target = "f7", pending = 0, targetSince = 400 }
UpdateGroupTargets()
eq(Context.Groups[1].target, "f7", "still capping: target unchanged (already covered by same-tier stickiness)")

-- f7's capture completes (occupant flips to us) mid-quant. Without the settle grace this is
-- exactly the moment FlagAttackable(f7) goes false and the bug fired.
Context.GameClock = 410
BotApi.Scene.Flags = { flag("f6", "a"), flag("f7", "a"), flag("f10", "b") }
LabelFlags(); PartitionFlags()
TrackLostFlags() -- stamps CapturedStamp["f7"] = 410 (neutral -> owned transition)
UpdateGroupTargets()
eq(Context.Groups[1].target, "f7", "just captured: target NOT bumped to the deep enemy flag")
-- CaptureFlag's own group-target guard is what would actually route a squad here (not
-- UpdateGroupTargets/ReorderGroup, which only re-orders on an actual target CHANGE): confirm
-- it accepts f7 via FlagJustCaptured even though FlagAttackable(f7) is now false.
BotApi.Commands.CaptureFlag = function(_, squad, flag)
	eq(flag, "f7", "just captured: CaptureFlag still routes the member to hold f7")
end
CaptureFlag("s2")
BotApi.Commands.CaptureFlag = function() end

-- Still within the settle window a few ticks later: target holds.
Context.GameClock = 430
UpdateGroupTargets()
eq(Context.Groups[1].target, "f7", "mid-settle: target still holds f7")

-- Settle window elapses: f7 is a genuinely spent objective now (owned, no longer held/lost),
-- so the group is free to move on -- to f10, the only remaining attackable flag.
Context.GameClock = 441 -- 410 + CaptureSettleSec(30) + 1
UpdateGroupTargets()
eq(Context.Groups[1].target, "f10", "settle window elapsed: group now free to advance to f10")
BotApi.Commands.CaptureFlag = realCapture2

print("routing OK")
