-->>>>>>>>>>>>
-- COMPASS_HUD
-- Version 1.0.0
-->>>>>>>>>>>>

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local BG_COLOR    = Color3.fromRGB(14, 14, 22)
local ACCENT_COLOR = Color3.fromRGB(230, 230, 230)
local SUB_COLOR   = Color3.fromRGB(145, 145, 160)

local COMPASS_WIDTH = 242
local COMPASS_HEIGHT = 30
local PIXELS_PER_DEGREE = 2 -- How wide the compass feels
local SMOOTH_TIME = 0.35    -- Snappier glide for better responsiveness

local DIRECTIONS = {
	[0]   = "N",
	[45]  = "NE",
	[90]  = "E",
	[135] = "SE",
	[180] = "S",
	[225] = "SW",
	[270] = "W",
	[315] = "NW",
}

local CompassHUD = {}
CompassHUD.__index = CompassHUD

function CompassHUD.new()
	local self = setmetatable({}, CompassHUD)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "CompassHUD"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	self._gui = gui

	-- Main Container (The Clipping Window)
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, COMPASS_WIDTH, 0, COMPASS_HEIGHT)
	container.Position = UDim2.new(0.5, 0, 0, -40)
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.BackgroundColor3 = BG_COLOR
	container.BackgroundTransparency = 0.5
	container.ClipsDescendants = true
	container.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.8
	stroke.Thickness = 1.5
	stroke.Parent = container

	-- Center Indicator Notch
	local notch = Instance.new("Frame")
	notch.Name = "Notch"
	notch.Size = UDim2.new(0, 2, 0, 10)
	notch.Position = UDim2.new(0.5, 0, 0, 0)
	notch.AnchorPoint = Vector2.new(0.5, 0)
	notch.BackgroundColor3 = Color3.fromRGB(255, 215, 60) -- Gold accent
	notch.BorderSizePixel = 0
	notch.ZIndex = 5
	notch.Parent = container

	-- The Sliding Strip
	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.Size = UDim2.new(0, 0, 1, 0)
	strip.BackgroundTransparency = 1
	strip.Parent = container
	self._strip = strip

	self:_buildMarkers()

	return self
end

function CompassHUD:_buildMarkers()
	-- We build markers for 0-360, plus padding to ensure smooth looping
	-- Total markers covers -180 to 540 to handle wrap-around visuals
	for i = -180, 540, 15 do
		-- Flip the mapping logic so E and W are on the correct sides for non-inverted movement
		local degree = (-i) % 360
		if degree < 0 then degree += 360 end

		local isCardinal = (i % 45 == 0)
		local label = Instance.new("TextLabel")
		label.Name = "Mark_" .. i
		label.Size = UDim2.new(0, 40, 1, 0)
		label.Position = UDim2.new(0, i * PIXELS_PER_DEGREE, 0.5, 0)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.BackgroundTransparency = 1
		
		if isCardinal then
			label.Text = DIRECTIONS[degree] or tostring(degree)
			label.TextColor3 = ACCENT_COLOR
			label.Font = Enum.Font.GothamBold
			label.TextSize = 14
		else
			label.Text = tostring(degree)
			label.TextColor3 = SUB_COLOR
			label.Font = Enum.Font.Gotham
			label.TextSize = 10
		end

		label.Parent = self._strip

		-- Tick mark
		local tick = Instance.new("Frame")
		tick.Size = UDim2.new(0, 1, 0, isCardinal and 8 or 4)
		tick.Position = UDim2.new(0.5, 0, 1, 0)
		tick.AnchorPoint = Vector2.new(0.5, 1)
		tick.BackgroundColor3 = isCardinal and ACCENT_COLOR or SUB_COLOR
		tick.BackgroundTransparency = 0.5
		tick.BorderSizePixel = 0
		tick.Parent = label
	end
end

-->>>>>>>>>>>>
-- Updates the compass position based on the camera LookVector.
-- Call this every frame (RenderStepped).
function CompassHUD:Update(cameraCF: CFrame)
	local look = cameraCF.LookVector
	-- Standardize yaw so that turning Right (East) is positive
	local yaw  = math.atan2(look.X, -look.Z)
	local degrees = math.deg(yaw)

	-- Non-inverted: Positive degree (Right turn) = Positive offset (Slide Right)
	local targetPos = UDim2.new(0.5, (degrees * PIXELS_PER_DEGREE), 0, 0)
	
	TweenService:Create(self._strip, TweenInfo.new(SMOOTH_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Position = targetPos
	}):Play()
end

function CompassHUD:SetVisible(visible: boolean)
	self._gui.Enabled = visible
end

return CompassHUD
