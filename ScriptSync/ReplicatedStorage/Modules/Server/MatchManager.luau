-->>>>>>>>>>>>
-- MATCH_MANAGER
-- Version 1.1.0
--
-- Stages:
--   WAITING      — fewer than 1 player per team. Holds indefinitely.
--   INTERMISSION — 40 s countdown. Borders still up.
--   MATCH        — 25:00 countdown. Borders removed. Tickets drain.
--   ENDED        — winner shown.
--
-- Border parts: workspace.game.game_border.t1_border / t2_border
-- Set CanCollide/CanQuery/CanTouch = false when match starts.
-->>>>>>>>>>>>

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")
local Network    = require(game.ReplicatedStorage.Blink.Server)
local Teams      = game:GetService("Teams")

-- ── Config ────────────────────────────────────────────────────────────

local STARTING_TICKETS    = 10000
local MATCH_DURATION      = 20 * 60
local INTERMISSION_DURATION = 5
local BROADCAST_INTERVAL  = 10   -- seconds between MatchUpdate fires during match

local COST_BOT_DEATH = 5
local COST_BROKE     = 200
local COST_OVERRUN   = 500

-- Map your actual Roblox Team names here
local TEAM_NAME_TO_INDEX: { [string]: number } = {
	["TEAM 1"] = 1,
	["TEAM 2"] = 2,
}

-- ── Stage enum ────────────────────────────────────────────────────────

local STAGE = {
	WAITING      = "WAITING",
	INTERMISSION = "INTERMISSION",
	MATCH        = "MATCH",
	ENDED        = "ENDED",
}

-- ── State ─────────────────────────────────────────────────────────────

local teamTickets: { [number]: number } = {
	[1] = STARTING_TICKETS,
	[2] = STARTING_TICKETS,
}

local stage                    = STAGE.WAITING
local stageTimer               = 0
local broadcastAccum           = 0
local intermissionBroadcastAccum = 0

-- ── Borders ───────────────────────────────────────────────────────────

local function openBorders()
	local ok, folder = pcall(function()
		return workspace:WaitForChild("game", 5) :WaitForChild("game_border", 5)
	end)
	if not ok or not folder then
		warn("[MatchManager] Could not find workspace.game.game_border")
		return
	end

	for _, name in ipairs({ "t1_border", "t2_border" }) do
		local part = folder:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery   = false
			part.CanTouch   = false
			part.Transparency = 1
		else
			warn("[MatchManager] Border part not found:", name)
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
	stage      = STAGE.INTERMISSION
	stageTimer = INTERMISSION_DURATION
	broadcastIntermission()
	print("[MatchManager] Intermission started.")
end

local function startMatch()
	stage        = STAGE.MATCH
	stageTimer   = MATCH_DURATION
	broadcastAccum = 0

	teamTickets[1] = STARTING_TICKETS
	teamTickets[2] = STARTING_TICKETS

	openBorders()
	broadcastUpdate()
	print("[MatchManager] Match started.")
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

	print("[MatchManager] Match ended. Winner:", winner)
end

-- ── Team readiness check ──────────────────────────────────────────────

local function teamsReady(): boolean
	local counts: { [number]: number } = { [1] = 0, [2] = 0 }
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Team then
			local idx = TEAM_NAME_TO_INDEX[player.Team.Name]
			if idx then
				counts[idx] += 1
			end
		end
	end
	return counts[1] >= 1 and counts[2] >= 1
end

-- ── Heartbeat ─────────────────────────────────────────────────────────

RunService.Heartbeat:Connect(function(dt)
	if stage == STAGE.WAITING then
		if teamsReady() then
			startIntermission()
		end
		return
	end

	stageTimer = math.max(0, stageTimer - dt)

	if stage == STAGE.INTERMISSION then
		intermissionBroadcastAccum += dt
		if intermissionBroadcastAccum >= 1 then
			intermissionBroadcastAccum -= 1
			broadcastIntermission()
		end

		if stageTimer <= 0 then
			startMatch()
		end
		return
	end

	if stage == STAGE.MATCH then
		broadcastAccum += dt
		if broadcastAccum >= BROADCAST_INTERVAL then
			broadcastAccum -= BROADCAST_INTERVAL
			broadcastUpdate()
		end

		if stageTimer <= 0 then
			endMatch()
		end
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
	elseif stage == STAGE.ENDED then
		local winner = teamTickets[1] > teamTickets[2] and 1 or (teamTickets[2] > teamTickets[1] and 2 or 0)
		Network.MatchEnd.Fire(player, winner, teamTickets[1], teamTickets[2])
	end
end)

-- ── Public API ────────────────────────────────────────────────────────

local MatchManager = {}

local function resolveTeam(teamName: string?): number?
	if not teamName then return nil end
	return TEAM_NAME_TO_INDEX[teamName]
end

local function deduct(teamIndex: number?, amount: number)
	if stage ~= STAGE.MATCH then return end
	if not teamIndex then return end
	local prev = teamTickets[teamIndex]
	teamTickets[teamIndex] = math.max(0, prev - amount)
	-- Always broadcast immediately on a deduction so clients see it right away
	broadcastUpdate()
end

function MatchManager.onBotDied(teamName: string?)
	deduct(resolveTeam(teamName), COST_BOT_DEATH)
end

local function fireNotification(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx, eventType, cost)
	local victimName   = victimPlayer   and victimPlayer.Name   or "Unknown"
	local attackerName = attackerPlayer and attackerPlayer.Name or "Unknown"
	local aCompIdx     = attackerCompIdx or 0

	for _, player in ipairs(Players:GetPlayers()) do
		Network.MatchNotification.Fire(
			player,
			victimName,   victimCompIdx,
			attackerName, aCompIdx,
			eventType,    cost
		)
	end
end

function MatchManager.onCompanyBroke(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx)
	local teamName = victimPlayer and victimPlayer.Team and victimPlayer.Team.Name or nil
	deduct(resolveTeam(teamName), COST_BROKE)
	fireNotification(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx, 1, COST_BROKE)
end

function MatchManager.onCompanyOverrun(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx)
	local teamName = victimPlayer and victimPlayer.Team and victimPlayer.Team.Name or nil
	deduct(resolveTeam(teamName), COST_OVERRUN)
	fireNotification(victimPlayer, victimCompIdx, attackerPlayer, attackerCompIdx, 2, COST_OVERRUN)
end

function MatchManager.syncPlayer(player: Player)
	if stage == STAGE.MATCH then
		Network.MatchUpdate.Fire(player, teamTickets[1], teamTickets[2], math.ceil(stageTimer))
	elseif stage == STAGE.INTERMISSION then
		Network.MatchIntermission.Fire(player, math.ceil(stageTimer))
	end
end

return MatchManager