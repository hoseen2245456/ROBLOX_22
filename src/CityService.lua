-- CityService: gives each player a city slot and builds their city from their saved data.
-- Location in Studio: ServerScriptService.Services.CityService (ModuleScript)
-- The server owns all city geometry; clients only look at it (and request actions later).
-- Plots are fixed (GameConfig.CityLayout). A plot is Built, Upgrading, Constructing (new building on
-- a timer), Empty (buildable) or Locked (needs a higher Castle level). Call CityService.RefreshPlot
-- after any change to a building's data or timers.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local BuildingVisuals = require(ReplicatedStorage.Modules.BuildingVisuals)

local CityCfg = GameConfig.City

local CityService = {}

local cities = {} -- [Player] = { Slot, Origin, Model, PlotsFolder, WallsModel, Plots = { [plotId] = Model } }
local usedSlots = {} -- [slot] = Player
local citiesFolder: Folder
local PlayerDataService

local plotById = {}
for _, plot in ipairs(GameConfig.CityLayout) do
	plotById[plot.Id] = plot
end

local function slotOrigin(slot: number): Vector3
	local index = slot - 1
	local col = index % CityCfg.SlotsPerRow
	local row = index // CityCfg.SlotsPerRow
	return CityCfg.GridOrigin + Vector3.new(col * CityCfg.SlotSpacing, 0, row * CityCfg.SlotSpacing)
end

local function claimSlot(player: Player): number
	local slot = 1
	while usedSlots[slot] do
		slot += 1
	end
	usedSlots[slot] = player
	return slot
end

local function makePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Lighting + post effects from GameConfig.Environment (Lighting replicates to every client)
local function applyLighting()
	local Lighting = game:GetService("Lighting")
	for prop, value in pairs(GameConfig.Environment.Lighting) do
		Lighting[prop] = value
	end
	for className, props in pairs(GameConfig.Environment.Effects) do
		local effect = Lighting:FindFirstChildOfClass(className)
		if not effect then
			effect = Instance.new(className)
			effect.Parent = Lighting
		end
		for prop, value in pairs(props) do
			effect[prop] = value
		end
	end
end

-- Decoration: looks only, so clicks and the walking builder go through it
local function decorPart(parent, name, size, cframe, color, material, shape)
	local p = makePart(parent, name, size, cframe, color, material)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	if shape then
		p.Shape = shape
	end
	return p
end

local function buildGround(city, data)
	local G = GameConfig.Environment.Ground
	local C = G.Colors
	local origin, gy = city.Origin, CityCfg.GroundY
	local rng = Random.new(city.Slot) -- same decoration every time for this slot
	local model = city.Model

	-- The base ground fills the whole slot; thin flat layers sit on top (each a bit higher)
	local outer = G.OutskirtsHalfSize * 2
	makePart(model, "Ground", Vector3.new(outer, 1, outer), CFrame.new(origin + Vector3.new(0, gy - 0.5, 0)), C.Outskirts, Enum.Material.Grass)
	local function flat(name, sx, sz, x, z, layer, color, material)
		local p = decorPart(model, name, Vector3.new(sx, 0.2, sz), CFrame.new(origin + Vector3.new(x, gy + layer * 0.03 - 0.1, z)), color, material)
		p.CastShadow = false
		return p
	end
	local meadow, inner = CityCfg.HalfSize * 2, G.InnerHalfSize * 2
	flat("Meadow", meadow, meadow, 0, 0, 1, C.Meadow, Enum.Material.Grass)
	flat("CityGrass", inner, inner, 0, 0, 2, C.Grass, Enum.Material.Grass)
	for _ = 1, G.Patches do
		local d = rng:NextNumber(12, 36)
		local x, z = rng:NextNumber(-100, 100), rng:NextNumber(-100, 100)
		local patch = decorPart(model, "GrassPatch", Vector3.new(0.2, d, d), CFrame.new(origin + Vector3.new(x, gy + 3 * 0.03 - 0.1, z)) * CFrame.Angles(0, 0, math.pi / 2),
			rng:NextNumber() < 0.6 and C.GrassDark or C.GrassLight, Enum.Material.Grass, Enum.PartType.Cylinder)
		patch.CastShadow = false
	end
	-- Dirt paths between the plot columns/rows
	for _, x in ipairs(G.PathsX) do
		flat("Path", G.PathWidth, 177, x, -13.5, 4, C.Dirt, Enum.Material.Ground)
	end
	for _, p in ipairs(G.PathsZ) do
		flat("Path", p[3] - p[2], G.PathWidth, (p[2] + p[3]) / 2, p[1], 4, C.Dirt, Enum.Material.Ground)
	end
	-- Castle plaza, then the cobble roads on slate curbs (a wider strip under each road)
	local plaza = G.PlazaHalfSize * 2
	flat("PlazaCurb", plaza + 2 * G.CurbWidth, plaza + 2 * G.CurbWidth, 0, 0, 5, C.Curb, Enum.Material.Slate)
	flat("Plaza", plaza, plaza, 0, 0, 6, C.Plaza, Enum.Material.Cobblestone)
	local roadStart, roadEnd = G.PlazaHalfSize, G.OutskirtsHalfSize
	local len, w = roadEnd - roadStart, CityCfg.RoadWidth
	flat("RoadCurb", w + 2 * G.CurbWidth, len, 0, roadStart + len / 2, 5, C.Curb, Enum.Material.Slate)
	flat("Road", w, len, 0, roadStart + len / 2, 7, C.Cobble, Enum.Material.Cobblestone)
	local crossLen = CityCfg.WallHalfSize * 2 - 12
	flat("RoadCurb", crossLen, G.CrossRoadWidth + 2 * G.CurbWidth, 0, G.CrossRoadZ, 5, C.Curb, Enum.Material.Slate)
	flat("Road", crossLen, G.CrossRoadWidth, 0, G.CrossRoadZ, 7, C.Cobble, Enum.Material.Cobblestone)

	local decor = Instance.new("Model")
	decor.Name = "Decor"
	decor.Parent = model
	local base = gy + 0.2
	local function at(x, z, y)
		return CFrame.new(origin + Vector3.new(x, base + (y or 0), z))
	end
	local function onSouthRoad(x, z)
		return math.abs(x) < 14 and z > 0
	end
	local function tree(x, z)
		local s = rng:NextNumber(0.8, 1.4)
		local spin = CFrame.Angles(0, rng:NextNumber(0, math.pi), 0)
		if rng:NextNumber() < 0.55 then -- pine: trunk + two stacked turned blocks
			decorPart(decor, "Trunk", Vector3.new(4 * s, 1.2 * s, 1.2 * s), at(x, z, 2 * s) * CFrame.Angles(0, 0, math.pi / 2), C.Trunk, Enum.Material.Wood, Enum.PartType.Cylinder)
			decorPart(decor, "Leaves", Vector3.new(7, 4, 7) * s, at(x, z, 5 * s) * spin * CFrame.Angles(0, math.pi / 4, 0), C.Pine, Enum.Material.Grass)
			decorPart(decor, "Leaves", Vector3.new(4.5, 4, 4.5) * s, at(x, z, 8.5 * s) * spin, C.Pine2, Enum.Material.Grass)
		else -- oak: trunk + two balls
			decorPart(decor, "Trunk", Vector3.new(5 * s, 1.5 * s, 1.5 * s), at(x, z, 2.5 * s) * CFrame.Angles(0, 0, math.pi / 2), C.Trunk, Enum.Material.Wood, Enum.PartType.Cylinder)
			decorPart(decor, "Leaves", Vector3.new(8, 8, 8) * s, at(x - 1 * s, z, 7 * s), C.Oak, Enum.Material.Grass, Enum.PartType.Ball)
			decorPart(decor, "Leaves", Vector3.new(6.5, 6.5, 6.5) * s, at(x + 1.5 * s, z + 1 * s, 8.5 * s), C.Oak2, Enum.Material.Grass, Enum.PartType.Ball)
		end
	end
	-- Forest belt at the slot edge, a few trees just outside the wall
	local edge = G.OutskirtsHalfSize - 4
	for _ = 1, G.ForestTrees do
		local x, z = rng:NextNumber(-edge, edge), rng:NextNumber(-edge, edge)
		if math.max(math.abs(x), math.abs(z)) >= G.ForestFrom and not onSouthRoad(x, z) then
			tree(x, z)
		end
	end
	for _ = 1, G.MeadowTrees do
		local x, z = rng:NextNumber(-127, 127), rng:NextNumber(-127, 127)
		if math.max(math.abs(x), math.abs(z)) >= 118 and not onSouthRoad(x, z) then
			tree(x, z)
		end
	end
	for _ = 1, G.Rocks do
		local x, z = rng:NextNumber(-190, 190), rng:NextNumber(-190, 190)
		if math.max(math.abs(x), math.abs(z)) >= 132 and not onSouthRoad(x, z) then
			local s = rng:NextNumber(0.7, 1.5)
			decorPart(decor, "Rock", Vector3.new(4, 2.5, 3) * s, at(x, z, 0.8 * s) * CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 3), 0), C.Rock, Enum.Material.Slate)
			decorPart(decor, "Rock", Vector3.new(2.5, 2, 2.5) * s, at(x + 1.8 * s, z + 1 * s, 0.6 * s) * CFrame.Angles(0, rng:NextNumber(0, 3), 0.3), C.Rock, Enum.Material.Slate)
		end
	end
	-- Bushes along the inside of the wall
	for i = 1, G.Bushes do
		local side, t = i % 4, rng:NextNumber(-100, 100)
		local x = side < 2 and t or (side == 2 and -104 or 104)
		local z = side < 2 and (side == 1 and -104 or 104) or t
		if not (math.abs(x) < 14 and z > 100) then
			decorPart(decor, "Bush", Vector3.new(3.5, 3.5, 3.5) * rng:NextNumber(0.8, 1.3), at(x, z, 1), C.Bush, Enum.Material.Grass, Enum.PartType.Ball)
		end
	end
	-- Lamp posts on both sides of the main road (lights zig-zag: one side per row)
	local row = 0
	for z = 34, 104, G.LampSpacing do
		if math.abs(z - G.CrossRoadZ) < 5 then
			continue
		end
		row += 1
		for _, x in ipairs({ -8, 8 }) do
			decorPart(decor, "LampPost", Vector3.new(0.6, 6, 0.6), at(x, z, 3), C.Trunk, Enum.Material.Wood)
			decorPart(decor, "LampCap", Vector3.new(1.8, 0.4, 1.8), at(x, z, 7), Color3.fromRGB(42, 32, 24), Enum.Material.Metal)
			local flame = decorPart(decor, "LampFlame", Vector3.new(0.9, 0.9, 0.9), at(x, z, 6.4), C.Flame, Enum.Material.Neon)
			if (row % 2 == 1) == (x < 0) then
				local light = Instance.new("PointLight")
				light.Color = C.Flame
				light.Range = G.LampRange
				light.Brightness = 1.5
				light.Parent = flame
			end
		end
	end
	-- Civilization banners around the castle
	local banner = GameConfig.Art.Banners[data and data.Civilization or ""] or GameConfig.Art.Banners.English
	for _, p in ipairs({ { -13, -22 }, { 13, -22 }, { -13, 22 }, { 13, 22 } }) do
		local x, z = p[1], p[2]
		decorPart(decor, "BannerPole", Vector3.new(10, 0.5, 0.5), at(x, z, 5) * CFrame.Angles(0, 0, math.pi / 2), C.Trunk, Enum.Material.Wood, Enum.PartType.Cylinder)
		decorPart(decor, "Banner", Vector3.new(0.2, 4, 3), at(x, z + 1.75, 7.5), banner.Main, Enum.Material.Fabric)
		decorPart(decor, "BannerTrim", Vector3.new(0.25, 0.5, 3.2), at(x, z + 1.75, 9.6), banner.Trim, Enum.Material.Fabric)
	end
	-- Flower beds in the gaps beside the castle
	for _, p in ipairs({ { -25, -15 }, { 25, -15 }, { -25, 15 }, { 25, 15 } }) do
		decorPart(decor, "FlowerBed", Vector3.new(8, 0.6, 2.5), at(p[1], p[2], 0.3), C.Curb, Enum.Material.Slate)
		for i = -1.5, 1.5 do
			decorPart(decor, "Flower", Vector3.new(1.4, 1.4, 1.4), at(p[1] + i * 1.8, p[2], 0.9), i % 2 == 0.5 and C.FlowerA or C.FlowerB, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		end
	end
	-- Work props next to the production buildings
	for _, z in ipairs({ -90, -60, -30, 0 }) do
		decorPart(decor, "Hay", Vector3.new(3, 4.4, 4.4), at(104, z + 6, 1.5) * CFrame.Angles(0, 0, math.pi / 2), C.Hay, Enum.Material.Fabric, Enum.PartType.Cylinder)
		decorPart(decor, "Hay", Vector3.new(3.6, 3.6, 3.6), at(104, z + 6, 3), C.Hay, Enum.Material.Fabric, Enum.PartType.Ball)
		for _, o in ipairs({ { 0, 0.8 }, { 1.7, 0.8 }, { 0.85, 2.3 } }) do
			decorPart(decor, "Log", Vector3.new(5, 1.6, 1.6), at(-104 + o[1] - 0.85, z + 6, o[2]) * CFrame.Angles(0, math.pi / 2, 0), C.Log, Enum.Material.Wood, Enum.PartType.Cylinder)
		end
	end
	for _, z in ipairs({ 30, 60 }) do
		decorPart(decor, "StonePile", Vector3.new(3, 2.5, 3), at(104, z + 6, 1.2) * CFrame.Angles(0, 0.6, 0), C.Rock, Enum.Material.Slate)
		decorPart(decor, "StonePile", Vector3.new(2.2, 2, 2.2), at(105, z + 8, 1) * CFrame.Angles(0, 1.2, 0), Color3.fromRGB(125, 131, 140), Enum.Material.Slate)
	end
	for _, z in ipairs({ -52, -22 }) do
		decorPart(decor, "OreCart", Vector3.new(2.5, 1.5, 3.5), at(72, z, 1), C.Log, Enum.Material.WoodPlanks)
		decorPart(decor, "Ore", Vector3.new(2, 0.8, 3), at(72, z, 2), C.Ore, Enum.Material.Metal)
	end
	-- Fence on the farm edge
	for z = -102, 12, 6 do
		decorPart(decor, "FencePost", Vector3.new(0.5, 3, 0.5), at(101, z, 1.5), C.Log, Enum.Material.Wood)
	end
	for _, y in ipairs({ 1, 2.3 }) do
		decorPart(decor, "FenceRail", Vector3.new(0.3, 0.4, 114), at(101, -45, y), C.Log, Enum.Material.Wood)
	end
	-- Well by the tavern
	decorPart(decor, "Well", Vector3.new(2.5, 4, 4), at(15, -45, 1.25) * CFrame.Angles(0, 0, math.pi / 2), C.Curb, Enum.Material.Cobblestone, Enum.PartType.Cylinder)
	decorPart(decor, "WellWater", Vector3.new(0.2, 3, 3), at(15, -45, 2.5) * CFrame.Angles(0, 0, math.pi / 2), C.Water, Enum.Material.Glass, Enum.PartType.Cylinder)
	decorPart(decor, "WellRoof", Vector3.new(5, 0.6, 5), at(15, -45, 5.5) * CFrame.Angles(0, math.pi / 4, 0), C.Roof, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -1.9, 1.9 }) do
		decorPart(decor, "WellPost", Vector3.new(0.4, 3, 0.4), at(15 + x, -45, 4), C.Trunk, Enum.Material.Wood)
	end
end

-- The build/upgrade timer running on a plot, if any
local function buildTimerFor(data, plotId: string)
	for _, timer in pairs(data.Timers) do
		if timer.Kind == "Build" and timer.Target == plotId then
			return timer
		end
	end
	return nil
end

-- Marks a model as under construction; each client turns TimerEndsAt into a countdown
-- (TimerStartsAt is when the worker gets there; before that the client shows "Worker on the way")
local function addTimer(model: Model, timer, height: number)
	model:SetAttribute("TimerStartsAt", timer.StartedAt)
	model:SetAttribute("TimerEndsAt", timer.EndsAt)
	model:SetAttribute("TimerToLevel", timer.ToLevel)
	model:SetAttribute("TimerWorker", timer.Worker or 1)
	BuildingVisuals.AddTimerLabel(model, height)
end

-- Real models name their flags "Banner": paint them in the civilization color
local function paintBanners(model: Instance, data)
	local banner = GameConfig.Art.Banners[data.Civilization or ""] or GameConfig.Art.Banners.English
	for _, p in ipairs(model:GetDescendants()) do
		if p.Name == "Banner" and p:IsA("BasePart") then
			p.Color = banner.Main
		end
	end
end

local placeSegment = BuildingVisuals.PlaceWallSegment

-- The walls are not a plot, but they are tapped and upgraded like one (PlotId "Walls_1").
-- Uses WallSegment_N / WallTower_N / WallGate_N from BuildingModels (WallsModelBuilder), else Parts.
local function buildWalls(city, data)
	if city.WallsModel then
		city.WallsModel:Destroy()
	end
	local level = data.Buildings.Walls_1 and data.Buildings.Walls_1.Level or 1
	local timer = buildTimerFor(data, "Walls_1")
	local folder = Instance.new("Model")
	folder.Name = "Walls"
	city.WallsModel = folder

	local tierIndex = BuildingVisuals.GetTier(level)
	local tier = BuildingVisuals.Tiers[tierIndex]
	local wt = CityCfg.WallTiers[tierIndex]
	local color = BuildingVisuals.Colors.Walls
	local W, H, T = CityCfg.WallHalfSize, wt.Height, wt.Thickness
	local gx = CityCfg.GateWidth / 2 + wt.GateRadius + 0.4 -- gate tower centers
	local base = CFrame.new(city.Origin + Vector3.new(0, CityCfg.GroundY, 0))
	local segModel = BuildingVisuals.FindModel("WallSegment", tierIndex)
	local towerModel = BuildingVisuals.FindModel("WallTower", tierIndex)
	local gateModel = BuildingVisuals.FindModel("WallGate", tierIndex)

	-- Runs between tower centers; each faces outward (local +Z)
	local runs = {
		{ base * CFrame.new(0, 0, -W) * CFrame.Angles(0, math.pi, 0), W * 2 }, -- north
		{ base * CFrame.new(W, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), W * 2 }, -- east
		{ base * CFrame.new(-W, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), W * 2 }, -- west
		{ base * CFrame.new(-(gx + W) / 2, 0, W), W - gx }, -- south, left of the gate
		{ base * CFrame.new((gx + W) / 2, 0, W), W - gx }, -- south, right of the gate
	}
	for _, run in ipairs(runs) do
		if segModel then
			placeSegment(folder, segModel, run[1], run[2])
		else
			makePart(folder, "Wall", Vector3.new(run[2], H, T), run[1] * CFrame.new(0, H / 2, 0), color, tier.Material)
		end
	end

	local function partTower(cf: CFrame, r: number, h: number)
		local t = makePart(folder, "Tower", Vector3.new(h, r * 2, r * 2), cf * CFrame.new(0, h / 2, 0) * CFrame.Angles(0, 0, math.pi / 2), color, tier.Material)
		t.Shape = Enum.PartType.Cylinder
		local cap = makePart(folder, "TowerCap", Vector3.new(r * 2 + 1.5, 1.2, r * 2 + 1.5), cf * CFrame.new(0, h + 0.6, 0), tier.Roof, Enum.Material.SmoothPlastic)
		cap.CastShadow = false
	end
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local cf = base * CFrame.new(sx * W, 0, sz * W)
			if towerModel then
				local m = towerModel:Clone()
				m:PivotTo(cf)
				m.Parent = folder
			else
				partTower(cf, wt.CornerRadius, wt.CornerHeight)
			end
		end
	end

	local gateCf = base * CFrame.new(0, 0, W)
	local labelHeight
	if gateModel then
		local m = gateModel:Clone()
		m:PivotTo(gateCf)
		m.Parent = folder
		labelHeight = m:GetAttribute("LabelHeight")
	else
		for _, sx in ipairs({ -1, 1 }) do
			partTower(gateCf * CFrame.new(sx * gx, 0, 0), wt.GateRadius, wt.GateHeight)
		end
		local lintel = makePart(folder, "GateArch", Vector3.new(gx * 2, 3, T + 1), gateCf * CFrame.new(0, H + 1.5, 0), color, tier.Material)
		lintel.CanCollide = false
	end
	labelHeight = labelHeight or wt.GateHeight + 2

	-- Invisible anchor at the gate for the name tag and timer
	local anchor = makePart(folder, "Anchor", Vector3.new(1, 1, 1), gateCf, color, Enum.Material.SmoothPlastic)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	paintBanners(folder, data)

	local def = GameConfig.Buildings.Walls
	folder.PrimaryPart = anchor
	folder:SetAttribute("PlotId", "Walls_1")
	folder:SetAttribute("BuildingType", "Walls")
	folder:SetAttribute("Level", level)
	folder:SetAttribute("State", timer and "Upgrading" or "Built")
	local chip = if timer then ("Lv %d → %d"):format(level, timer.ToLevel) else ("Lv %d"):format(level)
	BuildingVisuals.AddLabel(folder, def.DisplayName, labelHeight, "Built", chip)
	if timer then
		addTimer(folder, timer, labelHeight)
	end

	folder.Parent = city.Model
end

local function renderPlot(city, plot, data)
	local old = city.Plots[plot.Id]
	if old then
		old:Destroy()
	end

	local def = GameConfig.Buildings[plot.Type]
	local size = plot.Type == "Castle" and CityCfg.CastlePlotSize or CityCfg.PlotSize
	local building = data.Buildings[plot.Id]
	local timer = buildTimerFor(data, plot.Id)
	local castleLevel = data.Buildings.Castle_1 and data.Buildings.Castle_1.Level or 1

	-- Name tag: style + small badge (see BuildingVisuals.AddLabel)
	local model, height, state, style, chip
	if building then
		model, height = BuildingVisuals.BuildBuilding(plot.Type, building.Level, size)
		if timer then
			state, style, chip = "Upgrading", "Built", ("Lv %d → %d"):format(building.Level, timer.ToLevel)
		else
			state, style, chip = "Built", "Built", ("Lv %d"):format(building.Level)
		end
	elseif timer then
		model, height = BuildingVisuals.BuildEmptyPlot(size, false, plot.Type, true)
		state, style = "Constructing", "Empty"
	elseif castleLevel >= def.UnlockAt then
		model, height = BuildingVisuals.BuildEmptyPlot(size, false, plot.Type)
		state, style, chip = "Empty", "Empty", "+ Build"
	else
		model, height = BuildingVisuals.BuildEmptyPlot(size, true)
		state, style, chip = "Locked", "Locked", ("🔒 Castle %d"):format(def.UnlockAt)
	end

	paintBanners(model, data)

	model.Name = plot.Id
	model:SetAttribute("PlotId", plot.Id)
	model:SetAttribute("BuildingType", plot.Type)
	model:SetAttribute("Level", building and building.Level or 0)
	model:SetAttribute("State", state)
	BuildingVisuals.AddLabel(model, def.DisplayName, height, style, chip)
	if timer then
		addTimer(model, timer, height)
	end
	-- Training is separate from the build timer (no worker goes there); each client shows the countdown
	local training = data.Timers["Train_" .. plot.Id]
	if training then
		model:SetAttribute("TrainStartsAt", training.StartedAt)
		model:SetAttribute("TrainEndsAt", training.EndsAt)
		model:SetAttribute("TrainTier", training.Tier)
		model:SetAttribute("TrainCount", training.Count)
		BuildingVisuals.AddTimerLabel(model, height, "TrainLabel", Color3.fromRGB(70, 130, 200))
	end
	-- Each client works out the stored amount from these and shows the collect bubble
	if state == "Built" and def.Produces and building.LastCollected then
		model:SetAttribute("ProduceResource", def.Produces)
		model:SetAttribute("ProduceRate", GameConfig.GetProductionPerHour(def.Produces, building.Level))
		model:SetAttribute("ProduceCapacity", GameConfig.GetProductionCapacity(def.Produces, building.Level))
		model:SetAttribute("ProduceSince", building.LastCollected)
	end
	model:PivotTo(CFrame.new(city.Origin + Vector3.new(plot.X, CityCfg.GroundY, plot.Z)))
	model.Parent = city.PlotsFolder
	city.Plots[plot.Id] = model
end

local function placeCharacter(player: Player, character: Model)
	local city = cities[player]
	if not city then
		return -- the city is not built yet; buildCity places the character when it is
	end
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root then
		return
	end
	if not character:IsDescendantOf(workspace) then
		character.AncestryChanged:Wait()
	end
	character:PivotTo(CFrame.new(city.Origin + CityCfg.SpawnOffset))
end

local function buildCity(player: Player)
	local data = PlayerDataService.GetData(player)
	if cities[player] or not data then
		return
	end
	local slot = claimSlot(player)
	local model = Instance.new("Model")
	model.Name = "City_" .. player.UserId
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("Slot", slot)
	-- StreamingEnabled: the owner always gets their whole city (the camera looks far from the
	-- character); everyone else streams it normally, so 100 cities never load at once.
	model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	model:AddPersistentPlayer(player)

	local plotsFolder = Instance.new("Folder")
	plotsFolder.Name = "Plots"
	plotsFolder.Parent = model

	local city = {
		Slot = slot,
		Origin = slotOrigin(slot),
		Model = model,
		PlotsFolder = plotsFolder,
		WallsFolder = nil,
		Plots = {},
	}
	cities[player] = city

	buildGround(city, data)
	buildWalls(city, data)
	for _, plot in ipairs(GameConfig.CityLayout) do
		renderPlot(city, plot, data)
	end
	model.Parent = citiesFolder

	player:SetAttribute("CityOrigin", city.Origin)
	if player.Character then
		task.spawn(placeCharacter, player, player.Character)
	end
end

local function destroyCity(player: Player)
	local city = cities[player]
	if not city then
		return
	end
	city.Model:Destroy()
	usedSlots[city.Slot] = nil
	cities[player] = nil
end

-- Re-renders one plot from the player's current data (after build/upgrade)
function CityService.RefreshPlot(player: Player, plotId: string)
	local city = cities[player]
	local data = PlayerDataService.GetData(player)
	if not city or not data then
		return
	end
	if plotId == "Walls_1" then
		buildWalls(city, data)
		return
	end
	local plot = plotById[plotId]
	if plot then
		renderPlot(city, plot, data)
	end
	-- A Castle upgrade can unlock other plots
	if plotId == "Castle_1" then
		for _, other in ipairs(GameConfig.CityLayout) do
			if not data.Buildings[other.Id] then
				renderPlot(city, other, data)
			end
		end
	end
end

function CityService.GetCity(player: Player)
	return cities[player]
end

function CityService.GetPlotModel(player: Player, plotId: string): Model?
	local city = cities[player]
	return city and city.Plots[plotId]
end

function CityService.Start(dataService)
	PlayerDataService = dataService
	applyLighting()

	citiesFolder = workspace:FindFirstChild("Cities") :: Folder
	if not citiesFolder then
		citiesFolder = Instance.new("Folder")
		citiesFolder.Name = "Cities"
		citiesFolder.Parent = workspace
	end

	PlayerDataService.Loaded:Connect(buildCity)
	Players.PlayerRemoving:Connect(destroyCity)

	local function onPlayerAdded(player: Player)
		player.CharacterAdded:Connect(function(character)
			placeCharacter(player, character)
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return CityService
