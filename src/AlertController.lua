-- AlertController: the incoming-attack alert (client, docs\art\incoming_attack.html). Works in the city and
-- on the map: red pulsing screen edges, a bar under the resources (attacker, troops, time left, Go, minimize),
-- a list when several attacks come, sounds, and "Under Attack!" when the army arrives.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.AlertController (ModuleScript)
-- Display only: the attacks come from MarchController.GetIncoming() (everyone's marches, fetched every
-- March.ClientRefreshSeconds), and the battle itself is the server's (the defense report comes as usual).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local UIStyle = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("UIStyle"))
local MarchController = require(script.Parent.MarchController)

local Cfg = GameConfig.Alert
local Art = GameConfig.Art
local RED = Color3.fromHex("#c41616")
local LINE = Color3.fromHex("#e8695f")
local BAR_TOP, BAR_BOTTOM = Color3.fromHex("#3a0f0e"), Color3.fromHex("#1b0909")
local LABEL = Color3.fromHex("#f0cfc9")
local NAME = Color3.fromHex("#ff8f84")
local TIME = Color3.fromHex("#ffd27a")
local TIME_URGENT = Color3.fromHex("#ff6b5f")
local BAR_Y = 46 -- under the resource bar
local BAR_H = 58

local AlertController = {}

local player = Players.LocalPlayer
local hud: ScreenGui
local edges: { Frame } = {}
local bar, mini, list, flash -- built in Start
local refs = {} -- named parts of the bar
local minimized = false
local listOpen = false
local heard = {} -- march key -> true once the horn played for it
local watching = {} -- march key -> march, attacks shown that have not arrived yet
local lastDrum = -1
local shown = {} -- current incoming list (soonest first)

local function keyOf(m): string
	return ("%d_%d"):format(m.UserId, m.StartAt)
end

local function clock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return ("%02d:%02d"):format(seconds // 60, seconds % 60)
end

local function play(name: string)
	local s = GameConfig.Sounds[name]
	if not s then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. s.Id
	sound.Volume = s.Volume
	sound.Parent = SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	task.delay(10, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function text(parent: Instance, name: string, value: string, fontKey: string, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Size = UDim2.new(0, 0, 0, size + 2)
	l.Text = value
	UIStyle.Text(l, fontKey, size, color)
	l.Parent = parent
	return l
end

local function hlist(parent: Instance, padding: number): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding)
	layout.Parent = parent
	return layout
end

-- The round red badge with the crossed swords and a gold rim
local function badge(parent: Instance, size: number, order: number): Frame
	local b = Instance.new("Frame")
	b.Name = "Badge"
	b.LayoutOrder = order
	b.Size = UDim2.new(0, size, 0, size)
	b.Parent = parent
	UIStyle.Corner(b, UDim.new(1, 0))
	UIStyle.Gradient(b, Color3.fromHex("#d8463c"), Color3.fromHex("#7a1714"))
	UIStyle.Stroke(b, Art.Colors.GoldLight, 2)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(0.7, 0, 0.7, 0)
	icon.Image = UIStyle.Icon("Attack")
	icon.Parent = b
	return b
end

local function redPanel(frame: GuiObject)
	UIStyle.Gradient(frame, BAR_TOP, BAR_BOTTOM)
	frame.BackgroundTransparency = 0.04
	UIStyle.Stroke(frame, LINE, 2)
end

local function redButton(parent: Instance, name: string, label: string, size: UDim2, order: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.LayoutOrder = order
	b.Size = size
	b.Text = label
	b.TextSize = 17
	b.Parent = parent
	UIStyle.Button(b, "Danger")
	b.FontFace = Art.Fonts.Title
	return b
end

------------------------------------------------------------------------
-- Building
------------------------------------------------------------------------
-- Red glow on the four screen edges (its own ScreenGui over the whole screen, never takes clicks)
local function buildEdges()
	local gui = Instance.new("ScreenGui")
	gui.Name = "AttackEdges"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = player:WaitForChild("PlayerGui")
	local sides = {
		{ "Top", UDim2.new(1, 0, 0.16, 0), UDim2.new(0, 0, 0, 0), 90 },
		{ "Bottom", UDim2.new(1, 0, 0.16, 0), UDim2.new(0, 0, 0.84, 0), -90 },
		{ "Left", UDim2.new(0.1, 0, 1, 0), UDim2.new(0, 0, 0, 0), 0 },
		{ "Right", UDim2.new(0.1, 0, 1, 0), UDim2.new(0.9, 0, 0, 0), 180 },
	}
	for _, s in ipairs(sides) do
		local f = Instance.new("Frame")
		f.Name = s[1]
		f.Size = s[2]
		f.Position = s[3]
		f.BorderSizePixel = 0
		f.BackgroundColor3 = RED
		f.Visible = false
		f.Parent = gui
		local g = Instance.new("UIGradient")
		g.Rotation = s[4] -- solid at the screen edge, clear toward the middle
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.35, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = f
		table.insert(edges, f)
	end

	-- "Under Attack!" on arrival
	flash = Instance.new("Frame")
	flash.Name = "UnderAttack"
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.BackgroundColor3 = Color3.fromHex("#7a0f0c")
	flash.BackgroundTransparency = 1
	flash.Visible = false
	flash.Parent = gui
	local big = text(flash, "Title", "Under Attack!", "Logo", 72, Color3.fromHex("#ffb3aa"))
	big.AnchorPoint = Vector2.new(0.5, 0.5)
	big.Position = UDim2.new(0.5, 0, 0.45, 0)
	big.TextStrokeColor3 = Color3.fromHex("#4a1210")
	big.TextStrokeTransparency = 0
	local sub = text(flash, "Sub", "", "Subtitle", 20, Art.Colors.Text)
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.new(0.5, 0, 0.45, 46)
	sub.TextStrokeTransparency = 0.3
end

local function buildBar()
	bar = Instance.new("Frame")
	bar.Name = "AttackAlert"
	bar.Active = true -- taps on it don't count as taps on the city / map
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, BAR_Y)
	bar.Size = UDim2.new(0, 0, 0, BAR_H)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.Visible = false
	bar.ZIndex = 5
	bar.Parent = hud
	redPanel(bar)
	UIStyle.Corner(bar, UDim.new(0, 10))
	hlist(bar, 12)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 10)
	pad.Parent = bar

	badge(bar, 44, 1)
	local words = Instance.new("Frame")
	words.Name = "Words"
	words.LayoutOrder = 2
	words.BackgroundTransparency = 1
	words.AutomaticSize = Enum.AutomaticSize.X
	words.Size = UDim2.new(0, 0, 1, 0)
	words.Parent = bar
	local v = Instance.new("UIListLayout")
	v.SortOrder = Enum.SortOrder.LayoutOrder
	v.VerticalAlignment = Enum.VerticalAlignment.Center
	v.Parent = words
	text(words, "Title", "INCOMING ATTACK", "Title", 13, Color3.fromHex("#ffb3aa")).LayoutOrder = 1
	refs.Who = text(words, "Who", "", "Subtitle", 16, Art.Colors.Text)
	refs.Who.LayoutOrder = 2
	refs.Who.RichText = true

	local sep = Instance.new("Frame")
	sep.Name = "Sep"
	sep.LayoutOrder = 3
	sep.Size = UDim2.new(0, 2, 0, 38)
	sep.BorderSizePixel = 0
	sep.BackgroundColor3 = LINE
	sep.BackgroundTransparency = 0.6
	sep.Parent = bar

	local function stat(name: string, caption: string, order: number): TextLabel
		local f = Instance.new("Frame")
		f.Name = name
		f.LayoutOrder = order
		f.BackgroundTransparency = 1
		f.AutomaticSize = Enum.AutomaticSize.X
		f.Size = UDim2.new(0, 0, 1, 0)
		f.Parent = bar
		local l = Instance.new("UIListLayout")
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.VerticalAlignment = Enum.VerticalAlignment.Center
		l.HorizontalAlignment = Enum.HorizontalAlignment.Center
		l.Parent = f
		text(f, "Caption", caption, "Number", 11, LABEL).LayoutOrder = 1
		local value = text(f, "Value", "", "Number", 22, Art.Colors.Text)
		value.LayoutOrder = 2
		return value
	end
	refs.Troops = stat("Troops", "TROOPS", 4)
	refs.Time = stat("Time", "ARRIVES IN", 5)

	-- "+2": more attacks, opens the list
	local more = Instance.new("TextButton")
	more.Name = "More"
	more.LayoutOrder = 6
	more.AutoButtonColor = false
	more.Size = UDim2.new(0, 34, 0, 30)
	more.BackgroundColor3 = LINE
	more.Text = "+1"
	more.Visible = false
	UIStyle.Text(more, "Number", 16, BAR_BOTTOM)
	more.Parent = bar
	UIStyle.Corner(more, UDim.new(1, 0))
	more.Activated:Connect(function()
		listOpen = not listOpen
	end)
	refs.More = more

	local go = redButton(bar, "Go", "Go", UDim2.new(0, 64, 0, 40), 7)
	go.Activated:Connect(function()
		local m = shown[1]
		if m then
			AlertController.GoTo(m)
		end
	end)

	local hide = Instance.new("TextButton")
	hide.Name = "Minimize"
	hide.LayoutOrder = 8
	hide.Size = UDim2.new(0, 28, 0, 28)
	hide.BackgroundColor3 = Color3.new(0, 0, 0)
	hide.BackgroundTransparency = 0.6
	hide.Text = "–"
	UIStyle.Text(hide, "Number", 20, LABEL)
	hide.Parent = bar
	UIStyle.Corner(hide, UDim.new(1, 0))
	hide.Activated:Connect(function()
		minimized = true
		listOpen = false
	end)

	-- Minimized: a small capsule with the time; tap = the bar again
	mini = Instance.new("TextButton")
	mini.Name = "AttackAlertMini"
	mini.Active = true
	mini.AutoButtonColor = false
	mini.Text = ""
	mini.AnchorPoint = Vector2.new(0.5, 0)
	mini.Position = UDim2.new(0.5, 0, 0, BAR_Y)
	mini.Size = UDim2.new(0, 0, 0, 36)
	mini.AutomaticSize = Enum.AutomaticSize.X
	mini.Visible = false
	mini.Parent = hud
	redPanel(mini)
	UIStyle.Corner(mini, UDim.new(1, 0))
	hlist(mini, 6)
	local mpad = Instance.new("UIPadding")
	mpad.PaddingLeft, mpad.PaddingRight = UDim.new(0, 3), UDim.new(0, 12)
	mpad.Parent = mini
	badge(mini, 30, 1)
	refs.MiniTime = text(mini, "Time", "", "Number", 18, TIME)
	refs.MiniTime.LayoutOrder = 2
	mini.Activated:Connect(function()
		minimized = false
	end)

	-- Every attack (when more than one): name, troops, time, Go
	list = Instance.new("Frame")
	list.Name = "AttackList"
	list.Active = true
	list.AnchorPoint = Vector2.new(0.5, 0)
	list.Position = UDim2.new(0.5, 0, 0, BAR_Y + BAR_H + 6)
	list.Size = UDim2.new(0, 380, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.Visible = false
	list.Parent = hud
	redPanel(list)
	UIStyle.Corner(list, UDim.new(0, 10))
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, 5)
	l.Parent = list
	local lpad = Instance.new("UIPadding")
	lpad.PaddingLeft, lpad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	lpad.PaddingTop, lpad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	lpad.Parent = list
end

local function listRow(i: number): Frame
	local row = list:FindFirstChild("Row" .. i) :: Frame?
	if row then
		return row
	end
	row = Instance.new("Frame")
	row.Name = "Row" .. i
	row.LayoutOrder = i
	row.Size = UDim2.new(1, 0, 0, 36)
	row.BackgroundColor3 = Color3.new(0, 0, 0)
	row.BackgroundTransparency = 0.65
	row.Parent = list
	UIStyle.Corner(row, UDim.new(0, 7))
	local nm = text(row, "Name", "", "Subtitle", 14, Art.Colors.Text)
	nm.AutomaticSize = Enum.AutomaticSize.None
	nm.Size = UDim2.new(1, -200, 1, 0)
	nm.Position = UDim2.new(0, 10, 0, 0)
	nm.TextXAlignment = Enum.TextXAlignment.Left
	nm.TextTruncate = Enum.TextTruncate.AtEnd
	local count = text(row, "Count", "", "Number", 15, LABEL)
	count.AutomaticSize = Enum.AutomaticSize.None
	count.Size = UDim2.new(0, 60, 1, 0)
	count.Position = UDim2.new(1, -190, 0, 0)
	count.TextXAlignment = Enum.TextXAlignment.Right
	local tm = text(row, "Time", "", "Number", 15, TIME)
	tm.AutomaticSize = Enum.AutomaticSize.None
	tm.Size = UDim2.new(0, 60, 1, 0)
	tm.Position = UDim2.new(1, -124, 0, 0)
	tm.TextXAlignment = Enum.TextXAlignment.Right
	local go = redButton(row, "Go", "Go", UDim2.new(0, 50, 0, 28), 0)
	go.TextSize = 14
	go.Position = UDim2.new(1, -56, 0.5, -14)
	go.Activated:Connect(function()
		local m = shown[i]
		if m then
			AlertController.GoTo(m)
		end
	end)
	return row
end

------------------------------------------------------------------------
-- Every frame
------------------------------------------------------------------------
local function showFlash(m)
	play("AttackClash")
	flash:FindFirstChild("Sub").Text = ("%s has reached your walls"):format(m.Name)
	flash.Visible = true
	flash.BackgroundTransparency = 0.55
	local title = flash:FindFirstChild("Title") :: TextLabel
	local scale = title:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 1.4
	scale.Parent = title
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(flash, TweenInfo.new(Cfg.FlashSeconds), { BackgroundTransparency = 1 }):Play()
	task.delay(Cfg.FlashSeconds, function()
		flash.Visible = false
	end)
end

local function update()
	local now = workspace:GetServerTimeNow()
	local incoming = MarchController.GetIncoming()
	local current = {}
	local live = {}
	for _, m in ipairs(incoming) do
		local key = keyOf(m)
		live[key] = m
		if now < m.ArriveAt then
			table.insert(current, m)
			if not heard[key] then
				heard[key] = true
				minimized = false -- a new attack always shows the full bar
				play("AttackHorn")
				UIStyle.PopIn(bar)
			end
		end
	end
	-- arrived (still in the latest fetch, so not recalled): "Under Attack!" once
	for key, m in pairs(watching) do
		local latest = live[key]
		if not latest then
			watching[key] = nil -- recalled or gone: the bar just disappears
		elseif now >= latest.ArriveAt then
			watching[key] = nil
			showFlash(latest)
		end
	end
	for _, m in ipairs(current) do
		watching[keyOf(m)] = m
	end
	shown = current

	local any = #current > 0
	local first = current[1]
	bar.Visible = any and not minimized
	mini.Visible = any and minimized
	list.Visible = any and not minimized and listOpen and #current > 1
	if not any then
		listOpen = false
		lastDrum = -1
		for _, e in ipairs(edges) do
			e.Visible = false
		end
		return
	end

	local left = first.ArriveAt - now
	local urgent = left <= Cfg.UrgentSeconds
	refs.Who.Text = ('<font color="#%s"><b>%s</b></font> is marching on you'):format(NAME:ToHex(), first.Name)
	refs.Troops.Text = tostring(first.Count)
	refs.Time.Text = clock(left)
	refs.Time.TextColor3 = if urgent then TIME_URGENT else TIME
	refs.MiniTime.Text = clock(left)
	refs.More.Visible = #current > 1
	refs.More.Text = "+" .. (#current - 1)
	if list.Visible then
		for i, m in ipairs(current) do
			local row = listRow(i)
			row:FindFirstChild("Name").Text = m.Name
			row:FindFirstChild("Count").Text = tostring(m.Count)
			row:FindFirstChild("Time").Text = clock(m.ArriveAt - now)
		end
		for _, child in ipairs(list:GetChildren()) do
			local i = tonumber(child.Name:match("^Row(%d+)$"))
			if i and i > #current then
				child:Destroy()
			end
		end
	end

	-- edges: pulse (faster when urgent), or a steady faint glow while minimized
	local strength
	if minimized then
		strength = Cfg.MinimizedEdge
	else
		local period = if urgent then Cfg.UrgentPulse else Cfg.Pulse
		strength = 0.35 + 0.65 * (0.5 - 0.5 * math.cos(now * 2 * math.pi / period))
	end
	for _, e in ipairs(edges) do
		e.Visible = true
		e.BackgroundTransparency = 1 - strength
	end
	local stroke = bar:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0.6 * (1 - strength)
	end

	-- a drum beat each second of the last DrumSeconds
	local second = math.ceil(left)
	if left <= Cfg.DrumSeconds and second ~= lastDrum and second > 0 then
		lastDrum = second
		play("AttackDrum")
	end
end

------------------------------------------------------------------------
-- API
------------------------------------------------------------------------
-- Opens the map on the attacking army (where it is now) and selects that tile
function AlertController.GoTo(m)
	listOpen = false
	local x, y = MarchController.TileNow(m)
	require(script.Parent.MapController).ShowTile(x, y)
end

function AlertController.Start()
	hud = player:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
	for _, name in ipairs({ "AttackAlert", "AttackAlertMini", "AttackList" }) do
		local old = hud:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	local oldEdges = player.PlayerGui:FindFirstChild("AttackEdges")
	if oldEdges then
		oldEdges:Destroy()
	end
	buildEdges()
	buildBar()

	-- the map's tile-coordinate chip sits where the bar is: push it under the bar while an attack shows
	local coordBase = nil
	RunService.RenderStepped:Connect(function()
		update()
		local coord = hud:FindFirstChild("MapCoord")
		if coord then
			coordBase = coordBase or coord.Position
			local covered = bar.Visible or mini.Visible
			local below = (if bar.Visible then BAR_H else 36) + (if list.Visible then list.AbsoluteSize.Y + 6 else 0) + 6
			coord.Position = if covered then UDim2.new(0.5, 0, 0, BAR_Y + below) else coordBase
		end
	end)
end

return AlertController
