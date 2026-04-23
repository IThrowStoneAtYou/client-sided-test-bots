-->>>>>>>>>>>>
-- FLAG_CONTROLLER
-- Version 1.0.0
--
-- Manages all client-side flag visuals:
--   • Attaches f_flag model to bearer NPCs (friendly OR enemy carrier)
--   • Shows an anchored dropped-flag model in the world when the flag falls
--   • Plays the F_Idle wave animation on the held flag model
--   • Removes visuals on pickup / capture
--
-- API
--   FlagController.attachToNpc(clientModel)
--     → weld f_flag to the NPC's torso and play F_Idle
--   FlagController.detachFromNpc(shortId)
--     → destroy the welded model
--   FlagController.spawnDropped(ownerUserId, compIdx, position) 
--     → anchor a copy of f_flag at the given world position
--   FlagController.removeDropped(ownerUserId, compIdx)
--     → remove the anchored model
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Asset paths ───────────────────────────────────────────────────────
local FLAG_FOLDER  = ReplicatedStorage.Shared.Npc.Item:WaitForChild("Flag")
local FLAG_TEMPLATE = FLAG_FOLDER:WaitForChild("f_flag")
local FLAG_ANIM_OBJ = FLAG_FOLDER:WaitForChild("F_Idle")

-- ── Constants ─────────────────────────────────────────────────────────
local HOLD_OFFSET = CFrame.new(0.6, 1.2, 0)

-- ── State ─────────────────────────────────────────────────────────────
local attachedFlags = {}   -- [shortId]          = { model: Model, motor: Motor6D, track: AnimationTrack? }
local droppedFlags  = {}   -- [ownerUserId_compIdx] = Model

local FlagController = {}

-- ── Helpers ───────────────────────────────────────────────────────────

local function makeKey(ownerUserId: number, compIdx: number): string
	return tostring(ownerUserId) .. "_" .. tostring(compIdx)
end

local function disableCollision(model: Model)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.CanCollide = false
			p.CanTouch   = false
			p.CanQuery   = false
		end
	end
end

local function playFlagAnim(model: Model)
	-- Mirroring MusketUtils: Find Humanoid/Controller and its Animator
	local container = model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildOfClass("AnimationController")
	local animator = container and container:FindFirstChildOfClass("Animator")

	if not animator then return nil end

	local ok, track = pcall(function()
		return animator:LoadAnimation(FLAG_ANIM_OBJ)
	end)
	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = true
		track:Play()
		return track
	end
	return nil
end

-- ── Public API ────────────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Welds a copy of f_flag to the given client NPC model (by Torso attachment).
-- shortId is used to key the attachment so it can be removed later.
function FlagController.attachToNpc(clientModel: Model)
	local shortId = tonumber(clientModel.Name:sub(5))
	if not shortId then return end

	-- Remove any existing flag on this NPC first.
	FlagController.detachFromNpc(shortId)

	local torso = clientModel:FindFirstChild("Torso")
	if not torso then return end

	local flagModel = FLAG_TEMPLATE:Clone()
	flagModel.Name  = "HeldFlag"

	-- Determine the primary attachment part (Prefer 'Handle' as requested).
	local handlePart = flagModel:FindFirstChild("Handle") or flagModel.PrimaryPart or flagModel:FindFirstChildOfClass("BasePart")
	if not handlePart then
		flagModel:Destroy()
		return
	end

	-- Anchor temporarily so we can weld/motorize properly without physics fighting us.
	for _, p in ipairs(flagModel:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
		end
	end

	flagModel.Parent = clientModel

	local motor       = Instance.new("Motor6D")
	motor.Name        = "FlagGrip"
	motor.Part0       = torso
	motor.Part1       = handlePart
	motor.C0          = CFrame.new()
	motor.C1          = CFrame.new()
	motor.Parent      = torso

	-- Unanchor so the weld can move it.
	for _, p in ipairs(flagModel:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
		end
	end
	disableCollision(flagModel)

	local track = playFlagAnim(clientModel)
	attachedFlags[shortId] = { model = flagModel, motor = motor, track = track }
end

-->>>>>>>>>>>>
-- Removes the welded flag from the NPC with the given shortId.
function FlagController.detachFromNpc(shortId: number)
	local data = attachedFlags[shortId]
	if not data then return end

	if data.track then
		pcall(function() data.track:Stop() end)
	end
	if data.motor and data.motor.Parent then
		data.motor:Destroy()
	end
	if data.model and data.model.Parent then
		data.model:Destroy()
	end

	attachedFlags[shortId] = nil
end

-->>>>>>>>>>>>
-- Spawns an anchored dropped-flag model at the given world position.
-- Uses a raycast (already done on server) result sent via FlagDropped.
function FlagController.spawnDropped(ownerUserId: number, compIdx: number, position: Vector3)
	local key = makeKey(ownerUserId, compIdx)

	-- Remove any stale model for this flag slot.
	FlagController.removeDropped(ownerUserId, compIdx)

	local flagModel = FLAG_TEMPLATE:Clone()
	flagModel.Name  = "DroppedFlag_" .. key

	-- Anchor every part; flag lies on the ground.
	for _, p in ipairs(flagModel:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
		end
	end
	disableCollision(flagModel)

	-- Tilt the flag slightly as if it's stuck in the ground.
	-- The flag pole stands upright; rotate if needed based on model orientation.
	local rootPart = flagModel.PrimaryPart or flagModel:FindFirstChildOfClass("BasePart")
	if rootPart then
		flagModel:PivotTo(CFrame.new(position))
	end

	flagModel.Parent = workspace

	-- Play idle wave even on the dropped model.
	playFlagAnim(flagModel)

	droppedFlags[key] = flagModel
end

-->>>>>>>>>>>>
-- Removes the anchored dropped-flag model for the given company.
function FlagController.removeDropped(ownerUserId: number, compIdx: number)
	local key   = makeKey(ownerUserId, compIdx)
	local model = droppedFlags[key]
	if model and model.Parent then
		model:Destroy()
	end
	droppedFlags[key] = nil
end

return FlagController
