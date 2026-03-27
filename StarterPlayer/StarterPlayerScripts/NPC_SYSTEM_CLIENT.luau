-->>>>>>>>>>>>
-- NPC_CLIENT (Client) — ready-gated
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NpcReplicator = require(ReplicatedStorage.Modules:WaitForChild("NPC_Replicator_v2"))
local NpcAnimator = require(ReplicatedStorage.Modules:WaitForChild("NpcAnimator"))
local RegimentFormation = require(ReplicatedStorage.Modules:WaitForChild("RegimentFormation"))


local CLIENT_MODEL  = ReplicatedStorage:WaitForChild("CLIENT")

local Remotes      = ReplicatedStorage:WaitForChild("NpcRemotes")
local EvtSpawned   = Remotes:WaitForChild("NpcSpawned")
local EvtDespawned = Remotes:WaitForChild("NpcDespawned")
local EvtBatch     = Remotes:WaitForChild("NpcBatch")
local EvtReady     = Remotes:WaitForChild("NpcReady")

if not workspace:FindFirstChild("Npc_Registry") then
	local folder  = Instance.new("Folder")
	folder.Name   = "Npc_Registry"
	folder.Parent = workspace
end

local replicators = {}

local animators = {}  -- [shortId] = NpcAnimator

local myRegimentCount = 0

local function buildCFrame(pos, yaw)
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

local function registerNpc(shortId, pos, yaw)
	if replicators[shortId] then return end

	local clientModel    = CLIENT_MODEL:Clone()
	local rep            = NpcReplicator.new(shortId, clientModel)
	rep.Root.CFrame      = buildCFrame(pos, yaw)
	
	rep:Start()
	replicators[shortId] = rep

	-- Animator created after rep so the model is already parented to Npc_Registry
	animators[shortId]     = NpcAnimator.new(clientModel)
	myRegimentCount        += 1
end

-- ── Wire all handlers FIRST, then signal ready ────────────────────────

EvtSpawned.OnClientEvent:Connect(function(idOrBatch, pos, yaw)
	if type(idOrBatch) == "number" then
		registerNpc(idOrBatch, pos, yaw)
	else
		for _, entry in ipairs(idOrBatch) do
			registerNpc(entry[1], entry[2], entry[3])
		end
	end
end)

-- velocity is no longer sent; replicator derives it internally
EvtBatch.OnClientEvent:Connect(function(timestamp, chunk)
	for _, entry in ipairs(chunk) do
		local rep = replicators[entry[1]]
		if rep then
			rep:PushNetworkSnapshot(buildCFrame(entry[2], entry[3]), timestamp)
		end
	end
end)

-- EvtDespawned — also destroy the animator
EvtDespawned.OnClientEvent:Connect(function(shortId)
	local rep = replicators[shortId]
	if not rep then return end
	if rep.Client then rep.Client:Destroy() end
	rep:Destroy()
	replicators[shortId] = nil

	local anim = animators[shortId]
	if anim then
		anim:Destroy()
		animators[shortId] = nil
	end
end)


local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")

local EvtOrder    = Remotes:WaitForChild("NpcOrder")
local localPlayer = Players.LocalPlayer
local camera      = workspace.CurrentCamera

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function updateRayFilter()
	rayParams.FilterDescendantsInstances = {
		workspace:WaitForChild("Npc_Registry"),
		localPlayer.Character,
	}
end
updateRayFilter()
localPlayer.CharacterAdded:Connect(updateRayFilter)

-- ── Preview parts ─────────────────────────────────────────────────────
local function makePart(color: Color3, transparency: number)
	local p = Instance.new("Part")
	p.Anchored      = true
	p.CanCollide    = false
	p.CastShadow    = false
	p.Material      = Enum.Material.Neon
	p.Color         = color
	p.Transparency  = transparency
	p.Parent        = workspace
	return p
end

-- Front rank line (gold, solid)
local previewFront = makePart(Color3.fromRGB(255, 215, 60), 1)
-- Formation body rectangle (gold, semi-transparent)
local previewBody  = makePart(Color3.fromRGB(255, 215, 60), 1)
-- Facing arrow nub (white)
local previewArrow = makePart(Color3.fromRGB(255, 255, 255), 1)

local function setPreview(anchor: Vector3, facing: Vector3, width: number, depth: number)
	-- Front rank line: runs perpendicular to facing, centred on anchor
	previewFront.Size  = Vector3.new(0.3, 0.3, width)
	previewFront.CFrame = CFrame.lookAt(anchor, anchor + facing)
		* CFrame.Angles(0, math.pi / 2, 0)

	-- Body rect: centred halfway back into the depth, same orientation
	local bodyCenter = anchor + (-facing) * (depth / 2)
	previewBody.Size  = Vector3.new(depth, 0.15, width)
	previewBody.CFrame = CFrame.lookAt(bodyCenter, bodyCenter + facing)
		* CFrame.Angles(0, math.pi / 2, 0)

	-- Facing arrow: short nub sticking forward from anchor
	previewArrow.Size  = Vector3.new(0.4, 0.4, math.min(4, depth * 0.3 + 1))
	previewArrow.CFrame = CFrame.lookAt(
		anchor + facing * 2,
		anchor + facing * 2 + facing
	)

	previewFront.Transparency = 0
	previewBody.Transparency  = 0.6
	previewArrow.Transparency = 0
end

local function hidePreview()
	previewFront.Transparency = 1
	previewBody.Transparency  = 1
	previewArrow.Transparency = 1
end

-- ── Raycast helper ────────────────────────────────────────────────────
local function raycastMouse(): Vector3?
	local pos    = UserInputService:GetMouseLocation()
	local ray    = camera:ViewportPointToRay(pos.X, pos.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000, rayParams)
	return result and result.Position or nil
end

-- ── Drag state ────────────────────────────────────────────────────────
local DRAG_THRESHOLD = 3   -- studs before drag starts registering

local dragActive = false
local anchorPos  = nil
local facingDir  = nil
local dragRanks  = 1
local dragFiles  = 1

-- [FIX 1] Persist ranks/files across plain clicks
local lastRanks  = 1
local lastFiles  = 1

local function getCount(): number
	return myRegimentCount  -- tracked earlier in registerNpc
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

	local hit = raycastMouse()
	if not hit then return end

	dragActive = true
	anchorPos  = hit
	dragDir    = nil
	-- Start from last known layout until drag overrides it
	dragRanks  = lastRanks
	dragFiles  = lastFiles
end)

UserInputService.InputChanged:Connect(function(input)
	if not dragActive then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	if not anchorPos then return end

	local hit = raycastMouse()
	if not hit then return end

	local delta = Vector3.new(hit.X - anchorPos.X, 0, hit.Z - anchorPos.Z)
	local mag   = delta.Magnitude
	if mag < DRAG_THRESHOLD then return end

	-- [FIX 2] Drag direction = right edge direction (the front rank line)
	dragDir = delta.Unit

	-- Facing = 90° clockwise from dragDir (soldiers face perpendicular to rank line)
	-- If you drag right (+X), soldiers face forward (-Z)
	local facingDir = Vector3.new(dragDir.Z, 0, -dragDir.X)

	local count = getCount()
	if count > 0 then
		-- Width comes from drag magnitude
		dragRanks, dragFiles = RegimentFormation.dragToLayout(count, mag)
		local width, depth   = RegimentFormation.getPreviewSize(dragRanks, dragFiles)

		-- [FIX 2] Preview is left-anchored not centred
		-- Centre of front rank = anchorPos shifted right by half width
		local rankCentre = anchorPos + dragDir * (width / 2)
		setPreview(rankCentre, facingDir, width, depth)
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if not dragActive then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

	dragActive = false
	hidePreview()

	if not anchorPos then return end

	local count = getCount()
	if count == 0 then
		anchorPos = nil
		dragDir   = nil
		return
	end

	if dragDir then
		-- Drag occurred — derive facing from drag direction, update persisted layout
		local facingDir  = Vector3.new(dragDir.Z, 0, -dragDir.X)
		local width, _   = RegimentFormation.getPreviewSize(dragRanks, dragFiles)
		local rankCentre = anchorPos + dragDir * (width / 2)

		-- [FIX 1] Persist for next plain click
		lastRanks = dragRanks
		lastFiles = dragFiles

		EvtOrder:FireServer(rankCentre, facingDir, dragRanks, dragFiles)
	else
		-- [FIX 1] Plain click — reuse last ranks/files, face camera direction
		local look      = camera.CFrame.LookVector
		local facingDir = Vector3.new(look.X, 0, look.Z)
		facingDir       = facingDir.Magnitude > 0.01 and facingDir.Unit or Vector3.new(0, 0, -1)

		EvtOrder:FireServer(anchorPos, facingDir, lastRanks, lastFiles)
	end

	anchorPos = nil
	dragDir   = nil
end)

-- Signal the server only after all handlers above are connected.
-- This is what eliminates the "did you forget OnClientEvent?" drop warning.
EvtReady:FireServer()

