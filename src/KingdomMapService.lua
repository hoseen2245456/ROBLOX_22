-- KingdomMapService: castles on the kingdom map. Gives every player a free tile, keeps the shared castle
-- list, and answers the client's "MapAction" requests.
-- Location in Studio: ServerScriptService.Services.KingdomMapService (ModuleScript)
-- The castle list is one DataStore key (KingdomMap_<KingdomId> in Map.DataStoreName), always changed
-- with UpdateAsync because every server writes to it. Ground/nodes/monsters come from KingdomMapGen.
-- Each player's own tile is also in their data (data.MapTile = {X, Y}).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local KingdomMapGen = require(ReplicatedStorage.Modules.KingdomMapGen)
local Cfg = GameConfig.Map

local KingdomMapService = {}

local PlayerDataService
local store: DataStore? = nil
local memoryOnly = false
local storeKey = GameConfig.Save.KingdomMapKeyPrefix .. Cfg.KingdomId

-- Latest castle list: ["x_y"] = { U = userId, N = name, L = castle level }
local castles: { [string]: { U: number, N: string, L: number } } = {}
local lastRequest: { [Player]: number } = {}
local moving: { [Player]: boolean } = {} -- a move is waiting on UpdateAsync
local rng = Random.new()

local function tileKey(x: number, y: number): string
	return x .. "_" .. y
end

local function parseKey(k: string): (number, number)
	local x, y = string.match(k, "^(%d+)_(%d+)$")
	return tonumber(x) :: number, tonumber(y) :: number
end

local function castleLevel(data): number
	local castle = data.Buildings and data.Buildings.Castle_1
	return castle and castle.Level or 1
end

local function getStore(): DataStore?
	if memoryOnly or PlayerDataService.IsMemoryMode() then
		memoryOnly = true
		return nil
	end
	if not store then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(Cfg.DataStoreName)
		end)
		if not ok then
			warn("[KingdomMapService] DataStore unavailable, map kept in memory:", result)
			memoryOnly = true
			return nil
		end
		store = result
	end
	return store
end

-- Runs fn(castleTable) on the saved list (UpdateAsync) and keeps the result in `castles`.
-- fn may run more than once (DataStore retries), so it must only change the table it gets.
local function updateCastles(fn: ({ [string]: any }) -> ()): boolean
	local ds = getStore()
	if not ds then
		fn(castles)
		return true
	end
	for attempt = 1, GameConfig.Save.MaxRetries do
		local ok, result = pcall(function()
			return ds:UpdateAsync(storeKey, function(old)
				old = old or { Castles = {} }
				old.Castles = old.Castles or {}
				fn(old.Castles)
				return old
			end)
		end)
		if ok then
			castles = result.Castles
			return true
		end
		warn("[KingdomMapService] UpdateAsync failed:", result)
		task.wait(GameConfig.Save.RetryDelay * attempt)
	end
	return false
end

local function readCastles()
	local ds = getStore()
	if not ds then
		return
	end
	local ok, result = pcall(function()
		return ds:GetAsync(storeKey)
	end)
	if ok then
		castles = (result and result.Castles) or {}
	else
		warn("[KingdomMapService] GetAsync failed:", result)
	end
end

-- Is (x, y) free for a new castle, with `gap` empty tiles around it (no castles or nodes there)?
local function isFree(list, x: number, y: number, gap: number): boolean
	if not KingdomMapGen.CanHoldCastle(x, y) or list[tileKey(x, y)] then
		return false
	end
	for dy = -gap, gap do
		for dx = -gap, gap do
			if (dx ~= 0 or dy ~= 0) and KingdomMapGen.InBounds(x + dx, y + dy) then
				if list[tileKey(x + dx, y + dy)] or KingdomMapGen.GetFeatureAt(x + dx, y + dy) then
					return false
				end
			end
		end
	end
	return true
end

-- A random free tile in `zone` (default: the new-player zone; any zone and no gap if that zone is full)
local function pickFreeTile(list, zone: number?): (number?, number?)
	local size = Cfg.Size
	local z = zone or Cfg.NewPlayerZone
	for _, pass in ipairs({ { z, Cfg.CastleGap }, { z, 0 }, { nil, 0 } }) do
		local zone, gap = pass[1], pass[2]
		for _ = 1, 3000 do
			local x, y = rng:NextInteger(1, size), rng:NextInteger(1, size)
			if (not zone or KingdomMapGen.GetZone(x, y) == zone) and isFree(list, x, y, gap) then
				return x, y
			end
		end
	end
	return nil, nil
end

-- Puts the player's castle on the map. mode:
--   nil      = keep their saved tile if it is still theirs, else a new one (join)
--   "Random" = a new random free tile in the zone they are in now
--   "Target" = exactly (tx, ty); fails if a castle is there (the caller checks ground/nodes)
-- The old entry is only removed once the new tile is taken, all inside one UpdateAsync.
local function placePlayer(player: Player, mode: string?, tx: number?, ty: number?): (boolean, string?)
	local data = PlayerDataService.GetData(player)
	if not data then
		return false, "Data not loaded"
	end
	local userId = player.UserId
	local wanted = data.MapTile
	local zone = wanted and KingdomMapGen.GetZone(wanted.X, wanted.Y) or nil
	local entry = { U = userId, N = player.Name, L = castleLevel(data) }
	local chosenX, chosenY, reason

	local ok = updateCastles(function(list)
		chosenX, chosenY, reason = nil, nil, nil
		if mode == nil and wanted then
			local current = list[tileKey(wanted.X, wanted.Y)]
			if (current and current.U == userId) or (not current and KingdomMapGen.CanHoldCastle(wanted.X, wanted.Y)) then
				chosenX, chosenY = wanted.X, wanted.Y
			end
		end
		if mode == "Target" then
			local current = list[tileKey(tx :: number, ty :: number)]
			if current then
				reason = if current.U == userId then "Your castle is already here" else "Tile taken"
				return
			end
			chosenX, chosenY = tx, ty
		elseif not chosenX then
			chosenX, chosenY = pickFreeTile(list, if mode == "Random" then zone else nil)
		end
		if not chosenX then
			return
		end
		local newKey = tileKey(chosenX, chosenY)
		for k, c in pairs(list) do
			if c.U == userId and k ~= newKey then
				list[k] = nil
			end
		end
		list[newKey] = entry
	end)
	if not ok then
		return false, "Map save failed"
	end
	if not chosenX then
		return false, reason or "Map is full"
	end
	if player.Parent then
		data.MapTile = { X = chosenX, Y = chosenY }
		data.KingdomId = Cfg.KingdomId
		PlayerDataService.Sync(player)
	end
	return true
end

-- Every RefreshSeconds: write castle level/name changes of players on this server, else just re-read
local function refreshLoop()
	while true do
		task.wait(Cfg.RefreshSeconds)
		local changes = {}
		for _, player in ipairs(Players:GetPlayers()) do
			local data = PlayerDataService.GetData(player)
			local tile = data and data.MapTile
			if tile then
				local k = tileKey(tile.X, tile.Y)
				local c = castles[k]
				local level = castleLevel(data)
				if c and c.U == player.UserId and (c.L ~= level or c.N ~= player.Name) then
					changes[k] = { U = player.UserId, N = player.Name, L = level }
				end
			end
		end
		if next(changes) then
			updateCastles(function(list)
				for k, entry in pairs(changes) do
					local c = list[k]
					if c and c.U == entry.U then
						list[k] = entry
					end
				end
			end)
		else
			readCastles()
		end
	end
end

local function castleList()
	local list = {}
	for k, c in pairs(castles) do
		local x, y = parseKey(k)
		if x then
			table.insert(list, { X = x, Y = y, UserId = c.U, Name = c.N, Level = c.L })
		end
	end
	return list
end

local function moveReadyAt(data): number
	return (data.LastMoveAt or 0) + Cfg.Move.CooldownSeconds
end

-- "MoveRandom" / "MoveTo" (x, y): paid castle move with a cooldown. Nothing from the client is trusted.
local function moveCastle(player: Player, mode: string, x: any, y: any)
	local data = PlayerDataService.GetData(player)
	if not data or not data.MapTile then
		return { Ok = false, Error = "Data not loaded" }
	end
	if moving[player] then
		return { Ok = false, Error = "Busy" }
	end
	if data.Marches and next(data.Marches) then
		return { Ok = false, Error = "Your armies must be home first" }
	end
	local left = moveReadyAt(data) - os.time()
	if left > 0 then
		return { Ok = false, Error = ("Move again in %ds"):format(left) }
	end
	if mode == "Target" then
		if type(x) ~= "number" or type(y) ~= "number" or x % 1 ~= 0 or y % 1 ~= 0 or not KingdomMapGen.InBounds(x, y) then
			return { Ok = false, Error = "Bad tile" }
		end
		if not KingdomMapGen.CanHoldCastle(x, y) or KingdomMapGen.GetFeatureAt(x, y) then
			return { Ok = false, Error = "Can't build a castle here" }
		end
	end
	local cost = if mode == "Target" then Cfg.Move.AdvancedCost else Cfg.Move.RandomCost
	for resource, amount in pairs(cost) do
		if (data.Resources[resource] or 0) < amount then
			return { Ok = false, Error = "Not enough " .. resource }
		end
	end

	moving[player] = true
	local ok, err = placePlayer(player, mode, x, y)
	moving[player] = nil
	if not ok then
		return { Ok = false, Error = err }
	end
	for resource, amount in pairs(cost) do
		data.Resources[resource] = math.max(0, (data.Resources[resource] or 0) - amount)
	end
	data.LastMoveAt = os.time()
	PlayerDataService.Sync(player)
	print(("[KingdomMapService] %s moved castle to %d, %d"):format(player.Name, data.MapTile.X, data.MapTile.Y))
	return { Ok = true, MyTile = data.MapTile, MoveReadyAt = moveReadyAt(data) }
end

-- While the map is open, stream the world around a point on the map instead of around the character
-- (StreamingEnabled: the map Terrain is far from every city). x = nil goes back to the character.
local focusParts: { [Player]: BasePart } = {}
local lastFocus: { [Player]: number } = {}

local function setFocus(player: Player, x: any, y: any)
	if x == nil then -- closing the map is never rate limited
		player.ReplicationFocus = nil
		if focusParts[player] then
			focusParts[player]:Destroy()
			focusParts[player] = nil
		end
		return { Ok = true }
	end
	local now = os.clock()
	if now - (lastFocus[player] or 0) < Cfg.FocusMinInterval then
		return { Ok = false, Error = "Too fast" }
	end
	lastFocus[player] = now
	if typeof(x) ~= "number" or typeof(y) ~= "number" or x ~= x or y ~= y then
		return { Ok = false, Error = "Bad tile" }
	end
	x = math.clamp(math.floor(x), 1, Cfg.Size)
	y = math.clamp(math.floor(y), 1, Cfg.Size)
	local part = focusParts[player]
	if not part then
		part = Instance.new("Part")
		part.Name = "MapFocus_" .. player.UserId
		part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
		part.Transparency = 1
		part.Size = Vector3.new(1, 1, 1)
		part.Parent = workspace
		focusParts[player] = part
	end
	part.Position = KingdomMapGen.TileToWorld(x, y)
	player.ReplicationFocus = part
	return { Ok = true }
end

local function onMapAction(player: Player, action: any, x: any, y: any)
	if action == "Focus" then
		return setFocus(player, x, y) -- its own rate limit: it comes while the camera moves
	end
	local now = os.clock()
	if now - (lastRequest[player] or 0) < GameConfig.Remotes.MinRequestInterval then
		return { Ok = false, Error = "Too fast" }
	end
	lastRequest[player] = now
	if action == "GetCastles" then
		local data = PlayerDataService.GetData(player)
		return {
			Ok = true,
			Castles = castleList(),
			MyTile = data and data.MapTile,
			MoveReadyAt = data and moveReadyAt(data),
		}
	elseif action == "MoveRandom" then
		return moveCastle(player, "Random")
	elseif action == "MoveTo" then
		return moveCastle(player, "Target", x, y)
	end
	return { Ok = false, Error = "Unknown action" }
end

-- Admin: move the player's castle to a new random tile (free, no cooldown)
function KingdomMapService.MoveRandom(player: Player): (boolean, string?)
	return placePlayer(player, "Random")
end

-- Admin: puts a castle for a fake player (userId) on the closest free tile to (nx, ny), or on a random
-- free tile if nx is nil, replacing its old one. Returns x, y or nil, error.
function KingdomMapService.PlaceDummy(userId: number, name: string, level: number, nx: number?, ny: number?)
	local chosenX, chosenY
	local ok = updateCastles(function(list)
		chosenX, chosenY = nil, nil
		for k, c in pairs(list) do
			if c.U == userId then
				list[k] = nil
			end
		end
		if not nx or not ny then
			chosenX, chosenY = pickFreeTile(list, nil)
		end
		for r = 1, 12 do
			if chosenX or not nx or not ny then
				break
			end
			for dy = -r, r do
				for dx = -r, r do
					local x, y = nx + dx, ny + dy
					if not chosenX and math.max(math.abs(dx), math.abs(dy)) == r and KingdomMapGen.InBounds(x, y)
						and isFree(list, x, y, 0) and not KingdomMapGen.GetFeatureAt(x, y) then
						chosenX, chosenY = x, y
					end
				end
			end
			if chosenX then
				break
			end
		end
		if chosenX then
			list[tileKey(chosenX, chosenY)] = { U = userId, N = name, L = level }
		end
	end)
	if not ok then
		return nil, "Map save failed"
	end
	if not chosenX then
		return nil, "No free tile nearby"
	end
	return chosenX, chosenY
end

-- The castle on (x, y) from the latest list: { U, N, L } or nil
function KingdomMapService.GetCastleAt(x: number, y: number)
	return castles[tileKey(x, y)]
end

function KingdomMapService.GetCastleCount(): number
	local n = 0
	for _ in pairs(castles) do
		n += 1
	end
	return n
end

function KingdomMapService.Start(dataService)
	PlayerDataService = dataService

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("MapAction") :: RemoteFunction
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "MapAction"
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onMapAction

	PlayerDataService.Loaded:Connect(function(player)
		task.spawn(function()
			local ok, err = placePlayer(player)
			if not ok then
				warn("[KingdomMapService] Could not place", player.Name, err)
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
		moving[player] = nil
		lastFocus[player] = nil
		if focusParts[player] then
			focusParts[player]:Destroy()
			focusParts[player] = nil
		end
	end)

	task.spawn(function()
		readCastles()
		refreshLoop()
	end)
end

return KingdomMapService
