-->>>>>>>>>>>>
-- ServerScript
-- Version 4.1.0
-- Core game logic lives in ServerFunctions.
-->>>>>>>>>>>>

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService    = game:GetService("PhysicsService")
local TweenService      = game:GetService("TweenService")

local Network           = require(game.ReplicatedStorage.Blink.Server)
local RegimentFormation = require(ReplicatedStorage.Modules.Shared:WaitForChild("RegimentFormation"))
local NoobPath          = require(ReplicatedStorage.Modules.Packages:WaitForChild("NoobPath"))
local MatchManager      = require(ReplicatedStorage.Modules.Server.Modules.MatchManager)
local ServerFunctions   = require(ReplicatedStorage.Modules.Server.ServerFunctions)
local GameSettings      = require(ReplicatedStorage.Modules.Shared.GameSettings)
local NpcConstants      = require(ReplicatedStorage.Modules.Shared.NpcConstants)

-- ── Destructure NpcConstants for local use ────────────────────────────
-- Pure-networking / performance constants stay as locals below;
-- everything else comes from the shared module.
local SPAWN_OFFSET         = NpcConstants.SPAWN_OFFSET
local COMPANY_GAP          = NpcConstants.COMPANY_GAP
local RANK_SPACING         = NpcConstants.RANK_SPACING
local RANK_DEPTH           = NpcConstants.RANK_DEPTH
local FLAG_OFFSET_Z        = NpcConstants.FLAG_OFFSET_Z
local MOVE_RETRIES         = NpcConstants.MOVE_RETRIES
local MAX_TICKETS          = NpcConstants.MAX_TICKETS
local WEAPON_IDLE          = NpcConstants.WEAPON_IDLE
local WEAPON_DURATIONS     = NpcConstants.WEAPON_DURATIONS
local MELEE_NONE           = NpcConstants.MELEE_NONE
local MELEE_IDLE           = NpcConstants.MELEE_IDLE
local MELEE_BOT_START      = NpcConstants.MELEE_BOT_START
local MELEE_UP_START       = NpcConstants.MELEE_UP_START
local MELEE_ADVANCE        = NpcConstants.MELEE_ADVANCE
local MELEE_DURATIONS      = NpcConstants.MELEE_DURATIONS
local BEARER_MODE_CENTER   = NpcConstants.BEARER_MODE_CENTER
local BEARER_MODE_PACING   = NpcConstants.BEARER_MODE_PACING

-- ── Server-only performance / networking constants ────────────────────
-- These are never needed by ServerFunctions or the client so they stay local.
local CHUNK_SIZE    = 35
local NEAR_RATE     = 1 / 20
local FAR_RATE      = 1 / 4
local CULL_RADIUS   = 500
local DELTA_POS     = 0.08
local DELTA_ROT     = 0.01

local SERVER_MODEL        = ReplicatedStorage:WaitForChild("SERVER")
local ROTATION_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local NPC_COLLISION_GROUP = "NpcGroup"
local CLIENT_NPC_GROUP    = "ClientNpcGroup"

local WANDER_CENTER = Vector3.new(0, 0, 0)
local WANDER_RADIUS = 60
local WANDER_MIN    = 8

if not PhysicsService:IsCollisionGroupRegistered(NPC_COLLISION_GROUP) then
	PhysicsService:RegisterCollisionGroup(NPC_COLLISION_GROUP)
end
if not PhysicsService:IsCollisionGroupRegistered(CLIENT_NPC_GROUP) then
	PhysicsService:RegisterCollisionGroup(CLIENT_NPC_GROUP)
end

PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, NPC_COLLISION_GROUP, false)
PhysicsService:CollisionGroupSetCollidable(CLIENT_NPC_GROUP,    CLIENT_NPC_GROUP,    false)
PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, CLIENT_NPC_GROUP,    false)

local combatRayParams = RaycastParams.new()
combatRayParams.FilterType = Enum.RaycastFilterType.Exclude

-- ── State ─────────────────────────────────────────────────────────────
local activeNpcs      = {}
local nextShortId     = 1
local readyPlayers    = {}
local farLastSent     = {}
local companies       = {}
local serverCanAttack = {}
local sf              -- Forward declaration for ServerFunctions

-- ── Performance Pooling ──────────────────────────────────────────────
local ENTRY_POOL    = {}
local USED_ENTRIES  = {}
local DIRTY_ENTRIES = {}
local FAR_ENTRIES   = {}
local DEAD_IDS      = {}
local NEAR_BUFFER   = {}
local FAR_BUFFER    = {}
local CHUNK_BUFFER  = table.create(CHUNK_SIZE)

local PLAYER_WORK_NEAR = {}
local PLAYER_WORK_FAR  = {}

local function getPooledEntry(id, pos, yaw)
	local t = table.remove(ENTRY_POOL) or { id = 0, pos = Vector3.zero, yaw = 0 }
	t.id = id
	t.pos = pos
	t.yaw = yaw
	table.insert(USED_ENTRIES, t)
	return t
end

local function releaseEntries()
	for _, t in ipairs(USED_ENTRIES) do
		table.insert(ENTRY_POOL, t)
	end
	table.clear(USED_ENTRIES)
end

-- ── Helpers ───────────────────────────────────────────────────────────
local function randomPoint(center, radius, minDist)
	local angle = math.random() * math.pi * 2
	local dist  = minDist + math.random() * (radius - minDist)
	return Vector3.new(center.X + math.cos(angle)*dist, center.Y, center.Z + math.sin(angle)*dist)
end

local function getYaw(cf)
	local _, y, _ = cf:ToEulerAnglesYXZ()
	return y
end

local function cfChanged(cf, lastCF, npc)
	local threshold = (npc.IsRegiment and npc.RegimentTarget and (cf.Position - npc.RegimentTarget).Magnitude < 3) and 1.5 or DELTA_POS
	if (cf.Position - lastCF.Position).Magnitude > threshold then 
		return true
	end
	
	if math.abs(getYaw(cf) - getYaw(lastCF)) > DELTA_ROT then 
		return true
	end
	return false
end

local function getPlayerRootPos(player)
	local char = player.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	
	return root and root.Position or nil
end

local function fireChunked(player, timestamp, entries)
	for i = 1, #entries, CHUNK_SIZE do
		table.clear(CHUNK_BUFFER)
		for j = i, math.min(i + CHUNK_SIZE - 1, #entries) do
			table.insert(CHUNK_BUFFER, entries[j])
		end
		Network.NpcBatch.Fire(player, timestamp, CHUNK_BUFFER)
	end
end

-- ── Company management ────────────────────────────────────────────────
local function syncCompanies(player: Player)
	local playerCompanies = companies[player]
	local data = {}
	if playerCompanies then
		for idx, company in pairs(playerCompanies) do
			table.insert(data, { index = idx, count = #company.slots, slots = company.slots })
		end
		table.sort(data, function(a, b) return a.index < b.index end)
	end
	Network.NpcCompanySync.Fire(player, data)
end

local function broadcastCanAttackState(player, companyIndex, state)
	for p in pairs(readyPlayers) do
		Network.NpcCanAttackSync.Fire(p, companyIndex, state, player.UserId)
	end
end

-- ── NPC Spawn ─────────────────────────────────────────────────────────
local function spawnNpc(spawnCF: CFrame?, suppressNotify: boolean?, ownerPlayer: Player?, companyIndex: number?)
	local shortId  = nextShortId
	nextShortId   += 1

	local model    = SERVER_MODEL:Clone()
	model.Name     = "NPC_" .. shortId
	
	local root     = model.HumanoidRootPart
	local humanoid = model.Humanoid
	humanoid.AutoRotate = true
	humanoid.WalkSpeed  = GameSettings.WALK_SPEED

	local cf = spawnCF or CFrame.new(randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN) + Vector3.new(0,4,0))
	root.CFrame  = cf
	model.Parent = workspace.Npc_Registry_Server

	local teamName = nil
	if ownerPlayer then
		teamName = ownerPlayer.Team and ownerPlayer.Team.Name or ("Player_" .. ownerPlayer.UserId)
		model:SetAttribute("TeamName", teamName)
		if ownerPlayer.Team then
			model:SetAttribute("TeamColor", ownerPlayer.Team.TeamColor)
		end
	end

	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 1
			part.CanTouch     = false
			part.CanQuery     = true
			part.CollisionGroup = NPC_COLLISION_GROUP
			part:SetNetworkOwner(nil)
		end
	end

	local pathfinder = NoobPath.Humanoid(model, { WaypointSpacing = 6, AgentRadius = 1.5, AgentHeight = 5 })

	local npc = {
		ShortId         = shortId,
		Model           = model,
		Root            = root,
		Humanoid        = humanoid,
		Pathfinder      = pathfinder,
		LastMoveTime    = 0,
		LastSentCF      = cf,
		IsRegiment      = spawnCF ~= nil,
		RegimentTarget  = nil,
		MoveRetries     = 0,
		ActiveTween     = nil,
		Health          = 100,
		AimAttachment   = root:WaitForChild("RootAttachment"),
		AimAlign        = root:WaitForChild("AlignOrientation"),
		IsFlagBearer    = false,
		PaceDirection   = 1,
		CompanyOwner    = nil,
		CompanyIndex    = companyIndex,
		Team            = ownerPlayer and ownerPlayer.Team or nil,
		TeamName        = teamName,
		WeaponState     = WEAPON_IDLE,
		WeaponTimer     = 0,
		WeaponTarget    = nil,
		MeleeState      = MELEE_IDLE,
		MeleeTimer      = 0,
		MeleeTarget     = nil,
		MeleeHasHit     = false,
		_meleePathAccum = 0,
	}

	pathfinder.Reached:Connect(function()
		if npc.IsFlagBearer and npc.IsPacing then
			npc.MoveRetries   = 0
			npc.PaceDirection = -(npc.PaceDirection or 1)
			local pComps = companies[npc.CompanyOwner]
			if pComps and pComps[npc.CompanyIndex] then
				local comp     = pComps[npc.CompanyIndex]
				local targetCF = sf.getBearerTarget(npc, comp)
				npc.RegimentTarget = targetCF.Position
				npc.Pathfinder:Run(npc.RegimentTarget)
			end
		elseif npc.IsRegiment then
			npc.MoveRetries = 0
			if npc.RegimentFacing then
				if npc.ActiveTween then npc.ActiveTween:Cancel() end
				local pos      = npc.Root.Position
				local targetCF = CFrame.lookAt(pos, pos + npc.RegimentFacing)
				npc.ActiveTween = TweenService:Create(npc.Root, ROTATION_TWEEN_INFO, { CFrame = targetCF })
				npc.ActiveTween:Play()
			end
		end
	end)

	pathfinder.Trapped:Connect(function()
		npc.MoveRetries += 1
		if npc.MoveRetries <= MOVE_RETRIES and npc.RegimentTarget then
			task.delay(0.5 + math.random()*0.5, function()
				if npc.Model and npc.Model.Parent then
					npc.Pathfinder:Run(npc.RegimentTarget)
					npc.LastMoveTime = os.clock()
				end
			end)
		end
	end)

	activeNpcs[shortId] = npc

	if not suppressNotify then
		for player in pairs(readyPlayers) do
			Network.NpcSpawn.Fire(player, {
				Type         = "Single",
				id           = shortId,
				pos          = cf.Position,
				yaw          = getYaw(cf),
				teamName     = teamName :: any,
				isBearer     = npc.IsFlagBearer,
				companyIndex = companyIndex,
				ownerUserId  = ownerPlayer and ownerPlayer.UserId or 0,
			})
			Network.NpcWeaponState.Fire(player, shortId, WEAPON_IDLE)
		end
	end

	return npc, {
		id           = shortId,
		pos          = cf.Position,
		yaw          = getYaw(cf),
		teamName     = teamName :: any,
		isBearer     = npc.IsFlagBearer,
		companyIndex = companyIndex,
		ownerUserId  = ownerPlayer and ownerPlayer.UserId or 0,
	}
end

-- ── Init ServerFunctions ───────────────────────────────────────────────
-- ctx now only carries shared state and function references.
-- All constants come from NpcConstants, which ServerFunctions requires directly.
sf = ServerFunctions.init({
	-- Shared state
	activeNpcs      = activeNpcs,
	companies       = companies,
	serverCanAttack = serverCanAttack,
	readyPlayers    = readyPlayers,
	farLastSent     = farLastSent,
	combatRayParams = combatRayParams,

	-- Function references (defined before this call above)
	spawnNpc        = spawnNpc,
	syncCompanies   = syncCompanies,
	getYaw          = getYaw,
})

-- ── Spawn/Despawn ─────────────────────────────────────────────────────
local function despawnCompany(player: Player, companyIndex: number)
	local playerCompanies = companies[player]
	if not playerCompanies then return end
	local company = playerCompanies[companyIndex]
	if not company then return end
	for _, shortId in ipairs(company.slots) do
		if activeNpcs[shortId] then
			for p in pairs(readyPlayers) do
				Network.NpcDespawn.Fire(p, shortId)
				if farLastSent[p] then farLastSent[p][shortId] = nil end
			end
			if activeNpcs[shortId].Pathfinder then activeNpcs[shortId].Pathfinder:Destroy() end
			activeNpcs[shortId].Model:Destroy()
			activeNpcs[shortId] = nil
		end
	end
	playerCompanies[companyIndex] = nil
	if serverCanAttack[player] then serverCanAttack[player][companyIndex] = nil end
	for _, otherPlayerComps in pairs(companies) do
		for _, comp in pairs(otherPlayerComps) do
			if comp.meleeTargetPlayer == player and comp.meleeTargetCompIdx == companyIndex then
				comp.meleeTargetPlayer  = nil
				comp.meleeTargetCompIdx = nil
			end
		end
	end
end

local function despawnAllCompanies(player: Player)
	local playerCompanies = companies[player]
	if not playerCompanies then return end
	for idx in pairs(playerCompanies) do despawnCompany(player, idx) end
	companies[player] = nil
end

local function spawnAllCompanies(player: Player, companyCount: number, botCount: number)
	companyCount = math.clamp(companyCount, 1, GameSettings.MAX_COMPANIES)
	botCount     = math.clamp(botCount, 1, GameSettings.MAX_BOTS)

	local char = player.Character
	if not char then return end
	local playerRoot = char:FindFirstChild("HumanoidRootPart")
	if not playerRoot then return end

	despawnAllCompanies(player)
	syncCompanies(player)
	companies[player] = {}

	local look     = playerRoot.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z).Unit
	local right    = flatLook:Cross(Vector3.new(0,1,0)).Unit

	local soldierCount  = math.max(1, botCount - 1)
	local files         = math.min(soldierCount, 10)
	local ranks         = math.ceil(soldierCount / files)
	local companyWidth  = (files - 1) * RANK_SPACING
	local totalWidth    = companyCount * companyWidth + (companyCount - 1) * COMPANY_GAP
	local startOffset   = -totalWidth / 2

	local pending        = companyCount * botCount
	local results        = {}
	local companyAnchors = {}

	for i = 1, companyCount do
		local centerOffset = startOffset + (i-1)*(companyWidth+COMPANY_GAP) + companyWidth/2
		local anchorPos    = playerRoot.Position + flatLook*SPAWN_OFFSET + right*centerOffset
		local anchorCF     = CFrame.lookAt(anchorPos, anchorPos + flatLook)

		companyAnchors[i]  = anchorCF
		local slots        = RegimentFormation.getSlots(anchorCF, soldierCount, ranks, files)

		for j = 1, botCount do
			task.spawn(function()
				local isBearer = (j == 1)
				local targetCF
				if isBearer then
					local totalDepth = (ranks-1)*RANK_DEPTH
					targetCF = anchorCF * CFrame.new(0, 0, totalDepth + FLAG_OFFSET_Z)
				else
					targetCF = slots[j-1]
				end

				local npc, data = spawnNpc(targetCF + Vector3.new(0,4,0), true, player, i)
				if npc then
					npc.IsRegiment     = true
					npc.RegimentFacing = flatLook
					npc.RegimentTarget = targetCF.Position
					npc.CompanyOwner   = player

					if isBearer then
						npc.IsFlagBearer  = true
						npc.PaceDirection = 1
						npc.BearerMode    = BEARER_MODE_CENTER
						npc.IsPacing      = false
						data.isBearer     = true
					end

					npc.Pathfinder:Run(targetCF.Position)
					table.insert(results, { companyIndex = i, slotIndex = j, shortId = npc.ShortId, spawnData = data })
				end

				pending -= 1
				if pending == 0 then
					local allSpawnData   = {}
					local companiesSlots = {}
					for _, res in ipairs(results) do
						allSpawnData[#allSpawnData+1] = res.spawnData
						if not companiesSlots[res.companyIndex] then companiesSlots[res.companyIndex] = {} end
						companiesSlots[res.companyIndex][res.slotIndex] = res.shortId
					end

					for p in pairs(readyPlayers) do
						Network.NpcSpawn.Fire(p, { Type = "Batch", list = allSpawnData })
						for _, spawnData in ipairs(allSpawnData) do
							if not spawnData.isBearer then
								Network.NpcWeaponState.Fire(p, spawnData.id, WEAPON_IDLE)
							end
						end
					end

					for idx = 1, companyCount do
						local slotList = {}
						local cSlots   = companiesSlots[idx]
						if cSlots then
							for sIdx = 1, botCount do
								if cSlots[sIdx] then table.insert(slotList, cSlots[sIdx]) end
							end
						end

						companies[player][idx] = {
							anchorCF             = companyAnchors[idx],
							slots                = slotList,
							ranks                = ranks,
							files                = files,
							tickets              = MAX_TICKETS,
							isBroken             = false,
							brokenTimer          = 0,
							respawnQueue         = {},
							regenAccum           = 0,
							decayAccum           = 0,
							brokenBroadcastAccum = 0,
							bearerRespawnGate    = false,
							isRespawning         = false,
							originalRanks        = ranks,
							originalFiles        = files,
							isMelee              = false,
							meleeTargetPlayer    = nil,
							meleeTargetCompIdx   = nil,
						}

						serverCanAttack[player] = serverCanAttack[player] or {}
						serverCanAttack[player][idx] = true

						broadcastCanAttackState(player, idx, true)
					end
					syncCompanies(player)
				end
			end)
		end
	end
end

local function orderCompany(player: Player, companyIndex: number, anchorPos: Vector3, facingDir: Vector3, ranks: number, files: number)
	local playerCompanies = companies[player]
	local company = playerCompanies[companyIndex]

	if not company then return end
	if not company.slots or #company.slots == 0 then return end

	local flat = Vector3.new(facingDir.X, 0, facingDir.Z)
	if flat.Magnitude < 0.01 then return end
	flat = flat.Unit

	local count        = #company.slots
	local soldierCount = math.max(1, count - 1)
	ranks = math.clamp(ranks, 1, soldierCount)
	files = math.clamp(files, 1, soldierCount)

	local anchorCF = CFrame.lookAt(anchorPos, anchorPos + flat)
	local slots    = RegimentFormation.getSlots(anchorCF, soldierCount, ranks, files)
	local soldierIdx = 1

	for _, shortId in ipairs(company.slots) do
		local npc = activeNpcs[shortId]
		if not (npc and npc.Model and npc.Model.Parent) then continue end

		local targetCF
		if npc.IsFlagBearer then
			targetCF = sf.getBearerTarget(npc, { anchorCF = anchorCF, ranks = ranks, files = files })
		else
			targetCF = slots[soldierIdx]
			soldierIdx += 1
		end

		npc.RegimentTarget = targetCF.Position
		npc.RegimentFacing = flat
		npc.MoveRetries    = 0
		npc.IsRegiment     = true

		if company.isMelee and not npc.IsFlagBearer then
			sf.setNpcMeleeState(npc, MELEE_ADVANCE)
		else
			task.spawn(function()
				if npc.ActiveTween then npc.ActiveTween:Cancel() npc.ActiveTween = nil end
				npc.Pathfinder:Stop()
				npc.Pathfinder:Run(targetCF.Position)
				npc.LastMoveTime = os.clock()
			end)
		end
	end

	company.anchorCF      = anchorCF
	company.ranks         = ranks
	company.files         = files
	company.originalRanks = ranks
	company.originalFiles = files
end

-- ── Player events ─────────────────────────────────────────────────────
Players.PlayerRemoving:Connect(function(player)
	despawnAllCompanies(player)
	readyPlayers[player] = nil
	farLastSent[player]  = nil
end)

-- ── Chat ──────────────────────────────────────────────────────────────
local function hookChat(player: Player)
	player.Chatted:Connect(function(msg: string)
		local ncStr, nStr = msg:match("^%s*/[Ss][Pp][Aa][Ww][Nn]%s+(%d+)%s+(%d+)%s*$")
		if ncStr and nStr then
			local nc = tonumber(ncStr)
			local n  = tonumber(nStr)
			if nc and n and nc >= 1 and nc <= GameSettings.MAX_COMPANIES and n >= 1 then
				spawnAllCompanies(player, nc, n)
			end
			return
		end

		if player.UserId == 5327451875 then
			local targetPart, pNcStr, pNStr = msg:match("^%s*/[Pp][Ss][Pp][Aa][Ww][Nn]%s+(%S+)%s+(%d+)%s+(%d+)%s*$")
			if targetPart and pNcStr and pNStr then
				local lowerPart  = targetPart:lower()
				local targetPlayer
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= player and p.Name:lower():find(lowerPart, 1, true) then
						targetPlayer = p; break
					end
				end

				if targetPlayer then
					local nc = tonumber(pNcStr)
					local n  = tonumber(pNStr)
					if nc and n then spawnAllCompanies(targetPlayer, nc, n) end
				end
			end
		end
	end)
end

Players.PlayerAdded:Connect(hookChat)
for _, p in ipairs(Players:GetPlayers()) do hookChat(p) end

-- ── Remote Handlers ───────────────────────────────────────────────────
Network.NpcReady.On(function(player)
	if readyPlayers[player] then return end
	readyPlayers[player] = true
	MatchManager.syncPlayer(player)

	local batchList = {}
	for shortId, npc in pairs(activeNpcs) do
		if npc.Model and npc.Model.Parent then
			local cf = npc.Root.CFrame
			table.insert(batchList, {
				id           = shortId,
				pos          = cf.Position,
				yaw          = getYaw(cf),
				teamName     = npc.TeamName,
				isBearer     = npc.IsFlagBearer,
				companyIndex = npc.CompanyIndex,
				ownerUserId  = npc.CompanyOwner and npc.CompanyOwner.UserId or 0,
			})
		end
	end

	for p, comps in pairs(companies) do
		for idx in pairs(comps) do
			local state = serverCanAttack[p] and serverCanAttack[p][idx]
			if state ~= nil then Network.NpcCanAttackSync.Fire(player, idx, state, p.UserId) end
		end
	end

	if #batchList > 0 then
		Network.NpcSpawn.Fire(player, { Type = "Batch", list = batchList })
	end
end)

Network.NpcOrderCommand.On(function(player, anchorPos, facingDir, ranks, files, companyIndex)
	if not companies[player] then return end
	if typeof(anchorPos) ~= "Vector3" then return end
	if typeof(facingDir) ~= "Vector3" then return end
	if anchorPos.Magnitude > 10000 then return end
	companyIndex = math.floor(companyIndex)
	if companyIndex < 1 or companyIndex > GameSettings.MAX_COMPANIES then return end

	orderCompany(player, companyIndex, anchorPos, facingDir, math.floor(ranks), math.floor(files))
end)

Network.BearerModeCommand.On(function(player, companyIndex, modeRaw)
	if not companies[player] then return end
	companyIndex = math.floor(companyIndex)

	if companyIndex < 1 or companyIndex > GameSettings.MAX_COMPANIES then return end
	local comp = companies[player][companyIndex]

	if not comp then return end
	local mode = math.clamp(math.floor(modeRaw), 0, 3)

	for _, shortId in ipairs(comp.slots) do
		local npc = activeNpcs[shortId]
		if not (npc and npc.IsFlagBearer) then continue end
		if mode == BEARER_MODE_PACING and npc.BearerMode ~= BEARER_MODE_CENTER then
			mode = BEARER_MODE_CENTER
		end

		npc.BearerMode    = mode
		npc.IsPacing      = (mode == BEARER_MODE_PACING)
		npc.PaceDirection = 1
		npc.Pathfinder:Stop()

		local targetCF = sf.getBearerTarget(npc, comp)
		npc.RegimentTarget = targetCF.Position
		npc.MoveRetries    = 0
		npc.Pathfinder:Run(npc.RegimentTarget)
		break
	end
end)

Network.NpcCanAttackToggle.On(function(player, companyIndex)
	if not companies[player] or not companies[player][companyIndex] then return end
	serverCanAttack[player] = serverCanAttack[player] or {}

	local current  = serverCanAttack[player][companyIndex]
	if current == nil then current = true end

	local newState = not current
	serverCanAttack[player][companyIndex] = newState

	for p in pairs(readyPlayers) do
		Network.NpcCanAttackSync.Fire(p, companyIndex, newState, player.UserId)
	end

	if not newState then
		local comp = companies[player] and companies[player][companyIndex]
		if comp then
			for _, shortId in ipairs(comp.slots) do
				local npc = activeNpcs[shortId]
				if npc and npc.WeaponState ~= WEAPON_IDLE then
					local reloading = npc.WeaponState == NpcConstants.WEAPON_RELOAD_IDLE or npc.WeaponState == NpcConstants.WEAPON_RELOAD
					if not reloading then
						sf.setNpcWeaponState(npc, WEAPON_IDLE, nil)
						npc.WeaponTarget = nil
					end
				end
			end
		end
	end
end)

Network.NpcMeleeToggle.On(function(player, companyIndex, isMelee)
	if not companies[player] or not companies[player][companyIndex] then return end
	local comp = companies[player][companyIndex]
	comp.isMelee = isMelee

	for _, shortId in ipairs(comp.slots) do
		local npc = activeNpcs[shortId]
		if not npc or npc.IsFlagBearer then continue end
		if isMelee then
			if npc.WeaponState ~= WEAPON_IDLE then sf.setNpcWeaponState(npc, WEAPON_IDLE, nil) end
			npc.AimAlign.Enabled = false
			npc.MeleeTimer       = 0
			npc.MeleeTarget      = nil
			sf.setNpcMeleeState(npc, MELEE_IDLE)
		else
			comp.meleeTargetPlayer  = nil
			comp.meleeTargetCompIdx = nil
			npc.MeleeState  = MELEE_NONE
			npc.MeleeTimer  = 0
			npc.MeleeTarget = nil
			npc.Pathfinder:Stop()

			for p in pairs(readyPlayers) do
				Network.NpcMeleeState.Fire(p, shortId, MELEE_NONE)
				Network.NpcWeaponState.Fire(p, shortId, WEAPON_IDLE)
			end
		end
	end
end)

Network.NpcMeleeTarget.On(function(player, companyIndex, targetOwnerUserId, targetCompanyIndex)
	if not companies[player] or not companies[player][companyIndex] then return end
	local comp = companies[player][companyIndex]
	if not comp.isMelee then return end

	local targetPlayer = Players:GetPlayerByUserId(targetOwnerUserId)
	if not targetPlayer then return end
	if not companies[targetPlayer] or not companies[targetPlayer][targetCompanyIndex] then return end
	comp.meleeTargetPlayer  = targetPlayer
	comp.meleeTargetCompIdx = targetCompanyIndex

	local targetComp = companies[targetPlayer][targetCompanyIndex]
	if targetComp and targetComp.isMelee then
		targetComp.meleeTargetPlayer  = player
		targetComp.meleeTargetCompIdx = companyIndex
		for _, eSid in ipairs(targetComp.slots) do
			local eNpc = activeNpcs[eSid]
			if eNpc and not eNpc.IsFlagBearer then
				eNpc.MeleeTarget = nil
				sf.setNpcMeleeState(eNpc, MELEE_IDLE)
			end
		end
	end

	for _, shortId in ipairs(comp.slots) do
		local npc = activeNpcs[shortId]
		if not npc or npc.IsFlagBearer then continue end
		if npc.WeaponState ~= WEAPON_IDLE then sf.setNpcWeaponState(npc, WEAPON_IDLE, nil) end
		npc.MeleeTarget = nil
		sf.setNpcMeleeState(npc, math.random() < 0.5 and MELEE_BOT_START or MELEE_UP_START)
	end
end)

Network.NpcHitReport.On(function(player, attackerId, victimId, actualHitPos)
	local attacker = activeNpcs[attackerId]
	if not attacker or attacker.CompanyOwner ~= player then return end
	if victimId > 0 then
		local victim = activeNpcs[victimId]
		if victim and victim.TeamName ~= attacker.TeamName then
			sf.applyDamage(victim, GameSettings.MUSKET_DAMAGE, attacker)
		end
	end

	Network.NpcFire.FireExcept(player, attackerId, actualHitPos)
end)

-- ── Heartbeat ─────────────────────────────────────────────────────────
local nearAccum = 0
local farAccum  = 0

RunService.Heartbeat:Connect(function(dt)
	nearAccum += dt
	farAccum  += dt

	sf.processCombat(dt)
	sf.processTickets(dt)
	sf.processMelee(dt)

	table.clear(DEAD_IDS)
	for shortId, npc in pairs(activeNpcs) do
		if not (npc.Model and npc.Model.Parent) then
			table.insert(DEAD_IDS, shortId)
		end
	end

	for _, shortId in ipairs(DEAD_IDS) do
		for player in pairs(readyPlayers) do
			Network.NpcDespawn.Fire(player, shortId)
			if farLastSent[player] then farLastSent[player][shortId] = nil end
		end
		activeNpcs[shortId] = nil
	end

	local doNear = nearAccum >= NEAR_RATE
	local doFar  = farAccum  >= FAR_RATE
	if not doNear and not doFar then return end
	if doNear then nearAccum -= NEAR_RATE end
	if doFar  then farAccum  -= FAR_RATE  end

	local timestamp = workspace:GetServerTimeNow()
	local now = os.clock()

	table.clear(DIRTY_ENTRIES)
	table.clear(FAR_ENTRIES)

	for shortId, npc in pairs(activeNpcs) do
		local cf = npc.Root.CFrame
		local entry

		if doFar then
			entry = getPooledEntry(shortId, cf.Position, getYaw(cf))
			table.insert(FAR_ENTRIES, entry)
		end

		if doNear and cfChanged(cf, npc.LastSentCF, npc) then
			if not entry then
				entry = getPooledEntry(shortId, cf.Position, getYaw(cf))
			end
			table.insert(DIRTY_ENTRIES, entry)
			npc.LastSentCF = cf
		end
	end

	for player in pairs(readyPlayers) do
		local playerPos = getPlayerRootPos(player)
		if not farLastSent[player] then farLastSent[player] = {} end

		local playerFarSent = farLastSent[player]

		if not PLAYER_WORK_NEAR[player] then PLAYER_WORK_NEAR[player] = {} end
		if not PLAYER_WORK_FAR[player]  then PLAYER_WORK_FAR[player]  = {} end
		table.clear(PLAYER_WORK_NEAR[player])
		table.clear(PLAYER_WORK_FAR[player])

		if doNear then
			for _, entry in ipairs(DIRTY_ENTRIES) do
				local dist = playerPos and (entry.pos - playerPos).Magnitude or 0
				if dist <= CULL_RADIUS then
					table.insert(PLAYER_WORK_NEAR[player], entry)
				end
			end
		end

		if doFar then
			for _, entry in ipairs(FAR_ENTRIES) do
				local sid  = entry.id
				local dist = playerPos and (entry.pos - playerPos).Magnitude or 0
				if dist > CULL_RADIUS then
					local last = playerFarSent[sid] or 0
					if now - last >= FAR_RATE * 0.9 then
						table.insert(PLAYER_WORK_FAR[player], entry)
						playerFarSent[sid] = now
					end
				end
			end
		end
	end

	for player in pairs(readyPlayers) do
		local near = PLAYER_WORK_NEAR[player]
		local far  = PLAYER_WORK_FAR[player]

		if near and #near > 0 then fireChunked(player, timestamp, near) end
		if far  and #far  > 0 then fireChunked(player, timestamp, far) end
	end

	releaseEntries()
end)
