local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MUSKET_TEMPLATE = ReplicatedStorage.AnimShared.Npc.Item.Musket:WaitForChild("Musket")
local ANIM_FOLDER     = ReplicatedStorage.AnimShared.Npc.Item:WaitForChild("Musket")

local MAKE_READY_IDLE_HOLD = 1.0
local AIM_IDLE_HOLD        = 1.0
local RELOAD_IDLE_HOLD     = 1.0

local MusketUtils = {}
MusketUtils.__index = MusketUtils

function MusketUtils:isMoving()
	local moveDir = self._humanoid and self._humanoid.MoveDirection
	return moveDir and moveDir.Magnitude > 0.05
end

local function playAndWait(track, cancelFn)
	if not track then return true end
	track:Play()
	local start = os.clock()
	local lastCheck = os.clock()
	while track.IsPlaying and os.clock() - start < track.Length + 0.5 do
		if os.clock() - lastCheck >= 0.05 then
			lastCheck = os.clock()
			if cancelFn and cancelFn() then
				track:Stop()
				return false
			end
		end
		task.wait()
	end
	return true
end

local function playForDuration(track, duration, cancelFn)
	if not track then return true end
	track:Play()
	local start = os.clock()
	local lastCheck = os.clock()
	while os.clock() - start < duration do
		if os.clock() - lastCheck >= 0.05 then
			lastCheck = os.clock()
			if cancelFn and cancelFn() then
				track:Stop()
				return false
			end
		end
		task.wait()
	end
	track:Stop(0.15)
	return true
end

function MusketUtils.new(clientModel: Model, teamName: string?)
	local self = setmetatable({}, MusketUtils)

	self._model      = clientModel
	self._canShoot   = true
	self._destroyed  = false
	self._team       = teamName
	self._isReloading = false
	self._busy       = false

	local torso = clientModel:FindFirstChild("Torso")
		or clientModel:FindFirstChild("UpperTorso")
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

	if self._tracks.Idle then
		self._tracks.Idle.Priority = Enum.AnimationPriority.Action
		self._tracks.Idle:Play()
	end

	self._humanoid = humanoid
	return self
end

function MusketUtils:FaceTarget(targetPos: Vector3)
	local root = self._model:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local myPos = root.Position
	local direction = (targetPos - myPos).Unit
	local newCF = CFrame.lookAt(myPos, myPos + direction)
	root.CFrame = newCF
end

function MusketUtils:SetCanShoot(state)
	self._canShoot = state
end

function MusketUtils:PlayFire(targetPos: Vector3)
	if not self._canShoot or self._destroyed or self._busy then return end
	self._busy = true

	self:FaceTarget(targetPos)

	local function shouldAbort()
		if not self._canShoot then return true end
		local moving = self:isMoving()
		if moving and not self._isReloading then return true end
		return false
	end

	local ok = true

	-- We'll use a simple sequential check; if any step fails, we break out.
	if ok then
		ok = playAndWait(self._tracks.MakeReady, shouldAbort)
		if not ok then ok = false end
	end
	if ok then
		ok = playForDuration(self._tracks.MakeReadyIdle, MAKE_READY_IDLE_HOLD, shouldAbort)
		if not ok then ok = false end
	end
	if ok then
		ok = playAndWait(self._tracks.ToAim, shouldAbort)
		if not ok then ok = false end
	end
	if ok then
		ok = playForDuration(self._tracks.AimIdle, AIM_IDLE_HOLD, shouldAbort)
		if not ok then ok = false end
	end
	if ok then
		ok = playAndWait(self._tracks.Fire, shouldAbort)
		if not ok then ok = false end
	end
	if ok then
		ok = playForDuration(self._tracks.ReloadIdle, RELOAD_IDLE_HOLD, shouldAbort)
		if not ok then ok = false end
	end
	if ok then
		self._isReloading = true
		playAndWait(self._tracks.Reload, function() return false end) -- never cancel reload
		self._isReloading = false
	end

	self._busy = false
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

return MusketUtils