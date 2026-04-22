-->>>>>>>>>>>>
-- RAGDOLL_UTILS
-- Version 1.0.0
--
-- Applies ragdoll physics to a client NPC model on death.
-- Called from NpcDespawn handler instead of immediately destroying.
-->>>>>>>>>>>>

local RAGDOLL_LIFETIME = 5  -- seconds before the model is destroyed

local RagdollUtils = {}

local function makeAttachment(parent: BasePart, position: Vector3, name: string): Attachment
	local a          = Instance.new("Attachment")
	a.Position       = position
	a.Name           = name
	a.Parent         = parent
	return a
end

local function makeBallSocket(torso: BasePart, a0: Attachment, a1: Attachment, twistLower: number, twistUpper: number)
	local bs                  = Instance.new("BallSocketConstraint")
	bs.Attachment0            = a0
	bs.Attachment1            = a1
	bs.LimitsEnabled          = true
	bs.TwistLimitsEnabled     = true
	bs.TwistLowerAngle        = twistLower
	bs.TwistUpperAngle        = twistUpper
	bs.MaxFrictionTorque      = 10
	bs.Parent                 = torso
end

function RagdollUtils.apply(clientModel: Model)
	local torso    = clientModel:FindFirstChild("Torso")
	local head     = clientModel:FindFirstChild("Head")
	local rightArm = clientModel:FindFirstChild("Right Arm")
	local leftArm  = clientModel:FindFirstChild("Left Arm")
	local rightLeg = clientModel:FindFirstChild("Right Leg")
	local leftLeg  = clientModel:FindFirstChild("Left Leg")
	local hrp      = clientModel:FindFirstChild("HumanoidRootPart")

	if not torso then
		-- fallback: just destroy
		clientModel:Destroy()
		return
	end

	-- ── Attachments on limbs (Attachment1 side) ───────────────────────
	local a_head = makeAttachment(head,     Vector3.new(0,    -0.6, 0), "RD_Head1")
	local a_rArm = makeAttachment(rightArm, Vector3.new(-0.5,  0.5, 0), "RD_RArm1")
	local a_lArm = makeAttachment(leftArm,  Vector3.new( 0.5,  0.5, 0), "RD_LArm1")
	local a_rLeg = makeAttachment(rightLeg, Vector3.new(0,     1,   0), "RD_RLeg1")
	local a_lLeg = makeAttachment(leftLeg,  Vector3.new(0,     1,   0), "RD_LLeg1")

	-- ── Attachments on torso (Attachment0 side) ───────────────────────
	local a_headT = makeAttachment(torso, Vector3.new( 0,    1,   0), "RD_Head0")
	local a_rArmT = makeAttachment(torso, Vector3.new( 1,    0.5, 0), "RD_RArm0")
	local a_lArmT = makeAttachment(torso, Vector3.new(-1,    0.5, 0), "RD_LArm0")
	local a_rLegT = makeAttachment(torso, Vector3.new( 0.5, -1,   0), "RD_RLeg0")
	local a_lLegT = makeAttachment(torso, Vector3.new(-0.5, -1,   0), "RD_LLeg0")

	-- ── BallSocket constraints ────────────────────────────────────────
	makeBallSocket(torso, a_headT, a_head,  -45,  45)
	makeBallSocket(torso, a_rArmT, a_rArm,   45,   0)
	makeBallSocket(torso, a_lArmT, a_lArm,    0,  45)
	makeBallSocket(torso, a_rLegT, a_rLeg,  -45,  45)
	makeBallSocket(torso, a_lLegT, a_lLeg,  -45,  45)

	-- ── Remove Motor6D joints so parts break free ─────────────────────
	for _, child in ipairs(torso:GetChildren()) do
		if child:IsA("Motor6D") then
			child:Destroy()
		end
	end

	-- ── Destroy HRP (kills AlignOrientation + stops BulkMoveTo target) 
	if hrp then
		hrp:Destroy()
	end

	-- ── Unanchor + enable collision on body parts ─────────────────────
	local bodyParts = { torso, head, rightArm, leftArm, rightLeg, leftLeg }
	for _, part in ipairs(bodyParts) do
		if part then
			part.Anchored   = false
			part.CanCollide = true
		end
	end

	-- ── Cleanup after lifetime ────────────────────────────────────────
	task.delay(RAGDOLL_LIFETIME, function()
		if clientModel and clientModel.Parent then
			clientModel:Destroy()
		end
	end)
end

return RagdollUtils