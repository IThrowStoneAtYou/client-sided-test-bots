-->>>>>>>>>>>>
-- REGIMENT_FORMATION
-- Pure math module. No services, no state.
-->>>>>>>>>>>>

local RegimentFormation = {}

local RANK_SPACING = 4.5  -- studs between soldiers side by side
local RANK_DEPTH   = 5    -- studs between ranks front to back
--local MAX_FILES    = 24   -- hard cap — prevents single-file 100-man columns
local MIN_FILES    = 1

-->>>>>>>>>>>>
-- Converts a drag magnitude (studs) into ranks + files for a given count.
-- Called by both the client (preview) and server (slot generation).
function RegimentFormation.dragToLayout(count: number, dragMagnitude: number): (number, number)
	-- files derived from width dragged, clamped between 1 and count
	local files = math.max(1, math.round(dragMagnitude / RANK_SPACING))
	files = math.clamp(files, 1, count)   -- count = fully flat single rank
	local ranks = math.ceil(count / files)
	return ranks, files
end

-->>>>>>>>>>>>
-- Returns pixel width and depth of a formation for the client preview rect.
function RegimentFormation.getPreviewSize(ranks: number, files: number): (number, number)
	return files * RANK_SPACING, ranks * RANK_DEPTH
end

-->>>>>>>>>>>>
-- Returns { CFrame, ... } for each slot.
-- anchorCF: centre of the FRONT rank, LookVector = facing direction.
-- ranks / files: from dragToLayout.
function RegimentFormation.getSlots(anchorCF: CFrame, count: number, ranks: number, files: number): {CFrame}
	local slots  = {}
	local right  = anchorCF.RightVector
	local look   = anchorCF.LookVector
	local yaw    = math.atan2(-look.X, -look.Z)
	local faceCF = CFrame.Angles(0, yaw, 0)

	for i = 1, count do
		local rank = math.floor((i - 1) / files)
		local file = (i - 1) % files

		local offsetRight = (file - (files - 1) / 2) * RANK_SPACING
		local offsetBack  = rank * RANK_DEPTH

		local pos = anchorCF.Position
			+ right  * offsetRight
			+ (-look) * offsetBack

		slots[i] = CFrame.new(pos) * faceCF
	end

	return slots
end

return RegimentFormation