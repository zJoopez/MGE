-- Playable atmo mods: a big atmo made solid in game by the Atmo Play script (../atmoplay.lua, next to
-- mge/; docs/atmo-play-plan.md). MGE makes them, Atmo Play plays them, with the same code: the format,
-- which atmo objects are solid, how the pool is split and how it's moved come from Atmo Play's own modules
-- (MGE.AtmoPlay: format.lua, colliders.lua, pool.lua, driver.lua). A playable mod is an ordinary .tbm with:
--   * a note line first (what the file needs), then the mod's own lines and its real objects
--   * the pool: hidden static env_obj blocks on every free static id, marked with Format.POOL_MARKER. Atmo
--     Play moves them onto the atmo objects nearest the players, every frame of a fight
--   * a header line ("#atmoplay v1 rule=1 radius=4"), then the atmo: every line of the atmo file behind
--     "#@ ". The game skips "#" lines, so neither its mod loader nor its atmo loader sees them
--
-- One switch (the Atmo list's Advanced tab: Playable, On / Off) decides everything:
--   On:  the mod's static objects move into the atmo (MGE's To atmo: ids freed, one undo step; dynamic,
--        joint-linked and model objects stay), Save writes the playable form, and the editor plays it: the
--        working copy (MGE.apply) carries the pool and MGE moves it in fights like Atmo Play does
--   Off: an ordinary mod again (its atmo back in MGE - <mod>.atmo on the next save, its atmo objects stay)
-- Opening a playable mod reads its atmo into the Atmo list (from the "#@ " lines, not MGE - <mod>.atmo); the
-- pool isn't in the data: it's made again from the free ids on every save and working copy.
-- Props (proof of concept, Atmo Play's dynamics.lua): atmo objects with a flag line lacking the static bit
-- (make objects dynamic, then To atmo) are pushable in Atmo Play. The file then also gets a dynamic pool on
-- the free ids 1-48 and a hidden parking platform; MGE's own test fights don't move them (props aren't solid
-- in the editor).
local ModData = MGE.ModData
local FileHandler = MGE.FileHandler
local AtmoLayer = MGE.AtmoLayer
local History = MGE.History
local Format = MGE.AtmoPlay.Format
local Colliders = MGE.AtmoPlay.Colliders
local Pool = MGE.AtmoPlay.Pool
local Driver = MGE.AtmoPlay.Driver
local Dynamics = MGE.AtmoPlay.Dynamics

---@class PlayableParams
---@field rule integer pool rule (Atmo Play's pool.lua)
---@field radius number pool reach from a player's center
---@field dradius number? props' reach (Atmo Play's dynamics.lua), its default without one

---@class Playable
local Playable = {
    DEFAULT_RULE = Pool.DEFAULT_RULE,
    DEFAULT_RADIUS = Pool.DEFAULT_RADIUS,
    NOTE = Format.NOTE,
    PARK_Z = -100000,
    STATIC_FLAG = 8,
}

---A mod file's lines in parts (Atmo Play's Format.split): `lines` is the mod MGE parses, without the
---pool blocks and Atmo Play's lines; `header` is nil for an ordinary mod. `poolObjects` and
---`dynamicObjects` (Format.read's): the pools the file has, what the world has after /lm
---@param lines string[]
---@return AtmoPlaySplit|{ poolObjects: AtmoPlayPoolObject[]?, dynamicObjects: AtmoPlayPoolObject[]? }
function Playable.split(lines)
    local split = Format.split(lines)
    if split.header then
        local file = Format.read(lines)
        split.poolObjects, split.dynamicObjects = file.pool, file.dynamic
    end
    return split
end

---@return boolean the data is a playable mod (Playable On, the Atmo list's Advanced tab)
function Playable.isOn()
    return ModData.parsed.playable ~= nil
end

---The mod's objects On moves into the atmo: static, not linked by a joint, not a model
---@param obj FileParserEnvObj
---@return boolean
function Playable.convertible(obj)
    if not ModData.isStatic(obj, true) or ModData.jointIds[obj.id] then return false end
    if obj.props.use_model == "1" then return false end
    return not tostring(obj.props.shape or ""):match("^%s*custom")
end

-- the last colliders made, by the atmo text they came from: reloads with an unchanged atmo (most edits are
-- to objects) don't build them again (~0.1 s on a 5k-object atmo)
local colliderCache = { text = nil, colliders = nil, props = nil }

---The atmo's solid objects exactly as Atmo Play will see them: its colliders.lua on the atmo's text
---@param atmo FileParserEnvObj[] the atmo layer
---@return AtmoPlayCollider[] colliders the static ones
---@return AtmoPlayCollider[] props the dynamic ones (pushable in Atmo Play)
function Playable.colliders(atmo)
    local text = MGE.Atmo.text({ objects = atmo or {} })
    if colliderCache.text == text then return colliderCache.colliders, colliderCache.props end
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local colliders, _, props = Colliders.build(lines)
    colliderCache.text, colliderCache.colliders, colliderCache.props = text, colliders, props
    return colliders, props
end

---@class PlayablePlan
---@field objects { id: integer, group: string }[] the pool, by id
---@field groups { group: string, colliders: integer, peak: integer, pool: integer }[]
---@field freeIds integer static ids the mod doesn't use
---@field solid integer solid atmo objects
---@field atmo integer all atmo objects
---@field props integer pushable atmo objects (dynamic flag)
---@field dynamic { id: integer, group: string }[] the props' pool (ids 1-48), by id
---@field park integer? the parking platform's id (with props and a dynamic pool)

---The pool a save would write for this data: every free static id (above MAX_NONSTATIC_OBJECTS), split
---by Atmo Play's Pool.plan, no more than solid objects. With props: the free ids up to MAX_NONSTATIC_OBJECTS
---are their pool, and the first free static id their parking platform
---@param parsed FileParserResult
---@param colliders AtmoPlayCollider[]? Playable.colliders(parsed.atmo), made when not given
---@param props AtmoPlayCollider[]? its second result
---@return PlayablePlan
function Playable.poolPlan(parsed, colliders, props)
    local params = parsed.playable or {}
    local used = {}
    for _, obj in ipairs(parsed.env_obj or {}) do used[obj.id] = true end
    local free, freeDynamic = {}, {}
    for id = MGE.MAX_NONSTATIC_OBJECTS + 1, MGE.MAX_ENV_OBJECTS do
        if not used[id] then free[#free + 1] = id end
    end
    for id = 1, MGE.MAX_NONSTATIC_OBJECTS do
        if not used[id] then freeDynamic[#freeDynamic + 1] = id end
    end
    if not colliders then colliders, props = Playable.colliders(parsed.atmo) end
    props = props or {}
    local dynamic, park = {}, nil
    if #props > 0 and #freeDynamic > 0 and #free > 0 then
        park = table.remove(free, 1)
        dynamic = Pool.plan(props, freeDynamic, tonumber(params.dradius) or Dynamics.DEFAULT_RADIUS).objects
    end
    local plan = Pool.plan(colliders, free, tonumber(params.radius) or Playable.DEFAULT_RADIUS)
    return { objects = plan.objects, groups = plan.groups, freeIds = #free, solid = #colliders,
        atmo = #(parsed.atmo or {}), props = #props, dynamic = dynamic, park = park }
end

---A pool object as MGE's file writer writes objects: hidden, static, parked far below the map
---@param id integer
---@param group string "shape|friction"
---@return FileParserEnvObj
local function poolObject(id, group)
    local shape, friction = group:match("^([^|]*)|(.*)$")
    local obj = {
        kind = "env_obj",
        id = id,
        props = {
            shape = shape,
            pos = id .. " 0 " .. Playable.PARK_Z,
            rot = "0 0 0",
            sides = "1 1 1",
            color = "1 1 1 1",
            flag = tostring(Playable.STATIC_FLAG),
            visible = "0",
        },
        lines = { { raw = Format.POOL_MARKER } },
    }
    for _, key in ipairs({ "shape", "pos", "rot", "sides", "color", "flag" }) do obj.lines[#obj.lines + 1] = { key = key } end
    if friction ~= "" then
        obj.props.friction = friction
        obj.lines[#obj.lines + 1] = { key = "friction" }
    end
    obj.lines[#obj.lines + 1] = { key = "visible" }
    return obj
end

---A prop pool object (Atmo Play's dynamics.lua): hidden, dynamic, resting on the parking platform
---@param id integer 1-48
---@param group string "shape|friction"
---@return FileParserEnvObj
local function dynamicObject(id, group)
    local shape, friction = group:match("^([^|]*)|(.*)$")
    local x, y, z = Dynamics.parkPos(id)
    local side = FileHandler.formatNumbers(Dynamics.PARK_SIDE, Dynamics.PARK_SIDE, Dynamics.PARK_SIDE)
    local obj = {
        kind = "env_obj",
        id = id,
        props = { shape = shape, pos = FileHandler.formatNumbers(x, y, z), rot = "0 0 0", sides = side,
            color = "1 1 1 1", flag = "0", visible = "0" },
        lines = { { raw = Format.DYNAMIC_MARKER } },
    }
    for _, key in ipairs({ "shape", "pos", "rot", "sides", "color", "flag" }) do obj.lines[#obj.lines + 1] = { key = key } end
    if friction ~= "" then
        obj.props.friction = friction
        obj.lines[#obj.lines + 1] = { key = "friction" }
    end
    obj.lines[#obj.lines + 1] = { key = "visible" }
    return obj
end

---The props' parking platform: hidden, static, far below the map
---@param id integer
---@return FileParserEnvObj
local function parkObject(id)
    local s = Dynamics.PLATFORM_SIDES
    local obj = {
        kind = "env_obj",
        id = id,
        props = { shape = "box", pos = FileHandler.formatNumbers(0, 0, Dynamics.PARK_Z), rot = "0 0 0",
            sides = FileHandler.formatNumbers(s[1], s[2], s[3]), color = "1 1 1 1",
            flag = tostring(Playable.STATIC_FLAG), visible = "0" },
        lines = { { raw = Format.PARK_MARKER } },
    }
    for _, key in ipairs({ "shape", "pos", "rot", "sides", "color", "flag", "visible" }) do
        obj.lines[#obj.lines + 1] = { key = key }
    end
    return obj
end

---The playable mod's text: the note, the mod with its pool (MGE's own writer), the header, the atmo
---@param parsed FileParserResult with .playable set
---@param atmoText string the atmo as its file would hold it (Atmo.text)
---@param colliders AtmoPlayCollider[]? Playable.colliders(parsed.atmo), made when not given
---@param props AtmoPlayCollider[]? its second result
---@return string text, PlayablePlan plan
function Playable.text(parsed, atmoText, colliders, props)
    local plan = Playable.poolPlan(parsed, colliders, props)
    local copy = {}
    for k, v in pairs(parsed) do copy[k] = v end
    copy.env_obj = {}
    for _, obj in ipairs(parsed.env_obj or {}) do copy.env_obj[#copy.env_obj + 1] = obj end
    for _, p in ipairs(plan.objects) do copy.env_obj[#copy.env_obj + 1] = poolObject(p.id, p.group) end
    for _, p in ipairs(plan.dynamic) do copy.env_obj[#copy.env_obj + 1] = dynamicObject(p.id, p.group) end
    if plan.park and #plan.dynamic > 0 then copy.env_obj[#copy.env_obj + 1] = parkObject(plan.park) end
    table.sort(copy.env_obj, function(a, b) return a.id < b.id end)
    local out = { Format.NOTE, FileHandler.modText(copy), "", Format.headerLine(parsed.playable) }
    for line in (atmoText .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line == "" and "#@" or (Format.ATMO_PREFIX .. line)
    end
    return table.concat(out, "\n"), plan
end

---The working copy of a playable mod (MGE.apply): the mod with its pool and the header, no atmo lines (MGE
---draws the atmo itself; the header makes the reload leave the pool out of the data and free its ids)
---@param parsed FileParserResult
---@return string
function Playable.workingText(parsed)
    return (Playable.text(parsed, "", Playable.colliders(parsed.atmo))) -- both results: colliders, props
end

---------------------------------------------------------------------------------------------------- the switch

local function refreshRow()
    if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "playable" }) end
end

---Playable On: the mod's convertible static objects into the atmo (To atmo: one undo step, the working copy
---reloads with its pool) and the mod marked playable
---@return boolean on
local function turnOn()
    ModData.refreshJointIds()
    local count = 0
    for _, obj in ipairs(ModData.parsed.env_obj) do
        obj.selected = Playable.convertible(obj) or nil
        if obj.selected then count = count + 1 end
    end
    for _, obj in ipairs(ModData.parsed.atmo or {}) do obj.selected = nil end
    local colliders, props = Playable.colliders(ModData.parsed.atmo)
    if count == 0 and #colliders == 0 and #props == 0 then
        MGE.say("nothing to make solid: no static objects and no solid atmo objects (boxes, spheres, capsules)")
        return false
    end
    -- set before the step To atmo commits, so undo takes it back with the moved objects
    ModData.parsed.playable = { rule = Playable.DEFAULT_RULE, radius = Playable.DEFAULT_RADIUS }
    if count > 0 then
        AtmoLayer.moveIn() -- History.commit, MGE.apply (with the pool now)
    else
        History.commit()
        MGE.apply()
    end
    local plan = Playable.poolPlan(ModData.parsed)
    MGE.say(string.format("playable: %d solid atmo objects, %d pool objects%s. Fights here are solid; Save writes it",
        plan.solid, #plan.objects, count > 0 and (", " .. count .. " objects moved to the atmo") or ""))
    if plan.props > 0 then
        MGE.say(string.format("%d props (dynamic atmo objects), %d dynamic pool objects: pushable in Atmo Play, " ..
            "not in MGE's own fights (proof of concept)", plan.props, #plan.dynamic))
    end
    return true
end

---The World tab's Playable switch. On: a playable mod (see the header), tested in the editor. Off: an
---ordinary mod again; its atmo objects stay in the atmo. Each is one undo step
---@param on boolean
---@return boolean changed
function Playable.setPlayable(on)
    local changed = false
    if on and not Playable.isOn() then
        changed = turnOn()
    elseif not on and Playable.isOn() then
        ModData.parsed.playable = nil
        History.commit()
        MGE.apply() -- the working copy without its pool
        MGE.say("not playable: Save writes an ordinary mod and its atmo file again")
        changed = true
    end
    refreshRow()
    return changed
end

---------------------------------------------------------------------------------------------------- playing in the editor

local PLAY_HOOKS = MGE.hookname .. "_playable"
---@type AtmoPlayDriver?
local driver = nil
---@type table? the props in fights (Atmo Play's dynamics.lua), nil without props
local dynamics = nil
---@type number? the player's replaycache while props have it off (cached replays misplace them, as in Atmo Play)
local cacheBefore = nil

local function setReplayCache(withProps)
    if withProps and cacheBefore == nil then
        local ok, value = pcall(get_option, "replaycache")
        if ok and tonumber(value) and tonumber(value) ~= 0 then
            cacheBefore = tonumber(value)
            set_option("replaycache", 0)
            MGE.say("replay cache off while the mod has props (cached replays misplace them); set back after")
        end
    elseif not withProps and cacheBefore ~= nil then
        pcall(set_option, "replaycache", cacheBefore)
        cacheBefore = nil
    end
end

---Runs a dynamics.lua call; an error stops the props (proof of concept), not the static pool
local function runDynamics(fn, ws)
    if not dynamics then return end
    local ok, err = pcall(fn, dynamics, ws)
    if not ok then
        dynamics = nil
        if driver then driver.moreCenters = nil end
        MGE.say("playable: props stopped: " .. tostring(err))
    end
end

---After every reload (main.lua's match_begin, inside /lm): for a playable mod, a driver for the pool that's
---in the world now (the loaded file's own pool: MGE's working copy or the opened mod), placed for this fight.
---It also follows the mod's own dynamic objects, and with props their pool moves too (drawn by MGE:
---Playable.movedGhost)
function Playable.onMatchBegin()
    driver, dynamics = nil, nil
    if not Playable.isOn() then
        setReplayCache(false)
        return
    end
    local loaded = ModData.loadedPlayable
    if not (loaded and loaded.poolObjects) then return end -- the world has no pool (e.g. an old working copy)
    local colliders, props = Playable.colliders(ModData.parsed.atmo)
    local pool, err = Pool.new(loaded.poolObjects, colliders, ModData.parsed.playable)
    if not pool then
        MGE.say("playable: " .. tostring(err))
        return
    end
    driver = Driver.new(pool)
    local skip = {}
    for _, object in ipairs(loaded.dynamicObjects or {}) do skip[object.id] = true end
    driver.follow = Driver.dynamicIds(skip)
    if loaded.dynamicObjects and #loaded.dynamicObjects > 0 and #props > 0 then
        local params = { dradius = ModData.parsed.playable.dradius, noCopies = true }
        dynamics = Dynamics.new(loaded.dynamicObjects, props, params)
        local d = dynamics
        driver.moreCenters = function() return Dynamics.centers(d) end
    end
    setReplayCache(dynamics ~= nil)
    local ws = get_world_state()
    runDynamics(Dynamics.matchBegin, ws) -- first: the static pool covers the props it takes
    Driver.matchBegin(driver, ws)
end

---A prop's ghost where the prop is now (fights in the editor), else the ghost as it is
---@param index integer the atmo object's place in the Atmo list
---@param g AtmoGhost
---@return AtmoGhost
function Playable.movedGhost(index, g)
    if not dynamics then return g end
    local moved = Dynamics.movedProp(dynamics, index)
    if not moved then return g end
    local cached = moved.ghost
    if not cached or cached.from ~= g then
        cached = {}
        for k, v in pairs(g) do cached[k] = v end
        cached.pos, cached.frame, cached.from = moved.pos, moved.frame, g
        moved.ghost = cached
    end
    return cached
end

-- between physics steps: the pools follow the players once per new match frame (driver.lua, dynamics.lua)
remove_hooks(PLAY_HOOKS)
add_hook("draw2d", PLAY_HOOKS, function()
    if not driver then return end
    local ws = get_world_state()
    runDynamics(Dynamics.draw, ws)
    local ok, err = pcall(Driver.draw, driver, ws)
    if not ok then
        driver, dynamics = nil, nil
        MGE.say("playable: the pool stopped moving: " .. tostring(err))
    end
end)
table.insert(MGE.onQuit, function()
    remove_hooks(PLAY_HOOKS)
    driver, dynamics = nil, nil
    setReplayCache(false)
end)

MGE.Playable = Playable
return Playable
