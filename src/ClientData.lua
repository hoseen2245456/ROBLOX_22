-- ClientData: the client's read-only copy of the player's data (from Remotes.DataSync).
-- Location in Studio: StarterPlayer.StarterPlayerScripts.Controllers.ClientData (ModuleScript)
-- For display only. The server never trusts anything the client computes from it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientData = {}

local current = nil
local changedEvent = Instance.new("BindableEvent")
ClientData.Changed = changedEvent.Event -- fires (snapshot) on every sync

-- The latest snapshot: { Resources, Buildings, Timers, Troops, Heroes, Stats, Civilization, ServerTime }, or nil
function ClientData.Get()
	return current
end

function ClientData.Start()
	local dataSync = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DataSync") :: RemoteEvent
	dataSync.OnClientEvent:Connect(function(snapshot)
		current = snapshot
		changedEvent:Fire(snapshot)
	end)
	-- The first sync can be sent before this script runs, so ask for a fresh copy
	dataSync:FireServer()
end

return ClientData
