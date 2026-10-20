-- UpgradeFXController: building effects on the client.
-- Scaffolding around a building while its build timer runs (only once the worker gets there).
-- The server rebuilds the plot model when the timer ends, so the scaffold goes away with it.
-- Then the finish scene: the camera glides in, the scaffold drops, the new building pops up in dust with a gold
-- ring and light beam, fireworks, then a "LEVEL N" badge (+ "NEW LOOK" on a new tier), with sounds.
-- Empty plots: the gold corners pulse when the player can build there; the ghost fills in while it is built.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.UpgradeFXController (ModuleScript)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local BuildingVisuals = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("BuildingVisuals"))
local CameraController = require(script.Parent.CameraController)
local ClientData = require(script.Parent.ClientData)
local Cfg = GameConfig.UpgradeFX
local Sounds = GameConfig.Sounds

local player = Players.LocalPlayer

local UpgradeFXController = {}

local POLE_COLOR = Color3.fromHex("8b5e36")
local PLANK_COLOR = Color3.fromHex("b98a55")
local BRACE_COLOR = Color3.fromHex("7d5430")
local STONE_COLOR = Color3.fromHex("8e8b84")
local ROPE_COLOR = Color3.fromHex("d9c79a")
local LOG_COLOR = Color3.fromHex("8a5a32")
local GOLD_LIGHT = Color3.fromHex("f2d488")
local GOLD = Color3.fromHex("d4a646")

local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

-- The player's civilization colors (banners, fireworks, NEW LOOK ribbon)
local function civColors()
	local snapshot = ClientData.Get()
	local banners = GameConfig.Art.Banners
	return banners[snapshot and snapshot.Civilization or ""] or banners.English
end

local city: Model
local fxFolder: Folder
local watched: { [Model]: boolean } = {}
-- Last build timer seen on each plot: when the plot comes back without it at ToLevel, the build finished
local pending: { [string]: number } = {} -- plotId -> ToLevel
-- Moving bits, run every frame: scaffold cranes, and the corners of plots the player can build on now
local cranes: { { Block: BasePart, Rope: BasePart, Tip: Vector3, Low: number, High: number } } = {}
local pulsing: { BasePart } = {}

local function makePart(parent: Instance, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false -- taps go through to the building
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Transparency = 1 -- faded in at the end of buildScaffold
	p.Parent = parent
	return p
end

-- World box of the building itself: every part except the pad and flat decorations (fields)
local function buildingBox(model: Model): (Vector3?, Vector3?)
	local pad = model.PrimaryPart
	if not pad then
		return nil, nil
	end
	local baseY = pad.Position.Y + pad.Size.Y / 2
	local ghost = model:FindFirstChild("Ghost")
	if ghost then
		local cf, size = ghost:GetBoundingBox()
		local lo, hi = cf.Position - size / 2, cf.Position + size / 2
		return Vector3.new(lo.X, baseY, lo.Z), hi
	end
	if model:GetAttribute("State") == "Constructing" or model:GetAttribute("State") == "Empty" then
		local half = pad.Size.X * Cfg.EmptyPlotFootprint / 2
		local c = pad.Position
		return Vector3.new(c.X - half, baseY, c.Z - half), Vector3.new(c.X + half, baseY + Cfg.EmptyPlotHeight, c.Z + half)
	end
	local lo, hi
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part ~= pad and part.Parent == model then
			local cf, s = part.CFrame, part.Size / 2
			local ext = Vector3.new(
				math.abs(cf.RightVector.X) * s.X + math.abs(cf.UpVector.X) * s.Y + math.abs(cf.LookVector.X) * s.Z,
				math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z,
				math.abs(cf.RightVector.Z) * s.X + math.abs(cf.UpVector.Z) * s.Y + math.abs(cf.LookVector.Z) * s.Z
			)
			if ext.Y > 1 then -- skip fields and other flat things
				local a, b = cf.Position - ext, cf.Position + ext
				lo = lo and lo:Min(a) or a
				hi = hi and hi:Max(b) or b
			end
		end
	end
	if not lo then
		return nil, nil
	end
	return Vector3.new(lo.X, baseY, lo.Z), hi
end

-- Evenly spaced points from a to b (both ends included), at most `spacing` apart
local function spread(a: number, b: number, spacing: number): { number }
	local n = math.max(1, math.ceil((b - a) / spacing))
	local out = {}
	for i = 0, n do
		table.insert(out, a + (b - a) * i / n)
	end
	return out
end

local function buildScaffold(model: Model)
	if model:FindFirstChild("Scaffold") then
		return
	end
	local lo, hi = buildingBox(model)
	if not lo then
		return
	end
	local m = Cfg.ScaffoldMargin
	local x0, x1, z0, z1 = lo.X - m, hi.X + m, lo.Z - m, hi.Z + m
	local y0 = lo.Y
	local height = math.max(hi.Y - y0, Cfg.LevelGap)

	local scaffold = Instance.new("Model")
	scaffold.Name = "Scaffold"
	local levels: { { BasePart } } = {}

	-- Poles along the four sides
	local poles = {}
	local xs, zs = spread(x0, x1, Cfg.PoleSpacing), spread(z0, z1, Cfg.PoleSpacing)
	for _, x in ipairs(xs) do
		table.insert(poles, makePart(scaffold, Vector3.new(0.5, height, 0.5), CFrame.new(x, y0 + height / 2, z0), POLE_COLOR, Enum.Material.Wood))
		table.insert(poles, makePart(scaffold, Vector3.new(0.5, height, 0.5), CFrame.new(x, y0 + height / 2, z1), POLE_COLOR, Enum.Material.Wood))
	end
	for i = 2, #zs - 1 do
		table.insert(poles, makePart(scaffold, Vector3.new(0.5, height, 0.5), CFrame.new(x0, y0 + height / 2, zs[i]), POLE_COLOR, Enum.Material.Wood))
		table.insert(poles, makePart(scaffold, Vector3.new(0.5, height, 0.5), CFrame.new(x1, y0 + height / 2, zs[i]), POLE_COLOR, Enum.Material.Wood))
	end
	table.insert(levels, poles)

	-- Plank walkways and a rail at each level
	local w, d = x1 - x0, z1 - z0
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local y = y0 + Cfg.LevelGap
	while y <= y0 + height + 0.01 do
		local level = {}
		local function side(size: Vector3, pos: Vector3)
			table.insert(level, makePart(scaffold, size, CFrame.new(pos), PLANK_COLOR, Enum.Material.WoodPlanks))
		end
		side(Vector3.new(w + 1.4, 0.3, 1.4), Vector3.new(cx, y, z0 - 0.45)) -- north
		side(Vector3.new(w + 1.4, 0.3, 1.4), Vector3.new(cx, y, z1 + 0.45)) -- south
		side(Vector3.new(1.4, 0.3, d), Vector3.new(x0 - 0.45, y, cz)) -- west
		side(Vector3.new(1.4, 0.3, d), Vector3.new(x1 + 0.45, y, cz)) -- east
		-- Rail half way up to the next level
		local ry = y - Cfg.LevelGap / 2
		table.insert(level, makePart(scaffold, Vector3.new(w, 0.25, 0.25), CFrame.new(cx, ry, z0), POLE_COLOR, Enum.Material.Wood))
		table.insert(level, makePart(scaffold, Vector3.new(w, 0.25, 0.25), CFrame.new(cx, ry, z1), POLE_COLOR, Enum.Material.Wood))
		table.insert(level, makePart(scaffold, Vector3.new(0.25, 0.25, d), CFrame.new(x0, ry, cz), POLE_COLOR, Enum.Material.Wood))
		table.insert(level, makePart(scaffold, Vector3.new(0.25, 0.25, d), CFrame.new(x1, ry, cz), POLE_COLOR, Enum.Material.Wood))
		-- One diagonal brace per bay between two poles, alternating, so each face shows X shapes
		local function brace(a: Vector3, b: Vector3)
			table.insert(level, makePart(scaffold, Vector3.new(0.2, 0.2, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), BRACE_COLOR, Enum.Material.Wood))
		end
		local yb = y - Cfg.LevelGap
		for i = 1, #xs - 1 do
			local lo, hi = if i % 2 == 0 then yb else y, if i % 2 == 0 then y else yb
			brace(Vector3.new(xs[i], lo, z0), Vector3.new(xs[i + 1], hi, z0))
			brace(Vector3.new(xs[i], hi, z1), Vector3.new(xs[i + 1], lo, z1))
		end
		for i = 1, #zs - 1 do
			local lo, hi = if i % 2 == 0 then yb else y, if i % 2 == 0 then y else yb
			brace(Vector3.new(x0, lo, zs[i]), Vector3.new(x0, hi, zs[i + 1]))
			brace(Vector3.new(x1, hi, zs[i]), Vector3.new(x1, lo, zs[i + 1]))
		end
		table.insert(levels, level)
		y += Cfg.LevelGap
	end

	-- Crane at the back right corner: its arm reaches over the back walkway, a stone block goes up and down
	local extras = {}
	local top = y0 + height + 4
	local mast = Vector3.new(x1 + 1.2, 0, z0 - 1.2)
	table.insert(extras, makePart(scaffold, Vector3.new(0.7, top - y0, 0.7), CFrame.new(mast.X, (y0 + top) / 2, mast.Z), BRACE_COLOR, Enum.Material.Wood))
	local tip = Vector3.new(cx - 2, top, z0 - 1.2)
	local mastTop = Vector3.new(mast.X, top, mast.Z)
	table.insert(extras, makePart(scaffold, Vector3.new(0.5, 0.5, (tip - mastTop).Magnitude), CFrame.lookAt((tip + mastTop) / 2, tip), POLE_COLOR, Enum.Material.Wood))
	local strut = Vector3.new(mast.X, top - 3, mast.Z)
	table.insert(extras, makePart(scaffold, Vector3.new(0.25, 0.25, (tip - strut).Magnitude), CFrame.lookAt((tip + strut) / 2, tip), POLE_COLOR, Enum.Material.Wood))
	local block = makePart(scaffold, Vector3.new(1.4, 1.4, 1.4), CFrame.new(tip.X, y0 + 1, tip.Z), STONE_COLOR, Enum.Material.Cobblestone)
	local rope = makePart(scaffold, Vector3.new(0.12, 1, 0.12), CFrame.new(tip), ROPE_COLOR, Enum.Material.Fabric)
	table.insert(extras, block)
	table.insert(extras, rope)
	local crane = { Block = block, Rope = rope, Tip = tip, Low = y0 + 0.7, High = math.max(y0 + 2, y0 + height - 1.5) }
	table.insert(cranes, crane)
	scaffold.Destroying:Once(function()
		local i = table.find(cranes, crane)
		if i then
			table.remove(cranes, i)
		end
	end)

	-- Upgrade: civilization banner hanging on the front; both: a pile of logs and stones in front
	local civ = civColors()
	if model:GetAttribute("State") == "Upgrading" and height >= 6 then
		local bw = math.min(5, w * 0.4)
		local bh = math.min(5, height - 1)
		local banner = makePart(scaffold, Vector3.new(bw, bh, 0.15), CFrame.new(cx, y0 + height - 0.4 - bh / 2, z1 + 1.3), civ.Main, Enum.Material.Fabric)
		banner.Name = "Banner"
		table.insert(extras, banner)
		table.insert(extras, makePart(scaffold, Vector3.new(bw, 0.6, 0.2), CFrame.new(cx, y0 + height - 0.7, z1 + 1.4), civ.Trim, Enum.Material.Fabric))
	end
	for i = 0, 2 do
		local log = makePart(scaffold, Vector3.new(4, 0.8, 0.8), CFrame.new(x0 + 2.5, y0 + 0.4 + (if i == 2 then 0.7 else 0), z1 + 2 + (if i == 1 then 0.9 elseif i == 2 then 0.45 else 0)), LOG_COLOR, Enum.Material.Wood)
		log.Shape = Enum.PartType.Cylinder
		table.insert(extras, log)
	end
	for i, o in ipairs({ Vector3.new(0, 0.7, 0), Vector3.new(1.8, 0.7, 0), Vector3.new(0.9, 2.05, 0.1) }) do
		table.insert(extras, makePart(scaffold, Vector3.new(1.6, 1.3 + (i % 2) * 0.1, 1.5), CFrame.new(Vector3.new(x1 - 3, y0, z1 + 2) + o), STONE_COLOR:Lerp(Color3.new(1, 1, 1), (i - 2) * 0.05), Enum.Material.Cobblestone))
	end
	table.insert(levels, extras)

	scaffold.Parent = model

	-- Goes up level by level: poles first, then each plank level from the bottom
	local step = Cfg.RevealSeconds / #levels
	local info = TweenInfo.new(math.max(step, 0.15), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for i, level in ipairs(levels) do
		task.delay((i - 1) * step, function()
			for _, part in ipairs(level) do
				if part.Parent then
					TweenService:Create(part, info, { Transparency = 0 }):Play()
				end
			end
		end)
	end
end

-- An invisible anchored part to hang particles on (in our own folder, so plot redraws don't cut them off)
local function emitterPart(size: Vector3, position: Vector3, lifetime: number): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = size
	p.Position = position
	p.Parent = fxFolder
	Debris:AddItem(p, lifetime)
	return p
end

-- A one-shot sound heard the same everywhere (the camera is focused on the scene anyway)
local function playSound(sound: { Id: number, Volume: number })
	local s = Instance.new("Sound")
	s.SoundId = "rbxassetid://" .. sound.Id
	s.Volume = sound.Volume
	s.PlaybackSpeed = 0.95 + math.random() * 0.1 -- small variation so repeats don't sound copied
	s.Parent = fxFolder
	s.Ended:Once(function()
		s:Destroy()
	end)
	Debris:AddItem(s, 10)
	s:Play()
end

local function dustBurst(lo: Vector3, hi: Vector3)
	local size = Vector3.new(math.max(hi.X - lo.X, 2), 1, math.max(hi.Z - lo.Z, 2))
	local part = emitterPart(size, Vector3.new((lo.X + hi.X) / 2, lo.Y + 0.5, (lo.Z + hi.Z) / 2), 4)
	local e = Instance.new("ParticleEmitter")
	e.Texture = DUST_TEXTURE
	e.Color = ColorSequence.new(Color3.fromRGB(205, 185, 155))
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(1.2, 2)
	e.Speed = NumberRange.new(4, 10)
	e.SpreadAngle = Vector2.new(70, 70)
	e.Drag = 2
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-40, 40)
	e.EmissionDirection = Enum.NormalId.Top
	e.Enabled = false
	e.Parent = part
	e:Emit(Cfg.DustCount)
end

-- One rocket: a glowing dot flies up, then bursts into sparks
local function firework(from: Vector3, apex: Vector3, color: Color3)
	local rocket = emitterPart(Vector3.new(0.6, 0.6, 0.6), from, 3)
	rocket.Shape = Enum.PartType.Ball
	rocket.Material = Enum.Material.Neon
	rocket.Color = color
	rocket.Transparency = 0
	local riseSeconds = 0.6
	playSound(Sounds.FireworkLaunch)
	TweenService:Create(rocket, TweenInfo.new(riseSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = apex }):Play()
	task.delay(riseSeconds, function()
		rocket.Transparency = 1
		playSound(Sounds.FireworkBurst)
		local burst = emitterPart(Vector3.new(1, 1, 1), apex, 3)
		local e = Instance.new("ParticleEmitter")
		e.Texture = SPARK_TEXTURE
		e.LightEmission = 1
		e.Color = ColorSequence.new(color)
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0.2) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		e.Lifetime = NumberRange.new(0.8, 1.3)
		e.Speed = NumberRange.new(12, 18)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 3
		e.Acceleration = Vector3.new(0, -8, 0)
		e.Enabled = false
		e.Parent = burst
		e:Emit(45)
	end)
end

-- Finish: a ring of gold dashes on the ground grows outward and fades
local function goldRing(center: Vector3)
	local n = 28
	local holder = emitterPart(Vector3.one, center, Cfg.RingSeconds + 0.2)
	local dashes = {}
	for i = 1, n do
		local d = Instance.new("Part")
		d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow = true, false, false, false, false
		d.Material = Enum.Material.Neon
		d.Color = GOLD_LIGHT
		d.Size = Vector3.new(0.6, 0.15, 0.6)
		d.Parent = holder
		dashes[i] = d
	end
	local value = Instance.new("NumberValue")
	local function place(t: number)
		local r = (Cfg.RingStart + (Cfg.RingEnd - Cfg.RingStart) * t) / 2
		local len = 2 * math.pi * r / n * 0.7
		for i, d in ipairs(dashes) do
			local a = 2 * math.pi * i / n
			d.Size = Vector3.new(0.6, 0.15, len)
			d.CFrame = CFrame.new(center + Vector3.new(math.cos(a) * r, 0.3, math.sin(a) * r)) * CFrame.Angles(0, -a, 0)
			d.Transparency = 0.1 + 0.9 * t
		end
	end
	place(0)
	value.Changed:Connect(place)
	local tween = TweenService:Create(value, TweenInfo.new(Cfg.RingSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 1 })
	tween.Completed:Once(function()
		value:Destroy()
	end)
	tween:Play()
end

-- Finish: a column of gold light from the ground, fading out
local function lightBeam(center: Vector3)
	local holder = emitterPart(Vector3.one, center, Cfg.BeamSeconds + 0.2)
	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Parent, a1.Parent = holder, holder
	a1.Position = Vector3.new(0, Cfg.BeamHeight, 0)
	local beam = Instance.new("Beam")
	beam.Attachment0, beam.Attachment1 = a0, a1
	beam.Width0, beam.Width1 = Cfg.BeamWidth, Cfg.BeamWidth
	beam.Color = ColorSequence.new(GOLD_LIGHT)
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Parent = holder
	local value = Instance.new("NumberValue")
	local function fade(t: number)
		beam.Transparency = NumberSequence.new(0.15 + 0.85 * t, 1)
	end
	fade(0)
	value.Changed:Connect(fade)
	local tween = TweenService:Create(value, TweenInfo.new(Cfg.BeamSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 1 })
	tween.Completed:Once(function()
		value:Destroy()
	end)
	tween:Play()
end

-- Finish: "LEVEL N" rises above the building and fades; "NEW LOOK" ribbon under it on a new tier (civ given)
local function levelBadge(position: Vector3, level: number, civ)
	local holder = emitterPart(Vector3.one, position, Cfg.BadgeSeconds + 0.3)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = holder
	gui.Size = UDim2.new(14, 0, 6, 0)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true
	gui.Parent = holder
	local group = Instance.new("CanvasGroup")
	group.Size = UDim2.fromScale(1, 1)
	group.BackgroundTransparency = 1
	group.Parent = gui

	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.fromScale(1, 0.55)
	badge.BackgroundColor3 = Color3.fromHex("14171c")
	badge.BackgroundTransparency = 0.15
	badge.TextColor3 = GOLD_LIGHT
	badge.TextScaled = true
	badge.FontFace = GameConfig.Art.Fonts.Logo
	badge.Text = "LEVEL " .. level
	badge.Parent = group
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.2, 0)
	c.Parent = badge
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = GOLD
	s.Thickness = 2.5
	s.Parent = badge
	local p = Instance.new("UIPadding")
	p.PaddingTop, p.PaddingBottom = UDim.new(0.1, 0), UDim.new(0.1, 0)
	p.Parent = badge

	if civ then
		local ribbon = Instance.new("TextLabel")
		ribbon.AnchorPoint = Vector2.new(0.5, 0)
		ribbon.Position = UDim2.fromScale(0.5, 0.65)
		ribbon.Size = UDim2.fromScale(0.78, 0.33)
		ribbon.BackgroundColor3 = civ.Main
		ribbon.TextColor3 = Color3.new(1, 1, 1)
		ribbon.TextScaled = true
		ribbon.FontFace = GameConfig.Art.Fonts.Subtitle
		ribbon.Text = "NEW LOOK"
		ribbon.Parent = group
		local rs = Instance.new("UIStroke")
		rs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		rs.Color = civ.Trim
		rs.Thickness = 1.5
		rs.Parent = ribbon
	end

	local info = TweenInfo.new(Cfg.BadgeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffsetWorldSpace = Vector3.new(0, Cfg.BadgeRise, 0) }):Play()
	TweenService:Create(group, TweenInfo.new(Cfg.BadgeSeconds * 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, Cfg.BadgeSeconds * 0.6), { GroupTransparency = 1 }):Play()
end

-- Finish, shot 1: a copy of the scaffold drops a little and fades (the server already removed the real one)
local function dropScaffold(scaffold: Model)
	local copy = scaffold:Clone()
	copy.Parent = fxFolder
	Debris:AddItem(copy, Cfg.ScaffoldDropSeconds + 0.2)
	local info = TweenInfo.new(Cfg.ScaffoldDropSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, part in ipairs(copy:GetDescendants()) do
		if part:IsA("BasePart") then
			TweenService:Create(part, info, { Transparency = 1, CFrame = part.CFrame - Vector3.new(0, 3, 0) }):Play()
		end
	end
end

-- The build timer ended and the server drew the new building: show it off
local function playFinish(model: Model)
	local lo, hi = buildingBox(model)
	if not lo then
		return
	end
	local center = (lo + hi) / 2
	local ground = Vector3.new(center.X, lo.Y, center.Z)
	CameraController.FocusOn(ground, Cfg.FinishZoomDistance, Cfg.FinishHoldSeconds, Cfg.FinishGlideSmoothing)

	dustBurst(lo, hi)
	playSound(Sounds.Finish)
	goldRing(ground)
	lightBeam(ground)
	local civ = civColors()
	local level = model:GetAttribute("Level") or 1
	local newLook = level == 1 or BuildingVisuals.GetTier(level) ~= BuildingVisuals.GetTier(level - 1)
	task.delay(Cfg.BadgeDelay, levelBadge, Vector3.new(center.X, hi.Y + 3, center.Z), level, if newLook then civ else nil)

	-- Pop: the new building grows from small to full size
	local fullScale = model:GetScale()
	local ok = pcall(function()
		model:ScaleTo(fullScale * Cfg.PopStartScale)
	end)
	if ok then
		local value = Instance.new("NumberValue")
		value.Value = Cfg.PopStartScale
		value.Changed:Connect(function(v)
			if model.Parent then
				model:ScaleTo(fullScale * v)
			end
		end)
		local tween = TweenService:Create(value, TweenInfo.new(Cfg.PopSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = 1 })
		tween.Completed:Once(function()
			value:Destroy()
		end)
		tween:Play()
	end

	-- Fireworks from around the roof, one after another
	local top = hi.Y
	for i = 1, Cfg.FireworkCount do
		task.delay(Cfg.PopSeconds + (i - 1) * Cfg.FireworkInterval, function()
			local from = Vector3.new(center.X + math.random(-4, 4), top, center.Z + math.random(-4, 4))
			local apex = from + Vector3.new(math.random(-6, 6), Cfg.FireworkHeight + math.random(-3, 3), math.random(-6, 6))
			local colors = { GOLD_LIGHT, civ.Main, Color3.new(1, 1, 1) }
			firework(from, apex, colors[(i - 1) % 3 + 1])
		end)
	end
end

-- A plot model with a build timer: put the scaffold up when the worker gets there
local function watch(model: Instance)
	if not model:IsA("Model") or watched[model] or model:GetAttribute("PlotId") == "Walls_1" then
		return
	end
	local plotId = model:GetAttribute("PlotId")
	local startsAt = model:GetAttribute("TimerStartsAt")
	if not startsAt then
		-- Same plot came back without its timer, at the new level: the build is done
		local toLevel = plotId and pending[plotId]
		if toLevel and (model:GetAttribute("Level") or 0) >= toLevel then
			pending[plotId] = nil
			task.defer(playFinish, model)
		end
		return
	end
	if plotId then
		pending[plotId] = model:GetAttribute("TimerToLevel")
	end
	watched[model] = true
	model.Destroying:Once(function()
		watched[model] = nil
		local scaffold = model:FindFirstChild("Scaffold")
		local endsAt = model:GetAttribute("TimerEndsAt")
		if scaffold and endsAt and endsAt <= workspace:GetServerTimeNow() + 1 then
			dropScaffold(scaffold) -- the build is done (else it's only a redraw)
		end
	end)
	task.delay(math.max(0, startsAt - workspace:GetServerTimeNow()), function()
		if model.Parent then
			buildScaffold(model)
		end
	end)
end

-- Can the player build this (level 1) now? Display only: the server checks again when asked.
local function canBuild(snapshot, buildingType: string): boolean
	if not snapshot or not snapshot.Buildings then
		return false
	end
	for _, req in ipairs(GameConfig.GetRequirements(buildingType, 1)) do
		local best = 0
		for _, b in pairs(snapshot.Buildings) do
			if b.Type == req.Type then
				best = math.max(best, b.Level)
			end
		end
		if best < req.Level then
			return false
		end
	end
	for resource, amount in pairs(GameConfig.GetUpgradeCost(buildingType, 1)) do
		if ((snapshot.Resources or {})[resource] or 0) < amount then
			return false
		end
	end
	return true
end

-- Twice a second: which empty plots glow (+ show their "+ Build" chip), and how full the ghosts are
local function refreshPlots(plots: Instance)
	local snapshot = ClientData.Get()
	local now = workspace:GetServerTimeNow()
	table.clear(pulsing)
	for _, model in ipairs(plots:GetChildren()) do
		local state = model:GetAttribute("State")
		if state == "Empty" then
			local ok = canBuild(snapshot, model:GetAttribute("BuildingType"))
			local corners = model:FindFirstChild("BuildCorners")
			if corners then
				for _, p in ipairs(corners:GetChildren()) do
					if p:IsA("BasePart") then
						if ok then
							table.insert(pulsing, p)
						else
							p.Transparency = 1
						end
					end
				end
			end
			local label = model:FindFirstChild("Label")
			local chip = label and label:FindFirstChild("BuildChip", true)
			if chip then
				chip.Visible = ok
			end
		elseif state == "Constructing" then
			local ghost = model:FindFirstChild("Ghost")
			local startsAt, endsAt = model:GetAttribute("TimerStartsAt"), model:GetAttribute("TimerEndsAt")
			if ghost and startsAt and endsAt then
				local t = math.clamp((now - startsAt) / math.max(1, endsAt - startsAt), 0, 1)
				local tr = Cfg.GhostTransparency + (Cfg.GhostBuiltTransparency - Cfg.GhostTransparency) * t
				for _, p in ipairs(ghost:GetDescendants()) do
					if p:IsA("BasePart") then
						p.Transparency = tr
					end
				end
			end
		end
	end
end

-- Every frame: corner pulse and crane blocks (a handful of parts)
local function animate()
	local t = os.clock()
	local glow = 0.65 - 0.65 * (0.5 + 0.5 * math.sin(t * 2 * math.pi / Cfg.CornerPulseSeconds))
	for _, p in ipairs(pulsing) do
		p.Transparency = glow
	end
	local k = 0.5 - 0.5 * math.cos(t * 2 * math.pi / Cfg.CraneCycle)
	for _, c in ipairs(cranes) do
		if c.Block.Transparency < 1 then
			local y = c.Low + (c.High - c.Low) * k
			c.Block.CFrame = CFrame.new(c.Tip.X, y, c.Tip.Z)
			local len = c.Tip.Y - (y + 0.7)
			c.Rope.Size = Vector3.new(0.12, math.max(0.1, len), 0.12)
			c.Rope.CFrame = CFrame.new(c.Tip.X, c.Tip.Y - len / 2, c.Tip.Z)
			c.Rope.Transparency = c.Block.Transparency
		end
	end
end

function UpgradeFXController.Start()
	city = workspace:WaitForChild("Cities"):WaitForChild("City_" .. player.UserId) :: Model
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "UpgradeFX"
	fxFolder.Parent = workspace
	local plots = city:WaitForChild("Plots")
	plots.ChildAdded:Connect(watch)
	for _, model in ipairs(plots:GetChildren()) do
		watch(model)
	end
	RunService.Heartbeat:Connect(animate)
	task.spawn(function()
		while true do
			refreshPlots(plots)
			task.wait(0.5)
		end
	end)
end

return UpgradeFXController
