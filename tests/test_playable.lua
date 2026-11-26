-- utils/playable.lua: Convert (static objects into the atmo, undo), the playable mod's text (pool, header,
-- "#@ " atmo) and reading it back, opening one (pool ids free). Atmo Play's format.lua and colliders.lua
-- (atmoplay/) read the text too: the writer and the reader must agree
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
    T.ok(Playable.setPlayable(true), "made playable")
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

T.test("Default: the objects Playable moved come back as far as ids allow, the rest stay", function()
    local static = smallMod()
    local extra = object(70, { flag = "8" })
    table.insert(ModData.parsed.env_obj, extra)
    for i = #ModData.freeIds.static, 1, -1 do
        if ModData.freeIds.static[i] == 70 then table.remove(ModData.freeIds.static, i) end
    end
    MGE.History.reset()
    T.ok(Playable.setPlayable(true), "on")
    T.eq(#ModData.parsed.atmo, 6, "both static objects moved")
    T.eq(static.props[MGE.AtmoLayer.FROM_KEY], "60", "marked with the old id")
    local text = Atmo.currentText()
    T.ok(text:find("mge_was_object 60", 1, true) ~= nil, "the mark is saved with the atmo")
    -- the mod fills up: one free id left, not the old ones
    local free = ModData.freeIds
    local keep = table.remove(free.nonStatic, 1)
    free.static, free.nonStatic = {}, { keep }
    local said = {}
    local say = MGE.say
    MGE.say = function(msg) said[#said + 1] = msg end
    T.ok(Playable.setPlayable(false), "off")
    MGE.say = say
    T.ok(not Playable.isOn(), "not playable")
    T.eq(#ModData.parsed.env_obj, 4, "one came back")
    T.eq(#ModData.parsed.atmo, 5, "one stays in the atmo")
    T.eq(ModData.parsed.env_obj[1].id, keep, "on the free id")
    local warned = false
    for _, msg in ipairs(said) do if msg:find("stay in the atmo", 1, true) then warned = true end end
    T.ok(warned, "says some stay")
    local stays = 0
    for _, obj in ipairs(ModData.parsed.atmo) do
        if obj.props[MGE.AtmoLayer.FROM_KEY] then stays = stays + 1 end
    end
    T.eq(stays, 1, "the one left keeps its mark")
end)

T.test("To objects drops Playable's mark; the atmo's own objects never had one", function()
    smallMod()
    Playable.setPlayable(true)
    local marked = 0
    for _, obj in ipairs(ModData.parsed.atmo) do
        obj.selected = obj.props[MGE.AtmoLayer.FROM_KEY] and true or nil
        if obj.selected then marked = marked + 1 end
    end
    T.eq(marked, 1, "only the converted object is marked")
    MGE.AtmoLayer.moveOut()
    for _, obj in ipairs(ModData.parsed.env_obj) do
        T.eq(obj.props[MGE.AtmoLayer.FROM_KEY], nil, "no mark on objects")
    end
    T.eq(#ModData.parsed.env_obj, 4, "back")
end)

T.test("the playable text: pool on free static ids, header, atmo; read back", function()
    smallMod()
    Playable.setPlayable(true)
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
    smallMod()
    Playable.setPlayable(true)
    local text, plan = Playable.text(ModData.parsed, Atmo.currentText())
    local ok, err = pcall(function()
        -- Atmo Play's modules as tests/run.lua loaded them (atmoplay/)
        local file = ATMOPLAY.Format.read(splitLines(text))
        T.eq(file.header and file.header.radius, 4, "Atmo Play: header")
        T.eq(#file.pool, #plan.objects, "Atmo Play: pool objects")
        T.eq(#file.atmo, #Playable.split(splitLines(text)).atmo, "Atmo Play: atmo lines")
        local colliders, stats = ATMOPLAY.Colliders.build(file.atmo)
        T.eq(stats.collidable, plan.solid, "Atmo Play: the same solid objects")
        local groups = {}
        for _, c in ipairs(colliders) do groups[c.group] = true end
        for _, p in ipairs(file.pool) do
            local key = ATMOPLAY.Colliders.groupKey(ATMOPLAY.Colliders.shapeOf(p.shape) or "box", p)
            T.ok(groups[key], "pool group " .. key .. " has colliders in Atmo Play")
        end
    end)
    if not ok then error(err) end
end)

T.test("bounce and flag bits: their own pool group, written on the pool objects (set live, replays don't keep them)", function()
    smallMod()
    Playable.setPlayable(true)
    for _, obj in ipairs(ModData.parsed.atmo) do
        if obj.props.shape == "sphere" then obj.props.bounce, obj.props.flag = "10", "24" end -- bouncy, nogrip
    end
    local text, plan = Playable.text(ModData.parsed, Atmo.currentText())
    local groups = {}
    for _, p in ipairs(plan.objects) do groups[p.group] = true end
    T.ok(groups["sphere|||10|16"], "the bouncy nogrip ball: its own group")
    local file = ATMOPLAY.Format.read(splitLines(text))
    local found = false
    for _, p in ipairs(file.pool) do
        if p.bounce == "10" then
            found = true
            T.eq(p.flag, "24", "static + nogrip on its pool object")
        end
    end
    T.ok(found, "a pool object written with bounce 10")
    local colliders = ATMOPLAY.Colliders.build(file.atmo)
    local pool = ATMOPLAY.Pool.new(file.pool, colliders, file.header)
    T.ok(pool and pool.targets["sphere|||10|16"] and #pool.targets["sphere|||10|16"] == 1,
        "Atmo Play: the ball has its pool object")
end)

T.test("hardness: its own pool group, written on the pool objects, read back by Atmo Play", function()
    smallMod()
    Playable.setPlayable(true)
    for _, obj in ipairs(ModData.parsed.atmo) do
        if obj.props.shape == "sphere" then obj.props.hardness = "2" else obj.props.hardness = "0.000000" end
    end
    local text, plan = Playable.text(ModData.parsed, Atmo.currentText())
    local groups = {}
    for _, p in ipairs(plan.objects) do groups[p.group] = (groups[p.group] or 0) + 1 end
    T.eq(groups["sphere||2"], 1, "the ball's hardness is its own group")
    T.eq(groups["box|10000"], 2, "hardness 0 (the default) changes nothing")
    local file = ATMOPLAY.Format.read(splitLines(text))
    local hard = 0
    for _, p in ipairs(file.pool) do
        if p.hardness then
            hard = hard + 1
            T.eq(p.hardness, "2", "the hardness line on the pool object")
        end
    end
    T.eq(hard, 1, "one pool object with a hardness line")
    local colliders = ATMOPLAY.Colliders.build(file.atmo)
    local pool = ATMOPLAY.Pool.new(file.pool, colliders, file.header)
    T.ok(pool and pool.targets["sphere||2"] and #pool.targets["sphere||2"] == 1, "Atmo Play: the ball has its pool object")
end)

T.test("the split check classifies objects as Atmo Play does (without building colliders)", function()
    smallMod()
    Playable.setPlayable(true)
    local atmo = ModData.parsed.atmo
    -- a few more kinds: a prop, a hardness, a skipped (random) one
    atmo[#atmo + 1] = { kind = "atmo", id = #atmo + 1, props = { shape = "box", pos = "1 2 3", flag = "0" } }
    atmo[#atmo + 1] = { kind = "atmo", id = #atmo + 1, props = { shape = "sphere", pos = "1 2 3", hardness = "2" } }
    atmo[#atmo + 1] = { kind = "atmo", id = #atmo + 1, props = { shape = "box", pos = "1 2 3", rpos = "1 1 1" } }
    local colliders, props = Playable.colliders(atmo) -- the full way: the atmo's text, Colliders.build
    local counts = {}
    for _, c in ipairs(colliders) do counts["s " .. c.group] = (counts["s " .. c.group] or 0) + 1 end
    for _, p in ipairs(props) do counts["p " .. p.group] = (counts["p " .. p.group] or 0) + 1 end
    local parts = {}
    for group, n in pairs(counts) do parts[#parts + 1] = group .. "=" .. n end
    table.sort(parts)
    T.eq(Playable.poolSplitKey(atmo), table.concat(parts, ";"), "the same groups and counts")
end)

T.test("atmo edits reload a playable mod only when its pools no longer fit", function()
    smallMod()
    local applied, savedApply = 0, MGE.apply
    MGE.apply = function()
        applied = applied + 1
        -- what the real apply writes for a playable mod (and records its split with)
        if Playable.isOn() then Playable.workingText(ModData.parsed) end
    end
    local ok, err = pcall(function()
        Playable.setPlayable(true) -- writes the working copy: its pools' key
        applied = 0
        T.ok(Playable.loadedKey ~= nil, "the working copy recorded its split")
        T.eq(Playable.reloadIfSplitChanged(), false, "nothing changed")
        local atmo = ModData.parsed.atmo
        atmo[1].props.pos = "9 9 9"
        atmo[1].props.mass = "5"
        T.eq(Playable.reloadIfSplitChanged(), false, "moved, heavier: the next fight reads it")
        -- a duplicate (as the Atmo list's Duplicate makes it): one more of its group
        atmo[#atmo + 1] = { kind = "atmo", id = #atmo + 1, props = ModData.copy(atmo[1].props), lines = atmo[1].lines }
        T.eq(Playable.reloadIfSplitChanged(), true, "a copy: new pools")
        T.eq(applied, 1, "reloaded once")
        T.eq(Playable.reloadIfSplitChanged(), false, "the reload recorded the new split")
        atmo[1].props.friction = "123"
        T.eq(Playable.reloadIfSplitChanged(), true, "another friction: another group")
        atmo[1].props.bounce = "5"
        T.eq(Playable.reloadIfSplitChanged(), true, "another bounce: another group (written in the mod)")
        Playable.setPlayable(false)
        applied = 0
        atmo[#atmo + 1] = { kind = "atmo", id = #atmo + 1, props = ModData.copy(atmo[1].props), lines = atmo[1].lines }
        T.eq(Playable.reloadIfSplitChanged(), false, "not playable: no pools to fit")
        T.eq(applied, 0, "no reload")
    end)
    MGE.apply = savedApply
    if not ok then error(err) end
end)

T.test("opening a playable mod: pool left out, its ids free, atmo and params from the file", function()
    smallMod()
    Playable.setPlayable(true)
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
    T.ok(not Playable.setPlayable(true), "not made playable")
    T.eq(ModData.parsed.playable, nil, "not playable")
end)

T.test("On: the working copy carries the pool, MGE moves it like Atmo Play; Off is one undo step", function()
    smallMod()
    local names = { "get_world_state", "get_body_info", "BODYPARTS", "set_obj_pos", "set_obj_sides", "set_obj_rot_m",
        "set_obj_flag", "set_obj_bounce", "set_obj_vis", "set_obj_color", "get_obj_bounce" }
    local saved = {}
    for _, name in ipairs(names) do saved[name] = rawget(_G, name) end
    local ok, err = pcall(function()
        local moves = {}
        get_world_state = function() return { match_frame = 0, replay_mode = 0, num_players = 1 } end
        BODYPARTS = { HEAD = 0 }
        get_body_info = function() return { pos = { x = 10, y = 0, z = 1 } } end -- next to the wall
        set_obj_pos = function(id, x, y, z) moves[#moves + 1] = { id = id, x = x } end
        set_obj_sides, set_obj_rot_m, set_obj_flag, set_obj_bounce = function() end, function() end, function() end, function() end
        set_obj_vis, set_obj_color = function() end, function() end
        get_obj_bounce = function() return 0.5 end
        T.ok(not Playable.isOn(), "off at first")
        T.ok(Playable.setPlayable(true), "on")
        local text = Playable.workingText(ModData.parsed)
        local split = Playable.split(splitLines(text))
        T.ok(split.header ~= nil, "the working copy has the header (the reload frees the pool's ids)")
        T.eq(#split.pool, 3, "and the pool")
        T.eq(#split.poolObjects, 3, "with shapes for the driver")
        T.eq(#split.atmo, 1, "but not the atmo (one empty #@ line): MGE draws it")
        -- the reload of that working copy: the driver takes the pool the file has
        ModData.loadedPlayable = split
        Playable.onMatchBegin()
        T.eq(#moves, 0, "nothing moved at match_begin (frame 0: Driver.FIRST_FRAME)")
        get_world_state = function() return { match_frame = 1, replay_mode = 0, num_players = 1 } end
        Playable.draw()
        local placed = false
        for _, m in ipairs(moves) do
            if math.abs(m.x - 10) < 1e-9 then placed = true end
        end
        T.ok(placed, "the wall's pool object placed on the fight's first frame")
        local steps = #MGE.History.states
        T.ok(Playable.setPlayable(false), "off")
        T.ok(not Playable.isOn(), "not playable")
        T.eq(#MGE.History.states, steps + 1, "one undo step")
        T.eq(#ModData.parsed.atmo, 4, "the atmo's own objects stay in the atmo")
        T.eq(#ModData.parsed.env_obj, 4, "the object Playable moved is an object again")
        local back
        for _, obj in ipairs(ModData.parsed.env_obj) do if obj.props.friction == "10000" then back = obj end end
        T.ok(back ~= nil and back.kind == "env_obj", "the converted one")
        T.eq(back and back.id, 60, "on its old id")
        T.eq(back and back.props[MGE.AtmoLayer.FROM_KEY], nil, "without Playable's mark")
        MGE.History.undo()
        T.ok(Playable.isOn(), "undo: playable again")
        T.eq(#ModData.parsed.atmo, 5, "undo: back in the atmo")
        ModData.loadedPlayable = nil
    end)
    for _, name in ipairs(names) do rawset(_G, name, saved[name]) end
    if not ok then error(err) end
end)

T.test("props (dynamic atmo objects): a dynamic pool on free ids 1-48 and a parking platform", function()
    smallMod()
    Playable.setPlayable(true)
    -- the dynamic object 2 has a joint: unlink it, then To atmo makes it a prop (its flag 0 goes along)
    ModData.parsed.env_obj_joint = {}
    ModData.refreshJointIds()
    for _, obj in ipairs(ModData.parsed.env_obj) do obj.selected = obj.id == 2 or nil end
    MGE.AtmoLayer.moveIn()
    local colliders, props = Playable.colliders(ModData.parsed.atmo)
    T.eq(#props, 1, "one prop")
    T.eq(#colliders, 3, "the static colliders unchanged")
    local text, plan = Playable.text(ModData.parsed, Atmo.currentText())
    T.eq(plan.props, 1, "plan counts the prop")
    T.eq(#plan.dynamic, 1, "one dynamic pool object (no more than props)")
    T.eq(plan.dynamic[1].id, 1, "on the first free id up to 48")
    T.eq(plan.park, MGE.MAX_NONSTATIC_OBJECTS + 1, "the platform on the first free static id")
    T.eq(plan.objects[1].id, MGE.MAX_NONSTATIC_OBJECTS + 2, "the static pool after it")
    local file = MGE.AtmoPlay.Format.read(splitLines(text))
    T.eq(#file.dynamic, 1, "Atmo Play reads the dynamic pool")
    T.eq(file.park, plan.park, "and the platform")
    T.eq(#file.pool, #plan.objects, "and the static pool")
    local split = Playable.split(splitLines(text))
    local parsed = FileHandler.parseLines(split.lines)
    local ids = {}
    for _, obj in ipairs(parsed.env_obj) do ids[#ids + 1] = obj.id end
    T.eq(table.concat(ids, ","), "61,62", "MGE's data: the real objects only")
    -- the dynamic pool object's lines: dynamic, on the platform, faint by its alpha but "visible 1" (the game
    -- shows move predictions only for visible objects)
    local block = text:match("env_obj 1\n(.-)\n\n") or text:match("env_obj 1\n(.-)env_obj")
    T.ok(block and block:match("flag 0"), "dynamic")
    local alpha = MGE.AtmoPlay.Dynamics.POOL_ALPHA
    T.ok(alpha > 0 and alpha < 1, "faint, not see-through")
    T.ok(block and block:find("color 1 1 1 " .. alpha, 1, true) and not block:match("visible 0"), "faint, not hidden")
    -- written at the prop's own size and mass, parked on the platform at that size: taking it resizes nothing
    local object, prop = file.dynamic[1], props[1]
    local s = {}
    for n in object.sides:gmatch("%S+") do s[#s + 1] = tonumber(n) end
    T.near(s[1], prop.sides[1], 1e-6, "the prop's size")
    T.eq(tonumber(object.mass), prop.mass, "the prop's mass line, as the prop has one or not")
    local spot = {}
    for n in object.pos:gmatch("%S+") do spot[#spot + 1] = tonumber(n) end
    local top = MGE.AtmoPlay.Dynamics.PARK_Z + MGE.AtmoPlay.Dynamics.PLATFORM_SIDES[3] / 2
    T.near(spot[3], top + prop.sides[3] / 2 + 0.01, 1e-6, "resting on the platform at its height")
    local dyn = MGE.AtmoPlay.Dynamics.new(file.dynamic, props, {})
    T.near(dyn.entries[1].home.pos[3], spot[3], 1e-6, "Atmo Play parks it there")
    T.near(dyn.entries[1].sides[1], prop.sides[1], 1e-6, "and knows its size")
end)

T.test("dynamic pool looks: each group's most common prop; the parking layout fits them", function()
    local Dynamics = MGE.AtmoPlay.Dynamics
    local props = {
        { group = "box|", sides = { 1, 1, 1 }, mass = 2 },
        { group = "box|", sides = { 1, 1, 1 }, mass = 2 },
        { group = "box|", sides = { 3, 1, 1 } },
        { group = "sphere|", sides = { 0.5, 0, 0 }, bounce = 0.4 },
    }
    local looks = Playable.propLooks(props)
    T.eq(looks["box|"].sides[1], 1, "the common box size")
    T.eq(looks["box|"].mass, 2, "with its mass")
    T.eq(looks["sphere|"].bounce, 0.4, "the sphere's bounce")
    local spots, platform = Dynamics.parkLayout({
        { id = 1, shape = "box", sides = { 1, 1, 1 } },
        { id = 2, shape = "box", sides = { 6, 6, 6 } },
        { id = 3, shape = "sphere", sides = { 0.5, 0, 0 } },
    })
    local r2 = math.sqrt(108) / 2
    T.ok(spots[2][1] - spots[1][1] >= math.sqrt(3) / 2 + r2, "neighbours apart by their sizes")
    T.ok(spots[3][1] - spots[2][1] >= r2 + 0.5, "the sphere after the big box")
    T.ok(platform.sides[1] / 2 >= spots[3][1] + 0.5 and -platform.sides[1] / 2 <= spots[1][1] - 0.5, "all on the platform")
    T.ok(platform.sides[2] >= 2 * r2, "wide enough for the big box")
    local top = Dynamics.PARK_Z + Dynamics.PLATFORM_SIDES[3] / 2
    T.near(spots[3][3], top + 0.5 + 0.01, 1e-9, "the sphere rests on it")
end)

T.test("a prop that never becomes real (prop_real 0) gets no dynamic pool object; the split check sees it", function()
    smallMod()
    Playable.setPlayable(true)
    ModData.parsed.env_obj_joint = {}
    ModData.refreshJointIds()
    for _, obj in ipairs(ModData.parsed.env_obj) do obj.selected = obj.id == 2 or nil end
    MGE.AtmoLayer.moveIn()
    local before = Playable.poolSplitKey(ModData.parsed.atmo)
    for _, obj in ipairs(ModData.parsed.atmo) do
        if obj.props.flag == "0" then obj.props.prop_real = "0" end
    end
    T.ok(Playable.poolSplitKey(ModData.parsed.atmo) ~= before, "the split changed: the working copy reloads")
    local _, props = Playable.colliders(ModData.parsed.atmo)
    T.eq(#props, 1, "still a prop (it flies drawn)")
    T.eq(props[1].noReal, true, "that never becomes real")
    local _, plan = Playable.text(ModData.parsed, Atmo.currentText())
    T.eq(#plan.dynamic, 0, "no dynamic pool object for it")
end)

T.test("the pool plan is reused while the atmo and free ids stay, made again when either changes", function()
    smallMod()
    Playable.setPlayable(true)
    local colliders, props = Playable.colliders(ModData.parsed.atmo)
    local plan = Playable.poolPlan(ModData.parsed, colliders, props)
    T.eq(Playable.poolPlan(ModData.parsed, colliders, props), plan, "nothing changed: the same plan")
    ModData.parsed.env_obj[#ModData.parsed.env_obj + 1] = { kind = "env_obj", id = 200, props = { shape = "box" },
        lines = {} }
    local fewer = Playable.poolPlan(ModData.parsed, colliders, props)
    T.ok(fewer ~= plan and fewer.freeIds == plan.freeIds - 1, "an id taken: planned again")
    ModData.parsed.atmo[1].props.pos = "50 50 50"
    local moved, movedProps = Playable.colliders(ModData.parsed.atmo)
    T.ok(moved ~= colliders, "an atmo line edited: colliders built again")
    T.ok(Playable.poolPlan(ModData.parsed, moved, movedProps) ~= fewer, "and planned again")
end)
