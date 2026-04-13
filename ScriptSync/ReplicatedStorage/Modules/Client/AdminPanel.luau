-->>>>>>>>>>>>
-- ADMIN_PANEL
-- Version 1.0.0
--
-- Admin-only settings panel:
--   • Small ⚙ button, bottom-right of screen
--   • Clicking slides a two-tab panel in from the right
--   • Tab 1 — BOTS:  Walk Speed, Max Bots, Max Companies, all combat & melee constants
--   • Tab 2 — MATCH: Ticket counts, durations, costs
--   • Save button fires the appropriate Network event; server validates & applies
--
-- To grant access: add the admin's UserId to ADMIN_IDS.
-- Non-admins get a silent dummy object — nothing is rendered.
--
-- Call: AdminPanel.new(Network)   (pass the already-required Blink client module)
-->>>>>>>>>>>>

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- ── Admin whitelist (client-side display gate only; server re-checks) ──
local ADMIN_IDS: { [number]: boolean } = {
	[5327451875] = true,
	-- add more UserIds here
}

-- ── Visual constants (matches existing HUD palette) ────────────────────
local BG_COLOR     = Color3.fromRGB(14,  14,  22)
local FIELD_BG     = Color3.fromRGB(22,  22,  36)
local ACCENT_COLOR = Color3.fromRGB(100, 140, 255)
local TEXT_COLOR   = Color3.fromRGB(220, 220, 220)
local DIM_COLOR    = Color3.fromRGB(130, 130, 145)
local SAVE_OK      = Color3.fromRGB(55,  170, 90)

local PANEL_W    = 382
local PANEL_H    = 514
local SLIDE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local localPlayer = Players.LocalPlayer

-- ── Module ────────────────────────────────────────────────────────────
local AdminPanel = {}
AdminPanel.__index = AdminPanel

-- ── Internal helpers ──────────────────────────────────────────────────

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color        = color
	s.Thickness    = thickness
	s.Transparency = transparency
	s.Parent       = parent
	return s
end

local function addCorner(parent: Instance, radius: number): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent       = parent
	return c
end

-->>>>>>>>>>>>
-- Creates one labelled input row inside a page frame.
-- Returns the TextBox so the caller can read .Text on save.
local function makeRow(parent: Frame, label: string, default: string, yOffset: number): TextBox
	local row = Instance.new("Frame")
	row.Size                 = UDim2.new(1, -20, 0, 28)
	row.Position             = UDim2.new(0, 10,  0, yOffset)
	row.BackgroundTransparency = 1
	row.Parent               = parent

	local lbl = Instance.new("TextLabel")
	lbl.Size                 = UDim2.new(1, -136, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text                 = label
	lbl.TextColor3           = DIM_COLOR
	lbl.Font                 = Enum.Font.Gotham
	lbl.TextSize             = 11
	lbl.TextXAlignment       = Enum.TextXAlignment.Left
	lbl.TextTruncate         = Enum.TextTruncate.AtEnd
	lbl.Parent               = row

	local bg = Instance.new("Frame")
	bg.Size              = UDim2.new(0, 122, 1, -6)
	bg.AnchorPoint       = Vector2.new(1, 0.5)
	bg.Position          = UDim2.new(1, 0, 0.5, 0)
	bg.BackgroundColor3  = FIELD_BG
	bg.BorderSizePixel   = 0
	bg.Parent            = row
	addCorner(bg, 4)
	local fieldStroke = addStroke(bg, Color3.fromRGB(48, 48, 72), 1, 0)

	local tb = Instance.new("TextBox")
	tb.Size                 = UDim2.new(1, -10, 1, 0)
	tb.Position             = UDim2.new(0, 5, 0, 0)
	tb.BackgroundTransparency = 1
	tb.Text                 = default
	tb.TextColor3           = TEXT_COLOR
	tb.PlaceholderColor3    = DIM_COLOR
	tb.Font                 = Enum.Font.GothamBold
	tb.TextSize             = 12
	tb.TextXAlignment       = Enum.TextXAlignment.Center
	tb.ClearTextOnFocus     = false
	tb.Parent               = bg

	tb.Focused:Connect(function()
		fieldStroke.Color        = ACCENT_COLOR
		fieldStroke.Transparency = 0
	end)
	tb.FocusLost:Connect(function()
		fieldStroke.Color        = Color3.fromRGB(48, 48, 72)
		fieldStroke.Transparency = 0
	end)

	return tb
end

-->>>>>>>>>>>>
-- Parses "MM:SS" or plain seconds into total seconds.
local function parseDuration(text: string): number
	local m, s = text:match("^(%d+):(%d+)$")
	if m and s then
		return tonumber(m) * 60 + tonumber(s)
	end
	return tonumber(text) or (20 * 60)
end

local function fmtDuration(secs: number): string
	local s = math.max(0, math.floor(secs))
	return string.format("%02d:%02d", math.floor(s / 60), s % 60)
end

local function num(text: string, fallback: number): number
	return tonumber(text) or fallback
end

-- ── Constructor ───────────────────────────────────────────────────────

-->>>>>>>>>>>>
-- Builds the full admin UI. Silently returns a dummy table for non-admins.
function AdminPanel.new(Network)
	if not ADMIN_IDS[localPlayer.UserId] then
		return setmetatable({}, AdminPanel)
	end

	local self        = setmetatable({}, AdminPanel)
	self._open        = false
	self._currentTab  = "BOTS"

	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name           = "AdminPanel"
	gui.ResetOnSpawn   = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.Parent         = playerGui

	-- ── Toggle button ──────────────────────────────────────────────
	local toggle = Instance.new("TextButton")
	toggle.Name                   = "AdminToggle"
	toggle.Size                   = UDim2.new(0, 44, 0, 44)
	toggle.Position               = UDim2.new(1, -10, 1, -10)
	toggle.AnchorPoint            = Vector2.new(1, 1)
	toggle.BackgroundColor3       = Color3.fromRGB(18, 18, 32)
	toggle.BackgroundTransparency = 0.12
	toggle.Text                   = "⚙"
	toggle.TextColor3             = ACCENT_COLOR
	toggle.Font                   = Enum.Font.GothamBold
	toggle.TextSize               = 22
	toggle.ZIndex                 = 55
	toggle.Parent                 = gui
	addCorner(toggle, 8)
	local toggleStroke = addStroke(toggle, ACCENT_COLOR, 1.5, 0.45)

	-- ── Panel (slides in from the right) ───────────────────────────
	-- AnchorPoint (0.5,0.5): centered.
	-- closedPos: right edge past screen boundary → fully hidden.
	-- openPos:   center of the screen.
	local openPos   = UDim2.new(0.5, 0, 0.5, 0)
	local closedPos = UDim2.new(1.5, 0, 0.5, 0)

	local panel = Instance.new("Frame")
	panel.Name                   = "Panel"
	panel.Size                   = UDim2.new(0, PANEL_W, 0, PANEL_H)
	panel.Position               = closedPos
	panel.AnchorPoint            = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3       = BG_COLOR
	panel.BackgroundTransparency = 0.06
	panel.ZIndex                 = 45
	panel.Parent                 = gui
	addCorner(panel, 10)
	addStroke(panel, ACCENT_COLOR, 1.5, 0.3)

	-- Header
	local header = Instance.new("TextLabel")
	header.Size                 = UDim2.new(1, -20, 0, 36)
	header.Position             = UDim2.new(0, 14, 0, 5)
	header.BackgroundTransparency = 1
	header.Text                 = "⚙  ADMIN PANEL"
	header.TextColor3           = ACCENT_COLOR
	header.Font                 = Enum.Font.GothamBold
	header.TextSize             = 13
	header.TextXAlignment       = Enum.TextXAlignment.Left
	header.ZIndex               = 46
	header.Parent               = panel

	-- Divider under header
	local divider = Instance.new("Frame")
	divider.Size              = UDim2.new(1, -20, 0, 1)
	divider.Position          = UDim2.new(0, 10, 0, 40)
	divider.BackgroundColor3  = ACCENT_COLOR
	divider.BackgroundTransparency = 0.65
	divider.BorderSizePixel   = 0
	divider.ZIndex            = 46
	divider.Parent            = panel

	-- ── Tab buttons ────────────────────────────────────────────────
	local TAB_Y = 48

	local botsTab = Instance.new("TextButton")
	botsTab.Size                   = UDim2.new(0.5, -14, 0, 28)
	botsTab.Position               = UDim2.new(0, 10, 0, TAB_Y)
	botsTab.BackgroundColor3       = Color3.fromRGB(22, 22, 40)
	botsTab.BackgroundTransparency = 0.2
	botsTab.Text                   = "BOTS"
	botsTab.TextColor3             = TEXT_COLOR
	botsTab.Font                   = Enum.Font.GothamBold
	botsTab.TextSize               = 11
	botsTab.ZIndex                 = 46
	botsTab.Parent                 = panel
	addCorner(botsTab, 5)
	local botsStroke = addStroke(botsTab, ACCENT_COLOR, 1.5, 0)

	local matchTab = Instance.new("TextButton")
	matchTab.Size                   = UDim2.new(0.5, -14, 0, 28)
	matchTab.Position               = UDim2.new(0.5, 4, 0, TAB_Y)
	matchTab.BackgroundColor3       = Color3.fromRGB(22, 22, 40)
	matchTab.BackgroundTransparency = 0.2
	matchTab.Text                   = "MATCH"
	matchTab.TextColor3             = DIM_COLOR
	matchTab.Font                   = Enum.Font.GothamBold
	matchTab.TextSize               = 11
	matchTab.ZIndex                 = 46
	matchTab.Parent                 = panel
	addCorner(matchTab, 5)
	local matchStroke = addStroke(matchTab, Color3.fromRGB(48, 48, 72), 1.5, 0)

	-- ── Scrolling content pages ────────────────────────────────────
	local CONTENT_TOP = TAB_Y + 36
	local CONTENT_H   = PANEL_H - CONTENT_TOP - 54   -- space for save button

	local function makePage(): ScrollingFrame
		local page = Instance.new("ScrollingFrame")
		page.Size                = UDim2.new(1, 0, 0, CONTENT_H)
		page.Position            = UDim2.new(0, 0, 0, CONTENT_TOP)
		page.BackgroundTransparency = 1
		page.ScrollBarThickness  = 3
		page.ScrollBarImageColor3 = ACCENT_COLOR
		page.CanvasSize          = UDim2.new(0, 0, 0, 0)
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.ZIndex              = 46
		page.Visible             = false
		page.Parent              = panel
		return page
	end

	local botsPage  = makePage()
	local matchPage = makePage()

	-- ── BOTS fields ────────────────────────────────────────────────
	local botsFields = {}
	local BOTS_DEFS = {
		{ key = "WALK_SPEED",              label = "Walk Speed",                     default = "15"  },
		{ key = "MAX_BOTS",                label = "Max Bots",                       default = "45"  },
		{ key = "MAX_COMPANIES",           label = "Max Companies",                  default = "4"   },
		{ key = "COMBAT_RANGE",            label = "Combat Range (studs)",           default = "400" },
		{ key = "MUSKET_DAMAGE",           label = "Musket Damage",                  default = "100" },
		{ key = "BULLET_SPREAD",           label = "Bullet Spread (°)",              default = "3"   },
		{ key = "MELEE_ENGAGE_RANGE",      label = "Melee Engage Range (studs)",     default = "7"   },
		{ key = "MELEE_DAMAGE",            label = "Melee Damage",                   default = "50"  },
		{ key = "MELEE_BEARER_FLEE_RANGE", label = "Bearer Flee Trigger (studs)",    default = "30"  },
		{ key = "MELEE_BEARER_FLEE_DIST",  label = "Bearer Flee Distance (studs)",   default = "20"  },
	}

	local yOff = 8
	for _, def in ipairs(BOTS_DEFS) do
		botsFields[def.key] = makeRow(botsPage, def.label, def.default, yOff)
		yOff += 34
	end

	-- ── MATCH fields ───────────────────────────────────────────────
	local matchFields = {}
	local MATCH_DEFS = {
		{ key = "STARTING_TICKETS",      label = "Starting Tickets",          default = "10000" },
		{ key = "MATCH_DURATION",        label = "Match Duration (MM:SS)",    default = "20:00" },
		{ key = "INTERMISSION_DURATION", label = "Intermission (seconds)",    default = "5"     },
		{ key = "COST_BOT_DEATH",        label = "Cost: Bot Death",           default = "5"     },
		{ key = "COST_BROKE",            label = "Cost: Company Broke",       default = "200"   },
		{ key = "COST_OVERRUN",          label = "Cost: Company Overrun",     default = "500"   },
	}

	yOff = 8
	for _, def in ipairs(MATCH_DEFS) do
		matchFields[def.key] = makeRow(matchPage, def.label, def.default, yOff)
		yOff += 34
	end

	-- ── Save button ────────────────────────────────────────────────
	local saveBtn = Instance.new("TextButton")
	saveBtn.Size                   = UDim2.new(1, -20, 0, 36)
	saveBtn.Position               = UDim2.new(0, 10, 1, -44)
	saveBtn.AnchorPoint            = Vector2.new(0, 0)
	saveBtn.BackgroundColor3       = ACCENT_COLOR
	saveBtn.BackgroundTransparency = 0.1
	saveBtn.Text                   = "SAVE CHANGES"
	saveBtn.TextColor3             = Color3.fromRGB(255, 255, 255)
	saveBtn.Font                   = Enum.Font.GothamBold
	saveBtn.TextSize               = 13
	saveBtn.ZIndex                 = 47
	saveBtn.Parent                 = panel
	addCorner(saveBtn, 6)

	-- ── Tab switching ──────────────────────────────────────────────
	local function switchTab(tab: string)
		self._currentTab = tab
		local onBots = tab == "BOTS"

		botsPage.Visible  = onBots
		matchPage.Visible = not onBots

		botsTab.TextColor3   = onBots and TEXT_COLOR or DIM_COLOR
		matchTab.TextColor3  = onBots and DIM_COLOR  or TEXT_COLOR
		botsStroke.Color     = onBots and ACCENT_COLOR               or Color3.fromRGB(48, 48, 72)
		matchStroke.Color    = onBots and Color3.fromRGB(48, 48, 72) or ACCENT_COLOR
	end

	switchTab("BOTS")   -- default tab on open

	botsTab.MouseButton1Click:Connect(function()  switchTab("BOTS")  end)
	matchTab.MouseButton1Click:Connect(function() switchTab("MATCH") end)

	-- ── Panel toggle (slide in/out) ────────────────────────────────
	toggle.MouseButton1Click:Connect(function()
		self._open = not self._open
		TweenService:Create(panel, SLIDE_INFO, {
			Position = self._open and openPos or closedPos,
		}):Play()
		toggleStroke.Transparency = self._open and 0 or 0.45
	end)

	-- ── Save logic ─────────────────────────────────────────────────
	local function flashSave(success: boolean)
		local flash = success and SAVE_OK or Color3.fromRGB(200, 55, 55)
		local prev  = ACCENT_COLOR
		saveBtn.BackgroundColor3 = flash
		task.delay(0.7, function()
			if saveBtn and saveBtn.Parent then
				saveBtn.BackgroundColor3 = prev
			end
		end)
	end

	saveBtn.MouseButton1Click:Connect(function()
		if self._currentTab == "BOTS" then
			local ok = pcall(function()
				Network.AdminUpdateBots.Fire({
					walkSpeed            = num(botsFields.WALK_SPEED.Text,              15),
					maxBots              = num(botsFields.MAX_BOTS.Text,                45),
					maxCompanies         = num(botsFields.MAX_COMPANIES.Text,           4),
					combatRange          = num(botsFields.COMBAT_RANGE.Text,            400),
					musketDamage         = num(botsFields.MUSKET_DAMAGE.Text,           100),
					bulletSpread         = num(botsFields.BULLET_SPREAD.Text,           3),
					meleeEngageRange     = num(botsFields.MELEE_ENGAGE_RANGE.Text,      7),
					meleeDamage          = num(botsFields.MELEE_DAMAGE.Text,            50),
					meleeBearerFleeRange = num(botsFields.MELEE_BEARER_FLEE_RANGE.Text, 30),
					meleeBearerFleeDist  = num(botsFields.MELEE_BEARER_FLEE_DIST.Text,  20),
				})
			end)
			flashSave(ok)

		else -- MATCH tab
			local rawDur = parseDuration(matchFields.MATCH_DURATION.Text)
			matchFields.MATCH_DURATION.Text = fmtDuration(rawDur)   -- normalise display

			local ok = pcall(function()
				Network.AdminUpdateMatch.Fire({
					startingTickets      = num(matchFields.STARTING_TICKETS.Text,      10000),
					matchDuration        = rawDur,
					intermissionDuration = num(matchFields.INTERMISSION_DURATION.Text, 5),
					costBotDeath         = num(matchFields.COST_BOT_DEATH.Text,        5),
					costBroke            = num(matchFields.COST_BROKE.Text,            200),
					costOverrun          = num(matchFields.COST_OVERRUN.Text,          500),
				})
			end)
			flashSave(ok)
		end
	end)

	return self
end

return AdminPanel
