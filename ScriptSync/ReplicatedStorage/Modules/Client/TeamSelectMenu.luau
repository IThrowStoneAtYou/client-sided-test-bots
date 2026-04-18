local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- ── Palette (matches existing HUDs) ──────────────────────────────────
local BG_OVERLAY  = Color3.fromRGB(0,   0,   0)
local PANEL_BG    = Color3.fromRGB(14,  14,  22)
local CARD_BG     = Color3.fromRGB(18,  18,  30)
local ROW_BG      = Color3.fromRGB(22,  22,  36)
local ACCENT      = Color3.fromRGB(100, 140, 255)
local TEXT_COLOR  = Color3.fromRGB(220, 220, 220)
local DIM_COLOR   = Color3.fromRGB(130, 130, 145)
local SEL_OUTLINE = Color3.fromRGB(100, 140, 255)

local FADE_INFO  = TweenInfo.new(0.18, Enum.EasingStyle.Linear)
local SLIDE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

-- ── Flag assets (reuse MatchHUD IDs) ─────────────────────────────────
local FLAG_GB = "rbxassetid://88813497029040"
local FLAG_FR = "rbxassetid://139065210013036"

-- ── Regiment definitions ──────────────────────────────────────────────
local TEAMS = {
	[1] = {
		name      = "GREAT BRITAIN & ALLIES",
		shortName = "TEAM I",
		flagAsset = FLAG_GB,
		barColor  = Color3.fromRGB(170, 0,  0),
		regiments = {
			{
				name  = "British Line Infantry",
				desc  = "Steadfast redcoats of the line battalions",
				color = Color3.fromRGB(180, 30,  30),
			},
			{
				name  = "95th Rifles",
				desc  = "Elite skirmishers armed with the Baker rifle",
				color = Color3.fromRGB(30,  110, 40),
			},
			{
				name  = "King's German Legion",
				desc  = "Battle-hardened German veterans in British service",
				color = Color3.fromRGB(40,  60,  180),
			},
			{
				name  = "Dutch-Belgian Brigade",
				desc  = "Allied Netherlands forces of the Low Countries",
				color = Color3.fromRGB(210, 130, 20),
			},
		},
	},
	[2] = {
		name      = "FRANCE & ALLIES",
		shortName = "TEAM II",
		flagAsset = FLAG_FR,
		barColor  = Color3.fromRGB(28, 42, 140),
		regiments = {
			{
				name  = "French Line Infantry",
				desc  = "The backbone of the mighty Grande Armée",
				color = Color3.fromRGB(30,  60,  190),
			},
			{
				name  = "Imperial Guard",
				desc  = "Napoleon's invincible veteran élite",
				color = Color3.fromRGB(20,  20,  90),
			},
			{
				name  = "Polish Lancers",
				desc  = "Ferocious cavalry, feared across Europe",
				color = Color3.fromRGB(160, 0,   0),
			},
			{
				name  = "Westphalian Infantry",
				desc  = "Loyal German allies of the French Empire",
				color = Color3.fromRGB(70,  45,  130),
			},
		},
	},
}

local localPlayer = Players.LocalPlayer

-- ── Module ────────────────────────────────────────────────────────────
local TeamSelectMenu = {}
TeamSelectMenu.__index = TeamSelectMenu

-- ── Helpers ───────────────────────────────────────────────────────────
local function corner(parent: Instance, r: number): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent       = parent
	return c
end

local function stroke(parent: Instance, color: Color3, thick: number, transp: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color        = color
	s.Thickness    = thick
	s.Transparency = transp
	s.Parent       = parent
	return s
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	for k, v in pairs(props) do (l :: any)[k] = v end
	l.BackgroundTransparency = l.BackgroundTransparency or 1
	l.Font                   = l.Font                   or Enum.Font.Gotham
	l.Parent                 = parent
	return l
end

-- ── Constructor ───────────────────────────────────────────────────────
function TeamSelectMenu.new(Network)
	local self               = setmetatable({}, TeamSelectMenu)
	self._network            = Network
	self._selectedTeam       = nil   -- number | nil
	self._selectedRegiment   = nil   -- number | nil
	self._teamCards          = {}    -- [teamIdx] = { frame, stroke, bar }
	self._regRows            = {}    -- [teamIdx][regIdx] = { frame, stroke }

	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- ── Root ScreenGui ─────────────────────────────────────────────
	local gui = Instance.new("ScreenGui")
	gui.Name           = "TeamSelectMenu"
	gui.ResetOnSpawn   = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.Enabled        = true
	gui.Parent         = playerGui
	self._gui = gui

	-- ── Overlay ────────────────────────────────────────────────────
	local overlay = Instance.new("Frame")
	overlay.Size                   = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3       = BG_OVERLAY
	overlay.BackgroundTransparency = 0.40
	overlay.ZIndex                 = 48
	overlay.Parent                 = gui
	self._overlay = overlay

	-- ── Panel ──────────────────────────────────────────────────────
	local PANEL_W, PANEL_H = 840, 540
	local panel = Instance.new("Frame")
	panel.Name                   = "Panel"
	panel.Size                   = UDim2.new(0, PANEL_W, 0, PANEL_H)
	panel.AnchorPoint            = Vector2.new(0.5, 0.5)
	panel.Position               = UDim2.new(0.5, 0, 0.5, 0)
	panel.BackgroundColor3       = PANEL_BG
	panel.BackgroundTransparency = 0.05
	panel.ZIndex                 = 49
	panel.Parent                 = gui
	corner(panel, 12)
	stroke(panel, ACCENT, 1.5, 0.3)
	self._panel = panel

	-- ── Header ─────────────────────────────────────────────────────
	label(panel, {
		Name            = "Title",
		Size            = UDim2.new(1, 0, 0, 40),
		Position        = UDim2.new(0, 0, 0, 8),
		Text            = "⚑   SELECT YOUR FACTION",
		TextColor3      = ACCENT,
		Font            = Enum.Font.GothamBold,
		TextSize        = 15,
		TextXAlignment  = Enum.TextXAlignment.Center,
		ZIndex          = 50,
	})

	local hDiv = Instance.new("Frame")
	hDiv.Size              = UDim2.new(1, -40, 0, 1)
	hDiv.Position          = UDim2.new(0, 20, 0, 50)
	hDiv.BackgroundColor3  = ACCENT
	hDiv.BackgroundTransparency = 0.6
	hDiv.BorderSizePixel   = 0
	hDiv.ZIndex            = 50
	hDiv.Parent            = panel

	-- ── Cards row ──────────────────────────────────────────────────
	local CARD_W = 400
	local CARD_H = 446
	local CARD_TOP = 58

	for teamIdx = 1, 2 do
		local td   = TEAMS[teamIdx]
		local xOff = (teamIdx == 1) and 10 or (PANEL_W - CARD_W - 10)

		-- Card frame
		local card = Instance.new("Frame")
		card.Name              = "Card_" .. teamIdx
		card.Size              = UDim2.new(0, CARD_W, 0, CARD_H)
		card.Position          = UDim2.new(0, xOff, 0, CARD_TOP)
		card.BackgroundColor3  = CARD_BG
		card.BackgroundTransparency = 0.15
		card.ZIndex            = 50
		card.Parent            = panel
		corner(card, 8)
		local cardStroke = stroke(card, Color3.fromRGB(40, 40, 60), 1.5, 0.3)

		-- Coloured top bar
		local bar = Instance.new("Frame")
		bar.Size             = UDim2.new(1, 0, 0, 5)
		bar.BackgroundColor3 = td.barColor
		bar.BackgroundTransparency = 0.4
		bar.BorderSizePixel  = 0
		bar.ZIndex           = 51
		bar.Parent           = card
		corner(bar, 4)

		-- Flag icon
		local flag = Instance.new("ImageLabel")
		flag.Size                   = UDim2.new(0, 52, 0, 52)
		flag.Position               = UDim2.new(0, 12, 0, 14)
		flag.BackgroundColor3       = Color3.fromRGB(22, 22, 34)
		flag.BackgroundTransparency = 0.1
		flag.Image                  = td.flagAsset
		flag.ScaleType              = Enum.ScaleType.Crop
		flag.ZIndex                 = 51
		flag.Parent                 = card
		corner(flag, 26)
		stroke(flag, Color3.fromRGB(120, 90, 40), 1.5, 0.2)

		-- Team name
		label(card, {
			Size           = UDim2.new(1, -78, 0, 24),
			Position       = UDim2.new(0, 76, 0, 16),
			Text           = td.name,
			TextColor3     = td.barColor,
			Font           = Enum.Font.GothamBold,
			TextSize       = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate   = Enum.TextTruncate.AtEnd,
			ZIndex         = 51,
		})
		label(card, {
			Size           = UDim2.new(1, -78, 0, 16),
			Position       = UDim2.new(0, 76, 0, 40),
			Text           = td.shortName,
			TextColor3     = DIM_COLOR,
			Font           = Enum.Font.GothamBold,
			TextSize       = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex         = 51,
		})

		-- Separator
		local sep = Instance.new("Frame")
		sep.Size              = UDim2.new(1, -14, 0, 1)
		sep.Position          = UDim2.new(0, 7, 0, 74)
		sep.BackgroundColor3  = td.barColor
		sep.BackgroundTransparency = 0.55
		sep.BorderSizePixel   = 0
		sep.ZIndex            = 51
		sep.Parent            = card

		label(card, {
			Size           = UDim2.new(1, -14, 0, 14),
			Position       = UDim2.new(0, 7, 0, 80),
			Text           = "CHOOSE REGIMENT",
			TextColor3     = DIM_COLOR,
			Font           = Enum.Font.GothamBold,
			TextSize        = 9,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex         = 51,
		})

		-- ── Regiment rows ─────────────────────────────────────────
		self._regRows[teamIdx] = {}
		for regIdx, rd in ipairs(td.regiments) do
			local rowY = 98 + (regIdx - 1) * 82

			local row = Instance.new("Frame")
			row.Size              = UDim2.new(1, -14, 0, 76)
			row.Position          = UDim2.new(0, 7, 0, rowY)
			row.BackgroundColor3  = ROW_BG
			row.BackgroundTransparency = 0.4
			row.ZIndex            = 51
			row.Parent            = card
			corner(row, 6)
			local rowStroke = stroke(row, Color3.fromRGB(40, 40, 60), 1, 0.45)

			-- Left colour swatch
			local swatch = Instance.new("Frame")
			swatch.Size             = UDim2.new(0, 4, 1, -18)
			swatch.Position         = UDim2.new(0, 10, 0, 9)
			swatch.BackgroundColor3 = rd.color
			swatch.BorderSizePixel  = 0
			swatch.ZIndex           = 52
			swatch.Parent           = row
			corner(swatch, 2)

			-- Regiment name
			label(row, {
				Size           = UDim2.new(1, -30, 0, 22),
				Position       = UDim2.new(0, 24, 0, 10),
				Text           = rd.name,
				TextColor3     = TEXT_COLOR,
				Font           = Enum.Font.GothamBold,
				TextSize       = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate   = Enum.TextTruncate.AtEnd,
				ZIndex         = 52,
			})

			-- Regiment description
			label(row, {
				Size           = UDim2.new(1, -30, 0, 28),
				Position       = UDim2.new(0, 24, 0, 33),
				Text           = rd.desc,
				TextColor3     = DIM_COLOR,
				Font           = Enum.Font.Gotham,
				TextSize       = 10,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped    = true,
				ZIndex         = 52,
			})

			-- Invisible click surface
			local btn = Instance.new("TextButton")
			btn.Size                   = UDim2.new(1, 0, 1, 0)
			btn.BackgroundTransparency = 1
			btn.Text                   = ""
			btn.ZIndex                 = 55
			btn.Parent                 = row

			self._regRows[teamIdx][regIdx] = { frame = row, stroke = rowStroke }

			-- Hover
			btn.MouseEnter:Connect(function()
				if not (self._selectedTeam == teamIdx and self._selectedRegiment == regIdx) then
					TweenService:Create(row, FADE_INFO, { BackgroundTransparency = 0.22 }):Play()
				end
			end)
			btn.MouseLeave:Connect(function()
				if not (self._selectedTeam == teamIdx and self._selectedRegiment == regIdx) then
					TweenService:Create(row, FADE_INFO, { BackgroundTransparency = 0.40 }):Play()
				end
			end)
			btn.MouseButton1Click:Connect(function()
				self:_selectRegiment(teamIdx, regIdx)
			end)
		end

		self._teamCards[teamIdx] = { frame = card, stroke = cardStroke, bar = bar }

		-- Clicking the card header selects team with regiment 1 by default
		local headerBtn = Instance.new("TextButton")
		headerBtn.Size                   = UDim2.new(1, 0, 0, 94)
		headerBtn.BackgroundTransparency = 1
		headerBtn.Text                   = ""
		headerBtn.ZIndex                 = 54
		headerBtn.Parent                 = card
		headerBtn.MouseButton1Click:Connect(function()
			if self._selectedTeam ~= teamIdx then
				self:_selectRegiment(teamIdx, 1)
			end
		end)
	end

	-- ── Deploy button ──────────────────────────────────────────────
	local deployBtn = Instance.new("TextButton")
	deployBtn.Name                   = "DeployBtn"
	deployBtn.Size                   = UDim2.new(0, 300, 0, 44)
	deployBtn.AnchorPoint            = Vector2.new(0.5, 1)
	deployBtn.Position               = UDim2.new(0.5, 0, 1, -12)
	deployBtn.BackgroundColor3       = ACCENT
	deployBtn.BackgroundTransparency = 0.18
	deployBtn.Text                   = "SELECT A FACTION TO DEPLOY"
	deployBtn.TextColor3             = Color3.fromRGB(255, 255, 255)
	deployBtn.Font                   = Enum.Font.GothamBold
	deployBtn.TextSize               = 13
	deployBtn.ZIndex                 = 52
	deployBtn.Parent                 = panel
	corner(deployBtn, 8)
	self._deployBtn     = deployBtn
	self._deployBtnText = deployBtn  -- alias

	deployBtn.MouseButton1Click:Connect(function()
		if self._selectedTeam and self._selectedRegiment then
			self:_deploy()
		end
	end)

	-- ── Persistent reopen button ───────────────────────────────────
	local reopenBtn = Instance.new("TextButton")
	reopenBtn.Size                   = UDim2.new(0, 96, 0, 28)
	reopenBtn.AnchorPoint            = Vector2.new(0, 1)
	reopenBtn.Position               = UDim2.new(0, 10, 1, -54)
	reopenBtn.BackgroundColor3       = Color3.fromRGB(18, 18, 32)
	reopenBtn.BackgroundTransparency = 0.08
	reopenBtn.Text                   = "⚑  FACTION"
	reopenBtn.TextColor3             = DIM_COLOR
	reopenBtn.Font                   = Enum.Font.GothamBold
	reopenBtn.TextSize               = 10
	reopenBtn.ZIndex                 = 35
	reopenBtn.Parent                 = gui
	corner(reopenBtn, 6)
	stroke(reopenBtn, Color3.fromRGB(48, 48, 72), 1, 0)

	reopenBtn.MouseEnter:Connect(function()
		TweenService:Create(reopenBtn, FADE_INFO, { TextColor3 = TEXT_COLOR }):Play()
	end)
	reopenBtn.MouseLeave:Connect(function()
		TweenService:Create(reopenBtn, FADE_INFO, { TextColor3 = DIM_COLOR }):Play()
	end)
	reopenBtn.MouseButton1Click:Connect(function()
		self:show()
	end)

	return self
end

-- ── Internal: visual selection logic ─────────────────────────────────

function TeamSelectMenu:_selectRegiment(teamIdx: number, regIdx: number)
	local prevTeam = self._selectedTeam
	local prevReg  = self._selectedRegiment

	self._selectedTeam     = teamIdx
	self._selectedRegiment = regIdx

	-- Reset all cards
	for ti, tc in pairs(self._teamCards) do
		local isTeam = (ti == teamIdx)
		TweenService:Create(tc.stroke, FADE_INFO, {
			Color        = isTeam and ACCENT or Color3.fromRGB(40, 40, 60),
			Transparency = isTeam and 0 or 0.3,
		}):Play()
		TweenService:Create(tc.bar, FADE_INFO, {
			BackgroundTransparency = isTeam and 0.1 or 0.5,
		}):Play()

		-- Deselect rows on other team
		if ti ~= teamIdx and self._regRows[ti] then
			for _, rdata in pairs(self._regRows[ti]) do
				TweenService:Create(rdata.frame, FADE_INFO, { BackgroundTransparency = 0.40 }):Play()
				TweenService:Create(rdata.stroke, FADE_INFO, {
					Color        = Color3.fromRGB(40, 40, 60),
					Transparency = 0.45,
				}):Play()
			end
		end
	end

	-- Reset all rows in this team then highlight selected
	local rows = self._regRows[teamIdx]
	if rows then
		for ri, rdata in pairs(rows) do
			local isSel = (ri == regIdx)
			TweenService:Create(rdata.frame, FADE_INFO, {
				BackgroundTransparency = isSel and 0.08 or 0.40,
			}):Play()
			TweenService:Create(rdata.stroke, FADE_INFO, {
				Color        = isSel and SEL_OUTLINE or Color3.fromRGB(40, 40, 60),
				Transparency = isSel and 0 or 0.45,
			}):Play()
		end
	end

	-- Update deploy button
	local td = TEAMS[teamIdx]
	local rd = td.regiments[regIdx]
	self._deployBtn.Text            = "DEPLOY AS  " .. rd.name:upper()
	self._deployBtn.BackgroundColor3 = td.barColor
end

function TeamSelectMenu:_deploy()
	local ti = self._selectedTeam
	local ri = self._selectedRegiment
	if not ti or not ri then return end

	-- Flash button green, then close
	local prev = TEAMS[ti].barColor
	self._deployBtn.BackgroundColor3 = Color3.fromRGB(55, 170, 90)
	task.delay(0.4, function()
		if self._deployBtn and self._deployBtn.Parent then
			self._deployBtn.BackgroundColor3 = prev
		end
	end)

	self._network.TeamRegimentSelect.Fire(ti, ri)

	task.delay(0.45, function()
		self:hide()
	end)
end

-- ── Public API ────────────────────────────────────────────────────────

function TeamSelectMenu:show()
	self._gui.Enabled = true
	self._overlay.BackgroundTransparency = 1
	self._panel.Position = UDim2.new(0.5, 0, 0.35, 0)

	TweenService:Create(self._overlay, SLIDE_INFO, { BackgroundTransparency = 0.40 }):Play()
	TweenService:Create(self._panel,   SLIDE_INFO, { Position = UDim2.new(0.5, 0, 0.5, 0) }):Play()
end

function TeamSelectMenu:hide()
	TweenService:Create(self._overlay, FADE_INFO, { BackgroundTransparency = 1 }):Play()
	local t = TweenService:Create(self._panel, SLIDE_INFO, { Position = UDim2.new(0.5, 0, 0.65, 0) })
	t.Completed:Connect(function()
		self._gui.Enabled = false
	end)
	t:Play()
end

return TeamSelectMenu
