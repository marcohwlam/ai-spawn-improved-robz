dofile((arg[0]:gsub("axis_minor_spec%.lua$", "harness.lua")))

local function eq(got, want, msg)
	if got ~= want then error((msg or "") .. " expected " .. tostring(want) .. " got " .. tostring(got)) end
end

-- axis_minor faction: phases and bias
local jap_style = ResolvePhases("axis_minor")
eq(jap_style[1].upto, 650,  "axis_minor early ends at 650 (turan1 first medium)")
eq(jap_style[2].upto, 1500, "axis_minor mid ends at 1500 (panther first heavy)")
eq(jap_style[3].upto, 1000000000, "axis_minor late is open-ended")
eq(jap_style[3].targets.heavy, nil, "axis_minor late drops the heavy tier")
eq(jap_style[3].targets.medium, 2, "axis_minor late medium target is 2")

assert(FactionBias.axis_minor ~= nil, "axis_minor has a FactionBias entry")
eq(FactionBias.axis_minor.early.rifle, 1, "axis_minor early floors rifle")
eq(FactionBias.axis_minor.mid.attank,  1, "axis_minor mid floors attank")
eq(FactionBias.axis_minor.late.attank, 1, "axis_minor late floors attank")
eq(FactionBias.axis_minor.late.medium, 1, "axis_minor late floors medium")
print("axis_minor phases/bias OK")
