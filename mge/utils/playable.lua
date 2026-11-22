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
--   Off: an ordinary mod again (Save keeps its atmo inside the mod, Atmo.bundledText; World > Export writes
--        separate copies), its atmo objects stay
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

---@return boolean the data is a playable mod (World > Atmo: Playable)
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

---What a playable mod's pools are split by: how many solid atmo objects and props of each group
---(Colliders.groupKey) there are. Where they are doesn't change it: every fight reads the atmo again
---(Playable.onMatchBegin), so moves and colors need no reload (a changed bounce, flag or mass is another group)
---@param atmo FileParserEnvObj[]?
---@return string
function Playable.poolSplitKey(atmo)
    -- from the objects' lines alone (Colliders.classify, as Atmo Play classifies them): building the colliders
    -- for it took ~170 ms on a 5k atmo after every atmo edit or undo, to find out that a move changed nothing
    local counts = {}
    for _, obj in ipairs(atmo or {}) do
        local reason, _, group, prop = Colliders.classify(obj.props)
        if not reason then
            local key = (prop and "p " or "s ") .. group
            counts[key] = (counts[key] or 0) + 1
        end
    end
    local parts = {}
    for group, n in pairs(counts) do parts[#parts + 1] = group .. "=" .. n end
    table.sort(parts)
    return table.concat(parts, ";")
end

---@type string? Playable.poolSplitKey of the loaded pools: set by the working copy as it's written, or by the
---first fight of an opened mod (its pools were planned for its atmo); nil: not known yet
Playable.loadedKey = nil

---After atmo objects changed (committed): on a playable mod whose pools no longer fit its atmo (objects added
---or removed, a group or Static changed) the working copy is written and reloaded with new pools, so the
---editor's fights have them (a duplicated prop got no dynamic object until Save before). Everything else
---waits for the next fight
---@return boolean reloaded the caller's refresh is done by the reload
function Playable.reloadIfSplitChanged()
    if not Playable.isOn() or Playable.loadedKey == nil then return false end
    if Playable.poolSplitKey(ModData.parsed.atmo) == Playable.loadedKey then return false end
    MGE.apply()
    return true
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

---A pool object's lines in the writer's order: the given keys, then the group's friction, hardness, bounce and
---mass (what the object can't change once loaded: Colliders.groupKey), then visible
---@param obj FileParserEnvObj
---@param keys string[]
---@param group string
---@return FileParserEnvObj obj
local function withLines(obj, keys, group)
    -- bounce and flag bits too: set live, replays don't record them (docs/atmo-play-plan.md, R2), so the
    -- group's values are written; the flag bits join the object's own flag (static or not)
    local _, friction, hardness, bounce, flagBits, mass = Colliders.splitGroup(group)
    if flagBits ~= "" then obj.props.flag = tostring((tonumber(obj.props.flag) or 0) + tonumber(flagBits)) end
    for _, key in ipairs(keys) do obj.lines[#obj.lines + 1] = { key = key } end
    for _, line in ipairs({ { "friction", friction }, { "hardness", hardness }, { "bounce", bounce }, { "mass", mass } }) do
        local key, value = line[1], line[2]
        if value ~= "" then
            local listed = obj.props[key] ~= nil -- the dynamic pool's look may have written it already
            obj.props[key] = value
            if not listed then obj.lines[#obj.lines + 1] = { key = key } end
        end
    end
    obj.lines[#obj.lines + 1] = { key = "visible" }
    return obj
end

local POOL_KEYS = { "shape", "pos", "rot", "sides", "color", "flag" }

---A pool object as MGE's file writer writes objects: hidden, static, parked far below the map (Driver.PARK_Z)
---@param id integer
---@param group string Colliders.groupKey
---@return FileParserEnvObj
local function poolObject(id, group)
    local shape = Colliders.splitGroup(group)
    return withLines({
        kind = "env_obj",
        id = id,
        props = {
            shape = shape,
            pos = id .. " 0 " .. Driver.PARK_Z,
            rot = "0 0 0",
            sides = "1 1 1",
            color = "1 1 1 1",
            flag = tostring(Colliders.STATIC_FLAG),
            visible = "0",
        },
        lines = { { raw = Format.POOL_MARKER } },
    }, POOL_KEYS, group)
end

---Each dynamic pool group's most common prop size, mass and bounce (ties: the first in atmo order): its pool
---objects are written at that size, so taking those props resizes nothing (Atmo Play's fitObject)
---@param props AtmoPlayCollider[]?
---@return table<string, { sides: number[], mass: number?, bounce: number? }> by group
function Playable.propLooks(props)
    local counts, looks, best = {}, {}, {}
    for _, p in ipairs(props or {}) do
        local key = string.format("%.6g %.6g %.6g|%s|%s", p.sides[1], p.sides[2], p.sides[3], tostring(p.mass),
            tostring(p.bounce))
        counts[p.group] = counts[p.group] or {}
        local n = (counts[p.group][key] or 0) + 1
        counts[p.group][key] = n
        if not best[p.group] or n > best[p.group] then
            best[p.group] = n
            looks[p.group] = { sides = p.sides, mass = p.mass, bounce = p.bounce }
        end
    end
    return looks
end

---A prop pool object (Atmo Play's dynamics.lua): dynamic, resting on the parking platform. Faint by its
---color's alpha (Dynamics.POOL_ALPHA), not "visible 0": the game shows no move predictions (ghost) for a
---hidden object, and a carried prop should have them like the mod's own dynamic objects. Not alpha 0: the
---ghost may take the object's alpha
---@param id integer 1-48
---@param group string Colliders.groupKey
---@param look { sides: number[], mass: number?, bounce: number? }? the group's common prop (Playable.propLooks)
---@param pos number[]? its parking spot (Dynamics.parkLayout), Dynamics.parkPos without one
---@return FileParserEnvObj
local function dynamicObject(id, group, look, pos)
    local shape = Colliders.splitGroup(group)
    pos = pos or { Dynamics.parkPos(id) }
    local s = look and look.sides or { Dynamics.PARK_SIDE, Dynamics.PARK_SIDE, Dynamics.PARK_SIDE }
    local obj = {
        kind = "env_obj",
        id = id,
        props = { shape = shape, pos = FileHandler.formatNumbers(pos[1], pos[2], pos[3]), rot = "0 0 0",
            sides = FileHandler.formatNumbers(s[1], s[2], s[3]), color = "1 1 1 " .. Dynamics.POOL_ALPHA, flag = "0",
            visible = "1" },
        lines = { { raw = Format.DYNAMIC_MARKER } },
    }
    local keys = { unpack(POOL_KEYS) }
    if look and look.mass then
        obj.props.mass = FileHandler.formatNumbers(look.mass)
        keys[#keys + 1] = "mass"
    end
    if look and look.bounce then
        obj.props.bounce = FileHandler.formatNumbers(look.bounce)
        keys[#keys + 1] = "bounce"
    end
    return withLines(obj, keys, group)
end

---The props' parking platform: hidden, static, high above the map (Dynamics.PARK_Z)
---@param id integer
---@param platform { pos: number[], sides: number[] }? Dynamics.parkLayout's, the old fixed one without
---@return FileParserEnvObj
local function parkObject(id, platform)
    local s = platform and platform.sides or Dynamics.PLATFORM_SIDES
    local obj = {
        kind = "env_obj",
        id = id,
        props = { shape = "box", pos = FileHandler.formatNumbers(0, 0, Dynamics.PARK_Z), rot = "0 0 0",
            sides = FileHandler.formatNumbers(s[1], s[2], s[3]), color = "1 1 1 1",
            flag = tostring(Colliders.STATIC_FLAG), visible = "0" },
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
    if not colliders then colliders, props = Playable.colliders(parsed.atmo) end
    local plan = Playable.poolPlan(parsed, colliders, props)
    local copy = {}
    for k, v in pairs(parsed) do copy[k] = v end
    copy.env_obj = {}
    for _, obj in ipairs(parsed.env_obj or {}) do copy.env_obj[#copy.env_obj + 1] = obj end
    for _, p in ipairs(plan.objects) do copy.env_obj[#copy.env_obj + 1] = poolObject(p.id, p.group) end
    -- the dynamic pool at its groups' common prop look, parked side by side at that size
    local looks, laid = Playable.propLooks(props), {}
    for _, p in ipairs(plan.dynamic) do
        local look = looks[p.group]
        laid[#laid + 1] = { id = p.id, shape = (Colliders.splitGroup(p.group)),
            sides = look and look.sides or { Dynamics.PARK_SIDE, Dynamics.PARK_SIDE, Dynamics.PARK_SIDE } }
    end
    local spots, platform = Dynamics.parkLayout(laid)
    for _, p in ipairs(plan.dynamic) do
        copy.env_obj[#copy.env_obj + 1] = dynamicObject(p.id, p.group, looks[p.group], spots[p.id])
    end
    if plan.park and #plan.dynamic > 0 then copy.env_obj[#copy.env_obj + 1] = parkObject(plan.park, platform) end
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
    Playable.loadedKey = Playable.poolSplitKey(parsed.atmo) -- what the reload's pools are planned for
    return (Playable.text(parsed, "", Playable.colliders(parsed.atmo))) -- both results: colliders, props
end

---------------------------------------------------------------------------------------------------- the switch

local function refreshRow()
    if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "playable" }) end
end

---Atmo: Playable: the mod's convertible static objects into the atmo (To atmo: one undo step, the working copy
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
        MGE.say("nothing to make solid (no static objects or solid atmo shapes)")
        return false
    end
    -- set before the step To atmo commits, so undo takes it back with the moved objects
    ModData.parsed.playable = { rule = Playable.DEFAULT_RULE, radius = Playable.DEFAULT_RADIUS }
    if count > 0 then
        AtmoLayer.moveIn(true) -- marked for Default; History.commit, MGE.apply (with the pool now)
    else
        History.commit()
        MGE.apply()
    end
    local plan = Playable.poolPlan(ModData.parsed)
    MGE.say(string.format("playable: %d solid, %d pool objects%s",
        plan.solid, #plan.objects, count > 0 and (", " .. count .. " moved to the atmo") or ""))
    if plan.props > 0 then
        MGE.say(string.format("%d props (pushable), %d dynamic pool objects", plan.props, #plan.dynamic))
    end
    return true
end

---Default: the mod isn't playable, and the objects Playable moved into the atmo (AtmoLayer.FROM_KEY) are objects
---again, as many as there are free ids (the rest stay in the atmo, said so). One undo step
local function turnOff()
    local marked = {}
    for _, obj in ipairs(ModData.parsed.atmo or {}) do
        obj.selected = nil
        if obj.props[AtmoLayer.FROM_KEY] then marked[#marked + 1] = obj end
    end
    for _, obj in ipairs(ModData.parsed.env_obj) do obj.selected = nil end
    ModData.parsed.playable = nil
    local back = AtmoLayer.returnObjects(marked)
    for i = 1, back do marked[i].selected = true end
    History.commit()
    MGE.apply() -- the working copy without its pool
    local note = ""
    if back > 0 then note = ", " .. back .. " objects back" end
    MGE.say("atmo: Default (drawn only)" .. note)
    if back < #marked then
        MGE.say(string.format("%d moved objects stay in the atmo: no free ids (To objects once there are)",
            #marked - back))
    end
end

---The World tab's Atmo row (Playable / Default). Playable: a playable mod (see the header), tested in the editor. Default: an
---ordinary mod again, the objects Playable moved into the atmo back (turnOff). Each is one undo step
---@param on boolean
---@return boolean changed
function Playable.setPlayable(on)
    local changed = false
    if on and not Playable.isOn() then
        changed = turnOn()
    elseif not on and Playable.isOn() then
        turnOff()
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
            MGE.say("replay cache off while props are loaded")
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
    -- every way out without props gives the player's replay cache back (setReplayCache(false))
    if not Playable.isOn() then
        setReplayCache(false)
        return
    end
    local loaded = ModData.loadedPlayable
    if not (loaded and loaded.poolObjects) then -- the world has no pool (e.g. an old working copy)
        setReplayCache(false)
        return
    end
    -- an opened mod's pools were planned for its atmo (main.lua forgets the key when another mod opens)
    Playable.loadedKey = Playable.loadedKey or Playable.poolSplitKey(ModData.parsed.atmo)
    local colliders, props = Playable.colliders(ModData.parsed.atmo)
    local pool, err = Pool.new(loaded.poolObjects, colliders, ModData.parsed.playable)
    if not pool then
        MGE.say("playable: " .. tostring(err))
        setReplayCache(false)
        return
    end
    driver = Driver.new(pool)
    local skip = {}
    for _, object in ipairs(loaded.dynamicObjects or {}) do skip[object.id] = true end
    driver.follow = Driver.dynamicIds(skip)
    if loaded.dynamicObjects and #loaded.dynamicObjects > 0 and #props > 0 then
        -- follow: the mod's own dynamic objects push props too
        local params = { dradius = ModData.parsed.playable.dradius, noCopies = true, follow = driver.follow,
            statics = colliders }
        dynamics = Dynamics.new(loaded.dynamicObjects, props, params)
        local d = dynamics
        driver.moreCenters = function() return Dynamics.centers(d) end
    end
    setReplayCache(dynamics ~= nil)
    local ws = get_world_state()
    runDynamics(Dynamics.matchBegin, ws) -- first: the static pool covers the props it takes
    Driver.matchBegin(driver, ws)
end

---A prop's ghost where the prop is now (fights in the editor), else the ghost as it is. nil for a carried
---prop: its pool object shows it (painted its color), two drawn at one pose flickered
---@param index integer the atmo object's place in the Atmo list
---@param g AtmoGhost
---@return AtmoGhost?
function Playable.movedGhost(index, g)
    if not dynamics then return g end
    if Dynamics.isCarried(dynamics, index) then return nil end
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

---draw2d, between physics steps: the pools follow the players once per new match frame from Driver.FIRST_FRAME
---on; replays move nothing, the game plays the recorded moves (driver.lua, dynamics.lua)
function Playable.draw()
    if not driver then return end
    local ws = get_world_state()
    runDynamics(Dynamics.draw, ws)
    local ok, err = pcall(Driver.draw, driver, ws)
    if not ok then
        driver, dynamics = nil, nil
        MGE.say("playable: the pool stopped moving: " .. tostring(err))
    end
end
remove_hooks(PLAY_HOOKS)
add_hook("draw2d", PLAY_HOOKS, function() Playable.draw() end)
table.insert(MGE.onQuit, function()
    remove_hooks(PLAY_HOOKS)
    driver, dynamics = nil, nil
    setReplayCache(false)
end)

MGE.Playable = Playable
return Playable
