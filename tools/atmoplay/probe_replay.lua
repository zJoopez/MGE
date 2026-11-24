-- Atmo Play probe: a fight against its replay, frame by frame, for mods with props (dynamic atmo objects). Dev only
-- (tools/ isn't shipped). Logs, after Atmo Play's own work on each frame, every pool object out of its parking spot
-- (which prop it carries), the mod's own dynamic objects, the takes and releases, the replay misses and the replay
-- cache; compare_replay.lua says where the replay parts from its fight.
--   1. The playable mod loaded (MGE open with it, or Atmo Play)
--   2. /ls mgeDev/tools/atmoplay/probe_replay.lua (after MGE / Atmo Play: it wraps their Dynamics.step / observe)
--   3. a fight (reload the mod), then the replay view (R, or the end of the fight), watched to where it went wrong
--   4. /rprobe (flushes the log) or /rprobe quit
-- The log: data/script/atmoplay_replayprobe.log, written new at a fight's match_begin. Lines:
--   BEGIN host=<mge|atmoplay> replay=<mode> frame=<f> level=<level> mod=<name> cache=<replaycache option>
--   F <mode> <frame> sim=<flights' frame> cache=<option>/<get_replay_cache> misses=<far>/<none> carried=<n>
--   E <id> <prop index or -> x y z vx vy vz alpha  a pool object out of its parking spot (alpha: its color's)
--   R <id> x y z vx vy vz                          one of the mod's own dynamic objects
--   V <take|release> <frame> <id> <prop index>      an event new since the last line
--   P <prop index> x y z <f|s>                     a flying (f) or moved still (s) prop that isn't carried

if ATMOPLAY_REPLAYPROBE and ATMOPLAY_REPLAYPROBE.quit then pcall(ATMOPLAY_REPLAYPROBE.quit) end

local HOOKS = "atmoplay_replayprobe"
local LOG = "atmoplay_replayprobe.log"

local probe = { buffer = {}, wrapped = {}, fresh = false }
ATMOPLAY_REPLAYPROBE = probe

local function say(text) echo("^04[rprobe] ^07" .. text) end

local function flush()
    if #probe.buffer == 0 then return end
    local file = io.open(LOG, probe.fresh and "w" or "a")
    if file then
        file:write(table.concat(probe.buffer, "\n"), "\n")
        file:close()
        probe.fresh = false
    end
    probe.buffer = {}
end

local function log(line)
    probe.buffer[#probe.buffer + 1] = line
    if #probe.buffer >= 300 then flush() end
end

local function f4(n) return string.format("%.4f", tonumber(n) or 0) end

local function opt(name)
    local ok, v = pcall(get_option, name)
    return ok and tostring(v) or "?"
end

local function replayCache()
    if not get_replay_cache then return "?" end
    local ok, v = pcall(get_replay_cache)
    return ok and tostring(v) or "?"
end

local function begin(s, ws, host)
    if ws.replay_mode == 0 then probe.fresh, probe.buffer = true, {} end
    probe.state, probe.host, probe.lastKey = s, host, nil
    -- events logged, by table (a rewind cuts the list and new ones fill it again: a count would miss them)
    probe.logged = setmetatable({}, { __mode = "k" })
    for _, ev in ipairs(s.events or {}) do probe.logged[ev] = true end
    local ok, rules = pcall(get_game_rules)
    log(("BEGIN host=%s replay=%d frame=%d level=%s mod=%s cache=%s"):format(host, ws.replay_mode, ws.match_frame,
        tostring(s.level), ok and rules and tostring(rules.mod) or "?", opt("replaycache")))
end

local function record(s, ws)
    local key = ws.replay_mode .. ":" .. ws.match_frame
    if key == probe.lastKey then return end
    probe.lastKey = key
    local carried = 0
    for _, e in ipairs(s.entries) do
        if e.prop then carried = carried + 1 end
    end
    local misses = s.replayMisses or { far = 0, none = 0 }
    log(("F %d %d sim=%d cache=%s/%s misses=%d/%d carried=%d"):format(ws.replay_mode, ws.match_frame, s.simFrame or -1,
        opt("replaycache"), replayCache(), misses.far, misses.none, carried))
    for _, e in ipairs(s.entries) do
        local id = e.id - 1
        local x, y, z = get_obj_pos(id)
        if x and math.abs(z - e.home.pos[3]) >= 1000 then -- out of its parking spot (Dynamics.PARKED)
            local vx, vy, vz = get_obj_linear_vel(id)
            local okColor, r, _, _, a = pcall(get_obj_color, id)
            if okColor and type(r) == "table" then a = r[4] end
            log(("E %d %s %s %s %s %s %s %s %s"):format(e.id, e.prop and tostring(e.prop.index) or "-", f4(x), f4(y),
                f4(z), f4(vx), f4(vy), f4(vz), okColor and f4(a) or "?"))
        end
    end
    for _, id in ipairs(s.follow or {}) do
        local x, y, z = get_obj_pos(id)
        if x then
            local vx, vy, vz = get_obj_linear_vel(id)
            log(("R %d %s %s %s %s %s %s"):format(id + 1, f4(x), f4(y), f4(z), f4(vx), f4(vy), f4(vz)))
        end
    end
    for _, ev in ipairs(s.events) do
        if not probe.logged[ev] then
            probe.logged[ev] = true
            log(("V %s %d %d %d"):format(ev.kind, ev.frame or -1, ev.entry and ev.entry.id or -1,
                ev.prop and ev.prop.index or -1))
        end
    end
    for _, prop in ipairs(s.props) do
        if not prop.entry and (prop.flight or prop.pos ~= prop.home.pos) then
            log(("P %d %s %s %s %s"):format(prop.index, f4(prop.pos[1]), f4(prop.pos[2]), f4(prop.pos[3]),
                prop.flight and "f" or "s"))
        end
    end
end

local function wrap(D, host)
    if type(D) ~= "table" or probe.wrapped[D] then return end
    local orig = { matchBegin = D.matchBegin, step = D.step, observe = D.observe }
    probe.wrapped[D] = orig
    D.matchBegin = function(s, ws, ...)
        local r = orig.matchBegin(s, ws, ...)
        local ok, err = pcall(begin, s, ws, host)
        if not ok then say("begin: " .. tostring(err)) end
        return r
    end
    local function after(s)
        if s ~= probe.state then
            local ok, err = pcall(begin, s, get_world_state(), host)
            if not ok then say("begin: " .. tostring(err)) return end
        end
        local ok, err = pcall(record, s, get_world_state())
        if not ok then say("record: " .. tostring(err)) end
    end
    D.step = function(s, ...)
        local r = orig.step(s, ...)
        after(s)
        return r
    end
    D.observe = function(s, ...)
        local r = orig.observe(s, ...)
        after(s)
        return r
    end
end

local hosts = 0
if type(ATMOPLAY) == "table" and ATMOPLAY.Dynamics then
    wrap(ATMOPLAY.Dynamics, "atmoplay")
    hosts = hosts + 1
end
local mge = rawget(_G, "MGE")
if type(mge) == "table" and type(mge.AtmoPlay) == "table" and mge.AtmoPlay.Dynamics then
    wrap(mge.AtmoPlay.Dynamics, "mge")
    hosts = hosts + 1
end

function probe.quit()
    for D, orig in pairs(probe.wrapped) do
        D.matchBegin, D.step, D.observe = orig.matchBegin, orig.step, orig.observe
    end
    probe.wrapped = {}
    pcall(flush)
    remove_hooks(HOOKS)
    if ATMOPLAY_REPLAYPROBE == probe then ATMOPLAY_REPLAYPROBE = nil end
end

remove_hooks(HOOKS)
add_hook("leave_game", HOOKS, flush)
add_hook("end_game", HOOKS, flush)
add_hook("command", HOOKS, function(text)
    local cmd, rest = tostring(text):match("^(%S+)%s*(.-)%s*$")
    if cmd ~= "rprobe" then return end
    if rest == "quit" then
        probe.quit()
        say("stopped")
    else
        flush()
        say("log flushed: data/script/" .. LOG)
    end
    return 1
end)

if hosts == 0 then
    say("neither Atmo Play nor MGE is running: load one first, then this probe again")
else
    say("ready: reload the mod for a fight, then watch its replay; /rprobe writes the log")
end
