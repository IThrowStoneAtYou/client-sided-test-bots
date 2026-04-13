-->>>>>>>>>>>>
-- MATCH_HUD
-- Version 2.0.0
--
-- Layout (matches screenshot):
--   - Timer centered ABOVE the bar
--   - Flag icon (left) | gold bar [tickets] | navy bar [tickets] | Flag icon (right)
--   - Both flag icons use asset id: 13488010851
-->>>>>>>>>>>>

local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")

local FLAG_IMG  = "rbxassetid://13488010851"
local BAR_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

-- Team 1 = gold/amber side (left)
local TEAM1_BAR_COLOR = Color3.fromRGB(196, 148, 18)
-- Team 2 = dark navy side (right)
local TEAM2_BAR_COLOR = Color3.fromRGB(28, 42, 90)

local MatchHUD = {}
MatchHUD.__index = MatchHUD

function MatchHUD.new()
	local self = setmetatable({}, MatchHUD)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name           = "MatchHUD"
	gui.ResetOnSpawn   = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.Parent         = playerGui
	self._gui = gui

	self:_build()
	return self
end

function MatchHUD:_build()

	-- ── Outer wrapper: centered at top ────────────────────────────────
	-- Holds both the timer label and the bar row, stacked vertically
	local wrapper = Instance.new("Frame")
	wrapper.Name                   = "MatchWrapper"
	wrapper.Size                   = UDim2.new(0, 500, 0, 52)
	wrapper.Position               = UDim2.new(0.5, 0, 0, 10)
	wrapper.AnchorPoint            = Vector2.new(0.5, 0)
	wrapper.BackgroundTransparency = 1
	wrapper.ZIndex                 = 20
	wrapper.Parent                 = self._gui

	-- ── Timer label (above the bar) ───────────────────────────────────
	local timer = Instance.new("TextLabel")
	timer.Name                  = "Timer"
	timer.Size                  = UDim2.new(1, 0, 0, 22)
	timer.Position              = UDim2.new(0, 0, 0, 0)
	timer.BackgroundTransparency = 1
	timer.Text                  = "25:00"
	timer.TextColor3            = Color3.fromRGB(220, 220, 220)
	timer.Font                  = Enum.Font.GothamBold
	timer.TextSize              = 18
	timer.TextXAlignment        = Enum.TextXAlignment.Center
	timer.ZIndex                = 21
	timer.Parent                = wrapper

	-- ── Bar row: flag | bar | flag ────────────────────────────────────
	local row = Instance.new("Frame")
	row.Name                   = "BarRow"
	row.Size                   = UDim2.new(1, 0, 0, 28)
	row.Position               = UDim2.new(0, 0, 0, 24)
	row.BackgroundTransparency = 1
	row.ZIndex                 = 20
	row.Parent                 = wrapper

	-- Left flag icon
	local flagSize = 28
	local flagL = Instance.new("ImageLabel")
	flagL.Name                 = "FlagLeft"
	flagL.Size                 = UDim2.new(0, 47, 0, 47)
	flagL.Position             = UDim2.new(0.132, -3, 0.339, -22)
	flagL.AnchorPoint          = Vector2.new(0, 0)
	flagL.BackgroundColor3     = Color3.fromRGB(22, 22, 34)
	flagL.BackgroundTransparency = 0.1
	flagL.Image                = FLAG_IMG
	flagL.ScaleType            = Enum.ScaleType.Fit
	flagL.ZIndex               = 25
	flagL.Parent               = row

	local flagLCorner = Instance.new("UICorner")
	flagLCorner.CornerRadius = UDim.new(1, 0)
	flagLCorner.Parent = flagL

	local flagLStroke = Instance.new("UIStroke")
	flagLStroke.Color        = Color3.fromRGB(140, 110, 50)
	flagLStroke.Thickness    = 1.5
	flagLStroke.Transparency = 0.2
	flagLStroke.Parent       = flagL

	-- Right flag icon
	local flagR = Instance.new("ImageLabel")
	flagR.Name                 = "FlagRight"
	flagR.Size                 = UDim2.new(0, 47, 0, 47)
	flagR.Position             = UDim2.new(0.132, 328, 0.339, -22)
	flagR.AnchorPoint          = Vector2.new(0, 0)
	flagR.BackgroundColor3     = Color3.fromRGB(22, 22, 34)
	flagR.BackgroundTransparency = 0.1
	flagR.Image                = FLAG_IMG
	flagR.ScaleType            = Enum.ScaleType.Fit
	flagR.ZIndex               = 25
	flagR.Parent               = row

	local flagRCorner = Instance.new("UICorner")
	flagRCorner.CornerRadius = UDim.new(1, 0)
	flagRCorner.Parent = flagR

	local flagRStroke = Instance.new("UIStroke")
	flagRStroke.Color        = Color3.fromRGB(140, 110, 50)
	flagRStroke.Thickness    = 1.5
	flagRStroke.Transparency = 0.2
	flagRStroke.Parent       = flagR

	-- Split bar background (sits between the two flags)
	local barGap = flagSize + 4   -- pixels between flag edge and bar edge
	local barBg = Instance.new("Frame")
	barBg.Name                   = "BarBg"
	barBg.Size                   = UDim2.new(0.706, -64, 0.75, 0)
	barBg.Position               = UDim2.new(0, 107, 0, 0)
	barBg.BackgroundColor3       = Color3.fromRGB(12, 12, 20)
	barBg.BackgroundTransparency = 0.05
	barBg.BorderSizePixel        = 0
	barBg.ZIndex                 = 21
	barBg.ClipsDescendants       = true
	barBg.Parent                 = row

	local barBgStroke = Instance.new("UIStroke")
	barBgStroke.Color        = Color3.fromRGB(60, 60, 80)
	barBgStroke.Thickness    = 1
	barBgStroke.Transparency = 0.4
	barBgStroke.Parent       = barBg

	-- Gold bar — grows from left
	local goldBar = Instance.new("Frame")
	goldBar.Name                   = "GoldBar"
	goldBar.Size                   = UDim2.new(0.5, 0, 1, 0)
	goldBar.Position               = UDim2.new(0, 0, 0, 0)
	goldBar.AnchorPoint            = Vector2.new(0, 0)
	goldBar.BackgroundColor3       = TEAM1_BAR_COLOR
	goldBar.BackgroundTransparency = 0
	goldBar.BorderSizePixel        = 0
	goldBar.ZIndex                 = 22
	goldBar.Parent                 = barBg

	-- Gold bar ticket label (centered on left half)
	local goldLabel = Instance.new("TextLabel")
	goldLabel.Name                  = "GoldLabel"
	goldLabel.Size                  = UDim2.new(1, 0, 1, 0)
	goldLabel.BackgroundTransparency = 1
	goldLabel.Text                  = "10,000"
	goldLabel.TextColor3            = Color3.fromRGB(255, 255, 255)
	goldLabel.Font                  = Enum.Font.GothamBold
	goldLabel.TextSize              = 12
	goldLabel.TextXAlignment        = Enum.TextXAlignment.Center
	goldLabel.ZIndex                = 23
	goldLabel.Parent                = goldBar

	-- Navy bar — retreats from right
	local navyBar = Instance.new("Frame")
	navyBar.Name                   = "NavyBar"
	navyBar.Size                   = UDim2.new(0.5, 0, 1, 0)
	navyBar.Position               = UDim2.new(1, 0, 0, 0)
	navyBar.AnchorPoint            = Vector2.new(1, 0)
	navyBar.BackgroundColor3       = TEAM2_BAR_COLOR
	navyBar.BackgroundTransparency = 0
	navyBar.BorderSizePixel        = 0
	navyBar.ZIndex                 = 22
	navyBar.Parent                 = barBg

	-- Navy bar ticket label (centered on right half)
	local navyLabel = Instance.new("TextLabel")
	navyLabel.Name                  = "NavyLabel"
	navyLabel.Size                  = UDim2.new(1, 0, 1, 0)
	navyLabel.BackgroundTransparency = 1
	navyLabel.Text                  = "10,000"
	navyLabel.TextColor3            = Color3.fromRGB(200, 215, 255)
	navyLabel.Font                  = Enum.Font.GothamBold
	navyLabel.TextSize              = 12
	navyLabel.TextXAlignment        = Enum.TextXAlignment.Center
	navyLabel.ZIndex                = 23
	navyLabel.Parent                = navyBar

	-- Center seam divider
	local seam = Instance.new("Frame")
	seam.Name                   = "Seam"
	seam.Size                   = UDim2.new(0, 2, 1, 4)
	seam.Position               = UDim2.new(0.5, -1, 0, -2)
	seam.BackgroundColor3       = Color3.fromRGB(255, 255, 255)
	seam.BackgroundTransparency = 0.5
	seam.BorderSizePixel        = 0
	seam.ZIndex                 = 24
	seam.Parent                 = barBg

	-- Store references
	self._timer     = timer
	self._goldBar   = goldBar
	self._navyBar   = navyBar
	self._goldLabel = goldLabel
	self._navyLabel = navyLabel
end

-- ── Helpers ───────────────────────────────────────────────────────────

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

-- ── Public API ────────────────────────────────────────────────────────

function MatchHUD:update(t1: number, t2: number, timeRemaining: number)
	local fmt1 = fmtTickets(t1)
	local fmt2 = fmtTickets(t2)

	self._goldLabel.Text = fmt1
	self._navyLabel.Text = fmt2
	self._timer.Text     = fmtTime(timeRemaining)
	self._timer.TextColor3 = Color3.fromRGB(220, 220, 220)

	local total = t1 + t2
	local ratio = total > 0 and math.clamp(t1 / total, 0, 1) or 0.5

	TweenService:Create(self._goldBar, BAR_TWEEN, { Size = UDim2.new(ratio,     0, 1, 0) }):Play()
	TweenService:Create(self._navyBar, BAR_TWEEN, { Size = UDim2.new(1 - ratio, 0, 1, 0) }):Play()
end

function MatchHUD:showIntermission(secondsLeft: number)
	self._timer.Text       = "INTERMISSION  " .. fmtTime(secondsLeft)
	self._timer.TextColor3 = Color3.fromRGB(200, 200, 100)
end

function MatchHUD:showResult(winner: number, t1: number, t2: number)
	self:update(t1, t2, 0)
	if winner == 0 then
		self._timer.Text       = "DRAW"
		self._timer.TextColor3 = Color3.fromRGB(200, 200, 200)
	elseif winner == 1 then
		self._timer.Text       = "TEAM I WINS"
		self._timer.TextColor3 = Color3.fromRGB(210, 160, 35)
	else
		self._timer.Text       = "TEAM II WINS"
		self._timer.TextColor3 = Color3.fromRGB(130, 160, 255)
	end
end

function MatchHUD:setTimerOnly(secs: number)
	self._timer.Text       = fmtTime(secs)
	self._timer.TextColor3 = Color3.fromRGB(220, 220, 220)
end

function MatchHUD:setIntermissionTimer(secs: number)
	self._timer.Text       = "INTERMISSION  " .. fmtTime(secs)
	self._timer.TextColor3 = Color3.fromRGB(200, 200, 100)
end

return MatchHUD
