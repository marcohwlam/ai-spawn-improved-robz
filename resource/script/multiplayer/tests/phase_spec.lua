dofile((arg[0]:gsub("phase_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- TierOf
eq(TierOf({class = UnitClass.Infantry, inf = "rifle"}), "rifle", "rifle inf is rifle")
eq(TierOf({class = UnitClass.Infantry, inf = "smg"}),   "smg",   "smg inf is smg")
eq(TierOf({class = UnitClass.Infantry, mech = true, inf = "smg"}), "light", "mech smg is light")
eq(TierOf({class = UnitClass.Infantry}), "rifle", "plain inf defaults to rifle")
eq(TierOf({class = UnitClass.Infantry, flame = true}), nil, "flamer is aux")
eq(TierOf({class = UnitClass.Tank, recharge = 420}), "light", "pz2l light")
eq(TierOf({class = UnitClass.Tank, recharge = 550}), "medium", "550 is medium")
eq(TierOf({class = UnitClass.Tank, recharge = 950}), "medium", "pz4h medium")
eq(TierOf({class = UnitClass.HeavyTank, recharge = 2160}), "heavy", "tiger heavy")
eq(TierOf({class = UnitClass.Vehicle, recharge = 30}), "light", "halftrack light")
eq(TierOf({class = UnitClass.Infantry, mech = true}), "light", "mech inf is light")
eq(TierOf({class = UnitClass.ATInfantry}), nil, "AT is aux")
eq(TierOf({class = UnitClass.MG}), nil, "MG is aux")
print("TierOf OK")

-- CurrentPhase
eq(CurrentPhase(0).name,   "early", "t0 early")
eq(CurrentPhase(179).name, "early", "179 early")
eq(CurrentPhase(180).name, "mid",   "180 mid")
eq(CurrentPhase(479).name, "mid",   "479 mid")
eq(CurrentPhase(480).name, "late",  "480 late")
eq(CurrentPhase(99999).name, "late","late stays late")

-- DecideTier: empty field, all eligible -> rifle has the largest absolute deficit (weight 3)
local late = CurrentPhase(480)
local empty = { heavy = 0, medium = 0, light = 0, rifle = 0, smg = 0, aux = 0 }
local allOk = { heavy = true, medium = true, light = true, rifle = true, smg = true }
eq(DecideTier(late, empty, false, allOk), "rifle", "empty field wants rifle first")

-- DecideTier: rifle satisfied -> next deficit is light (weight 2)
local f2 = { heavy = 0, medium = 0, light = 0, rifle = 4, smg = 0, aux = 0 }
eq(DecideTier(late, f2, false, allOk), "light", "after rifle, light")

-- DecideTier: only rifle eligible (tanks on cooldown) -> rifle
eq(DecideTier(late, f2, false, { rifle = true }), "rifle", "fallback to eligible tier")

-- DecideTier: enemy tanks bumps medium/heavy deficit
local f3 = { heavy = 1, medium = 1, light = 2, rifle = 4, smg = 0, aux = 0 }
local pick = DecideTier(late, f3, true, allOk)
assert(pick == "medium" or pick == "heavy", "enemy tanks leans armor, got " .. tostring(pick))

-- DecideTier: smg under-filled -> picks smg over rifle and light
-- Use light=1 so smg is strictly more under-filled (avoids tie with light).
local fRifled = { heavy = 0, medium = 0, light = 1, rifle = 3, smg = 0, aux = 0 }
local earlyOk = { light = true, rifle = true, smg = true }
local early = CurrentPhase(0)
eq(DecideTier(early, fRifled, false, earlyOk), "smg", "smg picked when rifle and light filled and smg empty")

-- DecideTier: losing bumps smg weight to 2; smg under-filled -> picks smg
local fLosing = { heavy = 0, medium = 0, light = 0, rifle = 3, smg = 0, aux = 0 }
eq(DecideTier(early, fLosing, false, earlyOk, true), "smg", "losing smg bump picks smg")
print("phase OK")

-- Group helpers: elite flag is orthogonal to tier, and empty-group helpers return zero.
eq(TierOf({class = UnitClass.Infantry, inf = "rifle", elite = true}), "rifle", "elite rifle still rifle tier")
eq(TierOf({class = UnitClass.Infantry, inf = "smg",   elite = true}), "smg",   "elite smg still smg tier")
assert(type(CountByTier)      == "function", "CountByTier defined")
assert(type(GroupMemberCount) == "function", "GroupMemberCount defined")
assert(type(GroupEliteCount)  == "function", "GroupEliteCount defined")
assert(type(ManageGroups)     == "function", "ManageGroups defined")
assert(type(GroupToFill)      == "function", "GroupToFill defined")
assert(type(CompactGroups)    == "function", "CompactGroups defined")
local emptyGroup = { members = {}, size = 8 }
local ec = CountByTier(emptyGroup)
eq(ec.rifle, 0, "CountByTier empty group rifle=0")
eq(ec.smg,   0, "CountByTier empty group smg=0")
eq(GroupMemberCount(emptyGroup), 0, "GroupMemberCount empty=0")
eq(GroupEliteCount(emptyGroup),  0, "GroupEliteCount empty=0")
print("group helpers OK")
