-- Discord: treas123, Roblox: TreaS271
-- client weather controller: UI picks the mode, this script drives lighting, rain, wind, and storm flashes
-- everything runs on Heartbeat through one active state (Clear, Rain, Storm, or Fog)

local WeatherDirector = {}

----------[[ SERVICES ]]----------
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

----------[[ CONFIGURATIONS ]]----------
-- Fredoka for the panel, tweak TweenShort or TweenLong if transitions feel too slow
local UiFont = Font.new("rbxasset://fonts/families/FredokaOne.json")

local TweenShort = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TweenLong = TweenInfo.new(3.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- tag loose parts with WindAffected in Studio if you want extra wind props
local WindTag = "WindAffected"
local RainFolderName = "ClientRain"

local TimePresets = {
	Morning = 6.5,
	Noon = 14,
	Evening = 18.5,
	Night = 0,
}

local WeatherKeys = { "Clear", "Rain", "Storm", "Fog" }

----------[[ VARIABLES ]]----------
-- shared refs so we are not calling FindFirstChild every frame
local LocalPlayer = Players.LocalPlayer
local PlayerGui

local Atmosphere
local ColorCorrection

local ActiveState
local StateTable = {}
local TransitionBusy = false

local WindDirection = Vector3.new(1, 0, 0.3).Unit
local WindStrength = 0
local WindTargets = {}

local RainFolder
local RainEmitters = {}
local ThunderTimer = 0
local WindScanTimer = 0

local HeartbeatConn
local StatusLabel
local PanelFrame

-- one raycast params object for lightning, filter list updates before each strike
local CachedRayParams = RaycastParams.new()
CachedRayParams.FilterType = Enum.RaycastFilterType.Exclude
CachedRayParams.IgnoreWater = true

----------[[ WEATHER STATE METATABLE ]]----------
-- each weather type is a state object, shared behavior lives on WeatherState
local WeatherState = {}
WeatherState.__index = WeatherState

-- hooks table lets each weather type override only what it needs
function WeatherState.New(Name, Hooks)
	local Self = setmetatable({}, WeatherState)
	Self.Name = Name
	Self.OnEnter = Hooks.OnEnter
	Self.OnTick = Hooks.OnTick
	Self.OnExit = Hooks.OnExit
	return Self
end

-- Director is the module table, passed in so storm can store LastStrike on it
function WeatherState:Enter(Director)
	if self.OnEnter then
		self.OnEnter(Director)
	end
end

function WeatherState:Tick(Director, Dt)
	if self.OnTick then
		self.OnTick(Director, Dt)
	end
end

function WeatherState:Exit(Director)
	if self.OnExit then
		self.OnExit(Director)
	end
end

----------[[ FUNCTIONS ]]----------
local function GetCharacterRoot()
	local Character = LocalPlayer.Character
	if not Character then
		return nil
	end
	return Character:FindFirstChild("HumanoidRootPart")
end

-- place might not have these yet, create them once so tweens always have a target
local function EnsureLightingObjects()
	Atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not Atmosphere then
		Atmosphere = Instance.new("Atmosphere")
		Atmosphere.Parent = Lighting
	end

	ColorCorrection = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if not ColorCorrection then
		ColorCorrection = Instance.new("ColorCorrectionEffect")
		ColorCorrection.Parent = Lighting
	end
end

local function TweenLighting(Props, Info)
	local Tween = TweenService:Create(Lighting, Info or TweenShort, Props)
	Tween:Play()
	return Tween
end

local function TweenAtmosphere(Props, Info)
	local Tween = TweenService:Create(Atmosphere, Info or TweenShort, Props)
	Tween:Play()
	return Tween
end

-- all emitters share the same on or off and rate so rain feels even
local function SetRainEnabled(Enabled)
	for _, Emitter in RainEmitters do
		if Emitter.Parent then
			Emitter.Enabled = Enabled
		end
	end
end

local function SetRainRate(Rate)
	for _, Emitter in RainEmitters do
		if Emitter.Parent then
			Emitter.Rate = Rate
		end
	end
end

local function UpdateStatus(Text)
	if StatusLabel then
		StatusLabel.Text = Text
	end
end

-- three invisible anchors with particle emitters, rebuilt if Start runs again
local function BuildRainEmitters()
	if RainFolder then
		RainFolder:Destroy()
	end

	RainFolder = Instance.new("Folder")
	RainFolder.Name = RainFolderName
	RainFolder.Parent = workspace

	table.clear(RainEmitters)

	local Offsets = {
		Vector3.new(0, 40, 0),
		Vector3.new(18, 38, 12),
		Vector3.new(-16, 42, -10),
	}

	for Index, Offset in Offsets do
		local Anchor = Instance.new("Part")
		Anchor.Name = "RainAnchor" .. Index
		Anchor.Anchored = true
		Anchor.CanCollide = false
		Anchor.CanQuery = false
		Anchor.CanTouch = false
		Anchor.Transparency = 1
		Anchor.Size = Vector3.new(1, 1, 1)
		Anchor.Parent = RainFolder

		local Attachment = Instance.new("Attachment")
		Attachment.Parent = Anchor

		local Emitter = Instance.new("ParticleEmitter")
		Emitter.Name = "RainEmitter"
		Emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		Emitter.Color = ColorSequence.new(Color3.fromRGB(170, 190, 220))
		Emitter.LightEmission = 0.1
		Emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(1, 0.12),
		})
		Emitter.Lifetime = NumberRange.new(0.6, 1.1)
		Emitter.Speed = NumberRange.new(80, 110)
		Emitter.SpreadAngle = Vector2.new(8, 8)
		Emitter.Acceleration = Vector3.new(0, -120, 0)
		Emitter.Rate = 0
		Emitter.Enabled = false
		Emitter.EmissionDirection = Enum.NormalId.Bottom
		Emitter.Parent = Attachment

		Anchor:SetAttribute("RainOffset", Offset)
		RainEmitters[Index] = Emitter
	end
end

-- anchors sit above the player so rain particles stay around the camera view
local function FollowRainAnchors()
	local Root = GetCharacterRoot()
	if not Root or not RainFolder then
		return
	end

	for _, Anchor in RainFolder:GetChildren() do
		if Anchor:IsA("BasePart") then
			local Offset = Anchor:GetAttribute("RainOffset")
			if typeof(Offset) == "Vector3" then
				Anchor.CFrame = CFrame.new(Root.Position + Offset)
			end
		end
	end
end

-- scan tagged parts every couple seconds instead of every frame
local function RefreshWindTargets()
	table.clear(WindTargets)

	for _, Instance in CollectionService:GetTagged(WindTag) do
		if Instance:IsA("BasePart") and not Instance.Anchored then
			table.insert(WindTargets, Instance)
		end
	end
end

-- nudge velocity on unanchored parts, strength comes from the active weather state
local function ApplyWind(Dt)
	if WindStrength <= 0 then
		return
	end

	local Push = WindDirection * WindStrength * Dt

	for _, Part in WindTargets do
		if Part.Parent then
			Part.AssemblyLinearVelocity = Part.AssemblyLinearVelocity + Push
		end
	end
end

local function PickLightningIgnore()
	local List = { RainFolder }

	local Character = LocalPlayer.Character
	if Character then
		table.insert(List, Character)
	end

	CachedRayParams.FilterDescendantsInstances = List
end

local function StrikeLightning(Director)
	PickLightningIgnore()

	local Root = GetCharacterRoot()
	local Center = Root and Root.Position or Vector3.zero

	local RandomOffset = Vector3.new(math.random(-60, 60), 0, math.random(-60, 60))
	local Origin = Center + RandomOffset + Vector3.new(0, 220, 0)
	local Direction = Vector3.new(0, -400, 0)

	-- raycast down from the sky so lightning actually hits geometry
	local Result = workspace:Raycast(Origin, Direction, CachedRayParams)
	if not Result then
		return
	end

	local HitCFrame = CFrame.new(Result.Position, Result.Position + Result.Normal)

	local Marker = Instance.new("Part")
	Marker.Anchored = true
	Marker.CanCollide = false
	Marker.CanQuery = false
	Marker.CanTouch = false
	Marker.Material = Enum.Material.Neon
	Marker.Color = Color3.fromRGB(240, 245, 255)
	Marker.Size = Vector3.new(0.4, 0.4, 0.4)
	Marker.CFrame = HitCFrame
	Marker.Parent = workspace

	local Flash = Instance.new("PointLight")
	Flash.Name = "ThunderFlash"
	Flash.Brightness = 4
	Flash.Range = 40
	Flash.Color = Color3.fromRGB(220, 230, 255)
	Flash.Parent = Marker

	-- quick flash on the whole screen then clean up the marker part
	ColorCorrection.Brightness = 0.35
	ColorCorrection.Contrast = 0.15

	task.delay(0.08, function()
		ColorCorrection.Brightness = 0
		ColorCorrection.Contrast = 0
	end)

	task.delay(0.35, function()
		if Marker.Parent then
			Marker:Destroy()
		end
	end)

	Director.LastStrike = os.clock()
end

-- small loose parts so reviewers can see wind without setting up the place
local function SpawnDemoWindParts()
	if workspace:FindFirstChild("WeatherDemoBits") then
		return
	end

	local Folder = Instance.new("Folder")
	Folder.Name = "WeatherDemoBits"
	Folder.Parent = workspace

	for Index = 1, 6 do
		local Leaf = Instance.new("Part")
		Leaf.Name = "LooseLeaf" .. Index
		Leaf.Size = Vector3.new(0.8, 0.2, 0.8)
		Leaf.Material = Enum.Material.Grass
		Leaf.Color = Color3.fromRGB(70, 120, 60)
		Leaf.Position = Vector3.new(-15 + Index * 5, 3, 8 + (Index % 3))
		Leaf.Anchored = false
		Leaf.CanCollide = true
		Leaf.Parent = Folder
		CollectionService:AddTag(Leaf, WindTag)
	end

	print("spawned a few loose parts for wind demo")
end

local function MakeUiButton(Parent, Text, Position, Size, Callback)
	local Button = Instance.new("TextButton")
	Button.Name = Text .. "Button"
	Button.Size = Size
	Button.Position = Position
	Button.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
	Button.BorderSizePixel = 0
	Button.Text = Text
	Button.TextColor3 = Color3.fromRGB(235, 235, 240)
	Button.TextSize = 15
	Button.FontFace = UiFont
	Button.AutoButtonColor = true
	Button.Parent = Parent

	local Corner = Instance.new("UICorner")
	Corner.CornerRadius = UDim.new(0, 6)
	Corner.Parent = Button

	Button.MouseButton1Click:Connect(Callback)
	return Button
end

-- builds the whole ScreenGui in code, buttons call SetWeather or SetTime
local function BuildPanel()
	PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

	local Old = PlayerGui:FindFirstChild("WeatherPanel")
	if Old then
		Old:Destroy()
	end

	local Screen = Instance.new("ScreenGui")
	Screen.Name = "WeatherPanel"
	Screen.ResetOnSpawn = false
	Screen.Parent = PlayerGui

	PanelFrame = Instance.new("Frame")
	PanelFrame.Name = "Main"
	PanelFrame.AnchorPoint = Vector2.new(0, 1)
	PanelFrame.Position = UDim2.new(0, 16, 1, -16)
	PanelFrame.Size = UDim2.new(0, 300, 0, 150)
	PanelFrame.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
	PanelFrame.BackgroundTransparency = 0.15
	PanelFrame.BorderSizePixel = 0
	PanelFrame.Parent = Screen

	local PanelCorner = Instance.new("UICorner")
	PanelCorner.CornerRadius = UDim.new(0, 8)
	PanelCorner.Parent = PanelFrame

	local Title = Instance.new("TextLabel")
	Title.Name = "Title"
	Title.BackgroundTransparency = 1
	Title.Position = UDim2.new(0, 12, 0, 8)
	Title.Size = UDim2.new(1, -24, 0, 24)
	Title.FontFace = UiFont
	Title.TextSize = 20
	Title.TextXAlignment = Enum.TextXAlignment.Left
	Title.TextColor3 = Color3.fromRGB(245, 245, 250)
	Title.Text = "weather"
	Title.Parent = PanelFrame

	StatusLabel = Instance.new("TextLabel")
	StatusLabel.Name = "Status"
	StatusLabel.BackgroundTransparency = 1
	StatusLabel.Position = UDim2.new(0, 12, 0, 32)
	StatusLabel.Size = UDim2.new(1, -24, 0, 18)
	StatusLabel.FontFace = UiFont
	StatusLabel.TextSize = 13
	StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	StatusLabel.TextColor3 = Color3.fromRGB(170, 175, 185)
	StatusLabel.Text = "clear"
	StatusLabel.Parent = PanelFrame

	local WeatherRowY = 56
	local ButtonWidth = 68
	local Gap = 6

	-- top row: weather presets hook into the state machine
	for Index, Key in WeatherKeys do
		local X = 10 + (Index - 1) * (ButtonWidth + Gap)
		MakeUiButton(PanelFrame, Key, UDim2.new(0, X, 0, WeatherRowY), UDim2.new(0, ButtonWidth, 0, 28), function()
			WeatherDirector.SetWeather(Key)
		end)
	end

	local TimeLabel = Instance.new("TextLabel")
	TimeLabel.BackgroundTransparency = 1
	TimeLabel.Position = UDim2.new(0, 12, 0, 92)
	TimeLabel.Size = UDim2.new(1, -24, 0, 16)
	TimeLabel.FontFace = UiFont
	TimeLabel.TextSize = 12
	TimeLabel.TextXAlignment = Enum.TextXAlignment.Left
	TimeLabel.TextColor3 = Color3.fromRGB(150, 155, 165)
	TimeLabel.Text = "time"
	TimeLabel.Parent = PanelFrame

	local TimeY = 112
	local TimeWidth = 66
	-- bottom row: only moves ClockTime, does not change weather mode
	for Index, Name in { "Morning", "Noon", "Evening", "Night" } do
		local X = 10 + (Index - 1) * (TimeWidth + Gap)
		MakeUiButton(PanelFrame, Name, UDim2.new(0, X, 0, TimeY), UDim2.new(0, TimeWidth, 0, 24), function()
			WeatherDirector.SetTime(Name)
		end)
	end

	print("weather panel is up")
end

-- time buttons are separate from weather, they only tween Lighting.ClockTime
function WeatherDirector.SetTime(PresetName)
	local Clock = TimePresets[PresetName]
	if not Clock then
		return
	end

	TweenLighting({ ClockTime = Clock }, TweenLong)
	UpdateStatus((ActiveState and ActiveState.Name or "idle") .. " · " .. string.lower(PresetName))
end

-- swap states: exit old one, enter new one, tweens handle the sky look
function WeatherDirector.SetWeather(Name)
	if TransitionBusy then
		return
	end

	local NextState = StateTable[Name]
	if not NextState then
		warn("unknown weather:", Name)
		return
	end

	if ActiveState == NextState then
		return
	end

	TransitionBusy = true

	if ActiveState then
		ActiveState:Exit(WeatherDirector)
	end

	ActiveState = NextState
	ActiveState:Enter(WeatherDirector)

	UpdateStatus(string.lower(Name))
	TransitionBusy = false

	print("switched weather to", Name)
end

-- each block sets wind and rain on enter, per-frame work lives in OnTick
local function RegisterStates()
	StateTable.Clear = WeatherState.New("Clear", {
		OnEnter = function()
			WindStrength = 0
			SetRainEnabled(false)
			SetRainRate(0)

			TweenLighting({ Brightness = 2, FogEnd = 100000, FogStart = 0 }, TweenLong)
			TweenAtmosphere({
				Density = 0.3,
				Offset = 0,
				Color = Color3.fromRGB(199, 210, 228),
				Haze = 0,
				Glare = 0,
			}, TweenLong)
		end,
	})

	-- light rain and breeze
	StateTable.Rain = WeatherState.New("Rain", {
		OnEnter = function()
			WindStrength = 4
			WindDirection = Vector3.new(0.8, 0, 0.2).Unit
			SetRainEnabled(true)
			SetRainRate(140)

			TweenLighting({ Brightness = 1.2, FogEnd = 600, FogStart = 0 }, TweenLong)
			TweenAtmosphere({
				Density = 0.45,
				Offset = 0.2,
				Color = Color3.fromRGB(140, 150, 165),
				Haze = 0.8,
				Glare = 0,
			}, TweenLong)
		end,
		OnTick = function(_, Dt)
			FollowRainAnchors()
			ApplyWind(Dt)
		end,
	})

	-- heavy rain, strong wind, random lightning from OnTick
	StateTable.Storm = WeatherState.New("Storm", {
		OnEnter = function(Director)
			WindStrength = 22
			WindDirection = Vector3.new(1, 0, 0.35).Unit
			SetRainEnabled(true)
			SetRainRate(260)
			ThunderTimer = 0

			TweenLighting({ Brightness = 0.7, FogEnd = 420, FogStart = 0 }, TweenLong)
			TweenAtmosphere({
				Density = 0.55,
				Offset = 0.35,
				Color = Color3.fromRGB(95, 105, 120),
				Haze = 1.2,
				Glare = 0,
			}, TweenLong)

			Director.LastStrike = 0
		end,
		OnTick = function(Director, Dt)
			FollowRainAnchors()
			ApplyWind(Dt)

			ThunderTimer += Dt
			if ThunderTimer > math.random(4, 9) then
				ThunderTimer = 0
				StrikeLightning(Director)
			end
		end,
	})

	-- thick fog via FogEnd and atmosphere haze, no rain
	StateTable.Fog = WeatherState.New("Fog", {
		OnEnter = function()
			WindStrength = 2
			WindDirection = Vector3.new(0.2, 0, 1).Unit
			SetRainEnabled(false)
			SetRainRate(0)

			TweenLighting({ Brightness = 1.4, FogEnd = 120, FogStart = 0 }, TweenLong)
			TweenAtmosphere({
				Density = 0.65,
				Offset = 0.5,
				Color = Color3.fromRGB(180, 185, 190),
				Haze = 2,
				Glare = 0,
			}, TweenLong)
		end,
		OnTick = function(_, Dt)
			ApplyWind(Dt)
		end,
	})
end

-- one connection drives whichever state is active plus the wind target refresh
local function OnHeartbeat(Dt)
	if not ActiveState then
		return
	end

	ActiveState:Tick(WeatherDirector, Dt)

	WindScanTimer += Dt
	if WindScanTimer > 2 then
		WindScanTimer = 0
		RefreshWindTargets()
	end
end

-- called from client once, order matters: lighting objects before tweens
function WeatherDirector.Start()
	EnsureLightingObjects()
	RegisterStates()
	BuildRainEmitters()
	BuildPanel()
	SpawnDemoWindParts()
	RefreshWindTargets()

	HeartbeatConn = RunService.Heartbeat:Connect(OnHeartbeat)

	WeatherDirector.SetWeather("Clear")
	WeatherDirector.SetTime("Noon")

	print("weather director running")
end

return WeatherDirector
