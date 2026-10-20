-- HUDController: the always-visible HUD (docs\art\ui.html): the player plate (top left), the resource bar
-- (top), the timers list (left) and the Explore medallion (right column, UIStyle.SideColumn).
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.HUDController (ModuleScript)
-- It never sends anything to the server: it reads ClientData snapshots and toggles the camera.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local UIStyle = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("UIStyle"))
local ClientData = require(script.Parent.ClientData)
local CameraController = require(script.Parent.CameraController)

local HUDController = {}

local player = Players.LocalPlayer
local Art = GameConfig.Art

local SHOWN = { "Food", "Wood", "Stone", "Gold", "Gems", "KingsCrystal" }
local TEXT_COLOR = Art.Colors.Text
local GAIN_COLOR = Art.Status.Gain
local LOSS_COLOR = Art.Status.Loss
local CHIP_TOP, CHIP_BOTTOM = Color3.fromHex("#0d0f12"), Color3.fromHex("#181b20")

local chips = {} -- resource -> { Value = TextLabel, Last = number? }
local plate = {} -- Crest, Banner, Level, Name, Power

-- 1234 -> "1,234", 12345 -> "12.3K", 1234567 -> "1.23M"
local function formatAmount(n)
	n = math.floor(n or 0)
	if n >= 1e9 then
		return string.format("%.2fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("%.2fM", n / 1e6)
	elseif n >= 1e4 then
		return string.format("%.1fK", n / 1e3)
	elseif n >= 1000 then
		return string.format("%d,%03d", n // 1000, n % 1000)
	end
	return tostring(n)
end

local function label(parent: Instance, name: string, fontKey: string, size: number, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	UIStyle.Text(l, fontKey, size, color)
	l.Parent = parent
	return l
end

local function image(parent: Instance, name: string, iconKey: string, size: number): ImageLabel
	local i = Instance.new("ImageLabel")
	i.Name = name
	i.BackgroundTransparency = 1
	i.Size = UDim2.new(0, size, 0, size)
	i.Image = UIStyle.Icon(iconKey)
	i.Parent = parent
	return i
end

-- Player plate: civilization crest + castle level, name, power
local function buildPlate(hud)
	local frame = Instance.new("Frame")
	frame.Name = "PlayerPlate"
	frame.Active = true
	frame.Position = UDim2.new(0, 8, 0, 6)
	frame.Size = UDim2.new(0, 168, 0, 40)
	frame.Parent = hud
	UIStyle.Gradient(frame, Art.Colors.Panel2, Color3.fromHex("#1b1f25"))
	UIStyle.Corner(frame, UDim.new(0, 20))
	UIStyle.Stroke(frame, Art.Colors.GoldDark, 2)

	local crest = Instance.new("Frame")
	crest.Name = "Crest"
	crest.Position = UDim2.new(0, -2, 0.5, 0)
	crest.AnchorPoint = Vector2.new(0, 0.5)
	crest.Size = UDim2.new(0, 44, 0, 44)
	crest.Parent = frame
	UIStyle.Corner(crest, UDim.new(1, 0))
	UIStyle.Gradient(crest, Art.Colors.GoldLight, Art.Colors.GoldDark)
	UIStyle.Stroke(crest, Color3.fromHex("#6b4c16"), 2)

	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.new(0.5, 0, 0.45, 0)
	banner.Size = UDim2.new(0, 22, 0, 26)
	banner.BorderSizePixel = 0
	banner.Parent = crest
	UIStyle.Corner(banner, UDim.new(0, 4))
	local trim = Instance.new("UIStroke")
	trim.Thickness = 2
	trim.Parent = banner

	local level = Instance.new("TextLabel")
	level.Name = "Level"
	level.AnchorPoint = Vector2.new(0.5, 0.5)
	level.Position = UDim2.new(0.5, 0, 1, -2)
	level.Size = UDim2.new(0, 34, 0, 14)
	level.Text = "Lv 1"
	UIStyle.Text(level, "Title", 10, Color3.fromHex("#1b1608"))
	level.ZIndex = 2
	level.Parent = crest
	UIStyle.Corner(level, UDim.new(1, 0))
	UIStyle.Gradient(level, Art.Colors.GoldLight, Color3.fromHex("#c08f30"))
	UIStyle.Stroke(level, Color3.fromHex("#6b4c16"), 1)

	local name = label(frame, "PlayerName", "Title", 13)
	name.Position = UDim2.new(0, 48, 0, 3)
	name.Size = UDim2.new(1, -54, 0, 17)
	name.Text = player.DisplayName

	local power = Instance.new("Frame")
	power.Name = "Power"
	power.BackgroundTransparency = 1
	power.Position = UDim2.new(0, 48, 0, 20)
	power.Size = UDim2.new(1, -54, 0, 16)
	power.Parent = frame
	image(power, "Icon", "Power", 15).Position = UDim2.new(0, 0, 0, 0)
	local value = label(power, "Value", "Number", 14, Art.Colors.GoldLight)
	value.Position = UDim2.new(0, 18, 0, 0)
	value.Size = UDim2.new(1, -18, 1, 0)
	value.Text = "0"

	plate = { Banner = banner, Trim = trim, Level = level, Power = value }
end

local function refreshPlate(snapshot)
	if not plate.Banner or not snapshot then
		return
	end
	local colors = Art.Banners[snapshot.Civilization or ""] or Art.Banners.English
	plate.Banner.BackgroundColor3 = colors.Main
	plate.Trim.Color = colors.Trim
	local castle = 1
	for _, b in pairs(snapshot.Buildings or {}) do
		if b.Type == "Castle" then
			castle = b.Level
		end
	end
	plate.Level.Text = "Lv " .. castle
	plate.Power.Text = formatAmount(snapshot.Stats and snapshot.Stats.Power or 0)
end

local function makeChip(parent, resource, order)
	local chip = Instance.new("Frame")
	chip.Name = resource
	chip.LayoutOrder = order
	chip.Size = UDim2.new(1 / #SHOWN, -6, 1, 0)
	chip.Active = true
	chip.Parent = parent
	UIStyle.Gradient(chip, CHIP_TOP, CHIP_BOTTOM)
	chip.BackgroundTransparency = 0.06
	UIStyle.Corner(chip, UDim.new(1, 0))
	UIStyle.Stroke(chip, Art.Colors.Border, 1.5)

	local icon = image(chip, "Icon", resource, 34)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, -4, 0.5, 0)

	local value = label(chip, "Value", "Number", 16)
	value.Position = UDim2.new(0, 30, 0, 0)
	value.Size = UDim2.new(1, -36, 1, 0)
	value.Text = "-"

	chips[resource] = { Value = value, Last = nil }
end

-- Flash the number green (gain) or red (spend), then fade back
local function flash(textLabel, color)
	textLabel.TextColor3 = color
	TweenService:Create(textLabel, TweenInfo.new(0.8), { TextColor3 = TEXT_COLOR }):Play()
end

local function refresh(snapshot)
	local resources = snapshot and snapshot.Resources
	if not resources then
		return
	end
	for resource, chip in pairs(chips) do
		local amount = resources[resource] or 0
		chip.Value.Text = formatAmount(amount)
		if chip.Last and amount ~= chip.Last then
			flash(chip.Value, amount > chip.Last and GAIN_COLOR or LOSS_COLOR)
		end
		chip.Last = amount
	end
	refreshPlate(snapshot)
end

local function buildResourceBar(hud)
	local bar = Instance.new("Frame")
	bar.Name = "ResourceBar"
	bar.Position = UDim2.new(0, 186, 0, 10)
	bar.Size = UDim2.new(1, -196, 0, 30)
	bar.BackgroundTransparency = 1
	bar.Active = true
	bar.Parent = hud

	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(720, 30)
	limit.Parent = bar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = bar

	for i, resource in ipairs(SHOWN) do
		makeChip(bar, resource, i)
	end
end

-- Timers list (left side, under the plate): builders header + one row per running build or training timer.
-- Rows are rebuilt on each snapshot; a light client loop only rewrites the time text and progress bars.
local timerList: Frame? = nil
local hammers: Frame? = nil
local timerRows = {} -- { { Timer = table, Time = TextLabel, Fill = Frame } }
local idleRow: Frame? = nil

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

local function timerTitle(timer): string
	if timer.Kind == "Train" then
		local tier = Art.TroopTiers[timer.Tier or 1]
		return ("%d %s %s"):format(timer.Count or 0, timer.TroopType or "Troops", tier and tier.Name or "")
	end
	local def = GameConfig.Buildings[timer.BuildingType]
	local name = if def then def.DisplayName else tostring(timer.BuildingType)
	return if timer.ToLevel == 1 then "Build " .. name else ("%s → Lv %d"):format(name, timer.ToLevel)
end

local function updateTimerRows()
	local now = workspace:GetServerTimeNow()
	for _, row in ipairs(timerRows) do
		local t = row.Timer
		local total = math.max(1, t.EndsAt - t.StartedAt)
		if now < t.StartedAt then
			row.Time.Text = "On the way"
			row.Fill.Size = UDim2.new(0, 0, 1, 0)
		else
			local left = t.EndsAt - now
			row.Time.Text = if left > 0 then formatTime(left) else "Finishing..."
			row.Fill.Size = UDim2.new(math.clamp((now - t.StartedAt) / total, 0, 1), 0, 1, 0)
		end
	end
end

-- Row shell: colored icon square on the left, title + time on top, optional bar under them
local function makeRowShell(name, order, color, iconKey, faded)
	local row = Instance.new("Frame")
	row.Name = name
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, 32)
	row.BackgroundTransparency = 1
	row.Parent = timerList

	local box = Instance.new("Frame")
	box.Name = "IconBox"
	box.AnchorPoint = Vector2.new(0, 0.5)
	box.Position = UDim2.new(0, 0, 0.5, 0)
	box.Size = UDim2.new(0, 28, 0, 28)
	box.BackgroundColor3 = color:Lerp(Color3.new(0, 0, 0), 0.75)
	box.BackgroundTransparency = if faded then 0.5 else 0
	box.Parent = row
	UIStyle.Corner(box, UDim.new(0, 6))
	UIStyle.Stroke(box, color, 1.5).Transparency = if faded then 0.5 else 0
	local icon = image(box, "Icon", iconKey, 22)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.ImageTransparency = if faded then 0.5 else 0

	local title = label(row, "Title", "Number", 13)
	title.Position = UDim2.new(0, 34, 0, 1)
	title.Size = UDim2.new(0.66, -34, 0, 16)

	local time = label(row, "Time", "Number", 13)
	time.Position = UDim2.new(0.66, 0, 0, 1)
	time.Size = UDim2.new(0.34, 0, 0, 16)
	time.TextXAlignment = Enum.TextXAlignment.Right
	time.Text = ""
	return row, title, time
end

local function makeTimerRow(timer, order)
	local isTrain = timer.Kind == "Train"
	local color = if isTrain then Art.Status.TrainTimer else Art.Status.BuildTimer
	local iconKey = if isTrain then (timer.TroopType or "Infantry") else "Hammer"
	local row, title, time = makeRowShell("Timer", order, color, iconKey, false)
	title.Text = timerTitle(timer)

	local track = Instance.new("Frame")
	track.Name = "Bar"
	track.Position = UDim2.new(0, 34, 0, 21)
	track.Size = UDim2.new(1, -34, 0, 7)
	track.BackgroundColor3 = Color3.fromHex("#0d0f12")
	track.BorderSizePixel = 0
	track.Parent = row
	UIStyle.Corner(track, UDim.new(1, 0))

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BorderSizePixel = 0
	fill.Parent = track
	UIStyle.Corner(fill, UDim.new(1, 0))
	UIStyle.Gradient(fill, color:Lerp(Color3.new(1, 1, 1), 0.3), color:Lerp(Color3.new(0, 0, 0), 0.25))

	table.insert(timerRows, { Timer = timer, Time = time, Fill = fill })
end

local function refreshTimers(snapshot)
	if not timerList or not snapshot or not snapshot.Timers then
		return
	end
	for _, row in ipairs(timerRows) do
		row.Time.Parent:Destroy()
	end
	table.clear(timerRows)
	if idleRow then
		idleRow:Destroy()
		idleRow = nil
	end

	local list, builders = {}, 0
	for _, timer in pairs(snapshot.Timers) do
		if timer.EndsAt and timer.StartedAt then
			table.insert(list, timer)
			if timer.Kind == "Build" then
				builders += 1
			end
		end
	end
	table.sort(list, function(a, b)
		return a.EndsAt < b.EndsAt
	end)
	for i, timer in ipairs(list) do
		makeTimerRow(timer, i + 1)
	end

	local maxBuilders = snapshot.Builders or GameConfig.FreeBuilders
	for _, old in ipairs(hammers:GetChildren()) do
		if old:IsA("Frame") then
			old:Destroy()
		end
	end
	for i = 1, maxBuilders do
		local busy = i <= builders
		local box = Instance.new("Frame")
		box.Name = "Builder" .. i
		box.LayoutOrder = i
		box.Size = UDim2.new(0, 18, 0, 18)
		box.Parent = hammers
		UIStyle.Corner(box, UDim.new(0, 4))
		if busy then
			UIStyle.Gradient(box, Art.Colors.GoldLight, Color3.fromHex("#c08f30"))
		else
			box.BackgroundColor3 = Color3.fromHex("#0d0f12")
		end
		UIStyle.Stroke(box, if busy then Color3.fromHex("#6b4c16") else Art.Colors.Border, 1)
		local icon = image(box, "Icon", "Hammer", 14)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.new(0.5, 0, 0.5, 0)
		icon.ImageTransparency = if busy then 0 else 0.6
	end
	if builders < maxBuilders then
		local row, title = makeRowShell("Idle", #list + 2, Art.Status.BuildTimer, "Hammer", true)
		title.Text = "Idle builder"
		title.TextColor3 = Art.Colors.Muted
		idleRow = row
	end
	updateTimerRows()
end

local function buildTimerList(hud)
	local frame = Instance.new("Frame")
	frame.Name = "TimerList"
	frame.Position = UDim2.new(0, 8, 0, 54)
	frame.Size = UDim2.new(0.3, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Active = true
	frame.Parent = hud
	UIStyle.Panel(frame, Art.Colors.GoldDark)

	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(180, 0)
	limit.MaxSize = Vector2.new(240, math.huge)
	limit.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 8)
	pad.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 3)
	layout.Parent = frame

	local header = Instance.new("Frame")
	header.Name = "Builders"
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0, 20)
	header.BackgroundTransparency = 1
	header.Parent = frame
	local title = label(header, "Title", "Subtitle", 13, Art.Colors.GoldLight)
	title.Size = UDim2.new(0.6, 0, 1, 0)
	title.Text = "Builders"

	local boxes = Instance.new("Frame")
	boxes.Name = "Hammers"
	boxes.AnchorPoint = Vector2.new(1, 0)
	boxes.Position = UDim2.new(1, 0, 0, 1)
	boxes.Size = UDim2.new(0.4, 0, 0, 18)
	boxes.BackgroundTransparency = 1
	boxes.Parent = header
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Right
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 3)
	row.Parent = boxes

	timerList, hammers = frame, boxes
end

-- "Explore" medallion (right column; bottom left is the thumbstick on phones): swaps the top-down city
-- camera for the normal Roblox camera so the player can walk around, and back.
local function buildExploreButton(hud)
	local button = UIStyle.Medallion(UIStyle.SideColumn(hud), "ExploreButton", "Explore", "Explore")
	button.LayoutOrder = 1

	button.Activated:Connect(function()
		local toCity = not CameraController.IsEnabled()
		CameraController.SetEnabled(toCity)
		button.Text = if toCity then "Explore" else "City View"
		UIStyle.SetIcon(button, if toCity then "Explore" else "City")
		local mapButton = hud:FindFirstChild("MapButton", true) -- MapController: no map while walking around
		if mapButton then
			mapButton.Visible = toCity
		end
	end)
end

function HUDController.Start()
	local hud = player:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
	for _, name in ipairs({ "PlayerPlate", "ResourceBar", "TimerList", "SideButtons", "ExploreButton" }) do
		local old = hud:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	buildPlate(hud)
	buildResourceBar(hud)
	buildTimerList(hud)
	buildExploreButton(hud)
	ClientData.Changed:Connect(function(snapshot)
		refresh(snapshot)
		refreshTimers(snapshot)
	end)
	refresh(ClientData.Get())
	refreshTimers(ClientData.Get())

	task.spawn(function()
		while true do
			task.wait(0.25)
			updateTimerRows()
		end
	end)
end

return HUDController
