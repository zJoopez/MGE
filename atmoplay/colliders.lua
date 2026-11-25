-- Atmo lines to collision shapes. Entities are read as the game's atmo parser reads them (Atmospheres.ParseFile):
-- "env_obj <name>" starts one, a "player N" line ignores the lines up to the next env_obj, a later line of a key wins,
-- size and sides are one line. Not collidable: custom models, randomly placed or animated entities, parented ones.
-- An entity whose flag lacks the static bit (8) is a prop (dynamics.lua), returned apart.

local NS = ATMOPLAY_LOADING

local Mat3 = NS.Mat3

---@class AtmoPlayCollider
---@field index integer place among the atmo's entities (ties go to the lower one)
---@field name string
---@field shape "box"|"sphere"|"cylinder"
---@field pos number[]
---@field sides number[] box: full sides; sphere: radius first; cylinder: radius, length (along local z)
---@field frame number[][] rotation, local to world
---@field radius number bounding sphere
---@field group string pool group (Colliders.groupKey)
---@field friction number?
---@field flag integer?
---@field bounce number?
---@field visible boolean false for "visible 0": solid, not drawn
---@field color number[]? props: r g b a as written
---@field mass number? props
---@field thrust string? props: the thrust line
---@field startMode integer? props: prop_motion start, 1 active from frame 0, 0 waits; nil: active iff it has thrust
---@field noHits boolean? props: flies through other props
---@field noPlayer boolean? props: doesn't become real near players
---@field noDynamic boolean? props: doesn't become real near real dynamic objects
---@field noReal boolean? props: never real (needs no pool object)
---@field matrixTB table? set_obj_rot_m's rotation, made when first needed

---@class AtmoPlayColliders
local Colliders = {
    MIN_SIDE = 0.01,
    STATIC_FLAG = 8,
}

---@param flag string|number|nil a flag line
---@return boolean a flag without the static bit
function Colliders.isDynamicFlag(flag)
    local n = tonumber(flag)
    if not n then return false end
    return math.floor(n / Colliders.STATIC_FLAG) % 2 == 0
end

-- keys that keep an entity out of collision, and why
local SKIP_KEYS = {
    count = "random", rpos = "random", randompos = "random", rsize = "random", randomsize = "random",
    move = "animated", rotate = "animated", drawfunc = "animated", framefunc = "animated",
    parent = "parented",
}

---`prop_motion <start>`: true active from frame 0, false waits until reached, nil not set
---@param p table<string, string>
---@return boolean?
function Colliders.motion(p)
    local first = tonumber(tostring(p.prop_motion or ""):match("%S+") or "")
    if first == nil then return nil end
    return first ~= 0
end

---Whether a prop is active from frame 0: its prop_motion, else whether it has a thrust
function Colliders.startsActive(p, hasThrust)
    local start = Colliders.motion(p)
    if start == nil then return hasThrust and true or false end
    return start
end

---`prop_collide <player> <dynamic> <atmo>` (no line: all on; the older prop_real 0 / prop_hits 0 still read): whether a
---prop becomes real near players / near real dynamic objects, and whether its flight hits other props
---@param p table<string, string>
---@return boolean player, boolean dynamic, boolean atmo
function Colliders.collision(p)
    local function on(n) return n == nil or n ~= 0 end
    if p.prop_collide then
        local n = {}
        for v in tostring(p.prop_collide):gmatch("%S+") do n[#n + 1] = tonumber(v) end
        return on(n[1]), on(n[2]), on(n[3])
    end
    local real = not (p.prop_real ~= nil and p.prop_real:match("^%s*0") ~= nil)
    local hits = not (p.prop_hits ~= nil and p.prop_hits:match("^%s*0") ~= nil)
    return real, real, hits
end

---"1 2 3" -> { 1, 2, 3 }, {} for nil
---@param text string?
---@return number[]
local function numbers(text)
    local out = {}
    for n in tostring(text or ""):gmatch("%S+") do out[#out + 1] = tonumber(n) or 0 end
    return out
end
Colliders.numbers = numbers

---A shape line as a collider shape, nil for custom models
---@return "box"|"sphere"|"cylinder"|nil
function Colliders.shapeOf(value)
    local word = tostring(value or "box"):match("^%s*(%a+)") or "box"
    if word == "custom" then return nil end
    if word == "sphere" then return "sphere" end
    if word == "cylinder" or word == "capsule" then return "cylinder" end
    return "box"
end

---Bounding sphere radius (sides as the atmo writes them; a pill is "cylinder" or "capsule")
function Colliders.radius(shape, sides)
    if shape == "sphere" then return sides[1] end
    if shape == "cylinder" or shape == "capsule" then return sides[2] / 2 + sides[1] end
    return math.sqrt(sides[1] ^ 2 + sides[2] ^ 2 + sides[3] ^ 2) / 2
end

-- group key parts: each written back the same way every time, "" at its default
function Colliders.frictionKey(value)
    local n = tonumber(value)
    return n and tostring(n) or ""
end

---Hardness 0 is the default ("hardness 0.000000" groups with no line)
function Colliders.hardnessKey(value)
    local n = tonumber(value)
    return (n and n ~= 0) and tostring(n) or ""
end

Colliders.bounceKey = Colliders.frictionKey

---The flag's bits other than static
function Colliders.flagKey(value)
    local n = tonumber(value)
    if not n then return "" end
    if not Colliders.isDynamicFlag(n) then n = n - Colliders.STATIC_FLAG end
    return n ~= 0 and tostring(n) or ""
end

---A pool group: what a pool object can't change once loaded (no setter, or setters replays don't record), so each
---kind gets its own pool objects: shape|friction|hardness|bounce|flag bits|mass (mass for props only). Empty parts at
---the end are left out ("box|10000", "sphere||2")
---@param prop boolean? a prop: its mass counts
---@return string
function Colliders.groupKey(shape, lines, prop)
    lines = lines or {}
    local parts = { shape, Colliders.frictionKey(lines.friction), Colliders.hardnessKey(lines.hardness),
        Colliders.bounceKey(lines.bounce), Colliders.flagKey(lines.flag), prop and Colliders.bounceKey(lines.mass) or "" }
    while #parts > 2 and parts[#parts] == "" do parts[#parts] = nil end
    return table.concat(parts, "|")
end

---A group key's parts, "" for each at its default
---@return string shape, string friction, string hardness, string bounce, string flagBits, string mass
function Colliders.splitGroup(group)
    local parts = {}
    for part in (group .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = part end
    return parts[1] or group, parts[2] or "", parts[3] or "", parts[4] or "", parts[5] or "", parts[6] or ""
end

---A rot line (degrees) as the game turns objects: rotX(-x) rotY(-y) rotZ(-z)
---@param rot number[]
---@return number[][]
function Colliders.frameOf(rot)
    local r = math.rad
    return Mat3.mul(Mat3.mul(Mat3.rotX(-r(rot[1] or 0)), Mat3.rotY(-r(rot[2] or 0))), Mat3.rotZ(-r(rot[3] or 0)))
end

---The atmo's entities as the game's parser sees them, each with its raw lines; a "player N" line marks it `player`
---@param lines string[]
---@return { name: string, props: table<string, string>, lines: string[], player: boolean }[] entities
---@return string[] header lines before the first entity
function Colliders.entities(lines)
    local entities, header, current, ignoring = {}, {}, nil, false
    for _, raw in ipairs(lines) do
        local line = raw:gsub("^%s*", ""):gsub("[\r\n]", "")
        local name = line:match("^env_obj (.*)$")
        if name then
            current = { name = name, props = {}, lines = { raw }, player = false }
            entities[#entities + 1] = current
            ignoring = false
        elseif not current then
            header[#header + 1] = raw
        else
            current.lines[#current.lines + 1] = raw
            if line:match("^player %d") then
                ignoring, current.player = true, true
            elseif not ignoring then
                local key, value = line:match("^([%a_]+)%s+(.-)%s*$")
                if key then
                    if key == "size" then key = "sides" end
                    if key == "col" or key == "colour" then key = "color" end
                    current.props[key] = value
                end
            end
        end
    end
    return entities, header
end

---What an entity is to Atmo Play from its lines: skipped (and why), or its shape, pool group and whether it's a prop.
---Colliders.build and MGE's split check share it
---@param p table<string, string>
---@return string? reason "random", "animated", "parented", "model", "unplaced"
---@return string? shape
---@return string? group
---@return boolean? prop
function Colliders.classify(p)
    for key, why in pairs(SKIP_KEYS) do
        if p[key] ~= nil then return why, nil, nil, nil end
    end
    local shape = Colliders.shapeOf(p.shape)
    if not shape then return "model", nil, nil, nil end
    if not p.pos then return "unplaced", nil, nil, nil end
    local prop = Colliders.isDynamicFlag(p.flag)
    return nil, shape, Colliders.groupKey(shape, p, prop), prop
end

---Collision shapes of an atmo
---@param lines string[]
---@return AtmoPlayCollider[] colliders static ones
---@return { collidable: integer, total: integer, skipped: table<string, integer>, props: integer } stats
---@return AtmoPlayCollider[] props dynamic ones, in atmo order
function Colliders.build(lines)
    local entities = Colliders.entities(lines)
    local colliders, skipped, props = {}, {}, {}
    local frames = {} -- one frame per rot line: maps repeat rotations a lot
    for index, entity in ipairs(entities) do
        local p = entity.props
        local reason, shape, group, dynamic = Colliders.classify(p)
        if reason then
            skipped[reason] = (skipped[reason] or 0) + 1
        else
            local written = p.sides and numbers(p.sides) or { 1, 1, 1 }
            local sides = {}
            for k = 1, 3 do sides[k] = math.max(math.abs(written[k] or 0), Colliders.MIN_SIDE) end
            local pos = numbers(p.pos)
            local rotKey = p.rot or ""
            local frame = frames[rotKey]
            if not frame then
                frame = Colliders.frameOf(numbers(p.rot))
                frames[rotKey] = frame
            end
            local list = dynamic and props or colliders
            local player, real, atmo = Colliders.collision(p)
            local start = Colliders.motion(p)
            list[#list + 1] = {
                index = index,
                name = entity.name,
                shape = shape,
                pos = { pos[1] or 0, pos[2] or 0, pos[3] or 0 },
                sides = sides,
                frame = frame,
                radius = Colliders.radius(shape, sides),
                group = group,
                friction = tonumber(p.friction),
                flag = tonumber(p.flag),
                bounce = tonumber(p.bounce),
                visible = not (p.visible and p.visible:match("^0") ~= nil),
                mass = dynamic and tonumber(p.mass) or nil,
                thrust = dynamic and p.thrust or nil,
                noHits = dynamic and not atmo or nil,
                noPlayer = dynamic and not player or nil,
                noDynamic = dynamic and not real or nil,
                noReal = dynamic and not player and not real or nil,
                color = dynamic and p.color and numbers(p.color) or nil,
                startMode = (dynamic and start ~= nil) and (start and 1 or 0) or nil,
            }
        end
    end
    return colliders, { collidable = #colliders, total = #entities, skipped = skipped, props = #props }, props
end

---Distance from a point to a collider's surface, 0 inside
---@param c AtmoPlayCollider
---@param p number[]
---@return number
function Colliders.distance(c, p)
    local dx, dy, dz = p[1] - c.pos[1], p[2] - c.pos[2], p[3] - c.pos[3]
    if c.shape == "sphere" then
        return math.max(0, math.sqrt(dx * dx + dy * dy + dz * dz) - c.sides[1])
    end
    local f = c.frame -- into its own axes (the transpose)
    local x = dx * f[1][1] + dy * f[2][1] + dz * f[3][1]
    local y = dx * f[1][2] + dy * f[2][2] + dz * f[3][2]
    local z = dx * f[1][3] + dy * f[2][3] + dz * f[3][3]
    if c.shape == "cylinder" then
        local axial = math.max(0, math.abs(z) - c.sides[2] / 2)
        return math.max(0, math.sqrt(x * x + y * y + axial * axial) - c.sides[1])
    end
    x = math.max(0, math.abs(x) - c.sides[1] / 2)
    y = math.max(0, math.abs(y) - c.sides[2] / 2)
    z = math.max(0, math.abs(z) - c.sides[3] / 2)
    return math.sqrt(x * x + y * y + z * z)
end

NS.Colliders = Colliders
return Colliders
