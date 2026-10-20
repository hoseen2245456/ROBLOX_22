-- ClientMain: starts every client controller in order.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.ClientMain (LocalScript)

local Controllers = script.Parent:WaitForChild("Controllers")

local ClientData = require(Controllers.ClientData)
local CameraController = require(Controllers.CameraController)
local ProductionController = require(Controllers.ProductionController)
local BuildingController = require(Controllers.BuildingController)
local WorkerController = require(Controllers.WorkerController)
local HUDController = require(Controllers.HUDController)
local UpgradeFXController = require(Controllers.UpgradeFXController)
local AdminController = require(Controllers.AdminController)
local MapController = require(Controllers.MapController)
local MarchController = require(Controllers.MarchController)
local BattleReportController = require(Controllers.BattleReportController)
local AlertController = require(Controllers.AlertController)

ClientData.Start()
HUDController.Start() -- before the camera, which waits for the city
CameraController.Start() -- waits until the server gives us a city
ProductionController.Start()
BuildingController.Start()
WorkerController.Start()
MarchController.Start() -- before Map, which opens its panels
MapController.Start()
BattleReportController.Start()
AlertController.Start() -- incoming-attack alert (uses MarchController's marches)
AdminController.Start() -- before UpgradeFX, which waits for the city
UpgradeFXController.Start()
