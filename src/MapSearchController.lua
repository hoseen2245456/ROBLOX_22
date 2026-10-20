-- MapSearchController: the map's "Search" button and panel (client only).
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.MapSearchController (ModuleScript)
-- Go to coordinates, or find the nearest monster / resource node of a level (pressing Search again
-- shows the next nearest). Monsters and nodes come from KingdomMapGen (same seed as the server), so no
-- server request is needed. MapController starts it and shows the button only while the map is open.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local UIStyle = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("UIStyle"))
local KingdomMapGen = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("KingdomMapGen"))

local MapSearchController = {}

local KINDS = { "Monster", "Food", "Wood", "Stone", "Gold" } -- "Monster" or a node's Resource
local camera = workspace.CurrentCamera

local goTo: (number, number) -> () = function() end
local button: TextButton
local panel: Frame
local status: TextLabel
local levelLabel: TextLabel
local kindButtons = {} -- kind -> TextButton
local kind = "Monster"
local level = 1
local maxLevel = {} -- kind -> highest level on the map
local results = nil -- tiles of the last search, nearest first
local resultIndex = 0
local resultKey = ""

local Art = GameConfig.Art
local WELL = Color3.fromHex("#0d0f12")

local function kindOf(f): string
	return if f.Kind == "Monster" then "Monster" else f.Resource or "?"
end

-- style: a GameConfig.Art.Buttons name
local function newButton(parent: Instance, name: string, text: string, size: UDim2, pos: UDim2, style: string): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.Position = pos
	b.TextSize = 14
	b.Text = text
	b.Parent = parent
	UIStyle.Button(b, style)
	return b
end

local function newLabel(parent: Instance, name: string, text: string, size: UDim2, pos: UDim2, textSize: number, fontKey: string?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.Text = text
	UIStyle.Text(l, fontKey or "Number", textSize)
	l.Parent = parent
	return l
end

local function newBox(parent: Instance, name: string, pos: UDim2): TextBox
	local box = Instance.new("TextBox")
	box.Name = name
	box.Size = UDim2.new(0, 60, 0, 30)
	box.Position = pos
	box.BackgroundColor3 = WELL
	box.FontFace = Art.Fonts.Number
	box.TextSize = 16
	box.TextColor3 = Art.Colors.Text
	box.PlaceholderColor3 = Art.Colors.Muted
	box.PlaceholderText = "1-" .. GameConfig.Map.Size
	box.Text = ""
	box.ClearTextOnFocus = false
	box.Parent = parent
	UIStyle.Corner(box, UDim.new(0, 6))
	UIStyle.Stroke(box, Art.Colors.GoldDark, 1)
	return box
end

-- The tile in the middle of the screen (the map is flat at Map.Origin.Y)
local function viewTile(): (number, number)
	local ray = camera:ViewportPointToRay(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
	local y = GameConfig.Map.Origin.Y
	if math.abs(ray.Direction.Y) > 1e-3 then
		local t = (y - ray.Origin.Y) / ray.Direction.Y
		if t > 0 then
			return KingdomMapGen.WorldToTile(ray.Origin + ray.Direction * t)
		end
	end
	local half = math.ceil(GameConfig.Map.Size / 2)
	return half, half
end

local function refreshKind()
	for k, b in pairs(kindButtons) do
		UIStyle.Button(b, if k == kind then "Primary" else "Neutral")
	end
	level = math.clamp(level, 1, maxLevel[kind] or 1)
	levelLabel.Text = ("Lv %d"):format(level)
end

local function search()
	local key = kind .. "_" .. level
	if key ~= resultKey or not results or #results == 0 then
		local cx, cy = viewTile()
		results = {}
		for _, f in ipairs(KingdomMapGen.GetFeatures()) do
			if kindOf(f) == kind and f.Level == level then
				table.insert(results, { X = f.X, Y = f.Y, D = (f.X - cx) ^ 2 + (f.Y - cy) ^ 2 })
			end
		end
		table.sort(results, function(a, b)
			return a.D < b.D
		end)
		resultKey = key
		resultIndex = 0
	end
	if #results == 0 then
		status.Text = ("No %s Lv %d on the map"):format(kind, level)
		return
	end
	resultIndex = resultIndex % #results + 1
	local r = results[resultIndex]
	status.Text = ("%s Lv %d at (%d, %d) · %d of %d (Search again for the next)"):format(kind, level, r.X, r.Y, resultIndex, #results)
	goTo(r.X, r.Y)
end

local function goToTyped(xBox: TextBox, yBox: TextBox)
	local x, y = tonumber(xBox.Text), tonumber(yBox.Text)
	if not x or not y or x % 1 ~= 0 or y % 1 ~= 0 or not KingdomMapGen.InBounds(x, y) then
		status.Text = ("Type whole numbers from 1 to %d"):format(GameConfig.Map.Size)
		return
	end
	status.Text = ("Going to (%d, %d)"):format(x, y)
	goTo(x, y)
end

local function build(hud: ScreenGui)
	for _, name in ipairs({ "MapSearchButton", "MapSearch" }) do
		local old = hud:FindFirstChild(name, true)
		if old then
			old:Destroy()
		end
	end

	button = UIStyle.Medallion(UIStyle.SideColumn(hud), "MapSearchButton", "Search", "Search")
	button.LayoutOrder = 4
	button.Visible = false

	panel = Instance.new("Frame")
	panel.Name = "MapSearch"
	panel.Active = true
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -84, 0, 100)
	panel.Size = UDim2.new(0, 300, 0, 262)
	panel.Visible = false
	panel.Parent = hud
	UIStyle.Exclusive(panel)
	UIStyle.Panel(panel, Art.Colors.Border)

	newLabel(panel, "Title", "Search", UDim2.new(1, -60, 0, 26), UDim2.new(0, 12, 0, 8), 18, "Title").TextColor3 = Art.Colors.GoldLight
	local close = newButton(panel, "Close", "X", UDim2.new(0, 28, 0, 28), UDim2.new(1, -36, 0, 6), "Danger")
	close.Activated:Connect(function()
		panel.Visible = false
	end)

	-- Coordinates
	newLabel(panel, "GoLabel", "Go to", UDim2.new(0, 50, 0, 30), UDim2.new(0, 12, 0, 42), 14)
	newLabel(panel, "XLabel", "X", UDim2.new(0, 14, 0, 30), UDim2.new(0, 64, 0, 42), 14)
	local xBox = newBox(panel, "X", UDim2.new(0, 80, 0, 42))
	newLabel(panel, "YLabel", "Y", UDim2.new(0, 14, 0, 30), UDim2.new(0, 148, 0, 42), 14)
	local yBox = newBox(panel, "Y", UDim2.new(0, 164, 0, 42))
	local go = newButton(panel, "Go", "Go", UDim2.new(0, 52, 0, 30), UDim2.new(1, -64, 0, 42), "Confirm")
	go.Activated:Connect(function()
		goToTyped(xBox, yBox)
	end)
	yBox.FocusLost:Connect(function(enter)
		if enter then
			goToTyped(xBox, yBox)
		end
	end)

	-- Kind + level
	newLabel(panel, "FindLabel", "Find the nearest", UDim2.new(1, -24, 0, 20), UDim2.new(0, 12, 0, 84), 14, "Subtitle")
	local w = (300 - 24 - 4 * 4) / #KINDS
	for i, k in ipairs(KINDS) do
		local b = newButton(panel, "Kind_" .. k, k, UDim2.new(0, w, 0, 30), UDim2.new(0, 12 + (i - 1) * (w + 4), 0, 108), "Neutral")
		b.TextSize = 12
		kindButtons[k] = b
		b.Activated:Connect(function()
			kind = k
			refreshKind()
		end)
	end
	local minus = newButton(panel, "LevelDown", "-", UDim2.new(0, 36, 0, 30), UDim2.new(0, 12, 0, 146), "Neutral")
	levelLabel = newLabel(panel, "Level", "Lv 1", UDim2.new(0, 60, 0, 30), UDim2.new(0, 54, 0, 146), 16)
	levelLabel.TextXAlignment = Enum.TextXAlignment.Center
	local plus = newButton(panel, "LevelUp", "+", UDim2.new(0, 36, 0, 30), UDim2.new(0, 120, 0, 146), "Neutral")
	minus.Activated:Connect(function()
		level -= 1
		refreshKind()
	end)
	plus.Activated:Connect(function()
		level += 1
		refreshKind()
	end)
	local find = newButton(panel, "Find", "Search", UDim2.new(0, 120, 0, 30), UDim2.new(1, -132, 0, 146), "Confirm")
	find.Activated:Connect(search)

	status = newLabel(panel, "Status", "Type a tile, or pick what to find.", UDim2.new(1, -24, 0, 70), UDim2.new(0, 12, 0, 184), 14, "Body")
	status.TextColor3 = Art.Colors.Muted
	status.TextYAlignment = Enum.TextYAlignment.Top

	button.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
	refreshKind()
end

-- Shows the Search button while the map is open (MapController.SetOpen)
function MapSearchController.SetMapOpen(open: boolean)
	if button then
		button.Visible = open
		if not open then
			panel.Visible = false
		end
	end
end

-- onGoTo(x, y) moves the camera to a tile and selects it (MapController)
function MapSearchController.Start(hud: ScreenGui, onGoTo: (number, number) -> ())
	goTo = onGoTo
	for _, f in ipairs(KingdomMapGen.GetFeatures()) do
		local k = kindOf(f)
		maxLevel[k] = math.max(maxLevel[k] or 1, f.Level)
	end
	build(hud)
end

return MapSearchController
