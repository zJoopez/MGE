-- Dynamic atmo props (docs/atmo-play-plan.md, sections 6-7): atmo objects without the static bit, carried by a
-- second pool of visible dynamic objects on ids 1-48, parked on a hidden platform above the map (below z = 0
-- they'd be pushed out of the ground).
-- Fights, once per new match frame: props near players, the mod's dynamic objects or moving carried props are
-- wanted (by tier, then the gap LOOKAHEAD seconds ahead) and take a free pool object of their group; carried props
-- are released when unwanted, at rest and untouched (a full pool frees the least wanted). Uncarried props fly
-- drawn (flight.lua). Replays move nothing: takes and releases are kept as events (and snapshots) for rewinds

local NS = ATMOPLAY_LOADING

local Colliders = NS.Colliders
local Pool = NS.Pool
local Driver = NS.Driver
local Flight = NS.Flight

---@class AtmoPlayProp : AtmoPlayCollider
---@field mass number?
---@field thrust AtmoPlayThrust?
---@field flight AtmoPlayFlight? flying drawn
---@field flying boolean? in s.flying
---@field home { pos: number[], rot: table } the atmo's pose
---@field rot table MatrixTB now
---@field entry AtmoPlayDynEntry? the pool object carrying it

---@class AtmoPlayDynEntry
---@field id integer env_obj id as the file writes it
---@field group string
---@field prop AtmoPlayProp?
---@field speed number
---@field vel number[]?
---@field spin number
---@field home { pos: number[], sides: number[] } parking spot and own size
---@field sides number[] its size now
---@field seen { pos: number[], rot: table, vel: number[]?, frame: integer? }? replays: last seen carrying its prop

---@class AtmoPlayDynamics
local Dynamics = {
    DEFAULT_RADIUS = 2,
    REST_SPEED = 0.05,
    REST_SPIN = 0.1,
    TOUCH = 0.5, -- a body part this close to a prop keeps it carried
    CHAIN = 0.3, -- a prop this close to a moving carried prop is wanted
    MOVING = 0.2, -- a carried prop moving faster (center speed + spin x radius) pulls in what it touches
    MATCH = 0.5, -- replays: an object that appeared takes the free prop this close
    -- replays: a carrying object farther than this from where its velocity takes it was put elsewhere
    JUMP = 1,
    JUMP_SPEED = 50,
    MATCH_FAR = 4, -- replays: no prop near a take: the nearest of its group within this
    PARK_Z = 50000,
    PARKED = 1000, -- this close to its parking height: parked
    PLATFORM_SIDES = { 120, 4, 1 },
    PARK_SIDE = 0.5,
    FALL = 50, -- this far below the lowest prop's start: fell off the map
    EVICT_MARGIN = 0.5, -- a full pool frees a prop only for one nearer by more than this
    LOOKAHEAD = 0.1, -- seconds of closing speed taken off a gap
    MAX_LEAD = 3,
    TIER_PLAYER = 1,
    TIER_OBJECT = 2,
    TIER_CHAIN = 3,
    POOL_ALPHA = 0.1, -- pool objects as MGE writes them (only seen parked)
    -- snapshots every SNAPSHOT_EVERY frames; older than SNAPSHOT_RECENT only every SNAPSHOT_OLD-th is kept
    SNAPSHOT_EVERY = 50,
    SNAPSHOT_RECENT = 200,
    SNAPSHOT_OLD = 250,
    LEVELS = { "simple", "shapes", "full" }, -- the player's Detail: Low / Medium / High
    FLY_RANGE = 30, -- far props: farther than this from every sampled point, a flight pauses
    DEFAULT_LEVEL = "shapes",
}

---@param level string?
---@return string a known level, else the default
function Dynamics.level(level)
    for _, known in ipairs(Dynamics.LEVELS) do
        if level == known then return level end
    end
    return Dynamics.DEFAULT_LEVEL
end

local IDENTITY = Flight.IDENTITY
local NONE = { tier = math.huge, distance = math.huge } -- the rank of a carried prop nothing wants
local ZERO = { 0, 0, 0 }

---A pool object's parking spot when the file has none
---@return number x, number y, number z
function Dynamics.parkPos(id)
    return id * 2 - 50, 0, Dynamics.PARK_Z + Dynamics.PLATFORM_SIDES[3] / 2 + Dynamics.PARK_SIDE / 2 + 0.01
end

---Parking spots for a dynamic pool written at its own sizes (MGE's writer): side by side along x, each resting on
---the platform, and the platform sized to hold them
---@param objects { id: integer, shape: string, sides: number[] }[]
---@return table<integer, number[]> pos by id
---@return { pos: number[], sides: number[] } platform
function Dynamics.parkLayout(objects)
    local GAP, top = 0.5, Dynamics.PARK_Z + Dynamics.PLATFORM_SIDES[3] / 2
    local spans, total, widest = {}, 0, 0
    for i, o in ipairs(objects) do
        local s = o.sides
        local radius, half
        if o.shape == "sphere" then
            radius, half = s[1], s[1]
        elseif o.shape == "cylinder" then
            radius, half = s[2] / 2 + s[1], s[2] / 2 + s[1] -- stands on its end
        else
            radius, half = math.sqrt(s[1] ^ 2 + s[2] ^ 2 + s[3] ^ 2) / 2, s[3] / 2
        end
        spans[i] = { radius = radius, half = half }
        total = total + 2 * radius + GAP
        if radius > widest then widest = radius end
    end
    local pos, x = {}, -total / 2
    for i, o in ipairs(objects) do
        local span = spans[i]
        pos[o.id] = { x + span.radius, 0, top + span.half + 0.01 }
        x = x + 2 * span.radius + GAP
    end
    local platform = { pos = { 0, 0, Dynamics.PARK_Z }, sides = { math.max(Dynamics.PLATFORM_SIDES[1], total + 4),
        math.max(Dynamics.PLATFORM_SIDES[2], 2 * widest + 2), Dynamics.PLATFORM_SIDES[3] } }
    return pos, platform
end

local function isParked(e, z)
    return math.abs(z - e.home.pos[3]) < Dynamics.PARKED
end

local matrixTB = Driver.matrixTB
local TB_KEYS = { "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11" }

---get_obj_rot's matrix (a list of 12 or a MatrixTB) as a MatrixTB copy
local function copyTB(m)
    local out = {}
    if type(m) ~= "table" then return IDENTITY end
    if m.r0 ~= nil then
        for k = 1, 12 do out[TB_KEYS[k]] = m[TB_KEYS[k]] or 0 end
    else
        for k = 1, 12 do out[TB_KEYS[k]] = m[k] or 0 end
    end
    return out
end

---A pose read from an object; new tables only where it changed (still props keep theirs, so table compares hold)
local function updatePose(prop, x, y, z, m)
    local p = prop.pos
    if x ~= p[1] or y ~= p[2] or z ~= p[3] then prop.pos = { x, y, z } end
    if type(m) ~= "table" then m = IDENTITY end
    local r, list = prop.rot, m.r0 == nil
    for k = 1, 11 do
        local key = TB_KEYS[k]
        local v
        if list then v = m[k] else v = m[key] end
        if (v or 0) ~= r[key] then
            prop.rot = copyTB(m)
            return
        end
    end
end

local function dist(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function length(x, y, z) return math.sqrt((x or 0) ^ 2 + (y or 0) ^ 2 + (z or 0) ^ 2) end
local numbers = Colliders.numbers

---The same value to the engine (written lines and engine floats differ in the last digits)
local function same(a, b)
    if a == nil or b == nil then return a == b end
    return math.abs(a - b) <= 1e-6 * math.max(1, math.abs(a), math.abs(b))
end

local function sameSides(a, b)
    return same(a[1], b[1]) and same(a[2], b[2]) and same(a[3], b[3])
end

---A color line's numbers as 0-1 (0-256 when any of the first three is above 2; above 1 drawn as 1)
local function unitColor(c)
    if not c then return 1, 1, 1, 1 end
    local r, g, b, a = c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
    if r > 2 or g > 2 or b > 2 then r, g, b = r / 256, g / 256, b / 256 end
    local function unit(v) return v < 0 and 0 or (v > 1 and 1 or v) end
    return unit(r), unit(g), unit(b), unit(a)
end

---------------------------------------------------------------------------------------------------- the grid

-- Every prop is listed by the x / y cell it rests in; a carried one stays where it was taken until released.
-- noGrid (tests): every prop every time

local cellKey = Pool.cellKey

local function cellOf(s, v)
    return math.floor(v / s.cellSize)
end

---Lists a prop in the cell it is in now
local function gridPlace(s, prop)
    if s.noGrid then return end
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

---Adds to `out` (once each, `seen`) every prop that can be within `reach` of p in x / y
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

---@param objects AtmoPlayPoolObject[] the dynamic pool (Format.read's `dynamic`)
---@param props AtmoPlayCollider[] Colliders.build's third result
---@param params { dradius: number?, noGrid: boolean?, follow: integer[]?, fromFrame: integer?, statics: AtmoPlayCollider[]?, gravity: number[]?, level: string?, pauseFar: boolean? }?
---follow: the mod's own dynamic objects (0-based ids);
---statics: what flights hit; gravity: fixed (tests), else the gamerule's
---@return table state
function Dynamics.new(objects, props, params)
    params = params or {}
    local s = {
        radius = tonumber(params.dradius) or Dynamics.DEFAULT_RADIUS,
        entries = {}, groups = {}, groupKeys = {}, props = {}, byGroup = {}, byIndex = {},
        noGrid = params.noGrid,
        level = Dynamics.level(params.level), -- a change waits for match_begin
        pauseFar = params.pauseFar and true or false, -- a change waits for match_begin
        samples = {}, -- by frame: the points far props pause by (Dynamics.sample)
        simFrame = 0, -- the frame every flight is at
        snapshots = {},
        grouped = {}, cells = {}, maxRadius = 0,
        events = {}, lastFrame = nil,
        follow = params.follow, followSizes = {},
        fromFrame = params.fromFrame or Driver.FIRST_FRAME,
        world = Flight.newWorld(params.statics, params.gravity), fixedGravity = params.gravity ~= nil,
        flying = {},
        replayMisses = { far = 0, none = 0 },
        -- as after a replay: a state made mid-fight rebuilds and reseats on its first fight draw
        wasReplay = true,
    }
    s.cellSize = math.max(s.radius * 2, 1)
    if not s.fixedGravity then
        local getRules = rawget(_G, "get_game_rules")
        local ok, rules = false, nil
        if getRules then ok, rules = pcall(getRules) end
        local g = ok and type(rules) == "table" and Flight.parseGravity(rules.gravity) or nil
        if g then s.world.gravity = g end
    end
    for _, object in ipairs(objects) do
        local shape = Colliders.shapeOf(object.shape) or "box"
        local pos, sides = numbers(object.pos), numbers(object.sides)
        if #pos < 3 then pos = { Dynamics.parkPos(object.id) } end
        if #sides < 3 then sides = { Dynamics.PARK_SIDE, Dynamics.PARK_SIDE, Dynamics.PARK_SIDE } end
        s.entries[#s.entries + 1] = { id = object.id, group = Colliders.groupKey(shape, object, true),
            prop = nil, speed = 0, spin = 0, home = { pos = pos, sides = sides }, sides = sides }
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
        prop.thrust = Flight.parseThrust(c.thrust)
        -- Active: moves from frame 0 (prop_motion 1, or a thrust by default); else it waits until reached
        prop.active = prop.startMode == 1 or (prop.startMode == nil and prop.thrust ~= nil)
        s.props[#s.props + 1] = prop
        s.byIndex[prop.index] = prop
        s.fallen = math.min(s.fallen or math.huge, c.pos[3] - Dynamics.FALL)
        -- without a mass line it flies with the mass the game gives its pool object
        if not prop.mass then
            local pool = s.groups[prop.group]
            local ok, m = false, nil
            if pool then ok, m = pcall(get_obj_mass, pool[1].id - 1) end
            m = ok and tonumber(m) or nil
            if m and m > 0 then prop.flightMass = m end
        end
        -- carriable: its group has pool objects and it may become real
        if s.groups[prop.group] ~= nil and not prop.noReal then
            s.byGroup[prop.group] = s.byGroup[prop.group] or {}
            table.insert(s.byGroup[prop.group], prop)
            prop.grouped = true
        end
        s.grouped[#s.grouped + 1] = prop
        if prop.radius > s.maxRadius then s.maxRadius = prop.radius end
        gridPlace(s, prop)
    end
    -- props overlapping where the map places them never push each other apart
    for _, prop in ipairs(s.grouped) do
        local near = {}
        gather(s, prop.pos, prop.radius + s.maxRadius, near, {})
        for _, other in ipairs(near) do
            if other ~= prop and other.index > prop.index and Flight.overlap(prop, other) then
                prop.ignore = prop.ignore or {}
                other.ignore = other.ignore or {}
                prop.ignore[other], other.ignore[prop] = true, true
            end
        end
    end
    return s
end

---------------------------------------------------------------------------------------------------- flights

---Everything back to the atmo's poses, every object free (the world's objects aren't touched)
local function clear(s)
    s.flying, s.simFrame = {}, 0
    for _, prop in ipairs(s.props) do
        prop.pos, prop.rot, prop.entry = prop.home.pos, prop.home.rot, nil
        prop.flight, prop.flying = nil, nil
        prop.dormant = nil -- a waiting thrust prop is dormant until reached
        if prop.active then
            prop.flight, prop.flying = Flight.start(nil, 0), true
            s.flying[#s.flying + 1] = prop
        elseif prop.thrust then
            prop.dormant = true
        end
        gridPlace(s, prop)
    end
    for _, e in ipairs(s.entries) do e.prop, e.seen, e.speed, e.spin, e.vel, e.angVel, e.pushedTo = nil, nil, 0, 0, nil, nil, nil end
    s.epoch = (s.epoch or 0) + 1 -- a new timeline: predictions start again
    s.prediction, s.predictionKey = nil, nil
    s.pendingPrediction, s.pendingKey = nil, nil
end

local function startFlight(s, prop, vel, frame, ang)
    prop.flight = Flight.start(vel, frame, ang)
    if not prop.flying then
        prop.flying = true
        s.flying[#s.flying + 1] = prop
    end
end

---A prop let go flies on when it moves, spins or has thrust
local function fliesOn(prop, vel, ang)
    return prop.thrust ~= nil or (vel ~= nil and length(vel[1], vel[2], vel[3]) > Dynamics.REST_SPEED)
        or (ang ~= nil and length(ang[1], ang[2], ang[3]) > Dynamics.REST_SPIN)
end

local function copy3(v)
    return v and { v[1], v[2], v[3] } or nil
end

local function byIndex(a, b) return a.index < b.index end

-- stillNear's list, reused by every call (callers read it before asking again); a call's stamp marks the props met
local nearStamp, nearOut = 0, {}

local function addStill(list, prop, stamp, n)
    for k = 1, #list do
        local other = list[k]
        if other.nearAt ~= stamp then
            other.nearAt = stamp
            if other ~= prop and not other.flight and not other.entry then
                n = n + 1
                nearOut[n] = other
            end
        end
    end
    return n
end

---The still props near a flying one (it may wake them), in atmo order
local function stillNear(s, prop, reach)
    nearStamp = nearStamp + 1
    local stamp, n = nearStamp, 0
    if s.noGrid then
        n = addStill(s.grouped, prop, stamp, n)
    else
        local p, r = prop.pos, reach + s.maxRadius
        for x = cellOf(s, p[1] - r), cellOf(s, p[1] + r) do
            for y = cellOf(s, p[2] - r), cellOf(s, p[2] + r) do
                local list = s.cells[cellKey(x, y)]
                if list then n = addStill(list, prop, stamp, n) end
            end
        end
    end
    for i = #nearOut, n + 1, -1 do nearOut[i] = nil end
    if n > 1 then table.sort(nearOut, byIndex) end
    return nearOut
end

-- A snapshot: { props, data }, SNAP numbers a prop in one flat list: flags (1 pos is home's, 2 rot is home's,
-- 4 flying, 8 its flight has rows, 16 a rest anchor, 32 the anchor has rows), pos 3, rot 9, vel 3, ang 3, frame,
-- still, rows 9, anchor 9
local SNAP = 39
local ROT_KEYS = { "r0", "r1", "r2", "r4", "r5", "r6", "r8", "r9", "r10" }

local function hasFlag(flags, bit) return math.floor(flags / bit) % 2 == 1 end

---Keeps the free props not at the atmo's pose as they are at the sim's frame; thins out old snapshots
local function snapshot(s)
    local props, data, n = {}, {}, 0
    for _, prop in ipairs(s.props) do
        if not prop.entry and (prop.flight or prop.pos ~= prop.home.pos or prop.rot ~= prop.home.rot) then
            n = n + 1
            props[n] = prop
            local o = (n - 1) * SNAP
            local fl, p, r = prop.flight, prop.pos, prop.rot
            local m = fl and fl.rows
            data[o + 1] = (p == prop.home.pos and 1 or 0) + (r == prop.home.rot and 2 or 0) + (fl and 4 or 0) + (m and 8 or 0)
                + (fl and fl.ax and 16 or 0) + (fl and fl.ax and fl.u1 and 32 or 0)
            data[o + 2], data[o + 3], data[o + 4] = p[1], p[2], p[3]
            for i = 1, 9 do data[o + 4 + i] = r[ROT_KEYS[i]] or 0 end
            if fl then
                local v, w = fl.vel, fl.ang
                data[o + 14], data[o + 15], data[o + 16] = v[1], v[2], v[3]
                data[o + 17], data[o + 18], data[o + 19] = w[1], w[2], w[3]
                data[o + 20], data[o + 21] = fl.frame, fl.still
                if m then
                    data[o + 22], data[o + 23], data[o + 24] = m[1][1], m[1][2], m[1][3]
                    data[o + 25], data[o + 26], data[o + 27] = m[2][1], m[2][2], m[2][3]
                    data[o + 28], data[o + 29], data[o + 30] = m[3][1], m[3][2], m[3][3]
                end
                if fl.ax then
                    data[o + 31], data[o + 32], data[o + 33] = fl.ax, fl.ay, fl.az
                    if fl.u1 then
                        data[o + 34], data[o + 35], data[o + 36] = fl.u1, fl.u2, fl.u3
                        data[o + 37], data[o + 38], data[o + 39] = fl.w1, fl.w2, fl.w3
                    end
                end
            end
        end
    end
    local now = s.simFrame
    s.snapshots[now] = { props = props, data = data }
    for at in pairs(s.snapshots) do
        if at < now - Dynamics.SNAPSHOT_RECENT and at % Dynamics.SNAPSHOT_OLD ~= 0 then s.snapshots[at] = nil end
    end
end

local function restoreSnapshot(s, snap)
    local d = snap.data
    for n, prop in ipairs(snap.props) do
        local o = (n - 1) * SNAP
        local flags = d[o + 1]
        prop.pos = hasFlag(flags, 1) and prop.home.pos or { d[o + 2], d[o + 3], d[o + 4] }
        if hasFlag(flags, 2) then
            prop.rot = prop.home.rot
        else
            local r = { r3 = 0, r7 = 0, r11 = 0 }
            for i = 1, 9 do r[ROT_KEYS[i]] = d[o + 4 + i] end
            prop.rot = r
        end
        gridPlace(s, prop)
        if hasFlag(flags, 4) then
            local rows = nil
            if hasFlag(flags, 8) then
                rows = { { d[o + 22], d[o + 23], d[o + 24] }, { d[o + 25], d[o + 26], d[o + 27] },
                    { d[o + 28], d[o + 29], d[o + 30] } }
            end
            local fl = { vel = { d[o + 14], d[o + 15], d[o + 16] }, ang = { d[o + 17], d[o + 18], d[o + 19] },
                frame = d[o + 20], still = d[o + 21], rows = rows }
            if hasFlag(flags, 16) then
                fl.ax, fl.ay, fl.az = d[o + 31], d[o + 32], d[o + 33]
                if hasFlag(flags, 32) then
                    fl.u1, fl.u2, fl.u3, fl.w1, fl.w2, fl.w3 = d[o + 34], d[o + 35], d[o + 36], d[o + 37], d[o + 38], d[o + 39]
                end
            end
            prop.flight = fl
            prop.flying = true
            s.flying[#s.flying + 1] = prop
        end
    end
end

---Whether a flying prop is within FLY_RANGE of a sampled point (far props paused)
local function movesNear(prop, near)
    local r2 = Dynamics.FLY_RANGE * Dynamics.FLY_RANGE
    local p = prop.pos
    for k = 1, #near do
        local q = near[k]
        local dx, dy, dz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
        if dx * dx + dy * dy + dz * dz <= r2 then return true end
    end
    return false
end

---Every flight stepped together, a frame at a time, up to `frame`; ones that rested, fell or are carried leave the list
local function fly(s, frame)
    if s.simFrame >= frame then return end
    local list = nil
    if not s.flightOpts then
        s.neighborsFn = function(prop, reach) return stillNear(s, prop, reach) end
        s.flightOpts = {
            collide = s.level == "full",
            simple = s.level == "simple",
            neighbors = s.neighborsFn,
            wake = function(prop, at)
                prop.pos = { prop.pos[1], prop.pos[2], prop.pos[3] } -- its own table: steps move it in place
                prop.flight = Flight.start(nil, at)
                prop.dormant = nil
                prop.flying = true
                local stepping = s.stepping
                stepping[#stepping + 1] = prop
            end,
        }
    end
    while s.simFrame < frame do
        -- two lists used in turn and emptied in place, in atmo order (sorted only when it isn't)
        list = s.flyingSpare
        if not list or list == s.flying then list = {} end
        s.flyingSpare = s.flying
        for i = #list, 1, -1 do list[i] = nil end
        local sorted, last = true, -math.huge
        for _, prop in ipairs(s.flying) do
            if prop.flight and not prop.entry then
                list[#list + 1] = prop
                if prop.index < last then sorted = false end
                last = prop.index
            else
                prop.flying = nil
            end
        end
        if #list == 0 then
            s.flying = list
            s.simFrame = frame
            break
        end
        if not sorted then table.sort(list, byIndex) end
        -- no wake search when no prop is still
        local carried = 0
        for _, e in ipairs(s.entries) do
            if e.prop then carried = carried + 1 end
        end
        s.flightOpts.neighbors = (#s.grouped - #list - carried > 0) and s.neighborsFn or nil
        -- far props paused: only those near a point sampled at this frame step
        local stepList = list
        local near = s.pauseFar and Dynamics.sampleAt(s, s.simFrame) or nil
        if near then
            stepList = s.stepBuf or {}
            s.stepBuf = stepList
            for i = #stepList, 1, -1 do stepList[i] = nil end
            for _, prop in ipairs(list) do
                if movesNear(prop, near) then stepList[#stepList + 1] = prop end
            end
        end
        s.stepping = stepList
        local before = #stepList
        Flight.step(s.world, stepList, s.simFrame, s.flightOpts)
        if stepList ~= list then
            for i = before + 1, #stepList do list[#list + 1] = stepList[i] end -- woken this step
        end
        s.simFrame = s.simFrame + 1
        -- re-listed after every step (a fight steps several frames a call, its replay one: the same either way)
        for _, prop in ipairs(list) do gridPlace(s, prop) end
        s.flying = list
        if s.simFrame % Dynamics.SNAPSHOT_EVERY == 0 then snapshot(s) end
    end
    s.stepping = nil
    local flying, n = s.flying, 0
    for i = 1, #flying do
        local prop = flying[i]
        if prop.flight and not prop.entry then
            n = n + 1
            flying[n] = prop
        else
            prop.flying = nil
        end
    end
    for i = #flying, n + 1, -1 do flying[i] = nil end
end

---A take or release, kept by frame for rebuilds. `sim`: the flights' frame then (a rebuild puts it there)
local function event(s, frame, kind, e, prop)
    local fl = kind == "release" and prop.flight or nil
    -- a flight's pos and rot tables are written in place: copied (home's kept as they are: snapshots compare them)
    local rot = prop.rot == prop.home.rot and prop.rot or copyTB(prop.rot)
    local p = prop.pos
    local pos = p == prop.home.pos and p or { p[1], p[2], p[3] }
    s.events[#s.events + 1] = { frame = frame, kind = kind, entry = e, prop = prop, pos = pos, rot = rot,
        vel = fl and copy3(fl.vel) or nil, ang = fl and copy3(fl.ang) or nil, flightFrame = fl and fl.frame or nil,
        sim = s.simFrame }
    if fl then s.flightStarts = (s.flightStarts or 0) + 1 end -- a new flight: predictions start again
end

---A prop's color as its object shows it (alpha 0 for "visible 0")
local function propColor(prop)
    local r, g, b, a = unitColor(prop.color)
    return r, g, b, prop.visible == false and 0 or a
end

---A carrying object painted its prop's color (colors aren't in replays: they paint too). Flags are never set:
---pool objects carry their group's in the mod
local function dress(e, prop)
    pcall(set_obj_color, e.id - 1, propColor(prop))
end

local function colorOff(x, y) return math.abs((tonumber(x) or -1) - y) > 0.01 end

---Replays: painted again when the game put the object back to its file color
local function keepDressed(e)
    local ok, r, g, b, a = pcall(get_obj_color, e.id - 1)
    if not ok then return end
    if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    local wr, wg, wb, wa = propColor(e.prop)
    if colorOff(a, wa) or colorOff(r, wr) or colorOff(g, wg) or colorOff(b, wb) then dress(e, e.prop) end
end

---The props as they were at a frame: the events up to it from the nearest snapshot before (later ones dropped)
---@param frame integer
function Dynamics.rebuild(s, frame)
    clear(s)
    local kept, events, k = {}, {}, 1
    for _, ev in ipairs(s.events) do
        if ev.frame <= frame then events[#events + 1] = ev end
    end
    local from = 0
    for at in pairs(s.snapshots) do
        if at > frame - 1 then
            s.snapshots[at] = nil
        elseif at > from then
            from = at
        end
    end
    ---Applies the events made at sim steps up to t
    local function applyUpTo(t)
        while events[k] and (events[k].sim or events[k].frame - 1) <= t do
            local ev = events[k]
            k = k + 1
            kept[#kept + 1] = ev
            local prop, e = ev.prop, ev.entry
            prop.pos, prop.rot = ev.pos, ev.rot
            if ev.kind == "take" then
                e.prop, prop.entry, prop.dormant = prop, e, nil
                e.seen = { pos = ev.pos, rot = ev.rot }
                prop.flight = nil
            else
                e.prop, prop.entry, e.seen = nil, nil, nil
                if ev.vel then startFlight(s, prop, ev.vel, ev.flightFrame, ev.ang) else prop.flight = nil end
            end
            gridPlace(s, prop)
        end
    end
    if from > 0 then
        applyUpTo(from - 1)
        for _, prop in ipairs(s.props) do
            if not prop.entry then prop.flight, prop.flying = nil, nil end
        end
        s.flying = {}
        restoreSnapshot(s, s.snapshots[from])
        s.simFrame = from
    end
    for f = from, frame - 2 do
        applyUpTo(f)
        fly(s, f + 1)
    end
    applyUpTo(math.huge)
    s.events = kept
    for _, prop in ipairs(s.props) do gridPlace(s, prop) end
    for _, e in ipairs(s.entries) do
        if e.prop then dress(e, e.prop) end
    end
end

---------------------------------------------------------------------------------------------------- fights

---Every player's center and mean velocity, and every body part's position
---@return { pos: number[], vel: number[] }[] players
---@return number[][] parts
local function bodyPoints()
    local players, parts = {}, {}
    local count = get_world_state().num_players or 2
    for player = 0, count - 1 do
        local sum, vel, n = { 0, 0, 0 }, { 0, 0, 0 }, 0
        for _, part in pairs(BODYPARTS) do
            local ok, info = pcall(get_body_info, player, part)
            if ok and info and info.pos then
                local p = { info.pos.x, info.pos.y, info.pos.z }
                parts[#parts + 1] = p
                sum[1], sum[2], sum[3], n = sum[1] + p[1], sum[2] + p[2], sum[3] + p[3], n + 1
                local okVel, vx, vy, vz = pcall(get_body_linear_vel, player, part)
                if okVel and vx then vel[1], vel[2], vel[3] = vel[1] + vx, vel[2] + (vy or 0), vel[3] + (vz or 0) end
            end
        end
        if n > 0 then
            players[#players + 1] = { pos = { sum[1] / n, sum[2] / n, sum[3] / n },
                vel = { vel[1] / n, vel[2] / n, vel[3] / n } }
        end
    end
    return players, parts
end

---Bounding radius of one of the mod's own dynamic objects (read once; get_obj_shape: 0 sphere, 1 box, 2 capsule)
local function followSize(s, id)
    local size = s.followSizes[id]
    if size then return size end
    local ok, x, y, z = pcall(get_obj_sides, id)
    x, y, z = ok and tonumber(x) or 0, ok and tonumber(y) or 0, ok and tonumber(z) or 0
    local okShape, shape = pcall(get_obj_shape, id)
    shape = okShape and tonumber(shape) or nil
    local box, sphere, capsule = math.sqrt(x * x + y * y + z * z) / 2, x, x + y / 2
    if shape == 0 then size = sphere elseif shape == 1 then size = box elseif shape == 2 then size = capsule
    else size = math.max(box, sphere, capsule) end
    s.followSizes[id] = size
    return size
end

---What wants props: the players' centers and the mod's own dynamic objects, with velocity and reach
---@return { pos: number[], vel: number[], size: number, player: boolean? }[] sources
---@return number[][] parts every body part
local function sourcePoints(s)
    local players, parts = bodyPoints()
    local sources = {}
    for _, p in ipairs(players) do sources[#sources + 1] = { pos = p.pos, vel = p.vel, size = 0, player = true } end
    for _, id in ipairs(s.follow or {}) do
        local x, y, z = get_obj_pos(id)
        if x then
            local vx, vy, vz = get_obj_linear_vel(id)
            sources[#sources + 1] = { pos = { x, y, z }, vel = { vx or 0, vy or 0, vz or 0 }, size = followSize(s, id) }
        end
    end
    return sources, parts
end

---The gap between something moving (pos, vel, radius size) and a prop, less what the closing speed covers in
---LOOKAHEAD seconds (at most MAX_LEAD either way); a carried or flying prop's own velocity counts
local function gapAhead(pos, vel, size, prop)
    local dx, dy, dz = prop.pos[1] - pos[1], prop.pos[2] - pos[2], prop.pos[3] - pos[3]
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    local gap = d - prop.radius - size
    if d < 1e-9 then return gap end
    local vx, vy, vz = vel[1], vel[2], vel[3]
    local own = (prop.entry and prop.entry.vel) or (prop.flight and prop.flight.vel)
    if own then vx, vy, vz = vx - own[1], vy - own[2], vz - own[3] end
    local closing = (vx * dx + vy * dy + vz * dz) / d
    local lead = math.max(-Dynamics.MAX_LEAD, math.min(Dynamics.MAX_LEAD, closing * Dynamics.LOOKAHEAD))
    return gap - lead
end

---How much farther a moving thing reaches in the search: its lead
local function leadReach(vel)
    return math.min(Dynamics.MAX_LEAD, length(vel[1], vel[2], vel[3]) * Dynamics.LOOKAHEAD)
end

local function touched(prop, parts)
    for _, p in ipairs(parts) do
        if dist(p, prop.pos) <= prop.radius + Dynamics.TOUCH then return true end
    end
    return false
end

---Resizes an object only when its size differs (the heaviest change; MGE writes pools at their props' size)
local function fitObject(e, sides)
    if not sameSides(e.sides, sides) then
        set_obj_sides(e.id - 1, sides[1], sides[2], sides[3])
        e.sides = sides
    end
end

---Puts an object at a pose, still or with velocity and spin
local function placeAt(e, pos, rot, vel, ang)
    local id = e.id - 1
    set_obj_rot_m(id, rot)
    set_obj_pos(id, pos[1], pos[2], pos[3])
    if vel then
        set_obj_linear_vel(id, vel[1], vel[2], vel[3])
    else
        set_obj_linear_vel(id, 0, 0, 0)
    end
    if ang then
        set_obj_angular_vel(id, ang[1], ang[2], ang[3])
    else
        set_obj_angular_vel(id, 0, 0, 0)
    end
end

---A free object takes a prop: at its pose and size, moving on as its flight was
local function take(s, e, prop, frame)
    fitObject(e, prop.sides)
    dress(e, prop)
    local fl = prop.flight
    local vel, ang = fl and copy3(fl.vel) or nil, fl and copy3(fl.ang) or nil
    placeAt(e, prop.pos, prop.rot, vel, ang)
    prop.flight = nil
    prop.dormant = nil
    e.prop, prop.entry = prop, e
    e.speed, e.spin, e.vel, e.angVel = vel and length(vel[1], vel[2], vel[3]) or 0,
        ang and length(ang[1], ang[2], ang[3]) or 0, vel, ang
    e.pushedTo = s.simFrame - 1 -- its flight had the pushes before this frame
    event(s, frame, "take", e, prop)
end

local function park(e)
    fitObject(e, e.home.sides)
    placeAt(e, e.home.pos, IDENTITY)
end

---A carried prop stays where it is or flies on drawn (from its pose and velocity at `poseFrame`); its object parks
local function release(s, e, tag, poseFrame)
    local prop = e.prop
    if fliesOn(prop, e.vel, e.angVel) then startFlight(s, prop, e.vel, poseFrame, e.angVel) end
    event(s, tag, "release", e, prop)
    park(e)
    e.prop, prop.entry = nil, nil
    gridPlace(s, prop)
end

---Back in a fight from a replay: every object set again as the props say. The object is the truth; one the game left
---at 0,0,0 (past an R replay's recorded frames) is put back, a parked one only when off its spot
local function reseat(s)
    for _, e in ipairs(s.entries) do
        local ok, x, y, z = pcall(get_obj_sides, e.id - 1)
        if ok and tonumber(x) then e.sides = { tonumber(x), tonumber(y) or 0, tonumber(z) or 0 } end
        if e.prop then
            fitObject(e, e.prop.sides)
            dress(e, e.prop)
            local x, y, z = get_obj_pos(e.id - 1)
            if x and math.abs(x) + math.abs(y) + math.abs(z) >= 0.01 then
                updatePose(e.prop, x, y, z, get_obj_rot(e.id - 1))
            else
                placeAt(e, e.prop.pos, e.prop.rot)
            end
        else
            local x, y, z = get_obj_pos(e.id - 1)
            local speed = length(get_obj_linear_vel(e.id - 1))
            local h = e.home.pos
            if not (x and math.abs(x - h[1]) + math.abs(y - h[2]) + math.abs(z - h[3]) < 0.01 and speed < 0.01) then
                park(e)
            end
        end
        e.speed, e.spin, e.vel, e.pushedTo = 0, 0, nil, nil
    end
end

---One fight frame. Moves made now show from the next frame, so events are tagged frame + 1
---@param tag integer? the events' frame (match_begin: 0)
function Dynamics.step(s, frame, tag)
    tag = tag or frame + 1
    local movers, moverVel = {}, {}
    for _, e in ipairs(s.entries) do
        if e.prop then
            local id = e.id - 1
            local x, y, z = get_obj_pos(id)
            if x then updatePose(e.prop, x, y, z, get_obj_rot(id)) end
            local vx, vy, vz = get_obj_linear_vel(id)
            e.vel = { vx or 0, vy or 0, vz or 0 }
            e.speed = length(vx, vy, vz)
            local ax, ay, az = get_obj_angular_vel(id)
            e.angVel = { ax or 0, ay or 0, az or 0 }
            e.spin = length(ax, ay, az)
            if e.speed + e.spin * e.prop.radius > Dynamics.MOVING then
                movers[#movers + 1] = e.prop
                moverVel[e.prop] = e.vel
            end
        end
    end
    fly(s, frame) -- after the objects were read (as a replay's observe does)
    local sources, parts = sourcePoints(s)
    -- the candidates: around the sources and the movers (a flying prop may close in: MAX_LEAD farther), and the
    -- carried ones. Lists kept between frames
    local candidates, seen = s.stepCandidates or {}, s.stepSeen or {}
    s.stepCandidates, s.stepSeen = candidates, seen
    for i = #candidates, 1, -1 do candidates[i] = nil end
    for k in pairs(seen) do seen[k] = nil end
    local flyLead = #s.flying > 0 and Dynamics.MAX_LEAD or 0
    for _, src in ipairs(sources) do
        gather(s, src.pos, s.radius + s.maxRadius + src.size + leadReach(src.vel) + flyLead, candidates, seen)
    end
    for _, m in ipairs(movers) do
        gather(s, m.pos, m.radius + s.maxRadius + Dynamics.CHAIN + leadReach(moverVel[m]), candidates, seen)
    end
    local carriedProps = {}
    for _, e in ipairs(s.entries) do
        if e.prop then carriedProps[#carriedProps + 1] = e.prop end
    end
    if #s.flying > 0 then -- a flying prop about to hit a carried one must become real
        for _, c in ipairs(carriedProps) do
            gather(s, c.pos, c.radius + s.maxRadius + Dynamics.CHAIN + Dynamics.MAX_LEAD, candidates, seen)
        end
    end
    for _, c in ipairs(carriedProps) do
        if not seen[c] then
            seen[c] = true
            candidates[#candidates + 1] = c
        end
    end
    local byGroup = {}
    for _, prop in ipairs(candidates) do
        if prop.grouped then
            local list = byGroup[prop.group]
            if not list then
                list = {}
                byGroup[prop.group] = list
            end
            list[#list + 1] = prop
        end
    end
    for _, group in ipairs(s.groupKeys) do
        local entries = s.groups[group]
        local list = {}
        for _, prop in ipairs(byGroup[group] or {}) do
            local nearPlayer, nearObject
            for _, src in ipairs(sources) do
                local d = gapAhead(src.pos, src.vel, src.size, prop)
                if src.player then
                    if not nearPlayer or d < nearPlayer then nearPlayer = d end
                elseif not nearObject or d < nearObject then
                    nearObject = d
                end
            end
            if prop.noPlayer then nearPlayer = nil end
            if prop.noDynamic then nearObject = nil end
            local best, tier
            if nearPlayer and nearPlayer <= s.radius then
                best, tier = nearPlayer, Dynamics.TIER_PLAYER
            elseif nearObject and nearObject <= s.radius then
                best, tier = nearObject, Dynamics.TIER_OBJECT
            elseif not prop.noDynamic then -- pushed by carried props
                for _, m in ipairs(movers) do
                    if m ~= prop then
                        local d = dist(m.pos, prop.pos) - m.radius - prop.radius
                        if d <= Dynamics.CHAIN then
                            d = gapAhead(m.pos, moverVel[m], m.radius, prop)
                            if not best or d < best then best = d end
                        end
                    end
                end
                if prop.flight then -- flying at a carried prop
                    local p = prop.pos
                    for _, c in ipairs(carriedProps) do
                        local q = c.pos
                        local dx, dy, dz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
                        local reach = c.radius + prop.radius + Dynamics.CHAIN + Dynamics.MAX_LEAD
                        if dx * dx + dy * dy + dz * dz <= reach * reach then
                            local d = gapAhead(c.pos, ZERO, c.radius, prop)
                            if d <= Dynamics.CHAIN and (not best or d < best) then best = d end
                        end
                    end
                end
                tier = Dynamics.TIER_CHAIN
            end
            if best and s.fallen and prop.pos[3] < s.fallen then best = nil end -- fell off the map
            if best then list[#list + 1] = { prop = prop, distance = best, tier = tier } end
        end
        table.sort(list, function(a, b)
            if a.tier ~= b.tier then return a.tier < b.tier end
            if a.distance ~= b.distance then return a.distance < b.distance end
            return a.prop.index < b.prop.index
        end)
        local isWanted, rankOf = {}, {}
        for i = 1, math.min(#list, #entries) do isWanted[list[i].prop] = true end
        for _, w in ipairs(list) do rankOf[w.prop] = w end
        local free, kept = {}, {}
        for _, e in ipairs(entries) do
            if e.prop then
                local fell = s.fallen and e.prop.pos[3] < s.fallen
                local atRest = e.prop.thrust or (e.speed < Dynamics.REST_SPEED and e.spin < Dynamics.REST_SPIN)
                if fell or (not isWanted[e.prop] and atRest and not touched(e.prop, parts)) then
                    release(s, e, tag, frame)
                else
                    kept[#kept + 1] = e
                end
            else
                free[#free + 1] = e
            end
        end
        local k = 1
        local waiting = {} -- wanted near a player or object, no free object left
        for _, w in ipairs(list) do
            if isWanted[w.prop] and not w.prop.entry then
                local e = free[k]
                if e then
                    k = k + 1
                    take(s, e, w.prop, tag)
                elseif w.tier ~= Dynamics.TIER_CHAIN then
                    waiting[#waiting + 1] = w
                end
            end
        end
        if #waiting > 0 then
            -- a full pool: the least wanted untouched carried props are let go for the best waiting ones (within
            -- a tier only when farther by EVICT_MARGIN)
            local victims = {}
            for _, e in ipairs(kept) do
                if not isWanted[e.prop] and not touched(e.prop, parts) then victims[#victims + 1] = e end
            end
            table.sort(victims, function(a, b)
                local ra, rb = rankOf[a.prop] or NONE, rankOf[b.prop] or NONE
                if ra.tier ~= rb.tier then return ra.tier > rb.tier end
                if ra.distance ~= rb.distance then return ra.distance > rb.distance end
                return a.prop.index > b.prop.index
            end)
            for i, w in ipairs(waiting) do
                local e = victims[i]
                if not e then break end
                local r = rankOf[e.prop] or NONE
                if r.tier < w.tier or (r.tier == w.tier and r.distance <= w.distance + Dynamics.EVICT_MARGIN) then
                    break
                end
                release(s, e, tag, frame)
            end
        end
    end
    -- carried thrust props pushed as the game's thrust pushes, with the pushes of frames not drawn since (e.pushedTo)
    for _, e in ipairs(s.entries) do
        local prop = e.prop
        if prop and prop.thrust and not prop.dormant then
            local every = prop.thrust.every
            local from = e.pushedTo or (frame - 1)
            local count = math.floor(frame / every) - math.floor(from / every)
            if count > 0 then
                local fx, fy, fz = Flight.thrustWorld(prop.thrust, prop.rot)
                pcall(set_obj_force, e.id - 1, fx * count, fy * count, fz * count)
            end
            e.pushedTo = frame
        else
            e.pushedTo = nil
        end
    end
end

---------------------------------------------------------------------------------------------------- replays

---Whether a carrying object was put somewhere since last seen (not moved there by its velocity)
local function jumped(e, pos, frame)
    local seen = e.seen
    if not (seen and seen.frame and seen.vel) then return false end
    local t = (frame - seen.frame) * Flight.DT
    local v, p = seen.vel, seen.pos
    local dx, dy, dz = pos[1] - (p[1] + v[1] * t), pos[2] - (p[2] + v[2] * t), pos[3] - (p[3] + v[3] * t)
    local allowed = Dynamics.JUMP + Dynamics.JUMP_SPEED * t
    return dx * dx + dy * dy + dz * dz > allowed * allowed
end

---Where a carrying object is seen with its prop, and how fast
local function seeMoving(e, prop, id, frame)
    local vx, vy, vz = get_obj_linear_vel(id)
    local ax, ay, az = get_obj_angular_vel(id)
    e.seen = { pos = prop.pos, rot = prop.rot, vel = { vx or 0, vy or 0, vz or 0 }, ang = { ax or 0, ay or 0, az or 0 },
        frame = frame }
end

---A carrying object let its prop go: the prop as last seen, flying on from there
local function seenRelease(s, e, frame)
    local prop, seen = e.prop, e.seen
    if seen then prop.pos, prop.rot = seen.pos, seen.rot end
    if seen and seen.frame and fliesOn(prop, seen.vel, seen.ang) then
        startFlight(s, prop, seen.vel, seen.frame, seen.ang)
    end
    event(s, frame, "release", e, prop)
    e.prop, prop.entry, e.seen = nil, nil, nil
    gridPlace(s, prop)
end

---Replays: where the props are, from what the pool objects do
function Dynamics.observe(s, frame)
    -- 1. carrying objects parked or put elsewhere (released), or moved (followed)
    local free = {} -- objects off their parking spot carrying nothing: they took a prop
    local steps = math.max(1, frame - (s.lastFrame or frame - 1))
    for _, e in ipairs(s.entries) do
        local id = e.id - 1
        local x, y, z = get_obj_pos(id)
        if x then
            local pos = { x, y, z }
            if e.prop then
                if isParked(e, z) then
                    seenRelease(s, e, frame)
                elseif jumped(e, pos, frame) then
                    seenRelease(s, e, frame)
                    free[#free + 1] = { e = e, pos = pos }
                else
                    updatePose(e.prop, x, y, z, get_obj_rot(id))
                    seeMoving(e, e.prop, id, frame)
                end
            elseif not isParked(e, z) then
                free[#free + 1] = { e = e, pos = pos }
            else
                e.unmatched = nil
            end
        end
    end
    -- 2. each take: the free prop of its group nearest to where the object appeared (flying ones where they'd be now)
    local ahead = (frame - s.simFrame) * Flight.DT
    for _, f in ipairs(free) do
        local e, pos = f.e, f.pos
        local id = e.id - 1
        local vx, vy, vz = get_obj_linear_vel(id)
        local slack = Dynamics.MATCH + length(vx, vy, vz) * Flight.DT * steps
        local best, bestD
        local candidates = {}
        gather(s, pos, math.max(slack, Dynamics.MATCH_FAR) + s.maxRadius + Dynamics.MAX_LEAD, candidates, {})
        for _, prop in ipairs(candidates) do
            if not prop.entry and prop.grouped and prop.group == e.group then
                local p, fl = prop.pos, prop.flight
                local px, py, pz = p[1], p[2], p[3]
                if fl then px, py, pz = px + fl.vel[1] * ahead, py + fl.vel[2] * ahead, pz + fl.vel[3] * ahead end
                local dx, dy, dz = px - pos[1], py - pos[2], pz - pos[3]
                local d = math.sqrt(dx * dx + dy * dy + dz * dz) - prop.radius
                if not bestD or d < bestD or (d == bestD and prop.index < best.index) then
                    best, bestD = prop, d
                end
            end
        end
        local misses = s.replayMisses
        if best and bestD > slack and bestD <= Dynamics.MATCH_FAR then misses.far = misses.far + 1 end
        local first = not e.unmatched -- a miss counts once until the object parks
        if not best or bestD > Dynamics.MATCH_FAR then
            if first then misses.none = misses.none + 1 end
            e.unmatched = true
            best = nil
        else
            e.unmatched = nil
        end
        local log = NS.DebugLog
        if log and log.event and (not best or bestD > slack) and (best or first) then
            pcall(log.event, string.format("replay take: obj %d at %.2f %.2f %.2f, %s", id, pos[1], pos[2],
                pos[3], best and string.format("nearest prop %.2f away (slack %.2f): taken", bestD, slack)
                or "no free prop of its group within " .. Dynamics.MATCH_FAR))
        end
        if best then
            e.prop, best.entry, best.dormant = best, e, nil
            best.pos, best.rot = pos, copyTB(get_obj_rot(id))
            best.flight = nil
            seeMoving(e, best, id, frame)
            event(s, frame, "take", e, best)
            dress(e, best)
        end
    end
    -- 3. the flights on to this frame (a taken prop doesn't fly these frames, as in the fight)
    fly(s, frame)
end

---------------------------------------------------------------------------------------------------- hooks

---A new flight level, from the next match_begin (a fight and its rewinds keep one)
function Dynamics.setLevel(s, level)
    level = Dynamics.level(level)
    s.nextLevel = level ~= s.level and level or nil
end

---Far props pause or not, from the next match_begin
function Dynamics.setPauseFar(s, on)
    on = on and true or false
    if on ~= s.pauseFar then s.nextPauseFar = on else s.nextPauseFar = nil end
end

---enter_frame, fights and replays alike: where the players (one body part each) and the mod's dynamic objects are,
---for far props' pauses
function Dynamics.sample(s, ws)
    if not s.pauseFar then return end
    local points = {}
    local count = ws.num_players or 2
    for player = 0, count - 1 do
        local ok, info = pcall(get_body_info, player, 0)
        if ok and info and info.pos then points[#points + 1] = { info.pos.x, info.pos.y, info.pos.z } end
    end
    for _, id in ipairs(s.follow or {}) do
        local x, y, z = get_obj_pos(id)
        if x then points[#points + 1] = { x, y, z } end
    end
    s.samples[ws.match_frame] = points
end

---The points sampled at a frame or the nearest of the 60 before; nil: nothing pauses
---@return number[][]?
function Dynamics.sampleAt(s, frame)
    for f = frame, math.max(0, frame - 60), -1 do
        local points = s.samples[f]
        if points and #points > 0 then return points end
    end
    return nil
end

---match_begin: back to the atmo's poses; a fight places what's near now
function Dynamics.matchBegin(s, ws)
    if not s.fixedGravity then
        local ok, rules = pcall(rawget(_G, "get_game_rules"))
        s.world.gravity = ok and type(rules) == "table" and Flight.parseGravity(rules.gravity) or Flight.GRAVITY
    end
    if s.nextLevel then
        s.level, s.nextLevel, s.flightOpts = s.nextLevel, nil, nil
    end
    if s.nextPauseFar ~= nil then s.pauseFar, s.nextPauseFar = s.nextPauseFar, nil end
    clear(s)
    s.events, s.snapshots, s.samples = {}, {}, {}
    s.replayMisses = { far = 0, none = 0 }
    s.wasReplay = ws.replay_mode > 0
    s.lastFrame = not s.wasReplay and ws.match_frame or nil
    if not s.wasReplay and ws.match_frame >= (s.fromFrame or 0) then Dynamics.step(s, ws.match_frame, 0) end
end

---draw2d (and pre_draw / enter_frame in replays): fights step once per new frame, replays watch
function Dynamics.draw(s, ws)
    local frame = ws.match_frame
    local clock = os.clock
    local t0 = clock()
    s.lastSimMs = 0
    if ws.replay_mode > 0 then -- on every call: a color reset seen only at the next frame flashed the prop away
        for _, e in ipairs(s.entries) do
            if e.prop then keepDressed(e) end
        end
    end
    if frame == s.lastFrame and ws.replay_mode > 0 == s.wasReplay then return end
    if ws.replay_mode > 0 then
        if s.lastFrame and frame < s.lastFrame then Dynamics.rebuild(s, frame) end
        s.wasReplay = true
        if frame ~= s.lastFrame then Dynamics.observe(s, frame) end
    else
        if s.wasReplay or (s.lastFrame and frame < s.lastFrame) then
            -- back in a fight: the props as they were then, every object set to match
            Dynamics.rebuild(s, frame)
            reseat(s)
            s.wasReplay = false
        end
        if frame ~= s.lastFrame and frame >= (s.fromFrame or 0) then Dynamics.step(s, frame) end
    end
    s.lastFrame = frame
    s.lastSimMs = (clock() - t0) * 1000
end

---The carried props' centers: the static pool covers them too
---@return number[][]
function Dynamics.centers(s)
    local out = {}
    for _, e in ipairs(s.entries) do
        if e.prop then out[#out + 1] = e.prop.pos end
    end
    return out
end

---A prop away from the atmo's pose by atmo index, with its rotation as a frame (cached per pose); nil at home
---@return { pos: number[], frame: number[][] }?
function Dynamics.movedProp(s, index)
    local prop = s.byIndex[index]
    if not prop or (prop.pos == prop.home.pos and prop.rot == prop.home.rot) then return nil end
    local cached = prop.moved
    if cached and cached.forPos == prop.pos and cached.forRot == prop.rot and cached.forMoves == prop.moves then
        return cached
    end
    local r = prop.rot
    cached = { pos = prop.pos, frame = { { r.r0, r.r1, r.r2 }, { r.r4, r.r5, r.r6 }, { r.r8, r.r9, r.r10 } },
        forPos = prop.pos, forRot = prop.rot, forMoves = prop.moves }
    prop.moved = cached
    return cached
end

---A prop's own pos and rotation (read only) when it's away from the atmo's pose; nil at home
---@return number[]? pos, table? rot
function Dynamics.movedPose(s, index)
    local prop = s.byIndex[index]
    if not prop or (prop.pos == prop.home.pos and prop.rot == prop.home.rot) then return nil end
    return prop.pos, prop.rot
end

---@return boolean carried (its object shows it)
function Dynamics.isCarried(s, index)
    local prop = s.byIndex[index]
    return prop ~= nil and prop.entry ~= nil
end

---@return integer carried, integer props, integer flying
function Dynamics.counts(s)
    local carried = 0
    for _, e in ipairs(s.entries) do
        if e.prop then carried = carried + 1 end
    end
    local flying = 0
    for _, prop in ipairs(s.flying) do
        if prop.flight and not prop.entry then flying = flying + 1 end
    end
    return carried, #s.props, flying
end

---------------------------------------------------------------------------------------------------- ghosts

-- While a fight waits for the turn, flying props get ghosts like the game's objects: drawn faint where the prediction
-- (Flight.newPrediction) puts them at the game's ghost frame. Carried props have the game's own ghost. The prediction
-- runs PREDICT_MS a drawn frame and is kept while the flights follow it
Dynamics.PREDICT_MS = 2
Dynamics.GHOST_STILL = 0.1 -- seconds the frame must hold before ghosts show again
Dynamics.GHOST_FRAMES = 100 -- when the game's ghost length can't be read
Dynamics.GHOST_LOOP_FPS = 60 -- our own ghost loop when the game's frame can't be read
Dynamics.MAX_GHOSTS = 100 -- the nearest the camera (on screen first) are predicted
Dynamics.GHOST_RECENTER = 4 -- the camera moved this far: ghosts picked again
Dynamics.GHOST_SHRINK = 0.01 -- a ghost on its prop stays inside it

---A game function's results, nil when it's missing or fails
local function gameCall(name, ...)
    local f = rawget(_G, name)
    if type(f) ~= "function" then return nil end
    local ok, a, b, c = pcall(f, ...)
    if ok then return a, b, c end
    return nil
end

---The game's ghost now: the frame ahead it shows, its fade and the frames to predict; nil when none shows
---@return number? frame, number? fade, integer? last
function Dynamics.ghostFrame(s, ws)
    if ws.replay_mode > 0 then return nil end
    if tonumber(gameCall("get_ghost")) == 0 then return nil end
    if tonumber(gameCall("get_option", "ghostenvobj")) == 0 then return nil end
    local now = os.clock()
    if s.ghostAt == nil then
        s.ghostAt, s.ghostSince = ws.match_frame, -math.huge -- the first frame seen: nothing was playing
    elseif s.ghostAt ~= ws.match_frame then
        s.ghostAt, s.ghostSince = ws.match_frame, now
    end
    if now - s.ghostSince < Dynamics.GHOST_STILL then return nil end
    local last = (tonumber(gameCall("get_ghost_length")) or Dynamics.GHOST_FRAMES) - 1
    local left = tonumber(ws.game_frame) and ws.game_frame - ws.match_frame or nil -- nothing past the match's end
    if left then
        if left < 1 then return nil end
        if left < last then last = left end
    end
    if last < 1 then return nil end
    local frame, fade = gameCall("get_ghost_frame")
    frame = tonumber(frame)
    if not frame then frame, fade = (now * Dynamics.GHOST_LOOP_FPS) % (last + 1), 1 end
    return math.max(0, math.min(frame, last)), tonumber(fade) or 1, last
end

---A new prediction of the flying props (past MAX_GHOSTS, the nearest the camera, on screen first)
local function newPrediction(s, frames, camera, onScreen)
    local list = {}
    local near = s.pauseFar and Dynamics.sampleAt(s, s.simFrame) or nil -- paused props get no ghost
    for _, prop in ipairs(s.flying) do
        if prop.flight and not prop.entry and (not near or movesNear(prop, near)) then list[#list + 1] = prop end
    end
    local picked = false
    if #list > Dynamics.MAX_GHOSTS and camera then
        local cx, cy, cz = camera[1], camera[2], camera[3]
        local far = {}
        for _, prop in ipairs(list) do
            local p = prop.pos
            local d = (p[1] - cx) ^ 2 + (p[2] - cy) ^ 2 + (p[3] - cz) ^ 2
            if onScreen and not onScreen(p[1], p[2], p[3], prop.radius or 1) then d = d + 1e12 end
            far[prop] = d
        end
        table.sort(list, function(a, b)
            if far[a] ~= far[b] then return far[a] < far[b] end
            return a.index < b.index
        end)
        for i = #list, Dynamics.MAX_GHOSTS + 1, -1 do list[i] = nil end
        picked = true
    end
    table.sort(list, byIndex)
    local pr = Flight.newPrediction(s.world, list, s.simFrame, { collide = s.level == "full", simple = s.level == "simple",
        neighbors = function(prop, reach) return stillNear(s, prop, reach) end }, frames + 1)
    pr.picked, pr.camera = picked, camera and { camera[1], camera[2], camera[3] } or nil
    return pr
end

---The prediction to show, moved up to `frames` ahead (PREDICT_MS a call). Kept while the flights follow it; a new one
---(a flight started, a new level or timeline, the camera moved away from its picks) is built while the old one
---stays shown, and replaces it once it covers the ghost's frames
---@return AtmoPlayPrediction
function Dynamics.predict(s, frames, camera, onScreen)
    local key = (s.epoch or 0) .. ":" .. (s.flightStarts or 0) .. ":" .. s.level
    local function usable(pr)
        local base = s.simFrame - pr.frame
        return base >= 0 and base <= pr.steps and pr.ring > frames
    end
    local function step(pr)
        local base = s.simFrame - pr.frame
        if base > pr.base then Flight.predictTrim(pr, base) end
        pr.base = base
        local t0 = os.clock()
        while not pr.done and pr.steps < base + frames do
            Flight.predictStep(pr, 1)
            if (os.clock() - t0) * 1000 >= Dynamics.PREDICT_MS then break end
        end
    end
    local shown = s.prediction
    local moved = shown and shown.picked and camera and shown.camera and
        (camera[1] - shown.camera[1]) ^ 2 + (camera[2] - shown.camera[2]) ^ 2 + (camera[3] - shown.camera[3]) ^ 2 >
        Dynamics.GHOST_RECENTER ^ 2
    if shown and s.predictionKey == key and usable(shown) and not moved then
        s.pendingPrediction, s.pendingKey = nil, nil
        step(shown)
        return shown
    end
    local pending = s.pendingPrediction
    if not pending or s.pendingKey ~= key or not usable(pending) then
        pending = newPrediction(s, frames, camera, onScreen)
        s.pendingPrediction, s.pendingKey = pending, key
    end
    step(pending)
    local ready = pending.done or pending.steps >= pending.base + frames
    if ready or not (shown and usable(shown)) then
        s.prediction, s.predictionKey = pending, s.pendingKey
        s.pendingPrediction, s.pendingKey = nil, nil
        return pending
    end
    local base = s.simFrame - shown.frame
    if base > shown.base then Flight.predictTrim(shown, base) end
    shown.base = base
    return shown
end

---Ghosts off: both predictions go now
function Dynamics.dropPrediction(s)
    s.prediction, s.predictionKey, s.pendingPrediction, s.pendingKey = nil, nil, nil, nil
end

-- drawGhosts' lists, kept between frames
local ghostProps, ghostDist, ghostPose = {}, {}, setmetatable({}, { __mode = "k" })

local function nearerFirst(p, q) return ghostDist[p] < ghostDist[q] end

---draw3d: the flying props' ghosts at the game's ghost frame, on screen only, at most MAX_GHOSTS (nearest the camera)
---@param onScreen (fun(x: number, y: number, z: number, r: number): boolean)?
---@return integer drawn
function Dynamics.drawGhosts(s, ws, onScreen)
    local k, fade, last = Dynamics.ghostFrame(s, ws)
    if not k then return 0 end
    local cam = gameCall("get_camera_info")
    local c = type(cam) == "table" and cam.pos or nil
    local camera = c and { c.x or c[1] or 0, c.y or c[2] or 0, c.z or c[3] or 0 } or nil
    local pr = Dynamics.predict(s, last, camera, onScreen)
    if #pr.props == 0 then return 0 end
    local opacity = (tonumber(gameCall("get_option", "ghostopacity")) or 50) / 100 * (fade or 1)
    local n = 0
    for _, prop in ipairs(pr.props) do
        if prop.visible ~= false and not prop.entry then
            local x, y, z, rot = Flight.predictedPose(pr, prop, pr.base + k)
            if x and (not onScreen or onScreen(x, y, z, prop.radius or 1)) then
                n = n + 1
                ghostProps[n] = prop
                local pose = ghostPose[prop]
                if not pose then
                    pose = {}
                    ghostPose[prop] = pose
                end
                pose[1], pose[2], pose[3], pose[4] = x, y, z, rot
            end
        end
    end
    for i = n + 1, #ghostProps do ghostProps[i] = nil end
    if n > Dynamics.MAX_GHOSTS then -- props woken in the prediction add to the picked
        if camera then
            local cx, cy, cz = camera[1], camera[2], camera[3]
            for i = 1, n do
                local prop = ghostProps[i]
                local pose = ghostPose[prop]
                ghostDist[prop] = (pose[1] - cx) ^ 2 + (pose[2] - cy) ^ 2 + (pose[3] - cz) ^ 2
            end
            table.sort(ghostProps, nearerFirst)
            for i = 1, n do ghostDist[ghostProps[i]] = nil end
        end
        n = Dynamics.MAX_GHOSTS
    end
    local drawn = 0
    for i = 1, n do
        local prop = ghostProps[i]
        local pose = ghostPose[prop]
        local r, g, b, a = unitColor(prop.color)
        a = a * opacity
        if a > 0 then
            set_color(r, g, b, a)
            local x, y, z, rot = pose[1], pose[2], pose[3], pose[4] or IDENTITY
            local sd, shrink = prop.sides, Dynamics.GHOST_SHRINK
            if prop.shape == "sphere" then
                draw_sphere_m(x, y, z, math.max(sd[1] - shrink / 2, 0.001), rot)
            elseif prop.shape == "cylinder" then
                draw_capsule_m(x, y, z, sd[2], math.max(sd[1] - shrink / 2, 0.001), rot)
            else
                draw_box_m(x, y, z, math.max(sd[1] - shrink, 0.001), math.max(sd[2] - shrink, 0.001),
                    math.max(sd[3] - shrink, 0.001), rot)
            end
            drawn = drawn + 1
        end
    end
    return drawn
end

NS.Dynamics = Dynamics
return Dynamics
