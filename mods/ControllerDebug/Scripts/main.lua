-- Testing build only. Writes what the controller does and what the game's menus show to controller-debug.log in this
-- mod's folder, so a tester's report can be read back step by step.
--
-- Logged: controller buttons as the game sees them, the keys the game's menus are handed, and a snapshot of the UI
-- each time it changes (which menus are open, the pause menu's page and highlight, who holds the focus, and the Admin
-- Panel's page and highlight). Of the keyboard, only navigation keys are named, so no typed text is ever written.
--
-- The game only sees a button that no menu took first, so a press a menu handled shows as a menu key, not a pad press.

local ModKit = require("ModKit")
local mod = ModKit.new("ControllerDebug")
local has_pad, Pad = pcall(require, "Pad")

local LOG_FILE = mod.dir .. "controller-debug.log"
local MAX_LINES = 30000
local LOOP_MS = 20
local SNAPSHOT_EVERY_LOOPS = 50 -- Once a second, and straight after any key.
local MIN_SNAPSHOT_GAP_SECONDS = 0.2
local PAUSE_MENU_CLASS = "/Game/Blueprints/UI/Menu/BPW_PauseMenu.BPW_PauseMenu_C"
local KEY_COMPARE = "/Script/Engine.KismetInputLibrary:EqualEqual_KeyKey"
local VISIBILITY_COLLAPSED, VISIBILITY_HIDDEN = 1, 2

-- Menus that take input. Each is looked for by class, so the list is kept short.
local MENU_CLASSES = {
    "BPW_PauseMenu_C", "BPW_InteractionWheel_C", "BPW_SelectableSexMenu_C", "BPW_MapContainer_C", "BPW_Inventory_C",
    "BP_FullDialogueWidget_C", "BPW_ItemSelect_C", "BPW_ShopMenu_C", "BPW_MerchantShop_C", "BPW_LevelupScreen_C",
}

-- Keyboard keys safe to name. Every other keyboard key is written as "another key".
local NAMED_KEYS = {
    Escape = true, Enter = true, SpaceBar = true, Up = true, Down = true, Left = true, Right = true, Tab = true,
    P = true, BackSpace = true, None = true,
}

local file = io.open(LOG_FILE, "w")
local lines = 0
local started = os.clock()

local function write(text)
    if not file or lines >= MAX_LINES then
        return
    end
    lines = lines + 1
    file:write(string.format("%s +%8.3f  %s\n", os.date("%H:%M:%S"), os.clock() - started, text))
    if lines >= MAX_LINES then
        file:write("Log full, nothing more is written this session.\n")
    end
    file:flush()
end

local function safe_key_name(name)
    if name:find("^Gamepad_") or NAMED_KEYS[name] or name:find("Mouse") then
        return name
    end
    return "another key"
end

local function valid(object)
    return object ~= nil and type(object) == "userdata" and object:IsValid()
end

local function live(object)
    return valid(object) and object:GetFullName():find("/Engine/Transient", 1, true) ~= nil
end

-- Whether the widget is on screen: nothing above it hidden, and on the shown page of every switcher it sits in. The
-- game keeps many menus built and hidden inside its HUD, so being visible itself is not enough.
local function is_shown(widget)
    local user_widget = StaticFindObject("/Script/UMG.UserWidget")
    local current = widget
    for _ = 1, 64 do
        if not valid(current) then
            return false
        end
        local visibility = current:GetVisibility()
        if visibility == VISIBILITY_COLLAPSED or visibility == VISIBILITY_HIDDEN then
            return false
        end
        local parent = current:GetParent()
        if valid(parent) then
            if parent:GetClass():GetFName():ToString() == "WidgetSwitcher" then
                local active = parent:GetActiveWidget()
                if not valid(active) or active:GetAddress() ~= current:GetAddress() then
                    return false
                end
            end
            current = parent
        else
            local tree = current:GetOuter()
            local owner = valid(tree) and tree:GetOuter() or nil
            if not valid(owner) or not owner:IsA(user_widget) then
                return current:IsA(user_widget) and current:IsInViewport()
            end
            if owner:IsInViewport() then
                visibility = owner:GetVisibility()
                return visibility ~= VISIBILITY_COLLAPSED and visibility ~= VISIBILITY_HIDDEN
            end
            current = owner
        end
    end
    return false
end

local function controller()
    local found = FindFirstOf("PlayerController")
    if valid(found) then
        return found
    end
    return nil
end

-- Controller buttons, with names a tester would recognise.
local PAD_NAMES = {}
local pad_reader = nil
if has_pad then
    PAD_NAMES = {
        [Pad.A] = "A", [Pad.B] = "B", [Pad.X] = "X", [Pad.Y] = "Y", [Pad.LB] = "LB", [Pad.RB] = "RB",
        [Pad.LT] = "LT", [Pad.RT] = "RT", [Pad.L3] = "L3 (left stick click)", [Pad.R3] = "R3 (right stick click)",
        [Pad.VIEW] = "View/Back", [Pad.MENU] = "Menu/Start", [Pad.UP] = "D-pad up", [Pad.DOWN] = "D-pad down",
        [Pad.LEFT] = "D-pad left", [Pad.RIGHT] = "D-pad right", [Pad.STICK_UP] = "left stick up",
        [Pad.STICK_DOWN] = "left stick down", [Pad.STICK_LEFT] = "left stick left", [Pad.STICK_RIGHT] = "left stick right",
    }
    local names = {}
    for key in pairs(PAD_NAMES) do
        table.insert(names, key)
    end
    table.sort(names)
    pad_reader = Pad.Reader(names, { repeat_delay = 1e9 })
end
local KEYBOARD_KEYS = { "Escape", "Enter", "SpaceBar", "Up", "Down", "Left", "Right", "Tab", "P" }
local keyboard_reader = has_pad and Pad.Reader(KEYBOARD_KEYS, { repeat_delay = 1e9 }) or nil
local held_since = {}

-- The text a row or button shows, for the log.
local function label_of(widget)
    if not valid(widget) then
        return "none"
    end
    for _, name in ipairs({ "TextBlock_0", "TextBlock_91", "TextBlock_9", "TextBlock_15" }) do
        local ok, text = pcall(function()
            local block = widget[name]
            if block and block:IsValid() then
                return block:GetText():ToString()
            end
        end)
        if ok and text and text ~= "" then
            return text
        end
    end
    local ok, text = pcall(function()
        return widget.Text:ToString()
    end)
    if ok and text and text ~= "" then
        return text
    end
    ok, text = pcall(function()
        return widget:GetChildAt(0):GetText():ToString()
    end)
    if ok and text and text ~= "" then
        return text
    end
    return widget:GetClass():GetFName():ToString()
end

local function focus_of(widget, pc)
    local parts = {}
    pcall(function()
        if widget:HasUserFocus(pc) then
            table.insert(parts, "has focus")
        end
        if widget:HasFocusedDescendants() then
            table.insert(parts, "a child has focus")
        end
    end)
    if #parts == 0 then
        return "no focus"
    end
    return table.concat(parts, ", ")
end

local function pause_menu_text(menu, pc)
    local parts = {}
    local function add(label, fn)
        local ok, value = pcall(fn)
        table.insert(parts, label .. "=" .. (ok and tostring(value) or "?"))
    end
    add("start menu", function() return menu.IsStartMenu end)
    add("state", function() return menu.MenuState end)
    add("page", function() return menu.WidgetSwitcher_62:GetActiveWidgetIndex() end)
    add("highlighted", function() return label_of(menu.HighlightedButton) end)
    add("social", function() return menu.HighlightedSocial end)
    add("settings tab", function() return menu.BPW_SettingsMenu.WidgetSwitcher_0:GetActiveWidgetIndex() end)
    add("settings row", function() return label_of(menu.HighlightedSettingButton) end)
    add("focus", function() return focus_of(menu, pc) end)
    return table.concat(parts, ", ")
end

-- The Admin Panel's own window: the menu button it lives in is the only one added straight to the screen.
local function admin_panel_host()
    for _, button in ipairs(FindAllOf("BPW_GenericMenuButton_C") or {}) do
        if live(button) and button:IsInViewport() then
            return button
        end
    end
    return nil
end

local function snapshot()
    local pc = controller()
    if not pc then
        return "no player controller"
    end
    local parts = {}
    pcall(function()
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        table.insert(parts, "paused=" .. tostring(statics:IsGamePaused(pc)))
    end)
    table.insert(parts, "pad last used=" .. tostring(has_pad and Pad.using_gamepad(pc)))
    pcall(function()
        table.insert(parts, "level=" .. (pc:GetFullName():match("/Game/Maps/([^.]+)") or pc:GetFullName():match("/Game/([^.]+)") or "?"))
    end)
    local open = {}
    local pause_texts = {}
    for _, class in ipairs(MENU_CLASSES) do
        for _, widget in ipairs(FindAllOf(class) or {}) do
            if live(widget) then
                local shown = false
                pcall(function()
                    shown = is_shown(widget)
                end)
                if shown then
                    local name = class:gsub("_C$", "")
                    table.insert(open, name .. " (" .. focus_of(widget, pc) .. ")")
                    if class == "BPW_PauseMenu_C" then
                        table.insert(pause_texts, pause_menu_text(widget, pc))
                    end
                end
            end
        end
    end
    table.insert(parts, "open menus=[" .. table.concat(open, "; ") .. "]")
    for _, text in ipairs(pause_texts) do
        table.insert(parts, "pause menu {" .. text .. "}")
    end
    local admin = ModRef:GetSharedVariable("AdminPanel_DebugState")
    if admin then
        local host = admin_panel_host()
        table.insert(parts, "admin panel {" .. tostring(admin) .. (host and (", window " .. focus_of(host, pc)) or "") .. "}")
    end
    return table.concat(parts, "  ")
end

-- Keys the game's menus are handed. Every one goes through the engine's key comparison, and the first comparison
-- after the pause menu's OnKeyDown starts holds the key it was given.
local menu_events = {} -- Written out on the next loop, as the hooks run in the middle of the game's own code.
local in_pause_key = nil
local last_compared, last_compared_clock = nil, 0

local function hook_key_compare()
    local ok, problem = pcall(RegisterHook, KEY_COMPARE, function(_, first)
        local ok_name, name = pcall(function()
            return first:get().KeyName:ToString()
        end)
        if not ok_name then
            return
        end
        if in_pause_key then
            in_pause_key = nil
            table.insert(menu_events, "pause menu was handed " .. safe_key_name(name))
        elseif name ~= last_compared or os.clock() - last_compared_clock > 0.05 then
            table.insert(menu_events, "a game menu checked " .. safe_key_name(name))
        end
        last_compared, last_compared_clock = name, os.clock()
    end)
    write("Key comparison hook: " .. (ok and "on" or ("failed: " .. tostring(problem))))
end

local pause_hooked = false
local function hook_pause_menu()
    if pause_hooked then
        return
    end
    pause_hooked = true
    local ok, problem = pcall(RegisterHook, PAUSE_MENU_CLASS .. ":OnKeyDown", function()
        in_pause_key = true
    end)
    write("Pause menu key hook: " .. (ok and "on" or ("failed: " .. tostring(problem))))
end

local last_snapshot, last_snapshot_clock = nil, -1
local function log_snapshot(force)
    if not force and os.clock() - last_snapshot_clock < MIN_SNAPSHOT_GAP_SECONDS then
        return
    end
    local ok, text = pcall(snapshot)
    text = ok and text or ("snapshot failed: " .. tostring(text))
    last_snapshot_clock = os.clock()
    if text ~= last_snapshot then
        last_snapshot = text
        write("UI: " .. text)
    end
end

local function read_buttons(reader, names, kind)
    local pc = controller()
    if not reader or not pc then
        return false
    end
    reader:update(pc)
    local any = false
    for _, key in ipairs(reader.names) do
        local label = names[key] or key
        if reader:pressed(key) then
            held_since[key] = os.clock()
            write(kind .. " down: " .. label)
            any = true
        elseif reader:released(key) then
            local held = held_since[key] and (os.clock() - held_since[key]) or 0
            write(string.format("%s up: %s (held %.2fs)", kind, label, held))
            any = true
        end
    end
    return any
end

write("Controller Debug started. Pad module: " .. (has_pad and "yes" or "no, so controller buttons cannot be read"))
write("Admin Panel loaded: " .. tostring(ModKit.is_loaded("AdminPanel")) .. ", ModKit loaded: " .. tostring(ModKit.is_loaded("ModKit")))
hook_key_compare()

local loops = 0
mod.loop(LOOP_MS, function()
    loops = loops + 1
    if not pause_hooked and loops % 25 == 0 then
        for _, menu in ipairs(FindAllOf("BPW_PauseMenu_C") or {}) do
            if live(menu) then
                hook_pause_menu()
                break
            end
        end
    end
    local key_event = false
    if #menu_events > 0 then
        local events = menu_events
        menu_events = {}
        for _, text in ipairs(events) do
            write(text)
        end
        key_event = true
    end
    key_event = read_buttons(pad_reader, PAD_NAMES, "pad") or key_event
    key_event = read_buttons(keyboard_reader, {}, "key") or key_event
    if key_event then
        log_snapshot(false)
    elseif loops % SNAPSHOT_EVERY_LOOPS == 0 then
        log_snapshot(true)
    end
end)

mod.log("Writing controller debug lines to " .. LOG_FILE)
