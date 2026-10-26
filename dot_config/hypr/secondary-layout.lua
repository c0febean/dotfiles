-- DP-3: a shared floating/pinned top slot above native scrolling workspaces.
-- Config reloads restore tagged pins without adopting existing lower windows.
return function(api, options)
    local PIN_TAG = "secondary-top"
    local WIDTH_TAG = "secondary-scrolling"
    local output = options.monitor.output
    local fixed, expected, area_key
    local reserved_height = 0
    local started, pending, busy = false, false, false
    local columns, last_lower, locations, arrivals = {}, {}, {}, {}
    local pointer

    local function tagged(window, tag)
        for _, value in ipairs(window.tags or {}) do
            if value == tag then return true end
        end
        return false
    end

    local function tag(window, value)
        api.dispatch(api.dsp.window.tag({ window = window, tag = value }))
    end

    local function same(a, b)
        return a and b and a.stable_id == b.stable_id
    end

    local function secondary_workspace(workspace)
        return workspace and workspace.id >= 4 and workspace.id <= 6
            and workspace.monitor and workspace.monitor.name == output
    end

    local function lower_window(window)
        return window and window.mapped and not window.floating
            and secondary_workspace(window.workspace)
    end

    local function active_lower()
        local monitor = api.get_active_monitor()
        local workspace = monitor and (monitor.active_special_workspace or monitor.active_workspace)
        local window = api.get_active_window()
        if not monitor or monitor.name ~= output or not secondary_workspace(workspace)
            or workspace.tiled_layout ~= "scrolling" or not lower_window(window)
            or window.workspace.id ~= workspace.id or not window.monitor or window.monitor.id ~= monitor.id then
            return
        end
        return window, workspace
    end

    local function reserve(height)
        if reserved_height == height then return end
        reserved_height = height
        -- Monitor reserved areas move layer-shell panels as well. Workspace
        -- gaps reserve the scrolling area while leaving Waybar at the top.
        -- workspace_rule merges these fields into the existing workspace rule.
        for id = 4, 6 do
            api.workspace_rule({
                workspace = tostring(id),
                gaps_out = {
                    top = options.gap + height, right = options.gap,
                    bottom = options.gap, left = options.gap,
                },
                float_gaps = options.gap,
            })
        end
    end

    local function release(retile)
        local window = fixed
        fixed, expected, area_key = nil, nil, nil
        reserve(0)
        if not window or not window.mapped then return end
        busy = true
        tag(window, "-" .. PIN_TAG)
        if window.pinned and window.floating and window.fullscreen == 0 then
            api.dispatch(api.dsp.window.pin({ window = window, action = "disable" }))
        end
        if retile and window.fullscreen == 0 then
            local monitor = api.get_monitor(output)
            local workspace = monitor and monitor.active_workspace
            if secondary_workspace(workspace) then
                api.dispatch(api.dsp.window.move({ window = window, workspace = workspace.id, follow = false }))
                api.dispatch(api.dsp.window.float({ window = window, action = "disable" }))
            end
        end
        busy = false
    end

    local function slot(monitor)
        -- In 0.56 the Lua width/height (and size) are untransformed pixels.
        local width, height = monitor.width, monitor.height
        if monitor.transform % 2 == 1 then width, height = height, width end
        width, height = math.floor(width / monitor.scale + 0.5), math.floor(height / monitor.scale + 0.5)
        local reserved = monitor.reserved
        local top = reserved.top
        local height_top = math.floor((height - top - reserved.bottom) * options.top_fraction)
        local inset = options.gap + api.get_config("general.border_size")
        local box = {
            x = monitor.x + reserved.left + inset,
            y = monitor.y + top + inset,
            w = math.max(1, width - reserved.left - reserved.right - 2 * inset),
            h = math.max(1, height_top - 2 * inset),
        }
        local key = table.concat({ monitor.id, box.x, box.y, box.w, box.h }, "/")
        local zone = { x = box.x - inset, y = monitor.y + top, w = box.w + 2 * inset, h = height_top }
        return box, height_top, key, zone
    end

    local function place(monitor)
        local box, height, key = slot(monitor)
        busy = true
        api.dispatch(api.dsp.window.resize({ window = fixed, x = box.w, y = box.h }))
        api.dispatch(api.dsp.window.move({ window = fixed, x = box.x, y = box.y }))
        -- Clients can impose size constraints; compare with the accepted goal,
        -- never with animation coordinates or an assumed client minimum size.
        local at, size = fixed.at, fixed.size
        expected = { x = at.x, y = at.y, w = size.x, h = size.y }
        area_key = key
        reserve(height)
        busy = false
    end

    local function column_key(window)
        local layout = window.layout
        local column = layout and layout.name == "scrolling" and layout.column
        if not column then return end
        local ids = {}
        for _, member in ipairs(column.windows) do ids[#ids + 1] = member.stable_id end
        table.sort(ids)
        return window.workspace.id .. "/" .. table.concat(ids, ","), column, ids
    end

    local function prepare_column(window)
        local key, column, ids = column_key(window)
        if not key or columns[key] then return end
        columns[key] = ids
        -- Set only default-sized, newly encountered columns. A static
        -- scrolling_width window rule would also follow the app to DP-2.
        local default = api.get_config("scrolling.column_width")
        if math.abs(column.width - default) < 0.0001 then
            api.dispatch(api.dsp.layout("colresize " .. options.column_width))
        end
        for _, member in ipairs(column.windows) do
            if not tagged(member, WIDTH_TAG) then tag(member, "+" .. WIDTH_TAG) end
        end
    end

    local function fit()
        local window, workspace = active_lower()
        if not window or window.fullscreen ~= 0 then return end
        last_lower[workspace.id] = window
        prepare_column(window)
        api.dispatch(api.dsp.layout("fit_into_view"))
    end

    local function focus_across_edge(window, direction)
        if direction ~= "left" and direction ~= "right" then return false end
        if not api.get_config("binds.window_direction_monitor_fallback")
            or not api.get_monitor(direction:sub(1, 1)) then return false end
        local _, column = column_key(window)
        if not column or column.index == nil then return false end
        local step = direction == "right" and 1 or -1
        for _, candidate in ipairs(api.get_workspace_windows(window.workspace)) do
            if lower_window(candidate) then
                local _, other = column_key(candidate)
                if other and other.index ~= nil and (other.index - column.index) * step > 0 then return false end
            end
        end
        -- Scrolling's layout focus wraps locally. At a column boundary, use
        -- native directional focus so it can fall back to the adjacent monitor.
        api.dispatch(api.dsp.focus({ direction = direction }))
        return true
    end

    local function pin_window(window, monitor, take_focus)
        if not window.mapped or not monitor or monitor.active_special_workspace
            or not secondary_workspace(monitor.active_workspace) then return false end
        busy = true
        if window.fullscreen ~= 0 then
            api.dispatch(api.dsp.window.fullscreen({ window = window, action = "unset" }))
        end
        if not window.workspace or window.workspace.id ~= monitor.active_workspace.id then
            api.dispatch(api.dsp.window.move({ window = window, workspace = monitor.active_workspace.id, follow = false }))
        end
        api.dispatch(api.dsp.window.float({ window = window, action = "enable" }))
        local result = api.dispatch(api.dsp.window.pin({ window = window, action = "enable" }))
        if not result.ok then busy = false; return false end
        tag(window, "+" .. PIN_TAG)
        fixed = window
        place(monitor)
        busy = false
        if take_focus then api.dispatch(api.dsp.focus({ window = window })) end
        return true
    end

    local function arrive(window)
        -- Keep app-specific floating dialogs/PiP rules intact. Dragging a
        -- floating window into the top slot is still an explicit opt-in.
        if started and not busy and not fixed and lower_window(window)
            and window.fullscreen == 0 and not (pointer and same(pointer.window, window)) then
            for _, queued in ipairs(arrivals) do if same(queued, window) then return end end
            arrivals[#arrivals + 1] = window
        end
    end

    local function drop(window, cursor)
        if not window or not window.mapped then return end
        if same(window, fixed) then release(false) end
        local monitor = api.get_monitor(output)
        if not monitor or monitor.active_special_workspace
            or not secondary_workspace(monitor.active_workspace) then return end
        local _, height, _, zone = slot(monitor)
        local screen_height = monitor.transform % 2 == 1 and monitor.width or monitor.height
        screen_height = math.floor(screen_height / monitor.scale + 0.5)
        if cursor.x < zone.x or cursor.x >= zone.x + zone.w
            or cursor.y < zone.y or cursor.y >= monitor.y + screen_height - monitor.reserved.bottom then return end
        if not fixed and cursor.y < zone.y + height then
            pin_window(window, monitor, true)
        else
            -- A full slot never replaces its owner on drop. Also return a
            -- formerly pinned window to scrolling when dropped below the slot.
            busy = true
            if window.pinned and window.fullscreen == 0 then
                api.dispatch(api.dsp.window.pin({ window = window, action = "disable" }))
            end
            api.dispatch(api.dsp.window.move({ window = window, workspace = monitor.active_workspace.id, follow = false }))
            api.dispatch(api.dsp.window.float({ window = window, action = "disable" }))
            busy = false
            api.dispatch(api.dsp.focus({ window = window }))
            fit()
        end
    end

    local function maintain()
        if not started or busy then return end
        local monitor = api.get_monitor(output)
        if fixed then
            if not monitor or not fixed.mapped or not fixed.floating or not fixed.pinned
                or not fixed.monitor or fixed.monitor.name ~= output
                or not secondary_workspace(fixed.workspace) or not tagged(fixed, PIN_TAG)
                or fixed.fullscreen ~= 0 then
                release(false)
            else
                local _, _, key = slot(monitor)
                if key ~= area_key then
                    place(monitor)
                elseif expected then
                    local at, size = fixed.at, fixed.size
                    if math.abs(at.x - expected.x) > 2 or math.abs(at.y - expected.y) > 2
                        or math.abs(size.x - expected.w) > 2 or math.abs(size.y - expected.h) > 2 then
                        -- Also catch client/border moves that bypass our binds.
                        release(false)
                    end
                end
            end
        end
        if not pointer then
            local waiting = arrivals
            arrivals = {}
            if not fixed then
                for _, candidate in ipairs(waiting) do
                    if lower_window(candidate) and candidate.fullscreen == 0
                        and pin_window(candidate, monitor, false) then break end
                end
            end
        end
        local window, workspace = active_lower()
        if window and window.fullscreen == 0 then
            last_lower[workspace.id] = window
            prepare_column(window)
        end
    end

    local function schedule()
        if not started or pending then return end
        pending = true
        api.timer(function()
            pending = false
            maintain()
        end, { timeout = 32, type = "oneshot" })
    end

    local function start()
        -- --verify-config emits config.reloaded without a running event loop.
        if started or #api.get_monitors() == 0 then return end
        started = true
        for _, window in ipairs(api.get_windows()) do
            locations[window.stable_id] = window.monitor and window.monitor.name
            if tagged(window, PIN_TAG) then
                if not fixed and window.mapped and window.floating and window.pinned
                    and window.monitor and window.monitor.name == output
                    and secondary_workspace(window.workspace) and window.fullscreen == 0 then
                    fixed = window
                else
                    tag(window, "-" .. PIN_TAG)
                    if window.mapped and window.pinned and window.floating and window.fullscreen == 0 then
                        api.dispatch(api.dsp.window.pin({ window = window, action = "disable" }))
                    end
                end
            end
            -- Preserve already-initialized columns, including manual widths,
            -- across reloads; do not infer a pinned window from its position.
            if lower_window(window) then
                local key, column, ids = column_key(window)
                local initialized = key ~= nil
                for _, member in ipairs(column and column.windows or {}) do
                    initialized = initialized and tagged(member, WIDTH_TAG)
                end
                if initialized then columns[key] = ids end
            end
        end
        local monitor = api.get_monitor(output)
        if fixed and monitor then place(monitor) end
        api.timer(maintain, { timeout = 120, type = "repeat" })
        schedule()
    end

    api.on("hyprland.start", start)
    api.on("config.reloaded", start)
    api.on("monitor.added", function() start(); schedule() end)
    api.on("monitor.layout_changed", function()
        if not started then return end
        schedule()
    end)
    for _, event in ipairs({ "monitor.removed", "layer.opened", "layer.closed", "window.pin", "window.fullscreen" }) do
        api.on(event, schedule)
    end
    api.on("window.close", function(window)
        if same(window, fixed) then release(false) end
        if window then locations[window.stable_id] = nil end
        schedule()
    end)
    api.on("window.move_to_workspace", function(window)
        local previous = window and locations[window.stable_id]
        if window then
            locations[window.stable_id] = window.monitor and window.monitor.name
            for key, ids in pairs(columns) do
                for _, id in ipairs(ids) do
                    if id == window.stable_id then columns[key] = nil; break end
                end
            end
        end
        if window and window.mapped and not lower_window(window) and tagged(window, WIDTH_TAG) then
            tag(window, "-" .. WIDTH_TAG)
        end
        if previous and previous ~= output then arrive(window) end
        schedule()
    end)
    api.on("window.open", function(window)
        locations[window.stable_id] = window.monitor and window.monitor.name
        arrive(window)
        schedule()
    end)

    -- Observe press/release across modifiers, including the native Super drag.
    -- The delayed release runs after Hyprland finishes its drag operation.
    api.bind("mouse:272", function()
        local window = api.get_active_window()
        pointer = { window = window }
        if window and window.mapped then
            local at, size = window.at, window.size
            pointer.x, pointer.y, pointer.w, pointer.h = at.x, at.y, size.x, size.y
            pointer.monitor = window.monitor and window.monitor.name
        end
    end, { non_consuming = true, ignore_mods = true })
    api.bind("mouse:272", function()
        local gesture = pointer
        if not gesture then return end
        local pos = api.get_cursor_pos()
        local cursor = { x = pos.x, y = pos.y }
        api.timer(function()
            if pointer ~= gesture then return end
            pointer = nil
            local window = gesture.window
            if window and window.mapped and gesture.x then
                local at, size = window.at, window.size
                local moved = math.abs(at.x - gesture.x) > 2 or math.abs(at.y - gesture.y) > 2
                    or math.abs(size.x - gesture.w) > 2 or math.abs(size.y - gesture.h) > 2
                    or (window.monitor and window.monitor.name ~= gesture.monitor)
                if moved then drop(window, cursor) end
            end
            schedule()
        end, { timeout = 16, type = "oneshot" })
    end, { release = true, non_consuming = true, ignore_mods = true })

    -- Mouse focus remains passive. A click can follow a hover without emitting
    -- window.active again, so fit on release without consuming the application click.
    api.bind("mouse:272", function()
        local window = active_lower()
        if not window or window.fullscreen ~= 0 then return end
        local at, size, cursor = window.at, window.size, api.get_cursor_pos()
        if cursor.x < at.x or cursor.x >= at.x + size.x
            or cursor.y < at.y or cursor.y >= at.y + size.y then return end
        api.timer(function()
            if same(api.get_active_window(), window) then fit() end
        end, { timeout = 16, type = "oneshot" })
    end, { release = true, click = true, non_consuming = true })

    local controller = {}

    function controller.toggle_pin()
        local monitor, window = api.get_active_monitor(), api.get_active_window()
        if not started or not monitor or monitor.name ~= output or monitor.active_special_workspace
            or not secondary_workspace(monitor.active_workspace) or not window or not window.mapped
            or not window.monitor or window.monitor.id ~= monitor.id then return end
        if same(window, fixed) then release(true); return end
        release(true)
        pin_window(window, monitor, true)
    end

    function controller.focus(direction)
        if same(api.get_active_window(), fixed) then return end
        local window = active_lower()
        if window and window.fullscreen == 0 then
            prepare_column(window)
            if not focus_across_edge(window, direction) then
                api.dispatch(api.dsp.layout("focus " .. direction))
            end
            fit()
        else
            local previous = api.get_active_window()
            api.dispatch(api.dsp.focus({ direction = direction }))
            -- Cross-monitor fallback can choose the monitor's last focused
            -- pinned window. Redirect that case to its scrolling workspace.
            if same(api.get_active_window(), fixed) then
                local workspace = api.get_monitor(output).active_workspace
                local target = last_lower[workspace.id]
                if not lower_window(target) or target.workspace.id ~= workspace.id then
                    target = nil
                    for _, candidate in ipairs(api.get_workspace_windows(workspace)) do
                        if lower_window(candidate) then target = candidate; break end
                    end
                end
                target = target or previous
                if target and target.mapped then
                    api.dispatch(api.dsp.focus({ window = target }))
                    fit()
                    local at, size = target.at, target.size
                    api.dispatch(api.dsp.cursor.move({ x = at.x + size.x / 2, y = at.y + size.y / 2 }))
                end
            end
        end
    end

    function controller.move(direction)
        if same(api.get_active_window(), fixed) then return end
        api.dispatch(api.dsp.window.move({ direction = direction }))
        schedule()
    end

    function controller.unfixed(dispatcher)
        return function()
            if same(api.get_active_window(), fixed) then release(false) end
            -- Native mouse dispatchers set releasePending on this Lua bind, so
            -- the matching release still reaches Hyprland and ends the drag.
            return api.dispatch(dispatcher)
        end
    end

    return controller
end
