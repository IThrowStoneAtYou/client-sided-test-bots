-->>>>>>>>>>>>
-- NPC_ANIMATOR
-- Version 1.0.0
-- Manages Idle / Walk animation state for a client NPC model.
-- Fully decoupled from NpcReplicator — derives speed from its own
-- position delta each frame so no replicator changes are needed.
-->>>>>>>>>>>>

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Shared Animation objects (loaded once, reused across all instances) ──
local Animations = ReplicatedStorage.AnimShared.Npc:WaitForChild("Movement")
local ANIM_IDLE  = Animations:WaitForChild("idle")
local ANIM_WALK  = Animations:WaitForChild("walk")

-- Speed threshold to switch between idle and walk (studs/s)
local WALK_THRESHOLD = 0.5

-- How fast animations blend in/out (seconds)
local FADE_TIME = 0.2

local NpcAnimator = {}
NpcAnimator.__index = NpcAnimator

-->>>>>>>>>>>>
-- Constructor for the animator. 
-- Binds to RenderStepped to monitor model movement speed.
function NpcAnimator.new(model: Model)
	local self = setmetatable({}, NpcAnimator)

	local humanoid = model:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")
	local root     = model:WaitForChild("HumanoidRootPart")

	-- Load tracks onto this model's Animator
	self._trackIdle = animator:LoadAnimation(ANIM_IDLE)
	self._trackWalk = animator:LoadAnimation(ANIM_WALK)
	self._root      = root
	self._prevPos   = root.Position
	self._isWalking = false

	-- priorities
	self._trackIdle.Priority = Enum.AnimationPriority.Core
	self._trackWalk.Priority = Enum.AnimationPriority.Core

	-- Start in idle
	self._trackIdle:Play(FADE_TIME)

	self._connection = RunService.RenderStepped:Connect(function(dt)
		self:_update(dt)
	end)

	return self
end

-->>>>>>>>>>>>
-- Internal update loop. 
-- Calculates speed (studs/s) and triggers animation blends if thresholds are crossed.
function NpcAnimator:_update(dt: number)
	local pos   = self._root.Position
	local speed = (pos - self._prevPos).Magnitude / dt
	self._prevPos = pos

	local shouldWalk = speed > WALK_THRESHOLD

	if shouldWalk == self._isWalking then return end
	self._isWalking = shouldWalk

	if shouldWalk then
		self._trackIdle:Stop(FADE_TIME)
		self._trackWalk:Play(FADE_TIME)
	else
		self._trackWalk:Stop(FADE_TIME)
		self._trackIdle:Play(FADE_TIME)
	end
end

function NpcAnimator:Destroy()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end

	if self._trackIdle then
		self._trackIdle:Stop()
	end
	
	if self._trackWalk then
		self._trackWalk:Stop() 
	end
end

return NpcAnimator