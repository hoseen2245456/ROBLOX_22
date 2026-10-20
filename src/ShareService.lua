-- ShareService: players share a map tile (enemy castle, resource node, monster, rally point...) with the
-- whole kingdom. Everyone sees it in the map's "Shared" list and as a line in the chat.
-- Location in Studio: ServerScriptService.Services.ShareService (ModuleScript)
-- Rules followed:
--   * The client only sends x, y and one of GameConfig.Share.Tags. The server checks them and writes the
--     label itself from the tile (castle name/level, monster/node level), so there is no typed text.
--   * One share per player every Share.MinSeconds.
--   * Shares reach the other servers of the kingdom through MessagingService. Each server keeps the newest
--     Share.Keep in memory (nothing is saved: shares are only useful for a while).

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local KingdomMapGen = require(ReplicatedStorage.Modules.KingdomMapGen)
local Cfg = GameConfig.Share

local ShareService = {}

local KingdomMapService
local feed: RemoteEvent
local topic = Cfg.Topic .. GameConfig.Map.KingdomId
local shares = {} -- newest first: { Id, UserId, By, Tag, X, Y, Label, At }
local seen = {} -- [Id] = true
local lastShare: { [Player]: number } = {}

-- What is on the tile, in words
local function labelOf(x: number, y: number): string
	local castle = KingdomMapService.GetCastleAt(x, y)
	if castle then
		return ("%s's Castle Lv %d"):format(castle.N, castle.L)
	end
	local f = KingdomMapGen.GetFeatureAt(x, y)
	if f and f.Kind == "Monster" then
		return ("Monster Lv %d"):format(f.Level)
	elseif f then
		return ("%s Node Lv %d"):format(f.Resource or "?", f.Level)
	end
	return KingdomMapGen.GetBiome(x, y) or "Land"
end

-- Keeps a share and sends it to every player here. Returns false if it was already known.
local function add(entry): boolean
	if type(entry) ~= "table" or type(entry.Id) ~= "string" or seen[entry.Id] then
		return false
	end
	seen[entry.Id] = true
	table.insert(shares, 1, entry)
	while #shares > Cfg.Keep do
		local old = table.remove(shares)
		seen[old.Id] = nil
	end
	feed:FireAllClients(entry)
	return true
end

local function share(player: Player, x: any, y: any, tag: any)
	if type(x) ~= "number" or type(y) ~= "number" or x % 1 ~= 0 or y % 1 ~= 0 or not KingdomMapGen.InBounds(x, y) then
		return { Ok = false, Error = "Bad tile" }
	end
	if type(tag) ~= "string" or not table.find(Cfg.Tags, tag) then
		return { Ok = false, Error = "Bad tag" }
	end
	local now = os.time()
	local wait = (lastShare[player] or 0) + Cfg.MinSeconds - now
	if wait > 0 then
		return { Ok = false, Error = ("Share again in %ds"):format(wait) }
	end
	lastShare[player] = now
	local entry = {
		Id = HttpService:GenerateGUID(false),
		UserId = player.UserId,
		By = player.Name,
		Tag = tag,
		X = x,
		Y = y,
		Label = labelOf(x, y),
		At = now,
	}
	add(entry)
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(topic, entry)
		end)
		if not ok then
			warn("[ShareService] PublishAsync failed (other servers won't see it):", err)
		end
	end)
	print(("[ShareService] %s shared %s: %s (%d, %d)"):format(player.Name, tag, entry.Label, x, y))
	return { Ok = true }
end

local function onAction(player: Player, action: any, x: any, y: any, tag: any)
	if action == "Get" then
		return { Ok = true, Shares = shares, ServerTime = os.time() }
	elseif action == "Share" then
		return share(player, x, y, tag)
	end
	return { Ok = false, Error = "Unknown action" }
end

function ShareService.Start(mapService)
	KingdomMapService = mapService

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotes:FindFirstChild("ShareAction") :: RemoteFunction
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "ShareAction"
		remote.Parent = remotes
	end
	remote.OnServerInvoke = onAction
	feed = remotes:FindFirstChild("ShareFeed") :: RemoteEvent
	if not feed then
		feed = Instance.new("RemoteEvent")
		feed.Name = "ShareFeed"
		feed.Parent = remotes
	end

	Players.PlayerRemoving:Connect(function(player)
		lastShare[player] = nil
	end)

	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(topic, function(message)
				local e = message.Data
				-- Another server's share: check its shape (the label was made by that server)
				if type(e) == "table" and type(e.X) == "number" and type(e.Y) == "number" and table.find(Cfg.Tags, e.Tag)
					and type(e.By) == "string" and type(e.Label) == "string" and type(e.At) == "number" then
					add(e)
				end
			end)
		end)
		if not ok then
			warn("[ShareService] SubscribeAsync failed, shares stay on this server:", err)
		end
	end)
end

return ShareService
