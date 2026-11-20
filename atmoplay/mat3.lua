-- Minimal 3x3 matrix helpers (row-major number[][]), standard right-handed rotations. Copied from MGE's
-- mge/utils/mat3.lua (only what Atmo Play needs)

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

---@class AtmoPlayMat3
local Mat3 = {}

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

NS.Mat3 = Mat3
return Mat3
