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
        x, y, z = 2 * sides[1], 2 * sides[1], sides[2] + 2 * sides[1] -- as a box around the pill
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
        local mass = prop.mass or Flight.MASS
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

local function toTB(m)
    return { r0 = m[1][1], r1 = m[1][2], r2 = m[1][3], r3 = 0, r4 = m[2][1], r5 = m[2][2], r6 = m[2][3], r7 = 0,
        r8 = m[3][1], r9 = m[3][2], r10 = m[3][3], r11 = 0 }
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
    local w = { gravity = gravity or Flight.GRAVITY, cellSize = Flight.CELL, cells = {}, big = {} }
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

---The static colliders whose bounding spheres reach a sphere at p of radius r (each once, in a stable order)
local function nearby(w, p, r, out)
    local n, seen = 0, {}
    local function try(c)
        if seen[c] then return end
        seen[c] = true
        local dx, dy, dz = c.pos[1] - p[1], c.pos[2] - p[2], c.pos[3] - p[3]
        local reach = c.radius + r
        if dx * dx + dy * dy + dz * dz <= reach * reach then
            n = n + 1
            out[n] = c
        end
    end
    for _, c in ipairs(w.big) do try(c) end
    local size = w.cellSize
    for cx = math.floor((p[1] - r) / size), math.floor((p[1] + r) / size) do
        for cy = math.floor((p[2] - r) / size), math.floor((p[2] + r) / size) do
            local list = w.cells[cellKey(cx, cy)]
            if list then
                for _, c in ipairs(list) do try(c) end
            end
        end
    end
    for i = n + 1, #out do out[i] = nil end
    return n
end

---------------------------------------------------------------------------------------------------- contacts

-- A contact: a (a flying prop), b (another, or nil: static / ground), the point, the normal n (out of b, into
-- a's side), its depth, two tangents, the bounce it aims for, the friction cap, the impulses so far

---The world points of a flying prop's touch points
local function worldPoints(prop, b, rows)
    local p, out = prop.pos, {}
    for i, l in ipairs(b.points) do
        out[i] = { p[1] + rows[1][1] * l[1] + rows[1][2] * l[2] + rows[1][3] * l[3],
            p[2] + rows[2][1] * l[1] + rows[2][2] * l[2] + rows[2][3] * l[3],
            p[3] + rows[3][1] * l[1] + rows[3][2] * l[2] + rows[3][3] * l[3], l[4] }
    end
    return out
end

local function tangents(nx, ny, nz)
    local ax, ay, az
    if abs(nx) < 0.6 then ax, ay, az = 1, 0, 0 else ax, ay, az = 0, 1, 0 end
    -- t1 = a x n, normalized; t2 = n x t1
    local t1x, t1y, t1z = ay * nz - az * ny, az * nx - ax * nz, ax * ny - ay * nx
    local l = sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
    t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
    return t1x, t1y, t1z, ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
end

local function addContact(list, a, b, px, py, pz, nx, ny, nz, depth, other)
    local t1x, t1y, t1z, t2x, t2y, t2z = tangents(nx, ny, nz)
    list[#list + 1] = { a = a, b = b, p = { px, py, pz }, n = { nx, ny, nz }, depth = depth,
        t1 = { t1x, t1y, t1z }, t2 = { t2x, t2y, t2z }, other = other, jn = 0, jt1 = 0, jt2 = 0 }
end

local AXIS_TOL = 1e-4 -- a corner this close to a box's side still counts as inside it (faces flush)

---Box against box by separating axes (their 3 + 3 faces and 9 edge pairs): the axis of least overlap is the
---normal; the contacts are each box's corners inside the other (flush faces too), or one point between the
---two when only edges cross. Corner tests alone miss flush faces of equal boxes (their corners sit on edges)
local function boxBox(list, A, fa, ptsA, B, fb, ptsB, bodyB, other)
    local ax = { { fa[1][1], fa[2][1], fa[3][1] }, { fa[1][2], fa[2][2], fa[3][2] }, { fa[1][3], fa[2][3], fa[3][3] } }
    local bx = { { fb[1][1], fb[2][1], fb[3][1] }, { fb[1][2], fb[2][2], fb[3][2] }, { fb[1][3], fb[2][3], fb[3][3] } }
    local ha = { A.sides[1] / 2, A.sides[2] / 2, A.sides[3] / 2 }
    local hb = { B.sides[1] / 2, B.sides[2] / 2, B.sides[3] / 2 }
    local dx, dy, dz = B.pos[1] - A.pos[1], B.pos[2] - A.pos[2], B.pos[3] - A.pos[3]
    local best, nx, ny, nz = math.huge, 0, 0, 1
    local function try(lx, ly, lz, edge)
        local len = sqrt(lx * lx + ly * ly + lz * lz)
        if len < 1e-6 then return true end
        lx, ly, lz = lx / len, ly / len, lz / len
        local ra, rb = 0, 0
        for i = 1, 3 do
            ra = ra + ha[i] * abs(ax[i][1] * lx + ax[i][2] * ly + ax[i][3] * lz)
            rb = rb + hb[i] * abs(bx[i][1] * lx + bx[i][2] * ly + bx[i][3] * lz)
        end
        local dist = dx * lx + dy * ly + dz * lz
        local over = ra + rb - abs(dist)
        if over < 0 then return false end
        -- an edge axis only when clearly better (faces give steadier contacts)
        if over < (edge and best * 0.95 - 1e-4 or best) then
            best = over
            if dist > 0 then nx, ny, nz = -lx, -ly, -lz else nx, ny, nz = lx, ly, lz end -- out of B, toward A
        end
        return true
    end
    for i = 1, 3 do
        if not try(ax[i][1], ax[i][2], ax[i][3]) or not try(bx[i][1], bx[i][2], bx[i][3]) then return end
    end
    for i = 1, 3 do
        for j = 1, 3 do
            local u, v = ax[i], bx[j]
            if not try(u[2] * v[3] - u[3] * v[2], u[3] * v[1] - u[1] * v[3], u[1] * v[2] - u[2] * v[1], true) then
                return
            end
        end
    end
    -- how far each box reaches along n
    local ra, rb = 0, 0
    for i = 1, 3 do
        ra = ra + ha[i] * abs(ax[i][1] * nx + ax[i][2] * ny + ax[i][3] * nz)
        rb = rb + hb[i] * abs(bx[i][1] * nx + bx[i][2] * ny + bx[i][3] * nz)
    end
    local topB = B.pos[1] * nx + B.pos[2] * ny + B.pos[3] * nz + rb -- B's side facing A
    local bottomA = A.pos[1] * nx + A.pos[2] * ny + A.pos[3] * nz - ra -- A's side facing B
    local before = #list
    local function inside(q, pos, axes, h)
        local qx, qy, qz = q[1] - pos[1], q[2] - pos[2], q[3] - pos[3]
        for i = 1, 3 do
            if abs(qx * axes[i][1] + qy * axes[i][2] + qz * axes[i][3]) > h[i] + AXIS_TOL then return false end
        end
        return true
    end
    for _, q in ipairs(ptsA) do
        local depth = topB - (q[1] * nx + q[2] * ny + q[3] * nz)
        if depth > 0 and inside(q, B.pos, bx, hb) then
            addContact(list, A, bodyB, q[1], q[2], q[3], nx, ny, nz, depth, other)
        end
    end
    for _, q in ipairs(ptsB) do
        local depth = (q[1] * nx + q[2] * ny + q[3] * nz) - bottomA
        if depth > 0 and inside(q, A.pos, ax, ha) then
            addContact(list, A, bodyB, q[1], q[2], q[3], nx, ny, nz, depth, other)
        end
    end
    if #list == before then
        -- edges crossing: one point between the two boxes' nearest corners along n
        local function support(pos, axes, h, sx, sy, sz)
            local px, py, pz = pos[1], pos[2], pos[3]
            for i = 1, 3 do
                local k = (axes[i][1] * sx + axes[i][2] * sy + axes[i][3] * sz) >= 0 and h[i] or -h[i]
                px, py, pz = px + axes[i][1] * k, py + axes[i][2] * k, pz + axes[i][3] * k
            end
            return px, py, pz
        end
        local px, py, pz = support(A.pos, ax, ha, -nx, -ny, -nz)
        local qx, qy, qz = support(B.pos, bx, hb, nx, ny, nz)
        addContact(list, A, bodyB, (px + qx) / 2, (py + qy) / 2, (pz + qz) / 2, nx, ny, nz, best, other)
    end
end

---Contacts between flying prop A (its world points) and a shape B (static collider or flying prop: shape,
---sides, pos, rows f, and its world points), each way. bodyB: nil for a static one. A touches as its body's
---shape (a sphere on the simple level)
local function pairContacts(list, A, ptsA, B, f, ptsB, bodyB, other)
    local fa, shapeA, sidesA = A.flight.rows, A.body.shape, A.body.sides
    local shapeB, sidesB = B.shape, B.sides
    if bodyB then shapeB, sidesB = bodyB.body.shape, bodyB.body.sides end
    if shapeA == "box" and shapeB == "box" then return boxBox(list, A, fa, ptsA, B, f, ptsB, bodyB, other) end
    for _, q in ipairs(ptsA) do
        local d, nx, ny, nz = surfaceAt(shapeB, sidesB, B.pos, f, q[1], q[2], q[3])
        if d < q[4] then
            addContact(list, A, bodyB, q[1] - nx * q[4], q[2] - ny * q[4], q[3] - nz * q[4], nx, ny, nz, q[4] - d, other)
        end
    end
    for _, q in ipairs(ptsB) do
        local d, nx, ny, nz = surfaceAt(shapeA, sidesA, A.pos, fa, q[1], q[2], q[3])
        if d < q[4] then
            -- the way out of A is into B: the normal out of B is its opposite
            addContact(list, A, bodyB, q[1], q[2], q[3], -nx, -ny, -nz, q[4] - d, other)
        end
    end
end

---------------------------------------------------------------------------------------------------- solving

---v (world) through a flying prop's inverse inertia: R * diag(invI) * R^T * v
local function invInertia(prop, x, y, z)
    local m, i = prop.flight.rows, prop.body.invI
    local lx = (m[1][1] * x + m[2][1] * y + m[3][1] * z) * i[1]
    local ly = (m[1][2] * x + m[2][2] * y + m[3][2] * z) * i[2]
    local lz = (m[1][3] * x + m[2][3] * y + m[3][3] * z) * i[3]
    return m[1][1] * lx + m[1][2] * ly + m[1][3] * lz, m[2][1] * lx + m[2][2] * ly + m[2][3] * lz,
        m[3][1] * lx + m[3][2] * ly + m[3][3] * lz
end

---The velocity of a flying prop's material at world point p
local function pointVel(prop, p)
    if not prop then return 0, 0, 0 end
    local fl, q = prop.flight, prop.pos
    local rx, ry, rz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
    local w, v = fl.ang, fl.vel
    return v[1] + w[2] * rz - w[3] * ry, v[2] + w[3] * rx - w[1] * rz, v[3] + w[1] * ry - w[2] * rx
end

---How hard it is to change the speed along direction d at point p (1 / effective mass)
local function resistance(prop, p, dx, dy, dz)
    if not prop then return 0 end
    local q = prop.pos
    local rx, ry, rz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
    -- (r x d)
    local cx, cy, cz = ry * dz - rz * dy, rz * dx - rx * dz, rx * dy - ry * dx
    local ix, iy, iz = invInertia(prop, cx, cy, cz)
    -- (I^-1 (r x d)) x r . d
    local kx, ky, kz = iy * rz - iz * ry, iz * rx - ix * rz, ix * ry - iy * rx
    return prop.body.invMass + kx * dx + ky * dy + kz * dz
end

---An impulse j along d at point p: + on prop a, - on prop b
local function push(prop, p, jx, jy, jz, sign)
    if not prop then return end
    local fl, q, inv = prop.flight, prop.pos, prop.body.invMass * sign
    local v, w = fl.vel, fl.ang
    v[1], v[2], v[3] = v[1] + jx * inv, v[2] + jy * inv, v[3] + jz * inv
    local rx, ry, rz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
    local ix, iy, iz = invInertia(prop, ry * jz - rz * jy, rz * jx - rx * jz, rx * jy - ry * jx)
    w[1], w[2], w[3] = w[1] + ix * sign, w[2] + iy * sign, w[3] + iz * sign
end

local function relVel(c)
    local ax, ay, az = pointVel(c.a, c.p)
    local bx, by, bz = pointVel(c.b, c.p)
    return ax - bx, ay - by, az - bz
end

local function prepare(c)
    local n = c.n
    c.kn = resistance(c.a, c.p, n[1], n[2], n[3]) + resistance(c.b, c.p, n[1], n[2], n[3])
    c.kt1 = resistance(c.a, c.p, c.t1[1], c.t1[2], c.t1[3]) + resistance(c.b, c.p, c.t1[1], c.t1[2], c.t1[3])
    c.kt2 = resistance(c.a, c.p, c.t2[1], c.t2[2], c.t2[3]) + resistance(c.b, c.p, c.t2[1], c.t2[2], c.t2[3])
    local vx, vy, vz = relVel(c)
    local vn = vx * n[1] + vy * n[2] + vz * n[3]
    local o, a = c.other, c.a
    local e = Flight.restitution(max(a.bounce or 0, o and o.bounce or 0))
    c.bias = vn < -Flight.BOUNCE_MIN and -e * vn or 0
    c.limit = Flight.frictionLimit(a.friction, o and o.friction)
end

local function solve(c)
    local n = c.n
    local vx, vy, vz = relVel(c)
    local vn = vx * n[1] + vy * n[2] + vz * n[3]
    local dj = (c.bias - vn) / c.kn
    local old = c.jn
    c.jn = max(old + dj, 0)
    dj = c.jn - old
    if dj ~= 0 then
        push(c.a, c.p, n[1] * dj, n[2] * dj, n[3] * dj, 1)
        push(c.b, c.p, n[1] * dj, n[2] * dj, n[3] * dj, -1)
    end
    -- friction: the cone (MU x the normal impulse so far), capped by the game's limit
    local cap = Flight.MU * c.jn
    if c.limit and c.limit < cap then cap = c.limit end
    vx, vy, vz = relVel(c)
    local t1, t2 = c.t1, c.t2
    local d1 = -(vx * t1[1] + vy * t1[2] + vz * t1[3]) / c.kt1
    local d2 = -(vx * t2[1] + vy * t2[2] + vz * t2[3]) / c.kt2
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
        local jx, jy, jz = t1[1] * d1 + t2[1] * d2, t1[2] * d1 + t2[2] * d2, t1[3] * d1 + t2[3] * d2
        push(c.a, c.p, jx, jy, jz, 1)
        push(c.b, c.p, jx, jy, jz, -1)
    end
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

---One frame for every flying prop, from `frame` to the next, together. `bodies` is in atmo order; woken props are
---added to its end. A prop that came to rest or fell under the map has its flight cleared (the caller drops it)
---@param w AtmoPlayFlightWorld
---@param bodies table[] props with a flight
---@param frame integer
---@param opts AtmoPlayFlightOptions?
function Flight.step(w, bodies, frame, opts)
    opts = opts or {}
    local dt, g, simple = Flight.DT, w.gravity, opts.simple and true or false
    -- 1. moved on: gravity and thrust, then position and rotation
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
        local p = prop.pos
        prop.pos = { p[1] + v[1] * dt, p[2] + v[2] * dt, p[3] + v[3] * dt }
        if a[1] ~= 0 or a[2] ~= 0 or a[3] ~= 0 then
            turn(m, a[1], a[2], a[3], dt)
            orthonormalize(m)
            fl.turned = true
        end
        fl.touching, fl.gripping = false, false
    end
    -- 2. contacts: the ground, the static atmo, and (collide) each other and the still props run into
    local contacts, near = {}, {}
    local i = 1
    while i <= #bodies do
        local A = bodies[i]
        local b, fl = A.body, A.flight
        local ptsA = worldPoints(A, b, fl.rows)
        for _, q in ipairs(ptsA) do
            if q[3] - q[4] < 0 then addContact(contacts, A, nil, q[1], q[2], q[3] - q[4], 0, 0, 1, q[4] - q[3], nil) end
        end
        local reach = A.radius or 1
        for k = 1, nearby(w, A.pos, reach, near) do
            local c = near[k]
            pairContacts(contacts, A, ptsA, c, c.frame, c.points, nil, c)
        end
        if opts.collide then
            for j = i + 1, #bodies do
                local B = bodies[j]
                local dx, dy, dz = B.pos[1] - A.pos[1], B.pos[2] - A.pos[2], B.pos[3] - A.pos[3]
                local r = reach + (B.radius or 1)
                if dx * dx + dy * dy + dz * dz <= r * r then
                    local bb = bodyOf(B, simple)
                    B.flight.rows = B.flight.rows or rowsOf(B.rot or Flight.IDENTITY)
                    pairContacts(contacts, A, ptsA, B, B.flight.rows, worldPoints(B, bb, B.flight.rows), B, B)
                end
            end
            -- a moving prop wakes the still ones it runs into (they join the list: their own turn comes later)
            local moving = fl.still == 0
            if moving and opts.neighbors and opts.wake then
                for _, S in ipairs(opts.neighbors(A, reach)) do
                    if not S.flight and not S.entry then
                        local dx, dy, dz = S.pos[1] - A.pos[1], S.pos[2] - A.pos[2], S.pos[3] - A.pos[3]
                        local r = reach + (S.radius or 1)
                        if dx * dx + dy * dy + dz * dz <= r * r then
                            local before = #contacts
                            local sRows = rowsOf(S.rot or Flight.IDENTITY)
                            pairContacts(contacts, A, ptsA, S, sRows, worldPoints(S, bodyOf(S, simple), sRows), S, S)
                            if #contacts > before then
                                opts.wake(S, frame) -- gives it a flight and adds it to `bodies`
                                S.flight.rows = sRows
                                S.flight.touching = false
                            end
                        end
                    end
                end
            end
        end
        i = i + 1
    end
    -- 3. impulses
    for _, c in ipairs(contacts) do
        prepare(c)
        c.a.flight.touching = true
        if c.b then c.b.flight.touching = true end
        if c.limit ~= 0 then
            c.a.flight.gripping = true
            if c.b then c.b.flight.gripping = true end
        end
    end
    for _ = 1, Flight.ITERATIONS do
        for _, c in ipairs(contacts) do solve(c) end
    end
    -- 4. overlaps pushed apart (positions only), shared by inverse mass
    for _, c in ipairs(contacts) do
        local over = c.depth - Flight.SLOP
        if over > 0 then
            local ia, ib = c.a.body.invMass, c.b and c.b.body.invMass or 0
            local k = over * Flight.PUSH / (ia + ib)
            local n, pa = c.n, c.a.pos
            pa[1], pa[2], pa[3] = pa[1] + n[1] * k * ia, pa[2] + n[2] * k * ia, pa[3] + n[3] * k * ia
            if c.b then
                local pb = c.b.pos
                pb[1], pb[2], pb[3] = pb[1] - n[1] * k * ib, pb[2] - n[2] * k * ib, pb[3] - n[3] * k * ib
            end
        end
    end
    -- 5. rotations shown, rest and falls
    for _, prop in ipairs(bodies) do
        local fl = prop.flight
        if fl.turned then
            prop.rot = toTB(fl.rows)
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

Flight.IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0 }

NS.Flight = Flight
return Flight
