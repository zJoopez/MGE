-- In-game probe (docs/atmo-play-plan.md): can a pool of DYNAMIC objects stand in for pushable atmo objects
-- (crates) and still replay exactly with the script off? Dynamic objects must be on ids 1-48 (above, the
-- game shows no predictions and they misbehave in replays: user, 2026-11-20), so the pool is small.
-- The pool rule (setups with `pool`; moves made from draw2d, between physics steps, like the static pool):
--   * a crate within RADIUS of a player's center gets a pool object: put at the crate's saved position and
--     rotation, velocities zero
--   * a crate no longer wanted gives its pool object back only when it's AT REST (slow enough): its position
--     and rotation are saved into the crate (it may have been pushed), the object goes back to its parking
--     spot. Releasing only at rest means nothing ever needs a velocity restored
--   * parked pool objects rest on a far static platform (a parked dynamic object would fall forever)
-- Each fight is replayed with the script off and compared per frame with the fight: every body part of both
-- players AND every dynamic object's position.
-- Version history (2026-11-20):
--   2: the first run's bodies jumped ~100 units: a crate a hand held was released with the hand on it.
--   3: still jumped, the user saw why: dismemberment was on (a cut-off hand holding a crate). Since then the
--      mods set no dismemberment, no fracture, flags 0; a crate isn't released while ANY body part is near
--      it; one-frame jumps over JUMP are logged.
--   4: pool3 drifted though it only placed 3 crates in match_begin. placed3 (the same crates written into
--      the mod, no script) drifted identically, and its fight was identical to pool3's: teleporting isn't
--      the cause, the mod is. wake3 (a tiny force after placing) changed nothing.
--   5 (this one): what in placed3's mod makes the game's own replays drift, and can a replay be patched so
--      it doesn't?
--        plain:      6 ordinary dynamic crates (ids 1-6) around tori: the exact baseline
--        plat49:     plain + an empty static platform on id 49, far away
--        plat7:      plain + the same platform on id 7
--        parked:     plain + the platform on id 49 with 3 dynamic objects resting on it (ids 7-9)
--        placed3:    the fourth run's placed3 (3 crates near tori on ids 1-3, ids 4-6 parked, platform 49)
--        placedOnly: placed3's 3 crates alone (no platform, nothing parked)
--      Each replay logs the drift per turn (at the turn's first frame and the most in it): if it's back to
--      zero at each turn start, the game applies its own per-turn POS / EOBJ lines.
--      placed3's saved replay is also patched (tools/atmoplay/atmoplay_replay_patch.lua): a FRAME on every
--      frame with both players' POS / QAT / LINVEL / ANGVEL and every dynamic object's EOBJ line, from the
--      fight's recording, like clone_parser_v1.0.1.lua's recorder. The patched copy is replayed too:
--      exact => patching saved replays fixes the drift whatever causes it.
--      Result: the platform, ids and parked objects change nothing; placedOnly drifts like placed3 (the
--      fight itself drifts); the patched replay is exact uncached (0.057 cached).
--   6: the pool with moves DURING the fight (pool6: activations and releases; pool3), patched the same way:
--      do per-frame lines also make a fight with teleports replay exactly? (The third run's pool6 cached
--      replay was off by 37 in objects.) Result: patched replays exact, cache 0 and 2.
--   7: the pool's drift WITHOUT patching against a normal mod (all 16 crates as dynamic objects), over three
--      fights where both players move. A summary table ends the log.
-- Run it WITHOUT MGE and Atmo Play: /ls mgeDev/tools/atmoplay/atmoplay_dynamic_probe.lua
-- Results: chat and data/script/atmoplay_dynamic_probe.log. Dev only: tools/ isn't in the release.

local HOOKS = "atmoplay_dynamic_probe"
remove_hooks(HOOKS)
if ATMOPLAY and ATMOPLAY.quit then pcall(ATMOPLAY.quit) end
if not Utils3D then require("toriui.uielement3d") end
local Patch = dofile("mgeDev/tools/atmoplay/atmoplay_replay_patch.lua")

local MOD_NAME = "atmoplay_dynamic_probe" -- the pool setups' mod
local LOG_PATH = "atmoplay_dynamic_probe.log" -- data/script
local MAX_POOL = 6 -- dynamic pool objects in the pool mod: ids 1-6 (file ids)
local PLATFORM_ID = 49 -- the static parking platform (file id)
-- mod: a fight without script moves (its objects are built at the start, see setupObjects); pool: the dynamic
-- pool's size (the pool rule); caches: the replay passes; patch: also replay a patched copy
-- The fifth run's fights (plat49, plat7, parked, placed3, placedOnly) stay defined in setupObjects (layout:
-- which one a setup's mod uses, default its name). This run (seventh version): how far the pool drifts
-- WITHOUT patching against a normal mod, over several fights where both players move (seed: the joint
-- pattern):
--   all16: all 16 crates as ordinary dynamic objects in the mod (ids 1-16), no script: what a normal mod does
--   pool6, pool3: the pool for the same 16 crates
local SEEDS = { 1, 2, 3 }
local SETUPS = {}
for _, seed in ipairs(SEEDS) do
    SETUPS[#SETUPS + 1] = { name = "all16_s" .. seed, layout = "all16", mod = "atmoplay_dynamic_all16", seed = seed,
        caches = { 0, 2 }, label = "all 16 crates as ordinary dynamic objects (ids 1-16), no script, seed " .. seed }
    SETUPS[#SETUPS + 1] = { name = "pool6_s" .. seed, pool = 6, seed = seed, caches = { 0, 2 } }
    SETUPS[#SETUPS + 1] = { name = "pool3_s" .. seed, pool = 3, seed = seed, caches = { 0, 2 } }
end
local WAKE_FORCE = -0.001 -- z: a tiny push down after a placement (setups with `wake`)
local TOUCH = 0.5 -- a crate this close (center to a body part's center, plus the crate's half side) is touched
local JUMP = 1 -- a body part moving more than this in one fight frame is logged
-- the probe's mods: no dismemberment or fracture (a cut-off part holding a crate), no DQ ending the fight
local GAMERULES = { "gamerule", "   matchframes 500", "   flags 0", "   grip 1", "   dismemberment 0",
    "   fracture 0", "" }
local TURN_FRAMES = 10 -- the classic turn: the game writes its FRAME lines every 10 frames
local DRIFT_TURNS = 8 -- turns with drift logged per replay
local CRATES = 16
local CRATE_SIDE = 0.4
local RADIUS = 1.6 -- a crate is wanted when its center is this close to a player's center
local REST_SPEED, REST_SPIN = 0.05, 0.1 -- below both: at rest, may be released
local MOVED = 0.05 -- a crate this far from where it started was pushed
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

local IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0,
    r12 = 0, r13 = 0, r14 = 0, r15 = 1 }

---------------------------------------------------------------------------------------------------- world

local function parkPos(i) return 90 + i * 2, 100, 0.5 + CRATE_SIDE / 2 + 0.01 end

---A mod from objects { id = file id, pos, static }: dynamic ones are crates, static ones the platform
---@param name string
---@param objects table[]
---@return boolean
local function writeObjectsMod(name, objects)
    local out = {}
    for _, line in ipairs(GAMERULES) do out[#out + 1] = line end
    for _, o in ipairs(objects) do
        out[#out + 1] = "env_obj " .. o.id
        out[#out + 1] = "    shape box"
        out[#out + 1] = string.format("    pos %.4f %.4f %.4f", o.pos[1], o.pos[2], o.pos[3])
        out[#out + 1] = "    rot 0 0 0"
        if o.static then
            out[#out + 1] = "    sides 30 30 1"
            out[#out + 1] = "    color 0.3 0.3 0.3 1"
            out[#out + 1] = "    flag 8"
        else
            out[#out + 1] = string.format("    sides %.2f %.2f %.2f", CRATE_SIDE, CRATE_SIDE, CRATE_SIDE)
            out[#out + 1] = "    color 0.8 0.5 0.2 1"
            out[#out + 1] = "    flag 0"
            out[#out + 1] = "    mass 0.3"
        end
        out[#out + 1] = ""
    end
    if not writeFile("../data/mod/" .. name .. ".tbm", table.concat(out, "\n")) then
        say("can't write data/mod/" .. name .. ".tbm")
        return false
    end
    return true
end

local function playerCenter(player)
    local s, n = { 0, 0, 0 }, 0
    for _, part in pairs(BODYPARTS) do
        local p = get_body_info(player, part).pos
        s[1], s[2], s[3], n = s[1] + p.x, s[2] + p.y, s[3] + p.z, n + 1
    end
    return { s[1] / n, s[2] / n, s[3] / n }
end

---16 crates resting on the floor in two rings around tori (their start; each fight begins from it)
local function buildCrates()
    local c0 = playerCenter(0)
    local floor
    for _, part in pairs(BODYPARTS) do
        local z = get_body_info(0, part).pos.z
        if not floor or z < floor then floor = z end
    end
    floor = floor - 0.1
    local starts = {}
    for k = 0, CRATES - 1 do
        local ring = k < 8 and 0.9 or 1.5
        local a = (k % 8) * math.pi / 4 + (k < 8 and 0 or math.pi / 8)
        starts[#starts + 1] = { c0[1] + math.cos(a) * ring, c0[2] + math.sin(a) * ring, floor + CRATE_SIDE / 2 + 0.01 }
    end
    -- rounded like the mods write them ("%.4f"): a mod and the script place a crate at the same numbers
    for _, p in ipairs(starts) do
        for k = 1, 3 do p[k] = tonumber(string.format("%.4f", p[k])) end
    end
    return starts
end

---------------------------------------------------------------------------------------------------- the dynamic pool

local run -- forward: the run's state
local starts -- crate start positions

---A fresh fight: every crate at its start, every pool object parked (in match_begin: recorded under FRAME 0)
local function resetPool(size)
    run.crates = {}
    for i, p in ipairs(starts) do
        run.crates[i] = { index = i, pos = { p[1], p[2], p[3] }, rot = IDENTITY, entry = nil }
    end
    run.entries = {}
    for i = 1, size do run.entries[i] = { id = i - 1, crate = nil } end
    for i = 1, MAX_POOL do
        local x, y, z = parkPos(i)
        set_obj_pos(i - 1, x, y, z)
        set_obj_rot_m(i - 1, IDENTITY)
        set_obj_linear_vel(i - 1, 0, 0, 0)
        set_obj_angular_vel(i - 1, 0, 0, 0)
    end
end

local function length(x, y, z) return math.sqrt(x * x + y * y + z * z) end

---True when any body part of either player (cut-off ones too) is near the crate: it may be held or pressed,
---releasing it would move what touches it
local function held(pos)
    for player = 0, 1 do
        for _, part in pairs(BODYPARTS) do
            local ok, info = pcall(get_body_info, player, part)
            local p = ok and info and info.pos
            if p and length(p.x - pos[1], p.y - pos[2], p.z - pos[3]) <= TOUCH + CRATE_SIDE / 2 then return true end
        end
    end
    return false
end

---The crates within RADIUS of a player's center, nearest first ({ crate, distance })
---@param crates table[] { index, pos }
local function wantedCrates(crates)
    local centers = { playerCenter(0), playerCenter(1) }
    local wanted = {}
    for _, c in ipairs(crates) do
        local best
        for _, p in ipairs(centers) do
            local d = length(p[1] - c.pos[1], p[2] - c.pos[2], p[3] - c.pos[3])
            if not best or d < best then best = d end
        end
        if best <= RADIUS then wanted[#wanted + 1] = { crate = c, distance = best } end
    end
    table.sort(wanted, function(a, b)
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.crate.index < b.crate.index
    end)
    return wanted
end

---One frame of the rule (see the header)
local function drive()
    -- active crates: where their objects are now
    for _, e in ipairs(run.entries) do
        if e.crate then
            local x, y, z = get_obj_pos(e.id)
            e.crate.pos = { x, y, z }
        end
    end
    local wanted = wantedCrates(run.crates)
    local isWanted = {}
    for i, w in ipairs(wanted) do
        if i <= #run.entries then isWanted[w.crate] = true end
    end
    -- release: no longer wanted and at rest
    for _, e in ipairs(run.entries) do
        local c = e.crate
        if c and not isWanted[c] and not held(c.pos) then
            local vx, vy, vz = get_obj_linear_vel(e.id)
            local wx, wy, wz = get_obj_angular_vel(e.id)
            if length(vx, vy, vz) < REST_SPEED and length(wx, wy, wz) < REST_SPIN then
                c.rot = Utils3D.MatrixToMatrixTB(get_obj_rot(e.id))
                c.entry, e.crate = nil, nil
                local x, y, z = parkPos(e.id + 1)
                set_obj_pos(e.id, x, y, z)
                set_obj_rot_m(e.id, IDENTITY)
                set_obj_linear_vel(e.id, 0, 0, 0)
                set_obj_angular_vel(e.id, 0, 0, 0)
                run.releases = run.releases + 1
            end
        end
    end
    -- activate: wanted, no object yet, a free one left
    for _, w in ipairs(wanted) do
        local c = w.crate
        if isWanted[c] and not c.entry then
            for _, e in ipairs(run.entries) do
                if not e.crate then
                    e.crate, c.entry = c, e
                    set_obj_pos(e.id, c.pos[1], c.pos[2], c.pos[3])
                    set_obj_rot_m(e.id, c.rot)
                    set_obj_linear_vel(e.id, 0, 0, 0)
                    set_obj_angular_vel(e.id, 0, 0, 0)
                    if run.wake then set_obj_force(e.id, 0, 0, WAKE_FORCE) end
                    run.activations = run.activations + 1
                    break
                end
            end
        end
    end
    if #wanted > #run.entries then run.saturated = run.saturated + 1 end
end

---------------------------------------------------------------------------------------------------- recording

---Every body part's position, then every dynamic object's (run.objIds)
local function snapshot()
    local out = {}
    for player = 0, 1 do
        for _, part in pairs(BODYPARTS) do
            local p = get_body_info(player, part).pos
            -- one at a time: `out[#out + 1], out[#out + 1] = ...` takes every index before assigning (the
            -- second version of this probe stored only z that way)
            out[#out + 1] = p.x
            out[#out + 1] = p.y
            out[#out + 1] = p.z
        end
    end
    for _, id in ipairs(run.objIds) do
        local x, y, z = get_obj_pos(id)
        out[#out + 1] = x or 0
        out[#out + 1] = y or 0
        out[#out + 1] = z or 0
    end
    return out
end

local function copyMatrix(m)
    m = Utils3D.MatrixToMatrixTB(m)
    local c = {}
    for k = 0, 11 do c["r" .. k] = m["r" .. k] or 0 end
    return c
end

---The state the patched replay needs (atmoplay_replay_patch.lua's recording format)
local function fullSnapshot()
    local s = { bodies = {}, objs = {} }
    for player = 0, 1 do
        local parts = {}
        for part = 0, Patch.PARTS - 1 do
            local info = get_body_info(player, part)
            local lx, ly, lz = get_body_linear_vel(player, part)
            local ax, ay, az = get_body_angular_vel(player, part)
            parts[part] = { pos = { info.pos.x, info.pos.y, info.pos.z }, rot = copyMatrix(info.rot),
                lin = { lx, ly, lz }, ang = { ax, ay, az } }
        end
        s.bodies[player] = parts
    end
    for _, id in ipairs(run.objIds) do
        local x, y, z = get_obj_pos(id)
        local lx, ly, lz = get_obj_linear_vel(id)
        local ax, ay, az = get_obj_angular_vel(id)
        s.objs[id] = { pos = { x, y, z }, rot = copyMatrix(get_obj_rot(id)), lin = { lx, ly, lz }, ang = { ax, ay, az } }
    end
    return s
end

local BODY_VALUES -- how many numbers of a snapshot are body parts (the rest: dynamic objects)

---The largest differences between two recordings; perFrame[frame]: the bodies' largest that frame
local function compare(live, other, shift)
    local result = { compared = 0, body = 0, objects = 0, first = nil, firstObjects = nil, perFrame = {} }
    local frames = {}
    for frame in pairs(live) do frames[#frames + 1] = frame end
    table.sort(frames)
    for _, frame in ipairs(frames) do
        local a, b = live[frame], other[frame + shift]
        if b then
            result.compared = result.compared + 1
            local frameBody = 0
            for i = 1, #a, 3 do
                local d = length(a[i] - b[i], a[i + 1] - b[i + 1], a[i + 2] - b[i + 2])
                if i <= BODY_VALUES then
                    if d > frameBody then frameBody = d end
                    if d > SAME and not result.first then result.first = frame end
                else
                    if d > result.objects then result.objects = d end
                    if d > SAME and not result.firstObjects then result.firstObjects = frame end
                end
            end
            result.perFrame[frame] = frameBody
            if frameBody > result.body then result.body = frameBody end
        end
    end
    return result
end

---Per turn with drift: the bodies' drift at the turn's first frame, and the most in the turn. Back to ~0 at
---each turn start means the game applies its per-turn lines
local function sayTurns(perFrame)
    local turns, last = 0, 0
    for frame in pairs(perFrame) do
        if frame > last then last = frame end
    end
    local resets, carried = 0, 0
    for start = 0, last, TURN_FRAMES do
        local most, at = 0, start
        for f = start, start + TURN_FRAMES - 1 do
            local d = perFrame[f]
            if d and d > most then most, at = d, f end
        end
        if most > SAME then
            local first = perFrame[start] or 0
            if first <= SAME then resets = resets + 1 else carried = carried + 1 end
            if turns < DRIFT_TURNS then
                turns = turns + 1
                say(string.format("    frames %d-%d: at %d %.4f, most %.4f at %d", start, start + TURN_FRAMES - 1,
                    start, first, most, at))
            end
        end
    end
    if resets + carried > 0 then
        say(string.format("    turns with drift: %d start exact (reset), %d start drifted (carried over)", resets,
            carried))
    end
end

---------------------------------------------------------------------------------------------------- the run

local before = get_game_rules().mod
local optionBefore = get_option("replaycache")
run = {
    mode = "start", setupIndex = 0, passIndex = 0, passes = nil, drive = false,
    live = {}, liveLast = 0, current = nil, lastFrame = -1, lastDrive = nil, still = 0, turn = 0, wait = 0,
    opened = false, sinceOpen = 0, beginsAtOpen = 0, begins = 0,
    activations = 0, releases = 0, saturated = 0, jumps = 0, crates = {}, entries = {},
    objIds = {}, full = nil,
}

local nextSetup, nextPass

local function finish()
    run.mode = "done"
    remove_hooks(HOOKS)
    set_option("replaycache", optionBefore)
    say("")
    say("summary (bodies' drift, replay frame = fight frame: most / at the last frame; objects' most)")
    for _, setup in ipairs(SETUPS) do
        local parts = {}
        for _, cache in ipairs(setup.caches or { 0, 2 }) do
            local r = setup.results and setup.results[cache]
            parts[#parts + 1] = r and string.format("cache %d: %.4f / %.4f, objects %.4f", cache, r.body, r.last,
                r.objects) or ("cache " .. cache .. ": -")
        end
        say(string.format("  %-10s %s", setup.name, table.concat(parts, "; ")))
    end
    say("")
    say("done, replaycache back to " .. tostring(optionBefore) .. ", loading the mod from before: " .. tostring(before))
    run_cmd("lm " .. tostring(before))
end

local function replayName() return MOD_NAME .. "_" .. SETUPS[run.setupIndex].name end

local function endPass(reason)
    if reason then say(reason) end
    if not run.opened then
        say("the replay didn't open, nothing compared")
    else
        for _, shift in ipairs({ 0, 1 }) do
            local r = compare(run.live, run.current, shift)
            say(string.format("  replay frame = fight frame%s: compared %d; bodies max %.4f%s; objects max %.4f%s",
                shift == 0 and "" or " + 1", r.compared, r.body, r.first and (", first over " .. SAME .. " at " .. r.first) or ", exact",
                r.objects, r.firstObjects and (", first over " .. SAME .. " at " .. r.firstObjects) or ", exact"))
            if shift == 0 and r.first then sayTurns(r.perFrame) end
            local pass = run.passes[run.passIndex]
            if shift == 0 and not pass.patched then
                local setup = SETUPS[run.setupIndex]
                setup.results = setup.results or {}
                setup.results[pass.cache] = { body = r.body, objects = r.objects, last = r.perFrame[run.liveLast] or 0 }
            end
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
    run.mode, run.current, run.drive = "replay", {}, false
    run.lastFrame, run.still, run.maxSeen, run.opened, run.sinceOpen = -1, 0, -1, false, 0
    run.beginsAtOpen = run.begins
    open_replay("my replays/" .. pass.file .. ".rpl", pass.cache)
    if run.begins > run.beginsAtOpen then run.opened = true end
end

nextSetup = function()
    run.setupIndex = run.setupIndex + 1
    local setup = SETUPS[run.setupIndex]
    if not setup then return finish() end
    say("")
    say("##### setup " .. setup.name .. ": " .. (setup.label or (setup.pool .. " dynamic pool objects for " ..
        CRATES .. " crates, radius " .. RADIUS .. (setup.wake and (", force 0 0 " .. WAKE_FORCE ..
        " after each placement") or ""))))
    run.live, run.liveLast, run.turn = {}, 0, 0
    run.activations, run.releases, run.saturated, run.jumps = 0, 0, 0, 0
    run.size, run.scripted, run.wake = setup.pool, not setup.mod, setup.wake
    run.objIds = setup.objIds
    run.full = setup.patch and {} or nil
    run.mode, run.drive = "fightStart", true
    run_cmd("lm " .. (setup.mod or MOD_NAME)) -- match_begin inside: crates reset, first placed (FRAME 0)
    run.mode, run.current, run.lastFrame, run.lastDrive, run.still = "live", run.live, -1, 0, 0
end

add_hook("match_begin", HOOKS, function()
    run.begins = run.begins + 1
    if run.mode == "fightStart" and run.scripted then
        resetPool(run.size)
        drive()
    end
end)

add_hook("enter_frame", HOOKS, function()
    if run.mode ~= "live" and run.mode ~= "replay" then return end
    local frame = get_world_state().match_frame
    if not run.current[frame] then
        local snap = snapshot()
        run.current[frame] = snap
        if run.mode == "live" and run.full then run.full[frame] = fullSnapshot() end
        local before = run.mode == "live" and run.current[frame - 1]
        if before then
            local index = 0
            for player = 0, 1 do
                for name in pairs(BODYPARTS) do
                    local i = index * 3 + 1
                    local d = length(snap[i] - before[i], snap[i + 1] - before[i + 1], snap[i + 2] - before[i + 2])
                    if d > JUMP and run.jumps < 10 then
                        run.jumps = run.jumps + 1
                        say(string.format("  jump: frame %d, player %d %s moved %.2f in one frame", frame, player, name, d))
                    end
                    index = index + 1
                end
            end
        end
    end
end)

add_hook("end_game", HOOKS, function()
    if run.mode == "live" then run.mode, run.wait = "saving", 30 end
end)

local function setTurnJoints()
    run.turn = run.turn + 1
    -- both players move (the sixth version moved only tori, and the pool's crates sat around a still uke);
    -- the seed picks the pattern
    local seed = SETUPS[run.setupIndex].seed or 0
    for player = 0, seed > 0 and 1 or 0 do
        for _, joint in pairs(JOINTS) do
            pcall(set_joint_state, player, joint, ((run.turn * 5 + joint * 3 + seed * 7 + player * 11) % 4) + 1)
        end
    end
end

---placed3's saved replay with a FRAME on every frame (atmoplay_replay_patch.lua), saved as <name>_patched.
---Returns the patched replay's name, or nil
local function writePatched(name)
    local file = Files.Open("../replay/my replays/" .. name .. ".rpl", FILES_MODE_READONLY)
    if not file.data then
        say("  patch: can't read the saved replay")
        return nil
    end
    local lines = file:readAll()
    file:close()
    local c = Patch.calibrate(lines, run.full)
    for offset = -1, 1 do
        local r = c.byOffset[offset]
        say(string.format("  patch check, recorded frame = FRAME line %+d: %d lines; POS max %.6f, QAT max %.6f " ..
            "(transposed %.6f); EOBJ pos max %.6f, quat max %.6f (transposed %.6f)", offset, r.compared, r.pos,
            r.quat[false], r.quat[true], r.objPos, r.objQuat[false], r.objQuat[true]))
    end
    if not c.offset then
        say("  patch: no recorded frame matches the replay's FRAME lines, not patched")
        return nil
    end
    local out, inserted = Patch.patch(lines, run.full, c.offset, c.transposed, c.objTransposed, run.liveLast)
    local patched = name .. "_patched"
    if not writeFile("../replay/my replays/" .. patched .. ".rpl", table.concat(out, "\n")) then
        say("  patch: can't write " .. patched .. ".rpl")
        return nil
    end
    say(string.format("  patch: offset %+d, body quaternions %s, object quaternions %s; %d frames added " ..
        "(%d lines -> %d)", c.offset, c.transposed and "transposed" or "plain",
        c.objTransposed and "transposed" or "plain", inserted, #lines, #out))
    return patched
end

add_hook("draw2d", HOOKS, function()
    if run.mode == "live" then
        local frame = get_world_state().match_frame
        if frame ~= run.lastDrive and run.scripted then
            run.lastDrive = frame
            drive()
        end
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
            local setup = SETUPS[run.setupIndex]
            local pushed, farthest = 0, 0
            if not run.scripted then
                for _, o in ipairs(setup.objects) do
                    if not o.static then
                        local x, y, z = get_obj_pos(o.id - 1)
                        local d = length(x - o.pos[1], y - o.pos[2], z - o.pos[3])
                        if d > MOVED then pushed = pushed + 1 end
                        if d > farthest then farthest = d end
                    end
                end
            end
            for i, c in ipairs(run.scripted and run.crates or {}) do
                local s = starts[i]
                local d = length(c.pos[1] - s[1], c.pos[2] - s[2], c.pos[3] - s[3])
                if d > MOVED then pushed = pushed + 1 end
                if d > farthest then farthest = d end
            end
            say(string.format("fight over: %d frames; %d activations, %d releases; %d crates pushed (farthest %.2f); " ..
                "more crates wanted than pool objects in %d frames", run.liveLast + 1, run.activations, run.releases,
                pushed, farthest, run.saturated))
            run_cmd("savereplay " .. replayName())
            run.passes = {}
            for _, cache in ipairs(setup.caches or { 0, 2 }) do
                run.passes[#run.passes + 1] = { label = "cache " .. cache .. ", script off (the game's own replay)",
                    cache = cache, file = replayName() }
            end
            if setup.patch then
                local patched = writePatched(replayName())
                if patched then
                    for _, cache in ipairs({ 0, 2 }) do
                        run.passes[#run.passes + 1] = { label = "cache " .. cache ..
                            ", PATCHED (body and EOBJ lines on every frame)", cache = cache, file = patched,
                            patched = true }
                    end
                end
            end
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
        if frame < run.lastFrame and run.maxSeen >= run.liveLast - 1 then return endPass() end
        if frame ~= run.lastFrame then
            run.lastFrame, run.still = frame, 0
            if frame > run.maxSeen then run.maxSeen = frame end
            if frame >= run.liveLast and (run.current[run.liveLast + 1] or frame > run.liveLast + 1) then
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

-- the crates without an object, where they are (orange outlines): what a player would see drawn by the atmo
add_hook("draw3d", HOOKS, function()
    if (run.mode ~= "live" and run.mode ~= "fightStart") or not run.scripted then return end
    for _, c in ipairs(run.crates) do
        if not c.entry then
            set_color(0.9, 0.6, 0.2, 0.35)
            draw_box(c.pos[1], c.pos[2], c.pos[3], CRATE_SIDE, CRATE_SIDE, CRATE_SIDE)
        end
    end
end)

---------------------------------------------------------------------------------------------------- start

---Each mod setup's objects ({ id = file id, pos, static }) and its dynamic objects' ids (0-based)
local function setupObjects()
    local platform = { 100, 100, 0 }
    local function crates(first, last)
        local list = {}
        for i = first, last do list[#list + 1] = { id = i, pos = starts[i] } end
        return list
    end
    local function with(list, more)
        local out = {}
        for _, o in ipairs(list) do out[#out + 1] = o end
        for _, o in ipairs(more) do out[#out + 1] = o end
        return out
    end
    local function parked(first, last)
        local list = {}
        for i = first, last do list[#list + 1] = { id = i, pos = { parkPos(i) } } end
        return list
    end
    -- placed3: the crates the pool rule places at the start (wanted[k] -> file id k), the fourth run's placed3
    local all = {}
    for i, p in ipairs(starts) do all[i] = { index = i, pos = p } end
    local wanted = wantedCrates(all)
    local near = {}
    for k = 1, 3 do
        if wanted[k] then near[#near + 1] = { id = k, pos = wanted[k].crate.pos } end
    end
    local plain = crates(1, 6)
    local objects = {
        plain = plain,
        plat49 = with(plain, { { id = PLATFORM_ID, pos = platform, static = true } }),
        plat7 = with(plain, { { id = 7, pos = platform, static = true } }),
        parked = with(with(plain, parked(7, 9)), { { id = PLATFORM_ID, pos = platform, static = true } }),
        placed3 = with(with(near, parked(4, 6)), { { id = PLATFORM_ID, pos = platform, static = true } }),
        placedOnly = near,
        all16 = crates(1, CRATES), -- every crate a real dynamic object: what a normal mod would do
    }
    for _, setup in ipairs(SETUPS) do
        setup.objIds = {}
        if setup.mod then
            setup.objects = objects[setup.layout or setup.name]
            for _, o in ipairs(setup.objects) do
                if not o.static then setup.objIds[#setup.objIds + 1] = o.id - 1 end
            end
            writeObjectsMod(setup.mod, setup.objects)
        else
            for i = 1, MAX_POOL do setup.objIds[i] = i - 1 end
        end
    end
    say("placed3: " .. #near .. " crates near tori (of " .. #wanted .. " within radius at the start)")
end

-- the pool mod (the pool parked on the platform), loaded once to measure where tori stands
local poolObjects = {}
for i = 1, MAX_POOL do poolObjects[i] = { id = i, pos = { parkPos(i) } } end
poolObjects[#poolObjects + 1] = { id = PLATFORM_ID, pos = { 100, 100, 0 }, static = true }
if not writeObjectsMod(MOD_NAME, poolObjects) then
    remove_hooks(HOOKS)
    return
end
say("mod before: " .. tostring(before) .. "; replaycache " .. tostring(optionBefore))
run_cmd("lm " .. MOD_NAME)
starts = buildCrates()
local partCount = 0
for _ in pairs(BODYPARTS) do partCount = partCount + 1 end
BODY_VALUES = partCount * 2 * 3
setupObjects()
nextSetup()
