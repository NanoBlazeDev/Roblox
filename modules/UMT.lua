--[[
	UMT Toolkit — one Bloom module, four tabs
	Appears as "umt toolkit" in bloom / modules.
	Unload the module to deload the whole script cleanly.
]]

local BLOOM_URL   = "https://raw.githubusercontent.com/NanoBlazeDev/Roblox/refs/heads/main/UI/bloom-ui-lib.lua"
local TOOLKIT_URL = "https://raw.githubusercontent.com/NanoBlazeDev/Roblox/refs/heads/main/modules/UMT.lua"

if _G.__umtToolkit then pcall(_G.__umtToolkit) end
_G.__umtToolkit = nil

-- re-fire this toolkit after every teleport (server hop, rejoin, map change)
-- so the UI survives the transition and the user doesn't have to re-inject.
-- 5 retries with 1s backoff; on final failure show a Roblox notification.
local q = queue_on_teleport or queueonteleport or syn and syn.queue_on_teleport
if q then
	pcall(q, string.format([[
local URL = %q
local lastErr
for i = 1, 5 do
	local ok, src = pcall(game.HttpGet, game, URL)
	if ok and src and #src > 0 then
		local okRun, errRun = pcall(function() loadstring(src)() end)
		if okRun then return end
		lastErr = tostring(errRun)
	else
		lastErr = tostring(src)
	end
	task.wait(1)
end
pcall(function()
	game:GetService("StarterGui"):SetCore("SendNotification", {
		Title    = "umt toolkit",
		Text     = "re-inject failed: " .. (lastErr or "unknown"),
		Duration = 8,
	})
end)
]], TOOLKIT_URL))
end

local okB, Bloom = pcall(function()
	return loadstring(game:HttpGet(BLOOM_URL))()
end)
local function umtFail(stage, err)
	local msg = "[UMT] " .. stage .. " failed: " .. tostring(err)
	warn(msg)
	print(msg)
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title    = "UMT Toolkit",
			Text     = stage .. " failed — check console (F9)",
			Duration = 8,
		})
	end)
end

if not okB or type(Bloom) ~= "table" then
	umtFail("Bloom load", Bloom)
	return
end

local RS      = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TS      = game:GetService("TeleportService")
local HS      = game:GetService("HttpService")
local Workspace = workspace
local Terrain = Workspace.Terrain
local lp      = Players.LocalPlayer

local function tryReq(path)
	local ok, mod = pcall(function()
		local cur = RS
		for _, seg in ipairs(path) do cur = cur:WaitForChild(seg, 5) end
		return require(cur)
	end)
	return ok and mod or nil
end

local VC       = tryReq({ "Packages", "InnoVehicles", "VehicleController" })
local MT_mod   = tryReq({ "Packages", "Mining", "MineTerrain" })
local MUtils   = tryReq({ "Packages", "Mining", "MiningUtils" })
local MTF      = tryReq({ "Packages", "Mining", "MiningTimeFunction" })
local BlockDef = tryReq({ "Definitions", "BlockDefinitions" })
local Settings = tryReq({ "Settings" })
local MT = MT_mod and MT_mod.GetInstance and MT_mod.GetInstance() or nil

local CFG_NAME = "umt_default"  -- config slot name inside Bloom's shared config store

-- ============================================================
--  THE MODULE
-- ============================================================
local okMod, mod = pcall(function()
	return Bloom:Module({
		Name        = "umt toolkit",
		Version     = "1.0",
		Author      = "ExaVolt",
		Description = "ultimate mining tycoon tools — ore xray, vehicle boost, fastmine, server hop",
	})
end)
if not okMod or not mod then
	umtFail("Module registration", mod)
	return
end

local function notify(title, text, kind)
	pcall(function()
		mod.Window:Notify({ Title = title, Text = text, Kind = kind or "success", Duration = 3 })
	end)
end

-- shared cleanup bag
local bag = { folders = {}, flags = {}, hooks = {} }

-- ============================================================
--  TAB — ORE XRAY
-- ============================================================
do
	local tab = mod:Tab({ Name = "xray" })
	local sec = tab:Section("highlights")

	local state = { active = false, radius = 10, scanning = false }
	local folder = Instance.new("Folder")
	folder.Name = "UMT_XRay"
	folder.Parent = Workspace
	table.insert(bag.folders, folder)

	-- incremental highlight tracking: coord-key → {part, box}
	local shown = {}
	local function keyOf(c) return c.X * 1000000 + c.Y * 1000 + c.Z end

	local ORE_COLORS = {
		-- ores (wiki-matched)
		Tin           = Color3.fromRGB(215, 210, 180),  -- pale cream nuggets
		Iron          = Color3.fromRGB(220, 110,  40),  -- rust orange
		Lead          = Color3.fromRGB( 25,  25,  30),  -- near-black splotches
		Cobalt        = Color3.fromRGB( 40,  95, 220),  -- bright royal blue
		Aluminium     = Color3.fromRGB(230, 230, 235),  -- white crystal shards
		Silver        = Color3.fromRGB(210, 220, 230),  -- bright silver-white
		Uranium       = Color3.fromRGB(140, 240,  90),  -- radioactive neon green
		Vanadium      = Color3.fromRGB(170,  50,  40),  -- dark burgundy red
		Titanium      = Color3.fromRGB(100,  80, 170),  -- purple-blue
		Gold          = Color3.fromRGB(255, 215,  70),  -- bright yellow gold
		Tungsten      = Color3.fromRGB(110, 140,  70),  -- olive mossy green
		Molybdenum    = Color3.fromRGB(170, 185, 170),  -- pale silver-green
		Plutonium     = Color3.fromRGB( 40, 190, 255),  -- glowing cyan
		Palladium     = Color3.fromRGB(240, 190,  40),  -- bright gold-yellow
		Iridium       = Color3.fromRGB(200, 220, 240),  -- pale ice blue-white
		Adamantium    = Color3.fromRGB( 80, 220, 140),  -- bright green
		Thorium       = Color3.fromRGB(130, 220, 110),  -- lime green on purple
		Mithril       = Color3.fromRGB( 60, 220, 150),  -- vivid mint green
		Rhodium       = Color3.fromRGB(255, 130,  40),  -- hot orange glow
		Unobtainium   = Color3.fromRGB(255,  70, 240),  -- neon magenta
		-- gems (wiki-matched)
		Topaz         = Color3.fromRGB(245, 215,  70),  -- bright yellow
		Emerald       = Color3.fromRGB( 20, 180,  60),  -- vivid green
		Sapphire      = Color3.fromRGB( 30,  60, 230),  -- deep blue
		Ruby          = Color3.fromRGB(220,  25,  25),  -- bright red
		Diamond       = Color3.fromRGB(120, 220, 230),  -- cyan crystal
		Poudretteite  = Color3.fromRGB(230,  70, 230),  -- magenta pink
		Zultanite     = Color3.fromRGB(230, 140, 140),  -- salmon pink
		Grandidierite = Color3.fromRGB( 70, 210, 140),  -- teal green
		Musgravite    = Color3.fromRGB( 60, 100, 100),  -- dark teal
		Painite       = Color3.fromRGB(210,  60,  60),  -- deep crimson
	}

	local function clear()
		for _, c in ipairs(folder:GetChildren()) do c:Destroy() end
		table.clear(shown)
	end

	local function removeAt(k)
		local h = shown[k]
		if h then
			pcall(function() h.part:Destroy() end)
			pcall(function() h.box:Destroy() end)
			shown[k] = nil
		end
	end

	local function addAt(k, coord, color)
		local wp = Terrain:CellCenterToWorld(coord.X, coord.Y, coord.Z)
		local part = Instance.new("Part")
		part.Size, part.CFrame = Vector3.new(3.9,3.9,3.9), CFrame.new(wp)
		part.Anchored, part.CanCollide, part.CanTouch = true, false, false
		part.Transparency, part.Parent = 1, folder
		local box = Instance.new("BoxHandleAdornment")
		box.Adornee, box.Size = part, Vector3.new(3.8,3.8,3.8)
		box.Color3, box.Transparency = color, 0.3
		box.AlwaysOnTop, box.ZIndex, box.Parent = true, 5, folder
		shown[k] = { part = part, box = box }
	end

	-- compute which ore ids are worth showing right now
	-- = mineable (hardness/pickaxe <= limit) AND in top-N by value
	-- recomputed each scan so pickaxe upgrades expand the whitelist automatically
	state.topN = 2  -- top 2 ores + top 2 gems
	state.allowed = {}

	local function recomputeAllowed()
		state.allowed = {}
		if not (MUtils and BlockDef and Settings) then
			-- fallback: no filter, show everything with a color
			for id in pairs(ORE_COLORS) do state.allowed[id] = true end
			return
		end
		local hard  = MUtils.GetPlayerPickaxeHardnessClient()
		local limit = Settings.MiningHardnessRatioLimit
		local ores, gems = {}, {}
		for id, def in pairs(BlockDef) do
			if def.Hardness and not def.ExplosiveOnly and (def.Hardness/hard) <= limit then
				local e = { id = id, value = def.Value or 0 }
				if def.Types and def.Types.Ore then table.insert(ores, e) end
				if def.Types and def.Types.Gem then table.insert(gems, e) end
			end
		end
		table.sort(ores, function(a,b) return a.value > b.value end)
		table.sort(gems, function(a,b) return a.value > b.value end)
		for i = 1, math.min(state.topN, #ores) do state.allowed[ores[i].id] = true end
		for i = 1, math.min(state.topN, #gems) do state.allowed[gems[i].id] = true end
	end

	local function scan()
		if state.scanning or not MT then return 0 end
		state.scanning = true
		recomputeAllowed()
		local char = lp.Character
		if not char then state.scanning = false; return 0 end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then state.scanning = false; return 0 end

		local cell   = Terrain:WorldToCell(hrp.Position)
		local origin = Vector3int16.new(cell.X, cell.Y, cell.Z)
		local R = state.radius
		local R2 = R * R

		-- iterate ONLY cells within the radius cube via :Get(coord) — O(R^3)
		-- not :List() which iterates the entire cached mine (can be 50k+ cells)
		local desired = {}
		local getCell = MT._Cells.Get
		local Cells   = MT._Cells
		for x = origin.X - R, origin.X + R do
			for y = origin.Y - R, origin.Y + R do
				local dx = x - origin.X; local dy = y - origin.Y
				local dxy2 = dx*dx + dy*dy
				if dxy2 > R2 then continue end
				for z = origin.Z - R, origin.Z + R do
					local dz = z - origin.Z
					if dxy2 + dz*dz > R2 then continue end
					local coord = Vector3int16.new(x, y, z)
					local block = getCell(Cells, coord)
					if not block then continue end
					local oreId = block.Ore
					if not oreId then continue end
					if not state.allowed[oreId] then continue end
					local color = ORE_COLORS[oreId]
					if not color then continue end
					desired[keyOf(coord)] = { coord = coord, color = color }
				end
			end
		end

		-- remove highlights for cells no longer desired (mined, out of range, wrong ore)
		for k, _ in pairs(shown) do
			if not desired[k] then removeAt(k) end
		end
		-- add any new ones
		for k, info in pairs(desired) do
			if not shown[k] then addAt(k, info.coord, info.color) end
		end

		state.scanning = false
		local n = 0; for _ in pairs(shown) do n += 1 end
		return n
	end

	local toggle = sec:Toggle("xray_on", {
		Label = "xray enabled", Default = false,
		Callback = function(v)
			state.active = v
			if v then notify("xray on", scan() .. " ores", "success") else clear() end
		end,
	})
	sec:Int("xray_radius", {
		Label = "radius (cells)", Default = state.radius, Min = 3, Max = 40, Step = 1,
		Callback = function(v) state.radius = v; if state.active then scan() end end,
	})
	sec:Int("xray_topn", {
		Label = "top-N per category (ores+gems)",
		Default = state.topN, Min = 1, Max = 10, Step = 1,
		Callback = function(v) state.topN = v; if state.active then scan() end end,
	})
	sec:Keybind("xray_key", {
		Label = "toggle key", Default = Enum.KeyCode.X,
		OnPress = function() toggle:Set(not toggle:Get()) end,
	})
	sec:Button("xray_rescan", { Text = "rescan now",
		Callback = function() if state.active then notify("rescanned", scan() .. " ores", "info") end end,
	})

	local info = tab:Section("best mineable")
	local hLbl = info:Label("pickaxe hardness: —")
	local oLbl = info:Label("ore: —")
	local gLbl = info:Label("gem: —")

	local function refreshBest()
		if not (MUtils and BlockDef and Settings) then return end
		local hard  = MUtils.GetPlayerPickaxeHardnessClient()
		local limit = Settings.MiningHardnessRatioLimit
		local ores, gems = {}, {}
		for id, def in pairs(BlockDef) do
			if def.Hardness and not def.ExplosiveOnly and (def.Hardness/hard) <= limit then
				local e = { name = def.Name, value = def.Value or 0, hardness = def.Hardness, id = id }
				if def.Types and def.Types.Ore then table.insert(ores, e) end
				if def.Types and def.Types.Gem then table.insert(gems, e) end
			end
		end
		table.sort(ores, function(a,b) return a.value > b.value end)
		table.sort(gems, function(a,b) return a.value > b.value end)
		hLbl:Set("pickaxe hardness: " .. math.floor(hard))
		oLbl:Set(ores[1] and string.format("ore: %s  H:%d  V:%d",
			ores[1].name, ores[1].hardness, ores[1].value) or "ore: none")
		gLbl:Set(gems[1] and string.format("gem: %s  H:%d  V:%d",
			gems[1].name, gems[1].hardness, gems[1].value) or "gem: none")
	end
	refreshBest()  -- initial

	-- watch pickaxe hardness; auto-refresh labels + xray allow set when it changes
	bag.flags.hardWatchAlive = true
	task.spawn(function()
		local lastHard = nil
		while bag.flags.hardWatchAlive do
			task.wait(1)
			if not MUtils then continue end
			local ok, h = pcall(MUtils.GetPlayerPickaxeHardnessClient)
			if not ok or not h then continue end
			if h ~= lastHard then
				lastHard = h
				refreshBest()
				if state.active then task.spawn(scan) end  -- expand/shrink xray immediately
			end
		end
	end)

	-- adaptive poll: 0.2s when the player has moved, 0.7s when idle.
	-- scan() iterates only the radius cube so this stays cheap.
	bag.flags.xrayAlive = true
	task.spawn(function()
		local lastCellKey = nil
		local idleTicks = 0
		while bag.flags.xrayAlive do
			if not state.active then task.wait(0.4) continue end
			local char = lp.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local nowKey
			if hrp then
				local c = Terrain:WorldToCell(hrp.Position)
				nowKey = c.X * 1e6 + c.Y * 1e3 + c.Z
			end
			if nowKey ~= lastCellKey or idleTicks >= 3 then
				-- moved, or periodic re-sync so mined-away blocks disappear
				lastCellKey = nowKey
				idleTicks = 0
				task.spawn(scan)
				task.wait(0.2)
			else
				idleTicks += 1
				task.wait(0.5)
			end
		end
	end)

	bag.hooks.xray_disable = function() state.active = false; clear() end
	bag.hooks.xray_enable  = function() if toggle:Get() then state.active = true; scan() end end
	bag.hooks.xray_unload  = function() bag.flags.xrayAlive = false; bag.flags.hardWatchAlive = false; state.active = false; clear() end
end

-- player ESP removed — the ore xray tab IS the "ore esp"

-- ============================================================
--  TAB — VEHICLE BOOST
-- ============================================================
do
	local tab = mod:Tab({ Name = "boost" })
	local sec = tab:Section("multipliers")

	-- persist boosted-model memory across reloads so re-running the script
	-- doesn't re-multiply vehicles that are already boosted this session.
	-- key = PerformanceFolder (survives if model is same), value = original attrs
	_G.__umtBoosted = _G.__umtBoosted or {}

	local state = {
		enabled    = true,
		POWER_MULT = 15, PEAK_MULT = 3, BRAKE_MULT = 15,
		GRIP_MULT  = 2, DOWNFORCE_MULT = 3,  -- grip + downforce for high-speed cornering
	}

	local function boost(vb)
		if not state.enabled then return end
		local perf = vb.PerformanceFolder; if not perf then return end
		if _G.__umtBoosted[perf] then return end  -- already boosted this session
		task.wait(0.8)
		if vb.Model:GetAttribute("DriverId") ~= lp.UserId then return end
		local pw = perf:GetAttribute("Power"); if not pw then return end
		local pk = perf:GetAttribute("PeakRevs")
		local br = perf:GetAttribute("Braking")

		local entry = { Power = pw, PeakRevs = pk, Braking = br, Model = vb.Model, Wheels = {}, Aero = nil }

		-- live attrs the engine reads every frame (Power/Peak/Brake)
		perf:SetAttribute("Power",    pw * state.POWER_MULT)
		perf:SetAttribute("PeakRevs", pk * state.PEAK_MULT)
		perf:SetAttribute("Braking",  br * state.BRAKE_MULT)

		-- REAL grip: wheel friction is baked into CustomPhysicalProperties at
		-- Suspension.MakeModel. Override each wheel's props directly so grip
		-- isn't dependent on cargo mass pressing tires into the ground.
		local wv = vb.Components and vb.Components.WheeledVehicle
		if wv and wv.Suspensions then
			for _, susp in ipairs(wv.Suspensions) do
				local w = susp.Wheel
				if w then
					local old = w.CustomPhysicalProperties
					table.insert(entry.Wheels, { Wheel = w, Props = old })
					local newFriction = (old and old.Friction or 1.2) * state.GRIP_MULT
					w.CustomPhysicalProperties = PhysicalProperties.new(
						old and old.Density or 1,
						newFriction,
						old and old.Elasticity or 0
					)
				end
			end
		end

		-- REAL downforce: GroundAerodynamics snapshots DownforceCoeff at new().
		-- Set it directly on the component. Also handles Downforce=0 stock by
		-- adding a baseline instead of multiplying.
		local aero = vb.Components and vb.Components.GroundAerodynamics
		if aero then
			entry.Aero = { Component = aero, OldDownforce = aero.DownforceCoeff }
			local base = (aero.DownforceCoeff > 0) and aero.DownforceCoeff or 1
			aero.DownforceCoeff = base * state.DOWNFORCE_MULT
		end

		_G.__umtBoosted[perf] = entry
		notify("boosted", vb.Model.Name, "success")
	end

	local function revertAll()
		for perf, orig in pairs(_G.__umtBoosted) do
			pcall(function()
				if perf and perf.Parent then
					perf:SetAttribute("Power",    orig.Power)
					perf:SetAttribute("PeakRevs", orig.PeakRevs)
					perf:SetAttribute("Braking",  orig.Braking)
				end
			end)
			-- restore wheel friction
			for _, w in ipairs(orig.Wheels or {}) do
				pcall(function()
					if w.Wheel and w.Wheel.Parent then
						w.Wheel.CustomPhysicalProperties = w.Props
					end
				end)
			end
			-- restore downforce coefficient
			if orig.Aero then
				pcall(function() orig.Aero.Component.DownforceCoeff = orig.Aero.OldDownforce end)
			end
		end
		_G.__umtBoosted = {}
	end

	local function hookVehicle(model)
		mod:Connect(model.AncestryChanged, function()
			-- vehicle removed: _G.__umtBoosted entries keyed by now-orphaned
			-- PerformanceFolder become dead weak-refs; revertAll pcalls through
			-- the parent check so no explicit cleanup needed here.
		end)
		mod:Connect(model:GetAttributeChangedSignal("DriverId"), function()
			if not state.enabled then return end
			if model:GetAttribute("DriverId") ~= lp.UserId then return end
			if not VC then return end
			local vb = VC.CurrentDrivenVehicle or (VC.VehiclesByOwnerId
				and VC.VehiclesByOwnerId[model:GetAttribute("OwnerId")])
			if vb then task.spawn(boost, vb) end
		end)
	end

	local Veh = Workspace:FindFirstChild("Vehicles")
	if Veh then
		for _, m in ipairs(Veh:GetChildren()) do if m:IsA("Model") then hookVehicle(m) end end
		mod:Connect(Veh.ChildAdded, function(c)
			if c:IsA("Model") then task.spawn(function() task.wait(0.5) hookVehicle(c) end) end
		end)
	end

	sec:Toggle("boost_on",    { Label = "auto-boost on sit", Default = true,
		Callback = function(v)
			state.enabled = v
			if not v then revertAll() end  -- flipping off reverts everything
		end })
	sec:Int("boost_power",   { Label = "power mult",     Default = 15, Min = 1, Max = 500, Step = 1,
		Callback = function(v) state.POWER_MULT = v end })
	sec:Int("boost_peak",    { Label = "peak-revs mult", Default = 3,  Min = 1, Max = 50,  Step = 1,
		Callback = function(v) state.PEAK_MULT = v end })
	sec:Int("boost_brake",   { Label = "brake mult",     Default = 15, Min = 1, Max = 500, Step = 1,
		Callback = function(v) state.BRAKE_MULT = v end })
	sec:Number("boost_grip", { Label = "grip mult (1 = stock)",     Default = 2, Min = 1, Max = 20, Step = 0.1,
		Callback = function(v) state.GRIP_MULT = v end })
	sec:Number("boost_down", { Label = "downforce mult (1 = stock)", Default = 3, Min = 1, Max = 50, Step = 0.1,
		Callback = function(v) state.DOWNFORCE_MULT = v end })
	sec:Button("boost_revert", { Text = "revert all vehicles to stock", Danger = true,
		Callback = function()
			revertAll()
			notify("reverted", "all boosted vehicles restored", "info")
		end })

	bag.hooks.boost_disable = function() state.enabled = false; revertAll() end
	bag.hooks.boost_enable  = function() state.enabled = true end
	bag.hooks.boost_unload  = function() state.enabled = false; revertAll() end
end

-- ============================================================
--  TAB — FAST PICKAXE
-- ============================================================
do
	local tab = mod:Tab({ Name = "fastmine" })
	local sec = tab:Section("timing")

	local state = { active = false, mult = 0.75, oldMTF = nil }
	local function enable()
		if state.active or not MTF or not hookfunction then return end
		state.oldMTF = hookfunction(MTF, function(speed, hardness, bh)
			return state.oldMTF(speed, hardness, bh) * state.mult
		end)
		state.active = true
	end
	local function disable()
		if not state.active or not state.oldMTF then return end
		pcall(function() hookfunction(MTF, state.oldMTF) end)
		state.active = false
	end

	sec:Toggle("fastmine_on", { Label = "enable", Default = false,
		Callback = function(v)
			if v then enable(); notify("fastmine on", "x" .. state.mult, "success")
			else disable() end
		end })
	sec:Number("fastmine_mult", { Label = "time multiplier (lower = faster)",
		Default = 0.75, Min = 0.1, Max = 1.0, Step = 0.05,
		Callback = function(v) state.mult = v; if state.active then disable() enable() end end })
	sec:Label("warning: < 0.5 risks server rollback")

	bag.hooks.pick_disable = disable
	bag.hooks.pick_enable  = function() end
	bag.hooks.pick_unload  = disable
end

-- ============================================================
--  TAB — SERVER HOP
-- ============================================================
do
	local tab = mod:Tab({ Name = "server hop" })
	local sec = tab:Section("session")

	_G.__visitedServers = _G.__visitedServers or {}
	_G.__visitedServers[game.JobId] = true

	local function visitedCount()
		local n = 0; for _ in pairs(_G.__visitedServers) do n += 1 end; return n
	end
	local vLbl = sec:Label("visited: " .. visitedCount())

	sec:Button("hop_go", { Text = "hop to fresh server", Primary = true,
		Callback = function()
			local servers = {}
			local ok, req = pcall(function()
				return game:HttpGet("https://games.roblox.com/v1/games/"
					.. game.PlaceId .. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true")
			end)
			if not ok then notify("hop failed", "fetch error", "error") return end
			local body = HS:JSONDecode(req)
			if body and body.data then
				for _, v in next, body.data do
					if type(v) == "table" and tonumber(v.playing) and tonumber(v.maxPlayers)
					   and v.playing < v.maxPlayers and v.id ~= game.JobId
					   and not _G.__visitedServers[v.id] then
						table.insert(servers, v.id)
					end
				end
			end
			vLbl:Set("visited: " .. visitedCount() .. " | fresh: " .. #servers)
			if #servers == 0 then notify("no fresh", "reset to clear memory", "warn") return end
			local target = servers[math.random(1, #servers)]
			_G.__visitedServers[target] = true
			TS:TeleportToPlaceInstance(game.PlaceId, target, lp)
		end })
	sec:Button("hop_reset", { Text = "reset visited", Danger = true,
		Callback = function()
			_G.__visitedServers = { [game.JobId] = true }
			vLbl:Set("visited: 1"); notify("reset", "", "info")
		end })
	sec:Button("hop_rejoin", { Text = "rejoin this server",
		Callback = function() TS:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp) end })
end

-- ============================================================
--  MODULE LIFECYCLE — one point for the whole script
-- ============================================================
mod:OnDisable(function()
	bag.hooks.xray_disable()
	bag.hooks.boost_disable()
	bag.hooks.pick_disable()
end)
mod:OnEnable(function()
	bag.hooks.xray_enable()
	bag.hooks.boost_enable()
	bag.hooks.pick_enable()
end)
mod:OnUnload(function()
	bag.hooks.xray_unload()
	bag.hooks.boost_unload()
	bag.hooks.pick_unload()
	for _, f in ipairs(bag.folders) do pcall(function() f:Destroy() end) end
	table.clear(bag.folders)
	print("[UMT] umt toolkit unloaded")
end)

_G.__umtToolkit = function()
	pcall(function() mod:Unload(true) end)
	print("[UMT] obliterated via _G")
end

-- ============================================================
--  AUTO LOAD + AUTO SAVE
-- ============================================================
do
	-- try to load saved config right after module is built (deferred so controls exist)
	task.defer(function()
		local ok = pcall(function() mod.Window:LoadConfig(CFG_NAME) end)
		if ok then notify("config", "loaded " .. CFG_NAME, "info") end
	end)

	-- auto-save loop: every 3s, if config state changed since last save, save it
	bag.flags.autosaveAlive = true
	local lastDump = ""
	task.spawn(function()
		task.wait(2)  -- let LoadConfig settle first
		while bag.flags.autosaveAlive do
			task.wait(3)
			local ok, cur = pcall(function()
				return HS:JSONEncode(mod.Window:GetConfig())
			end)
			if ok and cur ~= lastDump then
				lastDump = cur
				pcall(function() mod.Window:SaveConfig(CFG_NAME) end)
			end
		end
	end)

	-- also save on module unload so last state survives even without 3s tick
	mod:OnUnload(function()
		bag.flags.autosaveAlive = false
		pcall(function() mod.Window:SaveConfig(CFG_NAME) end)
	end)
end

print("[UMT] umt toolkit loaded as module — 4 tabs ready")
notify("umt toolkit", "loaded — 4 tabs", "success")
