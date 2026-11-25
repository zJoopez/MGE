local assetsView = {}

local Main = MGE.Main
local ModData = MGE.ModData
local History = MGE.History
local Joints = MGE.Joints
local ScrollList = MGE.ScrollList
local FileHandler = MGE.FileHandler
local SHAPE = MGE.SHAPE

local selectedAssetName = nil -- last picked asset's name, the next export's default
---@type table<string, string> last imported path per kind (relative to its folder), selected when Import opens
local lastImported = {}

local ASSET_DIR = MGE.scriptPath .. "assets"
local ASSET_FOLDERS = { obj = "obj", player = "player" }
---@type "obj"|"player"
local assetKind = "obj" -- from the list tab on export / import


---File name for an asset: spaces become _, other unsafe characters are dropped, .tbm is added
---@param name string?
---@return string "" when nothing usable is left
local function sanitizeAssetName(name)
    local sanitized = (name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "_"):gsub("[^%w%-%_%.]+", "")
    if sanitized ~= "" and not sanitized:find("%.") then
        sanitized = sanitized .. ".tbm"
    end
    return sanitized
end

---A save prompt validator: refuses an empty name
---@param message string
---@return fun(name: string): boolean, string?
local function requireName(message)
    return function(name)
        if name == "" then return false, message end
        return true
    end
end

---@param name string?
---@return string?
local function getAssetPath(name)
    local fileName = sanitizeAssetName(name)
    if fileName == "" then return nil end
    return ASSET_DIR .. "/" .. ASSET_FOLDERS[assetKind] .. "/" .. fileName
end

---Path of a picked asset, relative to the kind's folder
---@param relative string e.g. "vehicles/scooter.tbm"
---@return string?
local function getImportPath(relative)
    if relative:find("%.%.") then return nil end
    return ASSET_DIR .. "/" .. ASSET_FOLDERS[assetKind] .. "/" .. relative
end

---Distance from an object's center to its lowest point, rotation (from the rot line) included
---@param obj FileParserEnvObj
---@return number?
local function getObjHalfHeight(obj)
    local id = obj.id - 1
    local sx, sy, sz = get_obj_sides(id)
    local shape = get_obj_shape(id)
    if sx == nil or shape == nil then return nil end
    -- third row: the local axes' world z
    local rot = MGE.Transforms.orientationOf(obj)
    local zx, zy, zz = math.abs(rot[3][1]), math.abs(rot[3][2]), math.abs(rot[3][3])

    if shape == SHAPE.SPHERE then
        return sx -- x is radius
    elseif shape == SHAPE.CAPSULE then
        return zz * sy / 2 + sx -- x radius, y straight length along local z
    end
    return (zx * sx + zy * sy + zz * sz) / 2 -- box: projected half extents
end

local function saveSelectedToAsset()
    local selectedObjects = ModData.getSelected()
    if #selectedObjects == 0 then
        MGE.say("No objects selected")
        return
    end

    MGE.saveOverlayContext = {
        title = "Asset Name",
        placeholder = "Enter asset name",
        defaultName = selectedAssetName or "",
        sanitize = sanitizeAssetName,
        validate = requireName("Enter an asset name"),
        onSave = function(name)
            local path = getAssetPath(name)
            local parser = { env_obj = {}, env_obj_joint = {}, ignores = {} }
            local positions = {}
            local totalX, totalY, minZ = 0, 0, nil

            for i, obj in ipairs(selectedObjects) do
                local x, y, z
                if get_obj_pos(obj.id - 1) ~= nil then -- in the world; file position
                    local pos = MGE.Transforms.positionOf(obj)
                    x, y, z = pos[1], pos[2], pos[3]
                end
                local halfHeight = getObjHalfHeight(obj)
                if x == nil or y == nil or z == nil or halfHeight == nil then
                    MGE.say("Unable to read selected object position or scale")
                    return false
                end
                positions[i] = { x = x, y = y, z = z }
                totalX = totalX + x
                totalY = totalY + y
                minZ = minZ and math.min(minZ, z - halfHeight) or z - halfHeight
            end

            -- stored centered on POS_ORIGIN with its lowest point at z 0
            local centerX = totalX / #positions - MGE.POS_ORIGIN[1]
            local centerY = totalY / #positions - MGE.POS_ORIGIN[2]
            for i, obj in ipairs(selectedObjects) do
                local assetObj = { kind = "env_obj", id = obj.id, props = ModData.copy(obj.props) }
                local pos = positions[i]
                assetObj.props.pos = FileHandler.formatNumbers(pos.x - centerX, pos.y - centerY, pos.z - minZ)
                table.insert(parser.env_obj, assetObj)
            end
            -- joints between selected objects get the same offset
            for _, joint in ipairs(Joints.getLinked(Joints.idSet(selectedObjects))) do
                local assetJoint = Joints.copy(joint, joint.id, joint.obj1, joint.obj2)
                Joints.transformPos(assetJoint, function(x, y, z)
                    return x - centerX, y - centerY, z - minZ
                end)
                table.insert(parser.env_obj_joint, assetJoint)
            end
            if FileHandler.WriteMod(parser, path) then
                MGE.say("asset saved: " .. path)
                return true
            end
            MGE.say("failed to save asset")
            return false
        end
    }
    dofile(MGE.scriptPath .. "ui/save_overlay.lua")
end

---@return number[]? a vector line's three numbers, nil otherwise
---@param line string?
---@return number[]?
local function readVector(line)
    local x, y, z = (line or ""):match("(%S+)%s+(%S+)%s+(%S+)")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x and y and z then return { x, y, z } end
    return nil
end

---Box around objects from their props (not in the world yet), rotation included
---@param objects FileParserEnvObj[]
---@return SpawnBounds?
local function propsBounds(objects)
    local min, max = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    local any = false
    for _, obj in ipairs(objects) do
        local pos = readVector(obj.props.pos)
        if pos then
            any = true
            local s = readVector(obj.props.sides) or { 0.5, 0.5, 0.5 }
            local shape = (obj.props.shape or "box"):lower()
            local rot = MGE.Transforms.orientationOf(obj) -- rot[k][j]: world k of local axis j
            for k = 1, 3 do
                local extent
                if shape == "sphere" then
                    extent = s[1]
                elseif shape == "cylinder" then -- x radius, y length along local z
                    extent = math.abs(rot[k][3]) * s[2] / 2 + s[1]
                else
                    extent = (math.abs(rot[k][1]) * s[1] + math.abs(rot[k][2]) * s[2] + math.abs(rot[k][3]) * s[3]) / 2
                end
                min[k] = math.min(min[k], pos[k] - extent)
                max[k] = math.max(max[k], pos[k] + extent)
            end
        end
    end
    return any and { min = min, max = max } or nil
end

---Moves asset objects and joints in front of the camera, keeping their layout (in place)
---@param parser FileParserResult
local function placeInView(parser)
    local bounds = propsBounds(parser.env_obj)
    if not bounds then return end
    local shift = MGE.Camera.spawnShift(bounds, MGE.Camera.spawnPoint(bounds))
    for _, obj in ipairs(parser.env_obj) do
        local pos = readVector(obj.props.pos)
        if pos then
            obj.props.pos = FileHandler.formatNumbers(pos[1] + shift[1], pos[2] + shift[2], pos[3] + shift[3])
        end
    end
    for _, joint in ipairs(parser.env_obj_joint) do
        Joints.transformPos(joint, function(x, y, z) return x + shift[1], y + shift[2], z + shift[3] end)
    end
end

---Gives joints without a pos line one halfway between their objects, before the objects move (without
---it, an asset placed away from the dojo center folds up). In place
---@param parser FileParserResult
---@return integer filled
local function fillJointAnchors(parser)
    local byId = {}
    for _, obj in ipairs(parser.env_obj) do byId[obj.id] = obj end
    local filled = 0
    for _, joint in ipairs(parser.env_obj_joint) do
        local a, b = byId[joint.obj1], byId[joint.obj2]
        -- from the asset's lines: not in the world yet
        if not joint.props.pos and a and b and readVector(a.props.pos) and readVector(b.props.pos) then
            joint.props.pos = Joints.midpoint(a, b)
            filled = filled + 1
        end
    end
    return filled
end

---Adds an asset's objects (and joints between them), selected, in one undo step, then reloads
---@param parser FileParserResult
---@param keepTab boolean? stay on the shown editor tab instead of Core
---@param inView boolean? move them in front of the camera first
---@param jointIds integer[]? ids for the joints in order
---@param atmoExcess (boolean|integer)? the last objects past the free ids (or past this number) go to
---the atmo instead of failing: put the important ones first
---@return boolean added
local function importObjects(parser, keepTab, inView, jointIds, atmoExcess)
    -- only joints with both objects in the asset are imported
    local linkedJoints = Joints.getLinked(Joints.idSet(parser.env_obj), parser.env_obj_joint)
    if not Joints.haveRoom(#linkedJoints) then return false end
    local linkedIds = Joints.getObjectIds(linkedJoints)
    ---@type FileParserEnvObj[] the ones going to the atmo
    local excess = {}
    if atmoExcess and #linkedJoints == 0 then
        local free = ModData.freeCount()
        if type(atmoExcess) == "number" then free = math.max(0, math.min(free, atmoExcess)) end
        local over = #parser.env_obj - free
        for _ = 1, over do table.insert(excess, 1, table.remove(parser.env_obj)) end
    end
    local plans = {}
    for i, assetObj in ipairs(parser.env_obj) do
        plans[i] = { pool = ModData.isStatic(assetObj) and "static" or "nonStatic", linked = linkedIds[assetObj.id] or false }
    end
    local ids = ModData.allocateIds(plans) -- all or nothing
    if not ids then return false end
    local filled = fillJointAnchors(parser) -- before placeInView
    if filled > 0 then MGE.say("" .. filled .. " joints without pos: anchored between their objects") end
    if inView then placeInView(parser) end

    -- the selection moves to the imported objects
    for _, obj in ipairs(ModData.parsed.env_obj) do
        obj.selected = nil
    end
    for _, obj in ipairs(ModData.parsed.atmo) do
        obj.selected = nil
    end

    local idMap = {} -- asset object id -> id in the mod
    for i, assetObj in ipairs(parser.env_obj) do
        local newId = ids[i]
        table.insert(ModData.parsed.env_obj, { kind = "env_obj", id = newId, props = ModData.copy(assetObj.props),
            selected = true })
        idMap[assetObj.id] = newId
    end
    local importedJoints = Joints.copyLinked(parser.env_obj_joint, idMap, jointIds)
    local atmoObjs = {}
    for i, assetObj in ipairs(excess) do
        atmoObjs[i] = { kind = "env_obj", id = 0, props = ModData.copy(assetObj.props) }
    end
    MGE.AtmoLayer.add(atmoObjs)

    ModData.sortObjects()
    History.commit()
    if not keepTab then MGE.Main.setTab("core") end
    MGE.focusAfterReload = true -- camera follow once they're in the world
    MGE.apply()
    MGE.say("imported " .. #parser.env_obj .. " objects, " .. importedJoints .. " joints" ..
        (#atmoObjs > 0 and (", " .. #atmoObjs .. " atmo objects") or ""))
    return true
end

---@param assetName string
local function importAssetFromFile(assetName)
    local path = getImportPath(assetName)
    if not path or not Files.Exists(path) then
        MGE.say("Asset not found")
        return
    end

    local parser = FileHandler.ParseMod(path)
    if #parser.env_obj == 0 then
        MGE.say("Asset file contains no objects")
        return
    end
    importObjects(parser, false, true)
end

---A player's model parts: its own section or the shared parts, nil for the default body
---@param playerId integer
---@return string[]?
function assetsView.playerParts(playerId)
    return FileHandler.getPlayerLines(ModData.parsed, playerId) or FileHandler.getSharedPlayerLines(ModData.parsed)
end

---Saves a player's model (relative to its spawn, copied as is) as a player asset
---@param playerId integer? default the last picked player
local function savePlayerToAsset(playerId)
    Main.getPlayerCount() -- keeps selectedPlayer in range
    playerId = playerId or Main.selectedPlayer
    local parts = assetsView.playerParts(playerId)
    if not parts then
        MGE.say("player " .. playerId .. " has the default body: nothing to export")
        return
    end

    MGE.saveOverlayContext = {
        title = "Player Model Name",
        placeholder = "Enter model name",
        defaultName = selectedAssetName or "",
        sanitize = sanitizeAssetName,
        validate = requireName("Enter a model name"),
        onSave = function(name)
            local path = getAssetPath(name)
            if not path then return false end
            -- stored as player 0; importing writes it under the chosen players
            local lines = { "player 0" }
            for _, line in ipairs(parts) do table.insert(lines, line) end
            if FileHandler.WriteMod({ env_obj = {}, env_obj_joint = {}, ignores = lines }, path) then
                MGE.say("player model saved: " .. path)
                return true
            end
            MGE.say("failed to save player model")
            return false
        end
    }
    dofile(MGE.scriptPath .. "ui/save_overlay.lua")
end

---Gives every selected player the asset's model, one undo step
---@param assetName string
local function replacePlayerFromFile(assetName)
    local path = getImportPath(assetName)
    if not path or not Files.Exists(path) then
        MGE.say("Asset not found")
        return
    end
    -- the first player section, or shared parts (mods like fatkido.tbm work as is)
    local assetParser = FileHandler.ParseMod(path)
    local parts = FileHandler.getPlayerLines(assetParser) or FileHandler.getSharedPlayerLines(assetParser)
    if not parts then
        MGE.say("Asset file contains no body or joint changes")
        return
    end

    local players = Main.selectedPlayerList()
    if #players == 0 then
        MGE.say("Select the players to import the model to first")
        return
    end
    for _, playerId in ipairs(players) do
        FileHandler.setPlayerLines(ModData.parsed, playerId, parts)
    end
    History.commit()
    MGE.apply()
    MGE.say((#players == 1 and "player " or "players ") .. table.concat(players, ", ") .. " replaced with " .. assetName)
end


-- New's object (as assets/obj/default.tbm), here so New works without the file
local DEFAULT_OBJECT = {
    { "shape", "box" },
    { "pos", "1 -0.1 0.25" },
    { "rot", "0.00 0.00 0.00" },
    { "sides", "0.50 0.50 0.50" },
    { "color", "0.00000000 1.00000000 0.00000000 1.00000000" },
    { "flag", "0" },
    { "mass", "0.1000" },
    { "bounce", "0.100000" },
    { "friction", "10000.00" },
    { "force", "0.00 0.00 0.00" },
    { "visible", "1" },
    { "model_name", "env_obj1" },
    { "use_model", "0" },
    { "hardness", "0.000000" },
}

---@return table<string, string> a new copy of DEFAULT_OBJECT's properties
function assetsView.defaultProps()
    local props = {}
    for _, entry in ipairs(DEFAULT_OBJECT) do props[entry[1]] = entry[2] end
    return props
end

---Adds objects like an import (Generate, New)
---@param objects FileParserEnvObj[]
---@param keepTab boolean? see importObjects
---@param inView boolean? see importObjects
---@param joints FileParserEnvObjJoint[]? joints between the objects (by the objects' ids here)
---@param atmoExcess (boolean|integer)? see importObjects
---@return boolean added
function assetsView.addObjects(objects, keepTab, inView, joints, atmoExcess)
    return importObjects({ env_obj = objects, env_obj_joint = joints or {}, ignores = {} }, keepTab, inView, nil, atmoExcess)
end

-- Atmo pieces (Atmo list Import / Export): .atmo files in assets/atmo or data/atmospheres, added as
-- they are. No reload: atmo objects aren't in the .tbm
local ATMO_DIR = ASSET_DIR .. "/atmo"
local ATMO_ROOTS = {
    { root = "data/script/" .. ATMO_DIR, label = "assets/atmo" },
    { root = "data/atmospheres", label = "data/atmospheres" },
}
---@type string? last imported .atmo, relative to its root
local lastAtmo = nil

---Adds atmo objects, alone selected, one undo step
---@param objects FileParserEnvObj[]
---@param inView boolean? moved in front of the camera first
---@return boolean added
local function addAtmo(objects, inView)
    if #objects == 0 then return false end
    if inView then placeInView({ env_obj = objects, env_obj_joint = {}, ignores = {} }) end
    local layer = ModData.parsed.atmo
    for _, obj in ipairs(layer) do obj.selected = nil end
    for _, obj in ipairs(objects) do
        obj.kind, obj.selected = "atmo", true
        layer[#layer + 1] = obj
        obj.id = #layer
    end
    History.commit()
    -- a playable mod may reload for new pools (the camera follows after it)
    if MGE.Playable.reloadIfSplitChanged() then
        MGE.focusAfterReload = true
    else
        Main.updateWindow()
        MGE.Camera.followSelection()
    end
    return true
end
assetsView.addAtmo = addAtmo

---New on the Atmo list: a default box in front of the camera (look lines only)
function assetsView.newAtmo()
    local all = assetsView.defaultProps()
    -- mass too: the game skips it, Atmo Play's props use it
    local props = { shape = all.shape, pos = all.pos, rot = all.rot, sides = all.sides, color = all.color, mass = all.mass }
    addAtmo({ { kind = "atmo", id = 1, props = props } }, true)
end

---Import on the Atmo list: an .atmo's objects join the atmo where the file has them; its header lines
---become the atmo's when it has none
function assetsView.openAtmoImport()
    MGE.FilePicker.open({
        title = "Import Atmo",
        roots = ATMO_ROOTS,
        extension = "atmo",
        keepExtension = true,
        selected = lastAtmo,
        confirmLabel = "Import",
        emptyText = "No .atmo files here. Export (Atmo list) saves to assets/atmo",
        onConfirm = function(path, root)
            if path:find("%.%.") then return end
            lastAtmo = path
            local filePath = root == ATMO_ROOTS[1].root and (ATMO_DIR .. "/" .. path) or ("../data/atmospheres/" .. path)
            local lines = FileHandler.readLines(filePath)
            if not lines then
                MGE.say("couldn't read " .. path)
                return
            end
            local atmo = MGE.Atmo.parse(lines)
            if #atmo.objects == 0 then
                MGE.say("no objects in " .. path)
                return
            end
            local state = MGE.Atmo.state
            local headerTaken = #atmo.header > 0 and #state.header == 0
            if addAtmo(atmo.objects, false) then
                if headerTaken then state.header = atmo.header end
                MGE.say("imported " .. #atmo.objects .. " atmo objects from " .. path ..
                    (headerTaken and " (with its shader / options lines)" or ""))
            end
        end,
    })
end

---Export on the Atmo list: the selected atmo objects as an .atmo in assets/atmo
function assetsView.exportAtmo()
    local selected = ModData.getSelectedAtmo()
    if #selected == 0 then
        MGE.say("select the atmo objects to export first")
        return
    end
    MGE.saveOverlayContext = {
        title = "Atmo Piece Name",
        placeholder = "Enter a name",
        defaultName = "",
        sanitize = function(name) return (sanitizeAssetName(name):gsub("%.tbm$", ".atmo")) end,
        validate = requireName("Enter a name"),
        onSave = function(name)
            local fileName = sanitizeAssetName(name):gsub("%.tbm$", ""):gsub("%.atmo$", "") .. ".atmo"
            if not FileHandler.writeText(ATMO_DIR .. "/" .. fileName, MGE.Atmo.text({ objects = selected })) then
                MGE.say("couldn't write assets/atmo/" .. fileName)
                return false
            end
            lastAtmo = fileName
            MGE.say("saved assets/atmo/" .. fileName .. " (" .. #selected .. " objects)")
            return true
        end,
    }
    dofile(MGE.scriptPath .. "ui/save_overlay.lua")
end

---New on the Objects list: DEFAULT_OBJECT in front of the camera
function assetsView.newObject()
    assetsView.addObjects({ { kind = "env_obj", id = 1, props = assetsView.defaultProps() } }, false, true)
end

---Link tab Create with nothing picked: two touching DEFAULT_OBJECTs in front of the camera, joined at
---their shared face. One undo step
---@param jointId integer the empty slot
---@return boolean added
function assetsView.newPair(jointId)
    local objects = {}
    for i, dx in ipairs({ -0.25, 0.25 }) do -- 0.5 wide: they touch at its pos
        local props = assetsView.defaultProps()
        local x, y, z = props.pos:match("(%S+)%s+(%S+)%s+(%S+)")
        props.pos = FileHandler.formatNumbers(tonumber(x) + dx, tonumber(y), tonumber(z))
        objects[i] = { kind = "env_obj", id = i, props = props }
    end
    local joint = { kind = "env_obj_joint", id = jointId, obj1 = 1, obj2 = 2, lines = {},
        props = { pos = assetsView.defaultProps().pos, visible = Joints.NEW_VISIBLE } }
    return importObjects({ env_obj = objects, env_obj_joint = { joint }, ignores = {} }, true, true, { jointId })
end

---@return "obj"|"player" the shown list's asset kind
local function listKind()
    return Main.listTab == "players" and "player" or "obj"
end

---Export: the selected objects or the picked player's model
function assetsView.export()
    assetKind = listKind()
    if assetKind == "obj" then saveSelectedToAsset() else savePlayerToAsset() end
end

---Export on the Players list: that player's model
---@param playerId integer
function assetsView.exportPlayer(playerId)
    assetKind = "player"
    savePlayerToAsset(playerId)
end

---Import: picks a saved asset; objects are added in view, a model replaces the selected players'
function assetsView.openImport()
    assetKind = listKind()
    local kind = assetKind
    local players = kind == "player" and Main.selectedPlayerList() or {}
    if kind == "player" and #players == 0 then
        TBMenu:showStatusMessage("Select the players to import the model to first")
        return
    end
    MGE.FilePicker.open({
        title = kind == "obj" and "Import Objects"
            or ("Import Model to Player" .. (#players > 1 and "s " or " ") .. table.concat(players, ", ")),
        root = "data/script/" .. ASSET_DIR .. "/" .. ASSET_FOLDERS[kind],
        rootLabel = "assets/" .. ASSET_FOLDERS[kind],
        extension = "tbm",
        keepExtension = true,
        selected = lastImported[kind],
        confirmLabel = "Import",
        emptyText = "No folders or assets here, Export saves to assets/" .. ASSET_FOLDERS[kind],
        onConfirm = function(path)
            lastImported[kind] = path
            selectedAssetName = path:gsub("^.*/", "")
            assetKind = kind
            if kind == "obj" then importAssetFromFile(path) else replacePlayerFromFile(path) end
        end,
    })
end

MGE.Assets = assetsView
return assetsView
