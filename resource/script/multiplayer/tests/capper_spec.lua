dofile((arg[0]:gsub("capper_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

BotApi.Instance.team = "a"; BotApi.Instance.enemyTeam = "b"

local function flag(name, occ) return { name = name, occupant = occ } end

-- Neutral flag in this bot's own lane: top weight (cappers exist to grab these).
Context.FlagLabel = { n1 = { sector = "CONTESTED" } }
Context.FlagOwner = { n1 = { mine = true } }
eq(CapperFlagPriority(flag("n1", 0)), 5.0, "neutral in-lane = 5.0")

-- Enemy-held flag in our lane (not the base sector): low but non-zero, opportunistic grab.
Context.FlagLabel = { e1 = { sector = "CONTESTED" } }
Context.FlagOwner = { e1 = { mine = true } }
eq(CapperFlagPriority(flag("e1", "b")), 1.0, "enemy-held in-lane = 1.0")

-- A flag we already own: weight 0 so the capper rolls on to the next target after capping.
Context.FlagLabel = { o1 = { sector = "OWN" } }
Context.FlagOwner = { o1 = { mine = true } }
eq(CapperFlagPriority(flag("o1", "a")), 0, "already ours = 0 (move on after cap)")

-- Enemy home sector: never (a cheap single unit must not walk into the enemy base),
-- whether the base flag reads neutral or enemy-held.
Context.FlagLabel = { base = { sector = "ENEMY" } }
Context.FlagOwner = { base = { mine = true } }
eq(CapperFlagPriority(flag("base", 0)), 0, "enemy base sector (neutral) = 0")
eq(CapperFlagPriority(flag("base", "b")), 0, "enemy base sector (enemy-held) = 0")

-- A teammate's partition: never, so each bot's cappers stay in their own sector.
Context.FlagLabel = { t1 = { sector = "CONTESTED" } }
Context.FlagOwner = { t1 = { mine = false } }
eq(CapperFlagPriority(flag("t1", 0)), 0, "teammate partition = 0")

-- Unknown map (no label / no partition data): filters are skipped, neutral preference holds.
Context.FlagLabel = {}
Context.FlagOwner = {}
eq(CapperFlagPriority(flag("u1", 0)), 5.0, "unknown map: neutral still 5.0")
eq(CapperFlagPriority(flag("u2", "b")), 1.0, "unknown map: enemy-held still 1.0")

-- AnyCapperTarget: gates the capper trickle on CapperFlagPriority itself, not a plain global
-- neutral-flag count. A neutral flag sitting entirely in a teammate's partition must NOT be
-- seen as a valid capper target (CapperFlagPriority returns 0 for it), even though a naive
-- "any neutral flag exists" count would say yes -- that mismatch used to spawn a capper with
-- nowhere to go (GetFlagToCapture returns nil, so it never received a CaptureFlag order at all).
Context.FlagLabel = { theirs = { sector = "CONTESTED" } }
Context.FlagOwner = { theirs = { mine = false } }
BotApi.Scene.Flags = { flag("theirs", 0) }
eq(AnyCapperTarget(), false, "neutral flag in teammate's lane alone: no capper target")

Context.FlagLabel = { theirs = { sector = "CONTESTED" }, mine1 = { sector = "CONTESTED" } }
Context.FlagOwner = { theirs = { mine = false }, mine1 = { mine = true } }
BotApi.Scene.Flags = { flag("theirs", 0), flag("mine1", 0) }
eq(AnyCapperTarget(), true, "neutral flag in our own lane: capper target exists")
print("AnyCapperTarget OK")

-- GetCapperUnit: a single-soldier riflemans2(<army>) for a known faction.
Purchases = { { Units = { usa = { { unit = "riflemans(usa)", class = UnitClass.Infantry, line = true } } } } }
BotApi.Instance.army = "usa"
local cu = GetCapperUnit()
eq(cu.unit, "riflemans2(usa)", "capper unit is the single-man riflemans2 for the army")
eq(cu.class, UnitClass.Infantry, "capper unit is infantry")

-- Unknown faction (no roster): falls back to a line squad rather than an unverified name.
BotApi.Instance.army = "no_such_army"
local fb = GetCapperUnit()
eq(fb, nil, "unknown army with no line roster falls back (nil here, no usable line unit)")

-- FlagNeutralByName: true only while the named flag is neutral.
BotApi.Instance.team = "a"; BotApi.Instance.enemyTeam = "b"
BotApi.Scene.Flags = { flag("n", 0), flag("mine", "a"), flag("foe", "b") }
eq(FlagNeutralByName("n"), true, "neutral flag -> true")
eq(FlagNeutralByName("mine"), false, "our flag -> false")
eq(FlagNeutralByName("foe"), false, "enemy flag -> false")
eq(FlagNeutralByName("missing"), false, "absent flag -> false")
print("FlagNeutralByName OK")

-- Capper stays committed to its in-progress flag and does not switch mid-cap.
local routed = nil
BotApi.Commands.CaptureFlag = function(_, squad, name) routed = name end
Context.SquadGroup = {}; Context.AirborneSquads = {}; Context.Groups = {}
Context.FieldUnits = {}
Context.Cappers = { [1] = true }
Context.CapperTarget = { [1] = "cur" }
Context.FlagLabel = { cur = { sector = "CONTESTED" }, other = { sector = "CONTESTED" } }
Context.FlagOwner = { cur = { mine = true }, other = { mine = true } }
-- Both neutral and in-lane (equal priority); the capper must keep "cur" while it is neutral.
BotApi.Scene.Flags = { flag("cur", 0), flag("other", 0) }
routed = nil; CaptureFlag(1)
eq(routed, "cur", "capper sticks to its current flag while still neutral")

-- Once "cur" is captured (ours), the capper re-picks the remaining neutral flag.
BotApi.Scene.Flags = { flag("cur", "a"), flag("other", 0) }
routed = nil; CaptureFlag(1)
eq(routed, "other", "capper moves on only after the current flag is capped")
eq(Context.CapperTarget[1], "other", "capper target updates on re-pick")
print("capper stick OK")

print("capper OK")
