-- Gizmo math: handle layout and drag results from camera rays, no game calls.
-- Drags are absolute (from the grab to the current ray, never summed deltas): no drift.
--   axis:  closest point on the axis line to the ray, minus the one at the grab
--   plane: ray hit on the handle's plane, minus the grab hit

---@class GizmoMath
local GizmoMath = {}
MGE.GizmoMath = GizmoMath

local V = MGE.Mat3.vec
local sub, add, scale, dot, length, cross, normalize = V.sub, V.add, V.scale, V.dot, V.length, V.cross, V.normalize
GizmoMath.sub, GizmoMath.add, GizmoMath.scale, GizmoMath.dot, GizmoMath.length = sub, add, scale, dot, length
GizmoMath.cross, GizmoMath.normalize = cross, normalize

GizmoMath.AXES = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }

-- handles within 10 degrees of edge-on can't be dragged precisely: hidden
local EDGE_ON_AXIS = math.cos(math.rad(10))
local EDGE_ON_PLANE = math.sin(math.rad(10))

-- Handle sizes as shares of `size` (the arrow length, which scales with camera distance)
GizmoMath.SHAPE = {
    tipRadius = 0.072,    -- ball at an arrow's end, half a scale cube
    pickRadius = 0.08,    -- clickable around shafts and ring segments
    planeOffset = 0.3,    -- plane square's center, along both of its axes
    planeHalf = 0.11,     -- plane square's half size
    planeThick = 0.03,    -- plane square's half thickness (clickable)
    ringRadius = 0.85,    -- rotate rings
    uniformOffset = 0.45, -- uniform scale cube, along each axis
}

---@class GizmoHandle
---@field kind "axis"|"plane"
---@field index integer axis (arrow) or normal (plane square): 1 x, 2 y, 3 z
---@field dir number[]? arrow direction
---@field from number[]? arrow start (gizmo center)
---@field to number[]? arrow end
---@field normal number[]? plane square's normal
---@field center number[]? plane square's center
---@field half number[]? plane square's half sizes along x y z
---@field enabled boolean false when turned (nearly) edge-on to the camera

---Handles of the move gizmo: an arrow per world axis and a square per axis pair
---@param center number[] gizmo center (the selection's center)
---@param size number arrow length
---@param viewDir number[] unit, from the camera toward the center
---@return GizmoHandle[]
function GizmoMath.moveHandles(center, size, viewDir)
    local S = GizmoMath.SHAPE
    local handles = {}
    for i, a in ipairs(GizmoMath.AXES) do
        table.insert(handles, { kind = "axis", index = i, dir = a, from = center, to = add(center, scale(a, size)),
            enabled = math.abs(dot(a, viewDir)) < EDGE_ON_AXIS })
    end
    for i, n in ipairs(GizmoMath.AXES) do
        local u, v = i % 3 + 1, (i + 1) % 3 + 1 -- the two axes it moves along
        local c, half = { center[1], center[2], center[3] }, {}
        for _, k in ipairs({ u, v }) do c[k] = c[k] + S.planeOffset * size end
        for k = 1, 3 do half[k] = (k == i and S.planeThick or S.planeHalf) * size end
        table.insert(handles, { kind = "plane", index = i, normal = n, center = c, half = half,
            enabled = math.abs(dot(n, viewDir)) > EDGE_ON_PLANE })
    end
    return handles
end

---Parameter s of the point p + s * u on a line (u unit) closest to the ray o + t * d (d unit)
---@return number? nil when ray and line are (nearly) parallel
function GizmoMath.closestOnLine(o, d, p, u)
    local w = sub(p, o)
    local b = dot(u, d)
    local denom = 1 - b * b
    if denom < 1e-9 then return nil end
    return (b * dot(d, w) - dot(u, w)) / denom
end

---Where the ray o + t * d hits the plane through p with normal n
---@return number[]? nil when parallel or behind the camera
function GizmoMath.rayPlane(o, d, p, n)
    local dn = dot(d, n)
    if math.abs(dn) < 1e-9 then return nil end
    local t = dot(sub(p, o), n) / dn
    if t < 0 then return nil end
    return add(o, scale(d, t))
end

---@param value number
---@param step number
---@return number
function GizmoMath.snap(value, step)
    return math.floor(value / step + 0.5) * step
end

---What a drag remembers from the grab: the line parameter (arrow) or the plane hit (square)
---@param handle GizmoHandle
---@param center number[] gizmo center at the grab
---@return number|number[]|nil nil when the ray can't grab it (parallel)
function GizmoMath.dragStart(handle, center, o, d)
    if handle.kind == "axis" then return GizmoMath.closestOnLine(o, d, center, handle.dir) end
    return GizmoMath.rayPlane(o, d, center, handle.normal)
end

---Offset of the dragged objects for the current mouse ray
---@param handle GizmoHandle
---@param center number[] gizmo center at the grab
---@param grab number|number[] dragStart's result
---@param step number? snaps the offset to multiples of it (Ctrl)
---@return number[]? nil when the ray can't be used this frame (parallel), keep the last offset
function GizmoMath.dragOffset(handle, center, grab, o, d, step)
    if handle.kind == "axis" then
        local s = GizmoMath.closestOnLine(o, d, center, handle.dir)
        if not s then return nil end
        local delta = s - grab
        if step then delta = GizmoMath.snap(delta, step) end
        return scale(handle.dir, delta)
    end
    local hit = GizmoMath.rayPlane(o, d, center, handle.normal)
    if not hit then return nil end
    local offset = sub(hit, grab)
    for k = 1, 3 do
        if k == handle.index then
            offset[k] = 0 -- stays in the plane exactly
        elseif step then
            offset[k] = GizmoMath.snap(offset[k], step)
        end
    end
    return offset
end

---------------------------------------------------------------- rotate rings
-- A ring per group axis. Face-on enough: the angle is measured on the ring's plane (full turns work).
-- Nearly edge-on: the mouse moves along the tangent at the grab, one radius of travel = 1 radian

local atan2 = math.atan2 or math.atan -- 5.1 has atan2

GizmoMath.RING_SEGMENTS = 64
-- |cos| between ring axis and view below this: tangent drag (~17 degrees from edge-on)
GizmoMath.RING_PLANE_LIMIT = 0.3

GizmoMath.rotationAbout = MGE.Mat3.rotationAbout

---@class GizmoRing: GizmoHandle
---@field radius number
---@field u number[] in-plane axis, angle 0
---@field v number[] in-plane axis, angle 90 degrees (u x v = normal)
---@field points number[][] RING_SEGMENTS + 1 points around the ring, the last is the first again

---Rings of the rotate gizmo, one per axis of `frame` (columns)
---@param center number[]
---@param frame number[][] group axes as columns
---@param radius number
---@return GizmoRing[]
function GizmoMath.ringHandles(center, frame, radius)
    local cols = MGE.Mat3.transpose(frame)
    local handles = {}
    for i = 1, 3 do
        local u, v = cols[i % 3 + 1], cols[(i + 1) % 3 + 1]
        local points = {}
        for k = 0, GizmoMath.RING_SEGMENTS do
            local a = 2 * math.pi * k / GizmoMath.RING_SEGMENTS
            points[k + 1] = add(center, add(scale(u, radius * math.cos(a)), scale(v, radius * math.sin(a))))
        end
        table.insert(handles, { kind = "ring", index = i, normal = cols[i], center = center, radius = radius,
            u = u, v = v, points = points, enabled = true })
    end
    return handles
end

---@class GizmoRingGrab
---@field method "plane"|"tangent"
---@field point number[] grabbed point on the ring
---@field tangent number[]? tangent drag: direction a positive turn moves the grabbed point
---@field s0 number? tangent drag: line parameter at the grab
---@field raw number? plane drag: last measured angle (-pi..pi) from the grab
---@field from number[]? plane drag: center to the plane hit at the grab
---@field angle number turned so far (radians)

---Starts a ring drag where the mouse ray hit the ring
---@param ring GizmoRing
---@param o number[] ray origin
---@param d number[] ray direction
---@param t number distance along the ray to the hit
---@param viewDir number[] unit, camera toward the gizmo center
---@return GizmoRingGrab?
function GizmoMath.ringGrab(ring, o, d, t, viewDir)
    local n, c = ring.normal, ring.center
    local q = sub(add(o, scale(d, t)), c)
    q = sub(q, scale(n, dot(q, n))) -- onto the ring's plane
    local dirOut = normalize(q)
    if not dirOut then return nil end
    local point = add(c, scale(dirOut, ring.radius))
    if math.abs(dot(n, viewDir)) >= GizmoMath.RING_PLANE_LIMIT then
        local hit = GizmoMath.rayPlane(o, d, c, n)
        local from = hit and sub(hit, c)
        if from and length(from) > 1e-9 then
            return { method = "plane", point = point, from = from, raw = 0, angle = 0 }
        end
    end
    local tangent = cross(n, dirOut)
    local s0 = GizmoMath.closestOnLine(o, d, point, tangent)
    if not s0 then return nil end
    return { method = "tangent", point = point, tangent = tangent, s0 = s0, angle = 0 }
end

---Angle turned for the current mouse ray (updates the grab's running angle)
---@param ring GizmoRing
---@param grab GizmoRingGrab
---@param step number? snaps the angle to multiples of it (radians, Ctrl)
---@return number? radians, nil when the ray can't be used this frame (keep the last angle)
function GizmoMath.ringAngle(ring, grab, o, d, step)
    if grab.method == "plane" then
        local hit = GizmoMath.rayPlane(o, d, ring.center, ring.normal)
        local to = hit and sub(hit, ring.center)
        if not to or length(to) < 1e-9 then return nil end
        local raw = atan2(dot(ring.normal, cross(grab.from, to)), dot(grab.from, to))
        -- unwrapped across frames, so turns past 180 degrees don't flip
        local delta = raw - grab.raw
        if delta > math.pi then delta = delta - 2 * math.pi elseif delta < -math.pi then delta = delta + 2 * math.pi end
        grab.raw, grab.angle = raw, grab.angle + delta
    else
        local s = GizmoMath.closestOnLine(o, d, grab.point, grab.tangent)
        if not s then return nil end
        grab.angle = (s - grab.s0) / ring.radius
    end
    if step then return GizmoMath.snap(grab.angle, step) end
    return grab.angle
end

---------------------------------------------------------------- scale handles
-- A cube per group axis plus a uniform cube. The factor is exponential in the travel along the
-- handle: each gizmo size of drag multiplies it by SCALE_PER_SIZE (never flips or reaches 0)

GizmoMath.SCALE_PER_SIZE = 5
GizmoMath.MIN_FACTOR, GizmoMath.MAX_FACTOR = 1e-3, 1e4 -- per drag

---@class GizmoScaleHandle: GizmoHandle
---@field kind "scale"|"uniform"
---@field dir number[] line the factor is measured along (unit)
---@field from number[] gizmo center
---@field to number[] handle end (cube)
---@field axes number[][] group axes, the cubes turn with them

---Scale gizmo handles
---@param center number[]
---@param axes number[][] group axes (unit vectors)
---@param tips number[] distance from the center to each axis handle's cube
---@param corner number[] distance from the center to the uniform cube along each axis
---@param viewDir number[] unit, from the camera toward the center
---@return GizmoScaleHandle[]
function GizmoMath.scaleHandles(center, axes, tips, corner, viewDir)
    local handles = {}
    for i = 1, 3 do
        local a = axes[i]
        table.insert(handles, { kind = "scale", index = i, dir = a, from = center, to = add(center, scale(a, tips[i])),
            axes = axes, enabled = math.abs(dot(a, viewDir)) < EDGE_ON_AXIS })
    end
    local toCorner = { 0, 0, 0 }
    for i = 1, 3 do toCorner = add(toCorner, scale(axes[i], corner[i])) end
    local dir = normalize(toCorner) or axes[1]
    table.insert(handles, { kind = "uniform", index = 4, dir = dir, from = center, to = add(center, toCorner),
        axes = axes, enabled = math.abs(dot(dir, viewDir)) < EDGE_ON_AXIS })
    return handles
end

---Where along the handle's line the grab is
---@param handle GizmoScaleHandle
---@return number? nil when the line can't be grabbed (parallel to the ray)
function GizmoMath.scaleStart(handle, o, d)
    return GizmoMath.closestOnLine(o, d, handle.from, handle.dir)
end

---Factor for a drag of `travel` along the handle (exponential, see above)
---@param travel number
---@param size number gizmo size
---@param step number? snaps the factor to multiples of it (Ctrl), never below one step
---@return number
function GizmoMath.scaleFactor(travel, size, step)
    local f = GizmoMath.SCALE_PER_SIZE ^ (travel / size)
    if step then f = math.max(GizmoMath.snap(f, step), step) end
    return math.min(math.max(f, GizmoMath.MIN_FACTOR), GizmoMath.MAX_FACTOR)
end

---Scale factors along the group's axes for the current mouse ray
---@param handle GizmoScaleHandle
---@param s0 number scaleStart's result
---@param size number gizmo size
---@param step number? snaps the factor (Ctrl)
---@return number[]? x y z factors, nil when the ray can't be used this frame
---@return number? travel along the handle since the grab (the cube follows it)
function GizmoMath.scaleFactors(handle, s0, o, d, size, step)
    local s = GizmoMath.closestOnLine(o, d, handle.from, handle.dir)
    if not s then return nil end
    local f = GizmoMath.scaleFactor(s - s0, size, step)
    if handle.kind == "uniform" then return { f, f, f }, s - s0 end
    ---@type number[]
    local factors = { 1, 1, 1 }
    factors[handle.index] = f
    return factors, s - s0
end

return GizmoMath
