-- Lets any mod add its own paired enemies (two enemies playing a scene together, or anything else it spawns at a
-- spot) to the Enemy Randomizer's spawn table. It ships with the Enemy Randomizer, so a mod should load it with pcall
-- and simply do nothing when the randomizer is not installed:
--
--   local ok, RandomizerPairs = pcall(require, "RandomizerPairs")
--   if ok then
--       RandomizerPairs.Register({ id = "MyMod.my_pair", label = "My Pair", weight = 1 })
--       RandomizerPairs.OnSpawn(function(id, spot) ... end)   -- spot = { X, Y, Z, Yaw }: the spawner's floor spot
--   end
--   -- and in the mod's game-thread tick:
--   if ok then RandomizerPairs.Poll() end
--
-- id must be unique; "<ModName>.<kind>" is the convention. weight is the default share in the spawn table, on the
-- same scale as the randomizer's enemies (they default to 10 each, so 1 is rare); the randomizer's admin tab and
-- mod-randomizer.json ("pairs") can change it, and 0 switches it off. The randomizer only hands out pairs on floors it
-- randomizes, and the game's own spawn chances still apply. A pair spot comes from one spawner, so the owning mod
-- spawns both partners itself; the game counts any enemies it spawns there towards FullClear if they appear within
-- the manager's first 5 seconds.
--
-- Mods run in separate Lua states, so the registry and the spawn requests travel as shared text variables, like
-- AdminTabs. Everything runs on the game thread.

local RandomizerPairs = {}

local LIST_VARIABLE = "RandomizerPairs_List"       -- one line per pair: id \t label \t default weight
local REQUEST_VARIABLE = "RandomizerPairs_Request_" -- .. id: "x,y,z,yaw;x,y,z,yaw;..." waiting for the owner
local SEPARATOR, FIELD, SPOT = "\n", "\t", ";"

local mine = {} -- ids registered by this mod (this Lua state), in order
local handler = nil -- this mod's spawn function

local function clean(text)
    return (tostring(text):gsub("[\t\n;]", " "))
end

-- Every registered pair, from any mod: { { id, label, weight }, ... } in registration order.
function RandomizerPairs.List()
    local out = {}
    local list = ModRef:GetSharedVariable(LIST_VARIABLE) or ""
    for line in list:gmatch("[^\n]+") do
        local id, label, weight = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if id and id ~= "" then
            table.insert(out, { id = id, label = label, weight = tonumber(weight) or 0 })
        end
    end
    return out
end

function RandomizerPairs.Register(pair)
    if type(pair) ~= "table" or type(pair.id) ~= "string" or pair.id == "" then
        return false
    end
    local id = clean(pair.id)
    local lines = {}
    for _, p in ipairs(RandomizerPairs.List()) do
        if p.id ~= id then
            table.insert(lines, p.id .. FIELD .. p.label .. FIELD .. tostring(p.weight))
        end
    end
    table.insert(lines, id .. FIELD .. clean(pair.label or id) .. FIELD .. tostring(math.max(tonumber(pair.weight) or 1, 0)))
    ModRef:SetSharedVariable(LIST_VARIABLE, table.concat(lines, SEPARATOR))
    for _, m in ipairs(mine) do
        if m == id then return true end
    end
    table.insert(mine, id)
    return true
end

-- fn(id, spot) is called from Poll() for each spot the randomizer gave one of this mod's pairs.
function RandomizerPairs.OnSpawn(fn)
    handler = fn
end

-- The owner's side: takes the waiting spots for this mod's own pairs and calls its handler for each. Call it from the
-- mod's game-thread tick.
function RandomizerPairs.Poll()
    if not handler then
        return
    end
    for _, id in ipairs(mine) do
        local variable = REQUEST_VARIABLE .. id
        local waiting = ModRef:GetSharedVariable(variable)
        if waiting and waiting ~= "" then
            ModRef:SetSharedVariable(variable, "")
            for item in waiting:gmatch("[^;]+") do
                local x, y, z, yaw = item:match("^([^,]+),([^,]+),([^,]+),([^,]+)$")
                if x then
                    local ok, problem = pcall(handler, id, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z), Yaw = tonumber(yaw) })
                    if not ok then
                        print("[RandomizerPairs] " .. id .. " failed: " .. tostring(problem) .. "\n")
                    end
                end
            end
        end
    end
end

-- The randomizer's side: queues a spot for a pair's owner.
function RandomizerPairs.Request(id, spot)
    local variable = REQUEST_VARIABLE .. id
    local waiting = ModRef:GetSharedVariable(variable) or ""
    local item = string.format("%.1f,%.1f,%.1f,%.1f", spot.X, spot.Y, spot.Z, spot.Yaw or 0)
    ModRef:SetSharedVariable(variable, waiting == "" and item or (waiting .. SPOT .. item))
end

return RandomizerPairs
