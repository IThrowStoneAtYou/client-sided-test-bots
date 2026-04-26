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
local TweenService     = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")
local RegimentData      = require(ReplicatedStorage.Modules.Shared.RegimentData)
local GameSettings      = require(ReplicatedStorage.Modules.Shared.GameSettings)

local localPlayer = Players.LocalPlayer

-- ── Tooltip UI (Screen Space) ────────────────────────────────────────
-- We create this IMMEDIATELY at the top so it exists even if assets hang.
local tooltipGui = Instance.new("ScreenGui")
tooltipGui.Name = "tooltipGui" 
tooltipGui.Enabled = false
tooltipGui.IgnoreGuiInset = true
tooltipGui.DisplayOrder = 100
tooltipGui.Parent = localPlayer:WaitForChild("PlayerGui")

local tooltipFrame = Instance.new("Frame")
tooltipFrame.Size = UDim2.new(0, 160, 0, 45)
tooltipFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
tooltipFrame.BackgroundTransparency = 0.2
tooltipFrame.AnchorPoint = Vector2.new(1, 0) -- Top-right corner at cursor
tooltipFrame.Parent = tooltipGui

local tooltipStroke = Instance.new("UIStroke")
tooltipStroke.Color = Color3.fromRGB(60, 60, 60)
tooltipStroke.Thickness = 1
tooltipStroke.Parent = tooltipFrame

local tooltipOwner = Instance.new("TextLabel")
tooltipOwner.Size = UDim2.new(1, -10, 0, 20)
tooltipOwner.Position = UDim2.new(0, 5, 0, 5)
tooltipOwner.BackgroundTransparency = 1
tooltipOwner.Font = Enum.Font.GothamBold
tooltipOwner.TextSize = 12
tooltipOwner.TextXAlignment = Enum.TextXAlignment.Right
tooltipOwner.Parent = tooltipFrame

local tooltipStrength = Instance.new("TextLabel")
tooltipStrength.Size = UDim2.new(1, -10, 0, 15)
tooltipStrength.Position = UDim2.new(0, 5, 0, 22)
tooltipStrength.BackgroundTransparency = 1
tooltipStrength.TextColor3 = Color3.new(0.9, 0.9, 0.9)
tooltipStrength.Font = Enum.Font.Gotham
tooltipStrength.TextSize = 11
tooltipStrength.TextXAlignment = Enum.TextXAlignment.Right
tooltipStrength.Parent = tooltipFrame

-- ── Asset paths ───────────────────────────────────────────────────────
local FLAG_FOLDER  = ReplicatedStorage.Shared.Npc.Item:WaitForChild("Flag")
-- Use FindFirstChild or logic that won't hang the entire module if an asset is missing
local FLAG_TEMPLATE = FLAG_FOLDER:FindFirstChild("f_flag")
local FLAG_ANIM_OBJ = FLAG_FOLDER:FindFirstChild("F_Idle")

if not FLAG_TEMPLATE then warn("[FlagController] CRITICAL: f_flag template missing!") end
if not FLAG_ANIM_OBJ then warn("[FlagController] CRITICAL: F_Idle animation missing!") end

local BAR_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

-- ── State ─────────────────────────────────────────────────────────────
local attachedFlags = {}   -- [shortId]          = { model: Model, motor: Motor6D, track: AnimationTrack? }
local droppedFlags  = {}   -- [ownerUserId_compIdx] = Model

local flagUIs = {} -- [ownerUserId_compIdx] = { gui: BillboardGui, fill: Frame, tickets: number, ownerId: number }
local FlagController = {}

local activeHoverKey = nil

-- ── Helpers ───────────────────────────────────────────────────────────

RunService.Heartbeat:Connect(function()
	if not activeHoverKey or not tooltipGui.Enabled then return end
	local data = flagUIs[activeHoverKey]
	
	-- Validation: If the NPC is gone or moves beyond MaxDistance while hovering, hide the tooltip.
	local isStale = not data or not data.gui or not data.gui.Adornee
	if not isStale then
		local cam = workspace.CurrentCamera
		local dist = (data.gui.Adornee.Position - cam.CFrame.Position).Magnitude
		if dist > data.gui.MaxDistance then
			isStale = true
		end
	end

	if isStale then
		activeHoverKey = nil
		tooltipGui.Enabled = false
		return
	end

	local ratio = math.clamp(data.tickets / GameSettings.MAX_TICKETS, 0, 1)
	local player = Players:GetPlayerByUserId(data.ownerId)
	
	tooltipOwner.Text = player and player.Name or "Unknown"
	tooltipOwner.TextColor3 = (player and player.TeamColor) and player.TeamColor.Color or Color3.new(1,1,1)
	tooltipStrength.Text = "Company strength is " .. math.floor(ratio * 100) .. "%"

	-- Positioning it at the bottom-left of the cursor using absolute coordinates
	local mousePos = UserInputService:GetMouseLocation()
	tooltipFrame.Position = UDim2.new(0, mousePos.X - 10, 0, mousePos.Y + 10)
end)

local function makeKey(ownerUserId: number, compIdx: number): string
	return tostring(ownerUserId) .. "_" .. tostring(compIdx)
end

local function getTicketColor(ratio: number): Color3
	if ratio > 0.66 then
		return Color3.fromRGB(0, 120, 220)
	elseif ratio > 0.33 then
		return Color3.fromRGB(255, 140, 0)
	else
		return Color3.fromRGB(200, 50, 50)
	end
end

local function createFlagUI(parentPart: BasePart, ownerUserId: number, compIdx: number)
	local key = makeKey(ownerUserId, compIdx)
	
	local bgui = Instance.new("BillboardGui")
	bgui.Name = "FlagStatusUI"
	bgui.Size = UDim2.new(0, 50, 0, 45)
	bgui.StudsOffset = Vector3.new(0, 47, 0) -- Floats just above the flag
	bgui.AlwaysOnTop = true
	bgui.MaxDistance = 250
	bgui.Active = true
	
	local container = Instance.new("TextButton")
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 0.99 -- Essential for hover detection
	container.Text = ""
	container.Active = true
	container.Parent = bgui

	container.MouseEnter:Connect(function()
		activeHoverKey = key
		tooltipGui.Enabled = true
	end)
	container.MouseLeave:Connect(function()
		if activeHoverKey == key then
			activeHoverKey = nil
			tooltipGui.Enabled = false
		end
	end)

	-- Nation Icon
	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.new(0, 24, 0, 24)
	icon.Position = UDim2.new(0.5, 0, 0.4, 0)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.BackgroundTransparency = 1
	icon.Image = "rbxassetid://13488010851" -- Default
	icon.ZIndex = 2
	icon.Parent = container

	-- Resolve Flag Asset
	local player = game.Players:GetPlayerByUserId(ownerUserId)
	if player then
		local sideIdx = player:GetAttribute("SideIndex")
		local regIdx = player:GetAttribute("RegimentIndex")
		if sideIdx and regIdx then
			local _, nationKey = RegimentData.GetRegimentInfo(sideIdx, regIdx)
			if nationKey then
				for _, nation in ipairs(RegimentData.Sides[sideIdx].nations) do
					if nation.key == nationKey then
						icon.Image = nation.flag
						break
					end
				end
			end
		end
	end

	-- Strength Bar
	local barBg = Instance.new("Frame")
	barBg.Size = UDim2.new(0.8, 0, 0, 4)
	barBg.Position = UDim2.new(0.1, 0, 0.8, 0)
	barBg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	barBg.BackgroundTransparency = 0.4
	barBg.BorderSizePixel = 0
	barBg.Parent = container

	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.new(1, 0, 1, 0)
	barFill.BackgroundColor3 = Color3.fromRGB(0, 120, 220)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg

	bgui.Adornee = parentPart
	bgui.Parent = localPlayer:WaitForChild("PlayerGui")

	flagUIs[key] = {
		gui = bgui,
		fill = barFill,
		tickets = GameSettings.MAX_TICKETS,
		ownerId = ownerUserId
	}
	return bgui
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

	local ownerId = clientModel:GetAttribute("OwnerUserId")
	local compIdx = clientModel:GetAttribute("CompanyIndex")

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

	if handlePart and ownerId and compIdx then
		createFlagUI(handlePart, ownerId, compIdx)
	end

	local track = playFlagAnim(clientModel)
	attachedFlags[shortId] = { model = flagModel, motor = motor, track = track }
end

-->>>>>>>>>>>>
-- Removes the welded flag from the NPC with the given shortId.
function FlagController.detachFromNpc(shortId: number)
	local data = attachedFlags[shortId]
	if not data then return end

	local ownerId = data.model.Parent:GetAttribute("OwnerUserId")
	local compIdx = data.model.Parent:GetAttribute("CompanyIndex")
	if ownerId and compIdx then
		local key = makeKey(ownerId, compIdx)
		if flagUIs[key] then flagUIs[key].gui:Destroy(); flagUIs[key] = nil end
	end

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

	if rootPart then
		createFlagUI(rootPart, ownerUserId, compIdx)
	end

	droppedFlags[key] = flagModel
end

-->>>>>>>>>>>>
-- Updates the bar fill and color based on company health.
function FlagController.updateFlagUI(ownerUserId: number, compIdx: number, tickets: number, isBroken: boolean)
	local key = makeKey(ownerUserId, compIdx)
	local data = flagUIs[key]
	if not data then return end

	local ratio = math.clamp(tickets / GameSettings.MAX_TICKETS, 0, 1)
	local color = isBroken and Color3.fromRGB(200, 50, 50) or getTicketColor(ratio)
	data.tickets = tickets
	data.isBroken = isBroken

	TweenService:Create(data.fill, BAR_TWEEN, {
		Size = UDim2.new(ratio, 0, 1, 0),
		BackgroundColor3 = color
	}):Play()
end

-->>>>>>>>>>>>
-- Removes the anchored dropped-flag model for the given company.
function FlagController.removeDropped(ownerUserId: number, compIdx: number)
	local key   = makeKey(ownerUserId, compIdx)
	local model = droppedFlags[key]
	if model and model.Parent then
		model:Destroy()
	end
	
	if flagUIs[key] then
		flagUIs[key].gui:Destroy()
		flagUIs[key] = nil
	end
	droppedFlags[key] = nil
end

return FlagController
