-->>>>>>>>>>>>
-- NPC_CONSTANTS
-->>>>>>>>>>>>

local NpcConstants = {
	-- ── Spawn / Formation ───────────────────────────────────────────────
	SPAWN_OFFSET  = 16,
	COMPANY_GAP   = 15,
	RANK_SPACING  = 4.7,
	RANK_DEPTH    = 5,
	FLAG_OFFSET_Z = 8,
	MOVE_RETRIES  = 2,

	-- ── Weapon States ───────────────────────────────────────────────────
	WEAPON_IDLE           = 0,
	WEAPON_MAKE_READY     = 1,
	WEAPON_MAKEREADY_IDLE = 2,
	WEAPON_TO_AIM         = 3,
	WEAPON_AIM_IDLE       = 4,
	WEAPON_FIRE           = 5,
	WEAPON_RELOAD_IDLE    = 6,
	WEAPON_RELOAD         = 7,

	-- ── Melee States ────────────────────────────────────────────────────
	MELEE_NONE      = 0,
	MELEE_IDLE      = 1,
	MELEE_BOT_START = 2,
	MELEE_BOT_IDLE  = 3,
	MELEE_BOT_ATK   = 4,
	MELEE_UP_START  = 5,
	MELEE_UP_IDLE   = 6,
	MELEE_UP_ATK    = 7,
	MELEE_ADVANCE   = 8,
	MELEE_BACKPEDAL = 9,

	-- ── Bearer Modes ────────────────────────────────────────────────────
	BEARER_MODE_CENTER   = 0,
	BEARER_MODE_LEFT     = 1,
	BEARER_MODE_RIGHT    = 2,
	BEARER_MODE_PACING   = 3,
	BEARER_SIDE_OFFSET_X = 5,
	BEARER_SIDE_OFFSET_Z = 0,
}

-- Duration tables reference the numeric values defined above so they
-- stay in sync if a state number is ever changed.
NpcConstants.WEAPON_DURATIONS = {
	[NpcConstants.WEAPON_IDLE]           = 0,
	[NpcConstants.WEAPON_MAKE_READY]     = 1.8,
	[NpcConstants.WEAPON_MAKEREADY_IDLE] = 1.0,
	[NpcConstants.WEAPON_TO_AIM]         = 0.7,
	[NpcConstants.WEAPON_AIM_IDLE]       = 1.0,
	[NpcConstants.WEAPON_FIRE]           = 0.75,
	[NpcConstants.WEAPON_RELOAD_IDLE]    = 1.0,
	[NpcConstants.WEAPON_RELOAD]         = 10.33,
}

NpcConstants.MELEE_DURATIONS = {
	[NpcConstants.MELEE_NONE]      = 0,
	[NpcConstants.MELEE_IDLE]      = 0,
	[NpcConstants.MELEE_BOT_START] = 0.25,
	[NpcConstants.MELEE_BOT_IDLE]  = 0,
	[NpcConstants.MELEE_BOT_ATK]   = 0.5,
	[NpcConstants.MELEE_UP_START]  = 0.7,
	[NpcConstants.MELEE_UP_IDLE]   = 0,
	[NpcConstants.MELEE_UP_ATK]    = 0.333,
	[NpcConstants.MELEE_ADVANCE]   = 0,
	[NpcConstants.MELEE_BACKPEDAL] = 0.8,
}

return NpcConstants
