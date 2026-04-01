------------------
-- Goal configuration and assessment

-- Approximate difficulty of a branch:depth. Higher = harder.
-- Based on typical monster danger for each area.
local branch_base_difficulty = {
    D = 0, Lair = 3, Orc = 6, Spider = 8, Shoals = 8,
    Snake = 8, Swamp = 8, Vaults = 10, Elf = 10,
    Depths = 12, Crypt = 13, Slime = 14, Zot = 16,
}

-- Find the easiest (lowest difficulty) unexplored level across branches.
-- Only considers branches that exist and whose entrance has been found.
-- Returns a single level like "Spider:2" or "Orc:1".
function easiest_unexplored_level(branches)
    local best_level, best_diff
    local has_non_rune = false

    -- First pass: check if any non-rune-floor levels remain
    for _, br in ipairs(branches) do
        if branch_exists(br) and branch_found(br) then
            local max_d = branch_depth(br)
            for d = 1, max_d do
                if not explored_level(br, d) then
                    if d ~= branch_rune_depth(br) then
                        has_non_rune = true
                    end
                    break
                end
            end
        end
    end

    -- Second pass: score and pick
    for _, br in ipairs(branches) do
        if branch_exists(br) and branch_found(br) then
            local max_d = branch_depth(br)
            local base = branch_base_difficulty[br] or 10
            for d = 1, max_d do
                if not explored_level(br, d) then
                    local difficulty = base + d
                    -- Only penalize rune floors when there are easier
                    -- non-rune options. Otherwise commit to the rune.
                    if d == branch_rune_depth(br) and has_non_rune then
                        difficulty = difficulty + 4
                    end
                    if not best_diff or difficulty < best_diff then
                        best_diff = difficulty
                        best_level = make_level(br, d)
                    end
                    break
                end
            end
        end
    end
    return best_level
end

function goal_normal_next(final)
    local goal

    -- If the bot is on a level that needs autoexploring AND that level is
    -- part of a valid goal range, stick with the current goal. This prevents
    -- goal cycling where the bot visits a level, goal switches, it leaves
    -- before autoexplore completes, and keeps bouncing between levels.
    if not autoexplored_level(where_branch, where_depth)
            and not in_portal()
            and not branch_is_temporary(where_branch)
            and where_branch ~= "Temple" then
        if where_branch == "D" and where_depth <= 11 then
            return "D:1-11"
        elseif where_branch == "Lair" then
            return "Lair"
        elseif where_branch == "Orc" then
            return "Orc"
        end
    end

    -- Don't try to convert from Ignis too early.
    if explored_level_range("D:1-8")
            and you.god() == "Ignis"
            and you.piety_rank() == 0 then
        local found = {}
        local gods = god_options()
        local keep_ignis = false
        for _, g in ipairs(gods) do
            if g == "Ignis" then
                keep_ignis = true
                break
            elseif altar_found(g) then
                table.insert(found, g)
            end
        end

        if not keep_ignis then
            if #found ~= #gods
                    and branch_found("Temple")
                    and not explored_level_range("Temple") then
                return "Temple"
            end

            if #found > 0 then
                if not c_persist.chosen_god then
                    c_persist.chosen_god = found[crawl.roll_dice(1, #found)]
                end

                return "God:" .. c_persist.chosen_god
            end
        end
    end

    if not explored_level_range("D:1-11") then
        -- We head to Lair early, before having explored through D:11, if we
        -- feel we're ready.  But if we've been in Lair and are under-leveled
        -- or lack teleport scrolls, go back to D instead of pushing deeper
        -- into dangerous Lair floors.
        local have_tele = find_item("scroll", "teleportation")
        -- Trigger detour if we're on Lair:4+ or have done Lair:1-3
        local in_deep_lair = you.branch() == "Lair" and you.depth() >= 4
        local lair_shallow_done = explored_level_range("Lair:1-3")
            or in_deep_lair
        local need_more_xp = lair_shallow_done
            and (you.xl() < 15 or not have_tele)

        -- Log which D levels are blocking explored_level_range("D:1-11")
        local blocking = {}
        for d = 1, 11 do
            if not explored_level("D", d) then
                local ae = autoexplored_level("D", d)
                local up = have_all_stairs("D", d, const.dir.up,
                    const.explore.reachable)
                local dn = have_all_stairs("D", d, const.dir.down,
                    const.explore.reachable)
                local state = c_persist.autoexplore[make_level("D", d)]
                table.insert(blocking, "D:" .. d
                    .. "(ae=" .. bool_string(ae)
                    .. " up=" .. bool_string(up)
                    .. " dn=" .. bool_string(dn)
                    .. " st=" .. tostring(state) .. ")")
            end
        end
        note_decision("GOAL-BLOCK", "D:1-11 blocking: "
            .. table.concat(blocking, ", ")
            .. " | Lair=" .. bool_string(branch_found("Lair"))
            .. " xl=" .. you.xl()
            .. " tele=" .. bool_string(have_tele))

        -- Don't switch away from Dungeon while we're actively on an
        -- unexplored D level. This prevents goal cycling where the bot
        -- enters D:N, goal switches to Lair, bot leaves, comes back,
        -- goal switches again, wasting thousands of turns.
        local on_unexplored_d = in_branch("D")
            and not explored_level(where_branch, where_depth)
        if need_more_xp or on_unexplored_d then
            goal = "D:1-11"
        elseif branch_found("Lair")
                and not explored_level_range("Lair")
                and ready_for_lair() then
            goal = "Lair"
        elseif branch_found("Orc")
                and not explored_level_range("Orc") then
            -- Orc:1 (difficulty 7) is easier than D:10+ (difficulty 10+).
            -- Use easiest_unexplored_level to interleave Orc with late D.
            goal = easiest_unexplored_level({"D", "Orc"})
                or "D:1-11"
        else
            goal = "D:1-11"
        end
    -- D:1-11 explored, but not Lair. Only target Lair if the entrance was
    -- actually found; otherwise skip to deeper Dungeon goals to avoid an
    -- infinite travel oscillation when the entrance is unreachable.
    elseif branch_found("Lair") and not explored_level_range("Lair") then
        -- After clearing some Lair, detour for XP if under-leveled or
        -- lacking teleport scrolls. Try Orc:1, then D:12, before deep Lair.
        local have_tele = find_item("scroll", "teleportation")
        local need_detour = you.xl() < 15 or not have_tele
        if need_detour then
            if not explored_level_range("D:12") then
                goal = "D:12"
            else
                goal = "Lair"
            end
        else
            goal = "Lair"
        end
    -- D:1-11 and Lair explored, but not D:12.
    elseif not explored_level_range("D:12") then
        if qw.late_orc then
            goal = "D"
        else
            goal = "D:12"
        end
    -- D:1-12 and Lair explored, but not all of D.
    elseif not explored_level_range("D") then
        if not qw.late_orc
                and branch_found("Orc")
                and not explored_level_range("Orc") then
            goal = "Orc"
        else
            goal = "D"
        end
    -- D and Lair explored, but not Orc or Lair branches.
    -- Use one-level-at-a-time swapping: pick the easiest unexplored level
    -- across Orc and both Lair rune branches.
    elseif not explored_level_range("Orc") then
        local candidates = { "Orc" }
        local first_br = next_branch(lair_branch_order())
        if first_br then
            table.insert(candidates, first_br)
        end
        local second_br = next_branch(lair_branch_order(), 1)
        if second_br then
            table.insert(candidates, second_br)
        end
        goal = easiest_unexplored_level(candidates)
        if not goal then
            goal = "Orc"
        end
    end

    if goal then
        return goal
    end

    -- D, Lair, and Orc all explored. Sequential progression through
    -- remaining branches. Use easiest_unexplored_level only for the
    -- two Lair rune branches (to interleave their non-rune floors).

    if not early_first_lair_branch then
        local first_br = next_branch(lair_branch_order())
        early_first_lair_branch = make_level_range(first_br, 1, -1)
        first_lair_branch_end = branch_end(first_br)

        local second_br = next_branch(lair_branch_order(), 1)
        early_second_lair_branch = make_level_range(second_br, 1, -1)
        second_lair_branch_end = branch_end(second_br)
    end

    -- Interleave non-rune floors of both Lair branches.
    local first_br = next_branch(lair_branch_order())
    local second_br = next_branch(lair_branch_order(), 1)
    -- Pick which Lair branch to explore next based on difficulty.
    -- Use branch ranges (not individual levels) so the bot fully commits
    -- to one branch at a time instead of cycling between branches.
    local lair_next
    if first_br and not explored_level_range(first_br) then
        if second_br and not explored_level_range(second_br) then
            -- Both available: pick the one with the easier next level
            local candidates = {}
            table.insert(candidates, first_br)
            table.insert(candidates, second_br)
            local pick = easiest_unexplored_level(candidates)
            if pick then
                lair_next = parse_level_range(pick)
            end
        else
            lair_next = first_br
        end
    elseif second_br and not explored_level_range(second_br) then
        lair_next = second_br
    end

    if lair_next then
        goal = lair_next
    -- Both Lair branches explored. Vaults (if we have runes to avoid lock).
    -- Vaults:1-4 (if we have runes, so no lock-in)
    elseif you.num_runes() > 0 and not explored_level_range(early_vaults) then
        goal = early_vaults
    -- Depths before Vaults:5 and Elf (Depths has better XP/turn)
    elseif not explored_level_range("Depths") then
        goal = "Depths"
    -- Elf for XP before Zot (runed doors auto-open on explored levels)
    elseif branch_found("Elf") and not explored_level_range("Elf") then
        goal = "Elf"
    -- No runes and Vaults not started — full commit
    elseif you.num_runes() == 0 and not explored_level_range("Vaults") then
        goal = "Vaults"
    -- Slime rune is easier than Vaults:5 when we have corrosion resistance.
    -- Slime:1-4 are simple, Slime:5 has Royal Jelly but is manageable.
    elseif branch_found("Slime") and not explored_level_range("Slime")
            and you.res_corr() and not have_branch_runes("Slime") then
        goal = "Slime"
    -- Vaults:5 only if we still need runes. Skip if we got 3 from Slime.
    elseif you.num_runes() < 3 and not explored_level_range(vaults_end) then
        goal = vaults_end
    end

    if goal then
        return goal
    end

    -- Everything explored. Final goals.
    if not c_persist.done_shopping then
        goal = "Shopping"
    elseif final and not explored_level_range(early_zot) then
        goal = early_zot
    elseif final then
        goal = "Win"
    end

    return goal
end

function goal_complete(plan, final)
    if plan:find("^God:") then
        return you.god() == goal_god(plan)
    elseif plan:find("^Rune:") then
        local branch = goal_rune_branch(plan)
        return not branch_exists(branch) or have_branch_runes(branch)
    end

    local branch = parse_level_range(plan)
    return plan == "Normal" and not goal_normal_next(final)
        or branch and not branch_exists(branch)
        or branch and explored_level_range(plan)
        or plan == "Shopping" and c_persist.done_shopping
        or plan == "Abyss"
            and have_branch_runes("Abyss")
        or plan == "Pan" and have_branch_runes("Pan")
        or plan == "Zig" and c_persist.zig_completed
        or plan == "Orb" and qw.have_orb
        or plan == "Save" and c_persist.last_completed_goal == "Save"
end

function choose_goal()
    local next_goal, chosen_goal, normal_goal, last_completed

    if debug_goal then
        if debug_goal == "Normal" then
            normal_goal = goal_normal_next(false)
            if normal_goal then
                chosen_goal = debug_goal
            else
                last_completed = debug_goal
                debug_goal = nil
            end
        elseif goal_complete(debug_goal) then
            last_completed = debug_goal
            debug_goal = nil
        else
            chosen_goal = debug_goal
        end
    end

    while not chosen_goal and which_goal <= #goal_list do
        chosen_goal = goal_list[which_goal]
        next_goal = goal_list[which_goal + 1]
        local chosen_final = not next_goal
        local next_final = not goal_list[which_goal + 2]

        if chosen_goal == "Normal" then
            normal_goal = goal_normal_next(chosen_final)
            if not normal_goal then
                last_completed = chosen_goal
                chosen_goal = nil
            end
        -- For God conversion and save goals, we don't perform them if we see
        -- that the next plan is complete. This way if a goal list has god
        -- conversions or saves, past ones won't be re-attempted when we save
        -- and reload.
        elseif (chosen_goal:find("^God:") or chosen_goal == "Save")
                and next_goal
                and goal_complete(next_goal, next_final) then
            last_completed = chosen_goal
            chosen_goal = nil
        elseif goal_complete(chosen_goal, chosen_final) then
            last_completed = chosen_goal
            chosen_goal = nil
        end

        if not chosen_goal then
            which_goal = which_goal + 1
        end
    end

    if last_completed then
        c_persist.last_completed_goal = last_completed
    end

    -- We're out of goals, so we make our final task be winning.
    if not chosen_goal then
        which_goal = nil
        chosen_goal = "Win"
    end

    return chosen_goal, normal_goal
end

-- Choose an active portal on this level. We only consider allowed portals, and
-- choose the oldest one. Permanent bazaars get chosen last.
function choose_level_portal(level)
    local oldest_portal
    local oldest_turns
    for portal, turns_list in pairs(c_persist.portals[level]) do
        if portal_allowed(portal) then
            if #turns_list > 0
                    and (not oldest_turns
                        or turns_list[#turns_list] < oldest_turns) then
                oldest_portal = portal
                oldest_turns = turns_list[#turns_list]
            end
        end
    end

    return oldest_portal, oldest_turns
end

-- If we found a viable portal on the current level, that becomes our goal.
function get_portal_goal()
    local chosen_portal, chosen_level, chosen_turns
    for level, portals in pairs(c_persist.portals) do
        local portal, turns = choose_level_portal(level)
        if portal and (not chosen_turns or turns < chosen_turns) then
            chosen_portal = portal
            chosen_level = level
            chosen_turns = turns
        end
    end

    -- We only load a portal's parent branch info when it's actually chosen,
    -- and the parent info will be removed once the portal expires or is
    -- completed.
    if chosen_portal then
        local branch, depth = parse_level_range(chosen_level)
        branch_data[chosen_portal].parent = branch
        branch_data[chosen_portal].parent_min_depth = depth
        branch_data[chosen_portal].parent_max_depth = depth
    end

    return chosen_portal, chosen_turns == const.inf_turns
end

function want_god()
    return you.race() ~= "Demigod"
        and you.god() == "No God"
        and god_options()[1] ~= "No God"
end

function determine_goal()
    permanent_bazaar = nil
    local chosen_goal, normal_goal = choose_goal()

    if debug_channel("goals") then
        note_decision("GOAL-EVAL", "chosen=" .. tostring(chosen_goal)
            .. " normal=" .. tostring(normal_goal)
            .. " where=" .. tostring(where)
            .. " xl=" .. you.xl()
            .. " turns=" .. you.turns())
    end
    local old_status = goal_status
    local status = chosen_goal
    local goal = status

    if status == "Save" then
        goal_status = status
        note_decision("GOAL", "SAVING")
        return
    end

    if qw.quit_turns and qw.stuck_turns > qw.quit_turns
            or select(2, you.hp()) == 1 then
        status = "Quit"
    end

    if status == "Quit" then
        goal_status = status
        note_decision("GOAL", "QUITTING!")
        return
    end

    if status == "Normal" then
        status = normal_goal
        goal = normal_goal
    end

    -- Safety: don't enter very dangerous areas without escape consumables.
    -- Redirect to easier content or shopping.
    if goal then
        local goal_br = parse_level_range(goal)
        local have_tele = find_item("scroll", "teleportation")
        local have_heal = find_item("potion", "heal wounds")
        local too_dangerous = false
        if goal_br == "Vaults" and goal == vaults_end then
            too_dangerous = true
        elseif goal_br == "Depths" and not have_tele and you.xl() < 22 then
            too_dangerous = true
        elseif goal_br == "Zot" and (not have_tele or not have_heal)
                and you.xl() < 24 then
            too_dangerous = true
        end
        if too_dangerous and (not have_tele or not have_heal) then
            -- Look for something safer to do, or go shopping.
            if branch_found("Crypt") and not explored_level_range("Crypt") then
                goal = "Crypt"
                status = goal
            elseif you.gold() >= 100 then
                -- With gold, go shopping to get consumables.
                c_persist.done_shopping = false
                status = "Shopping"
                goal = "Shopping"
                desc = "emergency shopping (need consumables)"
            end
        end
    end

    -- Override: if heading to deep Lair (4+) without teleport scrolls
    -- or at low XL, detour to D instead. This catches all cases regardless
    -- of which goal evaluation path was taken.
    if goal and goal:find("^Lair") then
        local lair_br, lair_min = parse_level_range(goal)
        if lair_br == "Lair" then
            local have_tele = find_item("scroll", "teleportation")
            local heading_deep = you.where():find("Lair")
                and (you.depth() >= 3 or explored_level("Lair", 3))
            if (you.xl() < 15 or not have_tele) and heading_deep then
                if not explored_level_range("D:1-11") then
                    goal = "D:1-11"
                    status = goal
                    note_decision("GOAL", "LAIR-OVERRIDE: too dangerous, heading to D instead")
                elseif not explored_level_range("D:12") then
                    goal = "D:12"
                    status = goal
                    note_decision("GOAL", "LAIR-OVERRIDE: too dangerous, heading to D:12 instead")
                end
            end
        end
    end

    -- Once we have the rune for this branch, this goal will be complete.
    -- Until then, we're diving to and exploring the branch end.
    local desc
    if status:find("^Rune:") then
        local branch = goal_rune_branch(status)
        goal = make_level(branch, branch_rune_depth(branch))
        desc = branch .. " rune"
    end

    -- If we're configured to join a god, prioritize finding one from our god
    -- list, possibly exploring Temple once it's found.
    if want_god() then
        local found = {}
        local gods = god_options()
        for _, g in ipairs(gods) do
            if altar_found(g) then
                table.insert(found, g)
            end
        end

        if #found ~= #gods
                and branch_found("Temple")
                and not explored_level_range("Temple") then
            status = "Temple"
            goal = "Temple"
            desc = "Temple"
        elseif #found > 0 then
            if not c_persist.chosen_god then
                c_persist.chosen_god = found[crawl.roll_dice(1, #found)]
            end

            status = "God:" .. c_persist.chosen_god
        end
    end

    if status:find("^God:") then
        local god = goal_god(status)
        desc = god .. " worship"
        local altar_level = altar_found(god)
        if altar_level then
            goal = altar_level
        elseif branch_found("Temple")
                and not explored_level_range("Temple") then
            goal = "Temple"
        end
    end

    local portal
    portal, permanent_bazaar = get_portal_goal()
    if portal then
        status = portal
        goal = portal
        desc = portal
    end

    -- Make sure we respect Vaults locking when we don't have the rune.
    if in_branch("Vaults") and you.num_runes() == 0 then
        local branch = parse_level_range(goal)
        local override = false
        if branch then
            local parent = parent_branch(branch)
            if branch ~= "Vaults"
                    and parent ~= "Vaults"
                    and parent ~= "Crypt"
                    and parent ~= "Tomb" then
                override = true
            end
        else
            override = true
        end

        if override then
            branch = "Vaults"
            status = "Rune:Vaults"
            goal = vaults_end
            desc = "Vaults rune"
        end
    end

    if status == "Win" then
        status = qw.have_orb and "Escape" or "Orb"
    end

    if status == "Escape" then
        goal = "D:1"
    -- Dive to and explore the end of Zot. We'll start trying to pick up the
    -- ORB via stash search travel as soon as it's found.
    elseif status == "Orb" then
        goal = zot_end
    end

    -- Re-enable shopping when critically low on consumables with gold
    -- to spend. The bot may have used all its potions/scrolls but shops
    -- still have stock. Reset done_shopping so plan_shop fires when the
    -- bot passes through a shop tile during travel.
    -- Don't re-enable shopping when we have 3 runes and should head to Zot.
    if c_persist.done_shopping and you.gold() >= 200
            and you.num_runes() < 3
            and not find_item("scroll", "teleportation")
            and not find_item("potion", "heal wounds") then
        if debug_channel("shopping") then
            note_decision("SHOPPING", "re-enabling, gold=" .. you.gold()
                .. " no_tele=" .. tostring(not find_item("scroll", "teleportation"))
                .. " no_heal=" .. tostring(not find_item("potion", "heal wounds")))
        end
        c_persist.done_shopping = false
    end

    -- Aggressive shopping: if we can afford anything on the shopping list,
    -- go buy it now. The plan_shopping_spree has a stuck counter to bail
    -- out if travel fails.
    if status ~= "Shopping" and status ~= "Save" and status ~= "Quit"
            and not in_portal()
            and not c_persist.done_shopping
            and you.num_runes() < 3
            and can_afford_any_shoplist_item() then
        if debug_channel("shopping") then
            local shoplist = items.shopping_list()
            local list_str = ""
            if shoplist then
                for n, entry in ipairs(shoplist) do
                    list_str = list_str .. "\n  [" .. n .. "] "
                        .. entry[1] .. " (" .. entry[2] .. "g)"
                end
            end
            note_decision("SHOPPING", "aggressive spree triggered from " .. status
                .. ", gold=" .. you.gold() .. ", shoplist:" .. list_str)
        end
        status = "Shopping"
        goal = "Shopping"
        desc = "shopping spree"
    end

    -- Portals remain our goal while we're there.
    if in_portal() then
        status = where_branch
        goal = where_branch
    end

    local branch = parse_level_range(goal)
    if branch == "Zot" and you.num_runes() < 3 then
        error("Couldn't get three runes to enter Zot!")
    end

    if old_status ~= status then
        if not desc then
            if status == "Shopping" then
                desc = "shopping spree"
            else
                desc = status
            end
        end
        note_decision("GOAL", "PLANNING " .. desc:upper())
    end

    set_goal(status, goal)
end

function branch_soon(branch)
    return branch == goal_branch
end

function undead_or_demon_branch_soon()
    return branch_soon("Abyss")
        or branch_soon("Crypt")
        or branch_soon("Hell")
        or is_hell_branch(goal_branch)
        or branch_soon("Pan")
        or branch_soon("Tomb")
        or branch_soon("Zig")
        -- Once you have the ORB, every branch is an demon branch.
        or qw.have_orb
end

function goals_visit_branches(branches)
    if not which_goal then
        return false
    end

    for i = which_goal, #goal_list do
        local plan = goal_list[i]
        local plan_branch
        if plan:find("^Rune:") then
            plan_branch = goal_rune_branch(plan)
        else
            plan_branch = parse_level_range(plan)
        end

        if plan_branch
                and util.contains(branches, plan_branch)
                and not goal_complete(plan, i == #goal_list) then
            return true
        end
    end

    if not qw.have_orb and util.contains(branches, "Zot") then
        return true
    end

    return false
end

function goals_visit_branch(branch)
    return goals_visit_branches({ branch })
end

function goals_future_gods()
    if not which_goal then
        return {}
    end

    local options = god_options()
    local gods = {}
    if not util.contains(options, you.god()) then
        gods = util.copy_table(options)
    end

    for i = which_goal, #goal_list do
        local plan = goal_list[i]
        local plan_god = goal_god(plan)
        if plan_god then
            table.insert(gods, plan_god)
        end
    end

    return gods
end

function planning_convert_to_gods(gods)
    for _, god in ipairs(gods) do
        if util.contains(qw.future_gods, god) then
            return true
        end
    end

    return false
end

function planning_convert_to_god(god)
    return planning_convert_to_gods({ god })
end

function planning_convert_to_mp_using_gods()
    if you.race() == "Djinni" then
        return false
    end

    return planning_convert_to_gods(const.mp_using_gods)
end

function planned_gods_all_use_mp()
    if not util.contains(const.mp_using_gods, you.god()) then
        return false
    end

    for _, god in ipairs(qw.future_gods) do
        if not util.contains(const.mp_using_gods, god) then
            return false
        end
    end

    return true
end

function update_planning()
    if goal_status == "Save" or goal_status == "Quit" then
        return
    end

    qw.planning_zig = goals_visit_branch("Zig")

    qw.planning_vaults = goals_visit_branch("Vaults")
    qw.planning_slime = goals_visit_branch("Slime")
    qw.planning_tomb = goals_visit_branch("Tomb")
    qw.planning_cocytus = goals_visit_branch("Coc")

    qw.future_gods = goals_future_gods()
    qw.future_gods_use_mp = planning_convert_to_mp_using_gods()
    qw.future_tso = planning_convert_to_god("the Shining One")
    qw.future_okawaru = planning_convert_to_god("Okawaru")

    qw.planned_gods_all_use_mp = planned_gods_all_use_mp()
end

-- Make a level range for the given branch and ranges, e.g. D:1-11. The
-- returned string is normalized so it's as simple as possible. Invalid level
-- ranges raise an error.
-- @string      branch The branch.
-- @number      first  The first level in the range.
-- @number[opt] last   The last level in the range, defaulting to the branch end.
--                     If negative, the range stops that many levels from the
--                     end of the branch.
-- @treturn string The level range.
function make_level_range(branch, first, last)
    local max_depth = branch_depth(branch)
    if not last then
        last = max_depth
    elseif last < 0 then
        last = max_depth + last
    end

    if first < 1
            or first > max_depth
            or last < 1
            or last > max_depth
            or first > last then
        error("Invalid level range for " .. tostring(branch)
            ..": " .. tostring(first) .. ", " .. tostring(last))
    end

    if first == 1 and last == max_depth then
        return branch
    elseif first == last then
        return branch .. ":" .. first
    else
        return branch .. ":" .. first .. "-" .. last
    end
end

-- Make a level range for a single level, e.g. D:1.
-- @string branch The branch.
-- @int    first  The level.
-- @treturn string The level range.
function make_level(branch, depth)
    return make_level_range(branch, depth, depth)
end

-- Parse components of a level range.
-- @string range The level range.
--
-- @treturn string The branch. Will be nil if the level is invalid.
-- @treturn int    The starting level.
-- @treturn int    The ending level.
function parse_level_range(range)
    local terms = split(range, ":")
    local br = terms[1]

    if not branch_data[br] then
        return
    end

    local br_depth = branch_depth(br)
    -- A branch name with no level range.
    if #terms == 1 then
        return br, 1, br_depth
    end

    local min_level, max_level
    local level_terms = split(terms[2], "-")
    min_level = tonumber(level_terms[1])
    if not min_level
            or math.floor(min_level) ~= min_level
            or min_level < 1
            or min_level > br_depth then
        return
    end

    if #level_terms == 1 then
        max_level = min_level
    else
        max_level = tonumber(level_terms[2])
        if not max_level
                or math.floor(max_level) ~= max_level
                or max_level < min_level
                or max_level > br_depth then
            return
        end
    end

    return br, min_level, max_level
end

function autoexplored_level(branch, depth)
    local state = c_persist.autoexplore[make_level(branch, depth)]
    return state and state > const.autoexplore.needed
end

function explored_level(branch, depth)
    if branch == "Abyss" or branch == "Pan" then
        return have_branch_runes(branch)
    end

    -- Levels that were force-explored (stuck autoexplore detection) are
    -- treated as fully explored to prevent the bot from returning to them.
    local level = make_level(branch, depth)
    if c_persist.force_explored and c_persist.force_explored[level] then
        return true
    end

    return autoexplored_level(branch, depth)
        and have_all_stairs(branch, depth, const.dir.down,
            const.explore.reachable)
        and have_all_stairs(branch, depth, const.dir.up,
            const.explore.reachable)
        and (have_branch_runes(branch) or depth < branch_rune_depth(branch))
end

function explored_level_range(range)
    local br, min_level, max_level
    br, min_level, max_level = parse_level_range(range)
    if not br then
        return false
    end

    for l = min_level, max_level do
        if not explored_level(br, l) then
            return false
        end
    end

    return true
end

function ready_for_lair()
    if want_god()
            or goal_branch
                and goal_branch == "D"
                and goal_depth <= 11
                and not explored_level(goal_branch, goal_depth) then
        return false
    end

    return you.god() == "Trog"
        or you.god() == "Cheibriados"
        or you.god() == "Okawaru"
        or you.god() == "Ignis"
        or you.god() == "Qazlal"
        or you.god() == "the Shining One"
        or you.god() == "Lugonu"
        or you.god() == "Uskayaw"
        or you.god() == "Xom"
        or you.god() == "Zin"
        or (you.god() == "Beogh"
            or you.god() == "Makhleb"
            or you.god() == "Yredelemnul") and you.piety_rank() >= 4
        or (you.god() == "Ru" or you.god() == "Elyvilon")
            and you.piety_rank() >= 3
        or you.god() == "Hepliaklqana" and you.piety_rank() >= 2
end

-- Return the next existing level range in a list.
-- @param[opt=0] skip A number giving how many valid level ranges to skip.
-- @tparam options A list of level ranges.
-- @treturn string The next level range.
function next_branch(options, skip)
    if not skip then
        skip = 0
    end

    local skipped = 0
    for _, level in ipairs(options) do
        local branch = parse_level_range(level)
        -- Reject any levels in branches that couldn't exist given the branches
        -- we've found already.
        if branch and branch_exists(branch) then
            if skipped < skip then
                skipped = skipped + 1
            else
                return branch
            end
        end
    end
end

function lair_branch_order()
    if c_persist.lair_branch_order then
        return c_persist.lair_branch_order
    end

    local branch_options
    if qw.rune_preference == "smart" then
        if crawl.random2(2) == 0 then
            branch_options = { "Spider", "Snake", "Swamp", "Shoals" }
        else
            branch_options = { "Spider", "Swamp", "Snake", "Shoals" }
        end
    elseif qw.rune_preference == "dsmart" then
        if crawl.random2(2) == 0 then
            branch_options = { "Spider", "Swamp", "Snake", "Shoals" }
        else
            branch_options = { "Swamp", "Spider", "Snake", "Shoals" }
        end
    elseif qw.rune_preference == "nowater" then
        branch_options = { "Snake", "Spider", "Swamp", "Shoals" }
    -- "random"
    else
        if crawl.random2(2) == 0 then
            branch_options = { "Snake", "Spider", "Swamp", "Shoals" }
        else
            branch_options = { "Swamp", "Shoals", "Snake", "Spider" }
        end
    end

    c_persist.lair_branch_order = branch_options
    return branch_options
end

-- Remove the "God:" prefix and return the god's full name.
function goal_god(plan)
    if not plan:find("^God:") then
        return
    end

    return god_full_name(plan:sub(5))
end

-- Remove the "Rune:" prefix and return the branch name.
function goal_rune_branch(plan)
    if not plan:find("^Rune:") then
        return
    end

    return plan:sub(6)
end

-- Remove any prefix and return the Zig depth we want to reach.
function goal_zig_depth(plan)
    if plan == "Zig" or plan:find("^MegaZig") then
        return 27
    end

    if not plan:find("^Zig:") then
        return
    end

    return tonumber(plan:sub(5))
end

function initialize_goals()
    local goals = split(goal_options(), ",")
    goal_list = {}
    for _, pl in ipairs(goals) do
        -- Two-part plan specs: God conversion and rune.
        local plan
        pl = trim(pl)
        if pl:lower():find("^god:") then
            local name = goal_god(pl)
            if not name then
                error("Unkown god: " .. name)
            end

            plan = "God:" .. name
            processed = true
        elseif pl:lower():find("^rune:") then
            local branch = capitalise(goal_rune_branch(pl))
            if not branch_data[branch] then
                error("Unknown rune branch: " .. branch)
            elseif not branch_runes(branch) then
                error("Branch has no rune: " .. branch)
            end

            plan = "Rune:" .. branch
            processed = true
        else
            -- Normalize the plan so we're always making accurate comparisons
            -- for special plans like Normal, Shopping, Orb, etc.
            plan = capitalise(pl)
        end

        -- We turn Hells into a sequence of goals for each Hell branch rune
        -- in random order.
        if plan == "Hells" then
            -- Save our selection so it can be recreated across saving.
            if not c_persist.hell_branches then
                c_persist.hell_branches = util.random_subset(hell_branches,
                    #hell_branches)
            end

            for _, br in ipairs(c_persist.hell_branches) do
                table.insert(goal_list, "Rune:" .. br)
            end
        end

        local branch, min_level, max_level = parse_level_range(plan)
        if not (branch
                or plan == "Save"
                or plan == "Quit"
                or plan == "Escape"
                or plan:find("^Rune:")
                or plan:find("^God:")
                or plan == "Normal"
                or plan == "Shopping"
                or plan == "Hells"
                or plan == "Zig"
                or plan == "Orb"
                or plan == "Win") then
            error("Invalid goal '" .. tostring(plan) .. "'.")
        end

        table.insert(goal_list, plan)
    end
end

function update_goal()
    local last_goal_branch = goal_branch

    update_expired_portals()
    update_permanent_flight()

    determine_goal()
    update_planning()
    update_goal_travel()

    -- Open runed doors in portals, when travel says to, or when the
    -- current level is autoexplored but not fully explored (runed doors
    -- are the only thing blocking progress).
    open_runed_doors = branch_is_temporary(where_branch)
        or goal_travel.open_runed_doors
        or (autoexplored_level(where_branch, where_depth)
            and not explored_level(where_branch, where_depth))

    -- The branch we're planning to visit can affect equipment decisions.
    if last_goal_branch ~= goal_branch then
        reset_best_equip()
    end

    qw.want_goal_update = false
end

function god_options()
    return c_persist.current_god_list
end

function goal_options()
    if override_goals then
        return override_goals
    end

    return qw.goals[c_persist.current_goals]
end

function next_exploration_depth(branch, min_depth, max_depth)
    if branch == "Abyss" then
        local rune_depth = branch_rune_depth("Abyss")
        if in_branch("Abyss") and where_depth > rune_depth then
            return where_depth
        else
            return rune_depth
        end
    end

    -- The earliest depth that either lacks autoexplore or doesn't have all
    -- stairs reachable.
    local branch_max = branch_depth(branch)
    for d = min_depth, max_depth do
        if not autoexplored_level(branch, d) then
            note_decision("GOAL-DEPTH", "next_explore: " .. branch .. ":"
                .. d .. " not-autoexplored state="
                .. tostring(c_persist.autoexplore[make_level(branch, d)]))
            return d
        elseif not have_all_stairs(branch, d, const.dir.up,
                    const.explore.reachable)
                or not have_all_stairs(branch, d, const.dir.down,
                    const.explore.reachable) then
            local up_ok = have_all_stairs(branch, d, const.dir.up,
                const.explore.reachable)
            local dn_ok = have_all_stairs(branch, d, const.dir.down,
                const.explore.reachable)
            note_decision("GOAL-DEPTH", "next_explore: " .. branch .. ":"
                .. d .. " missing-stairs up=" .. bool_string(up_ok)
                .. " down=" .. bool_string(dn_ok))
            return d
        end
    end

    if max_depth == branch_depth(branch) and not have_branch_runes(branch) then
        return max_depth
    end
end

function set_goal(status, goal)
    goal_status = status

    goal_branch = nil
    goal_depth = nil
    local min_depth, max_depth
    goal_branch, min_depth, max_depth = parse_level_range(goal)

    -- God and Escape goals always set the goal branch/depth to a
    -- specific level, so we don't need further exploration.
    if status:find("^God") or status == "Escape" then
        goal_depth = min_depth
    elseif in_portal() then
        goal_depth = where_depth
    elseif goal_branch then
        goal_depth
            = next_exploration_depth(goal_branch, min_depth, max_depth)

        if goal == zot_end and not goal_depth then
            goal_depth = branch_depth("Zot")
            if where == zot_end then
                qw.ignore_traps = true
                c_persist.autoexplore[zot_end] = const.autoexplore.needed
            end
        end
    end

    if debug_channel("goals") then
        note_decision("GOAL", "Goal status: " .. goal_status)
        if goal_branch then
            note_decision("GOAL", "Goal branch: " .. tostring(goal_branch)
                .. ", depth: " .. tostring(goal_depth))
        end
    end

end

function reset_autoexplore(level)
    if c_persist.autoexplore[level] == const.autoexplore.needed then
        return
    end

    -- Don't reset force-explored levels; they were marked because the
    -- bot was stuck and we need to skip them permanently.
    if c_persist.force_explored and c_persist.force_explored[level] then
        return
    end

    if debug_channel("goals") then
        note_decision("GOAL", "Resetting autoexplore of " .. level)
    end

    c_persist.autoexplore[level] = const.autoexplore.needed
    qw.want_goal_update = true
end
