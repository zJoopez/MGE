-- Dynamic atmo props (proof of concept; docs/atmo-play-plan.md, section 6): pushable atmo objects. An
-- atmo object is a prop when its flag line lacks the static bit (colliders.lua). A playable mod with props
-- has a second pool: DYNAMIC objects on free ids 1-48 (the game shows no predictions above 48 and such
-- objects misbehave in replays), "visible 1" so they get move predictions (faint, POOL_ALPHA, until one
-- carries a prop), parked on a hidden static platform high above the map (PARK_Z: a dynamic body parked
-- below the ground is pushed out of it at once and flies through the map).
--
-- In fights (draw2d, once per new match frame, like the static pool):
--   * wanted: props within `radius` of a player's center or of one of the mod's own dynamic objects
--     (`follow`: a rolling ball pushes a crate as a player does; distance between bounding spheres), and
--     props touching a moving carried prop (chain reactions); nearest first, per group (Colliders.groupKey:
--     shape|friction|hardness|bounce|flag bits|mass).
--     "Nearest" looks LOOKAHEAD seconds ahead: the gap less what the closing speed covers, so props ahead
--     of a fast object come first and those it leaves behind last (and drop out of reach sooner). Ranked
--     by tier first: props near a player, then near a dynamic object, then chain ones
--   * a wanted prop without an object gets a free one of its group: put at the prop's pose, velocities zero
--   * a carried prop is released only when it's no longer wanted, AT REST and no body part is near it: its
--     pose is kept, the object goes back to its parking spot (free from the next frame)
--   * a full pool: a prop near a player or dynamic object still waiting for an object FREEZES the least
--     wanted carried prop of its group, moving or not (released where it is, its speed lost), when that one
--     is of a lower tier, or of the same tier and farther by more than EVICT_MARGIN, and no body part
--     touches it. Players' collisions come first, then the nearest
--   * the static pool also covers carried props (moreCenters): a pushed prop keeps a floor under it
-- While carried, the pool object IS the prop on screen: painted the prop's color (dress), with the game's move
-- predictions; the drawn copy (its atmo item) is hidden, and shown again at the prop's pose once released
-- (both drawn flickered). MGE likewise skips drawing a carried prop (Dynamics.isCarried).
--
-- Drawn flight (flight.lua; plan, section 7): a prop with a thrust line flies from frame 0 while no object
-- carries it (its copy moves); taken, its object gets the flight's velocity, and the script pushes it with
-- set_obj_force on the thrust's frames (recorded in replays). A carried prop let go while moving (a full pool's
-- eviction, a thrust prop nobody wants) flies on drawn from the object's pose and velocity instead of hanging
-- where it was. Flights start only from states replays have too (frame 0; a release's pose and velocity), so a
-- fight and its replay fly the same.
-- Replays move nothing: the game replays the pool objects (EOBJ lines). The script WATCHES them to know
-- where the props are: an object leaving its parking spot took the free prop of its group nearest to where
-- it appeared; an object going back left its prop where it was last seen. Everything that happened is kept
-- as events by frame (taken / released, with the pose), so a frame going back (replay rewind, a replay
-- edited and played on) rebuilds the props from them.
-- Measured (plan, section 6): the game's own replays of dynamic objects drift a little in some fights, the
-- pool no more than a normal mod; cached replays misplace teleported objects (the drawn props follow them).

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Colliders = NS.Colliders
local Pool = NS.Pool
local Driver = NS.Driver -- loaded first: Driver.FIRST_FRAME
local Flight = NS.Flight

---@class AtmoPlayProp : AtmoPlayCollider
---@field mass number?
---@field thrust AtmoPlayThrust? from its thrust line
---@field flight AtmoPlayFlight? flying drawn (no object carries it)
---@field flying boolean? listed in s.flying
---@field home { pos: number[], rot: table } the atmo's pose (rot: MatrixTB)
---@field rot table MatrixTB now
---@field entry AtmoPlayDynEntry? the pool object carrying it
---@field item table? its drawn copy (an atmo UIElement3D), found after the atmo loads
---@field copyHidden boolean? its copy is hidden (carried: the object shows it)
---@field drawnPos number[] the pose its copy shows (drawCopies compares tables)
---@field drawnRot table

---@class AtmoPlayDynEntry
---@field id integer env_obj id as the file writes it
---@field group string
---@field prop AtmoPlayProp?
---@field speed number
---@field vel number[]? its linear velocity, read each fight frame while carrying
---@field spin number
---@field home { pos: number[], sides: number[] } its parking spot and own size, as the file has them
---@field sides number[] its size now (fitObject sets a size only when it differs)
---@field seen { pos: number[], rot: table, vel: number[]?, frame: integer? }? replays: where it was last seen
---carrying its prop (and how fast, at which frame: a prop let go moving flies on from there)

---@class AtmoPlayDynamics
local Dynamics = {
    DEFAULT_RADIUS = 2,
    REST_SPEED = 0.05,
    REST_SPIN = 0.1,
    TOUCH = 0.5, -- a body part this close to a prop's bounding sphere touches it: not released
    CHAIN = 0.3, -- a prop this close to a moving carried prop's sphere is wanted too
    -- a carried prop whose fastest point (its center's speed + its spin x its radius) is faster than this pulls in
    -- the props it touches: a cube tipping over barely moves its center, its corners sweep into its neighbours
    MOVING = 0.2,
    MATCH = 0.5, -- replays: an object that appeared takes the free prop within this of its sphere
    -- replays: a carrying object farther than this from where its last seen velocity takes it (plus JUMP_SPEED
    -- times the time since: a hit changing its speed) was put somewhere: it let its prop go and took another between two drawn frames
    -- (a low fps skips the frames it was parked in)
    JUMP = 1,
    JUMP_SPEED = 50,
    -- replays: an object that took a prop none is near (the drawn flights went elsewhere than the fight's: a replay
    -- recorded with other code or another flight level, chaotic piles) takes the nearest free prop of its group
    -- within this, so the prop shows where its object is (not an object in the faint pool color and the prop drawn
    -- elsewhere)
    MATCH_FAR = 4,
    -- The parking platform's center height: ABOVE the map. Everything below z = 0 is inside the game's ground for
    -- a dynamic body: parked 50000 below (the first version), the pool was pushed out at the first physics step
    -- (owotail.rpl, fight frame 1: vz 833317 = depth 49999 x 16.67, the engine's push-out) and flew up through
    -- the map near frame 10, in fights and replays. Static objects don't move, the static pool parks below
    PARK_Z = 50000,
    PARKED = 1000, -- an object this close to its parking spot (height) is parked
    PLATFORM_SIDES = { 120, 4, 1 },
    PARK_SIDE = 0.5, -- a parked object's sides
    FALL = 50, -- a carried prop this far below the lowest prop's start fell off the map: released
    -- a full pool frees a carried prop for a waiting one only when that is nearer by more than this: two
    -- props about as near don't take the object from each other every frame
    EVICT_MARGIN = 0.5,
    -- props are ranked by the gap left after this many seconds at the closing speed: ahead of a fast object first,
    -- behind it last. MAX_LEAD caps the shift. Velocities are per second and a match frame is about 0.006 s
    -- (test2.rpl: the cube moved 0.1798 between two recorded frames at 29.98), so 0.1 s is ~17 frames ahead
    LOOKAHEAD = 0.1,
    MAX_LEAD = 3,
    -- who a prop is wanted for, best first: a full pool serves the players' collisions before the mod's
    -- dynamic objects', and those before chain reactions
    TIER_PLAYER = 1,
    TIER_OBJECT = 2,
    TIER_CHAIN = 3,
    -- the pool objects' color alpha as MGE writes them, "visible 1" (hidden objects get no move predictions).
    -- Only seen parked, far above the map: a carrying object is painted the prop's color (dress)
    POOL_ALPHA = 0.1,
    -- flights are kept every this many frames (snapshots): a rebuild steps on from the nearest one, not frame 0.
    -- Older than SNAPSHOT_RECENT frames, only every SNAPSHOT_OLD-th is kept (a long fight's snapshots were most of the
    -- Lua memory: 768 thrust props, 2000 frames, 53 MB in ~200,000 small tables; the GC walks them all)
    SNAPSHOT_EVERY = 50,
    SNAPSHOT_RECENT = 200,
    SNAPSHOT_OLD = 250,
    -- how drawn props fly (a player's setting, by how fast their computer is; flight.lua): simple, spheres hits
    -- don't turn; shapes, their real shapes; full, real shapes that hit each other and the still props they meet
    LEVELS = { "simple", "shapes", "full" },
    -- far props (the player's option, Atmo Play's window): flying props this far from every player and the mod's own
    -- dynamic objects pause where they are (no step), every prop alike. Decided by where those were
    -- at the very frame stepped (sampled each physics frame in fights and replays alike: the same pauses)
    FLY_RANGE = 30,
    DEFAULT_LEVEL = "shapes",
}

---@param level string?
---@return string a known level (the default for anything else)
function Dynamics.level(level)
    for _, known in ipairs(Dynamics.LEVELS) do
        if level == known then return level end
    end
    return Dynamics.DEFAULT_LEVEL
end

local IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0 }
local NONE = { tier = math.huge, distance = math.huge } -- the rank of a carried prop nothing wants (step)
local ZERO = { 0, 0, 0 }

---Where a pool object parks: on the platform, one spot per id
---@param id integer the file id
---@return number x, number y, number z
function Dynamics.parkPos(id)
    return id * 2 - 50, 0, Dynamics.PARK_Z + Dynamics.PLATFORM_SIDES[3] / 2 + Dynamics.PARK_SIDE / 2 + 0.01
end

---Where a dynamic pool written at its own size parks (MGE's writer: each object at its group's common prop
---size, so taking those props resizes nothing): side by side along x, each resting on the platform at its
---shape's height, spaced by its bounding sphere; the platform sized to hold them all. A pool object without
---pos / sides lines parks at Dynamics.parkPos at PARK_SIDE
---@param objects { id: integer, shape: string, sides: number[] }[] in the order they're laid out
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
            radius, half = s[2] / 2 + s[1], s[2] / 2 + s[1] -- a capsule along z: stands on its end
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

---@param e AtmoPlayDynEntry
---@param z number
---@return boolean the object is at its parking height (far above every map)
local function isParked(e, z)
    return math.abs(z - e.home.pos[3]) < Dynamics.PARKED
end

local matrixTB = Driver.matrixTB

---get_obj_rot's matrix (a number list or a MatrixTB) as a MatrixTB copy
local TB_KEYS = { "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11" }

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

---A pose read from an object, as new tables only where it changed: a still prop keeps its tables, so
---nothing that compares them (drawCopies, movedProp's cache) redoes its work
---@param m table get_obj_rot's (a list of 12 or a MatrixTB): copied only when it differs (a carried prop at rest made a
---new 12-key table a frame)
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

---The same value as far as the engine cares (written lines and engine floats differ in the last digits)
local function same(a, b)
    if a == nil or b == nil then return a == b end
    return math.abs(a - b) <= 1e-6 * math.max(1, math.abs(a), math.abs(b))
end

local function sameSides(a, b)
    return same(a[1], b[1]) and same(a[2], b[2]) and same(a[3], b[3])
end


---------------------------------------------------------------------------------------------------- the grid

-- Props that can get an object (their group has a pool) are listed by the x / y cell they rest in, so a
-- frame looks only at the cells around the players and the pushed props, not at every prop of the map. A
-- carried prop stays listed where it was taken (the searches add the carried ones themselves) and moves
-- to its new cell when it's released or the props are rebuilt. noGrid: every prop every time (the tests
-- compare: the same takes and releases)

local cellKey = Pool.cellKey -- one number per x / y cell

local function cellOf(s, v)
    return math.floor(v / s.cellSize)
end

---Lists a prop in the cell of where it is now (moved out of its old one)
local function gridPlace(s, prop)
    if s.noGrid or not prop.listed then return end
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
---@param params { dradius: number?, noCopies: boolean?, noGrid: boolean?, follow: integer[]?, fromFrame: integer?, statics: AtmoPlayCollider[]?, gravity: number[]? }?
---the mod header's (noCopies: MGE's own; noGrid: tests; follow: the mod's own dynamic objects, Driver.dynamicIds;
---fromFrame: tests, default Driver.FIRST_FRAME; statics: the static colliders flights hit; gravity: tests,
---else the gamerule's, read at match_begin)
---@return table? state, string? error
function Dynamics.new(objects, props, params)
    params = params or {}
    local s = {
        radius = tonumber(params.dradius) or Dynamics.DEFAULT_RADIUS,
        entries = {}, groups = {}, groupKeys = {}, props = {}, byGroup = {}, byIndex = {},
        noCopies = params.noCopies, -- MGE: it draws the atmo itself, the game's atmo copies aren't moved
        noGrid = params.noGrid,
        level = Dynamics.level(params.level), -- how props fly (Dynamics.LEVELS); a new one waits for match_begin
        pauseFar = params.pauseFar and true or false, -- far props pause (Dynamics.FLY_RANGE); a change waits for match_begin
        samples = {}, -- by frame: where the players and the mod's dynamic objects were (Dynamics.sample)
        simFrame = 0, -- the frame every flight is at (they step together, flight.lua)
        snapshots = {}, -- by frame: the moved props' poses and flights then (rebuild)
        grouped = {}, cells = {}, maxRadius = 0,
        dirty = {}, dirtyAll = true, -- drawn copies to update: props whose pose changed (or all of them)
        events = {}, lastFrame = nil, wasReplay = false, holder = nil,
        follow = params.follow, followSizes = {}, -- the mod's own dynamic objects (0-based ids) want props too
        -- no takes or releases before this frame (Driver.FIRST_FRAME: moves before the first one crashed R)
        fromFrame = params.fromFrame or Driver.FIRST_FRAME,
        world = Flight.newWorld(params.statics, params.gravity), fixedGravity = params.gravity ~= nil,
        flying = {}, -- props with a flight (drawn, moving)
        replayMisses = { far = 0, none = 0 },
        -- as if a replay came before: a state made outside match_begin (Atmo Play restarted or reloaded mid-fight)
        -- finds pool objects still carrying the old instance's props in the arena. Its first fight draw then rebuilds
        -- the props to that frame and sets every object again (reseat); match_begin sets the real value
        wasReplay = true,
    }
    s.cellSize = math.max(s.radius * 2, 1)
    -- the mod's gravity now (match_begin reads it again; a state made mid-fight has no match_begin before its flights)
    if not s.fixedGravity then
        local getRules = rawget(_G, "get_game_rules")
        local ok, rules = false, nil
        if getRules then ok, rules = pcall(getRules) end
        local g = ok and type(rules) == "table" and Flight.parseGravity(rules.gravity) or nil
        if g then s.world.gravity = g end
    end
    for _, object in ipairs(objects) do
        local shape = Colliders.shapeOf(object.shape) or "box"
        -- its own parking spot and size as the file has them (MGE writes the group's common prop size there,
        -- so those props never resize it; without the lines: the formula's spot, PARK_SIDE)
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
    local listed = {} -- props in the grid, for the overlap check below
    for _, c in ipairs(props) do
        local prop = {}
        for k, v in pairs(c) do prop[k] = v end
        prop.home = { pos = { c.pos[1], c.pos[2], c.pos[3] }, rot = matrixTB(c.frame) }
        prop.pos = { c.pos[1], c.pos[2], c.pos[3] }
        prop.rot = prop.home.rot
        prop.drawnPos, prop.drawnRot = prop.home.pos, prop.home.rot
        prop.thrust = Flight.parseThrust(c.thrust)
        s.props[#s.props + 1] = prop
        s.byIndex[prop.index] = prop
        -- a carried prop this far below every prop's start fell off the map: released where it is
        s.fallen = math.min(s.fallen or math.huge, c.pos[3] - Dynamics.FALL)
        -- listed (in the grid: found by players, flights and replays) when its group has pool objects, or when it never
        -- becomes real ("prop_real 0": no pool object needed, still woken by flying props)
        local carriable = s.groups[prop.group] ~= nil and not prop.noReal
        -- every prop is listed (the grid: flying props find the still ones they run into and wake them). Only carriable
        -- and never-real ones were: a prop whose group had no pool object (no ids left, a mod without a dynamic pool)
        -- flew drawn but, once at rest, was passed through by the others (a dropped tower fell through itself)
        do
            -- the mass its object will have: the game's, read from a pool object of its group (written with the
            -- prop's mass line, or none: the game's default for an object without one, which a drawn flight
            -- can't guess; Flight.MASS was 1, a 0.1 New object flew 10 times further than its drawn copy)
            if not prop.mass then
                local pool = s.groups[prop.group]
                local ok, m = false, nil
                if pool then ok, m = pcall(get_obj_mass, pool[1].id - 1) end
                m = ok and tonumber(m) or nil
                if m and m > 0 then prop.flightMass = m end
            end
            if carriable then
                s.byGroup[prop.group] = s.byGroup[prop.group] or {}
                table.insert(s.byGroup[prop.group], prop)
                prop.grouped = true
            end
            prop.listed = true
            s.grouped[#s.grouped + 1] = prop
            if prop.radius > s.maxRadius then s.maxRadius = prop.radius end
            gridPlace(s, prop)
            listed[#listed + 1] = prop
        end
    end
    -- props already overlapping where the map places them (a generated shape of overlapping boxes) never push each
    -- other apart in their drawn flights: the shape holds while drawn (real, the game's physics parts them: no flag
    -- turns off collisions between objects)
    for _, prop in ipairs(listed) do
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

---------------------------------------------------------------------------------------------------- drawn copies

---The atmo items of the props (the game's atmo keeps them local: found among Atmospheres.EntityHolder's
---children by their position and size), again whenever the atmo was loaded again
local function findItems(s)
    local m = rawget(_G, "Atmospheres")
    local holder = type(m) == "table" and m.EntityHolder or nil
    if holder == s.holder then return end
    s.holder = holder
    -- a freshly loaded atmo shows every copy at the atmo's pose: the moved ones are drawn again
    for _, prop in ipairs(s.props) do
        prop.item, prop.drawnPos, prop.drawnRot, prop.copyHidden = nil, prop.home.pos, prop.home.rot, false
    end
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

---A carried prop's copy is hidden: its object (painted the prop's color, dress) is what shows, with the
---game's move predictions. Both drawn flickered: in replays the copy followed its object a frame late, and
---at the same pose the two surfaces fight for depth. Back at the prop's pose once it's released
local function drawOne(prop)
    local item = prop.item
    if prop.entry then
        if item and not item.destroyed and not prop.copyHidden then
            item:hide(true) -- noreload: the atmo's holder shown again doesn't bring it back
            prop.copyHidden = true
        end
        return
    end
    if prop.copyHidden then
        if item and not item.destroyed then item:show(true) end
        prop.copyHidden = false
    end
    -- a new pose table, or a flight that moved its own in place (prop.moves: flight.lua)
    if prop.drawnPos ~= prop.pos or prop.drawnRot ~= prop.rot or prop.drawnMoves ~= prop.moves then
        drawAt(prop, prop.pos, prop.rot)
        prop.drawnPos, prop.drawnRot, prop.drawnMoves = prop.pos, prop.rot, prop.moves
    end
end

---The drawn copies of the props taken or released since the last draw (every take and release is an
---event, which marks it), or of every prop after a reset or a new atmo (dirtyAll). A released copy is
---moved only when its pose changed (poses are new tables whenever they change; drawnPos / drawnRot are
---the ones the copy shows)
local function drawCopies(s)
    if s.noCopies then -- MGE draws the atmo itself (Dynamics.movedProp, Dynamics.isCarried)
        s.dirty, s.dirtyAll = {}, false
        return
    end
    findItems(s)
    for _, prop in ipairs(s.dirtyAll and s.props or s.dirty) do drawOne(prop) end
    s.dirty, s.dirtyAll = {}, false
end

---------------------------------------------------------------------------------------------------- state

---Everything back to the atmo's poses, every object free (the world's objects aren't touched)
local function clear(s)
    s.flying, s.simFrame = {}, 0
    for _, prop in ipairs(s.props) do
        prop.pos, prop.rot, prop.entry = prop.home.pos, prop.home.rot, nil
        prop.flight, prop.flying = nil, nil
        -- an active prop flies from frame 0, from the atmo's pose: a thrust prop by default, any prop with prop_motion
        -- start 1 (it falls, tumbles and settles before anything comes near: its flight ends at rest as a woken one's).
        -- A waiting one (start 0, or no thrust and no start) stays still, a thrust one unpushed, until something
        -- reaches it (a take, a flying prop's hit)
        local active = prop.startMode == 1 or (prop.startMode == nil and prop.thrust ~= nil)
        prop.dormant = nil
        if active then
            prop.flight, prop.flying = Flight.start(nil, 0), true
            s.flying[#s.flying + 1] = prop
        elseif prop.thrust then
            prop.dormant = true
        end
        gridPlace(s, prop)
    end
    for _, e in ipairs(s.entries) do e.prop, e.seen, e.speed, e.spin, e.vel, e.angVel, e.pushedTo = nil, nil, 0, 0, nil, nil, nil end
    s.dirtyAll = true
    s.epoch = (s.epoch or 0) + 1 -- a new timeline: the move prediction starts again (Dynamics.predict)
    s.prediction, s.predictionKey = nil, nil -- and the old one's memory goes now, not when ghosts next show
    s.pendingPrediction, s.pendingKey = nil, nil
end

---A prop starts flying drawn from its pose now (at `frame`) with velocity `vel` and angular velocity `ang`
local function startFlight(s, prop, vel, frame, ang)
    prop.flight = Flight.start(vel, frame, ang)
    if not prop.flying then
        prop.flying = true
        s.flying[#s.flying + 1] = prop
    end
end

---Whether a prop let go with velocity `vel` and angular velocity `ang` flies on: it moves, spins, or has thrust
local function fliesOn(prop, vel, ang)
    return prop.thrust ~= nil or (vel ~= nil and length(vel[1], vel[2], vel[3]) > Dynamics.REST_SPEED)
        or (ang ~= nil and length(ang[1], ang[2], ang[3]) > Dynamics.REST_SPIN)
end

---A velocity list copied (nil stays nil)
local function copy3(v)
    return v and { v[1], v[2], v[3] } or nil
end

---The flying props moved on to `frame` (their copies follow); those that came to rest or are carried now
---leave the list
local function byIndex(a, b) return a.index < b.index end

---The still props near a flying one (collide: it may wake them), in atmo order
local function stillNear(s, prop, reach)
    local found, out = {}, {}
    gather(s, prop.pos, reach + s.maxRadius, found, {})
    for _, other in ipairs(found) do
        if other ~= prop and not other.flight and not other.entry then out[#out + 1] = other end
    end
    table.sort(out, byIndex)
    return out
end

-- A snapshot: { props = the props kept, data = their numbers, SNAP each }: flags (1 pos is the home table, 2 rot is,
-- 4 flying, 8 its flight has rows, 16 a rest anchor, 32 the anchor has rows), pos 3, rot 9 (r0 r1 r2 r4 r5 r6 r8 r9
-- r10), vel 3, ang 3, the flight's frame and still, rows 9, then (31-39) the rest anchor: pos 3, rows 1-2 (Flight's
-- ax..w3). Numbers in one list: a table or two a snapshot for the GC, not seven a prop
local SNAP = 39
local ROT_KEYS = { "r0", "r1", "r2", "r4", "r5", "r6", "r8", "r9", "r10" }

local function hasFlag(flags, bit) return math.floor(flags / bit) % 2 == 1 end

---Keeps the free props that aren't at the atmo's pose (moved, resting or flying) as they are at the sim's frame; drops
---older snapshots past SNAPSHOT_RECENT but every SNAPSHOT_OLD-th
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

---A snapshot's props back as they were (rebuild)
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

---Every flight stepped together, one frame at a time, from the sim's frame to `frame` (flight.lua: the same steps
---in a fight, its replay and a rebuild give the same numbers). Their copies follow; those that came to rest, fell
---or are carried now leave the list
---Whether a flying prop moves with far props paused: within FLY_RANGE of a sampled point
---@param near number[][] Dynamics.sampleAt's points
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

local function fly(s, frame)
    if s.simFrame >= frame then return end
    -- the moved props are only for the game's atmo copies (drawn by MGE or Atmo Play's own drawing: none to move)
    local track = not s.noCopies
    local moved, movedList = track and {} or nil, track and {} or nil
    local list = nil
    if not s.flightOpts then
        s.neighborsFn = function(prop, reach) return stillNear(s, prop, reach) end
        s.flightOpts = {
            collide = s.level == "full",
            simple = s.level == "simple",
            neighbors = s.neighborsFn,
            wake = function(prop, at)
                prop.pos = { prop.pos[1], prop.pos[2], prop.pos[3] } -- its own table: steps change it in place
                prop.flight = Flight.start(nil, at)
                prop.dormant = nil -- reached by a flying prop: a waiting one is active from now
                prop.flying = true
                local stepping = s.stepping
                stepping[#stepping + 1] = prop
            end,
        }
    end
    while s.simFrame < frame do
        -- in atmo order (sorted only when it isn't: the list keeps its order, new flights are added at its end). Two
        -- lists used in turn, emptied in place: a new 768-prop list a step was garbage the GC had to take back
        list = s.flyingSpare
        if not list or list == s.flying then list = {} end
        s.flyingSpare = s.flying
        local old = #list
        for i = old, 1, -1 do list[i] = nil end
        local sorted, last, listedFlying = true, -math.huge, 0
        for _, prop in ipairs(s.flying) do
            if prop.flight and not prop.entry then
                list[#list + 1] = prop
                if prop.index < last then sorted = false end
                last = prop.index
                if prop.listed then listedFlying = listedFlying + 1 end
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
        -- waking needs still props: with none listed (all flying or carried), no search for them
        local carried = 0
        for _, e in ipairs(s.entries) do
            if e.prop then carried = carried + 1 end
        end
        s.flightOpts.neighbors = (#s.grouped - listedFlying - carried > 0) and s.neighborsFn or nil
        -- far props pause (the player's option): those far from every sampled player / dynamic object at this frame
        -- aren't stepped (they keep their flight and go on when someone comes near)
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
            for i = before + 1, #stepList do list[#list + 1] = stepList[i] end -- woken this step: flying from now
        end
        s.simFrame = s.simFrame + 1
        -- listed where they are now after every step (the next step's wakes find them there; a fight steps several
        -- frames in one call when draws were skipped, its replay one: the same either way)
        for _, prop in ipairs(list) do
            gridPlace(s, prop)
            if track and not moved[prop] then
                moved[prop] = true
                movedList[#movedList + 1] = prop
            end
        end
        s.flying = list
        if s.simFrame % Dynamics.SNAPSHOT_EVERY == 0 then snapshot(s) end
    end
    s.stepping = nil
    -- the ones still flying, kept in place
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
    -- their copies redrawn
    if track then
        for _, prop in ipairs(movedList) do s.dirty[#s.dirty + 1] = prop end
    end
end

---A take or release, kept by frame for rebuilds; its prop's copy is hidden or shown by the next draw. A release
---that starts a flight keeps its velocity and frame (rebuilds fly it again from there)
local function event(s, frame, kind, e, prop)
    local fl = kind == "release" and prop.flight or nil
    -- sim: the flights' frame when it happened; a rebuild puts it in place before stepping from there (a replay
    -- watched with skipped frames sees it later than it happened, and so does its rebuild)
    -- its rotation copied (a flying prop's is its flight's table, written in place every frame: flight.lua), the
    -- atmo's own kept as that table (snapshots tell "at home" by it)
    local rot = prop.rot == prop.home.rot and prop.rot or copyTB(prop.rot)
    local p = prop.pos -- the same for its position (a flight moves its own in place)
    local pos = p == prop.home.pos and p or { p[1], p[2], p[3] }
    s.events[#s.events + 1] = { frame = frame, kind = kind, entry = e, prop = prop, pos = pos, rot = rot,
        vel = fl and copy3(fl.vel) or nil, ang = fl and copy3(fl.ang) or nil, flightFrame = fl and fl.frame or nil,
        sim = s.simFrame }
    s.dirty[#s.dirty + 1] = prop
    -- a prop let go flying: a flight the move prediction doesn't have (Dynamics.predict starts again on it)
    if fl then s.flightStarts = (s.flightStarts or 0) + 1 end
end

---A carrying object made its prop: painted its color (it's what shows while the copy is hidden, drawOne; no
---color line: white, "visible 0": alpha 0; replays don't record colors, EOBJ lines have none, so replays
---paint too). Its flag isn't set: pool objects carry their group's flag bits in the mod (Colliders.groupKey),
---and a flag set while watching crashed the game (R right after loading a playable mod)
---A prop's color as its object shows it: the color line read as the game reads it (the first three over 256 when any
---is above 2; up to 2 is brighter, drawn as 1), "visible 0": alpha 0. A raw "128 64 32" painted the object white
local function propColor(prop)
    local c = prop.color or {}
    local r, g, b, a = c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
    if r > 2 or g > 2 or b > 2 then r, g, b = r / 256, g / 256, b / 256 end
    local function unit(v) return v < 0 and 0 or (v > 1 and 1 or v) end
    return unit(r), unit(g), unit(b), prop.visible == false and 0 or unit(a)
end

local function dress(e, prop)
    pcall(set_obj_color, e.id - 1, propColor(prop))
end

---Replays: a carrying object painted again when its color isn't its prop's any more. The game puts objects back to
---their file colors at times (suspected: where an R replay's recorded frames end; user 2026-11-24: carried props
---vanished there, the pool's own color is nearly clear, POOL_ALPHA), and a carried prop's copy is hidden: unpainted,
---nobody shows it
local function keepDressed(e)
    local prop = e.prop
    local ok, r, g, b, a = pcall(get_obj_color, e.id - 1)
    if not ok then return end
    if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    local wr, wg, wb, wa = propColor(prop)
    local function off(x, y) return math.abs((tonumber(x) or -1) - y) > 0.01 end
    if off(a, wa) or off(r, wr) or off(g, wg) or off(b, wb) then dress(e, prop) end
end

---The props as they were at a frame: from the events up to it; later ones are dropped (what follows is
---played or watched again)
---@param frame integer
function Dynamics.rebuild(s, frame)
    clear(s)
    -- the events seen by this frame, put in place by the sim step they were made at
    local kept, events, k = {}, {}, 1
    for _, ev in ipairs(s.events) do
        if ev.frame <= frame then events[#events + 1] = ev end
    end
    -- the nearest snapshot before the frame (later ones are of a timeline that's dropped now)
    local from = 0
    for at in pairs(s.snapshots) do
        if at > frame - 1 then
            s.snapshots[at] = nil
        elseif at > from then
            from = at
        end
    end
    ---The events made at sim steps up to t (in place before the step from t on)
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
            -- listed where it is now: the flights flown again below find the still props as the live ones did
            gridPlace(s, prop)
        end
    end
    -- the flights flown again with the events between, up to the frame before (step and observe fly on to the
    -- frame itself; observe matches an object that appears with where its prop was the frame before). Flights
    -- touch each other (collide), so they're stepped again from frame 0, not each from its own start
    if from > 0 then
        -- the events before it (who carries what), then the free props as they were there
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
    applyUpTo(math.huge) -- the rest seen by this frame
    s.events = kept
    for _, prop in ipairs(s.props) do gridPlace(s, prop) end
    for _, e in ipairs(s.entries) do
        if e.prop then dress(e, e.prop) end
    end
end

---------------------------------------------------------------------------------------------------- fights

---Every player's center and mean velocity (of its body parts), and every body part's position
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

---Bounding sphere radius of one of the mod's own dynamic objects, read once (get_obj_shape: 0 sphere,
---1 box, 2 capsule; an unknown shape: the largest of the three readings of its sides)
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

---What wants props: the players' centers and the mod's own dynamic objects (`follow`, 0-based ids), each
---with its velocity and the radius it reaches by itself (0 for a player's center)
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

---The gap between something moving (at `pos` with velocity `vel`, radius `size`) and a prop, less how far it
---closes in LOOKAHEAD seconds (MAX_LEAD at most either way): a prop ahead of a fast object comes before
---one beside it, one it moves away from after. A carried or flying prop's own velocity counts (it may flee as
---fast, or fly at it)
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

---How much farther a moving thing can want props in its search (the grid): its lead, at most MAX_LEAD
local function leadReach(vel)
    return math.min(Dynamics.MAX_LEAD, length(vel[1], vel[2], vel[3]) * Dynamics.LOOKAHEAD)
end

local function touched(prop, parts)
    for _, p in ipairs(parts) do
        if dist(p, prop.pos) <= prop.radius + Dynamics.TOUCH then return true end
    end
    return false
end

---Gives an object a size, only when it differs from what the object has now: resizing a dynamic body is the
---heaviest change there is, and RPH (which edits replays freely) moves objects without it. MGE writes each
---dynamic pool object at its group's common prop size, so a uniform map's props never need the call. Mass
---and bounce aren't set: they're in the group (Colliders.groupKey), each pool object has its group's
local function fitObject(e, sides)
    if not sameSides(e.sides, sides) then
        set_obj_sides(e.id - 1, sides[1], sides[2], sides[3])
        e.sides = sides
    end
end

---Puts an object at a pose, still or moving at `vel` and spinning at `ang` (the game has no torque for objects:
---the spin is set as RPH sets it, recorded in replays as the velocity is)
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

---A free object takes a prop: put at its pose and size, still, or moving and spinning on as its flight was
local function take(s, e, prop, frame)
    fitObject(e, prop.sides)
    dress(e, prop)
    local fl = prop.flight
    local vel, ang = fl and copy3(fl.vel) or nil, fl and copy3(fl.ang) or nil
    placeAt(e, prop.pos, prop.rot, vel, ang)
    prop.flight = nil -- fly() drops it from the list
    prop.dormant = nil -- reached: a waiting prop is active from now
    e.prop, prop.entry = prop, e
    e.speed, e.spin, e.vel, e.angVel = vel and length(vel[1], vel[2], vel[3]) or 0,
        ang and length(ang[1], ang[2], ang[3]) or 0, vel, ang
    e.pushedTo = s.simFrame - 1 -- its flight had the pushes before this frame: from this one on, its object's
    event(s, frame, "take", e, prop)
end

---An object back on its parking spot at its own size (its file's), still
local function park(e)
    fitObject(e, e.home.sides)
    placeAt(e, e.home.pos, IDENTITY)
end

---A carried prop stays where it is, or flies on drawn when it moves or has thrust (from its pose and velocity
---at `poseFrame`, the fight frame they were read at); its object goes back to its parking spot
---@param tag integer the event's frame
---@param poseFrame integer
local function release(s, e, tag, poseFrame)
    local prop = e.prop
    if fliesOn(prop, e.vel, e.angVel) then startFlight(s, prop, e.vel, poseFrame, e.angVel) end
    event(s, tag, "release", e, prop)
    park(e)
    e.prop, prop.entry = nil, nil
    gridPlace(s, prop) -- listed where it stays
end

---Every object set again as the props say, when a replay goes back to a fight (an edit, the replay view left):
---carried ones at their prop's pose and size, the others parked. Past an R replay's recorded frames the game
---puts every object a script touched at 0,0,0 (the probe log: all 255 pool objects; 48 dynamic ones stacked
---there crashed the game when that replay was edited): those are put back, the rest only where they differ
local function reseat(s)
    for _, e in ipairs(s.entries) do
        -- the size it really has now (read, not assumed): resized only where it differs
        local ok, x, y, z = pcall(get_obj_sides, e.id - 1)
        if ok and tonumber(x) then e.sides = { tonumber(x), tonumber(y) or 0, tonumber(z) or 0 } end
        if e.prop then
            fitObject(e, e.prop.sides)
            dress(e, e.prop)
            -- the object is the truth (the usual case): its prop's pose read from it, the object left alone and
            -- still moving. Only one the game moved to 0,0,0 is put back at its prop's last pose
            local x, y, z = get_obj_pos(e.id - 1)
            if x and math.abs(x) + math.abs(y) + math.abs(z) >= 0.01 then
                updatePose(e.prop, x, y, z, get_obj_rot(e.id - 1))
            else
                placeAt(e, e.prop.pos, e.prop.rot)
            end
        else
            -- a parked one already on its spot and still is left alone (RPH-like: only what differs)
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

---One fight frame (see the header). Moves made now show from the next frame on, so they're tagged frame + 1
---@param frame integer the match frame
---@param tag integer? the events' frame (match_begin: 0)
function Dynamics.step(s, frame, tag)
    tag = tag or frame + 1
    local movers, moverVel = {}, {} -- moverVel: a mover released this step (another group) keeps it
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
    -- the flights on to this frame, after the objects were read (as a replay's observe does: the same order)
    fly(s, frame)
    local sources, parts = sourcePoints(s)
    -- the props that can be wanted: around the players, the mod's dynamic objects and the pushed props (the
    -- grid), and the carried ones. A flying prop may close in by itself: MAX_LEAD farther
    -- kept between frames and emptied (no new list and set a frame: with hundreds of flying props near the players,
    -- they were most of the step's garbage)
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
    -- a flying prop about to hit a carried one (drawn flights don't meet carried props: it must be real)
    local carriedProps = {}
    for _, e in ipairs(s.entries) do
        if e.prop then carriedProps[#carriedProps + 1] = e.prop end
    end
    if #s.flying > 0 then
        for _, c in ipairs(carriedProps) do
            gather(s, c.pos, c.radius + s.maxRadius + Dynamics.CHAIN + Dynamics.MAX_LEAD, candidates, seen)
        end
    end
    for _, e in ipairs(s.entries) do
        if e.prop and not seen[e.prop] then
            seen[e.prop] = true
            candidates[#candidates + 1] = e.prop
        end
    end
    local byGroup = {}
    for _, prop in ipairs(candidates) do
        if prop.grouped then -- a "prop_real 0" one is never wanted: it never becomes real
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
            -- the gap to the nearest player and to the nearest dynamic object, less what its closing speed
            -- covers soon
            local nearPlayer, nearObject
            for _, src in ipairs(sources) do
                local d = gapAhead(src.pos, src.vel, src.size, prop)
                if src.player then
                    if not nearPlayer or d < nearPlayer then nearPlayer = d end
                elseif not nearObject or d < nearObject then
                    nearObject = d
                end
            end
            -- what it becomes real for (Colliders.collision: the prop's Collision toggles)
            if prop.noPlayer then nearPlayer = nil end
            if prop.noDynamic then nearObject = nil end
            local best, tier
            if nearPlayer and nearPlayer <= s.radius then
                best, tier = nearPlayer, Dynamics.TIER_PLAYER
            elseif nearObject and nearObject <= s.radius then
                best, tier = nearObject, Dynamics.TIER_OBJECT
            elseif not prop.noDynamic then -- pushed by carried props: real dynamic objects too
                for _, m in ipairs(movers) do
                    if m ~= prop then
                        local d = dist(m.pos, prop.pos) - m.radius - prop.radius
                        if d <= Dynamics.CHAIN then
                            -- those the pushed prop is heading at first
                            d = gapAhead(m.pos, moverVel[m], m.radius, prop)
                            if not best or d < best then best = d end
                        end
                    end
                end
                if prop.flight then
                    -- flying at a carried prop (its own velocity closes the gap)
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
            -- one that fell off the map isn't wanted: let go below (fell), it was taken again in the same step
            if best and s.fallen and prop.pos[3] < s.fallen then best = nil end
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
                -- let go when nobody wants it, nothing touches it and it's at rest; a thrust prop never rests:
                -- it goes on flying drawn
                local atRest = e.prop.thrust or (e.speed < Dynamics.REST_SPEED and e.spin < Dynamics.REST_SPIN)
                if fell or (not isWanted[e.prop] and atRest and not touched(e.prop, parts)) then
                    release(s, e, tag, frame) -- free from the next frame
                else
                    kept[#kept + 1] = e
                end
            else
                free[#free + 1] = e
            end
        end
        local k = 1
        local waiting = {} -- wanted near a player or dynamic object, no free object left for it
        for _, w in ipairs(list) do
            if isWanted[w.prop] and not w.prop.entry then
                local e = free[k]
                if e then
                    k = k + 1
                    take(s, e, w.prop, tag)
                elseif w.tier ~= Dynamics.TIER_CHAIN then -- a chain one doesn't stop the props pushing it
                    waiting[#waiting + 1] = w
                end
            end
        end
        if #waiting > 0 then
            -- the pool is full: the carried props wanted least (a lower tier, farther, or not wanted at all)
            -- are let go, for the best waiting props first (a moving one flies on drawn, a still one stays);
            -- their objects are free from the next frame. Within a tier only when farther by more than
            -- EVICT_MARGIN; a waiting prop near a player frees one near a dynamic object or pushed along
            -- however near
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
    -- carried thrust props: pushed as the game's thrust pushes (into frames 1, N + 1 ...: a force set now acts
    -- on the step to the next frame; recorded in replays). Steps run on drawn frames only: the pushes of frames
    -- not drawn since the last step (e.pushedTo) come with this one, so a low fps doesn't lose any (as many
    -- pushes' worth of force in one step: the same speed gained)
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

---Replays: where the props are, from what the pool objects do (see the header)
---@param frame integer
---Whether a carrying object was put somewhere since it was last seen (not moved there): farther from where its
---last seen velocity takes it than JUMP plus JUMP_SPEED x the time since (a hit changes its speed)
local function jumped(e, pos, frame)
    local seen = e.seen
    if not (seen and seen.frame and seen.vel) then return false end
    local t = (frame - seen.frame) * Flight.DT
    local v, p = seen.vel, seen.pos
    local dx, dy, dz = pos[1] - (p[1] + v[1] * t), pos[2] - (p[2] + v[2] * t), pos[3] - (p[3] + v[3] * t)
    local allowed = Dynamics.JUMP + Dynamics.JUMP_SPEED * t
    return dx * dx + dy * dy + dz * dz > allowed * allowed
end

---A carrying object let its prop go (parked, or put elsewhere): the prop as last seen, flying on from there
local function seenRelease(s, e, frame)
    local prop, seen = e.prop, e.seen
    if seen then prop.pos, prop.rot = seen.pos, seen.rot end
    -- as the fight let it go: flying on from its last seen pose and velocity
    if seen and seen.frame and fliesOn(prop, seen.vel, seen.ang) then
        startFlight(s, prop, seen.vel, seen.frame, seen.ang)
    end
    event(s, frame, "release", e, prop)
    e.prop, prop.entry, e.seen = nil, nil, nil
    gridPlace(s, prop) -- listed where it stays
end

function Dynamics.observe(s, frame)
    -- 1. the carrying objects: parked or put elsewhere (released), or moved (followed)
    local free = {} -- objects out of their parking spot carrying nothing: they took a prop
    local steps = math.max(1, frame - (s.lastFrame or frame - 1)) -- frames since the last drawn one
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
                    local prop = e.prop
                    updatePose(prop, x, y, z, get_obj_rot(id))
                    local vx, vy, vz = get_obj_linear_vel(id)
                    local ax, ay, az = get_obj_angular_vel(id)
                    e.seen = { pos = prop.pos, rot = prop.rot, vel = { vx or 0, vy or 0, vz or 0 },
                        ang = { ax or 0, ay or 0, az or 0 }, frame = frame }
                end
            elseif not isParked(e, z) then
                free[#free + 1] = { e = e, pos = pos }
            else
                e.unmatched = nil -- parked again: its next take is a new one
            end
        end
    end
    -- 2. the objects that took a prop: the free prop of its group nearest to where it appeared (ties: the lower
    -- atmo index). Flying props are where they'd be now (the frames since the last drawn one), and the slack
    -- grows with the object's speed over those frames
    local ahead = (frame - s.simFrame) * Flight.DT
    for _, f in ipairs(free) do
        local e, pos = f.e, f.pos
        local id = e.id - 1
        local vx, vy, vz = get_obj_linear_vel(id)
        local slack = Dynamics.MATCH + length(vx, vy, vz) * Flight.DT * steps
        do
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
                -- no match: counted and logged once (it's tried again each frame until it parks)
                local first = not e.unmatched
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
                    best.flight = nil -- fly() drops it from the list
                    local vx, vy, vz = get_obj_linear_vel(id)
                    local ax, ay, az = get_obj_angular_vel(id)
                    e.seen = { pos = best.pos, rot = best.rot, vel = { vx or 0, vy or 0, vz or 0 },
                        ang = { ax or 0, ay or 0, az or 0 }, frame = frame }
                    event(s, frame, "take", e, best)
                    dress(e, best)
                end
        end
    end
    -- 3. the flights on to this frame (after the takes: a taken prop doesn't fly these frames, as in the fight)
    fly(s, frame)
end

---------------------------------------------------------------------------------------------------- hooks

---A new level for drawn props' flight (Dynamics.LEVELS), used from the next match_begin: a fight and its rewinds
---keep the one they started with
---@param level string
function Dynamics.setLevel(s, level)
    level = Dynamics.level(level)
    s.nextLevel = level ~= s.level and level or nil
end

---Far props pause or not (the player's option), from the next match_begin (a fight and its rewinds keep one)
---@param on boolean
function Dynamics.setPauseFar(s, on)
    on = on and true or false
    if on ~= s.pauseFar then s.nextPauseFar = on else s.nextPauseFar = nil end
end

---enter_frame, every physics frame in fights and replays: where the players and the mod's dynamic objects are now,
---for the far props' pauses (only kept while far props may pause). One body part a player is enough at FLY_RANGE
---@param ws table get_world_state()
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

---The points sampled at a frame (or the nearest frame before, for a replay sought ahead); nil: none, nothing pauses
---@param frame integer
---@return number[][]?
function Dynamics.sampleAt(s, frame)
    for f = frame, math.max(0, frame - 60), -1 do
        local points = s.samples[f]
        if points and #points > 0 then return points end
    end
    return nil
end

---match_begin: a new fight or replay starts from the atmo's poses; a fight places what's near now
---@param ws table get_world_state()
function Dynamics.matchBegin(s, ws)
    if not s.fixedGravity then
        local getRules = rawget(_G, "get_game_rules")
        local ok, rules = pcall(getRules)
        s.world.gravity = ok and type(rules) == "table" and Flight.parseGravity(rules.gravity) or Flight.GRAVITY
    end
    -- a new level from here: a fight and its rewinds fly at one level
    if s.nextLevel then
        s.level, s.nextLevel, s.flightOpts = s.nextLevel, nil, nil
    end
    if s.nextPauseFar ~= nil then s.pauseFar, s.nextPauseFar = s.nextPauseFar, nil end
    clear(s)
    s.events, s.snapshots, s.samples = {}, {}, {}
    s.replayMisses = { far = 0, none = 0 } -- replays: takes matched only by MATCH_FAR, takes not matched
    s.wasReplay = ws.replay_mode > 0
    -- a replay's first frame is watched by the next draw; a fight's is stepped now
    s.lastFrame = not s.wasReplay and ws.match_frame or nil
    if not s.wasReplay and ws.match_frame >= (s.fromFrame or 0) then Dynamics.step(s, ws.match_frame, 0) end
    drawCopies(s)
end

---draw2d: fights step once per new frame, replays watch; the drawn copies follow
---@param ws table get_world_state()
function Dynamics.draw(s, ws)
    local frame = ws.match_frame
    local clock = os.clock
    local t0 = clock()
    s.lastSimMs, s.lastCopiesMs = 0, 0 -- what this frame cost (/atmoplay time)
    -- replays: the carrying objects still in their props' colors, on every call (pre_draw, enter_frame, draw2d), not
    -- only on new frames: the game resets colors at times (keepDressed), and a reset seen only at the next new frame
    -- flashed the props away for a frame (user 2026-11-24)
    if ws.replay_mode > 0 then
        for _, e in ipairs(s.entries) do
            if e.prop then keepDressed(e) end
        end
    end
    if frame == s.lastFrame and ws.replay_mode > 0 == s.wasReplay then
        drawCopies(s) -- nothing new (a paused fight, a still replay)
        s.lastCopiesMs = (clock() - t0) * 1000
        return
    end
    if ws.replay_mode > 0 then
        if s.lastFrame and frame < s.lastFrame then Dynamics.rebuild(s, frame) end
        s.wasReplay = true
        -- replays move nothing (driver.lua's Driver.draw: the dropped "tail"): the props are watched
        if frame ~= s.lastFrame then Dynamics.observe(s, frame) end
    else
        if s.wasReplay or (s.lastFrame and frame < s.lastFrame) then
            -- back in a fight (replay view left, an edited replay played on): the props as they were then, and
            -- every object set to match (as the driver sets the static pool again)
            Dynamics.rebuild(s, frame)
            reseat(s)
            s.wasReplay = false
        end
        if frame ~= s.lastFrame and frame >= (s.fromFrame or 0) then Dynamics.step(s, frame) end
    end
    s.lastFrame = frame
    local t1 = clock()
    drawCopies(s)
    s.lastSimMs, s.lastCopiesMs = (t1 - t0) * 1000, (clock() - t1) * 1000
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
    if cached and cached.forPos == prop.pos and cached.forRot == prop.rot and cached.forMoves == prop.moves then
        return cached
    end
    local r = prop.rot
    cached = { pos = prop.pos, frame = { { r.r0, r.r1, r.r2 }, { r.r4, r.r5, r.r6 }, { r.r8, r.r9, r.r10 } },
        forPos = prop.pos, forRot = prop.rot, forMoves = prop.moves }
    prop.moved = cached
    return cached
end

---A prop's pose now when it isn't at the atmo's pose, by its place among the atmo's entities: pos and rotation
---(MatrixTB, as draw_*_m take it), the prop's own tables (read only), nothing made. nil at home
---@param index integer
---@return number[]? pos, table? rot
function Dynamics.movedPose(s, index)
    local prop = s.byIndex[index]
    if not prop or (prop.pos == prop.home.pos and prop.rot == prop.home.rot) then return nil end
    return prop.pos, prop.rot
end

---Whether a prop (by its place among the atmo's entities) is carried now: its object shows it, MGE doesn't
---draw it (as the game's copy is hidden, drawOne)
---@param index integer
---@return boolean
function Dynamics.isCarried(s, index)
    local prop = s.byIndex[index]
    return prop ~= nil and prop.entry ~= nil
end

---@return integer carried props carried now
---@return integer props all props
---@return integer flying props flying drawn now
function Dynamics.counts(s)
    local carried = 0
    for _, e in ipairs(s.entries) do
        if e.prop then carried = carried + 1 end
    end
    local flying = 0
    for _, prop in ipairs(s.flying) do
        if prop.flight and not prop.entry then flying = flying + 1 end -- the list drops taken ones next frame
    end
    return carried, #s.props, flying
end

---Every drawn copy back at the atmo's pose and shown (Atmo Play leaving the mod)
function Dynamics.restoreCopies(s)
    for _, prop in ipairs(s.props) do
        if prop.copyHidden then
            if prop.item and not prop.item.destroyed then prop.item:show(true) end
            prop.copyHidden = false
        end
        if prop.drawnPos ~= prop.home.pos or prop.drawnRot ~= prop.home.rot then
            drawAt(prop, prop.home.pos, prop.home.rot)
        end
        prop.drawnPos, prop.drawnRot = prop.home.pos, prop.home.rot
    end
end

---------------------------------------------------------------------------------------------------- move predictions

-- Drawn props get ghosts the way the game's objects do: while a fight waits for the turn, each flying prop is drawn
-- faint where its flight puts it at the frame the game's ghost shows: the classic ghost plays the next frames in a
-- loop, fading out at its end, and the props' ghosts play along. Also on frame 0 (MGE's editing view). Fights only (the game shows none in replays), not for carried
-- props (their pool object gets the game's own ghost; it doesn't know the script's thrust pushes). The prediction
-- (Flight.newPrediction) steps copies of the flights, PREDICT_MS of each drawn frame, and starts again when the
-- flights move on (a new frame, a take, a rebuild)
Dynamics.PREDICT_MS = 2
-- seconds the match frame holds before ghosts show again after frames played (they hide while frames play); a
-- state's first frame (a fight's start, MGE's reload after an edit) shows them at once
Dynamics.GHOST_STILL = 0.1
Dynamics.GHOST_FRAMES = 100 -- frames predicted when the game's ghost length can't be read
Dynamics.GHOST_LOOP_FPS = 60 -- frames a second of our own ghost loop, when the game's frame can't be read
-- at most this many props get ghosts, the nearest the camera (on screen first): only they are predicted, so the
-- prediction's work is theirs, not every flying prop's (768 thrust props: a prediction step cost as much as playing a
-- frame; user: ~100 ghosts are enough). Their ghosts pass through the flying props left out
Dynamics.MAX_GHOSTS = 100
-- the camera this far from where it was when the ghosts were picked: picked again (a new prediction)
Dynamics.GHOST_RECENTER = 4
-- ghosts this much smaller (sides; a sphere's or pill's radius by half): one on its prop (early in the loop) stays
-- inside it, so the prop shows, also where the ghost is drawn first (the game's atmo drawing, "draw game")
Dynamics.GHOST_SHRINK = 0.01

---A game function's results, nil when it's missing or fails (older builds, tests)
local function gameCall(name, ...)
    local f = rawget(_G, name)
    if type(f) ~= "function" then return nil end
    local ok, a, b, c = pcall(f, ...)
    if ok then return a, b, c end
    return nil
end

---How many frames ahead the game's ghost shows now and how much of it is left as it fades out, nil when no ghost
---shows: a replay, ghosts off (get_ghost 0, ghostenvobj 0), frames playing. The classic ghost plays the next
---get_ghost_length() frames in a loop (partway between frames), get_ghost_frame() says where it is; without it (an
---older build) the loop is our own at GHOST_LOOP_FPS
---@param ws table get_world_state()
---@return number? frame, number? fade, integer? last the frames to predict
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
    -- the match's end: nothing after it (a ghost past the last frame was work for frames that never come), none once
    -- it's over (the end screen waits as a turn does: it kept predicting a full ghost for nothing)
    local left = tonumber(ws.game_frame) and ws.game_frame - ws.match_frame or nil
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

---A new prediction of the flying props from the flights' frame: with more of them than MAX_GHOSTS, the nearest the
---camera (on screen first) only
local function newPrediction(s, frames, camera, onScreen)
    local list = {}
    -- far props paused: no ghost for those paused now (they wait where they are; the prediction doesn't pause them)
    local near = s.pauseFar and Dynamics.sampleAt(s, s.simFrame) or nil
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
            if onScreen and not onScreen(p[1], p[2], p[3], prop.radius or 1) then d = d + 1e12 end -- off screen last
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

---The flying props' prediction (the one to show) moved up to `frames` ahead of the flights' frame, PREDICT_MS at most
---this call. It's kept while the flights move on as it predicted, so the next turn's ghosts go on from where the last
---turn's prediction got to; pr.base is the flights' frame in it. A new one is needed when a prop is let go flying (a
---flight it doesn't have), on a new level, or when the camera moved away from where its few were picked. A take
---doesn't: the taken prop's ghost is the game's own then (drawGhosts skips carried props), and the drawn flights never
---met it anyway. Takes near the players every turn made it start over every turn (user's log: ghosts 190-390 ms a
---second, more than playing the props).
---The new one is built while the old one stays shown (the game's ghost keeps moving: a new one shown at once could
---only show the few frames it had, the ghosts stalled and jumped as the camera moved), and takes its place once it
---covers the ghost's frames, or at once when the old one can't be shown any more (a rebuild, a new fight: clear drops it)
---@param frames integer
---@param camera number[]? where the camera is: with more flying props than MAX_GHOSTS, the nearest it (on screen first)
---@param onScreen (fun(x: number, y: number, z: number, r: number): boolean)?
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
    -- a new one, built while the old one stays shown
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

---Ghosts off: the prediction shown and the one being built go, their memory at once
function Dynamics.dropPrediction(s)
    s.prediction, s.predictionKey, s.pendingPrediction, s.pendingKey = nil, nil, nil, nil
end

---A color line's numbers as 0-1 (the game reads 0-256 when any of the first three is above 2)
local function unitColor(c)
    if not c then return 1, 1, 1, 1 end
    local r, g, b, a = c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
    if r > 2 or g > 2 or b > 2 then r, g, b = r / 256, g / 256, b / 256 end
    -- up to 2 is brighter in the atmo; drawn as 1, as MGE draws props (over 1, set_color washed them out)
    local function unit(v) return v < 0 and 0 or (v > 1 and 1 or v) end
    return unit(r), unit(g), unit(b), unit(a)
end

-- drawGhosts' lists, kept (no tables a frame)
local ghostProps, ghostDist, ghostPose = {}, {}, setmetatable({}, { __mode = "k" })

local function nearerFirst(p, q) return ghostDist[p] < ghostDist[q] end

---draw3d: the drawn props' ghosts at the game's ghost frame (nothing while it shows none). Only those on screen
---(onScreen(x, y, z, r): the host's check, optional), at most MAX_GHOSTS a frame: the nearest the camera when more
---(they used to be the first MAX_GHOSTS in atmo order, on screen or not: user 2026-11-24, "only ~300 get a ghost")
---@param ws table get_world_state()
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
    -- the ghosts that can show, with their poses
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
    -- more than the game draws (props woken in the prediction add to the picked): the nearest the camera
    if n > Dynamics.MAX_GHOSTS then
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
