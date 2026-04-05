-->>>>>>>>>>>>
-- NPC_SYSTEM_SERVER
-- Version 3.1.0
--
-- Configuration:
--   - MAX_BOTS: 31 NPCs per game
--   - MAX_COMPANIES: 2 (can be 4, currently limited to 2)
--   - RANK_SPACING: 4.7 studs (side-to-side)
--   - RANK_DEPTH: 5 studs (front-to-back)
--   - COMBAT_RANGE: 750 studs (musket attack range)
--
-- Update Rates:
--   - Near Rate (NEAR_RATE = 1/20): High frequency snapshots for players < 500 studs
--   - Far Rate (FAR_RATE = 1/4): Low frequency updates for distant players
--   - Chunking: Large batches split into 35-unit chunks to avoid network floods
-->>>>>>>>>>>>

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService    = game:GetService("PhysicsService")
local TweenService      = game:GetService("TweenService")

local Network           = require(game.ReplicatedStorage.Blink.Server)
local RegimentFormation = require(ReplicatedStorage.Modules.Shared:WaitForChild("RegimentFormation"))
local NoobPath          = require(ReplicatedStorage.Modules.Packages:WaitForChild("NoobPath"))

local SERVER_MODEL  = ReplicatedStorage:WaitForChild("SERVER")
local ROTATION_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

-- ── Config ────────────────────────────────────────────────────────────
local WALK_SPEED    = 15
local CHUNK_SIZE    = 35
local NEAR_RATE     = 1 / 20
local FAR_RATE      = 1 / 4
local CULL_RADIUS   = 500       
local DELTA_POS     = 0.08
local DELTA_ROT     = 0.01
local MAX_BOTS      = 31        
local MAX_COMPANIES = 4 --4
local SPAWN_OFFSET  = 16         
local COMPANY_GAP   = 15         
local RANK_SPACING  = 4.7 --5       
local RANK_DEPTH    = 5
local FLAG_OFFSET_Z = 8       
local MOVE_RETRIES  = 2 

local MAX_TICKETS            = 150
local TICKET_REGEN_RATE      = 4
local TICKET_REGEN_INTERVAL  = 4.5
local TICKET_DECAY_RATE      = 6
local TICKET_DECAY_INTERVAL  = 5
local TICKET_COST_STATIONARY = 2
local TICKET_COST_MOVING     = 4
local BROKEN_RECOVERY_TIME   = 20
local BEARER_NEARBY_RADIUS   = 65
local BEARER_REPLACE_DELAY   = 3

local COMBAT_RANGE    = 500    -- studs

local WEAPON_IDLE          = 0
local WEAPON_MAKE_READY    = 1
local WEAPON_MAKEREADY_IDLE = 2
local WEAPON_TO_AIM        = 3
local WEAPON_AIM_IDLE      = 4
local WEAPON_FIRE          = 5
local WEAPON_RELOAD_IDLE   = 6
local WEAPON_RELOAD        = 7

local MUSKET_DAMAGE = 100

local WEAPON_DURATIONS = {
	[0] = 0,
	[1] = 1.8,
	[2] = 1.0,
	[3] = 0.7,
	[4] = 1.0,
	[5] = 0.75,
	[6] = 1.0,
	[7] = 10.33,
}

local BEARER_MODE_CENTER    = 0   -- j : static, behind centre
local BEARER_MODE_LEFT      = 1   -- h : front-left corner
local BEARER_MODE_RIGHT     = 2   -- k : front-right corner
local BEARER_MODE_PACING    = 3   -- l : left↔right behind last rank

local BEARER_SIDE_OFFSET_X = 5   -- studs outward beyond the corner soldier
local BEARER_SIDE_OFFSET_Z = 0   -- studs back so it's beside rank 1, not in front

local NPC_COLLISION_GROUP = "NpcGroup"
local CLIENT_NPC_GROUP = "ClientNpcGroup"

if not PhysicsService:IsCollisionGroupRegistered(NPC_COLLISION_GROUP) then
	PhysicsService:RegisterCollisionGroup(NPC_COLLISION_GROUP)
end
if not PhysicsService:IsCollisionGroupRegistered(CLIENT_NPC_GROUP) then
	PhysicsService:RegisterCollisionGroup(CLIENT_NPC_GROUP)
end

PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, NPC_COLLISION_GROUP, false)
PhysicsService:CollisionGroupSetCollidable(CLIENT_NPC_GROUP, CLIENT_NPC_GROUP, false)
PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, CLIENT_NPC_GROUP, false)

local WANDER_CENTER = Vector3.new(0, 0, 0)
local WANDER_RADIUS = 60
local WANDER_MIN    = 8
local IDLE_TIMEOUT  = 3

-- ── State ─────────────────────────────────────────────────────────────
-- Central runtime state for NPC system

local activeNpcs   = {}   -- [shortId] = npc object {Model, Humanoid, Root, etc.}
local nextShortId  = 1    -- Counter for unique NPC IDs
local readyPlayers = {}   -- [player] = true (clients that are loaded and ready)
local farLastSent  = {}   -- [player][shortId] = last CFrame sent at far rate
local companies = {}      -- [player][companyIndex] = company object (ranks, files, slots, bearers)
local serverCanAttack = {}   -- [player][companyIndex] = boolean (server-tracked combat state)

-- ── Helpers ───────────────────────────────────────────────────────────
local function randomPoint(center, radius, minDist)
	local angle = math.random() * math.pi * 2
	local dist  = minDist + math.random() * (radius - minDist)
	return Vector3.new(center.X + math.cos(angle) * dist, center.Y, center.Z + math.sin(angle) * dist)
end

local function getYaw(cf)
	local _, y, _ = cf:ToEulerAnglesYXZ()
	return y
end

local function cfChanged(cf, lastCF, npc)
	local threshold = (npc.IsRegiment and npc.RegimentTarget
		and (cf.Position - npc.RegimentTarget).Magnitude < 3)
		and 1.5  
		or DELTA_POS

	if (cf.Position - lastCF.Position).Magnitude > threshold then return true end
	if math.abs(getYaw(cf) - getYaw(lastCF)) > DELTA_ROT then return true end
	return false
end

local function getPlayerRootPos(player)
	local char = player.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function makeBatchEntry(shortId, cf)
	return 
		{ 
		id = shortId,
		pos = cf.Position,
		yaw = getYaw(cf),
		}
end

local function fireChunked(player, timestamp, entries)
	for i = 1, #entries, CHUNK_SIZE do
		local chunk = {}
		for j = i, math.min(i + CHUNK_SIZE - 1, #entries) do
			local e = entries[j]
			chunk[#chunk + 1] = { id = e.id, pos = e.pos, yaw = e.yaw }
		end
		Network.NpcBatch.Fire(player, timestamp, chunk)
	end
end

local function pickNewTarget(npc)
	npc.Target       = randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN)
	npc.LastMoveTime = os.clock()
	npc.Pathfinder:Run(npc.Target)
end

local function getBearerTarget(npc, comp)
	local anchorCF   = comp.anchorCF
	local halfWidth  = ((comp.files - 1) * RANK_SPACING) / 2
	local totalDepth = (comp.ranks - 1) * RANK_DEPTH
	local dynamicZ   = totalDepth + FLAG_OFFSET_Z

	local mode = npc.BearerMode

	if mode == BEARER_MODE_LEFT then
		-- front-left corner of the formation (negative X = left)
		return anchorCF * CFrame.new(-(halfWidth + BEARER_SIDE_OFFSET_X), 0, BEARER_SIDE_OFFSET_Z)

	elseif mode == BEARER_MODE_RIGHT then
		-- front-right corner of the formation
		return anchorCF * CFrame.new(halfWidth + BEARER_SIDE_OFFSET_X, 0, BEARER_SIDE_OFFSET_Z)

	elseif mode == BEARER_MODE_PACING then
		-- pacing: go to whichever side PaceDirection points to
		return anchorCF * CFrame.new(halfWidth * npc.PaceDirection, 0, dynamicZ)

	else
		-- BEARER_MODE_CENTER (j) : static centre behind last rank
		return anchorCF * CFrame.new(0, 0, dynamicZ)
	end
end

local function findNearestEnemy(npc)
	local myTeam = npc.TeamName
	if not myTeam then return nil end
	local myPos = npc.Root.Position

	-- Find all enemies within COMBAT_RANGE
	local enemiesInRange = {}
	for _, other in pairs(activeNpcs) do
		if other ~= npc then
			local otherTeam = other.TeamName
			if otherTeam and otherTeam ~= myTeam then
				local otherPos = other.Root and other.Root.Position
				if otherPos then
					local dist = (otherPos - myPos).Magnitude
					if dist <= COMBAT_RANGE then
						enemiesInRange[#enemiesInRange + 1] = other
					end
				end
			end
		end
	end

	-- Return random enemy from those in range (prevents all focusing on distant target)
	if #enemiesInRange > 0 then
		return enemiesInRange[math.random(1, #enemiesInRange)]
	end
	return nil
end

-- ── NPC Spawn ─────────────────────────────────────────────────────────
local function spawnNpc(spawnCF: CFrame?, suppressNotify: boolean?, ownerPlayer: Player?)
	local shortId   = nextShortId
	nextShortId     = nextShortId + 1

	local model    = SERVER_MODEL:Clone()
	model.Name     = "NPC_" .. shortId

	local root     = model.HumanoidRootPart
	local humanoid = model.Humanoid
	humanoid.AutoRotate = true 
	humanoid.WalkSpeed = WALK_SPEED

	local cf = spawnCF or CFrame.new(
		randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN) + Vector3.new(0, 4, 0)
	)

	root.CFrame  = cf
	model.Parent = workspace.Npc_Registry_Server
	
	-- Set team name attribute for client-side team logic (store as string, not Instance)
	local teamName = nil
	if ownerPlayer then
		if ownerPlayer.Team then
			teamName = ownerPlayer.Team.Name
		else
			teamName = "Player_" .. ownerPlayer.UserId   -- fallback unique string
		end
		model:SetAttribute("TeamName", teamName)
		if ownerPlayer.Team then
			model:SetAttribute("TeamColor", ownerPlayer.Team.TeamColor)
		end
	end

	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 1 
			part.CanTouch = false 
			part.CanQuery = false 
			part.CollisionGroup = NPC_COLLISION_GROUP
			part:SetNetworkOwner(nil)
		end
	end

	local pathfinder = NoobPath.Humanoid(model, {
		WaypointSpacing = 6,
		AgentRadius = 1.5, 
		AgentHeight = 5,
	})

	local npc = {
		ShortId        = shortId,
		Model          = model,
		Root           = root,
		Humanoid       = humanoid,
		Pathfinder     = pathfinder,
		LastMoveTime   = 0,
		LastSentCF     = cf,
		IsRegiment     = spawnCF ~= nil,
		RegimentTarget = nil,
		MoveRetries    = 0,
		ActiveTween    = nil,
		
		Health       = 100,
		
		AimAttachment = root:WaitForChild("RootAttachment"),
		AimAlign      = root:WaitForChild("AlignOrientation"),

		-- [FLAG BEARER LOGIC] Track bearer properties
		IsFlagBearer   = false,
		PaceDirection  = 1,
		CompanyOwner   = nil,
		CompanyIndex   = nil,
		Team           = ownerPlayer and ownerPlayer.Team or nil,
		TeamName       = teamName,
		
		-- weapon
		WeaponState  = WEAPON_IDLE,
		WeaponTimer  = 0,
		WeaponTarget = nil,
	}

	pathfinder.Reached:Connect(function()
		if not npc.IsRegiment then
			pickNewTarget(npc)

			-- [FLAG BEARER LOGIC] Pacing trigger
			elseif npc.IsFlagBearer and npc.IsPacing then
				npc.MoveRetries = 0
				npc.PaceDirection = -(npc.PaceDirection or 1)
				local pComps = companies[npc.CompanyOwner]
				if pComps and pComps[npc.CompanyIndex] then
					local comp     = pComps[npc.CompanyIndex]
					local targetCF = getBearerTarget(npc, comp)
					npc.RegimentTarget = targetCF.Position
					npc.Pathfinder:Run(npc.RegimentTarget)
				end
			elseif npc.IsRegiment then
				npc.MoveRetries = 0
				if npc.RegimentFacing then
					if npc.ActiveTween then npc.ActiveTween:Cancel() end
					local pos = npc.Root.Position
					local targetCF = CFrame.lookAt(pos, pos + npc.RegimentFacing)
					npc.ActiveTween = TweenService:Create(npc.Root, ROTATION_TWEEN_INFO, { CFrame = targetCF })
					npc.ActiveTween:Play()
				end
			end
	end)

	pathfinder.Trapped:Connect(function()
		if not npc.IsRegiment then
			pickNewTarget(npc)
			return
		end

		npc.MoveRetries += 1
		if npc.MoveRetries <= MOVE_RETRIES and npc.RegimentTarget then
			task.delay(0.5 + math.random() * 0.5, function()  
				if npc.Model and npc.Model.Parent then
					npc.Pathfinder:Run(npc.RegimentTarget)
					npc.LastMoveTime = os.clock()
				end
			end)
		end
	end)

	if not spawnCF then pickNewTarget(npc) end

	activeNpcs[shortId] = npc

	if not suppressNotify then
		for player in pairs(readyPlayers) do
			local ownerUserId = ownerPlayer and ownerPlayer.UserId or nil
			Network.NpcSpawn.Fire(player, {
				Type        = "Single",
				id          = shortId,
				pos         = cf.Position,
				yaw         = getYaw(cf),
				teamName    = teamName,
				isBearer    = npc.IsFlagBearer,
				companyIndex = npc.CompanyIndex,
				ownerUserId = ownerPlayer and ownerPlayer.UserId or 0,  -- 0 not nil
			})
			
			Network.NpcWeaponState.Fire(player, shortId, WEAPON_IDLE)
		end
	end

	return npc, {
		id           = shortId,
		pos          = cf.Position,
		yaw          = getYaw(cf),
		teamName     = teamName,
		isBearer     = npc.IsFlagBearer,
		companyIndex = npc.CompanyIndex,
		ownerUserId  = ownerPlayer and ownerPlayer.UserId or 0,  -- 0 not nil
	}
end

-- ── Company Management ────────────────────────────────────────────────
local function syncCompanies(player: Player)
	local playerCompanies = companies[player]
	local data = {}

	if playerCompanies then
		for idx, company in pairs(playerCompanies) do
			table.insert(data, {
				index = idx,
				count = #company.slots,
				slots = company.slots,
			})
		end
		table.sort(data, function(a, b) return a.index < b.index end)
	end
	Network.NpcCompanySync.Fire(player, data)
end

local function isEnemyBearerNearby(player, companyIndex)
	local comp = companies[player] and companies[player][companyIndex]
	if not comp then return false end

	local ourBearerPos = nil
	for _, sid in ipairs(comp.slots) do
		local npc = activeNpcs[sid]
		if npc and npc.IsFlagBearer then
			ourBearerPos = npc.Root.Position
			break
		end
	end
	if not ourBearerPos then return false end

	for otherPlayer, otherComps in pairs(companies) do
		if otherPlayer == player then continue end
		if otherPlayer.Team and player.Team and otherPlayer.Team == player.Team then continue end
		for _, otherComp in pairs(otherComps) do
			for _, sid in ipairs(otherComp.slots) do
				local npc = activeNpcs[sid]
				if npc and npc.IsFlagBearer and npc.Root then
					if (npc.Root.Position - ourBearerPos).Magnitude <= BEARER_NEARBY_RADIUS then
						return true
					end
				end
			end
		end
	end
	return false
end

local function broadcastStrength(player, companyIndex)
	local comp = companies[player] and companies[player][companyIndex]
	if not comp then return end
	local enemyNear = isEnemyBearerNearby(player, companyIndex)
	for p in pairs(readyPlayers) do
		Network.NpcCompanyStrength.Fire(
			p,
			companyIndex,
			comp.tickets,
			comp.isBroken,
			player.UserId,
			comp.brokenTimer,
			enemyNear
		)
	end
end


local function replaceBearer(player, companyIndex, deadBearerPos)
	local comp = companies[player] and companies[player][companyIndex]
	if not comp then return end

	comp.bearerRespawnGate = true

	local candidates = {}
	for _, sid in ipairs(comp.slots) do
		local npc = activeNpcs[sid]
		if npc and not npc.IsFlagBearer then
			candidates[#candidates + 1] = sid
		end
	end

	if #candidates == 0 then
		task.delay(BEARER_REPLACE_DELAY, function()
			if companies[player] and companies[player][companyIndex] then
				comp.bearerRespawnGate = false
			end
		end)
		return
	end

	local chosenId  = candidates[math.random(1, #candidates)]
	local chosenNpc = activeNpcs[chosenId]
	if not chosenNpc then
		task.delay(BEARER_REPLACE_DELAY, function()
			if companies[player] and companies[player][companyIndex] then
				comp.bearerRespawnGate = false
			end
		end)
		return
	end

	-- Promote to bearer
	chosenNpc.IsFlagBearer   = true
	-- Use saved bearer mode from dead bearer (or default to CENTER)
	chosenNpc.BearerMode     = comp.savedBearerMode or BEARER_MODE_CENTER
	chosenNpc.IsPacing       = comp.savedBearerPacing or false
	chosenNpc.PaceDirection  = 1
	chosenNpc.WeaponState    = WEAPON_IDLE
	chosenNpc.WeaponTimer    = 0
	chosenNpc.WeaponTarget   = nil
	chosenNpc.AimAlign.Enabled = false

	for p in pairs(readyPlayers) do
		Network.NpcWeaponState.Fire(p, chosenId, WEAPON_IDLE)
		Network.NpcBecomeBearer.Fire(p, chosenId)
	end

	-- Path to old bearer position immediately
	chosenNpc.RegimentTarget = deadBearerPos
	chosenNpc.MoveRetries    = 0
	task.spawn(function()
		if chosenNpc.ActiveTween then chosenNpc.ActiveTween:Cancel() chosenNpc.ActiveTween = nil end
		chosenNpc.Pathfinder:Stop()
		chosenNpc.Pathfinder:Run(deadBearerPos)
	end)

	-- Remaining soldiers fill formation gap
	local soldierIds = {}
	for _, sid in ipairs(comp.slots) do
		local s = activeNpcs[sid]
		if s and not s.IsFlagBearer then
			soldierIds[#soldierIds + 1] = sid
		end
	end

	local soldierCount = #soldierIds
	if soldierCount > 0 and comp.anchorCF then
		local files = math.min(soldierCount, comp.files)
		local ranks = math.ceil(soldierCount / files)
		comp.ranks = ranks
		comp.files = files
		local slots = RegimentFormation.getSlots(comp.anchorCF, soldierCount, ranks, files)
		for i, sid in ipairs(soldierIds) do
			local s = activeNpcs[sid]
			if not s then continue end
			s.RegimentTarget = slots[i].Position
			s.MoveRetries    = 0
			task.spawn(function()
				if s.ActiveTween then s.ActiveTween:Cancel() s.ActiveTween = nil end
				s.Pathfinder:Stop()
				s.Pathfinder:Run(slots[i].Position)
			end)
		end
	end

	task.delay(BEARER_REPLACE_DELAY, function()
		if companies[player] and companies[player][companyIndex] then
			comp.bearerRespawnGate = false
		end
	end)
end


local function killNpc(shortId)
	local npc = activeNpcs[shortId]
	if not npc then return end

	local wasBearer  = npc.IsFlagBearer
	local deadPos    = npc.Root.Position
	local wasWalking = npc.Humanoid and npc.Humanoid.MoveDirection.Magnitude > 0.05
	local owner      = npc.CompanyOwner
	local compIdx    = npc.CompanyIndex

	for p in pairs(readyPlayers) do
		Network.NpcDespawn.Fire(p, shortId)
		if farLastSent[p] then farLastSent[p][shortId] = nil end
	end

	if npc.Pathfinder then npc.Pathfinder:Destroy() end
	if npc.Model then npc.Model:Destroy() end
	activeNpcs[shortId] = nil

	if not owner or not compIdx then return end
	local comp = companies[owner] and companies[owner][compIdx]
	if not comp then return end

	for i = #comp.slots, 1, -1 do
		if comp.slots[i] == shortId then
			table.remove(comp.slots, i)
			break
		end
	end

	if wasBearer then
		-- Save dead bearer's mode so new bearer continues in same mode
		local deadNpc = activeNpcs[shortId]
		if deadNpc then
			comp.savedBearerMode = deadNpc.BearerMode or BEARER_MODE_CENTER
			comp.savedBearerPacing = deadNpc.IsPacing or false
		else
			comp.savedBearerMode = BEARER_MODE_CENTER
			comp.savedBearerPacing = false
		end
		
		replaceBearer(owner, compIdx, deadPos)
		syncCompanies(owner)
		return
	end

	-- Ticket deduction
	local cost = wasWalking and TICKET_COST_MOVING or TICKET_COST_STATIONARY

	if not comp.isBroken then
		comp.tickets = math.max(0, comp.tickets - cost)

		if comp.tickets <= 0 then
			comp.isBroken         = true
			comp.brokenTimer      = BROKEN_RECOVERY_TIME
			comp.brokenBroadcastAccum = 0
		end
		broadcastStrength(owner, compIdx)
	end

	-- Always queue respawn, whether company is broken or not
	comp.respawnQueue += 1

	syncCompanies(owner)

	-- Remaining soldiers fill formation gap immediately
	local soldierIds = {}
	for _, sid in ipairs(comp.slots) do
		local s = activeNpcs[sid]
		if s and not s.IsFlagBearer then
			soldierIds[#soldierIds + 1] = sid
		end
	end

	local soldierCount = #soldierIds
	if soldierCount > 0 and comp.anchorCF then
		-- Keep original formation layout - don't recalculate ranks/files
		-- Just fill slots with remaining soldiers using existing formation dimensions
		local slots = RegimentFormation.getSlots(comp.anchorCF, soldierCount, comp.ranks, comp.files)
		for i, sid in ipairs(soldierIds) do
			local s = activeNpcs[sid]
			if not s then continue end
			s.RegimentTarget = slots[i].Position
			s.MoveRetries    = 0
			task.spawn(function()
				if s.ActiveTween then s.ActiveTween:Cancel() s.ActiveTween = nil end
				s.Pathfinder:Stop()
				s.Pathfinder:Run(slots[i].Position)
			end)
		end
	end
end

local function applyDamage(targetNpc, damage)
	if not targetNpc or not activeNpcs[targetNpc.ShortId] then return end
	targetNpc.Health -= damage
	if targetNpc.Health <= 0 then
		killNpc(targetNpc.ShortId)
	end
end

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

			if activeNpcs[shortId].Pathfinder then
				activeNpcs[shortId].Pathfinder:Destroy()
			end

			activeNpcs[shortId].Model:Destroy()
			activeNpcs[shortId] = nil
		end
	end

	playerCompanies[companyIndex] = nil

	if serverCanAttack[player] then
		serverCanAttack[player][companyIndex] = nil
	end
end

local function despawnAllCompanies(player: Player)
	local playerCompanies = companies[player]
	if not playerCompanies then return end
	for idx in pairs(playerCompanies) do
		 despawnCompany(player, idx)
	end
	
	companies[player] = nil
end

local function broadcastCanAttackState(player, companyIndex, state)
	for p in pairs(readyPlayers) do
		Network.NpcCanAttackSync.Fire(p, companyIndex, state, player.UserId)
	end
end

local function flushRespawnQueue(player, companyIndex)
	local comp = companies[player] and companies[player][companyIndex]

	if not comp then print("[RESPAWN] No company found") return end
	if comp.isBroken then print("[RESPAWN] Company broken") return end
	if comp.bearerRespawnGate then print("[RESPAWN] Gate locked") return end
	if comp.respawnQueue <= 0 then print("[RESPAWN] Queue empty:", comp.respawnQueue) return end
	if isEnemyBearerNearby(player, companyIndex) then print("[RESPAWN] Enemies nearby") return end

	local bearerPos = nil
	for _, sid in ipairs(comp.slots) do
		local npc = activeNpcs[sid]
		if npc and npc.IsFlagBearer then
			bearerPos = npc.Root.Position
			break
		end
	end
	if not bearerPos then print("[RESPAWN] No bearer found") return end

	print("[RESPAWN] Flushing queue, count:", comp.respawnQueue)

	local count = comp.respawnQueue
	comp.respawnQueue = 0

	for _ = 1, count do
		task.spawn(function()
			local offset = Vector3.new(math.random(-3, 3), 4, math.random(-3, 3))
			local spawnCF = CFrame.new(bearerPos + offset)
			local npc, data = spawnNpc(spawnCF, true, player)
			if not npc then return end

			npc.IsRegiment   = true
			npc.CompanyOwner = player
			npc.CompanyIndex = companyIndex
			npc.RegimentFacing = comp.anchorCF and comp.anchorCF.LookVector or Vector3.new(0, 0, -1)

			table.insert(comp.slots, npc.ShortId)

			-- Reassign formation slots
			local soldierIds = {}
			for _, sid in ipairs(comp.slots) do
				local s = activeNpcs[sid]
				if s and not s.IsFlagBearer then
					soldierIds[#soldierIds + 1] = sid
				end
			end

			local soldierCount = #soldierIds
			if soldierCount > 0 and comp.anchorCF then
				-- Keep original formation layout - don't recalculate ranks/files
				local slots = RegimentFormation.getSlots(comp.anchorCF, soldierCount, comp.ranks, comp.files)
				for j, sid in ipairs(soldierIds) do
					local s = activeNpcs[sid]
					if not s then continue end
					s.RegimentTarget = slots[j].Position
					s.MoveRetries = 0
					task.spawn(function()
						if s.ActiveTween then s.ActiveTween:Cancel() s.ActiveTween = nil end
						s.Pathfinder:Stop()
						s.Pathfinder:Run(slots[j].Position)
					end)
				end
			end

			for p in pairs(readyPlayers) do
				Network.NpcSpawn.Fire(p, {
					Type         = "Single",
					id           = npc.ShortId,
					pos          = npc.Root.CFrame.Position,
					yaw          = getYaw(npc.Root.CFrame),
					teamName     = npc.TeamName,
					isBearer     = false,
					companyIndex = companyIndex,
					ownerUserId  = player.UserId,
				})
				Network.NpcWeaponState.Fire(p, npc.ShortId, WEAPON_IDLE)
			end

			syncCompanies(player)
		end)
	end
end

local function spawnAllCompanies(player: Player, companyCount: number, botCount: number)
	companyCount = math.clamp(companyCount, 1, MAX_COMPANIES)
	botCount     = math.clamp(botCount, 1, MAX_BOTS)

	local char = player.Character
	if not char then return end
	local playerRoot = char:FindFirstChild("HumanoidRootPart")
	if not playerRoot then return end

	despawnAllCompanies(player)
	companies[player] = {}

	local look = playerRoot.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z).Unit
	local right = flatLook:Cross(Vector3.new(0, 1, 0)).Unit

	-- Calculate geometry for soldiers (Total bots minus the 1 bearer)
	local soldierCount = math.max(1, botCount - 1)
	local files        = math.min(soldierCount, 10)
	local ranks        = math.ceil(soldierCount / files)
	local companyWidth = (files - 1) * RANK_SPACING

	local totalWidth  = companyCount * companyWidth + (companyCount - 1) * COMPANY_GAP
	local startOffset = -totalWidth / 2

	local pending = companyCount * botCount
	local results = {}
	local companyAnchors = {}

	for i = 1, companyCount do
		local centerOffset = startOffset + (i - 1) * (companyWidth + COMPANY_GAP) + companyWidth / 2
		local anchorPos    = playerRoot.Position + flatLook * SPAWN_OFFSET + right * centerOffset
		local anchorCF     = CFrame.lookAt(anchorPos, anchorPos + flatLook)

		companyAnchors[i]  = anchorCF
		local slots = RegimentFormation.getSlots(anchorCF, soldierCount, ranks, files)

		for j = 1, botCount do
			task.spawn(function()
				local isBearer = (j == 1)
				local targetCF

				if isBearer then
					local totalDepth = (ranks - 1) * RANK_DEPTH
					local dynamicZ   = totalDepth + FLAG_OFFSET_Z
					targetCF = anchorCF * CFrame.new(0, 0, dynamicZ)  -- centre, not halfWidth
				else
					targetCF = slots[j - 1]
				end

				local npc, data = spawnNpc(targetCF + Vector3.new(0, 4, 0), true, player)
				if npc then
					npc.IsRegiment = true
					npc.RegimentFacing = flatLook
					npc.RegimentTarget = targetCF.Position
					npc.CompanyOwner = player
					npc.CompanyIndex = i

					if isBearer then
						npc.IsFlagBearer  = true
						npc.PaceDirection = 1
						npc.BearerMode    = BEARER_MODE_CENTER  -- ADD
						npc.IsPacing      = false               -- ADD
						-- Send bearer flag through spawn event
						data.isBearer = true
					end

					npc.Pathfinder:Run(targetCF.Position)

					table.insert(results, {
						companyIndex = i,
						slotIndex = j,
						shortId = npc.ShortId,
						spawnData = data,
					})
				end

				pending -= 1
				if pending == 0 then
					local allSpawnData = {}
					local companiesSlots = {}
					for _, res in ipairs(results) do
						allSpawnData[#allSpawnData + 1] = res.spawnData
						if not companiesSlots[res.companyIndex] then
							companiesSlots[res.companyIndex] = {}
						end
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
							respawnQueue         = 0,
							regenAccum           = 0,
							decayAccum           = 0,
							brokenBroadcastAccum = 0,
							bearerRespawnGate    = false,
						}
						
						serverCanAttack[player] = serverCanAttack[player] or {}
						serverCanAttack[player][idx] = true
						broadcastCanAttackState(player, idx, true)   -- <-- add this line
					end

					syncCompanies(player)
				end
			end)
		end
	end
end

local function orderCompany(player: Player, companyIndex: number, anchorPos: Vector3, facingDir: Vector3, ranks: number, files: number)
	local playerCompanies = companies[player]
	if not playerCompanies then return end

	local company = playerCompanies[companyIndex]
	if not company then return end

	local flat = Vector3.new(facingDir.X, 0, facingDir.Z)
	if flat.Magnitude < 0.01 then return end
	flat = flat.Unit

	local count = #company.slots

	-- [FLAG BEARER LOGIC] Ensure math accounts for 1 bot being excluded from slots
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

		-- [FLAG BEARER LOGIC] Assign separate movement logic for bearer
		if npc.IsFlagBearer then
			targetCF = getBearerTarget(npc, {
				anchorCF = anchorCF,
				ranks    = ranks,
				files    = files,
			})
		else
			targetCF = slots[soldierIdx]
			soldierIdx += 1
		end

		npc.RegimentTarget = targetCF.Position
		npc.RegimentFacing = flat 
		npc.MoveRetries    = 0
		npc.IsRegiment     = true

		task.spawn(function()
			if npc.ActiveTween then
				npc.ActiveTween:Cancel()
				npc.ActiveTween = nil
			end

			npc.Pathfinder:Stop()
			npc.Pathfinder:Run(targetCF.Position)
			npc.LastMoveTime = os.clock()
		end)
	end

	company.anchorCF = anchorCF
	company.ranks    = ranks
	company.files    = files
end

Players.PlayerRemoving:Connect(function(player)
	despawnAllCompanies(player)
	readyPlayers[player] = nil
	farLastSent[player]  = nil
end)

-- ── Chat: /spawn <nc> <n> ─────────────────────────────────────────────
local function hookChat(player: Player)
	player.Chatted:Connect(function(msg: string)
		local ncStr, nStr = msg:match("^%s*/[Ss][Pp][Aa][Ww][Nn]%s+(%d+)%s+(%d+)%s*$") 
		if not (ncStr and nStr) then return end

		local nc = tonumber(ncStr)
		local n  = tonumber(nStr)

		if nc and n and nc >= 1 and nc <= MAX_COMPANIES and n >= 1 then
			spawnAllCompanies(player, nc, n)
		end
	end)
end

Players.PlayerAdded:Connect(hookChat)
for _, p in ipairs(Players:GetPlayers()) do
	hookChat(p)
end

-- ── Combat Loop ─────────────────────────────────────────────────────────
local function setNpcWeaponState(npc, state, targetPos)
	npc.WeaponState = state
	npc.WeaponTimer = WEAPON_DURATIONS[state] or 0

	-- AlignOrientation gating
	if state == WEAPON_TO_AIM then
		npc.AimAlign.Enabled = true
	elseif state == WEAPON_FIRE or state == WEAPON_IDLE then
		npc.AimAlign.Enabled = false
	end

	for p in pairs(readyPlayers) do
		Network.NpcWeaponState.Fire(p, npc.ShortId, state)
	end

	if state == WEAPON_FIRE then
		if targetPos then
			for p in pairs(readyPlayers) do
				Network.NpcFire.Fire(p, npc.ShortId, targetPos)
			end
		end
		if npc.WeaponTarget then
			applyDamage(npc.WeaponTarget, MUSKET_DAMAGE)
		end
	end
end

local function processTickets(dt)
	for player, playerCompanies in pairs(companies) do
		for compIdx, comp in pairs(playerCompanies) do
			if comp.isBroken then
				if comp.brokenTimer > 0 then
					comp.brokenTimer = math.max(0, comp.brokenTimer - dt)
				end

				-- Broadcast timer to client once per second
				comp.brokenBroadcastAccum = (comp.brokenBroadcastAccum or 0) + dt
				if comp.brokenBroadcastAccum >= 1 then
					comp.brokenBroadcastAccum -= 1
					broadcastStrength(player, compIdx)
				end

				-- Recovery: timer done AND no nearby enemy
				if comp.brokenTimer <= 0 and not isEnemyBearerNearby(player, compIdx) then
					comp.isBroken         = false
					comp.tickets          = math.floor(MAX_TICKETS / 2)
					comp.regenAccum       = 0
					comp.decayAccum       = 0
					comp.brokenBroadcastAccum = 0
					broadcastStrength(player, compIdx)
				end
			else
				-- Regen
				comp.regenAccum = (comp.regenAccum or 0) + dt
				if comp.regenAccum >= TICKET_REGEN_INTERVAL then
					comp.regenAccum -= TICKET_REGEN_INTERVAL
					local prev = comp.tickets
					comp.tickets = math.min(MAX_TICKETS, comp.tickets + TICKET_REGEN_RATE)
					if comp.tickets ~= prev then broadcastStrength(player, compIdx) end
				end

			-- Decay: Only drain if enemies nearby (to encourage defensive play)
			local enemyNear = isEnemyBearerNearby(player, compIdx)
			if enemyNear then
				comp.decayAccum = (comp.decayAccum or 0) + dt
				if comp.decayAccum >= TICKET_DECAY_INTERVAL then
					comp.decayAccum -= TICKET_DECAY_INTERVAL
					local prev = comp.tickets
					comp.tickets = math.max(0, comp.tickets - TICKET_DECAY_RATE)
					if comp.tickets ~= prev then
						if comp.tickets <= 0 then
							comp.isBroken             = true
							comp.brokenTimer          = BROKEN_RECOVERY_TIME
							comp.brokenBroadcastAccum = 0
						end
						broadcastStrength(player, compIdx)
					end
					end
				end

				-- Flush respawn queue
				if comp.respawnQueue > 0 then
					flushRespawnQueue(player, compIdx)
				end
			end
		end
	end
end

local function processCombat(dt)
	for shortId, npc in pairs(activeNpcs) do
		if npc.IsFlagBearer then continue end
		if not npc.TeamName then continue end

		local owner      = npc.CompanyOwner
		local companyIdx = npc.CompanyIndex
		if not owner or not companyIdx then continue end

		local canShoot = serverCanAttack[owner] and serverCanAttack[owner][companyIdx]

		-- hard abort
		if not canShoot then
			local reloading = npc.WeaponState == WEAPON_RELOAD_IDLE or npc.WeaponState == WEAPON_RELOAD
			if npc.WeaponState ~= WEAPON_IDLE and not reloading then
				setNpcWeaponState(npc, WEAPON_IDLE, nil)
				npc.WeaponTarget = nil
			end
			continue
		end

		-- idle: hunt for enemy
		if npc.WeaponState == WEAPON_IDLE then
			local enemy = findNearestEnemy(npc)
			if enemy then
				npc.WeaponTarget = enemy
				setNpcWeaponState(npc, WEAPON_MAKE_READY, nil)
			end
			continue
		end

		-- tick
		npc.WeaponTimer -= dt

		-- update aim every frame regardless of timer
		if npc.AimAlign.Enabled and npc.WeaponTarget then
			local aimPos = npc.WeaponTarget.Root and npc.WeaponTarget.Root.Position
			if aimPos then
				local dir = (aimPos - npc.Root.Position)
				dir = Vector3.new(dir.X, 0, dir.Z).Unit
				npc.AimAlign.CFrame = CFrame.lookAt(npc.Root.Position, npc.Root.Position + dir)
			end
		end
		
		if npc.WeaponTimer > 0 then continue end
		
		-- validate target on transitions that need it
		local target    = npc.WeaponTarget
		local targetPos = target and target.Root and target.Root.Position

		if npc.WeaponState == WEAPON_MAKE_READY then
			setNpcWeaponState(npc, WEAPON_MAKEREADY_IDLE, nil)

		elseif npc.WeaponState == WEAPON_MAKEREADY_IDLE then
			setNpcWeaponState(npc, WEAPON_TO_AIM, nil)

		elseif npc.WeaponState == WEAPON_TO_AIM then
			setNpcWeaponState(npc, WEAPON_AIM_IDLE, nil)

		elseif npc.WeaponState == WEAPON_AIM_IDLE then
			if not targetPos then
				-- target gone, abort
				npc.WeaponTarget = nil
				setNpcWeaponState(npc, WEAPON_IDLE, nil)
			else
				setNpcWeaponState(npc, WEAPON_FIRE, targetPos)
			end

		elseif npc.WeaponState == WEAPON_FIRE then
			setNpcWeaponState(npc, WEAPON_RELOAD_IDLE, nil)

		elseif npc.WeaponState == WEAPON_RELOAD_IDLE then
			setNpcWeaponState(npc, WEAPON_RELOAD, nil)

		elseif npc.WeaponState == WEAPON_RELOAD then
			npc.WeaponTarget = nil
			setNpcWeaponState(npc, WEAPON_IDLE, nil)
		end
	end
end

-- ── Broadcast Loop ────────────────────────────────────────────────────
-- Server heartbeat that handles two main systems:
--  1. COMBAT: Processes NPC-to-NPC targeting and shooting
--  2. NETWORK BROADCAST: Sends position updates at dual rates
--
-- Update Rates:
--   - Near Rate (1/20 = 50ms): Detailed snapshots to players < 500 studs away
--   - Far Rate (1/4 = 250ms): Sparse updates to distant players
--
-- Optimization:
--   Uses accumulated deltas (nearAccum, farAccum) to skip checks between ticks
--   Large NPC batches are chunked (35 units per chunk) to avoid network limits
--
local nearAccum = 0
local farAccum  = 0

RunService.Heartbeat:Connect(function(dt)
	nearAccum += dt
	farAccum  += dt
	
	processCombat(dt)
	processTickets(dt)

	local doNear = nearAccum >= NEAR_RATE
	local doFar  = farAccum  >= FAR_RATE

	if not doNear and not doFar then return end
	if doNear then nearAccum -= NEAR_RATE end
	if doFar  then farAccum  -= FAR_RATE  end

	local timestamp     = workspace:GetServerTimeNow()
	local deadIds       = {}
	local dirtyEntries  = {}
	local allFarEntries = {}

	for shortId, npc in pairs(activeNpcs) do
		if not (npc.Model and npc.Model.Parent) then
			deadIds[#deadIds + 1] = shortId
			continue
		end

		if not npc.IsRegiment and os.clock() - npc.LastMoveTime > IDLE_TIMEOUT then
			pickNewTarget(npc)
		end

		local cf = npc.Root.CFrame
		if doFar then
			allFarEntries[#allFarEntries + 1] = makeBatchEntry(shortId, cf)
		end

		if doNear and cfChanged(cf, npc.LastSentCF, npc) then
			dirtyEntries[#dirtyEntries + 1] = makeBatchEntry(shortId, cf)
			npc.LastSentCF = cf
		end
	end

	for player in pairs(readyPlayers) do
		local playerPos = getPlayerRootPos(player)
		if not farLastSent[player] then farLastSent[player] = {} end

		local playerFarSent = farLastSent[player]
		local nearList = {}
		local farList  = {}
		local now      = os.clock()

		if doNear then
			for _, entry in ipairs(dirtyEntries) do
				local dist = playerPos and (entry.pos - playerPos).Magnitude or 0
				if dist <= CULL_RADIUS then
					nearList[#nearList + 1] = entry
				end
			end
		end

		if doFar then
			for _, entry in ipairs(allFarEntries) do
				local sid  = entry.id
				local dist = playerPos and (entry.pos - playerPos).Magnitude or 0
				if dist > CULL_RADIUS then
					local last = playerFarSent[sid] or 0
					if now - last >= FAR_RATE * 0.9 then
						farList[#farList + 1] = entry
						playerFarSent[sid] = now
					end
				end
			end
		end

		if #nearList > 0 then 
			fireChunked(player, timestamp, nearList) 
		end
		
		if #farList  > 0 then 
			fireChunked(player, timestamp, farList) 
		end
	end

	for _, shortId in ipairs(deadIds) do
		for player in pairs(readyPlayers) do
			Network.NpcDespawn.Fire(player, shortId)
			if farLastSent[player] then farLastSent[player][shortId] = nil end
		end
		activeNpcs[shortId] = nil
	end
end)

-- ── Remote Handlers ───────────────────────────────────────────────────
Network.NpcReady.On(function(player)
	if readyPlayers[player] then return end
	readyPlayers[player] = true

	local batchList = {}
	for shortId, npc in pairs(activeNpcs) do
		if npc.Model and npc.Model.Parent then
			local cf = npc.Root.CFrame
			local npcOwner = nil

			for p, comps in pairs(companies) do
				for idx, company in pairs(comps) do
					for _, slotId in ipairs(company.slots) do
						if slotId == shortId then
							npcOwner = p
							break
						end
					end

					if npcOwner then 
						break 
					end
				end

				if npcOwner then
					break
				end
			end

			table.insert(batchList, {
				id           = shortId,
				pos          = cf.Position,
				yaw          = getYaw(cf),
				teamName     = npc.TeamName,
				isBearer     = npc.IsFlagBearer,
				companyIndex = npc.CompanyIndex,
				ownerUserId  = npcOwner and npcOwner.UserId or nil,
			})
		end
	end

	-- Send current canAttack states to the joining player
	for p, comps in pairs(companies) do
		for idx, company in pairs(comps) do
			local state = serverCanAttack[p] and serverCanAttack[p][idx]
			if state ~= nil then
				Network.NpcCanAttackSync.Fire(player, idx, state, p.UserId)  -- fixed: player, idx, state
			end
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
	if companyIndex < 1 or companyIndex > MAX_COMPANIES then return end

	orderCompany(player, companyIndex, anchorPos, facingDir, math.floor(ranks), math.floor(files))
end)

Network.BearerModeCommand.On(function(player, companyIndex, modeRaw)
	if not companies[player] then return end

	companyIndex = math.floor(companyIndex)
	if companyIndex < 1 or companyIndex > MAX_COMPANIES then return end

	local comp = companies[player][companyIndex]
	if not comp then return end

	local mode = math.clamp(math.floor(modeRaw), 0, 3)

	for _, shortId in ipairs(comp.slots) do
		local npc = activeNpcs[shortId]
		if not (npc and npc.IsFlagBearer) then continue end

		-- L is only valid from J; if not in J, redirect to J instead
		if mode == BEARER_MODE_PACING and npc.BearerMode ~= BEARER_MODE_CENTER then
			mode = BEARER_MODE_CENTER
		end

		npc.BearerMode    = mode
		npc.IsPacing      = (mode == BEARER_MODE_PACING)
		npc.PaceDirection = 1  -- reset pace side on any mode change

		npc.Pathfinder:Stop()

		local targetCF = getBearerTarget(npc, comp)
		npc.RegimentTarget = targetCF.Position
		npc.MoveRetries    = 0
		npc.Pathfinder:Run(npc.RegimentTarget)

		break  -- one bearer per company
	end
end)

Network.NpcCanAttackToggle.On(function(player, companyIndex)
	if not companies[player] or not companies[player][companyIndex] then return end

	serverCanAttack[player] = serverCanAttack[player] or {}

	local current = serverCanAttack[player][companyIndex]
	if current == nil then 
		current = true 	
	end

	local newState = not current
	serverCanAttack[player][companyIndex] = newState

	-- Broadcast the new state to all ready players
	for p in pairs(readyPlayers) do
		Network.NpcCanAttackSync.Fire(p, companyIndex, newState, player.UserId)
	end

	-- If attack permission was turned OFF, force all NPCs in this company to stop attacking immediately
	if not newState then
		local comp = companies[player] and companies[player][companyIndex]
		if comp then
			for _, shortId in ipairs(comp.slots) do
				local npc = activeNpcs[shortId]
				if npc and npc.WeaponState ~= WEAPON_IDLE then
					local reloading = npc.WeaponState == WEAPON_RELOAD_IDLE or npc.WeaponState == WEAPON_RELOAD
					if not reloading then
						setNpcWeaponState(npc, WEAPON_IDLE, nil)
						npc.WeaponTarget = nil
					end
				end
			end
		end
	end
end)