-- MapVisuals: looks for the kingdom map (decor on the baked Terrain, icons, labels).
-- Location in Studio: ReplicatedStorage.Modules.MapVisuals (ModuleScript)
-- Only looks live here (the logic is in MapController / KingdomMapService), so the final visual
-- identity can replace this module alone. Colors and sizes are in GameConfig.Map.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local KingdomMapGen = require(ReplicatedStorage.Modules.KingdomMapGen)
local BuildingVisuals = require(ReplicatedStorage.Modules.BuildingVisuals)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local Cfg = GameConfig.Map

local MapVisuals = {}

local TILE = Cfg.TileStuds
local SIZE = Cfg.Size
local CENTER = (SIZE + 1) / 2

local function part(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Parent = parent
	return p
end

local D = Cfg.Decor
local LINE = GameConfig.March.Line
local pulsing: { [Beam]: boolean } = {} -- incoming march beams, pulsed by stepMotion
local selectorParts: { BasePart } = {} -- the selector's corners, pulsed by stepMotion

-- World Y of the ground at a tile center (the baked Terrain follows KingdomMapGen.SurfaceHeight)
local function tileTop(x: number, y: number): number
	return math.max(Cfg.GroundY, (Cfg.Terrain.SurfaceY + Cfg.Terrain.RenderLift) + KingdomMapGen.SurfaceHeight(x, y))
end
MapVisuals.TileTop = tileTop

-- Same random number for a tile on every client (decor is not saved)
local function hash(x: number, y: number, k: number): number
	local v = math.sin(x * 12.9898 + y * 78.233 + k * 37.719 + Cfg.Seed) * 43758.5453
	return v - math.floor(v)
end

-- World CFrame of the top-center of a block of tiles (x1..x2, y1..y2), `height` studs tall
local function blockCFrame(x1: number, y1: number, x2: number, y2: number, topY: number, height: number): CFrame
	local cx = (x1 + x2) / 2
	local cy = (y1 + y2) / 2
	local pos = Cfg.Origin + Vector3.new((cx - CENTER) * TILE, topY - height / 2, (cy - CENTER) * TILE)
	return CFrame.new(pos)
end

-- The ground itself is Terrain baked in the place (tools\MapTerrainBuilder). This adds what sits on it:
-- the zone borders (a thin gold dash on the outer edge of every border tile, and a stone post with a
-- gold cap every PostEvery tiles), then the trees and Crown Lands ruins.
function MapVisuals.BuildGround(parent: Instance)
	local ground = Instance.new("Model")
	ground.Name = "Ground"
	for i = 2, #Cfg.Zones do
		local r = Cfg.Zones[i].MaxRadius
		local x1, x2 = math.ceil(CENTER - r), math.floor(CENTER + r)
		local n = 0
		local function dash(x: number, y: number, dx: number, dy: number)
			-- (dx, dy) = which side of the tile is the outer edge
			local pos = Cfg.Origin + Vector3.new((x - CENTER + dx / 2) * TILE, 0, (y - CENTER + dy / 2) * TILE)
			-- on the ground, or on the water surface where the border crosses a lake
			local y = math.max(KingdomMapGen.GroundYAt(pos), (Cfg.Terrain.SurfaceY + Cfg.Terrain.RenderLift) + Cfg.Terrain.WaterLevel)
			pos = Vector3.new(pos.X, y + 0.05, pos.Z)
			local size = if dx ~= 0 then Vector3.new(0.35, 0.12, TILE * 0.55) else Vector3.new(TILE * 0.55, 0.12, 0.35)
			part("ZoneLine", size, CFrame.new(pos), D.ZoneLineColor, ground)
			n += 1
			if n % D.PostEvery == 1 then
				part("ZonePost", Vector3.new(0.6, 2.6, 0.6), CFrame.new(pos + Vector3.new(0, 1.3, 0)), D.PostColor, ground)
				local cap = part("ZonePost", Vector3.new(0.8, 0.8, 0.8), CFrame.new(pos + Vector3.new(0, 2.85, 0)), D.PostCapColor, ground)
				cap.Shape = Enum.PartType.Ball
			end
		end
		for x = x1, x2 do
			dash(x, x1, 0, -1)
			dash(x, x2, 0, 1)
		end
		for y = x1, x2 do
			dash(x1, y, -1, 0)
			dash(x2, y, 1, 0)
		end
	end
	ground.Parent = parent
	MapVisuals.BuildDecor(parent)
	return ground
end

------------------------------------------------------------------------
-- Decor (client only, from the seed): trees and Crown Lands pillars
------------------------------------------------------------------------
local mapModels = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("MapModels")

-- One tree: a clone of MapModels.<name> (pivot at the trunk bottom), or a plain ball if it is missing.
-- Skipped on banks, in water and on mountain slopes.
local function tree(name: string, at: Vector3, scale: number, yaw: number, parent: Instance)
	local h = at.Y + 0.1 - (Cfg.Terrain.SurfaceY + Cfg.Terrain.RenderLift)
	if h < -0.05 or h > D.TreeMaxHeight then
		return
	end
	local template = mapModels and mapModels:FindFirstChild(name)
	if template then
		local t = template:Clone()
		if t:IsA("Model") then
			t:ScaleTo(t:GetScale() * scale)
		elseif t:IsA("BasePart") then
			t.Size *= scale
		end
		t:PivotTo(CFrame.new(at) * CFrame.Angles(0, yaw, 0))
		t.Parent = parent
		return
	end
	local d = 3.4 * scale
	local p = part(name, Vector3.new(d, d, d), CFrame.new(at + Vector3.new(0, d * 0.45, 0)), Color3.fromRGB(58, 115, 60), parent)
	p.Shape = Enum.PartType.Ball
end

local function decorTile(x: number, y: number, folder: Instance)
	local biome = KingdomMapGen.GetBiome(x, y)
	if biome == "River" or biome == "Mountain" or KingdomMapGen.GetFeatureAt(x, y) then
		return
	end
	local roll = hash(x, y, 1)
	local center = KingdomMapGen.TileToWorld(x, y)
	local function spot(k: number): Vector3 -- a random point inside the tile, on the ground
		local p = Vector3.new(center.X + (hash(x, y, k) - 0.5) * TILE * 0.7, 0, center.Z + (hash(y, x, k) - 0.5) * TILE * 0.7)
		return Vector3.new(p.X, KingdomMapGen.GroundYAt(p) - 0.1, p.Z)
	end
	local function scale(k: number): number
		return D.TreeScale[1] + (D.TreeScale[2] - D.TreeScale[1]) * hash(x, y, k)
	end
	if biome == "Forest" and roll < D.ForestChance then
		local count = math.floor(D.ForestTrees[1] + (D.ForestTrees[2] - D.ForestTrees[1]) * hash(x, y, 2) + 0.5)
		for i = 1, count do
			tree("Pine", spot(20 + i), scale(10 + i), hash(x, y, 30 + i) * math.pi * 2, folder)
		end
	elseif biome == "Plains" and roll < D.OakChance then
		tree("Oak", spot(4), scale(3), hash(x, y, 5) * math.pi * 2, folder)
	end
	if biome == "Plains" and KingdomMapGen.GetZone(x, y) == #Cfg.Zones and hash(x, y, 16) < D.PillarChance then
		local at = Vector3.new(center.X, tileTop(x, y), center.Z)
		local pillar = part("Pillar", Vector3.new(3.5, 0.9, 0.9), CFrame.new(at + Vector3.new(0, 1.75, 0)) * CFrame.Angles(0, 0, math.pi / 2), D.PillarColor, folder)
		pillar.Shape = Enum.PartType.Cylinder
		pillar.Material = Enum.Material.Marble
		local cap = part("Pillar", Vector3.new(1.4, 0.3, 1.4), CFrame.new(at + Vector3.new(0, 3.65, 0)), D.PillarColor, folder)
		cap.Material = Enum.Material.Marble
	end
end

local decorAt: { [number]: { Instance } } = {} -- tile key -> its decor (castles clear it)

function MapVisuals.BuildDecor(parent: Instance)
	local folder = Instance.new("Model")
	folder.Name = "Decor"
	folder.Parent = parent
	table.clear(decorAt)
	local tmp = Instance.new("Folder")
	for y = 1, SIZE do
		-- each row goes in its own model, so parenting stays small
		local row = Instance.new("Model")
		row.Name = "Row"
		for x = 1, SIZE do
			decorTile(x, y, tmp)
			local kids = tmp:GetChildren()
			if #kids > 0 then
				decorAt[KingdomMapGen.Key(x, y)] = kids
				for _, k in ipairs(kids) do
					k.Parent = row
				end
			end
		end
		row.Parent = folder
		if y % 10 == 0 then
			task.wait()
		end
	end
	tmp:Destroy()
	return folder
end

-- Removes the decor on a tile (a castle stands there now)
function MapVisuals.ClearDecor(x: number, y: number)
	local key = KingdomMapGen.Key(x, y)
	for _, p in ipairs(decorAt[key] or {}) do
		p:Destroy()
	end
	decorAt[key] = nil
end

-- A name chip (map.html section 7): dark rounded pill with a colored border, an optional colored dot,
-- the name, and an optional gold "Lv N" badge. opts = {border?, color?, dot?, badge?, badgeTop?, badgeBottom?, badgeText?}
local CH = Cfg.Chip
local function addLabel(adornee: BasePart, text: string, opts, maxDistance: number, offsetY: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.new(0, 280, 0, CH.Height)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = maxDistance
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true -- from above the label sits over its model, and the Terrain grass hid it
	gui.Adornee = adornee
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.AnchorPoint = Vector2.new(0.5, 0.5)
	chip.Position = UDim2.fromScale(0.5, 0.5)
	chip.Size = UDim2.new(0, 0, 1, 0)
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.BackgroundColor3 = CH.Background
	chip.BackgroundTransparency = CH.BackgroundTransparency
	UIStyle.Corner(chip, UDim.new(0.5, 0))
	UIStyle.Stroke(chip, opts.border or CH.Border, 1.5)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 9)
	pad.PaddingRight = UDim.new(0, if opts.badge then 3 else 9)
	pad.Parent = chip
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 5)
	list.Parent = chip
	if opts.dot then
		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.Size = UDim2.fromOffset(10, 10)
		dot.BackgroundColor3 = opts.dot
		dot.LayoutOrder = 1
		UIStyle.Corner(dot, UDim.new(0.5, 0))
		dot.Parent = chip
	end
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0, 0, 1, 0)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Text = text
	label.LayoutOrder = 2
	UIStyle.Text(label, "Number", CH.TextSize, opts.color or CH.Text)
	label.Parent = chip
	if opts.badge then
		-- a Frame with the gradient and the text in a child (a gradient also tints its object's own text)
		local badge = Instance.new("Frame")
		badge.Name = "Badge"
		badge.Size = UDim2.new(0, 0, 1, -6)
		badge.AutomaticSize = Enum.AutomaticSize.X
		badge.LayoutOrder = 3
		if opts.badgeTop then
			badge.BackgroundColor3 = opts.badgeTop
		else
			UIStyle.Gradient(badge, CH.BadgeTop, CH.BadgeBottom)
		end
		UIStyle.Corner(badge, UDim.new(0.5, 0))
		local bt = Instance.new("TextLabel")
		bt.Name = "Text"
		bt.BackgroundTransparency = 1
		bt.Size = UDim2.new(0, 0, 1, 0)
		bt.AutomaticSize = Enum.AutomaticSize.X
		bt.Text = opts.badge
		UIStyle.Text(bt, "Number", CH.TextSize - 2, opts.badgeText or CH.BadgeText)
		local bp = Instance.new("UIPadding")
		bp.PaddingLeft = UDim.new(0, 7)
		bp.PaddingRight = UDim.new(0, 7)
		bp.Parent = bt
		bt.Parent = badge
		badge.Parent = chip
	end
	chip.Parent = gui
	gui.Parent = adornee
	return gui
end

-- 1234 -> "1.2K"
local function shortCount(n: number): string
	if n >= 1e6 then
		return (("%.1fM"):format(n / 1e6):gsub("%.0M", "M"))
	elseif n >= 1e3 then
		return (("%.1fK"):format(n / 1e3):gsub("%.0K", "K"))
	end
	return tostring(n)
end

-- Moving pieces of the feature models (client only): filled by BuildFeatures, moved by stepMotion
local motion: { { kind: string, at: Vector3, inst: Instance, base: any, size: Vector3?, phase: number } } = {}

local function collectMotion(model: Model, at: Vector3, phase: number)
	for _, d in ipairs(model:GetDescendants()) do
		if d.Name == "Aura" and d:IsA("Model") then
			table.insert(motion, { kind = "Aura", at = at, inst = d, base = d:GetPivot(), phase = phase })
		elseif d.Name == "Wolf" and d:IsA("Model") then
			table.insert(motion, { kind = "Wolf", at = at, inst = d, base = d:GetPivot(), phase = phase + #motion })
		elseif (d.Name == "Flame" or d.Name == "Glint") and d:IsA("BasePart") then
			table.insert(motion, { kind = d.Name, at = at, inst = d, base = d.CFrame, size = d.Size, phase = phase })
		end
	end
end

-- One node/monster: a clone of MapModels.Node_<Resource>_<band> / Monster_<band> seated on the tile,
-- turned at random (from the seed). Returns the model and its label height above the Pad, or nil.
local function placeFeature(f, top: number, folder: Instance): (Model?, number?)
	local band = math.clamp(math.ceil(f.Level / 3), 1, 3)
	local name = if f.Kind == "Resource" then ("Node_%s_%d"):format(f.Resource :: string, band) else "Monster_" .. band
	local template = mapModels and mapModels:FindFirstChild(name)
	if not template then
		return nil
	end
	local m = template:Clone()
	local scale = Cfg.FeatureScale or 1
	if scale ~= 1 then
		m:ScaleTo(scale)
	end
	local pos = KingdomMapGen.TileToWorld(f.X, f.Y)
	local at = Vector3.new(pos.X, top, pos.Z)
	m:PivotTo(CFrame.new(at) * CFrame.Angles(0, math.floor(hash(f.X, f.Y, 41) * 8) * math.pi / 4, 0))
	m.Parent = folder
	collectMotion(m, at, hash(f.X, f.Y, 42) * 10)
	-- the label hangs on the PrimaryPart: its offset is from that part's center up to the model top
	local primary = m.PrimaryPart :: BasePart
	return m, (m:GetAttribute("LabelHeight") or 3) * scale - (primary.Position.Y - at.Y) + 1.5
end

-- Resource nodes and monsters (static, from the seed)
function MapVisuals.BuildFeatures(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Features"
	folder.Parent = parent -- first: each model then goes in on its own (small parent writes)
	table.clear(motion)
	for i, f in ipairs(KingdomMapGen.GetFeatures()) do
		local top = tileTop(f.X, f.Y)
		local model, labelY = placeFeature(f, top, folder)
		local text, opts
		if f.Kind == "Resource" then
			text = f.Resource :: string
			opts = { dot = Cfg.NodeColors[f.Resource], badge = "Lv " .. f.Level }
		else
			text = Cfg.MonsterNames[math.clamp(math.ceil(f.Level / 3), 1, 3)]
			opts = { border = CH.MonsterColor, badge = "Lv " .. f.Level, badgeTop = CH.MonsterColor, badgeText = Color3.new(1, 1, 1) }
		end
		if model then
			addLabel(model.PrimaryPart :: BasePart, text, opts, Cfg.LabelMaxDistance, labelY :: number)
		elseif f.Kind == "Resource" then
			local h = 2 + f.Level * 0.3
			local p = part("Node", Vector3.new(TILE * 0.6, h, TILE * 0.6), blockCFrame(f.X, f.Y, f.X, f.Y, top + h, h),
				Cfg.NodeColors[f.Resource], folder)
			addLabel(p, text, opts, Cfg.LabelMaxDistance, h / 2 + 2)
		else
			local d = TILE * 0.55
			local p = part("Monster", Vector3.new(d, d, d), blockCFrame(f.X, f.Y, f.X, f.Y, top + d, d), Cfg.MonsterColor, folder)
			p.Shape = Enum.PartType.Ball
			addLabel(p, text, opts, Cfg.LabelMaxDistance, d / 2 + 2)
		end
		if i % 60 == 0 then
			task.wait()
		end
	end
	return folder
end

-- Light motion near the camera: monster rings turn, wolves sway, campfires flicker, gold glints pulse
local FM = Cfg.FeatureMotion
local lastStep = 0
local function stepMotion()
	local now = os.clock()
	if now - lastStep < 1 / FM.Fps then
		return
	end
	lastStep = now
	-- the selected tile's corners and attacks coming at you pulse (anywhere on the map)
	local sel = 0.45 * (0.5 + 0.5 * math.sin(now * Cfg.Selector.PulseSpeed))
	for _, p in ipairs(selectorParts) do
		p.Transparency = sel
	end
	local beat = NumberSequence.new(0.6 * (0.5 + 0.5 * math.sin(now * LINE.PulseSpeed)))
	for beam in pairs(pulsing) do
		beam.Transparency = beat
	end
	local cam = workspace.CurrentCamera
	local look = cam.CFrame.LookVector
	if look.Y > -0.05 then
		return
	end
	-- where the camera looks on the map plane
	local p = cam.CFrame.Position
	local focus = p + look * ((Cfg.GroundY - p.Y) / look.Y)
	local r2 = FM.Radius * FM.Radius
	for _, e in ipairs(motion) do
		local d = e.at - focus
		if d.X * d.X + d.Z * d.Z < r2 and e.inst.Parent then
			local t = now + e.phase
			if e.kind == "Aura" then
				(e.inst :: Model):PivotTo(e.base * CFrame.Angles(0, t * FM.AuraSpin, 0))
			elseif e.kind == "Wolf" then
				(e.inst :: Model):PivotTo(e.base * CFrame.Angles(0, math.sin(t * FM.WolfSwaySpeed) * FM.WolfSway, 0))
			elseif e.kind == "Flame" then
				local part = e.inst :: BasePart
				local k = 1 + 0.25 * math.sin(t * FM.FlameFlicker) + 0.1 * math.sin(t * FM.FlameFlicker * 2.3)
				local size = e.size :: Vector3
				part.Size = Vector3.new(size.X, size.Y * k, size.Z)
				part.CFrame = e.base * CFrame.new(0, size.Y * (k - 1) / 2, 0) -- grows from its bottom
			else
				(e.inst :: BasePart).Transparency = 0.15 + 0.6 * (0.5 + 0.5 * math.sin(t * FM.GlintSpeed))
			end
		end
	end
end

local motionConn: RBXScriptConnection? = nil
-- MapController turns this on while the map is open
function MapVisuals.SetFeatureMotion(on: boolean)
	if on and not motionConn then
		motionConn = game:GetService("RunService").RenderStepped:Connect(stepMotion)
	elseif not on and motionConn then
		motionConn:Disconnect()
		motionConn = nil
	end
end

-- Drops the pad and parts too small to see after shrinking, and makes the rest non-interactive
local function slimIcon(icon: Model, minPart: number)
	local pad = icon.PrimaryPart
	for _, d in ipairs(icon:GetDescendants()) do
		if d:IsA("BasePart") then
			local s = d.Size
			if d == pad or math.max(s.X, s.Y, s.Z) < minPart then
				d:Destroy()
			else
				d.CanCollide, d.CanTouch, d.CanQuery, d.CastShadow = false, false, false, false
			end
		end
	end
end

-- A small copy of the city walls (runs, corner towers, gate on the south side) around the castle icon.
-- Uses the castle's tier: the map list only knows the castle level. Built at city size, then shrunk by `scale`.
local function addWallRing(model: Model, level: number, at: CFrame, scale: number)
	local tierIndex = BuildingVisuals.GetTier(level)
	local seg = BuildingVisuals.FindModel("WallSegment", tierIndex)
	local tower = BuildingVisuals.FindModel("WallTower", tierIndex)
	local gate = BuildingVisuals.FindModel("WallGate", tierIndex)
	if not (seg and tower and gate) then
		return
	end
	local wt = GameConfig.City.WallTiers[tierIndex]
	local W = TILE * Cfg.CastleIconWallHalf / scale
	local gx = GameConfig.City.GateWidth / 2 + wt.GateRadius + 0.4 -- gate tower centers, as in CityService
	local ring = Instance.new("Model")
	ring.Name = "WallRing"
	local runs = {
		{ CFrame.new(0, 0, -W) * CFrame.Angles(0, math.pi, 0), W * 2 },
		{ CFrame.new(W, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), W * 2 },
		{ CFrame.new(-W, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), W * 2 },
		{ CFrame.new(-(gx + W) / 2, 0, W), W - gx },
		{ CFrame.new((gx + W) / 2, 0, W), W - gx },
	}
	for _, run in ipairs(runs) do
		BuildingVisuals.PlaceWallSegment(ring, seg, run[1], run[2])
	end
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local m = tower:Clone()
			m:PivotTo(CFrame.new(sx * W, 0, sz * W))
			m.Parent = ring
		end
	end
	local g = gate:Clone()
	g:PivotTo(CFrame.new(0, 0, W))
	g.Parent = ring
	ring.WorldPivot = CFrame.identity
	ring:ScaleTo(scale)
	ring:PivotTo(at)
	slimIcon(ring, Cfg.CastleIconWallMinPart)
	ring.Parent = model
end

-- The city castle model of this level's tier, shrunk and seated on `at`, inside its wall ring.
-- Returns its height, or nil.
local function addCastleIcon(model: Model, level: number, at: CFrame): number?
	local template = BuildingVisuals.FindModel("Castle", BuildingVisuals.GetTier(level))
	if not template then
		return nil
	end
	local icon = template:Clone()
	local scale = TILE * Cfg.CastleIconScale / (template:GetAttribute("PlotSize") or 36)
	icon:ScaleTo(scale)
	icon:PivotTo(at)
	slimIcon(icon, Cfg.CastleIconMinPart)
	icon.Name = "Icon"
	icon.Parent = model
	addWallRing(model, level, at, scale)
	return (template:GetAttribute("LabelHeight") or 20) * scale
end

-- One castle icon: the castle model of its tier on a plate in the owner color, with the owner's name.
-- Falls back to a block that gets taller with the level if the model is missing.
function MapVisuals.BuildCastle(parent: Instance, castle, isMine: boolean): Model
	local model = Instance.new("Model")
	model.Name = "Castle_" .. castle.X .. "_" .. castle.Y
	MapVisuals.ClearDecor(castle.X, castle.Y)
	local color = if isMine then Cfg.MyCastleColor else Cfg.OtherCastleColor
	local plate = Cfg.CastlePlateHeight
	local base = part("Base", Vector3.new(TILE * 0.95, plate, TILE * 0.95),
		blockCFrame(castle.X, castle.Y, castle.X, castle.Y, Cfg.GroundY + plate, plate), color, model)
	local h = addCastleIcon(model, castle.Level, base.CFrame * CFrame.new(0, plate / 2, 0))
	if h then
		h += plate
	else
		h = 3 + castle.Level * 0.4
		base.Size = Vector3.new(TILE * 0.85, h, TILE * 0.85)
		base.CFrame = blockCFrame(castle.X, castle.Y, castle.X, castle.Y, Cfg.GroundY + h, h)
		part("Keep", Vector3.new(TILE * 0.4, h * 0.6, TILE * 0.4), base.CFrame * CFrame.new(0, h * 0.8, 0), color:Lerp(Color3.new(0, 0, 0), 0.2), model)
	end
	local name = if isMine then "You" else castle.Name
	-- base is centered at plate/2 (or h/2) above the ground; the chip sits above the castle top.
	-- Yours never hides (map.html section 7).
	addLabel(base, name, { border = color, color = if isMine then CH.MyText else nil, badge = "Lv " .. castle.Level },
		if isMine then math.huge else Cfg.LabelMaxDistance, h + 1)
	model.PrimaryPart = base
	model.Parent = parent
	return model
end

-- A march path (map.html section 6): a Beam with arrows moving toward its far end, held by a hidden
-- part. style: "Go" (default), "Back" (returning with loot: thinner and paler) or "Incoming" (an
-- attack on your castle: pulses). Destroy the returned part to remove it.
function MapVisuals.BuildMarchLine(parent: Instance, fromX: number, fromY: number, toX: number, toY: number, color: Color3, style: string?): Part
	local lift = Vector3.new(0, 0.6, 0)
	local a = KingdomMapGen.TileToWorld(fromX, fromY) + lift
	local b = KingdomMapGen.TileToWorld(toX, toY) + lift
	local holder = part("MarchLine", Vector3.new(0.1, 0.1, 0.1), CFrame.new(a), color, parent)
	holder.Transparency = 1
	local a0 = Instance.new("Attachment")
	a0.Parent = holder
	local a1 = Instance.new("Attachment")
	a1.Position = b - a -- relative to the holder (which is unrotated at `a`)
	a1.Parent = holder
	local back = style == "Back"
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Texture = LINE.Texture
	beam.TextureMode = Enum.TextureMode.Static
	beam.TextureLength = if back then LINE.BackTextureLength else LINE.TextureLength
	beam.TextureSpeed = LINE.Speed
	local w = if back then LINE.BackWidth else LINE.Width
	beam.Width0, beam.Width1 = w, w
	beam.Color = ColorSequence.new(color)
	beam.LightEmission = 0.6
	beam.LightInfluence = 0
	beam.Transparency = NumberSequence.new(if back then LINE.BackTransparency else 0.05)
	beam.Parent = holder
	if style == "Incoming" then
		pulsing[beam] = true
		beam.Destroying:Connect(function()
			pulsing[beam] = nil
		end)
	end
	return holder
end

-- An army icon (map.html section 6): the AI squad model MapModels.Army (tools\MapModelBuilder) on a ring
-- in the owner color, with a chip under it ("850", or "Name · 1.2K" for someone else's). Without the
-- model: a flag on a small base. Move it with :PivotTo (its pivot is on the ground; -Z = facing, see
-- the "FaceYaw" attribute).
function MapVisuals.BuildArmyIcon(parent: Instance, count: number, color: Color3, owner: string?): Model
	local text = if owner then ("%s · %s"):format(owner, shortCount(count)) else shortCount(count)
	local template = mapModels and mapModels:FindFirstChild("Army")
	if template then
		local model = template:Clone()
		local ring = model:FindFirstChild("Ring") :: BasePart?
		if ring then
			ring.Color = color
		end
		model:PivotTo(CFrame.new(0, Cfg.GroundY, 0))
		addLabel(model.PrimaryPart :: BasePart, text, { border = color }, math.huge, -1.2)
		model.Parent = parent
		return model
	end
	local model = Instance.new("Model")
	model.Name = "Army"
	local d = TILE * 0.45
	local g = Cfg.GroundY
	local base = part("Base", Vector3.new(d * 0.25, d, d), CFrame.new(0, g + d * 0.125, 0) * CFrame.Angles(0, 0, math.pi / 2),
		color:Lerp(Color3.new(0, 0, 0), 0.35), model)
	base.Shape = Enum.PartType.Cylinder
	part("Pole", Vector3.new(0.3, d * 2, 0.3), CFrame.new(0, g + d * 1.1, 0), Color3.fromRGB(58, 42, 26), model)
	local flag = part("Flag", Vector3.new(0.15, d * 0.6, d * 0.9), CFrame.new(0, g + d * 1.75, d * 0.45), color, model)
	flag.Material = Enum.Material.Fabric
	local cap = part("Cap", Vector3.new(0.6, 0.6, 0.6), CFrame.new(0, g + d * 2.15, 0), Cfg.Selector.Color, model)
	cap.Shape = Enum.PartType.Ball
	-- the chip hangs just under the base (below the flag, as in the design)
	addLabel(base, text, { border = color }, math.huge, -1.2)
	model.WorldPivot = CFrame.new(0, g, 0) -- pivot on the ground, so PivotTo(tile world pos) works
	model.Parent = parent
	return model
end

-- The selected tile (map.html section 7): an L of gold neon in each corner, pulsing (stepMotion)
function MapVisuals.BuildSelector(parent: Instance): Model
	local S = Cfg.Selector
	local model = Instance.new("Model")
	model.Name = "Selector"
	local h, t, arm = TILE / 2, S.Thickness, TILE * S.Arm
	local y = Cfg.GroundY + 0.3
	table.clear(selectorParts)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			-- one arm along X and one along Z, meeting in the corner
			local cx, cz = sx * (h - t / 2), sz * (h - t / 2)
			table.insert(selectorParts, part("Corner", Vector3.new(arm, t, t), CFrame.new(cx - sx * (arm - t) / 2, y, cz), S.Color, model))
			table.insert(selectorParts, part("Corner", Vector3.new(t, t, arm), CFrame.new(cx, y, cz - sz * (arm - t) / 2), S.Color, model))
		end
	end
	for _, p in ipairs(selectorParts) do
		p.Material = Enum.Material.Neon
	end
	local center = part("Center", Vector3.new(0.1, 0.1, 0.1), CFrame.new(0, y, 0), S.Color, model)
	center.Transparency = 1
	model.PrimaryPart = center
	model.Parent = parent
	return model
end

function MapVisuals.MoveSelector(selector: Model, x: number, y: number)
	local pos = KingdomMapGen.TileToWorld(x, y)
	selector:PivotTo(CFrame.new(pos + Vector3.new(0, 0.3, 0)))
end

return MapVisuals
