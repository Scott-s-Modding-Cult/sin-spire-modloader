-- Things most mods need, so each one does not have to work them out again.
--
--   local ModKit = require("ModKit")
--   local mod = ModKit.new("MyMod")           -- The mod's folder name.
--   mod.log("Hello")                          -- Goes to UE4SS.log as [MyMod] Hello.
--   mod.on_key(Key.F2, function() end)        -- A Lua error is logged and the key keeps working.
--   mod.loop(100, function() end)             -- Runs on the game thread every 100 ms. Keep to one per mod.
--   mod.send("MyMod_Value", 5)                -- Mods have separate Lua states, so this is how they talk.
--   mod.get("MyMod_Value", 0)                 -- Reads it from any mod, with a fallback.
--   mod.slider({ key = "Volume", label = "My Volume", tab = "audio", min = 0, max = 100, step = 5, default = 50 })
--   ModKit.is_loaded("OtherMod")              -- Whether the mod loader started that mod this launch.
--
-- Add "requires": ["ModKit"] to the mod's mod.json so it loads after this library is in place.

local ModKit = {}

local LOADED_FILE = "..\\..\\..\\Mods\\.modloader\\loaded.txt" -- The game runs from SinSpire\Binaries\Win64.
local MAX_LOOP_ERRORS = 5 -- A loop that keeps failing would fill the log, so it stops after this many.

local loaded = nil

function ModKit.is_loaded(name)
    if loaded == nil then
        loaded = {}
        local file = io.open(LOADED_FILE, "r")
        if file then
            for line in file:lines() do
                local mod_name, version = line:match("^([^=]+)=(.*)$")
                if mod_name then loaded[mod_name] = version end
            end
            file:close()
        end
    end
    return loaded[name] ~= nil
end

function ModKit.new(name)
    local mod = { name = name, dir = "ue4ss\\Mods\\" .. name .. "\\" }

    function mod.log(message)
        print("[" .. name .. "] " .. tostring(message) .. "\n")
    end

    -- Calls fn and logs any error instead of letting it end whatever called it. Returns whether it worked.
    function mod.try(fn, ...)
        local ok, problem = pcall(fn, ...)
        if not ok then mod.log("Error: " .. tostring(problem)) end
        return ok
    end

    function mod.on_key(key, fn)
        RegisterKeyBind(key, function()
            ExecuteInGameThread(function() mod.try(fn) end)
        end)
    end

    function mod.loop(milliseconds, fn)
        local errors = 0
        -- On the game thread throughout: LoopAsync runs Lua on another thread at the same time, which corrupts the Lua state.
        LoopInGameThreadWithDelay(milliseconds, function()
            if errors >= MAX_LOOP_ERRORS then return true end
            if not mod.try(fn) then
                errors = errors + 1
                if errors >= MAX_LOOP_ERRORS then mod.log("Loop stopped after repeated errors.") end
            end
            return false
        end)
    end

    function mod.send(variable, value)
        ModRef:SetSharedVariable(variable, value)
    end

    function mod.get(variable, fallback)
        local value = ModRef:GetSharedVariable(variable)
        if value == nil then return fallback end
        return value
    end

    -- Takes ModSettings.AddSlider's options, with the mod name filled in. Call ModSettings.Poll() or
    -- ModSettings.StartPolling() as that module describes.
    function mod.slider(options)
        options.mod = name
        return require("ModSettings").AddSlider(options)
    end

    return mod
end

return ModKit
