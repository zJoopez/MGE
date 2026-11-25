-- Drawn flight (docs/atmo-play-plan.md, section 7): a small rigid-body step for props that move while no pool
-- object carries them (thrust props, props let go while moving). Pure Lua, no engine calls.
-- Measured in game (probe_thrust.lua): a match frame is 0.006 s, stepped as `v += a * dt`, then `pos += v * dt`;
-- a thrust line is a force for one step on its push frames (dv = F / mass * dt); bounce rebounds the normal speed
-- by e = 0.096 x (bounce - 0.48); friction: the lower value of the two sides wins, -10000 is frictionless,
-- -9999 a ~2 N limit (`mu = friction + 10000`), 0 and up full grip.
-- Shapes: a box touches by its 8 corners, a sphere by its center, a pill (capsule along local z) by its two end
-- spheres; each pair is tried both ways (A's points against B's surface and B's against A's), so a static's
-- corner against a prop's face counts too. Edge against edge is missed. Contacts are solved with impulses
-- (ITERATIONS rounds: normal, bounce, friction as a Coulomb cone of MU capped by the game's friction limit), so
-- hits turn props (spin from where they're hit, world axes, rad/s as ODE's get_obj_angular_vel; the game has no
-- torque for objects: a taken prop's spin is set with set_obj_angular_vel, as RPH does).
-- It meets the static atmo, the ground (always at z = 0) and, with `collide`, the other flying props and the
-- still ones it runs into (woken: they fly too). Never carried props or players: near one a prop is real by then.
-- `simple` (the cheap level, for slower computers): every prop is a sphere of its smallest half side, hits don't
-- turn it (its spin slows by SIMPLE_SPIN_GRIP a frame while something grips it), one point a prop to test.
-- All flying props step together one frame at a time (Flight.step), in atmo order, so a fight and its replay
-- (and a rebuild that steps the same frames again) give the same numbers.

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

---@class AtmoPlayThrust
---@field every integer pushes on the steps from frames 0, N, 2N ... (into 1, N + 1 ...)
---@field force number[] x y z
---@field space integer 0 world axes, 1 the prop's own

---@class AtmoPlayFlight
---@field vel number[] linear velocity, per second
---@field ang number[] angular velocity, rad/s, world axes
---@field frame integer the frame its prop's pos is at
---@field still integer frames in a row at rest on something
---@field rows number[][] its rotation (local to world) while it flies

---@class AtmoPlayFlightWorld
---@field gravity number[]
---@field cellSize number
---@field cells table<integer, AtmoPlayCollider[]>
---@field big AtmoPlayCollider[] colliders over too many cells: looked at every time

local Flight = {
    DT = 0.006,
    GRAVITY = { 0, 0, -9.82 },
    MASS = 1, -- a prop without a mass line
    NO_FRICTION = -10000,
    -- gripping contacts: a Coulomb cone of this share (a flat box slid at 5 stops in ~0.25 s, as in game), and
    -- the game's friction limit, (friction + 10000) x LIMIT_SHARE N per contact (the flat box's 4 corners: ~2 N)
    MU = 2,
    LIMIT_SHARE = 0.5,
    ITERATIONS = 8,
    -- the rounds after the first stop early once a whole round changes the impulses by less than this (N s): resting
    -- boxes (4 corners on the ground) settle in a round or two, they took all 8 every frame. The same data gives the
    -- same rounds: fights still equal their replays
    SETTLE = 1e-7,
    BOUNCE_MIN = 0.3, -- slower hits than this (normal speed) don't bounce: resting contacts stay quiet
    SLOP = 0.002, -- this much overlap is left (no jitter at rest)
    PUSH = 0.8, -- the share of the rest of an overlap pushed out each frame
    SIMPLE_SPIN_GRIP = 0.11, -- simple: the share of the spin a gripping contact takes each frame
    REST_SPEED = 0.05,
    REST_SPIN = 0.1,
    REST_FRAMES = 10, -- this many frames at rest on something: the flight ends
    LOWEST = -100, -- below this the flight ends (under the ground: fell through)
    CELL = 8,
    MAX_CELLS = 64, -- a collider over more cells than this goes in `big`
}

local cellKey = NS.Pool.cellKey
local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max

---A thrust line ("<frames> x y z [space]") as a prop's thrust, nil without a push
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

---The rebound share of the normal speed for a bounce value (0 when it doesn't bounce)
---@param bounce number?
---@return number
function Flight.restitution(bounce)
    return max(0, 0.096 * ((bounce or 0) - 0.48))
end

---The friction impulse one contact can give in a frame (frictionA / B: the two sides' friction lines, nil: grip),
---nil without a limit of its own (only the Coulomb cone)
---@param frictionA number?
---@param frictionB number?
---@return number? limit 0 for frictionless
function Flight.frictionLimit(frictionA, frictionB)
    local f = min(frictionA or 0, frictionB or 0)
    if f <= Flight.NO_FRICTION then return 0 end
    return (f + 10000) * Flight.LIMIT_SHARE * Flight.DT
end

---A thrust's force in world axes for a prop turned by `rot` (MatrixTB, local to world; Driver.matrixTB's layout)
---@param thrust AtmoPlayThrust
---@param rot table?
---@return number x, number y, number z
function Flight.thrustWorld(thrust, rot)
    local f = thrust.force
    if thrust.space ~= 1 or not rot then return f[1], f[2], f[3] end
    return rot.r0 * f[1] + rot.r1 * f[2] + rot.r2 * f[3],
        rot.r4 * f[1] + rot.r5 * f[2] + rot.r6 * f[3],
        rot.r8 * f[1] + rot.r9 * f[2] + rot.r10 * f[3]
end

---Whether the step from `frame` to the next pushes (the game's thrust pushes into frames 1, N + 1, 2N + 1 ...)
---@param thrust AtmoPlayThrust
---@param frame integer
---@return boolean
function Flight.pushes(thrust, frame)
    return frame % thrust.every == 0
end

---Gravity as a gamerule string ("0 0 -9.82"), nil when it isn't three numbers
---@param text string?
---@return number[]?
function Flight.parseGravity(text)
    local n = {}
    for v in tostring(text or ""):gmatch("%S+") do n[#n + 1] = tonumber(v) end
    if #n == 3 and n[1] and n[2] and n[3] then return n end
    return nil
end

---------------------------------------------------------------------------------------------------- shapes

---The points a shape touches by, in its own axes: { x, y, z, radius }
---@param shape string
---@param sides number[]
---@return number[][]
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

---The inverse of a shape's inertia in its own axes (per unit mass: divided by the mass after)
local function inverseInertia(shape, sides, mass)
    local x, y, z
    if shape == "sphere" then
        local i = 0.4 * mass * sides[1] ^ 2
        return { 1 / i, 1 / i, 1 / i }
    elseif shape == "cylinder" then
        -- ODE's capsule (dMassSetCapsule): a cylinder of radius r and length l with two half spheres, its mass shared by
        -- volume. The box around the pill (the first version) turned ~1.5x too hard: drawn cylinders rolled ~11% short of
        -- the game's (docs/atmo-play-plan.md, real against drawn)
        local r, l = sides[1], sides[2]
        local m1, m2 = math.pi * r * r * l, 4 / 3 * math.pi * r ^ 3
        local k = mass / (m1 + m2)
        local along = k * (m1 * 0.5 * r * r + m2 * 0.4 * r * r)
        local across = k * (m1 * (0.25 * r * r + l * l / 12) + m2 * (0.4 * r * r + 0.375 * r * l + 0.25 * l * l))
        return { 1 / across, 1 / across, 1 / along }
    else
        x, y, z = sides[1], sides[2], sides[3]
    end
    local k = mass / 12
    return { 1 / (k * (y * y + z * z)), 1 / (k * (x * x + z * z)), 1 / (k * (x * x + y * y)) }
end

---A prop's body data for a level, made once each (its shape and size don't change): its shape as it touches,
---points, mass and inertia. Set as prop.body, the one the solver uses
---@param prop AtmoPlayCollider
---@param simple boolean? the cheap level: a sphere of the smallest half side that hits don't turn
local function bodyOf(prop, simple)
    local cache = prop.bodies
    if not cache then
        cache = {}
        prop.bodies = cache
    end
    local key = simple and "simple" or "shapes"
    local b = cache[key]
    if not b then
        -- the mass its object has in the game (dynamics.lua reads it for a prop without a mass line), else its line
        local mass = prop.flightMass or prop.mass or Flight.MASS
        if mass <= 0 then mass = Flight.MASS end
        if simple then
            local r = Flight.radiusOf(prop)
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

---The sphere a prop flies as on the simple level: its smallest half side (flat props sit low), a sphere's
---radius, a pill's
---@param prop AtmoPlayCollider
---@return number
function Flight.radiusOf(prop)
    local s = prop.sides
    if prop.shape == "sphere" or prop.shape == "cylinder" then return s[1] end
    return min(s[1], s[2], s[3]) / 2
end
Flight.bodyOf = bodyOf

---A MatrixTB (local to world, Driver.matrixTB's layout) as rows
local function rowsOf(m)
    return { { m.r0, m.r1, m.r2 }, { m.r4, m.r5, m.r6 }, { m.r8, m.r9, m.r10 } }
end

---Rows m back to a rotation (Gram-Schmidt on its columns: steps add up rounding), in place
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

---Rows m turned by angular velocity w for dt (Rodrigues, world axes): Q * m, in place
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

---Where a point is against a shape at pos turned by frame (rows, local to world): its distance out of the surface
---(negative inside) and the way out
---@return number distance, number nx, number ny, number nz
local function surfaceAt(shape, sides, pos, f, x, y, z)
    local dx, dy, dz = x - pos[1], y - pos[2], z - pos[3]
    if shape == "sphere" then
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < 1e-9 then return -sides[1], 0, 0, 1 end
        return d - sides[1], dx / d, dy / d, dz / d
    end
    -- into the shape's own axes (frame is local to world, so its transpose)
    local lx = dx * f[1][1] + dy * f[2][1] + dz * f[3][1]
    local ly = dx * f[1][2] + dy * f[2][2] + dz * f[3][2]
    local lz = dx * f[1][3] + dy * f[2][3] + dz * f[3][3]
    local ox, oy, oz, d -- the way out, local
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
        else
            -- inside: out through the nearest face
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

local OVERLAP_MARGIN = 0.01 -- deeper than this in each other: overlapping (touching faces aren't)

---Whether two shapes (shape, sides, pos, frame: rows local to world) overlap: a touch point of one inside the
---other, or one's center inside the other. Props that already overlap where the map places them (a generated shape
---of overlapping boxes) never push each other apart (dynamics.lua: prop.ignore)
---@return boolean
function Flight.overlap(a, b)
    local dx, dy, dz = b.pos[1] - a.pos[1], b.pos[2] - a.pos[2], b.pos[3] - a.pos[3]
    local reach = (a.radius or 0) + (b.radius or 0)
    if dx * dx + dy * dy + dz * dz > reach * reach then return false end
    local function into(x, y)
        local f, p = x.frame, x.pos
        if surfaceAt(y.shape, y.sides, y.pos, y.frame, p[1], p[2], p[3]) < -OVERLAP_MARGIN then return true end
        for _, l in ipairs(localPoints(x.shape, x.sides)) do
            local qx = p[1] + f[1][1] * l[1] + f[1][2] * l[2] + f[1][3] * l[3]
            local qy = p[2] + f[2][1] * l[1] + f[2][2] * l[2] + f[2][3] * l[3]
            local qz = p[3] + f[3][1] * l[1] + f[3][2] * l[2] + f[3][3] * l[3]
            if surfaceAt(y.shape, y.sides, y.pos, y.frame, qx, qy, qz) < l[4] - OVERLAP_MARGIN then return true end
        end
        return false
    end
    if a.shape == "box" and b.shape == "box" and Flight.boxesOverlap then
        return Flight.boxesOverlap(a, b) > OVERLAP_MARGIN -- separating axes: faces crossing without a corner inside
    end
    return into(a, b) or into(b, a)
end

---Where a point is against a collider (see surfaceAt)
---@param c AtmoPlayCollider
---@return number distance, number nx, number ny, number nz
function Flight.surface(c, x, y, z)
    return surfaceAt(c.shape, c.sides, c.pos, c.frame, x, y, z)
end

---------------------------------------------------------------------------------------------------- the world

---The static atmo, listed by x / y cell for quick lookups; each collider gets its touch points in world axes
---@param colliders AtmoPlayCollider[]? static ones
---@param gravity number[]?
---@return AtmoPlayFlightWorld
function Flight.newWorld(colliders, gravity)
    local w = { gravity = gravity or Flight.GRAVITY, cellSize = Flight.CELL, cells = {}, big = {},
        empty = colliders == nil or #colliders == 0 }
    for _, c in ipairs(colliders or {}) do
        if not c.points then
            local f, pts = c.frame, {}
            for _, l in ipairs(localPoints(c.shape, c.sides)) do
                pts[#pts + 1] = { c.pos[1] + f[1][1] * l[1] + f[1][2] * l[2] + f[1][3] * l[3],
                    c.pos[2] + f[2][1] * l[1] + f[2][2] * l[2] + f[2][3] * l[3],
                    c.pos[3] + f[3][1] * l[1] + f[3][2] * l[2] + f[3][3] * l[3], l[4] }
            end
            c.points = pts
        end
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

---The static colliders whose bounding spheres reach a sphere at p of radius r (each once, in a stable order).
---Makes no tables: a collider already listed by this call carries the call's stamp
local stamp = 0
local function nearby(w, p, r, out)
    if w.empty then
        for i = 1, #out do out[i] = nil end
        return 0
    end
    stamp = stamp + 1
    local n, px, py, pz = 0, p[1], p[2], p[3]
    local big = w.big
    for k = 1, #big do
        local c = big[k]
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
    local size, cells = w.cellSize, w.cells
    for cx = math.floor((px - r) / size), math.floor((px + r) / size) do
        for cy = math.floor((py - r) / size), math.floor((py + r) / size) do
            local list = cells[cellKey(cx, cy)]
            if list then
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
            end
        end
    end
    for i = n + 1, #out do out[i] = nil end
    return n
end

---------------------------------------------------------------------------------------------------- contacts

-- A contact (pooled: the tables are used again every frame): a (a flying prop), b (another, or nil: static /
-- ground), other (b, or the static collider: its bounce and friction), the point px py pz, the normal n (out of b,
-- into a's side), its depth, two tangents t1 t2, the bounce it aims for, the friction cap, the impulses so far

---A flying prop's touch points in world axes, written into `out` (its tables used again)
local function worldPointsInto(pos, b, m, out)
    local px, py, pz = pos[1], pos[2], pos[3]
    local m11, m12, m13, m21, m22, m23, m31, m32, m33 =
        m[1][1], m[1][2], m[1][3], m[2][1], m[2][2], m[2][3], m[3][1], m[3][2], m[3][3]
    local pts = b.points
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

local pool, used = {}, 0 -- the contacts of the frame being stepped
local coupledList = {} -- Flight.step's contacts solved in every round, kept (no list a step)

local function addContact(a, b, px, py, pz, nx, ny, nz, depth, other)
    used = used + 1
    local c = pool[used]
    if not c then
        c = {}
        pool[used] = c
    end
    c.a, c.b, c.other = a, b, other
    c.px, c.py, c.pz, c.nx, c.ny, c.nz, c.depth = px, py, pz, nx, ny, nz, depth
    -- tangents: t1 = a x n, normalized; t2 = n x t1
    local ax, ay, az
    if abs(nx) < 0.6 then ax, ay, az = 1, 0, 0 else ax, ay, az = 0, 1, 0 end
    local t1x, t1y, t1z = ay * nz - az * ny, az * nx - ax * nz, ax * ny - ay * nx
    local l = sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
    t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
    c.t1x, c.t1y, c.t1z = t1x, t1y, t1z
    c.t2x, c.t2y, c.t2z = ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
    c.jn, c.jt1, c.jt2 = 0, 0, 0
end

local AXIS_TOL = 1e-4 -- a corner this close to a box's side still counts as inside it (faces flush)

-- the pair boxBox is testing (upvalues: no tables or closures a call)
local A1x, A1y, A1z, A2x, A2y, A2z, A3x, A3y, A3z
local B1x, B1y, B1z, B2x, B2y, B2z, B3x, B3y, B3z
local hA1, hA2, hA3, hB1, hB2, hB3, Dx, Dy, Dz
local best, Nx, Ny, Nz

---One separating axis: false when the boxes are apart along it; else the least overlap so far (an edge axis only
---when clearly better: faces give steadier contacts) and the normal out of B, toward A
local function satAxis(lx, ly, lz, edge)
    local len = sqrt(lx * lx + ly * ly + lz * lz)
    if len < 1e-6 then return true end
    lx, ly, lz = lx / len, ly / len, lz / len
    local ra = hA1 * abs(A1x * lx + A1y * ly + A1z * lz) + hA2 * abs(A2x * lx + A2y * ly + A2z * lz)
        + hA3 * abs(A3x * lx + A3y * ly + A3z * lz)
    local rb = hB1 * abs(B1x * lx + B1y * ly + B1z * lz) + hB2 * abs(B2x * lx + B2y * ly + B2z * lz)
        + hB3 * abs(B3x * lx + B3y * ly + B3z * lz)
    local dist = Dx * lx + Dy * ly + Dz * lz
    local over = ra + rb - abs(dist)
    if over < 0 then return false end
    if over < (edge and best * 0.95 - 1e-4 or best) then
        best = over
        if dist > 0 then Nx, Ny, Nz = -lx, -ly, -lz else Nx, Ny, Nz = lx, ly, lz end
    end
    return true
end

---How deep two boxes (shape, sides, pos, frame) overlap by separating axes: the least overlap over the 15 axes, 0
---or less when apart
---@return number
function Flight.boxesOverlap(a, b)
    local fa, fb = a.frame, b.frame
    A1x, A1y, A1z, A2x, A2y, A2z, A3x, A3y, A3z =
        fa[1][1], fa[2][1], fa[3][1], fa[1][2], fa[2][2], fa[3][2], fa[1][3], fa[2][3], fa[3][3]
    B1x, B1y, B1z, B2x, B2y, B2z, B3x, B3y, B3z =
        fb[1][1], fb[2][1], fb[3][1], fb[1][2], fb[2][2], fb[3][2], fb[1][3], fb[2][3], fb[3][3]
    local sa, sb, pa, pb = a.sides, b.sides, a.pos, b.pos
    hA1, hA2, hA3, hB1, hB2, hB3 = sa[1] / 2, sa[2] / 2, sa[3] / 2, sb[1] / 2, sb[2] / 2, sb[3] / 2
    Dx, Dy, Dz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
    best = math.huge
    local axes = {
        { A1x, A1y, A1z }, { A2x, A2y, A2z }, { A3x, A3y, A3z }, { B1x, B1y, B1z }, { B2x, B2y, B2z }, { B3x, B3y, B3z } }
    for _, l in ipairs(axes) do
        if not satAxis(l[1], l[2], l[3]) then return 0 end
    end
    for i = 1, 3 do
        for j = 4, 6 do
            local u, v = axes[i], axes[j]
            -- every axis counts the same here (edge = nil): the least overlap is the depth
            if not satAxis(u[2] * v[3] - u[3] * v[2], u[3] * v[1] - u[1] * v[3], u[1] * v[2] - u[2] * v[1]) then
                return 0
            end
        end
    end
    return best
end

---Box against box by separating axes (their 3 + 3 faces and 9 edge pairs): the axis of least overlap is the
---normal; the contacts are each box's corners inside the other (flush faces too), or one point between the
---two when only edges cross. Corner tests alone miss flush faces of equal boxes (their corners sit on edges)
local function boxBox(A, fa, ptsA, B, fb, ptsB, bodyB, other)
    A1x, A1y, A1z, A2x, A2y, A2z, A3x, A3y, A3z =
        fa[1][1], fa[2][1], fa[3][1], fa[1][2], fa[2][2], fa[3][2], fa[1][3], fa[2][3], fa[3][3]
    B1x, B1y, B1z, B2x, B2y, B2z, B3x, B3y, B3z =
        fb[1][1], fb[2][1], fb[3][1], fb[1][2], fb[2][2], fb[3][2], fb[1][3], fb[2][3], fb[3][3]
    local sa, sb, pa, pb = A.sides, B.sides, A.pos, B.pos
    hA1, hA2, hA3, hB1, hB2, hB3 = sa[1] / 2, sa[2] / 2, sa[3] / 2, sb[1] / 2, sb[2] / 2, sb[3] / 2
    Dx, Dy, Dz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
    best, Nx, Ny, Nz = math.huge, 0, 0, 1
    if not (satAxis(A1x, A1y, A1z) and satAxis(B1x, B1y, B1z) and satAxis(A2x, A2y, A2z) and satAxis(B2x, B2y, B2z)
            and satAxis(A3x, A3y, A3z) and satAxis(B3x, B3y, B3z)) then
        return
    end
    -- the 9 edge pairs: A's axis i x B's axis j
    if not (satAxis(A1y * B1z - A1z * B1y, A1z * B1x - A1x * B1z, A1x * B1y - A1y * B1x, true)
            and satAxis(A1y * B2z - A1z * B2y, A1z * B2x - A1x * B2z, A1x * B2y - A1y * B2x, true)
            and satAxis(A1y * B3z - A1z * B3y, A1z * B3x - A1x * B3z, A1x * B3y - A1y * B3x, true)
            and satAxis(A2y * B1z - A2z * B1y, A2z * B1x - A2x * B1z, A2x * B1y - A2y * B1x, true)
            and satAxis(A2y * B2z - A2z * B2y, A2z * B2x - A2x * B2z, A2x * B2y - A2y * B2x, true)
            and satAxis(A2y * B3z - A2z * B3y, A2z * B3x - A2x * B3z, A2x * B3y - A2y * B3x, true)
            and satAxis(A3y * B1z - A3z * B1y, A3z * B1x - A3x * B1z, A3x * B1y - A3y * B1x, true)
            and satAxis(A3y * B2z - A3z * B2y, A3z * B2x - A3x * B2z, A3x * B2y - A3y * B2x, true)
            and satAxis(A3y * B3z - A3z * B3y, A3z * B3x - A3x * B3z, A3x * B3y - A3y * B3x, true)) then
        return
    end
    local nx, ny, nz = Nx, Ny, Nz
    -- how far each box reaches along n
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
    if used == before then
        -- edges crossing: one point between the two boxes' nearest corners along n
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

---Contacts between flying prop A (its world points) and a shape B (static collider or flying prop: shape,
---sides, pos, rows f, and its world points), each way. bodyB: nil for a static one. A touches as its body's
---shape (a sphere on the simple level)
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
        if d < q[4] then
            -- the way out of A is into B: the normal out of B is its opposite
            addContact(A, bodyB, q[1], q[2], q[3], -nx, -ny, -nz, q[4] - d, other)
        end
    end
end

---------------------------------------------------------------------------------------------------- solving

---A flying prop's inverse inertia in world axes for this frame (R * diag(invI) * R^T, 9 numbers by rows)
local function worldInertia(fl, b)
    local m, i = fl.rows, b.invI
    local iw = fl.iw
    if not iw then
        iw = {}
        fl.iw = iw
    end
    local i1, i2, i3 = i[1], i[2], i[3]
    if i1 == i2 and i2 == i3 then -- the same in every axis (a sphere, the simple level): any rotation keeps it
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

---How hard it is to change the speed along direction d at point p (1 / effective mass); 0 for no prop
local function resistance(prop, px, py, pz, dx, dy, dz)
    if not prop then return 0 end
    local q, i = prop.pos, prop.flight.iw
    local rx, ry, rz = px - q[1], py - q[2], pz - q[3]
    local cx, cy, cz = ry * dz - rz * dy, rz * dx - rx * dz, rx * dy - ry * dx -- r x d
    local ix = i[1] * cx + i[2] * cy + i[3] * cz
    local iy = i[4] * cx + i[5] * cy + i[6] * cz
    local iz = i[7] * cx + i[8] * cy + i[9] * cz
    -- (I^-1 (r x d)) x r . d
    return prop.body.invMass + (iy * rz - iz * ry) * dx + (iz * rx - ix * rz) * dy + (ix * ry - iy * rx) * dz
end

---The relative velocity of a's and b's material at the contact point
local function relVel(c)
    local a, px, py, pz = c.a, c.px, c.py, c.pz
    local fl, q = a.flight, a.pos
    local v, w = fl.vel, fl.ang
    local rx, ry, rz = px - q[1], py - q[2], pz - q[3]
    local vx = v[1] + w[2] * rz - w[3] * ry
    local vy = v[2] + w[3] * rx - w[1] * rz
    local vz = v[3] + w[1] * ry - w[2] * rx
    local b = c.b
    if b then
        fl, q = b.flight, b.pos
        v, w = fl.vel, fl.ang
        rx, ry, rz = px - q[1], py - q[2], pz - q[3]
        vx = vx - (v[1] + w[2] * rz - w[3] * ry)
        vy = vy - (v[2] + w[3] * rx - w[1] * rz)
        vz = vz - (v[3] + w[1] * ry - w[2] * rx)
    end
    return vx, vy, vz
end

---An impulse j at point p on a prop, times sign (+ on a, - on b)
local function push(prop, px, py, pz, jx, jy, jz, sign)
    local fl, q = prop.flight, prop.pos
    local inv = prop.body.invMass * sign
    local v, w, i = fl.vel, fl.ang, fl.iw
    v[1], v[2], v[3] = v[1] + jx * inv, v[2] + jy * inv, v[3] + jz * inv
    local rx, ry, rz = px - q[1], py - q[2], pz - q[3]
    local cx, cy, cz = ry * jz - rz * jy, rz * jx - rx * jz, rx * jy - ry * jx
    w[1] = w[1] + (i[1] * cx + i[2] * cy + i[3] * cz) * sign
    w[2] = w[2] + (i[4] * cx + i[5] * cy + i[6] * cz) * sign
    w[3] = w[3] + (i[7] * cx + i[8] * cy + i[9] * cz) * sign
end

-- the frame being stepped (Flight.step counts them): a flying prop's touch points and inertia in world axes are
-- worked out once a frame, and only when something is near enough to touch it (most flying props meet nothing)
local stepStamp = 0

---A flying prop's touch points this frame (worked out the first time they're asked for)
local function ptsOf(prop)
    local fl = prop.flight
    if fl.ptsAt ~= stepStamp then
        fl.pts = worldPointsInto(prop.pos, prop.body, fl.rows, fl.pts or {})
        fl.ptsAt = stepStamp
    end
    return fl.pts
end

---A flying prop's inverse inertia in world axes this frame (worked out the first time a contact needs it)
local function inertiaOf(prop)
    local fl = prop.flight
    if fl.iwAt ~= stepStamp then
        worldInertia(fl, prop.body)
        fl.iwAt = stepStamp
    end
end

local function prepare(c)
    local a, b, px, py, pz = c.a, c.b, c.px, c.py, c.pz
    inertiaOf(a)
    if b then inertiaOf(b) end
    c.kn = resistance(a, px, py, pz, c.nx, c.ny, c.nz) + resistance(b, px, py, pz, c.nx, c.ny, c.nz)
    c.kt1 = resistance(a, px, py, pz, c.t1x, c.t1y, c.t1z) + resistance(b, px, py, pz, c.t1x, c.t1y, c.t1z)
    c.kt2 = resistance(a, px, py, pz, c.t2x, c.t2y, c.t2z) + resistance(b, px, py, pz, c.t2x, c.t2y, c.t2z)
    local vx, vy, vz = relVel(c)
    local vn = vx * c.nx + vy * c.ny + vz * c.nz
    local o = c.other
    local e = Flight.restitution(max(a.bounce or 0, o and o.bounce or 0))
    c.bias = vn < -Flight.BOUNCE_MIN and -e * vn or 0
    c.limit = Flight.frictionLimit(a.friction, o and o.friction)
end

local function solve(c)
    local a, b, px, py, pz = c.a, c.b, c.px, c.py, c.pz
    local nx, ny, nz = c.nx, c.ny, c.nz
    local vx, vy, vz = relVel(c)
    local vn = vx * nx + vy * ny + vz * nz
    local dj = (c.bias - vn) / c.kn
    local old = c.jn
    local jn = max(old + dj, 0)
    c.jn = jn
    dj = jn - old
    if dj ~= 0 then
        push(a, px, py, pz, nx * dj, ny * dj, nz * dj, 1)
        if b then push(b, px, py, pz, nx * dj, ny * dj, nz * dj, -1) end
    end
    -- friction: the cone (MU x the normal impulse so far), capped by the game's limit
    local cap = Flight.MU * jn
    local limit = c.limit
    if limit and limit < cap then cap = limit end
    vx, vy, vz = relVel(c)
    local t1x, t1y, t1z, t2x, t2y, t2z = c.t1x, c.t1y, c.t1z, c.t2x, c.t2y, c.t2z
    local d1 = -(vx * t1x + vy * t1y + vz * t1z) / c.kt1
    local d2 = -(vx * t2x + vy * t2y + vz * t2z) / c.kt2
    local o1, o2 = c.jt1, c.jt2
    local j1, j2 = o1 + d1, o2 + d2
    local len = sqrt(j1 * j1 + j2 * j2)
    if len > cap then
        local k = cap > 0 and cap / len or 0
        j1, j2 = j1 * k, j2 * k
    end
    c.jt1, c.jt2 = j1, j2
    d1, d2 = j1 - o1, j2 - o2
    if d1 ~= 0 or d2 ~= 0 then
        local jx, jy, jz = t1x * d1 + t2x * d2, t1y * d1 + t2y * d2, t1z * d1 + t2z * d2
        push(a, px, py, pz, jx, jy, jz, 1)
        if b then push(b, px, py, pz, jx, jy, jz, -1) end
    end
    return abs(dj) + abs(d1) + abs(d2) -- how much this round changed it
end

---------------------------------------------------------------------------------------------------- stepping

---A new flight for a prop at its pos and rotation
---@param vel number[]? per second (copied)
---@param frame integer the frame its pos is at
---@param ang number[]? angular velocity, rad/s (copied)
---@return AtmoPlayFlight
function Flight.start(vel, frame, ang)
    vel, ang = vel or { 0, 0, 0 }, ang or { 0, 0, 0 }
    return { vel = { vel[1] or 0, vel[2] or 0, vel[3] or 0 }, ang = { ang[1] or 0, ang[2] or 0, ang[3] or 0 },
        frame = frame, still = 0 }
end

---@class AtmoPlayFlightOptions
---@field collide boolean? flying props hit each other and wake the still ones they run into
---@field simple boolean? the cheap level: props fly as spheres hits don't turn
---@field neighbors (fun(prop: table, reach: number): table[])? collide: the still props (no flight, not carried)
---whose centers may be within reach of prop's, in atmo order
---@field wake (fun(prop: table, frame: integer))? collide: a still prop starts flying (its flight made by the caller,
---then added to the list being stepped)

---The pairs of flying props whose bounding spheres meet, by sweeping along the axis they spread most on (props in a
---line or a wall along x would all overlap on x: 1.7k props in a line along y, 1.5 million pairs a frame). The order
---along that axis is kept from the last frame and put right with an insertion sort (props move little a frame: nearly
---free), ties by atmo index, so it's the same whatever order it starts from (fights and their replays). Props that hit
---no props (Atmo off) aren't swept. For each list position, the later positions it meets, in list order
---@param w AtmoPlayFlightWorld keeps the orders
---@param bodies table[]
---@param n integer the first n are swept (props woken later in the frame are tried one by one)
---@return table<integer, integer[]>
local sweepStamp = 0

local function sweepPairs(w, bodies, n)
    sweepStamp = sweepStamp + 1
    local stamp = sweepStamp
    local minP, maxP = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for k = 1, n do
        local b = bodies[k]
        -- this sweep's fields on the prop (a stamp marks the ones swept now: no tables made a frame)
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
    -- last frame's order on this axis, without the props gone, the new ones at its end
    w.sweepOrders = w.sweepOrders or {}
    local prev = w.sweepOrders[axis] or {}
    local order, m = {}, 0
    for _, b in ipairs(prev) do
        if b.sweepAt == stamp and not b.noHits then
            m = m + 1
            order[m] = b
            b.sweepSeen = true
        end
    end
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
    -- insertion sort by (lo, atmo index)
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
    local partners = {}
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
                local list = partners[first]
                if not list then
                    list = {}
                    partners[first] = list
                end
                list[#list + 1] = second
            end
        end
    end
    for _, list in pairs(partners) do table.sort(list) end
    return partners
end

---Whether two props pass through each other: one of them doesn't hit props ("prop_hits 0"), or they overlapped
---where the map placed them (prop.ignore: a generated shape isn't blown apart)
local function passes(A, B)
    -- a prediction's copy (Flight.newPrediction) stands for its prop: `ignore` is keyed by the props
    return A.noHits or B.noHits or (A.ignore ~= nil and A.ignore[B.of or B] == true)
end

---Contacts between flying props A and B when their bounding spheres meet
local function pairBodies(A, B)
    if passes(A, B) then return end
    local pa, pb = A.pos, B.pos
    local dx, dy, dz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
    local r = (A.radius or 1) + (B.radius or 1)
    if dx * dx + dy * dy + dz * dz <= r * r then
        pairContacts(A, ptsOf(A), B, B.flight.rows, ptsOf(B), B, B)
    end
end

---One frame for every flying prop, from `frame` to the next, together. `bodies` is in atmo order; woken props are
---added to its end. A prop that came to rest or fell under the map has its flight cleared (the caller drops it)
---@param w AtmoPlayFlightWorld
---@param bodies table[] props with a flight
---@param frame integer
---@param opts AtmoPlayFlightOptions?
function Flight.step(w, bodies, frame, opts)
    opts = opts or {}
    local dt, g, simple = Flight.DT, w.gravity, opts.simple and true or false
    -- 1. moved on: gravity and thrust, then position and rotation; this frame's inertia and touch points
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
        -- one position table a flight, made at its first step (never the atmo's own or one an event keeps) and moved in
        -- place: a new table a frame for every flying prop was garbage. prop.moves counts the steps: "did it move"
        -- checks compare it, not the table (dynamics.lua's drawn copies and movedProp)
        local p = prop.pos
        if p ~= fl.posBuf then
            p = { p[1], p[2], p[3] }
            fl.posBuf = p
            prop.pos = p
        end
        p[1], p[2], p[3] = p[1] + v[1] * dt, p[2] + v[2] * dt, p[3] + v[3] * dt
        prop.moves = (prop.moves or 0) + 1
        -- a sphere looks the same however it's turned: its rotation isn't kept up (its spin still rolls it: contacts
        -- use its inertia, the same in every axis), unless a thrust on its own axes turns with it
        local seen = prop.shape ~= "sphere" or (thrust ~= nil and thrust.space == 1)
        if seen and (a[1] ~= 0 or a[2] ~= 0 or a[3] ~= 0) then
            turn(m, a[1], a[2], a[3], dt)
            orthonormalize(m)
            fl.turned = true
        end
        fl.touching, fl.gripping, fl.contacts = false, false, 0
    end
    stepStamp = stepStamp + 1 -- touch points and inertia: this frame's, when first needed (ptsOf, inertiaOf)
    -- 2. contacts: the ground, the static atmo, and (collide) each other and the still props run into
    used = 0
    local n0 = #bodies
    local collide = opts.collide
    local partners = collide and n0 > 1 and sweepPairs(w, bodies, n0) or nil
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
        if A.pos[3] - reach < 0 then -- a touch point can reach the ground (all are within its bounding sphere)
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
            -- the later props it meets: those swept, then any woken this frame (after the swept ones)
            local list = partners and partners[i]
            if list then
                for k = 1, #list do pairBodies(A, bodies[list[k]]) end
            end
            if not A.noHits then
                for j = (i < n0 and n0 or i) + 1, #bodies do pairBodies(A, bodies[j]) end
            end
            -- a moving prop wakes the still ones it runs into (they join the list: their own turn comes later)
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
                            local sPts = worldPointsInto(sp, sb, sRows, S.wakePts or {})
                            S.wakePts = sPts
                            pairContacts(A, ptsOf(A), S, sRows, sPts, S, S)
                            if used > before then
                                opts.wake(S, frame) -- gives it a flight and adds it to `bodies`
                                local sf = S.flight
                                sf.rows, sf.touching, sf.gripping = sRows, false, false
                                sf.pts, sf.ptsAt = worldPointsInto(S.pos, sb, sRows, {}), stepStamp
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
    -- the first round solves every contact; a prop's only contact, against the ground or the static atmo, is
    -- settled by it (nothing else moves that prop: another round changes nothing), so later rounds solve only the
    -- rest (a box resting on several corners, props touching each other). A rolling sphere: one contact, one round
    local coupled, nc = coupledList, 0
    for k = 1, used do
        local c = pool[k]
        solve(c)
        if c.b or c.a.flight.contacts > 1 then
            nc = nc + 1
            coupled[nc] = c
        end
    end
    for i = nc + 1, #coupled do coupled[i] = nil end
    local settle = Flight.SETTLE
    for _ = 2, Flight.ITERATIONS do
        local change = 0
        for k = 1, nc do change = change + solve(coupled[k]) end
        if change < settle then break end
    end
    -- 4. overlaps pushed apart (positions only), shared by inverse mass
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
    end
    -- the pool keeps its tables, not the props
    for k = 1, used do
        local c = pool[k]
        c.a, c.b, c.other = nil, nil, nil
    end
    -- 5. rotations shown, rest and falls
    for _, prop in ipairs(bodies) do
        local fl = prop.flight
        if fl.turned then
            -- one rotation table a flight, written in place: a new one a frame (12 keys, ~700 bytes) for every turning prop
            -- was most of the garbage (768 thrust props: ~0.5 MB a frame; the game collected 140 MB at the match's end in
            -- one go, a 1.3 s freeze). Who keeps a prop's rotation copies it (dynamics.lua's events); pos tables are still
            -- new each frame, so "did it move" checks by table (drawn copies, MGE's moved props) still see a change
            local tb, m = fl.tb, fl.rows
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
        local speed = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
        local spin = sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
        if fl.touching and speed < Flight.REST_SPEED and spin < Flight.REST_SPIN and not prop.thrust then
            fl.still = fl.still + 1
        else
            fl.still = 0
        end
        if fl.still >= Flight.REST_FRAMES or prop.pos[3] < Flight.LOWEST then prop.flight = nil end
    end
end

---Flies one prop alone (no other props) from its flight's frame to `toFrame`
---@param w AtmoPlayFlightWorld
---@param prop table with .flight, .pos, .rot (MatrixTB), .shape, .sides, .radius, .thrust, .mass, .bounce, .friction
---@param toFrame integer
---@param opts AtmoPlayFlightOptions?
---@return boolean flying false: the flight ended (at rest, or fell under the map)
function Flight.advance(w, prop, toFrame, opts)
    local list = { prop }
    while prop.flight and prop.flight.frame < toFrame do Flight.step(w, list, prop.flight.frame, opts) end
    return prop.flight ~= nil
end

---------------------------------------------------------------------------------------------------- prediction

-- Move predictions (the ghosts of drawn props, as the game shows its objects' next frames): the flights stepped on
-- ahead on copies ("shadows": a prop's fields, with its own pos and flight), so the props and their flights stay as
-- they are. What a step keeps on a prop (sweep fields, touch points, inertia) lands on the copy. The world's caches
-- (sweep orders, the near list) are the prediction's own too

---@class AtmoPlayPrediction
---@field world table the flight world with its own caches
---@field frame integer the frame the props are at (pose 0)
---@field steps integer frames stepped so far (poses 0..steps)
---@field done boolean every flight ended (at rest, fell): the last poses hold from there
---@field poses table<table, AtmoPlayPredictedPoses> by prop
---@field ring integer frames of poses kept (a ring: frame k in slot k % ring)
---@field props table[] the props with poses, in the order they got them
---@field list table[] the copies still flying
---@field shadows table<table, table> copies by prop
---@field opts AtmoPlayFlightOptions
---@field base integer the flights' frame now, counted from `frame` (Dynamics.predict keeps a prediction while they
---follow it): poses before it are dropped

---The copy of a prop a prediction steps
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
                { m[3][1], m[3][2], m[3][3] } } or nil }
    end
    pr.shadows[prop] = sh
    return sh
end

---@class AtmoPlayPredictedPoses
---@field pos number[] x y z of frame k at slot (k % ring) * 3
---@field rot number[]? r0 r1 r2 r4 r5 r6 r8 r9 r10 at slot (k % ring) * 9; nil: fixedRot every frame
---@field fixedRot table? a sphere's rotation (its looks don't change; it isn't kept up while it flies)
---@field first integer the first frame kept
---@field last integer the last frame predicted
---@field tb table the MatrixTB predictedPose fills and returns

-- A prediction's poses are numbers in two lists a prop, in a ring of `ring` frames (the ghost's window): a table per
-- prop and frame (768 props x 100 frames, a position and a rotation each) was ~150,000 live tables for the GC
local function posesFor(pr, sh, k)
    local th = sh.thrust
    local fixed = sh.shape == "sphere" and not (th and th.space == 1)
    local p = { pos = {}, rot = (not fixed) and {} or nil, fixedRot = fixed and sh.rot or nil, first = k, last = k,
        tb = { r3 = 0, r7 = 0, r11 = 0 } }
    pr.poses[sh.of] = p
    pr.props[#pr.props + 1] = sh.of
    return p
end

---Frame k's pose into its ring slot
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

---A copy's pose now as its prop's pose `pr.steps` frames ahead
local function record(pr, sh)
    local p = pr.poses[sh.of] or posesFor(pr, sh, pr.steps)
    writePose(pr, p, pr.steps, sh.pos, sh.rot)
end

---A prediction of `bodies` (flying props, atmo order) from `frame` on; Flight.predictStep moves it ahead
---@param w AtmoPlayFlightWorld
---@param bodies table[]
---@param frame integer
---@param opts AtmoPlayFlightOptions? as the flights are stepped (neighbors: the still props near a prop's pos)
---@param ring integer? frames of poses kept (default 128): at least the frames read ahead of the flights, plus one
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
        -- the still props near the copy, as copies (one woken in the prediction has a flight: not still any more)
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
            -- still until now: its pose for the frames before (those the ring holds)
            local from = math.max(0, pr.steps - pr.ring + 1)
            local p = posesFor(pr, S, from)
            for k = from, pr.steps do writePose(pr, p, k, S.pos, S.rot) end
            S.pos = { S.pos[1], S.pos[2], S.pos[3] } -- its own table: this step pushes it in place
            S.flight = Flight.start(nil, at)
            pr.list[#pr.list + 1] = S
        end
    end
    pr.done = #pr.list == 0
    return pr
end

local function byAtmoIndex(a, b) return (a.index or 0) < (b.index or 0) end

---Moves a prediction `count` frames ahead (fewer when every flight ends)
---@param pr AtmoPlayPrediction
---@param count integer
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
        if not sorted then table.sort(kept, byAtmoIndex) end -- woken ones join in atmo order, as the flights do
        pr.list = kept
        pr.done = #kept == 0
    end
end

---Drops the poses before frame `base` of the prediction (the flights are past them); a prop's last pose stays
---@param pr AtmoPlayPrediction
---@param base integer
function Flight.predictTrim(pr, base)
    for _, p in pairs(pr.poses) do
        local from = math.min(base, p.last)
        if from > p.first then p.first = from end -- the ring's slots are written over as it goes on
    end
end

---A prop's predicted pose `k` frames ahead (k can be partway between two frames: the position blended, the nearer
---rotation). Past the frames predicted so far (or after its flight ended) its last pose. nil: no prediction for it
---@param pr AtmoPlayPrediction
---@param prop table
---@param k number
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

Flight.IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0 }

NS.Flight = Flight
return Flight
