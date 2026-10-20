-- MapController: the kingdom map on the client. "Map" button, tile taps, info panel, castle icons.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.MapController (ModuleScript)
-- The map world (workspace.KingdomMap) is local and built the first time the map opens.
-- Castles come from the server ("MapAction" "GetCastles"); everything else is from KingdomMapGen.
-- Castle moves work ("Move Here" on empty land, "Random Move" on your castle; both confirm first).
-- "Send Army" on any other tile opens MarchController's panel (battles/gathering come in later tasks).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local KingdomMapGen = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("KingdomMapGen"))
local MapVisuals = require(ReplicatedStorage.Modules:WaitForChild("MapVisuals"))
local CameraController = require(script.Parent.CameraController)
local ClientData = require(script.Parent.ClientData)
local MarchController = require(script.Parent.MarchController)
local MapSearchController = require(script.Parent.MapSearchController)
local ShareController = require(script.Parent.ShareController)
local UIStyle = require(ReplicatedStorage.Modules:WaitForChild("UIStyle"))

local Cfg = GameConfig.Map

local MapController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local hud: ScreenGui
local mapButton: TextButton
local homeButton: TextButton
local info -- { Frame, Title, Body, Action, Action2, Pic, PicStroke, Icon }
local coordChip: TextLabel
local world: Folder? = nil
local castleFolder: Folder? = nil
local selector: Model? = nil
local building = false
local isOpen = false
local castleAt = {} -- KingdomMapGen.Key -> castle { X, Y, UserId, Name, Level }
local myTile = nil -- { X, Y }
local selected = nil -- { X, Y }
local actionHandler: (() -> ())? = nil
local action2Handler: (() -> ())? = nil
local moveReadyAt = 0 -- server time when the castle can move again
local moveBusy = false

local Art = GameConfig.Art
local INFO_HEIGHT = 92
local PIC_SIZE = 70
local ACTION_WIDTH = 112
local SHARE_WIDTH = 86
local GAP = 8

-- Round button in the right column (UIStyle.SideColumn): Map 2, Home 3
local function makeButton(name: string, text: string, iconKey: string, order: number, hud: Instance, gold: boolean?): TextButton
	local button = UIStyle.Medallion(UIStyle.SideColumn(hud), name, iconKey, text, gold)
	button.LayoutOrder = order
	return button
end

local function infoText(parent: Instance, name: string, fontKey: string, size: number, color: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.TextTruncate = Enum.TextTruncate.AtEnd
	UIStyle.Text(label, fontKey, size, color)
	label.Parent = parent
	return label
end

-- Coordinates chip under the resource bar (ui.html section 3): the tile in the middle of the screen
local function buildCoordChip(): TextLabel
	local chip = Instance.new("TextLabel")
	chip.Name = "MapCoord"
	chip.AnchorPoint = Vector2.new(0.5, 0)
	chip.Position = UDim2.new(0.5, 0, 0, 50)
	chip.Size = UDim2.new(0, 0, 0, 24)
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.BackgroundColor3 = Color3.fromHex("#0d0f12")
	chip.BackgroundTransparency = 0.2
	chip.Visible = false
	UIStyle.Text(chip, "Number", 14, Art.Colors.GoldLight)
	UIStyle.Corner(chip, UDim.new(1, 0))
	UIStyle.Stroke(chip, Art.Colors.GoldDark, 1)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 14), UDim.new(0, 14)
	pad.Parent = chip
	chip.Parent = hud
	return chip
end

local function buildInfoPanel()
	local frame = Instance.new("Frame")
	frame.Name = "MapInfo"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -12)
	frame.Size = UDim2.new(0.92, 0, 0, INFO_HEIGHT)
	frame.Active = true
	frame.Visible = false
	frame.Parent = hud
	UIStyle.Panel(frame, Art.Colors.Border)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(640, INFO_HEIGHT)
	limit.Parent = frame

	-- Picture: icon in a box framed in the tile's color (yours / enemy / monster / resource)
	local pic = Instance.new("Frame")
	pic.Name = "Pic"
	pic.AnchorPoint = Vector2.new(0, 0.5)
	pic.Position = UDim2.new(0, 11, 0.5, 0)
	pic.Size = UDim2.new(0, PIC_SIZE, 0, PIC_SIZE)
	pic.Parent = frame
	UIStyle.Corner(pic, UDim.new(0, 8))
	local picStroke = UIStyle.Stroke(pic, Art.Colors.Gold, 2)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(0.66, 0, 0.66, 0)
	icon.Parent = pic

	local textLeft = 11 + PIC_SIZE + 12
	local title = infoText(frame, "Title", "Subtitle", 17)
	title.Position = UDim2.new(0, textLeft, 0, 14)
	title.TextWrapped = false
	local body = infoText(frame, "Body", "Body", 14, Art.Colors.Muted)
	body.Position = UDim2.new(0, textLeft, 0, 38)

	-- Buttons on the right, in a row: Share, Action2 (only sometimes), Action
	local acts = Instance.new("Frame")
	acts.Name = "Acts"
	acts.AnchorPoint = Vector2.new(1, 0.5)
	acts.Position = UDim2.new(1, -12, 0.5, 0)
	acts.Size = UDim2.new(0, 0, 0, 42)
	acts.AutomaticSize = Enum.AutomaticSize.X
	acts.BackgroundTransparency = 1
	acts.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, GAP)
	layout.Parent = acts

	local function actionButton(name: string, order: number, width: number, onPress: () -> ()): TextButton
		local action = Instance.new("TextButton")
		action.Name = name
		action.LayoutOrder = order
		action.Size = UDim2.new(0, width, 0, 42)
		action.TextSize = 14
		action.TextWrapped = true
		action.Parent = acts
		UIStyle.Button(action, "Neutral")
		action.Activated:Connect(onPress)
		return action
	end
	local action = actionButton("Action", 3, ACTION_WIDTH, function()
		if actionHandler then
			actionHandler()
		end
	end)
	local action2 = actionButton("Action2", 2, ACTION_WIDTH, function()
		if action2Handler then
			action2Handler()
		end
	end)
	action2.Visible = false

	-- Share: sends the selected tile to the kingdom (icon + text)
	local shareButton = actionButton("Share", 1, SHARE_WIDTH, function()
		if selected then
			ShareController.OpenShare(selected.X, selected.Y, title.Text)
		end
	end)
	shareButton.Text = "      Share"
	local shareIcon = Instance.new("ImageLabel")
	shareIcon.Name = "Icon"
	shareIcon.BackgroundTransparency = 1
	shareIcon.AnchorPoint = Vector2.new(0, 0.5)
	shareIcon.Position = UDim2.new(0, 8, 0.5, 0)
	shareIcon.Size = UDim2.new(0, 22, 0, 22)
	shareIcon.Image = UIStyle.Icon("Share")
	shareIcon.ZIndex = 2
	shareIcon.Parent = shareButton

	info = { Frame = frame, Title = title, Body = body, Action = action, Action2 = action2, Pic = pic, PicStroke = picStroke, Icon = icon }
end

-- Title and body take the width the buttons leave
local function fitText()
	local buttons = SHARE_WIDTH + ACTION_WIDTH + GAP + (if info.Action2.Visible then ACTION_WIDTH + GAP else 0)
	local width = UDim2.new(1, -(11 + PIC_SIZE + 12 + buttons + 24), 0, 0)
	info.Title.Size = width + UDim2.fromOffset(0, 22)
	info.Body.Size = width + UDim2.fromOffset(0, 42)
end

-- The picture: icon key and frame color for the selected tile
local function setPicture(iconKey: string, color: Color3)
	info.Icon.Image = UIStyle.Icon(iconKey)
	info.PicStroke.Color = color
	UIStyle.Gradient(info.Pic, color:Lerp(Color3.new(0, 0, 0), 0.6), Art.Colors.Background)
end

-- style: a GameConfig.Art.Buttons name ("Danger" attack, "Confirm" send/enter, "Primary" move). No handler = greyed.
local function paint(button: TextButton, text: string, handler: (() -> ())?, style: string?)
	button.Text = text
	UIStyle.Button(button, if handler then (style or "Confirm") else "Disabled")
end

local function setAction(text: string, handler: (() -> ())?, style: string?)
	paint(info.Action, text, handler, style)
	actionHandler = handler
end

-- Second button (left of the first). text = nil hides it.
local function setAction2(text: string?, handler: (() -> ())?, style: string?)
	info.Action2.Visible = text ~= nil
	paint(info.Action2, text or "", handler, style)
	action2Handler = handler
	fitText()
end

------------------------------------------------------------------------
-- Castles
------------------------------------------------------------------------
local function drawCastles(list)
	if not castleFolder then
		return
	end
	castleFolder:ClearAllChildren()
	table.clear(castleAt)
	for _, c in ipairs(list) do
		castleAt[KingdomMapGen.Key(c.X, c.Y)] = c
		MapVisuals.BuildCastle(castleFolder, c, c.UserId == player.UserId)
	end
end

local fetching = false
local function fetchCastles()
	if fetching then
		repeat
			task.wait()
		until not fetching -- someone else is fetching; just wait for their result
		return
	end
	fetching = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MapAction")
	local ok, result = pcall(function()
		return remote:InvokeServer("GetCastles")
	end)
	fetching = false
	if ok and result and result.Ok then
		myTile = result.MyTile or myTile
		moveReadyAt = result.MoveReadyAt or moveReadyAt
		drawCastles(result.Castles)
	end
end

------------------------------------------------------------------------
-- Selecting a tile
------------------------------------------------------------------------
local function zoneName(x: number, y: number): string
	return Cfg.Zones[KingdomMapGen.GetZone(x, y)].Name
end

------------------------------------------------------------------------
-- Moving the castle (server checks cost, cooldown and the tile)
------------------------------------------------------------------------
local selectTile

local function costText(cost): string
	local parts = {}
	for resource, amount in pairs(cost) do
		table.insert(parts, amount .. " " .. resource)
	end
	return table.concat(parts, ", ")
end

local function requestMove(action: string, x: number?, y: number?)
	if moveBusy then
		return
	end
	moveBusy = true
	setAction(if action == "MoveTo" then "Moving..." else info.Action.Text, nil)
	if action == "MoveRandom" then
		setAction2("Moving...", nil)
	end
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MapAction")
	local ok, result = pcall(function()
		return remote:InvokeServer(action, x, y)
	end)
	if ok and result and result.Ok then
		myTile = result.MyTile
		moveReadyAt = result.MoveReadyAt or moveReadyAt
		task.wait(GameConfig.Remotes.MinRequestInterval)
		fetchCastles()
		moveBusy = false
		CameraController.PanTo(KingdomMapGen.TileToWorld(myTile.X, myTile.Y))
		selectTile(myTile.X, myTile.Y)
		info.Body.Text = "Castle moved! " .. info.Body.Text
	else
		moveBusy = false
		if selected then
			selectTile(selected.X, selected.Y)
		end
		info.Body.Text = "Can't move: " .. tostring(ok and result and result.Error or "no answer")
	end
end

-- A move button: first press shows the cost to confirm, second press moves. Greyed during cooldown.
local function moveButton(setter, label: string, cost, onConfirm: () -> ())
	local left = math.ceil(moveReadyAt - workspace:GetServerTimeNow())
	if left > 0 then
		setter(("%s\n%d:%02d"):format(label, left // 60, left % 60), nil)
		return
	end
	setter(label, function()
		setter("Confirm\n" .. costText(cost), onConfirm, "Primary")
	end, "Primary")
end

function selectTile(x: number, y: number)
	selected = { X = x, Y = y }
	if selector then
		MapVisuals.MoveSelector(selector, x, y)
	end
	setAction2(nil, nil)
	local where = ("X %d · Y %d · %s · %s zone"):format(x, y, KingdomMapGen.GetBiome(x, y) or "?", zoneName(x, y))
	local castle = castleAt[KingdomMapGen.Key(x, y)]
	local feature = KingdomMapGen.GetFeatureAt(x, y)
	local function sendArmy()
		MarchController.OpenSend(x, y, info.Title.Text, castle ~= nil or (feature ~= nil and feature.Kind == "Monster"))
	end
	if castle and castle.UserId == player.UserId then
		setPicture("Castle", Art.Status.MyCastle)
		info.Title.Text = ("Your Castle · Lv %d"):format(castle.Level)
		info.Body.Text = where .. ("\nArmies out: %d / %d"):format(MarchController.GetMyMarchCount(), GameConfig.March.MaxMarches)
		setAction("Enter City", function()
			MapController.SetOpen(false)
		end)
		moveButton(setAction2, "Random Move", Cfg.Move.RandomCost, function()
			requestMove("MoveRandom")
		end)
	elseif castle then
		setPicture("Castle", Art.Status.Enemy)
		info.Title.Text = ("%s's Castle · Lv %d"):format(castle.Name, castle.Level)
		info.Body.Text = where .. ("\nBeat the troops at home to take %d%% of their stored resources.")
			:format(GameConfig.Battle.Castle.StealShare * 100)
		setAction("Attack", sendArmy, "Danger")
	elseif feature and feature.Kind == "Resource" then
		setPicture(feature.Resource, Art.Resources[feature.Resource] or Art.Colors.Gold)
		info.Title.Text = ("%s Node · Lv %d"):format(feature.Resource, feature.Level)
		info.Body.Text = where .. "\nGathering comes later: for now the army walks there and back."
		setAction("Send Army", sendArmy)
	elseif feature then
		setPicture("Monster", Art.Status.Monster)
		info.Title.Text = ("Monster · Lv %d"):format(feature.Level)
		info.Body.Text = where .. "\nDefeat it to bring loot home."
		setAction("Attack", sendArmy, "Danger")
	elseif not KingdomMapGen.IsPassable(x, y) then
		setPicture("Map", Art.Colors.Muted)
		info.Title.Text = "Mountains"
		info.Body.Text = where .. "\nToo steep: armies and castles can't go here."
		setAction("Impassable", nil)
	else
		setPicture("Map", Art.Colors.Muted)
		local biome = KingdomMapGen.GetBiome(x, y)
		info.Title.Text = if biome == "River" then biome elseif KingdomMapGen.GetGround(x, y) == "Water" then "Riverbank" else "Empty Land"
		info.Body.Text = where
		if KingdomMapGen.CanHoldCastle(x, y) then
			moveButton(setAction, "Move Here", Cfg.Move.AdvancedCost, function()
				requestMove("MoveTo", x, y)
			end)
			setAction2("Send Army", sendArmy)
		else
			setAction("Send Army", sendArmy)
		end
	end
	if not info.Frame.Visible then
		info.Frame.Visible = true
		UIStyle.PopIn(info.Frame)
	end
end

local function groundTileAt(screenPos: Vector2): (number?, number?)
	local ray = camera:ScreenPointToRay(screenPos.X, screenPos.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil, nil
	end
	local t = (Cfg.GroundY - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil, nil
	end
	local x, y = KingdomMapGen.WorldToTile(ray.Origin + ray.Direction * t)
	if not KingdomMapGen.InBounds(x, y) then
		return nil, nil
	end
	return x, y
end

-- Taps (not drags) on the map. Same rules as BuildingController: skip presses on Active GUI.
local press: InputObject? = nil
local pressStart = Vector2.zero
local pressCancelled = false
local touches = 0

local function isOverGui(pos: Vector2): boolean
	for _, obj in ipairs(player.PlayerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)) do
		if obj.Active then
			return true
		end
	end
	return false
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch then
		touches += 1
		if touches > 1 then
			pressCancelled = true
			return
		end
	end
	if not isOpen or gameProcessed or not isPress(input) then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	if isOverGui(pos) then
		return
	end
	press, pressStart, pressCancelled = input, pos, false
end

local function onInputChanged(input: InputObject)
	if not press or pressCancelled then
		return
	end
	local isMyMove = input == press
		or (press.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
	if isMyMove and (Vector2.new(input.Position.X, input.Position.Y) - pressStart).Magnitude >= GameConfig.Camera.DragThreshold then
		pressCancelled = true
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.Touch then
		touches = math.max(0, touches - 1)
	end
	if not press or input.UserInputType ~= press.UserInputType then
		return
	end
	press = nil
	if pressCancelled or not isOpen then
		return
	end
	local x, y = groundTileAt(Vector2.new(input.Position.X, input.Position.Y))
	if x then
		selectTile(x, y)
	end
end

------------------------------------------------------------------------
-- Open / close
------------------------------------------------------------------------
local function buildWorld()
	if world or building then
		return
	end
	building = true
	local folder = Instance.new("Folder")
	folder.Name = "KingdomMap"
	folder.Parent = workspace
	MapVisuals.BuildGround(folder)
	MapVisuals.BuildFeatures(folder)
	castleFolder = Instance.new("Folder")
	castleFolder.Name = "Castles"
	castleFolder.Parent = folder
	selector = MapVisuals.BuildSelector(folder)
	world = folder
	building = false
end

local function myCastleWorld(): Vector3?
	local tile = myTile or (ClientData.Get() or {}).MapTile
	if tile then
		return KingdomMapGen.TileToWorld(tile.X, tile.Y)
	end
	return nil
end

-- While the map is open the server streams the world around this tile (nil = back to the character)
local lastFocus: Vector3? = nil
local function sendFocus(x: number?, y: number?)
	lastFocus = if x and y then KingdomMapGen.TileToWorld(x, y) else nil
	task.spawn(function()
		pcall(function()
			ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MapAction"):InvokeServer("Focus", x, y)
		end)
	end)
end

function MapController.SetOpen(open: boolean)
	if open == isOpen then
		return
	end
	if open and not CameraController.IsEnabled() then
		return -- the Map button is hidden while exploring
	end
	isOpen = open
	local explore = hud:FindFirstChild("ExploreButton", true)
	if explore then
		explore.Visible = not open
	end
	homeButton.Visible = open
	coordChip.Visible = open
	MapSearchController.SetMapOpen(open)
	ShareController.SetMapOpen(open)
	mapButton.Text = if open then "City" else "Map"
	UIStyle.SetIcon(mapButton, if open then "City" else "Map")
	if open then
		local window = hud:FindFirstChild("BuildingWindow")
		if window then
			window.Visible = false
		end
		mapButton.Text = "Loading..."
		-- the map ground is Terrain far from the character: the server streams around the map view instead
		local tile = myTile or (ClientData.Get() or {}).MapTile
		sendFocus(if tile then tile.X else math.ceil(Cfg.Size / 2), if tile then tile.Y else math.ceil(Cfg.Size / 2))
		buildWorld()
		mapButton.Text = "City"
		CameraController.SetView("Map", myCastleWorld())
		task.spawn(fetchCastles)
		MarchController.SetMapOpen(true, world)
		MapVisuals.SetFeatureMotion(true)
	else
		info.Frame.Visible = false
		sendFocus(nil, nil)
		MarchController.SetMapOpen(false)
		MapVisuals.SetFeatureMotion(false)
		CameraController.SetView("City")
	end
end

function MapController.IsOpen(): boolean
	return isOpen
end

-- Opens the map, reloads the castles and moves the camera to (x, y) with that tile selected (admin)
function MapController.ShowTile(x: number, y: number)
	if not isOpen then
		MapController.SetOpen(true)
		if not isOpen then
			return -- exploring: the map can't open
		end
	end
	task.wait(GameConfig.Remotes.MinRequestInterval) -- the server refuses two map requests too close together
	fetchCastles()
	MapController.GoTo(x, y)
end

-- Moves the camera to (x, y) and selects it (map open)
function MapController.GoTo(x: number, y: number)
	CameraController.PanTo(KingdomMapGen.TileToWorld(x, y))
	selectTile(x, y)
end

function MapController.Start()
	hud = player:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
	for _, name in ipairs({ "MapButton", "MapHomeButton", "MapInfo", "MapCoord" }) do
		local old = hud:FindFirstChild(name, true)
		if old then
			old:Destroy()
		end
	end
	mapButton = makeButton("MapButton", "Map", "Map", 2, hud, true)
	homeButton = makeButton("MapHomeButton", "Home", "Home", 3, hud)
	homeButton.Visible = false
	buildInfoPanel()
	coordChip = buildCoordChip()
	MapSearchController.Start(hud, MapController.GoTo)
	ShareController.Start(hud, MapController.ShowTile)

	mapButton.Activated:Connect(function()
		if not building then
			MapController.SetOpen(not isOpen)
		end
	end)
	homeButton.Activated:Connect(function()
		local pos = myCastleWorld()
		if pos then
			CameraController.PanTo(pos)
			if myTile then
				selectTile(myTile.X, myTile.Y)
			end
		end
	end)
	ClientData.Changed:Connect(function(snapshot)
		if snapshot and snapshot.MapTile then
			local old = myTile
			myTile = snapshot.MapTile
			if isOpen and (not old or old.X ~= myTile.X or old.Y ~= myTile.Y) then
				task.spawn(fetchCastles) -- our castle moved
			end
		end
	end)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)

	-- coordinates chip: the tile in the middle of the screen. Also moves the streaming focus there
	-- (StreamingEnabled only sends what is near the focus; the map is far from the character).
	task.spawn(function()
		while true do
			task.wait(0.2)
			if isOpen then
				local view = camera.ViewportSize
				local x, y = groundTileAt(Vector2.new(view.X / 2, view.Y / 2))
				if x then
					coordChip.Text = ("Kingdom %d · X %d · Y %d"):format(Cfg.KingdomId, x, y)
					local fx, fy = math.clamp(x, 1, Cfg.Size), math.clamp(y, 1, Cfg.Size)
					if not lastFocus or (KingdomMapGen.TileToWorld(fx, fy) - lastFocus).Magnitude > Cfg.StreamStep then
						sendFocus(fx, fy)
					end
				end
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Cfg.ClientRefreshSeconds)
			if isOpen then
				fetchCastles()
			end
		end
	end)
end

return MapController
