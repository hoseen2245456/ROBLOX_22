-- TrainingService: trains troops in the Barracks, Archery Range, Stable and Siege Workshop on a timer.
-- Location in Studio: ServerScriptService.Services.TrainingService (ModuleScript)
-- Rules followed:
--   * The client only asks (Remotes.TrainingAction). The server checks the building, the tier, the
--     count and the resources, then spends the resources and starts the timer.
--   * One batch at a time per building. Training does not use a builder (the worker never walks there),
--     and a building cannot train while it upgrades or upgrade while it trains.
--   * The timer is data.Timers["Train_<plotId>"] with EndsAt = os.time() + seconds. While the player is
--     online it gets one task.delay; batches that ended offline are added on load.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)

local TrainingService = {}

local PlayerDataService
local CityService
local lastRequest = {} -- [Player] = os.clock() of the last request

-- Every training plot: plotId -> troop type it trains
local plotTrains = {}
for _, plot in ipairs(GameConfig.CityLayout) do
	local trains = GameConfig.Buildings[plot.Type].Trains
	if trains then
		plotTrains[plot.Id] = trains
	end
end

local function timerId(plotId: string): string
	return "Train_" .. plotId
end

-- Returns the plan { TroopType, Cost, Seconds } or nil and the reason shown to the player
local function checkRequest(data, plotId: string, tier: number, count: number)
	local troopType = plotTrains[plotId]
	if not troopType then
		return nil, "This building does not train troops"
	end
	local building = data.Buildings[plotId]
	if not building then
		return nil, "Build it first"
	end
	if data.Timers["Build_" .. plotId] then
		return nil, "Upgrading, try again later"
	end
	if data.Timers[timerId(plotId)] then
		return nil, "Already training"
	end
	local tierDef = GameConfig.TroopTiers[tier]
	if not tierDef then
		return nil, "Unknown tier"
	end
	if building.Level < tierDef.UnlockAt then
		return nil, ("T%d needs %s Lv %d"):format(tier, GameConfig.Buildings[building.Type].DisplayName, tierDef.UnlockAt)
	end
	if count > GameConfig.GetMaxTrainBatch(building.Level) then
		return nil, "Too many troops for one batch"
	end
	local cost = GameConfig.GetTrainCost(tier, count)
	for resource, amount in pairs(cost) do
		if (data.Resources[resource] or 0) < amount then
			return nil, "Not enough " .. resource
		end
	end
	return { TroopType = troopType, Cost = cost, Seconds = GameConfig.GetTrainSeconds(tier, count) }
end

-- Adds a finished batch to the data. Returns true if it was still active.
local function applyTimer(data, id: string, timer): boolean
	if data.Timers[id] ~= timer then
		return false -- already finished or replaced
	end
	data.Timers[id] = nil
	local counts = data.Troops[timer.TroopType]
	counts[timer.Tier] = (counts[timer.Tier] or 0) + timer.Count
	data.Stats.Power += timer.Count * GameConfig.TroopTiers[timer.Tier].Power
	return true
end

local function schedule(player: Player, data, id: string, timer)
	task.delay(math.max(0, timer.EndsAt - os.time()), function()
		-- The player may have left (and even rejoined with a fresh data table) since this was scheduled
		if PlayerDataService.GetData(player) ~= data or data.Timers[id] ~= timer then
			return
		end
		if os.time() < timer.EndsAt then
			schedule(player, data, id, timer)
			return
		end
		applyTimer(data, id, timer)
		CityService.RefreshPlot(player, timer.Target)
		PlayerDataService.Sync(player)
	end)
end

-- On load: add every batch that ended while the player was offline, schedule the rest
local function onLoaded(player: Player)
	local data = PlayerDataService.GetData(player)
	if not data then
		return
	end
	local now = os.time()
	local finished = {}
	for id, timer in pairs(data.Timers) do
		if timer.Kind == "Train" then
			if timer.EndsAt <= now then
				applyTimer(data, id, timer)
				table.insert(finished, ("%d T%d %s"):format(timer.Count, timer.Tier, timer.TroopType))
			else
				schedule(player, data, id, timer)
			end
		end
	end
	if #finished > 0 then
		print("[TrainingService]", player.Name, "trained offline:", table.concat(finished, ", "))
		PlayerDataService.Sync(player)
	end
end

local function onAction(player: Player, action: any, plotId: any, tier: any, count: any)
	if action ~= "Train" or type(plotId) ~= "string" or type(tier) ~= "number" or type(count) ~= "number" then
		return { Ok = false, Error = "Bad request" }
	end
	if tier % 1 ~= 0 or count % 1 ~= 0 or count < 1 then
		return { Ok = false, Error = "Bad request" } -- also rejects NaN and inf
	end
	local clock = os.clock()
	if lastRequest[player] and clock - lastRequest[player] < GameConfig.Remotes.MinRequestInterval then
		return { Ok = false, Error = "Too many requests" }
	end
	lastRequest[player] = clock

	local data = PlayerDataService.GetData(player)
	if not data then
		return { Ok = false, Error = "Your kingdom is still loading" }
	end
	local plan, reason = checkRequest(data, plotId, tier, count)
	if not plan then
		return { Ok = false, Error = reason }
	end

	-- No yield between the check and here, so two requests can never spend the same resources
	for resource, amount in pairs(plan.Cost) do
		data.Resources[resource] -= amount
	end
	local now = os.time()
	local timer = {
		Kind = "Train",
		Target = plotId,
		TroopType = plan.TroopType,
		Tier = tier,
		Count = count,
		StartedAt = now,
		EndsAt = now + plan.Seconds,
	}
	local id = timerId(plotId)
	data.Timers[id] = timer
	schedule(player, data, id, timer)

	CityService.RefreshPlot(player, plotId)
	PlayerDataService.Sync(player)
	return { Ok = true, EndsAt = timer.EndsAt }
end

-- Admin: start a free 1-troop T1 batch on this plot for `seconds` (to watch the training animation).
-- Returns false if the plot can't train or is busy.
function TrainingService.StartFree(player: Player, data, plotId: string, seconds: number): boolean
	local building = data.Buildings[plotId]
	local def = building and GameConfig.Buildings[building.Type]
	local id = timerId(plotId)
	if not def or not def.Trains or data.Timers[id] or data.Timers["Build_" .. plotId] then
		return false
	end
	local now = os.time()
	local timer = { Kind = "Train", Target = plotId, TroopType = def.Trains, Tier = 1, Count = 1, StartedAt = now, EndsAt = now + seconds }
	data.Timers[id] = timer
	schedule(player, data, id, timer)
	CityService.RefreshPlot(player, plotId)
	return true
end

-- Admin: finish every training batch of this player now. Returns how many finished.
function TrainingService.FinishAll(player: Player): number
	local data = PlayerDataService.GetData(player)
	if not data then
		return 0
	end
	local count = 0
	for id, timer in pairs(table.clone(data.Timers)) do
		if timer.Kind == "Train" and applyTimer(data, id, timer) then
			CityService.RefreshPlot(player, timer.Target)
			count += 1
		end
	end
	return count
end

function TrainingService.Start(dataService, cityService)
	PlayerDataService = dataService
	CityService = cityService

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("TrainingAction") :: RemoteFunction
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "TrainingAction"
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onAction

	PlayerDataService.Loaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
end

return TrainingService
