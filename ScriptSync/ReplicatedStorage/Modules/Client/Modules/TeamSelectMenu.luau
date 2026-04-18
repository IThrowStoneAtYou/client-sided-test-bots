-->>>>>>>>>>>>
-- TeamSelectMenu
-- Version 2.0.0
--
-- Flow:
--   show()
--     → camera locked to workspace.menu_cam_pos
--     → SideScreen fades in (ATTACKERS | DEFENDERS)
--   Side clicked
--     → SideScreen fades out
--     → LoadoutScreen slides up (Nations → Regiments → Deploy)
--   Back pressed
--     → LoadoutScreen slides down
--     → SideScreen fades back
--   Deploy pressed
--     → Network.TeamRegimentSelect.Fire(sideIndex, regimentKey)
--     → hide()
-->>>>>>>>>>>>

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")

-- ── Side / Nation / Regiment data ────────────────────────────────────
-- sideIndex 1 = Attacker (France), 2 = Defender (Britain)
-- This is passed directly to Network.TeamRegimentSelect so the server
-- can resolve the team the same way as before.
local SIDES = {
	[1] = {
		key    = "attacker",
		role   = "ATTACKERS",
		name   = "FRANCE & ALLIES",
		accent = Color3.fromRGB(55,  100, 220),
		dim    = Color3.fromRGB(12,  22,  80),
		nations = {
			{
				key      = "france",
				name     = "France",
				subtitle = "République Française",
				flag     = "rbxassetid://139065210013036",
				regiments = {
					{
						key   = "1er_ligne",
						name  = "1er Régiment d'Infanterie de Ligne",
						desc  = "Premier regiment of Napoleon's Grande Armée",
						color = Color3.fromRGB(55, 100, 220),
					},
					
					{
						key   = "2er_ligne",
						name  = "2er Régiment d'Infanterie de Ligne",
						desc  = "Premier regiment of Napoleon's Grande Armée",
						color = Color3.fromRGB(55, 100, 220),
					},
				},
			},
		},
	},
	[2] = {
		key    = "defender",
		role   = "DEFENDERS",
		name   = "GREAT BRITAIN & ALLIES",
		accent = Color3.fromRGB(210, 50,  50),
		dim    = Color3.fromRGB(80,  10,  10),
		nations = {
			{
				key      = "britain",
				name     = "Great Britain",
				subtitle = "United Kingdom of Great Britain",
				flag     = "rbxassetid://88813497029040",
				regiments = {
					{
						key   = "23rd_foot",
						name  = "23rd Regiment of Foot",
						desc  = "The Royal Welch Fusiliers, steadfast redcoat infantry",
						color = Color3.fromRGB(210, 50, 50),
					},
				},
			},
		},
	},
}

-- ── Palette ───────────────────────────────────────────────────────────
local C_BG    = Color3.fromRGB(6,   6,   10)
local C_PANEL = Color3.fromRGB(11,  11,  18)
local C_CARD  = Color3.fromRGB(15,  15,  24)
local C_ROW   = Color3.fromRGB(20,  20,  33)
local C_GOLD  = Color3.fromRGB(190, 155, 70)
local C_TEXT  = Color3.fromRGB(215, 210, 195)
local C_DIM   = Color3.fromRGB(110, 108, 100)
local C_SEP   = Color3.fromRGB(35,  35,  55)

-- ── Tween infos ───────────────────────────────────────────────────────
local TI_FAST      = TweenInfo.new(0.14, Enum.EasingStyle.Linear)
local TI_MED       = TweenInfo.new(0.22, Enum.EasingStyle.Linear)
local TI_SLIDE_IN  = TweenInfo.new(0.32, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TI_SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

local PAD           = 14
local NAT_ROW_H     = 58
local REG_ROW_H     = 88
local NAT_ROW_GAP   = 6
local REG_ROW_GAP   = 6
local CONTENT_START = 62   -- px below header where content begins
local SEC_LABEL_H   = 22

local localPlayer = Players.LocalPlayer

-- ── UI helpers ────────────────────────────────────────────────────────
local function mkCorner(parent, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent       = parent
	return c
end

local function mkStroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color        = color
	s.Thickness    = thickness
	s.Transparency = transparency
	s.Parent       = parent
	return s
end

local function mkFrame(parent, props)
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 0
	f.BorderSizePixel        = 0
	for k, v in pairs(props) do (f :: any)[k] = v end
	f.Parent = parent
	return f
end

local function mkLabel(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel        = 0
	l.Font                   = Enum.Font.GothamBold
	l.TextColor3             = C_TEXT
	for k, v in pairs(props) do (l :: any)[k] = v end
	l.Parent = parent
	return l
end

local function mkButton(parent, props)
	local b = Instance.new("TextButton")
	b.BackgroundTransparency = 1
	b.BorderSizePixel        = 0
	b.Text                   = ""
	for k, v in pairs(props) do (b :: any)[k] = v end
	b.Parent = parent
	return b
end

local function mkImage(parent, props)
	local i = Instance.new("ImageLabel")
	i.BackgroundTransparency = 1
	i.BorderSizePixel        = 0
	for k, v in pairs(props) do (i :: any)[k] = v end
	i.Parent = parent
	return i
end

-- ── Module ────────────────────────────────────────────────────────────
local TeamSelectMenu = {}
TeamSelectMenu.__index = TeamSelectMenu

function TeamSelectMenu.new(Network)
	local self = setmetatable({}, TeamSelectMenu)
	self._network          = Network
	self._selectedSide     = nil  -- side data
	self._selectedSideIdx  = nil  -- 1 or 2
	self._selectedNation   = nil  -- nation data
	self._selectedRegiment = nil  -- regiment data

	self._camConn      = nil
	self._savedCamType = nil
	self._natRows      = {}
	self._regRows      = {}

	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name           = "TeamSelectMenu"
	gui.ResetOnSpawn   = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.Enabled        = false
	gui.Parent         = playerGui
	self._gui          = gui

	self:_buildSideScreen()
	self:_buildLoadoutScreen()

	return self
end

-- ─────────────────────────────────────────────────────────────────────
-- Camera
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_lockCamera()
	local cam          = workspace.CurrentCamera
	self._savedCamType = cam.CameraType
	cam.CameraType     = Enum.CameraType.Scriptable

	if self._camConn then self._camConn:Disconnect() end

	-- Re-apply every frame so cinematic/moving camera parts work too
	self._camConn = RunService.RenderStepped:Connect(function()
		local ref = workspace:FindFirstChild("menu_cam_pos")
		if not ref then return end
		if ref:IsA("BasePart")    then cam.CFrame = ref.CFrame end
		if ref:IsA("CFrameValue") then cam.CFrame = ref.Value  end
	end)
end

function TeamSelectMenu:_unlockCamera()
	if self._camConn then
		self._camConn:Disconnect()
		self._camConn = nil
	end
	workspace.CurrentCamera.CameraType = self._savedCamType or Enum.CameraType.Custom
end

-- ─────────────────────────────────────────────────────────────────────
-- Side Selection Screen
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_buildSideScreen()
	local gui = self._gui

	local root = mkFrame(gui, {
		Name                   = "SideScreen",
		Size                   = UDim2.new(1, 0, 1, 0),
		BackgroundColor3       = C_BG,
		BackgroundTransparency = 1,
		ZIndex                 = 10,
	})
	self._sideScreen = root

	-- Gold bars top + bottom
	for _, pos in ipairs({ UDim2.new(0,0,0,0), UDim2.new(0,0,1,-2) }) do
		mkFrame(root, {
			Size             = UDim2.new(1,0,0,2),
			Position         = pos,
			BackgroundColor3 = C_GOLD,
			BackgroundTransparency = 0.35,
			ZIndex           = 11,
		})
	end

	-- Header
	mkLabel(root, {
		Size           = UDim2.new(1,0,0,18),
		Position       = UDim2.new(0,0,0,24),
		Text           = "— SELECT YOUR SIDE —",
		TextColor3     = C_GOLD,
		Font           = Enum.Font.GothamBold,
		TextSize       = 11,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex         = 12,
	})
	mkLabel(root, {
		Size           = UDim2.new(1,0,0,38),
		Position       = UDim2.new(0,0,0,40),
		Text           = "CHOOSE YOUR ALLEGIANCE",
		TextColor3     = C_TEXT,
		Font           = Enum.Font.GothamBlack,
		TextSize       = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex         = 12,
	})

	-- Cards container
	local CARD_W, CARD_H = 390, 400
	local holder = mkFrame(root, {
		Name                   = "CardsHolder",
		Size                   = UDim2.new(0, CARD_W*2 + 30, 0, CARD_H),
		AnchorPoint            = Vector2.new(0.5, 0.5),
		Position               = UDim2.new(0.5, 0, 0.5, 14),
		BackgroundTransparency = 1,
		ZIndex                 = 12,
	})

	-- Center divider line
	mkFrame(holder, {
		Size             = UDim2.new(0, 1, 0, CARD_H - 40),
		AnchorPoint      = Vector2.new(0.5, 0.5),
		Position         = UDim2.new(0.5, 0, 0.5, 0),
		BackgroundColor3 = C_GOLD,
		BackgroundTransparency = 0.55,
		ZIndex           = 14,
	})

	-- VS badge
	local vsBadge = mkFrame(holder, {
		Size             = UDim2.new(0, 40, 0, 40),
		AnchorPoint      = Vector2.new(0.5, 0.5),
		Position         = UDim2.new(0.5, 0, 0.5, 0),
		BackgroundColor3 = C_GOLD,
		BackgroundTransparency = 0.06,
		ZIndex           = 15,
	})
	mkCorner(vsBadge, 20)
	mkLabel(vsBadge, {
		Size           = UDim2.new(1,0,1,0),
		Text           = "VS",
		TextColor3     = C_BG,
		Font           = Enum.Font.GothamBlack,
		TextSize       = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex         = 16,
	})

	-- Build each side card
	self._sideCardVisuals = {}

	for sideIdx, sd in ipairs(SIDES) do
		local isLeft  = (sideIdx == 1)
		local cardPos = isLeft
			and UDim2.new(0, 0, 0, 0)
			or  UDim2.new(0.5, 15, 0, 0)

		local card = mkFrame(holder, {
			Name                   = "Card_" .. sd.key,
			Size                   = UDim2.new(0.5, -15, 1, 0),
			Position               = cardPos,
			BackgroundColor3       = sd.dim,
			BackgroundTransparency = 0.15,
			ZIndex                 = 13,
		})
		mkCorner(card, 10)
		local cStroke = mkStroke(card, sd.accent, 1.5, 0.65)

		-- Gradient atmosphere
		local gradOver = mkFrame(card, {
			Size                   = UDim2.new(1,0,1,0),
			BackgroundColor3       = sd.accent,
			BackgroundTransparency = 0.80,
			ZIndex                 = 13,
		})
		mkCorner(gradOver, 10)
		local g = Instance.new("UIGradient")
		g.Rotation    = isLeft and 130 or 50
		g.Color       = ColorSequence.new(Color3.new(1,1,1), Color3.new(0,0,0))
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.0),
			NumberSequenceKeypoint.new(1, 0.9),
		})
		g.Parent = gradOver

		-- Top accent bar
		local topBar = mkFrame(card, {
			Size             = UDim2.new(1,0,0,4),
			BackgroundColor3 = sd.accent,
			ZIndex           = 14,
		})
		mkCorner(topBar, 4)

		-- Role badge (small caps)
		mkLabel(card, {
			Size           = UDim2.new(1,-16,0,16),
			Position       = UDim2.new(0,8,0,12),
			Text           = sd.role,
			TextColor3     = sd.accent,
			Font           = Enum.Font.GothamBold,
			TextSize       = 10,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex         = 14,
		})

		-- Large role text
		mkLabel(card, {
			Size           = UDim2.new(1,-16,0,68),
			Position       = UDim2.new(0,8,0,30),
			Text           = sd.role,
			TextColor3     = C_TEXT,
			Font           = Enum.Font.GothamBlack,
			TextScaled     = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			ZIndex         = 14,
		})

		-- Thin separator
		mkFrame(card, {
			Size             = UDim2.new(1,-30,0,1),
			Position         = UDim2.new(0,15,0,106),
			BackgroundColor3 = sd.accent,
			BackgroundTransparency = 0.6,
			ZIndex           = 14,
		})

		-- Faction name
		mkLabel(card, {
			Size           = UDim2.new(1,-16,0,26),
			Position       = UDim2.new(0,8,0,114),
			Text           = sd.name,
			TextColor3     = C_TEXT,
			Font           = Enum.Font.GothamBold,
			TextSize       = 12,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate   = Enum.TextTruncate.AtEnd,
			ZIndex         = 14,
		})

		-- Nation preview rows (non-interactive, just informational)
		local ny = 148
		for _, nd in ipairs(sd.nations) do
			local natPrev = mkFrame(card, {
				Size             = UDim2.new(1,-16,0,32),
				Position         = UDim2.new(0,8,0,ny),
				BackgroundColor3 = C_ROW,
				BackgroundTransparency = 0.45,
				ZIndex           = 14,
			})
			mkCorner(natPrev, 5)
			mkImage(natPrev, {
				Size     = UDim2.new(0,26,0,26),
				Position = UDim2.new(0,6,0.5,-13),
				Image    = nd.flag,
				ZIndex   = 15,
			})
			mkLabel(natPrev, {
				Size           = UDim2.new(1,-44,1,0),
				Position       = UDim2.new(0,40,0,0),
				Text           = nd.name,
				TextColor3     = C_DIM,
				Font           = Enum.Font.Gotham,
				TextSize       = 10,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex         = 15,
			})
			ny += 36
		end

		-- SELECT button (anchored to bottom)
		local selBtn = Instance.new("TextButton")
		selBtn.Size                   = UDim2.new(1,-16,0,46)
		selBtn.AnchorPoint            = Vector2.new(0,1)
		selBtn.Position               = UDim2.new(0,8,1,-8)
		selBtn.BackgroundColor3       = sd.accent
		selBtn.BackgroundTransparency = 0.28
		selBtn.Text                   = "SELECT  ›"
		selBtn.TextColor3             = Color3.new(1,1,1)
		selBtn.Font                   = Enum.Font.GothamBold
		selBtn.TextSize               = 13
		selBtn.ZIndex                 = 16
		selBtn.Parent                 = card
		mkCorner(selBtn, 8)
		mkStroke(selBtn, sd.accent, 1.5, 0.45)

		-- Hover effects
		card.MouseEnter:Connect(function()
			TweenService:Create(cStroke, TI_FAST, { Transparency = 0.1, Color = sd.accent }):Play()
			TweenService:Create(card,    TI_FAST, { BackgroundTransparency = 0.05 }):Play()
		end)
		card.MouseLeave:Connect(function()
			TweenService:Create(cStroke, TI_FAST, { Transparency = 0.65, Color = sd.accent }):Play()
			TweenService:Create(card,    TI_FAST, { BackgroundTransparency = 0.15 }):Play()
		end)
		selBtn.MouseEnter:Connect(function()
			TweenService:Create(selBtn, TI_FAST, { BackgroundTransparency = 0.05 }):Play()
		end)
		selBtn.MouseLeave:Connect(function()
			TweenService:Create(selBtn, TI_FAST, { BackgroundTransparency = 0.28 }):Play()
		end)

		-- Click the button OR top area of card
		local function onSelect()
			self:_onSideSelected(sd, sideIdx)
		end
		selBtn.MouseButton1Click:Connect(onSelect)

		-- Invisible hit area over the top portion of the card (above the select btn)
		mkButton(card, {
			Size                   = UDim2.new(1,0,1,-62),
			BackgroundTransparency = 1,
			ZIndex                 = 17,
		}).MouseButton1Click:Connect(onSelect)

		self._sideCardVisuals[sideIdx] = { card = card, stroke = cStroke, data = sd }
	end

	-- Bottom hint
	mkLabel(root, {
		Size           = UDim2.new(1,0,0,16),
		AnchorPoint    = Vector2.new(0,1),
		Position       = UDim2.new(0,0,1,-14),
		Text           = "Choose your allegiance to begin",
		TextColor3     = C_DIM,
		Font           = Enum.Font.Gotham,
		TextSize       = 10,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex         = 12,
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- Loadout Screen  (Nations + Regiments + Deploy)
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_buildLoadoutScreen()
	local gui = self._gui

	-- Full-screen backing (dark overlay)
	local root = mkFrame(gui, {
		Name                   = "LoadoutScreen",
		Size                   = UDim2.new(1,0,1,0),
		BackgroundColor3       = Color3.new(0,0,0),
		BackgroundTransparency = 0.45,
		ZIndex                 = 30,
		Visible                = false,
	})
	self._loadoutScreen = root

	-- Compute panel height from contents
	local natBlockH  = SEC_LABEL_H + 4 + NAT_ROW_H              -- 1 nation row
	local regBlockH  = SEC_LABEL_H + 4 + REG_ROW_H              -- 1 regiment row
	local PANEL_H    = CONTENT_START + natBlockH + 20 + regBlockH + 16 + 50 + 16

	local panel = mkFrame(root, {
		Name                   = "Panel",
		Size                   = UDim2.new(0,630,0,PANEL_H),
		AnchorPoint            = Vector2.new(0.5,0.5),
		Position               = UDim2.new(0.5,0,1.4,0),   -- starts off-screen below
		BackgroundColor3       = C_PANEL,
		BackgroundTransparency = 0.04,
		ZIndex                 = 31,
	})
	mkCorner(panel, 12)
	self._loadoutPanel  = panel
	self._loadoutStroke = mkStroke(panel, C_GOLD, 1.5, 0.7)

	-- ── Header ────────────────────────────────────────────────────────
	local header = mkFrame(panel, {
		Size             = UDim2.new(1,0,0,54),
		BackgroundColor3 = C_CARD,
		BackgroundTransparency = 0.08,
		ZIndex           = 32,
	})
	mkCorner(header, 12)
	-- Patch bottom corners of header
	mkFrame(header, {
		Size             = UDim2.new(1,0,0,12),
		Position         = UDim2.new(0,0,1,-12),
		BackgroundColor3 = C_CARD,
		BackgroundTransparency = 0.08,
		ZIndex           = 32,
	})

	-- Accent bar at very top of header
	self._headerAccentBar = mkFrame(header, {
		Size             = UDim2.new(1,0,0,3),
		BackgroundColor3 = C_GOLD,
		ZIndex           = 33,
	})

	self._headerLabel = mkLabel(header, {
		Size           = UDim2.new(1,-130,1,0),
		Position       = UDim2.new(0,65,0,0),
		Text           = "—",
		TextColor3     = C_TEXT,
		Font           = Enum.Font.GothamBold,
		TextSize       = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex         = 33,
	})

	-- Back button
	local backBtn = Instance.new("TextButton")
	backBtn.Size                   = UDim2.new(0,58,0,34)
	backBtn.Position               = UDim2.new(0,8,0.5,-17)
	backBtn.BackgroundColor3       = C_ROW
	backBtn.BackgroundTransparency = 0.38
	backBtn.Text                   = "‹  BACK"
	backBtn.TextColor3             = C_DIM
	backBtn.Font                   = Enum.Font.GothamBold
	backBtn.TextSize               = 10
	backBtn.ZIndex                 = 34
	backBtn.Parent                 = header
	mkCorner(backBtn, 5)

	backBtn.MouseEnter:Connect(function()
		TweenService:Create(backBtn, TI_FAST, { TextColor3 = C_TEXT }):Play()
	end)
	backBtn.MouseLeave:Connect(function()
		TweenService:Create(backBtn, TI_FAST, { TextColor3 = C_DIM }):Play()
	end)
	backBtn.MouseButton1Click:Connect(function()
		self:_transitionToSideScreen()
	end)

	-- ── NATIONS section ───────────────────────────────────────────────
	local natTop = CONTENT_START

	self:_buildSectionLabel(panel, "NATION", natTop)

	self._natContainer = mkFrame(panel, {
		Name                   = "NatContainer",
		Size                   = UDim2.new(1,-PAD*2,0,NAT_ROW_H),
		Position               = UDim2.new(0,PAD,0,natTop + SEC_LABEL_H + 4),
		BackgroundTransparency = 1,
		ZIndex                 = 32,
	})

	-- ── REGIMENT section ──────────────────────────────────────────────
	local regTop = natTop + SEC_LABEL_H + 4 + NAT_ROW_H + 20

	self:_buildSectionLabel(panel, "REGIMENT", regTop)

	self._regContainer = mkFrame(panel, {
		Name                   = "RegContainer",
		Size                   = UDim2.new(1,-PAD*2,0,REG_ROW_H),
		Position               = UDim2.new(0,PAD,0,regTop + SEC_LABEL_H + 4),
		BackgroundTransparency = 1,
		ZIndex                 = 32,
	})

	-- ── Deploy button ─────────────────────────────────────────────────
	local deployBtn = Instance.new("TextButton")
	deployBtn.Name                   = "DeployBtn"
	deployBtn.Size                   = UDim2.new(1,-PAD*2,0,50)
	deployBtn.AnchorPoint            = Vector2.new(0,1)
	deployBtn.Position               = UDim2.new(0,PAD,1,-12)
	deployBtn.BackgroundColor3       = C_GOLD
	deployBtn.BackgroundTransparency = 0.25
	deployBtn.Text                   = "⚑  SELECT A SIDE TO DEPLOY"
	deployBtn.TextColor3             = C_BG
	deployBtn.Font                   = Enum.Font.GothamBlack
	deployBtn.TextSize               = 13
	deployBtn.ZIndex                 = 33
	deployBtn.Parent                 = panel
	mkCorner(deployBtn, 8)
	self._deployBtn = deployBtn

	deployBtn.MouseEnter:Connect(function()
		if self._selectedRegiment then
			TweenService:Create(deployBtn, TI_FAST, { BackgroundTransparency = 0 }):Play()
		end
	end)
	deployBtn.MouseLeave:Connect(function()
		TweenService:Create(deployBtn, TI_FAST, { BackgroundTransparency = 0.25 }):Play()
	end)
	deployBtn.MouseButton1Click:Connect(function()
		if self._selectedRegiment then self:_deploy() end
	end)
end

-- ── Section label (gold text + separator line) ────────────────────────
function TeamSelectMenu:_buildSectionLabel(parent, text, yPos)
	local f = mkFrame(parent, {
		Size                   = UDim2.new(1,-PAD*2,0,SEC_LABEL_H),
		Position               = UDim2.new(0,PAD,0,yPos),
		BackgroundTransparency = 1,
		ZIndex                 = 32,
	})

	local LBL_W = 80   -- fixed label area width

	mkLabel(f, {
		Size           = UDim2.new(0,LBL_W,1,0),
		Text           = text,
		TextColor3     = C_GOLD,
		Font           = Enum.Font.GothamBold,
		TextSize       = 9,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex         = 33,
	})
	mkFrame(f, {
		Size             = UDim2.new(1,-LBL_W-6,0,1),
		Position         = UDim2.new(0,LBL_W+6,0.5,0),
		BackgroundColor3 = C_SEP,
		ZIndex           = 33,
	})
end

-- ─────────────────────────────────────────────────────────────────────
-- Populate nations
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_populateNations(sd)
	for _, ch in ipairs(self._natContainer:GetChildren()) do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	self._natRows = {}

	local totalH = #sd.nations * NAT_ROW_H + (#sd.nations - 1) * NAT_ROW_GAP
	self._natContainer.Size = UDim2.new(1,-PAD*2,0,totalH)

	for i, nd in ipairs(sd.nations) do
		local rowY = (i-1) * (NAT_ROW_H + NAT_ROW_GAP)

		local row = mkFrame(self._natContainer, {
			Size             = UDim2.new(1,0,0,NAT_ROW_H),
			Position         = UDim2.new(0,0,0,rowY),
			BackgroundColor3 = C_ROW,
			BackgroundTransparency = 0.35,
			ZIndex           = 33,
		})
		mkCorner(row, 7)
		local rStroke = mkStroke(row, C_SEP, 1, 0.2)

		-- Flag
		mkImage(row, {
			Size     = UDim2.new(0,40,0,40),
			Position = UDim2.new(0,10,0.5,-20),
			Image    = nd.flag,
			ZIndex   = 34,
		})

		-- Nation name
		mkLabel(row, {
			Size           = UDim2.new(1,-70,0,22),
			Position       = UDim2.new(0,62,0,7),
			Text           = nd.name,
			TextColor3     = C_TEXT,
			Font           = Enum.Font.GothamBold,
			TextSize       = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex         = 34,
		})
		-- Subtitle
		mkLabel(row, {
			Size           = UDim2.new(1,-70,0,16),
			Position       = UDim2.new(0,62,0,30),
			Text           = nd.subtitle,
			TextColor3     = C_DIM,
			Font           = Enum.Font.Gotham,
			TextSize       = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex         = 34,
		})

		-- Click surface
		local clickBtn = mkButton(row, { Size = UDim2.new(1,0,1,0), ZIndex = 36 })

		clickBtn.MouseEnter:Connect(function()
			if self._selectedNation ~= nd then
				TweenService:Create(row, TI_FAST, { BackgroundTransparency = 0.15 }):Play()
			end
		end)
		clickBtn.MouseLeave:Connect(function()
			if self._selectedNation ~= nd then
				TweenService:Create(row, TI_FAST, { BackgroundTransparency = 0.35 }):Play()
			end
		end)
		clickBtn.MouseButton1Click:Connect(function()
			self:_onNationSelected(nd)
		end)

		self._natRows[i] = { row = row, stroke = rStroke, data = nd }
	end

	-- Auto-select first nation
	self:_onNationSelected(sd.nations[1])
end

-- ─────────────────────────────────────────────────────────────────────
-- Populate regiments
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_populateRegiments(nd)
	for _, ch in ipairs(self._regContainer:GetChildren()) do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	self._regRows = {}

	local totalH = #nd.regiments * REG_ROW_H + (#nd.regiments - 1) * REG_ROW_GAP
	self._regContainer.Size = UDim2.new(1,-PAD*2,0,totalH)

	for i, rd in ipairs(nd.regiments) do
		local rowY = (i-1) * (REG_ROW_H + REG_ROW_GAP)

		local row = mkFrame(self._regContainer, {
			Size             = UDim2.new(1,0,0,REG_ROW_H),
			Position         = UDim2.new(0,0,0,rowY),
			BackgroundColor3 = C_ROW,
			BackgroundTransparency = 0.35,
			ZIndex           = 33,
		})
		mkCorner(row, 7)
		local rStroke = mkStroke(row, C_SEP, 1, 0.2)

		-- Left color swatch
		mkFrame(row, {
			Size             = UDim2.new(0,4,1,-18),
			Position         = UDim2.new(0,10,0,9),
			BackgroundColor3 = rd.color,
			ZIndex           = 34,
		})

		-- Regiment name (wraps if long)
		mkLabel(row, {
			Size           = UDim2.new(1,-30,0,40),
			Position       = UDim2.new(0,24,0,6),
			Text           = rd.name,
			TextColor3     = C_TEXT,
			Font           = Enum.Font.GothamBold,
			TextSize       = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped    = true,
			ZIndex         = 34,
		})
		-- Description
		mkLabel(row, {
			Size           = UDim2.new(1,-30,0,28),
			Position       = UDim2.new(0,24,0,48),
			Text           = rd.desc,
			TextColor3     = C_DIM,
			Font           = Enum.Font.Gotham,
			TextSize       = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped    = true,
			ZIndex         = 34,
		})

		local clickBtn = mkButton(row, { Size = UDim2.new(1,0,1,0), ZIndex = 36 })

		clickBtn.MouseEnter:Connect(function()
			if self._selectedRegiment ~= rd then
				TweenService:Create(row, TI_FAST, { BackgroundTransparency = 0.15 }):Play()
			end
		end)
		clickBtn.MouseLeave:Connect(function()
			if self._selectedRegiment ~= rd then
				TweenService:Create(row, TI_FAST, { BackgroundTransparency = 0.35 }):Play()
			end
		end)
		clickBtn.MouseButton1Click:Connect(function()
			self:_onRegimentSelected(rd)
		end)

		self._regRows[i] = { row = row, stroke = rStroke, data = rd }
	end

	-- Auto-select first regiment
	self:_onRegimentSelected(nd.regiments[1])
end

-- ─────────────────────────────────────────────────────────────────────
-- Selection logic
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_onSideSelected(sd, sideIdx)
	self._selectedSide     = sd
	self._selectedSideIdx  = sideIdx
	self._selectedNation   = nil
	self._selectedRegiment = nil

	-- Update loadout header
	self._headerLabel.Text                    = sd.role .. "  ·  " .. sd.name
	self._headerAccentBar.BackgroundColor3    = sd.accent
	self._loadoutStroke.Color                 = sd.accent
	self._loadoutStroke.Transparency          = 0.4
	self._deployBtn.BackgroundColor3          = sd.accent
	self._deployBtn.Text                      = "⚑  SELECT A REGIMENT TO DEPLOY"

	self:_populateNations(sd)
	self:_transitionToLoadoutScreen()
end

function TeamSelectMenu:_onNationSelected(nd)
	self._selectedNation   = nd
	self._selectedRegiment = nil
	local accentColor      = self._selectedSide and self._selectedSide.accent or C_GOLD

	-- Highlight nation rows
	for _, rdata in ipairs(self._natRows) do
		local sel = (rdata.data == nd)
		TweenService:Create(rdata.row, TI_FAST, {
			BackgroundTransparency = sel and 0.08 or 0.35,
		}):Play()
		TweenService:Create(rdata.stroke, TI_FAST, {
			Color        = sel and accentColor or C_SEP,
			Transparency = sel and 0           or 0.2,
		}):Play()
	end

	self:_populateRegiments(nd)
end

function TeamSelectMenu:_onRegimentSelected(rd)
	self._selectedRegiment = rd
	local accentColor = self._selectedSide and self._selectedSide.accent or C_GOLD

	-- Highlight regiment rows
	for _, rdata in ipairs(self._regRows) do
		local sel = (rdata.data == rd)
		TweenService:Create(rdata.row, TI_FAST, {
			BackgroundTransparency = sel and 0.08 or 0.35,
		}):Play()
		TweenService:Create(rdata.stroke, TI_FAST, {
			Color        = sel and accentColor or C_SEP,
			Transparency = sel and 0           or 0.2,
		}):Play()
	end

	-- Update deploy button label
	self._deployBtn.Text = "⚑  DEPLOY  —  " .. rd.name:upper()
end

-- ─────────────────────────────────────────────────────────────────────
-- Deploy
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_deploy()
	local si = self._selectedSideIdx
	local rd = self._selectedRegiment
	if not si or not rd then return end

	-- Flash green confirm then original accent
	local prevColor = self._selectedSide and self._selectedSide.accent or C_GOLD
	self._deployBtn.BackgroundColor3 = Color3.fromRGB(50, 170, 80)
	task.delay(0.4, function()
		if self._deployBtn and self._deployBtn.Parent then
			self._deployBtn.BackgroundColor3 = prevColor
		end
	end)

	-- sideIndex (1 or 2) matches the old ti convention
	self._network.TeamRegimentSelect.Fire(si, rd.key)

	task.delay(0.45, function()
		self:hide()
	end)
end

-- ─────────────────────────────────────────────────────────────────────
-- Screen transitions
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:_transitionToLoadoutScreen()
	-- Side screen fades out
	TweenService:Create(self._sideScreen, TI_MED, { BackgroundTransparency = 1 }):Play()

	-- Loadout panel slides up from below
	self._loadoutScreen.Visible  = true
	self._loadoutPanel.Position  = UDim2.new(0.5, 0, 1.4, 0)
	TweenService:Create(self._loadoutPanel, TI_SLIDE_IN, {
		Position = UDim2.new(0.5, 0, 0.5, 0),
	}):Play()
end

function TeamSelectMenu:_transitionToSideScreen()
	-- Loadout panel slides back down
	TweenService:Create(self._loadoutPanel, TI_SLIDE_OUT, {
		Position = UDim2.new(0.5, 0, 1.4, 0),
	}):Play()
	task.delay(0.22, function()
		if self._loadoutScreen then
			self._loadoutScreen.Visible = false
		end
	end)

	-- Side screen fades back in
	self._sideScreen.BackgroundTransparency = 1
	TweenService:Create(self._sideScreen, TI_MED, { BackgroundTransparency = 0 }):Play()
end

-- ─────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────

function TeamSelectMenu:show()
	self._gui.Enabled = true
	self:_lockCamera()

	-- Reset to side screen
	self._loadoutScreen.Visible               = false
	self._sideScreen.BackgroundTransparency   = 1
	TweenService:Create(self._sideScreen, TI_MED, { BackgroundTransparency = 0 }):Play()
end

function TeamSelectMenu:hide()
	self:_unlockCamera()

	TweenService:Create(self._sideScreen, TI_MED, { BackgroundTransparency = 1 }):Play()

	if self._loadoutScreen.Visible then
		local t = TweenService:Create(self._loadoutPanel, TI_SLIDE_OUT, {
			Position = UDim2.new(0.5, 0, 1.4, 0),
		})
		t.Completed:Connect(function()
			if self._gui then self._gui.Enabled = false end
		end)
		t:Play()
	else
		task.delay(0.22, function()
			if self._gui then self._gui.Enabled = false end
		end)
	end
end

return TeamSelectMenu
