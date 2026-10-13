--[[
	UMT Toolkit — one Bloom module, four tabs
	Appears as "umt toolkit" in bloom / modules.
	Unload the module to deload the whole script cleanly.
]]

local BLOOM_URL   = "https://raw.githubusercontent.com/NanoBlazeDev/Roblox/refs/heads/main/UI/bloom-ui-lib.lua"
local TOOLKIT_URL = "https://raw.githubusercontent.com/NanoBlazeDev/Roblox/refs/heads/main/modules/UMT.lua"

-- ============================================================
--  CONCURRENCY GUARD — stop two parallel injections from both passing
--  the "no previous load" check and both wiring tabs.
-- ============================================================
do
	task.wait(math.random() * 0.2)  -- jitter so twin injections desync
	if _G.__umtClaim then
		local t0 = tick()
		while _G.__umtClaim and (tick() - t0) < 10 do task.wait(0.05) end
		-- the other load finished setup — bail; it already built everything
		if _G.__umtToolkit then return end
	end
	_G.__umtClaim = true  -- claim BEFORE any yielding call below
end

-- ============================================================
--  HARD KILL — authoritative teardown of ANY previous UMT load.
--  Must not rely on Bloom's module lifecycle (which may have been
--  singleton-swapped out from under the old module).
-- ============================================================
do
	-- 1. flip the shared session token so every old loop exits on next tick.
	--    old loops do `while _G.__umtSession == myToken`; mismatch → break.
	_G.__umtSession = {}  -- new unique table; old loops' myToken ~= this

	-- 2. call any registered teardown fns (xray/farland/boost/fling/fastmine/autosave)
	if _G.__umtTeardowns then
		for _, fn in ipairs(_G.__umtTeardowns) do pcall(fn) end
	end
	_G.__umtTeardowns = {}

	-- 3. nuke any UMT folders in workspace left behind
	for _, name in ipairs({ "UMT_XRay", "UMT_Farland", "UMT_Waypoint" }) do
		local f = workspace:FindFirstChild(name)
		while f do pcall(function() f:Destroy() end); f = workspace:FindFirstChild(name) end
	end

	-- 4. unhook fastmine unconditionally if it was ever hooked.
	--    __umt_mtf_hooked stores { target, original } so we can always
	--    restore to the TRUE original even if someone double-hooked.
	if _G.__umt_mtf_hooked and hookfunction then
		pcall(function()
			hookfunction(_G.__umt_mtf_hooked.target, _G.__umt_mtf_hooked.original)
		end)
		_G.__umt_mtf_hooked = nil
	end

	-- 5. fallback: call old legacy cleanup if present
	if _G.__umtToolkit then pcall(_G.__umtToolkit) end
	_G.__umtToolkit = nil

	-- give yielded loops one frame to actually exit before we build new state
	task.wait()
end

local SESSION = _G.__umtSession  -- the token this load owns; loops check against it

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

local CFG_NAME = "umt_default"  -- config slot name inside Bloom's shared config store

-- ============================================================
--  THE MODULE
-- ============================================================
local okMod, mod = pcall(function()
	return Bloom:Module({
		Name        = "umt toolkit",
		Version     = "1.1",
		Author      = "ExaVolt",
		Description = "ultimate mining tycoon tools — ore xray, vehicle boost, waypoints, flinger, fastmine, server hop",
		AutoConfig  = CFG_NAME,  -- Bloom owns load/save lifecycle for us
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

-- register a teardown fn that a FUTURE reload's hard-kill will call even if
-- Bloom's module lifecycle never fires. keep each fn pcall-safe + idempotent.
local function registerTeardown(fn)
	_G.__umtTeardowns = _G.__umtTeardowns or {}
	table.insert(_G.__umtTeardowns, fn)
end

-- master kill — flips all local loop flags so any surviving old loop in THIS
-- closure exits even if session-token check missed a tick.
registerTeardown(function()
	bag.flags.xrayAlive = false
	bag.flags.hardWatchAlive = false
	bag.flags.farAlive = false
	bag.flags.autosaveAlive = false
	for _, f in ipairs(bag.folders) do pcall(function() f:Destroy() end) end
	table.clear(bag.folders)
end)

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
		if not state.active then return 0 end  -- toggled off between calls
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
		while bag.flags.hardWatchAlive and _G.__umtSession == SESSION do
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

	-- ====================================================================
	--  FARLAND — global scan: highlights the single best mineable ore + gem
	--  anywhere in the mine (ignoring radius). Cap keeps perf sane.
	-- ====================================================================
	local farlandState = {
		active   = false,
		oreCap   = 30,  -- gems = oreCap / 2
		folder   = nil,
		bestOre  = nil, -- ore id (string)
		bestGem  = nil,
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

	-- determine the single best ore + best gem user can mine (by value).
	-- Gem classification takes precedence over Ore (Diamond, Topaz etc are
	-- flagged as both Types.Ore AND Types.Gem in BlockDef — treat them as
	-- Gems to match the wiki/user expectation).
	local function computeBest()
		if not (MUtils and BlockDef and Settings) then return end
		local hard = MUtils.GetPlayerPickaxeHardnessClient()
		local limit = Settings.MiningHardnessRatioLimit
		local topOre, topGem = nil, nil
		for id, def in pairs(BlockDef) do
			if def.Hardness and not def.ExplosiveOnly and (def.Hardness / hard) <= limit and def.Types then
				local isGem = def.Types.Gem == true
				local isOre = def.Types.Ore == true and not isGem  -- Gem wins
				local v = def.Value or 0
				if isGem then
					if not topGem or v > topGem.value then
						topGem = { id = id, value = v, name = def.Name }
					end
				elseif isOre then
					if not topOre or v > topOre.value then
						topOre = { id = id, value = v, name = def.Name }
					end
				end
			end
		end
		farlandState.bestOre     = topOre and topOre.id or nil
		farlandState.bestGem     = topGem and topGem.id or nil
		farlandState.bestOreName = topOre and topOre.name or nil
		farlandState.bestGemName = topGem and topGem.name or nil
	end

	-- cached ore position index — rebuilt lazily, 10s TTL.
	-- MASSIVE perf win: full MT._Cells iteration happens max once per 10s
	-- instead of every farScan (which was every 5s), AND lookups are O(1)
	-- hash by ore id instead of O(n) full-cache scan.
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
		-- VISIBLE colored part (not invisible-part-with-adornment).
		-- Adornments like BoxHandleAdornment only render when their adornee
		-- is on-screen, so far-away markers invisible. Visible parts with
		-- Material=ForceField glow at any distance and ignore adornment
		-- rendering limits.
		local part = Instance.new("Part")
		part.Size = Vector3.new(3.9, 3.9, 3.9)  -- match actual cell size (voxel = 4 studs)
		part.CFrame = CFrame.new(wp)
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Transparency = 0.25
		part.Color = color
		part.Material = Enum.Material.ForceField  -- glows, visible from any distance
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = farlandState.folder

		-- Highlight for ALWAYS-ON-TOP rendering through terrain
		local hl = Instance.new("Highlight")
		hl.Adornee = part
		hl.FillColor = color
		hl.FillTransparency = 0.4
		hl.OutlineColor = Color3.fromRGB(255, 255, 255)
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = part

		-- floating billboard with ore name — visible from any distance
		if label then
			local bg = Instance.new("BillboardGui")
			bg.Adornee = part
			bg.Size = UDim2.fromOffset(160, 32)
			bg.StudsOffset = Vector3.new(0, 4, 0)
			bg.AlwaysOnTop = true
			bg.MaxDistance = 0  -- 0 = unlimited visibility distance
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

	-- count instances of a given ore id in the whole cache
	local function countOnServer(oreId)
		if not oreId or not MT then return 0 end
		return getIndex().counts[oreId] or 0
	end

	local function farScan()
		if not MT then return end
		farClear()
		computeBest()
		if not (farlandState.bestOre or farlandState.bestGem) then return end
		local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
		local myPos = hrp and hrp.Position or Vector3.new()
		local idx = getIndex().byOre
		-- O(1) hash lookup instead of full-cache scan
		local oreCoords = idx[farlandState.bestOre] or {}
		local gemCoords = idx[farlandState.bestGem] or {}
		local ores, gems = table.create(#oreCoords), table.create(#gemCoords)
		for i = 1, #oreCoords do
			local c = oreCoords[i]
			local wp = Terrain:CellCenterToWorld(c.X, c.Y, c.Z)
			ores[i] = { coord = c, d2 = (wp - myPos).Magnitude ^ 2 }
		end
		for i = 1, #gemCoords do
			local c = gemCoords[i]
			local wp = Terrain:CellCenterToWorld(c.X, c.Y, c.Z)
			gems[i] = { coord = c, d2 = (wp - myPos).Magnitude ^ 2 }
		end
		table.sort(ores, function(a, b) return a.d2 < b.d2 end)
		table.sort(gems, function(a, b) return a.d2 < b.d2 end)
		local oreCap = farlandState.oreCap
		local gemCap = math.floor(oreCap / 2)
		local oreColor = ORE_COLORS[farlandState.bestOre] or Color3.fromRGB(255,255,255)
		local gemColor = ORE_COLORS[farlandState.bestGem] or Color3.fromRGB(255,255,255)
		for i = 1, math.min(oreCap, #ores) do makeFarMarker(ores[i].coord, oreColor, farlandState.bestOreName) end
		for i = 1, math.min(gemCap, #gems) do makeFarMarker(gems[i].coord, gemColor, farlandState.bestGemName) end
	end

	local farSection = tab:Section("farland (best-ore global ESP)")
	local farToggleCtrl = farSection:Toggle("farland_on", {
		Label = "farland enabled", Default = false,
		Callback = function(v)
			farlandState.active = v
			if v then farScan() else farClear() end
		end,
	})
	farSection:Int("farland_cap", {
		Label = "ore limit (gems = limit / 2)",
		Default = farlandState.oreCap, Min = 2, Max = 60, Step = 2,
		Callback = function(v)
			farlandState.oreCap = v
			if farlandState.active then farScan() end
		end,
	})
	-- live-updating stats labels (refreshed every 5s + on hardness change)
	local farOreLbl = farSection:Label("Ore: —")
	local farGemLbl = farSection:Label("Gem: —")

	-- forward-declare so the button Callback below closes over the real local
	-- (Lua binds at closure-creation; a reference to an not-yet-declared local
	-- becomes a global reference that stays nil forever → `attempt to call nil`
	-- when the button is clicked. Declare the local FIRST, assign body after,
	-- or declare and assign before any closure that uses it.)
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
			getIndex(true)  -- force index rebuild
			refreshFarLabels()
			if farlandState.active then farScan() end
			notify("farland", "index rebuilt", "info")
		end,
	})

	-- auto-rescan every 5s: refresh labels + redraw markers if active
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

	-- JOIN NOTIFICATION — 10s after load, report best stuff on server
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
		GRIP_MULT  = 2, DOWNFORCE_MULT = 1,  -- downforce grows with speed² — keep LOW to avoid suspension crush
	}

	local function boost(vb)
		if not state.enabled then return end
		local perf = vb.PerformanceFolder; if not perf then return end
		if _G.__umtBoosted[perf] then return end  -- already boosted this session

		-- caller (DriverId handler) has already waited for Components.Engine
		-- and WheeledVehicle to exist. small settle here lets PetrolEngine's
		-- AttributeChanged listener bind before we write.
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
					-- Roblox clamps Friction to [0, 2]. Pre-clamp to silence warnings
					-- and still give the maximum traction allowed.
					local newFriction = math.clamp((old and old.Friction or 1.2) * state.GRIP_MULT, 0, 2)
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
			-- if stock downforce is 0 (Quadbike by design), inject a small
			-- baseline so slider > 1 still has some effect. 0.3 keeps the
			-- suspension-crush at high speed to a reasonable amount.
			local base = (aero.DownforceCoeff > 0) and aero.DownforceCoeff or 0.3
			aero.DownforceCoeff = base * state.DOWNFORCE_MULT
		end

		_G.__umtBoosted[perf] = entry
		notify("boosted", vb.Model.Name, "success")
	end

	local function revertAll()
		for perf, orig in pairs(_G.__umtBoosted) do
			if orig.pending then continue end  -- not actually applied yet
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
			-- RACE FIX: wait for BOTH (a) VC to resolve the vehicle AND
			-- (b) the vehicle's Components.Engine + WheeledVehicle to exist
			-- (meaning InitComponents ran). Newly-spawned vehicles need
			-- longer than first-ever vehicle — poll up to 3s.
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
	sec:Number("boost_down", { Label = "downforce mult (grows with speed² — keep ≤2)", Default = 1, Min = 0, Max = 10, Step = 0.1,
		Callback = function(v) state.DOWNFORCE_MULT = v end })
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

-- ============================================================
--  TAB — WAYPOINTS (recall own car + per-key TPs)
-- ============================================================
do
	local HS2 = HS  -- reuse HttpService alias from top
	local WP_PATH   = "BloomUI/vehicle_waypoints.json"
	local TP_Y_LIFT = 5

	-- helpers
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

	-- shared anchor-dance teleport
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

	-- waypoints shape: [name] = { cf = {12 CFrame components}, key = "KeyCodeName" or "" }
	local waypoints = {}

	local function loadWaypoints()
		if not (isfile and readfile and isfile(WP_PATH)) then return end
		local ok, data = pcall(readfile, WP_PATH)
		if not ok then return end
		local ok2, parsed = pcall(function() return HS2:JSONDecode(data) end)
		if ok2 and type(parsed) == "table" then
			waypoints = parsed
			-- migrate old flat-array format
			for name, v in pairs(waypoints) do
				if type(v) == "table" and v[1] and not v.cf then
					waypoints[name] = { cf = v, key = "" }
				end
			end
		end
	end

	local function saveWaypoints()
		if not writefile then return end
		pcall(function() writefile(WP_PATH, HS2:JSONEncode(waypoints)) end)
	end

	local function labelOf(name)
		local wp = waypoints[name]
		if wp and wp.key and wp.key ~= "" and wp.key ~= "Unknown" then
			return name .. "  [" .. wp.key .. "]"
		end
		return name
	end

	local function nameFromLabel(label)
		if not label or label == "" then return nil end
		return (label:gsub("%s%s%[.-%]$", ""))
	end

	local function waypointLabels()
		local out = {}
		for name in pairs(waypoints) do table.insert(out, labelOf(name)) end
		table.sort(out)
		return out
	end

	local function teleportTo(name)
		local wp = waypoints[name]
		if not wp or not wp.cf then return false, "no such waypoint" end
		local vb = myVehicleHere(); if not vb then return false, "sit in your car first" end
		local target = CFrame.new(unpack(wp.cf)) + Vector3.new(0, TP_Y_LIFT, 0)
		return pivotWithAnchorDance(vb.Model, target)
	end

	loadWaypoints()

	local tab = mod:Tab({ Name = "waypoints" })

	-- recall section
	local secRecall = tab:Section("recall my car")
	local function bringMyCar()
		local vb = myVehicleHere()
		if not vb then notify("recall", "no driven vehicle", "error") return end
		local hrp = myHrp()
		if not hrp then notify("recall", "no character", "error") return end
		pivotWithAnchorDance(vb.Model, hrp.CFrame * CFrame.new(0, 3, -8))
		notify("recalled", "car in front", "success")
	end
	secRecall:Button("recall_bring", {
		Text = "bring my car in front of me",
		Primary = true,
		Callback = bringMyCar,
	})
	secRecall:Keybind("recall_key", {
		Label = "recall key",
		Default = Enum.KeyCode.B,
		OnPress = bringMyCar,
	})

	-- new waypoint section
	local secAdd = tab:Section("new waypoint")
	local dropdown
	local keybindCtrl

	local nameInput = secAdd:String("wp_name", {
		Label = "name", Default = "", Placeholder = "my spot",
	})
	secAdd:Button("wp_save", {
		Text = "save current car position",
		Primary = true,
		Callback = function()
			local name = (nameInput:Get() or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if name == "" then notify("waypoints", "enter a name first", "error") return end
			local pp = myPrimary()
			if not pp then notify("waypoints", "no driven vehicle", "error") return end
			local prevKey = (waypoints[name] and waypoints[name].key) or ""
			waypoints[name] = { cf = { pp.CFrame:GetComponents() }, key = prevKey }
			saveWaypoints()
			notify("saved", name, "success")
			if dropdown then
				dropdown:SetOptions(waypointLabels())
				dropdown:Set(labelOf(name))
			end
		end,
	})

	-- saved list section
	local secList = tab:Section("saved waypoints")

	local initial = waypointLabels()
	if #initial == 0 then initial = { "(none saved)" } end

	dropdown = secList:Enum("wp_pick", {
		Label = "waypoint", Options = initial, Default = initial[1],
		Callback = function(label)
			if not keybindCtrl then return end
			local name = nameFromLabel(label)
			local wp = name and waypoints[name]
			local keyName = wp and wp.key or ""
			if keyName ~= "" and keyName ~= "Unknown" then
				local ok, k = pcall(function() return Enum.KeyCode[keyName] end)
				if ok and k then keybindCtrl:Set(k, true); return end
			end
			keybindCtrl:Set(Enum.KeyCode.Unknown, true)
		end,
	})

	keybindCtrl = secList:Keybind("wp_set_key", {
		Label = "key for selected (empty = none)",
		Default = Enum.KeyCode.Unknown,
		OnPress = function() end,
	})

	keybindCtrl.Changed:Connect(function()
		local sel = dropdown:Get()
		local name = nameFromLabel(sel)
		local wp = name and waypoints[name]
		if not wp then return end
		local key = keybindCtrl:Get()
		local keyName = (typeof(key) == "EnumItem" and key.Name) or ""
		if keyName == "Unknown" then keyName = "" end
		if wp.key == keyName then return end
		wp.key = keyName
		saveWaypoints()
		dropdown:SetOptions(waypointLabels())
		dropdown:Set(labelOf(name))
	end)

	secList:Button("wp_tp", {
		Text = "teleport to selected",
		Primary = true,
		Callback = function()
			local sel = dropdown:Get()
			if not sel or sel == "(none saved)" then
				notify("waypoints", "pick one first", "error") return
			end
			local name = nameFromLabel(sel)
			local ok, err = teleportTo(name)
			if ok then notify("tp'd", name, "success")
			else notify("tp failed", err or "?", "error") end
		end,
	})
	secList:Button("wp_delete", {
		Text = "delete selected",
		Danger = true,
		Callback = function()
			local sel = dropdown:Get()
			if not sel or sel == "(none saved)" then return end
			local name = nameFromLabel(sel)
			if not name then return end
			waypoints[name] = nil
			saveWaypoints()
			local list = waypointLabels()
			if #list == 0 then list = { "(none saved)" } end
			dropdown:SetOptions(list)
			dropdown:Set(list[1])
			notify("deleted", name, "info")
		end,
	})
	secList:Button("wp_refresh", {
		Text = "reload from disk",
		Callback = function()
			loadWaypoints()
			local list = waypointLabels()
			if #list == 0 then list = { "(none saved)" } end
			dropdown:SetOptions(list)
			dropdown:Set(list[1])
			notify("reloaded", #list .. " waypoints", "info")
		end,
	})

	-- global quick-tp listener for all waypoint keys
	mod:Connect(UIS.InputBegan, function(input, gpe)
		if gpe then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		local kname = input.KeyCode.Name
		if kname == "Unknown" then return end
		for name, wp in pairs(waypoints) do
			if wp.key == kname then
				teleportTo(name)
				break
			end
		end
	end)

	-- expose flinger helpers via upvalue capture for flinger tab below
	_G.__umtVFHelpers = {
		myVehicle    = myVehicleHere,
		myPrimary    = myPrimary,
		myHrp        = myHrp,
		pivotDance   = pivotWithAnchorDance,
	}
end

-- ============================================================
--  TAB — FLINGER (fling other players' vehicles via physics)
-- ============================================================
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

-- ============================================================
--  TAB — FAST PICKAXE
-- ============================================================
do
	local tab = mod:Tab({ Name = "fastmine" })
	local sec = tab:Section("timing")

	local state = { active = false, mult = 0.75, oldMTF = nil }
	local function enable()
		if state.active or not MTF or not hookfunction then return end
		-- stash the TRUE original globally the first time we ever hook, so a
		-- later reload (without this closure) can still restore it cleanly.
		if not _G.__umt_mtf_hooked then
			_G.__umt_mtf_hooked = { target = MTF, original = nil }
		end
		local prev = hookfunction(MTF, function(speed, hardness, bh)
			return state.oldMTF(speed, hardness, bh) * state.mult
		end)
		state.oldMTF = prev
		-- only record the FIRST hook's return as "true original"
		if _G.__umt_mtf_hooked.original == nil then
			_G.__umt_mtf_hooked.original = prev
		end
		state.active = true
	end
	local function disable()
		if not state.active then return end
		-- unconditionally restore to the TRUE original if we have it
		local trueOrig = _G.__umt_mtf_hooked and _G.__umt_mtf_hooked.original
		pcall(function() hookfunction(MTF, trueOrig or state.oldMTF) end)
		_G.__umt_mtf_hooked = nil
		state.active = false
	end

	local fmToggle = sec:Toggle("fastmine_on", { Label = "enable", Default = false,
		Callback = function(v)
			if v then enable(); notify("fastmine on", "x" .. state.mult, "success")
			else disable() end
		end })
	-- expose so autoload can re-apply the hook after a silent LoadConfig
	-- (LoadConfig restores toggle state but skips the Callback → hook not set)
	bag.hooks.pick_resync = function()
		if fmToggle:Get() and not state.active then
			enable()
		elseif not fmToggle:Get() and state.active then
			disable()
		end
	end
	sec:Number("fastmine_mult", { Label = "time multiplier (lower = faster)",
		Default = 0.75, Min = 0.1, Max = 1.0, Step = 0.05,
		Callback = function(v) state.mult = v; if state.active then disable() enable() end end })
	sec:Label("warning: < 0.5 risks server rollback")

	bag.hooks.pick_disable = disable
	bag.hooks.pick_enable  = function() end
	bag.hooks.pick_unload  = disable
	registerTeardown(disable)
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

-- ============================================================
--  POST-LOAD HOOKS
-- ============================================================
-- Bloom's AutoConfig handles LoadConfig + autosave + unload-flush for us.
-- All we do here is wire the resyncs that have to run after a silent load
-- (fastmine hookfunction can't be installed via a silent toggle restore).
mod:OnConfigLoaded(function(ok)
	if ok then notify("config", "loaded " .. CFG_NAME, "info") end
	for hname, fn in pairs(bag.hooks) do
		if hname:sub(-7) == "_resync" then pcall(fn) end
	end
end)

_G.__umtClaim = nil  -- release concurrency lock
print("[UMT] umt toolkit v1.1 loaded — 6 tabs ready")
notify("umt toolkit", "loaded — 4 tabs", "success")
