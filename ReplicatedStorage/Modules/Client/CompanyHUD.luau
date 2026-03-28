-->>>>>>>>>>>>
-- COMPANY_HUD
-- Version 2.0.0
-- Description:
-- Multi-select support. Regular click = exclusive select/deselect.
-- Shift+click = toggle individual company in/out of selection.
-- Fires onSelectionChanged(selectedList: {number}) on every change.
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

local function cardXOffset(i)
	return -191 + (i - 1) * (CARD_W + CARD_GAP) + CARD_W / 2
end

local CompanyHUD = {}
CompanyHUD.__index = CompanyHUD

-->>>>>>>>>>>>
-- Constructor. onSelectionChanged(selectedList: {number}) fires on every change.
function CompanyHUD.new(onSelectionChanged)
	local self        = setmetatable({}, CompanyHUD)
	self._selected    = {}   -- { [index] = true }  (set)
	self._companies   = {}   -- { [index] = { count } }
	self._cards       = {}
	self._onChanged   = onSelectionChanged or function() end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name            = "CompanyHUD"
	gui.ResetOnSpawn    = false
	gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset  = true
	gui.Parent          = playerGui
	self._gui = gui

	for i = 1, 4 do self:_createCard(i) end
	return self
end

-- ── Public API ────────────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Returns the accent Color3 for a given company index.
function CompanyHUD.getColor(index: number): Color3
	return COMPANY_COLORS[index]
end

-->>>>>>>>>>>>
-- Returns a sorted array of currently selected company indices.
function CompanyHUD:getSelectedList(): {number}
	local list = {}
	for idx in pairs(self._selected) do list[#list + 1] = idx end
	table.sort(list)
	return list
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
	for idx in pairs(prev)       do dirty[idx] = true end
	if index then dirty[index] = true end
	for idx in pairs(dirty)      do self:_refreshCard(idx) end
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
	if selChanged then self._onChanged(self:getSelectedList()) end

	for i = 1, 4 do self:_refreshCard(i) end
end

-- ── Internal ──────────────────────────────────────────────────────────

function CompanyHUD:_refreshCard(i: number)
	local cd      = self._cards[i]
	if not cd then return end
	local company = self._companies[i]
	local isSel   = self._selected[i] == true

	cd.frame.Visible = company ~= nil
	if not company then return end

	cd.countLabel.Text        = tostring(company.count)
	cd.stroke.Thickness       = isSel and 3   or 1.5
	cd.stroke.Transparency    = isSel and 0   or 0.6
	cd.frame.BackgroundColor3 = isSel
		and Color3.fromRGB(26, 30, 50)
		or  Color3.fromRGB(14, 14, 22)

	local target = (isSel or cd.hovered) and cd.raisedPos or cd.restingPos
	TweenService:Create(cd.frame, SLIDE_TWEEN, { Position = target }):Play()
end

function CompanyHUD:_createCard(index: number)
	local accent     = COMPANY_COLORS[index]
	local xOff       = cardXOffset(index)
	local raisedPos  = UDim2.new(0.5, xOff, 1, RAISED_OFF)
	local restingPos = UDim2.new(0.5, xOff, 1, RESTING_OFF)

	local card = Instance.new("Frame")
	card.Name                   = "Company" .. index
	card.AnchorPoint            = Vector2.new(0.5, 1)
	card.Position               = restingPos
	card.Size                   = UDim2.new(0, CARD_W, 0, CARD_H)
	card.BackgroundColor3       = Color3.fromRGB(14, 14, 22)
	card.BackgroundTransparency = 0.1
	card.Visible                = false
	card.Parent                 = self._gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 9)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color        = accent
	stroke.Thickness    = 1.5
	stroke.Transparency = 0.6
	stroke.Parent       = card

	local bar = Instance.new("Frame")
	bar.Size             = UDim2.new(1, 0, 0, 7)
	bar.BackgroundColor3 = accent
	bar.BorderSizePixel  = 0
	bar.ZIndex           = 2
	bar.Parent           = card

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 9)
	barCorner.Parent = bar

	local barFill = Instance.new("Frame")
	barFill.Size             = UDim2.new(1, 0, 0, 5)
	barFill.Position         = UDim2.new(0, 0, 1, -5)
	barFill.BackgroundColor3 = accent
	barFill.BorderSizePixel  = 0
	barFill.ZIndex           = 2
	barFill.Parent           = bar

	local compTitle = Instance.new("TextLabel")
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
	divider.Size             = UDim2.new(0.6, 0, 0, 1)
	divider.Position         = UDim2.new(0.2, 0, 0, 54)
	divider.BackgroundColor3 = accent
	divider.BackgroundTransparency = 0.5
	divider.BorderSizePixel  = 0
	divider.ZIndex           = 2
	divider.Parent           = card

	local countLabel = Instance.new("TextLabel")
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
	}
	self._cards[index] = cd

	btn.MouseEnter:Connect(function()
		cd.hovered = true
		if self._companies[index] then
			TweenService:Create(card, SLIDE_TWEEN, { Position = raisedPos }):Play()
		end
	end)

	btn.MouseLeave:Connect(function()
		cd.hovered = false
		if not self._selected[index] and self._companies[index] then
			TweenService:Create(card, SLIDE_TWEEN, { Position = restingPos }):Play()
		end
	end)

	btn.MouseButton1Click:Connect(function()
		if not self._companies[index] then return end
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

		if shift then
			-- Add/remove from multi-selection
			self:toggleSelected(index)
		else
			-- Exclusive: deselect if this is the only one selected, else select only this
			local list = self:getSelectedList()
			if #list == 1 and list[1] == index then
				self:setSelected(nil)
			else
				self:setSelected(index)
			end
		end
	end)
end

return CompanyHUD