-- BuildingController: tap a plot (or the walls) to open its building window, and show countdowns
-- on buildings under construction.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.BuildingController (ModuleScript)
-- The client only asks (Remotes.BuildingAction / TrainingAction); the server checks and decides. Costs and
-- requirements shown here come from GameConfig and the last DataSync snapshot, for display only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local BuildingVisuals = require(ReplicatedStorage.Modules.BuildingVisuals)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local ClientData = require(script.Parent.ClientData)
local CameraController = require(script.Parent.CameraController)
local ProductionController = require(script.Parent.ProductionController)

local BuildingController = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local buildingAction: RemoteFunction
local trainingAction: RemoteFunction
local city: Model

-- Look: docs\art\ui.html section 2 (colors from GameConfig.Art, extra shades from the page)
local Art = GameConfig.Art
local RESOURCE_ORDER = { "Food", "Wood", "Stone", "Gold", GameConfig.RareMaterial }
local COLOR_TEXT = Art.Colors.Text
local COLOR_DIM = Art.Colors.Muted
local COLOR_GOOD = Art.Status.Gain
local COLOR_BAD = Art.Status.Loss
local COLOR_SECTION = Art.Colors.Background
local COLOR_SECTION_LINE = Color3.fromHex("#2c2f35")
local COLOR_WELL = Color3.fromHex("#0d0f12") -- cost chips, count box, bars
local COLOR_BAD_LINE = Color3.fromHex("#6e1d1a")
local HEADER_GREEN = { Color3.fromHex("#2f6247"), Color3.fromHex("#1d3d2d") }
local HEADER_BLUE = { Color3.fromHex("#24476b"), Color3.fromHex("#162c45") }
local BAR_BUILD = { Color3.fromHex("#f2c06a"), Color3.fromHex("#c07a1a") }
local BAR_TRAIN = { Color3.fromHex("#4f9fe0"), Color3.fromHex("#1f4f80") }
local TIER_NAMES = { "I", "II", "III", "IV", "V", "VI" }
local MAX_REQ_ROWS = 4
-- Header icon for buildings that neither produce nor train (GameConfig.Art.Icons key)
local BUILDING_ICONS = { Castle = "Castle", Walls = "Castle", WatchTower = "Search", Market = "Gold", Embassy = "Shared", Storehouse = "Wood" }

-- Current press (mouse button or one finger). A press that moves or adds a finger is not a tap.
local press: InputObject? = nil
local pressStart = Vector2.zero
local pressCancelled = false
local touches = 0

local win = {} -- the building window's parts (see createWindow)
local openPlotId: string? = nil
local openAction: string? = nil
local requesting = false
local trainTier = 1
local trainCount: number? = nil -- nil = pick the most the player can afford on the next refresh
local trainMax = 1 -- most troops in one batch for the open building
local sliding = false -- dragging the troop count slider
local goToBuilding: (string) -> () -- requirement "Go" buttons (defined after openWindow)

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	local d, h = seconds // 86400, (seconds % 86400) // 3600
	local m, s = (seconds % 3600) // 60, seconds % 60
	if d > 0 then
		return ("%dd %02dh"):format(d, h)
	elseif h > 0 then
		return ("%dh %02dm"):format(h, m)
	end
	return ("%02d:%02d"):format(m, s)
end

-- 1234 -> "1,234", 12345 -> "12.3K"
local function formatAmount(n: number): string
	n = math.floor(n)
	if n >= 1e6 then
		return ("%.2fM"):format(n / 1e6)
	elseif n >= 1e4 then
		return ("%.1fK"):format(n / 1e3)
	elseif n >= 1000 then
		return ("%d,%03d"):format(n // 1000, n % 1000)
	end
	return tostring(n)
end

local function highestLevel(data, buildingType: string): number
	local best = 0
	for _, building in pairs(data and data.Buildings or {}) do
		if building.Type == buildingType and building.Level > best then
			best = building.Level
		end
	end
	return best
end

local function findPlotModel(plotId: string): Model?
	if plotId == "Walls_1" then
		return city:FindFirstChild("Walls") :: Model?
	end
	return city.Plots:FindFirstChild(plotId) :: Model?
end

------------------------------------------------------------------------
-- Window parts (docs\art\ui.html section 2)
------------------------------------------------------------------------
local function addPadding(parent: Instance, vertical: number, horizontal: number?)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop, padding.PaddingBottom = UDim.new(0, vertical), UDim.new(0, vertical)
	padding.PaddingLeft, padding.PaddingRight = UDim.new(0, horizontal or vertical), UDim.new(0, horizontal or vertical)
	padding.Parent = parent
end

local function addList(parent: Instance, px: number, horizontal: boolean?)
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, px)
	if horizontal then
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	layout.Parent = parent
	return layout
end

local function makeText(parent: Instance, name: string, order: number, fontKey: string, textSize: number, color: Color3?)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.LayoutOrder = order
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	UIStyle.Text(label, fontKey, textSize, color)
	label.TextWrapped = true
	label.RichText = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = parent
	return label
end

local function makeButton(parent: Instance, name: string, text: string, style: string, size: UDim2)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.TextSize = 16
	button.RichText = true
	button.Text = text
	button.Parent = parent
	UIStyle.Button(button, style)
	button.TextSize = 16
	return button
end

local function makeRow(parent: Instance, name: string, order: number, height: number)
	local row = Instance.new("Frame")
	row.Name = name
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, height)
	row.Parent = parent
	return row
end

-- Dark box with a gold title on the left and a small grey note on the right
local function makeSection(parent: Instance, name: string, order: number)
	local section = Instance.new("Frame")
	section.Name = name
	section.LayoutOrder = order
	section.Size = UDim2.new(1, 0, 0, 0)
	section.AutomaticSize = Enum.AutomaticSize.Y
	section.BackgroundColor3 = COLOR_SECTION
	section.Visible = false
	UIStyle.Corner(section, UDim.new(0, 10))
	UIStyle.Stroke(section, COLOR_SECTION_LINE, 1)
	addPadding(section, 10, 12)
	addList(section, 6)
	section.Parent = parent
	local head = makeRow(section, "Head", 0, 18)
	local title = makeText(head, "Title", 0, "Subtitle", 14, Art.Colors.GoldLight)
	title.AutomaticSize = Enum.AutomaticSize.None
	title.Size = UDim2.new(0.64, 0, 1, 0)
	title.TextWrapped = false
	title.TextTruncate = Enum.TextTruncate.AtEnd
	local note = makeText(head, "Note", 0, "Body", 12, COLOR_DIM)
	note.AutomaticSize = Enum.AutomaticSize.None
	note.AnchorPoint = Vector2.new(1, 0)
	note.Position = UDim2.new(1, 0, 0, 0)
	note.Size = UDim2.new(0.36, 0, 1, 0)
	note.TextXAlignment = Enum.TextXAlignment.Right
	return section, title, note
end

-- "Food / hour   1,200 -> 1,450"
local function makeStatRow(parent: Instance, order: number)
	local row = makeRow(parent, "Stat" .. order, order, 20)
	local name = makeText(row, "Name", 0, "Body", 14, COLOR_DIM)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.Size = UDim2.new(0.5, 0, 1, 0)
	local values = Instance.new("Frame")
	values.Name = "Values"
	values.BackgroundTransparency = 1
	values.AnchorPoint = Vector2.new(1, 0)
	values.Position = UDim2.new(1, 0, 0, 0)
	values.Size = UDim2.new(0.5, 0, 1, 0)
	values.Parent = row
	addList(values, 6, true).HorizontalAlignment = Enum.HorizontalAlignment.Right
	local parts = {}
	for i, part in ipairs({ { "Before", COLOR_TEXT }, { "Arrow", Art.Colors.Gold }, { "After", COLOR_GOOD } }) do
		local label = makeText(values, part[1], i, "Number", 14, part[2])
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.new(0, 0, 1, 0)
		label.TextWrapped = false
		parts[part[1]] = label
	end
	parts.Arrow.Text = "→"
	return { Frame = row, Name = name, Before = parts.Before, After = parts.After }
end

-- Rows of "[mark] text" (requirements, unlocks). A row with a target building has a "Go" button
-- that takes the camera there and opens it (onGo(buildingType)).
local function makeMarkRows(parent: Instance, firstOrder: number, onGo: ((string) -> ())?)
	local rows = {}
	for i = 1, MAX_REQ_ROWS do
		local row = makeRow(parent, "Row" .. i, firstOrder + i, 20)
		local mark = makeText(row, "Mark", 0, "Number", 14)
		mark.AutomaticSize = Enum.AutomaticSize.None
		mark.Size = UDim2.new(0, 18, 1, 0)
		local text = makeText(row, "Text", 0, "Body", 13)
		text.AutomaticSize = Enum.AutomaticSize.None
		text.Position = UDim2.new(0, 20, 0, 0)
		text.Size = UDim2.new(1, if onGo then -64 else -20, 1, 0)
		text.TextWrapped = false
		text.TextTruncate = Enum.TextTruncate.AtEnd
		local entry = { Frame = row, Mark = mark, Text = text, Target = nil }
		if onGo then
			local go = makeButton(row, "Go", "Go", "Primary", UDim2.new(0, 40, 1, 0))
			go.AnchorPoint = Vector2.new(1, 0)
			go.Position = UDim2.new(1, 0, 0, 0)
			go.TextSize = 13
			go.Activated:Connect(function()
				if entry.Target then
					onGo(entry.Target)
				end
			end)
			entry.Go = go
		end
		rows[i] = entry
	end
	return rows
end

-- items = {{mark, color, text, targetType?}}; returns true if any row is shown
local function setMarkRows(rows, items): boolean
	for i, row in ipairs(rows) do
		local item = items[i]
		row.Frame.Visible = item ~= nil
		if item then
			row.Mark.Text, row.Mark.TextColor3, row.Text.Text = item[1], item[2], item[3]
			row.Target = item[4]
			if row.Go then
				row.Go.Visible = item[4] ~= nil
			end
		end
	end
	return #items > 0
end

-- Rounded progress bar with the time written on it; returns the fill and the label
local function makeBar(parent: Instance, order: number)
	local track = Instance.new("Frame")
	track.Name = "Bar"
	track.LayoutOrder = order
	track.Size = UDim2.new(1, 0, 0, 16)
	track.BackgroundColor3 = COLOR_WELL
	UIStyle.Corner(track, UDim.new(1, 0))
	UIStyle.Stroke(track, Color3.new(0, 0, 0), 1)
	track.ClipsDescendants = true
	track.Parent = parent
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	UIStyle.Corner(fill, UDim.new(1, 0))
	UIStyle.Gradient(fill, BAR_BUILD[1], BAR_BUILD[2])
	fill.Parent = track
	local label = makeText(track, "Time", 0, "Number", 12)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.Size = UDim2.new(1, 0, 1, 0)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextStrokeTransparency = 0.3
	label.ZIndex = 2
	return fill, label
end

-- Two columns of chips: [icon] 3,200 ... have 24.6K (red when not enough)
local function makeCostGrid(parent: Instance, order: number)
	local grid = Instance.new("Frame")
	grid.Name = "Cost"
	grid.LayoutOrder = order
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.Parent = parent
	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.CellSize = UDim2.new(0.5, -3, 0, 28)
	layout.CellPadding = UDim2.new(0, 6, 0, 6)
	layout.Parent = grid
	local chips = {}
	for i, resource in ipairs(RESOURCE_ORDER) do
		local chip = Instance.new("Frame")
		chip.Name = resource
		chip.LayoutOrder = i
		chip.BackgroundColor3 = COLOR_WELL
		chip.Visible = false
		UIStyle.Corner(chip, UDim.new(0, 8))
		local stroke = UIStyle.Stroke(chip, COLOR_SECTION_LINE, 1)
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 5, 0.5, 0)
		icon.Size = UDim2.new(0, 22, 0, 22)
		icon.Image = UIStyle.Icon(resource)
		icon.Parent = chip
		local amount = makeText(chip, "Amount", 0, "Number", 14)
		amount.AutomaticSize = Enum.AutomaticSize.X
		amount.Position = UDim2.new(0, 31, 0, 0)
		amount.Size = UDim2.new(0, 0, 1, 0)
		amount.TextWrapped = false
		local have = makeText(chip, "Have", 0, "Body", 12, COLOR_DIM)
		have.AutomaticSize = Enum.AutomaticSize.X
		have.AnchorPoint = Vector2.new(1, 0)
		have.Position = UDim2.new(1, -7, 0, 0)
		have.Size = UDim2.new(0, 0, 1, 0)
		have.TextWrapped = false
		chip.Parent = grid
		chips[resource] = { Frame = chip, Stroke = stroke, Amount = amount, Have = have }
	end
	return chips
end

-- Shows the cost; returns the first resource the player is short of (nil = can afford)
local function setCost(chips, cost, data): string?
	local short = nil
	for _, resource in ipairs(RESOURCE_ORDER) do
		local chip, amount = chips[resource], cost[resource]
		chip.Frame.Visible = amount ~= nil
		if amount then
			local have = data and data.Resources[resource] or 0
			local enough = have >= amount
			short = short or (not enough and resource or nil)
			chip.Amount.Text = formatAmount(amount)
			chip.Amount.TextColor3 = if enough then COLOR_TEXT else COLOR_BAD
			chip.Stroke.Color = if enough then COLOR_SECTION_LINE else COLOR_BAD_LINE
			chip.Have.Text = formatAmount(have)
		end
	end
	return short
end

-- Main button with a small grey reason after the label
local function setButton(button: TextButton, label: string, ok: boolean, style: string, note: string?)
	UIStyle.Button(button, if ok then style else "Disabled")
	button.TextSize = 16
	button.Text = if note and note ~= "" then ('%s  <font size="13">%s</font>'):format(label, note) else label
end

local function setStatus(text: string, isError: boolean?)
	win.Status.Text = text
	win.Status.Visible = text ~= ""
	win.Status.TextColor3 = if isError then COLOR_BAD else COLOR_DIM
	win.Status.BackgroundColor3 = if isError then Color3.fromHex("#3a1412") else COLOR_SECTION
	win.StatusStroke.Color = if isError then COLOR_BAD_LINE else COLOR_SECTION_LINE
end

local function createHeader(frame: Frame)
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0, 66)
	UIStyle.Corner(header, UDim.new(0, 10))
	header.Parent = frame
	win.Header = header
	-- squares the header's bottom corners, then a gold line under it
	local base = Instance.new("Frame")
	base.Name = "Base"
	base.AnchorPoint = Vector2.new(0, 1)
	base.Position = UDim2.new(0, 0, 1, 0)
	base.Size = UDim2.new(1, 0, 0, 12)
	base.BorderSizePixel = 0
	base.Parent = header
	win.HeaderBase = base
	local line = Instance.new("Frame")
	line.Name = "Line"
	line.AnchorPoint = Vector2.new(0, 1)
	line.Position = UDim2.new(0, 0, 1, 0)
	line.Size = UDim2.new(1, 0, 0, 2)
	line.BorderSizePixel = 0
	line.BackgroundColor3 = Art.Colors.GoldDark
	line.ZIndex = 2
	line.Parent = header

	local box = Instance.new("Frame")
	box.Name = "IconBox"
	box.AnchorPoint = Vector2.new(0, 0.5)
	box.Position = UDim2.new(0, 12, 0.5, -1)
	box.Size = UDim2.new(0, 46, 0, 46)
	box.ZIndex = 2
	UIStyle.Corner(box, UDim.new(0, 10))
	UIStyle.Gradient(box, Color3.fromHex("#3a4049"), Art.Colors.Background)
	UIStyle.Stroke(box, Art.Colors.Gold, 2)
	box.Parent = header
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(0, 34, 0, 34)
	icon.ZIndex = 2
	icon.Parent = box
	win.Icon = icon

	local title = makeText(header, "Title", 0, "Title", 17)
	title.AutomaticSize = Enum.AutomaticSize.None
	title.Position = UDim2.new(0, 68, 0, 11)
	title.Size = UDim2.new(1, -160, 0, 22)
	title.TextWrapped = false
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.ZIndex = 2
	win.Title = title
	local sub = makeText(header, "Level", 0, "Body", 13, Color3.fromHex("#d9e8dc"))
	sub.AutomaticSize = Enum.AutomaticSize.None
	sub.Position = UDim2.new(0, 68, 0, 34)
	sub.Size = UDim2.new(1, -120, 0, 18)
	sub.TextWrapped = false
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	sub.ZIndex = 2
	win.Level = sub

	local chip = makeText(header, "LevelChip", 0, "Title", 12, Color3.fromHex("#1b1608"))
	chip.AnchorPoint = Vector2.new(1, 0)
	chip.Position = UDim2.new(1, -50, 0, 13)
	chip.Size = UDim2.new(0, 0, 0, 20)
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.TextWrapped = false
	chip.TextXAlignment = Enum.TextXAlignment.Center
	chip.ZIndex = 2
	UIStyle.Corner(chip, UDim.new(1, 0))
	UIStyle.Gradient(chip, Art.Colors.GoldLight, Color3.fromHex("#c08f30"))
	chip.BackgroundTransparency = 0
	UIStyle.Stroke(chip, Color3.fromHex("#6b4c16"), 1)
	addPadding(chip, 0, 9)
	win.LevelChip = chip

	win.Close = makeButton(header, "Close", "X", "Danger", UDim2.new(0, 30, 0, 30))
	win.Close.AnchorPoint = Vector2.new(1, 0)
	win.Close.Position = UDim2.new(1, -12, 0, 10)
	win.Close.ZIndex = 2
end

local function createTrain(body: Frame)
	local train = Instance.new("Frame")
	train.Name = "Train"
	train.LayoutOrder = 8
	train.BackgroundTransparency = 1
	train.Size = UDim2.new(1, 0, 0, 0)
	train.AutomaticSize = Enum.AutomaticSize.Y
	train.Visible = false
	addList(train, 8)
	train.Parent = body
	win.TrainSection = train

	-- Tier tabs: framed in the tier color, the chosen one glows gold, locked ones are faded
	local tiers = makeRow(train, "Tiers", 1, 58)
	addList(tiers, 6, true)
	win.Tiers = {}
	local tierCount = #GameConfig.TroopTiers
	for tier = 1, tierCount do
		local tab = Instance.new("TextButton")
		tab.Name = "T" .. tier
		tab.LayoutOrder = tier
		tab.Text = ""
		tab.AutoButtonColor = false
		tab.Size = UDim2.new(1 / tierCount, -6 * (tierCount - 1) / tierCount, 1, 0)
		tab.BackgroundColor3 = COLOR_SECTION
		UIStyle.Corner(tab, UDim.new(0, 10))
		local stroke = UIStyle.Stroke(tab, Art.TroopTiers[tier].Frame, 2)
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.new(0.5, 0, 0, 5)
		icon.Size = UDim2.new(0, 30, 0, 30)
		icon.Parent = tab
		local label = makeText(tab, "Label", 0, "Title", 12)
		label.AutomaticSize = Enum.AutomaticSize.None
		label.AnchorPoint = Vector2.new(0, 1)
		label.Position = UDim2.new(0, 0, 1, -3)
		label.Size = UDim2.new(1, 0, 0, 16)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextWrapped = false
		tab.Parent = tiers
		win.Tiers[tier] = { Button = tab, Stroke = stroke, Icon = icon, Label = label }
	end

	-- [-] count [+] [Max]
	local count = makeRow(train, "CountRow", 2, 36)
	addList(count, 6, true)
	win.Minus = makeButton(count, "Minus", "-", "Neutral", UDim2.new(0, 36, 1, 0))
	local value = makeText(count, "Count", 0, "Number", 18)
	value.AutomaticSize = Enum.AutomaticSize.None
	value.Size = UDim2.new(1, -(36 + 36 + 52 + 18), 1, 0)
	value.TextXAlignment = Enum.TextXAlignment.Center
	value.BackgroundTransparency = 0
	value.BackgroundColor3 = COLOR_WELL
	UIStyle.Corner(value, UDim.new(0, 8))
	UIStyle.Stroke(value, Art.Colors.Border, 1)
	win.Count = value
	win.Plus = makeButton(count, "Plus", "+", "Neutral", UDim2.new(0, 36, 1, 0))
	win.Max = makeButton(count, "Max", "Max", "Neutral", UDim2.new(0, 52, 1, 0))
	win.Max.TextSize = 14
	for i, name in ipairs({ "Minus", "Count", "Plus", "Max" }) do
		win[name].LayoutOrder = i
	end

	-- Slider: press or drag anywhere on it to pick the count
	local slider = Instance.new("TextButton")
	slider.Name = "Slider"
	slider.LayoutOrder = 3
	slider.Text = ""
	slider.AutoButtonColor = false
	slider.BackgroundTransparency = 1
	slider.Size = UDim2.new(1, 0, 0, 20)
	slider.Parent = train
	win.Slider = slider
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.5, 0)
	track.Size = UDim2.new(1, 0, 0, 8)
	track.BackgroundColor3 = COLOR_WELL
	UIStyle.Corner(track, UDim.new(1, 0))
	UIStyle.Stroke(track, Color3.new(0, 0, 0), 1)
	track.Parent = slider
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	UIStyle.Corner(fill, UDim.new(1, 0))
	UIStyle.Gradient(fill, BAR_TRAIN[2], BAR_TRAIN[1]).Rotation = 0
	fill.Parent = track
	win.SliderFill = fill
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.Size = UDim2.new(0, 18, 0, 18)
	knob.ZIndex = 2
	UIStyle.Corner(knob, UDim.new(1, 0))
	UIStyle.Gradient(knob, Color3.new(1, 1, 1), Art.Colors.Gold)
	UIStyle.Stroke(knob, Color3.fromHex("#6b4c16"), 2)
	knob.Parent = slider
	win.SliderKnob = knob

	win.TrainCost = makeCostGrid(train, 4)
	win.Train = makeButton(train, "TrainButton", "Train", "Train", UDim2.new(1, 0, 0, 42))
	win.Train.LayoutOrder = 5
end

local function createWindow()
	local hud = player:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
	local frame = Instance.new("Frame")
	frame.Name = "BuildingWindow"
	-- Right side: the timers list is on the left, and the tapped building stays visible
	frame.AnchorPoint = Vector2.new(1, 0.5)
	frame.Position = UDim2.new(1, -10, 0.55, 0)
	frame.Size = UDim2.new(0.4, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Active = true -- presses on the window are never city taps (see isOverGui)
	frame.Visible = false
	UIStyle.Corner(frame, UDim.new(0, 12))
	UIStyle.Gradient(frame, Art.Colors.Panel2, Color3.fromHex("#1b1f25"))
	UIStyle.Stroke(frame, Art.Colors.GoldDark, 2)
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MinSize = Vector2.new(300, 0)
	sizeLimit.MaxSize = Vector2.new(360, math.huge)
	sizeLimit.Parent = frame
	addPadding(frame, 2)
	addList(frame, 0)
	win.Frame = frame

	createHeader(frame)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.LayoutOrder = 2
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	addPadding(body, 12, 12)
	addList(body, 10)
	body.Parent = frame

	win.Info = makeText(body, "Info", 1, "Body", 14, COLOR_DIM)

	-- Running timer (build/upgrade or training)
	local timer
	timer, win.TimerTitle, win.TimerNote = makeSection(body, "Timer", 2)
	win.TimerSection = timer
	win.TimerFill, win.TimerTime = makeBar(timer, 1)

	-- Build / upgrade: stats before -> after
	local upgrade
	upgrade, win.UpgradeTitle, win.UpgradeTime = makeSection(body, "Upgrade", 3)
	win.UpgradeSection = upgrade
	win.Stats = { makeStatRow(upgrade, 1), makeStatRow(upgrade, 2) }

	-- What the next level brings (new look, new buildings, new troop tier)
	local unlocks
	unlocks, win.UnlocksTitle = makeSection(body, "Unlocks", 4)
	win.UnlocksSection = unlocks
	win.Unlocks = makeMarkRows(unlocks, 0)

	local cost
	cost, win.CostTitle = makeSection(body, "CostBox", 5)
	win.CostTitle.Text = "Cost"
	win.CostSection = cost
	win.UpgradeCost = makeCostGrid(cost, 1)

	local reqs
	reqs, win.ReqTitle = makeSection(body, "Requires", 6)
	win.ReqTitle.Text = "Requires"
	win.ReqSection = reqs
	win.Requirements = makeMarkRows(reqs, 0, function(buildingType)
		goToBuilding(buildingType)
	end)

	win.Confirm = makeButton(body, "Confirm", "Upgrade", "Confirm", UDim2.new(1, 0, 0, 42))
	win.Confirm.LayoutOrder = 7
	win.Confirm.Visible = false

	createTrain(body)

	local status = makeText(body, "Status", 9, "Number", 14, COLOR_BAD)
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.BackgroundTransparency = 0
	UIStyle.Corner(status, UDim.new(0, 8))
	win.StatusStroke = UIStyle.Stroke(status, COLOR_BAD_LINE, 1)
	addPadding(status, 6)
	status.Visible = false
	win.Status = status

	frame.Parent = hud
	-- one panel at a time: another panel opening closes this window
	UIStyle.Exclusive(frame, function()
		openPlotId, openAction = nil, nil
		sliding = false
	end)
end

local function closeWindow()
	openPlotId, openAction = nil, nil
	sliding = false
	win.Frame.Visible = false
end

local function headerIcon(buildingType: string, def): string
	return def.Produces or def.Trains or BUILDING_ICONS[buildingType] or "Hammer"
end

-- What reaching toLevel brings: new look, new buildings (Castle), new troop tier (training buildings)
local function unlocksAt(buildingType: string, def, level: number, toLevel: number)
	local items = {}
	local star = Art.Colors.Gold
	local tier = BuildingVisuals.GetTier(toLevel)
	if level > 0 and tier ~= BuildingVisuals.GetTier(level) then
		table.insert(items, { "★", star, ("New look (tier %s)"):format(TIER_NAMES[tier] or tostring(tier)) })
	end
	if buildingType == "Castle" then
		for _, other in pairs(GameConfig.Buildings) do
			if other.UnlockAt == toLevel and toLevel > 1 then
				table.insert(items, { "★", star, "New building: " .. other.DisplayName })
			end
		end
	end
	if def.Trains then
		for t, troopTier in ipairs(GameConfig.TroopTiers) do
			if troopTier.UnlockAt == toLevel and t > 1 then
				table.insert(items, { "★", star, ("Tier %s %s"):format(Art.TroopTiers[t].Name, def.Trains) })
			end
		end
	end
	return items
end

-- Before -> after numbers for the next level
local function setStats(buildingType: string, def, level: number, toLevel: number)
	local rows = {}
	if def.Produces then
		local resource = def.Produces
		local function rate(l)
			return if l > 0 then formatAmount(GameConfig.GetProductionPerHour(resource, l)) else "-"
		end
		local function cap(l)
			return if l > 0 then formatAmount(GameConfig.GetProductionCapacity(resource, l)) else "-"
		end
		rows = { { resource .. " / hour", rate(level), rate(toLevel) }, { "Capacity", cap(level), cap(toLevel) } }
	elseif def.Trains then
		local function batch(l)
			return if l > 0 then tostring(GameConfig.GetMaxTrainBatch(l)) else "-"
		end
		rows = { { "Troops per batch", batch(level), batch(toLevel) } }
	end
	for i, stat in ipairs(win.Stats) do
		local row = rows[i]
		stat.Frame.Visible = row ~= nil
		if row then
			stat.Name.Text, stat.Before.Text, stat.After.Text = row[1], row[2], row[3]
		end
	end
	return #rows > 0
end

-- Redraws the window from the plot model's attributes and the latest data snapshot
local function refreshWindow()
	if not openPlotId then
		return
	end
	local model = findPlotModel(openPlotId)
	if not model then
		closeWindow()
		return
	end
	local buildingType = model:GetAttribute("BuildingType")
	local def = GameConfig.Buildings[buildingType]
	local level = model:GetAttribute("Level") or 0
	local endsAt = model:GetAttribute("TimerEndsAt")
	local trainEndsAt = model:GetAttribute("TrainEndsAt")
	local locked = model:GetAttribute("State") == "Locked"
	local data = ClientData.Get()
	local now = workspace:GetServerTimeNow()
	local timers = data and data.Timers or {}
	local running = if endsAt then timers["Build_" .. openPlotId] elseif trainEndsAt then timers["Train_" .. openPlotId] else nil

	-- Header: green, or blue for training buildings
	local colors = if def.Trains then HEADER_BLUE else HEADER_GREEN
	UIStyle.Gradient(win.Header, colors[1], colors[2])
	win.HeaderBase.BackgroundColor3 = colors[2]
	win.Icon.Image = UIStyle.Icon(headerIcon(buildingType, def))
	win.Title.Text = def.DisplayName
	local worker = running and running.Worker or 1
	win.Level.Text = if locked then ("Locked: needs Castle Lv %d"):format(def.UnlockAt)
		elseif endsAt then ("%s · worker %d"):format(if level == 0 then "Building" else "Upgrading", worker)
		elseif trainEndsAt then "Training " .. def.Trains
		elseif level == 0 then "Not built"
		else def.Role or (def.Produces and "Produces " .. def.Produces .. " every hour") or ("Trains " .. def.Trains)
	win.LevelChip.Visible = level > 0
	win.LevelChip.Text = if level >= GameConfig.MaxBuildingLevel then ("Lv %d · Max"):format(level) else ("Lv %d"):format(level)

	-- Info: stored resources, troops owned
	local lines = {}
	local rate = model:GetAttribute("ProduceRate")
	if rate then
		local stored, capacity = ProductionController.GetStored(model), model:GetAttribute("ProduceCapacity")
		table.insert(lines, ("Stored %s / %s   ·   %s / hour"):format(formatAmount(stored), formatAmount(capacity), formatAmount(rate)))
	end
	if def.Trains and level > 0 then
		local owned = data and data.Troops and data.Troops[def.Trains] or {}
		local parts = {}
		for tier = 1, #GameConfig.TroopTiers do
			table.insert(parts, ("%s: %d"):format(Art.TroopTiers[tier].Name, owned[tier] or 0))
		end
		table.insert(lines, "Your troops   " .. table.concat(parts, "   "))
	end
	win.Info.Text = table.concat(lines, "\n")
	win.Info.Visible = #lines > 0

	-- Running timer: StartedAt comes from the snapshot, EndsAt from the model (both server times)
	local unlockItems = {}
	win.TimerSection.Visible = running ~= nil
	if running then
		local isTrain = endsAt == nil
		local ends = endsAt or trainEndsAt
		local startsAt = running.StartedAt or now
		if isTrain then
			win.TimerTitle.Text = ("Training %d %s"):format(running.Count or 0, def.Trains)
			win.TimerNote.Text = "Tier " .. (Art.TroopTiers[running.Tier or 1].Name)
		else
			local toLevel = model:GetAttribute("TimerToLevel") or level + 1
			win.TimerTitle.Text = if level == 0 then "Building Lv 1" else ("Lv %d → Lv %d"):format(level, toLevel)
			win.TimerNote.Text = "Builder " .. worker
			unlockItems = unlocksAt(buildingType, def, level, toLevel)
			win.UnlocksTitle.Text = ("Unlocks at Lv %d"):format(toLevel)
		end
		local bar = if isTrain then BAR_TRAIN else BAR_BUILD
		UIStyle.Gradient(win.TimerFill, bar[1], bar[2])
		if now < startsAt then
			win.TimerTime.Text = "Worker on the way · " .. formatTime(ends - startsAt)
			win.TimerFill.Size = UDim2.new(0, 0, 1, 0)
		else
			local left = ends - now
			win.TimerTime.Text = if left > 0 then formatTime(left) .. " left" else "Finishing..."
			win.TimerFill.Size = UDim2.new(math.clamp((now - startsAt) / math.max(1, ends - startsAt), 0, 1), 0, 1, 0)
		end
	end

	-- Build / upgrade (never while upgrading or training; the server refuses it too)
	local action = nil
	if not endsAt and not trainEndsAt and not locked and level < GameConfig.MaxBuildingLevel then
		local toLevel = level + 1
		action = if level == 0 then "Build" else "Upgrade"
		win.UpgradeTitle.Text = if level == 0 then "Build Lv 1" else ("Upgrade to Lv %d"):format(toLevel)
		win.UpgradeTime.Text = "Time " .. formatTime(GameConfig.GetUpgradeSeconds(buildingType, toLevel))
		setStats(buildingType, def, level, toLevel)
		unlockItems = unlocksAt(buildingType, def, level, toLevel)
		win.UnlocksTitle.Text = ("Unlocks at Lv %d"):format(toLevel)

		local reqs, missing = {}, nil
		for _, req in ipairs(GameConfig.GetRequirements(buildingType, toLevel)) do
			local have = highestLevel(data, req.Type)
			local name = ("%s Lv %d"):format(GameConfig.Buildings[req.Type].DisplayName, req.Level)
			if have >= req.Level then
				table.insert(reqs, { "✔", COLOR_GOOD, name, req.Type })
			else
				missing = missing or name
				table.insert(reqs, { "✖", COLOR_BAD, ("%s  (Lv %d)"):format(name, have), req.Type })
			end
		end
		win.ReqSection.Visible = setMarkRows(win.Requirements, reqs)
		local short = setCost(win.UpgradeCost, GameConfig.GetUpgradeCost(buildingType, toLevel), data)
		local note = if missing then "needs " .. missing elseif short then "not enough " .. short else nil
		setButton(win.Confirm, action, note == nil, "Confirm", note)
	end
	win.UpgradeSection.Visible = action ~= nil
	win.CostSection.Visible = action ~= nil
	win.Confirm.Visible = action ~= nil
	if action == nil then
		win.ReqSection.Visible = false
	end
	win.UnlocksSection.Visible = setMarkRows(win.Unlocks, unlockItems)
	openAction = action

	-- Training: one batch at a time, not while upgrading
	local canTrain = def.Trains ~= nil and level > 0 and not endsAt and not trainEndsAt
	win.TrainSection.Visible = canTrain
	if canTrain then
		if GameConfig.TroopTiers[trainTier].UnlockAt > level then
			trainTier, trainCount = 1, nil
		end
		trainMax = GameConfig.GetMaxTrainBatch(level)
		if not trainCount then
			trainCount = trainMax
			for resource, amount in pairs(GameConfig.TroopCost[trainTier]) do
				trainCount = math.min(trainCount, (data and data.Resources[resource] or 0) // amount)
			end
			trainCount = math.max(1, trainCount)
		end
		trainCount = math.clamp(trainCount, 1, trainMax)

		local troopIcon = UIStyle.Icon(def.Trains)
		for tier, tab in ipairs(win.Tiers) do
			local unlockAt = GameConfig.TroopTiers[tier].UnlockAt
			local open = unlockAt <= level
			local chosen = tier == trainTier
			tab.Icon.Image = troopIcon
			tab.Icon.ImageTransparency = if open then 0 else 0.6
			tab.Label.Text = if open then Art.TroopTiers[tier].Name else ("Lv %d"):format(unlockAt)
			tab.Label.TextColor3 = if open then COLOR_TEXT else COLOR_DIM
			tab.Stroke.Color = if chosen then Art.Colors.GoldLight else Art.TroopTiers[tier].Frame
			tab.Stroke.Thickness = if chosen then 3 else 2
			tab.Stroke.Transparency = if open then 0 else 0.6
			tab.Button.BackgroundColor3 = if chosen then Art.TroopTiers[tier].Fill else COLOR_SECTION
		end
		win.Count.Text = ("%d / %d"):format(trainCount, trainMax)
		local fraction = if trainMax > 1 then (trainCount - 1) / (trainMax - 1) else 1
		win.SliderFill.Size = UDim2.new(fraction, 0, 1, 0)
		win.SliderKnob.Position = UDim2.new(fraction, 0, 0.5, 0)
		local short = setCost(win.TrainCost, GameConfig.GetTrainCost(trainTier, trainCount), data)
		local seconds = formatTime(GameConfig.GetTrainSeconds(trainTier, trainCount))
		setButton(win.Train, ("Train %d"):format(trainCount), short == nil, "Train", if short then "not enough " .. short else seconds)
	end
end

local function openWindow(plotId: string)
	if openPlotId ~= plotId then
		setStatus("")
		trainTier, trainCount = 1, nil
		if win.Frame.Visible then
			UIStyle.Nudge(win.Frame) -- another building: show that the window changed
		end
	end
	openPlotId = plotId
	win.Frame.Visible = true
	refreshWindow()
end

-- Requirement "Go": glide to the best plot of that type (highest level, unlocked first) and open it
function goToBuilding(buildingType: string)
	local models = city.Plots:GetChildren()
	local walls = city:FindFirstChild("Walls")
	if walls then
		table.insert(models, walls)
	end
	local best, bestScore = nil, -math.huge
	for _, model in ipairs(models) do
		if model:GetAttribute("BuildingType") == buildingType then
			local score = (model:GetAttribute("Level") or 0) - (if model:GetAttribute("State") == "Locked" then 1000 else 0)
			if score > bestScore then
				best, bestScore = model, score
			end
		end
	end
	if not best then
		setStatus(GameConfig.Buildings[buildingType].DisplayName .. " has no plot yet", true)
		return
	end
	CameraController.PanTo(best:GetPivot().Position)
	openWindow(best:GetAttribute("PlotId"))
end

-- Sends one request; the window stays open and shows the new timer (or the server's reason)
local function request(remote: RemoteFunction, ...)
	if requesting then
		return false
	end
	requesting = true
	setStatus("...")
	local args = table.pack(...)
	local ok, result = pcall(function()
		return remote:InvokeServer(table.unpack(args, 1, args.n))
	end)
	requesting = false
	if ok and type(result) == "table" and result.Ok then
		setStatus("")
		return true
	end
	setStatus(if ok and type(result) == "table" then tostring(result.Error) else "Request failed, try again", true)
	return false
end

local function onConfirm()
	if openPlotId and openAction then
		request(buildingAction, openAction, openPlotId)
		refreshWindow()
	end
end

local function onTrain()
	if openPlotId and win.TrainSection.Visible then
		if request(trainingAction, "Train", openPlotId, trainTier, trainCount) then
			trainCount = nil
		end
		refreshWindow()
	end
end

local function onTierPressed(tier: number)
	local model = openPlotId and findPlotModel(openPlotId)
	local level = model and model:GetAttribute("Level") or 0
	local unlockAt = GameConfig.TroopTiers[tier].UnlockAt
	if unlockAt > level then
		setStatus(("Tier %s unlocks at Lv %d"):format(Art.TroopTiers[tier].Name, unlockAt), true)
		return
	end
	setStatus("")
	trainTier, trainCount = tier, nil
	refreshWindow()
end

local function changeCount(delta: number)
	trainCount = math.clamp((trainCount or 1) + delta, 1, trainMax)
	refreshWindow()
end

-- Slider: the press position picks the count (1 at the left end, the batch max at the right)
local function slideTo(x: number)
	local track = win.Slider
	local fraction = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
	local count = 1 + math.floor(fraction * (trainMax - 1) + 0.5)
	if count ~= trainCount then
		trainCount = count
		refreshWindow()
	end
end

------------------------------------------------------------------------
-- Tapping plots
------------------------------------------------------------------------
local function plotAt(screenPos: Vector2): string?
	local ray = camera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local targets = { city.Plots }
	local walls = city:FindFirstChild("Walls")
	if walls then
		table.insert(targets, walls)
	end
	params.FilterDescendantsInstances = targets
	local result = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
	local inst = result and result.Instance
	while inst and inst ~= city do
		local plotId = inst:GetAttribute("PlotId")
		if plotId then
			return plotId
		end
		inst = inst.Parent
	end
	return nil
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- gameProcessed is not always set for presses on our GUI, so also skip any press on an Active GUI object
local function isOverGui(pos: Vector2): boolean
	for _, obj in ipairs(player.PlayerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)) do
		if obj.Active then
			return true
		end
	end
	return false
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.Touch then
		touches += 1
		if touches > 1 then
			pressCancelled = true -- pinch, not a tap
			return
		end
	end
	if gameProcessed or not isPress(input) then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	if isOverGui(pos) then
		return
	end
	press = input
	pressStart = pos
	pressCancelled = false
end

local function onInputChanged(input: InputObject)
	if not press or pressCancelled then
		return
	end
	local isMyMove = input == press
		or (press.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
	if isMyMove and (Vector2.new(input.Position.X, input.Position.Y) - pressStart).Magnitude >= GameConfig.Camera.DragThreshold then
		pressCancelled = true -- it became a camera drag
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
	if pressCancelled or not CameraController.IsEnabled() or CameraController.GetView() ~= "City" then
		return -- on the kingdom map, MapController handles taps
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	if ProductionController.TryCollectAt(pos) then
		return -- a tap on a collect bubble collects, it does not open the building
	end
	local plotId = plotAt(pos)
	if plotId then
		openWindow(plotId)
	else
		closeWindow()
	end
end

------------------------------------------------------------------------
-- Countdowns on buildings (client only; the server just sets TimerEndsAt)
------------------------------------------------------------------------
local function updateCountdowns()
	local now = workspace:GetServerTimeNow()
	local models = city.Plots:GetChildren()
	local walls = city:FindFirstChild("Walls")
	if walls then
		table.insert(models, walls)
	end
	for _, model in ipairs(models) do
		local endsAt = model:GetAttribute("TimerEndsAt")
		local gui = endsAt and model:FindFirstChild("TimerLabel")
		local label = gui and gui:FindFirstChild("Time")
		if label then
			local startsAt = model:GetAttribute("TimerStartsAt")
			local left = endsAt - now
			if startsAt and now < startsAt then
				label.Text = "On the way"
				BuildingVisuals.SetTimerProgress(gui, 0)
			else
				label.Text = if left > 0 then formatTime(left) else "Finishing..."
				BuildingVisuals.SetTimerProgress(gui, (now - (startsAt or now)) / math.max(1, endsAt - (startsAt or now)))
			end
		end
		local trainEndsAt = model:GetAttribute("TrainEndsAt")
		local trainGui = trainEndsAt and model:FindFirstChild("TrainLabel")
		local trainLabel = trainGui and trainGui:FindFirstChild("Time")
		if trainLabel then
			local left = trainEndsAt - now
			local count = model:GetAttribute("TrainCount") or 0
			trainLabel.Text = if left > 0 then ("%d · %s"):format(count, formatTime(left)) else "Finishing..."
			local trainStartsAt = model:GetAttribute("TrainStartsAt") or now
			BuildingVisuals.SetTimerProgress(trainGui, (now - trainStartsAt) / math.max(1, trainEndsAt - trainStartsAt))
		end
	end
	if openPlotId and not CameraController.IsEnabled() then
		closeWindow() -- exploring in 3D: buildings can't be tapped, so no window
	elseif openPlotId then
		refreshWindow()
	end
end

function BuildingController.Start()
	buildingAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("BuildingAction") :: RemoteFunction
	trainingAction = ReplicatedStorage.Remotes:WaitForChild("TrainingAction") :: RemoteFunction
	city = workspace:WaitForChild("Cities"):WaitForChild("City_" .. player.UserId) :: Model
	city:WaitForChild("Plots")

	createWindow()
	win.Confirm.Activated:Connect(onConfirm)
	win.Close.Activated:Connect(closeWindow)
	win.Train.Activated:Connect(onTrain)
	for tier, tab in ipairs(win.Tiers) do
		tab.Button.Activated:Connect(function()
			onTierPressed(tier)
		end)
	end
	win.Minus.Activated:Connect(function()
		changeCount(-1)
	end)
	win.Plus.Activated:Connect(function()
		changeCount(1)
	end)
	win.Max.Activated:Connect(function()
		trainCount = nil -- the most the player can afford
		refreshWindow()
	end)
	win.Slider.InputBegan:Connect(function(input)
		if isPress(input) then
			sliding = true
			slideTo(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			slideTo(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			sliding = false
		end
	end)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)
	ClientData.Changed:Connect(refreshWindow)

	task.spawn(function()
		while true do
			updateCountdowns()
			task.wait(0.25)
		end
	end)
end

return BuildingController
