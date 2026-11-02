-- Lets any UE4SS mod add its own tab of test buttons to the admin panel.
--
--   local AdminTabs = require("AdminTabs")
--   local tab = AdminTabs.AddTab({ id = "MyMod", title = "My Mod" })
--   tab:AddButton("Do Something", function() end) -- Runs in this mod, on its game-thread tick.
--
-- A mod with its own game-thread tick calls AdminTabs.Poll() from it, and any other mod calls AdminTabs.StartPolling()
-- once. The tab only shows when the Admin Panel mod is installed. Without it, nothing presses the buttons and all of this
-- does nothing, so a mod using it needs only ModKit, not the panel.
--
-- The panel pauses the game while it is open, so a button that changes the world should queue the change for when the
-- game is running again.
--
-- Mods run in separate Lua states and cannot call each other, but they can share plain values. So the tabs are written
-- out as text, and each press adds one to a count that the mod owning the button watches.

local AdminTabs = {}

local POLL_MS = 100
local LIST_VARIABLE = "AdminTabs_List"
local TAB_VARIABLE = "AdminTabs_Tab_"
local PRESS_VARIABLE = "AdminTabs_Press_"
local SEPARATOR = "\n"

local tabs = {}
local polling = false

local function log(message)
    print("[AdminTabs] " .. message .. "\n")
end

local function one_line(text)
    return (tostring(text):gsub("[\r\n]+", " "))
end

local function split(text)
    local parts = {}
    for part in string.gmatch(text or "", "[^" .. SEPARATOR .. "]+") do
        table.insert(parts, part)
    end
    return parts
end

local function press_variable(id, index)
    return PRESS_VARIABLE .. id .. "_" .. index
end

local function publish(tab)
    local labels = {}
    for index, button in ipairs(tab.buttons) do
        labels[index] = button.label
    end
    ModRef:SetSharedVariable(TAB_VARIABLE .. tab.id, table.concat({ tab.title, table.unpack(labels) }, SEPARATOR))
end

local Tab = {}
Tab.__index = Tab

function Tab:AddButton(label, on_press)
    table.insert(self.buttons, { label = one_line(label), on_press = on_press, seen = 0 })
    publish(self)
    return self
end

function AdminTabs.AddTab(options)
    local id = one_line(options.id)
    local tab = setmetatable({ id = id, title = one_line(options.title or id), buttons = {} }, Tab)
    table.insert(tabs, tab)
    publish(tab)
    local known = split(ModRef:GetSharedVariable(LIST_VARIABLE))
    for _, other in ipairs(known) do
        if other == id then
            return tab
        end
    end
    table.insert(known, id)
    ModRef:SetSharedVariable(LIST_VARIABLE, table.concat(known, SEPARATOR))
    return tab
end

-- Runs the button of any press made since the last call.
function AdminTabs.Poll()
    for _, tab in ipairs(tabs) do
        for index, button in ipairs(tab.buttons) do
            local total = ModRef:GetSharedVariable(press_variable(tab.id, index)) or 0
            while button.seen < total do
                button.seen = button.seen + 1
                local ok, problem = pcall(button.on_press)
                if not ok then
                    log(tab.title .. ", " .. button.label .. " failed: " .. tostring(problem))
                end
            end
        end
    end
end

function AdminTabs.StartPolling()
    if polling then
        return
    end
    polling = true
    LoopInGameThreadWithDelay(POLL_MS, AdminTabs.Poll)
end

-- For the admin panel: every mod's tab, in the order the mods loaded, as { id, title, labels }.
function AdminTabs.List()
    local list = {}
    for _, id in ipairs(split(ModRef:GetSharedVariable(LIST_VARIABLE))) do
        local parts = split(ModRef:GetSharedVariable(TAB_VARIABLE .. id))
        local title = table.remove(parts, 1)
        if title then
            table.insert(list, { id = id, title = title, labels = parts })
        end
    end
    return list
end

-- For the admin panel: presses a button of another mod's tab.
function AdminTabs.Press(id, index)
    local variable = press_variable(id, index)
    ModRef:SetSharedVariable(variable, (ModRef:GetSharedVariable(variable) or 0) + 1)
end

return AdminTabs
