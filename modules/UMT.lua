local BLOOM_URL   = "https://raw.githubusercontent.com/NanoBlazeDev/Roblox/refs/heads/main/UI/bloom-ui-lib.lua?t=" .. tick()
local TOOLKIT_URL = "https://raw.githubusercontent.com/NanoBlazeDev/Roblox/refs/heads/main/modules/UMT.lua?t=" .. tick()

do
	task.wait(math.random() * 0.2)
	if _G.__umtClaim then
		local t0 = tick()
		while _G.__umtClaim and (tick() - t0) < 10 do task.wait(0.05) end

		if _G.__umtToolkit then return end
	end
	_G.__umtClaim = true
end

do

	_G.__umtSession = {}

	if _G.__umtTeardowns then
		for _, fn in ipairs(_G.__umtTeardowns) do pcall(fn) end
	end
	_G.__umtTeardowns = {}

	for _, name in ipairs({ "UMT_XRay", "UMT_Farland", "UMT_Waypoint" }) do
		local f = workspace:FindFirstChild(name)
		while f do pcall(function() f:Destroy() end); f = workspace:FindFirstChild(name) end
	end

	if _G.__umt_mtf_hooked and hookfunction then
		pcall(function()
			hookfunction(_G.__umt_mtf_hooked.target, _G.__umt_mtf_hooked.original)
		end)
		_G.__umt_mtf_hooked = nil
	end

	if _G.__umtToolkit then pcall(_G.__umtToolkit) end
	_G.__umtToolkit = nil

	task.wait()
end

local SESSION = _G.__umtSession

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
local UIS     = game:GetService("UserInputService")
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

local CFG_NAME = "umt_default"

local okMod, mod = pcall(function()
	return Bloom:Module({
		Name        = "umt toolkit",
		Version     = "2.1",
		Author      = "ExaVolt",
		Description = "ultimate mining tycoon tools — ore xray, vehicle boost, flip+bring+drill-lock, flinger, fastmine, server hop",
		AutoConfig  = CFG_NAME,
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

local bag = { folders = {}, flags = {}, hooks = {} }

local function registerTeardown(fn)
	_G.__umtTeardowns = _G.__umtTeardowns or {}
	table.insert(_G.__umtTeardowns, fn)
end

registerTeardown(function()
	bag.flags.xrayAlive = false
	bag.flags.hardWatchAlive = false
	bag.flags.farAlive = false
	bag.flags.autosaveAlive = false
	for _, f in ipairs(bag.folders) do pcall(function() f:Destroy() end) end
	table.clear(bag.folders)
end)

do
	local tab = mod:Tab({ Name = "xray" })
	local sec = tab:Section("highlights")

	local state = { active = false, radius = 10, scanning = false }
	local folder = Instance.new("Folder")
	folder.Name = "UMT_XRay"
	folder.Parent = Workspace
	table.insert(bag.folders, folder)

	local shown = {}
	local function keyOf(c) return c.X * 1000000 + c.Y * 1000 + c.Z end

	local ORE_COLORS = {

		Tin           = Color3.fromRGB(215, 210, 180),
		Iron          = Color3.fromRGB(220, 110,  40),
		Lead          = Color3.fromRGB( 25,  25,  30),
		Cobalt        = Color3.fromRGB( 40,  95, 220),
		Aluminium     = Color3.fromRGB(230, 230, 235),
		Silver        = Color3.fromRGB(210, 220, 230),
		Uranium       = Color3.fromRGB(140, 240,  90),
		Vanadium      = Color3.fromRGB(170,  50,  40),
		Titanium      = Color3.fromRGB(100,  80, 170),
		Gold          = Color3.fromRGB(255, 215,  70),
		Tungsten      = Color3.fromRGB(110, 140,  70),
		Molybdenum    = Color3.fromRGB(170, 185, 170),
		Plutonium     = Color3.fromRGB( 40, 190, 255),
		Palladium     = Color3.fromRGB(240, 190,  40),
		Iridium       = Color3.fromRGB(200, 220, 240),
		Adamantium    = Color3.fromRGB( 80, 220, 140),
		Thorium       = Color3.fromRGB(130, 220, 110),
		Mithril       = Color3.fromRGB( 60, 220, 150),
		Rhodium       = Color3.fromRGB(255, 130,  40),
		Unobtainium   = Color3.fromRGB(255,  70, 240),

		Topaz         = Color3.fromRGB(245, 215,  70),
		Emerald       = Color3.fromRGB( 20, 180,  60),
		Sapphire      = Color3.fromRGB( 30,  60, 230),
		Ruby          = Color3.fromRGB(220,  25,  25),
		Diamond       = Color3.fromRGB(120, 220, 230),
		Poudretteite  = Color3.fromRGB(230,  70, 230),
		Zultanite     = Color3.fromRGB(230, 140, 140),
		Grandidierite = Color3.fromRGB( 70, 210, 140),
		Musgravite    = Color3.fromRGB( 60, 100, 100),
		Painite       = Color3.fromRGB(210,  60,  60),
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

	state.topN = 2
	state.allowed = {}

	local function recomputeAllowed()
		state.allowed = {}
		if not (MUtils and BlockDef and Settings) then

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
		if not state.active then return 0 end
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

		for k, _ in pairs(shown) do
			if not desired[k] then removeAt(k) end
		end

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
	local radiusCtl = sec:Int("xray_radius", {
		Label = "radius (cells)", Default = state.radius, Min = 3, Max = 40, Step = 1,
		Callback = function(v) state.radius = v; if state.active then scan() end end,
	})
	local topnCtl = sec:Int("xray_topn", {
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
	refreshBest()

	bag.flags.hardWatchAlive = true
	task.spawn(function()
		local lastHard = nil
		while bag.flags.hardWatchAlive and _G.__umtSession == SESSION do
			task.wait(1)
			if not MUtils then continue end
			local ok, h = pcall(MUtils.GetPlayerPickaxeHardnessClient)
			if not ok or not h then continue end
			if h ~= lastHard then
				lastHard = h
				refreshBest()
				if state.active then task.spawn(scan) end
			end
		end
	end)

	bag.flags.xrayAlive = true
	task.spawn(function()
		local lastCellKey = nil
		local idleTicks = 0
		while bag.flags.xrayAlive and _G.__umtSession == SESSION do
			if not state.active then task.wait(0.4) continue end
			local char = lp.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local nowKey
			if hrp then
				local c = Terrain:WorldToCell(hrp.Position)
				nowKey = c.X * 1e6 + c.Y * 1e3 + c.Z
			end
			if nowKey ~= lastCellKey or idleTicks >= 3 then

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

	local farlandState = {
		active   = false,
		oreCap   = 30,
		tiers    = 1,
		showOres = true,
		showGems = true,
		folder   = nil,
		bestOre  = nil,
		bestGem  = nil,
		topOres  = {},
		topGems  = {},
		bestOreName = nil,
		bestGemName = nil,
	}
	farlandState.folder = Instance.new("Folder")
	farlandState.folder.Name = "UMT_Farland"
	farlandState.folder.Parent = Workspace
	table.insert(bag.folders, farlandState.folder)

	local farShown = {}

	local function farClear()
		for _, c in ipairs(farlandState.folder:GetChildren()) do c:Destroy() end
		table.clear(farShown)
	end

	local function computeBest()
		if not (MUtils and BlockDef and Settings) then return end
		local hard = MUtils.GetPlayerPickaxeHardnessClient()
		local limit = Settings.MiningHardnessRatioLimit
		local ores, gems = {}, {}
		for id, def in pairs(BlockDef) do
			if def.Hardness and not def.ExplosiveOnly and (def.Hardness / hard) <= limit and def.Types then
				local isGem = def.Types.Gem == true
				local isOre = def.Types.Ore == true and not isGem
				local v = def.Value or 0
				if isGem then
					table.insert(gems, { id = id, value = v, name = def.Name })
				elseif isOre then
					table.insert(ores, { id = id, value = v, name = def.Name })
				end
			end
		end
		table.sort(ores, function(a, b) return a.value > b.value end)
		table.sort(gems, function(a, b) return a.value > b.value end)
		farlandState.topOres = ores
		farlandState.topGems = gems

		farlandState.bestOre     = ores[1] and ores[1].id or nil
		farlandState.bestGem     = gems[1] and gems[1].id or nil
		farlandState.bestOreName = ores[1] and ores[1].name or nil
		farlandState.bestGemName = gems[1] and gems[1].name or nil
	end

	local idxCache = { ts = 0, byOre = {}, counts = {} }
	local INDEX_TTL = 10

	local function rebuildIndex()
		local byOre, counts = {}, {}
		for coord, block in MT._Cells:List() do
			local oid = block.Ore
			if oid then
				local list = byOre[oid]
				if not list then list = {}; byOre[oid] = list end
				list[#list + 1] = coord
				counts[oid] = (counts[oid] or 0) + 1
			end
		end
		idxCache.byOre  = byOre
		idxCache.counts = counts
		idxCache.ts     = tick()
	end

	local function getIndex(forceRefresh)
		if forceRefresh or (tick() - idxCache.ts) > INDEX_TTL then
			rebuildIndex()
		end
		return idxCache
	end

	local function makeFarMarker(coord, color, label)
		local wp = Terrain:CellCenterToWorld(coord.X, coord.Y, coord.Z)

		local part = Instance.new("Part")
		part.Size = Vector3.new(3.9, 3.9, 3.9)
		part.CFrame = CFrame.new(wp)
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Transparency = 0.25
		part.Color = color
		part.Material = Enum.Material.ForceField
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = farlandState.folder

		local hl = Instance.new("Highlight")
		hl.Adornee = part
		hl.FillColor = color
		hl.FillTransparency = 0.4
		hl.OutlineColor = Color3.fromRGB(255, 255, 255)
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = part

		if label then
			local bg = Instance.new("BillboardGui")
			bg.Adornee = part
			bg.Size = UDim2.fromOffset(160, 32)
			bg.StudsOffset = Vector3.new(0, 4, 0)
			bg.AlwaysOnTop = true
			bg.MaxDistance = 0
			bg.LightInfluence = 0
			bg.Parent = part
			local tl = Instance.new("TextLabel")
			tl.Size = UDim2.fromScale(1, 1)
			tl.BackgroundTransparency = 0.3
			tl.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			tl.TextColor3 = color
			tl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
			tl.TextStrokeTransparency = 0
			tl.Font = Enum.Font.GothamBold
			tl.TextSize = 15
			tl.Text = label
			tl.Parent = bg
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 4)
			corner.Parent = tl
		end
		return part
	end

	local function countOnServer(oreId)
		if not oreId or not MT then return 0 end
		return getIndex().counts[oreId] or 0
	end

	local function farScan()
		if not MT then return end
		farClear()
		computeBest()
		local tiers  = math.max(1, farlandState.tiers or 1)
		local oreCap = farlandState.oreCap
		local gemCap = math.floor(oreCap / 2)
		local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
		local myPos = hrp and hrp.Position or Vector3.new()
		local idx = getIndex().byOre

		local function renderTier(entry, perTierCap)
			if not (entry and entry.id) then return end
			local coords = idx[entry.id] or {}
			if #coords == 0 then return end
			local sorted = table.create(#coords)
			for i = 1, #coords do
				local c = coords[i]
				local wp = Terrain:CellCenterToWorld(c.X, c.Y, c.Z)
				sorted[i] = { coord = c, d2 = (wp - myPos).Magnitude ^ 2 }
			end
			table.sort(sorted, function(a, b) return a.d2 < b.d2 end)
			local color = ORE_COLORS[entry.id] or Color3.fromRGB(255,255,255)
			for i = 1, math.min(perTierCap, #sorted) do
				makeFarMarker(sorted[i].coord, color, entry.name)
			end
		end

		if farlandState.showOres and farlandState.topOres then
			local perTier = math.max(1, math.ceil(oreCap / tiers))
			for t = 1, math.min(tiers, #farlandState.topOres) do
				renderTier(farlandState.topOres[t], perTier)
			end
		end

		if farlandState.showGems and farlandState.topGems then
			local perTier = math.max(1, math.ceil(gemCap / tiers))
			for t = 1, math.min(tiers, #farlandState.topGems) do
				renderTier(farlandState.topGems[t], perTier)
			end
		end
	end

	local farSection = tab:Section("farland (best-ore global ESP)")
	local farToggleCtrl = farSection:Toggle("farland_on", {
		Label = "farland enabled", Default = false,
		Callback = function(v)
			farlandState.active = v
			if v then farScan() else farClear() end
		end,
	})
	local farCapCtl = farSection:Int("farland_cap", {
		Label = "ore limit (gems = limit / 2)",
		Default = farlandState.oreCap, Min = 2, Max = 60, Step = 2,
		Callback = function(v)
			farlandState.oreCap = v
			if farlandState.active then farScan() end
		end,
	})
	local farTiersCtl = farSection:Int("farland_tiers", {
		Label = "tiers (top-N by value)",
		Default = farlandState.tiers, Min = 1, Max = 5, Step = 1,
		Callback = function(v)
			farlandState.tiers = v
			if farlandState.active then farScan() end
		end,
	})
	local farShowOreCtl = farSection:Toggle("farland_show_ores", {
		Label = "show ores", Default = true,
		Callback = function(v)
			farlandState.showOres = v
			if farlandState.active then farScan() end
		end,
	})
	local farShowGemCtl = farSection:Toggle("farland_show_gems", {
		Label = "show gems", Default = true,
		Callback = function(v)
			farlandState.showGems = v
			if farlandState.active then farScan() end
		end,
	})

	local farOreLbl = farSection:Label("Ore: —")
	local farGemLbl = farSection:Label("Gem: —")

	local function refreshFarLabels()
		computeBest()
		local nOre = countOnServer(farlandState.bestOre)
		local nGem = countOnServer(farlandState.bestGem)
		farOreLbl:Set(string.format("Ore: %s  x%d", farlandState.bestOreName or "—", nOre))
		farGemLbl:Set(string.format("Gem: %s  x%d", farlandState.bestGemName or "—", nGem))
	end

	farSection:Button("farland_rescan", {
		Text = "rescan farland (rebuilds index)",
		Callback = function()
			getIndex(true)
			refreshFarLabels()
			if farlandState.active then farScan() end
			notify("farland", "index rebuilt", "info")
		end,
	})

	bag.flags.farAlive = true
	local farToken = SESSION
	task.spawn(function()
		while bag.flags.farAlive and _G.__umtSession == farToken do
			task.wait(5)
			if not MT then continue end
			refreshFarLabels()
			if farlandState.active then task.spawn(farScan) end
		end
	end)

	task.spawn(function()
		task.wait(10)
		computeBest()
		local nOre = countOnServer(farlandState.bestOre)
		local nGem = countOnServer(farlandState.bestGem)
		local msg = string.format(
			"Ore: %s x%d | Gem: %s x%d",
			farlandState.bestOreName or "—", nOre,
			farlandState.bestGemName or "—", nGem
		)
		notify("farland scan", msg, "info")
		print("[FARLAND] " .. msg)
	end)

	bag.hooks.xray_disable = function()
		state.active = false; clear()
		farlandState.active = false; farClear()
	end
	bag.hooks.xray_enable  = function() if toggle:Get() then state.active = true; scan() end end
	bag.hooks.xray_unload  = function()
		bag.flags.xrayAlive = false; bag.flags.hardWatchAlive = false; bag.flags.farAlive = false
		state.active = false; clear()
		farlandState.active = false; farClear()
	end
	registerTeardown(bag.hooks.xray_unload)

	bag.hooks.xray_resync = function()
		state.radius = radiusCtl:Get() or state.radius
		state.topN   = topnCtl:Get()   or state.topN
		if toggle:Get() then
			state.active = true
			task.spawn(scan)
		end
	end
	bag.hooks.farland_resync = function()
		farlandState.oreCap   = farCapCtl:Get()      or farlandState.oreCap
		farlandState.tiers    = farTiersCtl:Get()    or farlandState.tiers
		farlandState.showOres = farShowOreCtl:Get()
		farlandState.showGems = farShowGemCtl:Get()
		if farToggleCtrl:Get() then
			farlandState.active = true
			task.spawn(farScan)
		end
	end
end

do
	local tab = mod:Tab({ Name = "boost" })
	local sec = tab:Section("multipliers")

	_G.__umtBoosted = _G.__umtBoosted or {}

	local state = {
		enabled    = true,
		POWER_MULT = 15, PEAK_MULT = 3, BRAKE_MULT = 15,
		GRIP_MULT  = 2, DOWNFORCE_MULT = 1,
	}

	local function boost(vb)
		if not state.enabled then return end
		local perf = vb.PerformanceFolder; if not perf then return end
		if _G.__umtBoosted[perf] then return end

		_G.__umtBoosted[perf] = { pending = true }
		task.wait(0.3)
		if vb.Model:GetAttribute("DriverId") ~= lp.UserId then
			_G.__umtBoosted[perf] = nil
			return
		end

		local pw = perf:GetAttribute("Power")
		if not pw then _G.__umtBoosted[perf] = nil; return end
		local pk = perf:GetAttribute("PeakRevs")
		local br = perf:GetAttribute("Braking")

		local entry = { Power = pw, PeakRevs = pk, Braking = br, Model = vb.Model, Wheels = {}, Aero = nil }

		perf:SetAttribute("Power",    pw * state.POWER_MULT)
		perf:SetAttribute("PeakRevs", pk * state.PEAK_MULT)
		perf:SetAttribute("Braking",  br * state.BRAKE_MULT)

		local wv = vb.Components and vb.Components.WheeledVehicle
		if wv and wv.Suspensions then
			for _, susp in ipairs(wv.Suspensions) do
				local w = susp.Wheel
				if w then
					local old = w.CustomPhysicalProperties
					table.insert(entry.Wheels, { Wheel = w, Props = old })

					local newFriction = math.clamp((old and old.Friction or 1.2) * state.GRIP_MULT, 0, 2)
					w.CustomPhysicalProperties = PhysicalProperties.new(
						old and old.Density or 1,
						newFriction,
						old and old.Elasticity or 0
					)
				end
			end
		end

		local aero = vb.Components and vb.Components.GroundAerodynamics
		if aero then
			entry.Aero = { Component = aero, OldDownforce = aero.DownforceCoeff }

			local base = (aero.DownforceCoeff > 0) and aero.DownforceCoeff or 0.3
			aero.DownforceCoeff = base * state.DOWNFORCE_MULT
		end

		_G.__umtBoosted[perf] = entry
		notify("boosted", vb.Model.Name, "success")
	end

	local function revertAll()
		for perf, orig in pairs(_G.__umtBoosted) do
			if orig.pending then continue end
			pcall(function()
				if perf and perf.Parent then
					perf:SetAttribute("Power",    orig.Power)
					perf:SetAttribute("PeakRevs", orig.PeakRevs)
					perf:SetAttribute("Braking",  orig.Braking)
				end
			end)

			for _, w in ipairs(orig.Wheels or {}) do
				pcall(function()
					if w.Wheel and w.Wheel.Parent then
						w.Wheel.CustomPhysicalProperties = w.Props
					end
				end)
			end

			if orig.Aero then
				pcall(function() orig.Aero.Component.DownforceCoeff = orig.Aero.OldDownforce end)
			end
		end
		_G.__umtBoosted = {}
	end

	local function hookVehicle(model)
		mod:Connect(model.AncestryChanged, function()

		end)
		mod:Connect(model:GetAttributeChangedSignal("DriverId"), function()
			if not state.enabled then return end
			if model:GetAttribute("DriverId") ~= lp.UserId then return end
			if not VC then return end

			task.spawn(function()
				local vb
				for _ = 1, 60 do
					local candidate = VC.CurrentDrivenVehicle
						or (VC.VehiclesByOwnerId and VC.VehiclesByOwnerId[model:GetAttribute("OwnerId")])
					if candidate and candidate.Components
					   and candidate.Components.Engine
					   and candidate.Components.WheeledVehicle then
						vb = candidate
						break
					end
					task.wait(0.05)
				end
				if vb and model:GetAttribute("DriverId") == lp.UserId then
					boost(vb)
				end
			end)
		end)
	end

	local Veh = Workspace:FindFirstChild("Vehicles")
	if Veh then
		for _, m in ipairs(Veh:GetChildren()) do if m:IsA("Model") then hookVehicle(m) end end
		mod:Connect(Veh.ChildAdded, function(c)
			if c:IsA("Model") then task.spawn(function() task.wait(0.5) hookVehicle(c) end) end
		end)
	end

	local boostToggle = sec:Toggle("boost_on", { Label = "auto-boost on sit", Default = true,
		Callback = function(v)
			state.enabled = v
			if not v then revertAll() end
		end })
	local boostPower = sec:Int("boost_power",   { Label = "power mult",     Default = 15, Min = 1, Max = 500, Step = 1,
		Callback = function(v) state.POWER_MULT = v end })
	local boostPeak  = sec:Int("boost_peak",    { Label = "peak-revs mult", Default = 3,  Min = 1, Max = 50,  Step = 1,
		Callback = function(v) state.PEAK_MULT = v end })
	local boostBrake = sec:Int("boost_brake",   { Label = "brake mult",     Default = 15, Min = 1, Max = 500, Step = 1,
		Callback = function(v) state.BRAKE_MULT = v end })
	local boostGrip  = sec:Number("boost_grip", { Label = "grip mult (1 = stock)",     Default = 2, Min = 1, Max = 20, Step = 0.1,
		Callback = function(v) state.GRIP_MULT = v end })
	local boostDown  = sec:Number("boost_down", { Label = "downforce mult (grows with speed² — keep ≤2)", Default = 1, Min = 0, Max = 10, Step = 0.1,
		Callback = function(v) state.DOWNFORCE_MULT = v end })

	bag.hooks.boost_resync = function()
		state.enabled        = boostToggle:Get()
		state.POWER_MULT     = boostPower:Get()  or state.POWER_MULT
		state.PEAK_MULT      = boostPeak:Get()   or state.PEAK_MULT
		state.BRAKE_MULT     = boostBrake:Get()  or state.BRAKE_MULT
		state.GRIP_MULT      = boostGrip:Get()   or state.GRIP_MULT
		state.DOWNFORCE_MULT = boostDown:Get()   or state.DOWNFORCE_MULT
	end
	sec:Button("boost_revert", { Text = "revert all vehicles to stock", Danger = true,
		Callback = function()
			revertAll()
			notify("reverted", "all boosted vehicles restored", "info")
		end })

	bag.hooks.boost_disable = function() state.enabled = false; revertAll() end
	bag.hooks.boost_enable  = function() state.enabled = true end
	bag.hooks.boost_unload  = function() state.enabled = false; revertAll() end
	registerTeardown(bag.hooks.boost_unload)
end

do

	local function myVehicleHere()
		if not VC then return nil end
		return VC.CurrentDrivenVehicle
	end
	local function myPrimary()
		local vb = myVehicleHere()
		return vb and vb.Model and vb.Model.PrimaryPart
	end
	local function myHrp()
		local c = lp.Character
		return c and c:FindFirstChild("HumanoidRootPart")
	end

	local function pivotWithAnchorDance(model, targetCFrame)
		if not model or not model.PrimaryPart then return false, "no model" end
		pcall(function()
			local cache = {}
			for _, p in ipairs(model:GetDescendants()) do
				if p:IsA("BasePart") then
					cache[p] = p.Anchored
					p.Anchored = true
				end
			end
			model:PivotTo(targetCFrame)
			for p in pairs(cache) do
				p.AssemblyLinearVelocity  = Vector3.zero
				p.AssemblyAngularVelocity = Vector3.zero
			end
			game:GetService("RunService").Heartbeat:Wait()
			game:GetService("RunService").Heartbeat:Wait()
			for p, was in pairs(cache) do p.Anchored = was end
		end)
		return true
	end

	local function flipVehicle180()
		local vb = myVehicleHere()
		local model = vb and vb.Model
		local pp    = model and model.PrimaryPart
		if not pp then
			notify("flip", "no driven vehicle", "error"); return
		end
		local cf   = pp.CFrame

		local newCF = CFrame.new(cf.Position) * CFrame.Angles(0, math.pi, 0) * (cf - cf.Position)

		newCF = newCF + Vector3.new(0, 2, 0)
		pivotWithAnchorDance(model, newCF)
		notify("flip", "rotated 180°", "success")
	end

	local function bringVehicleHere()
		local vb = myVehicleHere()
		local model = vb and vb.Model
		if not (model and model.PrimaryPart) then
			notify("bring", "no owned vehicle", "error"); return
		end
		local hrp = myHrp()
		if not hrp then
			notify("bring", "no character", "error"); return
		end

		local hCF = hrp.CFrame
		local target = hCF * CFrame.new(0, 3, -6)
		pivotWithAnchorDance(model, target)
		notify("bring", "vehicle recalled", "success")
	end

	local drillLock = { active = false, conn = nil, pp = nil }
	local function stopDrillLock()
		if drillLock.conn then pcall(function() drillLock.conn:Disconnect() end) end
		drillLock.conn, drillLock.pp = nil, nil
		drillLock.active = false
	end
	registerTeardown(stopDrillLock)

	local function startDrillLock()
		if drillLock.active then return end
		local vb = myVehicleHere()
		local model = vb and vb.Model
		local pp = model and model.PrimaryPart
		if not pp then
			notify("drill lock", "no owned vehicle to lock", "error")
			return
		end
		drillLock.active = true
		drillLock.pp = pp

		local DEG2RAD = math.pi / 180
		drillLock.conn = game:GetService("RunService").Heartbeat:Connect(function()
			if not drillLock.active or _G.__umtSession ~= SESSION then stopDrillLock() return end
			local vb2 = myVehicleHere()
			local pp2 = vb2 and vb2.Model and vb2.Model.PrimaryPart
			if pp2 ~= drillLock.pp or not pp2 or not pp2.Parent then
				stopDrillLock(); return
			end
			local ori = pp2.Orientation
			local snappedYaw = math.round(ori.Y / 90) * 90

			local pos = pp2.CFrame.Position
			pp2.CFrame = CFrame.new(pos) * CFrame.fromOrientation(
				ori.X * DEG2RAD, snappedYaw * DEG2RAD, ori.Z * DEG2RAD)

			local cf = pp2.CFrame
			local localAV = cf:VectorToObjectSpace(pp2.AssemblyAngularVelocity)
			localAV = Vector3.new(localAV.X, 0, localAV.Z)
			pp2.AssemblyAngularVelocity = cf:VectorToWorldSpace(localAV)
		end)
	end

	local drillLockToggle
	local function toggleDrillLock()
		local newVal = not drillLock.active
		if drillLockToggle then drillLockToggle:Set(newVal) else
			if newVal then startDrillLock() else stopDrillLock() end
			notify("drill lock", newVal and "ON — pitch locked to 90° steps" or "OFF",
				newVal and "success" or "info")
		end
	end

	local tab = mod:Tab({ Name = "vehicle" })
	local sec = tab:Section("controls")

	sec:Label("Flip 180° — rotate car in place")
	sec:Button("vehicle_flip", {
		Text = "flip 180° now",
		Callback = flipVehicle180,
	})
	sec:Keybind("hotkey_flip", {
		Label = "flip hotkey",
		Default = Enum.KeyCode.T,
		OnPress = flipVehicle180,
	})

	sec:Label("Bring — teleport car to you")
	sec:Button("vehicle_bring", {
		Text = "bring vehicle here",
		Callback = bringVehicleHere,
	})
	sec:Keybind("hotkey_bring", {
		Label = "bring hotkey",
		Default = Enum.KeyCode.V,
		OnPress = bringVehicleHere,
	})

	sec:Label("Drill Lock Mode — snap pitch to nearest 90° (clean drilling)")
	drillLockToggle = sec:Toggle("drill_lock", {
		Text = "drill lock",
		Default = false,
		Callback = function(v)
			if v then startDrillLock() else stopDrillLock() end
			notify("drill lock", v and "ON — pitch locked to 90° steps" or "OFF",
				v and "success" or "info")
		end,
	})
	sec:Keybind("hotkey_drill_lock", {
		Label = "drill lock hotkey",
		Default = Enum.KeyCode.U,
		OnPress = toggleDrillLock,
	})

	_G.__umtVFHelpers = {
		myVehicle    = myVehicleHere,
		myPrimary    = myPrimary,
		myHrp        = myHrp,
		pivotDance   = pivotWithAnchorDance,
	}
end

do
	local H = _G.__umtVFHelpers
	local RunSvc = game:GetService("RunService")

	local flingState = {
		scanRadius = 100, targetModel = nil, targetLabel = nil,
		highlight = nil, flinging = false, flingLoop = nil, label2model = {},
	}

	local function clearHighlight()
		if flingState.highlight then
			pcall(function() flingState.highlight:Destroy() end)
			flingState.highlight = nil
		end
	end
	local function setHighlight(model)
		clearHighlight()
		if not model then return end
		local h = Instance.new("Highlight")
		h.Name = "UMT_FlingTarget"
		h.Adornee = model
		h.FillColor = Color3.fromRGB(255, 50, 70)
		h.OutlineColor = Color3.fromRGB(255, 255, 255)
		h.FillTransparency = 0.65
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent = model
		flingState.highlight = h
	end

	local function scanNearby()
		flingState.label2model = {}
		local hrp = H.myHrp(); if not hrp then return {} end
		local myPos = hrp.Position
		local R2 = flingState.scanRadius ^ 2
		local Veh = Workspace:FindFirstChild("Vehicles")
		if not Veh then return {} end
		local hits = {}
		for _, m in ipairs(Veh:GetChildren()) do
			if m:IsA("Model") and m.PrimaryPart then
				local d2 = (m.PrimaryPart.Position - myPos).Magnitude ^ 2
				if d2 <= R2 then
					local ownerId  = m:GetAttribute("OwnerId")
					local driverId = m:GetAttribute("DriverId")
					if ownerId ~= lp.UserId then
						local ownerPlr  = ownerId and Players:GetPlayerByUserId(ownerId)
						local driverPlr = driverId and Players:GetPlayerByUserId(driverId)
						local who = (driverPlr and driverPlr.Name) or (ownerPlr and ownerPlr.Name) or ("uid:" .. tostring(ownerId or "?"))
						local label = string.format("%s — %s (%dm)", who, m.Name, math.sqrt(d2))
						flingState.label2model[label] = m
						table.insert(hits, { label = label, d2 = d2 })
					end
				end
			end
		end
		table.sort(hits, function(a, b) return a.d2 < b.d2 end)
		local labels = {}
		for _, h in ipairs(hits) do table.insert(labels, h.label) end
		return labels
	end

	local function startFling()
		if flingState.flinging then return end
		if not flingState.targetModel then notify("flinger", "pick a target first", "error") return end
		flingState.flinging = true
		flingState.flingLoop = RunSvc.Heartbeat:Connect(function()
			if not flingState.flinging then return end
			local pp = H.myPrimary()
			local tgtPP = flingState.targetModel and flingState.targetModel.PrimaryPart
			if not pp or not tgtPP or not tgtPP.Parent then return end
			pcall(function()
				pp.CFrame = tgtPP.CFrame * CFrame.new(0, 2.5, 0)
				local burst = Vector3.new(
					math.random(-1, 1) * 1e5,
					math.random( 0, 1) * 1e5,
					math.random(-1, 1) * 1e5
				)
				pp.AssemblyLinearVelocity  = burst
				pp.AssemblyAngularVelocity = burst * 0.5
			end)
		end)
		notify("flinging", "attached to " .. (flingState.targetLabel or "?"), "success")
	end
	local function stopFling()
		flingState.flinging = false
		if flingState.flingLoop then
			pcall(function() flingState.flingLoop:Disconnect() end)
			flingState.flingLoop = nil
		end
	end

	local tab = mod:Tab({ Name = "flinger" })
	local secTarget = tab:Section("target")

	local flingDropdown = secTarget:Enum("fling_target", {
		Label = "target vehicle",
		Options = { "(none - press scan)" },
		Default = "(none - press scan)",
		Callback = function(label)
			local m = flingState.label2model[label]
			flingState.targetLabel = m and label or nil
			flingState.targetModel = m
			if m then setHighlight(m); notify("locked", label, "info")
			else clearHighlight() end
		end,
	})
	secTarget:Int("fling_radius", {
		Label = "scan radius (studs)",
		Default = flingState.scanRadius, Min = 20, Max = 500, Step = 5,
		Callback = function(v) flingState.scanRadius = v end,
	})
	secTarget:Button("fling_scan", {
		Text = "scan nearby",
		Primary = true,
		Callback = function()
			local labels = scanNearby()
			if #labels == 0 then
				flingDropdown:SetOptions({ "(none in range)" })
				flingDropdown:Set("(none in range)")
				notify("no vehicles", "nothing within " .. flingState.scanRadius, "warn")
				return
			end
			flingDropdown:SetOptions(labels)
			flingDropdown:Set(labels[1])
			notify("found", #labels .. " vehicles", "success")
		end,
	})

	local secFling = tab:Section("fling")
	local flingToggle = secFling:Toggle("fling_on", {
		Label = "fling (drive into target first!)",
		Default = false,
		Callback = function(v) if v then startFling() else stopFling() end end,
	})
	secFling:Button("fling_clear", {
		Text = "clear target",
		Danger = true,
		Callback = function()
			stopFling()
			flingToggle:Set(false)
			flingState.targetModel = nil
			flingState.targetLabel = nil
			clearHighlight()
			flingDropdown:Set("(none - press scan)")
			notify("cleared", "", "info")
		end,
	})
	secFling:Label("WARNING: visible from server replay. use on moving targets only.")

	bag.hooks.fling_disable = function() stopFling(); clearHighlight() end
	bag.hooks.fling_unload  = function() stopFling(); clearHighlight() end
	registerTeardown(bag.hooks.fling_unload)
end

do
	local tab = mod:Tab({ Name = "fastmine" })
	local sec = tab:Section("static")

	-- smart mode = static baseline reacting to user's actual mining pace.
	-- Baseline: actual = vanilla × mult (same as static, server-safe 2× speedup).
	-- Bonus: if you were idle (gap between mines > previous mine duration),
	-- the EXTRA idle seconds are subtracted from current actual, so one block
	-- after a pause runs faster. Floor caps at vanilla × 0.1 (10× speedup max).
	-- No credit variable, no hardness ratio, just gap − prevActual − cushion.
	local state = {
		active        = false,
		mode          = "static",
		mult          = 0.5,          -- static multiplier (also smart baseline)
		burstMult     = 0.1,          -- smart: floor (vanilla × 0.1 = 10× cap)
		pollBaseline  = 0.1,          -- smart: cushion before idle counts
		lastCall      = 0,            -- smart: tick() of last MTF call
		prevActual    = 0,            -- smart: previous returned actual
		lastVanilla   = 1,            -- smart: UI
		lastMult      = 1,            -- smart: UI
		lastGap       = 0,            -- smart: UI
		lastIdle      = 0,            -- smart: UI
		oldMTF        = nil,
	}

	local function enable()
		if state.active or not MTF or not hookfunction then return end
		if not _G.__umt_mtf_hooked then
			_G.__umt_mtf_hooked = { target = MTF, original = nil }
		end
		state.lastCall = tick()
		state.prevActual = 0
		local prev = hookfunction(MTF, function(speed, hardness, bh)
			local vanilla = state.oldMTF(speed, hardness, bh)
			-- skip unmineable blocks (walls/air hover polls return absurd vanilla ~9999999)
			if vanilla and vanilla > 1e6 then return vanilla end
			if state.mode == "static" then
				return vanilla * state.mult
			else
				state.lastVanilla = vanilla
				local now = tick()
				local gap = now - state.lastCall
				state.lastCall = now
				state.lastGap = gap

				-- idle = extra time since previous mine completed
				local idle = math.max(0, gap - state.prevActual - state.pollBaseline)
				state.lastIdle = idle

				-- baseline (same as static) minus idle bonus, floored at 10× speedup
				local base = vanilla * state.mult
				local floor = vanilla * state.burstMult
				local actual = math.max(floor, base - idle)

				state.prevActual = actual
				state.lastMult = (actual > 0) and (vanilla / actual) or 1
				return actual
			end
		end)
		state.oldMTF = prev
		if _G.__umt_mtf_hooked.original == nil then
			_G.__umt_mtf_hooked.original = prev
		end
		state.active = true
	end
	local function disable()
		if not state.active then return end
		local trueOrig = _G.__umt_mtf_hooked and _G.__umt_mtf_hooked.original
		pcall(function() hookfunction(MTF, trueOrig or state.oldMTF) end)
		_G.__umt_mtf_hooked = nil
		state.active = false
	end

	local fmToggle = sec:Toggle("fastmine_on", { Label = "enable static", Default = false,
		Callback = function(v)
			if v then
				state.mode = "static"
				if state.active then disable() end
				enable()
				notify("fastmine on", "static x" .. state.mult, "success")
			else disable() end
		end })
	local fmMult = sec:Number("fastmine_mult", { Label = "time multiplier (lower = faster)",
		Default = 0.75, Min = 0.1, Max = 1.0, Step = 0.05,
		Callback = function(v) state.mult = v; if state.active and state.mode=="static" then disable() enable() end end })
	sec:Label("warning: < 0.5 risks server rollback")

	local sec2 = tab:Section("smart (auto)")
	local smartToggle = sec2:Toggle("fastmine_smart", { Label = "enable smart", Default = false,
		Callback = function(v)
			if v then
				state.mode = "smart"
				if state.active then disable() end
				enable()
				notify("fastmine smart", "auto rate", "success")
			else disable() end
		end })
	sec2:Label("static baseline + idle bonus. floor at 10× speedup (vanilla × 0.1)")
	local liveLbl = sec2:Label("gap: 0.00s   idle: 0.00s   vanilla: 1.0s   next: 1.00x   last: 1.00x")

	local RS = game:GetService("RunService")
	if _G.__umt_fastmine_live then pcall(function() _G.__umt_fastmine_live:Disconnect() end) end
	local lastDiag = 0
	-- Live gap = time since last MTF call (what will be saved on next mine).
	-- Caps display at vanilla so UI doesn't scream BIG numbers while idle forever.
	local function liveGap()
		local now = tick()
		return now - (tonumber(state.lastCall) or now)
	end
	_G.__umt_fastmine_live = RS.Heartbeat:Connect(function(dt)
		if state.active and state.mode == "smart" then
			local g   = liveGap()
			local lv  = tonumber(state.lastVanilla) or 1
			local lm  = tonumber(state.lastMult) or 1
			local pa  = tonumber(state.prevActual) or 0
			local liveIdle = math.max(0, g - pa - state.pollBaseline)
			local base = lv * state.mult
			local floor = lv * state.burstMult
			local nextActual = math.max(floor, base - liveIdle)
			local nextSpeedup = (nextActual > 0) and (lv / nextActual) or 1
			pcall(function()
				liveLbl:Set(string.format("gap: %.2fs   idle: %.2fs   vanilla: %.1fs   next: %.2fx   last: %.2fx",
					g, liveIdle, lv, nextSpeedup, lm))
			end)
		end
		if tick() - lastDiag > 2 then
			lastDiag = tick()
			local g  = liveGap()
			local lv = tonumber(state.lastVanilla) or 0
			local lm = tonumber(state.lastMult) or 0
			local li = tonumber(state.lastIdle) or 0
			local pa = tonumber(state.prevActual) or 0
			print(string.format("[fastmine] active=%s mode=%s gap=%.2fs idle=%.2fs vanilla=%.2fs prev=%.2fs speedup=%.2f",
				tostring(state.active), tostring(state.mode), g, li, lv, pa, lm))
		end
	end)
	registerTeardown(function()
		if _G.__umt_fastmine_live then pcall(function() _G.__umt_fastmine_live:Disconnect() end) end
		_G.__umt_fastmine_live = nil
	end)

	bag.hooks.pick_resync = function()
		state.mult = fmMult:Get() or state.mult
		if smartToggle:Get() then
			state.mode = "smart"
		elseif fmToggle:Get() then
			state.mode = "static"
		end
		if (fmToggle:Get() or smartToggle:Get()) and not state.active then
			enable()
		elseif not fmToggle:Get() and not smartToggle:Get() and state.active then
			disable()
		elseif state.active then
			disable(); enable()
		end
	end

	bag.hooks.pick_disable = disable
	bag.hooks.pick_enable  = function() end
	bag.hooks.pick_unload  = disable
	registerTeardown(disable)
end

do
	local tab = mod:Tab({ Name = "server hop" })
	local sec = tab:Section("session")

	local VISIT_FILE = "BloomUI/umt_visited.json"
	local VISIT_TTL  = 4 * 3600

	local visited = {}

	local function loadVisited()
		if not (readfile and isfile and isfile(VISIT_FILE)) then return end
		local ok, raw = pcall(readfile, VISIT_FILE)
		if not ok or type(raw) ~= "string" then return end
		local ok2, obj = pcall(HS.JSONDecode, HS, raw)
		if ok2 and type(obj) == "table" then
			local now = os.time()
			for id, ts in pairs(obj) do

				if type(ts) == "number" and (now - ts) < VISIT_TTL then
					visited[id] = ts
				end
			end
		end
	end

	local function saveVisited()
		if not writefile then return end
		pcall(writefile, VISIT_FILE, HS:JSONEncode(visited))
	end

	local function markVisited(id)
		visited[id] = os.time()
		saveVisited()
	end

	local function isVisited(id)
		local ts = visited[id]
		if not ts then return false end
		if (os.time() - ts) >= VISIT_TTL then
			visited[id] = nil
			return false
		end
		return true
	end

	local function visitedCount()
		local n = 0; for _ in pairs(visited) do n += 1 end; return n
	end

	loadVisited()
	markVisited(game.JobId)

	local vLbl = sec:Label("visited: " .. visitedCount() .. "  (expire 4h)")

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
					   and not isVisited(v.id) then
						table.insert(servers, v.id)
					end
				end
			end
			vLbl:Set("visited: " .. visitedCount() .. " | fresh: " .. #servers)
			if #servers == 0 then notify("no fresh", "all seen or small pool", "warn") return end
			local target = servers[math.random(1, #servers)]
			markVisited(target)
			TS:TeleportToPlaceInstance(game.PlaceId, target, lp)
		end })
	sec:Button("hop_reset", { Text = "reset visited", Danger = true,
		Callback = function()
			visited = { [game.JobId] = os.time() }
			saveVisited()
			vLbl:Set("visited: 1"); notify("reset", "", "info")
		end })
	sec:Button("hop_rejoin", { Text = "rejoin this server",
		Callback = function() TS:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp) end })
end

mod:OnDisable(function()
	bag.hooks.xray_disable()
	bag.hooks.boost_disable()
	bag.hooks.pick_disable()
	if bag.hooks.fling_disable then bag.hooks.fling_disable() end
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
	if bag.hooks.fling_unload then bag.hooks.fling_unload() end
	for _, f in ipairs(bag.folders) do pcall(function() f:Destroy() end) end
	table.clear(bag.folders)
	print("[UMT] umt toolkit unloaded")
end)

_G.__umtToolkit = function()
	pcall(function() mod:Unload(true) end)
	print("[UMT] obliterated via _G")
end

mod:OnConfigLoaded(function(ok)
	if ok then notify("config", "loaded " .. CFG_NAME, "info") end
	for hname, fn in pairs(bag.hooks) do
		if hname:sub(-7) == "_resync" then pcall(fn) end
	end
end)

_G.__umtClaim = nil
print("[UMT] umt toolkit v2.1.10 loaded — smart = base + idle bonus, 10× floor cap")
notify("umt toolkit", "v2.1.10 — reasonable cap", "success")
