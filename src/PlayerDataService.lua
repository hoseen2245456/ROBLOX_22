-- PlayerDataService: loads, saves and session-locks each player's data.
-- Location in Studio: ServerScriptService.Services.PlayerDataService (ModuleScript)
-- Rules followed:
--   * Every write uses UpdateAsync with a session lock, so two servers never own one player.
--   * Saves every GameConfig.Save.AutoSaveInterval seconds, on leave, and on BindToClose.
--   * Time is os.time() on the server. LastSeen is stored so offline progress can be computed.
--   * The client never writes data. It only receives a read-only snapshot through Remotes.DataSync.
-- In Studio, if the place is unpublished or API access is off, it falls back to an in-memory
-- store (nothing persists) and prints a warning.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local SaveCfg = GameConfig.Save

local PlayerDataService = {}

local SESSION_ID = game.JobId ~= "" and game.JobId or ("Studio_" .. HttpService:GenerateGUID(false))

local profiles = {} -- [Player] = { Data, Key, OfflineSeconds, Saving, Leaving }
local loadedEvent = Instance.new("BindableEvent")
-- Fires (player) once data is ready. Read it with GetData: a BindableEvent would pass a copy of the table.
PlayerDataService.Loaded = loadedEvent.Event

local store = nil
local memoryMode = false
local memoryStore = {}
local dataSync: RemoteEvent

local function log(...)
	print("[PlayerDataService]", ...)
end

local function deepCopy(t)
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = if type(v) == "table" then deepCopy(v) else v
	end
	return copy
end

local function makeTemplate()
	local troops = {}
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		troops[troopType] = { 0, 0, 0, 0 } -- count per tier T1..T4
	end
	return {
		Version = SaveCfg.DataVersion,
		CreatedAt = os.time(),
		LastSeen = os.time(),
		Resources = deepCopy(GameConfig.StartingResources),
		Buildings = {
			Castle_1 = { Type = "Castle", Level = 1 },
			Walls_1 = { Type = "Walls", Level = 1 },
		},
		Timers = {}, -- [timerId] = { Kind, Target, StartedAt, EndsAt }
		Troops = troops,
		Heroes = {},
		Stats = { Power = 0 },
		ExtraBuilders = 0, -- second builder (Game Pass)
		Marches = {}, -- [marchId] = march (MarchService)
		Reports = {}, -- battle reports, newest first (BattleService)
		-- Civilization, KingdomId, AllianceId, MapTile ({X, Y} on the kingdom map) are set later (nil until set)
	}
end

-- Adds any keys the template has but the saved data is missing (new features after launch)
local function reconcile(data, template)
	for k, v in pairs(template) do
		if data[k] == nil then
			data[k] = if type(v) == "table" then deepCopy(v) else v
		elseif type(v) == "table" and type(data[k]) == "table" then
			reconcile(data[k], v)
		end
	end
end

local function withRetries(fn)
	local lastErr
	for attempt = 1, SaveCfg.MaxRetries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		warn("[PlayerDataService] DataStore attempt", attempt, "failed:", result)
		task.wait(SaveCfg.RetryDelay * attempt)
	end
	return false, lastErr
end

local function initStore()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(SaveCfg.PlayerDataStoreName)
	end)
	if ok and RunService:IsStudio() then
		-- In Studio, an unpublished place or disabled API access only fails on the first real call
		local probeOk = pcall(function()
			result:GetAsync("__probe")
		end)
		ok = probeOk
	end
	if ok then
		store = result
		log("Using DataStore", SaveCfg.PlayerDataStoreName)
	else
		memoryMode = true
		warn("[PlayerDataService] DataStore unavailable. Using IN-MEMORY data (nothing is saved).",
			"Publish the place and enable Studio Access to API Services to save for real.")
	end
end

local function loadData(player: Player)
	local key = SaveCfg.PlayerKeyPrefix .. player.UserId

	if memoryMode then
		local saved = memoryStore[key]
		return true, if saved then deepCopy(saved) else makeTemplate(), key
	end

	for _ = 1, SaveCfg.LockWaitAttempts do
		local lockedElsewhere = false
		local ok, result = withRetries(function()
			return store:UpdateAsync(key, function(old)
				lockedElsewhere = false
				local now = os.time()
				local lock = old and old.SessionLock
				if lock and lock.Id ~= SESSION_ID and now - lock.Time < SaveCfg.SessionLockTimeout then
					lockedElsewhere = true
					return nil -- cancel: another live server owns this player
				end
				local data = old or makeTemplate()
				data.SessionLock = { Id = SESSION_ID, Time = now }
				return data
			end)
		end)
		if not ok then
			return false, nil, key
		end
		if not lockedElsewhere then
			return true, result, key
		end
		if not player.Parent then
			return false, nil, key
		end
		log("Data for", player.Name, "is locked by another server, waiting...")
		task.wait(SaveCfg.LockWaitSeconds)
	end
	return false, nil, key
end

-- Saves one profile. release = true also clears the session lock (player left / server closing).
local function saveProfile(player: Player, profile, release: boolean)
	while profile.Saving do
		task.wait()
	end
	profile.Saving = true
	profile.Data.LastSeen = os.time()

	if memoryMode then
		memoryStore[profile.Key] = deepCopy(profile.Data)
		profile.Saving = false
		return true
	end

	local stolen = false
	local snapshot = deepCopy(profile.Data)
	local ok, err = withRetries(function()
		return store:UpdateAsync(profile.Key, function(old)
			stolen = false
			local lock = old and old.SessionLock
			if lock and lock.Id ~= SESSION_ID then
				stolen = true
				return nil -- another server took over; never overwrite its newer data
			end
			snapshot.SessionLock = if release then nil else { Id = SESSION_ID, Time = os.time() }
			return snapshot
		end)
	end)
	profile.Saving = false

	if not ok then
		warn("[PlayerDataService] Save failed for", player.Name, err)
		return false
	end
	if stolen then
		warn("[PlayerDataService] Session for", player.Name, "was taken by another server")
		profiles[player] = nil
		if player.Parent then
			player:Kick("Your kingdom was opened in another server. Please rejoin.")
		end
		return false
	end
	return true
end

-- Client-safe, read-only copy of the data
local function makeSnapshot(data)
	return {
		Resources = data.Resources,
		Buildings = data.Buildings,
		Timers = data.Timers,
		Troops = data.Troops,
		Heroes = data.Heroes,
		Stats = data.Stats,
		Civilization = data.Civilization,
		Builders = GameConfig.GetBuilderCount(data.ExtraBuilders),
		MapTile = data.MapTile,
		Marches = data.Marches,
		Reports = data.Reports,
		ServerTime = os.time(),
	}
end

function PlayerDataService.Sync(player: Player)
	local profile = profiles[player]
	if profile then
		dataSync:FireClient(player, makeSnapshot(profile.Data))
	end
end

function PlayerDataService.GetData(player: Player)
	local profile = profiles[player]
	return profile and profile.Data
end

function PlayerDataService.WaitForData(player: Player, timeout: number?)
	local deadline = os.clock() + (timeout or 30)
	while player.Parent and not profiles[player] and os.clock() < deadline do
		task.wait(0.1)
	end
	return PlayerDataService.GetData(player)
end

-- Seconds the player was away since their last save (for offline production/timers)
function PlayerDataService.GetOfflineSeconds(player: Player): number
	local profile = profiles[player]
	return profile and profile.OfflineSeconds or 0
end

function PlayerDataService.IsMemoryMode(): boolean
	return memoryMode
end

-- Fresh data for a new player (admin test castles)
function PlayerDataService.NewData()
	return makeTemplate()
end

-- Player, data of someone on this server (data is nil while they are loading or leaving)
function PlayerDataService.FindByUserId(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return nil, nil
	end
	local profile = profiles[player]
	if not profile or profile.Leaving then
		return player, nil
	end
	return player, profile.Data
end

-- Changes the saved data of a player who is NOT on this server (UpdateAsync, so it is safe).
-- fn(data or nil) runs inside the transform (may run more than once, must not yield) and returns the
-- new data, or nil to change nothing. Returns "Done", "Cancelled", "Locked" (a live server owns that
-- player, or they are on this one) or "Failed".
function PlayerDataService.UpdateOffline(userId: number, fn): string
	local key = SaveCfg.PlayerKeyPrefix .. userId
	if Players:GetPlayerByUserId(userId) then
		return "Locked"
	end
	if memoryMode then
		local saved = memoryStore[key]
		local data = if saved then deepCopy(saved) else nil
		if data then
			reconcile(data, makeTemplate())
		end
		local new = fn(data)
		if not new then
			return "Cancelled"
		end
		memoryStore[key] = deepCopy(new)
		return "Done"
	end
	local status = "Cancelled"
	local ok = withRetries(function()
		return store:UpdateAsync(key, function(old)
			status = "Cancelled"
			local lock = old and old.SessionLock
			if lock and os.time() - lock.Time < SaveCfg.SessionLockTimeout then
				status = "Locked"
				return nil
			end
			if old then
				reconcile(old, makeTemplate())
			end
			local new = fn(old)
			if new then
				status = "Done"
			end
			return new
		end)
	end)
	return if ok then status else "Failed"
end

local function onPlayerAdded(player: Player)
	local ok, data, key = loadData(player)
	if not ok then
		if player.Parent then
			player:Kick("Could not load your kingdom. Please rejoin in a moment.")
		end
		return
	end

	data.SessionLock = nil
	reconcile(data, makeTemplate())
	local profile = {
		Data = data,
		Key = key,
		OfflineSeconds = math.max(0, os.time() - (data.LastSeen or os.time())),
		Saving = false,
		Leaving = false,
	}
	profiles[player] = profile

	if not player.Parent then
		-- Left while loading: release the lock we just took
		profile.Leaving = true
		saveProfile(player, profile, true)
		profiles[player] = nil
		return
	end

	log("Loaded", player.Name, "| offline", profile.OfflineSeconds, "s | memoryMode", memoryMode)
	loadedEvent:Fire(player)
	PlayerDataService.Sync(player)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile or profile.Leaving then
		return
	end
	profile.Leaving = true
	saveProfile(player, profile, true)
	if profiles[player] == profile then
		profiles[player] = nil
	end
	log("Saved and released", player.Name)
end

function PlayerDataService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	dataSync = remotes:FindFirstChild("DataSync") :: RemoteEvent
	if not dataSync then
		dataSync = Instance.new("RemoteEvent")
		dataSync.Name = "DataSync"
		dataSync.Parent = remotes
	end
	-- A client asks for a fresh copy when its scripts start (the first Sync can arrive before they listen)
	local lastSyncRequest = {}
	dataSync.OnServerEvent:Connect(function(player)
		local clock = os.clock()
		if lastSyncRequest[player] and clock - lastSyncRequest[player] < GameConfig.Remotes.SyncRequestInterval then
			return
		end
		lastSyncRequest[player] = clock
		PlayerDataService.Sync(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastSyncRequest[player] = nil
	end)

	initStore()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	-- Autosave
	task.spawn(function()
		while true do
			task.wait(SaveCfg.AutoSaveInterval)
			for player, profile in pairs(profiles) do
				if not profile.Leaving then
					task.spawn(saveProfile, player, profile, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		for player, profile in pairs(profiles) do
			if not profile.Leaving then
				profile.Leaving = true
				task.spawn(function()
					saveProfile(player, profile, true)
					if profiles[player] == profile then
						profiles[player] = nil
					end
				end)
			end
		end
		-- Wait for every save, including ones PlayerRemoving already started.
		-- A profile is removed from `profiles` only after its final save finishes.
		local deadline = os.clock() + SaveCfg.CloseTimeout
		while next(profiles) ~= nil and os.clock() < deadline do
			task.wait()
		end
	end)
end

return PlayerDataService
