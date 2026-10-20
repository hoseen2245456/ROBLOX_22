-- AdminController: the admin panel (only shown when the server marks the player "IsAdmin").
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.AdminController (ModuleScript)
-- An "Admin" medallion (last in the right column) opens a scrolling list of buttons in groups; each one
-- asks Remotes.AdminAction. Look: docs\art\ui.html (UIStyle panel + buttons).
-- New game systems should add their buttons to BUTTONS (see roblox_rules).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local UIStyle = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("UIStyle"))

local Art = GameConfig.Art
local player = Players.LocalPlayer

local AdminController = {}

-- { label, action, arg?, style? }. An entry with only a label is a group heading.
local BUTTONS = { { "Resources" } }
for _, amount in ipairs(GameConfig.Admin.ResourceSteps) do
	local text = amount >= 1000000 and (amount / 1000000) .. "M" or (amount / 1000) .. "K"
	table.insert(BUTTONS, { "+" .. text .. " all resources", "AddResources", amount })
end
table.insert(BUTTONS, { "Set resources to 0", "ClearResources" })
table.insert(BUTTONS, { "City" })
table.insert(BUTTONS, { "Finish all timers", "FinishTimers", nil, "Confirm" })
table.insert(BUTTONS, { ("+%d troops (T1, each)"):format(GameConfig.Admin.TroopStep), "AddTroops" })
table.insert(BUTTONS, { "Toggle 2nd builder", "ToggleBuilder" })
table.insert(BUTTONS, { "Looks" })
table.insert(BUTTONS, { "Castle: next look (tier)", "NextCastleTier" })
table.insert(BUTTONS, { "Walls: next look (tier)", "NextWallTier" })
table.insert(BUTTONS, { "Military: next look (tier)", "NextMilitaryTier" })
table.insert(BUTTONS, { "Military: demo training", "DemoTraining" })
table.insert(BUTTONS, { "Civic: next look (tier)", "NextCivicTier" })
table.insert(BUTTONS, { "Plots: demo build (empty)", "DemoBuild", "Build" })
table.insert(BUTTONS, { "Plots: demo upgrade", "DemoBuild", "Upgrade" })
table.insert(BUTTONS, { "Map" })
table.insert(BUTTONS, { "Move castle (random tile)", "MoveCastle" })
table.insert(BUTTONS, { "Reset castle move cooldown", "ResetMoveCooldown" })
table.insert(BUTTONS, { "Bring all armies home", "FinishMarches" })
table.insert(BUTTONS, { "Armies arrive now (battle)", "ArriveMarches", nil, "Train" })
table.insert(BUTTONS, { "Test castle next to me", "SpawnDummy", "Near" })
table.insert(BUTTONS, { "Test castle (random tile)", "SpawnDummy", "Random" })
table.insert(BUTTONS, { "Dummy attacks me (1 min)", "DummyAttack", nil, "Danger" })
table.insert(BUTTONS, { "Danger" })
table.insert(BUTTONS, { "RESET EVERYTHING (press 2x)", "ResetAll", nil, "Danger" })

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

local function build(hud: ScreenGui)
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("AdminAction") :: RemoteFunction

	local toggle = UIStyle.Medallion(UIStyle.SideColumn(hud), "AdminButton", "Admin", "Admin")
	toggle.LayoutOrder = 9 -- last in the right column

	local panel = Instance.new("Frame")
	panel.Name = "AdminPanel"
	panel.Active = true -- taps on it don't count as taps on the city
	panel.Visible = false
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -96, 0, 52)
	panel.Size = UDim2.new(0, 250, 1, -130)
	panel.Parent = hud
	UIStyle.Panel(panel, Art.Colors.GoldDark)
	UIStyle.Exclusive(panel)

	-- Header: icon, title, close
	local head = Instance.new("Frame")
	head.Name = "Header"
	head.Size = UDim2.new(1, 0, 0, 44)
	head.Parent = panel
	UIStyle.Corner(head, UDim.new(0, 8))
	UIStyle.Gradient(head, Color3.fromHex("#24476b"), Color3.fromHex("#162c45"))
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.new(0, 30, 0, 30)
	icon.Position = UDim2.new(0, 8, 0, 7)
	icon.Image = UIStyle.Icon("Admin")
	icon.Parent = head
	local title = label(head, "Title", "Admin", "Title", 17)
	title.Size = UDim2.new(1, -90, 1, 0)
	title.Position = UDim2.new(0, 44, 0, 0)
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Size = UDim2.new(0, 28, 0, 28)
	close.Position = UDim2.new(1, -36, 0, 8)
	close.Text = "✕"
	close.TextSize = 15
	close.Parent = head
	UIStyle.Button(close, "Danger")
	close.Activated:Connect(function()
		panel.Visible = false
	end)

	local status = label(panel, "Status", "Test tools", "Body", 13, Art.Colors.GoldLight)
	status.Size = UDim2.new(1, -20, 0, 34)
	status.Position = UDim2.new(0, 10, 0, 46)
	status.TextYAlignment = Enum.TextYAlignment.Center

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.new(0, 8, 0, 82)
	list.Size = UDim2.new(1, -12, 1, -90)
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = Art.Colors.Gold
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	for i, def in ipairs(BUTTONS) do
		local text, action, arg, style = def[1], def[2], def[3], def[4]
		if not action then
			local heading = label(list, "Group", text:upper(), "Subtitle", 12, Art.Colors.Gold)
			heading.LayoutOrder = i
			heading.Size = UDim2.new(1, -10, 0, 20)
			heading.TextYAlignment = Enum.TextYAlignment.Bottom
			continue
		end
		local b = Instance.new("TextButton")
		b.Name = action .. (arg and tostring(arg) or "")
		b.LayoutOrder = i
		b.Size = UDim2.new(1, -10, 0, 34)
		b.Text = text
		b.TextSize = 14
		b.Parent = list
		UIStyle.Button(b, style or "Neutral")
		b.Activated:Connect(function()
			status.Text = "..."
			local ok, result = pcall(remote.InvokeServer, remote, action, arg)
			if not ok then
				status.Text = "Error: " .. tostring(result)
			elseif result.Ok then
				status.Text = result.Message
				if action == "DummyAttack" then
					require(script.Parent.MarchController).Refresh() -- the alert shows now, not on the next fetch
				end
				if result.Tile then
					require(script.Parent.MapController).ShowTile(result.Tile.X, result.Tile.Y)
				end
			else
				status.Text = "Error: " .. tostring(result.Error)
			end
		end)
	end

	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
end

function AdminController.Start()
	local hud = player:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
	for _, name in ipairs({ "AdminButton", "AdminPanel" }) do
		local old = hud:FindFirstChild(name, true)
		if old then
			old:Destroy()
		end
	end
	if player:GetAttribute("IsAdmin") then
		build(hud)
		return
	end
	player:GetAttributeChangedSignal("IsAdmin"):Once(function()
		if player:GetAttribute("IsAdmin") then
			build(hud)
		end
	end)
end

return AdminController
