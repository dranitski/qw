----------------------
-- Assessment of fleeing positions

function update_flee_positions()
    qw.flee_positions = {}

    if unable_to_move() then
        return
    end

    local stairs_feats = level_stairs_features(where_branch, where_depth,
        const.dir.up)
    local search_feats = {}
    -- Only retreat to safe stairs with a safe destination.
    for _, feat in ipairs(stairs_feats) do
        local state = get_stairs(where_branch, where_depth, feat)
        local dest_state = get_destination_stairs(where_branch, where_depth,
            feat)
        if (not state or state.safe)
                and (not dest_state or dest_state.safe) then
            table.insert(search_feats, feat)
        end
    end

    local positions, feats = get_feature_map_positions(search_feats)
    if not positions then
        return
    end

    for i, pos in ipairs(positions) do
        local state
        if feats[i] == "escape_hatch_up" then
            state = get_map_escape_hatch(where_branch, where_depth, pos)
        end
        if (not state or state.safe)
                and map_is_reachable_at(pos) then
            if debug_channel("flee") then
                note_decision("FLEE", "Adding flee position #"
                    .. tostring(#qw.flee_positions + 1) .. " at "
                    .. cell_string_from_map_position(pos))
            end

            table.insert(qw.flee_positions, pos)
        end
    end
end

function check_following_melee_enemies(radius)
    return check_enemies(radius,
        function(mons)
            return mons:can_melee_player() and mons:can_seek()
        end)
end

function want_to_flee()
    -- On D:1 there are no upstairs to flee to, but we can still retreat
    -- toward the dungeon exit to create distance. Without this, the bot
    -- stands and melees to death in unwinnable fights.
    -- At low XL, be more cautious: flee at 50% HP since the HP pool is
    -- tiny and a couple of unlucky hits means death.
    if not qw.can_flee_upstairs then
        if qw.danger_in_los and not buffed() then
            local flee_threshold = you.xl() < 5 and 50 or 25
            if hp_is_low(flee_threshold) then
                return true
            end
        end
        return false
    end

    -- If we're stuck in danger a bad form or berserked with a non-melee
    -- weapon, fleeing is our best bet.
    if (qw.danger_in_los or options.autopick_on)
            and (in_bad_form() or you.berserk() and using_ranged_weapon()) then
        return true
    end

    -- Flee to safety when on berserk cooldown with enemies present.
    -- Post-berserk the bot is slowed and vulnerable. Always flee on
    -- cooldown — even taking opportunity attacks is better than dying
    -- to sustained damage while slowed.
    if qw.danger_in_los
            and you.status("on berserk cooldown")
            and not buffed()
            and not check_brothers_in_arms(3) then
        return true
    end

    if not qw.danger_in_los then
        if qw.last_flee_turn and you.turns() >= qw.last_flee_turn + 10 then
            qw.last_flee_turn = nil
        end

        if not qw.last_flee_turn then
            return false
        end

        return not buffed() and reason_to_rest(90)
    end

    -- Flee from high-threat enemies even at full HP when under-leveled.
    -- Also flee from any scary enemy (e.g. Sonja with distortion) at any
    -- XL — distortion banishment is lethal regardless of level.
    if not buffed() and have_high_threat() then
        local scary = get_scary_enemy(const.duration.available)
        if scary or you.xl() < 7 then
            return true
        end
    end

    -- Don't flee from a place were we'll be opportunity attacked, and don't
    -- flee when we have allies close by. At low XL, override this at a
    -- higher HP threshold since the HP pool is small. Without escape items,
    -- use a higher gate since taking opportunity attacks is better than
    -- standing and dying with no way out.
    local have_escape = find_item("scroll", "teleportation")
        or find_item("potion", "heal wounds")
    local hp_gate
    if you.xl() < 5 then
        hp_gate = 50
    elseif not have_escape and where_depth > 3 then
        hp_gate = 40
    else
        hp_gate = 25
    end
    if check_following_melee_enemies(2) and not hp_is_low(hp_gate) then
        return false
    end

    if check_allies(3) and not hp_is_low(hp_gate) then
        return false
    end

    -- When we're at low XL and trying to go up, we want to flee to known
    -- stairs when autoexplore is disabled, instead of engaging in combat. This
    -- rule helps Delvers in particular avoid fights near their starting level
    -- that would get them killed.
    if you.xl() <= 8
            and disable_autoexplore
            and goal_travel.first_dir == const.dir.up
            and not goal_travel.stairs_dir then
        return true
    end

    local enemy = get_scary_enemy(const.duration.available)
    if enemy and enemy:threat(const.duration.available) >= 5
            and enemy:name():find("slime creature")
            and enemy:name() ~= "slime creature" then
        return true
    end

    if have_extreme_threat() then
        return not will_fight_extreme_threat()
    end

    if will_kite() then
        return false
    end

    -- Flee at higher HP threshold on dangerous levels or without escape.
    -- On Depths/Vaults:5, fight from stairs: engage, flee at 60% HP, rest,
    -- return. Without escape items, flee even earlier.
    local dangerous_area = in_branch("Depths") or in_branch("Zot")
        or (in_branch("Vaults") and at_branch_end("Vaults"))
    local flee_hp
    if not have_escape and dangerous_area then
        flee_hp = 60  -- stair-dance: flee early, rest, return
    elseif not have_escape then
        flee_hp = 75
    elseif dangerous_area then
        flee_hp = 80  -- cautious even with escape items
    else
        flee_hp = 90
    end

    return not buffed()
        and reason_to_rest(flee_hp)
        and qw.starting_spell ~= "Summon Small Mammal"
end

function enemy_can_flee_attack(enemy, flee_dist)
    local dist_to_player = enemy:melee_move_distance(const.origin)
    if not dist_to_player then
        if debug_channel("flee-all") then
            local props = { is_ranged = "ranged", reach_range = "reach",
                move_delay = "move delay" }
            note_decision("FLEE", "Ignoring monster that can't reach us: "
                .. monster_string(enemy, props))
        end

        return false
    end

    local closing_dist = dist_to_player
        - (enemy:is_ranged(true) and 4 or 0)
    local dist_gain = flee_dist
        * (player_move_delay() - enemy:move_delay())
        / enemy:move_delay()

    if debug_channel("flee-all") then
        local props = { is_ranged = "ranged", reach_range = "reach",
            move_delay = "move delay" }
        note_decision("FLEE", "Evaluating " .. monster_string(enemy, props)
            .. " with a closing distance of "
            .. tostring(closing_dist)
            .. " compared to a distance gain of "
            .. tostring(dist_gain))
    end

    return closing_dist < dist_gain
end

function flee_function(map_pos)
    local pos = position_difference(map_pos, qw.map_pos)
    if view.withheld(pos.x, pos.y) or not is_safe_at(pos) then
        return false
    end

    if supdist(pos) > qw.los_radius then
        return true
    end

    local mons = get_monster_at(pos)
    if mons and not mons:is_friendly() then
        return false
    end

    for _, enemy in ipairs(qw.enemy_list) do
        if enemy:can_melee_at(pos) then
            return false
        end
    end

    return true
end

function can_flee_to_destination(pos)
    local search = distance_map_search(qw.map_pos, pos, flee_function, 0)
    if not search then
        if debug_channel("flee") then
            note_decision("FLEE", "Unable to find move to flee position at "
                .. cell_string_from_map_position(pos))
        end

        return false
    end

    if debug_channel("flee") then
        note_decision("FLEE", "Evaluating flee position at "
            .. cell_string_from_map_position(pos) .. " with distance "
            .. tostring(search.dist))
    end

    local extreme_threat = have_extreme_threat()
    local flee_attackers = 0
    for _, enemy in ipairs(qw.enemy_list) do
        if enemy_can_flee_attack(enemy, search.dist) then
            flee_attackers = flee_attackers + 1
        end

        -- Allow fleeing through up to 1 attacker when HP is low and we have
        -- no escape. Better to take a hit than die standing still.
        local no_escape = not can_teleport()
            and not find_item("potion", "heal wounds")
        local max_flee_attackers = extreme_threat and 2
            or (hp_is_low(33) and no_escape) and 1 or 0
        if flee_attackers > max_flee_attackers then
            if debug_channel("flee") then
                note_decision("FLEE", "Not fleeing to " .. cell_string_from_map_position(pos)
                    .. " due to "  .. tostring(flee_attackers)
                    .. " or more attackers gaining distance")
            end

            return false
        end
    end

    if debug_channel("flee") then
        note_decision("FLEE", "Able to flee to " .. cell_string_from_map_position(pos))
    end

    return true
end

function get_flee_move()
    if in_bad_form() then
        result = best_move_towards_positions(qw.flee_positions, true)

        if debug_channel("flee") then
            if result then
                note_decision("FLEE", "Found bad form flee move to "
                    .. cell_string_from_position(result.move)
                    .. " towards destination "
                    .. cell_string_from_map_position(result.dest))
            else
                note_decision("FLEE", "No bad form flee move found towards any destination")
            end
        end

        if not result then
            result = best_move_towards_unexplored(true)
        end

        if debug_channel("flee") then
            if result then
                note_decision("FLEE", "Found bad form flee move to "
                    .. cell_string_from_position(result.move)
                    .. " towards destination near unexplored areas at "
                    .. cell_string_from_map_position(result.dest))
            else
                note_decision("FLEE", "No bad form flee move found towards unexplored areas")
            end
        end

        return result
    end

    local valid_dests = {}
    for _, pos in ipairs(qw.flee_positions) do
        if can_flee_to_destination(pos) then
            table.insert(valid_dests, pos)
        end
    end

    local result = best_move_towards_positions(valid_dests)

    if debug_channel("flee") then
        if result then
            note_decision("FLEE", "Found flee move to "
                .. cell_string_from_position(result.move)
                .. " towards destination "
                .. cell_string_from_map_position(result.dest))
        else
            note_decision("FLEE", "No move found towards any flee destination")
        end
    end

    return result
end

function will_flee()
    if not want_to_flee() or unable_to_move() or dangerous_to_move() then
        return false
    end

    return get_flee_move()
end
