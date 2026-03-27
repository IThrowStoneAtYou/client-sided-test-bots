-->>>>>>>>>>>>
-- NPC_REPLICATOR
-- Written by @Razor5 on discord
-- Version 2.0.0
-- Description: 
-- This module is a simple and basic npc replicator that replicates the npc's position and rotation to the client
-->>>>>>>>>>>>

local RunService = game:GetService("RunService")

local NpcReplicator = {}
NpcReplicator.__index = NpcReplicator

-->>>>>>>>>>>>
-- Self explanatory. This is a constructor of the class
function NpcReplicator.new(id: string, clientModel: Model)
	local self = setmetatable({}, NpcReplicator)

	self.Id = id
	self.Client = clientModel
	self.Root = clientModel:WaitForChild("HumanoidRootPart")

	self.Snapshots = {}
	self.BufferTime = 0.3	--0.1
	self.MaxBuffer = 20
	self.MaxExtrapolation = 0.4 --0.25

	self.Connections = {}
	
	self.Client.Parent = workspace.Npc_Registry

	return self
end

-->>>>>>>>>>>>
-- Returns the entity model
-- This is somewhat unecassary because you can get the entitys model from the constructor (ex: replicator.Client)
function NpcReplicator:GetModel()
	return self.Client
end

-->>>>>>>>>>>>
-- Starts the rendering
function NpcReplicator:Start()
	self:StartRender()
end

-->>>>>>>>>>>>
-- Adds a new movement snapshot received from the server
-- Parameters:
-- cf: CFrame of the entity
-- velocity: movement velocity
-- timestamp: server time
function NpcReplicator:PushNetworkSnapshot(cf, timestamp)
	local last = self.Snapshots[#self.Snapshots]
	if last and timestamp <= last.t then return end

	-- Derive velocity from the position delta with the previous snapshot
	local velocity = Vector3.zero
	if last then
		local dt = timestamp - last.t
		if dt > 0 then
			velocity = (cf.Position - last.cf.Position) / dt
		end
	end

	table.insert(self.Snapshots, {
		t  = timestamp,
		cf = cf,
		v  = velocity,
	})

	while #self.Snapshots > self.MaxBuffer do
		table.remove(self.Snapshots, 1)
	end
end

--[[
function NpcReplicator:PushNetworkSnapshot(cf, velocity, timestamp)
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

	self.LastVelocity = velocity
end
--[[]]

-->>>>>>>>>>>>
-- Connects the render loop
function NpcReplicator:StartRender()
	self.Connections.Render = RunService.RenderStepped:Connect(function()
		self:Render()
	end)
end

-->>>>>>>>>>>>
-- Smoothing core logic. This is the function holding the entirety of the module
-- Extra info: If no future snapshot exist. An extrapolation will occur
function NpcReplicator:Render()
	if #self.Snapshots < 2 then return end

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

	self.Root.CFrame = latest.cf + latest.v * dt
	
	if workspace:GetServerTimeNow() - latest.t > 1 then
		self:Destroy()
	end
end

-->>>>>>>>>>>>
-- Self explanatory
function NpcReplicator:Destroy()
	for _, conn in pairs(self.Connections) do
		conn:Disconnect()
	end
	self.Connections = {}
	
	-->>>>>>>>>>>>
	-- These lines below are optional. can re-enable it if dont want to destroy entity manually
	-->>>>>>>>>>>>
	
	if self.Client then
		self.Client:Destroy()
	end
	
	self.Snapshots = nil
end

return NpcReplicator
