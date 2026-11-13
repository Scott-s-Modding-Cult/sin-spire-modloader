-- A variation of the Twisted Nurse: she stands with her gun put away and her dress exposed, touching herself, until the
-- player comes close or hurts her, and then she is an ordinary enemy again. Each new nurse may turn out this way, and
-- Free Mode always gets one. Half of them are futa: the player's penis, as its own mesh on her pelvis bone, which she
-- strokes, and which stays with her when she wakes. Others gain a partner where they stand, who stands behind them and
-- gropes them. A pair is two real nurses, and hurting or approaching either wakes both.
--
-- The game can delete any object and reuse its memory at any moment, so nothing here keeps a game object between
-- ticks: nurses are remembered by address and looked up fresh from the game's live list.

local UEHelpers = require("UEHelpers")

local NURSE_PACKAGE = "/Game/Blueprints/AI/Enemies/BP_TwistedNurse"
local NURSE_CLASS = "BP_TwistedNurse_C"
local ANIM_PACKAGE = "/Game/Mods/NurseTouch/AS_Twisted_Touch"
local ANIM_NAME = "AS_Twisted_Touch"
local VOICE_DIR = "/Game/Audio/Voice/Monsters/Twisted/"
local TICK_MS = 100
local TOUCH_CHANCE = 0.35 -- Chance that a newly spawned nurse is this variation.
local MIN_PLAYER_CM = 500.0 -- She never starts right beside the player, except when placed on purpose.
local WAKE_RADIUS_CM = 150.0
local SETTLE_SECONDS = 0.5 -- Her outfit is only created a few frames after she spawns, and she needs to land.
local GIVE_UP_SECONDS = 10.0
local WAKE_TARGET_DELAY_MS = 400 -- The AI restarts first, or it would reset the target it was just given.
local COMBAT_STATE_ATTACKING = 4
local MOVEMENT_WALKING = 1
local ANIMATION_BLUEPRINT = 0

local PAIR_SHARE = 0.33 -- Of the nurses that become this variation.
local FUTA_SHARE = 0.5 -- Of the rest.
local MOD_DIR = "/Game/Mods/NurseTouch/"
local STROKE_ANIM_NAME = "AS_Twisted_Stroke"
local SHAFT_MESH_NAME = "SK_NurseShaft"
local SHAFT_STROKE_NAME = "AS_NurseShaft_Stroke"
local SHAFT_IDLE_NAME = "AS_NurseShaft_Idle"
local SHAFT_MATERIAL_PACKAGE = "/Game/Models/Characters/Human/Player/M_PlayerFull"
local SHAFT_MATERIAL_NAME = "M_PlayerFull"
local SHAFT_ACTOR_CLASS = "SkeletalMeshActor"
local SHAFT_ACTOR_PATH = "/Script/Engine.SkeletalMeshActor"
local SHAFT_BONE = "pelvis" -- The mesh is modelled in this bone's frame.
local RESYNC_SECONDS = 0.1 -- Two clips that must match run apart when a mesh is off screen and stops ticking.
-- The game's own effect, on the bone its scenes use. Unturned it sprayed back towards her. The angle was chosen in game.
local CUM_YAW = 285.0
local CUM_YAW_VARIABLE = "NurseTouch_CumYaw" -- The admin panel's setting, which replaces CUM_YAW when it is there.
local CUM_PACKAGE = "/Game/Blueprints/Effects/NS_Cum"
local CUM_NAME = "NS_Cum"
local CUM_BONE = "penis_06"
local CUM_SOUND_DIR = "/Game/Audio/SexFoley/Homemade/"
local CUM_SOUND_NAME = "Cum"
local CUM_SECONDS = { 9.75, 10.27 } -- On two of the shaft clip's strong throbs, from make_futa_keys.py.
local KEEP_RELATIVE_OFFSET = 0
local NO_POOLING = 0
local MOBILITY_MOVABLE = 2
local ALWAYS_TICK_POSE = 1
local ATTACH_SNAP_TO_TARGET = 2

-- Both clips of a pair are keyed in one space, so both nurses stand on one origin facing one way.
local GROPE_FRONT_NAME = "AS_Twisted_GropeFront"
local GROPE_BACK_NAME = "AS_Twisted_GropeBack"
local MESH_FORWARD_YAW = 90.0 -- The rig faces its mesh's +Y axis.
local WAKE_PUSH_CM = 45.0 -- Waking partners move apart, because their capsules overlap.
local BACK_VOICE_GAP = 3.0 -- The one groping is quieter, and leaves the climax to her partner.

-- From make_touch_keys.py. The stroke and grope clips have the same timing.
local CLIP_SECONDS = 12.0
local CLIMAX_SECONDS = 9.36
local QUIET_UNTIL_SECONDS = 11.0 -- After the climax she catches her breath.

local FAST_MOAN_COUNT = 7
local VOICE_ABOVE_CENTRE_CM = 40.0
local AUDIBLE_DISTANCE_CM = 2500.0

-- Free Mode has no nurse unless the player adds one, so one of each is placed there. Map name in lower case.
local PLACED_LEVELS = { freemode = { delay_seconds = 4.0, kinds = { "futa", "touch", "pair" } } }
local PLACE_SPREAD_CM = 220.0 -- With no navigation they all land ahead of the player, so each stands further along.
local PLACE_DISTANCE_CM = 1200.0
local PLACE_ATTEMPTS = 12
local SPAWN_LIFT_CM = 100.0

local active = {}
local seen = {}
local shafts = {} -- Nurse address to the address of the shaft actor on her, for as long as she lives.
local level_plan = nil
local world_address = nil
local elapsed_seconds = 0.0

local function log(message)
    print("[NurseTouch] " .. message .. "\n")
end

local function random_between(low, high)
    return low + math.random() * (high - low)
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

-- Every live nurse right now, by address. Only objects from this list are safe to call during this tick.
local function live_nurses()
    local live = {}
    for _, nurse in ipairs(FindAllOf(NURSE_CLASS) or {}) do
        if nurse:IsValid() then
            live[nurse:GetAddress()] = nurse
        end
    end
    return live
end

local function set_weapon_shown(nurse, shown)
    local weapon = nurse.CurrentWeapon
    if weapon and weapon:IsValid() then
        weapon:SetActorHiddenInGame(not shown)
    end
end

local function live_shafts()
    local live = {}
    if next(shafts) then
        for _, actor in ipairs(FindAllOf(SHAFT_ACTOR_CLASS) or {}) do
            if actor:IsValid() then
                live[actor:GetAddress()] = actor
            end
        end
    end
    return live
end

-- Returns false if any part is missing, and she is then an ordinary touching nurse.
local function attach_shaft(nurse)
    local mesh = load_by_package(MOD_DIR .. SHAFT_MESH_NAME, SHAFT_MESH_NAME)
    local anim = load_by_package(MOD_DIR .. SHAFT_STROKE_NAME, SHAFT_STROKE_NAME)
    if not mesh or not anim then
        log("Could not load the shaft: mesh " .. tostring(mesh ~= nil) .. ", animation " .. tostring(anim ~= nil))
        return false
    end
    local actor = UEHelpers.GetWorld():SpawnActor(StaticFindObject(SHAFT_ACTOR_PATH), nurse:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
    if not actor or not actor:IsValid() then
        log("Could not spawn the shaft")
        return false
    end
    local component = actor.SkeletalMeshComponent
    component:SetMobility(MOBILITY_MOVABLE)
    component:SetSkeletalMeshAsset(mesh)
    component.VisibilityBasedAnimTickOption = ALWAYS_TICK_POSE
    actor:SetActorEnableCollision(false)
    local material = load_by_package(SHAFT_MATERIAL_PACKAGE, SHAFT_MATERIAL_NAME)
    if material then
        component:SetMaterial(0, material)
    else
        log("Could not load the player's material")
    end
    component:K2_AttachToComponent(nurse.Mesh, UEHelpers.FindOrAddFName(SHAFT_BONE),
        ATTACH_SNAP_TO_TARGET, ATTACH_SNAP_TO_TARGET, ATTACH_SNAP_TO_TARGET, false)
    component:PlayAnimation(anim, true)
    shafts[nurse:GetAddress()] = actor:GetAddress()
    return true
end

-- Stops her, with her gun put away and her dress exposed, and returns what wake needs to give it all back.
local function hold_still(nurse)
    local entry = {
        health = nurse.BPC_HealthComponent.CurrentHealth,
        life_state = nurse.BPC_HealthComponent.LifeState,
        next_voice = elapsed_seconds + random_between(0.5, 2.0),
        last_position = 0.0,
    }
    if nurse.Controller:IsValid() then
        nurse.Controller:StopMovement()
        if nurse.Controller.BrainComponent:IsValid() then
            nurse.Controller.BrainComponent:StopLogic("NurseTouch")
        end
    end
    if nurse.AIPerception:IsValid() then
        nurse.AIPerception:Deactivate()
    end
    -- Her capsule keeps its collision, so she can still be shot and that wakes her.
    nurse.CharacterMovement:DisableMovement()
    set_weapon_shown(nurse, false)
    nurse:Expose()
    return entry
end

local function play_clip(nurse, anim, entry)
    nurse.Mesh:PlayAnimation(anim, true)
    nurse.Mesh:SetMorphTarget(UEHelpers.FindOrAddFName("Bod_Cleavage"), 0.5, true)
    active[nurse:GetAddress()] = entry
end

local function start_touching(nurse, anim, futa, entry)
    entry = entry or hold_still(nurse)
    entry.futa = futa
    play_clip(nurse, anim, entry)
end

-- Moves her so her mesh origin lands on the target, wherever the mesh sits inside the actor.
local function place(nurse, target, face_yaw)
    local hit = {}
    nurse:K2_SetActorRotation({ Pitch = 0, Yaw = face_yaw - MESH_FORWARD_YAW - nurse.Mesh.RelativeRotation.Yaw, Roll = 0 }, true)
    local mesh_location = nurse.Mesh:K2_GetComponentLocation()
    local actor_location = nurse:K2_GetActorLocation()
    nurse:K2_SetActorLocation({
        X = actor_location.X + target.X - mesh_location.X,
        Y = actor_location.Y + target.Y - mesh_location.Y,
        Z = actor_location.Z + target.Z - mesh_location.Z,
    }, false, hit, true)
end

-- The first nurse has been held since the partner was spawned. Her capsule was off so the partner could spawn inside it.
local function begin_pair(front, back, front_entry)
    local front_anim = load_by_package(MOD_DIR .. GROPE_FRONT_NAME, GROPE_FRONT_NAME)
    local back_anim = load_by_package(MOD_DIR .. GROPE_BACK_NAME, GROPE_BACK_NAME)
    if not front_anim or not back_anim then
        log("Could not load the pair's animations: front " .. tostring(front_anim ~= nil) .. ", back " .. tostring(back_anim ~= nil))
        return false
    end
    front:SetActorEnableCollision(true)
    local back_entry = hold_still(back)
    local centre = front.Mesh:K2_GetComponentLocation()
    -- The pair turns to face the player when it starts, so the groping is seen from the front, not the back.
    local yaw = random_between(-180.0, 180.0)
    local player = current_player()
    if player then
        local at = player:K2_GetActorLocation()
        yaw = math.deg(math.atan(at.Y - centre.Y, at.X - centre.X))
    end
    place(front, centre, yaw)
    place(back, centre, yaw)
    local front_address, back_address = front:GetAddress(), back:GetAddress()
    front_entry.partner, back_entry.partner = back_address, front_address
    front_entry.push_x, front_entry.push_y = math.cos(math.rad(yaw)) * WAKE_PUSH_CM, math.sin(math.rad(yaw)) * WAKE_PUSH_CM
    back_entry.push_x, back_entry.push_y = -front_entry.push_x, -front_entry.push_y
    back_entry.follows = front_address
    back_entry.voice_gap = BACK_VOICE_GAP
    back_entry.no_climax = true
    play_clip(front, front_anim, front_entry)
    play_clip(back, back_anim, back_entry)
    return true
end

local function target_player(nurse, player)
    if not nurse.Controller:IsValid() then
        return
    end
    local blackboard = nurse.Controller.Blackboard
    if blackboard:IsValid() then
        blackboard:SetValueAsObject(UEHelpers.FindOrAddFName("CurrentEnemy"), player)
        blackboard:SetValueAsEnum(UEHelpers.FindOrAddFName("CombatState"), COMBAT_STATE_ATTACKING)
    end
    nurse:SetCurrentEnemy(player)
    nurse:SetCombatState(COMBAT_STATE_ATTACKING)
end

-- Gives her back everything start_touching took. A nurse knocked down or killed keeps her state and gets no AI back.
local function wake(nurse, entry, reason)
    local address = nurse:GetAddress()
    active[address] = nil
    log("Woken: " .. reason)
    if entry.push_x then
        local location = nurse:K2_GetActorLocation()
        local hit = {}
        nurse:K2_SetActorLocation({ X = location.X + entry.push_x, Y = location.Y + entry.push_y, Z = location.Z }, false, hit, true)
    end
    nurse.Mesh:SetAnimationMode(ANIMATION_BLUEPRINT, true)
    if entry.futa then
        -- She stays exposed, as the closed dress would have the shaft poking through it.
        local shaft = live_shafts()[shafts[address]]
        local idle = load_by_package(MOD_DIR .. SHAFT_IDLE_NAME, SHAFT_IDLE_NAME)
        if shaft and idle then
            shaft.SkeletalMeshComponent:PlayAnimation(idle, true)
        end
    else
        nurse:Unexpose()
    end
    set_weapon_shown(nurse, true)
    if nurse.BPC_HealthComponent.LifeState ~= entry.life_state then
        return
    end
    nurse.CharacterMovement:SetMovementMode(MOVEMENT_WALKING, 0)
    if nurse.AIPerception:IsValid() then
        nurse.AIPerception:Activate(true)
    end
    if nurse.Controller:IsValid() and nurse.Controller.BrainComponent:IsValid() then
        nurse.Controller.BrainComponent:RestartLogic()
    end
    ExecuteInGameThreadWithDelay(WAKE_TARGET_DELAY_MS, function()
        local player = current_player()
        local now = live_nurses()[address]
        if player and now then
            target_player(now, player)
        end
    end)
end

local function pick_moan(last)
    local name
    repeat
        if math.random() < 0.7 then
            name = string.format("S_Twisted_SexMoanFast%02d", math.random(FAST_MOAN_COUNT))
        else
            name = math.random() < 0.5 and "S_Twisted_SexMoan" or "S_Twisted_SexMoan2"
        end
    until name ~= last
    return name
end

local function play_voice(nurse, name, player, volume, directory)
    local location = nurse:K2_GetActorLocation()
    local range_squared = AUDIBLE_DISTANCE_CM * AUDIBLE_DISTANCE_CM
    local distance = distance_squared(location, player:K2_GetActorLocation())
    if distance > range_squared then
        return
    end
    local sound = load_by_package((directory or VOICE_DIR) .. name, name)
    if sound then
        local fade = 1.0 - math.sqrt(distance / range_squared)
        StaticFindObject("/Script/Engine.Default__GameplayStatics"):PlaySoundAtLocation(nurse, sound,
            { X = location.X, Y = location.Y, Z = location.Z + VOICE_ABOVE_CENTRE_CM }, { Pitch = 0, Yaw = 0, Roll = 0 },
            volume * fade, random_between(0.96, 1.04), 0.0, nil, nil, nil, nil)
    end
end

-- Follows the clip's own position, so her voice builds with her body and stops when the game pauses.
local function update_voice(nurse, entry, player)
    local position = nurse.Mesh:GetPosition()
    if not entry.no_climax and entry.last_position < CLIMAX_SECONDS and position >= CLIMAX_SECONDS then
        play_voice(nurse, "S_Twisted_SexClimax", player, 1.0)
        entry.next_voice = elapsed_seconds + (QUIET_UNTIL_SECONDS - CLIMAX_SECONDS)
    elseif elapsed_seconds >= entry.next_voice then
        local heat = math.min(position / CLIMAX_SECONDS, 1.0)
        entry.next_voice = elapsed_seconds
            + (random_between(0.7, 1.2) + (1.0 - heat) * random_between(1.0, 2.2)) * (entry.voice_gap or 1.0)
        entry.last_voice = pick_moan(entry.last_voice)
        play_voice(nurse, entry.last_voice, player, 0.55 + 0.4 * heat)
    end
    entry.last_position = position % CLIP_SECONDS
end

-- Keeps one clip on another, so a hand stays on what it holds. Near the loop point the two can read a whole clip apart.
local function resync(component, position)
    local apart = math.abs(component:GetPosition() - position)
    if apart > RESYNC_SECONDS and apart < CLIP_SECONDS - RESYNC_SECONDS then
        component:SetPosition(position, false)
    end
end

local function spurt(shaft)
    local system = load_by_package(CUM_PACKAGE, CUM_NAME)
    local library = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not system or not library:IsValid() then
        log("Could not load the cum effect")
        return
    end
    local yaw = ModRef:GetSharedVariable(CUM_YAW_VARIABLE) or CUM_YAW
    library:SpawnSystemAttached(system, shaft.SkeletalMeshComponent, UEHelpers.FindOrAddFName(CUM_BONE),
        { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = yaw, Roll = 0 }, KEEP_RELATIVE_OFFSET, true, true, NO_POOLING, true)
    log("Spurt at yaw " .. yaw)
end

-- Follows her clip's position like her voice does, so it stops when the game pauses or she is off screen.
local function update_cum(nurse, entry, shaft, player)
    local position = nurse.Mesh:GetPosition()
    local last = entry.last_cum_position or 0.0
    for index, at in ipairs(CUM_SECONDS) do
        if last < at and position >= at then
            spurt(shaft)
            if index == 1 and player then
                play_voice(nurse, CUM_SOUND_NAME, player, 1.0, CUM_SOUND_DIR)
            end
        end
    end
    entry.last_cum_position = position
end

-- Attached actors outlive their parent, so a shaft goes when its nurse does.
local function clean_up_shafts(live, shaft_actors)
    for nurse_address, shaft_address in pairs(shafts) do
        if not live[nurse_address] then
            shafts[nurse_address] = nil
            local shaft = shaft_actors[shaft_address]
            if shaft then
                shaft:K2_DestroyActor()
            end
        end
    end
end

local function watch_active(live, player, shaft_actors)
    for address, entry in pairs(active) do
        local nurse = live[address]
        local reason = nil
        if not nurse then
            active[address] = nil
            reason = "her partner is gone"
        elseif nurse.BPC_HealthComponent.CurrentHealth < entry.health
            or nurse.BPC_HealthComponent.LifeState ~= entry.life_state then
            reason = "she was hurt"
        elseif player and distance_squared(nurse:K2_GetActorLocation(), player:K2_GetActorLocation())
            <= WAKE_RADIUS_CM * WAKE_RADIUS_CM then
            reason = "the player came close"
        end
        if reason then
            -- Partners wake together, or one would be left holding the air.
            if nurse then
                wake(nurse, entry, reason)
            end
            local partner_entry = entry.partner and active[entry.partner]
            local partner = partner_entry and live[entry.partner]
            if partner then
                wake(partner, partner_entry, reason)
            end
        else
            local shaft = entry.futa and shaft_actors[shafts[address]]
            local followed = entry.follows and live[entry.follows]
            if followed then
                resync(nurse.Mesh, followed.Mesh:GetPosition())
            end
            if shaft then
                resync(shaft.SkeletalMeshComponent, nurse.Mesh:GetPosition())
                update_cum(nurse, entry, shaft, player)
            end
            if player then
                update_voice(nurse, entry, player)
            end
        end
    end
end

local function pick_kind()
    if math.random() < PAIR_SHARE then
        return "pair"
    end
    return math.random() < FUTA_SHARE and "futa" or "touch"
end

local function start_alone(nurse, kind, entry)
    local futa = kind == "futa" and attach_shaft(nurse)
    local anim = futa and load_by_package(MOD_DIR .. STROKE_ANIM_NAME, STROKE_ANIM_NAME)
        or load_by_package(ANIM_PACKAGE, ANIM_NAME)
    if anim then
        start_touching(nurse, anim, futa, entry)
        log(futa and "A futa nurse is stroking herself" or "A nurse is touching herself")
    else
        log("Could not load the animation")
    end
end

local function spawn_nurse(location)
    local class = load_by_package(NURSE_PACKAGE, NURSE_CLASS)
    if not class then
        log("Could not load the nurse")
        return nil
    end
    local nurse = UEHelpers.GetWorld():SpawnActor(class, location, { Pitch = 0, Yaw = random_between(-180.0, 180.0), Roll = 0 })
    if not nurse or not nurse:IsValid() then
        log("Could not spawn the nurse")
        return nil
    end
    if not nurse.Controller:IsValid() then
        nurse:SpawnDefaultController()
    end
    return nurse
end

-- Holds her where she stands and spawns the partner on her. The pair starts once the partner has settled too.
local function start_waiting_for_partner(nurse, address)
    local held = hold_still(nurse)
    nurse:SetActorEnableCollision(false)
    local partner = spawn_nurse(nurse:K2_GetActorLocation())
    if partner then
        seen[partner:GetAddress()] = { since = elapsed_seconds, partner_of = address, held = held }
    else
        nurse:SetActorEnableCollision(true)
        start_alone(nurse, "touch", held)
    end
end

-- The partner settled, or never did and the first nurse carries on alone.
local function finish_partner(nurse, entry, live, settled)
    local first = live[entry.partner_of]
    if not first then
        return
    end
    if settled and begin_pair(first, nurse, entry.held) then
        log("A nurse is groping another")
    else
        first:SetActorEnableCollision(true)
        start_alone(first, "touch", entry.held)
    end
end

-- Each new nurse is decided once, when her outfit exists and she stands on the floor.
local function check_new_nurses(live, player)
    for address in pairs(seen) do
        if not live[address] then
            seen[address] = nil
        end
    end
    for address, nurse in pairs(live) do
        -- Class templates have no controller, so waiting for one also skips them.
        if not seen[address] and nurse.Controller:IsValid() then
            seen[address] = { since = elapsed_seconds, placed = false, kind = pick_kind() }
        end
        local entry = seen[address]
        if entry and not entry.decided then
            local age = elapsed_seconds - entry.since
            if age >= GIVE_UP_SECONDS then
                entry.decided = true
                if entry.partner_of then
                    finish_partner(nurse, entry, live, false)
                end
            elseif age >= SETTLE_SECONDS and nurse.CharacterMovement.MovementMode == MOVEMENT_WALKING then
                entry.decided = true
                local far_enough = not player or distance_squared(nurse:K2_GetActorLocation(), player:K2_GetActorLocation())
                    >= MIN_PLAYER_CM * MIN_PLAYER_CM
                if entry.partner_of then
                    finish_partner(nurse, entry, live, true)
                elseif entry.placed or (far_enough and math.random() < TOUCH_CHANCE) then
                    if entry.kind == "pair" then
                        start_waiting_for_partner(nurse, address)
                    else
                        start_alone(nurse, entry.kind)
                    end
                end
            end
        end
    end
end

-- A random walkable point some way from the player, or the player's own surroundings if the level has no navigation.
local function random_spot(player, place_number)
    local origin = player:K2_GetActorLocation()
    local navigation = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    if navigation and navigation:IsValid() then
        for _ = 1, PLACE_ATTEMPTS do
            local point = {}
            if navigation:K2_GetRandomReachablePointInRadius(player, origin, point, PLACE_DISTANCE_CM * 3.0, nil, nil) and point.X
                and distance_squared(point, origin) >= PLACE_DISTANCE_CM * PLACE_DISTANCE_CM / 4.0 then
                return { X = point.X, Y = point.Y, Z = point.Z + SPAWN_LIFT_CM }
            end
        end
    end
    local forward = player:GetActorForwardVector()
    local across = PLACE_SPREAD_CM * (place_number - 2)
    return {
        X = origin.X + forward.X * PLACE_DISTANCE_CM / 2.0 - forward.Y * across,
        Y = origin.Y + forward.Y * PLACE_DISTANCE_CM / 2.0 + forward.X * across,
        Z = origin.Z,
    }
end

local function update_level_plan(player)
    if not level_plan or elapsed_seconds < level_plan.next_time or not player then
        return
    end
    level_plan.placed = level_plan.placed + 1
    local place_number = level_plan.placed
    local kind = table.remove(level_plan.kinds, 1)
    if #level_plan.kinds == 0 then
        level_plan = nil
    end
    local spot = random_spot(player, place_number)
    local nurse = spawn_nurse(spot)
    if nurse then
        seen[nurse:GetAddress()] = { since = elapsed_seconds, placed = true, kind = kind }
        log(string.format("Placed a nurse (%s) at %.0f, %.0f, %.0f", kind, spot.X, spot.Y, spot.Z))
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
        active = {}
        seen = {}
        shafts = {}
        level_plan = nil
        local settings = PLACED_LEVELS[string.lower(world:GetFName():ToString())]
        if settings then
            level_plan = { next_time = elapsed_seconds + settings.delay_seconds, placed = 0, kinds = { table.unpack(settings.kinds) } }
        end
    end
    return true
end

LoopInGameThreadWithDelay(TICK_MS, function()
    if not check_level_change() then
        return
    end
    elapsed_seconds = elapsed_seconds + TICK_MS / 1000.0
    local player = current_player()
    update_level_plan(player)
    local live = live_nurses()
    local shaft_actors = live_shafts()
    clean_up_shafts(live, shaft_actors)
    watch_active(live, player, shaft_actors)
    check_new_nurses(live, player)
end)

math.randomseed(os.time())
log("Loaded.")
