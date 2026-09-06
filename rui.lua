-- char

local UserInputService = game:GetService("UserInputService")
local CoreGui          = game:GetService("CoreGui")
local Players          = game:GetService("Players")
local StarterGui       = game:GetService("StarterGui")
local TweenService     = game:GetService("TweenService")
local localPlayer      = Players.LocalPlayer
local runtimeEnv       = type(getgenv) == "function" and getgenv() or _G

-- Runtime config (driven by the GUI)
local config = {
    Enabled  = true,
    Username = "",
    Scale    = 0.5,    -- body width/depth (0.5 = Da Hood default / no change)
    Height   = 0.5,    -- body height (0.5 = Da Hood default / no change)
    Headless = false,  -- hide the head + face
    HideHair = false,
    HideHats = false,
    HideFace = false,
}

local isApplying    = false
local isResetting   = false
local deathSpamCount = 0
local lastDeathTime  = 0
local diedConnection = nil

-- caches
local cachedFor             = nil   -- username the userId cache belongs to
local cachedUserId          = nil   -- userId for cachedFor (one web hit per username)
local cachedModel           = nil   -- the appearance MODEL for the target
local cachedModelForUser    = nil   -- username the model cache belongs to
local lastAppliedAt         = 0     -- tick() of last successful apply
local morphedAccessoryCount = 0     -- how many accessories the target look has
local rigOriginal           = nil   -- pristine part sizes + joint offsets for scaling
local rigCaptureReadyAt     = 0     -- block baseline capture until tick() passes this (lets Da Hood thin first)
local headOrigSize          = nil   -- pristine head size (for headless restore)
local headOrigChar          = nil   -- character the head size belongs to
local headEnforceToken      = 0     -- guards overlapping head-enforce loops

local function notify(title, text, duration)
    StarterGui:SetCore("SendNotification", {
        Title = title, Text = text, Duration = duration,
    })
end

----------------------------------------------------------------------
local function applyWeaponSkins()
    if not shared.Glory or not shared.Glory.skins.enabled then return end

    local character = localPlayer.Character
    if not character then return end

    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Tool") then
            local skin = shared.Glory.skins.weapons[child.Name]
            if skin and skin ~= "" then
                pcall(function()
                    if child.Name == "[Knife]" then
                        if type(applyknife) == "function" then
                            applyknife(character, child, skin)
                        end
                    elseif type(applygun) == "function" then
                        applygun(child, skin)
                    end
                end)
            end
        end
    end
end

----------------------------------------------------------------------
local function restartAnimate(character)
    local animate = character:FindFirstChild("Animate")
    if animate then
        animate.Disabled = true
        task.wait()
        animate.Disabled = false
    end
end

----------------------------------------------------------------------
local function unsit(humanoid)
    if not humanoid then return end
    humanoid.Sit = false

    local root = humanoid.Parent
    if root then
        local hrp = root:FindFirstChild("HumanoidRootPart")
        if hrp then
            for _, weld in ipairs(hrp:GetChildren()) do
                if weld:IsA("Weld") and weld.Name == "SeatWeld" then
                    weld:Destroy()
                end
            end
        end
    end
end

----------------------------------------------------------------------
local function countAccessories(character)
    local n = 0
    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Accessory") then n = n + 1 end
    end
    return n
end

----------------------------------------------------------------------
-- Manually weld an accessory's Handle directly to a body PART (not an
-- attachment). Body parts survive stripping, so this holds where AddAccessory
-- doesn't. This is what the working reference script does.
----------------------------------------------------------------------
local function weldAccessory(character, accessory)
    local handle = accessory:FindFirstChild("Handle")
    if not handle then return false end

    local accAtt = handle:FindFirstChildOfClass("Attachment")
    if not accAtt then return false end

    local targetPart, bodyAtt
    for _, part in ipairs(character:GetChildren()) do
        if part:IsA("BasePart") then
            local match = part:FindFirstChild(accAtt.Name)
            if match and match:IsA("Attachment") then
                targetPart = part
                bodyAtt    = match
                break
            end
        end
    end
    if not targetPart or not bodyAtt then return false end

    for _, c in ipairs(handle:GetChildren()) do
        if c:IsA("Weld") or c:IsA("Motor6D") then c:Destroy() end
    end

    accessory.Parent = character

    local weld = Instance.new("Weld")
    weld.Name   = "AccessoryWeld"
    weld.Part0  = targetPart
    weld.Part1  = handle
    weld.C0     = bodyAtt.CFrame
    weld.C1     = accAtt.CFrame
    weld.Parent = handle

    handle.Anchored = false
    return true
end

-- True while the body is knocked / ragdolled / physics-flopping. We must NOT
-- re-assert body scale during this or we re-stiffen the rig and kill the flop.
-- This is exactly why scaling "broke" ragdoll: at 1.00 applyBodyScale no-ops,
-- so nothing fought the flop; off 1.00 it did.
local function isRagdolled(humanoid)
    if not humanoid then return false end
    if humanoid.PlatformStand then return true end
    local st = humanoid:GetState()
    if st == Enum.HumanoidStateType.Physics
        or st == Enum.HumanoidStateType.FallingDown
        or st == Enum.HumanoidStateType.Ragdoll then
        return true
    end
    return false
end

----------------------------------------------------------------------
-- Body scaling (manual). Width -> X/Z. Height -> Y + joint Y offsets + HipHeight.
-- The Head is held at its ORIGINAL size so height never stretches it.
----------------------------------------------------------------------
local function scaleCFrame(cf, sx, sy, sz)
    local p = cf.Position
    return CFrame.new(p.X * sx, p.Y * sy, p.Z * sz) * (cf - p)
end

local function captureRig(character, humanoid)
    if rigOriginal and rigOriginal.char == character then return rigOriginal end
    local data = { char = character, parts = {}, joints = {}, hipHeight = humanoid.HipHeight }
    for _, p in ipairs(character:GetChildren()) do
        if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
            data.parts[p] = p.Size   -- natural Da Hood size = the 0.5 baseline
        end
    end
    for _, m in ipairs(character:GetDescendants()) do
        if m:IsA("Motor6D") then
            data.joints[m] = { C0 = m.C0, C1 = m.C1 }
        end
    end
    rigOriginal = data
    return data
end

local function applyBodyScale(rig, humanoid, widthScale, heightScale)
    -- 0.5 is the DEFAULT (Da Hood's natural body). At 0.5/0.5 we touch NOTHING,
    -- so the natural body -- and the death ragdoll -- are left exactly alone.
    -- Above 0.5 we scale UP from the captured natural body: multiplier = v/0.5,
    -- so 0.5 = x1 (no change), 1.0 = x2, 1.5 = x3.
    local doW = math.abs(widthScale  - 0.5) > 0.001
    local doH = math.abs(heightScale - 0.5) > 0.001
    if not doW and not doH then return end

    local mW = widthScale  / 0.5
    local mH = heightScale / 0.5
    for part, baseSize in pairs(rig.parts) do
        if part.Parent and part.Name ~= "Head" then
            local cur = part.Size
            local sx = doW and (baseSize.X * mW) or cur.X
            local sy = doH and (baseSize.Y * mH) or cur.Y
            local sz = doW and (baseSize.Z * mW) or cur.Z
            part.Size = Vector3.new(sx, sy, sz)
        end
    end
    for joint, orig in pairs(rig.joints) do
        if joint.Parent then
            local w = doW and mW or 1
            local h = doH and mH or 1
            joint.C0 = scaleCFrame(orig.C0, w, h, w)
            joint.C1 = scaleCFrame(orig.C1, w, h, w)
        end
    end
    if doH then
        pcall(function() humanoid.HipHeight = rig.hipHeight * mH end)
    end
end

-- Da Hood's own ragdoll-on-death gets confused by the client morph, so we do
-- our own: on death, turn every limb joint into a BallSocketConstraint and let
-- the body flop. Built from the CURRENT joints, so it works whether scaled or
-- not. Cleaned up automatically on respawn (fresh character).
local function ragdollNow(character, humanoid)
    if not character or not humanoid then return end
    pcall(function()
        for _, m in ipairs(character:GetDescendants()) do
            if m:IsA("Motor6D") and m.Name ~= "Root" and m.Name ~= "RootJoint" then
                local p0, p1 = m.Part0, m.Part1
                if p0 and p1 then
                    local a0 = Instance.new("Attachment")
                    a0.CFrame = m.C0
                    a0.Parent = p0
                    local a1 = Instance.new("Attachment")
                    a1.CFrame = m.C1
                    a1.Parent = p1
                    local socket = Instance.new("BallSocketConstraint")
                    socket.Attachment0     = a0
                    socket.Attachment1     = a1
                    socket.LimitsEnabled   = true
                    socket.TwistLimitsEnabled = true
                    socket.UpperAngle      = 55
                    socket.Parent          = p1
                    m.Enabled = false
                end
            end
        end
        for _, p in ipairs(character:GetChildren()) do
            if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
                p.CanCollide = true
            end
        end
        humanoid:ChangeState(Enum.HumanoidStateType.Physics)
        humanoid.PlatformStand = true
    end)
end

----------------------------------------------------------------------
-- Headless + separate hair/hat hiding. Reversible. Operates on the current character, so it
-- works whether or not an avatar morph is active.
----------------------------------------------------------------------
local hiddenAccessories = {}

local function accessoryCategory(accessory)
    local accessoryType = tostring(accessory.AccessoryType or "")
    local accessoryName = string.lower(accessory.Name or "")

    if string.find(accessoryType, "Hair", 1, true) or string.find(accessoryName, "hair", 1, true) then
        return "hair"
    end

    if string.find(accessoryType, "Face", 1, true)
        or string.find(accessoryType, "Neck", 1, true)
        or string.find(accessoryName, "mask", 1, true)
        or string.find(accessoryName, "glass", 1, true)
        or string.find(accessoryName, "face", 1, true)
        or string.find(accessoryName, "nose", 1, true)
        or string.find(accessoryName, "goggle", 1, true) then
        return "face"
    end

    return "hats"
end

local function refreshHead()
    local character = localPlayer.Character
    if not character then return end
    local head = character:FindFirstChild("Head")
    if not head then return end

    if headOrigChar ~= character then
        headOrigChar = character
        headOrigSize = head.Size
    end

    local face = head:FindFirstChild("face") or head:FindFirstChildOfClass("Decal")
    if config.Headless then
        head.Transparency = 1
        if face then face.Transparency = 1 end
        head.Size = Vector3.new(0.1, 0.1, 0.1)
    else
        head.Transparency = 0
        if face then face.Transparency = 0 end
        if headOrigSize then head.Size = headOrigSize end
    end

    for _, acc in ipairs(character:GetChildren()) do
        if acc:IsA("Accessory") then
            local handle = acc:FindFirstChild("Handle")
            if handle then
                local hide = hiddenAccessories[acc] == true
                handle.Transparency = hide and 1 or 0
                for _, d in ipairs(handle:GetDescendants()) do
                    if d:IsA("BasePart") then
                        d.Transparency = hide and 1 or 0
                    elseif d:IsA("Decal") or d:IsA("Texture") then
                        pcall(function() d.Transparency = hide and 1 or 0 end)
                    end
                end
            end
        end
    end
end

-- re-assert head state for a few seconds (catches late-loading hair / rebuilds)
local function enforceHeadBriefly()
    headEnforceToken = headEnforceToken + 1
    local myToken = headEnforceToken
    task.spawn(function()
        local deadline = tick() + 3
        while tick() < deadline and headEnforceToken == myToken do
            refreshHead()
            task.wait(0.4)
        end
    end)
end

----------------------------------------------------------------------
-- Apply the target look entirely CLIENT-SIDE.
----------------------------------------------------------------------
local function applyAvatar()
    if not config.Enabled or config.Username == "" then return end
    if isApplying then return end

    local character = localPlayer.Character
    if not character then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    if cachedUserId == nil or cachedFor ~= config.Username then
        local ok, uid = pcall(function()
            return Players:GetUserIdFromNameAsync(config.Username)
        end)
        if not ok or not uid then
            notify("Error", "username does not exist.", 3)
            return
        end
        cachedUserId = uid
        cachedFor    = config.Username
    end

    if cachedModel == nil or cachedModelForUser ~= config.Username then
        local ok, model = pcall(function()
            return Players:GetCharacterAppearanceAsync(cachedUserId)
        end)
        if not ok or not model then
            notify("Error", "couldn't load that avatar, try again.", 3)
            return
        end
        cachedModel        = model
        cachedModelForUser = config.Username
    end

isApplying = true
    if humanoid.Sit then unsit(humanoid) end

    -- strip ONLY clothing + body colors. Record (don't destroy yet) accessories.
    local oldAccessories = {}
    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Accessory") then
            oldAccessories[child] = true
        elseif child:IsA("Shirt") or child:IsA("Pants")
            or child:IsA("ShirtGraphic") or child:IsA("CharacterMesh")
            or child:IsA("BodyColors") then
            child:Destroy()
        end
    end

    -- apply target look (manual weld for accessories, parent for clothing)
    local head = character:FindFirstChild("Head")
    for _, item in ipairs(cachedModel:GetChildren()) do
        pcall(function()
            if item:IsA("Accessory") then
                local clone = item:Clone()
                if not weldAccessory(character, clone) then
                    humanoid:AddAccessory(clone)
                end
            elseif item:IsA("Shirt") or item:IsA("Pants")
                or item:IsA("ShirtGraphic") or item:IsA("BodyColors") then
                item:Clone().Parent = character
            elseif item:IsA("Decal") and head then
                local oldFace = head:FindFirstChild("face")
                    or head:FindFirstChildOfClass("Decal")
                if oldFace then
                    oldFace.Texture = item.Texture
                else
                    item:Clone().Parent = head
                end
            end
        end)
    end

    -- target accessories welded -> safe to remove your originals
    for old in pairs(oldAccessories) do
        if old and old.Parent then old:Destroy() end
    end

-- head state re-asserted briefly against rebuilds. Body SCALE is intentionally
    -- NOT touched here -- the bodyScaleKeeper owns all scaling, so the morph never
    -- bakes in a wrong (pre-thin) baseline.
    refreshHead()
    task.spawn(function()
        local deadline = tick() + 3
        while tick() < deadline do
            if localPlayer.Character ~= character or not humanoid.Parent then break end
            if humanoid.Health <= 0 then break end
            refreshHead()
            task.wait(0.5)
        end
    end)

morphedAccessoryCount = countAccessories(character)
    lastAppliedAt = tick()
    isApplying = false
    task.defer(function() pcall(rebuildAccessoryList) end)
end

----------------------------------------------------------------------
-- Apply ONLY the body scale (no avatar re-morph). The sliders call this so
-- moving them is instant, works even without a username set, and never
-- re-strips/re-welds your whole avatar.
local function reapplyBodyOnly()
    local character = localPlayer.Character
    local humanoid  = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end
    if isRagdolled(humanoid) then return end

    local atDefault = math.abs(config.Scale  - 0.5) < 0.001
                  and math.abs(config.Height - 0.5) < 0.001

    if atDefault then
        -- dragged back to 0.5 -> restore the captured natural body, then DROP the
        -- baseline so the next scale re-captures fresh from the thin body
        if rigOriginal and rigOriginal.char == character then
            for part, baseSize in pairs(rigOriginal.parts) do
                if part.Parent and part.Name ~= "Head" then part.Size = baseSize end
            end
            for joint, orig in pairs(rigOriginal.joints) do
                if joint.Parent then joint.C0 = orig.C0; joint.C1 = orig.C1 end
            end
            pcall(function() humanoid.HipHeight = rigOriginal.hipHeight end)
        end
        rigOriginal = nil
        return
    end

-- non-default: capture the baseline from the CURRENT (thin) body the first
    -- time only, so 0.51 means "thin x1.02", not "normal body".
    if not (rigOriginal and rigOriginal.char == character) then
        -- too soon after spawn -> body may not be thinned yet; let the keeper
        -- capture once the gate clears instead of snapshotting a bad baseline
        if tick() < rigCaptureReadyAt then return end
        captureRig(character, humanoid)
    end
    applyBodyScale(rigOriginal, humanoid, config.Scale, config.Height)
end

----------------------------------------------------------------------
local function onDied(character, humanoid)
    -- the game's ragdoll glitches on a client morph, so flop the body ourselves
    if not isResetting and config.Enabled and config.Username ~= "" then
        ragdollNow(character, humanoid)
    end

    local now = tick()
    if (now - lastDeathTime) < 3 then
        deathSpamCount = deathSpamCount + 1
        if deathSpamCount > 5 then
            task.wait(2)
        end
    else
        deathSpamCount = 0
    end
    lastDeathTime = now

    if config.Enabled and config.Username ~= "" then
        isApplying = false
    end
end

----------------------------------------------------------------------
local function onCharacterAdded(character)
    local humanoid = character:WaitForChild("Humanoid", 5)
    isResetting = false

-- new character -> drop stale captures so we re-grab pristine values.
    -- Block baseline capture for a beat: Da Hood thins the body a moment after
    -- spawn, and snapshotting before that grabs the PRE-thin (normal R6) body --
    -- the "0.51 looks like 1.01" bug, back again on respawn. Waiting lines the
    -- respawn path up with the first-char path (which captured late, post-thin).
    rigOriginal = nil
    hiddenAccessories = {}
    rigCaptureReadyAt = tick() + 1.0

    local t0 = tick()
    repeat
        task.wait(0.1)
    until character:FindFirstChildOfClass("Accessory")
        or character:FindFirstChildOfClass("Shirt")
        or character:FindFirstChildOfClass("Pants")
        or (tick() - t0) > 3
task.wait(0.2)

    -- Do NOT capture the rig here. Da Hood thins your body a moment after spawn,
    -- and capturing now grabbed the PRE-thin (normal R6) sizes -- which is why a
    -- tiny slider move snapped you to full normal size ("0.51 looked like 1.01").
    -- The baseline is captured lazily, the first time you scale, from the live
    -- (already-thinned) body.

    local spawnStartedAt = tick()
    if config.Enabled and config.Username ~= "" then
        applyAvatar()

        -- Retry once after Roblox finishes rebuilding the character so the
        -- saved outfit survives reset even when accessories load late.
        task.delay(1.5, function()
            if localPlayer.Character == character
                and humanoid
                and humanoid.Parent
                and humanoid.Health > 0
                and lastAppliedAt < spawnStartedAt then
                isApplying = false
                applyAvatar()
            end
        end)
    end

    -- keep headless / hide-hair active on respawn even without a morph
    if config.Headless or config.HideHair or config.HideHats or config.HideFace then
        enforceHeadBriefly()
    end

    if humanoid then
        if diedConnection then diedConnection:Disconnect() end
        diedConnection = humanoid.Died:Connect(function()
            onDied(character, humanoid)
        end)
    end
end

if runtimeEnv.AvatarChangerConnection then
    runtimeEnv.AvatarChangerConnection:Disconnect()
end
runtimeEnv.AvatarChangerConnection = localPlayer.CharacterAdded:Connect(onCharacterAdded)

if runtimeEnv.CharacterRemovingConnection then
    runtimeEnv.CharacterRemovingConnection:Disconnect()
end
runtimeEnv.CharacterRemovingConnection = localPlayer.CharacterRemoving:Connect(function()
    isResetting = true
    isApplying = false
    rigOriginal = nil
    hiddenAccessories = {}
end)

----------------------------------------------------------------------
-- Watchdog: re-apply only when the avatar was actually wiped.
----------------------------------------------------------------------
local function watchdogLoop()
    while true do
        task.wait(3)

        if not config.Enabled or config.Username == "" then continue end
        if isApplying or not cachedModel then continue end
        if (tick() - lastAppliedAt) < 4 then continue end

local character = localPlayer.Character
        local humanoid  = character and character:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then continue end
        if isRagdolled(humanoid) then continue end   -- don't re-morph mid-knock

        if morphedAccessoryCount > 0 and countAccessories(character) == 0 then
            applyAvatar()
        end
    end
end
task.spawn(watchdogLoop)

----------------------------------------------------------------------
-- Body-scale keeper: re-asserts your chosen scale while you're alive and NOT
-- ragdolled. Da Hood resets your body to normal when you get up from a knock
-- or respawn, which is why a scaled body kept "reverting to 1.00" -- nothing
-- was putting it back. Idempotent (always multiplies the captured pristine
-- sizes, never the current ones) and fully paused while ragdolled.
----------------------------------------------------------------------
local function bodyScaleKeeper()
    while true do
        task.wait(0.5)
        -- 0.5/0.5 is the default -> leave Da Hood's natural body completely alone
        local atDefault = math.abs(config.Scale  - 0.5) < 0.001
                      and math.abs(config.Height - 0.5) < 0.001
        if atDefault then continue end
        if isApplying then continue end
        local character = localPlayer.Character
        local humanoid  = character and character:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then continue end
if isRagdolled(humanoid) then continue end
        if not (rigOriginal and rigOriginal.char == character) then
            -- wait for Da Hood to thin the body before snapshotting the baseline
            if tick() < rigCaptureReadyAt then continue end
            captureRig(character, humanoid)
        end
        applyBodyScale(rigOriginal, humanoid, config.Scale, config.Height)
    end
end
task.spawn(bodyScaleKeeper)

----------------------------------------------------------------------
-- THEME  (Light blue)
----------------------------------------------------------------------
local T = {
    BG1     = Color3.fromRGB(255, 255, 254),
    BG2     = Color3.fromRGB(210, 242, 255),
    PANEL   = Color3.fromRGB(244, 251, 255),
    INPUT   = Color3.fromRGB(232, 247, 255),
    ACCENT  = Color3.fromRGB(125, 205, 255),
    ACCENT2 = Color3.fromRGB(50, 155, 225),
    GOLD1   = Color3.fromRGB(225, 248, 255),
    GOLD2   = Color3.fromRGB(170, 225, 255),
    TXT     = Color3.fromRGB(30, 75, 105),
    DIM     = Color3.fromRGB(110, 155, 180),
    STROKE  = Color3.fromRGB(160, 220, 245),
    TRACK   = Color3.fromRGB(200, 237, 255),
    OFF     = Color3.fromRGB(210, 225, 235),
    WHITE   = Color3.fromRGB(255, 255, 255),
}

local QUICK  = TweenInfo.new(0.16, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local SMOOTH = TweenInfo.new(0.40, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local SOFT   = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local function tw(o, i, p) local t = TweenService:Create(o, i, p); t:Play(); return t end
local function corner(o, r) local c = Instance.new("UICorner", o); c.CornerRadius = UDim.new(0, r or 8); return c end
local function strokeOf(o, col, th, tr) local s=Instance.new("UIStroke", o); s.Color=col or T.STROKE; s.Thickness=th or 1; s.Transparency=tr or 0.35; return s end
local function pad(o, l, r, t, b)
    local p = Instance.new("UIPadding", o)
    p.PaddingLeft=UDim.new(0,l); p.PaddingRight=UDim.new(0,r)
    p.PaddingTop=UDim.new(0,t); p.PaddingBottom=UDim.new(0,b)
    return p
end
local function gradient(o, seq, rot)
    local g = Instance.new("UIGradient")
    g.Color = seq
    g.Rotation = rot or 0
    g.Parent = o
    return g
end
local function seq2(a, b) return ColorSequence.new(a, b) end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.IgnoreGuiInset = true
screenGui.ResetOnSpawn   = false
screenGui.Name           = "PwdsCharUI"
screenGui.Parent         = localPlayer:WaitForChild("PlayerGui")

local mainFrame = Instance.new("Frame")
mainFrame.Size             = UDim2.new(0, 900, 0, 960)
mainFrame.AnchorPoint      = Vector2.new(0.5, 0.5)
mainFrame.Position         = UDim2.new(0.5, 0, 0.42, 0)
mainFrame.BackgroundColor3 = T.BG1
mainFrame.BorderSizePixel  = 0
mainFrame.Parent           = screenGui
corner(mainFrame, 20)
gradient(mainFrame, seq2(T.BG1, T.BG2), 135)

-- animated rose-gold shimmer border
local mainStroke = Instance.new("UIStroke")
mainStroke.Thickness    = 1.6
mainStroke.Transparency = 0.1
mainStroke.Parent       = mainFrame
local strokeGrad = gradient(mainStroke, ColorSequence.new({
    ColorSequenceKeypoint.new(0,    T.GOLD1),
    ColorSequenceKeypoint.new(0.35, T.ACCENT),
    ColorSequenceKeypoint.new(0.65, T.GOLD2),
    ColorSequenceKeypoint.new(1,    T.GOLD1),
}), 0)
task.spawn(function()
    while mainFrame.Parent do
        strokeGrad.Rotation = 0
        local t = tw(strokeGrad, TweenInfo.new(7, Enum.EasingStyle.Linear), {Rotation = 360})
        t.Completed:Wait()
    end
end)

-- soft drop shadow (outside the frame, not clipped)
local shadow = Instance.new("ImageLabel")
shadow.Image = "rbxassetid://6014261993"
shadow.ScaleType = Enum.ScaleType.Slice
shadow.SliceCenter = Rect.new(49, 49, 450, 450)
shadow.Size = UDim2.new(1, 60, 1, 60)
shadow.Position = UDim2.new(0, -30, 0, -28)
shadow.BackgroundTransparency = 1
shadow.ImageColor3 = Color3.fromRGB(100, 195, 255)
shadow.ImageTransparency = 0.45
shadow.ZIndex = 0
shadow.Parent = mainFrame

-- FX layer (drifting sparkles, behind content)
local fxLayer = Instance.new("Frame")
fxLayer.Size = UDim2.new(1, 0, 1, 0)
fxLayer.BackgroundTransparency = 1
fxLayer.ClipsDescendants = true
fxLayer.Parent = mainFrame
corner(fxLayer, 20)

local sparkleChars = {""}
local function spawnSparkle()
    local s = Instance.new("TextLabel")
    s.BackgroundTransparency = 1
    s.Text = sparkleChars[math.random(#sparkleChars)]
    s.TextColor3 = (math.random() > 0.5) and T.ACCENT or T.GOLD2
    s.TextSize = math.random(10, 18)
    s.Font = Enum.Font.GothamMedium
    s.Size = UDim2.new(0, 26, 0, 26)
    local x = math.random(18, 288)
    s.Position = UDim2.new(0, x, 1, 12)
    s.TextTransparency = 1
    s.Parent = fxLayer
    local rise = math.random(150, 320)
    local dur  = math.random(34, 60) / 10
    tw(s, TweenInfo.new(0.7), {TextTransparency = math.random(35, 65) / 100})
    local t = tw(s, TweenInfo.new(dur, Enum.EasingStyle.Sine), {
        Position       = UDim2.new(0, x + math.random(-26, 26), 1, 12 - rise),
        TextTransparency = 1,
        Rotation       = math.random(-45, 45),
    })
    t.Completed:Connect(function() s:Destroy() end)
end
task.spawn(function()
    while fxLayer.Parent do
        spawnSparkle()
        task.wait(math.random(6, 13) / 10)
    end
end)

local scaler = Instance.new("UIScale", mainFrame)
scaler.Scale = 1

-- Drag (whole window)
local dragging, dragInputObj, dragStart, startPos
mainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = mainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
mainFrame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInputObj = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInputObj and dragging then
        local d = input.Position - dragStart
        mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)

----------------------------------------------------------------------
-- Header
----------------------------------------------------------------------
-- glowing pulse dot (center-anchored so it pulses in place, no jitter)
local dotGlow = Instance.new("Frame")
dotGlow.AnchorPoint = Vector2.new(0.5, 0.5)
dotGlow.Size = UDim2.new(0, 22, 0, 22)
dotGlow.Position = UDim2.new(0, 23, 0, 22)
dotGlow.BackgroundColor3 = T.ACCENT
dotGlow.BackgroundTransparency = 0.7
dotGlow.BorderSizePixel = 0
dotGlow.Parent = mainFrame
corner(dotGlow, 11)

local dot = Instance.new("Frame")
dot.AnchorPoint = Vector2.new(0.5, 0.5)
dot.Size = UDim2.new(0, 10, 0, 10)
dot.Position = UDim2.new(0, 23, 0, 22)
dot.BackgroundColor3 = T.ACCENT2
dot.BorderSizePixel = 0
dot.Parent = mainFrame
corner(dot, 5)
task.spawn(function()
    while dotGlow.Parent do
        tw(dotGlow, TweenInfo.new(1.3, Enum.EasingStyle.Sine), {Size = UDim2.new(0,28,0,28), BackgroundTransparency = 0.9}).Completed:Wait()
        tw(dotGlow, TweenInfo.new(1.3, Enum.EasingStyle.Sine), {Size = UDim2.new(0,22,0,22), BackgroundTransparency = 0.6}).Completed:Wait()
    end
end)

local titleLabel = Instance.new("TextLabel")
titleLabel.Size              = UDim2.new(0, 210, 0, 22)
titleLabel.Position          = UDim2.new(0, 38, 0, 12)
titleLabel.Text              = "rui's char"
titleLabel.TextColor3        = T.TXT
titleLabel.TextSize          = 18
titleLabel.Font              = Enum.Font.FredokaOne
titleLabel.BackgroundTransparency = 1
titleLabel.TextXAlignment    = Enum.TextXAlignment.Left
titleLabel.Parent            = mainFrame
-- shimmer sweep across the title
local titleGrad = gradient(titleLabel, ColorSequence.new({
    ColorSequenceKeypoint.new(0,    T.TXT),
    ColorSequenceKeypoint.new(0.42, T.TXT),
    ColorSequenceKeypoint.new(0.5,  T.ACCENT2),
    ColorSequenceKeypoint.new(0.58, T.TXT),
    ColorSequenceKeypoint.new(1,    T.TXT),
}))
task.spawn(function()
    while titleLabel.Parent do
        titleGrad.Offset = Vector2.new(-1.2, 0)
        tw(titleGrad, TweenInfo.new(2.0, Enum.EasingStyle.Sine), {Offset = Vector2.new(1.2, 0)}).Completed:Wait()
        task.wait(1.6)
    end
end)

local subLabel = Instance.new("TextLabel")
subLabel.Size              = UDim2.new(0, 210, 0, 14)
subLabel.Position          = UDim2.new(0, 38, 0, 33)
subLabel.Text              = "char"
subLabel.TextColor3        = T.DIM
subLabel.TextSize          = 11
subLabel.Font              = Enum.Font.FredokaOne
subLabel.BackgroundTransparency = 1
subLabel.TextXAlignment    = Enum.TextXAlignment.Left
subLabel.Parent            = mainFrame

-- thin gradient divider under header
local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -32, 0, 1)
divider.Position = UDim2.new(0, 16, 0, 50)
divider.BackgroundColor3 = T.ACCENT
divider.BackgroundTransparency = 0.4
divider.BorderSizePixel = 0
divider.Parent = mainFrame
gradient(divider, ColorSequence.new({
    ColorSequenceKeypoint.new(0,   T.GOLD2),
    ColorSequenceKeypoint.new(0.5, T.ACCENT),
    ColorSequenceKeypoint.new(1,   T.GOLD2),
}))

----------------------------------------------------------------------
-- Username input (hero) with focus glow
----------------------------------------------------------------------
local usernameWrap = Instance.new("Frame")
usernameWrap.Size             = UDim2.new(1, -32, 0, 42)
usernameWrap.Position         = UDim2.new(0, 16, 0, 62)
usernameWrap.BackgroundColor3 = T.INPUT
usernameWrap.BorderSizePixel  = 0
usernameWrap.Parent           = mainFrame
corner(usernameWrap, 12)
local usernameStroke = strokeOf(usernameWrap, T.STROKE, 1.2, 0.3)

local userIcon = Instance.new("TextLabel")
userIcon.Size = UDim2.new(0, 22, 1, 0)
userIcon.Position = UDim2.new(0, 12, 0, 0)
userIcon.Text = ""
userIcon.TextColor3 = T.ACCENT
userIcon.TextSize = 15
userIcon.Font = Enum.Font.GothamBold
userIcon.BackgroundTransparency = 1
userIcon.Parent = usernameWrap

local usernameBox = Instance.new("TextBox")
usernameBox.Size              = UDim2.new(1, -44, 1, 0)
usernameBox.Position          = UDim2.new(0, 38, 0, 0)
usernameBox.BackgroundTransparency = 1
usernameBox.Text              = ""
usernameBox.PlaceholderText   = "enter username..."
usernameBox.PlaceholderColor3 = T.DIM
usernameBox.TextColor3        = T.TXT
usernameBox.Font              = Enum.Font.FredokaOne
usernameBox.TextSize          = 14
usernameBox.TextXAlignment    = Enum.TextXAlignment.Left
usernameBox.ClearTextOnFocus  = false
usernameBox.Parent            = usernameWrap
usernameBox.Focused:Connect(function()
    tw(usernameStroke, QUICK, {Color = T.ACCENT, Transparency = 0})
    tw(userIcon, QUICK, {TextColor3 = T.ACCENT2})
end)
usernameBox.FocusLost:Connect(function(enterPressed)
    tw(usernameStroke, QUICK, {Color = T.STROKE, Transparency = 0.3})
    tw(userIcon, QUICK, {TextColor3 = T.ACCENT})
    if usernameBox.Text ~= "" and usernameBox.Text ~= "enter username..." then
        config.Username = usernameBox.Text
        if enterPressed then applyAvatar() end
    end
end)

----------------------------------------------------------------------
-- Apply button
----------------------------------------------------------------------
local applyButton = Instance.new("TextButton")
applyButton.Size = UDim2.new(1, -32, 0, 42)
applyButton.Position = UDim2.new(0, 16, 0, 112)
applyButton.BackgroundColor3 = T.ACCENT
applyButton.Text = ""
applyButton.AutoButtonColor = false
applyButton.ClipsDescendants = true
applyButton.Parent = mainFrame
corner(applyButton, 12)
gradient(applyButton, seq2(T.ACCENT, T.ACCENT2), 25)
strokeOf(applyButton, T.WHITE, 1, 0.7)

local applyText = Instance.new("TextLabel")
applyText.Size = UDim2.new(1, 0, 1, 0)
applyText.BackgroundTransparency = 1
applyText.Text = "wear avatar"
applyText.TextColor3 = T.WHITE
applyText.Font = Enum.Font.FredokaOne
applyText.TextSize = 15
applyText.ZIndex = 3
applyText.Parent = applyButton

applyButton.MouseEnter:Connect(function()
    tw(applyButton, QUICK, {Size = UDim2.new(1, -28, 0, 44), Position = UDim2.new(0, 14, 0, 111)})
end)
applyButton.MouseLeave:Connect(function()
    tw(applyButton, QUICK, {Size = UDim2.new(1, -32, 0, 42), Position = UDim2.new(0, 16, 0, 112)})
end)
applyButton.MouseButton1Click:Connect(function()
    if usernameBox.Text ~= "" and usernameBox.Text ~= "enter username..." then
        config.Username = usernameBox.Text
        applyAvatar()
    else
        notify("Notice", "please enter a username in the input field first.", 3)
    end
end)

----------------------------------------------------------------------
-- Body sub-panel
----------------------------------------------------------------------
local panel = Instance.new("Frame")
panel.Size = UDim2.new(1, -32, 0, 150)
panel.Position = UDim2.new(0, 16, 0, 164)
panel.BackgroundColor3 = T.PANEL
panel.BorderSizePixel = 0
panel.Parent = mainFrame
corner(panel, 16)
gradient(panel, seq2(Color3.fromRGB(255, 255, 255), T.PANEL), 135)
strokeOf(panel, T.STROKE, 1, 0.5)
pad(panel, 14, 14, 12, 12)

local panelTitle = Instance.new("TextLabel")
panelTitle.Size = UDim2.new(1, 0, 0, 18)
panelTitle.Text = "body"
panelTitle.TextColor3 = T.ACCENT2
panelTitle.TextSize = 12
panelTitle.Font = Enum.Font.FredokaOne
panelTitle.TextXAlignment = Enum.TextXAlignment.Left
panelTitle.BackgroundTransparency = 1
panelTitle.Parent = panel

----------------------------------------------------------------------
-- Hair and hat dropdowns
----------------------------------------------------------------------


----------------------------------------------------------------------
-- Per-item accessory list (+ headless)
----------------------------------------------------------------------
hiddenAccessories = hiddenAccessories or {}

local function setHandleHidden(accessory, hidden)
    local handle = accessory and accessory:FindFirstChild("Handle")
    if not handle then return end
    handle.Transparency = hidden and 1 or 0
    for _, d in ipairs(handle:GetDescendants()) do
        if d:IsA("BasePart") then
            d.Transparency = hidden and 1 or 0
        elseif d:IsA("Decal") or d:IsA("Texture") then
            pcall(function() d.Transparency = hidden and 1 or 0 end)
        end
    end
end

-- title
local listTitle = Instance.new("TextLabel")
listTitle.Size = UDim2.new(1, -32, 0, 16)
listTitle.Position = UDim2.new(0, 16, 0, 322)
listTitle.BackgroundTransparency = 1
listTitle.Text = "accessories  (click to hide / show)"
listTitle.TextColor3 = T.DIM
listTitle.TextSize = 11
listTitle.Font = Enum.Font.FredokaOne
listTitle.TextXAlignment = Enum.TextXAlignment.Left
listTitle.Parent = mainFrame

local accListFrame = Instance.new("ScrollingFrame")
accListFrame.Name = "AccessoryList"
accListFrame.Size = UDim2.new(1, -32, 0, 160)
accListFrame.Position = UDim2.new(0, 16, 0, 342)
accListFrame.BackgroundColor3 = T.PANEL
accListFrame.BorderSizePixel = 0
accListFrame.ScrollBarThickness = 4
accListFrame.ScrollBarImageColor3 = T.ACCENT2
accListFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
accListFrame.ZIndex = 20
accListFrame.Parent = mainFrame
corner(accListFrame, 12)
strokeOf(accListFrame, T.STROKE, 1, 0.4)

local accPad = Instance.new("UIPadding")
accPad.PaddingLeft = UDim.new(0, 6)
accPad.PaddingRight = UDim.new(0, 6)
accPad.PaddingTop = UDim.new(0, 6)
accPad.PaddingBottom = UDim.new(0, 6)
accPad.Parent = accListFrame

local accLayout = Instance.new("UIListLayout")
accLayout.Padding = UDim.new(0, 4)
accLayout.SortOrder = Enum.SortOrder.LayoutOrder
accLayout.Parent = accListFrame
accLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    accListFrame.CanvasSize = UDim2.new(0, 0, 0, accLayout.AbsoluteContentSize.Y + 12)
end)

local function rebuildAccessoryList()
    for _, child in ipairs(accListFrame:GetChildren()) do
        if child:IsA("TextButton") or child:IsA("TextLabel") or child:IsA("Frame") then
            child:Destroy()
        end
    end

    local character = localPlayer.Character
    if not character then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, -4, 0, 28)
        empty.BackgroundTransparency = 1
        empty.Text = "no character"
        empty.TextColor3 = T.DIM
        empty.TextSize = 12
        empty.Font = Enum.Font.FredokaOne
        empty.Parent = accListFrame
        return
    end

    local accessories = {}
    for _, acc in ipairs(character:GetChildren()) do
        if acc:IsA("Accessory") then
            table.insert(accessories, acc)
        end
    end

    if #accessories == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, -4, 0, 28)
        empty.BackgroundTransparency = 1
        empty.Text = "no accessories equipped"
        empty.TextColor3 = T.DIM
        empty.TextSize = 12
        empty.Font = Enum.Font.FredokaOne
        empty.Parent = accListFrame
        return
    end

    for i, acc in ipairs(accessories) do
        local isHidden = hiddenAccessories[acc] == true

        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -4, 0, 30)
        row.BackgroundColor3 = isHidden and T.TRACK or T.INPUT
        row.BorderSizePixel = 0
        row.AutoButtonColor = false
        row.Text = ""
        row.LayoutOrder = i
        row.ZIndex = 21
        row.Parent = accListFrame
        corner(row, 8)

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size = UDim2.new(1, -58, 1, 0)
        nameLbl.Position = UDim2.new(0, 10, 0, 0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Text = acc.Name
        nameLbl.TextColor3 = T.TXT
        nameLbl.TextSize = 12
        nameLbl.Font = Enum.Font.FredokaOne
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.ZIndex = 22
        nameLbl.Parent = row

        local stateLbl = Instance.new("TextLabel")
        stateLbl.Size = UDim2.new(0, 44, 1, 0)
        stateLbl.Position = UDim2.new(1, -48, 0, 0)
        stateLbl.BackgroundTransparency = 1
        stateLbl.Text = isHidden and "OFF" or "ON"
        stateLbl.TextColor3 = isHidden and Color3.fromRGB(200, 90, 90) or Color3.fromRGB(40, 160, 90)
        stateLbl.TextSize = 12
        stateLbl.Font = Enum.Font.FredokaOne
        stateLbl.TextXAlignment = Enum.TextXAlignment.Right
        stateLbl.ZIndex = 22
        stateLbl.Parent = row

        row.MouseButton1Click:Connect(function()
            if not acc or not acc.Parent then
                rebuildAccessoryList()
                return
            end
            local nowHidden = not (hiddenAccessories[acc] == true)
            hiddenAccessories[acc] = nowHidden
            setHandleHidden(acc, nowHidden)
            rebuildAccessoryList()
        end)
    end
end

-- headless only (single toggle under the list)
local headlessRow = Instance.new("Frame")
headlessRow.Size = UDim2.new(1, -32, 0, 32)
headlessRow.Position = UDim2.new(0, 16, 0, 512)
headlessRow.BackgroundColor3 = T.PANEL
headlessRow.BorderSizePixel = 0
headlessRow.Parent = mainFrame
corner(headlessRow, 10)
gradient(headlessRow, seq2(Color3.fromRGB(255, 255, 255), T.PANEL), 135)
strokeOf(headlessRow, T.STROKE, 1, 0.5)

local headlessLbl = Instance.new("TextLabel")
headlessLbl.Size = UDim2.new(1, -56, 1, 0)
headlessLbl.Position = UDim2.new(0, 12, 0, 0)
headlessLbl.BackgroundTransparency = 1
headlessLbl.Text = "headless"
headlessLbl.TextColor3 = T.TXT
headlessLbl.TextSize = 13
headlessLbl.Font = Enum.Font.FredokaOne
headlessLbl.TextXAlignment = Enum.TextXAlignment.Left
headlessLbl.Parent = headlessRow

local headlessBtn = Instance.new("TextButton")
headlessBtn.Size = UDim2.new(0, 40, 0, 22)
headlessBtn.Position = UDim2.new(1, -48, 0.5, -11)
headlessBtn.BackgroundColor3 = config.Headless and T.ACCENT or T.TRACK
headlessBtn.BorderSizePixel = 0
headlessBtn.Text = config.Headless and "ON" or "OFF"
headlessBtn.TextColor3 = config.Headless and T.WHITE or T.DIM
headlessBtn.TextSize = 11
headlessBtn.Font = Enum.Font.FredokaOne
headlessBtn.AutoButtonColor = false
headlessBtn.Parent = headlessRow
corner(headlessBtn, 8)

headlessBtn.MouseButton1Click:Connect(function()
    config.Headless = not config.Headless
    headlessBtn.BackgroundColor3 = config.Headless and T.ACCENT or T.TRACK
    headlessBtn.Text = config.Headless and "ON" or "OFF"
    headlessBtn.TextColor3 = config.Headless and T.WHITE or T.DIM
    refreshHead()
    enforceHeadBriefly()
end)

mainFrame.Size = UDim2.new(0, 500, 0, 560)

rebuildAccessoryList()

local function watchAccessories(character)
    if not character then return end
    character.ChildAdded:Connect(function(child)
        if child:IsA("Accessory") then
            task.defer(rebuildAccessoryList)
        end
    end)
    character.ChildRemoved:Connect(function(child)
        if child:IsA("Accessory") then
            task.defer(rebuildAccessoryList)
        end
    end)
end
if localPlayer.Character then watchAccessories(localPlayer.Character) end
localPlayer.CharacterAdded:Connect(function(char)
    hiddenAccessories = {}
    task.wait(0.5)
    watchAccessories(char)
    rebuildAccessoryList()
end)

----------------------------------------------------------------------
-- Slider builder (gradient fill + glowing knob)
----------------------------------------------------------------------
local function addSlider(y, name, initAlpha, initValue, mapFn, field)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.6, 0, 0, 16)
    lbl.Position = UDim2.new(0, 0, 0, y)
    lbl.Text = name
    lbl.TextColor3 = T.TXT
    lbl.TextSize = 13
    lbl.Font = Enum.Font.FredokaOne
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.BackgroundTransparency = 1
    lbl.Parent = panel

    local badge = Instance.new("Frame")
    badge.Size = UDim2.new(0, 54, 0, 18)
    badge.Position = UDim2.new(1, -54, 0, y - 1)
    badge.BackgroundColor3 = T.ACCENT
    badge.BorderSizePixel = 0
    badge.Parent = panel
    corner(badge, 7)
    gradient(badge, seq2(T.ACCENT, T.ACCENT2), 0)

    local badgeText = Instance.new("TextLabel")
    badgeText.Size = UDim2.new(1, 0, 1, 0)
    badgeText.BackgroundTransparency = 1
    badgeText.Text = string.format("%.2f", initValue)
    badgeText.TextColor3 = T.WHITE
    badgeText.TextSize = 12
    badgeText.Font = Enum.Font.FredokaOne
    badgeText.ZIndex = 2
    badgeText.Parent = badge

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, 0, 0, 8)
    track.Position = UDim2.new(0, 0, 0, y + 26)
    track.BackgroundColor3 = T.TRACK
    track.BorderSizePixel = 0
    track.Parent = panel
    corner(track, 4)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(initAlpha, 0, 1, 0)
    fill.BackgroundColor3 = T.ACCENT
    fill.BorderSizePixel = 0
    fill.Parent = track
    corner(fill, 4)
    gradient(fill, seq2(T.GOLD1, T.ACCENT), 0)

    local knobGlow = Instance.new("Frame")
    knobGlow.Size = UDim2.new(0, 24, 0, 24)
    knobGlow.Position = UDim2.new(initAlpha, -12, 0.5, -12)
    knobGlow.BackgroundColor3 = T.ACCENT
    knobGlow.BackgroundTransparency = 0.65
    knobGlow.BorderSizePixel = 0
    knobGlow.Parent = track
    corner(knobGlow, 12)

    local knob = Instance.new("TextButton")
    knob.Size = UDim2.new(0, 18, 0, 18)
    knob.Position = UDim2.new(initAlpha, -9, 0.5, -9)
    knob.BackgroundColor3 = T.WHITE
    knob.BorderSizePixel = 0
    knob.AutoButtonColor = false
    knob.Text = ""
    knob.Parent = track
    corner(knob, 9)
    strokeOf(knob, T.ACCENT2, 2, 0)

    -- gentle glow pulse on the knob
    task.spawn(function()
        while knob.Parent do
            tw(knobGlow, TweenInfo.new(1.3, Enum.EasingStyle.Sine), {BackgroundTransparency = 0.85}).Completed:Wait()
            tw(knobGlow, TweenInfo.new(1.3, Enum.EasingStyle.Sine), {BackgroundTransparency = 0.6}).Completed:Wait()
        end
    end)

-- ── drag state ─────────────────────────────────────────────
    local dragging = false
    local curAlpha = initAlpha
    local KNOB_IDLE, KNOB_DRAG = 18, 23
    local GLOW_IDLE, GLOW_DRAG = 24, 32
    local knobHalf = KNOB_IDLE / 2   -- updated when the knob grows/shrinks
    local glowHalf = GLOW_IDLE / 2

    -- Position knob/glow/fill PURELY from an alpha. Never tweens Position, so a
    -- drag can't fight a running tween -- that competing tween (Back easing,
    -- overshoot) was the jitter/lag/snap-back.
    local function placeAt(alpha)
        curAlpha = alpha
        knob.Position     = UDim2.new(alpha, -knobHalf, 0.5, -knobHalf)
        knobGlow.Position = UDim2.new(alpha, -glowHalf, 0.5, -glowHalf)
        fill.Size         = UDim2.new(alpha, 0, 1, 0)
    end

    local function applyAlpha(alpha)
        alpha = math.clamp(alpha, 0, 1)
        placeAt(alpha)
        local value = mapFn(alpha)
        badgeText.Text = string.format("%.2f", value)
        config[field]  = value
    end

    local function alphaFromX(x)
        if track.AbsoluteSize.X == 0 then return curAlpha end
        return (x - track.AbsolutePosition.X) / track.AbsoluteSize.X
    end

    -- size change is INSTANT (set, not tweened) so the knob can't read a
    -- mid-tween size and drift off-center; only the glow opacity animates
    local function grow()
        knobHalf, glowHalf = KNOB_DRAG / 2, GLOW_DRAG / 2
        knob.Size     = UDim2.new(0, KNOB_DRAG, 0, KNOB_DRAG)
        knobGlow.Size = UDim2.new(0, GLOW_DRAG, 0, GLOW_DRAG)
        tw(knobGlow, QUICK, {BackgroundTransparency = 0.4})
        placeAt(curAlpha)
    end
    local function shrink()
        knobHalf, glowHalf = KNOB_IDLE / 2, GLOW_IDLE / 2
        knob.Size     = UDim2.new(0, KNOB_IDLE, 0, KNOB_IDLE)
        knobGlow.Size = UDim2.new(0, GLOW_IDLE, 0, GLOW_IDLE)
        tw(knobGlow, QUICK, {BackgroundTransparency = 0.65})
        placeAt(curAlpha)
    end

    local function startDrag(x)
        if dragging then return end
        dragging = true
        grow()
        applyAlpha(alphaFromX(x))
    end

    -- grab the knob OR click anywhere on the track to seek + drag
    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            startDrag(input.Position.X)
        end
    end)
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            startDrag(input.Position.X)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            applyAlpha(alphaFromX(input.Position.X))
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            shrink()
            reapplyBodyOnly()
        end
    end)
end

addSlider(30, "body scale", 0.0, 0.5, function(a) return 0.5 + a end, "Scale")
addSlider(84, "height", 0.0, 0.5, function(a) return 0.5 + a end, "Height")

-- Staggered entrance reveal
local revealList = { titleLabel, subLabel, divider,
    usernameWrap, applyButton, panel }
task.spawn(function()
    for i, el in ipairs(revealList) do
        local op = el.BackgroundTransparency
        pcall(function() el.BackgroundTransparency = 1 end)
        el.Position = el.Position + UDim2.new(0, 0, 0, 8)
        task.wait(0.04)
        local goalPos = el.Position - UDim2.new(0, 0, 0, 8)
        tw(el, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = goalPos})
        pcall(function() tw(el, QUICK, {BackgroundTransparency = op}) end)
    end
end)

----------------------------------------------------------------------
-- Right Ctrl toggle (animated)
----------------------------------------------------------------------
local guiVisible, animating = true, false
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.RightControl and not animating then
        animating = true
        if guiVisible then
            local t = tw(scaler, QUICK, {Scale = 0})
            t.Completed:Connect(function() mainFrame.Visible = false; guiVisible = false; animating = false end)
        else
            mainFrame.Visible = true; scaler.Scale = 0; guiVisible = true
            local t = tw(scaler, SMOOTH, {Scale = 1})
            t.Completed:Connect(function() animating = false end)
        end
    end
end)

tw(scaler, SMOOTH, {Scale = 1})
