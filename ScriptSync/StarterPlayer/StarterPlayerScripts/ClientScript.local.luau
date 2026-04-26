-->>>>>>>>>>>>
-- ClientScript
-- Version 3.6.0
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local RunService 		= game:GetService("RunService")

local CombatGui = ReplicatedStorage.Modules.Client.Modules.CombatGui

local NpcReplicator     = require(ReplicatedStorage.Modules.Shared:WaitForChild("NPC_Replicator_v2"))
local NpcAnimator       = require(ReplicatedStorage.Modules.Shared:WaitForChild("NpcAnimator"))
local RegimentFormation = require(ReplicatedStorage.Modules.Shared:WaitForChild("RegimentFormation"))
local MusketUtils 		= require(ReplicatedStorage.Modules.Shared:WaitForChild("MusketUtils"))
local RegimentData      = require(ReplicatedStorage.Modules.Shared:WaitForChild("RegimentData"))
local AdminPanel        = require(ReplicatedStorage.Modules.Client.Modules:WaitForChild("AdminPanel"))

local TeamSelectMenu = require(ReplicatedStorage.Modules.Client.Modules:WaitForChild("TeamSelectMenu"))
local FlagController = require(ReplicatedStorage.Modules.Client.Modules:WaitForChild("FlagController"))

-- Combat Gui
local CompanyHUD        = require(CombatGui.CompanyHUD)
local CompassHUD        = require(CombatGui.CompassHUD)
local MatchHUD 			= require(CombatGui.MatchHUD)
local NotificationHUD 	= require(CombatGui.NotificationHUD)
local NpcPreview        = require(CombatGui.NpcPreview)

local CLIENT_MODEL   = ReplicatedStorage:WaitForChild("CLIENT")
local DRAG_THRESHOLD = 3
local COMPANY_GAP  = 10

local Network = require(game.ReplicatedStorage.Blink.Client)

-- ── State ─────────────────────────────────────────────────────────────
local localPlayer   = Players.LocalPlayer
local camera        = workspace.CurrentCamera
local replicators   = {}
local animators     = {}
local companySlots  = {}
local lastFormation = {}
local musketUtils   = {}
local canAttack     = {}
local bearerIds     = {}
local npcOwners     = {}
local lastHitReport = {}

-- Tracks which NPC is currently holding each company's flag.
-- [ownerUserId][compIdx] = shortId
local flagHolders = {}

local localTimeRemaining = 0
local localTimerMode     = "none"   -- "match" | "intermission" | "none"

local meleeMode = {}

local meleeRayParams = RaycastParams.new()
meleeRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function updateMeleeRayFilter()
	local list = { workspace:WaitForChild("Npc_Registry") }
	if localPlayer.Character then table.insert(list, localPlayer.Character) end
	meleeRayParams.FilterDescendantsInstances = list
end
updateMeleeRayFilter()
localPlayer.CharacterAdded:Connect(updateMeleeRayFilter)

local BEARER_MODE_CENTER = 0
local BEARER_MODE_LEFT   = 1
local BEARER_MODE_RIGHT  = 2
local BEARER_MODE_PACING = 3

local bearerMode = {}

local function ensureFolder(name)
	if not workspace:FindFirstChild(name) then
		local f = Instance.new("Folder")
		f.Name   = name
		f.Parent = workspace
	end
end

ensureFolder("Npc_Registry")

local function buildCFrame(pos, yaw)
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

-- ── HUD ───────────────────────────────────────────────────────────────
local hud = CompanyHUD.new(function(selectedList)
	NpcPreview.applyHighlights(replicators, companySlots, selectedList)
end)

local matchHud = MatchHUD.new()

local notifHud = NotificationHUD.new()

-- ── NPC Registration ──────────────────────────────────────────────────
local function registerNpc(shortId, pos, yaw, teamName, isBearer, companyIndex, ownerUserId, role)

	role = role or "ranker"

	if replicators[shortId] then return end

	local clientModel = CLIENT_MODEL:Clone()
	clientModel.Name = "NPC_" .. shortId
	local initialCF = buildCFrame(pos, yaw)

	local rep = NpcReplicator.new(shortId, clientModel)
	rep.Root.CFrame = initialCF
	rep:PushNetworkSnapshot(initialCF, workspace:GetServerTimeNow())

	local anim = NpcAnimator.new(clientModel)
	rep:SetAnimator(anim)

	if isBearer and ownerUserId and companyIndex then
		if not flagHolders[ownerUserId] then flagHolders[ownerUserId] = {} end
		flagHolders[ownerUserId][companyIndex] = shortId
		FlagController.attachToNpc(clientModel)
	end

	replicators[shortId] = rep
	animators[shortId] = anim

	if teamName then
		clientModel:SetAttribute("TeamName", teamName)
	end

	if companyIndex then
		clientModel:SetAttribute("CompanyIndex", companyIndex)
	end

	ownerUserId = ownerUserId or 0
	clientModel:SetAttribute("OwnerUserId", ownerUserId)
	npcOwners[shortId] = ownerUserId

	local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	if ownerPlayer then
		local function tryApply()
			local sideIdx = ownerPlayer:GetAttribute("SideIndex")
			local regIdx  = ownerPlayer:GetAttribute("RegimentIndex")

			if sideIdx and regIdx then
				local rInfo, nKey = RegimentData.GetRegimentInfo(sideIdx, regIdx)
				if rInfo and nKey then
					rep:ApplyRegimentRig(nKey, rInfo.key, role)
				end
				return true
			end
			return false
		end

		if not tryApply() then
			local conn
			conn = ownerPlayer.AttributeChanged:Connect(function()
				if tryApply() then conn:Disconnect() end
			end)
		end
	end

	if not isBearer then
		local mu = MusketUtils.new(clientModel, teamName)
		if companyIndex and ownerUserId ~= 0 then
			local ownerState = canAttack[ownerUserId]
			local shouldShoot = true

			if ownerState and ownerState[companyIndex] ~= nil then
				shouldShoot = ownerState[companyIndex]
			end

			mu:SetCanShoot(shouldShoot)
		else
			mu:SetCanShoot(true)
		end
		musketUtils[shortId] = mu
	end

	for _, compIdx in ipairs(hud:getSelectedList()) do
		if companySlots[compIdx] and companySlots[compIdx][shortId] then
			NpcPreview.setHighlightVisible(clientModel, compIdx, true)
			break
		end
	end
end

local function fireBearerMode(mode: number)
	local selectedList = hud:getSelectedList()
	if #selectedList == 0 then return end
	for _, compIdx in ipairs(selectedList) do
		if not companySlots[compIdx] then
			continue 
		end

		Network.BearerModeCommand.Fire(compIdx, mode)
		bearerMode[compIdx] = mode
	end
end

-- ── Formation Layout ──────────────────────────────────────────────────

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

		local soldierCount = math.max(0, count - 1)
		if soldierCount == 0 then
			nc += 1
			continue
		end

		local f     = lastFormation[compIdx]
		local files = f and f.files or math.min(soldierCount, 10)
		total += (files - 1) * RegimentFormation.RANK_SPACING
		nc    += 1
	end

	if nc > 1 then 
		total += (nc - 1) * COMPANY_GAP
	end

	return total
end

local function computeCompanyLayouts(selectedList, leftEdge, rightDir, totalDragMag)
	local facingDir = Vector3.new(rightDir.Z, 0, -rightDir.X)

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

	local perCompanyMag
	if totalDragMag then
		local gapTotal  = (nc - 1) * COMPANY_GAP
		perCompanyMag   = math.max((totalDragMag - gapTotal) / nc, 0)
	end

	local cursor = 0
	local result = {}

	for _, info in ipairs(infos) do
		local soldierCount = math.max(0, info.count - 1)
		local ranks, files

		if soldierCount > 0 then
			if perCompanyMag then
				ranks, files = RegimentFormation.dragToLayout(soldierCount, perCompanyMag)
			else
				local f = lastFormation[info.compIdx]
				files   = f and f.files or math.min(soldierCount, 10)
				ranks   = f and f.ranks or math.ceil(soldierCount / files)
			end
		else
			ranks, files = 1, 1
		end

		local compWidth = (soldierCount > 0) and (files - 1) * RegimentFormation.RANK_SPACING or 0

		local compCenter = leftEdge + rightDir * (cursor + compWidth / 2)
		cursor += compWidth + COMPANY_GAP

		local anchorCF = CFrame.lookAt(compCenter, compCenter + facingDir)
		local slots    = (soldierCount > 0) and RegimentFormation.getSlots(anchorCF, soldierCount, ranks, files) or {}

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
		registerNpc(
			data.id, 
			data.pos,
			data.yaw,
			data.teamName,
			data.isBearer,
			data.companyIndex,
			data.ownerUserId,
			data.role
		)
	elseif data.Type == "Batch" then
		for _, entry in ipairs(data.list) do
			registerNpc(
				entry.id,
				entry.pos,
				entry.yaw,
				entry.teamName,
				entry.isBearer,
				entry.companyIndex,
				entry.ownerUserId,
				entry.role
			)
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

-->>>>>>>>>>>>
-- NpcDespawn: clean order matters.
-- Tracks (anim/musket) must be stopped while the Humanoid.Animator still exists,
-- then the flag detached, then the model destroyed via the replicator.
Network.NpcDespawn.On(function(shortId)
	-- Guard: server fires this once from killNpc; heartbeat sweep may fire again.
	if not replicators[shortId] then return end

	-- 1. Stop animation tracks while Humanoid.Animator is still alive.
	local anim = animators[shortId]
	if anim then
		animators[shortId] = nil
		anim:Destroy()
	end

	-- 2. Stop weapon tracks and destroy musket child model before clientModel goes.
	local mu = musketUtils[shortId]
	if mu then
		musketUtils[shortId] = nil
		mu:Destroy()
	end

	-- 3. Detach flag model before clientModel is destroyed.
	FlagController.detachFromNpc(shortId)
	for _, compTable in pairs(flagHolders) do
		for ci, hid in pairs(compTable) do
			if hid == shortId then compTable[ci] = nil end
		end
	end

	-- 4. Destroy client model via replicator (safe: sub-systems already cleaned).
	local rep = replicators[shortId]
	replicators[shortId] = nil
	rep:Destroy()

	-- 5. Secondary state tables.
	bearerIds[shortId]     = nil
	npcOwners[shortId]     = nil
	lastHitReport[shortId] = nil
end)

Network.NpcCompanySync.On(function(data)
	for _, slots in pairs(companySlots) do
		for shortId in pairs(slots) do
			npcOwners[shortId] = nil
		end
	end

	companySlots = {}
	bearerIds    = {}

	local myUserId = localPlayer.UserId
	if not canAttack[myUserId] then canAttack[myUserId] = {} end

	for _, entry in ipairs(data) do
		local bearerId = entry.slots[1]
		if bearerId then
			bearerIds[bearerId] = true
		end

		local compCanShoot = canAttack[myUserId][entry.index] ~= false
		for i = 2, #entry.slots do
			local sid = entry.slots[i]
			local mu  = musketUtils[sid]
			if mu then
				mu:SetCanShoot(compCanShoot)
			end
		end

		local slotSet = {}
		for _, sid in ipairs(entry.slots) do
			slotSet[sid] = true
			local rep = replicators[sid]
			if rep and rep.Client then
				rep.Client:SetAttribute("CompanyIndex", entry.index)
				NpcPreview.setHighlightVisible(rep.Client, entry.index, false)
			end
		end

		bearerMode[entry.index]   = BEARER_MODE_CENTER
		canAttack[myUserId][entry.index] = canAttack[myUserId][entry.index] ~= false
		companySlots[entry.index] = slotSet
	end

	for compIdx in pairs(meleeMode) do
		if not companySlots[compIdx] then
			meleeMode[compIdx] = nil
		end
	end

	for _, slotSet in pairs(companySlots) do
		for sid in pairs(slotSet) do
			local rep = replicators[sid]
			if rep and rep.Client then
				local stored = rep.Client:GetAttribute("OwnerUserId")
				if stored and stored ~= 0 then
					npcOwners[sid] = stored
				end
			end
		end
	end

	hud:syncCompanies(data)
	NpcPreview.applyHighlights(replicators, companySlots, hud:getSelectedList())
end)

Network.NpcCanAttackSync.On(function(companyIndex, canAttackState, ownerUserId)
	if not canAttack[ownerUserId] then
		canAttack[ownerUserId] = {}
	end

	canAttack[ownerUserId][companyIndex] = canAttackState

	if ownerUserId == localPlayer.UserId then
		hud:setCanAttack(companyIndex, canAttackState)
	end

	for shortId, mu in pairs(musketUtils) do
		local rep = replicators[shortId]
		if not (rep and rep.Client) then continue end

		local npcOwner = npcOwners[shortId] or rep.Client:GetAttribute("OwnerUserId")
		if npcOwner == ownerUserId then
			local idx = rep.Client:GetAttribute("CompanyIndex")
			if idx == companyIndex then
				mu:SetCanShoot(canAttackState)
			end
		end
	end
end)

Network.NpcWeaponState.On(function(shortId, state)
	local mu = musketUtils[shortId]
	if mu then
		mu:PlayState(state)
	end
end)

Network.NpcFire.On(function(shortId, targetPos)
	local mu = musketUtils[shortId]
	if not mu then return end

	if npcOwners[shortId] == localPlayer.UserId then
		local now = os.clock()
		if lastHitReport[shortId] and now - lastHitReport[shortId] < 0.1 then return end
		lastHitReport[shortId] = now

		local ignore = {}
		local myTeam = replicators[shortId] and replicators[shortId].Client:GetAttribute("TeamName")
		for _, otherRep in pairs(replicators) do
			if otherRep.Client and otherRep.Client:GetAttribute("TeamName") == myTeam then
				table.insert(ignore, otherRep.Client)
			end
		end

		local victimId, actualHitPos = mu:CalculateHit(targetPos, ignore)
		Network.NpcHitReport.Fire(shortId, victimId, actualHitPos)
		mu:PlayFire(actualHitPos)
	else
		mu:PlayFire(targetPos)
	end
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

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.Q then
		if hud:hasSelection() then
			hud:setSelected(nil)
		else
			for compIdx in pairs(companySlots) do
				hud:toggleSelected(compIdx)
			end
		end
		return
	end

	if input.UserInputType == Enum.UserInputType.Keyboard then
		local key = input.KeyCode

		local function handleCompanyKeySelect(companyIndex)
			if not hud._companies or not hud._companies[companyIndex] then return end

			local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			if shift then
				hud:toggleSelected(companyIndex)
			else
				local list = hud:getSelectedList()
				if #list == 1 and list[1] == companyIndex then
					hud:setSelected(nil)
				else
					hud:setSelected(companyIndex)
				end
			end
		end

		local numKeys = {Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four}
		local foundIndex = table.find(numKeys, key)
		if foundIndex then
			handleCompanyKeySelect(foundIndex)
			return
		end
	end

	if input.UserInputType == Enum.UserInputType.Keyboard then
		local key = input.KeyCode

		if key == Enum.KeyCode.H then
			fireBearerMode(BEARER_MODE_LEFT)
			return
		elseif key == Enum.KeyCode.J then
			fireBearerMode(BEARER_MODE_CENTER)
			return
		elseif key == Enum.KeyCode.K then
			fireBearerMode(BEARER_MODE_RIGHT)
			return
		elseif key == Enum.KeyCode.L then
			local selectedList = hud:getSelectedList()
			if #selectedList == 0 then return end
			for _, compIdx in ipairs(selectedList) do
				if not companySlots[compIdx] then
					continue 
				end

				local current = bearerMode[compIdx] or BEARER_MODE_CENTER
				local next    = (current == BEARER_MODE_CENTER) and BEARER_MODE_PACING or BEARER_MODE_CENTER

				Network.BearerModeCommand.Fire(compIdx, next)
				bearerMode[compIdx] = next
			end
		elseif key == Enum.KeyCode.E then
			local selectedList = hud:getSelectedList()
			if #selectedList == 0 then return end
			for _, compIdx in ipairs(selectedList) do
				if not companySlots[compIdx] then continue end
				Network.NpcCanAttackToggle.Fire(compIdx)
			end

		elseif key == Enum.KeyCode.T then
			local selectedList = hud:getSelectedList()
			if #selectedList == 0 then return end
			for _, compIdx in ipairs(selectedList) do
				if not companySlots[compIdx] then continue end
				local newMelee = not meleeMode[compIdx]
				meleeMode[compIdx] = newMelee
				hud:setMeleeState(compIdx, newMelee)
				Network.NpcMeleeToggle.Fire(compIdx, newMelee)

				if not newMelee then
					for shortId in pairs(companySlots[compIdx]) do
						local mu = musketUtils[shortId]
						if mu then 
							mu:ExitMelee()
						end
					end
				end
			end
			return
		elseif key == Enum.KeyCode.M then
			local currentTeam = localPlayer.Team
			if currentTeam and currentTeam.Name ~= "NO TEAM" then
				Network.RequestTeamReset.Fire()
			end
			return
		end
	end

	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not hud:hasSelection() then return end

	local selectedList = hud:getSelectedList()

	local anyMelee = false
	for _, compIdx in ipairs(selectedList) do
		if meleeMode[compIdx] then anyMelee = true break end
	end

	if anyMelee then
		local pos    = UserInputService:GetMouseLocation()
		local ray    = camera:ViewportPointToRay(pos.X, pos.Y)
		local result = workspace:Raycast(ray.Origin, ray.Direction * 2000, meleeRayParams)

		if result then
			local clickPos = result.Position
			local DETECT_RADIUS = 30

			local closestTarget, minTargetDist = nil, math.huge

			local registry = workspace:FindFirstChild("Npc_Registry")
			if registry then
				for shortId, rep in pairs(replicators) do
					if not (rep and rep.Client) then continue end

					local ownerUserId = rep.Client:GetAttribute("OwnerUserId") 
					local compIdx     = rep.Client:GetAttribute("CompanyIndex")

					if ownerUserId == nil or compIdx == nil then 
						continue 
					end

					if ownerUserId == localPlayer.UserId then 
						continue
					end

					local root = rep.Root
					if not root then continue end

					local dist = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(clickPos.X, 0, clickPos.Z)).Magnitude
					if dist <= DETECT_RADIUS and dist < minTargetDist then
						minTargetDist = dist
						closestTarget = {
							ownerUserId = ownerUserId,
							compIdx     = compIdx,
						}
					end
				end
			end

			if closestTarget then
				for _, compIdx in ipairs(selectedList) do
					if meleeMode[compIdx] and companySlots[compIdx] then
						Network.NpcMeleeTarget.Fire(compIdx, closestTarget.ownerUserId, closestTarget.compIdx)
					end
				end
				return
			end
		end
	end

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
	if mag < DRAG_THRESHOLD then
		NpcPreview.hide() return
	end

	dragDir = delta.Unit

	local layouts, facingDir = computeCompanyLayouts(hud:getSelectedList(), anchorPos, dragDir, mag)
	if #layouts == 0 then 
		NpcPreview.hide() return
	end

	NpcPreview.update(layouts, facingDir)
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragActive then return end

	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

	dragActive = false
	NpcPreview.hide()

	if not anchorPos or not hud:hasSelection() then
		anchorPos = nil
		dragDir   = nil
		return
	end

	local selectedList = hud:getSelectedList()
	local layouts, facingDir

	if dragDir then
		local hit      = raycastMouse()
		local delta    = hit and Vector3.new(hit.X - anchorPos.X, 0, hit.Z - anchorPos.Z) or Vector3.zero
		local mag      = delta.Magnitude
		local finalDir = (mag > DRAG_THRESHOLD) and delta.Unit or dragDir
		local finalMag = math.max(mag, DRAG_THRESHOLD)

		layouts, facingDir = computeCompanyLayouts(selectedList, anchorPos, finalDir, finalMag)
	else
		local look = camera.CFrame.LookVector
		facingDir  = Vector3.new(look.X, 0, look.Z)
		if facingDir.Magnitude < 0.01 then 
			facingDir = Vector3.new(0, 0, -1)
		end

		facingDir  = facingDir.Unit

		local rightDir   = facingDir:Cross(Vector3.new(0, 1, 0)).Unit
		local totalWidth = getTotalWidthFromLastFormation(selectedList)

		local leftEdge   = anchorPos - rightDir * (totalWidth / 2)

		layouts, facingDir = computeCompanyLayouts(selectedList, leftEdge, rightDir, nil)
	end

	if #layouts == 0 then
		anchorPos = nil
		dragDir   = nil
		return
	end

	NpcPreview.spawnFadeDots(layouts, facingDir)
	for _, layout in ipairs(layouts) do
		lastFormation[layout.compIdx] = { ranks = layout.ranks, files = layout.files }
		Network.NpcOrderCommand.Fire(layout.anchor, facingDir, layout.ranks, layout.files, layout.compIdx)
	end

	anchorPos = nil
	dragDir   = nil
end)

Network.NpcCompanyStrength.On(function(companyIndex, tickets, isBroken, ownerUserId, brokenTimer, enemyNearby)
	if ownerUserId ~= localPlayer.UserId then return end
	hud:setStrength(companyIndex, tickets, isBroken, brokenTimer, enemyNearby)
end)

Network.NpcBecomeBearer.On(function(shortId)
	local mu = musketUtils[shortId]
	if mu then
		mu:Destroy()
		musketUtils[shortId] = nil
	end
	bearerIds[shortId] = true

	local rep = replicators[shortId]
	if rep and rep.Client then
		local ownerId = rep.Client:GetAttribute("OwnerUserId")
		local compIdx = rep.Client:GetAttribute("CompanyIndex")
		if ownerId and compIdx then
			if not flagHolders[ownerId] then flagHolders[ownerId] = {} end
			local oldHolder = flagHolders[ownerId][compIdx]
			if oldHolder and oldHolder ~= shortId then
				FlagController.detachFromNpc(oldHolder)
			end
			flagHolders[ownerId][compIdx] = shortId
			FlagController.attachToNpc(rep.Client)
		end
	end
end)

Network.NpcMeleeState.On(function(shortId, state)
	local mu = musketUtils[shortId]
	if mu then
		if state == 0 then
			mu:ExitMelee()
		else
			mu:PlayMeleeState(state)
		end
	end
end)

Network.MatchUpdate.On(function(t1, t2, timeRemaining)
	localTimeRemaining = timeRemaining
	localTimerMode     = "match"
	matchHud:update(t1, t2, timeRemaining)
end)

Network.MatchEnd.On(function(winner, t1, t2)
	localTimerMode = "none"
	matchHud:showResult(winner, t1, t2)
end)

Network.MatchIntermission.On(function(secondsLeft)
	localTimeRemaining = secondsLeft
	localTimerMode     = "intermission"
	matchHud:showIntermission(secondsLeft)
end)

Network.MatchNotification.On(function(vName, vIdx, aName, aIdx, eType, cost, vColorInt, aColorInt)
	local vColor = Color3.fromRGB(
		math.floor(vColorInt / 65536) % 256,
		math.floor(vColorInt / 256) % 256,
		vColorInt % 256
	)
	local aColor = Color3.fromRGB(
		math.floor(aColorInt / 65536) % 256,
		math.floor(aColorInt / 256) % 256,
		aColorInt % 256
	)
	notifHud:push(vName, vIdx, aName, aIdx, eType, cost, vColor, aColor)
end)

Network.FlagDropped.On(function(ownerUserId, compIdx, pos)
	if flagHolders[ownerUserId] then
		local oldId = flagHolders[ownerUserId][compIdx]
		if oldId then FlagController.detachFromNpc(oldId) end
		flagHolders[ownerUserId][compIdx] = nil
	end
	FlagController.spawnDropped(ownerUserId, compIdx, pos)
end)

Network.FlagPickedUp.On(function(ownerUserId, compIdx, pickerShortId, isFriendly)
	FlagController.removeDropped(ownerUserId, compIdx)

	local rep = replicators[pickerShortId]
	if rep and rep.Client then
		if not flagHolders[ownerUserId] then flagHolders[ownerUserId] = {} end
		local oldId = flagHolders[ownerUserId][compIdx]
		if oldId and oldId ~= pickerShortId then
			FlagController.detachFromNpc(oldId)
		end
		flagHolders[ownerUserId][compIdx] = pickerShortId
		FlagController.attachToNpc(rep.Client)
	end
end)

-->>>>>>>>>>>>
-- FlagCaptureProgress is no longer used for a separate HUD.
-- The server now sends NpcCompanyStrength with isBroken=true and the
-- remaining capture time as brokenTimer, so the existing brokenPrompt
-- in CompanyHUD shows the countdown automatically.
-- Keep a no-op handler so the event doesn't error if the server still fires it.
Network.FlagCaptureProgress.On(function(_ownerUserId, _compIdx, _secondsElapsed)
	-- Intentionally empty: display handled by NpcCompanyStrength / brokenPrompt.
end)

Network.FlagCaptured.On(function(victimUserId, victimCompIdx, captorUserId, captorCompIdx)
	FlagController.removeDropped(victimUserId, victimCompIdx)

	if flagHolders[victimUserId] then
		local holderId = flagHolders[victimUserId][victimCompIdx]
		if holderId then FlagController.detachFromNpc(holderId) end
		flagHolders[victimUserId][victimCompIdx] = nil
	end
end)

-- ── Central render loop ──────────────────────────────────────────────

RunService.RenderStepped:Connect(function(dt)
	local serverTime = workspace:GetServerTimeNow()
	local parts   = {}
	local cframes = {}

	-- Client-side timer countdown
	if localTimerMode ~= "none" then
		localTimeRemaining = math.max(0, localTimeRemaining - dt)
		if localTimerMode == "match" then
			matchHud:setTimerOnly(localTimeRemaining)
		elseif localTimerMode == "intermission" then
			matchHud:setIntermissionTimer(localTimeRemaining)
		end
	end

	-- NPC render
	for _, rep in pairs(replicators) do
		local cf = rep:ComputeCFrame(dt, serverTime)
		if cf then
			parts[#parts + 1]   = rep.Root
			cframes[#cframes + 1] = cf
		end
	end

	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end)

print("[Client] Sending NpcReady signal to server...")
Network.NpcReady.Fire()

AdminPanel.new(Network)

local function toggleHUDs(menuVisible)
	hud:SetVisible(not menuVisible)
	matchHud:SetVisible(not menuVisible)
	notifHud:SetVisible(not menuVisible)
end

local teamMenu = TeamSelectMenu.new(Network, toggleHUDs)

local function checkTeamRequirement()
	local currentTeam = localPlayer.Team
	if not currentTeam or currentTeam.Name == "NO TEAM" then
		teamMenu:show()
	end
end

checkTeamRequirement()
localPlayer:GetPropertyChangedSignal("Team"):Connect(checkTeamRequirement)
