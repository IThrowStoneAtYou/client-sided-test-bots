-->>>>>>>>>>>>
-- NPC_MANAGER (Server) — ready-gated + per-player distance culling
-->>>>>>>>>>>>

local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Remotes ──────────────────────────────────────────────────────────
local Remotes      = ReplicatedStorage:WaitForChild("NpcRemotes")
local EvtSpawned   = Remotes:WaitForChild("NpcSpawned")
local EvtDespawned = Remotes:WaitForChild("NpcDespawned")
local EvtBatch     = Remotes:WaitForChild("NpcBatch")
local EvtReady     = Remotes:WaitForChild("NpcReady")

-- ── Modules ────────────────────────────────────────────────────────────
local RegimentFormation = require(ReplicatedStorage.Modules:WaitForChild("RegimentFormation"))

-- ── Config ────────────────────────────────────────────────────────────
local SERVER_MODEL  = ReplicatedStorage:WaitForChild("SERVER")
local NPC_COUNT     = 350

local WANDER_CENTER = Vector3.new(0, 0, 0)
local WANDER_RADIUS = 60
local WANDER_MIN    = 8

local WALK_SPEED    = 14
local UPDATE_RATE   = 1 / 20
local IDLE_TIMEOUT  = 3

local DELTA_POS     = 0.08
local DELTA_ROT     = 0.01
local CHUNK_SIZE    = 12

-- Only send NPCs within this distance of the player's character.
-- Set to math.huge to disable culling (e.g. small maps where all bots are visible).
local NEAR_RATE     = 1 / 20   -- 20 hz for nearby NPCs
local FAR_RATE      = 1 / 4    -- 4 hz keep-alive for distant NPCs
local CULL_RADIUS   = 350      -- studs — near/far boundary

-- ── State ─────────────────────────────────────────────────────────────
local activeNpcs  = {}
local nextShortId = 1
local readyPlayers = {} -- [Player] = true; only populated after NpcReady fires
local farLastSent = {}   -- [Player] = { [shortId] = number }

-- [player] = {
--     formation : string,
--     anchorCF  : CFrame,
--     slots     : { shortId },   -- ordered; index = slot number
-- }
local regiments = {}

local MAX_SPAWN     = 100   -- hard cap per /spawn command
local SPAWN_OFFSET  = 16    -- studs in front of the player the line appears

-- ── Helpers ───────────────────────────────────────────────────────────
local function randomPoint(center, radius, minDist)
	local angle = math.random() * math.pi * 2
	local dist  = minDist + math.random() * (radius - minDist)
	
	return Vector3.new(
		center.X + math.cos(angle) * dist,
		center.Y,
		center.Z + math.sin(angle) * dist
	)
end

local function getYaw(cf)
	local _, y, _ = cf:ToEulerAnglesYXZ()
	return y
end

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

local function fireChunked(player, timestamp, entries)
	for i = 1, #entries, CHUNK_SIZE do
		local chunk = {}
		for j = i, math.min(i + CHUNK_SIZE - 1, #entries) do
			chunk[#chunk + 1] = entries[j]
		end
		
		EvtBatch:FireClient(player, timestamp, chunk)
	end
end

local function pickNewTarget(npc)
	npc.Target       = randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN)
	npc.LastMoveTime = os.clock()
	npc.Humanoid:MoveTo(npc.Target)
end

-- ── Spawn ─────────────────────────────────────────────────────────────

local function spawnNpc(spawnCF: CFrame?)
	local shortId = nextShortId
	nextShortId   = nextShortId + 1

	local model = SERVER_MODEL:Clone()
	model.Name  = "NPC_" .. shortId

	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = 1
		end
	end

	local root     = model:WaitForChild("HumanoidRootPart")
	local humanoid = model:WaitForChild("Humanoid")
	humanoid.WalkSpeed = WALK_SPEED

	-- Use provided CFrame or fall back to random wander position
	local cf = spawnCF or CFrame.new(
		randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN) + Vector3.new(0, 4, 0)
	)

	root.CFrame  = cf
	model.Parent = workspace

	local npc = {
		ShortId      = shortId,
		Model        = model,
		Root         = root,
		Humanoid     = humanoid,
		LastMoveTime = 0,
		LastSentCF   = cf,
	}

	humanoid.MoveToFinished:Connect(function()
		pickNewTarget(npc)
	end)

	-- Only wander if not part of a regiment (regiment handles its own MoveTo)
	if not spawnCF then
		pickNewTarget(npc)
	end

	activeNpcs[shortId] = npc

	for player in pairs(readyPlayers) do
		EvtSpawned:FireClient(player, shortId, cf.Position, getYaw(cf))
	end

	return npc
end

--[[
local function spawnNpc()
	local shortId = nextShortId
	nextShortId   = nextShortId + 1
	
--	print("spawn", nextShortId)

	local model = SERVER_MODEL:Clone()
	model.Name  = "NPC_" .. shortId
	
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = 1
			print("is this even working???")
		end
	end


	local root     = model:WaitForChild("HumanoidRootPart")
	local humanoid = model:WaitForChild("Humanoid")
	humanoid.WalkSpeed = WALK_SPEED

	local spawnCF = CFrame.new(
		randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN) + Vector3.new(0, 4, 0)
	)
	root.CFrame  = spawnCF
	model.Parent = workspace.Npc_Registry_Server

	local npc = {
		ShortId      = shortId,
		Model        = model,
		Root         = root,
		Humanoid     = humanoid,
		LastMoveTime = 0,
		LastSentCF   = spawnCF,
	}

	humanoid.MoveToFinished:Connect(function()
		pickNewTarget(npc)
	end)

	pickNewTarget(npc)
	activeNpcs[shortId] = npc

	-- Notify only players that are already ready
	for player in pairs(readyPlayers) do
		EvtSpawned:FireClient(player, shortId, spawnCF.Position, getYaw(spawnCF))
	end

	return npc
end

for _ = 1, NPC_COUNT do
	spawnNpc()
end
--[[]]

-- ── Regiment spawn ─────────────────────────────────────────────────────
local function spawnRegiment(player: Player, count: number)
	count = math.clamp(count, 1, MAX_SPAWN)

	local char = player.Character
	if not char then return end
	local playerRoot = char:FindFirstChild("HumanoidRootPart")
	if not playerRoot then return end

	-- Anchor is SPAWN_OFFSET studs in front of where the player is looking,
	-- flattened to Y=0 so the line sits on the ground plane.
	local look = playerRoot.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z).Unit

	local anchorPos = playerRoot.Position + flatLook * SPAWN_OFFSET
	local anchorCF  = CFrame.lookAt(anchorPos, anchorPos + flatLook)

	local slots     = RegimentFormation.getSlots(anchorCF, count, "Line")
	local slotIds   = {}

	for i, slotCF in ipairs(slots) do
		-- Raise slightly so bots don't spawn inside the ground
		local raisedCF = slotCF + Vector3.new(0, 4, 0)
		local npc      = spawnNpc(raisedCF)

		-- Walk each bot to its slot (clears the raised Y)
		npc.Humanoid:MoveTo(slotCF.Position)
		npc.LastMoveTime = os.clock()

		slotIds[i] = npc.ShortId
	end

	regiments[player] = {
		formation = "Line",
		anchorCF  = anchorCF,
		slots     = slotIds,
	}

	print(string.format("[NpcManager] %s spawned regiment of %d", player.Name, count))
end

-- ── Ready gate ────────────────────────────────────────────────────────
-- The client fires NpcReady once its handlers are wired.
-- Only then do we send the spawn batch and start streaming updates.
EvtReady.OnServerEvent:Connect(function(player)
	if readyPlayers[player] then return end
	readyPlayers[player] = true

	-- Send all live NPCs in one reliable fire
	local batch = {}
	for shortId, npc in pairs(activeNpcs) do
		if npc.Model and npc.Model.Parent then
			local cf = npc.Root.CFrame
			batch[#batch + 1] = { shortId, cf.Position, getYaw(cf) }
		end
	end

	if #batch > 0 then
		EvtSpawned:FireClient(player, batch)
	end
end)

-- Remove player from ready set on leave
Players.PlayerRemoving:Connect(function(player)
	readyPlayers[player] = nil
	farLastSent[player]  = nil   -- clean up
	regiments[player] 	 = nil
end)


-- ── Broadcast loop ────────────────────────────────────────────────────
local nearAccum = 0
local farAccum  = 0

RunService.Heartbeat:Connect(function(dt)
	nearAccum += dt
	farAccum  += dt

	local doNear = nearAccum >= NEAR_RATE
	local doFar  = farAccum  >= FAR_RATE

	if not doNear and not doFar then return end

	if doNear then nearAccum -= NEAR_RATE end
	if doFar  then farAccum  -= FAR_RATE  end

	local timestamp = workspace:GetServerTimeNow()
	local deadIds   = {}

	-- [CHANGED] Two separate tables:
	--   dirtyEntries  — NPCs that moved; used for near players (high freq)
	--   allFarEntries — every live NPC; used for far keep-alive (low freq)
	--   Far players need ALL npcs so stationary ones don't go dark.
	local dirtyEntries  = {}
	local allFarEntries = {}

	for shortId, npc in pairs(activeNpcs) do
		if not (npc.Model and npc.Model.Parent) then
			deadIds[#deadIds + 1] = shortId
			continue
		end

		if os.clock() - npc.LastMoveTime > IDLE_TIMEOUT then
			pickNewTarget(npc)
		end

		local cf = npc.Root.CFrame

		if doFar then
			-- Always include every live NPC in the far list
			allFarEntries[#allFarEntries + 1] = {
				shortId,
				cf.Position,
				getYaw(cf),
			}
		end

		if doNear and cfChanged(cf, npc.LastSentCF) then
			-- Only include moved NPCs in the near list
			dirtyEntries[#dirtyEntries + 1] = {
				shortId,
				cf.Position,
				getYaw(cf),
			}
			npc.LastSentCF = cf
		end
	end

	-- Per-player: route each NPC to near or far based on distance
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
				local dist = playerPos and (entry[2] - playerPos).Magnitude or 0
				if dist <= CULL_RADIUS then
					nearList[#nearList + 1] = entry
				end
			end
		end

		if doFar then
			for _, entry in ipairs(allFarEntries) do
				local shortId = entry[1]
				local dist    = playerPos and (entry[2] - playerPos).Magnitude or 0
				if dist > CULL_RADIUS then
					local lastSent = playerFarSent[shortId] or 0
					if now - lastSent >= FAR_RATE * 0.9 then
						farList[#farList + 1] = entry
						playerFarSent[shortId] = now
					end
				end
			end
		end

		if #nearList > 0 then
			fireChunked(player, timestamp, nearList)
		end
		if #farList > 0 then
			fireChunked(player, timestamp, farList)
		end
	end

	for _, shortId in ipairs(deadIds) do
		for player in pairs(readyPlayers) do
			EvtDespawned:FireClient(player, shortId)
			if farLastSent[player] then
				farLastSent[player][shortId] = nil
			end
		end
		activeNpcs[shortId] = nil
	end
end)

-- ── Chat command listener ─────────────────────────────────────────────
-- Wire up for players already in the server and ones who join later.
local function hookChat(player: Player)
	player.Chatted:Connect(function(message: string)
		-- Match "/spawn n" case-insensitively, ignore leading spaces
		local raw = message:match("^%s*/[Ss][Pp][Aa][Ww][Nn]%s+(%d+)%s*$")
		if not raw then return end

		local count = tonumber(raw)
		if not count or count < 1 then return end

		spawnRegiment(player, count)
	end)
end

Players.PlayerAdded:Connect(hookChat)
for _, player in ipairs(Players:GetPlayers()) do
	hookChat(player)
end