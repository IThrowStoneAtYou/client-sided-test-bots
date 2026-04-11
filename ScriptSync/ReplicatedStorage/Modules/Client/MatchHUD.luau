-->>>>>>>>>>>>
-- MATCH_HUD
-- Version 1.1.0
-->>>>>>>>>>>>

local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")

local TEAM1_COLOR  = Color3.fromRGB(200, 55, 55)
local TEAM2_COLOR  = Color3.fromRGB(65, 105, 210)
local BAR_TWEEN    = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local MatchHUD = {}
MatchHUD.__index = MatchHUD

function MatchHUD.new()
	local self = setmetatable({}, MatchHUD)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name             = "MatchHUD"
	gui.ResetOnSpawn     = false
	gui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset   = true
	gui.Parent           = playerGui
	self._gui = gui

	self:_build()
	return self
end

function MatchHUD:_build()
	local container = Instance.new("Frame")
	container.Name                   = "MatchContainer"
	container.Size                   = UDim2.new(0, 620, 0, 70)
	container.Position               = UDim2.new(0.5, 0, 0, 10)
	container.AnchorPoint            = Vector2.new(0.5, 0)
	container.BackgroundColor3       = Color3.fromRGB(14, 14, 22)
	container.BackgroundTransparency = 0.15
	container.ZIndex                 = 20
	container.Parent                 = self._gui

	local cStroke = Instance.new("UIStroke")
	cStroke.Color        = Color3.fromRGB(55, 55, 75)
	cStroke.Thickness    = 1.5
	cStroke.Transparency = 0.4
	cStroke.Parent       = container

	-- ── Team 1 (left) ─────────────────────────────────────────────────
	local t1Label = Instance.new("TextLabel")
	t1Label.Name                  = "Team1Label"
	t1Label.Size                  = UDim2.new(0, 145, 0, 20)
	t1Label.Position              = UDim2.new(0, 10, 0, 9)
	t1Label.BackgroundTransparency = 1
	t1Label.Text                  = "TEAM I"
	t1Label.TextColor3            = TEAM1_COLOR
	t1Label.Font                  = Enum.Font.GothamBold
	t1Label.TextSize              = 11
	t1Label.TextXAlignment        = Enum.TextXAlignment.Left
	t1Label.ZIndex                = 21
	t1Label.Parent                = container

	local t1Tickets = Instance.new("TextLabel")
	t1Tickets.Name                  = "Team1Tickets"
	t1Tickets.Size                  = UDim2.new(0, 145, 0, 28)
	t1Tickets.Position              = UDim2.new(0, 10, 0, 30)
	t1Tickets.BackgroundTransparency = 1
	t1Tickets.Text                  = "10,000"
	t1Tickets.TextColor3            = Color3.fromRGB(225, 225, 225)
	t1Tickets.Font                  = Enum.Font.GothamBold
	t1Tickets.TextSize              = 22
	t1Tickets.TextXAlignment        = Enum.TextXAlignment.Left
	t1Tickets.ZIndex                = 21
	t1Tickets.Parent                = container

	-- ── Team 2 (right) ────────────────────────────────────────────────
	local t2Label = Instance.new("TextLabel")
	t2Label.Name                  = "Team2Label"
	t2Label.Size                  = UDim2.new(0, 145, 0, 20)
	t2Label.Position              = UDim2.new(1, -155, 0, 9)
	t2Label.BackgroundTransparency = 1
	t2Label.Text                  = "TEAM II"
	t2Label.TextColor3            = TEAM2_COLOR
	t2Label.Font                  = Enum.Font.GothamBold
	t2Label.TextSize              = 11
	t2Label.TextXAlignment        = Enum.TextXAlignment.Right
	t2Label.ZIndex                = 21
	t2Label.Parent                = container

	local t2Tickets = Instance.new("TextLabel")
	t2Tickets.Name                  = "Team2Tickets"
	t2Tickets.Size                  = UDim2.new(0, 145, 0, 28)
	t2Tickets.Position              = UDim2.new(1, -155, 0, 30)
	t2Tickets.BackgroundTransparency = 1
	t2Tickets.Text                  = "10,000"
	t2Tickets.TextColor3            = Color3.fromRGB(225, 225, 225)
	t2Tickets.Font                  = Enum.Font.GothamBold
	t2Tickets.TextSize              = 22
	t2Tickets.TextXAlignment        = Enum.TextXAlignment.Right
	t2Tickets.ZIndex                = 21
	t2Tickets.Parent                = container

	-- ── Center: bar first, timer below it ─────────────────────────────
	local barBg = Instance.new("Frame")
	barBg.Name                   = "BarBg"
	barBg.Size                   = UDim2.new(0, 280, 0, 20)
	barBg.Position               = UDim2.new(0.5, -140, 0, 10)
	barBg.BackgroundColor3       = Color3.fromRGB(18, 18, 28)
	barBg.BackgroundTransparency = 0.1
	barBg.BorderSizePixel        = 0
	barBg.ZIndex                 = 21
	barBg.Parent                 = container

	local barBgCorner = Instance.new("UICorner")
	barBgCorner.CornerRadius = UDim.new(0, 4)
	barBgCorner.Parent       = barBg

	-- Red — grows from left
	local redBar = Instance.new("Frame")
	redBar.Name                   = "RedBar"
	redBar.Size                   = UDim2.new(0.5, 0, 1, 0)
	redBar.Position               = UDim2.new(0, 0, 0, 0)
	redBar.AnchorPoint            = Vector2.new(0, 0)
	redBar.BackgroundColor3       = TEAM1_COLOR
	redBar.BackgroundTransparency = 0.15
	redBar.BorderSizePixel        = 0
	redBar.ZIndex                 = 22
	redBar.Parent                 = barBg

	local redCorner = Instance.new("UICorner")
	redCorner.CornerRadius = UDim.new(0, 4)
	redCorner.Parent       = redBar

	-- Blue — retreats from right
	local blueBar = Instance.new("Frame")
	blueBar.Name                   = "BlueBar"
	blueBar.Size                   = UDim2.new(0.5, 0, 1, 0)
	blueBar.Position               = UDim2.new(1, 0, 0, 0)
	blueBar.AnchorPoint            = Vector2.new(1, 0)
	blueBar.BackgroundColor3       = TEAM2_COLOR
	blueBar.BackgroundTransparency = 0.15
	blueBar.BorderSizePixel        = 0
	blueBar.ZIndex                 = 22
	blueBar.Parent                 = barBg

	local blueCorner = Instance.new("UICorner")
	blueCorner.CornerRadius = UDim.new(0, 4)
	blueCorner.Parent       = blueBar

	-- Seam
	local seam = Instance.new("Frame")
	seam.Name                   = "Seam"
	seam.Size                   = UDim2.new(0, 2, 1, 6)
	seam.Position               = UDim2.new(0.5, -1, 0, -3)
	seam.BackgroundColor3       = Color3.fromRGB(255, 255, 255)
	seam.BackgroundTransparency = 0.55
	seam.BorderSizePixel        = 0
	seam.ZIndex                 = 23
	seam.Parent                 = barBg

	-- Team ticket numbers centered on the bar
	local t1BarLabel = Instance.new("TextLabel")
	t1BarLabel.Name                  = "T1BarLabel"
	t1BarLabel.Size                  = UDim2.new(0.5, 0, 1, 0)
	t1BarLabel.Position              = UDim2.new(0, 0, 0, 0)
	t1BarLabel.BackgroundTransparency = 1
	t1BarLabel.Text                  = "10,000"
	t1BarLabel.TextColor3            = Color3.fromRGB(255, 255, 255)
	t1BarLabel.Font                  = Enum.Font.GothamBold
	t1BarLabel.TextSize              = 10
	t1BarLabel.TextXAlignment        = Enum.TextXAlignment.Center
	t1BarLabel.ZIndex                = 24
	t1BarLabel.Parent                = barBg

	local t2BarLabel = Instance.new("TextLabel")
	t2BarLabel.Name                  = "T2BarLabel"
	t2BarLabel.Size                  = UDim2.new(0.5, 0, 1, 0)
	t2BarLabel.Position              = UDim2.new(0.5, 0, 0, 0)
	t2BarLabel.BackgroundTransparency = 1
	t2BarLabel.Text                  = "10,000"
	t2BarLabel.TextColor3            = Color3.fromRGB(255, 255, 255)
	t2BarLabel.Font                  = Enum.Font.GothamBold
	t2BarLabel.TextSize              = 10
	t2BarLabel.TextXAlignment        = Enum.TextXAlignment.Center
	t2BarLabel.ZIndex                = 24
	t2BarLabel.Parent                = barBg

	-- Timer below the bar
	local timer = Instance.new("TextLabel")
	timer.Name                  = "Timer"
	timer.Size                  = UDim2.new(0, 120, 0, 18)
	timer.Position              = UDim2.new(0.5, -60, 0, 44)
	timer.BackgroundTransparency = 1
	timer.Text                  = "25:00"
	timer.TextColor3            = Color3.fromRGB(215, 215, 215)
	timer.Font                  = Enum.Font.GothamBold
	timer.TextSize              = 13
	timer.TextXAlignment        = Enum.TextXAlignment.Center
	timer.ZIndex                = 21
	timer.Parent                = container

	self._t1Tickets  = t1Tickets
	self._t2Tickets  = t2Tickets
	self._t1BarLabel = t1BarLabel
	self._t2BarLabel = t2BarLabel
	self._timer      = timer
	self._redBar     = redBar
	self._blueBar    = blueBar
	self._container  = container
end

local function fmtTickets(n: number): string
	local s      = tostring(math.max(0, math.floor(n)))
	local result = ""
	local len    = #s
	for i = 1, len do
		if i > 1 and (len - i + 1) % 3 == 0 then
			result ..= ","
		end
		result ..= s:sub(i, i)
	end
	return result
end

local function fmtTime(secs: number): string
	local s = math.max(0, math.floor(secs))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function MatchHUD:update(t1: number, t2: number, timeRemaining: number)
	local fmt1 = fmtTickets(t1)
	local fmt2 = fmtTickets(t2)

	self._t1Tickets.Text  = fmt1
	self._t2Tickets.Text  = fmt2
	self._t1BarLabel.Text = fmt1
	self._t2BarLabel.Text = fmt2
	self._timer.Text      = fmtTime(timeRemaining)

	local total = t1 + t2
	local ratio = total > 0 and math.clamp(t1 / total, 0, 1) or 0.5

	TweenService:Create(self._redBar,  BAR_TWEEN, { Size = UDim2.new(ratio,     0, 1, 0) }):Play()
	TweenService:Create(self._blueBar, BAR_TWEEN, { Size = UDim2.new(1 - ratio, 0, 1, 0) }):Play()
end

function MatchHUD:showIntermission(secondsLeft: number)
	self._timer.Text       = "INTERMISSION " .. fmtTime(secondsLeft)
	self._timer.TextColor3 = Color3.fromRGB(200, 200, 100)
end

function MatchHUD:showResult(winner: number, t1: number, t2: number)
	self:update(t1, t2, 0)
	if winner == 0 then
		self._timer.Text       = "DRAW"
		self._timer.TextColor3 = Color3.fromRGB(200, 200, 200)
	elseif winner == 1 then
		self._timer.Text       = "TEAM I WINS"
		self._timer.TextColor3 = TEAM1_COLOR
	else
		self._timer.Text       = "TEAM II WINS"
		self._timer.TextColor3 = TEAM2_COLOR
	end
end

return MatchHUD