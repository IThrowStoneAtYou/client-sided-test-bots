-->>>>>>>>>>>>
-- SERVER_FUNCTIONS
-- Version 2.0.0
--
-- Flag System additions (v2):
--   • Bearer death → physical flag drops to ground (FlagDropped event)
--   • Friendly NPC nearest the flag is auto-assigned to pick it up
--   • Picked-up friendly → that NPC becomes the new bearer (FlagPickedUp isFriendly=true)
--   • Enemy melee NPCs (up to FLAG_CAPTURE_BOTS) break off to steal the flag
--   • Enemy pickup → 20 s capture timer (FlagPickedUp isFriendly=false + FlagCaptureProgress)
--   • Timer expires  → FlagCaptured fires, company is overrun
--   • Enemy carrier death → flag drops again at that position
--   • Respawn queue is gated until a friendly holds the flag
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
	local C = NpcConstants

	-- ── Ground-detection ray params (used when dropping the flag) ─────────
	local groundRayParams = RaycastParams.new()
	groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
	-- Populated lazily in dropFlag; registries may not exist at module load time.

	-- ── Forward declarations ───────────────────────────────────────────────
	local applyDamage
	local setNpcMeleeState
	local setNpcWeaponState
	local killNpc
	local replaceBearer
	local flushRespawnQueue
	local updateNpcCombat
	local updateNpcMelee

	-- Flag system
	local dropFlag
	local assignFlagPickup
	local friendlyPickupFlag
	local assignEnemyCapture
	local enemyPickupFlag
	local captureFlag
	local updateFlagStates

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

	-- ── Damage / Weapon / Melee ────────────────────────────────────────────

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

		npc.MeleeState       = state
		npc._meleePathAccum  = 0
		npc.MeleeTimer       = (C.MELEE_DURATIONS[state] or 0) + (math.random() * 0.2)

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

	-- ── killNpc ────────────────────────────────────────────────────────────

	killNpc = function(shortId)
		local npc = activeNpcs[shortId]
		if not npc then return end

		local wasBearer        = npc.IsFlagBearer
		local isEnemyCarrier   = npc._isEnemyFlagCarrier
		local carriedFlagOwner = npc._carriedFlagOwner
		local carriedFlagComp  = npc._carriedFlagCompIdx
		local deadPos          = npc.Root.Position
		local wasWalking       = npc.Humanoid and npc.Humanoid.MoveDirection.Magnitude > 0.05
		local owner            = npc.CompanyOwner
		local compIdx          = npc.CompanyIndex
		local role             = npc.Role

		-- BUG FIX: Notify clients IMMEDIATELY when an NPC is killed.
		-- The Heartbeat safety loop misses these because we set activeNpcs[id] = nil below.
		print(string.format("[Server Trace] Firing NpcDespawn for ID: %d", shortId))
		for p in pairs(readyPlayers) do
			Network.NpcDespawn.Fire(p, shortId)
			if farLastSent[p] then farLastSent[p][shortId] = nil end
		end

		-- Clean up flag-seeking state ─────────────────────────────────────
		if npc._goingForFlag then
			local tOwner   = npc._targetFlagOwner   or owner
			local tCompIdx = npc._targetFlagCompIdx or compIdx
			local tComp    = companies[tOwner] and companies[tOwner][tCompIdx]
			if tComp and tComp.flagState then
				local fs = tComp.flagState
				if fs.pickupNpcId == shortId then
					fs.pickupNpcId = nil
				end
				for i = #(fs.captureNpcs or {}), 1, -1 do
					if fs.captureNpcs[i] == shortId then
						table.remove(fs.captureNpcs, i)
						break
					end
				end
			end
		end

		print(string.format("[Server] NPC %d Died (bearer=%s, carrier=%s)", shortId, tostring(wasBearer), tostring(isEnemyCarrier)))
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

		-- ── Bearer died → drop the flag ────────────────────────────────
		if wasBearer then
			comp.savedBearerMode   = npc.BearerMode or C.BEARER_MODE_CENTER
			comp.savedBearerPacing = npc.IsPacing   or false
			dropFlag(owner, compIdx, deadPos)

			-- ── Enemy carrier died → flag re-drops at their position ───────
		elseif isEnemyCarrier and carriedFlagOwner and carriedFlagComp then
			dropFlag(carriedFlagOwner, carriedFlagComp, deadPos)

			-- ── Normal soldier died → reform remaining formation ───────────
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
					if not s or s._goingForFlag then continue end
					s.MeleeTarget = nil
					s.MeleeHasHit = false
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
		table.insert(comp.respawnQueue, { time = os.clock(), role = role })
		syncCompanies(owner)
		activeNpcs[shortId] = nil
	end

	-- ── Flag System ────────────────────────────────────────────────────────

	-->>>>>>>>>>>>
	-- Called when the bearer dies. Raycasts to find the ground below the death
	-- position, places the flag there, and broadcasts FlagDropped to all clients.
	dropFlag = function(player, companyIndex, position)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return end

		-- Ground raycast — exclude server NPC registry so we land on terrain/map.
		groundRayParams.FilterDescendantsInstances = {
			workspace:FindFirstChild("Npc_Registry_Server") or Instance.new("Folder"),
			workspace:FindFirstChild("Npc_Registry")        or Instance.new("Folder"),
		}
		local rayOrigin = position + Vector3.new(0, 3, 0)
		local result    = workspace:Raycast(rayOrigin, Vector3.new(0, -15, 0), groundRayParams)
		local flagPos   = result and result.Position or position

		-- Initialise (or reset) flag state.
		comp.flagState = {
			isDropped        = true,
			isEnemyHeld      = false,
			worldPos         = flagPos,
			holderNpcId      = nil,
			captureAccum     = 0,
			captureBroadcastAccum = 0,
			pickupNpcId      = nil,
			captureNpcs      = {},
			capturingPlayer  = nil,
			capturingCompIdx = nil,
			reassignCooldown = 0,
		}

		-- Gate respawning until a friendly picks the flag up.
		comp.bearerRespawnGate = true

		for p in pairs(readyPlayers) do
			Network.FlagDropped.Fire(p, player.UserId, companyIndex, flagPos)
		end

		print(string.format("[Flag] Company %d of %s dropped flag at %s", companyIndex, player.Name, tostring(flagPos)))

		-- Immediately try to route a friendly to pick it up.
		assignFlagPickup(player, companyIndex)
	end

	-->>>>>>>>>>>>
	-- Finds the nearest available friendly NPC (not bearer, not already tasked)
	-- and routes them to the dropped flag.
	assignFlagPickup = function(player, companyIndex)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return end
		local fs = comp.flagState
		if not fs or not fs.isDropped or fs.isEnemyHeld then return end
		if fs.pickupNpcId and activeNpcs[fs.pickupNpcId] then return end  -- already assigned

		local flagPos = fs.worldPos
		if not flagPos then return end

		local nearest, nearestDist = nil, math.huge
		for _, sid in ipairs(comp.slots) do
			local npc = activeNpcs[sid]
			if not npc or npc.IsFlagBearer or npc._goingForFlag then continue end
			local dist = (npc.Root.Position - flagPos).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearest     = npc
			end
		end

		if nearest then
			nearest._goingForFlag       = "pickup"
			nearest._targetFlagOwner    = player
			nearest._targetFlagCompIdx  = companyIndex
			fs.pickupNpcId              = nearest.ShortId

			-- Stop current combat / melee activity.
			if nearest.WeaponState ~= C.WEAPON_IDLE then
				setNpcWeaponState(nearest, C.WEAPON_IDLE, nil)
			end
			if nearest.MeleeState ~= C.MELEE_IDLE then
				setNpcMeleeState(nearest, C.MELEE_IDLE)
			end

			task.spawn(function()
				if nearest.ActiveTween then nearest.ActiveTween:Cancel() nearest.ActiveTween = nil end
				nearest.Pathfinder:Stop()
				nearest.Pathfinder:Run(flagPos)
			end)

			print(string.format("[Flag] NPC %d assigned to recover flag for %s co%d", nearest.ShortId, player.Name, companyIndex))
		end
	end

	-->>>>>>>>>>>>
	-- Called when a friendly NPC reaches the dropped flag.
	-- Makes them the new bearer, re-forms the company, and opens respawn.
	friendlyPickupFlag = function(player, companyIndex, npc)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return end
		local fs = comp.flagState
		if not fs then return end

		-- Clear all flag-seeking flags for this company's NPCs.
		for _, sid in ipairs(comp.slots) do
			local s = activeNpcs[sid]
			if s then s._goingForFlag = nil; s._targetFlagOwner = nil; s._targetFlagCompIdx = nil end
		end

		-- Mark npc as the new bearer.
		npc._goingForFlag       = nil
		npc.IsFlagBearer        = true
		npc.BearerMode          = comp.savedBearerMode  or C.BEARER_MODE_CENTER
		npc.IsPacing            = comp.savedBearerPacing or false
		npc.PaceDirection       = 1
		npc.WeaponState         = C.WEAPON_IDLE
		npc.WeaponTimer         = 0
		npc.WeaponTarget        = nil
		npc.AimAlign.Enabled    = false

		-- Clear flag state — flag is now "held" again.
		comp.flagState           = {
			isDropped = false, isEnemyHeld = false,
			worldPos  = nil,   holderNpcId = nil,
			captureAccum = 0, captureBroadcastAccum = 0,
			pickupNpcId = nil, captureNpcs = {},
			capturingPlayer = nil, capturingCompIdx = nil,
			reassignCooldown = 0,
		}

		-- Open respawn gate.
		comp.bearerRespawnGate = false

		-- Tell clients: remove dropped model, attach flag to this NPC.
		for p in pairs(readyPlayers) do
			Network.FlagPickedUp.Fire(p, player.UserId, companyIndex, npc.ShortId, true)
			Network.NpcBecomeBearer.Fire(p, npc.ShortId)
			Network.NpcWeaponState.Fire(p, npc.ShortId, C.WEAPON_IDLE)
		end

		-- Move bearer to formation back.
		if comp.anchorCF then
			local targetCF = getBearerTarget(npc, comp)
			npc.RegimentTarget = targetCF.Position
			npc.MoveRetries    = 0
			task.spawn(function()
				if npc.ActiveTween then npc.ActiveTween:Cancel() npc.ActiveTween = nil end
				npc.Pathfinder:Stop()
				npc.Pathfinder:Run(npc.RegimentTarget)
			end)
		end

		-- Reform soldiers around current anchor.
		local soldierIds = {}
		for _, sid in ipairs(comp.slots) do
			local s = activeNpcs[sid]
			if s and not s.IsFlagBearer then soldierIds[#soldierIds+1] = sid end
		end
		if #soldierIds > 0 and comp.anchorCF then
			local files = comp.originalFiles or comp.files
			local ranks = comp.originalRanks or comp.ranks
			local slots = RegimentFormation.getSlots(comp.anchorCF, #soldierIds, ranks, files)
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

		print(string.format("[Flag] NPC %d recovered flag for %s co%d — respawn open", npc.ShortId, player.Name, companyIndex))
	end

	-->>>>>>>>>>>>
	-- Assigns up to FLAG_CAPTURE_BOTS enemy NPCs from the given company to
	-- chase the dropped flag belonging to victimPlayer/victimCompIdx.
	assignEnemyCapture = function(ePlayer, eCompIdx, victimPlayer, victimCompIdx)
		local eComp     = companies[ePlayer]     and companies[ePlayer][eCompIdx]
		local victimComp = companies[victimPlayer] and companies[victimPlayer][victimCompIdx]
		if not eComp or not victimComp then return end

		local fs = victimComp.flagState
		if not fs or not fs.isDropped or fs.isEnemyHeld then return end

		local flagPos = fs.worldPos
		if not flagPos then return end

		-- Count capture NPCs that are still alive and active.
		local activeCapture = {}
		for _, sid in ipairs(fs.captureNpcs or {}) do
			local npc = activeNpcs[sid]
			if npc and npc._goingForFlag == "capture" then
				table.insert(activeCapture, sid)
			end
		end
		fs.captureNpcs = activeCapture

		local needed = GameSettings.FLAG_CAPTURE_BOTS - #activeCapture
		if needed <= 0 then return end

		-- Find idle enemy NPCs to redirect.
		local candidates = {}
		for _, sid in ipairs(eComp.slots) do
			local npc = activeNpcs[sid]
			if not npc or npc.IsFlagBearer or npc._goingForFlag then continue end
			-- Only pull from NPCs that aren't mid-attack swing.
			if npc.MeleeState == C.MELEE_BOT_ATK or npc.MeleeState == C.MELEE_UP_ATK then continue end
			table.insert(candidates, npc)
		end

		-- Closest first.
		table.sort(candidates, function(a, b)
			return (a.Root.Position - flagPos).Magnitude < (b.Root.Position - flagPos).Magnitude
		end)

		for i = 1, math.min(needed, #candidates) do
			local npc = candidates[i]
			npc._goingForFlag      = "capture"
			npc._targetFlagOwner   = victimPlayer
			npc._targetFlagCompIdx = victimCompIdx

			-- Pause any active weapon/melee.
			if npc.WeaponState ~= C.WEAPON_IDLE then
				setNpcWeaponState(npc, C.WEAPON_IDLE, nil)
			end
			setNpcMeleeState(npc, C.MELEE_IDLE)
			npc.MeleeTarget = nil

			task.spawn(function()
				npc.Pathfinder:Stop()
				npc.Pathfinder:Run(flagPos)
			end)

			table.insert(fs.captureNpcs, npc.ShortId)
			fs.capturingPlayer  = ePlayer
			fs.capturingCompIdx = eCompIdx

			print(string.format("[Flag] Enemy NPC %d (%s co%d) sent to capture flag of %s co%d",
				npc.ShortId, ePlayer.Name, eCompIdx, victimPlayer.Name, victimCompIdx))
		end
	end

	-->>>>>>>>>>>>
	-- Called when an enemy NPC reaches and picks up the dropped flag.
	-- Starts the 20 s capture timer.
	enemyPickupFlag = function(ePlayer, eCompIdx, npc, victimPlayer, victimCompIdx)
		local victimComp = companies[victimPlayer] and companies[victimPlayer][victimCompIdx]
		if not victimComp then return end
		local fs = victimComp.flagState
		if not fs or not fs.isDropped then return end

		-- Transfer flag ownership to the enemy NPC.
		npc._isEnemyFlagCarrier = true
		npc._carriedFlagOwner   = victimPlayer
		npc._carriedFlagCompIdx = victimCompIdx
		npc._goingForFlag       = nil  -- done seeking, now carrying

		fs.isDropped     = false
		fs.isEnemyHeld   = true
		fs.holderNpcId   = npc.ShortId
		fs.captureAccum  = 0
		fs.captureBroadcastAccum = 0
		fs.capturingPlayer  = ePlayer
		fs.capturingCompIdx = eCompIdx

		-- Tell clients: remove world model, attach flag to enemy NPC.
		for p in pairs(readyPlayers) do
			Network.FlagPickedUp.Fire(p, victimPlayer.UserId, victimCompIdx, npc.ShortId, false)
		end

		-- Have the enemy carrier walk back toward their anchor.
		local eComp = companies[ePlayer] and companies[ePlayer][eCompIdx]
		if eComp and eComp.anchorCF then
			task.spawn(function()
				npc.Pathfinder:Stop()
				npc.Pathfinder:Run(eComp.anchorCF.Position)
			end)
		end

		print(string.format("[Flag] Enemy NPC %d (%s co%d) picked up flag of %s co%d — capture timer started",
			npc.ShortId, ePlayer.Name, eCompIdx, victimPlayer.Name, victimCompIdx))
	end

	-->>>>>>>>>>>>
	-- Fires when the 20 s capture timer elapses. Permanently eliminates the
	-- victim company by triggering an overrun and cleaning up all flag state.
	captureFlag = function(victimPlayer, victimCompIdx, captorPlayer, captorCompIdx)
		local comp = companies[victimPlayer] and companies[victimPlayer][victimCompIdx]
		if not comp then return end
		local fs = comp.flagState

		-- Clean up enemy carrier NPC.
		if fs and fs.holderNpcId then
			local holder = activeNpcs[fs.holderNpcId]
			if holder then
				holder._isEnemyFlagCarrier = false
				holder._carriedFlagOwner   = nil
				holder._carriedFlagCompIdx = nil
				holder._goingForFlag       = nil
			end
		end

		-- Wipe flag state.
		comp.flagState = {
			isDropped = false, isEnemyHeld = false,
			worldPos  = nil,   holderNpcId = nil,
			captureAccum = 0, captureBroadcastAccum = 0,
			pickupNpcId = nil, captureNpcs = {},
			capturingPlayer = nil, capturingCompIdx = nil,
			reassignCooldown = 0,
		}
		comp.bearerRespawnGate = true  -- no more respawns for this company

		-- Broadcast capture.
		for p in pairs(readyPlayers) do
			Network.FlagCaptured.Fire(p,
				victimPlayer.UserId, victimCompIdx,
				captorPlayer and captorPlayer.UserId or 0,
				captorCompIdx or 0)
		end

		-- Penalise via MatchManager.
		MatchManager.onCompanyOverrun(victimPlayer, victimCompIdx, captorPlayer, captorCompIdx)

		print(string.format("[Flag] %s co%d CAPTURED by %s co%d",
			victimPlayer.Name, victimCompIdx,
			captorPlayer and captorPlayer.Name or "?", captorCompIdx or 0))
	end

	-- ── replaceBearer (kept for edge cases; normally superseded by dropFlag) ──

	replaceBearer = function(player, companyIndex, deadBearerPos)
		-- This is a fallback used only by legacy callers. Normally killNpc calls
		-- dropFlag which routes through the full flag-pickup flow.
		dropFlag(player, companyIndex, deadBearerPos)
	end

	-- ── flushRespawnQueue ─────────────────────────────────────────────────

	flushRespawnQueue = function(player, companyIndex)
		local comp = companies[player] and companies[player][companyIndex]
		if not comp then return end
		if comp.isBroken          then return end
		if comp.bearerRespawnGate then return end   -- flag not yet recovered
		if comp.isRespawning      then return end
		if not comp.respawnQueue or #comp.respawnQueue == 0 then return end

		-- Spawn near the current bearer (flag holder).
		local bearerPos
		for _, sid in ipairs(comp.slots) do
			local npc = activeNpcs[sid]
			if npc and npc.IsFlagBearer then bearerPos = npc.Root.Position; break end
		end
		bearerPos = bearerPos or (comp.anchorCF and comp.anchorCF.Position)
		if not bearerPos then return end

		local currentTime = os.clock()
		local RESPAWN_DELAY = 3
		local readyEntry, readyIndex

		for i, entry in ipairs(comp.respawnQueue) do
			if currentTime - entry.time >= RESPAWN_DELAY then
				readyEntry = entry; readyIndex = i; break
			end
		end

		if not readyIndex or not readyEntry then return end
		table.remove(comp.respawnQueue, readyIndex)
		comp.isRespawning = true

		task.spawn(function()
			local offset  = Vector3.new(math.random(-3,3), 4, math.random(-3,3))
			local spawnCF = CFrame.new(bearerPos + offset)
			local npc, data = spawnNpc(spawnCF, true, player, companyIndex, readyEntry.role)
			if npc and companies[player] and companies[player][companyIndex] then
				local c = companies[player][companyIndex]
				local isNewBearer = (#c.slots == 0)
				npc.IsRegiment     = true
				npc.CompanyOwner   = player
				npc.Role           = readyEntry.role
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

				if c.isMelee then
					npc.MeleeTarget = nil
					setNpcMeleeState(npc, C.MELEE_IDLE)
				elseif #soldierIds > 0 and c.anchorCF then
					local ranks = c.originalRanks or c.ranks
					local files = c.originalFiles or c.files
					local slots = RegimentFormation.getSlots(c.anchorCF, #soldierIds, ranks, files)
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
						role         = npc.Role or "ranker",
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

	updateNpcCombat = function(npc, dt)
		-- Never shoot while pursuing / carrying a flag.
		if npc._goingForFlag or npc._isEnemyFlagCarrier then return end
		if npc.IsFlagBearer then return end
		if not npc.TeamName then return end

		local owner      = npc.CompanyOwner
		local companyIdx = npc.CompanyIndex
		if not owner or not companyIdx then return end

		local canShoot = serverCanAttack[owner] and serverCanAttack[owner][companyIdx]
		local comp     = companies[owner] and companies[owner][companyIdx]
		if comp and comp.isMelee then return end

		if not canShoot then
			local reloading = npc.WeaponState == C.WEAPON_RELOAD_IDLE or npc.WeaponState == C.WEAPON_RELOAD
			if npc.WeaponState ~= C.WEAPON_IDLE and not reloading then
				setNpcWeaponState(npc, C.WEAPON_IDLE, nil)
				npc.WeaponTarget = nil
			end
			return
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
			return
		end

		npc.WeaponTimer -= dt
		if npc.AimAlign.Enabled and npc.WeaponTarget then
			local aimPos = npc.WeaponTarget.Root and npc.WeaponTarget.Root.Position
			if aimPos then
				local dir = Vector3.new(aimPos.X - npc.Root.Position.X, 0, aimPos.Z - npc.Root.Position.Z).Unit
				npc.AimAlign.CFrame = CFrame.lookAt(npc.Root.Position, npc.Root.Position + dir)
			end
		end

		if npc.WeaponTimer > 0 then return end

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

	local function prepareCompanyMetadata()
		for player, playerCompanies in pairs(companies) do
			for _, comp in pairs(playerCompanies) do
				local center = Vector3.zero
				local count  = 0
				for _, sid in ipairs(comp.slots) do
					local n = activeNpcs[sid]
					if n and n.Root and not n.IsFlagBearer then
						center += n.Root.Position
						count  += 1
					end
				end
				comp._cachedCenter = count > 0 and (center / count) or nil
				comp._cachedCount  = count
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

	updateNpcMelee = function(npc, dt)
		-- If this NPC is chasing / carrying a flag, skip normal melee AI.
		-- (The pathfinder was already pointed at the flag in assign/enemyPickup.)
		if npc._goingForFlag or npc._isEnemyFlagCarrier then return end

		local owner = npc.CompanyOwner
		local comp  = owner and companies[owner] and companies[owner][npc.CompanyIndex]
		if not comp or not comp.isMelee then return end

		if npc.IsFlagBearer then
			local soldierCenter = comp._cachedCenter or npc.Root.Position
			local movePos       = soldierCenter
			npc._meleePathAccum = (npc._meleePathAccum or 0) + dt

			local targetComp = comp.meleeTargetPlayer and companies[comp.meleeTargetPlayer] and companies[comp.meleeTargetPlayer][comp.meleeTargetCompIdx]
			if targetComp then
				local nearestEnemyPos
				local nearestDist = math.huge
				for _, eSid in ipairs(targetComp.slots) do
					local e = activeNpcs[eSid]
					if e and e.Root then
						local d = (e.Root.Position - npc.Root.Position).Magnitude
						if d < nearestDist and d < GameSettings.MELEE_BEARER_FLEE_RANGE then
							nearestDist      = d
							nearestEnemyPos  = e.Root.Position
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
			return
		end

		npc.MeleeTimer -= dt
		if npc.MeleeTarget and not activeNpcs[npc.MeleeTarget.ShortId] then
			npc.MeleeTarget = nil
			setNpcMeleeState(npc, C.MELEE_IDLE)
		end

		local targetComp = comp.meleeTargetPlayer and companies[comp.meleeTargetPlayer] and companies[comp.meleeTargetPlayer][comp.meleeTargetCompIdx]

		if npc.MeleeState == C.MELEE_IDLE then
			if not targetComp then return end
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
				
				-- Instant pursuit: don't wait for the 0.4s accumulator to start moving
				if nearest.Root then
					npc.Pathfinder:Run(nearest.Root)
				end
			end
		elseif npc.MeleeState == C.MELEE_ADVANCE then
			if not npc.MeleeTarget then setNpcMeleeState(npc, C.MELEE_IDLE); return end
			setNpcMeleeState(npc, math.random() < 0.5 and C.MELEE_BOT_START or C.MELEE_UP_START)
		elseif npc.MeleeState == C.MELEE_BOT_START or npc.MeleeState == C.MELEE_UP_START then
			if npc.MeleeTimer <= 0 then
				setNpcMeleeState(npc, npc.MeleeState == C.MELEE_BOT_START and C.MELEE_BOT_IDLE or C.MELEE_UP_IDLE)
			end
		elseif npc.MeleeState == C.MELEE_BOT_IDLE or npc.MeleeState == C.MELEE_UP_IDLE then
			if not npc.MeleeTarget or not npc.MeleeTarget.Root then setNpcMeleeState(npc, C.MELEE_IDLE); return end
			local dist = (npc.MeleeTarget.Root.Position - npc.Root.Position).Magnitude
			if dist <= GameSettings.MELEE_ENGAGE_RANGE then
				npc.Pathfinder:Stop()
				setNpcMeleeState(npc, npc.MeleeState == C.MELEE_BOT_IDLE and C.MELEE_BOT_ATK or C.MELEE_UP_ATK)
			end
		elseif npc.MeleeState == C.MELEE_BOT_ATK or npc.MeleeState == C.MELEE_UP_ATK then
			if npc.MeleeTimer <= 0 then setNpcMeleeState(npc, C.MELEE_BACKPEDAL) end
		elseif npc.MeleeState == C.MELEE_BACKPEDAL then
			if npc.MeleeTarget and npc.MeleeTarget.Root then
				-- Only run backpedal path once per state transition to prevent stuttering
				if npc._meleePathAccum == 0 then
					npc._meleePathAccum = 1
					local fleeDir = (npc.Root.Position - npc.MeleeTarget.Root.Position).Unit
					npc.Pathfinder:Run(npc.Root.Position + fleeDir * 8)
				end
			end
			if npc.MeleeTimer <= 0 then
				setNpcMeleeState(npc, math.random() < 0.5 and C.MELEE_BOT_START or C.MELEE_UP_START)
			end
		end
	end

	-->>>>>>>>>>>>
	-- updateFlagStates — call once per heartbeat.
	-- Checks pickup/capture distances and advances capture timers.
	updateFlagStates = function(dt)
		local pickupR  = GameSettings.FLAG_PICKUP_RADIUS
		local captureT = GameSettings.FLAG_CAPTURE_TIME

		for player, playerCompanies in pairs(companies) do
			for compIdx, comp in pairs(playerCompanies) do
				local fs = comp.flagState
				if not fs then continue end
				if not fs.isDropped and not fs.isEnemyHeld then continue end

				-- ── Dropped: check friendly pickup reach ──────────────────
				if fs.isDropped and not fs.isEnemyHeld then
					local flagPos = fs.worldPos
					if not flagPos then continue end

					-- Verify assigned pickup NPC is still alive.
					if fs.pickupNpcId then
						local pNpc = activeNpcs[fs.pickupNpcId]
						if pNpc then
							-- Did they reach the flag?
							if (pNpc.Root.Position - flagPos).Magnitude <= pickupR then
								friendlyPickupFlag(player, compIdx, pNpc)
								continue  -- flag handled, skip rest
							end
							-- Still walking — re-run pathfinder if they stalled.
							pNpc._meleePathAccum = (pNpc._meleePathAccum or 0) + dt
							if pNpc._meleePathAccum >= 2 then
								pNpc._meleePathAccum = 0
								task.spawn(function() pNpc.Pathfinder:Run(flagPos) end)
							end
						else
							-- Dead — reassign after cooldown.
							fs.pickupNpcId = nil
							fs.reassignCooldown = (fs.reassignCooldown or 0) + dt
							if fs.reassignCooldown >= GameSettings.FLAG_REASSIGN_DELAY then
								fs.reassignCooldown = 0
								assignFlagPickup(player, compIdx)
							end
						end
					else
						-- Nobody assigned; try again.
						fs.reassignCooldown = (fs.reassignCooldown or 0) + dt
						if fs.reassignCooldown >= GameSettings.FLAG_REASSIGN_DELAY then
							fs.reassignCooldown = 0
							assignFlagPickup(player, compIdx)
						end
					end

					-- ── Check if any enemy capture NPC reached the flag ──
					for _, eSid in ipairs(fs.captureNpcs or {}) do
						local eNpc = activeNpcs[eSid]
						if eNpc and eNpc.Root then
							if (eNpc.Root.Position - flagPos).Magnitude <= pickupR then
								enemyPickupFlag(eNpc.CompanyOwner, eNpc.CompanyIndex, eNpc, player, compIdx)
								break
							end
						end
					end

					-- ── Auto-assign enemy capture for melee companies ─────
					for ePlayer, eComps in pairs(companies) do
						if ePlayer == player then continue end
						if ePlayer.Team and player.Team and ePlayer.Team == player.Team then continue end
						for eCompIdx, eComp in pairs(eComps) do
							if eComp.isMelee
								and eComp.meleeTargetPlayer == player
								and eComp.meleeTargetCompIdx == compIdx
							then
								assignEnemyCapture(ePlayer, eCompIdx, player, compIdx)
							end
						end
					end
				end

				-- ── Enemy held: advance capture timer ─────────────────────
				if fs.isEnemyHeld then
					local holder = activeNpcs[fs.holderNpcId]
					if not holder then
						-- Carrier was killed; dropFlag was already called from killNpc.
						-- Safety-clear stale state.
						fs.isEnemyHeld  = false
						fs.holderNpcId  = nil
						continue
					end

					fs.captureAccum              += dt
					fs.captureBroadcastAccum      = (fs.captureBroadcastAccum or 0) + dt

					-- Broadcast progress ~once per second.
					if fs.captureBroadcastAccum >= 1 then
						fs.captureBroadcastAccum -= 1
						for p in pairs(readyPlayers) do
							Network.FlagCaptureProgress.Fire(p, player.UserId, compIdx, fs.captureAccum)
						end
					end

					if fs.captureAccum >= captureT then
						captureFlag(player, compIdx, fs.capturingPlayer, fs.capturingCompIdx)
					end
				end
			end
		end
	end

	-- ── Return public API ──────────────────────────────────────────────────
	return {
		applyDamage            = applyDamage,
		setNpcMeleeState       = setNpcMeleeState,
		setNpcWeaponState      = setNpcWeaponState,
		killNpc                = killNpc,
		replaceBearer          = replaceBearer,
		flushRespawnQueue      = flushRespawnQueue,
		updateNpcCombat        = updateNpcCombat,
		updateNpcMelee         = updateNpcMelee,
		prepareCompanyMetadata = prepareCompanyMetadata,
		processTickets         = processTickets,
		broadcastStrength      = broadcastStrength,
		isEnemyBearerNearby    = isEnemyBearerNearby,
		getBearerTarget        = getBearerTarget,
		-- flag system
		dropFlag               = dropFlag,
		assignFlagPickup       = assignFlagPickup,
		friendlyPickupFlag     = friendlyPickupFlag,
		assignEnemyCapture     = assignEnemyCapture,
		enemyPickupFlag        = enemyPickupFlag,
		captureFlag            = captureFlag,
		updateFlagStates       = updateFlagStates,
	}
end

return ServerFunctions
