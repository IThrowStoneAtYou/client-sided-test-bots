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
local TOP_OFFSET     = 90   -- sits below MatchHUD

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

	self._stack = {}   -- { frame, tweenables[] }

	return self
end

-- ── Internal ──────────────────────────────────────────────────────────

-- Smoothly slides all active notifications to their correct Y position.
function NotificationHUD:_restack()
	for i, entry in ipairs(self._stack) do
		local targetY = TOP_OFFSET + (i - 1) * (NOTIF_H + NOTIF_GAP)
		TweenService:Create(entry.frame, SLIDE_IN, {
			Position = UDim2.new(1, -(NOTIF_W + 10), 0, targetY),
		}):Play()
	end
end

function NotificationHUD:_remove(entry)
	for i, e in ipairs(self._stack) do
		if e == entry then
			table.remove(self._stack, i)
			break
		end
	end
	entry.frame:Destroy()
	self:_restack()
end

-- ── Public API ────────────────────────────────────────────────────────

-->>>>>>>>>>>>
-- eventType: 1 = broke, 2 = overrun
-- cost: raw ticket number (200, 500, …)
function NotificationHUD:push(
	victimName:   string,
	victimComp:   number,
	attackerName: string,
	attackerComp: number,
	eventType:    number,
	cost:         number
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
	frame.Position               = UDim2.new(1, 10, 0, TOP_OFFSET)
	frame.AnchorPoint            = Vector2.new(0, 0)
	frame.BackgroundColor3       = Color3.fromRGB(14, 14, 22)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel        = 0
	frame.ZIndex                 = 30
	frame.Parent                 = self._gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent       = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color        = color
	stroke.Thickness    = 1.5
	stroke.Transparency = 0.35
	stroke.Parent       = frame

	-- Left accent stripe
	local accent = Instance.new("Frame")
	accent.Size             = UDim2.new(0, 3, 1, 0)
	accent.Position         = UDim2.new(0, 0, 0, 0)
	accent.BackgroundColor3 = color
	accent.BorderSizePixel  = 0
	accent.ZIndex           = 31
	accent.Parent           = frame

	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(0, 5)
	accentCorner.Parent       = accent

	-- Main label: "VictimName - CO N  broke  by  AttackerName - CO M"
	local mainLabel = Instance.new("TextLabel")
	mainLabel.Name                  = "Main"
	mainLabel.Size                  = UDim2.new(1, -70, 1, 0)
	mainLabel.Position              = UDim2.new(0, 12, 0, 0)
	mainLabel.BackgroundTransparency = 1
	mainLabel.RichText              = true
	mainLabel.Text                  = string.format(
		'<b>%s</b> CO %d  <font color="#%s">%s</font>  by  <b>%s</b> CO %d',
		victimName,   victimComp,
		color:ToHex(), verb,
		attackerName, attackerComp
	)
	mainLabel.TextColor3            = Color3.fromRGB(215, 215, 215)
	mainLabel.Font                  = Enum.Font.Gotham
	mainLabel.TextSize              = 11
	mainLabel.TextXAlignment        = Enum.TextXAlignment.Left
	mainLabel.TextTruncate          = Enum.TextTruncate.AtEnd
	mainLabel.ZIndex                = 31
	mainLabel.Parent                = frame

	-- Cost label right-aligned
	local costLabel = Instance.new("TextLabel")
	costLabel.Name                  = "Cost"
	costLabel.Size                  = UDim2.new(0, 55, 1, 0)
	costLabel.Position              = UDim2.new(1, -58, 0, 0)
	costLabel.BackgroundTransparency = 1
	costLabel.Text                  = "-" .. tostring(cost)
	costLabel.TextColor3            = color
	costLabel.Font                  = Enum.Font.GothamBold
	costLabel.TextSize              = 13
	costLabel.TextXAlignment        = Enum.TextXAlignment.Right
	costLabel.ZIndex                = 31
	costLabel.Parent                = frame

	-- Collect everything that needs fading
	local tweenables = {
		{ obj = frame,     prop = "BackgroundTransparency", full = 0.1,  gone = 1    },
		{ obj = stroke,    prop = "Transparency",           full = 0.35, gone = 1    },
		{ obj = accent,    prop = "BackgroundTransparency", full = 0,    gone = 1    },
		{ obj = mainLabel, prop = "TextTransparency",       full = 0,    gone = 1    },
		{ obj = costLabel, prop = "TextTransparency",       full = 0,    gone = 1    },
	}

	local entry = { frame = frame, tweenables = tweenables }
	table.insert(self._stack, entry)
	self:_restack()

	-- Lifetime → fade out → remove
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

return NotificationHUD