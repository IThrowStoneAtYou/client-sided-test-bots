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
local Remotes = Instance.new("Folder")
Remotes.Name  = "NpcRemotes"
Remotes.Parent = ReplicatedStorage

local function makeRemote(name: string)
	local re = Instance.new("RemoteEvent")
	re.Name   = name
	re.Parent = Remotes
	return re
end

local NpcSpawned       = makeRemote("NpcSpawned")
local NpcDespawned     = makeRemote("NpcDespawned")
local NpcBatchSnapshot = makeRemote("NpcBatchSnapshot")

-- ─── Config ──────────────────────────────────────────────────────────────────
local CONFIG = {
	NpcCount        = 75,
	WanderRadius    = 65,
	RespawnDelay    = 3,
	SnapshotRate    = 0.05,    -- 0 = every Heartbeat. e.g. 0.05 = 20 per second
	WaypointSpacing = 4,    -- NoobPath: distance between each computed waypoint
	NpcSpeed        = 16,   -- studs/sec, used by NoobPath Timeout calculation
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
local activeNpcs = {} -- [id] = { model, humanoid, root, origin, path }
local lastSentPos = {} -- [id] = Vector3
local lastSentVel = {} -- [id] = Vector3

-- ─── Helpers ─────────────────────────────────────────────────────────────────
local idCounter = 0
local function generateId(): number
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

-- ─── Wander AI (NoobPath) ────────────────────────────────────────────────────
local function startWander(id: string)
	local data = activeNpcs[id]
	if not data then return end

	local path: any = NoobPath.Humanoid(data.model, {
		WaypointSpacing = CONFIG.WaypointSpacing,
		AgentRadius     = CONFIG.AgentRadius,
		AgentHeight     = CONFIG.AgentHeight,
		AgentCanJump    = true,
		PathSettings    = { SupportPartialPath = true },
	})

	path.Timeout  = true
	path.Speed    = CONFIG.NpcSpeed

	data.path = path -- store so we can destroy it on despawn

	-- ── Pick a new random wander target and run toward it ──────────────────
	local function wander()
		if not activeNpcs[id] then return end
		local target = randomWaypointNear(data.origin, CONFIG.WanderRadius)
		path:Run(target)
	end

	-- ── Signals ────────────────────────────────────────────────────────────

	-- Reached: NPC arrived at destination → pause briefly then wander again
	path.Reached:Connect(function()
		task.wait(0.5 + math.random() * 1.5)
		wander()
	end)

	-- Trapped: NPC is stuck → jump to unstuck then retry
	path.Trapped:Connect(function()
		path.Jump()
		task.wait(0.3)
		wander()
	end)

	-- Error: path failed (no path found, etc.) → short wait then retry
	path.Error:Connect(function(errType: string)
		warn("[NoobPath] NPC", id, "error:", errType)
		task.wait(1)
		wander()
	end)

	-- Kick off the first wander
	wander()
end

-- ─── Spawn ───────────────────────────────────────────────────────────────────
local function spawnNpc(spawnPos: Vector3)
	local id    = generateId()
	local model = SERVER_TEMPLATE:Clone()
	model.Name  = "ServerNPC_" .. id
	model.Parent = workspace

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

	-- Tell all current clients about this NPC
	NpcSpawned:FireAllClients(id, root.CFrame)

	-- Death handler
	humanoid.Died:Connect(function()
		local data = activeNpcs[id]

		-- Cleanup NoobPath before destroying
		if data and data.path then
			data.path:Stop()
			data.path:Destroy()
		end

		NpcDespawned:FireAllClients(id)
		activeNpcs[id] = nil
		lastSentPos[id] = nil
		lastSentVel[id] = nil

		task.delay(CONFIG.RespawnDelay, function()
			model:Destroy()
			spawnNpc(spawnPos) -- respawn at same origin
		end)
	end)

	startWander(id)
end

-- ─── Initial Spawn ───────────────────────────────────────────────────────────
for i = 1, CONFIG.NpcCount do
	local pos = SPAWN_POSITIONS[i] or SPAWN_POSITIONS[1]
	task.wait(0.1)
	spawnNpc(pos)
end

-- ─── Late-Join Handler ───────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
	task.wait(1) -- give client scripts time to initialize

	for id, data in pairs(activeNpcs) do
		NpcSpawned:FireClient(player, id, data.root.CFrame)
	end
end)

-- ─── Snapshot Broadcast ──────────────────────────────────────────────────────
local lastBroadcast = 0

RunService.Heartbeat:Connect(function()
	local now = workspace:GetServerTimeNow()

	-- fix 1: rate limiting
	if (now - lastBroadcast) < CONFIG.SnapshotRate then return end
	lastBroadcast = now

	local batch = {}

	for id, data in pairs(activeNpcs) do
		local cf  = data.root.CFrame
		local pos = cf.Position
		local vel = data.root.AssemblyLinearVelocity

		-- fix 4: skip if NPC hasn't moved
		-- We also check velocity change to prevent "sliding" when stopping
		local dist = lastSentPos[id] and (pos - lastSentPos[id]).Magnitude or 999
		local velChange = lastSentVel[id] and (vel - lastSentVel[id]).Magnitude or 999

		if dist < 0.1 and velChange < 1 then
			continue
		end
		lastSentPos[id] = pos
		lastSentVel[id] = vel

		-- fix 2: compact pos + yRot instead of full CFrame
		local yRot = math.floor(math.deg(select(2, cf:ToEulerAnglesYXZ())) * 10 + 0.5) / 10

		table.insert(batch, {
			id   = id,
			pos  = pos,
			yRot = yRot,
			vel  = vel,
			t    = now,
		})
	end

	if #batch > 0 then
		NpcBatchSnapshot:FireAllClients(batch)
	end
end)