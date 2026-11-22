-- Drawn flight (docs/atmo-play-plan.md, section 7): a small physics step for props that move while no pool
-- object carries them (thrust props, props let go while moving). Pure Lua, no engine calls.
-- Measured in game (probe_thrust.lua): a match frame is 0.006 s, stepped as `v += a * dt`, then `pos += v * dt`;
-- a thrust line is a force for one step on its push frames (dv = F / mass * dt); bounce rebounds the normal speed
-- by e = 0.096 x (bounce - 0.48); friction: the lower value of the two sides wins, -10000 is frictionless,
-- -9999 a ~2 N limit (`mu = friction + 10000` on ~2 contacts), 0 and up full grip (the speed x0.89 a frame).
-- Simple on purpose: the prop is a sphere (its smallest half side), it meets only the static atmo and the ground
-- (always at z = 0), not other props or players (near one it's real by then). It spins on at the angular
-- velocity it had (world axes, rad/s, as ODE's get_obj_angular_vel; the game has no torque for objects, RPH
-- spins them with set_obj_angular_vel too); the spin is only seen (its rotation, a thrust on its own axes), it
-- doesn't roll the sphere. Touching something with friction slows it by GRIP a frame.

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

---@class AtmoPlayThrust
---@field every integer pushes on the steps from frames 0, N, 2N ... (into 1, N + 1 ...)
---@field force number[] x y z
---@field space integer 0 world axes, 1 the prop's own

---@class AtmoPlayFlight
---@field vel number[] linear velocity, per second
---@field ang number[]? angular velocity, rad/s, world axes (nil: no spin)
---@field frame integer the frame its prop's pos is at
---@field still integer frames in a row at rest on something

---@class AtmoPlayFlightWorld
---@field gravity number[]
---@field cellSize number
---@field cells table<integer, AtmoPlayCollider[]>
---@field big AtmoPlayCollider[] colliders over too many cells: looked at every time

local Flight = {
    DT = 0.006,
    GRAVITY = { 0, 0, -9.82 },
    MASS = 1, -- a prop without a mass line
    GRIP = 0.11, -- full grip: the share of the sliding speed lost each frame
    CONTACTS = 2, -- friction limit: (friction + 10000) N on this many contacts
    NO_FRICTION = -10000,
    REST_SPEED = 0.05,
    REST_SPIN = 0.1,
    REST_FRAMES = 10, -- this many frames at rest on something: the flight ends
    LOWEST = -100, -- below this the flight ends (under the ground: fell through)
    CELL = 8,
    MAX_CELLS = 64, -- a collider over more cells than this goes in `big`
}

local cellKey = NS.Pool.cellKey

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
    return math.max(0, 0.096 * ((bounce or 0) - 0.48))
end

---The sliding speed a frame of contact takes off (frictionA / B: the two sides' friction lines, nil: grip)
---@param speed number the sliding speed
---@param frictionA number?
---@param frictionB number?
---@param mass number
---@return number
function Flight.frictionLoss(speed, frictionA, frictionB, mass)
    local f = math.min(frictionA or 0, frictionB or 0)
    if f <= Flight.NO_FRICTION then return 0 end
    local limit = Flight.CONTACTS * (f + 10000) / mass * Flight.DT
    return math.min(limit, Flight.GRIP * speed, speed)
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

---The sphere a prop flies as: its smallest half side (flat props sit low), a sphere's radius, a capsule's
---@param prop AtmoPlayCollider
---@return number
function Flight.radiusOf(prop)
    local s = prop.sides
    if prop.shape == "sphere" or prop.shape == "cylinder" then return s[1] end
    return math.min(s[1], s[2], s[3]) / 2
end

---------------------------------------------------------------------------------------------------- the world

---The static atmo, listed by x / y cell for quick lookups
---@param colliders AtmoPlayCollider[]? static ones
---@param gravity number[]?
---@return AtmoPlayFlightWorld
function Flight.newWorld(colliders, gravity)
    local w = { gravity = gravity or Flight.GRAVITY, cellSize = Flight.CELL, cells = {}, big = {} }
    for _, c in ipairs(colliders or {}) do
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

---Gravity as a gamerule string ("0 0 -9.82"), nil when it isn't three numbers
---@param text string?
---@return number[]?
function Flight.parseGravity(text)
    local n = {}
    for v in tostring(text or ""):gmatch("%S+") do n[#n + 1] = tonumber(v) end
    if #n == 3 and n[1] and n[2] and n[3] then return n end
    return nil
end

---Where a point is against a collider: its distance out of the surface (negative inside) and the way out
---@param c AtmoPlayCollider
---@param x number
---@param y number
---@param z number
---@return number distance, number nx, number ny, number nz
function Flight.surface(c, x, y, z)
    local dx, dy, dz = x - c.pos[1], y - c.pos[2], z - c.pos[3]
    local f = c.frame
    if c.shape == "sphere" then
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < 1e-9 then return -c.sides[1], 0, 0, 1 end
        return d - c.sides[1], dx / d, dy / d, dz / d
    end
    -- into the collider's own axes (frame is local to world, so its transpose)
    local lx = dx * f[1][1] + dy * f[2][1] + dz * f[3][1]
    local ly = dx * f[1][2] + dy * f[2][2] + dz * f[3][2]
    local lz = dx * f[1][3] + dy * f[2][3] + dz * f[3][3]
    local ox, oy, oz, d -- the way out, local
    if c.shape == "cylinder" then
        local half = c.sides[2] / 2
        local qz = math.max(-half, math.min(half, lz))
        local ex, ey, ez = lx, ly, lz - qz
        local len = math.sqrt(ex * ex + ey * ey + ez * ez)
        if len < 1e-9 then
            ox, oy, oz, d = 0, 0, 1, -c.sides[1]
        else
            ox, oy, oz, d = ex / len, ey / len, ez / len, len - c.sides[1]
        end
    else
        local hx, hy, hz = c.sides[1] / 2, c.sides[2] / 2, c.sides[3] / 2
        local qx, qy, qz = math.max(-hx, math.min(hx, lx)), math.max(-hy, math.min(hy, ly)), math.max(-hz, math.min(hz, lz))
        local ex, ey, ez = lx - qx, ly - qy, lz - qz
        local len = math.sqrt(ex * ex + ey * ey + ez * ez)
        if len > 1e-9 then
            ox, oy, oz, d = ex / len, ey / len, ez / len, len
        else
            -- inside: out through the nearest face
            local px, py, pz = hx - math.abs(lx), hy - math.abs(ly), hz - math.abs(lz)
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

---The static colliders that can touch a sphere at x, y of radius r
local function nearby(w, x, y, r, out)
    local n = 0
    for _, c in ipairs(w.big) do
        n = n + 1
        out[n] = c
    end
    local size = w.cellSize
    for cx = math.floor((x - r) / size), math.floor((x + r) / size) do
        for cy = math.floor((y - r) / size), math.floor((y + r) / size) do
            local list = w.cells[cellKey(cx, cy)]
            if list then
                for _, c in ipairs(list) do
                    n = n + 1
                    out[n] = c
                end
            end
        end
    end
    for i = n + 1, #out do out[i] = nil end
    return n
end

---------------------------------------------------------------------------------------------------- stepping

local GROUND = { friction = nil, bounce = nil } -- the ground's lines: the game's defaults

---One contact: the sphere pushed out along n by `depth`, its velocity bounced and slowed
---@return boolean gripping the two sides have friction (the spin slows too)
local function contact(p, v, nx, ny, nz, depth, other, prop, mass)
    p[1], p[2], p[3] = p[1] + nx * depth, p[2] + ny * depth, p[3] + nz * depth
    local gripping = math.min(prop.friction or 0, other.friction or 0) > Flight.NO_FRICTION
    local vn = v[1] * nx + v[2] * ny + v[3] * nz
    if vn >= 0 then return gripping end -- already leaving
    local e = Flight.restitution(math.max(prop.bounce or 0, other.bounce or 0))
    local k = (1 + e) * vn
    v[1], v[2], v[3] = v[1] - k * nx, v[2] - k * ny, v[3] - k * nz
    -- the sliding part
    local tx, ty, tz = v[1] - (v[1] * nx + v[2] * ny + v[3] * nz) * nx, v[2] - (v[1] * nx + v[2] * ny + v[3] * nz) * ny,
        v[3] - (v[1] * nx + v[2] * ny + v[3] * nz) * nz
    local speed = math.sqrt(tx * tx + ty * ty + tz * tz)
    if speed < 1e-9 then return gripping end
    local loss = Flight.frictionLoss(speed, prop.friction, other.friction, mass) / speed
    v[1], v[2], v[3] = v[1] - tx * loss, v[2] - ty * loss, v[3] - tz * loss
    return gripping
end

---A MatrixTB (local to world, Driver.matrixTB's layout) as rows
local function rowsOf(m)
    return { { m.r0, m.r1, m.r2 }, { m.r4, m.r5, m.r6 }, { m.r8, m.r9, m.r10 } }
end

---Rows m turned by angular velocity w for dt (Rodrigues, world axes): Q * m, in place
local function turn(m, wx, wy, wz, dt)
    local w = math.sqrt(wx * wx + wy * wy + wz * wz)
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

---Rows m back to a rotation (Gram-Schmidt on its columns: steps add up rounding) as a new MatrixTB
local function toTB(m)
    local ax, ay, az = m[1][1], m[2][1], m[3][1]
    local n = math.sqrt(ax * ax + ay * ay + az * az)
    ax, ay, az = ax / n, ay / n, az / n
    local bx, by, bz = m[1][2], m[2][2], m[3][2]
    local d = ax * bx + ay * by + az * bz
    bx, by, bz = bx - d * ax, by - d * ay, bz - d * az
    n = math.sqrt(bx * bx + by * by + bz * bz)
    bx, by, bz = bx / n, by / n, bz / n
    local cx, cy, cz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
    return { r0 = ax, r1 = bx, r2 = cx, r3 = 0, r4 = ay, r5 = by, r6 = cy, r7 = 0, r8 = az, r9 = bz, r10 = cz, r11 = 0 }
end

---Flies a prop from its flight's frame to `toFrame`; its pos becomes a new table when it moved
---@param w AtmoPlayFlightWorld
---@param prop AtmoPlayCollider|table with .flight, .pos, .rot (MatrixTB), .thrust, .mass, .bounce, .friction
---@param toFrame integer
---@return boolean flying false: the flight ended (at rest, or fell under the map); prop.flight is cleared
function Flight.advance(w, prop, toFrame)
    local fl = prop.flight
    if not fl then return false end
    if toFrame <= fl.frame then return true end
    local dt, g = Flight.DT, w.gravity
    local mass = prop.mass or Flight.MASS
    local r = prop.flightRadius or Flight.radiusOf(prop)
    prop.flightRadius = r
    local thrust = prop.thrust
    local a = fl.ang -- spinning: its rotation turns each step (rows m), a thrust on its own axes with it
    local m = a and rowsOf(prop.rot or Flight.IDENTITY) or nil
    local tx, ty, tz = 0, 0, 0
    local turning = thrust and thrust.space == 1 and a ~= nil
    if thrust and not turning then
        tx, ty, tz = Flight.thrustWorld(thrust, prop.rot)
        tx, ty, tz = tx / mass * dt, ty / mass * dt, tz / mass * dt
    end
    local p = { prop.pos[1], prop.pos[2], prop.pos[3] }
    local v = fl.vel
    local near = prop.flightNear or {}
    prop.flightNear = near
    local function finish()
        prop.pos = p
        if m then prop.rot = toTB(m) end
    end
    for frame = fl.frame, toFrame - 1 do
        v[1], v[2], v[3] = v[1] + g[1] * dt, v[2] + g[2] * dt, v[3] + g[3] * dt
        if thrust and Flight.pushes(thrust, frame) then
            if turning then
                local f = thrust.force
                tx = (m[1][1] * f[1] + m[1][2] * f[2] + m[1][3] * f[3]) / mass * dt
                ty = (m[2][1] * f[1] + m[2][2] * f[2] + m[2][3] * f[3]) / mass * dt
                tz = (m[3][1] * f[1] + m[3][2] * f[2] + m[3][3] * f[3]) / mass * dt
            end
            v[1], v[2], v[3] = v[1] + tx, v[2] + ty, v[3] + tz
        end
        p[1], p[2], p[3] = p[1] + v[1] * dt, p[2] + v[2] * dt, p[3] + v[3] * dt
        if a then turn(m, a[1], a[2], a[3], dt) end
        local touching, gripping = false, false
        if p[3] - r < 0 then
            gripping = contact(p, v, 0, 0, 1, r - p[3], GROUND, prop, mass) or gripping
            touching = true
        end
        for i = 1, nearby(w, p[1], p[2], r, near) do
            local d, nx, ny, nz = Flight.surface(near[i], p[1], p[2], p[3])
            if d < r then
                gripping = contact(p, v, nx, ny, nz, r - d, near[i], prop, mass) or gripping
                touching = true
            end
        end
        local spin = 0
        if a then
            if gripping then
                local keep = 1 - Flight.GRIP
                a[1], a[2], a[3] = a[1] * keep, a[2] * keep, a[3] * keep
            end
            spin = math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
        end
        local speed = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
        if touching and speed < Flight.REST_SPEED and spin < Flight.REST_SPIN and not thrust then
            fl.still = fl.still + 1
        else
            fl.still = 0
        end
        if fl.still >= Flight.REST_FRAMES or p[3] < Flight.LOWEST then
            finish()
            prop.flight = nil
            return false
        end
    end
    fl.frame = toFrame
    finish()
    return true
end

Flight.IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0 }

---A new flight for a prop at its pos
---@param vel number[]? per second (copied)
---@param frame integer the frame its pos is at
---@param ang number[]? angular velocity, rad/s (copied; nil or ~0: no spin)
---@return AtmoPlayFlight
function Flight.start(vel, frame, ang)
    vel = vel or { 0, 0, 0 }
    local spin = ang and math.sqrt((ang[1] or 0) ^ 2 + (ang[2] or 0) ^ 2 + (ang[3] or 0) ^ 2) or 0
    return { vel = { vel[1] or 0, vel[2] or 0, vel[3] or 0 }, frame = frame, still = 0,
        ang = spin > 1e-9 and { ang[1] or 0, ang[2] or 0, ang[3] or 0 } or nil }
end

NS.Flight = Flight
return Flight
