-->>>>>>>>>>>>
-- NPC_SYSTEM_CLIENT
-- Version 3.1.0
-- Cards slide up on hover/select, stay raised when selected.
-- Selected company bots get a Highlight matching card accent color.
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")

local NpcReplicator     = require(ReplicatedStorage.Modules:WaitForChild("NPC_Replicator_v2"))
local NpcAnimator       = require(ReplicatedStorage.Modules:WaitForChild("NpcAnimator"))
local RegimentFormation = require(ReplicatedStorage.Modules:WaitForChild("RegimentFormation"))

local CLIENT_MODEL   = ReplicatedStorage:WaitForChild("CLIENT")
local DRAG_THRESHOLD = 3
local DOT_SIZE       = Vector3.new(1.2, 0.3, 1.2)
local DOT_COLOR      = Color3.fromRGB(255, 215, 60)

local Network = require(game.ReplicatedStorage.Blink.Client)

-- ── State ─────────────────────────────────────────────────────────────
local localPlayer     = Players.LocalPlayer
local camera          = workspace.CurrentCamera
local replicators     = {}
local animators       = {}
local myCompanies     = {}   -- [companyIndex] = { count }
local companySlots    = {}   -- [companyIndex] = { [shortId] = true }
local selectedCompany = nil
local lastFormation   = {}   -- [companyIndex] = { ranks, files }

local function ensureFolder(name)
	if not workspace:FindFirstChild(name) then
		local f = Instance.new("Folder")
		f.Name   = name
		f.Parent = workspace
	end
end
ensureFolder("Npc_Registry")
ensureFolder("Client_Preview_Dots")

local function buildCFrame(pos, yaw)
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

-- ── HUD Constants ─────────────────────────────────────────────────────
local ROMAN          = { "I", "II", "III", "IV" }
local COMPANY_COLORS = {
	Color3.fromRGB(65,  105, 210),  -- I:   Royal Blue
	Color3.fromRGB(200, 55,  55),   -- II:  Red
	Color3.fromRGB(55,  170, 90),   -- III: Green
	Color3.fromRGB(210, 160, 35),   -- IV:  Gold
}

local CARD_W      = 88
local CARD_H      = 122
local CARD_GAP    = 10
local PEEK_H      = 30                             -- px visible when collapsed
local RAISED_OFF  = -18                            -- Y offset from screen bottom when raised
local RESTING_OFF = RAISED_OFF + (CARD_H - PEEK_H) -- = -18 + 92 = 74

local SLIDE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

-- Horizontal center offsets for each card (centered around screen midpoint)
-- Total span = 4*88 + 3*10 = 382 → left edge at -191, each card width+gap = 98
local function cardXOffset(i)
	return -191 + (i - 1) * (CARD_W + CARD_GAP) + CARD_W / 2
end

-- ── Highlight Helpers ─────────────────────────────────────────────────
local HIGHLIGHT_TAG = "CompanyHighlight"

local function clearHighlights()
	for _, rep in pairs(replicators) do
		if rep.Client then
			local h = rep.Client:FindFirstChild(HIGHLIGHT_TAG)
			if h then h:Destroy() end
		end
	end
end

local function addHighlight(clientModel, companyIndex)
	if not clientModel then return end
	local existing = clientModel:FindFirstChild(HIGHLIGHT_TAG)
	if existing then existing:Destroy() end

	local color = COMPANY_COLORS[companyIndex]
	local h = Instance.new("Highlight")
	h.Name                = HIGHLIGHT_TAG
	h.FillColor           = color
	h.OutlineColor        = color
	h.FillTransparency    = 0.62
	h.OutlineTransparency = 0.1
	h.DepthMode           = Enum.HighlightDepthMode.Occluded
	h.Parent              = clientModel
end

local function applyHighlights(companyIndex)
	clearHighlights()
	if not companyIndex then return end
	local slots = companySlots[companyIndex]
	if not slots then return end

	for shortId in pairs(slots) do
		local rep = replicators[shortId]
		if rep and rep.Client then
			addHighlight(rep.Client, companyIndex)
		end
	end
end

-- ── NPC Registration ──────────────────────────────────────────────────
local function registerNpc(shortId, pos, yaw)
	if replicators[shortId] then return end
	local clientModel   = CLIENT_MODEL:Clone()
	local rep           = NpcReplicator.new(shortId, clientModel)
	rep.Root.CFrame     = buildCFrame(pos, yaw)
	rep:Start()
	replicators[shortId] = rep
	animators[shortId]   = NpcAnimator.new(clientModel)

	-- Highlight if already selected and this NPC belongs to selected company
	if selectedCompany
		and companySlots[selectedCompany]
		and companySlots[selectedCompany][shortId]
	then
		addHighlight(clientModel, selectedCompany)
	end
end

-- ── HUD ───────────────────────────────────────────────────────────────
local PlayerGui = localPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name            = "CompanyHUD"
screenGui.ResetOnSpawn    = false
screenGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset  = true
screenGui.Parent          = PlayerGui

-- Cards table: [i] = { frame, countLabel, stroke, hovered, raisedPos, restingPos }
local companyCards = {}

local function refreshCard(i)
	local cd      = companyCards[i]
	local company = myCompanies[i]
	local isSel   = selectedCompany == i

	cd.frame.Visible = company ~= nil
	if not company then return end

	cd.countLabel.Text          = tostring(company.count)
	cd.stroke.Thickness         = isSel and 3 or 1.5
	cd.stroke.Transparency      = isSel and 0 or 0.6
	cd.frame.BackgroundColor3   = isSel
		and Color3.fromRGB(26, 30, 50)
		or  Color3.fromRGB(14, 14, 22)

	local shouldRaise = isSel or cd.hovered
	TweenService:Create(cd.frame, SLIDE_TWEEN, {
		Position = shouldRaise and cd.raisedPos or cd.restingPos
	}):Play()
end

local function updateAllCards()
	for i = 1, 4 do refreshCard(i) end
end

local function setSelectedCompany(idx)
	local prev = selectedCompany
	selectedCompany = idx
	applyHighlights(idx)
	
	-- Refresh both the previously selected and newly selected card
	if prev then refreshCard(prev) end
	if idx  then refreshCard(idx)  end
end

local function createCard(index: number)
	local accent     = COMPANY_COLORS[index]
	local xOff       = cardXOffset(index)
	local raisedPos  = UDim2.new(0.5, xOff, 1, RAISED_OFF)
	local restingPos = UDim2.new(0.5, xOff, 1, RESTING_OFF)

	-- Card frame
	local card = Instance.new("Frame")
	card.Name                   = "Company" .. index
	card.AnchorPoint            = Vector2.new(0.5, 1)
	card.Position               = restingPos
	card.Size                   = UDim2.new(0, CARD_W, 0, CARD_H)
	card.BackgroundColor3       = Color3.fromRGB(14, 14, 22)
	card.BackgroundTransparency = 0.1
	card.Visible                = false
	card.Parent                 = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 9)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color        = accent
	stroke.Thickness    = 1.5
	stroke.Transparency = 0.6
	stroke.Parent       = card

	-- Accent bar
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

	-- "COMPANY" label
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

	-- Roman numeral
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

	-- Divider
	local divider = Instance.new("Frame")
	divider.Size             = UDim2.new(0.6, 0, 0, 1)
	divider.Position         = UDim2.new(0.2, 0, 0, 54)
	divider.BackgroundColor3 = accent
	divider.BackgroundTransparency = 0.5
	divider.BorderSizePixel  = 0
	divider.ZIndex           = 2
	divider.Parent           = card

	-- Bot count
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

	-- "MEN" label
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

	-- Click/hover button (covers whole card)
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
	companyCards[index] = cd

	btn.MouseEnter:Connect(function()
		cd.hovered = true
		if myCompanies[index] then
			TweenService:Create(card, SLIDE_TWEEN, { Position = raisedPos }):Play()
		end
	end)

	btn.MouseLeave:Connect(function()
		cd.hovered = false
		if selectedCompany ~= index and myCompanies[index] then
			TweenService:Create(card, SLIDE_TWEEN, { Position = restingPos }):Play()
		end
	end)

	btn.MouseButton1Click:Connect(function()
		if not myCompanies[index] then return end
		if selectedCompany == index then
			setSelectedCompany(nil)
		else
			setSelectedCompany(index)
		end
	end)
end

for i = 1, 4 do createCard(i) end

-- ── Event Handlers ────────────────────────────────────────────────────

Network.NpcSpawn.On(function(data)
	if data.Type == "Single" then
		registerNpc(data.id, data.pos, data.yaw)
	elseif data.Type == "Batch" then
		for _, entry in ipairs(data.list) do
			registerNpc(entry.id, entry.pos, entry.yaw)
		end
	end
end)

Network.NpcBatch.On(function(timestamp, chunk)
	for _, entry in ipairs(chunk) do
		local rep = replicators[entry.id]
		if rep then
			rep:PushNetworkSnapshot(buildCFrame(entry.pos, entry.yaw), timestamp)
		end
	end
end)

Network.NpcDespawn.On(function(shortId)
	local rep = replicators[shortId]
	if not rep then return end
	if rep.Client then rep.Client:Destroy() end
	rep:Destroy()
	replicators[shortId] = nil

	local anim = animators[shortId]
	if anim then
		anim:Destroy()
		animators[shortId] = nil
	end
end)

Network.NpcCompanySync.On(function(data)
	myCompanies  = {}
	companySlots = {}

	for _, entry in ipairs(data) do
		myCompanies[entry.index] = { count = entry.count }
		local slotSet = {}
		for _, sid in ipairs(entry.slots) do
			slotSet[sid] = true
		end
		companySlots[entry.index] = slotSet
	end

	-- Deselect if company no longer exists
	if selectedCompany and not myCompanies[selectedCompany] then
		selectedCompany = nil
	end

	applyHighlights(selectedCompany)
	updateAllCards()
end)

-- ── Raycast / Preview ─────────────────────────────────────────────────
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function updateRayFilter()
	local list = { workspace:WaitForChild("Npc_Registry") }
	if localPlayer.Character then table.insert(list, localPlayer.Character) end
	rayParams.FilterDescendantsInstances = list
end

updateRayFilter()
localPlayer.CharacterAdded:Connect(updateRayFilter)

local function createPreviewPart(color, size)
	local p = Instance.new("Part")
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CastShadow   = false
	p.Material     = Enum.Material.Neon
	p.Color        = color
	p.Size         = size
	p.Transparency = 1
	p.Parent       = workspace.Client_Preview_Dots
	return p
end

local previewArrow = createPreviewPart(Color3.fromRGB(255, 255, 255), Vector3.new(0.4, 0.4, 4))
local slotDots     = {}
local activeDots   = 0

local function ensurePool(needed)
	while #slotDots < needed do
		slotDots[#slotDots + 1] = createPreviewPart(DOT_COLOR, DOT_SIZE)
	end
end

local function showDots(slots)
	ensurePool(#slots)
	for i, slotCF in ipairs(slots) do
		slotDots[i].CFrame       = slotCF
		slotDots[i].Transparency = 0.3
	end
	for i = #slots + 1, activeDots do
		slotDots[i].Transparency = 1
	end
	activeDots = #slots
end

local function setArrow(centre, facing, depth)
	local arrowLen      = math.clamp(depth * 0.3, 2, 6)
	previewArrow.Size   = Vector3.new(0.4, 0.4, arrowLen)
	previewArrow.CFrame = CFrame.lookAt(
		centre + facing * (arrowLen / 2 + 0.5),
		centre + facing * (arrowLen / 2 + 0.5) + facing
	)
	previewArrow.Transparency = 0
end

local function hidePreview()
	for i = 1, activeDots do slotDots[i].Transparency = 1 end
	activeDots = 0
	previewArrow.Transparency = 1
end

local function spawnFadeDots(slots, anchor, facing, depth)
	local fadeInfo = TweenInfo.new(1.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	for _, slotCF in ipairs(slots) do
		local p = createPreviewPart(DOT_COLOR, DOT_SIZE)
		p.CFrame       = slotCF
		p.Transparency = 0.3
		local t = TweenService:Create(p, fadeInfo, { Transparency = 1, Size = DOT_SIZE * 0.5 })
		t:Play()
		t.Completed:Connect(function() p:Destroy() end)
	end

	local arrowLen = math.clamp(depth * 0.3, 2, 6)
	local a = createPreviewPart(Color3.fromRGB(255, 255, 255), Vector3.new(0.4, 0.4, arrowLen))
	a.CFrame = CFrame.lookAt(
		anchor + facing * (arrowLen / 2 + 0.5),
		anchor + facing * (arrowLen / 2 + 0.5) + facing
	)
	a.Transparency = 0
	local t2 = TweenService:Create(a, fadeInfo, { Transparency = 1 })
	t2:Play()
	t2.Completed:Connect(function() a:Destroy() end)
end

local function buildSlots(leftAnchor, dir, count, mag)
	local ranks, files = RegimentFormation.dragToLayout(count, mag)
	local width, depth = RegimentFormation.getPreviewSize(ranks, files)
	local facing       = Vector3.new(dir.Z, 0, -dir.X)
	local rankCentre   = leftAnchor + dir * (width / 2)
	local anchorCF     = CFrame.lookAt(rankCentre, rankCentre + facing)
	local slots        = RegimentFormation.getSlots(anchorCF, count, ranks, files)
	return slots, rankCentre, facing, ranks, files, width, depth
end

local function raycastMouse()
	local pos    = UserInputService:GetMouseLocation()
	local ray    = camera:ViewportPointToRay(pos.X, pos.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000, rayParams)
	return result and result.Position or nil
end

-- ── Drag & Order ──────────────────────────────────────────────────────
local dragActive = false
local anchorPos  = nil
local dragDir    = nil

local function getSelectedCount()
	if not selectedCompany then return 0 end
	local c = myCompanies[selectedCompany]
	return c and c.count or 0
end

local function getLastFormation()
	local f = selectedCompany and lastFormation[selectedCompany]
	return (f and f.ranks or 1), (f and f.files or 1)
end

local function saveFormation(ranks, files)
	if not selectedCompany then return end
	lastFormation[selectedCompany] = { ranks = ranks, files = files }
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not selectedCompany then return end

	local hit = raycastMouse()
	if not hit then return end

	dragActive = true
	anchorPos  = hit
	dragDir    = nil
end)

UserInputService.InputChanged:Connect(function(input)
	if not dragActive then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	if not anchorPos then return end

	local hit = raycastMouse()
	if not hit then return end

	local delta = Vector3.new(hit.X - anchorPos.X, 0, hit.Z - anchorPos.Z)
	local mag   = delta.Magnitude
	if mag < DRAG_THRESHOLD then hidePreview() return end

	dragDir     = delta.Unit
	local count = getSelectedCount()
	if count < 1 then return end

	local slots, rankCentre, facing, _, _, _, depth = buildSlots(anchorPos, dragDir, count, mag)
	showDots(slots)
	setArrow(rankCentre, facing, depth)
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragActive then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

	dragActive = false
	hidePreview()

	if not anchorPos or not selectedCompany then
		anchorPos = nil
		dragDir   = nil
		return
	end

	local count = getSelectedCount()
	if count == 0 then
		anchorPos = nil
		dragDir   = nil
		return
	end

	local finalSlots, finalAnchor, finalFacing, finalRanks, finalFiles, finalDepth

	if dragDir then
		local hit   = raycastMouse()
		local delta = hit and Vector3.new(hit.X - anchorPos.X, 0, hit.Z - anchorPos.Z) or Vector3.zero
		local slots, rankCentre, facing, ranks, files, _, depth =
			buildSlots(anchorPos, dragDir, count, delta.Magnitude)
		finalSlots, finalAnchor, finalFacing           = slots, rankCentre, facing
		finalRanks,  finalFiles,  finalDepth           = ranks, files, depth
	else
		local look  = camera.CFrame.LookVector
		finalFacing = Vector3.new(look.X, 0, look.Z)
		finalFacing = finalFacing.Magnitude > 0.01 and finalFacing.Unit or Vector3.new(0, 0, -1)
		finalAnchor = anchorPos
		finalRanks, finalFiles = getLastFormation()
		local _, depth = RegimentFormation.getPreviewSize(finalRanks, finalFiles)
		finalDepth     = depth
		local anchorCF = CFrame.lookAt(finalAnchor, finalAnchor + finalFacing)
		finalSlots     = RegimentFormation.getSlots(anchorCF, count, finalRanks, finalFiles)
	end

	saveFormation(finalRanks, finalFiles)
	spawnFadeDots(finalSlots, finalAnchor, finalFacing, finalDepth)
	Network.NpcOrderCommand.Fire(finalAnchor, finalFacing, finalRanks, finalFiles, selectedCompany)

	anchorPos = nil
	dragDir   = nil
end)

Network.NpcReady.Fire()