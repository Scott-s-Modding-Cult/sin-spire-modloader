-- Reads the game controller from a Lua mod. UE4SS key binds only see the keyboard, so this asks the engine instead,
-- through the player controller, which knows every button the game itself can see.
--
--   local Pad = require("Pad")
--   Pad.down(Pad.A)                                -- Whether the button is held right now.
--   local reader = Pad.Reader({ Pad.UP, Pad.A })   -- Remembers presses between calls to update.
--   reader:update()                                -- From a game-thread loop, every 20 to 30 ms for menus.
--   reader:pressed(Pad.A)                          -- Went down since the last update.
--   reader:repeated(Pad.UP)                        -- Pressed, or held long enough to repeat as menus do.
--   Pad.using_gamepad()                            -- Whether the game last saw a controller rather than mouse and keys.
--   Pad.action_keys("Interact", { Pad.X })         -- The controller buttons the game binds to one of its actions.
--
-- The engine only sees a button that no menu took first. The game's own menus handle the controller themselves, so
-- while one of them has focus their buttons read as up here. A tap shorter than the time between updates can be missed.

local Pad = {}

Pad.A = "Gamepad_FaceButton_Bottom"
Pad.B = "Gamepad_FaceButton_Right"
Pad.X = "Gamepad_FaceButton_Left"
Pad.Y = "Gamepad_FaceButton_Top"
Pad.LB = "Gamepad_LeftShoulder"
Pad.RB = "Gamepad_RightShoulder"
Pad.LT = "Gamepad_LeftTrigger"
Pad.RT = "Gamepad_RightTrigger"
Pad.L3 = "Gamepad_LeftThumbstick"
Pad.R3 = "Gamepad_RightThumbstick"
Pad.VIEW = "Gamepad_Special_Left" -- Back or Select on older controllers. The game opens its map with it.
Pad.MENU = "Gamepad_Special_Right" -- Start. The game pauses with it.
Pad.UP = "Gamepad_DPad_Up"
Pad.DOWN = "Gamepad_DPad_Down"
Pad.LEFT = "Gamepad_DPad_Left"
Pad.RIGHT = "Gamepad_DPad_Right"
-- The engine also reports the left stick pushed past halfway as these buttons.
Pad.STICK_UP = "Gamepad_LeftStick_Up"
Pad.STICK_DOWN = "Gamepad_LeftStick_Down"
Pad.STICK_LEFT = "Gamepad_LeftStick_Left"
Pad.STICK_RIGHT = "Gamepad_LeftStick_Right"

local REPEAT_DELAY_SECONDS = 0.4
local REPEAT_EVERY_SECONDS = 0.12

local keys = {} -- Key structs by name, made once.

local function key(name)
    local made = keys[name]
    if not made then
        made = { KeyName = FName(name) }
        keys[name] = made
    end
    return made
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

function Pad.controller()
    local controller = FindFirstOf("PlayerController")
    if valid(controller) then
        return controller
    end
    return nil
end

function Pad.down(name, controller)
    controller = controller or Pad.controller()
    if not controller then
        return false
    end
    local ok, down = pcall(function()
        return controller:IsInputKeyDown(key(name))
    end)
    return ok and down == true
end

-- An analog axis such as "Gamepad_LeftX", from -1 to 1, or a trigger such as "Gamepad_LeftTriggerAxis", from 0 to 1.
function Pad.axis(name, controller)
    controller = controller or Pad.controller()
    if not controller then
        return 0.0
    end
    local ok, value = pcall(function()
        return controller:GetInputAnalogKeyState(key(name))
    end)
    return ok and tonumber(value) or 0.0
end

-- The game keeps this flag itself, from the last key it saw, to swap its button prompts.
function Pad.using_gamepad(controller)
    controller = controller or Pad.controller()
    if not controller then
        return false
    end
    local ok, using = pcall(function()
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        return statics:GetGameInstance(controller).UsingGamepad
    end)
    return ok and using == true
end

-- From the game's input settings. A binding changed in the game's Controls menu may not show here, so pass the
-- buttons the game ships with as the fallback.
function Pad.action_keys(action, fallback)
    local found = {}
    pcall(function()
        local settings = StaticFindObject("/Script/Engine.Default__InputSettings")
        settings.ActionMappings:ForEach(function(_, element)
            local mapping = element:get()
            local name = mapping.Key.KeyName:ToString()
            if mapping.ActionName:ToString() == action and name:find("^Gamepad_") then
                table.insert(found, name)
            end
        end)
    end)
    if #found == 0 then
        return fallback or {}
    end
    return found
end

-- Tracks the given buttons between updates, so a mod can act once per press instead of every tick it is held.
function Pad.Reader(names, options)
    options = options or {}
    local reader = {
        names = names,
        delay = options.repeat_delay or REPEAT_DELAY_SECONDS,
        every = options.repeat_every or REPEAT_EVERY_SECONDS,
        state = {},
    }
    for _, name in ipairs(names) do
        reader.state[name] = { down = false, pressed = false, released = false, repeated = false, next_repeat = 0.0 }
    end

    -- Reads every button. Returns whether any of them was pressed or repeated this time.
    function reader:update(controller)
        controller = controller or Pad.controller()
        local now = os.clock()
        local any = false
        for _, name in ipairs(self.names) do
            local state = self.state[name]
            local down = controller ~= nil and Pad.down(name, controller)
            state.pressed = down and not state.down
            state.released = state.down and not down
            state.repeated = false
            if state.pressed then
                state.repeated = true
                state.next_repeat = now + self.delay
            elseif down and now >= state.next_repeat then
                state.repeated = true
                state.next_repeat = now + self.every
            end
            state.down = down
            any = any or state.repeated
        end
        return any
    end

    -- Takes the buttons as they are now without counting anything as pressed, for when a reader starts listening
    -- after a pause and a button may already be held.
    function reader:reset(controller)
        controller = controller or Pad.controller()
        for _, name in ipairs(self.names) do
            local state = self.state[name]
            state.down = controller ~= nil and Pad.down(name, controller)
            state.pressed, state.released, state.repeated = false, false, false
            state.next_repeat = os.clock() + self.delay
        end
    end

    function reader:pressed(name)
        local state = self.state[name]
        return state ~= nil and state.pressed
    end

    function reader:released(name)
        local state = self.state[name]
        return state ~= nil and state.released
    end

    function reader:held(name)
        local state = self.state[name]
        return state ~= nil and state.down
    end

    function reader:repeated(name)
        local state = self.state[name]
        return state ~= nil and state.repeated
    end

    return reader
end

return Pad
