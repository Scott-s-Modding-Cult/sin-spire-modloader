-- Admin panel. A button in the pause menu opens and closes it, and its Close button and Esc also close it. While it is
-- open the player and controller get no input, so nothing typed or clicked in the panel reaches the game.
--
-- The panel reuses the game's settings rows and menu buttons, hosted in a menu button whose contents are
-- replaced. Nothing here keeps a game object between ticks: the game can delete any object and reuse its
-- memory, and calling a deleted object crashes it. See GhostKiss for how that was found.

-- Other mods add pages of their own buttons with ModKit's AdminTabs, so nothing breaks if an older ModKit lacks it.
local has_tabs, AdminTabs = pcall(require, "AdminTabs")

local SPINNER_CLASS = "/Game/Blueprints/UI/Menu/Settings/BPW_SettingsSpinner.BPW_SettingsSpinner_C"
local BUTTON_CLASS = "/Game/Blueprints/UI/Menu/BPW_GenericMenuButton.BPW_GenericMenuButton_C"
local BUTTON_SHORT_CLASS = "BPW_GenericMenuButton_C"
local PAUSE_MENU_SHORT_CLASS = "BPW_PauseMenu_C"
local PAUSE_BUTTON_LABEL = "Admin Panel"
local BUTTON_PRESSED_HOOK = BUTTON_CLASS
    .. ":BndEvt__BPW_GenericMenuButton_Button_14_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature"
local TICK_MS = 50
local SETTLE_TICKS = 6 -- A new row can reset itself while it builds, so its choice is reapplied for a moment.
local ESCAPE_CLOSE_DELAY_MS = 200 -- The game must have seen Esc go down first, or it would open the pause menu.
local PANEL_WIDTH = 900.0
local PANEL_MAX_HEIGHT = 860.0 -- A longer page scrolls, so its Back and Close buttons stay on a 1080p screen.
local MONEY_STEP = 1000
local ALIVE = 0
local INPUT_LOCK_NONE = 0
local LOOPS_UNTIL_ERROR_IS_REPEATED = 200
-- PlantDistractor watches this count, and places a pair for each one added once the panel has closed.
local PLANT_REQUESTS_VARIABLE = "PlantDistractor_SpawnRequests"
-- The Backrooms mod watches this count, and goes there once the panel has closed.
local BACKROOMS_REQUESTS_VARIABLE = "Backrooms_EnterRequests"
-- NurseTouch reads this each time the futa nurse's cum effect fires.
local CUM_YAW_VARIABLE = "NurseTouch_CumYaw"
local CUM_YAW_STEP = 15
local CUM_YAW_DEFAULT = 285 -- NurseTouch's own default, the angle the user chose in game.

local OFF_ON = { "Off", "On" }
local MULTIPLIERS = { 1, 2, 3, 5, 10 }
local MULTIPLIER_LABELS = { "Normal", "2x", "3x", "5x", "10x" }
local CUM_YAW_LABELS = {}
for degrees = 0, 360 - CUM_YAW_STEP, CUM_YAW_STEP do
    table.insert(CUM_YAW_LABELS, tostring(degrees))
end

-- Every row keeps its chosen option here, so choices survive closing the panel and changing level.
local rows = {
    { key = "god", label = "God Mode", options = OFF_ON, index = 0 },
    { key = "stamina", label = "Infinite Stamina", options = OFF_ON, index = 0 },
    { key = "ammo", label = "Infinite Ammo", options = OFF_ON, index = 0 },
    { key = "sanity", label = "Lock Sanity", options = OFF_ON, index = 0 },
    { key = "speed", label = "Super Speed", options = MULTIPLIER_LABELS, index = 0 },
    { key = "jump", label = "Super Jump", options = MULTIPLIER_LABELS, index = 0 },
    { key = "cum_yaw", label = "Futa Nurse Cum Yaw", options = CUM_YAW_LABELS, index = CUM_YAW_DEFAULT // CUM_YAW_STEP },
}

local panel = nil -- { address, row_addresses, button_actions, settle }
local hook_registered = false
local pause_button = nil -- { menu_address, button_address }
local speed_scale = { WalkSpeed = {}, SprintSpeed = {} }
local accel_scale = {}
local jump_scale = {}
local saved_damage_multiplier = 1.0
local god_was_on = false
local stamina_was_on = false
local durability_seen = {}
local error_cooldown = 0
local cum_yaw_sent = nil

local function log(message)
    print("[AdminPanel] " .. message .. "\n")
end

-- UE4SS 3.0.1, the last stable release, has neither game thread timer. Players who installed it before the patch keep
-- it, so there a background timer hands each step to the game thread. That older way was linked to crashes, so the
-- game thread timers are used whenever they exist.
local function loop_in_game_thread(delay_ms, callback)
    if LoopInGameThreadWithDelay then
        LoopInGameThreadWithDelay(delay_ms, callback)
        return
    end
    log("This UE4SS has no LoopInGameThreadWithDelay, so an older loop is used. A newer UE4SS is more stable.")
    local waiting = false -- A slow frame must not pile up steps.
    LoopAsync(delay_ms, function()
        if not waiting then
            waiting = true
            ExecuteInGameThread(function()
                waiting = false
                callback()
            end)
        end
        return false
    end)
end

local function in_game_thread_after(delay_ms, callback)
    if ExecuteInGameThreadWithDelay then
        ExecuteInGameThreadWithDelay(delay_ms, callback)
    else
        ExecuteWithDelay(delay_ms, function()
            ExecuteInGameThread(callback)
        end)
    end
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function row_value(key)
    for _, row in ipairs(rows) do
        if row.key == key then
            return row.index
        end
    end
    return 0
end

local function is_on(key)
    return row_value(key) == 1
end

local function multiplier(key)
    return MULTIPLIERS[row_value(key) + 1] or 1
end

local function statics()
    return StaticFindObject("/Script/Engine.Default__GameplayStatics")
end

local function widget_library()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

local function current_controller()
    local controller = FindFirstOf("PlayerController")
    if valid(controller) then
        return controller
    end
    return nil
end

-- Only the player character has a health component and weapon inventory, so menus and cutscenes return nil.
local function current_player()
    local controller = current_controller()
    if controller and valid(controller.Pawn) and valid(controller.Pawn.BPC_HealthComponent)
        and valid(controller.Pawn.BP_WeaponInventory) then
        return controller.Pawn
    end
    return nil
end

-- The game overwrites these values itself (a new level's player, carrying an object), so a value that is not
-- the one last written is the game's new base. Returns the ratio applied, or nil if nothing changed.
local function apply_scale(owner, property, memory, scale)
    local current = owner[property]
    if current == nil then
        return nil
    end
    if memory.written == nil or math.abs(current - memory.written) > 0.01 then
        memory.base = current
    end
    local wanted = memory.base * scale
    memory.written = wanted
    if math.abs(current - wanted) <= 0.01 then
        return nil
    end
    owner[property] = wanted
    if current > 0 then
        return wanted / current
    end
    return nil
end

local function apply_movement(player)
    local movement = player.CharacterMovement
    if not valid(movement) then
        return
    end
    local speed = multiplier("speed")
    apply_scale(movement, "MaxAcceleration", accel_scale, speed)
    for property, memory in pairs(speed_scale) do
        local ratio = apply_scale(player, property, memory, speed)
        -- The game only copies these into the movement component when the movement state changes.
        if ratio and property == "WalkSpeed" then
            movement.MaxWalkSpeed = movement.MaxWalkSpeed * ratio
        end
    end
    apply_scale(movement, "JumpZVelocity", jump_scale, multiplier("jump"))
end

local function apply_god(player)
    local health = player.BPC_HealthComponent
    if is_on("god") then
        -- Damage is multiplied by this before anything else uses it, so hits still land but do nothing.
        if health.ExternalMultiplier ~= 0 then
            saved_damage_multiplier = health.ExternalMultiplier
            health.ExternalMultiplier = 0
        end
        if health.LifeState == ALIVE and health.CurrentHealth < health.MaxHealth then
            health:AddHealth(health.MaxHealth - health.CurrentHealth, {})
        end
        god_was_on = true
    elseif god_was_on then
        health.ExternalMultiplier = saved_damage_multiplier
        god_was_on = false
    end
end

local function apply_stamina(player)
    local health = player.BPC_HealthComponent
    if is_on("stamina") or is_on("god") then
        health.InfiniteStamina = true
        if health.Stamina < health.MaxStamina then
            health.Stamina = health.MaxStamina
        end
        stamina_was_on = true
    elseif stamina_was_on then
        health.InfiniteStamina = false
        stamina_was_on = false
    end
end

local function apply_ammo(player)
    if not is_on("ammo") then
        durability_seen = {}
        return
    end
    local weapon = player.BP_WeaponInventory.CurrentlySelectedWeapon
    if not valid(weapon) then
        return
    end
    local maximum = weapon.MaxMagazine
    if maximum and maximum > 0 and weapon.CurrentMagazine < maximum then
        weapon.CurrentMagazine = maximum
    end
    -- Weapons have no maximum durability value, so hold the highest one seen on this weapon.
    local durability = weapon.Durability
    if durability then
        local address = weapon:GetAddress()
        local highest = durability_seen[address] or durability
        if durability < highest then
            weapon.Durability = highest
        else
            highest = durability
        end
        durability_seen[address] = highest
    end
end

local function apply_sanity(player)
    if is_on("sanity") and player.Sanity < player.MaxSanity then
        player.Sanity = player.MaxSanity
    end
end

local function apply_cheats()
    local player = current_player()
    if not player then
        return
    end
    apply_god(player)
    apply_stamina(player)
    apply_ammo(player)
    apply_sanity(player)
    apply_movement(player)
end

local function full_heal()
    local player = current_player()
    if player then
        local health = player.BPC_HealthComponent
        if health.LifeState == ALIVE then
            health:AddHealth(health.MaxHealth - health.CurrentHealth, {})
        end
        player.Sanity = player.MaxSanity
    end
end

-- The game's own AddMoney also posts to the online money leaderboard, so this changes the value directly.
local function add_money()
    local player = current_player()
    if player then
        player.CurrentMoney = player.CurrentMoney + MONEY_STEP
        log("Money is now " .. player.CurrentMoney)
    end
end

-- Class templates count as instances too and crash the game if called, so only actors in a level are used.
local function kill_enemies()
    local killed = 0
    for _, enemy in ipairs(FindAllOf("BP_BaseEnemyCharacter_C") or {}) do
        if valid(enemy) and enemy:GetFullName():find(":PersistentLevel.", 1, true)
            and valid(enemy.BPC_HealthComponent) and enemy.BPC_HealthComponent.LifeState == ALIVE then
            enemy.BPC_HealthComponent:ForceDeath()
            killed = killed + 1
        end
    end
    log("Killed " .. killed .. " enemies")
end

local function spawn_plant_pair()
    local requests = (ModRef:GetSharedVariable(PLANT_REQUESTS_VARIABLE) or 0) + 1
    ModRef:SetSharedVariable(PLANT_REQUESTS_VARIABLE, requests)
    log("Asked for a random plant pair, request " .. requests)
end

local function enter_backrooms()
    local requests = (ModRef:GetSharedVariable(BACKROOMS_REQUESTS_VARIABLE) or 0) + 1
    ModRef:SetSharedVariable(BACKROOMS_REQUESTS_VARIABLE, requests)
    log("Asked to enter the Backrooms, request " .. requests)
end

local function send_cum_yaw()
    local degrees = row_value("cum_yaw") * CUM_YAW_STEP
    if degrees ~= cum_yaw_sent then
        ModRef:SetSharedVariable(CUM_YAW_VARIABLE, degrees)
        cum_yaw_sent = degrees
    end
end

local function new_widget(class_path, outer)
    return StaticConstructObject(StaticFindObject(class_path), outer)
end

local function fill_list(list_owner, labels)
    local options = {}
    for index = 1, #labels do
        options[index] = { Value = tostring(index - 1) }
    end
    list_owner.Options = options
    for index, label in ipairs(labels) do
        list_owner.Options[index].Label = FText(label)
    end
end

local function add_row(box, controller, row)
    local widget = widget_library():Create(controller, StaticFindObject(SPINNER_CLASS), controller)
    widget.Text = FText(row.label)
    widget.IsBool = false
    -- These rows have no console variable for the settings system to write to.
    widget.bAutoApply = false
    widget.bAutoSave = false
    -- The row copies its own list over the spinner's when it is built, so the list has to go on both.
    if widget.Options ~= nil then
        fill_list(widget, row.options)
    end
    fill_list(widget.Spinner, row.options)
    box:AddChild(widget)
    widget.TextBlock_91:SetText(FText(row.label))
    return widget:GetAddress()
end

local function add_button(box, controller, label)
    local widget = widget_library():Create(controller, StaticFindObject(BUTTON_CLASS), controller)
    box:AddChild(widget)
    widget.TextBlock_0:SetText(FText(label))
    return widget:GetAddress()
end

-- All rows and buttons hang off the host, so they are found again through it each tick instead of being kept.
local function find_rows_box(host)
    local box = host.WidgetTree.RootWidget:GetChildAt(0):GetChildAt(0):GetChildAt(0):GetChildAt(0)
    if valid(box) then
        return box
    end
    return nil
end

local function find_host()
    if not panel then
        return nil
    end
    for _, host in ipairs(FindAllOf(BUTTON_SHORT_CLASS) or {}) do
        if host:IsValid() and host:GetAddress() == panel.address then
            return host
        end
    end
    return nil
end

-- The pause menu the panel was opened from, if it is still up.
local function open_pause_menu()
    for _, menu in ipairs(FindAllOf(PAUSE_MENU_SHORT_CLASS) or {}) do
        if menu:IsValid() and not menu.IsStartMenu and menu:IsInViewport() then
            return menu
        end
    end
    return nil
end

local function close_panel()
    if not panel then
        return
    end
    local host = find_host()
    panel = nil
    if host then
        host:RemoveFromParent()
    end
    local controller = current_controller()
    if controller then
        -- The game itself never disables input on these, so there is no earlier state to restore.
        controller:EnableInput(controller)
        local player = current_player()
        if player then
            player:EnableInput(controller)
        end
        local menu = open_pause_menu()
        if menu then
            -- Back to the pause menu, which keeps the game paused and the cursor showing.
            widget_library():SetInputMode_GameAndUIEx(controller, menu, INPUT_LOCK_NONE, false, false)
            menu:SetUserFocus(controller)
        else
            widget_library():SetInputMode_GameOnly(controller, true)
            controller.bShowMouseCursor = false
            statics():SetGamePaused(controller, false)
        end
    end
    log("Closed")
end

local function mod_tabs()
    return has_tabs and AdminTabs.List() or {}
end

local show_page -- Set below, as the pages' buttons need it.

-- A mod's settings rows, in the form the cheat rows use. Each row tells the mod when its choice changes.
local function page_rows(page)
    local page_rows = {}
    for index, choice in ipairs(page.choices or {}) do
        page_rows[index] = {
            label = choice.label,
            options = choice.options,
            index = choice.value,
            on_change = function(value)
                AdminTabs.SetChoice(page.id, index, value)
            end,
        }
    end
    return page_rows
end

-- One page of the panel: the cheats, or with a tab given, that mod's rows and buttons.
local function build_panel(controller, page)
    local host = widget_library():Create(controller, StaticFindObject(BUTTON_CLASS), controller)
    local tree = host.WidgetTree
    local root = new_widget("/Script/UMG.CanvasPanel", tree)
    local background = new_widget("/Script/UMG.Border", tree)
    local size = new_widget("/Script/UMG.SizeBox", tree)
    local scroll = new_widget("/Script/UMG.ScrollBox", tree)
    local box = new_widget("/Script/UMG.VerticalBox", tree)
    local title = new_widget("/Script/UMG.TextBlock", tree)

    background:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.9 })
    background:SetPadding({ Left = 40.0, Top = 30.0, Right = 40.0, Bottom = 30.0 })
    size:SetWidthOverride(PANEL_WIDTH)
    size:SetMaxDesiredHeight(PANEL_MAX_HEIGHT)
    title:SetText(FText(page and page.title or "Admin Panel"))
    title:SetColorAndOpacity({ SpecifiedColor = { R = 0.75, G = 0.0, B = 0.0, A = 1.0 }, ColorUseRule = 0 })

    local slot = root:AddChild(background)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetAutoSize(true)
    background:AddChild(size)
    size:AddChild(scroll)
    scroll:AddChild(box)
    box:AddChild(title)

    local result = {
        address = host:GetAddress(),
        page = page,
        rows = page and page_rows(page) or rows,
        row_addresses = {},
        button_actions = {},
        settle = SETTLE_TICKS,
    }
    for index, row in ipairs(result.rows) do
        result.row_addresses[index] = add_row(box, controller, row)
    end
    if page then
        for index, label in ipairs(page.labels) do
            result.button_actions[add_button(box, controller, label)] = function()
                AdminTabs.Press(page.id, index)
                log(page.title .. ": " .. label)
            end
        end
        result.button_actions[add_button(box, controller, "Back")] = function()
            show_page(nil)
        end
    else
        result.button_actions[add_button(box, controller, "Full Heal")] = full_heal
        result.button_actions[add_button(box, controller, "Add " .. MONEY_STEP .. " Money")] = add_money
        result.button_actions[add_button(box, controller, "Kill All Enemies")] = kill_enemies
        result.button_actions[add_button(box, controller, "Spawn Random Plant Pair")] = spawn_plant_pair
        result.button_actions[add_button(box, controller, "Enter the Backrooms")] = enter_backrooms
        for _, tab in ipairs(mod_tabs()) do
            result.button_actions[add_button(box, controller, tab.title)] = function()
                show_page(tab)
            end
        end
    end
    result.button_actions[add_button(box, controller, "Close")] = close_panel

    tree.RootWidget = root
    pcall(function()
        host:SetIsFocusable(true)
    end)
    return host, result
end

local function open_panel()
    local controller = current_controller()
    if not controller or not current_player() then
        log("No player to open the panel for")
        return
    end
    local host, built = build_panel(controller)
    local player = current_player()
    host:AddToViewport(50)
    panel = built
    controller:DisableInput(controller)
    player:DisableInput(controller)
    widget_library():SetInputMode_UIOnlyEx(controller, host, INPUT_LOCK_NONE, true)
    controller.bShowMouseCursor = true
    log("Opened")
end

-- Swaps the panel for another page. Input stays with the panel, so only the widget and its focus change.
show_page = function(page)
    local controller = current_controller()
    if not panel or not controller then
        return
    end
    local old = find_host()
    local host, built = build_panel(controller, page)
    host:AddToViewport(50)
    panel = built
    if old then
        old:RemoveFromParent()
    end
    widget_library():SetInputMode_UIOnlyEx(controller, host, INPUT_LOCK_NONE, true)
    log("Showing " .. (page and page.title or "the main page"))
end

local function toggle_panel()
    if panel then
        close_panel()
    else
        open_panel()
    end
end

local function register_button_hook()
    if hook_registered then
        return
    end
    hook_registered = true
    RegisterHook(BUTTON_PRESSED_HOOK, function(context)
        local address = context:get():GetAddress()
        -- Actions wait for the next game thread step, as Close removes the button being pressed.
        if pause_button and address == pause_button.button_address then
            ExecuteInGameThread(toggle_panel)
        elseif panel and panel.button_actions[address] then
            ExecuteInGameThread(panel.button_actions[address])
        end
    end)
end

-- The controller makes one pause menu per level and shows and hides it, so the button goes in once per menu.
local function update_pause_button()
    local controller = current_controller()
    if not controller then
        return
    end
    for _, menu in ipairs(FindAllOf(PAUSE_MENU_SHORT_CLASS) or {}) do
        if menu:IsValid() and not menu.IsStartMenu and menu.ResumeButt:IsValid() then
            if pause_button and pause_button.menu_address == menu:GetAddress() then
                return
            end
            local parent = menu.ResumeButt:GetParent()
            if not valid(parent) then
                return
            end
            register_button_hook()
            local button = widget_library():Create(controller, StaticFindObject(BUTTON_CLASS), controller)
            local slot = parent:AddChild(button)
            local model = menu.ResumeButt.Slot
            -- Sits like the buttons around it. Only a vertical box has these, so another parent just keeps its defaults.
            pcall(function()
                slot:SetPadding(model.Padding)
                slot:SetHorizontalAlignment(model.HorizontalAlignment)
                slot:SetVerticalAlignment(model.VerticalAlignment)
                slot:SetSize(model.Size)
            end)
            button.TextBlock_0:SetText(FText(PAUSE_BUTTON_LABEL))
            pause_button = { menu_address = menu:GetAddress(), button_address = button:GetAddress() }
            log("Added the pause menu button to a " .. parent:GetClass():GetFName():ToString())
            return
        end
    end
end

local function update_panel()
    if not panel then
        return
    end
    local host = find_host()
    local box = host and find_rows_box(host)
    if not box then
        log("Panel is gone")
        close_panel()
        return
    end
    -- The title is the first child, then the rows in order.
    for index, row in ipairs(panel.rows) do
        local widget = box:GetChildAt(index)
        if not valid(widget) or widget:GetAddress() ~= panel.row_addresses[index] then
            log("Row is gone")
            close_panel()
            return
        end
        local spinner = widget.Spinner
        -- Selecting past the end of the list crashes the game, so never select without checking its size.
        if #spinner.Options ~= #row.options then
            if widget.Options ~= nil then
                fill_list(widget, row.options)
            end
            fill_list(spinner, row.options)
        elseif panel.settle > 0 then
            if spinner:GetCurrentIndex() ~= row.index then
                spinner:SelectIndex(row.index)
            end
        else
            local chosen = spinner:GetCurrentIndex()
            if chosen ~= row.index and row.options[chosen + 1] then
                row.index = chosen
                if row.on_change then
                    row.on_change(chosen)
                end
                log(row.label .. ": " .. row.options[chosen + 1])
            end
        end
    end
    if panel.settle > 0 then
        panel.settle = panel.settle - 1
    end
end

local function tick()
    update_pause_button()
    update_panel()
    send_cum_yaw()
    apply_cheats()
end

RegisterKeyBind(Key.ESCAPE, function()
    if panel then
        in_game_thread_after(ESCAPE_CLOSE_DELAY_MS, close_panel)
    end
end)

loop_in_game_thread(TICK_MS, function()
    local ok, message = pcall(tick)
    if ok then
        return
    end
    -- This runs 20 times a second, so one failure must not flood the log.
    if error_cooldown <= 0 then
        log("Error: " .. tostring(message))
        error_cooldown = LOOPS_UNTIL_ERROR_IS_REPEATED
    end
    error_cooldown = error_cooldown - 1
end)

log("Loaded, the pause menu opens the panel")
