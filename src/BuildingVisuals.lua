-- BuildingVisuals: placeholder 3D models for every building, by type and visual tier.
-- Location in Studio: ReplicatedStorage.Modules.BuildingVisuals (ModuleScript)
-- Phase 1 placeholders built from Parts. The real models (6 per building, one per tier) replace
-- them one building at a time (see FindModel); the function signatures stay the same.
-- Every model is built around (0, 0, 0) = plot center at ground level; the pivot is that point.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)

local BuildingVisuals = {}

BuildingVisuals.Colors = {
	Castle = Color3.fromRGB(196, 186, 160),
	Walls = Color3.fromRGB(150, 140, 120),
	WatchTower = Color3.fromRGB(120, 95, 70),
	Farm = Color3.fromRGB(214, 180, 90),
	LumberMill = Color3.fromRGB(125, 85, 50),
	Quarry = Color3.fromRGB(140, 140, 145),
	GoldMine = Color3.fromRGB(230, 190, 60),
	Storehouse = Color3.fromRGB(160, 110, 70),
	Barracks = Color3.fromRGB(170, 60, 50),
	ArcheryRange = Color3.fromRGB(70, 120, 60),
	Stable = Color3.fromRGB(140, 90, 55),
	SiegeWorkshop = Color3.fromRGB(95, 85, 80),
	Hospital = Color3.fromRGB(235, 235, 230),
	Academy = Color3.fromRGB(70, 90, 160),
	Tavern = Color3.fromRGB(150, 80, 40),
	Embassy = Color3.fromRGB(120, 60, 140),
	Market = Color3.fromRGB(200, 120, 60),
}

-- One entry per GameConfig.VisualTiers row (Wooden, Stone, Fortified, Royal, Imperial, Legendary)
BuildingVisuals.Tiers = {
	{ Material = Enum.Material.WoodPlanks, Height = 1.0, Roof = Color3.fromRGB(120, 80, 45) },
	{ Material = Enum.Material.Cobblestone, Height = 1.25, Roof = Color3.fromRGB(110, 60, 50) },
	{ Material = Enum.Material.Slate, Height = 1.5, Roof = Color3.fromRGB(60, 65, 80) },
	{ Material = Enum.Material.Marble, Height = 1.75, Roof = Color3.fromRGB(40, 70, 140) },
	{ Material = Enum.Material.Granite, Height = 2.0, Roof = Color3.fromRGB(200, 160, 50) },
	{ Material = Enum.Material.Glass, Height = 2.3, Roof = Color3.fromRGB(120, 200, 255) },
}

local PAD_HEIGHT = 0.4
local PAD_COLOR = Color3.fromRGB(165, 140, 105)
local LOCKED_COLOR = Color3.fromRGB(110, 110, 115)

function BuildingVisuals.GetTier(level: number): number
	for i, tier in ipairs(GameConfig.VisualTiers) do
		if level >= tier.FromLevel and level <= tier.ToLevel then
			return i
		end
	end
	return 1
end

local function addPart(model: Model, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, className: string?)
	local p = Instance.new(className or "Part")
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- Small decoration: no shadow, no collision (cheaper on weak phones)
local function decor(p: BasePart)
	p.CastShadow = false
	p.CanCollide = false
	return p
end

local function addPad(model: Model, size: number, color: Color3, material: Enum.Material)
	local pad = addPart(model, Vector3.new(size, PAD_HEIGHT, size), CFrame.new(0, PAD_HEIGHT / 2, 0), color, material)
	pad.Name = "Pad"
	-- Model pivot = bottom center of the pad = local (0, 0, 0), so PivotTo(ground point) seats it on the ground
	pad.PivotOffset = CFrame.new(0, -PAD_HEIGHT / 2, 0)
	model.PrimaryPart = pad
	return pad
end

-- Box body with a gable roof (ridge along X). Returns the top Y of the roof.
local function addHouse(model: Model, w: number, d: number, h: number, offset: Vector3, color: Color3, tier)
	local baseY = PAD_HEIGHT + offset.Y
	addPart(model, Vector3.new(w, h, d), CFrame.new(offset.X, baseY + h / 2, offset.Z), color, tier.Material).Name = "Body"
	local roofH = math.max(2, h * 0.45)
	local roofY = baseY + h + roofH / 2
	local front = addPart(model, Vector3.new(w + 1, roofH, d / 2 + 0.5), CFrame.new(offset.X, roofY, offset.Z - d / 4), tier.Roof, Enum.Material.SmoothPlastic, "WedgePart")
	local back = addPart(model, Vector3.new(w + 1, roofH, d / 2 + 0.5), CFrame.new(offset.X, roofY, offset.Z + d / 4) * CFrame.Angles(0, math.pi, 0), tier.Roof, Enum.Material.SmoothPlastic, "WedgePart")
	front.Name, back.Name = "Roof", "Roof"
	return baseY + h + roofH
end

local function addTower(model: Model, diameter: number, h: number, pos: Vector3, color: Color3, tier)
	local baseY = PAD_HEIGHT
	addPart(model, Vector3.new(h, diameter, diameter), CFrame.new(pos.X, baseY + h / 2, pos.Z) * CFrame.Angles(0, 0, math.pi / 2), color, tier.Material).Shape = Enum.PartType.Cylinder
	local cap = addPart(model, Vector3.new(diameter + 1, 1, diameter + 1), CFrame.new(pos.X, baseY + h + 0.5, pos.Z), tier.Roof, Enum.Material.SmoothPlastic)
	decor(cap)
	return baseY + h + 1
end

local builders = {}

builders.Castle = function(model, size, color, tier)
	local keep = size * 0.45
	local h = 14 * tier.Height
	local top = addHouse(model, keep, keep, h, Vector3.zero, color, tier)
	local towerH = h + 6
	local off = keep / 2 + 2
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			addTower(model, 7, towerH, Vector3.new(sx * off, 0, sz * off), color, tier)
		end
	end
	-- Flag in the civilization colors comes later; red banner for now
	decor(addPart(model, Vector3.new(0.5, 8, 0.5), CFrame.new(0, top + 4, 0), Color3.fromRGB(60, 50, 40), Enum.Material.Wood))
	decor(addPart(model, Vector3.new(4, 2.5, 0.3), CFrame.new(2.2, top + 6.5, 0), Color3.fromRGB(180, 30, 30), Enum.Material.Fabric))
	return math.max(top, PAD_HEIGHT + towerH) + 8
end

builders.Farm = function(model, size, color, tier)
	local field = addPart(model, Vector3.new(size * 0.9, 0.3, size * 0.5), CFrame.new(0, PAD_HEIGHT + 0.15, -size * 0.2), Color3.fromRGB(150, 170, 60), Enum.Material.Grass)
	decor(field)
	for i = -2, 2 do
		decor(addPart(model, Vector3.new(size * 0.85, 0.6, 0.8), CFrame.new(0, PAD_HEIGHT + 0.5, -size * 0.2 + i * 2), color, Enum.Material.Fabric))
	end
	return addHouse(model, size * 0.35, size * 0.3, 5 * tier.Height, Vector3.new(-size * 0.2, 0, size * 0.25), Color3.fromRGB(170, 130, 90), tier)
end

builders.LumberMill = function(model, size, color, tier)
	local top = addHouse(model, size * 0.45, size * 0.4, 6 * tier.Height, Vector3.new(-size * 0.15, 0, -size * 0.1), color, tier)
	for i = 0, 2 do
		local log = addPart(model, Vector3.new(size * 0.4, 1.6, 1.6), CFrame.new(size * 0.22, PAD_HEIGHT + 0.8 + i * 1.4, size * 0.25 - (i % 2) * 0.8), Color3.fromRGB(110, 75, 45), Enum.Material.Wood)
		log.Shape = Enum.PartType.Cylinder
		decor(log)
	end
	return top
end

builders.Quarry = function(model, size, color, tier)
	local rocks = { { -0.2, 0.2, 7 }, { 0.15, 0.25, 5 }, { 0.25, -0.15, 6 }, { -0.25, -0.2, 4 } }
	for _, r in ipairs(rocks) do
		local rock = addPart(model, Vector3.new(r[3], r[3], r[3]), CFrame.new(r[1] * size, PAD_HEIGHT + r[3] * 0.35, r[2] * size), color, Enum.Material.Rock)
		rock.Shape = Enum.PartType.Ball
	end
	return addHouse(model, size * 0.25, size * 0.25, 4 * tier.Height, Vector3.new(0, 0, size * 0.05), Color3.fromRGB(150, 120, 90), tier)
end

builders.GoldMine = function(model, size, color, tier)
	local mound = addPart(model, Vector3.new(size * 0.7, 8 * tier.Height, size * 0.5), CFrame.new(0, PAD_HEIGHT + 4 * tier.Height, -size * 0.15), Color3.fromRGB(120, 110, 100), Enum.Material.Rock)
	mound.Name = "Body"
	decor(addPart(model, Vector3.new(5, 5, 1), CFrame.new(0, PAD_HEIGHT + 2.5, -size * 0.15 + size * 0.25 + 0.4), Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic))
	decor(addPart(model, Vector3.new(4, 2, 3), CFrame.new(size * 0.25, PAD_HEIGHT + 1, size * 0.3), color, Enum.Material.Metal))
	return PAD_HEIGHT + 8 * tier.Height
end

builders.WatchTower = function(model, size, color, tier)
	local h = 18 * tier.Height
	addPart(model, Vector3.new(7, h, 7), CFrame.new(0, PAD_HEIGHT + h / 2, 0), color, tier.Material).Name = "Body"
	decor(addPart(model, Vector3.new(10, 1, 10), CFrame.new(0, PAD_HEIGHT + h + 0.5, 0), tier.Roof, Enum.Material.WoodPlanks))
	local fire = decor(addPart(model, Vector3.new(2.5, 2.5, 2.5), CFrame.new(0, PAD_HEIGHT + h + 2.2, 0), Color3.fromRGB(255, 140, 30), Enum.Material.Neon))
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 60)
	light.Range = 16
	light.Parent = fire
	return PAD_HEIGHT + h + 4
end

builders.Hospital = function(model, size, color, tier)
	local top = addHouse(model, size * 0.6, size * 0.5, 4 * tier.Height, Vector3.zero, color, tier)
	decor(addPart(model, Vector3.new(4, 0.4, 1.2), CFrame.new(0, top + 0.3, 0), Color3.fromRGB(200, 30, 30), Enum.Material.SmoothPlastic))
	decor(addPart(model, Vector3.new(1.2, 0.4, 4), CFrame.new(0, top + 0.3, 0), Color3.fromRGB(200, 30, 30), Enum.Material.SmoothPlastic))
	return top + 1
end

local function genericBuilder(model, size, color, tier)
	return addHouse(model, size * 0.65, size * 0.55, 7 * tier.Height, Vector3.zero, color, tier)
end

-- Real models (V art pass): ReplicatedStorage.Assets.BuildingModels.<Type>_<tier>, with attributes PlotSize and
-- LabelHeight. Replicated because the map (client) shows the castle models too.
function BuildingVisuals.FindModel(buildingType: string, tierIndex: number): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild("BuildingModels")
	return folder and folder:FindFirstChild(buildingType .. "_" .. tierIndex)
end

-- A wall run of `length` studs: WallSegment_N is 1 stud long, so its parts stretch along X and its
-- "Repeat" unit (merlons/stakes) is copied every Repeat.Every studs. Local +Z = outside of the city.
-- Used by the city walls (CityService) and the map castle icon (MapVisuals).
function BuildingVisuals.PlaceWallSegment(parent: Instance, template: Model, cf: CFrame, length: number)
	local m = template:Clone()
	local rep = m:FindFirstChild("Repeat")
	if rep then
		rep.Parent = nil
	end
	for _, p in ipairs(m:GetChildren()) do
		if p:IsA("BasePart") then
			p.Size = Vector3.new(p.Size.X * length, p.Size.Y, p.Size.Z)
		end
	end
	if rep then
		local every = rep:GetAttribute("Every")
		local n = math.max(1, math.floor(length / every))
		for k = 0, n - 1 do
			local unit = rep:Clone()
			unit:PivotTo(CFrame.new((k - (n - 1) / 2) * every, 0, 0))
			unit.Parent = m
		end
		rep:Destroy()
	end
	m:PivotTo(cf)
	m.Parent = parent
end

-- Builds a finished building. Returns the model (not parented) and the height for the label.
-- Uses the real model when there is one, else the Part placeholder below.
function BuildingVisuals.BuildBuilding(buildingType: string, level: number, size: number)
	local tierIndex = BuildingVisuals.GetTier(level)
	local template = BuildingVisuals.FindModel(buildingType, tierIndex)
	if template then
		local model = template:Clone()
		model.Name = buildingType
		local scale = size / (template:GetAttribute("PlotSize") or size)
		if scale ~= 1 then
			model:ScaleTo(scale)
		end
		return model, (template:GetAttribute("LabelHeight") or 20) * scale
	end

	local model = Instance.new("Model")
	model.Name = buildingType
	local tier = BuildingVisuals.Tiers[tierIndex]
	local color = BuildingVisuals.Colors[buildingType] or Color3.fromRGB(160, 160, 160)
	addPad(model, size, PAD_COLOR, Enum.Material.Ground)
	local builder = builders[buildingType] or genericBuilder
	local height = builder(model, size, color, tier)
	return model, height
end

local GHOST_COLOR = Color3.fromHex("5ec8f0")
local FOUNDATION_COLOR = Color3.fromHex("8e8b84")

-- See-through copy of the level-1 model of a building ("Ghost"): shows what will stand on an empty plot
local function addGhost(model: Model, buildingType: string, size: number): number?
	local template = BuildingVisuals.FindModel(buildingType, 1)
	if not template then
		return nil
	end
	local ghost = template:Clone()
	ghost.Name = "Ghost"
	local scale = size / (template:GetAttribute("PlotSize") or size)
	if scale ~= 1 then
		ghost:ScaleTo(scale)
	end
	local pad = ghost.PrimaryPart
	for _, d in ipairs(ghost:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency > 0.95 then
			d:Destroy() -- hidden helpers (pivots, arrows in flight) stay hidden
		elseif d:IsA("BasePart") then
			d.Material = Enum.Material.ForceField
			d.Color = GHOST_COLOR
			d.Transparency = GameConfig.UpgradeFX.GhostTransparency
			d.CastShadow = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("Decal") or d:IsA("Texture") or d:IsA("Light") or d:IsA("Fire") or d:IsA("ParticleEmitter")
			or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("LayerCollector") then
			d:Destroy()
		end
	end
	ghost.PrimaryPart = nil
	if pad then
		pad:Destroy()
	end
	ghost:PivotTo(model:GetPivot())
	ghost.Parent = model
	return (template:GetAttribute("LabelHeight") or 20) * scale
end

-- Builds an empty plot: buildable (surveyed ground + the ghost of `buildingType`) or locked (stone, barrier
-- and lock). `constructing`: the survey stakes go, a stone foundation goes under the ghost.
-- Uses BuildingModels.EmptyPlot / LockedPlot (PlotModelBuilder) when there, else Parts.
function BuildingVisuals.BuildEmptyPlot(size: number, locked: boolean, buildingType: string?, constructing: boolean?)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local folder = assets and assets:FindFirstChild("BuildingModels")
	local template = folder and folder:FindFirstChild(locked and "LockedPlot" or "EmptyPlot")
	if template then
		local model = template:Clone()
		local scale = size / (template:GetAttribute("PlotSize") or size)
		if scale ~= 1 then
			model:ScaleTo(scale)
		end
		local height = (template:GetAttribute("LabelHeight") or 4) * scale
		if not locked and buildingType then
			if constructing then
				for _, name in ipairs({ "Survey", "BuildCorners" }) do
					local child = model:FindFirstChild(name)
					if child then
						child:Destroy()
					end
				end
			end
			local ghostHeight = addGhost(model, buildingType, size)
			if ghostHeight then
				height = math.max(height, ghostHeight)
			end
			local ghost = model:FindFirstChild("Ghost")
			if constructing and ghost then
				local cf, ext = ghost:GetBoundingBox()
				local f = addPart(model, Vector3.new(ext.X, 1.2, ext.Z), CFrame.new(cf.Position.X, model:GetPivot().Y + PAD_HEIGHT + 0.6, cf.Position.Z), FOUNDATION_COLOR, Enum.Material.Cobblestone)
				f.Name = "Foundation"
				f.CanQuery = false
				decor(f)
			end
		end
		return model, height
	end

	local model = Instance.new("Model")
	model.Name = locked and "LockedPlot" or "EmptyPlot"
	addPad(model, size, locked and LOCKED_COLOR or PAD_COLOR, locked and Enum.Material.Slate or Enum.Material.Ground)
	if not locked then
		local half = size / 2 - 1
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				decor(addPart(model, Vector3.new(0.6, 2.5, 0.6), CFrame.new(sx * half, PAD_HEIGHT + 1.25, sz * half), Color3.fromRGB(110, 80, 50), Enum.Material.Wood))
			end
		end
	end
	return model, PAD_HEIGHT + 3
end

-- Name tag looks (docs\art\plots_construction.html, section 4)
local TAG = {
	Built = { Back = 0.22, Stroke = Color3.fromHex("8a6420"), Ink = Color3.fromHex("f2e6c4") },
	Empty = { Back = 0.45, Stroke = Color3.fromHex("3a3328"), Ink = Color3.fromHex("c9c0ac") },
	Locked = { Back = 0.5, Stroke = Color3.fromHex("2a2d33"), Ink = Color3.fromHex("bdb8ad") },
}
local CHIP = {
	Level = { Top = Color3.fromHex("f2d488"), Bottom = Color3.fromHex("c08f30"), Ink = Color3.fromHex("1b1608") },
	Build = { Top = Color3.fromHex("2f6d4a"), Bottom = Color3.fromHex("1a3f2e"), Ink = Color3.new(1, 1, 1) },
	Lock = { Top = Color3.fromHex("3a3d44"), Bottom = Color3.fromHex("3a3d44"), Ink = Color3.fromHex("d9d4c8") },
}
local TAG_HEIGHT = 2.6 -- studs
local CHAR_WIDTH = 1.15 -- studs per character at that height (a rough guess: TextScaled shrinks long names)

local function corner(parent: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function chipLabel(parent: Instance, name: string, text: string, kind: string, widthScale: number, order: number)
	local look = CHIP[kind]
	local chip = Instance.new("TextLabel")
	chip.Name = name
	chip.LayoutOrder = order
	chip.Size = UDim2.fromScale(widthScale, 0.72)
	chip.BackgroundColor3 = Color3.new(1, 1, 1)
	chip.TextColor3 = look.Ink
	chip.TextScaled = true
	chip.FontFace = GameConfig.Art.Fonts.Number
	chip.Text = text
	chip.Parent = parent
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(look.Top, look.Bottom)
	g.Rotation = 90
	g.Parent = chip
	corner(chip, 0.25)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0.1, 0), UDim.new(0.1, 0)
	pad.Parent = chip
	return chip
end

-- Floating name tag above a plot, sized in studs so it shrinks as the camera zooms out.
-- style: "Built" (default), "Empty" or "Locked" (true = "Empty", the old `faded`). chip: text of the small
-- badge: "Lv 5" (Built, before the name), "+ Build" (Empty, after; named BuildChip, the client hides it when
-- the player can't build), "🔒 Castle 8" (Locked, after).
function BuildingVisuals.AddLabel(model: Model, text: string, height: number, style: (string | boolean)?, chip: string?)
	style = if style == true then "Empty" elseif type(style) == "string" then style else "Built"
	local look = TAG[style] or TAG.Built
	local chipKind = if style == "Empty" then "Build" elseif style == "Locked" then "Lock" else "Level"
	local nameW = #text * CHAR_WIDTH + 0.8
	local chipW = chip and (utf8.len(chip) or #chip) * CHAR_WIDTH * 0.62 + 0.9 or 0
	local width = nameW + chipW + (chip and 0.6 or 0) + 0.6

	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Adornee = model.PrimaryPart
	gui.Size = UDim2.new(width, 0, TAG_HEIGHT, 0)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height + 2, 0)
	gui.LightInfluence = 0
	gui.Parent = model

	local frame = Instance.new("Frame")
	frame.Name = "Tag"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromHex("14171c")
	frame.BackgroundTransparency = look.Back
	frame.Parent = gui
	corner(frame, 0.3)
	local stroke = Instance.new("UIStroke")
	stroke.Color = look.Stroke
	stroke.Thickness = 2
	stroke.Parent = frame
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0.6 / width, 0)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.LayoutOrder = 2
	label.Size = UDim2.fromScale(nameW / width, 0.78)
	label.BackgroundTransparency = 1
	label.TextColor3 = look.Ink
	label.TextScaled = true
	label.FontFace = if style == "Built" then GameConfig.Art.Fonts.Title else GameConfig.Art.Fonts.Subtitle
	label.Text = text
	label.Parent = frame

	if chip then
		chipLabel(frame, if style == "Empty" then "BuildChip" else "Chip", chip, chipKind, chipW / width, if style == "Built" then 1 else 3)
	end
	return gui
end

-- Countdown tag above the name tag while a build/upgrade (or training) runs. The server makes it; each client
-- writes the time left into its "Time" label and the progress into Back.Bar (from the model's attributes),
-- so the server sends nothing per second. Pass a color for training (blue, ⚔), else it's the build look (⚒).
function BuildingVisuals.AddTimerLabel(model: Model, height: number, name: string?, color: Color3?)
	local training = color ~= nil
	local gui = Instance.new("BillboardGui")
	gui.Name = name or "TimerLabel"
	gui.Adornee = model.PrimaryPart
	gui.Size = UDim2.new(10, 0, 2.4, 0)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height + 6, 0)
	gui.LightInfluence = 0
	gui.Parent = model

	local ink = if training then Color3.new(1, 1, 1) else Color3.fromHex("2a1a06")
	local back = Instance.new("Frame")
	back.Name = "Back"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = if training then Color3.fromHex("4f9fe0") else Color3.fromHex("e0a03a")
	back.ClipsDescendants = true
	back.Parent = gui
	corner(back, 0.3)
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = if training then Color3.fromHex("24557f") else Color3.fromHex("8a5a14")
	stroke.Thickness = 2
	stroke.Parent = back

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0.04, 0.5)
	icon.Size = UDim2.fromScale(0.18, 0.76)
	icon.BackgroundColor3 = Color3.new(0, 0, 0)
	icon.BackgroundTransparency = 0.8
	icon.TextColor3 = ink
	icon.TextScaled = true
	icon.Text = if training then "⚔" else "⚒"
	icon.Parent = back
	corner(icon, 0.25)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.fromScale(0, 1)
	bar.Size = UDim2.fromScale(0, 0.12)
	bar.BackgroundColor3 = Color3.new(1, 1, 1)
	bar.BackgroundTransparency = 0.4
	bar.BorderSizePixel = 0
	bar.Parent = back

	local label = Instance.new("TextLabel")
	label.Name = "Time"
	label.Position = UDim2.fromScale(0.25, 0.12)
	label.Size = UDim2.fromScale(0.7, 0.7)
	label.BackgroundTransparency = 1
	label.TextColor3 = ink
	label.TextScaled = true
	label.FontFace = GameConfig.Art.Fonts.Number
	label.Text = "..."
	label.ZIndex = 2
	label.Parent = gui
	return gui
end

-- Fills a timer tag's progress bar (0..1)
function BuildingVisuals.SetTimerProgress(gui: Instance, progress: number)
	local back = gui:FindFirstChild("Back")
	local bar = back and back:FindFirstChild("Bar")
	if bar then
		bar.Size = UDim2.fromScale(math.clamp(progress, 0, 1), 0.12)
	end
end

return BuildingVisuals
