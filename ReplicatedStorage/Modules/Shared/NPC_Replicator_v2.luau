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

	self.LastPos = self.Root.Position
	self.Animator = nil
	self.Connections = {}

	-- Disable collisions for the client-side visual model
	for _, part in ipairs(clientModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
		end
	end

	local humanoid = clientModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
			if state ~= Enum.HumanoidStateType.None then
				humanoid:SetStateEnabled(state, false)
			end
		end
	end

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
-- Links an animator to this replicator to automatically manage movement animations.
function NpcReplicator:SetAnimator(animator)
	self.Animator = animator
end

-->>>>>>>>>>>>
-- Adds a new movement snapshot received from the server
-- Parameters:
-- cf: CFrame of the entity
-- velocity: movement velocity
-- timestamp: server time
function NpcReplicator:PushNetworkSnapshot(cf, timestamp) -- modded
	if not self.Snapshots then return end

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
function NpcReplicator:PushNetworkSnapshot(cf, velocity, timestamp) -- og
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
	self.Connections.Render = RunService.RenderStepped:Connect(function(dt)
		self:Render(dt)
	end)
end

-->>>>>>>>>>>>
-- Smoothing core logic. This is the function holding the entirety of the module
-- Extra info: If no future snapshot exist. An extrapolation will occur
function NpcReplicator:Render(dt)
    if not self.Snapshots then return end
    local latest = self.Snapshots[#self.Snapshots]
    if not latest then return end

    local isMoving = false
    local renderTime = workspace:GetServerTimeNow() - self.BufferTime
    local timeSinceLatest = renderTime - latest.t
    
    local s1, s2
    if #self.Snapshots >= 2 then
        for i = #self.Snapshots - 1, 1, -1 do
            if self.Snapshots[i].t <= renderTime then
                s1 = self.Snapshots[i]
                s2 = self.Snapshots[i + 1]
                break
            end
        end
    end

    if s1 and s2 then
        -- Interpolate between two known points
        local alpha = math.clamp((renderTime - s1.t) / (s2.t - s1.t), 0, 1)
        self.Root.CFrame = s1.cf:Lerp(s2.cf, alpha)
    else
        -- Extrapolate or stay at latest position
        local extrapolationDt = math.max(0, math.min(timeSinceLatest, self.MaxExtrapolation))
        self.Root.CFrame = latest.cf + latest.v * extrapolationDt
    end

    -- Calculate real visual speed to drive animations
    local currentPos = self.Root.Position
    local visualSpeed = (currentPos - self.LastPos).Magnitude / (dt > 0 and dt or 0.01)
    self.LastPos = currentPos

    -- Update linked animator state
    if self.Animator then
        -- Threshold of 0.5 studs/sec to account for micro-jitter
        self.Animator:SetWalking(visualSpeed > 0.5)
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
