------------------
-- Debug functions

function initialize_debug()
    qw.debug_mode = DEBUG_MODE
    qw.debug_channels = {}
    for _, channel in ipairs(DEBUG_CHANNELS or {}) do
        qw.debug_channels[channel] = true
    end
    initialize_decision_log()
end

function toggle_debug()
    qw.debug_mode = not qw.debug_mode
    note_decision("DEBUG", (qw.debug_mode and "Enabling" or "Disabling") .. " debug mode")
end

function debug_channel(channel)
    return qw.debug_mode and qw.debug_channels[channel]
end

function toggle_debug_channel(channel)
    qw.debug_channels[channel] = not qw.debug_channels[channel]
    note_decision("DEBUG", (qw.debug_channels[channel] and "Enabling " or "Disabling ")
      .. channel .. " debug channel")
end

function disable_all_debug_channels()
    note_decision("DEBUG", "Disabling all debug channels")
    qw.debug_channels = {}
end

local DECISION_LOG_PATH = nil
local DECISION_LOG_FILE = nil

local function get_decision_log_path()
    if not DECISION_LOG_PATH then
        local name = you.name() or "qw"
        -- Use DECISION_LOG_DIR if set (e.g. by debug-seed.py), else /tmp.
        local dir = qw.decision_log_dir or "/tmp"
        DECISION_LOG_PATH = dir .. "/qw_decisions_" .. name .. ".log"
    end
    return DECISION_LOG_PATH
end

local function get_decision_log_file()
    if not DECISION_LOG_FILE then
        DECISION_LOG_FILE = io.open(get_decision_log_path(), "a")
    end
    return DECISION_LOG_FILE
end

function flush_decision_log()
    if DECISION_LOG_FILE then
        DECISION_LOG_FILE:flush()
    end
end

function close_decision_log()
    if DECISION_LOG_FILE then
        DECISION_LOG_FILE:close()
        DECISION_LOG_FILE = nil
    end
end

function initialize_decision_log()
    if not io or not qw.debug_mode then
        return
    end
    local path = get_decision_log_path()
    -- Append if the log already exists (preserves across save/restore cycles),
    -- otherwise create with a header.
    local exists = io.open(path, "r")
    if exists then
        exists:close()
        local f = get_decision_log_file()
        if f then
            local timestamp = os and os.date() or "unknown"
            f:write("--- Session resumed at " .. timestamp .. " ---\n")
        end
    else
        -- Create with header, then keep open via get_decision_log_file
        local f = io.open(path, "w")
        if f then
            local timestamp = os and os.date() or "unknown"
            f:write("QW Decision Log — " .. timestamp .. "\n")
            f:close()
        end
        -- Reopen in append mode as the persistent handle
        get_decision_log_file()
    end
end

function note_decision(category, message)
    if not io or not qw.debug_mode then
        return
    end
    local hp, mhp = you.hp()
    local pct = math.floor(100 * hp / mhp)
    local line = you.turns() .. " ||| QW " .. category
        .. " [HP:" .. hp .. "/" .. mhp .. " " .. pct .. "%]: " .. message
    local f = get_decision_log_file()
    if f then
        f:write(line .. "\n")
    end
end

function build_level_map_lines(use_grid)
    if not io or not qw.debug_mode then
        return
    end

    local feat_fn = use_grid and view.grid_feature_at or view.feature_at

    local min_x, max_x, min_y, max_y = const.gxm, -const.gxm, const.gxm, -const.gxm
    for x = -const.gxm, const.gxm do
        for y = -const.gxm, const.gxm do
            local feat = feat_fn(x, y)
            if feat and feat ~= "unseen" and feat ~= "rock_wall" then
                if x < min_x then min_x = x end
                if x > max_x then max_x = x end
                if y < min_y then min_y = y end
                if y > max_y then max_y = y end
            end
        end
    end

    if min_x > max_x then
        return nil
    end

    local feat_char = {
        floor = ".",
        rock_wall = "#",
        stone_wall = "#",
        metal_wall = "#",
        crystal_wall = "#",
        closed_door = "+",
        closed_clear_door = "+",
        runed_door = "+",
        runed_clear_door = "+",
        open_door = "'",
        open_clear_door = "'",
        shallow_water = "~",
        deep_water = "W",
        lava = "L",
        enter_shop = "$",
        altar = "_",
        transporter = "^",
        escape_hatch_up = "<",
        escape_hatch_down = ">",
    }

    local lines = {}
    for y = min_y, max_y do
        local row = {}
        for x = min_x, max_x do
            local feat = feat_fn(x, y)
            if x == 0 and y == 0 then
                table.insert(row, "@")
            elseif not feat or feat == "unseen" then
                table.insert(row, " ")
            elseif feat:find("stone_stairs_up") then
                table.insert(row, "<")
            elseif feat:find("stone_stairs_down") then
                table.insert(row, ">")
            elseif feat:find("exit_") then
                table.insert(row, "E")
            elseif feat:find("enter_") then
                table.insert(row, "P")
            elseif feat:find("altar_") then
                table.insert(row, "_")
            elseif feat_char[feat] then
                table.insert(row, feat_char[feat])
            elseif feat:find("wall") then
                table.insert(row, "#")
            elseif feat:find("door") then
                table.insert(row, "+")
            elseif feat:find("trap") then
                table.insert(row, "^")
            else
                table.insert(row, "?")
            end
        end
        table.insert(lines, table.concat(row))
    end

    return lines, where
end

function dump_level_map_to_file(prefix)
    if not io or not qw.debug_mode then
        return
    end

    local use_grid = view.grid_feature_at ~= nil
    local lines, level = build_level_map_lines(use_grid)
    if not lines then
        return
    end

    local safe_level = level:gsub(":", "-"):gsub(" ", "_")
    local dir = qw.decision_log_dir or "/tmp"
    local path = dir .. "/" .. (prefix or "map") .. "-" .. safe_level .. ".txt"
    local f = io.open(path, "w")
    if f then
        f:write("Level: " .. level .. "  Turn: " .. you.turns()
            .. "  XL: " .. you.xl()
            .. (use_grid and "  (full grid)" or "  (player knowledge)") .. "\n")
        f:write("Player at @\n\n")
        for _, line in ipairs(lines) do
            f:write(line .. "\n")
        end
        f:close()
    end
end

function dump_stats()
    if not io or not qw.stats then
        return
    end
    local dir = qw.decision_log_dir or "/tmp"
    local path = dir .. "/qw_stats.txt"
    local f = io.open(path, "w")
    if not f then
        return
    end
    for k, v in pairs(qw.stats) do
        f:write(k .. "=" .. tostring(v) .. "\n")
    end
    f:close()
    close_decision_log()
end

function write_reason(reason, detail)
    local dir = qw.decision_log_dir or "/tmp"
    local path = dir .. "/reason.txt"
    local f = io.open(path, "w")
    if not f then
        return
    end
    f:write(reason .. "\n")
    if detail then
        f:write(detail .. "\n")
    end
    f:close()
end

function test_radius_iter()
    note_decision("DEBUG", "Testing 3, 3 with radius 1")
    for pos in radius_iter({ x = 3, y = 3 }, 1) do
        note_decision("DEBUG", "x: " .. tostring(pos.x) .. ", y: " .. tostring(pos.y))
    end

    note_decision("DEBUG", "Testing const.origin with radius 3")
    for pos in radius_iter(const.origin, 3) do
        note_decision("DEBUG", "x: " .. tostring(pos.x) .. ", y: " .. tostring(pos.y))
    end
end

function print_traversal_map(center)
    if not center then
        center = const.origin
    end

    crawl.setopt("msg_condense_repeats = false")

    local map_center = position_sum(qw.map_pos, center)
    note_decision("MAP", "Traversal map at " .. cell_string_from_map_position(map_center))
    -- This needs to iterate by row then column for display purposes.
    for y = -20, 20 do
        local str = ""
        for x = -20, 20 do
            local pos = position_sum(map_center, { x = x, y = y })
            local traversable = map_is_traversable_at(pos)
            local char
            if positions_equal(pos, qw.map_pos) then
                if traversable == nil then
                    str = str .. "✞"
                else
                    str = str .. (traversable and "@" or "7")
                end
            elseif positions_equal(pos, map_center) then
                if traversable == nil then
                    str = str .. "W"
                else
                    str = str .. (traversable and "&" or "8")
                end
            elseif traversable == nil then
                str = str .. " "
            else
                str = str .. (traversable and "." or "#")
            end
        end
        note_decision("MAP", str)
    end

    crawl.setopt("msg_condense_repeats = true")
end

function print_unexcluded_map(center)
    if not center then
        center = const.origin
    end

    crawl.setopt("msg_condense_repeats = false")

    local map_center = position_sum(qw.map_pos, center)
    note_decision("MAP", "Unexcluded map at " .. cell_string_from_map_position(map_center))
    -- This needs to iterate by row then column for display purposes.
    for y = -20, 20 do
        local str = ""
        for x = -20, 20 do
            local pos = position_sum(map_center, { x = x, y = y })
            local unexcluded = map_is_unexcluded_at(pos)
            local char
            if positions_equal(pos, qw.map_pos) then
                if unexcluded == nil then
                    str = str .. "✞"
                else
                    str = str .. (unexcluded and "@" or "7")
                end
            elseif positions_equal(pos, map_center) then
                if unexcluded == nil then
                    str = str .. "W"
                else
                    str = str .. (unexcluded and "&" or "8")
                end
            elseif unexcluded == nil then
                str = str .. " "
            else
                str = str .. (unexcluded and "." or "#")
            end
        end
        note_decision("MAP", str)
    end

    crawl.setopt("msg_condense_repeats = true")
end

function print_adjacent_floor_map(center)
    if not center then
        center = const.origin
    end

    crawl.setopt("msg_condense_repeats = false")

    local map_center = position_sum(qw.map_pos, center)
    note_decision("MAP", "Adjacent floor map at " .. cell_string_from_map_position(map_center))
    -- This needs to iterate by row then column for display purposes.
    for y = -20, 20 do
        local str = ""
        for x = -20, 20 do
            local pos = position_sum(map_center, { x = x, y = y })
            local floor_count = adjacent_floor_map[pos.x][pos.y]
            local char
            if positions_equal(pos, qw.map_pos) then
                if floor_count == nil then
                    str = str .. "✞"
                else
                    str = str .. (floor_count <= 3 and "@" or "7")
                end
            elseif positions_equal(pos, map_center) then
                if floor_count == nil then
                    str = str .. "W"
                else
                    str = str .. (floor_count <= 3 and "&" or "8")
                end
            elseif floor_count == nil then
                str = str .. " "
            else
                str = str .. floor_count
            end
        end
        note_decision("MAP", str)
    end

    crawl.setopt("msg_condense_repeats = true")
end

function print_distance_map(dist_map, center, excluded)
    if not center then
        center = const.origin
    end

    crawl.setopt("msg_condense_repeats = false")

    local map = excluded and dist_map.excluded_map or dist_map.map
    local map_center = position_sum(qw.map_pos, center)
    note_decision("MAP", "Distance map at " .. cell_string_from_map_position(dist_map.pos)
        .. " from position " .. cell_string_from_map_position(map_center))
    -- This needs to iterate by row then column for display purposes.
    for y = -20, 20 do
        local str = ""
        for x = -20, 20 do
            local pos = position_sum(map_center, { x = x, y = y })
            local dist = map[pos.x][pos.y]
            if positions_equal(pos, qw.map_pos) then
                if dist == nil then
                    str = str .. "✞"
                else
                    str = str .. (dist > 180 and "7" or "@")
                end
            elseif positions_equal(pos, map_center) then
                if dist == nil then
                    str = str .. "W"
                else
                    str = str .. (dist > 180 and "8" or "&")
                end
            else
                if dist == nil then
                    str = str .. " "
                elseif dist > 180 then
                    str = str .. "∞"
                elseif dist > 61 then
                    str = str .. "Ø"
                else
                    str = str .. string.char(string.byte('A') + dist)
                end
            end
        end
        note_decision("MAP", str)
    end

    crawl.setopt("msg_condense_repeats = true")
end

function print_distance_maps(center, excluded)
    if not center then
        center = const.origin
    end

    for _, dist_map in pairs(distance_maps) do
        print_distance_map(dist_map, center, excluded)
    end
end

function set_counter()
    crawl.formatted_mpr("Set game counter to what? ", "prompt")
    local res = crawl.c_input_line()
    c_persist.record.counter = tonumber(res)
    note_decision("COUNTER", "Game counter set to " .. c_persist.record.counter)
end

function override_goal(goal)
    debug_goal = goal
    update_goal()
end

function get_vars()
    return qw, const
end

function pos_string(pos)
    return tostring(pos.x) .. "," .. tostring(pos.y)
end

function los_pos_string(map_pos)
    return pos_string(position_difference(map_pos, qw.map_pos))
end

function cell_string(cell)
    local str = pos_string(cell.los_pos) .. " ("
    if supdist(cell.los_pos) <= qw.los_radius then
        local mons = monster.get_monster_at(cell.los_pos.x, cell.los_pos.y)
        if mons then
            str = str .. mons:name() .. "; "
        end
    end

    return str .. cell.feat .. ")"
end

function cell_string_from_position(pos)
    return cell_string(cell_from_position(pos))
end

function cell_string_from_map_position(pos)
    return cell_string_from_position(position_difference(pos, qw.map_pos))
end

function monster_string(mons, props)
    if not props then
        props = { move_delay = "move delay", reach_range = "reach",
            is_ranged = "ranged" }
    end

    local vals = {}
    for prop, name in pairs(props) do
        table.insert(vals, name .. ":" .. tostring(mons[prop](mons)))
    end
    return mons:name() .. " (" .. table.concat(vals, "/") .. ") at "
        .. pos_string(mons:pos())
end

function toggle_throttle()
    qw.coroutine_throttle = not qw.coroutine_throttle
    note_decision("DEBUG", (qw.coroutine_throttle and "Enabling" or "Disabling")
      .. " coroutine throttle")
end

function toggle_delay()
    qw.delayed = not qw.delayed
    note_decision("DEBUG", (qw.delayed and "Enabling" or "Disabling") .. " action delay")
end

function reset_coroutine()
    qw.update_coroutine = nil
    collectgarbage("collect")
end

function resume_qw()
    qw.abort = false
end

function toggle_single_step()
    qw.single_step = not qw.single_step
    note_decision("DEBUG", (qw.single_step and "Enabling" or "Disabling")
      .. " single action steps.")
end

function qw.stringify(x)
    local t = type(x)
    if t == "nil" then
        return "nil"
    elseif t == "number" or t == "function" then
        return tostring(x)
    elseif t == "string" then
        return x
    elseif t == "boolean" then
        return x and "true" or "false"
    elseif x.name then
        return item_string(x)
    end
end

function qw.stringify_table(tab, indent_level)
    if not indent_level then
        indent_level = 0
    end

    local spaces = ""
    for i = 1, 2 * indent_level + 1 do
        spaces = spaces .. " "
    end

    if type(tab.pos) == "function" then
        return spaces .. "{ " .. cell_string_from_position(tab:pos()) .. " }"
    end

    local res = spaces .. "{\n"
    for key, val in pairs(tab) do
        res = res .. spaces .. " [" .. qw.stringify(key) .. "] ="
        if type(val) ~= "table" then
            res = res .. " " .. qw.stringify(val) .. ",\n"
        elseif next(val) == nil then -- table is empty
            res = res .. " { },\n"
        else
            res = res .. "\n" .. qw.stringify_table(val, indent_level + 1) .. ",\n"
        end
    end
    res = res .. spaces .. "}"
    return res
end
