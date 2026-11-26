-- Dev probe for docs/body-parts-plan.md (not shipped). /ls mgeDev/tools/body_probe.lua, then /lm each
-- mge_tests/body_*.tbm: a few frames after each load it writes the mod's body / joint lines next to what the
-- game made of them to data/script/body_probe.log. /bprobe dumps again (e.g. after a turn), /bprobe quit stops.

local HOOKS = "mge_body_probe"
local LOG = "body_probe.log"
local WAIT_FRAMES = 3
remove_hooks(HOOKS)

local function say(text) echo("^04[body probe] ^07" .. text) end

local out = {}
local function put(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

---------------------------------------------------------------------------------------------------- math

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function len(a) return math.sqrt(dot(a, a)) end
local function unit(a) local l = len(a); return { a[1] / l, a[2] / l, a[3] / l } end
local function apply(m, v) return { dot(m[1], v), dot(m[2], v), dot(m[3], v) } end
local function mul(a, b)
    local r = {}
    for i = 1, 3 do
        r[i] = {}
        for j = 1, 3 do r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j] end
    end
    return r
end
local function transpose(m)
    return { { m[1][1], m[2][1], m[3][1] }, { m[1][2], m[2][2], m[3][2] }, { m[1][3], m[2][3], m[3][3] } }
end
local function maxDiff(a, b)
    local d = 0
    for i = 1, 3 do for j = 1, 3 do d = math.max(d, math.abs(a[i][j] - b[i][j])) end end
    return d
end
local function rotX(t) local c, s = math.cos(t), math.sin(t); return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } end
local function rotY(t) local c, s = math.cos(t), math.sin(t); return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } } end
local function rotZ(t) local c, s = math.cos(t), math.sin(t); return { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } } end

---Orthonormal frame (columns as rows of the returned matrix) from three points
local function frameOf(a, b, c)
    local x = unit(sub(b, a))
    local z = unit(cross(x, sub(c, a)))
    return { x, cross(z, x), z }
end

---Rigid fit live = R * file + t from three parts, and the largest miss over every pair
local function fit(list, i1, i2, i3)
    local F = frameOf(list[i1].file, list[i2].file, list[i3].file)
    local L = frameOf(list[i1].live, list[i2].live, list[i3].live)
    local R = mul(transpose(L), F) -- frames hold axes as rows
    local t = sub(list[i1].live, apply(R, list[i1].file))
    local worst, worstName = 0, nil
    for _, p in ipairs(list) do
        local q = apply(R, p.file)
        local miss = len(sub(p.live, { q[1] + t[1], q[2] + t[2], q[3] + t[3] }))
        if miss > worst then worst, worstName = miss, p.name end
    end
    return R, t, worst, worstName
end

local function vec(v) return v and string.format("%.3f %.3f %.3f", v[1], v[2], v[3]) or "-" end
local function mat(m)
    return string.format("[%.3f %.3f %.3f | %.3f %.3f %.3f | %.3f %.3f %.3f]", m[1][1], m[1][2], m[1][3],
        m[2][1], m[2][2], m[2][3], m[3][1], m[3][2], m[3][3])
end

---------------------------------------------------------------------------------------------------- the mod file

local function readVec(s)
    local x, y, z = tostring(s or ""):match("(%S+)%s+(%S+)%s+(%S+)")
    return tonumber(x) and { tonumber(x), tonumber(y), tonumber(z) } or nil
end

---players[n] = { body = { name = { key = value } }, joint = {...} }, gamerule lines by key
local function readMod(name)
    local file = Files.Open("../data/mod/" .. name, FILES_MODE_READONLY)
    if not file.data then return nil end
    local lines = file:readAll()
    file:close()
    local players, rules, section, player, part = {}, {}, nil, nil, nil
    for _, line in ipairs(lines) do
        local word, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
        local indented = line:match("^%s") ~= nil
        if not word then
        elseif not indented then
            section, player, part = word, nil, nil
            if word == "player" then
                player = tonumber(rest)
                players[player] = { body = {}, joint = {} }
            end
        elseif section == "gamerule" then
            rules[word] = rest
        elseif player and (word == "body" or word == "joint") then
            part = { kind = word }
            players[player][word][rest:lower()] = part
        elseif part then
            part[word] = rest
        end
    end
    return players, rules
end

---------------------------------------------------------------------------------------------------- the dump

-- candidate readings of a `rot x y z` line (degrees): order, sign
local ORDERS = { xyz = { rotX, rotY, rotZ, 1, 2, 3 }, zyx = { rotZ, rotY, rotX, 3, 2, 1 } }

local function rotCandidates(r)
    local list = {}
    for name, o in pairs(ORDERS) do
        for _, sign in ipairs({ 1, -1 }) do
            local a = { math.rad(r[1]) * sign, math.rad(r[2]) * sign, math.rad(r[3]) * sign }
            list[#list + 1] = { name = name .. (sign > 0 and " +" or " -"),
                m = mul(o[1](a[o[4]]), mul(o[2](a[o[5]]), o[3](a[o[6]]))) }
        end
    end
    return list
end

local function liveRot(b)
    local r = b.rot
    return { { r.r0, r.r1, r.r2 }, { r.r4, r.r5, r.r6 }, { r.r8, r.r9, r.r10 } }
end

local function dumpPlayer(p, file)
    local ws = get_world_state()
    put("-- player %d", p)
    -- bodies: file vs live
    local pairs_, groinRot = {}, nil
    local bodies = {}
    for name, id in pairs(BODYPARTS) do bodies[#bodies + 1] = { name = name:lower(), id = id } end
    table.sort(bodies, function(a, b) return a.id < b.id end)
    for _, b in ipairs(bodies) do
        local info = get_body_info(p, b.id)
        local line = file and file.body[b.name] or {}
        local live = { info.pos.x, info.pos.y, info.pos.z }
        local filePos = readVec(line.pos)
        if filePos then pairs_[#pairs_ + 1] = { name = b.name, file = filePos, live = live } end
        if b.name == "groin" then groinRot = liveRot(info) end
        put("body %-9s file shape=%s sides=%s pos=%s rot=%s | live shape=%d sides=%s pos=%s", b.name,
            tostring(line.shape), tostring(line.sides), tostring(line.pos), tostring(line.rot), info.shape,
            vec({ info.sides.x, info.sides.y, info.sides.z }), vec(live))
    end
    local index = {}
    for i, q in ipairs(pairs_) do index[q.name] = i end
    local R, t
    if index.head and index.r_hand and index.l_foot then
        local worst, worstName
        R, t, worst, worstName = fit(pairs_, index.head, index.r_hand, index.l_foot)
        put("FIT body live = R*file + t: R=%s t=%s worst miss %.4f (%s)", mat(R), vec(t), worst, tostring(worstName))
        -- mirror check: the same fit on file x mirrored around 1 (the classic body's middle)
        local mirrored = {}
        for i, q in ipairs(pairs_) do mirrored[i] = { name = q.name, file = { 2 - q.file[1], q.file[2], q.file[3] }, live = q.live } end
        local _, _, mworst = fit(mirrored, index.head, index.r_hand, index.l_foot)
        put("FIT mirrored-x file: worst miss %.4f", mworst)
    end
    -- rot lines: each rotated part against the groin's live rotation (the player's turn)
    if groinRot then
        put("groin live rot %s", mat(groinRot))
        for _, b in ipairs(bodies) do
            local line = file and file.body[b.name] or {}
            local r = readVec(line.rot)
            if r and (r[1] ~= 0 or r[2] ~= 0 or r[3] ~= 0) then
                local rel = mul(transpose(groinRot), liveRot(get_body_info(p, b.id)))
                local best = {}
                for _, c in ipairs(rotCandidates(r)) do
                    best[#best + 1] = string.format("%s %.3f / T %.3f", c.name, maxDiff(rel, c.m),
                        maxDiff(transpose(rel), c.m))
                end
                put("ROT %s rot=%s rel to groin %s; misses: %s", b.name, line.rot, mat(rel), table.concat(best, ", "))
            end
        end
    end
    -- joints: file pos through the body fit vs live
    local joints = {}
    for name, id in pairs(JOINTS) do joints[#joints + 1] = { name = name:lower(), id = id } end
    table.sort(joints, function(a, b) return a.id < b.id end)
    for _, j in ipairs(joints) do
        local line = file and file.joint[j.name] or {}
        local x, y, z = get_joint_pos(p, j.id)
        local live = { x, y, z }
        local filePos, expected = readVec(line.pos), nil
        if filePos and R then
            local q = apply(R, filePos)
            expected = { q[1] + t[1], q[2] + t[2], q[3] + t[3] }
        end
        put("joint %-10s file pos=%s radius=%s | live pos=%s radius=%.3f%s", j.name, tostring(line.pos),
            tostring(line.radius), vec(live), get_joint_radius(p, j.id) or -1,
            expected and string.format(" miss %.4f", len(sub(live, expected))) or "")
    end
    -- rotated bodies: the point the game turned each about. Frame from the joints (they stay at their file pos);
    -- a body turned by M about P lands at P + M (c - P): its shift is (M - I)(c - P)
    local jp, ji = {}, {}
    for _, j in ipairs(joints) do
        local line = file and file.joint[j.name] or {}
        local f = readVec(line.pos)
        if f then
            jp[#jp + 1] = { name = j.name, file = f, live = { get_joint_pos(p, j.id) } }
            ji[j.name] = #jp
        end
    end
    local RJ, TJ, jworst
    if ji.neck and ji.r_wrist and ji.l_ankle then
        RJ, TJ, jworst = fit(jp, ji.neck, ji.r_wrist, ji.l_ankle)
        put("FIT joints live = R*file + t: R=%s t=%s worst miss %.4f", mat(RJ), vec(TJ), jworst)
    end
    for _, b in ipairs(bodies) do
        local line = file and file.body[b.name] or {}
        local r, c = readVec(line.rot), readVec(line.pos)
        if RJ and r and c and (r[1] ~= 0 or r[2] ~= 0 or r[3] ~= 0) then
            local info = get_body_info(p, b.id)
            local L = { info.pos.x, info.pos.y, info.pos.z }
            local s = sub(apply(transpose(RJ), sub(L, TJ)), c) -- shift in the player frame
            local M = mul(rotX(-math.rad(r[1])), mul(rotY(-math.rad(r[2])), rotZ(-math.rad(r[3]))))
            local sides = readVec(line.sides) or { 0, 0, 0 }
            local shape = tostring(line.shape or "")
            local hz = shape:match("^sphere") and sides[1] or (shape:match("^cyl") or shape:match("^cap")) and sides[2] / 2
                or sides[3] / 2
            local cands = { { "center", c }, { "top", { c[1], c[2], c[3] + hz } }, { "bottom", { c[1], c[2], c[3] - hz } } }
            for _, j in ipairs(jp) do cands[#cands + 1] = { "joint " .. j.name, j.file } end
            for _, cand in ipairs(cands) do
                local d = sub(c, cand[2])
                cand.miss = len(sub(s, sub(apply(M, d), d)))
            end
            table.sort(cands, function(a, b2) return a.miss < b2.miss end)
            put("PIVOT %-9s rot=%s shift=%s best: %s %.4f, %s %.4f, %s %.4f", b.name, line.rot, vec(s), cands[1][1],
                cands[1].miss, cands[2][1], cands[2].miss, cands[3][1], cands[3].miss)
        end
    end
    put("match frame %d", ws.match_frame)
end

local function dump(why)
    out = {}
    local rules = get_game_rules()
    local name = tostring(rules.mod)
    local players, fileRules = readMod(name)
    put("==== %s (%s) %s", name, why, os.date("%H:%M:%S"))
    put("engageplayerpos=%s engageplayerrot=%s engagedistance=%s engagerotation=%s", tostring(rules.engageplayerpos),
        tostring(rules.engageplayerrot), tostring(rules.engagedistance), tostring(rules.engagerotation))
    if not players then put("couldn't read ../data/mod/%s", name) end
    local count = get_world_state().num_players or 2
    for p = 0, count - 1 do
        local ok, err = pcall(dumpPlayer, p, players and players[p])
        if not ok then put("player %d failed: %s", p, tostring(err)) end
    end
    local file = Files.Open(LOG, FILES_MODE_APPEND)
    if file.data then
        file:writeLine(table.concat(out, "\n"))
        file:close()
        say(name .. ": written to data/script/" .. LOG)
    else
        say("couldn't write " .. LOG)
    end
end

---------------------------------------------------------------------------------------------------- hooks

local waiting = WAIT_FRAMES
add_hook("match_begin", HOOKS, function() waiting = WAIT_FRAMES end)
add_hook("draw3d", HOOKS, function()
    if not waiting then return end
    waiting = waiting - 1
    if waiting > 0 then return end
    waiting = nil
    local ok, err = pcall(dump, "loaded")
    if not ok then say("dump failed: " .. tostring(err)) end
end)
add_hook("command", HOOKS, function(text)
    local word, rest = tostring(text or ""):match("^%s*(%S+)%s*(.-)%s*$")
    if word ~= "bprobe" then return end
    if rest == "quit" then
        remove_hooks(HOOKS)
        say("stopped")
    else
        local ok, err = pcall(dump, "/bprobe")
        if not ok then say("dump failed: " .. tostring(err)) end
    end
    return 1
end)
say("on: /lm the mge_tests/body_*.tbm mods; /bprobe dumps now, /bprobe quit stops")
