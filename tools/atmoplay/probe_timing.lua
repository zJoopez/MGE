-- Atmo Play probe: where the time goes, in game. Dev only (tools/ isn't shipped). Wraps the props' calls (Atmo Play's
-- and MGE's Dynamics: draw, step, observe, rebuild, predict, drawGhosts, matchBegin) and times each, and times the
-- gap between drawn frames (draw2d to draw2d), so a freeze shows whether it was ours.
--   1. MGE (or Atmo Play) with the playable mod
--   2. /ls mgeDev/tools/atmoplay/probe_timing.lua
--   3. play as usual to where it freezes or drops frames; /tprobe writes the log (also at end_game), /tprobe quit
-- data/script/atmoplay_timing.log:
--   SLOW <clock> <call> mode=<replay mode> frame=<f> <ms> ms sim <before>-><after> flying=<n>   a call over SLOW_MS
--   GAP <clock> <ms> ms between draws, frame <a>-><b> mode=<m>; ours <ms> ms (<call>: <ms>, ...)   a draw gap over GAP_MS
--   SEC <clock> <draws> draws, frames <a>-><b>, ours <ms> ms (<call> <ms> ...), slowest gap <ms>      every second
--   EVENT <clock> <hook> mode=<m> frame=<f>                                                         match_begin, end_game ...

if ATMOPLAY_TIMEPROBE and ATMOPLAY_TIMEPROBE.quit then pcall(ATMOPLAY_TIMEPROBE.quit) end

local HOOKS = "atmoplay_timeprobe"
local LOG = "atmoplay_timing.log"
local SLOW_MS, GAP_MS = 8, 50
local CALLS = { "draw", "step", "observe", "rebuild", "predict", "drawGhosts", "matchBegin" }

local probe = { buffer = {}, wrapped = {}, gapCalls = {}, secCalls = {}, depth = 0 }
ATMOPLAY_TIMEPROBE = probe

local clock = os.clock
local function say(text) echo("^04[tprobe] ^07" .. text) end

local function flush()
    if #probe.buffer == 0 then return end
    local file = io.open(LOG, probe.started and "a" or "w")
    if file then
        file:write(table.concat(probe.buffer, "\n"), "\n")
        file:close()
        probe.started = true
    end
    probe.buffer = {}
end

local function log(line)
    probe.buffer[#probe.buffer + 1] = line
    if #probe.buffer >= 200 then flush() end
end

local function ws() return get_world_state() end

local function add(list, name, ms) list[name] = (list[name] or 0) + ms end

---The dynamic objects (ids 0-47) at 0,0,0 and below the ground: the game's replay start has put script-moved objects
---at the origin before, and objects piled into each other make a slow physics step
local function objectsText()
    local origin, under, n = 0, 0, 0
    for id = 0, 47 do
        local ok, x, y, z = pcall(get_obj_pos, id)
        if ok and x then
            n = n + 1
            if math.abs(x) + math.abs(y) + math.abs(z) < 0.01 then origin = origin + 1 end
            if z < 0 then under = under + 1 end
        end
    end
    return ("objects %d: %d at 0,0,0, %d below z 0"):format(n, origin, under)
end

local function listText(list)
    local parts = {}
    for name, ms in pairs(list) do parts[#parts + 1] = ("%s %.1f"):format(name, ms) end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function wrap(D, host)
    if type(D) ~= "table" or probe.wrapped[D] then return end
    local orig = {}
    probe.wrapped[D] = orig
    for _, name in ipairs(CALLS) do
        local f = D[name]
        if type(f) == "function" then
            orig[name] = f
            D[name] = function(s, ...)
                -- only the outermost call counts (draw calls step / observe / rebuild): nested ones are logged but
                -- not added twice
                probe.depth = probe.depth + 1
                local before = s and s.simFrame
                local t = clock()
                local a, b, c = f(s, ...)
                local ms = (clock() - t) * 1000
                probe.depth = probe.depth - 1
                local nested = probe.depth > 0
                if not nested then
                    add(probe.gapCalls, name, ms)
                    add(probe.secCalls, name, ms)
                end
                if ms >= SLOW_MS then
                    local w = ws()
                    local flying = 0
                    for _, prop in ipairs(s and s.flying or {}) do
                        if prop.flight and not prop.entry then flying = flying + 1 end
                    end
                    log(("SLOW %.3f %s%s %s mode=%d frame=%d %.1f ms sim %s->%s flying=%d"):format(clock(), name,
                        nested and " (inside)" or "", host, w.replay_mode, w.match_frame, ms, tostring(before),
                        tostring(s and s.simFrame), flying))
                end
                return a, b, c
            end
        end
    end
end

if type(ATMOPLAY) == "table" and ATMOPLAY.Dynamics then wrap(ATMOPLAY.Dynamics, "atmoplay") end
local mge = rawget(_G, "MGE")
if type(mge) == "table" and type(mge.AtmoPlay) == "table" and mge.AtmoPlay.Dynamics then wrap(mge.AtmoPlay.Dynamics, "mge") end

-- MGE's own work around a match: what its match_begin and drawing call (a freeze at the game's end or a replay's
-- start: theirs or ours?). Timed like the props' calls, under "mge.<name>"
local MGE_CALLS = {
    { "Playable", { "onMatchBegin", "draw", "drawGhosts" } },
    { "Main", { "resetWindow", "updateWindow" } },
    { "History", { "reset" } },
    { "AtmoLayer", { "reapplySeeThrough", "setObjectsSeeThrough" } },
    { "", { "updateSource", "snapshotGamerules", "apply" } },
}
probe.mgeWrapped = {}
if type(mge) == "table" then
    for _, group in ipairs(MGE_CALLS) do
        local t = group[1] == "" and mge or mge[group[1]]
        if type(t) == "table" then
            for _, name in ipairs(group[2]) do
                local f = t[name]
                if type(f) == "function" then
                    local label = "mge." .. (group[1] ~= "" and group[1] .. "." or "") .. name
                    probe.mgeWrapped[#probe.mgeWrapped + 1] = { t, name, f }
                    t[name] = function(...)
                        -- the outermost timed call counts (MGE's Playable.draw calls the props' draw: not twice)
                        probe.depth = probe.depth + 1
                        local a = clock()
                        local r1, r2, r3 = f(...)
                        local ms = (clock() - a) * 1000
                        probe.depth = probe.depth - 1
                        if probe.depth == 0 then
                            add(probe.gapCalls, label, ms)
                            add(probe.secCalls, label, ms)
                        end
                        if ms >= SLOW_MS then
                            local w = ws()
                            log(("SLOW %.3f %s mode=%d frame=%d %.1f ms"):format(clock(), label, w.replay_mode,
                                w.match_frame, ms))
                        end
                        return r1, r2, r3
                    end
                end
            end
        end
    end
end

local function event(name)
    return function()
        local w = ws()
        local mem = collectgarbage("count") / 1024
        log(("EVENT %.3f %s mode=%d frame=%d game_frame=%s gameover=%s lua=%.1f MB"):format(clock(), name,
            w.replay_mode, w.match_frame, tostring(w.game_frame), tostring(w.gameover or w.game_over), mem))
        if name == "end_game" or name == "leave_game" then flush() end
    end
end

remove_hooks(HOOKS)
add_hook("draw2d", HOOKS, function()
    local now, w = clock(), ws()
    if probe.lastDraw then
        local gap = (now - probe.lastDraw) * 1000
        if gap >= GAP_MS then
            local ours = 0
            for _, ms in pairs(probe.gapCalls) do ours = ours + ms end
            log(("GAP %.3f %.1f ms between draws, frame %d->%d mode=%d; ours %.1f ms (%s); %s, lua %.1f MB"):format(now,
                gap, probe.lastFrame or -1, w.match_frame, w.replay_mode, ours, listText(probe.gapCalls), objectsText(),
                collectgarbage("count") / 1024))
        end
        if gap > (probe.secWorst or 0) then probe.secWorst = gap end
    end
    probe.gapCalls = {}
    if probe.lastMode ~= nil and probe.lastMode ~= w.replay_mode then
        log(("SWITCH %.3f mode %d->%d at frame %d (was %d); %s, lua %.1f MB"):format(now, probe.lastMode, w.replay_mode,
            w.match_frame, probe.lastFrame or -1, objectsText(), collectgarbage("count") / 1024))
    end
    probe.lastMode = w.replay_mode
    probe.lastDraw, probe.lastFrame = now, w.match_frame
    probe.secDraws = (probe.secDraws or 0) + 1
    probe.secFrom = probe.secFrom or w.match_frame
    if now - (probe.secAt or now) >= 1 or not probe.secAt then
        if probe.secAt then
            local ours = 0
            for _, ms in pairs(probe.secCalls) do ours = ours + ms end
            log(("SEC %.3f %d draws, frames %d->%d mode=%d, ours %.1f ms (%s), slowest gap %.1f ms"):format(now,
                probe.secDraws, probe.secFrom, w.match_frame, w.replay_mode, ours, listText(probe.secCalls),
                probe.secWorst or 0))
        end
        probe.secAt, probe.secDraws, probe.secFrom, probe.secCalls, probe.secWorst = now, 0, w.match_frame, {}, 0
    end
end)
for _, name in ipairs({ "match_begin", "end_game", "leave_game", "new_game" }) do add_hook(name, HOOKS, event(name)) end
add_hook("command", HOOKS, function(text)
    local cmd, rest = tostring(text):match("^(%S+)%s*(.-)%s*$")
    if cmd ~= "tprobe" then return end
    if rest == "quit" then
        probe.quit()
        say("stopped")
    else
        flush()
        say("log written: data/script/" .. LOG)
    end
    return 1
end)

function probe.quit()
    for D, orig in pairs(probe.wrapped) do
        for name, f in pairs(orig) do D[name] = f end
    end
    probe.wrapped = {}
    for _, w in ipairs(probe.mgeWrapped or {}) do w[1][w[2]] = w[3] end
    probe.mgeWrapped = {}
    pcall(flush)
    remove_hooks(HOOKS)
    if ATMOPLAY_TIMEPROBE == probe then ATMOPLAY_TIMEPROBE = nil end
end

say("timing; play to where it freezes, then /tprobe (log: data/script/" .. LOG .. ")")
