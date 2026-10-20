-- AdminService: test/admin tools (give or take resources, finish timers, add troops).
-- Location in Studio: ServerScriptService.Services.AdminService (ModuleScript)
-- Only players in GameConfig.Admin.UserIds (or anyone in Studio) can use it. The server checks every
-- request; the client only gets the "IsAdmin" attribute to know whether to show the panel.
-- New game systems should add their admin actions here (see roblox_rules).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local BuildingVisuals = require(ReplicatedStorage.Modules.BuildingVisuals)
local CityService = require(script.Parent.CityService)
local Cfg = GameConfig.Admin

local AdminService = {}

local PlayerDataService, BuildingService, TrainingService, KingdomMapService, MarchService

local ALL_RESOURCES = table.clone(GameConfig.Resources)
table.insert(ALL_RESOURCES, GameConfig.PremiumCurrency)
table.insert(ALL_RESOURCES, GameConfig.RareMaterial)

local function isAdmin(player: Player): boolean
	if Cfg.AllowInStudio and RunService:IsStudio() then
		return true
	end
	return table.find(Cfg.UserIds, player.UserId) ~= nil
end

-- Every action: (player, data, arg) -> message
local actions = {}

function actions.AddResources(_player, data, amount)
	if not table.find(Cfg.ResourceSteps, amount) then
		return nil, "Bad amount"
	end
	for _, r in ipairs(ALL_RESOURCES) do
		data.Resources[r] = (data.Resources[r] or 0) + amount
	end
	return ("+%d of every resource"):format(amount)
end

function actions.ClearResources(_player, data)
	for _, r in ipairs(ALL_RESOURCES) do
		data.Resources[r] = 0
	end
	return "All resources set to 0"
end

function actions.FinishTimers(player)
	local n = BuildingService.FinishAll(player) + TrainingService.FinishAll(player)
	return ("Finished %d timer(s)"):format(n)
end

function actions.AddTroops(_player, data)
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		local counts = data.Troops[troopType] or { 0, 0, 0, 0 }
		data.Troops[troopType] = counts
		counts[1] = (counts[1] or 0) + Cfg.TroopStep
		data.Stats.Power += Cfg.TroopStep * GameConfig.TroopTiers[1].Power
	end
	return ("+%d T1 of every troop type"):format(Cfg.TroopStep)
end

function actions.ToggleBuilder(_player, data)
	data.ExtraBuilders = if (data.ExtraBuilders or 0) >= 1 then 0 else 1
	return ("Builders: %d"):format(GameConfig.GetBuilderCount(data.ExtraBuilders))
end

function actions.MoveCastle(player)
	local ok, err = KingdomMapService.MoveRandom(player)
	if not ok then
		return nil, err
	end
	local tile = PlayerDataService.GetData(player).MapTile
	return ("Castle moved to %d, %d"):format(tile.X, tile.Y)
end

-- Castle jumps to the first level of the next visual tier (1 → 6 → 11 ... → 26 → 1), to see every castle model
function actions.NextCastleTier(player, data)
	if data.Timers.Build_Castle_1 then
		return nil, "Castle is upgrading: finish timers first"
	end
	local castle = data.Buildings.Castle_1
	local tiers = GameConfig.VisualTiers
	local nextTier = tiers[BuildingVisuals.GetTier(castle.Level) + 1] or tiers[1]
	castle.Level = nextTier.FromLevel
	for _, plot in ipairs(GameConfig.CityLayout) do
		CityService.RefreshPlot(player, plot.Id)
	end
	return ("Castle Lv %d (%s)"):format(castle.Level, nextTier.Name)
end

function actions.NextWallTier(player, data)
	if data.Timers.Build_Walls_1 then
		return nil, "Walls are upgrading: finish timers first"
	end
	local walls = data.Buildings.Walls_1
	local tiers = GameConfig.VisualTiers
	local nextTier = tiers[BuildingVisuals.GetTier(walls.Level) + 1] or tiers[1]
	walls.Level = nextTier.FromLevel
	CityService.RefreshPlot(player, "Walls_1")
	return ("Walls Lv %d (%s)"):format(walls.Level, nextTier.Name)
end

local MILITARY_PLOTS = { "Barracks_1", "ArcheryRange_1", "Stable_1", "SiegeWorkshop_1" }
local CIVIC_PLOTS = { "Hospital_1", "Academy_1", "Tavern_1", "Embassy_1", "Market_1", "WatchTower_1" }

-- A group of buildings jumps together to the first level of the next visual tier (built if missing)
local function nextGroupTier(player, data, plots: { string })
	local first = data.Buildings[plots[1]]
	local tiers = GameConfig.VisualTiers
	local nextTier = tiers[(first and BuildingVisuals.GetTier(first.Level) or 0) + 1] or tiers[1]
	for _, plotId in ipairs(plots) do
		if not data.Timers["Build_" .. plotId] then
			local building = data.Buildings[plotId]
			if building then
				building.Level = nextTier.FromLevel
			else
				data.Buildings[plotId] = { Type = (plotId:gsub("_%d+$", "")), Level = nextTier.FromLevel }
			end
			CityService.RefreshPlot(player, plotId)
		end
	end
	return nextTier
end

function actions.NextMilitaryTier(player, data)
	local tier = nextGroupTier(player, data, MILITARY_PLOTS)
	return ("Military Lv %d (%s)"):format(tier.FromLevel, tier.Name)
end

function actions.NextCivicTier(player, data)
	local tier = nextGroupTier(player, data, CIVIC_PLOTS)
	return ("Civic Lv %d (%s)"):format(tier.FromLevel, tier.Name)
end

-- Free short training batch in each military building, to watch the training animation
function actions.DemoTraining(player, data)
	local n = 0
	for _, plotId in ipairs(MILITARY_PLOTS) do
		if TrainingService.StartFree(player, data, plotId, Cfg.DemoTrainSeconds) then
			n += 1
		end
	end
	return ("%d building(s) training for %ds"):format(n, Cfg.DemoTrainSeconds)
end

-- Free short build on the first empty unlocked plot ("Build"), or upgrade of the first built one ("Upgrade"),
-- to watch the scaffold, the ghost filling in and the finish scene
function actions.DemoBuild(player, data, arg)
	local castle = data.Buildings.Castle_1 and data.Buildings.Castle_1.Level or 1
	for _, plot in ipairs(GameConfig.CityLayout) do
		local building = data.Buildings[plot.Id]
		local fits = if arg == "Upgrade" then building ~= nil and plot.Type ~= "Castle"
			else building == nil and castle >= GameConfig.Buildings[plot.Type].UnlockAt
		if fits and BuildingService.StartFree(player, data, plot.Id, Cfg.DemoBuildSeconds) then
			return ("%s: %s for %ds (after the walk)"):format(plot.Id, if building then "upgrade" else "build", Cfg.DemoBuildSeconds)
		end
	end
	return nil, "No free plot or builder"
end

-- Start over: the city, resources, troops, timers and reports go back to a new player's (the castle keeps its
-- map tile). Needs a second press within Admin.ResetConfirmSeconds, so one stray tap can't wipe everything.
local resetArmedAt: { [Player]: number } = {}
function actions.ResetAll(player, data)
	if MarchService.HasMarches(data) then
		return nil, "Armies are out: finish marches first"
	end
	local armed = resetArmedAt[player]
	if not armed or os.clock() - armed > Cfg.ResetConfirmSeconds then
		resetArmedAt[player] = os.clock()
		return nil, "Press again to reset EVERYTHING"
	end
	resetArmedAt[player] = nil
	-- Same table (the services hold it), new contents. Old timers just stop: they check data.Timers.
	for k, v in pairs(PlayerDataService.NewData()) do
		data[k] = v
	end
	data.ShieldOff = nil
	data.LastMoveAt = nil
	CityService.RefreshPlot(player, "Walls_1")
	for _, plot in ipairs(GameConfig.CityLayout) do
		CityService.RefreshPlot(player, plot.Id)
	end
	return "Everything reset to a new player's start"
end

function actions.ResetMoveCooldown(_player, data)
	data.LastMoveAt = nil
	return "Castle move cooldown reset"
end

function actions.FinishMarches(player)
	return ("%d army(s) came home"):format(MarchService.FinishAll(player))
end

function actions.ArriveMarches(player)
	return ("%d army(s) arrived"):format(MarchService.ArriveAll(player))
end

-- A new fake player's castle to attack (troops, resources, no beginner shield). arg "Near" = the closest
-- free tile to your castle, "Random" = anywhere. The 5 test castles are reused in turn.
local nextDummy = 0
local function spawnDummy(data, arg)
	local d = GameConfig.Battle.Castle.Dummy
	local tile = data.MapTile
	if not tile then
		return nil, "Your castle is not on the map yet"
	end
	nextDummy = nextDummy % d.Max + 1
	local userId = -nextDummy
	local name = d.Name:format(nextDummy)
	local x, y
	if arg == "Random" then
		x, y = KingdomMapService.PlaceDummy(userId, name, 1)
	else
		x, y = KingdomMapService.PlaceDummy(userId, name, 1, tile.X, tile.Y)
	end
	if not x then
		return nil, y
	end
	local status = PlayerDataService.UpdateOffline(userId, function(old)
		local dummy = old or PlayerDataService.NewData()
		dummy.CreatedAt = 0
		dummy.MapTile = { X = x, Y = y }
		dummy.KingdomId = GameConfig.Map.KingdomId
		for _, resource in ipairs(GameConfig.Resources) do
			dummy.Resources[resource] = d.Resources
		end
		for _, troopType in ipairs(GameConfig.TroopTypes) do
			dummy.Troops[troopType] = { d.TroopsPerType, 0, 0, 0 }
		end
		dummy.Stats.Power = d.TroopsPerType * #GameConfig.TroopTypes * GameConfig.TroopTiers[1].Power
		dummy.SessionLock = nil
		return dummy
	end)
	if status ~= "Done" then
		return nil, "Could not save the test castle: " .. status
	end
	return { UserId = userId, Name = name, X = x, Y = y }
end

function actions.SpawnDummy(_player, data, arg)
	local dummy, err = spawnDummy(data, arg)
	if not dummy then
		return nil, err
	end
	local d = GameConfig.Battle.Castle.Dummy
	return ("%s at %d, %d (%d troops of each type, %d of each resource)"):format(dummy.Name, dummy.X, dummy.Y, d.TroopsPerType, d.Resources),
		nil, { X = dummy.X, Y = dummy.Y }
end

-- A new test castle next to yours sends an army at you (arrives in Admin.DummyAttackSeconds): the
-- incoming-attack alert, then a defense battle and report
function actions.DummyAttack(player, data)
	local dummy, err = spawnDummy(data, "Near")
	if not dummy then
		return nil, err
	end
	local troops = {}
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		troops[troopType] = { Cfg.DummyAttackTroops, 0, 0, 0 }
	end
	if not MarchService.DummyAttack(player, dummy.UserId, dummy.Name, dummy, troops, Cfg.DummyAttackSeconds) then
		return nil, "Your castle is not on the map yet"
	end
	return ("%s attacks you in %ds (%d of each troop type)"):format(dummy.Name, Cfg.DummyAttackSeconds, Cfg.DummyAttackTroops)
end

local function onAction(player: Player, action: any, arg: any)
	if not isAdmin(player) then
		return { Ok = false, Error = "Not an admin" }
	end
	local fn = type(action) == "string" and actions[action]
	if not fn then
		return { Ok = false, Error = "Unknown action" }
	end
	local data = PlayerDataService.GetData(player)
	if not data then
		return { Ok = false, Error = "Data not loaded" }
	end
	local message, err, tile = fn(player, data, arg)
	if not message then
		return { Ok = false, Error = err }
	end
	PlayerDataService.Sync(player)
	print(("[AdminService] %s: %s"):format(player.Name, message))
	return { Ok = true, Message = message, Tile = tile } -- Tile: the client shows it on the map
end

function AdminService.Start(dataService, buildingService, trainingService, mapService, marchService)
	PlayerDataService = dataService
	BuildingService = buildingService
	TrainingService = trainingService
	KingdomMapService = mapService
	MarchService = marchService

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("AdminAction") :: RemoteFunction
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "AdminAction"
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onAction

	local function mark(player: Player)
		player:SetAttribute("IsAdmin", isAdmin(player))
	end
	Players.PlayerAdded:Connect(mark)
	for _, player in ipairs(Players:GetPlayers()) do
		mark(player)
	end
end

return AdminService
