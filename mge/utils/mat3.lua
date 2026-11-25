-- Minimal 3x3 matrix helpers (row-major number[][]), standard right-handed rotations

---@class Mat3
local Mat3 = {
    IDENTITY = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
}

---@param a number[][]
---@param b number[][]
---@return number[][]
function Mat3.mul(a, b)
    local r = {}
    for i = 1, 3 do
        r[i] = {}
        for j = 1, 3 do
            r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
        end
    end
    return r
end

---@param a number[][]
---@return number[][]
function Mat3.transpose(a)
    return {
        { a[1][1], a[2][1], a[3][1] },
        { a[1][2], a[2][2], a[3][2] },
        { a[1][3], a[2][3], a[3][3] },
    }
end

---@param m number[][]
---@param v number[]
---@return number[]
function Mat3.apply(m, v)
    return {
        m[1][1] * v[1] + m[1][2] * v[2] + m[1][3] * v[3],
        m[2][1] * v[1] + m[2][2] * v[2] + m[2][3] * v[3],
        m[3][1] * v[1] + m[3][2] * v[2] + m[3][3] * v[3],
    }
end

---@param t number radians
function Mat3.rotX(t)
    local c, s = math.cos(t), math.sin(t)
    return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } }
end

---@param t number radians
function Mat3.rotY(t)
    local c, s = math.cos(t), math.sin(t)
    return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } }
end

---@param t number radians
function Mat3.rotZ(t)
    local c, s = math.cos(t), math.sin(t)
    return { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } }
end

---rotX(x) * rotY(y) * rotZ(z) from angles in degrees, the inverse of toEulerXYZ (which gives radians): the
---Rot rows' and engageplayerrot's x y z
---@param x number degrees
---@param y number degrees
---@param z number degrees
---@return number[][]
function Mat3.fromEulerDegrees(x, y, z)
    return Mat3.mul(Mat3.rotX(math.rad(x)), Mat3.mul(Mat3.rotY(math.rad(y)), Mat3.rotZ(math.rad(z))))
end

---Angles x, y, z (radians) with m = rotX(x) * rotY(y) * rotZ(z), the order MGE's rotate tool
---applies rotations in (RotatingOld.SetRotPos: z, then y, then x)
---@param m number[][]
---@return number x, number y, number z
function Mat3.toEulerXYZ(m)
    local sy = math.max(-1, math.min(1, m[1][3]))
    local y = math.asin(sy)
    local atan2 = math.atan2 or math.atan -- game Lua has atan2, newer Lua takes two args in atan
    if math.abs(sy) < 0.999999 then
        return atan2(-m[2][3], m[3][3]), y, atan2(-m[1][2], m[1][1])
    end
    -- y = +-90 degrees: x and z turn around the same axis, put it all in x
    return atan2(m[3][2], m[2][2]), y, 0
end

---Rotation by t radians around the unit vector u (Rodrigues)
---@param u number[]
---@param t number
---@return number[][]
function Mat3.rotationAbout(u, t)
    local c, s = math.cos(t), math.sin(t)
    local k = 1 - c
    local x, y, z = u[1], u[2], u[3]
    return {
        { c + x * x * k, x * y * k - z * s, x * z * k + y * s },
        { y * x * k + z * s, c + y * y * k, y * z * k - x * s },
        { z * x * k - y * s, z * y * k + x * s, c + z * z * k },
    }
end

-- 3-vector helpers (number[3], new tables)
local V = {}
function V.sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
function V.add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
function V.scale(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
function V.dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
function V.cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
function V.length(a) return math.sqrt(V.dot(a, a)) end
---@return number[]? nil for a (near) zero vector
function V.normalize(a)
    local l = V.length(a)
    if l < 1e-12 then return nil end
    return { a[1] / l, a[2] / l, a[3] / l } -- divided: the map converter's baselines are bit-exact
end
Mat3.vec = V

MGE.Mat3 = Mat3
