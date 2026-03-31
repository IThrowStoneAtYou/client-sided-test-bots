-->>>>>>>>>>>>
-- NPC_ANIMATOR
-- Version 1.1.0
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Shared Animation objects (loaded once, reused across all instances) ──
local Animations = ReplicatedStorage.AnimShared.Npc:WaitForChild("Movement")
local ANIM_IDLE  = Animations:WaitForChild("idle")
local ANIM_WALK  = Animations:WaitForChild("walk")

-- How fast animations blend in/out (seconds)
local FADE_TIME = 0.2

local NpcAnimator = {}
NpcAnimator.__index = NpcAnimator

-->>>>>>>>>>>>
-- Constructor for the animator. Starts in Idle state.
function NpcAnimator.new(model: Model)
	local self = setmetatable({}, NpcAnimator)

	-- Use direct access since the model is cloned from a known template
	local humanoid = model.Humanoid
	local animator = humanoid.Animator
	local root     = model.HumanoidRootPart

	-- Load tracks onto this model's Animator
	self._trackIdle = animator:LoadAnimation(ANIM_IDLE)
	self._trackWalk = animator:LoadAnimation(ANIM_WALK)
	self._isWalking = false

	-- priorities
	self._trackIdle.Priority = Enum.AnimationPriority.Core
	self._trackWalk.Priority = Enum.AnimationPriority.Core

	-- Start in idle
	self._trackIdle:Play(FADE_TIME)

	return self
end

-->>>>>>>>>>>>
-- Updates the animation state based on a boolean.
function NpcAnimator:SetWalking(isWalking: boolean)
	if self._isWalking == isWalking then return end
	self._isWalking = isWalking

	if isWalking then
		self._trackIdle:Stop(FADE_TIME)
		self._trackWalk:Play(FADE_TIME)
	else
		self._trackWalk:Stop(FADE_TIME)
		self._trackIdle:Play(FADE_TIME)
	end
end

function NpcAnimator:Destroy()
	if self._trackIdle then
		self._trackIdle:Stop()
	end

	if self._trackWalk then
		self._trackWalk:Stop() 
	end
end

return NpcAnimator