-- Atmo lines to collision shapes: the atmo objects the pool can stand in for.
-- Entities are read the way the game's atmo parser reads them (system/atmospheres_manager.lua,
-- Atmospheres.ParseFile): "env_obj <name>" starts one, a "player N" line ignores the lines up to the next
-- env_obj, a later line of the same key wins, size and sides are the same line.
-- Not collidable (still drawn): custom models, and objects the game places differently on each load or
-- moves while it draws them (count, rpos, rsize, move, rotate, drawfunc, framefunc: their collision
-- wouldn't be where they're drawn), and parented objects (their pos is relative to the parent).
-- Collision never depends on the graphics level (min_level / max_level): the map is the same for everyone.
-- Props (dynamics.lua, proof of concept): an entity whose flag line lacks the static bit (8) is a pushable
-- prop, not a static collider: build returns them apart, with their mass.
-- Shape math from MGE (mge/utils/atmo_layer.lua: shapeOf, frameOf, ghost) and the playable-atmo PoC.

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Mat3 = NS.Mat3

---@class AtmoPlayCollider
---@field index integer place among the atmo's entities (ties in the pool rule go to the lower one)
---@field name string the entity's name
---@field shape "box"|"sphere"|"cylinder"
---@field pos number[]
---@field sides number[] box: full sides; sphere: radius first; cylinder: radius, length (along local z)
---@field frame number[][] rotation, local to world
---@field radius number bounding sphere around pos
---@field group string pool group: shape, friction and hardness ("box|10000", "sphere|", "box||5"), Colliders.groupKey
---@field friction number?
---@field flag integer?
---@field bounce number?
---@field visible boolean false for "visible 0": solid, not drawn
---@field color number[]? props only: r g b a as written (dynamics.lua paints the carrying object with it)
---@field matrixTB table? the rotation for set_obj_rot_m, made by the runtime when first needed

---@class AtmoPlayColliders
local Colliders = {
    MIN_SIDE = 0.01,
    STATIC_FLAG = 8,
}

---@param flag string? a flag line
---@return boolean the line makes the entity a dynamic prop: a flag without the static bit
function Colliders.isDynamicFlag(flag)
    local n = tonumber(flag)
    if not n then return false end
    return math.floor(n / Colliders.STATIC_FLAG) % 2 == 0
end

-- keys that keep an entity out of collision, and why (the reason counted in the stats)
local SKIP_KEYS = {
    count = "random", rpos = "random", randompos = "random", rsize = "random", randomsize = "random",
    move = "animated", rotate = "animated", drawfunc = "animated", framefunc = "animated",
    parent = "parented",
}

---@param text string?
---@return number[]
local function numbers(text)
    local out = {}
    for n in tostring(text or ""):gmatch("%S+") do out[#out + 1] = tonumber(n) or 0 end
    return out
end

---A shape line as a collider shape: nil for custom models
---@param value string?
---@return "box"|"sphere"|"cylinder"|nil
function Colliders.shapeOf(value)
    local word = tostring(value or "box"):match("^%s*(%a+)") or "box"
    if word == "custom" then return nil end
    if word == "sphere" then return "sphere" end
    if word == "cylinder" or word == "capsule" then return "cylinder" end
    return "box"
end

---A friction line as the group key part: the number written back the same way every time ("" without one)
---@param value string|number|nil
---@return string
function Colliders.frictionKey(value)
    local n = tonumber(value)
    return n and tostring(n) or ""
end

---A hardness line as the group key part: "" without one or at the game's default 0 (objects moved to the atmo
---carry "hardness 0.000000", and pools written before hardness counted have no line: both still match)
---@param value string|number|nil
---@return string
function Colliders.hardnessKey(value)
    local n = tonumber(value)
    return (n and n ~= 0) and tostring(n) or ""
end

---A pool group: what a pool object can't change once loaded (the game has no setter for these), so each
---kind gets pool objects of its own. "shape|friction", "|hardness" added only when it isn't the default
---@param shape string
---@param friction string|number|nil
---@param hardness string|number|nil
---@return string
function Colliders.groupKey(shape, friction, hardness)
    local h = Colliders.hardnessKey(hardness)
    return shape .. "|" .. Colliders.frictionKey(friction) .. (h ~= "" and "|" .. h or "")
end

---A group key's parts (Colliders.groupKey), "" for a missing friction or hardness
---@param group string
---@return string shape, string friction, string hardness
function Colliders.splitGroup(group)
    local shape, friction, hardness = group:match("^([^|]*)|([^|]*)|?(.*)$")
    return shape or group, friction or "", hardness or ""
end

---A rot line (degrees) as the rotation the game gives the object: rotX(-x) rotY(-y) rotZ(-z), measured in
---game for MGE (mge/utils/atmo_layer.lua, AtmoLayer.frameOf); atmos read rot the way mods do
---@param rot number[]
---@return number[][]
function Colliders.frameOf(rot)
    local r = math.rad
    return Mat3.mul(Mat3.mul(Mat3.rotX(-r(rot[1] or 0)), Mat3.rotY(-r(rot[2] or 0))), Mat3.rotZ(-r(rot[3] or 0)))
end

---The atmo's entities as the game's parser sees them
---@param lines string[]
---@return { name: string, props: table<string, string> }[] entities, string[] header lines before the first
function Colliders.entities(lines)
    local entities, header, ignoring = {}, {}, false
    for _, raw in ipairs(lines) do
        local line = raw:gsub("^%s*", ""):gsub("[\r\n]", "")
        local name = line:match("^env_obj (.*)$")
        if name then
            entities[#entities + 1] = { name = name, props = {} }
            ignoring = false
        elseif line:match("^player %d") then
            ignoring = true
        elseif #entities == 0 then
            header[#header + 1] = raw
        elseif not ignoring then
            local key, value = line:match("^([%a_]+)%s+(.-)%s*$")
            if key then
                if key == "size" then key = "sides" end
                entities[#entities].props[key] = value
            end
        end
    end
    return entities, header
end

---Collision shapes of an atmo
---@param lines string[] the atmo's lines
---@return AtmoPlayCollider[] colliders static ones
---@return { collidable: integer, total: integer, skipped: table<string, integer>, props: integer } stats
---@return AtmoPlayCollider[] props dynamic ones (with mass), in atmo order
function Colliders.build(lines)
    local entities = Colliders.entities(lines)
    local colliders, skipped, props = {}, {}, {}
    -- one frame per rot line: maps repeat rotations a lot (MGE's frameByRot), colliders only read them
    local frames = {}
    for index, entity in ipairs(entities) do
        local p = entity.props
        local reason
        for key, why in pairs(SKIP_KEYS) do
            if p[key] ~= nil then
                reason = why
                break
            end
        end
        local shape = Colliders.shapeOf(p.shape)
        if not reason and not shape then reason = "model" end
        if not reason and not p.pos then reason = "unplaced" end
        if reason then
            skipped[reason] = (skipped[reason] or 0) + 1
        else
            local written = p.sides and numbers(p.sides) or { 1, 1, 1 }
            local sides = {}
            for k = 1, 3 do sides[k] = math.max(math.abs(written[k] or 0), Colliders.MIN_SIDE) end
            local radius
            if shape == "sphere" then
                radius = sides[1]
            elseif shape == "cylinder" then
                radius = sides[2] / 2 + sides[1]
            else
                radius = math.sqrt(sides[1] ^ 2 + sides[2] ^ 2 + sides[3] ^ 2) / 2
            end
            local pos = numbers(p.pos)
            local rotKey = p.rot or ""
            local frame = frames[rotKey]
            if not frame then
                frame = Colliders.frameOf(numbers(p.rot))
                frames[rotKey] = frame
            end
            local dynamic = Colliders.isDynamicFlag(p.flag)
            local list = dynamic and props or colliders
            list[#list + 1] = {
                index = index,
                name = entity.name,
                shape = shape,
                pos = { pos[1] or 0, pos[2] or 0, pos[3] or 0 },
                sides = sides,
                frame = frame,
                radius = radius,
                group = Colliders.groupKey(shape --[[@as string]], p.friction, p.hardness),
                friction = tonumber(p.friction),
                flag = tonumber(p.flag),
                bounce = tonumber(p.bounce),
                visible = not (p.visible and p.visible:match("^0") ~= nil),
                mass = dynamic and tonumber(p.mass) or nil,
                color = dynamic and p.color and numbers(p.color) or nil,
            }
        end
    end
    return colliders, { collidable = #colliders, total = #entities, skipped = skipped, props = #props }, props
end

---Distance from a point to a collider's surface, 0 inside it
---@param c AtmoPlayCollider
---@param p number[]
---@return number
function Colliders.distance(c, p)
    local dx, dy, dz = p[1] - c.pos[1], p[2] - c.pos[2], p[3] - c.pos[3]
    if c.shape == "sphere" then
        return math.max(0, math.sqrt(dx * dx + dy * dy + dz * dz) - c.sides[1])
    end
    -- into the collider's own axes (frame is local to world, so its transpose)
    local f = c.frame
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
