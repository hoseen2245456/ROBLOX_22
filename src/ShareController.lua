-- ShareController: sharing map tiles (client). A tag picker for the "Share" button of the map info panel,
-- the "Shared" button + list (Go jumps to the tile), and a chat line for every new share.
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.ShareController (ModuleScript)
-- The server (ShareService) checks every share and writes its text; this only shows it.
-- MapController starts it and shows the "Shared" button only while the map is open.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local UIStyle = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("UIStyle"))

local Cfg = GameConfig.Share

local ShareController = {}

local remote: RemoteFunction
local show: (number, number) -> () = function() end
local listButton: TextButton
local listFrame: Frame
local picker: Frame
local pickerTitle: TextLabel
local pickerStatus: TextLabel
local pickTile = nil -- { X, Y } the picker shares
local toast: Frame -- popup for a new share with a Go button (chat lines can't be clicked)
local toastText: TextLabel
local toastTile = nil -- { X, Y }
local toastToken = 0
local shares = {} -- newest first
local unseen = 0
local timeOffset = 0 -- server time - local time


local Art = GameConfig.Art

-- style: a GameConfig.Art.Buttons name, or a Color3 (tag buttons: a gradient of that color)
local function newButton(parent: Instance, name: string, text: string, size: UDim2, pos: UDim2, style: string | Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.Position = pos
	b.TextSize = 14
	b.Text = text
	b.Parent = parent
	if typeof(style) == "Color3" then
		UIStyle.Button(b, "Neutral")
		UIStyle.Gradient(b, style, style:Lerp(Color3.new(0, 0, 0), 0.4))
		b:FindFirstChildOfClass("UIStroke").Color = style:Lerp(Color3.new(0, 0, 0), 0.65)
	else
		UIStyle.Button(b, style)
	end
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

local function newPanel(hud: ScreenGui, name: string, size: UDim2, pos: UDim2, anchor: Vector2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Active = true
	f.Size = size
	f.Position = pos
	f.AnchorPoint = anchor
	f.Visible = false
	f.Parent = hud
	UIStyle.Panel(f, Art.Colors.Border)
	return f
end

-- Panel title in gold
local function newTitle(parent: Instance, text: string, textSize: number): TextLabel
	local t = newLabel(parent, "Title", text, UDim2.new(1, -60, 0, 26), UDim2.new(0, 12, 0, 8), textSize, "Title")
	t.TextColor3 = Art.Colors.GoldLight
	t.TextTruncate = Enum.TextTruncate.AtEnd
	t.TextWrapped = false
	return t
end

local function ago(at: number): string
	local s = math.max(0, os.time() + timeOffset - at)
	if s < 60 then
		return "just now"
	elseif s < 3600 then
		return ("%dm ago"):format(s // 60)
	end
	return ("%dh ago"):format(s // 3600)
end

local function lineOf(e): string
	return ("[%s] %s (%d, %d) · by %s"):format(e.Tag, e.Label, e.X, e.Y, e.By)
end

local function refreshButton()
	UIStyle.SetBadge(listButton, unseen)
end

local function chatLine(e)
	local text = ("[Map] %s shared %s"):format(e.By, lineOf(e))
	local ok = pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		local general = channels and channels:FindFirstChild("RBXGeneral") :: TextChannel
		if not general then
			error("no TextChatService channel")
		end
		local color = (Cfg.TagColors[e.Tag] or Color3.new(1, 1, 1)):ToHex()
		general:DisplaySystemMessage(('<font color="#%s">%s</font>'):format(color, text))
	end)
	if not ok then
		pcall(StarterGui.SetCore, StarterGui, "ChatMakeSystemMessage", { Text = text, Color = Cfg.TagColors[e.Tag] })
	end
end

local function fillList()
	local scroll = listFrame.Rows
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	if #shares == 0 then
		newLabel(scroll, "Empty", "Nothing shared yet. Tap a tile on the map and press Share.", UDim2.new(1, -8, 0, 40), UDim2.new(), 14, "Body").TextColor3 = Art.Colors.Muted
		return
	end
	for i, e in ipairs(shares) do
		local row = Instance.new("Frame")
		row.Name = "Share"
		row.LayoutOrder = i
		row.Size = UDim2.new(1, -8, 0, 44)
		row.BackgroundColor3 = Art.Colors.Background
		row.Parent = scroll
		UIStyle.Corner(row, UDim.new(0, 8))
		UIStyle.Stroke(row, Color3.fromHex("#2c2f35"), 1)
		local text = newLabel(row, "Text", "", UDim2.new(1, -66, 1, -4), UDim2.new(0, 8, 0, 2), 13, "Body")
		text.RichText = true
		text.TextYAlignment = Enum.TextYAlignment.Center
		text.Text = ('<font color="#%s"><b>%s</b></font> %s (%d, %d)\n<font color="#a59c88">by %s · %s</font>'):format(
			(Cfg.TagColors[e.Tag] or Color3.new(1, 1, 1)):ToHex(), e.Tag, e.Label, e.X, e.Y, e.By, ago(e.At))
		local go = newButton(row, "Go", "Go", UDim2.new(0, 50, 0, 30), UDim2.new(1, -56, 0.5, -15), "Confirm")
		go.Activated:Connect(function()
			listFrame.Visible = false
			show(e.X, e.Y)
		end)
	end
end

local function onShare(e)
	for _, old in ipairs(shares) do
		if old.Id == e.Id then
			return
		end
	end
	table.insert(shares, 1, e)
	while #shares > Cfg.Keep do
		table.remove(shares)
	end
	chatLine(e)
	toastTile = { X = e.X, Y = e.Y }
	toastText.Text = ('<font color="#%s"><b>%s</b></font> %s (%d, %d)\n<font color="#a59c88">shared by %s</font>'):format(
		(Cfg.TagColors[e.Tag] or Color3.new(1, 1, 1)):ToHex(), e.Tag, e.Label, e.X, e.Y, e.By)
	toast.Visible = true
	toastToken += 1
	local token = toastToken
	task.delay(Cfg.PopupSeconds, function()
		if toastToken == token then
			toast.Visible = false
		end
	end)
	if listFrame.Visible then
		fillList()
	else
		unseen += 1
		refreshButton()
	end
end

local function build(hud: ScreenGui)
	for _, name in ipairs({ "MapSharedButton", "MapShared", "SharePicker", "SharePopup" }) do
		local old = hud:FindFirstChild(name, true)
		if old then
			old:Destroy()
		end
	end

	-- "Shared" button (map only) and the list
	listButton = UIStyle.Medallion(UIStyle.SideColumn(hud), "MapSharedButton", "Shared", "Shared")
	listButton.LayoutOrder = 5
	listButton.Visible = false
	listFrame = newPanel(hud, "MapShared", UDim2.new(0, 340, 0, 320), UDim2.new(1, -84, 0, 100), Vector2.new(1, 0))
	UIStyle.Exclusive(listFrame)
	newTitle(listFrame, "Shared Locations", 18)
	local close = newButton(listFrame, "Close", "X", UDim2.new(0, 28, 0, 28), UDim2.new(1, -36, 0, 6), "Danger")
	close.Activated:Connect(function()
		listFrame.Visible = false
	end)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Rows"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, -16, 1, -46)
	scroll.Position = UDim2.new(0, 8, 0, 40)
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.Parent = listFrame
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll
	listButton.Activated:Connect(function()
		listFrame.Visible = not listFrame.Visible
		if listFrame.Visible then
			unseen = 0
			refreshButton()
			fillList()
		end
	end)

	-- Tag picker (opened by the Share button of the map info panel)
	picker = newPanel(hud, "SharePicker", UDim2.new(0, 300, 0, 150), UDim2.new(0.5, 0, 1, -116), Vector2.new(0.5, 1))
	UIStyle.Exclusive(picker)
	pickerTitle = newTitle(picker, "Share", 15)
	local pClose = newButton(picker, "Close", "X", UDim2.new(0, 28, 0, 28), UDim2.new(1, -36, 0, 6), "Danger")
	pClose.Activated:Connect(function()
		picker.Visible = false
	end)
	newLabel(picker, "Hint", "Share with the kingdom as:", UDim2.new(1, -24, 0, 18), UDim2.new(0, 12, 0, 36), 14, "Body").TextColor3 = Art.Colors.Muted
	local w = (300 - 24 - 4 * (#Cfg.Tags - 1)) / #Cfg.Tags
	for i, tag in ipairs(Cfg.Tags) do
		local b = newButton(picker, "Tag_" .. tag, tag, UDim2.new(0, w, 0, 34), UDim2.new(0, 12 + (i - 1) * (w + 4), 0, 60), Cfg.TagColors[tag])
		b.TextSize = 12
		b.Activated:Connect(function()
			if not pickTile or not remote then
				return
			end
			pickerStatus.Text = "Sharing..."
			local ok, result = pcall(remote.InvokeServer, remote, "Share", pickTile.X, pickTile.Y, tag)
			if ok and result and result.Ok then
				picker.Visible = false
			else
				pickerStatus.Text = "Can't share: " .. tostring(ok and result and result.Error or "no answer")
			end
		end)
	end
	pickerStatus = newLabel(picker, "Status", "", UDim2.new(1, -24, 0, 36), UDim2.new(0, 12, 0, 102), 13, "Body")
	pickerStatus.TextColor3 = Art.Status.Loss

	-- New-share popup (top middle, under the resource bar), shown in the city too
	toast = newPanel(hud, "SharePopup", UDim2.new(0, 380, 0, 52), UDim2.new(0.5, 0, 0, 82), Vector2.new(0.5, 0))
	toastText = newLabel(toast, "Text", "", UDim2.new(1, -110, 1, -6), UDim2.new(0, 10, 0, 3), 14, "Body")
	toastText.RichText = true
	toastText.TextYAlignment = Enum.TextYAlignment.Center
	local go = newButton(toast, "Go", "Go", UDim2.new(0, 56, 0, 34), UDim2.new(1, -96, 0.5, -17), "Confirm")
	go.Activated:Connect(function()
		toast.Visible = false
		if toastTile then
			show(toastTile.X, toastTile.Y)
		end
	end)
	local x = newButton(toast, "Close", "X", UDim2.new(0, 28, 0, 28), UDim2.new(1, -34, 0.5, -14), "Danger")
	x.Activated:Connect(function()
		toast.Visible = false
	end)
end

-- Opens the tag picker for tile (x, y); `what` is the tile's title (shown only)
function ShareController.OpenShare(x: number, y: number, what: string)
	pickTile = { X = x, Y = y }
	pickerTitle.Text = ("Share %s (%d, %d)"):format(what, x, y)
	pickerStatus.Text = ""
	picker.Visible = true
end

-- Shows the "Shared" button while the map is open (MapController.SetOpen)
function ShareController.SetMapOpen(open: boolean)
	if listButton then
		listButton.Visible = open
		if not open then
			listFrame.Visible = false
			picker.Visible = false
		end
	end
end

-- onShow(x, y) opens the map on that tile (MapController.ShowTile)
function ShareController.Start(hud: ScreenGui, onShow: (number, number) -> ())
	show = onShow
	build(hud)
	refreshButton()
	task.spawn(function() -- don't hold up the other controllers while the server makes the remotes
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		remote = remotes:WaitForChild("ShareAction") :: RemoteFunction
		remotes:WaitForChild("ShareFeed").OnClientEvent:Connect(onShare)
		local ok, result = pcall(remote.InvokeServer, remote, "Get")
		if ok and result and result.Ok then
			timeOffset = (result.ServerTime or os.time()) - os.time()
			for i = #result.Shares, 1, -1 do -- oldest first, so the newest ends on top
				local e = result.Shares[i]
				local known = false
				for _, old in ipairs(shares) do
					known = known or old.Id == e.Id
				end
				if not known then
					table.insert(shares, 1, e)
				end
			end
		end
	end)
end

return ShareController
