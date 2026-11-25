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
---@field group string pool group: shape|friction|hardness|bounce|flag bits (+mass for props), Colliders.groupKey ("box|10000")
---@field friction number?
---@field flag integer?
---@field bounce number?
---@field visible boolean false for "visible 0": solid, not drawn
---@field color number[]? props only: r g b a as written (dynamics.lua paints the carrying object with it)
---@field mass number? props only: the mass line
---@field thrust string? props only: the thrust line (dynamics.lua flies it, flight.lua)
---@field startMode integer? props only: prop_motion's start, 1 active from frame 0 (falls, tumbles, flies its
---thrust), 0 waits until reached; nil: the default (active with thrust, else waits; Colliders.startsActive)
---@field alwaysMove boolean? props only: never paused by far props (prop_motion's always)
---@field noHits boolean? props only: "prop_hits 0", it flies through the other props (still hits the static atmo)
---@field noPlayer boolean? props only: doesn't become real near players (Colliders.collision)
---@field noDynamic boolean? props only: doesn't become real near real dynamic objects (the mod's own, carried props)
---@field noReal boolean? props only: neither: never carried by a pool object, players and real objects pass through
---it (it flies drawn only, needs no dynamic pool object)
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

---A prop's collision toggles from its lines: `prop_collide <player> <dynamic> <atmo>` (1 on, 0 off; no line: all on).
---Player / dynamic: whether it becomes real near players / near real dynamic objects (a real object collides with
---everything real: the game can't filter that). Atmo: whether its drawn flight hits other props. The older lines
---still count: prop_real 0 (neither player nor dynamic), prop_hits 0 (no atmo)
---@param p table<string, string> the entity's lines
---@return boolean player, boolean dynamic, boolean atmo
---A prop's motion line, `prop_motion <start> <always>` (the game's atmo skips it):
---start 1: active from the fight's first frame, any prop: it falls, tumbles and settles under gravity (and flies its
---thrust) before anything comes near; 0: it waits, still, until something reaches it (taken by a player or a dynamic
---object, or hit by a flying prop). No start: the default, active with a thrust, else waiting (Colliders.startsActive).
---always 1: it keeps moving far from every player even when the player lets far props pause (Atmo Play's window);
---0 / none: it may pause there
---@param p table<string, string>
---@return boolean? start nil: not set (the default), boolean always
function Colliders.motion(p)
    local n = {}
    for v in tostring(p.prop_motion or ""):gmatch("%S+") do n[#n + 1] = tonumber(v) end
    local start = nil
    if n[1] ~= nil then start = n[1] ~= 0 end
    return start, n[2] ~= nil and n[2] ~= 0
end

---Whether a prop is active from frame 0: its prop_motion start, else whether it has a thrust (one that pushes)
---@param p table<string, string>
---@param hasThrust boolean
---@return boolean
function Colliders.startsActive(p, hasThrust)
    local start = Colliders.motion(p)
    if start == nil then return hasThrust and true or false end
    return start
end

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

---A line's numbers ("1 2 3" -> { 1, 2, 3 }), {} for nil
---@param text string?
---@return number[]
local function numbers(text)
    local out = {}
    for n in tostring(text or ""):gmatch("%S+") do out[#out + 1] = tonumber(n) or 0 end
    return out
end
Colliders.numbers = numbers

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
---carry "hardness 0.000000": the same group as one without the line)
---@param value string|number|nil
---@return string
function Colliders.hardnessKey(value)
    local n = tonumber(value)
    return (n and n ~= 0) and tostring(n) or ""
end

---A bounce line as the group key part: the number written back the same way every time ("" without one)
---@param value string|number|nil
---@return string
function Colliders.bounceKey(value)
    local n = tonumber(value)
    return n and tostring(n) or ""
end

---A flag line's bits other than static (weapon, nogrip...) as the group key part: "" for none
---@param value string|number|nil
---@return string
function Colliders.flagKey(value)
    local n = tonumber(value)
    if not n then return "" end
    if not Colliders.isDynamicFlag(n) then n = n - Colliders.STATIC_FLAG end
    return n ~= 0 and tostring(n) or ""
end

---A pool group: what a pool object can't change once loaded, so each kind gets pool objects of its own, written
---with these lines in the mod. The game has no setter for friction or hardness, and bounce and flag set live
---(set_obj_bounce, set_obj_flag) aren't recorded in replays (EOBJ lines have neither): a replay would use the
---file's, unlike the fight. Written in the mod they hold in both (bounce probe: docs/atmo-play-plan.md, R2). A prop's mass too (it moves:
---set_obj_mass isn't recorded either), a static object's isn't (it doesn't move). Parts: shape|friction|hardness|
---bounce|flag bits|mass, each "" at its default; empty parts at the end are left out ("box|10000", "sphere||2")
---@param shape string
---@param lines { friction: string|number|nil, hardness: string|number|nil, bounce: string|number|nil, flag: string|number|nil, mass: string|number|nil }?
---@param prop boolean? a prop (the dynamic pool): its mass counts
---@return string
function Colliders.groupKey(shape, lines, prop)
    lines = lines or {}
    local parts = { shape, Colliders.frictionKey(lines.friction), Colliders.hardnessKey(lines.hardness),
        Colliders.bounceKey(lines.bounce), Colliders.flagKey(lines.flag), prop and Colliders.bounceKey(lines.mass) or "" }
    while #parts > 2 and parts[#parts] == "" do parts[#parts] = nil end
    return table.concat(parts, "|")
end

---A group key's parts (Colliders.groupKey), "" for each one at its default
---@param group string
---@return string shape, string friction, string hardness, string bounce, string flag bits, string mass
function Colliders.splitGroup(group)
    local parts = {}
    for part in (group .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = part end
    return parts[1] or group, parts[2] or "", parts[3] or "", parts[4] or "", parts[5] or "", parts[6] or ""
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
                -- the game's other spellings (as drawer.lua reads them): a prop's color went missing when carried
                if key == "col" or key == "colour" then key = "color" end
                entities[#entities].props[key] = value
            end
        end
    end
    return entities, header
end

---What an atmo entity is to Atmo Play, from its lines alone (no geometry): skipped (and why), or solid / a prop
---and its pool group. Colliders.build and MGE's split check (Playable.poolSplitKey) share it
---@param p table<string, string> the entity's lines by key (sides for size)
---@return string? reason skipped: "random", "animated", "parented", "model", "unplaced"
---@return string? shape
---@return string? group Colliders.groupKey
---@return boolean? prop no static bit in its flag
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
        local reason, shape, group, dynamic = Colliders.classify(p)
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
            local list = dynamic and props or colliders
            local player, real, atmo = Colliders.collision(p)
            local start, always = Colliders.motion(p)
            list[#list + 1] = {
                index = index,
                name = entity.name,
                shape = shape,
                pos = { pos[1] or 0, pos[2] or 0, pos[3] or 0 },
                sides = sides,
                frame = frame,
                radius = radius,
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
                alwaysMove = dynamic and always or nil,
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
