-->>>>>>>>>>>>
-- TEAM_MANAGER
-- Version 1.0.0
-- Manages team/affiliation detection
-->>>>>>>>>>>>

local TeamManager = {}

-- Team constants
TeamManager.TEAMS = {
	NONE     = 0,
	PLAYER   = 1,
	ENEMY    = 2,
}

-->>>>>>>>>>>>
-- Get team from a model/character
function TeamManager.getTeam(model: Model): number
	if not model then return TeamManager.TEAMS.NONE end
	
	local teamValue = model:FindFirstChild("Team")
	if teamValue and teamValue:IsA("IntValue") then
		return teamValue.Value
	end
	
	return TeamManager.TEAMS.NONE
end

-->>>>>>>>>>>>
-- Set team on a model/character
function TeamManager.setTeam(model: Model, team: number)
	if not model then return end
	
	local teamValue = model:FindFirstChild("Team")
	if not teamValue then
		teamValue = Instance.new("IntValue")
		teamValue.Name = "Team"
		teamValue.Parent = model
	end
	
	teamValue.Value = team
end

-->>>>>>>>>>>>
-- Check if two models are on the same team
function TeamManager.isFriendly(modelA: Model, modelB: Model): boolean
	if not modelA or not modelB then return false end
	
	local teamA = TeamManager.getTeam(modelA)
	local teamB = TeamManager.getTeam(modelB)
	
	return teamA ~= TeamManager.TEAMS.NONE 
		and teamB ~= TeamManager.TEAMS.NONE 
		and teamA == teamB
end

-->>>>>>>>>>>>
-- Check if two models are enemies
function TeamManager.isEnemy(modelA: Model, modelB: Model): boolean
	if not modelA or not modelB then return false end
	
	local teamA = TeamManager.getTeam(modelA)
	local teamB = TeamManager.getTeam(modelB)
	
	return teamA ~= TeamManager.TEAMS.NONE 
		and teamB ~= TeamManager.TEAMS.NONE 
		and teamA ~= teamB
end

return TeamManager
