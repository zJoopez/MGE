-- Atmo Play's debug log, DEV ONLY: not in either release zip (tools/package.ps1). atmoplay.lua loads it when the
-- file is there, and runtime.lua calls it through NS.DebugLog only then, so the releases run without it.
-- /atmoplay log turns it on and off: every hook, every frame's planned pool moves and every engine object call
-- go to data/script/atmoplay_debug.log, written (and closed) before the calls run, so after a crash the file ends
-- at what was happening. It made the replay crashes findable (docs/atmo-play-plan.md)

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY)

local Runtime = NS.Runtime -- loaded first: its state, say
local Dynamics = NS.Dynamics

---@class AtmoPlayDebugLog
local DebugLog = {
    PATH = "atmoplay_debug.log", -- data/script
    on = false,
    loggedFrame = nil, ---@type string? the last frame summarized
}

local clock = os and os.clock or function() return 0 end

---@param lines string[]
local function write(lines)
    if not DebugLog.on then return end
    local file = Files.Open(DebugLog.PATH, FILES_MODE_APPEND)
    if not file.data then return end
    for _, line in ipairs(lines) do file:writeLine(line) end
    file:close()
end

---@param ws table get_world_state()
---@return string
local function worldLine(ws)
    return string.format("frame %s replay %s game_frame %s gameover %s paused %s winner %s", tostring(ws.match_frame),
        tostring(ws.replay_mode), tostring(ws.game_frame), tostring(ws.gameover_frame), tostring(ws.game_paused),
        tostring(ws.winner))
end

---A hook ran (match_begin, leave_game, end_game, new_game, unload)
---@param event string
function DebugLog.event(event)
    if not DebugLog.on then return end
    write({ string.format("%.3f %s: %s mod %s", clock(), event, worldLine(get_world_state()),
        tostring(get_game_rules().mod)) })
end

---The driver's planned moves for a frame (driver.lua's onDrive), before they're made
---@param changes AtmoPlayPoolChange[]
---@param ws table
function DebugLog.onDrive(changes, ws)
    if not DebugLog.on then return end
    local lines = { string.format("%.3f drive: %s, %d changes", clock(), worldLine(ws), #changes) }
    for _, change in ipairs(changes) do
        local c = change.collider
        if c then
            lines[#lines + 1] = string.format("  place %d -> %s %s at %.2f %.2f %.2f", change.entry.id - 1, c.name,
                c.shape, c.pos[1], c.pos[2], c.pos[3])
        else
            lines[#lines + 1] = string.format("  park %d", change.entry.id - 1)
        end
    end
    write(lines)
end

---------------------------------------------------------------------------------------------------- trace

-- The engine's object setters, traced while the log is on: each call is a log line, written at the end of the
-- hook that made it (or every 500 lines), so after a crash the log ends at the last hook that ran. The
-- originals are kept in a global, so a restart never wraps a wrapper
local TRACED = { "set_obj_pos", "set_obj_sides", "set_obj_rot", "set_obj_rot_m", "set_obj_linear_vel",
    "set_obj_angular_vel", "set_obj_mass", "set_obj_bounce", "set_obj_flag", "set_obj_color", "set_obj_vis",
    "set_obj_force" }
local trace = {} ---@type string[] lines not written yet

---Writes the traced lines (the end of each hook)
function DebugLog.flush()
    if #trace == 0 then return end
    write(trace)
    trace = {}
end

local function traceArg(v)
    if type(v) ~= "number" then return tostring(v) end
    if v == math.floor(v) and math.abs(v) < 1e9 then return string.format("%d", v) end
    return string.format("%.3f", v)
end

---@param on boolean
local function setTrace(on)
    -- originals by name, and our wrappers: a global that isn't one of ours is the engine's (a restart that
    -- didn't turn the log off left wrappers that a new trace must not take for originals)
    ATMOPLAY_TRACED = ATMOPLAY_TRACED or { originals = {}, wrappers = {} }
    local traced = ATMOPLAY_TRACED
    for _, name in ipairs(TRACED) do
        local current = rawget(_G, name)
        if current and not traced.wrappers[current] then traced.originals[name] = current end
        local original = traced.originals[name]
        if original then
            if on then
                local wrapper = function(...)
                    local parts = { name }
                    for i = 1, select("#", ...) do parts[#parts + 1] = traceArg((select(i, ...))) end
                    trace[#trace + 1] = "  " .. table.concat(parts, " ")
                    if #trace >= 500 then DebugLog.flush() end
                    return original(...)
                end
                traced.wrappers[wrapper] = true
                _G[name] = wrapper
            else
                _G[name] = original
            end
        end
    end
    if not on then ATMOPLAY_TRACED = nil end
end

---Once per new frame (draw2d): where the pool objects are. How many sit at 0,0,0 (RPH saw objects moved before
---the first move teleported there in that replay) and every dynamic pool object off its parking spot
---@param ws table
function DebugLog.frame(ws)
    local loaded = Runtime.state.loaded
    local key = tostring(ws.replay_mode) .. ":" .. tostring(ws.match_frame)
    if not (DebugLog.on and loaded and loaded.file) or key == DebugLog.loggedFrame then return end
    DebugLog.loggedFrame = key
    local atOrigin, off = 0, {}
    local function check(object, dynamic)
        local x, y, z = get_obj_pos(object.id - 1)
        if not x then return end
        if math.abs(x) + math.abs(y) + math.abs(z) < 0.01 then atOrigin = atOrigin + 1 end
        if dynamic and math.abs(z - Dynamics.PARK_Z) > Dynamics.PARKED then -- not at the parking height
            off[#off + 1] = string.format("%d@%.2f,%.2f,%.2f", object.id - 1, x, y, z)
        end
    end
    for _, object in ipairs(loaded.file.pool or {}) do check(object, false) end
    for _, object in ipairs(loaded.file.dynamic or {}) do check(object, true) end
    trace[#trace + 1] = string.format("%.3f objects: %s; %d pool objects at 0,0,0; %d dynamic off the platform: %s",
        clock(), worldLine(ws), atOrigin, #off, table.concat(off, " "))
end

---------------------------------------------------------------------------------------------------- on / off

---/atmoplay log: on (a new log file) or off
function DebugLog.toggle()
    DebugLog.on = not DebugLog.on
    DebugLog.loggedFrame = nil
    setTrace(DebugLog.on) -- every object call goes in too
    if DebugLog.on then
        local file = Files.Open(DebugLog.PATH, FILES_MODE_WRITE)
        if file.data then
            local loaded = Runtime.state.loaded
            file:writeLine("Atmo Play debug log; " .. tostring(loaded and loaded.name or "no playable mod"))
            file:close()
        end
        Runtime.say("logging every frame and object call to data/script/" .. DebugLog.PATH ..
            " (slow; /atmoplay log again stops it)")
    else
        Runtime.say("log stopped")
    end
end

---Atmo Play quits: the engine's own setters back
function DebugLog.stop()
    if not DebugLog.on then return end
    DebugLog.flush()
    DebugLog.on = false
    setTrace(false)
end

---------------------------------------------------------------------------------------------------- status

local function say(text) Runtime.say(text) end

function DebugLog.status()
    local state = Runtime.dev.state
    local Driver = NS.Driver
    local loaded = state.loaded
    if not loaded then
        say("running; " .. tostring(state.modName) .. " isn't a playable mod")
        return
    end
    if loaded.drawOnly then
        say(loaded.name .. ": a drawn mod, its atmo " .. (loaded.drawn and "drawn" or "not drawn") .. " (no pools)")
        return
    end
    say(string.format("%s: %d/%d pool objects in use, %d solid atmo objects", loaded.name,
        Driver.active(loaded.driver), #loaded.pool.entries, loaded.stats.collidable))
    if state.drawer then
        say(string.format("drawing: Atmo Play %d shapes (%d on screen last frame), the game %d", state.drawer.count,
            state.drawer.drawn, state.drawer.left or 0))
    end
    if loaded.dynamics then
        local carried, props, flying = Dynamics.counts(loaded.dynamics)
        say(string.format("props: %d of %d carried by %d dynamic pool objects, %d flying drawn (flight %s)", carried,
            props, #loaded.dynamics.entries, flying, Runtime.settings.flight))
        local misses = loaded.dynamics.replayMisses
        if misses and misses.far + misses.none > 0 then
            say(string.format("this replay: %d takes found only by a wider search, %d not found (its props flew " ..
                "elsewhere than in the fight: recorded with another version or flight level?)", misses.far, misses.none))
        end
    end
end

---------------------------------------------------------------------------------------------------- timing

-- /atmoplay time: TIMING_FRAMES drawn frames measured (Runtime.measure is set meanwhile), then one report. Each part's
-- average and worst in ms: the props (their flights, takes and releases), moving the props' drawn copies, the static
-- pool, Atmo Play's drawing and the game drawing the atmo (its draw3d loop over every atmo element, Atmospheres;
-- timed by wrapping UIElement3D.drawVisuals while it measures). os.clock: wall time on Windows
DebugLog.TIMING_FRAMES = 300

local timing = nil

local function addTime(part, ms)
    part.sum, part.max = part.sum + ms, math.max(part.max, ms)
end

local function stopTiming()
    if not timing then return end
    local U = rawget(_G, "UIElement3D")
    if timing.origDraw and U then U.drawVisuals = timing.origDraw end
    timing = nil
    Runtime.measure = nil
end

local function reportTiming()
    local t, n = timing, timing.frames
    local state = Runtime.dev.state
    local seconds = os.clock() - t.started
    local function line(name, part)
        return string.format("%s %.2f ms (worst %.1f)", name, part.sum / n, part.max)
    end
    local flying = state.loaded and state.loaded.dynamics and select(3, Dynamics.counts(state.loaded.dynamics)) or 0
    say(string.format("%d frames, ~%.0f fps, flight %s, %d flying now:", n, n / math.max(seconds, 1e-6),
        Runtime.settings.flight, flying))
    say(line("props", t.props) .. ", " .. line("their copies", t.copies) .. ", " .. line("static pool", t.pool))
    local ownLine = ""
    if t.draws > 0 then
        ownLine = ", " .. line("Atmo Play drawing", { sum = t.own.sum, max = t.own.max }):gsub("%(worst",
            string.format("(%.0f shapes of %d a frame, worst", t.shapes / t.draws, state.drawer and state.drawer.count or 0))
    end
    say(line("the game drawing the atmo", t.atmo) .. ownLine .. string.format(" (%.2f ms a frame in all)",
        (t.props.sum + t.copies.sum + t.pool.sum + t.atmo.sum + t.own.sum) / n))
    stopTiming()
end

local function startTiming()
    stopTiming()
    timing = { frames = 0, started = os.clock(), props = { sum = 0, max = 0 }, copies = { sum = 0, max = 0 },
        pool = { sum = 0, max = 0 }, atmo = { sum = 0, max = 0 }, own = { sum = 0, max = 0 }, shapes = 0, draws = 0 }
    local U = rawget(_G, "UIElement3D")
    if U and type(U.drawVisuals) == "function" then
        local orig = U.drawVisuals
        timing.origDraw = orig
        U.drawVisuals = function(object, globalid)
            local A = rawget(_G, "Atmospheres")
            local gid = type(object) == "table" and (object.globalid or globalid) or object
            if timing and A and gid == A.Globalid then
                local t = os.clock()
                orig(object, globalid)
                addTime(timing.atmo, (os.clock() - t) * 1000)
                return
            end
            return orig(object, globalid)
        end
    end
    Runtime.measure = {
        frame = function(poolMs, propsMs, copiesMs)
            if not timing then return end
            addTime(timing.pool, poolMs)
            addTime(timing.props, propsMs)
            addTime(timing.copies, copiesMs)
            timing.frames = timing.frames + 1
            if timing.frames >= DebugLog.TIMING_FRAMES then reportTiming() end
        end,
        own = function(ms, shapes)
            if not timing then return end
            addTime(timing.own, ms)
            timing.shapes, timing.draws = timing.shapes + shapes, timing.draws + 1
        end,
        stop = stopTiming,
    }
    say("timing the next " .. DebugLog.TIMING_FRAMES .. " frames: play or watch as usual")
end

---------------------------------------------------------------------------------------------------- the command

-- /atmoplay [status | reload | time | draw own | draw game | flight <level> | ghosts on | off | log | quit]: dev builds
-- only (this file isn't in the release zip). Players use the window
function DebugLog.command(text)
    local word, rest = tostring(text or ""):match("^%s*(%S+)%s*(.-)%s*$")
    if word ~= "atmoplay" then return end
    local key, value = rest:match("^(%S*)%s*(.-)$")
    local state = Runtime.dev.state
    if key == "" or key == "status" then
        DebugLog.status()
    elseif key == "reload" then
        Runtime.dev.reload()
    elseif key == "draw" and Runtime.DRAW_MODES[value] then
        Runtime.settings.draw = value
        Runtime.saveSettings()
        Runtime.dev.redraw()
        say("draw " .. value)
    elseif key == "time" then
        if not state.loaded or state.loaded.drawOnly then say("time: load a playable mod first") else startTiming() end
    elseif key == "flight" and Dynamics.level(value) == value then
        Runtime.setFlight(value)
        say("flight " .. value)
    elseif key == "ghosts" and (value == "on" or value == "off") then
        Runtime.setGhosts(value == "on")
        say("ghosts " .. value)
    elseif key == "log" then
        DebugLog.toggle()
    elseif key == "quit" then
        Runtime.stop()
    else
        say("/atmoplay [status | reload | time | draw own|game | flight simple|shapes|full | ghosts on|off | log | quit]")
    end
    return 1
end

NS.DebugLog = DebugLog
return DebugLog
