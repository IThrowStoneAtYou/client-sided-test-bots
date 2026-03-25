-->>>>>>>>>>>>
-- NPC_SYSTEM — Client
-- Handles: receiving spawns/despawns, creating visual models, feeding replicator
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NpcReplicator = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("NPC_Replicator_v2"))
local Ragdoll = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Ragdoll"))

-- ─── Remotes ─────────────────────────────────────────────────────────────────
local Remotes          = ReplicatedStorage:WaitForChild("NpcRemotes")

local NpcSpawned       = Remotes:WaitForChild("NpcSpawned")
local NpcDespawned     = Remotes:WaitForChild("NpcDespawned")
local NpcBatchSnapshot = Remotes:WaitForChild("NpcBatchSnapshot")
local NpcClientDied    = Remotes:WaitForChild("NpcClientDied")

-- ─── Templates ───────────────────────────────────────────────────────────────
local CLIENT_TEMPLATE = ReplicatedStorage:WaitForChild("CLIENT")

-- ─── Registry Folder (used by NpcReplicator internally) ──────────────────────
if not workspace:FindFirstChild("Npc_Registry") then
	local folder = Instance.new("Folder")
	folder.Name = "Npc_Registry"
	folder.Parent = workspace
end

-- ─── Active Replicators ───────────────────────────────────────────────────────
local replicators = {} -- [id] = NpcReplicator

-- ─── Spawn ───────────────────────────────────────────────────────────────────
NpcSpawned.OnClientEvent:Connect(function(id: number, spawnCFrame: CFrame)
	if replicators[id] then return end

	local clientModel = CLIENT_TEMPLATE:Clone()
	clientModel.Name = "ClientNPC_" .. id

	local root = clientModel:WaitForChild("HumanoidRootPart")
	root.CFrame = spawnCFrame

	local replicator = NpcReplicator.new(id, clientModel)
	replicator:Start()
	replicators[id] = replicator
end)

-- ─── Despawn ─────────────────────────────────────────────────────────────────
NpcDespawned.OnClientEvent:Connect(function(id: number)
	local replicator = replicators[id]
	if not replicator then return end

	local model = replicator.Client

	-- Stop replicator immediately so it stops moving the ragdoll around
	replicator:Destroy()
	replicators[id] = nil

	-- Ragdoll then clean up after delay
	if model then
		Ragdoll.Apply(model)
		task.delay(4, function()
			model:Destroy()
		end)
	end
end)

-- ─── Snapshot Feed ───────────────────────────────────────────────────────────
NpcBatchSnapshot.OnClientEvent:Connect(function(batch: { any })
	for _, snap in ipairs(batch) do
		local replicator = replicators[snap.id]
		if replicator then
			-- fix 2: reconstruct CFrame from compact pos + yRot
			local cf = CFrame.new(snap.pos) * CFrame.Angles(0, math.rad(snap.yRot), 0)
			replicator:PushNetworkSnapshot(cf, snap.vel, snap.t)
		end
	end
end)