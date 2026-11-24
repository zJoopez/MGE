-- Atmo Play drawing the atmo itself (`/atmoplay draw own`, the default): one loop in draw3d over the plain shapes,
-- only the ones on screen. The game's atmo draws every element every frame from Lua (UIElement3D, each its own
-- display call), seen or not; how much is drawn is what costs fps on big maps (MGE found the same: its atmo is
-- drawn with the same on-screen test, mge/utils/highlight.lua).
--   * own: boxes, spheres and pills that stay put: pos, rot, size, color, no_depth, min_level / max_level.
--     Listed by x / y cell; a cell off screen skips all of its shapes at once, then each shape is tested.
--   * the game's: everything else (custom models, count / random lines, rotate / move, drawfunc / framefunc,
--     parent and the parents, size_dojo, queue_player, player lines) and the header (shader, opt lines), written
--     to the cache atmo as before.
--   * props (no static bit): drawn where they are now (dynamics.lua: pos / rot), not while carried (their object
--     shows them); no drawn copies in the game's atmo to move each frame.
-- Not drawn, as before: "visible 0" (solid, not drawn).

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY)

local Colliders = NS.Colliders
local Driver = NS.Driver

---@class AtmoPlayDrawItem
---@field index integer place among the atmo's entities (a prop's: Dynamics' byIndex)
---@field shape "box"|"sphere"|"capsule"
---@field pos number[]
---@field size number[] as the game draws it: box sides, sphere radius first, pill radius then length
---@field rot table MatrixTB (Driver.matrixTB), shared by every shape with the same rot line
---@field color number[] r g b a, as the game reads it (above 2 is 0-256)
---@field noDepth boolean?
---@field minLevel integer
---@field maxLevel integer
---@field radius number a sphere around pos (the on-screen test)

---@class AtmoPlayDrawer
local Drawer = {
    CELL = 16, -- x / y cell size of the static shapes' grid
    -- keys that leave a shape to the game: it draws them differently (random, animated, scripted, relative...)
    GAME_KEYS = {
        parent = true, count = true, rpos = true, randompos = true, rsize = true, randomsize = true,
        rotate = true, move = true, drawfunc = true, framefunc = true, size_dojo = true, queue_player = true,
        rcolor = true, rcolour = true, randomcolor = true, randomcolour = true, rcol = true,
    },
}

local cellKey = NS.Pool.cellKey
local numbers = Colliders.numbers

---@param line string a trimmed line
---@return string? key, string? value
local function keyValue(line)
    local key, value = line:match("^([%a_]+)%s+(.-)%s*$")
    return key, value
end

---A color line as the game reads it: 4 numbers, the first three over 256 when any is above 2
local function colorOf(value)
    local c = numbers(value)
    local r, g, b, a = c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
    if r > 2 or g > 2 or b > 2 then r, g, b = r / 256, g / 256, b / 256 end
    return { r, g, b, a }
end

---What the game would do with one entity's lines: nil when Atmo Play draws it, else why the game keeps it
---@param e { props: table<string, string>, player: boolean, model: boolean }
---@param parents table<string, boolean> names some entity is parented to
---@param name string
---@return string? reason
local function gameReason(e, parents, name)
    if e.player then return "player" end
    if e.model then return "model" end
    if parents[name] then return "parent" end
    for key in pairs(e.props) do
        if Drawer.GAME_KEYS[key] then return key end
    end
    return nil
end

---Splits an atmo's lines: the plain shapes Atmo Play draws, and the lines the game's atmo keeps (the header and
---the other entities, as they were). "visible 0" entities go nowhere (solid, not drawn), nor do shapes of alpha 0
---(the game's UIElement3D draws only alpha above 0). Props are always Atmo Play's: they move, and with its own
---drawing nothing moves a copy in the game's atmo (a prop with rcolor, size_dojo, queue_player, a player line or a
---child is drawn plainly, its child left to the game)
---@param atmoLines string[] the atmo (a playable mod's #@ lines, without the prefix)
---@param props table<integer, any>? the props by atmo index (Dynamics' byIndex)
---@return { items: AtmoPlayDrawItem[], gameLines: string[], own: integer, game: integer, hidden: integer }
function Drawer.split(atmoLines, props)
    -- entities as the game's parser sees them (colliders.lua's rules: one per env_obj, "player N" ignores the
    -- lines after it, size is sides), each with its own lines
    local header, entities = {}, {}
    local current, ignoring = nil, false
    for _, raw in ipairs(atmoLines) do
        local line = raw:gsub("^%s*", ""):gsub("[\r\n]", "")
        local name = line:match("^env_obj (.*)$")
        if name then
            current = { name = name, lines = { raw }, props = {}, player = false, model = false }
            entities[#entities + 1] = current
            ignoring = false
        elseif not current then
            header[#header + 1] = raw
        else
            current.lines[#current.lines + 1] = raw
            if line:match("^player %d") then
                ignoring, current.player = true, true
            elseif not ignoring then
                local key, value = keyValue(line)
                if key then
                    if key == "size" then key = "sides" end
                    if key == "col" or key == "colour" then key = "color" end
                    current.props[key] = value
                    if key == "shape" and tostring(value):match("^custom") then current.model = true end
                end
            end
        end
    end
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
        local alpha = colorOf(p.color)[4]
        if (p.visible and p.visible:match("^0")) or (alpha <= 0 and not gameReason(e, parents, e.name)) then
            hidden = hidden + 1
        elseif not isProp and (gameReason(e, parents, e.name) or not p.pos) then
            game = game + 1
            for _, line in ipairs(e.lines) do gameLines[#gameLines + 1] = line end
        else
            own = own + 1
            local word = tostring(p.shape or "box"):match("^%s*(%a+)") or "box"
            local shape = (word == "sphere") and "sphere" or ((word == "cylinder" or word == "capsule") and "capsule")
                or "box"
            local s = numbers(p.sides)
            local size = { s[1] or 1, s[2] or 1, s[3] or 1 }
            local ax, ay, az = math.abs(size[1]), math.abs(size[2]), math.abs(size[3])
            local radius
            if shape == "sphere" then
                radius = ax
            elseif shape == "capsule" then
                radius = ay / 2 + ax
            else
                radius = math.sqrt(ax * ax + ay * ay + az * az) / 2
            end
            local rotLine = p.rot or ""
            local rot = rots[rotLine]
            if not rot then
                rot = Driver.matrixTB(Colliders.frameOf(numbers(p.rot)))
                rots[rotLine] = rot
            end
            local pos = numbers(p.pos)
            -- one color table per color line: drawing sets the color only when it changes
            local colorLine = p.color or ""
            local color = colors[colorLine]
            if not color then
                color = colorOf(p.color)
                colors[colorLine] = color
            end
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
---@param props table<integer, table>? the props by atmo index (Dynamics' byIndex): drawn where they are now
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
    -- each cell as a sphere around its shapes' bounds (the on-screen test of a cell)
    for _, cell in ipairs(d.cellList) do
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

---Screen position of a point `e` out from `target` along `dir` (nil off screen or behind)
local function screenAt(target, dir, e)
    local x, y, z = get_screen_pos(target[1] + dir[1] * e, target[2] + dir[2] * e, target[3] + dir[3] * e)
    if x == nil or z ~= 0 then return nil end -- z 0: on screen (draw3d only)
    return x, y
end

-- the shares of the target's distance the projection is measured at, farthest first (MGE's world_select.lua)
local MEASURE_SHARES = { 0.25, 0.05 }

---The camera's view this frame (as MGE's WorldSelect.measureProjectionNow): eye, axes and the screen mapping
---of sideways / depth, measured with get_screen_pos around the camera's target. nil: draw everything
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
    for _, share in ipairs(MEASURE_SHARES) do
        local e = dist * share
        local rx1, ry1 = screenAt(target, right, e)
        local rx2, ry2 = screenAt(target, right, -e)
        local ux1, uy1 = screenAt(target, up, e)
        local ux2, uy2 = screenAt(target, up, -e)
        if rx1 and rx2 and ux1 and ux2 then
            local k = dist / (2 * e)
            local m11, m21 = (rx1 - rx2) * k, (ry1 - ry2) * k
            local m12, m22 = (ux1 - ux2) * k, (uy1 - uy2) * k
            if math.abs(m11 * m22 - m12 * m21) < 1e-9 then return nil end
            return { eye = eye, forward = forward, right = right, up = up, cx = (rx1 + rx2 + ux1 + ux2) / 4,
                cy = (ry1 + ry2 + uy1 + uy2) / 4, m11 = m11, m12 = m12, m21 = m21, m22 = m22,
                w = rawget(_G, "WIN_W") or 1920, h = rawget(_G, "WIN_H") or 1080 }
        end
    end
    return nil
end

---Whether a sphere at x y z of radius r can show on screen (MGE's onScreen): in front of the camera and
---overlapping the screen, with a margin. No view: true
local function onScreen(v, x, y, z, r)
    if not v then return true end
    local e, f = v.eye, v.forward
    local rx, ry, rz = x - e[1], y - e[2], z - e[3]
    local depth = rx * f[1] + ry * f[2] + rz * f[3]
    if depth < -r then return false end -- behind the camera
    if depth <= r then return true end -- around the camera
    local right, up = v.right, v.up
    local a = (rx * right[1] + ry * right[2] + rz * right[3]) / depth
    local b = (rx * up[1] + ry * up[2] + rz * up[3]) / depth
    local sx, sy = v.cx + v.m11 * a + v.m12 * b, v.cy + v.m21 * a + v.m22 * b
    local sr = r / depth * math.sqrt(v.m11 * v.m11 + v.m21 * v.m21) * 1.5 + 8
    return sx + sr >= 0 and sx - sr <= v.w and sy + sr >= 0 and sy - sr <= v.h
end
Drawer.onScreen = onScreen

---------------------------------------------------------------------------------------------------- drawing

local lastColor = nil -- the color set last (drawItem sets it only when it changes)

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

---Draws the shapes that can show this frame (draw3d)
---@param d table Drawer.new's
---@param view table? Drawer.measureView's (nil: every shape)
---@param level integer the game's graphics level (0-2)
---@return integer drawn
function Drawer.draw(d, view, level)
    local drawn = 0
    lastColor = nil -- others drew in between
    for _, cell in ipairs(d.cellList) do
        local cp = cell.pos
        if onScreen(view, cp[1], cp[2], cp[3], cell.radius) then
            local items = cell.items
            for k = 1, #items do
                local item = items[k]
                if level >= item.minLevel and level <= item.maxLevel then
                    local p = item.pos
                    if onScreen(view, p[1], p[2], p[3], item.radius) then
                        drawItem(item, p[1], p[2], p[3], item.rot)
                        drawn = drawn + 1
                    end
                end
            end
        end
    end
    -- props: where they are now, not while an object carries them (it shows them)
    for _, item in ipairs(d.moving) do
        local prop = item.prop
        if not prop.entry and level >= item.minLevel and level <= item.maxLevel then
            local p = prop.pos
            if onScreen(view, p[1], p[2], p[3], item.radius) then
                drawItem(item, p[1], p[2], p[3], prop.rot)
                drawn = drawn + 1
            end
        end
    end
    d.drawn = drawn
    return drawn
end

NS.Drawer = Drawer
return Drawer
