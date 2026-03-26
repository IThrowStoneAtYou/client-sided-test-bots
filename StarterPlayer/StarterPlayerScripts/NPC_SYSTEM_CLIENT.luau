-->>>>>>>>>>>>
-- NPC_CLIENT (Client) — ready-gated
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NpcReplicator = require(ReplicatedStorage.Modules:WaitForChild("NPC_Replicator_v2"))
local CLIENT_MODEL  = ReplicatedStorage:WaitForChild("CLIENT")

local Remotes      = ReplicatedStorage:WaitForChild("NpcRemotes")
local EvtSpawned   = Remotes:WaitForChild("NpcSpawned")
local EvtDespawned = Remotes:WaitForChild("NpcDespawned")
local EvtBatch     = Remotes:WaitForChild("NpcBatch")
local EvtReady     = Remotes:WaitForChild("NpcReady")

if not workspace:FindFirstChild("Npc_Registry") then
	local folder  = Instance.new("Folder")
	folder.Name   = "Npc_Registry"
	folder.Parent = workspace
end

local replicators = {}

local function buildCFrame(pos, yaw)
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

local function registerNpc(shortId, pos, yaw)
	if replicators[shortId] then return end
	local clientModel    = CLIENT_MODEL:Clone()
	local rep            = NpcReplicator.new(shortId, clientModel)
	rep.Root.CFrame      = buildCFrame(pos, yaw)
	rep:Start()
	replicators[shortId] = rep
end

-- ── Wire all handlers FIRST, then signal ready ────────────────────────

EvtSpawned.OnClientEvent:Connect(function(idOrBatch, pos, yaw)
	if type(idOrBatch) == "number" then
		registerNpc(idOrBatch, pos, yaw)
	else
		for _, entry in ipairs(idOrBatch) do
			registerNpc(entry[1], entry[2], entry[3])
		end
	end
end)

-- velocity is no longer sent; replicator derives it internally
EvtBatch.OnClientEvent:Connect(function(timestamp, chunk)
	for _, entry in ipairs(chunk) do
		local rep = replicators[entry[1]]
		if rep then
			rep:PushNetworkSnapshot(buildCFrame(entry[2], entry[3]), timestamp)
		end
	end
end)

EvtDespawned.OnClientEvent:Connect(function(shortId)
	local rep = replicators[shortId]
	if not rep then return end
	if rep.Client then rep.Client:Destroy() end
	rep:Destroy()
	replicators[shortId] = nil
end)

-- Signal the server only after all handlers above are connected.
-- This is what eliminates the "did you forget OnClientEvent?" drop warning.
EvtReady:FireServer()