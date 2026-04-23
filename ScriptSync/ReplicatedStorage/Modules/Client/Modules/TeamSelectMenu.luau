-->>>>>>>>>>>>
-- TeamSelectMenu
-- Version 3.0.0
--
-- Firing convention (unchanged from Blink definition):
--   Network.TeamRegimentSelect.Fire(sideIndex: u8, regimentIndex: u8)
--   sideIndex     1 = Attackers (France)   2 = Defenders (Britain)
--   regimentIndex 1-based position in nation.regiments[]
-->>>>>>>>>>>>

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Data ──────────────────────────────────────────────────────────────
local RegimentData = require(ReplicatedStorage.Modules.Shared.RegimentData)
local SIDES = RegimentData.Sides

-- ── Palette ───────────────────────────────────────────────────────────
local C_BG    = Color3.fromRGB(6,   6,   10)
local C_PANEL = Color3.fromRGB(11,  11,  18)
local C_CARD  = Color3.fromRGB(15,  15,  24)
local C_ROW   = Color3.fromRGB(20,  20,  33)
local C_GOLD  = Color3.fromRGB(190, 155, 70)
local C_TEXT  = Color3.fromRGB(215, 210, 195)
local C_DIM   = Color3.fromRGB(110, 108, 100)
local C_SEP   = Color3.fromRGB(38,  38,  58)

-- ── Layout ────────────────────────────────────────────────────────────
local PANEL_W  = 700
local PANEL_H  = 400
local HEADER_H = 54
local NAV_W    = 220
local PAD      = 10

-- Nav card positions (y relative to the content area below header)
local NAT_LABEL_Y = 10
local NAT_CARD_Y  = NAT_LABEL_Y + 20    -- 30
local NAT_CARD_H  = 54
local REG_LABEL_Y = NAT_CARD_Y + NAT_CARD_H + 14   -- 98
local REG_CARD_Y  = REG_LABEL_Y + 20   -- 118
local REG_CARD_H  = 54

-- ── Tweens ────────────────────────────────────────────────────────────
local TI_FAST = TweenInfo.new(0.13, Enum.EasingStyle.Linear)
local TI_MED  = TweenInfo.new(0.20, Enum.EasingStyle.Linear)
local TI_IN   = TweenInfo.new(0.30, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TI_OUT  = TweenInfo.new(0.20, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

local localPlayer = Players.LocalPlayer

-- ── Module ────────────────────────────────────────────────────────────
local TeamSelectMenu = {}
TeamSelectMenu.__index = TeamSelectMenu

function TeamSelectMenu.new(Network, onVisibilityChanged)
	local self = setmetatable({}, TeamSelectMenu)
	self._network             = Network
	self._onVisibilityChanged = onVisibilityChanged
	self._selectedSide        = nil
	self._selectedSideIdx     = nil
	self._selectedNation      = nil
	self._selectedRegiment    = nil
	self._selectedRegimentIdx = nil  -- 1-based, sent as u8 via Blink

	self._camConn      = nil
	self._savedCamType = nil
	self._cameraLockActive = false
	self._rightMode    = "nations"  -- "nations" | "regiments"
	self._natRows      = {}
	self._regRows      = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "TeamSelectMenu"; gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true; gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	self._gui = gui

	self:_buildSideScreen()
	self:_buildLoadoutScreen()

	return self
end

-- ─────────────────────────────────────────────────────────────────────
-- Camera
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_lockCamera()
	local cam = workspace.CurrentCamera
	self._cameraLockActive = true

	-- Prevent saving 'Scriptable' if we're already locked to avoid restore loops
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		self._savedCamType = cam.CameraType
	end

	cam.CameraType = Enum.CameraType.Scriptable
	if self._camConn then self._camConn:Disconnect() end
	self._camConn = RunService.RenderStepped:Connect(function()
		local ref = workspace:FindFirstChild("menu_cam_pos")
		if not ref then return end
		local targetCF = ref:IsA("BasePart") and ref.CFrame or (ref:IsA("CFrameValue") and ref.Value)
		if targetCF then
			workspace.CurrentCamera.CFrame = targetCF
		end
	end)
end

function TeamSelectMenu:_unlockCamera()
	if self._camConn then self._camConn:Disconnect(); self._camConn = nil end
	self._cameraLockActive = false

	-- Return to Custom immediately to allow the engine to start its default behavior
	workspace.CurrentCamera.CameraType = Enum.CameraType.Custom

	-- Use task.spawn to wait for the character to respawn (triggered by the Team change)
	task.spawn(function()
		local char = localPlayer.Character
		-- If character is missing or dead, wait for the new one to arrive
		if not char or not char:FindFirstChild("Humanoid") or char.Humanoid.Health <= 0 then
			char = localPlayer.CharacterAdded:Wait()
		end
		local hum = char:WaitForChild("Humanoid", 5)

		-- Ensure we haven't locked the camera again (e.g. re-opened the menu) while waiting
		if hum and not self._cameraLockActive then
			workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
			workspace.CurrentCamera.CameraSubject = hum
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────
-- Side Selection Screen
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_buildSideScreen()
	local root = Instance.new("Frame")
	root.Name = "SideScreen"
	root.Size = UDim2.new(1, 0, 1, 0)
	root.BackgroundColor3 = C_BG
	root.BackgroundTransparency = 1
	root.ZIndex = 10
	root.Parent = self._gui
	self._sideScreen = root

	local topBorder = Instance.new("Frame")
	topBorder.Name = "TopBorder"
	topBorder.Size = UDim2.new(1, 0, 0, 2)
	topBorder.Position = UDim2.new(0, 0, 0, 0)
	topBorder.BackgroundColor3 = C_GOLD
	topBorder.BackgroundTransparency = 0.35
	topBorder.BorderSizePixel = 0
	topBorder.ZIndex = 11
	topBorder.Parent = root

	local bottomBorder = Instance.new("Frame")
	bottomBorder.Name = "BottomBorder"
	bottomBorder.Size = UDim2.new(1, 0, 0, 2)
	bottomBorder.Position = UDim2.new(0, 0, 1, -2)
	bottomBorder.BackgroundColor3 = C_GOLD
	bottomBorder.BackgroundTransparency = 0.35
	bottomBorder.BorderSizePixel = 0
	bottomBorder.ZIndex = 11
	bottomBorder.Parent = root

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(1, 0, 0, 18)
	subtitle.Position = UDim2.new(0, 0, 0, 24)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "— SELECT YOUR SIDE —"
	subtitle.TextColor3 = C_GOLD
	subtitle.TextSize = 11
	subtitle.Font = Enum.Font.GothamBold
	subtitle.TextXAlignment = Enum.TextXAlignment.Center
	subtitle.ZIndex = 12
	subtitle.Parent = root

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 38)
	title.Position = UDim2.new(0, 0, 0, 40)
	title.BackgroundTransparency = 1
	title.Text = "CHOOSE YOUR ALLEGIANCE"
	title.TextColor3 = C_TEXT
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 26
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 12
	title.Parent = root

	local CARD_W, CARD_H = 390, 400
	local holder = Instance.new("Frame")
	holder.Name = "CardsHolder"
	holder.Size = UDim2.new(0, CARD_W * 2 + 30, 0, CARD_H)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0.5, 14)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 12
	holder.Parent = root

	local separator = Instance.new("Frame")
	separator.Name = "Separator"
	separator.Size = UDim2.new(0, 1, 0, CARD_H - 40)
	separator.AnchorPoint = Vector2.new(0.5, 0.5)
	separator.Position = UDim2.new(0.5, 0, 0.5, 0)
	separator.BackgroundColor3 = C_GOLD
	separator.BackgroundTransparency = 0.55
	separator.BorderSizePixel = 0
	separator.ZIndex = 14
	separator.Parent = holder

	self._sideCardVisuals = {}
	for sideIdx, sd in ipairs(SIDES) do
		local isLeft = (sideIdx == 1)
		local card = Instance.new("Frame")
		card.Name = "Card_" .. sd.key
		card.Size = UDim2.new(0.5, -15, 1, 0)
		card.Position = isLeft and UDim2.new(0, 0, 0, 0) or UDim2.new(0.5, 15, 0, 0)
		card.BackgroundColor3 = sd.dim
		card.BackgroundTransparency = 0.15
		card.ZIndex = 13
		card.Parent = holder

		local cardStroke = Instance.new("UIStroke")
		cardStroke.Color = sd.accent
		cardStroke.Thickness = 1.5
		cardStroke.Transparency = 0.65
		cardStroke.Parent = card

		local gradOver = Instance.new("Frame")
		gradOver.Name = "GradientOverlay"
		gradOver.Size = UDim2.new(1, 0, 1, 0)
		gradOver.BackgroundColor3 = sd.accent
		gradOver.BackgroundTransparency = 0.80
		gradOver.BorderSizePixel = 0
		gradOver.ZIndex = 13
		gradOver.Parent = card

		local g = Instance.new("UIGradient")
		g.Rotation = isLeft and 130 or 50
		g.Color = ColorSequence.new(Color3.new(1,1,1), Color3.new(0,0,0))
		g.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.0), NumberSequenceKeypoint.new(1, 0.9) })
		g.Parent = gradOver

		local roleSmall = Instance.new("TextLabel")
		roleSmall.Name = "RoleSmall"
		roleSmall.Size = UDim2.new(1, -16, 0, 16)
		roleSmall.Position = UDim2.new(0, 8, 0, 12)
		roleSmall.BackgroundTransparency = 1
		roleSmall.Text = sd.role
		roleSmall.TextColor3 = sd.accent
		roleSmall.TextSize = 10
		roleSmall.Font = Enum.Font.GothamBold
		roleSmall.TextXAlignment = Enum.TextXAlignment.Center
		roleSmall.ZIndex = 14
		roleSmall.Parent = card

		local roleLarge = Instance.new("TextLabel")
		roleLarge.Name = "RoleLarge"
		roleLarge.Size = UDim2.new(1, -16, 0, 68)
		roleLarge.Position = UDim2.new(0, 8, 0, 30)
		roleLarge.BackgroundTransparency = 1
		roleLarge.Text = sd.role
		roleLarge.TextColor3 = C_TEXT
		roleLarge.Font = Enum.Font.GothamBlack
		roleLarge.TextScaled = true
		roleLarge.TextXAlignment = Enum.TextXAlignment.Center
		roleLarge.ZIndex = 14
		roleLarge.Parent = card

		local divider = Instance.new("Frame")
		divider.Name = "Divider"
		divider.Size = UDim2.new(1, -30, 0, 1)
		divider.Position = UDim2.new(0, 15, 0, 106)
		divider.BackgroundColor3 = sd.accent
		divider.BackgroundTransparency = 0.6
		divider.BorderSizePixel = 0
		divider.ZIndex = 14
		divider.Parent = card

		local sideName = Instance.new("TextLabel")
		sideName.Name = "SideName"
		sideName.Size = UDim2.new(1, -16, 0, 26)
		sideName.Position = UDim2.new(0, 8, 0, 114)
		sideName.BackgroundTransparency = 1
		sideName.Text = sd.name
		sideName.TextColor3 = C_TEXT
		sideName.TextSize = 12
		sideName.Font = Enum.Font.GothamBold
		sideName.TextXAlignment = Enum.TextXAlignment.Center
		sideName.TextTruncate = Enum.TextTruncate.AtEnd
		sideName.ZIndex = 14
		sideName.Parent = card

		local ny = 148
		for _, nd in ipairs(sd.nations) do
			local np = Instance.new("Frame")
			np.Name = "Nation_" .. nd.key
			np.Size = UDim2.new(1, -16, 0, 32)
			np.Position = UDim2.new(0, 8, 0, ny)
			np.BackgroundColor3 = C_ROW
			np.BackgroundTransparency = 0.45
			np.BorderSizePixel = 0
			np.ZIndex = 14
			np.Parent = card

			local npCorner = Instance.new("UICorner")
			npCorner.CornerRadius = UDim.new(0, 5)
			npCorner.Parent = np

			local flagImg = Instance.new("ImageLabel")
			flagImg.Size = UDim2.new(0, 26, 0, 26)
			flagImg.Position = UDim2.new(0, 6, 0.5, -13)
			flagImg.BackgroundTransparency = 1
			flagImg.Image = nd.flag
			flagImg.ZIndex = 15
			flagImg.Parent = np

			local nLabel = Instance.new("TextLabel")
			nLabel.Size = UDim2.new(1, -44, 1, 0)
			nLabel.Position = UDim2.new(0, 40, 0, 0)
			nLabel.BackgroundTransparency = 1
			nLabel.Text = nd.name
			nLabel.TextColor3 = C_DIM
			nLabel.Font = Enum.Font.Gotham
			nLabel.TextSize = 10
			nLabel.TextXAlignment = Enum.TextXAlignment.Left
			nLabel.ZIndex = 15
			nLabel.Parent = np

			ny += 36
		end

		local selBtn = Instance.new("TextButton")
		selBtn.Name = "SelectBtn"
		selBtn.Size = UDim2.new(1,-16,0,46); selBtn.AnchorPoint = Vector2.new(0,1)
		selBtn.Position = UDim2.new(0,8,1,-8); selBtn.BackgroundColor3 = sd.accent
		selBtn.BackgroundTransparency = 0.28; selBtn.Text = "SELECT  ›"
		selBtn.TextColor3 = Color3.new(1,1,1); selBtn.Font = Enum.Font.GothamBold
		selBtn.TextSize = 13; selBtn.ZIndex = 16; selBtn.Parent = card

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 8)
		btnCorner.Parent = selBtn

		local btnStroke = Instance.new("UIStroke")
		btnStroke.Color = sd.accent; btnStroke.Thickness = 1.5; btnStroke.Transparency = 0.45; btnStroke.Parent = selBtn

		card.MouseEnter:Connect(function()
			TweenService:Create(cardStroke, TI_FAST, {Transparency=0.1}):Play()
			TweenService:Create(card,    TI_FAST, {BackgroundTransparency=0.05}):Play()
		end)

		card.MouseLeave:Connect(function()
			TweenService:Create(cardStroke, TI_FAST, {Transparency=0.65}):Play()
			TweenService:Create(card, TI_FAST, {BackgroundTransparency=0.15}):Play()
		end)

		selBtn.MouseEnter:Connect(function()
			TweenService:Create(selBtn, TI_FAST, {BackgroundTransparency=0.05}):Play()
		end)

		selBtn.MouseLeave:Connect(function()
			TweenService:Create(selBtn, TI_FAST, {BackgroundTransparency=0.28}):Play()
		end)

		local function onSelect()
			self:_onSideSelected(sd, sideIdx)
		end

		selBtn.MouseButton1Click:Connect(onSelect)

		local hitSurface = Instance.new("TextButton")
		hitSurface.Name = "HitSurface"
		hitSurface.Size = UDim2.new(1, 0, 1, -62)
		hitSurface.BackgroundTransparency = 1
		hitSurface.Text = ""
		hitSurface.ZIndex = 17
		hitSurface.Parent = card
		hitSurface.MouseButton1Click:Connect(onSelect)

		self._sideCardVisuals[sideIdx] = { card=card, stroke=cardStroke }
	end

	local footerHint = Instance.new("TextLabel")
	footerHint.Name = "FooterHint"
	footerHint.Size = UDim2.new(1, 0, 0, 16)
	footerHint.AnchorPoint = Vector2.new(0, 1)
	footerHint.Position = UDim2.new(0, 0, 1, -14)
	footerHint.BackgroundTransparency = 1
	footerHint.Text = "Choose your allegiance to begin"
	footerHint.TextColor3 = C_DIM
	footerHint.Font = Enum.Font.Gotham
	footerHint.TextSize = 10
	footerHint.TextXAlignment = Enum.TextXAlignment.Center
	footerHint.ZIndex = 12
	footerHint.Parent = root
end

-- ─────────────────────────────────────────────────────────────────────
-- Loadout Screen
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_buildLoadoutScreen()
	local overlay = Instance.new("Frame")
	overlay.Name = "LoadoutScreen"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.45
	overlay.ZIndex = 30
	overlay.Visible = false
	overlay.Parent = self._gui
	self._loadoutScreen = overlay

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 1.5, 0)
	panel.BackgroundColor3 = C_PANEL
	panel.BackgroundTransparency = 0.04
	panel.ZIndex = 31
	panel.Parent = overlay

	--	local panelCorner = Instance.new("UICorner")
	--	panelCorner.CornerRadius = UDim.new(0, 12)
	--	panelCorner.Parent = panel

	self._loadoutPanel  = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = C_GOLD
	panelStroke.Thickness = 1.5
	panelStroke.Transparency = 0.7
	panelStroke.Parent = panel
	self._loadoutStroke = panelStroke

	-- ── Header ────────────────────────────────────────────────────────
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_H)
	header.BackgroundColor3 = C_CARD
	header.BackgroundTransparency = 0.08
	header.BorderSizePixel = 0
	header.ZIndex = 32
	header.Parent = panel

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 12)
	headerCorner.Parent = header

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleLabel"
	titleLabel.Size = UDim2.new(1, -140, 1, 0)
	titleLabel.Position = UDim2.new(0, 70, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "—"
	titleLabel.TextColor3 = C_TEXT
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextSize = 13
	titleLabel.TextXAlignment = Enum.TextXAlignment.Center
	titleLabel.ZIndex = 33
	titleLabel.Parent = header

	self._headerLabel = titleLabel

	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackBtn"
	backBtn.Size = UDim2.new(0,60,0,34); backBtn.Position = UDim2.new(0,8,0.5,-17)
	backBtn.BackgroundColor3 = C_ROW; backBtn.BackgroundTransparency = 0.38
	backBtn.Text = "‹  BACK"; backBtn.TextColor3 = C_DIM
	backBtn.Font = Enum.Font.GothamBold; backBtn.TextSize = 10
	backBtn.ZIndex = 34; backBtn.Parent = header

	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 5)
	backCorner.Parent = backBtn

	backBtn.MouseEnter:Connect(function()
		TweenService:Create(backBtn, TI_FAST, {TextColor3=C_TEXT}):Play()
	end)

	backBtn.MouseLeave:Connect(function()
		TweenService:Create(backBtn, TI_FAST, {TextColor3=C_DIM}):Play()
	end)

	backBtn.MouseButton1Click:Connect(function() 
		self:_transitionToSideScreen()
	end)

	-- ── Two-column content area ───────────────────────────────────────
	local CONTENT_H = PANEL_H - HEADER_H   -- 346px
	local RIGHT_X   = NAV_W + 1
	local RIGHT_W   = PANEL_W - RIGHT_X    -- 479px

	-- Left nav frame
	local leftNav = Instance.new("Frame")
	leftNav.Name = "LeftNav"
	leftNav.Size = UDim2.new(0, NAV_W, 0, CONTENT_H)
	leftNav.Position = UDim2.new(0, 0, 0, HEADER_H)
	leftNav.BackgroundColor3 = C_CARD
	leftNav.BackgroundTransparency = 0.30
	leftNav.BorderSizePixel = 0
	leftNav.ZIndex = 32
	leftNav.Parent = panel

	-- Patch top corners of leftNav (header already rounds the panel top)
	local navPatch = Instance.new("Frame")
	navPatch.Name = "NavPatch"
	navPatch.Size = UDim2.new(1, 0, 0, 12)
	navPatch.BackgroundColor3 = C_CARD
	navPatch.BackgroundTransparency = 0.30
	navPatch.BorderSizePixel = 0
	navPatch.ZIndex = 32
	navPatch.Parent = leftNav

	-- Round bottom-left corner only
	local navCorner = Instance.new("UICorner")
	navCorner.CornerRadius = UDim.new(0, 8)
	navCorner.Parent = leftNav

	-- Column divider
	local colDiv = Instance.new("Frame")
	colDiv.Name = "ColumnDivider"
	colDiv.Size = UDim2.new(0, 1, 0, CONTENT_H - 16)
	colDiv.Position = UDim2.new(0, NAV_W, 0, HEADER_H + 8)
	colDiv.BackgroundColor3 = C_SEP; colDiv.BorderSizePixel = 0; colDiv.ZIndex = 32
	colDiv.Parent = panel

	-- ── NATION nav section ────────────────────────────────────────────
	self:_makeNavSectionLabel(leftNav, "NATION", NAT_LABEL_Y)

	local natCard, natName, natSub, natIcon, natStroke =
		self:_makeNavCard(leftNav, NAT_CARD_Y, NAT_CARD_H)
	self._natNavCard   = natCard
	self._natNavName   = natName
	self._natNavSub    = natSub
	self._natNavIcon   = natIcon
	self._natNavStroke = natStroke

	natCard.MouseButton1Click:Connect(function()
		self:_setRightMode("nations")
	end)

	-- ── REGIMENT nav section ──────────────────────────────────────────
	self:_makeNavSectionLabel(leftNav, "REGIMENT", REG_LABEL_Y)

	local regCard, regName, regSub, regSwatch, regStroke = self:_makeNavCard(leftNav, REG_CARD_Y, REG_CARD_H)
	self._regNavCard   = regCard
	self._regNavName   = regName
	self._regNavSub    = regSub
	self._regNavSwatch = regSwatch
	self._regNavStroke = regStroke

	-- Regiment swatch starts as solid box, not flag image
	regSwatch.Image = ""; regSwatch.BackgroundColor3 = C_SEP
	regSwatch.BackgroundTransparency = 0.4

	local regSwatchCorner = Instance.new("UICorner")
	regSwatchCorner.CornerRadius = UDim.new(0, 4)
	regSwatchCorner.Parent = regSwatch

	regCard.MouseButton1Click:Connect(function()
		if self._selectedNation then
			self:_setRightMode("regiments")
		end
	end)

	-- ── Deploy button ─────────────────────────────────────────────────
	local deployBtn = Instance.new("TextButton")
	deployBtn.Name = "DeployBtn"
	deployBtn.Size = UDim2.new(1,-PAD*2,0,44)
	deployBtn.AnchorPoint = Vector2.new(0,1)
	deployBtn.Position = UDim2.new(0,PAD,1,-PAD)
	deployBtn.BackgroundColor3 = C_GOLD
	deployBtn.BackgroundTransparency = 0.45
	deployBtn.Text = "⚑  DEPLOY"
	deployBtn.TextColor3 = C_BG
	deployBtn.Font = Enum.Font.GothamBlack
	deployBtn.TextSize = 12
	deployBtn.ZIndex = 34
	deployBtn.Parent = leftNav

	local deployCorner = Instance.new("UICorner")
	deployCorner.CornerRadius = UDim.new(0, 8)
	deployCorner.Parent = deployBtn

	self._deployBtn = deployBtn

	deployBtn.MouseEnter:Connect(function()
		if self._selectedRegiment then
			TweenService:Create(deployBtn, TI_FAST, {BackgroundTransparency=0}):Play()
		end
	end)

	deployBtn.MouseLeave:Connect(function()
		TweenService:Create(deployBtn, TI_FAST, {BackgroundTransparency = self._selectedRegiment and 0.18 or 0.45}):Play()
	end)

	deployBtn.MouseButton1Click:Connect(function()
		if self._selectedRegiment then 
			self:_deploy() 
		end
	end)

	-- ── Right area ────────────────────────────────────────────────────
	local rightArea = Instance.new("Frame")
	rightArea.Name = "RightArea"
	rightArea.Size = UDim2.new(0, RIGHT_W, 0, CONTENT_H)
	rightArea.Position = UDim2.new(0, RIGHT_X, 0, HEADER_H)
	rightArea.BackgroundTransparency = 1
	rightArea.ZIndex = 32
	rightArea.Parent = panel

	-- Right area section label
	local sectionTitle = Instance.new("TextLabel")
	sectionTitle.Name = "SectionTitle"
	sectionTitle.Size = UDim2.new(1, -16, 0, 18)
	sectionTitle.Position = UDim2.new(0, 10, 0, 10)
	sectionTitle.BackgroundTransparency = 1
	sectionTitle.Text = "CHOOSE A NATION"
	sectionTitle.TextColor3 = C_DIM
	sectionTitle.Font = Enum.Font.GothamBold
	sectionTitle.TextSize = 9
	sectionTitle.TextXAlignment = Enum.TextXAlignment.Left
	sectionTitle.ZIndex = 33
	sectionTitle.Parent = rightArea
	self._rightModeLabel = sectionTitle

	local SCROLL_TOP = 32
	local SCROLL_H   = CONTENT_H - SCROLL_TOP - 8

	-- Nations scroll (UIListLayout inside)
	local natScroll = Instance.new("ScrollingFrame")
	natScroll.Name = "NatScroll"
	natScroll.Size = UDim2.new(1, -16, 0, SCROLL_H)
	natScroll.Position = UDim2.new(0, 8, 0, SCROLL_TOP)
	natScroll.BackgroundTransparency = 1
	natScroll.ScrollBarThickness = 3
	natScroll.ScrollBarImageColor3 = C_GOLD
	natScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	natScroll.ZIndex = 33; natScroll.Visible = true; natScroll.Parent = rightArea
	self._natScroll = natScroll

	local nl = Instance.new("UIListLayout")
	nl.Padding = UDim.new(0,5); nl.SortOrder = Enum.SortOrder.LayoutOrder
	nl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	nl.Parent = natScroll

	-- Regiments scroll (UIListLayout inside)
	local regScroll = Instance.new("ScrollingFrame")
	regScroll.Name = "RegScroll"
	regScroll.Size = UDim2.new(1, -16, 0, SCROLL_H)
	regScroll.Position = UDim2.new(0, 8, 0, SCROLL_TOP)
	regScroll.BackgroundTransparency = 1
	regScroll.ScrollBarThickness = 3
	regScroll.ScrollBarImageColor3 = C_GOLD
	regScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	regScroll.ZIndex = 33; regScroll.Visible = false; regScroll.Parent = rightArea
	self._regScroll = regScroll

	local rl = Instance.new("UIListLayout")
	rl.Padding = UDim.new(0,5); rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rl.Parent = regScroll
end

-- ── Nav section builder helpers ───────────────────────────────────────

function TeamSelectMenu:_makeNavSectionLabel(parent, text, yPos)
	local label = Instance.new("TextLabel")
	label.Name = "Label_" .. text
	label.Size = UDim2.new(1, -PAD * 2, 0, 16)
	label.Position = UDim2.new(0, PAD, 0, yPos)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = C_GOLD
	label.Font = Enum.Font.GothamBold
	label.TextSize = 9
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 33
	label.Parent = parent

	local sep = Instance.new("Frame")
	sep.Name = "Separator_" .. text
	sep.Size = UDim2.new(1, -PAD * 2, 0, 1)
	sep.Position = UDim2.new(0, PAD, 0, yPos + 16)
	sep.BackgroundColor3 = C_SEP
	sep.BorderSizePixel = 0
	sep.ZIndex = 33
	sep.Parent = parent
end

-- Returns: clickSurface, nameLabel, subLabel, iconImg, stroke
function TeamSelectMenu:_makeNavCard(parent, yPos, cardH)
	local frame = Instance.new("Frame")
	frame.Name = "NavCard"
	frame.Size = UDim2.new(1, -PAD * 2, 0, cardH)
	frame.Position = UDim2.new(0, PAD, 0, yPos)
	frame.BackgroundColor3 = C_ROW
	frame.BackgroundTransparency = 0.50
	frame.BorderSizePixel = 0
	frame.ZIndex = 33
	frame.Parent = parent

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(0, 7)
	frameCorner.Parent = frame

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = C_SEP
	cardStroke.Thickness = 1
	cardStroke.Transparency = 0.3
	cardStroke.Parent = frame

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.new(0, 36, 0, 36)
	icon.Position = UDim2.new(0, 10, 0.5, -18)
	icon.BackgroundColor3 = C_SEP
	icon.BackgroundTransparency = 0.50
	icon.ZIndex = 34
	icon.Parent = frame

	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(0, 4)
	iconCorner.Parent = icon

	local nameL = Instance.new("TextLabel")
	nameL.Name = "Title"
	nameL.Size = UDim2.new(1, -66, 0, 20)
	nameL.Position = UDim2.new(0, 56, 0, 8)
	nameL.BackgroundTransparency = 1
	nameL.Text = "—"
	nameL.TextColor3 = C_DIM
	nameL.Font = Enum.Font.GothamBold
	nameL.TextSize = 12
	nameL.TextXAlignment = Enum.TextXAlignment.Left
	nameL.TextTruncate = Enum.TextTruncate.AtEnd
	nameL.ZIndex = 34
	nameL.Parent = frame

	local subL = Instance.new("TextLabel")
	subL.Name = "Subtitle"
	subL.Size = UDim2.new(1, -66, 0, 14)
	subL.Position = UDim2.new(0, 56, 0, 29)
	subL.BackgroundTransparency = 1
	subL.Text = ""
	subL.TextColor3 = C_DIM
	subL.Font = Enum.Font.Gotham
	subL.TextSize = 9
	subL.TextXAlignment = Enum.TextXAlignment.Left
	subL.TextTruncate = Enum.TextTruncate.AtEnd
	subL.ZIndex = 34
	subL.Parent = frame

	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.Size = UDim2.new(0, 14, 1, 0)
	arrow.Position = UDim2.new(1, -18, 0, 0)
	arrow.BackgroundTransparency = 1
	arrow.Text = "›"
	arrow.TextColor3 = C_DIM
	arrow.Font = Enum.Font.GothamBold
	arrow.TextSize = 14
	arrow.TextXAlignment = Enum.TextXAlignment.Center
	arrow.ZIndex = 34
	arrow.Parent = frame

	-- Hover on the whole frame
	local hitBtn = Instance.new("TextButton")
	hitBtn.Name = "HitButton"
	hitBtn.Size = UDim2.new(1, 0, 1, 0)
	hitBtn.BackgroundTransparency = 1
	hitBtn.Text = ""
	hitBtn.ZIndex = 36
	hitBtn.Parent = frame

	frame.MouseEnter:Connect(function()
		TweenService:Create(frame, TI_FAST, {BackgroundTransparency=0.30}):Play()
	end)

	frame.MouseLeave:Connect(function()
		TweenService:Create(frame, TI_FAST, {BackgroundTransparency=0.50}):Play()
	end)

	return hitBtn, nameL, subL, icon, cardStroke
end

-- ─────────────────────────────────────────────────────────────────────
-- Right mode switching
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_setRightMode(mode)
	self._rightMode = mode
	self._natScroll.Visible = (mode == "nations")
	self._regScroll.Visible = (mode == "regiments")
	self._rightModeLabel.Text = (mode == "nations") and "CHOOSE A NATION" or "CHOOSE A REGIMENT"

	local accent = self._selectedSide and self._selectedSide.accent or C_GOLD
	local natSel = (mode == "nations")
	TweenService:Create(self._natNavStroke, TI_FAST, {Color = natSel and accent or C_SEP, Transparency = natSel and 0.1 or 0.3,}):Play()
	TweenService:Create(self._regNavStroke, TI_FAST, {Color = (not natSel) and accent or C_SEP, Transparency = (not natSel) and 0.1 or 0.3,}):Play()
end

-- ─────────────────────────────────────────────────────────────────────
-- Populate nations scroll
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_populateNations(sd)
	for _, ch in ipairs(self._natScroll:GetChildren()) do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	self._natRows = {}

	for i, nd in ipairs(sd.nations) do
		local row = Instance.new("Frame")
		row.Name = "NatRow" .. i
		row.Size = UDim2.new(1, -4, 0, 62)
		row.BackgroundColor3 = C_ROW
		row.BackgroundTransparency = 0.38
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 34
		row.Parent = self._natScroll

		local rStroke = Instance.new("UIStroke")
		rStroke.Color = C_SEP; rStroke.Thickness = 1; rStroke.Transparency = 0.25; rStroke.Parent = row

		local flagImg = Instance.new("ImageLabel")
		flagImg.Size = UDim2.new(0, 40, 0, 40)
		flagImg.Position = UDim2.new(0, 12, 0.5, -20)
		flagImg.BackgroundTransparency = 1; flagImg.Image = nd.flag; flagImg.ZIndex = 35
		flagImg.Parent = row

		local nName = Instance.new("TextLabel")
		nName.Size = UDim2.new(1, -76, 0, 22)
		nName.Position = UDim2.new(0, 64, 0, 9)
		nName.BackgroundTransparency = 1; nName.Text = nd.name; nName.TextColor3 = C_TEXT
		nName.Font = Enum.Font.GothamBold; nName.TextSize = 14
		nName.TextXAlignment = Enum.TextXAlignment.Left; nName.ZIndex = 35
		nName.Parent = row

		local nSub = Instance.new("TextLabel")
		nSub.Size = UDim2.new(1, -76, 0, 16)
		nSub.Position = UDim2.new(0, 64, 0, 32)
		nSub.BackgroundTransparency = 1; nSub.Text = nd.subtitle; nSub.TextColor3 = C_DIM
		nSub.Font = Enum.Font.Gotham; nSub.TextSize = 10
		nSub.TextXAlignment = Enum.TextXAlignment.Left; nSub.ZIndex = 35
		nSub.Parent = row

		local clickBtn = Instance.new("TextButton")
		clickBtn.Size = UDim2.new(1, 0, 1, 0); clickBtn.BackgroundTransparency = 1; clickBtn.Text = ""
		clickBtn.ZIndex = 37; clickBtn.Parent = row

		clickBtn.MouseEnter:Connect(function()
			if self._selectedNation ~= nd then
				TweenService:Create(row, TI_FAST, {BackgroundTransparency=0.18}):Play()
			end
		end)

		clickBtn.MouseLeave:Connect(function()
			if self._selectedNation ~= nd then
				TweenService:Create(row, TI_FAST, {BackgroundTransparency=0.38}):Play()
			end
		end)

		clickBtn.MouseButton1Click:Connect(function()
			self:_onNationSelected(nd)
		end)

		self._natRows[i] = { row=row, stroke=rStroke, data=nd }
	end
end

-- ─────────────────────────────────────────────────────────────────────
-- Populate regiments scroll
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_populateRegiments(nd)
	for _, ch in ipairs(self._regScroll:GetChildren()) do
		if ch:IsA("GuiObject") then 
			ch:Destroy()
		end
	end

	self._regRows = {}

	for i, rd in ipairs(nd.regiments) do
		local row = Instance.new("Frame")
		row.Name = "RegRow" .. i
		row.Size = UDim2.new(1, -4, 0, 84)
		row.BackgroundColor3 = C_ROW
		row.BackgroundTransparency = 0.38
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 34
		row.Parent = self._regScroll

		local rStroke = Instance.new("UIStroke")
		rStroke.Color = C_SEP; rStroke.Thickness = 1; rStroke.Transparency = 0.25; rStroke.Parent = row

		-- Left swatch
		local sw = Instance.new("Frame")
		sw.Size = UDim2.new(0, 4, 1, -18)
		sw.Position = UDim2.new(0, 10, 0, 9); sw.BackgroundColor3 = rd.color
		sw.BorderSizePixel = 0; sw.ZIndex = 35; sw.Parent = row

		local swCorner = Instance.new("UICorner")
		swCorner.CornerRadius = UDim.new(0, 2); swCorner.Parent = sw

		local rName = Instance.new("TextLabel")
		rName.Size = UDim2.new(1, -26, 0, 40); rName.Position = UDim2.new(0, 24, 0, 6)
		rName.BackgroundTransparency = 1; rName.Text = rd.name; rName.TextColor3 = C_TEXT
		rName.Font = Enum.Font.GothamBold; rName.TextSize = 13
		rName.TextXAlignment = Enum.TextXAlignment.Left; rName.TextWrapped = true; rName.ZIndex = 35
		rName.Parent = row

		local rDesc = Instance.new("TextLabel")
		rDesc.Size = UDim2.new(1, -26, 0, 26); rDesc.Position = UDim2.new(0, 24, 0, 50)
		rDesc.BackgroundTransparency = 1; rDesc.Text = rd.desc; rDesc.TextColor3 = C_DIM
		rDesc.Font = Enum.Font.Gotham; rDesc.TextSize = 10
		rDesc.TextXAlignment = Enum.TextXAlignment.Left; rDesc.TextWrapped = true; rDesc.ZIndex = 35
		rDesc.Parent = row

		local clickBtn = Instance.new("TextButton")
		clickBtn.Size = UDim2.new(1, 0, 1, 0); clickBtn.BackgroundTransparency = 1; clickBtn.Text = ""
		clickBtn.ZIndex = 37; clickBtn.Parent = row

		clickBtn.MouseEnter:Connect(function()
			if self._selectedRegiment ~= rd then
				TweenService:Create(row, TI_FAST, {BackgroundTransparency=0.18}):Play()
			end
		end)

		clickBtn.MouseLeave:Connect(function()
			if self._selectedRegiment ~= rd then
				TweenService:Create(row, TI_FAST, {BackgroundTransparency=0.38}):Play()
			end
		end)

		clickBtn.MouseButton1Click:Connect(function()
			self:_onRegimentSelected(rd, i)
		end)

		self._regRows[i] = { row=row, stroke=rStroke, data=rd }
	end
end

-- ─────────────────────────────────────────────────────────────────────
-- Selection handlers
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_onSideSelected(sd, sideIdx)
	-- 1. Update State
	self._selectedSide        = sd
	self._selectedSideIdx     = sideIdx
	self._selectedNation      = nil
	self._selectedRegiment    = nil
	self._selectedRegimentIdx = nil

	-- 2. Update Visuals
	self._headerLabel.Text                 = sd.role .. "  ·  " .. sd.name
	self._loadoutStroke.Color              = sd.accent
	self._loadoutStroke.Transparency       = 0.4
	self._deployBtn.BackgroundColor3       = sd.accent
	self._deployBtn.BackgroundTransparency = 0.45
	self._deployBtn.Text                   = "DEPLOY"

	-- 3. Reset Navigation Cards
	self._natNavName.Text = "—"; self._natNavName.TextColor3 = C_DIM
	self._natNavSub.Text  = "Select a nation"
	self._natNavIcon.Image = ""; self._natNavIcon.BackgroundColor3 = C_SEP
	self._natNavIcon.BackgroundTransparency = 0.5

	self._regNavName.Text = "—"; self._regNavName.TextColor3 = C_DIM
	self._regNavSub.Text  = "Choose a nation first"
	self._regNavSwatch.BackgroundColor3 = C_SEP
	self._regNavSwatch.BackgroundTransparency = 0.5

	-- 4. Prepare List and Transition
	self:_populateNations(sd)
	self:_setRightMode("nations") -- Ensure we always start on the Nations list
	self:_transitionToLoadoutScreen()
end

function TeamSelectMenu:_onNationSelected(nd)
	local accent = self._selectedSide and self._selectedSide.accent or C_GOLD

	for _, rdata in ipairs(self._natRows) do
		local sel = (rdata.data == nd)
		TweenService:Create(rdata.row, TI_FAST, {BackgroundTransparency=sel and 0.08 or 0.38}):Play()
		TweenService:Create(rdata.stroke, TI_FAST, {Color=sel and accent or C_SEP, Transparency=sel and 0.1 or 0.25 }):Play()
	end

	self._selectedNation = nd
	self._selectedRegiment = nil; self._selectedRegimentIdx = nil
	self._natNavName.Text = nd.name; self._natNavName.TextColor3 = C_TEXT
	self._natNavSub.Text  = nd.subtitle
	self._natNavIcon.Image = nd.flag; self._natNavIcon.BackgroundTransparency = 0

	self:_populateRegiments(nd)
	self._regNavSub.Text = "Select a regiment"
end

function TeamSelectMenu:_onRegimentSelected(rd, regIdx)
	local side = self._selectedSide
	if not side then return end

	-- Calculate global index across all nations in this side
	local globalIdx = 0
	for _, nation in ipairs(side.nations) do
		if nation == self._selectedNation then break end
		globalIdx += #nation.regiments
	end

	self._selectedRegiment    = rd
	self._selectedRegimentIdx = globalIdx + regIdx

	local accent = self._selectedSide and self._selectedSide.accent or C_GOLD

	for _, rdata in ipairs(self._regRows) do
		local sel = (rdata.data == rd)
		TweenService:Create(rdata.row, TI_FAST, {BackgroundTransparency=sel and 0.08 or 0.38}):Play()
		TweenService:Create(rdata.stroke, TI_FAST, {Color=sel and accent or C_SEP, Transparency=sel and 0.1 or 0.25 }):Play()
	end

	-- Update regiment nav card
	self._regNavName.Text = rd.name; self._regNavName.TextColor3 = C_TEXT
	self._regNavSub.Text  = rd.desc
	self._regNavSwatch.BackgroundColor3 = rd.color
	self._regNavSwatch.BackgroundTransparency = 0.2

	-- Enable deploy
	self._deployBtn.BackgroundTransparency = 0.18
end

-- ─────────────────────────────────────────────────────────────────────
-- Deploy
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_deploy()
	local si = self._selectedSideIdx
	local ri = self._selectedRegimentIdx
	if not si or not ri then return end

	local prev = self._selectedSide and self._selectedSide.accent or C_GOLD
	self._deployBtn.BackgroundColor3 = Color3.fromRGB(50, 170, 80)

	task.delay(0.4, function()
		if self._deployBtn and self._deployBtn.Parent then
			self._deployBtn.BackgroundColor3 = prev
		end
	end)

	-- (u8, u8) — matches Blink TeamRegimentSelect definition
	self._network.TeamRegimentSelect.Fire(si, ri)
	task.delay(0.45, function()
		self:hide() 
	end)
end

-- ─────────────────────────────────────────────────────────────────────
-- Transitions
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_transitionToLoadoutScreen()
	self._sideScreen.Visible = false
	self._loadoutScreen.Visible = true
	self._loadoutPanel.Position = UDim2.new(0.5,0,1.5,0)
	TweenService:Create(self._loadoutPanel, TI_IN, {Position=UDim2.new(0.5,0,0.5,0)}):Play()
end

function TeamSelectMenu:_transitionToSideScreen()
	self._sideScreen.Visible = true
	TweenService:Create(self._loadoutPanel, TI_OUT, {Position=UDim2.new(0.5,0,1.5,0)}):Play()

	task.delay(0.20, function()
		if self._loadoutScreen then
			self._loadoutScreen.Visible = false 
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:show()
	self._gui.Enabled = true
	self:_lockCamera()
	self._sideScreen.Visible = true
	self._loadoutScreen.Visible = false

	if self._onVisibilityChanged then 
		self._onVisibilityChanged(true)
	end
end

function TeamSelectMenu:hide()
	self:_unlockCamera()
	if self._onVisibilityChanged then self._onVisibilityChanged(false) end
	if self._loadoutScreen.Visible then
		local t = TweenService:Create(self._loadoutPanel, TI_OUT, {Position=UDim2.new(0.5,0,1.5,0) })
		t.Completed:Connect(function()
			if self._gui then 
				self._gui.Enabled = false 
			end
		end)
		t:Play()
	else
		task.delay(0.20, function()
			if self._gui then
				self._gui.Enabled = false 
			end
		end)
	end
end

return TeamSelectMenu