-- Shows the player's full body in first person, walking with the player.
--
-- The game keeps the body mesh hidden in normal play and only shows it during interactions, so this mod steps
-- aside whenever one is running and the game's own scenes play untouched. The body's arms hang at its sides,
-- below the separate first person arms. Nothing here keeps a game object between ticks: the game can delete any
-- object and reuse its memory, and calling a deleted object crashes it. See GhostKiss.

local UEHelpers = require("UEHelpers")

local TICK_MS = 50
local PBO_NONE = 0
local LOOPS_UNTIL_ERROR_IS_REPEATED = 200
local HIDDEN_BONES = { "neck_01" } -- Hiding a bone also hides its children, so this takes the head away from the camera.

local ANIM_PACKAGE = "/Game/Mods/BodyVisible/"
local SLOT = "DefaultSlot"
local BLEND_SECONDS = 0.2
local LOOPS = 10000
local NO_BLEND_OUT_TRIGGER = -1.0
local MOVING_CM_S = 20.0
local WALK_CLIP_CM_S = 180.0 -- Keep these two equal to make_body_keys.py's output.
local CROUCH_CLIP_CM_S = 110.0
local MIN_RATE = 0.6
local MAX_RATE = 2.2
local CROUCHED_HEIGHT_SHARE = 0.75 -- Of the standing capsule. The game's crouch halves it.
local MAX_TURN_DEG = 70.0 -- The legs turn toward a sideways step, and past this the body would look twisted.
local BACKWARD_DEG = 100.0
local TURN_SHARE_PER_TICK = 0.25
local HOLD_VARIABLE = "BodyVisible_Hold" -- Set by a mod whose scene plays its own clip on the body.

local state = nil -- { address, showing, rest, standing, clip, montage, turn }
local error_cooldown = 0

local function log(message)
    print("[BodyVisible] " .. message .. "\n")
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

-- Only the player character has a health component and weapon inventory, so menus and cutscenes return nil.
local function current_player()
    local controller = FindFirstOf("PlayerController")
    if valid(controller) and valid(controller.Pawn) and valid(controller.Pawn.BPC_HealthComponent)
        and valid(controller.Pawn.BP_WeaponInventory) and valid(controller.Pawn.Mesh) then
        return controller.Pawn
    end
    return nil
end

-- LoadAsset only finds assets in the game's asset registry, which a mod pak is not part of.
local function load_clip(name)
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not valid(helpers) then
        return nil
    end
    local asset = helpers:GetAsset({
        PackageName = UEHelpers.FindOrAddFName(ANIM_PACKAGE .. name),
        AssetName = UEHelpers.FindOrAddFName(name),
    })
    if valid(asset) then
        return asset
    end
    return nil
end

local function set_bones_hidden(mesh, hidden)
    for _, bone in ipairs(HIDDEN_BONES) do
        local name = UEHelpers.FindOrAddFName(bone)
        if hidden then
            mesh:HideBoneByName(name, PBO_NONE)
        else
            mesh:UnHideBoneByName(name)
        end
    end
end

-- Copies the numbers, because the value the game returns does not outlive this tick.
local function read_rest(mesh)
    local rotation = mesh.RelativeRotation
    return { Pitch = rotation.Pitch, Yaw = rotation.Yaw, Roll = rotation.Roll }
end

local function set_turn(mesh, turn)
    local rest = state.rest
    mesh:K2_SetRelativeRotation({ Pitch = rest.Pitch, Yaw = rest.Yaw + turn, Roll = rest.Roll }, false, {}, false)
end

local function active_montage(mesh)
    local anim = mesh:GetAnimInstance()
    if not valid(anim) then
        return nil, nil
    end
    local montage = anim:GetCurrentActiveMontage()
    if valid(montage) then
        return anim, montage
    end
    return anim, nil
end

-- Stops only this mod's own clip, which is recognised by address. A scene's montage must keep playing.
local function stop_clip(mesh)
    local anim, montage = active_montage(mesh)
    if montage and montage:GetAddress() == state.montage then
        anim:Montage_Stop(BLEND_SECONDS, montage)
    end
    state.clip, state.montage = nil, nil
end

local function stop_showing(mesh)
    stop_clip(mesh)
    set_bones_hidden(mesh, false)
    state.showing = false
end

-- Which way the player is moving, in degrees from where the body faces, and how fast.
local function read_motion(player)
    local velocity = player:GetVelocity()
    local speed = math.sqrt(velocity.X * velocity.X + velocity.Y * velocity.Y)
    if speed < MOVING_CM_S then
        return 0.0, 0.0
    end
    local yaw = math.rad(player:K2_GetActorRotation().Yaw)
    local forward = velocity.X * math.cos(yaw) + velocity.Y * math.sin(yaw)
    local right = velocity.Y * math.cos(yaw) - velocity.X * math.sin(yaw)
    return speed, math.deg(math.atan(right, forward))
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function animate(player, mesh)
    local speed, heading = read_motion(player)
    if player.CharacterMovement:IsFalling() then
        speed, heading = 0.0, 0.0
    end

    if not state.standing then
        state.standing = player.CapsuleComponent:GetScaledCapsuleHalfHeight()
    end
    local crouched = player.CapsuleComponent:GetScaledCapsuleHalfHeight() < state.standing * CROUCHED_HEIGHT_SHARE

    local backward = math.abs(heading) > BACKWARD_DEG
    local clip = crouched and "AS_BodyCrouchIdle" or "AS_BodyIdle"
    local rate = 1.0
    local wanted_turn = 0.0
    if speed > 0.0 then
        clip = (crouched and "AS_BodyCrouch" or "AS_Body") .. (backward and "WalkBack" or "Walk")
        rate = clamp(speed / (crouched and CROUCH_CLIP_CM_S or WALK_CLIP_CM_S), MIN_RATE, MAX_RATE)
        wanted_turn = backward and (heading > 0.0 and heading - 180.0 or heading + 180.0) or heading
        wanted_turn = clamp(wanted_turn, -MAX_TURN_DEG, MAX_TURN_DEG)
    end

    state.turn = state.turn + (wanted_turn - state.turn) * TURN_SHARE_PER_TICK
    set_turn(mesh, state.turn)

    local anim, montage = active_montage(mesh)
    if not anim then
        return
    end
    local ours = montage and montage:GetAddress() == state.montage
    if ours and clip == state.clip then
        anim:Montage_SetPlayRate(montage, rate)
        return
    end

    local asset = load_clip(clip)
    if not asset then
        log("Clip not found: " .. clip)
        return
    end
    local started = anim:PlaySlotAnimationAsDynamicMontage(asset, UEHelpers.FindOrAddFName(SLOT), BLEND_SECONDS,
        BLEND_SECONDS, rate, LOOPS, NO_BLEND_OUT_TRIGGER, 0.0)
    if valid(started) then
        state.clip, state.montage = clip, started:GetAddress()
    end
end

local function tick()
    local player = current_player()
    if not player then
        state = nil
        return
    end

    local address = player:GetAddress()
    if not state or state.address ~= address then
        state = { address = address, showing = false, turn = 0.0 }
    end

    local mesh = player.Mesh
    if player.InInteraction then
        if state.showing then
            stop_showing(mesh)
        end
        return
    end

    if not state.rest then
        state.rest = read_rest(mesh)
        log(string.format("Body found, yaw %.1f, walk speed %.0f", state.rest.Yaw, player.WalkSpeed or 0.0))
    end

    if not state.showing then
        -- An interaction turns the mesh to face its scene and leaves it that way, which would twist the body.
        state.turn = 0.0
        set_turn(mesh, 0.0)
        set_bones_hidden(mesh, true)
        state.showing = true
    end

    -- Another mod's scene is playing on the body (GhostKiss), so it stays showing, faces ahead and plays nothing.
    if ModRef:GetSharedVariable(HOLD_VARIABLE) then
        state.turn = 0.0
        set_turn(mesh, 0.0)
        state.clip, state.montage = nil, nil
        return
    end

    -- The game hides the mesh again at the end of every interaction.
    mesh:SetOwnerNoSee(false)
    mesh:SetVisibility(true, false)
    animate(player, mesh)
end

LoopInGameThreadWithDelay(TICK_MS, function()
    local ok, message = pcall(tick)
    if ok then
        return
    end
    -- This runs 20 times a second, so one failure must not flood the log.
    if error_cooldown <= 0 then
        log("Error: " .. tostring(message))
        error_cooldown = LOOPS_UNTIL_ERROR_IS_REPEATED
    end
    error_cooldown = error_cooldown - 1
end)

log("Loaded")
