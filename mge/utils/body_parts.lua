-- Body and joint blocks of player sections (docs/body-parts-plan.md). A section is parsed into parts that
-- keep their lines as written, so a write changes only the edited ones. Game facts (the plan's probes):
-- a player's parts sit at R * file + t (rigid, no mirror; measured per player after a reload: fitFrame); a
-- body's rot line turns as rotX(-x) rotY(-y) rotZ(-z) like env_obj's, in the player frame; joints stay at
-- their own pos (they don't follow their bodies); a head that isn't a sphere crashes the game

local Mat3 = MGE.Mat3

---@class BodyParts
local BodyParts = {}
MGE.BodyParts = BodyParts

---@class BodyPartProp
---@field key string
---@field value string
---@field raw string? the line as written, until changed

---@class BodyPart a body or joint block of a player section
---@field kind "body"|"joint"
---@field name string lower case, as the BODYPARTS / JOINTS keys
---@field header string? the block's first line as written
---@field props BodyPartProp[]

---@class BodySection
---@field preamble string[] lines before the first block
---@field parts BodyPart[]

-- the classic body (data/mod/modmaker.tbm, player 0): what a part without the line has
BodyParts.DEFAULTS = {
    body = {
        head = { shape = "sphere", sides = { 0.2, 0, 0 }, pos = { 1, 0.85, 2.65 } },
        breast = { shape = "box", sides = { 0.2, 0.1, 0.3 }, pos = { 1, 0.9, 2.2 } },
        chest = { shape = "box", sides = { 0.5, 0.15, 0.2 }, pos = { 1, 0.9, 1.95 } },
        stomach = { shape = "box", sides = { 0.35, 0.15, 0.2 }, pos = { 1, 0.95, 1.75 } },
        groin = { shape = "box", sides = { 0.2, 0.15, 0.2 }, pos = { 1, 1, 1.55 } },
        r_pecs = { shape = "box", sides = { 0.2, 0.15, 0.2 }, pos = { 0.75, 0.9, 2.15 } },
        r_biceps = { shape = "box", sides = { 0.4, 0.2, 0.2 }, pos = { 0.45, 0.9, 2.3 } },
        r_triceps = { shape = "box", sides = { 0.4, 0.1, 0.1 }, pos = { 0.05, 0.9, 2.3 } },
        l_pecs = { shape = "box", sides = { 0.2, 0.15, 0.2 }, pos = { 1.25, 0.9, 2.15 } },
        l_biceps = { shape = "box", sides = { 0.4, 0.2, 0.2 }, pos = { 1.55, 0.9, 2.3 } },
        l_triceps = { shape = "box", sides = { 0.4, 0.1, 0.1 }, pos = { 1.95, 0.9, 2.3 } },
        r_hand = { shape = "box", sides = { 0.22, 0.22, 0.22 }, pos = { -0.35, 0.85, 2.3 } },
        l_hand = { shape = "box", sides = { 0.22, 0.22, 0.22 }, pos = { 2.35, 0.85, 2.3 } },
        r_butt = { shape = "box", sides = { 0.1, 0.1, 0.1 }, pos = { 0.8, 1, 1.45 } },
        l_butt = { shape = "box", sides = { 0.1, 0.1, 0.1 }, pos = { 1.2, 1, 1.45 } },
        r_thigh = { shape = "cylinder", sides = { 0.12, 0.3, 0 }, pos = { 0.8, 1, 1.1 } },
        l_thigh = { shape = "cylinder", sides = { 0.12, 0.3, 0 }, pos = { 1.2, 1, 1.1 } },
        l_leg = { shape = "cylinder", sides = { 0.13, 0.3, 0 }, pos = { 1.2, 1, 0.5 } },
        r_leg = { shape = "cylinder", sides = { 0.13, 0.3, 0 }, pos = { 0.8, 1, 0.5 } },
        r_foot = { shape = "box", sides = { 0.2, 0.5, 0.08 }, pos = { 0.8, 0.9, 0.1 } },
        l_foot = { shape = "box", sides = { 0.2, 0.5, 0.08 }, pos = { 1.2, 0.9, 0.1 } },
    },
    joint = {
        neck = { pos = { 1, 0.9, 2.5 }, radius = 0.11, axis = { 1, 0, 0 }, range = { 0.5, -0.5 }, strength = 1, velocity = 50 },
        chest = { pos = { 1, 0.9, 2.05 }, radius = 0.18, axis = { 0, 0, 1 }, range = { 1, -1 }, strength = 4, velocity = 20 },
        lumbar = { pos = { 1, 0.95, 1.85 }, radius = 0.16, axis = { 0, 1, 0 }, range = { 0.5, -0.5 }, strength = 3, velocity = 5 },
        abs = { pos = { 1, 1, 1.65 }, radius = 0.14, axis = { 1, 0, 0 }, range = { 0.4, -0.6 }, strength = 3, velocity = 5 },
        r_pecs = { pos = { 0.85, 0.85, 2.2 }, radius = 0.18, axis = { 0, 0, 1 }, range = { 1.5, -0.7 }, strength = 3, velocity = 15 },
        r_shoulder = { pos = { 0.65, 0.9, 2.3 }, radius = 0.18, axis = { 0, 1, 0 }, range = { 1.2, -1.2 }, strength = 4, velocity = 20 },
        r_elbow = { pos = { 0.25, 0.9, 2.3 }, radius = 0.16, axis = { 0, 0, 1 }, range = { 2.3, 0.05 }, strength = 2, velocity = 40 },
        l_pecs = { pos = { 1.15, 0.85, 2.2 }, radius = 0.18, axis = { 0, 0, 1 }, range = { 1.5, -0.7 }, strength = 3, velocity = 15 },
        l_shoulder = { pos = { 1.35, 0.9, 2.3 }, radius = 0.18, axis = { 0, 1, 0 }, range = { 1.2, -1.2 }, strength = 4, velocity = 20 },
        l_elbow = { pos = { 1.75, 0.9, 2.3 }, radius = 0.16, axis = { 0, 0, 1 }, range = { 2.3, 0.05 }, strength = 2, velocity = 40 },
        r_wrist = { pos = { -0.2, 0.9, 2.3 }, radius = 0.11, axis = { 0, 0, 1 }, range = { 2, -0.3 }, strength = 2, velocity = 60 },
        l_wrist = { pos = { 2.2, 0.9, 2.3 }, radius = 0.11, axis = { 0, 0, 1 }, range = { 2, -0.3 }, strength = 2, velocity = 60 },
        r_glute = { pos = { 0.9, 1.1, 1.51 }, radius = 0.16, axis = { 0, 1, 0 }, range = { 1.2, -0.2 }, strength = 4, velocity = 10 },
        l_glute = { pos = { 1.1, 1.1, 1.51 }, radius = 0.16, axis = { 0, 1, 0 }, range = { 1.2, -0.2 }, strength = 4, velocity = 10 },
        r_hip = { pos = { 0.79, 1, 1.4 }, radius = 0.16, axis = { 1, 0, 0 }, range = { 1, -1.8 }, strength = 2, velocity = 12 },
        l_hip = { pos = { 1.21, 1, 1.4 }, radius = 0.16, axis = { 1, 0, 0 }, range = { 1, -1.8 }, strength = 2, velocity = 12 },
        r_knee = { pos = { 0.8, 1, 0.8 }, radius = 0.14, axis = { 1, 0, 0 }, range = { 2.3, 0 }, strength = 4, velocity = 40 },
        l_knee = { pos = { 1.2, 1, 0.8 }, radius = 0.14, axis = { 1, 0, 0 }, range = { 2.3, 0 }, strength = 4, velocity = 40 },
        r_ankle = { pos = { 0.8, 1.05, 0.25 }, radius = 0.11, axis = { 1, 0, 0 }, range = { 1.1, -0.3 }, strength = 1, velocity = 8 },
        l_ankle = { pos = { 1.2, 1.05, 0.25 }, radius = 0.11, axis = { 1, 0, 0 }, range = { 1.1, -0.3 }, strength = 1, velocity = 8 },
    },
}

---A joint's single-number line (radius, strength, velocity), else the classic value
---@param section BodySection
---@param name string
---@param key "radius"|"strength"|"velocity"
---@return number?
function BodyParts.jointNumber(section, name, key)
    name = name:lower()
    local part = BodyParts.part(section, "joint", name)
    local v = part and tonumber((BodyParts.getProp(part, key) or ""):match("^(%S+)"))
    if v then return v end
    local d = BodyParts.DEFAULTS.joint[name]
    return d and d[key] or nil
end

---A joint's range line (two numbers), else the classic one
---@param section BodySection
---@param name string
---@return number[]?
function BodyParts.range(section, name)
    name = name:lower()
    local part = BodyParts.part(section, "joint", name)
    local a, b = tostring(part and BodyParts.getProp(part, "range") or ""):match("(%S+)%s+(%S+)")
    if tonumber(a) and tonumber(b) then return { tonumber(a), tonumber(b) } end
    local d = BodyParts.DEFAULTS.joint[name]
    return d and d.range and { d.range[1], d.range[2] } or nil
end

---Sets a joint line on the joints, the twins getting the same text with mirror (classic twins share axis and
---range: only positions mirror)
---@param section BodySection
---@param names string[]
---@param key string
---@param text string
---@param mirror boolean?
function BodyParts.setJointLine(section, names, key, text, mirror)
    for _, n in ipairs(BodyParts.withTwins(names, mirror)) do
        BodyParts.setProp(BodyParts.part(section, "joint", n, true) --[[@as BodyPart]], key, text)
    end
end

---Moves the joints' pos lines through fn (player frame); with mirrorX their twins (not selected themselves)
---get it mirrored. Bodies turning about a moved joint keep their place (BodyParts.transform)
---@param section BodySection
---@param names string[]
---@param fn fun(p: number[], name: string): number[]
---@param mirrorX number?
function BodyParts.transformJoints(section, names, fn, mirrorX)
    BodyParts.transform(section, nil, {}, { pos = fn }, mirrorX, names)
end

-- single-number body lines and their classic values (modmaker.tbm: every body the same, hands flag 1)
BodyParts.NUMBER_DEFAULTS = { density = 0.25, friction = 0.3, bounce = 0.1, hardness = 1, flag = 0 }
local FLAG_DEFAULTS = { r_hand = 1, l_hand = 1 }

---A body's single-number line, else the classic value
---@param section BodySection
---@param name string
---@param key string a NUMBER_DEFAULTS key
---@return number?
function BodyParts.number(section, name, key)
    name = name:lower()
    local part = BodyParts.part(section, "body", name)
    local v = part and tonumber((BodyParts.getProp(part, key) or ""):match("^(%S+)"))
    if v then return v end
    if key == "flag" and FLAG_DEFAULTS[name] then return FLAG_DEFAULTS[name] end
    return BodyParts.NUMBER_DEFAULTS[key]
end

---The names with their twins added (Mirror), each once
---@param names string[]
---@param mirror boolean?
---@return string[]
function BodyParts.withTwins(names, mirror)
    local out, seen = {}, {}
    for _, n in ipairs(names) do
        n = n:lower()
        if not seen[n] then out[#out + 1], seen[n] = n, true end
        local twin = mirror and BodyParts.twin(n)
        if twin and not seen[twin] then out[#out + 1], seen[twin] = twin, true end
    end
    return out
end

---Sets a single-number line on the bodies (and their twins with mirror)
---@param section BodySection
---@param names string[]
---@param key string
---@param value number
---@param mirror boolean?
function BodyParts.setNumber(section, names, key, value, mirror)
    local text = key == "flag" and tostring(math.floor(value + 0.5)) or MGE.FileHandler.formatNumber(value)
    for _, n in ipairs(BodyParts.withTwins(names, mirror)) do
        BodyParts.setProp(BodyParts.part(section, "body", n, true) --[[@as BodyPart]], key, text)
    end
end

-- the two bodies each classic joint links (by the classic layout: each joint sits between them).
-- get_joint_bodies (5.78+) is asked first where the game has it
BodyParts.LINKS = {
    neck = { "head", "breast" }, chest = { "breast", "chest" }, lumbar = { "chest", "stomach" },
    abs = { "stomach", "groin" }, r_pecs = { "breast", "r_pecs" }, r_shoulder = { "r_pecs", "r_biceps" },
    r_elbow = { "r_biceps", "r_triceps" }, l_pecs = { "breast", "l_pecs" }, l_shoulder = { "l_pecs", "l_biceps" },
    l_elbow = { "l_biceps", "l_triceps" }, r_wrist = { "r_triceps", "r_hand" }, l_wrist = { "l_triceps", "l_hand" },
    r_glute = { "groin", "r_butt" }, l_glute = { "groin", "l_butt" }, r_hip = { "r_butt", "r_thigh" },
    l_hip = { "l_butt", "l_thigh" }, r_knee = { "r_thigh", "r_leg" }, l_knee = { "l_thigh", "l_leg" },
    r_ankle = { "r_leg", "r_foot" }, l_ankle = { "l_leg", "l_foot" },
}

local INDENT, PROP_INDENT = "   ", "      "

---------------------------------------------------------------------------------------------------- sections

---Parts of a player section, lines before the first part kept as they are
---@param lines string[]
---@return BodySection
function BodyParts.parseSection(lines)
    local out, current = { preamble = {}, parts = {} }, nil
    for _, line in ipairs(lines) do
        local kind, name = line:match("^%s*(%a+)%s+(%S+)%s*$")
        if kind == "body" or kind == "joint" then
            current = { kind = kind, name = name:lower(), header = line, props = {} }
            table.insert(out.parts, current)
        elseif current and line:match("%S") then
            local key, value = line:match("^%s*(%S+)%s*(.-)%s*$")
            table.insert(current.props, { key = key, value = value, raw = line })
        elseif not current then
            table.insert(out.preamble, line)
        end
    end
    return out
end

---@param part BodyPart
---@param key string
---@return string?
function BodyParts.getProp(part, key)
    for _, p in ipairs(part.props) do if p.key == key then return p.value end end
    return nil
end

---@param part BodyPart
---@param key string
---@param value string
function BodyParts.setProp(part, key, value)
    for _, p in ipairs(part.props) do
        if p.key == key then
            p.value, p.raw = value, nil
            return
        end
    end
    table.insert(part.props, { key = key, value = value })
end

---@param section BodySection
---@return string[]
function BodyParts.sectionLines(section)
    local lines = {}
    for _, l in ipairs(section.preamble) do table.insert(lines, l) end
    for _, part in ipairs(section.parts) do
        table.insert(lines, part.header or (INDENT .. part.kind .. " " .. part.name))
        for _, p in ipairs(part.props) do
            table.insert(lines, p.raw or (PROP_INDENT .. p.key .. " " .. p.value))
        end
    end
    return lines
end

---@param value string?
---@return number[]?
function BodyParts.readVec(value)
    local x, y, z = tostring(value or ""):match("(%S+)%s+(%S+)%s+(%S+)")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    return x and y and z and { x, y, z } or nil
end

---A part of the section, added (empty) when missing and create is set
---@param section BodySection
---@param kind "body"|"joint"
---@param name string
---@param create boolean?
---@return BodyPart?
function BodyParts.part(section, kind, name, create)
    name = name:lower()
    for _, part in ipairs(section.parts) do
        if part.kind == kind and part.name == name then return part end
    end
    if not create then return nil end
    local part = { kind = kind, name = name, props = {} }
    table.insert(section.parts, part)
    return part
end

---A player's section: its own lines, else the shared ones (a write then gives the player its own section)
---@param parsed FileParserResult
---@param player integer 0-based
---@return BodySection section
---@return boolean own the player has its own section
function BodyParts.section(parsed, player)
    local FH = MGE.FileHandler
    local own = FH.getPlayerLines(parsed, player)
    return BodyParts.parseSection(own or FH.getSharedPlayerLines(parsed) or {}), own ~= nil
end

---@param parsed FileParserResult
---@param player integer 0-based
---@param section BodySection
function BodyParts.write(parsed, player, section)
    MGE.FileHandler.setPlayerLines(parsed, player, BodyParts.sectionLines(section))
end

---A vector line of a part, else the classic default (a copy)
---@param section BodySection
---@param kind "body"|"joint"
---@param name string
---@param key string
---@return number[]?
function BodyParts.vector(section, kind, name, key)
    local part = BodyParts.part(section, kind, name)
    local v = part and BodyParts.readVec(BodyParts.getProp(part, key))
    if v then return v end
    local defaults = BodyParts.DEFAULTS[kind][name:lower()]
    local d = defaults and defaults[key]
    return type(d) == "table" and { d[1], d[2], d[3] } or nil
end

local SHAPE_WORDS = { box = "box", cube = "box", sphere = "sphere", cylinder = "cylinder", capsule = "cylinder" }

---A body's shape as MGE writes it: "box", "sphere" or "cylinder" (the game also reads cube and capsule)
---@param section BodySection
---@param name string
---@return string?
function BodyParts.shape(section, name)
    local part = BodyParts.part(section, "body", name)
    local word = part and BodyParts.getProp(part, "shape")
    word = word and word:match("^(%a+)")
    local d = BodyParts.DEFAULTS.body[name:lower()]
    return SHAPE_WORDS[(word or ""):lower()] or (d and d.shape) or nil
end

---Whether a body's shape may change: a head that isn't a sphere crashes the game
---@param name string
---@return boolean
function BodyParts.canChangeShape(name)
    return name:lower() ~= "head"
end

---Sides for another shape, about the same size: box x y z full sides; sphere x radius; cylinder (a pill
---along z) x radius, y length
---@param from string
---@param to string
---@param s number[]
---@return number[]
function BodyParts.convertSides(from, to, s)
    local min = MGE.MIN_SIDE or 0.0001
    local x, y, z = math.abs(s[1]), math.abs(s[2]), math.abs(s[3])
    local out
    if from == to then
        out = { s[1], s[2], s[3] }
    elseif from == "sphere" then
        out = to == "box" and { 2 * x, 2 * x, 2 * x } or { x, x, 0 }
    elseif from == "cylinder" then
        out = to == "box" and { 2 * x, 2 * x, y + 2 * x } or { x, 0, 0 }
    else -- box
        out = to == "sphere" and { math.max(x, y, z) / 2, 0, 0 } or { math.max(x, y) / 2, math.max(z - math.max(x, y), min), 0 }
    end
    out[1] = math.max(math.abs(out[1]), min)
    if to ~= "sphere" then out[2] = math.max(math.abs(out[2]), min) end
    if to == "box" then out[3] = math.max(math.abs(out[3]), min) end
    return out
end

---Sets a body's shape, its sides converted (BodyParts.convertSides). False for the head
---@param section BodySection
---@param name string
---@param shape "box"|"sphere"|"cylinder"
---@return boolean changed
function BodyParts.setShape(section, name, shape)
    if not BodyParts.canChangeShape(name) then return false end
    local from = BodyParts.shape(section, name) or "box"
    if from == shape then return false end
    local sides = BodyParts.convertSides(from, shape, BodyParts.vector(section, "body", name, "sides") or { 0.1, 0.1, 0.1 })
    local part = BodyParts.part(section, "body", name, true) --[[@as BodyPart]]
    BodyParts.setProp(part, "shape", shape)
    BodyParts.setProp(part, "sides", MGE.FileHandler.formatNumbers(sides[1], sides[2], sides[3]))
    return true
end

---------------------------------------------------------------------------------------------------- mirror

---The l_ / r_ twin of a part name, nil for the middle ones
---@param name string
---@return string?
function BodyParts.twin(name)
    name = name:lower()
    local side, rest = name:match("^([lr])_(.+)$")
    if not side then return nil end
    return (side == "l" and "r_" or "l_") .. rest
end

---The x the twins mirror around: the middle bodies' average (1 on the classic body)
---@param section BodySection
---@return number
function BodyParts.mirrorX(section)
    local sum, n = 0, 0
    for name in pairs(BodyParts.DEFAULTS.body) do
        if not BodyParts.twin(name) then
            sum, n = sum + BodyParts.vector(section, "body", name, "pos")[1], n + 1
        end
    end
    return n > 0 and sum / n or 1
end

---@param p number[] a position in the player frame
---@param cx number BodyParts.mirrorX
---@return number[]
function BodyParts.mirrorPos(p, cx)
    return { 2 * cx - p[1], p[2], p[3] }
end

---A rot line (degrees) mirrored across the x plane: S M S with S = diag(-1, 1, 1) keeps x, flips y and z
---@param r number[]
---@return number[]
function BodyParts.mirrorRot(r)
    return { r[1], -r[2], -r[3] }
end

---------------------------------------------------------------------------------------------------- frames

---A rot line (degrees) as a matrix: rotX(-x) rotY(-y) rotZ(-z), like env_obj (measured for bodies)
---@param r number[]
---@return number[][]
function BodyParts.rotMatrix(r)
    local x, y, z = math.rad(r[1]), math.rad(r[2]), math.rad(r[3])
    return Mat3.mul(Mat3.rotX(-x), Mat3.mul(Mat3.rotY(-y), Mat3.rotZ(-z)))
end

---The rot line (degrees) of a matrix, BodyParts.rotMatrix's inverse
---@param m number[][]
---@return number[]
function BodyParts.rotLine(m)
    local x, y, z = Mat3.toEulerXYZ(m)
    return { -math.deg(x), -math.deg(y), -math.deg(z) }
end

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function length(a) return math.sqrt(dot(a, a)) end

---Orthonormal axes (as rows) from three points; nil when they're (nearly) on a line
local function axesOf(a, b, c)
    local x, w = sub(b, a), sub(c, a)
    local lx = length(x)
    if lx < 1e-6 then return nil end
    x = { x[1] / lx, x[2] / lx, x[3] / lx }
    local z = cross(x, w)
    local lz = length(z)
    if lz < 1e-6 * lx then return nil end
    z = { z[1] / lz, z[2] / lz, z[3] / lz }
    return { x, cross(z, x), z }
end

---@class BodyFrame live = R * file + t for one player
---@field R number[][]
---@field t number[]
---@field worst number the largest miss over the fitted points (a part the file doesn't place right)

---Rigid fit from file to live positions: three spread points (the first, the farthest from it, the farthest
---from that line) give R and t; every point's miss is checked
---@param points { file: number[], live: number[] }[]
---@return BodyFrame?
function BodyParts.fitFrame(points)
    if #points < 3 then return nil end
    local a, b, c = points[1], nil, nil
    local best = -1
    for _, p in ipairs(points) do
        local d = length(sub(p.file, a.file))
        if d > best then b, best = p, d end
    end
    best = -1
    local ab = sub(b.file, a.file)
    for _, p in ipairs(points) do
        local d = length(cross(ab, sub(p.file, a.file)))
        if d > best then c, best = p, d end
    end
    if not b or not c then return nil end
    local F, L = axesOf(a.file, b.file, c.file), axesOf(a.live, b.live, c.live)
    if not F or not L then return nil end
    local R = Mat3.mul(Mat3.transpose(L), F)
    local t = sub(a.live, Mat3.apply(R, a.file))
    local frame = { R = R, t = t, worst = 0 }
    for _, p in ipairs(points) do
        frame.worst = math.max(frame.worst, length(sub(p.live, BodyParts.toWorld(frame, p.file))))
    end
    return frame
end

---@param frame BodyFrame
---@param p number[] player frame
---@return number[] world
function BodyParts.toWorld(frame, p)
    local q = Mat3.apply(frame.R, p)
    return { q[1] + frame.t[1], q[2] + frame.t[2], q[3] + frame.t[3] }
end

---@param frame BodyFrame
---@param w number[] world
---@return number[] player frame
function BodyParts.toFile(frame, w)
    return Mat3.apply(Mat3.transpose(frame.R), sub(w, frame.t))
end

---A world rotation (about the origin) in the player frame: R^T W R
---@param frame BodyFrame
---@param w number[][]
---@return number[][]
function BodyParts.rotationToFile(frame, w)
    return Mat3.mul(Mat3.transpose(frame.R), Mat3.mul(w, frame.R))
end

-- A body with a rot line turns about this joint (probe 2b: every part, each axis, miss 0); groin and feet about
-- their own center. The game puts it at P + M (c - P): c its pos line, P the joint's pos line, M its rot
BodyParts.PIVOTS = {
    head = "neck", breast = "chest", chest = "lumbar", stomach = "abs",
    r_pecs = "r_pecs", r_biceps = "r_shoulder", r_triceps = "r_elbow", r_hand = "r_wrist",
    l_pecs = "l_pecs", l_biceps = "l_shoulder", l_triceps = "l_elbow", l_hand = "l_wrist",
    r_butt = "r_glute", l_butt = "l_glute", r_thigh = "r_hip", l_thigh = "l_hip", r_leg = "r_ankle", l_leg = "l_ankle",
}

---@param r number[]?
---@return boolean
local function turned(r)
    return r ~= nil and (r[1] ~= 0 or r[2] ~= 0 or r[3] ~= 0)
end

---Where the game puts a body (player frame): its pos line turned with its rot about its pivot joint
---@param section BodySection
---@param name string
---@return number[]?
function BodyParts.placed(section, name)
    name = name:lower()
    local c = BodyParts.vector(section, "body", name, "pos")
    local r = BodyParts.vector(section, "body", name, "rot")
    local pivot = BodyParts.PIVOTS[name]
    local P = pivot and BodyParts.vector(section, "joint", pivot, "pos")
    if not c or not P or not turned(r) then return c end
    local q = Mat3.apply(BodyParts.rotMatrix(r --[[@as number[] ]]), sub(c, P))
    return { P[1] + q[1], P[2] + q[2], P[3] + q[3] }
end

---Writes the pos line that makes the game put the body at D with its current rot and pivot: P + M^T (D - P)
---@param section BodySection
---@param name string
---@param D number[] player frame
function BodyParts.setPlaced(section, name, D)
    name = name:lower()
    local r = BodyParts.vector(section, "body", name, "rot")
    local pivot = BodyParts.PIVOTS[name]
    local P = pivot and BodyParts.vector(section, "joint", pivot, "pos")
    local c = D
    if P and turned(r) then
        local q = Mat3.apply(Mat3.transpose(BodyParts.rotMatrix(r --[[@as number[] ]])), sub(D, P))
        c = { P[1] + q[1], P[2] + q[2], P[3] + q[3] }
    end
    BodyParts.setProp(BodyParts.part(section, "body", name, true) --[[@as BodyPart]], "pos",
        MGE.FileHandler.formatNumbers(c[1], c[2], c[3]))
end

-- Joints the game carries with a turned body (the knees: no body's pivot): placed at c' + M (j - c'), c' the
-- body's placed center, M its rot (measured: body_rot_x / _y, body_rot_knee). Other joints stay at their pos line
BodyParts.CARRIED = { r_knee = "r_thigh", l_knee = "l_thigh" }

---Where the game puts a joint (player frame)
---@param section BodySection
---@param joint string
---@return number[]?
function BodyParts.jointPlaced(section, joint)
    joint = joint:lower()
    local j = BodyParts.vector(section, "joint", joint, "pos")
    local body = BodyParts.CARRIED[joint]
    local r = body and BodyParts.vector(section, "body", body, "rot")
    if not j or not turned(r) then return j end
    local c = BodyParts.placed(section, body) --[[@as number[] ]]
    local q = Mat3.apply(BodyParts.rotMatrix(r --[[@as number[] ]]), sub(j, c))
    return { c[1] + q[1], c[2] + q[2], c[3] + q[3] }
end

---Writes the joint's pos line that makes the game put it at K (with its carrying body as it is now)
---@param section BodySection
---@param joint string
---@param K number[] player frame
function BodyParts.setJointPlaced(section, joint, K)
    joint = joint:lower()
    local body = BodyParts.CARRIED[joint]
    local r = body and BodyParts.vector(section, "body", body, "rot")
    local j = K
    if turned(r) then
        local c = BodyParts.placed(section, body) --[[@as number[] ]]
        local q = Mat3.apply(Mat3.transpose(BodyParts.rotMatrix(r --[[@as number[] ]])), sub(K, c))
        j = { c[1] + q[1], c[2] + q[2], c[3] + q[3] }
    end
    BodyParts.setProp(BodyParts.part(section, "joint", joint, true) --[[@as BodyPart]], "pos",
        MGE.FileHandler.formatNumbers(j[1], j[2], j[3]))
end

---The player's frame, fitted from its bodies' live positions against where the file places them (defaults
---for missing lines). Call when the bodies stand where the last load put them (after a reload, before a fight)
---@param player integer 0-based
---@param section BodySection
---@return BodyFrame?
function BodyParts.measureFrame(player, section)
    local points = {}
    for name, id in pairs(BODYPARTS) do
        local file = BodyParts.placed(section, name)
        local ok, info = pcall(get_body_info, player, id)
        if file and ok and info and info.pos then
            points[#points + 1] = { file = file, live = { info.pos.x, info.pos.y, info.pos.z }, name = name }
        end
    end
    table.sort(points, function(p, q) return p.name < q.name end) -- the same three each time
    return BodyParts.fitFrame(points)
end

---------------------------------------------------------------------------------------------------- edits

---The two bodies a joint links (lower case names): the game's answer where it has get_joint_bodies
---@param player integer 0-based
---@param joint string
---@return string[]?
function BodyParts.linkOf(player, joint)
    joint = joint:lower()
    local id = JOINTS and JOINTS[joint:upper()]
    local getBodies = rawget(_G, "get_joint_bodies")
    if getBodies and id then
        local ok, b1, b2 = pcall(getBodies, player, id)
        if ok and b1 and b2 then
            local names = {}
            for name, bid in pairs(BODYPARTS) do names[bid] = name:lower() end
            if names[b1] and names[b2] then return { names[b1], names[b2] } end
        end
    end
    return BodyParts.LINKS[joint]
end

---Joints whose two bodies are both in the set: they move with the parts, the others stay
---@param player integer 0-based
---@param bodies table<string, boolean> lower case body names
---@return string[] joint names, sorted
function BodyParts.jointsBetween(player, bodies)
    local out = {}
    for joint in pairs(BodyParts.DEFAULTS.joint) do
        local link = BodyParts.linkOf(player, joint)
        if link and bodies[link[1]] and bodies[link[2]] then out[#out + 1] = joint end
    end
    table.sort(out)
    return out
end

---@alias BodyPartFns { pos: (fun(p: number[], name: string): number[])?, rot: (fun(r: number[], name: string): number[])?, sides: (fun(s: number[], name: string): number[])? }

---The same edit seen in the mirror: pos and rot mirrored in, edited, mirrored back; sides as they are
---@param fns BodyPartFns
---@param cx number BodyParts.mirrorX
---@return BodyPartFns
local function mirrored(fns, cx)
    local out = { sides = fns.sides }
    if fns.pos then
        out.pos = function(p, name)
            return BodyParts.mirrorPos(fns.pos(BodyParts.mirrorPos(p, cx), name), cx)
        end
    end
    if fns.rot then
        out.rot = function(r, name) return BodyParts.mirrorRot(fns.rot(BodyParts.mirrorRot(r), name)) end
    end
    return out
end

---Rewrites the selected bodies' lines through the functions, player frame: pos moves where the game places
---them (BodyParts.placed) and the joints between moved bodies plus the given joints, rot gets and gives a rot
---line in degrees, sides a body's sides. Missing lines start from the defaults. Pos lines are written last,
---about the pivots where they end up; bodies turning about a moved joint keep their place. With mirrorX, twins
---not selected themselves get the mirrored edit, and so do joints touching a twin
---@param section BodySection
---@param player integer? 0-based (joint links); nil without bodies
---@param bodies string[] body names
---@param fns BodyPartFns
---@param mirrorX number? BodyParts.mirrorX, nil without Mirror
---@param joints string[]? joints moved with fns.pos too (selected ones)
---@return table<string, boolean> joints moved
function BodyParts.transform(section, player, bodies, fns, mirrorX, joints)
    local fmt = MGE.FileHandler.formatNumbers
    local fnsOf, moved = {}, {}
    for _, name in ipairs(bodies) do
        name = name:lower()
        fnsOf[name], moved[name] = fns, true
    end
    local twinFns = mirrorX and mirrored(fns, mirrorX)
    local twinSet = {}
    if twinFns then
        for _, name in ipairs(bodies) do
            local twin = BodyParts.twin(name)
            if twin and not fnsOf[twin] then twinSet[twin] = true end
        end
        for twin in pairs(twinSet) do fnsOf[twin], moved[twin] = twinFns, true end
    end

    -- the joints that move, each with its function
    local jointFn = {}
    if fns.pos then
        if next(moved) then
            for _, joint in ipairs(BodyParts.jointsBetween(player, moved)) do
                local link = BodyParts.linkOf(player, joint) --[[@as string[] ]]
                jointFn[joint] = (twinSet[link[1]] or twinSet[link[2]]) and twinFns.pos or fns.pos
            end
        end
        local selectedJoint = {}
        for _, j in ipairs(joints or {}) do selectedJoint[j:lower()] = true end
        for j in pairs(selectedJoint) do
            jointFn[j] = jointFn[j] or fns.pos
            local twin = twinFns and BodyParts.twin(j)
            if twin and not selectedJoint[twin] and not jointFn[twin] then jointFn[twin] = twinFns.pos end
        end
    end

    -- every target from where things stand now, before any line changes (placements depend on each other)
    local target, writePos = {}, {}
    for name, f in pairs(fnsOf) do
        local D = BodyParts.placed(section, name) or { 0, 0, 0 }
        target[name] = f.pos and f.pos(D, name) or D
        writePos[name] = f.pos ~= nil or f.rot ~= nil
    end
    for body, pivot in pairs(BodyParts.PIVOTS) do -- turning about a moved joint: kept in place
        if jointFn[pivot] then
            target[body] = target[body] or BodyParts.placed(section, body)
            writePos[body] = true
        end
    end
    local jointTarget = {}
    for joint, f in pairs(jointFn) do
        jointTarget[joint] = f(BodyParts.jointPlaced(section, joint) or { 0, 0, 0 }, joint)
    end
    for joint, body in pairs(BodyParts.CARRIED) do -- a knee whose thigh moves or turns: kept in place
        if writePos[body] and not jointTarget[joint] then jointTarget[joint] = BodyParts.jointPlaced(section, joint) end
    end

    -- then the lines: rot and sides, plain joints, bodies about their final pivots, knees about their final thighs
    for name, f in pairs(fnsOf) do
        local part = BodyParts.part(section, "body", name, true) --[[@as BodyPart]]
        if f.rot then
            local r = f.rot(BodyParts.vector(section, "body", name, "rot") or { 0, 0, 0 }, name)
            BodyParts.setProp(part, "rot", fmt(r[1], r[2], r[3]))
        end
        if f.sides then
            local s = f.sides(BodyParts.vector(section, "body", name, "sides") or { 0, 0, 0 }, name)
            BodyParts.setProp(part, "sides", fmt(s[1], s[2], s[3]))
        end
    end
    for joint, K in pairs(jointTarget) do
        if not BodyParts.CARRIED[joint] then BodyParts.setJointPlaced(section, joint, K) end
    end
    for name, D in pairs(target) do
        if writePos[name] then BodyParts.setPlaced(section, name, D) end
    end
    for joint, K in pairs(jointTarget) do
        if BodyParts.CARRIED[joint] then BodyParts.setJointPlaced(section, joint, K) end
    end
    local movedJoints = {}
    for joint in pairs(jointFn) do movedJoints[joint] = true end
    return movedJoints
end

return BodyParts
