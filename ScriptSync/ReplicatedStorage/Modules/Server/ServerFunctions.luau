-->>>>>>>>>>>>
-- SERVER_FUNCTIONS
-- Version 1.1.0
-->>>>>>>>>>>>

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NpcConstants      = require(ReplicatedStorage.Modules.Shared.NpcConstants)

local Network           = require(game.ReplicatedStorage.Blink.Server)
local RegimentFormation = require(ReplicatedStorage.Modules.Shared.RegimentFormation)
local MatchManager      = require(ReplicatedStorage.Modules.Server.Modules.MatchManager)
local GameSettings      = require(ReplicatedStorage.Modules.Shared.GameSettings)

local ServerFunctions = {}

function ServerFunctions.init(ctx)

	-- ── Shared state ───────────────────────────────────────────────────────
	local activeNpcs      = ctx.activeNpcs
	local companies       = ctx.companies
	local serverCanAttack = ctx.serverCanAttack
	local readyPlayers    = ctx.readyPlayers
	local farLastSent     = ctx.farLastSent
	local combatRayParams = ctx.combatRayParams

	-- ── NPC_SYSTEM function references ─────────────────────────────────────
	local spawnNpc      = ctx.spawnNpc
	local syncCompanies = ctx.syncCompanies
	local getYaw        = ctx.getYaw

	-- ── Constants ─────────────────────────────────────────────────────────
	-- C aliases NpcConstants so existing C.X references throughout this
	local C = NpcConstants

	-- ── Forward declarations ───────────────────────────────────────────────
	local applyDamage
	local setNpcMeleeState
	local setNpcWeaponState
	local killNpc
	local replaceBearer
	local flushRespawnQueue

	-- ── Internal helpers ───────────────────────────────────────────────────

	local function getBearerTarget(npc, comp)
		local anchorCF   = comp.anchorCF
		local halfWidth  = ((comp.files - 1) * C.RANK_SPACING) / 2
		local totalDepth = (comp.ranks - 1) * C.RANK_DEPTH
		local dynamicZ   = totalDepth + C.FLAG_OFFSET_Z
		local mode       = npc.BearerMode
		if mode == C.BEARER_MODE_LEFT then
			return anchorCF * CFrame.new(-(halfWidth + C.BEARER_SIDE_OFFSET_X), 0, C.BEARER_SIDE_OFFSET_Z)
		elseif mode == C.BEARER_MODE_RIGHT then
			return anchorCF * CFrame.new(halfWidth + C.BEARER_SIDE_OFFSET_X, 0, C.BEARER_SIDE_OFFSET_Z)
		elseif mode == C.BEARER_MODE_PACING then
			return anchorCF * CFrame.new(halfWidth * npc.PaceDirection, 0, dynamicZ)
		else
			return anchorCF * CFrame.new(0, 0, dynamicZ)
		end
	end

	local function isEnemyBearerNearby(player, companyIndex)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return false end
		local ourBearerPos
		for _, sid in ipairs(comp.slots) do
			local npc = activeNpcs[sid]
			if npc and npc.IsFlagBearer then
				ourBearerPos = npc.Root.Position
				break
			end
		end
		if not ourBearerPos then return false end
		for otherPlayer, otherComps in pairs(companies) do
			if otherPlayer == player then continue end
			if otherPlayer.Team and player.Team and otherPlayer.Team == player.Team then continue end
			for _, otherComp in pairs(otherComps) do
				for _, sid in ipairs(otherComp.slots) do
					local npc = activeNpcs[sid]
					if npc and npc.IsFlagBearer and npc.Root then
					if (npc.Root.Position - ourBearerPos).Magnitude <= GameSettings.BEARER_NEARBY_RADIUS then
							return true
						end
					end
				end
			end
		end
		return false
	end

	local function broadcastStrength(player, companyIndex)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return end
		local enemyNear = isEnemyBearerNearby(player, companyIndex)
		for p in pairs(readyPlayers) do
			Network.NpcCompanyStrength.Fire(
				p, companyIndex, comp.tickets, comp.isBroken,
				player.UserId, comp.brokenTimer, enemyNear
			)
		end
	end

	-- ── Core functions ─────────────────────────────────────────────────────

	applyDamage = function(targetNpc, damage, attackerNpc)
		if not targetNpc or not activeNpcs[targetNpc.ShortId] then return end
		if targetNpc.Health <= 0 or targetNpc._dying then return end

		if attackerNpc then
			local comp = companies[targetNpc.CompanyOwner]
				and companies[targetNpc.CompanyOwner][targetNpc.CompanyIndex]
			if comp then
				comp.lastAttackerPlayer  = attackerNpc.CompanyOwner
				comp.lastAttackerCompIdx = attackerNpc.CompanyIndex
			end
		end

		targetNpc.Health -= damage

		if targetNpc.Health <= 0 then
			targetNpc._dying = true
			killNpc(targetNpc.ShortId)
		end
	end

	setNpcMeleeState = function(npc, state)
		if npc.MeleeState == state then return end

		npc.MeleeState = state
		npc._meleePathAccum = 0

		npc.MeleeTimer = (C.MELEE_DURATIONS[state] or 0) + (math.random() * 0.2)

		-- Reset hit flag on any state that begins a fresh attack sequence
		-- (includes IDLE so survivors reset properly when their company re-engages)
		if state == C.MELEE_BOT_START or state == C.MELEE_UP_START or state == C.MELEE_IDLE then
			npc.MeleeHasHit = false
		end

		for p in pairs(readyPlayers) do
			Network.NpcMeleeState.Fire(p, npc.ShortId, state)
		end

		if (state == C.MELEE_BOT_ATK or state == C.MELEE_UP_ATK) and npc.MeleeTarget and not npc.MeleeHasHit then
			local target = npc.MeleeTarget
			if target and activeNpcs[target.ShortId] then
				local dist = (target.Root.Position - npc.Root.Position).Magnitude
				if dist <= (GameSettings.MELEE_ENGAGE_RANGE + 3.5) then
					applyDamage(target, GameSettings.MELEE_DAMAGE, npc)
					npc.MeleeHasHit = true
				end
			end
		end

		if npc.MeleeTarget and (state == C.MELEE_BOT_ATK or state == C.MELEE_UP_ATK) then
			local tPos = npc.MeleeTarget.Root and npc.MeleeTarget.Root.Position
			if tPos then
				local dir = Vector3.new(tPos.X - npc.Root.Position.X, 0, tPos.Z - npc.Root.Position.Z).Unit
				npc.AimAlign.CFrame = CFrame.lookAt(npc.Root.Position, npc.Root.Position + dir)
			end
		end
	end

	setNpcWeaponState = function(npc, state, targetPos)
		npc.WeaponState = state
		npc.WeaponTimer = C.WEAPON_DURATIONS[state] or 0

		if state == C.WEAPON_TO_AIM then
			npc.AimAlign.Enabled = true
		elseif state == C.WEAPON_FIRE or state == C.WEAPON_IDLE then
			npc.AimAlign.Enabled = false
		end

		if state == C.WEAPON_FIRE and targetPos then
			if npc.CompanyOwner then
				Network.NpcFire.Fire(npc.CompanyOwner, npc.ShortId, targetPos)
			else
				local origin    = npc.Root.Position + Vector3.new(0, 1.5, 0)
				local direction = (targetPos - origin).Unit
				local spreadRad = math.rad(GameSettings.BULLET_SPREAD)
				local spreadCF  = CFrame.lookAt(Vector3.zero, direction) * CFrame.Angles((math.random()-0.5)*spreadRad, (math.random()-0.5)*spreadRad, 0)
				local finalDir  = spreadCF.LookVector

				combatRayParams.FilterDescendantsInstances = { npc.Model }

				local result = workspace:Raycast(origin, finalDir * GameSettings.COMBAT_RANGE, combatRayParams)
				local actualHitPos = origin + finalDir * GameSettings.COMBAT_RANGE
				if result then
					actualHitPos = result.Position
					local target = npc.WeaponTarget
					if target and target.Model and (result.Instance == target.Root or result.Instance.Name == "Torso") then
						applyDamage(target, GameSettings.MUSKET_DAMAGE, npc)
					end
				end

				for p in pairs(readyPlayers) do
					Network.NpcFire.Fire(p, npc.ShortId, actualHitPos)
				end
			end
		end

		for p in pairs(readyPlayers) do
			Network.NpcWeaponState.Fire(p, npc.ShortId, state)
		end
	end

	killNpc = function(shortId)
		local npc = activeNpcs[shortId]
		if not npc then return end
		local wasBearer  = npc.IsFlagBearer
		local deadPos    = npc.Root.Position
		local wasWalking = npc.Humanoid and npc.Humanoid.MoveDirection.Magnitude > 0.05
		local owner      = npc.CompanyOwner
		local compIdx    = npc.CompanyIndex

		if npc.Pathfinder then npc.Pathfinder:Destroy() end
		if npc.Model      then npc.Model:Destroy() end

		if not owner or not compIdx then activeNpcs[shortId] = nil return end
		local comp = companies[owner] and companies[owner][compIdx]
		if not comp then return end

		for i = #comp.slots, 1, -1 do
			if comp.slots[i] == shortId then
				table.remove(comp.slots, i)
				MatchManager.onBotDied(npc.TeamName)
				if #comp.slots == 0 then
					MatchManager.onCompanyOverrun(owner, compIdx, comp.lastAttackerPlayer, comp.lastAttackerCompIdx)
				end
				break
			end
		end

		if wasBearer then
			comp.savedBearerMode   = npc.BearerMode or C.BEARER_MODE_CENTER
			comp.savedBearerPacing = npc.IsPacing   or false
			replaceBearer(owner, compIdx, deadPos)
		else
			local soldierIds = {}
			for _, sid in ipairs(comp.slots) do
				local s = activeNpcs[sid]
				if s and not s.IsFlagBearer then soldierIds[#soldierIds+1] = sid end
			end
			local soldierCount = #soldierIds
			if not comp.isMelee and soldierCount > 0 and comp.anchorCF then
				local slots = RegimentFormation.getSlots(comp.anchorCF, soldierCount, comp.ranks, comp.files)
				for i, sid in ipairs(soldierIds) do
					local s = activeNpcs[sid]
					if not s then continue end
					s.RegimentTarget = slots[i].Position
					s.MoveRetries    = 0
					task.spawn(function()
						if s.ActiveTween then s.ActiveTween:Cancel() s.ActiveTween = nil end
						s.Pathfinder:Stop()
						s.Pathfinder:Run(slots[i].Position)
					end)
				end
			elseif comp.isMelee and soldierCount > 0 then
				for _, sid in ipairs(soldierIds) do
					local s = activeNpcs[sid]
					if not s then continue end
					s.MeleeTarget  = nil
					s.MeleeHasHit  = false
					setNpcMeleeState(s, C.MELEE_IDLE)
				end
			end
		end

		local cost = wasWalking and GameSettings.TICKET_COST_MOVING or GameSettings.TICKET_COST_STATIONARY
		if not comp.isBroken then
			comp.tickets = math.max(0, comp.tickets - cost)
			if comp.tickets <= 0 then
				comp.isBroken             = true
				comp.brokenTimer          = GameSettings.BROKEN_RECOVERY_TIME
				comp.brokenBroadcastAccum = 0
				MatchManager.onCompanyBroke(owner, compIdx, comp.lastAttackerPlayer, comp.lastAttackerCompIdx)
			end
			broadcastStrength(owner, compIdx)
		end

		if not comp.respawnQueue then comp.respawnQueue = {} end
		table.insert(comp.respawnQueue, os.clock())
		syncCompanies(owner)
	end

	replaceBearer = function(player, companyIndex, deadBearerPos)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return end
		if not comp.slots or #comp.slots == 0 then return end

		comp.bearerRespawnGate = true

		local candidates = {}
		for _, sid in ipairs(comp.slots) do
			local npc = activeNpcs[sid]
			if npc and not npc.IsFlagBearer then candidates[#candidates+1] = sid end
		end

		if #candidates == 0 then
			task.delay(GameSettings.BEARER_REPLACE_DELAY, function()
				if companies[player] and companies[player][companyIndex] then
					comp.bearerRespawnGate = false
				end
			end)
			return
		end

		local chosenId  = candidates[math.random(1, #candidates)]
		local chosenNpc = activeNpcs[chosenId]
		if not chosenNpc then
			task.delay(GameSettings.BEARER_REPLACE_DELAY, function()
				if companies[player] and companies[player][companyIndex] then
					comp.bearerRespawnGate = false
				end
			end)
			return
		end

		chosenNpc.IsFlagBearer   = true
		chosenNpc.BearerMode     = comp.savedBearerMode  or C.BEARER_MODE_CENTER
		chosenNpc.IsPacing       = comp.savedBearerPacing or false
		chosenNpc.PaceDirection  = 1
		chosenNpc.WeaponState    = C.WEAPON_IDLE
		chosenNpc.WeaponTimer    = 0
		chosenNpc.WeaponTarget   = nil
		chosenNpc.AimAlign.Enabled = false

		for p in pairs(readyPlayers) do
			Network.NpcWeaponState.Fire(p, chosenId, C.WEAPON_IDLE)
			Network.NpcBecomeBearer.Fire(p, chosenId)
		end

		chosenNpc.RegimentTarget = deadBearerPos
		chosenNpc.MoveRetries    = 0

		task.spawn(function()
			if chosenNpc.ActiveTween then chosenNpc.ActiveTween:Cancel() chosenNpc.ActiveTween = nil end
			chosenNpc.Pathfinder:Stop()
			chosenNpc.Pathfinder:Run(deadBearerPos)
		end)

		local soldierIds = {}
		for _, sid in ipairs(comp.slots) do
			local s = activeNpcs[sid]
			if s and not s.IsFlagBearer then soldierIds[#soldierIds+1] = sid end
		end

		local soldierCount = #soldierIds
		if not comp.isMelee and soldierCount > 0 and comp.anchorCF then
			local files = comp.originalFiles or comp.files
			local ranks = comp.originalRanks or comp.ranks
			local slots = RegimentFormation.getSlots(comp.anchorCF, soldierCount, ranks, files)
			for i, sid in ipairs(soldierIds) do
				local s = activeNpcs[sid]
				if not s then continue end
				s.RegimentTarget = slots[i].Position
				s.MoveRetries    = 0

				task.spawn(function()
					if s.ActiveTween then s.ActiveTween:Cancel() s.ActiveTween = nil end
					s.Pathfinder:Stop()
					s.Pathfinder:Run(slots[i].Position)
				end)
			end
		end

		task.delay(GameSettings.BEARER_REPLACE_DELAY, function()
			if companies[player] and companies[player][companyIndex] then
				comp.bearerRespawnGate = false
			end
		end)
	end

	flushRespawnQueue = function(player, companyIndex)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return end
		if comp.isBroken          then return end
		if comp.bearerRespawnGate then return end
		if comp.isRespawning      then return end
		if not comp.respawnQueue or #comp.respawnQueue == 0 then return end

		local bearerPos
		for _, sid in ipairs(comp.slots) do
			local npc = activeNpcs[sid]
			if npc and npc.IsFlagBearer then bearerPos = npc.Root.Position; break end
		end

		bearerPos = bearerPos or (comp.anchorCF and comp.anchorCF.Position)
		if not bearerPos then return end
		local currentTime = os.clock()
		local RESPAWN_DELAY = 3
		local readyIndex

		for i, deathTime in ipairs(comp.respawnQueue) do
			if currentTime - deathTime >= RESPAWN_DELAY then readyIndex = i; break end
		end

		if not readyIndex then return end
		table.remove(comp.respawnQueue, readyIndex)
		comp.isRespawning = true

		task.spawn(function()
			local offset  = Vector3.new(math.random(-3,3), 4, math.random(-3,3))
			local spawnCF = CFrame.new(bearerPos + offset)
			local npc, data = spawnNpc(spawnCF, true, player, companyIndex)
			if npc and companies[player] and companies[player][companyIndex] then
				local c = companies[player][companyIndex]
				local isNewBearer = (#c.slots == 0)
				npc.IsRegiment     = true
				npc.CompanyOwner   = player
				npc.RegimentFacing = c.anchorCF and c.anchorCF.LookVector or Vector3.new(0,0,-1)
				npc.CompanyIndex   = companyIndex

				if isNewBearer then
					npc.IsFlagBearer  = true
					npc.BearerMode    = c.savedBearerMode  or C.BEARER_MODE_CENTER
					npc.IsPacing      = c.savedBearerPacing or false
					npc.PaceDirection = 1
					npc.WeaponState   = C.WEAPON_IDLE
					npc.WeaponTimer   = 0
					npc.WeaponTarget  = nil
					npc.AimAlign.Enabled = false
				elseif c.isMelee then
					npc.MeleeState  = C.MELEE_IDLE
					npc.MeleeTimer  = 0
					npc.MeleeTarget = nil
				end

				table.insert(c.slots, npc.ShortId)

				local soldierIds = {}
				for _, sid in ipairs(c.slots) do
					local s = activeNpcs[sid]
					if s and not s.IsFlagBearer then soldierIds[#soldierIds+1] = sid end
				end

				local soldierCount = #soldierIds
				if c.isMelee then
					npc.MeleeTarget = nil
					setNpcMeleeState(npc, C.MELEE_IDLE)
				elseif soldierCount > 0 and c.anchorCF then
					local ranks = c.originalRanks or c.ranks
					local files = c.originalFiles or c.files
					local slots = RegimentFormation.getSlots(c.anchorCF, soldierCount, ranks, files)
					for j, sid in ipairs(soldierIds) do
						local s = activeNpcs[sid]
						if not s then continue end
						s.RegimentTarget = slots[j].Position
						s.MoveRetries    = 0
						task.spawn(function()
							if s.ActiveTween then s.ActiveTween:Cancel() s.ActiveTween = nil end
							s.Pathfinder:Stop()
							s.Pathfinder:Run(slots[j].Position)
						end)
					end
				end

				for p in pairs(readyPlayers) do
					Network.NpcSpawn.Fire(p, {
						Type         = "Single",
						id           = npc.ShortId,
						pos          = npc.Root.CFrame.Position,
						yaw          = getYaw(npc.Root.CFrame),
						teamName     = npc.TeamName,
						isBearer     = isNewBearer,
						companyIndex = npc.CompanyIndex,
						ownerUserId  = player.UserId,
					})
					if not isNewBearer and not c.isMelee then
						Network.NpcWeaponState.Fire(p, npc.ShortId, C.WEAPON_IDLE)
					elseif not isNewBearer and c.isMelee then
						Network.NpcMeleeState.Fire(p, npc.ShortId, C.MELEE_IDLE)
					end
				end
				syncCompanies(player)
			end

			if companies[player] and companies[player][companyIndex] then
				companies[player][companyIndex].isRespawning = false
			end
		end)
	end

	-- ── Process functions ──────────────────────────────────────────────────

	local function processCombat(dt)
		for shortId, npc in pairs(activeNpcs) do
			if npc.IsFlagBearer then continue end
			if not npc.TeamName  then continue end
			local owner      = npc.CompanyOwner
			local companyIdx = npc.CompanyIndex
			if not owner or not companyIdx then continue end
			local canShoot = serverCanAttack[owner] and serverCanAttack[owner][companyIdx]
			local comp     = companies[owner] and companies[owner][companyIdx]
			if comp and comp.isMelee then continue end
			if not canShoot then
				local reloading = npc.WeaponState == C.WEAPON_RELOAD_IDLE or npc.WeaponState == C.WEAPON_RELOAD
				if npc.WeaponState ~= C.WEAPON_IDLE and not reloading then
					setNpcWeaponState(npc, C.WEAPON_IDLE, nil)
					npc.WeaponTarget = nil
				end
				continue
			end

			if npc.WeaponState == C.WEAPON_IDLE then
				local myTeam         = npc.TeamName
				local myPos          = npc.Root.Position
				local enemiesInRange = {}
				for _, other in pairs(activeNpcs) do
					if other ~= npc then
						local otherTeam = other.TeamName
						if otherTeam and otherTeam ~= myTeam then
							local otherPos = other.Root and other.Root.Position
							if otherPos and (otherPos - myPos).Magnitude <= GameSettings.COMBAT_RANGE then
								enemiesInRange[#enemiesInRange+1] = other
							end
						end
					end
				end

				if #enemiesInRange > 0 then
					local enemy = enemiesInRange[math.random(1, #enemiesInRange)]
					npc.WeaponTarget = enemy
					setNpcWeaponState(npc, C.WEAPON_MAKE_READY, nil)
				end
				continue
			end

			npc.WeaponTimer -= dt
			if npc.AimAlign.Enabled and npc.WeaponTarget then
				local aimPos = npc.WeaponTarget.Root and npc.WeaponTarget.Root.Position
				if aimPos then
					local dir = Vector3.new(aimPos.X - npc.Root.Position.X, 0, aimPos.Z - npc.Root.Position.Z).Unit
					npc.AimAlign.CFrame = CFrame.lookAt(npc.Root.Position, npc.Root.Position + dir)
				end
			end

			if npc.WeaponTimer > 0 then continue end

			local target    = npc.WeaponTarget
			local targetPos = target and target.Root and target.Root.Position

			if npc.WeaponState == C.WEAPON_MAKE_READY then
				setNpcWeaponState(npc, C.WEAPON_MAKEREADY_IDLE, nil)
			elseif npc.WeaponState == C.WEAPON_MAKEREADY_IDLE then
				setNpcWeaponState(npc, C.WEAPON_TO_AIM, nil)
			elseif npc.WeaponState == C.WEAPON_TO_AIM then
				setNpcWeaponState(npc, C.WEAPON_AIM_IDLE, nil)
			elseif npc.WeaponState == C.WEAPON_AIM_IDLE then
				if not targetPos then
					npc.WeaponTarget = nil
					setNpcWeaponState(npc, C.WEAPON_IDLE, nil)
				else
					setNpcWeaponState(npc, C.WEAPON_FIRE, targetPos)
				end
			elseif npc.WeaponState == C.WEAPON_FIRE then
				setNpcWeaponState(npc, C.WEAPON_RELOAD_IDLE, nil)
			elseif npc.WeaponState == C.WEAPON_RELOAD_IDLE then
				setNpcWeaponState(npc, C.WEAPON_RELOAD, nil)
			elseif npc.WeaponState == C.WEAPON_RELOAD then
				npc.WeaponTarget = nil
				setNpcWeaponState(npc, C.WEAPON_IDLE, nil)
			end
		end
	end

	local function processTickets(dt)
		for player, playerCompanies in pairs(companies) do
			for compIdx, comp in pairs(playerCompanies) do
				local slotCount = comp.slots and #comp.slots or 0
				if slotCount == 0 then
					if comp.isBroken then
						comp.brokenTimer = math.max(0, comp.brokenTimer - dt)
						if comp.brokenTimer <= 0 then
							comp.isBroken = false
					comp.tickets  = math.floor(GameSettings.MAX_TICKETS / 2)
							broadcastStrength(player, compIdx)
						end
					end
					if comp.respawnQueue and #comp.respawnQueue > 0 then
						flushRespawnQueue(player, compIdx)
					end
					continue
				end

				if comp.isBroken then
					if comp.brokenTimer > 0 then
						comp.brokenTimer = math.max(0, comp.brokenTimer - dt)
					end
					comp.brokenBroadcastAccum = (comp.brokenBroadcastAccum or 0) + dt
					if comp.brokenBroadcastAccum >= 1 then
						comp.brokenBroadcastAccum -= 1
						broadcastStrength(player, compIdx)
					end
					if comp.brokenTimer <= 0 and not isEnemyBearerNearby(player, compIdx) then
						comp.isBroken             = false
					comp.tickets              = math.floor(GameSettings.MAX_TICKETS / 2)
						comp.regenAccum           = 0
						comp.decayAccum           = 0
						comp.brokenBroadcastAccum = 0
						broadcastStrength(player, compIdx)
					end
				else
					comp.regenAccum = (comp.regenAccum or 0) + dt
				if comp.regenAccum >= GameSettings.TICKET_REGEN_INTERVAL then
					comp.regenAccum -= GameSettings.TICKET_REGEN_INTERVAL
						local prev = comp.tickets
					comp.tickets = math.min(GameSettings.MAX_TICKETS, comp.tickets + GameSettings.TICKET_REGEN_RATE)
						if comp.tickets ~= prev then broadcastStrength(player, compIdx) end
					end

					if isEnemyBearerNearby(player, compIdx) then
						comp.decayAccum = (comp.decayAccum or 0) + dt
					if comp.decayAccum >= GameSettings.TICKET_DECAY_INTERVAL then
						comp.decayAccum -= GameSettings.TICKET_DECAY_INTERVAL
							local prev = comp.tickets
						comp.tickets = math.max(0, comp.tickets - GameSettings.TICKET_DECAY_RATE)
							if comp.tickets ~= prev then
								if comp.tickets <= 0 then
									comp.isBroken             = true
								comp.brokenTimer          = GameSettings.BROKEN_RECOVERY_TIME
									comp.brokenBroadcastAccum = 0
									MatchManager.onCompanyBroke(player, compIdx, comp.lastAttackerPlayer, comp.lastAttackerCompIdx)
								end
								broadcastStrength(player, compIdx)
							end
						end
					end

					if comp.respawnQueue and #comp.respawnQueue > 0 then
						flushRespawnQueue(player, compIdx)
					end
				end
			end
		end
	end

	local function processMelee(dt)
		for player, playerCompanies in pairs(companies) do
			for compIdx, comp in pairs(playerCompanies) do
				if not comp.isMelee then continue end
				local soldierCenter = Vector3.zero
				local validSoldiers = 0

				for _, sid in ipairs(comp.slots) do
					local n = activeNpcs[sid]
					if n and n.Root and not n.IsFlagBearer then
						soldierCenter += n.Root.Position
						validSoldiers += 1
					end
				end

				if validSoldiers > 0 then soldierCenter /= validSoldiers end
				local targetComp = comp.meleeTargetPlayer and companies[comp.meleeTargetPlayer] and companies[comp.meleeTargetPlayer][comp.meleeTargetCompIdx]
				for _, shortId in ipairs(comp.slots) do
					local npc = activeNpcs[shortId]
					if not (npc and npc.Root and npc.Model and npc.Model.Parent) then continue end
					if npc.IsFlagBearer then
						local movePos = (validSoldiers > 0) and soldierCenter or npc.Root.Position
						npc._meleePathAccum = (npc._meleePathAccum or 0) + dt
						if targetComp then
							local nearestEnemyPos
							local nearestDist = math.huge
							for _, eSid in ipairs(targetComp.slots) do
								local e = activeNpcs[eSid]
								if e and e.Root then
									local d = (e.Root.Position - npc.Root.Position).Magnitude
									if d < nearestDist and d < GameSettings.MELEE_BEARER_FLEE_RANGE then
										nearestDist = d
										nearestEnemyPos = e.Root.Position
									end
								end
							end
							if nearestEnemyPos then
								local fleeDir = (npc.Root.Position - nearestEnemyPos).Unit
								movePos = npc.Root.Position + fleeDir * GameSettings.MELEE_BEARER_FLEE_DIST
							end
						end
						if npc._meleePathAccum >= 0.4 and (npc.Root.Position - movePos).Magnitude > 4 then
							npc._meleePathAccum = 0
							npc.Pathfinder:Run(movePos)
						end
						continue
					end
					npc.MeleeTimer -= dt
					if npc.MeleeTarget and not activeNpcs[npc.MeleeTarget.ShortId] then
						npc.MeleeTarget = nil
						setNpcMeleeState(npc, C.MELEE_IDLE)
					end
					if npc.MeleeState == C.MELEE_IDLE then
						if not targetComp then continue end
						local nearest, nearestDist = nil, math.huge
						for _, eSid in ipairs(targetComp.slots) do
							local e = activeNpcs[eSid]
							if e then
								local d = (e.Root.Position - npc.Root.Position).Magnitude
								if d < nearestDist then nearestDist = d; nearest = e end
							end
						end
						if nearest then
							npc.MeleeTarget = nearest
							setNpcMeleeState(npc, math.random() < 0.5 and C.MELEE_BOT_START or C.MELEE_UP_START)
						end
					elseif npc.MeleeState == C.MELEE_ADVANCE then
						if not npc.MeleeTarget then setNpcMeleeState(npc, C.MELEE_IDLE); continue end
						setNpcMeleeState(npc, math.random() < 0.5 and C.MELEE_BOT_START or C.MELEE_UP_START)
					elseif npc.MeleeState == C.MELEE_BOT_START then
						if npc.MeleeTarget and npc.MeleeTarget.Root then
							npc._meleePathAccum += dt
							if npc._meleePathAccum >= 0.4 then
								npc._meleePathAccum = 0
								npc.Pathfinder:Run(npc.MeleeTarget.Root.Position)
							end
						end
						if npc.MeleeTimer <= 0 then setNpcMeleeState(npc, C.MELEE_BOT_IDLE) end
					elseif npc.MeleeState == C.MELEE_BOT_IDLE then
						if not npc.MeleeTarget or not npc.MeleeTarget.Root then setNpcMeleeState(npc, C.MELEE_IDLE); continue end
						local dist = (npc.MeleeTarget.Root.Position - npc.Root.Position).Magnitude
						npc._meleePathAccum += dt
						if npc._meleePathAccum >= 0.4 then
							npc._meleePathAccum = 0
							npc.Pathfinder:Run(npc.MeleeTarget.Root.Position)
						end
						if dist <= GameSettings.MELEE_ENGAGE_RANGE then
							npc.Pathfinder:Stop()
							setNpcMeleeState(npc, C.MELEE_BOT_ATK)
						end
					elseif npc.MeleeState == C.MELEE_BOT_ATK then
						if npc.MeleeTimer <= 0 then setNpcMeleeState(npc, C.MELEE_BACKPEDAL) end
					elseif npc.MeleeState == C.MELEE_UP_START then
						if npc.MeleeTarget and npc.MeleeTarget.Root then
							npc._meleePathAccum += dt
							if npc._meleePathAccum >= 0.4 then
								npc._meleePathAccum = 0
								npc.Pathfinder:Run(npc.MeleeTarget.Root.Position)
							end
						end
						if npc.MeleeTimer <= 0 then setNpcMeleeState(npc, C.MELEE_UP_IDLE) end
					elseif npc.MeleeState == C.MELEE_UP_IDLE then
						if not npc.MeleeTarget or not npc.MeleeTarget.Root then setNpcMeleeState(npc, C.MELEE_IDLE); continue end
						local dist = (npc.MeleeTarget.Root.Position - npc.Root.Position).Magnitude
						npc._meleePathAccum += dt
						if npc._meleePathAccum >= 0.4 then
							npc._meleePathAccum = 0
							npc.Pathfinder:Run(npc.MeleeTarget.Root.Position)
						end
						if dist <= GameSettings.MELEE_ENGAGE_RANGE then
							npc.Pathfinder:Stop()
							setNpcMeleeState(npc, C.MELEE_UP_ATK)
						end
					elseif npc.MeleeState == C.MELEE_UP_ATK then
						if npc.MeleeTimer <= 0 then setNpcMeleeState(npc, C.MELEE_BACKPEDAL) end
					elseif npc.MeleeState == C.MELEE_BACKPEDAL then
						if npc.MeleeTarget and npc.MeleeTarget.Root then
							npc._meleePathAccum += dt
							if npc._meleePathAccum >= 0.2 then
								npc._meleePathAccum = 0
								local fleeDir = (npc.Root.Position - npc.MeleeTarget.Root.Position).Unit
								npc.Pathfinder:Run(npc.Root.Position + fleeDir * 8)
							end
						end
						if npc.MeleeTimer <= 0 then
							setNpcMeleeState(npc, math.random() < 0.5 and C.MELEE_BOT_START or C.MELEE_UP_START)
						end
					end
				end
			end
		end
	end

	-- ── Return public API ──────────────────────────────────────────────────
	return {
		applyDamage         = applyDamage,
		setNpcMeleeState    = setNpcMeleeState,
		setNpcWeaponState   = setNpcWeaponState,
		killNpc             = killNpc,
		replaceBearer       = replaceBearer,
		flushRespawnQueue   = flushRespawnQueue,
		processCombat       = processCombat,
		processTickets      = processTickets,
		processMelee        = processMelee,
		broadcastStrength   = broadcastStrength,
		isEnemyBearerNearby = isEnemyBearerNearby,
		getBearerTarget     = getBearerTarget,
	}
end

return ServerFunctions
