-- A distraction: two Creepers scissoring and kissing, with tongues and saliva, at a random spot in the cave where the
-- real Creeper lives, and in Free Mode.
--
-- The Creeper's own blueprint starts a boss fight as soon as it exists, so these are plain meshes with no AI: they
-- cannot attack or be hurt, and they ignore the player.
--
-- The game can delete any object and reuse its memory at any moment, so nothing here keeps a game object between
-- ticks: pairs are remembered by address and looked up fresh from the game's live list.

local UEHelpers = require("UEHelpers")

local BODY_PACKAGE = "/Game/Models/Characters/Stalkers/Creeper/SK_Creeper"
local BODY_NAME = "SK_Creeper"
local BODY_ANIM_PACKAGE = "/Game/Mods/CreeperPair/AS_Creeper_Scissor"
local BODY_ANIM_NAME = "AS_Creeper_Scissor"
local TONGUE_PACKAGE = "/Game/Mods/CreeperPair/SK_CreeperTongue"
local TONGUE_NAME = "SK_CreeperTongue"
local TONGUE_ANIM_PACKAGE = "/Game/Mods/CreeperPair/AS_CreeperTongue_Lash"
local TONGUE_ANIM_NAME = "AS_CreeperTongue_Lash"
local TONGUE_BONE = "head"
local SALIVA_PACKAGE = "/Game/Mods/CreeperPair/SK_CreeperSaliva"
local SALIVA_NAME = "SK_CreeperSaliva"
local SALIVA_ANIM_PACKAGE = "/Game/Mods/CreeperPair/AS_CreeperSaliva_Stretch"
local SALIVA_ANIM_NAME = "AS_CreeperSaliva_Stretch"
local ACTOR_CLASS = "/Script/Engine.SkeletalMeshActor"
local MOBILITY_MOVABLE = 2
local ALWAYS_TICK_POSE = 1 -- Animation time keeps running, but bones only update while the pair is on screen.
local ATTACH_SNAP_TO_TARGET = 2
local SPAWN_DISTANCE_CM = 500.0
local TICK_MS = 50
local PAIR_TURNS = { 0.0, 180.0 }

-- The Creeper has no voice of her own in the game's files, and she shares the Witness's sex table.
local VOICE_DIR = "/Game/Audio/Voice/Monsters/Witness/"
local FAST_MOAN_COUNT = 8
local LONG_MOAN_COUNT = 4
local VOICE_HEIGHT_CM = 160.0
local AUDIBLE_DISTANCE_CM = 3000.0

-- Where a pair appears, by map name in lower case. The cave is tight and uneven, so it tries for longer as the player
-- walks through, allows rougher floor, and never drops a pair in front of the player.
local LEVELS = {
    freemode = { delay_seconds = 4.0, max_searches = 8, max_floor_step_cm = 18.0, fallback_after = 3 },
    tutorialcave = { delay_seconds = 8.0, max_searches = 36, max_floor_step_cm = 40.0 },
}
local RETRY_SECONDS = 5.0 -- A level may still be building, or the player may need to get closer, so a failed search tries again.
local SPOTS_PER_SEARCH = 12
local SEARCH_RADIUS_CM = 6000.0
local NEARBY_SEARCH_RADIUS_CM = 2500.0
local MIN_PLAYER_DISTANCE_CM = 1000.0 -- A pair never appears right beside the player.
-- The room a pair needs, from the Creepers' size with their legs spread.
local HALF_LENGTH_CM = 190.0
local HALF_WIDTH_CM = 150.0
local HEADROOM_CM = 240.0
local TRACE_CHANNEL_VISIBILITY = 0
local DRAW_NO_DEBUG = 0
local NO_COLOUR = { R = 0, G = 0, B = 0, A = 0 }

local pairs_list = {}
local level_plan = nil
local world_address = nil
local elapsed_seconds = 0.0

local function log(message)
    print("[CreeperPair] " .. message .. "\n")
end

local function random_between(low, high)
    return low + math.random() * (high - low)
end

local function current_player()
    local controller = FindFirstOf("PlayerController")
    if controller and controller:IsValid() and controller.Pawn:IsValid() then
        return controller.Pawn
    end
    return nil
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

-- Every live mesh actor right now, by address. Only objects from this list are safe to call during this tick.
local function live_actors()
    local live = {}
    for _, actor in ipairs(FindAllOf("SkeletalMeshActor") or {}) do
        if actor:IsValid() then
            live[actor:GetAddress()] = actor
        end
    end
    return live
end

local function spawn_mesh_actor(mesh, anim, location, yaw)
    local actor = UEHelpers.GetWorld():SpawnActor(StaticFindObject(ACTOR_CLASS), location, { Pitch = 0, Yaw = yaw, Roll = 0 })
    if not actor or not actor:IsValid() then
        return nil
    end
    local component = actor.SkeletalMeshComponent
    component:SetMobility(MOBILITY_MOVABLE)
    component:SetSkeletalMeshAsset(mesh)
    component.VisibilityBasedAnimTickOption = ALWAYS_TICK_POSE
    actor:SetActorEnableCollision(false)
    component:PlayAnimation(anim, true)
    return actor
end

-- Spawns the bodies on one spot, half a turn apart, because the clip meets itself on the vertical axis there.
local function spawn_pair(target, yaw, turns)
    local body = load_by_package(BODY_PACKAGE, BODY_NAME)
    local body_anim = load_by_package(BODY_ANIM_PACKAGE, BODY_ANIM_NAME)
    local tongue = load_by_package(TONGUE_PACKAGE, TONGUE_NAME)
    local tongue_anim = load_by_package(TONGUE_ANIM_PACKAGE, TONGUE_ANIM_NAME)
    if not body or not body_anim then
        log("Could not load the bodies: mesh " .. tostring(body ~= nil) .. ", animation " .. tostring(body_anim ~= nil))
        return nil
    end
    local pair = {
        addresses = {},
        next_voice = elapsed_seconds + random_between(0.2, 0.8),
        voice_turn = false,
        voice_at = { X = target.X, Y = target.Y, Z = target.Z + VOICE_HEIGHT_CM },
    }
    for _, turn in ipairs(turns) do
        local actor = spawn_mesh_actor(body, body_anim, target, yaw + turn)
        if not actor then
            log("Could not spawn a body")
            return pair
        end
        table.insert(pair.addresses, actor:GetAddress())
        if tongue and tongue_anim then
            local tongue_actor = spawn_mesh_actor(tongue, tongue_anim, target, yaw + turn)
            if tongue_actor then
                -- The tongue is modelled in the head's frame and takes on the head bone's scale, which it allows for.
                tongue_actor.SkeletalMeshComponent:K2_AttachToComponent(actor.SkeletalMeshComponent,
                    UEHelpers.FindOrAddFName(TONGUE_BONE), ATTACH_SNAP_TO_TARGET, ATTACH_SNAP_TO_TARGET, ATTACH_SNAP_TO_TARGET, false)
                table.insert(pair.addresses, tongue_actor:GetAddress())
            end
        else
            log("Could not load the tongue: mesh " .. tostring(tongue ~= nil) .. ", animation " .. tostring(tongue_anim ~= nil))
        end
    end
    -- The strings run between the two mouths. Their clip is keyed in the pair's own space.
    local saliva = load_by_package(SALIVA_PACKAGE, SALIVA_NAME)
    local saliva_anim = load_by_package(SALIVA_ANIM_PACKAGE, SALIVA_ANIM_NAME)
    local saliva_actor = saliva and saliva_anim and spawn_mesh_actor(saliva, saliva_anim, target, yaw)
    if saliva_actor then
        table.insert(pair.addresses, saliva_actor:GetAddress())
    else
        log("Could not start the saliva: mesh " .. tostring(saliva ~= nil) .. ", animation " .. tostring(saliva_anim ~= nil))
    end
    table.insert(pairs_list, pair)
    return pair
end

-- Looks straight down for the floor at a point, and returns its height.
local function floor_height(context, x, y, z)
    local hit = {}
    local found = UEHelpers.GetKismetSystemLibrary():LineTraceSingle(context, { X = x, Y = y, Z = z + 120.0 },
        { X = x, Y = y, Z = z - 250.0 }, TRACE_CHANNEL_VISIBILITY, false, {}, DRAW_NO_DEBUG, hit, true, NO_COLOUR, NO_COLOUR, 0.0)
    if found and hit.ImpactPoint and hit.ImpactPoint.Z then
        return hit.ImpactPoint.Z
    end
    return nil
end

local function is_clear(context, from, to)
    local hit = {}
    return not UEHelpers.GetKismetSystemLibrary():LineTraceSingle(context, from, to, TRACE_CHANNEL_VISIBILITY, false, {},
        DRAW_NO_DEBUG, hit, true, NO_COLOUR, NO_COLOUR, 0.0)
end

-- Checks that a pair along this heading has level floor under it, no wall through it, and room above it.
local function room_for_pair(context, x, y, z, heading, max_floor_step_cm)
    local middle = floor_height(context, x, y, z)
    if not middle then
        return nil
    end
    local along_x, along_y = math.cos(math.rad(heading)), math.sin(math.rad(heading))
    local across_x, across_y = -along_y, along_x
    local checks = {
        { x + along_x * HALF_LENGTH_CM, y + along_y * HALF_LENGTH_CM },
        { x - along_x * HALF_LENGTH_CM, y - along_y * HALF_LENGTH_CM },
        { x + across_x * HALF_WIDTH_CM, y + across_y * HALF_WIDTH_CM },
        { x - across_x * HALF_WIDTH_CM, y - across_y * HALF_WIDTH_CM },
    }
    for _, point in ipairs(checks) do
        local height = floor_height(context, point[1], point[2], middle)
        if not height or math.abs(height - middle) > max_floor_step_cm then
            return nil
        end
    end
    local centre = { X = x, Y = y, Z = middle + 70.0 }
    for _, point in ipairs(checks) do
        if not is_clear(context, centre, { X = point[1], Y = point[2], Z = middle + 70.0 }) then
            return nil
        end
    end
    if not is_clear(context, centre, { X = x, Y = y, Z = middle + HEADROOM_CM }) then
        return nil
    end
    return middle
end

-- A random walkable point the game's own AI could reach, or nil if the level has no navigation yet.
local function random_walkable_point(player, origin)
    local navigation = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    if not navigation or not navigation:IsValid() then
        return nil
    end
    local point = {}
    if navigation:K2_GetRandomReachablePointInRadius(player, origin, point, SEARCH_RADIUS_CM, nil, nil) and point.X then
        return point
    end
    return nil
end

-- For when navigation gives nothing: a random point the player has a clear line to, so it is in a space they can see.
local function random_visible_point(player, origin)
    local angle = math.rad(random_between(-180.0, 180.0))
    local distance = random_between(MIN_PLAYER_DISTANCE_CM, NEARBY_SEARCH_RADIUS_CM)
    local point = { X = origin.X + math.cos(angle) * distance, Y = origin.Y + math.sin(angle) * distance, Z = origin.Z }
    if is_clear(player, origin, point) then
        return point
    end
    return nil
end

local function search_for_spot(player, origin, settings)
    local minimum_squared = MIN_PLAYER_DISTANCE_CM * MIN_PLAYER_DISTANCE_CM
    for _ = 1, SPOTS_PER_SEARCH do
        local point = random_walkable_point(player, origin) or random_visible_point(player, origin)
        if point then
            local dx, dy = point.X - origin.X, point.Y - origin.Y
            if dx * dx + dy * dy >= minimum_squared then
                local heading = random_between(-180.0, 180.0)
                -- The clip's axis of length is the rig's Y, so the room check runs along the facing direction.
                local floor = room_for_pair(player, point.X, point.Y, point.Z, heading + 90.0, settings.max_floor_step_cm)
                if floor then
                    return { X = point.X, Y = point.Y, Z = floor }, heading
                end
            end
        end
    end
    return nil
end

-- The last resort: ahead of the player, on the floor they stand on.
local function spot_ahead_of_player(player)
    local location = player:K2_GetActorLocation()
    local forward = player:GetActorForwardVector()
    return {
        X = location.X + forward.X * SPAWN_DISTANCE_CM,
        Y = location.Y + forward.Y * SPAWN_DISTANCE_CM,
        Z = location.Z - player.CapsuleComponent:GetScaledCapsuleHalfHeight(),
    }, player:K2_GetActorRotation().Yaw
end

local function update_level_plan()
    local plan = level_plan
    if not plan or elapsed_seconds < plan.next_time then
        return
    end
    local player = current_player()
    if not player then
        plan.next_time = elapsed_seconds + 1.0
        return
    end
    plan.searches = plan.searches + 1
    local ok, spot, heading = pcall(search_for_spot, player, player:K2_GetActorLocation(), plan.settings)
    if not ok then
        log("The spot search failed: " .. tostring(spot))
        spot = nil
    end
    if not spot and plan.settings.fallback_after and plan.searches >= plan.settings.fallback_after then
        spot, heading = spot_ahead_of_player(player)
        log("No free spot found, so placing ahead of the player")
    end
    if spot then
        if spawn_pair(spot, heading, PAIR_TURNS) then
            log(string.format("Placed the pair at %.0f, %.0f, %.0f", spot.X, spot.Y, spot.Z))
        end
        level_plan = nil
    elseif plan.searches >= plan.settings.max_searches then
        log(string.format("Stopped after %d searches with no room for a pair", plan.searches))
        level_plan = nil
    else
        plan.next_time = elapsed_seconds + RETRY_SECONDS
    end
end

-- Everything from the previous level is gone, so a new level forgets it all and decides what this one gets.
local function check_level_change()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then
        return false
    end
    local address = world:GetAddress()
    if address ~= world_address then
        world_address = address
        pairs_list = {}
        level_plan = nil
        local name = world:GetFName():ToString()
        local settings = LEVELS[string.lower(name)]
        if settings then
            level_plan = { settings = settings, searches = 0, next_time = elapsed_seconds + settings.delay_seconds }
            log("Level " .. name .. ": looking for a spot")
        end
    end
    return true
end

-- Mostly fast moans, sometimes a long one. A different one each time, so no sound repeats back to back.
local function pick_voice(last)
    local name
    repeat
        if math.random() < 0.8 then
            name = string.format("S_WitnessMoanFast%02d", math.random(FAST_MOAN_COUNT))
        else
            name = string.format("S_WitnessMoan%02d", math.random(LONG_MOAN_COUNT))
        end
    until name ~= last
    return name
end

local function update_audio(pair, live, player)
    if elapsed_seconds < pair.next_voice then
        return
    end
    pair.next_voice = elapsed_seconds + random_between(0.7, 1.8)
    local actor = live[pair.addresses[1]]
    if not actor or not player then
        return
    end
    local location = player:K2_GetActorLocation()
    local dx, dy = location.X - pair.voice_at.X, location.Y - pair.voice_at.Y
    if dx * dx + dy * dy > AUDIBLE_DISTANCE_CM * AUDIBLE_DISTANCE_CM then
        return
    end
    -- The two take turns, told apart by pitch.
    pair.voice_turn = not pair.voice_turn
    local name = pick_voice(pair.last_voice)
    pair.last_voice = name
    local sound = load_by_package(VOICE_DIR .. name, name)
    if sound then
        StaticFindObject("/Script/Engine.Default__GameplayStatics"):PlaySoundAtLocation(actor, sound, pair.voice_at,
            { Pitch = 0, Yaw = 0, Roll = 0 }, random_between(0.8, 1.0), pair.voice_turn and random_between(0.84, 0.9) or random_between(0.96, 1.04),
            0.0, nil, nil, nil, nil)
    end
end

LoopAsync(TICK_MS, function()
    ExecuteInGameThread(function()
        if not check_level_change() then
            return
        end
        elapsed_seconds = elapsed_seconds + TICK_MS / 1000.0
        update_level_plan()
        if #pairs_list > 0 then
            local live = live_actors()
            local player = current_player()
            for _, pair in ipairs(pairs_list) do
                update_audio(pair, live, player)
            end
        end
    end)
    return false
end)

math.randomseed(os.time())
log("Loaded.")
