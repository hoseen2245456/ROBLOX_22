-- WorkerController: the builders. Builder 1 is the player's own character; builder 2 (second builder)
-- is an NPC helper in a hard hat. While a building has a build or upgrade timer, its builder walks
-- to it by itself and hammers it until the timer ends, then walks to the next job or back to its idle
-- spot beside the castle. The player never steers them.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.WorkerController (ModuleScript)
-- Display only: it reads TimerEndsAt/TimerWorker on the plot models and changes no data. The client
-- owns its character, so its walking replicates by itself; the hammer, the arm swing and the helper
-- (a local clone of ReplicatedStorage.WorkerHelperTemplate) are local only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local CameraController = require(script.Parent.CameraController)
local ClientData = require(script.Parent.ClientData)

local WorkerController = {}

local Cfg = GameConfig.Worker
local Sounds = GameConfig.Sounds
local CityCfg = GameConfig.City
local player = Players.LocalPlayer
local city: Model
local origin: Vector3

local IDLE = "" -- job id meaning "no work, stand at the idle spot"
local SWING_UP = math.rad(150) -- shoulder angle with the hammer raised
local SWING_DOWN = math.rad(55) -- shoulder angle when it hits
local MOVE_TIMEOUT = 4 -- seconds to wait for one waypoint before moving on

-- One builder. Index matches the server's timer.Worker.
type Worker = {
	Index: number,
	IsHelper: boolean,
	IdleOffset: Vector3,
	humanoid: Humanoid?,
	root: BasePart?,
	shoulder: Instance?, -- AnimationConstraint (new avatar joints) or Motor6D; both have Transform
	hammer: Model?,
	swingConn: RBXScriptConnection?,
	currentJob: string?, -- plotId, IDLE, or nil (= decide again)
	jobToken: number, -- bumped on every new job; old walks and swings stop when it changes
	model: Model?, -- the helper's body (nil for the player)
	walkTrack: AnimationTrack?,
	idleTrack: AnimationTrack?,
}

local function newWorker(index: number, isHelper: boolean, idleOffset: Vector3): Worker
	return { Index = index, IsHelper = isHelper, IdleOffset = idleOffset, jobToken = 0 }
end

local playerWorker = newWorker(1, false, Cfg.IdleOffset)
local helper: Worker? = nil

------------------------------------------------------------------------
-- Character
------------------------------------------------------------------------
local function bindCharacter(w: Worker, character: Model)
	w.humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	w.root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	local arm = character:WaitForChild("RightUpperArm", 10)
	w.shoulder = arm and arm:WaitForChild("RightShoulder", 10)
	w.hammer = nil
	w.currentJob = nil
end

local function isReady(w: Worker): boolean
	return w.humanoid ~= nil and w.humanoid.Health > 0 and w.root ~= nil and w.root.Parent ~= nil
end

-- Waits for the current MoveTo to finish, time out, or be replaced by a newer job
local function waitMoveFinished(w: Worker, token: number)
	local done = false
	local conn = w.humanoid.MoveToFinished:Once(function()
		done = true
	end)
	local waited = 0
	while not done and waited < MOVE_TIMEOUT and token == w.jobToken do
		waited += task.wait()
	end
	conn:Disconnect()
end

-- The helper has no Animate script, so it plays walk/idle itself
local function setWalking(w: Worker, walking: boolean)
	if not w.walkTrack then
		return
	end
	if walking and not w.walkTrack.IsPlaying then
		w.idleTrack:Stop(0.2)
		w.walkTrack:Play(0.2)
	elseif not walking and w.walkTrack.IsPlaying then
		w.walkTrack:Stop(0.2)
		w.idleTrack:Play(0.2)
	end
end

-- Walks to goal (Pathfinding, or straight if no path). Returns false if a newer job took over.
local function walkTo(w: Worker, goal: Vector3, token: number): boolean
	local waypoints = nil
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = false, WaypointSpacing = 6 })
	local ok = pcall(function()
		path:ComputeAsync(w.root.Position, goal)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		waypoints = path:GetWaypoints()
		table.remove(waypoints, 1) -- the first waypoint is where we stand
	end
	if not waypoints or #waypoints == 0 then
		waypoints = { { Position = goal } }
	end

	setWalking(w, true)
	for _, waypoint in ipairs(waypoints) do
		if token ~= w.jobToken or not isReady(w) then
			return false
		end
		w.humanoid.WalkSpeed = Cfg.WalkSpeed -- set every step: CameraController zeroes it on respawn
		w.humanoid:MoveTo(waypoint.Position)
		waitMoveFinished(w, token)
	end
	if token ~= w.jobToken or not isReady(w) then
		return false
	end
	setWalking(w, false)
	if not w.IsHelper and CameraController.IsEnabled() then
		w.humanoid.WalkSpeed = 0 -- city view keeps the character frozen (see CameraController)
	end
	return true
end

local function faceTowards(w: Worker, point: Vector3)
	local pos = w.root.Position
	w.root.CFrame = CFrame.lookAt(pos, Vector3.new(point.X, pos.Y, point.Z))
end

------------------------------------------------------------------------
-- Hammer
------------------------------------------------------------------------
local function hammerPart(parent: Model, name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Parent = parent
	return p
end

local function weld(part0: BasePart, part1: BasePart, c0: CFrame)
	local wd = Instance.new("Weld")
	wd.Part0 = part0
	wd.Part1 = part1
	wd.C0 = c0
	wd.Parent = part1
end

local function stopHammering(w: Worker)
	if w.swingConn then
		w.swingConn:Disconnect()
		w.swingConn = nil
	end
	if w.hammer then
		w.hammer:Destroy()
		w.hammer = nil
	end
end

-- Shoulder angle at time t: quick ease-out lift, then an ease-in hit
local function swingAngle(t: number): number
	local phase = (t % Cfg.SwingSeconds) / Cfg.SwingSeconds
	if phase < 0.6 then
		local u = phase / 0.6
		return SWING_DOWN + (SWING_UP - SWING_DOWN) * (1 - (1 - u) ^ 2)
	end
	local u = (phase - 0.6) / 0.4
	return SWING_UP + (SWING_DOWN - SWING_UP) * u * u
end

-- Puts a hammer in the right hand and swings the arm until the job changes. There is no uploaded
-- animation, so the shoulder's Transform is set every frame after the Animator has run (C0 of the
-- new AnimationConstraint joints is read-only, and the idle animation would overwrite a tween).
local function startHammering(w: Worker, token: number)
	local hand = w.humanoid.Parent and w.humanoid.Parent:FindFirstChild("RightHand") :: BasePart?
	if not hand or not w.shoulder then
		return
	end
	stopHammering(w)
	local model = Instance.new("Model")
	model.Name = "WorkerHammer"
	local handle = hammerPart(model, "Handle", Vector3.new(0.25, 0.25, 2.2), Color3.fromRGB(120, 80, 45), Enum.Material.Wood)
	local head = hammerPart(model, "Head", Vector3.new(0.55, 1.1, 0.55), Color3.fromRGB(110, 110, 120), Enum.Material.Metal)
	weld(hand, handle, CFrame.new(0, -0.2, -0.8)) -- gripped in the fist, pointing forward
	weld(handle, head, CFrame.new(0, 0, -1.1))
	local hit = Instance.new("Sound")
	hit.Name = "HitSound"
	hit.SoundId = "rbxassetid://" .. Sounds.HammerHit.Id
	hit.Volume = Sounds.HammerHit.Volume
	hit.RollOffMode = Enum.RollOffMode.Linear
	hit.RollOffMaxDistance = Sounds.HammerMaxDistance
	hit.Parent = head
	model.Parent = w.humanoid.Parent
	w.hammer = model

	local joint = w.shoulder :: any
	local started = os.clock()
	local swings = 0
	w.swingConn = RunService.PreSimulation:Connect(function()
		if token ~= w.jobToken or not joint.Parent then
			return
		end
		local elapsed = os.clock() - started
		joint.Transform = CFrame.Angles(swingAngle(elapsed), 0, 0)
		-- The hammer lands at the end of each swing
		local done = math.floor(elapsed / Cfg.SwingSeconds)
		if done > swings then
			swings = done
			hit:Play()
		end
	end)
end

------------------------------------------------------------------------
-- Jobs
------------------------------------------------------------------------
local function jobModels(): { Model }
	local models = city.Plots:GetChildren()
	local walls = city:FindFirstChild("Walls")
	if walls then
		table.insert(models, walls)
	end
	return models
end

-- The running timer of this builder that ends first (the server gives each builder one at a time)
local function findJob(w: Worker): Model?
	local now = workspace:GetServerTimeNow()
	local best, bestEnds = nil, math.huge
	for _, model in ipairs(jobModels()) do
		local endsAt = model:GetAttribute("TimerEndsAt")
		local worker = model:GetAttribute("TimerWorker") or 1
		if worker == w.Index and endsAt and endsAt > now and endsAt < bestEnds then
			best, bestEnds = model, endsAt
		end
	end
	return best
end

-- Where to stand for a job (same spot the server used for the walk time), and the point to face
local function workSpot(model: Model): (Vector3, Vector3)
	local center = model:GetPivot().Position
	local ground = Vector3.new(center.X, origin.Y + CityCfg.GroundY, center.Z)
	local offset = GameConfig.GetWorkSpot(model:GetAttribute("PlotId") or model.Name)
	if not offset then
		return ground, ground
	end
	return origin + Vector3.new(offset.X, CityCfg.GroundY, offset.Z), ground
end

-- The build timer starts when the worker is due to arrive; wait for it before hammering
local function waitForStart(w: Worker, model: Model, token: number)
	local startsAt = model:GetAttribute("TimerStartsAt")
	while startsAt and token == w.jobToken and workspace:GetServerTimeNow() < startsAt do
		task.wait(0.1)
	end
end

local function idleSpot(w: Worker): Vector3
	return origin + Vector3.new(w.IdleOffset.X, CityCfg.GroundY, w.IdleOffset.Z)
end

local function setJob(w: Worker, jobId: string, model: Model?)
	if jobId == w.currentJob then
		return
	end
	w.currentJob = jobId
	w.jobToken += 1
	local token = w.jobToken
	stopHammering(w)
	task.spawn(function()
		if model then
			local spot, lookAt = workSpot(model)
			if walkTo(w, spot, token) then
				faceTowards(w, lookAt)
				waitForStart(w, model, token)
				if token == w.jobToken then
					startHammering(w, token)
				end
			end
		else
			if walkTo(w, idleSpot(w), token) then
				faceTowards(w, w.root.Position + Vector3.new(0, 0, 1)) -- face the camera
			end
		end
	end)
end

------------------------------------------------------------------------
-- Helper (builder 2)
------------------------------------------------------------------------
local function spawnHelper()
	local template = ReplicatedStorage:FindFirstChild("WorkerHelperTemplate") :: Model?
	if not template then
		return -- the server makes it at start; try again next check
	end
	local w = newWorker(2, true, Cfg.HelperIdleOffset)
	local model = template:Clone()
	model.Name = "WorkerHelper"
	model:PivotTo(CFrame.new(idleSpot(w) + Vector3.new(0, 3, 0)))
	model.Parent = city
	w.model = model
	bindCharacter(w, model)
	local animator = w.humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", w.humanoid)
	local function track(id: number): AnimationTrack
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://" .. id
		return animator:LoadAnimation(anim)
	end
	w.walkTrack = track(Cfg.WalkAnimId)
	w.idleTrack = track(Cfg.IdleAnimId)
	w.walkTrack.Looped, w.idleTrack.Looped = true, true
	w.idleTrack:Play()
	helper = w
end

local function removeHelper()
	if not helper then
		return
	end
	helper.jobToken += 1
	stopHammering(helper)
	if helper.model then
		helper.model:Destroy()
	end
	helper = nil
end

------------------------------------------------------------------------
-- Update
------------------------------------------------------------------------
local function updatePlayer()
	local w = playerWorker
	if not isReady(w) then
		return -- dead or respawning
	end
	if not CameraController.IsEnabled() then
		-- Exploring in 3D: drop the job once and hand the character to the player
		if w.currentJob ~= nil then
			w.currentJob = nil
			w.jobToken += 1
			stopHammering(w)
			w.humanoid:MoveTo(w.root.Position)
		end
		return
	end
	local model = findJob(w)
	setJob(w, model and model.Name or IDLE, model)
end

-- The helper keeps working while the player explores. It goes away when the player loses the
-- second builder and it has no job left.
local function updateHelper()
	local snapshot = ClientData.Get()
	local wanted = snapshot ~= nil and (snapshot.Builders or 1) >= 2
	if helper and helper.model and not helper.model.Parent then
		removeHelper()
	end
	if not helper then
		if wanted then
			spawnHelper()
		end
		return
	end
	local model = findJob(helper)
	if not model and not wanted then
		removeHelper()
		return
	end
	if isReady(helper) then
		setJob(helper, model and model.Name or IDLE, model)
	end
end

function WorkerController.Start()
	city = workspace:WaitForChild("Cities"):WaitForChild("City_" .. player.UserId) :: Model
	city:WaitForChild("Plots")
	origin = player:GetAttribute("CityOrigin")

	-- The player never steers the worker. This place has no PlayerModule today; if one is added,
	-- its controls are turned off here.
	local playerModule = player:WaitForChild("PlayerScripts"):FindFirstChild("PlayerModule")
	if playerModule then
		pcall(function()
			require(playerModule):GetControls():Disable()
		end)
	end

	player.CharacterAdded:Connect(function(character)
		stopHammering(playerWorker)
		playerWorker.jobToken += 1
		bindCharacter(playerWorker, character)
	end)
	if player.Character then
		bindCharacter(playerWorker, player.Character)
	end

	task.spawn(function()
		while true do
			for _, fn in ipairs({ updatePlayer, updateHelper }) do
				local ok, err = pcall(fn)
				if not ok then
					warn("[WorkerController] " .. tostring(err))
				end
			end
			task.wait(Cfg.CheckInterval)
		end
	end)
end

return WorkerController
