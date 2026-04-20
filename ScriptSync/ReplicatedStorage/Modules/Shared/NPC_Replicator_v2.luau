-->>>>>>>>>>>>
-- NPC_REPLICATOR
-- Written by @Razor5 on discord
-- Version 2.0.0
-->>>>>>>>>>>>

local RunService = game:GetService("RunService")
local replicatestorage = game:GetService("ReplicatedStorage")

local NPC_COLLISION_GROUP = "NpcGroup"
local CLIENT_NPC_GROUP = "ClientNpcGroup"

local NpcReplicator = {}
NpcReplicator.__index = NpcReplicator

-->>>>>>>>>>>>
-- Self explanatory. This is a constructor of the class
function NpcReplicator.new(id: string, clientModel: Model)
	local self = setmetatable({}, NpcReplicator)

	self.Id = id
	self.Client = clientModel
	self.Root = clientModel.HumanoidRootPart

	-- ── Snapshot System ───────────────────────────────────
	-- Server sends position snapshots at 20/sec (near) or 4/sec (far)
	-- Client interpolates between snapshots for smooth movement
	self.Snapshots = {}   -- [{t=timestamp, cf=CFrame, v=velocity}, ...]
	self.BufferTime = 0.1  -- was 0.3, too much latency buffer
	self.MaxBuffer = 20    -- revert back to 20 (max snapshots to keep)
	self.MaxExtrapolation = 0.2  -- was 0.4 (max time to extrapolate if no new data)

	self.LastPos = self.Root.Position
	self.Animator = nil
	self.Connections = {}
	
	self._frameSkip    = 0
	self._frameCounter = 0

	for _, part in ipairs(clientModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = CLIENT_NPC_GROUP
			part.CanTouch = false
			part.CanQuery = false
		end
	end

	-- Humanoid resets CanCollide after state changes, so lock it
	local humanoid = clientModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = true  -- forces humanoid to stop fighting physics
		for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
			if state ~= Enum.HumanoidStateType.None then
				humanoid:SetStateEnabled(state, false)
			end
		end
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)  -- puts it in full manual control mode
	end

	-- Disable again AFTER state changes since humanoid may have re-enabled some
	for _, part in ipairs(clientModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
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
-- Clones and welds head/body rigs from Shared.Npc.Nation based on keys.
function NpcReplicator:ApplyRegimentRig(nationKey: string, regimentKey: string, roleKey: string)
	roleKey = roleKey or "ranker"
	print(string.format("[Replicator] Attempting rig apply: %s/%s/%s", tostring(nationKey), tostring(regimentKey), tostring(roleKey)))
	
	local sharedFolder = replicatestorage.Shared
	local npcFolder    = sharedFolder and sharedFolder:FindFirstChild("Npc")
	local outfitFolder = npcFolder and npcFolder:FindFirstChild("Outfit")
	local nationFolder = outfitFolder and outfitFolder:FindFirstChild("Nation")

	if outfitFolder then print("[Replicator] Found Outfit folder") end
	if nationFolder then print("[Replicator] Found Nation base folder") end
	
	local nationPath   = nationFolder and nationFolder:FindFirstChild(nationKey)
	local regFolder    = nationPath and nationPath:FindFirstChild(regimentKey)
	local roleFolder   = regFolder and regFolder:FindFirstChild(roleKey)

	if not roleFolder then 
		warn(string.format("[Replicator] FAILED to find roleFolder at Shared.Npc.Outfit.Nation.%s.%s.%s", nationKey, regimentKey, roleKey))
		if not outfitFolder then warn("   -> Outfit folder missing")
		elseif not nationFolder then warn("   -> Nation base folder missing")
		elseif not nationPath then warn("   -> Specific nation folder missing:", nationKey) end
		return 
	end
	
	print(string.format("[Replicator] Found roleFolder: %s", roleFolder:GetFullName()))
	
	-- Prevent duplicate rigs
	if self.Client:GetAttribute("HasRegimentRig") then return end
	self.Client:SetAttribute("HasRegimentRig", true)

	-- Apply Shirt/Pants
	local shirt = roleFolder:FindFirstChildOfClass("Shirt") or roleFolder:FindFirstChild("Shirt")
	if shirt then
		local existing = self.Client:FindFirstChildOfClass("Shirt")
		if existing then existing:Destroy() end
		shirt:Clone().Parent = self.Client
	end

	local pants = roleFolder:FindFirstChildOfClass("Pants") or roleFolder:FindFirstChild("Pants")
	if pants then
		local existing = self.Client:FindFirstChildOfClass("Pants")
		if existing then existing:Destroy() end
		pants:Clone().Parent = self.Client
	end

	local function attach(rigName, targetPartName)
		local rigTemplate = roleFolder:FindFirstChild(rigName)
		local targetPart   = self.Client:FindFirstChild(targetPartName)
		
		if rigTemplate and targetPart then
			print(string.format("[Replicator] Cloning %s for %s", rigName, targetPartName))
			local rig = rigTemplate:Clone()
			rig.Name = "Rig_" .. rigName
			
			-- 1. Position the part exactly at the target's CFrame BEFORE welding
			if rig:IsA("Model") then
				rig:PivotTo(targetPart.CFrame)
			elseif rig:IsA("BasePart") then
				rig.CFrame = targetPart.CFrame
			end
			
		--	print(string.format("  -> %s position set to: %s", rigName, tostring(rig.Position)))
			
			rig.Parent = self.Client
			
			local primary = (rig:IsA("Model") and rig.PrimaryPart) or (rig:IsA("BasePart") and rig)
			if primary then
				-- 2. Create the weld to maintain the current CFrame offset
				local weld = Instance.new("Weld")
				weld.Part0 = targetPart
				weld.Part1 = primary
				weld.Parent = primary
			end
			
		--	print(string.format("[Visuals] Attached %s to NPC %s", rigName, self.Client.Name))
			for _, p in ipairs(rig:GetDescendants()) do
				if p:IsA("BasePart") then
					p.CanCollide = false
					p.CanTouch   = false
					p.CanQuery   = false
				end
			end
		end
	end

	attach("head_rig",     "Head")
	attach("body_rig",     "Torso")
	attach("leftArm_rig",  "Left Arm")
	attach("rightArm_rig", "Right Arm")
	attach("leftLeg_rig",  "Left Leg")
	attach("rightLeg_rig", "Right Leg")
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

	self._dirty = true

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
	--	self.Connections.Render = RunService.RenderStepped:Connect(function(dt)
	--		self:Render(dt)
	--	end)
end

-->>>>>>>>>>>>
-- Smoothing core logic. This is the function holding the entirety of the module
-- Extra info: If no future snapshot exist. An extrapolation will occur

-- In NpcReplicator.luau, rename Render to ComputeCFrame and return the result
function NpcReplicator:ComputeCFrame(dt, serverTime)
	if not self.Snapshots then return nil end
	local latest = self.Snapshots[#self.Snapshots]
	if not latest then return nil end
	if not self._dirty then return nil end
	
	if self._frameCounter % 30 == 0 then
		local dist = (self.Root.Position - workspace.CurrentCamera.CFrame.Position).Magnitude
		if dist < 60 then
			self._frameSkip = 0   -- full 60fps
		elseif dist < 150 then
			self._frameSkip = 1   -- every 2nd frame
		elseif dist < 300 then
			self._frameSkip = 3   -- every 4th frame
		else
			self._frameSkip = 5   -- every 6th frame
		end
	end

	self._frameCounter += 1
	local shouldUpdatePhysics = (self._frameCounter % (self._frameSkip + 1) == 0)

	local renderTime = (serverTime or workspace:GetServerTimeNow()) - self.BufferTime
	
	-- If we aren't updating this frame and we have a cached result, 
	-- we can exit early but we still need the animator to know we are "moving"
	
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

	local newCF
	if s1 and s2 then
		local alpha = math.clamp((renderTime - s1.t) / (s2.t - s1.t), 0, 1)
		newCF = s1.cf:Lerp(s2.cf, alpha)
	else
		local extrapolationDt = math.max(0, math.min(timeSinceLatest, self.MaxExtrapolation))
		newCF = latest.cf + latest.v * extrapolationDt
	end
	
	if not shouldUpdatePhysics then
		return nil
	end

	-- Animation logic stays here (reads position, doesn't write CFrame)
	local currentPos  = newCF.Position
	local actualDelta = (currentPos - self.LastPos).Magnitude
	local visualSpeed = actualDelta / (dt > 0 and dt or 0.01)
	self.LastPos      = currentPos

	local now = os.clock()
	if self.Animator and (not self._lastAnimCheck or now - self._lastAnimCheck > 0.5) then
		self._lastAnimCheck = now
		local dist = (self.Root.Position - workspace.CurrentCamera.CFrame.Position).Magnitude
		self._isNear = dist < 150
		if not self._isNear then
			self.Animator:SetWalking(false)
		end
	end

	if self.Animator and self._isNear then
		self.Animator:SetWalking(visualSpeed > 1.5)
	end

	if timeSinceLatest > self.MaxExtrapolation then
		self._dirty = false
	end

	return newCF
end

--[[
function NpcReplicator:Render(dt, serverTime)
	if not self.Snapshots then return end
	local latest = self.Snapshots[#self.Snapshots]
	if not latest then return end

	if not self._dirty then return end

	local renderTime = (serverTime or workspace:GetServerTimeNow()) - self.BufferTime
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
		local alpha = math.clamp((renderTime - s1.t) / (s2.t - s1.t), 0, 1)
		self.Root.CFrame = s1.cf:Lerp(s2.cf, alpha)
	else
		local extrapolationDt = math.max(0, math.min(timeSinceLatest, self.MaxExtrapolation))
		self.Root.CFrame = latest.cf + latest.v * extrapolationDt
	end

	local currentPos  = self.Root.Position
	local actualDelta = (currentPos - self.LastPos).Magnitude
	local visualSpeed = actualDelta / (dt > 0 and dt or 0.01)
	self.LastPos      = currentPos

	-- Throttle animation distance checks
	if self.Animator and (not self._lastAnimCheck or tick() - self._lastAnimCheck > 0.5) then
		self._lastAnimCheck = tick()
		local dist = (self.Root.Position - workspace.CurrentCamera.CFrame.Position).Magnitude
		if dist < 150 then
			self._isNear = true
		else
			self._isNear = false
			self.Animator:SetWalking(false)
		end
	end

	if self.Animator and self._isNear then
		self.Animator:SetWalking(visualSpeed > 1.5)
	end

	if timeSinceLatest > self.MaxExtrapolation then
		self._dirty = false
	end
end
--[[]]

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
