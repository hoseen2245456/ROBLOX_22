--!strict
-- KingdomMapGen: the kingdom map's ground, resource nodes and monsters, made from GameConfig.Map.Seed.
-- Location in Studio: ReplicatedStorage.Modules.KingdomMapGen (ModuleScript)
-- Server and client run the same code with the same seed, so they get the same map and nothing
-- here is saved. Castles are not here: they are saved by KingdomMapService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local Cfg = GameConfig.Map

local KingdomMapGen = {}

export type Feature = { X: number, Y: number, Kind: string, Resource: string?, Level: number }

local SIZE = Cfg.Size
local CENTER = (SIZE + 1) / 2

local function key(x: number, y: number): number
	return (y - 1) * SIZE + x
end

function KingdomMapGen.Key(x: number, y: number): number
	return key(x, y)
end

function KingdomMapGen.InBounds(x: number, y: number): boolean
	return x >= 1 and y >= 1 and x <= SIZE and y <= SIZE and x % 1 == 0 and y % 1 == 0
end

-- Distance from the center in tiles (square rings)
function KingdomMapGen.Radius(x: number, y: number): number
	return math.max(math.abs(x - CENTER), math.abs(y - CENTER))
end

-- Zone index: 1 = Outer ... #Zones = Center (the smallest ring that still contains the tile)
function KingdomMapGen.GetZone(x: number, y: number): number
	local r = KingdomMapGen.Radius(x, y)
	local zone = 1
	for i, z in ipairs(Cfg.Zones) do
		if r <= z.MaxRadius then
			zone = i
		end
	end
	return zone
end

------------------------------------------------------------------------
-- Ground
------------------------------------------------------------------------
local biomes: { [number]: string } = {}

local function noise(x: number, y: number, layer: number): number
	local s = Cfg.NoiseScale
	return math.noise(x * s + Cfg.Seed * 0.013, y * s + layer * 17.31, Cfg.Seed * 0.0071 + layer)
end

local heightNoise: { [number]: number } = {}

local function computeBiome(x: number, y: number): string
	local height = noise(x, y, 1) + 0.5 * noise(x * 2, y * 2, 2)
	heightNoise[key(x, y)] = height
	local river = noise(x * 0.6, y * 0.6, 3)
	local moisture = noise(x, y, 4)
	if math.abs(river) < Cfg.RiverWidth then
		return "River"
	elseif height > Cfg.MountainLevel then
		return "Mountain"
	elseif moisture < Cfg.DesertLevel then
		return "Desert"
	elseif moisture > Cfg.ForestLevel then
		return "Forest"
	end
	return "Plains"
end

for y = 1, SIZE do
	for x = 1, SIZE do
		biomes[key(x, y)] = computeBiome(x, y)
	end
end

function KingdomMapGen.GetBiome(x: number, y: number): string?
	return biomes[key(x, y)]
end

------------------------------------------------------------------------
-- Ground height (the baked Terrain follows this, so client decor can sit on it)
------------------------------------------------------------------------
local TCfg = Cfg.Terrain

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function mountainAt(x: number, y: number): number
	return if KingdomMapGen.InBounds(x, y) and biomes[key(x, y)] == "Mountain" then 1 else 0
end

-- How big the mountain on this tile is (0 if it is not a mountain): grows with the height noise
local function riseAt(x: number, y: number): number
	if mountainAt(x, y) == 0 then
		return 0
	end
	return TCfg.MountainBase + (heightNoise[key(x, y)] - Cfg.MountainLevel) * TCfg.MountainScale
end

local function riverAt(x: number, y: number): number
	return if KingdomMapGen.InBounds(x, y) and biomes[key(x, y)] == "River" then 1 else 0
end

-- Ground height above GroundY at any point, in tile units (tile centers are whole numbers).
-- Mountains: a smooth mask of mountain tiles times ridged noise, so ranges get sharp ridges and peaks.
-- Water: rivers are a separate smooth blend (diagonal river tiles still join); outside the map the land
-- runs on a few tiles (wavy coast) and then slopes into the sea.
function KingdomMapGen.SurfaceHeight(u: number, v: number): number
	local i, j = math.floor(u), math.floor(v)
	local fu, fv = smooth(u - i), smooth(v - j)
	local function blend(fn: (number, number) -> number): number
		return (fn(i, j) * (1 - fu) + fn(i + 1, j) * fu) * (1 - fv) + (fn(i, j + 1) * (1 - fu) + fn(i + 1, j + 1) * fu) * fv
	end
	local h = 0
	local m = blend(mountainAt)
	if m > 0 then
		local rise = blend(riseAt) / m -- the size of the nearby mountain tiles
		local ridge = 1 - math.abs(math.noise(u * TCfg.RidgeScale, v * TCfg.RidgeScale, Cfg.Seed * 0.013))
		ridge *= ridge
		-- the mask only lifts past MaskStart, so a mountain stays on its own tiles (neighbours stay flat)
		local lift = smooth((m - TCfg.MaskStart) / (1 - TCfg.MaskStart))
		h = (rise * (0.5 + 0.5 * ridge) + ridge * TCfg.RidgeHeight) * lift
		h += math.noise(u * TCfg.RoughScale, v * TCfg.RoughScale, Cfg.Seed * 0.01) * TCfg.Roughness * lift
		if h > TCfg.MountainSoft then
			-- squash the tops gently instead of cutting them flat (a hard cap makes snow plateaus)
			h = TCfg.MountainSoft + (h - TCfg.MountainSoft) * 0.35
		end
	end
	local water = blend(riverAt)
	local out = math.max(1 - u, u - SIZE, 1 - v, v - SIZE, 0) -- tiles beyond the map edge
	if out > 0 then
		local reach = (math.noise(u * TCfg.CoastScale, v * TCfg.CoastScale, 5.5) * 0.5 + 0.5) * TCfg.CoastReach
		water = math.max(water, math.clamp((out - reach) / TCfg.CoastBlend, 0, 1))
	end
	local edge = TCfg.RiverEdge
	if water > edge[1] then
		local t = smooth((water - edge[1]) / (edge[2] - edge[1]))
		h += (TCfg.RiverDepth - h) * t
	end
	return h
end

-- Height of a tile center above GroundY
function KingdomMapGen.GetHeight(x: number, y: number): number
	return KingdomMapGen.SurfaceHeight(x, y)
end

-- World Y of the visible Terrain surface at a world position (baked at SurfaceY + height, drawn
-- RenderLift higher; flat land shows at about Cfg.GroundY, where map icons stand)
function KingdomMapGen.GroundYAt(pos: Vector3): number
	local s = Cfg.TileStuds
	local u = (pos.X - Cfg.Origin.X) / s + CENTER
	local v = (pos.Z - Cfg.Origin.Z) / s + CENTER
	return TCfg.SurfaceY + TCfg.RenderLift + KingdomMapGen.SurfaceHeight(u, v)
end

-- What the ground on a tile really is, from the baked heights (a tile named Plains can still be
-- partly covered by the foot of a mountain or by a river bank): "Land", "Mountain" or "Water".
-- Samples the center, the edges and the corners (Terrain smooths shapes out a little past their heights).
local groundCache: { [number]: string } = {}
local E = 0.45
local SAMPLES = { { 0, 0 }, { -E, 0 }, { E, 0 }, { 0, -E }, { 0, E }, { -E, -E }, { E, -E }, { -E, E }, { E, E } }

function KingdomMapGen.GetGround(x: number, y: number): string
	if not KingdomMapGen.InBounds(x, y) then
		return "Water"
	end
	local k = key(x, y)
	local cached = groundCache[k]
	if cached then
		return cached
	end
	local hi, lo = -math.huge, math.huge
	for _, s in ipairs(SAMPLES) do
		local h = KingdomMapGen.SurfaceHeight(x + s[1], y + s[2])
		hi, lo = math.max(hi, h), math.min(lo, h)
	end
	local biome = biomes[k]
	local ground = if biome == "Mountain" or hi > TCfg.BlockHeight then "Mountain"
		elseif biome == "River" or lo < TCfg.WaterLevel then "Water"
		else "Land"
	groundCache[k] = ground
	return ground
end

-- Can armies go to this tile? Mountains (and their slopes) are impassable.
function KingdomMapGen.IsPassable(x: number, y: number): boolean
	return KingdomMapGen.InBounds(x, y) and KingdomMapGen.GetGround(x, y) ~= "Mountain"
end

------------------------------------------------------------------------
-- Resource nodes and monsters (only on "Land" tiles: no water, no mountain slopes)
------------------------------------------------------------------------
local features: { Feature } = {}
local featureAt: { [number]: Feature } = {}

local function zoneTiles(zone: number): { { number } }
	local list = {}
	for y = 1, SIZE do
		for x = 1, SIZE do
			if KingdomMapGen.GetZone(x, y) == zone and KingdomMapGen.GetGround(x, y) == "Land" then
				table.insert(list, { x, y })
			end
		end
	end
	return list
end

local function placeFeatures()
	local rng = Random.new(Cfg.Seed)
	local resources = GameConfig.Resources
	for zone, zoneCfg in ipairs(Cfg.Zones) do
		local tiles = zoneTiles(zone)
		-- Shuffle once, then hand tiles out in order
		for i = #tiles, 2, -1 do
			local j = rng:NextInteger(1, i)
			tiles[i], tiles[j] = tiles[j], tiles[i]
		end
		local nextTile = 1
		local function grab(look: number): { number }
			local t = tiles[look]
			tiles[look], tiles[nextTile] = tiles[nextTile], t
			nextTile += 1
			return t
		end
		-- Look a little ahead for the preferred ground, else take the next tile that is not a mountain
		local function take(preferBiome: string?): { number }?
			if preferBiome then
				for look = nextTile, math.min(#tiles, nextTile + 60) do
					if biomes[key(tiles[look][1], tiles[look][2])] == preferBiome then
						return grab(look)
					end
				end
			end
			for look = nextTile, #tiles do
				if biomes[key(tiles[look][1], tiles[look][2])] ~= "Mountain" then
					return grab(look)
				end
			end
			return nil
		end
		local function add(t: { number }?, kind: string, resource: string?)
			if not t then
				return
			end
			local f: Feature = {
				X = t[1],
				Y = t[2],
				Kind = kind,
				Resource = resource,
				Level = rng:NextInteger(zoneCfg.LevelMin, zoneCfg.LevelMax),
			}
			table.insert(features, f)
			featureAt[key(f.X, f.Y)] = f
		end
		for i = 1, Cfg.ResourceNodesPerZone[zone] or 0 do
			local resource = resources[(i - 1) % #resources + 1]
			add(take(Cfg.NodeBiome[resource]), "Resource", resource)
		end
		for _ = 1, Cfg.MonstersPerZone[zone] or 0 do
			add(take(nil), "Monster", nil)
		end
	end
end
placeFeatures()

function KingdomMapGen.GetFeatures(): { Feature }
	return features
end

function KingdomMapGen.GetFeatureAt(x: number, y: number): Feature?
	return featureAt[key(x, y)]
end

-- Can a castle stand here? (ground and nodes only; the caller checks other castles)
function KingdomMapGen.CanHoldCastle(x: number, y: number): boolean
	if not KingdomMapGen.InBounds(x, y) then
		return false
	end
	return KingdomMapGen.GetGround(x, y) == "Land" and featureAt[key(x, y)] == nil
end

------------------------------------------------------------------------
-- World positions
------------------------------------------------------------------------
function KingdomMapGen.TileToWorld(x: number, y: number): Vector3
	local s = Cfg.TileStuds
	return Cfg.Origin + Vector3.new((x - CENTER) * s, Cfg.GroundY, (y - CENTER) * s)
end

function KingdomMapGen.WorldToTile(pos: Vector3): (number, number)
	local s = Cfg.TileStuds
	local x = math.floor((pos.X - Cfg.Origin.X) / s + CENTER + 0.5)
	local y = math.floor((pos.Z - Cfg.Origin.Z) / s + CENTER + 0.5)
	return x, y
end

return KingdomMapGen
