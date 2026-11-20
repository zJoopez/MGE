-- In-game probe for the Atmo Play plan (docs/atmo-play-plan.md, R1): does a replay collide the way the
-- fight did when the pool objects are moved onto the atmo colliders every frame? Third version: what
-- happens inside a cached replay (open_replay cache 1), and whether the pool can work there when it
-- follows a per-frame schedule recorded in the fight instead of the players' positions. Earlier versions
-- tested cache 0 / 1 / 2, jumps (rewind_replay_to_frame does nothing without the cache) and /lr; their
-- results are in docs/atmo-play-plan.md.
-- Fully automatic, nothing to press:
--   1. Writes data/mod/atmoplay_replay_probe.tbm: a pool of hidden static objects (8 boxes, 3 spheres)
--      and nothing else, and loads it.
--   2. Live fight: places 25 boxes (floor tiles and a wall) and 6 balls around tori as "atmo" colliders
--      (kept in this script, not in a file), plays a fixed joint pattern every turn, and drives the pool
--      onto the colliders nearest to the players in enter_frame (fewer pool objects than colliders, so
--      they get reassigned while tori moves). Records every body part of both players per match frame.
--      At the end it saves the replay (savereplay writes replay/my replays/atmoplay_replay_probe.rpl).
--   3. Plays that replay once per entry in PASSES (below), driving the pool, and compares each frame with
--      the live fight, separately before a jump, inside the jump call and after it.
--   4. Sets the replaycache option back and loads the mod from before.
-- Run it WITHOUT MGE and the Atmo Play PoC: /ls mgeDev/tools/atmoplay/atmoplay_replay_probe.lua
-- Results go to chat and to data/script/atmoplay_replay_probe.log. Dev only: tools/ isn't in the release.

local HOOKS = "atmoplay_replay_probe"
remove_hooks(HOOKS)

local MOD_NAME = "atmoplay_replay_probe"
local REPLAY_NAME = "atmoplay_replay_probe"
local LOG_PATH = "atmoplay_replay_probe.log" -- data/script
local POOL_BOXES, POOL_SPHERES = 8, 3
local RADIUS = 4 -- pool reach from a player's center, as in the PoC
local PARK_Z = -100000
local SAME = 0.001 -- position difference still counted as the same
local WAIT_FRAMES = 10 -- draw frames without a new match frame: the game waits for input, step it
local STALL_FRAMES = 300 -- draw frames without progress in a replay: the pass is over

---Writes `text` as the whole file
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

---------------------------------------------------------------------------------------------------- pool

local pool = {} -- { id (0-based), shape, target }
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
            out[#out + 1] = "    sides 0.5 0.5 0.5"
            out[#out + 1] = "    color 0.3 0.9 0.4 1"
            out[#out + 1] = "    flag 8"
            out[#out + 1] = "    visible 0"
            out[#out + 1] = ""
            pool[#pool + 1] = { id = id - 1, shape = shape }
        end
    end
    add("box", POOL_BOXES)
    add("sphere", POOL_SPHERES)
    return writeFile("../data/mod/" .. MOD_NAME .. ".tbm", table.concat(out, "\n"))
end

local function park(proxy)
    set_obj_pos(proxy.id, proxy.id, 0, PARK_Z)
    set_obj_vis(proxy.id, 0)
    proxy.target = nil
end

local function parkAll()
    for _, proxy in ipairs(pool) do park(proxy) end
end

---------------------------------------------------------------------------------------------------- colliders

local colliders = nil -- { shape, pos, sides (box: full sides, sphere: radius first) }, built once

local function playerCenter(player)
    local s, n = { 0, 0, 0 }, 0
    for _, part in pairs(BODYPARTS) do
        local p = get_body_info(player, part).pos
        s[1], s[2], s[3], n = s[1] + p.x, s[2] + p.y, s[3] + p.z, n + 1
    end
    return { s[1] / n, s[2] / n, s[3] / n }
end

local function lowestZ(player)
    local low
    for _, part in pairs(BODYPARTS) do
        local z = get_body_info(player, part).pos.z
        if not low or z < low then low = z end
    end
    return low
end

---Floor tiles in a 5x5 grid around tori (the middle one left out, tori stands there), a wall between
---tori and uke, and balls around tori at chest height
local function buildColliders()
    local c0, c1 = playerCenter(0), playerCenter(1)
    local floor = lowestZ(0) - 0.1
    local dx, dy = c1[1] - c0[1], c1[2] - c0[2]
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then dx, dy, len = 0, 1, 1 end
    dx, dy = dx / len, dy / len
    local list = {}
    for i = -2, 2 do
        for j = -2, 2 do
            if i ~= 0 or j ~= 0 then
                list[#list + 1] = { shape = "box", pos = { c0[1] + i, c0[2] + j, floor + 0.08 },
                    sides = { 0.8, 0.8, 0.16 } }
            end
        end
    end
    list[#list + 1] = { shape = "box", pos = { c0[1] + dx * 1.1, c0[2] + dy * 1.1, floor + 0.7 },
        sides = { math.abs(dy) * 2 + 0.3, math.abs(dx) * 2 + 0.3, 1.2 } }
    for k = 0, 5 do
        local a = k * math.pi / 3
        list[#list + 1] = { shape = "sphere", pos = { c0[1] + math.cos(a) * 1.4, c0[2] + math.sin(a) * 1.4,
            c0[3] }, sides = { 0.3, 0.3, 0.3 } }
    end
    return list
end

local function distanceTo(collider, p)
    local q = collider.pos
    if collider.shape == "sphere" then
        local d = math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2 + (p[3] - q[3]) ^ 2) - collider.sides[1]
        return math.max(d, 0)
    end
    local s = collider.sides
    local x = math.max(0, math.abs(p[1] - q[1]) - s[1] / 2)
    local y = math.max(0, math.abs(p[2] - q[2]) - s[2] / 2)
    local z = math.max(0, math.abs(p[3] - q[3]) - s[3] / 2)
    return math.sqrt(x * x + y * y + z * z)
end

---Puts a pool object on a collider (when it isn't there already)
local function place(proxy, c)
    if proxy.target == c then return end
    set_obj_pos(proxy.id, c.pos[1], c.pos[2], c.pos[3])
    set_obj_sides(proxy.id, c.sides[1], c.sides[2], c.sides[3])
    set_obj_vis(proxy.id, 1)
    proxy.target = c
end

---The PoC's rule: per shape, the colliders nearest to any player within RADIUS, nearest first (ties by
---index), on the pool objects of that shape in id order. A pool object is moved only when its target
---changes
local function drivePool()
    if not colliders then return end
    local centers = { playerCenter(0), playerCenter(1) }
    local byShape = {}
    for index, collider in ipairs(colliders) do
        local best
        for _, center in ipairs(centers) do
            local d = distanceTo(collider, center)
            if not best or d < best then best = d end
        end
        if best <= RADIUS then
            local list = byShape[collider.shape] or {}
            byShape[collider.shape] = list
            list[#list + 1] = { collider = collider, distance = best, index = index }
        end
    end
    for _, list in pairs(byShape) do
        table.sort(list, function(a, b)
            if a.distance ~= b.distance then return a.distance < b.distance end
            return a.index < b.index
        end)
    end
    local used = {}
    for _, proxy in ipairs(pool) do
        local n = (used[proxy.shape] or 0) + 1
        used[proxy.shape] = n
        local pick = byShape[proxy.shape] and byShape[proxy.shape][n]
        if pick then
            place(proxy, pick.collider)
        elseif proxy.target then
            park(proxy)
        end
    end
end

---------------------------------------------------------------------------------------------------- recording

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

---@param shift integer? the other recording's frame live frame + shift (cached replays report frames one
---higher)
---@return integer compared, number maxDiff, integer? maxFrame, integer? firstDiverged
local function compare(live, other, shift)
    shift = shift or 0
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

-- drive: "positions" moves the pool from the players' positions (as live play does), "schedule" sets the
-- pool to what it was in the live fight at frame (reported frame + offset): cached replays report frames
-- one higher, so offset -1 is the fight's frame if that's the only difference. Recorded and logged per
-- pass: what runs inside the open_replay call (hooks, enter_frame calls, frame numbers, time) and inside a
-- jump call. jump: at a share of the fight's length (0.6 = 60% of its frames) rewind_replay_to_frame to
-- another share (it does nothing without the cache, see the plan). Every comparison is printed twice:
-- replay frame = fight frame, and replay frame = fight frame + 1
-- Cache 1 was cached in the first run and not in the third (exact, frames 0-500, jumps did nothing), so
-- these passes use cache 2, which was cached every time; one cache 1 pass at the end, with the options
-- logged, to see what decides it
local PASSES = {
    { label = "cache 0, pool from positions (baseline, known exact)", cache = 0, drive = "positions" },
    { label = "cache 2, pool from positions", cache = 2, drive = "positions" },
    { label = "cache 2, pool from the fight's schedule, same frame", cache = 2, drive = "schedule", offset = 0 },
    { label = "cache 2, pool from the fight's schedule, frame - 1", cache = 2, drive = "schedule", offset = -1 },
    { label = "cache 2, positions, jump 60% -> 30%", cache = 2, drive = "positions", jump = { at = 0.6, to = 0.3 } },
    { label = "cache 2, schedule same frame, jump 60% -> 30%", cache = 2, drive = "schedule", offset = 0,
        jump = { at = 0.6, to = 0.3 } },
    { label = "cache 2, schedule frame - 1, jump 60% -> 30%", cache = 2, drive = "schedule", offset = -1,
        jump = { at = 0.6, to = 0.3 } },
    { label = "cache 1, pool from positions (cached or not?)", cache = 1, drive = "positions" },
}
local REPLAY_FILE = "my replays/" .. REPLAY_NAME .. ".rpl" -- savereplay writes to replay/my replays/
local OPEN_TIMEOUT = 180 -- draw frames after opening without match_begin or new_game: it didn't open
local clock = os and os.clock or function() return 0 end

local before = get_game_rules().mod
local optionBefore = get_option("replaycache")
local run = {
    mode = "start", -- start, live, saving, replay, done
    live = {}, -- match frame -> positions
    schedule = {}, -- match frame -> the pool after drivePool in the live fight: collider or false per pool object
    liveLast = 0,
    current = nil, -- the recording being filled: the live fight, or the replay segment's frames
    segments = {},
    lastFrame = -1,
    still = 0,
    turn = 0,
    passIndex = 0,
    wait = 0,
    counts = { match_begin = 0, new_game = 0, leave_game = 0, end_game = 0, enter_frame = 0 },
}

local function finish()
    run.mode = "done"
    remove_hooks(HOOKS)
    set_option("replaycache", optionBefore)
    say("")
    say("done, replaycache option back to " .. tostring(optionBefore) .. ", loading the mod from before: " ..
        tostring(before))
    run_cmd("lm " .. tostring(before))
end

local function newSegment(label)
    local segment = { label = label, frames = {}, order = {} }
    run.segments[#run.segments + 1] = segment
    run.current = segment
    return segment
end

local function frameRange(segment)
    local low, high
    for frame in pairs(segment.frames) do
        if not low or frame < low then low = frame end
        if not high or frame > high then high = frame end
    end
    return low, high
end

---What ran inside a call: hooks with counts, enter_frame's frame numbers in order (first few), time
local function measure(label, fn)
    local counts = {}
    for k, v in pairs(run.counts) do counts[k] = v end
    local segment = run.current
    local orderStart = #segment.order
    local start = clock()
    fn()
    local took = clock() - start
    local fired = {}
    for k, v in pairs(run.counts) do
        if v ~= counts[k] then fired[#fired + 1] = k .. " x" .. (v - counts[k]) end
    end
    table.sort(fired)
    local frames = {}
    for i = orderStart + 1, math.min(#segment.order, orderStart + 6) do frames[#frames + 1] = segment.order[i] end
    if #segment.order > orderStart + 6 then
        frames[#frames + 1] = "... " .. segment.order[#segment.order]
    end
    say(string.format("%s took %.0f ms; inside it: %s%s; now at frame %d; replaycache %s, sysreplaycache %s",
        label, took * 1000, #fired > 0 and table.concat(fired, ", ") or "no hooks",
        #frames > 0 and ("; enter_frame frames " .. table.concat(frames, ", ")) or "",
        get_world_state().match_frame, tostring(get_option("replaycache")), tostring(get_option("sysreplaycache"))))
end

local nextPass

---@param reason string?
local function endPass(reason)
    if reason then say(reason) end
    if not run.opened then
        say("the replay didn't open (no match_begin or new_game), nothing compared")
    end
    for _, segment in ipairs(run.segments) do
        local low, high = frameRange(segment)
        if low then
            for _, shift in ipairs({ 0, 1 }) do
                local compared, maxDiff, maxFrame, first = compare(run.live, segment.frames, shift)
                say(string.format("  %s (frames %d-%d), replay frame = fight frame%s: compared %d, max %.4f%s, %s",
                    segment.label, low, high, shift == 0 and "" or " + 1", compared, maxDiff,
                    maxFrame and (" at fight frame " .. maxFrame) or "",
                    first and ("first over " .. SAME .. " at fight frame " .. first) or "no frame differs"))
            end
        else
            say("  " .. segment.label .. ": no frames")
        end
    end
    nextPass()
end

nextPass = function()
    run.passIndex = run.passIndex + 1
    local pass = PASSES[run.passIndex]
    if not pass then return finish() end
    say("")
    say("=== replay " .. run.passIndex .. ": " .. pass.label)
    run.mode, run.segments = "replay", {}
    run.lastFrame, run.still, run.maxSeen = -1, 0, -1
    run.jumped, run.opened, run.sinceOpen = false, false, 0
    if not Files.Exists("../replay/" .. REPLAY_FILE) then
        say("replay/" .. REPLAY_FILE .. " not found, stopping")
        return finish()
    end
    run.beginsAtOpen = run.counts.match_begin + run.counts.new_game
    say("before opening: replaycache " .. tostring(get_option("replaycache")) .. ", sysreplaycache " ..
        tostring(get_option("sysreplaycache")))
    newSegment("inside the open_replay call")
    measure("open_replay cache " .. pass.cache, function() open_replay(REPLAY_FILE, pass.cache) end)
    if run.counts.match_begin + run.counts.new_game > run.beginsAtOpen then run.opened = true end
    newSegment(pass.jump and "playback before the jump" or "playback")
end

---Every pool object is set again on the next drive: the sentinel differs from any collider, and pool
---objects with nothing to take are parked
local function forceReapply()
    for _, proxy in ipairs(pool) do proxy.target = true end
end

---The live fight's pool at a frame, on the pool now
local function applySchedule(frame)
    local state = run.schedule[frame]
    if not state then return end
    for i, proxy in ipairs(pool) do
        local target = state[i]
        if target then
            place(proxy, target)
        elseif proxy.target then
            park(proxy)
        end
    end
end

local function doJump(pass)
    run.jumped = true
    newSegment("inside the jump call")
    local to = math.floor(pass.jump.to * run.liveLast)
    measure("rewind_replay_to_frame(" .. to .. ") from frame " .. get_world_state().match_frame, function()
        rewind_replay_to_frame(to)
    end)
    newSegment("playback after the jump")
    forceReapply()
    local frame = get_world_state().match_frame
    run.lastFrame, run.maxSeen, run.still = frame, frame, 0
end

add_hook("match_begin", HOOKS, function()
    run.counts.match_begin = run.counts.match_begin + 1
    parkAll() -- every fight and replay start begins with the pool parked
end)
add_hook("new_game", HOOKS, function() run.counts.new_game = run.counts.new_game + 1 end)
add_hook("leave_game", HOOKS, function()
    run.counts.leave_game = run.counts.leave_game + 1
    forceReapply() -- a replay restart fires only leave_game
end)

add_hook("enter_frame", HOOKS, function()
    run.counts.enter_frame = run.counts.enter_frame + 1
    if run.mode ~= "live" and run.mode ~= "replay" then return end
    local frame = get_world_state().match_frame
    local segment = run.current
    if not segment.frames[frame] then segment.frames[frame] = snapshot() end
    segment.order[#segment.order + 1] = frame
    if run.mode == "live" then
        drivePool()
        local state = {}
        for i, proxy in ipairs(pool) do state[i] = proxy.target or false end
        run.schedule[frame] = state
        return
    end
    local pass = PASSES[run.passIndex]
    if pass.drive == "schedule" then
        applySchedule(frame + pass.offset)
    else
        drivePool()
    end
end)

add_hook("end_game", HOOKS, function()
    run.counts.end_game = run.counts.end_game + 1
    if run.mode == "live" then
        run.mode, run.wait = "saving", 30
    end
end)

---This turn's joint states for tori: a fixed pattern, the same every run
local function setTurnJoints()
    run.turn = run.turn + 1
    for _, joint in pairs(JOINTS) do
        local state = ((run.turn * 5 + joint * 3) % 4) + 1
        pcall(set_joint_state, 0, joint, state)
    end
end

add_hook("draw2d", HOOKS, function()
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
            say(string.format("live fight over: %d match frames recorded, %d turns", run.liveLast + 1, run.turn))
            run_cmd("savereplay " .. REPLAY_NAME)
            say("saved replay/" .. REPLAY_FILE .. "; replaycache option is " .. tostring(optionBefore))
            nextPass()
        end
    elseif run.mode == "replay" then
        local pass = PASSES[run.passIndex]
        if not run.opened then
            run.sinceOpen = run.sinceOpen + 1
            if run.counts.match_begin + run.counts.new_game > run.beginsAtOpen then
                run.opened = true
            elseif run.sinceOpen >= OPEN_TIMEOUT then
                return endPass()
            end
        end
        local frame = get_world_state().match_frame
        if pass.jump and not run.jumped and frame >= math.floor(pass.jump.at * run.liveLast) then
            return doJump(pass)
        end
        if frame < run.lastFrame and run.maxSeen >= run.liveLast - 1 then return endPass("replay looped") end
        if frame ~= run.lastFrame then
            run.lastFrame, run.still = frame, 0
            if frame > run.maxSeen then run.maxSeen = frame end
            -- the end: the fight's last frame recorded (cached replays report one higher, so also that one)
            local frames = run.current.frames
            if frame >= run.liveLast and (frames[run.liveLast + 1] or frame > run.liveLast + 1) then
                return endPass()
            end
        else
            run.still = run.still + 1
            if run.still >= STALL_FRAMES then
                return endPass("no progress for " .. STALL_FRAMES .. " frames at match frame " .. frame)
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
say("mod before: " .. tostring(before) .. ". Loading " .. MOD_NAME .. " (" .. #pool .. " pool objects)")
run_cmd("lm " .. MOD_NAME) -- match_begin runs inside it (parks the pool)
colliders = buildColliders()
say(#colliders .. " colliders around tori; live fight starts")
run.mode = "live"
run.current = { label = "live", frames = run.live, order = {} }
