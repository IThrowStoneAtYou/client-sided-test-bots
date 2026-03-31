-->>>>>>>>>>>>
-- BULLET_MANAGER
-- Version 1.0.0
-- Client-side bullet simulation
-->>>>>>>>>>>>

local RunService = game:GetService("RunService")

local TeamManager = require(game.ReplicatedStorage.Modules.Shared:WaitForChild("TeamManager"))

local BulletManager = {}

-- Bullet config
local BULLET_SPEED   = 150        -- studs per second
local BULLET_SIZE    = Vector3.new(0.2, 0.2, 1)
local BULLET_TIMEOUT = 15         -- max lifetime in seconds
local RAYCAST_RANGE  = 200        -- max raycast distance per frame

local bulletPool    = {}    -- [bullet] = state
local bulletFolder  = nil

-->>>>>>>>>>>>
-- Initialize bullet folder
local function ensureBulletFolder()
	if bulletFolder then return end
	
	bulletFolder = workspace:FindFirstChild("Bullets") or (function()
		local f = Instance.new("Folder")
		f.Name = "Bullets"
		f.Parent = workspace
		print("bullet")
		return f
	end)()
end

-->>>>>>>>>>>>
-- Create a visual bullet part
local function createBulletPart()
	local p = Instance.new("Part")
	p.Shape       = Enum.PartType.Ball
	p.Size        = BULLET_SIZE
	p.Material    = Enum.Material.Neon
	p.Color       = Color3.fromRGB(255, 200, 100)
	p.CanCollide  = false
	p.CanQuery    = false
	p.CFrame      = CFrame.new(0, -500, 0)
	p.TopSurface  = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent      = bulletFolder
	
	return p
end

-->>>>>>>>>>>>
-- Fire a bullet from a source position in a direction
-- sourceModel: the NPC that fired (source of bullet, for team checking)
-- muzzlePos: world position where bullet spawns
-- direction: unit vector direction
function BulletManager.fire(sourceModel: Model, muzzlePos: Vector3, direction: Vector3)
	ensureBulletFolder()
	
	local bullet = createBulletPart()
	local sourceTeam = TeamManager.getTeam(sourceModel)
	
	bulletPool[bullet] = {
		position = muzzlePos,
		direction = direction.Unit,
		velocity = direction.Unit * BULLET_SPEED,
		lifetime = 0,
		sourceModel = sourceModel,
		sourceTeam = sourceTeam,
		isAlive = true,
	}
	
	bullet.CFrame = CFrame.new(muzzlePos)
	
	return bullet
end

-->>>>>>>>>>>>
-- Check what a raycast hits (skipping friendly models)
local function raycastBullet(state, distance)
	local origin = state.position
	local direction = state.direction * distance
	
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	
	-- Build filter list: exclude source and friendlies
	local filterList = { state.sourceModel }
	
	-- Also exclude all bullet parts
	for bullet in pairs(bulletPool) do
		table.insert(filterList, bullet)
	end
	
	rayParams.FilterDescendantsInstances = filterList
	
	local result = workspace:Raycast(origin, direction, rayParams)
	
	if not result then return nil end
	
	local hit = result.Instance
	if not hit then return nil end
	
	-- Find the humanoid (is this an NPC or character?)
	local humanoid = hit.Parent:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end
	
	local hitModel = hit.Parent
	
	-- Skip friendlies
	if TeamManager.isFriendly(state.sourceModel, hitModel) then
		return nil
	end
	
	return {
		position = result.Position,
		instance = hit,
		humanoid = humanoid,
		model = hitModel,
	}
end

-->>>>>>>>>>>>
-- Update all active bullets
local function updateBullets(dt)
	local bulletsToRemove = {}
	
	for bullet, state in pairs(bulletPool) do
		if not state.isAlive then
			bulletsToRemove[#bulletsToRemove + 1] = bullet
			continue
		end
		
		state.lifetime = state.lifetime + dt
		
		-- Check timeout
		if state.lifetime > BULLET_TIMEOUT then
			state.isAlive = false
			bulletsToRemove[#bulletsToRemove + 1] = bullet
			continue
		end
		
		-- Move bullet
		local travel = state.velocity * dt
		local distance = travel.Magnitude
		
		-- Raycast for hits
		local hit = raycastBullet(state, math.min(distance, RAYCAST_RANGE))
		
		if hit then
			-- Hit something!
			state.position = hit.position
			state.isAlive = false
			bulletsToRemove[#bulletsToRemove + 1] = bullet
			
			-- Deal damage
			if hit.humanoid then
				hit.humanoid:TakeDamage(25)
			end
			
			continue
		end
		
		-- Move to new position
		state.position = state.position + travel
		bullet.CFrame = CFrame.new(state.position)
	end
	
	-- Cleanup dead bullets
	for _, bullet in ipairs(bulletsToRemove) do
		if bulletPool[bullet] then
			bulletPool[bullet] = nil
			bullet:Destroy()
		end
	end
end

-- Start update loop
RunService.Heartbeat:Connect(function(dt)
	updateBullets(dt)
end)

return BulletManager
