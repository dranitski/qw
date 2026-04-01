---------------------------------------------
-- ready function and main coroutine

function stop()
    qw.automatic = false
    unset_options()
end

function start()
    qw.automatic = true
    set_options()
    ready()
end

function startstop()
    if qw.automatic then
        stop()
    else
        start()
    end
end

function panic(msg)
    qw_assert(false, msg)
end

function set_options()
    crawl.setopt("pickup_mode = multi")
    crawl.setopt("message_colour += mute:Search for what")
    crawl.setopt("message_colour += mute:Can't find anything")
    crawl.setopt("message_colour += mute:Drop what")
    crawl.setopt("message_colour += mute:Okay. then")
    crawl.setopt("message_colour += mute:Use which ability")
    crawl.setopt("message_colour += mute:Read which item")
    crawl.setopt("message_colour += mute:Drink which item")
    crawl.setopt("message_colour += mute:not good enough")
    crawl.setopt("message_colour += mute:Attack whom")
    crawl.setopt("message_colour += mute:move target cursor")
    crawl.setopt("message_colour += mute:Aim:")
    crawl.setopt("message_colour += mute:You reach to attack")
    crawl.enable_more(false)
end

function unset_options()
    crawl.setopt("pickup_mode = auto")
    crawl.setopt("message_colour -= mute:Search for what")
    crawl.setopt("message_colour -= mute:Can't find anything")
    crawl.setopt("message_colour -= mute:Drop what")
    crawl.setopt("message_colour -= mute:Okay. then")
    crawl.setopt("message_colour -= mute:Use which ability")
    crawl.setopt("message_colour -= mute:Read which item")
    crawl.setopt("message_colour -= mute:Drink which item")
    crawl.setopt("message_colour -= mute:not good enough")
    crawl.setopt("message_colour -= mute:Attack whom")
    crawl.setopt("message_colour -= mute:move target cursor")
    crawl.setopt("message_colour -= mute:Aim:")
    crawl.setopt("message_colour -= mute:You reach to attack")
    crawl.enable_more(true)
end

function qw_main()
    local t0 = you.real_time_ms and you.real_time_ms() or 0
    turn_update()
    local t1 = you.real_time_ms and you.real_time_ms() or 0

    if qw.max_realtime and you.real_time() >= qw.max_realtime then
        note_decision("QUIT", "QUITTING (real-time limit: " .. you.real_time() .. "s)")
        goal_status = "Quit"
    end

    -- Skip Lua-side save interval when C++ non-exiting checkpoints are active
    -- (crawl.save_checkpoint sets up periodic saves in world_reacts).
    if qw.save_interval and qw.save_interval > 0
            and not crawl.save_checkpoint
            and you.turns() > 0
            and goal_status ~= "Save" and goal_status ~= "Quit" then
        local last = c_persist.last_save_turn or 0
        local next_target = last + qw.save_interval
        -- Handle first save: align to the interval grid
        if last == 0 then
            next_target = qw.save_interval
        end
        if you.turns() >= next_target then
            c_persist.last_save_turn = you.turns()
            note_decision("SAVE", "SAVING (interval checkpoint: turn " .. you.turns() .. ")")
            goal_status = "Save"
        end
    end

    if qw.time_passed and qw.single_step then
        stop()
    end

    local did_restart = qw.restart_cascade
    local t2 = you.real_time_ms and you.real_time_ms() or 0
    if qw.automatic then
        crawl.flush_input()
        crawl.more_autoclear(true)
        if qw.have_message then
            plan_message()
        else
            plans.turn()
        end
    end
    local t3 = you.real_time_ms and you.real_time_ms() or 0

    -- Profiling: accumulate and report every 200 turns (ms precision)
    if t3 > 0 then
        if not qw.perf then
            qw.perf = { update = 0, cascade = 0, count = 0, start = t0 }
        end
        qw.perf.update = qw.perf.update + (t1 - t0)
        qw.perf.cascade = qw.perf.cascade + (t3 - t2)
        qw.perf.count = qw.perf.count + 1
        if qw.perf.count % 200 == 0 then
            local elapsed = t3 - qw.perf.start
            local lua_time = qw.perf.update + qw.perf.cascade
            local other = elapsed - lua_time
            note_decision("PERF", string.format(
                "%d turns in %dms: update=%dms cascade=%dms other=%dms (lua %.0f%%)",
                qw.perf.count, elapsed, qw.perf.update, qw.perf.cascade,
                other, lua_time / elapsed * 100))
        end
    end
    -- restart_cascade must remain true for the entire move cascade while we're
    -- restarting.
    if did_restart then
        qw.restart_cascade = false
    end
end

function run_qw()
    if qw.abort then
        magic(control('q') .. "yes\r")
        return
    end

    if qw.update_coroutine == nil then
        qw.update_coroutine = coroutine.create(qw_main)
    end

    local okay, err = coroutine.resume(qw.update_coroutine)
    if not okay then
        qw_assert(false, "Error in coroutine: " .. err)
    end

    if coroutine.status(qw.update_coroutine) == "dead" then
        qw.update_coroutine = nil
        qw.do_dummy_action = qw.do_dummy_action == nil and qw.restart_cascade
        -- Invariant: a completed coroutine must have produced an action
        -- (via magic/do_command/do_targeted_command) or be restarting the
        -- cascade. If neither, the cascade fell through without acting.
        qw_assert(qw.did_magic or qw.restart_cascade or qw.do_dummy_action,
            "coroutine finished without producing any action "
            .. "(no magic(), no restart_cascade)")
    else
        qw.do_dummy_action = qw.do_dummy_action == nil
    end

    local memory_count = collectgarbage("count")
    if debug_channel("throttle") and qw.throttle then
        note_decision("MEMORY", "Memory count is " .. tostring(memory_count))
    end

    if qw.max_memory and memory_count > qw.max_memory then
        collectgarbage("collect")

        qw_assert(collectgarbage("count") <= qw.max_memory,
            "memory usage above " .. tostring(qw.max_memory)
            .. "KB after GC (at " .. tostring(collectgarbage("count")) .. "KB)")
    end
    qw.throttle = false

    if qw.do_dummy_action and not qw.did_magic then
        crawl.process_keys(":" .. string.char(27) .. string.char(27))
    end
    qw.do_dummy_action = nil
    qw.did_magic = false
end

function ready()
    run_qw()
end

function hit_closest()
    startstop()
end
