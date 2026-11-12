-- Lets any UE4SS mod add its own rows to the game's settings menu, and remembers their values between sessions.
--
--   local ModSettings = require("ModSettings")
--   local volume = ModSettings.AddSlider({
--       mod = "MyMod",           -- The mod's folder under ue4ss\Mods, where settings.txt is kept.
--       key = "MyVolume",        -- Its name in settings.txt.
--       label = "My Volume",     -- What the row says.
--       tab = "audio",           -- "audio" or "video".
--       min = 0, max = 100, step = 5, default = 100,
--       format = "%d%%",         -- How the value is shown beside the slider.
--       on_change = function(value) end, -- Optional.
--   })
--   -- Read volume.value whenever it is needed. It holds the saved value from the moment the mod loads.
--
-- The rows need updating regularly. A mod with its own game-thread tick calls ModSettings.Poll() from it, and any
-- other mod calls ModSettings.StartPolling() once. Two async loops in one mod can step on each other, so a mod with
-- a loop should not start a second one.
--
-- The rows are plain engine widgets, not the game's own setting rows. Those are tied to console variables, and a row
-- pointed at a real one could overwrite the game's own setting when the menu applies its changes.
--
-- The game can delete and reuse any object, so nothing here keeps a widget between ticks. Rows are remembered by
-- address and found again through the menu each time.
--
-- With a controller, the game's menu moves its highlight onto these rows like its own, but only its own rows answer
-- the calls it then makes. So a highlighted row turns red here, and the menu's keys are read as it checks them: left
-- and right on the D-pad step the row's slider. The menu keeps the focus throughout, as a focused slider would take
-- the D-pad for the engine's own navigation and the menu's highlight could never leave it.

local ModSettings = {}

local POLL_MS = 100
local SAVE_DELAY_SECONDS = 1.0 -- Dragging a slider changes it many times, so saving waits for it to settle.
local SETTINGS_FILE = "settings.txt"
local SIZE_RULE_FILL = 1
local VALIGN_CENTER = 2
local LABEL_FILL, SLIDER_FILL = 1.0, 1.0
local TABS = { audio = "audio", video = "video" }
local PAUSE_MENU_CLASS = "/Game/Blueprints/UI/Menu/BPW_PauseMenu.BPW_PauseMenu_C"
-- Every key the pause menu gets goes through this comparison, with the key pressed first. UE4SS runs a hook on a
-- blueprint function only after it has finished, so the key is the one the last comparison saw when OnKeyDown's runs.
local KEY_COMPARE = "/Script/Engine.KismetInputLibrary:EqualEqual_KeyKey"
local STEP_KEYS = { Gamepad_DPad_Left = -1, Gamepad_DPad_Right = 1 }
local VISIBILITY_COLLAPSED, VISIBILITY_HIDDEN = 1, 2
-- The game's own rows turn red while the controller is on them.
local HIGHLIGHT_COLOR = { SpecifiedColor = { R = 1.0, G = 0.0, B = 0.0, A = 1.0 }, ColorUseRule = 0 }
local PLAIN_COLOR = { SpecifiedColor = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }, ColorUseRule = 0 }

local sliders = {}
local polling = false
local next_poll_clock = 0.0
local pad_hooks_registered = false
local pad_errors = 0
local menu_keys = {} -- One entry per OnKeyDown of the pause menu since the last game thread step.
local last_compared_key = nil

local function log(message)
    print("[ModSettings] " .. message .. "\n")
end

local function settings_path(mod)
    return "ue4ss\\Mods\\" .. mod .. "\\" .. SETTINGS_FILE
end

local function read_settings(mod)
    local values = {}
    local file = io.open(settings_path(mod), "r")
    if file then
        for line in file:lines() do
            local key, value = line:match("^([^=]+)=(.*)$")
            if key then
                values[key] = tonumber(value)
            end
        end
        file:close()
    end
    return values
end

-- Rewrites the mod's whole file, so settings from its other rows are kept.
local function write_setting(mod, key, value)
    local values = read_settings(mod)
    values[key] = value
    local file = io.open(settings_path(mod), "w")
    if not file then
        log("Could not save " .. key .. " for " .. mod)
        return
    end
    for name, number in pairs(values) do
        file:write(string.format("%s=%s\n", name, tostring(number)))
    end
    file:close()
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function snap(setting, value)
    local steps = math.floor((value - setting.min) / setting.step + 0.5)
    return clamp(setting.min + steps * setting.step, setting.min, setting.max)
end

local function value_text(setting)
    return string.format(setting.format, math.floor(setting.value + 0.5))
end

-- Class templates count as instances too and crash the game if called, so only trust menus in the running world.
local function find_menu()
    for _, menu in ipairs(FindAllOf("BPW_SettingsMenu_C") or {}) do
        if type(menu) == "userdata" and menu:IsValid() and menu:GetFullName():find("/Engine/Transient", 1, true) then
            return menu
        end
    end
    return nil
end

-- A row of the game's own on the wanted tab, used to find the tab's list and to copy how its rows look.
local function find_template(menu, tab)
    if tab == "video" then
        local template = menu.BPW_AntiAliasingSetting
        if template and template:IsValid() then
            return template
        end
        return nil
    end
    local menu_path = menu:GetFullName():match("%S+$")
    for _, row in ipairs(FindAllOf("BPW_VolumeSlider_C") or {}) do
        if row:IsValid() and row:GetFullName():find(menu_path, 1, true) then
            return row
        end
    end
    return nil
end

local function copy_slot_layout(from, to)
    pcall(function()
        to:SetPadding(from.Padding)
    end)
    pcall(function()
        to:SetHorizontalAlignment(from.HorizontalAlignment)
        to:SetVerticalAlignment(from.VerticalAlignment)
    end)
    pcall(function()
        to:SetSize(from.Size)
    end)
end

local function layout_cell(slot, fill)
    pcall(function()
        slot:SetVerticalAlignment(VALIGN_CENTER)
    end)
    if fill then
        pcall(function()
            slot:SetSize({ SizeRule = SIZE_RULE_FILL, Value = fill })
        end)
    end
end

-- Matches the game's rows where that can be done safely. If any of it fails, the row only looks plainer.
local function copy_look(template, label, value, slider)
    local sample_text = template.TextBlock_9
    if sample_text and sample_text:IsValid() then
        pcall(function()
            label:SetFont(sample_text.Font)
            value:SetFont(sample_text.Font)
        end)
    end
    local holder = template.DefaultSliderSetting_189
    local sample_slider = holder and holder:IsValid() and holder.Slider or nil
    if sample_slider and sample_slider:IsValid() then
        pcall(function()
            slider:SetSliderBarColor(sample_slider.SliderBarColor)
            slider:SetSliderHandleColor(sample_slider.SliderHandleColor)
        end)
    end
end

local function add_row(menu, setting)
    local template = find_template(menu, setting.tab)
    if not template then
        log("Could not find the " .. setting.tab .. " tab for " .. setting.label)
        return false
    end
    local panel = template:GetParent()
    local tree = menu.WidgetTree
    if not panel:IsValid() or not tree:IsValid() then
        log("Menu is not ready for " .. setting.label)
        return false
    end
    local function new_widget(class_path)
        return StaticConstructObject(StaticFindObject(class_path), tree)
    end
    local row = new_widget("/Script/UMG.HorizontalBox")
    local label = new_widget("/Script/UMG.TextBlock")
    local slider = new_widget("/Script/UMG.Slider")
    local value = new_widget("/Script/UMG.TextBlock")
    label:SetText(FText(setting.label))
    value:SetText(FText(value_text(setting)))
    layout_cell(row:AddChild(label), LABEL_FILL)
    layout_cell(row:AddChild(slider), SLIDER_FILL)
    layout_cell(row:AddChild(value), nil)
    copy_look(template, label, value, slider)
    copy_slot_layout(template.Slot, panel:AddChild(row))
    slider:SetMinValue(setting.min)
    slider:SetMaxValue(setting.max)
    slider:SetStepSize(setting.step)
    pcall(function()
        slider.MouseUsesStep = true
    end)
    slider:SetValue(setting.value)
    setting.menu_address = menu:GetAddress()
    setting.row_address = row:GetAddress()
    setting.pad_highlight = false
    log("Added " .. setting.label .. " at " .. value_text(setting))
    return true
end

-- The row's slider, value text, the row itself and its label, found again through the menu, or nil if any are gone.
local function find_row_parts(menu, setting)
    local template = find_template(menu, setting.tab)
    if not template then
        return nil
    end
    local panel = template:GetParent()
    if not panel:IsValid() then
        return nil
    end
    for index = panel:GetChildrenCount() - 1, 0, -1 do
        local child = panel:GetChildAt(index)
        if child:IsValid() and child:GetAddress() == setting.row_address then
            local label, slider, value = child:GetChildAt(0), child:GetChildAt(1), child:GetChildAt(2)
            if slider:IsValid() and value:IsValid() and label:IsValid() then
                return slider, value, child, label
            end
            return nil
        end
    end
    return nil
end

local function update_setting(menu, setting)
    local address = menu:GetAddress()
    if setting.menu_address ~= address then
        -- Only try each menu once, so a failure cannot repeat every poll.
        if setting.failed_address ~= address and not add_row(menu, setting) then
            setting.failed_address = address
        end
        return
    end
    local slider, text = find_row_parts(menu, setting)
    if not slider then
        setting.menu_address = nil
        return
    end
    local value = snap(setting, slider:GetValue())
    if value ~= setting.value then
        setting.value = value
        setting.save_clock = os.clock() + SAVE_DELAY_SECONDS
        text:SetText(FText(value_text(setting)))
        if setting.on_change then
            setting.on_change(value)
        end
    end
end

local function save_settled(setting)
    if setting.save_clock and os.clock() >= setting.save_clock then
        setting.save_clock = nil
        write_setting(setting.mod, setting.key, setting.value)
    end
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

-- Whether the widget is on screen: nothing above it hidden, and on the shown page of every switcher it sits in. The
-- menu keeps its other tabs and pages built, so being in the menu is not enough.
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
            -- The top of one widget's own tree: carry on from the widget it belongs to, until one on the screen itself.
            local tree = current:GetOuter()
            local owner = valid(tree) and tree:GetOuter() or nil
            if not valid(owner) or not owner:IsA(user_widget) then
                return true
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

-- The pause menu, or the main menu's, that this settings menu is part of.
local function find_pause_menu(menu)
    for _, pause in ipairs(FindAllOf("BPW_PauseMenu_C") or {}) do
        if pause:IsValid() and pause:GetFullName():find("/Engine/Transient", 1, true) then
            local inner = pause.BPW_SettingsMenu
            if valid(inner) and inner:GetAddress() == menu:GetAddress() then
                return pause
            end
        end
    end
    return nil
end

-- The highlighted row, if it is one of these and on screen, with everything needed to change it.
local function highlighted_setting(menu, pause)
    local target = pause.HighlightedSettingButton
    if not pause:IsInViewport() or not valid(target) then
        return nil
    end
    for _, setting in ipairs(sliders) do
        if setting.menu_address == menu:GetAddress() and target:GetAddress() == setting.row_address then
            local slider, _, row, label = find_row_parts(menu, setting)
            if slider and is_shown(row) then
                return setting, slider, label
            end
        end
    end
    return nil
end

-- Turns the highlighted row red, as the game's rows do, and every other row back.
local function update_pad_highlight(menu)
    local pause = find_pause_menu(menu)
    if not pause then
        return
    end
    local current = highlighted_setting(menu, pause)
    for _, setting in ipairs(sliders) do
        local wanted = setting == current
        if setting.menu_address == menu:GetAddress() and setting.pad_highlight ~= wanted then
            local _, _, _, label = find_row_parts(menu, setting)
            if label then
                label:SetColorAndOpacity(wanted and HIGHLIGHT_COLOR or PLAIN_COLOR)
                setting.pad_highlight = wanted
            end
        end
    end
end

-- Left and right on the D-pad step the highlighted row. The value is picked up and saved by the next poll.
local function on_menu_key(key)
    local direction = STEP_KEYS[key]
    if not direction then
        return
    end
    local menu = find_menu()
    local pause = menu and find_pause_menu(menu)
    local setting, slider = nil, nil
    if pause then
        setting, slider = highlighted_setting(menu, pause)
    end
    if setting then
        slider:SetValue(snap(setting, slider:GetValue() + direction * setting.step))
    end
end

local function report_pad_error(problem)
    pad_errors = pad_errors + 1
    if pad_errors <= 5 then
        log("Controller problem: " .. tostring(problem))
    end
end

local function pad_highlight_now(known_menu)
    local ok, problem = pcall(function()
        local menu = known_menu or find_menu()
        if menu then
            update_pad_highlight(menu)
        end
    end)
    if not ok then
        report_pad_error(problem)
    end
end

-- After the menu has handled its keys: each key acts on the row then highlighted, and the red follows the highlight.
local function handle_menu_keys()
    local keys = menu_keys
    menu_keys = {}
    for _, entry in ipairs(keys) do
        if entry.key then
            local ok, problem = pcall(on_menu_key, entry.key)
            if not ok then
                report_pad_error(problem)
            end
        end
    end
    pad_highlight_now(nil)
end

local function register_pad_hooks()
    if pad_hooks_registered then
        return
    end
    pad_hooks_registered = true
    local ok, problem = pcall(RegisterHook, KEY_COMPARE, function(_, first)
        pcall(function()
            last_compared_key = first:get().KeyName:ToString()
        end)
    end)
    if ok then
        ok, problem = pcall(RegisterHook, PAUSE_MENU_CLASS .. ":OnKeyDown", function()
            table.insert(menu_keys, { key = last_compared_key })
            last_compared_key = nil
            if #menu_keys == 1 then
                ExecuteInGameThread(handle_menu_keys)
            end
        end)
    end
    if not ok then
        log("Could not read the menu's keys, so the controller cannot move these sliders: " .. tostring(problem))
    end
end

local function update_all()
    local menu = find_menu()
    for _, setting in ipairs(sliders) do
        if menu then
            local ok, problem = pcall(update_setting, menu, setting)
            if not ok then
                log("Problem with " .. setting.label .. ": " .. tostring(problem))
                setting.failed_address = menu:GetAddress()
                setting.menu_address = nil
            end
        else
            setting.menu_address = nil
        end
        save_settled(setting)
    end
    if menu then
        register_pad_hooks()
        if #menu_keys > 0 then
            handle_menu_keys() -- In case a game thread step was missed.
        end
        pad_highlight_now(menu)
    end
end

-- Call from the game thread. It limits itself to its own pace, and an error here must never stop the caller's loop.
function ModSettings.Poll()
    if #sliders == 0 or os.clock() < next_poll_clock then
        return
    end
    next_poll_clock = os.clock() + POLL_MS / 1000.0
    local ok, problem = pcall(update_all)
    if not ok then
        log("Update failed, trying again: " .. tostring(problem))
    end
end

function ModSettings.StartPolling()
    if polling then
        return
    end
    polling = true
    LoopInGameThreadWithDelay(POLL_MS, ModSettings.Poll)
end

function ModSettings.AddSlider(options)
    local setting = {
        mod = options.mod,
        key = options.key,
        label = options.label,
        tab = TABS[options.tab] or "audio",
        min = options.min or 0,
        max = options.max or 100,
        step = options.step or 1,
        format = options.format or "%d",
        on_change = options.on_change,
    }
    local saved = read_settings(setting.mod)[setting.key]
    setting.value = snap(setting, saved or options.default or setting.max)
    table.insert(sliders, setting)
    return setting
end

return ModSettings
