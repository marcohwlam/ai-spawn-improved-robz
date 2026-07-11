dofile((arg[0]:gsub("arty_cap_spec%.lua$", "harness.lua")))

-- FlagDeficit = (enemy-held flags) - (own-held flags). Drive it via BotApi.Scene.Flags.
-- IsCapturedFlag/IsEnemyFlag classify by `flag.occupant` vs BotApi.Instance.team/enemyTeam.
local function setFlags(ownCount, enemyCount)
	local flags = {}
	for i = 1, ownCount   do flags[#flags + 1] = { occupant = BotApi.Instance.team } end
	for i = 1, enemyCount do flags[#flags + 1] = { occupant = BotApi.Instance.enemyTeam } end
	BotApi.Scene.Flags = flags
end

Context.ArmorBankUntil = 0
Context.GameClock = 1000

-- Even flags (deficit 0): default cap 1.
setFlags(3, 3)
assert(FlagDeficit() == 0, "sanity: even flags => deficit 0")
assert(ArtyCapNow() == 1, "even/ahead: ArtyCapNow is 1")

-- Small deficit (1-2 behind): still 1.
setFlags(2, 4)
assert(FlagDeficit() == 2, "sanity: deficit 2")
assert(ArtyCapNow() == 1, "small deficit keeps ArtyCapNow at 1")

-- Badly losing (deficit >= 3): 0.
setFlags(1, 4)
assert(FlagDeficit() == 3, "sanity: deficit 3")
assert(ArtyCapNow() == 0, "badly losing (deficit>=3): ArtyCapNow is 0")

-- Bank window active overrides everything: 0 even when even on flags.
setFlags(3, 3)
Context.ArmorBankUntil = 5000   -- 1000 < 5000 => active
assert(ArtyCapNow() == 0, "bank window active: ArtyCapNow is 0 regardless of deficit")
Context.ArmorBankUntil = 0

-- Baseline constant lowered to 1.
assert(ArtyCap == 1, "ArtyCap baseline is 1")

print("arty cap OK")
