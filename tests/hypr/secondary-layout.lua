-- Run from the source directory: lua tests/hypr/secondary-layout.lua
local source = arg[1] or "dot_config/hypr/secondary-layout.lua"
local factory = dofile(source)
local now, timers, handlers, clicks, calls, windows = 0, {}, {}, {}, {}, {}
local main = { id = 0, name = "DP-2" }
local secondary = {
    id = 1, name = "DP-3", width = 2560, height = 1440,
    scale = 1, transform = 1, x = 0, y = 0,
    reserved = { top = 34, right = 0, bottom = 0, left = 0 },
}
local workspaces = {}
for id = 1, 6 do
    workspaces[id] = {
        id = id, tiled_layout = "scrolling", monitor = id < 4 and main or secondary,
        gaps_out = { top = 6, right = 6, bottom = 6, left = 6 },
    }
end
main.active_workspace, secondary.active_workspace = workspaces[1], workspaces[6]
local active_monitor, active, outputs = secondary, nil, { main, secondary }
local cursor = { x = 10, y = 1000 }
local native_target, scrolling_target, fail_pin
local monitor_fallback = true
local press, release_pointer

local function emit(event, ...)
    for _, callback in ipairs(handlers[event] or {}) do callback(...) end
end

local function has(window, value)
    for _, tag in ipairs(window.tags) do if tag == value then return true end end
    return false
end

local function make_window(workspace, width)
    local window = {
        stable_id = #windows + 1, mapped = true, floating = false, pinned = false,
        fullscreen = 0, visible = true, tags = {}, workspace = workspace, monitor = workspace.monitor,
        at = { x = 10, y = 1000 }, size = { x = 1280, y = 1000 },
    }
    window.layout = { name = "scrolling", column = { width = width or 0.9, windows = { window } } }
    windows[#windows + 1] = window
    return window
end

local function focus(window)
    active, active_monitor = window, window.monitor
    active_monitor.active_workspace = window.workspace
end

local function command(kind)
    return function(args) return { kind = kind, args = args or {} } end
end

local api = {
    get_active_window = function() return active end,
    get_active_monitor = function() return active_monitor end,
    get_monitors = function() return outputs end,
    get_monitor = function(name)
        local adjacent = active_monitor == secondary and name == "r" and main
            or active_monitor == main and name == "l" and secondary
        for _, monitor in ipairs(outputs) do if monitor.name == name then return monitor end end
        for _, monitor in ipairs(outputs) do if monitor == adjacent then return monitor end end
    end,
    get_windows = function() return windows end,
    get_workspace_windows = function(workspace)
        local result = {}
        for _, window in ipairs(windows) do
            if window.workspace == workspace and window.mapped then result[#result + 1] = window end
        end
        return result
    end,
    get_config = function(key)
        if key == "binds.window_direction_monitor_fallback" then return monitor_fallback end
        assert(key == "general.border_size" or key == "scrolling.column_width", "unknown config key")
        return key == "general.border_size" and 1 or 0.9
    end,
    get_cursor_pos = function() return cursor end,
    on = function(event, callback)
        handlers[event] = handlers[event] or {}
        table.insert(handlers[event], callback)
    end,
    bind = function(key, callback, options)
        assert(key == "mouse:272" and options.non_consuming)
        if options.click then
            assert(options.release)
            clicks[#clicks + 1] = callback
        else
            assert(options.ignore_mods)
            if options.release then release_pointer = callback else press = callback end
        end
    end,
    timer = function(callback, options)
        timers[#timers + 1] = {
            callback = callback, due = now + options.timeout,
            interval = options.type == "repeat" and options.timeout or nil,
        }
    end,
    workspace_rule = function(rule)
        local workspace = workspaces[tonumber(rule.workspace)]
        assert(workspace.id >= 4, "main workspace changed")
        workspace.gaps_out = rule.gaps_out
        workspace.float_gaps = rule.float_gaps
    end,
    monitor = function() error("monitor reservations must not move Waybar") end,
    dsp = {
        layout = command("layout"), focus = command("focus"),
        cursor = { move = command("cursor") },
        window = {
            tag = command("tag"), pin = command("pin"), float = command("float"),
            move = command("move"), resize = command("resize"),
            fullscreen = command("fullscreen"), drag = command("drag"),
        },
    },
}

function api.dispatch(cmd)
    calls[#calls + 1] = cmd
    local a, kind = cmd.args, cmd.kind
    local window = a.window or active
    if kind == "tag" then
        local value = a.tag:sub(2)
        if a.tag:sub(1, 1) == "+" then
            if not has(window, value) then table.insert(window.tags, value) end
        else
            for i = #window.tags, 1, -1 do
                if window.tags[i] == value then table.remove(window.tags, i) end
            end
        end
    elseif kind == "pin" then
        if fail_pin and a.action == "enable" then return { ok = false } end
        assert(window.floating and window.fullscreen == 0)
        window.pinned = a.action == "enable"
        emit("window.pin", window)
    elseif kind == "float" then
        window.floating = a.action == "enable" or (a.action == "toggle" and not window.floating)
    elseif kind == "resize" then
        window.size = { x = a.x, y = a.y }
    elseif kind == "move" then
        if a.workspace then
            window.workspace = workspaces[a.workspace]
            window.monitor = window.workspace.monitor
            emit("window.move_to_workspace", window)
        elseif a.x then
            window.at = { x = a.x, y = a.y }
        end
    elseif kind == "fullscreen" then
        window.fullscreen = a.action == "unset" and 0 or (window.fullscreen == 0 and 2 or 0)
        emit("window.fullscreen", window)
    elseif kind == "focus" then
        if a.window then focus(a.window) elseif native_target then focus(native_target) end
    elseif kind == "cursor" then
        cursor = { x = a.x, y = a.y }
    elseif kind == "layout" then
        assert(active_monitor == secondary, "layout sent to main monitor")
        assert(active and not active.floating and active.workspace == active_monitor.active_workspace)
        local value = cmd.args
        if value:match("^colresize ") then active.layout.column.width = tonumber(value:match(" (%S+)$")) end
        assert(not value:match("center"), "secondary must only fit into view")
        if value:match("^focus ") and scrolling_target then focus(scrolling_target) end
    end
    return { ok = true }
end

local function advance(ms)
    local target = now + ms
    while true do
        local index, due
        for i, timer in ipairs(timers) do
            if timer.due <= target and (not due or timer.due < due) then index, due = i, timer.due end
        end
        if not index then break end
        local timer = table.remove(timers, index)
        now = due
        timer.callback()
        if timer.interval then
            timer.due = now + timer.interval
            timers[#timers + 1] = timer
        end
    end
    now = target
end

local function load()
    handlers, timers, clicks = {}, {}, {}
    for id = 4, 6 do workspaces[id].gaps_out.top = 6 end
    return factory(api, { monitor = { output = "DP-3" }, top_fraction = 0.3, column_width = 0.94, gap = 6 })
end

local count = 0
local function check(label, test)
    test()
    count = count + 1
    print("ok " .. count .. " - " .. label)
end

local controller = load()
check("verify-config starts no timers without monitors", function()
    local saved = outputs
    outputs = {}; emit("config.reloaded"); outputs = saved
    assert(#timers == 0)
end)
local a, b, c = make_window(workspaces[6]), make_window(workspaces[6]), make_window(workspaces[5])
focus(a)
emit("config.reloaded"); emit("hyprland.start"); advance(200)
check("empty startup and secondary width initialization", function()
    assert(not a.pinned and workspaces[6].gaps_out.top == 6)
    assert(a.layout.column.width == 0.94)
    a.layout.column.width = 0.82; advance(300)
    assert(a.layout.column.width == 0.82)
end)
controller.toggle_pin(); advance(200)
check("pin uses portrait geometry and preserves Waybar and main screen", function()
    assert(a.pinned and a.floating and has(a, "secondary-top"))
    assert(a.at.x == 7 and a.at.y == 41 and a.size.x == 1426 and a.size.y == 743)
    for id = 4, 6 do assert(workspaces[id].gaps_out.top == 763) end
    assert(secondary.reserved.top == 34 and workspaces[1].gaps_out.top == 6)
end)
check("fixed window ignores all direction and direction-move keys", function()
    local before = #calls
    for _, direction in ipairs({ "left", "right", "up", "down" }) do
        controller.focus(direction); controller.move(direction)
    end
    assert(#calls == before)
end)
check("lower navigation stays in native scrolling", function()
    focus(b); controller.focus("left")
    assert(not b.pinned and calls[#calls].args == "fit_into_view")
    local before = #calls; advance(500)
    assert(#calls == before, "hover/idle must not repeatedly scroll")
end)
check("transient missing window monitor is ignored", function()
    b.monitor = nil; advance(200); b.monitor = secondary
    assert(not b.pinned)
end)
check("click after hover fits without consuming the click", function()
    cursor = { x = b.at.x + 10, y = b.at.y + 10 }
    clicks[1](); advance(40)
    assert(calls[#calls].args == "fit_into_view")
    local before = #calls
    cursor.y = -10; clicks[1](); advance(40)
    assert(#calls == before, "panel click must not scroll")
end)
check("fullscreen below retains the fixed slot", function()
    b.fullscreen, a.visible = 2, false
    emit("window.fullscreen", b); advance(300)
    assert(a.pinned and workspaces[6].gaps_out.top == 763)
    b.fullscreen, a.visible = 0, true
    emit("window.fullscreen", b); advance(200)
    assert(a.pinned)
end)
check("workspace switch shares the same fixed window", function()
    a.workspace = workspaces[5] -- Native pinned-window migration.
    focus(c); advance(200)
    assert(a.pinned and workspaces[5].gaps_out.top == 763)
end)
check("replacement returns the old window to the active workspace", function()
    controller.toggle_pin(); advance(200)
    assert(not a.pinned and not a.floating and a.workspace == workspaces[5])
    assert(c.pinned and c.floating and workspaces[5].gaps_out.top == 763)
end)
check("reload restores tags and preserves manual column widths", function()
    focus(b); advance(200); b.layout.column.width = 0.81
    controller = load(); emit("config.reloaded"); advance(200)
    assert(c.pinned and has(c, "secondary-top") and workspaces[6].gaps_out.top == 763)
    assert(b.layout.column.width == 0.81)
end)
check("toggle unpins and returns the window to scrolling", function()
    focus(c); controller.toggle_pin(); advance(200)
    assert(not c.pinned and not c.floating and workspaces[5].gaps_out.top == 6)
end)
check("native drag gets both press and release after unpinning", function()
    controller.toggle_pin(); advance(200)
    local drag = controller.unfixed(api.dsp.window.drag())
    drag(); drag(); advance(200)
    assert(not c.pinned and c.floating and not has(c, "secondary-top"))
    assert(workspaces[5].gaps_out.top == 6 and calls[#calls].kind == "drag")
    assert(not a.pinned and not b.pinned)
end)
check("client and border geometry changes release without snapping back", function()
    controller.toggle_pin(); advance(200)
    c.at.y = c.at.y + 100; local moved = c.at.y
    advance(200)
    assert(not c.pinned and c.floating and c.at.y == moved and workspaces[5].gaps_out.top == 6)
    controller.toggle_pin(); advance(200)
    c.size.y = c.size.y - 50; advance(200)
    assert(not c.pinned and c.floating and workspaces[5].gaps_out.top == 6)
end)
check("layer reservation changes reposition the slot without detaching it", function()
    controller.toggle_pin(); advance(200)
    secondary.reserved.top = 50
    emit("layer.opened"); advance(200)
    assert(c.pinned and c.at.y == 57 and workspaces[5].gaps_out.top == 759)
    secondary.reserved.top = 34; advance(200)
end)
check("rotation and fractional scaling use logical coordinates", function()
    secondary.scale = 1.25; emit("monitor.layout_changed"); advance(200)
    assert(c.pinned and c.size.x == 1138 and c.size.y == 590)
    secondary.scale = 1; emit("monitor.layout_changed"); advance(200)
    assert(c.pinned and c.size.x == 1426)
end)
check("cross-monitor fallback skips the fixed window", function()
    local primary = make_window(workspaces[1])
    focus(primary); native_target = c
    controller.focus("left"); native_target = nil
    assert(active ~= c and not active.floating and active.workspace == workspaces[5])
    assert(cursor.y > active.at.y)
end)
check("right from the only lower column returns to the main monitor", function()
    local primary = windows[#windows]
    a.layout.column.index = 0
    focus(a); native_target = primary
    controller.focus("right"); native_target = nil
    assert(active == primary and active_monitor == main)
    assert(c.pinned, "cross-monitor focus must not alter the pin")
    focus(a)
end)
check("right visits the next column before crossing from the last column", function()
    local primary, previous_workspace = windows[#windows], b.workspace
    b.workspace, b.layout.column.index = a.workspace, 1
    focus(a); native_target, scrolling_target = primary, b
    controller.focus("right")
    assert(active == b and active_monitor == secondary, "must not skip a lower column")
    scrolling_target = a -- Native scrolling would wrap here without monitor fallback.
    controller.focus("right")
    assert(active == primary and active_monitor == main, "last column must leave instead of wrapping")
    native_target, scrolling_target = nil, nil
    b.workspace, b.layout.column.index = previous_workspace, nil
    focus(a)
end)
check("a missing neighbor or disabled fallback retains scrolling navigation", function()
    local primary = windows[#windows]
    focus(a); native_target = primary
    controller.focus("left") -- There is no monitor to the left of DP-3.
    assert(active == a and active_monitor == secondary)
    local saved = outputs
    outputs = { secondary }; controller.focus("right"); outputs = saved
    assert(active == a and active_monitor == secondary, "a disconnected monitor cannot receive focus")
    monitor_fallback = false; controller.focus("right"); monitor_fallback = true
    assert(active == a and active_monitor == secondary)
    native_target = nil
end)
check("stacked rows stay below the pin during vertical navigation", function()
    local previous_workspace, previous_layout = b.workspace, b.layout
    b.workspace, b.layout = a.workspace, a.layout
    focus(a); native_target, scrolling_target = c, b
    controller.focus("down")
    assert(active == b and not active.floating and c.pinned)
    native_target, scrolling_target = nil, nil
    b.workspace, b.layout = previous_workspace, previous_layout
    focus(a)
end)
check("close releases all slots without selecting a replacement", function()
    emit("window.close", c); c.mapped = false; advance(300)
    for id = 4, 6 do assert(workspaces[id].gaps_out.top == 6) end
    assert(not a.pinned and not b.pinned)
end)
check("reload does not adopt an untagged pinned window", function()
    a.floating, a.pinned = true, true
    controller = load(); emit("config.reloaded"); advance(200)
    assert(a.pinned and not has(a, "secondary-top") and workspaces[5].gaps_out.top == 6)
    a.pinned = false
end)
check("stale tag is removed without restoring a cancelled pin", function()
    a.tags[#a.tags + 1] = "secondary-top"
    controller = load(); emit("config.reloaded"); advance(200)
    assert(not a.pinned and not has(a, "secondary-top") and workspaces[5].gaps_out.top == 6)
end)
check("main monitor ignores the pin shortcut", function()
    local primary = windows[#windows]
    focus(primary); local before = #calls
    controller.toggle_pin(); assert(#calls == before)
end)
check("moving a window back and forth initializes only its secondary column", function()
    focus(b); controller.toggle_pin(); advance(200)
    local window = make_window(workspaces[6])
    focus(window); advance(200)
    assert(window.layout.column.width == 0.94)
    api.dispatch(api.dsp.window.move({ window = window, workspace = 1 }))
    window.layout.column.width = 0.9 -- Native default for a fresh column on DP-2.
    focus(window); advance(200)
    assert(window.layout.column.width == 0.9 and not has(window, "secondary-scrolling"))
    api.dispatch(api.dsp.window.move({ window = window, workspace = 6 }))
    focus(window); advance(200)
    assert(window.layout.column.width == 0.94)
    focus(b); controller.toggle_pin(); advance(200)
end)
check("new secondary window auto-pins without stealing background focus", function()
    local previous = active
    local window = make_window(workspaces[6])
    emit("window.open", window); advance(200)
    assert(window.pinned and active == previous and workspaces[6].gaps_out.top == 763)
    native_target = window -- Remember the owner for the following drop scenarios.
end)
check("new windows stay below when the top slot is occupied", function()
    local window = make_window(workspaces[6])
    emit("window.open", window); focus(window); advance(200)
    assert(not window.pinned and not window.floating and native_target.pinned)
    press(); window.floating = true; window.at.y = 100
    cursor = { x = 30, y = 100 }; release_pointer(); advance(200)
    assert(not window.pinned and not window.floating and native_target.pinned)
end)
check("dragging the owner down returns it to scrolling without a replacement", function()
    local owner = native_target; native_target = nil
    focus(owner); press()
    controller.unfixed(api.dsp.window.drag())()
    owner.at.y = 1000; cursor = { x = 30, y = 1200 }
    release_pointer(); advance(500)
    assert(not owner.pinned and not owner.floating and workspaces[6].gaps_out.top == 6)
    for _, window in ipairs(windows) do assert(not has(window, "secondary-top")) end
end)
check("dragging an existing lower window up fills an empty slot", function()
    focus(b); press(); b.floating = true; b.at.y = 100
    cursor = { x = 30, y = 100 }; release_pointer(); advance(200)
    assert(b.pinned and b.floating and workspaces[6].gaps_out.top == 763)
    controller.toggle_pin(); advance(200)
end)
check("a drag into the lower area does not trigger arrival auto-pinning", function()
    local window = make_window(workspaces[1])
    emit("window.open", window); focus(window); press()
    window.floating = true
    api.dispatch(api.dsp.window.move({ window = window, workspace = 6 }))
    window.at.y = 1200; cursor = { x = 30, y = 1400 }
    release_pointer(); advance(300)
    assert(not window.pinned and not window.floating and workspaces[6].gaps_out.top == 6)
end)
check("moving from the main screen without dragging auto-pins", function()
    local window = active
    api.dispatch(api.dsp.window.move({ window = window, workspace = 1 })); focus(window); advance(200)
    api.dispatch(api.dsp.window.move({ window = window, workspace = 6 })); advance(200)
    assert(window.pinned and has(window, "secondary-top"))
    focus(window); controller.toggle_pin(); advance(200)
end)
check("floating dialogs are preserved and reload with no pin stays empty", function()
    local dialog = make_window(workspaces[6]); dialog.floating = true
    emit("window.open", dialog); advance(200)
    assert(not dialog.pinned and dialog.floating)
    controller = load(); emit("config.reloaded"); advance(300)
    assert(workspaces[6].gaps_out.top == 6)
    for _, window in ipairs(windows) do assert(not has(window, "secondary-top")) end
end)
check("ordinary clicks and text selections do not pin a lower window", function()
    focus(b); press(); cursor = { x = 30, y = 100 }; release_pointer(); advance(200)
    assert(not b.pinned and workspaces[6].gaps_out.top == 6)
end)
check("failed pin creates no reserved slot", function()
    focus(b); fail_pin = true; controller.toggle_pin(); fail_pin = false
    assert(not b.pinned and not has(b, "secondary-top") and workspaces[6].gaps_out.top == 6)
end)
check("monitor disconnect safely releases only the owned pin", function()
    controller.toggle_pin(); advance(200)
    outputs = { main }; b.monitor = main; b.workspace = workspaces[1]
    emit("monitor.removed", secondary); advance(200)
    assert(not b.pinned and not has(b, "secondary-top"))
    assert(workspaces[6].gaps_out.top == 6 and workspaces[1].gaps_out.top == 6)
end)
print("passed " .. count .. " scenarios")
