--!strict
-- GameConfig: the single source of truth for every game number.
-- Location in Studio: ReplicatedStorage.GameConfig
-- Rule: no gameplay number lives anywhere else. Tune difficulty here only.
-- Numbers marked "TEST" are first-pass values from the design PDF, to be tuned in Phase 1.

local GameConfig = {}

GameConfig.GameName = "Realm of Crowns"
GameConfig.Version = "0.0.1"

------------------------------------------------------------------------
-- Saving / technical rules
------------------------------------------------------------------------
GameConfig.Save = {
	AutoSaveInterval = 60, -- seconds; also save on PlayerRemoving and BindToClose
	PlayerKeyPrefix = "Player_", -- DataStore key: Player_<UserId>
	KingdomKeyPrefix = "Kingdom_",
	KingdomMapKeyPrefix = "KingdomMap_",
	AllianceKeyPrefix = "Alliance_",
	PlayerDataStoreName = "PlayerData_v1",
	DataVersion = 1,
	SessionLockTimeout = 5 * 60, -- seconds before a crashed server's lock is ignored (live servers refresh it every autosave)
	LockWaitAttempts = 5, -- tries to load while another server still holds the lock
	LockWaitSeconds = 6,
	MaxRetries = 4, -- DataStore call retries
	RetryDelay = 2, -- seconds, multiplied by attempt number
	CloseTimeout = 25, -- max seconds BindToClose waits for final saves (Roblox allows 30)
}

GameConfig.Camera = {
	FieldOfView = 20, -- narrow FOV, high tilted camera (Rise of Kingdoms look)
	Pitch = 55, -- degrees down from horizontal
	Yaw = 0, -- degrees; 0 = looking north (-Z), the gate is at the bottom of the screen
	DefaultDistance = 320, -- studs from the focus point on the ground
	MinDistance = 90,
	MaxDistance = 460,
	ZoomStep = 0.12, -- fraction of distance per mouse-wheel notch
	ZoomInKey = Enum.KeyCode.I, -- hold to zoom (keyboard, like Roblox's default camera)
	ZoomOutKey = Enum.KeyCode.O,
	KeyZoomPerSecond = 1.2, -- fraction of distance per second while a zoom key is held
	Smoothing = 12, -- higher = snappier camera
	DragThreshold = 6, -- pixels a press must move before it counts as a drag (not a tap)
	PanLimit = 120, -- max studs the focus can move from the city center
}

------------------------------------------------------------------------
-- City: each player gets their own city in a slot on the server.
------------------------------------------------------------------------
GameConfig.City = {
	GroundY = 0.2, -- top of the city ground (just above the Baseplate)
	HalfSize = 130, -- ground is 260 x 260 studs
	WallHalfSize = 112,
	WallHeight = 14,
	WallThickness = 4,
	GateWidth = 18,
	-- Walls & gate per visual tier (studs, docs\art\walls_gate.html). WallsModelBuilder builds the models
	-- from these, and CityService uses them for the Part fallback. Radius = tower radius.
	WallTiers = {
		{ Height = 12, Thickness = 4, CornerRadius = 4.5, CornerHeight = 18, GateRadius = 4, GateHeight = 18, GateOpening = 10 },
		{ Height = 14, Thickness = 5, CornerRadius = 5, CornerHeight = 21, GateRadius = 4.5, GateHeight = 22, GateOpening = 11 },
		{ Height = 16, Thickness = 6, CornerRadius = 5.5, CornerHeight = 24, GateRadius = 5, GateHeight = 26, GateOpening = 12 },
		{ Height = 18, Thickness = 6, CornerRadius = 6, CornerHeight = 27, GateRadius = 5.5, GateHeight = 29, GateOpening = 13 },
		{ Height = 20, Thickness = 7, CornerRadius = 6.5, CornerHeight = 30, GateRadius = 6, GateHeight = 32, GateOpening = 14 },
		{ Height = 22, Thickness = 8, CornerRadius = 7, CornerHeight = 33, GateRadius = 6.5, GateHeight = 35, GateOpening = 14 },
	},
	PlotSize = 20, -- plots sit on a 30-stud grid, so this leaves room between them
	CastlePlotSize = 36,
	RoadWidth = 10,
	SlotSpacing = 400, -- distance between neighbouring cities
	SlotsPerRow = 10,
	GridOrigin = Vector3.new(-1800, 0, 600), -- slot 1 center
	SpawnOffset = Vector3.new(4, 4, 24), -- on the road just south of the castle (= Worker.IdleOffset)
}

-- The player's character is the builder: it walks to the building being upgraded and hammers it.
GameConfig.Worker = {
	IdleOffset = Vector3.new(4, 0, 24), -- where it waits when there is no work (relative to the city center)
	WalkSpeed = 16,
	EdgeGap = 3, -- studs between the plot's south edge and the worker
	SwingSeconds = 0.6, -- one hammer hit (up + down)
	CheckInterval = 0.5, -- seconds between looks for a new job (client only)
	-- A build timer starts only when the worker gets there. The server works out the walk time:
	PathFactor = 1.1, -- paths go around buildings, so the straight line is a bit longer
	ArriveExtraSeconds = 0.5, -- turning and slowing down at the end
	MaxWalkSeconds = 15,
	-- Builder 2 (NPC helper, client only). The server times its walk from its idle spot.
	HelperIdleOffset = Vector3.new(-4, 0, 24),
	HelperColors = {
		Skin = Color3.fromRGB(234, 184, 146),
		Shirt = Color3.fromRGB(230, 140, 40),
		Pants = Color3.fromRGB(70, 75, 90),
		Helmet = Color3.fromRGB(245, 200, 40),
	},
	WalkAnimId = 507777826, -- default R15 walk
	IdleAnimId = 507766388, -- default R15 idle
}

-- Client-only building effects (UpgradeFXController)
GameConfig.UpgradeFX = {
	ScaffoldMargin = 1.5, -- studs between the building and the scaffold
	PoleSpacing = 6, -- max studs between two poles on one side
	LevelGap = 4.5, -- studs between two plank levels
	EmptyPlotFootprint = 0.55, -- a new building: scaffold covers this part of the plot
	EmptyPlotHeight = 9,
	RevealSeconds = 0.8, -- the scaffold goes up level by level in this time
	-- Finish scene (timer ends): camera glides in, the new building pops up in dust, fireworks
	FinishZoomDistance = 150, -- camera distance while showing the finished building
	FinishHoldSeconds = 3, -- then the camera glides back
	FinishGlideSmoothing = 3, -- camera smoothing during the glide (Camera.Smoothing is the normal one)
	PopSeconds = 0.6,
	PopStartScale = 0.6, -- the new building grows from this scale to full size
	DustCount = 40,
	FireworkCount = 5,
	FireworkHeight = 18, -- studs above the building top
	FireworkInterval = 0.3, -- seconds between two rockets
	-- V9 (docs\art\plots_construction.html)
	GhostTransparency = 0.85, -- the ghost of the building on an empty plot...
	GhostBuiltTransparency = 0.5, -- ...fills in to this while it is being built
	CornerPulseSeconds = 1.6, -- gold corners on an empty plot you can build now
	CraneCycle = 4, -- scaffold crane: block goes up and down
	ScaffoldDropSeconds = 0.3, -- finish: the scaffold falls and fades
	RingSeconds = 0.6, -- finish: gold ring on the ground grows from RingStart to RingEnd studs
	RingStart = 4,
	RingEnd = 30,
	BeamSeconds = 1,
	BeamWidth = 6,
	BeamHeight = 40,
	BadgeDelay = 1.5, -- finish: "LEVEL N" rises and fades
	BadgeSeconds = 1.6,
	BadgeRise = 4,
}

-- Sound effects (Creator Store audio ids, all checked to load). Client only.
GameConfig.Sounds = {
	HammerHit = { Id = 9125573605, Volume = 0.5 }, -- each hammer hit (3D, on the hammer head)
	HammerMaxDistance = 400, -- studs: the top-down camera is far away, so the hit carries far
	Finish = { Id = 85188102085028, Volume = 0.6 }, -- the finished building pops up
	FireworkLaunch = { Id = 101176984676433, Volume = 0.35 },
	FireworkBurst = { Id = 134947109312227, Volume = 0.5 },
	AttackHorn = { Id = 6875748361, Volume = 0.6 }, -- an attack on your castle starts (once)
	AttackDrum = { Id = 90534468052722, Volume = 0.5 }, -- every second of the last Alert.DrumSeconds
	AttackClash = { Id = 5763723309, Volume = 0.7 }, -- the attackers reach your walls
}

-- Incoming-attack alert (AlertController, docs\art\incoming_attack.html): red pulsing screen edges and a bar
GameConfig.Alert = {
	Pulse = 1.6, -- seconds per edge pulse
	UrgentSeconds = 30, -- below this: faster pulse, red time
	UrgentPulse = 0.7,
	DrumSeconds = 10, -- a drum beat each second below this
	FlashSeconds = 2, -- "Under Attack!" on arrival, then the defense report
	MinimizedEdge = 0.35, -- edge glow strength while the bar is minimized (no pulse)
}

-- Fixed building plots (X, Z relative to the city center). 29 plots + walls.
-- Each Id matches the key in the player's Buildings data.
GameConfig.CityLayout = {
	{ Id = "Castle_1", Type = "Castle", X = 0, Z = 0 },
	-- Inner ring (civic)
	{ Id = "Academy_1", Type = "Academy", X = -30, Z = -30 },
	{ Id = "Tavern_1", Type = "Tavern", X = -30, Z = -60 }, -- not (0, -30): the tall castle hid it
	{ Id = "Embassy_1", Type = "Embassy", X = 30, Z = -30 },
	{ Id = "Storehouse_1", Type = "Storehouse", X = -30, Z = 0 },
	{ Id = "Market_1", Type = "Market", X = 30, Z = 0 },
	{ Id = "Hospital_1", Type = "Hospital", X = -30, Z = 30 },
	{ Id = "Hospital_2", Type = "Hospital", X = 30, Z = 30 },
	-- Middle ring: military (west), mining (east)
	{ Id = "Barracks_1", Type = "Barracks", X = -60, Z = -60 },
	{ Id = "ArcheryRange_1", Type = "ArcheryRange", X = -60, Z = -30 },
	{ Id = "Stable_1", Type = "Stable", X = -60, Z = 0 },
	{ Id = "SiegeWorkshop_1", Type = "SiegeWorkshop", X = -60, Z = 30 },
	{ Id = "Hospital_3", Type = "Hospital", X = -60, Z = 60 },
	{ Id = "Hospital_4", Type = "Hospital", X = 60, Z = 60 },
	{ Id = "GoldMine_1", Type = "GoldMine", X = 60, Z = -60 },
	{ Id = "GoldMine_2", Type = "GoldMine", X = 60, Z = -30 },
	{ Id = "Quarry_1", Type = "Quarry", X = 60, Z = 0 },
	{ Id = "Quarry_2", Type = "Quarry", X = 60, Z = 30 },
	-- Outer ring: lumber (west), farms (east), gate tower (south)
	{ Id = "LumberMill_1", Type = "LumberMill", X = -90, Z = -90 },
	{ Id = "LumberMill_2", Type = "LumberMill", X = -90, Z = -60 },
	{ Id = "LumberMill_3", Type = "LumberMill", X = -90, Z = -30 },
	{ Id = "LumberMill_4", Type = "LumberMill", X = -90, Z = 0 },
	{ Id = "Farm_1", Type = "Farm", X = 90, Z = -90 },
	{ Id = "Farm_2", Type = "Farm", X = 90, Z = -60 },
	{ Id = "Farm_3", Type = "Farm", X = 90, Z = -30 },
	{ Id = "Farm_4", Type = "Farm", X = 90, Z = 0 },
	{ Id = "Quarry_3", Type = "Quarry", X = 90, Z = 30 },
	{ Id = "Quarry_4", Type = "Quarry", X = 90, Z = 60 },
	{ Id = "WatchTower_1", Type = "WatchTower", X = -30, Z = 90 }, -- beside the gate road (X = 0)
}

local plotById = {}
for _, plot in ipairs(GameConfig.CityLayout) do
	plotById[plot.Id] = plot
end

-- Where the worker stands to work on a plot (relative to the city center, Y = 0): the south side
-- of the plot (towards the camera), or just inside the gate for the walls.
function GameConfig.GetWorkSpot(plotId: string): Vector3?
	local city, worker = GameConfig.City, GameConfig.Worker
	if plotId == "Walls_1" then
		return Vector3.new(0, 0, city.WallHalfSize - city.WallThickness / 2 - worker.EdgeGap - 2)
	end
	local plot = plotById[plotId]
	if not plot then
		return nil
	end
	local size = plot.Type == "Castle" and city.CastlePlotSize or city.PlotSize
	return Vector3.new(plot.X, 0, plot.Z + size / 2 + worker.EdgeGap)
end

-- Whole seconds the worker needs to walk from `from` (relative to the city center) to a plot
function GameConfig.GetWalkSeconds(from: Vector3, plotId: string): number
	local spot = GameConfig.GetWorkSpot(plotId)
	if not spot then
		return 0
	end
	local w = GameConfig.Worker
	local distance = Vector3.new(spot.X - from.X, 0, spot.Z - from.Z).Magnitude
	if distance < 2 then
		return 0
	end
	return math.min(w.MaxWalkSeconds, math.ceil(distance * w.PathFactor / w.WalkSpeed + w.ArriveExtraSeconds))
end

-- Kingdom map (phase 2): a flat top-down grid far from the cities. Ground, resource nodes and
-- monsters come from Seed (same on server and client, nothing saved). Only castles are saved.
-- Tile (X, Y): 1..Size, Y grows to the south (screen down). Looks are placeholders (see decisions).
GameConfig.Map = {
	KingdomId = 1, -- one kingdom until phase 4
	Seed = 1337,
	Size = 100, -- 100 x 100 tiles
	TileStuds = 8,
	Origin = Vector3.new(0, 0, -3000), -- world center of the map
	GroundY = 0.2, -- top of the map tiles (same as the city ground, so the camera math is shared)
	DataStoreName = "KingdomMap_v1", -- key: Save.KingdomMapKeyPrefix .. KingdomId
	RefreshSeconds = 60, -- servers re-read the castle list (and write level changes) this often
	ClientRefreshSeconds = 20, -- the open map asks the server for castles this often
	StreamStep = 120, -- studs: the open map moves the player's ReplicationFocus when the camera moves this far
	FocusMinInterval = 0.25, -- seconds between "Focus" requests (server check)
	-- Zones by distance from the center (Chebyshev, in tiles). The center is richer and more dangerous.
	Zones = {
		{ Name = "Outer", MaxRadius = 50, LevelMin = 1, LevelMax = 3 },
		{ Name = "Middle", MaxRadius = 30, LevelMin = 3, LevelMax = 6 },
		{ Name = "Center", MaxRadius = 12, LevelMin = 6, LevelMax = 9 },
	},
	-- Map ground = Roblox Terrain, baked once in Studio by ServerStorage.Assets.Tools.MapTerrainBuilder
	-- (saved in the place, nothing runs in play). KingdomMapGen.SurfaceHeight follows the same numbers.
	Terrain = {
		MountainBase = 4, -- studs above GroundY for a mountain tile at MountainLevel
		MountainScale = 30, -- + this per unit of height noise above MountainLevel
		MaskStart = 0.4, -- mountain tiles lift only past this blended amount: neighbours stay flat
		SurfaceY = -2, -- baked Y of flat land: Terrain renders its surface ~2 studs above the baked level (measured), so flat land shows at Y 0
		RenderLift = 2, -- studs: visible surface = baked level + this (decor and icons use the visible one)
		RidgeScale = 0.22, RidgeHeight = 5, -- ridged noise: sharp ridges and peaks inside ranges
		Roughness = 1.4, RoughScale = 1.3, -- bumps on mountains
		MountainSoft = 14, -- above this the peaks grow slower (no flat tops)
		MountainMax = 24, -- highest possible ground (sizes the baked region)
		RiverDepth = -4.8, -- river/lake/sea bed: under the voxel layer that holds the water (-4..0)
		RiverEdge = { 0.25, 0.65 }, -- blended water amount: the bank starts at [1], full depth at [2]
		WaterLevel = -0.6, -- water surface, from GroundY
		CoastReach = 4, CoastScale = 0.12, CoastBlend = 3, -- tiles: wavy land past the map edge, then beach into the sea
		Bottom = -12, -- terrain fills from here (from GroundY)
		SnowHeight = 16.5, SnowWobble = 1.5, -- above this (+/- wobble, not too steep) = Snow: only the peak tops
		RockHeight = 1.2, -- above this = Rock (gentle low slopes stay grass)
		BlockHeight = 0.3, -- a tile with any sample above this is a mountain tile (no castles, armies, nodes)
		Margin = 60, -- tiles of sea around the map (fades into the fog)
		EdgeWobble = 0.35, EdgeWobbleScale = 0.45, -- tiles: wavy borders between ground types
		Materials = {
			Plains = Enum.Material.Grass,
			Forest = Enum.Material.LeafyGrass,
			Desert = Enum.Material.Sand,
			Mountain = Enum.Material.Rock,
			River = Enum.Material.Mud,
			Crown = Enum.Material.Grass,
			Paving = Enum.Material.Pavement, -- old marble paving in the Crown Lands
		},
		Colors = { -- Terrain material colors (global; only the map uses Terrain)
			Grass = Color3.fromRGB(143, 179, 90),
			LeafyGrass = Color3.fromRGB(84, 138, 66),
			Sand = Color3.fromRGB(217, 191, 126),
			Rock = Color3.fromRGB(140, 130, 117),
			Snow = Color3.fromRGB(241, 239, 233),
			Mud = Color3.fromRGB(110, 92, 66),
			Pavement = Color3.fromRGB(214, 207, 191),
			Ground = Color3.fromRGB(120, 98, 70),
		},
		Water = { WaterColor = Color3.fromRGB(44, 118, 160), WaterTransparency = 0.2, WaterReflectance = 0.5, WaterWaveSize = 0.08, WaterWaveSpeed = 8 },
		PavingChance = 0.15, -- Crown Lands tiles with a paved square
	},
	-- Client decor on the map (from Seed, same for everyone). Trees are clones of one model each
	-- (ReplicatedStorage.Assets.MapModels.Pine / Oak), so the engine draws them in batches.
	Decor = {
		ForestChance = 0.6, ForestTrees = { 2, 3 }, TreeScale = { 0.85, 1.25 },
		TreeMaxHeight = 1.2, -- studs above GroundY: no trees on mountain slopes (or below the bank top)
		OakChance = 0.05,
		PillarChance = 0.05, PillarColor = Color3.fromRGB(230, 223, 208),
		ZoneLineColor = Color3.fromRGB(242, 212, 136), -- one thin dash per border tile, on the ground
		PostEvery = 8, PostColor = Color3.fromRGB(163, 157, 146), PostCapColor = Color3.fromRGB(233, 189, 82),
	},
	NewPlayerZone = 1, -- new castles go to the Outer zone
	CastleGap = 1, -- empty tiles kept between a new castle and anything else
	-- Ground (noise). River tiles hold nothing; Mountain tiles hold only Stone nodes (no castles).
	NoiseScale = 0.07,
	MountainLevel = 0.32, -- height noise above this = mountain
	RiverWidth = 0.035, -- |river noise| below this = river
	DesertLevel = -0.25, -- moisture noise below this = desert
	ForestLevel = 0.18, -- moisture noise above this = forest
	BiomeColors = {
		Plains = Color3.fromRGB(143, 179, 90),
		Forest = Color3.fromRGB(90, 145, 72),
		River = Color3.fromRGB(79, 147, 200),
		Mountain = Color3.fromRGB(149, 138, 124),
		Desert = Color3.fromRGB(217, 191, 126),
	},
	-- Resource nodes and monsters per zone (placed at random free tiles from Seed)
	ResourceNodesPerZone = { 220, 110, 40 },
	MonstersPerZone = { 90, 60, 30 },
	NodeBiome = { Food = "Plains", Wood = "Forest", Stone = "Plains", Gold = "Desert" }, -- preferred ground (never Mountain: impassable)
	NodeColors = {
		Food = Color3.fromRGB(230, 190, 70),
		Wood = Color3.fromRGB(150, 100, 55),
		Stone = Color3.fromRGB(170, 175, 185),
		Gold = Color3.fromRGB(255, 205, 40),
	},
	MonsterColor = Color3.fromRGB(170, 40, 40),
	-- Node/monster models (Assets.MapModels Node_<Resource>_<1..3>, Monster_<1..3>; size band = ceil(level / 3))
	FeatureScale = 1, -- extra size on the map (the models are built for an 8-stud tile)
	FeatureMotion = { -- client only, and only near the camera's ground point
		Radius = 320, -- studs
		Fps = 30,
		AuraSpin = 0.35, -- rad/s, monster ring
		WolfSway = 0.3, -- rad
		WolfSwaySpeed = 1.2,
		FlameFlicker = 9,
		GlintSpeed = 3,
	},
	-- Plate under a castle icon = your relation to its owner (docs\art\map.html section 3)
	MyCastleColor = Color3.fromRGB(79, 182, 255), -- sky: yours
	OtherCastleColor = Color3.fromRGB(192, 69, 60), -- crimson: everyone else (possible targets)
	AllyCastleColor = Color3.fromRGB(212, 166, 70), -- gold: alliance (phase 3)
	-- Name chips over castles, nodes, monsters and armies (map.html section 7)
	Chip = {
		Height = 24, -- px
		TextSize = 14,
		Background = Color3.fromRGB(17, 19, 23),
		BackgroundTransparency = 0.1,
		Border = Color3.fromRGB(58, 51, 40),
		Text = Color3.fromRGB(239, 230, 210),
		MyText = Color3.fromRGB(191, 227, 255),
		MonsterColor = Color3.fromRGB(178, 107, 224),
		BadgeTop = Color3.fromRGB(242, 212, 136),
		BadgeBottom = Color3.fromRGB(192, 143, 48),
		BadgeText = Color3.fromRGB(27, 22, 8),
	},
	MonsterNames = { "Wolf Den", "Bandit Camp", "Ogre Stronghold" }, -- by band (Lv 1-3, 4-6, 7-9)
	-- The selected tile: gold corners that pulse
	Selector = { Color = Color3.fromRGB(242, 212, 136), Arm = 0.28, Thickness = 0.45, PulseSpeed = 4 }, -- Arm = tile fraction
	-- Castle icon = the city castle model of its tier, shrunk to the tile, on a plate in the colors above
	CastleIconScale = 0.42, -- model plot width / tile width (room inside the wall ring; walls use the same shrink)
	CastleIconWallHalf = 0.36, -- wall ring half size / tile width (leaves a gap between neighbouring castles)
	CastleIconMinPart = 0.3, -- studs (after shrinking): smaller parts (windows, merlons...) are dropped
	CastleIconWallMinPart = 0.5, -- same for the wall ring (it has many small parts, and the map has many castles)
	CastlePlateHeight = 0.6,
	-- Camera on the map (same pitch/FOV as the city camera)
	DefaultDistance = 700,
	MinDistance = 200,
	MaxDistance = 1800,
	LabelMaxDistance = 900, -- level/name labels hide when the camera is farther than this
	-- Moving the castle. Random = a free tile in the same zone; Advanced = the exact tile the player picks.
	Move = {
		RandomCost = { Gold = 500 },
		AdvancedCost = { Gems = 50 },
		CooldownSeconds = 300, -- after any (non-admin) move
	},
}

-- Marches (phase 2). An army leaves the castle, walks to a tile and comes back. TEST values.
-- On arrival a monster fights (GameConfig.Battle); other tiles turn the army back until gathering/castle attacks exist.
GameConfig.March = {
	MaxMarches = 2, -- armies out at the same time (research/VIP raise it later)
	MaxTroops = 1000, -- troops in one army
	SecondsPerTile = { Infantry = 6, Archers = 6, Cavalry = 4, Siege = 9 }, -- the slowest type sets the speed
	MinSeconds = 10, -- shortest one-way trip
	ShareKey = "Marches_", -- MemoryStore sorted map: .. Map.KingdomId (every server sees every march)
	ShareReadSeconds = 5, -- servers re-read the shared marches at most this often
	ClientRefreshSeconds = 5, -- the client asks for everyone's marches this often (map + incoming alert)
	MyColor = Color3.fromRGB(70, 220, 90), -- green: your armies
	AllyColor = Color3.fromRGB(70, 150, 255), -- blue: alliance (phase 3)
	EnemyColor = Color3.fromRGB(192, 69, 60), -- crimson: everyone else
	IncomingColor = Color3.fromRGB(232, 69, 60), -- an attack coming at your castle (pulses)
	-- The path: a Beam with a moving arrow texture (docs\art\map.html section 6)
	Line = {
		Texture = "rbxassetid://138461598477133", -- docs\art\icons\march_arrow.png (white, tinted by the color)
		Width = 2.4,
		TextureLength = 4,
		Speed = 1.5,
		BackWidth = 1.6, -- returning with loot: thinner, smaller arrows, paler
		BackTextureLength = 2.6,
		BackTransparency = 0.5,
		PulseSpeed = 5,
	},
}

-- One-way travel time between two tiles for an army ({type = {n1..n4}})
function GameConfig.GetMarchSeconds(fromX: number, fromY: number, toX: number, toY: number, troops): number
	local m = GameConfig.March
	local perTile = 0
	for troopType, counts in pairs(troops) do
		local n = 0
		for _, c in ipairs(counts) do
			n += c
		end
		if n > 0 then
			perTile = math.max(perTile, m.SecondsPerTile[troopType] or 0)
		end
	end
	local dist = math.sqrt((toX - fromX) ^ 2 + (toY - fromY) ^ 2)
	return math.max(m.MinSeconds, math.ceil(dist * perTile))
end

-- Sharing a map tile with the kingdom (ShareService). The text is made by the server from the tile and
-- a fixed tag, so no player-typed text is sent (no chat filter needed). Alliance-only sharing in phase 3.
GameConfig.Share = {
	Tags = { "Enemy", "Target", "Resources", "Rally", "Friend" },
	TagColors = {
		Enemy = Color3.fromRGB(230, 70, 60),
		Target = Color3.fromRGB(230, 140, 40),
		Resources = Color3.fromRGB(90, 190, 90),
		Rally = Color3.fromRGB(170, 110, 220),
		Friend = Color3.fromRGB(70, 150, 255),
	},
	MinSeconds = 10, -- one share per player this often
	PopupSeconds = 10, -- the "new share" popup with its Go button stays this long
	Keep = 20, -- newest shares each server keeps (new players see them)
	Topic = "MapShare_", -- MessagingService topic (+ KingdomId): every server of the kingdom sees every share
}

-- Battles (phase 2). Worked out on the server in rounds, all at once, when an army arrives. TEST values.
-- Each round every stack hits every enemy stack (split by how many troops each has):
--   damage = count x Attack x DamageScale (x (1 + CounterBonus) vs the type it counters)
--   killed = damage / (Health + Defense) of the troop hit
-- It ends when a side has no troops left or after MaxRounds (then the attacker pulls back = defeat).
GameConfig.Battle = {
	DamageScale = 0.08,
	MaxRounds = 20,
	WoundedShare = 0.5, -- of the attacker's losses; they come home healed until the hospital exists
	MaxReports = 20, -- newest reports kept in data.Reports
	ReplaySeconds = 4, -- the report window plays the rounds this long
	-- A monster of level L is an army of TroopsPerLevel x L troops of every type, at the tier below
	Monster = {
		TroopsPerLevel = 12,
		TierByLevel = { 1, 1, 1, 2, 2, 2, 3, 3, 4 }, -- [level] = tier
		Loot = { Food = 400, Wood = 400, Stone = 200, Gold = 80 }, -- x level, if the army wins
	},
	-- Attacking another player's castle (AttackService). The defender fights with the troops at home.
	Castle = {
		StealShare = 0.2, -- a win takes this share of each stored resource (Food/Wood/Stone/Gold), up to the army's Load
		AnswerSeconds = 8, -- wait this long for the server that has the defender online
		Topic = "CastleAttack_", -- MessagingService topic (+ KingdomId)
		-- Admin "Spawn test castle": fake players to attack (UserIds -1 .. -Max, reused in turn)
		Dummy = { Max = 5, Name = "Test Dummy %d", TroopsPerType = 40, Resources = 5000 },
	},
}

GameConfig.Kingdom = {
	MinRegistered = 300,
	MaxRegistered = 1000,
	ServerMinPlayers = 50,
	ServerMaxPlayers = 100,
	BeginnerShieldSeconds = 3 * 24 * 3600, -- 3 days, no reward for attacking it
}

------------------------------------------------------------------------
-- Resources
------------------------------------------------------------------------
GameConfig.Resources = { "Food", "Wood", "Stone", "Gold" }
GameConfig.PremiumCurrency = "Gems"
GameConfig.RareMaterial = "KingsCrystal" -- required from building level 21+

GameConfig.StartingResources = { -- TEST
	Food = 1500,
	Wood = 1500,
	Stone = 0,
	Gold = 0,
	Gems = 100,
	KingsCrystal = 0,
}

------------------------------------------------------------------------
-- Civilizations (small 5% perk each)
------------------------------------------------------------------------
GameConfig.Civilizations = {
	English = { DisplayName = "England", Bonus = "WallDefense", Value = 0.05 },
	Franks = { DisplayName = "Franks", Bonus = "CavalryAttack", Value = 0.05 },
	Vikings = { DisplayName = "Vikings", Bonus = "GatherSpeed", Value = 0.05 },
	Arabs = { DisplayName = "Arabia", Bonus = "MarchSpeed", Value = 0.05 },
	Japan = { DisplayName = "Japan", Bonus = "InfantryAttack", Value = 0.05 },
}

------------------------------------------------------------------------
-- Buildings: 17 types, all max level 30. Castle level caps every other building.
-- Count = how many of that building a city can have. UnlockAt = Castle level.
------------------------------------------------------------------------
GameConfig.MaxBuildingLevel = 30
GameConfig.FreeBuilders = 1 -- second builder is a Game Pass
GameConfig.MaxExtraBuilders = 1 -- data.ExtraBuilders (Game Pass in phase 5; admin button for now)

-- How many builders a player has. Builder 1 is the player's character, builder 2 is the NPC helper.
function GameConfig.GetBuilderCount(extraBuilders: number?): number
	return GameConfig.FreeBuilders + math.clamp(extraBuilders or 0, 0, GameConfig.MaxExtraBuilders)
end

GameConfig.Buildings = {
	Castle = { DisplayName = "Castle", Count = 1, UnlockAt = 1, Role = "Caps all buildings" },
	Walls = { DisplayName = "Walls & Gate", Count = 1, UnlockAt = 1, Role = "City defense" },
	WatchTower = { DisplayName = "Watch Tower", Count = 1, UnlockAt = 2, Role = "Detect attacks" },
	Farm = { DisplayName = "Farm", Count = 4, UnlockAt = 1, Produces = "Food" },
	LumberMill = { DisplayName = "Lumber Mill", Count = 4, UnlockAt = 1, Produces = "Wood" },
	Quarry = { DisplayName = "Quarry", Count = 4, UnlockAt = 5, Produces = "Stone" },
	GoldMine = { DisplayName = "Gold Mine", Count = 2, UnlockAt = 10, Produces = "Gold" },
	Storehouse = { DisplayName = "Storehouse", Count = 1, UnlockAt = 3, Role = "Protects resources" },
	Barracks = { DisplayName = "Barracks", Count = 1, UnlockAt = 1, Trains = "Infantry" },
	ArcheryRange = { DisplayName = "Archery Range", Count = 1, UnlockAt = 3, Trains = "Archers" },
	Stable = { DisplayName = "Stable", Count = 1, UnlockAt = 6, Trains = "Cavalry" },
	SiegeWorkshop = { DisplayName = "Siege Workshop", Count = 1, UnlockAt = 10, Trains = "Siege" },
	Hospital = { DisplayName = "Hospital", Count = 4, UnlockAt = 2, Role = "Heals wounded" },
	Academy = { DisplayName = "Academy", Count = 1, UnlockAt = 4, Role = "Research" },
	Tavern = { DisplayName = "Tavern", Count = 1, UnlockAt = 3, Role = "Summon heroes" },
	Embassy = { DisplayName = "Embassy", Count = 1, UnlockAt = 5, Role = "Alliance help" },
	Market = { DisplayName = "Market", Count = 1, UnlockAt = 8, Role = "Send resources" },
}

-- Visual tier changes every 5 levels (6 models per building)
GameConfig.VisualTiers = {
	{ FromLevel = 1, ToLevel = 5, Name = "Wooden" },
	{ FromLevel = 6, ToLevel = 10, Name = "Stone" },
	{ FromLevel = 11, ToLevel = 15, Name = "Fortified" },
	{ FromLevel = 16, ToLevel = 20, Name = "Royal" },
	{ FromLevel = 21, ToLevel = 25, Name = "Imperial" },
	{ FromLevel = 26, ToLevel = 30, Name = "Legendary" },
}

------------------------------------------------------------------------
-- Upgrade times and costs
-- Castle: 60 s for level 2 -> 20 days for level 30 (exponential curve).
------------------------------------------------------------------------
GameConfig.Upgrade = {
	CastleLevel2Seconds = 60,
	CastleLevel30Seconds = 20 * 24 * 3600,
	OtherBuildingTimeMultiplier = 0.6, -- TEST: other buildings vs castle at same level
	GoldRequiredFromLevel = 16,
	CrystalRequiredFromLevel = 21,
	CastleRequires = { "Walls" }, -- plus one more building at (target level - 1)
	-- The "one more building" per Castle target level. Each one is unlocked by then. TEST
	CastleSecondBuilding = {
		[2] = "Farm", [3] = "LumberMill", [4] = "Hospital", [5] = "Barracks", [6] = "Academy",
		[7] = "Quarry", [8] = "Storehouse", [9] = "Embassy", [10] = "ArcheryRange", [11] = "Stable",
		[12] = "Market", [13] = "Tavern", [14] = "GoldMine", [15] = "SiegeWorkshop", [16] = "Farm",
		[17] = "LumberMill", [18] = "Barracks", [19] = "Academy", [20] = "Hospital", [21] = "Quarry",
		[22] = "Storehouse", [23] = "Embassy", [24] = "ArcheryRange", [25] = "Stable", [26] = "GoldMine",
		[27] = "Academy", [28] = "Barracks", [29] = "Hospital", [30] = "Storehouse",
	},
	NewBuildingSeconds = 60, -- TEST: building a new building (level 1) on an empty plot
	CastleBaseCost = { Food = 100, Wood = 100 }, -- TEST: cost at level 2
	CostGrowth = 1.45, -- TEST: cost multiplier per level
	OtherBuildingCostMultiplier = 0.5, -- TEST
}

-- Seconds to upgrade the Castle TO `level` (2..30)
function GameConfig.GetCastleUpgradeSeconds(level: number): number
	local u = GameConfig.Upgrade
	if level <= 1 then
		return 0
	end
	local growth = (u.CastleLevel30Seconds / u.CastleLevel2Seconds) ^ (1 / 28)
	return math.floor(u.CastleLevel2Seconds * growth ^ (level - 2) + 0.5)
end

-- Seconds to upgrade any building TO `level` (level 1 = building it on an empty plot)
function GameConfig.GetUpgradeSeconds(buildingId: string, level: number): number
	if level <= 1 then
		return GameConfig.Upgrade.NewBuildingSeconds
	end
	local castleSeconds = GameConfig.GetCastleUpgradeSeconds(level)
	if buildingId == "Castle" then
		return castleSeconds
	end
	return math.floor(castleSeconds * GameConfig.Upgrade.OtherBuildingTimeMultiplier + 0.5)
end

-- Resource cost to upgrade a building TO `level`
function GameConfig.GetUpgradeCost(buildingId: string, level: number): { [string]: number }
	local u = GameConfig.Upgrade
	local mult = (buildingId == "Castle") and 1 or u.OtherBuildingCostMultiplier
	local scale = mult * u.CostGrowth ^ (level - 2)
	local base = u.CastleBaseCost.Food
	local cost: { [string]: number } = {
		Food = math.floor(base * scale),
		Wood = math.floor(base * scale),
	}
	if level >= 6 then
		cost.Stone = math.floor(base * 0.5 * scale)
	end
	if level >= u.GoldRequiredFromLevel then
		cost.Gold = math.floor(base * 0.25 * scale)
	end
	if level >= u.CrystalRequiredFromLevel then
		cost.KingsCrystal = (level - u.CrystalRequiredFromLevel + 1) * 5 -- TEST
	end
	return cost
end

-- What a building needs before it can go TO `level`: a list of { Type, Level }.
-- Met when the player owns a building of that Type at that Level or higher.
-- Castle: Walls + one more building at (level - 1). Others: Castle at max(level, UnlockAt).
function GameConfig.GetRequirements(buildingType: string, level: number): { { Type: string, Level: number } }
	local u = GameConfig.Upgrade
	if buildingType == "Castle" then
		local reqs = {}
		for _, reqType in ipairs(u.CastleRequires) do
			table.insert(reqs, { Type = reqType, Level = level - 1 })
		end
		local second = u.CastleSecondBuilding[level]
		if second then
			table.insert(reqs, { Type = second, Level = level - 1 })
		end
		return reqs
	end
	local def = GameConfig.Buildings[buildingType]
	return { { Type = "Castle", Level = math.max(level, def.UnlockAt) } }
end

------------------------------------------------------------------------
-- Remote requests (anti-spam). Every RemoteEvent/Function is checked on the server.
------------------------------------------------------------------------
-- Admin panel (AdminService / AdminController). Works for these UserIds, and for everyone in Studio.
GameConfig.Admin = {
	UserIds = { 8344263175 },
	AllowInStudio = true,
	ResourceSteps = { 10000, 100000, 1000000 }, -- "+" buttons, added to every resource
	TroopStep = 100, -- "+100 troops": T1 of every type
	DemoTrainSeconds = 60, -- "Military: demo training": free 1-troop batch so the training animation can be watched
	DemoBuildSeconds = 30, -- "Plots: demo build/upgrade": free short build to watch the scaffold and finish scene
	ResetConfirmSeconds = 5, -- "RESET EVERYTHING": the second press must come within this
	DummyAttackSeconds = 60, -- "Dummy attacks me": the test army arrives after this
	DummyAttackTroops = 30, -- T1 of each troop type in that army
}

GameConfig.Remotes = {
	MinRequestInterval = 0.25, -- seconds between two build/upgrade requests from one player
	SyncRequestInterval = 1, -- seconds between two "send me my data" requests
}

------------------------------------------------------------------------
-- Resource production (per hour, collected by tapping). TEST values.
------------------------------------------------------------------------
GameConfig.Production = {
	BasePerHour = { Food = 100, Wood = 100, Stone = 60, Gold = 20 },
	GrowthPerLevel = 1.18,
	BaseCapacityHours = 8, -- building stops filling after this many hours uncollected
	MinBubbleAmount = 10, -- the collect bubble shows once a building holds at least this much
	SailSpin = 0.8, -- farm windmill sails, radians per second (client only, while producing)
	SawSpin = 9, -- lumber mill saw blade, radians per second
	MineCartCycle = 10, -- gold mine cart: seconds for one trip into the tunnel and back out full
	CraneCycle = 9, -- quarry crane: seconds to lift one block from the cliff into the cart and swing back
}

-- Light motion of the civic buildings (CivicModelBuilder parts), client only, always on.
-- Swings are { max angle in radians, seconds per back-and-forth }; spins are radians per second.
GameConfig.CivicMotion = {
	Bell = { 0.35, 2.4 }, -- hospital / watch tower bell
	TavernSign = { 0.12, 3.2 },
	ScaleBeam = { 0.1, 4 }, -- market scale tips one pan then the other
	Flag = { 0.22, 1.6 }, -- pole flags ("Banner" / "AllyFlag" / pennants) flap about the pole
	ArmillarySpin = 0.5, -- academy rings
	PigeonSpin = 1.1, -- pigeons circling the tower
	PigeonBob = 0.4, -- studs up and down while circling (unscaled)
}

function GameConfig.GetProductionCapacity(resource: string, level: number): number
	return GameConfig.GetProductionPerHour(resource, level) * GameConfig.Production.BaseCapacityHours
end

function GameConfig.GetProductionPerHour(resource: string, level: number): number
	local p = GameConfig.Production
	return math.floor(p.BasePerHour[resource] * p.GrowthPerLevel ^ (level - 1))
end

------------------------------------------------------------------------
-- Troops: 4 types x 4 tiers. Power = count x tier x hero x research.
-- Counters: Infantry > Cavalry > Archers > Infantry. Siege breaks walls.
------------------------------------------------------------------------
GameConfig.TroopTypes = { "Infantry", "Archers", "Cavalry", "Siege" }

GameConfig.Counters = {
	Infantry = "Cavalry",
	Cavalry = "Archers",
	Archers = "Infantry",
	Siege = "Walls",
}
GameConfig.CounterBonus = 0.25 -- TEST: +25% damage vs the countered type

GameConfig.TroopTiers = { -- TEST stats per single troop
	[1] = { Attack = 10, Defense = 10, Health = 10, Load = 10, Power = 1, TrainSeconds = 20, UnlockAt = 1 },
	[2] = { Attack = 16, Defense = 16, Health = 16, Load = 14, Power = 2, TrainSeconds = 40, UnlockAt = 8 },
	[3] = { Attack = 26, Defense = 26, Health = 26, Load = 18, Power = 4, TrainSeconds = 80, UnlockAt = 16 },
	[4] = { Attack = 42, Defense = 42, Health = 42, Load = 24, Power = 8, TrainSeconds = 160, UnlockAt = 25 },
}
-- UnlockAt = level of the training building (Barracks/Range/Stable/Workshop). T4 at 25.

GameConfig.TroopCost = { -- TEST cost per single troop, by tier
	[1] = { Food = 50, Wood = 50 },
	[2] = { Food = 100, Wood = 100, Stone = 20 },
	[3] = { Food = 200, Wood = 200, Stone = 60, Gold = 10 },
	[4] = { Food = 400, Wood = 400, Stone = 150, Gold = 40 },
}

-- Training (one batch at a time per training building; it does not use a builder). TEST values.
GameConfig.Training = {
	BaseBatch = 10, -- most troops in one batch at building Lv 1
	BatchPerLevel = 5, -- + this many per building level above 1
	-- Moving parts while a building trains (client only, ProductionController): seconds per cycle
	DummyCycle = 1.6, -- barracks: a dummy is hit and sways back
	ArrowCycle = 2.4, -- archery range: an arrow flies to the target, sticks, vanishes
	HorseLap = 8, -- stable: one lap of the paddock
	GallopRate = 2.5, -- stable: hoof beats (bobs) per second
	CatapultCycle = 6, -- siege workshop: fire, hold, wind back, reload
	HoistCycle = 8, -- siege workshop: the log goes up and down again
}

function GameConfig.GetMaxTrainBatch(buildingLevel: number): number
	local t = GameConfig.Training
	return t.BaseBatch + t.BatchPerLevel * (buildingLevel - 1)
end

function GameConfig.GetTrainSeconds(tier: number, count: number): number
	return GameConfig.TroopTiers[tier].TrainSeconds * count
end

function GameConfig.GetTrainCost(tier: number, count: number)
	local cost = {}
	for resource, amount in pairs(GameConfig.TroopCost[tier]) do
		cost[resource] = amount * count
	end
	return cost
end

------------------------------------------------------------------------
-- Art: the visual identity from docs/art/style_guide.html. All UI and
-- building colors/fonts should come from here.
------------------------------------------------------------------------
local function hex(h: string): Color3
	return Color3.fromHex(h)
end

local FONT_PATH = "rbxasset://fonts/families/%s.json"
local function font(family: string, weight: Enum.FontWeight): Font
	return Font.new(string.format(FONT_PATH, family), weight)
end

GameConfig.Art = {
	Colors = {
		Background = hex("#14171c"),
		Panel = hex("#1d2128"),
		Panel2 = hex("#262b33"),
		Border = hex("#3a3328"),
		Text = hex("#efe6d2"),
		Muted = hex("#a59c88"),
		Gold = hex("#d4a646"),
		GoldLight = hex("#f2d488"),
		GoldDark = hex("#8a6420"),
		RoyalGreen = hex("#25543f"),
		GreenLight = hex("#3f8a5f"),
		Crimson = hex("#a8322d"),
		Wood = hex("#8b5e36"),
		Stone = hex("#8e8b84"),
		Marble = hex("#e6dfd0"),
		Arcane = hex("#5dffc9"),
	},
	Status = {
		Gain = hex("#7fd67a"),
		Loss = hex("#e8695f"),
		BuildTimer = hex("#e0a03a"),
		TrainTimer = hex("#4f9fe0"),
		MyCastle = hex("#5ec8f0"),
		Ally = hex("#7fd67a"),
		Enemy = hex("#e8695f"),
		Monster = hex("#c07cff"),
	},
	Resources = {
		Food = hex("#e3c35a"),
		Wood = hex("#a06a3b"),
		Stone = hex("#9aa0a8"),
		Gold = hex("#f0c23a"),
		Gems = hex("#5ec8f0"),
		KingsCrystal = hex("#b07cff"),
	},
	-- Troop badge frame per tier: Frame = border, Fill = background.
	TroopTiers = {
		[1] = { Name = "I", Frame = hex("#b07a45"), Fill = hex("#2e2318") },
		[2] = { Name = "II", Frame = hex("#9aa4ae"), Fill = hex("#2a2f35") },
		[3] = { Name = "III", Frame = hex("#d4a646"), Fill = hex("#3a2f17") },
		[4] = { Name = "IV", Frame = hex("#5dffc9"), Fill = hex("#173a33") },
	},
	-- Banner colors per civilization (Main = cloth, Trim = top band and edge).
	Banners = {
		English = { Main = hex("#b0262d"), Trim = hex("#d4a646") },
		Franks = { Main = hex("#2f4f9e"), Trim = hex("#efe6d2") },
		Vikings = { Main = hex("#3d5a6b"), Trim = hex("#c3c7cc") },
		Arabs = { Main = hex("#1f7a4d"), Trim = hex("#d4a646") },
		Japan = { Main = hex("#e6dfd0"), Trim = hex("#b0262d") },
	},
	-- Button styles: Top/Bottom = UIGradient, Stroke = UIStroke, Text = label color.
	Buttons = {
		Primary = { Top = hex("#f2d488"), Bottom = hex("#c08f30"), Stroke = hex("#6b4c16"), Text = hex("#1b1608") },
		Confirm = { Top = hex("#2f6d4a"), Bottom = hex("#1a3f2e"), Stroke = hex("#123124"), Text = hex("#ffffff") },
		Danger = { Top = hex("#a8382f"), Bottom = hex("#6e1d1a"), Stroke = hex("#4a1210"), Text = hex("#ffffff") },
		Neutral = { Top = hex("#5a5f68"), Bottom = hex("#383c43"), Stroke = hex("#22252a"), Text = hex("#ffffff") },
		Disabled = { Top = hex("#4a4a4a"), Bottom = hex("#333333"), Stroke = hex("#222222"), Text = hex("#a8a8a8") },
		Train = { Top = hex("#3b7fc0"), Bottom = hex("#1f4f80"), Stroke = hex("#143150"), Text = hex("#ffffff") },
	},
	-- V10 icons (docs\art\ui.html, PNG 128x128 in docs\art\icons). Resources by name, troops by TroopTypes name.
	Icons = {
		Food = "rbxassetid://83298116470235",
		Wood = "rbxassetid://80113377066946",
		Stone = "rbxassetid://96899474221985",
		Gold = "rbxassetid://79136250494343",
		Gems = "rbxassetid://78637741023116",
		KingsCrystal = "rbxassetid://81927359049974",
		Infantry = "rbxassetid://110562480894851",
		Archers = "rbxassetid://81721464520195",
		Cavalry = "rbxassetid://124647040052831",
		Siege = "rbxassetid://92398490798803",
		Map = "rbxassetid://120445671773316",
		City = "rbxassetid://131547868327471",
		Explore = "rbxassetid://123218948979842",
		Search = "rbxassetid://80229124424412",
		Share = "rbxassetid://105530566736747",
		Reports = "rbxassetid://83286532551188",
		Admin = "rbxassetid://136146567381067",
		Home = "rbxassetid://72534376145770",
		Shared = "rbxassetid://126627597821794",
		March = "rbxassetid://78244159418162",
		Hammer = "rbxassetid://109923034433347",
		Power = "rbxassetid://109410374752087",
		Monster = "rbxassetid://88013920598147",
		Castle = "rbxassetid://89142490314394",
		Attack = "rbxassetid://139587036805277", -- crossed swords (u-attack.png), the incoming-attack alert
	},
	Medallion = { Size = 52, Label = 14, Gap = 6 }, -- right-side round buttons (pixels)
	ButtonCorner = 8, -- UICorner pixels
	ButtonStroke = 2, -- UIStroke thickness
	ButtonPressOffset = 2, -- pixels the button moves down when pressed
	Fonts = {
		Logo = font("GrenzeGotisch", Enum.FontWeight.ExtraBold), -- big screens: Victory, title
		Title = font("Merriweather", Enum.FontWeight.Heavy), -- window headers
		Subtitle = font("Merriweather", Enum.FontWeight.Bold),
		Body = font("RobotoCondensed", Enum.FontWeight.Regular),
		Number = font("RobotoCondensed", Enum.FontWeight.Bold), -- resources, timers, counts
	},
}

-- V2 mood + city ground (docs\art\environment.html, "Golden Afternoon"). CityService applies it.
GameConfig.Environment = {
	Lighting = {
		ClockTime = 15.2,
		GeographicLatitude = 35,
		Brightness = 2.2,
		Ambient = hex("#5a5246"),
		OutdoorAmbient = hex("#8a7f6a"),
		ColorShift_Top = hex("#ffe2b0"),
		ColorShift_Bottom = hex("#3a3030"),
		EnvironmentDiffuseScale = 0.6,
		EnvironmentSpecularScale = 0.4,
		ShadowSoftness = 0.3,
		GlobalShadows = true,
	},
	-- [effect class] = properties. Missing effects get created in Lighting.
	Effects = {
		Atmosphere = { Density = 0.28, Offset = 0.15, Color = hex("#d9c7a3"), Decay = hex("#7a6a55"), Glare = 0.2, Haze = 1.4 },
		ColorCorrectionEffect = { Brightness = 0.02, Contrast = 0.08, Saturation = 0.12, TintColor = hex("#fff4e3") },
		BloomEffect = { Intensity = 0.6, Size = 24, Threshold = 1.6 },
		SunRaysEffect = { Intensity = 0.06, Spread = 0.6 },
		DepthOfFieldEffect = { Enabled = false }, -- the top-down camera would blur the city
	},
	Ground = {
		OutskirtsHalfSize = 200, -- 400 x 400 = one city slot, so no gap between cities
		InnerHalfSize = 108, -- city grass inside the walls
		PlazaHalfSize = 28,
		CurbWidth = 1,
		PathWidth = 4,
		PathsX = { -75, -45, 45, 75 }, -- dirt paths between plot columns (Z from -102 to 75)
		PathsZ = { { -45, -102, 102 }, { -75, -102, -45 }, { -75, 45, 102 } }, -- {Z, fromX, toX}
		CrossRoadZ = 45,
		CrossRoadWidth = 6,
		Patches = 26,
		ForestTrees = 90, -- tried positions in the 140..195 belt (some get skipped)
		ForestFrom = 140,
		MeadowTrees = 60, -- tried positions just outside the wall (most miss the thin ring)
		Rocks = 14,
		Bushes = 18,
		LampSpacing = 14, -- along the main road, Z from 34 to 104
		LampRange = 18,
		Colors = {
			Outskirts = hex("#64883f"),
			Meadow = hex("#7aa452"),
			Grass = hex("#6f9a4c"),
			GrassDark = hex("#5d8640"),
			GrassLight = hex("#83ad5c"),
			Plaza = hex("#a79e8e"),
			Cobble = hex("#a99f8d"),
			Curb = hex("#6f6a62"),
			Dirt = hex("#9c7f58"),
			Pine = hex("#2f5a34"),
			Pine2 = hex("#386a3d"),
			Oak = hex("#4f7a3a"),
			Oak2 = hex("#5e8a44"),
			Bush = hex("#4d7a35"),
			Trunk = hex("#6b4a2c"),
			Rock = hex("#8a8780"),
			Flame = hex("#ffb347"),
			Hay = hex("#d9b65a"),
			Log = hex("#8b5e36"),
			Ore = hex("#f0c23a"),
			Water = hex("#3a7fb0"),
			Roof = hex("#8a3a2e"),
			FlowerA = hex("#d86a7a"),
			FlowerB = hex("#f2d488"),
		},
	},
}

------------------------------------------------------------------------
-- Monetization (Phase 5). Prices in Robux.
------------------------------------------------------------------------
GameConfig.Shop = {
	StarterPack = 49,
	SecondBuilderPass = 399,
	MonthlyCard = 199,
	SeasonPass = 499,
	VipMaxLevel = 15,
}

return GameConfig
