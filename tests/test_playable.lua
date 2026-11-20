-- utils/playable.lua: Convert (static objects into the atmo, undo), the playable mod's text (pool, header,
-- "#@ " atmo) and reading it back, opening one (pool ids free). When Atmo Play's repo is next to this one
-- (data/script/atmoplayDev), its format.lua and colliders.lua read the text too: the two must agree
local T = ...
local FileHandler = MGE.FileHandler
local ModData = MGE.ModData
local Atmo = MGE.Atmo
local Playable = MGE.Playable

local function setup(objects, joints)
    ModData.parsed = { env_obj = objects, env_obj_joint = joints or {}, atmo = {}, ignores = { "version 15" },
        trailer = {} }
    ModData.freeIds = { nonStatic = {}, static = {} }
    local used = {}
    for _, obj in ipairs(objects) do used[obj.id] = true end
    for id = 1, MGE.MAX_ENV_OBJECTS do
        if not used[id] then table.insert(id <= MGE.MAX_NONSTATIC_OBJECTS and ModData.freeIds.nonStatic or ModData.freeIds.static, id) end
    end
    ModData.jointIds = {}
    MGE.History.reset()
end
MGE.apply = function() end
get_obj_flag = function() return 0 end
get_obj_color = function() return 1, 1, 1, 1 end

local function object(id, props)
    props = props or {}
    props.pos = props.pos or (id .. " 0 0")
    local lines = {}
    for key in pairs(props) do lines[#lines + 1] = { key = key } end
    table.sort(lines, function(a, b) return a.key < b.key end)
    return { kind = "env_obj", id = id, lines = lines, props = props }
end

local function splitLines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if lines[#lines] == "" then lines[#lines] = nil end
    return lines
end

---A small mod: 60 static (converted), 2 dynamic, 61 static but joint-linked, 62 a static model; and an atmo
local function smallMod()
    local static = object(60, { flag = "8", sides = "4 4 0.5", friction = "10000" })
    local dynamic = object(2, { flag = "0" })
    local linked = object(61, { flag = "8" })
    local model = object(62, { flag = "8", use_model = "1", model_name = "tree" })
    setup({ dynamic, static, linked, model }, { { kind = "env_obj_joint", id = 1, obj1 = 2, obj2 = 61, props = {}, lines = {} } })
    ModData.parsed.atmo = Atmo.parse(splitLines([[
env_obj wall
   shape box
   pos 10 0 1
   size 1 4 2
   friction 10000
env_obj ball
   shape sphere
   pos 12 0 1
   size 0.5 0 0
env_obj spinner
   pos 14 0 1
   rotate 0 0 1
env_obj tree
   shape custom tree
   pos 16 0 0]])).objects
    Atmo.state = { name = nil, header = { "shader dark" } }
    MGE.History.reset()
    return static, dynamic, linked, model
end

T.test("convert: static objects into the atmo, the mod playable, one undo step", function()
    local static, dynamic, linked, model = smallMod()
    T.ok(Playable.convertible(static), "static: converted")
    T.ok(not Playable.convertible(dynamic), "dynamic: stays")
    ModData.refreshJointIds()
    T.ok(not Playable.convertible(linked), "joint-linked: stays")
    T.ok(not Playable.convertible(model), "model: stays")
    T.ok(Playable.convert(), "converted")
    T.eq(#ModData.parsed.env_obj, 3, "three real objects left")
    T.eq(#ModData.parsed.atmo, 5, "the static object joined the four atmo objects")
    T.eq(ModData.parsed.atmo[5], static, "at the end of the atmo")
    T.eq(ModData.parsed.playable and ModData.parsed.playable.radius, 4, "playable, radius 4")
    MGE.History.undo()
    T.eq(ModData.parsed.playable, nil, "undo: not playable")
    T.eq(#ModData.parsed.env_obj, 4, "undo: the static object is back")
    MGE.History.redo()
    T.ok(ModData.parsed.playable ~= nil, "redo: playable again")
end)

T.test("the playable text: pool on free static ids, header, atmo; read back", function()
    smallMod()
    Playable.convert()
    local text, plan = Playable.text(ModData.parsed, Atmo.currentText())
    local lines = splitLines(text)
    T.eq(lines[1], Playable.NOTE, "the note first")
    -- solid: wall, ball, the converted box (spinner animated, tree a model)
    T.eq(plan.solid, 3, "three solid atmo objects")
    T.eq(plan.atmo, 5, "five atmo objects")
    T.eq(#plan.objects, 3, "pool capped at the solid count")
    T.eq(plan.freeIds, MGE.MAX_ENV_OBJECTS - MGE.MAX_NONSTATIC_OBJECTS - 2, "static ids minus 61 and 62")
    T.eq(plan.objects[1].id, MGE.MAX_NONSTATIC_OBJECTS + 1, "the first free static id")
    local groups = {}
    for _, p in ipairs(plan.objects) do groups[p.group] = (groups[p.group] or 0) + 1 end
    T.eq(groups["box|10000"], 2, "wall and the converted box share friction 10000")
    T.eq(groups["sphere|"], 1, "the ball")

    local split = Playable.split(lines)
    T.eq(split.header and split.header.radius, 4, "header read")
    T.eq(#split.pool, 3, "pool blocks found")
    for _, line in ipairs(split.lines) do
        T.ok(not line:match("^%s*#atmoplay") and not line:match("^#@"), "no Atmo Play lines left: " .. line)
    end
    local parsed = FileHandler.parseLines(split.lines)
    local ids = {}
    for _, obj in ipairs(parsed.env_obj) do ids[#ids + 1] = obj.id end
    T.eq(table.concat(ids, ","), "2,61,62", "the real objects, no pool")
    T.eq(#parsed.env_obj_joint, 1, "the joint")
    local atmo = Atmo.parse(split.atmo)
    T.eq(#atmo.objects, 5, "the atmo read back")
    T.eq(atmo.header[1], "shader dark", "with its shader line")
    T.eq(atmo.objects[5].props.friction, "10000", "the converted object's lines")
end)

T.test("Atmo Play reads MGE's playable mods the same way", function()
    local dir = T.dir .. "../../atmoplayDev/atmoplay/"
    local probe = io.open(dir .. "format.lua", "r")
    if not probe then
        print("  (atmoplayDev not next to mgeDev: skipped)")
        return
    end
    probe:close()
    smallMod()
    Playable.convert()
    local text, plan = Playable.text(ModData.parsed, Atmo.currentText())
    local saved = ATMOPLAY
    ATMOPLAY = {}
    local ok, err = pcall(function()
        for _, module in ipairs({ "mat3.lua", "format.lua", "colliders.lua" }) do dofile(dir .. module) end
        local file = ATMOPLAY.Format.read(splitLines(text))
        T.eq(file.header and file.header.radius, 4, "Atmo Play: header")
        T.eq(#file.pool, #plan.objects, "Atmo Play: pool objects")
        T.eq(#file.atmo, #Playable.split(splitLines(text)).atmo, "Atmo Play: atmo lines")
        local colliders, stats = ATMOPLAY.Colliders.build(file.atmo)
        T.eq(stats.collidable, plan.solid, "Atmo Play: the same solid objects")
        local groups = {}
        for _, c in ipairs(colliders) do groups[c.group] = true end
        for _, p in ipairs(file.pool) do
            local key = (p.shape or "box") .. "|" .. ATMOPLAY.Colliders.frictionKey(p.friction)
            T.ok(groups[key], "pool group " .. key .. " has colliders in Atmo Play")
        end
    end)
    ATMOPLAY = saved
    if not ok then error(err) end
end)

T.test("opening a playable mod: pool left out, its ids free, atmo and params from the file", function()
    smallMod()
    Playable.convert()
    local text, plan = Playable.text(ModData.parsed, Atmo.currentText())
    local saved = { modPath = MGE.modPath, modName = MGE.modName, modFolder = MGE.modFolder,
        get_obj_pos = get_obj_pos, get_game_rules = get_game_rules }
    local ok, err = pcall(function()
        MGE.modFolder, MGE.modPath, MGE.modName = "mods/", "modmaker/arena.tbm", "modmaker/arena.tbm"
        T.files["mods/modmaker/arena.tbm"] = text
        -- the world after /lm: the real objects and the pool
        local world = { [1] = true, [60] = true, [61] = true }
        for _, p in ipairs(plan.objects) do world[p.id - 1] = true end
        get_obj_pos = function(i) if world[i] then return 0, 0, 0 end end
        get_game_rules = function() return { numplayers = 2 } end
        ModData.parsed.playable = nil
        ModData.reloadObjects()
        T.ok(ModData.loadedPlayable ~= nil, "seen as playable")
        T.eq(#ModData.parsed.env_obj, 3, "the pool isn't in the data")
        local free = {}
        for _, id in ipairs(ModData.freeIds.static) do free[id] = true end
        for _, p in ipairs(plan.objects) do T.ok(free[p.id], "pool id " .. p.id .. " is free") end
        T.ok(not free[61] and not free[62], "the real objects' ids aren't")
        T.eq(#ModData.loadedPlayable.atmo, #Playable.split(splitLines(text)).atmo, "the atmo lines kept for Atmo.load")
        Atmo.load(MGE.modPath, ModData.loadedPlayable.atmo)
        T.eq(#ModData.parsed.atmo, 5, "the atmo layer from the mod")
        T.ok(not Atmo.hasChanges(), "and counts as saved")
    end)
    MGE.modPath, MGE.modName, MGE.modFolder = saved.modPath, saved.modName, saved.modFolder
    get_obj_pos, get_game_rules = saved.get_obj_pos, saved.get_game_rules
    if not ok then error(err) end
end)

T.test("convert with nothing to make solid says so", function()
    setup({ object(2, { flag = "0" }) })
    T.ok(not Playable.convert(), "not converted")
    T.eq(ModData.parsed.playable, nil, "not playable")
end)
