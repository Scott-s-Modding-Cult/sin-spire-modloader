-- LostSoul ghosts sometimes spawn as a kissing pair, and only notice the player at very close range.
--
-- The game can delete any object and reuse its memory at any moment, and calling a function on a deleted
-- object crashes it. So nothing here keeps a game object between ticks: ghosts are remembered by address and
-- looked up fresh from the game's live list, and assets are fetched each time they are used.

local UEHelpers = require("UEHelpers")

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
local MOVEMENT_NONE = 0
local MOVEMENT_WALKING = 1

local active_pairs = {}
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
        saved_b = hold_still(b),
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
    ExecuteWithDelay(WAKE_TARGET_DELAY_MS, function()
        ExecuteInGameThread(function()
            local player = current_player()
            if player then
                local now = live_ghosts()
                target_player(now[a_address], player)
                target_player(now[b_address], player)
            end
        end)
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
        elseif player then
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
    end
    return true
end

LoopAsync(TICK_MS, function()
    ExecuteInGameThread(function()
        if not check_level_change() then
            return
        end
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
    end)
    return false
end)

math.randomseed(os.time())
log("Loaded.")
