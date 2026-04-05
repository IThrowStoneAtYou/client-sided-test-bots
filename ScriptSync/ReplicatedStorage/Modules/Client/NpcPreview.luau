-->>>>>>>>>>>>
-- NPC_PREVIEW
-- Version 1.0.0
--
-- Purpose: Renders visual feedback for formation placement before confirming.
--
-- Features:
--   - Yellow dots at each NPC slot position (shows where soldiers will stand)
--   - White arrow showing formation's facing direction
--   - Highlights selected companies by applying Highlight instances
--   - Spawns fade-out particle dots when formation is placed (visual feedback)
--   - Pooled dot system for efficient rendering of many slots
--
-- Used by: NPC_SYSTEM_CLIENT during drag operations and company selection
--
-->>>>>>>>>>>>

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RegimentFormation = require(ReplicatedStorage.Modules.Shared:WaitForChild("RegimentFormation"))
local CompanyHUD = require(ReplicatedStorage.Modules.Client:WaitForChild("CompanyHUD"))

-- ── Constants ─────────────────────────────────────────────────────────
local DOT_SIZE = Vector3.new(1.2, 0.3, 1.2)
local FADE_INFO = TweenInfo.new(1.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local NpcPreview = {}

local HIGHLIGHT_TAG = "CompanyHighlight"

-- ── State ─────────────────────────────────────────────────────────────
local previewFolder = workspace:FindFirstChild("Client_Preview_Dots") or (function()
	local f = Instance.new("Folder")
	f.Name   = "Client_Preview_Dots"
	f.Parent = workspace
	
	return f
end)() -- huh

local function createPreviewPart(color: Color3, size: Vector3)
	local p = Instance.new("Part")
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CastShadow   = false
	p.Material     = Enum.Material.Neon
	p.Color        = color
	p.Size         = size
	p.Transparency = 1
	p.Parent       = previewFolder
	
	return p
end

local previewArrow = createPreviewPart(Color3.fromRGB(255, 255, 255), Vector3.new(0.4, 0.4, 4))
local slotDots     = {}
local activeDots   = 0

local function ensurePool(needed: number)
	while #slotDots < needed do
		slotDots[#slotDots + 1] = createPreviewPart(Color3.fromRGB(255, 215, 60), DOT_SIZE)
	end
end

-- ── Public API ────────────────────────────────────────────────────────

function NpcPreview.clearHighlights(replicators)
	for _, rep in pairs(replicators) do
		if rep.Client then
			local h = rep.Client:FindFirstChild(HIGHLIGHT_TAG)
			if h then h.Enabled = false end
		end
	end
end

function NpcPreview.setHighlightVisible(clientModel, companyIndex, visible)
	if not clientModel then return end
	local h = clientModel:FindFirstChild(HIGHLIGHT_TAG)
	if not h then
		h = Instance.new("Highlight")
		h.Name                = HIGHLIGHT_TAG
		h.FillColor           = CompanyHUD.getColor(companyIndex)
		h.OutlineColor        = CompanyHUD.getColor(companyIndex)
		h.FillTransparency    = 0.62
		h.OutlineTransparency = 0.1
		h.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent              = clientModel
	end
	h.Enabled = visible
end

function NpcPreview.applyHighlights(replicators, companySlots, selectedList)
	NpcPreview.clearHighlights(replicators)
	for _, compIdx in ipairs(selectedList) do
		local slots = companySlots[compIdx]
		if not slots then continue end
		for shortId in pairs(slots) do
			local rep = replicators[shortId]
			if rep and rep.Client then
				NpcPreview.setHighlightVisible(rep.Client, compIdx, true)
			end
		end
	end
end

-->>>>>>>>>>>>
-- Updates the active preview dots and arrow based on the calculated layouts.
function NpcPreview.update(layouts, facingDir: Vector3)
	local needed = 0
	for _, l in ipairs(layouts) do
		needed += #l.slots 
	end
	
	ensurePool(needed)

	local dotIdx    = 1
	local anchorSum = Vector3.zero
	local maxDepth  = 0

	for _, l in ipairs(layouts) do
		anchorSum += l.anchor
		local _, depth = RegimentFormation.getPreviewSize(l.ranks, l.files)
		if depth > maxDepth then
			maxDepth = depth 
		end

		for _, slotCF in ipairs(l.slots) do
			local dot = slotDots[dotIdx]
			dot.CFrame       = slotCF
			dot.Color        = l.color
			dot.Transparency = 0.3
			dotIdx += 1
		end
	end

	-- Hide unused dots in pool
	for i = dotIdx, activeDots do slotDots[i].Transparency = 1 end
	activeDots = dotIdx - 1

	-- Position central indicator arrow
	local centre   = anchorSum / #layouts
	local arrowLen = math.clamp(maxDepth * 0.3, 2, 6)
	previewArrow.Size   = Vector3.new(0.4, 0.4, arrowLen)
	previewArrow.CFrame = CFrame.lookAt(
		centre + facingDir * (arrowLen / 2 + 0.5),
		centre + facingDir * (arrowLen / 2 + 0.5) + facingDir
	)
	previewArrow.Transparency = 0
end

-->>>>>>>>>>>>
-- Hides all active preview elements.
function NpcPreview.hide()
	for i = 1, activeDots do
		slotDots[i].Transparency = 1
	end
	
	activeDots = 0
	previewArrow.Transparency = 1
end

-->>>>>>>>>>>>
-- Spawns temporary "echo" dots that fade out, providing feedback on command release.
function NpcPreview.spawnFadeDots(layouts, facingDir: Vector3)
	if #layouts == 0 then return end

	local anchorSum = Vector3.zero
	local maxDepth  = 0

	for _, l in ipairs(layouts) do
		anchorSum += l.anchor
		local _, depth = RegimentFormation.getPreviewSize(l.ranks, l.files)
		if depth > maxDepth then maxDepth = depth end

		for _, slotCF in ipairs(l.slots) do
			local p = createPreviewPart(l.color, DOT_SIZE)
			p.CFrame       = slotCF
			p.Transparency = 0.3
			
			local t = TweenService:Create(p, FADE_INFO, { Transparency = 1, Size = DOT_SIZE * 0.5 })
			t:Play()
			
			t.Completed:Connect(function()
				p:Destroy()
			end)
		end
	end

	-- Create a temporary arrow that fades out
	local centre   = anchorSum / #layouts
	local arrowLen = math.clamp(maxDepth * 0.3, 2, 6)
	local a = createPreviewPart(Color3.fromRGB(255, 255, 255), Vector3.new(0.4, 0.4, arrowLen))
	a.CFrame = CFrame.lookAt(
		centre + facingDir * (arrowLen / 2 + 0.5),
		centre + facingDir * (arrowLen / 2 + 0.5) + facingDir
	)
	a.Transparency = 0
	
	local t2 = TweenService:Create(a, FADE_INFO, { Transparency = 1 })
	t2:Play()
	
	t2.Completed:Connect(function()
		a:Destroy()
	end)
end

return NpcPreview