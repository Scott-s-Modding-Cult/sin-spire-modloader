-- Lets any regular enemy appear at any spawn point, instead of each floor's own group.
--
-- Each dungeon has one BP_AIManager with a weighted table of enemies. When the dungeon finishes generating, it picks from
-- that table for every BP_AISpawner. So the table is replaced before then, and the game does the rest as usual. Levels with
-- no manager, such as boss arenas and the tutorial, are left alone, as are stalkers, which come from BP_StalkerTimer.
--
-- mod-randomizer.json is read once at launch and is not watched. Changes in the admin panel are written back to it.

local ModKit = require("ModKit")
local AdminTabs = require("AdminTabs")
local UEHelpers = require("UEHelpers")

local mod = ModKit.new("EnemyRandomizer")

local CONFIG_FILE = mod.dir .. "mod-randomizer.json"
local TICK_MS = 250
local ENEMY_FOLDER = "/Game/Blueprints/AI/Enemies/"
local AI_FOLDER = "/Game/Blueprints/AI/Behaviours/"
local OFF_ON = { "Off", "On" }
local WEIGHTS = { 0, 1, 2, 5, 10, 20, 50 }
local WEIGHT_LABELS = { "Off", "1", "2", "5", "10", "20", "50" }
local EMPTY_KEY = "emptySpawnPercent"
local EMPTY_MAX = 95 -- At 100 the table would need an endless weight, and a floor with no enemies is what switching them off is for.
local EMPTY_PERCENTS = { 0, 10, 25, 50, 75, 90 }
local EMPTY_LABELS = { "Off", "10%", "25%", "50%", "75%", "90%" }

-- The pairings are the game's own, from its managers' AITableControllers. The Gold Virgin has none on any floor.
local ENEMIES = {
    { key = "Automaid", label = "Automaid", controller = "Maid/BPAI_Maid", weight = 10 },
    { key = "Banshee", label = "Banshee", controller = "Banshee/BPAI_Banshee", weight = 10 },
    { key = "Butcherette", label = "Butcherette", controller = "Butcher/BPAI_Butcherette", weight = 10 },
    { key = "GoldVirgin", label = "Gold Virgin", weight = 1 }, -- At most 0.5 on the game's own floors, so it stays rare.
    { key = "LostSoul", label = "Lost Soul", controller = "LostSoul/BPAI_LostSoul", weight = 10 },
    { key = "Mannequin", label = "Mannequin", controller = "Mannequin/BPAI_Mannequin", weight = 10 },
    { key = "Smiler", label = "Smiler", controller = "Smiler/BPAI_Smiler", weight = 10 },
    { key = "SplitFace", label = "Split Face", controller = "Splitface/BPAI_Splitface", weight = 10 },
    { key = "StoneVirgin", label = "Stone Virgin", controller = "Stone/BPAI_Statue", weight = 10 },
    { key = "Twisted", label = "Twisted", controller = "Twisted/BPAI_Twisted", weight = 10 },
    { key = "TwistedNurse", label = "Twisted Nurse", controller = "Twisted/BPAI_Twisted", weight = 10 },
    { key = "Witness", label = "Witness", controller = "Witness/BPAI_Witness", weight = 10 },
    { key = "WitnessBag", label = "Witness (Bag)", controller = "Witness/BPAI_Witness", weight = 10 },
    { key = "WitnessLust", label = "Witness (Lust)", controller = "Witness/BPAI_Witness", weight = 10 },
    { key = "WitnessRed", label = "Witness (Red)", controller = "Witness/BPAI_Witness", weight = 10 },
    { key = "WitnessSloth", label = "Witness (Sloth)", controller = "Witness/BPAI_Witness", weight = 10 },
    { key = "Wraith", label = "Wraith", controller = "Wraith/BPAI_Wraith", weight = 10 },
}

local enabled = true
local empty_percent = 25
local patched = {} -- The managers already changed, by address, until they are gone.

local function save_config()
    local lines = {}
    for index, enemy in ipairs(ENEMIES) do
        lines[index] = string.format('        "%s": %s', enemy.key, tostring(enemy.weight))
    end
    local file = io.open(CONFIG_FILE, "w")
    if not file then
        mod.log("Could not write " .. CONFIG_FILE)
        return
    end
    file:write('{\n    "enabled": ' .. tostring(enabled) .. ',\n    "' .. EMPTY_KEY .. '": ' .. tostring(empty_percent)
        .. ',\n    "enemies": {\n'
        .. table.concat(lines, ",\n") .. "\n    }\n}\n")
    file:close()
end

local function load_config()
    local file = io.open(CONFIG_FILE, "r")
    if not file then
        save_config()
        mod.log("Wrote the default settings to " .. CONFIG_FILE)
        return
    end
    local text = file:read("*a")
    file:close()
    local switch = text:match('"enabled"%s*:%s*(%a+)')
    if switch then
        enabled = switch == "true"
    end
    local by_key = {}
    for _, enemy in ipairs(ENEMIES) do
        by_key[enemy.key] = enemy
    end
    -- Enemies missing from the file keep their defaults, so one typo cannot empty the table.
    for key, value in text:gmatch('"([%w_]+)"%s*:%s*(%-?%d+%.?%d*)') do
        if key == EMPTY_KEY then
            empty_percent = math.min(math.max(tonumber(value), 0), EMPTY_MAX)
        elseif by_key[key] then
            by_key[key].weight = math.max(tonumber(value), 0)
        else
            mod.log("Unknown enemy in the settings: " .. key)
        end
    end
end

-- A file can hold any weight, so the panel shows the closest one it offers. The file keeps the value until it is changed.
local function closest_index(options, value)
    local best = 0
    for index, option in ipairs(options) do
        if math.abs(option - value) < math.abs(options[best + 1] - value) then
            best = index - 1
        end
    end
    return best
end

-- Floors only load the enemies they use, so the rest are loaded here. The manager's tables then keep them loaded.
local function load_class(folder, path)
    local name = path:match("[^/]+$")
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local class = helpers:GetAsset({
        PackageName = UEHelpers.FindOrAddFName(folder .. path),
        AssetName = UEHelpers.FindOrAddFName(name .. "_C"),
    })
    if class:IsValid() then
        return class
    end
    mod.log("Could not load " .. name)
    return nil
end

local function patch_manager(manager)
    local chosen = {}
    for _, enemy in ipairs(ENEMIES) do
        if enemy.weight > 0 then
            local class = load_class(ENEMY_FOLDER, "BP_" .. enemy.key)
            local controller = enemy.controller and load_class(AI_FOLDER, enemy.controller)
            if class and (controller or not enemy.controller) then
                table.insert(chosen, { class = class, controller = controller, weight = enemy.weight })
            end
        end
    end
    -- An empty table would leave the manager nothing to give out, so that floor keeps its own group.
    if #chosen == 0 then
        mod.log("No enemies are switched on, leaving this floor's group as it is")
        return
    end
    manager.AITable:Empty()
    manager.AITableControllers:Empty()
    local total = 0
    for _, entry in ipairs(chosen) do
        manager.AITable:Add(entry.class, entry.weight)
        total = total + entry.weight
        if entry.controller then
            manager.AITableControllers:Add(entry.class, entry.controller)
        end
    end
    -- An empty spawn is a plain Actor, with nothing to see and no controller, as with the Gold Virgin. The manager only
    -- counts BP_BaseEnemyCharacter, so these do not get in the way of FullClear.
    if empty_percent > 0 then
        local nothing = StaticFindObject("/Script/Engine.Actor")
        if nothing:IsValid() then
            manager.AITable:Add(nothing, total * empty_percent / (100 - empty_percent))
        else
            mod.log("Could not find the Actor class, so no spawns will be empty on this floor")
        end
    end
    mod.log("Replaced this floor's group with " .. #chosen .. " enemies, " .. empty_percent .. "% of spawns empty")
end

local function update_managers()
    local seen = {}
    if enabled then
        for _, manager in ipairs(FindAllOf("BP_AIManager_C") or {}) do
            if manager:IsValid() and manager:GetFullName():find(":PersistentLevel.", 1, true) then
                local address = manager:GetAddress()
                seen[address] = true
                if not patched[address] then
                    -- The manager sets this as it hands out enemies, so anything but zero means it has already done so.
                    if manager.ValueSum == 0 then
                        patch_manager(manager)
                    else
                        mod.log("Too late for this floor, its enemies are already out")
                    end
                end
            end
        end
    end
    patched = seen
end

local function add_tab()
    local tab = AdminTabs.AddTab({ id = "EnemyRandomizer", title = "Enemy Randomizer" })
    tab:AddChoice("Randomizer (from the next floor)", OFF_ON, enabled and 1 or 0, function(index)
        enabled = index == 1
        save_config()
        mod.log(enabled and "On" or "Off")
    end)
    tab:AddChoice("Empty spawns", EMPTY_LABELS, closest_index(EMPTY_PERCENTS, empty_percent), function(index)
        empty_percent = EMPTY_PERCENTS[index + 1]
        save_config()
        mod.log("Empty spawns are now " .. empty_percent .. "%")
    end)
    for _, enemy in ipairs(ENEMIES) do
        tab:AddChoice(enemy.label, WEIGHT_LABELS, closest_index(WEIGHTS, enemy.weight), function(index)
            enemy.weight = WEIGHTS[index + 1]
            save_config()
            mod.log(enemy.label .. " is now " .. enemy.weight)
        end)
    end
end

load_config()
add_tab()

mod.loop(TICK_MS, function()
    update_managers()
    AdminTabs.Poll()
end)

mod.log("Loaded, " .. (enabled and "on" or "off"))
