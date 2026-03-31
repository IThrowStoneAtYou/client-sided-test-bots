-->>>>>>>>>>>>
-- MUSKET_UTILS
-- Version 1.0.0
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

-- Plays a non-looping track and waits for it to finish naturally.
-- Safe to cancel via task.cancel() on the owning thread.
local function playAndWait(track)
	if not track then return end
	track:Play(0.1)
	task.wait(math.max(track.Length, 0.05))
end

-- Plays a track for a fixed duration then fades it out.
local function playForDuration(track, duration)
	if not track then return end
	track:Play(0.1)
	task.wait(duration)
	track:Stop(0.15)
end

-->>>>>>>>>>>>
-- Constructor. Attaches the musket and starts the combat loop immediately
-- (canShoot defaults to true).
function MusketUtils.new(clientModel: Model)
	local self = setmetatable({}, MusketUtils)

	self._model      = clientModel
	self._canShoot   = true
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
function MusketUtils:SetCanShoot(enabled: boolean)
	if self._canShoot == enabled then return end
	self._canShoot = enabled

	if enabled then
		self:_startLoop()
	else
		self:_cancelLoop()
		if self._tracks.Idle and not self._tracks.Idle.IsPlaying then
			self._tracks.Idle:Play(0.2)
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
			track:Stop(0.15)
		end
	end
end

function MusketUtils:_startLoop()
	if self._loopThread then return end
	if not self._canShoot or self._destroyed then return end

	local t = self._tracks

	self._loopThread = task.spawn(function()
		while self._canShoot and not self._destroyed do

			if t.Idle and t.Idle.IsPlaying then t.Idle:Stop(0.1) end

			-- 1. MakeReady
			playAndWait(t.MakeReady)
			if not self._canShoot or self._destroyed then break end

			-- 2. MakeReadyIdle (hold)
			playForDuration(t.MakeReadyIdle, MAKE_READY_IDLE_HOLD)
			if not self._canShoot or self._destroyed then break end

			-- 3. ToAim
			playAndWait(t.ToAim)
			if not self._canShoot or self._destroyed then break end

			-- 4. AimIdle (hold)
			playForDuration(t.AimIdle, AIM_IDLE_HOLD)
			if not self._canShoot or self._destroyed then break end

			-- 5. Fire
			playAndWait(t.Fire)
			if not self._canShoot or self._destroyed then break end

			-- 6. ReloadIdle (hold)
			playForDuration(t.ReloadIdle, RELOAD_IDLE_HOLD)
			if not self._canShoot or self._destroyed then break end

			-- 7. Reload
			playAndWait(t.Reload)
			if not self._canShoot or self._destroyed then break end

			-- Loop back to MakeReady
		end

		-- Return to idle on exit
		if not self._destroyed then
			for name, track in pairs(self._tracks) do
				if name ~= "Idle" and track and track.IsPlaying then
					track:Stop(0.15)
				end
			end
			if t.Idle and not t.Idle.IsPlaying then
				t.Idle:Play(0.2)
			end
		end

		self._loopThread = nil
	end)
end

return MusketUtils