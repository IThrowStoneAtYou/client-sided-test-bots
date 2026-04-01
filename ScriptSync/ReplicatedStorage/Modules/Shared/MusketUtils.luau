-->>>>>>>>>>>>
-- MUSKET_UTILS
-- Version 1.0.0 (debug + movement fix)
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MUSKET_TEMPLATE = ReplicatedStorage.AnimShared.Npc.Item.Musket:WaitForChild("Musket")
local ANIM_FOLDER     = ReplicatedStorage.AnimShared.Npc.Item:WaitForChild("Musket")

-- How long to linger in each "hold" animation (seconds)
local MAKE_READY_IDLE_HOLD = 1.0
local AIM_IDLE_HOLD        = 1.0
local RELOAD_IDLE_HOLD     = 1.0

local MusketUtils = {}
MusketUtils.__index = MusketUtils

-- Movement detection: more sensitive
function MusketUtils:isMoving()
	local moveDir = self._humanoid and self._humanoid.MoveDirection
	return moveDir and moveDir.Magnitude > 0.05   -- lower threshold
end

-- Plays a non-looping track and waits for it to finish.
-- Returns true if finished normally, false if aborted.
local function playAndWait(track, cancelFn)
	if not track then return true end
	track:Play()
	local start = os.clock()
	local lastCheck = os.clock()
	while track.IsPlaying and os.clock() - start < track.Length + 0.5 do
		-- Check every 0.05 seconds for faster response
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

-- Plays a track for a fixed duration then fades it out.
-- Returns true if finished normally, false if aborted.
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

-->>>>>>>>>>>>
-- Constructor. Attaches the musket and starts the combat loop immediately
function MusketUtils.new(clientModel: Model, teamName: string?)
	local self = setmetatable({}, MusketUtils)

	self._model      = clientModel
	self._canShoot   = true
	self._loopThread = nil
	self._destroyed  = false
	self._team       = teamName
	self._isReloading = false

	-- Attach musket model
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

	-- Load animations
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
	self:_startLoop()
	return self
end

-->>>>>>>>>>>>
-- Finds the nearest enemy NPC not on the same team within range.
function MusketUtils:FindNearestEnemy(range: number): Model?
	local myPos = self._model:FindFirstChild("HumanoidRootPart")
	if not myPos then return nil end
	myPos = myPos.Position

	local nearest = nil
	local nearestDist = range

	local npcFolder = workspace:FindFirstChild("Npc_Registry")
	if not npcFolder then return nil end

	local foundEnemies = 0
	for _, npcModel in pairs(npcFolder:GetChildren()) do
		if npcModel == self._model then continue end

		local theirTeamName = npcModel:GetAttribute("TeamName")
		local theirRoot = npcModel:FindFirstChild("HumanoidRootPart")
		if not theirRoot then continue end

		local dist = (theirRoot.Position - myPos).Magnitude
		if dist < nearestDist then
			-- Only consider if it's an enemy (different team)
			if not self._team or theirTeamName ~= self._team then
				nearestDist = dist
				nearest = npcModel
				foundEnemies += 1
			else
			--	print("[Musket]", self._model.Name, "skipping friendly", npcModel.Name, "team=", theirTeamName)
			end
		end
	end

	if foundEnemies > 0 then
	--	print("[Musket]", self._model.Name, "found enemy", nearest and nearest.Name or "none", "dist=", nearestDist)
	else
		-- Uncomment for debugging:
		-- print("[Musket]", self._model.Name, "no enemies in range")
	end

	return nearest
end

-->>>>>>>>>>>>
-- Faces the NPC toward a target position.
function MusketUtils:FaceTarget(targetPos: Vector3)
	local root = self._model:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local myPos = root.Position
	local direction = (targetPos - myPos).Unit
	local newCF = CFrame.lookAt(myPos, myPos + direction)
	root.CFrame = newCF
end

-->>>>>>>>>>>>
-- Enables or disables the combat loop.
function MusketUtils:SetCanShoot(enabled: boolean)
--	print("[Musket]", self._model.Name, "SetCanShoot", enabled)
	if self._canShoot == enabled then return end
	self._canShoot = enabled

	if enabled then
		self:_startLoop()
	else
		if not self._isReloading then
			self:_cancelLoop()
			if self._tracks.Idle and not self._tracks.Idle.IsPlaying then
				self._tracks.Idle:Play()
			end
		end
	end
end

-->>>>>>>>>>>>
-- Cleanup
function MusketUtils:Destroy()
	self._destroyed = true
	self:_cancelLoop()

	for _, track in pairs(self._tracks) do
		if track then track:Stop() end
	end
	self._tracks = {}

	if self._musket then
		self._musket:Destroy()
		self._musket = nil
	end
end

-- ── Internal ──────────────────────────────────────────────────────────

function MusketUtils:_cancelLoop()
	if self._loopThread then
		task.cancel(self._loopThread)
		self._loopThread = nil
	end
	for name, track in pairs(self._tracks) do
		if name ~= "Idle" and track and track.IsPlaying then
			track:Stop()
		end
	end
end

function MusketUtils:_startLoop()
	if self._loopThread then return end
	if not self._canShoot or self._destroyed then return end

	self._loopThread = task.spawn(function()
		while self._canShoot and not self._destroyed do
			-- Check for enemies
			local enemy = self:FindNearestEnemy(100)
			if not enemy then
				if self._tracks.Idle and not self._tracks.Idle.IsPlaying then
					self._tracks.Idle:Play()
				end
				task.wait(0.5)
				continue
			end

			-- Stop idle if playing
			if self._tracks.Idle and self._tracks.Idle.IsPlaying then
				self._tracks.Idle:Stop()
			end

			-- If moving and not reloading, skip combat this iteration
			if self:isMoving() and not self._isReloading then
			--	print("[Musket]", self._model.Name, "moving, skipping combat (reloading=", self._isReloading, ")")
				for name, track in pairs(self._tracks) do
					if name ~= "Idle" and track and track.IsPlaying then
						track:Stop()
					end
				end
				self._tracks.Idle:Play()
				task.wait(0.5)
				continue
			end

			-- Helper to check if we should abort (canfire disabled, movement and not reloading)
			local function shouldAbort()
				-- Abort if canShoot has been disabled
				if not self._canShoot then
				--	print("[Musket]", self._model.Name, "aborting step due to canShoot disabled")
					return true
				end
				
				local moving = self:isMoving()
				if moving and not self._isReloading then
				--	print("[Musket]", self._model.Name, "aborting step due to movement")
					return true
				end
				return false
			end

			-- Perform combat sequence, breaking early if aborted
			local ok = true

			-- 1. MakeReady
			if ok then
				ok = playAndWait(self._tracks.MakeReady, shouldAbort)
				if ok and (not self._canShoot or self._destroyed) then break end
			end

			-- 2. MakeReadyIdle
			if ok then
				ok = playForDuration(self._tracks.MakeReadyIdle, MAKE_READY_IDLE_HOLD, shouldAbort)
				if ok and (not self._canShoot or self._destroyed) then break end
			end

			-- 3. ToAim
			if ok then
				ok = playAndWait(self._tracks.ToAim, shouldAbort)
				if ok and (not self._canShoot or self._destroyed) then break end
			end

			-- 4. AimIdle
			if ok then
				self:FaceTarget(enemy:FindFirstChild("HumanoidRootPart").Position)
				ok = playForDuration(self._tracks.AimIdle, AIM_IDLE_HOLD, shouldAbort)
				if ok and (not self._canShoot or self._destroyed) then break end
			end

			-- 5. Fire
			if ok then
				self:FaceTarget(enemy:FindFirstChild("HumanoidRootPart").Position)
				ok = playAndWait(self._tracks.Fire, shouldAbort)
				if ok and (not self._canShoot or self._destroyed) then break end
			end

			-- 6. ReloadIdle
			if ok then
				ok = playForDuration(self._tracks.ReloadIdle, RELOAD_IDLE_HOLD, shouldAbort)
				if ok and (not self._canShoot or self._destroyed) then break end
			end

			-- 7. Reload (ignore movement)
			if ok then
				self._isReloading = true
--				print("[Musket]", self._model.Name, "reloading (movement will not cancel)")
				playAndWait(self._tracks.Reload, function() return false end)  -- never cancel
				self._isReloading = false
			--	print("[Musket]", self._model.Name, "reload finished")
				if not self._canShoot or self._destroyed then break end
			end

			-- If any step was aborted (ok == false), the loop restarts from the top
		end

		-- Cleanup on exit
		self._isReloading = false
		if not self._destroyed then
			for name, track in pairs(self._tracks) do
				if name ~= "Idle" and track and track.IsPlaying then
					track:Stop()
				end
			end
			if self._tracks.Idle and not self._tracks.Idle.IsPlaying then
				self._tracks.Idle:Play()
			end
		end

		self._loopThread = nil
	end)
end

return MusketUtils