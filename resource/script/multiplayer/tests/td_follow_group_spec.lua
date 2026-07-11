dofile((arg[0]:gsub("td_follow_group_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- Drive TryCappedTrickle directly. Neutralize every gate except the group-existence check:
--  * liveCountFn = 0 and cap = 99  -> under cap
--  * floorValue = 0                -> floor met (relies on intervalOk instead)
--  * lastTimeField reset to 0 with a large clock -> intervalOk true
--  * one captured flag             -> HeldFlagCount() > 0
--  * PendingSpawn nil              -> SpawnSlotFree() true
UpdateUnitToSpawn = function() end -- PIter/Purchases plumbing is irrelevant to these assertions

local stubUnit = { class = UnitClass.ATTank, unit = "stub_td" }
local function baseCfg(extra)
	local cfg = {
		lastTimeField = "LastAtTankTime", interval = 1, cap = 99,
		liveCountFn = function() return 0 end,
		unitPickerFn = function() return stubUnit end,
		label = "ATTANK", floorValue = 0,
	}
	for k, v in pairs(extra or {}) do cfg[k] = v end
	return cfg
end
local function reset()
	Context.PendingSpawn = nil
	Context.LastAtTankTime = 0
	Context.GameClock = 1000
	BotApi.Scene.Flags = { { occupant = BotApi.Instance.team } }  -- one held flag
end

-- (A) No groupSlot: legacy path still claims kind="trickle".
reset()
Context.Groups = {}
local firedA = TryCappedTrickle(baseCfg())
eq(firedA, true, "trickle fires when gates pass")
eq(Context.PendingSpawn.kind, "trickle", "no groupSlot -> kind trickle (regression)")

-- (B) groupSlot set but the group is absent: does NOT fire and does NOT stamp lastTimeField.
reset()
Context.Groups = {}                                   -- no main group
local firedB = TryCappedTrickle(baseCfg({ groupSlot = 1, aux = true }))
eq(firedB, false, "escort trickle skips when its group is absent")
eq(Context.LastAtTankTime, 0, "skipped escort must NOT consume the interval")
eq(Context.PendingSpawn, nil, "skipped escort claims no slot")

-- (C) groupSlot set and the group exists: claims kind="group", slot=1, aux=true.
reset()
Context.Groups = { [1] = { members = {}, auxMembers = {}, target = "f1" } }
local firedC = TryCappedTrickle(baseCfg({ groupSlot = 1, aux = true }))
eq(firedC, true, "escort trickle fires when its group exists")
eq(Context.PendingSpawn.kind, "group", "escort claims a group slot")
eq(Context.PendingSpawn.slot, 1, "escort attaches to the main group")
eq(Context.PendingSpawn.aux, true, "escort is an aux member")

-- (D) ATTank is no longer a defender class (it now follows the group).
eq(DefenderClasses[UnitClass.ATTank], nil, "ATTank removed from DefenderClasses")
eq(DefenderClasses[UnitClass.MG], true, "MG stays a defender")

Context.Groups = {}
print("td follow group OK")
