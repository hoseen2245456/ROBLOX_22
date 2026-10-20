-- BattleReportController: battle reports (client). A "Reports" button (bottom right) with the list of
-- your last battles, and the report window that replays the fight (both numbers going down) and then
-- shows the losses and the loot. Look: docs\art\ui.html section 4.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.BattleReportController (ModuleScript)
-- The server works out every battle (BattleService) and sends the reports in data.Reports (ClientData).
-- A report that shows up during the session opens by itself.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local UIStyle = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("UIStyle"))
local ClientData = require(script.Parent.ClientData)

local Cfg = GameConfig.Battle
local Art = GameConfig.Art
local C, S = Art.Colors, Art.Status

local BattleReportController = {}

local player = Players.LocalPlayer
local hud: ScreenGui
local listButton: TextButton
local listFrame: Frame
local window -- { Frame, Head, Title, Sub, You, Enemy, Note, Losses, Loot, Report }
local known = nil -- [reportId] = true (nil until the first snapshot)
local fresh = {} -- [reportId] = true: came in this session and not opened yet ("NEW")
local unseen = 0
local timeOffset = 0 -- server time - local time
local playing = 0 -- replay token

local hex = Color3.fromHex
-- Header glow per result (ui.html .vict / .vict.lose), and the list's kind boxes (.rk.w / .l / .d)
local HEAD = { Win = hex("#4a3a12"), Lose = hex("#4a1513"), Plain = C.Panel2 }
local KIND = {
	w = { Back = hex("#173a26"), Border = S.Gain, Icon = "March" },
	l = { Back = hex("#3a1412"), Border = S.Loss, Icon = "March" },
	d = { Back = hex("#10263a"), Border = S.TrainTimer, Icon = "Castle" },
	n = { Back = C.Panel2, Border = C.Muted, Icon = "March" },
}
local LINE = hex("#2c2f35")

local function label(parent: Instance, name: string, text: string, fontKey: string, size: number, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.Text = text
	UIStyle.Text(l, fontKey, size, color)
	l.Parent = parent
	return l
end

local function frame(parent: Instance, name: string, size: UDim2, pos: UDim2?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.Size = size
	f.Position = pos or UDim2.new()
	f.Parent = parent
	return f
end

local function vlist(parent: Instance, padding: number)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

local function pad(parent: Instance, x: number, y: number)
	local p = Instance.new("UIPadding")
	p.PaddingLeft, p.PaddingRight = UDim.new(0, x), UDim.new(0, x)
	p.PaddingTop, p.PaddingBottom = UDim.new(0, y), UDim.new(0, y)
	p.Parent = parent
end

local function panel(name: string, size: UDim2, pos: UDim2, anchor: Vector2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Active = true
	f.Size = size
	f.Position = pos
	f.AnchorPoint = anchor
	f.Visible = false
	f.Parent = hud
	UIStyle.Panel(f, C.GoldDark)
	UIStyle.Exclusive(f) -- one panel at a time
	return f
end

local function button(parent: Instance, name: string, text: string, style: string, size: UDim2, pos: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.Position = pos
	b.Text = text
	b.TextSize = 16
	b.Parent = parent
	UIStyle.Button(b, style)
	return b
end

local function comma(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function ago(at: number): string
	local s = math.max(0, os.time() + timeOffset - at)
	if s < 60 then
		return "just now"
	elseif s < 3600 then
		return ("%d min ago"):format(s // 60)
	elseif s < 86400 then
		return ("%d h ago"):format(s // 3600)
	elseif s < 172800 then
		return "Yesterday"
	end
	return ("%d days ago"):format(s // 86400)
end

local function lootTotal(loot): number
	local total = 0
	for _, resource in ipairs(GameConfig.Resources) do
		total += loot and loot[resource] or 0
	end
	return total
end

-- "w" won, "l" lost, "d" defended, "n" no battle
local function kindOf(report): string
	if report.Note then
		return "n"
	elseif report.Kind == "Defense" then
		return if report.Win then "d" else "l"
	end
	return if report.Win then "w" else "l"
end

local function refreshButton()
	UIStyle.SetBadge(listButton, unseen)
end

------------------------------------------------------------------------
-- Report window
------------------------------------------------------------------------
local function makeSide(parent: Instance, name: string, x: number, top: Color3, bottom: Color3)
	local side = frame(parent, name, UDim2.new(0.42, 0, 1, 0), UDim2.new(x, 0, 0, 0))
	local who = label(side, "Who", name, "Subtitle", 13)
	who.Size = UDim2.new(1, 0, 0, 16)
	who.TextXAlignment = Enum.TextXAlignment.Center
	who.TextTruncate = Enum.TextTruncate.AtEnd
	who.TextWrapped = false
	local big = label(side, "Big", "0", "Number", 24)
	big.Size = UDim2.new(1, 0, 0, 26)
	big.Position = UDim2.new(0, 0, 0, 16)
	big.TextXAlignment = Enum.TextXAlignment.Center
	local track = frame(side, "Track", UDim2.new(1, 0, 0, 8), UDim2.new(0, 0, 0, 46))
	track.BackgroundTransparency = 0
	track.BackgroundColor3 = hex("#0d0f12")
	UIStyle.Corner(track, UDim.new(1, 0))
	UIStyle.Stroke(track, LINE, 1)
	local fill = frame(track, "Fill", UDim2.new(1, 0, 1, 0))
	fill.BackgroundTransparency = 0
	UIStyle.Corner(fill, UDim.new(1, 0))
	UIStyle.Gradient(fill, top, bottom)
	return { Who = who, Big = big, Fill = fill }
end

-- A titled block in the window body (ui.html .sec)
local function section(parent: Instance, name: string, order: number): Frame
	local sec = frame(parent, name, UDim2.new(1, 0, 0, 0))
	sec.AutomaticSize = Enum.AutomaticSize.Y
	sec.LayoutOrder = order
	vlist(sec, 4)
	local title = label(sec, "Title", "", "Subtitle", 13, C.GoldLight)
	title.Size = UDim2.new(1, 0, 0, 18)
	title.LayoutOrder = 0
	return sec
end

local function clearRows(sec: Instance)
	for _, child in ipairs(sec:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "Title" then
			child:Destroy()
		end
	end
end

-- Losses table: rows of { name, value, color? }
local function setRows(sec: Frame, title: string, rows)
	clearRows(sec)
	sec.Title.Text = title
	for i, r in ipairs(rows) do
		local row = frame(sec, "Row", UDim2.new(1, 0, 0, 24))
		row.LayoutOrder = i
		local line = frame(row, "Line", UDim2.new(1, 0, 0, 1))
		line.BackgroundTransparency = 0
		line.BackgroundColor3 = LINE
		line.BorderSizePixel = 0
		local name = label(row, "Name", r[1], "Body", 14)
		name.Size = UDim2.new(0.6, -6, 1, 0)
		name.Position = UDim2.new(0, 6, 0, 0)
		local value = label(row, "Value", r[2], "Number", 14, r[3])
		value.Size = UDim2.new(0.4, -6, 1, 0)
		value.Position = UDim2.new(0.6, 0, 0, 0)
		value.TextXAlignment = Enum.TextXAlignment.Right
	end
end

-- Loot chips (ui.html .loot .ci): sign "+" (green) or "−" (red)
local function setLoot(sec: Frame, title: string, loot, sign: string)
	clearRows(sec)
	sec.Title.Text = title
	local color = if sign == "+" then S.Gain else S.Loss
	local chips = frame(sec, "Chips", UDim2.new(1, 0, 0, 0))
	chips.AutomaticSize = Enum.AutomaticSize.Y
	chips.LayoutOrder = 1
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Wraps = true
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = chips
	local any = false
	for i, resource in ipairs(GameConfig.Resources) do
		local n = loot and loot[resource]
		if n and n > 0 then
			any = true
			local chip = frame(chips, "Chip", UDim2.new(0, 0, 0, 28))
			chip.AutomaticSize = Enum.AutomaticSize.X
			chip.LayoutOrder = i
			chip.BackgroundTransparency = 0
			chip.BackgroundColor3 = hex("#0d0f12")
			UIStyle.Corner(chip, UDim.new(0, 8))
			UIStyle.Stroke(chip, LINE, 1)
			pad(chip, 8, 0)
			local row = Instance.new("UIListLayout")
			row.FillDirection = Enum.FillDirection.Horizontal
			row.VerticalAlignment = Enum.VerticalAlignment.Center
			row.Padding = UDim.new(0, 6)
			row.SortOrder = Enum.SortOrder.LayoutOrder
			row.Parent = chip
			local icon = Instance.new("ImageLabel")
			icon.Name = "Icon"
			icon.BackgroundTransparency = 1
			icon.Size = UDim2.new(0, 22, 0, 22)
			icon.Image = UIStyle.Icon(resource)
			icon.Parent = chip
			local amount = label(chip, "Amount", sign .. comma(n), "Number", 14, color)
			amount.LayoutOrder = 1
			amount.Size = UDim2.new(0, 0, 1, 0)
			amount.AutomaticSize = Enum.AutomaticSize.X
			amount.TextWrapped = false
		end
	end
	if not any then
		chips:Destroy()
		local none = label(sec, "None", if sign == "+" then "No loot" else "Nothing stolen", "Body", 14, C.Muted)
		none.Size = UDim2.new(1, 0, 0, 20)
		none.LayoutOrder = 1
	end
end

local function buildWindow()
	local f = panel("BattleReport", UDim2.new(0, 380, 0, 0), UDim2.new(0.5, 0, 0.5, 0), Vector2.new(0.5, 0.5))
	f.AutomaticSize = Enum.AutomaticSize.Y
	vlist(f, 0)

	-- Header: big Victory / Defeat in the logo font over a glow (ui.html .vict)
	local head = frame(f, "Head", UDim2.new(1, 0, 0, 84))
	head.LayoutOrder = 1
	head.BackgroundTransparency = 0
	UIStyle.Corner(head, UDim.new(0, 8))
	local title = label(head, "Title", "", "Logo", 44, C.GoldLight)
	title.Size = UDim2.new(1, -20, 0, 48)
	title.Position = UDim2.new(0, 10, 0, 8)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextStrokeTransparency = 0.35
	local sub = label(head, "Sub", "", "Body", 13, C.Muted)
	sub.Size = UDim2.new(1, -20, 0, 18)
	sub.Position = UDim2.new(0, 10, 0, 58)
	sub.TextXAlignment = Enum.TextXAlignment.Center
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	sub.TextWrapped = false
	local rule = frame(head, "Line", UDim2.new(1, 0, 0, 2), UDim2.new(0, 0, 1, -2))
	rule.BackgroundTransparency = 0
	rule.BackgroundColor3 = C.GoldDark
	rule.BorderSizePixel = 0

	local body = frame(f, "Body", UDim2.new(1, 0, 0, 0))
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.LayoutOrder = 2
	pad(body, 14, 12)
	vlist(body, 12)

	local vs = frame(body, "Vs", UDim2.new(1, 0, 0, 56))
	vs.LayoutOrder = 1
	local you = makeSide(vs, "Your army", 0, hex("#a6e89f"), C.GreenLight)
	local enemy = makeSide(vs, "Enemy", 0.58, hex("#f2a29a"), C.Crimson)
	local mid = label(vs, "Mid", "vs", "Logo", 26, C.Gold)
	mid.Size = UDim2.new(0.16, 0, 1, 0)
	mid.Position = UDim2.new(0.42, 0, 0, 0)
	mid.TextXAlignment = Enum.TextXAlignment.Center

	local note = label(body, "Note", "", "Body", 14)
	note.Size = UDim2.new(1, 0, 0, 0)
	note.AutomaticSize = Enum.AutomaticSize.Y
	note.LayoutOrder = 2
	local losses = section(body, "Losses", 3)
	local loot = section(body, "Loot", 4)

	local btns = frame(body, "Buttons", UDim2.new(1, 0, 0, 38))
	btns.LayoutOrder = 5
	local replay = button(btns, "Replay", "Replay", "Neutral", UDim2.new(0.5, -5, 1, 0), UDim2.new())
	local ok = button(btns, "Close", "OK", "Primary", UDim2.new(0.5, -5, 1, 0), UDim2.new(0.5, 5, 0, 0))
	ok.Activated:Connect(function()
		playing += 1
		f.Visible = false
	end)
	window = { Frame = f, Head = head, Title = title, Sub = sub, You = you, Enemy = enemy, Note = note,
		Losses = losses, Loot = loot, Report = nil }
	replay.Activated:Connect(function()
		if window.Report then
			BattleReportController.Open(window.Report)
		end
	end)
end

local function setSide(side, n: number, start: number)
	side.Big.Text = comma(n)
	side.Fill.Size = UDim2.new(math.clamp(n / math.max(1, start), 0, 1), 0, 1, 0)
	side.Fill.Visible = n > 0
end

local function setHead(glow: Color3, titleColor: Color3, text: string)
	UIStyle.Gradient(window.Head, glow, C.Panel)
	window.Title.Text = text
	window.Title.TextColor3 = titleColor
end

-- "Victory", "Defeat", "Defended", "Castle Raided" or "No Battle"
function BattleReportController.TitleOf(report): string
	if report.Note then
		return "No Battle"
	elseif report.Kind == "Defense" then
		return if report.Win then "Defended" else "Castle Raided"
	end
	return if report.Win then "Victory" else "Defeat"
end

-- Opens a report and plays its rounds
function BattleReportController.Open(report)
	if listFrame then
		listFrame.Visible = false
	end
	if fresh[report.Id] then
		fresh[report.Id] = nil
	end
	playing += 1
	local token = playing
	window.Report = report
	window.Frame.Visible = true
	setHead(HEAD.Plain, C.Text, "Fighting...")
	local defense = report.Kind == "Defense"
	window.Sub.Text = (if defense then "Attacked by %s · X %d Y %d · %s" else "%s · X %d Y %d · %s")
		:format(report.Defender.Name, report.X, report.Y, ago(report.At))
	window.You.Who.Text = if defense then "Your defenders" else "Your army"
	window.Enemy.Who.Text = report.Defender.Name
	window.Note.Visible = false
	window.Losses.Visible = false
	window.Loot.Visible = false
	local rounds = report.Rounds or {}
	local first = rounds[1] or { report.Attacker.Start, report.Defender.Start }
	setSide(window.You, first[1], first[1])
	setSide(window.Enemy, first[2], first[2])

	task.spawn(function()
		local step = Cfg.ReplaySeconds / math.max(1, #rounds - 1)
		for i = 2, #rounds do
			task.wait(step)
			if playing ~= token then
				return
			end
			setSide(window.You, rounds[i][1], first[1])
			setSide(window.Enemy, rounds[i][2], first[2])
		end
		task.wait(0.3)
		if playing ~= token then
			return
		end
		local a, d = report.Attacker, report.Defender
		local title = BattleReportController.TitleOf(report)
		if report.Note then
			setHead(HEAD.Plain, C.Muted, title)
			window.Note.Text = ("No battle: %s.\nYour army of %s came home."):format(report.Note, comma(a.Start))
			window.Note.Visible = true
			return
		end
		if report.Win then
			setHead(HEAD.Win, C.GoldLight, title)
		else
			setHead(HEAD.Lose, S.Loss, title)
		end
		setRows(window.Losses, if defense then "Your defenders" else "Your losses", {
			{ if defense then "Defended" else "Sent", comma(a.Start) },
			{ "Left", comma(a.Left), S.Gain },
			{ if defense then "Wounded (healed)" else "Wounded (came home)", comma(a.Wounded), S.BuildTimer },
			{ "Dead", comma(a.Dead), S.Loss },
			{ "Enemy lost", ("%s / %s"):format(comma(d.Lost), comma(d.Start)) },
		})
		if defense then
			setLoot(window.Loot, "Stolen from you", report.Stolen, "−")
		else
			setLoot(window.Loot, "Loot", report.Loot, "+")
		end
		window.Losses.Visible = true
		window.Loot.Visible = true
	end)
end

------------------------------------------------------------------------
-- Report list (ui.html .rlist)
------------------------------------------------------------------------
local function buildList()
	listFrame = panel("ReportList", UDim2.new(0, 340, 0, 380), UDim2.new(1, -10, 1, -84), Vector2.new(1, 1)) -- above the Reports medallion
	local head = frame(listFrame, "Header", UDim2.new(1, 0, 0, 66))
	head.BackgroundTransparency = 0
	UIStyle.Corner(head, UDim.new(0, 8))
	UIStyle.Gradient(head, hex("#2f6247"), hex("#1d3d2d"))
	local rule = frame(head, "Line", UDim2.new(1, 0, 0, 2), UDim2.new(0, 0, 1, -2))
	rule.BackgroundTransparency = 0
	rule.BackgroundColor3 = C.GoldDark
	rule.BorderSizePixel = 0
	local box = frame(head, "IconBox", UDim2.new(0, 46, 0, 46), UDim2.new(0, 10, 0, 9))
	box.BackgroundTransparency = 0
	UIStyle.Corner(box, UDim.new(0, 10))
	UIStyle.Gradient(box, hex("#3a4049"), C.Background)
	UIStyle.Stroke(box, C.Gold, 2)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(0, 34, 0, 34)
	icon.Image = UIStyle.Icon("Reports")
	icon.Parent = box
	local title = label(head, "Title", "Reports", "Title", 18)
	title.Size = UDim2.new(1, -120, 0, 24)
	title.Position = UDim2.new(0, 66, 0, 12)
	local sub = label(head, "Sub", ("Last %d"):format(20), "Body", 13, C.Muted)
	sub.Size = UDim2.new(1, -120, 0, 16)
	sub.Position = UDim2.new(0, 66, 0, 36)
	local close = button(head, "Close", "✕", "Danger", UDim2.new(0, 30, 0, 30), UDim2.new(1, -40, 0, 18))
	close.Activated:Connect(function()
		listFrame.Visible = false
	end)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Rows"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, -8, 1, -74)
	scroll.Position = UDim2.new(0, 4, 0, 70)
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = C.Gold
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.Parent = listFrame
	vlist(scroll, 0)
end

local function rowSub(report): string
	local when = ago(report.At)
	if report.Note then
		return ("%s · %s"):format(when, report.Note)
	elseif report.Kind == "Defense" then
		local stolen = lootTotal(report.Stolen)
		return ("%s · %s"):format(when, if stolen > 0 then "−" .. comma(stolen) .. " stolen" else "nothing stolen")
	end
	local loot = lootTotal(report.Loot)
	return ("%s · %s"):format(when, if loot > 0 then "+" .. comma(loot) .. " loot" else "no loot")
end

local function fillList()
	local scroll = listFrame.Rows
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local snapshot = ClientData.Get()
	local reports = snapshot and snapshot.Reports or {}
	if #reports == 0 then
		local empty = label(scroll, "Empty", "No battles yet. Send an army to a monster or a castle on the map.", "Body", 14, C.Muted)
		empty.Size = UDim2.new(1, -16, 0, 44)
		empty.Position = UDim2.new(0, 8, 0, 0)
		return
	end
	for i, report in ipairs(reports) do
		local kind = KIND[kindOf(report)]
		local row = Instance.new("TextButton")
		row.Name = "Report"
		row.LayoutOrder = i
		row.Size = UDim2.new(1, -8, 0, 56)
		row.BackgroundTransparency = 1
		row.AutoButtonColor = false
		row.Text = ""
		row.Parent = scroll
		if i < #reports then
			local line = frame(row, "Line", UDim2.new(1, -16, 0, 1), UDim2.new(0, 8, 1, -1))
			line.BackgroundTransparency = 0
			line.BackgroundColor3 = LINE
			line.BorderSizePixel = 0
		end
		local box = frame(row, "Kind", UDim2.new(0, 40, 0, 40), UDim2.new(0, 8, 0, 8))
		box.BackgroundTransparency = 0
		box.BackgroundColor3 = kind.Back
		UIStyle.Corner(box, UDim.new(0, 10))
		UIStyle.Stroke(box, kind.Border, 2)
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.new(0.5, 0, 0.5, 0)
		icon.Size = UDim2.new(0, 28, 0, 28)
		icon.Image = UIStyle.Icon(kind.Icon)
		icon.Parent = box
		local isNew = fresh[report.Id]
		local right = if isNew then 104 else 64
		local title = label(row, "Title", ("%s · %s"):format(BattleReportController.TitleOf(report), report.Defender.Name), "Subtitle", 13)
		title.Size = UDim2.new(1, -right, 0, 18)
		title.Position = UDim2.new(0, 58, 0, 9)
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.TextWrapped = false
		local sub = label(row, "Sub", rowSub(report), "Body", 12, C.Muted)
		sub.Size = UDim2.new(1, -right, 0, 16)
		sub.Position = UDim2.new(0, 58, 0, 29)
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		sub.TextWrapped = false
		if isNew then
			local pill = label(row, "New", "NEW", "Number", 11, Color3.new(1, 1, 1))
			pill.BackgroundTransparency = 0
			pill.BackgroundColor3 = C.Crimson
			pill.TextXAlignment = Enum.TextXAlignment.Center
			pill.AnchorPoint = Vector2.new(1, 0.5)
			pill.Size = UDim2.new(0, 38, 0, 18)
			pill.Position = UDim2.new(1, -8, 0.5, 0)
			UIStyle.Corner(pill, UDim.new(1, 0))
		end
		row.Activated:Connect(function()
			BattleReportController.Open(report)
		end)
	end
end

------------------------------------------------------------------------
-- New reports
------------------------------------------------------------------------
local function onChanged(snapshot)
	if snapshot.ServerTime then
		timeOffset = snapshot.ServerTime - os.time()
	end
	local reports = snapshot.Reports or {}
	if not known then
		known = {}
		for _, r in ipairs(reports) do
			known[r.Id] = true
		end
		return
	end
	local newest = nil
	for _, r in ipairs(reports) do
		if not known[r.Id] then
			known[r.Id] = true
			fresh[r.Id] = true
			unseen += 1
			newest = newest or r
		end
	end
	if newest then
		refreshButton()
		BattleReportController.Open(newest)
	end
end

function BattleReportController.Start()
	hud = player:WaitForChild("PlayerGui"):WaitForChild("MainHUD") :: ScreenGui
	for _, name in ipairs({ "ReportsButton", "ReportList", "BattleReport" }) do
		local old = hud:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	listButton = UIStyle.Medallion(hud, "ReportsButton", "Reports", "Reports")
	listButton.AnchorPoint = Vector2.new(1, 1)
	listButton.Position = UDim2.new(1, -8, 1, -8)
	buildList()
	buildWindow()
	refreshButton()
	listButton.Activated:Connect(function()
		listFrame.Visible = not listFrame.Visible
		if listFrame.Visible then
			unseen = 0
			refreshButton()
			fillList()
		end
	end)

	local snapshot = ClientData.Get()
	if snapshot then
		onChanged(snapshot)
	end
	ClientData.Changed:Connect(onChanged)
end

return BattleReportController
