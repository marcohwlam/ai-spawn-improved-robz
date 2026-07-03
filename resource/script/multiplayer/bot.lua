require([[/script/multiplayer/bot.data]])
require([[/script/multiplayer/flag_sectors]])

-- Engine/API scope note: BotApi.Scene.Squads and BotApi.Scene.Flags are THIS bot's own view --
-- Squads is every squad this player (bot) currently controls (not the whole match), and Flags
-- is the full flag set with each flag's occupant/team-relative state. Each AI-controlled player
-- in a match runs its own instance of this script, so there is no cross-bot or cross-team read
-- here: BotApi.Commands:CaptureFlag/Spawn only ever act on this player's own units. This matters
-- for the catch-all order loop at the bottom of OnGameQuant (squads with no SquadTimers entry,
-- e.g. the pre-placed starting garrison that never went through AttemptSpawn/OnGameSpawn) --
-- it is safe to blanket-order everything in BotApi.Scene.Squads precisely because that set is
-- already scoped to this bot's own units.
Context = {
	Purchase = nil,
	SpawnInfo = nil,
	SquadTimers = {},
	FieldUnits = {},  -- squadId -> unit entry, tracks live units we spawned
	SpawnQueue = {},  -- FIFO descriptors for successful Spawn() calls; consumed by OnGameSpawn
	SpawnLockQuant = -1, -- Context.MatchQuants value of the last claimed spawn slot this tick
	SpawnFlags = {
		isAirborne = false,
		isRare = false,
	},
	Cappers = {},      -- squadId -> true, cheap line units sent to grab neutral flags
	CapperTarget = {}, -- squadId -> flag name the capper is committed to until it is capped or lost
	LastWaveTime = 0,     -- Elapsed() at last wave start
	WaveRemaining = 0, -- units left to attempt in the current wave (0 = idle)
	WaveFails = 0,     -- consecutive failed Spawns this wave (MP-spent detector)
	WaveCooldown = 0,  -- quant countdown between spawns within a wave
	LastNeutralTime = 0,  -- Elapsed() at last neutral-capper trickle
	LastBackfillTime = 0, -- Elapsed() at last idle backfill
	LastDefenderTime = 0, -- Elapsed() at last MG defender trickle
	LastArtyTime = 0,     -- Elapsed() at last artillery defender trickle
	LastDeepStrikeTime = 0, -- Elapsed() at last airborne deep-strike drop
	AirborneSquads = {},    -- squadId -> true, elite airborne squads sent at enemy bases
	LastOfficerTime = 0,  -- Elapsed() at last officer keep-alive
	LastAtRifleTime = 0,  -- Elapsed() at last AT-rifle keep-alive
	LastAssaultGunTime = 0, -- Elapsed() at last assault-gun escort keep-alive
	LastSupportVehicleTime = 0, -- Elapsed() at last support-vehicle keep-alive
	RatioCount = 0,    -- ratio (non-aux) units spawned since the last aux batch
	Groups = {},        -- array of at most 2 live groups
	SquadGroup = {},    -- squadId -> index into Context.Groups
	FillGroup = nil,    -- index of the group currently being filled (set per spawn)
	AuxOwed = 0,       -- aux units still to inject in the current batch
	MatchQuants = 0,   -- quant ticks since match start (elapsed-time estimate)
	StartTime = nil,   -- os.time() at match start; set in OnGameStart
	GameClock = 0,     -- real game-seconds since match start (AdvanceClock accumulates this)
	LastWall = nil,    -- os.time() at the last Quant tick
	FailCooldown = {}, -- unit.unit -> Elapsed() seconds of last FAILED spawn (skip a while)
	PrevOwned = {},    -- flag name -> true if we owned it last tick
	LostStamp = {},    -- flag name -> Elapsed() seconds when we lost it (recapture priority)
	CapturedStamp = {}, -- flag name -> Elapsed() seconds when we captured it (settle grace)
	FlagLabel = {},    -- flag name -> {sector, rank, axis, x, y}; set by LabelFlags at start
	FlagBases = nil,   -- the matched map's base coords, or nil on an unrecognized map
	FlagOwner = {},    -- flag name -> {band, shared, mine, lat}; set by PartitionFlags at start
}

-- Wave spawning. The engine accepts at most ~1 Spawn per quant tick, so a wave
-- must be SPREAD across quants, not dumped in one tick (doing so wasted MP: one
-- unit landed and the rest were rejected, leaving 3000+ MP unspent at game end).
-- Each wave attempts up to phase.budget units, one every WaveSpawnSpacing quants,
-- and ends early only after MaxWaveFails spawns in a row fail (= truly out of MP).
local WaveIntervalSec     = 90   -- seconds between wave starts
local MinWaveIntervalSec  = 15   -- floor: never faster than ~15s even when far behind
local WaveSpawnSpacing = 7      -- quants between spawns inside a wave (~0.1s)
local MaxWaveFails    = 6       -- consecutive failed Spawns => treat MP as spent, end wave

-- Neutral-flag capper trickle: every NeutralInterval quants, if any flag is
-- neutral, spawn one cheap single soldier ordered to grab a neutral flag.
local NeutralIntervalSec  = 12   -- seconds between capper checks (longer cooldown: cappers trickle, not stream)
local CapperCap       = 6       -- max live single-soldier cappers (prevents stacking)
-- Cappers re-pick their target far faster than the standard 3-minute rotation so a capper
-- rolls on to the next neutral flag right after taking one, instead of idling on it.
local CapperRotationPeriod = 15 * 1000 -- ms between capper target re-picks
-- Distance falloff (world units, same scale as ArtyReach) applied to capper target choice:
-- a flag this far from our nearest owned ground has its priority halved. Without this, a
-- capper is equally likely to be sent across the whole lane as to the flag next door; the
-- far pick dies to opportunistic fire en route far more often, so that flag never finishes
-- capping while a safer, closer one sits neutral and unpicked. Distance only narrows the
-- choice among same-tier candidates -- it never promotes a farther enemy-held flag over a
-- closer neutral one by more than the existing 5:1 base-weight gap allows.
local CapperNearRange = 2500
local GroupHomeGraceSec = 240 -- first N seconds: groups ignore OWN-sector (home) flags and push forward
local GroupTargetStuckSec = 480 -- if a group can't take its target within this long, force a re-pick
-- A flag's occupant flipping to our team is the only capture signal the engine exposes (no
-- progress %, no "still contesting" flag) -- it is NOT proof the capture is secure. Without
-- this grace period, a group/capper that just took a flag saw it as no longer a valid target
-- (FlagTier/FlagAttackable/FlagNeutralByName all treat an owned flag as done) and immediately
-- moved on the same tick, sometimes before the position was defended -- letting the enemy
-- recontest an undefended, barely-won flag. During this window a just-captured flag still
-- counts as the group/capper's objective (hold it), instead of the next target.
local CaptureSettleSec = 30

-- When a Spawn fails (usually the picked unit is unaffordable right now), bench
-- that unit for FailCooldownSec seconds so the picker falls through to a cheaper tier
-- instead of hammering the same too-expensive unit until MaxWaveFails ends the wave.
local FailCooldownSec     = 10   -- seconds bench after a failed spawn

-- Between waves the field still loses units; backfill trickles one spawn every
-- BackfillInterval quants while idle to keep the composition near its ratio.
-- A quiet window after each wave start keeps backfill from merging into the wave
-- and reading as one continuous infantry stream.
local BackfillIntervalSec = 30   -- seconds between idle backfill spawns
local BackfillQuietSec    = 30   -- seconds after a wave start before idle backfill may resume

-- Between-wave defensive trickle: a small, capped number of mobile MG teams (mgs2)
-- sent to dig in on owned flags. Only fires while idle and only when we hold ground.
local DefenderIntervalSec = 20   -- seconds between defender checks
local DefenderCap      = 3       -- max live MG teams the bot keeps fielded
local ArtyIntervalSec  = 45      -- seconds between artillery trickle checks (rarer than MG)
-- max live artillery pieces the bot keeps fielded, shared across every arty subtype (field/
-- heavy/rocket) a faction has. At 1, the first subtype to unlock and win GetArtyUnit's
-- priority-weighted pick (usually the cheapest/earliest, e.g. wespe_ss at unlock=900) fills
-- the only slot and, as long as it survives, permanently locks out every other subtype for
-- the rest of the match -- e.g. ger_ss's sdkfz4_ss rocket halftrack (unlock=1200, lowest
-- priority of the three) would essentially never get a turn. 2 gives a second subtype room
-- to appear once its own unlock passes, without turning artillery into a real force pillar.
local ArtyCap          = 2       -- max live artillery pieces the bot keeps fielded
local DeepStrikePct        = 0.65   -- trigger deep-strike when enemy holds > this share of all flags
local DeepStrikeIntervalSec = 180   -- seconds between airborne drops (frontline-equivalent of c(900) x 0.2)
local DeepStrikeCap        = 2      -- max live airborne squads kept fielded
-- Firing reach per artillery subtype, in flag_sectors.lua world units (reach = range x 10,
-- see the 2026-06-29 placement design). Used to keep a piece on the REARMOST owned flag
-- from which an enemy/contested target is already in range, so it never over-runs forward.
local ArtyReach        = { rocket = 2200, field = 3000, heavy = 4000 }
-- A piece never sits closer than this to its nearest target: the safe-band lower bound.
-- A flag qualifies as a firing position only when its nearest target distance is in
-- [ArtySafeMin, reach]. No qualifying flag => the piece stays parked at base, unexposed.
local ArtySafeMin      = 1500    -- world units; standoff floor from the nearest enemy fire

-- Officer keep-alive: after OfficerUnlock seconds, keep up to OfficerCap officers parked
-- at the spawn (no capture order) -- they hold the unit cap and must not die at the front.
local OfficerUnlock   = 600     -- seconds before officers become available (~10 min)
local OfficerIntervalSec  = 30   -- seconds between officer checks
local OfficerCap      = 1       -- max live officers

-- AT-rifle keep-alive: from mid phase on, keep one AT rifle on the field (anti half-track).
local AtRifleIntervalSec  = 20   -- seconds between AT-rifle keep-alive checks
local AtRifleCap      = 1       -- max live AT rifles kept

-- Assault-gun escort keep-alive: units tagged assault=true (stuh42, brummbar, ...) are
-- close-support gun-howitzers, not backline artillery -- they escort a group and follow its
-- target, same shape as the AT-rifle keep-alive above, instead of parking at a rear
-- safe-band flag via ArtilleryTargetFlag like wespe/hummel/sdkfz4.
local AssaultGunIntervalSec = 40   -- seconds between assault-gun keep-alive checks
local AssaultGunCap    = 1       -- max live assault guns kept

-- Support-vehicle keep-alive: units tagged support=true (e.g. the 75mm gun halftracks) get
-- their own guaranteed slot, mirroring the AT-rifle keep-alive shape, instead of competing
-- for AuxPerCycle picks in the crowded generic aux pool (which also holds every faction's
-- MG/AT/sniper/flame variants -- ger alone has 7 duplicate MG entries in there). Attaches to
-- a group as an escort (aux member, does not fill the combat cap), same as the AT rifle.
local SupportVehicleIntervalSec = 120  -- seconds between support-vehicle keep-alive checks
local SupportVehicleCap    = 1       -- max live support vehicles kept

local PAUSE_CLAMP = 2  -- seconds; an inter-quant os.time gap larger than this is a pause/hitch, skipped


-- Match elapsed seconds: a wall-clock accumulator advanced only on Quant ticks (see AdvanceClock),
-- so it tracks real game-seconds and is pause-immune (frozen while the sim is paused).
function Elapsed()
	return Context.GameClock
end

-- Accumulate real seconds between consecutive Quant events. A gap > PAUSE_CLAMP (pause / multi-second
-- hitch) or a backward clock step is skipped so the clock never jumps.
function AdvanceClock()
	local now = os.time()
	if Context.LastWall then
		local d = now - Context.LastWall
		if d >= 0 and d <= PAUSE_CLAMP then
			Context.GameClock = Context.GameClock + d
		end
	end
	Context.LastWall = now
end

local MainGroupSize = 5   -- main prong member count (fallback; per-phase mainGroup overrides)
local SubGroupSize  = 3   -- sub prong member count  (fallback; per-phase subGroup overrides)
local MaxGroups = 2       -- main + sub prongs on adjacent flags

-- Hard ceiling on this bot's OWN live squads (combat fill). The engine is 32-bit (~2GB);
-- on team games every AI bot runs this script, so per-bot count multiplies. Aux counts 0.5
-- (see OwnedSquadCount), so 24 is roughly 24 combat or up to ~32-40 mixed squads. Sized for
-- 2v2 (<=4 bots): ~96 weighted / ~130-160 real squads, under the ~200-squad level that OOM'd
-- the 32-bit engine. Lower this if playing larger team games. Tune per typical match size.
local MaxLiveSquads = 24

-- Half-width (normalized lateral units [0,1]) of the SHARED band around each internal
-- teammate-band boundary. Flags within this margin belong to both teammates on purpose;
-- narrower = cleaner split, wider = more overlap/coverage. Tunable.
local PartSharedHalfWidth = 0.15

-- Composition is driven by a core infantry : tank ratio. Auxiliary units do not
-- count toward the ratio; they are injected up to a cap and filtered by trigger.
local Ratio      = 4    -- target core infantry per tank (4:1)
-- After each full ratio cycle (sum of the phase's target weights), inject this many
-- auxiliary units (AT / sniper / flame / MG). Aux never counts toward the ratio.
local AuxPerCycle = 2

-- Role assignment. Defender classes hold captured flags; everything else pushes
-- enemy/neutral flags. BotApi has no "hold position" order, so "defend" means the
-- squad is routed to an owned flag and the engine fights off attackers there.
local DefenderClasses = {
	[UnitClass.ATInfantry]    = true,  -- AT teams anchor the line
	[UnitClass.ATTank]        = true,  -- tank destroyers overwatch
	[UnitClass.AATank]        = true,  -- AA covers the rear
	[UnitClass.ArtilleryTank] = true,  -- SPGs sit back
	[UnitClass.Sniper]        = true,
	[UnitClass.Officer]       = true,
	[UnitClass.MG]            = true,  -- MG teams dig in on owned flags
}

local PIter = {}
PIter.__index = PIter

function PIter:new(data)
	local obj = { idx = nil, rpt = nil, purchases = data }
	self.nextIndex(obj)
	return setmetatable(obj, self)
end

function PIter:current()
	if self.idx then return self.purchases[self.idx].Units end
end

function PIter:nextIndex()
	self.idx = next(self.purchases, self.idx)
	if self.idx then self.rpt = self.purchases[self.idx].Repeat
	else self.rpt = nil end
end

function PIter:moveNext()
	if not self.rpt or self.rpt == 0 then return end
	self.rpt = self.rpt - 1
	if self.rpt == 0 then self:nextIndex() end
end

function PIter:advanceGroup()
	self.idx = next(self.purchases, self.idx)
	if not self.idx then self.idx = next(self.purchases) end
	self.rpt = self.purchases[self.idx].Repeat
end

-- Weighted-random pick. NOTE: the loop below can, in principle, run off the end without
-- matching (float rounding on `bound / total` can leave the last boundary a hair under 1.0
-- while rnd lands in that sliver) -- with a plain `for` returning nothing in that branch, this
-- would silently hand back nil even though total > 0 and a valid item existed. Every caller
-- (capper/flag targeting, unit picks) treats nil as "no candidate" and drops the order/spawn
-- entirely, so falling off the end must never happen: always return the last item as a fallback.
function GetRandomItem(items, getRate)
	local item_rates = {}
	local total = 0
	for i, item in pairs(items) do
		local rate = getRate(item)
		total = total + rate
		table.insert(item_rates, {i = item, r = rate})
	end
	if total == 0 then return nil end
	local rnd = math.random()
	local bound = 0.0
	for j, item_rate in pairs(item_rates) do
		bound = bound + item_rate.r
		if rnd < bound / total then return item_rate.i end
	end
	return item_rates[#item_rates].i
end

function IsCapturedFlag(flag) return flag.occupant == BotApi.Instance.team end
function IsEnemyFlag(flag)    return flag.occupant == BotApi.Instance.enemyTeam end
function IsNeutralFlag(flag)
	return flag.occupant ~= BotApi.Instance.team
	   and flag.occupant ~= BotApi.Instance.enemyTeam
end

-- True if the named flag exists and is currently neutral (capture in progress, not yet
-- ours and not taken by the enemy). Used to keep a capper committed to its flag.
function FlagNeutralByName(name)
	for _, f in pairs(BotApi.Scene.Flags) do
		if f.name == name then return IsNeutralFlag(f) end
	end
	return false
end

function GetFlagPriority(flag)
	if     IsCapturedFlag(flag) then return FlagPriority.Captured
	elseif IsEnemyFlag(flag)    then return FlagPriority.Enemy
	else                             return FlagPriority.Neutral
	end
end

-- Defenders weight owned flags highest, but still drift forward if the bot holds
-- none so they never sit idle.
function DefenderFlagPriority(flag)
	if     IsCapturedFlag(flag) then return 3.0
	elseif IsNeutralFlag(flag)  then return 1.0
	else                             return 0.5
	end
end

-- Distance to the nearest enemy-held or contested flag from (x, y), or nil if there are
-- no targets or no coords. The firing-position test below reads this distance directly.
function ArtyNearestTarget(x, y)
	if not x or not y then return nil end
	local best = nil
	for _, f in pairs(BotApi.Scene.Flags) do
		local lab = Context.FlagLabel[f.name]
		local isTarget = IsEnemyFlag(f) or (lab and lab.sector == "CONTESTED")
		if isTarget and lab and lab.x and lab.y then
			local dx, dy = lab.x - x, lab.y - y
			local d = math.sqrt(dx * dx + dy * dy)
			if not best or d < best then best = d end
		end
	end
	return best
end

-- Score an OWNED flag as an artillery firing position. A flag qualifies only when its
-- nearest target sits inside the safe band [ArtySafeMin, reach]: far enough that the
-- piece is not overrun by enemy fire, near enough to actually hit. Among qualifying flags
-- the rearmost (lowest team-axis) scores highest, so a piece sits as far back as it can
-- while still reaching a target. A non-qualifying flag scores 0 -- the router then parks
-- the piece at base rather than sending it somewhere too exposed or out of range.
function ArtilleryFlagPriority(flag, entry)
	if not IsCapturedFlag(flag) then return 0 end
	local label = Context.FlagLabel[flag.name]
	if not label then return 0 end
	local sub = entry and entry.arty
	local reach = ArtyReach[sub] or ArtyReach.field
	local d = ArtyNearestTarget(label.x, label.y)
	if not d or d < ArtySafeMin or d > reach then return 0 end
	return 3.0 - (label.axis or 0.5)
end

-- The owned flag an artillery piece should hold, or nil to stay parked at base. Picks the
-- highest-scoring (rearmost qualifying) flag deterministically; ties break toward the
-- first scanned, which is good enough since equal scores mean equal safety.
function ArtilleryTargetFlag(entry)
	local best, bestK = nil, 0
	for _, f in pairs(BotApi.Scene.Flags) do
		local k = ArtilleryFlagPriority(f, entry)
		if k > bestK then best, bestK = f.name, k end
	end
	return best
end

-- The flag an airborne deep-strike squad should attack: the FURTHEST enemy-held flag in
-- the enemy base sector (max team-axis = deepest in enemy territory; tiebreak by name so
-- teammates agree). As each base falls it stops being enemy-held, so successive calls roll
-- inward through the remaining bases. When no enemy base remains, fold into the main group
-- target (Context.Groups[1]); nil if there is nothing to attack.
function DeepStrikeTarget()
	local best, bestAxis
	for i, flag in pairs(BotApi.Scene.Flags) do
		local label = Context.FlagLabel[flag.name]
		if label and label.sector == "ENEMY" and IsEnemyFlag(flag) then
			local axis = label.axis or 0.5
			if not best or axis > bestAxis or (axis == bestAxis and flag.name < best) then
				best, bestAxis = flag.name, axis
			end
		end
	end
	if best then return best end
	-- Never fall back to a home-sector flag: the main group may legitimately be
	-- recapturing an OWN flag post-grace-period, but paras dropped there would land
	-- in our own territory instead of contesting the enemy.
	local fallback = Context.Groups[1] and Context.Groups[1].target
	if fallback then
		local label = Context.FlagLabel[fallback]
		if label and label.sector == "OWN" then return nil end
	end
	return fallback
end

function IsDefender(squad)
	local entry = Context.FieldUnits[squad]
	return entry ~= nil and DefenderClasses[entry.class] == true
end

function GetFlagToCapture(flagPoints, getPriority)
	-- consider every flag (stock-game behavior); the frontlines name filter was
	-- mis-routing squads and stalling them at the spawn point
	local flags = {}
	for i, flag in pairs(flagPoints) do
		table.insert(flags, {name = flag.name, k = getPriority(flag)})
	end
	return GetRandomItem(flags, function(f) return f.k end)
end

-- Cappers grab uncontested ground inside this bot's own lane: neutral flags first,
-- then in-lane enemy-held flags. Two hard exclusions (weight 0 = never picked):
--   * the enemy home sector -- cheap single units must not walk into the enemy base.
--   * a teammate's partition -- each bot's cappers stay in their own sector.
-- A flag we already own also returns 0 so a capper moves on to the next target after
-- a capture instead of sitting on the flag it just took.
function CapperFlagPriority(flag)
	local label = Context.FlagLabel[flag.name]
	if label and label.sector == "ENEMY" then return 0 end
	local owner = Context.FlagOwner[flag.name]
	if owner and not owner.mine then return 0 end
	local base
	if     IsNeutralFlag(flag)  then base = 5.0
	elseif IsEnemyFlag(flag)    then base = 1.0
	else                             return 0
	end
	-- Favor the nearest candidate flag to our own ground (see CapperNearRange comment):
	-- skip the discount when position data is unavailable (unit-test flags, or a map
	-- with no flag_sectors.lua coords) so the base weight is unaffected.
	if label and label.x then
		local d = NearestOwnedDist(label)
		if d then
			local r2 = CapperNearRange * CapperNearRange
			base = base * r2 / (r2 + d)
		end
	end
	return base
end

-- True if some flag currently scores > 0 under CapperFlagPriority, i.e. a capper spawned
-- right now would actually have somewhere to go. Gating the trickle on this (instead of a
-- plain global neutral-flag count, which the trickle used to use) matters in a partitioned
-- team game: a neutral flag can exist in a teammate's lane while THIS bot's own lane has none,
-- so "a neutral flag exists somewhere" does not imply a capper has a legal target. Spawning on
-- that mismatch produced a capper with no CaptureFlag order at all (GetFlagToCapture returns
-- nil, CaptureFlag's `if flag then` just skips the order) -- one of the "capper stuck at base"
-- symptoms, distinct from the SpawnQueue FIFO desync fixed earlier.
function AnyCapperTarget()
	for _, flag in pairs(BotApi.Scene.Flags) do
		if CapperFlagPriority(flag) > 0 then return true end
	end
	return false
end

-- Pick a cheap line-infantry unit from the current faction roster, or nil.
function GetLineUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local lines = {}
	for i, t in pairs(roster) do
		if t.line and t.class == UnitClass.Infantry then table.insert(lines, t) end
	end
	if #lines == 0 then return nil end
	return GetRandomItem(lines, function(t) return t.priority end)
end

-- The capper unit: a single soldier, not a full squad. RobZ exposes a one-man rifleman
-- as "riflemans2(<army>)" for every faction the bot fields, so a capper is one body that
-- grabs an undefended flag without burning a whole squad's manpower. Falls back to a line
-- squad only on an unknown faction (no roster), where the single-man name is unverified.
function GetCapperUnit()
	local army = BotApi.Instance.army
	local roster = Purchases[1] and Purchases[1].Units[army]
	if not roster then return GetLineUnit() end
	return { class = UnitClass.Infantry, unit = "riflemans2(" .. army .. ")", line = true, inf = "rifle" }
end

-- The defender MG: use the cheapest MG only (the basic mgs2 team). Falls back to any
-- MG if a faction has no mgs2.
function GetMGUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	for i, t in pairs(roster) do
		if t.class == UnitClass.MG and string.find(t.unit, "mgs2", 1, true) then return t end
	end
	for i, t in pairs(roster) do
		if t.class == UnitClass.MG then return t end
	end
	return nil
end

-- Flags we currently own (something worth defending).
function HeldFlagCount()
	local n = 0
	for i, flag in pairs(BotApi.Scene.Flags) do
		if IsCapturedFlag(flag) then n = n + 1 end
	end
	return n
end

-- Live MG teams we have fielded (the defender cap).
function LiveMGCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.MG then n = n + 1 end
	end
	return n
end

-- An artillery unit from the current faction roster, drawn by priority, or nil. Filters out
-- subtypes not yet unlocked (GetUnitToSpawn's pool does this for every other unit; the arty
-- trickle calls this directly instead, so it must apply the same check itself) and any
-- subtype already fielded live, so with ArtyCap > 1 the extra slot(s) go toward variety
-- instead of a second copy of whichever subtype won the last pick.
function GetArtyUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local elapsed = Elapsed()
	local live = {}
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.ArtilleryTank then live[entry.unit] = true end
	end
	local arty = {}
	for i, t in pairs(roster) do
		if t.class == UnitClass.ArtilleryTank and not t.assault -- assault guns escort the
		-- main group instead (see GetAssaultGunUnit); they are not backline artillery.
		and (t.unlock == nil or elapsed >= t.unlock)
		and not live[t.unit] then
			table.insert(arty, t)
		end
	end
	if #arty == 0 then return nil end
	return GetRandomItem(arty, function(t) return t.priority end)
end

-- Live backline artillery pieces we have fielded (the artillery cap). Excludes assault=true
-- guns (stuh42, brummbar, ...) -- those escort a group under their own separate cap
-- (AssaultGunCap), not this backline one.
function LiveArtyCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.ArtilleryTank and not entry.assault then n = n + 1 end
	end
	return n
end

-- An airborne (paradrop) unit from the current faction roster, drawn by priority, or nil.
function GetAirborneUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local drops = {}
	for i, t in pairs(roster) do
		if t.class == UnitClass.Airborne then table.insert(drops, t) end
	end
	if #drops == 0 then return nil end
	return GetRandomItem(drops, function(t) return t.priority end)
end

-- Live airborne squads we have fielded (the deep-strike cap).
function LiveAirborneCount()
	local n = 0
	for squadId in pairs(Context.AirborneSquads) do n = n + 1 end
	return n
end

-- An officer unit from the current faction roster (parked at spawn for the cap), or nil.
function GetOfficerUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	for i, t in pairs(roster) do
		if t.class == UnitClass.Officer then return t end
	end
	return nil
end

-- Live officers we have fielded (the officer cap).
function OfficerOnField()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.Officer then n = n + 1 end
	end
	return n
end

-- An AT-rifle team from the current faction roster (name contains "at_rifle"), or nil.
function GetAtRifleUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	for i, t in pairs(roster) do
		if t.class == UnitClass.ATInfantry and string.find(t.unit, "at_rifle", 1, true) then
			return t
		end
	end
	return nil
end

-- Live AT-rifle teams we have fielded.
function AtRifleOnField()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.ATInfantry and string.find(entry.unit, "at_rifle", 1, true) then
			n = n + 1
		end
	end
	return n
end

-- An assault=true ArtilleryTank (close-support gun-howitzer: stuh42, brummbar, ...) from the
-- current faction roster, unlocked and drawn by priority, or nil. Mirrors GetArtyUnit's
-- unlock filtering, but pulls from the disjoint assault=true set instead of the backline set.
function GetAssaultGunUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local elapsed = Elapsed()
	local cands = {}
	for i, t in pairs(roster) do
		if t.class == UnitClass.ArtilleryTank and t.assault
		and (t.unlock == nil or elapsed >= t.unlock) then
			table.insert(cands, t)
		end
	end
	if #cands == 0 then return nil end
	return GetRandomItem(cands, function(t) return t.priority end)
end

-- Live assault guns we have fielded (the assault-gun cap).
function LiveAssaultGunCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.ArtilleryTank and entry.assault then n = n + 1 end
	end
	return n
end

-- A support=true Vehicle from the current faction roster, unlocked and drawn by priority, or
-- nil. Mirrors GetArtyUnit's unlock filtering (see that comment): the dedicated keep-alive
-- trickle calls this directly instead of going through GetUnitToSpawn's pool, so it must apply
-- the same unlockOk check itself.
function GetSupportVehicleUnit()
	local roster = Purchases[1] and Purchases[1].Units[BotApi.Instance.army]
	if not roster then return nil end
	local elapsed = Elapsed()
	local cands = {}
	for i, t in pairs(roster) do
		if t.class == UnitClass.Vehicle and t.support
		and (t.unlock == nil or elapsed >= t.unlock) then
			table.insert(cands, t)
		end
	end
	if #cands == 0 then return nil end
	return GetRandomItem(cands, function(t) return t.priority end)
end

-- Live support vehicles we have fielded (the support-vehicle cap).
function LiveSupportVehicleCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.Vehicle and entry.support then n = n + 1 end
	end
	return n
end

-- The engine accepts at most ~1 Spawn per quant tick (see the WaveSpawnSpacing comment
-- above). The wave/backfill, capper, officer, AT-rifle and deep-strike trickles are each
-- independent `if` blocks in OnGameQuant and can otherwise all fire the same tick; when two
-- Commands:Spawn calls land in one quant, the engine silently defers/reorders one of them,
-- desyncing the FIFO Context.SpawnQueue so a later OnGameSpawn event pops the WRONG
-- descriptor (e.g. a tank spawn consuming a capper's queue entry). That leaves the real
-- spawn with no group/role assignment -- it never gets ordered anywhere and sits at base.
-- These two functions serialize all spawn attempts to at most one claimed slot per quant.
function SpawnSlotFree()
	return Context.SpawnLockQuant ~= Context.MatchQuants
end

function ClaimSpawnSlot()
	Context.SpawnLockQuant = Context.MatchQuants
end

function LiveCapperCount()
	local n = 0
	for _ in pairs(Context.Cappers) do n = n + 1 end
	return n
end

-- Five-tier classification. Aux (AT, MG, sniper, officer, AA, artillery, flamer)
-- returns nil and never counts toward the ratio.
function TierOf(t)
	-- Support half-tracks (scout/utility variants tagged support=true in bot.data.lua) ride
	-- along as aux, same as MG/AT/officer -- they must never crowd out real light tanks in
	-- the "light" ratio slot.
	if t.support then return nil end
	-- mech=true (mounted/panzergrenadier-style Infantry, e.g. pzgren_mech(ger_ss)) is still
	-- infantry, not armor -- it must NOT share the "light" bucket with actual light tanks/
	-- vehicles. It used to: once a mech squad filled the field's light-tier count, DecideTier's
	-- deficit calculation saw "light" as satisfied and stopped picking that tier at all, so real
	-- light armor (pz2l, sdkfz222, np_sdkfz250_1, ...) went unpicked for the first 10+ minutes of
	-- a match even though it was unlocked and affordable the whole time. Falls through to the
	-- same rifle/smg classification as any other non-mech infantry.
	if t.class == UnitClass.Infantry and not t.flame then
		if t.inf == "smg" then return "smg"
		else return "rifle" end
	elseif t.class == UnitClass.HeavyTank then
		return "heavy"
	elseif t.class == UnitClass.Tank then
		if t.weight == "heavy" or t.weight == "sheavy" then return "heavy"
		elseif t.weight == "medium" then return "medium"
		else return "light" end
	elseif t.class == UnitClass.Vehicle then
		return "light"
	else
		return nil
	end
end

function GetFieldCounts()
	local c = { heavy = 0, medium = 0, light = 0, rifle = 0, smg = 0, aux = 0, total = 0 }
	for squadId, entry in pairs(Context.FieldUnits) do
		if not Context.Cappers[squadId] then
			c.total = c.total + 1
			local tier = TierOf(entry)
			if tier then c[tier] = c[tier] + 1 else c.aux = c.aux + 1 end
		end
	end
	return c
end

-- Combat member count: aux (AT/MG/sniper/etc.) ride along with a group but do NOT fill
-- its 5/3 cap, so only non-aux (ratio) members count toward "is the group full". Aux
-- members are tracked in group.auxMembers and excluded here.
function GroupMemberCount(group)
	local n = 0
	local aux = group.auxMembers
	for sq in pairs(group.members) do
		if not (aux and aux[sq]) then n = n + 1 end
	end
	return n
end

function GroupEliteCount(group)
	local n = 0
	for squadId in pairs(group.members) do
		local e = Context.FieldUnits[squadId]
		if e and e.elite then n = n + 1 end
	end
	return n
end

-- Tag for per-bot attribution in shared game.log (multiple AI bots print to one file).
function PidTag() return " pid=" .. tostring(BotApi.Instance.playerId) end

-- Sum of live group sizes: the standing-army size the ratio targets are scaled to.
function TotalGroupCapacity()
	local n = 0
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g then n = n + g.size end
	end
	return n
end

-- How many armor units the standing army should hold for this phase, scaled from
-- the phase's armor share to the total group capacity.
function ArmorTargetCount(phase)
	local armorTotal = (phase.targets.heavy or 0) + (phase.targets.medium or 0)
	local cap = TotalGroupCapacity()
	if cap == 0 then return 0 end
	return math.floor(armorTotal / CycleSize(phase) * cap + 0.5)
end

-- Distribute the phase's armor quota (heavy + medium target weights) across the live
-- groups by the largest-remainder method on group size, writing g.armorLead. Each
-- prong receives armor support rather than the main group taking all of it.
function ApportionArmor(phase)
	local armorTotal = (phase.targets.heavy or 0) + (phase.targets.medium or 0)
	local groups, cap = {}, 0
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g then groups[#groups + 1] = g; cap = cap + g.size end
	end
	if cap == 0 then return end
	local fracs, assigned = {}, 0
	for idx = 1, #groups do
		local exact = armorTotal * groups[idx].size / cap
		local f = math.floor(exact)
		groups[idx].armorLead = f
		fracs[idx] = exact - f
		assigned = assigned + f
	end
	local remainder = armorTotal - assigned
	while remainder > 0 do
		local bestIdx, bestFrac = nil, -1
		for idx = 1, #groups do
			if fracs[idx] > bestFrac then bestFrac = fracs[idx]; bestIdx = idx end
		end
		groups[bestIdx].armorLead = groups[bestIdx].armorLead + 1
		fracs[bestIdx] = -1
		remainder = remainder - 1
	end
end

-- Create groups: the 1st whenever none exist; the 2nd only once the 1st is full.
function ManageGroups()
	local phase = CurrentPhase(Elapsed())
	if not Context.Groups[1] then
		local t = PickGroupTarget(nil)
		Context.Groups[1] = { members = {}, auxMembers = {}, size = phase.mainGroup or MainGroupSize, target = t, pending = 0,
			phase = phase.name, targetSince = Elapsed() }
		print("[AISPAWN] GROUP_NEW id=1 target=" .. tostring(t) .. PidTag())
	elseif MaxGroups >= 2 and not Context.Groups[2]
	   and GroupMemberCount(Context.Groups[1]) >= Context.Groups[1].size then
		local t = PickSubTarget(Context.Groups[1].target)
		Context.Groups[2] = { members = {}, auxMembers = {}, size = phase.subGroup or SubGroupSize, target = t, pending = 0,
			phase = phase.name }
		print("[AISPAWN] GROUP_NEW id=2 target=" .. tostring(t) .. PidTag())
	end
end

-- Re-issue the capture order to every live member of a group immediately, so a
-- target change takes effect without waiting for the OrderRotationPeriod timer.
function ReorderGroup(gi)
	local g = Context.Groups[gi]
	if not g then return end
	for squad in pairs(g.members) do
		if BotApi.Scene:IsSquadExists(squad) then
			CaptureFlag(squad)
		end
	end
end

-- The sub group's flag: the attackable objective nearest the main group's target
-- (by flag coords), excluding the main target. Falls back to the main target when
-- no other objective exists, so the sub never idles. nil when there is no main.
function PickSubTarget(mainTarget)
	if not mainTarget then return nil end
	local mainLabel = Context.FlagLabel[mainTarget]
	local best, bestKey
	for _, flag in pairs(BotApi.Scene.Flags) do
		local name = flag.name
		if name ~= mainTarget and FlagTier(name) ~= nil then
			local label = Context.FlagLabel[name]
			local key = 1e18
			if mainLabel and mainLabel.x and label and label.x then
				local dx, dy = label.x - mainLabel.x, label.y - mainLabel.y
				key = dx * dx + dy * dy
			end
			if not best or key < bestKey or (key == bestKey and name < best) then
				best, bestKey = name, key
			end
		end
	end
	return best or mainTarget
end

-- Refresh each group's target: if nil or the flag is gone, re-pick de-conflicted from the other.
function UpdateGroupTargets()
	local g1 = Context.Groups[1]
	local g2 = Context.Groups[2]
	if g1 then
		local other = g2 and g2.target
		local newT, stuck
		if not g1.target or not FlagAttackable(g1.target) then
			newT = PickGroupTarget(other)
		else
			local cand = PickGroupTarget(other)
			local ct = cand and FlagTier(cand)
			local gt = FlagTier(g1.target)
			if ct and gt and ct < gt then
				newT = cand
			elseif Elapsed() - (g1.targetSince or Elapsed()) > GroupTargetStuckSec then
				-- Still attackable and no better tier, but the group hasn't taken it within
				-- GroupTargetStuckSec: force a re-pick excluding both the stuck flag and the
				-- sub group's target, so escaping a stuck flag can't just hand group 1 group 2's
				-- own objective (the plain `other` exclude above is not in scope here).
				newT = PickGroupTarget(g1.target, other)
				stuck = true
			end
		end
		if newT and newT ~= g1.target then
			print("[AISPAWN] GROUP_TARGET id=1 target=" .. tostring(newT)
				.. " reason=" .. (stuck and "stuck" or (Context.LostStamp[newT] and "recapture" or "priority"))
				.. " tier=" .. tostring(Context.LastPickTier) .. PidTag())
			g1.target = newT
			g1.targetSince = Elapsed()
			ReorderGroup(1)
		end
	end
	if g2 then
		local mainT = g1 and g1.target
		local newT = PickSubTarget(mainT)
		if newT and newT ~= g2.target then
			print("[AISPAWN] GROUP_TARGET id=2 target=" .. tostring(newT)
				.. " reason=sub" .. PidTag())
			g2.target = newT
			ReorderGroup(2)
		end
	end
end

-- The first group not yet at size, or nil if all full. Counts pending (queued, not yet landed
-- via OnGameSpawn) fills alongside live members -- a wave drives multiple AttemptSpawn calls
-- across the quants before any of them resolve, so checking live members alone kept re-selecting
-- the same under-cap group on every one of those calls and let it massively overshoot g.size
-- (observed ballooning a 3-member sub group to 6-8 members in one wave) while a co-existing
-- group sat starved of that wave's budget. AttemptSpawn's own GROUP_FILL log line already
-- computes size this way (GroupMemberCount(g) + (g.pending or 0)) for display; this just applies
-- the same accounting to the fill decision itself.
function GroupToFill()
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g and GroupMemberCount(g) + (g.pending or 0) < g.size then return i end
	end
	return nil
end

-- Drop a group only when it has no live members AND no pending (queued) members, so a
-- freshly-filled group is never reaped before its deferred OnGameSpawn lands. Stable slots:
-- no reindexing, so SquadGroup indices and queued slot refs stay valid.
function PruneGroups()
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g and next(g.members) == nil then  -- raw emptiness: keep alive while ANY member (incl aux) lives
			if (g.pending or 0) == 0 then
				if g.seeded then print("[AISPAWN] GROUP_END id=" .. i .. PidTag()) end
				Context.Groups[i] = nil
			else
				-- pending should clear within ~1 quant once OnGameSpawn lands. If it lingers,
				-- a Spawn/OnGameSpawn pairing was lost at the engine level; age the slot out so
				-- it cannot orphan (and desync the queue) for the rest of the match.
				g.staleSince = g.staleSince or Elapsed()
				if Elapsed() - g.staleSince > 3 then
					print("[AISPAWN] GROUP_END id=" .. i .. " reason=stale_pending" .. PidTag())
					Context.Groups[i] = nil
				end
			end
		elseif g then
			g.staleSince = nil
		end
	end
end
-- Backward-compat alias: tests check this name; the old reindexing logic is gone.
CompactGroups = PruneGroups

function LiveSquadCount()
	local n = 0
	for _ in pairs(BotApi.Scene.Squads) do n = n + 1 end
	return n
end

-- Count this bot's own live squads (units we spawned and still track). This is the memory
-- footprint we can actually bound; LiveSquadCount() counts the whole scene and must not be
-- used for the cap. Aux units (TierOf == nil: MG, AT, sniper, officer, etc.) count as 0.5
-- since they have their own small caps and cost less headroom.
function OwnedSquadCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if TierOf(entry) == nil then n = n + 0.5 else n = n + 1 end
	end
	return n
end

function IsLosing()
	return FlagDeficit() > 0
end

-- How many more flags the enemy holds than we do (negative = we are ahead).
function FlagDeficit()
	local captured, enemy = 0, 0
	for i, flag in pairs(BotApi.Scene.Flags) do
		if IsCapturedFlag(flag) then captured = captured + 1 end
		if IsEnemyFlag(flag)    then enemy = enemy + 1 end
	end
	return enemy - captured
end

-- Share of all flags currently held by the enemy, in [0,1]. 0 when there are no flags.
function EnemyFlagPct()
	local enemy, total = 0, 0
	for i, flag in pairs(BotApi.Scene.Flags) do
		total = total + 1
		if IsEnemyFlag(flag) then enemy = enemy + 1 end
	end
	if total == 0 then return 0 end
	return enemy / total
end

-- Wave budget multiplier that scales with how badly we are losing on flags.
-- Even (or ahead) -> 1.0; each flag behind adds 0.25, capped so it cannot run away.
function LosingBudgetMult()
	local deficit = FlagDeficit()
	if deficit <= 0 then return 1.0 end
	return math.min(1.0 + 0.25 * deficit, 2.5)
end

-- Wave cadence: base gap scales up by the phase's waveMult (later phases wait longer so MP
-- banks for pricier units). The further behind on flags, the shorter the gap (each flag
-- deficit speeds it up), down to MinWaveInterval. Even/ahead -> full phase-scaled gap.
function WaveIntervalNow()
	local phase = CurrentPhase(Elapsed())
	local base = WaveIntervalSec * (phase.waveMult or 1.0)
	local deficit = FlagDeficit()
	if deficit <= 0 then return base end
	return math.max(MinWaveIntervalSec, math.floor(base / (1.0 + 0.25 * deficit)))
end

-- Live-squad ceiling for the current phase (grows +2 per phase). Falls back to the
-- MaxLiveSquads base if a phase omits squadCap.
function CurrentSquadCap()
	local phase = CurrentPhase(Elapsed())
	return phase.squadCap or MaxLiveSquads
end

-- A1 filter: which aux units may spawn right now.
function AuxEligible(t, enemyHasTanks)
	local c = t.class
	if c == UnitClass.ATInfantry or c == UnitClass.ATTank then
		return enemyHasTanks            -- AT only matters against enemy armor
	elseif c == UnitClass.MG then
		return not IsLosing()           -- MG holds ground; skip when retaking flags
	else
		return true                     -- sniper, officer, flamer, vehicle, AA, SPG
	end
end

-- Build a faction-resolved phase array from the global Phases template: apply this
-- faction's mid/late boundaries and (Japan) its late targets, keeping the shared
-- budget/waveMult/squadCap. Returns the global Phases table unchanged when the faction
-- has no entry. Pure: depends only on its argument and the module-level Phases/FactionPhases.
function ResolvePhases(army)
	local fp = FactionPhases and FactionPhases[army]
	if not fp then return Phases end
	return {
		{ name = "early", upto = fp.mid, targets = Phases[1].targets,
		  budget = Phases[1].budget, waveMult = Phases[1].waveMult, squadCap = Phases[1].squadCap,
		  mainGroup = Phases[1].mainGroup, subGroup = Phases[1].subGroup },
		{ name = "mid", upto = fp.late, targets = Phases[2].targets,
		  budget = Phases[2].budget, waveMult = Phases[2].waveMult, squadCap = Phases[2].squadCap,
		  mainGroup = Phases[2].mainGroup, subGroup = Phases[2].subGroup },
		{ name = "late", upto = 1000000000, targets = fp.lateTargets or Phases[3].targets,
		  budget = Phases[3].budget, waveMult = Phases[3].waveMult, squadCap = Phases[3].squadCap,
		  mainGroup = Phases[3].mainGroup, subGroup = Phases[3].subGroup },
	}
end

-- Pick the active phase for an elapsed time in seconds.
function CurrentPhase(elapsedSec)
	local phases = Context.Phases or Phases
	for i = 1, #phases do
		if elapsedSec < phases[i].upto then return phases[i] end
	end
	return phases[#phases]
end

-- Choose the tier whose share is furthest below its target, among phase-allowed tiers
-- that actually have a spawnable candidate. enemyHasTanks adds a small armor lean.
-- losing bumps the smg weight to 2. Pure: all inputs passed in, no BotApi/Context reads.
function DecideTier(phase, field, enemyHasTanks, tierEligible, losing)
	local targets = phase.targets
	local totalT = 0
	for tier, w in pairs(targets) do
		totalT = totalT + ((losing and tier == "smg") and 2 or w)
	end
	local totalF = 0
	for tier in pairs(targets) do totalF = totalF + (field[tier] or 0) end

	local best, bestDeficit = nil, -1e9
	for tier, w in pairs(targets) do
		local ew = (losing and tier == "smg") and 2 or w
		local targetShare = ew / totalT
		local actualShare = (totalF > 0) and ((field[tier] or 0) / totalF) or 0
		local deficit = targetShare - actualShare
		if enemyHasTanks and (tier == "medium" or tier == "heavy") then
			deficit = deficit + 0.15
		end
		if (tierEligible[tier]) and deficit > bestDeficit then
			best, bestDeficit = tier, deficit
		end
	end
	return best or "rifle"
end

-- Number of ratio units in one full composition cycle for a phase (sum of target weights).
function CycleSize(phase)
	local n = 0
	for _, w in pairs(phase.targets) do n = n + w end
	return n
end

function GetNextUnitToSpawn(purchase)
	for attempt = 1, #Purchases do
		local units = purchase:current()
		if units then
			local unit = GetUnitToSpawn(units[BotApi.Instance.army])
			if unit then
				purchase:moveNext()
				if unit.class == UnitClass.Airborne then Context.SpawnFlags.isAirborne = true end
				if unit.class == UnitClass.Rare     then Context.SpawnFlags.isRare = true end
				return unit
			end
		end
		purchase:advanceGroup()
	end
	return nil
end

function GetUnitToSpawn(units)
	if not units then return nil end

	local teamSize = BotApi.Instance.teamSize
	local income = BotApi.Commands:Income(BotApi.Instance.playerId)
	local enemyHasTanks = BotApi.Commands:EnemyHasTanks()
	local elapsed = Elapsed()
	local phase = CurrentPhase(elapsed)

	-- Resolve fill group for per-group field counts and elite cap.
	local g = Context.FillGroup and Context.Groups[Context.FillGroup]

	-- Build the eligible pool: affordable, unlocked, and within the phase composition targets.
	local pool = {}
	for i, unit in pairs(units) do
		local affordable = teamSize >= (unit.min_team or 0)
			and income >= (unit.min_income or -1)
		local unlockOk = (unit.unlock == nil) or (elapsed >= unit.unlock)
		local failed = Context.FailCooldown[unit.unit]
		local notRecentlyFailed = (failed == nil)
			or (Elapsed() - failed >= FailCooldownSec)
		local tier = TierOf(unit)
		local phaseOk = (unit.phase == nil) or (unit.phase == phase.name) -- per-unit phase lock
		-- Elite infantry only spawns in early. From mid on, tanks dominate the field and
		-- elite inf just feeds them, so ban elite outside early. In early, still cap at 1/group.
		local elitePhaseOk = (not unit.elite) or (phase.name == "early")
		local eliteCapOk = not (g and unit.elite and GroupEliteCount(g) >= 1)
		local eliteOk = elitePhaseOk and eliteCapOk
		if affordable and unlockOk and notRecentlyFailed and phaseOk and eliteOk then
			table.insert(pool, unit)
		end
	end
	if #pool == 0 then return nil end

	-- Army-wide composition: the tier ratio is enforced across the whole force, not
	-- per group, so splitting the force into prongs does not skew the ratio.
	local field = GetFieldCounts()
	local function collectAux()
		local out = {}
		for i, t in pairs(pool) do
			if TierOf(t) == nil and AuxEligible(t, enemyHasTanks) then
				if t.class ~= UnitClass.Airborne         -- airborne ONLY via the deep-strike trickle (late + losing gate)
				and not (t.class == UnitClass.Rare and Context.SpawnFlags.isRare)
				and t.class ~= UnitClass.Howitzrer
				and t.class ~= UnitClass.ArtilleryTank   -- SPGs disabled (poor bot AI use)
				and t.class ~= UnitClass.Officer         -- officers are parked by their own trickle
				and not (t.class == UnitClass.Vehicle and t.support) then -- support vehicles: own keep-alive trickle
					table.insert(out, t)
				end
			end
		end
		return out
	end
	-- Which tiers have a candidate in the pool right now?
	local tierEligible, byTier = {}, { heavy = {}, medium = {}, light = {}, rifle = {}, smg = {} }
	for i, t in pairs(pool) do
		local tier = TierOf(t)
		if tier then
			tierEligible[tier] = true
			table.insert(byTier[tier], t)
		end
	end

	-- Shared weighting: lean toward the strongest / most relevant pick within a tier.
	local function weightOf(t)
		local mul = 1.0
		if enemyHasTanks then
			if t.class == UnitClass.HeavyTank then mul = mul * 1.5
			elseif t.class == UnitClass.ATTank then mul = mul * 1.5
			elseif t.class == UnitClass.ATInfantry then mul = mul * 1.5 end
		end
		return t.priority * mul
	end

	-- Per-group armor lead, gated by the army-wide armor deficit. Front-loading leads
	-- with armor at the wave start but stops once the army meets its armor target, so
	-- surviving tanks across waves no longer crowd out infantry refills.
	if g and (g.armorLead or 0) > 0 then
		if (field.heavy + field.medium) < ArmorTargetCount(phase) then
			local lead = nil
			if #byTier.heavy > 0 then lead = "heavy"
			elseif #byTier.medium > 0 then lead = "medium" end
			if lead then
				return GetRandomItem(byTier[lead], weightOf)
			else
				g.armorLead = 0 -- no armor available; resume normal selection
			end
		else
			g.armorLead = 0 -- armor already at target; resume normal selection
		end
	end

	-- If aux is owed for this cycle, inject one now (skips the four-tier deficit pick).
	if Context.AuxOwed > 0 then
		local aux = collectAux()
		if #aux > 0 then
			return GetRandomItem(aux, function(t) return t.priority end)
		end
	end

	local tier = DecideTier(phase, field, enemyHasTanks, tierEligible, FlagDeficit() > 0)
	local cands = byTier[tier]
	if not cands or #cands == 0 then cands = pool end
	return GetRandomItem(cands, weightOf)
end

function UpdateUnitToSpawn(purchase)
	Context.SpawnInfo = GetNextUnitToSpawn(purchase)
end

-- The sorted, comma-joined set of current flag names. The engine exposes no map id, so
-- this set is the map fingerprint used to look a precomputed sector table up.
function FlagFingerprint()
	local names = {}
	for _, flag in pairs(BotApi.Scene.Flags) do
		names[#names + 1] = flag.name
	end
	table.sort(names)
	return table.concat(names, ",")
end

-- Extract the loaded map's base name from game.log text. The engine writes
-- `Starting "multi/<X>:<variant>"` at match start; the LAST such line names the current
-- map. Returns the token between `multi/` and the first `:` or `"`, or nil. Pure (no io).
function ParseMapName(text)
	if not text then return nil end
	local found
	for line in text:gmatch("[^\r\n]+") do
		local tok = line:match('Starting "multi/([^:"]+)')
		if tok then found = tok end
	end
	return found
end

local TAIL_BYTES = 65536
local MAP_TAIL_WIN = [[\Documents\my games\men of war - assault squad 2\log\game.log]]
local MAP_TAIL_NIX = [[/Documents/my games/men of war - assault squad 2/log/game.log]]

-- Read the last 64KB of a file (the current match's Starting line sits near the end).
-- If that tail has no Starting line and the file is bigger than the tail, re-read in full.
-- Returns the text, or nil on any failure. pcall-wrapped.
function TailRead(path)
	local ok, res = pcall(function()
		local f = io.open(path, "r")
		if not f then return nil end
		local size = f:seek("end")
		local from = size - TAIL_BYTES
		if from < 0 then from = 0 end
		f:seek("set", from)
		local text = f:read("*a")
		f:close()
		if text and from > 0 and not text:find('Starting "multi/', 1, true) then
			local g = io.open(path, "r")
			if g then text = g:read("*a"); g:close() end
		end
		return text
	end)
	return ok and res or nil
end

-- Resolve the loaded map name by reading game.log from env-derived candidate paths.
-- No hardcoded username; Proton is covered by USERPROFILE. First parse hit wins. nil if none.
function ReadMapName()
	if not (io and io.open and os and os.getenv) then return nil end
	local up = os.getenv("USERPROFILE")
	local home = os.getenv("HOME")
	local candidates = {}
	if up then
		candidates[#candidates + 1] = up .. MAP_TAIL_WIN
		candidates[#candidates + 1] = up .. [[\OneDrive]] .. MAP_TAIL_WIN
	end
	if home then candidates[#candidates + 1] = home .. MAP_TAIL_NIX end
	for _, path in ipairs(candidates) do
		local name = ParseMapName(TailRead(path))
		if name then return name end
	end
	return nil
end

-- Label every live flag OWN / CONTESTED / ENEMY plus a rank toward the enemy home,
-- from the precomputed Sectors table, oriented by this bot's team. Unknown maps fall
-- back to all-CONTESTED. Writes Context.FlagLabel and Context.FlagBases. Never errors.
function LabelFlags()
	Context.FlagLabel = {}
	Context.FlagBases = nil
	local fp = FlagFingerprint()
	local entry = Sectors and Context.MapName and Sectors[Context.MapName]
	local team = BotApi.Instance.team
	local pid = BotApi.Instance.playerId
	if not entry then
		for _, flag in pairs(BotApi.Scene.Flags) do
			Context.FlagLabel[flag.name] = { sector = "CONTESTED" }
		end
		print("[AISPAWN] SECTOR_FALLBACK map=" .. tostring(Context.MapName) .. " fp=" .. fp)
		return
	end
	Context.FlagBases = entry.bases
	-- Collect present flags with a team-oriented axis (team b sees the axis reversed).
	local present = {}
	for _, flag in pairs(BotApi.Scene.Flags) do
		local d = entry.flags[flag.name]
		if d then
			local myAxis = (team == "b") and (1 - d.axis) or d.axis
			present[#present + 1] = { name = flag.name, myAxis = myAxis, x = d.x, y = d.y,
				nb = d.nb, base = d.base }
		else
			Context.FlagLabel[flag.name] = { sector = "CONTESTED" } -- present but unmapped
		end
	end
	-- Rank by myAxis descending; rank 1 = closest to enemy home. Tie-break by name so the
	-- two teammates compute an identical ranking regardless of pairs() iteration order.
	table.sort(present, function(p, q)
		if p.myAxis ~= q.myAxis then return p.myAxis > q.myAxis end
		return p.name < q.name
	end)
	for rank, p in ipairs(present) do
		local sector = "CONTESTED"
		if p.base and p.base[1] then
			sector = (p.base[1] == team) and "OWN" or "ENEMY"
		end
		Context.FlagLabel[p.name] = { sector = sector, rank = rank, axis = p.myAxis,
			x = p.x, y = p.y, nb = p.nb, base = p.base }
		print("[AISPAWN] SECTOR pid=" .. tostring(pid) .. " team=" .. tostring(team)
			.. " " .. p.name .. " sector=" .. sector .. " rank=" .. rank
			.. " axis=" .. string.format("%.2f", p.myAxis))
	end
end

-- A flag is on the frontier if a neighbor is held by our team, or it is adjacent to our base.
-- Needs the offline adjacency graph (Context.FlagLabel[name].nb/base); false without it.
function IsFrontier(name)
	local label = Context.FlagLabel[name]
	if not label or not label.nb then return false end
	local team = BotApi.Instance.team
	if label.base then
		for _, t in ipairs(label.base) do
			if t == team then return true end
		end
	end
	for _, nbname in ipairs(label.nb) do
		for _, flag in pairs(BotApi.Scene.Flags) do
			if flag.name == nbname and flag.occupant == team then return true end
		end
	end
	return false
end

-- Split the labeled flags laterally between teammate bots. Pure geometry over the Phase 1
-- coords: project each flag onto the axis perpendicular to A->B, band by normalized lateral
-- position, and mark band / shared / mine. Compute + log only -- issues no orders. Two
-- teammates compute an identical partition (same data, same teamSize); only `mine` differs.
-- Collision-safe: if this bot's idx is outside 1..teamSize (the playerId assumption failed),
-- every flag is marked mine (own-all = no partition). nil FlagBases => skip + PART_FALLBACK.
function PartitionFlags()
	Context.FlagOwner = {}
	local bases = Context.FlagBases
	local team = BotApi.Instance.team
	local pid = BotApi.Instance.playerId
	local teamSize = BotApi.Instance.teamSize
	if not bases or not teamSize or teamSize < 1 then
		print("[AISPAWN] PART_FALLBACK reason=no_bases")
		return
	end
	-- A-home and B-home centroids from the base spawns (names start with "a" / "b").
	local ax, ay, an, bx, by, bn = 0, 0, 0, 0, 0, 0
	for name, b in pairs(bases) do
		if string.sub(name, 1, 1) == "a" then ax = ax + b.x; ay = ay + b.y; an = an + 1
		elseif string.sub(name, 1, 1) == "b" then bx = bx + b.x; by = by + b.y; bn = bn + 1 end
	end
	if an == 0 or bn == 0 then
		print("[AISPAWN] PART_FALLBACK reason=missing_side")
		return
	end
	ax, ay, bx, by = ax / an, ay / an, bx / bn, by / bn
	-- Forward axis A->B = (fx, fy); lateral axis is the perpendicular (-fy, fx).
	local fx, fy = bx - ax, by - ay
	local px, py = -fy, fx
	-- Each labeled flag's signed lateral projection, relative to the A centroid.
	local flags = {}
	for name, lab in pairs(Context.FlagLabel) do
		if lab.x and lab.y then
			local lat = (lab.x - ax) * px + (lab.y - ay) * py
			flags[#flags + 1] = { name = name, lat = lat }
		end
	end
	if #flags == 0 then
		print("[AISPAWN] PART_FALLBACK reason=no_coords")
		return
	end
	-- Normalize lateral to [0,1] across the present flags.
	local lo, hi = flags[1].lat, flags[1].lat
	for _, f in ipairs(flags) do
		if f.lat < lo then lo = f.lat end
		if f.lat > hi then hi = f.lat end
	end
	local span = hi - lo
	-- This bot's team index, and whether it is in range (the gate-verified assumption).
	local idx = (team == "b") and (pid - teamSize) or pid
	local idxTrusted = (idx >= 1 and idx <= teamSize)
	for _, f in ipairs(flags) do
		local u = (span > 0) and ((f.lat - lo) / span) or 0.5
		local band = math.floor(u * teamSize) + 1
		if band > teamSize then band = teamSize end
		local shared = false
		for k = 1, teamSize - 1 do
			if math.abs(u - k / teamSize) <= PartSharedHalfWidth then shared = true; break end
		end
		local mine = (not idxTrusted) or shared or (band == idx)
		Context.FlagOwner[f.name] = { band = band, shared = shared, mine = mine, lat = f.lat }
		print("[AISPAWN] PART pid=" .. tostring(pid) .. " team=" .. tostring(team)
			.. " idx=" .. tostring(idx) .. " trusted=" .. tostring(idxTrusted)
			.. " " .. f.name .. " band=" .. band
			.. " shared=" .. tostring(shared) .. " mine=" .. tostring(mine))
	end
end

-- One-shot diagnostic: dump the runtime environment so a captured log can reveal whether
-- ANY map/scene identity or flag coordinate is reachable (to disambiguate maps with the
-- same flag-name set). Pure introspection, every access pcall-guarded -- never errors.
function MapProbe()
	local function keys(label, t)
		local ok, s = pcall(function()
			local o = {}
			for k in pairs(t) do o[#o + 1] = tostring(k) end
			table.sort(o)
			return table.concat(o, ",")
		end)
		print("[AISPAWN] MAPPROBE " .. label .. "=" .. (ok and s or "<not iterable>"))
	end
	keys("_G", _G)
	keys("BotApi", BotApi)
	keys("Instance", BotApi.Instance)
	keys("Scene", BotApi.Scene)
	keys("Commands", BotApi.Commands)
	-- Speculative engine globals that might name the map/mission.
	for _, g in ipairs({ "GetMissionName", "MissionName", "Mission", "mission",
		"Map", "map", "GetMap", "Scene", "scene", "Game", "GameInfo", "GetSceneName" }) do
		local ok, v = pcall(function() return _G[g] end)
		print("[AISPAWN] MAPPROBE global." .. g .. "=" .. tostring(ok and v))
	end
	-- File/OS capability: os.time is already used, so the sandbox is not fully locked. If io
	-- read works on an engine-written file (game.log names the loaded map), map identity
	-- becomes reachable -- which would resolve the flag-name collision across 20 maps.
	keys("os", os)
	keys("io", io)
	print("[AISPAWN] MAPPROBE has_loadfile=" .. tostring(_G.loadfile ~= nil)
		.. " has_dofile=" .. tostring(_G.dofile ~= nil)
		.. " has_io=" .. tostring(io ~= nil) .. " has_os=" .. tostring(os ~= nil))
	local function tryRead(path)
		local ok, res = pcall(function()
			local f = io.open(path, "r")
			if not f then return "nil" end
			local line = f:read("*l")
			f:close()
			return "OPENED first_line=[" .. tostring(line) .. "]"
		end)
		print("[AISPAWN] MAPPROBE read[" .. path .. "]=" .. tostring((ok and res) or "<err>"))
	end
	if io and io.open then
		tryRead("game.log")
		tryRead("log/game.log")
		tryRead("mission.mi")
		local okw = pcall(function()
			local f = io.open("aispawn_probe.txt", "w"); f:write("aispawn"); f:close()
		end)
		print("[AISPAWN] MAPPROBE write_test=" .. tostring(okw))
	end
	-- Engine root objects never dumped before. `root` is in _G and may expose scene/mission
	-- identity natively -- portable, no log scraping. `package`/`log` listed for completeness.
	for _, g in ipairs({ "root", "package", "log" }) do
		local ok, v = pcall(function() return _G[g] end)
		print("[AISPAWN] MAPPROBE global." .. g .. "=" .. tostring(ok and v)
			.. " type=" .. tostring(type(_G[g])))
		keys(g, _G[g])
	end
	-- If `root` holds an object, probe speculative map-name accessors on it.
	if type(root) == "table" or type(root) == "userdata" then
		for _, fld in ipairs({ "name", "scene", "Scene", "mission", "Mission", "map", "Map",
			"sceneName", "missionName", "GetName", "GetScene", "GetMission" }) do
			local ok, v = pcall(function() return root[fld] end)
			print("[AISPAWN] MAPPROBE root." .. fld .. "=" .. tostring(ok and v))
		end
	end
	-- Env-based log-path discovery. Proton path is deterministic (user is always steamuser);
	-- on native Windows the user folder comes from USERPROFILE. Tail is a game constant.
	if os and os.getenv then
		for _, e in ipairs({ "PWD", "CD", "USERPROFILE", "USERNAME", "APPDATA",
			"HOMEDRIVE", "HOMEPATH", "HOME" }) do
			print("[AISPAWN] MAPPROBE env." .. e .. "=" .. tostring(os.getenv(e)))
		end
		-- Read the real game.log and keep the last `Starting "multi/<MAP>"` line: that names
		-- the loaded map and would break the flag-name fingerprint collision across 20 maps.
		local tail = [[\Documents\my games\men of war - assault squad 2\log\game.log]]
		local function scanForMap(path)
			local ok, res = pcall(function()
				local f = io.open(path, "r")
				if not f then return "nil" end
				local hit = "no-Starting-line"
				for line in f:lines() do
					if line:find("Starting", 1, true) and line:find("multi/", 1, true) then
						hit = line
					end
				end
				f:close()
				return hit
			end)
			print("[AISPAWN] MAPPROBE scan[" .. path .. "]=" .. tostring((ok and res) or "<err>"))
		end
		if io and io.open then
			scanForMap([[C:\users\steamuser\Documents\my games\men of war - assault squad 2\log\game.log]])
			local up = os.getenv("USERPROFILE")
			if up then scanForMap(up .. tail) end
		end
	end
	-- One flag object: list its fields, then probe speculative coordinate/id accessors.
	local f1
	for _, fl in pairs(BotApi.Scene.Flags) do f1 = fl; break end
	if f1 then
		keys("flag", f1)
		for _, fld in ipairs({ "name", "occupant", "position", "pos", "point", "coord",
			"x", "y", "z", "id", "tag", "mid", "index" }) do
			local ok, v = pcall(function() return f1[fld] end)
			print("[AISPAWN] MAPPROBE flag." .. fld .. "=" .. tostring(ok and v))
		end
	end
end

function OnGameStart()
	-- START_PROBE: dump the BotApi surface so a captured log can show whether the engine
	-- exposes any player/team count. Speculative fields print "nil" if they do not exist.
	local inst = BotApi.Instance
	local nflags, nsquads = 0, 0
	for _ in pairs(BotApi.Scene.Flags) do nflags = nflags + 1 end
	for _ in pairs(BotApi.Scene.Squads) do nsquads = nsquads + 1 end
	print("[AISPAWN] START_PROBE team=" .. tostring(inst.team)
		.. " enemyTeam=" .. tostring(inst.enemyTeam)
		.. " army=" .. tostring(inst.army)
		.. " teamSize=" .. tostring(inst.teamSize)
		.. " hostId=" .. tostring(inst.hostId)
		.. " playerId=" .. tostring(inst.playerId)
		.. " players=" .. tostring(inst.players)
		.. " playerCount=" .. tostring(inst.playerCount)
		.. " numPlayers=" .. tostring(inst.numPlayers)
		.. " teamPlayers=" .. tostring(inst.teamPlayers)
		.. " teamCount=" .. tostring(inst.teamCount)
		.. " allies=" .. tostring(inst.allies)
		.. " flags=" .. tostring(nflags)
		.. " squads=" .. tostring(nsquads))
	MapProbe()
	Context.MapName = ReadMapName()
	LabelFlags()
	PartitionFlags()
	math.randomseed(os.time() * BotApi.Instance.hostId)
	math.random() math.random() math.random()
	Context.Purchase = PIter:new(Purchases)
	Context.Phases = ResolvePhases(BotApi.Instance.army)
	Context.LastWaveTime = -WaveIntervalSec -- negative so the first wave-start check passes immediately at Elapsed()==0
	Context.MatchQuants = 0
	Context.StartTime = os.time()
	Context.GameClock = 0
	Context.LastWall = os.time()
	Context.WaveRemaining = 0
	Context.WaveFails = 0
	Context.WaveCooldown = 0
	Context.LastNeutralTime = 0
	Context.LastBackfillTime = 0
	Context.LastDefenderTime = 0
	Context.LastArtyTime = 0
	Context.LastDeepStrikeTime = 0
	Context.AirborneSquads = {}
	Context.LastOfficerTime = 0
	Context.LastAtRifleTime = 0
	Context.LastAssaultGunTime = 0
	Context.LastSupportVehicleTime = 0
	Context.RatioCount = 0
	Context.AuxOwed = 0
	Context.Cappers = {}
	Context.CapperTarget = {}
	Context.SpawnQueue = {}
	Context.FailCooldown = {}
	Context.PrevOwned = {}
	Context.LostStamp = {}
	Context.CapturedStamp = {}
	Context.Groups = {}
	Context.SquadGroup = {}
	Context.FillGroup = nil
	UpdateUnitToSpawn(Context.Purchase)
end

function OnGameStop()
	for squad, timer in pairs(Context.SquadTimers) do
		if timer then BotApi.Events:KillQuantTimer(timer) end
	end
end

-- Attempt one spawn of the current pick, log it, and re-roll the next pick.
-- On failure the unit is benched (FailCooldown) so the picker falls through to a
-- cheaper tier next time. Returns "ok", "fail", or "empty" (nothing spawnable).
-- Shared by the wave driver and the between-wave backfill (tag distinguishes them).
function AttemptSpawn(tag)
	if not Context.SpawnInfo then UpdateUnitToSpawn(Context.Purchase) end
	if not Context.SpawnInfo then return "empty" end
	local unit = Context.SpawnInfo
	local ok = BotApi.Commands:Spawn(unit.unit, MaxSquadSize)
	if ok then ClaimSpawnSlot() end
	local field = GetFieldCounts()
	print("[AISPAWN] " .. tag .. " mq=" .. tostring(Context.MatchQuants)
		.. " phase=" .. CurrentPhase(Elapsed()).name
		.. " income=" .. tostring(BotApi.Commands:Income(BotApi.Instance.playerId))
		.. " squads=" .. tostring(LiveSquadCount())
		.. " H=" .. tostring(field.heavy)
		.. " Md=" .. tostring(field.medium)
		.. " L=" .. tostring(field.light)
		.. " R=" .. tostring(field.rifle)
		.. " S=" .. tostring(field.smg)
		.. " A=" .. tostring(field.aux)
		.. " tier=" .. tostring(TierOf(unit))
		.. " try=" .. tostring(unit.unit)
		.. " ok=" .. tostring(ok))
	local g = Context.FillGroup and Context.Groups[Context.FillGroup]
	if g then
		local pname = CurrentPhase(Elapsed()).name
		if g.phase ~= pname then
			g.phase = pname
			print("[AISPAWN] GROUP_UP id=" .. tostring(Context.FillGroup) .. " phase=" .. pname .. PidTag())
		end
		if ok then
			-- Aux (TierOf == nil) rides along but does not fill the cap, so it does not
			-- count as a pending combat slot either; only ratio units bump g.pending.
			local isAux = (TierOf(unit) == nil)
			if not isAux then g.pending = (g.pending or 0) + 1 end
			Context.SpawnQueue[#Context.SpawnQueue + 1] =
				{ kind = "group", info = unit, slot = Context.FillGroup, aux = isAux }
		end
		-- size reflects committed fills (live members + pending), since the member for THIS
		-- spawn lands a quant later via OnGameSpawn.
		print("[AISPAWN] GROUP_FILL id=" .. tostring(Context.FillGroup)
			.. " tier=" .. tostring(TierOf(unit))
			.. " try=" .. tostring(unit.unit)
			.. " ok=" .. tostring(ok)
			.. " size=" .. tostring(GroupMemberCount(g) + (g.pending or 0)) .. "/" .. tostring(g.size) .. PidTag())
	elseif ok then
		-- No group to attach to (FillGroup unset or pruned between the check and here):
		-- still push a descriptor so the FIFO stays in sync with this successful Spawn.
		-- Skipping this push was the root cause of a class of "wrong unit acts wrong"
		-- bugs -- e.g. a later officer's descriptor getting consumed by this squad
		-- (leaving the real officer to inherit a combat descriptor and get sent to
		-- attack), or a combat unit inheriting an officer descriptor and sitting
		-- parked at base forever -- since OnGameSpawn blindly pops the next queue
		-- entry for every engine spawn event regardless of whether one was pushed.
		Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "trickle", info = unit }
	end
	if not ok then
		Context.FailCooldown[unit.unit] = Elapsed()
	else
		-- Advance the ratio/aux cycle on a successful spawn.
		if TierOf(unit) == nil then
			if Context.AuxOwed > 0 then Context.AuxOwed = Context.AuxOwed - 1 end
		else
			local utier = TierOf(unit)
			if g and (g.armorLead or 0) > 0 and (utier == "heavy" or utier == "medium") then
				g.armorLead = g.armorLead - 1
			end
			Context.RatioCount = Context.RatioCount + 1
			local phase = CurrentPhase(Elapsed())
			if Context.RatioCount >= CycleSize(phase) then
				Context.RatioCount = 0
				Context.AuxOwed = AuxPerCycle
			end
		end
	end
	UpdateUnitToSpawn(Context.Purchase)
	if ok then return "ok" else return "fail" end
end

-- Stamp flags we just lost (ours last tick, now no longer ours) with the loss time, and
-- flags we just captured (not ours last tick, ours now) with the capture time. The engine's
-- flag object exposes only `name` and `occupant` (confirmed via MapProbe's field dump) --
-- no capture-progress percentage, no "still contesting" flag -- so `occupant` flipping to our
-- team is the only signal we get, and it is NOT proof the capture is secure: a fresh capture
-- can still be flipped back quickly if the position is undefended. CapturedStamp lets
-- FlagJustCaptured approximate "how long have we held this" from that one bit of information.
-- Triggers on owned->neutral (enemy mid-capture), not only owned->enemy, so FlagTier
-- can escalate an own-sector flag to tier 1 before the enemy finishes capturing it.
function TrackLostFlags()
	for i, flag in pairs(BotApi.Scene.Flags) do
		local ownedNow = (flag.occupant == BotApi.Instance.team)
		if Context.PrevOwned[flag.name] and not ownedNow then
			Context.LostStamp[flag.name] = Elapsed()
		elseif ownedNow and not Context.PrevOwned[flag.name] then
			Context.CapturedStamp[flag.name] = Elapsed()
		end
		Context.PrevOwned[flag.name] = ownedNow
	end
end

-- Late-game comeback: when the enemy holds more than DeepStrikePct of all flags, drop an
-- elite airborne squad on its own cooldown (capped). The squad is queued as kind="airborne"
-- so OnGameSpawn tags it for the deep-strike router instead of a group. Mirrors the MG/arty
-- trickle shape; runs as an independent trickle because its trigger differs from theirs.
function DeepStrikeTrickle()
	if Elapsed() - Context.LastDeepStrikeTime < DeepStrikeIntervalSec then return end
	local phaseName = CurrentPhase(Elapsed()).name
	if phaseName ~= "mid" and phaseName ~= "late" then return end
	if EnemyFlagPct() <= DeepStrikePct and not IsLosing() then return end
	if LiveAirborneCount() >= DeepStrikeCap then return end
	local u = GetAirborneUnit()
	if not u then return end
	if not SpawnSlotFree() then return end
	Context.LastDeepStrikeTime = Elapsed()
	Context.SpawnInfo = u
	local ok = BotApi.Commands:Spawn(u.unit, MaxSquadSize)
	print("[AISPAWN] DEEPSTRIKE try=" .. tostring(u.unit) .. " ok=" .. tostring(ok)
		.. " pct=" .. string.format("%.2f", EnemyFlagPct()))
	if ok then
		ClaimSpawnSlot()
		Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "airborne", info = u }
	else
		Context.FailCooldown[u.unit] = Elapsed()
	end
end

function OnGameQuant()
	Context.MatchQuants = Context.MatchQuants + 1
	AdvanceClock()

	-- Stamp flags we just lost so FlagTier can prioritise recapture (see TrackLostFlags).
	TrackLostFlags()

	-- Refresh group targets each quant (re-pick if gone or nil).
	UpdateGroupTargets()

	-- Start a wave every WaveIntervalNow() quants (shorter when losing; only when
	-- no wave is in progress).
	if Elapsed() - Context.LastWaveTime >= WaveIntervalNow() and Context.WaveRemaining == 0 then
		Context.LastWaveTime = Elapsed()
		local phase = CurrentPhase(Elapsed())
		local budget = math.floor(phase.budget * LosingBudgetMult())
		Context.WaveRemaining = budget
		Context.WaveFails = 0
		Context.WaveCooldown = 0
		-- Build/refresh the groups, then split the phase's armor quota across them so
		-- each prong leads with armor (front-load is gated by the army-wide deficit).
		ManageGroups()
		ApportionArmor(phase)
		local ng = 0
		for i = 1, MaxGroups do if Context.Groups[i] then ng = ng + 1 end end
		print("[AISPAWN] WAVE mq=" .. tostring(Context.MatchQuants)
			.. " t=" .. tostring(math.floor(Elapsed()))
			.. " phase=" .. phase.name .. " budget=" .. tostring(budget)
			.. " deficit=" .. tostring(FlagDeficit())
			.. " groups=" .. tostring(ng))
	end

	-- Drive the in-progress wave: one Spawn every WaveSpawnSpacing quants (the
	-- engine accepts ~1 spawn per tick, so attempts must be spread across quants).
	if Context.WaveRemaining > 0 then
		Context.LastBackfillTime = Elapsed() -- no idle backfill while a wave is running
		Context.WaveCooldown = Context.WaveCooldown - 1
		if Context.WaveCooldown <= 0 then
			Context.WaveCooldown = WaveSpawnSpacing
			Context.FillGroup = GroupToFill()
			if Context.FillGroup ~= nil and OwnedSquadCount() < CurrentSquadCap() then
				if not SpawnSlotFree() then
					-- Another trickle already claimed this quant's one spawn slot; retry
					-- next tick instead of racing it (see SpawnSlotFree comment).
					Context.WaveCooldown = 0
				else
					local r = AttemptSpawn("SPAWN")
					if r == "ok" then
						Context.WaveRemaining = Context.WaveRemaining - 1
						Context.WaveFails = 0
					else
						-- "fail" (benched a unit) or "empty" (pool exhausted): a persistently
						-- unspendable wave still ends after MaxWaveFails, but a single failure
						-- just falls through to the next-cheapest pick on the following tick.
						Context.WaveFails = Context.WaveFails + 1
						if Context.WaveFails >= MaxWaveFails then
							Context.WaveRemaining = 0
						end
					end
				end
			else
				-- Both groups are full: nothing to fill, so end the wave now (otherwise the
				-- cadence would freeze until attrition frees a slot).
				Context.WaveRemaining = 0
			end
			if Context.WaveRemaining == 0 then
				print("[AISPAWN] WAVE_END")
			end
		end
	else
		-- Idle between waves. Two trickles share this window; at most one spawns per
		-- tick (the engine accepts ~1 spawn/quant). The rarer MG defender takes
		-- priority, then the combat backfill toward the deficit tier.
		if Elapsed() - Context.LastDefenderTime >= DefenderIntervalSec
		and HeldFlagCount() > 0 and LiveMGCount() < DefenderCap and SpawnSlotFree() then
			Context.LastDefenderTime = Elapsed()
			local mg = GetMGUnit()
			if mg then
				Context.SpawnInfo = mg -- routed as a defender (DefenderClasses[MG]=true)
				local ok = BotApi.Commands:Spawn(mg.unit, MaxSquadSize)
				print("[AISPAWN] DEFENDER try=" .. tostring(mg.unit) .. " ok=" .. tostring(ok))
				if ok then
					ClaimSpawnSlot()
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "trickle", info = mg }
				else
					Context.FailCooldown[mg.unit] = Elapsed()
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
		elseif Elapsed() - Context.LastArtyTime >= ArtyIntervalSec
		and CurrentPhase(Elapsed()).name ~= "early"
		and HeldFlagCount() > 0 and LiveArtyCount() < ArtyCap and SpawnSlotFree() then
			Context.LastArtyTime = Elapsed()
			local art = GetArtyUnit()
			if art then
				Context.SpawnInfo = art -- routed as a defender (DefenderClasses[ArtilleryTank]=true)
				local ok = BotApi.Commands:Spawn(art.unit, MaxSquadSize)
				print("[AISPAWN] ARTY try=" .. tostring(art.unit) .. " ok=" .. tostring(ok))
				if ok then
					ClaimSpawnSlot()
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "trickle", info = art }
				else
					Context.FailCooldown[art.unit] = Elapsed()
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
		elseif Elapsed() - Context.LastWaveTime >= BackfillQuietSec
		and Elapsed() - Context.LastBackfillTime >= BackfillIntervalSec and SpawnSlotFree() then
			Context.LastBackfillTime = Elapsed()
			Context.FillGroup = GroupToFill()
			if Context.FillGroup ~= nil and OwnedSquadCount() < CurrentSquadCap() then
				AttemptSpawn("BACKFILL")
			end
		end
	end

	-- Neutral-flag capper trickle, independent of the wave cadence.
	if Elapsed() - Context.LastNeutralTime >= NeutralIntervalSec and SpawnSlotFree() then
		Context.LastNeutralTime = Elapsed()
		if AnyCapperTarget() and LiveCapperCount() < CapperCap then
			local line = GetCapperUnit()
			if line then
				local ok = BotApi.Commands:Spawn(line.unit, 1) -- single-soldier capper entity (riflemans2)
				print("[AISPAWN] CAPPER try=" .. tostring(line.unit)
					.. " ok=" .. tostring(ok))
				if ok then
					ClaimSpawnSlot()
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "capper", info = line }
				end
			end
		end
	end

	-- Officer keep-alive trickle: after the unlock, maintain OfficerCap officers parked
	-- at the spawn. They are spawned here (never via the ratio/aux pool) so OnGameSpawn
	-- can withhold their capture order and leave them safe in the rear.
	if Elapsed() - Context.LastOfficerTime >= OfficerIntervalSec and SpawnSlotFree() then
		Context.LastOfficerTime = Elapsed()
		if Elapsed() >= OfficerUnlock
		and OfficerOnField() < OfficerCap then
			local off = GetOfficerUnit()
			if off then
				Context.SpawnInfo = off
				local ok = BotApi.Commands:Spawn(off.unit, MaxSquadSize)
				print("[AISPAWN] OFFICER try=" .. tostring(off.unit) .. " ok=" .. tostring(ok))
				if ok then
					ClaimSpawnSlot()
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "trickle", info = off }
				else
					Context.FailCooldown[off.unit] = Elapsed()
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
		end
	end

	-- AT-rifle keep-alive: from mid phase on, keep one AT rifle fielded as a GROUP member so it
	-- moves with and escorts the platoon (anti half-track) instead of wandering alone.
	if Elapsed() - Context.LastAtRifleTime >= AtRifleIntervalSec and SpawnSlotFree() then
		Context.LastAtRifleTime = Elapsed()
		if CurrentPhase(Elapsed()).name ~= "early"
		and AtRifleOnField() < AtRifleCap
		and OwnedSquadCount() < CurrentSquadCap() then
			-- Attach to a group: the one being filled, else the first live group. Only spawn
			-- the AT rifle when a group exists for it to follow.
			local slot = GroupToFill()
			if not slot then
				for i = 1, MaxGroups do
					if Context.Groups[i] then slot = i; break end
				end
			end
			local g = slot and Context.Groups[slot]
			if g then
				local atr = GetAtRifleUnit()
				if atr then
					Context.SpawnInfo = atr
					local ok = BotApi.Commands:Spawn(atr.unit, MaxSquadSize)
					print("[AISPAWN] ATRIFLE try=" .. tostring(atr.unit)
						.. " ok=" .. tostring(ok) .. " group=" .. tostring(slot))
					if ok then
						ClaimSpawnSlot()
						-- AT rifle is aux: rides along to escort the platoon but does not fill
						-- the group cap, so it is not a pending combat slot.
						Context.SpawnQueue[#Context.SpawnQueue + 1] =
							{ kind = "group", info = atr, slot = slot, aux = true }
					else
						Context.FailCooldown[atr.unit] = Elapsed()
					end
					UpdateUnitToSpawn(Context.Purchase)
				end
			end
		end
	end

	-- Assault-gun escort keep-alive: close-support gun-howitzers (stuh42, brummbar, ...)
	-- attach specifically to the MAIN group (id 1) and follow its target, unlike the AT rifle
	-- above which is fine escorting whichever group needs it -- these are meant as the main
	-- push's direct-fire support, not a sub-prong add-on.
	if Elapsed() - Context.LastAssaultGunTime >= AssaultGunIntervalSec and SpawnSlotFree() then
		Context.LastAssaultGunTime = Elapsed()
		if LiveAssaultGunCount() < AssaultGunCap
		and OwnedSquadCount() < CurrentSquadCap()
		and Context.Groups[1] then
			local ag = GetAssaultGunUnit()
			if ag then
				Context.SpawnInfo = ag
				local ok = BotApi.Commands:Spawn(ag.unit, MaxSquadSize)
				print("[AISPAWN] ASSAULTGUN try=" .. tostring(ag.unit) .. " ok=" .. tostring(ok))
				if ok then
					ClaimSpawnSlot()
					-- Assault gun is aux: rides along to escort the main group but does not
					-- fill the group cap, so it is not a pending combat slot.
					Context.SpawnQueue[#Context.SpawnQueue + 1] =
						{ kind = "group", info = ag, slot = 1, aux = true }
				else
					Context.FailCooldown[ag.unit] = Elapsed()
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
		end
	end

	-- Support-vehicle keep-alive: guarantee these a real shot at the field (see
	-- SupportVehicleIntervalSec comment) instead of leaving them to compete for AuxPerCycle
	-- picks in the crowded generic aux pool. Same shape as the AT-rifle trickle above: attach
	-- to a group as an escort, only spawn when a group exists to follow.
	if Elapsed() - Context.LastSupportVehicleTime >= SupportVehicleIntervalSec and SpawnSlotFree() then
		Context.LastSupportVehicleTime = Elapsed()
		if LiveSupportVehicleCount() < SupportVehicleCap
		and OwnedSquadCount() < CurrentSquadCap() then
			local slot = GroupToFill()
			if not slot then
				for i = 1, MaxGroups do
					if Context.Groups[i] then slot = i; break end
				end
			end
			local g = slot and Context.Groups[slot]
			if g then
				local sv = GetSupportVehicleUnit()
				if sv then
					Context.SpawnInfo = sv
					local ok = BotApi.Commands:Spawn(sv.unit, MaxSquadSize)
					print("[AISPAWN] SUPPORTVEH try=" .. tostring(sv.unit)
						.. " ok=" .. tostring(ok) .. " group=" .. tostring(slot))
					if ok then
						ClaimSpawnSlot()
						-- Support vehicle is aux: rides along to escort the platoon but does not
						-- fill the group cap, so it is not a pending combat slot.
						Context.SpawnQueue[#Context.SpawnQueue + 1] =
							{ kind = "group", info = sv, slot = slot, aux = true }
					else
						Context.FailCooldown[sv.unit] = Elapsed()
					end
					UpdateUnitToSpawn(Context.Purchase)
				end
			end
		end
	end

	DeepStrikeTrickle()

	for squadId in pairs(Context.FieldUnits) do
		if not BotApi.Scene:IsSquadExists(squadId) then
			local gi = Context.SquadGroup[squadId]
			if gi and Context.Groups[gi] then
				Context.Groups[gi].members[squadId] = nil
				if Context.Groups[gi].auxMembers then Context.Groups[gi].auxMembers[squadId] = nil end
			end
			Context.SquadGroup[squadId] = nil
			Context.FieldUnits[squadId] = nil
			Context.Cappers[squadId] = nil
			Context.CapperTarget[squadId] = nil
			Context.AirborneSquads[squadId] = nil
		end
	end
	PruneGroups()

	for i, squad in pairs(BotApi.Scene.Squads) do
		if not Context.SquadTimers[squad] then
			local entry = Context.FieldUnits[squad]
			if not (entry and entry.class == UnitClass.Officer) then
				SetSquadOrder(CaptureFlag, squad, OrderRotationPeriod) -- officers stay parked
			end
		end
	end
end

-- True if a flag (by name) is still worth attacking: it exists and is not already ours.
function FlagAttackable(name)
	for i, flag in pairs(BotApi.Scene.Flags) do
		if flag.name == name then
			return flag.occupant ~= BotApi.Instance.team
		end
	end
	return false
end

-- True if we currently own this flag AND captured it within the last CaptureSettleSec
-- seconds (see the constant's comment). Requires the CURRENT occupant to still be us, not
-- just a recent-enough CapturedStamp -- a flag captured, then lost, then not yet recaptured
-- must not read as "settling" off a stale timestamp.
function FlagJustCaptured(name)
	local stamp = Context.CapturedStamp[name]
	if not stamp or Elapsed() - stamp >= CaptureSettleSec then return false end
	for i, flag in pairs(BotApi.Scene.Flags) do
		if flag.name == name then return flag.occupant == BotApi.Instance.team end
	end
	return false
end

-- Squared distance from a flag's coords to the nearest flag our team currently owns.
-- nil when the flag has no coords or we own no coord-bearing flag (triggers legacy ordering).
function NearestOwnedDist(label)
	if not (label and label.x) then return nil end
	local team = BotApi.Instance.team
	local best
	for _, flag in pairs(BotApi.Scene.Flags) do
		if flag.occupant == team then
			local o = Context.FlagLabel[flag.name]
			if o and o.x then
				local dx, dy = label.x - o.x, label.y - o.y
				local d = dx * dx + dy * dy
				if not best or d < best then best = d end
			end
		end
	end
	return best
end

-- Classify a flag into the attack tier ladder, or nil when it is not a valid
-- candidate (not enemy-held and not a recently-lost neutral).
-- Tier 1:   enemy holds/attacks an OWN-sector flag (home invaded).
-- Tier 2:   a mine + frontier + CONTESTED flag the enemy holds (our lane front).
-- Tier 2.5: a mine + CONTESTED flag in our lane whose frontier status is momentarily
--           unconfirmed (still ranked ahead of tier 3 so a frontier gap never sends the
--           group past the frontline at the enemy's OWN/base flag).
-- Tier 3:   every other enemy/attacked flag (expand).
function FlagTier(name)
	local team = BotApi.Instance.team
	local enemy = BotApi.Instance.enemyTeam
	local flag
	for _, f in pairs(BotApi.Scene.Flags) do
		if f.name == name then flag = f; break end
	end
	if not flag then return nil end
	-- Hold newly-won ground for CaptureSettleSec before it can be dropped as a target: an
	-- owned flag would otherwise fall straight through to nil below (neither held nor
	-- lostNeutral) the instant occupant flips, which is not proof the capture is secure (see
	-- CaptureSettleSec's comment). Same tier as an active frontier fight so this never loses
	-- out to a genuinely better candidate, but also never permanently outranks one.
	if FlagJustCaptured(name) then return 2 end
	local held = flag.occupant == enemy
	local neutral = flag.occupant ~= team and flag.occupant ~= enemy
	local lostNeutral = neutral and Context.LostStamp[name] ~= nil
	local label = Context.FlagLabel[name] or {}
	local owner = Context.FlagOwner[name]
	-- Natural frontline: a frontier flag in our own lane is a group target whether the enemy
	-- holds it OR it is still neutral. This keeps groups fighting at the contested boundary
	-- instead of marching past a neutral center straight into the enemy base.
	if owner and owner.mine and label.sector == "CONTESTED" and (held or neutral) then
		if IsFrontier(name) then return 2 end
		-- IsFrontier can go transiently false (a neighbor flag briefly recontested, or not
		-- yet registered right at match start) even though this is still our lane's own
		-- CONTESTED flag. Once we actually hold ground somewhere (HeldFlagCount() > 0 --
		-- true from t=0 in a real match, since home starts owned), rank this flag just
		-- behind a confirmed frontier flag but still strictly ahead of tier 3, so a
		-- momentary frontier gap never sends the group past the frontline straight at the
		-- enemy's OWN/base flag. Guarded on HeldFlagCount() so the all-neutral/nothing-
		-- captured-anywhere case still falls through to nil below, unchanged.
		if HeldFlagCount() > 0 then return 2.5 end
	end
	-- Everything below is a recapture/deep target: the flag must be enemy-held or freshly lost.
	if not (held or lostNeutral) then return nil end
	if label.sector == "OWN" then
		-- First 4 minutes: groups do not pull back to recapture home flags; they push
		-- forward and leave home defense to cappers/defenders. After the grace, home
		-- recapture resumes at top priority.
		if Elapsed() < GroupHomeGraceSec then return nil end
		return 1
	end
	return 3
end

-- The group's attack flag, by the FlagTier ladder over candidates, excluding excludeName and
-- (optionally) excludeName2 -- the stuck-timeout re-pick in UpdateGroupTargets passes both the
-- stuck flag AND the other group's target, so forcing group 1 off a stuck flag can never just
-- hand it group 2's own objective. Within a tier, lower key wins (tier 1/2 by lane axis, tier 3
-- by distance to our nearest owned flag, then recapture recency). Sets Context.LastPickTier for
-- logging. Returns nil only when no candidate exists.
function PickGroupTarget(excludeName, excludeName2)
	local best
	for _, flag in pairs(BotApi.Scene.Flags) do
		local name = flag.name
		if name ~= excludeName and name ~= excludeName2 then
			local tier = FlagTier(name)
			if tier then
				local label = Context.FlagLabel[name] or {}
				local key
				if tier == 1 or tier == 2 or tier == 2.5 then
					-- Within the frontier tier, contest enemy-held flags before advancing onto
					-- still-neutral ones (bias held ahead); ties break by axis (rear first).
					local heldHere = flag.occupant == BotApi.Instance.enemyTeam
					key = (heldHere and 0 or 1000) + (label.axis or 1)
				else
					local d = NearestOwnedDist(label)
					if d then
						key = d
					else
						local stamp = Context.LostStamp[name]
						key = (stamp and -stamp or (1e9 - GetFlagPriority(flag)))
					end
				end
				if not best or tier < best.tier
				   or (tier == best.tier and key < best.key)
				   or (tier == best.tier and key == best.key and name < best.name) then
					best = { name = name, tier = tier, key = key }
				end
			end
		end
	end
	Context.LastPickTier = best and best.tier
	return best and best.name
end

function CaptureFlag(squad)
	-- Group members: attack the group's shared target (membership overrides class role).
	-- FlagJustCaptured also qualifies: a freshly-taken flag still orders the group there
	-- (the command holds/garrisons an owned flag, same mechanism defenders use) instead of
	-- going order-less for the rest of the settle window while UpdateGroupTargets keeps it
	-- as the group's target but CaptureFlag itself refuses to route to an owned flag.
	local gi = Context.SquadGroup[squad]
	if gi and Context.Groups[gi] and Context.Groups[gi].target
	   and (FlagAttackable(Context.Groups[gi].target) or FlagJustCaptured(Context.Groups[gi].target)) then
		BotApi.Commands:CaptureFlag(squad, Context.Groups[gi].target)
		return
	end
	-- Airborne deep-strike squads: drive at the deepest enemy base, then the main target.
	if Context.AirborneSquads[squad] then
		local name = DeepStrikeTarget()
		if name and FlagAttackable(name) then BotApi.Commands:CaptureFlag(squad, name) end
		return
	end
	-- Cappers chase neutral flags (trickle; never group members).
	if Context.Cappers[squad] then
		-- Stay committed to the current flag while it is still neutral (capture unfinished
		-- and not lost to the enemy), so a re-pick never pulls the capper off a flag it is
		-- mid-way through capping. FlagJustCaptured extends this past the occupant flip: the
		-- capper is the only thing garrisoning a flag it just took, so pulling it off
		-- immediately (occupant == team no longer reads as neutral) hands the enemy an
		-- undefended, barely-won flag back for free. Only actually moves on once the flag has
		-- been ours long enough to count as settled, lost again, or unset.
		local cur = Context.CapperTarget[squad]
		if cur and (FlagNeutralByName(cur) or FlagJustCaptured(cur)) then
			BotApi.Commands:CaptureFlag(squad, cur)
			return
		end
		local flag = GetFlagToCapture(BotApi.Scene.Flags, CapperFlagPriority)
		if flag then
			Context.CapperTarget[squad] = flag.name
			BotApi.Commands:CaptureFlag(squad, flag.name)
		end
		return
	end
	-- Defenders (MG, AT, sniper, etc.) hold owned flags. Artillery uses a range-aware
	-- priority so each piece sits where its reach covers the contested center.
	if IsDefender(squad) then
		local entry = Context.FieldUnits[squad]
		if entry and entry.class == UnitClass.ArtilleryTank then
			-- Artillery holds the rearmost owned flag in its safe band, or stays parked
			-- at base (no order) when no held flag is both in range and far enough from
			-- enemy fire -- never advances into a position where it gets killed.
			local name = ArtilleryTargetFlag(entry)
			if name then BotApi.Commands:CaptureFlag(squad, name) end
			return
		end
		local flag = GetFlagToCapture(BotApi.Scene.Flags, DefenderFlagPriority)
		if flag then BotApi.Commands:CaptureFlag(squad, flag.name) end
		return
	end
	-- Fallback: best flag by priority.
	local flag = GetFlagToCapture(BotApi.Scene.Flags, GetFlagPriority)
	if flag then BotApi.Commands:CaptureFlag(squad, flag.name) end
end

function SetSquadOrder(order, squad, delay)
	order(squad)
	local setTimer = function(callback)
		Context.SquadTimers[squad] = BotApi.Events:SetQuantTimer(
			function()
				Context.SquadTimers[squad] = nil
				if BotApi.Scene:IsSquadExists(squad) then
					order(squad)
					callback(callback)
				end
			end, delay)
	end
	setTimer(setTimer)
end

function OnGameSpawn(args)
	local d = table.remove(Context.SpawnQueue, 1)  -- FIFO: matches successful spawns in order
	local info = (d and d.info) or Context.SpawnInfo  -- fallback if queue is empty/desynced
	-- Clear the airborne/rare dedup flags now that the unit has physically spawned.
	Context.SpawnFlags.isAirborne = false
	Context.SpawnFlags.isRare = false
	if info then
		Context.FieldUnits[args.squadId] = info
	end
	if d and d.kind == "capper" then
		Context.Cappers[args.squadId] = true
	elseif d and d.kind == "group" and d.slot and Context.Groups[d.slot] then
		local g = Context.Groups[d.slot]
		g.members[args.squadId] = true
		g.seeded = true
		Context.SquadGroup[args.squadId] = d.slot
		-- Aux members ride along (follow the group target) but do not occupy a combat slot,
		-- so they are tracked separately and never decrement the combat pending count.
		if d.aux then
			g.auxMembers = g.auxMembers or {}
			g.auxMembers[args.squadId] = true
		else
			g.pending = math.max(0, (g.pending or 0) - 1)
		end
	elseif d and d.kind == "airborne" then
		Context.AirborneSquads[args.squadId] = true
	end
	-- Officers stay parked at the spawn (they hold the unit cap); everyone else gets a
	-- capture order. Cappers rotate fast so they advance to the next flag after capping;
	-- everyone else uses the slow standard rotation.
	local entry = Context.FieldUnits[args.squadId]
	if not (entry and entry.class == UnitClass.Officer) then
		local period = Context.Cappers[args.squadId] and CapperRotationPeriod or OrderRotationPeriod
		SetSquadOrder(CaptureFlag, args.squadId, period)
	end
end

BotApi.Events:Subscribe(BotApi.Events.GameStart, OnGameStart)
BotApi.Events:Subscribe(BotApi.Events.GameEnd, OnGameStop)
BotApi.Events:Subscribe(BotApi.Events.Quant, OnGameQuant)
BotApi.Events:Subscribe(BotApi.Events.GameSpawn, OnGameSpawn)
