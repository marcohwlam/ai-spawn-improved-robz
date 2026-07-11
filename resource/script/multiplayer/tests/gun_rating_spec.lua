dofile((arg[0]:gsub("gun_rating_spec%.lua$", "harness.lua")))

-- Globals the function under test depends on (bot.lua defines these; the harness
-- loads bot.lua, here we just set the data the test controls).
GunRating = { sdkfz222 = 46, pz3_m = 97, weakcar = 20, uebertank = 200 }
GunRatingRef = 60
GunRatingMulMin = 0.5
GunRatingMulMax = 1.8

local enemyHasTanks = false
BotApi = BotApi or {}
BotApi.Commands = BotApi.Commands or {}
function BotApi.Commands:EnemyHasTanks() return enemyHasTanks end

local function approx(a, b) return math.abs(a - b) < 1e-6 end

-- 1. no enemy armor -> no-op
enemyHasTanks = false
assert(GunRatingMul("pz3_m") == 1.0, "no enemy armor must be a no-op")

-- 2. enemy armor + rating -> rating/ref
enemyHasTanks = true
assert(approx(GunRatingMul("sdkfz222"), 46 / 60), "46mm -> 0.7667x")
assert(approx(GunRatingMul("pz3_m"), 97 / 60), "97mm -> 1.617x")

-- 3. unrated unit with enemy armor -> 1.0
assert(GunRatingMul("no_such_unit") == 1.0, "nil rating must be a no-op")

-- 4. clamp floor / ceiling
assert(approx(GunRatingMul("weakcar"), 0.5), "20mm clamps to floor 0.5")
assert(approx(GunRatingMul("uebertank"), 1.8), "200mm clamps to ceiling 1.8")

print("gun_rating_spec: OK")
