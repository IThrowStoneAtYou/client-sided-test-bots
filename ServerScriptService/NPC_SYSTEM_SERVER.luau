-->>>>>>>>>>>>
-- NPC_SYSTEM — Server (NoobPath Edition)
-- Handles: spawning, wander AI via NoobPath, snapshot broadcasting, late-join, respawn
-->>>>>>>>>>>>

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

-- ─── Modules ─────────────────────────────────────────────────────────────────
local Modules    = ReplicatedStorage:WaitForChild("Modules")
local NoobPath   = require(Modules:WaitForChild("NoobPath"))

-- ─── Templates ───────────────────────────────────────────────────────────────
local SERVER_TEMPLATE = ReplicatedStorage:WaitForChild("SERVER")

-- ─── Remotes Setup ───────────────────────────────────────────────────────────
local NpcSpawned       = ReplicatedStorage.NpcRemotes.NpcSpawned
local NpcDespawned     = ReplicatedStorage.NpcRemotes.NpcDespawned
local NpcBatchSnapshot = ReplicatedStorage.NpcRemotes.NpcBatchSnapshot
local NpcClientDied = ReplicatedStorage.NpcRemotes.NpcClientDied

-- ─── Config ──────────────────────────────────────────────────────────────────
local CONFIG = {
	NpcCount        = 35,
	WanderRadius    = 65,
	RespawnDelay    = 3,
	SnapshotRate    = 0.05,
	WaypointSpacing = 4,
	NpcSpeed        = 16,
	AgentHeight     = 5,
	AgentRadius     = 2,
}

local SPAWN_POSITIONS = {
	Vector3.new(  0, 3,   0),
	Vector3.new( 20, 3,  20),
	Vector3.new(-20, 3,  20),
	Vector3.new( 20, 3, -20),
	Vector3.new(-20, 3, -20),
}

-- ─── State ───────────────────────────────────────────────────────────────────
local activeNpcs  = {} -- [id] = { model, humanoid, root, origin, path }
local lastSentPos = {} -- FIX 1: moved up so Died handler can safely reference it

-- ─── Helpers ─────────────────────────────────────────────────────────────────
local idCounter = 0
local function generateId(): number -- FIX 2: return type corrected to number
	idCounter += 1
	return idCounter
end

local function randomWaypointNear(origin: Vector3, radius: number): Vector3
	local angle = math.random() * math.pi * 2
	local dist  = math.random(math.floor(radius * 0.4), radius)
	return Vector3.new(
		origin.X + math.cos(angle) * dist,
		origin.Y,
		origin.Z + math.sin(angle) * dist
	)
end

-- FIX 5: cycles through SPAWN_POSITIONS instead of falling back to index 1
local function getSpawnPosition(index: number): Vector3
	return SPAWN_POSITIONS[((index - 1) % #SPAWN_POSITIONS) + 1]
end

-- ─── Wander AI (NoobPath) ────────────────────────────────────────────────────
local function startWander(id: number)
	local data = activeNpcs[id]
	if not data then return end

	local path: any = NoobPath.Humanoid(data.model, {
		WaypointSpacing = CONFIG.WaypointSpacing,
		AgentRadius     = CONFIG.AgentRadius,
		AgentHeight     = CONFIG.AgentHeight,
		AgentCanJump    = true,
		PathSettings    = { SupportPartialPath = true },
	})

	path.Timeout = true
	path.Speed   = CONFIG.NpcSpeed

	data.path = path

	local function wander()
		if not activeNpcs[id] then return end
		local target = randomWaypointNear(data.origin, CONFIG.WanderRadius)
		path:Run(target)
	end

	path.Reached:Connect(function()
		task.wait(0.5 + math.random() * 1.5)
		wander()
	end)

	path.Trapped:Connect(function()
		path.Jump()
		task.wait(0.3)
		wander()
	end)

	path.Error:Connect(function(errType: string)
		warn("[NoobPath] NPC", id, "error:", errType)
		task.wait(1)
		wander()
	end)

	wander()
end

-- ─── Spawn ───────────────────────────────────────────────────────────────────
local function spawnNpc(spawnPos: Vector3)
	local id    = generateId()
	local model = SERVER_TEMPLATE:Clone()
	model.Name  = "ServerNPC_" .. id
	model.Parent = workspace.Npc_Registry_Server

	local root     = model:WaitForChild("HumanoidRootPart")
	local humanoid = model:WaitForChild("Humanoid")

	root.CFrame = CFrame.new(spawnPos + Vector3.new(0, 3, 0))

	activeNpcs[id] = {
		model    = model,
		humanoid = humanoid,
		root     = root,
		origin   = spawnPos,
		path     = nil,
	}

	NpcSpawned:FireAllClients(id, root.CFrame)

	humanoid.Died:Connect(function()
		local data = activeNpcs[id]

		if data and data.path then
			data.path:Stop()
			data.path:Destroy()
		end

		NpcDespawned:FireAllClients(id)
		activeNpcs[id]  = nil
		lastSentPos[id] = nil

		task.delay(CONFIG.RespawnDelay, function()
			model:Destroy()
			spawnNpc(spawnPos)
		end)
	end)

	startWander(id)
end

-- ─── Initial Spawn ───────────────────────────────────────────────────────────
for i = 1, CONFIG.NpcCount do
	task.wait(0.1)
	spawnNpc(getSpawnPosition(i)) -- FIX 5: cycles evenly across all positions
end

-- ─── Late-Join Handler ───────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
	task.wait(1)

	for id, data in pairs(activeNpcs) do
		NpcSpawned:FireClient(player, id, data.root.CFrame)
	end
end)

-- ─── Snapshot Broadcast ──────────────────────────────────────────────────────
local lastBroadcast = 0

RunService.Heartbeat:Connect(function()
	local now = workspace:GetServerTimeNow()

	if (now - lastBroadcast) < CONFIG.SnapshotRate then return end
	lastBroadcast = now

	local batch = {}

	for id, data in pairs(activeNpcs) do
		local cf  = data.root.CFrame
		local pos = cf.Position

		if lastSentPos[id] and (pos - lastSentPos[id]).Magnitude < 0.1 then
			continue
		end
		
		lastSentPos[id] = pos

		local yRot = math.floor(math.deg(select(2, cf:ToEulerAnglesYXZ())) * 10 + 0.5) / 10

		table.insert(batch, {
			id   = id,
			pos  = pos,
			yRot = yRot,
			vel  = data.root.AssemblyLinearVelocity,
			t    = now,
		})
	end

	if #batch > 0 then
		NpcBatchSnapshot:FireAllClients(batch)
	end
end)

NpcClientDied.OnServerEvent:Connect(function(player: Player, id: number)
	local data = activeNpcs[id]
	if not data then return end -- already dead or doesn't exist

	data.humanoid:TakeDamage(data.humanoid.MaxHealth) -- force kill → triggers existing Died handler
end)