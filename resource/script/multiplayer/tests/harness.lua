-- Offline harness: load bot.lua without the game engine.
-- Run tests from the multiplayer dir: `cd resource/script/multiplayer && lua tests/phase_spec.lua`.
local MROOT = "."

local realRequire = require
require = function(mod)
	if tostring(mod):find("bot%.data") then
		return dofile(MROOT .. "/bot.data.lua")
	end
	if tostring(mod):find("flag_sectors") then
		return dofile(MROOT .. "/flag_sectors.lua")
	end
	if tostring(mod):find("gun_ratings") then
		return dofile(MROOT .. "/gun_ratings.lua")
	end
	return realRequire(mod)
end

local noop = function() end
BotApi = {
	Events = { Subscribe = noop, GameStart = 1, GameEnd = 2, Quant = 3, NonQuant = 4, GameSpawn = 5,
	           SetTimer = noop, KillTimer = noop, SetQuantTimer = noop, KillQuantTimer = noop },
	Commands = { Income = function() return 5 end, EnemyHasTanks = function() return false end,
	             Spawn = function() return true end, CaptureFlag = noop, SayChat = noop },
	Instance = { team = 1, enemyTeam = 2, army = "ger", teamSize = 8, hostId = 1, playerId = 1 },
	Scene = { Flags = {}, Squads = {}, IsSquadExists = function() return true end },
}

dofile(MROOT .. "/bot.lua")
return _G
