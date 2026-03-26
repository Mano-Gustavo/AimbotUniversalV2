--[[
    ╔══════════════════════════════════════════════════════════╗
    ║       AIMBOT UNIVERSAL v2  —  Powered by Obsidian UI     ║
    ║   Aimbot · ESP · Tracer · Glow · Save/Load · Themes      ║
    ╚══════════════════════════════════════════════════════════╝

    Compatible with: Synapse X, KRNL, Fluxus, Delta, Wave, etc.
    Tested on games with ragdolls, custom cameras and humanoids.
    Aggressive Mode targets ANY entity with health, not just players.
]]

-- ═══════════════════════════════════════════════════════════
-- [1] LIBRARY LOADING
-- ═══════════════════════════════════════════════════════════
local repo        = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library     = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager  = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

local Options  = Library.Options
local Toggles  = Library.Toggles

-- ═══════════════════════════════════════════════════════════
-- [2] SERVICES & GLOBALS
-- ═══════════════════════════════════════════════════════════
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Camera           = workspace.CurrentCamera

local LP      = Players.LocalPlayer
local Mouse   = LP:GetMouse()

-- Drawing objects per player
local ESPObjects   = {}  -- [player] = { Box, BoxOutline, Name, Dist, HealthBg, HealthFill, Tracer }
local GlowObjects  = {}  -- [player] = Highlight instance
-- Aggressive mode: Drawing objects for non-player entities
local AggroESP     = {}  -- [instance] = { Box, BoxOutline, HealthBg, HealthFill }

-- ═══════════════════════════════════════════════════════════
-- [3] UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════

-- Returns true if the player is an ally of LocalPlayer
local function IsAlly(player)
    if not player or player == LP then return true end
    local ok, result = pcall(function()
        return LP.Team ~= nil and player.Team == LP.Team
    end)
    return ok and result or false
end

-- Returns the actual Team color for a player, or nil if unavailable.
local function GetRealTeamColor(player)
    local ok, col = pcall(function()
        return player.Team and player.Team.TeamColor.Color
    end)
    return (ok and col) or nil
end

-- Resolves the display color for a player given option key names.
-- If realTeamColorToggle is enabled and the player has a Team, the
-- game's actual team color is used. Otherwise falls back to custom colors.
local function GetPlayerColor(player, enemyColorKey, allyColorKey, realTeamColorToggleKey)
    local ally = IsAlly(player)
    if realTeamColorToggleKey
        and Toggles[realTeamColorToggleKey]
        and Toggles[realTeamColorToggleKey].Value then
        local col = GetRealTeamColor(player)
        if col then return col end
    end
    if ally then
        return Options[allyColorKey]  and Options[allyColorKey].Value  or Color3.fromRGB(50, 150, 255)
    else
        return Options[enemyColorKey] and Options[enemyColorKey].Value or Color3.fromRGB(255, 50, 50)
    end
end

-- Hides all drawing objects belonging to a player (ESP + Tracer).
local function HideAll(objs)
    for _, obj in pairs(objs) do
        if obj then pcall(function() obj.Visible = false end) end
    end
end

-- Hides only the ESP elements (Box, Name, Dist, HP).
-- Does NOT touch the Tracer — that has its own independent loop.
local function HideESP(objs)
    for _, key in ipairs({"Box","BoxOutline","Name","Dist","HealthBg","HealthFill"}) do
        if objs[key] then pcall(function() objs[key].Visible = false end) end
    end
end

-- Returns the target body part for aimbot with fallback chain
local function GetTargetPart(character, partName)
    if not character then return nil end
    local part = character:FindFirstChild(partName)
    if part and part:IsA("BasePart") then return part end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp end
    for _, v in pairs(character:GetDescendants()) do
        if v:IsA("BasePart") then return v end
    end
    return nil
end

-- Wall Check: casts a ray from the camera to the target part.
-- Returns true only if the first thing hit is the target's model
-- (or nothing is hit at all, meaning clear line of sight).
local function IsVisible(origin, targetPart)
    if not targetPart or not targetPart.Parent then return false end
    local targetPos = targetPart.Position
    local direction = targetPos - origin
    local distance  = direction.Magnitude
    if distance < 0.5 then return true end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = {}
    if LP.Character then table.insert(exclude, LP.Character) end
    -- Also exclude the local player's tool/held objects
    local char = LP.Character
    if char then
        for _, v in pairs(char:GetChildren()) do
            if v:IsA("Tool") then table.insert(exclude, v) end
        end
    end
    params.FilterDescendantsInstances = exclude

    local result = workspace:Raycast(origin, direction.Unit * distance, params)
    if not result then return true end  -- nothing blocking

    local hit = result.Instance
    -- Visible if the hit part belongs to the same model as the target
    local targetModel = targetPart.Parent
    if hit == targetPart then return true end
    if targetModel and hit:IsDescendantOf(targetModel) then return true end

    -- Also accept if hit belongs to any enemy player (they stack but that's fine)
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LP and p.Character and hit:IsDescendantOf(p.Character) then
            return true
        end
    end

    return false
end

-- Returns 2D screen position and whether the point is in front of the camera.
-- IMPORTANT: returns nil if the point is BEHIND the camera (Z <= 0).
local function WorldToScreen(pos)
    local ok, vp = pcall(function()
        return Camera:WorldToViewportPoint(pos)
    end)
    if not ok then return nil, false end
    if vp.Z <= 0 then return nil, false end  -- behind camera — never render
    local onScreen = vp.X >= 0 and vp.X <= Camera.ViewportSize.X
                  and vp.Y >= 0 and vp.Y <= Camera.ViewportSize.Y
    return Vector2.new(vp.X, vp.Y), onScreen, vp.Z
end

-- Safe Drawing constructor
local function NewDrawing(class, props)
    local ok, obj = pcall(Drawing.new, class)
    if not ok then return nil end
    for k, v in pairs(props or {}) do
        pcall(function() obj[k] = v end)
    end
    return obj
end

-- Safe Drawing removal
local function RemoveDrawing(obj)
    if obj then pcall(function() obj:Remove() end) end
end

-- ═══════════════════════════════════════════════════════════
-- [4] ESP — OBJECT CREATION & REMOVAL
-- ═══════════════════════════════════════════════════════════

local function CreateESPForPlayer(player)
    if ESPObjects[player] then return end

    local objs = {}

    -- Box (square around the character)
    objs.Box = NewDrawing("Square", {
        Visible       = false,
        Color         = Color3.new(1, 0, 0),
        Thickness     = 1.5,
        Transparency  = 1,
        Filled        = false,
    })

    -- Box outer outline (black border)
    objs.BoxOutline = NewDrawing("Square", {
        Visible       = false,
        Color         = Color3.new(0, 0, 0),
        Thickness     = 3,
        Transparency  = 1,
        Filled        = false,
    })

    -- Name label
    objs.Name = NewDrawing("Text", {
        Visible       = false,
        Color         = Color3.new(1, 1, 1),
        Size          = 14,
        Center        = true,
        Outline       = true,
        OutlineColor  = Color3.new(0, 0, 0),
        Font          = Drawing.Fonts.UI,
        Text          = player.Name,
        Transparency  = 1,
    })

    -- Distance label
    objs.Dist = NewDrawing("Text", {
        Visible       = false,
        Color         = Color3.fromRGB(220, 220, 220),
        Size          = 12,
        Center        = true,
        Outline       = true,
        OutlineColor  = Color3.new(0, 0, 0),
        Font          = Drawing.Fonts.UI,
        Transparency  = 1,
    })

    -- Health bar background
    objs.HealthBg = NewDrawing("Square", {
        Visible       = false,
        Color         = Color3.fromRGB(20, 20, 20),
        Thickness     = 1,
        Transparency  = 1,
        Filled        = true,
    })

    -- Health bar fill
    objs.HealthFill = NewDrawing("Square", {
        Visible       = false,
        Color         = Color3.fromRGB(50, 255, 50),
        Thickness     = 1,
        Transparency  = 1,
        Filled        = true,
    })

    -- Tracer line
    objs.Tracer = NewDrawing("Line", {
        Visible       = false,
        Color         = Color3.new(1, 0, 0),
        Thickness     = 1,
        Transparency  = 1,
    })

    ESPObjects[player] = objs
end

local function RemoveESPForPlayer(player)
    local objs = ESPObjects[player]
    if not objs then return end
    for _, obj in pairs(objs) do
        RemoveDrawing(obj)
    end
    ESPObjects[player] = nil
end

-- Per-player CharacterAdded connection cache (prevent stacking)
local GlowConnections = {}

-- Creates / re-attaches a Highlight to a player's current character.
local function CreateGlowForPlayer(player)
    -- Destroy any stale highlight first
    if GlowObjects[player] then
        pcall(function() GlowObjects[player]:Destroy() end)
        GlowObjects[player] = nil
    end

    local char = player.Character
    -- Guard: character must exist and be in the DataModel
    if not char or not char.Parent then return end

    local ok, hl = pcall(function()
        local h = Instance.new("Highlight")
        h.FillTransparency    = 0.5
        h.OutlineTransparency = 0
        h.FillColor           = Color3.fromRGB(255, 50, 50)
        h.OutlineColor        = Color3.new(1, 1, 1)
        -- Adorn to character so it follows the rig automatically
        h.Adornee = char
        h.Parent  = char
        return h
    end)
    if not ok or not hl then return end

    GlowObjects[player] = hl

    -- Auto-clean when the highlight loses its parent (e.g. character removed)
    hl.AncestryChanged:Connect(function()
        if hl ~= GlowObjects[player] then return end  -- already replaced
        if not hl.Parent then
            GlowObjects[player] = nil
        end
    end)
end

local function RemoveGlowForPlayer(player)
    local hl = GlowObjects[player]
    if hl then
        pcall(function() hl:Destroy() end)
        GlowObjects[player] = nil
    end
    -- Disconnect stale CharacterAdded connection
    local conn = GlowConnections[player]
    if conn then
        pcall(function() conn:Disconnect() end)
        GlowConnections[player] = nil
    end
end

-- ═══════════════════════════════════════════════════════════
-- [5] WINDOW & TABS
-- ═══════════════════════════════════════════════════════════
local Window = Library:CreateWindow({
    Title          = "Aimbot Universal v2",
    Footer         = "v2.0 — Obsidian UI",
    NotifySide     = "Right",
    ShowCustomCursor = true,
    AutoShow       = true,
    Center         = true,
})

local Tabs = {
    Aimbot   = Window:AddTab("Aimbot",   "crosshair"),
    ESP      = Window:AddTab("ESP",      "eye"),
    Visuals  = Window:AddTab("Visuals",  "sparkles"),
    Settings = Window:AddTab("Settings", "settings"),
}

-- ═══════════════════════════════════════════════════════════
-- [6] AIMBOT TAB
-- ═══════════════════════════════════════════════════════════
local AimLeft  = Tabs.Aimbot:AddLeftGroupbox("Aimbot")
local AimRight = Tabs.Aimbot:AddRightGroupbox("FOV & Filters")

-- Main toggle + keybind
AimLeft:AddToggle("AimbotEnabled", {
    Text    = "Aimbot",
    Default = false,
    Tooltip = "Enable the aimbot",
}):AddKeyPicker("AimbotKey", {
    Text    = "Aimbot Key",
    Default = "None",
    Mode    = "Hold",
    NoUI    = false,
})

AimLeft:AddToggle("AimbotWallCheck", {
    Text    = "Wall Check",
    Default = false,
    Tooltip = "Only aim at targets not hidden behind walls",
})

AimLeft:AddToggle("AimbotTeamCheck", {
    Text    = "Team Check",
    Default = false,
    Tooltip = "Ignore teammates",
})

AimLeft:AddToggle("AimbotAggressiveMode", {
    Text    = "Aggressive Mode",
    Default = false,
    Tooltip = "Target ANY entity with health, not just players. Works across different game structures.",
    Risky   = true,
})

AimLeft:AddSlider("AimbotSmooth", {
    Text     = "Smoothness",
    Default  = 10,
    Min      = 1,
    Max      = 100,
    Rounding = 0,
    Suffix   = "%",
    Tooltip  = "Higher = smoother but slower",
})

AimLeft:AddDropdown("AimbotHitbox", {
    Text    = "Hitbox",
    Values  = { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso" },
    Default = 1,
    Tooltip = "Body part to aim at",
})

AimLeft:AddDivider()
AimLeft:AddLabel("FOV Circle"):AddColorPicker("AimbotFOVColor", {
    Default = Color3.fromRGB(255, 255, 255),
    Title   = "FOV Color",
})

-- FOV settings
AimRight:AddToggle("AimbotFOVEnabled", {
    Text    = "Show FOV Circle",
    Default = false,
    Tooltip = "Draw the FOV circle on screen",
})

AimRight:AddSlider("AimbotFOVRadius", {
    Text     = "FOV Radius",
    Default  = 120,
    Min      = 10,
    Max      = 600,
    Rounding = 0,
    Suffix   = "px",
    Tooltip  = "FOV circle radius in pixels",
})

AimRight:AddSlider("AimbotFOVThickness", {
    Text     = "FOV Thickness",
    Default  = 1,
    Min      = 1,
    Max      = 5,
    Rounding = 0,
})

AimRight:AddDivider()
AimRight:AddLabel("Prediction")

AimRight:AddToggle("AimbotPredict", {
    Text    = "Movement Prediction",
    Default = false,
    Tooltip = "Predict target future position",
})

AimRight:AddSlider("AimbotPredictFactor", {
    Text     = "Prediction Factor",
    Default  = 2,
    Min      = 1,
    Max      = 20,
    Rounding = 1,
})

-- FOV Circle (Drawing)
local FOVCircle = NewDrawing("Circle", {
    Visible     = false,
    Radius      = 120,
    Color       = Color3.new(1, 1, 1),
    Thickness   = 1,
    Transparency = 1,
    Filled      = false,
    NumSides    = 64,
})

-- ═══════════════════════════════════════════════════════════
-- [7] ESP TAB
-- ═══════════════════════════════════════════════════════════
local ESPLeft  = Tabs.ESP:AddLeftGroupbox("ESP")
local ESPRight = Tabs.ESP:AddRightGroupbox("Colors & Style")

ESPLeft:AddToggle("ESPEnabled", {
    Text    = "ESP Enabled",
    Default = false,
    Tooltip = "Enable the entire ESP system",
})

ESPLeft:AddDivider()
ESPLeft:AddLabel("Elements")

ESPLeft:AddToggle("ESPBox", {
    Text    = "Box ESP",
    Default = false,
    Tooltip = "Draw box around players",
})

ESPLeft:AddToggle("ESPName", {
    Text    = "Name",
    Default = false,
    Tooltip = "Show player name",
})

ESPLeft:AddToggle("ESPDistance", {
    Text    = "Distance",
    Default = false,
    Tooltip = "Show distance in meters",
})

ESPLeft:AddToggle("ESPHealthBar", {
    Text    = "Health Bar",
    Default = false,
    Tooltip = "Show styled health bar",
})

ESPLeft:AddDivider()
ESPLeft:AddLabel("Options")

ESPLeft:AddToggle("ESPTeamColor", {
    Text    = "Team Color",
    Default = false,
    Tooltip = "Allies in blue, enemies in red",
})

ESPLeft:AddToggle("ESPTeamCheck", {
    Text    = "Team Check",
    Default = false,
    Tooltip = "Only show ESP for enemies — hide teammates completely",
})

ESPLeft:AddToggle("ESPWallCheck", {
    Text    = "Wall Check",
    Default = false,
    Tooltip = "Only show ESP for players not hidden behind walls",
})

ESPLeft:AddToggle("ESPRealTeamColor", {
    Text    = "Real Team Color",
    Default = false,
    Tooltip = "Use the game's actual team color instead of custom colors",
})

ESPLeft:AddSlider("ESPMaxDistance", {
    Text     = "Max Distance",
    Default  = 1000,
    Min      = 50,
    Max      = 3000,
    Rounding = 0,
    Suffix   = "m",
    Tooltip  = "Maximum distance to display ESP",
})

ESPLeft:AddSlider("ESPBoxThickness", {
    Text     = "Box Thickness",
    Default  = 1,
    Min      = 1,
    Max      = 5,
    Rounding = 0,
})

ESPLeft:AddSlider("ESPNameSize", {
    Text     = "Name Size",
    Default  = 14,
    Min      = 8,
    Max      = 24,
    Rounding = 0,
})

-- ESP Colors
ESPRight:AddLabel("Enemy"):AddColorPicker("ESPEnemyColor", {
    Default = Color3.fromRGB(255, 50, 50),
    Title   = "Enemy Color",
})

ESPRight:AddLabel("Ally"):AddColorPicker("ESPAllyColor", {
    Default = Color3.fromRGB(50, 150, 255),
    Title   = "Ally Color",
})

ESPRight:AddLabel("Name"):AddColorPicker("ESPNameColor", {
    Default = Color3.fromRGB(255, 255, 255),
    Title   = "Name Color",
})

ESPRight:AddLabel("Distance"):AddColorPicker("ESPDistColor", {
    Default = Color3.fromRGB(200, 200, 200),
    Title   = "Distance Color",
})

ESPRight:AddLabel("HP High"):AddColorPicker("ESPHPHighColor", {
    Default = Color3.fromRGB(50, 255, 50),
    Title   = "HP High Color",
})

ESPRight:AddLabel("HP Low"):AddColorPicker("ESPHPLowColor", {
    Default = Color3.fromRGB(255, 50, 50),
    Title   = "HP Low Color",
})

-- ═══════════════════════════════════════════════════════════
-- [8] VISUALS TAB (TRACER + GLOW)
-- ═══════════════════════════════════════════════════════════
local TracerGroup = Tabs.Visuals:AddLeftGroupbox("Tracer")
local GlowGroup   = Tabs.Visuals:AddRightGroupbox("Glow / Chams")

-- TRACER
TracerGroup:AddToggle("TracerEnabled", {
    Text    = "Tracer",
    Default = false,
    Tooltip = "Draw lines from screen to players",
})

TracerGroup:AddDropdown("TracerOrigin", {
    Text    = "Origin",
    Values  = { "Screen Center", "Mouse Cursor", "Screen Bottom" },
    Default = 1,
    Tooltip = "Where the tracer lines originate from",
})

TracerGroup:AddSlider("TracerThickness", {
    Text     = "Thickness",
    Default  = 1,
    Min      = 1,
    Max      = 6,
    Rounding = 0,
})

TracerGroup:AddToggle("TracerTeamCheck", {
    Text    = "Team Check",
    Default = false,
    Tooltip = "Only draw tracers for enemies — hide teammates",
})

TracerGroup:AddToggle("TracerTeamColor", {
    Text    = "Team Color",
    Default = false,
})

TracerGroup:AddToggle("TracerRealTeamColor", {
    Text    = "Real Team Color",
    Default = false,
    Tooltip = "Use the game's actual team color for tracers",
})

TracerGroup:AddLabel("Enemy"):AddColorPicker("TracerEnemyColor", {
    Default = Color3.fromRGB(255, 50, 50),
    Title   = "Enemy Tracer Color",
})

TracerGroup:AddLabel("Ally"):AddColorPicker("TracerAllyColor", {
    Default = Color3.fromRGB(50, 150, 255),
    Title   = "Ally Tracer Color",
})

-- GLOW
GlowGroup:AddToggle("GlowEnabled", {
    Text    = "Glow / Highlight",
    Default = false,
    Tooltip = "Apply Highlight effect on player characters",
})

GlowGroup:AddToggle("GlowEnemy", {
    Text    = "On Enemies",
    Default = false,
})

GlowGroup:AddToggle("GlowAlly", {
    Text    = "On Allies",
    Default = false,
})

GlowGroup:AddToggle("GlowTeamCheck", {
    Text    = "Team Check",
    Default = false,
    Tooltip = "Only apply glow to enemies — skip teammates",
})

GlowGroup:AddToggle("GlowTeamColor", {
    Text    = "Team Color",
    Default = false,
    Tooltip = "Use different colors for allies and enemies",
})

GlowGroup:AddToggle("GlowRealTeamColor", {
    Text    = "Real Team Color",
    Default = false,
    Tooltip = "Use the game's actual team color for glow",
})

GlowGroup:AddSlider("GlowFillTransp", {
    Text     = "Fill Transparency",
    Default  = 70,
    Min      = 0,
    Max      = 100,
    Rounding = 0,
    Suffix   = "%",
})

GlowGroup:AddSlider("GlowOutlineTransp", {
    Text     = "Outline Transparency",
    Default  = 0,
    Min      = 0,
    Max      = 100,
    Rounding = 0,
    Suffix   = "%",
})

GlowGroup:AddLabel("Enemy Fill"):AddColorPicker("GlowEnemyFill", {
    Default = Color3.fromRGB(255, 50, 50),
    Title   = "Glow Enemy Fill",
})

GlowGroup:AddLabel("Ally Fill"):AddColorPicker("GlowAllyFill", {
    Default = Color3.fromRGB(50, 150, 255),
    Title   = "Glow Ally Fill",
})

GlowGroup:AddLabel("Outline"):AddColorPicker("GlowOutlineColor", {
    Default = Color3.fromRGB(255, 255, 255),
    Title   = "Glow Outline",
})

-- ═══════════════════════════════════════════════════════════
-- [9] SETTINGS TAB
-- ═══════════════════════════════════════════════════════════
local MenuGroup = Tabs.Settings:AddLeftGroupbox("Menu", "wrench")

MenuGroup:AddToggle("KeybindMenuOpen", {
    Default  = Library.KeybindFrame.Visible,
    Text     = "Keybind Menu",
    Callback = function(v) Library.KeybindFrame.Visible = v end,
})

MenuGroup:AddToggle("ShowCustomCursor", {
    Text     = "Custom Cursor",
    Default  = false,
    Callback = function(v) Library.ShowCustomCursor = v end,
})

MenuGroup:AddDropdown("NotifSide", {
    Text     = "Notification Side",
    Values   = { "Left", "Right" },
    Default  = "Right",
    Callback = function(v) Library:SetNotifySide(v) end,
})

MenuGroup:AddSlider("UICorner", {
    Text     = "Corner Radius",
    Default  = Library.CornerRadius,
    Min      = 0,
    Max      = 20,
    Rounding = 0,
    Callback = function(v) Window:SetCornerRadius(v) end,
})

MenuGroup:AddDivider()
MenuGroup:AddLabel("Menu Keybind"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift",
    NoUI    = true,
    Text    = "Toggle Menu",
})

MenuGroup:AddButton({
    Text    = "Unload Script",
    Func    = function() Library:Unload() end,
    Risky   = true,
    Tooltip = "Completely removes the script",
})

Library.ToggleKeybind = Options.MenuKeybind

-- Save manager only (no theme UI exposed to user)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
ThemeManager:SetFolder("PhantomCheat")
SaveManager:SetFolder("PhantomCheat/configs")
SaveManager:BuildConfigSection(Tabs.Settings)
-- Apply Monokai theme + Fantasy font silently (no UI for theme selection)
pcall(function()
    Library.Scheme.BackgroundColor = Color3.fromRGB(39,  40,  34)   -- #272822
    Library.Scheme.MainColor       = Color3.fromRGB(62,  61,  50)   -- #3E3D32
    Library.Scheme.AccentColor     = Color3.fromRGB(166, 226, 46)   -- #A6E22E
    Library.Scheme.OutlineColor    = Color3.fromRGB(73,  72,  62)   -- #49483E
    Library.Scheme.FontColor       = Color3.fromRGB(248, 248, 242)  -- #F8F8F2
    Library:SetFont(Enum.Font.Fantasy)
    Library:UpdateColorsUsingRegistry()
end)
SaveManager:LoadAutoloadConfig()

-- ═══════════════════════════════════════════════════════════
-- [10] AIMBOT LOGIC
-- ═══════════════════════════════════════════════════════════

-- Scans workspace for all Humanoid instances not belonging to players.
-- Used by Aggressive Mode.
local function GetAggressiveTargets()
    local targets = {}
    -- Collect character models that belong to players (to exclude)
    local playerChars = {}
    for _, p in pairs(Players:GetPlayers()) do
        if p.Character then playerChars[p.Character] = true end
    end

    for _, obj in pairs(workspace:GetDescendants()) do
        if obj:IsA("Humanoid") and obj.Health > 0 then
            local model = obj.Parent
            if model and not playerChars[model] then
                -- Skip LP's own character
                if model ~= LP.Character then
                    table.insert(targets, obj)
                end
            end
        end
    end
    return targets
end

-- Returns the best aimbot target (BasePart) within FOV
local function GetAimbotTarget()
    local camPos       = Camera.CFrame.Position
    local centerScreen = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local fovRadius    = Options.AimbotFOVRadius.Value
    local hitboxName   = Options.AimbotHitbox.Value
    local wallCheck    = Toggles.AimbotWallCheck.Value
    local teamCheck    = Toggles.AimbotTeamCheck.Value
    local aggressive   = Toggles.AimbotAggressiveMode.Value

    local best, bestDist = nil, math.huge

    -- ── Player targets ────────────────────────────────────
    for _, player in pairs(Players:GetPlayers()) do
        if player == LP then continue end
        if teamCheck and IsAlly(player) then continue end

        local char = player.Character
        if not char then continue end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then continue end

        local part = GetTargetPart(char, hitboxName)
        if not part then continue end

        local screenPos, onScreen = WorldToScreen(part.Position)
        if not screenPos then continue end  -- behind camera

        local dist2D = (screenPos - centerScreen).Magnitude
        if dist2D > fovRadius then continue end

        if wallCheck and not IsVisible(camPos, part) then continue end

        if dist2D < bestDist then
            best     = part
            bestDist = dist2D
        end
    end

    -- ── Aggressive Mode: non-player entities ─────────────
    if aggressive then
        for _, hum in pairs(GetAggressiveTargets()) do
            local model = hum.Parent
            if not model then continue end

            -- Try to find a good target part
            local part = model:FindFirstChild(hitboxName)
                      or model:FindFirstChild("HumanoidRootPart")
                      or model:FindFirstChild("Head")
            if not part then
                -- Fall back to any BasePart in the model
                for _, v in pairs(model:GetDescendants()) do
                    if v:IsA("BasePart") then part = v; break end
                end
            end
            if not part then continue end

            local screenPos, onScreen = WorldToScreen(part.Position)
            if not screenPos then continue end

            local dist2D = (screenPos - centerScreen).Magnitude
            if dist2D > fovRadius then continue end

            if wallCheck and not IsVisible(camPos, part) then continue end

            if dist2D < bestDist then
                best     = part
                bestDist = dist2D
            end
        end
    end

    return best
end

-- Aimbot render loop
RunService.Heartbeat:Connect(function()
    -- Update FOV Circle
    if FOVCircle then
        local showFOV = Toggles.AimbotFOVEnabled and Toggles.AimbotFOVEnabled.Value
        FOVCircle.Visible   = showFOV
        FOVCircle.Radius    = Options.AimbotFOVRadius    and Options.AimbotFOVRadius.Value    or 120
        FOVCircle.Color     = Options.AimbotFOVColor     and Options.AimbotFOVColor.Value     or Color3.new(1,1,1)
        FOVCircle.Thickness = Options.AimbotFOVThickness and Options.AimbotFOVThickness.Value or 1
        FOVCircle.Position  = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end

    local aimbotOn = Toggles.AimbotEnabled and Toggles.AimbotEnabled.Value
    local keyState = Options.AimbotKey     and Options.AimbotKey:GetState()
    if not aimbotOn or not keyState then return end

    local target = GetAimbotTarget()
    if not target then return end

    local camCF     = Camera.CFrame
    local targetPos = target.Position

    -- Movement prediction
    if Toggles.AimbotPredict and Toggles.AimbotPredict.Value then
        local ok, vel = pcall(function() return target.Velocity end)
        if ok and vel then
            local factor = Options.AimbotPredictFactor and Options.AimbotPredictFactor.Value or 2
            targetPos = targetPos + vel * (factor / 60)
        end
    end

    local targetCF = CFrame.new(camCF.Position, targetPos)
    local smooth   = Options.AimbotSmooth and Options.AimbotSmooth.Value or 10
    local alpha    = math.clamp(smooth / 100, 0.01, 1)
    local newCF    = camCF:Lerp(targetCF, alpha)

    pcall(function() Camera.CFrame = newCF end)
end)

-- ═══════════════════════════════════════════════════════════
-- [11] ESP + TRACER RENDER LOOP
-- ═══════════════════════════════════════════════════════════

-- Initialize ESP for all current players
for _, player in pairs(Players:GetPlayers()) do
    if player ~= LP then CreateESPForPlayer(player) end
end

-- New players joining
Players.PlayerAdded:Connect(function(player)
    CreateESPForPlayer(player)
    SetupGlowHook(player)
end)

-- Players leaving
Players.PlayerRemoving:Connect(function(player)
    RemoveESPForPlayer(player)
    RemoveGlowForPlayer(player)
end)

-- Rebuild ESP if LP respawns
if LP then
    LP.CharacterAdded:Connect(function()
        task.wait(0.5)
        for _, player in pairs(Players:GetPlayers()) do
            if player ~= LP and not ESPObjects[player] then
                CreateESPForPlayer(player)
            end
        end
    end)
end

-- Main ESP render loop (RenderStepped = synced with camera)
RunService.RenderStepped:Connect(function()
    local espOn  = Toggles.ESPEnabled and Toggles.ESPEnabled.Value
    local camPos = Camera.CFrame.Position

    for _, player in pairs(Players:GetPlayers()) do
        if player == LP then continue end

        local objs = ESPObjects[player]
        if not objs then continue end

        local char = player.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")

        -- Gate: ESP off, character missing, or dead
        if not espOn or not char or not hrp or not hum or hum.Health <= 0 then
            HideESP(objs)
            continue
        end

        -- Team Check: skip allies when enabled
        local isAlly = IsAlly(player)
        if Toggles.ESPTeamCheck and Toggles.ESPTeamCheck.Value and isAlly then
            HideESP(objs)
            continue
        end

        -- Critical Z-check: skip if HRP is behind the camera
        local ok_vp, hrpVP = pcall(function()
            return Camera:WorldToViewportPoint(hrp.Position)
        end)
        if not ok_vp or hrpVP.Z <= 0 then
            HideESP(objs)
            continue
        end

        local worldPos = hrp.Position
        local dist3D   = (camPos - worldPos).Magnitude

        -- Max distance check
        local maxDist = Options.ESPMaxDistance and Options.ESPMaxDistance.Value or 1000
        if dist3D > maxDist then
            HideESP(objs)
            continue
        end

        -- Wall Check
        if Toggles.ESPWallCheck and Toggles.ESPWallCheck.Value then
            if not IsVisible(camPos, hrp) then
                HideESP(objs)
                continue
            end
        end

        -- Compute screen bounding box via model GetBoundingBox
        local topWorld, botWorld
        local ok_bb, cf_bb, sz_bb = pcall(function() return char:GetBoundingBox() end)
        if ok_bb and cf_bb and sz_bb then
            local halfH = sz_bb.Y / 2
            local center = cf_bb.Position
            topWorld = center + Vector3.new(0,  halfH + 0.1, 0)
            botWorld = center + Vector3.new(0, -halfH,       0)
        else
            local head = char:FindFirstChild("Head")
            topWorld = head and (head.Position + Vector3.new(0, head.Size.Y / 2 + 0.1, 0))
                            or  (worldPos + Vector3.new(0, 3.2, 0))
            botWorld = worldPos + Vector3.new(0, -3.2, 0)
        end

        local topScreen = WorldToScreen(topWorld)
        local botScreen = WorldToScreen(botWorld)

        if not topScreen or not botScreen then
            HideESP(objs)
            continue
        end

        if topScreen.Y > botScreen.Y then
            topScreen, botScreen = botScreen, topScreen
        end

        local boxH = math.max(botScreen.Y - topScreen.Y, 2)
        local boxW = boxH * 0.55
        local midX = (topScreen.X + botScreen.X) / 2
        local boxX = math.floor(midX - boxW / 2)
        local boxY = math.floor(topScreen.Y)
        boxW       = math.floor(boxW)
        boxH       = math.floor(boxH)

        -- Resolve main color (real team color → team color toggle → default)
        local mainColor
        if Toggles.ESPTeamColor and Toggles.ESPTeamColor.Value then
            mainColor = GetPlayerColor(player, "ESPEnemyColor", "ESPAllyColor", "ESPRealTeamColor")
        else
            -- No team color toggle: still respect real team color if enabled
            if Toggles.ESPRealTeamColor and Toggles.ESPRealTeamColor.Value then
                mainColor = GetRealTeamColor(player)
                        or (Options.ESPEnemyColor and Options.ESPEnemyColor.Value)
                        or Color3.fromRGB(255, 50, 50)
            else
                mainColor = Options.ESPEnemyColor and Options.ESPEnemyColor.Value or Color3.fromRGB(255, 50, 50)
            end
        end

        -- ── BOX ─────────────────────────────────────────────────────
        if objs.Box and objs.BoxOutline then
            local showBox = Toggles.ESPBox and Toggles.ESPBox.Value
            local thick   = Options.ESPBoxThickness and Options.ESPBoxThickness.Value or 1
            pcall(function()
                objs.BoxOutline.Visible   = showBox
                objs.BoxOutline.Position  = Vector2.new(boxX - 1, boxY - 1)
                objs.BoxOutline.Size      = Vector2.new(boxW + 2, boxH + 2)
                objs.BoxOutline.Thickness = thick + 2
                objs.BoxOutline.Color     = Color3.new(0, 0, 0)

                objs.Box.Visible   = showBox
                objs.Box.Position  = Vector2.new(boxX, boxY)
                objs.Box.Size      = Vector2.new(boxW, boxH)
                objs.Box.Thickness = thick
                objs.Box.Color     = mainColor
            end)
        end

        -- ── NAME ────────────────────────────────────────────────────
        if objs.Name then
            local showName = Toggles.ESPName and Toggles.ESPName.Value
            local nameSize = Options.ESPNameSize and Options.ESPNameSize.Value or 14
            pcall(function()
                objs.Name.Visible  = showName
                objs.Name.Position = Vector2.new(boxX + boxW / 2, boxY - nameSize - 3)
                objs.Name.Size     = nameSize
                objs.Name.Color    = Options.ESPNameColor and Options.ESPNameColor.Value or Color3.new(1,1,1)
                objs.Name.Text     = player.DisplayName ~= player.Name
                    and (player.DisplayName .. " [" .. player.Name .. "]")
                    or  player.Name
            end)
        end

        -- ── DISTANCE ────────────────────────────────────────────────
        if objs.Dist then
            local showDist = Toggles.ESPDistance and Toggles.ESPDistance.Value
            local distM    = math.floor(dist3D / 3.5)
            pcall(function()
                objs.Dist.Visible  = showDist
                objs.Dist.Position = Vector2.new(boxX + boxW / 2, boxY + boxH + 4)
                objs.Dist.Size     = 12
                objs.Dist.Color    = Options.ESPDistColor and Options.ESPDistColor.Value or Color3.fromRGB(200,200,200)
                objs.Dist.Text     = distM .. "m"
            end)
        end

        -- ── HEALTH BAR ──────────────────────────────────────────────
        if objs.HealthBg and objs.HealthFill then
            local showHP  = Toggles.ESPHealthBar and Toggles.ESPHealthBar.Value
            local hp      = hum.Health
            local maxHP   = math.max(hum.MaxHealth, 1)
            local hpRatio = math.clamp(hp / maxHP, 0, 1)
            local hiCol   = Options.ESPHPHighColor and Options.ESPHPHighColor.Value or Color3.fromRGB(50,255,50)
            local loCol   = Options.ESPHPLowColor  and Options.ESPHPLowColor.Value  or Color3.fromRGB(255,50,50)
            local hpCol   = hiCol:Lerp(loCol, 1 - hpRatio)
            local barW    = 4
            local barX    = boxX - barW - 2
            local fillH   = math.max(math.floor(boxH * hpRatio), 1)
            pcall(function()
                objs.HealthBg.Visible  = showHP
                objs.HealthBg.Position = Vector2.new(barX, boxY)
                objs.HealthBg.Size     = Vector2.new(barW, boxH)
                objs.HealthBg.Color    = Color3.fromRGB(20, 20, 20)
                objs.HealthFill.Visible  = showHP
                objs.HealthFill.Position = Vector2.new(barX, boxY + boxH - fillH)
                objs.HealthFill.Size     = Vector2.new(barW, fillH)
                objs.HealthFill.Color    = hpCol
            end)
        end
    end
end)

-- ── TRACER — fully independent render loop ───────────────────────────────
-- This loop runs regardless of whether ESP is on. Each player's tracer
-- has its own set of checks: enabled, team check, alive, in front of camera.
RunService.RenderStepped:Connect(function()
    local tracerOn = Toggles.TracerEnabled and Toggles.TracerEnabled.Value
    local camPos   = Camera.CFrame.Position
    local vpSize   = Camera.ViewportSize

    for _, player in pairs(Players:GetPlayers()) do
        if player == LP then continue end

        local objs = ESPObjects[player]
        if not objs or not objs.Tracer then continue end

        local char = player.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")

        -- Gate: tracer off, character/health unavailable
        if not tracerOn or not char or not hrp or not hum or hum.Health <= 0 then
            pcall(function() objs.Tracer.Visible = false end)
            continue
        end

        -- Team Check: skip allies when enabled
        local isAlly = IsAlly(player)
        if Toggles.TracerTeamCheck and Toggles.TracerTeamCheck.Value and isAlly then
            pcall(function() objs.Tracer.Visible = false end)
            continue
        end

        -- Z-check: player must be in front of camera
        local ok_vp, vp = pcall(function() return Camera:WorldToViewportPoint(hrp.Position) end)
        if not ok_vp or vp.Z <= 0 then
            pcall(function() objs.Tracer.Visible = false end)
            continue
        end

        -- Compute target screen point (feet of character)
        local botWorld
        local ok_bb, cf_bb, sz_bb = pcall(function() return char:GetBoundingBox() end)
        if ok_bb and cf_bb and sz_bb then
            botWorld = cf_bb.Position + Vector3.new(0, -sz_bb.Y / 2, 0)
        else
            botWorld = hrp.Position + Vector3.new(0, -3.2, 0)
        end

        local botScreen = WorldToScreen(botWorld)
        if not botScreen then
            pcall(function() objs.Tracer.Visible = false end)
            continue
        end

        -- Origin point
        local originMode = Options.TracerOrigin and Options.TracerOrigin.Value
        local origin
        if originMode == "Mouse Cursor" then
            origin = Vector2.new(Mouse.X, Mouse.Y)
        elseif originMode == "Screen Bottom" then
            origin = Vector2.new(vpSize.X / 2, vpSize.Y)
        else
            origin = Vector2.new(vpSize.X / 2, vpSize.Y / 2)
        end

        -- Color (real team → team color toggle → default)
        local tracerColor
        if Toggles.TracerTeamColor and Toggles.TracerTeamColor.Value then
            tracerColor = GetPlayerColor(player, "TracerEnemyColor", "TracerAllyColor", "TracerRealTeamColor")
        else
            if Toggles.TracerRealTeamColor and Toggles.TracerRealTeamColor.Value then
                tracerColor = GetRealTeamColor(player)
                          or (Options.TracerEnemyColor and Options.TracerEnemyColor.Value)
                          or Color3.fromRGB(255, 50, 50)
            else
                tracerColor = Options.TracerEnemyColor and Options.TracerEnemyColor.Value or Color3.fromRGB(255, 50, 50)
            end
        end

        pcall(function()
            objs.Tracer.Visible   = true
            objs.Tracer.From      = origin
            objs.Tracer.To        = botScreen
            objs.Tracer.Thickness = Options.TracerThickness and Options.TracerThickness.Value or 1
            objs.Tracer.Color     = tracerColor
        end)
    end
end)

-- ═══════════════════════════════════════════════════════════
-- [12] GLOW LOGIC
-- ═══════════════════════════════════════════════════════════

-- Sets up the CharacterAdded hook for a player (idempotent).
local function SetupGlowHook(player)
    if GlowConnections[player] then return end  -- already hooked
    GlowConnections[player] = player.CharacterAdded:Connect(function()
        -- Small wait so the character model is fully loaded
        task.wait(0.3)
        if GlowObjects[player] then
            pcall(function() GlowObjects[player]:Destroy() end)
            GlowObjects[player] = nil
        end
        if Toggles.GlowEnabled and Toggles.GlowEnabled.Value then
            CreateGlowForPlayer(player)
        end
    end)
end

-- Register hooks for players already in the server
for _, player in pairs(Players:GetPlayers()) do
    if player ~= LP then SetupGlowHook(player) end
end

-- Updates ALL Highlight instances every frame
local function UpdateAllGlows()
    local glowOn        = Toggles.GlowEnabled   and Toggles.GlowEnabled.Value
    local glowEnemy     = Toggles.GlowEnemy      and Toggles.GlowEnemy.Value
    local glowAlly      = Toggles.GlowAlly       and Toggles.GlowAlly.Value
    local glowTeamCheck = Toggles.GlowTeamCheck  and Toggles.GlowTeamCheck.Value
    local useTeamColor  = Toggles.GlowTeamColor  and Toggles.GlowTeamColor.Value
    local useRealColor  = Toggles.GlowRealTeamColor and Toggles.GlowRealTeamColor.Value

    for _, player in pairs(Players:GetPlayers()) do
        if player == LP then continue end
        local ally = IsAlly(player)
        local char = player.Character

        -- Determine if this player should have glow.
        -- GlowTeamCheck ON  → only enemies (ignore GlowAlly entirely).
        -- GlowTeamCheck OFF → respect GlowEnemy / GlowAlly individually.
        local shouldGlow = glowOn and char and char.Parent
        if shouldGlow then
            if glowTeamCheck then
                shouldGlow = not ally and glowEnemy
            else
                shouldGlow = (ally and glowAlly) or (not ally and glowEnemy)
            end
        end

        if not shouldGlow then
            RemoveGlowForPlayer(player)
            continue
        end

        local hl = GlowObjects[player]

        -- Re-create when missing, parent destroyed, or adornee is stale character
        if not hl or not hl.Parent or (hl.Adornee ~= char) then
            CreateGlowForPlayer(player)
            hl = GlowObjects[player]
        end

        if not hl or not hl.Parent then continue end

        pcall(function()
            hl.FillTransparency    = (Options.GlowFillTransp    and Options.GlowFillTransp.Value    or 70) / 100
            hl.OutlineTransparency = (Options.GlowOutlineTransp and Options.GlowOutlineTransp.Value or 0)  / 100
            hl.OutlineColor        = Options.GlowOutlineColor and Options.GlowOutlineColor.Value or Color3.new(1,1,1)

            -- Color priority: real team color → team color toggle → default
            if useRealColor then
                hl.FillColor = GetRealTeamColor(player)
                           or (useTeamColor and (ally
                               and (Options.GlowAllyFill  and Options.GlowAllyFill.Value  or Color3.fromRGB(50,150,255))
                               or  (Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50))))
                           or (Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50))
            elseif useTeamColor then
                hl.FillColor = ally
                    and (Options.GlowAllyFill  and Options.GlowAllyFill.Value  or Color3.fromRGB(50,150,255))
                    or  (Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50))
            else
                hl.FillColor = Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50)
            end
        end)
    end
end

RunService.Heartbeat:Connect(UpdateAllGlows)

-- ═══════════════════════════════════════════════════════════
-- [13] OnChanged CALLBACKS
-- (decoupled from UI creation, as recommended by Obsidian)
-- ═══════════════════════════════════════════════════════════

-- Hide all ESP when disabled
Toggles.ESPEnabled:OnChanged(function(v)
    if not v then
        for _, objs in pairs(ESPObjects) do HideAll(objs) end
    end
end)

-- Glow: create on enable, remove on disable
Toggles.GlowEnabled:OnChanged(function(v)
    if v then
        for _, player in pairs(Players:GetPlayers()) do
            if player ~= LP then CreateGlowForPlayer(player) end
        end
    else
        for _, player in pairs(Players:GetPlayers()) do
            RemoveGlowForPlayer(player)
        end
    end
end)

-- Glow color refresh (immediate visual feedback on color changes)
local function RefreshGlowColors()
    for player, hl in pairs(GlowObjects) do
        if hl and hl.Parent then
            pcall(function()
                local ally      = IsAlly(player)
                local useTeam   = Toggles.GlowTeamColor     and Toggles.GlowTeamColor.Value
                local useReal   = Toggles.GlowRealTeamColor and Toggles.GlowRealTeamColor.Value
                if useReal then
                    hl.FillColor = GetRealTeamColor(player)
                               or (useTeam and (ally
                                   and (Options.GlowAllyFill  and Options.GlowAllyFill.Value  or Color3.fromRGB(50,150,255))
                                   or  (Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50))))
                               or (Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50))
                elseif useTeam then
                    hl.FillColor = ally
                        and (Options.GlowAllyFill  and Options.GlowAllyFill.Value  or Color3.fromRGB(50,150,255))
                        or  (Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50))
                else
                    hl.FillColor = Options.GlowEnemyFill and Options.GlowEnemyFill.Value or Color3.fromRGB(255,50,50)
                end
                hl.OutlineColor        = Options.GlowOutlineColor and Options.GlowOutlineColor.Value or Color3.new(1,1,1)
                hl.FillTransparency    = (Options.GlowFillTransp    and Options.GlowFillTransp.Value    or 70) / 100
                hl.OutlineTransparency = (Options.GlowOutlineTransp and Options.GlowOutlineTransp.Value or 0)  / 100
            end)
        end
    end
end

Options.GlowEnemyFill:OnChanged(RefreshGlowColors)
Options.GlowAllyFill:OnChanged(RefreshGlowColors)
Options.GlowOutlineColor:OnChanged(RefreshGlowColors)
Options.GlowFillTransp:OnChanged(RefreshGlowColors)
Options.GlowOutlineTransp:OnChanged(RefreshGlowColors)
Toggles.GlowTeamColor:OnChanged(RefreshGlowColors)
Toggles.GlowRealTeamColor:OnChanged(RefreshGlowColors)

-- FOV circle color updates in real time
Options.AimbotFOVColor:OnChanged(function(v)
    if FOVCircle then pcall(function() FOVCircle.Color = v end) end
end)

-- ═══════════════════════════════════════════════════════════
-- [14] UNLOAD CLEANUP
-- ═══════════════════════════════════════════════════════════
Library:OnUnload(function()
    for _, objs in pairs(ESPObjects) do
        for _, obj in pairs(objs) do RemoveDrawing(obj) end
    end
    ESPObjects = {}

    for _, objs in pairs(AggroESP) do
        for _, obj in pairs(objs) do RemoveDrawing(obj) end
    end
    AggroESP = {}

    for _, player in pairs(Players:GetPlayers()) do
        RemoveGlowForPlayer(player)  -- also disconnects GlowConnections
    end

    RemoveDrawing(FOVCircle)
    print("[Aimbot Universal v2] Unloaded successfully.")
end)

-- ═══════════════════════════════════════════════════════════
-- [15] STARTUP NOTIFICATION
-- ═══════════════════════════════════════════════════════════
task.delay(1, function()
    Library:Notify({
        Title       = "Aimbot Universal v2",
        Description = "Loaded! Press RightShift to toggle the menu.",
        Time        = 5,
    })
end)