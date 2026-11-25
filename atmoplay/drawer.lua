-- Atmo Play draws the plain atmo shapes itself, on screen only (the game's atmo draws everything every frame),
-- binned by x / y cell so off-screen cells are skipped whole. The game's atmo keeps the rest (models, random,
-- animated, scripted, parented, player lines) and the header. Props are drawn where they are, not while carried.
-- "visible 0" and alpha 0 aren't drawn

local NS = ATMOPLAY_LOADING

local Colliders = NS.Colliders
local Driver = NS.Driver

---@class AtmoPlayDrawItem
---@field index integer place among the atmo's entities
---@field shape "box"|"sphere"|"capsule"
---@field pos number[]
---@field size number[] as the game draws it: box sides, sphere radius first, pill radius then length
---@field rot table MatrixTB, shared by every shape with the same rot line
---@field color number[] r g b a as the game reads it
---@field noDepth boolean?
---@field minLevel integer
---@field maxLevel integer
---@field radius number

---@class AtmoPlayDrawer
local Drawer = {
    CELL = 16,
    -- keys that leave a shape to the game (random, animated, scripted, relative...)
    GAME_KEYS = {
        parent = true, count = true, rpos = true, randompos = true, rsize = true, randomsize = true,
        rotate = true, move = true, drawfunc = true, framefunc = true, size_dojo = true, queue_player = true,
        rcolor = true, rcolour = true, randomcolor = true, randomcolour = true, rcol = true,
    },
}

local cellKey = NS.Pool.cellKey
local numbers = Colliders.numbers

---A color line as the game reads it: the first three over 256 when any is above 2
local function colorOf(value)
    local c = numbers(value)
    local r, g, b, a = c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
    if r > 2 or g > 2 or b > 2 then r, g, b = r / 256, g / 256, b / 256 end
    return { r, g, b, a }
end

---Why the game draws an entity, nil when Atmo Play does
---@param parents table<string, boolean> names some entity is parented to
---@return string? reason
local function gameReason(e, parents)
    if e.player then return "player" end
    if tostring(e.props.shape or ""):match("^custom") then return "model" end
    if parents[e.name] then return "parent" end
    for key in pairs(e.props) do
        if Drawer.GAME_KEYS[key] then return key end
    end
    return nil
end

---Splits an atmo into the plain shapes Atmo Play draws (props always: they move) and the lines the game keeps
---@param atmoLines string[]
---@param props table<integer, any>? the props by atmo index
---@return { items: AtmoPlayDrawItem[], gameLines: string[], own: integer, game: integer, hidden: integer }
function Drawer.split(atmoLines, props)
    local entities, header = Colliders.entities(atmoLines)
    local parents = {}
    for _, e in ipairs(entities) do
        if e.props.parent then parents[e.props.parent] = true end
    end
    local gameLines, items, rots, colors = {}, {}, {}, {}
    for _, line in ipairs(header) do gameLines[#gameLines + 1] = line end
    local own, game, hidden = 0, 0, 0
    for index, e in ipairs(entities) do
        local p = e.props
        local isProp = props ~= nil and props[index] ~= nil
        local colorLine = p.color or "" -- one table per color line: drawing sets the color only when it changes
        local color = colors[colorLine]
        if not color then
            color = colorOf(p.color)
            colors[colorLine] = color
        end
        local reason = gameReason(e, parents)
        if (p.visible and p.visible:match("^0")) or (color[4] <= 0 and not reason) then
            hidden = hidden + 1
        elseif not isProp and (reason or not p.pos) then
            game = game + 1
            for _, line in ipairs(e.lines) do gameLines[#gameLines + 1] = line end
        else
            own = own + 1
            local shape = Colliders.shapeOf(p.shape) or "box" -- the game draws pills as capsules
            if shape == "cylinder" then shape = "capsule" end
            local s = numbers(p.sides)
            local size = { s[1] or 1, s[2] or 1, s[3] or 1 }
            local radius = Colliders.radius(shape, { math.abs(size[1]), math.abs(size[2]), math.abs(size[3]) })
            local rotLine = p.rot or ""
            local rot = rots[rotLine]
            if not rot then
                rot = Driver.matrixTB(Colliders.frameOf(numbers(p.rot)))
                rots[rotLine] = rot
            end
            local pos = numbers(p.pos)
            items[#items + 1] = {
                index = index, shape = shape, pos = { pos[1] or 0, pos[2] or 0, pos[3] or 0 }, size = size, rot = rot,
                color = color, noDepth = p.no_depth ~= nil and p.no_depth:match("^1") ~= nil or nil,
                minLevel = tonumber(p.min_level) or 0, maxLevel = tonumber(p.max_level) or 2, radius = radius,
            }
        end
    end
    return { items = items, gameLines = gameLines, own = own, game = game, hidden = hidden }
end

---------------------------------------------------------------------------------------------------- the drawer

---@param split table Drawer.split's
---@param props table<integer, table>? the props by atmo index
---@return table drawer
function Drawer.new(split, props)
    local d = { cells = {}, cellList = {}, moving = {}, count = #split.items, drawn = 0 }
    for _, item in ipairs(split.items) do
        local prop = props and props[item.index]
        if prop then
            item.prop = prop
            d.moving[#d.moving + 1] = item
        else
            local key = cellKey(math.floor(item.pos[1] / Drawer.CELL), math.floor(item.pos[2] / Drawer.CELL))
            local cell = d.cells[key]
            if not cell then
                cell = { items = {}, lo = { math.huge, math.huge, math.huge }, hi = { -math.huge, -math.huge, -math.huge } }
                d.cells[key] = cell
                d.cellList[#d.cellList + 1] = cell
            end
            cell.items[#cell.items + 1] = item
            for k = 1, 3 do
                cell.lo[k] = math.min(cell.lo[k], item.pos[k] - item.radius)
                cell.hi[k] = math.max(cell.hi[k], item.pos[k] + item.radius)
            end
        end
    end
    for _, cell in ipairs(d.cellList) do -- a sphere around each cell's shapes
        local lo, hi = cell.lo, cell.hi
        cell.pos = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }
        cell.radius = math.sqrt((hi[1] - lo[1]) ^ 2 + (hi[2] - lo[2]) ^ 2 + (hi[3] - lo[3]) ^ 2) / 2
    end
    return d
end

---------------------------------------------------------------------------------------------------- the view

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function normalize(v)
    local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if l < 1e-9 then return nil end
    return { v[1] / l, v[2] / l, v[3] / l }
end

---Screen position of a point `e` out from `target` along `dir`, nil off screen
local function screenAt(target, dir, e)
    local x, y, z = get_screen_pos(target[1] + dir[1] * e, target[2] + dir[2] * e, target[3] + dir[3] * e)
    if x == nil or z ~= 0 then return nil end
    return x, y
end

local MEASURE_SHARES = { 0.25, 0.05 } -- of the measuring depth, farthest first (MGE's world_select.lua)
local MEASURE_MIN_DEPTH = 10 -- past the game's near clip (~5 units)

---This frame's camera: eye, axes and the screen mapping, measured with get_screen_pos around its target. nil: draw
---everything
---@return table?
function Drawer.measureView()
    local ok, info = pcall(get_camera_info)
    if not ok or type(info) ~= "table" or not info.pos or not info.lookat then return nil end
    local eye = { info.pos.x, info.pos.y, info.pos.z }
    local target = { info.lookat.x, info.lookat.y, info.lookat.z }
    local toTarget = sub(target, eye)
    local dist = math.sqrt(toTarget[1] ^ 2 + toTarget[2] ^ 2 + toTarget[3] ^ 2)
    local forward = normalize(toTarget)
    if not forward then return nil end
    local right = normalize(cross(forward, { 0, 0, 1 })) or { 1, 0, 0 }
    local up = cross(right, forward)
    -- at least MEASURE_MIN_DEPTH out: free camera's look-at point is close to the eye, inside the near clip
    local depths = dist >= MEASURE_MIN_DEPTH and { dist, MEASURE_MIN_DEPTH } or { MEASURE_MIN_DEPTH, MEASURE_MIN_DEPTH * 3 }
    for _, depth in ipairs(depths) do
        local anchor = { eye[1] + forward[1] * depth, eye[2] + forward[2] * depth, eye[3] + forward[3] * depth }
        for _, share in ipairs(MEASURE_SHARES) do
            local e = depth * share
            local rx1, ry1 = screenAt(anchor, right, e)
            local rx2, ry2 = screenAt(anchor, right, -e)
            local ux1, uy1 = screenAt(anchor, up, e)
            local ux2, uy2 = screenAt(anchor, up, -e)
            if rx1 and rx2 and ux1 and ux2 then
                local k = depth / (2 * e)
                local m11, m21 = (rx1 - rx2) * k, (ry1 - ry2) * k
                local m12, m22 = (ux1 - ux2) * k, (uy1 - uy2) * k
                if math.abs(m11 * m22 - m12 * m21) < 1e-9 then return nil end
                return { eye = eye, forward = forward, right = right, up = up, cx = (rx1 + rx2 + ux1 + ux2) / 4,
                    cy = (ry1 + ry2 + uy1 + uy2) / 4, m11 = m11, m12 = m12, m21 = m21, m22 = m22,
                    w = rawget(_G, "WIN_W") or 1920, h = rawget(_G, "WIN_H") or 1080 }
            end
        end
    end
    return nil
end

---Whether a sphere can show on screen (with a margin); true without a view
local function onScreen(v, x, y, z, r)
    if not v then return true end
    local e, f = v.eye, v.forward
    local rx, ry, rz = x - e[1], y - e[2], z - e[3]
    local depth = rx * f[1] + ry * f[2] + rz * f[3]
    if depth < -r then return false end
    if depth <= r then return true end
    local right, up = v.right, v.up
    local a = (rx * right[1] + ry * right[2] + rz * right[3]) / depth
    local b = (rx * up[1] + ry * up[2] + rz * up[3]) / depth
    local sx, sy = v.cx + v.m11 * a + v.m12 * b, v.cy + v.m21 * a + v.m22 * b
    local sr = r / depth * math.sqrt(v.m11 * v.m11 + v.m21 * v.m21) * 1.5 + 8
    return sx + sr >= 0 and sx - sr <= v.w and sy + sr >= 0 and sy - sr <= v.h
end
Drawer.onScreen = onScreen

---------------------------------------------------------------------------------------------------- drawing

local lastColor = nil -- set_color only when it changes

local function drawItem(item, x, y, z, rot)
    local c, s = item.color, item.size
    if c ~= lastColor then
        set_color(c[1], c[2], c[3], c[4])
        lastColor = c
    end
    if item.shape == "box" then
        draw_box_m(x, y, z, s[1], s[2], s[3], rot, nil, item.noDepth)
    elseif item.shape == "sphere" then
        draw_sphere_m(x, y, z, s[1], rot, nil, item.noDepth)
    else
        draw_capsule_m(x, y, z, s[2], s[1], rot, nil, item.noDepth)
    end
end

-- this frame's shapes on screen and the cells on screen by distance (reused)
local visible, cellOrder = {}, {}
local function nearer(a, b) return a.dist < b.dist end
local function cellNearer(a, b) return a.near < b.near end

-- orderNearest's buckets: sorting thousands with table.sort was most of a frame
local BUCKETS = 256
local bucketCount, bucketEnd, bucketOf, ordered, boundary = {}, {}, {}, {}, {}

---visible[1..n] near to far by distance buckets, exactly sorted in the bucket holding the most-th, so
---visible[1..most] are exactly the nearest most
local function orderNearest(n, most)
    if n < 2 then return end
    local sqrt, lo, hi = math.sqrt, math.huge, 0
    for i = 1, n do
        local d = sqrt(visible[i].dist)
        bucketOf[i] = d
        if d < lo then lo = d end
        if d > hi then hi = d end
    end
    local scale = hi > lo and (BUCKETS - 1e-9) / (hi - lo) or 0
    for b = 1, BUCKETS do bucketCount[b] = 0 end
    for i = 1, n do
        local b = math.floor((bucketOf[i] - lo) * scale) + 1
        bucketOf[i] = b
        bucketCount[b] = bucketCount[b] + 1
    end
    local at = 1
    for b = 1, BUCKETS do
        bucketEnd[b] = at -- the next free slot while placing; one past the bucket's last after
        at = at + bucketCount[b]
    end
    for i = 1, n do
        local b = bucketOf[i]
        local slot = bucketEnd[b]
        ordered[slot] = visible[i]
        bucketEnd[b] = slot + 1
    end
    for i = 1, n do visible[i] = ordered[i] end
    if most >= n then return end
    local b = 1 -- the bucket holding the most-th: sorted exactly
    while bucketEnd[b] <= most do b = b + 1 end
    local first, last = bucketEnd[b] - bucketCount[b], bucketEnd[b] - 1
    local m = 0
    for k = first, last do
        m = m + 1
        boundary[m] = visible[k]
    end
    for k = #boundary, m + 1, -1 do boundary[k] = nil end
    table.sort(boundary, nearer)
    for k = 1, m do visible[first + k - 1] = boundary[k] end
end

---draw3d: on-screen shapes nearest first, at most maxDraws. Cells go nearest first; once maxDraws are found,
---the farthest of them is a threshold past which cells and shapes are skipped (same result, less work)
---@param view table? Drawer.measureView's (nil: unordered, the first maxDraws)
---@param level integer the game's graphics level (0-2)
---@param maxDraws integer? nil or 0: all
---@return integer drawn
function Drawer.draw(d, view, level, maxDraws)
    lastColor = nil -- others drew in between
    local cap = (maxDraws and maxDraws > 0) and maxDraws or math.huge
    local n = 0
    local e = view and view.eye
    local ex, ey, ez = 0, 0, 0
    if e then ex, ey, ez = e[1], e[2], e[3] end
    for _, item in ipairs(d.moving) do -- props first (few, not in cells)
        local prop = item.prop
        if not prop.entry and level >= item.minLevel and level <= item.maxLevel then
            local p = prop.pos
            if onScreen(view, p[1], p[2], p[3], item.radius) then
                n = n + 1
                visible[n] = item
                item.at, item.atRot = p, prop.rot
                local dx, dy, dz = p[1] - ex, p[2] - ey, p[3] - ez
                item.dist = dx * dx + dy * dy + dz * dz
            end
        end
    end
    -- cells on screen, nearest edge first
    local m = 0
    for _, cell in ipairs(d.cellList) do
        local cp = cell.pos
        if onScreen(view, cp[1], cp[2], cp[3], cell.radius) then
            m = m + 1
            cellOrder[m] = cell
            local dx, dy, dz = cp[1] - ex, cp[2] - ey, cp[3] - ez
            local near = math.sqrt(dx * dx + dy * dy + dz * dz) - cell.radius
            cell.near = near > 0 and near * near or 0 -- squared, as the shapes' dist
        end
    end
    for i = #cellOrder, m + 1, -1 do cellOrder[i] = nil end
    if e then table.sort(cellOrder, cellNearer) end
    local threshold = math.huge -- once cap are in hand: the cap-th nearest's dist (nothing at or past it is drawn)
    for k = 1, m do
        local cell = cellOrder[k]
        if cell.near >= threshold then break end
        local items = cell.items
        for j = 1, #items do
            local item = items[j]
            if level >= item.minLevel and level <= item.maxLevel then
                local p = item.pos
                local dx, dy, dz = p[1] - ex, p[2] - ey, p[3] - ez
                local dist = dx * dx + dy * dy + dz * dz
                if dist < threshold and onScreen(view, p[1], p[2], p[3], item.radius) then
                    n = n + 1
                    visible[n] = item
                    item.at, item.atRot, item.dist = p, item.rot, dist
                end
            end
        end
        if e and threshold == math.huge and n >= cap then
            orderNearest(n, cap)
            n = cap -- the rest are at or past the threshold
            threshold = visible[cap].dist
        end
    end
    for i = #visible, n + 1, -1 do visible[i] = nil end
    if e then orderNearest(n, cap) end
    if n > cap then n = cap end
    for i = 1, n do
        local item = visible[i]
        local p = item.at
        drawItem(item, p[1], p[2], p[3], item.atRot)
    end
    d.drawn = n
    return n
end

NS.Drawer = Drawer
return Drawer
