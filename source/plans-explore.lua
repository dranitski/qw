------------------
-- The exploration plan cascades.

function plan_move_towards_safety()
    if autoexplored_level(where_branch, where_depth)
            or disable_autoexplore
            or qw.position_is_safe
            or unable_to_move()
            or dangerous_to_move()
            or you.mesmerised() then
        return false
    end

    local result = best_move_towards_safety()
    if result then
        if debug_channel("move") then
            note_decision("EXPLORE", "Moving to safe position at "
                .. cell_string_from_map_position(result.dest))
        end
        return move_towards_destination(result.move, result.dest, "safety")
    end

    return false
end

function plan_autoexplore()
    if unable_to_travel()
            or disable_autoexplore
            or free_inventory_slots() == 0
            or (c_persist.autoexplore[where]
                and c_persist.autoexplore[where]
                    > const.autoexplore.needed) then
        qw.autoexplore_turn = nil
        return false
    end

    -- Detect stuck autoexplore: if we've been autoexploring the same level
    -- for too many turns without the state being set by c_message, the level
    -- likely has unreachable areas. Mark it as partially explored.
    if not qw.autoexplore_turn then
        qw.autoexplore_turn = you.turns()
        qw.autoexplore_where = where
    elseif where ~= qw.autoexplore_where then
        qw.autoexplore_turn = you.turns()
        qw.autoexplore_where = where
    elseif you.turns() - qw.autoexplore_turn > 1000 then
        note_decision("AUTOEXPLORE", "Stuck exploring " .. where
            .. " for " .. (you.turns() - qw.autoexplore_turn)
            .. " turns, marking as partial")
        c_persist.autoexplore[where] = const.autoexplore.partial
        qw.want_goal_update = true
        qw.autoexplore_turn = nil
        return false
    end

    magic("o", "autoexplore")
    return true
end

function send_travel(branch, depth)
    local depth_str
    if depth == nil or branch_depth(branch) == 1 then
        depth_str = ""
    else
        depth_str = depth
    end

    magic("G" .. branch_travel(branch) .. depth_str .. "\rY", "travel")
end

function unable_to_travel()
    return qw.danger_in_los or qw.position_is_cloudy or unable_to_move()
end

function plan_go_to_portal_entrance()
    if unable_to_travel()
            or in_portal()
            or not is_portal_branch(goal_branch)
            or not branch_found(goal_branch) then
        return false
    end

    local desc = portal_entrance_description(goal_branch)
    -- For timed bazaars, make a search string that can' match permanent
    -- ones.
    if goal_branch == "Bazaar" and not permanent_bazaar then
        desc = "a flickering " .. desc
    end
    magicfind(desc)
    return true
end

-- Use the 'G' command to travel to our next destination.

function plan_go_command()
    if unable_to_travel() or not goal_travel.want_go then
        qw.go_fails = 0
        return false
    end

    -- Track repeated failures: if G-travel doesn't change our level after
    -- multiple attempts, the destination is unreachable from here. Return
    -- false to let the stuck cascade run (random steps, escape hatches).
    if not qw.go_fails then
        qw.go_fails = 0
    end
    if qw.go_last_where and qw.go_last_where == where then
        qw.go_fails = qw.go_fails + 1
    else
        qw.go_fails = 0
        qw.go_last_where = where
    end

    if qw.go_fails > 10 then
        -- G-travel can't reach the destination from here. Try to manually
        -- navigate to stairs in the travel direction to make progress.
        local dir = goal_travel.first_dir
        if not dir then
            -- Default: go down (most goals are deeper levels).
            dir = const.dir.down
        end
        -- Can't G-travel to the destination. Run autoexplore on the current
        -- level to find/take stairs. DCSS autoexplore will move the bot
        -- towards unexplored areas or stairs it hasn't taken yet.
        note_decision("GO-TRAVEL", "G-travel to "
            .. make_level(goal_travel.branch, goal_travel.depth)
            .. " failed from " .. where .. ", using autoexplore fallback")
        qw.go_fails = 0
        magic("o", "autoexplore")
        return true
    end

    -- We can't set goal_travel data to an invalid level like D:0, so we set it
    -- to D:1 and override it in this plan.
    if goal_status == "Escape"
            and goal_travel.branch == "D"
            and goal_travel.depth == 1 then
        -- We're already on the stairs, so travel won't take us further.
        if view.feature_at(0, 0) == branch_exit("D") then
            go_upstairs(true)
        else
            send_travel("D", 0)
        end
    else
        send_travel(goal_travel.branch, goal_travel.depth)
    end
    return true
end

function plan_go_to_portal_exit()
    -- Zig has its own stair handling in plan_zig_go_to_stairs().
    if unable_to_travel() or not in_portal() or where_branch == "Zig" then
        qw.portal_exit_fails = 0
        return false
    end

    -- Some portal exits (e.g. exit_gauntlet) aren't found by X< map search.
    -- After a few failures, walk towards the exit feature directly.
    if not qw.portal_exit_fails then
        qw.portal_exit_fails = 0
    end
    if qw.portal_exit_fails > 3 then
        local exit_feat = branch_exit(where_branch)
        if exit_feat then
            local result = best_move_towards_features({ exit_feat }, true)
            if result then
                return move_towards_destination(result.move, result.dest,
                    "goal")
            end
        end
        -- X< failed and no path to exit feature — give up so stuck
        -- cascade can take over with random steps / escape hatches.
        return false
    end

    qw.portal_exit_fails = qw.portal_exit_fails + 1
    magic("X<\r", "map_search")
    return true
end

-- Open runed doors in Pan to get to the pan lord vault and open them on levels
-- that are known to contain entrances to Pan if we intend to visit Pan.
function plan_open_runed_doors()
    if not open_runed_doors then
        return false
    end

    for pos in adjacent_iter(const.origin) do
        if view.feature_at(pos.x, pos.y) == "runed_clear_door" then
            magic(delta_to_vi(pos) .. "Y", "movement")
            return true
        end
    end
    return false
end

function plan_enter_portal()
    if not is_portal_branch(goal_branch)
            or view.feature_at(0, 0) ~= branch_entrance(goal_branch)
            or unable_to_use_stairs() then
        return false
    end

    go_downstairs(goal_branch == "Zig", true)
    return true
end

function plan_exit_portal()
    if not in_portal()
            -- Zigs have their own exit rules.
            or where_branch == "Zig"
            or view.feature_at(0, 0) ~= branch_exit(where_branch)
            or unable_to_use_stairs() then
        return false
    end

    local parent, depth = parent_branch(where_branch)
    remove_portal(make_level(parent, depth), where_branch, true)

    go_upstairs()
    return true
end

function want_rune_on_current_level()
    return not have_branch_runes(where_branch)
            and where_branch == goal_branch
            and where_depth == goal_depth
            and goal_depth == branch_rune_depth(goal_branch)
end

function plan_pick_up_rune()
    if not want_rune_on_current_level() then
        return false
    end

    local runes = branch_runes(where_branch, true)
    local rune_positions = get_item_map_positions(runes)
    if not rune_positions
            or not positions_equal(qw.map_pos, rune_positions[1]) then
        return false
    end

    magic(",", "pickup")
    return true
end

function plan_move_towards_rune()
    if not want_rune_on_current_level()
            or you.confused()
            or unable_to_move()
            or dangerous_to_move() then
        return false
    end

    local runes = branch_runes(where_branch, true)
    local rune_positions = get_item_map_positions(runes)
    if not rune_positions then
        return false
    end

    local result = best_move_towards_positions(rune_positions, true)
    if result then
        return move_towards_destination(result.move, result.dest, "goal")
    end

    return false
end

function plan_move_towards_travel_feature()
    if unable_to_move() or dangerous_to_move()
 then
        return false
    end

    if goal_travel.safe_hatch and not goal_travel.want_go then
        local map_pos = unhash_position(goal_travel.safe_hatch)
        local result = best_move_towards(map_pos)
        if result then
            return move_towards_destination(result.move, result.des, "goal")
        end

        return false
    end

    local feats = goal_travel_features()
    if not feats then
        return false
    end

    if util.contains(feats, view.feature_at(0, 0)) then
        return false
    end

    local result = best_move_towards_features(feats, true)
    if result then
        return move_towards_destination(result.move, result.dest, "goal")
    end

    local god = goal_god(goal_status)
    if not god then
        return false
    end

    if c_persist.altars[god] and c_persist.altars[god][where] then
        for hash, _ in pairs(c_persist.altars[god][where]) do
            if update_altar(god, where, hash, { feat = const.explore.seen },
                    true) then
                qw.restart_cascade = true
            end
        end
    end

    -- If we're restarting the cascade, we have to do the goal update ourself
    -- to ensure earlier plans have current goal information.
    if qw.restart_cascade and qw.want_goal_update then
        update_goal()
    end

    return false
end

function plan_move_towards_destination()
    if not qw.move_destination or unable_to_move() or dangerous_to_move() then
        return false
    end

    -- Detect stuck movement: if we've been heading to the same destination
    -- for too many turns without arriving, give up so other plans can run.
    if not qw.move_dest_start_turn then
        qw.move_dest_start_turn = you.turns()
    end
    if you.turns() - qw.move_dest_start_turn > 200 then
        qw_assert(false, "destination unreachable after 200 turns at "
            .. cell_string_from_map_position(qw.move_destination)
            .. " (reason: " .. tostring(qw.move_reason) .. ")")
    end

    result = best_move_towards(qw.move_destination, qw.map_pos, true)
    if result then
        return move_to(result.move)
    end

    return false
end

function plan_move_towards_monster()
    if not qw.position_is_safe or unable_to_move() or dangerous_to_move() then
        return false
    end

    local mons_targets = {}
    for _, enemy in ipairs(qw.enemy_list) do
        table.insert(mons_targets, position_sum(qw.map_pos, enemy:pos()))
    end

    if #mons_targets == 0 then
        for pos in square_iter(const.origin, qw.los_radius) do
            local mons = monster.get_monster_at(pos.x, pos.y)
            if mons and Monster:new(mons):is_enemy() then
                table.insert(mons_targets, position_sum(qw.map_pos, pos))
            end
        end
    end

    if #mons_targets == 0 then
        return false
    end

    local result = best_move_towards_positions(mons_targets)
    if result then
        if debug_channel("move") then
            note_decision("EXPLORE", "Moving to enemy at "
                .. cell_string_from_map_position(result.dest))
        end
        return move_towards_destination(result.move, result.dest, "monster")
    end

    return false
end

function plan_move_towards_unexplored()
    if disable_autoexplore or unable_to_move() or dangerous_to_move() then
        return false
    end

    local result = best_move_towards_unexplored()
    if result then
        if debug_channel("move") then
            note_decision("EXPLORE", "Moving to explore near safe position at "
                .. cell_string_from_map_position(result.dest))
        end
        return move_towards_destination(result.move, result.dest, "unexplored")
    end

    local result = best_move_towards_unexplored(true)
    if result then
        if debug_channel("move") then
            note_decision("EXPLORE", "Moving to explore near unsafe position at "
                .. cell_string_from_map_position(result.dest))
        end

        return move_towards_destination(result.move, result.dest, "unexplored")
    end

    return false
end

function plan_tomb_use_hatch()
    if (where == "Tomb:2" and not have_branch_runes("Tomb")
                or where == "Tomb:1")
            and view.feature_at(0, 0) == "escape_hatch_down" then
        prev_hatch_dist = 1000
        go_downstairs()
        return true
    end

    if (where == "Tomb:3" and have_branch_runes("Tomb")
                or where == "Tomb:2")
            and view.feature_at(0, 0) == "escape_hatch_up" then
        prev_hatch_dist = 1000
        go_upstairs()
        return true
    end

    return false
end

function plan_tomb_go_to_final_hatch()
    if where == "Tomb:2"
            and not have_branch_runes("Tomb")
            and view.feature_at(0, 0) ~= "escape_hatch_down" then
        magic("X>\r", "map_search")
        return true
    end
    return false
end

function plan_tomb_go_to_hatch()
    if where == "Tomb:3"
            and have_branch_runes("Tomb")
            and view.feature_at(0, 0) ~= "escape_hatch_up" then
        magic("X<\r", "map_search")
        return true
    elseif where == "Tomb:2" then
        if not have_branch_runes("Tomb")
                and view.feature_at(0, 0) == "escape_hatch_down" then
            return false
        end

        if view.feature_at(0, 0) == "escape_hatch_up" then
            local new_hatch_dist = supdist(qw.map_pos)
            if new_hatch_dist >= prev_hatch_dist
                    and not positions_equal(qw.map_pos, prev_hatch) then
                return false
            end

            prev_hatch_dist = new_hatch_dist
            prev_hatch = util.copy_table(qw.map_pos)
        end

        magic("X<\r", "map_search")
        return true
    elseif where == "Tomb:1" then
        if view.feature_at(0, 0) == "escape_hatch_down" then
            local new_hatch_dist = supdist(qw.map_pos)
            if new_hatch_dist >= prev_hatch_dist
                    and not positions_equal(qw.map_pos, prev_hatch) then
                return false
            end

            prev_hatch_dist = new_hatch_dist
            prev_hatch = util.copy_table(qw.map_pos)
        end

        magic("X>\r", "map_search")
        return true
    end

    return false
end


-- Returns true if the current level has a timed portal the bot wants to
-- enter. In that case we skip the shout routine to prioritize the portal.
function level_has_timed_portal()
    if not c_persist.portals or not c_persist.portals[where] then
        return false
    end

    for portal, turns_list in pairs(c_persist.portals[where]) do
        if portal_allowed(portal) then
            for _, turns in ipairs(turns_list) do
                if turns ~= const.inf_turns then
                    return true
                end
            end
        end
    end
    return false
end

function get_stair_shout(level)
    -- Use c_persist so shout state survives save/restore.
    if not c_persist.stair_shout then
        c_persist.stair_shout = {}
    end
    -- Merge: local state takes priority (for current session phase tracking),
    -- but c_persist.done flag persists across saves.
    if not stair_shout[level] then
        local persisted = c_persist.stair_shout[level] or {}
        stair_shout[level] = {
            shouted = persisted.shouted or {},
            parent_used = persisted.parent_used or {},
            count = persisted.count or 0,
            phase = nil,
            shout_turn = 0,
            done = persisted.done or false,
        }
    end
    return stair_shout[level]
end

-- Save shout state to c_persist when a level is fully shout-cleared.
function persist_stair_shout(level, state)
    if not c_persist.stair_shout then
        c_persist.stair_shout = {}
    end
    c_persist.stair_shout[level] = {
        shouted = state.shouted,
        parent_used = state.parent_used,
        count = state.count,
        done = state.done,
    }
end

-- Return true if the shout-clear routine should run on this level.
function shout_clear_wanted()
    return qw.can_flee_upstairs
        and not in_portal()
        and not branch_is_temporary(where_branch)
        and not level_has_timed_portal()
        and not in_branch("Temple")
end

function shout_max_stairs()
    if in_branch("Depths") or in_branch("Zot")
            or (in_branch("Vaults") and at_branch_end("Vaults")) then
        return 6
    end
    return 3
end

-- Find a downstair on the CURRENT level (the parent) that hasn't been
-- used for shout-clearing the level below. The state tracks used
-- downstairs by position hash. We call find_features directly to
-- ensure the map is scanned for downstairs on this turn.
function find_unused_downstair(state)
    local positions, feats = find_features(const.downstairs)
    if not positions or #positions == 0 then
        return nil
    end
    -- Use feature name (e.g. "stone_stairs_down_ii") as stable key
    -- instead of position hash, which shifts when qw.map_pos changes.
    for i, pos in ipairs(positions) do
        if not state.parent_used[feats[i]] then
            return pos, feats[i]
        end
    end
    return nil
end

function plan_shout_at_stairs()
    if not shout_clear_wanted() then
        return false
    end

    -- Only shout-clear when the goal is to explore this specific level,
    -- not when passing through to a deeper destination. This prevents
    -- the bot from starting a shout cycle on every transit level.
    if goal_branch ~= where_branch or goal_depth ~= where_depth then
        return false
    end

    local state = get_stair_shout(where)
    if state.done then
        return false
    end

    local max_shouts = shout_max_stairs()

    -- Safety valve: if shout-clear started but has taken too long
    -- (e.g. stuck cycling), give up.
    if state.start_turn and you.turns() - state.start_turn > 300 then
        state.done = true
        persist_stair_shout(where, state)
        note_decision("SHOUT", "Shout-clear timeout for " .. where
            .. " after " .. (you.turns() - state.start_turn) .. " turns"
            .. " (" .. state.count .. " stairs)")
        return false
    end

    if state.count >= max_shouts then
        state.done = true
        persist_stair_shout(where, state)
        note_decision("SHOUT", "Shout-clear complete for " .. where
            .. " (" .. state.count .. " stairs)")
        note_decision("SHOUT", "Shout-clear complete for " .. where)
        return false
    end

    -- Must be standing on an upstair to shout.
    local feat = view.feature_at(0, 0)
    if not feature_is_upstairs(feat) then
        if state.phase then
            state.phase = nil
        end
        return false
    end

    -- If enemies are already visible (e.g. we just descended), don't
    -- shout - let combat handle them. Log what we see.
    if qw.danger_in_los then
        local names = {}
        for _, enemy in ipairs(qw.enemy_list) do
            table.insert(names, enemy:name())
        end
        local mons_str = #names > 0 and table.concat(names, ", ")
            or "unknown"
        local pos_hash = hash_position(qw.map_pos)

        if state.phase == "shout" or state.phase == "wait" then
            local waited = you.turns() - state.shout_turn
            note_decision("SHOUT-ATTRACT", where
                .. " stair " .. state.count + 1 .. "/" .. max_shouts
                .. " after " .. waited .. "t: " .. mons_str)
            state.shouted[pos_hash] = true
            state.count = state.count + 1
            state.phase = nil
        elseif not state.phase and not state.shouted[pos_hash] then
            -- Enemies already present when we arrived - no need to shout.
            note_decision("SHOUT-ALREADY", where
                .. " stair " .. state.count + 1 .. "/" .. max_shouts
                .. " monsters already present: " .. mons_str)
            state.shouted[pos_hash] = true
            state.count = state.count + 1
        end
        return false
    end

    local pos_hash = hash_position(qw.map_pos)

    -- Already shouted from this specific stair.
    if state.shouted[pos_hash] then
        if state.count < max_shouts then
            note_decision("SHOUT", "Skipping already-shouted stair on "
                .. where .. " (" .. state.count .. "/" .. max_shouts
                .. " done)")
        end
        return false
    end

    -- Phase 1: shout to attract nearby monsters.
    if not state.phase then
        state.phase = "shout"
        state.shout_turn = you.turns()
        if not state.start_turn then
            state.start_turn = you.turns()
        end
        note_decision("SHOUT", "Shouting at stairs on " .. where
            .. " (shout " .. (state.count + 1) .. "/" .. max_shouts .. ")")
        note_decision("SHOUT", "SHOUTING at stairs!")
        magic("tt", "ability")
        return true
    end

    -- Phase 2: wait up to 20 turns for monsters to arrive.
    if state.phase == "shout" or state.phase == "wait" then
        state.phase = "wait"
        if you.turns() < state.shout_turn + 20 then
            wait_one_turn(true)
            return true
        end

        -- Wait done with no monsters attracted.
        state.shouted[pos_hash] = true
        state.count = state.count + 1
        state.phase = "ascending"
        note_decision("SHOUT-ATTRACT", where
            .. " stair " .. state.count .. "/" .. max_shouts
            .. " after 20t: nothing")
        note_decision("SHOUT", "Ascending to re-enter via next stair")
        note_decision("SHOUT", "Shout done, going up to try next stair")
        -- Clear any pending movement destination so
        -- plan_move_towards_destination doesn't bypass the shout system.
        qw.move_destination = nil
        qw.move_reason = nil
        qw.move_dest_start_turn = nil
        go_upstairs()
        return true
    end

    return false
end

-- When on the PARENT level and shout-clear for the level BELOW isn't
-- done, navigate to an unused downstair so we enter via a new position.
-- This runs after plan_shout_at_stairs in the explore cascade.
function plan_go_to_shout_stair()
    -- Don't act in portals/temporary branches.
    if in_portal() or branch_is_temporary(where_branch) then
        return false
    end

    if not goal_branch or not goal_depth then
        return false
    end

    -- Case 1: On the TARGET level, navigate to an unshouted upstair
    -- (e.g. bot was bumped off stair during combat).
    if where_branch == goal_branch and where_depth == goal_depth
            and shout_clear_wanted() then
        local state = get_stair_shout(where)
        if state.done or state.count >= shout_max_stairs() then
            return false
        end
        if qw.danger_in_los or unable_to_move() or dangerous_to_move() then
            return false
        end
        local positions = find_features(const.upstairs)
        if not positions or #positions == 0 then
            return false
        end
        local target_pos
        for _, pos in ipairs(positions) do
            if not state.shouted[hash_position(pos)] then
                target_pos = pos
                break
            end
        end
        if not target_pos then
            state.done = true
            persist_stair_shout(where, state)
            return false
        end
        if positions_equal(qw.map_pos, target_pos) then
            return false
        end
        -- Use waypoint autotravel to reach the upstair quickly.
        local rel = position_difference(target_pos, qw.map_pos)
        travel.set_waypoint(9, rel.x, rel.y)
        magic("G*9\r", "travel")
        return true
    end

    -- Case 2: On the PARENT level, navigate to an unused downstair.
    if where_branch ~= goal_branch or where_depth ~= goal_depth - 1 then
        return false
    end

    local target_level = make_level(goal_branch, goal_depth)
    local state = get_stair_shout(target_level)
    if state.done then
        return false
    end
    if state.count >= shout_max_stairs() then
        state.done = true
        persist_stair_shout(target_level, state)
        return false
    end

    -- Clear ascending phase when back on the parent level.
    if state.phase == "ascending" then
        state.phase = nil
    end

    if qw.danger_in_los or unable_to_move() or dangerous_to_move() then
        return false
    end

    local next_down, next_feat = find_unused_downstair(state)
    if not next_down then
        -- All downstairs used or none found. Mark target done.
        state.done = true
        persist_stair_shout(target_level, state)
        note_decision("SHOUT", "Shout-clear complete for " .. target_level
            .. " (" .. state.count .. " stairs, from " .. where .. ")")
        return false
    end

    note_decision("SHOUT-NAV", "Navigating to downstair for "
        .. target_level .. " at "
        .. cell_string_from_map_position(next_down)
        .. " (" .. tostring(next_feat) .. ")"
        .. " count=" .. state.count .. " done=" .. tostring(state.done))

    -- If standing on the unused downstair, take it.
    if positions_equal(qw.map_pos, next_down) then
        -- Mark by feature name (stable across position shifts).
        state.parent_used[next_feat] = true
        note_decision("SHOUT", "Taking downstair to " .. target_level
            .. " for shout " .. (state.count + 1) .. "/" .. shout_max_stairs()
            .. " via " .. view.feature_at(0, 0))
        go_downstairs()
        return true
    end

    -- Use a waypoint + autotravel to reach the downstair quickly.
    -- Waypoint 9 is reserved for shout stair navigation.
    local rel = position_difference(next_down, qw.map_pos)
    travel.set_waypoint(9, rel.x, rel.y)
    magic("G*9\r", "travel")
    return true
end

function set_plan_pre_explore()
    plans.pre_explore = cascade {
        {plan_ancestor_life, "ancestor_life"},
        {plan_sacrifice, "sacrifice"},
        {plans.acquirement, "acquirement"},
        {plan_bless_weapon, "bless_weapon"},
        {plan_remove_shield, "remove_shield"},
        {plan_upgrade_weapon, "upgrade_weapon"},
        {plan_wear_shield, "wear_shield"},
        {plan_use_identify_scrolls, "use_identify_scrolls"},
        {plan_upgrade_equipment, "upgrade_equipment"},
        {plan_remove_equipment, "remove_equipment"},
        {plan_use_good_consumables, "use_good_consumables"},
        {plan_unwield_weapon, "unwield_weapon"},
    }
end

function set_plan_explore()
    plans.explore = cascade {
        {plan_dive_pan, "dive_pan"},
        {plan_dive_go_to_pan_downstairs, "try_dive_go_to_pan_downstairs"},
        {plan_move_towards_destination, "move_towards_destination"},
        {plan_take_escape_hatch, "take_escape_hatch"},
        {plan_move_towards_escape_hatch, "try_go_to_escape_hatch"},
        {plan_shout_at_stairs, "shout_at_stairs"},
        {plan_go_to_shout_stair, "try_go_to_shout_stair"},
        {plan_move_towards_safety, "move_towards_safety"},
        {plan_autoexplore, "try_autoexplore"},
    }
end

function set_plan_pre_explore2()
    plans.pre_explore2 = cascade {
        {plan_read_unided_scrolls, "try_read_unided_scrolls"},
        {plan_quaff_unided_potions, "quaff_unided_potions"},
        {plan_drop_items, "drop_items"},
        {plan_full_inventory_panic, "full_inventory_panic"},
    }
end

function set_plan_explore2()
    plans.explore2 = cascade {
        {plan_abandon_god, "abandon_god"},
        {plan_use_altar, "use_altar"},
        {plan_go_to_altar, "try_go_to_altar"},
        {plan_enter_portal, "enter_portal"},
        {plan_go_to_portal_entrance, "try_go_to_portal_entrance"},
        {plan_open_runed_doors, "open_runed_doors"},
        {plan_enter_transporter, "enter_transporter"},
        {plan_transporter_orient_exit, "try_transporter_orient_exit"},
        {plan_go_to_transporter, "try_go_to_transporter"},
        {plan_exit_portal, "exit_portal"},
        {plan_go_to_portal_exit, "try_go_to_portal_exit"},
        {plan_visit_shop, "try_visit_shop"},
        {plan_shopping_spree, "try_shopping_spree"},
        {plan_tomb_go_to_final_hatch, "try_tomb_go_to_final_hatch"},
        {plan_tomb_go_to_hatch, "try_tomb_go_to_hatch"},
        {plan_tomb_use_hatch, "tomb_use_hatch"},
        {plan_enter_pan, "enter_pan"},
        {plan_go_to_pan_portal, "try_go_to_pan_portal"},
        {plan_exit_pan, "exit_pan"},
        {plan_go_to_pan_exit, "try_go_to_pan_exit"},
        {plan_go_down_pan, "try_go_down_pan"},
        {plan_go_to_pan_downstairs, "try_go_to_pan_downstairs"},
        {plan_enter_abyss, "enter_abyss"},
        {plan_go_to_abyss_portal, "try_go_to_abyss_portal"},
        {plan_move_to_zigfig_location, "try_move_to_zigfig_location"},
        {plan_use_zigfig, "use_zigfig"},
        {plan_zig_dig, "zig_dig"},
        {plan_go_to_zig_dig, "try_go_to_zig_dig"},
        {plan_zig_leave_level, "zig_leave_level"},
        {plan_zig_go_to_stairs, "try_zig_go_to_stairs"},
        {plan_take_unexplored_stairs, "take_unexplored_stairs"},
        {plan_go_to_unexplored_stairs, "try_go_to_unexplored_stairs"},
        {plan_move_towards_rune, "move_towards_rune"},
        {plan_go_to_orb, "try_go_to_orb"},
        {plan_berserk_dangerous_stairs, "berserk_dangerous_stairs"},
        {plan_go_to_shout_stair, "try_go_to_shout_stair2"},
        {plan_go_command, "try_go_command"},
        {plan_teleport_dangerous_stairs, "teleport_dangerous_stairs"},
        {plan_use_travel_stairs, "use_travel_stairs"},
        {plan_move_towards_travel_feature, "move_towards_travel_feature"},
        {plan_autoexplore, "try_autoexplore2"},
        {plan_move_towards_monster, "move_towards_monster"},
        {plan_move_towards_unexplored, "move_towards_unexplored"},
        {plan_unexplored_stairs_backtrack, "try_unexplored_stairs_backtrack"},
        {plan_abort_safe_stairs, "try_abort_safe_stairs"},
    }
end
