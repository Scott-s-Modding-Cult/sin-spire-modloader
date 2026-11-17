-- Lustful Distractions: plant pairs and headcrab pairs busy with each other around the level, as a distraction for
-- the player. They ignore the player for now. This is Plant Distractor and Crab Pair merged into one mod, so a level
-- gets one set of pairs picked from every kind instead of two mods each placing their own.
--
-- The kinds are two penis plants rubbing their tips together, one penis plant docked inside another, two penis plants
-- mashing their tips together and failing to dock, a penis plant in a mouth plant, one headcrab riding another, and
-- rarely a mouth plant sucking off a headcrab.
-- Pairs appear at random spots when a level loads, and Free Mode always has at least one.
-- Every so often a pair gets excited and slams once, and less often it climaxes. The crab pair also has the lower crab
-- fighting to get away and being held back, and rarely breaking free, being chased down and caught, if it has room.
-- Press F9 to make every pair struggle at its next chance.
--
-- The assets still live under /Game/Mods/PlantDistractor/ and /Game/Mods/CrabPair/ inside the two cooked paks this mod
-- ships, which were not rebuilt for the merge. Only the paths below know that.
--
-- The game can delete any object and reuse its memory at any moment, so nothing here keeps a game object between
-- ticks: pairs are remembered by address and looked up fresh from the game's live list.

local UEHelpers = require("UEHelpers")
local ModSettings = require("ModSettings")
local AdminTabs = require("AdminTabs")

-- Two sliders, because the plants and the crabs were tuned apart from each other and sound nothing alike.
local plant_volume = ModSettings.AddSlider({
    mod = "LustfulDistractions",
    key = "PlantSexVolume",
    label = "Plant Sex Volume",
    tab = "audio",
    min = 0,
    max = 100,
    step = 5,
    default = 50,
    format = "%d%%",
})
local crab_volume = ModSettings.AddSlider({
    mod = "LustfulDistractions",
    key = "CrabSexVolume",
    label = "Crab Sex Volume",
    tab = "audio",
    min = 0,
    max = 100,
    step = 5,
    default = 50,
    format = "%d%%",
})
local NORMAL_VOLUME_SETTING = 50.0 -- The slider value that plays the sounds at their authored loudness.

local PLANT_DIR = "/Game/Mods/PlantDistractor/"
local CRAB_DIR = "/Game/Mods/CrabPair/"
local CRAB_PLANT_DIR = "/Game/Mods/CrabPair/Plant/"

local ACTOR_CLASS = "/Script/Engine.SkeletalMeshActor"
local PAIR_SCALE = 2.0
local SPAWN_DISTANCE_CM = 350.0
local MOBILITY_MOVABLE = 2
local ALWAYS_TICK_POSE = 1 -- Animation time keeps running, but bones only update while the pair is on screen.
local LOOP_SECONDS = 8.333

-- Where pairs appear, by map name in lower case. Menus, dialogue scenes and boss arenas are left out on purpose.
-- One mod now covers what two placed separately, so the counts are a little above either mod's own and below the sum.
local LEVELS = {
    freemode = { chance = 1.0, min = 2, max = 4, always = true, delay_seconds = 4.0 },
    lustdungeon = { chance = 0.8, min = 1, max = 3, delay_seconds = 10.0 },
    lustdungeon_classic = { chance = 0.8, min = 1, max = 3, delay_seconds = 10.0 },
    envydungeon = { chance = 0.8, min = 1, max = 3, delay_seconds = 10.0 },
    envydungeon_classic = { chance = 0.8, min = 1, max = 3, delay_seconds = 10.0 },
    gluttony = { chance = 0.8, min = 1, max = 3, delay_seconds = 10.0 },
    gluttony_classic = { chance = 0.8, min = 1, max = 3, delay_seconds = 10.0 },
    overworld = { chance = 0.5, min = 1, max = 2, delay_seconds = 10.0 },
}
local RETRY_SECONDS = 5.0 -- A dungeon may still be building, so a failed search tries again later.
local MAX_SEARCHES = 10
local SEARCHES_BEFORE_FALLBACK = 3 -- A level that must have a pair stops being picky after this many.
local SPOTS_PER_SEARCH = 12
local NEARBY_SEARCH_RADIUS_CM = 2500.0
local SEARCH_RADIUS_CM = 6000.0
local MIN_PLAYER_DISTANCE_CM = 600.0 -- A pair never appears right beside the player.
local MIN_PAIR_DISTANCE_CM = 1000.0
local OTHER_ACTOR_DISTANCE_CM = 400.0 -- Clear of other mods' pairs, which are the same kind of actor.
local MAX_FLOOR_STEP_CM = 18.0
local TRACE_CHANNEL_VISIBILITY = 0
local DRAW_NO_DEBUG = 0
local NO_COLOUR = { R = 0, G = 0, B = 0, A = 0 }

-- The room each sort of pair needs, from its size at PAIR_SCALE.
local PLANT_ROOM = { half_length_cm = 150.0, half_width_cm = 60.0, headroom_cm = 130.0, clear_height_cm = 70.0 }
local CRAB_ROOM = { half_length_cm = 110.0, half_width_cm = 65.0, headroom_cm = 140.0, clear_height_cm = 50.0 }

-- Sounds are from Shinlalala's Lewd Sound Pack, CC BY-SA 4.0: "Lewd sounds by Shinlalala". They are the plant pak's
-- cooked copies, which this mod ships, so both sorts of pair can be heard.
local SOUND_DIR = PLANT_DIR .. "Audio/"
local SOUND_COUNTS = { Plap = 16, Stroke = 10, Wet = 12, Cum = 3 }
local PITCH_LOW, PITCH_HIGH = 0.92, 1.08 -- So repeats of one sound do not sound identical.
local GULP_PITCH = 0.62 -- The pack has no swallow, so a wet sound played low stands in.
local AUDIBLE_DISTANCE_CM = 2500.0 -- Further away than this, a pair's sounds are not worth playing.

-- Each sound is { seconds into the clip, sound group, volume, fixed pitch if any }. The times are where each push
-- lands, from plant_sound_timing.py and build_crab_pair.py, and pushes that travel further are louder.

-- The penis plant and mouth plant pair.
local PLANT_LOOP_SOUNDS = {
    { 0.375, "Stroke", 0.60 }, { 0.792, "Stroke", 0.70 }, { 0.792, "Wet", 0.40 }, { 1.208, "Stroke", 0.50 },
    { 1.625, "Stroke", 0.70 }, { 1.625, "Wet", 0.40 }, { 2.042, "Stroke", 0.45 }, { 2.458, "Stroke", 0.65 },
    { 2.458, "Wet", 0.40 }, { 2.875, "Stroke", 0.55 }, { 3.292, "Stroke", 0.60 }, { 3.708, "Stroke", 0.55 },
    { 4.125, "Stroke", 0.40 }, { 4.583, "Stroke", 0.65 }, { 4.583, "Wet", 0.40 }, { 4.958, "Stroke", 0.45 },
    { 5.375, "Stroke", 0.50 }, { 5.792, "Stroke", 0.60 }, { 6.208, "Stroke", 0.55 }, { 6.625, "Stroke", 0.65 },
    { 6.625, "Wet", 0.40 }, { 7.042, "Stroke", 0.45 }, { 7.500, "Stroke", 0.75 }, { 7.500, "Wet", 0.45 },
    { 7.875, "Stroke", 0.40 }, { 8.292, "Stroke", 0.50 },
}
local PLANT_SLAM_SOUNDS = {
    { 0.875, "Plap", 1.00 }, { 0.875, "Wet", 0.75 }, { 1.292, "Stroke", 0.50 }, { 1.708, "Stroke", 0.40 },
}
local PLANT_CLIMAX_SOUNDS = {
    { 0.333, "Plap", 0.50 }, { 0.958, "Plap", 0.65 }, { 1.417, "Plap", 0.80 }, -- The three building strokes.
    { 2.417, "Plap", 1.00 }, { 2.417, "Wet", 0.70 }, -- The final push.
    { 2.583, "Cum", 1.00 }, { 3.083, "Cum", 0.90 }, { 3.667, "Cum", 0.80 }, { 4.333, "Cum", 0.65 }, { 5.083, "Cum", 0.50 },
    { 5.583, "Wet", 0.90, GULP_PITCH }, { 6.833, "Wet", 0.80, GULP_PITCH }, -- The two swallows.
    { 7.208, "Stroke", 0.45 }, { 7.625, "Stroke", 0.35 },
}
-- The tip pair: a soft rub on each press, and wet ones as the tips part for a kiss and land again.
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
-- The docking pair: each stroke lands at its deepest point.
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
-- The struggling pair: a hit as each try lands, and a wet push as the heads mash together.
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
-- The crab pair.
local CRAB_LOOP_SOUNDS = {
    { 0.083, "Plap", 0.70 }, { 0.833, "Plap", 0.85 }, { 0.833, "Wet", 0.40 }, { 1.667, "Plap", 0.70 },
    { 2.417, "Plap", 0.50 }, { 2.417, "Stroke", 0.35 }, { 3.125, "Plap", 0.50 }, { 3.875, "Plap", 0.70 },
    { 3.875, "Wet", 0.35 }, { 4.708, "Plap", 0.85 }, { 4.708, "Wet", 0.40 }, { 5.417, "Plap", 0.80 },
    { 6.125, "Plap", 0.60 }, { 6.917, "Plap", 0.50 }, { 6.917, "Stroke", 0.35 }, { 7.750, "Plap", 0.60 },
}
local CRAB_SLAM_SOUNDS = {
    { 0.083, "Stroke", 0.35 }, { 0.750, "Plap", 1.00 }, { 0.750, "Wet", 0.80 }, { 1.250, "Stroke", 0.40 },
}
local CRAB_CLIMAX_SOUNDS = {
    { 0.667, "Plap", 0.50 }, { 1.417, "Plap", 0.70 }, -- The building strokes.
    { 2.417, "Plap", 1.00 }, { 2.417, "Wet", 0.70 }, -- The final push.
    { 2.583, "Cum", 1.00 }, { 3.083, "Cum", 0.90 }, { 3.667, "Cum", 0.80 }, { 4.333, "Cum", 0.65 }, { 5.083, "Cum", 0.50 },
    { 6.500, "Stroke", 0.40 }, { 7.500, "Stroke", 0.35 },
}
local CRAB_STRUGGLE_SOUNDS = {
    { 1.250, "Stroke", 0.50 }, { 1.833, "Plap", 1.00 }, { 1.833, "Wet", 0.70 }, -- Pulls away, and is hauled back.
    { 3.000, "Stroke", 0.60 }, { 3.583, "Plap", 1.00 }, { 3.583, "Wet", 0.75 },
    { 4.917, "Stroke", 0.65 }, { 5.500, "Plap", 1.00 }, { 5.500, "Wet", 0.80 },
    { 6.750, "Plap", 0.50 },
}
local CRAB_CHASE_SOUNDS = {
    { 0.250, "Wet", 0.50 }, -- It breaks free.
    { 6.250, "Plap", 1.00 }, { 6.250, "Wet", 0.60 }, -- Much later the pounce lands, and they wrestle.
    { 6.750, "Stroke", 0.40 }, { 7.167, "Stroke", 0.35 },
    { 8.333, "Plap", 1.00 }, { 8.333, "Wet", 0.80 }, -- The first thrust, then the fast ones.
    { 8.583, "Plap", 0.70 }, { 8.792, "Plap", 0.85 }, { 9.042, "Plap", 0.70 }, { 9.250, "Plap", 0.85 }, { 9.500, "Plap", 0.70 },
    { 9.708, "Plap", 0.85 }, { 9.958, "Plap", 0.70 }, { 10.167, "Plap", 0.85 }, { 10.167, "Wet", 0.40 }, { 10.417, "Plap", 0.70 },
    { 10.625, "Plap", 0.85 }, { 10.875, "Plap", 0.70 }, { 11.083, "Plap", 0.85 }, { 11.083, "Wet", 0.40 }, { 11.333, "Plap", 0.70 },
    { 11.542, "Plap", 0.85 }, { 11.792, "Plap", 0.70 }, { 12.000, "Plap", 0.85 }, { 12.208, "Plap", 0.60 }, { 12.458, "Plap", 0.70 },
    { 13.250, "Plap", 0.70 }, { 13.958, "Plap", 0.60 },
}

-- Each clip picks up from the loop at one moment and hands back to it later on; from the builders' output.
-- A slam and a climax share their timings across the kinds that were cut the same way.
local function slam_clip(dir, name, sounds, start_seconds)
    return {
        dir = dir, name = name, sounds = sounds,
        start_seconds = start_seconds, resume_seconds = start_seconds + 2.0, length_seconds = 2.0,
        min_wait_seconds = 12.0, max_wait_seconds = 30.0,
    }
end
local function climax_clip(dir, name, sounds, start_seconds)
    return {
        dir = dir, name = name, sounds = sounds,
        start_seconds = start_seconds, resume_seconds = start_seconds + 8.0, length_seconds = 8.0,
        min_wait_seconds = 60.0, max_wait_seconds = 120.0,
    }
end

local CRAB_STRUGGLE = {
    dir = CRAB_DIR, name = "AS_CrabPair_Struggle", sounds = CRAB_STRUGGLE_SOUNDS,
    start_seconds = 1.0, resume_seconds = 8.0, length_seconds = 7.0,
    min_wait_seconds = 30.0, max_wait_seconds = 70.0,
}
local CRAB_CHASE = {
    dir = CRAB_DIR, name = "AS_CrabPair_Chase", sounds = CRAB_CHASE_SOUNDS,
    start_seconds = 0.5, resume_seconds = 6.333, length_seconds = 14.167,
    min_wait_seconds = 180.0, max_wait_seconds = 420.0,
    needs_lap_room = true,
}
-- The crabs run a circle 2.8 m across, at PAIR_SCALE, on the pair's left-hand bone side. Whether it fits is decided
-- once, when the pair is placed: a trace can hit anything, and a pair is placed well away from the player.
local LAP_RADIUS_CM = 140.0
local LAP_CLEARANCE_CM = 60.0 -- How far out from the circle a crab's body and claws reach.
local LAP_ROOM_DIRECTIONS = 8

-- The struggling plants only keep at it until they cum, so their climax comes sooner than the other kinds'.
local STRUGGLE_CLIMAX = climax_clip(PLANT_DIR, "AS_PlantStruggle_Climax", STRUGGLE_CLIMAX_SOUNDS, 0.1667)
STRUGGLE_CLIMAX.min_wait_seconds, STRUGGLE_CLIMAX.max_wait_seconds = 30.0, 60.0
local STRUGGLE_SLAM = slam_clip(PLANT_DIR, "AS_PlantStruggle_Slam", STRUGGLE_SLAM_SOUNDS, 3.5)
STRUGGLE_SLAM.min_wait_seconds, STRUGGLE_SLAM.max_wait_seconds = 20.0, 40.0

-- Every kind of pair. "align" says how the mesh is lined up on its spot: "pair" centres it between two root bones,
-- and "front" stands one root bone on the spot, facing the way the front bone lies. "weight" is how often it is
-- picked; the crabs together come up about as often as the four plant kinds together.
local KINDS = {
    {
        name = "mouth pair", family = "plant", weight = 1.0, volume = plant_volume, room = PLANT_ROOM, scale = PAIR_SCALE,
        mesh_dir = PLANT_DIR, mesh = "SK_PlantPair", loop = "AS_PlantPair_Loop", loop_dir = PLANT_DIR,
        loop_sounds = PLANT_LOOP_SOUNDS, sound_bone = "Mth_DEF-Head",
        align = { mode = "pair", root_bones = { "PenisPlant_Root", "MouthPlant_Root" } },
        clips = {
            { key = "climax", clip = climax_clip(PLANT_DIR, "AS_PlantPair_Climax", PLANT_CLIMAX_SOUNDS, 0.25) },
            { key = "slam", clip = slam_clip(PLANT_DIR, "AS_PlantPair_Slam", PLANT_SLAM_SOUNDS, 4.5) },
        },
    },
    {
        name = "tip pair", family = "plant", weight = 1.0, volume = plant_volume, room = PLANT_ROOM, scale = PAIR_SCALE,
        mesh_dir = PLANT_DIR, mesh = "SK_PlantTips", loop = "AS_PlantTips_Loop", loop_dir = PLANT_DIR,
        loop_sounds = TIP_LOOP_SOUNDS, sound_bone = "A_DEF-PenisMid_Tip",
        align = { mode = "pair", root_bones = { "PlantA_Root", "PlantB_Root" } },
        clips = {
            { key = "climax", clip = climax_clip(PLANT_DIR, "AS_PlantTips_Climax", TIP_CLIMAX_SOUNDS, 0.1667) },
            { key = "slam", clip = slam_clip(PLANT_DIR, "AS_PlantTips_Slam", TIP_SLAM_SOUNDS, 3.5) },
        },
    },
    {
        name = "docking pair", family = "plant", weight = 1.0, volume = plant_volume, room = PLANT_ROOM, scale = PAIR_SCALE,
        mesh_dir = PLANT_DIR, mesh = "SK_PlantDock", loop = "AS_PlantDock_Loop", loop_dir = PLANT_DIR,
        loop_sounds = DOCK_LOOP_SOUNDS, sound_bone = "B_DEF-PenisMid_Tip",
        align = { mode = "pair", root_bones = { "PlantA_Root", "PlantB_Root" } },
        clips = {
            { key = "climax", clip = climax_clip(PLANT_DIR, "AS_PlantDock_Climax", DOCK_CLIMAX_SOUNDS, 0.1667) },
            { key = "slam", clip = slam_clip(PLANT_DIR, "AS_PlantDock_Slam", DOCK_SLAM_SOUNDS, 3.5) },
        },
    },
    {
        name = "struggling pair", family = "plant", weight = 1.0, volume = plant_volume, room = PLANT_ROOM, scale = PAIR_SCALE,
        mesh_dir = PLANT_DIR, mesh = "SK_PlantStruggle", loop = "AS_PlantStruggle_Loop", loop_dir = PLANT_DIR,
        loop_sounds = STRUGGLE_LOOP_SOUNDS, sound_bone = "A_DEF-PenisMid_Tip",
        align = { mode = "pair", root_bones = { "PlantA_Root", "PlantB_Root" } },
        clips = {
            { key = "climax", clip = STRUGGLE_CLIMAX },
            { key = "slam", clip = STRUGGLE_SLAM },
        },
    },
    {
        name = "crab pair", family = "crab", weight = 3.5, volume = crab_volume, room = CRAB_ROOM, scale = PAIR_SCALE,
        mesh_dir = CRAB_DIR, mesh = "SK_CrabPair", loop = "AS_CrabPair_Loop", loop_dir = CRAB_DIR,
        loop_sounds = CRAB_LOOP_SOUNDS, sound_bone = "Bot_def_pelvis",
        align = { mode = "front", root_bone = "Pair_Root", front_bone = "Pair_Front", centre_ahead_cm = 0.0 },
        lap_bones = { root = "Pair_Root", left = "Bot_def_leg_L", right = "Bot_def_leg_R" },
        clips = {
            { key = "climax", clip = climax_clip(CRAB_DIR, "AS_CrabPair_Climax", CRAB_CLIMAX_SOUNDS, 0.25) },
            { key = "chase", clip = CRAB_CHASE },
            { key = "struggle", clip = CRAB_STRUGGLE },
            { key = "slam", clip = slam_clip(CRAB_DIR, "AS_CrabPair_Slam", CRAB_SLAM_SOUNDS, 4.5) },
        },
    },
    {
        name = "mouth plant and crab", family = "crab", weight = 0.5, volume = crab_volume, room = CRAB_ROOM, scale = PAIR_SCALE,
        mesh_dir = CRAB_PLANT_DIR, mesh = "SK_CrabPlant", loop = "AS_CrabPlant_Loop", loop_dir = CRAB_PLANT_DIR,
        loop_sounds = PLANT_LOOP_SOUNDS, sound_bone = "Mth_DEF-Head",
        -- The plant stands well ahead of the mesh's root, so the root goes behind the spot.
        align = { mode = "front", root_bone = "PlantPair", front_bone = "Pair_Front", centre_ahead_cm = 70.0 },
        clips = {
            { key = "climax", clip = climax_clip(CRAB_PLANT_DIR, "AS_CrabPlant_Climax", PLANT_CLIMAX_SOUNDS, 0.25) },
            { key = "slam", clip = slam_clip(CRAB_PLANT_DIR, "AS_CrabPlant_Slam", PLANT_SLAM_SOUNDS, 4.5) },
        },
    },
}

-- By name, for the admin tab's buttons.
local KIND_BY_NAME = {}
for _, kind in ipairs(KINDS) do
    KIND_BY_NAME[kind.name] = kind
end

-- The admin panel adds one to this for each plant pair it asks for. Mods cannot call each other, but they can share
-- this. The name is the one the panel already uses, so the panel needs no change for the merge.
local SPAWN_REQUESTS_VARIABLE = "PlantDistractor_SpawnRequests"
local REQUEST_SEARCHES_BEFORE_FALLBACK = 3
local REQUEST_RETRY_SECONDS = 1.0
local START_WINDOW_SECONDS = 0.1 -- How soon after its start moment a clip may still begin.
local TICK_MS = 33

local pairs_list = {} -- { address, kind, clip, clip_key, sound_position, clocks, forced, has_lap_room }
local level_plan = nil
local world_address = nil
local last_sound_number = {}
local requests = {} -- Each is a kind, or a family name, or false for any kind at all.
local shared_requests_seen = 0
local request_searches = 0
local next_request_clock = 0.0
local requested_spots = {}

local function log(message)
    print("[LustfulDistractions] " .. message .. "\n")
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

local function random_between(low, high)
    return low + math.random() * (high - low)
end

-- One kind at random. "want" is a kind to use as it is, a family name to pick within, or nil for any kind.
local function pick_kind(want)
    if type(want) == "table" then
        return want
    end
    local pool, total = {}, 0.0
    for _, kind in ipairs(KINDS) do
        if not want or kind.family == want then
            table.insert(pool, kind)
            total = total + kind.weight
        end
    end
    local roll = math.random() * total
    for _, kind in ipairs(pool) do
        roll = roll - kind.weight
        if roll <= 0.0 then
            return kind
        end
    end
    return pool[#pool]
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

-- Lines the pair up along the given heading and puts it on the target, measured from its own bones, so this does not
-- depend on which way the importer laid out the mesh's axes. A two-root pair is centred between its roots and the
-- first root rests on the floor; a front-aligned pair stands its root on the spot, set back by centre_ahead_cm.
local function arrange(actor, component, kind, target, heading)
    local hit = {}
    local align = kind.align
    if align.mode == "pair" then
        local first = bone_location(component, align.root_bones[1])
        local second = bone_location(component, align.root_bones[2])
        local current = math.deg(math.atan(second.Y - first.Y, second.X - first.X))
        actor:K2_SetActorRotation({ Pitch = 0, Yaw = actor:K2_GetActorRotation().Yaw + (heading - current), Roll = 0 }, true)
        first = bone_location(component, align.root_bones[1])
        second = bone_location(component, align.root_bones[2])
        local location = actor:K2_GetActorLocation()
        actor:K2_SetActorLocation({
            X = location.X + target.X - (first.X + second.X) / 2,
            Y = location.Y + target.Y - (first.Y + second.Y) / 2,
            Z = location.Z + target.Z - first.Z,
        }, false, hit, true)
        return
    end
    local root = bone_location(component, align.root_bone)
    local front = bone_location(component, align.front_bone)
    local current = math.deg(math.atan(front.Y - root.Y, front.X - root.X))
    actor:K2_SetActorRotation({ Pitch = 0, Yaw = actor:K2_GetActorRotation().Yaw + (heading - current), Roll = 0 }, true)
    root = bone_location(component, align.root_bone)
    local behind = align.centre_ahead_cm
    local location = actor:K2_GetActorLocation()
    actor:K2_SetActorLocation({
        X = location.X + target.X - root.X - math.cos(math.rad(heading)) * behind,
        Y = location.Y + target.Y - root.Y - math.sin(math.rad(heading)) * behind,
        Z = location.Z + target.Z - root.Z,
    }, false, hit, true)
end

local function plan_clip(pair, entry)
    pair.clocks[entry.key] = os.clock() + random_between(entry.clip.min_wait_seconds, entry.clip.max_wait_seconds)
    pair.forced[entry.key] = false
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

-- Checks that a pair of this kind lying along this heading has level floor under it, no wall through it, and room
-- above it.
local function room_for_pair(context, x, y, z, heading, kind)
    local room = kind.room
    local middle = floor_height(context, x, y, z)
    if not middle then
        return nil
    end
    local along_x, along_y = math.cos(math.rad(heading)), math.sin(math.rad(heading))
    local across_x, across_y = -along_y, along_x
    local checks = {
        { x + along_x * room.half_length_cm, y + along_y * room.half_length_cm },
        { x - along_x * room.half_length_cm, y - along_y * room.half_length_cm },
        { x + across_x * room.half_width_cm, y + across_y * room.half_width_cm },
        { x - across_x * room.half_width_cm, y - across_y * room.half_width_cm },
    }
    for _, point in ipairs(checks) do
        local height = floor_height(context, point[1], point[2], middle)
        if not height or math.abs(height - middle) > MAX_FLOOR_STEP_CM then
            return nil
        end
    end
    local centre = { X = x, Y = y, Z = middle + room.clear_height_cm }
    for _, point in ipairs(checks) do
        if not is_clear(context, centre, { X = point[1], Y = point[2], Z = middle + room.clear_height_cm }) then
            return nil
        end
    end
    if not is_clear(context, centre, { X = x, Y = y, Z = middle + room.headroom_cm }) then
        return nil
    end
    return middle
end

-- Whether the circle the crabs run is level and free of walls, and says what stopped it if not.
local function has_lap_room(live_pair, bones)
    local component = live_pair.component
    local root = bone_location(component, bones.root)
    -- The lap's side, measured from the mesh's own bones, so this does not depend on how the importer laid out its axes.
    local left = bone_location(component, bones.left)
    local right = bone_location(component, bones.right)
    local dx, dy = left.X - right.X, left.Y - right.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1.0 then
        return false, "the bones are not posed"
    end
    local x = root.X + dx / length * LAP_RADIUS_CM
    local y = root.Y + dy / length * LAP_RADIUS_CM
    local height = root.Z + 50.0
    local context = live_pair.actor
    if not is_clear(context, { X = root.X, Y = root.Y, Z = height }, { X = x, Y = y, Z = height }) then
        return false, "a wall between the pair and the circle's middle"
    end
    local reach = LAP_RADIUS_CM + LAP_CLEARANCE_CM
    for index = 1, LAP_ROOM_DIRECTIONS do
        local angle = 2.0 * math.pi * index / LAP_ROOM_DIRECTIONS
        local px, py = x + math.cos(angle) * reach, y + math.sin(angle) * reach
        if not is_clear(context, { X = x, Y = y, Z = height }, { X = px, Y = py, Z = height }) then
            return false, string.format("a wall in direction %d", index)
        end
        local floor = floor_height(context, px, py, root.Z)
        if not floor or math.abs(floor - root.Z) > MAX_FLOOR_STEP_CM then
            return false, string.format("uneven floor in direction %d", index)
        end
    end
    return true
end

local function record_lap_room(pair)
    if not pair.kind.lap_bones then
        return -- Only the crabs ever run.
    end
    local live_pair = live_pairs()[pair.address]
    if not live_pair then
        return
    end
    local ok, fits, reason = pcall(has_lap_room, live_pair, pair.kind.lap_bones)
    pair.has_lap_room = ok and fits
    if not ok then
        log("The chase room check failed: " .. tostring(fits))
    elseif fits then
        log("This pair has room for the chase")
    else
        log("This pair has no room for the chase: " .. tostring(reason))
    end
end

local function spawn_pair(kind, target, heading)
    local mesh = load_by_package(kind.mesh_dir .. kind.mesh, kind.mesh)
    local anim = load_by_package(kind.loop_dir .. kind.loop, kind.loop)
    if not mesh or not anim then
        log("Could not load the " .. kind.name .. ": mesh " .. tostring(mesh ~= nil) .. ", animation " .. tostring(anim ~= nil))
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
    actor:SetActorScale3D({ X = kind.scale, Y = kind.scale, Z = kind.scale })
    component:PlayAnimation(anim, true)
    arrange(actor, component, kind, target, heading)
    -- Pairs start at different points in the loop, so they never move in step.
    local start = random_between(0.0, LOOP_SECONDS)
    component:SetPosition(start, false)
    local pair = { address = actor:GetAddress(), kind = kind, clip = nil, clip_key = nil, sound_position = start,
        clocks = {}, forced = {} }
    for _, entry in ipairs(kind.clips) do
        plan_clip(pair, entry)
    end
    table.insert(pairs_list, pair)
    record_lap_room(pair)
    return pair
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
    for _, actor in ipairs(FindAllOf("SkeletalMeshActor") or {}) do
        if actor:IsValid() and distance_2d(point, actor:K2_GetActorLocation()) < OTHER_ACTOR_DISTANCE_CM then
            return false
        end
    end
    return true
end

local function search_for_spot(player, origin, plan, kind)
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
                local floor = room_for_pair(player, point.X, point.Y, point.Z, heading, kind)
                if floor then
                    return { X = point.X, Y = point.Y, Z = floor }, heading
                end
                counts.no_room = counts.no_room + 1
            else
                counts.too_close = counts.too_close + 1
            end
        end
    end
    log(string.format("No spot in search %d for a %s: %d walkable points, %d visible points, %d found nothing, %d too close, %d without room",
        plan.searches, kind.name, counts.walkable, counts.visible, counts.none, counts.too_close, counts.no_room))
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
    -- The kind is picked first, because each kind needs a different amount of room.
    local kind = pick_kind(nil)
    local ok, spot, heading = pcall(search_for_spot, player, origin, plan, kind)
    if not ok then
        log("The spot search failed: " .. tostring(spot))
        spot = nil
    end
    if not spot and plan.always and #plan.placed == 0 and plan.searches >= SEARCHES_BEFORE_FALLBACK then
        spot, heading = place_ahead_of_player(player)
        log("No free spot found, so placing ahead of the player")
    end
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

-- Places one pair that was asked for, by this mod's admin tab or by the admin panel's own plant button. The panel
-- pauses the game, so this waits for it to close, and a pair never spawns into a paused world.
local function update_spawn_requests()
    local total = ModRef:GetSharedVariable(SPAWN_REQUESTS_VARIABLE) or 0
    if total > shared_requests_seen then
        for _ = 1, total - shared_requests_seen do
            table.insert(requests, "plant") -- The panel's button asks for a plant pair.
        end
        shared_requests_seen = total
        log(string.format("%d requested pairs waiting", #requests))
    end
    if #requests == 0 or os.clock() < next_request_clock then
        return
    end
    local player = current_player()
    if not player or StaticFindObject("/Script/Engine.Default__GameplayStatics"):IsGamePaused(player) then
        return
    end
    local want = requests[1]
    local kind = pick_kind(want ~= false and want or nil)
    request_searches = request_searches + 1
    local plan = { placed = taken_spots(), searches = request_searches }
    local ok, spot, heading = pcall(search_for_spot, player, player:K2_GetActorLocation(), plan, kind)
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
    if spawn_pair(kind, spot, heading) then
        table.insert(requested_spots, { X = spot.X, Y = spot.Y })
        log(string.format("Placed requested %s at %s", kind.name, format_location(spot)))
    end
    -- A request that failed even so is dropped, as trying again every tick would only repeat the failure.
    table.remove(requests, 1)
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
        log("Level " .. name .. ": no pairs here")
        return
    end
    if math.random() >= settings.chance then
        log("Level " .. name .. ": no pairs this time")
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
    local volume = event[3] * pair.kind.volume.value / NORMAL_VOLUME_SETTING
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

local function try_start(pair, live_pair, entry, position)
    local clip = entry.clip
    if not (pair.forced[entry.key] or os.clock() >= pair.clocks[entry.key]) then
        return false
    end
    if position < clip.start_seconds or position >= clip.start_seconds + START_WINDOW_SECONDS then
        return false
    end
    if clip.needs_lap_room and not pair.has_lap_room then
        log("No room here for " .. clip.name)
        plan_clip(pair, entry)
        return false
    end
    local animation = load_by_package(clip.dir .. clip.name, clip.name)
    if not animation then
        log("Could not load " .. clip.name)
        for _, other in ipairs(pair.kind.clips) do
            plan_clip(pair, other)
        end
        return false
    end
    live_pair.component:PlayAnimation(animation, false)
    pair.clip = clip
    pair.clip_key = entry.key
    pair.forced[entry.key] = false
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
            local loop = load_by_package(pair.kind.loop_dir .. pair.kind.loop, pair.kind.loop)
            if loop then
                component:PlayAnimation(loop, true)
                component:SetPosition(pair.clip.resume_seconds, false)
                pair.sound_position = pair.clip.resume_seconds
            end
            -- The clip that just played waits its full time again, and so does the slam: one straight after anything
            -- else would break the mood.
            for _, entry in ipairs(pair.kind.clips) do
                if entry.key == pair.clip_key or entry.key == "slam" then
                    plan_clip(pair, entry)
                end
            end
            pair.clip = nil
            pair.clip_key = nil
        end
        return
    end
    -- In order, so the rarer and longer clips get their turn before the slam.
    for _, entry in ipairs(pair.kind.clips) do
        if try_start(pair, live_pair, entry, position) then
            return
        end
    end
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

-- Makes every pair that has this clip do it at its next chance. A pair without one is left alone.
local function force_all(key, what)
    return function()
        local asked = 0
        for _, pair in ipairs(pairs_list) do
            if pair.clocks[key] then
                pair.forced[key] = true
                asked = asked + 1
            end
        end
        log(string.format("%s requested for %d pairs", what, asked))
    end
end

RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(force_all("struggle", "Struggle"))
end)

-- Shows in the admin panel if it is installed.
AdminTabs.AddTab({ id = "LustfulDistractions", title = "Lustful Distractions" })
    :AddButton("Spawn Random Pair", function() table.insert(requests, false) end)
    :AddButton("Spawn Plant Pair", function() table.insert(requests, "plant") end)
    :AddButton("Spawn Crab Pair", function() table.insert(requests, KIND_BY_NAME["crab pair"]) end)
    :AddButton("Spawn Mouth Plant And Crab", function() table.insert(requests, KIND_BY_NAME["mouth plant and crab"]) end)
    :AddButton("Make Pairs Slam", force_all("slam", "Slam"))
    :AddButton("Make Pairs Struggle", force_all("struggle", "Struggle"))
    :AddButton("Make Pairs Climax", force_all("climax", "Climax"))
    :AddButton("Make Pairs Chase", force_all("chase", "Chase"))

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
    AdminTabs.Poll()
    ModSettings.Poll()
end)

math.randomseed(os.time())
log("Loaded. Pairs appear on their own. F9 makes them struggle.")
