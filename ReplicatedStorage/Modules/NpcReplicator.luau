-->>>>>>>>>>>>
-- NPC_REPLICATOR
-- Written by @Razor5 on discord
-- Version 2.0.1 (patched)
-- Fixes: CFrame extrapolation math, repeated Destroy() calls, nil Snapshots guard
-->>>>>>>>>>>>

local RunService = game:GetService("RunService")

local NpcReplicator = {}
NpcReplicator.__index = NpcReplicator

function NpcReplicator.new(id: string, clientModel: Model)
	local self = setmetatable({}, NpcReplicator)

	self.Id = id
	self.Client = clientModel
	self.Root = clientModel:WaitForChild("HumanoidRootPart")

	self.Snapshots = {}
	self.BufferTime = 0.1
	self.MaxBuffer = 20
	self.MaxExtrapolation = 0.25

	self.Connections = {}
	self.Destroying = false

	self.Client.Parent = workspace.Npc_Registry

	return self
end

function NpcReplicator:GetModel()
	return self.Client
end

function NpcReplicator:Start()
	self:StartRender()
end

function NpcReplicator:PushNetworkSnapshot(cf, velocity, timestamp)
	if not self.Snapshots then return end

	local last = self.Snapshots[#self.Snapshots]
	if last and timestamp <= last.t then return end

	table.insert(self.Snapshots, {
		t = timestamp,
		cf = cf,
		v = velocity
	})

	while #self.Snapshots > self.MaxBuffer do
		table.remove(self.Snapshots, 1)
	end
end

function NpcReplicator:StartRender()
	self.Connections.Render = RunService.RenderStepped:Connect(function()
		self:Render()
	end)
end

function NpcReplicator:Render()
	if not self.Snapshots or #self.Snapshots < 2 then return end

	local renderTime = workspace:GetServerTimeNow() - self.BufferTime

	local s1, s2

	for i = #self.Snapshots - 1, 1, -1 do
		if self.Snapshots[i].t <= renderTime then
			s1 = self.Snapshots[i]
			s2 = self.Snapshots[i + 1]
			break
		end
	end

	if s1 and s2 then
		local alpha = math.clamp(
			(renderTime - s1.t) / (s2.t - s1.t),
			0, 1
		)
		self.Root.CFrame = s1.cf:Lerp(s2.cf, alpha)
		return
	end

	local latest = self.Snapshots[#self.Snapshots]
	local dt = renderTime - latest.t

	if dt <= 0 then return end
	if dt > self.MaxExtrapolation then
		dt = self.MaxExtrapolation
	end

	local newPos = latest.cf.Position + latest.v * dt
	self.Root.CFrame = CFrame.new(newPos) * latest.cf.Rotation

	if not self.Destroying and workspace:GetServerTimeNow() - latest.t > 1 then
		self.Destroying = true
		self:Destroy()
	end
end

function NpcReplicator:Destroy()
	for _, conn in pairs(self.Connections) do
		conn:Disconnect()
	end
	self.Connections = {}
	self.Snapshots = nil
end

return NpcReplicator