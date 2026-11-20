-- In-game probe (docs/atmo-play-plan.md): WHEN to move the pool so the game's own replay (EOBJ lines, script off)
-- reproduces the fight exactly. atmoplay_native_probe.lua found: the pool placed in match_begin replays
-- exactly (written under FRAME 0); moves made later in enter_frame of frame f are written under FRAME f+1,
-- so the replay applies them one step late (saturated pool: off from frame 90, max 0.11). Moves made
-- between physics steps (draw2d) may be written under the step they affect: then the replay would be exact.
-- Three fights, each replayed with the script off, cache 0 and cache 2:
--   baseline:    no pool objects at all (how exact is a cached replay by itself?)
--   enter_frame: 11 pool objects for 31 colliders, moved in enter_frame (as before)
--   draw2d:      the same, moved in draw2d (between steps), only when the frame changed
-- Run it WITHOUT MGE (it stops Atmo Play if running): /ls mgeDev/tools/atmoplay/atmoplay_timing_probe.lua
-- Results: chat and data/script/atmoplay_timing_probe.log. Dev only: tools/ isn't in the release.

local HOOKS = "atmoplay_timing_probe"
remove_hooks(HOOKS)
if ATMOPLAY and ATMOPLAY.quit then pcall(ATMOPLAY.quit) end

local info = debug and debug.getinfo and debug.getinfo(1, "S")
local source = (info and info.source or ""):gsub("^@", ""):gsub("\\", "/")
local root = source:match("data/script/(.*)tools/atmoplay/atmoplay_timing_probe%.lua$") or "mgeDev/"
ATMOPLAY = { scriptPath = root .. "atmoplay/" }
for _, module in ipairs({ "mat3.lua", "colliders.lua", "pool.lua" }) do
    ATMOPLAY_LOADING = ATMOPLAY
    dofile(ATMOPLAY.scriptPath .. module)
end
ATMOPLAY_LOADING = nil
local Colliders, Pool = ATMOPLAY.Colliders, ATMOPLAY.Pool

local MOD_NAME = "atmoplay_timing_probe"
local LOG_PATH = "atmoplay_timing_probe.log" -- data/script
local BOXES, SPHERES = 25, 6 -- pool objects in the mod: ids 49-73 boxes, 74-79 spheres
local SETUPS = {
    { name = "baseline", boxes = 0, spheres = 0, driveIn = "none" },
    { name = "enter_frame", boxes = 8, spheres = 3, driveIn = "enter_frame" },
    { name = "draw2d", boxes = 8, spheres = 3, driveIn = "draw2d" },
}
local RADIUS = 4
local PARK_Z = -100000
local SAME = 0.001
local WAIT_FRAMES = 10
local STALL_FRAMES = 300
local OPEN_TIMEOUT = 180

local function writeFile(path, text)
    local file = Files.Open(path, FILES_MODE_WRITE)
    if not file.data then return false end
    file:writeLine(text)
    file:close()
    return true
end

writeFile(LOG_PATH, "")
local function say(text)
    echo("^04[probe] " .. text)
    local file = Files.Open(LOG_PATH, FILES_MODE_APPEND)
    if file.data then
        file:writeLine(text)
        file:close()
    end
end

---------------------------------------------------------------------------------------------------- world

local function writeMod()
    local out = {}
    local id = 48
    local function add(shape, count)
        for _ = 1, count do
            id = id + 1
            out[#out + 1] = "env_obj " .. id
            out[#out + 1] = "    #atmoplay pool"
            out[#out + 1] = "    shape " .. shape
            out[#out + 1] = "    pos " .. id .. " 0 " .. PARK_Z
            out[#out + 1] = "    rot 0 0 0"
            out[#out + 1] = "    sides 1 1 1"
            out[#out + 1] = "    color 0.3 0.9 0.4 1"
            out[#out + 1] = "    flag 8"
            out[#out + 1] = "    visible 0"
            out[#out + 1] = ""
        end
    end
    add("box", BOXES)
    add("sphere", SPHERES)
    return writeFile("../data/mod/" .. MOD_NAME .. ".tbm", table.concat(out, "\n"))
end

---@param setup table
---@return AtmoPlayPoolObject[] the setup's pool objects (the rest of the mod's stay parked)
local function poolObjects(setup)
    local list = {}
    for i = 1, setup.boxes do list[#list + 1] = { id = 48 + i, shape = "box" } end
    for i = 1, setup.spheres do list[#list + 1] = { id = 48 + BOXES + i, shape = "sphere" } end
    return list
end

local function playerCenter(player)
    local s, n = { 0, 0, 0 }, 0
    for _, part in pairs(BODYPARTS) do
        local p = get_body_info(player, part).pos
        s[1], s[2], s[3], n = s[1] + p.x, s[2] + p.y, s[3] + p.z, n + 1
    end
    return { s[1] / n, s[2] / n, s[3] / n }
end

local function centers() return { playerCenter(0), playerCenter(1) } end

---The first probe's layout around tori (25 floor tiles and a wall, 6 balls at chest height), as atmo lines
---read by Colliders.build
local function buildColliders()
    local c0, c1 = playerCenter(0), playerCenter(1)
    local floor
    for _, part in pairs(BODYPARTS) do
        local z = get_body_info(0, part).pos.z
        if not floor or z < floor then floor = z end
    end
    floor = floor - 0.1
    local dx, dy = c1[1] - c0[1], c1[2] - c0[2]
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then dx, dy, len = 0, 1, 1 end
    dx, dy = dx / len, dy / len
    local lines = {}
    local function add(name, shape, x, y, z, sx, sy, sz)
        lines[#lines + 1] = "env_obj " .. name
        lines[#lines + 1] = "   shape " .. shape
        lines[#lines + 1] = string.format("   pos %.4f %.4f %.4f", x, y, z)
        lines[#lines + 1] = string.format("   sides %.4f %.4f %.4f", sx, sy, sz)
    end
    for i = -2, 2 do
        for j = -2, 2 do
            if i ~= 0 or j ~= 0 then add("tile" .. i .. j, "box", c0[1] + i, c0[2] + j, floor + 0.08, 0.8, 0.8, 0.16) end
        end
    end
    add("wall", "box", c0[1] + dx * 1.1, c0[2] + dy * 1.1, floor + 0.7, math.abs(dy) * 2 + 0.3, math.abs(dx) * 2 + 0.3, 1.2)
    for k = 0, 5 do
        local a = k * math.pi / 3
        add("ball" .. k, "sphere", c0[1] + math.cos(a) * 1.4, c0[2] + math.sin(a) * 1.4, c0[3], 0.3, 0.3, 0.3)
    end
    return (Colliders.build(lines))
end

local function apply(changes)
    for _, change in ipairs(changes) do
        local id, c = change.entry.id - 1, change.collider
        if c then
            set_obj_pos(id, c.pos[1], c.pos[2], c.pos[3])
            set_obj_sides(id, c.sides[1], c.sides[2], c.sides[3])
        else
            set_obj_pos(id, change.entry.id, 0, PARK_Z)
        end
    end
    return #changes
end

local function snapshot()
    local out = {}
    for player = 0, 1 do
        for _, part in pairs(BODYPARTS) do
            local p = get_body_info(player, part).pos
            out[#out + 1] = p.x
            out[#out + 1] = p.y
            out[#out + 1] = p.z
        end
    end
    return out
end

local function compare(live, other, shift)
    local compared, maxDiff, maxFrame, first = 0, 0, nil, nil
    local frames = {}
    for frame in pairs(live) do frames[#frames + 1] = frame end
    table.sort(frames)
    for _, frame in ipairs(frames) do
        local a, b = live[frame], other[frame + shift]
        if b then
            compared = compared + 1
            local diff = 0
            for i = 1, #a, 3 do
                local d = math.sqrt((a[i] - b[i]) ^ 2 + (a[i + 1] - b[i + 1]) ^ 2 + (a[i + 2] - b[i + 2]) ^ 2)
                if d > diff then diff = d end
            end
            if diff > maxDiff then maxDiff, maxFrame = diff, frame end
            if diff > SAME and not first then first = frame end
        end
    end
    return compared, maxDiff, maxFrame, first
end

---------------------------------------------------------------------------------------------------- the run

local before = get_game_rules().mod
local optionBefore = get_option("replaycache")
local colliders
local run = {
    mode = "start", -- start, fightStart, live, saving, replay, done
    setupIndex = 0,
    passIndex = 0,
    passes = nil,
    pool = nil, ---@type AtmoPlayPoolState?
    drive = false, -- the script moves the pool now (fight; driving replays)
    live = {}, liveLast = 0, current = nil,
    lastFrame = -1, still = 0, turn = 0, wait = 0, opened = false, sinceOpen = 0, beginsAtOpen = 0, begins = 0,
    moves = 0, saturated = 0,
}

local nextSetup, nextPass

local function finish()
    run.mode = "done"
    remove_hooks(HOOKS)
    set_option("replaycache", optionBefore)
    say("")
    say("done, replaycache back to " .. tostring(optionBefore) .. ", loading the mod from before: " .. tostring(before))
    run_cmd("lm " .. tostring(before))
end

local function replayName()
    return MOD_NAME .. "_" .. SETUPS[run.setupIndex].name
end

---Every pool object of a group in use: a wanted collider may have had to wait for one
local function poolFull()
    for _, entry in ipairs(run.pool.entries) do
        if not entry.target then return false end
    end
    return true
end

local function endPass(reason)
    if reason then say(reason) end
    if not run.opened then
        say("the replay didn't open, nothing compared")
    else
        for _, shift in ipairs({ 0, 1 }) do
            local compared, maxDiff, maxFrame, first = compare(run.live, run.current, shift)
            say(string.format("  replay frame = fight frame%s: compared %d, max %.4f%s, %s", shift == 0 and "" or " + 1",
                compared, maxDiff, maxFrame and (" at fight frame " .. maxFrame) or "",
                first and ("first over " .. SAME .. " at fight frame " .. first) or "no frame differs"))
        end
    end
    nextPass()
end

nextPass = function()
    run.passIndex = run.passIndex + 1
    local pass = run.passes[run.passIndex]
    if not pass then return nextSetup() end
    say("")
    say("=== " .. SETUPS[run.setupIndex].name .. " replay " .. run.passIndex .. ": " .. pass.label)
    run.mode, run.current, run.drive = "replay", {}, pass.drive
    run.toEnd = pass.toEnd
    run.lastFrame, run.still, run.maxSeen, run.opened, run.sinceOpen = -1, 0, -1, false, 0
    run.beginsAtOpen = run.begins
    open_replay("my replays/" .. replayName() .. ".rpl", pass.cache)
    if run.begins > run.beginsAtOpen then run.opened = true end
end

nextSetup = function()
    run.setupIndex = run.setupIndex + 1
    local setup = SETUPS[run.setupIndex]
    if not setup then return finish() end
    say("")
    say("##### setup " .. setup.name .. ": " .. (setup.boxes + setup.spheres) .. " pool objects for " .. #colliders ..
        " colliders, moved in " .. setup.driveIn)
    run.pool = assert(Pool.new(poolObjects(setup), colliders, { radius = RADIUS }))
    run.live, run.liveLast, run.turn, run.moves, run.saturated = {}, 0, 0, 0, 0
    run.driveIn, run.lastDriveFrame, run.maxGap = setup.driveIn, nil, 0
    run.mode, run.drive = "fightStart", true
    run_cmd("lm " .. MOD_NAME) -- match_begin inside: the pool is placed there (FRAME 0 in the replay)
    run.mode, run.current, run.lastFrame, run.still = "live", run.live, -1, 0
end

---The pool from scratch at a fight's (or driving replay's) start: these moves are written under FRAME 0
local function placeAtStart()
    Pool.reset(run.pool)
    -- parked first: the setup's unused pool objects and anything left from before
    for i = 1, BOXES + SPHERES do set_obj_pos(48 + i - 1, 48 + i, 0, PARK_Z) end
    local n = apply(Pool.step(run.pool, centers()))
    if run.mode == "fightStart" then say("pool placed in match_begin: " .. n .. " objects set") end
end

add_hook("match_begin", HOOKS, function()
    run.begins = run.begins + 1
    if run.mode == "fightStart" or (run.mode == "replay" and run.drive) then placeAtStart() end
end)

add_hook("leave_game", HOOKS, function()
    if run.mode == "replay" and run.drive and run.pool then Pool.reset(run.pool) end
end)

add_hook("enter_frame", HOOKS, function()
    if run.mode ~= "live" and run.mode ~= "replay" then return end
    local frame = get_world_state().match_frame
    if not run.current[frame] then run.current[frame] = snapshot() end
    if run.drive and run.pool and (run.mode ~= "live" or run.driveIn == "enter_frame") then
        local n = apply(Pool.step(run.pool, centers()))
        if run.mode == "live" then
            run.moves = run.moves + n
            if poolFull() then run.saturated = run.saturated + 1 end
        end
    end
end)

add_hook("end_game", HOOKS, function()
    if run.mode == "live" then run.mode, run.wait = "saving", 30 end
end)

local function setTurnJoints()
    run.turn = run.turn + 1
    for _, joint in pairs(JOINTS) do
        pcall(set_joint_state, 0, joint, ((run.turn * 5 + joint * 3) % 4) + 1)
    end
end

add_hook("draw2d", HOOKS, function()
    if run.mode == "live" and run.driveIn == "draw2d" then
        local frame = get_world_state().match_frame
        if frame ~= run.lastDriveFrame then
            if run.lastDriveFrame and frame - run.lastDriveFrame > run.maxGap then
                run.maxGap = frame - run.lastDriveFrame
            end
            run.lastDriveFrame = frame
            run.moves = run.moves + apply(Pool.step(run.pool, centers()))
            if poolFull() then run.saturated = run.saturated + 1 end
        end
    end
    if run.mode == "live" then
        local frame = get_world_state().match_frame
        if frame ~= run.lastFrame then
            run.lastFrame, run.still = frame, 0
            if frame > run.liveLast then run.liveLast = frame end
        else
            run.still = run.still + 1
            if run.still >= WAIT_FRAMES then
                run.still = 0
                setTurnJoints()
                step_game()
            end
        end
    elseif run.mode == "saving" then
        run.wait = run.wait - 1
        if run.wait <= 0 then
            say(string.format("fight over: %d frames, %d pool moves after the start, every pool object in use in %d frames%s",
                run.liveLast + 1, run.moves, run.saturated, run.driveIn == "draw2d" and
                (", at most " .. run.maxGap .. " match frames between two draw2d calls") or ""))
            run_cmd("savereplay " .. replayName())
            run.passes = {
                { label = "cache 0, script off (EOBJ lines only)", cache = 0, drive = false },
                { label = "cache 2, script off (EOBJ lines only)", cache = 2, drive = false },
            }
            run.passIndex = 0
            nextPass()
        end
    elseif run.mode == "replay" then
        if not run.opened then
            run.sinceOpen = run.sinceOpen + 1
            if run.begins > run.beginsAtOpen then
                run.opened = true
            elseif run.sinceOpen >= OPEN_TIMEOUT then
                return endPass()
            end
        end
        local frame = get_world_state().match_frame
        if frame < run.lastFrame and run.maxSeen >= run.liveLast - 1 then
            return endPass(run.toEnd and "replay reached its end and looped: no crash" or nil)
        end
        if frame ~= run.lastFrame then
            run.lastFrame, run.still = frame, 0
            if frame > run.maxSeen then run.maxSeen = frame end
            if not run.toEnd and frame >= run.liveLast and (run.current[run.liveLast + 1] or frame > run.liveLast + 1) then
                return endPass()
            end
        else
            run.still = run.still + 1
            if run.still >= STALL_FRAMES then
                return endPass("no progress for " .. STALL_FRAMES .. " frames at match frame " .. frame ..
                    (run.toEnd and " (stopped at its end: no crash)" or ""))
            end
        end
    end
end)

add_hook("draw3d", HOOKS, function()
    if not colliders then return end
    for _, c in ipairs(colliders) do
        set_color(0.6, 0.3, 1, 0.25)
        if c.shape == "sphere" then
            draw_sphere(c.pos[1], c.pos[2], c.pos[3], c.sides[1])
        else
            draw_box(c.pos[1], c.pos[2], c.pos[3], c.sides[1], c.sides[2], c.sides[3])
        end
    end
end)

if not writeMod() then
    say("can't write data/mod/" .. MOD_NAME .. ".tbm")
    remove_hooks(HOOKS)
    return
end
say("mod before: " .. tostring(before) .. "; replaycache " .. tostring(optionBefore))
run_cmd("lm " .. MOD_NAME) -- once, to measure where tori stands
colliders = buildColliders()
say(#colliders .. " colliders around tori (Atmo Play's colliders.lua and pool.lua, radius " .. RADIUS .. ")")
nextSetup()
