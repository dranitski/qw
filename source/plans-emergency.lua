------------------
-- Emergency plans

function plan_teleport()
    if not want_to_teleport() then
        return false
    end

    if can_teleport() then
        return teleport()
    end

    note_decision("TELEPORT", "Teleport wanted but can't:"
        .. " can_read=" .. tostring(can_read())
        .. " confused=" .. tostring(you.confused())
        .. " silenced=" .. tostring(you.silenced())
        .. " teleporting=" .. tostring(you.teleporting())
        .. " anchored=" .. tostring(you.anchored())
        .. " have_scroll=" .. tostring(not not find_item("scroll", "teleportation")))
    return false
end

-- Are we significantly stronger than usual thanks to a buff that we used?
function buffed()
    if hp_is_low(50)
            or transformed()
            or you.corrosion() >= 8 + qw.base_corrosion then
        return false
    end

    if you.god() == "Okawaru"
            and (have_duration("heroism") or have_duration("finesse")) then
        return true
    end

    if you.extra_resistant() then
        return true
    end

    return false
end

function use_ru_healing()
    use_ability("Draw Out Power")
end

function use_ely_healing()
    use_ability("Greater Healing")
end

function use_purification()
    use_ability("Purification")
end

function plan_brothers_in_arms()
    if can_brothers_in_arms() and want_to_brothers_in_arms() then
        return use_ability("Brothers in Arms")
    end

    return false
end

function plan_greater_servant()
    if can_greater_servant() and want_to_greater_servant() then
        return use_ability("Greater Servant of Makhleb")
    end

    return false
end

function plan_cleansing_flame()
    if can_cleansing_flame() and want_to_cleansing_flame() then
        return use_ability("Cleansing Flame")
    end

    return false
end

function plan_divine_warrior()
    if can_divine_warrior() and want_to_divine_warrior() then
        return use_ability("Summon Divine Warrior")
    end

    return false
end

function plan_recite()
    if can_recite()
            and qw.danger_in_los
            and not (qw.immediate_danger and hp_is_low(33)) then
        return use_ability("Recite", "", true)
    end

    return false
end

function plan_tactical_step()
    if not qw.tactical_step then
        return false
    end

    note_decision("TACTICAL", "Stepping ~*~*~tactically~*~*~ (" .. qw.tactical_reason .. ").")
    return move_to(qw.tactical_step)
end

function plan_priority_tactical_step()
    if qw.tactical_reason == "cloud"
            or qw.tactical_reason == "sticky flame" then
        return plan_tactical_step()
    end

    return false
end

function plan_early_flee()
    if not qw.danger_in_los or not qw.can_flee_upstairs then
        return false
    end

    -- Flee immediately on berserk cooldown.
    if you.status("on berserk cooldown") and not buffed() then
        return plan_flee()
    end

    -- At very low XL with critical HP, flee before trying anything else.
    if you.xl() < 7 and hp_is_low(30) and not buffed() then
        return plan_flee()
    end

    return false
end

function plan_flee()
    if unable_to_move() or dangerous_to_move() or not want_to_flee() then
        return false
    end

    local result = get_flee_move()
    if not result then
        return false
    end

    if not qw.danger_in_los then
        qw.last_flee_turn = you.turns()
    end

    if move_to(result.move) then
        qw.stats.flees = qw.stats.flees + 1
        note_decision("FLEE", "FLEEEEING towards " .. cell_string_from_map_position(result.dest))
        note_decision("FLEE", "Fleeing towards "
            .. cell_string_from_map_position(result.dest))
        return true
    end

    return false
end

-- XXX: This plan is broken due to changes to combat assessment.
function plan_grand_finale()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.teleporting
            or not can_grand_finale() then
        return false
    end

    local invo = you.skill("Invocations")
    -- fail rate potentially too high, need to add ability failure rate lua
    if invo < 10 or you.piety_rank() < 6 and invo < 15 then
        return false
    end
    local bestx, besty, best_info, new_info
    local flag_order = {"threat", "injury", "distance"}
    local flag_reversed = {false, true, true}
    local best_info, best_pos
    for _, enemy in ipairs(qw.enemy_list) do
        local pos = enemy:pos()
        if is_traversable_at(pos)
                and not cloud_is_dangerous_at(pos) then
            if new_info.safe == 0
                    and (not best_info
                        or compare_melee_targets(enemy, best_enemy, props, reversed)) then
                best_info = new_info
                best_pos = pos
            end
        end
    end
    if best_info then
        use_ability("Grand Finale", "r" .. vector_move(best_pos) .. "\rY")
        return true
    end
    return false
end

function plan_apocalypse()
    if can_apocalypse() and want_to_apocalypse() then
        return use_ability("Apocalypse")
    end

    return false
end

function plan_hydra_destruction()
    if not can_destruction()
            or you.skill("Invocations") < 8
            or check_greater_servants(4) then
        return false
    end

    local hydra_dist = dangerous_hydra_distance()
    if not hydra_dist or hydra_dist > 5 then
        return false
    end

    return use_ability("Major Destruction",
        "r" .. vector_move(enemy:x_pos(), enemy:y_pos()) .. "\r")
end

function fiery_armour()
    use_ability("Fiery Armour")
end

function plan_resistance()
    if can_drink() and want_resistance() then
        return drink_by_name("resistance")
    end

    return false
end

function plan_magic_points()
    if can_drink() and want_magic_points() then
        return drink_by_name("magic")
    end

    return false
end

function plan_trogs_hand()
    if can_trogs_hand() and want_to_trogs_hand() then
        return use_ability("Trog's Hand")
    end

    return false
end

function plan_cure_bad_poison()
    local hp, mhp = you.hp()
    local dangerous_dot = you.poison_survival() < hp
    if not qw.danger_in_los and not dangerous_dot then
        return false
    end

    if you.poison_survival() <= hp - 60 then
        if drink_by_name("curing") then
            note_decision("EMERGENCY", "(to cure bad poison)")
            return true
        end

        if can_purification() then
            return use_purification()
        end
    end

    return false
end

function plan_cancellation()
    if not qw.danger_in_los or not can_drink() or you.teleporting() then
        return false
    end

    if you.petrifying()
            or you.corrosion() >= 16 + qw.base_corrosion
            or you.corrosion() >= 12 + qw.base_corrosion and hp_is_low(70)
            or in_bad_form() then
        return drink_by_name("cancellation")
    end

    return false
end

function plan_blinking()
    if not in_branch("Zig") or not qw.danger_in_los or not can_read() then
        return false
    end

    local para_danger = false
    for _, enemy in ipairs(qw.enemy_list) do
        if enemy:name() == "floating eye"
                or enemy:name() == "starcursed mass" then
            para_danger = true
        end
    end
    if not para_danger then
        return false
    end

    if count_item("scroll", "blinking") == 0 then
        return false
    end

    local cur_count = 0
    for pos in adjacent_iter(const.origin) do
        local mons = get_monster_at(pos)
        if mons and mons:name() == "floating eye" then
            cur_count = cur_count + 3
        elseif mons and mons:name() == "starcursed mass" then
            cur_count = cur_count + 1
        end
    end
    if cur_count >= 2 then
        return false
    end

    local best_count = 0
    local best_pos
    for pos in square_iter(const.origin) do
        if is_traversable_at(pos)
                and not is_solid_at(pos)
                and not get_monster_at(pos)
                and is_safe_at(pos)
                and not view.withheld(pos.x, pos.y)
                and you.see_cell_no_trans(pos.x, pos.y) then
            local count = 0
            for dpos in adjacent_iter(pos) do
                if supdist(dpos) <= qw.los_radius then
                    local mons = get_monster_at(dpos)
                    if mons and mons:is_enemy()
                            and mons:name() == "floating eye" then
                        count = count + 3
                    elseif mons
                            and mons:is_enemy()
                            and mons:name() == "starcursed mass" then
                        count = count + 1
                    end
                end
            end
            if count > best_count then
                best_count = count
                best_pos = pos
            end
        end
    end
    if best_count >= cur_count + 2 then
        local scroll = find_item("scroll", "blinking")
        return read_scroll(scroll,  vector_move(best_x, best_y) .. ".")
    end
    return false
end

function can_drink_heal_wounds()
    if not can_drink()
            or not find_item("potion", "heal wounds")
            or you.mutation("no potion heal") > 1 then
        return false
    end

    local armour = get_slot_item("body")
    if armour and armour:name():find("NoPotionHeal") then
        return false
    end

    return true
end

function heal_general()
    if can_ru_healing() and drain_level() <= 1 then
        return use_ru_healing()
    end

    if can_ely_healing() then
        return use_ely_healing()
    end

    if can_drink_heal_wounds() then
        if drink_by_name("heal wounds") then
            return true
        end
    end

    -- If heal wounds isn't identified yet, try any unidentified potion.
    -- This catches the case where we HAVE heal wounds but can't find it
    -- by name because it's unidentified.
    if can_drink() and not item_type_is_ided("potion", "heal wounds")
            and quaff_unided_potion() then
        return true
    end

    -- Use curing potions as backup healing when heal wounds is unavailable.
    -- Curing heals 5-9 HP. At low XL this is significant; at high XL it's
    -- still better than nothing when we have no heal wounds.
    local use_curing = you.xl() < 12
        or (not find_item("potion", "heal wounds") and hp_is_low(33))
    if use_curing and can_drink() then
        if drink_by_name("curing") then
            note_decision("HEAL", "(curing for emergency HP)")
            return true
        end
    end

    if can_ru_healing() then
        return use_ru_healing()
    end

    if can_ely_healing() then
        return use_ely_healing()
    end

    return false
end

function plan_heal_wounds()
    if want_to_heal_wounds() then
        note_decision("HEAL", "Heal wanted, attempting heal_general()")
        local result = heal_general()
        if result then
            qw.stats.heals = qw.stats.heals + 1
        else
            note_decision("HEAL", "heal_general() failed")
        end
        return result
    end

    return false
end

function can_haste()
    return can_drink()
        and not you.berserk()
        and you.god() ~= "Cheibriados"
        and you.race() ~= "Formicid"
        and find_item("potion", "haste")
end

function plan_haste()
    if can_haste() and want_to_haste() then
        return drink_by_name("haste")
    end

    return false
end

function can_might()
    return can_drink() and find_item("potion", "might")
end

function want_to_might()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.mighty()
            or you.teleporting()
            or will_kite() then
        return false
    end

    local result = assess_enemies()
    if result.threat >= high_threat_level() then
        return true
    elseif result.scary_enemy then
        attack = result.scary_enemy:best_player_attack()
        return attack and attack.uses_might
    end

    return false
end

function plan_might()
    if can_might() and want_to_might() then
        return drink_by_name("might")
    end

    return false
end

function plan_berserk()
    if not want_to_berserk() then
        return false
    end

    if can_berserk() then
        -- In extreme danger, pre-read teleport as safety net. The delayed
        -- teleport fires after berserk ends. Next turn the cascade re-runs
        -- and berserks (you.teleporting() doesn't block berserk).
        if not you.teleporting() and can_teleport() then
            local result = assess_enemies(const.duration.available)
            if result.threat >= extreme_threat_level() then
                note_decision("EMERGENCY", "PRE-BERSERK TELEPORT")
                return teleport()
            end
        end

        return use_ability("Berserk")
    end

    note_decision("BERSERK", "Berserk wanted but can't:"
        .. " can_invoke=" .. tostring(can_invoke())
        .. " cooldown=" .. tostring(you.status("on berserk cooldown"))
        .. " mesmerised=" .. tostring(you.mesmerised())
        .. " afraid=" .. tostring(you.status("afraid"))
        .. " piety_rank=" .. tostring(you.piety_rank()))
    return false
end

function plan_heroism()
    if can_heroism() and want_to_heroism() then
        return use_ability("Heroism")
    end

    return false
end

function plan_recall()
    if can_recall() and want_to_recall() then
        if you.god() == "Yredelemnul" then
            return use_ability("Recall Undead Slaves", "", true)
        else
            return use_ability("Recall Orcish Followers", "", true)
        end
    end

    return false
end

function plan_recall_ancestor()
    if can_recall_ancestor() and check_elliptic(qw.los_radius) then
        return use_ability("Recall Ancestor", "", true)
    end

    return false
end

function plan_finesse()
    if can_finesse() and want_to_finesse() then
        return use_ability("Finesse")
    end

    return false
end

function plan_slouch()
    if can_slouch() and want_to_slouch() then
        return use_ability("Slouch")
    end

    return false
end

function plan_drain_life()
    if can_drain_life() and want_to_drain_life() then
        return use_ability("Drain Life")
    end

    return false
end

function plan_fiery_armour()
    if can_fiery_armour() and want_to_fiery_armour() then
        return use_ability("Fiery Armour")
    end

    return false
end

function want_to_brothers_in_arms()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.teleporting()
            or check_brothers_in_arms(4) then
        return false
    end

    local result = assess_enemies(const.duration.available)

    -- Proactive: summon ally when threat is high. Brothers in Arms is
    -- positioned before Berserk in cascade, so the ally arrives first.
    -- On dangerous levels, summon at lower threshold — allies are free tanks.
    local bia_threshold = high_threat_level() + 5
    if in_branch("Depths") or in_branch("Zot")
            or (in_branch("Vaults") and at_branch_end("Vaults")) then
        bia_threshold = high_threat_level()
    end
    if result.threat >= bia_threshold then
        return true
    end

    -- Reactive: use as alternative during berserk cooldown when the bot
    -- can't berserk but faces significant danger.
    if you.status("on berserk cooldown")
            and result.threat >= high_threat_level() then
        return true
    end

    return false
end

function want_to_slouch()
    return qw.danger_in_los
        and not dangerous_to_attack()
        and not you.teleporting()
        and you.piety_rank() == 6
        and estimate_slouch_damage() >= 6
end

function want_to_drain_life()
    return qw.danger_in_los
        and not dangerous_to_attack()
        and not you.teleporting()
        and count_enemies(qw.los_radius,
            function(mons) return mons:res_draining() == 0 end)
end

function want_to_greater_servant()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.teleporting()
            or you.skill("Invocations") < 12
            or check_greater_servants(4) then
        return false
    end

    if hp_is_low(50) and qw.immediate_danger then
        return true
    end

    local result = assess_enemies()
    if result.threat >= 15 then
        return true
    end

    return false
end

function want_to_cleansing_flame()
    if not qw.danger_in_los or dangerous_to_attack() then
        return false
    end

    local result = assess_enemies(const.duration.active, 2,
        function(mons) return mons:res_holy() <= 0 end)
    if result.scary_enemy and not result.scary_enemy:player_can_attack(1)
            or result.threat >= high_threat_level() and result.count >= 3 then
        return true
    end

    if hp_is_low(50) and qw.immediate_danger then
        local flame_restore_count = count_enemies(2, mons_tso_heal_check)
        return flame_restore_count > count_enemies(1, mons_tso_heal_check)
            and flame_restore_count >= 4
    end

    return false
end

function want_to_divine_warrior()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.teleporting()
            or you.skill("Invocations") < 8
            or check_divine_warriors(4) then
        return false
    end

    if hp_is_low(50) and qw.immediate_danger then
        return true
    end

    local result = assess_enemies()
    if result.threat >= 15 then
        return true
    end
end

function want_to_fiery_armour()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.status("fiery-armoured") then
        return false
    end

    if hp_is_low(50) and qw.immediate_danger then
        return true
    end

    local result = assess_enemies()
    if result.scary_enemy or result.threat >= high_threat_level() then
        return true
    end

    return false
end

function want_to_apocalypse()
    if not qw.danger_in_los or dangerous_to_attack() or you.teleporting() then
        return false
    end

    local dlevel = drain_level()
    local result = assess_enemies()
    if dlevel == 0
                and (result.scary_enemy
                    or result.threat >= high_threat_level())
            or dlevel <= 2 and hp_is_low(50) then
        return true
    end

    return false
end

function bad_corrosion()
    if you.corrosion() == qw.base_corrosion then
        return false
    elseif in_branch("Slime") then
        return you.corrosion() >= 24 + qw.base_corrosion and hp_is_low(70)
    else
        return you.corrosion() >= 12 + qw.base_corrosion and hp_is_low(50)
            or you.corrosion() >= 16 + qw.base_corrosion and hp_is_low(70)
    end
end

function want_to_teleport()
    if you.teleporting() or in_branch("Zig") then
        return false
    end

    if in_bad_form() and not will_flee() then
        return true
    end

    if qw.have_orb and hp_is_low(33) and check_enemies(2) then
        return true
    end

    -- Count teleport scrolls to decide how conservatively to use them.
    local tele_scroll = find_item("scroll", "teleportation")
    local tele_count = tele_scroll and tele_scroll.quantity or 0

    -- Only teleport for hostile summons when we have multiple scrolls.
    if count_hostile_summons(qw.los_radius) > 0
            and you.xl() < 21 and tele_count >= 2 then
        hostile_summons_timer = you.turns()
        return true
    end

    -- Teleport for corrosion only when it's really bad and we can spare one.
    if qw.immediate_danger and bad_corrosion() and tele_count >= 2 then
        return true
    end

    -- At low XL, teleport earlier: small HP pools mean a single hit can kill.
    -- At high XL with few scrolls, be more conservative.
    local tp_threshold
    if you.xl() < 9 then
        tp_threshold = 50
    elseif tele_count <= 1 then
        tp_threshold = 25  -- last scroll: emergency only
    else
        tp_threshold = 40
    end
    if qw.immediate_danger and hp_is_low(tp_threshold) then
        return true
    end

    -- Prefer fleeing over teleporting when we can actually move, but
    -- don't skip teleport when we're stuck (flee path blocked) or when
    -- a scary enemy is adjacent and HP is low — distortion etc. can
    -- one-shot us before we reach stairs.
    if will_flee() then
        local scary = get_scary_enemy(const.duration.available)
        local stuck_fleeing = qw.danger_in_los and hp_is_low(50)
            and scary and check_following_melee_enemies(2)
        if not stuck_fleeing then
            return false
        end
    end

    local enemies = assess_enemies(const.duration.available)
    if enemies.scary_enemy
            and enemies.scary_enemy:threat(const.duration.available) >= 5
            and enemies.scary_enemy:name():find("slime creature")
            and enemies.scary_enemy:name() ~= "slime creature" then
        return true
    end

    if enemies.threat >= extreme_threat_level() then
        return not will_fight_extreme_threat()
    end

    return false
end

function want_to_heal_wounds()
    if want_to_orbrun_heal_wounds() then
        return true
    end

    -- Heal during dangerous DOT even without enemies visible
    local hp, mhp = you.hp()
    local dominated_by_dot = (you.poison_survival() < hp)
        or you.status("on fire")
    if hp_is_low(50) and dominated_by_dot then
        return true
    end

    if not qw.danger_in_los then
        return false
    end

    if can_ely_healing() and hp_is_low(50) and you.piety_rank() >= 5 then
        return true
    end

    -- At low XL, heal earlier: small HP pools mean percentage thresholds
    -- leave dangerously few absolute HP.
    local low_xl = you.xl() < 9
    if qw.immediate_danger then
        return hp_is_low(low_xl and 50 or 40)
    end
    return hp_is_low(low_xl and 35 or 25)
end

function want_resistance()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.teleporting()
            or you.extra_resistant() then
        return false
    end

    for _, enemy in ipairs(qw.enemy_list) do
        if (enemy:has_path_to_melee_player() or enemy:is_ranged(true))
                and (monster_in_list(enemy, fire_resistance_monsters)
                        and you.res_fire() < 3
                    or monster_in_list(enemy, cold_resistance_monsters)
                        and you.res_cold() < 3
                    or monster_in_list(enemy, elec_resistance_monsters)
                        and you.res_shock() < 1
                    or monster_in_list(enemy, pois_resistance_monsters)
                        and you.res_poison() < 1
                    or in_branch("Zig")
                        and monster_in_list(enemy, acid_resistance_monsters)
                        and not you.res_corr()) then
            return true
        end
    end

    return false
end

function want_to_haste()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or you.hasted()
            or you.teleporting()
            or will_kite() then
        return false
    end

    local result = assess_enemies()
    if result.threat >= high_threat_level() then
        return not duration_active("finesse") or you.slowed()
    elseif result.scary_enemy then
        local attack = result.scary_enemy:best_player_attack()
        return attack
            -- We can always use haste if we're slowed().
            and (you.slowed()
                -- Only primary attacks are allowed to use haste.
                or attack.index == 1
                    -- Don't haste if we're already benefiting from Finesse.
                    and not (attack.uses_finesse and duration_active("finesse")))
    end

    return false
end

function want_magic_points()
    if you.race() == "Djinni" then
        return false
    end

    local mp, mmp = you.mp()
    return qw.danger_in_los
        and not dangerous_to_attack()
        and not you.teleporting()
        -- Don't bother restoring MP if our max MP is low.
        and mmp >= 20
        -- No point trying to restore MP with ghost moths around.
        and count_enemies_by_name(qw.los_radius, "ghost moth") == 0
        -- We want and could use these abilities if we had more MP.
        and (can_cleansing_flame(true)
                and not can_cleansing_flame()
                and want_to_cleansing_flame()
            or can_divine_warrior(true)
                and not can_divine_warrior()
                and want_to_divine_warrior())
end

function want_to_trogs_hand()
    if you.regenerating() or you.teleporting() then
        return false
    end

    -- Always use in Abyss when missing significant HP.
    local hp, mhp = you.hp()
    if in_branch("Abyss") and mhp - hp >= 30 then
        return true
    end

    if not qw.danger_in_los or dangerous_to_attack() then
        return false
    end

    -- Use against known dangerous casters (original behavior).
    if check_enemies_in_list(qw.los_radius, hand_monsters) then
        return true
    end

    -- Use against any unique — they're always more dangerous than normal
    -- monsters and the regen helps survive unexpected burst damage.
    for _, enemy in ipairs(qw.enemy_list) do
        if enemy.minfo:is_unique() and enemy:distance() <= qw.los_radius then
            return true
        end
    end

    -- Proactively buff when facing significant threat. Trog's Hand is
    -- cheap and stacks with Berserk, so using it early is always good.
    -- This fires before Berserk in the cascade, setting up the combo.
    local result = assess_enemies(const.duration.available)
    if result.threat >= high_threat_level() then
        return true
    end

    -- Use when HP is dropping and enemies are present.
    if hp_is_low(70) and result.threat >= max(3, high_threat_level() * 0.5) then
        return true
    end

    return false
end

function check_berserkable_enemies()
    local filter = function(enemy, moveable)
        return enemy:player_has_path_to_melee()
    end
    return check_enemies(2, filter)
end

-- Estimate whether we can kill all visible enemies within berserk's
-- ~12 turns. Returns true if total enemy HP / berserk DPS <= 12.
function can_kill_in_berserk()
    local total_hp = 0
    local count = 0
    local dps_target = nil
    for _, enemy in ipairs(qw.enemy_list) do
        if enemy:distance() <= qw.los_radius
                and (enemy:is_ranged(true)
                    or enemy:has_path_to_melee_player()) then
            total_hp = total_hp + enemy:hp()
            count = count + 1
            if not dps_target then
                dps_target = enemy
            end
        end
    end

    if count == 0 or not dps_target then
        return false
    end

    -- Calculate berserk DPS: damage/delay with berserk factored in.
    -- const.duration.available already includes berserk in calculations.
    local dps = player_attack_damage(dps_target, 1,
            const.duration.available)
        / player_attack_delay(1, const.duration.available)

    if dps <= 0 then
        return false
    end

    -- Conservative estimate: berserk lasts 10-20 turns, use 12 as cutoff.
    -- If we can't kill everything in 12 turns, berserk may end mid-fight.
    local turns_needed = total_hp / dps
    return turns_needed <= 12
end

function want_to_berserk()
    if not qw.danger_in_los or dangerous_to_melee() or you.berserk() then
        return false
    end

    -- Don't berserk if Trog's Hand regen is handling the situation
    -- and HP isn't critical.
    if you.regenerating() and not hp_is_low(33) then
        return false
    end

    -- Emergency berserk: HP critical with enemies in melee range.
    -- On D:1 where there's no upstairs to flee to, berserk earlier.
    local berserk_threshold = qw.can_flee_upstairs and 33 or 50
    if hp_is_low(berserk_threshold) and check_berserkable_enemies() then
        -- At low XL with only one adjacent enemy and escape available, prefer
        -- fleeing over berserking to avoid cooldown deaths.
        if you.xl() < 5 and qw.can_flee_upstairs
                and count_enemies(2) <= 1 then
            return false
        end
        return true
    end

    -- Always berserk against nasty invisible casters.
    if invis_monster and nasty_invis_caster then
        return true
    end

    local result = assess_enemies(const.duration.available, 2)

    -- Berserk if a scary enemy specifically benefits from berserk damage.
    -- Conservative berserk only at high XL where the bot should have
    -- consumables. At low XL, berserk freely — it's the main survival tool.
    local have_escape = find_item("scroll", "teleportation")
        or find_item("potion", "heal wounds")
    local conservative = you.xl() >= 15 and not have_escape
    if result.scary_enemy then
        local attack = result.scary_enemy:best_player_attack()
        if attack and attack.uses_berserk
                and can_kill_in_berserk()
                and (not conservative or hp_is_low(50)) then
            return true
        end
    end

    -- High threat with immediate danger — but only if we can finish
    -- the fight within berserk duration. At high XL without escape items,
    -- only berserk when HP is already low.
    if qw.immediate_danger
            and result.threat >= high_threat_level()
            and can_kill_in_berserk()
            and (not conservative or hp_is_low(50)) then
        return true
    end

    return false
end

function want_to_finesse()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or duration_active("finesse")
            or you.teleporting()
            or will_kite() then
        return false
    end

    local result = assess_enemies()
    if result.threat >= high_threat_level() then
        return true
    elseif result.scary_enemy then
        attack = result.scary_enemy:best_player_attack()
        return attack and attack.uses_finesse
    end

    return false
end

function want_to_heroism()
    if not qw.danger_in_los
            or dangerous_to_attack()
            or duration_active("heroism")
            or you.teleporting()
            or will_kite() then
        return false
    end

    local result = assess_enemies()
    if result.threat >= high_threat_level() then
        return true
    elseif result.scary_enemy then
        local attack = result.scary_enemy:best_player_attack()
        return attack and attack.uses_heroism
    end

    return false
end

function want_to_recall()
    if qw.immediate_danger and hp_is_low(66) then
        return false
    end

    if you.race() == "Djinni" then
        local hp, mhp = you.hp()
        return hp == mhp
    else
        local mp, mmp = you.mp()
        return mp == mmp
    end
end

function plan_full_inventory_panic()
    if qw.danger_in_los or not qw.position_is_safe then
        return false
    end

    if qw_full_inventory_panic and free_inventory_slots() == 0 then
        panic("Inventory is full!")
    else
        return false
    end
end

function plan_cure_confusion()
    if not you.confused()
            or not can_drink()
            or not (qw.danger_in_los
                or options.autopick_on
                or qw.position_is_cloudy)
            or view.cloud_at(0, 0) == "noxious fumes"
                and not meph_immune() then
        return false
    end

    if drink_by_name("curing") then
        note_decision("EMERGENCY", "(to cure confusion)")
        return true
    end

    if can_purification() then
        return use_purification()
    end

    if not item_type_is_ided("potion", "curing") then
        return quaff_unided_potion()
    end

    return false
end

-- This plan is necessary to make launcher qw try to escape from the net so
-- that it can resume attacking instead of trying post-attack plans. It should
-- come after any emergency plans that we could still execute while caught.
function plan_escape_net()
    if not qw.danger_in_los or not you.caught() then
        return false
    end

    -- Can move in any direction to escape nets, regardless of what's there.
    return move_to({ x = 0, y = 1 })
end

function plan_wait_confusion()
    if not you.confused()
            or not (qw.danger_in_los or options.autopick_on)
            or qw.position_is_cloudy then
        return false
    end

    wait_one_turn()
    return true
end

function plan_non_melee_berserk()
    if not you.berserk() or not using_ranged_weapon() then
        return false
    end

    if unable_to_move() or dangerous_to_move() then
        wait_one_turn()
        return true
    end

    local result = best_move_towards_positions(qw.flee_positions)
    if result then
        return move_to(result.move)
    end

    wait_one_turn()
    return true
end

-- Curing poison/confusion with purification is handled elsewhere.
function plan_special_purification()
    if not can_purification() then
        return false
    end

    if you.slowed() and not qw.slow_aura or you.petrifying() then
        return use_purification()
    end

    local str, mstr = you.strength()
    local int, mint = you.intelligence()
    local dex, mdex = you.dexterity()
    if str < mstr
            and (str < mstr - 5 or str < 3)
                or int < mint and int < 3
                or dex < mdex and (dex < mdex - 8 or dex < 3) then
        return use_purification()
    end

    return false
end

function can_dig_to(pos)
    local positions = spells.path("Dig", pos.x, pos.y, false)
    local hit_grate = false
    for i, coords in ipairs(positions) do
        local dpos = { x = coords[1], y = coords[2] }
        if not hit_grate
                and view.feature_at(dpos.x, dpos.y) == "iron_grate" then
            hit_grate = true
        end

        if positions_equal(pos, dpos) then
            return hit_grate
        end
    end
    return false
end

function plan_tomb2_arrival()
    if not tomb2_entry_turn
            or you.turns() >= tomb2_entry_turn + 5
            or c_persist.did_tomb2_buff then
        return false
    end

    if not you.hasted() then
        return haste()
    elseif not you.status("attractive") then
        if drink_by_name("attraction") then
            c_persist.did_tomb2_buff = true
            return true
        end

        return false
    end
end

function plan_tomb3_arrival()
    if not tomb3_entry_turn
            or you.turns() >= tomb3_entry_turn + 5
            or c_persist.did_tomb3_buff then
        return false
    end

    if not you.hasted() then
        return haste()
    elseif not you.status("attractive") then
        if drink_by_name("attraction") then
            c_persist.did_tomb3_buff = true
            return true
        end

        return false
    end
end

function plan_dig_grate()
    local wand = find_item("wand", "digging")
    if not wand or not can_evoke() then
        return false
    end

    for _, enemy in ipairs(qw.enemy_list) do
        if not map_is_reachable_at(enemy:map_pos())
                and enemy:should_dig_unreachable() then
            return evoke_targeted_item(wand, enemy:pos())
        end
    end

    return false
end

function set_plan_emergency()
    plans.emergency = cascade {
        {plan_stairdance_up, "stairdance_up"},
        {plan_lugonu_exit_abyss, "lugonu_exit_abyss"},
        {plan_exit_abyss, "exit_abyss"},
        {plan_go_down_abyss, "go_down_abyss"},
        {plan_pick_up_rune, "pick_up_rune"},
        {plan_early_flee, "early_flee"},
        {plan_special_purification, "special_purification"},
        {plan_cure_confusion, "cure_confusion"},
        {plan_cancellation, "cancellation"},
        {plan_teleport, "teleport"},
        {plan_remove_terrible_rings, "remove_terrible_rings"},
        {plan_cure_bad_poison, "cure_bad_poison"},
        {plan_blinking, "blinking"},
        {plan_drain_life, "drain_life"},
        {plan_heal_wounds, "heal_wounds"},
        {plan_trogs_hand, "trogs_hand"},
        {plan_brothers_in_arms, "brothers_in_arms"},
        {plan_resistance, "resistance"},
        {plan_might, "might"},
        {plan_haste, "haste"},
        {plan_berserk, "berserk"},
        {plan_escape_net, "escape_net"},
        {plan_move_towards_abyssal_rune, "move_towards_abyssal_rune"},
        {plan_move_towards_abyssal_feature, "move_towards_abyssal_feature"},
        {plan_explore_near_runelights, "explore_near_runelights"},
        {plan_priority_tactical_step, "priority_tactical_step"},
        {plan_wait_confusion, "wait_confusion"},
        {plan_zig_fog, "zig_fog"},
        {plan_flee, "flee"},
        {plan_tactical_step, "tactical_step"},
        {plan_tomb2_arrival, "tomb2_arrival"},
        {plan_tomb3_arrival, "tomb3_arrival"},
        {plan_magic_points, "magic_points"},
        {plan_cleansing_flame, "try_cleansing_flame"},
        {plan_divine_warrior, "divine_warrior"},
        {plan_greater_servant, "greater_servant"},
        {plan_apocalypse, "try_apocalypse"},
        {plan_slouch, "try_slouch"},
        {plan_hydra_destruction, "try_hydra_destruction"},
        {plan_grand_finale, "grand_finale"},
        {plan_fiery_armour, "fiery_armour"},
        {plan_dig_grate, "try_dig_grate"},
        {plan_wield_weapon, "wield_weapon"},
        {plan_finesse, "finesse"},
        {plan_heroism, "heroism"},
        {plan_recall, "recall"},
        {plan_recall_ancestor, "try_recall_ancestor"},
        {plan_recite, "try_recite"},
    }
end
