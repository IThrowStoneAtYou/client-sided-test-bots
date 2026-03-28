-->>>>>>>>>>>>
-- NPC_SYSTEM_CLIENT
-- Version 3.5.0
-- Description:
-- Single company: click = left edge, drag right = expand width.
-- Multi company: left edge of company 1 at click, drag right until right edge of last company.
-- Plain click: troops center on click point, facing derived from camera.
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")

local NpcReplicator     = require(ReplicatedStorage.Modules.Shared:WaitForChild("NPC_Replicator_v2"))
local NpcAnimator       = require(ReplicatedStorage.Modules.Shared:WaitForChild("NpcAnimator"))
local RegimentFormation = require(ReplicatedStorage.Modules.Shared:WaitForChild("RegimentFormation"))
local CompanyHUD        = require(ReplicatedStorage.Modules.Client:WaitForChild("CompanyHUD"))

local CLIENT_MODEL   = ReplicatedStorage:WaitForChild("CLIENT")
local DRAG_THRESHOLD = 3
local DOT_SIZE       = Vector3.new(1.2, 0.3, 1.2)
local HIGHLIGHT_TAG  = "CompanyHighlight"

local RANK_SPACING = 4.5   -- must mirror RegimentFormation
local COMPANY_GAP  = 8

local Network = require(game.ReplicatedStorage.Blink.Client)

-- ── State ─────────────────────────────────────────────────────────────
local localPlayer   = Players.LocalPlayer
local camera        = workspace.CurrentCamera
local replicators   = {}
local animators     = {}
local companySlots  = {}   -- [companyIndex] = { [shortId] = true }
local lastFormation = {}   -- [companyIndex] = { ranks, files }

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

-- ── Highlights ────────────────────────────────────────────────────────

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
	local h = Instance.new("Highlight")
	h.Name                = HIGHLIGHT_TAG
	h.FillColor           = CompanyHUD.getColor(companyIndex)
	h.OutlineColor        = CompanyHUD.getColor(companyIndex)
	h.FillTransparency    = 0.62
	h.OutlineTransparency = 0.1
	h.DepthMode           = Enum.HighlightDepthMode.Occluded
	h.Parent              = clientModel
end

local function applyHighlights(selectedList)
	clearHighlights()
	for _, compIdx in ipairs(selectedList) do
		local slots = companySlots[compIdx]
		if not slots then continue end
		for shortId in pairs(slots) do
			local rep = replicators[shortId]
			if rep and rep.Client then addHighlight(rep.Client, compIdx) end
		end
	end
end

-- ── HUD ───────────────────────────────────────────────────────────────
local hud = CompanyHUD.new(function(selectedList)
	applyHighlights(selectedList)
end)

-- ── NPC Registration ──────────────────────────────────────────────────
local function registerNpc(shortId, pos, yaw)
	if replicators[shortId] then return end
	local clientModel   = CLIENT_MODEL:Clone()
	local rep           = NpcReplicator.new(shortId, clientModel)
	rep.Root.CFrame     = buildCFrame(pos, yaw)
	rep:Start()
	replicators[shortId] = rep
	animators[shortId]   = NpcAnimator.new(clientModel)

	for _, compIdx in ipairs(hud:getSelectedList()) do
		if companySlots[compIdx] and companySlots[compIdx][shortId] then
			addHighlight(clientModel, compIdx)
			break
		end
	end
end

-- ── Formation Layout ──────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Returns the total horizontal span of all selected companies using lastFormation,
-- used to back-compute the left edge for plain clicks.
local function getTotalWidthFromLastFormation(selectedList): number
	local total = 0
	local nc    = 0
	
	for _, compIdx in ipairs(selectedList) do
		local slots = companySlots[compIdx]
		local count = 0
		for _ in pairs(slots or {}) do
			count += 1
		end
		
		if count == 0 then 
			continue 
		end
		
		local f     = lastFormation[compIdx]
		local files = f and f.files or math.min(count, 10)
		total += (files - 1) * RANK_SPACING
		nc    += 1
	end
	
	if nc > 1 then 
		total += (nc - 1) * COMPANY_GAP
	end
	
	return total
end

-->>>>>>>>>>>>
-- Core layout function. All placement is LEFT-BASED.
--
-- leftEdge     : world position of the left edge of the leftmost company.
-- rightDir     : unit vector pointing "right" across the formation line.
--               facingDir is derived as 90° CCW: (rightDir.Z, 0, -rightDir.X).
-- totalDragMag : total drag distance covering ALL companies + gaps.
--               nil = use lastFormation ranks/files per company.
--
-- For single company:  totalDragMag == width of that one company.
-- For multi company:   totalDragMag == sum of all company widths + all gaps.
local function computeCompanyLayouts(selectedList, leftEdge, rightDir, totalDragMag)
	-- Facing is always perpendicular to the right/drag direction
	local facingDir = Vector3.new(rightDir.Z, 0, -rightDir.X)

	-- Collect valid companies
	local infos = {}
	for _, compIdx in ipairs(selectedList) do
		local slots = companySlots[compIdx]
		local count = 0
		
		for _ in pairs(slots or {}) do 
			count += 1 
		end
		
		if count > 0 then
			infos[#infos + 1] = { compIdx = compIdx, count = count }
		end
	end

	if #infos == 0 then 
		return {}, facingDir 
	end

	local nc = #infos

	-- Per-company drag magnitude: subtract all gaps then divide evenly
	local perCompanyMag
	if totalDragMag then
		local gapTotal  = (nc - 1) * COMPANY_GAP
		perCompanyMag   = math.max((totalDragMag - gapTotal) / nc, 0)
	end

	local cursor = 0   -- running offset from leftEdge along rightDir (studs)
	local result = {}

	for _, info in ipairs(infos) do
		local ranks, files
		if perCompanyMag then
			ranks, files = RegimentFormation.dragToLayout(info.count, perCompanyMag)
		else
			local f = lastFormation[info.compIdx]
			files   = f and f.files or math.min(info.count, 10)
			ranks   = f and f.ranks or math.ceil(info.count / files)
		end

		local compWidth  = (files - 1) * RANK_SPACING
		
		-- Company anchor = center of this company's front rank
		local compCenter = leftEdge + rightDir * (cursor + compWidth / 2)
		cursor += compWidth + COMPANY_GAP

		local anchorCF = CFrame.lookAt(compCenter, compCenter + facingDir)
		local slots    = RegimentFormation.getSlots(anchorCF, info.count, ranks, files)

		result[#result + 1] = {
			compIdx = info.compIdx,
			anchor  = compCenter,
			ranks   = ranks,
			files   = files,
			slots   = slots,
			color   = CompanyHUD.getColor(info.compIdx),
		}
	end

	return result, facingDir
end

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
	if not rep then 
		return
	end
	
	if rep.Client then 
		rep.Client:Destroy()
	end
	
	rep:Destroy()
	replicators[shortId] = nil
	
	local anim = animators[shortId]
	if anim then
		anim:Destroy()
		animators[shortId] = nil
	end
end)

Network.NpcCompanySync.On(function(data)
	companySlots = {}
	for _, entry in ipairs(data) do
		local slotSet = {}
		for _, sid in ipairs(entry.slots) do slotSet[sid] = true end
		companySlots[entry.index] = slotSet
	end
	hud:syncCompanies(data)
	applyHighlights(hud:getSelectedList())
end)

-- ── Raycast / Preview Parts ───────────────────────────────────────────
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function updateRayFilter()
	local list = { workspace:WaitForChild("Npc_Registry") }
	if localPlayer.Character then 
		table.insert(list, localPlayer.Character)
	end
	
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
		slotDots[#slotDots + 1] = createPreviewPart(Color3.fromRGB(255, 215, 60), DOT_SIZE)
	end
end

local function showColoredDots(entries)
	ensurePool(#entries)
	for i, e in ipairs(entries) do
		slotDots[i].CFrame       = e.cf
		slotDots[i].Color        = e.color
		slotDots[i].Transparency = 0.3
	end
	for i = #entries + 1, activeDots do
		slotDots[i].Transparency = 1
	end
	activeDots = #entries
end

-->>>>>>>>>>>>
-- Places the arrow at the lateral midpoint between all company anchors.
local function setArrow(layouts, facingDir)
	if #layouts == 0 then return end
	local anchorSum = Vector3.zero
	local maxDepth  = 0
	for _, layout in ipairs(layouts) do
		anchorSum += layout.anchor
		local _, depth = RegimentFormation.getPreviewSize(layout.ranks, layout.files)
		if depth > maxDepth then maxDepth = depth end
	end
	local centre   = anchorSum / #layouts
	local arrowLen = math.clamp(maxDepth * 0.3, 2, 6)
	previewArrow.Size   = Vector3.new(0.4, 0.4, arrowLen)
	previewArrow.CFrame = CFrame.lookAt(
		centre + facingDir * (arrowLen / 2 + 0.5),
		centre + facingDir * (arrowLen / 2 + 0.5) + facingDir
	)
	previewArrow.Transparency = 0
end

local function hidePreview()
	for i = 1, activeDots do slotDots[i].Transparency = 1 end
	activeDots = 0
	previewArrow.Transparency = 1
end

local function spawnFadeDots(layouts, facingDir)
	if #layouts == 0 then return end
	local fadeInfo  = TweenInfo.new(1.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	local anchorSum = Vector3.zero
	local maxDepth  = 0

	for _, layout in ipairs(layouts) do
		local _, depth = RegimentFormation.getPreviewSize(layout.ranks, layout.files)
		if depth > maxDepth then maxDepth = depth end
		anchorSum += layout.anchor
		for _, slotCF in ipairs(layout.slots) do
			local p = createPreviewPart(layout.color, DOT_SIZE)
			p.CFrame       = slotCF
			p.Transparency = 0.3
			local t = TweenService:Create(p, fadeInfo, { Transparency = 1, Size = DOT_SIZE * 0.5 })
			t:Play()
			t.Completed:Connect(function() p:Destroy() end)
		end
	end

	local centre   = anchorSum / #layouts
	local arrowLen = math.clamp(maxDepth * 0.3, 2, 6)
	local a = createPreviewPart(Color3.fromRGB(255, 255, 255), Vector3.new(0.4, 0.4, arrowLen))
	a.CFrame = CFrame.lookAt(
		centre + facingDir * (arrowLen / 2 + 0.5),
		centre + facingDir * (arrowLen / 2 + 0.5) + facingDir
	)
	a.Transparency = 0
	local t2 = TweenService:Create(a, fadeInfo, { Transparency = 1 })
	t2:Play()
	t2.Completed:Connect(function() a:Destroy() end)
end

local function raycastMouse()
	local pos    = UserInputService:GetMouseLocation()
	local ray    = camera:ViewportPointToRay(pos.X, pos.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000, rayParams)
	return result and result.Position or nil
end

-- ── Drag & Order ──────────────────────────────────────────────────────
local dragActive = false
local anchorPos  = nil   -- left edge of company 1 (world space)
local dragDir    = nil   -- last known rightDir unit vector (nil until drag threshold crossed)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not hud:hasSelection() then return end

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

	-- delta direction IS the rightDir — drag left-to-right expands the formation
	dragDir = delta.Unit

	local layouts, facingDir = computeCompanyLayouts(hud:getSelectedList(), anchorPos, dragDir, mag)
	if #layouts == 0 then return end

	local dotEntries = {}
	for _, layout in ipairs(layouts) do
		for _, slotCF in ipairs(layout.slots) do
			dotEntries[#dotEntries + 1] = { cf = slotCF, color = layout.color }
		end
	end
	showColoredDots(dotEntries)
	setArrow(layouts, facingDir)
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragActive then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

	dragActive = false
	hidePreview()

	if not anchorPos or not hud:hasSelection() then
		anchorPos = nil
		dragDir   = nil
		return
	end

	local selectedList = hud:getSelectedList()
	local layouts, facingDir

	if dragDir then
		-- Drag: get final mouse pos for most accurate magnitude
		local hit      = raycastMouse()
		local delta    = hit and Vector3.new(hit.X - anchorPos.X, 0, hit.Z - anchorPos.Z) or Vector3.zero
		local mag      = delta.Magnitude
		local finalDir = (mag > DRAG_THRESHOLD) and delta.Unit or dragDir
		local finalMag = math.max(mag, DRAG_THRESHOLD)

		layouts, facingDir = computeCompanyLayouts(selectedList, anchorPos, finalDir, finalMag)
	else
		-- Plain click: derive rightDir from camera facing, center group on anchorPos
		local look = camera.CFrame.LookVector
		facingDir  = Vector3.new(look.X, 0, look.Z)
		if facingDir.Magnitude < 0.01 then facingDir = Vector3.new(0, 0, -1) end
		facingDir  = facingDir.Unit

		-- rightDir is 90° CW of facingDir: if facing (0,0,-1), right = (1,0,0) ✓
		local rightDir   = Vector3.new(-facingDir.Z, 0, facingDir.X)
		local totalWidth = getTotalWidthFromLastFormation(selectedList)
		
		-- Back-compute leftEdge so the group is centered on anchorPos
		local leftEdge   = anchorPos - rightDir * (totalWidth / 2)

		layouts, facingDir = computeCompanyLayouts(selectedList, leftEdge, rightDir, nil)
	end

	if #layouts == 0 then
		anchorPos = nil
		dragDir   = nil
		return
	end

	spawnFadeDots(layouts, facingDir)
	for _, layout in ipairs(layouts) do
		lastFormation[layout.compIdx] = { ranks = layout.ranks, files = layout.files }
		Network.NpcOrderCommand.Fire(layout.anchor, facingDir, layout.ranks, layout.files, layout.compIdx)
	end

	anchorPos = nil
	dragDir   = nil
end)

Network.NpcReady.Fire()