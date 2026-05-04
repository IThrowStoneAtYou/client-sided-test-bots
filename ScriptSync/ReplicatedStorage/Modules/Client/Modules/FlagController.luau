-->>>>>>>>>>>>
-- FLAG_CONTROLLER
-- Version 1.1.0
--
-- Changes from 1.0:
--   • Hover detection now uses WorldToScreenPoint (matches GetMouseLocation coords)
--     instead of WorldToViewportPoint, fixing tooltips that would sometimes not
--     appear when the billboard sits behind geometry or near screen edges.
--   • Hit-test uses fixed pixel half-sizes (matching BillboardGui 50×45 px)
--     plus an 8-px padding ring instead of the unreliable AbsoluteSize property.
--   • lastKnownTickets / lastKnownBroken tables persist the bar state across
--     flag hand-offs so the strength bar doesn't reset to full on every re-attach.
--   • Removed stray debug print.
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
local tooltipGui = Instance.new("ScreenGui")
tooltipGui.Name = "tooltipGui"
tooltipGui.ResetOnSpawn = false
tooltipGui.Enabled = false
tooltipGui.IgnoreGuiInset = true
tooltipGui.DisplayOrder = 100
tooltipGui.Parent = localPlayer:WaitForChild("PlayerGui")

local tooltipFrame = Instance.new("Frame")
tooltipFrame.Size = UDim2.new(0, 160, 0, 45)
tooltipFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
tooltipFrame.BackgroundTransparency = 0.2
tooltipFrame.AnchorPoint = Vector2.new(0, 0)   -- anchor top-left; position right of cursor
tooltipFrame.Parent = tooltipGui

local tooltipStroke = Instance.new("UIStroke")
tooltipStroke.Color = Color3.fromRGB(60, 60, 60)
tooltipStroke.Thickness = 1
tooltipStroke.Parent = tooltipFrame

local tooltipOwner = Instance.new("TextLabel")
tooltipOwner.Size = UDim2.new(1, -10, 0, 20)
tooltipOwner.Position = UDim2.new(0, 5, 0, 5)
tooltipOwner.BackgroundTransparency = 1
tooltipOwner.TextColor3 = Color3.new(1, 1, 1)
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

-- ── Hover hit-test constants ──────────────────────────────────────────
-- BillboardGui is UDim2.new(0, 50, 0, 45) → half sizes are 25 and 22.
-- Extra padding makes it easier to hover small flags.
local HOVER_HALF_W = 25 + 8   -- 33 px
local HOVER_HALF_H = 22 + 8   -- 30 px

-- ── Asset paths ───────────────────────────────────────────────────────
local FLAG_FOLDER  = ReplicatedStorage.Shared.Npc.Item:WaitForChild("Flag")
local FLAG_TEMPLATE = FLAG_FOLDER:FindFirstChild("f_flag")
local FLAG_ANIM_OBJ = FLAG_FOLDER:FindFirstChild("F_Idle")

if not FLAG_TEMPLATE then warn("[FlagController] CRITICAL: f_flag template missing!") end
if not FLAG_ANIM_OBJ then warn("[FlagController] CRITICAL: F_Idle animation missing!") end

local BAR_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

-- ── State ─────────────────────────────────────────────────────────────
local attachedFlags = {}   -- [shortId] = { model, motor, track }
local droppedFlags  = {}   -- [key]     = Model
local flagUIs       = {}   -- [key]     = { gui, fill, tickets, ownerId, isBroken }

-- Persist bar state across flag hand-offs (carrier dies → new carrier).
-- Without this, the bar always starts at 100% after re-attach.
local lastKnownTickets: { [string]: number }  = {}
local lastKnownBroken:  { [string]: boolean } = {}

local FlagController = {}

local activeHoverKey = nil

-- ── Helpers ───────────────────────────────────────────────────────────

-- Heartbeat hover: use WorldToScreenPoint so coordinates match GetMouseLocation.
RunService.Heartbeat:Connect(function()
	local cam      = workspace.CurrentCamera
	local mousePos = UserInputService:GetMouseLocation()
	local newKey: string? = nil

	for key, data in pairs(flagUIs) do
		local ok, adornee = pcall(function() return data.gui and data.gui.Adornee end)
		if not ok or not adornee then continue end

		-- Project billboard center to screen space.
		-- StudsOffset is world-space so add it to the adornee world position.
		local worldPos  = adornee.Position + data.gui.StudsOffset
		-- WorldToScreenPoint accounts for the GUI inset, matching GetMouseLocation.
		local screenPos, onScreen = cam:WorldToScreenPoint(worldPos)
		if not onScreen or screenPos.Z <= 0 then continue end

		if math.abs(mousePos.X - screenPos.X) <= HOVER_HALF_W
			and math.abs(mousePos.Y - screenPos.Y) <= HOVER_HALF_H then
			newKey = key
			break
		end
	end

	if newKey ~= activeHoverKey then
		activeHoverKey = newKey
		tooltipGui.Enabled = (newKey ~= nil)
	end

	if not activeHoverKey then return end

	local data = flagUIs[activeHoverKey]
	if not data then return end

	local ok, adornee = pcall(function() return data.gui and data.gui.Adornee end)
	if not ok or not adornee then
		activeHoverKey = nil
		tooltipGui.Enabled = false
		return
	end

	-- Update tooltip content
	local ratio  = math.clamp(data.tickets / GameSettings.MAX_TICKETS, 0, 1)
	local player = Players:GetPlayerByUserId(data.ownerId)

	tooltipOwner.Text       = player and player.Name or "Unknown"
	tooltipOwner.TextColor3 = (player and player.TeamColor)
		and player.TeamColor.Color
		or Color3.new(1, 1, 1)
	tooltipStrength.Text    = "Company strength: " .. math.floor(ratio * 100) .. "%"

	-- Position tooltip to the right of and slightly below the cursor
	tooltipFrame.Position = UDim2.new(0, mousePos.X + 16, 0, mousePos.Y + 10)
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
	bgui.Name        = "FlagStatusUI"
	bgui.Size        = UDim2.new(0, 50, 0, 45)
	bgui.StudsOffset = Vector3.new(0, 47, 0)
	bgui.AlwaysOnTop = true
	bgui.MaxDistance = 250
	bgui.Active      = true

	local container = Instance.new("TextButton")
	container.Size                 = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 0.99
	container.Text   = ""
	container.Active = true
	container.Parent = bgui

	-- Nation Icon
	local icon = Instance.new("ImageLabel")
	icon.Name                = "NationIcon"
	icon.Size                = UDim2.new(0, 24, 0, 24)
	icon.Position            = UDim2.new(0.5, 0, 0.4, 0)
	icon.AnchorPoint         = Vector2.new(0.5, 0.5)
	icon.BackgroundTransparency = 1
	icon.Image               = "rbxassetid://13488010851"
	icon.ZIndex              = 2
	icon.Parent              = container

	local function updateFlagIcon()
		local p = game.Players:GetPlayerByUserId(ownerUserId)
		if not p then return end
		local sideIdx = p:GetAttribute("SideIndex")
		local regIdx  = p:GetAttribute("RegimentIndex")
		if sideIdx and regIdx and sideIdx > 0 then
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

	updateFlagIcon()

	local ownerPlayer = game.Players:GetPlayerByUserId(ownerUserId)
	if ownerPlayer then
		ownerPlayer:GetAttributeChangedSignal("SideIndex"):Connect(updateFlagIcon)
		ownerPlayer:GetAttributeChangedSignal("RegimentIndex"):Connect(updateFlagIcon)
	end

	-- Strength Bar
	local barBg = Instance.new("Frame")
	barBg.Size                = UDim2.new(0.8, 0, 0, 4)
	barBg.Position            = UDim2.new(0.1, 0, 0.8, 0)
	barBg.BackgroundColor3    = Color3.fromRGB(0, 0, 0)
	barBg.BackgroundTransparency = 0.4
	barBg.BorderSizePixel     = 0
	barBg.Parent              = container

	local barFill = Instance.new("Frame")
	barFill.Name               = "Fill"
	barFill.Size               = UDim2.new(1, 0, 1, 0)
	barFill.BackgroundColor3   = Color3.fromRGB(0, 120, 220)
	barFill.BorderSizePixel    = 0
	barFill.Parent             = barBg

	-- ── Restore last known bar state so the bar doesn't flicker to 100% ──
	local initTickets = lastKnownTickets[key] or GameSettings.MAX_TICKETS
	local initBroken  = lastKnownBroken[key]  or false
	local initRatio   = math.clamp(initTickets / GameSettings.MAX_TICKETS, 0, 1)
	barFill.Size             = UDim2.new(initRatio, 0, 1, 0)
	barFill.BackgroundColor3 = initBroken and Color3.fromRGB(200, 50, 50) or getTicketColor(initRatio)

	bgui.Adornee = parentPart
	if parentPart:IsA("BasePart") then
		bgui.Parent = parentPart
	else
		bgui.Parent = localPlayer:WaitForChild("PlayerGui")
	end

	flagUIs[key] = {
		gui      = bgui,
		fill     = barFill,
		tickets  = initTickets,
		ownerId  = ownerUserId,
		isBroken = initBroken,
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
	local container = model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildOfClass("AnimationController")
	local animator  = container and container:FindFirstChildOfClass("Animator")
	if not animator then return nil end

	local ok, track = pcall(function()
		return animator:LoadAnimation(FLAG_ANIM_OBJ)
	end)
	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track.Looped   = true
		track:Play()
		return track
	end
	return nil
end

-- ── Public API ────────────────────────────────────────────────────────

function FlagController.attachToNpc(clientModel: Model, flagOwnerId: number?, flagCompIdx: number?)
	local shortId = tonumber(clientModel.Name:sub(5))
	if not shortId then return end

	-- Use explicit owner params when provided (enemy carrying friendly flag).
	-- Fall back to the model's own attributes (bearer holding their own flag).
	local ownerId = flagOwnerId or clientModel:GetAttribute("OwnerUserId")
	local compIdx = flagCompIdx or clientModel:GetAttribute("CompanyIndex")

	FlagController.detachFromNpc(shortId)

	local torso = clientModel:FindFirstChild("Torso")
	if not torso then return end

	local flagModel = FLAG_TEMPLATE:Clone()
	flagModel.Name  = "HeldFlag"

	local handlePart = flagModel:FindFirstChild("Handle") or flagModel.PrimaryPart or flagModel:FindFirstChildOfClass("BasePart")
	if not handlePart then flagModel:Destroy(); return end

	for _, p in ipairs(flagModel:GetDescendants()) do
		if p:IsA("BasePart") then p.Anchored = true end
	end

	flagModel.Parent = clientModel

	local motor    = Instance.new("Motor6D")
	motor.Name     = "FlagGrip"
	motor.Part0    = torso
	motor.Part1    = handlePart
	motor.C0       = CFrame.new()
	motor.C1       = CFrame.new()
	motor.Parent   = torso

	for _, p in ipairs(flagModel:GetDescendants()) do
		if p:IsA("BasePart") then p.Anchored = false end
	end
	disableCollision(flagModel)

	if handlePart and ownerId and compIdx then
		createFlagUI(handlePart, ownerId, compIdx)
	end

	local track = playFlagAnim(clientModel)
	attachedFlags[shortId] = { model = flagModel, motor = motor, track = track }
end


function FlagController.detachFromNpc(shortId: number)
	local data = attachedFlags[shortId]
	if not data then return end

	local ownerId = data.model.Parent and data.model.Parent:GetAttribute("OwnerUserId")
	local compIdx = data.model.Parent and data.model.Parent:GetAttribute("CompanyIndex")
	if ownerId and compIdx then
		local key = makeKey(ownerId, compIdx)
		if flagUIs[key] then flagUIs[key].gui:Destroy(); flagUIs[key] = nil end
	end

	if data.track then pcall(function() data.track:Stop() end) end
	if data.motor and data.motor.Parent then data.motor:Destroy() end
	if data.model and data.model.Parent then data.model:Destroy() end

	attachedFlags[shortId] = nil
end

function FlagController.spawnDropped(ownerUserId: number, compIdx: number, position: Vector3)
	local key = makeKey(ownerUserId, compIdx)
	FlagController.removeDropped(ownerUserId, compIdx)

	local flagModel = FLAG_TEMPLATE:Clone()
	flagModel.Name  = "DroppedFlag_" .. key

	for _, p in ipairs(flagModel:GetDescendants()) do
		if p:IsA("BasePart") then p.Anchored = true end
	end
	disableCollision(flagModel)

	local rootPart = flagModel.PrimaryPart or flagModel:FindFirstChildOfClass("BasePart")
	if rootPart then flagModel:PivotTo(CFrame.new(position)) end

	flagModel.Parent = workspace
	playFlagAnim(flagModel)

	if rootPart then
		createFlagUI(rootPart, ownerUserId, compIdx)
	end

	droppedFlags[key] = flagModel
end

-->>>>>>>>>>>>
-- Updates the strength bar. Persists ticket/broken values so re-attached flags
-- start at the correct bar level instead of resetting to 100%.
function FlagController.updateFlagUI(ownerUserId: number, compIdx: number, tickets: number, isBroken: boolean)
	local key  = makeKey(ownerUserId, compIdx)

	-- Always persist so re-created UIs can restore the last known state.
	lastKnownTickets[key] = tickets
	lastKnownBroken[key]  = isBroken

	local data = flagUIs[key]
	if not data then return end

	local ratio = math.clamp(tickets / GameSettings.MAX_TICKETS, 0, 1)
	local color = isBroken and Color3.fromRGB(200, 50, 50) or getTicketColor(ratio)
	data.tickets  = tickets
	data.isBroken = isBroken

	TweenService:Create(data.fill, BAR_TWEEN, {
		Size             = UDim2.new(ratio, 0, 1, 0),
		BackgroundColor3 = color,
	}):Play()
end

function FlagController.removeDropped(ownerUserId: number, compIdx: number)
	local key   = makeKey(ownerUserId, compIdx)
	local model = droppedFlags[key]
	if model and model.Parent then model:Destroy() end

	if flagUIs[key] then
		flagUIs[key].gui:Destroy()
		flagUIs[key] = nil
	end
	droppedFlags[key] = nil
end

return FlagController
