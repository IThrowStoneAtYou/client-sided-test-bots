-->>>>>>>>>>>>
-- GAME_SETTINGS
-- Version 1.0.0
--
-- Central mutable settings table shared between NPC_SYSTEM, MatchManager,
-- and AdminHandler. All values here are the authoritative runtime defaults.
--
-- Usage:
--   local GameSettings = require(ReplicatedStorage.Modules.Shared.GameSettings)
--   local range = GameSettings.COMBAT_RANGE   -- reads live value
--
-- AdminHandler writes to this table; server systems read from it each frame,
-- so changes take effect immediately without a restart.
-->>>>>>>>>>>>

local GameSettings = {
	-- ── Bot / Movement ─────────────────────────────────────────────────
	WALK_SPEED    = 15,
	MAX_BOTS      = 45,
	MAX_COMPANIES = 4,

	-- ── Ranged Combat ──────────────────────────────────────────────────
	COMBAT_RANGE  = 400,
	MUSKET_DAMAGE = 100,
	BULLET_SPREAD = 3,      -- degrees

	-- ── Melee ──────────────────────────────────────────────────────────
	MELEE_ENGAGE_RANGE      = 7,
	MELEE_DAMAGE            = 50,
	MELEE_BEARER_FLEE_RANGE = 30,
	MELEE_BEARER_FLEE_DIST  = 20,

	-- ── Match ──────────────────────────────────────────────────────────
	STARTING_TICKETS      = 10000,
	MATCH_DURATION        = 20 * 60,   -- seconds
	INTERMISSION_DURATION = 5,
	COST_BOT_DEATH        = 5,
	COST_BROKE            = 200,
	COST_OVERRUN          = 500,
}

return GameSettings
