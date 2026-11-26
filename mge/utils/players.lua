-- Players' start positions and rotations: engageplayerpos / engageplayerrot, comma-separated x y z per
-- player. Measured in game: pos moves every part by exactly that much; rot turns around the head as
-- rotX(x) rotY(y) rotZ(z) degrees; empty / all zeros means unset (engagedistance places them, rot is
-- ignored).
-- Edits are offsets from the world. Without positions the first edit fills them in (a guess, a hidden
-- reload, then the measured difference corrected). Changes go through set_gamerule, syncGamerules
-- (one undo step) and a reload

local Mat3 = MGE.Mat3
local History = MGE.History
local HOOK_SET = MGE.hookname .. "_players"
local atan2 = math.atan2 or math.atan -- 5.1 has atan2

---@class Players
local Players = {}
MGE.Players = Players

local POS, ROT = "engageplayerpos", "engageplayerrot"

---@return integer
function Players.count()
    return math.max(tonumber(get_game_rules().numplayers) or 2, 1)
end

---Numbers of a gamerule list, 3 per player, nil when it isn't set (empty, "0" or all zeros)
---@param name string
---@return number[]?
local function readList(name)
    local value = tostring(get_gamerule(name) or "")
    if value:match("^[%s0%.,%-]*$") then return nil end
    local list = {}
    for part in (value .. ","):gmatch("([^,]*),") do table.insert(list, tonumber(part) or 0) end
    for i = #list + 1, Players.count() * 3 do list[i] = 0 end
    return list
end

---Full precision: rounding like "2.50" would drift the center over edits
---@param list number[]
---@param count integer? players, default numplayers (given while it changes)
---@return string
local function formatList(list, count)
    local parts = {}
    for i = 1, (count or Players.count()) * 3 do parts[i] = MGE.FileHandler.formatNumber(list[i] or 0) end
    return table.concat(parts, ",")
end

---Rounded to whole degrees ("-0" as 0): the game keeps engageplayerrot in whole degrees
---@param degrees number
---@return number
function Players.wholeDegrees(degrees)
    local r = math.floor(degrees + 0.5)
    return r == 0 and 0 or r
end
local wholeDegrees = Players.wholeDegrees

---@param list number[] a gamerule list
---@param player integer 0-based
---@return number[] the player's x y z, 0 where missing
local function tripleOf(list, player)
    local i = player * 3
    return { list[i + 1] or 0, list[i + 2] or 0, list[i + 3] or 0 }
end

---@return boolean the mod sets player positions
function Players.hasPositions()
    return readList(POS) ~= nil
end

---Position (engageplayerpos) of a player, nil when not set
---@param player integer 0-based
---@return number[]?
function Players.getPos(player)
    local list = readList(POS)
    return list and { list[player * 3 + 1], list[player * 3 + 2], list[player * 3 + 3] }
end

---Rotation in degrees (engageplayerrot) of a player, nil when positions aren't set
---@param player integer
---@return number[]?
function Players.getRot(player)
    if not Players.hasPositions() then return nil end
    return tripleOf(readList(ROT) or {}, player)
end

-- live bodies ---------------------------------------------------------------------------------------

---Rotation of a body part, rows like the game's matrix (r0 r1 r2 is the first row)
---@param b BodyInfo
---@return number[][]
local function bodyRot(b)
    local r = b.rot
    return { { r.r0, r.r1, r.r2 }, { r.r4, r.r5, r.r6 }, { r.r8, r.r9, r.r10 } }
end

---@param player integer
---@return boolean the player is in the world
function Players.exists(player)
    if player < 0 or player >= Players.count() then return false end
    local ok, b = pcall(get_body_info, player, BODYPARTS.HEAD)
    return ok and b ~= nil and b.pos ~= nil
end

---Average of the body part positions
---@param player integer
---@return number[]
function Players.center(player)
    local s, n = { 0, 0, 0 }, 0
    for _, id in pairs(BODYPARTS) do
        local p = get_body_info(player, id).pos
        s[1], s[2], s[3], n = s[1] + p.x, s[2] + p.y, s[3] + p.z, n + 1
    end
    return { s[1] / n, s[2] / n, s[3] / n }
end

---Head position: engageplayerrot turns the player around it
---@param player integer
---@return number[]
function Players.head(player)
    local p = get_body_info(player, BODYPARTS.HEAD).pos
    return { p.x, p.y, p.z }
end

---Facing in degrees around z, from the groin's rotation (0: like player 0 without rotation)
---@param player integer
---@return number
function Players.yaw(player)
    local m = bodyRot(get_body_info(player, BODYPARTS.GROIN))
    return math.deg(atan2(m[2][1], m[1][1]))
end

---Live state of every body part, to preview a drag from and restore after. Joints follow the bodies
---@param player integer
---@return table
function Players.snapshot(player)
    local s = { bodies = {} }
    for _, id in pairs(BODYPARTS) do
        local b = get_body_info(player, id)
        s.bodies[id] = { pos = { b.pos.x, b.pos.y, b.pos.z }, rot = bodyRot(b) }
    end
    return s
end

---@type { players: integer[], pivot: number[], factor: number }? a scale drag in progress, drawn by the
---highlight (bodies can't be resized live)
Players.scalePreview = nil

---Puts every body part where fn says, from a snapshot. Joints follow on their own (setting them too
---moves them twice)
---@param player integer
---@param snap table Players.snapshot
---@param fn fun(p: number[]): number[]
---@param turn number[][]? rotation added to every part's own rotation
local function placeFrom(player, snap, fn, turn)
    for id, b in pairs(snap.bodies) do
        local p = fn(b.pos)
        set_body_pos(player, id, p[1], p[2], p[3])
        local m = turn and Mat3.mul(turn, b.rot) or b.rot
        set_body_rotation_m(player, id, MGE.Highlight.toMatrixTB(m))
    end
end

-- writing -------------------------------------------------------------------------------------------

---Writes the lists as gamerules, then into the mod data as one undo step, and reloads
---@param pos number[]
---@param rot number[]
---@param count integer? players, see formatList
local function commit(pos, rot, count)
    set_gamerule(POS, formatList(pos, count))
    set_gamerule(ROT, formatList(rot, count))
    -- unversioned mods ignore engageplayerrot
    MGE.FileHandler.ensureVersion(MGE.ModData.parsed)
    MGE.syncGamerules()
    History.commit()
    MGE.apply()
end

---@type { waitFrames: integer, run: fun() }? work waiting for a reload (players are placed a few
---frames after it)
local pending = nil

---Reloads (MGE.apply, no undo step) and runs fn once the players are placed again, to measure them
---@param fn fun()
local function afterReload(fn)
    pending = { run = fn }
    MGE.FileHandler.ensureVersion(MGE.ModData.parsed) -- so rotations apply in what's measured
    MGE.apply()
end

add_hook("draw3d", HOOK_SET, function()
    if not pending or MGE.reloadPending then return end
    pending.waitFrames = (pending.waitFrames or 3) - 1
    if pending.waitFrames > 0 then return end
    local done = pending
    pending = nil -- before running: it may wait for another reload
    local ok, err = pcall(done.run)
    if not ok then MGE.say("players: " .. tostring(err)) end
end)

---Position list corrected so each player's measured center lands on its target (exact: positions
---shift a player rigidly)
---@param targets table<integer, number[]> player -> wanted center
---@return number[]
local function correctedPositions(targets)
    local pos = readList(POS) or {}
    for p, t in pairs(targets) do
        local c = Players.center(p)
        for k = 1, 3 do pos[p * 3 + k] = (pos[p * 3 + k] or 0) + t[k] - c[k] end
    end
    return pos
end

---Runs then_ once the mod has positions that keep every player where it is now: right away if set,
---else after a guess (head and facing), a reload without undo step and a measured correction
---@param then_ fun()
local function ensurePositions(then_)
    if Players.hasPositions() then return then_() end
    if pending then return end -- already waiting for a reload
    local pos, rot, targets = {}, {}, {}
    for p = 0, Players.count() - 1 do
        local head = Players.head(p)
        targets[p] = Players.center(p)
        pos[p * 3 + 1], pos[p * 3 + 2], pos[p * 3 + 3] = head[1], head[2], head[3]
        rot[p * 3 + 1], rot[p * 3 + 2], rot[p * 3 + 3] = 0, 0, wholeDegrees(Players.yaw(p))
    end
    set_gamerule(POS, formatList(pos))
    set_gamerule(ROT, formatList(rot))
    -- no undo step: undoing the edit goes back to no positions
    afterReload(function()
        local corrected = correctedPositions(targets)
        set_gamerule(POS, formatList(corrected))
        -- shift the bodies from the guess to the corrected place
        for p, t in pairs(targets) do
            local c, snap = Players.center(p), Players.snapshot(p)
            local d = { t[1] - c[1], t[2] - c[2], t[3] - c[3] }
            placeFrom(p, snap, function(q) return { q[1] + d[1], q[2] + d[2], q[3] + d[3] } end)
        end
        then_()
    end)
end

table.insert(MGE.onQuit, function() remove_hooks(HOOK_SET) end)

---@param players integer|integer[] one player or several
---@return integer[]
local function asList(players)
    return type(players) == "table" and players or { players }
end

---Moves players by offset (world units), one undo step for all of them
---@param players integer|integer[] 0-based
---@param offset number[]
function Players.moveBy(players, offset)
    local list = asList(players)
    -- measured now: the bodies are placed after the reload
    MGE.Camera.followPlayer(list, { offset = offset })
    ensurePositions(function()
        local pos, rot = readList(POS) or {}, readList(ROT) or {}
        for _, player in ipairs(list) do
            for k = 1, 3 do pos[player * 3 + k] = (pos[player * 3 + k] or 0) + offset[k] end
        end
        commit(pos, rot)
    end)
end

---Average of the players' centers (the gizmo's pivot)
---@param players integer[]
---@return number[]
function Players.groupCenter(players)
    local s = { 0, 0, 0 }
    for _, player in ipairs(players) do
        local c = Players.center(player)
        for k = 1, 3 do s[k] = s[k] + c[k] / #players end
    end
    return s
end

---engageplayerrot's x y z (degrees) as rotX(x) rotY(y) rotZ(z), measured in game
---@param r number[] x y z degrees
---@return number[][]
local function rotMatrix(r)
    return Mat3.fromEulerDegrees(r[1], r[2], r[3])
end

---Turns players by a world rotation around pivot as one rigid group (one undo step). The game turns
---around the head, so the position takes up the difference to turning around the pivot
---@param players integer|integer[] 0-based
---@param m number[][] world rotation
---@param pivot number[]? default Players.groupCenter
function Players.rotateByMatrix(players, m, pivot)
    local list = asList(players)
    ensurePositions(function()
        local pos, rot = readList(POS) or {}, readList(ROT) or {}
        local p = pivot or Players.groupCenter(list)
        for _, player in ipairs(list) do
            local i = player * 3
            local current = rotMatrix(tripleOf(rot, player))
            local x, y, z = Mat3.toEulerXYZ(Mat3.mul(m, current))
            -- rounded like the game will: the position follows the rounded turn
            local turned = { wholeDegrees(math.deg(x)), wholeDegrees(math.deg(y)), wholeDegrees(math.deg(z)) }
            rot[i + 1], rot[i + 2], rot[i + 3] = turned[1], turned[2], turned[3]
            local mi = Mat3.mul(rotMatrix(turned), Mat3.transpose(current))
            local c, h = Players.center(player), Players.head(player)
            local wanted = Mat3.apply(mi, { c[1] - p[1], c[2] - p[2], c[3] - p[3] })
            local byHead = Mat3.apply(mi, { c[1] - h[1], c[2] - h[2], c[3] - h[3] })
            for k = 1, 3 do pos[i + k] = (pos[i + k] or 0) + (p[k] + wanted[k]) - (h[k] + byHead[k]) end
        end
        commit(pos, rot)
    end)
end

---Current rotation: engageplayerrot when positions are set, else the groin's live rotation
---@param player integer
---@return number[][]
local function currentRotation(player)
    local rot = Players.hasPositions() and readList(ROT)
    if rot then return rotMatrix(tripleOf(rot, player)) end
    return bodyRot(get_body_info(player, BODYPARTS.GROIN))
end

---Pos / Rot as the panel shows them: group center relative to POS_ORIGIN, the first player's rotation
---@param players integer|integer[] first: the one whose rotation is shown
---@return number[] pos, number[] rot
function Players.shown(players)
    local list = asList(players)
    local c, o = Players.groupCenter(list), MGE.POS_ORIGIN or { 0, 0, 0 }
    local x, y, z = Mat3.toEulerXYZ(currentRotation(list[1]))
    return { c[1] - o[1], c[2] - o[2], c[3] - o[3] }, { math.deg(x), math.deg(y), math.deg(z) }
end

---Pos row: moves the group so its center's typed axes match
---@param players integer|integer[]
---@param typed (number?)[]
function Players.setShownPos(players, typed)
    local shown = Players.shown(players)
    local offset = {}
    for k = 1, 3 do offset[k] = typed[k] and typed[k] - shown[k] or 0 end
    Players.moveBy(players, offset)
end

---Rot row: turns the group so the first player has the typed angles
---@param players integer|integer[] first: the one the angles are for
---@param typed (number?)[]
function Players.setShownRot(players, typed)
    local list = asList(players)
    local _, shownRot = Players.shown(list)
    local wanted = {}
    for k = 1, 3 do wanted[k] = typed[k] or shownRot[k] end
    Players.rotateByMatrix(list, Mat3.mul(rotMatrix(wanted), Mat3.transpose(currentRotation(list[1]))))
end

---Average of partAverage over players: what the players panel shows for a selection
---@param players integer|integer[]
---@param key "density"|"strength"|"friction"|"bounce"
---@return number
function Players.groupPartAverage(players, key)
    local list, sum = asList(players), 0
    for _, player in ipairs(list) do sum = sum + Players.partAverage(player, key) end
    return #list > 0 and sum / #list or 0
end

---Turns a player around z by degrees, around its center
---@param player integer
---@param degrees number
function Players.rotateBy(player, degrees)
    Players.rotateByMatrix(player, Mat3.rotZ(math.rad(degrees)))
end

---Pos / Rot rows: sets the typed axes of a player's position or rotation (nil axes stay)
---@param player integer
---@param typedPos (number?)[]?
---@param typedRot (number?)[]?
function Players.setValues(player, typedPos, typedRot)
    ensurePositions(function()
        local pos, rot = readList(POS) or {}, readList(ROT) or {}
        for k = 1, 3 do
            if typedPos and typedPos[k] then pos[player * 3 + k] = typedPos[k] end
            if typedRot and typedRot[k] then rot[player * 3 + k] = typedRot[k] end
        end
        commit(pos, rot)
    end)
end

-- scaling -------------------------------------------------------------------------------------------
-- Scaling rewrites the `player N` section's part positions, sides and joint radii around the model's
-- center. Density and strength stay (a bigger player is heavier)

local BodyParts = MGE.BodyParts
local parseSection, getProp, setProp = BodyParts.parseSection, BodyParts.getProp, BodyParts.setProp
local sectionLines, readVec = BodyParts.sectionLines, BodyParts.readVec

---Rewrites a player's section scaled around its model center. Missing pos / sides / radius lines come
---from the live body; a player on shared parts gets its own section
---@param player integer
---@param factor number
local function scaleSection(player, factor)
    local ModData, FH = MGE.ModData, MGE.FileHandler
    local lines = FH.getPlayerLines(ModData.parsed, player) or FH.getSharedPlayerLines(ModData.parsed) or {}
    local section = parseSection(lines)
    local byKey = {}
    for _, part in ipairs(section.parts) do byKey[part.kind .. ":" .. part.name] = part end
    ---@return table
    local function partFor(kind, name)
        local key = kind .. ":" .. name
        if not byKey[key] then
            byKey[key] = { kind = kind, name = name, props = {} }
            table.insert(section.parts, byKey[key])
        end
        return byKey[key]
    end

    -- live -> model frame: ref + R^T (live - liveRef); any whole-model shift is corrected after the reload
    local rot = readList(ROT) or {}
    local Rt = Mat3.transpose(rotMatrix(tripleOf(rot, player)))
    local liveRef = Players.head(player)
    local ref = readVec(byKey["body:head"] and getProp(byKey["body:head"], "pos")) or { 1, 0.9, 2.9 }
    local function toModel(live)
        local r = Mat3.apply(Rt, { live[1] - liveRef[1], live[2] - liveRef[2], live[3] - liveRef[3] })
        return { ref[1] + r[1], ref[2] + r[2], ref[3] + r[3] }
    end

    local entries = {}
    for name, id in pairs(BODYPARTS) do
        local part = partFor("body", name:lower())
        local b = get_body_info(player, id)
        local pos = readVec(getProp(part, "pos")) or toModel({ b.pos.x, b.pos.y, b.pos.z })
        local sides = readVec(getProp(part, "sides")) or { b.sides.x, b.sides.y, b.sides.z }
        table.insert(entries, { part = part, pos = pos, sides = sides })
    end
    for name, id in pairs(JOINTS) do
        local part = partFor("joint", name:lower())
        local pos = readVec(getProp(part, "pos")) or toModel({ get_joint_pos(player, id) })
        local radius = tonumber(getProp(part, "radius")) or get_joint_radius(player, id)
        table.insert(entries, { part = part, pos = pos, radius = radius })
    end

    local center, n = { 0, 0, 0 }, 0
    for _, e in ipairs(entries) do
        if e.sides then
            for k = 1, 3 do center[k] = center[k] + e.pos[k] end
            n = n + 1
        end
    end
    for k = 1, 3 do center[k] = center[k] / n end
    local fmt = FH.formatNumbers
    for _, e in ipairs(entries) do
        local p = {}
        for k = 1, 3 do p[k] = center[k] + (e.pos[k] - center[k]) * factor end
        setProp(e.part, "pos", fmt(p[1], p[2], p[3]))
        if e.sides then
            setProp(e.part, "sides", fmt(e.sides[1] * factor, e.sides[2] * factor, e.sides[3] * factor))
        else
            setProp(e.part, "radius", FH.formatNumber(e.radius * factor))
        end
    end
    FH.setPlayerLines(ModData.parsed, player, sectionLines(section))
end

-- defaults for parts without the line, from the game's modmaker.tbm
local DEFAULT_DENSITY = 0.25
local DEFAULT_STRENGTH = {
    neck = 1, chest = 4, lumbar = 3, abs = 3, r_pecs = 3, r_shoulder = 4, r_elbow = 2, l_pecs = 3,
    l_shoulder = 4, l_elbow = 2, r_wrist = 2, l_wrist = 2, r_glute = 4, l_glute = 4, r_hip = 2, l_hip = 2,
    r_knee = 4, l_knee = 4, r_ankle = 1, l_ankle = 1,
}
-- which part kinds have the line, and its default per part name
local PART_KEYS = {
    density = { body = true, default = function() return DEFAULT_DENSITY end },
    strength = { joint = true, default = function(name) return DEFAULT_STRENGTH[name] or 1 end },
    friction = { body = true, joint = true, default = function() return 0.3 end },
    bounce = { body = true, joint = true, default = function() return 0.1 end },
}

---Calls fn(part, value) for every part the key applies to (value: its line or the default). With
---create, missing parts are added
---@param section table parseSection result
---@param key "density"|"strength"|"friction"|"bounce"
---@param create boolean
---@param fn fun(part: table|nil, value: number, name: string)
local function eachPart(section, key, create, fn)
    local spec = PART_KEYS[key]
    for _, kind in ipairs({ "body", "joint" }) do
        if spec[kind] then
            local byName = {}
            for _, part in ipairs(section.parts) do
                if part.kind == kind then byName[part.name] = part end
            end
            for name in pairs(kind == "body" and BODYPARTS or JOINTS) do
                name = name:lower()
                local part = byName[name]
                if not part and create then
                    part = { kind = kind, name = name, props = {} }
                    table.insert(section.parts, part)
                end
                fn(part, part and tonumber(getProp(part, key)) or spec.default(name), name)
            end
        end
    end
end

---A player's parsed section: its own lines, else the shared ones
local function playerSection(player)
    return (BodyParts.section(MGE.ModData.parsed, player))
end

---Average of a part value over a player's parts (defaults for missing lines)
---@param player integer
---@param key "density"|"strength"|"friction"|"bounce"
---@return number
function Players.partAverage(player, key)
    local sum, n = 0, 0
    eachPart(playerSection(player), key, false, function(_, value)
        sum, n = sum + value, n + 1
    end)
    return n > 0 and sum / n or 0
end

-- the default body's head and groin (modmaker.tbm, player 0): their distance is size 1
local DEFAULT_HEAD, DEFAULT_GROIN = { 1, 0.85, 2.65 }, { 1, 1, 1.55 }

---@return number
local function distance(a, b)
    local x, y, z = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(x * x + y * y + z * z)
end

---Size relative to the default body (head to groin distance), from the mod data so it shows before
---the players are placed
---@param player integer
---@return number
function Players.size(player)
    local head, groin
    for _, part in ipairs(playerSection(player).parts) do
        if part.kind == "body" and part.name == "head" then head = readVec(getProp(part, "pos")) end
        if part.kind == "body" and part.name == "groin" then groin = readVec(getProp(part, "pos")) end
    end
    return distance(head or DEFAULT_HEAD, groin or DEFAULT_GROIN) / distance(DEFAULT_HEAD, DEFAULT_GROIN)
end

---Average Players.size (the Scale row)
---@param players integer|integer[]
---@return number
function Players.groupSize(players)
    local list, sum = asList(players), 0
    for _, player in ipairs(list) do sum = sum + Players.size(player) end
    return #list > 0 and sum / #list or 1
end

---Rewrites a part value on every part of the players (one undo step and a reload)
local function changeParts(list, key, change)
    local FH = MGE.FileHandler
    for _, player in ipairs(list) do
        local section = playerSection(player)
        eachPart(section, key, true, function(part, value)
            setProp(part, key, FH.formatNumber(change(value)))
        end)
        FH.setPlayerLines(MGE.ModData.parsed, player, sectionLines(section))
    end
    History.commit()
    MGE.apply()
end

---Multiplies a part value (ratios stay). Negative factors only for friction
---@param players integer|integer[] 0-based
---@param key "density"|"strength"|"friction"|"bounce"
---@param factor number
function Players.multiplyParts(players, key, factor)
    local list = asList(players)
    if #list == 0 or (factor < 0 and key ~= "friction") or math.abs(factor - 1) < 1e-9 then return end
    changeParts(list, key, function(value) return value * factor end)
end

---Sets a part value everywhere (when the average is 0, a factor can't work)
---@param players integer|integer[] 0-based
---@param key "density"|"strength"|"friction"|"bounce"
---@param value number
function Players.setParts(players, key, value)
    local list = asList(players)
    if #list == 0 then return end
    changeParts(list, key, function() return value end)
end

---Rough world bounds of a player's body parts (rotation ignored)
---@param player integer
---@return { min: number[], max: number[] }
function Players.bounds(player)
    local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for _, id in pairs(BODYPARTS) do
        local b = get_body_info(player, id)
        local s = b.sides
        local half = b.shape == 0 and s.x or (b.shape == 2 and s.y / 2 + s.x) or math.max(s.x, s.y, s.z) / 2
        local p = { b.pos.x, b.pos.y, b.pos.z }
        for k = 1, 3 do
            lo[k], hi[k] = math.min(lo[k], p[k] - half), math.max(hi[k], p[k] + half)
        end
    end
    return { min = lo, max = hi }
end

---Scales players uniformly around pivot as one group (one undo step). Placement is measured after a
---reload and corrected
---@param players integer|integer[] 0-based
---@param factor number
---@param pivot number[]? default Players.groupCenter
function Players.scaleBy(players, factor, pivot)
    local list = asList(players)
    if #list == 0 or factor <= 0 or math.abs(factor - 1) < 1e-9 then return end
    MGE.Camera.followPlayer(list, { factor = factor, pivot = pivot or Players.groupCenter(list) })
    ensurePositions(function()
        local p = pivot or Players.groupCenter(list)
        local targets = {}
        for _, player in ipairs(list) do
            local c = Players.center(player)
            targets[player] = { p[1] + (c[1] - p[1]) * factor, p[2] + (c[2] - p[2]) * factor, p[3] + (c[3] - p[3]) * factor }
            scaleSection(player, factor)
        end
        afterReload(function()
            local rot = readList(ROT) or {}
            commit(correctedPositions(targets), rot)
        end)
    end)
end

-- adding and removing players -----------------------------------------------------------------------

Players.MAX = 4 -- the game's gamerules menu allows 1-4
local NUMPLAYERS = "numplayers"
local DUPLICATE_GAP = 0.3 -- between the copied players and their copies, along x

---@return boolean room for n more players (says why not in chat)
local function haveRoom(n)
    if Players.count() + n <= Players.MAX then return true end
    MGE.say("a mod can have at most " .. Players.MAX .. " players")
    return false
end

---@param list integer[]
---@return { min: number[], max: number[] }
local function groupBounds(list)
    local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for _, player in ipairs(list) do
        local b = Players.bounds(player)
        for k = 1, 3 do lo[k], hi[k] = math.min(lo[k], b.min[k]), math.max(hi[k], b.max[k]) end
    end
    return { min = lo, max = hi }
end

---Adds players after the last one (one undo step): each entry copies a player (shifted) or is false
---for a default body placed on the floor at spawnPoint. Placement is measured and corrected after the
---reload; done(new ids) runs then
---@param sources (integer|false)[]
---@param shift number[] for copies
---@param spawnPoint number[]? for default bodies (floor point), default in front of player 0
---@param done fun(ids: integer[])?
local function addPlayers(sources, shift, spawnPoint, done)
    if #sources == 0 or not haveRoom(#sources) then return end
    ensurePositions(function()
        if not haveRoom(#sources) then return end
        local ModData, FH = MGE.ModData, MGE.FileHandler
        local first = Players.count()
        local pos, rot = readList(POS) or {}, readList(ROT) or {}
        local targets, fresh, ids = {}, {}, {}
        for i, src in ipairs(sources) do
            local id = first + i - 1
            ids[i] = id
            if src then
                local c = Players.center(src)
                targets[id] = { c[1] + shift[1], c[2] + shift[2], c[3] + shift[3] }
                for k = 1, 3 do
                    pos[id * 3 + k] = (pos[src * 3 + k] or 0) + shift[k]
                    rot[id * 3 + k] = rot[src * 3 + k] or 0
                end
                local own = FH.getPlayerLines(ModData.parsed, src)
                if own then FH.setPlayerLines(ModData.parsed, id, own) else FH.renumberPlayers(ModData.parsed, { [id] = false }) end
            else
                -- drop a leftover section with this id
                FH.renumberPlayers(ModData.parsed, { [id] = false })
                local p = spawnPoint or Players.head(0)
                fresh[id] = p
                pos[id * 3 + 1], pos[id * 3 + 2], pos[id * 3 + 3] = p[1], p[2], p[3] + 1
                rot[id * 3 + 1], rot[id * 3 + 2], rot[id * 3 + 3] = 0, 0, 0
            end
        end
        local count = first + #sources
        set_gamerule(NUMPLAYERS, tostring(count))
        set_gamerule(POS, formatList(pos, count))
        set_gamerule(ROT, formatList(rot, count))
        afterReload(function()
            for id, p in pairs(fresh) do
                local b, c = Players.bounds(id), Players.center(id)
                local d = MGE.Camera.spawnShift(b, p)
                targets[id] = { c[1] + d[1], c[2] + d[2], c[3] + d[3] }
            end
            if done then done(ids) end
            -- camera follow where the correction will put them
            local now, offset = Players.groupCenter(ids), { 0, 0, 0 }
            for _, id in ipairs(ids) do
                for k = 1, 3 do offset[k] = offset[k] + targets[id][k] / #ids end
            end
            for k = 1, 3 do offset[k] = offset[k] - now[k] end
            MGE.Camera.followPlayer(ids, { offset = offset })
            commit(correctedPositions(targets), readList(ROT) or {})
        end)
    end)
end

---New player with the default body (or shared parts), on the floor at point
---@param point number[]? floor point, default in front of player 0
---@param done fun(ids: integer[])? called with the new id
function Players.addNew(point, done)
    addPlayers({ false }, { 0, 0, 0 }, point, done)
end

---Copies of players, placed next to them along x
---@param players integer|integer[] 0-based
---@param done fun(ids: integer[])? called with the copies' ids
function Players.duplicate(players, done)
    local list = asList(players)
    if #list == 0 then return end
    local b = groupBounds(list)
    addPlayers(list, { b.max[1] - b.min[1] + DUPLICATE_GAP, 0, 0 }, nil, done)
end

---Removes players (one undo step); later players move down to fill the ids. One always stays
---@param players integer|integer[] 0-based
---@param done fun(map: table<integer, integer|false>)? old id -> new id, false for removed
function Players.remove(players, done)
    local removed = {}
    for _, p in ipairs(asList(players)) do
        if p >= 0 and p < Players.count() then removed[p] = true end
    end
    local n = 0
    for _ in pairs(removed) do n = n + 1 end
    if n == 0 then return end
    if n >= Players.count() then
        MGE.say("a mod needs at least one player")
        return
    end
    ensurePositions(function()
        local count = Players.count()
        local pos, rot = readList(POS) or {}, readList(ROT) or {}
        local map, newPos, newRot, kept = {}, {}, {}, 0
        for p = 0, count - 1 do
            if removed[p] then
                map[p] = false
            else
                map[p] = kept
                for k = 1, 3 do
                    newPos[kept * 3 + k] = pos[p * 3 + k] or 0
                    newRot[kept * 3 + k] = rot[p * 3 + k] or 0
                end
                kept = kept + 1
            end
        end
        -- one pass: renames never meet a renamed header
        MGE.FileHandler.renumberPlayers(MGE.ModData.parsed, map)
        set_gamerule(NUMPLAYERS, tostring(kept))
        if done then done(map) end
        commit(newPos, newRot, kept)
    end)
end

-- gizmo target --------------------------------------------------------------------------------------

---Gizmo target for players: Move, Rotate and uniform Scale around their shared center (fixed at creation)
---@param players integer|integer[] 0-based
---@return table?
function Players.target(players)
    if pending then return nil end -- about to be placed again
    local list = {}
    for _, player in ipairs(asList(players)) do
        if Players.exists(player) then table.insert(list, player) end
    end
    if #list == 0 then return nil end
    local snaps, pivot = nil, Players.groupCenter(list)
    local t = { players = list, scalable = true, uniformScaleOnly = true }
    function t.pivot() return pivot end
    function t.frame() return Mat3.IDENTITY end
    function t.begin()
        snaps = {}
        for _, player in ipairs(list) do snaps[player] = Players.snapshot(player) end
    end
    ---@param fn fun(p: number[]): number[]
    ---@param turn number[][]?
    local function placeAll(fn, turn)
        if not snaps then return end
        for player, snap in pairs(snaps) do placeFrom(player, snap, fn, turn) end
    end
    function t.previewMove(offset)
        placeAll(function(p) return { p[1] + offset[1], p[2] + offset[2], p[3] + offset[3] } end)
    end
    function t.previewRotate(m)
        placeAll(function(p)
            local r = Mat3.apply(m, { p[1] - pivot[1], p[2] - pivot[2], p[3] - pivot[3] })
            return { pivot[1] + r[1], pivot[2] + r[2], pivot[3] + r[3] }
        end, m)
    end
    -- set_body_sides / set_joint_radius do nothing live: the highlight draws the scale instead
    function t.previewScale(factors)
        Players.scalePreview = { players = list, pivot = pivot, factor = factors[1] }
    end
    function t.restoreLive()
        Players.scalePreview = nil
        placeAll(function(p) return p end)
    end
    function t.scaleBy(factors)
        t.restoreLive()
        Players.scaleBy(list, factors[1], pivot)
    end
    function t.moveBy(offset)
        t.restoreLive()
        Players.moveBy(list, offset)
    end
    function t.rotateByMatrix(m)
        t.restoreLive()
        Players.rotateByMatrix(list, m, pivot)
    end
    return t
end

return Players
