-->>>>>>>>>>>>
-- ClientScript
-- Version 3.5.0
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
-- Central state tracking for all NPCs and user interactions

local localPlayer   = Players.LocalPlayer
local camera        = workspace.CurrentCamera
local replicators   = {}   -- [shortId] = NpcReplicator (smooth movement interpolation)
local animators     = {}   -- [shortId] = NpcAnimator (walk/idle state)
local companySlots  = {}   -- [companyIndex] = { [shortId] = true } (NPC membership)
local lastFormation = {}   -- [companyIndex] = { ranks, files } (cached for drag operations)
local musketUtils = {}   -- [shortId] = MusketUtils instance (combat/weapon)
local canAttack   = {}   -- [ownerUserId][companyIndex] = boolean (combat state)
local bearerIds   = {}   -- [shortId] = true (flag-carrier NPCs)
local npcOwners   = {}   -- [shortId] = ownerUserId (tracks NPC ownership)

local localTimeRemaining = 0
local localTimerMode     = "none"   -- "match" | "intermission" | "none"

local meleeMode = {}  -- [companyIndex] = boolean

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

local bearerMode = {}  -- [companyIndex] = number, mirrors server state

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

--local compass = CompassHUD.new()

-- ── NPC Registration ──────────────────────────────────────────────────
-- Creates client-side NPC instances when server announces new NPC

local function registerNpc(shortId, pos, yaw, teamName, isBearer, companyIndex, ownerUserId)
	-- Abort if already registered
	if replicators[shortId] then return end
	
	-- Clone model template and create replicator for smooth interpolation
	local clientModel = CLIENT_MODEL:Clone()
	clientModel.Name = "NPC_" .. shortId
	local initialCF = buildCFrame(pos, yaw)

	local rep = NpcReplicator.new(shortId, clientModel)
	rep.Root.CFrame = initialCF
	rep:PushNetworkSnapshot(initialCF, workspace:GetServerTimeNow())

	local anim = NpcAnimator.new(clientModel)
	rep:SetAnimator(anim)

	replicators[shortId] = rep
	animators[shortId] = anim

	if teamName then
		clientModel:SetAttribute("TeamName", teamName)
	end
	
	if companyIndex then
		clientModel:SetAttribute("CompanyIndex", companyIndex)
	end

	-- Only store owner if it's a real player (0 = no owner)
	ownerUserId = ownerUserId or 0
	clientModel:SetAttribute("OwnerUserId", ownerUserId)
	npcOwners[shortId] = ownerUserId

	-- Apply Regiment Rigs (Visuals)
	local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	if ownerPlayer then
		local function tryApply()
			print(string.format("[OutfitGiver] Checking attributes for NPC %d (Owner: %s)", shortId, ownerPlayer.Name))
			local sideIdx = ownerPlayer:GetAttribute("SideIndex")
			local regIdx  = ownerPlayer:GetAttribute("RegimentIndex")
			
			if sideIdx and regIdx then
				print(string.format("[OutfitGiver] Found Side: %d, Reg: %d", sideIdx, regIdx))
				local rInfo, nKey = RegimentData.GetRegimentInfo(sideIdx, regIdx)
				if rInfo and nKey then
					print(string.format("[OutfitGiver] Applying: %s from %s", rInfo.key, nKey))
					rep:ApplyRegimentRig(nKey, rInfo.key)
				else
					warn("[OutfitGiver] RegimentData lookup failed for indices provided")
				end
				return true
			end
			print("[OutfitGiver] Attributes not ready yet...")
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

		-- Company anchor = center of this company's front rank
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
-- Network events from server via Blink

-- Single NPC spawn event (sent when an individual NPC is created)
Network.NpcSpawn.On(function(data)
	if data.Type == "Single" then
		print(string.format("[Client] Registering Single NPC: %d", data.id))
		registerNpc(
			data.id, 
			data.pos,
			data.yaw,
			data.teamName,
			data.isBearer,
			data.companyIndex,
			data.ownerUserId
		)
	elseif data.Type == "Batch" then
		print(string.format("[Client] Registering Batch: %d NPCs", #data.list))
		for _, entry in ipairs(data.list) do
			registerNpc(
				entry.id,
				entry.pos,
				entry.yaw,
				entry.teamName,
				entry.isBearer,
				entry.companyIndex,
				entry.ownerUserId
			)
		end
	end
end)

-- Batch position update event (unreliable, high frequency: 20/sec near, 4/sec far)
-- chunk = array of {id, pos, yaw} for multiple NPCs
-- Used for smooth movement via snapshot interpolation
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
	
	local mu = musketUtils[shortId]
	if mu then
		mu:Destroy()
		musketUtils[shortId] = nil
	end

	bearerIds[shortId] = nil
	npcOwners[shortId] = nil
end)

-- Company sync event (reliable: sent when companies change or player joins)
-- data = array of {index, count, slots{...}, bearers[...]} for each company
-- Updates HUD counts and resets company membership tracking
Network.NpcCompanySync.On(function(data)
	print("[Client] Received Company Sync. Total Companies:", #data)
	-- Only clear owner entries for the local player's previous NPCs.
	-- Wiping the whole table also removes other players' NPC owner mappings,
	-- which breaks NpcCanAttackSync for those players.
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

	-- Clear stale meleeMode entries for companies that no longer exist
	for compIdx in pairs(meleeMode) do
		if not companySlots[compIdx] then
			meleeMode[compIdx] = nil
		end
	end

	-- Re-populate npcOwners from stored model attributes.
	-- Every sync clears npcOwners for old slots; without this step
	-- all surviving and freshly-respawned bots lose hit-detection ownership.
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

-- applies server canAttack state and enforces it on all matching NPCs
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

		-- Fall back to the attribute in case npcOwners was cleared by a
		-- NpcCompanySync that arrived after this NPC was registered.
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
	print(string.format("[Client] NPC %d Firing", shortId))

	-- If we own this NPC, we are responsible for hit detection
	if npcOwners[shortId] == localPlayer.UserId then
		-- Gather friendlies to prevent friendly-fire/body-blocking
		local ignore = {}
		local myTeam = replicators[shortId].Client:GetAttribute("TeamName")
		for _, otherRep in pairs(replicators) do
			if otherRep.Client and otherRep.Client:GetAttribute("TeamName") == myTeam then
				table.insert(ignore, otherRep.Client)
			end
		end

		local victimId, actualHitPos = mu:CalculateHit(targetPos, ignore)
		
		-- Report the hit/miss to the server
		Network.NpcHitReport.Fire(shortId, victimId, actualHitPos)
		
		-- Play visuals immediately for ourselves
		mu:PlayFire(actualHitPos)
	else
		-- We are seeing someone else's shot (or a server bot's shot)
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
local anchorPos  = nil   -- left edge of company 1 (world space)
local dragDir    = nil   -- last known rightDir unit vector (nil until drag threshold crossed)

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
	
	-- Keyboard shortcuts: 1-4 to select company cards
	if input.UserInputType == Enum.UserInputType.Keyboard then
		local key = input.KeyCode
		
		-- Helper function for number key selection
		local function handleCompanyKeySelect(companyIndex)
			-- Don't select if company doesn't exist
			if not hud._companies or not hud._companies[companyIndex] then return end
			
			local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			if shift then
				-- Shift+number: toggle
				hud:toggleSelected(companyIndex)
			else
				-- Number: exclusive select, or deselect if already selected
				local list = hud:getSelectedList()
				if #list == 1 and list[1] == companyIndex then
					hud:setSelected(nil)  -- Deselect if clicking same company
				else
					hud:setSelected(companyIndex)
				end
			end
		end
		
		-- Number keys 1-4 for company selection
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
			-- pacing only toggles from J; otherwise resets to J first
			local selectedList = hud:getSelectedList()
			if #selectedList == 0 then return end
			for _, compIdx in ipairs(selectedList) do
				if not companySlots[compIdx] then
					continue 
				end
				
				local current = bearerMode[compIdx] or BEARER_MODE_CENTER
				local next    = (current == BEARER_MODE_CENTER) and BEARER_MODE_PACING or  BEARER_MODE_CENTER
				
				Network.BearerModeCommand.Fire(compIdx, next)
				bearerMode[compIdx] = next
			end
		elseif key == Enum.KeyCode.E then
			local selectedList = hud:getSelectedList()
			if #selectedList == 0 then return end
			for _, compIdx in ipairs(selectedList) do
				if not companySlots[compIdx] then continue end
				-- Send the toggle to the server (it will broadcast back)
				Network.NpcCanAttackToggle.Fire(compIdx)
			end
			
		elseif key == Enum.KeyCode.T then
			local selectedList = hud:getSelectedList()
			if #selectedList == 0 then return end
			for _, compIdx in ipairs(selectedList) do
				if not companySlots[compIdx] then continue end
				local newMelee = not meleeMode[compIdx]
				meleeMode[compIdx] = newMelee
				hud:setMeleeState(compIdx, newMelee) -- Update HUD to show melee state
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
			-- Only request reset if we are actually on a team other than "NO TEAM"
			if currentTeam and currentTeam.Name ~= "NO TEAM" then
				Network.RequestTeamReset.Fire()
			end
			return
		end
	end

	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not hud:hasSelection() then return end

	local selectedList = hud:getSelectedList()

	-- Check if any selected company is in melee mode
	if #selectedList > 0 then
	--	print("[Melee Input] Click detected with", #selectedList, "companies selected.")
	end
	
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
			local DETECT_RADIUS = 30  -- More forgiving radius for group targeting

			-- Collect all enemy NPC candidates near the click
			local candidates = {}
			local registry = workspace:FindFirstChild("Npc_Registry")
			local closestTarget, minTargetDist = nil, math.huge

			if registry then
				for shortId, rep in pairs(replicators) do
					if not (rep and rep.Client) then continue end
					
					local ownerUserId = rep.Client:GetAttribute("OwnerUserId") 
					local compIdx     = rep.Client:GetAttribute("CompanyIndex")
					
					-- Enhanced targeting debug
					if ownerUserId == nil or compIdx == nil then 
						continue 
					end
					
					if ownerUserId == localPlayer.UserId then 
						continue -- skip own bots
					end

					local root = rep.Root
					if not root then continue end
					
					-- Flat distance check
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
				return  -- consumed the click
			end
		end

		-- Click missed all enemies — fall through to normal formation drag
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
		NpcPreview.hide() return -- yea
	end

	-- delta direction IS the rightDir — drag left-to-right expands the formation
	dragDir = delta.Unit

	local layouts, facingDir = computeCompanyLayouts(hud:getSelectedList(), anchorPos, dragDir, mag)
	if #layouts == 0 then 
		NpcPreview.hide() return -- uh yea
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
		if facingDir.Magnitude < 0.01 then 
			facingDir = Vector3.new(0, 0, -1)
		end
		
		facingDir  = facingDir.Unit

		-- rightDir is 90° CW of facingDir: if facing (0,0,-1), right = (1,0,0)
		-- Added a fallback for rightDir to ensure cross product stability
		local rightDir   = facingDir:Cross(Vector3.new(0, 1, 0)).Unit
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

-- ── Central render loop (runs once per frame, drives all replicators) ───────────

RunService.RenderStepped:Connect(function(dt)
	local serverTime = workspace:GetServerTimeNow()
	local parts   = {}
	local cframes = {}

	-- ── Client-side timer countdown ───────────────────────────────────
	if localTimerMode ~= "none" then
		localTimeRemaining = math.max(0, localTimeRemaining - dt)
		if localTimerMode == "match" then
			matchHud:setTimerOnly(localTimeRemaining)
		elseif localTimerMode == "intermission" then
			matchHud:setIntermissionTimer(localTimeRemaining)
		end
	end

	-- ── NPC render ────────────────────────────────────────────────────
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

-- to avoid server firing at client BEFORE client got a time to load it self.
-- also work as late-join
print("[Client] Sending NpcReady signal to server...")
Network.NpcReady.Fire()

AdminPanel.new(Network)

local function toggleHUDs(menuVisible)
	hud:SetVisible(not menuVisible)
	matchHud:SetVisible(not menuVisible)
	notifHud:SetVisible(not menuVisible)
end
local teamMenu = TeamSelectMenu.new(Network, toggleHUDs)

-- ── Auto-Show Menu for No Team ──────────────────────────────────────
local function checkTeamRequirement()
	local currentTeam = localPlayer.Team
	if not currentTeam or currentTeam.Name == "NO TEAM" then
		teamMenu:show()
	end
end

-- Run initial check and listen for team resets
checkTeamRequirement()
localPlayer:GetPropertyChangedSignal("Team"):Connect(checkTeamRequirement)