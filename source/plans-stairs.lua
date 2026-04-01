----------------------
-- Stair-related plans

function go_upstairs(confirm)
    magic("<" .. (confirm and "Y" or ""), "stairs")
end

function go_downstairs(confirm)
    magic(">" .. (confirm and "Y" or ""), "stairs")
end

function plan_go_to_unexplored_stairs()
    if unable_to_travel()
            or goal_travel.want_go
            or not goal_travel.stairs_dir
 then
        return false
    end

    if map_mode_search_attempts == 1 then
        map_mode_search_attempts = 0
        disable_autoexplore = false
        return false
    end

    local key = dir_key(goal_travel.stairs_dir)
    local hash = hash_position(qw.map_pos)
    local searches = map_mode_searches[key]
    local count = 1
    while searches and searches[hash] and searches[hash][count] do
        -- Trying to go one past this count lands us at the same destination as
        -- the count, so there are no more accessible unexplored stairs to be
        -- found from where we are, and we stop the search. The backtrack plan
        -- can take over from here.
        if searches[hash][count] == searches[hash][count + 1] then
            return false
        end

        count = count + 1
    end

    map_mode_search_key = key
    map_mode_search_hash = hash
    map_mode_search_count = count
    map_mode_search_attempts = 1
    magic("X" .. key:rep(count) .. "\r", "map_search")
    return true
end

function plan_go_to_transporter()
    if unable_to_travel()
            or not want_to_use_transporters()
            or transp_search then
        qw.transp_search_fails = 0
        return false
    end

    -- If transporter map search has been failing, stop trying so
    -- plan_go_to_portal_exit can run instead. The counter persists
    -- across turns (not reset by action_fails) because random_step
    -- advances the turn but doesn't fix the transporter search.
    if not qw.transp_search_fails then
        qw.transp_search_fails = 0
    end
    if qw.transp_search_fails > 5 then
        return false
    end

    local search_count
    if in_branch("Gauntlet") then
        -- Maps can have functionally different types of transporter routes and
        -- always start the player closest to a route of one type, so randomize
        -- which of the starting transporters we choose. No Gauntlet map has
        -- more than 3 starting transporters, and most have two, so use '>' 1
        -- to 4 times to reduce bias.
        if transp_zone == 0 then
            search_count = crawl.roll_dice(1, 4)
        -- After the first transporter, always take the closest one. This is
        -- important for gammafunk_gauntlet_77_escape_option so we don't take
        -- the early exit after each portal.
        else
            search_count = 1
        end
    else
        search_count = 1
        while transp_map[transp_zone]
                and transp_map[transp_zone][search_count] do
            search_count = search_count + 1
        end
    end

    transp_search_zone = transp_zone
    transp_search_count = search_count
    qw.transp_search_fails = qw.transp_search_fails + 1
    magic("X" .. (">"):rep(search_count) .. "\r", "map_search")
    return true
end

function plan_transporter_orient_exit()
    if unable_to_move() or not transp_orient then
        return false
    end

    magic("X<\r", "map_search")
    return true
end

function unable_to_use_transporters()
    return unable_to_move() or you.mesmerised()
end

function plan_enter_transporter()
    if not transp_search
            or view.feature_at(0, 0) ~= "transporter"
            or unable_to_use_transporters() then
        return false
    end

    magic(">", "stairs")
    return true
end

function plan_take_unexplored_stairs()
    if not goal_travel.stairs_dir or unable_to_use_stairs()
 then
        return false
    end

    local feat = view.feature_at(0, 0)
    local dir, num = stone_stairs_type(feat)
    if not dir or dir ~= goal_travel.stairs_dir then
        return false
    end

    local state = get_stone_stairs(where_branch, where_depth, dir, num)
    if state.feat >= const.explore.explored then
        return false
    end

    -- Ensure that we autoexplore any new area we arrive in, but only if the
    -- level hasn't been fully explored yet. Resetting a full level causes
    -- autoexplore to immediately say "Done exploring" without advancing a
    -- turn.
    local dest_level = make_level(where_branch, where_depth + dir)
    if c_persist.autoexplore[dest_level] ~= const.autoexplore.full then
        reset_autoexplore(dest_level)
    end

    if dir == const.dir.up then
        go_upstairs()
    else
        go_downstairs()
    end
    return true
end

-- Backtrack to the previous level if we're trying to explore stairs on a
-- destination level yet have no further accessible unexplored stairs. We
-- require a travel stairs search direction to know whether to attempt this and
-- what direction we should backtrack. Stairs are reset in the relevant
-- directions on both levels so after we explore the pair of stairs used to
-- return to the previous level, we'll take a different set of stairs from that
-- level via a new travel stairs search direction.
function plan_unexplored_stairs_backtrack()
    if unable_to_travel() or goal_travel.want_go or not goal_travel.stairs_dir then
        return false
    end

    local next_depth = where_depth + goal_travel.stairs_dir
    reset_stone_stairs(where_branch, where_depth, goal_travel.stairs_dir)
    reset_stone_stairs(where_branch, next_depth, -goal_travel.stairs_dir)
    send_travel(where_branch, next_depth)
    return true
end

function plan_go_to_upstairs()
    magic("X<\r", "map_search")
    return true
end

function unable_to_use_stairs()
    return unable_to_move() or you.mesmerised()
end

function count_stair_followers(radius)
    return count_enemies(radius,
        function (mons)
            return mons:can_seek() and mons:can_use_stairs()
        end)
end

function want_to_stairdance_up()
    -- Assume we'd rather follow through with our teleport rather than take
    -- stairs.
    if you.teleporting() then
        return false
    end

    local feat = view.feature_at(0, 0)
    if not qw.can_flee_upstairs or not feature_is_upstairs(feat) then
        return false
    end

    if in_bad_form() then
        return true
    end

    local state = get_destination_stairs(where_branch, where_depth, feat)
    if state and not state.safe then
        return false
    end

    local n = stairdance_count[where] or 0
    if n >= 20 then
        return false
    end

    if you.caught()
            or you.constricted()
            or check_brothers_in_arms(3)
            or check_greater_servants(3)
            or check_divine_warriors(3) then
        return false
    end

    local only_when_safe = you.berserk() or hp_is_low(33)
    local follow_count = count_stair_followers(1)
    local other_count = #qw.enemy_list - follow_count
    if only_when_safe and follow_count > 0 then
        return false
    end

    -- We have no stair followers, so we're going up because we're either
    -- fleeing or we want to rest safely.
    if follow_count == 0 and want_to_flee()
            -- We have stair followers, but there are even more non-following
            -- monsters around, so we go up to fight the following monsters in
            -- probable safety.
            or other_count > 0 and follow_count > 0 then
        stairdance_count[where] = n + 1
        return true
    end

    return false
end

function plan_stairdance_up()
    if unable_to_use_stairs()
            or dangerous_to_move(true)
            or not want_to_stairdance_up() then
        return false
    end

    qw.stats.stairdances = qw.stats.stairdances + 1
    note_decision("STAIR", "STAIRDANCE")
    go_upstairs(you.status("spiked"))
    return true
end

function want_to_use_escape_hatches(dir)
    return dir == const.dir.up
        and goal_status == "Escape"
        and not branch_is_temporary(where_branch)
        and not in_branch("Tomb")
        and where_depth > 1
        -- It's dangerous to hatch through unexplored areas in Zot as opposed
        -- to simply taking an explored route through stone stairs. So we only
        -- take a hatch up in Zot if the destination level is fully explored.
        and (where_branch ~= "Zot"
            or explored_level(where_branch, where_depth - 1))
end

function plan_take_escape_hatch()
    local dir = escape_hatch_type(view.feature_at(0, 0))
    if not dir
            or not want_to_use_escape_hatches(dir)
            or unable_to_use_stairs() then
        return false
    end

    if dir == const.dir.up then
        go_upstairs()
    else
        go_downstairs()
    end

    return true
end

function plan_move_towards_escape_hatch()
    if not want_to_use_escape_hatches(const.dir.up)
            or unable_to_move()
            or dangerous_to_move() then
        return false
    end

    local result = best_move_towards_positions(qw.flee_positions, true)
    if not result then
        return false
    end

    -- The best flee position is not a hatch.
    if not c_persist.up_hatches[hash_position(result.dest)] then
        return false
    end

    return move_to(result.move)
end

function teleporting_before_dangerous_stairs()
    if goal_travel.want_go or not goal_travel.safe_stairs then
        return false
    end

    local feat = view.feature_at(0, 0)
    if feat ~= goal_travel.safe_stairs then
        return false
    end

    local state = get_destination_stairs(where_branch, where_depth, feat)
    local threat = 0
    if state then
        threat = state.threat
    elseif where_branch == "Vaults"
            and where_depth == branch_depth("Vaults") - 1 then
        threat = 25
    end
    return threat >= extreme_threat_level()
end

function plan_teleport_dangerous_stairs()
    if not can_teleport() or not teleporting_before_dangerous_stairs() then
        return false
    end

    return teleport()
end

-- Check if the next level down from the current level has recorded high
-- threat at any of its upstairs. Returns the maximum threat value, or 0.
function next_level_stair_threat()
    local dest_depth = where_depth + 1
    if dest_depth > branch_depth(where_branch) then
        return 0
    end

    local max_threat = 0
    local n = num_required_stairs(where_branch, dest_depth, const.dir.up)
    for i = 1, n do
        local num = ("i"):rep(i)
        local state = get_stone_stairs(where_branch, dest_depth,
            const.dir.up, num)
        if state and state.threat and state.threat > max_threat then
            max_threat = state.threat
        end
    end
    return max_threat
end

-- At low XL, berserk before descending stairs that have recorded high
-- threat. This prevents the cycle where the bot flees from a dangerous
-- enemy, returns via the goal system, and gets one-shot on arrival.
-- Berserking before descending gives +50% HP to absorb the stair-ambush
-- hit and enough damage to finish the fight.
-- Only triggers once per destination level to avoid berserk spam.
function plan_berserk_dangerous_stairs()
    if you.berserk() or you.xl() >= 7 then
        return false
    end

    if not goal_travel.want_go then
        return false
    end

    -- Only when about to go one level deeper.
    if not goal_travel.branch
            or goal_travel.branch ~= where_branch
            or goal_travel.depth ~= where_depth + 1 then
        return false
    end

    local dest = make_level(goal_travel.branch, goal_travel.depth)
    if qw.preberserk_levels and qw.preberserk_levels[dest] then
        return false
    end

    local threat = next_level_stair_threat()
    if threat < high_threat_level() then
        return false
    end

    if can_berserk() then
        note_decision("STAIR", "PRE-STAIRS BERSERK (threat=" .. threat .. ")")
        if not qw.preberserk_levels then
            qw.preberserk_levels = {}
        end
        qw.preberserk_levels[dest] = true
        return use_ability("Berserk")
    end

    -- If we can't berserk, at least use Trog's Hand for the regen buffer.
    if can_trogs_hand() and not you.regenerating() then
        note_decision("STAIR", "PRE-STAIRS TROG'S HAND (threat=" .. threat .. ")")
        if not qw.preberserk_levels then
            qw.preberserk_levels = {}
        end
        qw.preberserk_levels[dest] = true
        return use_ability("Trog's Hand")
    end

    return false
end

function plan_use_travel_stairs()
    if unable_to_use_stairs() or dangerous_to_move()
 then
        return false
    end

    local feat = view.feature_at(0, 0)
    if goal_travel.safe_hatch and not goal_travel.want_go then
        local map_pos = unhash_position(goal_travel.safe_hatch)
        if not positions_equal(qw.map_pos, map_pos)
                or feat ~= "escape_hatch_down" then
            return false
        end
    else
        local feats = goal_travel_features()
        if not feats then
            return false
        end

        if not util.contains(feats, feat) then
            return false
        end
    end

    if feature_uses_map_key(">", feat) then
        go_downstairs()
        return true
    elseif feature_uses_map_key("<", feat) then
        go_upstairs()
        return true
    end

    return false
end

function plan_abort_safe_stairs()
    if goal_travel.want_go or not (goal_travel.safe_stairs or goal_travel.safe_hatch) then
        return false
    end

    -- We need to update goal travel ourself immediately because we also need
    -- to restart the cascade so that previous plans can do something besides
    -- attempting to use safe stairs.
    qw.safe_stairs_failed = true
    update_goal()

    qw.restart_cascade = true
    return true
end
