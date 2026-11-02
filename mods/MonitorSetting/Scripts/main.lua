-- Adds a Monitor setting to the game's settings menu and keeps the game window on the chosen monitor.
-- The game cannot move its own window from a script, so helper.ps1 does it, watching monitor.txt.

local MOD_DIR = "ue4ss\\Mods\\MonitorSetting\\"
local MONITOR_FILE = MOD_DIR .. "monitor.txt"
local MONITORS_FILE = MOD_DIR .. "monitors.txt"
local HELPER_FILE = MOD_DIR .. "start_helper.vbs"
local DEFAULT_MONITOR = 2
local SPINNER_CLASS = "/Game/Blueprints/UI/Menu/Settings/BPW_SettingsSpinner.BPW_SettingsSpinner_C"
local POLL_MS = 200
local SETTLE_POLLS = 5 -- The new row can reset itself while it builds, so reapply the choice for a moment.

local setting = nil
local failed_address = nil

local function log(message)
    print("[MonitorSetting] " .. message .. "\n")
end

local function read_monitor()
    local file = io.open(MONITOR_FILE, "r")
    if not file then
        return DEFAULT_MONITOR
    end
    local number = tonumber(file:read("l") or "")
    file:close()
    return number or DEFAULT_MONITOR
end

local function write_monitor(number)
    local file = io.open(MONITOR_FILE, "w")
    if file then
        file:write(tostring(number) .. "\n")
        file:close()
    end
end

-- Each line of monitors.txt is "<number>|<description>", written by the helper from the Windows display list.
local function read_monitors()
    local monitors = {}
    local file = io.open(MONITORS_FILE, "r")
    if file then
        for line in file:lines() do
            local number, description = line:match("^(%d+)|(.*)$")
            if number then
                table.insert(monitors, { number = tonumber(number), description = description })
            end
        end
        file:close()
    end
    return monitors
end

-- os.execute would flash a cmd.exe window, so this asks the shell to open the launcher script instead.
-- It has to be a file:// URL, because the engine sends anything without a scheme to the web browser.
local function start_helper()
    ExecuteInGameThread(function()
        local paths = StaticFindObject("/Script/Engine.Default__BlueprintPathsLibrary")
        local full = paths:ConvertRelativePathToFull(HELPER_FILE:gsub("\\", "/"), ""):ToString()
        local url = "file:///" .. full:gsub(" ", "%%20")
        log("Starting helper: " .. url)
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):LaunchURL(url)
    end)
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

local function fill_list(list_owner, monitors)
    local options = {}
    for index, monitor in ipairs(monitors) do
        options[index] = { Value = tostring(monitor.number) }
    end
    list_owner.Options = options
    for index, monitor in ipairs(monitors) do
        list_owner.Options[index].Label = FText(string.format("Monitor %d (%s)", monitor.number, monitor.description))
    end
end

local function fill_options(widget, monitors)
    if widget.Options ~= nil then
        fill_list(widget, monitors)
    end
    fill_list(widget.Spinner, monitors)
end

local function add_setting(menu)
    local monitors = read_monitors()
    if #monitors == 0 then
        log("No monitor list yet")
        return nil
    end
    local template = menu.BPW_AntiAliasingSetting
    local panel = template:GetParent()
    local controller = FindFirstOf("PlayerController")
    local spinner_class = StaticFindObject(SPINNER_CLASS)
    if not panel:IsValid() or not controller:IsValid() or not spinner_class:IsValid() then
        log("Menu is not ready")
        return nil
    end
    local widget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller, spinner_class, controller)
    if not widget or not widget:IsValid() then
        log("Could not create the setting row")
        return nil
    end
    widget.Text = FText("Monitor")
    widget.IsBool = false
    -- This row saves its own value, and has no console variable for the settings system to write to.
    widget.bAutoApply = false
    widget.bAutoSave = false

    local chosen_index = 0
    local chosen = read_monitor()
    for index, monitor in ipairs(monitors) do
        if monitor.number == chosen then
            chosen_index = index - 1
        end
    end
    -- The row copies its own list over the spinner's when it is built, so the list has to go on the row.
    fill_options(widget, monitors)

    local slot = panel:AddChild(widget)
    copy_slot_layout(template.Slot, slot)
    widget.TextBlock_91:SetText(FText("Monitor"))
    log(string.format("Added the setting with %d monitors, showing %d", #monitors, chosen))
    return { address = menu:GetAddress(), widget_address = widget:GetAddress(), monitors = monitors, index = chosen_index, settle = SETTLE_POLLS }
end

-- Class templates count as instances too and crash the game if called, so only trust menus living in
-- the running world. Everything here reads properties and calls no game functions.
local function find_menu()
    local menus = FindAllOf("BPW_SettingsMenu_C")
    if menus then
        for _, menu in ipairs(menus) do
            if menu:IsValid() and menu:GetFullName():find("/Engine/Transient", 1, true)
                and menu.BPW_AntiAliasingSetting:IsValid() then
                return menu
            end
        end
    end
    return nil
end

-- The game can delete and reuse any object, so the row is found again each time instead of being kept.
local function find_row(menu, address)
    local panel = menu.BPW_AntiAliasingSetting:GetParent()
    for index = panel:GetChildrenCount() - 1, 0, -1 do
        local child = panel:GetChildAt(index)
        if child:GetAddress() == address then
            return child
        end
    end
    return nil
end

local function update_setting()
    local menu = find_menu()
    if not menu then
        setting = nil
        return
    end
    if not setting or setting.address ~= menu:GetAddress() then
        local address = menu:GetAddress()
        if failed_address == address or #read_monitors() == 0 then
            return
        end
        -- Only try each menu once, so a failure cannot repeat every poll.
        failed_address = address
        setting = add_setting(menu)
        return
    end
    local row = find_row(menu, setting.widget_address)
    if not row or not row.Spinner:IsValid() then
        failed_address = nil
        setting = nil
        return
    end
    local spinner = row.Spinner
    -- Selecting past the end of the list crashes the game, so never select without checking its size.
    if #spinner.Options ~= #setting.monitors then
        fill_options(row, setting.monitors)
        return
    end
    -- Show the saved choice. Nothing is saved until the row has reached it, so only a person's change counts.
    if setting.settle > 0 then
        setting.settle = setting.settle - 1
        local current = spinner:GetCurrentIndex()
        if current ~= setting.index then
            spinner:SelectIndex(setting.index)
        end
        return
    end
    local index = spinner:GetCurrentIndex()
    if index ~= setting.index and setting.monitors[index + 1] then
        setting.index = index
        local number = setting.monitors[index + 1].number
        write_monitor(number)
        log("Moving to monitor " .. number)
    end
end

if not io.open(MONITOR_FILE, "r") then
    write_monitor(DEFAULT_MONITOR)
end
start_helper()

LoopInGameThreadWithDelay(POLL_MS, update_setting)

log("Loaded, monitor " .. read_monitor())
