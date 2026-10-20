-- MarchController: armies on the kingdom map (client). The "send army" panel, the list of your armies
-- (with Recall), and the march lines and army icons.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.MarchController (ModuleScript)
-- The server owns every march (MarchService). Your own marches come from ClientData (data.Marches),
-- everyone else's from "MarchAction" "GetMarches". Icons are placed every frame from the march times
-- (StartAt, ArriveAt, ReturnAt, Turn); nothing is moved by the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local KingdomMapGen = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("KingdomMapGen"))
local MapVisuals = require(ReplicatedStorage.Modules:WaitForChild("MapVisuals"))
local UIStyle = require(ReplicatedStorage.Modules:WaitForChild("UIStyle"))
local ClientData = require(script.Parent.ClientData)

local Cfg = GameConfig.March
local COLOR_SECTION = GameConfig.Art.Colors.Background
local COLOR_SECTION_LINE = Color3.fromHex("#2c2f35")
local COLOR_WELL = Color3.fromHex("#0d0f12")

local MarchController = {}

local player = Players.LocalPlayer
local hud: ScreenGui
local sendPanel -- { Frame, Header, HeaderBase, Target, Rows = {type = {Have, Count, Track, Fill, Knob}}, Total, Time, Status, Send }
local listFrame: Frame
local listHead: TextLabel
local chosen = {} -- troop type -> count picked in the send panel
local slidingType: string? = nil -- troop row being dragged
local mapOpen = false
local folder: Folder? = nil
local others = {} -- marches of other players (last fetch)
local drawn = {} -- key -> { Line, Icon, March, Turn }
local target = nil -- { X, Y } of the open send panel
local sending = false

local function remote(): RemoteFunction
	return ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MarchAction") :: RemoteFunction
end

local function clock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

local function label(parent: Instance, name: string, text: string, fontKey: string, size: number, box: UDim2, pos: UDim2): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = box
	l.Position = pos
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.Text = text
	UIStyle.Text(l, fontKey, size)
	l.Parent = parent
	return l
end

-- style: a GameConfig.Art.Buttons name
local function button(parent: Instance, name: string, text: string, style: string, size: UDim2, pos: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.Position = pos
	b.TextSize = 15
	b.Text = text
	b.Parent = parent
	UIStyle.Button(b, style)
	return b
end

------------------------------------------------------------------------
-- Where an army is now (0 = at home, 1 = at the target)
------------------------------------------------------------------------
local function progress(m, now: number): number
	if now < m.ArriveAt then
		return math.clamp((now - m.StartAt) / math.max(1, m.ArriveAt - m.StartAt), 0, 1)
	end
	local back = math.clamp((now - m.ArriveAt) / math.max(1, m.ReturnAt - m.ArriveAt), 0, 1)
	return (m.Turn or 1) * (1 - back)
end

local function worldAt(m, alpha: number): Vector3
	local a = KingdomMapGen.TileToWorld(m.From.X, m.From.Y)
	local b = KingdomMapGen.TileToWorld(m.To.X, m.To.Y)
	return a:Lerp(b, alpha)
end

local function myMarches()
	local list = {}
	local snapshot = ClientData.Get()
	for _, m in pairs(snapshot and snapshot.Marches or {}) do
		table.insert(list, m)
	end
	table.sort(list, function(a, b)
		return a.StartAt < b.StartAt
	end)
	return list
end

------------------------------------------------------------------------
-- Drawing (lines + icons in workspace.KingdomMap.Marches)
------------------------------------------------------------------------
local function marchKey(userId: number, m): string
	return ("%d_%d_%d_%d"):format(userId, m.StartAt, m.To.X, m.To.Y)
end

local function clearDrawn(key: string)
	local d = drawn[key]
	if d then
		d.Line:Destroy()
		d.Icon:Destroy()
		drawn[key] = nil
	end
end

-- The path of a drawn march: out (From -> turn point), or back home once it arrived (turn point -> From,
-- paler). An attack heading at your castle pulses red.
local function buildLine(d, now: number)
	local m = d.March
	local endX = m.From.X + (m.To.X - m.From.X) * d.Turn
	local endY = m.From.Y + (m.To.Y - m.From.Y) * d.Turn
	d.Back = now >= m.ArriveAt
	if d.Back then
		d.Line = MapVisuals.BuildMarchLine(folder :: Folder, endX, endY, m.From.X, m.From.Y, d.Color, "Back")
	else
		d.Line = MapVisuals.BuildMarchLine(folder :: Folder, m.From.X, m.From.Y, endX, endY, d.Color, if d.Incoming then "Incoming" else "Go")
	end
end

local function redraw()
	if not folder then
		return
	end
	local now = workspace:GetServerTimeNow()
	local snapshot = ClientData.Get()
	local home = snapshot and snapshot.MapTile
	local wanted = {}
	local function want(userId: number, m, color: Color3, owner: string?)
		if m.ReturnAt <= now then
			return
		end
		local key = marchKey(userId, m)
		wanted[key] = true
		local d = drawn[key]
		if d and d.Turn ~= (m.Turn or 1) then
			clearDrawn(key) -- recalled: the line gets shorter
			d = nil
		end
		if not d then
			local incoming = owner ~= nil and home ~= nil and m.To.X == home.X and m.To.Y == home.Y
			d = {
				Icon = MapVisuals.BuildArmyIcon(folder :: Folder, m.Count, if incoming then Cfg.IncomingColor else color, owner),
				March = m,
				Turn = m.Turn or 1,
				Incoming = incoming,
				Color = if incoming then Cfg.IncomingColor else color,
			}
			buildLine(d, now)
			drawn[key] = d
		else
			d.March = m
		end
	end
	for _, m in ipairs(myMarches()) do
		want(player.UserId, m, Cfg.MyColor, nil)
	end
	for _, m in ipairs(others) do
		if m.UserId ~= player.UserId then
			want(m.UserId, m, Cfg.EnemyColor, m.Name)
		end
	end
	for key in pairs(drawn) do
		if not wanted[key] then
			clearDrawn(key)
		end
	end
end

local function placeIcons()
	local now = workspace:GetServerTimeNow()
	for key, d in pairs(drawn) do
		local m = d.March
		if now >= m.ReturnAt then
			clearDrawn(key)
		else
			if d.Back ~= (now >= m.ArriveAt) then
				d.Line:Destroy() -- it arrived: the path now points home
				buildLine(d, now)
			end
			-- the squad faces where it is going (the target, or home once it turned back)
			local pos = worldAt(m, progress(m, now))
			local dir = worldAt(m, 1) - worldAt(m, 0)
			if d.Back then
				dir = -dir
			end
			local face = if dir.Magnitude > 0.01 then CFrame.lookAt(pos, pos + dir) else CFrame.new(pos)
			d.Icon:PivotTo(face * CFrame.Angles(0, d.Icon:GetAttribute("FaceYaw") or 0, 0))
		end
	end
end

local fetching = false
local function fetchOthers()
	if fetching then
		return
	end
	fetching = true
	local ok, result = pcall(function()
		return remote():InvokeServer("GetMarches")
	end)
	fetching = false
	if ok and result and result.Ok then
		others = result.Marches
		redraw()
	end
end

------------------------------------------------------------------------
-- Your armies (list on the left of the map, with Recall). ui.html section 3: "Armies 1/2".
------------------------------------------------------------------------
local function targetName(m): string
	if m.Kind == "Castle" then
		return (m.TargetName or "Castle") .. "'s Castle"
	elseif m.Kind == "Monster" or m.Kind == "Resource" then
		local feature = KingdomMapGen.GetFeatureAt(m.To.X, m.To.Y)
		local level = if feature then " Lv " .. feature.Level else ""
		return (if m.Kind == "Monster" then "Monster" else ((feature and feature.Resource or "") .. " Node")) .. level
	end
	return ("X %d · Y %d"):format(m.To.X, m.To.Y)
end

local function makeListRow(m): Frame
	local row = Instance.new("Frame")
	row.Name = m.Id
	row.Size = UDim2.new(1, 0, 0, 34)
	row.BackgroundTransparency = 1
	row.Active = true
	row.Parent = listFrame.Content
	local line = Instance.new("Frame")
	line.Name = "Line"
	line.Size = UDim2.new(1, 0, 0, 1)
	line.BorderSizePixel = 0
	line.BackgroundColor3 = Color3.new(1, 1, 1)
	line.BackgroundTransparency = 0.94
	line.Parent = row
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 0, 0.5, 0)
	icon.Size = UDim2.new(0, 20, 0, 20)
	icon.Image = UIStyle.Icon("March")
	icon.Parent = row
	local text = label(row, "Text", "", "Body", 14, UDim2.new(1, -96, 1, 0), UDim2.new(0, 24, 0, 0))
	text.RichText = true
	text.TextTruncate = Enum.TextTruncate.AtEnd
	text.TextWrapped = false
	local recall = button(row, "Recall", "Recall", "Danger", UDim2.new(0, 64, 0, 26), UDim2.new(1, -64, 0.5, -13))
	recall.TextSize = 13
	recall.Activated:Connect(function()
		recall.Text = "..."
		local ok, result = pcall(function()
			return remote():InvokeServer("Recall", m.Id)
		end)
		if not (ok and result and result.Ok) then
			recall.Text = "Recall"
		end
	end)
	return row
end

local function refreshList()
	local list = myMarches()
	local now = workspace:GetServerTimeNow()
	listFrame.Visible = mapOpen and #list > 0
	if not listFrame.Visible then
		return
	end
	listHead.Text = ("Armies %d/%d"):format(#list, Cfg.MaxMarches)
	local rows = {}
	for _, child in ipairs(listFrame.Content:GetChildren()) do
		if child:IsA("Frame") then
			rows[child.Name] = child
		end
	end
	local mine = "#" .. GameConfig.Art.Status.MyCastle:ToHex()
	for i, m in ipairs(list) do
		local row = rows[m.Id] or makeListRow(m)
		rows[m.Id] = nil
		row.LayoutOrder = i
		local out = now < m.ArriveAt
		local left = if out then m.ArriveAt - now else m.ReturnAt - now
		local text = row:FindFirstChild("Text") :: TextLabel
		text.Text = ('%d %s %s  <font color="%s"><b>%s</b></font>'):format(
			m.Count, if out then "→" else "←", if out then targetName(m) else "Home", mine, clock(left))
		local recall = row:FindFirstChild("Recall") :: TextButton
		recall.Visible = out
		text.Size = UDim2.new(1, if out then -96 else -24, 1, 0)
	end
	for _, old in pairs(rows) do
		old:Destroy()
	end
	-- small screens: sit above the tile panel instead of beside it
	local mapInfo = hud:FindFirstChild("MapInfo") :: Frame?
	local covered = mapInfo and mapInfo.Visible and mapInfo.AbsolutePosition.X < listFrame.AbsolutePosition.X + listFrame.AbsoluteSize.X + 8
	listFrame.Position = UDim2.new(0, 10, 1, if covered then -(mapInfo.AbsoluteSize.Y + 24) else -12)
end

local function buildList()
	listFrame = Instance.new("Frame")
	listFrame.Name = "MarchList"
	listFrame.AnchorPoint = Vector2.new(0, 1)
	listFrame.Position = UDim2.new(0, 10, 1, -12)
	listFrame.Size = UDim2.new(0, 260, 0, 0)
	listFrame.AutomaticSize = Enum.AutomaticSize.Y
	listFrame.Active = true
	listFrame.Visible = false
	listFrame.Parent = hud
	UIStyle.Panel(listFrame)
	-- blue stripe on the left (your armies' color)
	local stripe = Instance.new("Frame")
	stripe.Name = "Stripe"
	stripe.Size = UDim2.new(0, 4, 1, 0)
	stripe.BorderSizePixel = 0
	stripe.BackgroundColor3 = GameConfig.Art.Status.MyCastle
	stripe.Parent = listFrame
	UIStyle.Corner(stripe, UDim.new(0, 2))

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.new(1, 0, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.Parent = listFrame
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = content
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 14), UDim.new(0, 10)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 4)
	pad.Parent = content
	listHead = label(content, "Head", "Armies", "Subtitle", 14, UDim2.new(1, 0, 0, 20), UDim2.new())
	listHead.LayoutOrder = 0
	listHead.TextColor3 = GameConfig.Art.Colors.GoldLight
end

------------------------------------------------------------------------
-- Send panel (ui.html section 3: like the building window, one slider per troop type)
------------------------------------------------------------------------
local function available(troopType: string): number
	local snapshot = ClientData.Get()
	local counts = snapshot and snapshot.Troops and snapshot.Troops[troopType] or {}
	local n = 0
	for _, c in ipairs(counts) do
		n += c
	end
	return n
end

local function readCounts()
	local want, total, army = {}, 0, {}
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		local n = math.clamp(chosen[troopType] or 0, 0, available(troopType))
		want[troopType] = n
		army[troopType] = { n, 0, 0, 0 }
		total += n
	end
	return want, total, army
end

local function marchesOut(): number
	local out = 0
	for _ in pairs((ClientData.Get() or {}).Marches or {}) do
		out += 1
	end
	return out
end

local function updateSendInfo()
	if not target then
		return
	end
	local _, total, army = readCounts()
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		local row = sendPanel.Rows[troopType]
		local have = available(troopType)
		local n = math.min(chosen[troopType] or 0, have)
		local fraction = if have > 0 then n / have else 0
		row.Have.Text = ("%s · have %d"):format(troopType, have)
		row.Count.Text = tostring(n)
		row.Fill.Size = UDim2.new(fraction, 0, 1, 0)
		row.Knob.Position = UDim2.new(fraction, 0, 0.5, 0)
		row.Knob.Visible = have > 0
	end
	local home = (ClientData.Get() or {}).MapTile
	local out = marchesOut()
	sendPanel.Total.Text = ("Troops %d / %d · Armies out %d / %d"):format(total, Cfg.MaxTroops, out, Cfg.MaxMarches)
	sendPanel.Time.Text = if home and total > 0
		then "March " .. clock(GameConfig.GetMarchSeconds(home.X, home.Y, target.X, target.Y, army)) .. " each way"
		else "March --:--"
	local ok = total > 0 and total <= Cfg.MaxTroops and out < Cfg.MaxMarches and not sending
	UIStyle.Button(sendPanel.Send, if ok then (if target.Attack then "Danger" else "Confirm") else "Disabled")
end

-- Sets one troop type's count; the total never goes over the march size
local function setCount(troopType: string, n: number)
	local others = 0
	for _, t in ipairs(GameConfig.TroopTypes) do
		if t ~= troopType then
			others += math.min(chosen[t] or 0, available(t))
		end
	end
	chosen[troopType] = math.clamp(math.floor(n + 0.5), 0, math.min(available(troopType), Cfg.MaxTroops - others))
	updateSendInfo()
end

local function fillMax()
	local room = Cfg.MaxTroops
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		local n = math.min(available(troopType), room)
		room -= n
		chosen[troopType] = n
	end
	updateSendInfo()
end

local function setStatus(text: string)
	sendPanel.Status.Text = text
	sendPanel.Status.Visible = text ~= ""
end

local function doSend()
	if sending or not target then
		return
	end
	local want, total = readCounts()
	if total < 1 then
		setStatus("Pick some troops")
		return
	end
	sending = true
	sendPanel.Send.Text = "Sending..."
	local ok, result = pcall(function()
		return remote():InvokeServer("Send", target.X, target.Y, want)
	end)
	sending = false
	sendPanel.Send.Text = "March"
	if ok and result and result.Ok then
		sendPanel.Frame.Visible = false
		target = nil
	else
		setStatus("Can't send: " .. tostring(ok and result and result.Error or "no answer"))
		updateSendInfo()
	end
end

-- Slider: press or drag on a row's track to pick that troop count (0 at the left, all you have at the right)
local function slideTo(troopType: string, x: number)
	local track = sendPanel.Rows[troopType].Track
	local fraction = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
	setCount(troopType, fraction * available(troopType))
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function makeTroopRow(body: Frame, troopType: string, order: number)
	local row = Instance.new("Frame")
	row.Name = troopType
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, 50)
	row.BackgroundColor3 = COLOR_SECTION
	row.Parent = body
	UIStyle.Corner(row, UDim.new(0, 8))
	UIStyle.Stroke(row, COLOR_SECTION_LINE, 1)

	local box = Instance.new("Frame")
	box.Name = "IconBox"
	box.AnchorPoint = Vector2.new(0, 0.5)
	box.Position = UDim2.new(0, 7, 0.5, 0)
	box.Size = UDim2.new(0, 38, 0, 38)
	box.Parent = row
	UIStyle.Corner(box, UDim.new(0, 8))
	UIStyle.Gradient(box, Color3.fromHex("#3a4049"), GameConfig.Art.Colors.Background)
	UIStyle.Stroke(box, GameConfig.Art.TroopTiers[1].Frame, 2)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(0, 30, 0, 30)
	icon.Image = UIStyle.Icon(troopType)
	icon.Parent = box

	local have = label(row, "Have", "", "Body", 13, UDim2.new(1, -120, 0, 16), UDim2.new(0, 54, 0, 5))
	have.TextColor3 = GameConfig.Art.Colors.Muted
	local count = label(row, "Count", "0", "Number", 18, UDim2.new(0, 56, 1, 0), UDim2.new(1, -64, 0, 0))
	count.TextXAlignment = Enum.TextXAlignment.Right

	local slider = Instance.new("TextButton")
	slider.Name = "Slider"
	slider.Text = ""
	slider.AutoButtonColor = false
	slider.BackgroundTransparency = 1
	slider.Position = UDim2.new(0, 54, 0, 22)
	slider.Size = UDim2.new(1, -130, 0, 22)
	slider.Parent = row
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.5, 0)
	track.Size = UDim2.new(1, 0, 0, 8)
	track.BackgroundColor3 = COLOR_WELL
	track.Parent = slider
	UIStyle.Corner(track, UDim.new(1, 0))
	UIStyle.Stroke(track, Color3.new(0, 0, 0), 1)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Parent = track
	UIStyle.Corner(fill, UDim.new(1, 0))
	UIStyle.Gradient(fill, Color3.fromHex("#2b7fa8"), GameConfig.Art.Status.MyCastle).Rotation = 0
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.Size = UDim2.new(0, 18, 0, 18)
	knob.ZIndex = 2
	knob.Parent = slider
	UIStyle.Corner(knob, UDim.new(1, 0))
	UIStyle.Gradient(knob, Color3.new(1, 1, 1), GameConfig.Art.Colors.Gold)
	UIStyle.Stroke(knob, Color3.fromHex("#6b4c16"), 2)

	slider.InputBegan:Connect(function(input)
		if isPress(input) then
			slidingType = troopType
			slideTo(troopType, input.Position.X)
		end
	end)
	sendPanel.Rows[troopType] = { Have = have, Count = count, Track = track, Fill = fill, Knob = knob }
end

local function buildSendPanel()
	local Art = GameConfig.Art
	local frame = Instance.new("Frame")
	frame.Name = "MarchSend"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.48)
	frame.Size = UDim2.new(0, 360, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Active = true
	frame.Visible = false
	frame.Parent = hud
	UIStyle.Panel(frame, Art.Colors.Border)
	UIStyle.Exclusive(frame, function() -- one panel at a time
		target = nil
	end)
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = frame
	sendPanel = { Frame = frame, Rows = {} }

	-- Header: red for an attack, green otherwise (set in OpenSend)
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0, 58)
	header.Parent = frame
	UIStyle.Corner(header, UDim.new(0, 8))
	local base = Instance.new("Frame")
	base.Name = "Base"
	base.AnchorPoint = Vector2.new(0, 1)
	base.Position = UDim2.new(0, 0, 1, 0)
	base.Size = UDim2.new(1, 0, 0, 10)
	base.BorderSizePixel = 0
	base.Parent = header
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
	box.Position = UDim2.new(0, 10, 0.5, -1)
	box.Size = UDim2.new(0, 40, 0, 40)
	box.ZIndex = 2
	box.Parent = header
	UIStyle.Corner(box, UDim.new(0, 8))
	UIStyle.Gradient(box, Color3.fromHex("#3a4049"), Art.Colors.Background)
	UIStyle.Stroke(box, Art.Colors.Gold, 2)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(0, 30, 0, 30)
	icon.Image = UIStyle.Icon("March")
	icon.ZIndex = 2
	icon.Parent = box
	local title = label(header, "Title", "Send Army", "Title", 17, UDim2.new(1, -110, 0, 22), UDim2.new(0, 60, 0, 8))
	title.ZIndex = 2
	local sub = label(header, "Target", "", "Body", 13, UDim2.new(1, -110, 0, 18), UDim2.new(0, 60, 0, 30))
	sub.TextColor3 = Color3.fromHex("#e8dcc4")
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	sub.ZIndex = 2
	local close = button(header, "Close", "X", "Danger", UDim2.new(0, 30, 0, 30), UDim2.new(1, -40, 0, 12))
	close.ZIndex = 2
	close.Activated:Connect(function()
		frame.Visible = false
		target = nil
	end)
	sendPanel.Header, sendPanel.HeaderBase, sendPanel.Target = header, base, sub

	-- Body: a row per troop type, the totals, the status and the buttons
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.LayoutOrder = 2
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.Parent = frame
	local bodyList = Instance.new("UIListLayout")
	bodyList.SortOrder = Enum.SortOrder.LayoutOrder
	bodyList.Padding = UDim.new(0, 6)
	bodyList.Parent = body
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10)
	pad.Parent = body
	for i, troopType in ipairs(GameConfig.TroopTypes) do
		makeTroopRow(body, troopType, i)
	end

	local order = #GameConfig.TroopTypes
	local summary = Instance.new("Frame")
	summary.Name = "Summary"
	summary.LayoutOrder = order + 1
	summary.BackgroundTransparency = 1
	summary.Size = UDim2.new(1, 0, 0, 38)
	summary.Parent = body
	sendPanel.Total = label(summary, "Total", "", "Number", 14, UDim2.new(1, 0, 0, 18), UDim2.new(0, 2, 0, 0))
	sendPanel.Time = label(summary, "Time", "", "Body", 13, UDim2.new(1, 0, 0, 18), UDim2.new(0, 2, 0, 19))
	sendPanel.Time.TextColor3 = Art.Status.MyCastle

	local status = label(body, "Status", "", "Body", 13, UDim2.new(1, 0, 0, 0), UDim2.new())
	status.LayoutOrder = order + 2
	status.AutomaticSize = Enum.AutomaticSize.Y
	status.TextColor3 = Art.Status.Loss
	status.Visible = false
	sendPanel.Status = status

	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.LayoutOrder = order + 3
	actions.BackgroundTransparency = 1
	actions.Size = UDim2.new(1, 0, 0, 42)
	actions.Parent = body
	local maxButton = button(actions, "Max", "Max", "Neutral", UDim2.new(0, 80, 1, 0), UDim2.new())
	maxButton.Activated:Connect(fillMax)
	sendPanel.Send = button(actions, "Send", "March", "Confirm", UDim2.new(1, -88, 1, 0), UDim2.new(0, 88, 0, 0))
	sendPanel.Send.TextSize = 17
	sendPanel.Send.Activated:Connect(doSend)
end

-- Opens the "send army" panel for tile (x, y). `what` is the name shown under the title; attack = red header and button.
function MarchController.OpenSend(x: number, y: number, what: string, attack: boolean?)
	target = { X = x, Y = y, Attack = attack == true }
	sendPanel.Target.Text = ("→ %s · X %d · Y %d"):format(what, x, y)
	local top, bottom = GameConfig.Art.Colors.GreenLight, GameConfig.Art.Colors.RoyalGreen
	if attack then
		top, bottom = Color3.fromHex("#b8433a"), Color3.fromHex("#6e1d1a")
	end
	UIStyle.Gradient(sendPanel.Header, top, bottom)
	sendPanel.HeaderBase.BackgroundColor3 = bottom
	setStatus("")
	fillMax()
	sendPanel.Frame.Visible = true
end

function MarchController.GetMyMarchCount(): number
	return #myMarches()
end

-- Other players' armies on the way to your castle (not recalled), soonest first. AlertController drops
-- the ones that already arrived.
function MarchController.GetIncoming()
	local home = (ClientData.Get() or {}).MapTile
	local list = {}
	if not home then
		return list
	end
	for _, m in ipairs(others) do
		if m.UserId ~= player.UserId and m.To.X == home.X and m.To.Y == home.Y and (m.Turn or 1) >= 1 then
			table.insert(list, m)
		end
	end
	table.sort(list, function(a, b)
		return a.ArriveAt < b.ArriveAt
	end)
	return list
end

-- The tile an army is on now
function MarchController.TileNow(m): (number, number)
	local alpha = progress(m, workspace:GetServerTimeNow())
	return math.floor(m.From.X + (m.To.X - m.From.X) * alpha + 0.5), math.floor(m.From.Y + (m.To.Y - m.From.Y) * alpha + 0.5)
end

-- Ask for everyone's marches now (instead of waiting for the next ClientRefreshSeconds)
MarchController.Refresh = function()
	task.spawn(fetchOthers)
end

-- Called by MapController when the map opens/closes. `world` = workspace.KingdomMap.
function MarchController.SetMapOpen(open: boolean, world: Instance?)
	mapOpen = open
	if open and world and not folder then
		folder = Instance.new("Folder")
		folder.Name = "Marches"
		folder.Parent = world
	end
	if not open then
		sendPanel.Frame.Visible = false
		target = nil
	else
		redraw()
		task.spawn(fetchOthers)
	end
	refreshList()
end

function MarchController.Start()
	hud = player:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
	for _, name in ipairs({ "MarchSend", "MarchList" }) do
		local old = hud:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	buildSendPanel()
	buildList()

	ClientData.Changed:Connect(function()
		if mapOpen then
			redraw()
			refreshList()
		end
		if target then
			updateSendInfo()
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if slidingType and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			slideTo(slidingType, input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			slidingType = nil
		end
	end)

	local sinceList = 0
	RunService.RenderStepped:Connect(function(dt)
		if not mapOpen then
			return
		end
		placeIcons()
		sinceList += dt
		if sinceList >= 0.25 then
			sinceList = 0
			refreshList()
		end
	end)

	-- Always, not only on the map: the incoming-attack alert (AlertController) needs them in the city too
	task.spawn(function()
		while true do
			task.wait(Cfg.ClientRefreshSeconds)
			fetchOthers()
		end
	end)
end

return MarchController
