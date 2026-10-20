-- ProductionController: shows a collect bubble above resource buildings that hold something, and
-- collects when the bubble is tapped.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.ProductionController (ModuleScript)
-- The server only sets ProduceResource/ProduceRate/ProduceCapacity/ProduceSince on the plot model;
-- the amount shown here is worked out locally, for display only. The server recounts on collect.
-- Bubbles have no buttons: BuildingController asks TryCollectAt(pos) before treating a tap as a
-- tap on the building, so a tap on a bubble collects and a tap on the building opens its window.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.GameConfig)

local ProductionController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local productionAction: RemoteFunction
local city: Model

local BUBBLE_SIZE = Vector2.new(9, 3) -- studs
local TAP_PADDING = 6 -- extra pixels around a bubble that still count as a tap on it
local RESOURCE_COLORS = {
	Food = Color3.fromRGB(205, 160, 40),
	Wood = Color3.fromRGB(140, 90, 50),
	Stone = Color3.fromRGB(125, 130, 140),
	Gold = Color3.fromRGB(230, 190, 30),
}

local requesting = false

local function storedAmount(model: Model, now: number): number
	local rate, since = model:GetAttribute("ProduceRate"), model:GetAttribute("ProduceSince")
	if not rate or not since then
		return 0
	end
	local amount = rate * math.max(0, now - since) / 3600
	return math.floor(math.min(amount, model:GetAttribute("ProduceCapacity") or amount))
end

-- Moving parts of producing buildings, client only, and only while the building still fills (stops when full):
-- windmill "Sails" and saw "SawBlade" spin; the gold mine "MineCart" runs into the tunnel and comes out full;
-- the quarry "Crane" lifts a block from the cliff into its cart. Each part keeps the pose the server gave it
-- (cached once per instance) and every frame is placed from that pose, so nothing drifts.
-- Training buildings (MilitaryModelBuilder) move only while they train (TrainEndsAt): dummies sway when hit,
-- arrows fly to the targets, the horse runs laps of the paddock, the catapult fires and the hoist lifts a log.
-- Civic buildings (CivicModelBuilder) always move a little (GameConfig.CivicMotion): the bell and the tavern
-- sign swing, the market scale tips, the academy rings turn, the pigeons circle and the pole flags flap.
local spinners = {} -- { {Kind, Target, Base, ...} }
local spinBase = setmetatable({}, { __mode = "k" })
local resting = {} -- crane/cart entries of buildings that stopped: put back once in the rest pose

local function smooth(a)
	a = math.clamp(a, 0, 1)
	return a * a * (3 - 2 * a)
end

local function craneBase(crane: Model)
	local base = spinBase[crane]
	if not base then
		local pivot = crane:GetPivot()
		base = { Pivot = pivot, Parts = {} }
		for _, p in ipairs(crane:GetDescendants()) do
			if p:IsA("BasePart") then
				table.insert(base.Parts, { p, pivot:ToObjectSpace(p.CFrame) })
				if p.Name == "Rope" then
					base.Rope, base.RopeRel, base.RopeSize = p, pivot:ToObjectSpace(p.CFrame), p.Size
				elseif p.Name == "LiftedBlock" then
					base.Block, base.BlockRel = p, pivot:ToObjectSpace(p.CFrame)
				end
			end
		end
		spinBase[crane] = base
	end
	return base
end

local function cartBase(cart: Model)
	local base = spinBase[cart]
	if not base then
		base = { Pivot = cart:GetPivot(), Load = {} }
		for _, p in ipairs(cart:GetChildren()) do
			if p.Name == "Load" and p:IsA("BasePart") then
				table.insert(base.Load, p)
			end
		end
		spinBase[cart] = base
	end
	return base
end

local TRAIN_KINDS = { Dummy = "Dummy", FlyArrow = "Arrow", Horse = "Horse", CatapultArm = "Catapult", Hoist = "Hoist" }
local TRAIN_CYCLE = { Dummy = "DummyCycle", Arrow = "ArrowCycle", Horse = "HorseLap", Catapult = "CatapultCycle", Hoist = "HoistCycle" }

local function trainBase(m: Model)
	local base = spinBase[m]
	if not base then
		base = { Pivot = m:GetPivot(), Parts = {}, Ropes = {} }
		for _, p in ipairs(m:GetDescendants()) do
			if p:IsA("BasePart") then
				if p.Name == "HoistRope" then
					table.insert(base.Ropes, { p, p.CFrame, p.Size })
				elseif p.Name == "Stone" then
					base.Stone = p
				elseif m.Name == "FlyArrow" then
					table.insert(base.Parts, p)
				end
			end
		end
		spinBase[m] = base
	end
	return base
end

local CIVIC_TYPES = { Hospital = true, Academy = true, Tavern = true, Embassy = true, Market = true, WatchTower = true }
local CIVIC_MOVERS = { Bell = true, TavernSign = true, ScaleBeam = true, Armillary = true, Pigeons = true }
local FLAG_NAMES = { Banner = true, AllyFlag = true, Pennant = true }

-- A flag on a pole: thin flat block, wider than tall, hanging off the pole on its -X edge
-- (wall banners are taller than wide, the embassy emblem is a disc, saddles are not thin)
local function isPoleFlag(p: BasePart): boolean
	return p:IsA("Part") and p.Shape == Enum.PartType.Block and p.Size.Z < p.Size.Y * 0.2 and p.Size.X > p.Size.Y * 1.4
end

local function addCivic(model: Model, scale: number, offset: number)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Model") and CIVIC_MOVERS[d.Name] and d.PrimaryPart then
			spinBase[d] = spinBase[d] or d:GetPivot()
			table.insert(spinners, { Kind = "Civic", Target = d, Base = spinBase[d], Scale = scale, Offset = offset })
		elseif d:IsA("BasePart") and FLAG_NAMES[d.Name] and isPoleFlag(d) then
			spinBase[d] = spinBase[d] or d.CFrame
			local base = spinBase[d]
			table.insert(spinners, { Kind = "Flag", Target = d, Base = base, Half = d.Size.X / 2, Offset = offset + (base.Position.X + base.Position.Y) * 0.13 })
		end
	end
end

local function swingAngle(swing, t: number): number
	return swing[1] * math.sin(2 * math.pi * t / swing[2])
end

local function poseCivic(s, t: number)
	local m = GameConfig.CivicMotion
	t += s.Offset
	if s.Kind == "Flag" then
		local hinge = s.Base * CFrame.new(-s.Half, 0, 0)
		s.Target.CFrame = hinge * CFrame.Angles(0, swingAngle(m.Flag, t), 0) * CFrame.new(s.Half, 0, 0)
		return
	end
	local name = s.Target.Name
	local cf
	if name == "Armillary" then
		cf = s.Base * CFrame.Angles(0, (t * m.ArmillarySpin) % (2 * math.pi), 0)
	elseif name == "Pigeons" then
		cf = s.Base * CFrame.new(0, math.sin(t * 1.7) * m.PigeonBob * s.Scale, 0) * CFrame.Angles(0, (t * m.PigeonSpin) % (2 * math.pi), 0)
	elseif name == "Bell" then
		cf = s.Base * CFrame.Angles(swingAngle(m.Bell, t), 0, 0)
	else -- TavernSign / ScaleBeam: about the arm / beam pivot
		cf = s.Base * CFrame.Angles(0, 0, swingAngle(m[name], t))
	end
	s.Target:PivotTo(cf)
end

local function refreshSpinners()
	table.clear(spinners)
	local now = workspace:GetServerTimeNow()
	for _, model in ipairs(city.Plots:GetChildren()) do
		local pad = model.PrimaryPart
		local cap = model:GetAttribute("ProduceCapacity")
		local filling = model:GetAttribute("ProduceResource") and pad and not (cap and storedAmount(model, now) >= cap)
		local scale = model:GetScale()
		local offset = (string.byte(tostring(model:GetAttribute("PlotId")), -1) or 0) * 0.37 -- so two of a kind don't move in step
		local crane = model:FindFirstChild("Crane")
		if crane and crane:IsA("Model") and crane.PrimaryPart then
			local e = { Kind = "Crane", Target = crane, Base = craneBase(crane), Scale = scale, Offset = offset }
			table.insert(filling and spinners or resting, e)
		end
		local cart = model:FindFirstChild("MineCart")
		if cart and cart:IsA("Model") and cart.PrimaryPart then
			local e = { Kind = "Cart", Target = cart, Base = cartBase(cart), Dir = pad and pad.CFrame.LookVector or Vector3.zAxis,
				Travel = (cart:GetAttribute("Travel") or 0) * scale, Offset = offset }
			table.insert(filling and spinners or resting, e)
		end
		if CIVIC_TYPES[model:GetAttribute("BuildingType")] then
			addCivic(model, scale, offset)
		end
		local training = (model:GetAttribute("TrainEndsAt") or 0) > now
		local n = 0
		for _, c in ipairs(model:GetChildren()) do
			local kind = TRAIN_KINDS[c.Name]
			if kind and c:IsA("Model") and c.PrimaryPart then
				n += 1
				local e = { Kind = kind, Target = c, Base = trainBase(c), Scale = scale, Offset = offset + n * 0.53 }
				table.insert(training and spinners or resting, e)
			end
		end
		if filling then
			local sails = model:FindFirstChild("Sails", true)
			if sails and sails:IsA("Model") and sails.PrimaryPart then
				spinBase[sails] = spinBase[sails] or sails:GetPivot()
				table.insert(spinners, { Kind = "Spin", Target = sails, Base = spinBase[sails], Axis = pad.CFrame.RightVector, Speed = GameConfig.Production.SailSpin })
			end
			local blade = model:FindFirstChild("SawBlade", true)
			if blade and blade:IsA("BasePart") then
				spinBase[blade] = spinBase[blade] or blade.CFrame
				table.insert(spinners, { Kind = "Spin", Target = blade, Base = spinBase[blade], Axis = pad.CFrame.LookVector, Speed = GameConfig.Production.SawSpin })
			end
		end
	end
end

-- Crane at cycle fraction f: turn (relative to rest), hook drop (studs, unscaled), carrying a block?
local function cranePose(c: Model, f: number?): (number, number, boolean)
	if not f then
		return 0, 0, true -- rest pose, as built
	end
	local P, D = c:GetAttribute("PickYaw") or 0, c:GetAttribute("DropYaw") or 0
	local pd, cd = c:GetAttribute("PickDrop") or 0, c:GetAttribute("CartDrop") or 0
	if f < 0.11 then
		return P, pd * smooth(f / 0.11), false -- lower onto the cliff
	elseif f < 0.16 then
		return P, pd, f >= 0.13 -- grab
	elseif f < 0.27 then
		return P, pd * (1 - smooth((f - 0.16) / 0.11)), true -- lift
	elseif f < 0.49 then
		return P + (D - P) * smooth((f - 0.27) / 0.22), 0, true -- swing to the cart
	elseif f < 0.6 then
		return D, cd * smooth((f - 0.49) / 0.11), true -- lower into the cart
	elseif f < 0.65 then
		return D, cd, f < 0.62 -- let go
	elseif f < 0.76 then
		return D, cd * (1 - smooth((f - 0.65) / 0.11)), false -- lift empty
	elseif f < 0.98 then
		return D + (P - D) * smooth((f - 0.76) / 0.22), 0, false -- swing back
	end
	return P, 0, false
end

local function poseCrane(e, f: number?)
	local base = e.Base
	local turn, drop, carry = cranePose(e.Target, f)
	local cf = base.Pivot * CFrame.Angles(0, turn, 0)
	for _, p in ipairs(base.Parts) do
		p[1].CFrame = cf * p[2]
	end
	base.AtRest = f == nil
	local d = drop * e.Scale
	if base.Rope then
		base.Rope.Size = base.RopeSize + Vector3.new(0, d, 0)
		base.Rope.CFrame = cf * base.RopeRel - Vector3.new(0, d / 2, 0)
	end
	if base.Block then
		base.Block.CFrame = cf * base.BlockRel - Vector3.new(0, d, 0)
		base.Block.Transparency = carry and 0 or 1
	end
end

-- Cart at cycle fraction f: how far in (0 = out, 1 = deep in the tunnel), and is it full?
local function poseCart(e, f: number?)
	local inside, full = 0, true
	if f then
		if f < 0.35 then
			full = f < 0.3 -- waits outside full, then unloads
		elseif f < 0.55 then
			inside, full = smooth((f - 0.35) / 0.2), false
		elseif f < 0.75 then
			inside, full = 1, f >= 0.74 -- filled up inside
		elseif f < 0.95 then
			inside = 1 - smooth((f - 0.75) / 0.2)
		end
	end
	e.Base.AtRest = f == nil
	e.Target:PivotTo(e.Base.Pivot + e.Dir * e.Travel * inside)
	for _, p in ipairs(e.Base.Load) do
		p.Transparency = full and 0 or 1
	end
end

-- Training poses at cycle fraction f (nil = rest pose, as built)
local TRAIN_POSE = {}

function TRAIN_POSE.Dummy(e, f: number?)
	local a = 0
	if f then
		local s = f * GameConfig.Training.DummyCycle
		a = 0.35 * math.exp(-3 * s) * math.sin(14 * s) -- hit, then sways back and settles
	end
	e.Target:PivotTo(e.Base.Pivot * CFrame.Angles(-a, 0, a * 0.3))
end

function TRAIN_POSE.Arrow(e, f: number?)
	local show = f ~= nil and f < 0.75 -- flies, sticks in the target, then vanishes
	for _, p in ipairs(e.Base.Parts) do
		p.Transparency = show and 0 or 1
	end
	if not show then
		if not f then
			e.Target:PivotTo(e.Base.Pivot)
		end
		return
	end
	local flight = (e.Target:GetAttribute("Flight") or Vector3.zero) * e.Scale
	local arc = flight.Magnitude * 0.12
	local g = math.min(f / 0.3, 1)
	local pos = flight * g + Vector3.new(0, arc * 4 * g * (1 - g), 0)
	local dir = flight + Vector3.new(0, arc * 4 * (1 - 2 * g), 0)
	e.Target:PivotTo(e.Base.Pivot * CFrame.lookAt(pos, pos + dir))
end

function TRAIN_POSE.Horse(e, f: number?)
	if not f then
		e.Target:PivotTo(e.Base.Pivot)
		return
	end
	local a = (e.Target:GetAttribute("RadiusX") or 0) * e.Scale
	local b = (e.Target:GetAttribute("RadiusZ") or 0) * e.Scale
	local th = 2 * math.pi * f
	local beat = f * GameConfig.Training.HorseLap * GameConfig.Training.GallopRate * math.pi
	local bob = math.abs(math.sin(beat)) * 0.5 * e.Scale
	local yaw = math.atan2(b * math.sin(th), a * math.cos(th)) -- head (+X) along the path
	e.Target:PivotTo(e.Base.Pivot * CFrame.new(a * math.sin(th), bob, b * math.cos(th)) * CFrame.Angles(0, yaw, 0.08 * math.cos(beat)))
end

function TRAIN_POSE.Catapult(e, f: number?)
	local swing = e.Target:GetAttribute("Swing") or 0
	local a, loaded = 0, true
	if f then
		if f < 0.08 then
			local g = f / 0.08
			a, loaded = swing * g * g, g < 0.85 -- fires, lets the stone go near the top
		elseif f < 0.25 then
			a, loaded = swing - 0.12 * math.sin((f - 0.08) / 0.17 * math.pi), false -- hits the stop bar
		elseif f < 0.85 then
			a, loaded = swing * (1 - smooth((f - 0.25) / 0.6)), false -- winds back
		else
			loaded = f >= 0.9 -- reload
		end
	end
	e.Target:PivotTo(e.Base.Pivot * CFrame.Angles(-a, 0, 0))
	if e.Base.Stone then
		e.Base.Stone.Transparency = loaded and 0 or 1
	end
end

function TRAIN_POSE.Hoist(e, f: number?)
	local h = 0
	if f then
		if f < 0.4 then
			h = smooth(f / 0.4)
		elseif f < 0.55 then
			h = 1
		elseif f < 0.95 then
			h = 1 - smooth((f - 0.55) / 0.4)
		end
	end
	local d = (e.Target:GetAttribute("Lift") or 0) * e.Scale * h
	e.Target.PrimaryPart.CFrame = e.Base.Pivot + Vector3.yAxis * d -- the log only; the ropes get shorter
	for _, r in ipairs(e.Base.Ropes) do
		r[1].Size = r[3] - Vector3.new(0, d, 0)
		r[1].CFrame = r[2] + Vector3.yAxis * (d / 2)
	end
end

local function spin()
	local t = os.clock()
	for _, s in ipairs(spinners) do
		if s.Target.Parent then
			if s.Kind == "Crane" then
				local cycle = GameConfig.Production.CraneCycle
				poseCrane(s, ((t + s.Offset) % cycle) / cycle)
			elseif s.Kind == "Cart" then
				local cycle = GameConfig.Production.MineCartCycle
				poseCart(s, ((t + s.Offset) % cycle) / cycle)
			elseif s.Kind == "Civic" or s.Kind == "Flag" then
				poseCivic(s, t)
			elseif TRAIN_POSE[s.Kind] then
				local cycle = GameConfig.Training[TRAIN_CYCLE[s.Kind]]
				s.Base.AtRest = false
				TRAIN_POSE[s.Kind](s, ((t + s.Offset) % cycle) / cycle)
			else
				local p = s.Base.Position
				local turned = CFrame.new(p) * CFrame.fromAxisAngle(s.Axis, (t * s.Speed) % (2 * math.pi)) * CFrame.new(-p) * s.Base
				if s.Target:IsA("Model") then
					s.Target:PivotTo(turned)
				else
					s.Target.CFrame = turned
				end
			end
		end
	end
	for _, s in ipairs(resting) do
		if s.Target.Parent and not s.Base.AtRest then
			if s.Kind == "Crane" then
				poseCrane(s, nil)
			elseif s.Kind == "Cart" then
				poseCart(s, nil)
			else
				TRAIN_POSE[s.Kind](s, nil)
				s.Base.AtRest = true
			end
		end
	end
	table.clear(resting)
end

-- What the building on this plot model holds right now (display only)
function ProductionController.GetStored(model: Model): number
	return storedAmount(model, workspace:GetServerTimeNow())
end

local function formatAmount(n: number): string
	if n >= 1e6 then
		return ("%.1fM"):format(n / 1e6)
	elseif n >= 1e4 then
		return ("%.1fK"):format(n / 1e3)
	end
	return tostring(n)
end

local function createBubble(model: Model, resource: string): BillboardGui?
	local label = model:FindFirstChild("Label") :: BillboardGui?
	if not label or not model.PrimaryPart then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "CollectBubble"
	gui.Adornee = model.PrimaryPart
	gui.Size = UDim2.new(BUBBLE_SIZE.X, 0, BUBBLE_SIZE.Y, 0)
	gui.StudsOffsetWorldSpace = label.StudsOffsetWorldSpace + Vector3.new(0, 4, 0)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true

	local frame = Instance.new("TextLabel")
	frame.Name = "Amount"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = RESOURCE_COLORS[resource] or Color3.fromRGB(120, 120, 120)
	frame.Font = Enum.Font.GothamBold
	frame.TextScaled = true
	frame.TextColor3 = Color3.new(1, 1, 1)
	frame.TextStrokeTransparency = 0.4
	frame.Text = ""
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 2
	stroke.Parent = frame
	frame.Parent = gui

	gui.Parent = model -- client-only; it goes away with the model when the server re-renders the plot
	return gui
end

local function updateBubbles()
	local now = workspace:GetServerTimeNow()
	for _, model in ipairs(city.Plots:GetChildren()) do
		local resource = model:GetAttribute("ProduceResource")
		local bubble = model:FindFirstChild("CollectBubble") :: BillboardGui?
		local amount = resource and storedAmount(model, now) or 0
		if amount >= GameConfig.Production.MinBubbleAmount then
			bubble = bubble or createBubble(model, resource)
			if bubble then
				local full = amount >= (model:GetAttribute("ProduceCapacity") or math.huge)
				bubble.Enabled = true
				bubble.Amount.Text = ("%s %s%s"):format(resource, formatAmount(amount), full and " FULL" or "")
			end
		elseif bubble then
			bubble.Enabled = false
		end
	end
end

-- Pops "+amount Resource" where the bubble was. It is anchored to its own attachment, because the
-- server re-renders (destroys) the plot model on collect.
local function showGain(where: Vector3, text: string)
	local anchor = Instance.new("Attachment")
	anchor.Name = "GainPopup"
	anchor.WorldPosition = where
	anchor.Parent = workspace.Terrain
	local gui = Instance.new("BillboardGui")
	gui.Adornee = anchor
	gui.Size = UDim2.new(14, 0, 3, 0)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(140, 255, 120)
	label.TextStrokeTransparency = 0.2
	label.Text = text
	label.Parent = gui
	gui.Parent = anchor

	local info = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffsetWorldSpace = gui.StudsOffsetWorldSpace + Vector3.new(0, 6, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(1.3, function()
		anchor:Destroy()
	end)
end

local function collect(model: Model, where: Vector3)
	if requesting then
		return
	end
	requesting = true
	local plotId = model:GetAttribute("PlotId")
	local ok, result = pcall(function()
		return productionAction:InvokeServer("Collect", plotId)
	end)
	requesting = false
	if ok and type(result) == "table" and result.Ok then
		showGain(where, ("+%s %s"):format(formatAmount(result.Amount), result.Resource))
	end
end

-- The bubble's rectangle on screen, in the same space as InputObject.Position
local function bubbleHit(bubble: BillboardGui, pos: Vector2): boolean
	local adornee = bubble.Adornee :: BasePart?
	if not adornee then
		return false
	end
	local center = adornee.Position + bubble.StudsOffsetWorldSpace
	local c, onScreen = camera:WorldToScreenPoint(center)
	if not onScreen then
		return false
	end
	local right = camera:WorldToScreenPoint(center + camera.CFrame.RightVector * (BUBBLE_SIZE.X / 2))
	local up = camera:WorldToScreenPoint(center + camera.CFrame.UpVector * (BUBBLE_SIZE.Y / 2))
	local halfW = (Vector2.new(right.X, right.Y) - Vector2.new(c.X, c.Y)).Magnitude + TAP_PADDING
	local halfH = (Vector2.new(up.X, up.Y) - Vector2.new(c.X, c.Y)).Magnitude + TAP_PADDING
	return math.abs(pos.X - c.X) <= halfW and math.abs(pos.Y - c.Y) <= halfH
end

-- Called by BuildingController for every tap. Returns true if the tap hit a bubble (and collected).
function ProductionController.TryCollectAt(pos: Vector2): boolean
	if not city then
		return false
	end
	local best, bestDepth = nil, math.huge
	for _, model in ipairs(city.Plots:GetChildren()) do
		local bubble = model:FindFirstChild("CollectBubble") :: BillboardGui?
		if bubble and bubble.Enabled and bubbleHit(bubble, pos) then
			local depth = (bubble.Adornee.Position - camera.CFrame.Position).Magnitude
			if depth < bestDepth then
				best, bestDepth = model, depth
			end
		end
	end
	if not best then
		return false
	end
	local bubble = best.CollectBubble
	bubble.Enabled = false -- hide at once; the server re-renders the plot after collecting
	task.spawn(collect, best, bubble.Adornee.Position + bubble.StudsOffsetWorldSpace)
	return true
end

function ProductionController.Start()
	productionAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ProductionAction") :: RemoteFunction
	city = workspace:WaitForChild("Cities"):WaitForChild("City_" .. player.UserId) :: Model
	city:WaitForChild("Plots")

	task.spawn(function()
		while true do
			updateBubbles()
			refreshSpinners()
			task.wait(0.5)
		end
	end)
	RunService.RenderStepped:Connect(spin)
end

return ProductionController
