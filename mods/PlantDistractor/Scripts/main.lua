-- Penis plants and mouth plants locked in a loop, two penis plants rubbing their tips together, one penis plant docked
-- inside another, or two penis plants mashing their tips together and failing to dock, as a distraction for the
-- player. They ignore the player for now.
-- Pairs appear at random spots when a level loads, and Free Mode always has at least one. Each pair's kind is random.
-- Every so often a pair gets excited and slams once, and less often it climaxes.
--
-- The game can delete any object and reuse its memory at any moment, so nothing here keeps a game object between
-- ticks: pairs are remembered by address and looked up fresh from the game's live list.

local UEHelpers = require("UEHelpers")
local ModSettings = require("ModSettings")

local sex_volume = ModSettings.AddSlider({
    mod = "PlantDistractor",
    key = "PlantSexVolume",
    label = "Plant Sex Volume",
    tab = "audio",
    min = 0,
    max = 100,
    step = 5,
    default = 50,
    format = "%d%%",
})
local NORMAL_VOLUME_SETTING = 50.0 -- The slider value that plays the sounds at their authored loudness.

local ACTOR_CLASS = "/Script/Engine.SkeletalMeshActor"
local PLANT_SCALE = 2.0
local SPAWN_DISTANCE_CM = 350.0
local MOBILITY_MOVABLE = 2
local ALWAYS_TICK_POSE = 1 -- Animation time keeps running, but bones only update while the pair is on screen.
local LOOP_SECONDS = 8.333

-- Where pairs appear, by map name in lower case. Menus, dialogue scenes and boss arenas are left out on purpose.
local LEVELS = {
    freemode = { chance = 1.0, min = 1, max = 3, always = true, delay_seconds = 4.0 },
    lustdungeon = { chance = 0.6, min = 1, max = 2, delay_seconds = 10.0 },
    lustdungeon_classic = { chance = 0.6, min = 1, max = 2, delay_seconds = 10.0 },
    envydungeon = { chance = 0.6, min = 1, max = 2, delay_seconds = 10.0 },
    envydungeon_classic = { chance = 0.6, min = 1, max = 2, delay_seconds = 10.0 },
    gluttony = { chance = 0.6, min = 1, max = 2, delay_seconds = 10.0 },
    gluttony_classic = { chance = 0.6, min = 1, max = 2, delay_seconds = 10.0 },
    overworld = { chance = 0.4, min = 1, max = 1, delay_seconds = 10.0 },
}
local RETRY_SECONDS = 5.0 -- A dungeon may still be building, so a failed search tries again later.
local MAX_SEARCHES = 8
local SEARCHES_BEFORE_FALLBACK = 3 -- A level that must have a pair stops being picky after this many.
local SPOTS_PER_SEARCH = 12
local NEARBY_SEARCH_RADIUS_CM = 2500.0
local SEARCH_RADIUS_CM = 6000.0
local MIN_PLAYER_DISTANCE_CM = 600.0 -- A pair never appears right beside the player.
local MIN_PAIR_DISTANCE_CM = 1000.0
-- The room a pair needs, from the plants' size at PLANT_SCALE.
local HALF_LENGTH_CM = 150.0 -- The tip pair is the longer of the two.
local HALF_WIDTH_CM = 60.0
local HEADROOM_CM = 130.0
local MAX_FLOOR_STEP_CM = 18.0
local TRACE_CHANNEL_VISIBILITY = 0
local DRAW_NO_DEBUG = 0
local NO_COLOUR = { R = 0, G = 0, B = 0, A = 0 }

-- Sounds are from Shinlalala's Lewd Sound Pack, CC BY-SA 4.0: "Lewd sounds by Shinlalala".
local SOUND_DIR = "/Game/Mods/PlantDistractor/Audio/"
local SOUND_COUNTS = { Plap = 16, Stroke = 10, Wet = 12, Cum = 3 }
local PITCH_LOW, PITCH_HIGH = 0.92, 1.08 -- So repeats of one sound do not sound identical.
local GULP_PITCH = 0.62 -- The pack has no swallow, so a wet sound played low stands in.
local AUDIBLE_DISTANCE_CM = 2500.0 -- Further away than this, a pair's sounds are not worth playing.
-- Each is { seconds into the clip, sound group, volume, fixed pitch if any }. The times are where each push lands,
-- from plant_sound_timing.py, and pushes that travel further are louder.
local LOOP_SOUNDS = {
    { 0.375, "Stroke", 0.60 }, { 0.792, "Stroke", 0.70 }, { 0.792, "Wet", 0.40 }, { 1.208, "Stroke", 0.50 },
    { 1.625, "Stroke", 0.70 }, { 1.625, "Wet", 0.40 }, { 2.042, "Stroke", 0.45 }, { 2.458, "Stroke", 0.65 },
    { 2.458, "Wet", 0.40 }, { 2.875, "Stroke", 0.55 }, { 3.292, "Stroke", 0.60 }, { 3.708, "Stroke", 0.55 },
    { 4.125, "Stroke", 0.40 }, { 4.583, "Stroke", 0.65 }, { 4.583, "Wet", 0.40 }, { 4.958, "Stroke", 0.45 },
    { 5.375, "Stroke", 0.50 }, { 5.792, "Stroke", 0.60 }, { 6.208, "Stroke", 0.55 }, { 6.625, "Stroke", 0.65 },
    { 6.625, "Wet", 0.40 }, { 7.042, "Stroke", 0.45 }, { 7.500, "Stroke", 0.75 }, { 7.500, "Wet", 0.45 },
    { 7.875, "Stroke", 0.40 }, { 8.292, "Stroke", 0.50 },
}
local SLAM_SOUNDS = {
    { 0.875, "Plap", 1.00 }, { 0.875, "Wet", 0.75 }, { 1.292, "Stroke", 0.50 }, { 1.708, "Stroke", 0.40 },
}
local CLIMAX_SOUNDS = {
    { 0.333, "Plap", 0.50 }, { 0.958, "Plap", 0.65 }, { 1.417, "Plap", 0.80 }, -- The three building strokes.
    { 2.417, "Plap", 1.00 }, { 2.417, "Wet", 0.70 }, -- The final push.
    { 2.583, "Cum", 1.00 }, { 3.083, "Cum", 0.90 }, { 3.667, "Cum", 0.80 }, { 4.333, "Cum", 0.65 }, { 5.083, "Cum", 0.50 },
    { 5.583, "Wet", 0.90, GULP_PITCH }, { 6.833, "Wet", 0.80, GULP_PITCH }, -- The two swallows.
    { 7.208, "Stroke", 0.45 }, { 7.625, "Stroke", 0.35 },
}
-- Each clip picks up from the loop at one moment and hands back to it later on; from build_plant_pair.py's output.
local SLAM = {
    name = "AS_PlantPair_Slam",
    sounds = SLAM_SOUNDS,
    start_seconds = 4.5,
    resume_seconds = 6.5,
    length_seconds = 2.0,
    min_wait_seconds = 12.0,
    max_wait_seconds = 30.0,
}
local CLIMAX = {
    name = "AS_PlantPair_Climax",
    sounds = CLIMAX_SOUNDS,
    start_seconds = 0.25,
    resume_seconds = 8.25,
    length_seconds = 8.0,
    min_wait_seconds = 60.0,
    max_wait_seconds = 120.0,
}
-- The tip pair's sounds are from the plan in build_plant_tips.py: a soft rub on each press, and wet ones as the tips
-- part for a kiss and land again.
local TIP_LOOP_SOUNDS = {
    { 0.020, "Stroke", 0.35 }, { 0.833, "Stroke", 0.40 }, { 1.900, "Wet", 0.35 }, { 2.920, "Wet", 0.60 },
    { 3.333, "Stroke", 0.35 }, { 4.167, "Stroke", 0.40 }, { 5.000, "Stroke", 0.35 }, { 5.650, "Wet", 0.35 },
    { 6.670, "Wet", 0.60 }, { 7.500, "Stroke", 0.40 },
}
local TIP_SLAM_SOUNDS = {
    { 0.750, "Wet", 1.00 }, { 0.750, "Plap", 0.50 }, { 1.100, "Stroke", 0.40 }, { 1.500, "Stroke", 0.30 },
}
local TIP_CLIMAX_SOUNDS = {
    { 0.667, "Wet", 0.50 }, { 1.333, "Wet", 0.65 }, { 2.000, "Wet", 0.80 }, -- The three building strokes.
    { 2.583, "Cum", 1.00 }, { 3.083, "Cum", 0.90 }, { 3.667, "Cum", 0.80 }, { 4.333, "Cum", 0.65 }, { 5.083, "Cum", 0.50 },
    { 4.167, "Wet", 0.25 }, { 4.667, "Wet", 0.25 }, { 5.250, "Wet", 0.25 }, { 5.917, "Wet", 0.25 }, { 6.667, "Wet", 0.25 }, -- Each drip letting go.
    { 6.500, "Stroke", 0.40 }, { 7.200, "Stroke", 0.30 },
}
local TIP_SLAM = {
    name = "AS_PlantTips_Slam",
    sounds = TIP_SLAM_SOUNDS,
    start_seconds = 3.5,
    resume_seconds = 5.5,
    length_seconds = 2.0,
    min_wait_seconds = 12.0,
    max_wait_seconds = 30.0,
}
local TIP_CLIMAX = {
    name = "AS_PlantTips_Climax",
    sounds = TIP_CLIMAX_SOUNDS,
    start_seconds = 0.1667,
    resume_seconds = 8.1667,
    length_seconds = 8.0,
    min_wait_seconds = 60.0,
    max_wait_seconds = 120.0,
}
-- The docking pair's sounds are from dock_plan in build_plant_tips.py: each stroke lands at its deepest point.
local DOCK_LOOP_SOUNDS = {
    { 0.208, "Stroke", 0.55 }, { 0.208, "Wet", 0.35 }, { 1.042, "Stroke", 0.60 }, { 1.875, "Stroke", 0.55 },
    { 1.875, "Wet", 0.35 }, { 2.708, "Stroke", 0.50 }, { 3.542, "Stroke", 0.50 }, { 3.542, "Wet", 0.35 },
    { 4.375, "Stroke", 0.45 }, { 5.208, "Stroke", 0.50 }, { 5.208, "Wet", 0.35 }, { 6.042, "Stroke", 0.55 },
    { 6.875, "Stroke", 0.60 }, { 6.875, "Wet", 0.35 }, { 7.708, "Stroke", 0.55 },
}
local DOCK_SLAM_SOUNDS = {
    { 0.750, "Plap", 0.85 }, { 0.750, "Wet", 0.80 }, { 1.100, "Stroke", 0.45 }, { 1.500, "Stroke", 0.35 },
}
local DOCK_CLIMAX_SOUNDS = {
    { 0.400, "Plap", 0.50 }, { 1.200, "Plap", 0.70 }, { 2.000, "Plap", 0.90 }, { 2.000, "Wet", 0.70 }, -- The three strokes.
    { 2.583, "Cum", 1.00 }, { 3.083, "Cum", 0.90 }, { 3.667, "Cum", 0.80 }, { 4.333, "Cum", 0.65 }, { 5.083, "Cum", 0.50 },
    { 4.167, "Wet", 0.25 }, { 4.667, "Wet", 0.25 }, { 5.250, "Wet", 0.25 }, { 5.917, "Wet", 0.25 }, { 6.667, "Wet", 0.25 }, -- Each drip letting go.
    { 6.500, "Stroke", 0.40 }, { 7.200, "Stroke", 0.30 },
}
local DOCK_SLAM = {
    name = "AS_PlantDock_Slam",
    sounds = DOCK_SLAM_SOUNDS,
    start_seconds = 3.5,
    resume_seconds = 5.5,
    length_seconds = 2.0,
    min_wait_seconds = 12.0,
    max_wait_seconds = 30.0,
}
local DOCK_CLIMAX = {
    name = "AS_PlantDock_Climax",
    sounds = DOCK_CLIMAX_SOUNDS,
    start_seconds = 0.1667,
    resume_seconds = 8.1667,
    length_seconds = 8.0,
    min_wait_seconds = 60.0,
    max_wait_seconds = 120.0,
}
-- The struggling pair's sounds are from attempt_motion in build_plant_tips.py: a hit as each try lands, and a wet push
-- as the heads mash together.
local STRUGGLE_LOOP_SOUNDS = {
    { 0.840, "Plap", 0.70 }, { 0.840, "Wet", 0.50 }, { 1.460, "Wet", 0.35 },
    { 3.000, "Plap", 0.60 }, { 3.000, "Wet", 0.45 }, { 3.620, "Wet", 0.30 },
    { 5.030, "Plap", 0.75 }, { 5.030, "Wet", 0.50 }, { 5.670, "Wet", 0.35 },
    { 7.220, "Plap", 0.60 }, { 7.220, "Wet", 0.45 }, { 7.830, "Wet", 0.30 },
}
local STRUGGLE_SLAM_SOUNDS = {
    { 0.767, "Plap", 1.00 }, { 0.767, "Wet", 0.85 }, { 1.250, "Wet", 0.40 },
}
local STRUGGLE_CLIMAX_SOUNDS = {
    { 0.367, "Plap", 0.50 }, { 1.033, "Plap", 0.70 }, { 1.700, "Plap", 0.90 }, { 1.700, "Wet", 0.70 }, -- The frantic tries.
    { 2.583, "Cum", 1.00 }, { 3.083, "Cum", 0.90 }, { 3.667, "Cum", 0.80 }, { 4.333, "Cum", 0.65 }, { 5.083, "Cum", 0.50 },
    { 4.167, "Wet", 0.25 }, { 4.667, "Wet", 0.25 }, { 5.250, "Wet", 0.25 }, { 5.917, "Wet", 0.25 }, { 6.667, "Wet", 0.25 }, -- Each drip letting go.
    { 6.500, "Stroke", 0.40 }, { 7.200, "Stroke", 0.30 },
}
local STRUGGLE_SLAM = {
    name = "AS_PlantStruggle_Slam",
    sounds = STRUGGLE_SLAM_SOUNDS,
    start_seconds = 3.5,
    resume_seconds = 5.5,
    length_seconds = 2.0,
    min_wait_seconds = 20.0,
    max_wait_seconds = 40.0,
}
-- They only struggle until they cum, so this comes sooner than for the other kinds.
local STRUGGLE_CLIMAX = {
    name = "AS_PlantStruggle_Climax",
    sounds = STRUGGLE_CLIMAX_SOUNDS,
    start_seconds = 0.1667,
    resume_seconds = 8.1667,
    length_seconds = 8.0,
    min_wait_seconds = 30.0,
    max_wait_seconds = 60.0,
}
-- The kinds of pair. The two root bones are what a pair is lined up by.
local KINDS = {
    {
        name = "mouth pair",
        mesh = "SK_PlantPair",
        loop = "AS_PlantPair_Loop",
        root_bones = { "PenisPlant_Root", "MouthPlant_Root" },
        sound_bone = "Mth_DEF-Head",
        loop_sounds = LOOP_SOUNDS,
        slam = SLAM,
        climax = CLIMAX,
    },
    {
        name = "tip pair",
        mesh = "SK_PlantTips",
        loop = "AS_PlantTips_Loop",
        root_bones = { "PlantA_Root", "PlantB_Root" },
        sound_bone = "A_DEF-PenisMid_Tip",
        loop_sounds = TIP_LOOP_SOUNDS,
        slam = TIP_SLAM,
        climax = TIP_CLIMAX,
    },
    {
        name = "docking pair",
        mesh = "SK_PlantDock",
        loop = "AS_PlantDock_Loop",
        root_bones = { "PlantA_Root", "PlantB_Root" },
        sound_bone = "B_DEF-PenisMid_Tip",
        loop_sounds = DOCK_LOOP_SOUNDS,
        slam = DOCK_SLAM,
        climax = DOCK_CLIMAX,
    },
    {
        name = "struggling pair",
        mesh = "SK_PlantStruggle",
        loop = "AS_PlantStruggle_Loop",
        root_bones = { "PlantA_Root", "PlantB_Root" },
        sound_bone = "A_DEF-PenisMid_Tip",
        loop_sounds = STRUGGLE_LOOP_SOUNDS,
        slam = STRUGGLE_SLAM,
        climax = STRUGGLE_CLIMAX,
    },
}
local CLIP_PACKAGE_DIR = "/Game/Mods/PlantDistractor/"
-- The admin panel adds one to this for each pair it asks for. Mods cannot call each other, but they can share this.
local SPAWN_REQUESTS_VARIABLE = "PlantDistractor_SpawnRequests"
local REQUEST_SEARCHES_BEFORE_FALLBACK = 3
local REQUEST_RETRY_SECONDS = 1.0
local START_WINDOW_SECONDS = 0.1 -- How soon after its start moment a clip may still begin.
local TICK_MS = 33

local pairs_list = {} -- { address, kind, clip, sound_position, slam_clock, climax_clock }
local level_plan = nil
local world_address = nil
local last_sound_number = {}
local requests_seen = 0
local requests_waiting = 0
local request_searches = 0
local next_request_clock = 0.0
local requested_spots = {}

local function log(message)
    print("[PlantDistractor] " .. message .. "\n")
end

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

local function current_player()
    local controller = FindFirstOf("PlayerController")
    if controller and controller:IsValid() and controller.Pawn:IsValid() then
        return controller.Pawn
    end
    return nil
end

local function format_location(v)
    return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z)
end

local function distance_2d(a, b)
    local dx, dy = a.X - b.X, a.Y - b.Y
    return math.sqrt(dx * dx + dy * dy)
end

-- Every tracked pair that is safe to use during this tick, by address. While a level tears down, an actor can still
-- be listed after its component is gone, and calling a function on the missing component crashes the game.
local function live_pairs()
    local live = {}
    if #pairs_list == 0 then
        return live
    end
    local tracked = {}
    for _, pair in ipairs(pairs_list) do
        tracked[pair.address] = true
    end
    for _, actor in ipairs(FindAllOf("SkeletalMeshActor") or {}) do
        if actor:IsValid() and tracked[actor:GetAddress()] then
            local component = actor.SkeletalMeshComponent
            if component and component:IsValid() then
                live[actor:GetAddress()] = { actor = actor, component = component }
            end
        end
    end
    return live
end

local function bone_location(component, bone)
    return component:GetSocketLocation(UEHelpers.FindOrAddFName(bone))
end

-- Lines the pair up along the given heading and centres it on the target, measured from its own bones, so this does
-- not depend on which way the importer laid out the mesh's axes. The first plant's roots rest on the floor, and a
-- mouth plant's sit lower by design.
local function arrange(actor, component, kind, target, heading)
    local hit = {}
    local first = bone_location(component, kind.root_bones[1])
    local second = bone_location(component, kind.root_bones[2])
    local current = math.deg(math.atan(second.Y - first.Y, second.X - first.X))
    local yaw = actor:K2_GetActorRotation().Yaw + (heading - current)
    actor:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, true)
    first = bone_location(component, kind.root_bones[1])
    second = bone_location(component, kind.root_bones[2])
    local location = actor:K2_GetActorLocation()
    actor:K2_SetActorLocation({
        X = location.X + target.X - (first.X + second.X) / 2,
        Y = location.Y + target.Y - (first.Y + second.Y) / 2,
        Z = location.Z + target.Z - first.Z,
    }, false, hit, true)
end

local function random_between(low, high)
    return low + math.random() * (high - low)
end

local function plan_slam(pair)
    local slam = pair.kind.slam
    pair.slam_clock = os.clock() + random_between(slam.min_wait_seconds, slam.max_wait_seconds)
end

local function plan_climax(pair)
    local climax = pair.kind.climax
    pair.climax_clock = os.clock() + random_between(climax.min_wait_seconds, climax.max_wait_seconds)
end

local function spawn_pair(kind, target, heading)
    local mesh = load_by_package(CLIP_PACKAGE_DIR .. kind.mesh, kind.mesh)
    local anim = load_by_package(CLIP_PACKAGE_DIR .. kind.loop, kind.loop)
    if not mesh or not anim then
        log("Could not load the plants: mesh " .. tostring(mesh ~= nil) .. ", animation " .. tostring(anim ~= nil))
        return nil
    end
    local actor = UEHelpers.GetWorld():SpawnActor(StaticFindObject(ACTOR_CLASS), target, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not actor or not actor:IsValid() then
        log("Could not spawn the actor")
        return nil
    end
    local component = actor.SkeletalMeshComponent
    component:SetMobility(MOBILITY_MOVABLE)
    component:SetSkeletalMeshAsset(mesh)
    component.VisibilityBasedAnimTickOption = ALWAYS_TICK_POSE
    actor:SetActorEnableCollision(false)
    actor:SetActorScale3D({ X = PLANT_SCALE, Y = PLANT_SCALE, Z = PLANT_SCALE })
    component:PlayAnimation(anim, true)
    arrange(actor, component, kind, target, heading)
    -- Pairs start at different points in the loop, so they never move in step.
    local start = random_between(0.0, LOOP_SECONDS)
    component:SetPosition(start, false)
    local pair = { address = actor:GetAddress(), kind = kind, clip = nil, sound_position = start }
    plan_slam(pair)
    plan_climax(pair)
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

-- Checks that a pair lying along this heading has level floor under it, no wall through it, and room above it.
local function room_for_pair(context, x, y, z, heading)
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
        if not height or math.abs(height - middle) > MAX_FLOOR_STEP_CM then
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

local function far_enough(point, origin, plan)
    if distance_2d(point, origin) < MIN_PLAYER_DISTANCE_CM then
        return false
    end
    for _, placed in ipairs(plan.placed) do
        if distance_2d(point, placed) < MIN_PAIR_DISTANCE_CM then
            return false
        end
    end
    return true
end

local function search_for_spot(player, origin, plan)
    local counts = { walkable = 0, visible = 0, none = 0, too_close = 0, no_room = 0 }
    for _ = 1, SPOTS_PER_SEARCH do
        local point = random_walkable_point(player, origin)
        if point then
            counts.walkable = counts.walkable + 1
        else
            point = random_visible_point(player, origin)
            if point then
                counts.visible = counts.visible + 1
            else
                counts.none = counts.none + 1
            end
        end
        if point then
            if far_enough(point, origin, plan) then
                local heading = random_between(-180.0, 180.0)
                local floor = room_for_pair(player, point.X, point.Y, point.Z, heading)
                if floor then
                    return { X = point.X, Y = point.Y, Z = floor }, heading
                end
                counts.no_room = counts.no_room + 1
            else
                counts.too_close = counts.too_close + 1
            end
        end
    end
    log(string.format("No spot in search %d: %d walkable points, %d visible points, %d found nothing, %d too close, %d without room",
        plan.searches, counts.walkable, counts.visible, counts.none, counts.too_close, counts.no_room))
    return nil
end

-- The last resort for a level that must have a pair: ahead of the player, on the floor they stand on.
local function place_ahead_of_player(player)
    local location = player:K2_GetActorLocation()
    local forward = player:GetActorForwardVector()
    local feet = location.Z - player.CapsuleComponent:GetScaledCapsuleHalfHeight()
    return {
        X = location.X + forward.X * SPAWN_DISTANCE_CM,
        Y = location.Y + forward.Y * SPAWN_DISTANCE_CM,
        Z = feet,
    }, player:K2_GetActorRotation().Yaw + 90.0
end

local function update_level_plan()
    local plan = level_plan
    if not plan or #plan.placed >= plan.want or os.clock() < plan.next_clock then
        return
    end
    local player = current_player()
    if not player then
        plan.next_clock = os.clock() + 1.0
        return
    end
    local origin = player:K2_GetActorLocation()
    plan.searches = plan.searches + 1
    local ok, spot, heading = pcall(search_for_spot, player, origin, plan)
    if not ok then
        log("The spot search failed: " .. tostring(spot))
        spot = nil
    end
    if not spot and plan.always and #plan.placed == 0 and plan.searches >= SEARCHES_BEFORE_FALLBACK then
        spot, heading = place_ahead_of_player(player)
        log("No free spot found, so placing ahead of the player")
    end
    local kind = KINDS[math.random(#KINDS)]
    if spot and spawn_pair(kind, spot, heading) then
        table.insert(plan.placed, { X = spot.X, Y = spot.Y })
        log(string.format("Placed %s, pair %d of %d, at %s", kind.name, #plan.placed, plan.want, format_location(spot)))
    end
    if plan.searches >= MAX_SEARCHES and #plan.placed < plan.want then
        log(string.format("Stopped searching with %d of %d pairs placed", #plan.placed, plan.want))
        plan.want = #plan.placed
    end
    plan.next_clock = os.clock() + (spot and 0.2 or RETRY_SECONDS)
end

-- Every spot this level already has a pair on, so a requested pair keeps its distance from them.
local function taken_spots()
    local spots = {}
    for _, spot in ipairs(requested_spots) do
        table.insert(spots, spot)
    end
    for _, spot in ipairs(level_plan and level_plan.placed or {}) do
        table.insert(spots, spot)
    end
    return spots
end

-- Places one pair the admin panel asked for. The panel pauses the game, so this waits for it to close, and a pair
-- never spawns into a paused world.
local function update_spawn_requests()
    local total = ModRef:GetSharedVariable(SPAWN_REQUESTS_VARIABLE) or 0
    if total > requests_seen then
        requests_waiting = requests_waiting + total - requests_seen
        requests_seen = total
        log(string.format("%d requested pairs waiting", requests_waiting))
    end
    if requests_waiting == 0 or os.clock() < next_request_clock then
        return
    end
    local player = current_player()
    if not player or StaticFindObject("/Script/Engine.Default__GameplayStatics"):IsGamePaused(player) then
        return
    end
    request_searches = request_searches + 1
    local origin = player:K2_GetActorLocation()
    local ok, spot, heading = pcall(search_for_spot, player, origin, { placed = taken_spots(), searches = request_searches })
    if not ok then
        log("The spot search failed: " .. tostring(spot))
        spot = nil
    end
    if not spot then
        if request_searches < REQUEST_SEARCHES_BEFORE_FALLBACK then
            next_request_clock = os.clock() + REQUEST_RETRY_SECONDS
            return
        end
        spot, heading = place_ahead_of_player(player)
        log("No free spot found, so placing ahead of the player")
    end
    local kind = KINDS[math.random(#KINDS)]
    if spawn_pair(kind, spot, heading) then
        table.insert(requested_spots, { X = spot.X, Y = spot.Y })
        log(string.format("Placed requested %s at %s", kind.name, format_location(spot)))
    end
    -- A request that failed even so is dropped, as trying again every tick would only repeat the failure.
    requests_waiting = requests_waiting - 1
    request_searches = 0
    next_request_clock = os.clock() + 0.2
end

-- Everything from the previous level is gone, so a new level forgets it all and decides what this one gets.
local function begin_level(world)
    world_address = world:GetAddress()
    pairs_list = {}
    level_plan = nil
    requested_spots = {}
    request_searches = 0
    local name = world:GetFName():ToString()
    local settings = LEVELS[string.lower(name)]
    if not settings then
        log("Level " .. name .. ": no plants here")
        return
    end
    if math.random() >= settings.chance then
        log("Level " .. name .. ": no plants this time")
        return
    end
    local want = math.random(settings.min, settings.max)
    level_plan = { want = want, placed = {}, searches = 0, always = settings.always,
        next_clock = os.clock() + settings.delay_seconds }
    log(string.format("Level %s: looking for %d spots", name, want))
end

-- Picks a sound other than the group's last one, so the same sound never plays twice in a row.
local function pick_sound_name(group)
    local number = math.random(SOUND_COUNTS[group])
    if SOUND_COUNTS[group] > 1 then
        while number == last_sound_number[group] do
            number = math.random(SOUND_COUNTS[group])
        end
    end
    last_sound_number[group] = number
    return string.format("S_Plant_%s_%03d", group, number)
end

local function play_sound(pair, live_pair, event)
    local volume = event[3] * sex_volume.value / NORMAL_VOLUME_SETTING
    if volume <= 0.0 then
        return
    end
    local name = pick_sound_name(event[2])
    local sound = load_by_package(SOUND_DIR .. name, name)
    if not sound then
        log("Could not load " .. name)
        return
    end
    local pitch = event[4] or random_between(PITCH_LOW, PITCH_HIGH)
    StaticFindObject("/Script/Engine.Default__GameplayStatics"):PlaySoundAtLocation(live_pair.actor, sound,
        bone_location(live_pair.component, pair.kind.sound_bone), { Pitch = 0, Yaw = 0, Roll = 0 }, volume, pitch, 0.0, nil, nil, nil, nil)
end

-- Plays every sound the animation has passed since the last tick. Going by its own position keeps the sounds on the
-- motion, and they stop whenever the game pauses it.
local function play_sounds_between(pair, live_pair, sounds, from, to)
    for _, event in ipairs(sounds) do
        if event[1] > from and event[1] <= to then
            play_sound(pair, live_pair, event)
        end
    end
end

local function update_sounds(pair, live_pair, position, audible)
    if audible then
        local sounds = pair.clip and pair.clip.sounds or pair.kind.loop_sounds
        if position < pair.sound_position then
            -- The loop came back around.
            play_sounds_between(pair, live_pair, sounds, pair.sound_position, math.huge)
            play_sounds_between(pair, live_pair, sounds, -1.0, position)
        else
            play_sounds_between(pair, live_pair, sounds, pair.sound_position, position)
        end
    end
    pair.sound_position = position
end

local function try_start(pair, live_pair, clip, due, position)
    if not due or position < clip.start_seconds or position >= clip.start_seconds + START_WINDOW_SECONDS then
        return false
    end
    local animation = load_by_package(CLIP_PACKAGE_DIR .. clip.name, clip.name)
    if not animation then
        log("Could not load " .. clip.name)
        plan_slam(pair)
        plan_climax(pair)
        return false
    end
    live_pair.component:PlayAnimation(animation, false)
    pair.clip = clip
    pair.sound_position = -1.0
    log("Playing " .. clip.name)
    return true
end

local function update_pair(pair, live_pair, player_location)
    local component = live_pair.component
    local position = component:GetPosition()
    local audible = player_location
        and distance_2d(live_pair.actor:K2_GetActorLocation(), player_location) <= AUDIBLE_DISTANCE_CM
    update_sounds(pair, live_pair, position, audible)
    if pair.clip then
        if position >= pair.clip.length_seconds - 0.04 then
            local loop = load_by_package(CLIP_PACKAGE_DIR .. pair.kind.loop, pair.kind.loop)
            if loop then
                component:PlayAnimation(loop, true)
                component:SetPosition(pair.clip.resume_seconds, false)
                pair.sound_position = pair.clip.resume_seconds
            end
            -- A slam straight after a climax would break the mood, so the slam waits its full time again.
            if pair.clip == pair.kind.climax then
                plan_climax(pair)
            end
            plan_slam(pair)
            pair.clip = nil
        end
        return
    end
    local now = os.clock()
    if try_start(pair, live_pair, pair.kind.climax, now >= pair.climax_clock, position) then
        return
    end
    try_start(pair, live_pair, pair.kind.slam, now >= pair.slam_clock, position)
end

local function update_pairs()
    if #pairs_list == 0 then
        return
    end
    local live = live_pairs()
    local player = current_player()
    local player_location = player and player:K2_GetActorLocation() or nil
    -- Backwards, because a pair that is gone is removed from the list.
    for index = #pairs_list, 1, -1 do
        local pair = pairs_list[index]
        local live_pair = live[pair.address]
        if live_pair then
            update_pair(pair, live_pair, player_location)
        else
            log("A pair is gone")
            table.remove(pairs_list, index)
        end
    end
end

-- Returns the world only when it is safe to use, starting a new level's plan if the world has changed.
local function current_world()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then
        return nil
    end
    if world:GetAddress() ~= world_address then
        begin_level(world)
    end
    return world
end

LoopInGameThreadWithDelay(TICK_MS, function()
    -- A script error here would otherwise stop this loop for the rest of the session.
    local ok, problem = pcall(function()
        if current_world() then
            update_level_plan()
            update_spawn_requests()
            update_pairs()
        end
    end)
    if not ok then
        log("Tick failed, trying again: " .. tostring(problem))
    end
    ModSettings.Poll()
end)

math.randomseed(os.time())
log("Loaded. Pairs appear on their own.")
