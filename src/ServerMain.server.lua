-- ServerMain: starts every server service in order.
-- Location in Studio: ServerScriptService.ServerMain (Script)

local Services = script.Parent:WaitForChild("Services")

local PlayerDataService = require(Services.PlayerDataService)
local CityService = require(Services.CityService)
local BuildingService = require(Services.BuildingService)
local ProductionService = require(Services.ProductionService)
local TrainingService = require(Services.TrainingService)
local AdminService = require(Services.AdminService)
local KingdomMapService = require(Services.KingdomMapService)
local MarchService = require(Services.MarchService)
local AttackService = require(Services.AttackService)
local ShareService = require(Services.ShareService)

-- City, Building, Production, Training, KingdomMap and March services listen for PlayerDataService.Loaded, so they start before data begins loading
CityService.Start(PlayerDataService)
ProductionService.Start(PlayerDataService, CityService)
BuildingService.Start(PlayerDataService, CityService, ProductionService)
TrainingService.Start(PlayerDataService, CityService)
KingdomMapService.Start(PlayerDataService)
AttackService.Start(PlayerDataService)
ShareService.Start(KingdomMapService)
MarchService.Start(PlayerDataService, KingdomMapService)
AdminService.Start(PlayerDataService, BuildingService, TrainingService, KingdomMapService, MarchService)
PlayerDataService.Start()
