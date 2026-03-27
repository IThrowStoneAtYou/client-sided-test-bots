-->>>>>>>>>>>>
-- NPC_CLIENT (Client) — ready-gated
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")

local localPlayer = Players.LocalPlayer
local camera      = workspace.CurrentCamera

local NpcReplicator = require(ReplicatedStorage.Modules:WaitForChild("NPC_Replicator_v2"))
local NpcAnimator = require(ReplicatedStorage.Modules:WaitForChild("NpcAnimator"))
local RegimentFormation = require(ReplicatedStorage.Modules:WaitForChild("RegimentFormation"))

local CLIENT_MODEL  = ReplicatedStorage:WaitForChild("CLIENT")

local Remotes      = ReplicatedStorage:WaitForChild("NpcRemotes")
local EvtSpawned   = Remotes:WaitForChild("NpcSpawned")
local EvtDespawned = Remotes:WaitForChild("NpcDespawned")
local EvtBatch     = Remotes:WaitForChild("NpcBatch")
local EvtReady     = Remotes:WaitForChild("NpcReady")
local EvtOrder    = Remotes:WaitForChild("NpcOrder")

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
local function makePart(color: Color3, size: Vector3)
	local p = Instance.new("Part")
	p.Anchored     = true
	p.CanCollide   = false
	p.CastShadow   = false
	p.Material     = Enum.Material.Neon
	p.Color        = color
	p.Size         = size
	p.Transparency = 1
	p.Parent       = workspace
	return p
end

-- Arrow at centre-front showing facing direction
local previewArrow = makePart(Color3.fromRGB(255, 255, 255), Vector3.new(0.4, 0.4, 4))

-- Pool of slot dots — grown on demand, never shrunk (Parts are cheap hidden)
local slotDots  = {}
local activeDots = 0

local DOT_SIZE  = Vector3.new(1.2, 0.3, 1.2)
local DOT_COLOR = Color3.fromRGB(255, 215, 60)

local function ensurePool(needed: number)
	while #slotDots < needed do
		slotDots[#slotDots + 1] = makePart(DOT_COLOR, DOT_SIZE)
	end
end

local function showDots(slots: {CFrame})
	ensurePool(#slots)
	for i, slotCF in ipairs(slots) do
		slotDots[i].CFrame       = slotCF
		slotDots[i].Transparency = 0.3
	end
	-- Hide any extras from a previous larger formation
	for i = #slots + 1, activeDots do
		slotDots[i].Transparency = 1
	end
	activeDots = #slots
end

local function setArrow(centre: Vector3, facing: Vector3, depth: number)
	local arrowLen = math.clamp(depth * 0.3, 2, 6)
	previewArrow.Size   = Vector3.new(0.4, 0.4, arrowLen)
	previewArrow.CFrame = CFrame.lookAt(
		centre + facing * (arrowLen / 2 + 0.5),
		centre + facing * (arrowLen / 2 + 0.5) + facing
	)
	previewArrow.Transparency = 0
end

local function hidePreview()
	for i = 1, activeDots do
		slotDots[i].Transparency = 1
	end
	activeDots = 0
	previewArrow.Transparency = 1
end

-- ── Shared slot computation ───────────────────────────────────────────
-- Returns slots + rankCentre given left-anchor, dragDir, count
local function computeSlots(leftAnchor: Vector3, dragDirection: Vector3, count: number)
	local ranks, files = RegimentFormation.dragToLayout(count, 0)
	-- will be overridden by caller with real mag, this is just a safe default
	return ranks, files
end

local function buildSlots(leftAnchor: Vector3, dir: Vector3, count: number, mag: number)
	local ranks, files = RegimentFormation.dragToLayout(count, mag)
	local width, depth = RegimentFormation.getPreviewSize(ranks, files)

	local facing     = Vector3.new(dir.Z, 0, -dir.X)
	local rankCentre = leftAnchor + dir * (width / 2)
	local anchorCF   = CFrame.lookAt(rankCentre, rankCentre + facing)
	local slots      = RegimentFormation.getSlots(anchorCF, count, ranks, files)

	return slots, rankCentre, facing, ranks, files, width, depth
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

    dragDir = delta.Unit

    local count = getCount()
    if count < 1 then return end

    local slots, rankCentre, facing, ranks, files, _, depth =
        buildSlots(anchorPos, dragDir, count, mag)

    dragRanks = ranks
    dragFiles = files

    showDots(slots)
    setArrow(rankCentre, facing, depth)
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
        local _, rankCentre, facing, ranks, files =
            buildSlots(anchorPos, dragDir, count,
                (raycastMouse() and (raycastMouse() - anchorPos) or Vector3.zero).Magnitude)

        -- Use the values computed during last InputChanged (dragRanks/dragFiles)
        -- since raycastMouse() on InputEnded is the same frame as the last move
        local width, _ = RegimentFormation.getPreviewSize(dragRanks, dragFiles)
        local facingFinal = Vector3.new(dragDir.Z, 0, -dragDir.X)
        rankCentre = anchorPos + dragDir * (width / 2)

        lastRanks = dragRanks
        lastFiles = dragFiles

        EvtOrder:FireServer(rankCentre, facingFinal, dragRanks, dragFiles)
    else
        -- Plain click — click point is centre, reuse last layout
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

