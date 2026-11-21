-- Replay patching for tools/atmoplay/atmoplay_dynamic_probe.lua (dev only, no engine calls: tested offline).
-- The game writes each player's POS / QAT / LINVEL / ANGVEL and every dynamic object's EOBJ line once per
-- turn. clone_parser_v1.0.1.lua writes body lines on every frame, and its merged replays play back right, so
-- the game applies them. patch() fills the frames between the game's FRAME lines with the state the probe
-- recorded during the fight; calibrate() first finds which recorded frame matches a FRAME line, and the
-- quaternion order, by comparing with the game's own turn lines.
--
-- A recording: full[frame] = { bodies = { [player] = { [part] = { pos, rot, lin, ang } } },
--                              objs = { [id] = { pos, rot, lin, ang } } }
-- pos / lin / ang are { x, y, z }; rot is a MatrixTB (r0-r11: ODE's 3x4 row-major dMatrix3); player and part
-- are 0-based, id is the 0-based object id the replay's EOBJ lines use.

local Patch = {}

Patch.PARTS = 21 -- body parts per POS line (0-20)

---A rotation matrix as a quaternion { w, x, y, z } (ODE's dQfromR)
---@param m table MatrixTB
---@param transposed boolean? read the matrix transposed (the other storage order)
---@return number[]
function Patch.quat(m, transposed)
    local function R(i, j)
        if transposed then i, j = j, i end
        return m["r" .. (i * 4 + j)]
    end
    local w, x, y, z
    local tr = R(0, 0) + R(1, 1) + R(2, 2)
    if tr >= 0 then
        local s = math.sqrt(tr + 1)
        w = 0.5 * s
        s = 0.5 / s
        x = (R(2, 1) - R(1, 2)) * s
        y = (R(0, 2) - R(2, 0)) * s
        z = (R(1, 0) - R(0, 1)) * s
    elseif R(0, 0) >= R(1, 1) and R(0, 0) >= R(2, 2) then
        local s = math.sqrt(R(0, 0) - (R(1, 1) + R(2, 2)) + 1)
        x = 0.5 * s
        s = 0.5 / s
        y = (R(0, 1) + R(1, 0)) * s
        z = (R(2, 0) + R(0, 2)) * s
        w = (R(2, 1) - R(1, 2)) * s
    elseif R(1, 1) >= R(2, 2) then
        local s = math.sqrt(R(1, 1) - (R(2, 2) + R(0, 0)) + 1)
        y = 0.5 * s
        s = 0.5 / s
        z = (R(1, 2) + R(2, 1)) * s
        x = (R(0, 1) + R(1, 0)) * s
        w = (R(0, 2) - R(2, 0)) * s
    else
        local s = math.sqrt(R(2, 2) - (R(0, 0) + R(1, 1)) + 1)
        z = 0.5 * s
        s = 0.5 / s
        x = (R(2, 0) + R(0, 2)) * s
        y = (R(1, 2) + R(2, 1)) * s
        w = (R(1, 0) - R(0, 1)) * s
    end
    return { w, x, y, z }
end

---A replay line's tag, index and value tokens ("POS 0; 1 2 3" -> "POS", 0, { "1", "2", "3" })
---@param line string
---@return string? tag
---@return integer? index
---@return string[] values
function Patch.fields(line)
    local tag, index, rest = line:match("^(%u+) (%d+);%s*(.*)$")
    local values = {}
    if rest then
        for v in rest:gmatch("%S+") do values[#values + 1] = v end
    end
    return tag, tonumber(index), values
end

---The largest component difference between a quaternion and the replay's (q and -q are the same rotation)
local function quatDiff(q, values, at)
    local plus, minus = 0, 0
    for k = 1, 4 do
        local g = tonumber(values[at + k]) or 0
        plus = math.max(plus, math.abs(q[k] - g))
        minus = math.max(minus, math.abs(q[k] + g))
    end
    return math.min(plus, minus)
end

local function vecDiff(v, values, at)
    local d = 0
    for k = 1, 3 do d = math.max(d, math.abs(v[k] - (tonumber(values[at + k]) or 0))) end
    return d
end

---Which recorded frame matches the game's FRAME lines (offset -1, 0 or 1: full[frame + offset]), and which
---quaternion order, from the game's own POS / QAT / EOBJ lines
---@param lines string[] the saved replay
---@param full table the recording
---@return table result { offset, transposed, byOffset = { [offset] = { compared, pos, quat = { [false], [true] }, objPos, objQuat } } }
function Patch.calibrate(lines, full)
    local byOffset = {}
    for offset = -1, 1 do
        byOffset[offset] = { compared = 0, pos = 0, quat = { [false] = 0, [true] = 0 }, objPos = 0,
            objQuat = { [false] = 0, [true] = 0 } }
    end
    local frame
    for _, line in ipairs(lines) do
        local tag, index, values = Patch.fields(line)
        if tag == "FRAME" then
            frame = index
        elseif frame and (tag == "POS" or tag == "QAT" or tag == "EOBJ") then
            for offset = -1, 1 do
                local s = full[frame + offset]
                local r = byOffset[offset]
                if s then
                    if tag == "POS" and s.bodies[index] then
                        r.compared = r.compared + 1
                        for part = 0, Patch.PARTS - 1 do
                            r.pos = math.max(r.pos, vecDiff(s.bodies[index][part].pos, values, part * 3))
                        end
                    elseif tag == "QAT" and s.bodies[index] then
                        for _, transposed in ipairs({ false, true }) do
                            for part = 0, Patch.PARTS - 1 do
                                local q = Patch.quat(s.bodies[index][part].rot, transposed)
                                r.quat[transposed] = math.max(r.quat[transposed], quatDiff(q, values, part * 4))
                            end
                        end
                    elseif tag == "EOBJ" and s.objs[index] then
                        local o = s.objs[index]
                        r.objPos = math.max(r.objPos, vecDiff(o.pos, values, 0))
                        for _, transposed in ipairs({ false, true }) do
                            r.objQuat[transposed] = math.max(r.objQuat[transposed], quatDiff(Patch.quat(o.rot, transposed), values, 3))
                        end
                    end
                end
            end
        end
    end
    local best
    for offset = -1, 1 do
        local r = byOffset[offset]
        if r.compared > 0 and (not best or r.pos < byOffset[best].pos) then best = offset end
    end
    -- bodies' and objects' matrices come from different calls (get_body_info, get_obj_rot): checked apart
    local transposed, objTransposed = false, false
    if best and byOffset[best].quat[true] < byOffset[best].quat[false] then transposed = true end
    if best and byOffset[best].objQuat[true] < byOffset[best].objQuat[false] then objTransposed = true end
    return { offset = best, transposed = transposed, objTransposed = objTransposed, byOffset = byOffset }
end

local function joinNumbers(out, v, format)
    for k = 1, #v do out[#out + 1] = string.format(format, v[k]) end
end

---The replay with a FRAME on every frame from the first FRAME line to lastFrame: frames the game didn't
---write get each player's POS / QAT / LINVEL / ANGVEL and an EOBJ line for every object the game wrote one
---for, from full[frame + offset]. The game's own lines are kept as they are. An EOBJ line keeps the game's
---last line for that object past the state (sides, then what follows the velocities)
---@param lines string[]
---@param full table
---@param offset integer
---@param transposed boolean the bodies' quaternion order (calibrate)
---@param objTransposed boolean the objects'
---@param lastFrame integer
---@return string[] out
---@return integer inserted frames added
function Patch.patch(lines, full, offset, transposed, objTransposed, lastFrame)
    local out, inserted = {}, 0
    local frame, score = nil, "0 0 0 0"
    local objLines, objOrder = {}, {} -- id -> the game's last EOBJ values; ids in the order first seen
    local players = {}
    local function emit(f)
        local s = full[f + offset]
        if not s then return end
        inserted = inserted + 1
        out[#out + 1] = "FRAME " .. f .. "; " .. score
        for _, player in ipairs(players) do
            local b = s.bodies[player]
            if b then
                local pos, qat, lin, ang = {}, {}, {}, {}
                for part = 0, Patch.PARTS - 1 do
                    local p = b[part]
                    joinNumbers(pos, p.pos, "%.8f")
                    joinNumbers(qat, Patch.quat(p.rot, transposed), "%.6f")
                    joinNumbers(lin, p.lin, "%.6f")
                    joinNumbers(ang, p.ang, "%.6f")
                end
                out[#out + 1] = "POS " .. player .. "; " .. table.concat(pos, " ")
                out[#out + 1] = "QAT " .. player .. "; " .. table.concat(qat, " ")
                out[#out + 1] = "LINVEL " .. player .. "; " .. table.concat(lin, " ")
                out[#out + 1] = "ANGVEL " .. player .. "; " .. table.concat(ang, " ")
            end
        end
        for _, id in ipairs(objOrder) do
            local o = s.objs[id]
            if o then
                local v = {}
                for k, value in ipairs(objLines[id]) do v[k] = value end
                local q = Patch.quat(o.rot, objTransposed)
                for k = 1, 3 do v[k] = string.format("%.8f", o.pos[k]) end
                for k = 1, 4 do v[3 + k] = string.format("%.8f", q[k]) end
                for k = 1, 3 do
                    v[10 + k] = string.format("%.8f", o.lin[k])
                    v[13 + k] = string.format("%.8f", o.ang[k])
                end
                out[#out + 1] = "EOBJ " .. id .. "; " .. table.concat(v, " ")
            end
        end
    end
    for _, line in ipairs(lines) do
        local tag, index, values = Patch.fields(line)
        if tag == "FRAME" then
            if frame then
                for f = frame + 1, index - 1 do emit(f) end
            end
            frame = index
            score = table.concat(values, " ")
        elseif tag == "POS" and frame then
            local known = false
            for _, p in ipairs(players) do known = known or p == index end
            if not known then players[#players + 1] = index end
        elseif tag == "EOBJ" and frame then
            if not objLines[index] then objOrder[#objOrder + 1] = index end
            objLines[index] = values
        end
        out[#out + 1] = line
    end
    if frame then
        for f = frame + 1, lastFrame do emit(f) end
    end
    return out, inserted
end

return Patch
