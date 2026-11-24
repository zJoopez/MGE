-- Atmo Play probe: real dynamic objects against their drawn atmo copies (props), logged every match frame and
-- compared (compare_dynamic.lua). Dev only (tools/ isn't shipped).
--   1. Load the playable mod as usual: Atmo Play (/ls mgeDev/atmoplay.lua, /lm modmaker/mge.tbm) or MGE with the
--      mod open (Playable on). The mod has real dynamic objects and atmo props of the same shapes beside them
--      (modmaker/mge.tbm: box, sphere, cylinder, thrust 1 0 2 0 0, the atmo copies 0.976 further along x).
--   2. /ls mgeDev/tools/atmoplay/probe_dynamic.lua (after Atmo Play / MGE: it wraps their Dynamics.draw)
--   3. Start a fight (/lm again, or MGE's reload) and play it to the end (space each turn, no moves needed).
--      The summary is echoed at the end; /dynprobe shows it any time, /dynprobe quit stops the probe.
-- Pairs: each prop with the mod's own dynamic object of the same shape whose start is nearest; the prop's
-- numbers are logged shifted by that start offset (aligned: equal numbers = equal motion).
-- The log is data/script/atmoplay_dynprobe.log, written new at each fight's match_begin (a replay watched after it
-- is appended as its own section). Lines:
--   BEGIN replay=<mode> frame=<f> host=<atmoplay|mge> level=<flight level> gravity=<x y z> mod=<name>
--   PAIR <k> real=<id> prop=<name> shape=<s> offset=<dx dy dz> radius=<r> real_mass= real_bounce= prop_mass=
--        prop_bounce= prop_friction= e=<the flight sim's restitution>
--   P <frame> <replay> <k> <real: x y z vx vy vz wx wy wz clear tilt near> <state> <pframe>
--     <prop: x y z vx vy vz wx wy wz clear tilt near> <dang>
--     clear: the lowest point's height above the ground (z = 0); tilt: degrees turned from the start; near: the
--     nearest body part's center; state: f flying (drawn), c carried (a pool object), s still (drawn, at rest);
--     pframe: the frame the prop's numbers are at; dang: degrees between the two rotations
--   END

if ATMOPLAY_DYNPROBE and ATMOPLAY_DYNPROBE.quit then pcall(ATMOPLAY_DYNPROBE.quit) end

local HOOKS = "atmoplay_dynprobe"
local LOG = "atmoplay_dynprobe.log"
local SHAPES = { [0] = "sphere", [1] = "box", [2] = "cylinder" } -- get_obj_shape

local probe = { lines = {}, buffer = {}, wrapped = {} }
ATMOPLAY_DYNPROBE = probe

local function say(text) echo("^04[dynprobe] ^07" .. text) end

-- the analyzer, next to this file
local Compare
do
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local source = (info and info.source or ""):gsub("^@", ""):gsub("\\", "/")
    local dir = (source:match("data/script/(.*)$") or source):match("^(.*/)[^/]*$") or "mgeDev/tools/atmoplay/"
    local ok, mod = pcall(dofile, dir .. "compare_dynamic.lua")
    if ok and type(mod) == "table" then Compare = mod else say("no analyzer (" .. tostring(mod) .. "): logging only") end
end

---------------------------------------------------------------------------------------------------- log

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
    probe.lines[#probe.lines + 1] = line
    if #probe.buffer >= 200 then flush() end
end

local function f6(n) return string.format("%.6f", tonumber(n) or 0) end
local function f3(n) return string.format("%.3f", tonumber(n) or 0) end

---------------------------------------------------------------------------------------------------- math

---get_obj_rot (a list of 12 or a MatrixTB) as a MatrixTB
local function tbOf(m)
    if type(m) ~= "table" then return { r0 = 1, r1 = 0, r2 = 0, r4 = 0, r5 = 1, r6 = 0, r8 = 0, r9 = 0, r10 = 1 } end
    if m.r0 ~= nil then return m end
    local out = {}
    for k = 0, 11 do out["r" .. k] = m[k + 1] or 0 end
    return out
end

local KEYS = { "r0", "r1", "r2", "r4", "r5", "r6", "r8", "r9", "r10" }

local function acosDeg(c)
    if c > 1 then c = 1 elseif c < -1 then c = -1 end
    return math.deg(math.acos(c))
end

---degrees between two rotations (row-major, local to world: trace(A^T B) = the elementwise sum)
local function angleBetween(a, b)
    local t = 0
    for _, k in ipairs(KEYS) do t = t + (a[k] or 0) * (b[k] or 0) end
    return acosDeg((t - 1) / 2)
end

local function tiltOf(m) return acosDeg(((m.r0 or 1) + (m.r5 or 1) + (m.r10 or 1) - 1) / 2) end

---the lowest point's height above the ground (columns of the matrix are the object's axes in world: the third
---row is their world z)
local function clearance(shape, sides, z, m)
    local a, b, c = math.abs(m.r8 or 0), math.abs(m.r9 or 0), math.abs(m.r10 or 1)
    if shape == "sphere" then return z - sides[1] end
    if shape == "cylinder" then return z - (c * sides[2] / 2 + sides[1]) end
    return z - (a * sides[1] + b * sides[2] + c * sides[3]) / 2
end

local function bodyParts()
    local parts = {}
    local count = get_world_state().num_players or 2
    for player = 0, count - 1 do
        for _, part in pairs(BODYPARTS or {}) do
            local ok, info = pcall(get_body_info, player, part)
            if ok and info and info.pos then parts[#parts + 1] = { info.pos.x, info.pos.y, info.pos.z } end
        end
    end
    return parts
end

local function nearest(parts, x, y, z)
    local best = math.huge
    for _, p in ipairs(parts) do
        local d = (p[1] - x) ^ 2 + (p[2] - y) ^ 2 + (p[3] - z) ^ 2
        if d < best then best = d end
    end
    return best == math.huge and 999 or math.sqrt(best)
end

local function boundRadius(shape, sides)
    if shape == "sphere" then return sides[1] end
    if shape == "cylinder" then return sides[1] + sides[2] / 2 end
    return math.sqrt(sides[1] ^ 2 + sides[2] ^ 2 + sides[3] ^ 2) / 2
end

---------------------------------------------------------------------------------------------------- pairs

---The mod's own dynamic objects (0-based ids): the state's follow list, else every non-static object that isn't
---a pool object
local function realIds(s)
    if s.follow and #s.follow > 0 then return s.follow end
    local skip = {}
    for _, e in ipairs(s.entries or {}) do skip[e.id - 1] = true end
    local ids = {}
    for id = 0, 255 do
        local okPos, x = pcall(get_obj_pos, id)
        if okPos and x and not skip[id] then
            local ok, flag = pcall(get_obj_flag, id)
            if ok and math.floor((tonumber(flag) or 8) / 8) % 2 == 0 then ids[#ids + 1] = id end
        end
    end
    return ids
end

local function pairUp(s)
    local reals = {}
    for _, id in ipairs(realIds(s)) do
        local x, y, z = get_obj_pos(id)
        local okShape, shape = pcall(get_obj_shape, id)
        local sx, sy, sz = get_obj_sides(id)
        reals[#reals + 1] = { id = id, pos = { x, y, z }, shape = SHAPES[okShape and shape or 1] or "box",
            sides = { sx, sy, sz } }
    end
    local out, used = {}, {}
    for _, prop in ipairs(s.props or {}) do
        local best, bestD
        for _, r in ipairs(reals) do
            if not used[r] and r.shape == prop.shape then
                local h = prop.home.pos
                local d = (h[1] - r.pos[1]) ^ 2 + (h[2] - r.pos[2]) ^ 2 + (h[3] - r.pos[3]) ^ 2
                if not bestD or d < bestD then best, bestD = r, d end
            end
        end
        if best then
            used[best] = true
            local h = prop.home.pos
            out[#out + 1] = { real = best, prop = prop,
                offset = { h[1] - best.pos[1], h[2] - best.pos[2], h[3] - best.pos[3] },
                startRot = tbOf(get_obj_rot(best.id)) }
        end
    end
    return out
end

local function begin(s, ws, host)
    probe.state, probe.host = s, host
    probe.pairs = pairUp(s)
    probe.lastFrame, probe.lastReplay = nil, nil
    if ws.replay_mode == 0 then
        probe.fresh, probe.buffer, probe.lines = true, {}, {}
    end
    probe.sectionStart = #probe.lines + 1
    local ok, rules = pcall(get_game_rules)
    log(("BEGIN replay=%d frame=%d host=%s level=%s gravity=%s mod=%s"):format(ws.replay_mode, ws.match_frame, host,
        tostring(s.level), ok and rules and tostring(rules.gravity) or "?", ok and rules and tostring(rules.mod) or "?"))
    local Flight = host == "mge" and MGE and MGE.AtmoPlay and MGE.AtmoPlay.Flight or (ATMOPLAY and ATMOPLAY.Flight)
    for k, p in ipairs(probe.pairs) do
        local r, prop = p.real, p.prop
        local okM, mass = pcall(get_obj_mass, r.id)
        local okB, bounce = pcall(get_obj_bounce, r.id)
        log(("PAIR %d real=%d prop=%s shape=%s offset=%s %s %s radius=%s real_mass=%s real_bounce=%s prop_mass=%s " ..
            "prop_bounce=%s prop_friction=%s e=%s"):format(k, r.id + 1, tostring(prop.name), r.shape, f6(p.offset[1]),
            f6(p.offset[2]), f6(p.offset[3]), f3(boundRadius(r.shape, r.sides)), okM and tostring(mass) or "?",
            okB and tostring(bounce) or "?", tostring(prop.mass or prop.flightMass), tostring(prop.bounce),
            tostring(prop.friction), Flight and f3(Flight.restitution(prop.bounce)) or "?"))
    end
    if #probe.pairs == 0 then say("no prop has a real object of its shape to compare with") end
end

local function record(s, ws)
    local frame, replay = ws.match_frame, ws.replay_mode
    if frame == probe.lastFrame and replay == probe.lastReplay then return end
    probe.lastFrame, probe.lastReplay = frame, replay
    local parts = bodyParts()
    for k, p in ipairs(probe.pairs) do
        local r, prop, o = p.real, p.prop, p.offset
        local x, y, z = get_obj_pos(r.id)
        local vx, vy, vz = get_obj_linear_vel(r.id)
        local wx, wy, wz = get_obj_angular_vel(r.id)
        local rm = tbOf(get_obj_rot(r.id))
        -- the prop: its pool object's numbers while carried, its flight's while drawn
        local state, pf, pos, vel, ang, pm
        if prop.entry then
            local id = prop.entry.id - 1
            local px, py, pz = get_obj_pos(id)
            state, pf, pos = "c", frame, { px, py, pz }
            vel = { get_obj_linear_vel(id) }
            ang = { get_obj_angular_vel(id) }
            pm = tbOf(get_obj_rot(id))
        else
            state = prop.flight and "f" or "s"
            pf = prop.flight and prop.flight.frame or frame
            pos, pm = prop.pos, prop.rot or prop.home.rot
            vel = prop.flight and prop.flight.vel or { 0, 0, 0 }
            ang = prop.flight and prop.flight.ang or { 0, 0, 0 }
        end
        local ax, ay, az = pos[1] - o[1], pos[2] - o[2], pos[3] - o[3]
        local realPart = table.concat({ f6(x), f6(y), f6(z), f6(vx), f6(vy), f6(vz), f6(wx), f6(wy), f6(wz),
            f6(clearance(r.shape, r.sides, z, rm)), f3(angleBetween(p.startRot, rm)), f3(nearest(parts, x, y, z)) }, " ")
        local propPart = table.concat({ f6(ax), f6(ay), f6(az), f6(vel[1]), f6(vel[2]), f6(vel[3]), f6(ang[1]),
            f6(ang[2]), f6(ang[3]), f6(clearance(prop.shape, prop.sides, pos[3], pm)),
            f3(angleBetween(prop.home.rot, pm)), f3(nearest(parts, pos[1], pos[2], pos[3])) }, " ")
        log(("P %d %d %d %s %s %d %s %s"):format(frame, replay, k, realPart, state, pf, propPart,
            f3(angleBetween(rm, pm))))
    end
end

local function summary()
    if not Compare then return end
    local section = {}
    for i = probe.sectionStart or 1, #probe.lines do section[#section + 1] = probe.lines[i] end
    local ok, report = pcall(Compare.summary, section)
    if not ok then
        say("analyzer error: " .. tostring(report))
        return
    end
    for _, line in ipairs(report) do say(line) end
end

---------------------------------------------------------------------------------------------------- wrapping

local function wrap(D, host)
    if type(D) ~= "table" or probe.wrapped[D] then return end
    local origDraw, origBegin = D.draw, D.matchBegin
    probe.wrapped[D] = { draw = origDraw, matchBegin = origBegin }
    D.matchBegin = function(s, ws)
        origBegin(s, ws)
        local ok, err = pcall(begin, s, ws, host)
        if not ok then say("begin: " .. tostring(err)) end
    end
    D.draw = function(s, ws)
        origDraw(s, ws)
        if s ~= probe.state then -- loaded mid-fight: pair what's there now
            local ok, err = pcall(begin, s, ws, host)
            if not ok then say("begin: " .. tostring(err)) return end
        end
        local ok, err = pcall(record, s, ws)
        if not ok then say("record: " .. tostring(err)) end
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
        D.draw, D.matchBegin = orig.draw, orig.matchBegin
    end
    probe.wrapped = {}
    pcall(flush)
    remove_hooks(HOOKS)
    if ATMOPLAY_DYNPROBE == probe then ATMOPLAY_DYNPROBE = nil end
end

remove_hooks(HOOKS)
add_hook("end_game", HOOKS, function()
    if not probe.state then return end
    log("END")
    flush()
    summary()
end)
add_hook("leave_game", HOOKS, flush)
add_hook("command", HOOKS, function(text)
    local cmd, rest = tostring(text):match("^(%S+)%s*(.-)%s*$")
    if cmd ~= "dynprobe" then return end
    if rest == "quit" then
        probe.quit()
        say("stopped")
    else
        flush()
        summary()
    end
    return 1
end)

if hosts == 0 then
    say("neither Atmo Play nor MGE is running: load one first, then this probe again")
else
    say("ready: start a fight (/lm the mod again) and play it to the end; log data/script/" .. LOG)
end
