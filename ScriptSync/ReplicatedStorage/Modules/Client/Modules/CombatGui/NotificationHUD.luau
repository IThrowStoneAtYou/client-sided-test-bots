-->>>>>>>>>>>>
-- NOTIFICATION_HUD
-- Version 1.0.0
--
-- Top-right stacking notifications for match events.
-- Event types:
--   1 = Company broke   (-200)
--   2 = Company overrun (-500)
-->>>>>>>>>>>>

local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")

local NOTIF_W        = 370
local NOTIF_H        = 40
local NOTIF_GAP      = 5
local NOTIF_LIFETIME = 5
local NOTIF_FADE     = 0.5
local MAX_NOTIFS     = 6

local SLIDE_IN = TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(NOTIF_FADE, Enum.EasingStyle.Linear)

local EVENT_COLOR = {
	[1] = Color3.fromRGB(255, 255, 255),   -- broke: white
	[2] = Color3.fromRGB(200, 55,  55),   -- overrun: red
}

local EVENT_VERB = {
	[1] = "broke",
	[2] = "overrun",
}

local NotificationHUD = {}
NotificationHUD.__index = NotificationHUD

-- ── Constructor ───────────────────────────────────────────────────────

function NotificationHUD.new()
	local self = setmetatable({}, NotificationHUD)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name            = "NotificationHUD"
	gui.ResetOnSpawn    = false
	gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset  = true
	gui.Parent          = playerGui
	self._gui = gui

	local posFrame = Instance.new("Frame")
	posFrame.Name = "PosFrame"
	posFrame.BackgroundTransparency = 1
	posFrame.Position = UDim2.new(0.492, 0, 0.15, 90)
	posFrame.Size = UDim2.new(0, 22, 0, 20)
	posFrame.Parent = gui
	self._posFrame = posFrame

	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, NOTIF_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = posFrame

	self._stack = {}   -- { frame, tweenables[] }

	return self
end

-- ── Internal ──────────────────────────────────────────────────────────
function NotificationHUD:_remove(entry)
	for i, e in ipairs(self._stack) do
		if e == entry then
			table.remove(self._stack, i)
			break
		end
	end
	entry.frame:Destroy()
end

-- ── Public API ────────────────────────────────────────────────────────

-->>>>>>>>>>>>
-- eventType: 1 = broke, 2 = overrun
-- cost: raw ticket number (200, 500, …)
function NotificationHUD:push(
	victimName:    string,
	victimComp:    number,
	attackerName:  string,
	attackerComp:  number,
	eventType:     number,
	cost:          number,
	victimColor:   Color3,
	attackerColor: Color3
)
	-- Evict oldest if full
	if #self._stack >= MAX_NOTIFS then
		self:_remove(self._stack[1])
	end

	local color = EVENT_COLOR[eventType] or Color3.fromRGB(180, 180, 180)
	local verb  = EVENT_VERB[eventType]  or "event"

	-- ── Frame (off-screen right to start) ─────────────────────────────
	local frame = Instance.new("Frame")
	frame.Name                   = "Notif"
	frame.Size                   = UDim2.new(0, NOTIF_W, 0, NOTIF_H)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel        = 0
	frame.ZIndex                 = 30
	frame.Parent                 = self._posFrame

	-- Main label: "VictimName - CO N  broke  by  AttackerName - CO M"
	local mainLabel = Instance.new("TextLabel")
	mainLabel.Name                  = "Main"
	mainLabel.Size 					= UDim2.new(1, 0, 1, 0)
	mainLabel.Position              = UDim2.new(0, 0, 0, 0)
	mainLabel.BackgroundTransparency = 1
	mainLabel.RichText              = true
	local verb = eventType == 1 and "broken" or "overrun"
	mainLabel.Text = string.format(
		'<font color="#%s"><b>%s CO %d</b></font>  %s by  <font color="#%s"><b>%s CO %d</b></font>  <b>-%d</b>',
		victimColor:ToHex(),   victimName,   victimComp,
		verb,
		attackerColor:ToHex(), attackerName, attackerComp,
		cost
	)
	mainLabel.TextColor3            = Color3.fromRGB(215, 215, 215)
	mainLabel.Font                  = Enum.Font.Gotham
	mainLabel.TextSize              = 11
	mainLabel.TextXAlignment        = Enum.TextXAlignment.Center
	mainLabel.TextTruncate          = Enum.TextTruncate.AtEnd
	mainLabel.ZIndex                = 31
	mainLabel.Parent                = frame

	-- Collect everything that needs fading
	local tweenables = {
		{ obj = mainLabel, prop = "TextTransparency",       full = 0,    gone = 1    },
	}

	local entry = { frame = frame, tweenables = tweenables }
	table.insert(self._stack, entry)

	-- Lifetime, fade out, remove
	task.delay(NOTIF_LIFETIME, function()
		if not frame.Parent then return end
		local goals = {}
		for _, t in ipairs(tweenables) do
			goals[t.prop] = t.gone
		end
		-- Tween each instance individually
		for _, t in ipairs(tweenables) do
			TweenService:Create(t.obj, FADE_OUT, { [t.prop] = t.gone }):Play()
		end
		task.delay(NOTIF_FADE, function()
			self:_remove(entry)
		end)
	end)
end

function NotificationHUD:SetVisible(visible: boolean)
	self._gui.Enabled = visible
end

return NotificationHUD