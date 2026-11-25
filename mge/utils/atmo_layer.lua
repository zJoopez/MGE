-- The atmo layer: atmo objects in ModData.parsed.atmo, saved inside the mod (utils/atmo.lua). The game
-- draws atmos without collisions and past its object limit. MGE draws them itself (utils/highlight.lua
-- via AtmoLayer.ghost); the Atmo list shows them as A1, A2...
-- They're edited like objects (utils/transforms.lua writes their lines); moveBy / rotateBy / scaleBy
-- only serve previews. Only the nearest maxDraws are drawn.
-- An atmo id is its list index, NOT an object id: never pass one to get_obj_* (see AtmoLayer.isAtmo)
local ModData = MGE.ModData
local History = MGE.History
local Mat3 = MGE.Mat3
local FileHandler = MGE.FileHandler

---@class AtmoLayer
local AtmoLayer = {
    color = { 0.75, 0.45, 1.0 }, -- ghost fill; selected ones use the selection color
    alpha = 0.15,
    -- most atmo shapes drawn a frame, nearest first (Settings > Max draws): the game caps shapes a frame
    maxDraws = 1000,
    DRAW_CHOICES = { 5000, 1000, 500 },
    MAX_GENERATE = 5000, -- most pieces one Generate adds to the atmo (no more could be drawn)
    -- the objects' alpha while the Atmo list shows, so the atmo stands out
    seeThroughAlpha = 0.15,
    ---@type { move: number[]?, rotation: number[][]?, scale: number[]?, pivot: number[], frame: number[][] }?
    ---a gizmo drag in progress on the selected atmo objects, drawn as a preview
    live = nil,
}
MGE.AtmoLayer = AtmoLayer

---@param value string?
---@return number[]
local function numbers(value)
    -- fast path for the usual three numbers: thousands of ghosts are re-read after an edit
    local text = tostring(value or "")
    local a, b, c, rest = text:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
    if a and rest == "" then return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 } end
    local out = {}
    for n in text:gmatch("%S+") do out[#out + 1] = tonumber(n) or 0 end
    return out
end

---@param obj FileParserEnvObj
---@return string "box", "sphere" or "cylinder" (a pill in game)
local function shapeOf(obj)
    local shape = tostring(obj.props.shape or "box"):match("^%s*(%a+)") or "box"
    if shape == "sphere" or shape == "cylinder" or shape == "capsule" then
        return shape == "capsule" and "cylinder" or shape
    end
    return "box"
end
AtmoLayer.shapeOf = shapeOf

---@return number bounding sphere radius from the center (Atmo Play's, loaded after this file)
local function ghostRadius(shape, sides)
    return MGE.AtmoPlay.Colliders.radius(shape, sides)
end

---@param id integer 0-based
---@return any r, any g, any b, any a the game's color, r nil without one
local function objColor(id)
    local ok, r, g, b, a = pcall(get_obj_color, id)
    if ok and type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
    if ok and tonumber(r) then return r, g, b, a or 1 end
    return nil, 0, 0, 0
end
AtmoLayer.liveColor = objColor

---Keeps the atmo objects keep() accepts, renumbering their ids
---@param keep fun(obj: FileParserEnvObj): boolean
local function keepAtmo(keep)
    local stay = {}
    for _, obj in ipairs(ModData.parsed.atmo) do
        if keep(obj) then
            stay[#stay + 1] = obj
            obj.id = #stay
        end
    end
    ModData.parsed.atmo = stay
end

---A rot line (degrees) as the matrix draw_*_m needs: rotX(-x) rotY(-y) rotZ(-z), same as get_obj_rot
---(checked in game with tools/rotcheck.lua)
---@param rot number[]
---@return number[][]
function AtmoLayer.frameOf(rot)
    -- looked up at call time: MGE.AtmoPlay loads after this file
    return MGE.AtmoPlay.Colliders.frameOf(rot)
end

---@class AtmoGhost: HighlightBox
---@field shape string
---@field pos number[]
---@field frame number[][]
---@field sides number[] box sides, sphere: radius first, pill: radius, length
---@field radius number bounding sphere from pos (view culling)
---@field fileSides number[] the sides line as written (sides is made positive, min 0.01, for drawing)

-- Ghosts with the same rot line share one read-only frame table: maps have few rotations, so drags and
-- the highlight's rotCache work per frame, not per object
---@type table<string, number[][]>
local frameByRot = {}

---What an atmo object looks like, for drawing. Recomputed only when its lines change
---@param obj FileParserEnvObj
---@return AtmoGhost? nil without a pos line
function AtmoLayer.ghost(obj)
    local p = obj.props
    if not p.pos then return nil end
    -- compare the lines directly (interned strings): building a key per object per frame was slow
    local cached = obj.ghostCache
    if cached and cached.pos == p.pos and cached.rot == p.rot and cached.sides == p.sides and cached.shape == p.shape then
        return cached.ghost
    end
    local fileSides = numbers(p.sides)
    local sides = {}
    for k = 1, 3 do sides[k] = math.max(math.abs(fileSides[k] or 0), 0.01) end
    local shape = shapeOf(obj)
    local radius = ghostRadius(shape, sides)
    local rotLine = p.rot or ""
    local frame = frameByRot[rotLine]
    if not frame then
        frame = AtmoLayer.frameOf(numbers(p.rot))
        frameByRot[rotLine] = frame
    end
    local ghost = { shape = shape, pos = numbers(p.pos), frame = frame, sides = sides, radius = radius,
        fileSides = fileSides }
    obj.ghostCache = { pos = p.pos, rot = p.rot, sides = p.sides, shape = p.shape, ghost = ghost }
    return ghost
end

---Fills in flag (for To objects' id range) and color from the game when the lines lack them
---@param obj FileParserEnvObj in the world
local function writeMissingLines(obj)
    local id = obj.id - 1
    if obj.props.flag == nil then
        local flag = get_obj_flag(id)
        obj.props.flag = tostring(flag or MGE.FLAGS.STATIC)
    end
    if obj.props.color == nil then
        local r, g, b, a = objColor(id)
        if r then obj.props.color = FileHandler.formatNumbers(r, g, b, a) end
    end
end

---Moves the selected objects into the atmo, freeing their ids. Joint-linked objects stay
---@param mark boolean? Playable: tag each with FROM_KEY (its id) so Default can move it back
function AtmoLayer.moveIn(mark)
    local selected = ModData.getSelected()
    if #selected == 0 then
        MGE.say("select the objects to move to the atmo first")
        return
    end
    ModData.refreshJointIds()
    local moved, joined = {}, 0
    for i = #ModData.parsed.env_obj, 1, -1 do
        local obj = ModData.parsed.env_obj[i]
        if obj.selected then
            if ModData.jointIds[obj.id] then
                joined = joined + 1
            else
                writeMissingLines(obj)
                if mark then obj.props[AtmoLayer.FROM_KEY] = tostring(obj.id) end
                MGE.Atmo.fromMod(obj)
                obj.kind = "atmo"
                table.remove(ModData.parsed.env_obj, i)
                ModData.releaseId(obj.id)
                table.insert(moved, 1, obj) -- id order
            end
        end
    end
    if joined > 0 then
        MGE.say("" .. joined .. " joint-linked objects stay (unlink them first)")
    end
    if #moved == 0 then return end
    for _, obj in ipairs(moved) do
        table.insert(ModData.parsed.atmo, obj)
        obj.id = #ModData.parsed.atmo
    end
    MGE.say("moved " .. #moved .. " objects to the atmo (" .. #ModData.parsed.atmo .. " in all)")
    History.commit()
    MGE.apply()
end

-- Playable's tag on objects it moves into the atmo: their object id, so Default can move them back.
-- The game's atmo loader skips it
AtmoLayer.FROM_KEY = "mge_was_object"

---Takes id off the free lists when it's on one
---@param id integer?
---@return boolean taken
local function takeFreeId(id)
    for _, pool in pairs(ModData.freeIds) do
        for i, free in ipairs(pool) do
            if free == id then
                table.remove(pool, i)
                return true
            end
        end
    end
    return false
end

---Makes atmo objects objects again (FROM_KEY ones get their old id if free). With too few free ids,
---the first ones come back. No undo step: the caller commits
---@param list FileParserEnvObj[] atmo objects
---@return integer count moved back
function AtmoLayer.returnObjects(list)
    local count = math.min(#list, ModData.freeCount())
    if count == 0 then return 0 end
    local ids, plans, planned = {}, {}, {}
    for i = 1, count do
        local old = tonumber(list[i].props[AtmoLayer.FROM_KEY])
        if old and takeFreeId(old) then
            ids[i] = old
        else
            plans[#plans + 1] = { pool = ModData.idPool(list[i], false, {}), linked = false }
            planned[#plans] = i
        end
    end
    local got = ModData.allocateIds(plans) -- fits: count <= free ids
    if not got then
        for i = 1, count do if ids[i] then ModData.releaseId(ids[i]) end end
        return 0
    end
    for k, i in ipairs(planned) do ids[i] = got[k] end
    local back = {}
    for i = 1, count do
        local obj = list[i]
        back[obj] = true
        obj.props[AtmoLayer.FROM_KEY] = nil
        obj.id, obj.kind = ids[i], "env_obj"
        table.insert(ModData.parsed.env_obj, obj)
    end
    keepAtmo(function(obj) return not back[obj] end)
    ModData.sortObjects()
    return count
end

---Moves the selected atmo objects back to objects, still selected
function AtmoLayer.moveOut()
    local list = ModData.getSelectedAtmo()
    if #list == 0 then
        MGE.say("select atmo objects (the Atmo list) to move back first")
        return
    end
    local count = AtmoLayer.returnObjects(list)
    if count == 0 then
        MGE.say("no free object ids: delete objects first")
        return
    end
    MGE.say("moved " .. count .. " atmo objects back to objects" ..
        (count < #list and (", " .. (#list - count) .. " stay: no free ids") or ""))
    History.commit()
    MGE.apply()
end

---To atmo: moveIn, then show the Atmo list
function AtmoLayer.toAtmo()
    local before = #ModData.parsed.atmo
    AtmoLayer.moveIn()
    if #ModData.parsed.atmo > before and MGE.Main then MGE.Main.setListTab("atmo") end
end

---To objects: moveOut, then show the Objects list
function AtmoLayer.toObjects()
    local before = #ModData.parsed.atmo
    AtmoLayer.moveOut()
    if #ModData.parsed.atmo < before and MGE.Main then MGE.Main.setListTab("objects") end
end

---Adds objects to the atmo, selected (an import's overflow). The caller commits and applies
---@param objects FileParserEnvObj[]
function AtmoLayer.add(objects)
    for _, obj in ipairs(objects) do
        obj.kind, obj.selected = "atmo", true
        MGE.Atmo.fromMod(obj)
        table.insert(ModData.parsed.atmo, obj)
        obj.id = #ModData.parsed.atmo
    end
end

---Unloads the game's loaded atmo at startup: MGE draws the mod's atmo itself, and a loaded export would
---show every object twice. atmo.cfg's default is left alone
---@return boolean unloaded
function AtmoLayer.unloadGameAtmo()
    if rawget(_G, "_ATMO") == nil then return false end
    local manager = rawget(_G, "Atmospheres")
    if type(manager) ~= "table" or type(manager.Unload) ~= "function" then return false end
    local ok = pcall(manager.Unload)
    if ok then MGE.say("game atmo unloaded (MGE draws its own)") end
    return ok
end

---Removes the selected atmo objects (ui/editor.lua does the rest)
---@return integer removed
function AtmoLayer.removeSelected()
    local before = #ModData.parsed.atmo
    keepAtmo(function(obj) return not obj.selected end)
    return before - #ModData.parsed.atmo
end

---@param obj FileParserEnvObj
---@return boolean its id is an atmo list index, not an object id
function AtmoLayer.isAtmo(obj)
    return obj.kind == "atmo"
end

---@param obj FileParserEnvObj
---@return number[] pos line, 0 0 0 without one
local function posOf(obj)
    local p = numbers(obj.props.pos)
    return { p[1] or 0, p[2] or 0, p[3] or 0 }
end
AtmoLayer.posOf = posOf

---Average of the pos lines (the gizmo's spot for atmo alone)
---@param list FileParserEnvObj[]
---@return number[]
function AtmoLayer.center(list)
    local c = { 0, 0, 0 }
    for _, obj in ipairs(list) do
        local p = posOf(obj)
        for k = 1, 3 do c[k] = c[k] + p[k] / #list end
    end
    return c
end

---Moves atmo objects' pos lines. The caller commits
---@param list FileParserEnvObj[]
---@param offset number[]
---@param props table<FileParserEnvObj, table>? write into these copies instead (preview)
function AtmoLayer.moveBy(list, offset, props)
    for _, obj in ipairs(list) do
        local target = props and props[obj] or obj
        local p = numbers(target.props.pos)
        MGE.Transforms.writeVector(target, "pos", { (p[1] or 0) + offset[1], (p[2] or 0) + offset[2], (p[3] or 0) + offset[3] })
    end
end

local RotatingOld = dofile(MGE.scriptPath .. "utils/rotating.lua")

---Rotates atmo objects around pivot with the objects' rotate math (Transforms.rotBy), so they match.
---The caller commits
---@param list FileParserEnvObj[]
---@param rotation number[][]
---@param pivot number[]
---@param props table<FileParserEnvObj, table>? see moveBy
function AtmoLayer.rotateBy(list, rotation, pivot, props)
    local ox, oy, oz = Mat3.toEulerXYZ(rotation) -- rotBy's offsets: rotX(x) rotY(y) rotZ(z)
    for _, obj in ipairs(list) do
        local target = props and props[obj] or obj
        local pos, rot = numbers(target.props.pos), numbers(target.props.rot)
        local r = math.rad
        local outRot = RotatingOld.SetRotOffset(r(rot[1] or 0), r(rot[2] or 0), r(rot[3] or 0), ox, oy, oz)
        MGE.Transforms.writeVector(target, "rot", outRot)
        if not MGE.Transforms.inPlace then
            local outPos = RotatingOld.SetRotPos(pos[1] or 0, pos[2] or 0, pos[3] or 0, pivot[1], pivot[2], pivot[3], ox, oy, oz)
            MGE.Transforms.writeVector(target, "pos", outPos)
        end
    end
end

---Scales atmo objects along frame's axes around pivot, like the objects' gizmo Scale. The caller commits
---@param list FileParserEnvObj[]
---@param factors number[]
---@param pivot number[]
---@param frame number[][] group frame, columns are its axes
---@param props table<FileParserEnvObj, table>? see moveBy
function AtmoLayer.scaleBy(list, factors, pivot, frame, props)
    local T = MGE.Transforms
    local map = Mat3.mul(Mat3.mul(frame, { { factors[1], 0, 0 }, { 0, factors[2], 0 }, { 0, 0, factors[3] } }), Mat3.transpose(frame))
    for _, obj in ipairs(list) do
        local target = props and props[obj] or obj
        local p = numbers(target.props.pos)
        local rel = Mat3.apply(map, { (p[1] or 0) - pivot[1], (p[2] or 0) - pivot[2], (p[3] or 0) - pivot[3] })
        local s = numbers(target.props.sides)
        local sides = T.scaleSidesFor(target, { s[1] or 1, s[2] or 1, s[3] or 1 }, frame, factors, shapeOf(target))
        if not T.inPlace then T.writeVector(target, "pos", { pivot[1] + rel[1], pivot[2] + rel[2], pivot[3] + rel[3] }) end
        T.writeVector(target, "sides", sides)
    end
end

---A selected ghost as the drag in progress (AtmoLayer.live) leaves it: the moveBy / rotateBy / scaleBy
---math done on the cached ghost, not on copied lines (which stuttered with thousands selected)
---@param g AtmoGhost
---@param live table AtmoLayer.live
---@return AtmoGhost
function AtmoLayer.liveGhost(g, live)
    -- plain numbers: runs for every selected object each frame
    local x, y, z = g.pos[1], g.pos[2], g.pos[3]
    local frame, sides, radius = g.frame, g.sides, g.radius
    if live.move then
        local m = live.move
        x, y, z = x + m[1], y + m[2], z + m[3]
    end
    local inPlace = MGE.Transforms.inPlace
    if live.rotation then
        local c, r = live.pivot, live.rotation
        if not inPlace then
            local dx, dy, dz = x - c[1], y - c[2], z - c[3]
            x = c[1] + r[1][1] * dx + r[1][2] * dy + r[1][3] * dz
            y = c[2] + r[2][1] * dx + r[2][2] * dy + r[2][3] * dz
            z = c[3] + r[3][1] * dx + r[3][2] * dy + r[3][3] * dz
        end
        -- each shared frame turned once per drag step (live is new every step)
        live.turned = live.turned or {}
        local turned = live.turned[frame]
        if not turned then
            turned = Mat3.mul(r, frame)
            live.turned[frame] = turned
        end
        frame = turned
    end
    if live.scale then
        local c, gf = live.pivot, live.frame
        -- group scale once per step, side factors once per shared frame
        local map = live.map
        if not map then
            map = Mat3.mul(Mat3.mul(gf, { { live.scale[1], 0, 0 }, { 0, live.scale[2], 0 }, { 0, 0, live.scale[3] } }),
                Mat3.transpose(gf))
            live.map = map
        end
        if not inPlace then
            local dx, dy, dz = x - c[1], y - c[2], z - c[3]
            x = c[1] + map[1][1] * dx + map[1][2] * dy + map[1][3] * dz
            y = c[2] + map[2][1] * dx + map[2][2] * dy + map[2][3] * dz
            z = c[3] + map[3][1] * dx + map[3][2] * dy + map[3][3] * dz
        end
        live.factorsBy = live.factorsBy or {}
        local f = live.factorsBy[frame]
        if not f then
            f = MGE.Transforms.sideFactors(Mat3.transpose(frame), gf, live.scale)
            live.factorsBy[frame] = f
        end
        sides = MGE.Transforms.applySideFactors(sides, f, g.shape == "sphere", g.shape == "cylinder")
        radius = ghostRadius(g.shape, sides)
    end
    return { shape = g.shape, pos = { x, y, z }, frame = frame, sides = sides, radius = radius }
end

---The selected atmo objects as the drag in progress would leave them (copies), nil without a drag
---@return table<FileParserEnvObj, FileParserEnvObj>? copies by object
function AtmoLayer.liveCopies()
    local live = AtmoLayer.live
    if not live then return nil end
    local list, copies = {}, {}
    for _, obj in ipairs(ModData.getSelectedAtmo()) do
        list[#list + 1] = obj
        copies[obj] = { kind = obj.kind, id = obj.id, props = ModData.copy(obj.props), selected = true }
    end
    if live.move then AtmoLayer.moveBy(list, live.move, copies) end
    if live.rotation then AtmoLayer.rotateBy(list, live.rotation, live.pivot, copies) end
    if live.scale then AtmoLayer.scaleBy(list, live.scale, live.pivot, live.frame, copies) end
    return copies
end

---@type table<integer, number[]>? colors before see-through, by 0-based game id
local seeThrough = nil

---Makes the mod's objects see-through (Atmo list) or restores them. Live alpha only, lines untouched.
---A reload restores file colors; reapplySeeThrough redoes it
---@param on boolean
function AtmoLayer.setObjectsSeeThrough(on)
    if on then
        if seeThrough then return end
        seeThrough = {}
        for _, obj in ipairs(ModData.parsed.env_obj) do
            local id = obj.id - 1
            if get_obj_pos(id) ~= nil then
                local r, g, b, a = objColor(id)
                if r then
                    seeThrough[id] = { r, g, b, a }
                    pcall(set_obj_color, id, r, g, b, math.min(a, AtmoLayer.seeThroughAlpha))
                end
            end
        end
    elseif seeThrough then
        for id, c in pairs(seeThrough) do
            if get_obj_pos(id) ~= nil then pcall(set_obj_color, id, c[1], c[2], c[3], c[4]) end
        end
        seeThrough = nil
    end
end

---Sets an object's live color (undo) keeping see-through: the color is stored for restoring instead
---@param id integer 0-based
function AtmoLayer.setObjectColor(id, r, g, b, a)
    if seeThrough then
        seeThrough[id] = { r, g, b, a }
        a = math.min(a, AtmoLayer.seeThroughAlpha)
    end
    set_obj_color(id, r, g, b, a)
end

---After a reload: see-through again if it was
function AtmoLayer.reapplySeeThrough()
    if not seeThrough then return end
    seeThrough = nil
    AtmoLayer.setObjectsSeeThrough(true)
end

table.insert(MGE.onQuit, function() AtmoLayer.setObjectsSeeThrough(false) end)

---World > Export > Atmo: writes data/atmospheres/MGE - exp_<name>.atmo for players without Atmo Play
function AtmoLayer.exportAtmo()
    local Atmo = MGE.Atmo
    if Atmo.contentCount() == 0 then
        MGE.say("the atmo is empty: To atmo (Objects > Core) or New add to it")
        return
    end
    MGE.askExportName("Export atmo (atmospheres/" .. Atmo.prefix .. MGE.EXPORT_PREFIX .. "<name>)",
        function(name)
            local file = Atmo.fileName(name)
            if Atmo.export(name) then
                MGE.say("exported data/atmospheres/" .. file .. " (" .. #ModData.parsed.atmo .. " objects)")
            else
                MGE.say("couldn't write data/atmospheres/" .. tostring(file))
            end
        end)
end

return AtmoLayer
