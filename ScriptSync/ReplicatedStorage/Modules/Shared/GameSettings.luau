-->>>>>>>>>>>>
-- GAME_SETTINGS
-- Version 1.1.0
--
-- Central mutable settings table shared between NPC_SYSTEM, MatchManager,
-- and AdminHandler. All values here are the authoritative runtime defaults.
-->>>>>>>>>>>>

local GameSettings = {
	-- ── Bot / Movement ─────────────────────────────────────────────────
	WALK_SPEED    = 15,
	MAX_BOTS      = 35,
	MAX_COMPANIES = 1,

	-- ── Company Tickets ─────────────────────────────────────────────────
	MAX_TICKETS            = 135,
	TICKET_REGEN_RATE      = 5,
	TICKET_REGEN_INTERVAL  = 6,
	TICKET_DECAY_RATE      = 6,
	TICKET_DECAY_INTERVAL  = 5,
	TICKET_COST_STATIONARY = 2,
	TICKET_COST_MOVING     = 4,
	BROKEN_RECOVERY_TIME   = 20,
	BEARER_NEARBY_RADIUS   = 120,
	BEARER_REPLACE_DELAY   = 3,

	-- ── Ranged Combat ──────────────────────────────────────────────────
	COMBAT_RANGE  = 400,
	MUSKET_DAMAGE = 100,
	BULLET_SPREAD = 2.5,      -- degrees

	-- ── Melee ──────────────────────────────────────────────────────────
	MELEE_ENGAGE_RANGE      = 7,
	MELEE_DAMAGE            = 50,
	MELEE_BEARER_FLEE_RANGE = 30,
	MELEE_BEARER_FLEE_DIST  = 20,

	-- ── Match ──────────────────────────────────────────────────────────
	STARTING_TICKETS      = 10000,
	MATCH_DURATION        = 15 * 60,   -- seconds
	INTERMISSION_DURATION = 15,
	COST_BOT_DEATH        = 5,
	COST_BROKE            = 200,
	COST_OVERRUN          = 500,

	-- ── Flag System ────────────────────────────────────────────────────
	-- How close an NPC must be (studs) to pick up a dropped flag.
	FLAG_PICKUP_RADIUS  = 5,
	-- Seconds an enemy must hold a flag before it is fully captured.
	FLAG_CAPTURE_TIME   = 20,
	-- Maximum number of enemy NPCs that will break off to capture a dropped flag.
	FLAG_CAPTURE_BOTS   = 2,
	-- If a friendly pickup NPC dies without reaching the flag, this is the
	-- cooldown (seconds) before another one is assigned.
	FLAG_REASSIGN_DELAY = 2,
}

return GameSettings
