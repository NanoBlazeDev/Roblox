--[[
	bloom ui lib · v0.1.0
	Admin UI library for Roblox (client-side). Single ModuleScript.

	local Bloom = require(game.ReplicatedStorage.Bloom)
	local win = Bloom:CreateWindow({ Title = "admin", ToggleKey = Enum.KeyCode.RightShift })
	local tab = win:Tab({ Name = "Players", Icon = "users", Group = "Control" })
	local sec = tab:Section("Identity")
	sec:String("name", { Label = "Name", Default = "", Callback = function(v) end })

	Controls (Section methods): String, Number, Int, Toggle, Check, Vector3, Vector2, UDim2,
	Color, Enum (Enum type or list of strings), CFrame, Table, Instance, Range, Keybind,
	Button, Label. Each returns a control: :Get() :Set(v, silent) .Changed :SetVisible(b)

	Window: :Tab :Notify :Dialog :Show :Hide :Toggle :SelectTab :Destroy
	        :SaveConfig :LoadConfig :ListConfigs :DeleteConfig  (backed by Bloom.ConfigEndpoint)
	Global:  Bloom:SetTheme(themeOrName, { Tween = 0.35 }), Bloom.Themes, Bloom.Icons
]]

-- singleton: if a Bloom instance is already running on this executor,
-- reuse it instead of creating a second window+table. lets multiple
-- scripts loadstring Bloom independently and share one window.
--
-- race-safe: a plain `if _G.__BloomInstance then return` leaves a window
-- where two concurrent loadstrings both see nil and both build a window.
-- Fix: claim a lightweight lock IMMEDIATELY (before any yielding call),
-- so a second concurrent load sees the claim and waits for the first to
-- finish, then returns the finished instance.
do
	-- small random stagger so simultaneous injections desync
	task.wait(math.random() * 0.15)

	if _G.__BloomInstance then return _G.__BloomInstance end
	if _G.__BloomClaim then
		-- another load is mid-build; wait up to 10s for it to finish, then
		-- return its instance.
		local t0 = tick()
		while _G.__BloomClaim and (tick() - t0) < 10 do task.wait(0.05) end
		if _G.__BloomInstance then return _G.__BloomInstance end
		-- fell through (claim stuck or died) — proceed to build ours
	end
	_G.__BloomClaim = true  -- claimed BEFORE any yield below
end

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local Bloom = {}
Bloom.Version = "0.2.0"

--------------------------------------------------------------------------
-- Signal
--------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _h = {} }, Signal)
end

function Signal:Connect(fn)
	local h = { fn = fn, on = true }
	table.insert(self._h, h)
	return {
		Disconnect = function()
			h.on = false
			local i = table.find(self._h, h)
			if i then table.remove(self._h, i) end
		end,
	}
end

function Signal:Fire(...)
	for _, h in table.clone(self._h) do
		if h.on then task.spawn(h.fn, ...) end
	end
end

Bloom.Signal = Signal
Bloom.ThemeChanged = Signal.new()

--------------------------------------------------------------------------
-- Motion (TweenInfo spec)
--------------------------------------------------------------------------
local ES, ED = Enum.EasingStyle, Enum.EasingDirection
local Motion = {
	Hover = TweenInfo.new(0.14, ES.Sine, ED.Out),
	HoverOut = TweenInfo.new(0.22, ES.Sine, ED.Out),
	Open = TweenInfo.new(0.42, ES.Quint, ED.Out),
	Close = TweenInfo.new(0.22, ES.Quad, ED.In),
	Knob = TweenInfo.new(0.34, ES.Back, ED.Out),
	Drop = TweenInfo.new(0.24, ES.Quart, ED.Out),
	Toast = TweenInfo.new(0.5, ES.Exponential, ED.Out),
	Tab = TweenInfo.new(0.3, ES.Quint, ED.InOut),
	Theme = TweenInfo.new(0.35, ES.Sine, ED.InOut),
	Value = TweenInfo.new(0.2, ES.Quart, ED.Out),
	Stagger = TweenInfo.new(0.22, ES.Quart, ED.Out),
	Dim = TweenInfo.new(0.3, ES.Sine, ED.Out),
}
Bloom.Motion = Motion

local function tween(inst, info, goal)
	local t = TweenService:Create(inst, info, goal)
	t:Play()
	return t
end

--------------------------------------------------------------------------
-- Themes
--------------------------------------------------------------------------
local ThemeMT = {}
ThemeMT.__index = ThemeMT

local function convert(k, v)
	if typeof(v) == "string" and k ~= "Name" then
		return Color3.fromHex(v)
	end
	return v
end

function ThemeMT:Extend(over)
	local t = table.clone(self)
	for k, v in over do
		t[k] = convert(k, v)
	end
	return setmetatable(t, ThemeMT)
end

local function makeTheme(def)
	local t = {}
	for k, v in def do
		t[k] = convert(k, v)
	end
	return setmetatable(t, ThemeMT)
end

local FONT_DISPLAY = Font.fromName("JosefinSans", Enum.FontWeight.SemiBold)
local FONT_BODY = Font.fromName("Nunito", Enum.FontWeight.Regular)
local FONT_BODY_BOLD = Font.fromName("Nunito", Enum.FontWeight.Bold)
local FONT_MONO = Font.fromName("Inconsolata", Enum.FontWeight.Medium)
local FONT_MONO_BOLD = Font.fromName("Inconsolata", Enum.FontWeight.Bold)

-- Peony: the default. Every theme keeps TextFaint >= ~4.5:1 against Window.
local Peony = makeTheme({
	Name = "Peony",
	Bg = "0D0A0D", Window = "151116", Surface = "1C171D", Raised = "251E26",
	Stroke = "2F2730", StrokeStrong = "41363F",
	Text = "F3ECEF", TextDim = "C2B5BC", TextFaint = "9D8F97",
	Accent = "FF8FB1", AccentInk = "2A0B16",
	Warn = "FFC069", Bad = "FF6B6B", Ok = "8EE3B5", Info = "9CC8FF",
	AxisX = "FF7A8A", AxisY = "8EE3B5", AxisZ = "9CC8FF",
	TStr = "F2C48D", TNum = "9CC8FF", TInt = "B9A8FF", TBool = "FF8FB1", TVec = "FFA88A",
	TTbl = "D2A8FF", TCol = "FF9FD0", TEnum = "7FE0CF", TInst = "C9BFC5", TFn = "F4E58A",
	Shadow = "000000", Dim = 0.3, Radius = 6,
	PatternAlpha = 0.08, PatternTint = "FF8FB1",
	Glow1 = "FF8FB1", Glow2 = "B48CFF",
	Display = FONT_DISPLAY, Body = FONT_BODY, BodyBold = FONT_BODY_BOLD, Mono = FONT_MONO, MonoBold = FONT_MONO_BOLD,
})

Bloom.Themes = {
	Peony = Peony,
	-- Sakura: soft light grey with a deeper blossom pink (no paper-white glare)
	Sakura = Peony:Extend({
		Name = "Sakura",
		Bg = "AEA8AC", Window = "CFCACD", Surface = "C5BFC2", Raised = "BBB5B8",
		Stroke = "B2ACAF", StrokeStrong = "9A9397",
		Text = "1E191B", TextDim = "40393C", TextFaint = "564E52",
		Accent = "A8325A", AccentInk = "FFF2F6",
		Warn = "7A4700", Bad = "9A1E18", Ok = "15623A", Info = "1F4C88",
		AxisX = "A02C26", AxisY = "15623A", AxisZ = "1F4C88",
		TStr = "6A4400", TNum = "1F4C88", TInt = "3C3499", TBool = "A8325A", TVec = "8E3610",
		TTbl = "5E2E94", TCol = "902455", TEnum = "0A5E4E", TInst = "463F43", TFn = "5A4E00",
		Shadow = "2A1A20", Dim = 0.15,
		PatternAlpha = 0.11, PatternTint = "A8325A",
		Glow1 = "C9577F", Glow2 = "B98552",
	}),
	Lotus = Peony:Extend({
		Name = "Lotus",
		Bg = "071012", Window = "0C1719", Surface = "111F22", Raised = "17292D",
		Stroke = "1F3337", StrokeStrong = "2C4549",
		Text = "E6F1EF", TextDim = "A9C0BD", TextFaint = "85A09C",
		Accent = "F2A7C9", AccentInk = "2B0D1B", TBool = "F2A7C9",
		PatternTint = "5FD4C4", Glow1 = "5FD4C4", Glow2 = "F2A7C9",
	}),
	Iris = Peony:Extend({
		Name = "Iris",
		Bg = "0A0914", Window = "110F1E", Surface = "171527", Raised = "1F1C33",
		Stroke = "29263F", StrokeStrong = "3A3657",
		Text = "ECEAF7", TextDim = "B3AFCF", TextFaint = "8F8AB0",
		Accent = "A99BFF", AccentInk = "140E33", TBool = "A99BFF",
		PatternTint = "A99BFF", Glow1 = "A99BFF", Glow2 = "6FC3FF",
	}),
	Marigold = Peony:Extend({
		Name = "Marigold",
		Bg = "120D08", Window = "1A130C", Surface = "221911", Raised = "2C2117",
		Stroke = "382B1F", StrokeStrong = "4E3D2C",
		Text = "F7EDE0", TextDim = "CDB9A2", TextFaint = "A8927A",
		Accent = "FFB23E", AccentInk = "2A1700", TBool = "FFB23E",
		PatternTint = "FFB23E", Glow1 = "FFB23E", Glow2 = "FF6F61",
	}),
	Lily = Peony:Extend({
		Name = "Lily",
		Bg = "0A0A0A", Window = "111111", Surface = "181818", Raised = "212121",
		Stroke = "2A2A2A", StrokeStrong = "3D3D3D",
		Text = "F5F5F5", TextDim = "BDBDBD", TextFaint = "959595",
		Accent = "F5F5F5", AccentInk = "0A0A0A",
		TStr = "D9D9D9", TNum = "D9D9D9", TInt = "D9D9D9", TBool = "F5F5F5", TVec = "D9D9D9",
		TTbl = "D9D9D9", TCol = "D9D9D9", TEnum = "D9D9D9", TInst = "BDBDBD", TFn = "D9D9D9",
		PatternAlpha = 0.06, PatternTint = "F5F5F5", Glow1 = "F5F5F5", Glow2 = "5A5A5A",
	}),
}

local current = Peony
local painted = setmetatable({}, { __mode = "k" }) -- Instance -> { prop = token }
local corners = setmetatable({}, { __mode = "k" }) -- UICorner -> base radius
local patterns = setmetatable({}, { __mode = "k" }) -- background pattern ImageLabels

-- Background pattern: a seamless tile (white lines on transparent), tinted by the theme.
Bloom.Pattern = {
	Image = "rbxassetid://128708357911120", -- built-in wave tile (512x512, seamless)
	TileSize = 256, -- on-screen size of one tile (source is 512x512)
	Speed = 12, -- drift in px/s, 0 = static
	Parallax = 3, -- max px the pattern shifts against the cursor
	Alpha = nil, -- overrides theme.PatternAlpha (0..1)
}

-- Window border: UIStroke with a rotating two-colour gradient (theme.Glow1 -> theme.Glow2).
Bloom.Border = {
	Enabled = true, -- false = plain 1px stroke
	Animated = true,
	Speed = 40, -- degrees per second
	Thickness = 1.5,
}

local function patternTransparency()
	return 1 - (Bloom.Pattern.Alpha or current.PatternAlpha or 0.07)
end

local function paint(inst, map)
	local rec = painted[inst]
	if not rec then
		rec = {}
		painted[inst] = rec
	end
	for prop, token in map do
		rec[prop] = token
		inst[prop] = current[token]
	end
	return inst
end

local function recolor(inst, prop, token, info)
	local rec = painted[inst]
	if not rec then
		rec = {}
		painted[inst] = rec
	end
	rec[prop] = token
	if info then
		tween(inst, info, { [prop] = current[token] })
	else
		inst[prop] = current[token]
	end
end

function Bloom:GetTheme()
	return current
end

function Bloom:SetTheme(t, opts)
	if typeof(t) == "string" then
		t = Bloom.Themes[t]
	end
	assert(type(t) == "table", "Bloom:SetTheme — unknown theme")
	current = t
	local dur = (opts and opts.Tween) or 0.35
	local info = TweenInfo.new(dur, ES.Sine, ED.InOut)
	for inst, rec in painted do
		local goal = nil
		for prop, token in rec do
			local v = t[token]
			if v ~= nil then
				if typeof(v) == "Color3" and dur > 0 and inst.Parent then
					goal = goal or {}
					goal[prop] = v
				else
					inst[prop] = v
				end
			end
		end
		if goal then
			TweenService:Create(inst, info, goal):Play()
		end
	end
	for c, base in corners do
		c.CornerRadius = UDim.new(0, math.max(0, math.round(base * (t.Radius or 5) / 5)))
	end
	for img, owner in patterns do
		local a = type(owner) == "table" and owner:_patAlpha() or patternTransparency()
		if dur > 0 and img.Visible then
			TweenService:Create(img, info, { ImageTransparency = a }):Play()
		else
			img.ImageTransparency = a
		end
	end
	Bloom.ThemeChanged:Fire(t)
end

--------------------------------------------------------------------------
-- Icons (sprite atlas)
--------------------------------------------------------------------------
local Icons = {
	Atlas = "", -- rbxassetid://<id> of rivet_icons.png (1024x576, 16 cols, 64px cells)
	Cell = 64,
	Columns = 16,
	Map = {
		["users"]=0, ["user"]=1, ["globe"]=2, ["server"]=3, ["crosshair"]=4, ["terminal"]=5, ["save"]=6, ["search"]=7,
		["bell"]=8, ["x"]=9, ["check"]=10, ["plus"]=11, ["minus"]=12, ["chevron-right"]=13, ["chevron-down"]=14, ["chevron-up"]=15,
		["chevron-left"]=16, ["copy"]=17, ["trash-2"]=18, ["box"]=19, ["keyboard"]=20, ["download"]=21, ["upload"]=22, ["lock"]=23,
		["lock-open"]=24, ["eye"]=25, ["eye-off"]=26, ["refresh-cw"]=27, ["play"]=28, ["pause"]=29, ["ban"]=30, ["zap"]=31,
		["map-pin"]=32, ["snowflake"]=33, ["shield"]=34, ["sliders-horizontal"]=35, ["code"]=36, ["settings"]=37, ["palette"]=38, ["scroll-text"]=39,
		["layout-dashboard"]=40, ["house"]=41, ["wrench"]=42, ["hammer"]=43, ["sword"]=44, ["skull"]=45, ["heart"]=46, ["star"]=47,
		["flag"]=48, ["crown"]=49, ["gavel"]=50, ["user-plus"]=51, ["user-minus"]=52, ["user-x"]=53, ["user-check"]=54, ["message-square"]=55,
		["megaphone"]=56, ["volume-2"]=57, ["volume-x"]=58, ["sun"]=59, ["moon"]=60, ["cloud"]=61, ["clock"]=62, ["timer"]=63,
		["activity"]=64, ["cpu"]=65, ["wifi"]=66, ["database"]=67, ["folder"]=68, ["file"]=69, ["file-text"]=70, ["link"]=71,
		["external-link"]=72, ["info"]=73, ["triangle-alert"]=74, ["circle-alert"]=75, ["circle-check"]=76, ["circle-x"]=77, ["circle-help"]=78, ["move"]=79,
		["rotate-cw"]=80, ["maximize-2"]=81, ["minimize-2"]=82, ["grip-vertical"]=83, ["ellipsis"]=84, ["filter"]=85, ["list"]=86, ["table"]=87,
		["braces"]=88, ["hash"]=89, ["type"]=90, ["toggle-left"]=91, ["calendar"]=92, ["map"]=93, ["compass"]=94, ["rocket"]=95,
		["car"]=96, ["bike"]=97, ["coins"]=98, ["gift"]=99, ["package"]=100, ["sparkles"]=101, ["wand-sparkles"]=102, ["bug"]=103,
		["flame"]=104, ["droplet"]=105, ["mountain"]=106, ["trees"]=107, ["tag"]=108, ["bookmark"]=109, ["power"]=110, ["log-out"]=111,
		["log-in"]=112, ["arrow-right"]=113, ["arrow-left"]=114, ["arrow-up"]=115, ["arrow-down"]=116, ["undo-2"]=117, ["redo-2"]=118, ["history"]=119,
		["pin"]=120, ["camera"]=121, ["video"]=122, ["image"]=123, ["mouse-pointer-2"]=124, ["hand"]=125, ["target"]=126, ["radar"]=127,
		["swords"]=128, ["shield-check"]=129, ["key-round"]=130, ["fingerprint"]=131, ["ghost"]=132, ["footprints"]=133, ["plane"]=134, ["navigation"]=135,
		["locate"]=136, ["command"]=137, ["layers"]=138, ["gauge"]=139, ["chart-line"]=140, ["pipette"]=141, ["paintbrush"]=142, ["ruler"]=143,
	},
	_live = setmetatable({}, { __mode = "k" }),
}
Bloom.Icons = Icons

function Icons.Apply(img, name)
	Icons._live[img] = name
	local i = name and Icons.Map[name]
	local fb = img:FindFirstChild("Fallback")
	if i and Icons.Atlas ~= "" then
		img.Image = Icons.Atlas
		img.ImageRectSize = Vector2.new(Icons.Cell, Icons.Cell)
		img.ImageRectOffset = Vector2.new((i % Icons.Columns) * Icons.Cell, math.floor(i / Icons.Columns) * Icons.Cell)
		if fb then fb.Visible = false end
	else
		img.Image = ""
		if fb then fb.Visible = name ~= nil end
	end
end

-- Swap in your own atlas: Icons.Register("rbxassetid://123", { name = index, ... }, 64, 16)
function Icons.Register(assetId, map, cell, columns)
	Icons.Atlas = assetId or Icons.Atlas
	if map then Icons.Map = map end
	Icons.Cell = cell or Icons.Cell
	Icons.Columns = columns or Icons.Columns
	for img, name in Icons._live do
		Icons.Apply(img, name)
	end
	if Icons.Atlas ~= "" then
		task.spawn(function()
			pcall(ContentProvider.PreloadAsync, ContentProvider, { Icons.Atlas })
		end)
	end
end

-- Auto-load icon atlas from BloomUI/icons.png.
-- Downloads from Bloom.AtlasUrl on first run and caches to disk.
-- If URL ends in .txt or .b64, treats the body as base64 and decodes to PNG
-- (lets you host via GitHub Gist which refuses binary paste).
Bloom.AtlasUrl = Bloom.AtlasUrl
	or "https://raw.githubusercontent.com/NanoBlazeDev/Roblox/refs/heads/main/UI/icons.png?raw=true"
do
	local ATLAS_PATH = "BloomUI/icons.png"

	-- minimal base64 decoder (pure Luau)
	local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local b64idx = {}
	for i = 1, #B64 do b64idx[B64:sub(i,i)] = i - 1 end
	local function b64decode(data)
		data = data:gsub("[^A-Za-z0-9+/=]", "")
		local out = {}
		for i = 1, #data, 4 do
			local a = b64idx[data:sub(i,   i  )] or 0
			local b = b64idx[data:sub(i+1, i+1)] or 0
			local c = b64idx[data:sub(i+2, i+2)] or 0
			local d = b64idx[data:sub(i+3, i+3)] or 0
			local n = a * 262144 + b * 4096 + c * 64 + d
			table.insert(out, string.char(math.floor(n / 65536) % 256))
			if data:sub(i+2, i+2) ~= "=" then
				table.insert(out, string.char(math.floor(n / 256) % 256))
			end
			if data:sub(i+3, i+3) ~= "=" then
				table.insert(out, string.char(n % 256))
			end
		end
		return table.concat(out)
	end

	if makefolder and isfolder and not isfolder("BloomUI") then
		pcall(makefolder, "BloomUI")
	end

	local function applyAtlas()
		if not (isfile and isfile(ATLAS_PATH) and getcustomasset) then return end
		local ok, assetId = pcall(getcustomasset, ATLAS_PATH)
		if ok and assetId then
			Icons.Atlas = assetId
			pcall(ContentProvider.PreloadAsync, ContentProvider, { Icons.Atlas })
		end
	end

	if writefile and isfile and not isfile(ATLAS_PATH) then
		task.spawn(function()
			local ok, data = pcall(game.HttpGet, game, Bloom.AtlasUrl)
			if not (ok and data and #data > 0) then return end
			-- auto-detect: real PNG starts with \x89PNG magic bytes.
			-- anything else assumed base64 (gist text host workaround).
			if data:sub(1, 4) ~= "\137PNG" then
				data = b64decode(data)
			end
			pcall(writefile, ATLAS_PATH, data)
			applyAtlas()
		end)
	else
		applyAtlas()
	end
end

-- Bloom:SetPattern("rbxassetid://123", { TileSize = 256, Speed = 12, Parallax = 3, Alpha = 0.07 })
-- Pass "" to turn the pattern off. Applies live to every open window.
function Bloom:SetPattern(image, opts)
	local P = Bloom.Pattern
	if image ~= nil then P.Image = image end
	for k, v in opts or {} do P[k] = v end
	for _, owner in patterns do
		if type(owner) == "table" then owner:_applyPattern(false) end
	end
	if P.Image ~= "" then
		task.spawn(function()
			pcall(ContentProvider.PreloadAsync, ContentProvider, { P.Image })
		end)
	end
end

--------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------
local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				inst[k] = v
			end
		end
	end
	if children then
		for _, c in children do
			c.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent, r)
	local c = new("UICorner", { CornerRadius = UDim.new(0, math.round(r * (current.Radius or 5) / 5)), Parent = parent })
	corners[c] = r
	return c
end

local function stroke(parent, token, thick, transparency)
	local s = new("UIStroke", {
		Thickness = thick or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		Parent = parent,
	})
	paint(s, { Color = token })
	return s
end

local function padding(parent, t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t or 0), PaddingRight = UDim.new(0, r or t or 0),
		PaddingBottom = UDim.new(0, b or t or 0), PaddingLeft = UDim.new(0, l or r or t or 0),
		Parent = parent,
	})
end

local function list(parent, dir, gap, alignV, alignH)
	return new("UIListLayout", {
		FillDirection = dir or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = alignV or Enum.VerticalAlignment.Top,
		HorizontalAlignment = alignH or Enum.HorizontalAlignment.Left,
		Parent = parent,
	})
end

-- bloom style: chrome text is lowercase (values keep their case).
local function lc(s)
	return string.lower(tostring(s or ""))
end
local track = lc
Bloom.Lower = lc

local function frame(parent, props)
	props = props or {}
	props.BorderSizePixel = 0
	if props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 1
	end
	props.Parent = parent
	return new("Frame", props)
end

local function label(parent, txt, o)
	o = o or {}
	local l = new("TextLabel", {
		Name = o.Name or "Label",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = txt or "",
		TextSize = o.Size or 13,
		TextXAlignment = o.AlignX or Enum.TextXAlignment.Left,
		TextYAlignment = o.AlignY or Enum.TextYAlignment.Center,
		TextTruncate = o.Truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		TextWrapped = o.Wrap or false,
		RichText = o.Rich or false,
		AutomaticSize = o.Auto or Enum.AutomaticSize.None,
		Size = o.Dim or UDim2.fromScale(1, 1),
		Position = o.Pos or UDim2.new(),
		AnchorPoint = o.Anchor or Vector2.zero,
		LayoutOrder = o.Order or 0,
		ZIndex = o.Z or 1,
		Parent = parent,
	})
	paint(l, { TextColor3 = o.Color or "Text", FontFace = o.Font or "Body" })
	return l
end

local function chip(parent, txt, token, o)
	o = o or {}
	local c = new("TextLabel", {
		Name = "Chip",
		BackgroundTransparency = 1,
		Text = lc(txt),
		TextSize = 10,
		AutomaticSize = o.Fixed and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(o.Fixed or 0, 16),
		Position = o.Pos or UDim2.new(),
		AnchorPoint = o.Anchor or Vector2.zero,
		LayoutOrder = o.Order or 0,
		Parent = parent,
	})
	paint(c, { TextColor3 = token, FontFace = "MonoBold" })
	padding(c, 0, 5, 0, 5)
	corner(c, 3)
	local s = new("UIStroke", { Thickness = 1, Transparency = 0.3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = c })
	paint(s, { Color = token })
	return c
end

local function icon(parent, name, size, token, o)
	o = o or {}
	local img = new("ImageLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = o.Pos or UDim2.new(),
		AnchorPoint = o.Anchor or Vector2.zero,
		ScaleType = Enum.ScaleType.Fit,
		LayoutOrder = o.Order or 0,
		ZIndex = o.Z or 1,
		Parent = parent,
	})
	paint(img, { ImageColor3 = token })
	-- fallback glyph when no atlas is registered: a small outlined diamond
	local fb = frame(img, {
		Name = "Fallback", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.36, 0.36), Rotation = 0, Visible = false,
	})
	local fs = new("UIStroke", { Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = fb })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fb })
	paint(fs, { Color = token })
	Icons.Apply(img, name)
	return img
end

function Bloom.Icon(name, opts)
	opts = opts or {}
	local img = icon(opts.Parent, name, opts.Size or 16, opts.Color or "Text")
	return img
end

-- Five-petal blossom built from pill-shaped frames (the bloom mark).
function Bloom.Flower(parent, size, o)
	o = o or {}
	local holder = frame(parent, { Name = "Flower", Size = UDim2.fromOffset(size, size), AnchorPoint = o.Anchor or Vector2.zero, Position = o.Pos or UDim2.new(), LayoutOrder = o.Order or 0 })
	local spin = frame(holder, { Name = "Spin", Size = UDim2.fromScale(1, 1) })
	local n = o.Petals or 5
	local petals, sizes = {}, {}
	for i = 1, n do
		local a = (i - 1) / n * math.pi * 2
		local r = size * 0.22
		local full = UDim2.fromOffset(math.round(size * 0.36), math.round(size * 0.54))
		local p = frame(spin, {
			Name = "Petal", Size = full, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.sin(a) * r, 0.5, -math.cos(a) * r),
			Rotation = math.deg(a), BackgroundTransparency = 0.2, ZIndex = 2,
		})
		paint(p, { BackgroundColor3 = (i % 2 == 0) and "Glow2" or "Glow1" })
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = p })
		petals[i], sizes[i] = p, full
	end
	local core = frame(holder, {
		Name = "Core", Size = UDim2.fromOffset(math.round(size * 0.24), math.round(size * 0.24)),
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 0, ZIndex = 3,
	})
	paint(core, { BackgroundColor3 = "Window" })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = core })
	local api = { Holder = holder, Spin = spin, Petals = petals, Core = core }
	-- petals grow out one by one while the flower unwinds
	function api.Bloom(delay)
		spin.Rotation = -72
		for i, p in petals do
			p.Size = UDim2.fromOffset(0, 0)
			task.delay((delay or 0) + (i - 1) * 0.05, function()
				tween(p, Motion.Knob, { Size = sizes[i] })
			end)
		end
		tween(spin, TweenInfo.new(0.9, ES.Quint, ED.Out), { Rotation = 0 })
	end
	return api
end

local function shake(obj)
	task.spawn(function()
		local base = obj.Position
		for _, dx in { 4, -4, 3, -2, 1, 0 } do
			tween(obj, TweenInfo.new(0.04, ES.Sine, ED.Out), { Position = base + UDim2.fromOffset(dx, 0) })
			task.wait(0.04)
		end
		obj.Position = base
	end)
end

-- Field = slot frame containing a focus ring (behind) and the box (front).
local function field(parent, o)
	o = o or {}
	local outer = frame(parent, {
		Name = o.Name or "Field",
		Size = o.Size or UDim2.new(1, 0, 0, 30),
		Position = o.Pos or UDim2.new(0, 0, 0.5, 0),
		AnchorPoint = o.Anchor or Vector2.new(0, 0.5),
		LayoutOrder = o.Order or 0,
	})
	local ring = frame(outer, { Name = "Ring", Size = UDim2.new(1, 6, 1, 6), Position = UDim2.fromOffset(-3, -3), ZIndex = 1 })
	paint(ring, { BackgroundColor3 = "Accent" })
	corner(ring, 8)
	local box = frame(outer, { Name = "Box", Size = UDim2.fromScale(1, 1), BackgroundTransparency = o.Ghost and 1 or 0, ZIndex = 2 })
	paint(box, { BackgroundColor3 = o.Bg or "Surface" })
	corner(box, 5)
	local st = stroke(box, "Stroke")
	if o.Dashed then st.Transparency = 0.2 end

	local api = { Outer = outer, Box = box, Stroke = st, Ring = ring, hover = false, focus = false, bad = false }
	function api.refresh()
		local tok = api.bad and "Bad" or (api.focus and "Accent" or (api.hover and "StrokeStrong" or "Stroke"))
		recolor(st, "Color", tok, Motion.Hover)
		recolor(ring, "BackgroundColor3", api.bad and "Bad" or "Accent")
		tween(ring, api.focus and Motion.Hover or Motion.HoverOut, { BackgroundTransparency = (api.focus or api.bad) and 0.86 or 1 })
	end
	function api.setBad(b)
		if b and not api.bad then shake(outer) end
		api.bad = b
		api.refresh()
	end
	box.MouseEnter:Connect(function() api.hover = true; api.refresh() end)
	box.MouseLeave:Connect(function() api.hover = false; api.refresh() end)
	return api
end

local function textbox(parent, o)
	o = o or {}
	local tb = new("TextBox", {
		Name = o.Name or "Input",
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Text = o.Text or "",
		PlaceholderText = o.Placeholder or "",
		TextSize = o.Size or 13,
		TextXAlignment = o.AlignX or Enum.TextXAlignment.Left,
		Size = o.Dim or UDim2.new(1, -20, 1, 0),
		Position = o.Pos or UDim2.fromOffset(10, 0),
		ClipsDescendants = true,
		ZIndex = 3,
		Parent = parent,
	})
	paint(tb, { TextColor3 = o.Color or "Text", PlaceholderColor3 = "TextFaint", FontFace = o.Font or "Mono" })
	return tb
end

-- Wire a TextBox to a field's focus state.
local function bindFocus(f, tb)
	tb.Focused:Connect(function() f.focus = true; f.refresh() end)
	tb.FocusLost:Connect(function() f.focus = false; f.refresh() end)
end

local function button(parent, txt, o)
	o = o or {}
	local kind = o.Kind or "ghost" -- ghost | primary | danger
	local b = new("TextButton", {
		Name = o.Name or "Button",
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		BackgroundTransparency = kind == "primary" and 0 or 1,
		Size = o.Size or UDim2.fromOffset(96, 32),
		Position = o.Pos or UDim2.new(),
		AnchorPoint = o.Anchor or Vector2.zero,
		LayoutOrder = o.Order or 0,
		ZIndex = o.Z or 1,
		Parent = parent,
	})
	paint(b, { BackgroundColor3 = kind == "primary" and "Accent" or "Raised" })
	corner(b, 5)
	local st = stroke(b, kind == "primary" and "Accent" or (kind == "danger" and "Bad" or "StrokeStrong"), 1, kind == "danger" and 0.5 or 0)
	local sc = new("UIScale", { Parent = b })
	local txtTok = kind == "primary" and "AccentInk" or (kind == "danger" and "Bad" or "Text")
	local l = label(b, lc(txt), { Size = 13, Font = "BodyBold", Color = txtTok, AlignX = o.AlignX or Enum.TextXAlignment.Center, Z = 2 })
	if o.AlignX == Enum.TextXAlignment.Left then padding(l, 0, 12, 0, 12) end
	local hint
	if o.Hint then
		hint = label(b, o.Hint, { Size = 11, Font = "Mono", Color = kind == "primary" and "AccentInk" or "TextFaint", AlignX = Enum.TextXAlignment.Right, Z = 2 })
		padding(hint, 0, 12, 0, 12)
	end
	b.MouseEnter:Connect(function()
		if kind == "primary" then
			tween(b, Motion.Hover, { BackgroundColor3 = current.Accent:Lerp(Color3.new(1, 1, 1), 0.12) })
		elseif kind == "danger" then
			recolor(b, "BackgroundColor3", "Bad")
			tween(b, Motion.Hover, { BackgroundTransparency = 0.88 })
		else
			tween(b, Motion.Hover, { BackgroundTransparency = 0 })
		end
	end)
	b.MouseLeave:Connect(function()
		if kind == "primary" then
			recolor(b, "BackgroundColor3", "Accent", Motion.HoverOut)
		else
			tween(b, Motion.HoverOut, { BackgroundTransparency = 1 })
		end
		tween(sc, Motion.HoverOut, { Scale = 1 })
	end)
	b.MouseButton1Down:Connect(function() tween(sc, Motion.Hover, { Scale = 0.97 }) end)
	b.MouseButton1Up:Connect(function() tween(sc, Motion.Knob, { Scale = 1 }) end)
	return b, l, hint
end

local function iconButton(parent, name, o)
	o = o or {}
	local b = new("TextButton", {
		Name = o.Name or "IconButton", AutoButtonColor = false, Text = "", BorderSizePixel = 0,
		BackgroundTransparency = 1, Size = UDim2.fromOffset(o.Size or 30, o.Size or 30),
		Position = o.Pos or UDim2.new(), AnchorPoint = o.Anchor or Vector2.zero, LayoutOrder = o.Order or 0,
		ZIndex = o.Z or 3, Parent = parent,
	})
	paint(b, { BackgroundColor3 = "Raised" })
	corner(b, 5)
	local z = (o.Z or 3) + 1
	local ic, glyph
	if name == "x" or name == "minus" then
		-- drawn glyphs: window chrome must not depend on the icon atlas
		local gs = math.round((o.IconSize or 16) * 0.75)
		glyph = {}
		local holder = frame(b, { Size = UDim2.fromOffset(gs, gs), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = z })
		local rots = name == "x" and { 45, -45 } or { 90 }
		for _, r in rots do
			local bar = frame(holder, { Size = UDim2.new(0, 1.5, 1, name == "x" and 2 or 0), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Rotation = r, BackgroundTransparency = 0, ZIndex = z + 1 })
			paint(bar, { BackgroundColor3 = o.Color or "TextDim" })
			glyph[#glyph + 1] = bar
		end
	else
		ic = icon(b, name, o.IconSize or 16, o.Color or "TextDim", { Anchor = Vector2.new(0.5, 0.5), Pos = UDim2.fromScale(0.5, 0.5), Z = z })
	end
	local function tint(tok, info)
		if ic then recolor(ic, "ImageColor3", tok, info) end
		if glyph then for _, g in glyph do recolor(g, "BackgroundColor3", tok, info) end end
	end
	b.MouseEnter:Connect(function()
		tween(b, Motion.Hover, { BackgroundTransparency = 0 })
		tint(o.HoverColor or "Text", Motion.Hover)
	end)
	b.MouseLeave:Connect(function()
		tween(b, Motion.HoverOut, { BackgroundTransparency = 1 })
		tint(o.Color or "TextDim", Motion.HoverOut)
	end)
	return b, ic
end

local function fmt(n, dec)
	dec = dec or 2
	if dec <= 0 then return tostring(math.round(n)) end
	if math.abs(n) < 0.5 * 10 ^ -dec then n = 0 end
	return string.format("%." .. dec .. "f", n)
end

-- compact number: integers without decimals, otherwise up to `dec`, trailing zeros trimmed
local function short(n, dec)
	if n == math.floor(n) then return tostring(math.floor(n)) end
	local s = string.format("%." .. (dec or 2) .. "f", n)
	s = string.gsub(string.gsub(s, "0+$", ""), "%.$", "")
	return s
end

local function snap(v, step, min)
	if not step or step <= 0 then return v end
	return math.round((v - (min or 0)) / step) * step + (min or 0)
end

--------------------------------------------------------------------------
-- Strings (override for localisation)
--------------------------------------------------------------------------
Bloom.Strings = {
	Search = "find a setting…",
	Status = "server live",
	PressKey = "press a key…",
	Cancel = "cancel",
	Unbound = "none",
	Pick = "pick",
	Picking = "click a part…",
	Empty = "nil",
	Filter = "filter…",
	KeyTaken = "already used by ",
}

--------------------------------------------------------------------------
-- Window / Tab / Section / Control
--------------------------------------------------------------------------
local Window = {}
Window.__index = Window
local Tab = {}
Tab.__index = Tab
local Section = {}
Section.__index = Section
local Control = {}
Control.__index = Control

Bloom.Window, Bloom.Tab, Bloom.Section, Bloom.Control = Window, Tab, Section, Control

local X_AUTO = Enum.AutomaticSize.X
local Y_AUTO = Enum.AutomaticSize.Y
local ALIGN_R = Enum.TextXAlignment.Right
local ALIGN_C = Enum.TextXAlignment.Center
local HORIZ = Enum.FillDirection.Horizontal
local V_CENTER = Enum.VerticalAlignment.Center

local function conn(self, sig, fn)
	local c = sig:Connect(fn)
	table.insert(self._conns, c)
	return c
end

local function isPointer(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

local shared -- the single window every script shares

local function chevronGlyph(parent, token, o)
	o = o or {}
	local ch = frame(parent, { Name = "Chevron", Size = UDim2.fromOffset(14, 14), Position = o.Pos or UDim2.new(), AnchorPoint = o.Anchor or Vector2.zero, ZIndex = o.Z or 3, Rotation = o.Rotation or 0 })
	for i, spec in { { 4.6, -45 }, { 9.4, 45 } } do
		local bar = frame(ch, { Size = UDim2.fromOffset(2, 7), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(spec[1], 6.4), Rotation = spec[2], BackgroundTransparency = 0, ZIndex = (o.Z or 3) + 1 })
		paint(bar, { BackgroundColor3 = token })
	end
	return ch
end

local function uiShadow(parent, o)
	o = o or {}
	local s = new("UIShadow", {
		BlurRadius = UDim.new(0, o.Blur or 24),
		Offset = UDim2.fromOffset(0, o.Y or 0),
		Spread = UDim2.fromOffset(o.Spread or 0, o.Spread or 0),
		Transparency = o.Transparency or 0.5,
		Parent = parent,
	})
	paint(s, { Color = o.Token or "Shadow" })
	return s
end
Bloom.Shadow = uiShadow

-- Bloom:Init(opts) creates the shared window (or updates it). Every later call,
-- Bloom:GetWindow() and Bloom:Module() reuse the same window.
function Bloom:Init(opts)
	if shared and not shared._destroyed then
		shared:_apply(opts or {})
		return shared
	end
	shared = Window._new(opts or {})
	return shared
end

function Bloom:CreateWindow(opts)
	return Bloom:Init(opts)
end

function Bloom:GetWindow()
	if shared and not shared._destroyed then return shared end
	return Bloom:Init({})
end

function Window:_apply(opts)
	if opts.Title then self.Title = opts.Title end
	if opts.Theme then Bloom:SetTheme(opts.Theme) end
	if opts.ToggleKey then self.ToggleKey = opts.ToggleKey end
	if opts.Size then self:SetSize(opts.Size) end
end

function Window:SetTitle(t)
	self:_apply({ Title = t })
end

function Window._new(opts)
	local self = setmetatable({}, Window)
	self.Flags = {}
	self.Tabs = {}
	self.Keybinds = {}
	self.Modules = {}
	self._groups = {}
	self._conns = {}
	self.Visible = false
	self.ToggleKey = opts.ToggleKey or Enum.KeyCode.RightShift
	self.Size = opts.Size or Vector2.new(620, 420)
	self.MinSize = opts.MinSize or Vector2.new(440, 300)
	self._wantSize = self.Size
	self._targetSize = self.Size
	self._shownSize = self.Size
	self._compactAt = opts.CompactWidth or 560
	self.Title = opts.Title or "bloom"
	self.Shown = Signal.new()
	self.Hidden = Signal.new()
	self.ModulesChanged = Signal.new()
	self.AnyControlChanged = Signal.new()  -- fires on every Control:_emit
	local size = self.Size
	local S = Bloom.Strings

	if opts.Theme then
		Bloom:SetTheme(opts.Theme, { Tween = 0 })
	end

	local gui = new("ScreenGui", {
		Name = opts.Name or "Bloom",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = opts.DisplayOrder or 999,
		Parent = opts.Parent,  -- set below with executor-safe resolution
	})
	-- exploit-safe parent resolution: hidden gui > CoreGui > PlayerGui fallback
	if not gui.Parent then
		local target
		if gethui then
			local ok, h = pcall(gethui); if ok then target = h end
		end
		if not target then
			local ok, c = pcall(function() return game:GetService("CoreGui") end)
			if ok and c then target = c end
		end
		if not target then target = LocalPlayer:WaitForChild("PlayerGui") end
		pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
		pcall(function() if protect_gui then protect_gui(gui) end end)
		gui.Parent = target
	end
	self.Gui = gui

	local dim = frame(gui, { Name = "Dim", Size = UDim2.fromScale(1, 1), Visible = false })
	paint(dim, { BackgroundColor3 = "Shadow" })
	self._dim = dim
	self._useDim = opts.Dim ~= false

	local holder = frame(gui, {
		Name = "Holder", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size.X, size.Y), Visible = false,
	})
	self.Holder = holder
	local fit = new("UIScale", { Parent = holder })
	self._fit = fit
	local function refit()
		local cam = Workspace.CurrentCamera
		if not cam then return end
		local vp = cam.ViewportSize
		if vp.X < 200 or vp.Y < 200 then return end
		fit.Scale = math.clamp(math.min((vp.X - 24) / self.MinSize.X, (vp.Y - 24) / self.MinSize.Y, 1), 0.45, 1)
		self._targetSize = self:_clampSize(self._wantSize)
		if self._budTarget then self._budTarget = self:_clampBud(self._budTarget) end
	end
	refit()
	if Workspace.CurrentCamera then
		conn(self, Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), refit)
	end

	---------------------------------------------------------------- window surface
	-- One animated "stage" holds three layers: the backdrop group (fill, pattern,
	-- shadows), the content group, and the border frame. Pattern drift and the
	-- spinning border live outside the content CanvasGroup, so it only re-renders
	-- when its own content changes.
	local stage = frame(holder, { Name = "Stage", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 1 })
	self._stage = stage
	self._wscale = new("UIScale", { Scale = 0.96, Parent = stage })

	local back = new("CanvasGroup", { Name = "Backdrop", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, GroupTransparency = 1, ZIndex = 0, Parent = stage })
	paint(back, { BackgroundColor3 = "Window" })
	corner(back, 9)
	self._back = back
	self._shadowUI = uiShadow(back, { Blur = 36, Y = 16, Transparency = 1 })
	self._glowUI = uiShadow(back, { Blur = 42, Token = "Glow1", Transparency = 1 })

	local win = new("CanvasGroup", { Name = "Window", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, BackgroundTransparency = 1, GroupTransparency = 1, ZIndex = 1, Parent = stage })
	corner(win, 9)
	self._win = win

	local B = Bloom.Border
	local grads = {}
	local function paintGrad(g)
		local g1 = current.Glow1 or current.Accent
		local g2 = current.Glow2 or current.Accent
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, g1),
			ColorSequenceKeypoint.new(0.5, g2),
			ColorSequenceKeypoint.new(1, g1),
		})
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.25, 0.5),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(0.75, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		})
	end
	local function gradStroke(parent, thick, inner)
		local s = new("UIStroke", {
			Thickness = thick, Color = Color3.new(1, 1, 1), ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = inner and Enum.BorderStrokePosition.Inner or Enum.BorderStrokePosition.Center,
			Parent = parent,
		})
		local g = new("UIGradient", { Parent = s })
		paintGrad(g)
		table.insert(grads, g)
		return s, g
	end
	local borderF = frame(stage, { Name = "Border", Size = UDim2.fromScale(1, 1), ZIndex = 2 })
	corner(borderF, 9)
	if B.Enabled ~= false then
		self._border = gradStroke(borderF, B.Thickness or 1.5, true)
	else
		self._border = stroke(borderF, "Stroke")
	end
	self._border.Transparency = 1
	conn(self, Bloom.ThemeChanged, function()
		for _, g in grads do paintGrad(g) end
	end)

	local P = Bloom.Pattern
	local pat = new("ImageLabel", {
		Name = "Pattern", BackgroundTransparency = 1, BorderSizePixel = 0,
		Image = P.Image, ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.fromOffset(P.TileSize, P.TileSize),
		ImageTransparency = patternTransparency(), Visible = P.Image ~= "",
		Size = UDim2.new(1, P.TileSize * 2, 1, P.TileSize * 2), Position = UDim2.fromOffset(-P.TileSize, -P.TileSize),
		ZIndex = 1, Parent = back,
	})
	paint(pat, { ImageColor3 = "PatternTint" })
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.45, 0.15),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = pat,
	})
	patterns[pat] = self
	self._pattern = pat
	self._patPhase = 0
	self._par = Vector2.zero
	self._patPos = Vector2.zero

	self._marks = {}
	for _, mk in (opts.Marks and { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } or {}) do
		local ax, ay = mk[1], mk[2]
		local f = frame(holder, { Name = "Mark", Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(ax, ay), ZIndex = 2 })
		local h = frame(f, { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, ay), AnchorPoint = Vector2.new(0, ay) })
		local v = frame(f, { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.fromScale(ax, 0), AnchorPoint = Vector2.new(ax, 0) })
		paint(h, { BackgroundColor3 = "Accent" })
		paint(v, { BackgroundColor3 = "Accent" })
		local rec = { f = f, h = h, v = v, ax = ax, ay = ay, dx = ax == 0 and -1 or 1, dy = ay == 0 and -1 or 1 }
		f.Position = UDim2.new(ax, rec.dx * 9, ay, rec.dy * 9)
		table.insert(self._marks, rec)
	end

	---------------------------------------------------------------- title bar
	local bar = frame(win, { Name = "TitleBar", Size = UDim2.new(1, 0, 0, 50), Active = true })
	local barLine = frame(bar, { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1), BackgroundTransparency = 0 })
	paint(barLine, { BackgroundColor3 = "Stroke" })

	local brand = frame(bar, { Name = "Brand", Size = UDim2.new(0, 260, 1, 0), Position = UDim2.fromOffset(16, 0) })
	list(brand, HORIZ, 10, V_CENTER)
	self._flower = Bloom.Flower(brand, 22, { Order = 1 })
	self._logo = self._flower.Holder
	-- fixed brand: "bloom" + "ui lib // by exavolt"; page names come from modules
	self._brandLabel = label(brand, "bloom", { Size = 18, Font = "Display", Auto = X_AUTO, Dim = UDim2.new(0, 0, 0, 22), Order = 2 })
	self._brandSub = label(brand, "ui lib // by exavolt", { Size = 13, Font = "Mono", Color = "TextFaint", Auto = X_AUTO, Dim = UDim2.new(0, 0, 0, 20), Order = 3 })

	local sf = field(bar, { Size = UDim2.new(0.36, 0, 0, 32), Pos = UDim2.new(1, -50, 0.5, 0), Anchor = Vector2.new(1, 0.5) })
	new("UISizeConstraint", { MinSize = Vector2.new(120, 32), MaxSize = Vector2.new(300, 32), Parent = sf.Outer })
	icon(sf.Box, "search", 15, "TextFaint", { Pos = UDim2.new(0, 11, 0.5, 0), Anchor = Vector2.new(0, 0.5), Z = 3 })
	local search = textbox(sf.Box, { Placeholder = opts.SearchPlaceholder or S.Search, Font = "Body", Pos = UDim2.fromOffset(34, 0), Dim = UDim2.new(1, -96, 1, 0) })
	bindFocus(sf, search)
	local kbd = label(sf.Box, "ctrl k", {
		Size = 11, Font = "Mono", Color = "TextFaint", Auto = X_AUTO, Dim = UDim2.fromOffset(0, 18),
		Pos = UDim2.new(1, -8, 0.5, 0), Anchor = Vector2.new(1, 0.5), Z = 3,
	})
	padding(kbd, 0, 5, 0, 5)
	corner(kbd, 3)
	stroke(kbd, "StrokeStrong")
	self._search = search
	self._kbd = kbd

	local rightBox = frame(bar, { Size = UDim2.new(0, 40, 1, 0), Position = UDim2.new(1, -8, 0, 0), AnchorPoint = Vector2.new(1, 0) })
	list(rightBox, HORIZ, 4, V_CENTER, Enum.HorizontalAlignment.Right)

	local closeB = iconButton(rightBox, "x", { Order = 3, HoverColor = "Bad" })

	---------------------------------------------------------------- body
	local body = frame(win, { Name = "Body", Size = UDim2.new(1, 0, 1, -50), Position = UDim2.fromOffset(0, 50) })
	local side = frame(body, { Name = "Sidebar", Size = UDim2.new(0, 176, 1, 0) })
	local sideLine = frame(body, { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.fromOffset(176, 0), BackgroundTransparency = 0 })
	paint(sideLine, { BackgroundColor3 = "Stroke" })
	self._side, self._sideLine = side, sideLine

	local nav = new("ScrollingFrame", {
		Name = "Nav", Size = UDim2.new(1, 0, 1, -74), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 2, ScrollBarImageTransparency = 0.2, CanvasSize = UDim2.new(), AutomaticCanvasSize = Y_AUTO,
		ScrollingDirection = Enum.ScrollingDirection.Y, VerticalScrollBarInset = Enum.ScrollBarInset.None, Parent = side,
	})
	paint(nav, { ScrollBarImageColor3 = "StrokeStrong" })
	self._navPad = padding(nav, 8, 12, 12, 12)
	list(nav, nil, 2)
	self._nav = nav

	local foot = frame(side, { Name = "Footer", Size = UDim2.new(1, -28, 0, 62), Position = UDim2.new(0, 14, 1, -10), AnchorPoint = Vector2.new(0, 1) })
	self._foot = foot
	local footLine = frame(foot, { Size = UDim2.new(1, 0, 0, 1), BackgroundTransparency = 0 })
	paint(footLine, { BackgroundColor3 = "Stroke" })
	local r1 = frame(foot, { Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 14) })
	local live = frame(r1, { Size = UDim2.fromOffset(7, 7), Position = UDim2.new(0, 4, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 0 })
	paint(live, { BackgroundColor3 = "Ok" })
	corner(live, 4)
	tween(live, TweenInfo.new(1.1, ES.Sine, ED.InOut, -1, true), { BackgroundTransparency = 0.6 })
	label(r1, opts.StatusText or S.Status, { Size = 13, Color = "TextDim", Pos = UDim2.fromOffset(18, 0), Dim = UDim2.new(1, -18, 1, 0) })
	local pc = label(r1, "", { Size = 12, Font = "Mono", Color = "TextFaint", AlignX = ALIGN_R, Dim = UDim2.new(1, -4, 1, 0) })
	local r2 = frame(foot, { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 38) })
	local pingL = label(r2, "", { Size = 12, Font = "Mono", Color = "TextFaint", Pos = UDim2.fromOffset(4, 0), Dim = UDim2.new(0.5, 0, 1, 0) })
	local fpsL = label(r2, "", { Size = 12, Font = "Mono", Color = "TextFaint", AlignX = ALIGN_R, Dim = UDim2.new(1, -4, 1, 0) })
	self.Stats = { Fps = 60, Ping = 0 }
	local acc, frames = 0.5, 0
	conn(self, RunService.RenderStepped, function(dt)
		acc += dt
		frames += 1
		if acc >= 0.5 then
			self.Stats.Fps = math.round(frames / acc)
			local ok, p = pcall(function() return LocalPlayer:GetNetworkPing() end)
			self.Stats.Ping = ok and math.round(p * 1000) or nil
			if self.Visible then
				fpsL.Text = string.format("%d fps", self.Stats.Fps)
				pc.Text = string.format("%d/%d", #Players:GetPlayers(), Players.MaxPlayers)
				pingL.Text = self.Stats.Ping and string.format("ping %dms", self.Stats.Ping) or "ping \u{2014}"
			end
			acc, frames = 0, 0
		end
	end)

	local main = frame(body, { Name = "Main", Size = UDim2.new(1, -177, 1, 0), Position = UDim2.fromOffset(177, 0) })
	self._main = main
	local head = frame(main, { Name = "Header", Size = UDim2.new(1, 0, 0, 76) })
	local headLine = frame(head, { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1), BackgroundTransparency = 0 })
	paint(headLine, { BackgroundColor3 = "Stroke" })
	self._crumb = label(head, "", { Size = 13, Font = "Display", Color = "TextFaint", Pos = UDim2.fromOffset(24, 14), Dim = UDim2.new(1, -48, 0, 16), Truncate = true })
	self._title = label(head, "", { Size = 25, Font = "Display", Pos = UDim2.fromOffset(24, 33), Dim = UDim2.new(1, -48, 0, 28), Truncate = true })
	local headRight = frame(head, { Name = "Actions", Size = UDim2.new(0, 460, 0, 32), Position = UDim2.new(1, -24, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5) })
	self._actionsList = list(headRight, HORIZ, 8, V_CENTER, Enum.HorizontalAlignment.Right)
	self._actions = headRight

	local content = frame(main, { Name = "Content", Size = UDim2.new(1, 0, 1, -76), Position = UDim2.fromOffset(0, 76), ClipsDescendants = true })
	self._content = content
	local veil = frame(content, { Name = "Veil", Size = UDim2.fromScale(1, 1), ZIndex = 20, Visible = false })
	paint(veil, { BackgroundColor3 = "Window" })
	self._veil = veil

	self._overlay = frame(win, { Name = "Overlay", Size = UDim2.fromScale(1, 1), ZIndex = 50 })

	local toasts = frame(gui, { Name = "Toasts", Size = UDim2.fromOffset(330, 600), Position = UDim2.new(1, -24, 1, -24), AnchorPoint = Vector2.new(1, 1), ZIndex = 200 })
	list(toasts, nil, 0, Enum.VerticalAlignment.Bottom, Enum.HorizontalAlignment.Right)
	self._toasts = toasts

	---------------------------------------------------------------- the bloom button (bud)
	local bud = new("TextButton", {
		Name = "Bud", Text = "", AutoButtonColor = false, BorderSizePixel = 0,
		Size = UDim2.fromOffset(52, 52), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 100, Parent = gui,
	})
	paint(bud, { BackgroundColor3 = "Window" })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = bud })
	gradStroke(bud, 1.5, false)
	uiShadow(bud, { Blur = 18, Y = 6, Transparency = 0.4 })
	self._budGlow = uiShadow(bud, { Blur = 22, Token = "Glow1", Transparency = 0.78 })
	local budScale = new("UIScale", { Parent = bud })
	self._budFlower = Bloom.Flower(bud, 28, { Anchor = Vector2.new(0.5, 0.5), Pos = UDim2.fromScale(0.5, 0.5) })
	self._bud, self._budScale = bud, budScale
	do
		local cam = Workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		if vp.Y < 200 then vp = Vector2.new(1280, 720) end
		local start = opts.ButtonPosition or Vector2.new(56, vp.Y - 56)
		self._budTarget = start
		self._budPos = start
		bud.Position = UDim2.fromOffset(start.X, start.Y)
	end
	local budHover, bPress, bDrag, bStart, bOrig = false, false, false, nil, nil
	bud.MouseEnter:Connect(function()
		budHover = true
		if not bPress then tween(budScale, Motion.Hover, { Scale = 1.07 }) end
		tween(self._budGlow, Motion.Hover, { Transparency = 0.55 })
	end)
	bud.MouseLeave:Connect(function()
		budHover = false
		if not bPress then tween(budScale, Motion.HoverOut, { Scale = 1 }) end
		tween(self._budGlow, Motion.HoverOut, { Transparency = 0.78 })
	end)
	bud.InputBegan:Connect(function(input)
		if isPointer(input) then
			bPress, bDrag = true, false
			bStart = Vector2.new(input.Position.X, input.Position.Y)
			bOrig = self._budTarget
			tween(budScale, Motion.Hover, { Scale = 0.9 })
		end
	end)
	conn(self, UserInputService.InputChanged, function(input)
		if bPress and isMove(input) then
			local d = Vector2.new(input.Position.X, input.Position.Y) - bStart
			if not bDrag and d.Magnitude > 6 then bDrag = true end
			if bDrag then self._budTarget = self:_clampBud(bOrig + d) end
		end
	end)
	conn(self, UserInputService.InputEnded, function(input)
		if bPress and isPointer(input) then
			bPress = false
			tween(budScale, Motion.Knob, { Scale = budHover and 1.07 or 1 })
			if not bDrag then self:Toggle() end
		end
	end)

	---------------------------------------------------------------- drag (smoothed) + per-frame motion
	local dragging, dragStart, startOff = false, nil, nil
	local target = Vector2.zero
	self._offset = Vector2.zero
	conn(self, bar.InputBegan, function(input)
		if isPointer(input) then
			dragging = true
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			startOff = target
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					c:Disconnect()
				end
			end)
		end
	end)
	conn(self, UserInputService.InputChanged, function(input)
		if dragging and isMove(input) then
			target = startOff + (Vector2.new(input.Position.X, input.Position.Y) - dragStart)
		end
	end)
	conn(self, RunService.RenderStepped, function(dt)
		local k = 1 - math.exp(-dt * 24)
		local cur = self._offset
		if (cur - target).Magnitude > 0.05 then
			cur = cur:Lerp(target, k)
			self._offset = cur
			holder.Position = UDim2.new(0.5, cur.X, 0.5, cur.Y)
		end
		local goal = Vector2.new(self._targetSize.X, self._min and 50 or self._targetSize.Y)
		local shown = self._shownSize
		if (shown - goal).Magnitude > 0.05 then
			local nxt = shown:Lerp(goal, k)
			if (nxt - goal).Magnitude < 0.3 then nxt = goal end
			self._shownSize = nxt
			holder.Size = UDim2.fromOffset(math.round(nxt.X), math.round(nxt.Y))
			if math.abs(math.round(nxt.X) - (self._laidW or -1)) >= 1 then self:_relayout() end
		end
		self.Size = self._targetSize
		-- bud follows its target with a softer spring
		local bp = self._budPos
		if (bp - self._budTarget).Magnitude > 0.05 then
			bp = bp:Lerp(self._budTarget, 1 - math.exp(-dt * 18))
			self._budPos = bp
			bud.Position = UDim2.fromOffset(bp.X, bp.Y)
		end
		local bfh = self._budFlower.Holder
		bfh.Rotation = (bfh.Rotation + (budHover and 70 or 14) * dt) % 360
		if Bloom.Border.Animated ~= false then
			local r = (Bloom.Border.Speed or 40) * dt
			for _, g in grads do g.Rotation = (g.Rotation + r) % 360 end
		end
		if pat.Visible and self.Visible then
			local cfg = self._patCfg or Bloom.Pattern
			local T = cfg.TileSize or 256
			self._patPhase = (self._patPhase + (cfg.Speed or 0) * dt) % T
			local par = cfg.Parallax or 0
			local want = Vector2.zero
			if par > 0 then
				local mpos = UserInputService:GetMouseLocation()
				local hs = holder.AbsoluteSize
				local c = holder.AbsolutePosition + hs / 2
				want = Vector2.new(
					math.clamp((mpos.X - c.X) / math.max(1, hs.X), -0.5, 0.5),
					math.clamp((mpos.Y - c.Y) / math.max(1, hs.Y), -0.5, 0.5)
				) * (-2 * par)
			end
			self._par = self._par:Lerp(want, 1 - math.exp(-dt * 4))
			local np = Vector2.new(-T + self._patPhase + self._par.X, -T + self._par.Y)
			if (np - self._patPos).Magnitude > 0.02 then
				self._patPos = np
				pat.Position = UDim2.fromOffset(np.X, np.Y)
			end
		end
	end)

	---------------------------------------------------------------- resize
	local grip = new("TextButton", { Name = "Resize", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(20, 20), Position = UDim2.fromScale(1, 1), AnchorPoint = Vector2.new(1, 1), ZIndex = 45, Parent = win })
	local gripLines = {}
	for i, spec in { { 10, 11.5 }, { 5, 14.5 } } do
		local l = frame(grip, { Size = UDim2.fromOffset(1.5, spec[1]), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(spec[2], spec[2]), Rotation = 45, BackgroundTransparency = 0, ZIndex = 46 })
		paint(l, { BackgroundColor3 = "TextFaint" })
		gripLines[i] = l
	end
	local edgeR = new("TextButton", { Name = "EdgeR", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(0, 5, 1, -70), Position = UDim2.new(1, 0, 0, 50), AnchorPoint = Vector2.new(1, 0), ZIndex = 44, Parent = win })
	local edgeB = new("TextButton", { Name = "EdgeB", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, -20, 0, 5), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1), ZIndex = 44, Parent = win })
	local function edgeGlow(btn, vertical)
		local line = frame(btn, { Size = vertical and UDim2.new(0, 1, 1, 0) or UDim2.new(1, 0, 0, 1), Position = vertical and UDim2.new(1, -1, 0, 0) or UDim2.new(0, 0, 1, -1), ZIndex = 45 })
		paint(line, { BackgroundColor3 = "Accent" })
		return line
	end
	local rLine, bLine = edgeGlow(edgeR, true), edgeGlow(edgeB, false)
	local resizing, rStart, rSize, rOff = nil, nil, nil, nil
	local function resizeHover(mode, on)
		if resizing then return end
		if mode ~= "b" then tween(rLine, Motion.Hover, { BackgroundTransparency = on and 0.35 or 1 }) end
		if mode ~= "r" then tween(bLine, Motion.Hover, { BackgroundTransparency = on and 0.35 or 1 }) end
		if mode == "rb" then
			for _, l in gripLines do recolor(l, "BackgroundColor3", on and "Accent" or "TextFaint", Motion.Hover) end
		end
	end
	for mode, btn in { r = edgeR, b = edgeB, rb = grip } do
		btn.MouseEnter:Connect(function() resizeHover(mode, true) end)
		btn.MouseLeave:Connect(function() resizeHover(mode, false) end)
		btn.InputBegan:Connect(function(input)
			if isPointer(input) and not self._min then
				resizing = mode
				rStart = Vector2.new(input.Position.X, input.Position.Y)
				rSize = self._targetSize
				rOff = target
				self:_closePopup()
			end
		end)
	end
	conn(self, UserInputService.InputChanged, function(input)
		if resizing and isMove(input) then
			local d = (Vector2.new(input.Position.X, input.Position.Y) - rStart) / fit.Scale
			local want = rSize + Vector2.new(resizing ~= "b" and d.X or 0, resizing ~= "r" and d.Y or 0)
			local cam = Workspace.CurrentCamera
			if cam then
				local vp = cam.ViewportSize
				local topLeft = vp / 2 + rOff - rSize * fit.Scale / 2
				local room = (vp - Vector2.new(8, 8) - topLeft) / fit.Scale
				want = Vector2.new(math.min(want.X, math.max(self.MinSize.X, room.X)), math.min(want.Y, math.max(self.MinSize.Y, room.Y)))
			end
			local ns = self:_clampSize(want)
			self._targetSize = ns
			self._wantSize = ns
			target = rOff + (ns - rSize) * fit.Scale / 2
		end
	end)
	conn(self, UserInputService.InputEnded, function(input)
		if resizing and isPointer(input) then
			local mm = resizing
			resizing = nil
			resizeHover(mm, false)
		end
	end)

	---------------------------------------------------------------- keys & search
	conn(self, UserInputService.InputBegan, function(input, gp)
		if self._listening then return end
		if UserInputService:GetFocusedTextBox() then return end
		if input.KeyCode == self.ToggleKey then
			self:Toggle()
			return
		end
		if input.KeyCode == Enum.KeyCode.K and self.Visible
			and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
			task.delay(0.03, function() search:CaptureFocus() end)
			return
		end
		if gp then return end
		for _, kb in self.Keybinds do
			local mod = kb.Section and kb.Section.Tab.Module
			if kb.Value == input.KeyCode and kb.OnPress and not (mod and not mod.Enabled) then
				task.spawn(kb.OnPress, input.KeyCode)
			end
		end
	end)
	conn(self, search:GetPropertyChangedSignal("Text"), function()
		self:_filter(search.Text)
	end)
	closeB.MouseButton1Click:Connect(function() self:RequestClose() end)

	---------------------------------------------------------------- built-in pages
	self._bloomGroup = self:_group("bloom", { Builtin = true })
	self:_buildBuiltins()

	if opts.Visible ~= false then
		task.defer(function() self:Show() end)
	end
	return self
end

function Window:_clampBud(p)
	local cam = Workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	if vp.X < 200 then return p end
	return Vector2.new(math.clamp(p.X, 32, vp.X - 32), math.clamp(p.Y, 32, vp.Y - 32))
end

function Window:_budOffset()
	local bud = self._bud
	if not bud or not bud.Parent then return nil end
	local hc = self.Holder.AbsolutePosition + self.Holder.AbsoluteSize / 2
	local bc = bud.AbsolutePosition + bud.AbsoluteSize / 2
	return (bc - hc) / math.max(0.01, self._fit.Scale)
end

function Window:Show()
	if self.Visible or self._destroyed then return end
	self.Visible = true
	self._hideToken = nil
	local win = self._win
	self.Holder.Visible = true
	if self._useDim then
		self._dim.Visible = true
		tween(self._dim, Motion.Dim, { BackgroundTransparency = 1 - (current.Dim or 0.3) })
	end
	-- grow out of the bloom button
	local info = TweenInfo.new(0.55, ES.Quint, ED.Out)
	local from = self:_budOffset()
	local stage = self._stage
	if from then
		stage.Position = UDim2.new(0.5, from.X, 0.5, from.Y)
		self._wscale.Scale = 0.1
	else
		stage.Position = UDim2.new(0.5, 0, 0.5, 8)
		self._wscale.Scale = 0.96
	end
	for _, g in { win, self._back } do
		g.GroupTransparency = 1
		tween(g, info, { GroupTransparency = 0 })
	end
	self._border.Transparency = 1
	self._shadowUI.Transparency = 1
	self._glowUI.Transparency = 1
	tween(stage, info, { Position = UDim2.fromScale(0.5, 0.5) })
	tween(self._border, info, { Transparency = 0 })
	tween(self._wscale, info, { Scale = 1 })
	tween(self._shadowUI, info, { Transparency = 0.45 })
	tween(self._glowUI, info, { Transparency = 0.84 })
	local markInfo = TweenInfo.new(0.38, ES.Exponential, ED.Out)
	for _, mk in self._marks do
		mk.f.Position = UDim2.new(mk.ax, mk.dx * 18, mk.ay, mk.dy * 18)
		mk.h.BackgroundTransparency = 1
		mk.v.BackgroundTransparency = 1
		task.delay(0.12, function()
			if not self.Visible then return end
			tween(mk.f, markInfo, { Position = UDim2.new(mk.ax, mk.dx * 9, mk.ay, mk.dy * 9) })
			tween(mk.h, markInfo, { BackgroundTransparency = 0 })
			tween(mk.v, markInfo, { BackgroundTransparency = 0 })
		end)
	end
	tween(self._budScale, Motion.Hover, { Scale = 0.9 })
	task.delay(0.12, function() tween(self._budScale, Motion.Knob, { Scale = 1 }) end)
	self._flower.Bloom(0.15)
	self:_cascade(true)
	self.Shown:Fire()
end

function Window:Hide()
	if not self.Visible then return end
	self.Visible = false
	self:_closePopup()
	if self._search:IsFocused() then self._search:ReleaseFocus() end
	-- fold back into the bloom button
	local info = TweenInfo.new(0.34, ES.Quint, ED.In)
	local to = self:_budOffset()
	tween(self._dim, Motion.Close, { BackgroundTransparency = 1 })
	tween(self._stage, info, { Position = to and UDim2.new(0.5, to.X, 0.5, to.Y) or UDim2.new(0.5, 0, 0.5, 4) })
	tween(self._win, info, { GroupTransparency = 1 })
	tween(self._back, info, { GroupTransparency = 1 })
	tween(self._border, info, { Transparency = 1 })
	tween(self._wscale, info, { Scale = to and 0.1 or 0.98 })
	tween(self._shadowUI, info, { Transparency = 1 })
	tween(self._glowUI, info, { Transparency = 1 })
	for _, mk in self._marks do
		tween(mk.h, Motion.Close, { BackgroundTransparency = 1 })
		tween(mk.v, Motion.Close, { BackgroundTransparency = 1 })
	end
	local token = {}
	self._hideToken = token
	task.delay(0.34, function()
		if self._destroyed then return end
		-- the bud "catches" the window
		tween(self._budScale, TweenInfo.new(0.12, ES.Quad, ED.Out), { Scale = 1.16 })
		task.delay(0.12, function() tween(self._budScale, Motion.Knob, { Scale = 1 }) end)
		self._budFlower.Bloom(0)
		if self._hideToken == token and not self.Visible then
			self.Holder.Visible = false
			self._dim.Visible = false
		end
	end)
	self.Hidden:Fire()
end

function Window:Toggle()
	if self.Visible then self:Hide() else self:Show() end
end

function Window:SetMinimized(b)
	self._min = b
	self:_closePopup()
end

function Window:RequestClose()
	local n = #self.Modules
	self:Dialog({
		Tag = "close bloom", Kind = "error",
		Title = "close the panel?",
		Text = n > 0
			and string.format("this closes bloom and unloads %d module%s. to turn off a single module, use <b>bloom / modules</b>.", n, n == 1 and "" or "s")
			or "this closes bloom. run the script again to bring it back.",
		Buttons = { { Text = "cancel" }, { Text = "close", Kind = "danger" } },
		Callback = function(i)
			if i == 2 then self:Destroy() end
		end,
	})
end

function Window:SetSize(v)
	self._wantSize = v
	self._targetSize = self:_clampSize(v)
end

function Window:_clampSize(v)
	local cam = Workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
	if vp.X < 200 or vp.Y < 200 then vp = Vector2.new(1920, 1080) end
	local s = self._fit and self._fit.Scale or 1
	local maxW = math.max(self.MinSize.X, vp.X / s - 24)
	local maxH = math.max(self.MinSize.Y, vp.Y / s - 24)
	return Vector2.new(math.clamp(math.round(v.X), self.MinSize.X, maxW), math.clamp(math.round(v.Y), self.MinSize.Y, maxH))
end

function Window:_queueLayout()
	if self._layoutQueued then return end
	self._layoutQueued = true
	task.defer(function()
		self._layoutQueued = false
		self._laidW = nil
		if not self._destroyed then self:_relayout() end
	end)
end

---------------------------------------------------------------- sidebar groups
local SIDE_FULL, SIDE_RAIL = 176, 58
local GROUP_HEAD = 30

function Window:_group(name, o)
	o = o or {}
	for _, g in self._groups do
		if g.Name == name and not g.Removed then return g end
	end
	local g = { Name = name, Tabs = {}, Collapsed = false, Hidden = false, Module = o.Module, Builtin = o.Builtin }
	local order = o.Builtin and 0 or (#self._groups + 1) * 10
	local f = frame(self._nav, { Name = "Group_" .. name, Size = UDim2.new(1, 0, 0, GROUP_HEAD), ClipsDescendants = true, LayoutOrder = order })
	local head = new("TextButton", { Name = "Head", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, GROUP_HEAD), Parent = f })
	local hl = label(head, lc(name), { Size = 14, Font = "Display", Color = "TextFaint", Pos = UDim2.fromOffset(10, 0), Dim = UDim2.new(1, -40, 1, 0), Truncate = true })
	local ch = chevronGlyph(head, "TextFaint", { Pos = UDim2.new(1, -8, 0.5, 0), Anchor = Vector2.new(1, 0.5) })
	local rule = frame(head, { Size = UDim2.fromOffset(18, 1), Position = UDim2.new(0.5, 0, 0, 5), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 0, Visible = false })
	paint(rule, { BackgroundColor3 = "StrokeStrong" })
	local items = frame(f, { Name = "Items", Position = UDim2.fromOffset(0, GROUP_HEAD + 2), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO })
	list(items, nil, 4)
	g.Frame, g.Head, g.Label, g.Chevron, g.Rule, g.Items = f, head, hl, ch, rule, items
	head.MouseEnter:Connect(function() if not self._compact then recolor(hl, "TextColor3", "TextDim", Motion.Hover) end end)
	head.MouseLeave:Connect(function() recolor(hl, "TextColor3", "TextFaint", Motion.HoverOut) end)
	head.MouseButton1Click:Connect(function()
		if self._compact then return end
		self:CollapseGroup(g, not g.Collapsed)
	end)
	table.insert(self._groups, g)
	if self._compact then
		hl.Visible, ch.Visible, rule.Visible = false, false, true
		items.Position = UDim2.fromOffset(0, 12)
	end
	return g
end

function Window:_groupHeight(g)
	if g.Hidden then return 0 end
	local n = #g.Tabs
	local items = n > 0 and (n * 40 - 4) or 0
	if self._compact then return 12 + items + 8 end
	if g.Collapsed then return GROUP_HEAD end
	return GROUP_HEAD + 2 + items + 8
end

function Window:_layoutGroup(g, instant)
	if g.Removed then return end
	local h = self:_groupHeight(g)
	if h > 0 then g.Frame.Visible = true end
	if instant then
		g.Frame.Size = UDim2.new(1, 0, 0, h)
		g.Chevron.Rotation = g.Collapsed and -90 or 0
		if h == 0 then g.Frame.Visible = false end
	else
		local tw = tween(g.Frame, Motion.Drop, { Size = UDim2.new(1, 0, 0, h) })
		tween(g.Chevron, Motion.Drop, { Rotation = g.Collapsed and -90 or 0 })
		if h == 0 then
			tw.Completed:Connect(function() if g.Hidden then g.Frame.Visible = false end end)
		end
	end
end

function Window:CollapseGroup(g, b)
	if type(g) == "string" then
		for _, x in self._groups do if x.Name == g then g = x break end end
	end
	if type(g) ~= "table" then return end
	g.Collapsed = b
	self:_layoutGroup(g)
end

function Window:_setGroupVisible(g, b)
	g.Hidden = not b
	self:_layoutGroup(g)
end

function Window:_removeGroup(g)
	g.Removed = true
	local i = table.find(self._groups, g)
	if i then table.remove(self._groups, i) end
	tween(g.Frame, Motion.Drop, { Size = UDim2.new(1, 0, 0, 0) })
	task.delay(0.26, function() g.Frame:Destroy() end)
end

function Window:_setCompact(b, instant)
	self._compact = b
	local sw = b and SIDE_RAIL or SIDE_FULL
	local info = instant and TweenInfo.new(0) or Motion.Tab
	tween(self._side, info, { Size = UDim2.new(0, sw, 1, 0) })
	tween(self._sideLine, info, { Position = UDim2.fromOffset(sw, 0) })
	tween(self._main, info, { Position = UDim2.fromOffset(sw + 1, 0), Size = UDim2.new(1, -(sw + 1), 1, 0) })
	self._navPad.PaddingLeft = UDim.new(0, b and 7 or 12)
	self._navPad.PaddingRight = UDim.new(0, b and 7 or 12)
	self._foot.Visible = not b
	self._nav.Size = UDim2.new(1, 0, 1, b and -8 or -74)
	for _, g in self._groups do
		g.Label.Visible = not b
		g.Chevron.Visible = not b
		g.Rule.Visible = b
		g.Items.Position = UDim2.fromOffset(0, b and 12 or GROUP_HEAD + 2)
		self:_layoutGroup(g, instant)
	end
	local noAtlas = Icons.Atlas == ""
	for _, t in self.Tabs do
		tween(t._label, info, { TextTransparency = b and 1 or 0 })
		t._badge.Visible = not b
		t._icon.AnchorPoint = b and Vector2.new(0.5, 0.5) or Vector2.new(0, 0.5)
		t._icon.Position = b and UDim2.fromScale(0.5, 0.5) or UDim2.new(0, 14, 0.5, 0)
		t._abbr.Visible = b and noAtlas
		t._icon.Visible = not (b and noAtlas)
	end
end

function Window:_relayout()
	local w = math.round(self._shownSize.X)
	self._laidW = w
	local compact = w < self._compactAt
	if compact ~= self._compact then self:_setCompact(compact, self._compact == nil) end
	local searchW = math.clamp(w * 0.36, 120, 300)
	self._brandSub.Visible = (w - 50 - searchW) > 296
	self._kbd.Visible = w >= 560
	local sw = compact and SIDE_RAIL or SIDE_FULL
	local contentW = w - sw - 1 - 48
	for _, t in self.Tabs do t:_layout(contentW) end
	local aw = self._actionsList.AbsoluteContentSize.X / math.max(0.01, self._fit.Scale * self._wscale.Scale)
	local off = -(48 + (aw > 0 and aw + 16 or 0))
	self._title.Size = UDim2.new(1, off, 0, 28)
	self._crumb.Size = UDim2.new(1, off, 0, 16)
end

function Window:_cascade(includeNav)
	if includeNav then
		local i = 0
		for _, g in self._groups do
			for _, t in g.Tabs do
				i += 1
				local inner = t._navInner
				inner.Position = UDim2.fromOffset(-10, 0)
				task.delay(0.1 + (i - 1) * 0.024, function()
					tween(inner, Motion.Stagger, { Position = UDim2.new() })
				end)
			end
		end
	end
	local tab = self.Current
	if not tab then return end
	local n = 0
	for _, row in tab.Rows do
		if row.Frame.Visible then
			n += 1
			if n > 14 then break end
			local inner = row.Inner
			inner.Position = UDim2.fromOffset(12, 0)
			task.delay(0.14 + (n - 1) * 0.018, function()
				tween(inner, Motion.Stagger, { Position = UDim2.new() })
			end)
		end
	end
end

function Window:_filter(q)
	q = string.lower(q or "")
	local tab = self.Current
	if not tab then return end
	for _, sec in tab.Sections do
		local any = false
		for _, row in sec.Rows do
			local hit = q == "" or string.find(string.lower(row.Search), q, 1, true) ~= nil
			row.Frame.Visible = hit and not row.Hidden
			any = any or hit
		end
		sec.Frame.Visible = any or q == "" or string.find(string.lower(sec.Name), q, 1, true) ~= nil
	end
	for _, t in self.Tabs do
		if q == "" then
			t._badge.Text = t._badgeText or ""
			recolor(t._badge, "TextColor3", t._badgeColor or "TextFaint")
		elseif t ~= tab then
			local c = 0
			for _, row in t.Rows do
				if string.find(string.lower(row.Search), q, 1, true) then c += 1 end
			end
			t._badge.Text = c > 0 and tostring(c) or ""
			recolor(t._badge, "TextColor3", "Accent")
		end
	end
end

-- Popup layer (dropdowns, pickers).
function Window:_openPopup(anchor, w, h, build, o)
	o = o or {}
	self:_closePopup()
	local ov = self._overlay
	local catcher = new("TextButton", {
		Name = "Catcher", Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = ov,
	})
	local pop = frame(ov, { Name = "Popup", BackgroundTransparency = 0, ZIndex = 51, ClipsDescendants = true })
	paint(pop, { BackgroundColor3 = "Surface" })
	corner(pop, 7)
	stroke(pop, "StrokeStrong")
	uiShadow(pop, { Blur = 20, Y = 8, Transparency = 0.45 })
	local s = self._fit.Scale * self._wscale.Scale
	local rel = (anchor.AbsolutePosition - self._win.AbsolutePosition) / s
	local asz = anchor.AbsoluteSize / s
	local x = rel.X + (o.AlignRight and (asz.X - w) or 0)
	x = math.clamp(x, 8, self.Size.X - w - 8)
	local y = rel.Y + asz.Y + 6
	local up = y + h > self.Size.Y - 8
	if up then
		pop.AnchorPoint = Vector2.new(0, 1)
		y = rel.Y - 6
	end
	pop.Position = UDim2.fromOffset(x, y + (up and 6 or -6))
	pop.Size = UDim2.fromOffset(w, math.min(h, 28))
	local inner = frame(pop, { Name = "Content", Size = UDim2.fromOffset(w, h), Position = up and UDim2.new(0, 0, 1, 0) or UDim2.new(), AnchorPoint = up and Vector2.new(0, 1) or Vector2.zero, ZIndex = 52 })
	build(inner)
	tween(pop, Motion.Drop, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h) })
	catcher.MouseButton1Click:Connect(function() self:_closePopup() end)
	self._popup = { pop = pop, catcher = catcher, onClose = o.OnClose }
	return inner, pop
end

function Window:_closePopup()
	local p = self._popup
	if not p then return end
	self._popup = nil
	if p.onClose then task.spawn(p.onClose) end
	p.catcher:Destroy()
	local pop = p.pop
	tween(pop, TweenInfo.new(0.14, ES.Quad, ED.In), { Size = UDim2.fromOffset(pop.Size.X.Offset, 0) })
	task.delay(0.15, function() pop:Destroy() end)
end

---------------------------------------------------------------- tabs / pages
function Window:Tab(o)
	if typeof(o) == "string" then o = { Name = o } end
	o = o or {}
	local g = o.GroupObj or self:_group(o.Group or "pages")
	local tab = setmetatable({
		Window = self, Name = o.Name or "Tab", Sections = {}, Rows = {}, _canvases = {},
		Group = g, Module = o.Module or g.Module, _ord = 0,
	}, Tab)

	local item = new("TextButton", {
		Name = tab.Name, Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36), LayoutOrder = #g.Tabs + 1, Parent = g.Items,
	})
	paint(item, { BackgroundColor3 = "Raised" })
	corner(item, 6)
	local inner = frame(item, { Size = UDim2.fromScale(1, 1) })
	local bar = frame(item, { Name = "Bar", Size = UDim2.fromOffset(3, 0), Position = UDim2.new(0, 3, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 0, ZIndex = 3 })
	paint(bar, { BackgroundColor3 = "Accent" })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = bar })
	local ic = icon(inner, o.Icon, 17, "TextDim", { Pos = UDim2.new(0, 14, 0.5, 0), Anchor = Vector2.new(0, 0.5) })
	local nm = label(inner, lc(tab.Name), { Size = 14, Font = "BodyBold", Color = "TextDim", Pos = UDim2.fromOffset(o.Icon and 42 or 16, 0), Dim = UDim2.new(1, -84, 1, 0), Truncate = true })
	local badge = label(inner, o.Badge and tostring(o.Badge) or "", { Size = 11, Font = "Mono", Color = o.BadgeColor or "TextFaint", AlignX = ALIGN_R, Dim = UDim2.new(1, -12, 1, 0) })
	local abbr = label(inner, lc(string.sub(tab.Name, 1, 2)), { Size = 14, Font = "Display", Color = "TextDim", AlignX = ALIGN_C })
	abbr.Visible = false
	tab._abbr = abbr
	tab._nav, tab._navInner, tab._bar, tab._icon, tab._label, tab._badge = item, inner, bar, ic, nm, badge
	tab._badgeText, tab._badgeColor = o.Badge and tostring(o.Badge) or "", o.BadgeColor or "TextFaint"
	if self._compact then
		nm.TextTransparency = 1
		badge.Visible = false
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		abbr.Visible = Icons.Atlas == ""
		ic.Visible = Icons.Atlas ~= ""
	end

	item.MouseEnter:Connect(function()
		if self.Current ~= tab then
			tween(item, Motion.Hover, { BackgroundTransparency = 0.55 })
			recolor(nm, "TextColor3", "Text", Motion.Hover)
		end
	end)
	item.MouseLeave:Connect(function()
		if self.Current ~= tab then
			tween(item, Motion.HoverOut, { BackgroundTransparency = 1 })
			recolor(nm, "TextColor3", "TextDim", Motion.HoverOut)
		end
	end)
	item.MouseButton1Click:Connect(function() self:SelectTab(tab) end)

	local page = new("ScrollingFrame", {
		Name = tab.Name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Y_AUTO,
		ScrollingDirection = Enum.ScrollingDirection.Y, Visible = false, ZIndex = 1, Parent = self._content,
	})
	paint(page, { ScrollBarImageColor3 = "StrokeStrong" })
	local pageBody = frame(page, { Name = "Body", Position = UDim2.fromOffset(24, 2), Size = UDim2.new(1, -48, 0, 0), AutomaticSize = Y_AUTO })
	padding(pageBody, 0, 0, 24, 0)
	tab._layoutList = list(pageBody, nil, 14)
	local left = frame(pageBody, { Name = "Left", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, LayoutOrder = 1 })
	list(left, nil, 0)
	local right = frame(pageBody, { Name = "Right", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, Visible = false, LayoutOrder = 2 })
	tab._rightPad = padding(right, 0, 0, 0, 0)
	list(right, nil, 14)
	tab.Page, tab._leftCol, tab._rightCol = page, left, right
	tab._lw = 150
	table.insert(self.Tabs, tab)
	table.insert(g.Tabs, tab)
	self:_layoutGroup(g, not self.Visible)
	if not self.Current then
		self:SelectTab(tab, true)
	end
	self:_queueLayout()
	return tab
end

-- A page is a tab whose content you draw yourself: Build(tab, Bloom.UI).
function Window:Page(o)
	local tab = self:Tab(o)
	if o and o.Build then
		local ok, err = pcall(o.Build, tab, Bloom.UI)
		if not ok then warn("[bloom] page '" .. tostring(o.Name) .. "' failed to build: " .. tostring(err)) end
	end
	return tab
end

function Window:_removeTab(t)
	if t._removed then return end
	t._removed = true
	for id, ctl in self.Flags do
		if ctl.Section and ctl.Section.Tab == t then self.Flags[id] = nil end
	end
	for i = #self.Keybinds, 1, -1 do
		local kb = self.Keybinds[i]
		if kb.Section and kb.Section.Tab == t then table.remove(self.Keybinds, i) end
	end
	local i = table.find(self.Tabs, t)
	if i then table.remove(self.Tabs, i) end
	local j = table.find(t.Group.Tabs, t)
	if j then table.remove(t.Group.Tabs, j) end
	if self.Current == t then
		self.Current = nil
		local fallback = (self._mainTab and not self._mainTab._removed) and self._mainTab or self.Tabs[1]
		if fallback then self:SelectTab(fallback, true) end
	end
	t._nav:Destroy()
	t.Page:Destroy()
	self:_layoutGroup(t.Group)
end

function Tab:SetBadge(text, colorToken)
	self._badgeText = text and tostring(text) or ""
	self._badgeColor = colorToken or "TextFaint"
	self._badge.Text = self._badgeText
	recolor(self._badge, "TextColor3", self._badgeColor)
end

function Tab:Select()
	self.Window:SelectTab(self)
end

function Tab:_nextOrder()
	self._ord += 1
	return self._ord
end

-- Free-form block inside a tab (used by pages). Returns a vertical-list frame.
function Tab:Canvas(o)
	o = o or {}
	local rightSide = o.Side == "Right"
	if rightSide then self._rightCol.Visible = true end
	local col = rightSide and self._rightCol or self._leftCol
	local f = frame(col, { Name = o.Name or "Canvas", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, LayoutOrder = self:_nextOrder() })
	padding(f, o.Top or 14, 0, o.Bottom or 0, 0)
	list(f, nil, o.Gap or 12)
	table.insert(self._canvases, f)
	self.Window:_queueLayout()
	return f
end

function Window:SelectTab(tab, instant)
	if self.Current == tab or tab._removed then return end
	local prev = self.Current
	self.Current = tab
	self:_closePopup()
	for _, t in self.Tabs do
		local on = t == tab
		tween(t._nav, Motion.Hover, { BackgroundTransparency = on and 0 or 1 })
		recolor(t._label, "TextColor3", on and "Text" or "TextDim", Motion.Hover)
		recolor(t._icon, "ImageColor3", on and "Accent" or "TextDim", Motion.Hover)
		recolor(t._abbr, "TextColor3", on and "Accent" or "TextDim", Motion.Hover)
		local fb = t._icon:FindFirstChild("Fallback")
		if fb then recolor(fb:FindFirstChildOfClass("UIStroke"), "Color", on and "Accent" or "TextDim", Motion.Hover) end
		tween(t._bar, Motion.Tab, { Size = UDim2.fromOffset(3, on and 16 or 0) })
	end
	if tab.Group.Collapsed then self:CollapseGroup(tab.Group, false) end
	self:_applyPattern(not instant)
	if prev and not prev._removed then prev.Page.Visible = false end
	tab.Page.Visible = true
	self._title.Text = lc(tab.Name)
	-- crumb = module (group) / page
	self._crumb.Text = track(tab.Group.Name .. " / " .. tab.Name)
	if self._search.Text ~= "" then self._search.Text = "" end
	if tab._onShow then task.spawn(tab._onShow) end
	if not instant then
		tab.Page.Position = UDim2.fromOffset(0, 10)
		tween(tab.Page, Motion.Open, { Position = UDim2.new() })
		local v = self._veil
		v.Visible = true
		v.BackgroundTransparency = 0
		local tw = tween(v, TweenInfo.new(0.28, ES.Sine, ED.Out), { BackgroundTransparency = 1 })
		tw.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then v.Visible = false end
		end)
		self:_cascade(false)
	end
end

function Window:_patAlpha()
	local cfg = self._patCfg or Bloom.Pattern
	return 1 - (cfg.Alpha or Bloom.Pattern.Alpha or current.PatternAlpha or 0.07)
end

-- Shows the pattern of the current page's module (Module:SetPattern) or the default one.
function Window:_applyPattern(animate)
	local pat = self._pattern
	if not pat then return end
	local tab = self.Current
	local cfg = (tab and tab.Module and tab.Module.Pattern) or Bloom.Pattern
	local image = self._patternOff and "" or (cfg.Image or "")
	local changed = self._patCfg ~= cfg or pat.Image ~= image
	self._patCfg = cfg
	local alpha = self:_patAlpha()
	local function swap()
		pat.Image = image
		pat.Visible = image ~= ""
		local T = cfg.TileSize or Bloom.Pattern.TileSize or 256
		pat.TileSize = UDim2.fromOffset(T, T)
		pat.Size = UDim2.new(1, T * 2, 1, T * 2)
		recolor(pat, "ImageColor3", cfg.Tint or "PatternTint")
	end
	if animate and changed and pat.Visible then
		local tw = tween(pat, TweenInfo.new(0.16, ES.Sine, ED.In), { ImageTransparency = 1 })
		tw.Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed then return end
			swap()
			tween(pat, TweenInfo.new(0.32, ES.Sine, ED.Out), { ImageTransparency = alpha })
		end)
	else
		swap()
		if animate and pat.Visible then
			tween(pat, TweenInfo.new(0.32, ES.Sine, ED.Out), { ImageTransparency = alpha })
		else
			pat.ImageTransparency = alpha
		end
	end
end

function Window:Action(text, o)
	o = o or {}
	local b = button(self._actions, text, { Kind = o.Kind or "ghost", Hint = o.Hint, Size = UDim2.fromOffset(o.Width or 92, 32), Order = o.Order or 0 })
	if o.Callback then b.MouseButton1Click:Connect(o.Callback) end
	self:_queueLayout()
	return b
end

function Tab:Section(name, o)
	o = o or {}
	local right = o.Side == "Right"
	local col = right and self._rightCol or self._leftCol
	if right and not self._rightCol.Visible then
		self._rightCol.Visible = true
	end
	local sec = setmetatable({
		Tab = self, Window = self.Window, Name = name, Rows = {}, Right = right, _n = 0,
		LabelWidth = o.LabelWidth or (right and 96 or self._lw or 150), FixedLabel = o.LabelWidth ~= nil,
	}, Section)
	self.Window:_queueLayout()
	local f = frame(col, { Name = name, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, LayoutOrder = self:_nextOrder() })
	local bgTok = "Window"
	if right then
		bgTok = "Surface"
		f.BackgroundTransparency = 0
		paint(f, { BackgroundColor3 = "Surface" })
		corner(f, 8)
		stroke(f, "Stroke")
		padding(f, 4, 8, 8, 8)
	end
	list(f, nil, 0)
	local head = frame(f, { Name = "Head", Size = UDim2.new(1, 0, 0, right and 34 or 44), LayoutOrder = 0 })
	local line = frame(head, { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 1, -8), AnchorPoint = Vector2.new(0, 1) })
	local rule = frame(line, { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, 0.5), BackgroundTransparency = right and 1 or 0 })
	paint(rule, { BackgroundColor3 = "Stroke" })
	local hl = label(line, track(name), { Size = 15, Font = "Display", Color = "TextDim", Auto = X_AUTO, Dim = UDim2.new(0, 0, 1, 0), Z = 2 })
	hl.BackgroundTransparency = 0
	paint(hl, { BackgroundColor3 = bgTok })
	padding(hl, 0, 10, 0, 6)
	local cnt = label(line, "00", { Size = 11, Font = "Mono", Color = "TextFaint", Auto = X_AUTO, Dim = UDim2.new(0, 0, 1, 0), Pos = UDim2.fromScale(1, 0), Anchor = Vector2.new(1, 0), Z = 2, AlignX = ALIGN_R })
	cnt.BackgroundTransparency = 0
	paint(cnt, { BackgroundColor3 = bgTok })
	padding(cnt, 0, 6, 0, 10)
	sec._count = cnt
	sec.Frame = f
	table.insert(self.Sections, sec)
	return sec
end

function Tab:_layout(W)
	local hasRight = self._rightCol.Visible
	local sideBySide = hasRight and W >= 620
	local L = self._layoutList
	local colW
	if sideBySide then
		L.FillDirection = HORIZ
		L.Padding = UDim.new(0, 24)
		self._leftCol.Size = UDim2.new(1, -324, 0, 0)
		self._rightCol.Size = UDim2.new(0, 300, 0, 0)
		self._rightPad.PaddingTop = UDim.new(0, 18)
		colW = W - 324
	else
		L.FillDirection = Enum.FillDirection.Vertical
		L.Padding = UDim.new(0, 14)
		self._leftCol.Size = UDim2.new(1, 0, 0, 0)
		self._rightCol.Size = UDim2.new(1, 0, 0, 0)
		self._rightPad.PaddingTop = UDim.new(0, 0)
		colW = W
	end
	local lw = math.clamp(math.floor(colW * 0.34), 84, 150)
	self._lw = lw
	for _, sec in self.Sections do
		local slw = sec.FixedLabel and sec.LabelWidth or (sec.Right and (sideBySide and 96 or math.min(lw, 130)) or lw)
		sec.LabelWidth = slw
		for _, r in sec.Rows do
			if r.Lab and not r.Fixed then
				r.Lab.Size = UDim2.new(0, slw, 0, 40)
				r.Control.Size = UDim2.new(1, -(slw + 18), 1, 0)
				r.Control.Position = UDim2.fromOffset(slw + 12, 0)
				r.Cons.MaxSize = Vector2.new(math.max(40, slw - r.ChipW), 40)
			end
		end
	end
end

function Section:_row(o, typeToken, chipText, height)
	self._n += 1
	self._count.Text = string.format("%02d", self._n)
	local row = frame(self.Frame, { Name = o.Label or "Row", Size = UDim2.new(1, 0, 0, height or 40), LayoutOrder = self._n })
	local inner = frame(row, { Name = "Inner", Size = UDim2.fromScale(1, 1) })
	paint(inner, { BackgroundColor3 = "Text" })
	corner(inner, 4)
	inner.MouseEnter:Connect(function() tween(inner, Motion.Hover, { BackgroundTransparency = 0.975 }) end)
	inner.MouseLeave:Connect(function() tween(inner, Motion.HoverOut, { BackgroundTransparency = 1 }) end)
	local lw = o.LabelWidth or self.LabelWidth
	local ctl, labF, cons
	local chipW = chipText and (#chipText * 7 + 22) or 0
	if o.Full then
		ctl = frame(inner, { Name = "Control", Size = UDim2.new(1, -12, 1, 0), Position = UDim2.fromOffset(6, 0) })
	else
		local lab = frame(inner, { Name = "Label", Size = UDim2.new(0, lw, 0, 40), Position = UDim2.fromOffset(6, 0) })
		list(lab, HORIZ, 8, V_CENTER)
		labF = lab
		local nameL = label(lab, lc(o.Label), { Size = 14, Color = "TextDim", Auto = X_AUTO, Dim = UDim2.new(0, 0, 1, 0), Order = 1, Truncate = true })
		cons = new("UISizeConstraint", { MaxSize = Vector2.new(math.max(40, lw - chipW), 40), Parent = nameL })
		if chipText then chip(lab, chipText, typeToken, { Order = 2 }) end
		ctl = frame(inner, { Name = "Control", Size = UDim2.new(1, -(lw + 18), 1, 0), Position = UDim2.fromOffset(lw + 12, 0) })
	end
	local r = {
		Frame = row, Inner = inner, Control = ctl, Lab = labF, Cons = cons, ChipW = chipW, Fixed = o.LabelWidth ~= nil,
		Search = (o.Label or "") .. " " .. (o.Id or "") .. " " .. (chipText or ""),
	}
	table.insert(self.Rows, r)
	table.insert(self.Tab.Rows, r)
	return r
end

function Control:Get()
	return self.Value
end

function Control:Set(v, silent)
	self:_apply(v)
	if not silent then self:_emit() end
	return self
end

function Control:_emit()
	self.Changed:Fire(self.Value)
	if self.Callback then task.spawn(self.Callback, self.Value) end
	-- window-wide signal so AutoConfig can save on ANY change immediately
	-- instead of polling every 3s (keeps configs tight to the user's actions).
	local win = self.Window
	if win and win.AnyControlChanged then
		win.AnyControlChanged:Fire(self)
	end
end

function Control:SetVisible(b)
	self.Row.Hidden = not b
	self.Row.Frame.Visible = b
end

function Control:OnChanged(fn)
	return self.Changed:Connect(fn)
end

function Section:_control(kind, id, o, typeToken, chipText, height)
	if type(id) == "table" then
		o = id
		id = o.Id
	end
	o = o or {}
	o.Id = id
	o.Label = o.Label or id or kind
	local r = self:_row(o, typeToken, chipText, height)
	local c = setmetatable({
		Kind = kind, Id = id, Row = r, Window = self.Window, Section = self,
		Changed = Signal.new(), Callback = o.Callback, Options = o,
	}, Control)
	if id and o.Save ~= false then
		self.Window.Flags[id] = c
	end
	return c, r.Control, o
end

--------------------------------------------------------------------------
-- Controls · part 1
--------------------------------------------------------------------------
local function shiftDown()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function altDown()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
end

local function numbersIn(s)
	local out = {}
	for n in string.gmatch(s, "-?%d*%.?%d+") do
		out[#out + 1] = tonumber(n)
	end
	return out
end

-- STRING ---------------------------------------------------------------
function Section:String(id, o)
	local c, ctl
	c, ctl, o = self:_control("String", id, o, "TStr", "STR")
	local f = field(ctl)
	local max = o.MaxLength
	local tb = textbox(f.Box, { Placeholder = o.Placeholder or "", Dim = UDim2.new(1, max and -64 or -20, 1, 0) })
	bindFocus(f, tb)
	local counter
	if max then
		counter = label(f.Box, "", { Size = 11, Font = "Mono", Color = "TextFaint", AlignX = ALIGN_R, Dim = UDim2.new(1, -10, 1, 0), Z = 3 })
	end
	local function valid(s)
		if max and (utf8.len(s) or #s) > max then return false end
		if o.Pattern and not string.match(s, o.Pattern) then return false end
		if o.Validate and o.Validate(s) == false then return false end
		return true
	end
	local function upd()
		if counter then
			local n = utf8.len(tb.Text) or #tb.Text
			counter.Text = string.format("%d/%d", n, max)
			recolor(counter, "TextColor3", n > max and "Bad" or "TextFaint")
		end
	end
	c._apply = function(self2, v)
		v = tostring(v == nil and "" or v)
		self2.Value = v
		tb.Text = v
		upd()
		if f.bad then f.setBad(false) end
	end
	tb:GetPropertyChangedSignal("Text"):Connect(function()
		upd()
		local ok = valid(tb.Text)
		if ok == f.bad then f.setBad(not ok) end
		if o.Live and ok and tb.Text ~= c.Value then
			c.Value = tb.Text
			c:_emit()
		end
	end)
	tb.FocusLost:Connect(function()
		if valid(tb.Text) then
			if tb.Text ~= c.Value then
				c.Value = tb.Text
				c:_emit()
			end
		else
			tb.Text = c.Value
		end
	end)
	c.Input = tb
	c:Set(o.Default or "", true)
	return c
end

-- SLIDER PIECES ---------------------------------------------------------
local function sliderTrack(parent, rightPad)
	local area = new("TextButton", {
		Name = "Track", Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
		Size = UDim2.new(1, -(rightPad or 0), 0, 30), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
		Parent = parent,
	})
	local tk = frame(area, { Name = "Ticks", Size = UDim2.new(1, 0, 0, 5), Position = UDim2.fromOffset(0, 21) })
	for i = 0, 10 do
		local k = frame(tk, { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.fromScale(i / 10, 0), AnchorPoint = Vector2.new(i / 10, 0), BackgroundTransparency = 0 })
		paint(k, { BackgroundColor3 = "StrokeStrong" })
	end
	local rail = frame(area, { Name = "Rail", Size = UDim2.new(1, 0, 0, 3), Position = UDim2.fromOffset(0, 12), BackgroundTransparency = 0 })
	paint(rail, { BackgroundColor3 = "Raised" })
	corner(rail, 2)
	local fill = frame(area, { Name = "Fill", Size = UDim2.new(0, 0, 0, 3), Position = UDim2.fromOffset(0, 12), BackgroundTransparency = 0, ZIndex = 2 })
	paint(fill, { BackgroundColor3 = "Accent" })
	corner(fill, 2)
	return area, fill
end

local function sliderThumb(area)
	local glow = frame(area, { Name = "Glow", Size = UDim2.fromOffset(20, 27), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0, 13), ZIndex = 3 })
	paint(glow, { BackgroundColor3 = "Accent" })
	corner(glow, 5)
	local th = frame(area, { Name = "Thumb", Size = UDim2.fromOffset(10, 17), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0, 13), BackgroundTransparency = 0, ZIndex = 4 })
	paint(th, { BackgroundColor3 = "Text" })
	corner(th, 2)
	local tip = label(area, "", { Size = 11, Font = "MonoBold", Color = "AccentInk", AlignX = ALIGN_C, Auto = X_AUTO, Dim = UDim2.fromOffset(0, 16), Pos = UDim2.new(0, 0, 0, -2), Anchor = Vector2.new(0.5, 1), Z = 5 })
	paint(tip, { BackgroundColor3 = "Accent" })
	padding(tip, 0, 5, 0, 5)
	corner(tip, 3)
	tip.TextTransparency = 1
	local api = { glow = glow, th = th, tip = tip, a = 0 }
	function api.place(a, info)
		api.a = a
		local p = UDim2.new(a, 0, 0, 13)
		if info then
			tween(th, info, { Position = p })
			tween(glow, info, { Position = p })
			tween(tip, info, { Position = UDim2.new(a, 0, 0, tip.Position.Y.Offset) })
		else
			th.Position = p
			glow.Position = p
			tip.Position = UDim2.new(a, 0, 0, tip.Position.Y.Offset)
		end
	end
	function api.active(on)
		tween(th, on and Motion.Hover or Motion.Knob, { Size = on and UDim2.fromOffset(12, 21) or UDim2.fromOffset(10, 17) })
		tween(glow, Motion.Hover, { BackgroundTransparency = on and 0.82 or 1 })
		tween(tip, on and Motion.Drop or Motion.HoverOut, {
			TextTransparency = on and 0 or 1, BackgroundTransparency = on and 0 or 1,
			Position = UDim2.new(api.a, 0, 0, on and -6 or -2),
		})
	end
	function api.hover(on)
		tween(glow, Motion.Hover, { BackgroundTransparency = on and 0.9 or 1 })
	end
	return api
end

-- NUMBER ----------------------------------------------------------------
function Section:Number(id, o)
	local c, ctl
	c, ctl, o = self:_control("Number", id, o, "TNum", "NUM")
	local win = self.Window
	local min, max = o.Min or 0, o.Max or 100
	local step = o.Step or 0
	local dec = o.Decimals or ((step >= 1) and 0 or 2)
	local suffix = o.Suffix or ""
	local boxW = o.BoxWidth or 78
	local area, fill = sliderTrack(ctl, boxW + 12)
	local th = sliderThumb(area)
	local f = field(ctl, { Size = UDim2.fromOffset(boxW, 30), Pos = UDim2.new(1, 0, 0.5, 0), Anchor = Vector2.new(1, 0.5) })
	local tb = textbox(f.Box, { AlignX = ALIGN_R, Color = "TNum", Dim = UDim2.new(1, -16, 1, 0), Pos = UDim2.fromOffset(8, 0) })
	bindFocus(f, tb)

	local function alpha(v)
		return max > min and math.clamp((v - min) / (max - min), 0, 1) or 0
	end
	c._apply = function(self2, v, info)
		v = tonumber(v) or min
		v = math.clamp(snap(v, step, min), min, max)
		self2.Value = v
		local a = alpha(v)
		th.place(a, info)
		if info then tween(fill, info, { Size = UDim2.new(a, 0, 0, 3) }) else fill.Size = UDim2.new(a, 0, 0, 3) end
		if not tb:IsFocused() then tb.Text = fmt(v, dec) .. suffix end
		th.tip.Text = fmt(v, dec)
	end

	local dragging = false
	local function fromX(x)
		local a = math.clamp((x - area.AbsolutePosition.X) / math.max(1, area.AbsoluteSize.X), 0, 1)
		return min + a * (max - min)
	end
	local function push(v, info)
		local before = c.Value
		c:_apply(v, info)
		if c.Value ~= before and o.Live ~= false then c:_emit() end
	end
	area.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging = true
			c._dragStart = c.Value
			th.active(true)
			push(fromX(input.Position.X), Motion.Value)
		end
	end)
	conn(win, UserInputService.InputChanged, function(input)
		if dragging and isMove(input) then
			push(fromX(input.Position.X), TweenInfo.new(0.06, ES.Sine, ED.Out))
		end
	end)
	conn(win, UserInputService.InputEnded, function(input)
		if dragging and isPointer(input) then
			dragging = false
			th.active(false)
			if o.Live == false and c.Value ~= c._dragStart then c:_emit() end
		end
	end)
	area.MouseEnter:Connect(function() if not dragging then th.hover(true) end end)
	area.MouseLeave:Connect(function() if not dragging then th.hover(false) end end)
	tb.Focused:Connect(function() tb.Text = fmt(c.Value, dec) end)
	tb.FocusLost:Connect(function()
		local n = numbersIn(tb.Text)[1]
		if n then
			local before = c.Value
			c:_apply(n, Motion.Value)
			if c.Value ~= before then c:_emit() end
		else
			shake(f.Outer)
		end
		tb.Text = fmt(c.Value, dec) .. suffix
	end)
	c:Set(o.Default or min, true)
	return c
end

-- INT (stepper) ---------------------------------------------------------
function Section:Int(id, o)
	local c, ctl
	c, ctl, o = self:_control("Int", id, o, "TInt", "INT")
	local min, max, step = o.Min or -math.huge, o.Max or math.huge, o.Step or 1
	local box = frame(ctl, { Size = UDim2.fromOffset(126, 30), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 0, ClipsDescendants = true })
	paint(box, { BackgroundColor3 = "Surface" })
	corner(box, 5)
	local bst = stroke(box, "Stroke")
	local function stepBtn(sign, x)
		local b = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(x, 0), ZIndex = 2, Parent = box })
		paint(b, { BackgroundColor3 = "Raised" })
		local h = frame(b, { Size = UDim2.fromOffset(10, 2), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 0, ZIndex = 3 })
		paint(h, { BackgroundColor3 = "TextDim" })
		local v
		if sign > 0 then
			v = frame(b, { Size = UDim2.fromOffset(2, 10), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 0, ZIndex = 3 })
			paint(v, { BackgroundColor3 = "TextDim" })
		end
		b.MouseEnter:Connect(function()
			tween(b, Motion.Hover, { BackgroundTransparency = 0 })
			recolor(h, "BackgroundColor3", "Text", Motion.Hover)
			if v then recolor(v, "BackgroundColor3", "Text", Motion.Hover) end
		end)
		b.MouseLeave:Connect(function()
			tween(b, Motion.HoverOut, { BackgroundTransparency = 1 })
			recolor(h, "BackgroundColor3", "TextDim", Motion.HoverOut)
			if v then recolor(v, "BackgroundColor3", "TextDim", Motion.HoverOut) end
		end)
		return b
	end
	local mb = stepBtn(-1, 0)
	local pb = stepBtn(1, 96)
	for _, x in { 30, 95 } do
		local sep = frame(box, { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.fromOffset(x, 0), BackgroundTransparency = 0, ZIndex = 2 })
		paint(sep, { BackgroundColor3 = "Stroke" })
	end
	local val = textbox(box, { Font = "MonoBold", Color = "TInt", AlignX = ALIGN_C, Size = 14, Dim = UDim2.fromOffset(64, 30), Pos = UDim2.fromOffset(31, 0) })
	local hintText = o.Hint or ((step ~= 1 and ("step " .. step) or "") .. ((min ~= -math.huge and max ~= math.huge) and ((step ~= 1 and " · " or "") .. min .. "–" .. max) or ""))
	label(ctl, hintText, { Size = 11, Font = "Mono", Color = "TextFaint", Pos = UDim2.fromOffset(138, 0), Dim = UDim2.new(1, -138, 1, 0), Truncate = true })

	c._apply = function(self2, v, dir)
		v = math.clamp(math.round(tonumber(v) or 0), min, max)
		self2.Value = v
		val.Text = tostring(v)
		if dir then
			val.Position = UDim2.fromOffset(31, dir * -8)
			tween(val, Motion.Value, { Position = UDim2.fromOffset(31, 0) })
			recolor(val, "TextColor3", "Accent")
			recolor(val, "TextColor3", "TInt", TweenInfo.new(0.45, ES.Sine, ED.Out))
		end
	end
	local function bump(dir)
		local before = c.Value
		c:_apply(c.Value + dir * step * (shiftDown() and 10 or 1), dir)
		if c.Value ~= before then
			c:_emit()
			return true
		end
		shake(box)
		return false
	end
	local holdToken = 0
	local function holdable(b, dir)
		local function stop() holdToken += 1 end
		b.MouseButton1Down:Connect(function()
			holdToken += 1
			local my = holdToken
			bump(dir)
			task.delay(0.38, function()
				local d = 0.11
				while holdToken == my do
					if not bump(dir) then break end
					task.wait(d)
					d = math.max(0.025, d * 0.86)
				end
			end)
		end)
		b.MouseButton1Up:Connect(stop)
		b.MouseLeave:Connect(stop)
	end
	holdable(mb, -1)
	holdable(pb, 1)
	box.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			bump(input.Position.Z > 0 and 1 or -1)
		end
	end)
	val.Focused:Connect(function() recolor(bst, "Color", "Accent", Motion.Hover) end)
	val.FocusLost:Connect(function()
		recolor(bst, "Color", "Stroke", Motion.HoverOut)
		local n = numbersIn(val.Text)[1]
		if n then
			local before = c.Value
			c:_apply(n)
			if c.Value ~= before then c:_emit() end
		else
			shake(box)
		end
		val.Text = tostring(c.Value)
	end)
	c:Set(o.Default or math.max(min, math.min(0, max)), true)
	return c
end

-- TOGGLE (liquid switch) -------------------------------------------------
function Section:Toggle(id, o)
	local c, ctl
	c, ctl, o = self:_control("Toggle", id, o, "TBool", "BOOL")
	local sw = new("TextButton", { Name = "Switch", Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromOffset(48, 24), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Parent = ctl })
	paint(sw, { BackgroundColor3 = "Surface" })
	corner(sw, 5)
	local st = stroke(sw, "StrokeStrong")
	local knob = frame(sw, { Size = UDim2.fromOffset(20, 18), Position = UDim2.fromOffset(2, 3), BackgroundTransparency = 0, ZIndex = 2 })
	paint(knob, { BackgroundColor3 = "TextFaint" })
	corner(knob, 3)
	local txt = label(ctl, "", { Size = 13, Font = "Mono", Color = "TBool", Pos = UDim2.fromOffset(60, 0), Dim = UDim2.new(1, -60, 1, 0) })
	local seq = 0
	c._apply = function(self2, v, animate)
		v = v and true or false
		self2.Value = v
		txt.Text = v and "true" or "false"
		local info = animate and Motion.Hover or nil
		recolor(sw, "BackgroundColor3", v and "Accent" or "Surface", info)
		recolor(st, "Color", v and "Accent" or "StrokeStrong", info)
		recolor(knob, "BackgroundColor3", v and "Accent" or "TextFaint", info)
		recolor(txt, "TextColor3", v and "TBool" or "TextFaint", info)
		local bgT = v and 0.88 or 0
		local endPos = UDim2.fromOffset(v and 26 or 2, 3)
		seq += 1
		local my = seq
		if animate then
			tween(sw, Motion.Hover, { BackgroundTransparency = bgT })
			-- stretch toward the target, then snap back with overshoot
			tween(knob, TweenInfo.new(0.11, ES.Quad, ED.Out), { Size = UDim2.fromOffset(28, 18), Position = UDim2.fromOffset(v and 10 or 10, 3) })
			task.delay(0.1, function()
				if seq ~= my then return end
				tween(knob, Motion.Knob, { Size = UDim2.fromOffset(20, 18), Position = endPos })
			end)
		else
			sw.BackgroundTransparency = bgT
			knob.Size = UDim2.fromOffset(20, 18)
			knob.Position = endPos
		end
	end
	sw.MouseButton1Click:Connect(function()
		c:_apply(not c.Value, true)
		c:_emit()
	end)
	sw.MouseEnter:Connect(function() if not c.Value then recolor(st, "Color", "TextFaint", Motion.Hover) end end)
	sw.MouseLeave:Connect(function() if not c.Value then recolor(st, "Color", "StrokeStrong", Motion.HoverOut) end end)
	c:Set(o.Default == true, true)
	return c
end

-- CHECK -----------------------------------------------------------------
function Section:Check(id, o)
	local c, ctl
	c, ctl, o = self:_control("Check", id, o, "TBool", "BOOL")
	local b = new("TextButton", { Name = "Check", Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromOffset(20, 20), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Parent = ctl })
	paint(b, { BackgroundColor3 = "Surface" })
	corner(b, 4)
	local st = stroke(b, "StrokeStrong")
	local mark = frame(b, { Size = UDim2.fromScale(1, 1), ZIndex = 2 })
	local ms = new("UIScale", { Scale = 0, Parent = mark })
	local p1 = frame(mark, { Size = UDim2.fromOffset(2, 6), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(6.6, 11.6), Rotation = -45, BackgroundTransparency = 0, ZIndex = 3 })
	local p2 = frame(mark, { Size = UDim2.fromOffset(2, 11), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(11.6, 9.6), Rotation = 45, BackgroundTransparency = 0, ZIndex = 3 })
	paint(p1, { BackgroundColor3 = "AccentInk" })
	paint(p2, { BackgroundColor3 = "AccentInk" })
	local txt = label(ctl, o.Text or "", { Size = 13, Color = "TextDim", Pos = UDim2.fromOffset(32, 0), Dim = UDim2.new(1, -32, 1, 0) })
	c._apply = function(self2, v, animate)
		v = v and true or false
		self2.Value = v
		local info = animate and Motion.Hover or nil
		recolor(b, "BackgroundColor3", v and "Accent" or "Surface", info)
		recolor(st, "Color", v and "Accent" or "StrokeStrong", info)
		if animate then
			tween(ms, v and Motion.Knob or Motion.Close, { Scale = v and 1 or 0 })
		else
			ms.Scale = v and 1 or 0
		end
		if o.Text then recolor(txt, "TextColor3", v and "Text" or "TextDim", info) end
	end
	b.MouseButton1Click:Connect(function()
		c:_apply(not c.Value, true)
		c:_emit()
	end)
	c:Set(o.Default == true, true)
	return c
end

-- VECTOR-LIKE (Vector3, Vector2, UDim2, CFrame rows) --------------------
local function axisField(parent, letterText, token, pos, size, win, o, onCommit, onScrub)
	local f = field(parent, { Size = size, Pos = pos, Anchor = Vector2.new(0, 0.5) })
	local lw = #letterText > 1 and 24 or 16
	local letter = new("TextButton", {
		Text = letterText, AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(0, lw, 1, 0),
		Position = UDim2.fromOffset(6, 0), TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3, Parent = f.Box,
	})
	paint(letter, { TextColor3 = token, FontFace = "MonoBold" })
	local tb = textbox(f.Box, { AlignX = ALIGN_R, Dim = UDim2.new(1, -(lw + 14), 1, 0), Pos = UDim2.fromOffset(lw + 6, 0) })
	bindFocus(f, tb)
	tb.FocusLost:Connect(function() onCommit(tb.Text, f) end)
	-- drag the axis letter to scrub
	local scrubbing, sx = false, 0
	letter.InputBegan:Connect(function(input)
		if isPointer(input) then
			scrubbing = true
			sx = input.Position.X
			f.focus = true
			f.refresh()
			onScrub("begin")
		end
	end)
	conn(win, UserInputService.InputChanged, function(input)
		if scrubbing and isMove(input) then
			local k = o.ScrubStep or 0.1
			if altDown() then k *= 0.1 elseif shiftDown() then k *= 10 end
			onScrub("move", (input.Position.X - sx) * k)
		end
	end)
	conn(win, UserInputService.InputEnded, function(input)
		if scrubbing and isPointer(input) then
			scrubbing = false
			f.focus = false
			f.refresh()
			onScrub("end")
		end
	end)
	letter.MouseEnter:Connect(function() tween(letter, Motion.Hover, { TextTransparency = 0.35 }) end)
	letter.MouseLeave:Connect(function() tween(letter, Motion.HoverOut, { TextTransparency = 0 }) end)
	return tb, f
end

-- spec: { names, tokens, decs, ctor(...comps) -> value, parts(value) -> {comps} }
local function vectorGroup(c, parent, spec, o, yOffset, fieldsOut)
	local win = c.Window
	local n = #spec.names
	local gap = 6
	local comps = spec.comps
	local startVal
	for i, nm in spec.names do
		local tb
		tb = axisField(parent, nm, spec.tokens[i],
			UDim2.new((i - 1) / n, (i - 1) * gap / n + (spec.x or 0) * (1 - (i - 1) / n), 0, yOffset or 20),
			UDim2.new(1 / n, -gap * (n - 1) / n - (spec.x or 0) / n, 0, 30),
			win, o,
			function(text, f)
				local nums = numbersIn(text)
				if #nums >= spec.total then
					for k = 1, spec.total do comps[spec.offset + k] = nums[k] end
				elseif nums[1] then
					comps[spec.offset + i] = nums[1]
				else
					shake(f.Outer)
				end
				local before = c.Value
				c:_apply(spec.ctor(comps))
				if c.Value ~= before then c:_emit() end
			end,
			function(phase, delta)
				if phase == "begin" then
					startVal = comps[spec.offset + i]
				elseif phase == "move" then
					comps[spec.offset + i] = startVal + delta
					c:_apply(spec.ctor(comps))
					if o.Live ~= false then c:_emit() end
				elseif o.Live == false then
					c:_emit()
				end
			end)
		fieldsOut[spec.offset + i] = { tb = tb, dec = spec.decs[i] }
	end
end

local function vectorControl(self, kind, id, o, chipText, groups, total, ctor, parts, default, height)
	local c, ctl
	c, ctl, o = self:_control(kind, id, o, "TVec", chipText, height)
	local comps = table.create(total, 0)
	local fields = {}
	for _, g in groups do
		g.comps = comps
		g.total = total
		g.ctor = ctor
		vectorGroup(c, ctl, g, o, g.y, fields)
	end
	c._apply = function(self2, v)
		self2.Value = v
		local p = parts(v)
		for k = 1, total do
			comps[k] = p[k]
			local fd = fields[k]
			if fd and not fd.tb:IsFocused() then fd.tb.Text = fmt(p[k], fd.dec) end
		end
	end
	c:Set(o.Default or default, true)
	return c, ctl, o
end

function Section:Vector3(id, o)
	if type(id) == "table" then o = id; id = o.Id end
	o = o or {}
	local d = o.Decimals or 2
	local groups = {
		{ names = { "X", "Y", "Z" }, tokens = { "AxisX", "AxisY", "AxisZ" }, decs = { d, d, d }, offset = 0 },
	}
	local function ctor(cs) return Vector3.new(cs[1], cs[2], cs[3]) end
	local function parts(v) return { v.X, v.Y, v.Z } end
	return (vectorControl(self, "Vector3", id, o, "V3", groups, 3, ctor, parts, Vector3.zero))
end

function Section:Vector2(id, o)
	if type(id) == "table" then o = id; id = o.Id end
	o = o or {}
	local d = o.Decimals or 2
	local groups = {
		{ names = { "X", "Y" }, tokens = { "AxisX", "AxisY" }, decs = { d, d }, offset = 0 },
	}
	local function ctor(cs) return Vector2.new(cs[1], cs[2]) end
	local function parts(v) return { v.X, v.Y } end
	return (vectorControl(self, "Vector2", id, o, "V2", groups, 2, ctor, parts, Vector2.zero))
end

function Section:UDim2(id, o)
	if type(id) == "table" then o = id; id = o.Id end
	o = o or {}
	local groups = {
		{ names = { "Xs", "Xo", "Ys", "Yo" }, tokens = { "AxisX", "TextFaint", "AxisY", "TextFaint" }, decs = { 3, 0, 3, 0 }, offset = 0 },
	}
	local function ctor(cs) return UDim2.new(cs[1], math.round(cs[2]), cs[3], math.round(cs[4])) end
	local function parts(v) return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } end
	return (vectorControl(self, "UDim2", id, o, "UDIM2", groups, 4, ctor, parts, UDim2.new()))
end

function Section:CFrame(id, o)
	if type(id) == "table" then o = id; id = o.Id end
	o = o or {}
	local d = o.Decimals or 2
	local c, ctl
	c, ctl, o = vectorControl(self, "CFrame", id, o, "CF", {
		{ names = { "X", "Y", "Z" }, tokens = { "AxisX", "AxisY", "AxisZ" }, decs = { d, d, d }, offset = 0, y = 20 },
		{ names = { "R·x", "R·y", "R·z" }, tokens = { "TextFaint", "TextFaint", "TextFaint" }, decs = { 1, 1, 1 }, offset = 3, y = 56 },
	}, 6, function(cs)
		return CFrame.new(cs[1], cs[2], cs[3]) * CFrame.fromOrientation(math.rad(cs[4]), math.rad(cs[5]), math.rad(cs[6]))
	end, function(v)
		local rx, ry, rz = v:ToOrientation()
		return { v.X, v.Y, v.Z, math.deg(rx), math.deg(ry), math.deg(rz) }
	end, CFrame.identity, 78)
	-- quick grabs under the label
	local grabs = frame(c.Row.Inner, { Size = UDim2.fromOffset(84, 22), Position = UDim2.fromOffset(6, 46) })
	list(grabs, HORIZ, 4, V_CENTER)
	local function grab(text, fn, order)
		local b = button(grabs, text, { Size = UDim2.fromOffset(38, 22), Order = order })
		b:FindFirstChildOfClass("TextLabel").TextSize = 10
		b.MouseButton1Click:Connect(function()
			local cf = fn()
			if cf then
				c:_apply(cf)
				c:_emit()
			end
		end)
	end
	grab("CAM", function() return Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame end, 1)
	grab("CHAR", function()
		local ch = LocalPlayer.Character
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		return root and root.CFrame
	end, 2)
	return c
end

-- RANGE (dual thumb) ----------------------------------------------------
function Section:Range(id, o)
	local c, ctl
	c, ctl, o = self:_control("Range", id, o, "TNum", "RANGE")
	local win = self.Window
	local min, max = o.Min or 0, o.Max or 100
	local step = o.Step or 0
	local dec = o.Decimals or ((step >= 1) and 0 or 1)
	local suffix = o.Suffix or ""
	local area, fill = sliderTrack(ctl, 100)
	local t1, t2 = sliderThumb(area), sliderThumb(area)
	local readout = label(ctl, "", { Size = 13, Font = "Mono", Color = "TNum", AlignX = ALIGN_R, Dim = UDim2.new(0, 92, 1, 0), Pos = UDim2.fromScale(1, 0), Anchor = Vector2.new(1, 0) })
	local function alpha(v) return max > min and math.clamp((v - min) / (max - min), 0, 1) or 0 end
	c._apply = function(self2, v, info)
		local a, b
		if typeof(v) == "NumberRange" then a, b = v.Min, v.Max else a, b = min, max end
		a = math.clamp(snap(a, step, min), min, max)
		b = math.clamp(snap(b, step, min), min, max)
		if a > b then a, b = b, a end
		self2.Value = NumberRange.new(a, b)
		local aa, ab = alpha(a), alpha(b)
		t1.place(aa, info)
		t2.place(ab, info)
		t1.tip.Text, t2.tip.Text = fmt(a, dec), fmt(b, dec)
		local goal = { Position = UDim2.new(aa, 0, 0, 12), Size = UDim2.new(ab - aa, 0, 0, 3) }
		if info then tween(fill, info, goal) else fill.Position = goal.Position; fill.Size = goal.Size end
		readout.Text = fmt(a, dec) .. "–" .. fmt(b, dec) .. suffix
	end
	local mode, grabA, startV = nil, 0, nil
	local function toV(x)
		return min + math.clamp((x - area.AbsolutePosition.X) / math.max(1, area.AbsoluteSize.X), 0, 1) * (max - min)
	end
	local function push(a, b, info)
		local before = c.Value
		c:_apply(NumberRange.new(math.min(a, b), math.max(a, b)), info)
		if c.Value ~= before and o.Live ~= false then c:_emit() end
	end
	area.InputBegan:Connect(function(input)
		if not isPointer(input) then return end
		local v = toV(input.Position.X)
		local px = input.Position.X - area.AbsolutePosition.X
		local w = area.AbsoluteSize.X
		local d1, d2 = math.abs(px - alpha(c.Value.Min) * w), math.abs(px - alpha(c.Value.Max) * w)
		startV = c.Value
		if math.min(d1, d2) > 10 and v > c.Value.Min and v < c.Value.Max then
			mode, grabA = "both", v
			t1.active(true); t2.active(true)
		elseif d1 <= d2 then
			mode = "min"; t1.active(true)
			push(v, c.Value.Max, Motion.Value)
		else
			mode = "max"; t2.active(true)
			push(c.Value.Min, v, Motion.Value)
		end
	end)
	conn(win, UserInputService.InputChanged, function(input)
		if not mode or not isMove(input) then return end
		local v = toV(input.Position.X)
		local fast = TweenInfo.new(0.06, ES.Sine, ED.Out)
		if mode == "min" then
			push(math.min(v, c.Value.Max), c.Value.Max, fast)
		elseif mode == "max" then
			push(c.Value.Min, math.max(v, c.Value.Min), fast)
		else
			local span = startV.Max - startV.Min
			local lo = math.clamp(startV.Min + (v - grabA), min, max - span)
			push(lo, lo + span, fast)
		end
	end)
	conn(win, UserInputService.InputEnded, function(input)
		if mode and isPointer(input) then
			mode = nil
			t1.active(false); t2.active(false)
			if o.Live == false and c.Value ~= startV then c:_emit() end
		end
	end)
	c:Set(o.Default or NumberRange.new(min, max), true)
	return c
end

-- LABEL / PARAGRAPH -------------------------------------------------------
function Section:Label(text, o)
	o = o or {}
	o.Full = true
	o.Label = o.Label or text
	local r = self:_row(o, nil, nil, 0)
	r.Frame.AutomaticSize = Y_AUTO
	r.Inner.AutomaticSize = Y_AUTO
	r.Inner.Size = UDim2.new(1, 0, 0, 0)
	r.Control.AutomaticSize = Y_AUTO
	r.Control.Size = UDim2.new(1, -12, 0, 0)
	local l = label(r.Control, text, { Size = o.Size or 13, Color = o.Color or "TextDim", Wrap = true, Rich = true, Auto = Y_AUTO, Dim = UDim2.new(1, 0, 0, 0) })
	padding(l, 8, 0, 8, 0)
	local api = { Row = r, Label = l }
	function api:Set(t) l.Text = t end
	function api:SetVisible(b) r.Hidden = not b; r.Frame.Visible = b end
	return api
end

--------------------------------------------------------------------------
-- Controls · part 2
--------------------------------------------------------------------------
local function chevron(parent, token, o)
	o = o or {}
	local ch = frame(parent, { Name = "Chevron", Size = UDim2.fromOffset(14, 14), Position = o.Pos or UDim2.new(), AnchorPoint = o.Anchor or Vector2.zero, ZIndex = o.Z or 3, Rotation = o.Rotation or 0 })
	local a = frame(ch, { Size = UDim2.fromOffset(2, 7), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(4.6, 6.4), Rotation = -45, BackgroundTransparency = 0, ZIndex = (o.Z or 3) + 1 })
	local b = frame(ch, { Size = UDim2.fromOffset(2, 7), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(9.4, 6.4), Rotation = 45, BackgroundTransparency = 0, ZIndex = (o.Z or 3) + 1 })
	paint(a, { BackgroundColor3 = token })
	paint(b, { BackgroundColor3 = token })
	return ch, a, b
end

local function checkGlyph(parent, token, z)
	local m = frame(parent, { Name = "Check", Size = UDim2.fromOffset(16, 16), ZIndex = z or 4 })
	local p1 = frame(m, { Size = UDim2.fromOffset(2, 5), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(5, 9.4), Rotation = -45, BackgroundTransparency = 0, ZIndex = (z or 4) + 1 })
	local p2 = frame(m, { Size = UDim2.fromOffset(2, 10), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(9.6, 7.6), Rotation = 45, BackgroundTransparency = 0, ZIndex = (z or 4) + 1 })
	paint(p1, { BackgroundColor3 = token })
	paint(p2, { BackgroundColor3 = token })
	return m
end

-- COLOR3 ---------------------------------------------------------------
local PRESETS = { "D4FF4A", "FF6B5A", "FFB547", "6EE7A8", "7CC4FF", "C9A0FF", "FF86B6", "ECEAE4" }

function Section:Color(id, o)
	local c, ctl
	c, ctl, o = self:_control("Color", id, o, "TCol", "COL3")
	local win = self.Window
	local sw = new("TextButton", { Name = "Swatch", Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromOffset(30, 30), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Parent = ctl })
	paint(sw, { BackgroundColor3 = "Window" })
	corner(sw, 5)
	local swStroke = stroke(sw, "StrokeStrong")
	local chipC = frame(sw, { Size = UDim2.new(1, -6, 1, -6), Position = UDim2.fromOffset(3, 3), BackgroundTransparency = 0, ZIndex = 2 })
	corner(chipC, 3)
	local f = field(ctl, { Size = UDim2.fromOffset(100, 30), Pos = UDim2.new(0, 38, 0.5, 0) })
	local tb = textbox(f.Box, { Dim = UDim2.new(1, -16, 1, 0), Pos = UDim2.fromOffset(8, 0) })
	bindFocus(f, tb)
	local rgb = label(ctl, "", { Size = 12, Font = "Mono", Color = "TextFaint", Pos = UDim2.fromOffset(148, 0), Dim = UDim2.new(1, -148, 1, 0), Truncate = true })
	local H, Sat, Val = 0, 0, 1
	local sync -- set while picker is open
	c._apply = function(self2, col, keepHSV)
		if typeof(col) ~= "Color3" then col = Color3.new(1, 1, 1) end
		self2.Value = col
		if not keepHSV then
			local h, s, v = col:ToHSV()
			if s > 0.001 and v > 0.001 then H = h end
			Sat, Val = s, v
		end
		chipC.BackgroundColor3 = col
		if not tb:IsFocused() then tb.Text = "#" .. string.upper(col:ToHex()) end
		rgb.Text = string.format("%d · %d · %d", math.round(col.R * 255), math.round(col.G * 255), math.round(col.B * 255))
		if sync then sync() end
	end
	local function commit(col, keep)
		local before = c.Value
		c:_apply(col, keep)
		if c.Value ~= before then c:_emit() end
	end
	tb.FocusLost:Connect(function()
		local s = string.gsub(string.gsub(tb.Text, "#", ""), "%s", "")
		local ok, col = false, nil
		if #s == 6 or #s == 3 then
			if #s == 3 then s = string.gsub(s, "(.)", "%1%1") end
			ok, col = pcall(Color3.fromHex, s)
		end
		if not ok then
			local n = numbersIn(tb.Text)
			if #n >= 3 then ok, col = true, Color3.fromRGB(math.clamp(n[1], 0, 255), math.clamp(n[2], 0, 255), math.clamp(n[3], 0, 255)) end
		end
		if ok and col then commit(col) else shake(f.Outer) end
		tb.Text = "#" .. string.upper(c.Value:ToHex())
	end)
	sw.MouseEnter:Connect(function() recolor(swStroke, "Color", "Accent", Motion.Hover) end)
	sw.MouseLeave:Connect(function() recolor(swStroke, "Color", "StrokeStrong", Motion.HoverOut) end)

	sw.MouseButton1Click:Connect(function()
		local cons = {}
		local original = c.Value
		win:_openPopup(sw, 240, 250, function(p)
			-- saturation / value square
			local sv = new("TextButton", { Name = "SV", Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromOffset(182, 150), Position = UDim2.fromOffset(12, 12), ZIndex = 53, Parent = p })
			corner(sv, 4)
			local white = frame(sv, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0, BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 54 })
			corner(white, 4)
			new("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = white })
			local black = frame(sv, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0, BackgroundColor3 = Color3.new(0, 0, 0), ZIndex = 55 })
			corner(black, 4)
			new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0), Parent = black })
			local cur = frame(sv, { Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 57 })
			corner(cur, 6)
			new("UIStroke", { Thickness = 2, Color = Color3.new(1, 1, 1), Parent = cur })
			-- hue bar
			local hue = new("TextButton", { Name = "Hue", Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromOffset(14, 150), Position = UDim2.fromOffset(212, 12), BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 53, Parent = p })
			corner(hue, 3)
			local kp = {}
			for i = 0, 6 do kp[#kp + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV((i / 6) % 1, 1, 1)) end
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(kp), Parent = hue })
			local hh = frame(hue, { Size = UDim2.new(1, 6, 0, 4), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 0, BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 56 })
			corner(hh, 2)
			new("UIStroke", { Thickness = 1, Color = Color3.new(0, 0, 0), Transparency = 0.6, Parent = hh })
			-- presets
			local row = frame(p, { Size = UDim2.fromOffset(216, 22), Position = UDim2.fromOffset(12, 174), ZIndex = 53 })
			list(row, HORIZ, 6, V_CENTER)
			for i, hex in (o.Presets or PRESETS) do
				local col = typeof(hex) == "Color3" and hex or Color3.fromHex(hex)
				local b = new("TextButton", { Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromOffset(21, 21), BackgroundColor3 = col, LayoutOrder = i, ZIndex = 54, Parent = row })
				corner(b, 4)
				local bs = stroke(b, "StrokeStrong")
				b.MouseEnter:Connect(function() recolor(bs, "Color", "Text", Motion.Hover) end)
				b.MouseLeave:Connect(function() recolor(bs, "Color", "StrokeStrong", Motion.HoverOut) end)
				b.MouseButton1Click:Connect(function() commit(col) end)
			end
			-- before / after + hex
			local cmp = frame(p, { Size = UDim2.fromOffset(44, 30), Position = UDim2.fromOffset(12, 208), ZIndex = 53, ClipsDescendants = true })
			corner(cmp, 4)
			local old = new("TextButton", { Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.new(0.5, 0, 1, 0), BackgroundColor3 = original, ZIndex = 54, Parent = cmp })
			local now = frame(cmp, { Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromScale(0.5, 0), BackgroundTransparency = 0, ZIndex = 54 })
			old.MouseButton1Click:Connect(function() commit(original) end)
			local hf = field(p, { Size = UDim2.fromOffset(110, 30), Pos = UDim2.fromOffset(64, 223) })
			hf.Outer.ZIndex = 53
			local htb = textbox(hf.Box, { Dim = UDim2.new(1, -16, 1, 0), Pos = UDim2.fromOffset(8, 0) })
			bindFocus(hf, htb)
			htb.FocusLost:Connect(function()
				local s = string.gsub(string.gsub(htb.Text, "#", ""), "%s", "")
				local ok, col = pcall(Color3.fromHex, s)
				if ok and #s == 6 then commit(col) else shake(hf.Outer) end
			end)
			local rgbL = label(p, "", { Size = 11, Font = "Mono", Color = "TextFaint", AlignX = ALIGN_R, Pos = UDim2.fromOffset(180, 208), Dim = UDim2.fromOffset(48, 30), Z = 53 })

			sync = function()
				sv.BackgroundColor3 = Color3.fromHSV(H, 1, 1)
				cur.Position = UDim2.fromScale(Sat, 1 - Val)
				cur.BackgroundColor3 = c.Value
				hh.Position = UDim2.fromScale(0.5, H)
				now.BackgroundColor3 = c.Value
				if not htb:IsFocused() then htb.Text = "#" .. string.upper(c.Value:ToHex()) end
				rgbL.Text = string.format("H%d", math.round(H * 360))
			end
			sync()

			local drag = nil
			local function update(pos)
				if drag == "sv" then
					Sat = math.clamp((pos.X - sv.AbsolutePosition.X) / sv.AbsoluteSize.X, 0, 1)
					Val = 1 - math.clamp((pos.Y - sv.AbsolutePosition.Y) / sv.AbsoluteSize.Y, 0, 1)
				elseif drag == "hue" then
					H = math.clamp((pos.Y - hue.AbsolutePosition.Y) / hue.AbsoluteSize.Y, 0, 0.999)
				end
				local col = Color3.fromHSV(H, Sat, Val)
				c:_apply(col, true)
				if o.Live ~= false then c:_emit() end
			end
			sv.InputBegan:Connect(function(input) if isPointer(input) then drag = "sv"; update(input.Position) end end)
			hue.InputBegan:Connect(function(input) if isPointer(input) then drag = "hue"; update(input.Position) end end)
			table.insert(cons, UserInputService.InputChanged:Connect(function(input)
				if drag and isMove(input) then update(input.Position) end
			end))
			table.insert(cons, UserInputService.InputEnded:Connect(function(input)
				if drag and isPointer(input) then
					drag = nil
					if o.Live == false then c:_emit() end
				end
			end))
		end, {
			OnClose = function()
				sync = nil
				for _, cn in cons do cn:Disconnect() end
			end,
		})
	end)
	c:Set(o.Default or current.Accent, true)
	return c
end

-- ENUM / DROPDOWN --------------------------------------------------------
function Section:Enum(id, o)
	if type(id) == "table" then o = id; id = o.Id end
	o = o or {}
	local c, ctl
	c, ctl, o = self:_control("Enum", id, o, "TEnum", o.Chip or (o.Enum and "ENUM" or (o.Multi and "LIST" or "OPT")))
	local win = self.Window
	local items = {}
	local function setItems(src)
		items = {}
		if typeof(src) == "Enum" then
			for _, e in src:GetEnumItems() do items[#items + 1] = e end
			table.sort(items, function(a, b) return a.Name < b.Name end)
		else
			for _, v in src or {} do items[#items + 1] = v end
		end
	end
	setItems(o.Enum or o.Options)
	local function nameOf(v)
		if typeof(v) == "EnumItem" then return v.Name end
		return tostring(v)
	end

	local f = field(ctl)
	local btn = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = f.Box })
	local sq = frame(f.Box, { Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 0, ZIndex = 3 })
	paint(sq, { BackgroundColor3 = "TEnum" })
	corner(sq, 2)
	local txt = label(f.Box, "", { Size = 13, Pos = UDim2.fromOffset(26, 0), Dim = UDim2.new(1, -96, 1, 0), Truncate = true, Z = 3 })
	local cnt = label(f.Box, "", { Size = 11, Font = "Mono", Color = "TextFaint", AlignX = ALIGN_R, Dim = UDim2.new(1, -32, 1, 0), Z = 3 })
	local chev = chevron(f.Box, "TextFaint", { Pos = UDim2.new(1, -10, 0.5, 0), Anchor = Vector2.new(1, 0.5) })

	local function isSelected(v)
		if o.Multi then return table.find(c.Value or {}, v) ~= nil end
		return c.Value == v
	end
	c._apply = function(self2, v)
		if o.Multi then
			local arr = {}
			for _, x in (type(v) == "table" and v or {}) do
				if table.find(items, x) then arr[#arr + 1] = x end
			end
			self2.Value = arr
			local names = {}
			for _, x in arr do names[#names + 1] = nameOf(x) end
			txt.Text = #arr == 0 and "—" or (#arr <= 2 and table.concat(names, ", ") or (#arr .. " selected"))
		else
			if typeof(v) == "string" and o.Enum then
				local ok, e = pcall(function() return (o.Enum :: any)[v] end)
				if ok then v = e end
			end
			if v ~= nil and not table.find(items, v) then v = items[1] end
			self2.Value = v
			txt.Text = v ~= nil and nameOf(v) or "—"
		end
		cnt.Text = #items .. (o.Multi and " items" or " opts")
	end
	function c:SetOptions(list2)
		setItems(list2)
		self:_apply(self.Value)
	end

	local function open()
		local ROW = 28
		local searchable = #items > 8 or o.Search
		local visible = math.min(#items, 8)
		local w = math.max(200, math.round(f.Outer.AbsoluteSize.X / (win._fit.Scale)))
		local h = visible * ROW + 8 + (searchable and 38 or 0)
		if #items == 0 then h = 44 end
		win:_openPopup(f.Outer, w, h, function(p)
			local top = 4
			local query
			if searchable then
				local sf = field(p, { Size = UDim2.new(1, -8, 0, 28), Pos = UDim2.fromOffset(4, 4), Anchor = Vector2.zero, Bg = "Window" })
				sf.Outer.ZIndex = 53
				query = textbox(sf.Box, { Placeholder = Bloom.Strings.Filter, Size = 12 })
				bindFocus(sf, query)
				top = 38
				task.defer(function() query:CaptureFocus() end)
			end
			local sc = new("ScrollingFrame", {
				Size = UDim2.new(1, 0, 1, -top), Position = UDim2.fromOffset(0, top), BackgroundTransparency = 1, BorderSizePixel = 0,
				ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Y_AUTO, ZIndex = 53, Parent = p,
			})
			paint(sc, { ScrollBarImageColor3 = "StrokeStrong" })
			padding(sc, 0, 4, 4, 4)
			list(sc, nil, 0)
			if #items == 0 then
				label(sc, "—", { Size = 13, Color = "TextFaint", Dim = UDim2.new(1, 0, 0, ROW), AlignX = ALIGN_C, Z = 54 })
			end
			local rows = {}
			local function paintRow(r)
				local sel = isSelected(r.v)
				recolor(r.b, "BackgroundColor3", sel and "Accent" or "Raised")
				r.b.BackgroundTransparency = sel and 0.88 or 1
				recolor(r.l, "TextColor3", sel and "Text" or "TextDim")
				r.ck.Visible = sel
			end
			for i, v in items do
				local b = new("TextButton", { Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW), LayoutOrder = i, ZIndex = 54, Parent = sc })
				corner(b, 4)
				local inner = frame(b, { Size = UDim2.fromScale(1, 1), ZIndex = 55 })
				local l = label(inner, nameOf(v), { Size = 13, Pos = UDim2.fromOffset(10, 0), Dim = UDim2.new(1, -36, 1, 0), Truncate = true, Z = 56 })
				local ck = checkGlyph(inner, "Accent", 56)
				ck.AnchorPoint = Vector2.new(1, 0.5)
				ck.Position = UDim2.new(1, -8, 0.5, 0)
				local r = { b = b, l = l, ck = ck, v = v, name = string.lower(nameOf(v)) }
				rows[#rows + 1] = r
				paintRow(r)
				b.MouseEnter:Connect(function() if not isSelected(v) then tween(b, Motion.Hover, { BackgroundTransparency = 0 }) end end)
				b.MouseLeave:Connect(function() if not isSelected(v) then tween(b, Motion.HoverOut, { BackgroundTransparency = 1 }) end end)
				b.MouseButton1Click:Connect(function()
					if o.Multi then
						local arr = table.clone(c.Value)
						local at = table.find(arr, v)
						if at then table.remove(arr, at) else arr[#arr + 1] = v end
						c:_apply(arr)
						c:_emit()
						for _, rr in rows do paintRow(rr) end
					else
						local before = c.Value
						c:_apply(v)
						if before ~= v then c:_emit() end
						win:_closePopup()
					end
				end)
				if i <= 10 then
					inner.Position = UDim2.fromOffset(8, 0)
					task.delay(0.03 + i * 0.018, function() tween(inner, Motion.Stagger, { Position = UDim2.new() }) end)
				end
			end
			if query then
				query:GetPropertyChangedSignal("Text"):Connect(function()
					local q = string.lower(query.Text)
					for _, r in rows do r.b.Visible = q == "" or string.find(r.name, q, 1, true) ~= nil end
				end)
				query.FocusLost:Connect(function(enter)
					if enter and not o.Multi then
						for _, r in rows do
							if r.b.Visible then
								local before = c.Value
								c:_apply(r.v)
								if before ~= r.v then c:_emit() end
								win:_closePopup()
								break
							end
						end
					end
				end)
			end
		end, {
			OnClose = function()
				f.focus = false
				f.refresh()
				tween(chev, Motion.Drop, { Rotation = 0 })
			end,
		})
		f.focus = true
		f.refresh()
		tween(chev, Motion.Drop, { Rotation = 180 })
	end
	btn.MouseButton1Click:Connect(open)
	local default = o.Default
	if default == nil and not o.Multi then default = items[1] end
	c:Set(default or (o.Multi and {} or nil), true)
	return c
end

function Section:Dropdown(id, o)
	return self:Enum(id, o)
end

-- TABLE (tree viewer) ----------------------------------------------------
local function describe(v)
	local t = typeof(v)
	if t == "string" then return "TStr", "STR", '"' .. v .. '"' end
	if t == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return "TInt", "INT", tostring(v) end
		return "TNum", "NUM", short(v, 3)
	end
	if t == "boolean" then return "TBool", "BOOL", tostring(v) end
	if t == "Vector3" then return "TVec", "V3", string.format("%s, %s, %s", short(v.X, 1), short(v.Y, 1), short(v.Z, 1)) end
	if t == "Vector2" then return "TVec", "V2", string.format("%s, %s", short(v.X, 2), short(v.Y, 2)) end
	if t == "CFrame" then return "TVec", "CF", string.format("%s, %s, %s", short(v.X, 1), short(v.Y, 1), short(v.Z, 1)) end
	if t == "UDim2" then return "TVec", "UDIM2", string.format("{%s,%d},{%s,%d}", fmt(v.X.Scale, 2), v.X.Offset, fmt(v.Y.Scale, 2), v.Y.Offset) end
	if t == "Color3" then return "TCol", "COL3", "#" .. string.upper(v:ToHex()) end
	if t == "EnumItem" then return "TEnum", "ENUM", v.Name end
	if t == "Instance" then return "TInst", "INST", v.Name end
	if t == "NumberRange" then return "TNum", "RANGE", fmt(v.Min, 1) .. "–" .. fmt(v.Max, 1) end
	if t == "function" then return "TFn", "FN", "fn()" end
	if t == "table" then
		local n, arr = 0, true
		for k in v do
			n += 1
			if type(k) ~= "number" then arr = false end
		end
		return "TTbl", (arr and n > 0 and "ARR" or "TBL") .. "·" .. n, ""
	end
	return "TextFaint", string.upper(t), tostring(v)
end

function Section:Table(id, o)
	if type(id) == "table" and not o then o = id; id = o.Id end
	o = o or {}
	o.Full = true
	o.Save = false
	local c, ctl
	c, ctl, o = self:_control("Table", id, o, "TTbl", nil, 0)
	local r = c.Row
	r.Frame.AutomaticSize = Y_AUTO
	r.Inner.AutomaticSize = Y_AUTO
	r.Inner.Size = UDim2.new(1, 0, 0, 0)
	ctl.AutomaticSize = Y_AUTO
	ctl.Size = UDim2.new(1, -12, 0, 0)
	list(ctl, nil, 0)
	local head = frame(ctl, { Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 0 })
	label(head, lc(o.Label), { Size = 15, Font = "BodyBold", Dim = UDim2.new(1, -80, 1, 0), Pos = UDim2.fromOffset(4, 0) })
	local hchip = chip(head, "TBL", "TTbl", { Pos = UDim2.new(1, -2, 0.5, 0), Anchor = Vector2.new(1, 0.5) })
	local body = frame(ctl, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, LayoutOrder = 1 })
	list(body, nil, 0)
	local expanded = {}
	local maxDepth = o.Depth or 6
	if o.Expanded ~= false then expanded[""] = true end
	local ROW = 28

	local function sortedKeys(t)
		local ks = {}
		for k in t do ks[#ks + 1] = k end
		table.sort(ks, function(a, b)
			local ta, tb2 = type(a), type(b)
			if ta ~= tb2 then return ta == "number" end
			if ta == "number" or ta == "string" then return a < b end
			return tostring(a) < tostring(b)
		end)
		return ks
	end

	local render
	local function rebuild(animatePath, oldRot)
		for _, ch in body:GetChildren() do
			if not ch:IsA("UIListLayout") then ch:Destroy() end
		end
		local order = 0
		local fresh = {}
		local seen = {}
		local function emit(key, v, depth, path, parentOpen)
			order += 1
			local tok, chipText, shown = describe(v)
			local isTbl = type(v) == "table" and depth < maxDepth and not seen[v]
			local row = new("TextButton", { Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW), LayoutOrder = order, Parent = body })
			paint(row, { BackgroundColor3 = "Raised" })
			corner(row, 4)
			local inner = frame(row, { Size = UDim2.fromScale(1, 1) })
			for d = 1, depth do
				local g = frame(row, { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.fromOffset((d - 1) * 14 + 10, 0), BackgroundTransparency = 0.45 })
				paint(g, { BackgroundColor3 = "StrokeStrong" })
			end
			local x = depth * 14 + 4
			if isTbl then
				local open = expanded[path] == true
				local ch = chevron(inner, "TextFaint", { Pos = UDim2.new(0, x, 0.5, 0), Anchor = Vector2.new(0, 0.5), Rotation = open and 0 or -90 })
				if path == animatePath then
					ch.Rotation = oldRot
					tween(ch, Motion.Drop, { Rotation = open and 0 or -90 })
				end
			end
			local kl = label(inner, tostring(key), { Size = 13, Font = depth == 0 and "BodyBold" or "Body", Color = depth == 0 and "Text" or "TextDim", Pos = UDim2.fromOffset(x + 20, 0), Dim = UDim2.new(0.5, -(x + 20), 1, 0), Truncate = true })
			local vl = label(inner, shown, { Size = 13, Font = "Mono", Color = tok, AlignX = ALIGN_R, Pos = UDim2.new(0.5, 0, 0, 0), Dim = UDim2.new(0.5, -62, 1, 0), Truncate = true })
			if typeof(v) == "Color3" then
				local sq = frame(inner, { Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0.5, -6, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 0, BackgroundColor3 = v })
				corner(sq, 2)
			end
			chip(inner, chipText, tok, { Fixed = 54, Pos = UDim2.new(1, -2, 0.5, 0), Anchor = Vector2.new(1, 0.5) }).TextXAlignment = ALIGN_C
			row.MouseEnter:Connect(function() tween(row, Motion.Hover, { BackgroundTransparency = 0 }) end)
			row.MouseLeave:Connect(function() tween(row, Motion.HoverOut, { BackgroundTransparency = 1 }) end)
			if isTbl then
				row.MouseButton1Click:Connect(function()
					local was = expanded[path] == true
					expanded[path] = not was
					rebuild(path, was and 0 or -90)
				end)
			end
			if parentOpen then fresh[#fresh + 1] = inner end
			if isTbl and expanded[path] then
				seen[v] = true
				for _, k in sortedKeys(v) do
					emit(k, v[k], depth + 1, path .. "/" .. tostring(k), path == animatePath)
				end
				seen[v] = nil
			end
		end
		local root = c.Value
		if type(root) ~= "table" then
			label(body, Bloom.Strings.Empty, { Size = 13, Font = "Mono", Color = "TextFaint", Dim = UDim2.new(1, 0, 0, ROW), Pos = UDim2.fromOffset(4, 0) })
			hchip.Text = "NIL"
			return
		end
		local _, ct = describe(root)
		hchip.Text = ct
		seen[root] = true
		for _, k in sortedKeys(root) do
			emit(k, root[k], 0, "/" .. tostring(k), animatePath == nil)
		end
		for i, inner in fresh do
			if i > 16 then break end
			inner.Position = UDim2.fromOffset(8, 0)
			task.delay((i - 1) * 0.016, function() tween(inner, Motion.Stagger, { Position = UDim2.new() }) end)
		end
	end
	render = rebuild
	c._apply = function(self2, v)
		self2.Value = v
		render("__none")
	end
	function c:Refresh() render("__none") end
	c:Set(o.Default or {}, true)
	return c
end

-- INSTANCE picker -------------------------------------------------------
function Section:Instance(id, o)
	local c, ctl
	c, ctl, o = self:_control("Instance", id, o, "TInst", "INST")
	local win = self.Window
	local S = Bloom.Strings
	local f = field(ctl)
	icon(f.Box, "box", 15, "TInst", { Pos = UDim2.new(0, 10, 0.5, 0), Anchor = Vector2.new(0, 0.5), Z = 3 })
	local path = label(f.Box, "", { Size = 13, Font = "Mono", Rich = true, Pos = UDim2.fromOffset(32, 0), Dim = UDim2.new(1, -92, 1, 0), Truncate = true, Z = 3 })
	local pick = new("TextButton", { Text = S.Pick, AutoButtonColor = false, BorderSizePixel = 0, TextSize = 11, Size = UDim2.fromOffset(50, 22), Position = UDim2.new(1, -4, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), ZIndex = 4, Parent = f.Box })
	paint(pick, { BackgroundColor3 = "Raised", TextColor3 = "TextDim", FontFace = "MonoBold" })
	corner(pick, 3)
	pick.MouseEnter:Connect(function()
		recolor(pick, "BackgroundColor3", "Accent", Motion.Hover)
		recolor(pick, "TextColor3", "AccentInk", Motion.Hover)
	end)
	pick.MouseLeave:Connect(function()
		recolor(pick, "BackgroundColor3", "Raised", Motion.HoverOut)
		recolor(pick, "TextColor3", "TextDim", Motion.HoverOut)
	end)
	c._apply = function(self2, inst)
		if typeof(inst) ~= "Instance" then inst = nil end
		self2.Value = inst
		if inst then
			local full = inst:GetFullName()
			local parentPath = string.sub(full, 1, #full - #inst.Name)
			path.Text = string.format('<font color="#%s">%s</font>%s', current.TextFaint:ToHex(), parentPath, inst.Name)
		else
			path.Text = string.format('<font color="#%s">%s</font>', current.TextFaint:ToHex(), S.Empty)
		end
	end
	conn(win, Bloom.ThemeChanged, function() c:_apply(c.Value) end)
	pick.MouseButton1Click:Connect(function()
		if win._picking then return end
		win._picking = true
		local wasVisible = win.Visible
		win:Hide()
		local hint = win:Notify({ Title = S.Picking, Text = "Esc — " .. string.lower(S.Cancel), Kind = "info", Duration = 0 })
		local sel = new("SelectionBox", { LineThickness = 0.05, SurfaceTransparency = 0.88, Parent = win.Gui })
		paint(sel, { Color3 = "Accent", SurfaceColor3 = "Accent" })
		local mouse = LocalPlayer:GetMouse()
		win._listening = true
		local cand
		local rs, ib
		local function done(inst, cancelled)
			rs:Disconnect()
			ib:Disconnect()
			sel:Destroy()
			hint:Dismiss()
			task.defer(function() win._listening = false end)
			win._picking = false
			if not cancelled and inst then
				c:_apply(inst)
				c:_emit()
			end
			if wasVisible then win:Show() end
		end
		rs = RunService.RenderStepped:Connect(function()
			local t = mouse.Target
			if t and o.Class and not t:IsA(o.Class) then t = t:FindFirstAncestorWhichIsA(o.Class) end
			if t and o.Filter and not o.Filter(t) then t = nil end
			cand = t
			sel.Adornee = t
		end)
		ib = UserInputService.InputBegan:Connect(function(input, gp)
			if input.KeyCode == Enum.KeyCode.Escape then
				done(nil, true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 and not gp then
				done(cand, cand == nil)
			end
		end)
	end)
	c:Set(o.Default, true)
	return c
end

-- KEYBIND -----------------------------------------------------------------
function Section:Keybind(id, o)
	local c, ctl
	c, ctl, o = self:_control("Keybind", id, o, "TEnum", "KEY")
	local win = self.Window
	local S = Bloom.Strings
	local f = field(ctl, { Size = UDim2.fromOffset(150, 30), Pos = UDim2.new(0, 0, 0.5, 0) })
	local btn = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = f.Box })
	local dot = frame(f.Box, { Size = UDim2.fromOffset(7, 7), Position = UDim2.new(0, 11, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 1, ZIndex = 3 })
	paint(dot, { BackgroundColor3 = "Accent" })
	corner(dot, 4)
	local txt = label(f.Box, "", { Size = 13, Font = "Mono", Pos = UDim2.fromOffset(12, 0), Dim = UDim2.new(1, -20, 1, 0), Truncate = true, Z = 3 })
	label(ctl, o.Hint or "", { Size = 12, Color = "TextFaint", Pos = UDim2.fromOffset(162, 0), Dim = UDim2.new(1, -162, 1, 0), Truncate = true })
	c.OnPress = o.OnPress
	table.insert(win.Keybinds, c)
	c._apply = function(self2, key)
		if typeof(key) == "string" then
			local ok, k = pcall(function() return (Enum.KeyCode :: any)[key] end)
			key = ok and k or nil
		end
		if typeof(key) ~= "EnumItem" then key = nil end
		self2.Value = key
		txt.Text = key and key.Name or S.Unbound
		recolor(txt, "TextColor3", key and "Text" or "TextFaint")
	end
	local listening, pulse, cnx = false, nil, nil
	local function finish(key, cancel)
		if cnx then cnx:Disconnect() cnx = nil end
		listening = false
		task.defer(function() win._listening = false end)
		if pulse then pulse:Cancel() end
		dot.BackgroundTransparency = 1
		f.focus = false
		f.bad = false
		f.refresh()
		txt.Position = UDim2.fromOffset(12, 0)
		recolor(txt, "FontFace", "Mono")
		if cancel then
			c:_apply(c.Value)
		else
			local before = c.Value
			c:_apply(key)
			if c.Value ~= before then c:_emit() end
		end
	end
	btn.MouseButton1Click:Connect(function()
		if listening then return end
		listening = true
		win._listening = true
		f.focus = true
		f.refresh()
		txt.Text = S.PressKey
		txt.Position = UDim2.fromOffset(26, 0)
		recolor(txt, "FontFace", "Body")
		recolor(txt, "TextColor3", "TextDim")
		dot.BackgroundTransparency = 0
		pulse = tween(dot, TweenInfo.new(0.55, ES.Sine, ED.InOut, -1, true), { BackgroundTransparency = 0.75 })
		cnx = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				finish(nil, true)
				return
			end
			if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
			local k = input.KeyCode
			if k == Enum.KeyCode.Escape then finish(nil, true) return end
			if k == Enum.KeyCode.Backspace or k == Enum.KeyCode.Delete then finish(nil) return end
			local clash
			for _, kb in win.Keybinds do
				if kb ~= c and kb.Value == k then clash = kb.Options.Label end
			end
			if k == win.ToggleKey and not o.AllowToggleKey then clash = "window toggle" end
			if clash then
				f.setBad(true)
				txt.Text = S.KeyTaken .. clash
				recolor(txt, "TextColor3", "Bad")
				task.delay(1, function()
					if listening then
						f.bad = false
						f.refresh()
						txt.Text = S.PressKey
						recolor(txt, "TextColor3", "TextDim")
					end
				end)
				return
			end
			finish(k)
		end)
	end)
	c:Set(o.Default, true)
	return c
end

-- BUTTON ------------------------------------------------------------------
function Section:Button(id, o)
	if type(o) == "function" then o = { Callback = o } end
	if type(id) == "table" then o = id; id = o.Id end
	o = o or {}
	o.Save = false
	local c, ctl
	local chipText = if o.Chip == false then nil else "FN"
	c, ctl, o = self:_control("Button", id, o, "TFn", chipText)
	local kind = o.Danger and "danger" or (o.Primary and "primary" or "ghost")
	local text = o.Text or "Run"
	local b, l = button(ctl, text, { Kind = kind, Size = UDim2.new(1, 0, 0, 32), Pos = UDim2.new(0, 0, 0.5, 0), Anchor = Vector2.new(0, 0.5), Hint = o.Hint })
	local function fire()
		c.Value = os.clock()
		c.Changed:Fire()
		if o.Callback then task.spawn(o.Callback) end
		local tok = kind == "primary" and "AccentInk" or "Accent"
		recolor(l, "TextColor3", tok)
		recolor(l, "TextColor3", kind == "primary" and "AccentInk" or (kind == "danger" and "Bad" or "Text"), TweenInfo.new(0.5, ES.Sine, ED.Out))
	end
	if o.Hold then
		local prog = frame(b, { Size = UDim2.new(0, 0, 1, 0), BackgroundTransparency = 0.82, ZIndex = 1 })
		paint(prog, { BackgroundColor3 = kind == "danger" and "Bad" or (kind == "primary" and "AccentInk" or "Accent") })
		corner(prog, 5)
		l.Text = o.HoldText or ("Hold · " .. text)
		local holding, tw = false, nil
		b.MouseButton1Down:Connect(function()
			holding = true
			tw = tween(prog, TweenInfo.new(o.Hold, ES.Linear), { Size = UDim2.fromScale(1, 1) })
			tw.Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed and holding then
					holding = false
					fire()
					tween(prog, Motion.HoverOut, { Size = UDim2.new(0, 0, 1, 0) })
				end
			end)
		end)
		local function release()
			if holding then
				holding = false
				if tw then tw:Cancel() end
				tween(prog, Motion.Drop, { Size = UDim2.new(0, 0, 1, 0) })
			end
		end
		b.MouseButton1Up:Connect(release)
		b.MouseLeave:Connect(release)
	else
		b.MouseButton1Click:Connect(fire)
	end
	c._apply = function() end
	c.Fire = fire
	c.Button = b
	return c
end

-- Row of equal-width buttons: sec:Buttons({ {Text=, Callback=, Kind="primary"|"danger", Hint=} ... })
function Section:Buttons(defs, o)
	o = o or {}
	o.Full = true
	o.Label = o.Label or ""
	local r = self:_row(o, nil, nil, 40)
	local n = #defs
	local gap = 8
	local out = {}
	for i, d in defs do
		local b = button(r.Control, d.Text or "", {
			Kind = d.Kind or (d.Danger and "danger") or (d.Primary and "primary") or "ghost",
			Hint = d.Hint, AlignX = d.Hint and Enum.TextXAlignment.Left or nil,
			Size = UDim2.new(1 / n, -gap * (n - 1) / n, 0, 32),
			Pos = UDim2.new((i - 1) / n, (i - 1) * gap / n, 0.5, 0), Anchor = Vector2.new(0, 0.5),
		})
		if d.Callback then b.MouseButton1Click:Connect(d.Callback) end
		out[i] = b
		r.Search ..= " " .. (d.Text or "")
	end
	return out
end

--------------------------------------------------------------------------
-- Notifications
--------------------------------------------------------------------------
local toastSeq = 0
local KIND_TOKEN = { success = "Accent", info = "Info", warn = "Warn", error = "Bad" }
local KIND_ICON = { success = "circle-check", info = "info", warn = "triangle-alert", error = "circle-x" }

function Window:Notify(o)
	if type(o) == "string" then o = { Title = o } end
	o = o or {}
	local kind = o.Kind or "success"
	local tok = KIND_TOKEN[kind] or "Accent"
	local dur = o.Duration == nil and 4 or o.Duration
	local W = 320
	toastSeq += 1

	-- dynamic height: measure wrapped title + body text and let the card
	-- expand to fit. No truncation unless the user explicitly set Truncate.
	local TextService = game:GetService("TextService")
	local innerW = W - 100  -- width available for text (card minus icon + close)
	local function measure(text, size, font)
		if not text or text == "" then return 0 end
		local ok, v = pcall(function()
			return TextService:GetTextSize(text, size, font or Enum.Font.Gotham, Vector2.new(innerW, 10000))
		end)
		return ok and v.Y or size + 4
	end
	-- body renders in RobotoMono which is noticeably wider than Gotham, so
	-- measure with the matching font or we underestimate wrap height and
	-- the 2nd line gets clipped (e.g. ending at a colon).
	local titleH = math.max(20, measure(o.Title or "", 14, Enum.Font.Gotham))
	local bodyH  = o.Text and measure(o.Text, 12, Enum.Font.RobotoMono) or 0
	-- +1 line of slack so an off-by-one measurement never clips text
	if o.Text then bodyH = bodyH + 14 end
	local H
	if o.Text then
		H = math.max(62, 20 + titleH + bodyH)  -- 11 top + title + 4 gap + body + 5 bottom
	else
		H = math.max(50, titleH + 20)
	end

	self._toastList = self._toastList or {}
	-- no cap — if the user has lots of modules firing notifs, show them all

	-- give slot its full size IMMEDIATELY so UIListLayout spaces it correctly
	-- on frame 1. Previously we tweened Size 0 → H+10, which parked rapidly-
	-- fired toasts at the same y position until the tween finished.
	local slot = frame(self._toasts, { Name = "Toast", Size = UDim2.fromOffset(W, H + 10), LayoutOrder = toastSeq })
	local card = new("CanvasGroup", { Size = UDim2.fromOffset(W, H), Position = UDim2.fromOffset(28, 0), GroupTransparency = 1, BorderSizePixel = 0, Parent = slot })
	paint(card, { BackgroundColor3 = "Window" })
	corner(card, 8)
	stroke(card, "StrokeStrong")
	local tsh = uiShadow(card, { Blur = 20, Y = 8, Transparency = 1 })
	local ib = frame(card, { Size = UDim2.fromOffset(32, 32), Position = UDim2.new(0, 12, 0.5, -1), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 0.86 })
	paint(ib, { BackgroundColor3 = tok })
	corner(ib, 6)
	icon(ib, o.Icon or KIND_ICON[kind], 16, tok, { Anchor = Vector2.new(0.5, 0.5), Pos = UDim2.fromScale(0.5, 0.5) })
	local titleLbl = label(card, lc(o.Title), { Size = 14, Font = "BodyBold", Pos = UDim2.fromOffset(56, o.Text and 10 or 0), Dim = UDim2.new(1, -100, 0, o.Text and titleH or H - 2) })
	pcall(function() titleLbl.TextWrapped = true end)
	if o.Text then
		local bodyLbl = label(card, o.Text, { Size = 12, Font = "Mono", Color = "TextFaint", Pos = UDim2.fromOffset(56, 12 + titleH), Dim = UDim2.new(1, -100, 0, bodyH) })
		pcall(function()
			bodyLbl.TextWrapped = true
			bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
		end)
	end
	local xb = iconButton(card, "x", { Size = 26, IconSize = 14, Pos = UDim2.new(1, -10, 0.5, -1), Anchor = Vector2.new(1, 0.5) })
	local trackF = frame(card, { Size = UDim2.new(1, 0, 0, 2), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1), BackgroundTransparency = 0 })
	paint(trackF, { BackgroundColor3 = "Raised" })
	local barF = frame(trackF, { Size = UDim2.fromScale(dur > 0 and 1 or 0, 1), BackgroundTransparency = 0 })
	paint(barF, { BackgroundColor3 = tok })

	-- entrance anim lives entirely on the card now (slot is final-size already)
	tween(card, Motion.Toast, { Position = UDim2.new(), GroupTransparency = 0 })
	tween(tsh, Motion.Toast, { Transparency = 0.5 })

	local handle = {}
	local gone = false
	local hovered = false
	local remaining = dur
	local rs
	function handle.Dismiss()
		if gone then return end
		gone = true
		if rs then rs:Disconnect() end
		local i = table.find(self._toastList, handle)
		if i then table.remove(self._toastList, i) end
		tween(card, Motion.Close, { Position = UDim2.fromOffset(28, 0), GroupTransparency = 1 })
		tween(tsh, Motion.Close, { Transparency = 1 })
		task.delay(0.12, function()
			tween(slot, Motion.Drop, { Size = UDim2.fromOffset(W, 0) })
		end)
		task.delay(0.4, function() slot:Destroy() end)
	end
	function handle.SetTitle(t)
		local l = card:FindFirstChild("Label")
		if l then l.Text = t end
	end
	table.insert(self._toastList, handle)
	card.MouseEnter:Connect(function() hovered = true end)
	card.MouseLeave:Connect(function() hovered = false end)
	xb.MouseButton1Click:Connect(handle.Dismiss)
	if dur > 0 then
		rs = RunService.RenderStepped:Connect(function(dt)
			if hovered then return end
			remaining -= dt
			barF.Size = UDim2.fromScale(math.max(0, remaining / dur), 1)
			if remaining <= 0 then handle.Dismiss() end
		end)
	end
	return handle
end

--------------------------------------------------------------------------
-- Dialog (modal inside the window)
--------------------------------------------------------------------------
-- win:Dialog({ Title=, Text=, Tag="Confirm", Buttons = { {Text="Cancel"}, {Text="Delete", Kind="danger"} }, Callback = function(index, text) end })
function Window:Dialog(o)
	o = o or {}
	self:_closePopup()
	if not self.Visible then self:Show() end
	local ov = self._overlay
	local scrim = new("TextButton", { Name = "Scrim", Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 60, Parent = ov })
	paint(scrim, { BackgroundColor3 = "Shadow" })
	local W = o.Width or 400
	local card = new("CanvasGroup", {
		Name = "Dialog", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 12), Size = UDim2.fromOffset(W, 0),
		AutomaticSize = Y_AUTO, GroupTransparency = 1, BorderSizePixel = 0, ZIndex = 61, Parent = ov,
	})
	paint(card, { BackgroundColor3 = "Window" })
	corner(card, 9)
	stroke(card, "StrokeStrong")
	local dsh = uiShadow(card, { Blur = 40, Y = 18, Transparency = 1 })
	local sc = new("UIScale", { Scale = 0.97, Parent = card })
	padding(card, 20, 20, 18, 20)
	list(card, nil, 10)
	label(card, track(o.Tag or "Confirm"), { Size = 13, Font = "Display", Color = KIND_TOKEN[o.Kind or ""] or "TextFaint", Dim = UDim2.new(1, 0, 0, 12), Order = 1, Z = 62 })
	label(card, lc(o.Title), { Size = 21, Font = "Display", Wrap = true, Auto = Y_AUTO, Dim = UDim2.new(1, 0, 0, 0), Order = 2, Z = 62 })
	if o.Text then
		local t = label(card, o.Text, { Size = 14, Color = "TextDim", Wrap = true, Rich = true, Auto = Y_AUTO, Dim = UDim2.new(1, 0, 0, 0), Order = 3, Z = 62 })
		t.LineHeight = 1.15
	end
	local bar = frame(card, { Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 4, ZIndex = 62 })
	list(bar, HORIZ, 8, Enum.VerticalAlignment.Bottom, Enum.HorizontalAlignment.Right)

	local closed = false
	local keyConn
	local function close(index, text)
		if closed then return end
		closed = true
		if keyConn then keyConn:Disconnect() end
		tween(scrim, Motion.Close, { BackgroundTransparency = 1 })
		tween(card, Motion.Close, { GroupTransparency = 1, Position = UDim2.new(0.5, 0, 0.5, 6) })
		tween(dsh, Motion.Close, { Transparency = 1 })
		tween(sc, Motion.Close, { Scale = 0.98 })
		task.delay(0.24, function()
			scrim:Destroy()
			card:Destroy()
		end)
		if o.Callback then task.spawn(o.Callback, index, text) end
	end
	local defs = o.Buttons or { { Text = Bloom.Strings.Cancel }, { Text = "OK", Kind = "primary" } }
	local primaryIndex
	for i, d in defs do
		local kind = d.Kind or "ghost"
		if kind ~= "ghost" then primaryIndex = i end
		local tsz = math.max(84, #(d.Text or "") * 8 + 32)
		local b = button(bar, d.Text or "", { Kind = kind, Size = UDim2.fromOffset(tsz, 34), Order = i, Z = 63 })
		b.MouseButton1Click:Connect(function() close(i, d.Text) end)
	end
	scrim.MouseButton1Click:Connect(function()
		if o.Dismissible ~= false then close(nil, nil) end
	end)
	keyConn = UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape then
			close(nil, nil)
		elseif (input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter) and primaryIndex and not UserInputService:GetFocusedTextBox() then
			close(primaryIndex, defs[primaryIndex].Text)
		end
	end)
	tween(scrim, Motion.Dim, { BackgroundTransparency = 0.45 })
	tween(card, Motion.Open, { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.5) })
	tween(dsh, Motion.Open, { Transparency = 0.35 })
	tween(sc, Motion.Open, { Scale = 1 })
	return { Close = function() close(nil, nil) end }
end

-- Yielding variant: local index, text = win:Confirm({...})
function Window:Confirm(o)
	local thread = coroutine.running()
	o = table.clone(o or {})
	o.Callback = function(i, t) task.spawn(thread, i, t) end
	self:Dialog(o)
	return coroutine.yield()
end

--------------------------------------------------------------------------
-- Configs
--------------------------------------------------------------------------
local Codec = {}
Bloom.Codec = Codec

function Codec.encode(v)
	local t = typeof(v)
	if t == "number" or t == "string" or t == "boolean" then return v end
	if t == "Vector3" then return { __t = "V3", v = { v.X, v.Y, v.Z } } end
	if t == "Vector2" then return { __t = "V2", v = { v.X, v.Y } } end
	if t == "Color3" then return { __t = "C3", v = v:ToHex() } end
	if t == "UDim2" then return { __t = "U2", v = { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } } end
	if t == "CFrame" then return { __t = "CF", v = { v:GetComponents() } } end
	if t == "NumberRange" then return { __t = "NR", v = { v.Min, v.Max } } end
	if t == "EnumItem" then return { __t = "EI", v = { tostring(v.EnumType), v.Name } } end
	if t == "Instance" then return { __t = "IN", v = v:GetFullName() } end
	if t == "table" then
		local out = {}
		for k, x in v do out[k] = Codec.encode(x) end
		return out
	end
	return nil
end

function Codec.decode(v)
	if type(v) ~= "table" then return v end
	local tag, d = v.__t, v.v
	if tag == "V3" then return Vector3.new(d[1], d[2], d[3]) end
	if tag == "V2" then return Vector2.new(d[1], d[2]) end
	if tag == "C3" then return Color3.fromHex(d) end
	if tag == "U2" then return UDim2.new(d[1], d[2], d[3], d[4]) end
	if tag == "CF" then return CFrame.new(table.unpack(d)) end
	if tag == "NR" then return NumberRange.new(d[1], d[2]) end
	if tag == "EI" then return (Enum :: any)[d[1]][d[2]] end
	if tag == "IN" then
		local node = game
		for part in string.gmatch(d, "[^%.]+") do
			node = node and node:FindFirstChild(part)
		end
		return node
	end
	local out = {}
	for k, x in v do out[k] = Codec.decode(x) end
	return out
end

-- STUB endpoint: in-memory only. Replace with your transport (RemoteFunction -> DataStore, etc.).
-- Every function may yield. payload is a JSON string.
local memoryStore = {}
-- Default endpoint: executor filesystem under BloomUI/configs when writefile exists,
-- otherwise falls back to in-session memory. User scripts can override by setting
-- Bloom.ConfigEndpoint = {...} to point at HTTP, DataStore, etc.
local BLOOM_FOLDER  = "BloomUI"
local BLOOM_CFG_DIR = BLOOM_FOLDER .. "/configs"
if makefolder and isfolder then
	if not isfolder(BLOOM_FOLDER)  then pcall(makefolder, BLOOM_FOLDER)  end
	if not isfolder(BLOOM_CFG_DIR) then pcall(makefolder, BLOOM_CFG_DIR) end
end

Bloom.ConfigEndpoint = {
	Save = function(name, payload)
		if writefile then
			local ok = pcall(writefile, BLOOM_CFG_DIR .. "/" .. name .. ".json", payload)
			if ok then return true end
		end
		memoryStore[name] = payload
		return true
	end,
	Load = function(name)
		if readfile and isfile then
			local p = BLOOM_CFG_DIR .. "/" .. name .. ".json"
			if isfile(p) then
				local ok, res = pcall(readfile, p)
				if ok and res then return res end
			end
		end
		return memoryStore[name]
	end,
	List = function()
		local names = {}
		if listfiles and isfolder and isfolder(BLOOM_CFG_DIR) then
			for _, f in ipairs(listfiles(BLOOM_CFG_DIR)) do
				if string.sub(f, -5) == ".json" then
					local n = f:match("([^/\\]+)%.json$")
					if n then table.insert(names, n) end
				end
			end
		end
		-- also include in-memory names (if executor filesystem not available)
		for n in memoryStore do table.insert(names, n) end
		table.sort(names)
		return names
	end,
	Delete = function(name)
		if delfile and isfile then
			local p = BLOOM_CFG_DIR .. "/" .. name .. ".json"
			if isfile(p) then pcall(delfile, p) end
		end
		memoryStore[name] = nil
		return true
	end,
}

function Window:GetConfig()
	local data = {}
	for id, ctl in self.Flags do
		if ctl.Kind ~= "Button" and ctl.Kind ~= "Table" then
			data[id] = Codec.encode(ctl.Value)
		end
	end
	return data
end

function Window:ApplyConfig(data, silent)
	for id, raw in data or {} do
		local ctl = self.Flags[id]
		if ctl then
			local ok, v = pcall(Codec.decode, raw)
			if ok and v ~= nil then ctl:Set(v, silent) end
		end
	end
end

function Window:SaveConfig(name)
	local ok, payload = pcall(HttpService.JSONEncode, HttpService, { v = 1, rivet = Bloom.Version, data = self:GetConfig() })
	if not ok then return false, payload end
	local ok2, err = pcall(Bloom.ConfigEndpoint.Save, name, payload)
	if not ok2 then return false, err end
	return err ~= false, nil
end

function Window:LoadConfig(name)
	local ok, payload = pcall(Bloom.ConfigEndpoint.Load, name)
	if not ok then return false, payload end
	if type(payload) ~= "string" then return false, "not found" end
	local ok2, obj = pcall(HttpService.JSONDecode, HttpService, payload)
	if not ok2 or type(obj) ~= "table" then return false, "corrupt payload" end
	-- apply silently so control callbacks (which usually fire notifications)
	-- don't spam the user with "slider changed", "toggle changed" on every
	-- stored value when loading a saved config.
	self:ApplyConfig(obj.data, true)
	return true
end

function Window:ListConfigs()
	local ok, names = pcall(Bloom.ConfigEndpoint.List)
	return ok and names or {}
end

function Window:DeleteConfig(name)
	local ok, err = pcall(Bloom.ConfigEndpoint.Delete, name)
	return ok, (not ok) and err or nil
end

-- Ready-made sections ------------------------------------------------------
function Tab:ConfigManager(title)
	local win = self.Window
	local sec = self:Section(title or "Configs")
	local nameC = sec:String("__cfg_name", { Label = "Name", Placeholder = "default", MaxLength = 32, Pattern = "^[%w_%-]*$", Save = false })
	local listC = sec:Enum("__cfg_list", { Label = "Saved", Options = win:ListConfigs(), Save = false })
	local function refresh()
		listC:SetOptions(win:ListConfigs())
	end
	local function target()
		local n = nameC.Value ~= "" and nameC.Value or listC.Value
		return n
	end
	sec:Buttons({
		{ Text = "Save", Kind = "primary", Callback = function()
			local n = target() or "default"
			local ok, err = win:SaveConfig(n)
			if ok then
				win:Notify({ Title = "Config saved", Text = "configs/" .. n })
				refresh()
				listC:Set(n, true)
			else
				win:Notify({ Title = "Save failed", Text = tostring(err), Kind = "error" })
			end
		end },
		{ Text = "Load", Callback = function()
			local n = target()
			if not n then return end
			local ok, err = win:LoadConfig(n)
			win:Notify(ok and { Title = "Config loaded", Text = "configs/" .. n, Kind = "info" } or { Title = "Load failed", Text = tostring(err), Kind = "error" })
		end },
		{ Text = "Delete", Kind = "danger", Callback = function()
			local n = target()
			if not n then return end
			win:Dialog({
				Tag = "Delete config", Kind = "error", Title = "Delete «" .. n .. "»?", Text = "This cannot be undone.",
				Buttons = { { Text = Bloom.Strings.Cancel }, { Text = "Delete", Kind = "danger" } },
				Callback = function(i)
					if i == 2 then
						win:DeleteConfig(n)
						refresh()
						win:Notify({ Title = "Config deleted", Text = n, Kind = "warn" })
					end
				end,
			})
		end },
	})
	return sec
end

function Tab:ThemeManager(title)
	local sec = self:Section(title or "Theme")
	local names = {}
	for n in Bloom.Themes do names[#names + 1] = n end
	table.sort(names)
	local accent
	-- Save = true on both now (was false). _startWindowAutoSave includes any
	-- __-prefixed control in the bloom_window slot and re-fires the Callback
	-- on load, so the theme/accent restore properly across sessions.
	sec:Enum("__theme", {
		Label = "Preset", Options = names, Default = current.Name,
		Callback = function(n)
			Bloom:SetTheme(n)
			if accent then accent:Set(current.Accent, true) end
		end,
	})
	accent = sec:Color("__accent", {
		Label = "Accent", Default = current.Accent, Live = false,
		Callback = function(col)
			local t = current:Extend({ Accent = col, TBool = col })
			t.Name = current.Name
			Bloom:SetTheme(t, { Tween = 0.2 })
		end,
	})
	return sec
end

--------------------------------------------------------------------------
-- Modules: several scripts share one window
--------------------------------------------------------------------------
local Module = {}
Module.__index = Module
Bloom.ModuleClass = Module

-- local mod = Bloom:Module({ Name = "world tools", Version = "1.0", Author = "you", Description = "..." })
function Bloom:Module(o)
	if type(o) == "string" then o = { Name = o } end
	return Bloom:GetWindow():_registerModule(o or {})
end

function Window:_registerModule(o)
	local name = o.Name or ("module " .. (#self.Modules + 1))
	for _, old in self.Modules do
		if old.Name == name then
			old:Unload(true) -- the same script ran again: replace it
			break
		end
	end
	local m = setmetatable({
		Window = self, Name = name, Version = o.Version or "", Author = o.Author or "",
		Description = o.Description or "", Icon = o.Icon, Enabled = true, Tabs = {},
		_conns = {}, _on = { Enable = {}, Disable = {}, Unload = {}, ConfigLoaded = {} }, LoadedAt = os.clock(),
	}, Module)
	m.Group = self:_group(name, { Module = m })
	table.insert(self.Modules, m)
	self:_refreshModulesPage()
	if o.Announce then self:Notify({ Title = "module loaded", Text = name, Kind = "info" }) end

	-- AutoConfig: Bloom owns the LoadConfig + autosave lifecycle so scripts
	-- don't reinvent it (and don't race each other's config file). Opt in
	-- via o.AutoConfig = "slot_name" or AutoConfig = true (uses module name).
	if o.AutoConfig then
		local slot = (type(o.AutoConfig) == "string") and o.AutoConfig
			or name:lower():gsub("%s+", "_")
		m._autoConfigSlot = slot
		m:_startAutoConfig()
	end
	return m
end

-- Autosave + load lifecycle owned by Bloom. Guards:
--  * never save until LoadConfig has run (so defaults can't clobber saves)
--  * baseline seeded from POST-load state (not "")
--  * loop stops when the module unloads
function Module:_startAutoConfig()
	local HS = game:GetService("HttpService")
	local slot = self._autoConfigSlot
	local win = self.Window
	local loadDone, lastDump = false, nil
	self._autoConfigAlive = true

	task.defer(function()
		local ok = pcall(function() win:LoadConfig(slot) end)
		-- fire OnConfigLoaded hooks so modules can resync side-effect toggles
		-- (fastmine hookfunction, etc.) that LoadConfig's silent apply skipped
		for _, fn in self._on.ConfigLoaded do pcall(fn, ok) end
		local okE, cur = pcall(function() return HS:JSONEncode(win:GetConfig()) end)
		if okE then lastDump = cur end
		loadDone = true
	end)

	-- helper: do the diff-check + save (shared by event-driven and polling paths)
	local saving = false
	local function trySave()
		if saving or not loadDone or lastDump == nil then return end
		local ok, cur = pcall(function() return HS:JSONEncode(win:GetConfig()) end)
		if ok and cur ~= lastDump then
			saving = true
			lastDump = cur
			pcall(function() win:SaveConfig(slot) end)
			saving = false
		end
	end

	-- EVENT-DRIVEN: fire a debounced save on EVERY control change.
	-- debouncing collapses rapid changes (slider drag, keybind rebind) into one
	-- write; the ~400ms window is short enough that configs are never stale
	-- but long enough that scroll-wheeling a Number control doesn't thrash
	-- the file. Each new change bumps the deadline forward.
	local pending = 0
	local function schedule()
		if not self._autoConfigAlive or self._unloaded then return end
		pending = tick() + 0.4
		task.spawn(function()
			local myDeadline = pending
			while tick() < pending do task.wait(0.1) end
			-- only this spawn's deadline wins; others were superseded
			if pending == myDeadline then trySave() end
		end)
	end
	local sigConn = win.AnyControlChanged:Connect(schedule)

	-- POLLING FALLBACK: still run a slow diff-check every 5s in case something
	-- bypassed _emit (direct state mutation, external script set a flag, etc.)
	task.spawn(function()
		while self._autoConfigAlive and not self._unloaded do
			task.wait(5)
			if lastDump == nil then
				local ok, cur = pcall(function() return HS:JSONEncode(win:GetConfig()) end)
				if ok then lastDump = cur end
			else
				trySave()
			end
		end
	end)

	-- flush on unload, but only if load actually completed
	self:OnUnload(function()
		self._autoConfigAlive = false
		pcall(function() sigConn:Disconnect() end)
		if loadDone and lastDump ~= nil then
			pcall(function() win:SaveConfig(slot) end)
		end
	end)
end

function Module:OnConfigLoaded(fn)
	table.insert(self._on.ConfigLoaded, fn); return self
end

function Module:Tab(o)
	if typeof(o) == "string" then o = { Name = o } end
	o = o or {}
	o.GroupObj = self.Group
	o.Module = self
	local t = self.Window:Tab(o)
	table.insert(self.Tabs, t)
	self.Window:_refreshModulesPage()
	return t
end

function Module:Page(o)
	o = o or {}
	local t = self:Tab(o)
	if o.Build then
		local ok, err = pcall(o.Build, t, Bloom.UI)
		if not ok then warn("[bloom] " .. self.Name .. " page failed: " .. tostring(err)) end
	end
	return t
end

-- connections made through the module are disconnected on unload
function Module:Connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(self._conns, c)
	return c
end

function Module:OnEnable(fn) table.insert(self._on.Enable, fn) return self end
function Module:OnDisable(fn) table.insert(self._on.Disable, fn) return self end
function Module:OnUnload(fn) table.insert(self._on.Unload, fn) return self end

-- Pages of this module get their own background. Pass nil to fall back to the default.
-- mod:SetPattern("rbxassetid://123", { TileSize = 256, Speed = 12, Parallax = 3, Alpha = 0.08, Tint = "Accent" })
function Module:SetPattern(image, opts)
	if image == nil or image == false then
		self.Pattern = nil
	else
		opts = opts or {}
		local P = Bloom.Pattern
		self.Pattern = {
			Image = image, TileSize = opts.TileSize or P.TileSize, Speed = opts.Speed or P.Speed,
			Parallax = opts.Parallax or P.Parallax, Alpha = opts.Alpha, Tint = opts.Tint,
		}
		if image ~= "" then
			task.spawn(function() pcall(ContentProvider.PreloadAsync, ContentProvider, { image }) end)
		end
	end
	local win = self.Window
	if win.Current and win.Current.Module == self then win:_applyPattern(true) end
	return self
end

function Module:Notify(o)
	if type(o) == "string" then o = { Title = o } end
	o.Text = o.Text or self.Name
	return self.Window:Notify(o)
end

function Module:SetEnabled(b)
	if self._unloaded or self.Enabled == b then return end
	self.Enabled = b
	local win = self.Window
	if not b and win.Current and win.Current.Module == self and win._mainTab then win:SelectTab(win._mainTab) end
	win:_setGroupVisible(self.Group, b)
	for _, fn in self._on[b and "Enable" or "Disable"] do task.spawn(fn) end
	win:_refreshModulesPage()
end

function Module:Unload(silent)
	if self._unloaded then return end
	self._unloaded = true
	self.Enabled = false
	for _, fn in self._on.Unload do
		local ok, err = pcall(fn)
		if not ok then warn("[bloom] " .. self.Name .. " unload: " .. tostring(err)) end
	end
	for _, c in self._conns do pcall(function() c:Disconnect() end) end
	local win = self.Window
	for i = #self.Tabs, 1, -1 do win:_removeTab(self.Tabs[i]) end
	win:_removeGroup(self.Group)
	local i = table.find(win.Modules, self)
	if i then table.remove(win.Modules, i) end
	win:_refreshModulesPage()
	if not silent then win:Notify({ Title = "module unloaded", Text = self.Name, Kind = "warn" }) end
end

function Window:_refreshModulesPage()
	self.ModulesChanged:Fire()
	if self._modulesRebuild and not self._rebuildQueued then
		self._rebuildQueued = true
		task.defer(function()
			self._rebuildQueued = false
			if not self._destroyed then self._modulesRebuild() end
		end)
	end
end

--------------------------------------------------------------------------
-- Bloom.UI: building blocks for custom pages (Page{ Build = function(tab, ui) })
--------------------------------------------------------------------------
local UI = {}
Bloom.UI = UI
UI.New, UI.Frame, UI.Label, UI.Paint, UI.Recolor, UI.Tween = new, frame, label, paint, recolor, tween
UI.Corner, UI.Stroke, UI.Padding, UI.List, UI.Chip, UI.Icon = corner, stroke, padding, list, chip, icon
UI.Shadow, UI.Motion, UI.Flower = uiShadow, Motion, Bloom.Flower

local function uiScale()
	local w = shared
	if not w then return 1 end
	return math.max(0.01, w._fit.Scale * w._wscale.Scale)
end

-- section-style caption: "text ———— right"
function UI.Caption(parent, text, right, o)
	o = o or {}
	local line = frame(parent, { Name = "Caption", Size = UDim2.new(1, 0, 0, 22), LayoutOrder = o.Order or 0 })
	local rule = frame(line, { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromScale(0, 0.5), BackgroundTransparency = 0 })
	paint(rule, { BackgroundColor3 = "Stroke" })
	local l = label(line, lc(text), { Size = 15, Font = "Display", Color = "TextDim", Auto = X_AUTO, Dim = UDim2.new(0, 0, 1, 0), Z = 2 })
	l.BackgroundTransparency = 0
	paint(l, { BackgroundColor3 = o.Bg or "Window" })
	padding(l, 0, 10, 0, 0)
	local r = label(line, right or "", { Size = 11, Font = "Mono", Color = "TextFaint", Auto = X_AUTO, Dim = UDim2.new(0, 0, 1, 0), Pos = UDim2.fromScale(1, 0), Anchor = Vector2.new(1, 0), Z = 2, AlignX = ALIGN_R })
	r.BackgroundTransparency = 0
	paint(r, { BackgroundColor3 = o.Bg or "Window" })
	padding(r, 0, 0, 0, 10)
	r.Visible = right ~= nil
	return line, r
end

function UI.Card(parent, o)
	o = o or {}
	local c = frame(parent, { Name = o.Name or "Card", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, BackgroundTransparency = 0, LayoutOrder = o.Order or 0 })
	paint(c, { BackgroundColor3 = o.Bg or "Surface" })
	corner(c, 8)
	stroke(c, "Stroke")
	padding(c, o.Pad or 14)
	list(c, nil, o.Gap or 10)
	return c
end

function UI.Text(parent, text, o)
	o = o or {}
	local l = label(parent, text, { Size = o.Size or 14, Font = o.Font or "Body", Color = o.Color or "TextDim", Wrap = true, Rich = true, Auto = Y_AUTO, Dim = UDim2.new(1, 0, 0, 0), Order = o.Order or 0 })
	if o.LineHeight then l.LineHeight = o.LineHeight end
	return l
end

function UI.Row(parent, o)
	o = o or {}
	local r = frame(parent, { Name = "Row", Size = UDim2.new(1, 0, 0, o.Height or 32), LayoutOrder = o.Order or 0 })
	list(r, HORIZ, o.Gap or 8, V_CENTER, o.Align or Enum.HorizontalAlignment.Left)
	return r
end

-- responsive grid: as many columns of at least minW as fit
function UI.Grid(parent, minW, cellH, gap, o)
	o = o or {}
	gap = gap or 10
	local g = frame(parent, { Name = "Grid", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, LayoutOrder = o.Order or 0 })
	local gl = new("UIGridLayout", { CellPadding = UDim2.fromOffset(gap, gap), CellSize = UDim2.new(0.5, -gap / 2, 0, cellH), SortOrder = Enum.SortOrder.LayoutOrder, Parent = g })
	local function fitCols()
		local w = g.AbsoluteSize.X / uiScale()
		local cols = math.max(1, math.floor((w + gap) / (minW + gap)))
		gl.CellSize = UDim2.new(1 / cols, -gap * (cols - 1) / cols, 0, cellH)
	end
	g:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitCols)
	task.defer(fitCols)
	return g
end

-- metric tile; returns frame and set(value, token?)
function UI.Stat(parent, name, value, o)
	o = o or {}
	local f = frame(parent, { Name = "Stat", BackgroundTransparency = 0, LayoutOrder = o.Order or 0 })
	paint(f, { BackgroundColor3 = "Surface" })
	corner(f, 7)
	stroke(f, "Stroke")
	padding(f, 10, 12, 10, 12)
	label(f, lc(name), { Size = 12, Color = "TextFaint", Dim = UDim2.new(1, 0, 0, 14) })
	local v = label(f, tostring(value or "\u{2014}"), { Size = o.Mono and 15 or 20, Font = o.Mono and "Mono" or "Display", Color = o.Token or "Text", Pos = UDim2.fromOffset(0, 18), Dim = UDim2.new(1, 0, 0, 24), Truncate = true })
	local function set(val, token)
		v.Text = tostring(val)
		if token then recolor(v, "TextColor3", token) end
	end
	return f, set
end

function UI.Button(parent, text, o)
	o = o or {}
	local b = button(parent, text, { Kind = o.Kind or "ghost", Size = o.Size or UDim2.fromOffset(o.Width or 96, o.Height or 30), Order = o.Order or 0, Hint = o.Hint })
	if o.Callback then b.MouseButton1Click:Connect(o.Callback) end
	return b
end

-- compact on/off switch; onChange(bool)
function UI.Switch(parent, value, onChange, o)
	o = o or {}
	local sw = new("TextButton", { Name = "Switch", Text = "", AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.fromOffset(42, 22), LayoutOrder = o.Order or 0, Parent = parent })
	corner(sw, 6)
	local st = stroke(sw, "StrokeStrong")
	local knob = frame(sw, { Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(3, 3), BackgroundTransparency = 0, ZIndex = 2 })
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })
	local api = { Value = false, Button = sw }
	function api.Set(v, animate)
		v = v and true or false
		api.Value = v
		local info = animate and Motion.Hover or nil
		recolor(sw, "BackgroundColor3", v and "Accent" or "Surface", info)
		recolor(st, "Color", v and "Accent" or "StrokeStrong", info)
		recolor(knob, "BackgroundColor3", v and "Accent" or "TextFaint", info)
		local bt = v and 0.85 or 0
		local pos = UDim2.fromOffset(v and 23 or 3, 3)
		if animate then
			tween(sw, Motion.Hover, { BackgroundTransparency = bt })
			tween(knob, Motion.Knob, { Position = pos })
		else
			sw.BackgroundTransparency = bt
			knob.Position = pos
		end
	end
	sw.MouseButton1Click:Connect(function()
		api.Set(not api.Value, true)
		if onChange then task.spawn(onChange, api.Value) end
	end)
	api.Set(value)
	return api
end

function UI.Code(parent, text, o)
	o = o or {}
	local box = frame(parent, { Name = "Code", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y_AUTO, BackgroundTransparency = 0, LayoutOrder = o.Order or 0 })
	paint(box, { BackgroundColor3 = "Bg" })
	corner(box, 6)
	stroke(box, "Stroke")
	padding(box, 10, 12, 10, 12)
	label(box, text, { Size = 13, Font = "Mono", Color = "TextDim", Wrap = true, Auto = Y_AUTO, Dim = UDim2.new(1, 0, 0, 0) })
	return box
end

local function ago(sec)
	sec = math.max(0, math.floor(sec))
	if sec < 60 then return sec .. "s" end
	if sec < 3600 then return math.floor(sec / 60) .. "m" end
	return string.format("%dh %02dm", math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end
UI.Ago = ago

--------------------------------------------------------------------------
-- Built-in pages: bloom / main, bloom / modules
--------------------------------------------------------------------------
local MONO_TAG = '<font family="rbxasset://fonts/families/Inconsolata.json">%s</font>'

function Window:_buildBuiltins()
	local g = self._bloomGroup
	local startClock = os.clock()

	self._mainTab = self:Page({ Name = "main", Icon = "house", GroupObj = g, Build = function(tab, ui)
		local top = tab:Canvas({ Top = 10 })
		local hero = ui.Card(top, { Pad = 18 })
		local row = frame(hero, { Size = UDim2.new(1, 0, 0, 56) })
		local fl = Bloom.Flower(row, 48, { Anchor = Vector2.new(0, 0.5), Pos = UDim2.new(0, 2, 0.5, 0) })
		local who = LocalPlayer and LocalPlayer.DisplayName or "there"
		label(row, "hi, " .. lc(who), { Size = 24, Font = "Display", Pos = UDim2.fromOffset(66, 4), Dim = UDim2.new(1, -66, 0, 28), Truncate = true })
		local sub = label(row, "", { Size = 13, Font = "Mono", Color = "TextFaint", Pos = UDim2.fromOffset(66, 34), Dim = UDim2.new(1, -66, 0, 18), Truncate = true })
		ui.Text(hero, "everything you load into bloom lives here. pages from your scripts show up as groups in the sidebar \u{2014} manage them in <b>bloom / modules</b>.")
		tab._onShow = function() fl.Bloom(0.05) end

		local srv = tab:Canvas()
		ui.Caption(srv, "server")
		local grid = ui.Grid(srv, 130, 64, 10)
		local _, setPlayers = ui.Stat(grid, "players", "", { Order = 1 })
		local _, setPing = ui.Stat(grid, "ping", "", { Order = 2 })
		local _, setFps = ui.Stat(grid, "fps", "", { Order = 3 })
		local _, setUp = ui.Stat(grid, "session", "", { Order = 4 })
		local _, setPlace = ui.Stat(grid, "place", tostring(game.PlaceId), { Order = 5, Mono = true })
		ui.Stat(grid, "server id", game.JobId ~= "" and string.sub(game.JobId, 1, 8) or "studio", { Order = 6, Mono = true })
		local _, setMods = ui.Stat(grid, "modules", "0", { Order = 7, Token = "Accent" })
		local _, setTheme = ui.Stat(grid, "theme", lc(current.Name), { Order = 8 })

		local cli = tab:Canvas()
		ui.Caption(cli, "you")
		local grid2 = ui.Grid(cli, 130, 64, 10)
		ui.Stat(grid2, "user", LocalPlayer and ("@" .. LocalPlayer.Name) or "\u{2014}", { Order = 1, Mono = true })
		ui.Stat(grid2, "user id", LocalPlayer and tostring(LocalPlayer.UserId) or "\u{2014}", { Order = 2, Mono = true })
		ui.Stat(grid2, "account age", LocalPlayer and (LocalPlayer.AccountAge .. "d") or "\u{2014}", { Order = 3 })
		local device = "pc"
		if game:GetService("GuiService"):IsTenFootInterface() then
			device = "console"
		elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
			device = "mobile"
		end
		ui.Stat(grid2, "device", device, { Order = 4 })

		local keys = tab:Canvas({ Bottom = 6 })
		ui.Caption(keys, "shortcuts")
		local kc = ui.Card(keys, { Gap = 6 })
		local keyLine = ui.Text(kc, "", { Font = "Mono", Size = 13, LineHeight = 1.25 })

		local function refreshStatic()
			sub.Text = string.format("bloom ui lib \u{00b7} v%s \u{00b7} %s", Bloom.Version, lc(current.Name))
			setTheme(lc(current.Name))
			keyLine.Text = string.format("%s \u{2014} show / hide\nctrl + k \u{2014} search settings\ndrag the bloom button to move it", lc(self.ToggleKey.Name))
		end
		refreshStatic()
		conn(self, Bloom.ThemeChanged, refreshStatic)
		task.spawn(function()
			local ok, info = pcall(function() return game:GetService("MarketplaceService"):GetProductInfoAsync(game.PlaceId) end)
			if ok and info and info.Name and info.Name ~= "" then setPlace(info.Name) end
		end)
		local acc = 0.5
		conn(self, RunService.Heartbeat, function(dt)
			acc += dt
			if acc < 0.5 then return end
			acc = 0
			if not (self.Visible and self.Current == tab) then return end
			setPlayers(string.format("%d / %d", #Players:GetPlayers(), Players.MaxPlayers))
			local ping = self.Stats.Ping
			setPing(ping and (ping .. " ms") or "\u{2014}", ping and (ping > 200 and "Bad" or ping > 100 and "Warn" or "Ok") or nil)
			setFps(tostring(self.Stats.Fps), self.Stats.Fps < 30 and "Warn" or "Text")
			setUp(ago(os.clock() - startClock))
			setMods(tostring(#self.Modules))
			refreshStatic()
		end)
	end })

	self._modulesTab = self:Page({ Name = "modules", Icon = "layers", GroupObj = g, Build = function(tab, ui)
		local intro = tab:Canvas({ Top = 10 })
		ui.Text(intro, "every script that calls " .. string.format(MONO_TAG, "Bloom:Module()") .. " shares this window. switch a module off to hide its pages and pause it, or unload it to remove it until its script runs again.")
		local listC = tab:Canvas({ Gap = 10 })
		local function rebuild()
			for _, ch in listC:GetChildren() do
				if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then ch:Destroy() end
			end
			ui.Caption(listC, "loaded", string.format("%02d", #self.Modules))
			if #self.Modules == 0 then
				local empty = ui.Card(listC, { Gap = 8, Order = 1 })
				ui.Text(empty, "nothing loaded yet. register a module from any LocalScript:")
				ui.Code(empty, 'local Bloom = require(ReplicatedStorage.Bloom)\nlocal mod = Bloom:Module({ Name = "my tools", Version = "1.0" })\nlocal tab = mod:Tab({ Name = "main" })')
				tab:SetBadge("")
				return
			end
			tab:SetBadge(#self.Modules)
			for i, mod in self.Modules do
				local card = ui.Card(listC, { Gap = 8, Order = i })
				local top = frame(card, { Size = UDim2.new(1, 0, 0, 26) })
				local dot = frame(top, { Size = UDim2.fromOffset(8, 8), Position = UDim2.new(0, 2, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 0 })
				paint(dot, { BackgroundColor3 = mod.Enabled and "Ok" or "TextFaint" })
				new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dot })
				local nameRow = frame(top, { Size = UDim2.new(1, -70, 1, 0), Position = UDim2.fromOffset(18, 0) })
				list(nameRow, HORIZ, 8, V_CENTER)
				label(nameRow, lc(mod.Name), { Size = 17, Font = "Display", Auto = X_AUTO, Dim = UDim2.new(0, 0, 1, 0), Order = 1, Color = mod.Enabled and "Text" or "TextDim" })
				if mod.Version ~= "" then chip(nameRow, "v" .. mod.Version, "TextFaint", { Order = 2 }) end
				if not mod.Enabled then chip(nameRow, "off", "Warn", { Order = 3 }) end
				local sw = ui.Switch(top, mod.Enabled, function(v) mod:SetEnabled(v) end)
				sw.Button.AnchorPoint = Vector2.new(1, 0.5)
				sw.Button.Position = UDim2.new(1, 0, 0.5, 0)
				local meta = {}
				if mod.Author ~= "" then meta[#meta + 1] = "by " .. mod.Author end
				meta[#meta + 1] = #mod.Tabs .. (#mod.Tabs == 1 and " page" or " pages")
				meta[#meta + 1] = "loaded " .. ago(os.clock() - mod.LoadedAt) .. " ago"
				ui.Text(card, table.concat(meta, "  \u{00b7}  "), { Size = 12, Font = "Mono", Color = "TextFaint" })
				if mod.Description ~= "" then ui.Text(card, mod.Description) end
				local actions = ui.Row(card, { Height = 30 })
				ui.Button(actions, "open", { Width = 80, Order = 1, Callback = function()
					if not mod.Enabled then mod:SetEnabled(true) end
					if mod.Tabs[1] then self:SelectTab(mod.Tabs[1]) end
				end })
				ui.Button(actions, "unload", { Kind = "danger", Width = 90, Order = 2, Callback = function()
					self:Dialog({
						Tag = "unload module", Kind = "warn",
						Title = "unload " .. lc(mod.Name) .. "?",
						Text = "its pages disappear and its cleanup runs. it comes back the next time its script runs.",
						Buttons = { { Text = "cancel" }, { Text = "unload", Kind = "danger" } },
						Callback = function(k) if k == 2 then mod:Unload() end end,
					})
				end })
			end
		end
		self._modulesRebuild = rebuild
		rebuild()
		tab._onShow = rebuild
	end })

	local st = self:Tab({ Name = "settings", Icon = "settings", GroupObj = g })
	self._settingsTab = st
	st:ThemeManager("theme")
	local look = st:Section("look")
	-- Save = true on these now (was false, meaning they'd reset every session).
	-- Window-level persistence is handled by _startWindowAutoSave below.
	look:Toggle("__pattern", { Label = "pattern", Default = true, Callback = function(v)
		self._patternOff = not v
		self:_applyPattern(true)
	end })
	look:Number("__pattern_alpha", { Label = "pattern strength", Min = 0, Max = 0.25, Step = 0.01,
		Default = Bloom.Pattern.Alpha or current.PatternAlpha or 0.08, Callback = function(v)
			Bloom.Pattern.Alpha = v
			self:_applyPattern(false)
		end })
	look:Toggle("__border_anim", { Label = "animated border", Default = Bloom.Border.Animated ~= false, Callback = function(v)
		Bloom.Border.Animated = v
	end })
	look:Toggle("__dim", { Label = "dim backdrop", Default = self._useDim, Callback = function(v)
		self._useDim = v
		if self.Visible then
			self._dim.Visible = true
			tween(self._dim, Motion.Dim, { BackgroundTransparency = v and (1 - (current.Dim or 0.3)) or 1 })
		end
	end })
	st:ConfigManager("configs")
	local keys = st:Section("keys")
	keys:Keybind("__toggle_key", { Label = "panel key", Default = self.ToggleKey, AllowToggleKey = true, Callback = function(k)
		if k then self.ToggleKey = k end
	end })

	-- window-level autosave (separate from per-module AutoConfig). loads/saves
	-- just the __-prefixed Bloom chrome settings to a dedicated slot so UI
	-- tweaks persist across sessions regardless of which modules are loaded.
	self:_startWindowAutoSave("bloom_window")
end

-- subset save/load: only persist controls whose id starts with "__" (chrome
-- settings), kept separate from module configs so UI prefs don't collide.
function Window:_startWindowAutoSave(slot)
	local HS = game:GetService("HttpService")
	local loadDone, lastDump = false, nil

	local function snapshot()
		local out = {}
		for id, c in pairs(self.Flags) do
			if type(id) == "string" and id:sub(1, 2) == "__" then
				local ok, v = pcall(function() return c:Get() end)
				if ok then out[id] = v end
			end
		end
		local okE, s = pcall(function() return HS:JSONEncode(out) end)
		return okE and s or nil
	end

	task.defer(function()
		-- try to load existing bloom_window config
		pcall(function() self:LoadConfig(slot) end)
		-- LoadConfig applies values silently (ctl:Set(v, true)), which updates
		-- the visual state but skips the Callback. For Bloom chrome controls
		-- the Callback is what actually APPLIES the side effect (toggles
		-- self._patternOff, mutates Bloom.Pattern.Alpha, re-tweens the dim
		-- overlay, etc.). Without this re-fire the UI shows the saved state
		-- but the engine runs at defaults.
		for id, ctl in pairs(self.Flags) do
			if type(id) == "string" and id:sub(1, 2) == "__" and ctl.Callback then
				local ok, v = pcall(function() return ctl:Get() end)
				if ok then pcall(ctl.Callback, v) end
			end
		end
		lastDump = snapshot()
		loadDone = true
	end)

	-- hook AnyControlChanged, but only save if a __-prefix control changed
	local sigConn = self.AnyControlChanged:Connect(function(ctl)
		if not loadDone or not ctl or not ctl.Id then return end
		if type(ctl.Id) ~= "string" or ctl.Id:sub(1, 2) ~= "__" then return end
		local cur = snapshot()
		if cur and cur ~= lastDump then
			lastDump = cur
			pcall(function() self:SaveConfig(slot) end)
		end
	end)

	self._windowAutosaveConn = sigConn
end

--------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------
function Window:Destroy()
	if self._destroyed then return end
	for i = #self.Modules, 1, -1 do self.Modules[i]:Unload(true) end
	self._destroyed = true
	if shared == self then shared = nil end
	-- clear the singleton cache so a re-inject fetches fresh Bloom source
	if _G.__BloomInstance == Bloom then _G.__BloomInstance = nil end
	self:_closePopup()
	local info = TweenInfo.new(0.3, ES.Quint, ED.In)
	if self.Visible then
		tween(self._win, info, { GroupTransparency = 1 })
		tween(self._back, info, { GroupTransparency = 1 })
		tween(self._border, info, { Transparency = 1 })
		tween(self._wscale, info, { Scale = 0.92 })
		tween(self._shadowUI, info, { Transparency = 1 })
		tween(self._glowUI, info, { Transparency = 1 })
		tween(self._dim, info, { BackgroundTransparency = 1 })
	end
	tween(self._budScale, TweenInfo.new(0.35, ES.Back, ED.In), { Scale = 0 })
	self.Visible = false
	for _, cn in self._conns do cn:Disconnect() end
	self._conns = {}
	self.Keybinds = {}
	local gui = self.Gui
	task.delay(0.4, function() gui:Destroy() end)
end

_G.__BloomInstance = Bloom
_G.__BloomClaim = nil  -- release the build lock; others may now proceed
return Bloom
