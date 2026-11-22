-- Atmo Play probe: thrust, script force, bounce and friction, logged every match frame (docs/atmo-play-plan.md,
-- thrust props). Dev only (tools/ isn't shipped).
--   1. /lm mge_tests/atmoplay_probe.tbm (data/mod/mge_tests: what each object tests is in its header), or
--      mge_tests/atmoplay_probe_friction.tbm (12 flat boxes slid; logs to atmoplay_probe_friction.log)
--   2. /ls mgeDev/tools/atmoplay/probe_thrust.lua
--   3. play the fight to the end (space each turn, no moves needed), then save and watch its replay with
--      /opt replaycache 0, to the end
-- The log is data/script/atmoplay_probe.log (appended; delete it for a clean run). Lines:
--   BEGIN replay=<mode> gravity=<x y z>       match_begin
--   F <frame> <replay> | <id> x y z vx vy vz | ...  each new match frame seen in draw2d, before the script pushes
--   E <frame> <replay>                         each enter_frame (shows frames draw2d skipped)
-- In fights only, from frame 1 (moves before it crashed R in Atmo Play), the script:
--   obj 5: set_obj_force(FORCE, 0, 0) every frame; obj 6: every 5th frame; obj 7: once
--   objs 15-20, 22: set_obj_linear_vel(SLIDE, 0, 0) once (friction slides)

local HOOKS = "atmoplay_probe"
remove_hooks(HOOKS)

local LOG = "atmoplay_probe.log"
local DYNAMIC = 22 -- ids 1-22 are the dynamic ones
local FORCE = 0.1 -- the same number as the mod's thrust lines
local SLIDE = 5
local SLIDERS = { 15, 16, 17, 18, 19, 20, 22 }
local FORCES = true -- objs 5-7 pushed by the script

-- mge_tests/atmoplay_probe_friction.tbm: 12 flat boxes, all slid, no forces
do
    local ok, rules = pcall(get_game_rules)
    if ok and rules and tostring(rules.mod):find("friction") then
        DYNAMIC, FORCES, SLIDERS = 12, false, {}
        for id = 1, 12 do SLIDERS[id] = id end
        LOG = "atmoplay_probe_friction.log"
    end
end

local buffer = {}
local lastFrame, lastReplay
local pushedOnce, slid = false, false

local function flush()
    if #buffer == 0 then return end
    local file = io.open(LOG, "a")
    if file then
        file:write(table.concat(buffer, "\n"), "\n")
        file:close()
    end
    buffer = {}
end

local function log(line)
    buffer[#buffer + 1] = line
    if #buffer >= 100 then flush() end
end

local function fmt(n) return string.format("%.6f", tonumber(n) or 0) end

add_hook("match_begin", HOOKS, function()
    local ws = get_world_state()
    local ok, rules = pcall(get_game_rules)
    log(("BEGIN replay=%d gravity=%s frame=%d"):format(ws.replay_mode, ok and rules and tostring(rules.gravity) or "?",
        ws.match_frame))
    pushedOnce, slid = false, false
    lastFrame = nil
    flush()
end)

add_hook("enter_frame", HOOKS, function()
    local ws = get_world_state()
    log(("E %d %d"):format(ws.match_frame, ws.replay_mode))
end)

add_hook("draw2d", HOOKS, function()
    local ws = get_world_state()
    local frame, replay = ws.match_frame, ws.replay_mode
    if frame == lastFrame and replay == lastReplay then return end
    lastFrame, lastReplay = frame, replay
    local parts = { ("F %d %d"):format(frame, replay) }
    for id = 1, DYNAMIC do
        local x, y, z = get_obj_pos(id - 1)
        local vx, vy, vz = get_obj_linear_vel(id - 1)
        parts[#parts + 1] = table.concat({ id, fmt(x), fmt(y), fmt(z), fmt(vx), fmt(vy), fmt(vz) }, " ")
    end
    log(table.concat(parts, " | "))
    if replay == 0 and frame >= 1 then
        if FORCES then
            set_obj_force(4, FORCE, 0, 0)
            if frame % 5 == 0 then set_obj_force(5, FORCE, 0, 0) end
            if not pushedOnce then
                set_obj_force(6, FORCE, 0, 0)
                pushedOnce = true
            end
        end
        if not slid then
            for _, id in ipairs(SLIDERS) do set_obj_linear_vel(id - 1, SLIDE, 0, 0) end
            slid = true
        end
    end
end)

add_hook("end_game", HOOKS, function()
    log("END")
    flush()
end)

add_hook("leave_game", HOOKS, flush)

add_hook("unload", HOOKS, function()
    flush()
    remove_hooks(HOOKS)
end)

echo("^04[atmoplay probe] logging to data/script/" .. LOG .. " - play the fight, then watch its replay (replaycache 0)")
