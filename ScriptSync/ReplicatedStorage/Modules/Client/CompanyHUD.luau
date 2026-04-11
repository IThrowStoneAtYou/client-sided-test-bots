-->>>>>>>>>>>>
-- COMPANY_HUD
-- Version 3.0.0
--
-- Company Colors:
--   I (Blue):   RGB(65, 105, 210)
--   II (Red):   RGB(200, 55, 55)
--   III (Green): RGB(55, 170, 90)
--   IV (Gold):  RGB(210, 160, 35)
--
-- Selection Modes:
--   - Click: Exclusive select (deselects all others)
--   - Shift+Click: Toggle inclusion
--   - Right+Click: Deselect all
--
-->>>>>>>>>>>>

local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Players          = game:GetService("Players")

local ROMAN          = { "I", "II", "III", "IV" }
local COMPANY_COLORS = {
	Color3.fromRGB(65,  105, 210),
	Color3.fromRGB(200, 55,  55),
	Color3.fromRGB(55,  170, 90),
	Color3.fromRGB(210, 160, 35),
}

local CARD_W      = 88
local CARD_H      = 122
local CARD_GAP    = 10
local PEEK_H      = 30
local RAISED_OFF  = -18
local RESTING_OFF = RAISED_OFF + (CARD_H - PEEK_H)   -- 74

local SLIDE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local MAX_TICKETS = 135   -- maximum strength tickets

local CompanyHUD = {}
CompanyHUD.__index = CompanyHUD

-->>>>>>>>>>>>
-- Constructor. onSelectionChanged(selectedList: {number}) fires on every change.
function CompanyHUD.new(onSelectionChanged)
	local self        = setmetatable({}, CompanyHUD)
	self._selected    = {}   -- { [index] = true }  (set)
	self._companies   = {}   -- { [index] = { count } }
	self._cards       = {}
	self._canAttackState = {}   -- [index] = boolean (true by default)
	self._meleeState  = {}   -- [index] = boolean (false by default)
	self._strengthData = {}     -- [index] = { tickets, isBroken, brokenTimer, enemyNearby }
	self._onChanged   = onSelectionChanged or function() end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name            = "CompanyHUD"
	gui.ResetOnSpawn    = false
	gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset  = true
	gui.Parent          = playerGui
	self._gui = gui

	-- Create company cards
	for i = 1, 4 do
		self:_createCard(i)
	end

	-- Create the global info panel
	self:_createGlobalInfoPanel()

	-- Create the broken company prompt
	self:_createBrokenPrompt()

	return self
end

-- ── Public API ────────────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Returns the accent Color3 for a given company index.
-- Used to tint UI elements and Highlight instances to company colors.
function CompanyHUD.getColor(index: number): Color3
	return COMPANY_COLORS[index]
end

-->>>>>>>>>>>>
-- Returns a sorted array of currently selected company indices.
function CompanyHUD:getSelectedList(): {number}
	local list = {}
	for idx in pairs(self._selected) do
		list[#list + 1] = idx
	end

	table.sort(list)

	return list
end

-->>>>>>>>>>>>
-- Updates the can‑attack state for a given company and updates both its card icon
-- and the global info panel if that company is currently the only selected one.
function CompanyHUD:setCanAttack(index: number, enabled: boolean)
	self._canAttackState[index] = enabled
	self:_refreshCard(index)

	local selected = self:getSelectedList()
	if #selected == 1 and selected[1] == index then
		self:_updateGlobalPanel(index)
	end
end

-->>>>>>>>>>>>
-- Updates the melee state for a given company and updates its card icon.
function CompanyHUD:setMeleeState(index: number, enabled: boolean)
	self._meleeState[index] = enabled
	self:_refreshCard(index)

	local selected = self:getSelectedList()
	if #selected == 1 and selected[1] == index then
		self:_updateGlobalPanel(index) -- Re-evaluate global panel if this company is selected
	end
end
-->>>>>>>>>>>>
-- Returns true if at least one company is selected.
function CompanyHUD:hasSelection(): boolean
	return next(self._selected) ~= nil
end

-->>>>>>>>>>>>
-- Returns true if the given index is currently selected.
function CompanyHUD:isSelected(index: number): boolean
	return self._selected[index] == true
end

-->>>>>>>>>>>>
-- Exclusive select: clears all others and selects only this index.
-- Pass nil to deselect everything.
function CompanyHUD:setSelected(index: number?)
	local prev = self._selected
	self._selected = index and { [index] = true } or {}
	self._onChanged(self:getSelectedList())

	local dirty = {}
	for idx in pairs(prev) do
		dirty[idx] = true
	end

	if index then
		dirty[index] = true
	end

	for idx in pairs(dirty) do
		self:_refreshCard(idx)
	end

	-- Update global panel visibility/content based on new selection
	local selected = self:getSelectedList()
	if #selected == 1 then
		self:_updateGlobalPanel(selected[1])
		self._globalPanel.Visible = true
	else
		self._globalPanel.Visible = false
	end

	-- Update broken prompt
	self:_updateBrokenPrompt()
end

-->>>>>>>>>>>>
-- Toggles one company in/out of the selection (for shift+click).
function CompanyHUD:toggleSelected(index: number)
	if not self._companies[index] then return end
	if self._selected[index] then
		self._selected[index] = nil
	else
		self._selected[index] = true
	end

	self._onChanged(self:getSelectedList())
	self:_refreshCard(index)

	-- Update global panel visibility/content
	local selected = self:getSelectedList()
	if #selected == 1 then
		self:_updateGlobalPanel(selected[1])
		self._globalPanel.Visible = true
	else
		self._globalPanel.Visible = false
	end

	-- Update broken prompt
	self:_updateBrokenPrompt()
end

-->>>>>>>>>>>>
-- Called when NpcCompanySync arrives. Updates counts and removes stale selections.
function CompanyHUD:syncCompanies(data: {{index: number, count: number}})
	self._companies = {}
	for _, entry in ipairs(data) do
		self._companies[entry.index] = { count = entry.count }
	end

	local selChanged = false
	for idx in pairs(self._selected) do
		if not self._companies[idx] then
			self._selected[idx] = nil
			selChanged = true
		end
	end

	self:_updateLayout()

	if selChanged then
		self._onChanged(self:getSelectedList())
	end

	for i = 1, 4 do
		self:_refreshCard(i)
	end

	-- Refresh global panel if a company is still selected alone
	local selected = self:getSelectedList()
	if #selected == 1 then
		self:_updateGlobalPanel(selected[1])
		self._globalPanel.Visible = true
	else
		self._globalPanel.Visible = false
	end

	-- Refresh broken prompt
	self:_updateBrokenPrompt()
end

-->>>>>>>>>>>>
-- Recalculates horizontal positions for all active cards to keep them centered.
function CompanyHUD:_updateLayout()
	local activeIndices = {}
	for i = 1, 4 do
		if self._companies[i] then
			table.insert(activeIndices, i)
		end
	end

	local n = #activeIndices
	if n == 0 then return end

	local totalWidth = n * CARD_W + (n - 1) * CARD_GAP
	local startX     = -totalWidth / 2

	for slot, index in ipairs(activeIndices) do
		local xOff = startX + (slot - 1) * (CARD_W + CARD_GAP) + CARD_W / 2
		local cd   = self._cards[index]
		if cd then
			cd.raisedPos  = UDim2.new(0.5, xOff, 1, RAISED_OFF)
			cd.restingPos = UDim2.new(0.5, xOff, 1, RESTING_OFF)
		end
	end
end

function CompanyHUD:setStrength(index: number, tickets: number, isBroken: boolean, brokenTimer: number, enemyNearby: boolean)
	if not self._strengthData then self._strengthData = {} end
	self._strengthData[index] = {
		tickets     = tickets,
		isBroken    = isBroken,
		brokenTimer = brokenTimer,
		enemyNearby = enemyNearby,
	}

	self:_refreshCard(index)
	self:_updateCardFlashing(index, isBroken)

	local selected = self:getSelectedList()
	if #selected == 1 and selected[1] == index then
		self:_updateGlobalPanel(index)
	end

	self:_updateBrokenPrompt()
end

-- ── Internal ──────────────────────────────────────────────────────────

function CompanyHUD:_refreshCard(i: number)
	local cd      = self._cards[i]
	if not cd then return end

	local company = self._companies[i]
	local isSel   = self._selected[i] == true
	local canFire = self._canAttackState[i] ~= false  -- nil treated as true (default on)
	local inMelee = self._meleeState[i] == true

	cd.frame.Visible = company ~= nil
	if not company then return end

	cd.countLabel.Text        = tostring(company.count)
	cd.stroke.Thickness       = isSel and 3 or 1.5

	if inMelee then
		-- Special styling for melee mode
		cd.stroke.Color           = Color3.fromRGB(255, 100, 100) -- Reddish for melee
		cd.stroke.Transparency    = isSel and 0 or 0.3
		cd.frame.BackgroundColor3 = isSel and Color3.fromRGB(40, 20, 20) or Color3.fromRGB(25, 10, 10)
	else
		-- Normal styling
		cd.stroke.Color           = COMPANY_COLORS[i] -- Revert to company color
		if canFire then
			cd.stroke.Transparency    = isSel and 0 or 0.6
			cd.frame.BackgroundColor3 = isSel and Color3.fromRGB(26, 30, 50) or Color3.fromRGB(14, 14, 22)
		else
			cd.stroke.Transparency    = 0.85
			cd.frame.BackgroundColor3 = Color3.fromRGB(30, 14, 14)
		end
	end


	local target = (isSel or cd.hovered) and cd.raisedPos or cd.restingPos
	TweenService:Create(cd.frame, SLIDE_TWEEN, { Position = target }):Play()
end

-- Updates card flashing when company becomes broken
function CompanyHUD:_updateCardFlashing(index: number, isBroken: boolean)
	local cd = self._cards[index]
	if not cd then return end

	-- Cancel any existing flash tween
	if cd.flashTween then
		cd.flashTween:Cancel()
		cd.flashTween = nil
	end

	if isBroken then
		-- Start flashing animation: alternate between normal and darker red
		local function startFlash()
			if not cd.flashTween then  -- Check if still supposed to be flashing
				local flashTween = TweenService:Create(
					cd.stroke,
					TweenInfo.new(0.5, Enum.EasingStyle.Linear),
					{ Transparency = 0.2 }
				)
				flashTween:Play()
				flashTween.Completed:Connect(function()
					if cd.flashTween then  -- Still flashing
						local flashTween2 = TweenService:Create(
							cd.stroke,
							TweenInfo.new(0.5, Enum.EasingStyle.Linear),
							{ Transparency = 0.6 }
						)
						flashTween2:Play()
						flashTween2.Completed:Connect(startFlash)
						cd.flashTween = flashTween2
					end
				end)

				cd.flashTween = flashTween
			end
		end

		startFlash()
	else
		-- Company recovered - reset stroke to normal
		if cd.stroke then
			cd.stroke.Transparency = 0.6
		end
	end
end

-- Creates a single company card (no info panel inside)
function CompanyHUD:_createCard(index: number)
	local accent     = COMPANY_COLORS[index]
	local raisedPos  = UDim2.new(0.5, 0, 1, RAISED_OFF)
	local restingPos = UDim2.new(0.5, 0, 1, RESTING_OFF)

	local card = Instance.new("Frame")
	card.Name                   = "Card_" .. index
	card.AnchorPoint            = Vector2.new(0.5, 1)
	card.Position               = restingPos
	card.Size                   = UDim2.new(0, CARD_W, 0, CARD_H)
	card.BackgroundColor3       = Color3.fromRGB(14, 14, 22)
	card.BackgroundTransparency = 0.2
	card.Visible                = false
	card.Parent                 = self._gui

	local stroke = Instance.new("UIStroke")
	stroke.Name         = "Stroke"
	stroke.Color        = accent
	stroke.Thickness    = 1.5
	stroke.Transparency = 0.6
	stroke.Parent       = card

	local compTitle = Instance.new("TextLabel")
	compTitle.Name               = "Title"
	compTitle.Size               = UDim2.new(1, 0, 0, 14)
	compTitle.Position           = UDim2.new(0, 0, 0, 12)
	compTitle.BackgroundTransparency = 1
	compTitle.Text               = "COMPANY"
	compTitle.TextColor3         = Color3.fromRGB(145, 145, 160)
	compTitle.TextSize           = 9
	compTitle.Font               = Enum.Font.GothamBold
	compTitle.TextXAlignment     = Enum.TextXAlignment.Center
	compTitle.ZIndex             = 2
	compTitle.Parent             = card

	local romanLabel = Instance.new("TextLabel")
	romanLabel.Name              = "Roman"
	romanLabel.Size              = UDim2.new(1, 0, 0, 26)
	romanLabel.Position          = UDim2.new(0, 0, 0, 24)
	romanLabel.BackgroundTransparency = 1
	romanLabel.Text              = ROMAN[index]
	romanLabel.TextColor3        = accent
	romanLabel.TextSize          = 22
	romanLabel.Font              = Enum.Font.GothamBold
	romanLabel.TextXAlignment    = Enum.TextXAlignment.Center
	romanLabel.ZIndex            = 2
	romanLabel.Parent            = card

	local divider = Instance.new("Frame")
	divider.Name             = "Divider"
	divider.Size             = UDim2.new(0.6, 0, 0, 1)
	divider.Position         = UDim2.new(0.2, 0, 0, 54)
	divider.BackgroundColor3 = accent
	divider.BackgroundTransparency = 0.5
	divider.BorderSizePixel  = 0
	divider.ZIndex           = 2
	divider.Parent           = card

	local countLabel = Instance.new("TextLabel")
	countLabel.Name              = "Count"
	countLabel.Size              = UDim2.new(1, 0, 0, 40)
	countLabel.Position          = UDim2.new(0, 0, 0, 58)
	countLabel.BackgroundTransparency = 1
	countLabel.Text              = "0"
	countLabel.TextColor3        = Color3.fromRGB(230, 230, 230)
	countLabel.TextSize          = 36
	countLabel.Font              = Enum.Font.GothamBold
	countLabel.TextXAlignment    = Enum.TextXAlignment.Center
	countLabel.ZIndex            = 2
	countLabel.Parent            = card

	local menLabel = Instance.new("TextLabel")
	menLabel.Name               = "MenLabel"
	menLabel.Size               = UDim2.new(1, 0, 0, 14)
	menLabel.Position           = UDim2.new(0, 0, 0, 98)
	menLabel.BackgroundTransparency = 1
	menLabel.Text               = "MEN"
	menLabel.TextColor3         = Color3.fromRGB(110, 110, 125)
	menLabel.TextSize           = 9
	menLabel.Font               = Enum.Font.Gotham
	menLabel.TextXAlignment     = Enum.TextXAlignment.Center
	menLabel.ZIndex             = 2
	menLabel.Parent             = card

	local btn = Instance.new("TextButton")
	btn.Name               = "Button"
	btn.Size               = UDim2.new(1, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.Text               = ""
	btn.ZIndex             = 10
	btn.Parent             = card

	local cd = {
		frame      = card,
		countLabel = countLabel,
		stroke     = stroke,
		hovered    = false,
		raisedPos  = raisedPos,
		restingPos = restingPos,
		flashTween = nil,
	}
	self._cards[index] = cd

	btn.MouseEnter:Connect(function()
		cd.hovered = true
		if self._companies[index] then
			TweenService:Create(card, SLIDE_TWEEN, { Position = cd.raisedPos }):Play()
		end
	end)

	btn.MouseLeave:Connect(function()
		cd.hovered = false
		if not self._selected[index] and self._companies[index] then
			TweenService:Create(card, SLIDE_TWEEN, { Position = cd.restingPos }):Play()
		end
	end)

	btn.MouseButton1Click:Connect(function()
		if not self._companies[index] then return end
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

		if shift then
			self:toggleSelected(index)
		else
			local list = self:getSelectedList()
			if #list == 1 and list[1] == index then
				self:setSelected(nil)
			else
				self:setSelected(index)
			end
		end
	end)
end

-- Creates the global info panel at bottom left
function CompanyHUD:_createGlobalInfoPanel()
	local panel = Instance.new("Frame")
	panel.Name = "GlobalInfoPanel"
	panel.Size = UDim2.new(0, 340, 0, 200)   -- large panel
	panel.Position = UDim2.new(0, 10, 1, -10)
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.BackgroundColor3 = Color3.fromRGB(14, 14, 22)
	panel.BackgroundTransparency = 0.2
	panel.Visible = false
	panel.ZIndex = 10
	panel.Parent = self._gui

	local stroke = Instance.new("UIStroke")
	stroke.Name         = "Stroke"
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Thickness = 2.2
	stroke.Transparency = 0
	stroke.Parent = panel
	self._globalStroke = stroke

	-- Company name (dynamic)
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -20, 0, 28)
	title.Position = UDim2.new(0, 10, 0, 8)
	title.BackgroundTransparency = 1
	title.Text = "COMPANY I"
	title.TextColor3 = Color3.fromRGB(230, 230, 230)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = panel

	-- Strength bar
	local strLabel = Instance.new("TextLabel")
	strLabel.Name = "StrengthLabel"
	strLabel.Size = UDim2.new(1, -20, 0, 12)
	strLabel.Position = UDim2.new(0, 10, 0, 44)
	strLabel.BackgroundTransparency = 1
	strLabel.Text = "STRENGTH"
	strLabel.TextColor3 = Color3.fromRGB(130, 130, 145)
	strLabel.Font = Enum.Font.GothamBold
	strLabel.TextSize = 10
	strLabel.TextXAlignment = Enum.TextXAlignment.Left
	strLabel.ZIndex = 11
	strLabel.Parent = panel

	local strBg = Instance.new("Frame")
	strBg.Name = "StrengthBar"
	strBg.Size = UDim2.new(1, -20, 0, 16)
	strBg.Position = UDim2.new(0, 10, 0, 56)
	strBg.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	strBg.BorderSizePixel = 0
	strBg.ZIndex = 11
	strBg.Parent = panel

	local strBgCorner = Instance.new("UICorner")
	strBgCorner.Name         = "Corner"
	strBgCorner.CornerRadius = UDim.new(0, 4)
	strBgCorner.Parent = strBg

	local strFill = Instance.new("Frame")
	strFill.Name = "Fill"
	strFill.Size = UDim2.new(1, 0, 1, 0)
	strFill.BackgroundColor3 = Color3.fromRGB(55, 110, 200)
	strFill.BackgroundTransparency = 0.3
	strFill.BorderSizePixel = 0
	strFill.ZIndex = 12
	strFill.Parent = strBg

	local strFillCorner = Instance.new("UICorner")
	strFillCorner.Name         = "Corner"
	strFillCorner.CornerRadius = UDim.new(0, 4)
	strFillCorner.Parent = strFill

	local strVal = Instance.new("TextLabel")
	strVal.Name = "Value"
	strVal.Size = UDim2.new(1, 0, 1, 0)
	strVal.BackgroundTransparency = 1
	strVal.Text = "100"
	strVal.TextColor3 = Color3.fromRGB(230, 230, 230)
	strVal.Font = Enum.Font.GothamBold
	strVal.TextSize = 11
	strVal.TextXAlignment = Enum.TextXAlignment.Center
	strVal.ZIndex = 13
	strVal.Parent = strBg

	-- Morale bar
	local morLabel = Instance.new("TextLabel")
	morLabel.Name = "MoraleLabel"
	morLabel.Size = UDim2.new(1, -20, 0, 12)
	morLabel.Position = UDim2.new(0, 10, 0, 84)
	morLabel.BackgroundTransparency = 1
	morLabel.Text = "MORALE"
	morLabel.TextColor3 = Color3.fromRGB(130, 130, 145)
	morLabel.Font = Enum.Font.GothamBold
	morLabel.TextSize = 10
	morLabel.TextXAlignment = Enum.TextXAlignment.Left
	morLabel.ZIndex = 11
	morLabel.Parent = panel

	local morBg = Instance.new("Frame")
	morBg.Name = "MoraleBar"
	morBg.Size = UDim2.new(1, -20, 0, 16)
	morBg.Position = UDim2.new(0, 10, 0, 96)
	morBg.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	morBg.BorderSizePixel = 0
	morBg.ZIndex = 11
	morBg.Parent = panel

	local morBgCorner = Instance.new("UICorner")
	morBgCorner.Name         = "Corner"
	morBgCorner.CornerRadius = UDim.new(0, 4)
	morBgCorner.Parent = morBg

	local morFill = Instance.new("Frame")
	morFill.Name = "Fill"
	morFill.Size = UDim2.new(1, 0, 1, 0)
	morFill.BackgroundColor3 = Color3.fromRGB(200, 55, 55)
	morFill.BackgroundTransparency = 0.3
	morFill.BorderSizePixel = 0
	morFill.ZIndex = 12
	morFill.Parent = morBg

	local morFillCorner = Instance.new("UICorner")
	morFillCorner.Name         = "Corner"
	morFillCorner.CornerRadius = UDim.new(0, 4)
	morFillCorner.Parent = morFill

	local morVal = Instance.new("TextLabel")
	morVal.Name = "Value"
	morVal.Size = UDim2.new(1, 0, 1, 0)
	morVal.BackgroundTransparency = 1
	morVal.Text = "85"
	morVal.TextColor3 = Color3.fromRGB(230, 230, 230)
	morVal.Font = Enum.Font.GothamBold
	morVal.TextSize = 11
	morVal.TextXAlignment = Enum.TextXAlignment.Center
	morVal.ZIndex = 13
	morVal.Parent = morBg

	-- Icons row
	local iconDivider = Instance.new("Frame")
	iconDivider.Name = "Divider"
	iconDivider.Size = UDim2.new(0.8, 0, 0, 1)
	iconDivider.Position = UDim2.new(0.1, 0, 0, 130)
	iconDivider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	iconDivider.BackgroundTransparency = 0.6
	iconDivider.BorderSizePixel = 0
	iconDivider.ZIndex = 11
	iconDivider.Parent = panel

	local ICON_SIZE = 28
	local ICON_IMG = "http://www.roblox.com/asset/?id=13488010851"

	-- Weapon type icon (static)
	local typeIcon = Instance.new("ImageLabel")
	typeIcon.Name = "TypeIcon"
	typeIcon.Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE)
	typeIcon.Position = UDim2.new(0.5, -ICON_SIZE - 12, 0, 140)
	typeIcon.BackgroundTransparency = 1
	typeIcon.Image = ICON_IMG
	typeIcon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	typeIcon.ZIndex = 12
	typeIcon.Parent = panel

	local typeTip = Instance.new("TextLabel")
	typeTip.Name = "TypeTip"
	typeTip.Size = UDim2.new(0, ICON_SIZE + 20, 0, 12)
	typeTip.Position = UDim2.new(0.5, -ICON_SIZE - 12, 0, 170)
	typeTip.BackgroundTransparency = 1
	typeTip.Text = "TYPE"
	typeTip.TextColor3 = Color3.fromRGB(110, 110, 125)
	typeTip.Font = Enum.Font.Gotham
	typeTip.TextSize = 8
	typeTip.TextXAlignment = Enum.TextXAlignment.Center
	typeTip.ZIndex = 12
	typeTip.Parent = panel

	-- Fire toggle icon (dynamic)
	local fireIcon = Instance.new("ImageLabel")
	fireIcon.Name = "FireIcon"
	fireIcon.Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE)
	fireIcon.Position = UDim2.new(0.5, 12, 0, 140)
	fireIcon.BackgroundTransparency = 1
	fireIcon.Image = ICON_IMG
	fireIcon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	fireIcon.ZIndex = 12
	fireIcon.Parent = panel

	local fireTip = Instance.new("TextLabel")
	fireTip.Name = "FireTip"
	fireTip.Size = UDim2.new(0, ICON_SIZE + 20, 0, 12)
	fireTip.Position = UDim2.new(0.5, 12, 0, 170)
	fireTip.BackgroundTransparency = 1
	fireTip.Text = "[E] FIRE"
	fireTip.TextColor3 = Color3.fromRGB(110, 110, 125)
	fireTip.Font = Enum.Font.Gotham
	fireTip.TextSize = 8
	fireTip.TextXAlignment = Enum.TextXAlignment.Center
	fireTip.ZIndex = 12
	fireTip.Parent = panel

	-- Store references for later updates
	self._globalPanel = panel
	self._globalTitle = title
	self._strengthFill = strFill
	self._strengthValue = strVal
	self._moraleFill = morFill
	self._moraleValue = morVal
	self._globalFireIcon = fireIcon

	-- Also keep a per‑company icon reference for setCanAttack to update both card and global
	self._canAttackIcons = {}   -- will store card icons; global icon handled separately
end

-- Updates the global panel with data from the given company index
function CompanyHUD:_updateGlobalPanel(index: number)
	local company = self._companies[index]
	if not company then
		self._globalPanel.Visible = false
		return
	end

	local companyColor = COMPANY_COLORS[index]   -- <-- get the color
	self._globalTitle.TextColor3 = companyColor
	self._globalStroke.Color = companyColor      -- <-- apply to stroke

	self._globalTitle.Text = "COMPANY " .. ROMAN[index]

	-- Strength bar (updated as requested)
	local sd = self._strengthData and self._strengthData[index]
	local tickets = sd and sd.tickets or MAX_TICKETS
	local ratio   = math.clamp(tickets / MAX_TICKETS, 0, 1)
	self._strengthValue.Text = tostring(tickets)
	self._strengthFill.Size  = UDim2.new(ratio, 0, 1, 0)
	
	-- Simple solid color: Blue (full) → Orange (half) → Red (low)
	local color
	if ratio > 0.66 then
		-- Blue (full strength)
		color = Color3.fromRGB(0, 120, 220)
	elseif ratio > 0.33 then
		-- Orange (medium strength)
		color = Color3.fromRGB(255, 140, 0)
	else
		-- Red (low strength)
		color = Color3.fromRGB(200, 50, 50)
	end
	
	self._strengthFill.BackgroundColor3 = color

	-- Morale bar (placeholder)
	self._moraleValue.Text = "no worky"
	self._moraleFill.Size = UDim2.new(1, 0, 1, 0)

	-- Update fire icon state
	local canAttack = self._canAttackState[index] ~= false   -- default true
	self._globalFireIcon.ImageTransparency = canAttack and 0 or 0.65
	self._globalFireIcon.ImageColor3 = canAttack and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(120, 120, 120)

	self._globalPanel.Visible = true
end

-- Creates the broken company prompt at top center
function CompanyHUD:_createBrokenPrompt()
	local panel = Instance.new("Frame")
	panel.Name              = "BrokenPrompt"
	panel.Size              = UDim2.new(0, 320, 0, 90)
	panel.Position 			= UDim2.new(0.5, 0, 0, 92)
	panel.AnchorPoint       = Vector2.new(0.5, 0)
	panel.BackgroundColor3  = Color3.fromRGB(14, 14, 22)
	panel.BackgroundTransparency = 0.15
	panel.Visible           = false
	panel.ZIndex            = 20
	panel.Parent            = self._gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 9)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color       = Color3.fromRGB(200, 55, 55)
	stroke.Thickness   = 2.5
	stroke.Transparency = 0
	stroke.Parent = panel
	self._brokenStroke = stroke

	local title = Instance.new("TextLabel")
	title.Name               = "Title"
	title.Size               = UDim2.new(1, 0, 0, 24)
	title.Position           = UDim2.new(0, 0, 0, 8)
	title.BackgroundTransparency = 1
	title.Text               = "COMPANY I — BROKEN"
	title.TextColor3         = Color3.fromRGB(200, 55, 55)
	title.Font               = Enum.Font.GothamBold
	title.TextSize           = 14
	title.TextXAlignment     = Enum.TextXAlignment.Center
	title.ZIndex             = 21
	title.Parent             = panel
	self._brokenTitle = title

	-- Timer row
	local timerLabel = Instance.new("TextLabel")
	timerLabel.Name              = "TimerLabel"
	timerLabel.Size              = UDim2.new(0.5, -10, 0, 14)
	timerLabel.Position          = UDim2.new(0, 10, 0, 38)
	timerLabel.BackgroundTransparency = 1
	timerLabel.Text              = "SURVIVE"
	timerLabel.TextColor3        = Color3.fromRGB(130, 130, 145)
	timerLabel.Font              = Enum.Font.GothamBold
	timerLabel.TextSize          = 9
	timerLabel.TextXAlignment    = Enum.TextXAlignment.Left
	timerLabel.ZIndex            = 21
	timerLabel.Parent            = panel

	local timerVal = Instance.new("TextLabel")
	timerVal.Name              = "TimerValue"
	timerVal.Size              = UDim2.new(0.5, -10, 0, 14)
	timerVal.Position          = UDim2.new(0.5, 0, 0, 38)
	timerVal.BackgroundTransparency = 1
	timerVal.Text              = "20s"
	timerVal.TextColor3        = Color3.fromRGB(230, 230, 230)
	timerVal.Font              = Enum.Font.GothamBold
	timerVal.TextSize          = 9
	timerVal.TextXAlignment    = Enum.TextXAlignment.Right
	timerVal.ZIndex            = 21
	timerVal.Parent            = panel
	self._brokenTimerVal = timerVal

	-- Enemy nearby row
	local enemyLabel = Instance.new("TextLabel")
	enemyLabel.Name              = "EnemyLabel"
	enemyLabel.Size              = UDim2.new(0.5, -10, 0, 14)
	enemyLabel.Position          = UDim2.new(0, 10, 0, 58)
	enemyLabel.BackgroundTransparency = 1
	enemyLabel.Text              = "FAR FROM ENEMY COMPANY"
	enemyLabel.TextColor3        = Color3.fromRGB(130, 130, 145)
	enemyLabel.Font              = Enum.Font.GothamBold
	enemyLabel.TextSize          = 9
	enemyLabel.TextXAlignment    = Enum.TextXAlignment.Left
	enemyLabel.ZIndex            = 21
	enemyLabel.Parent            = panel

	local enemyVal = Instance.new("TextLabel")
	enemyVal.Name              = "EnemyValue"
	enemyVal.Size              = UDim2.new(0.5, -10, 0, 14)
	enemyVal.Position          = UDim2.new(0.5, 0, 0, 58)
	enemyVal.BackgroundTransparency = 1
	enemyVal.Text              = "NO"
	enemyVal.TextColor3        = Color3.fromRGB(200, 55, 55)
	enemyVal.Font              = Enum.Font.GothamBold
	enemyVal.TextSize          = 9
	enemyVal.TextXAlignment    = Enum.TextXAlignment.Right
	enemyVal.ZIndex            = 21
	enemyVal.Parent            = panel
	self._brokenEnemyVal = enemyVal

	self._brokenPrompt = panel
end

-- Updates the broken prompt visibility and content based on selected company
function CompanyHUD:_updateBrokenPrompt()
	if not self._brokenPrompt then return end

	local selected = self:getSelectedList()
	if #selected ~= 1 then
		self._brokenPrompt.Visible = false
		return
	end

	local idx = selected[1]
	local sd  = self._strengthData and self._strengthData[idx]
	if not sd or not sd.isBroken then
		self._brokenPrompt.Visible = false
		return
	end

	self._brokenPrompt.Visible   = true
	self._brokenTitle.Text       = "COMPANY " .. ({"I","II","III","IV"})[idx] .. " — BROKEN"
	self._brokenStroke.Color     = COMPANY_COLORS[idx]
	self._brokenTimerVal.Text    = math.ceil(sd.brokenTimer) .. "s"

	local timerDone = sd.brokenTimer <= 0
	self._brokenTimerVal.TextColor3 = timerDone
		and Color3.fromRGB(55, 200, 90)
		or  Color3.fromRGB(230, 230, 230)

	local clear = not sd.enemyNearby
	self._brokenEnemyVal.Text       = clear and "YES" or "NO"
	self._brokenEnemyVal.TextColor3 = clear
		and Color3.fromRGB(55, 200, 90)
		or  Color3.fromRGB(200, 55, 55)
end

return CompanyHUD