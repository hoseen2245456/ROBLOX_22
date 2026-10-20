-- AttackService: an army reaches another player's castle (phase 2). Finds the defender's data wherever it
-- is, runs the battle on it (BattleService.DefendCastle) and returns the fight for the attacker.
-- Location in Studio: ServerScriptService.Services.AttackService (ModuleScript)
-- Rules followed:
--   * Shared data changes with UpdateAsync: an offline defender's saved data is changed in one
--     PlayerDataService.UpdateOffline call (it refuses if a live server owns that player).
--   * Defender on this server: their loaded data is changed directly and synced.
--   * Defender online on another server: that server owns their data, so it is asked through
--     MessagingService to run the battle and send the fight back. No answer in Castle.AnswerSeconds =
--     no battle (the army turns back).
--   * MarchService calls Attack at the arrival time; nothing comes from the client.

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local BattleService = require(script.Parent.BattleService)
local Cfg = GameConfig.Battle.Castle

local AttackService = {}

local PlayerDataService
local topic = Cfg.Topic .. GameConfig.Map.KingdomId
local JOB_ID = game.JobId ~= "" and game.JobId or HttpService:GenerateGUID(false)
local waiting = {} -- [attack Id] = thread waiting for another server's answer
local answers = {} -- [attack Id] = fight

local function note(text: string, name: string)
	return { Note = text, Defender = { Name = name, Start = 0, Lost = 0 } }
end

local function publish(message): boolean
	local ok, err = pcall(function()
		MessagingService:PublishAsync(topic, message)
	end)
	if not ok then
		warn("[AttackService] PublishAsync failed:", err)
	end
	return ok
end

-- Battle on a defender who is loaded on this server. Returns the fight.
local function defendHere(player: Player, def, a)
	local fight = BattleService.DefendCastle(def, a)
	if not fight.Note then
		PlayerDataService.Sync(player)
	end
	return fight
end

-- Another server asks: is this defender here? Then fight and answer.
local function onMessage(message)
	local m = message.Data
	if type(m) ~= "table" then
		return
	end
	if m.T == "Hit" and type(m.A) == "table" then
		local player, def = PlayerDataService.FindByUserId(m.To)
		if not def then
			return -- not here (or still loading): the attacker's server times out
		end
		local fight = defendHere(player, def, m.A)
		print(("[AttackService] %s defended against %s for another server"):format(player.Name, tostring(m.A.AttackerName)))
		publish({ T = "Res", Job = m.Job, Id = m.A.Id, F = fight })
	elseif m.T == "Res" and m.Job == JOB_ID then
		local thread = waiting[m.Id]
		if thread then
			waiting[m.Id] = nil
			answers[m.Id] = m.F
			task.spawn(thread)
		end
	end
end

-- Ask the other servers; waits up to AnswerSeconds. Returns the fight or nil.
local function askOtherServers(targetId: number, a)
	waiting[a.Id] = coroutine.running()
	if not publish({ T = "Hit", To = targetId, Job = JOB_ID, A = a }) then
		waiting[a.Id] = nil
		return nil
	end
	task.delay(Cfg.AnswerSeconds, function()
		local thread = waiting[a.Id]
		if thread then
			waiting[a.Id] = nil
			task.spawn(thread)
		end
	end)
	coroutine.yield()
	local fight = answers[a.Id]
	answers[a.Id] = nil
	return fight
end

-- The army of `player` reached the castle in march.TargetId. Yields (DataStore / other servers).
-- Changes the attacker's march and data through BattleService.SettleAttack. Returns the report.
function AttackService.Attack(player: Player, data, march)
	local targetId = march.TargetId
	local name = march.TargetName or "Castle"
	local fight
	if type(targetId) ~= "number" or targetId == player.UserId then
		fight = note("No castle there", name)
	else
		local a = {
			Army = march.Troops,
			AttackerName = player.Name,
			DefenderName = name,
			X = march.To.X,
			Y = march.To.Y,
			At = march.ArriveAt,
			Id = player.UserId .. "_" .. march.Id,
		}
		local defPlayer, def = PlayerDataService.FindByUserId(targetId)
		if def then
			fight = defendHere(defPlayer, def, a)
		elseif defPlayer then
			fight = note("The castle was busy (try again)", name)
		else
			local status = PlayerDataService.UpdateOffline(targetId, function(old)
				if not old then
					fight = note("No castle there", name)
					return nil
				end
				fight = BattleService.DefendCastle(old, a)
				return if fight.Note then nil else old
			end)
			if status == "Locked" then
				fight = askOtherServers(targetId, a) or note("The castle could not be reached (try again)", name)
			elseif status == "Failed" then
				fight = note("The castle could not be reached (try again)", name)
			end
		end
	end
	return BattleService.SettleAttack(data, march, "Castle", nil, fight)
end

function AttackService.Start(dataService)
	PlayerDataService = dataService
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(topic, onMessage)
		end)
		if not ok then
			warn("[AttackService] SubscribeAsync failed, attacks on players in other servers won't work:", err)
		end
	end)
end

return AttackService
