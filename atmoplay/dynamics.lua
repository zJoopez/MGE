-- Dynamic atmo props (proof of concept; docs/atmo-play-plan.md, section 6): pushable atmo objects. An
-- atmo object is a prop when its flag line lacks the static bit (colliders.lua). A playable mod with props
-- has a second pool: hidden DYNAMIC objects on free ids 1-48 (the game shows no predictions above 48 and
-- such objects misbehave in replays), parked on a hidden static platform far below the map.
--
-- In fights (draw2d, once per new match frame, like the static pool):
--   * wanted: props within `radius` of a player's center (distance to the prop's bounding sphere), and props
--     touching a moving carried prop (chain reactions); nearest first, per group (shape and friction)
--   * a wanted prop without an object gets a free one of its group: put at the prop's pose, velocities zero
--   * a carried prop is released only when it's no longer wanted, AT REST and no body part is near it: its
--     pose is kept, the object goes back to its parking spot (free from the next frame)
--   * the static pool also covers carried props (moreCenters): a pushed prop keeps a floor under it
-- The prop's drawn copy (its atmo object) follows it: the game's atmo items are moved to the prop's pose.
--
-- Replays move nothing: the game replays the pool objects (EOBJ lines). The script WATCHES them to know
-- where the props are: an object leaving its parking spot took the free prop of its group nearest to where
-- it appeared; an object going back left its prop where it was last seen. Everything that happened is kept
-- as events by frame (taken / released, with the pose), so a frame going back (replay rewind, a replay
-- edited and played on) rebuilds the props from them.
-- Measured (plan, section 6): the game's own replays of dynamic objects drift a little in some fights, the
-- pool no more than a normal mod; cached replays misplace teleported objects (the drawn props follow them).

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Colliders = NS.Colliders

---@class AtmoPlayProp : AtmoPlayCollider
---@field mass number?
---@field home { pos: number[], rot: table } the atmo's pose (rot: MatrixTB)
---@field rot table MatrixTB now
---@field entry AtmoPlayDynEntry? the pool object carrying it
---@field item table? its drawn copy (an atmo UIElement3D), found after the atmo loads
---@field drawn boolean its copy was moved from the atmo's pose

---@class AtmoPlayDynEntry
---@field id integer env_obj id as the file writes it
---@field group string
---@field prop AtmoPlayProp?
---@field speed number
---@field spin number
---@field seen { pos: number[], rot: table }? replays: where it was last seen carrying its prop

---@class AtmoPlayDynamics
local Dynamics = {
    DEFAULT_RADIUS = 2,
    REST_SPEED = 0.05,
    REST_SPIN = 0.1,
    TOUCH = 0.5, -- a body part this close to a prop's bounding sphere touches it: not released
    CHAIN = 0.3, -- a prop this close to a moving carried prop's sphere is wanted too
    MOVING = 0.2, -- a carried prop faster than this pulls in the props it touches
    MATCH = 0.5, -- replays: an object that appeared takes the free prop within this of its sphere
    PARK_Z = -50000, -- the parking platform's center height
    PLATFORM_SIDES = { 120, 4, 1 },
    PARK_SIDE = 0.5, -- a parked object's sides
    FALL = 50, -- a carried prop this far below the lowest prop's start fell off the map: released
}

local IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0 }

---Where a pool object parks: on the platform, one spot per id
---@param id integer the file id
---@return number x, number y, number z
function Dynamics.parkPos(id)
    return id * 2 - 50, 0, Dynamics.PARK_Z + Dynamics.PLATFORM_SIDES[3] / 2 + Dynamics.PARK_SIDE / 2 + 0.01
end

---@param z number
---@return boolean the object is parked (far below every map)
local function isParked(z)
    return z < Dynamics.PARK_Z / 2
end

---@param frame number[][]
---@return table MatrixTB (as driver.lua's)
local function matrixTB(frame)
    return {
        r0 = frame[1][1], r1 = frame[1][2], r2 = frame[1][3], r3 = 0,
        r4 = frame[2][1], r5 = frame[2][2], r6 = frame[2][3], r7 = 0,
        r8 = frame[3][1], r9 = frame[3][2], r10 = frame[3][3], r11 = 0,
    }
end

---get_obj_rot's matrix (a number list or a MatrixTB) as a MatrixTB copy
local function copyTB(m)
    local out = {}
    if type(m) ~= "table" then return IDENTITY end
    if m.r0 ~= nil then
        for k = 0, 11 do out["r" .. k] = m["r" .. k] or 0 end
    else
        for k = 0, 11 do out["r" .. k] = m[k + 1] or 0 end
    end
    return out
end

---A pose read from an object, as new tables only where it changed: a still prop keeps its tables, so its
---drawn copy isn't redrawn (drawCopies compares tables)
local function updatePose(prop, x, y, z, rot)
    local p = prop.pos
    if x ~= p[1] or y ~= p[2] or z ~= p[3] then prop.pos = { x, y, z } end
    local r = prop.rot
    for k = 0, 10 do
        local key = "r" .. k
        if rot[key] ~= r[key] then
            prop.rot = rot
            return
        end
    end
end

local function dist(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local clock = os and os.clock or function() return 0 end

---------------------------------------------------------------------------------------------------- the grid

-- Props that can get an object (their group has a pool) are listed by the x / y cell they rest in, so a
-- frame looks only at the cells around the players and the pushed props, not at every prop of the map. A
-- carried prop stays listed where it was taken (the searches add the carried ones themselves) and moves
-- to its new cell when it's released or the props are rebuilt. noGrid: every prop every time (the tests
-- compare: the same takes and releases)

---A cell's key: one number, cells -32768..32767 per axis (as pool.lua's)
local function cellKey(x, y)
    return (x + 32768) * 65536 + (y + 32768)
end

local function cellOf(s, v)
    return math.floor(v / s.cellSize)
end

---Lists a prop in the cell of where it is now (moved out of its old one)
local function gridPlace(s, prop)
    if s.noGrid or not prop.grouped then return end
    local key = cellKey(cellOf(s, prop.pos[1]), cellOf(s, prop.pos[2]))
    if prop.cell == key then return end
    if prop.cell then
        local list = s.cells[prop.cell]
        for i = #list, 1, -1 do
            if list[i] == prop then
                table.remove(list, i)
                break
            end
        end
    end
    local list = s.cells[key]
    if not list then
        list = {}
        s.cells[key] = list
    end
    list[#list + 1] = prop
    prop.cell = key
end

---Adds to `out` (once each, `seen`) every listed prop that can be within `reach` of point p in x / y
local function gather(s, p, reach, out, seen)
    if s.noGrid then
        for _, prop in ipairs(s.grouped) do
            if not seen[prop] then
                seen[prop] = true
                out[#out + 1] = prop
            end
        end
        return
    end
    for x = cellOf(s, p[1] - reach), cellOf(s, p[1] + reach) do
        for y = cellOf(s, p[2] - reach), cellOf(s, p[2] + reach) do
            local list = s.cells[cellKey(x, y)]
            if list then
                for _, prop in ipairs(list) do
                    if not seen[prop] then
                        seen[prop] = true
                        out[#out + 1] = prop
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- state

---@param objects AtmoPlayPoolObject[] the mod's dynamic pool (Format.read's `dynamic`)
---@param props AtmoPlayCollider[] Colliders.build's third result
---@param params { dradius: number?, noCopies: boolean?, noGrid: boolean? }? the mod header's (noCopies:
---MGE's own; noGrid: tests)
---@return table? state, string? error
function Dynamics.new(objects, props, params)
    params = params or {}
    local s = {
        radius = tonumber(params.dradius) or Dynamics.DEFAULT_RADIUS,
        entries = {}, groups = {}, groupKeys = {}, props = {}, byGroup = {}, byIndex = {},
        noCopies = params.noCopies, -- MGE: it draws the atmo itself, the game's atmo copies aren't moved
        noGrid = params.noGrid,
        grouped = {}, cells = {}, maxRadius = 0,
        dirty = {}, dirtyAll = true, -- drawn copies to update: props whose pose changed (or all of them)
        events = {}, lastFrame = nil, wasReplay = false, holder = nil,
        steps = 0, stepTime = 0, worstStep = 0, -- ms, fights and replays alike (/atmoplay status)
    }
    s.cellSize = math.max(s.radius * 2, 1)
    for _, object in ipairs(objects) do
        local shape = Colliders.shapeOf(object.shape) or "box"
        s.entries[#s.entries + 1] = { id = object.id, group = shape .. "|" .. Colliders.frictionKey(object.friction),
            prop = nil, speed = 0, spin = 0 }
    end
    table.sort(s.entries, function(a, b) return a.id < b.id end)
    for _, e in ipairs(s.entries) do
        if not s.groups[e.group] then
            s.groups[e.group] = {}
            s.groupKeys[#s.groupKeys + 1] = e.group
        end
        table.insert(s.groups[e.group], e)
    end
    table.sort(s.groupKeys)
    for _, c in ipairs(props) do
        local prop = {}
        for k, v in pairs(c) do prop[k] = v end
        prop.home = { pos = { c.pos[1], c.pos[2], c.pos[3] }, rot = matrixTB(c.frame) }
        prop.pos = { c.pos[1], c.pos[2], c.pos[3] }
        prop.rot = prop.home.rot
        prop.drawnPos, prop.drawnRot = prop.home.pos, prop.home.rot
        s.props[#s.props + 1] = prop
        s.byIndex[prop.index] = prop
        -- a carried prop this far below every prop's start fell off the map: released where it is
        s.fallen = math.min(s.fallen or math.huge, c.pos[3] - Dynamics.FALL)
        if s.groups[prop.group] then
            s.byGroup[prop.group] = s.byGroup[prop.group] or {}
            table.insert(s.byGroup[prop.group], prop)
            prop.grouped = true
            s.grouped[#s.grouped + 1] = prop
            if prop.radius > s.maxRadius then s.maxRadius = prop.radius end
            gridPlace(s, prop)
        end
    end
    return s
end

---------------------------------------------------------------------------------------------------- drawn copies

---The atmo items of the props (the game's atmo keeps them local: found among Atmospheres.EntityHolder's
---children by their position and size), again whenever the atmo was loaded again
local function findItems(s)
    local m = rawget(_G, "Atmospheres")
    local holder = type(m) == "table" and m.EntityHolder or nil
    if holder == s.holder then return end
    s.holder = holder
    -- a freshly loaded atmo shows every copy at the atmo's pose: the moved ones are drawn again
    for _, prop in ipairs(s.props) do prop.item, prop.drawnPos, prop.drawnRot = nil, prop.home.pos, prop.home.rot end
    s.dirtyAll = true
    if not holder or type(holder.child) ~= "table" then return end
    local byKey = {}
    for _, item in ipairs(holder.child) do
        local p = item.shift or item.pos
        if p then
            local key = string.format("%.3f %.3f %.3f", p.x, p.y, p.z)
            byKey[key] = byKey[key] or {}
            table.insert(byKey[key], item)
        end
    end
    for _, prop in ipairs(s.props) do
        local h = prop.home.pos
        local list = byKey[string.format("%.3f %.3f %.3f", h[1], h[2], h[3])]
        if list and #list > 0 then prop.item = table.remove(list, 1) end
    end
end

---Puts a prop's drawn copy at a pose (the item's rotation fields as UIElement3D's own Rotate sets them;
---its parent, the atmo's holder, isn't rotated)
local function drawAt(prop, pos, rot)
    local item = prop.item
    if not item or item.destroyed or not Utils3D then return end
    local m = Utils3D.MatrixTBToMatrix(rot)
    local copy = { { m[1][1], m[1][2], m[1][3] }, { m[2][1], m[2][2], m[2][3] }, { m[3][1], m[3][2], m[3][3] } }
    item.__rotMatrixSelf = m
    item.rotMatrix = copy
    item.rotMatrixTB = Utils3D.MatrixToMatrixTB(copy)
    if Utils3D.GetEulerFromMatrix then item.rotXYZ = Utils3D.GetEulerFromMatrix(copy, EULER_XYZ) end
    item:moveTo(pos[1], pos[2], pos[3], true)
end

local function drawOne(prop)
    if prop.drawnPos ~= prop.pos or prop.drawnRot ~= prop.rot then
        drawAt(prop, prop.pos, prop.rot)
        prop.drawnPos, prop.drawnRot = prop.pos, prop.rot
    end
end

---The drawn copies where the props are: the carried ones and those marked dirty (released), or every one
---after a reset or a new atmo (dirtyAll). A copy is redrawn only when its pose changed (poses are new
---tables whenever they change; drawnPos / drawnRot are the ones the copy shows)
local function drawCopies(s)
    if s.noCopies then -- MGE draws the atmo itself (Dynamics.movedProp)
        s.dirty, s.dirtyAll = {}, false
        return
    end
    findItems(s)
    if s.dirtyAll then
        for _, prop in ipairs(s.props) do drawOne(prop) end
    else
        for _, e in ipairs(s.entries) do
            if e.prop then drawOne(e.prop) end
        end
        for _, prop in ipairs(s.dirty) do drawOne(prop) end
    end
    s.dirty, s.dirtyAll = {}, false
end

---------------------------------------------------------------------------------------------------- state

---Everything back to the atmo's poses, every object free (the world's objects aren't touched)
local function clear(s)
    for _, prop in ipairs(s.props) do
        prop.pos, prop.rot, prop.entry = prop.home.pos, prop.home.rot, nil
        gridPlace(s, prop)
    end
    for _, e in ipairs(s.entries) do e.prop, e.seen, e.speed, e.spin = nil, nil, 0, 0 end
    s.dirtyAll = true
end

---A prop left where it is (released): listed in its new cell, its drawn copy updated
local function settle(s, prop)
    gridPlace(s, prop)
    s.dirty[#s.dirty + 1] = prop
end

local function event(s, frame, kind, e, prop)
    s.events[#s.events + 1] = { frame = frame, kind = kind, entry = e, prop = prop, pos = prop.pos, rot = prop.rot }
end

---The props as they were at a frame: from the events up to it; later ones are dropped (what follows is
---played or watched again)
---@param frame integer
function Dynamics.rebuild(s, frame)
    clear(s)
    local kept = {}
    for _, ev in ipairs(s.events) do
        if ev.frame <= frame then
            kept[#kept + 1] = ev
            local prop, e = ev.prop, ev.entry
            prop.pos, prop.rot = ev.pos, ev.rot
            if ev.kind == "take" then
                e.prop, prop.entry = prop, e
                e.seen = { pos = ev.pos, rot = ev.rot }
            else
                e.prop, prop.entry, e.seen = nil, nil, nil
            end
        end
    end
    s.events = kept
    for _, ev in ipairs(kept) do gridPlace(s, ev.prop) end
end

---------------------------------------------------------------------------------------------------- fights

local function bodyPoints()
    local centers, parts = {}, {}
    local count = get_world_state().num_players or 2
    for player = 0, count - 1 do
        local sum, n = { 0, 0, 0 }, 0
        for _, part in pairs(BODYPARTS) do
            local ok, info = pcall(get_body_info, player, part)
            if ok and info and info.pos then
                local p = { info.pos.x, info.pos.y, info.pos.z }
                parts[#parts + 1] = p
                sum[1], sum[2], sum[3], n = sum[1] + p[1], sum[2] + p[2], sum[3] + p[3], n + 1
            end
        end
        if n > 0 then centers[#centers + 1] = { sum[1] / n, sum[2] / n, sum[3] / n } end
    end
    return centers, parts
end

local function touched(prop, parts)
    for _, p in ipairs(parts) do
        if dist(p, prop.pos) <= prop.radius + Dynamics.TOUCH then return true end
    end
    return false
end

local function length(x, y, z) return math.sqrt((x or 0) ^ 2 + (y or 0) ^ 2 + (z or 0) ^ 2) end

---A free object takes a prop: put at its pose, its size, mass and bounce (the object's own for a prop
---without those lines, read before the first change), still
local function take(s, e, prop, frame)
    local id = e.id - 1
    if e.baseMass == nil then
        local ok, mass = pcall(get_obj_mass, id)
        local okBounce, bounce = pcall(get_obj_bounce, id)
        e.baseMass = ok and tonumber(mass) or false
        e.baseBounce = okBounce and tonumber(bounce) or false
    end
    set_obj_sides(id, prop.sides[1], prop.sides[2], prop.sides[3])
    set_obj_rot_m(id, prop.rot)
    set_obj_pos(id, prop.pos[1], prop.pos[2], prop.pos[3])
    set_obj_linear_vel(id, 0, 0, 0)
    set_obj_angular_vel(id, 0, 0, 0)
    local mass, bounce = prop.mass or e.baseMass, prop.bounce or e.baseBounce
    if mass then pcall(set_obj_mass, id, mass) end
    if bounce then pcall(set_obj_bounce, id, bounce) end
    e.prop, prop.entry = prop, e
    e.speed, e.spin = 0, 0
    event(s, frame, "take", e, prop)
end

---A carried prop stays where it is; its object goes back to its parking spot
local function release(s, e, frame)
    local prop = e.prop
    event(s, frame, "release", e, prop)
    local id = e.id - 1
    local x, y, z = Dynamics.parkPos(e.id)
    set_obj_sides(id, Dynamics.PARK_SIDE, Dynamics.PARK_SIDE, Dynamics.PARK_SIDE)
    set_obj_rot_m(id, IDENTITY)
    set_obj_pos(id, x, y, z)
    set_obj_linear_vel(id, 0, 0, 0)
    set_obj_angular_vel(id, 0, 0, 0)
    e.prop, prop.entry = nil, nil
    settle(s, prop)
end

---One fight frame (see the header). Moves made now show from the next frame on, so they're tagged frame + 1
---@param frame integer the match frame
---@param tag integer? the events' frame (match_begin: 0)
function Dynamics.step(s, frame, tag)
    tag = tag or frame + 1
    local movers = {}
    for _, e in ipairs(s.entries) do
        if e.prop then
            local id = e.id - 1
            local x, y, z = get_obj_pos(id)
            if x then updatePose(e.prop, x, y, z, copyTB(get_obj_rot(id))) end
            e.speed = length(get_obj_linear_vel(id))
            e.spin = length(get_obj_angular_vel(id))
            if e.speed > Dynamics.MOVING then movers[#movers + 1] = e.prop end
        end
    end
    local centers, parts = bodyPoints()
    -- the props that can be wanted: around the players and the pushed props (the grid), and the carried ones
    local candidates, seen = {}, {}
    for _, c in ipairs(centers) do gather(s, c, s.radius + s.maxRadius, candidates, seen) end
    for _, m in ipairs(movers) do gather(s, m.pos, m.radius + s.maxRadius + Dynamics.CHAIN, candidates, seen) end
    for _, e in ipairs(s.entries) do
        if e.prop and not seen[e.prop] then
            seen[e.prop] = true
            candidates[#candidates + 1] = e.prop
        end
    end
    local byGroup = {}
    for _, prop in ipairs(candidates) do
        local list = byGroup[prop.group]
        if not list then
            list = {}
            byGroup[prop.group] = list
        end
        list[#list + 1] = prop
    end
    for _, group in ipairs(s.groupKeys) do
        local entries = s.groups[group]
        local list = {}
        for _, prop in ipairs(byGroup[group] or {}) do
            local best
            for _, c in ipairs(centers) do
                local d = dist(c, prop.pos) - prop.radius
                if not best or d < best then best = d end
            end
            if not (best and best <= s.radius) then
                best = nil
                for _, m in ipairs(movers) do
                    if m ~= prop then
                        local d = dist(m.pos, prop.pos) - m.radius - prop.radius
                        if d <= Dynamics.CHAIN then
                            d = s.radius + math.max(d, 0) -- after the props near players
                            if not best or d < best then best = d end
                        end
                    end
                end
            end
            if best then list[#list + 1] = { prop = prop, distance = best } end
        end
        table.sort(list, function(a, b)
            if a.distance ~= b.distance then return a.distance < b.distance end
            return a.prop.index < b.prop.index
        end)
        local isWanted = {}
        for i = 1, math.min(#list, #entries) do isWanted[list[i].prop] = true end
        local free = {}
        for _, e in ipairs(entries) do
            if e.prop then
                local fell = s.fallen and e.prop.pos[3] < s.fallen
                if fell or (not isWanted[e.prop] and e.speed < Dynamics.REST_SPEED and e.spin < Dynamics.REST_SPIN
                    and not touched(e.prop, parts)) then
                    release(s, e, tag) -- free from the next frame
                end
            else
                free[#free + 1] = e
            end
        end
        local k = 1
        for _, w in ipairs(list) do
            if isWanted[w.prop] and not w.prop.entry then
                local e = free[k]
                if not e then break end
                k = k + 1
                take(s, e, w.prop, tag)
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- replays

---Replays: where the props are, from what the pool objects do (see the header)
---@param frame integer
function Dynamics.observe(s, frame)
    for _, e in ipairs(s.entries) do
        local id = e.id - 1
        local x, y, z = get_obj_pos(id)
        if x then
            local pos = { x, y, z }
            if e.prop then
                local prop = e.prop
                if isParked(z) then
                    if e.seen then prop.pos, prop.rot = e.seen.pos, e.seen.rot end
                    event(s, frame, "release", e, prop)
                    e.prop, prop.entry, e.seen = nil, nil, nil
                    settle(s, prop)
                else
                    updatePose(prop, x, y, z, copyTB(get_obj_rot(id)))
                    e.seen = { pos = prop.pos, rot = prop.rot }
                end
            elseif not isParked(z) then
                -- the free prop of its group nearest to where it appeared (ties: the lower atmo index)
                local best, bestD
                local candidates = {}
                gather(s, pos, Dynamics.MATCH + s.maxRadius, candidates, {})
                for _, prop in ipairs(candidates) do
                    if not prop.entry and prop.group == e.group then
                        local d = dist(prop.pos, pos) - prop.radius
                        if not bestD or d < bestD or (d == bestD and prop.index < best.index) then
                            best, bestD = prop, d
                        end
                    end
                end
                if best and bestD <= Dynamics.MATCH then
                    e.prop, best.entry = best, e
                    best.pos, best.rot = pos, copyTB(get_obj_rot(id))
                    e.seen = { pos = best.pos, rot = best.rot }
                    event(s, frame, "take", e, best)
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- hooks

---Times a frame's work (step or watch, and drawing) for /atmoplay status
local function timed(s, start)
    local took = (clock() - start) * 1000
    s.steps, s.stepTime = s.steps + 1, s.stepTime + took
    if took > s.worstStep then s.worstStep = took end
end

---match_begin: a new fight or replay starts from the atmo's poses; a fight places what's near now
---@param ws table get_world_state()
function Dynamics.matchBegin(s, ws)
    clear(s)
    s.events = {}
    s.wasReplay = ws.replay_mode > 0
    -- a replay's first frame is watched by the next draw; a fight's is stepped now
    s.lastFrame = not s.wasReplay and ws.match_frame or nil
    if not s.wasReplay then Dynamics.step(s, ws.match_frame, 0) end
    drawCopies(s)
end

---draw2d: fights step once per new frame, replays watch; the drawn copies follow
---@param ws table get_world_state()
function Dynamics.draw(s, ws)
    local frame = ws.match_frame
    if frame == s.lastFrame and ws.replay_mode > 0 == s.wasReplay then
        drawCopies(s) -- nothing new (a paused fight, a still replay)
        return
    end
    local start = clock()
    if ws.replay_mode > 0 then
        if s.lastFrame and frame < s.lastFrame then Dynamics.rebuild(s, frame) end
        s.wasReplay = true
        if frame ~= s.lastFrame then Dynamics.observe(s, frame) end
    else
        if s.wasReplay or (s.lastFrame and frame < s.lastFrame) then
            -- back in a fight (replay view left, an edited replay played on): the props as they were then
            Dynamics.rebuild(s, frame)
            s.wasReplay = false
        end
        if frame ~= s.lastFrame then Dynamics.step(s, frame) end
    end
    s.lastFrame = frame
    drawCopies(s)
    timed(s, start)
end

---The carried props' centers: the static pool covers them too (a pushed prop keeps a floor under it)
---@return number[][]
function Dynamics.centers(s)
    local out = {}
    for _, e in ipairs(s.entries) do
        if e.prop then out[#out + 1] = e.prop.pos end
    end
    return out
end

---A prop that isn't at the atmo's pose now, by its place among the atmo's entities (MGE: its Atmo list
---index), with its pose as a local-to-world rotation (the frame colliders use); nil when it's at home
---@param index integer
---@return { pos: number[], frame: number[][] }?
function Dynamics.movedProp(s, index)
    local prop = s.byIndex[index]
    if not prop or (prop.pos == prop.home.pos and prop.rot == prop.home.rot) then return nil end
    -- one result per pose (poses are new tables when they change): drawing every frame makes nothing new
    local cached = prop.moved
    if cached and cached.forPos == prop.pos and cached.forRot == prop.rot then return cached end
    local r = prop.rot
    cached = { pos = prop.pos, frame = { { r.r0, r.r1, r.r2 }, { r.r4, r.r5, r.r6 }, { r.r8, r.r9, r.r10 } },
        forPos = prop.pos, forRot = prop.rot }
    prop.moved = cached
    return cached
end

---@return integer carried props carried now
---@return integer props all props
function Dynamics.counts(s)
    local carried = 0
    for _, e in ipairs(s.entries) do
        if e.prop then carried = carried + 1 end
    end
    return carried, #s.props
end

---Every drawn copy back at the atmo's pose (Atmo Play leaving the mod)
function Dynamics.restoreCopies(s)
    for _, prop in ipairs(s.props) do
        if prop.drawnPos ~= prop.home.pos or prop.drawnRot ~= prop.home.rot then
            drawAt(prop, prop.home.pos, prop.home.rot)
        end
        prop.drawnPos, prop.drawnRot = prop.home.pos, prop.home.rot
    end
end

NS.Dynamics = Dynamics
return Dynamics
