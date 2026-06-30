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

print("capper OK")
