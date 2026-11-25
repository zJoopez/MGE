local ShapeGen = {}
MGE.ShapeGen = ShapeGen

local RotatingOld = dofile(MGE.scriptPath .. "utils/rotating.lua")
local Mat3 = MGE.Mat3

-- Shape generator (Generate tab): a chain of boxes along X bending up toward Z by Angle in total
-- (0 straight, 360 a loop); pieces are chords of the arc. They touch along the bend's inside ("in"),
-- outside ("out") or middle ("center"), Gap apart. Piece i has sides + i * increment (stairs,
-- pyramids). Y is always centered

local rotationAbout = Mat3.rotationAbout

---@class GeneratePiece
---@field pos number[]
---@field rot number[] degrees, as written in the file
---@field frame number[][] orientation the rot line gives, columns are the piece's axes (preview drawing)
---@field sides number[]

---@alias GenerateAlign "in"|"out"|"center"

-- piece center offset from the touching line, in half-thicknesses along its Z
local ALIGN_LIFT = { ["in"] = -1, out = 1, center = 0 }

---@class GenerateOptions
---@field increment number[]? added to the sides of each next piece, default 0 0 0
---@field align GenerateAlign? default "out"
---@field rotation number[][]? each piece's own rotation in its frame (around its center; layout stays)
---@field firstTurn number[][]? a world turn for the first piece (Rotate gizmo on the preview), folded into rotation

---Sides of piece i (from 0)
---@param sides number[]
---@param increment number[]
---@param i integer
---@return number[]
local function pieceSides(sides, increment, i)
    return { sides[1] + increment[1] * i, sides[2] + increment[2] * i, sides[3] + increment[3] * i }
end

---Pieces left before a side shrinks below MGE.MIN_SIDE, nil when increments never shrink anything
---@param sides number[]
---@param increment number[]
---@return integer?
local function maxPieces(sides, increment)
    local most
    for k = 1, 3 do
        if increment[k] < 0 then
            -- piece i is fine while sides + increment * i >= MIN_SIDE
            local n = math.floor((sides[k] - MGE.MIN_SIDE) / -increment[k] + 1e-9) + 1
            most = math.min(most or n, n)
        end
    end
    return most
end

---@class GenerateBounds: SpawnBounds box around the whole shape, world axes (utils/camera.lua)

---Where the pieces go: the shape's lowest point at z 0, centered on `center` in x and y
---@param amount integer
---@param gap number
---@param angle number degrees turned in total
---@param sides number[] box sides of the first piece: length (x), width (y), thickness (z)
---@param center number[] x y
---@param options GenerateOptions?
---@return GeneratePiece[] pieces, GenerateBounds bounds where the pieces ended up
local function planGenerate(amount, gap, angle, sides, center, options)
    options = options or {}
    local increment = options.increment or { 0, 0, 0 }
    local liftHalves = ALIGN_LIFT[options.align] or ALIGN_LIFT.out
    local step = math.rad(angle) / amount
    local axis = { 0, -1, 0 } -- turning around -Y tilts X up toward Z
    -- nil: none (keeps the plain shape's numbers exact)
    local rotation = options.rotation
    if options.firstTurn then
        -- world turn Q of the first piece (frame bend1 * R): bend1 * R' = Q * bend1 * R, R' = bend1^T Q bend1 R
        local bend1 = rotationAbout(axis, step * 0.5)
        local local1 = Mat3.mul(Mat3.transpose(bend1), Mat3.mul(options.firstTurn, bend1))
        rotation = rotation and Mat3.mul(local1, rotation) or local1
    end
    local vertex = { 0, 0, 0 } -- on the touching line, where the next piece starts
    local pieces = {}
    local min, max = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for i = 0, amount - 1 do
        local s = pieceSides(sides, increment, i)
        local bend = rotationAbout(axis, step * (i + 0.5))
        local dir, up = Mat3.apply(bend, { 1, 0, 0 }), Mat3.apply(bend, { 0, 0, 1 })
        local lift = liftHalves * s[3] / 2 -- out: on the line, in: under it
        -- each piece sits mid-stretch (half the gap on each side), so its turn matches its place
        local pos = {}
        for k = 1, 3 do pos[k] = vertex[k] + dir[k] * (s[1] + gap) / 2 + up[k] * lift end
        for k = 1, 3 do vertex[k] = vertex[k] + dir[k] * (s[1] + gap) end
        local turn = rotation and Mat3.mul(bend, rotation) or bend
        -- corners, for the bounds
        for cx = -1, 1, 2 do
            for cy = -1, 1, 2 do
                for cz = -1, 1, 2 do
                    local corner = Mat3.apply(turn, { cx * s[1] / 2, cy * s[2] / 2, cz * s[3] / 2 })
                    for k = 1, 3 do
                        min[k] = math.min(min[k], pos[k] + corner[k])
                        max[k] = math.max(max[k], pos[k] + corner[k])
                    end
                end
            end
        end
        local offsets = { Mat3.toEulerXYZ(turn) }
        table.insert(pieces, {
            pos = pos,
            rot = RotatingOld.SetRotOffset(0, 0, 0, offsets[1], offsets[2], offsets[3]),
            frame = turn,
            sides = s,
        })
    end
    local shift = { center[1] - (min[1] + max[1]) / 2, center[2] - (min[2] + max[2]) / 2, -min[3] }
    for _, piece in ipairs(pieces) do
        for k = 1, 3 do piece.pos[k] = piece.pos[k] + shift[k] end
    end
    for k = 1, 3 do
        min[k], max[k] = min[k] + shift[k], max[k] + shift[k]
    end
    return pieces, { min = min, max = max }
end

---Moves planned pieces so the shape's center (x y) and lowest point (z) are at point
---@param pieces GeneratePiece[]
---@param bounds GenerateBounds where the pieces are now
---@param point number[] from Camera.spawnPoint
function ShapeGen.moveTo(pieces, bounds, point)
    local shift = MGE.Camera.spawnShift(bounds, point)
    for _, piece in ipairs(pieces) do
        for k = 1, 3 do piece.pos[k] = piece.pos[k] + shift[k] end
    end
end


---@class GenerateJoint
---@field a integer index of the first piece (from 1)
---@field b integer index of the next piece
---@field pos number[] anchor

---Joints between neighbouring pieces: 1 per pair halfway between centers, or 2 at the narrower
---piece's width edges (a hinge)
---@param pieces GeneratePiece[] planned and placed
---@param perPair integer 0, 1 or 2
---@return GenerateJoint[]
function ShapeGen.joints(pieces, perPair)
    local joints = {}
    if perPair < 1 then return joints end
    for i = 1, #pieces - 1 do
        local p, q = pieces[i], pieces[i + 1]
        local mid = {}
        for k = 1, 3 do mid[k] = (p.pos[k] + q.pos[k]) / 2 end
        if perPair == 1 then
            table.insert(joints, { a = i, b = i + 1, pos = mid })
        else
            local half = math.min(p.sides[2], q.sides[2]) / 2
            local width = { p.frame[1][2], p.frame[2][2], p.frame[3][2] } -- the piece's Y axis
            for _, sign in ipairs({ -1, 1 }) do
                local pos = {}
                for k = 1, 3 do pos[k] = mid[k] + sign * half * width[k] end
                table.insert(joints, { a = i, b = i + 1, pos = pos })
            end
        end
    end
    return joints
end

ShapeGen.plan = planGenerate
ShapeGen.maxPieces = maxPieces

return ShapeGen
