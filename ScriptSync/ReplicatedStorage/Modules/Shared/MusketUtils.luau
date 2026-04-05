local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MUSKET_TEMPLATE = ReplicatedStorage.AnimShared.Npc.Item.Musket:WaitForChild("Musket")
local ANIM_FOLDER     = ReplicatedStorage.AnimShared.Npc.Item:WaitForChild("Musket")

local BULLET_SPEED    = 350  -- studs per second
local BULLET_DIAMETER = 0.12
local BULLET_SPREAD   = 3    -- degrees, cone spread angle

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

	self._humanoid = humanoid
	return self
end

function MusketUtils:Destroy()
	self._destroyed = true
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
	
	-- Apply bullet spread in a cone
	if BULLET_SPREAD > 0 then
		local spreadRad = math.rad(BULLET_SPREAD)
		local randomYaw = (math.random() - 0.5) * spreadRad
		local randomPitch = (math.random() - 0.5) * spreadRad
		local cf = CFrame.lookAt(Vector3.zero, unitDir)
		cf = cf * CFrame.Angles(randomPitch, randomYaw, 0)
		unitDir = cf.LookVector
	end
	
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
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Parent        = bullet

	bullet.Parent = workspace

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { self._model, workspace:FindFirstChild("Npc_Registry") }

	task.spawn(function()
		while traveled < totalDist do
			local dt    = task.wait()
			local step  = BULLET_SPEED * dt

			local result = workspace:Raycast(
				origin + unitDir * traveled,
				unitDir * step,
				rayParams
			)

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
		self:PlayState(0)  -- 0 = Idle
	end
end

function MusketUtils:PlayFire(targetPos: Vector3)
	if not self._canShoot or self._destroyed then return end
	self:FaceTarget(targetPos)
	self:_fireBullet(targetPos)
end

return MusketUtils