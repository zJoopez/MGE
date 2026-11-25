-- Move, rotate and scale for the selection (editor rows and gizmo): changes go to the game (set_obj_*)
-- and the mod data, then History.commit and onChanged.
-- Positions and orientations come from the pos / rot lines, not the live world (dynamic objects fall);
-- the world only tells which objects exist. Atmo objects go through the same code using only their
-- lines: never pass their ids to get_obj_* / set_obj_*

local Transforms = {}
MGE.Transforms = Transforms

local RotatingOld = dofile(MGE.scriptPath .. "utils/rotating.lua")
local ModData = MGE.ModData
local History = MGE.History
local Joints = MGE.Joints
local Mat3 = MGE.Mat3
local FileHandler = MGE.FileHandler
local SHAPE = MGE.SHAPE
local POS_ORIGIN = MGE.POS_ORIGIN

-- defined further down, used by functions above them
local pickGroupFrame

---Called after every change (the editor refreshes its rows)
Transforms.onChanged = function() end

-- In place (top bar toggle): Rotate and Scale work on each object around itself, positions stay.
-- Off: the selection turns and scales as one group around its center
Transforms.inPlace = false

-- Rot / Rotate angle convention. true: the rot line's numbers (positive is clockwise down the axis, the
-- game's way). false: right-handed, so the file's "0 0 45" shows as -45
Transforms.fileAngles = true
---@return number 1 or -1: typed / shown angles into right-handed ones
local function angleSign() return Transforms.fileAngles and -1 or 1 end

---@param obj FileParserEnvObj
---@return boolean the object exists in the world (never an atmo object)
local function inWorld(obj)
    if obj.kind == "atmo" then return false end
    return get_obj_pos(obj.id - 1) ~= nil
end

---@param obj FileParserEnvObj
---@return boolean in the world, or an atmo object (its lines)
local function present(obj)
    return obj.kind == "atmo" or inWorld(obj)
end

---Position from the pos line; else the live one (atmo: 0 0 0)
---@param obj FileParserEnvObj
---@return number[]
local function positionOf(obj)
    -- atmo: the cached ghost's, read for every selected one on each edit
    if obj.kind == "atmo" and MGE.AtmoLayer then
        local g = MGE.AtmoLayer.ghost(obj)
        if g and g.pos[3] then return { g.pos[1], g.pos[2], g.pos[3] } end
        if not g then return { 0, 0, 0 } end
    end
    local x, y, z = (obj.props.pos or ""):match("(%S+)%s+(%S+)%s+(%S+)")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x and y and z then return { x, y, z } end
    if obj.kind == "atmo" then return { 0, 0, 0 } end
    return { get_obj_pos(obj.id - 1) }
end

---Sides: the game's live ones, or an atmo object's sides line
---@param obj FileParserEnvObj
---@return number, number, number
local function sidesOf(obj)
    if obj.kind == "atmo" then
        -- the cached ghost's
        local g = MGE.AtmoLayer and MGE.AtmoLayer.ghost(obj)
        if g then
            local s = g.fileSides
            return s[1] or 1, s[2] or 1, s[3] or 1
        end
        local s = {}
        for n in tostring(obj.props.sides or ""):gmatch("%S+") do s[#s + 1] = tonumber(n) end
        return s[1] or 1, s[2] or 1, s[3] or 1
    end
    return get_obj_sides(obj.id - 1)
end

---Shape (MGE.SHAPE): the game's, or an atmo object's shape line
---@param obj FileParserEnvObj
---@return integer
local function shapeIdOf(obj)
    if obj.kind == "atmo" then
        local name = MGE.AtmoLayer.shapeOf(obj)
        return name == "sphere" and SHAPE.SPHERE or name == "cylinder" and SHAPE.CAPSULE or SHAPE.BOX
    end
    return get_obj_shape(obj.id - 1)
end

---Without atmo objects: what joints and live calls see
---@param objects FileParserEnvObj[]
---@return FileParserEnvObj[]
local function worldOnly(objects)
    local out = {}
    for _, obj in ipairs(objects) do
        if obj.kind ~= "atmo" then out[#out + 1] = obj end
    end
    return out
end

---What the rows work on (atmo on the Atmo list)
---@return FileParserEnvObj[]
local function getSelected() return ModData.getEditSelection() end

---@param obj FileParserEnvObj
---@return number[] the rot line in radians, 0 0 0 without one
local function rotLine(obj)
    local x, y, z = (obj.props.rot or ""):match("(%S+)%s+(%S+)%s+(%S+)")
    return { math.rad(tonumber(x) or 0), math.rad(tonumber(y) or 0), math.rad(tonumber(z) or 0) }
end

---Puts the object's live rotation back to its rot line (after the game tumbled it)
---@param obj FileParserEnvObj
local function applyFileRotation(obj)
    if not inWorld(obj) then return end
    local r = rotLine(obj)
    set_obj_rot(obj.id - 1, r[1], r[2], r[3])
end

-- Read-only orientations by rot line (big maps share few lines). Reset when big: rotates add lines
---@type table<string, number[][]>
local orientationByRot, orientationCount = {}, 0

---Orientation from the rot line (degrees; none is 0 0 0), columns are the local axes in world space.
---The game reads rot x y z as Rx(-x) Ry(-y) Rz(-z) (matches get_obj_rot and rotating.lua)
---@param obj FileParserEnvObj
---@return number[][]
local function orientationOf(obj)
    local line = obj.props.rot or ""
    local m = orientationByRot[line]
    if m then return m end
    local r = rotLine(obj)
    local x, y, z = r[1], r[2], r[3]
    m = Mat3.mul(Mat3.rotX(-x), Mat3.mul(Mat3.rotY(-y), Mat3.rotZ(-z)))
    if orientationCount >= 4096 then orientationByRot, orientationCount = {}, 0 end
    orientationByRot[line], orientationCount = m, orientationCount + 1
    return m
end

---@param values number[]
local function writeVectorProperty(obj, key, values)
    obj.props[key] = FileHandler.formatNumbers(unpack(values))
end

---Applies the functions to linked joints' anchors / axes, then commits. Joints can't move live, so
---a change with linked joints reloads
---@param selected FileParserEnvObj[]
---@param posFn (fun(x: number, y: number, z: number): number, number, number)?
---@param axisFn (fun(x: number, y: number, z: number): number, number, number)?
local function finishTransform(selected, posFn, axisFn)
    local linked = Joints.getLinked(Joints.idSet(worldOnly(selected)))
    for _, joint in ipairs(linked) do
        if posFn then Joints.transformPos(joint, posFn) end
        if axisFn then Joints.transformAxis(joint, axisFn) end
    end
    History.commit()
    if #linked > 0 then MGE.apply() end
end

---@param selectedObjects FileParserEnvObj[]
---@return number, number, number
local function getSelectionPivot(selectedObjects)
    local total = #selectedObjects
    if total == 0 then return 0, 0, 0 end

    local sumX, sumY, sumZ, count = 0, 0, 0, 0
    for _, obj in ipairs(selectedObjects) do
        if present(obj) then
            local p = positionOf(obj)
            sumX, sumY, sumZ, count = sumX + p[1], sumY + p[2], sumZ + p[3], count + 1
        end
    end
    if count == 0 then return 0, 0, 0 end

    return sumX / count, sumY / count, sumZ / count
end

---Moves the objects (and joints linked between them) by offsets
---@param selectedObjects FileParserEnvObj[]
---@param offsets number[] x y z
local function moveBy(selectedObjects, offsets)
    local function move(x, y, z) return x + offsets[1], y + offsets[2], z + offsets[3] end
    for _, v in ipairs(selectedObjects) do
        local p = positionOf(v)
        local pos = { move(p[1], p[2], p[3]) }
        if inWorld(v) then set_obj_pos(v.id - 1, pos[1], pos[2], pos[3]) end
        applyFileRotation(v) -- the whole object back to the file's state
        writeVectorProperty(v, "pos", pos)
    end

    if MGE.Camera.followMoves then MGE.Camera.focus(selectedObjects) end
    finishTransform(selectedObjects, move)
    Transforms.onChanged()
end

---Live-only preview of a move from the file positions (gizmo drag). moveBy commits, restoreLive reverts
---@param selectedObjects FileParserEnvObj[]
---@param offset number[]
function Transforms.previewMove(selectedObjects, offset)
    for _, v in ipairs(selectedObjects) do
        if inWorld(v) then
            local p = positionOf(v)
            set_obj_pos(v.id - 1, p[1] + offset[1], p[2] + offset[2], p[3] + offset[3])
            applyFileRotation(v)
        end
    end
end

---Live-only: puts the objects back where the file has them (cancelled drag)
---@param selectedObjects FileParserEnvObj[]
---@param baseSides table<integer, number[]>? sizes to restore too (after previewScale), by object id
function Transforms.restoreLive(selectedObjects, baseSides)
    Transforms.previewMove(selectedObjects, { 0, 0, 0 })
    for _, v in ipairs(selectedObjects) do
        local s = baseSides and baseSides[v.id]
        if s and inWorld(v) then set_obj_sides(v.id - 1, s[1], s[2], s[3]) end
    end
end

---Live sizes by object id: a scale drag plans every frame from these, since previews change them
---@param selectedObjects FileParserEnvObj[]
---@return table<integer, number[]>
function Transforms.liveSides(selectedObjects)
    local out = {}
    for _, v in ipairs(selectedObjects) do
        if inWorld(v) then out[v.id] = { get_obj_sides(v.id - 1) } end
    end
    return out
end

---Pos row: moves the selection's pivot to the typed coordinates (relative to POS_ORIGIN)
---@param typed (number?)[] x y z, nil axes don't move
function Transforms.positionTo(typed)
    local selectedObjects = getSelected()
    if #selectedObjects == 0 then return end
    local pivot = { getSelectionPivot(selectedObjects) }
    local offsets = {}
    for i = 1, 3 do offsets[i] = typed[i] and typed[i] + POS_ORIGIN[i] - pivot[i] or 0 end
    moveBy(selectedObjects, offsets)
end

---Selection pivot relative to POS_ORIGIN, as the Pos row shows it
---@param selectedObjects FileParserEnvObj[]
---@return number[]
function Transforms.shownPosition(selectedObjects)
    local pivot = { getSelectionPivot(selectedObjects) }
    for i = 1, 3 do pivot[i] = pivot[i] - POS_ORIGIN[i] end
    return pivot
end

---Rotates the objects around their pivot by offsets (radians, applied z, then y, then x)
---@param selectedObjects FileParserEnvObj[]
---@param offsets number[] x y z
---@param pivot number[]? when the caller has it (gizmo)
local function rotBy(selectedObjects, offsets, pivot)
    pivot = pivot or { getSelectionPivot(selectedObjects) }

    -- SetRotPos as a matrix, built once from the unit axes; new rot lines once per distinct old line
    local turn = {}
    for k = 1, 3 do
        local e = { 0, 0, 0 }
        e[k] = 1
        turn[k] = RotatingOld.SetRotPos(e[1], e[2], e[3], 0, 0, 0, offsets[1], offsets[2], offsets[3])
    end
    local rotByLine = {}

    local inPlace = Transforms.inPlace
    for _, v in ipairs(selectedObjects) do
        local pos = positionOf(v)
        local dx, dy, dz = pos[1] - pivot[1], pos[2] - pivot[2], pos[3] - pivot[3]
        local outPos = inPlace and { pos[1], pos[2], pos[3] } or {
            pivot[1] + turn[1][1] * dx + turn[2][1] * dy + turn[3][1] * dz,
            pivot[2] + turn[1][2] * dx + turn[2][2] * dy + turn[3][2] * dz,
            pivot[3] + turn[1][3] * dx + turn[2][3] * dy + turn[3][3] * dz,
        }
        local line = v.props.rot or ""
        local outRot = rotByLine[line]
        if not outRot then
            local rot = rotLine(v)
            outRot = RotatingOld.SetRotOffset(rot[1], rot[2], rot[3], offsets[1], offsets[2], offsets[3])
            rotByLine[line] = outRot
        end
        if inWorld(v) then
            set_obj_rot(v.id - 1, math.rad(outRot[1]), math.rad(outRot[2]), math.rad(outRot[3]))
            set_obj_pos(v.id - 1, outPos[1], outPos[2], outPos[3])
        end

        writeVectorProperty(v, "rot", outRot)
        writeVectorProperty(v, "pos", outPos)
    end
    -- anchors turn around the pivot (not in place), axes turn without translation
    finishTransform(selectedObjects, not inPlace and function(x, y, z)
        local p = RotatingOld.SetRotPos(x, y, z, pivot[1], pivot[2], pivot[3], offsets[1], offsets[2], offsets[3])
        return p[1], p[2], p[3]
    end or nil, function(x, y, z)
        local a = RotatingOld.SetRotPos(x, y, z, 0, 0, 0, offsets[1], offsets[2], offsets[3])
        return a[1], a[2], a[3]
    end)
    Transforms.onChanged()
end

-- read-only local axes per shared orientation
local axesByOrientation = setmetatable({}, { __mode = "k" })

---An object's local axes in world space (its orientation's columns)
---@param obj FileParserEnvObj
---@return number[][]
local function getLocalAxes(obj)
    local m = orientationOf(obj)
    local axes = axesByOrientation[m]
    if not axes then
        axes = Mat3.transpose(m)
        axesByOrientation[m] = axes
    end
    return axes
end

---Linear map that scales along the group frame axes: G * diag(scale) * G^T
---@param frame number[][] 3x3, columns are the group axes in world space
---@param scale number[]
---@return number[][]
local function groupScaleMatrix(frame, scale)
    return Mat3.mul(Mat3.mul(frame, { { scale[1], 0, 0 }, { 0, scale[2], 0 }, { 0, 0, scale[3] } }), Mat3.transpose(frame))
end

-- defined below sideFactors and applySideFactors, which it uses
local scaleSidesAlong

---New sides for an object scaled along the group frame's axes. A tilted box can't stretch along other
---axes, so each local axis gets a geometric mean of the factors weighted by its squared alignment with
---each group axis. Exact when aligned, and reversible (s then 1/s gives the sides back)
---@param obj FileParserEnvObj
---@param sides number[]
---@param frame number[][] group frame, columns are the group axes
---@param scale number[] factors along the group axes
---@param shapeName string? "box", "sphere" or "cylinder" for atmo objects; nil asks the game
---@return number[]
local function scaleSides(obj, sides, frame, scale, shapeName)
    return scaleSidesAlong(getLocalAxes(obj), sides, frame, scale, shapeName or nil, obj)
end

---Each local axis' factor (scaleSides' weighted mean). Depends only on axes, frame and factors, so
---callers cache it per shared orientation and apply it with applySideFactors
---@param axes number[][]
---@param frame number[][]
---@param scale number[]
---@return number[] f per local axis
local function sideFactors(axes, frame, scale)
    local logScale = {}
    for j = 1, 3 do logScale[j] = math.log(math.max(math.abs(scale[j]), 1e-9)) end -- mirroring keeps sizes
    local f = {}
    for i = 1, 3 do
        local a, sum = axes[i], 0
        for j = 1, 3 do
            local along = a[1] * frame[1][j] + a[2] * frame[2][j] + a[3] * frame[3][j]
            sum = sum + along * along * logScale[j]
        end
        f[i] = math.exp(sum)
    end
    return f
end

---Sides scaled by sideFactors' f (spheres stay round, pills keep a round section)
---@param sides number[]
---@param f number[]
---@param sphere boolean
---@param capsule boolean
---@return number[]
local function applySideFactors(sides, f, sphere, capsule)
    local out
    if sphere then -- x radius, stays round: geometric mean of all axes
        local r = sides[1] * (f[1] * f[2] * f[3]) ^ (1 / 3)
        out = { r, r, r }
    elseif capsule then -- x radius (round across local x and y), y length along local z
        out = { sides[1] * math.sqrt(f[1] * f[2]), sides[2] * f[3], sides[3] }
    else
        out = { sides[1] * f[1], sides[2] * f[2], sides[3] * f[3] }
    end
    for i = 1, 3 do out[i] = math.max(math.abs(out[i]), MGE.MIN_SIDE) end -- zero sides crash physics
    return out
end
Transforms.sideFactors = sideFactors
Transforms.applySideFactors = applySideFactors

---scaleSides with the local axes given (e.g. from an atmo ghost's frame)
---@param axes number[][] the local x, y, z axes in world space
---@param sides number[]
---@param frame number[][] group frame
---@param scale number[]
---@param shapeName string? see scaleSides
---@param obj FileParserEnvObj? for the game's shape when shapeName is nil
---@return number[]
scaleSidesAlong = function(axes, sides, frame, scale, shapeName, obj)
    local f = sideFactors(axes, frame, scale)
    local sphere, capsule
    if shapeName then
        sphere, capsule = shapeName == "sphere", shapeName == "cylinder"
    else
        local shape = obj and shapeIdOf(obj)
        sphere, capsule = shape == SHAPE.SPHERE, shape == SHAPE.CAPSULE
    end
    return applySideFactors(sides, f, sphere, capsule)
end

---@param a number[][]
---@param b number[][]
local function sameFrame(a, b)
    for i = 1, 3 do
        for j = 1, 3 do
            if math.abs(a[i][j] - b[i][j]) > 1e-4 then return false end
        end
    end
    return true
end

---The group's axes (Rot shows them, Scale stretches along them): the orientation most objects share,
---ties to the first. Counted, not size-weighted, so scaling never switches the axes
---@param objects FileParserEnvObj[]
---@return number[][]
pickGroupFrame = function(objects)
    -- count by rot line first (thousands share a few)
    local byLine, lines = {}, {}
    for _, obj in ipairs(objects) do
        local line = obj.props.rot or ""
        local entry = byLine[line]
        if entry then
            entry.weight = entry.weight + 1
        else
            entry = { obj = obj, weight = 1 }
            byLine[line] = entry
            lines[#lines + 1] = line
        end
    end
    -- then by orientation, bucketed by its values rounded to 0.001 (pairwise comparing was too slow)
    local groups, byKey = {}, {} -- in first-seen order: ties go to the first
    for _, line in ipairs(lines) do
        local entry = byLine[line]
        local frame = orientationOf(entry.obj)
        local key = string.format("%d %d %d %d %d %d %d %d %d",
            math.floor(frame[1][1] * 1000 + 0.5), math.floor(frame[1][2] * 1000 + 0.5), math.floor(frame[1][3] * 1000 + 0.5),
            math.floor(frame[2][1] * 1000 + 0.5), math.floor(frame[2][2] * 1000 + 0.5), math.floor(frame[2][3] * 1000 + 0.5),
            math.floor(frame[3][1] * 1000 + 0.5), math.floor(frame[3][2] * 1000 + 0.5), math.floor(frame[3][3] * 1000 + 0.5))
        local group
        for _, g in ipairs(byKey[key] or {}) do
            if sameFrame(g.frame, frame) then group = g break end
        end
        if group then
            group.weight = group.weight + entry.weight
        else
            group = { frame = frame, weight = entry.weight }
            groups[#groups + 1] = group
            byKey[key] = byKey[key] or {}
            table.insert(byKey[key], group)
        end
    end
    local best = groups[1]
    for _, g in ipairs(groups) do
        if g.weight > best.weight then best = g end
    end
    return best and best.frame or Mat3.IDENTITY
end

---rotBy offsets that turn the group from `frame` to the angles `target` (radians)
---@param frame number[][]
---@param target number[]
---@return number[]
local function rotationTo(frame, target)
    local wanted = Mat3.mul(Mat3.rotX(target[1]), Mat3.mul(Mat3.rotY(target[2]), Mat3.rotZ(target[3])))
    return { Mat3.toEulerXYZ(Mat3.mul(wanted, Mat3.transpose(frame))) }
end

---Plans a scale along the group's axes without changing anything (scaleBy applies it)
---@param selectedObjects FileParserEnvObj[] objects in the world
---@param scale number[] x y z factors
---@return { obj: FileParserEnvObj, pos: number[], sides: number[] }[] planned
---@return fun(x: number, y: number, z: number): number, number, number scalePos
---@param pivot number[]? when the caller has it (gizmo)
---@param frame number[][]? likewise
local function planScale(selectedObjects, scale, pivot, frame)
    pivot = pivot or { getSelectionPivot(selectedObjects) }

    frame = frame or pickGroupFrame(selectedObjects)
    local map = groupScaleMatrix(frame, scale)
    local function scalePos(x, y, z)
        if Transforms.inPlace then return x, y, z end
        local rel = Mat3.apply(map, { x - pivot[1], y - pivot[2], z - pivot[3] })
        return pivot[1] + rel[1], pivot[2] + rel[2], pivot[3] + rel[3]
    end

    -- side factors once per rot line
    local factorsByLine = {}
    local function scaleSidesCached(v, sides)
        local line = v.props.rot or ""
        local f = factorsByLine[line]
        if not f then
            f = Transforms.sideFactors(getLocalAxes(v), frame, scale)
            factorsByLine[line] = f
        end
        local shape = shapeIdOf(v)
        return Transforms.applySideFactors(sides, f, shape == SHAPE.SPHERE, shape == SHAPE.CAPSULE)
    end

    local planned = {}
    for _, v in ipairs(selectedObjects) do
        if present(v) then
            local p = positionOf(v)
            table.insert(planned, {
                obj = v,
                pos = { scalePos(p[1], p[2], p[3]) },
                sides = scaleSidesCached(v, { sidesOf(v) }),
            })
        end
    end
    return planned, scalePos
end

---Scales the objects (sides and spacing) around their pivot along the group's axes
---@param selectedObjects FileParserEnvObj[]
---@param scale number[] x y z factors
---@param pivot number[]? when the caller has it (gizmo)
---@param frame number[][]? likewise
local function scaleBy(selectedObjects, scale, pivot, frame)
    local planned, scalePos = planScale(selectedObjects, scale, pivot, frame)
    for _, p in ipairs(planned) do
        local id = p.obj.id - 1
        if inWorld(p.obj) then
            set_obj_pos(id, p.pos[1], p.pos[2], p.pos[3])
            set_obj_sides(id, p.sides[1], p.sides[2], p.sides[3])
        end
        applyFileRotation(p.obj)
        writeVectorProperty(p.obj, "pos", p.pos)
        writeVectorProperty(p.obj, "sides", p.sides)
    end
    if MGE.Camera.followMoves then MGE.Camera.focus(selectedObjects) end
    finishTransform(selectedObjects, not Transforms.inPlace and scalePos or nil)
    Transforms.onChanged()
end

---Where the selection starts and ends along three axes, including each object's size and rotation
---@param selectedObjects FileParserEnvObj[]
---@param axes number[][] unit axes to measure along
---@param scale number[]? after scaling by these factors (planScale), nil for now
---@return number[] min, number[] max along each axis (math.huge / -math.huge when nothing is in the world)
local function groupBounds(selectedObjects, axes, scale)
    local placed = {} -- object -> planned pos and sides (keyed by table: atmo ids aren't unique)
    if scale then
        for _, p in ipairs((planScale(selectedObjects, scale))) do placed[p.obj] = p end
    end
    local min, max = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for _, v in ipairs(selectedObjects) do
        local x, y, z
        local sx, sy, sz
        if present(v) then
            local pos = positionOf(v)
            x, y, z = pos[1], pos[2], pos[3]
            sx, sy, sz = sidesOf(v)
        end
        local p = placed[v]
        if p then
            x, y, z = p.pos[1], p.pos[2], p.pos[3]
            sx, sy, sz = p.sides[1], p.sides[2], p.sides[3]
        end
        if x then
            local shape = shapeIdOf(v)
            local localAxes = getLocalAxes(v)
            local l1, l2, l3 = localAxes[1], localAxes[2], localAxes[3]
            for i, a in ipairs(axes) do
                -- each local axis' alignment with the group axis
                local a1, a2, a3 = a[1], a[2], a[3]
                local along3 = math.abs(l3[1] * a1 + l3[2] * a2 + l3[3] * a3)
                local half
                if shape == SHAPE.SPHERE then
                    half = sx
                elseif shape == SHAPE.CAPSULE then -- x radius, y length along local z
                    half = sx + along3 * sy / 2
                else
                    local along1 = math.abs(l1[1] * a1 + l1[2] * a2 + l1[3] * a3)
                    local along2 = math.abs(l2[1] * a1 + l2[2] * a2 + l2[3] * a3)
                    half = (along1 * sx + along2 * sy + along3 * sz) / 2
                end
                local c = x * a[1] + y * a[2] + z * a[3]
                min[i] = math.min(min[i], c - half)
                max[i] = math.max(max[i], c + half)
            end
        end
    end
    return min, max
end

---The selection's size along the group's axes
---@param selectedObjects FileParserEnvObj[]
---@param scale number[]? size after scaling by these factors (planScale), nil for the current size
---@return number[] extents x y z, 0 when nothing is in the world
local function groupExtents(selectedObjects, scale)
    local min, max = groupBounds(selectedObjects, Mat3.transpose(pickGroupFrame(selectedObjects)), scale)
    local extents = {}
    for i = 1, 3 do extents[i] = max[i] > min[i] and max[i] - min[i] or 0 end
    return extents
end

---Scale row: scales the selection so its size along the group axes becomes the typed values. Size
---doesn't follow the factor 1:1 (pill caps, round spheres, tilted objects), so factors are found
---iteratively: each step corrects in log space by how fast the size responded last step
---@param typed (number?)[] x y z sizes, nil (or 0 and below) axes don't change
function Transforms.sizeTo(typed)
    local selectedObjects = getSelected()
    if #selectedObjects == 0 then return end
    local current = groupExtents(selectedObjects)
    local targets, changed = {}, false
    for i = 1, 3 do
        if typed[i] and typed[i] > 0 and current[i] > 1e-9 then
            targets[i], changed = typed[i], true
        end
    end
    if not changed then return end

    ---@type number[]
    local scale = { 1, 1, 1 }
    ---@type table<integer, { scale: number, size: number }> per axis: log factor and log size of the step before
    local previous = {}
    for _ = 1, 50 do
        local extents = groupExtents(selectedObjects, scale)
        local done = true
        for i = 1, 3 do
            if targets[i] and extents[i] > 1e-9 then
                local logScale, logSize = math.log(scale[i]), math.log(extents[i])
                local miss = math.log(targets[i]) - logSize
                if math.abs(miss) > 1e-10 then
                    done = false
                    -- size response per factor change (1 for plain boxes), clamped: axes interact
                    local response = 1
                    local p = previous[i]
                    if p and math.abs(logScale - p.scale) > 1e-12 then
                        response = math.min(math.max((logSize - p.size) / (logScale - p.scale), 0.05), 2)
                    end
                    previous[i] = { scale = logScale, size = logSize }
                    scale[i] = math.min(math.max(math.exp(logScale + miss / response), 1e-4), 1e4)
                end
            end
        end
        if done then break end
    end
    -- unreachable (e.g. In place keeps the spacing): change nothing
    local reached = groupExtents(selectedObjects, scale)
    for i = 1, 3 do
        if targets[i] and math.abs(reached[i] - targets[i]) > math.max(targets[i] * 0.01, 1e-4) then
            MGE.say(string.format("can't scale the group to %g on %s: it gets to %.3g%s", targets[i],
                ({ "x", "y", "z" })[i], reached[i], Transforms.inPlace and
                " (In place keeps the spacing)"
                or ""))
            return
        end
    end
    scaleBy(selectedObjects, scale)
end

---Group orientation as the Rot row shows it (radians, see fileAngles)
---@param selectedObjects FileParserEnvObj[]
---@return number[]
function Transforms.groupAngles(selectedObjects)
    local sign = angleSign()
    local x, y, z = Mat3.toEulerXYZ(pickGroupFrame(selectedObjects))
    return { sign * x, sign * y, sign * z }
end

---Rot row: turns the selection so the group's angles become the typed degrees (nil axes keep theirs)
---@param typed (number?)[] x y z degrees, nil axes keep their angle
function Transforms.angleTo(typed)
    local selectedObjects = getSelected()
    if #selectedObjects == 0 then return end
    local frame = pickGroupFrame(selectedObjects)
    local target = Transforms.groupAngles(selectedObjects)
    local changed = false
    for i = 1, 3 do
        if typed[i] then target[i], changed = math.rad(typed[i]), true end
    end
    if not changed then return end
    local sign = angleSign()
    rotBy(selectedObjects, rotationTo(frame, { sign * target[1], sign * target[2], sign * target[3] }))
end


-- used by the editor rows, the generator and the offline tests
Transforms.writeVector = writeVectorProperty
Transforms.getSelectionPivot = getSelectionPivot
Transforms.positionOf = positionOf
Transforms.moveBy = moveBy -- gizmo drag commit
Transforms.groupFrame = function(selectedObjects) return pickGroupFrame(selectedObjects) end

---Only objects in the world: live previews skip atmo (drawn from AtmoLayer.live)
---@param objects FileParserEnvObj[]
---@return FileParserEnvObj[]
local function inWorldOnly(objects)
    local out = {}
    for _, v in ipairs(objects) do
        if inWorld(v) then out[#out + 1] = v end
    end
    return out
end

---Live-only preview of a rotation around the pivot (gizmo ring drag). rotateByMatrix commits
---@param selectedObjects FileParserEnvObj[]
---@param rotation number[][]
---@param pivot number[]? the selection's pivot (the gizmo keeps it)
function Transforms.previewRotate(selectedObjects, rotation, pivot)
    local world = inWorldOnly(selectedObjects)
    if #world == 0 then return end
    pivot = pivot or { getSelectionPivot(selectedObjects) }
    for _, v in ipairs(world) do
        if inWorld(v) then
            if not Transforms.inPlace then
                local p = positionOf(v)
                local rel = Mat3.apply(rotation, { p[1] - pivot[1], p[2] - pivot[2], p[3] - pivot[3] })
                set_obj_pos(v.id - 1, pivot[1] + rel[1], pivot[2] + rel[2], pivot[3] + rel[3])
            end
            -- orientation is Rx(-x) Ry(-y) Rz(-z), see orientationOf
            local x, y, z = Mat3.toEulerXYZ(Mat3.mul(rotation, orientationOf(v)))
            set_obj_rot(v.id - 1, -x, -y, -z)
        end
    end
end

---Turns the objects by a rotation matrix around the pivot, like the Rotate row
---@param selectedObjects FileParserEnvObj[]
---@param rotation number[][]
---@param pivot number[]? when the caller has it (gizmo)
function Transforms.rotateByMatrix(selectedObjects, rotation, pivot)
    rotBy(selectedObjects, { Mat3.toEulerXYZ(rotation) }, pivot) -- rotBy's offsets: rotX(x) rotY(y) rotZ(z)
end

---Live-only preview of a scale (gizmo drag), planned from baseSides (sizes at the grab). Restore
---baseSides (restoreLive) before scaleBy commits
---@param selectedObjects FileParserEnvObj[]
---@param scale number[]
---@param baseSides table<integer, number[]> Transforms.liveSides at the grab
---@param pivot number[]? the selection's pivot (the gizmo keeps it)
---@param frame number[][]? the group frame likewise
function Transforms.previewScale(selectedObjects, scale, baseSides, pivot, frame)
    local world = inWorldOnly(selectedObjects)
    if #world == 0 then return end
    -- pivot and frame from the whole selection (atmo counts), planned for world objects only
    pivot = pivot or { getSelectionPivot(selectedObjects) }
    frame = frame or pickGroupFrame(selectedObjects)
    for _, v in ipairs(world) do
        local s = baseSides[v.id]
        if s then set_obj_sides(v.id - 1, s[1], s[2], s[3]) end
    end
    for _, p in ipairs((planScale(world, scale, pivot, frame))) do
        if inWorld(p.obj) then
            local id = p.obj.id - 1
            set_obj_pos(id, p.pos[1], p.pos[2], p.pos[3])
            set_obj_sides(id, p.sides[1], p.sides[2], p.sides[3])
            applyFileRotation(p.obj)
        end
    end
end
Transforms.orientationOf = orientationOf
Transforms.scaleSidesFor = scaleSides
Transforms.scaleSidesAlong = function(...) return scaleSidesAlong(...) end
Transforms.groupExtents = groupExtents
Transforms.rotBy = rotBy
Transforms.scaleBy = scaleBy

return Transforms
