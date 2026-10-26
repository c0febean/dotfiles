-- Keep native edge fitting; center interior columns on explicit focus changes.
-- No focus commands, global mode changes, or screen-coordinate inference.
return function(api)
    -- Hyprland 0.56 passes Desktop::eFocusReason as window.active's second
    -- argument. FFM changes keyboard focus too, but must not move the view.
    local FOCUS_REASON_FFM = 1
    local FOCUS_REASON_SWITCH_TO_WINDOW_SOFT = 8
    local hover_focus = false
    local pending = false
    local last_applied
    local invalidated = false

    local function snapshot()
        -- layout() targets the focused monitor's special/regular workspace,
        -- not the active window's workspace. These can temporarily differ
        -- when keyboard focus crosses monitors or workspaces.
        local monitor = api.get_active_monitor()
        if not monitor or monitor.name ~= "DP-2" then
            return
        end
        local workspace = monitor.active_special_workspace or monitor.active_workspace
        if not workspace or workspace.id < 1 or workspace.id > 3
            or workspace.tiled_layout ~= "scrolling" then
            return
        end

        local window = api.get_active_window()
        if not window or not window.mapped or window.floating or window.fullscreen ~= 0 then
            return
        end

        local window_workspace = window.workspace
        local window_monitor = window.monitor
        if not window_workspace or window_workspace.id ~= workspace.id
            or not window_monitor or window_monitor.id ~= monitor.id then
            return
        end

        local layout = window.layout
        local column = layout and layout.column
        if not layout or layout.name ~= "scrolling" or not column or column.index == nil then
            return
        end

        -- A column can contain several windows; use its logical index once.
        local columns = {}
        for _, candidate in ipairs(api.get_workspace_windows(workspace)) do
            if candidate.mapped and not candidate.floating then
                local candidate_layout = candidate.layout
                local candidate_column = candidate_layout and candidate_layout.column
                if candidate_column and candidate_column.index ~= nil then
                    columns[candidate_column.index] = candidate_column.width
                end
            end
        end

        local indices = {}
        for index in pairs(columns) do
            indices[#indices + 1] = index
        end
        table.sort(indices)
        if #indices == 0 or columns[column.index] == nil then
            return
        end

        -- Focus belongs to a column, not to an individual window in it.
        local parts = { tostring(workspace.id), tostring(column.index) }
        for _, index in ipairs(indices) do
            parts[#parts + 1] = string.format("%d:%.6f", index, columns[index])
        end
        local edge = column.index == indices[1] or column.index == indices[#indices]
        return table.concat(parts, "/"), edge and "fit_into_view" or "center"
    end

    local function dispatch_view(state, command)
        -- Record before dispatch so a synchronous event cannot recurse.
        last_applied = state
        invalidated = false
        api.dispatch(api.dsp.layout(command))
    end

    local function schedule()
        if pending then
            return
        end
        pending = true
        local previous
        local function settle()
            -- A mouse focus change cancels even an already queued update.
            if hover_focus then
                pending = false
                return
            end
            -- Ignore event arguments: an open/close event may describe a
            -- background window, and several focus changes may be queued.
            local state, command = snapshot()
            if state ~= previous then
                previous = state
                api.timer(settle, { timeout = 16, type = "oneshot" })
                return
            end

            pending = false
            if not state then
                last_applied = nil
                invalidated = false
                return
            end
            if state == last_applied and not invalidated then
                return
            end
            dispatch_view(state, command)
        end
        api.timer(settle, { timeout = 16, type = "oneshot" })
    end

    local function request_view()
        -- Native callbacks may move the camera even if the logical state
        -- returns to its previous value during a rapid A-B-A.
        invalidated = true
        schedule()
    end

    -- Hover can focus a preview before it is clicked, so no new window.active
    -- event is guaranteed. Observe plain left clicks without consuming them.
    api.bind("mouse:272", function()
        if not snapshot() then
            return
        end
        local window = api.get_active_window()
        local cursor = api.get_cursor_pos()
        local at, size = window.at, window.size
        -- Coordinates are only a click hit test, never an edge classifier.
        -- Clicking a panel or the desktop must not scroll the last window.
        if cursor.x < at.x or cursor.x >= at.x + size.x
            or cursor.y < at.y or cursor.y >= at.y + size.y then
            return
        end
        local address = window.address
        -- Deliver the application's button release before moving its window.
        api.timer(function()
            local current = api.get_active_window()
            if not current or current.address ~= address then
                return
            end
            local state, command = snapshot()
            if state then
                hover_focus = false
                dispatch_view(state, command)
            end
        end, { timeout = 16, type = "oneshot" })
    end, { release = true, click = true, non_consuming = true })

    api.on("window.active", function(_, reason)
        hover_focus = reason == FOCUS_REASON_FFM
        if hover_focus then
            invalidated = false
            return
        end
        if reason == FOCUS_REASON_SWITCH_TO_WINDOW_SOFT then
            -- moveFocus emits this reason, then immediately warps the cursor.
            -- With follow_focus=false, native scrolling ignores that focus.
            -- Move the tape now: a deferred update leaves the target off-screen
            -- and its cursor warp can select DP-3 before the timer fires.
            local state, command = snapshot()
            if state then
                dispatch_view(state, command)
                return
            end
        end
        request_view()
    end)

    for _, event in ipairs({
        "window.open", "window.close", "window.move_to_workspace",
        "monitor.layout_changed",
    }) do
        api.on(event, function()
            if not hover_focus then
                request_view()
            end
        end)
    end

    for _, event in ipairs({
        "window.fullscreen", "workspace.active", "workspace.special_active",
    }) do
        api.on(event, function()
            hover_focus = false
            request_view()
        end)
    end

    local started = false
    local function start()
        if started or #api.get_monitors() == 0 then
            return
        end
        started = true
        -- --verify-config also emits config.reloaded but has no monitors
        -- or running event loop; timer cleanup crashes there in 0.56.2.
        -- This version has no Lua event for a tiled drag/resize ending.
        api.timer(function()
            -- Polling must not turn an ignored hover into a delayed scroll.
            if hover_focus then
                return
            end
            local state = snapshot()
            if state ~= last_applied then
                schedule()
            end
            if not state then
                last_applied = nil
            end
        end, { timeout = 120, type = "repeat" })
        schedule()
    end

    api.on("hyprland.start", start)
    api.on("config.reloaded", start)
end
