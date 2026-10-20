-- MarchService: armies leave the castle, walk to a map tile and come back (phase 2).
-- Location in Studio: ServerScriptService.Services.MarchService (ModuleScript)
-- Rules followed:
--   * The client only asks (Remotes.MarchAction). The server checks the tile, the troop counts and the
--     march limit, takes the troops out of data.Troops and works out every time itself.
--   * A march is data.Marches[id] = { Id, From, To, Kind, Troops, Count, StartAt, ArriveAt, ReturnAt, Turn }.
--     Out: From -> To between StartAt and ArriveAt. Back: (Turn of the way) -> From between ArriveAt
--     and ReturnAt. Turn = 1 normally, less after a recall. No loop moves armies: the client draws them
--     from these times. While the player is online each march gets one task.delay for ReturnAt; marches
--     that came back offline are finished on load.
--   * On arrival (ArriveAt) a march at a monster (BattleService) or a castle (AttackService) fights and
--     comes home with the survivors, the wounded and the loot. Other tiles turn the army back until
--     gathering exists.
--     march.Arrived is set once that is done; a recalled march (march.Recalled) never arrives.
--   * Every server shares its marches in a MemoryStore sorted map, so all players see all armies.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local KingdomMapGen = require(ReplicatedStorage.Modules.KingdomMapGen)
local BattleService = require(script.Parent.BattleService)
local AttackService = require(script.Parent.AttackService)
local Cfg = GameConfig.March

local MarchService = {}

local PlayerDataService, KingdomMapService
local lastRequest: { [Player]: number } = {}
local rng = Random.new()
local scheduled = setmetatable({}, { __mode = "k" }) -- march -> token of its latest task.delay

local sharedMap: MemoryStoreSortedMap? = nil
local shareBroken = false
local local_ = {} -- "userId_marchId" -> shared entry, for marches of players on this server
local remote_ = {} -- same shape, last read from MemoryStore (every server)
local lastRead = 0

------------------------------------------------------------------------
-- Shared list (MemoryStore). Entry: { U, N, F = {x, y}, T = {x, y}, C, S, A, R, Tu }
------------------------------------------------------------------------
local function getShared(): MemoryStoreSortedMap?
	if shareBroken then
		return nil
	end
	if not sharedMap then
		local ok, result = pcall(function()
			return MemoryStoreService:GetSortedMap(Cfg.ShareKey .. GameConfig.Map.KingdomId)
		end)
		if not ok then
			warn("[MarchService] MemoryStore unavailable, marches shown on this server only:", result)
			shareBroken = true
			return nil
		end
		sharedMap = result
	end
	return sharedMap
end

local function shareKey(userId: number, march): string
	return userId .. "_" .. march.Id
end

local function publish(player: Player, march)
	local key = shareKey(player.UserId, march)
	local entry = {
		U = player.UserId,
		N = player.Name,
		F = { march.From.X, march.From.Y },
		T = { march.To.X, march.To.Y },
		C = march.Count,
		S = march.StartAt,
		A = march.ArriveAt,
		R = march.ReturnAt,
		Tu = march.Turn,
	}
	local_[key] = entry
	local map = getShared()
	if map then
		task.spawn(function()
			local ok, err = pcall(function()
				map:SetAsync(key, entry, math.max(30, march.ReturnAt - os.time() + 30))
			end)
			if not ok then
				warn("[MarchService] SetAsync failed:", err)
			end
		end)
	end
end

local function unpublish(userId: number, march)
	local key = shareKey(userId, march)
	local_[key] = nil
	remote_[key] = nil
	local map = getShared()
	if map then
		task.spawn(function()
			pcall(function()
				map:RemoveAsync(key)
			end)
		end)
	end
end

local function readShared()
	local map = getShared()
	if not map or os.clock() - lastRead < Cfg.ShareReadSeconds then
		return
	end
	lastRead = os.clock()
	local ok, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, 200)
	end)
	if not ok then
		warn("[MarchService] GetRangeAsync failed:", items)
		return
	end
	local fresh = {}
	for _, item in ipairs(items) do
		fresh[item.key] = item.value
	end
	remote_ = fresh
end

-- Every march still out: this server's (always fresh) plus the other servers' (from MemoryStore)
local function allMarches()
	readShared()
	local now = os.time()
	local list = {}
	local seen = {}
	for _, source in ipairs({ local_, remote_ }) do
		for key, e in pairs(source) do
			if not seen[key] and e.R > now then
				seen[key] = true
				table.insert(list, {
					UserId = e.U,
					Name = e.N,
					From = { X = e.F[1], Y = e.F[2] },
					To = { X = e.T[1], Y = e.T[2] },
					Count = e.C,
					StartAt = e.S,
					ArriveAt = e.A,
					ReturnAt = e.R,
					Turn = e.Tu,
				})
			end
		end
	end
	return list
end

------------------------------------------------------------------------
-- Marches of one player
------------------------------------------------------------------------
-- Puts a march's troops back home. Returns true if it was still out.
local function finish(player: Player, data, march): boolean
	if data.Marches[march.Id] ~= march then
		return false -- already finished
	end
	data.Marches[march.Id] = nil
	for resource, amount in pairs(march.Loot or {}) do
		data.Resources[resource] = (data.Resources[resource] or 0) + amount
	end
	for troopType, counts in pairs(march.Troops) do
		local home = data.Troops[troopType] or { 0, 0, 0, 0 }
		data.Troops[troopType] = home
		for tier, c in ipairs(counts) do
			home[tier] = (home[tier] or 0) + c
		end
	end
	unpublish(player.UserId, march)
	return true
end

local function needsArrival(march): boolean
	return not march.Arrived and not march.Recalled
end

-- The army reached its tile: fight a monster or a castle, or just turn back. Returns the battle report,
-- if any. A castle attack yields (AttackService may wait on the DataStore or another server).
local function arrive(player: Player, data, march)
	march.Arrived = true
	local report = nil
	if march.Kind == "Castle" then
		report = AttackService.Attack(player, data, march)
		print(("[MarchService] %s vs castle of %s: %s, %d left, %d wounded, %d dead"):format(player.Name, tostring(march.TargetName),
			report.Note or (if report.Win then "won" else "lost"), report.Attacker.Left, report.Attacker.Wounded, report.Attacker.Dead))
		if march.Count <= 0 then
			march.ReturnAt = march.ArriveAt
		end
	elseif march.Kind == "Monster" then
		local feature = KingdomMapGen.GetFeatureAt(march.To.X, march.To.Y)
		if feature and feature.Kind == "Monster" then
			report = BattleService.FightMonster(data, march, feature.Level)
			print(("[MarchService] %s %s vs Monster Lv%d: %d left, %d wounded, %d dead"):format(player.Name,
				report.Win and "won" or "lost", feature.Level, report.Attacker.Left, report.Attacker.Wounded, report.Attacker.Dead))
			if march.Count <= 0 then
				march.ReturnAt = march.ArriveAt -- nobody walks home
			end
		end
	end
	publish(player, march)
	return report
end

local function schedule(player: Player, data, march)
	local token = {}
	scheduled[march] = token
	local at = if needsArrival(march) then march.ArriveAt else march.ReturnAt
	task.delay(math.max(0, at - os.time()), function()
		if scheduled[march] ~= token or PlayerDataService.GetData(player) ~= data or data.Marches[march.Id] ~= march then
			return -- rescheduled (recall), left, or finished by admin
		end
		if needsArrival(march) then
			if os.time() < march.ArriveAt then
				schedule(player, data, march)
				return
			end
			arrive(player, data, march)
			if PlayerDataService.GetData(player) ~= data or data.Marches[march.Id] ~= march then
				return -- left or finished while the castle battle was waiting
			end
		end
		if os.time() < march.ReturnAt then
			PlayerDataService.Sync(player)
			schedule(player, data, march)
			return
		end
		finish(player, data, march)
		PlayerDataService.Sync(player)
	end)
end

-- What is on the tile, and the castle there (if any)
local function targetKind(x: number, y: number)
	local castle = KingdomMapService.GetCastleAt(x, y)
	if castle then
		return "Castle", castle
	end
	local feature = KingdomMapGen.GetFeatureAt(x, y)
	return if feature then feature.Kind else "Land", nil
end

-- Takes `want[type]` troops of each type out of `home`, best tier first. Returns the army or nil, reason.
local function pickTroops(home, want)
	local army = {}
	local total = 0
	for troopType, n in pairs(want) do
		if not table.find(GameConfig.TroopTypes, troopType) or type(n) ~= "number" or n % 1 ~= 0 or n < 0 then
			return nil, "Bad troops"
		end
		if n > 0 then
			local counts = home[troopType] or {}
			local have = 0
			for _, c in ipairs(counts) do
				have += c
			end
			if have < n then
				return nil, "Not enough " .. troopType
			end
			local taken = { 0, 0, 0, 0 }
			local left = n
			for tier = 4, 1, -1 do
				local t = math.min(left, counts[tier] or 0)
				taken[tier] = t
				left -= t
			end
			army[troopType] = taken
			total += n
		end
	end
	if total < 1 then
		return nil, "Pick some troops"
	end
	if total > Cfg.MaxTroops then
		return nil, ("At most %d troops in one army"):format(Cfg.MaxTroops)
	end
	return army, total
end

local function send(player: Player, data, x: any, y: any, want: any)
	if type(x) ~= "number" or type(y) ~= "number" or x % 1 ~= 0 or y % 1 ~= 0 or not KingdomMapGen.InBounds(x, y) then
		return { Ok = false, Error = "Bad tile" }
	end
	if not KingdomMapGen.IsPassable(x, y) then
		return { Ok = false, Error = "Armies can't cross the mountains" }
	end
	if type(want) ~= "table" then
		return { Ok = false, Error = "Bad troops" }
	end
	local home = data.MapTile
	if not home then
		return { Ok = false, Error = "Your castle is not on the map yet" }
	end
	if home.X == x and home.Y == y then
		return { Ok = false, Error = "That is your castle" }
	end
	local out = 0
	for _ in pairs(data.Marches) do
		out += 1
	end
	if out >= Cfg.MaxMarches then
		return { Ok = false, Error = ("All %d armies are out"):format(Cfg.MaxMarches) }
	end
	local army, total = pickTroops(data.Troops, want)
	if not army then
		return { Ok = false, Error = total }
	end

	-- No yield between the checks and here, so two requests can never send the same troops
	for troopType, taken in pairs(army) do
		local counts = data.Troops[troopType]
		for tier, t in ipairs(taken) do
			counts[tier] -= t
		end
	end
	local now = os.time()
	local oneWay = GameConfig.GetMarchSeconds(home.X, home.Y, x, y, army)
	local kind, castle = targetKind(x, y)
	if castle then
		data.ShieldOff = true -- attacking a castle ends your own beginner shield
	end
	local march = {
		Id = ("%d_%d"):format(now, rng:NextInteger(1000, 9999)),
		From = { X = home.X, Y = home.Y },
		To = { X = x, Y = y },
		Kind = kind,
		TargetId = castle and castle.U,
		TargetName = castle and castle.N,
		Troops = army,
		Count = total,
		StartAt = now,
		ArriveAt = now + oneWay,
		ReturnAt = now + oneWay * 2, -- the same way back after arriving
		Turn = 1,
	}
	data.Marches[march.Id] = march
	schedule(player, data, march)
	publish(player, march)
	PlayerDataService.Sync(player)
	print(("[MarchService] %s sent %d troops to %d, %d (%s), %ds each way"):format(player.Name, total, x, y, march.Kind, oneWay))
	return { Ok = true, Id = march.Id, ArriveAt = march.ArriveAt, ReturnAt = march.ReturnAt }
end

-- Turn an army back while it is still on the way out. It walks back the same distance it walked.
local function recall(player: Player, data, id: any)
	local march = type(id) == "string" and data.Marches[id]
	if not march then
		return { Ok = false, Error = "No such army" }
	end
	local now = os.time()
	if now >= march.ArriveAt then
		return { Ok = false, Error = "Already coming back" }
	end
	local walked = now - march.StartAt
	march.Turn = walked / (march.ArriveAt - march.StartAt)
	march.Recalled = true
	march.ArriveAt = now
	march.ReturnAt = now + walked
	schedule(player, data, march)
	publish(player, march)
	PlayerDataService.Sync(player)
	return { Ok = true, ReturnAt = march.ReturnAt }
end

local function onAction(player: Player, action: any, a: any, b: any, c: any)
	local clock = os.clock()
	if clock - (lastRequest[player] or 0) < GameConfig.Remotes.MinRequestInterval then
		return { Ok = false, Error = "Too fast" }
	end
	lastRequest[player] = clock
	if action == "GetMarches" then
		return { Ok = true, Marches = allMarches(), ServerTime = os.time() }
	end
	local data = PlayerDataService.GetData(player)
	if not data then
		return { Ok = false, Error = "Your kingdom is still loading" }
	end
	if action == "Send" then
		return send(player, data, a, b, c)
	elseif action == "Recall" then
		return recall(player, data, a)
	end
	return { Ok = false, Error = "Unknown action" }
end

local function onLoaded(player: Player)
	local data = PlayerDataService.GetData(player)
	if not data then
		return
	end
	local now = os.time()
	local back = 0
	for _, march in pairs(table.clone(data.Marches)) do
		if needsArrival(march) and march.ArriveAt <= now then
			arrive(player, data, march) -- arrived while the player was offline
			now = os.time() -- a castle battle may have waited
		end
		if march.ReturnAt <= now then
			finish(player, data, march)
			back += 1
		else
			schedule(player, data, march)
			publish(player, march)
		end
	end
	if back > 0 then
		print("[MarchService]", player.Name, "armies came home offline:", back)
		PlayerDataService.Sync(player)
	end
end

-- Is any army of this player out? (castle moves wait for every army)
function MarchService.HasMarches(data): boolean
	return data.Marches ~= nil and next(data.Marches) ~= nil
end

-- Admin: bring every army of this player home now. Returns how many came back.
function MarchService.FinishAll(player: Player): number
	local data = PlayerDataService.GetData(player)
	if not data then
		return 0
	end
	local n = 0
	for _, march in pairs(table.clone(data.Marches)) do
		if finish(player, data, march) then
			n += 1
		end
	end
	return n
end

-- Admin: armies still on the way out arrive now (monster battles happen). Returns how many arrived.
function MarchService.ArriveAll(player: Player): number
	local data = PlayerDataService.GetData(player)
	if not data then
		return 0
	end
	local now = os.time()
	local n = 0
	for _, march in pairs(table.clone(data.Marches)) do -- castle battles yield
		if needsArrival(march) and march.ArriveAt > now then
			local skip = march.ArriveAt - now
			march.StartAt -= skip
			march.ArriveAt = now
			march.ReturnAt -= skip
			arrive(player, data, march)
			schedule(player, data, march)
			n += 1
		end
	end
	return n
end

-- Admin: a test castle (userId < 0) marches on this player's castle and fights it on arrival. Only this
-- server's shared list holds it (the alert and the map see it like any other march). Returns ArriveAt.
function MarchService.DummyAttack(player: Player, userId: number, name: string, from, troops, seconds: number): number?
	local data = PlayerDataService.GetData(player)
	local home = data and data.MapTile
	if not home then
		return nil
	end
	local function count(army): number
		local n = 0
		for _, counts in pairs(army) do
			for _, c in ipairs(counts) do
				n += c
			end
		end
		return n
	end
	local now = os.time()
	local key = ("%d_D%d_%d"):format(userId, now, rng:NextInteger(1000, 9999))
	local entry = {
		U = userId,
		N = name,
		F = { from.X, from.Y },
		T = { home.X, home.Y },
		C = count(troops),
		S = now,
		A = now + seconds,
		R = now + seconds * 2,
		Tu = 1,
	}
	local_[key] = entry
	task.delay(seconds, function()
		local def = PlayerDataService.GetData(player)
		if def then
			local fight = BattleService.DefendCastle(def, {
				Army = troops, AttackerName = name, DefenderName = player.Name,
				X = home.X, Y = home.Y, At = entry.A, Id = key, IgnoreShield = true,
			})
			if not fight.Note then
				entry.C = count(fight.AttackerLeft) -- the survivors walk home
				PlayerDataService.Sync(player)
			end
			print(("[MarchService] %s attacked %s: %s"):format(name, player.Name, fight.Note or (if fight.Win then "won" else "lost")))
		end
		task.delay(seconds, function()
			local_[key] = nil
		end)
	end)
	return entry.A
end

function MarchService.Start(dataService, mapService)
	PlayerDataService = dataService
	KingdomMapService = mapService

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("MarchAction") :: RemoteFunction
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "MarchAction"
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onAction

	PlayerDataService.Loaded:Connect(onLoaded)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
		-- Their armies keep walking in the shared map (MemoryStore); drop only this server's copy
		for key, e in pairs(local_) do
			if e.U == player.UserId then
				local_[key] = nil
			end
		end
	end)
end

return MarchService
