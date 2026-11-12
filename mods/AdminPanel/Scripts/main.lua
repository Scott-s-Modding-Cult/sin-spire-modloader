-- Admin panel. A button in the pause menu opens and closes it, and its Close button and Esc also close it. While it is
-- open the player and controller get no input, so nothing typed or clicked in the panel reaches the game.
--
-- With a controller, the pause menu's own highlight reaches the button and A opens the panel. In the panel the D-pad
-- or left stick moves a highlight, left and right change a row, A presses, B goes back a page or closes, and Start
-- closes. ModKit's Pad module reads the controller; without it the panel still works with the mouse.
--
-- The panel reuses the game's settings rows and menu buttons, hosted in a menu button whose contents are
-- replaced. Nothing here keeps a game object between ticks: the game can delete any object and reuse its
-- memory, and calling a deleted object crashes it. See GhostKiss for how that was found.

-- Other mods add pages of their own buttons with ModKit's AdminTabs, so nothing breaks if an older ModKit lacks it.
local has_tabs, AdminTabs = pcall(require, "AdminTabs")
-- An older ModKit has no Pad module, so the panel then works without the controller.
local has_pad, Pad = pcall(require, "Pad")

local SPINNER_CLASS = "/Game/Blueprints/UI/Menu/Settings/BPW_SettingsSpinner.BPW_SettingsSpinner_C"
local BUTTON_CLASS = "/Game/Blueprints/UI/Menu/BPW_GenericMenuButton.BPW_GenericMenuButton_C"
local BUTTON_SHORT_CLASS = "BPW_GenericMenuButton_C"
local PAUSE_MENU_CLASS = "/Game/Blueprints/UI/Menu/BPW_PauseMenu.BPW_PauseMenu_C"
local PAUSE_MENU_SHORT_CLASS = "BPW_PauseMenu_C"
local PAUSE_BUTTON_LABEL = "Admin Panel"
local BUTTON_PRESSED_HOOK = BUTTON_CLASS
    .. ":BndEvt__BPW_GenericMenuButton_Button_14_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature"
local LOOP_MS = 25 -- Often enough to catch a quick tap on the controller.
local LOOPS_PER_TICK = 2 -- Everything else runs every 50 ms, as before.
local FIRST_ROW_CHILD = 2 -- In the panel's list the title comes first, then the controller hint, then the rows.
local PAD_HINT = "D-pad or stick: move     Left / Right: change     A: select     B: back"
local HINT_FONT_SIZE = 16
local VISIBILITY_COLLAPSED, VISIBILITY_HIDDEN, VISIBILITY_HIT_TEST_INVISIBLE = 1, 2, 3
local SCROLL_INTO_VIEW = 0
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

local panel = nil -- { address, page, rows, row_addresses, button_actions, items, settle, cursor, pad_used }
local hook_registered = false
local pad = nil -- Reads the controller while the panel is open.
if has_pad then
    pad = Pad.Reader({ Pad.UP, Pad.DOWN, Pad.LEFT, Pad.RIGHT, Pad.STICK_UP, Pad.STICK_DOWN, Pad.STICK_LEFT,
        Pad.STICK_RIGHT, Pad.A, Pad.B, Pad.MENU })
end
local pad_needs_reset = false
local pad_error_cooldown = 0
local focus_error_cooldown = 0
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

-- Whether the widget is on screen: nothing above it hidden, and on the shown page of every switcher it sits in. The
-- pause menu keeps its other pages built, so being in the menu is not enough.
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

-- A row or button of the panel, by the address it was made with.
local function item_widget(box, item)
    for index = 0, box:GetChildrenCount() - 1 do
        local child = box:GetChildAt(index)
        if valid(child) and child:GetAddress() == item.address then
            return child
        end
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
    -- Shown once the controller is in use, so mouse players do not see it.
    local hint = new_widget("/Script/UMG.TextBlock", tree)
    hint:SetText(FText(PAD_HINT))
    hint:SetColorAndOpacity({ SpecifiedColor = { R = 0.6, G = 0.6, B = 0.6, A = 1.0 }, ColorUseRule = 0 })
    pcall(function()
        local font = hint.Font
        font.Size = HINT_FONT_SIZE
        hint:SetFont(font)
    end)
    hint:SetVisibility(VISIBILITY_COLLAPSED)

    local slot = root:AddChild(background)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetAutoSize(true)
    background:AddChild(size)
    size:AddChild(scroll)
    scroll:AddChild(box)
    box:AddChild(title)
    box:AddChild(hint)

    local result = {
        address = host:GetAddress(),
        page = page,
        rows = page and page_rows(page) or rows,
        row_addresses = {},
        button_actions = {},
        items = {}, -- Rows and buttons in the order the controller's highlight moves through them.
        settle = SETTLE_TICKS,
    }
    local function add_action(label, action)
        local address = add_button(box, controller, label)
        result.button_actions[address] = action
        table.insert(result.items, { address = address })
    end
    for index, row in ipairs(result.rows) do
        result.row_addresses[index] = add_row(box, controller, row)
        table.insert(result.items, { address = result.row_addresses[index], row = index })
    end
    if page then
        for index, label in ipairs(page.labels) do
            add_action(label, function()
                AdminTabs.Press(page.id, index)
                log(page.title .. ": " .. label)
            end)
        end
        add_action("Back", function()
            show_page(nil)
        end)
    else
        add_action("Full Heal", full_heal)
        add_action("Add " .. MONEY_STEP .. " Money", add_money)
        add_action("Kill All Enemies", kill_enemies)
        add_action("Spawn Random Plant Pair", spawn_plant_pair)
        add_action("Enter the Backrooms", enter_backrooms)
        for _, tab in ipairs(mod_tabs()) do
            add_action(tab.title, function()
                show_page(tab)
            end)
        end
    end
    add_action("Close", close_panel)

    tree.RootWidget = root
    -- The panel must hold the focus, or the pause menu beneath it would keep the controller's buttons. SetIsFocusable
    -- does nothing in this game, so the flag is set directly.
    pcall(function()
        host.bIsFocusable = true
    end)
    pcall(function()
        host:SetIsFocusable(true)
    end)
    return host, result
end

-- The controller's highlight. The rows and buttons are the game's own, so they light up the way its menus do.
local function set_item_highlight(box, item, on)
    local widget = item and item_widget(box, item)
    if widget then
        pcall(function()
            if on then
                widget:Highlight()
            else
                widget:Unhighlight()
            end
        end)
    end
    return widget
end

local function move_cursor(box, to)
    local count = #panel.items
    if count == 0 then
        return
    end
    to = ((to - 1) % count) + 1
    if panel.cursor and panel.cursor ~= to then
        set_item_highlight(box, panel.items[panel.cursor], false)
    end
    panel.cursor = to
    local widget = set_item_highlight(box, panel.items[to], true)
    if widget then
        pcall(function()
            box:GetParent():ScrollWidgetIntoView(widget, true, SCROLL_INTO_VIEW, 0.0)
        end)
    end
end

-- Starts the controller's highlight on the first row and shows the hint, once the controller is in use.
local function start_pad_cursor(host)
    local box = find_rows_box(host)
    if not box or not panel then
        return
    end
    panel.pad_used = true
    local hint = box:GetChildAt(1)
    if valid(hint) then
        hint:SetVisibility(VISIBILITY_HIT_TEST_INVISIBLE)
    end
    if not panel.cursor then
        move_cursor(box, 1)
    end
end

-- Changes a row the way its arrows do, going round at the ends.
local function step_row(box, item, delta)
    local row = panel.rows[item.row]
    local widget = item_widget(box, item)
    if not row or not widget then
        return
    end
    local spinner = widget.Spinner
    local count = #row.options
    -- Selecting past the end of the list crashes the game, so only a row whose list is in place is changed.
    if count == 0 or #spinner.Options ~= count then
        return
    end
    local chosen = (row.index + delta) % count
    spinner:SelectIndex(chosen)
    row.index = chosen
    if row.on_change then
        row.on_change(chosen)
    end
    log(row.label .. ": " .. row.options[chosen + 1])
end

-- The panel takes no keys itself, so the controller's buttons reach the engine, where the Pad module reads them.
local function pad_tick()
    if not panel or not pad then
        return
    end
    local controller = current_controller()
    if not controller then
        return
    end
    if pad_needs_reset then
        -- A button held when the panel opened, such as the A that opened it, is not a new press.
        pad:reset(controller)
        pad_needs_reset = false
        return
    end
    if not pad:update(controller) then
        return
    end
    local host = find_host()
    local box = host and find_rows_box(host)
    if not box then
        return
    end
    if not panel.pad_used then
        start_pad_cursor(host)
        return -- The first press only shows where the highlight is.
    end
    if pad:pressed(Pad.MENU) then
        close_panel()
        return
    end
    if pad:pressed(Pad.B) then
        if panel.page then
            show_page(nil)
        else
            close_panel()
        end
        return
    end
    local up = pad:repeated(Pad.UP) or pad:repeated(Pad.STICK_UP)
    local down = pad:repeated(Pad.DOWN) or pad:repeated(Pad.STICK_DOWN)
    local left = pad:repeated(Pad.LEFT) or pad:repeated(Pad.STICK_LEFT)
    local right = pad:repeated(Pad.RIGHT) or pad:repeated(Pad.STICK_RIGHT)
    if up then
        move_cursor(box, (panel.cursor or 1) - 1)
    elseif down then
        move_cursor(box, (panel.cursor or 0) + 1)
    end
    local item = panel.cursor and panel.items[panel.cursor]
    if not item then
        return
    end
    if item.row then
        if left then
            step_row(box, item, -1)
        elseif right or pad:pressed(Pad.A) then
            step_row(box, item, 1)
        end
    elseif pad:pressed(Pad.A) then
        local action = panel.button_actions[item.address]
        if action then
            action()
        end
    end
end

-- Game and UI input, as the game's own pause menu uses, rather than UI only: under UI only the engine never sees the
-- controller's buttons. Input to the player and controller stays off and the game stays paused, so nothing reaches it.
local function focus_panel(controller, host)
    widget_library():SetInputMode_GameAndUIEx(controller, host, INPUT_LOCK_NONE, false, false)
    host:SetUserFocus(controller)
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
    focus_panel(controller, host)
    controller.bShowMouseCursor = true
    pad_needs_reset = true
    if pad and Pad.using_gamepad(controller) then
        start_pad_cursor(host)
    end
    log("Opened")
end

-- Swaps the panel for another page. Input stays with the panel, so only the widget and its focus change.
show_page = function(page)
    local controller = current_controller()
    if not panel or not controller then
        return
    end
    local pad_used = panel.pad_used
    local old = find_host()
    local host, built = build_panel(controller, page)
    host:AddToViewport(50)
    panel = built
    if old then
        old:RemoveFromParent()
    end
    focus_panel(controller, host)
    if pad_used then
        start_pad_cursor(host)
    end
    log("Showing " .. (page and page.title or "the main page"))
end

local function toggle_panel()
    if panel then
        close_panel()
    else
        open_panel()
    end
end

-- The pause menu works the controller itself: it moves a highlight over its buttons and, on A, calls the highlighted
-- one directly, which this mod cannot see. It keeps the focus, so it also keeps the D-pad: a focused button of this
-- mod's would take the D-pad for the engine's own navigation, and the menu's highlight would never leave it. Instead
-- the menu's keys are read as it checks them. Every key it gets goes through the engine's key comparison, and the
-- first comparison after its OnKeyDown starts holds the key pressed.
local KEY_COMPARE = "/Script/Engine.KismetInputLibrary:EqualEqual_KeyKey"
local menu_keys = {} -- One entry per OnKeyDown of the pause menu since the last game thread step.
local menu_key_logged = false

local function pause_menu_for_button()
    if not pause_button then
        return nil
    end
    for _, candidate in ipairs(FindAllOf(PAUSE_MENU_SHORT_CLASS) or {}) do
        if candidate:IsValid() and candidate:GetAddress() == pause_button.menu_address then
            return candidate
        end
    end
    return nil
end

-- A on the panel's button while the menu's highlight is on it opens the panel, as a click does.
local function on_menu_key(key)
    if key ~= "Gamepad_FaceButton_Bottom" or panel then
        return
    end
    local menu = pause_menu_for_button()
    if not menu or not menu:IsInViewport() or menu.HighlightedSocial or not valid(menu.ResumeButt) then
        return
    end
    if not valid(menu.HighlightedButton) or menu.HighlightedButton:GetAddress() ~= pause_button.button_address then
        return
    end
    local parent = menu.ResumeButt:GetParent()
    local button = valid(parent) and item_widget(parent, { address = pause_button.button_address }) or nil
    if button and is_shown(button) then
        toggle_panel()
    end
end

local function handle_menu_keys()
    local keys = menu_keys
    menu_keys = {}
    for _, entry in ipairs(keys) do
        if entry.key then
            if not menu_key_logged then
                menu_key_logged = true
                log("Reading the pause menu's keys, first " .. entry.key)
            end
            local ok, message = pcall(on_menu_key, entry.key)
            if not ok and focus_error_cooldown <= 0 then
                log("Controller error: " .. tostring(message))
                focus_error_cooldown = LOOPS_UNTIL_ERROR_IS_REPEATED
            end
        end
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
    local ok, problem = pcall(RegisterHook, PAUSE_MENU_CLASS .. ":OnKeyDown", function()
        table.insert(menu_keys, { key = nil })
        if #menu_keys == 1 then
            ExecuteInGameThread(handle_menu_keys)
        end
    end)
    if ok then
        ok, problem = pcall(RegisterHook, KEY_COMPARE, function(_, first)
            local entry = menu_keys[#menu_keys]
            if entry and not entry.key then
                pcall(function()
                    entry.key = first:get().KeyName:ToString()
                end)
            end
        end)
    end
    if not ok then
        log("Could not read the pause menu's keys, so A on its button needs the mouse: " .. tostring(problem))
    end
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
    -- The title and the controller hint come first, then the rows in order.
    for index, row in ipairs(panel.rows) do
        local widget = box:GetChildAt(index + FIRST_ROW_CHILD - 1)
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
    if #menu_keys > 0 then
        handle_menu_keys() -- In case a game thread step was missed.
    end
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

local loop_count = 0
loop_in_game_thread(LOOP_MS, function()
    -- The controller is read every loop while the panel is open, and the rest every LOOPS_PER_TICK loops.
    local pad_ok, pad_problem = pcall(pad_tick)
    if not pad_ok then
        if pad_error_cooldown <= 0 then
            log("Controller error: " .. tostring(pad_problem))
            pad_error_cooldown = LOOPS_UNTIL_ERROR_IS_REPEATED * LOOPS_PER_TICK
        end
        pad_error_cooldown = pad_error_cooldown - 1
    end
    loop_count = loop_count + 1
    if loop_count % LOOPS_PER_TICK ~= 0 then
        return
    end
    focus_error_cooldown = focus_error_cooldown - 1
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

if has_pad then
    log("Loaded, the pause menu opens the panel, with the mouse or the controller")
else
    log("Loaded, the pause menu opens the panel. No Pad module in ModKit, so the panel has no controller support")
end
