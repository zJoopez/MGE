-- Camera framing. The game's orbit camera (mode 4) caps its distance at ~13.5 and undoes set_camera_pos
-- every frame; returning 1 from the camera hook keeps MGE's position but stops the game's orbiting.
-- So while MGE controls the camera it owns it: places it every frame and does orbit (left drag) and zoom
-- (wheel) itself. Control goes back when the window hides, the camera mode changes or MGE quits

local SHAPE = MGE.SHAPE
local HOOK_SET = MGE.hookname .. "_camera"
local atan2 = math.atan2 or math.atan -- 5.1 has atan2

---@class Camera
---@field followMoves boolean
local Camera = {
    fitFactor = 2.5,     -- camera distance per unit of selection radius
    margin = 1,          -- extra distance so objects don't touch the screen edges
    -- closest framing distance: the game clips what's nearer than ~5 to the camera
    minDistance = 6,
    -- objects count with at most this radius when framing (mods use huge ground objects)
    maxObjectRadius = 10,
    zoomStep = 1.15,     -- distance factor per wheel step
    zoomMin = 6,         -- same clip limit as minDistance
    zoomMax = 200,       -- also the furthest framing distance
    orbitSpeed = 0.008,  -- radians per dragged pixel
    maxPitch = math.rad(85),
    dragThreshold = 4,   -- pixels before a press becomes an orbit (shorter clicks select)
    -- only the left button's presses reach Lua (right / middle send just the release)
    orbitButtons = { [1] = true },
    ---@type number? MGE's camera distance, nil while the game controls the camera
    distance = nil,
    followMoves = true,  -- selecting and moving point the camera at the selection (top bar toggle)
    ---@type number[]? look-at point
    target = nil,
    yaw = 0,             -- direction from the target to the camera
    pitch = 0.0,         -- radians, kept above the floor (Camera.minPitch)
}

---@type { x: number, y: number, dragging: boolean, button: integer }?
local drag = nil

local function gizmoBusy()
    return MGE.Gizmo ~= nil and MGE.Gizmo.isDragging()
end

---Distance from an object's center to its furthest point
---@param id integer 0-based object id
---@return number
local function objectRadius(id)
    local sx, sy, sz = get_obj_sides(id)
    local shape = get_obj_shape(id)
    if shape == SHAPE.SPHERE then return sx end                 -- x radius
    if shape == SHAPE.CAPSULE then return sy / 2 + sx end       -- half length + radius
    return math.sqrt(sx * sx + sy * sy + sz * sz) / 2           -- box: half diagonal
end

---Bounding sphere of the objects (each at most maxObjectRadius), centered on the selection pivot so
---the gizmo sits mid-screen
---@param objects FileParserEnvObj[]
---@return number[]? center, number radius
function Camera.bounds(objects)
    local Transforms = MGE.Transforms
    local positions = {}
    for _, obj in ipairs(objects) do
        if obj.kind == "atmo" then
            -- atmo: from its ghost (its id isn't an object's)
            local g = MGE.AtmoLayer.ghost(obj)
            if g then
                table.insert(positions, { pos = g.pos, radius = math.min(g.radius, Camera.maxObjectRadius) })
            end
        elseif get_obj_pos(obj.id - 1) ~= nil then -- file position, like the pivot
            local radius = math.min(objectRadius(obj.id - 1), Camera.maxObjectRadius)
            table.insert(positions, { pos = Transforms.positionOf(obj), radius = radius })
        end
    end
    if #positions == 0 then return nil, 0 end
    local cx, cy, cz = Transforms.getSelectionPivot(objects)
    local center = { cx, cy, cz }
    local radius = 0
    for _, entry in ipairs(positions) do
        local d = math.sqrt((entry.pos[1] - center[1]) ^ 2 + (entry.pos[2] - center[2]) ^ 2 + (entry.pos[3] - center[3]) ^ 2)
        radius = math.max(radius, d + entry.radius)
    end
    return center, radius
end

---Camera distance that fits a sphere of this radius on screen
---@param radius number
---@return number
function Camera.fitDistance(radius)
    return math.min(math.max(radius * Camera.fitFactor + Camera.margin, Camera.minDistance), Camera.zoomMax)
end

---@return number x, number y, number z MGE camera's position from target, yaw, pitch and distance
local function orbitPos()
    local t, d, cp = Camera.target, Camera.distance, math.cos(Camera.pitch)
    return t[1] + math.cos(Camera.yaw) * cp * d, t[2] + math.sin(Camera.yaw) * cp * d, t[3] + math.sin(Camera.pitch) * d
end

---Camera position and unit view direction (MGE's or the game's); with MGE's camera also the distance
---to its target, where spawnPoint puts things
---@return number[] origin, number[] dir, number? lookDistance
function Camera.viewRay()
    local origin, lookat, lookDistance
    if Camera.distance and Camera.target then
        origin = { orbitPos() }
        lookat, lookDistance = Camera.target, Camera.distance
    else
        local c = get_camera_info()
        origin, lookat = { c.pos.x, c.pos.y, c.pos.z }, { c.lookat.x, c.lookat.y, c.lookat.z }
    end
    local dir = { lookat[1] - origin[1], lookat[2] - origin[2], lookat[3] - origin[3] }
    local len = math.sqrt(dir[1] ^ 2 + dir[2] ^ 2 + dir[3] ^ 2)
    if len < 1e-6 then return origin, { 0, 1, 0 } end
    return origin, { dir[1] / len, dir[2] / len, dir[3] / len }, lookDistance
end

-- Spawning in view (Generate, imports, New): new things go on screen at about framing distance.
-- On the game's camera they land on the floor where the view meets it, if that's within
-- GROUND_NEAR..GROUND_FAR of the framing distance (or up to GROUND_MAX)
Camera.GROUND_Z = 0
Camera.GROUND_NEAR = 1
Camera.GROUND_FAR = 1.6
Camera.GROUND_MAX = 25

---@class SpawnBounds box around what is spawned, world axes, any position
---@field min number[]
---@field max number[]

---Where something goes in front of the camera, never below the floor. MGE's camera: at its target (any
---other spot would make camera follow walk the camera). The game's camera: on the floor (see GROUND_*),
---else on the view line at framing distance
---@param bounds SpawnBounds
---@param origin number[]? view line to use (Generate keeps one), defaults to Camera.viewRay()
---@param dir number[]? unit direction of that line
---@param lookDistance number? MGE camera's target distance (viewRay's third value)
---@return number[] point x y: the center goes there, z: the lowest point
function Camera.spawnPoint(bounds, origin, dir, lookDistance)
    if not origin or not dir then origin, dir, lookDistance = Camera.viewRay() end
    local size = {}
    for k = 1, 3 do size[k] = bounds.max[k] - bounds.min[k] end
    if lookDistance then
        local p = {}
        for k = 1, 3 do p[k] = origin[k] + dir[k] * lookDistance end
        return { p[1], p[2], math.max(Camera.GROUND_Z, p[3] - size[3] / 2) }
    end
    local distance = Camera.fitDistance(math.sqrt(size[1] ^ 2 + size[2] ^ 2 + size[3] ^ 2) / 2)
    local groundZ = Camera.GROUND_Z
    if dir[3] < -1e-3 then -- looking down: where the view meets the floor
        local t = (groundZ - origin[3]) / dir[3]
        if t >= distance * Camera.GROUND_NEAR and t <= math.max(distance * Camera.GROUND_FAR, Camera.GROUND_MAX) then
            return { origin[1] + dir[1] * t, origin[2] + dir[2] * t, groundZ }
        end
    end
    local p = {}
    for k = 1, 3 do p[k] = origin[k] + dir[k] * distance end
    return { p[1], p[2], math.max(groundZ, p[3] - size[3] / 2) }
end

---Offset that moves bounds so their center (x y) and lowest point (z) are at point
---@param bounds SpawnBounds
---@param point number[] from Camera.spawnPoint
---@return number[]
function Camera.spawnShift(bounds, point)
    return {
        point[1] - (bounds.min[1] + bounds.max[1]) / 2,
        point[2] - (bounds.min[2] + bounds.max[2]) / 2,
        point[3] - bounds.min[3],
    }
end

-- The game pushes a camera below the floor up next to the target (collapsing the gizmo), so the orbit
-- stops this far above the floor
Camera.minHeight =  0

---Lowest pitch that keeps the camera at least minHeight above the floor
---@param target number[]
---@param distance number
---@return number pitch radians (from -maxPitch to maxPitch)
function Camera.minPitch(target, distance)
    if distance <= 1e-6 then return -Camera.maxPitch end
    local s = (Camera.GROUND_Z + Camera.minHeight - target[3]) / distance -- sin(pitch) at the floor
    if s <= -1 then return -Camera.maxPitch end
    if s >= 1 then return Camera.maxPitch end -- target far underground: as high as the camera goes
    return math.min(math.max(math.asin(s), -Camera.maxPitch), Camera.maxPitch)
end

---Places the camera from target, yaw, pitch and distance, above the floor. Clamps the pitch itself, so
---dragging back up answers at once
local function place()
    local t = Camera.target
    Camera.pitch = math.max(Camera.pitch, Camera.minPitch(t, Camera.distance))
    set_camera_lookat(t[1], t[2], t[3])
    set_camera_pos(orbitPos())
end

---True while MGE owns the camera
---@return boolean
function Camera.isControlling()
    return Camera.distance ~= nil
end

---Gives the camera back to the game
function Camera.release()
    Camera.distance, Camera.target, drag = nil, nil, nil
    remove_hooks(HOOK_SET)
end

---MGE's camera works while the window shows, or in the placement view
local function windowShown()
    local Main = MGE.Main
    if MGE.isPlacing() then return true end
    return Main and Main.window and Main.window.displayed
end

local function overUI(x, y)
    return MGE.Widgets and MGE.Widgets.isMouseOverUI(x, y)
end

local function takeControl()
    remove_hooks(HOOK_SET)
    add_hook("camera", HOOK_SET, function()
        if not Camera.distance or get_camera_mode() ~= 4 or not windowShown() then
            Camera.release()
            return
        end
        place()
        return 1 -- skip the game's camera update
    end)
    add_hook("mouse_button_down", HOOK_SET, function(button, x, y)
        if button == 4 or button == 5 then -- wheel: 4 up = closer
            -- the wheel's x, y aren't the cursor: use toriui's MOUSE_X / Y, so scrolling a list doesn't zoom
            if overUI(MOUSE_X or x, MOUSE_Y or y) or (MGE.overlayOpen and MGE.overlayOpen()) then return end
            local factor = button == 4 and 1 / Camera.zoomStep or Camera.zoomStep
            Camera.distance = math.min(math.max(Camera.distance * factor, Camera.zoomMin), Camera.zoomMax)
        elseif overUI(x, y) then
            return
        elseif Camera.orbitButtons[button] and not gizmoBusy() then
            -- dragging orbits, a short click still selects
            drag = { x = x, y = y, dragging = false, button = button }
        end
    end)
    add_hook("mouse_move", HOOK_SET, function(x, y)
        if not drag then return end
        -- the press grabbed a gizmo handle (its hook may run after this one)
        if gizmoBusy() then
            drag = nil
            return
        end
        local dx, dy = x - drag.x, y - drag.y
        if not drag.dragging then
            if math.abs(dx) <= Camera.dragThreshold and math.abs(dy) <= Camera.dragThreshold then return end
            drag.dragging = true
        end
        Camera.yaw = Camera.yaw - dx * Camera.orbitSpeed
        Camera.pitch = math.min(math.max(Camera.pitch + dy * Camera.orbitSpeed, -Camera.maxPitch), Camera.maxPitch)
        drag.x, drag.y = x, y
    end)
    add_hook("mouse_button_up", HOOK_SET, function(button)
        if drag and drag.button == button then drag = nil end
    end)
end

---Points the camera at the objects, keeping the zoom (Camera.focusOn)
---@param objects FileParserEnvObj[]
function Camera.focus(objects)
    local center, radius = Camera.bounds(objects)
    if not center then return end
    Camera.focusOn(center, radius)
end

---Points MGE's camera at a sphere from the current direction. Keeps the zoom unless the sphere wouldn't
---fit, then backs out just enough
---@param center number[]
---@param radius number
function Camera.focusOn(center, radius)
    local c = get_camera_info()
    if not Camera.isControlling() then
        -- start from the game's current view direction
        local dx, dy, dz = c.pos.x - c.lookat.x, c.pos.y - c.lookat.y, c.pos.z - c.lookat.z
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        if len < 1e-6 then dx, dy, dz, len = 1, -1, 0.6, math.sqrt(2.36) end
        Camera.yaw = atan2(dy, dx)
        Camera.pitch = math.min(math.max(math.asin(dz / len), -Camera.maxPitch), Camera.maxPitch)
        Camera.distance = len
    end

    local distance = math.max(Camera.fitDistance(radius), Camera.distance)

    set_camera_mode(4)
    MGE.cameraChanged = true -- reset on quit
    Camera.target = center
    Camera.distance = distance
    takeControl()
    place()
end

---Frames the selection when camera follow is on. Call only when something got selected
function Camera.followSelection()
    if not Camera.followMoves then return end
    local selected = MGE.ModData.getEditSelection()
    if #selected > 0 then Camera.focus(selected) end
end

---Frames the players around their shared center when camera follow is on. `after`: where an edit is
---taking them (the game places them a few frames after the reload)
---@param players integer|integer[] 0-based
---@param after { offset: number[]?, factor: number?, pivot: number[]? }?
function Camera.followPlayer(players, after)
    if not Camera.followMoves then return end
    local Players = MGE.Players
    if not Players then return end
    local list = {}
    for _, player in ipairs(type(players) == "table" and players or { players }) do
        if Players.exists(player) then table.insert(list, player) end
    end
    if #list == 0 then return end
    local center, radius = Players.groupCenter(list), 0
    for _, player in ipairs(list) do
        for _, id in pairs(BODYPARTS) do
            local p = get_body_info(player, id).pos
            radius = math.max(radius, math.sqrt((p.x - center[1]) ^ 2 + (p.y - center[2]) ^ 2 + (p.z - center[3]) ^ 2))
        end
    end
    if after and after.offset then
        for k = 1, 3 do center[k] = center[k] + after.offset[k] end
    end
    if after and after.factor then
        local pivot = after.pivot or center
        for k = 1, 3 do center[k] = pivot[k] + (center[k] - pivot[k]) * after.factor end
        radius = radius * after.factor
    end
    Camera.focusOn(center, math.min(radius + 0.5, Camera.maxObjectRadius))
end

table.insert(MGE.onQuit, Camera.release)

MGE.Camera = Camera
