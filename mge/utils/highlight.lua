-- Selection highlights (based on rph's replayhacks_selection.lua), previews and the atmo layer
require("toriui.uielement3d") -- Utils3D.MatrixToMatrixTB

local ModData = MGE.ModData
local SHAPE = MGE.SHAPE

---@class HighlightBox
---@field pos number[]
---@field sides number[]
---@field frame number[][] rotation, columns are the box's axes in world space
---@field rotTB MatrixTB? ready draw rotation (moved props), used instead of frame

local Highlight = {
    color = { 0.0, 0.333, 1.0 },
    fillAlpha = 0.25,
    previewColor = { 1.0, 0.6, 0.0 },
    previewAlpha = 0.2,
    -- the selection highlights' share of the game's shapes a frame
    drawRoom = 256,
    ---@type (fun(): HighlightBox[]?, number[][]?)? Generate tab: boxes and joint anchors to draw this frame
    preview = nil,
    ---@type fun()? map placement view's drawing (ui/map_place.lua)
    placement = nil,
    errorShown = false,
}
MGE.Highlight = Highlight

---Row-major rotation (as get_obj_rot gives it) for draw_*_m
---@param m number[][]
---@return MatrixTB
local function toMatrixTB(m)
    return Utils3D.MatrixToMatrixTB({
        m[1][1], m[1][2], m[1][3], 0,
        m[2][1], m[2][2], m[2][3], 0,
        m[3][1], m[3][2], m[3][3], 0,
    })
end

Highlight.toMatrixTB = toMatrixTB

-- Converted rotations by frame table: frames are never changed in place, so each converts once.
-- Weak keys let dropped boxes go
local rotCache = setmetatable({}, { __mode = "k" })

---A box's rotation for draw_*_m: a moved prop's ready one (Playable.movedGhost), else its frame's
---@param box HighlightBox|AtmoGhost
---@return MatrixTB
local function rotOf(box)
    local rot = box.rotTB or rotCache[box.frame]
    if not rot then
        rot = toMatrixTB(box.frame)
        rotCache[box.frame] = rot
    end
    return rot
end

-- While drawAtmo runs, set_color only on change: thousands of atmo shapes mostly share a color
local colorCaching, lastColor, lastAlpha = false, nil, nil

local function setColor(c, alpha)
    if colorCaching then
        if c == lastColor and alpha == lastAlpha then return end
        lastColor, lastAlpha = c, alpha
    end
    set_color(c[1], c[2], c[3], alpha)
end

---A box that isn't an object: translucent fill plus an outline (negative-size pass) unless outline is
---false. fillAlpha 0 draws only the outline
---@param box HighlightBox
---@param color number[]
---@param fillAlpha number
---@param outline boolean?
---@param grow number? added to each side of the fill
function Highlight.drawBox(box, color, fillAlpha, outline, grow)
    local p, s, c = box.pos, box.sides, color
    grow = grow or 0
    local rot = rotOf(box)
    if fillAlpha > 0 then
        setColor(c, fillAlpha)
        draw_box_m(p[1], p[2], p[3], s[1] + grow, s[2] + grow, s[3] + grow, rot)
    end
    if outline ~= false then
        setColor(c, 1.0)
        draw_box_m(p[1], p[2], p[3], -(s[1] + 0.02), -(s[2] + 0.02), -(s[3] + 0.02), rot)
    end
end

---The Generate tab's preview boxes
---@param box HighlightBox
local function drawPreviewBox(box)
    Highlight.drawBox(box, Highlight.previewColor, Highlight.previewAlpha, true)
end

---get_obj_rot returns a flat array, draw_*_m expects a MatrixTB (r0..r15)
---@param id integer 0-based object id
---@return MatrixTB?
local function getObjRotTB(id)
    local rot = get_obj_rot(id)
    if type(rot) ~= "table" then return nil end
    return Utils3D.MatrixToMatrixTB(rot)
end

local colorByLine = {}

---An atmo object's color clamped to 0-1 (atmos allow up to 2). One shared, read-only table per color
---line: parsed once, and setColor's caching compares tables
---@param obj FileParserEnvObj
---@return number[]
local function colorOf(obj)
    local line = obj.props.color or "1 1 1 1"
    local c = colorByLine[line]
    if c then return c end
    c = {}
    for n in tostring(line):gmatch("%S+") do c[#c + 1] = tonumber(n) or 1 end
    for k = 1, 4 do c[k] = math.min(math.max(c[k] or 1, 0), 1) end
    colorByLine[line] = c
    return c
end

---An atmo shape: boxes through drawBox, spheres and pills filled
---@param g AtmoGhost
---@param c number[]
---@param alpha number
---@param outline boolean
---@param grow number? added to sides (half to a radius)
local function drawGhost(g, c, alpha, outline, grow)
    local p, s = g.pos, g.sides
    grow = grow or 0
    if g.shape == "box" then
        Highlight.drawBox(g, c, alpha, outline, grow)
        return
    end
    local rot = rotOf(g)
    setColor(c, alpha)
    if g.shape == "sphere" then
        draw_sphere_m(p[1], p[2], p[3], s[1] + grow / 2, rot)
    else -- pill: x radius, y length
        draw_capsule_m(p[1], p[2], p[3], s[2], s[1] + grow / 2, rot)
    end
end

-- The Atmo list draws atmo shapes this much larger: an atmo copy exactly on a see-through real object
-- would lose the depth test to it. Less than the selection highlight's margin
local GROW = 0.01

---Selection highlight: a slightly larger translucent fill, then a bigger inverted shell as outline
---(2 draws). fillOnly: the fill alone, when full ones don't fit the frame's draws
---@param shape "box"|"sphere"|"pill"
---@param x number
---@param y number
---@param z number
---@param sx number box x side, sphere and pill radius
---@param sy number box y side, pill length
---@param sz number box z side
---@param rot MatrixTB?
---@param color number[]
---@param fillOnly boolean?
local function drawShapeHighlight(shape, x, y, z, sx, sy, sz, rot, color, fillOnly)
    local c = color
    set_color(c[1], c[2], c[3], Highlight.fillAlpha)
    if shape == "sphere" then
        draw_sphere_m(x, y, z, sx + 0.01, rot)
        if fillOnly then return end
        set_color(c[1], c[2], c[3], 1.0)
        draw_sphere_m(x, y, z, -(sx + 0.02), rot)
    elseif shape == "box" then
        draw_box_m(x, y, z, sx + 0.02, sy + 0.02, sz + 0.01, rot)
        if fillOnly then return end
        set_color(c[1], c[2], c[3], 1.0)
        draw_box_m(x, y, z, -(sx + 0.04), -(sy + 0.04), -(sz + 0.02), rot)
    else -- pill
        draw_capsule_m(x, y, z, sy + 0.01, sx + 0.01, rot)
        if fillOnly then return end
        set_color(c[1], c[2], c[3], 1.0)
        draw_capsule_m(x, y, z, -(sy + 0.02), -(sx + 0.02), rot)
    end
end

-- selected atmo objects (Atmo list) are at least this opaque
local SELECTED_ALPHA = 0.75

---@type CameraProjection? this frame's view, measured at the start of draw3d
local view = nil

---Whether a ghost's bounding sphere can overlap the screen this frame (with a margin). True without a view
---@param g AtmoGhost
---@return boolean
local function onScreen(g)
    local v = view
    if not v then return true end
    local e, f = v.eye, v.forward
    local rx, ry, rz = g.pos[1] - e[1], g.pos[2] - e[2], g.pos[3] - e[3]
    local r = g.radius or 0
    local depth = rx * f[1] + ry * f[2] + rz * f[3]
    if depth < -r then return false end -- behind the camera
    if depth <= r then return true end -- around the camera: some of it can be in view
    local a = (rx * v.right[1] + ry * v.right[2] + rz * v.right[3]) / depth
    local b = (rx * v.up[1] + ry * v.up[2] + rz * v.up[3]) / depth
    local x, y = v.cx + v.m11 * a + v.m12 * b, v.cy + v.m21 * a + v.m22 * b
    -- generous screen radius: spheres near the edge project bigger
    local sr = r / depth * math.sqrt(v.m11 * v.m11 + v.m21 * v.m21) * 1.5 + 8
    return x + sr >= 0 and x - sr <= WIN_W and y + sr >= 0 and y - sr <= WIN_H
end

-- reused probe for props' ghosts (Playable.drawGhosts)
local ghostProbe = { pos = { 0, 0, 0 }, radius = 0 }

---Whether a prop's ghost at x y z with bounding radius r can show this frame
local function ghostOnScreen(x, y, z, r)
    local p = ghostProbe.pos
    p[1], p[2], p[3], ghostProbe.radius = x, y, z, r
    return onScreen(ghostProbe)
end

-- Atmo drawing: at most AtmoLayer.maxDraws on-screen ghosts a frame, nearest first (the game caps shapes).
-- Objects list: translucent ghosts in AtmoLayer.color. Atmo list: own colors, selected ones in the
-- highlight color (color only, so thousands selected all show), where a drag has them

-- drawAtmo's on-screen ghosts this frame (reused): ghost, color, alpha, grow, distance, draw order
local visG, visC, visA, visGrow, visDist, visOrder = {}, {}, {}, {}, {}, {}
local visN = 0
local function nearerVis(i, j) return visDist[i] < visDist[j] end

-- orderNearest's buckets: sorting thousands with table.sort was most of a frame
local BUCKETS = 256
local bucketCount, bucketEnd, visKey, boundary = {}, {}, {}, {}

---visOrder[1..n] near to far by distance buckets, exactly sorted in the bucket holding the most-th, so
---visOrder[1..most] are exactly the nearest most
local function orderNearest(n, most)
    if n == 0 then return end
    local sqrt, lo, hi = math.sqrt, math.huge, 0
    for i = 1, n do
        local d = sqrt(visDist[i])
        visKey[i] = d
        if d < lo then lo = d end
        if d > hi then hi = d end
    end
    local scale = hi > lo and (BUCKETS - 1e-9) / (hi - lo) or 0
    for b = 1, BUCKETS do bucketCount[b] = 0 end
    for i = 1, n do
        local b = math.floor((visKey[i] - lo) * scale) + 1
        visKey[i] = b
        bucketCount[b] = bucketCount[b] + 1
    end
    local at = 1
    for b = 1, BUCKETS do
        bucketEnd[b] = at -- next free slot while placing; one past the bucket's end after
        at = at + bucketCount[b]
    end
    for i = 1, n do
        local b = visKey[i]
        local slot = bucketEnd[b]
        visOrder[slot] = i
        bucketEnd[b] = slot + 1
    end
    if most >= n then return end
    -- the bucket holding the most-th: sorted exactly
    local b = 1
    while bucketEnd[b] <= most do b = b + 1 end
    local first, last = bucketEnd[b] - bucketCount[b], bucketEnd[b] - 1
    local m = 0
    for k = first, last do
        m = m + 1
        boundary[m] = visOrder[k]
    end
    for k = #boundary, m + 1, -1 do boundary[k] = nil end
    table.sort(boundary, nearerVis)
    for k = 1, m do visOrder[first + k - 1] = boundary[k] end
end
-- Squared-distance cutoff from last frame's maxDraws-th (with a margin). A pass that finds too few under
-- it reruns without one, so the drawn ones are always the nearest
local visCut = math.huge
local CUT_MARGIN = 2 -- squared: ~1.4x the distance, room for camera movement
local pendingDist = 0 -- nearEnough's distance for addVisible

---Cheap test before onScreen; keeps the squared distance for addVisible
local function nearEnough(g)
    local e = view and view.eye
    if not e then
        pendingDist = 0
        return true
    end
    local p = g.pos
    local dx, dy, dz = p[1] - e[1], p[2] - e[2], p[3] - e[3]
    pendingDist = dx * dx + dy * dy + dz * dz
    return pendingDist < visCut
end

local function addVisible(g, c, alpha, grow)
    visN = visN + 1
    local n = visN
    visG[n], visC[n], visA[n], visGrow[n], visOrder[n], visDist[n] = g, c, alpha, grow or 0, n, pendingDist
end

-- Selected ghosts on screen (Atmo list): drawn first in list order, unsorted; the nearest others fill the rest
local selG, selA, selGrow = {}, {}, {}
local selN = 0

---Collects ghosts that can show: selected ones into sel (up to `most`), the rest under the cutoff into vis
---@param full boolean
---@param plain boolean?
---@param most number
local function collectAtmo(full, plain, most)
    local AtmoLayer = MGE.AtmoLayer
    local list = ModData.parsed.atmo or {}
    -- props moved in a fight (playable mods) are drawn where they are now
    local moved = MGE.Playable and MGE.Playable.movedGhost
    visN, selN = 0, 0
    if not full then
        for i, obj in ipairs(list) do
            local g = AtmoLayer.ghost(obj)
            if g and moved then g = moved(i, g) end
            if g and nearEnough(g) and onScreen(g) then addVisible(g, AtmoLayer.color, AtmoLayer.alpha) end
        end
        return
    end
    local live = AtmoLayer.live -- a gizmo drag in progress
    local grow = not plain and GROW or 0 -- F1's play view: as in game
    for i, atmoObj in ipairs(list) do
        if selN >= most then break end -- selected ones fill every draw
        local g = AtmoLayer.ghost(atmoObj)
        if g and moved then g = moved(i, g) end
        local selected = atmoObj.selected and not plain
        if g and live and selected then g = AtmoLayer.liveGhost(g, live) end
        if g then
            if selected then
                if onScreen(g) then
                    selN = selN + 1
                    selG[selN], selA[selN], selGrow[selN] = g, math.max(colorOf(atmoObj)[4], SELECTED_ALPHA), grow
                end
            elseif nearEnough(g) and onScreen(g) then
                local c = colorOf(atmoObj)
                addVisible(g, c, c[4], grow)
            end
        end
    end
end

---@param full boolean
---@param plain boolean? with full: as when played (window hidden), no selection highlight
local function drawAtmo(full, plain)
    local most = MGE.AtmoLayer.maxDraws
    if not (most and most > 0) then most = math.huge end
    if not view then visCut = math.huge end
    collectAtmo(full, plain, most)
    local room = most - math.min(selN, most) -- draws left for the unselected
    if visN < room and visCut < math.huge then -- cutoff left too few: retry without it
        visCut = math.huge
        collectAtmo(full, plain, most)
        room = most - math.min(selN, most)
    end
    local n = visN
    for i = #visOrder, n + 1, -1 do visOrder[i] = nil end
    if view and room > 0 then orderNearest(n, room) end
    if n > room then n = room end
    -- next frame's cutoff: this frame's room-th with a margin (none if fewer show, 0 if selected fill it)
    if not view then
        visCut = math.huge
    elseif room <= 0 then
        visCut = 0
    else
        visCut = visN >= room and visDist[visOrder[room]] * CUT_MARGIN + 1 or math.huge
    end
    colorCaching, lastColor, lastAlpha = true, nil, nil
    local color = Highlight.color
    for k = 1, math.min(selN, most) do drawGhost(selG[k], color, selA[k], false, selGrow[k]) end
    for k = 1, n do
        local i = visOrder[k]
        drawGhost(visG[i], visC[i], visA[i], false, visGrow[i])
    end
    colorCaching = false
    visN, selN = 0, 0
end

---drawShapeHighlight on a game object
---@param id integer 0-based object id
---@param color number[]? defaults to Highlight.color
---@param fillOnly boolean?
local function drawObjectHighlight(id, color, fillOnly)
    local x, y, z = get_obj_pos(id)
    if x == nil then return end
    local sx, sy, sz = get_obj_sides(id)
    local shape = get_obj_shape(id)
    local name = shape == SHAPE.SPHERE and "sphere" or shape == SHAPE.BOX and "box"
        or shape == SHAPE.CAPSULE and "pill" or nil
    if not name then return end
    drawShapeHighlight(name, x, y, z, sx, sy, sz, getObjRotTB(id), color or Highlight.color, fillOnly)
end

---Full highlights (2 draws) when all fit in room, else fills alone (1 draw) on as many as fit
---@param count integer selected shapes
---@param room integer draws they have
---@return boolean fillOnly
---@return integer drawn how many get one
local function highlightPlan(count, room)
    room = math.max(0, room)
    if count * 2 <= room then return false, count end
    return true, math.min(count, room)
end

-- BodyInfo.shape: sphere x radius, box sides, cylinder (pill) x radius y length; 1 is a box
local BODY_SPHERE, BODY_CYLINDER = 0, 2

---One body part's highlight: a translucent fill and an outline, scaled by f around where `at` puts it
---@param player integer 0-based
---@param id integer body part
---@param c number[] color
---@param f number? scale, default 1
---@param at (fun(x: number, y: number, z: number): table)?
---@param sides number[]? drawn instead of the live sides (a parts scale preview)
local function drawBodyHighlight(player, id, c, f, at, sides)
    f = f or 1
    local b = get_body_info(player, id)
    local p, rot = at and at(b.pos.x, b.pos.y, b.pos.z) or b.pos, b.rot
    local s = sides and { x = sides[1], y = sides[2], z = sides[3] }
        or { x = b.sides.x * f, y = b.sides.y * f, z = b.sides.z * f }
    set_color(c[1], c[2], c[3], Highlight.fillAlpha)
    if b.shape == BODY_SPHERE then
        draw_sphere_m(p.x, p.y, p.z, s.x + 0.01, rot)
        set_color(c[1], c[2], c[3], 1.0)
        draw_sphere_m(p.x, p.y, p.z, -(s.x + 0.02), rot)
    elseif b.shape == BODY_CYLINDER then
        draw_capsule_m(p.x, p.y, p.z, s.y + 0.01, s.x + 0.01, rot)
        set_color(c[1], c[2], c[3], 1.0)
        draw_capsule_m(p.x, p.y, p.z, -(s.y + 0.02), -(s.x + 0.02), rot)
    else
        draw_box_m(p.x, p.y, p.z, s.x + 0.02, s.y + 0.02, s.z + 0.02, rot)
        set_color(c[1], c[2], c[3], 1.0)
        draw_box_m(p.x, p.y, p.z, -(s.x + 0.04), -(s.y + 0.04), -(s.z + 0.04), rot)
    end
end

---The object highlight on a player's body parts and joints. With scale (a scale drag), drawn scaled
---around the pivot in the preview color: bodies can't be resized live
---@param player integer 0-based
---@param scale { pivot: number[], factor: number }?
local function drawPlayerHighlight(player, scale)
    local c = scale and Highlight.previewColor or Highlight.color
    local f = scale and scale.factor or 1
    ---@param x number
    ---@param y number
    ---@param z number
    ---@return table
    local function at(x, y, z)
        if not scale then return { x = x, y = y, z = z } end
        local q = scale.pivot
        return { x = q[1] + (x - q[1]) * f, y = q[2] + (y - q[2]) * f, z = q[3] + (z - q[3]) * f }
    end
    for _, id in pairs(BODYPARTS) do drawBodyHighlight(player, id, c, f, at) end
    set_color(c[1], c[2], c[3], Highlight.fillAlpha)
    for _, id in pairs(JOINTS) do
        local x, y, z = get_joint_pos(player, id)
        if x then
            local p = at(x, y, z)
            draw_sphere(p.x, p.y, p.z, (get_joint_radius(player, id) or 0.1) * f + 0.01)
        end
    end
end

local JOINT_ANCHOR_RADIUS = 0.12
-- the halo's radius: what a click on an anchor hits (WorldSelect.pickJoint)
Highlight.anchorPickRadius = JOINT_ANCHOR_RADIUS * 2

---A joint's anchor: solid core plus translucent halo (readable inside objects). Faint: unselected
---@param faint boolean?
local function drawAnchor(x, y, z, faint)
    local c = Highlight.previewColor
    set_color(c[1], c[2], c[3], faint and 0.35 or 1.0)
    draw_sphere(x, y, z, JOINT_ANCHOR_RADIUS)
    set_color(c[1], c[2], c[3], faint and 0.1 or 0.3)
    draw_sphere(x, y, z, JOINT_ANCHOR_RADIUS * 2)
end

---A joint's anchor, where a Move drag has it (Joints.anchorOf)
---@param joint FileParserEnvObjJoint
---@param faint boolean?
local function drawJointAnchor(joint, faint)
    local p = MGE.Joints.anchorOf(joint)
    if p then drawAnchor(p[1], p[2], p[3], faint) end
end

---Joints list: selected joints' objects highlighted and anchors bright; other anchors faint (clickable)
---@param joints FileParserEnvObjJoint[] the selected ones
local function drawJointHighlights(joints)
    local objects, selected = {}, {}
    for _, joint in ipairs(joints) do
        selected[joint] = true
        if joint.obj1 then objects[joint.obj1] = true end
        if joint.obj2 then objects[joint.obj2] = true end
    end
    for id in pairs(objects) do drawObjectHighlight(id - 1) end
    for _, joint in ipairs(ModData.parsed.env_obj_joint) do
        if not selected[joint] then drawJointAnchor(joint, true) end
    end
    for _, joint in ipairs(joints) do drawJointAnchor(joint) end
end

local HOVER_COLOR = { 1.0, 1.0, 1.0 } -- what a click would pick (or take out)

---Link tab's draft: picked objects highlighted, the hovered one white, the anchor (a new joint's halfway
---between the two). Other selected joints' anchors bright, unselected faint
---@param slot integer
local function drawLinkHighlights(slot)
    local Joints = MGE.Joints
    local draft = Joints.draftFor(slot)
    local hover = MGE.WorldSelect and MGE.WorldSelect.hover
    if draft.obj1 then drawObjectHighlight(draft.obj1 - 1) end
    if draft.obj2 then drawObjectHighlight(draft.obj2 - 1) end
    if hover then drawObjectHighlight(hover.id - 1, HOVER_COLOR) end
    local selected = MGE.Main.selectedJoints
    for _, other in ipairs(ModData.parsed.env_obj_joint) do
        if other.id ~= slot then drawJointAnchor(other, not selected[other.id]) end
    end
    local joint = Joints.find(slot)
    if joint then
        drawJointAnchor(joint)
    elseif draft.obj1 and draft.obj2 then
        local ax, ay, az = get_obj_pos(draft.obj1 - 1)
        local bx, by, bz = get_obj_pos(draft.obj2 - 1)
        if ax and bx then drawAnchor((ax + bx) / 2, (ay + by) / 2, (az + bz) / 2) end
    end
end

add_hook("draw3d", MGE.hookname, function()
    local Main = MGE.Main -- created after this module loads
    if not Main or not Main.window then return end
    local ok, err = pcall(function()
        -- measured in draw3d: it uses get_screen_pos
        view = MGE.WorldSelect and MGE.WorldSelect.measureProjection() or nil
        -- called every frame even when not drawn: that's how Generate notices it was left
        local boxes, anchors
        if Highlight.preview then boxes, anchors = Highlight.preview() end
        if Highlight.placement then Highlight.placement() end -- map placement, on any list
        if not Main.window.displayed then
            -- window hidden (F1): the atmo as in game. The placement view draws alone
            if not MGE.isPlacing() then drawAtmo(true, true) end
            return
        end
        if Main.listTab == "players" and not Main.partsShown() then
            drawAtmo(false) -- faint ghosts, apart from solid objects
            -- selected players, or the scaled ones during a scale drag
            local Players = MGE.Players
            local scale = Players and Players.scalePreview
            for _, player in ipairs(scale and scale.players or Main.selectedPlayerList()) do
                if Players and Players.exists(player) then drawPlayerHighlight(player, scale) end
            end
            return
        end
        if Main.partsShown() then
            drawAtmo(false)
            local Players, PartTarget = MGE.Players, MGE.PartTarget
            local scale = PartTarget and PartTarget.scalePreview
            if scale then -- a scale drag: the parts (and twins) at their new size
                local SHAPES = { [BODY_SPHERE] = "sphere", [BODY_CYLINDER] = "cylinder" }
                for _, e in ipairs(scale.entries) do
                    if e.kind == "body" then
                        local b = get_body_info(e.player, e.id)
                        local sides = PartTarget.scaleSides(SHAPES[b.shape] or "box",
                            { b.sides.x, b.sides.y, b.sides.z }, scale.factors)
                        drawBodyHighlight(e.player, e.id, Highlight.previewColor, 1, nil, sides)
                    end
                end
                return
            end
            -- joints in a move / rotate drag: where they'll be (bodies move live)
            local moving = {}
            for _, e in ipairs(PartTarget and PartTarget.preview or {}) do
                if e.kind == "joint" and e.preview then
                    moving[e.player .. ":" .. e.id] = true
                    local c = Highlight.previewColor
                    set_color(c[1], c[2], c[3], 0.6)
                    draw_sphere(e.preview[1], e.preview[2], e.preview[3], (get_joint_radius(e.player, e.id) or 0.1) + 0.02)
                end
            end
            local exists = {} -- per player once a frame: Players.exists reads the gamerules and a body
            for _, part in ipairs(MGE.PartList and MGE.PartList.selected() or {}) do
                if exists[part.player] == nil then
                    exists[part.player] = Players ~= nil and Players.exists(part.player)
                end
                if exists[part.player] then
                    if part.kind == "joint" then
                        local id = JOINTS[part.name:upper()]
                        local x, y, z
                        if id then x, y, z = get_joint_pos(part.player, id) end
                        if x and not moving[part.player .. ":" .. id] then
                            local c = Highlight.color
                            set_color(c[1], c[2], c[3], 0.6)
                            draw_sphere(x, y, z, (get_joint_radius(part.player, id) or 0.1) + 0.02)
                        end
                    else
                        local id = BODYPARTS[part.name:upper()]
                        if id then drawBodyHighlight(part.player, id, Highlight.color) end
                    end
                end
            end
            return
        end
        if Main.listTab == "joints" then
            -- Link tab: the slot's draft instead
            local slot = Main.linkSlot()
            if slot then drawLinkHighlights(slot) else drawJointHighlights(Main.selectedJointList()) end
            return
        end
        -- the game caps shapes a frame: preview, atmo and selection each get a share
        for _, box in ipairs(boxes or {}) do drawPreviewBox(box) end
        for _, p in ipairs(anchors or {}) do drawAnchor(p[1], p[2], p[3]) end -- Generate's joints
        local atmo = Main.listTab == "atmo"
        drawAtmo(atmo)
        -- a pick in progress (color picker): the hovered object in white
        local WorldSelect = MGE.WorldSelect
        if WorldSelect and WorldSelect.picking and WorldSelect.hover then
            drawObjectHighlight(WorldSelect.hover.id - 1, HOVER_COLOR)
        end
        if not atmo then -- the Atmo list shows its selection through drawAtmo
            local ids = {}
            for _, obj in ipairs(ModData.parsed.env_obj) do
                if obj.selected then ids[#ids + 1] = obj.id - 1 end
            end
            local fillOnly, drawn = highlightPlan(#ids, Highlight.drawRoom)
            for i = 1, drawn do drawObjectHighlight(ids[i], nil, fillOnly) end
        end
    end)
    if not ok and not Highlight.errorShown then -- report once
        Highlight.errorShown = true
        MGE.say("highlight error: " .. tostring(err))
    end
    -- playable mods' prop ghosts (where the turn takes them), on the Atmo list and in the play view.
    -- Last: drawn earlier, a ghost fills the depth and its prop shows faded through it
    local ghosts = not Main.window.displayed or Main.listTab == "atmo"
    if ghosts and not MGE.isPlacing() and MGE.Playable and MGE.Playable.drawGhosts then
        MGE.Playable.drawGhosts(ghostOnScreen) -- catches its own errors
    end
end)
