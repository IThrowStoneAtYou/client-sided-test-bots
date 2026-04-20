local RegimentData = {}

RegimentData.Sides = {
	[1] = {
		key    = "attacker",
		role   = "ATTACKERS",
		name   = "FRANCE & ALLIES",
		accent = Color3.fromRGB(55,  100, 220),
		dim    = Color3.fromRGB(10,  18,  70),
		nations = {
			{
				key      = "france",
				name     = "France",
				subtitle = "République Française",
				flag     = "rbxassetid://139065210013036",
				regiments = {
					{
						key   = "1er_ligne",
						name  = "1er Régiment d'Infanterie de Ligne",
						desc  = "Premier regiment of Napoleon's Grande Armée",
						color = Color3.fromRGB(55, 100, 220),
					},
					{
						key   = "3e_etranger",
						name  = "3e Regiment Étranger",
						desc  = "Foreign regiment of the Grande Armée",
						color = Color3.fromRGB(40, 140, 80),
					},
				},
			},
			{
				key      = "warsaw",
				name     = "Duchy of Warsaw",
				subtitle = "Księstwo Warszawskie",
				flag     = "rbxassetid://13110413028",
				regiments = {
					{
						key   = "13_pulk",
						name  = "13. Pułk Piechoty",
						desc  = "Line infantry regiment of the Duchy of Warsaw",
						color = Color3.fromRGB(200, 200, 200),
					},
					{
						key   = "16_pulk",
						name  = "16. Pułk Piechoty",
						desc  = "line infantry regiment of the Duchy of Warsaw",
						color = Color3.fromRGB(180, 40, 40),
					},
				},
			},
		},
	},
	[2] = {
		key    = "defender",
		role   = "DEFENDERS",
		name   = "COALITIONS FORCES",
		accent = Color3.fromRGB(210, 50,  50),
		dim    = Color3.fromRGB(70,  8,   8),
		nations = {
			{
				key      = "britain",
				name     = "Great Britain",
				subtitle = "United Kingdom of Great Britain",
				flag     = "rbxassetid://88813497029040",
				regiments = {
					{
						key   = "23rd_foot",
						name  = "23rd Regiment of Foot",
						desc  = "The Royal Welch Fusiliers steadfast redcoat infantry",
						color = Color3.fromRGB(210, 50, 50),
					},
					{
						key   = "35th_foot",
						name  = "35th Regiment of Foot",
						desc  = "foot pluh",
						color = Color3.fromRGB(200, 100, 30),
					},
				},
			},
			{
				key      = "prussia",
				name     = "Kingdom of Prussia",
				subtitle = "Königreich Preußen",
				flag     = "rbxassetid://13110404432",
				regiments = {
					{
						key   = "13_inf",
						name  = "13. Infanterie Regiment",
						desc  = "13th Infantry Regiment Prussian line infantry",
						color = Color3.fromRGB(40, 40, 40),
					},
					{
						key   = "18_inf",
						name  = "18. Infanterie Regiment",
						desc  = "18th Infantry Regiment Prussian line infantry",
						color = Color3.fromRGB(50, 60, 100),
					},
				},
			},
		},
	},
}

function RegimentData.GetRegimentInfo(sideIdx: number, globalRegIdx: number)
	local side = RegimentData.Sides[sideIdx]
	if not side then return nil end

	local count = 0
	for _, nation in ipairs(side.nations) do
		for _, reg in ipairs(nation.regiments) do
			count += 1
			if count == globalRegIdx then return reg end
		end
	end
	return nil
end

return RegimentData