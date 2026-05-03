-->>>>>>>>>>>>
-- MATCH_MANAGER
-- Version 1.2.0
--
-- Stages:
--   WAITING      — fewer than 1 player per team. Holds indefinitely.
--   INTERMISSION — countdown. Borders still up.
--   MATCH        — countdown. Borders removed. Tickets drain.
--   ENDED        — winner shown.
--   RESTARTING   — 10-second hold before full reset.
--
-- After ENDED, a 10-second RESTARTING phase fires, then all players are reset
-- to "NO TEAM", their characters respawn, and the stage returns to WAITING.
-- Register a callback via MatchManager.setOnRestartCallback to despawn companies.
-->>>>>>>>>>>>

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")
local Teams      = game:GetService("Teams")
local Network    = require(game.ReplicatedStorage.Blink.Server)

local GameSettings = require(game.ReplicatedStorage.Modules.Shared.GameSettings)

-- ── Config ────────────────────────────────────────────────────────────
local BROADCAST_INTERVAL  = 10   -- seconds between MatchUpdate fires during match
local RESTART_DELAY       = 10   -- seconds between ENDED and full reset

-- Map your actual Roblox Team names here
local TEAM_NAME_TO_INDEX: { [string]: number } = {
	["ATTACKERS"] = 1,
	["DEFENDERS"] = 2,
}

-- ── Stage enum ────────────────────────────────────────────────────────
local STAGE = {
	WAITING      = "WAITING",
	INTERMISSION = "INTERMISSION",
	MATCH        = "MATCH",
	ENDED        = "ENDED",
	RESTARTING   = "RESTARTING",
}

-- ── State ─────────────────────────────────────────────────────────────
local teamTickets: { [number]: number } = {
	[1] = GameSettings.STARTING_TICKETS,
	[2] = GameSettings.STARTING_TICKETS,
}

local stage                      = STAGE.WAITING
local stageTimer                 = 0
local broadcastAccum             = 0
local needsBroadcast             = false
local intermissionBroadcastAccum = 0

-- Callback registered by ServerScript so MatchManager can trigger company cleanup.
local onRestartCallback: (() -> ())?  = nil

-- ── Restart callback registration ─────────────────────────────────────
local MatchManager = {}

-- ServerScript calls this once during init to hook company despawn/respawn.
function MatchManager.setOnRestartCallback(fn: () -> ())
	onRestartCallback = fn
end

-- ── Borders ───────────────────────────────────────────────────────────
local function openBorders()
	local ok, folder = pcall(function()
		return workspace:WaitForChild("game", 5):WaitForChild("game_border", 5)
	end)
	if not ok or not folder then
		warn("[MatchManager] Could not find workspace.game.game_border")
		return
	end
	for _, name in ipairs({ "t1_border", "t2_border" }) do
		local part = folder:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.CanCollide  = false
			part.CanQuery    = false
			part.CanTouch    = false
			part.Transparency = 1
		else
			warn("[MatchManager] Border part not found:", name)
		end
	end
end

local function closeBorders()
	local ok, folder = pcall(function()
		return workspace:WaitForChild("game", 5):WaitForChild("game_border", 5)
	end)
	if not ok or not folder then return end
	for _, name in ipairs({ "t1_border", "t2_border" }) do
		local part = folder:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.CanCollide   = true
			part.CanQuery     = true
			part.CanTouch     = true
			part.Transparency = 0
		end
	end
end

-- ── Broadcast ─────────────────────────────────────────────────────────
local function broadcastUpdate()
	local t = math.ceil(stageTimer)
	for _, player in ipairs(Players:GetPlayers()) do
		Network.MatchUpdate.Fire(player, teamTickets[1], teamTickets[2], t)
	end
end

local function broadcastIntermission()
	local t = math.ceil(stageTimer)
	for _, player in ipairs(Players:GetPlayers()) do
		Network.MatchIntermission.Fire(player, t)
	end
end

-- ── Stage transitions ─────────────────────────────────────────────────
local function startIntermission()
	print("[MatchManager] Entering INTERMISSION")
	stage      = STAGE.INTERMISSION
	stageTimer = GameSettings.INTERMISSION_DURATION
	broadcastIntermission()
end

local function startMatch()
	print("[MatchManager] Entering MATCH")
	stage          = STAGE.MATCH
	stageTimer     = GameSettings.MATCH_DURATION
	broadcastAccum = 0

	teamTickets[1] = GameSettings.STARTING_TICKETS
	teamTickets[2] = GameSettings.STARTING_TICKETS

	openBorders()
	broadcastUpdate()
end

local function doRestart()
	print("[MatchManager] Restarting — resetting all players to NO TEAM")

	-- Reset match state
	teamTickets[1]            = GameSettings.STARTING_TICKETS
	teamTickets[2]            = GameSettings.STARTING_TICKETS
	stage                     = STAGE.WAITING
	stageTimer                = 0
	needsBroadcast            = false
	broadcastAccum            = 0
	intermissionBroadcastAccum = 0

	closeBorders()

	-- Notify ServerScript so it can despawn all active companies
	if onRestartCallback then
		pcall(onRestartCallback)
	end

	-- Reset every player back to the neutral team and respawn their character
	local noTeam = Teams:FindFirstChild("NO TEAM")
	for _, player in ipairs(Players:GetPlayers()) do
		if noTeam then
			player.Team = noTeam
		end
		player:SetAttribute("SideIndex",     nil)
		player:SetAttribute("RegimentIndex", nil)
		player:SetAttribute("RegimentName",  nil)
		player:SetAttribute("TeamIndex",     nil)
		pcall(function() player:LoadCharacterAsync() end)
	end

	print("[MatchManager] Restart complete — back to WAITING.")
end

local function endMatch()
	stage = STAGE.ENDED

	local winner
	if teamTickets[1] > teamTickets[2] then
		winner = 1
	elseif teamTickets[2] > teamTickets[1] then
		winner = 2
	else
		winner = 0
	end

	for _, player in ipairs(Players:GetPlayers()) do
		Network.MatchEnd.Fire(player, winner, teamTickets[1], teamTickets[2])
	end

	print(string.format("[MatchManager] Match ended. Winner: %d — restart in %ds", winner, RESTART_DELAY))

	-- Schedule automatic restart
	stage = STAGE.RESTARTING
	task.delay(RESTART_DELAY, doRestart)
end

-- ── Team readiness check ──────────────────────────────────────────────
local function teamsReady(): boolean
	local counts: { [number]: number } = { [1] = 0, [2] = 0 }
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Team then
			local idx = TEAM_NAME_TO_INDEX[player.Team.Name]
			if idx then counts[idx] += 1 end
		end
	end
	return counts[1] >= 1 and counts[2] >= 1
end

-- ── Heartbeat ─────────────────────────────────────────────────────────
RunService.Heartbeat:Connect(function(dt)
	if stage == STAGE.WAITING then
		if teamsReady() then startIntermission() end
		return
	end

	-- RESTARTING: passive wait — doRestart is handled by task.delay in endMatch
	if stage == STAGE.RESTARTING or stage == STAGE.ENDED then return end

	if needsBroadcast then
		needsBroadcast = false
		broadcastUpdate()
	end

	stageTimer = math.max(0, stageTimer - dt)

	if stage == STAGE.INTERMISSION then
		intermissionBroadcastAccum += dt
		if intermissionBroadcastAccum >= 1 then
			intermissionBroadcastAccum -= 1
			broadcastIntermission()
		end
		if stageTimer <= 0 then startMatch() end
		return
	end

	if stage == STAGE.MATCH then
		broadcastAccum += dt
		if broadcastAccum >= BROADCAST_INTERVAL then
			broadcastAccum -= BROADCAST_INTERVAL
			broadcastUpdate()
		end
		if stageTimer <= 0 then endMatch() end
		return
	end
end)

-- Re-enter WAITING if a team empties mid-intermission
Players.PlayerRemoving:Connect(function()
	if stage == STAGE.INTERMISSION then
		task.defer(function()
			if not teamsReady() then
				stage      = STAGE.WAITING
				stageTimer = 0
				print("[MatchManager] Player left during intermission — returning to WAITING.")
			end
		end)
	end
end)

-- Sync late-joining players
Players.PlayerAdded:Connect(function(player)
	task.wait(3)
	if stage == STAGE.WAITING then
		return
	elseif stage == STAGE.INTERMISSION then
		Network.MatchIntermission.Fire(player, math.ceil(stageTimer))
	elseif stage == STAGE.MATCH then
		Network.MatchUpdate.Fire(player, teamTickets[1], teamTickets[2], math.ceil(stageTimer))
	elseif stage == STAGE.ENDED or stage == STAGE.RESTARTING then
		local w = teamTickets[1] > teamTickets[2] and 1 or (teamTickets[2] > teamTickets[1] and 2 or 0)
		Network.MatchEnd.Fire(player, w, teamTickets[1], teamTickets[2])
	end
end)

-- ── Public API ────────────────────────────────────────────────────────
local function resolveTeam(teamName: string?): number?
	if not teamName then return nil end
	return TEAM_NAME_TO_INDEX[teamName]
end

local function deduct(teamIndex: number?, amount: number)
	if stage ~= STAGE.MATCH then return end
	if not teamIndex then return end
	teamTickets[teamIndex] = math.max(0, teamTickets[teamIndex] - amount)
	needsBroadcast = true
end

function MatchManager.onBotDied(teamName: string?)
	deduct(resolveTeam(teamName), GameSettings.COST_BOT_DEATH)
end

local function fireNotification(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx, eventType, cost)
	local victimName   = victimPlayer   and victimPlayer.Name   or "Unknown"
	local attackerName = attackerPlayer and attackerPlayer.Name or "Unknown"
	local aCompIdx     = attackerCompIdx or 0

	local vc = Color3.fromRGB(200, 200, 200)
	local ac = Color3.fromRGB(200, 200, 200)
	if victimPlayer   and victimPlayer.Team   then vc = victimPlayer.Team.TeamColor.Color   end
	if attackerPlayer and attackerPlayer.Team then ac = attackerPlayer.Team.TeamColor.Color end

	local vColorInt = math.floor(vc.R*255)*65536 + math.floor(vc.G*255)*256 + math.floor(vc.B*255)
	local aColorInt = math.floor(ac.R*255)*65536 + math.floor(ac.G*255)*256 + math.floor(ac.B*255)

	for _, player in ipairs(Players:GetPlayers()) do
		Network.MatchNotification.Fire(
			player,
			victimName,   victimCompIdx,
			attackerName, aCompIdx,
			eventType,    cost,
			vColorInt,    aColorInt
		)
	end
end

function MatchManager.onCompanyBroke(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx)
	local teamName = victimPlayer and victimPlayer.Team and victimPlayer.Team.Name or nil
	deduct(resolveTeam(teamName), GameSettings.COST_BROKE)
	fireNotification(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx, 1, GameSettings.COST_BROKE)
end

function MatchManager.onCompanyOverrun(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx)
	local teamName = victimPlayer and victimPlayer.Team and victimPlayer.Team.Name or nil
	deduct(resolveTeam(teamName), GameSettings.COST_OVERRUN)
	fireNotification(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx, 2, GameSettings.COST_OVERRUN)
end

function MatchManager.syncPlayer(player: Player)
	if stage == STAGE.MATCH then
		Network.MatchUpdate.Fire(player, teamTickets[1], teamTickets[2], math.ceil(stageTimer))
	elseif stage == STAGE.INTERMISSION then
		Network.MatchIntermission.Fire(player, math.ceil(stageTimer))
	elseif stage == STAGE.ENDED or stage == STAGE.RESTARTING then
		local w = teamTickets[1] > teamTickets[2] and 1 or (teamTickets[2] > teamTickets[1] and 2 or 0)
		Network.MatchEnd.Fire(player, w, teamTickets[1], teamTickets[2])
	end
end

return MatchManager
