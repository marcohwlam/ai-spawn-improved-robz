dofile((arg[0]:gsub("mapname_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- variant suffix stripped
eq(ParseMapName('Starting "multi/2v2_bastogne:battle_zones"'), "2v2_bastogne", "single")

-- last Starting line wins (log accumulates across matches)
local two = 'Starting "multi/2v2_bastogne:battle_zones"\nnoise\nStarting "multi/2v2_gsm_westland:battle_zones"\n'
eq(ParseMapName(two), "2v2_gsm_westland", "last wins")

-- no colon variant
eq(ParseMapName('Starting "multi/1v1_nikolaev"'), "1v1_nikolaev", "no colon")

-- surrounding noise, real-log shape
local noisy = '[00:00:53] foo\nStarting "multi/2v2_mamayev_kurgan:battle_zones"\n[00:00:54] bar\n'
eq(ParseMapName(noisy), "2v2_mamayev_kurgan", "noisy")

-- no match
eq(ParseMapName("no starting line here"), nil, "no match")
eq(ParseMapName(nil), nil, "nil input")

-- TailRead reads a real file and the parse pipeline recovers the map name.
do
	local tmp = os.tmpname()
	local f = assert(io.open(tmp, "w"))
	f:write('prologue line\nStarting "multi/2v2_testmap:battle_zones"\nepilogue line\n')
	f:close()
	eq(ParseMapName(TailRead(tmp)), "2v2_testmap", "tailread pipeline")
	eq(TailRead("/no/such/path/game.log"), nil, "tailread missing file")
	os.remove(tmp)
end

-- ReadMapName never errors and returns a string or nil regardless of environment.
do
	local r = ReadMapName()
	assert(r == nil or type(r) == "string", "ReadMapName returns string|nil")
end

print("mapname OK")
