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

local ModSettings = {}

local POLL_MS = 100
local SAVE_DELAY_SECONDS = 1.0 -- Dragging a slider changes it many times, so saving waits for it to settle.
local SETTINGS_FILE = "settings.txt"
local SIZE_RULE_FILL = 1
local VALIGN_CENTER = 2
local LABEL_FILL, SLIDER_FILL = 1.0, 1.0
local TABS = { audio = "audio", video = "video" }

local sliders = {}
local polling = false
local next_poll_clock = 0.0

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
    log("Added " .. setting.label .. " at " .. value_text(setting))
    return true
end

-- The row and its parts, found again through the menu, or nil if any of them are gone.
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
            local slider, value = child:GetChildAt(1), child:GetChildAt(2)
            if slider:IsValid() and value:IsValid() then
                return slider, value
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
    LoopAsync(POLL_MS, function()
        ExecuteInGameThread(ModSettings.Poll)
        return false
    end)
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
