require([[/script/multiplayer/bot.data]])

local Context = {
	Purchase = nil,
	SpawnInfo = nil,
	SquadTimers = {},
	FieldUnits = {},  -- squadId -> unit entry, tracks live units we spawned
	SpawnQueue = {},  -- FIFO descriptors for successful Spawn() calls; consumed by OnGameSpawn
	SpawnFlags = {
		isAirborne = false,
		isRare = false,
	},
	Cappers = {},      -- squadId -> true, cheap line units sent to grab neutral flags
	QuantCount = 0,    -- quant ticks since the last wave started (wave cadence)
	WaveRemaining = 0, -- units left to attempt in the current wave (0 = idle)
	WaveFails = 0,     -- consecutive failed Spawns this wave (MP-spent detector)
	ArmorLead = 0,     -- armor units still to front-load at the current wave's start
	WaveCooldown = 0,  -- quant countdown between spawns within a wave
	NeutralCount = 0,  -- quant countdown for the neutral-capper trickle
	BackfillCount = 0, -- quant countdown for the between-wave backfill trickle
	DefenderCount = 0, -- quant countdown for the between-wave MG defender trickle
	OfficerCount = 0,  -- quant countdown for the officer keep-alive trickle
	AtRifleCount = 0,  -- quant countdown for the AT-rifle keep-alive trickle
	RatioCount = 0,    -- ratio (non-aux) units spawned since the last aux batch
	Groups = {},        -- array of at most 2 live groups
	SquadGroup = {},    -- squadId -> index into Context.Groups
	FillGroup = nil,    -- index of the group currently being filled (set per spawn)
	AuxOwed = 0,       -- aux units still to inject in the current batch
	MatchQuants = 0,   -- quant ticks since match start (elapsed-time estimate)
	LastSpawn = {},    -- unit.unit -> MatchQuants tick of last spawn (recharge tracking)
	FailCooldown = {}, -- unit.unit -> MatchQuants tick of last FAILED spawn (skip a while)
	PrevOwned = {},    -- flag name -> true if we owned it last tick
	LostStamp = {},    -- flag name -> MatchQuants when we lost it (recapture priority)
}

-- Wave spawning. The engine accepts at most ~1 Spawn per quant tick, so a wave
-- must be SPREAD across quants, not dumped in one tick (doing so wasted MP: one
-- unit landed and the rest were rejected, leaving 3000+ MP unspent at game end).
-- Each wave attempts up to phase.budget units, one every WaveSpawnSpacing quants,
-- and ends early only after MaxWaveFails spawns in a row fail (= truly out of MP).
local WaveInterval    = 60 * 70 -- quants between wave starts (~60s at ~70 quant/sec)
local MinWaveInterval = 10 * 70 -- floor: never faster than ~10s even when far behind
local WaveSpawnSpacing = 7      -- quants between spawns inside a wave (~0.1s)
local MaxWaveFails    = 6       -- consecutive failed Spawns => treat MP as spent, end wave

-- Neutral-flag capper trickle: every NeutralInterval quants, if any flag is
-- neutral, spawn one cheap line-infantry squad ordered to grab a neutral flag.
local NeutralInterval = 5 * 70  -- ~5s between capper checks

-- When a Spawn fails (usually the picked unit is unaffordable right now), bench
-- that unit for FailCooldownQuants so the picker falls through to a cheaper tier
-- instead of hammering the same too-expensive unit until MaxWaveFails ends the wave.
local FailCooldownQuants = 10 * 70 -- ~10s bench after a failed spawn

-- Between waves the field still loses units; backfill trickles one spawn every
-- BackfillInterval quants while idle to keep the composition near its ratio.
local BackfillInterval = 3 * 70 -- ~3s between idle backfill spawns

-- Between-wave defensive trickle: a small, capped number of mobile MG teams (mgs2)
-- sent to dig in on owned flags. Only fires while idle and only when we hold ground.
local DefenderInterval = 20 * 70 -- ~20s between defender checks
local DefenderCap      = 3       -- max live MG teams the bot keeps fielded

-- Officer keep-alive: after OfficerUnlock seconds, keep up to OfficerCap officers parked
-- at the spawn (no capture order) -- they hold the unit cap and must not die at the front.
local OfficerUnlock   = 600     -- seconds before officers become available (~10 min)
local OfficerInterval = 30 * 70 -- quants between officer checks (~30s)
local OfficerCap      = 1       -- max live officers

-- AT-rifle keep-alive: from mid phase on, keep one AT rifle on the field (anti half-track).
local AtRifleInterval = 20 * 70 -- ~20s between checks
local AtRifleCap      = 1       -- max live AT rifles kept

-- Quant rate, measured ~70/sec. Only used to print an elapsed-seconds estimate
-- in the debug log (mq -> t). Unit unlocks are left entirely to the engine, so
-- this value no longer gates spawning; it is purely cosmetic for log review.
local QuantsPerSec = 70

local GroupSize = 8   -- target member count per group
local MaxGroups = 2   -- at most two live groups at a time

-- Hard ceiling on this bot's OWN live squads (combat fill). The engine is 32-bit (~2GB);
-- on team games every AI bot runs this script, so per-bot count multiplies. Aux counts 0.5
-- (see OwnedSquadCount), so 24 is roughly 24 combat or up to ~32-40 mixed squads. Sized for
-- 2v2 (<=4 bots): ~96 weighted / ~130-160 real squads, under the ~200-squad level that OOM'd
-- the 32-bit engine. Lower this if playing larger team games. Tune per typical match size.
local MaxLiveSquads = 24

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
end

function IsCapturedFlag(flag) return flag.occupant == BotApi.Instance.team end
function IsEnemyFlag(flag)    return flag.occupant == BotApi.Instance.enemyTeam end
function IsNeutralFlag(flag)
	return flag.occupant ~= BotApi.Instance.team
	   and flag.occupant ~= BotApi.Instance.enemyTeam
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

-- Cappers strongly prefer neutral flags (cheap units claiming uncontested ground)
-- but still drift to enemy/own flags so they never idle once the map is decided.
function CapperFlagPriority(flag)
	if     IsNeutralFlag(flag)  then return 5.0
	elseif IsEnemyFlag(flag)    then return 1.0
	else                             return 0.5
	end
end

function CountNeutralFlags()
	local n = 0
	for i, flag in pairs(BotApi.Scene.Flags) do
		if IsNeutralFlag(flag) then n = n + 1 end
	end
	return n
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
function LiveOfficerCount()
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
function LiveAtRifleCount()
	local n = 0
	for squadId, entry in pairs(Context.FieldUnits) do
		if entry.class == UnitClass.ATInfantry and string.find(entry.unit, "at_rifle", 1, true) then
			n = n + 1
		end
	end
	return n
end

-- Five-tier classification. Aux (AT, MG, sniper, officer, AA, artillery, flamer)
-- returns nil and never counts toward the ratio.
function TierOf(t)
	if t.class == UnitClass.Infantry and not t.flame then
		if t.mech then return "light"
		elseif t.inf == "smg" then return "smg"
		else return "rifle" end
	elseif t.class == UnitClass.HeavyTank then
		return "heavy"
	elseif t.class == UnitClass.Tank then
		if (t.recharge or 0) >= TierMediumRecharge then return "medium" else return "light" end
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

-- Count one group's live members by tier (heavy/medium/light/rifle/smg); aux not counted.
function CountByTier(group)
	local c = { heavy=0, medium=0, light=0, rifle=0, smg=0, aux=0 }
	for squadId in pairs(group.members) do
		local entry = Context.FieldUnits[squadId]
		if entry then
			local tier = TierOf(entry)
			if tier then c[tier] = c[tier] + 1 else c.aux = c.aux + 1 end
		end
	end
	return c
end

function GroupMemberCount(group)
	local n = 0
	for _ in pairs(group.members) do n = n + 1 end
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

-- Create groups: the 1st whenever none exist; the 2nd only once the 1st is full.
function ManageGroups()
	if not Context.Groups[1] then
		local t = PickGroupTarget(nil)
		Context.Groups[1] = { members = {}, size = GroupSize, target = t, pending = 0,
			phase = CurrentPhase(Context.MatchQuants / QuantsPerSec).name }
		print("[AISPAWN] GROUP_NEW id=1 target=" .. tostring(t))
	elseif not Context.Groups[2]
	   and GroupMemberCount(Context.Groups[1]) >= Context.Groups[1].size then
		local t = PickGroupTarget(Context.Groups[1].target)
		Context.Groups[2] = { members = {}, size = GroupSize, target = t, pending = 0,
			phase = CurrentPhase(Context.MatchQuants / QuantsPerSec).name }
		print("[AISPAWN] GROUP_NEW id=2 target=" .. tostring(t))
	end
end

-- Refresh each group's target: if nil or the flag is gone, re-pick de-conflicted from the other.
function UpdateGroupTargets()
	local g1 = Context.Groups[1]
	local g2 = Context.Groups[2]
	if g1 then
		local other = g2 and g2.target
		if not g1.target or not FlagAttackable(g1.target) then
			local newT = PickGroupTarget(other)
			if newT and newT ~= g1.target then
				print("[AISPAWN] GROUP_TARGET id=1 target=" .. tostring(newT)
					.. " reason=" .. (Context.LostStamp[newT] and "recapture" or "priority"))
			end
			g1.target = newT
		end
	end
	if g2 then
		local other = g1 and g1.target
		if not g2.target or not FlagAttackable(g2.target) then
			local newT = PickGroupTarget(other)
			if newT and newT ~= g2.target then
				print("[AISPAWN] GROUP_TARGET id=2 target=" .. tostring(newT)
					.. " reason=" .. (Context.LostStamp[newT] and "recapture" or "priority"))
			end
			g2.target = newT
		end
	end
end

-- The first group not yet at size, or nil if all full.
function GroupToFill()
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g and GroupMemberCount(g) < g.size then return i end
	end
	return nil
end

-- Drop a group only when it has no live members AND no pending (queued) members, so a
-- freshly-filled group is never reaped before its deferred OnGameSpawn lands. Stable slots:
-- no reindexing, so SquadGroup indices and queued slot refs stay valid.
function PruneGroups()
	for i = 1, MaxGroups do
		local g = Context.Groups[i]
		if g and GroupMemberCount(g) == 0 then
			if (g.pending or 0) == 0 then
				if g.seeded then print("[AISPAWN] GROUP_END id=" .. i) end
				Context.Groups[i] = nil
			else
				-- pending should clear within ~1 quant once OnGameSpawn lands. If it lingers,
				-- a Spawn/OnGameSpawn pairing was lost at the engine level; age the slot out so
				-- it cannot orphan (and desync the queue) for the rest of the match.
				g.staleSince = g.staleSince or Context.MatchQuants
				if Context.MatchQuants - g.staleSince > 3 * QuantsPerSec then
					print("[AISPAWN] GROUP_END id=" .. i .. " reason=stale_pending")
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

-- Wave budget multiplier that scales with how badly we are losing on flags.
-- Even (or ahead) -> 1.0; each flag behind adds 0.25, capped so it cannot run away.
function LosingBudgetMult()
	local deficit = FlagDeficit()
	if deficit <= 0 then return 1.0 end
	return math.min(1.0 + 0.25 * deficit, 2.5)
end

-- Wave cadence: the further behind on flags, the shorter the gap to the next wave
-- (each flag deficit speeds it up), down to MinWaveInterval. Even/ahead -> full gap.
function WaveIntervalNow()
	local deficit = FlagDeficit()
	if deficit <= 0 then return WaveInterval end
	return math.max(MinWaveInterval, math.floor(WaveInterval / (1.0 + 0.25 * deficit)))
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

-- Pick the active phase for an elapsed time in seconds.
function CurrentPhase(elapsedSec)
	for i = 1, #Phases do
		if elapsedSec < Phases[i].upto then return Phases[i] end
	end
	return Phases[#Phases]
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
	local elapsed = Context.MatchQuants / QuantsPerSec
	local phase = CurrentPhase(elapsed)
	local capRank = TierRank[phase.armorCap]

	-- Resolve fill group for per-group field counts and elite cap.
	local g = Context.FillGroup and Context.Groups[Context.FillGroup]

	-- Build the eligible pool: affordable, off-cooldown, and within the phase armor cap.
	local pool = {}
	for i, unit in pairs(units) do
		local affordable = teamSize >= (unit.min_team or 0)
			and income >= (unit.min_income or -1)
		local last = Context.LastSpawn[unit.unit]
		local cooled = (last == nil)
			or (Context.MatchQuants - last >= (unit.recharge or 0) * QuantsPerSec)
		local failed = Context.FailCooldown[unit.unit]
		local notRecentlyFailed = (failed == nil)
			or (Context.MatchQuants - failed >= FailCooldownQuants)
		local tier = TierOf(unit)
		local capOk = (tier == nil) or (TierRank[tier] <= capRank) -- aux not capped
		local phaseOk = (unit.phase == nil) or (unit.phase == phase.name) -- per-unit phase lock
		local eliteOk = not (g and unit.elite and GroupEliteCount(g) >= 1)
		if affordable and cooled and notRecentlyFailed and capOk and phaseOk and eliteOk then
			table.insert(pool, unit)
		end
	end
	if #pool == 0 then return nil end

	-- Aux is separate from the four-tier ratio; it is injected on a fixed cycle.
	local field
	if g then field = CountByTier(g) else field = GetFieldCounts() end
	local function collectAux()
		local out = {}
		for i, t in pairs(pool) do
			if TierOf(t) == nil and AuxEligible(t, enemyHasTanks) then
				if not (t.class == UnitClass.Airborne and Context.SpawnFlags.isAirborne)
				and not (t.class == UnitClass.Rare and Context.SpawnFlags.isRare)
				and t.class ~= UnitClass.Howitzrer
				and t.class ~= UnitClass.ArtilleryTank   -- SPGs disabled (poor bot AI use)
				and t.class ~= UnitClass.Officer then    -- officers are parked by their own trickle
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

	-- Armor lead: at the wave's start, spawn the heaviest available armor tier first.
	if Context.ArmorLead > 0 then
		local lead = nil
		if #byTier.heavy > 0 then lead = "heavy"
		elseif #byTier.medium > 0 then lead = "medium" end
		if lead then
			return GetRandomItem(byTier[lead], weightOf)
		else
			Context.ArmorLead = 0 -- no armor available; resume normal selection
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
	math.randomseed(os.time() * BotApi.Instance.hostId)
	math.random() math.random() math.random()
	Context.Purchase = PIter:new(Purchases)
	Context.QuantCount = 0
	Context.MatchQuants = 0
	Context.WaveRemaining = 0
	Context.WaveFails = 0
	Context.ArmorLead = 0
	Context.WaveCooldown = 0
	Context.NeutralCount = 0
	Context.BackfillCount = 0
	Context.DefenderCount = 0
	Context.OfficerCount = 0
	Context.AtRifleCount = 0
	Context.RatioCount = 0
	Context.AuxOwed = 0
	Context.Cappers = {}
	Context.SpawnQueue = {}
	Context.LastSpawn = {}
	Context.FailCooldown = {}
	Context.PrevOwned = {}
	Context.LostStamp = {}
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
	local field = GetFieldCounts()
	print("[AISPAWN] " .. tag .. " mq=" .. tostring(Context.MatchQuants)
		.. " phase=" .. CurrentPhase(Context.MatchQuants / QuantsPerSec).name
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
		local pname = CurrentPhase(Context.MatchQuants / QuantsPerSec).name
		if g.phase ~= pname then
			g.phase = pname
			print("[AISPAWN] GROUP_UP id=" .. tostring(Context.FillGroup) .. " phase=" .. pname)
		end
		if ok then
			g.pending = (g.pending or 0) + 1
			Context.SpawnQueue[#Context.SpawnQueue + 1] =
				{ kind = "group", info = unit, slot = Context.FillGroup }
		end
		-- size reflects committed fills (live members + pending), since the member for THIS
		-- spawn lands a quant later via OnGameSpawn.
		print("[AISPAWN] GROUP_FILL id=" .. tostring(Context.FillGroup)
			.. " tier=" .. tostring(TierOf(unit))
			.. " try=" .. tostring(unit.unit)
			.. " ok=" .. tostring(ok)
			.. " size=" .. tostring(GroupMemberCount(g) + (g.pending or 0)) .. "/" .. tostring(g.size))
	end
	if not ok then
		Context.FailCooldown[unit.unit] = Context.MatchQuants
	else
		-- Advance the ratio/aux cycle on a successful spawn.
		if TierOf(unit) == nil then
			if Context.AuxOwed > 0 then Context.AuxOwed = Context.AuxOwed - 1 end
		else
			local utier = TierOf(unit)
			if Context.ArmorLead > 0 and (utier == "heavy" or utier == "medium") then
				Context.ArmorLead = Context.ArmorLead - 1
			end
			Context.RatioCount = Context.RatioCount + 1
			local phase = CurrentPhase(Context.MatchQuants / QuantsPerSec)
			if Context.RatioCount >= CycleSize(phase) then
				Context.RatioCount = 0
				Context.AuxOwed = AuxPerCycle
			end
		end
	end
	UpdateUnitToSpawn(Context.Purchase)
	if ok then return "ok" else return "fail" end
end

function OnGameQuant()
	Context.MatchQuants = Context.MatchQuants + 1
	Context.QuantCount = Context.QuantCount + 1

	-- Track flags we just lost (were ours last tick, now enemy) for recapture priority.
	for i, flag in pairs(BotApi.Scene.Flags) do
		local ownedNow = (flag.occupant == BotApi.Instance.team)
		if Context.PrevOwned[flag.name] and flag.occupant == BotApi.Instance.enemyTeam then
			Context.LostStamp[flag.name] = Context.MatchQuants
		end
		Context.PrevOwned[flag.name] = ownedNow
	end

	-- Refresh group targets each quant (re-pick if gone or nil).
	UpdateGroupTargets()

	-- Start a wave every WaveIntervalNow() quants (shorter when losing; only when
	-- no wave is in progress).
	if Context.QuantCount >= WaveIntervalNow() and Context.WaveRemaining == 0 then
		Context.QuantCount = 0
		local phase = CurrentPhase(Context.MatchQuants / QuantsPerSec)
		local budget = math.floor(phase.budget * LosingBudgetMult())
		Context.WaveRemaining = budget
		Context.WaveFails = 0
		Context.WaveCooldown = 0
		-- Front-load the phase's armor quota (heaviest first) before the ratio picker.
		Context.ArmorLead = (phase.targets.heavy or 0) + (phase.targets.medium or 0)
		ManageGroups()
		local ng = 0
		for i = 1, MaxGroups do if Context.Groups[i] then ng = ng + 1 end end
		print("[AISPAWN] WAVE mq=" .. tostring(Context.MatchQuants)
			.. " t=" .. tostring(math.floor(Context.MatchQuants / QuantsPerSec))
			.. " phase=" .. phase.name .. " budget=" .. tostring(budget)
			.. " deficit=" .. tostring(FlagDeficit())
			.. " groups=" .. tostring(ng))
	end

	-- Drive the in-progress wave: one Spawn every WaveSpawnSpacing quants (the
	-- engine accepts ~1 spawn per tick, so attempts must be spread across quants).
	if Context.WaveRemaining > 0 then
		Context.BackfillCount = 0 -- no idle backfill while a wave is running
		Context.WaveCooldown = Context.WaveCooldown - 1
		if Context.WaveCooldown <= 0 then
			Context.WaveCooldown = WaveSpawnSpacing
			Context.FillGroup = GroupToFill()
			if Context.FillGroup ~= nil and OwnedSquadCount() < MaxLiveSquads then
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
		Context.BackfillCount = Context.BackfillCount + 1
		Context.DefenderCount = Context.DefenderCount + 1
		if Context.DefenderCount >= DefenderInterval
		and HeldFlagCount() > 0 and LiveMGCount() < DefenderCap then
			Context.DefenderCount = 0
			local mg = GetMGUnit()
			if mg then
				Context.SpawnInfo = mg -- routed as a defender (DefenderClasses[MG]=true)
				local ok = BotApi.Commands:Spawn(mg.unit, MaxSquadSize)
				print("[AISPAWN] DEFENDER try=" .. tostring(mg.unit) .. " ok=" .. tostring(ok))
				if ok then
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "trickle", info = mg }
				else
					Context.FailCooldown[mg.unit] = Context.MatchQuants
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
		elseif Context.BackfillCount >= BackfillInterval then
			Context.BackfillCount = 0
			Context.FillGroup = GroupToFill()
			if Context.FillGroup ~= nil and OwnedSquadCount() < MaxLiveSquads then
				AttemptSpawn("BACKFILL")
			end
		end
	end

	-- Neutral-flag capper trickle, independent of the wave cadence.
	Context.NeutralCount = Context.NeutralCount + 1
	if Context.NeutralCount >= NeutralInterval then
		Context.NeutralCount = 0
		if CountNeutralFlags() > 0 then
			local line = GetLineUnit()
			if line then
				local ok = BotApi.Commands:Spawn(line.unit, 1) -- single soldier, not a full squad
				print("[AISPAWN] CAPPER try=" .. tostring(line.unit)
					.. " ok=" .. tostring(ok))
				if ok then
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "capper", info = line }
				end
			end
		end
	end

	-- Officer keep-alive trickle: after the unlock, maintain OfficerCap officers parked
	-- at the spawn. They are spawned here (never via the ratio/aux pool) so OnGameSpawn
	-- can withhold their capture order and leave them safe in the rear.
	Context.OfficerCount = Context.OfficerCount + 1
	if Context.OfficerCount >= OfficerInterval then
		Context.OfficerCount = 0
		if Context.MatchQuants / QuantsPerSec >= OfficerUnlock
		and LiveOfficerCount() < OfficerCap then
			local off = GetOfficerUnit()
			if off then
				Context.SpawnInfo = off
				local ok = BotApi.Commands:Spawn(off.unit, MaxSquadSize)
				print("[AISPAWN] OFFICER try=" .. tostring(off.unit) .. " ok=" .. tostring(ok))
				if ok then
					Context.SpawnQueue[#Context.SpawnQueue + 1] = { kind = "trickle", info = off }
				else
					Context.FailCooldown[off.unit] = Context.MatchQuants
				end
				UpdateUnitToSpawn(Context.Purchase)
			end
		end
	end

	-- AT-rifle keep-alive: from mid phase on, keep one AT rifle fielded as a GROUP member so it
	-- moves with and escorts the platoon (anti half-track) instead of wandering alone.
	Context.AtRifleCount = Context.AtRifleCount + 1
	if Context.AtRifleCount >= AtRifleInterval then
		Context.AtRifleCount = 0
		if CurrentPhase(Context.MatchQuants / QuantsPerSec).name ~= "early"
		and LiveAtRifleCount() < AtRifleCap
		and OwnedSquadCount() < MaxLiveSquads then
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
						g.pending = (g.pending or 0) + 1
						Context.SpawnQueue[#Context.SpawnQueue + 1] =
							{ kind = "group", info = atr, slot = slot }
					else
						Context.FailCooldown[atr.unit] = Context.MatchQuants
					end
					UpdateUnitToSpawn(Context.Purchase)
				end
			end
		end
	end

	for squadId in pairs(Context.FieldUnits) do
		if not BotApi.Scene:IsSquadExists(squadId) then
			local gi = Context.SquadGroup[squadId]
			if gi and Context.Groups[gi] then Context.Groups[gi].members[squadId] = nil end
			Context.SquadGroup[squadId] = nil
			Context.FieldUnits[squadId] = nil
			Context.Cappers[squadId] = nil
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

-- The group's attack flag: an ENEMY-held flag (never neutral), most-recently-lost first,
-- excluding excludeName (the other group's target). Returns a flag name, or nil.
function PickGroupTarget(excludeName)
	local best, bestStamp, bestK = nil, -1, -1
	for i, flag in pairs(BotApi.Scene.Flags) do
		if flag.occupant == BotApi.Instance.enemyTeam and flag.name ~= excludeName then
			local stamp = Context.LostStamp[flag.name]
			if stamp ~= nil then
				if stamp > bestStamp then best, bestStamp = flag.name, stamp end
			elseif bestStamp < 0 then
				local k = GetFlagPriority(flag)
				if k > bestK then best, bestK = flag.name, k end
			end
		end
	end
	return best
end

function CaptureFlag(squad)
	-- Group members: attack the group's shared target (membership overrides class role).
	local gi = Context.SquadGroup[squad]
	if gi and Context.Groups[gi] and Context.Groups[gi].target
	   and FlagAttackable(Context.Groups[gi].target) then
		BotApi.Commands:CaptureFlag(squad, Context.Groups[gi].target)
		return
	end
	-- Cappers chase neutral flags (trickle; never group members).
	if Context.Cappers[squad] then
		local flag = GetFlagToCapture(BotApi.Scene.Flags, CapperFlagPriority)
		if flag then BotApi.Commands:CaptureFlag(squad, flag.name) end
		return
	end
	-- Defenders (MG, AT, sniper, etc.) hold owned flags.
	if IsDefender(squad) then
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
		Context.LastSpawn[info.unit] = Context.MatchQuants
	end
	if d and d.kind == "capper" then
		Context.Cappers[args.squadId] = true
	elseif d and d.kind == "group" and d.slot and Context.Groups[d.slot] then
		local g = Context.Groups[d.slot]
		g.members[args.squadId] = true
		g.seeded = true
		g.pending = math.max(0, (g.pending or 0) - 1)
		Context.SquadGroup[args.squadId] = d.slot
	end
	-- Officers stay parked at the spawn (they hold the unit cap); everyone else gets a
	-- capture order.
	local entry = Context.FieldUnits[args.squadId]
	if not (entry and entry.class == UnitClass.Officer) then
		SetSquadOrder(CaptureFlag, args.squadId, OrderRotationPeriod)
	end
end

BotApi.Events:Subscribe(BotApi.Events.GameStart, OnGameStart)
BotApi.Events:Subscribe(BotApi.Events.GameEnd, OnGameStop)
BotApi.Events:Subscribe(BotApi.Events.Quant, OnGameQuant)
BotApi.Events:Subscribe(BotApi.Events.GameSpawn, OnGameSpawn)
