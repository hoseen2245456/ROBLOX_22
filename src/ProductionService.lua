-- ProductionService: resource buildings (Farm, Lumber Mill, Quarry, Gold Mine) fill up over time and
-- the player collects by tapping the bubble above them.
-- Location in Studio: ServerScriptService.Services.ProductionService (ModuleScript)
-- Rules followed:
--   * Nothing ticks. Each producing building stores LastCollected = os.time(); the amount is worked out
--     only when it is collected: per-hour rate x hours, capped at Production.BaseCapacityHours.
--   * The client only asks (Remotes.ProductionAction). The server works out the amount itself.
--   * A building does not produce while it is being upgraded. Starting an upgrade collects what it
--     held (BuildingService calls CollectPlot), and production restarts when the upgrade ends.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)

local ProductionService = {}

local PlayerDataService
local CityService
local lastRequest = {} -- [Player] = os.clock() of the last request

local function producedResource(building): string?
	local def = building and GameConfig.Buildings[building.Type]
	return def and def.Produces
end

local function isUpgrading(data, plotId: string): boolean
	return data.Timers["Build_" .. plotId] ~= nil
end

-- What a building holds right now (0 while it is upgrading)
local function storedAmount(data, plotId: string, now: number): number
	local building = data.Buildings[plotId]
	local resource = producedResource(building)
	if not resource or not building.LastCollected or isUpgrading(data, plotId) then
		return 0
	end
	local hours = math.max(0, now - building.LastCollected) / 3600
	local amount = GameConfig.GetProductionPerHour(resource, building.Level) * hours
	return math.floor(math.min(amount, GameConfig.GetProductionCapacity(resource, building.Level)))
end

-- Moves what one building holds into the player's resources. Does not sync or refresh the plot.
-- Returns the resource and the amount collected.
function ProductionService.CollectPlot(data, plotId: string): (string?, number)
	local building = data.Buildings[plotId]
	local resource = producedResource(building)
	if not resource then
		return nil, 0
	end
	local now = os.time()
	local amount = storedAmount(data, plotId, now)
	building.LastCollected = now
	data.Resources[resource] = (data.Resources[resource] or 0) + amount
	return resource, amount
end

-- A building that just reached a new level starts producing from the moment its timer ended
function ProductionService.StartProducing(building, since: number)
	if producedResource(building) then
		building.LastCollected = since
	end
end

-- Tapping one bubble collects every ready building of that resource (like Rise of Kingdoms)
local function collectAll(player: Player, data, resource: string): number
	local total = 0
	local now = os.time()
	for plotId, building in pairs(data.Buildings) do
		if producedResource(building) == resource and storedAmount(data, plotId, now) >= 1 then
			local _, amount = ProductionService.CollectPlot(data, plotId)
			total += amount
			CityService.RefreshPlot(player, plotId)
		end
	end
	return total
end

local function onAction(player: Player, action: any, plotId: any)
	if action ~= "Collect" or type(plotId) ~= "string" then
		return { Ok = false, Error = "Bad request" }
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
	local resource = producedResource(data.Buildings[plotId])
	if not resource then
		return { Ok = false, Error = "Nothing to collect" }
	end
	if storedAmount(data, plotId, os.time()) < 1 then
		return { Ok = false, Error = "Nothing to collect" }
	end

	local total = collectAll(player, data, resource)
	PlayerDataService.Sync(player)
	return { Ok = true, Resource = resource, Amount = total }
end

-- Older saves (and buildings finished before this service existed) have no LastCollected yet
local function onLoaded(player: Player)
	local data = PlayerDataService.GetData(player)
	if not data then
		return
	end
	for plotId, building in pairs(data.Buildings) do
		if producedResource(building) and not building.LastCollected then
			building.LastCollected = os.time()
			CityService.RefreshPlot(player, plotId)
		end
	end
end

function ProductionService.Start(dataService, cityService)
	PlayerDataService = dataService
	CityService = cityService

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("ProductionAction") :: RemoteFunction
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "ProductionAction"
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onAction

	PlayerDataService.Loaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
end

return ProductionService
