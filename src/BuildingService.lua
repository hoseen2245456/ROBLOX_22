-- BuildingService: builds and upgrades buildings on a timer. Timers finish even while the player is offline.
-- Location in Studio: ServerScriptService.Services.BuildingService (ModuleScript)
-- Rules followed:
--   * The client only asks (Remotes.BuildingAction). The server checks the plot, the builder, the
--     requirements and the resources, then spends the resources and starts the timer.
--   * A timer is stored as EndsAt = os.time() + seconds in data.Timers. Nothing polls it: while the
--     player is online each timer gets one task.delay, and timers that ended offline finish on load.
--   * The timer starts when the worker (the player's character) gets to the plot: StartedAt = now +
--     the walk time the server works out from where the character stands (GameConfig.GetWalkSeconds).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)

local BuildingService = {}

local PlayerDataService
local CityService
local ProductionService
local lastRequest = {} -- [Player] = os.clock() of the last request

-- Every plot the player can build on or upgrade: plotId -> building type
local plotTypes = { Walls_1 = "Walls" }
for _, plot in ipairs(GameConfig.CityLayout) do
	plotTypes[plot.Id] = plot.Type
end

local function timerId(plotId: string): string
	return "Build_" .. plotId
end

-- The first free builder (1 = the player's character, 2 = the NPC helper), or nil if all are busy.
-- Timers saved before builders had numbers belong to builder 1.
local function freeBuilder(data): number?
	local busy = {}
	for _, timer in pairs(data.Timers) do
		if timer.Kind == "Build" then
			busy[timer.Worker or 1] = true
		end
	end
	for i = 1, GameConfig.GetBuilderCount(data.ExtraBuilders) do
		if not busy[i] then
			return i
		end
	end
	return nil
end

-- Highest level the player has of a building type (0 if none)
local function highestLevel(data, buildingType: string): number
	local best = 0
	for _, building in pairs(data.Buildings) do
		if building.Type == buildingType and building.Level > best then
			best = building.Level
		end
	end
	return best
end

-- Returns the plan { Type, ToLevel, Cost } or nil and the reason shown to the player
local function checkRequest(data, action: string, plotId: string)
	local buildingType = plotTypes[plotId]
	if not buildingType then
		return nil, "Unknown plot"
	end
	if data.Timers[timerId(plotId)] then
		return nil, "Already in progress"
	end
	if data.Timers["Train_" .. plotId] then
		return nil, "Training troops, try again later"
	end

	local building = data.Buildings[plotId]
	local toLevel
	if action == "Build" then
		if building then
			return nil, "Already built"
		end
		toLevel = 1
	elseif action == "Upgrade" then
		if not building then
			return nil, "Nothing to upgrade"
		end
		if building.Level >= GameConfig.MaxBuildingLevel then
			return nil, "Max level reached"
		end
		toLevel = building.Level + 1
	else
		return nil, "Unknown action"
	end

	local worker = freeBuilder(data)
	if not worker then
		return nil, "All builders are busy"
	end
	for _, req in ipairs(GameConfig.GetRequirements(buildingType, toLevel)) do
		if highestLevel(data, req.Type) < req.Level then
			return nil, ("Requires %s Lv %d"):format(GameConfig.Buildings[req.Type].DisplayName, req.Level)
		end
	end
	local cost = GameConfig.GetUpgradeCost(buildingType, toLevel)
	for resource, amount in pairs(cost) do
		if (data.Resources[resource] or 0) < amount then
			return nil, "Not enough " .. resource
		end
	end
	return { Type = buildingType, ToLevel = toLevel, Cost = cost, Worker = worker }
end

-- Applies a finished timer to the data. Returns true if it was still active.
local function applyTimer(data, id: string, timer): boolean
	if data.Timers[id] ~= timer then
		return false -- already finished or replaced
	end
	data.Timers[id] = nil
	local building = data.Buildings[timer.Target]
	if building then
		building.Level = math.max(building.Level, timer.ToLevel)
	else
		building = { Type = timer.BuildingType, Level = timer.ToLevel }
		data.Buildings[timer.Target] = building
	end
	ProductionService.StartProducing(building, timer.EndsAt)
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

-- On load: finish every timer that ended while the player was offline, schedule the rest
local function onLoaded(player: Player)
	local data = PlayerDataService.GetData(player)
	if not data then
		return
	end
	local now = os.time()
	local finished = {}
	for id, timer in pairs(data.Timers) do
		if timer.Kind == "Build" then
			if timer.EndsAt <= now then
				applyTimer(data, id, timer)
				table.insert(finished, timer.Target)
			else
				schedule(player, data, id, timer)
			end
		end
	end
	if #finished > 0 then
		print("[BuildingService]", player.Name, "finished offline:", table.concat(finished, ", "))
		for _, plotId in ipairs(finished) do
			CityService.RefreshPlot(player, plotId) -- no-op if the city is not built yet; it reads the new data
		end
		PlayerDataService.Sync(player)
	end
end

-- Where a builder is now, relative to the city center. The NPC helper lives on the client only, so
-- the server times it from its idle spot; the player's character from where it stands.
local function workerPosition(player: Player, worker: number): Vector3
	if worker ~= 1 then
		return GameConfig.Worker.HelperIdleOffset
	end
	local origin = player:GetAttribute("CityOrigin")
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if origin and root then
		return root.Position - origin
	end
	return GameConfig.Worker.IdleOffset
end

local function onAction(player: Player, action: any, plotId: any)
	if type(action) ~= "string" or type(plotId) ~= "string" then
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
	local plan, reason = checkRequest(data, action, plotId)
	if not plan then
		return { Ok = false, Error = reason }
	end

	-- No yield between the check and here, so two requests can never spend the same resources.
	-- A resource building stops producing while it upgrades, so it hands over what it held first.
	if action == "Upgrade" then
		ProductionService.CollectPlot(data, plotId)
	end
	for resource, amount in pairs(plan.Cost) do
		data.Resources[resource] -= amount
	end
	local startsAt = os.time() + GameConfig.GetWalkSeconds(workerPosition(player, plan.Worker), plotId)
	local timer = {
		Kind = "Build",
		Target = plotId,
		Worker = plan.Worker,
		BuildingType = plan.Type,
		ToLevel = plan.ToLevel,
		StartedAt = startsAt, -- the worker arrives
		EndsAt = startsAt + GameConfig.GetUpgradeSeconds(plan.Type, plan.ToLevel),
	}
	local id = timerId(plotId)
	data.Timers[id] = timer
	schedule(player, data, id, timer)

	CityService.RefreshPlot(player, plotId)
	PlayerDataService.Sync(player)
	return { Ok = true, StartsAt = timer.StartedAt, EndsAt = timer.EndsAt }
end

-- Admin: finish every build timer of this player now. Returns how many finished.
function BuildingService.FinishAll(player: Player): number
	local data = PlayerDataService.GetData(player)
	if not data then
		return 0
	end
	local count = 0
	for id, timer in pairs(table.clone(data.Timers)) do
		if timer.Kind == "Build" and applyTimer(data, id, timer) then
			CityService.RefreshPlot(player, timer.Target)
			count += 1
		end
	end
	return count
end

-- Admin: a free build (empty plot) or upgrade that takes `seconds` once the worker gets there, to watch the
-- scaffold, the ghost and the finish scene. Returns true if it started.
function BuildingService.StartFree(player: Player, data, plotId: string, seconds: number): boolean
	local buildingType = plotTypes[plotId]
	local building = data.Buildings[plotId]
	if not buildingType or data.Timers[timerId(plotId)] or data.Timers["Train_" .. plotId]
		or (building and building.Level >= GameConfig.MaxBuildingLevel) then
		return false
	end
	local worker = freeBuilder(data)
	if not worker then
		return false
	end
	if building then
		ProductionService.CollectPlot(data, plotId)
	end
	local startsAt = os.time() + GameConfig.GetWalkSeconds(workerPosition(player, worker), plotId)
	local timer = {
		Kind = "Build",
		Target = plotId,
		Worker = worker,
		BuildingType = buildingType,
		ToLevel = (building and building.Level or 0) + 1,
		StartedAt = startsAt,
		EndsAt = startsAt + seconds,
	}
	local id = timerId(plotId)
	data.Timers[id] = timer
	schedule(player, data, id, timer)
	CityService.RefreshPlot(player, plotId)
	return true
end

-- The NPC helper's body (ReplicatedStorage.WorkerHelperTemplate). Only the server can make a
-- character from a HumanoidDescription; each client clones it and moves its own copy.
local function makeHelperTemplate()
	if ReplicatedStorage:FindFirstChild("WorkerHelperTemplate") then
		return
	end
	local colors = GameConfig.Worker.HelperColors
	local desc = Instance.new("HumanoidDescription")
	desc.HeadColor, desc.LeftArmColor, desc.RightArmColor = colors.Skin, colors.Skin, colors.Skin
	desc.TorsoColor = colors.Shirt
	desc.LeftLegColor, desc.RightLegColor = colors.Pants, colors.Pants
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok then
		warn("[BuildingService] helper template failed: " .. tostring(model))
		return
	end
	model.Name = "WorkerHelperTemplate"
	-- A hard hat so it reads as a builder
	local head = model:FindFirstChild("Head") :: BasePart
	local helmet = Instance.new("Part")
	helmet.Name = "Helmet"
	helmet.Shape = Enum.PartType.Cylinder
	helmet.Size = Vector3.new(0.5, 1.5, 1.5)
	helmet.Color = colors.Helmet
	helmet.Material = Enum.Material.SmoothPlastic
	helmet.CanCollide, helmet.CanQuery, helmet.CanTouch, helmet.Massless = false, false, false, true
	helmet.CFrame = head.CFrame * CFrame.new(0, 0.55, 0) * CFrame.Angles(0, 0, math.rad(90))
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = head, helmet
	weld.Parent = helmet
	helmet.Parent = model
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanQuery = false -- clicks on plots go through it
		end
	end
	model.Parent = ReplicatedStorage
end

function BuildingService.Start(dataService, cityService, productionService)
	PlayerDataService = dataService
	CityService = cityService
	ProductionService = productionService
	task.spawn(makeHelperTemplate)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("BuildingAction") :: RemoteFunction
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "BuildingAction"
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onAction

	PlayerDataService.Loaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
end

return BuildingService
