-- CameraController: Rise of Kingdoms style top-down city camera.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.CameraController (ModuleScript)
-- High tilted camera with a narrow FOV. Drag (mouse or one finger) pans by "grabbing" the ground,
-- mouse wheel / pinch / held I and O keys zoom. All numbers come from GameConfig.Camera.
-- SetEnabled(false) hands the camera back to Roblox (the HUD's "Explore" walk button).
-- Two views share the same camera: "City" (the player's city) and "Map" (the kingdom map, MapController).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Cfg = GameConfig.Camera
local MapCfg = GameConfig.Map
local GROUND_Y = GameConfig.City.GroundY -- the map ground uses the same height (Map.GroundY)

local CameraController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local cityOrigin = Vector3.zero
local focus = Vector2.zero -- X/Z offset from the city center
local targetFocus = Vector2.zero
local distance = Cfg.DefaultDistance
local targetDistance = Cfg.DefaultDistance
local enabled = false
local view = "City"
local savedViews = {} -- view name -> { Focus, Distance } while that view is not shown

-- Center, pan limit and zoom range of the current view
local function viewOrigin(): Vector3
	return if view == "Map" then MapCfg.Origin else cityOrigin
end

local function viewLimits(): (number, number, number)
	if view == "Map" then
		return MapCfg.Size * MapCfg.TileStuds / 2, MapCfg.MinDistance, MapCfg.MaxDistance
	end
	return Cfg.PanLimit, Cfg.MinDistance, Cfg.MaxDistance
end

local pressInput: InputObject? = nil -- the mouse button / finger currently pressed
local pressStart = Vector2.zero
local lastPos = Vector2.zero
local isDragging = false
local activeTouches = 0
local pinchStartDistance = distance
local smoothing = Cfg.Smoothing -- lowered while FocusOn moves the camera
local focusToken = 0 -- bumps on every FocusOn and on any player drag/zoom (cancels the way back)

local LOOK_DIR = (function()
	local p, y = math.rad(Cfg.Pitch), math.rad(Cfg.Yaw)
	return Vector3.new(-math.sin(y) * math.cos(p), -math.sin(p), -math.cos(y) * math.cos(p))
end)()

local function clampFocus(f: Vector2): Vector2
	local limit = viewLimits()
	return Vector2.new(math.clamp(f.X, -limit, limit), math.clamp(f.Y, -limit, limit))
end

local function computeCFrame(f: Vector2, d: number): CFrame
	local origin = viewOrigin()
	local target = Vector3.new(origin.X + f.X, GROUND_Y, origin.Z + f.Y)
	return CFrame.lookAt(target - LOOK_DIR * d, target)
end

-- Where a screen point hits the ground plane, using the current camera
local function screenToGround(pos: Vector2): Vector3?
	local ray = camera:ScreenPointToRay(pos.X, pos.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = (GROUND_Y - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end
	return ray.Origin + ray.Direction * t
end

-- The player moved the camera: stop any FocusOn from taking it back
local function takeControl()
	focusToken += 1
	smoothing = Cfg.Smoothing
end

local function setZoom(d: number)
	takeControl()
	local _, minD, maxD = viewLimits()
	targetDistance = math.clamp(d, minD, maxD)
end

local function onRenderStep(dt: number)
	if not enabled then
		return
	end
	-- Roblox's default camera scripts reset these when the character (re)spawns; keep ours
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	if camera.FieldOfView ~= Cfg.FieldOfView then
		camera.FieldOfView = Cfg.FieldOfView
	end
	-- Held zoom keys (not while typing in a text box)
	if not UserInputService:GetFocusedTextBox() then
		local dir = (if UserInputService:IsKeyDown(Cfg.ZoomOutKey) then 1 else 0)
			- (if UserInputService:IsKeyDown(Cfg.ZoomInKey) then 1 else 0)
		if dir ~= 0 then
			setZoom(targetDistance * (1 + dir * Cfg.KeyZoomPerSecond * dt))
		end
	end
	local alpha = 1 - math.exp(-smoothing * dt)
	focus = focus:Lerp(targetFocus, alpha)
	distance += (targetDistance - distance) * alpha
	camera.CFrame = computeCFrame(focus, distance)
end

local function isPressInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch then
		activeTouches += 1
	end
	if not enabled or gameProcessed or not isPressInput(input) then
		return
	end
	if activeTouches > 1 then
		pressInput = nil -- second finger: pinch takes over
		return
	end
	pressInput = input
	pressStart = Vector2.new(input.Position.X, input.Position.Y)
	lastPos = pressStart
	isDragging = false
end

local function onInputChanged(input: InputObject, gameProcessed: boolean)
	if not enabled then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		if not gameProcessed then
			setZoom(targetDistance * (1 - Cfg.ZoomStep * input.Position.Z))
		end
		return
	end
	if not pressInput then
		return
	end
	local isMyMove = (pressInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
		or input == pressInput
	if not isMyMove then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	if not isDragging and (pos - pressStart).Magnitude >= Cfg.DragThreshold then
		isDragging = true
		takeControl()
	end
	if isDragging then
		-- Move the focus so the ground under the pointer follows the pointer
		local before, after = screenToGround(lastPos), screenToGround(pos)
		if before and after then
			local delta = before - after
			targetFocus = clampFocus(targetFocus + Vector2.new(delta.X, delta.Z))
		end
	end
	lastPos = pos
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.Touch then
		activeTouches = math.max(0, activeTouches - 1)
	end
	if pressInput and (input == pressInput or input.UserInputType == pressInput.UserInputType) then
		pressInput = nil
		isDragging = false
	end
end

local function onPinch(_positions, scale: number, _velocity, state: Enum.UserInputState, gameProcessed: boolean)
	if not enabled or gameProcessed then
		return
	end
	if state == Enum.UserInputState.Begin then
		pinchStartDistance = targetDistance
	elseif state == Enum.UserInputState.Change and scale > 0 then
		setZoom(pinchStartDistance / scale)
	end
end

-- Stops the character from walking/jumping while in city view. Done on the Humanoid (not the
-- PlayerModule, which this place does not have). Restores the StarterPlayer values when unfrozen.
local function setCharacterFrozen(frozen: boolean)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local starter = game:GetService("StarterPlayer")
	humanoid.WalkSpeed = frozen and 0 or starter.CharacterWalkSpeed
	humanoid.JumpPower = frozen and 0 or starter.CharacterJumpPower
	humanoid.JumpHeight = frozen and 0 or starter.CharacterJumpHeight
	-- If Roblox's PlayerModule is there (WorkerController may have turned its controls off), follow it too
	local scripts = player:FindFirstChild("PlayerScripts")
	local playerModule = scripts and scripts:FindFirstChild("PlayerModule")
	if playerModule then
		pcall(function()
			local controls = require(playerModule):GetControls()
			if frozen then
				controls:Disable()
			else
				controls:Enable()
			end
		end)
	end
end

-- true: top-down city camera (character frozen). false: normal Roblox camera.
function CameraController.SetEnabled(on: boolean)
	enabled = on
	takeControl()
	if on then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = Cfg.FieldOfView
		camera.CFrame = computeCFrame(focus, distance)
	else
		pressInput = nil
		isDragging = false
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = 70
	end
	setCharacterFrozen(on)
end

function CameraController.IsEnabled(): boolean
	return enabled
end

-- Short cinematic move: glide to a world point at `dist`, hold `holdSeconds`, then glide back to
-- where the player was. Any drag or zoom by the player cancels the way back.
function CameraController.FocusOn(worldPos: Vector3, dist: number, holdSeconds: number, glideSmoothing: number)
	if not enabled or view ~= "City" then
		return
	end
	focusToken += 1
	local token = focusToken
	local backFocus, backDistance = targetFocus, targetDistance
	smoothing = glideSmoothing
	targetFocus = clampFocus(Vector2.new(worldPos.X - cityOrigin.X, worldPos.Z - cityOrigin.Z))
	targetDistance = math.clamp(dist, Cfg.MinDistance, Cfg.MaxDistance)
	task.delay(holdSeconds, function()
		if focusToken ~= token or not enabled then
			return
		end
		targetFocus, targetDistance = backFocus, backDistance
		task.delay(2, function()
			if focusToken == token then
				smoothing = Cfg.Smoothing
			end
		end)
	end)
end

-- Switch between "City" and "Map". Each view keeps its own pan and zoom. The camera jumps (no glide).
-- On the first visit to the map, `mapFocusWorld` (e.g. the player's castle) is where it looks.
function CameraController.SetView(name: string, mapFocusWorld: Vector3?)
	if name == view then
		return
	end
	savedViews[view] = { Focus = targetFocus, Distance = targetDistance }
	view = name
	takeControl()
	local saved = savedViews[name]
	if saved then
		targetFocus, targetDistance = saved.Focus, saved.Distance
	elseif name == "Map" then
		local f = if mapFocusWorld then mapFocusWorld - MapCfg.Origin else Vector3.zero
		targetFocus, targetDistance = clampFocus(Vector2.new(f.X, f.Z)), MapCfg.DefaultDistance
	else
		targetFocus, targetDistance = Vector2.zero, Cfg.DefaultDistance
	end
	focus, distance = targetFocus, targetDistance
	if enabled then
		camera.CFrame = computeCFrame(focus, distance)
	end
end

function CameraController.GetView(): string
	return view
end

-- Glide the current view to look at a world point (keeps the zoom)
function CameraController.PanTo(worldPos: Vector3)
	takeControl()
	local origin = viewOrigin()
	targetFocus = clampFocus(Vector2.new(worldPos.X - origin.X, worldPos.Z - origin.Z))
end

-- True if the current press has moved far enough to be a drag (taps on buildings ignore drags)
function CameraController.IsDragging(): boolean
	return isDragging
end

function CameraController.Start()
	-- Wait for the server to give us a city
	local origin = player:GetAttribute("CityOrigin")
	while not origin do
		player:GetAttributeChangedSignal("CityOrigin"):Wait()
		origin = player:GetAttribute("CityOrigin")
	end
	cityOrigin = origin
	focus, targetFocus = Vector2.zero, Vector2.zero
	distance, targetDistance = Cfg.DefaultDistance, Cfg.DefaultDistance

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.TouchPinch:Connect(onPinch)
	RunService:BindToRenderStep("RoC_CityCamera", Enum.RenderPriority.Camera.Value + 1, onRenderStep)

	-- A new character starts with normal speed; freeze it again while in city view
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid", 10)
		if enabled then
			CameraController.SetEnabled(true)
		end
	end)

	CameraController.SetEnabled(true)
end

return CameraController
