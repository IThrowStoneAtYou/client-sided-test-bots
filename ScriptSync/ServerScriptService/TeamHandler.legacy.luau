-->>>>>>>>>>>>
-- TEAM_HANDLER
-- Version 2.0.0
--
-- Receives TeamRegimentSelect(sideIndex: u8, regimentIndex: u8) from client.
--
-- sideIndex mapping (matches TeamSelectMenu SIDES table):
--   1 = Attackers (France)   → Roblox team "TEAM 2"
--   2 = Defenders (Britain)  → Roblox team "TEAM 1"
--
-- This aligns with MatchManager's TEAM_NAME_TO_INDEX:
--   "TEAM 1" → team index 1  (Defenders / Britain  / red bar)
--   "TEAM 2" → team index 2  (Attackers / France   / navy bar)
--
-- regimentIndex is the 1-based position in the side's nations[1].regiments[].
-- When more nations or regiments are added, extend REGIMENT_NAMES below.
-->>>>>>>>>>>>

local Players           = game:GetService("Players")
local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(game.ReplicatedStorage.Blink.Server)
local RegimentData = require(ReplicatedStorage.Modules.Shared.RegimentData)


-- ── Handler ───────────────────────────────────────────────────────────

Network.TeamRegimentSelect.On(function(player: Player, sideIndex: number, regimentIndex: number)
	sideIndex     = math.floor(sideIndex)
	regimentIndex = math.floor(regimentIndex)

	local side = RegimentData.Sides[sideIndex]
	if not side then
		warn(string.format("[TeamHandler] Invalid sideIndex from %s: %s", player.Name, tostring(sideIndex)))
		return
	end

	local regInfo = RegimentData.GetRegimentInfo(sideIndex, regimentIndex)
	if not regInfo then
		warn(string.format("[TeamHandler] Invalid regimentIndex from %s: side=%d reg=%d", player.Name, sideIndex, regimentIndex))
		return
	end

	-- Assign Roblox team
	local team     = Teams:FindFirstChild(side.role)
	if team then
		player.Team = team
	else
		warn("[TeamHandler] Roblox Team not found:", teamName)
	end

	-- Store on player for NPC_SYSTEM / outfit lookup
	local regName = regInfo.name
	player:SetAttribute("SideIndex",      sideIndex)
	player:SetAttribute("RegimentIndex",  regimentIndex)
	player:SetAttribute("RegimentName",   regName)
	
	-- Legacy attribute kept for any existing code that reads TeamIndex
	player:SetAttribute("TeamIndex",      sideIndex == 1 and 2 or 1)

	-- Signal NPC_SYSTEM to despawn this player's current companies
	player:SetAttribute("RequestDespawnAll", true)

	print(string.format("[TeamHandler] %s %s / %s", player.Name, teamName, regName ))
end)

Network.RequestTeamReset.On(function(player: Player)
	local noTeam = Teams:FindFirstChild("NO TEAM")
	if noTeam then
		print(string.format("[TeamHandler] Resetting team for %s", player.Name))
		player.Team = noTeam
		player:SetAttribute("SideIndex",      nil)
		player:SetAttribute("RegimentIndex",  nil)
		player:SetAttribute("RegimentName",   nil)
		player:SetAttribute("TeamIndex",      nil)
		player:SetAttribute("RequestDespawnAll", true)
	end
end)

-- ── Cleanup ───────────────────────────────────────────────────────────
Players.PlayerRemoving:Connect(function(_player)
	-- Attributes clear automatically on leave; nothing extra needed.
end)
