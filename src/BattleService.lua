-- BattleService: battles by numbers (phase 2). No parts, no loops: one call works out the whole fight.
-- Location in Studio: ServerScriptService.Services.BattleService (ModuleScript)
-- Rules followed:
--   * Server only. MarchService calls it when an army arrives (online by task.delay, offline on load),
--     so nothing comes from the client and the result is known only after the arrival time.
--   * An army is { [troopType] = {n1, n2, n3, n4} }. The fight runs in rounds (GameConfig.Battle) and
--     keeps each round's totals so the client can replay it (the numbers going down).
--   * The attacker's losses are split into dead and wounded. Dead troops lower data.Stats.Power.
--     Wounded troops come home with the survivors (no hospital yet).
--   * Each battle adds a report to data.Reports (newest first, Battle.MaxReports kept).
--   * Castle attacks: AttackService finds the defender's data and calls DefendCastle on it, then
--     SettleAttack on the attacker. Both are plain table changes, so they also work inside UpdateAsync.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Cfg = GameConfig.Battle

local BattleService = {}

local function emptyCounts()
	return { 0, 0, 0, 0 }
end

local function total(army): number
	local n = 0
	for _, counts in pairs(army) do
		for _, c in ipairs(counts) do
			n += c
		end
	end
	return n
end

local function toStacks(army)
	local stacks = {}
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		for tier, c in ipairs(army[troopType] or {}) do
			if c > 0 then
				table.insert(stacks, { Type = troopType, Tier = tier, Start = c, N = c })
			end
		end
	end
	return stacks
end

local function alive(stacks): number
	local n = 0
	for _, s in ipairs(stacks) do
		n += s.N
	end
	return n
end

-- One side hits the other. Returns kills per enemy stack (applied later, so both sides hit at once).
local function hit(attackers, defenders)
	local kills = {}
	local enemyTotal = alive(defenders)
	if enemyTotal <= 0 then
		return kills
	end
	for _, a in ipairs(attackers) do
		if a.N > 0 then
			local base = a.N * GameConfig.TroopTiers[a.Tier].Attack * Cfg.DamageScale
			for i, d in ipairs(defenders) do
				if d.N > 0 then
					local mult = if GameConfig.Counters[a.Type] == d.Type then 1 + GameConfig.CounterBonus else 1
					local stats = GameConfig.TroopTiers[d.Tier]
					kills[i] = (kills[i] or 0) + base * (d.N / enemyTotal) * mult / (stats.Health + stats.Defense)
				end
			end
		end
	end
	return kills
end

local function apply(stacks, kills)
	for i, k in pairs(kills) do
		stacks[i].N = math.max(0, stacks[i].N - k)
	end
end

-- Whole troops left in each stack, back into army shape
local function leftArmy(stacks)
	local army = {}
	for _, s in ipairs(stacks) do
		army[s.Type] = army[s.Type] or emptyCounts()
		army[s.Type][s.Tier] += math.clamp(math.floor(s.N + 0.5), 0, s.Start)
	end
	return army
end

-- Pure fight between two armies. Returns { Win (attacker won), Rounds = {{a, d}, ...}, AttackerLeft, DefenderLeft }
function BattleService.Simulate(attacker, defender)
	local a = toStacks(attacker)
	local d = toStacks(defender)
	local rounds = { { math.floor(alive(a) + 0.5), math.floor(alive(d) + 0.5) } }
	for _ = 1, Cfg.MaxRounds do
		if alive(a) < 0.5 or alive(d) < 0.5 then
			break
		end
		local toD = hit(a, d)
		local toA = hit(d, a)
		apply(d, toD)
		apply(a, toA)
		table.insert(rounds, { math.floor(alive(a) + 0.5), math.floor(alive(d) + 0.5) })
	end
	local attackerLeft = leftArmy(a)
	local defenderLeft = leftArmy(d)
	return {
		Win = total(attackerLeft) > 0 and total(defenderLeft) == 0,
		Rounds = rounds,
		AttackerLeft = attackerLeft,
		DefenderLeft = defenderLeft,
	}
end

-- The army a monster of this level fights with
function BattleService.MonsterArmy(level: number)
	local m = Cfg.Monster
	local tier = m.TierByLevel[level] or m.TierByLevel[#m.TierByLevel]
	local army = {}
	for _, troopType in ipairs(GameConfig.TroopTypes) do
		local counts = emptyCounts()
		counts[tier] = m.TroopsPerLevel * level
		army[troopType] = counts
	end
	return army
end

local function addReport(data, report)
	data.Reports = data.Reports or {}
	table.insert(data.Reports, 1, report)
	while #data.Reports > Cfg.MaxReports do
		table.remove(data.Reports)
	end
end

-- Splits one side's losses into dead and wounded (Cfg.WoundedShare). The wounded go home with the
-- survivors. Returns the troops that are still alive, { Start, Left, Wounded, Dead } and the Power lost.
local function settleLosses(before, left)
	local home = {}
	local stats = { Start = 0, Left = 0, Wounded = 0, Dead = 0 }
	local powerLost = 0
	for troopType, counts in pairs(before) do
		local back = emptyCounts()
		for tier, c in ipairs(counts) do
			local l = math.clamp(left[troopType] and left[troopType][tier] or 0, 0, c)
			local lost = c - l
			local w = math.floor(lost * Cfg.WoundedShare)
			back[tier] = l + w
			stats.Start += c
			stats.Left += l
			stats.Wounded += w
			stats.Dead += lost - w
			powerLost += (lost - w) * GameConfig.TroopTiers[tier].Power
		end
		home[troopType] = back
	end
	return home, stats, powerLost
end

-- How much an army can carry home
local function carryOf(army): number
	local carry = 0
	for _, counts in pairs(army) do
		for tier, c in ipairs(counts) do
			carry += c * GameConfig.TroopTiers[tier].Load
		end
	end
	return carry
end

-- Scales loot down to what `carry` allows
local function capLoot(loot, carry: number)
	local want = 0
	for _, amount in pairs(loot) do
		want += amount
	end
	if want > carry then
		for resource, amount in pairs(loot) do
			loot[resource] = math.floor(amount * carry / want)
		end
	end
	return loot
end

-- The attacker's side of a battle: survivors + wounded go home with the loot. `fight` is
-- { Win, Rounds, AttackerLeft, Loot, Defender = {Name, Start, Lost}, Note? }. With a Note there was no
-- battle and the army just turns back. Changes march.Troops/Count/Loot, data.Stats.Power and data.Reports.
function BattleService.SettleAttack(data, march, kind: string, level: number?, fight)
	local stats
	if fight.Note then
		stats = { Start = march.Count, Left = march.Count, Wounded = 0, Dead = 0 }
		march.Loot = {}
	else
		local home, s, powerLost = settleLosses(march.Troops, fight.AttackerLeft)
		stats = s
		march.Troops = home
		march.Count = s.Left + s.Wounded
		march.Loot = if fight.Win then fight.Loot or {} else {}
		data.Stats.Power = math.max(0, data.Stats.Power - powerLost)
	end
	local report = {
		Id = march.Id,
		At = march.ArriveAt,
		Kind = kind,
		X = march.To.X,
		Y = march.To.Y,
		Level = level,
		Win = fight.Win == true and not fight.Note,
		Note = fight.Note,
		Rounds = fight.Rounds or {},
		Attacker = stats,
		Defender = fight.Defender,
		Loot = march.Loot,
	}
	addReport(data, report)
	return report
end

-- An army reached a monster. Returns the report (see SettleAttack).
function BattleService.FightMonster(data, march, level: number)
	local monster = BattleService.MonsterArmy(level)
	local result = BattleService.Simulate(march.Troops, monster)
	local loot = {}
	if result.Win then
		for resource, perLevel in pairs(Cfg.Monster.Loot) do
			loot[resource] = perLevel * level
		end
		capLoot(loot, carryOf(result.AttackerLeft))
	end
	local monsterStart = total(monster)
	result.Loot = loot
	result.Defender = { Name = ("Monster Lv%d"):format(level), Start = monsterStart, Lost = monsterStart - total(result.DefenderLeft) }
	return BattleService.SettleAttack(data, march, "Monster", level, result)
end

-- The defender's side of a castle attack, on the defender's data `def` (in memory, or inside an
-- UpdateAsync transform: no yields here). `a` = { Army, AttackerName, DefenderName, X, Y, At, Id, IgnoreShield? (admin test) }.
-- The defender fights with every troop at home, loses Power for the dead, gets a "Defense" report and,
-- if they lose, StealShare of each stored resource (up to what the survivors can carry).
-- Returns the fight for SettleAttack, or { Note } if there is no battle (def is then unchanged).
function BattleService.DefendCastle(def, a)
	local tile = def.MapTile
	if not tile or tile.X ~= a.X or tile.Y ~= a.Y then
		return { Note = "The castle had moved away", Defender = { Name = a.DefenderName, Start = 0, Lost = 0 } }
	end
	if not a.IgnoreShield and not def.ShieldOff and (def.CreatedAt or 0) + GameConfig.Kingdom.BeginnerShieldSeconds > a.At then
		return { Note = "Protected by the beginner shield", Defender = { Name = a.DefenderName, Start = 0, Lost = 0 } }
	end
	local result = BattleService.Simulate(a.Army, def.Troops)

	local home, stats, powerLost = settleLosses(def.Troops, result.DefenderLeft)
	def.Troops = home
	def.Stats = def.Stats or { Power = 0 }
	def.Stats.Power = math.max(0, (def.Stats.Power or 0) - powerLost)

	local loot = {}
	if result.Win then
		for _, resource in ipairs(GameConfig.Resources) do
			loot[resource] = math.floor((def.Resources[resource] or 0) * Cfg.Castle.StealShare)
		end
		capLoot(loot, carryOf(result.AttackerLeft))
		for resource, n in pairs(loot) do
			def.Resources[resource] = math.max(0, (def.Resources[resource] or 0) - n)
		end
	end

	local attackerStart = total(a.Army)
	local rounds = {}
	for i, r in ipairs(result.Rounds) do
		rounds[i] = { r[2], r[1] } -- "you" first
	end
	addReport(def, {
		Id = "D" .. a.Id,
		At = a.At,
		Kind = "Defense",
		X = a.X,
		Y = a.Y,
		Win = not result.Win,
		Rounds = rounds,
		Attacker = stats, -- the defender's own troops ("you")
		Defender = { Name = a.AttackerName, Start = attackerStart, Lost = attackerStart - total(result.AttackerLeft) },
		Loot = {},
		Stolen = loot,
	})

	return {
		Win = result.Win,
		Rounds = result.Rounds,
		AttackerLeft = result.AttackerLeft,
		Loot = loot,
		Defender = { Name = a.DefenderName, Start = stats.Start, Lost = stats.Start - stats.Left },
	}
end

return BattleService
