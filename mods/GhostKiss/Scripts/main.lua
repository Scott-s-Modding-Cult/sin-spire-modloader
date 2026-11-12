-- LostSoul ghosts sometimes spawn as a kissing pair, and only notice the player at very close range.
--
-- A kissing pair shows the game's own sex prompt. Holding Interact (E) fills its bar like any of the game's prompts, and
-- then, with enough lust, grabs both heads for a double blowjob scene that ends in a climax and purifies both. Pressing E
-- during that scene lets go early.
--
-- A single Lost Soul gets a Neck scene in the game's own scene lists, beside its blowjob: one head taken by its neck and
-- thrust through, out of its mouth. The game runs it like its own scenes, with stages, the climax bar and the end.
--
-- The game can delete any object and reuse its memory at any moment, and calling a function on a deleted
-- object crashes it. So nothing here keeps a game object between ticks: ghosts are remembered by address and
-- looked up fresh from the game's live list, and assets are fetched each time they are used.

local UEHelpers = require("UEHelpers")
local AdminTabs = require("AdminTabs")

local ANIM_PACKAGE = "/Game/Mods/GhostKiss/AS_LostSoul_Kiss"
local ANIM_NAME = "AS_LostSoul_Kiss"
local KNOWN_PACKAGE = "/Game/Models/Characters/Monsters/LostSoul/Anims/LostSoul_Idle"
local KNOWN_NAME = "LostSoul_Idle"
local GHOST_PACKAGE = "/Game/Blueprints/AI/Enemies/BP_LostSoul"
local GHOST_CLASS = "BP_LostSoul_C"
local AUDIO_DIR = "/Game/Mods/GhostKiss/Audio/"
local KISS_SOUND_COUNT = 10
local CYCLE_SECONDS = 2.0 -- The clip presses twice in its 4 seconds, 1 second into each half.
local PRESS_SECONDS = 1.0
local MOUTH_HEIGHT_CM = 151.6
local TICK_MS = 50
local WATCH_EVERY_TICKS = 4 -- Detection and new ghosts are checked every 200 ms, sound every 50 ms.
local SPAWN_DISTANCE_CM = 200.0
local SPAWN_SPREAD_CM = 100.0
local SEPARATION_CM = 18.502 -- Distance between the two rigs at which the mouths touch; from make_kiss_keys.py.
local MESH_FORWARD_YAW = 90.0 -- The rig faces its mesh's +Y axis.
local NATURAL_KISS_CHANCE = 0.35 -- Chance that a newly spawned LostSoul gains a partner.
local NATURAL_MIN_PLAYER_CM = 500.0 -- A partner never appears right beside the player.
local DETECTION_RADIUS_CM = 61.0 -- 2 feet.
local WAKE_PUSH_CM = 35.0 -- Waking ghosts move apart, because their capsules overlap while kissing.
local WAKE_TARGET_DELAY_MS = 400 -- The AI restarts first, or it would reset the target it was just given.
local COMBAT_STATE_ATTACKING = 4
local ADMIN_SPAWN_DISTANCE_CM = 250.0
local SEX_ICON = 7 -- The interact prompt's icon type for the game's sex symbol, as BPW_Interact picks it.
local VISIBILITY_CHANNEL = 3 -- ECC_Visibility, which the game's interact trace uses.
local IGNORE, BLOCK = 0, 2
local PERK_LIBRARY = "/Game/Blueprints/Player/BPL_Stats.Default__BPL_Stats_C"
local COMMON_LIBRARY = "/Game/Blueprints/BPFL_CommonFunctions.Default__BPFL_CommonFunctions_C"
local HOLD_TAKEOVER_SECONDS = 0.12 -- The mod ends the game's hold timer this long before it would finish, and acts itself.
local LUST_MESSAGE = "Lust is too low!" -- The game's own words and colour when a scene needs more lust.
local LUST_COLOUR = { R = 1.0, G = 0.222369, B = 0.72808, A = 1.0 }

-- The scenes. Each clip set is authored with its timing table, by make_ghost_bj_keys.py and make_ghost_neck_keys.py.
local SCENE_DIR = "/Game/Mods/GhostKiss/"
local SCENES = {
    double = { timing = require("bj_timing"), player = "AS_Player_GhostBJ",
               clips = { a = "AS_LostSoul_BJ_A", b = "AS_LostSoul_BJ_B" } },
    neck = { timing = require("neck_timing"), player = "AS_Player_GhostNeck", clips = { a = "AS_LostSoul_Neck" } },
}
local GRAB_RADIUS_CM = 180.0 -- From the player to the pair's mouths.
local GRAB_FACING = 0.3 -- The pair must be ahead of the player: the cosine of the widest angle.
local LOOK_PITCH_DEG = -58.0 -- The view is held looking down at the scene.
local RESYNC_JUMP_SECONDS = 1.0 -- A ghost's clip further than this from the player's jumps back in step.
local RESYNC_MAX_RATE = 0.15 -- Closer than that, it plays up to this much faster or slower until it catches up.
local CALM_SECONDS = 8.0 -- After the scene the pair does not wake for the player standing beside it.
local PURIFY_CHECK_SECONDS = 0.5 -- How long after the end of scene sequence to look for the game's dissolve.
local WIDEN_MORPH = "Widen01" -- The mouth's stretch, which the game's own LostSoul scene drives.
local WIDEN_SCALE = 1.0
local HIDDEN_BONE = "neck_01" -- Keeps the player's own head out of the camera, as BodyVisible does.
local FP_MESH = "FP Viewport Mesh"
local BODY_HOLD_VARIABLE = "BodyVisible_Hold" -- Tells BodyVisible to leave the body to this scene.
local PBO_NONE = 0
local SOUNDS = {
    suck = { "/Game/Audio/SexFoley/OpenNSFW/Oral/SC_FaceFuck", "SC_FaceFuck", 0.8 },
    gag = { "/Game/Audio/SexFoley/OpenNSFW/Oral/SC_Gag", "SC_Gag", 0.9 },
    slide = { "/Game/Audio/SexFoley/OpenNSFW/Slide/SC_SlideOut", "SC_SlideOut", 0.8 },
    swallow = { "/Game/Audio/SexFoley/OpenNSFW/Oral/SC_Swallow", "SC_Swallow", 0.9 },
    cum = { "/Game/Audio/SexFoley/Homemade/Cum", "Cum", 1.0 },
}
local LONGEST_SLURP_SECONDS = 3.0 -- A slurp is not restarted over itself; a looping cue counts as this long.
local CUM_PACKAGE = "/Game/Blueprints/Effects/NS_Cum"
local CUM_NAME = "NS_Cum"
local CUM_BONE = "penis_06"
-- The effect shoots along its attach point's +X. On the player's penis_06 the shaft runs along the bone's -Y (read in
-- game), so a yaw of 270 sends it straight out of the tip. At 0 it went straight to the player's left; at NurseTouch's
-- 285 it leant 15 degrees left, which in the neck scene, where the tip points at the camera, showed as a sideways streak.
local CUM_YAW = 270.0
local KEEP_RELATIVE_OFFSET = 0
local NO_POOLING = 0
local ANIMATION_BLUEPRINT = 0
local MOVEMENT_NONE = 0
local MOVEMENT_WALKING = 1

local active_pairs = {}
local scene = nil -- The running scene, if any.
local purifying = {} -- Pairs whose end of scene sequence ran, waiting to see whether the game dissolves them.
local let_go_requested = false
local admin_spawns = 0
local clock = 0.0
local seen_ghosts = {}
local world_address = nil
local tick_count = 0
local kiss_sound_names = {}
for number = 1, KISS_SOUND_COUNT do
    kiss_sound_names[number] = string.format("S_Kiss_%03d", number)
end

local function log(message)
    print("[GhostKiss] " .. message .. "\n")
end

local function distance_squared(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function current_player()
    local controller = FindFirstOf("PlayerController")
    if controller and controller:IsValid() and controller.Pawn:IsValid() then
        return controller.Pawn
    end
    return nil
end

local function player_location()
    local player = current_player()
    if player then
        return player:K2_GetActorLocation()
    end
    return { X = 0, Y = 0, Z = 0 }
end

-- Every live ghost right now, by address. Only objects from this list are safe to call during this tick.
local function live_ghosts()
    local live = {}
    for _, ghost in ipairs(FindAllOf(GHOST_CLASS) or {}) do
        if ghost:IsValid() then
            live[ghost:GetAddress()] = ghost
        end
    end
    return live
end

local function is_paired(address)
    for _, pair in ipairs(active_pairs) do
        if pair.a_address == address or pair.b_address == address then
            return true
        end
    end
    return false
end

local function nearest_two_ghosts(live)
    local origin = player_location()
    local found = {}
    for address, ghost in pairs(live) do
        -- Class templates have no controller, and spawned ghosts get theirs when they join a pair.
        if not is_paired(address) and ghost.Controller:IsValid() then
            table.insert(found, { actor = ghost, distance = distance_squared(ghost:K2_GetActorLocation(), origin) })
        end
    end
    if #found < 2 then
        return nil
    end
    table.sort(found, function(a, b)
        return a.distance < b.distance
    end)
    return found[1].actor, found[2].actor
end

-- Stops the ghost's AI and its senses, so only the checks in watch_pairs can wake it.
local function hold_still(ghost)
    local saved = { mode = ghost.CharacterMovement.MovementMode, health = ghost.BPC_HealthComponent.CurrentHealth }
    pcall(function()
        local interact = ghost.BP_InteractableObject
        saved.interact = { can = interact.CanInteract, hold = interact.HoldDownToInteract, kind = interact.InteractType,
            alternate = interact.HasAlternateInteractionsOnHold }
    end)
    pcall(function()
        saved.profile = ghost.CapsuleComponent:GetCollisionProfileName()
    end)
    if not ghost.Controller:IsValid() then
        ghost:SpawnDefaultController()
    end
    if ghost.Controller:IsValid() then
        ghost.Controller:StopMovement()
        if ghost.Controller.BrainComponent:IsValid() then
            ghost.Controller.BrainComponent:StopLogic("GhostKiss")
        end
    end
    if ghost.AIPerception:IsValid() then
        ghost.AIPerception:Deactivate()
    end
    ghost.CharacterMovement:DisableMovement()
    ghost:SetActorEnableCollision(false)
    return saved
end

-- The game's interact prompt, which it shows with the sex symbol over a knocked down enemy. A kissing ghost shows it
-- too, held like the game's own; check_holds takes over just before the hold would finish.
local function set_prompt(ghost, saved, on)
    if not ghost or not saved or not saved.interact then
        return
    end
    pcall(function()
        local interact = ghost.BP_InteractableObject
        if on then
            interact.CanInteract = true
            interact.HoldDownToInteract = true
            interact.InteractType = SEX_ICON
            -- Off, so the mod can end the hold with CancelHeldInteraction without it also acting as a tap.
            interact.HasAlternateInteractionsOnHold = false
        else
            interact:CancelHeldInteraction()
            interact.CanInteract = saved.interact.can
            interact.HoldDownToInteract = saved.interact.hold
            interact.InteractType = saved.interact.kind
            interact.HasAlternateInteractionsOnHold = saved.interact.alternate
        end
    end)
end

-- A kissing ghost blocks only the game's visibility traces, so the interact trace finds it and shots hit it, while the
-- pair's overlapping capsules and the player pass through each other. Off, it gets its own collision back.
local function set_trace_only(ghost, saved, on)
    if not ghost or not saved then
        return
    end
    pcall(function()
        local capsule = ghost.CapsuleComponent
        if on then
            capsule:SetCollisionResponseToAllChannels(IGNORE)
            capsule:SetCollisionResponseToChannel(VISIBILITY_CHANNEL, BLOCK)
            ghost:SetActorEnableCollision(true)
        elseif saved.profile then
            capsule:SetCollisionProfileName(saved.profile, true)
        end
    end)
end

local function release(ghost, saved)
    if not ghost then
        return
    end
    set_prompt(ghost, saved, false)
    set_trace_only(ghost, saved, false)
    ghost.Mesh:SetAnimationMode(0, true)
    ghost:SetActorEnableCollision(true)
    -- A ghost spawned this frame has not started moving yet, so it has no mode to go back to.
    ghost.CharacterMovement:SetMovementMode(saved.mode ~= MOVEMENT_NONE and saved.mode or MOVEMENT_WALKING, 0)
    if ghost.AIPerception:IsValid() then
        ghost.AIPerception:Activate(true)
    end
    if ghost.Controller:IsValid() and ghost.Controller.BrainComponent:IsValid() then
        ghost.Controller.BrainComponent:RestartLogic()
    end
end

-- Moves the ghost so its mesh origin lands on the target, wherever the mesh sits inside the actor.
local function place(ghost, target, face_yaw)
    local mesh_yaw = ghost.Mesh.RelativeRotation.Yaw
    local actor_yaw = face_yaw - MESH_FORWARD_YAW - mesh_yaw
    local hit = {}
    ghost:K2_SetActorRotation({ Pitch = 0, Yaw = actor_yaw, Roll = 0 }, true)
    local mesh_location = ghost.Mesh:K2_GetComponentLocation()
    local actor_location = ghost:K2_GetActorLocation()
    ghost:K2_SetActorLocation({
        X = actor_location.X + target.X - mesh_location.X,
        Y = actor_location.Y + target.Y - mesh_location.Y,
        Z = actor_location.Z + target.Z - mesh_location.Z,
    }, false, hit, true)
end

-- LoadAsset only finds assets in the game's asset registry, which a mod pak is not part of.
local function load_by_package(package_name, asset_name)
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not helpers:IsValid() then
        return nil
    end
    local asset = helpers:GetAsset({
        PackageName = UEHelpers.FindOrAddFName(package_name),
        AssetName = UEHelpers.FindOrAddFName(asset_name),
    })
    if asset:IsValid() then
        return asset
    end
    return nil
end

local function log_characters()
    local characters = FindAllOf("Character")
    if not characters then
        log("No characters are loaded in this level")
        return
    end
    local counts = {}
    for _, character in ipairs(characters) do
        local name = character:GetClass():GetFName():ToString()
        counts[name] = (counts[name] or 0) + 1
    end
    for name, count in pairs(counts) do
        log("Character in level: " .. name .. " x" .. count)
    end
end

local function spawn_ghost_at(location)
    local ghost_class = load_by_package(GHOST_PACKAGE, GHOST_CLASS)
    if not ghost_class then
        return nil
    end
    local spawned = UEHelpers.GetWorld():SpawnActor(ghost_class, location, { Pitch = 0, Yaw = 0, Roll = 0 })
    if spawned and spawned:IsValid() then
        -- Marked as seen so a mod-made ghost never rolls for a partner of its own.
        seen_ghosts[spawned:GetAddress()] = true
        return spawned
    end
    return nil
end

-- Spawns a ghost in front of the player, offset sideways so the two spawns do not overlap.
local function spawn_ghost(side)
    local player = current_player()
    if not player then
        return nil
    end
    local location = player:K2_GetActorLocation()
    local forward = player:GetActorForwardVector()
    return spawn_ghost_at({
        X = location.X + forward.X * SPAWN_DISTANCE_CM - forward.Y * side * SPAWN_SPREAD_CM,
        Y = location.Y + forward.Y * SPAWN_DISTANCE_CM + forward.X * side * SPAWN_SPREAD_CM,
        Z = location.Z,
    })
end

local function random_between(low, high)
    return low + math.random() * (high - low)
end

-- Picks a sound other than the one just played, so the same smack never plays twice in a row.
local function pick_sound_name(last)
    local name = kiss_sound_names[math.random(#kiss_sound_names)]
    while name == last do
        name = kiss_sound_names[math.random(#kiss_sound_names)]
    end
    return name
end

-- Plans one press: a main kiss on the press, and sometimes a softer one after it.
local function plan_cycle()
    local events = {
        { at = PRESS_SECONDS - random_between(0.05, 0.15), volume = random_between(0.85, 1.0) },
    }
    if math.random() < 0.4 then
        table.insert(events, { at = PRESS_SECONDS + random_between(0.2, 0.45), volume = random_between(0.5, 0.75) })
    end
    return events
end

local function play_sound(pair, ghost, volume)
    local name = pick_sound_name(pair.last_sound)
    pair.last_sound = name
    local sound = load_by_package(AUDIO_DIR .. name, name)
    if sound then
        StaticFindObject("/Script/Engine.Default__GameplayStatics"):PlaySoundAtLocation(ghost, sound, pair.mouth,
            { Pitch = 0, Yaw = 0, Roll = 0 }, volume, random_between(0.92, 1.08), 0.0, nil, nil, nil, nil)
    end
end

-- Follows the clip's own playback position, so the sounds stay on the presses and stop when the game pauses.
local function update_audio(pair, ghost)
    local phase = ghost.Mesh:GetPosition() % CYCLE_SECONDS
    if phase < pair.phase then
        pair.events = plan_cycle()
    end
    pair.phase = phase
    for _, event in ipairs(pair.events) do
        if not event.played and phase >= event.at then
            event.played = true
            play_sound(pair, ghost, event.volume)
        end
    end
end

local function load_anim()
    local anim = load_by_package(ANIM_PACKAGE, ANIM_NAME)
    if not anim then
        local known = load_by_package(KNOWN_PACKAGE, KNOWN_NAME)
        log("Could not load the kiss animation. Game animation load test: " .. (known and "worked" or "failed"))
    end
    return anim
end

-- Places both ghosts mouth to mouth around the centre point and starts the kiss.
local function begin_pair(a, b, centre, yaw, anim, options)
    local pair = {
        a_address = a:GetAddress(),
        b_address = b:GetAddress(),
        manual = options.manual,
        spawned = options.spawned,
        saved_a = options.saved_a or hold_still(a),
        saved_b = options.saved_b or hold_still(b),
        centre = { X = centre.X, Y = centre.Y, Z = centre.Z },
        yaw = yaw,
        calm_until = options.calm_until or 0.0,
        phase = 0.0,
        events = plan_cycle(),
    }
    local dir_x, dir_y = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local scale = a.Mesh:K2_GetComponentScale()
    local half = SEPARATION_CM * scale.X / 2
    place(a, { X = centre.X - dir_x * half, Y = centre.Y - dir_y * half, Z = centre.Z }, yaw)
    place(b, { X = centre.X + dir_x * half, Y = centre.Y + dir_y * half, Z = centre.Z }, yaw + 180.0)
    a.Mesh:PlayAnimation(anim, true)
    b.Mesh:PlayAnimation(anim, true)
    pair.dir_x, pair.dir_y = dir_x, dir_y
    pair.mouth = { X = centre.X, Y = centre.Y, Z = centre.Z + MOUTH_HEIGHT_CM * scale.Z }
    table.insert(active_pairs, pair)
    return pair
end

local function remove_pair(pair)
    for index, candidate in ipairs(active_pairs) do
        if candidate == pair then
            table.remove(active_pairs, index)
            return
        end
    end
end

local function target_player(ghost, player)
    if not ghost or not ghost.Controller:IsValid() then
        return
    end
    local blackboard = ghost.Controller.Blackboard
    if blackboard:IsValid() then
        blackboard:SetValueAsObject(UEHelpers.FindOrAddFName("CurrentEnemy"), player)
        blackboard:SetValueAsEnum(UEHelpers.FindOrAddFName("CombatState"), COMBAT_STATE_ATTACKING)
    end
    ghost:SetCurrentEnemy(player)
    ghost:SetCombatState(COMBAT_STATE_ATTACKING)
end

local function push_apart(ghost, x, y)
    if ghost then
        local location = ghost:K2_GetActorLocation()
        local hit = {}
        ghost:K2_SetActorLocation({ X = location.X + x, Y = location.Y + y, Z = location.Z }, false, hit, true)
    end
end

-- Ends the kiss and sends whichever ghosts are left after the player.
local function wake_pair(pair, live, reason)
    remove_pair(pair)
    log("Woken: " .. reason)
    local a, b = live[pair.a_address], live[pair.b_address]
    push_apart(a, -pair.dir_x * WAKE_PUSH_CM, -pair.dir_y * WAKE_PUSH_CM)
    push_apart(b, pair.dir_x * WAKE_PUSH_CM, pair.dir_y * WAKE_PUSH_CM)
    release(a, pair.saved_a)
    release(b, pair.saved_b)
    local a_address, b_address = pair.a_address, pair.b_address
    ExecuteInGameThreadWithDelay(WAKE_TARGET_DELAY_MS, function()
        local player = current_player()
        if player then
            local now = live_ghosts()
            target_player(now[a_address], player)
            target_player(now[b_address], player)
        end
    end)
end

local function was_hurt(ghost, saved)
    return ghost.BPC_HealthComponent.CurrentHealth < saved.health
end

local function watch_pairs(live)
    local player = current_player()
    local radius_squared = DETECTION_RADIUS_CM * DETECTION_RADIUS_CM
    -- Backwards, because waking a pair removes it from the list.
    for index = #active_pairs, 1, -1 do
        local pair = active_pairs[index]
        local a, b = live[pair.a_address], live[pair.b_address]
        if not a or not b then
            wake_pair(pair, live, "a ghost is gone")
        elseif was_hurt(a, pair.saved_a) or was_hurt(b, pair.saved_b) then
            wake_pair(pair, live, "a ghost was hurt")
        else
            set_prompt(a, pair.saved_a, true)
            set_prompt(b, pair.saved_b, true)
            if not pair.traceable then
                set_trace_only(a, pair.saved_a, true)
                set_trace_only(b, pair.saved_b, true)
                pair.traceable = true
            end
        end
        if a and b and active_pairs[index] == pair and player and clock >= pair.calm_until then
            local location = player:K2_GetActorLocation()
            if distance_squared(a:K2_GetActorLocation(), location) <= radius_squared
                or distance_squared(b:K2_GetActorLocation(), location) <= radius_squared then
                wake_pair(pair, live, "player within detection radius")
            end
        end
    end
end

-- Gives a newly spawned ghost a partner where it stands.
local function make_natural_pair(ghost)
    local anim = load_anim()
    if not anim then
        return
    end
    local saved = hold_still(ghost)
    local centre = ghost.Mesh:K2_GetComponentLocation()
    local partner = spawn_ghost_at(ghost:K2_GetActorLocation())
    if not partner then
        log("Could not spawn a partner")
        release(ghost, saved)
        return
    end
    begin_pair(ghost, partner, centre, random_between(-180.0, 180.0), anim, { saved_a = saved })
    log("A pair spawned kissing")
end

local function check_new_ghosts(live)
    -- Forget deleted ghosts, so a new ghost that reuses an old address still gets its roll.
    for address in pairs(seen_ghosts) do
        if not live[address] then
            seen_ghosts[address] = nil
        end
    end
    local origin = player_location()
    local minimum_squared = NATURAL_MIN_PLAYER_CM * NATURAL_MIN_PLAYER_CM
    for address, ghost in pairs(live) do
        -- Class templates have no controller, so waiting for one also skips them.
        if not seen_ghosts[address] and ghost.Controller:IsValid() then
            seen_ghosts[address] = true
            if math.random() < NATURAL_KISS_CHANCE
                and distance_squared(ghost:K2_GetActorLocation(), origin) >= minimum_squared then
                make_natural_pair(ghost)
            end
        end
    end
end

-- The double scene. ---------------------------------------------------------------------------------------------------

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function fname(text)
    return UEHelpers.FindOrAddFName(text)
end

local function is_paused(player)
    return StaticFindObject("/Script/Engine.Default__GameplayStatics"):IsGamePaused(player)
end

-- A point in the player mesh's own space (floor at 0, +Y ahead, +X to the player's left), in the world.
local function player_space(player, point)
    local origin = player.Mesh:K2_GetComponentLocation()
    local forward = player:GetActorForwardVector()
    local right = player:GetActorRightVector()
    return {
        X = origin.X - right.X * point.X + forward.X * point.Y,
        Y = origin.Y - right.Y * point.X + forward.Y * point.Y,
        Z = origin.Z - right.Z * point.X + forward.Z * point.Y + point.Z,
    }
end

-- The clips are authored with each ghost's origin on one spot in the player's space, facing the way the player does.
local function place_scene_ghosts(player, ghosts)
    local target = player_space(player, scene.def.timing.ghost_root)
    local yaw = player:K2_GetActorRotation().Yaw
    for _, ghost in pairs(ghosts) do
        place(ghost, target, yaw)
    end
end

-- The ghosts playing a part in the scene, by part, if all of them are still alive.
local function scene_ghosts(live)
    local ghosts = {}
    for key, address in pairs(scene.roles) do
        if not live[address] then
            return nil
        end
        ghosts[key] = live[address]
    end
    return ghosts
end

local function set_first_person_visible(player, visible)
    local ok, message = pcall(function()
        local arms = player[FP_MESH]
        if valid(arms) then
            -- Children too, which takes the held weapon with the arms.
            arms:SetVisibility(visible, true)
        else
            log("No first person arms found")
        end
    end)
    if not ok then
        log("Could not change the first person arms: " .. tostring(message))
    end
end

local function widen_at(key, position)
    local timing = scene.def.timing
    local values = timing["widen_" .. key]
    local at = position * timing.widen_fps
    local index = math.floor(at)
    local first = values[index + 1] or values[#values]
    local second = values[index + 2] or first
    return first + (second - first) * (at - index)
end

-- position only has to rise steadily: it says when a slurp may play again.
local function play_scene_sound(state, kind, key, ghost, position)
    local mouth = ghost.Mesh:GetSocketLocation(fname("mouth_ent"))
    if kind == "kiss" then
        state.kiss.mouth = { X = mouth.X, Y = mouth.Y, Z = mouth.Z }
        play_sound(state.kiss, ghost, random_between(0.6, 0.8))
        return
    end
    local entry = SOUNDS[kind]
    if kind == "suck" and position < state.slurp_until[key] then
        return
    end
    local sound = load_by_package(entry[1], entry[2])
    if not sound then
        log("Could not load sound " .. entry[2])
        return
    end
    if kind == "suck" or kind == "gag" then
        local duration = sound.Duration
        if type(duration) ~= "number" or duration <= 0.0 or duration > LONGEST_SLURP_SECONDS then
            duration = LONGEST_SLURP_SECONDS
        end
        state.slurp_until[key] = position + duration * 0.8
    end
    StaticFindObject("/Script/Engine.Default__GameplayStatics"):PlaySoundAtLocation(ghost, sound, mouth,
        { Pitch = 0, Yaw = 0, Roll = 0 }, entry[3], random_between(0.95, 1.05), 0.0, nil, nil, nil, nil)
end

local function spurt(player)
    local system = load_by_package(CUM_PACKAGE, CUM_NAME)
    local library = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not system or not library:IsValid() then
        log("Could not load the cum effect")
        return
    end
    local yaw = CUM_YAW
    library:SpawnSystemAttached(system, player.Mesh, fname(CUM_BONE), { X = 0, Y = 0, Z = 0 },
        { Pitch = 0, Yaw = yaw, Roll = 0 }, KEEP_RELATIVE_OFFSET, true, true, NO_POOLING, true)
    log("Spurt at yaw " .. yaw)
end

local function restore_player(player, saved)
    local mesh = player.Mesh
    mesh:SetAnimationMode(ANIMATION_BLUEPRINT, true)
    mesh.VisibilityBasedAnimTickOption = saved.tick_option
    -- With BodyVisible the body stays out, head still hidden; without it, the body goes back to how it was.
    if not saved.body_visible then
        mesh:UnHideBoneByName(fname(HIDDEN_BONE))
        mesh:SetVisibility(false, false)
        mesh:SetOwnerNoSee(saved.owner_no_see)
    end
    set_first_person_visible(player, true)
    player.CharacterMovement:SetMovementMode(MOVEMENT_WALKING, 0)
    if valid(player.Controller) then
        player:EnableInput(player.Controller)
    end
end

-- The game's own lust check for its scenes, with its own message when it fails.
local function lust_ok(player, ghost)
    local ok, enough = pcall(function()
        return player.CurrentLust >= ghost.LustRequirement
    end)
    if not ok or enough then
        return true
    end
    local shown, message = pcall(function()
        StaticFindObject(COMMON_LIBRARY):ShowHudMessage(FText(LUST_MESSAGE), LUST_COLOUR, player)
    end)
    log("Lust is too low for a scene" .. (shown and "" or ", and the message failed: " .. tostring(message)))
    return false
end

-- Ends the scene. The pair goes back to kissing where it was, unless it was hurt or lost a ghost.
local function end_scene(live, player, reason, wake)
    local ended = scene
    scene = nil
    log("Scene ended: " .. reason)
    ModRef:SetSharedVariable(BODY_HOLD_VARIABLE, false)
    if player then
        local ok, message = pcall(restore_player, player, ended.player)
        if not ok then
            log("Could not restore the player: " .. tostring(message))
        end
    end
    local pair = ended.pair
    local ghosts = { a = live[pair.a_address], b = live[pair.b_address] }
    for key, address in pairs(ended.roles) do
        local ghost = live[address]
        if ghost then
            ghost.Mesh:SetMorphTarget(fname(WIDEN_MORPH), 0.0, true)
            ghost.Mesh:SetPlayRate(1.0)
            ghost.Mesh:SetRelativeScale3D(ended.ghosts[key].scale)
            ghost.Mesh.bEnableUpdateRateOptimizations = ended.ghosts[key].update_rate
            ghost.Mesh.VisibilityBasedAnimTickOption = ended.ghosts[key].tick_option
        end
    end
    -- A scene played to the end ends the way the game's own scenes do: its end of scene sequence raises sanity, lowers
    -- lust and, if the player has the Purification perk, dissolves each ghost, counts it, pays and removes it. The user
    -- chose this over a look-alike, knowing the game also writes the count to its online leaderboard. Without the perk
    -- nothing dissolves, so check_purifying sends the pair back to kissing.
    if reason == "finished" and ghosts.a and ghosts.b then
        local perk_ok, perk = pcall(function()
            return StaticFindObject(PERK_LIBRARY):HasPerk(fname("Purification"), ghosts.a)
        end)
        local known = perk_ok and type(perk) == "boolean"
        log("Purification perk: " .. (known and tostring(perk) or "unknown, " .. tostring(perk)))
        local called = 0
        for _, ghost in pairs(ghosts) do
            local ok, message = pcall(function()
                ghost:DoSexEndSequence()
            end)
            if ok then
                called = called + 1
            else
                log("Could not run the end of scene sequence: " .. tostring(message))
            end
        end
        if called > 0 and known and perk then
            log("Purified the pair")
            return
        end
        if called > 0 and not known then
            table.insert(purifying, { pair = pair, check_at = clock + PURIFY_CHECK_SECONDS })
            return
        end
        if called > 0 then
            log("No Purification perk, so the pair was not purified and goes back to kissing")
        end
    end
    local anim = load_anim()
    if wake or not ghosts.a or not ghosts.b or not anim then
        table.insert(active_pairs, pair)
        wake_pair(pair, live, reason)
        return
    end
    begin_pair(ghosts.a, ghosts.b, pair.centre, pair.yaw, anim, { saved_a = pair.saved_a, saved_b = pair.saved_b,
        manual = pair.manual, spawned = pair.spawned, calm_until = clock + CALM_SECONDS })
end

-- Which ghost plays which part. The neck scene takes the ghost nearer the player.
local function cast(kind, pair, live, player)
    if kind == "double" then
        return { a = pair.a_address, b = pair.b_address }, nil
    end
    local location = player:K2_GetActorLocation()
    local a, b = pair.a_address, pair.b_address
    if distance_squared(live[b]:K2_GetActorLocation(), location) < distance_squared(live[a]:K2_GetActorLocation(), location) then
        a, b = b, a
    end
    return { a = a }, b
end

local function start_scene(kind, pair, live, player)
    local def = SCENES[kind]
    local clips = {}
    for key, name in pairs(def.clips) do
        clips[key] = load_by_package(SCENE_DIR .. name, name)
    end
    clips.player = load_by_package(SCENE_DIR .. def.player, def.player)
    for key, name in pairs(def.clips) do
        if not clips[key] then
            log("Could not load the scene clip " .. name)
            return
        end
    end
    if not clips.player then
        log("Could not load the scene clip " .. def.player)
        return
    end
    local controller = player.Controller
    if not valid(controller) then
        return
    end
    remove_pair(pair)
    for _, key in ipairs({ "a", "b" }) do
        local ghost = live[pair[key .. "_address"]]
        set_prompt(ghost, pair["saved_" .. key], false)
        set_trace_only(ghost, pair["saved_" .. key], false)
        if ghost then
            ghost:SetActorEnableCollision(false) -- The clips put the ghosts where the player stands.
        end
    end
    pair.traceable = false
    local mesh = player.Mesh
    local roles, watcher = cast(kind, pair, live, player)
    scene = {
        kind = kind,
        def = def,
        roles = roles,
        pair = pair,
        player_address = player:GetAddress(),
        last_position = 0.0,
        next_event = 1,
        slurp_until = { a = 0.0, b = 0.0 },
        kiss = {},
        ghosts = {},
        player = { body_visible = mesh:IsVisible(), owner_no_see = mesh.bOwnerNoSee,
                   tick_option = mesh.VisibilityBasedAnimTickOption },
    }
    local ghosts = {}
    for key, address in pairs(roles) do
        ghosts[key] = live[address]
    end
    for key, ghost in pairs(ghosts) do
        local scale = ghost.Mesh.RelativeScale3D
        scene.ghosts[key] = { scale = { X = scale.X, Y = scale.Y, Z = scale.Z },
            update_rate = ghost.Mesh.bEnableUpdateRateOptimizations, tick_option = ghost.Mesh.VisibilityBasedAnimTickOption }
        if key == "a" then
            log(string.format("Ghost scale %.2f, %.2f, %.2f", scale.X, scale.Y, scale.Z))
        end
        -- The clips are authored at full size, and the update rate optimisation would let the clips drift apart.
        ghost.Mesh:SetWorldScale3D({ X = 1.0, Y = 1.0, Z = 1.0 })
        ghost.Mesh.bEnableUpdateRateOptimizations = false
        ghost.Mesh.VisibilityBasedAnimTickOption = 0
        ghost.Mesh:PlayAnimation(clips[key], false)
    end
    if player.CharacterMovement:IsCrouching() then
        player:UnCrouch(false)
    end
    place_scene_ghosts(player, ghosts)
    -- The one left out stays where it was kissing and floats idly until the scene ends.
    if watcher then
        local idle = load_by_package(KNOWN_PACKAGE, KNOWN_NAME)
        if idle then
            live[watcher].Mesh:PlayAnimation(idle, true)
        end
    end

    ModRef:SetSharedVariable(BODY_HOLD_VARIABLE, true)
    mesh:SetOwnerNoSee(false)
    mesh:SetVisibility(true, false)
    mesh:HideBoneByName(fname(HIDDEN_BONE), PBO_NONE)
    mesh.VisibilityBasedAnimTickOption = 0
    mesh:PlayAnimation(clips.player, false)
    set_first_person_visible(player, false)
    player.CharacterMovement:StopMovementImmediately()
    player.CharacterMovement:DisableMovement()
    player:DisableInput(controller)
    controller:SetControlRotation({ Pitch = LOOK_PITCH_DEG, Yaw = player:K2_GetActorRotation().Yaw, Roll = 0 })
    log("Grabbed a pair for the " .. kind .. " scene")
end

local function update_scene(live)
    local player = current_player()
    local pair = scene.pair
    local a, b = live[pair.a_address], live[pair.b_address]
    if not player or player:GetAddress() ~= scene.player_address then
        end_scene(live, nil, "the player is gone")
        return
    end
    if not a or not b then
        end_scene(live, player, "a ghost is gone", true)
        return
    end
    if was_hurt(a, pair.saved_a) or was_hurt(b, pair.saved_b) then
        end_scene(live, player, "a ghost was hurt", true)
        return
    end
    if let_go_requested then
        let_go_requested = false
        end_scene(live, player, "let go")
        return
    end
    local timing = scene.def.timing
    local position = player.Mesh:GetPosition()
    if position >= timing.length - 0.1 then
        end_scene(live, player, "finished")
        return
    end
    local ghosts = scene_ghosts(live)
    place_scene_ghosts(player, ghosts)
    player.CharacterMovement:DisableMovement() -- Closing the admin panel turns input and movement back on.
    for key, ghost in pairs(ghosts) do
        -- Jumping a clip on every small drift makes the pose snap, so small drifts are closed by play rate.
        local behind = position - ghost.Mesh:GetPosition()
        if math.abs(behind) > RESYNC_JUMP_SECONDS then
            ghost.Mesh:SetPosition(position, false)
        else
            ghost.Mesh:SetPlayRate(1.0 + math.max(-RESYNC_MAX_RATE, math.min(RESYNC_MAX_RATE, behind * 2.0)))
        end
        ghost.Mesh:SetMorphTarget(fname(WIDEN_MORPH), widen_at(key, position) * WIDEN_SCALE, false)
    end
    while timing.events[scene.next_event] and timing.events[scene.next_event][1] <= position do
        local event = timing.events[scene.next_event]
        scene.next_event = scene.next_event + 1
        play_scene_sound(scene, event[3], event[2], ghosts[event[2]], position)
    end
    for _, at in ipairs(timing.spurts) do
        if scene.last_position < at and position >= at then
            spurt(player)
        end
    end
    scene.last_position = position
end

-- The neck scene in the game's own scene lists. ----------------------------------------------------------------------

-- A row added to the LostSoul's scene table at run time puts Neck beside the game's own blowjob: in the Free Mode
-- ghost's scene list, switched with D, and among the Sex scenes on the game's wheel. The row has no montages, so the
-- game's scene handler runs everything else as it does for its own scenes: the camera, the stages on W and S, the climax
-- bar, the climax on W once the bar is full, and purifying or ending afterwards. This mod plays its clips for the stage
-- the handler is on and sends the events the game's own montages send: CLevel at each thrust, then Purification.
local NECK_TIMING = require("neck_stages")
local SEX_TABLE_PACKAGE = "/Game/Blueprints/Player/Interactions/DT_LostSoulSex"
local SEX_TABLE_NAME = "DT_LostSoulSex"
local SOURCE_ROW = "Test" -- The game's blowjob from the front, which the Neck row starts as a copy of.
local NECK_ROW = "GhostKissNeck"
local NECK_TAG = "GhostKissNeck" -- Added to the row's scene tags, which tells this mod that a scene is its own.
local NECK_TITLE = "Neck"
local FREE_MODE_LIST = "/Game/Blueprints/AI/Enemies/FreemodeInfo/DIS_Lost.DIS_Lost:DE_StartSceneSelector_C_0"
local SELECTOR_CLASS = "BP_SelectableSceneActor_C"
local EVENT_LIBRARY = "/Script/EasyEventSystem.Default__EasyEventManagerLibrary"
local GAME_MONTAGE_PACKAGE = "/Game/Models/Characters/Monsters/LostSoul/Anims/Sex_LostSoul_Montage"
local GAME_MONTAGE_NAME = "Sex_LostSoul_Montage"
-- The scene table's fields, named as the game's struct names them.
local FIELD = {
    name = "Name_2_238638F249DE6D7D55C2828B6A7E9B20",
    animation = "Animation_18_B3E1E06D4393F322E226088A34C4879A",
    player_montage = "PlayerMontage_2_3C1386214D3CDFDAA0CB969D98F9E52A",
    npc_montage = "NPCMontage_4_EFDFA2E449426E7EFF4CCAB705208D09",
    unconscious = "NPCUnconscious_12_3F39B04B4A2BD0A8C24E399443E241F1",
    context = "ContextualSettings_74_8BB80D564193B78460CB0E8348A96875",
    can_context = "CanBeContextual_12_52D8872D45F50F894920D3AB612C9673",
    tags = "SceneTags_94_C7BDFD0D4FC07F9E3783DEB587897D1C",
}
local GHOST_SLOT = "DefaultOverride" -- The montage slots the game's own LostSoul scene plays in.
local PLAYER_SLOT = "DefaultSlot"
local STAGE_CLIPS = { "Loop1", "Loop2", "Loop3" } -- By the handler's stage, counted from 0.
local CLIP_BLEND_SECONDS = 0.2
local LOOP_COUNT = 10000 -- A stage's clip loops until the player changes stage. Its position runs on over the loops.
local SYNC_SECONDS = 0.05 -- The ghost's clip is put back in step with the player's when further apart than this.
-- A clip played once hands over this long before its end, ahead of its own blend out and with ticks to spare.
local HAND_OVER_SECONDS = CLIP_BLEND_SECONDS + 0.15

local game_scene = nil -- The game's scene handler running the Neck scene, while it does.
local neck_lists = {} -- The table and list objects already given the Neck scene, by address.
local knock_down_settings = nil -- What the game's own scene does to the ghost at its very end, read from its montage.

local function call_event(handler, name)
    StaticFindObject(EVENT_LIBRARY):CallEvent(handler, fname(name), "", nil)
end

local function sex_table()
    local dt = StaticFindObject(SEX_TABLE_PACKAGE .. "." .. SEX_TABLE_NAME)
    if valid(dt) then
        return dt
    end
    return load_by_package(SEX_TABLE_PACKAGE, SEX_TABLE_NAME)
end

-- Both are game objects that can be loaded again, so each new one is checked once.
local function add_neck_to_lists()
    local list = StaticFindObject(FREE_MODE_LIST)
    local dt = StaticFindObject(SEX_TABLE_PACKAGE .. "." .. SEX_TABLE_NAME)
    if not valid(dt) and valid(list) then
        dt = sex_table()
    end
    if valid(dt) and not neck_lists[dt:GetAddress()] then
        neck_lists[dt:GetAddress()] = true
        if not dt:FindRow(NECK_ROW) then
            local source = dt:FindRow(SOURCE_ROW)
            if not source then
                log("The LostSoul's scene table has no " .. SOURCE_ROW .. " row to copy")
                return
            end
            dt:AddRow(NECK_ROW, source)
            local row = dt:FindRow(NECK_ROW)
            row[FIELD.name] = FText(NECK_TITLE)
            local animation = row[FIELD.animation]
            animation[FIELD.player_montage] = nil
            animation[FIELD.npc_montage] = nil
            animation[FIELD.unconscious] = nil
            -- The game picks its contextual scenes at random; those stay its own.
            row[FIELD.context][FIELD.can_context] = false
            local tags = row[FIELD.tags]
            tags[tags:GetArrayNum() + 1] = fname(NECK_TAG)
            log("Added the Neck scene to the LostSoul's scene table")
        end
    end
    if valid(dt) and valid(list) and not neck_lists[list:GetAddress()] then
        neck_lists[list:GetAddress()] = true
        local scenes = list.Scenes
        for i = 1, scenes:GetArrayNum() do
            if scenes[i].RowName:ToString() == NECK_ROW then
                return
            end
        end
        scenes[scenes:GetArrayNum() + 1] = { DataTable = dt, RowName = fname(NECK_ROW) }
        log("Added the Neck scene to the Free Mode ghost's scene list")
    end
end

local function is_neck_scene(handler)
    local ours = false
    pcall(function()
        local tags = handler.SexSceneInfo[FIELD.tags]
        for i = 1, tags:GetArrayNum() do
            if tags[i]:ToString() == NECK_TAG then
                ours = true
            end
        end
    end)
    return ours
end

-- The clip playing in a mesh's slot, if it is still the one this mod started there.
local function neck_montage(mesh, address)
    local instance = mesh:GetAnimInstance()
    if not valid(instance) then
        return nil
    end
    local montage = instance:GetCurrentActiveMontage()
    if not valid(montage) or montage:GetAddress() ~= address then
        return nil
    end
    return instance, montage
end

local function play_neck_clip(state, ghost, player, name)
    local timing = NECK_TIMING.clips[name]
    local played = {}
    for key, part in pairs({ ghost = { ghost.Mesh, GHOST_SLOT, "AS_LostSoul_Neck" },
        player = { player.Mesh, PLAYER_SLOT, "AS_Player_GhostNeck" } }) do
        local asset = part[3] .. name
        local clip = load_by_package(SCENE_DIR .. asset, asset)
        if not clip then
            error("Could not load the neck clip " .. asset)
        end
        -- A clip played once only starts blending out at its very end, which the mod never lets it reach.
        local montage = part[1]:GetAnimInstance():PlaySlotAnimationAsDynamicMontage(clip, fname(part[2]),
            CLIP_BLEND_SECONDS, CLIP_BLEND_SECONDS, 1.0, timing.cycle and LOOP_COUNT or 1, 0.0, 0.0)
        if not valid(montage) then
            error("Could not play the neck clip " .. asset)
        end
        played[key] = montage:GetAddress()
    end
    state.montages = played
    state.clip = name
    state.last_position = 0.0
end

-- The clips are authored with the ghost's origin on one spot in the player's space, facing the way the player does.
-- The game's scene puts both on one spot, so the ghost's mesh is moved there within its actor.
local function place_neck_ghost(player, ghost)
    local mesh = ghost.Mesh
    mesh:SetWorldScale3D({ X = 1.0, Y = 1.0, Z = 1.0 })
    mesh:K2_SetWorldLocationAndRotation(player_space(player, NECK_TIMING.ghost_root), player.Mesh:K2_GetComponentRotation(),
        false, {}, true)
end

local function sample(values, position)
    local at = position * NECK_TIMING.widen_fps
    local index = math.floor(at)
    local first = values[index + 1] or values[#values]
    local second = values[index + 2] or first
    return first + (second - first) * (at - index)
end

-- The game's own scene knocks the ghost down as its montage ends, with its notify's settings.
local function knock_down(ghost)
    if not knock_down_settings then
        local montage = load_by_package(GAME_MONTAGE_PACKAGE, GAME_MONTAGE_NAME)
        local notifies = montage.Notifies
        for i = 1, notifies:GetArrayNum() do
            local notify = notifies[i].Notify
            if valid(notify) and notify:GetClass():GetFName():ToString() == "AnimNotify_Ragdoll_C" then
                knock_down_settings = { knocked = notify.KnockedOut, dead = notify.Dead }
            end
        end
        if not knock_down_settings then
            knock_down_settings = {}
            log("The game's LostSoul scene has no ragdoll at its end")
        end
    end
    if knock_down_settings.knocked ~= nil then
        ghost.BPC_HealthComponent:SetKnockDown(knock_down_settings.knocked, knock_down_settings.dead)
    end
end

local function is_dissolving(ghost)
    local ok, playing = pcall(function()
        return ghost.DissolveTimeline:IsPlaying()
    end)
    return ok and playing
end

local function begin_game_scene(player, handler)
    local ghost = handler.InteractedActor
    if not valid(ghost) or ghost:GetClass():GetFName():ToString() ~= GHOST_CLASS then
        error("the scene is not on a LostSoul")
    end
    -- In Free Mode the scene list's own actor ends the scene after purifying, and switches scenes.
    local in_list = false
    for _, actor in ipairs(FindAllOf(SELECTOR_CLASS) or {}) do
        if valid(actor.CurrentScene) and actor.CurrentScene:GetAddress() == handler:GetAddress() then
            in_list = true
        end
    end
    local mesh = ghost.Mesh
    local location, rotation, scale = mesh.RelativeLocation, mesh.RelativeRotation, mesh.RelativeScale3D
    game_scene = {
        handler_address = handler:GetAddress(),
        ghost_address = ghost:GetAddress(),
        in_list = in_list,
        saved = {
            location = { X = location.X, Y = location.Y, Z = location.Z },
            rotation = { Pitch = rotation.Pitch, Yaw = rotation.Yaw, Roll = rotation.Roll },
            scale = { X = scale.X, Y = scale.Y, Z = scale.Z },
            update_rate = mesh.bEnableUpdateRateOptimizations,
            tick_option = mesh.VisibilityBasedAnimTickOption,
            player_tick_option = player.Mesh.VisibilityBasedAnimTickOption,
        },
        slurp_until = { a = 0.0 },
        kiss = {},
    }
    -- The update rate optimisation would let the two clips drift apart.
    mesh.bEnableUpdateRateOptimizations = false
    mesh.VisibilityBasedAnimTickOption = 0
    player.Mesh.VisibilityBasedAnimTickOption = 0
    -- The game's own player montage turns the camera on as it starts; this row has none.
    player:EnableCamera(true)
    if valid(player.Controller) then
        player.Controller:SetControlRotation({ Pitch = LOOK_PITCH_DEG, Yaw = player:K2_GetActorRotation().Yaw, Roll = 0 })
    end
    place_neck_ghost(player, ghost)
    play_neck_clip(game_scene, ghost, player, "Enter")
    log("Neck scene started from the game's scene list" .. (in_list and " in Free Mode" or ""))
end

local function finish_game_scene(live, player, reason)
    local state = game_scene
    game_scene = nil
    log("Neck scene ended: " .. reason)
    local ghost = live[state.ghost_address]
    local meshes = { ghost = ghost and ghost.Mesh, player = player and player.Mesh }
    for key, mesh in pairs(meshes) do
        if mesh then
            -- Only this mod's own clip: after a switch in the scene list the game's next scene is already playing.
            local instance, montage = neck_montage(mesh, state.montages[key])
            if instance then
                instance:Montage_Stop(CLIP_BLEND_SECONDS, montage)
            end
        end
    end
    if ghost then
        local mesh = ghost.Mesh
        mesh:SetMorphTarget(fname(WIDEN_MORPH), 0.0, true)
        mesh:K2_SetRelativeLocationAndRotation(state.saved.location, state.saved.rotation, false, {}, true)
        mesh:SetRelativeScale3D(state.saved.scale)
        mesh.bEnableUpdateRateOptimizations = state.saved.update_rate
        mesh.VisibilityBasedAnimTickOption = state.saved.tick_option
    end
    if player then
        player.Mesh.VisibilityBasedAnimTickOption = state.saved.player_tick_option
    end
end

-- The game's own way out of a scene, through the Free Mode scene list when that started it.
local function leave_scene(handler)
    for _, actor in ipairs(FindAllOf(SELECTOR_CLASS) or {}) do
        if valid(actor.CurrentScene) and actor.CurrentScene:GetAddress() == handler:GetAddress() then
            actor:EndAnyScene()
            return
        end
    end
    handler:ForceEndScene()
end

-- When this mod cannot run the scene, so the player is not left in a scene that never ends.
local function abort_game_scene(live, player, reason)
    local state = game_scene
    local handler = player and player.CurrentSScene
    finish_game_scene(live, player, reason)
    if valid(handler) and handler:GetAddress() == state.handler_address then
        leave_scene(handler)
    end
end

local function drive_game_scene(live, player, handler)
    local state = game_scene
    local ghost = handler.InteractedActor
    if not valid(ghost) then
        -- Gone before the clip ended: the game's own scene ends its interaction with the clip, so this one does now.
        finish_game_scene(live, player, "the ghost is gone")
        if not state.in_list and player.InInteraction then
            player:EndInteraction()
        end
        return
    end
    place_neck_ghost(player, ghost)
    local timing = NECK_TIMING.clips[state.clip]
    local instance, montage = neck_montage(player.Mesh, state.montages.player)
    if not instance then
        -- Something else took the slot over. A stage's loop starts again, the entry goes on to the stage, and the
        -- climax is over.
        if state.clip == "Enter" then
            play_neck_clip(state, ghost, player, STAGE_CLIPS[handler.CurrentStage + 1] or STAGE_CLIPS[1])
        elseif state.clip ~= "End" then
            play_neck_clip(state, ghost, player, state.clip)
        end
        return
    end
    local raw = instance:Montage_GetPosition(montage)
    local position = timing.cycle and raw % timing.length or raw
    local ghost_instance, ghost_montage = neck_montage(ghost.Mesh, state.montages.ghost)
    if ghost_instance and math.abs(ghost_instance:Montage_GetPosition(ghost_montage) - raw) > SYNC_SECONDS then
        ghost_instance:Montage_SetPosition(ghost_montage, raw)
    end
    ghost.Mesh:SetMorphTarget(fname(WIDEN_MORPH), sample(timing.widen, position) * WIDEN_SCALE, false)

    local from = state.last_position
    local wrapped = position < from
    local function crossed(at)
        if wrapped then
            return at > from or at <= position
        end
        return at > from and at <= position
    end
    for _, event in ipairs(timing.events) do
        if crossed(event[1]) then
            play_scene_sound(state, event[2], "a", ghost, clock)
        end
    end
    if not handler.EndingSequence then
        for _, at in ipairs(timing.counts) do
            if crossed(at) then
                call_event(handler, "CLevel")
            end
        end
    end
    for _, at in ipairs(timing.spurts) do
        if crossed(at) then
            spurt(player)
        end
    end
    if timing.purify and crossed(timing.purify) then
        log("Neck scene purifying")
        call_event(handler, "Purification")
    end
    state.last_position = position

    -- The handler's stage picks the loop; once the climax bar is full and the player goes on, its climax plays.
    local wanted = handler.EndingSequence and "End" or STAGE_CLIPS[handler.CurrentStage + 1] or STAGE_CLIPS[#STAGE_CLIPS]
    if state.clip == "Enter" then
        if position >= timing.length - HAND_OVER_SECONDS then
            log("Neck scene clip " .. wanted)
            play_neck_clip(state, ghost, player, wanted)
        end
    elseif state.clip == "End" then
        if not state.frozen and position >= timing.length - HAND_OVER_SECONDS then
            -- Held on its last pose rather than blending back to the ghost's own animation.
            state.frozen = true
            instance:Montage_SetPlayRate(montage, 0.0)
            if ghost_instance then
                ghost_instance:Montage_SetPlayRate(ghost_montage, 0.0)
            end
            -- In Free Mode the scene list ends it once purified. Elsewhere it ends as the game's own montages end it.
            if not state.in_list then
                if not is_dissolving(ghost) then
                    local knocked, message = pcall(knock_down, ghost)
                    log(knocked and "Neck scene knocked the ghost down" or "Could not knock the ghost down: " .. tostring(message))
                end
                player:EndInteraction()
            end
        end
    elseif wanted ~= state.clip then
        -- Every loop passes the shallow end of a thrust once a cycle, where the clips meet.
        if wrapped or math.floor(position / timing.cycle) ~= math.floor(from / timing.cycle) then
            log("Neck scene clip " .. wanted)
            play_neck_clip(state, ghost, player, wanted)
        end
    end
end

local function update_game_scene(live)
    local player = current_player()
    local handler = player and player.CurrentSScene
    -- A destroyed handler still reads as valid until it is cleaned up, and the player's interaction ends with it.
    local current = valid(handler) and player.InInteraction and handler or nil
    if game_scene and (not current or current:GetAddress() ~= game_scene.handler_address) then
        finish_game_scene(live, player, "the game's scene ended")
    end
    if current and not game_scene and not scene and is_neck_scene(current) then
        local ok, message = pcall(begin_game_scene, player, current)
        if not ok then
            log("Could not start the neck scene: " .. tostring(message))
            if game_scene then
                abort_game_scene(live, player, "could not start")
            else
                leave_scene(current)
            end
            return
        end
    end
    if game_scene then
        drive_game_scene(live, player, current)
    end
end

-- The nearest kissing pair ahead of the player and within reach. From the admin panel, the nearest anywhere.
local function pair_to_grab(live, player, anywhere)
    local location = player:K2_GetActorLocation()
    local forward = player:GetActorForwardVector()
    local best, best_distance = nil, anywhere and math.huge or GRAB_RADIUS_CM * GRAB_RADIUS_CM
    for _, pair in ipairs(active_pairs) do
        if live[pair.a_address] and live[pair.b_address] then
            local dx, dy = pair.mouth.X - location.X, pair.mouth.Y - location.Y
            local flat = math.sqrt(dx * dx + dy * dy)
            local ahead = flat < 1.0 or (dx * forward.X + dy * forward.Y) / flat >= GRAB_FACING
            local distance = distance_squared(pair.mouth, location)
            if distance < best_distance and (ahead or anywhere) then
                best, best_distance = pair, distance
            end
        end
    end
    return best
end

local function spawn_admin_pair(player)
    local anim = load_anim()
    if not anim then
        return
    end
    local location = player:K2_GetActorLocation()
    local forward = player:GetActorForwardVector()
    local ghost = spawn_ghost_at({ X = location.X + forward.X * ADMIN_SPAWN_DISTANCE_CM,
        Y = location.Y + forward.Y * ADMIN_SPAWN_DISTANCE_CM, Z = location.Z })
    if not ghost then
        log("Could not spawn a ghost")
        return
    end
    local saved = hold_still(ghost)
    local centre = ghost.Mesh:K2_GetComponentLocation()
    local partner = spawn_ghost_at(ghost:K2_GetActorLocation())
    if not partner then
        log("Could not spawn a partner")
        release(ghost, saved)
        return
    end
    -- Side on to the player, so both faces show.
    begin_pair(ghost, partner, centre, player:K2_GetActorRotation().Yaw + 90.0, anim,
        { saved_a = saved, manual = true, spawned = true })
    log("Spawned a kissing pair from the admin panel")
end

local key_seen = false -- E reached the key callback since the last tick. Held, it does every frame.
local key_quiet_ticks = 0
local KEY_RELEASE_TICKS = 3 -- E unseen this many ticks counts as released.
local admin_grab = nil -- The scene the admin panel asked for.
local hold_requests = {} -- Pairs whose hold the mod took over this tick.
local hooked = {}

local holds = {} -- Pair ghosts the player is holding E on, by address: when the game's hold timer started.

local function game_seconds()
    return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(UEHelpers.GetWorld())
end

-- The game's hold timer on a pair ghost is about to finish: the mod ends it, so the game's own action never runs, and
-- starts the double scene itself.
local function check_holds(live)
    for address, started in pairs(holds) do
        local ghost = live[address]
        if not ghost or not is_paired(address) then
            holds[address] = nil
        else
            pcall(function()
                local interact = ghost.BP_InteractableObject
                if game_seconds() - started >= interact.InteractTime - HOLD_TAKEOVER_SECONDS then
                    holds[address] = nil
                    interact:CancelHeldInteraction()
                    for _, pair in ipairs(active_pairs) do
                        if pair.a_address == address or pair.b_address == address then
                            table.insert(hold_requests, { pair = pair, ghost = address })
                        end
                    end
                end
            end)
        end
    end
end

local function on_hold_start(interact)
    local owner = interact:GetOwner()
    if owner:IsValid() and is_paired(owner:GetAddress()) then
        holds[owner:GetAddress()] = game_seconds()
    end
end

local function on_hold_stop(interact)
    local owner = interact:GetOwner()
    if owner:IsValid() then
        holds[owner:GetAddress()] = nil
    end
end

local function on_hold_finished(interact)
    local owner = interact:GetOwner()
    if owner:IsValid() and is_paired(owner:GetAddress()) then
        log("The game's own hold finished on a kissing ghost before the mod took over")
    end
end

-- The game's classes load with the level, so the hooks are retried until they register.
local INTERACT_CLASS = "/Game/Blueprints/Components/BP_InteractableObject.BP_InteractableObject_C"

local function hook_holds()
    for path, callback in pairs({ [INTERACT_CLASS .. ":StartInteractTimer"] = on_hold_start,
        [INTERACT_CLASS .. ":CancelHeldInteraction"] = on_hold_stop, [INTERACT_CLASS .. ":FinishInteractTimer"] = on_hold_finished }) do
        if not hooked[path] then
            local ok = pcall(RegisterHook, path, function(self)
                local ok_call, message = pcall(callback, self:get())
                if not ok_call then
                    log("Hold hook error: " .. tostring(message))
                end
            end)
            if ok then
                hooked[path] = true
                log("Hooked " .. path:match(":(.*)$"))
            end
        end
    end
end

local function handle_requests(live)
    local player = current_player()
    if not player then
        return
    end
    local fresh_press = key_seen and key_quiet_ticks >= KEY_RELEASE_TICKS
    key_quiet_ticks = key_seen and 0 or key_quiet_ticks + 1
    key_seen = false
    if is_paused(player) then
        hold_requests = {}
        return
    end
    -- Only a new press: the hold that started the scene is usually still down when it begins.
    if fresh_press and scene then
        let_go_requested = true
    end
    if not scene then
        for _, request in ipairs(hold_requests) do
            local ghost = live[request.ghost]
            if ghost and lust_ok(player, ghost) and live[request.pair.a_address] and live[request.pair.b_address] then
                start_scene("double", request.pair, live, player)
                break
            end
        end
    end
    hold_requests = {}
    while admin_spawns > 0 do
        admin_spawns = admin_spawns - 1
        spawn_admin_pair(player)
    end
    local wanted = admin_grab
    if wanted and not scene then
        local pair = pair_to_grab(live, player, admin_grab ~= nil)
        if pair then
            start_scene(wanted, pair, live, player)
        elseif admin_grab then
            log("No kissing pair to grab")
        end
    end
    admin_grab = nil
end

-- The key only raises a flag. Everything else happens on the game thread's tick.
RegisterKeyBind(Key.E, function()
    key_seen = true
end)

-- Shows in the admin panel if it is installed.
local admin_tab = AdminTabs.AddTab({ id = "GhostKiss", title = "Ghost Kiss" })
admin_tab:AddButton("Spawn Kissing Pair", function()
    admin_spawns = admin_spawns + 1
end)
admin_tab:AddButton("Grab Nearest Pair", function()
    admin_grab = "double"
end)
admin_tab:AddButton("Neck Scene On Nearest Pair", function()
    admin_grab = "neck"
end)
admin_tab:AddButton("Let Go", function()
    let_go_requested = true
end)

-- The game dissolves an enemy only for a player with the Purification perk, by playing its dissolve timeline. When the
-- perk could not be read, a pair that is not dissolving was not purified, so it goes back to kissing.
local function check_purifying(live)
    for index = #purifying, 1, -1 do
        local entry = purifying[index]
        if clock >= entry.check_at then
            table.remove(purifying, index)
            local pair = entry.pair
            local a, b = live[pair.a_address], live[pair.b_address]
            local dissolving = false
            for _, ghost in ipairs({ a, b }) do
                local ok, playing = pcall(function()
                    return ghost.DissolveTimeline:IsPlaying()
                end)
                dissolving = dissolving or (ok and playing)
            end
            if dissolving or not a or not b then
                log("Purified the pair")
            else
                log("No Purification perk, so the pair was not purified and goes back to kissing")
                local anim = load_anim()
                if anim then
                    begin_pair(a, b, pair.centre, pair.yaw, anim, { saved_a = pair.saved_a, saved_b = pair.saved_b,
                        manual = pair.manual, spawned = pair.spawned, calm_until = clock + CALM_SECONDS })
                end
            end
        end
    end
end

-- Everything from the previous level is gone, so a level change forgets all of it.
local function check_level_change()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then
        return false
    end
    local address = world:GetAddress()
    if address ~= world_address then
        world_address = address
        active_pairs = {}
        seen_ghosts = {}
        purifying = {}
        if scene then
            scene = nil
            ModRef:SetSharedVariable(BODY_HOLD_VARIABLE, false)
        end
        game_scene = nil
        neck_lists = {}
    end
    return true
end

local scene_errors = 0

LoopInGameThreadWithDelay(TICK_MS, function()
    AdminTabs.Poll()
    if not check_level_change() then
        return
    end
    clock = clock + TICK_MS / 1000.0
    local live = live_ghosts()
    tick_count = tick_count + 1
    if tick_count % WATCH_EVERY_TICKS == 0 then
        watch_pairs(live)
        check_new_ghosts(live)
    end
    for _, pair in ipairs(active_pairs) do
        local ghost = live[pair.a_address]
        if ghost then
            update_audio(pair, ghost)
        end
    end
    local ok, message = pcall(function()
        if tick_count % 20 == 0 then
            hook_holds()
            add_neck_to_lists()
        end
        check_holds(live)
        handle_requests(live)
        if scene then
            update_scene(live)
        end
        update_game_scene(live)
        check_purifying(live)
    end)
    if not ok then
        -- One failure must not leave the player stuck, so the scene is dropped and the player let go.
        scene_errors = scene_errors + 1
        if scene_errors <= 5 then
            log("Scene error: " .. tostring(message))
        end
        if scene then
            pcall(end_scene, live, current_player(), "error", true)
            scene = nil
        end
        if game_scene then
            pcall(abort_game_scene, live, current_player(), "error")
            game_scene = nil
        end
    end
end)

math.randomseed(os.time())
log("Loaded.")
