-->>>>>>>>>>>>
-- REGIMENT_FORMATION
-- Version 1.1.0
--
-- Spacing Constants:
--   - RANK_SPACING = 5 studs (left-right between soldiers)
--   - RANK_DEPTH = 5 studs (front-back between rows)
--
-->>>>>>>>>>>>

local RegimentFormation = {}

local RANK_SPACING = 5  -- studs between soldiers side by side
local RANK_DEPTH   = 5    -- studs between ranks front to back

-->>>>>>>>>>>>
-- Converts a drag magnitude (studs) into ranks + files for a given count.
-- Called by both the client (preview) and server (slot generation).
--
-- Algorithm:
--   files = floor(dragMagnitude / RANK_SPACING) + 1, clamped to [1, count]
--   ranks = ceil(count / files)
--
-- Example: count=10, drag=20 studs
--   files = floor(20 / 5) + 1 = 5
--   ranks = ceil(10 / 5) = 2
--   Result: 2 ranks × 5 files = 10 soldiers in an elongated line
--
function RegimentFormation.dragToLayout(count: number, dragMagnitude: number): (number, number)
	-- files derived from width dragged, clamped between 1 and count
	local files = math.floor(dragMagnitude / RANK_SPACING) + 1
	files = math.clamp(files, 1, count)   -- allow 1 (column) through count (flat line)
	
	local ranks = math.ceil(count / files)
	
	return ranks, files
end

-->>>>>>>>>>>>
-- Returns pixel width and depth of a formation for the client preview rect.
-- Used to center arrows and calculate fade dot geometry.
function RegimentFormation.getPreviewSize(ranks: number, files: number): (number, number)
	return (files - 1) * RANK_SPACING, (ranks - 1) * RANK_DEPTH
end

-->>>>>>>>>>>>
-- Returns { CFrame, ... } for each slot in the formation.
--
-- Parameters:
--   anchorCF: CFrame at the centre of the FRONT rank, LookVector = facing direction
--   count: Total number of soldiers
--   ranks: Number of rows (front to back)
--   files: Number of columns (left to right)
--
-- Slot Algorithm:
--   Simple grid layout: soldiers fill left-to-right, front-to-back
--   No clustering, no special modes.
--
-- Example (12 soldiers, files=4):
--   O O O O    (rank 1)
--   O O O O    (rank 2)
--   O O O O    (rank 3)
--
function RegimentFormation.getSlots(anchorCF: CFrame, count: number, ranks: number, files: number): {CFrame}
	local slots  = {}
	local right  = anchorCF.RightVector
	local look   = anchorCF.LookVector
	local yaw    = math.atan2(-look.X, -look.Z)
	local faceCF = CFrame.Angles(0, yaw, 0)

	-- Standard grid layout: all formations use simple grid positioning
	for i = 1, count do
		local rank = math.floor((i - 1) / files)
		local file = (i - 1) % files

		local offsetRight = (file - (files - 1) / 2) * RANK_SPACING
		local offsetBack = rank * RANK_DEPTH

		local pos = anchorCF.Position + right * offsetRight + (-look) * offsetBack
		slots[i] = CFrame.new(pos) * faceCF
	end

	return slots
end

RegimentFormation.RANK_SPACING = RANK_SPACING
RegimentFormation.RANK_DEPTH   = RANK_DEPTH

return RegimentFormation