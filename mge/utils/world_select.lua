-- World clicks select whatever is under the cursor (pickAny): a joint anchor first, else the nearest
-- player or object (or atmo ghost on the Objects / Atmo lists). Something from another list switches to
-- its list with only it selected; on its own list it's the usual click / Shift + click select.
-- Shift + drag box-selects into the current list (rays: hidden objects stay out); Ctrl + Shift takes
-- everything inside.
-- Rays come from the camera projection measured with get_screen_pos and are intersected exactly with each
-- shape. Don't switch to the engine raycast (inaccurate) or projecting outlines (fails off screen)
require("toriui.uielement3d") -- Utils3D.MatrixToMatrixTB

local ModData = MGE.ModData
local SHAPE = MGE.SHAPE
local HOOK_SET = MGE.hookname .. "_worldselect" -- MGE's own draw3d slot is highlight's

---@class WorldSelect
local WorldSelect = {
    clickMoveLimit = 4, -- pixels between down and up that still count as a click
    clicksOff = false, -- only the gizmo takes clicks (ui/map_place.lua)
    boxGridStep = 12, -- box select: pixels between rays
    boxGridMax = 40, -- box select: most rays + 1 per side
}

---@type { x: number, y: number, box: boolean?, endX: number?, endY: number?, moved: boolean? }? box: a
---Shift press (endX / endY the mouse, moved once past clickMoveLimit)
local pressed = nil
---@type { x1: number, y1: number, x2: number, y2: number }? box waiting for the next draw3d
local pendingBox = nil
---@type { x: number, y: number, additive: boolean }? click waiting for draw3d (get_screen_pos works only there)
local pendingClick = nil

local V = MGE.Mat3.vec
local sub, add, scale, dot, cross, length, normalize = V.sub, V.add, V.scale, V.dot, V.cross, V.length, V.normalize

---@class CameraProjection
---@field eye number[]
---@field forward number[]
---@field right number[]
---@field up number[]
---@field cx number screen position of the look-at point
---@field cy number
---@field m11 number screen offset = M * (sideways / depth)
---@field m12 number
---@field m21 number
---@field m22 number
---@field det number

-- measuring offsets as shares of the camera distance: far first (less rounding), closer if off screen
local MEASURE_SHARES = { 0.25, 0.05 }
-- depths along the view axis to measure at: past the game's near clip (~5 units)
local MEASURE_MIN_DEPTH = 10

---@param dist number eye to look-at point
---@return number[] depths to try, nearest usable first
local function measureDepths(dist)
    if dist >= MEASURE_MIN_DEPTH then return { dist, MEASURE_MIN_DEPTH } end
    return { MEASURE_MIN_DEPTH, MEASURE_MIN_DEPTH * 3 }
end
WorldSelect.measureDepths = measureDepths -- Atmo Play's drawer has its own copy

---Screen position of target + dir * e, nil off screen (get_screen_pos, draw3d only)
---@return number? x, number? y
local function screenAt(target, dir, e)
    local x, y, z = get_screen_pos(target[1] + dir[1] * e, target[2] + dir[2] * e, target[3] + dir[3] * e)
    if x == nil or z ~= 0 then return nil end
    return x, y
end

-- Measured once a frame (gizmo and highlight both ask). Not cached by camera info: the drawn view eases
-- toward the camera, and a frozen measurement left the gizmo off until the camera moved
---@type CameraProjection?
local frameProjection = nil
local frameMeasured = nil -- UIElement.frameIndex it was measured in

---The camera's projection, once a frame (read-only). Call from draw3d (uses get_screen_pos); mouse events
---can reuse the last frame's
---@return CameraProjection?
function WorldSelect.measureProjection()
    local frame = UIElement and UIElement.frameIndex
    if frame and frame == frameMeasured then return frameProjection end
    frameProjection, frameMeasured = WorldSelect.measureProjectionNow(), frame
    return frameProjection
end

---Measures the camera's projection now, uncached
---@return CameraProjection?
function WorldSelect.measureProjectionNow()
    local info = get_camera_info()
    local eye = { info.pos.x, info.pos.y, info.pos.z }
    local target = { info.lookat.x, info.lookat.y, info.lookat.z }
    local toTarget = sub(target, eye)
    local dist = length(toTarget)
    local forward = normalize(toTarget)
    if not forward then return nil end
    local right = normalize(cross(forward, { 0, 0, 1 })) or { 1, 0, 0 } -- straight down: any right works
    local up = cross(right, forward)

    -- screen offset = M * (sideways / depth), the same at any depth along the view axis. get_screen_pos
    -- rounds to pixels, so measure pairs on both sides far out: their average is the center, their
    -- difference M, with ~10x less rounding (close points made the gizmo shake). Measured at least
    -- MEASURE_MIN_DEPTH out: free camera's look-at point is close to the eye, inside the near clip
    for _, depth in ipairs(measureDepths(dist)) do
        local anchor = { eye[1] + forward[1] * depth, eye[2] + forward[2] * depth, eye[3] + forward[3] * depth }
        for _, share in ipairs(MEASURE_SHARES) do
            local e = depth * share
            local rx1, ry1 = screenAt(anchor, right, e)
            local rx2, ry2 = screenAt(anchor, right, -e)
            local ux1, uy1 = screenAt(anchor, up, e)
            local ux2, uy2 = screenAt(anchor, up, -e)
            local m11, m21, m12, m22, det
            if rx1 and rx2 and ux1 and ux2 then
                local k = depth / (2 * e) -- 1 / (sideways / depth) between the pair's points
                m11, m21 = (rx1 - rx2) * k, (ry1 - ry2) * k
                m12, m22 = (ux1 - ux2) * k, (uy1 - uy2) * k
                det = m11 * m22 - m12 * m21
            end
            -- a degenerate measure: the next share or depth may measure fine
            if det and math.abs(det) >= 1e-9 then
                -- the anchor sits halfway between each pair (same depth: right and up are across the view)
                local cx = (rx1 + rx2 + ux1 + ux2) / 4
                local cy = (ry1 + ry2 + uy1 + uy2) / 4
                return { eye = eye, forward = forward, right = right, up = up, cx = cx, cy = cy,
                    m11 = m11, m12 = m12, m21 = m21, m22 = m22, det = det }
            end
        end
    end
    return nil
end

---Camera ray through a screen position for a measured projection (works outside draw3d)
---@param p CameraProjection
---@param x number
---@param y number
---@return number[] origin, number[]? direction normalized
function WorldSelect.rayFrom(p, x, y)
    local ox, oy = x - p.cx, y - p.cy
    local a = (ox * p.m22 - p.m12 * oy) / p.det
    local b = (p.m11 * oy - p.m21 * ox) / p.det
    return p.eye, normalize(add(p.forward, add(scale(p.right, a), scale(p.up, b))))
end

---Screen position of a world point (inverse of rayFrom). Unlike get_screen_pos, works off screen and
---outside draw3d
---@param p CameraProjection
---@param point number[]
---@return number? x, number? y nil when the point is behind the camera
function WorldSelect.project(p, point)
    local rel = sub(point, p.eye)
    local depth = dot(rel, p.forward)
    if depth < 1e-6 then return nil end
    local a, b = dot(rel, p.right) / depth, dot(rel, p.up) / depth
    return p.cx + p.m11 * a + p.m12 * b, p.cy + p.m21 * a + p.m22 * b
end

---Camera ray through a screen position. Call from draw3d
---@param x number
---@param y number
---@return number[]? origin, number[]? direction normalized
function WorldSelect.cameraRay(x, y)
    local p = WorldSelect.measureProjection()
    if not p then return nil end
    return WorldSelect.rayFrom(p, x, y)
end

---An object's local axes in world space: get_obj_rot's columns (row-major)
---@param id integer 0-based object id
---@return number[][]
local function getLocalAxes(id)
    local raw = get_obj_rot(id)
    if type(raw) ~= "table" then return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } end
    local m = Utils3D.MatrixToMatrixTB(raw)
    return { { m.r0, m.r4, m.r8 }, { m.r1, m.r5, m.r9 }, { m.r2, m.r6, m.r10 } }
end

---Distance along the ray to a sphere, nil when missed or when the ray starts inside it
local function hitSphere(origin, dir, center, radius)
    local oc = sub(origin, center)
    local b = dot(oc, dir)
    local c = dot(oc, oc) - radius * radius
    local h = b * b - c
    if h < 0 then return nil end
    local t = -b - math.sqrt(h)
    return t >= 0 and t or nil
end

---Distance along the ray to an oriented box (half sizes along the local axes)
local function hitBox(origin, dir, center, axes, half)
    local rel = sub(origin, center)
    local tmin, tmax = -math.huge, math.huge
    for i = 1, 3 do
        local o, d = dot(rel, axes[i]), dot(dir, axes[i])
        if math.abs(d) < 1e-12 then
            if math.abs(o) > half[i] then return nil end
        else
            local t1, t2 = (-half[i] - o) / d, (half[i] - o) / d
            if t1 > t2 then t1, t2 = t2, t1 end
            if t1 > tmin then tmin = t1 end
            if t2 < tmax then tmax = t2 end
            if tmin > tmax then return nil end
        end
    end
    return tmin >= 0 and tmin or nil -- negative: camera inside the box
end

---Distance along the ray to a capsule (segment a-b with radius)
local function hitCapsule(origin, dir, a, b, radius)
    local ba, oa = sub(b, a), sub(origin, a)
    local baba, bard, baoa = dot(ba, ba), dot(ba, dir), dot(ba, oa)
    local rdoa, oaoa = dot(dir, oa), dot(oa, oa)
    local qa = baba - bard * bard
    local best
    if qa > 1e-12 then -- straight part
        local qb = baba * rdoa - baoa * bard
        local qc = baba * oaoa - baoa * baoa - radius * radius * baba
        local h = qb * qb - qa * qc
        if h >= 0 then
            local t = (-qb - math.sqrt(h)) / qa
            local along = baoa + t * bard
            if t >= 0 and along > 0 and along < baba then best = t end
        end
    end
    for _, capCenter in ipairs({ a, b }) do -- round ends
        local t = hitSphere(origin, dir, capCenter, radius)
        if t and (not best or t < best) then best = t end
    end
    return best
end

-- also used by the gizmo's handles
WorldSelect.hitSphere, WorldSelect.hitBox, WorldSelect.hitCapsule = hitSphere, hitBox, hitCapsule

---@class WorldSelectShape a world object read once for many ray tests (box select)
---@field center number[]
---@field radius number bounding sphere
---@field hit fun(origin: number[], dir: number[]): number? distance along the ray, nil when missed
---@field obj FileParserEnvObj?

---A ray-test shape. Sphere: sx radius; pill: sx radius, sy straight length along axes[3]; box: full sides
---@param kind "sphere"|"pill"|"box"
---@param center number[]
---@param axes number[][]? local axes in world space (not needed for spheres)
---@param radius number? bounding sphere, default from the sides
---@return WorldSelectShape
local function rayShape(kind, center, axes, sx, sy, sz, radius)
    if kind == "sphere" then
        return { center = center, radius = radius or sx, hit = function(o, d) return hitSphere(o, d, center, sx) end }
    end
    if kind == "pill" then
        local halfAxis = scale(axes[3], sy / 2)
        local a, b = sub(center, halfAxis), add(center, halfAxis)
        return { center = center, radius = radius or sy / 2 + sx, hit = function(o, d) return hitCapsule(o, d, a, b, sx) end }
    end
    local half = { sx / 2, sy / 2, sz / 2 }
    return { center = center, radius = radius or length(half), hit = function(o, d) return hitBox(o, d, center, axes, half) end }
end

local SHAPE_KIND = { [SHAPE.SPHERE] = "sphere", [SHAPE.CAPSULE] = "pill" }
local GHOST_KIND = { sphere = "sphere", cylinder = "pill" }

---@param id integer 0-based object id
---@return WorldSelectShape?
local function objectShape(id)
    local x, y, z = get_obj_pos(id)
    if x == nil then return nil end
    local sx, sy, sz = get_obj_sides(id)
    local kind = SHAPE_KIND[get_obj_shape(id)] or "box"
    return rayShape(kind, { x, y, z }, kind ~= "sphere" and getLocalAxes(id) or nil, sx, sy, sz)
end

---An atmo object's ghost as a ray-test shape (its frame's columns are its axes)
---@param obj FileParserEnvObj an atmo object
---@return WorldSelectShape?
local function ghostShape(obj)
    local g = MGE.AtmoLayer.ghost(obj)
    if not g then return nil end
    local f, s = g.frame, g.sides
    local axes = MGE.Mat3.transpose(f)
    local shape = rayShape(GHOST_KIND[g.shape] or "box", { g.pos[1], g.pos[2], g.pos[3] }, axes, s[1], s[2], s[3],
        g.radius)
    shape.obj = obj
    return shape
end

---Whether the ray can reach the sphere at all (cheap test before the exact shape)
local function nearSphere(origin, dir, center, radius)
    local ox, oy, oz = origin[1] - center[1], origin[2] - center[2], origin[3] - center[3]
    local c = ox * ox + oy * oy + oz * oz - radius * radius
    if c <= 0 then return true end -- starts inside
    local b = ox * dir[1] + oy * dir[2] + oz * dir[3]
    return b < 0 and b * b >= c
end

local function byId(a, b) return a.id < b.id end

---Atmo objects are pickable where they're drawn: the Objects and Atmo lists
---@return boolean
local function atmoListed()
    local tab = MGE.Main and MGE.Main.listTab
    return tab == "objects" or tab == "atmo"
end

---Atmo object whose ghost is under the screen position, nearest along the ray. Call from draw3d
---@param x number
---@param y number
---@return FileParserEnvObj?
---@return number? distance along the ray
function WorldSelect.pickAtmo(x, y)
    local origin, dir = WorldSelect.cameraRay(x, y)
    if not origin or not dir then return nil end
    local best, bestT = nil, math.huge
    local AtmoLayer = MGE.AtmoLayer
    for _, obj in ipairs(ModData.parsed.atmo or {}) do
        -- cached bounding sphere first: the exact shape only for the few it can hit
        local g = AtmoLayer.ghost(obj)
        if g and nearSphere(origin, dir, g.pos, g.radius) then
            local shape = ghostShape(obj)
            local t = shape and shape.hit(origin, dir)
            if t and t < bestT then best, bestT = obj, t end
        end
    end
    return best, best and bestT
end

---Distance along the ray to a world object, nil when missed
---@param id integer 0-based object id
---@return number?
function WorldSelect.hitObject(origin, dir, id)
    local s = objectShape(id)
    return s and s.hit(origin, dir)
end

---Mod object under the screen position, nearest along the ray. Call from draw3d
---@param x number
---@param y number
---@return FileParserEnvObj?
---@return number? distance along the ray
function WorldSelect.pick(x, y)
    local origin, dir = WorldSelect.cameraRay(x, y)
    if not origin or not dir then return nil end
    local best, bestT = nil, math.huge
    for _, obj in ipairs(ModData.parsed.env_obj) do
        local t = WorldSelect.hitObject(origin, dir, obj.id - 1)
        if t and t < bestT then best, bestT = obj, t end
    end
    return best, best and bestT
end

---Joint whose anchor halo is under the screen position, nearest along the ray. Call from draw3d
---@param x number
---@param y number
---@param visibleOnly boolean? only joints the game draws (visible 1): MGE draws anchors only on the Joints list
---@return FileParserEnvObjJoint?
function WorldSelect.pickJoint(x, y, visibleOnly)
    local origin, dir = WorldSelect.cameraRay(x, y)
    if not origin or not dir then return nil end
    local radius = MGE.Highlight.anchorPickRadius
    local best, bestT = nil, math.huge
    for _, joint in ipairs(ModData.parsed.env_obj_joint) do
        local shown = not visibleOnly or joint.props.visible == "1"
        local p = shown and joint.id and MGE.Joints.anchorOf(joint)
        local t = p and hitSphere(origin, dir, p, radius)
        if t and t < bestT then best, bestT = joint, t end
    end
    return best
end

-- BodyInfo.shape: sphere x radius, box full sides, cylinder (pill) x radius y length along z
local BODY_SPHERE, BODY_CYLINDER = 0, 2

---A player's body part as a ray-test shape, where it stands now
---@param player integer 0-based
---@param id integer body part
---@return WorldSelectShape
local function bodyShape(player, id)
    local b = get_body_info(player, id)
    local s, r = b.sides, b.rot
    local kind = b.shape == BODY_SPHERE and "sphere" or b.shape == BODY_CYLINDER and "pill" or "box"
    local axes = { { r.r0, r.r4, r.r8 }, { r.r1, r.r5, r.r9 }, { r.r2, r.r6, r.r10 } } -- columns: local axes
    return rayShape(kind, { b.pos.x, b.pos.y, b.pos.z }, axes, s.x, s.y, s.z)
end

---Distance along the ray to a player's body part, nil when missed
---@param player integer 0-based
---@param id integer body part
---@return number?
local function hitBody(origin, dir, player, id)
    return bodyShape(player, id).hit(origin, dir)
end

---Player whose body parts or joints are under the screen position, nearest along the ray. Call from draw3d
---@param x number
---@param y number
---@return integer? player 0-based
---@return number? distance along the ray
function WorldSelect.pickPlayer(x, y)
    local origin, dir = WorldSelect.cameraRay(x, y)
    if not origin or not dir or not MGE.Players then return nil end
    local best, bestT = nil, math.huge
    for player = 0, MGE.Players.count() - 1 do
        if MGE.Players.exists(player) then
            for _, id in pairs(BODYPARTS) do
                local t = hitBody(origin, dir, player, id)
                if t and t < bestT then best, bestT = player, t end
            end
            for _, id in pairs(JOINTS) do
                local jx, jy, jz = get_joint_pos(player, id)
                local t = jx and hitSphere(origin, dir, { jx, jy, jz }, get_joint_radius(player, id) or 0.1)
                if t and t < bestT then best, bestT = player, t end
            end
        end
    end
    return best, best and bestT
end

---Body part or joint under the screen position, nearest along the ray. Call from draw3d
---@param x number
---@param y number
---@return integer? player 0-based
---@return string? name lower case
---@return "body"|"joint"|nil kind
function WorldSelect.pickPart(x, y)
    local origin, dir = WorldSelect.cameraRay(x, y)
    if not origin or not dir or not MGE.Players then return nil end
    local bestPlayer, bestName, bestKind, bestT = nil, nil, nil, math.huge
    for player = 0, MGE.Players.count() - 1 do
        if MGE.Players.exists(player) then
            for name, id in pairs(BODYPARTS) do
                local t = hitBody(origin, dir, player, id)
                if t and t < bestT then bestPlayer, bestName, bestKind, bestT = player, name:lower(), "body", t end
            end
            for name, id in pairs(JOINTS) do
                local jx, jy, jz = get_joint_pos(player, id)
                local t = jx and hitSphere(origin, dir, { jx, jy, jz }, get_joint_radius(player, id) or 0.1)
                if t and t < bestT then bestPlayer, bestName, bestKind, bestT = player, name:lower(), "joint", t end
            end
        end
    end
    return bestPlayer, bestName, bestKind
end

---What a world click hits: a joint anchor first (anchors sit on object faces, so the ray would reach
---the object), else the nearer of a player and an object. Call from draw3d
---@param x number
---@param y number
---@return "joint"|"player"|"object"|nil kind
---@return any hit FileParserEnvObjJoint / 0-based player / FileParserEnvObj (possibly atmo)
function WorldSelect.pickAny(x, y)
    local joint = WorldSelect.pickJoint(x, y, MGE.Main.listTab ~= "joints")
    if joint then return "joint", joint end
    local obj, objT = WorldSelect.pick(x, y)
    if atmoListed() then -- the nearer of an object and a ghost
        local ghost, ghostT = WorldSelect.pickAtmo(x, y)
        if ghost and (not obj or ghostT < objT) then obj, objT = ghost, ghostT end
    end
    local player, playerT = WorldSelect.pickPlayer(x, y)
    if player and (not obj or playerT < objT) then return "player", player end
    if obj then return "object", obj end
    return nil
end

---@param p CameraProjection
---@param point number[]
---@param box { left: number, top: number, right: number, bottom: number }
local function projectsInto(p, point, box)
    local x, y = WorldSelect.project(p, point)
    return x ~= nil and x >= box.left and x <= box.right and y >= box.top and y <= box.bottom, x, y
end

---@return { left: number, top: number, right: number, bottom: number }
local function boxOf(x1, y1, x2, y2)
    return { left = math.min(x1, x2), top = math.min(y1, y2), right = math.max(x1, x2), bottom = math.max(y1, y2) }
end

---Generous screen rectangle a sphere can cover: nil behind the camera, everything around it
---@param p CameraProjection
---@param center number[]
---@param radius number
---@return number? left, number? top, number? right, number? bottom
local function screenExtent(p, center, radius)
    local rel = sub(center, p.eye)
    local depth = dot(rel, p.forward)
    if depth < -radius then return nil end -- behind the camera
    if depth <= radius then return -math.huge, -math.huge, math.huge, math.huge end -- around the camera
    local x, y = WorldSelect.project(p, center)
    if not x then return -math.huge, -math.huge, math.huge, math.huge end
    local sr = radius / depth * math.sqrt(p.m11 * p.m11 + p.m21 * p.m21) * 1.5 + 4
    return x - sr, y - sr, x + sr, y + sr
end

-- box select's screen cell size: a ray tests only the shapes listed in its cell
local BOX_CELL = 24

---Objects the rays through a screen box hit: a ray grid plus one ray per object center inside (small
---objects), each taking only the nearest, so hidden objects stay out. Atmo ghosts count where listed
---(ids then aren't unique: loose order). Call from draw3d
---@return FileParserEnvObj[] in id order
function WorldSelect.pickBox(x1, y1, x2, y2)
    local p = WorldSelect.measureProjection()
    if not p then return {} end
    local box = boxOf(x1, y1, x2, y2)
    -- Shapes are binned into the screen cells their outline covers; a ray only tests its cell (testing
    -- all shapes per ray froze big maps). Same picks: a ray can only hit shapes covering its point
    local cellCols = math.max(1, math.ceil((box.right - box.left) / BOX_CELL))
    local cellRows = math.max(1, math.ceil((box.bottom - box.top) / BOX_CELL))
    local cells = {}
    local shapes = {}
    local function addShape(shape, l, t, r, b)
        if r < box.left or l > box.right or b < box.top or t > box.bottom then return end
        shapes[#shapes + 1] = shape
        local c0 = math.max(0, math.floor((l - box.left) / BOX_CELL))
        local c1 = math.min(cellCols - 1, math.floor((r - box.left) / BOX_CELL))
        local r0 = math.max(0, math.floor((t - box.top) / BOX_CELL))
        local r1 = math.min(cellRows - 1, math.floor((b - box.top) / BOX_CELL))
        for c = c0, c1 do
            for rr = r0, r1 do
                local key = rr * cellCols + c
                local list = cells[key]
                if not list then list = {}; cells[key] = list end
                list[#list + 1] = shape
            end
        end
    end
    for _, obj in ipairs(ModData.parsed.env_obj) do
        local sh = objectShape(obj.id - 1)
        if sh then
            local l, t, r, b = screenExtent(p, sh.center, sh.radius)
            if l then
                sh.obj = obj
                addShape(sh, l, t, r, b)
            end
        end
    end
    if atmoListed() then -- ghosts hide what's behind them like objects
        local AtmoLayer = MGE.AtmoLayer
        for _, obj in ipairs(ModData.parsed.atmo or {}) do
            local g = AtmoLayer.ghost(obj) -- cached sphere first, ray shape only for ones in the box
            if g then
                local l, t, r, b = screenExtent(p, g.pos, g.radius)
                if l and not (r < box.left or l > box.right or b < box.top or t > box.bottom) then
                    addShape(ghostShape(obj), l, t, r, b)
                end
            end
        end
    end
    local points = {}
    local w, h = box.right - box.left, box.bottom - box.top
    local cols = math.max(1, math.min(WorldSelect.boxGridMax, math.ceil(w / WorldSelect.boxGridStep)))
    local rows = math.max(1, math.min(WorldSelect.boxGridMax, math.ceil(h / WorldSelect.boxGridStep)))
    for i = 0, cols do
        for j = 0, rows do points[#points + 1] = { box.left + w * i / cols, box.top + h * j / rows } end
    end
    for _, s in ipairs(shapes) do
        local inside, sx, sy = projectsInto(p, s.center, box)
        if inside then points[#points + 1] = { sx, sy } end
    end
    local taken, list = {}, {}
    for _, pt in ipairs(points) do
        local origin, dir = WorldSelect.rayFrom(p, pt[1], pt[2])
        local c = math.min(cellCols - 1, math.max(0, math.floor((pt[1] - box.left) / BOX_CELL)))
        local rr = math.min(cellRows - 1, math.max(0, math.floor((pt[2] - box.top) / BOX_CELL)))
        local inCell = cells[rr * cellCols + c]
        if dir and inCell then
            local best, bestT = nil, math.huge
            for _, s in ipairs(inCell) do
                if nearSphere(origin, dir, s.center, s.radius) then
                    local t = s.hit(origin, dir)
                    if t and t < bestT then best, bestT = s.obj, t end
                end
            end
            if best and not taken[best] then
                taken[best] = true
                list[#list + 1] = best
            end
        end
    end
    table.sort(list, byId)
    return list
end

---Everything whose center is inside a screen box, hidden or not (Ctrl + Shift + drag): projections only,
---instant on big maps. Call from draw3d
---@return FileParserEnvObj[] in id order
function WorldSelect.pickBoxThrough(x1, y1, x2, y2)
    local p = WorldSelect.measureProjection()
    if not p then return {} end
    local box = boxOf(x1, y1, x2, y2)
    local list = {}
    for _, obj in ipairs(ModData.parsed.env_obj) do
        local x, y, z = get_obj_pos(obj.id - 1)
        if x and projectsInto(p, { x, y, z }, box) then list[#list + 1] = obj end
    end
    if atmoListed() then
        local AtmoLayer = MGE.AtmoLayer
        for _, obj in ipairs(ModData.parsed.atmo or {}) do
            local g = AtmoLayer.ghost(obj)
            if g and projectsInto(p, g.pos, box) then list[#list + 1] = obj end
        end
    end
    table.sort(list, byId)
    return list
end

---Players with a joint inside a screen box. Call from draw3d
---@return integer[] 0-based
function WorldSelect.pickPlayersBox(x1, y1, x2, y2)
    local p = WorldSelect.measureProjection()
    if not p or not MGE.Players then return {} end
    local box = boxOf(x1, y1, x2, y2)
    local list = {}
    for player = 0, MGE.Players.count() - 1 do
        if MGE.Players.exists(player) then
            for _, id in pairs(JOINTS) do
                local jx, jy, jz = get_joint_pos(player, id)
                if jx and projectsInto(p, { jx, jy, jz }, box) then
                    list[#list + 1] = player
                    break
                end
            end
        end
    end
    return list
end

---Body parts and joints in a screen box. Shift + drag: the ones its rays reach first (a ray grid plus one
---ray per center inside, each taking the nearest part); through (Ctrl too): every one whose center is
---inside. Only the players' parts count: a few dozen shapes, no binning needed. Call from draw3d
---@param through boolean?
---@return SelectedPart[]
function WorldSelect.pickPartsBox(x1, y1, x2, y2, through)
    local p = WorldSelect.measureProjection()
    if not p or not MGE.Players then return {} end
    local box = boxOf(x1, y1, x2, y2)
    local shapes = {}
    for player = 0, MGE.Players.count() - 1 do
        if MGE.Players.exists(player) then
            for name, id in pairs(BODYPARTS) do
                local sh = bodyShape(player, id)
                sh.part = { player = player, name = name:lower(), kind = "body" }
                shapes[#shapes + 1] = sh
            end
            for name, id in pairs(JOINTS) do
                local jx, jy, jz = get_joint_pos(player, id)
                if jx then
                    local r = get_joint_radius(player, id) or 0.1
                    local sh = rayShape("sphere", { jx, jy, jz }, nil, r, r, r)
                    sh.part = { player = player, name = name:lower(), kind = "joint" }
                    shapes[#shapes + 1] = sh
                end
            end
        end
    end
    local taken, list = {}, {}
    local function take(part)
        if taken[part] then return end
        taken[part] = true
        list[#list + 1] = part
    end
    if through then
        for _, s in ipairs(shapes) do
            if projectsInto(p, s.center, box) then take(s.part) end
        end
        return list
    end
    local near, points = {}, {}
    for _, s in ipairs(shapes) do
        local l, t, r, b = screenExtent(p, s.center, s.radius)
        if l and not (r < box.left or l > box.right or b < box.top or t > box.bottom) then
            near[#near + 1] = s
            local inside, sx, sy = projectsInto(p, s.center, box)
            if inside then points[#points + 1] = { sx, sy } end
        end
    end
    local w, h = box.right - box.left, box.bottom - box.top
    local cols = math.max(1, math.min(WorldSelect.boxGridMax, math.ceil(w / WorldSelect.boxGridStep)))
    local rows = math.max(1, math.min(WorldSelect.boxGridMax, math.ceil(h / WorldSelect.boxGridStep)))
    for i = 0, cols do
        for j = 0, rows do points[#points + 1] = { box.left + w * i / cols, box.top + h * j / rows } end
    end
    for _, pt in ipairs(points) do
        local origin, dir = WorldSelect.rayFrom(p, pt[1], pt[2])
        if dir then
            local best, bestT = nil, math.huge
            for _, s in ipairs(near) do
                if nearSphere(origin, dir, s.center, s.radius) then
                    local t = s.hit(origin, dir)
                    if t and t < bestT then best, bestT = s, t end
                end
            end
            if best then take(best.part) end
        end
    end
    return list
end

---Joints whose anchor is inside a screen box. Call from draw3d
---@return FileParserEnvObjJoint[]
function WorldSelect.pickJointsBox(x1, y1, x2, y2)
    local p = WorldSelect.measureProjection()
    if not p then return {} end
    local box = boxOf(x1, y1, x2, y2)
    local list = {}
    for _, joint in ipairs(ModData.parsed.env_obj_joint) do
        local anchor = joint.id and MGE.Joints.anchorOf(joint)
        if anchor and projectsInto(p, anchor, box) then list[#list + 1] = joint end
    end
    return list
end

local function isOverUI(x, y)
    return MGE.Widgets.isMouseOverUI(x, y) -- Widgets loads after this module
end

local function isActive()
    local Main = MGE.Main -- created after this module loads
    -- clicksOff: the placement view hides the window but its gizmo takes clicks
    return Main and Main.window and (Main.window.displayed or WorldSelect.clicksOff) and not TB_MENU_INPUT_ISACTIVE
end

-- The gizmo gets the mouse first: a press on a handle starts a drag; returning 1 stops a camera drag
add_hook("mouse_button_down", HOOK_SET, function(button, x, y)
    local Gizmo = MGE.Gizmo
    if Gizmo and Gizmo.isDragging() then return 1 end -- other buttons do nothing mid drag
    pressed = nil
    if button ~= 1 or not isActive() or isOverUI(x, y) then return end
    if Gizmo and Gizmo.press(x, y) then return 1 end
    if WorldSelect.clicksOff then return end -- drags still turn the camera
    -- Shift: a drag draws a select box instead of turning the camera
    if get_keyboard_shift() ~= 0 and not WorldSelect.picking then
        -- Ctrl too: pickBoxThrough. Not Alt: the game hides the cursor with it
        pressed = { x = x, y = y, box = true, endX = x, endY = y, through = get_keyboard_ctrl() ~= 0 }
        return 1
    end
    pressed = { x = x, y = y }
end)

add_hook("mouse_button_up", HOOK_SET, function(button, x, y)
    local Gizmo = MGE.Gizmo
    if button == 1 and Gizmo and Gizmo.release(x, y) then
        pressed = nil
        return 1
    end
    local start = pressed
    if button ~= 1 or not start then return end
    pressed = nil
    if not isActive() then return start.box and 1 or nil end
    if start.box and start.moved then
        pendingBox = { x1 = start.x, y1 = start.y, x2 = x, y2 = y, through = start.through or get_keyboard_ctrl() ~= 0 }
        return 1
    end
    local limit = WorldSelect.clickMoveLimit
    if math.abs(x - start.x) > limit or math.abs(y - start.y) > limit then return end -- camera drag
    pendingClick = { x = x, y = y, additive = start.box or get_keyboard_shift() ~= 0 } -- Shift read at the click
    if start.box then return 1 end
end)

---@type { x: number, y: number }? mouse position to test for the hovered object on the next draw3d
local pendingHover = nil
---@type FileParserEnvObj? object a click would pick (Link tab pick or one-shot pick), highlighted
WorldSelect.hover = nil

---@return integer? the joint slot a world click links objects to (Main.linkSlot), nil when clicks select
local function linkSlot()
    local Main = MGE.Main -- created after this module loads
    return Main and Main.linkSlot and Main.linkSlot() or nil
end

---The Link tab's slot while Pick from world is on: world clicks pick objects for it
---@return integer?
local function linkPick()
    local slot = linkSlot()
    return slot and MGE.Joints and MGE.Joints.worldPick and slot or nil
end

---@type { done: fun(obj: FileParserEnvObj), ended: fun()? }? a one-shot pick (color picker): the next
---click's object goes to done instead of selecting; nothing cancels. ended runs either way
WorldSelect.picking = nil

---Starts a one-shot pick, replacing one in progress
---@param done fun(obj: FileParserEnvObj)
---@param ended fun()? after done, or when cancelled
function WorldSelect.startPick(done, ended)
    WorldSelect.cancelPick()
    WorldSelect.picking = { done = done, ended = ended }
end

---Ends a pick in progress without picking (Esc, its button)
---@return boolean cancelled one was in progress
function WorldSelect.cancelPick()
    local p = WorldSelect.picking
    WorldSelect.picking, WorldSelect.hover = nil, nil
    if p and p.ended then p.ended() end
    return p ~= nil
end

-- Hover is retested only after the mouse moved
add_hook("mouse_move", HOOK_SET, function(x, y)
    local box = pressed and pressed.box and pressed
    if box then
        box.endX, box.endY = x, y
        local limit = WorldSelect.clickMoveLimit
        if math.abs(x - box.x) > limit or math.abs(y - box.y) > limit then box.moved = true end
    end
    if not linkPick() and not WorldSelect.picking then return end
    if not isActive() or isOverUI(x, y) then
        pendingHover, WorldSelect.hover = nil, nil
        return
    end
    pendingHover = { x = x, y = y }
end)

---A clicked object: picked for the Link draft when Pick from world is on, else click-selected on its
---own list, else its list opens with only it selected
---@param obj FileParserEnvObj
---@param additive boolean
local function clickObject(obj, additive)
    local Main = MGE.Main
    if obj.kind == "atmo" then
        if Main.listTab == "atmo" then
            local selected = ModData.clickSelect(obj, additive)
            Main.updateWindow()
            if selected then Main.selectionMade() end -- Generate back to Core, camera follow
        else
            for _, other in ipairs(ModData.parsed.atmo) do other.selected = nil end
            obj.selected = true
            Main.leaveGenerate("atmo")
            Main.setListTab("atmo")
        end
        return
    end
    local slot = linkPick()
    if slot then
        MGE.Joints.offerDraft(slot, obj.id)
    elseif Main.listTab == "objects" then
        local selected = ModData.clickSelect(obj, additive)
        Main.updateWindow()
        if selected then Main.selectionMade() end -- Generate back to Core, camera follow
    else
        for _, other in ipairs(ModData.parsed.env_obj) do other.selected = nil end
        obj.selected = true
        Main.leaveGenerate("objects")
        Main.setListTab("objects") -- rebuilds the window, camera follows
    end
end

---A clicked player: click-selected on the Players list, else that list opens with only it selected
---@param player integer 0-based
---@param additive boolean
local function clickPlayer(player, additive)
    local Main = MGE.Main
    if Main.listTab == "players" then
        Main.selectPlayer(player, additive)
        return
    end
    Main.selectedPlayers, Main.selectedPlayer = { [player] = true }, player
    Main.setListTab("players")
end

---A clicked joint anchor: click-selected on the Joints list, else that list opens with only it selected
---@param joint FileParserEnvObjJoint
---@param additive boolean
local function clickJoint(joint, additive)
    local Main = MGE.Main
    if Main.listTab == "joints" then
        Main.selectJoint(joint.id, additive)
        Main.updateWindow()
        return
    end
    Main.selectJointsOnly({ joint.id })
    Main.setListTab("joints")
end

---A Shift + drag box adds what's in it to the current list's selection (b.through: hidden ones too)
---@param b { x1: number, y1: number, x2: number, y2: number, through: boolean? }
local function boxSelect(b)
    local Main = MGE.Main
    if Main.listTab == "objects" or Main.listTab == "atmo" then
        local atmo, any = Main.listTab == "atmo", false -- only the shown list's layer
        local pick = b.through and WorldSelect.pickBoxThrough or WorldSelect.pickBox
        for _, obj in ipairs(pick(b.x1, b.y1, b.x2, b.y2)) do
            if (obj.kind == "atmo") == atmo then
                obj.selected, any = true, true
            end
        end
        if not any then return end
        Main.updateWindow()
        Main.selectionMade()
    elseif Main.listTab == "players" then
        local players = WorldSelect.pickPlayersBox(b.x1, b.y1, b.x2, b.y2)
        if not players[1] then return end
        for _, player in ipairs(players) do Main.selectedPlayers[player] = true end
        Main.selectedPlayer = players[#players]
        Main.updateWindow()
        MGE.Camera.followPlayer(Main.selectedPlayerList())
    elseif Main.listTab == "parts" then
        local parts = WorldSelect.pickPartsBox(b.x1, b.y1, b.x2, b.y2, b.through)
        if not parts[1] then return end
        MGE.PartList.add(parts)
    elseif Main.listTab == "joints" and not linkPick() then -- with Pick from world, clicks pick objects
        local last
        for _, joint in ipairs(WorldSelect.pickJointsBox(b.x1, b.y1, b.x2, b.y2)) do
            if not Main.selectedJoints[joint.id] then
                if last then Main.selectedJoints[last] = true end
                last = joint.id
            end
        end
        if not last then return end -- nothing new
        Main.selectJoint(last, true) -- the last one becomes the current slot
        Main.updateWindow()
    end
end

-- the box while Shift + dragging
add_hook("draw2d", HOOK_SET, function()
    local b = pressed
    if not b or not b.box or not b.moved then return end
    local l, t = math.min(b.x, b.endX), math.min(b.y, b.endY)
    local r, btm = math.max(b.x, b.endX), math.max(b.y, b.endY)
    -- orange: everything inside (Ctrl), blue: the ones in front
    local through = b.through or get_keyboard_ctrl() ~= 0
    local c = through and { 1, 0.6, 0.2 } or { 0.35, 0.65, 1 }
    set_color(c[1], c[2], c[3], 0.15)
    draw_quad(l, t, r - l, btm - t)
    set_color(c[1], c[2], c[3], 0.9)
    draw_line(l, t, r, t, 1)
    draw_line(r, t, r, btm, 1)
    draw_line(r, btm, l, btm, 1)
    draw_line(l, btm, l, t, 1)
end)

add_hook("draw3d", HOOK_SET, function()
    local box = pendingBox
    if box then
        pendingBox = nil
        local ok, err = pcall(boxSelect, box)
        if not ok then MGE.say("box select error: " .. tostring(err)) end
    end
    local picking = WorldSelect.picking
    if not linkPick() and not picking then
        pendingHover, WorldSelect.hover = nil, nil
    elseif pendingHover then
        -- Link pick: only an object a click would hit (not behind an anchor or player).
        -- One-shot pick: objects only
        local ok, kind, hit
        if picking then
            ok, hit = pcall(WorldSelect.pick, pendingHover.x, pendingHover.y)
            kind = hit and "object"
        else
            ok, kind, hit = pcall(WorldSelect.pickAny, pendingHover.x, pendingHover.y)
        end
        WorldSelect.hover = ok and kind == "object" and hit or nil
        pendingHover = nil
    end
    local click = pendingClick
    if not click then return end
    pendingClick = nil
    if picking then
        WorldSelect.picking, WorldSelect.hover = nil, nil
        local ok, obj = pcall(WorldSelect.pick, click.x, click.y)
        if ok and obj then
            local done, err = pcall(picking.done, obj)
            if not done then MGE.say("pick error: " .. tostring(err)) end
        else
            MGE.say("no object there, pick cancelled")
        end
        if picking.ended then picking.ended() end
        return
    end
    if MGE.Main.listTab == "parts" then -- body parts only; a miss leaves the selection
        local okPart, player, name, kind = pcall(WorldSelect.pickPart, click.x, click.y)
        if not okPart then
            MGE.say("world select error: " .. tostring(player))
        elseif player and name then
            MGE.PartList.select(player, name, click.additive, kind)
        end
        return
    end
    local ok, kind, hit = pcall(WorldSelect.pickAny, click.x, click.y)
    if not ok then
        MGE.say("world select error: " .. tostring(kind))
    elseif kind == "joint" then
        clickJoint(hit, click.additive)
    elseif kind == "player" then
        clickPlayer(hit, click.additive)
    elseif kind == "object" then
        clickObject(hit, click.additive)
    end
end)

table.insert(MGE.onQuit, function()
    WorldSelect.picking = nil -- its ended callback would touch the closing window
    remove_hooks(HOOK_SET)
end)

MGE.WorldSelect = WorldSelect
