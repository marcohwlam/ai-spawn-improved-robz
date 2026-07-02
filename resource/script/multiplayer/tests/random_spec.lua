dofile((arg[0]:gsub("random_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- GetRandomItem must never return nil when total > 0, even if math.random() lands on the
-- exact float boundary between the last item's cumulative bound and 1.0 -- a plain
-- "fall off the loop" would silently hand back nil there, which every caller (capper/flag
-- targeting, unit picks) reads as "no candidate" and drops the order/spawn entirely.
local items = { "a", "b", "c" }
local function rate() return 1.0 end

local realRandom = math.random
math.random = function() return 0.999999999999999 end -- as close to 1.0 as a double allows
local got = GetRandomItem(items, rate)
math.random = realRandom
eq(got ~= nil, true, "GetRandomItem never returns nil when total > 0, even at the float boundary")
eq(got, "c", "boundary case still resolves to the last item deterministically")

-- Normal path: rnd = 0 always picks the first item.
math.random = function() return 0.0 end
local first = GetRandomItem(items, rate)
math.random = realRandom
eq(first, "a", "rnd=0 picks the first item")

-- total == 0 (all rates zero, e.g. every candidate filtered out) is still a legitimate nil.
math.random = function() return 0.5 end
local none = GetRandomItem(items, function() return 0 end)
math.random = realRandom
eq(none, nil, "total == 0 correctly returns nil (no candidates), not the fallback")

print("GetRandomItem OK")
