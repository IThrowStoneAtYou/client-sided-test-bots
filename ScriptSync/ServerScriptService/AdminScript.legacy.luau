-->>>>>>>>>>>>
-- ADMIN_HANDLER
-->>>>>>>>>>>>

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network      = require(game.ReplicatedStorage.Blink.Server)
local GameSettings = require(ReplicatedStorage.Modules.Shared.GameSettings)

-- ── Admin whitelist (must mirror AdminPanel.luau) ─────────────────────
local ADMIN_IDS: { [number]: boolean } = {
	[5327451875] = true,
}

local function isAdmin(player: Player): boolean
	return ADMIN_IDS[player.UserId] == true
end

-- ── Helper: apply WalkSpeed to all currently-alive server NPCs ─────────
local function applyWalkSpeedNow()
	local registry = workspace:FindFirstChild("Npc_Registry_Server")
	if not registry then return end
	for _, model in ipairs(registry:GetChildren()) do
		local hum = model:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = GameSettings.WALK_SPEED
		end
	end
end

-- ── Bot / combat settings ─────────────────────────────────────────────
Network.AdminUpdateBots.On(function(player, data)
	if not isAdmin(player) then
		warn(string.format("[AdminHandler] Rejected AdminUpdateBots from non-admin: %s (%d)",
			player.Name, player.UserId))
		return
	end

	GameSettings.WALK_SPEED              = math.clamp(data.walkSpeed,              1,    200)
	GameSettings.MAX_BOTS                = math.clamp(math.floor(data.maxBots),    1,    500)
	GameSettings.MAX_COMPANIES           = math.clamp(math.floor(data.maxCompanies), 1,   4)
	GameSettings.COMBAT_RANGE            = math.clamp(data.combatRange,            10,  2000)
	GameSettings.MUSKET_DAMAGE           = math.clamp(data.musketDamage,           1,   9999)
	GameSettings.BULLET_SPREAD           = math.clamp(data.bulletSpread,           0,   45)
	GameSettings.MELEE_ENGAGE_RANGE      = math.clamp(data.meleeEngageRange,       1,   100)
	GameSettings.MELEE_DAMAGE            = math.clamp(data.meleeDamage,            1,   9999)
	GameSettings.MELEE_BEARER_FLEE_RANGE = math.clamp(data.meleeBearerFleeRange,   1,   500)
	GameSettings.MELEE_BEARER_FLEE_DIST  = math.clamp(data.meleeBearerFleeDist,    1,   300)

	-- WalkSpeed must be pushed to live Humanoids immediately;
	-- all other constants are read per-frame from GameSettings automatically
	-- once you complete the integration steps below.
	applyWalkSpeedNow()

	print(string.format(
		"[AdminHandler] Bot settings updated by %s  |  WalkSpeed=%.0f  Range=%.0f  MstDmg=%.0f  MelDmg=%.0f",
		player.Name,
		GameSettings.WALK_SPEED,
		GameSettings.COMBAT_RANGE,
		GameSettings.MUSKET_DAMAGE,
		GameSettings.MELEE_DAMAGE
		))
end)

-- ── Match settings ────────────────────────────────────────────────────
Network.AdminUpdateMatch.On(function(player, data)
	if not isAdmin(player) then
		warn(string.format("[AdminHandler] Rejected AdminUpdateMatch from non-admin: %s (%d)",
			player.Name, player.UserId))
		return
	end

	GameSettings.STARTING_TICKETS      = math.clamp(math.floor(data.startingTickets),      0,  10_000_000)
	GameSettings.MATCH_DURATION        = math.clamp(math.floor(data.matchDuration),         30, 86400)
	GameSettings.INTERMISSION_DURATION = math.clamp(math.floor(data.intermissionDuration),  1,  3600)
	GameSettings.COST_BOT_DEATH        = math.clamp(math.floor(data.costBotDeath),          0,  100_000)
	GameSettings.COST_BROKE            = math.clamp(math.floor(data.costBroke),             0,  100_000)
	GameSettings.COST_OVERRUN          = math.clamp(math.floor(data.costOverrun),           0,  100_000)

	-- Note: MATCH_DURATION and INTERMISSION_DURATION take effect on the
	-- NEXT stage transition.  COST_* take effect immediately on the next
	-- death/event because MatchManager reads them from GameSettings directly
	-- after you complete the integration steps.

	local mm = math.floor(GameSettings.MATCH_DURATION / 60)
	local ss = GameSettings.MATCH_DURATION % 60
	print(string.format(
		"[AdminHandler] Match settings updated by %s  |  Tickets=%d  Duration=%02d:%02d  IntDur=%ds  Costs=%d/%d/%d",
		player.Name,
		GameSettings.STARTING_TICKETS,
		mm, ss,
		GameSettings.INTERMISSION_DURATION,
		GameSettings.COST_BOT_DEATH,
		GameSettings.COST_BROKE,
		GameSettings.COST_OVERRUN
		))
end)
