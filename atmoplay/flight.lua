-- Drawn flight (docs/atmo-play-plan.md, section 7): a small rigid-body step for props no pool object carries.
-- Pure Lua, no engine calls. Steps as the game does (measured): dt 0.006, v += a dt then pos += v dt; a thrust is a
-- one-step force on its push frames. Boxes touch by their corners (box-box by separating axes), spheres by their
-- center, pills by their two end spheres; contacts are solved with impulses (normal, bounce, Coulomb friction capped
-- by the game's limit). Props meet the ground (z = 0), the static atmo and, with `collide`, each other.
-- All flights step together in atmo order: a fight, its replay and a rebuild give the same numbers.

local NS = ATMOPLAY_LOADING

---@class AtmoPlayThrust
---@field every integer pushes on the steps from frames 0, N, 2N ...
---@field force number[] x y z
---@field space integer 0 world axes, 1 the prop's own

---@class AtmoPlayFlight
---@field vel number[] per second
---@field ang number[] rad/s, world axes
---@field frame integer the frame its prop's pos is at
---@field still integer frames in a row at rest
---@field ax number? rest anchor: pos at its last restless frame (ay, az), rows 1-2 in u1-u3 / w1-w3
---@field rows number[][] rotation, local to world

---@class AtmoPlayFlightWorld
---@field gravity number[]
---@field cellSize number
---@field cells table<integer, AtmoPlayCollider[]>
---@field big AtmoPlayCollider[] colliders over too many cells: always looked at

local Flight = {
    DT = 0.006,
    GRAVITY = { 0, 0, -9.82 },
    MASS = 1, -- without a mass line
    NO_FRICTION = -10000,
    MU = 2, -- Coulomb cone
    LIMIT_SHARE = 0.5, -- the game's friction limit: (friction + 10000) x this N per contact
    ITERATIONS = 8,
    SETTLE = 1e-7, -- an island stops iterating once a round changes its impulses by less (N s)
    BOUNCE_MIN = 0.3, -- slower hits don't bounce
    SLOP = 0.002, -- overlap left alone (no jitter at rest)
    PUSH = 0.8, -- share of the rest of an overlap pushed out each frame
    SIMPLE_SPIN_GRIP = 0.11, -- simple: share of the spin a gripping contact takes a frame
    REST_SPEED = 0.05,
    REST_SPIN = 0.1,
    REST_FRAMES = 10, -- frames at rest that end a flight
    -- also at rest when it stayed this close to its anchor (piles jitter and creep without settling)
    REST_DRIFT = 0.01,
    REST_TURN = 0.03,
    LOWEST = -100, -- fell through the ground: the flight ends
    CELL = 8,
    MAX_CELLS = 64,
    IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0 },
}

local cellKey = NS.Pool.cellKey
local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max

---"<frames> x y z [space]", nil without a push
---@param line string?
---@return AtmoPlayThrust?
function Flight.parseThrust(line)
    if not line then return nil end
    local n = {}
    for v in tostring(line):gmatch("%S+") do n[#n + 1] = tonumber(v) or 0 end
    local every = math.floor(n[1] or 0)
    local force = { n[2] or 0, n[3] or 0, n[4] or 0 }
    if every < 1 or (force[1] == 0 and force[2] == 0 and force[3] == 0) then return nil end
    return { every = every, force = force, space = (n[5] or 0) == 1 and 1 or 0 }
end

---Rebound share of the normal speed (measured: 0.096 x (bounce - 0.48))
function Flight.restitution(bounce)
    return max(0, 0.096 * ((bounce or 0) - 0.48))
end

---Friction impulse cap of one contact a frame: the lower friction of the two sides wins, -10000 is frictionless
---@return number limit
function Flight.frictionLimit(frictionA, frictionB)
    local f = min(frictionA or 0, frictionB or 0)
    if f <= Flight.NO_FRICTION then return 0 end
    return (f + 10000) * Flight.LIMIT_SHARE * Flight.DT
end

---A thrust's force in world axes for a prop turned by `rot` (MatrixTB)
function Flight.thrustWorld(thrust, rot)
    local f = thrust.force
    if thrust.space ~= 1 or not rot then return f[1], f[2], f[3] end
    return rot.r0 * f[1] + rot.r1 * f[2] + rot.r2 * f[3],
        rot.r4 * f[1] + rot.r5 * f[2] + rot.r6 * f[3],
        rot.r8 * f[1] + rot.r9 * f[2] + rot.r10 * f[3]
end

---Whether the step from `frame` pushes (into frames 1, N + 1 ...)
function Flight.pushes(thrust, frame)
    return frame % thrust.every == 0
end

---A gamerule gravity string, nil when it isn't three numbers
function Flight.parseGravity(text)
    local n = {}
    for v in tostring(text or ""):gmatch("%S+") do n[#n + 1] = tonumber(v) end
    if #n == 3 and n[1] and n[2] and n[3] then return n end
    return nil
end

---------------------------------------------------------------------------------------------------- shapes

---The points a shape touches by, local: { x, y, z, radius }
local function localPoints(shape, sides)
    if shape == "sphere" then return { { 0, 0, 0, sides[1] } } end
    if shape == "cylinder" then
        local half = sides[2] / 2
        return { { 0, 0, -half, sides[1] }, { 0, 0, half, sides[1] } }
    end
    local hx, hy, hz = sides[1] / 2, sides[2] / 2, sides[3] / 2
    local out = {}
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            for _, sz in ipairs({ -1, 1 }) do out[#out + 1] = { sx * hx, sy * hy, sz * hz, 0 } end
        end
    end
    return out
end

---Local points moved to pos and turned by rows m, written into `out` (its tables reused)
local function worldPointsInto(pos, pts, m, out)
    local px, py, pz = pos[1], pos[2], pos[3]
    local m11, m12, m13, m21, m22, m23, m31, m32, m33 =
        m[1][1], m[1][2], m[1][3], m[2][1], m[2][2], m[2][3], m[3][1], m[3][2], m[3][3]
    for i = 1, #pts do
        local l = pts[i]
        local q = out[i]
        if not q then
            q = {}
            out[i] = q
        end
        local lx, ly, lz = l[1], l[2], l[3]
        q[1] = px + m11 * lx + m12 * ly + m13 * lz
        q[2] = py + m21 * lx + m22 * ly + m23 * lz
        q[3] = pz + m31 * lx + m32 * ly + m33 * lz
        q[4] = l[4]
    end
    for i = #pts + 1, #out do out[i] = nil end
    return out
end

---Inverse inertia in the shape's own axes
local function inverseInertia(shape, sides, mass)
    if shape == "sphere" then
        local i = 0.4 * mass * sides[1] ^ 2
        return { 1 / i, 1 / i, 1 / i }
    elseif shape == "cylinder" then
        -- ODE's capsule: a cylinder and two half spheres, the mass shared by volume
        local r, l = sides[1], sides[2]
        local m1, m2 = math.pi * r * r * l, 4 / 3 * math.pi * r ^ 3
        local k = mass / (m1 + m2)
        local along = k * (m1 * 0.5 * r * r + m2 * 0.4 * r * r)
        local across = k * (m1 * (0.25 * r * r + l * l / 12) + m2 * (0.4 * r * r + 0.375 * r * l + 0.25 * l * l))
        return { 1 / across, 1 / across, 1 / along }
    end
    local x, y, z = sides[1], sides[2], sides[3]
    local k = mass / 12
    return { 1 / (k * (y * y + z * z)), 1 / (k * (x * x + z * z)), 1 / (k * (x * x + y * y)) }
end

---The sphere a prop flies as on the simple level: its smallest half side, a sphere's or pill's radius
local function radiusOf(prop)
    local s = prop.sides
    if prop.shape == "sphere" or prop.shape == "cylinder" then return s[1] end
    return min(s[1], s[2], s[3]) / 2
end

---A prop's body for a level (made once each, set as prop.body): touching shape, points, mass, inertia
---@param simple boolean? a sphere that hits don't turn
local function bodyOf(prop, simple)
    local cache = prop.bodies
    if not cache then
        cache = {}
        prop.bodies = cache
    end
    local key = simple and "simple" or "shapes"
    local b = cache[key]
    if not b then
        -- flightMass: the game's own mass for a prop without a mass line (dynamics.lua)
        local mass = prop.flightMass or prop.mass or Flight.MASS
        if mass <= 0 then mass = Flight.MASS end
        if simple then
            local r = radiusOf(prop)
            b = { shape = "sphere", sides = { r, r, r }, points = { { 0, 0, 0, r } }, invMass = 1 / mass, mass = mass,
                invI = { 0, 0, 0 } }
        else
            b = { shape = prop.shape, sides = prop.sides, points = localPoints(prop.shape, prop.sides),
                invMass = 1 / mass, mass = mass, invI = inverseInertia(prop.shape, prop.sides, mass) }
        end
        cache[key] = b
    end
    prop.body = b
    return b
end
Flight.bodyOf = bodyOf

---MatrixTB as rows
local function rowsOf(m)
    return { { m.r0, m.r1, m.r2 }, { m.r4, m.r5, m.r6 }, { m.r8, m.r9, m.r10 } }
end

---Gram-Schmidt on the columns, in place (steps add up rounding)
local function orthonormalize(m)
    local ax, ay, az = m[1][1], m[2][1], m[3][1]
    local n = sqrt(ax * ax + ay * ay + az * az)
    ax, ay, az = ax / n, ay / n, az / n
    local bx, by, bz = m[1][2], m[2][2], m[3][2]
    local d = ax * bx + ay * by + az * bz
    bx, by, bz = bx - d * ax, by - d * ay, bz - d * az
    n = sqrt(bx * bx + by * by + bz * bz)
    bx, by, bz = bx / n, by / n, bz / n
    m[1][1], m[2][1], m[3][1] = ax, ay, az
    m[1][2], m[2][2], m[3][2] = bx, by, bz
    m[1][3], m[2][3], m[3][3] = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

---Rows m turned by angular velocity w for dt (Rodrigues), in place
local function turn(m, wx, wy, wz, dt)
    local w = sqrt(wx * wx + wy * wy + wz * wz)
    if w < 1e-12 then return end
    local kx, ky, kz = wx / w, wy / w, wz / w
    local c, s = math.cos(w * dt), math.sin(w * dt)
    local t = 1 - c
    local q11, q12, q13 = t * kx * kx + c, t * kx * ky - s * kz, t * kx * kz + s * ky
    local q21, q22, q23 = t * kx * ky + s * kz, t * ky * ky + c, t * ky * kz - s * kx
    local q31, q32, q33 = t * kx * kz - s * ky, t * ky * kz + s * kx, t * kz * kz + c
    for j = 1, 3 do
        local a, b, d = m[1][j], m[2][j], m[3][j]
        m[1][j], m[2][j], m[3][j] = q11 * a + q12 * b + q13 * d, q21 * a + q22 * b + q23 * d, q31 * a + q32 * b + q33 * d
    end
end

---A point against a shape at pos with rows f: its distance out of the surface (negative inside) and the way out
---@return number distance, number nx, number ny, number nz
local function surfaceAt(shape, sides, pos, f, x, y, z)
    local dx, dy, dz = x - pos[1], y - pos[2], z - pos[3]
    if shape == "sphere" then
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < 1e-9 then return -sides[1], 0, 0, 1 end
        return d - sides[1], dx / d, dy / d, dz / d
    end
    local lx = dx * f[1][1] + dy * f[2][1] + dz * f[3][1]
    local ly = dx * f[1][2] + dy * f[2][2] + dz * f[3][2]
    local lz = dx * f[1][3] + dy * f[2][3] + dz * f[3][3]
    local ox, oy, oz, d
    if shape == "cylinder" then
        local half = sides[2] / 2
        local qz = max(-half, min(half, lz))
        local ex, ey, ez = lx, ly, lz - qz
        local len = sqrt(ex * ex + ey * ey + ez * ez)
        if len < 1e-9 then
            ox, oy, oz, d = 0, 0, 1, -sides[1]
        else
            ox, oy, oz, d = ex / len, ey / len, ez / len, len - sides[1]
        end
    else
        local hx, hy, hz = sides[1] / 2, sides[2] / 2, sides[3] / 2
        local qx, qy, qz = max(-hx, min(hx, lx)), max(-hy, min(hy, ly)), max(-hz, min(hz, lz))
        local ex, ey, ez = lx - qx, ly - qy, lz - qz
        local len = sqrt(ex * ex + ey * ey + ez * ez)
        if len > 1e-9 then
            ox, oy, oz, d = ex / len, ey / len, ez / len, len
        else -- inside: out through the nearest face
            local px, py, pz = hx - abs(lx), hy - abs(ly), hz - abs(lz)
            if px <= py and px <= pz then
                ox, oy, oz, d = lx < 0 and -1 or 1, 0, 0, -px
            elseif py <= pz then
                ox, oy, oz, d = 0, ly < 0 and -1 or 1, 0, -py
            else
                ox, oy, oz, d = 0, 0, lz < 0 and -1 or 1, -pz
            end
        end
    end
    return d, f[1][1] * ox + f[1][2] * oy + f[1][3] * oz, f[2][1] * ox + f[2][2] * oy + f[2][3] * oz,
        f[3][1] * ox + f[3][2] * oy + f[3][3] * oz
end

---@param c AtmoPlayCollider
function Flight.surface(c, x, y, z)
    return surfaceAt(c.shape, c.sides, c.pos, c.frame, x, y, z)
end

---------------------------------------------------------------------------------------------------- box against box

-- Separating axes, Gottschalk's way: R_ij = |A_i . B_j| once, then each of the 15 axes is a few products (the axes
-- are orthonormal). Upvalues hold the pair being tested: no tables or closures a call
local A1x, A1y, A1z, A2x, A2y, A2z, A3x, A3y, A3z
local B1x, B1y, B1z, B2x, B2y, B2z, B3x, B3y, B3z
local hA1, hA2, hA3, hB1, hB2, hB3, Dx, Dy, Dz
local R11, R12, R13, R21, R22, R23, R31, R32, R33
local best, Nx, Ny, Nz -- least overlap so far and its normal (out of B, toward A)
local edgeBias -- edge axes win only when clearly better (faces give steadier contacts)

---A face axis (unit l): r both boxes' reach along it, dist the centers' gap
local function faceAxis(r, dist, lx, ly, lz)
    local over = r - abs(dist)
    if over < 0 then return false end
    if over < best then
        best = over
        if dist > 0 then Nx, Ny, Nz = -lx, -ly, -lz else Nx, Ny, Nz = lx, ly, lz end
    end
    return true
end

---An edge axis l = A_i x B_j (not unit), r the reach scaled by its length
local function edgeAxis(lx, ly, lz, r)
    local len = sqrt(lx * lx + ly * ly + lz * lz)
    if len < 1e-6 then return true end
    local dist = (Dx * lx + Dy * ly + Dz * lz) / len
    local over = r / len - abs(dist)
    if over < 0 then return false end
    if over < (edgeBias and best * 0.95 - 1e-4 or best) then
        best = over
        if dist > 0 then Nx, Ny, Nz = -lx / len, -ly / len, -lz / len else Nx, Ny, Nz = lx / len, ly / len, lz / len end
    end
    return true
end

---Loads a pair (rows fa / fb, sides, positions) and tries all 15 axes: false when apart, else `best` and N are set
local function separate(fa, fb, sa, sb, pa, pb, bias)
    A1x, A1y, A1z, A2x, A2y, A2z, A3x, A3y, A3z =
        fa[1][1], fa[2][1], fa[3][1], fa[1][2], fa[2][2], fa[3][2], fa[1][3], fa[2][3], fa[3][3]
    B1x, B1y, B1z, B2x, B2y, B2z, B3x, B3y, B3z =
        fb[1][1], fb[2][1], fb[3][1], fb[1][2], fb[2][2], fb[3][2], fb[1][3], fb[2][3], fb[3][3]
    hA1, hA2, hA3, hB1, hB2, hB3 = sa[1] / 2, sa[2] / 2, sa[3] / 2, sb[1] / 2, sb[2] / 2, sb[3] / 2
    Dx, Dy, Dz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
    best, Nx, Ny, Nz, edgeBias = math.huge, 0, 0, 1, bias
    R11 = abs(A1x * B1x + A1y * B1y + A1z * B1z)
    R12 = abs(A1x * B2x + A1y * B2y + A1z * B2z)
    R13 = abs(A1x * B3x + A1y * B3y + A1z * B3z)
    R21 = abs(A2x * B1x + A2y * B1y + A2z * B1z)
    R22 = abs(A2x * B2x + A2y * B2y + A2z * B2z)
    R23 = abs(A2x * B3x + A2y * B3y + A2z * B3z)
    R31 = abs(A3x * B1x + A3y * B1y + A3z * B1z)
    R32 = abs(A3x * B2x + A3y * B2y + A3z * B2z)
    R33 = abs(A3x * B3x + A3y * B3y + A3z * B3z)
    -- faces, A_i then B_i (this order decides ties)
    return faceAxis(hA1 + hB1 * R11 + hB2 * R12 + hB3 * R13, Dx * A1x + Dy * A1y + Dz * A1z, A1x, A1y, A1z)
        and faceAxis(hA1 * R11 + hA2 * R21 + hA3 * R31 + hB1, Dx * B1x + Dy * B1y + Dz * B1z, B1x, B1y, B1z)
        and faceAxis(hA2 + hB1 * R21 + hB2 * R22 + hB3 * R23, Dx * A2x + Dy * A2y + Dz * A2z, A2x, A2y, A2z)
        and faceAxis(hA1 * R12 + hA2 * R22 + hA3 * R32 + hB2, Dx * B2x + Dy * B2y + Dz * B2z, B2x, B2y, B2z)
        and faceAxis(hA3 + hB1 * R31 + hB2 * R32 + hB3 * R33, Dx * A3x + Dy * A3y + Dz * A3z, A3x, A3y, A3z)
        and faceAxis(hA1 * R13 + hA2 * R23 + hA3 * R33 + hB3, Dx * B3x + Dy * B3y + Dz * B3z, B3x, B3y, B3z)
        -- edges A_i x B_j: A reaches over its other two axes, B over its other two
        and edgeAxis(A1y * B1z - A1z * B1y, A1z * B1x - A1x * B1z, A1x * B1y - A1y * B1x,
            hA2 * R31 + hA3 * R21 + hB2 * R13 + hB3 * R12)
        and edgeAxis(A1y * B2z - A1z * B2y, A1z * B2x - A1x * B2z, A1x * B2y - A1y * B2x,
            hA2 * R32 + hA3 * R22 + hB1 * R13 + hB3 * R11)
        and edgeAxis(A1y * B3z - A1z * B3y, A1z * B3x - A1x * B3z, A1x * B3y - A1y * B3x,
            hA2 * R33 + hA3 * R23 + hB1 * R12 + hB2 * R11)
        and edgeAxis(A2y * B1z - A2z * B1y, A2z * B1x - A2x * B1z, A2x * B1y - A2y * B1x,
            hA1 * R31 + hA3 * R11 + hB2 * R23 + hB3 * R22)
        and edgeAxis(A2y * B2z - A2z * B2y, A2z * B2x - A2x * B2z, A2x * B2y - A2y * B2x,
            hA1 * R32 + hA3 * R12 + hB1 * R23 + hB3 * R21)
        and edgeAxis(A2y * B3z - A2z * B3y, A2z * B3x - A2x * B3z, A2x * B3y - A2y * B3x,
            hA1 * R33 + hA3 * R13 + hB1 * R22 + hB2 * R21)
        and edgeAxis(A3y * B1z - A3z * B1y, A3z * B1x - A3x * B1z, A3x * B1y - A3y * B1x,
            hA1 * R21 + hA2 * R11 + hB2 * R33 + hB3 * R32)
        and edgeAxis(A3y * B2z - A3z * B2y, A3z * B2x - A3x * B2z, A3x * B2y - A3y * B2x,
            hA1 * R22 + hA2 * R12 + hB1 * R33 + hB3 * R31)
        and edgeAxis(A3y * B3z - A3z * B3y, A3z * B3x - A3x * B3z, A3x * B3y - A3y * B3x,
            hA1 * R23 + hA2 * R13 + hB1 * R32 + hB2 * R31)
end

local OVERLAP_MARGIN = 0.01 -- deeper than this: overlapping (touching faces aren't)

---Whether two shapes (shape, sides, pos, frame) overlap. Props overlapping where the map places them never push
---each other apart (dynamics.lua: prop.ignore)
---@return boolean
function Flight.overlap(a, b)
    local dx, dy, dz = b.pos[1] - a.pos[1], b.pos[2] - a.pos[2], b.pos[3] - a.pos[3]
    local reach = (a.radius or 0) + (b.radius or 0)
    if dx * dx + dy * dy + dz * dz > reach * reach then return false end
    if a.shape == "box" and b.shape == "box" then
        return separate(a.frame, b.frame, a.sides, b.sides, a.pos, b.pos, false) and best > OVERLAP_MARGIN
    end
    local function into(x, y)
        local p = x.pos
        if surfaceAt(y.shape, y.sides, y.pos, y.frame, p[1], p[2], p[3]) < -OVERLAP_MARGIN then return true end
        for _, q in ipairs(worldPointsInto(p, localPoints(x.shape, x.sides), x.frame, {})) do
            if surfaceAt(y.shape, y.sides, y.pos, y.frame, q[1], q[2], q[3]) < q[4] - OVERLAP_MARGIN then return true end
        end
        return false
    end
    return into(a, b) or into(b, a)
end

---------------------------------------------------------------------------------------------------- the world

---The static atmo by x / y cell; each collider gets its touch points in world axes
---@param colliders AtmoPlayCollider[]?
---@param gravity number[]?
---@return AtmoPlayFlightWorld
function Flight.newWorld(colliders, gravity)
    local w = { gravity = gravity or Flight.GRAVITY, cellSize = Flight.CELL, cells = {}, big = {},
        empty = colliders == nil or #colliders == 0 }
    for _, c in ipairs(colliders or {}) do
        c.points = c.points or worldPointsInto(c.pos, localPoints(c.shape, c.sides), c.frame, {})
        local r = c.radius
        local x0, x1 = math.floor((c.pos[1] - r) / w.cellSize), math.floor((c.pos[1] + r) / w.cellSize)
        local y0, y1 = math.floor((c.pos[2] - r) / w.cellSize), math.floor((c.pos[2] + r) / w.cellSize)
        if (x1 - x0 + 1) * (y1 - y0 + 1) > Flight.MAX_CELLS then
            w.big[#w.big + 1] = c
        else
            for x = x0, x1 do
                for y = y0, y1 do
                    local key = cellKey(x, y)
                    local list = w.cells[key]
                    if not list then
                        list = {}
                        w.cells[key] = list
                    end
                    list[#list + 1] = c
                end
            end
        end
    end
    return w
end

local stamp = 0

---Adds to out[n + 1 ...] the colliders of `list` reaching a sphere at p of radius r, each once a call (stamped)
local function reaching(list, px, py, pz, r, out, n)
    for k = 1, #list do
        local c = list[k]
        if c.flightStamp ~= stamp then
            c.flightStamp = stamp
            local q = c.pos
            local dx, dy, dz = q[1] - px, q[2] - py, q[3] - pz
            local reach = c.radius + r
            if dx * dx + dy * dy + dz * dz <= reach * reach then
                n = n + 1
                out[n] = c
            end
        end
    end
    return n
end

---Writes into `out` the static colliders whose bounding spheres reach a sphere at p of radius r; returns how many
local function nearby(w, p, r, out)
    if w.empty then
        for i = 1, #out do out[i] = nil end
        return 0
    end
    stamp = stamp + 1
    local px, py, pz = p[1], p[2], p[3]
    local n = reaching(w.big, px, py, pz, r, out, 0)
    local size, cells = w.cellSize, w.cells
    for cx = math.floor((px - r) / size), math.floor((px + r) / size) do
        for cy = math.floor((py - r) / size), math.floor((py + r) / size) do
            local list = cells[cellKey(cx, cy)]
            if list then n = reaching(list, px, py, pz, r, out, n) end
        end
    end
    for i = n + 1, #out do out[i] = nil end
    return n
end

---------------------------------------------------------------------------------------------------- contacts

-- Pooled contacts: a (flying prop), b (another flying prop or false), other (b or the static collider: bounce and
-- friction), point p, normal n (out of b toward a), depth, tangents t1 t2, impulses so far. Empty fields hold false,
-- never nil: a key set to nil is dropped by a collection, and setting it again can rebuild the table
local pool, used = {}, 0
local coupledList = {}

local function addContact(a, b, px, py, pz, nx, ny, nz, depth, other)
    used = used + 1
    local c = pool[used]
    if not c then
        c = {}
        pool[used] = c
    end
    c.a, c.b, c.other = a, b or false, other or false
    c.px, c.py, c.pz, c.nx, c.ny, c.nz, c.depth = px, py, pz, nx, ny, nz, depth
    local ax, ay, az -- t1 = a x n, t2 = n x t1
    if abs(nx) < 0.6 then ax, ay, az = 1, 0, 0 else ax, ay, az = 0, 1, 0 end
    local t1x, t1y, t1z = ay * nz - az * ny, az * nx - ax * nz, ax * ny - ay * nx
    local l = sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
    t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
    c.t1x, c.t1y, c.t1z = t1x, t1y, t1z
    c.t2x, c.t2y, c.t2z = ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
    c.jn, c.jt1, c.jt2 = 0, 0, 0
end

local AXIS_TOL = 1e-4 -- a corner this close to a box's side counts as inside (flush faces)

---Box A against box B: contacts at each box's corners inside the other along the least-overlap axis, or one point
---between the two when only edges cross
local function boxBox(A, fa, ptsA, B, fb, ptsB, bodyB, other)
    local pa, pb = A.pos, B.pos
    if not separate(fa, fb, A.sides, B.sides, pa, pb, true) then return end
    local nx, ny, nz = Nx, Ny, Nz
    local ra = hA1 * abs(A1x * nx + A1y * ny + A1z * nz) + hA2 * abs(A2x * nx + A2y * ny + A2z * nz)
        + hA3 * abs(A3x * nx + A3y * ny + A3z * nz)
    local rb = hB1 * abs(B1x * nx + B1y * ny + B1z * nz) + hB2 * abs(B2x * nx + B2y * ny + B2z * nz)
        + hB3 * abs(B3x * nx + B3y * ny + B3z * nz)
    local topB = pb[1] * nx + pb[2] * ny + pb[3] * nz + rb -- B's side facing A
    local bottomA = pa[1] * nx + pa[2] * ny + pa[3] * nz - ra -- A's side facing B
    local before = used
    local bx, by, bz, ax, ay, az = pb[1], pb[2], pb[3], pa[1], pa[2], pa[3]
    for k = 1, #ptsA do
        local q = ptsA[k]
        local qx, qy, qz = q[1], q[2], q[3]
        local depth = topB - (qx * nx + qy * ny + qz * nz)
        if depth > 0 then
            local rx, ry, rz = qx - bx, qy - by, qz - bz
            if abs(rx * B1x + ry * B1y + rz * B1z) <= hB1 + AXIS_TOL and abs(rx * B2x + ry * B2y + rz * B2z) <= hB2 + AXIS_TOL
                and abs(rx * B3x + ry * B3y + rz * B3z) <= hB3 + AXIS_TOL then
                addContact(A, bodyB, qx, qy, qz, nx, ny, nz, depth, other)
            end
        end
    end
    for k = 1, #ptsB do
        local q = ptsB[k]
        local qx, qy, qz = q[1], q[2], q[3]
        local depth = (qx * nx + qy * ny + qz * nz) - bottomA
        if depth > 0 then
            local rx, ry, rz = qx - ax, qy - ay, qz - az
            if abs(rx * A1x + ry * A1y + rz * A1z) <= hA1 + AXIS_TOL and abs(rx * A2x + ry * A2y + rz * A2z) <= hA2 + AXIS_TOL
                and abs(rx * A3x + ry * A3y + rz * A3z) <= hA3 + AXIS_TOL then
                addContact(A, bodyB, qx, qy, qz, nx, ny, nz, depth, other)
            end
        end
    end
    if used == before then -- edges crossing: between the two boxes' nearest corners along n
        local k1 = (A1x * -nx + A1y * -ny + A1z * -nz) >= 0 and hA1 or -hA1
        local k2 = (A2x * -nx + A2y * -ny + A2z * -nz) >= 0 and hA2 or -hA2
        local k3 = (A3x * -nx + A3y * -ny + A3z * -nz) >= 0 and hA3 or -hA3
        local px = ax + A1x * k1 + A2x * k2 + A3x * k3
        local py = ay + A1y * k1 + A2y * k2 + A3y * k3
        local pz = az + A1z * k1 + A2z * k2 + A3z * k3
        k1 = (B1x * nx + B1y * ny + B1z * nz) >= 0 and hB1 or -hB1
        k2 = (B2x * nx + B2y * ny + B2z * nz) >= 0 and hB2 or -hB2
        k3 = (B3x * nx + B3y * ny + B3z * nz) >= 0 and hB3 or -hB3
        local qx = bx + B1x * k1 + B2x * k2 + B3x * k3
        local qy = by + B1y * k1 + B2y * k2 + B3y * k3
        local qz = bz + B1z * k1 + B2z * k2 + B3z * k3
        addContact(A, bodyB, (px + qx) / 2, (py + qy) / 2, (pz + qz) / 2, nx, ny, nz, best, other)
    end
end

---Contacts between flying prop A and shape B (static collider, or flying prop bodyB), A's points against B's
---surface and B's against A's. A touches as its body's shape (a sphere on the simple level)
local function pairContacts(A, ptsA, B, f, ptsB, bodyB, other)
    local fa, shapeA, sidesA = A.flight.rows, A.body.shape, A.body.sides
    local shapeB, sidesB = B.shape, B.sides
    if bodyB then shapeB, sidesB = bodyB.body.shape, bodyB.body.sides end
    if shapeA == "box" and shapeB == "box" then return boxBox(A, fa, ptsA, B, f, ptsB, bodyB, other) end
    local pa, pb = A.pos, B.pos
    for k = 1, #ptsA do
        local q = ptsA[k]
        local d, nx, ny, nz = surfaceAt(shapeB, sidesB, pb, f, q[1], q[2], q[3])
        if d < q[4] then
            addContact(A, bodyB, q[1] - nx * q[4], q[2] - ny * q[4], q[3] - nz * q[4], nx, ny, nz, q[4] - d, other)
        end
    end
    for k = 1, #ptsB do
        local q = ptsB[k]
        local d, nx, ny, nz = surfaceAt(shapeA, sidesA, pa, fa, q[1], q[2], q[3])
        if d < q[4] then addContact(A, bodyB, q[1], q[2], q[3], -nx, -ny, -nz, q[4] - d, other) end
    end
end

---------------------------------------------------------------------------------------------------- solving

-- Touch points and world inertia are worked out once a step, only for props something touches
local stepStamp = 0

---Inverse inertia in world axes (R diag(invI) R^T, 9 numbers by rows)
local function worldInertia(fl, b)
    local m, i = fl.rows, b.invI
    local iw = fl.iw
    if not iw then
        iw = {}
        fl.iw = iw
    end
    local i1, i2, i3 = i[1], i[2], i[3]
    if i1 == i2 and i2 == i3 then -- isotropic: any rotation keeps it
        iw[1], iw[2], iw[3], iw[4], iw[5], iw[6], iw[7], iw[8], iw[9] = i1, 0, 0, 0, i1, 0, 0, 0, i1
        return
    end
    for r = 1, 3 do
        local mr = m[r]
        local a1, a2, a3 = mr[1] * i1, mr[2] * i2, mr[3] * i3
        for c = 1, 3 do
            local mc = m[c]
            iw[(r - 1) * 3 + c] = a1 * mc[1] + a2 * mc[2] + a3 * mc[3]
        end
    end
end

local function ptsOf(prop)
    local fl = prop.flight
    if fl.ptsAt ~= stepStamp then
        fl.pts = worldPointsInto(prop.pos, prop.body.points, fl.rows, fl.pts or {})
        fl.ptsAt = stepStamp
    end
    return fl.pts
end

local function inertiaOf(prop)
    local fl = prop.flight
    if fl.iwAt ~= stepStamp then
        worldInertia(fl, prop.body)
        fl.iwAt = stepStamp
    end
end

---A body's lever along d at a contact (r from its center): r x d, the spin a unit impulse gives (I^-1 (r x d)) and
---its resistance (1 / effective mass)
local function lever(prop, rx, ry, rz, dx, dy, dz)
    local i = prop.flight.iw
    local cx, cy, cz = ry * dz - rz * dy, rz * dx - rx * dz, rx * dy - ry * dx
    local ix = i[1] * cx + i[2] * cy + i[3] * cz
    local iy = i[4] * cx + i[5] * cy + i[6] * cz
    local iz = i[7] * cx + i[8] * cy + i[9] * cz
    return cx, cy, cz, ix, iy, iz, prop.body.invMass + cx * ix + cy * iy + cz * iz
end

---A contact's constants for this step's rounds: velocity tables, levers along n, t1, t2 (a: a*, ai*; b: b*, bi*),
---resistances, bounce target and friction cap
local function prepare(c)
    local a, b, px, py, pz = c.a, c.b, c.px, c.py, c.pz
    local nx, ny, nz, t1x, t1y, t1z, t2x, t2y, t2z = c.nx, c.ny, c.nz, c.t1x, c.t1y, c.t1z, c.t2x, c.t2y, c.t2z
    inertiaOf(a)
    local fa, q = a.flight, a.pos
    local va, wa = fa.vel, fa.ang
    c.va, c.wa, c.ima = va, wa, a.body.invMass
    local rx, ry, rz = px - q[1], py - q[2], pz - q[3]
    local kn, kt1, kt2
    c.anx, c.any, c.anz, c.ainx, c.ainy, c.ainz, kn = lever(a, rx, ry, rz, nx, ny, nz)
    c.a1x, c.a1y, c.a1z, c.ai1x, c.ai1y, c.ai1z, kt1 = lever(a, rx, ry, rz, t1x, t1y, t1z)
    c.a2x, c.a2y, c.a2z, c.ai2x, c.ai2y, c.ai2z, kt2 = lever(a, rx, ry, rz, t2x, t2y, t2z)
    local vn = nx * va[1] + ny * va[2] + nz * va[3] + c.anx * wa[1] + c.any * wa[2] + c.anz * wa[3]
    if b then
        inertiaOf(b)
        local fb = b.flight
        local vb, wb = fb.vel, fb.ang
        q = b.pos
        c.vb, c.wb, c.imb = vb, wb, b.body.invMass
        rx, ry, rz = px - q[1], py - q[2], pz - q[3]
        local k
        c.bnx, c.bny, c.bnz, c.binx, c.biny, c.binz, k = lever(b, rx, ry, rz, nx, ny, nz)
        kn = kn + k
        c.b1x, c.b1y, c.b1z, c.bi1x, c.bi1y, c.bi1z, k = lever(b, rx, ry, rz, t1x, t1y, t1z)
        kt1 = kt1 + k
        c.b2x, c.b2y, c.b2z, c.bi2x, c.bi2y, c.bi2z, k = lever(b, rx, ry, rz, t2x, t2y, t2z)
        kt2 = kt2 + k
        vn = vn - (nx * vb[1] + ny * vb[2] + nz * vb[3] + c.bnx * wb[1] + c.bny * wb[2] + c.bnz * wb[3])
    else
        c.vb, c.wb = false, false
    end
    c.kn, c.kt1, c.kt2 = kn, kt1, kt2
    local o = c.other
    local e = Flight.restitution(max(a.bounce or 0, o and o.bounce or 0))
    c.bias = vn < -Flight.BOUNCE_MIN and -e * vn or 0
    c.limit = Flight.frictionLimit(a.friction, o and o.friction)
end

---One round on a contact: normal impulse, then friction; returns how much it changed
local function solve(c)
    local va, wa, vb, wb = c.va, c.wa, c.vb, c.wb
    local nx, ny, nz = c.nx, c.ny, c.nz
    local va1, va2, va3, wa1, wa2, wa3 = va[1], va[2], va[3], wa[1], wa[2], wa[3]
    local vb1, vb2, vb3, wb1, wb2, wb3
    local vn = nx * va1 + ny * va2 + nz * va3 + c.anx * wa1 + c.any * wa2 + c.anz * wa3
    if vb then
        vb1, vb2, vb3, wb1, wb2, wb3 = vb[1], vb[2], vb[3], wb[1], wb[2], wb[3]
        vn = vn - (nx * vb1 + ny * vb2 + nz * vb3 + c.bnx * wb1 + c.bny * wb2 + c.bnz * wb3)
    end
    local dj = (c.bias - vn) / c.kn
    local old = c.jn
    local jn = old + dj
    if jn < 0 then jn = 0 end
    c.jn = jn
    dj = jn - old
    if dj ~= 0 then
        local k = dj * c.ima
        va1, va2, va3 = va1 + nx * k, va2 + ny * k, va3 + nz * k
        wa1, wa2, wa3 = wa1 + c.ainx * dj, wa2 + c.ainy * dj, wa3 + c.ainz * dj
        if vb then
            k = dj * c.imb
            vb1, vb2, vb3 = vb1 - nx * k, vb2 - ny * k, vb3 - nz * k
            wb1, wb2, wb3 = wb1 - c.binx * dj, wb2 - c.biny * dj, wb3 - c.binz * dj
        end
    end
    local cap = Flight.MU * jn
    local limit = c.limit
    if limit and limit < cap then cap = limit end
    local t1x, t1y, t1z, t2x, t2y, t2z = c.t1x, c.t1y, c.t1z, c.t2x, c.t2y, c.t2z
    local u1 = t1x * va1 + t1y * va2 + t1z * va3 + c.a1x * wa1 + c.a1y * wa2 + c.a1z * wa3
    local u2 = t2x * va1 + t2y * va2 + t2z * va3 + c.a2x * wa1 + c.a2y * wa2 + c.a2z * wa3
    if vb then
        u1 = u1 - (t1x * vb1 + t1y * vb2 + t1z * vb3 + c.b1x * wb1 + c.b1y * wb2 + c.b1z * wb3)
        u2 = u2 - (t2x * vb1 + t2y * vb2 + t2z * vb3 + c.b2x * wb1 + c.b2y * wb2 + c.b2z * wb3)
    end
    local o1, o2 = c.jt1, c.jt2
    local j1, j2 = o1 - u1 / c.kt1, o2 - u2 / c.kt2
    local len = sqrt(j1 * j1 + j2 * j2)
    if len > cap then
        local k = cap > 0 and cap / len or 0
        j1, j2 = j1 * k, j2 * k
    end
    c.jt1, c.jt2 = j1, j2
    local d1, d2 = j1 - o1, j2 - o2
    if d1 ~= 0 or d2 ~= 0 then
        local jx, jy, jz = t1x * d1 + t2x * d2, t1y * d1 + t2y * d2, t1z * d1 + t2z * d2
        local k = c.ima
        va1, va2, va3 = va1 + jx * k, va2 + jy * k, va3 + jz * k
        wa1 = wa1 + c.ai1x * d1 + c.ai2x * d2
        wa2 = wa2 + c.ai1y * d1 + c.ai2y * d2
        wa3 = wa3 + c.ai1z * d1 + c.ai2z * d2
        if vb then
            k = c.imb
            vb1, vb2, vb3 = vb1 - jx * k, vb2 - jy * k, vb3 - jz * k
            wb1 = wb1 - c.bi1x * d1 - c.bi2x * d2
            wb2 = wb2 - c.bi1y * d1 - c.bi2y * d2
            wb3 = wb3 - c.bi1z * d1 - c.bi2z * d2
        end
    elseif dj == 0 then
        return 0
    end
    va[1], va[2], va[3], wa[1], wa[2], wa[3] = va1, va2, va3, wa1, wa2, wa3
    if vb then vb[1], vb[2], vb[3], wb[1], wb[2], wb[3] = vb1, vb2, vb3, wb1, wb2, wb3 end
    return abs(dj) + abs(d1) + abs(d2)
end

-- Islands: props joined by contacts with each other (a ground or static contact joins nothing). Each island's rounds
-- stop on its own, so a busy pile elsewhere doesn't change its numbers
local islandOrder, islandStarts, islandOf, islandNext = {}, {}, {}, {}

---Union-find on the flights (fields stamped by this step)
local function rootOf(fl)
    if fl.ufAt ~= stepStamp then
        fl.ufAt, fl.uf = stepStamp, fl
        return fl
    end
    local r = fl
    while r.uf ~= r do
        r.uf = r.uf.uf
        r = r.uf
    end
    return r
end

---The contacts grouped by island into islandOrder, keeping their order within each
---@return integer[] starts each island's first slot (starts[count + 1]: one past the last)
---@return integer count
local function islands(coupled, nc)
    for k = 1, nc do
        local c = coupled[k]
        local ra = rootOf(c.a.flight)
        if c.b then
            local rb = rootOf(c.b.flight)
            if ra ~= rb then rb.uf = ra end
        end
    end
    local count = 0
    for k = 1, nc do
        local r = rootOf(coupled[k].a.flight)
        if r.islAt ~= stepStamp then
            r.islAt = stepStamp
            count = count + 1
            r.isl = count
            islandNext[count] = 0
        end
        local isl = r.isl
        islandOf[k] = isl
        islandNext[isl] = islandNext[isl] + 1
    end
    local at = 1 -- counting sort
    for isl = 1, count do
        islandStarts[isl] = at
        at = at + islandNext[isl]
        islandNext[isl] = islandStarts[isl]
    end
    islandStarts[count + 1] = at
    for k = 1, nc do
        local isl = islandOf[k]
        local slot = islandNext[isl]
        islandOrder[slot] = coupled[k]
        islandNext[isl] = slot + 1
    end
    for k = nc + 1, #islandOrder do islandOrder[k] = nil end
    return islandStarts, count
end

---------------------------------------------------------------------------------------------------- stepping

---A new flight from the prop's pose now (vel, ang copied)
---@return AtmoPlayFlight
function Flight.start(vel, frame, ang)
    vel, ang = vel or { 0, 0, 0 }, ang or { 0, 0, 0 }
    return { vel = { vel[1] or 0, vel[2] or 0, vel[3] or 0 }, ang = { ang[1] or 0, ang[2] or 0, ang[3] or 0 },
        frame = frame, still = 0 }
end

---@class AtmoPlayFlightOptions
---@field collide boolean? flying props hit each other and wake the still ones they run into
---@field simple boolean? props fly as spheres that hits don't turn
---@field neighbors (fun(prop: table, reach: number): table[])? collide: still props near prop, in atmo order
---@field wake (fun(prop: table, frame: integer))? collide: gives a still prop a flight and adds it to the list

-- The sweep's pairs: partnerLists[i] (later list positions i meets), valid while partnerAt[i] is the sweep's stamp
local sweepStamp = 0
local partnerLists, partnerAt, partnerFirsts = {}, {}, {}

---Pairs of flying props whose bounding spheres meet, by a sweep along the axis they spread most on. The order is kept
---from the last step and fixed by insertion sort (ties by atmo index: the same from any start). Props that hit no
---props aren't swept
---@param n integer the first n bodies are swept (ones woken later are tried one by one)
local function sweepPairs(w, bodies, n)
    sweepStamp = sweepStamp + 1
    local stamp = sweepStamp
    local minP, maxP = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for k = 1, n do
        local b = bodies[k]
        b.sweepAt, b.sweepPos, b.sweepSeen = stamp, k, false
        local p = b.pos
        for a = 1, 3 do
            if p[a] < minP[a] then minP[a] = p[a] end
            if p[a] > maxP[a] then maxP[a] = p[a] end
        end
    end
    local axis = 1
    for a = 2, 3 do
        if maxP[a] - minP[a] > maxP[axis] - minP[axis] then axis = a end
    end
    -- last step's order on this axis without the props gone, then the new ones
    w.sweepOrders = w.sweepOrders or {}
    local order = w.sweepOrders[axis] or {}
    local m, old = 0, #order
    for i = 1, old do
        local b = order[i]
        if b.sweepAt == stamp and not b.noHits then
            m = m + 1
            order[m] = b
            b.sweepSeen = true
        end
    end
    for i = old, m + 1, -1 do order[i] = nil end
    for k = 1, n do
        local b = bodies[k]
        if not b.noHits and not b.sweepSeen then
            m = m + 1
            order[m] = b
        end
    end
    for i = 1, m do
        local b = order[i]
        b.sweepLo = b.pos[axis] - (b.radius or 1)
    end
    for i = 2, m do
        local b = order[i]
        local lb, ib = b.sweepLo, b.index or 0
        local j = i - 1
        while j >= 1 do
            local c = order[j]
            local lc = c.sweepLo
            if lc < lb or (lc == lb and (c.index or 0) <= ib) then break end
            order[j + 1] = c
            j = j - 1
        end
        order[j + 1] = b
    end
    w.sweepOrders[axis] = order
    local firsts = 0
    for oi = 1, m do
        local A = order[oi]
        local pa, ra = A.pos, A.radius or 1
        local hi = pa[axis] + ra
        local ia = A.sweepPos
        for oj = oi + 1, m do
            local B = order[oj]
            if B.sweepLo > hi then break end
            local pb = B.pos
            local dx, dy, dz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
            local r = ra + (B.radius or 1)
            if dx * dx + dy * dy + dz * dz <= r * r then
                local ib = B.sweepPos
                local first, second = ia, ib
                if ib < ia then first, second = ib, ia end
                local list = partnerLists[first]
                if partnerAt[first] ~= stamp then
                    partnerAt[first] = stamp
                    if list then
                        for k = #list, 1, -1 do list[k] = nil end
                    else
                        list = {}
                        partnerLists[first] = list
                    end
                    firsts = firsts + 1
                    partnerFirsts[firsts] = first
                end
                list[#list + 1] = second
            end
        end
    end
    for k = 1, firsts do table.sort(partnerLists[partnerFirsts[k]]) end
    return true
end

---Props that pass through each other: prop_hits 0, or overlapping where the map placed them (`ignore` is keyed by
---the props; a prediction's copy stands for its prop through `of`)
local function passes(A, B)
    return A.noHits or B.noHits or (A.ignore ~= nil and A.ignore[B.of or B] == true)
end

local function pairBodies(A, B)
    if passes(A, B) then return end
    local pa, pb = A.pos, B.pos
    local dx, dy, dz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
    local r = (A.radius or 1) + (B.radius or 1)
    if dx * dx + dy * dy + dz * dz <= r * r then
        pairContacts(A, ptsOf(A), B, B.flight.rows, ptsOf(B), B, B)
    end
end

---One frame for every flying prop together. `bodies` is in atmo order; woken props are added to its end. A prop that
---came to rest or fell under the map has its flight cleared (the caller drops it)
---@param opts AtmoPlayFlightOptions?
function Flight.step(w, bodies, frame, opts)
    opts = opts or {}
    local dt, g, simple = Flight.DT, w.gravity, opts.simple and true or false
    -- 1. gravity and thrust, then position and rotation
    for _, prop in ipairs(bodies) do
        local fl, b = prop.flight, bodyOf(prop, simple)
        fl.rows = fl.rows or rowsOf(prop.rot or Flight.IDENTITY)
        local v, a, m = fl.vel, fl.ang, fl.rows
        v[1], v[2], v[3] = v[1] + g[1] * dt, v[2] + g[2] * dt, v[3] + g[3] * dt
        local thrust = prop.thrust
        if thrust and Flight.pushes(thrust, frame) then
            local f = thrust.force
            local fx, fy, fz = f[1], f[2], f[3]
            if thrust.space == 1 then
                fx, fy, fz = m[1][1] * f[1] + m[1][2] * f[2] + m[1][3] * f[3],
                    m[2][1] * f[1] + m[2][2] * f[2] + m[2][3] * f[3], m[3][1] * f[1] + m[3][2] * f[2] + m[3][3] * f[3]
            end
            local k = b.invMass * dt
            v[1], v[2], v[3] = v[1] + fx * k, v[2] + fy * k, v[3] + fz * k
        end
        -- one pos table per flight, moved in place (never the atmo's or an event's); prop.moves tells it moved
        local p = prop.pos
        if p ~= fl.posBuf then
            p = { p[1], p[2], p[3] }
            fl.posBuf = p
            prop.pos = p
        end
        p[1], p[2], p[3] = p[1] + v[1] * dt, p[2] + v[2] * dt, p[3] + v[3] * dt
        prop.moves = (prop.moves or 0) + 1
        -- a sphere's rotation isn't kept up (it looks the same), unless a thrust on its own axes turns with it
        local seen = prop.shape ~= "sphere" or (thrust ~= nil and thrust.space == 1)
        if seen and (a[1] ~= 0 or a[2] ~= 0 or a[3] ~= 0) then
            turn(m, a[1], a[2], a[3], dt)
            orthonormalize(m)
            fl.turned = true
        end
        fl.touching, fl.gripping, fl.contacts = false, false, 0
    end
    stepStamp = stepStamp + 1
    -- 2. contacts: the ground, the static atmo, and (collide) each other and the still props run into
    used = 0
    local n0 = #bodies
    local collide = opts.collide
    local swept = collide and n0 > 1 and sweepPairs(w, bodies, n0) or false
    local near = w.near
    if not near then
        near = {}
        w.near = near
    end
    local i = 1
    while i <= #bodies do
        local A = bodies[i]
        local fl = A.flight
        local reach = A.radius or 1
        if A.pos[3] - reach < 0 then
            local ptsA = ptsOf(A)
            for k = 1, #ptsA do
                local q = ptsA[k]
                if q[3] - q[4] < 0 then addContact(A, nil, q[1], q[2], q[3] - q[4], 0, 0, 1, q[4] - q[3], nil) end
            end
        end
        for k = 1, nearby(w, A.pos, reach, near) do
            local c = near[k]
            pairContacts(A, ptsOf(A), c, c.frame, c.points, nil, c)
        end
        if collide then
            local list = swept and partnerAt[i] == sweepStamp and partnerLists[i]
            if list then
                for k = 1, #list do pairBodies(A, bodies[list[k]]) end
            end
            if not A.noHits then
                for j = (i < n0 and n0 or i) + 1, #bodies do pairBodies(A, bodies[j]) end
            end
            -- a moving prop wakes the still ones it runs into (they join the list)
            if fl.still == 0 and not A.noHits and opts.neighbors and opts.wake then
                for _, S in ipairs(opts.neighbors(A, reach)) do
                    if not S.flight and not S.entry and not passes(A, S) then
                        local sp = S.pos
                        local dx, dy, dz = sp[1] - A.pos[1], sp[2] - A.pos[2], sp[3] - A.pos[3]
                        local r = reach + (S.radius or 1)
                        if dx * dx + dy * dy + dz * dz <= r * r then
                            local before = used
                            local sRows = rowsOf(S.rot or Flight.IDENTITY)
                            local sb = bodyOf(S, simple)
                            local sPts = worldPointsInto(sp, sb.points, sRows, S.wakePts or {})
                            S.wakePts = sPts
                            pairContacts(A, ptsOf(A), S, sRows, sPts, S, S)
                            if used > before then
                                opts.wake(S, frame)
                                local sf = S.flight
                                sf.rows, sf.touching, sf.gripping = sRows, false, false
                                sf.pts, sf.ptsAt = worldPointsInto(S.pos, sb.points, sRows, {}), stepStamp
                            end
                        end
                    end
                end
            end
        end
        i = i + 1
    end
    -- 3. impulses
    for k = 1, used do
        local c = pool[k]
        prepare(c)
        local a, b = c.a.flight, c.b and c.b.flight
        a.touching = true
        a.contacts = (a.contacts or 0) + 1
        if b then
            b.touching = true
            b.contacts = (b.contacts or 0) + 1
        end
        if c.limit ~= 0 then
            a.gripping = true
            if b then b.gripping = true end
        end
    end
    -- round 1 settles a prop's only static contact by itself; later rounds go island by island
    local coupled, nc = coupledList, 0
    for k = 1, used do
        local c = pool[k]
        solve(c)
        if c.b or c.a.flight.contacts > 1 then
            nc = nc + 1
            coupled[nc] = c
        end
    end
    for k = nc + 1, #coupled do coupled[k] = nil end
    if nc > 0 then
        local starts, count = islands(coupled, nc)
        local ordered, settle, rounds = islandOrder, Flight.SETTLE, Flight.ITERATIONS
        for isl = 1, count do
            local from, to = starts[isl], starts[isl + 1] - 1
            for _ = 2, rounds do
                local change = 0
                for k = from, to do change = change + solve(ordered[k]) end
                if change < settle then break end
            end
        end
    end
    -- 4. overlaps pushed apart, shared by inverse mass
    local slop, share = Flight.SLOP, Flight.PUSH
    for k = 1, used do
        local c = pool[k]
        local over = c.depth - slop
        if over > 0 then
            local ia, ib = c.a.body.invMass, c.b and c.b.body.invMass or 0
            local s = over * share / (ia + ib)
            local nx, ny, nz, pa = c.nx, c.ny, c.nz, c.a.pos
            pa[1], pa[2], pa[3] = pa[1] + nx * s * ia, pa[2] + ny * s * ia, pa[3] + nz * s * ia
            if c.b then
                local pb = c.b.pos
                pb[1], pb[2], pb[3] = pb[1] - nx * s * ib, pb[2] - ny * s * ib, pb[3] - nz * s * ib
            end
        end
        c.a, c.b, c.other, c.va, c.wa, c.vb, c.wb = false, false, false, false, false, false, false
    end
    -- 5. rotations shown, rest and falls
    for _, prop in ipairs(bodies) do
        local fl = prop.flight
        local m = fl.rows
        if fl.turned then
            -- one rotation table per flight, written in place (who keeps a rotation copies it)
            local tb = fl.tb
            if not tb then
                tb = { r3 = 0, r7 = 0, r11 = 0 }
                fl.tb = tb
            end
            tb.r0, tb.r1, tb.r2 = m[1][1], m[1][2], m[1][3]
            tb.r4, tb.r5, tb.r6 = m[2][1], m[2][2], m[2][3]
            tb.r8, tb.r9, tb.r10 = m[3][1], m[3][2], m[3][3]
            prop.rot = tb
            fl.turned = false
        end
        fl.frame = frame + 1
        local v, a = fl.vel, fl.ang
        if simple and fl.gripping then
            local keep = 1 - Flight.SIMPLE_SPIN_GRIP
            a[1], a[2], a[3] = a[1] * keep, a[2] * keep, a[3] * keep
        end
        local p = prop.pos
        local calm = false
        if fl.touching and not prop.thrust then
            calm = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) < Flight.REST_SPEED
                and sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3]) < Flight.REST_SPIN
            if not calm and fl.ax then -- or it went nowhere since the anchor
                local dx, dy, dz = p[1] - fl.ax, p[2] - fl.ay, p[3] - fl.az
                calm = dx * dx + dy * dy + dz * dz <= Flight.REST_DRIFT * Flight.REST_DRIFT
                if calm and fl.u1 then
                    local r1, r2 = m[1], m[2]
                    local t1, t2, t3 = r1[1] - fl.u1, r1[2] - fl.u2, r1[3] - fl.u3
                    local t4, t5, t6 = r2[1] - fl.w1, r2[2] - fl.w2, r2[3] - fl.w3
                    calm = t1 * t1 + t2 * t2 + t3 * t3 + t4 * t4 + t5 * t5 + t6 * t6 <= Flight.REST_TURN * Flight.REST_TURN
                end
            end
        end
        if calm then
            fl.still = fl.still + 1
        else
            fl.still = 0
            fl.ax, fl.ay, fl.az = p[1], p[2], p[3]
            fl.u1, fl.u2, fl.u3, fl.w1, fl.w2, fl.w3 = m[1][1], m[1][2], m[1][3], m[2][1], m[2][2], m[2][3]
        end
        if fl.still >= Flight.REST_FRAMES or p[3] < Flight.LOWEST then prop.flight = nil end
    end
end

---Flies one prop alone to `toFrame`; false once its flight ended
function Flight.advance(w, prop, toFrame, opts)
    local list = { prop }
    while prop.flight and prop.flight.frame < toFrame do Flight.step(w, list, prop.flight.frame, opts) end
    return prop.flight ~= nil
end

---------------------------------------------------------------------------------------------------- prediction

-- Ghosts: the flights stepped ahead on copies ("shadows": the prop's fields with their own pos and flight), so the
-- props stay as they are. The prediction's world has its own caches (sweep orders, near list)

---@class AtmoPlayPrediction
---@field world table
---@field frame integer the frame the props are at (pose 0)
---@field steps integer frames stepped so far
---@field done boolean every flight ended
---@field poses table<table, AtmoPlayPredictedPoses> by prop
---@field ring integer frames of poses kept (frame k in slot k % ring)
---@field props table[] props with poses
---@field list table[] copies still flying
---@field shadows table<table, table> copies by prop
---@field opts AtmoPlayFlightOptions
---@field base integer the flights' frame now, counted from `frame`

local function shadowOf(pr, prop)
    local sh = pr.shadows[prop]
    if sh then return sh end
    sh = {}
    for k, v in pairs(prop) do sh[k] = v end
    sh.of = prop
    sh.pos = { prop.pos[1], prop.pos[2], prop.pos[3] }
    sh.sweepAt, sh.sweepPos, sh.sweepSeen, sh.sweepLo, sh.wakePts = nil, nil, nil, nil, nil
    local fl = prop.flight
    if fl then
        local m = fl.rows
        sh.flight = { vel = { fl.vel[1], fl.vel[2], fl.vel[3] }, ang = { fl.ang[1], fl.ang[2], fl.ang[3] },
            frame = fl.frame, still = fl.still, rows = m and { { m[1][1], m[1][2], m[1][3] }, { m[2][1], m[2][2], m[2][3] },
                { m[3][1], m[3][2], m[3][3] } } or nil,
            ax = fl.ax, ay = fl.ay, az = fl.az, u1 = fl.u1, u2 = fl.u2, u3 = fl.u3, w1 = fl.w1, w2 = fl.w2, w3 = fl.w3 }
    end
    pr.shadows[prop] = sh
    return sh
end

---@class AtmoPlayPredictedPoses
---@field pos number[] x y z of frame k at slot (k % ring) * 3
---@field rot number[]? r0 r1 r2 r4 r5 r6 r8 r9 r10 at slot (k % ring) * 9; nil: fixedRot
---@field fixedRot table? a sphere's rotation (not kept up while it flies)
---@field first integer
---@field last integer
---@field tb table the MatrixTB predictedPose fills

-- Poses are numbers in two flat lists per prop (a table per prop and frame was too much for the GC)
local function posesFor(pr, sh, k)
    local th = sh.thrust
    local fixed = sh.shape == "sphere" and not (th and th.space == 1)
    local p = { pos = {}, rot = (not fixed) and {} or nil, fixedRot = fixed and sh.rot or nil, first = k, last = k,
        tb = { r3 = 0, r7 = 0, r11 = 0 } }
    pr.poses[sh.of] = p
    pr.props[#pr.props + 1] = sh.of
    return p
end

local function writePose(pr, p, k, pos, rot)
    local slot = k % pr.ring
    local i, list = slot * 3, p.pos
    list[i + 1], list[i + 2], list[i + 3] = pos[1], pos[2], pos[3]
    local r = p.rot
    if r then
        local j = slot * 9
        r[j + 1], r[j + 2], r[j + 3] = rot.r0, rot.r1, rot.r2
        r[j + 4], r[j + 5], r[j + 6] = rot.r4, rot.r5, rot.r6
        r[j + 7], r[j + 8], r[j + 9] = rot.r8, rot.r9, rot.r10
    end
    p.last = k
    if k - p.first >= pr.ring then p.first = k - pr.ring + 1 end
end

local function record(pr, sh)
    local p = pr.poses[sh.of] or posesFor(pr, sh, pr.steps)
    writePose(pr, p, pr.steps, sh.pos, sh.rot)
end

---A prediction of `bodies` (flying props, atmo order) from `frame` on
---@param ring integer? frames of poses kept (default 128)
---@return AtmoPlayPrediction
function Flight.newPrediction(w, bodies, frame, opts, ring)
    local pw = {}
    for k, v in pairs(w) do pw[k] = v end
    pw.near, pw.sweepOrders = {}, {}
    local pr = { world = pw, frame = frame, steps = 0, base = 0, done = false, shadows = {}, list = {}, poses = {},
        props = {}, ring = ring or 128 }
    for _, prop in ipairs(bodies) do
        if prop.flight then
            local sh = shadowOf(pr, prop)
            pr.list[#pr.list + 1] = sh
            record(pr, sh)
        end
    end
    opts = opts or {}
    pr.opts = { collide = opts.collide, simple = opts.simple }
    local neighbors = opts.neighbors
    if opts.collide and neighbors then
        pr.opts.neighbors = function(A, reach)
            local out = {}
            for _, S in ipairs(neighbors(A, reach)) do
                if S ~= A.of then
                    local sh = shadowOf(pr, S)
                    if not sh.flight then out[#out + 1] = sh end
                end
            end
            return out
        end
        pr.opts.wake = function(S, at)
            -- still until now: its pose for the frames the ring holds
            local from = math.max(0, pr.steps - pr.ring + 1)
            local p = posesFor(pr, S, from)
            for k = from, pr.steps do writePose(pr, p, k, S.pos, S.rot) end
            S.pos = { S.pos[1], S.pos[2], S.pos[3] }
            S.flight = Flight.start(nil, at)
            pr.list[#pr.list + 1] = S
        end
    end
    pr.done = #pr.list == 0
    return pr
end

local function byAtmoIndex(a, b) return (a.index or 0) < (b.index or 0) end

---Moves a prediction `count` frames ahead (fewer once every flight ended)
function Flight.predictStep(pr, count)
    for _ = 1, count do
        if pr.done then return end
        Flight.step(pr.world, pr.list, pr.frame + pr.steps, pr.opts)
        pr.steps = pr.steps + 1
        local kept, sorted, last = {}, true, -math.huge
        for _, sh in ipairs(pr.list) do
            record(pr, sh)
            if sh.flight then
                kept[#kept + 1] = sh
                if (sh.index or 0) < last then sorted = false end
                last = sh.index or 0
            end
        end
        if not sorted then table.sort(kept, byAtmoIndex) end
        pr.list = kept
        pr.done = #kept == 0
    end
end

---Drops the poses before frame `base` (a prop's last pose stays)
function Flight.predictTrim(pr, base)
    for _, p in pairs(pr.poses) do
        local from = math.min(base, p.last)
        if from > p.first then p.first = from end
    end
end

---A prop's predicted pose `k` frames ahead (fractional k blends the position, takes the nearer rotation); past the
---frames predicted, its last pose. nil without a prediction for it
---@return number? x, number? y, number? z, table? rot MatrixTB
function Flight.predictedPose(pr, prop, k)
    local p = pr.poses[prop]
    if not p then return nil end
    if k > p.last then k = p.last end
    if k < p.first then k = p.first end
    local ring, list = pr.ring, p.pos
    local i = math.floor(k)
    local t = k - i
    local a = (i % ring) * 3
    local x, y, z = list[a + 1], list[a + 2], list[a + 3]
    local next = t > 0 and i + 1 <= p.last
    if next then
        local b = ((i + 1) % ring) * 3
        x, y, z = x + (list[b + 1] - x) * t, y + (list[b + 2] - y) * t, z + (list[b + 3] - z) * t
    end
    local rot = p.fixedRot
    if not rot then
        local j = (((next and t >= 0.5) and i + 1 or i) % ring) * 9
        local r, tb = p.rot, p.tb
        tb.r0, tb.r1, tb.r2, tb.r4, tb.r5, tb.r6 = r[j + 1], r[j + 2], r[j + 3], r[j + 4], r[j + 5], r[j + 6]
        tb.r8, tb.r9, tb.r10 = r[j + 7], r[j + 8], r[j + 9]
        rot = tb
    end
    return x, y, z, rot
end

NS.Flight = Flight
return Flight
