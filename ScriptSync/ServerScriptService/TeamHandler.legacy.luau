local Players           = game:GetService("Players")
local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(game.ReplicatedStorage.Blink.Server)

-- Maps event teamIndex → Roblox Team name (must match MatchManager)
local TEAM_NAMES: { [number]: string } = {
	[1] = "TEAM 1",
	[2] = "TEAM 2",
}

-- Regiment name table (mirrors TeamSelectMenu — purely informational here;
-- swap to model-key lookup once you have per-regiment NPC models).
local REGIMENT_NAMES: { [number]: { [number]: string } } = {
	[1] = {
		[1] = "British Line Infantry",
		[2] = "95th Rifles",
		[3] = "King's German Legion",
		[4] = "Dutch-Belgian Brigade",
	},
	[2] = {
		[1] = "French Line Infantry",
		[2] = "Imperial Guard",
		[3] = "Polish Lancers",
		[4] = "Westphalian Infantry",
	},
}

-- ── Validate ──────────────────────────────────────────────────────────

local function isValidTeam(ti: number): boolean
	return ti == 1 or ti == 2
end

local function isValidRegiment(ri: number): boolean
	return ri >= 1 and ri <= 4
end

-- ── Handler ───────────────────────────────────────────────────────────

Network.TeamRegimentSelect.On(function(player: Player, teamIndex: number, regimentIndex: number)
	-- Sanitise
	teamIndex     = math.floor(teamIndex)
	regimentIndex = math.floor(regimentIndex)

	if not isValidTeam(teamIndex) or not isValidRegiment(regimentIndex) then
		warn(string.format( "[TeamHandler] Invalid selection from %s: team=%s reg=%s", player.Name, tostring(teamIndex), tostring(regimentIndex)))
		return
	end

	-- Assign Roblox team
	local teamName = TEAM_NAMES[teamIndex]
	local team     = Teams:FindFirstChild(teamName)
	if team then
		player.Team = team
	else
		warn("[TeamHandler] Roblox Team not found:", teamName)
	end

	-- Store on player for NPC_SYSTEM / outfit lookup
	player:SetAttribute("TeamIndex",      teamIndex)
	player:SetAttribute("RegimentIndex",  regimentIndex)
	player:SetAttribute("RegimentName",   REGIMENT_NAMES[teamIndex][regimentIndex] or "Unknown")

	-- ── Despawn existing companies so the player starts fresh ─────────
	-- (prevents owning bots on the wrong team after a switch)
	-- This fires into NPC_SYSTEM via chat /spawn 0 0 equivalent — but
	-- since despawnAllCompanies is local to NPC_SYSTEM we use an attribute
	-- flag that NPC_SYSTEM reads on its next tick to trigger cleanup.
	-- Alternatively, call despawnAllCompanies directly if you refactor it
	-- into a shared module.
	player:SetAttribute("RequestDespawnAll", true)

	print(string.format("[TeamHandler] %s → %s / %s", player.Name, teamName,REGIMENT_NAMES[teamIndex][regimentIndex]))
end)

-- ── Clean up on leave ─────────────────────────────────────────────────
Players.PlayerRemoving:Connect(function(player)
	-- Attributes auto-clear when the player leaves; nothing extra needed.
end)
