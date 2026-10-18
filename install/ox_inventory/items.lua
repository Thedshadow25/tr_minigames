-- tr_minigames items for ox_inventory (ESX, Qbox, or QBCore running ox_inventory).
-- Paste these entries into ox_inventory/data/items.lua, inside the returned table.
-- Images: copy install/images/*.png to ox_inventory/web/images/.

	['wire_strippers'] = {
		label = 'Wire Strippers',
		weight = 250,
		stack = false,
		description = 'For when you lost your keys. Or someone else did.',
	},

	['lishi_pick'] = {
		label = 'Lishi Pick',
		weight = 150,
		stack = false,
		description = 'A 2-in-1 pick and decoder for car door locks. Light hands.',
		client = {
			export = 'tr_minigames.lockpick', -- "Use" in the inventory starts lockpicking
		},
	},

	['siphon_hose'] = {
		label = 'Siphon Hose',
		weight = 400,
		stack = false,
		description = 'Two clear hoses and a fuel funnel. Tastes like unleaded.',
		client = {
			export = 'tr_minigames.siphon', -- "Use" in the inventory starts siphoning at the car you stand at
		},
	},
