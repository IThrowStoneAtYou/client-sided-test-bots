-->>>>>>>>>>>>
-- NPC_SYSTEM_SERVER
-- Manages server-side NPC lifecycle, regiment formation, and
-- position broadcasting to all ready clients.
--
-- Architecture:
--   activeNpcs   = flat table of every live NPC keyed by shortId
--   regiments    = one entry per player, holds their slot list
--   readyPlayers = set of players whose client handlers are wired
--
-- Broadcast runs two-tier:
--   Near (≤CULL_RADIUS studs) → 20 hz, dirty-only
--   Far  (> CULL_RADIUS studs) → 4 hz, all NPCs (keeps extrapolation alive)
-->>>>>>>>>>>>

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Networking Remotes ────────────────────────────────────────────────

local Remotes      = ReplicatedStorage:WaitForChild("NpcRemotes")
--local EvtSpawned   = Remotes:WaitForChild("NpcSpawned")
--local EvtDespawned = Remotes:WaitForChild("NpcDespawned")
--local EvtBatch     = Remotes:WaitForChild("NpcBatch")       -- UnreliableRemoteEvent
local EvtReady     = Remotes:WaitForChild("NpcReady")
--local EvtOrder     = Remotes:WaitForChild("NpcOrder")


local NpcPackets = require(game.ReplicatedStorage.Modules.NpcPackets)
local Network = require(game.ReplicatedStorage.Blink.Server)

-- ── Modules ───────────────────────────────────────────────────────────
local RegimentFormation = require(ReplicatedStorage.Modules:WaitForChild("RegimentFormation"))

-- ── Config ────────────────────────────────────────────────────────────
local SERVER_MODEL  = ReplicatedStorage:WaitForChild("SERVER")

local WALK_SPEED    = 14
local CHUNK_SIZE    = 12      -- NPCs per unreliable fire

local NEAR_RATE     = 1 / 20  -- 20 hz for nearby NPCs
local FAR_RATE      = 1 / 4   -- 4 hz keep-alive for distant NPCs
local CULL_RADIUS   = 350     -- studs — near/far split boundary

local DELTA_POS     = 0.08    -- studs — skip broadcast if moved less than this
local DELTA_ROT     = 0.01    -- radians — skip broadcast if rotated less than this

local MAX_SPAWN     = 1000    -- hard cap per /spawn command
local SPAWN_OFFSET  = 16      -- studs in front of the player on /spawn

local MOVE_RETRIES  = 5       -- max MoveTo retries before giving up on a stuck bot

-- Wander config (for non-regiment bots if ever used)
local WANDER_CENTER = Vector3.new(0, 0, 0)
local WANDER_RADIUS = 60
local WANDER_MIN    = 8
local IDLE_TIMEOUT  = 3

-- ── State ─────────────────────────────────────────────────────────────
local activeNpcs   = {}   -- [shortId] = npc table
local nextShortId  = 1
local readyPlayers = {}   -- [Player] = true
local farLastSent  = {}   -- [Player] = { [shortId] = os.clock() }

-- regiments[player] = {  -- Maps a player to their controlled group of bots
--   anchorCF : CFrame,
--   slots    : { shortId },  -- index matches formation slot
--   ranks    : number,
--   files    : number,
-- }
local regiments = {}

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
	if (cf.Position - lastCF.Position).Magnitude > DELTA_POS then return true end
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
	return {
		id = shortId,
		pos = cf.Position,
		yaw = getYaw(cf),
	}
end

local function fireChunked(player, timestamp, entries)
	for i = 1, #entries, CHUNK_SIZE do
		local chunk = {}

		for j = i, math.min(i + CHUNK_SIZE - 1, #entries) do
			local entry = entries[j]
			chunk[#chunk + 1] = {
				id = entry.id,
				pos = entry.pos,
				yaw = entry.yaw,
			}
		end

		Network.NpcBatch.Fire(player, timestamp, chunk)
	end
end

local function pickNewTarget(npc)
	npc.Target       = randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN)
	npc.LastMoveTime = os.clock()
	npc.Humanoid:MoveTo(npc.Target)
end

-- ── NPC Spawn ─────────────────────────────────────────────────────────
-- spawnCF: if provided, bot is regiment-owned and placed at that CFrame.
--          if nil, bot is a free wanderer.
local function spawnNpc(spawnCF: CFrame?)
	local shortId = nextShortId
	nextShortId   = nextShortId + 1

	local model = SERVER_MODEL:Clone()
	model.Name  = "NPC_" .. shortId

	-- Server models are invisible client-side.
	-- Clients render their own CLIENT model clone via NpcReplicator.
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
		--	part.LocalTransparencyModifier = 1
		end
	end
	
	local root     = model:WaitForChild("HumanoidRootPart")
	local humanoid = model:WaitForChild("Humanoid")
	humanoid.WalkSpeed = WALK_SPEED

	local cf = spawnCF or CFrame.new(
		randomPoint(WANDER_CENTER, WANDER_RADIUS, WANDER_MIN) + Vector3.new(0, 4, 0)
	)

	root.CFrame  = cf
	model.Parent = workspace.Npc_Registry_Server
	
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			--	part.LocalTransparencyModifier = 1
			part:SetNetworkOwner(nil)
		end
	end

	local npc = {
		ShortId        = shortId,
		Model          = model,
		Root           = root,
		Humanoid       = humanoid,
		LastMoveTime   = 0,
		LastSentCF     = cf,
		IsRegiment     = spawnCF ~= nil,
		RegimentTarget = nil,   -- set by spawnRegiment / orderRegiment
		MoveRetries    = 0,
	}

	-- MoveToFinished fires when Humanoid:MoveTo completes OR times out (8s).
	-- reached=true  → arrived, reset retry counter
	-- reached=false → Roblox timeout, re-issue same target up to MOVE_RETRIES times
	humanoid.MoveToFinished:Connect(function(reached)
		if not npc.IsRegiment then
			pickNewTarget(npc)
			return
		end

		if reached then
			npc.MoveRetries = 0
		elseif npc.RegimentTarget then
			npc.MoveRetries += 1
			if npc.MoveRetries <= MOVE_RETRIES then
				humanoid:MoveTo(npc.RegimentTarget)
				npc.LastMoveTime = os.clock()
			end
			-- Beyond MOVE_RETRIES the bot stays put — it's stuck on geometry.
		end
	end)

	if not spawnCF then
		pickNewTarget(npc)
	end

	activeNpcs[shortId] = npc

	for player in pairs(readyPlayers) do
		Network.NpcSpawn.Fire(player, {
			Type = "Single",
			id = shortId,
			pos = cf.Position,
			yaw = getYaw(cf)
		})
	end

	return npc
end

-- ── Regiment management ───────────────────────────────────────────────
-- Fully removes a player's regiment: notifies all clients, destroys
-- server models, cleans up activeNpcs and the regiment table entry.
local function despawnRegiment(player: Player)
	local regiment = regiments[player]
	if not regiment then return end

	for _, shortId in ipairs(regiment.slots) do
		if activeNpcs[shortId] then
			for p in pairs(readyPlayers) do
				Network.NpcDespawn.Fire(p, shortId)
				if farLastSent[p] then
					farLastSent[p][shortId] = nil
				end
			end
			activeNpcs[shortId].Model:Destroy()
			activeNpcs[shortId] = nil
		end
	end

	regiments[player] = nil
end

-- Spawns a fresh regiment in a default wide-line formation in front of
-- the player. Always despawns any existing regiment first.
local function spawnRegiment(player: Player, count: number)
	count = math.clamp(count, 1, MAX_SPAWN)

	local char = player.Character
	if not char then return end
	local playerRoot = char:FindFirstChild("HumanoidRootPart")
	if not playerRoot then return end

	despawnRegiment(player)

	local look     = playerRoot.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z).Unit
	local anchorPos = playerRoot.Position + flatLook * SPAWN_OFFSET
	local anchorCF  = CFrame.lookAt(anchorPos, anchorPos + flatLook)

	-- Default layout: up to 20 wide, as many ranks as needed
	local files = math.min(count, 20)
	local ranks = math.ceil(count / files)
	local slots = RegimentFormation.getSlots(anchorCF, count, ranks, files)
	local slotIds = {}

	for i, slotCF in ipairs(slots) do
		local npc = spawnNpc(slotCF + Vector3.new(0, 4, 0))
		npc.RegimentTarget = slotCF.Position
		npc.Humanoid:MoveTo(slotCF.Position)
		npc.LastMoveTime = os.clock()
		slotIds[i] = npc.ShortId
	end

	regiments[player] = {
		anchorCF = anchorCF,
		slots    = slotIds,
		ranks    = ranks,
		files    = files,
	}

	-- Notify the owner of their actual regiment size to keep previews accurate
	-- Using EvtOrder as a simple way to sync size back to the specific client
	Network.NpcRegimentCount.Fire(player, count)
	
	print(string.format("[NpcSystem] %s spawned %d bots (%dr × %df)",
		player.Name, count, ranks, files))
end

-- Issues new slot positions to every bot in the regiment.
-- Called when the player left-clicks (move) or drag-releases (reshape + move).
local function orderRegiment(player: Player, anchorPos: Vector3, facingDir: Vector3, ranks: number, files: number)
	local regiment = regiments[player]
	if not regiment then return end

	local flat = Vector3.new(facingDir.X, 0, facingDir.Z)
	if flat.Magnitude < 0.01 then return end
	flat = flat.Unit

	local count = #regiment.slots
	ranks = math.clamp(ranks, 1, count)
	files = math.clamp(files, 1, count)

	local anchorCF = CFrame.lookAt(anchorPos, anchorPos + flat)
	local slots    = RegimentFormation.getSlots(anchorCF, count, ranks, files)

	for i, shortId in ipairs(regiment.slots) do
		local npc = activeNpcs[shortId]
		if not (npc and npc.Model and npc.Model.Parent) then
			continue
		end

		npc.RegimentTarget = slots[i].Position
		npc.MoveRetries    = 0
		npc.IsRegiment     = true
		npc.Humanoid:MoveTo(slots[i].Position)
		npc.LastMoveTime   = os.clock()
	end

	regiment.anchorCF = anchorCF
	regiment.ranks    = ranks
	regiment.files    = files
end

-- ── Remote handlers ───────────────────────────────────────────────────

-- Client fires NpcReady once all its OnClientEvent handlers are wired.
-- Server responds with a batch of all currently live NPCs.
EvtReady.OnServerEvent:Connect(function(player)
	if readyPlayers[player] then return end
	readyPlayers[player] = true

	local batchList = {}
	for shortId, npc in pairs(activeNpcs) do
		if npc.Model and npc.Model.Parent then
			local cf = npc.Root.CFrame
			table.insert(batchList, {
				id = shortId,
				pos = cf.Position,
				yaw = getYaw(cf)
			})
		end
	end
	
	if #batchList > 0 then
		Network.NpcSpawn.Fire(player, {
			Type = "Batch",
			list = batchList
		})
	end
end)

-- Client fires NpcOrder on left-click (move) or drag-release (reshape).
-- anchorPos = centre of front rank, facingDir = unit facing vector.
Network.NpcOrderCommand.On(function(player, anchorPos, facingDir, ranks, files)
	if typeof(anchorPos) ~= "Vector3" then return end
	if typeof(facingDir) ~= "Vector3" then return end
	if anchorPos.Magnitude > 10000 then return end

	orderRegiment(player, anchorPos, facingDir, math.floor(ranks), math.floor(files))
end)

Players.PlayerRemoving:Connect(function(player)
	despawnRegiment(player)
	readyPlayers[player] = nil
	farLastSent[player]  = nil
end)

-- ── Chat: /spawn n ────────────────────────────────────────────────────
local function hookChat(player: Player)
	player.Chatted:Connect(function(msg: string)
		local raw = msg:match("^%s*/[Ss][Pp][Aa][Ww][Nn]%s+(%d+)%s*$")
		if not raw then return end
		
		local count = tonumber(raw)
		
		if count and count >= 1 then
			spawnRegiment(player, count)
		end
	end)
end

Players.PlayerAdded:Connect(hookChat)
for _, p in ipairs(Players:GetPlayers())do 
	hookChat(p) 
end

-- ── Broadcast loop ────────────────────────────────────────────────────
-- Runs on every Heartbeat, fires at NEAR_RATE and FAR_RATE independently.
--
-- Near list: only NPCs that moved (cfChanged), sent at 20 hz.
-- Far list:  every live NPC regardless of movement, sent at 4 hz.
--            Far bots that stand still still need keep-alives so the
--            client replicator can keep extrapolating without timing out.
local nearAccum = 0
local farAccum  = 0

RunService.Heartbeat:Connect(function(dt)
	nearAccum += dt
	farAccum  += dt

	-- Determine which update tier to run this frame
	local doNear = nearAccum >= NEAR_RATE
	local doFar  = farAccum  >= FAR_RATE
	if not doNear and not doFar then return end
	if doNear then nearAccum -= NEAR_RATE end
	if doFar  then farAccum  -= FAR_RATE  end
	local timestamp = workspace:GetServerTimeNow()
	local deadIds   = {}

	local dirtyEntries  = {}  -- moved NPCs → near players
	local allFarEntries = {}  -- all NPCs   → far players

	for shortId, npc in pairs(activeNpcs) do
		if not (npc.Model and npc.Model.Parent) then
			deadIds[#deadIds + 1] = shortId
			continue
		end

		-- AI Logic: If bot is a free wanderer, check if it needs a new target
		if not npc.IsRegiment and os.clock() - npc.LastMoveTime > IDLE_TIMEOUT then
			pickNewTarget(npc)
		end

		-- Snapshot capturing
		local cf = npc.Root.CFrame
		if doFar then
			allFarEntries[#allFarEntries + 1] = makeBatchEntry(shortId, cf)
		end

		if doNear and cfChanged(cf, npc.LastSentCF) then
			dirtyEntries[#dirtyEntries + 1] = makeBatchEntry(shortId, cf)
			npc.LastSentCF = cf
		end
	end

	-- Per-player: bucket each NPC into near or far based on distance
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
				local dist = playerPos and (entry.pos - playerPos).Magnitude or 0   -- use entry.pos
				if dist <= CULL_RADIUS then
					nearList[#nearList + 1] = entry
				end
			end
		end

		if doFar then
			for _, entry in ipairs(allFarEntries) do
				local sid = entry.id                                                -- use entry.id
				local dist = playerPos and (entry.pos - playerPos).Magnitude or 0   -- use entry.pos
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

	-- Clean up dead NPCs and notify all ready clients
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