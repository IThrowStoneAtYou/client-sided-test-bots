-->>>>>>>>>>>>
-- REGIMENT_FORMATION
-- Pure math module. No services, no state.
-- Returns an array of CFrames (one per soldier slot) given an
-- anchor CFrame, soldier count, and formation type.
-->>>>>>>>>>>>

local RegimentFormation = {}

local RANK_SPACING = 4.5   -- studs between soldiers side by side
local RANK_DEPTH   = 5     -- studs between ranks front to back
local MAX_FILES    = 20    -- soldiers per rank before a new rank is added

-->>>>>>>>>>>>
-- Returns { CFrame, ... } for each slot.
-- anchorCF: world CFrame — position is the centre of the front rank,
--           LookVector is the direction soldiers face.
function RegimentFormation.getSlots(anchorCF: CFrame, count: number, formation: string): {CFrame}
	formation = formation or "Line"

	if formation == "Line" then
		return RegimentFormation._line(anchorCF, count)
	elseif formation == "Column" then
		return RegimentFormation._column(anchorCF, count)
	end

	-- Default fallback
	return RegimentFormation._line(anchorCF, count)
end

-->>>>>>>>>>>>
-- LINE: wide front, shallow depth. Classic napoleonic firing line.
function RegimentFormation._line(anchorCF: CFrame, count: number): {CFrame}
	local slots = {}

	local files = math.min(count, MAX_FILES)
	local right = anchorCF.RightVector

	-- Face direction as a flat yaw-only CFrame so soldiers don't inherit pitch/roll
	local look  = anchorCF.LookVector
	local yaw   = math.atan2(-look.X, -look.Z)
	local faceCF = CFrame.Angles(0, yaw, 0)

	for i = 1, count do
		local rank = math.floor((i - 1) / files)
		local file = (i - 1) % files

		-- Centre the rank around the anchor
		local offsetRight = (file - (files - 1) / 2) * RANK_SPACING
		-- Ranks go behind the anchor (soldiers in front face forward)
		local offsetBack  = rank * RANK_DEPTH

		local pos = anchorCF.Position
			+ right * offsetRight
			+ (-anchorCF.LookVector) * offsetBack

		slots[i] = CFrame.new(pos) * faceCF
	end

	return slots
end

-->>>>>>>>>>>>
-- COLUMN: narrow files, long depth. Used for marching.
function RegimentFormation._column(anchorCF: CFrame, count: number): {CFrame}
	local slots = {}

	local files = 4
	local right = anchorCF.RightVector

	local look  = anchorCF.LookVector
	local yaw   = math.atan2(-look.X, -look.Z)
	local faceCF = CFrame.Angles(0, yaw, 0)

	for i = 1, count do
		local rank = math.floor((i - 1) / files)
		local file = (i - 1) % files

		local offsetRight = (file - (files - 1) / 2) * RANK_SPACING
		local offsetBack  = rank * RANK_DEPTH

		local pos = anchorCF.Position
			+ right * offsetRight
			+ (-anchorCF.LookVector) * offsetBack

		slots[i] = CFrame.new(pos) * faceCF
	end

	return slots
end

return RegimentFormation