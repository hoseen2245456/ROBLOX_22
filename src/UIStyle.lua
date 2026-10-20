-- UIStyle: shared look for every HUD piece (docs\art\ui.html). Colors, fonts and icons come from GameConfig.Art.
-- Location in Studio: ReplicatedStorage.Modules.UIStyle (ModuleScript). Client only (builds GUI, no game logic).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))

local Art = GameConfig.Art
local UIStyle = {}

local DISC_DARK = { Color3.fromHex("#3a4049"), Color3.fromHex("#1d2128") }
local DISC_GOLD = { Color3.fromHex("#ffe9a3"), Color3.fromHex("#c08f30") }

function UIStyle.Icon(key: string): string
	return Art.Icons[key] or ""
end

function UIStyle.Corner(parent: Instance, radius: UDim?)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UDim.new(0, Art.ButtonCorner)
	c.Parent = parent
	return c
end

function UIStyle.Stroke(parent: Instance, color: Color3, thickness: number?)
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = color
	s.Thickness = thickness or Art.ButtonStroke
	s.Parent = parent
	return s
end

-- Vertical gradient from top to bottom (BackgroundColor3 must be white for exact colors)
function UIStyle.Gradient(parent: GuiObject, top: Color3, bottom: Color3)
	parent.BackgroundColor3 = Color3.new(1, 1, 1)
	local g = parent:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = parent
	return g
end

-- Dark window/panel background with a thin border (adds no children, so it is safe with a UIListLayout)
function UIStyle.Panel(frame: GuiObject, border: Color3?)
	UIStyle.Gradient(frame, Art.Colors.Panel, Art.Colors.Background)
	frame.BackgroundTransparency = 0.08
	UIStyle.Corner(frame, UDim.new(0, 8))
	UIStyle.Stroke(frame, border or Color3.new(0, 0, 0), 1.5)
end

function UIStyle.Text(label: TextLabel | TextButton, fontKey: string, size: number, color: Color3?)
	label.FontFace = Art.Fonts[fontKey] or Art.Fonts.Body
	label.TextSize = size
	label.TextColor3 = color or Art.Colors.Text
end

-- A UIGradient also tints its object's own text, so a gradient button shows its text through a child
-- TextLabel "Label" that copies button.Text (callers keep writing button.Text / TextSize as usual).
local LABEL_PROPS = { "Text", "RichText", "FontFace", "TextSize", "TextWrapped" }
local function buttonLabel(button: TextButton): TextLabel
	local label = button:FindFirstChild("Label")
	if label then
		return label
	end
	label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Parent = button
	local function copy()
		for _, prop in ipairs(LABEL_PROPS) do
			label[prop] = button[prop]
		end
	end
	for _, prop in ipairs(LABEL_PROPS) do
		button:GetPropertyChangedSignal(prop):Connect(copy)
	end
	copy()
	button.TextTransparency = 1
	return label
end

-- Paints a TextButton with a GameConfig.Art.Buttons style ("Primary", "Confirm", "Danger", "Neutral", "Disabled", "Train")
function UIStyle.Button(button: TextButton, styleName: string)
	local style = Art.Buttons[styleName] or Art.Buttons.Neutral
	button.AutoButtonColor = false
	button.BackgroundTransparency = 0
	UIStyle.Gradient(button, style.Top, style.Bottom)
	if not button:FindFirstChildOfClass("UICorner") then
		UIStyle.Corner(button)
	end
	local stroke = button:FindFirstChildOfClass("UIStroke") or UIStyle.Stroke(button, style.Stroke)
	stroke.Color = style.Stroke
	button.FontFace = Art.Fonts.Number
	button.TextColor3 = style.Text
	buttonLabel(button).TextColor3 = style.Text
end

-- Round gold-rimmed button with an icon and a label under it (ui.html: medallions). Returns a TextButton:
-- its Text is the label, so existing code can keep writing button.Text. Children: Disc.Icon, Disc.Dot (badge).
function UIStyle.Medallion(parent: Instance, name: string, iconKey: string, label: string, gold: boolean?): TextButton
	local m = Art.Medallion
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Size = UDim2.new(0, m.Size + 12, 0, m.Size + m.Label + 2)
	button.Text = label
	button.FontFace = Art.Fonts.Number
	button.TextSize = 13
	button.TextColor3 = Art.Colors.GoldLight
	button.TextStrokeTransparency = 0.2
	button.TextYAlignment = Enum.TextYAlignment.Bottom
	button.Parent = parent

	local disc = Instance.new("Frame")
	disc.Name = "Disc"
	disc.AnchorPoint = Vector2.new(0.5, 0)
	disc.Position = UDim2.new(0.5, 0, 0, 0)
	disc.Size = UDim2.new(0, m.Size, 0, m.Size)
	disc.Parent = button
	UIStyle.Corner(disc, UDim.new(1, 0))
	local colors = if gold then DISC_GOLD else DISC_DARK
	UIStyle.Gradient(disc, colors[1], colors[2])
	disc.BackgroundTransparency = 0
	UIStyle.Stroke(disc, if gold then Art.Colors.GoldDark else Art.Colors.Gold, 3)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, 0)
	icon.Size = UDim2.new(0.64, 0, 0.64, 0)
	icon.Image = UIStyle.Icon(iconKey)
	icon.Parent = disc

	local dot = Instance.new("TextLabel")
	dot.Name = "Dot"
	dot.Visible = false
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.new(1, -6, 0, 6)
	dot.Size = UDim2.new(0, 20, 0, 20)
	dot.AutomaticSize = Enum.AutomaticSize.X
	dot.FontFace = Art.Fonts.Number
	dot.TextSize = 13
	dot.TextColor3 = Color3.new(1, 1, 1)
	dot.ZIndex = 3
	dot.Parent = disc
	UIStyle.Corner(dot, UDim.new(1, 0))
	UIStyle.Gradient(dot, Art.Status.Loss, Art.Colors.Crimson)
	UIStyle.Stroke(dot, Color3.fromHex("#4a1210"), 1.5)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 5), UDim.new(0, 5)
	pad.Parent = dot

	-- pressed: the disc moves down a little
	local offset = Art.ButtonPressOffset
	button.MouseButton1Down:Connect(function()
		disc.Position = UDim2.new(0.5, 0, 0, offset)
	end)
	local function release()
		disc.Position = UDim2.new(0.5, 0, 0, 0)
	end
	button.MouseButton1Up:Connect(release)
	button.MouseLeave:Connect(release)
	return button
end

function UIStyle.SetIcon(button: Instance, iconKey: string)
	local icon = button:FindFirstChild("Icon", true)
	if icon and icon:IsA("ImageLabel") then
		icon.Image = UIStyle.Icon(iconKey)
	end
end

-- Red number badge on a medallion (hidden for 0)
function UIStyle.SetBadge(button: Instance, count: number)
	local dot = button:FindFirstChild("Dot", true)
	if dot then
		dot.Visible = count > 0
		dot.Text = if count > 9 then "9+" else tostring(count)
	end
end

------------------------------------------------------------------------
-- Panels: only one open at a time, with a short pop-in
------------------------------------------------------------------------
local TweenService = game:GetService("TweenService")
local POP_IN = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local NUDGE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local exclusive = {} -- [frame] = onClosed callback (or false)

-- Pop-in: the panel grows from 88% (around its AnchorPoint) to full size
function UIStyle.PopIn(frame: GuiObject)
	local scale = frame:FindFirstChild("PopScale") :: UIScale?
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "PopScale"
		scale.Parent = frame
	end
	scale.Scale = 0.88
	TweenService:Create(scale, POP_IN, { Scale = 1 }):Play()
end

-- Same panel, new content (e.g. another building): slides in from the right with a small bounce
function UIStyle.Nudge(frame: GuiObject)
	local base = frame:GetAttribute("NudgeBase") or frame.Position
	frame:SetAttribute("NudgeBase", base)
	frame.Position = base + UDim2.fromOffset(28, 0)
	local tween = TweenService:Create(frame, NUDGE, { Position = base })
	tween.Completed:Once(function()
		frame:SetAttribute("NudgeBase", nil)
	end)
	tween:Play()
	UIStyle.PopIn(frame)
end

-- Registers a window/list: when it opens, every other registered panel closes (onClosed runs for
-- them, so their controller can forget its state), and it pops in. Controllers keep using Visible.
function UIStyle.Exclusive(frame: GuiObject, onClosed: (() -> ())?)
	exclusive[frame] = onClosed or false
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not frame.Visible then
			return
		end
		for other, closed in pairs(exclusive) do
			if other ~= frame and other.Visible then
				other.Visible = false
				if closed then
					closed()
				end
			end
		end
		UIStyle.PopIn(frame)
	end)
	frame.Destroying:Connect(function()
		exclusive[frame] = nil
	end)
end

-- The right-side column (MainHUD.SideButtons): medallions stack by LayoutOrder and hidden ones leave no gap.
-- Orders: Explore 1, Map 2, Home 3, Search 4, Shared 5, Admin 9.
function UIStyle.SideColumn(hud: Instance): Frame
	local column = hud:FindFirstChild("SideButtons")
	if column then
		return column
	end
	column = Instance.new("Frame")
	column.Name = "SideButtons"
	column.AnchorPoint = Vector2.new(1, 0)
	column.Position = UDim2.new(1, -8, 0, 52)
	column.Size = UDim2.new(0, Art.Medallion.Size + 12, 0, 0)
	column.AutomaticSize = Enum.AutomaticSize.Y
	column.BackgroundTransparency = 1
	column.Parent = hud
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, Art.Medallion.Gap)
	layout.Parent = column
	return column
end

return UIStyle
