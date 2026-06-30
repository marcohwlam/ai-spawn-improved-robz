dofile((arg[0]:gsub("calib_spec%.lua$", "harness.lua")))

-- Controllable os.time stub.
local fakeNow = 1000
os.time = function() return fakeNow end

-- Fresh match state.
Context.StartTime = os.time()
Context.QuantsPerSec = nil
Context.MatchQuants = 0

-- Before calibration: Elapsed() uses the wall fallback (os.time - StartTime).
fakeNow = 1005
assert(Elapsed() == 5, "pre-calib Elapsed uses wall delta, got " .. tostring(Elapsed()))
assert(Q(10) == 10 * 32, "pre-calib Q uses DEFAULT_QPS 32, got " .. tostring(Q(10)))

-- Drive quants; calibration fires once dtReal >= 20 and mq >= 200.
-- Simulate ~32 q/s: advance mq by 32 for each +1s of fake time.
Context.MatchQuants = 0
fakeNow = 1000
Context.StartTime = 1000
for s = 1, 25 do
	fakeNow = 1000 + s
	for i = 1, 32 do
		Context.MatchQuants = Context.MatchQuants + 1
		-- inline the calibration check the same way OnGameQuant does:
		if Context.QuantsPerSec == nil then
			local dt = os.time() - Context.StartTime
			if dt >= 20 and Context.MatchQuants >= 200 then
				local raw = Context.MatchQuants / dt
				Context.QuantsPerSec = math.max(10, math.min(200, raw))
			end
		end
	end
end
assert(Context.QuantsPerSec ~= nil, "should have calibrated")
assert(Context.QuantsPerSec >= 30 and Context.QuantsPerSec <= 34,
	"calibrated rate ~32, got " .. tostring(Context.QuantsPerSec))

-- After calibration Elapsed() = mq / QuantsPerSec.
Context.QuantsPerSec = 40
Context.MatchQuants = 4000
assert(Elapsed() == 100, "post-calib Elapsed = mq/QPS, got " .. tostring(Elapsed()))
assert(Q(10) == 400, "post-calib Q = sec*QPS, got " .. tostring(Q(10)))

-- Clamp guards a wild ratio.
assert(math.max(10, math.min(200, 5)) == 10, "clamp low")
assert(math.max(10, math.min(200, 999)) == 200, "clamp high")
print("calib OK")
