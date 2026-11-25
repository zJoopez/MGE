local FileHandler = MGE.FileHandler

---@enum FLAGS
local FLAGS = {
    NORMAL = 0,
    ALT = 1,
    SHIELD = 2,
    WEAPON = 6,
    STATIC = 8,
    UNGRIPPABLE = 16,
    DQ_DISABLE = 32,
    NO_DAMAGE = 64
}
---Values returned by get_obj_shape
---@enum SHAPE
local SHAPE = {
    SPHERE = 0,
    BOX = 1,
    CAPSULE = 2,
}

---@class FreeIdHolder
---@field nonStatic integer[]
---@field static integer[]

---@alias IdPool "static"|"nonStatic"

---@class ModData
---@field parsed FileParserResult
---@field freeIds FreeIdHolder
---@field jointIds table<integer, boolean> object ids linked to a joint
local ModData = {}

local MAX_ENV_OBJECTS = 256
local MAX_NONSTATIC_OBJECTS = 48
local MAX_ENV_JOINTS = 24 -- env_obj_joint ids 1-24

---Shallow copy
---@generic T: table
---@param t T
---@return T
function ModData.copy(t)
    local copy = {}
    for k, v in pairs(t or {}) do copy[k] = v end
    return copy
end

---Click selects only obj (clicking the only selected one deselects it); Shift + click toggles it
---@param obj FileParserEnvObj
---@param additive boolean Shift held
---@return boolean selected whether obj ended up selected
function ModData.clickSelect(obj, additive)
    if additive then
        obj.selected = not obj.selected or nil
        return obj.selected == true
    end
    local onlySelected = obj.selected
    -- objects and atmo objects are selected apart
    local list = obj.kind == "atmo" and (ModData.parsed.atmo or {}) or ModData.parsed.env_obj
    for _, other in ipairs(list) do
        if other ~= obj and other.selected then onlySelected = false end
        other.selected = nil
    end
    obj.selected = not onlySelected or nil
    return obj.selected == true
end

---What the editor, gizmo and transforms work on: selected atmo objects on the Atmo list, else objects
---@return FileParserEnvObj[]
function ModData.getEditSelection()
    if MGE.Main and MGE.Main.listTab == "atmo" then return ModData.getSelectedAtmo() end
    return ModData.getSelected()
end

---@param list FileParserEnvObj[]?
---@return FileParserEnvObj[]
local function selectedIn(list)
    local selected = {}
    for _, obj in ipairs(list or {}) do
        if obj.selected then selected[#selected + 1] = obj end
    end
    return selected
end

---@return FileParserEnvObj[]
function ModData.getSelectedAtmo()
    return selectedIn(ModData.parsed.atmo)
end

---@return FileParserEnvObj[] selected objects in the game (not atmo)
function ModData.getSelected()
    return selectedIn(ModData.parsed.env_obj)
end

---Keeps objects in id order: call after adding objects or changing ids
function ModData.sortObjects()
    table.sort(ModData.parsed.env_obj, function(a, b) return a.id < b.id end)
end

---The flag's static bit (8); other bits don't make an object static
---@param obj FileParserEnvObj
---@param loaded boolean? in the world: a missing flag line is read from the game
---@return boolean
function ModData.isStatic(obj, loaded)
    local flag = tonumber(obj.props.flag)
    if flag == nil and loaded then flag = get_obj_flag(obj.id - 1) end
    if flag == nil then return true end -- unknown: the safer pool
    return bit.band(flag, FLAGS.STATIC) ~= 0
end

---Static objects take ids above 48, dynamic and joint-linked ones 1-48
---@param obj FileParserEnvObj
---@param loaded boolean? see isStatic
---@param jointIds table<integer, boolean>? joint-linked ids, default the mod's
---@return IdPool
function ModData.idPool(obj, loaded, jointIds)
    if ModData.isStatic(obj, loaded) and not (jointIds or ModData.jointIds)[obj.id] then return "static" end
    return "nonStatic"
end

---@param joints FileParserEnvObjJoint[]?
---@return table<integer, boolean> object ids linked to any joint
local function getJointIds(joints)
    local ids = {}
    for _, joint in ipairs(joints or {}) do
        if joint.obj1 then ids[joint.obj1] = true end
        if joint.obj2 then ids[joint.obj2] = true end
    end
    return ids
end

-- Id rules: only joints strictly need ids 1-48 (the game ignores joints to higher ids). Dynamic objects
-- above 48 are treated partly as static, so they prefer low ids and the window warns until Reindex.
-- Ids change only on Reindex, or when joint-linked copies need low ids that static objects hold.

---@param id integer
---@return IdPool the free list id belongs to
local function rangeOf(id)
    return id <= MAX_NONSTATIC_OBJECTS and "nonStatic" or "static"
end

---Returns an id to the free lists
---@param id integer
function ModData.releaseId(id)
    local list = ModData.freeIds[rangeOf(id)]
    table.insert(list, id)
    table.sort(list)
end

---@return integer free object ids in both pools
function ModData.freeCount()
    return #ModData.freeIds.static + #ModData.freeIds.nonStatic
end

---@return integer objects that belong on ids 1-48 (dynamic or joint-linked)
function ModData.countDynamic()
    local count = 0
    for _, obj in ipairs(ModData.parsed.env_obj) do
        if ModData.idPool(obj, true) == "nonStatic" then count = count + 1 end
    end
    return count
end

---@return integer dynamic objects above id 48 (partly static to the game until Reindex)
function ModData.countMisplaced()
    local count = 0
    for _, obj in ipairs(ModData.parsed.env_obj) do
        if obj.id > MAX_NONSTATIC_OBJECTS and ModData.idPool(obj, true) == "nonStatic" then count = count + 1 end
    end
    return count
end

---Gives obj a new id. The game's flag is read by id, so a missing flag line is written first
---@param obj FileParserEnvObj
---@param id integer
local function changeId(obj, id)
    if obj.props.flag == nil then obj.props.flag = tostring(get_obj_flag(obj.id - 1) or FLAGS.STATIC) end
    obj.id = id
end

---Frees low ids for joint-linked objects by moving static objects up (highest low ids first).
---All or nothing
---@param count integer low ids needed in total
---@return boolean enough
local function freeLowIds(count)
    local free = ModData.freeIds
    local missing = count - #free.nonStatic
    if missing <= 0 then return true end

    local candidates = {}
    for _, obj in ipairs(ModData.parsed.env_obj) do
        if obj.id <= MAX_NONSTATIC_OBJECTS and ModData.idPool(obj, true) == "static" then
            table.insert(candidates, obj)
        end
    end
    if math.min(#candidates, #free.static) < missing then return false end
    table.sort(candidates, function(a, b) return a.id > b.id end)
    for i = 1, missing do
        local obj = candidates[i]
        table.insert(free.nonStatic, obj.id)
        changeId(obj, table.remove(free.static, 1))
    end
    table.sort(free.nonStatic)
    ModData.sortObjects()
    return true
end

---Picks ids for new objects, all or nothing. Joint-linked ones get low ids; others prefer their pool,
---else any free id. Says why when they don't fit
---@param plans { pool: IdPool, linked: boolean }[] one per new object
---@return integer[]? ids same order as plans
function ModData.allocateIds(plans)
    local free = ModData.freeIds
    local total = #free.nonStatic + #free.static
    if #plans > total then
        MGE.say("not enough object ids: " .. #plans .. " needed, " .. total .. " free")
        return nil
    end
    local linkedCount = 0
    for _, plan in ipairs(plans) do
        if plan.linked then linkedCount = linkedCount + 1 end
    end
    if not freeLowIds(linkedCount) then
        MGE.say("not enough ids 1-" .. MAX_NONSTATIC_OBJECTS .. " for joint-linked objects: " .. linkedCount ..
            " needed, " .. #free.nonStatic .. " free")
        return nil
    end

    local ids = {}
    for i, plan in ipairs(plans) do -- joint-linked first
        if plan.linked then ids[i] = table.remove(free.nonStatic, 1) end
    end
    for i, plan in ipairs(plans) do
        if not plan.linked then
            if #free[plan.pool] > 0 then
                ids[i] = table.remove(free[plan.pool], 1)
            elseif plan.pool == "static" then
                ids[i] = table.remove(free.nonStatic) -- highest low id, keeps the lowest free
            else
                ids[i] = table.remove(free.static, 1)
            end
        end
    end
    return ids
end

---Puts dynamic / joint-linked objects on ids 1-48 and static ones above, as far as ids allow (taking
---free low ids or swapping with low static objects). Joints follow the new ids
---@return integer moved objects that got a new id
---@return integer left dynamic objects still above
function ModData.reindex()
    local free = ModData.freeIds
    local highDynamic, lowStatic = {}, {}
    -- pools are read before any id changes (missing flags come from the game by id)
    for _, obj in ipairs(ModData.parsed.env_obj) do
        local pool = ModData.idPool(obj, true)
        if pool == "nonStatic" and obj.id > MAX_NONSTATIC_OBJECTS then
            table.insert(highDynamic, obj)
        elseif pool == "static" and obj.id <= MAX_NONSTATIC_OBJECTS then
            table.insert(lowStatic, obj)
        end
    end
    table.sort(highDynamic, function(a, b) return a.id < b.id end)
    table.sort(lowStatic, function(a, b) return a.id > b.id end) -- highest low ids move first

    local idMap = {} -- old id -> new id, each object moves at most once
    local function move(obj, id)
        idMap[obj.id] = id
        changeId(obj, id)
    end
    local left = 0
    for _, obj in ipairs(highDynamic) do
        local oldId = obj.id
        if #free.nonStatic > 0 then
            move(obj, table.remove(free.nonStatic, 1))
            table.insert(free.static, oldId)
        elseif #lowStatic > 0 then
            local static = table.remove(lowStatic, 1)
            local lowId = static.id
            move(static, oldId)
            move(obj, lowId)
        else
            left = left + 1
        end
    end
    table.sort(free.static)
    for _, obj in ipairs(lowStatic) do
        if #free.static == 0 then break end
        table.insert(free.nonStatic, obj.id)
        move(obj, table.remove(free.static, 1))
    end
    table.sort(free.nonStatic)

    local moved = 0
    for _ in pairs(idMap) do moved = moved + 1 end
    for _, joint in ipairs(ModData.parsed.env_obj_joint) do
        joint.obj1 = idMap[joint.obj1] or joint.obj1
        joint.obj2 = idMap[joint.obj2] or joint.obj2
    end
    ModData.jointIds = getJointIds(ModData.parsed.env_obj_joint)
    ModData.sortObjects()
    return moved, left
end

---Re-reads joint-linked ids, so links made since the load count before the reload
function ModData.refreshJointIds()
    ModData.jointIds = getJointIds(ModData.parsed.env_obj_joint)
end

-- model_name is relative to mod_assets/<mod name>/ whatever folder the mod file is in: ../Noki/PinTori is
-- mod_assets/Noki/PinTori.obj (Bowling_Noki.tbm, and the game's modmaker writes the same into modmaker/)

local SELF = "\0self" -- the mod's own asset folder, whose name fromModelName doesn't know

---@param model string path in mod_assets without .obj, e.g. "Noki/PinTori"
---@return string model_name
function ModData.toModelName(model)
    return "../" .. model
end

---@param modelName string?
---@return string? the mod_assets path (without .obj) it points to; nil for one in the mod's own folder.
---".." above mod_assets is skipped (older MGE versions wrote ../../ for mods in subfolders)
function ModData.fromModelName(modelName)
    if not modelName or modelName == "" then return nil end
    local parts = { SELF }
    for part in modelName:gmatch("[^/\\]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end
    if parts[1] == SELF or #parts == 0 then return nil end
    return table.concat(parts, "/")
end

---Repairs model_names that climb above mod_assets (MGE wrote ../../ for mods in subfolders): one ../ is right
local function repairModels()
    for _, obj in ipairs(ModData.parsed.env_obj) do
        local name = obj.props.model_name
        if obj.props.use_model == "1" and name and name:match("^%.%./%.%./") then
            local model = ModData.fromModelName(name)
            if model then obj.props.model_name = ModData.toModelName(model) end
        end
    end
end

local function init()
    ModData.parsed = { env_obj = {}, env_obj_joint = {}, atmo = {}, ignores = {} }
    ModData.freeIds = { nonStatic = {}, static = {} }
    ModData.jointIds = {}
end

---Re-reads the loaded mod and finds free ids in the world. Keeps the atmo layer and playable params
---(opening another mod replaces them in main.lua)
function ModData.reloadObjects()
    local atmo = ModData.parsed and ModData.parsed.atmo or {}
    local playable = ModData.parsed and ModData.parsed.playable
    init()
    ModData.loadedPlayable, ModData.loadedAtmo = nil, nil

    if MGE.modPath then
        -- a playable or drawn mod: its pool / atmo lines aren't parsed as the mod
        local lines = FileHandler.readLines(MGE.modFolder .. MGE.modPath) or {}
        local split = MGE.Playable and MGE.Playable.split(lines)
        if split and split.header then
            if MGE.AtmoPlay.Format.isDrawOnly(split.header) then
                ModData.loadedAtmo = split.atmo
            else
                ModData.loadedPlayable = split
            end
        end
        ModData.parsed = FileHandler.parseLines(split and split.lines or lines)
        local rules = get_game_rules and get_game_rules() or {} -- offline tests have no game
        local count = math.max(tonumber(rules.numplayers) or 2, 1)
        FileHandler.splitSharedPlayers(ModData.parsed, count)
        repairModels()
        ModData.jointIds = getJointIds(ModData.parsed.env_obj_joint)
    elseif tostring(MGE.modName or ""):match("%.tbm$") then
        MGE.say("Mod not found") -- built-in classic has no .tbm: nothing to say
    end
    ModData.parsed.atmo = atmo
    ModData.parsed.playable = playable

    -- free ids come from the world, also without a mod file
    for i = 0, MAX_ENV_OBJECTS - 1 do
        if get_obj_pos(i) == nil then
            local pool = i >= MAX_NONSTATIC_OBJECTS and ModData.freeIds.static or ModData.freeIds.nonStatic
            table.insert(pool, i + 1)
        end
    end
    -- a playable mod's pool objects are in the world but not the data: their ids are free
    if ModData.loadedPlayable then
        for _, id in ipairs(ModData.loadedPlayable.pool) do
            if get_obj_pos(id - 1) ~= nil then ModData.releaseId(id) end
        end
    end
    MGE.say("Mod data updated")
end

init()

MGE.ModData = ModData
MGE.FLAGS = FLAGS
MGE.SHAPE = SHAPE
MGE.MAX_ENV_OBJECTS = MAX_ENV_OBJECTS
MGE.MAX_NONSTATIC_OBJECTS = MAX_NONSTATIC_OBJECTS
MGE.MAX_ENV_JOINTS = MAX_ENV_JOINTS
-- smallest side MGE writes: zero-sized objects crash physics
MGE.MIN_SIDE = 0.0001
-- the dojo center in world coordinates: the Pos row is relative to it, assets and shapes center on it
MGE.POS_ORIGIN = { 1, -0.1, 0 }
