-->>>>>>>>>>>>
-- TeamSelectMenu
-- Version 4.0.0  (Minimal Redesign)
--
-- Firing convention (unchanged):
--   Network.TeamRegimentSelect.Fire(sideIndex: u8, regimentIndex: u8)
--   sideIndex     1 = Attackers   2 = Defenders
--   regimentIndex 1-based position in nation.regiments[]
-->>>>>>>>>>>>

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RegimentData = require(ReplicatedStorage.Modules.Shared.RegimentData)
local SIDES = RegimentData.Sides

-- ── Palette (monochromatic / minimal) ────────────────────────────────
local C_BG       = Color3.fromRGB(8,   8,   8)
local C_SURFACE  = Color3.fromRGB(14,  14,  14)
local C_RAISED   = Color3.fromRGB(22,  22,  22)
local C_HOVER    = Color3.fromRGB(30,  30,  30)
local C_BORDER   = Color3.fromRGB(40,  40,  40)
local C_BORDER_H = Color3.fromRGB(105, 105, 105)
local C_TEXT     = Color3.fromRGB(205, 205, 205)
local C_DIM      = Color3.fromRGB(75,  75,  75)
local C_SEL      = Color3.fromRGB(185, 185, 185)

-- ── Layout ────────────────────────────────────────────────────────────
local PANEL_W  = 640
local PANEL_H  = 370
local HEADER_H = 42
local NAV_W    = 185
local PAD      = 10

local NAT_LABEL_Y = 10
local NAT_CARD_Y  = NAT_LABEL_Y + 18
local NAT_CARD_H  = 50
local REG_LABEL_Y = NAT_CARD_Y + NAT_CARD_H + 12
local REG_CARD_Y  = REG_LABEL_Y + 18
local REG_CARD_H  = 50

-- ── Tweens ────────────────────────────────────────────────────────────
local TI_FAST = TweenInfo.new(0.10, Enum.EasingStyle.Linear)
local TI_IN   = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TI_OUT  = TweenInfo.new(0.16, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

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
	self._selectedRegimentIdx = nil
	self._camConn             = nil
	self._savedCamType        = nil
	self._cameraLockActive    = false
	self._rightMode           = "nations"
	self._natRows             = {}
	self._regRows             = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "TeamSelectMenu"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	self._gui = gui

	self:_buildSideScreen()
	self:_buildLoadoutScreen()

	return self
end

-- ── Camera ────────────────────────────────────────────────────────────

function TeamSelectMenu:_lockCamera()
	local cam = workspace.CurrentCamera
	self._cameraLockActive = true
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		self._savedCamType = cam.CameraType
	end
	cam.CameraType = Enum.CameraType.Scriptable
	if self._camConn then self._camConn:Disconnect() end
	self._camConn = RunService.RenderStepped:Connect(function()
		local ref = workspace:FindFirstChild("menu_cam_pos")
		if not ref then return end
		local targetCF = ref:IsA("BasePart") and ref.CFrame or (ref:IsA("CFrameValue") and ref.Value)
		if targetCF then workspace.CurrentCamera.CFrame = targetCF end
	end)
end

function TeamSelectMenu:_unlockCamera()
	if self._camConn then self._camConn:Disconnect(); self._camConn = nil end
	self._cameraLockActive = false
	workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	task.spawn(function()
		local char = localPlayer.Character
		if not char or not char:FindFirstChild("Humanoid") or char.Humanoid.Health <= 0 then
			char = localPlayer.CharacterAdded:Wait()
		end
		local hum = char:WaitForChild("Humanoid", 5)
		if hum and not self._cameraLockActive then
			workspace.CurrentCamera.CameraType    = Enum.CameraType.Custom
			workspace.CurrentCamera.CameraSubject = hum
		end
	end)
end

-- ── Side Selection Screen ─────────────────────────────────────────────

function TeamSelectMenu:_buildSideScreen()
	local root = Instance.new("Frame")
	root.Name = "SideScreen"
	root.Size = UDim2.new(1, 0, 1, 0)
	root.BackgroundColor3 = C_BG
	root.BackgroundTransparency = 0
	root.ZIndex = 10
	root.Parent = self._gui
	self._sideScreen = root

	-- Tiny header label
	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, 0, 0, 14)
	header.Position = UDim2.new(0, 0, 0, 28)
	header.BackgroundTransparency = 1
	header.Text = "SELECT YOUR SIDE"
	header.TextColor3 = C_DIM
	header.Font = Enum.Font.GothamBold
	header.TextSize = 9
	header.TextXAlignment = Enum.TextXAlignment.Center
	header.ZIndex = 11
	header.Parent = root

	-- Two-card holder: 1px C_BORDER gap acts as the center divider
	local CARD_W = 320
	local CARD_H = 410

	local holder = Instance.new("Frame")
	holder.Name = "CardsHolder"
	holder.Size = UDim2.new(0, CARD_W * 2 + 1, 0, CARD_H)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0.5, 8)
	holder.BackgroundColor3 = C_BORDER    -- the 1px gap between cards
	holder.BackgroundTransparency = 0
	holder.BorderSizePixel = 0
	holder.ZIndex = 11
	holder.Parent = root

	self._sideCardVisuals = {}

	for sideIdx, sd in ipairs(SIDES) do
		local isLeft  = (sideIdx == 1)
		local xOffset = isLeft and 0 or (CARD_W + 1)

		local card = Instance.new("Frame")
		card.Name = "Card_" .. sd.key
		card.Size = UDim2.new(0, CARD_W, 1, 0)
		card.Position = UDim2.new(0, xOffset, 0, 0)
		card.BackgroundColor3 = C_SURFACE
		card.BackgroundTransparency = 0
		card.BorderSizePixel = 0
		card.ZIndex = 13
		card.Parent = holder

		local cardStroke = Instance.new("UIStroke")
		cardStroke.Color = C_BORDER
		cardStroke.Thickness = 1
		cardStroke.Transparency = 0
		cardStroke.Parent = card

		-- ROLE — tiny dim label
		local roleLabel = Instance.new("TextLabel")
		roleLabel.Size = UDim2.new(1, -28, 0, 12)
		roleLabel.Position = UDim2.new(0, 14, 0, 20)
		roleLabel.BackgroundTransparency = 1
		roleLabel.Text = sd.role
		roleLabel.TextColor3 = C_DIM
		roleLabel.Font = Enum.Font.GothamBold
		roleLabel.TextSize = 8
		roleLabel.TextXAlignment = Enum.TextXAlignment.Left
		roleLabel.ZIndex = 14
		roleLabel.Parent = card

		-- Alliance name — main heading
		local allianceName = Instance.new("TextLabel")
		allianceName.Size = UDim2.new(1, -28, 0, 26)
		allianceName.Position = UDim2.new(0, 14, 0, 34)
		allianceName.BackgroundTransparency = 1
		allianceName.Text = sd.name
		allianceName.TextColor3 = C_TEXT
		allianceName.Font = Enum.Font.GothamBold
		allianceName.TextSize = 14
		allianceName.TextXAlignment = Enum.TextXAlignment.Left
		allianceName.ZIndex = 14
		allianceName.Parent = card

		-- Thin rule
		local rule = Instance.new("Frame")
		rule.Size = UDim2.new(1, -28, 0, 1)
		rule.Position = UDim2.new(0, 14, 0, 70)
		rule.BackgroundColor3 = C_BORDER
		rule.BorderSizePixel = 0
		rule.ZIndex = 14
		rule.Parent = card

		-- Nations list (flag + name + subtitle)
		local ny = 82
		for _, nd in ipairs(sd.nations) do
			local rowFrame = Instance.new("Frame")
			rowFrame.Size = UDim2.new(1, -28, 0, 42)
			rowFrame.Position = UDim2.new(0, 14, 0, ny)
			rowFrame.BackgroundTransparency = 1
			rowFrame.BorderSizePixel = 0
			rowFrame.ZIndex = 14
			rowFrame.Parent = card

			local flagImg = Instance.new("ImageLabel")
			flagImg.Size = UDim2.new(0, 28, 0, 20)
			flagImg.Position = UDim2.new(0, 0, 0.5, -10)
			flagImg.BackgroundTransparency = 1
			flagImg.Image = nd.flag
			flagImg.ZIndex = 15
			flagImg.Parent = rowFrame

			local nName = Instance.new("TextLabel")
			nName.Size = UDim2.new(1, -38, 0, 16)
			nName.Position = UDim2.new(0, 38, 0, 4)
			nName.BackgroundTransparency = 1
			nName.Text = nd.name
			nName.TextColor3 = C_DIM
			nName.Font = Enum.Font.Gotham
			nName.TextSize = 10
			nName.TextXAlignment = Enum.TextXAlignment.Left
			nName.ZIndex = 15
			nName.Parent = rowFrame

			local nSub = Instance.new("TextLabel")
			nSub.Size = UDim2.new(1, -38, 0, 11)
			nSub.Position = UDim2.new(0, 38, 0, 22)
			nSub.BackgroundTransparency = 1
			nSub.Text = nd.subtitle
			nSub.TextColor3 = Color3.fromRGB(48, 48, 48)
			nSub.Font = Enum.Font.Gotham
			nSub.TextSize = 8
			nSub.TextXAlignment = Enum.TextXAlignment.Left
			nSub.ZIndex = 15
			nSub.Parent = rowFrame

			ny += 46
		end

		-- SELECT button (flush to bottom, full width minus padding)
		local selBtn = Instance.new("TextButton")
		selBtn.Name = "SelectBtn"
		selBtn.Size = UDim2.new(1, -28, 0, 36)
		selBtn.AnchorPoint = Vector2.new(0, 1)
		selBtn.Position = UDim2.new(0, 14, 1, -14)
		selBtn.BackgroundColor3 = C_RAISED
		selBtn.BackgroundTransparency = 0
		selBtn.Text = "SELECT  →"
		selBtn.TextColor3 = C_SEL
		selBtn.Font = Enum.Font.GothamBold
		selBtn.TextSize = 10
		selBtn.BorderSizePixel = 0
		selBtn.ZIndex = 16
		selBtn.Parent = card

		local selStroke = Instance.new("UIStroke")
		selStroke.Color = C_BORDER_H
		selStroke.Thickness = 1
		selStroke.Transparency = 0
		selStroke.Parent = selBtn

		card.MouseEnter:Connect(function()
			TweenService:Create(cardStroke, TI_FAST, {Color = C_BORDER_H}):Play()
		end)
		card.MouseLeave:Connect(function()
			TweenService:Create(cardStroke, TI_FAST, {Color = C_BORDER}):Play()
		end)
		selBtn.MouseEnter:Connect(function()
			TweenService:Create(selBtn, TI_FAST, {BackgroundColor3 = C_HOVER}):Play()
		end)
		selBtn.MouseLeave:Connect(function()
			TweenService:Create(selBtn, TI_FAST, {BackgroundColor3 = C_RAISED}):Play()
		end)

		local function onSelect()
			self:_onSideSelected(sd, sideIdx)
		end
		selBtn.MouseButton1Click:Connect(onSelect)

		-- Invisible hit surface covering the non-button card area
		local hitSurface = Instance.new("TextButton")
		hitSurface.Name = "HitSurface"
		hitSurface.Size = UDim2.new(1, 0, 1, -60)
		hitSurface.BackgroundTransparency = 1
		hitSurface.Text = ""
		hitSurface.ZIndex = 17
		hitSurface.Parent = card
		hitSurface.MouseButton1Click:Connect(onSelect)

		self._sideCardVisuals[sideIdx] = { card = card, stroke = cardStroke }
	end
end

-- ── Loadout Screen ────────────────────────────────────────────────────

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
	panel.BackgroundColor3 = C_SURFACE
	panel.BackgroundTransparency = 0
	panel.BorderSizePixel = 0
	panel.ZIndex = 31
	panel.Parent = overlay
	self._loadoutPanel = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = C_BORDER_H
	panelStroke.Thickness = 1
	panelStroke.Transparency = 0
	panelStroke.Parent = panel
	self._loadoutStroke = panelStroke

	-- ── Header ────────────────────────────────────────────────────────
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_H)
	header.BackgroundColor3 = C_RAISED
	header.BackgroundTransparency = 0
	header.BorderSizePixel = 0
	header.ZIndex = 32
	header.Parent = panel

	-- 1px divider under header
	local headerDiv = Instance.new("Frame")
	headerDiv.Size = UDim2.new(1, 0, 0, 1)
	headerDiv.Position = UDim2.new(0, 0, 1, -1)
	headerDiv.BackgroundColor3 = C_BORDER
	headerDiv.BorderSizePixel = 0
	headerDiv.ZIndex = 33
	headerDiv.Parent = header

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleLabel"
	titleLabel.Size = UDim2.new(1, -160, 1, 0)
	titleLabel.Position = UDim2.new(0, 80, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "—"
	titleLabel.TextColor3 = C_TEXT
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextSize = 10
	titleLabel.TextXAlignment = Enum.TextXAlignment.Center
	titleLabel.ZIndex = 33
	titleLabel.Parent = header
	self._headerLabel = titleLabel

	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackBtn"
	backBtn.Size = UDim2.new(0, 56, 0, 22)
	backBtn.Position = UDim2.new(0, 10, 0.5, -11)
	backBtn.BackgroundTransparency = 1
	backBtn.Text = "‹  BACK"
	backBtn.TextColor3 = C_DIM
	backBtn.Font = Enum.Font.GothamBold
	backBtn.TextSize = 9
	backBtn.BorderSizePixel = 0
	backBtn.ZIndex = 34
	backBtn.Parent = header

	backBtn.MouseEnter:Connect(function()
		TweenService:Create(backBtn, TI_FAST, {TextColor3 = C_SEL}):Play()
	end)
	backBtn.MouseLeave:Connect(function()
		TweenService:Create(backBtn, TI_FAST, {TextColor3 = C_DIM}):Play()
	end)
	backBtn.MouseButton1Click:Connect(function()
		self:_transitionToSideScreen()
	end)

	-- ── Two-column content ────────────────────────────────────────────
	local CONTENT_H = PANEL_H - HEADER_H
	local RIGHT_X   = NAV_W + 1
	local RIGHT_W   = PANEL_W - RIGHT_X

	-- Left nav panel
	local leftNav = Instance.new("Frame")
	leftNav.Name = "LeftNav"
	leftNav.Size = UDim2.new(0, NAV_W, 0, CONTENT_H)
	leftNav.Position = UDim2.new(0, 0, 0, HEADER_H)
	leftNav.BackgroundColor3 = C_SURFACE
	leftNav.BackgroundTransparency = 0
	leftNav.BorderSizePixel = 0
	leftNav.ZIndex = 32
	leftNav.Parent = panel

	-- 1px column divider
	local colDiv = Instance.new("Frame")
	colDiv.Name = "ColumnDivider"
	colDiv.Size = UDim2.new(0, 1, 0, CONTENT_H)
	colDiv.Position = UDim2.new(0, NAV_W, 0, HEADER_H)
	colDiv.BackgroundColor3 = C_BORDER
	colDiv.BorderSizePixel = 0
	colDiv.ZIndex = 32
	colDiv.Parent = panel

	-- ── Nation nav ────────────────────────────────────────────────────
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

	-- ── Regiment nav ──────────────────────────────────────────────────
	self:_makeNavSectionLabel(leftNav, "REGIMENT", REG_LABEL_Y)

	local regCard, regName, regSub, regSwatch, regStroke =
		self:_makeNavCard(leftNav, REG_CARD_Y, REG_CARD_H)
	self._regNavCard   = regCard
	self._regNavName   = regName
	self._regNavSub    = regSub
	self._regNavSwatch = regSwatch
	self._regNavStroke = regStroke

	-- Regiment nav uses the icon slot as a color swatch, not a flag
	regSwatch.Image = ""
	regSwatch.BackgroundColor3 = C_BORDER
	regSwatch.BackgroundTransparency = 0

	regCard.MouseButton1Click:Connect(function()
		if self._selectedNation then
			self:_setRightMode("regiments")
		end
	end)

	-- ── Deploy button ─────────────────────────────────────────────────
	local deployBtn = Instance.new("TextButton")
	deployBtn.Name = "DeployBtn"
	deployBtn.Size = UDim2.new(1, -PAD * 2, 0, 34)
	deployBtn.AnchorPoint = Vector2.new(0, 1)
	deployBtn.Position = UDim2.new(0, PAD, 1, -PAD)
	deployBtn.BackgroundColor3 = C_RAISED
	deployBtn.BackgroundTransparency = 0
	deployBtn.Text = "DEPLOY"
	deployBtn.TextColor3 = C_DIM
	deployBtn.Font = Enum.Font.GothamBold
	deployBtn.TextSize = 9
	deployBtn.BorderSizePixel = 0
	deployBtn.ZIndex = 34
	deployBtn.Parent = leftNav
	self._deployBtn = deployBtn

	local deployStroke = Instance.new("UIStroke")
	deployStroke.Color = C_BORDER
	deployStroke.Thickness = 1
	deployStroke.Transparency = 0
	deployStroke.Parent = deployBtn
	self._deployStroke = deployStroke

	deployBtn.MouseEnter:Connect(function()
		if self._selectedRegiment then
			TweenService:Create(deployBtn, TI_FAST, {BackgroundColor3 = C_HOVER}):Play()
		end
	end)
	deployBtn.MouseLeave:Connect(function()
		TweenService:Create(deployBtn, TI_FAST, {BackgroundColor3 = C_RAISED}):Play()
	end)
	deployBtn.MouseButton1Click:Connect(function()
		if self._selectedRegiment then self:_deploy() end
	end)

	-- ── Right area ────────────────────────────────────────────────────
	local rightArea = Instance.new("Frame")
	rightArea.Name = "RightArea"
	rightArea.Size = UDim2.new(0, RIGHT_W, 0, CONTENT_H)
	rightArea.Position = UDim2.new(0, RIGHT_X, 0, HEADER_H)
	rightArea.BackgroundTransparency = 1
	rightArea.ZIndex = 32
	rightArea.Parent = panel

	local sectionTitle = Instance.new("TextLabel")
	sectionTitle.Name = "SectionTitle"
	sectionTitle.Size = UDim2.new(1, -16, 0, 14)
	sectionTitle.Position = UDim2.new(0, PAD, 0, 9)
	sectionTitle.BackgroundTransparency = 1
	sectionTitle.Text = "CHOOSE A NATION"
	sectionTitle.TextColor3 = C_DIM
	sectionTitle.Font = Enum.Font.GothamBold
	sectionTitle.TextSize = 8
	sectionTitle.TextXAlignment = Enum.TextXAlignment.Left
	sectionTitle.ZIndex = 33
	sectionTitle.Parent = rightArea
	self._rightModeLabel = sectionTitle

	local SCROLL_TOP = 28
	local SCROLL_H   = CONTENT_H - SCROLL_TOP - 8

	local natScroll = Instance.new("ScrollingFrame")
	natScroll.Name = "NatScroll"
	natScroll.Size = UDim2.new(1, -10, 0, SCROLL_H)
	natScroll.Position = UDim2.new(0, 6, 0, SCROLL_TOP)
	natScroll.BackgroundTransparency = 1
	natScroll.ScrollBarThickness = 2
	natScroll.ScrollBarImageColor3 = C_BORDER_H
	natScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	natScroll.ZIndex = 33
	natScroll.Visible = true
	natScroll.Parent = rightArea
	self._natScroll = natScroll

	local nl = Instance.new("UIListLayout")
	nl.Padding = UDim.new(0, 3)
	nl.SortOrder = Enum.SortOrder.LayoutOrder
	nl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	nl.Parent = natScroll

	local regScroll = Instance.new("ScrollingFrame")
	regScroll.Name = "RegScroll"
	regScroll.Size = UDim2.new(1, -10, 0, SCROLL_H)
	regScroll.Position = UDim2.new(0, 6, 0, SCROLL_TOP)
	regScroll.BackgroundTransparency = 1
	regScroll.ScrollBarThickness = 2
	regScroll.ScrollBarImageColor3 = C_BORDER_H
	regScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	regScroll.ZIndex = 33
	regScroll.Visible = false
	regScroll.Parent = rightArea
	self._regScroll = regScroll

	local rl = Instance.new("UIListLayout")
	rl.Padding = UDim.new(0, 3)
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rl.Parent = regScroll
end

-- ── Nav helpers ───────────────────────────────────────────────────────

function TeamSelectMenu:_makeNavSectionLabel(parent, text, yPos)
	local label = Instance.new("TextLabel")
	label.Name = "Label_" .. text
	label.Size = UDim2.new(1, -PAD * 2, 0, 14)
	label.Position = UDim2.new(0, PAD, 0, yPos)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = C_DIM
	label.Font = Enum.Font.GothamBold
	label.TextSize = 8
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 33
	label.Parent = parent
end

-- Returns: hitBtn, nameL, subL, iconImg, stroke
function TeamSelectMenu:_makeNavCard(parent, yPos, cardH)
	local frame = Instance.new("Frame")
	frame.Name = "NavCard"
	frame.Size = UDim2.new(1, -PAD * 2, 0, cardH)
	frame.Position = UDim2.new(0, PAD, 0, yPos)
	frame.BackgroundColor3 = C_RAISED
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel = 0
	frame.ZIndex = 33
	frame.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = C_BORDER
	stroke.Thickness = 1
	stroke.Transparency = 0
	stroke.Parent = frame

	-- Flag / swatch area (small, left-aligned)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.Size = UDim2.new(0, 28, 0, 20)
	icon.Position = UDim2.new(0, 8, 0.5, -10)
	icon.BackgroundColor3 = C_BORDER
	icon.BackgroundTransparency = 0
	icon.Image = ""
	icon.ZIndex = 34
	icon.Parent = frame

	local nameL = Instance.new("TextLabel")
	nameL.Name = "Title"
	nameL.Size = UDim2.new(1, -50, 0, 16)
	nameL.Position = UDim2.new(0, 44, 0, math.floor((cardH - 28) / 2))
	nameL.BackgroundTransparency = 1
	nameL.Text = "—"
	nameL.TextColor3 = C_DIM
	nameL.Font = Enum.Font.GothamBold
	nameL.TextSize = 10
	nameL.TextXAlignment = Enum.TextXAlignment.Left
	nameL.TextTruncate = Enum.TextTruncate.AtEnd
	nameL.ZIndex = 34
	nameL.Parent = frame

	local subL = Instance.new("TextLabel")
	subL.Name = "Subtitle"
	subL.Size = UDim2.new(1, -50, 0, 11)
	subL.Position = UDim2.new(0, 44, 0, math.floor((cardH - 28) / 2) + 17)
	subL.BackgroundTransparency = 1
	subL.Text = ""
	subL.TextColor3 = C_DIM
	subL.Font = Enum.Font.Gotham
	subL.TextSize = 8
	subL.TextXAlignment = Enum.TextXAlignment.Left
	subL.TextTruncate = Enum.TextTruncate.AtEnd
	subL.ZIndex = 34
	subL.Parent = frame

	local hitBtn = Instance.new("TextButton")
	hitBtn.Name = "HitButton"
	hitBtn.Size = UDim2.new(1, 0, 1, 0)
	hitBtn.BackgroundTransparency = 1
	hitBtn.Text = ""
	hitBtn.ZIndex = 36
	hitBtn.Parent = frame

	frame.MouseEnter:Connect(function()
		TweenService:Create(frame, TI_FAST, {BackgroundColor3 = C_HOVER}):Play()
	end)
	frame.MouseLeave:Connect(function()
		TweenService:Create(frame, TI_FAST, {BackgroundColor3 = C_RAISED}):Play()
	end)

	return hitBtn, nameL, subL, icon, stroke
end

-- ── Right mode switching ──────────────────────────────────────────────

function TeamSelectMenu:_setRightMode(mode)
	self._rightMode = mode
	self._natScroll.Visible = (mode == "nations")
	self._regScroll.Visible = (mode == "regiments")
	self._rightModeLabel.Text = (mode == "nations") and "CHOOSE A NATION" or "CHOOSE A REGIMENT"

	local natSel = (mode == "nations")
	TweenService:Create(self._natNavStroke, TI_FAST, {
		Color = natSel and C_BORDER_H or C_BORDER,
	}):Play()
	TweenService:Create(self._regNavStroke, TI_FAST, {
		Color = (not natSel) and C_BORDER_H or C_BORDER,
	}):Play()
end

-- ── Populate nations ──────────────────────────────────────────────────

function TeamSelectMenu:_populateNations(sd)
	for _, ch in ipairs(self._natScroll:GetChildren()) do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	self._natRows = {}

	for i, nd in ipairs(sd.nations) do
		local row = Instance.new("Frame")
		row.Name = "NatRow" .. i
		row.Size = UDim2.new(1, -4, 0, 56)
		row.BackgroundColor3 = C_RAISED
		row.BackgroundTransparency = 0
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 34
		row.Parent = self._natScroll

		local rStroke = Instance.new("UIStroke")
		rStroke.Color = C_BORDER
		rStroke.Thickness = 1
		rStroke.Transparency = 0
		rStroke.Parent = row

		local flagImg = Instance.new("ImageLabel")
		flagImg.Size = UDim2.new(0, 38, 0, 28)
		flagImg.Position = UDim2.new(0, 12, 0.5, -14)
		flagImg.BackgroundTransparency = 1
		flagImg.Image = nd.flag
		flagImg.ZIndex = 35
		flagImg.Parent = row

		local nName = Instance.new("TextLabel")
		nName.Size = UDim2.new(1, -64, 0, 18)
		nName.Position = UDim2.new(0, 58, 0, 10)
		nName.BackgroundTransparency = 1
		nName.Text = nd.name
		nName.TextColor3 = C_TEXT
		nName.Font = Enum.Font.GothamBold
		nName.TextSize = 12
		nName.TextXAlignment = Enum.TextXAlignment.Left
		nName.ZIndex = 35
		nName.Parent = row

		local nSub = Instance.new("TextLabel")
		nSub.Size = UDim2.new(1, -64, 0, 12)
		nSub.Position = UDim2.new(0, 58, 0, 30)
		nSub.BackgroundTransparency = 1
		nSub.Text = nd.subtitle
		nSub.TextColor3 = C_DIM
		nSub.Font = Enum.Font.Gotham
		nSub.TextSize = 9
		nSub.TextXAlignment = Enum.TextXAlignment.Left
		nSub.ZIndex = 35
		nSub.Parent = row

		local clickBtn = Instance.new("TextButton")
		clickBtn.Size = UDim2.new(1, 0, 1, 0)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.ZIndex = 37
		clickBtn.Parent = row

		clickBtn.MouseEnter:Connect(function()
			if self._selectedNation ~= nd then
				TweenService:Create(row, TI_FAST, {BackgroundColor3 = C_HOVER}):Play()
			end
		end)
		clickBtn.MouseLeave:Connect(function()
			if self._selectedNation ~= nd then
				TweenService:Create(row, TI_FAST, {BackgroundColor3 = C_RAISED}):Play()
			end
		end)
		clickBtn.MouseButton1Click:Connect(function()
			self:_onNationSelected(nd)
		end)

		self._natRows[i] = { row = row, stroke = rStroke, data = nd }
	end
end

-- ── Populate regiments ────────────────────────────────────────────────

function TeamSelectMenu:_populateRegiments(nd)
	for _, ch in ipairs(self._regScroll:GetChildren()) do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	self._regRows = {}

	for i, rd in ipairs(nd.regiments) do
		local row = Instance.new("Frame")
		row.Name = "RegRow" .. i
		row.Size = UDim2.new(1, -4, 0, 66)
		row.BackgroundColor3 = C_RAISED
		row.BackgroundTransparency = 0
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.ZIndex = 34
		row.Parent = self._regScroll

		local rStroke = Instance.new("UIStroke")
		rStroke.Color = C_BORDER
		rStroke.Thickness = 1
		rStroke.Transparency = 0
		rStroke.Parent = row

		-- Regiment color as a thin vertical swatch bar
		local sw = Instance.new("Frame")
		sw.Size = UDim2.new(0, 3, 1, -20)
		sw.Position = UDim2.new(0, 10, 0, 10)
		sw.BackgroundColor3 = rd.color
		sw.BorderSizePixel = 0
		sw.ZIndex = 35
		sw.Parent = row

		local rName = Instance.new("TextLabel")
		rName.Size = UDim2.new(1, -30, 0, 22)
		rName.Position = UDim2.new(0, 22, 0, 10)
		rName.BackgroundTransparency = 1
		rName.Text = rd.name
		rName.TextColor3 = C_TEXT
		rName.Font = Enum.Font.GothamBold
		rName.TextSize = 11
		rName.TextXAlignment = Enum.TextXAlignment.Left
		rName.TextWrapped = true
		rName.ZIndex = 35
		rName.Parent = row

		local rDesc = Instance.new("TextLabel")
		rDesc.Size = UDim2.new(1, -30, 0, 18)
		rDesc.Position = UDim2.new(0, 22, 0, 38)
		rDesc.BackgroundTransparency = 1
		rDesc.Text = rd.desc
		rDesc.TextColor3 = C_DIM
		rDesc.Font = Enum.Font.Gotham
		rDesc.TextSize = 9
		rDesc.TextXAlignment = Enum.TextXAlignment.Left
		rDesc.TextWrapped = true
		rDesc.ZIndex = 35
		rDesc.Parent = row

		local clickBtn = Instance.new("TextButton")
		clickBtn.Size = UDim2.new(1, 0, 1, 0)
		clickBtn.BackgroundTransparency = 1
		clickBtn.Text = ""
		clickBtn.ZIndex = 37
		clickBtn.Parent = row

		clickBtn.MouseEnter:Connect(function()
			if self._selectedRegiment ~= rd then
				TweenService:Create(row, TI_FAST, {BackgroundColor3 = C_HOVER}):Play()
			end
		end)
		clickBtn.MouseLeave:Connect(function()
			if self._selectedRegiment ~= rd then
				TweenService:Create(row, TI_FAST, {BackgroundColor3 = C_RAISED}):Play()
			end
		end)
		clickBtn.MouseButton1Click:Connect(function()
			self:_onRegimentSelected(rd, i)
		end)

		self._regRows[i] = { row = row, stroke = rStroke, data = rd }
	end
end

-- ── Selection handlers ────────────────────────────────────────────────

function TeamSelectMenu:_onSideSelected(sd, sideIdx)
	self._selectedSide        = sd
	self._selectedSideIdx     = sideIdx
	self._selectedNation      = nil
	self._selectedRegiment    = nil
	self._selectedRegimentIdx = nil

	self._headerLabel.Text = sd.role .. "  ·  " .. sd.name

	-- Reset nation nav card
	self._natNavName.Text = "—"
	self._natNavName.TextColor3 = C_DIM
	self._natNavSub.Text = "Select a nation"
	self._natNavIcon.Image = ""
	self._natNavIcon.BackgroundColor3 = C_BORDER
	self._natNavIcon.BackgroundTransparency = 0

	-- Reset regiment nav card
	self._regNavName.Text = "—"
	self._regNavName.TextColor3 = C_DIM
	self._regNavSub.Text = "Choose a nation first"
	self._regNavSwatch.BackgroundColor3 = C_BORDER
	self._regNavSwatch.BackgroundTransparency = 0

	-- Reset deploy button to inactive
	self._deployBtn.TextColor3 = C_DIM
	TweenService:Create(self._deployStroke, TI_FAST, {Color = C_BORDER}):Play()

	self:_populateNations(sd)
	self:_setRightMode("nations")
	self:_transitionToLoadoutScreen()
end

function TeamSelectMenu:_onNationSelected(nd)
	for _, rdata in ipairs(self._natRows) do
		local sel = (rdata.data == nd)
		TweenService:Create(rdata.row, TI_FAST, {BackgroundColor3 = sel and C_HOVER or C_RAISED}):Play()
		TweenService:Create(rdata.stroke, TI_FAST, {Color = sel and C_BORDER_H or C_BORDER}):Play()
	end

	self._selectedNation      = nd
	self._selectedRegiment    = nil
	self._selectedRegimentIdx = nil

	self._natNavName.Text = nd.name
	self._natNavName.TextColor3 = C_TEXT
	self._natNavSub.Text = nd.subtitle
	self._natNavIcon.Image = nd.flag
	self._natNavIcon.BackgroundTransparency = 0

	self:_populateRegiments(nd)
	self._regNavSub.Text = "Select a regiment"
end

function TeamSelectMenu:_onRegimentSelected(rd, regIdx)
	local side = self._selectedSide
	if not side then return end

	-- Compute global regiment index across all nations in this side
	local globalIdx = 0
	for _, nation in ipairs(side.nations) do
		if nation == self._selectedNation then break end
		globalIdx += #nation.regiments
	end

	self._selectedRegiment    = rd
	self._selectedRegimentIdx = globalIdx + regIdx

	for _, rdata in ipairs(self._regRows) do
		local sel = (rdata.data == rd)
		TweenService:Create(rdata.row, TI_FAST, {BackgroundColor3 = sel and C_HOVER or C_RAISED}):Play()
		TweenService:Create(rdata.stroke, TI_FAST, {Color = sel and C_BORDER_H or C_BORDER}):Play()
	end

	self._regNavName.Text = rd.name
	self._regNavName.TextColor3 = C_TEXT
	self._regNavSub.Text = rd.desc
	self._regNavSwatch.BackgroundColor3 = rd.color
	self._regNavSwatch.BackgroundTransparency = 0

	-- Activate deploy button
	self._deployBtn.TextColor3 = C_TEXT
	TweenService:Create(self._deployStroke, TI_FAST, {Color = C_BORDER_H}):Play()
end

-- ── Deploy ────────────────────────────────────────────────────────────

function TeamSelectMenu:_deploy()
	local si = self._selectedSideIdx
	local ri = self._selectedRegimentIdx
	if not si or not ri then return end

	-- Brief visual feedback
	self._deployBtn.TextColor3 = C_SEL
	task.delay(0.4, function()
		if self._deployBtn and self._deployBtn.Parent then
			self._deployBtn.TextColor3 = C_TEXT
		end
	end)

	self._network.TeamRegimentSelect.Fire(si, ri)
	task.delay(0.45, function() self:hide() end)
end

-- ── Transitions ───────────────────────────────────────────────────────

function TeamSelectMenu:_transitionToLoadoutScreen()
	self._sideScreen.Visible = false
	self._loadoutScreen.Visible = true
	self._loadoutPanel.Position = UDim2.new(0.5, 0, 1.5, 0)
	TweenService:Create(self._loadoutPanel, TI_IN, {Position = UDim2.new(0.5, 0, 0.5, 0)}):Play()
end

function TeamSelectMenu:_transitionToSideScreen()
	self._sideScreen.Visible = true
	TweenService:Create(self._loadoutPanel, TI_OUT, {Position = UDim2.new(0.5, 0, 1.5, 0)}):Play()
	task.delay(0.18, function()
		if self._loadoutScreen then
			self._loadoutScreen.Visible = false
		end
	end)
end

-- ── Public API ────────────────────────────────────────────────────────

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
		local t = TweenService:Create(self._loadoutPanel, TI_OUT, {Position = UDim2.new(0.5, 0, 1.5, 0)})
		t.Completed:Connect(function()
			if self._gui then self._gui.Enabled = false end
		end)
		t:Play()
	else
		task.delay(0.18, function()
			if self._gui then self._gui.Enabled = false end
		end)
	end
end

return TeamSelectMenu
