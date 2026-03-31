-->>>>>>>>>>>>
-- MUSKET_UTILS
-- Version 2.0.0
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MUSKET_TEMPLATE = ReplicatedStorage.AnimShared.Npc.Item.Musket:WaitForChild("Musket")
local ANIM_FOLDER     = ReplicatedStorage.AnimShared.Npc.Item:WaitForChild("Musket")

local TeamManager = require(ReplicatedStorage.Modules.Shared:WaitForChild("TeamManager"))
local BulletManager = require(ReplicatedStorage.Modules.Client:WaitForChild("BulletManager"))

-- How long to linger in each "hold" animation (seconds)
local MAKE_READY_IDLE_HOLD = 1.0
local AIM_IDLE_HOLD        = 1.0
local RELOAD_IDLE_HOLD     = 1.0

-- Combat config
local FIRE_RANGE           = 150       -- studs, max engagement distance
local TARGET_CHECK_DISTANCE = 200      -- studs, max distance to check for targets
local FACING_THRESHOLD     = 0.5       -- dot product threshold (0.8 = ~36° cone)

local MusketUtils = {}
MusketUtils.__index = MusketUtils

-- Plays a non-looping track and waits for it to finish naturally.
-- Safe to cancel via task.cancel() on the owning thread.
local function playAndWait(track)
	if not track then return end
	track:Play()
	task.wait(math.max(track.Length, 0.05))
end

-- Plays a track for a fixed duration then fades it out.
local function playForDuration(track, duration)
	if not track then return end
	track:Play()
	task.wait(duration)
	track:Stop(0.15)
end

-->>>>>>>>>>>>
-- Find all NPCs in the scene
local function getNpcRegistry()
	return workspace:FindFirstChild("Npc_Registry") or Instance.new("Folder")
end

-->>>>>>>>>>>>
-- Find a target in range and facing direction
local function findTarget(npcModel: Model): Model?
	if not npcModel then return nil end

	local npcTeam = TeamManager.getTeam(npcModel)
	if npcTeam == TeamManager.TEAMS.NONE then return nil end

	local root = npcModel:FindFirstChild("HumanoidRootPart")
	if not root then return nil end

	local npcPos = root.Position
	local npcLook = root.CFrame.LookVector

	local registry = getNpcRegistry()
	local closest = nil
	local closestDist = FIRE_RANGE

	for _, potentialTarget in ipairs(registry:GetChildren()) do
		if potentialTarget == npcModel then continue end

		local targetRoot = potentialTarget:FindFirstChild("HumanoidRootPart")
		if not targetRoot then continue end

		local targetPos = targetRoot.Position
		local dist = (targetPos - npcPos).Magnitude

		-- Check distance
		if dist > closestDist or dist < 1 then continue end

		-- Check team (skip friendlies)
		if TeamManager.isFriendly(npcModel, potentialTarget) then continue end

		-- Check facing direction
		local toTarget = (targetPos - npcPos).Unit
		local dotProduct = npcLook:Dot(toTarget)

		if dotProduct < FACING_THRESHOLD then continue end

		-- Valid target
		closest = potentialTarget
		closestDist = dist
	end

	return closest
end

-->>>>>>>>>>>>
-- Fire a bullet from the musket muzzle
local function fireBullet(clientModel: Model, musket: Model)
	if not musket then return end

	local muzzle = musket:FindFirstChild("Muzzle")
	if not muzzle then 
		warn("[MusketUtils] Musket missing 'Muzzle' part")
		return 
	end

	local root = clientModel:FindFirstChild("HumanoidRootPart")
	if not root then return end

	-- Fire in the direction the NPC is facing
	local direction = root.CFrame.LookVector

	BulletManager.fire(clientModel, muzzle.Position, direction)
end

-->>>>>>>>>>>>
-- Constructor. Attaches the musket and starts the combat loop immediately
-- (canShoot defaults to true).
function MusketUtils.new(clientModel: Model)
	local self = setmetatable({}, MusketUtils)

	self._model      = clientModel
	self._canShoot   = true
	self._hasBullet  = false    -- starts unloaded
	self._loopThread = nil
	self._destroyed  = false

	-- ── Attach musket model ───────────────────────────────────────────
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

	-- ── Load animations ───────────────────────────────────────────────
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

	-- Idle is the resting state — lower priority so walk can show through
	if self._tracks.Idle then
		self._tracks.Idle.Priority = Enum.AnimationPriority.Action
		self._tracks.Idle:Play(0.2)
	end

	self:_startLoop()
	return self
end

-- ── Public API ────────────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Enables or disables the combat loop.
-- When disabling: does NOT cancel reload animations, only prevents new cycles.
function MusketUtils:SetCanShoot(enabled: boolean)
	if self._canShoot == enabled then return end
	self._canShoot = enabled

	if enabled then
		self:_startLoop()
	else
		-- Do NOT cancel the loop thread here - let reload finish naturally
		-- The loop will check self._canShoot at key checkpoints
		if self._tracks.Idle and not self._tracks.Idle.IsPlaying then
			self._tracks.Idle:Play()
		end
	end
end

-->>>>>>>>>>>>
-- Cleanup — call when the NPC despawns.
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
	-- Stop all action-priority tracks cleanly
	for name, track in pairs(self._tracks) do
		if name ~= "Idle" and track and track.IsPlaying then
			track:Stop()
		end
	end
end

function MusketUtils:_startLoop()
	if self._loopThread then return end
	if not self._canShoot or self._destroyed then return end

	local t = self._tracks

	self._loopThread = task.spawn(function()
		while not self._destroyed do

			if t.Idle and t.Idle.IsPlaying then t.Idle:Stop() end

			-- 1. MakeReady
			playAndWait(t.MakeReady)
			if not self._canShoot or self._destroyed then break end

			-- 2. MakeReadyIdle (hold)
			playForDuration(t.MakeReadyIdle, MAKE_READY_IDLE_HOLD)
			if not self._canShoot or self._destroyed then break end

			-- Now we have a bullet
			self._hasBullet = true

			-- 3. ToAim
			playAndWait(t.ToAim)
			if not self._canShoot or self._destroyed then break end

			-- 4. AimIdle (hold) - check for valid target
			local targetModel = findTarget(self._model)

			if targetModel then
				-- Play aim idle while scanning
				playForDuration(t.AimIdle, AIM_IDLE_HOLD)
				if not self._canShoot or self._destroyed then break end

				-- 5. Fire - only if we still have a target and bullet
				if self._hasBullet and findTarget(self._model) then
					playAndWait(t.Fire)
					if self._hasBullet then
						fireBullet(self._model, self._musket)
						self._hasBullet = false
					end
					if not self._canShoot or self._destroyed then break end
				end
			else
				-- No target - skip to reload
				-- Can still fire if canShoot is true, but don't force aim
				playForDuration(t.AimIdle, AIM_IDLE_HOLD * 0.5)
				if not self._canShoot or self._destroyed then break end
			end

			-- 6. ReloadIdle (hold) - continues even if canShoot toggled off
			playForDuration(t.ReloadIdle, RELOAD_IDLE_HOLD)
			if self._destroyed then break end

			-- 7. Reload - continues even if canShoot toggled off
			playAndWait(t.Reload)
			if self._destroyed then break end

			-- After reload, we have a bullet again
			self._hasBullet = true

			-- Check if we should exit loop after reload completes
			if not self._canShoot then break end

			-- Loop back to MakeReady
		end

		-- Return to idle on exit
		if not self._destroyed then
			for name, track in pairs(self._tracks) do
				if name ~= "Idle" and track and track.IsPlaying then
					track:Stop()
				end
			end
			if t.Idle and not t.Idle.IsPlaying then
				t.Idle:Play()
			end
		end

		self._loopThread = nil
	end)
end

return MusketUtils