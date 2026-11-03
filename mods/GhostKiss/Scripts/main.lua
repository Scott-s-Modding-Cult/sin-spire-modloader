-- LostSoul ghosts sometimes spawn as a kissing pair, and only notice the player at very close range.
--
-- Pressing Interact (E) near a kissing pair grabs both heads, one in each hand, for a double blowjob scene that ends
-- in a climax and purifies both. Shift+E instead takes the nearer head by its neck and thrusts up through it
-- and out of its mouth, while the other waits, and purifies both too. Pressing E again lets go early, and they go back to
-- kissing.
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
local CUM_YAW = 285.0 -- The angle the user chose for the same shaft in NurseTouch.
local CUM_YAW_VARIABLE = "NurseTouch_CumYaw"
local KEEP_RELATIVE_OFFSET = 0
local NO_POOLING = 0
local ANIMATION_BLUEPRINT = 0
local MOVEMENT_NONE = 0
local MOVEMENT_WALKING = 1

local active_pairs = {}
local scene = nil -- The running scene, if any.
local purifying = {} -- Pairs whose end of scene sequence ran, waiting to see whether the game dissolves them.
local grab_requested = false
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

local function release(ghost, saved)
    if not ghost then
        return
    end
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
        elseif player and clock >= pair.calm_until then
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

local function play_scene_sound(kind, key, ghost, position)
    local mouth = ghost.Mesh:GetSocketLocation(fname("mouth_ent"))
    if kind == "kiss" then
        scene.kiss.mouth = { X = mouth.X, Y = mouth.Y, Z = mouth.Z }
        play_sound(scene.kiss, ghost, random_between(0.6, 0.8))
        return
    end
    local entry = SOUNDS[kind]
    if kind == "suck" and position < scene.slurp_until[key] then
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
        scene.slurp_until[key] = position + duration * 0.8
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
    local yaw = ModRef:GetSharedVariable(CUM_YAW_VARIABLE) or CUM_YAW
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
        if called > 0 then
            table.insert(purifying, { pair = pair, check_at = clock + PURIFY_CHECK_SECONDS })
            return
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
        play_scene_sound(event[3], event[2], ghosts[event[2]], position)
    end
    for _, at in ipairs(timing.spurts) do
        if scene.last_position < at and position >= at then
            spurt(player)
        end
    end
    scene.last_position = position
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

local key_pressed = false
local neck_key_pressed = false
local admin_grab = nil -- The scene the admin panel asked for.

local function handle_requests(live)
    local player = current_player()
    if not player then
        return
    end
    if is_paused(player) then
        key_pressed, neck_key_pressed = false, false -- Interact pressed in a menu is not a grab.
        return
    end
    if key_pressed or neck_key_pressed then
        if scene then
            let_go_requested = true
        else
            -- Shift+E may also fire the plain E binding, so the neck scene wins when both came in.
            grab_requested = neck_key_pressed and "neck" or "double"
        end
        key_pressed, neck_key_pressed = false, false
    end
    while admin_spawns > 0 do
        admin_spawns = admin_spawns - 1
        spawn_admin_pair(player)
    end
    local wanted = admin_grab or grab_requested
    if wanted and not scene then
        local pair = pair_to_grab(live, player, admin_grab ~= nil)
        if pair then
            start_scene(wanted, pair, live, player)
        elseif admin_grab then
            log("No kissing pair to grab")
        end
    end
    grab_requested, admin_grab = false, nil
end

-- The key only raises a flag. Everything else happens on the game thread's tick.
RegisterKeyBind(Key.E, function()
    key_pressed = true
end)
RegisterKeyBind(Key.E, { ModifierKey.SHIFT }, function()
    neck_key_pressed = true
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

-- The game dissolves an enemy only for a player with the Purification perk, by playing its dissolve timeline. A pair
-- that is not dissolving was not purified, so it goes back to kissing.
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
        handle_requests(live)
        if scene then
            update_scene(live)
        end
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
    end
end)

math.randomseed(os.time())
log("Loaded.")
