-->>>>>>>>>>>>
-- MUSKET_UTILS
-- Version 1.0.0
-->>>>>>>>>>>>
 
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MUSKET_TEMPLATE = ReplicatedStorage.Shared.Npc.Item.Musket:WaitForChild("Musket")
local ANIM_FOLDER     = ReplicatedStorage.Shared.Npc.Item:WaitForChild("Musket")
local SOUND_PATH      = ReplicatedStorage.Shared.Npc.Item.Musket:WaitForChild("Sounds"):WaitForChild("Fire")

local BULLET_SPEED    = 350  -- studs per second
local SOUND_DISTANCE_THRESHOLD = 85  -- studs (from camera)
local BULLET_SPREAD   = 3    -- degrees
local COMBAT_RANGE    = 400

local STATE_TO_ANIM = {
	[0] = "Idle",
	[1] = "MakeReady",
	[2] = "MakeReadyIdle",
	[3] = "ToAim",
	[4] = "AimIdle",
	[5] = "Fire",
	[6] = "ReloadIdle",
	[7] = "Reload",
}

local MELEE_STATE_TO_ANIM = {
	[1] = "bayonetidle",
	[2] = "bayonetbottomstart",
	[3] = "bayonetbottomidle",
	[4] = "bayonetbottomattack",
	[5] = "bayonetupstart",
	[6] = "bayonetupidle",
	[7] = "bayonetupattack",
	[8] = "bayonetidle",
}

local MusketUtils = {}
MusketUtils.__index = MusketUtils

function MusketUtils.new(clientModel: Model, teamName: string?)
	local self = setmetatable({}, MusketUtils)

	self._model      = clientModel
	self._canShoot   = true
	self._destroyed  = false
	self._team       = teamName

	local torso = clientModel:FindFirstChild("Torso")
	if not torso then
		warn("[MusketUtils] No torso on:", clientModel.Name)
		return self
	end

	local musket   = MUSKET_TEMPLATE:Clone()
	local holdPart = musket:FindFirstChild("Hold")
	if not holdPart then
		warn("[MusketUtils] Musket missing 'Hold' BasePart")
		musket:Destroy()
		return self
	end

	local motor   = Instance.new("Motor6D")
	motor.Name    = "MusketGrip"
	motor.Part0   = torso
	motor.Part1   = holdPart
	motor.C0      = CFrame.new()
	motor.C1      = CFrame.new()
	motor.Parent  = torso

	musket.Parent = clientModel
	self._musket  = musket
	self._motor   = motor

	local humanoid = clientModel:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		warn("[MusketUtils] No Animator on:", clientModel.Name)
		return self
	end

	local function load(name)
		local anim = ANIM_FOLDER:FindFirstChild(name)
		if not anim then
			warn("[MusketUtils] Missing anim:", name)
			return nil
		end
		local track = animator:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action2
		return track
	end
	
	local function loadMelee(name)
		local anim = ANIM_FOLDER:FindFirstChild(name)
		if not anim then warn("[MusketUtils] Missing melee anim:", name) return nil end
		local track = animator:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action3
		return track
	end

	self._tracks = {
		Idle          = load("Idle"),
		MakeReady     = load("MakeReady"),
		MakeReadyIdle = load("MakeReadyIdle"),
		ToAim         = load("ToAim"),
		AimIdle       = load("AimIdle"),
		Fire          = load("Fire"),
		ReloadIdle    = load("ReloadIdle"),
		Reload        = load("Reload"),
	}
	
	self._meleeTracks = {
		bayonetidle         = loadMelee("bayonetidle"),
		bayonetbottomstart  = loadMelee("bayonetbottomstart"),
		bayonetbottomidle   = loadMelee("bayonetbottomidle"),
		bayonetbottomattack = loadMelee("bayonetbottomattack"),
		bayonetupstart      = loadMelee("bayonetupstart"),
		bayonetupidle       = loadMelee("bayonetupidle"),
		bayonetupattack     = loadMelee("bayonetupattack"),
	}

	-- Load fire sounds from Close and Far folders
	local closeSounds = {}
	local farSounds = {}
	
	if SOUND_PATH:FindFirstChild("Close") then
		for _, sound in pairs(SOUND_PATH.Close:GetChildren()) do
			if sound:IsA("Sound") then
				table.insert(closeSounds, sound)
			end
		end
		self._closeSounds = closeSounds
	end
	
	if SOUND_PATH:FindFirstChild("Far") then
		for _, sound in pairs(SOUND_PATH.Far:GetChildren()) do
			if sound:IsA("Sound") then
				table.insert(farSounds, sound)
			end
		end
		self._farSounds = farSounds
	end

	self._humanoid = humanoid
	return self
end

function MusketUtils:Destroy()
	self._destroyed = true
	for _, track in pairs(self._meleeTracks or {}) do
		if track then track:Stop() end
	end
	self._meleeTracks = {}
	for _, track in pairs(self._tracks) do
		if track then track:Stop() end
	end
	self._tracks = {}
	if self._musket then
		self._musket:Destroy()
		self._musket = nil
	end
end

function MusketUtils:FaceTarget(targetPos: Vector3)
	local root = self._model:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local myPos = root.Position
	local direction = (targetPos - myPos).Unit
	local newCF = CFrame.lookAt(myPos, myPos + direction)
	root.CFrame = newCF
end

function MusketUtils:CalculateHit(targetPos: Vector3): (number, Vector3)
	local muzzle = self._musket and self._musket:FindFirstChild("Muzzle", true)
	local origin = muzzle and muzzle.Position or (self._model.PrimaryPart.Position + Vector3.new(0, 1.5, 0))
	local direction = (targetPos - origin).Unit

	local spreadRad = math.rad(BULLET_SPREAD)
	local spreadCF = CFrame.lookAt(Vector3.zero, direction)
		* CFrame.Angles((math.random()-0.5)*spreadRad, (math.random()-0.5)*spreadRad, 0)
	local finalDir = spreadCF.LookVector

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	-- Also exclude the server-side invisible hitbox of this same NPC
	local serverRegistry = workspace:FindFirstChild("Npc_Registry_Server")
	local serverModel = serverRegistry and serverRegistry:FindFirstChild(self._model.Name)
	local filter = { self._model }
	if serverModel then
		filter[2] = serverModel
	end
	rayParams.FilterDescendantsInstances = filter

	local result = workspace:Raycast(origin, finalDir * COMBAT_RANGE, rayParams)
	local hitPos = origin + finalDir * COMBAT_RANGE
	local victimId = 0

	if result then
		hitPos = result.Position
		local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
		if hitModel and hitModel.Name:sub(1, 4) == "NPC_" then
			victimId = tonumber(hitModel.Name:sub(5)) or 0
		end
	end

	return victimId, hitPos
end	

function MusketUtils:_fireBullet(targetPos: Vector3)
	local muzzle = self._musket and self._musket:FindFirstChild("Muzzle", true)
	if not muzzle then
		warn("[MusketUtils] No Muzzle found on musket")
		return
	end

	local origin    = muzzle.Position
	local direction = (targetPos - origin)
	local totalDist = direction.Magnitude
	if totalDist < 0.01 then return end

	local unitDir = direction.Unit
	local traveled = 0
	
	local bullet = Instance.new("Part")
	bullet.Name       = "Bullet"
	bullet.Anchored   = true
	bullet.CanCollide = false
	bullet.CanQuery   = false
	bullet.CastShadow = false
	bullet.Material   = Enum.Material.Neon
	bullet.Color      = Color3.fromRGB(255, 220, 100)
	bullet.Size = Vector3.new(0.05, 0.05, 0.05)
	bullet.Transparency = 1
	bullet.CFrame     = CFrame.lookAt(origin, origin + unitDir)

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0, -0.6)
	a0.Parent   = bullet

	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0, 0.6)
	a1.Parent   = bullet

	local trail = Instance.new("Trail")
	trail.Attachment0   = a0
	trail.Attachment1   = a1
	trail.Lifetime      = 0.06
	trail.MinLength     = 0
	trail.FaceCamera    = true
	trail.Color         = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 180)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 140, 60)),
	})
	trail.Transparency  = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale    = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Parent        = bullet

	bullet.Parent = workspace

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { self._model }

	task.spawn(function()
		while traveled < totalDist do
			local dt    = task.wait()
			local step  = BULLET_SPEED * dt

			local result = workspace:Raycast(origin + unitDir * traveled, unitDir * step, rayParams)

			traveled += step

			if result then
				bullet.CFrame = CFrame.lookAt(result.Position, result.Position + unitDir)
			--	print("[Bullet] Hit:", result.Instance:GetFullName(), "| Normal:", result.Normal)
				bullet:Destroy()
				return
			end

			local newPos = origin + unitDir * traveled
			bullet.CFrame = CFrame.lookAt(newPos, newPos + unitDir)
		end

		bullet:Destroy()
	end)
end

function MusketUtils:PlayState(state: number)
	if self._destroyed then return end
	local animName = STATE_TO_ANIM[state]
	if not animName then return end

	for name, track in pairs(self._tracks) do
		if track and track.IsPlaying and name ~= animName then
			track:Stop()
		end
	end

	local track = self._tracks[animName]
	if track and not track.IsPlaying then
		track:Play()
	end
end

function MusketUtils:SetCanShoot(state: boolean)
	self._canShoot = state
	if not state then
		self:PlayState()
	end
end

function MusketUtils:PlayMeleeState(state: number)
	if self._destroyed then return end
	for _, track in pairs(self._tracks or {}) do
		if track and track.IsPlaying then track:Stop() end
	end
	local animName = MELEE_STATE_TO_ANIM[state]
	print("[Client Anim] NPC", self._model.Name, "mapping State", state, "to Anim:", animName)

	for name, track in pairs(self._meleeTracks or {}) do
		if track and track.IsPlaying and name ~= animName then track:Stop() end
	end
	if animName then
		local track = self._meleeTracks and self._meleeTracks[animName]
		if track and not track.IsPlaying then track:Play() end
	end
end

function MusketUtils:ExitMelee()
	if self._destroyed then return end
	for _, track in pairs(self._meleeTracks or {}) do
		if track and track.IsPlaying then track:Stop(0.1) end
	end
	self:PlayState(0)
end

function MusketUtils:_playFireSound()
	-- Determine which sound set to use based on camera distance
	local camera = workspace.CurrentCamera
	local npcPos = self._model:FindFirstChild("HumanoidRootPart")
	if not camera or not npcPos then return end
	
	local cameraPos = camera.CFrame.Position
	local distToCamera = (npcPos.Position - cameraPos).Magnitude
	
	-- Choose sound set based on distance threshold
	local soundSet = (distToCamera < SOUND_DISTANCE_THRESHOLD) and self._closeSounds or self._farSounds
	
	if not soundSet or #soundSet == 0 then return end
	
	-- Pick a random sound from the appropriate set
	local soundTemplate = soundSet[math.random(1, #soundSet)]
	if not soundTemplate then return end
	
	-- Clone and play the sound
	local sound = soundTemplate:Clone()
	sound.Parent = npcPos
	sound:Play()
	
	-- Clean up the sound after it finishes
	local connection
	connection = sound.Ended:Connect(function()
		sound:Destroy()
		connection:Disconnect()
	end)
end

function MusketUtils:PlayFire(targetPos: Vector3)
	if not self._canShoot or self._destroyed then return end
	self:FaceTarget(targetPos)
	self:_playFireSound()
	self:_fireBullet(targetPos)
end

return MusketUtils