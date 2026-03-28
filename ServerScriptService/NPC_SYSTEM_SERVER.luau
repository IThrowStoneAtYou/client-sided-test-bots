-->>>>>>>>>>>>
-- NPC_SYSTEM_SERVER
-- Version 3.1.0
-- Description: 
-- Coordinates NPC AI states (Wander/Regiment), handles network replication 
-- with distance-based culling, and manages player-owned companies.
-->>>>>>>>>>>>

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService    = game:GetService("PhysicsService")

local Network           = require(game.ReplicatedStorage.Blink.Server)
local RegimentFormation = require(ReplicatedStorage.Modules.Shared:WaitForChild("RegimentFormation"))
local NoobPath          = require(ReplicatedStorage.Modules.Shared:WaitForChild("NoobPath"))

local SERVER_MODEL  = ReplicatedStorage:WaitForChild("SERVER")

-- ── Config ────────────────────────────────────────────────────────────
local WALK_SPEED    = 14
local CHUNK_SIZE    = 50
local NEAR_RATE     = 1 / 20
local FAR_RATE      = 1 / 4
local CULL_RADIUS   = 1000       -- Increased to match Napoleonic battlefield scale
local DELTA_POS     = 0.08
local DELTA_ROT     = 0.01
local MAX_BOTS      = 300        -- per company
local MAX_COMPANIES = 4
local SPAWN_OFFSET  = 16         -- studs in front of player
local COMPANY_GAP   = 8         -- studs between adjacent companies
local RANK_SPACING  = 4.5       -- mirrors RegimentFormation constant
local MOVE_RETRIES  = 5

local NPC_COLLISION_GROUP = "NpcGroup"
if not PhysicsService:IsCollisionGroupRegistered(NPC_COLLISION_GROUP) then
	PhysicsService:RegisterCollisionGroup(NPC_COLLISION_GROUP)
	print("NpcGroup")
end

-- Ensure NPCs in this group do not collide with each other
PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, NPC_COLLISION_GROUP, false)

local WANDER_CENTER = Vector3.new(0, 0, 0)
local WANDER_RADIUS = 60
local WANDER_MIN    = 8
local IDLE_TIMEOUT  = 3

-- ── State ─────────────────────────────────────────────────────────────
local activeNpcs   = {}   -- [shortId] = npc table
local nextShortId  = 1
local readyPlayers = {}   -- [Player] = true
local farLastSent  = {}   -- [Player] = { [shortId] = os.clock() }

-- companies[player] = { [1..4] = { slots={shortIds}, ranks, files, anchorCF } }
local companies = {}

-- ── Helpers ───────────────────────────────────────────────────────────
-->>>>>>>>>>>>
-- Generates a random Vector3 within a donut-shaped area on the XZ plane
local function randomPoint(center, radius, minDist)
	local angle = math.random() * math.pi * 2
	local dist  = minDist + math.random() * (radius - minDist)

	return Vector3.new(center.X + math.cos(angle) * dist, center.Y, center.Z + math.sin(angle) * dist)
end

-->>>>>>>>>>>>
-- Extracts the Y-axis rotation (Yaw) from a CFrame
local function getYaw(cf)
	local _, y, _ = cf:ToEulerAnglesYXZ()

	return y
end

-->>>>>>>>>>>>
-- Determines if an NPC has moved or rotated enough to justify a network update
local function cfChanged(cf, lastCF)
	if (cf.Position - lastCF.Position).Magnitude > DELTA_POS then
		return true
	end

	if math.abs(getYaw(cf) - getYaw(lastCF)) > DELTA_ROT then
		return true
	end

	return false
end

local function getPlayerRootPos(player)
	local char = player.Character
	if not char then 
		return nil 
	end

	local root = char:FindFirstChild("HumanoidRootPart")

	return root and root.Position or nil
end

-->>>>>>>>>>>>
-- Formats NPC data into a compact table for network transmission
local function makeBatchEntry(shortId, cf)
	return { id = shortId, pos = cf.Position, yaw = getYaw(cf) }
end

-->>>>>>>>>>>>
-- Splits large lists of NPC updates into smaller chunks to prevent network buffer overflows
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

-->>>>>>>>>>>>
-- Commands an idle NPC to walk to a new random location within the wander zone
local function pickNewTarget(npc)
	npc.Target       = randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN)
	npc.LastMoveTime = os.clock()
	npc.Pathfinder:Run(npc.Target)
end

-- ── NPC Spawn ─────────────────────────────────────────────────────────
-->>>>>>>>>>>>
-- Creates a new NPC entity, sets network ownership to server, and registers it in the system
local function spawnNpc(spawnCF: CFrame?, suppressNotify: boolean?)
	local shortId   = nextShortId
	nextShortId     = nextShortId + 1

	local model    = SERVER_MODEL:Clone()
	model.Name     = "NPC_" .. shortId

	local root     = model.HumanoidRootPart
	local humanoid = model.Humanoid
	humanoid.WalkSpeed = WALK_SPEED

	local cf = spawnCF or CFrame.new(
		randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN) + Vector3.new(0, 4, 0)
	)

	root.CFrame  = cf
	model.Parent = workspace.Npc_Registry_Server

	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 1 -- Hide server logic parts to save client rendering overhead
			part.CanTouch = false -- Optimization: Server NPCs don't need to trigger Touched events
			part.CanQuery = false -- Optimization: Server NPCs don't need to be hit by Raycasts
			part.CollisionGroup = NPC_COLLISION_GROUP
			part:SetNetworkOwner(nil)
		end
	end

	local pathfinder = NoobPath.Humanoid(model, {
		WaypointSpacing = 6,
		AgentRadius = 2,
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
	}

	pathfinder.Reached:Connect(function()
		if not npc.IsRegiment then
			pickNewTarget(npc)
		else
			npc.MoveRetries = 0
		end
	end)

	pathfinder.Trapped:Connect(function()
		if not npc.IsRegiment then
			pickNewTarget(npc)
			return
		end

		npc.MoveRetries += 1
		if npc.MoveRetries <= MOVE_RETRIES and npc.RegimentTarget then
			npc.Pathfinder:Run(npc.RegimentTarget)
			npc.LastMoveTime = os.clock()
		end
	end)

	if not spawnCF then pickNewTarget(npc) end

	activeNpcs[shortId] = npc

	if not suppressNotify then
		for player in pairs(readyPlayers) do
			Network.NpcSpawn.Fire(player, {
				Type = "Single",
				id   = shortId,
				pos  = cf.Position,
				yaw  = getYaw(cf),
			})
		end
	end

	return npc, { id = shortId, pos = cf.Position, yaw = getYaw(cf) }
end

-- ── Company Management ────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Sends the current state of a player's companies to their client
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

-->>>>>>>>>>>>
-- Destroys all NPCs associated with a specific company index for a player
local function despawnCompany(player: Player, companyIndex: number)
	local playerCompanies = companies[player]
	if not playerCompanies then
		return 
	end

	local company = playerCompanies[companyIndex]
	if not company then 
		return 
	end

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
end

local function despawnAllCompanies(player: Player)
	local playerCompanies = companies[player]
	if not playerCompanies then return end

	for idx in pairs(playerCompanies) do
		despawnCompany(player, idx)
	end

	companies[player] = nil
end

-- Spawns nc companies of n bots each, side-by-side centered in front of the player.
-->>>>>>>>>>>>
-- Logic for bulk-spawning multiple companies in a line based on player facing direction

-- Spawns nc companies of n bots each, side-by-side centered in front of the player.
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
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.01 then 
		flatLook = Vector3.new(0, 0, -1)
	end
	flatLook = flatLook.Unit

	local right = flatLook:Cross(Vector3.new(0, 1, 0)).Unit

	local totalSpawnData = {}
	-- Default formation per company: up to 10 files wide
	local files        = math.min(botCount, 10)
	local ranks        = math.ceil(botCount / files)
	local companyWidth = (files - 1) * RANK_SPACING

	-- Center all companies across the player's facing direction
	local totalWidth  = companyCount * companyWidth + (companyCount - 1) * COMPANY_GAP
	local startOffset = -totalWidth / 2

	-- For thread‑safe collection of spawned NPC data
	local lock = {}
	local pending = companyCount * botCount  -- total NPCs to spawn
	local results = {}                        -- will store { companyIndex, slotIndex, shortId, spawnData }

	for i = 1, companyCount do
		local centerOffset = startOffset + (i - 1) * (companyWidth + COMPANY_GAP) + companyWidth / 2
		local anchorPos    = playerRoot.Position + flatLook * SPAWN_OFFSET + right * centerOffset
		local anchorCF     = CFrame.lookAt(anchorPos, anchorPos + flatLook)
		local slots        = RegimentFormation.getSlots(anchorCF, botCount, ranks, files)
		local slotIds      = {}

		for j, slotCF in ipairs(slots) do
			task.spawn(function()
				local npc, data = spawnNpc(slotCF + Vector3.new(0, 4, 0), true)
				if npc then
					npc.RegimentTarget = slotCF.Position
					npc.Pathfinder:Run(slotCF.Position)
					npc.LastMoveTime = os.clock()
					-- Store the result thread‑safely
					local resultData = {
						companyIndex = i,
						slotIndex = j,
						shortId = npc.ShortId,
						spawnData = data,
					}
					table.insert(results, resultData)
				end

				pending = pending - 1
				if pending == 0 then
					-- All spawns finished – assemble data and send batch
					local allSpawnData = {}
					local companiesSlots = {}
					for _, res in ipairs(results) do
						allSpawnData[#allSpawnData + 1] = res.spawnData
						if not companiesSlots[res.companyIndex] then
							companiesSlots[res.companyIndex] = {}
						end
						companiesSlots[res.companyIndex][res.slotIndex] = res.shortId
					end

					-- Send spawn batch to all ready players
					for p in pairs(readyPlayers) do
						Network.NpcSpawn.Fire(p, { Type = "Batch", list = allSpawnData })
					end

					-- Build company tables
					for idx = 1, companyCount do
						local slotList = {}
						if companiesSlots[idx] then
							for _, sid in pairs(companiesSlots[idx]) do
								slotList[#slotList + 1] = sid
							end
						end
						companies[player][idx] = {
							anchorCF = anchorCF, -- use the same anchor for all? Actually each company has its own anchor
							slots    = slotList,
							ranks    = ranks,
							files    = files,
						}
					end

					syncCompanies(player)
					print(string.format("[NPC] %s spawned %d companies × %d bots each", player.Name, companyCount, botCount))
				end
			end)
		end
	end
end

--[[
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
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.01 then 
		flatLook = Vector3.new(0, 0, -1)
	end

	flatLook = flatLook.Unit

	local right = flatLook:Cross(Vector3.new(0, 1, 0)).Unit

--
	local totalSpawnData = {}
	-- Default formation per company: up to 10 files wide
	local files        = math.min(botCount, 10)
	local ranks        = math.ceil(botCount / files)
	local companyWidth = (files - 1) * RANK_SPACING

	-- Center all companies across the player's facing direction
	local totalWidth  = companyCount * companyWidth + (companyCount - 1) * COMPANY_GAP
	local startOffset = -totalWidth / 2

	for i = 1, companyCount do
		local centerOffset = startOffset + (i - 1) * (companyWidth + COMPANY_GAP) + companyWidth / 2
		local anchorPos    = playerRoot.Position + flatLook * SPAWN_OFFSET + right * centerOffset
		local anchorCF     = CFrame.lookAt(anchorPos, anchorPos + flatLook)
		local slots        = RegimentFormation.getSlots(anchorCF, botCount, ranks, files)
		local slotIds      = {}

		for j, slotCF in ipairs(slots) do
			local npc, data = spawnNpc(slotCF + Vector3.new(0, 4, 0), true)
			npc.RegimentTarget = slotCF.Position
			npc.Pathfinder:Run(slotCF.Position)
			npc.LastMoveTime = os.clock()
			slotIds[j] = npc.ShortId
			table.insert(totalSpawnData, data)
		end

		companies[player][i] = {
			anchorCF = anchorCF,
			slots    = slotIds,
			ranks    = ranks,
			files    = files,
		}
	end

	for p in pairs(readyPlayers) do
		Network.NpcSpawn.Fire(p, {
			Type = "Batch",
			list = totalSpawnData
		})
	end

	syncCompanies(player)
	print(string.format("[NPC] %s spawned %d companies × %d bots each", player.Name, companyCount, botCount))
end
--[[]]

-->>>>>>>>>>>>
-- Moves an existing company into a new formation at a target position
local function orderCompany(player: Player, companyIndex: number, anchorPos: Vector3, facingDir: Vector3, ranks: number, files: number)
	local playerCompanies = companies[player]
	if not playerCompanies then return end
	local company = playerCompanies[companyIndex]
	if not company then return end

	local flat = Vector3.new(facingDir.X, 0, facingDir.Z)
	if flat.Magnitude < 0.01 then return end
	flat = flat.Unit

	local count = #company.slots
	ranks = math.clamp(ranks, 1, count)
	files = math.clamp(files, 1, count)

	local anchorCF = CFrame.lookAt(anchorPos, anchorPos + flat)
	local slots    = RegimentFormation.getSlots(anchorCF, count, ranks, files)

	for i, shortId in ipairs(company.slots) do
		local npc = activeNpcs[shortId]
		if not (npc and npc.Model and npc.Model.Parent) then 
			continue 
		end

		npc.RegimentTarget = slots[i].Position
		npc.MoveRetries    = 0
		npc.IsRegiment     = true
		-- Launch async pathfinding
		task.spawn(function()
			npc.Pathfinder:Run(slots[i].Position)
			npc.LastMoveTime = os.clock()
		end)
	end

--[[
	for i, shortId in ipairs(company.slots) do
		local npc = activeNpcs[shortId]
		if not (npc and npc.Model and npc.Model.Parent) then 
			continue 
		end

		npc.RegimentTarget = slots[i].Position
		npc.MoveRetries    = 0
		npc.IsRegiment     = true
		npc.Pathfinder:Run(slots[i].Position)
		npc.LastMoveTime   = os.clock()
	end
	--[[]]

	company.anchorCF = anchorCF
	company.ranks    = ranks
	company.files    = files
end

-- ── Remote Handlers ───────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Handles new players joining and sends them the initial state of all existing NPCs
Network.NpcReady.On(function(player)
	if readyPlayers[player] then return end
	readyPlayers[player] = true

	local batchList = {}
	for shortId, npc in pairs(activeNpcs) do
		if npc.Model and npc.Model.Parent then
			local cf = npc.Root.CFrame
			table.insert(batchList, { id = shortId, pos = cf.Position, yaw = getYaw(cf) })
		end
	end

	if #batchList > 0 then
		Network.NpcSpawn.Fire(player, { Type = "Batch", list = batchList })
	end
end)

Network.NpcOrderCommand.On(function(player, anchorPos, facingDir, ranks, files, companyIndex)
	if not companies[player] then return end
	if typeof(anchorPos) ~= "Vector3" then return end
	if typeof(facingDir) ~= "Vector3" then return end -- huh
	if anchorPos.Magnitude > 10000 then return end

	companyIndex = math.floor(companyIndex)
	if companyIndex < 1 or companyIndex > MAX_COMPANIES then 
		return
	end

	orderCompany(player, companyIndex, anchorPos, facingDir, math.floor(ranks), math.floor(files))
end)

Players.PlayerRemoving:Connect(function(player)
	despawnAllCompanies(player)
	readyPlayers[player] = nil
	farLastSent[player]  = nil
end)

-- ── Chat: /spawn <nc> <n> ─────────────────────────────────────────────
-->>>>>>>>>>>>
-- Parses chat commands to allow players to spawn their army
local function hookChat(player: Player)
	player.Chatted:Connect(function(msg: string)
		local ncStr, nStr = msg:match("^%s*/[Ss][Pp][Aa][Ww][Nn]%s+(%d+)%s+(%d+)%s*$") -- yes
		if not (ncStr and nStr) then
			return
		end

		local nc = tonumber(ncStr)
		local n  = tonumber(nStr)

		if nc and n and nc >= 1 and nc <= MAX_COMPANIES and n >= 1 then
			spawnAllCompanies(player, nc, n)
		end
	end)
end

Players.PlayerAdded:Connect(hookChat)
for _, p in ipairs(Players:GetPlayers()) do hookChat(p) end

-- ── Broadcast Loop ────────────────────────────────────────────────────
local nearAccum = 0
local farAccum  = 0

-->>>>>>>>>>>>
-- Main replication loop. Handles distance culling and dirty-state broadcasting.
RunService.Heartbeat:Connect(function(dt)
	nearAccum += dt
	farAccum  += dt

	local doNear = nearAccum >= NEAR_RATE
	local doFar  = farAccum  >= FAR_RATE

	if not doNear and not doFar then
		return 
	end

	if doNear then
		nearAccum -= NEAR_RATE 
	end

	if doFar  then
		farAccum  -= FAR_RATE 
	end

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

		if doNear and cfChanged(cf, npc.LastSentCF) then
			dirtyEntries[#dirtyEntries + 1] = makeBatchEntry(shortId, cf)
			npc.LastSentCF = cf
		end
	end

	for player in pairs(readyPlayers) do
		local playerPos = getPlayerRootPos(player)
		if not farLastSent[player] then
			farLastSent[player] = {} 
		end

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

			if farLastSent[player] then 
				farLastSent[player][shortId] = nil 
			end
		end

		activeNpcs[shortId] = nil
	end
end)