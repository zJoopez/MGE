-- Playable atmo mods, made solid in game by Atmo Play (docs/atmo-play-plan.md) using its own modules
-- (MGE.AtmoPlay), so MGE writes and tests exactly what Atmo Play plays. File: a note line, the mod with a
-- pool of hidden static objects on every free static id (Format.POOL_MARKER), then a header and the atmo
-- as "#@ " lines (skipped by the game).
-- The World tab's Atmo switch: Playable moves the convertible static objects into the atmo (one undo
-- step) and the working copy carries the pool, moved in fights like Atmo Play does. Default makes an
-- ordinary mod again. The pool is never in the data: it's rebuilt from free ids on every write.
-- Props (atmo objects without the static bit) are pushable: the file also gets a dynamic pool on free
-- ids 1-48 and a hidden parking platform
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

---A mod file's lines in parts (Format.split): `lines` is the mod without pools and Atmo Play lines,
---`header` nil for an ordinary mod; poolObjects / dynamicObjects are the file's pools
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

---@return boolean the data is a playable mod
function Playable.isOn()
    return ModData.parsed.playable ~= nil
end

---Objects Playable moves into the atmo: static, not joint-linked, not a model
---@param obj FileParserEnvObj
---@return boolean
function Playable.convertible(obj)
    if not ModData.isStatic(obj, true) or ModData.jointIds[obj.id] then return false end
    if obj.props.use_model == "1" then return false end
    return not tostring(obj.props.shape or ""):match("^%s*custom")
end

-- colliders by atmo text: an unchanged atmo isn't rebuilt (~0.1 s on 5k objects)
local colliderCache = { text = nil, colliders = nil, props = nil }

---The atmo's solid objects exactly as Atmo Play sees them
---@param atmo FileParserEnvObj[] the atmo layer
---@return AtmoPlayCollider[] colliders the static ones
---@return AtmoPlayCollider[] props the dynamic ones (pushable in Atmo Play)
function Playable.colliders(atmo)
    -- the footer's text (shared, written again only on changes); its header lines aren't entities
    local text = MGE.Atmo.cachedText(atmo or {}, MGE.Atmo.state.header)
    if colliderCache.text == text then return colliderCache.colliders, colliderCache.props end
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local colliders, _, props = Colliders.build(lines)
    colliderCache.text, colliderCache.colliders, colliderCache.props = text, colliders, props
    return colliders, props
end

---What the pools are split by: solid objects and props per group. Positions don't count (every fight
---rereads the atmo), so moves and colors need no reload
---@param atmo FileParserEnvObj[]?
---@return string
---An atmo object's pool class: "s <group>" solid, "p <group>" prop, "n <group>" a prop never real (no pool
---object: counted apart), false when not solid
---@param obj FileParserEnvObj
---@return string|false
local function splitClass(obj)
    local reason, _, group, prop = Colliders.classify(obj.props)
    if reason then return false end
    local never = false
    if prop then
        local player, real = Colliders.collision(obj.props)
        never = not player and not real
    end
    return (never and "n " or prop and "p " or "s ") .. group
end

-- the last key, and each object's class with the text cache's snapshot it was read from: only objects whose
-- snapshot changed are classified again (all 5k took ~14 ms per atmo edit)
local splitCache = { text = nil, key = nil, list = nil, snaps = {}, classes = {}, counts = {} }

function Playable.poolSplitKey(atmo)
    local list = atmo or {}
    local text, snaps = MGE.Atmo.cachedText(list, MGE.Atmo.state.header)
    if splitCache.text == text and splitCache.list == list then return splitCache.key end
    local c = splitCache
    if c.list ~= list then c.list, c.snaps, c.classes, c.counts = list, {}, {}, {} end
    local counts = c.counts
    local function count(class, by)
        if not class then return end
        local n = (counts[class] or 0) + by
        counts[class] = n ~= 0 and n or nil
    end
    for i, obj in ipairs(list) do
        if c.snaps[i] ~= snaps[i] then
            count(c.classes[i], -1)
            local class = splitClass(obj)
            count(class, 1)
            c.classes[i], c.snaps[i] = class, snaps[i]
        end
    end
    for i = #c.snaps, #list + 1, -1 do -- objects gone from the end
        count(c.classes[i], -1)
        c.classes[i], c.snaps[i] = nil, nil
    end
    local parts = {}
    for class, n in pairs(counts) do parts[#parts + 1] = class .. "=" .. n end
    table.sort(parts)
    c.text, c.key = text, table.concat(parts, ";")
    return c.key
end

---@type string? poolSplitKey of the loaded pools, nil: not known yet
Playable.loadedKey = nil

---After committed atmo changes: reloads the working copy when the pools no longer fit the atmo
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

---@type { colliders: table?, props: table?, key: string?, plan: PlayablePlan? } read-only plans are shared
local planCache = {}

---The pool a save would write: free static ids split by Pool.plan. With props, free ids 1-48 are their
---pool and the first free static id their parking platform
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
    -- the same colliders (an unchanged atmo) and free ids: the same plan. Every edit of a playable mod reloads,
    -- and planning a 5k atmo took ~95 ms
    local key = table.concat(free, ",") .. "|" .. table.concat(freeDynamic, ",") .. "|" .. tostring(params.radius) ..
        "|" .. tostring(params.dradius)
    if planCache.colliders == colliders and planCache.props == props and planCache.key == key then
        return planCache.plan
    end
    local dynamic, park = {}, nil
    if #props > 0 and #freeDynamic > 0 and #free > 0 then
        park = table.remove(free, 1)
        -- only props that can become real get pool objects
        local real = {}
        for _, p in ipairs(props) do
            if not p.noReal then real[#real + 1] = p end
        end
        dynamic = #real > 0 and Pool.plan(real, freeDynamic, tonumber(params.dradius) or Dynamics.DEFAULT_RADIUS).objects
            or {}
    end
    local plan = Pool.plan(colliders, free, tonumber(params.radius) or Playable.DEFAULT_RADIUS)
    local result = { objects = plan.objects, groups = plan.groups, freeIds = #free, solid = #colliders,
        atmo = #(parsed.atmo or {}), props = #props, dynamic = dynamic, park = park }
    planCache = { colliders = colliders, props = props, key = key, plan = result }
    return result
end

---Adds a pool object's lines: the keys, then the group's friction / hardness / bounce / mass (fixed once
---loaded), then visible
---@param obj FileParserEnvObj
---@param keys string[]
---@param group string
---@return FileParserEnvObj obj
local function withLines(obj, keys, group)
    -- replays don't record live-set bounce / flags, so the group's values are written
    local _, friction, hardness, bounce, flagBits, mass = Colliders.splitGroup(group)
    if flagBits ~= "" then obj.props.flag = tostring((tonumber(obj.props.flag) or 0) + tonumber(flagBits)) end
    for _, key in ipairs(keys) do obj.lines[#obj.lines + 1] = { key = key } end
    for _, line in ipairs({ { "friction", friction }, { "hardness", hardness }, { "bounce", bounce }, { "mass", mass } }) do
        local key, value = line[1], line[2]
        if value ~= "" then
            local listed = obj.props[key] ~= nil -- the prop look may have written it
            obj.props[key] = value
            if not listed then obj.lines[#obj.lines + 1] = { key = key } end
        end
    end
    obj.lines[#obj.lines + 1] = { key = "visible" }
    return obj
end

local POOL_KEYS = { "shape", "pos", "rot", "sides", "color", "flag" }

---A pool object: hidden, static, parked far below the map
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

---Each prop group's most common size, mass and bounce: its pool objects are written so, so taking
---those props resizes nothing
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

---A prop pool object: dynamic, on the parking platform. Faint by alpha, not hidden: hidden objects get
---no move-prediction ghost
---@param id integer 1-48
---@param group string Colliders.groupKey
---@param look { sides: number[], mass: number?, bounce: number? }? Playable.propLooks'
---@param pos number[]? parking spot, default Dynamics.parkPos
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

---The props' parking platform: hidden, static, high above the map
---@param id integer
---@param platform { pos: number[], sides: number[] }? Dynamics.parkLayout's
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

---The playable mod's text: note, mod with pools, header, atmo
---@param parsed FileParserResult with .playable set
---@param atmoText string the atmo as its file would hold it (Atmo.text)
---@param colliders AtmoPlayCollider[]? Playable.colliders(parsed.atmo), made when not given
---@param props AtmoPlayCollider[]? its second result
---@return string text, PlayablePlan plan
function Playable.text(parsed, atmoText, colliders, props)
    if not colliders then colliders, props = Playable.colliders(parsed.atmo) end
    local plan = Playable.poolPlan(parsed, colliders, props)
    local copy = ModData.copy(parsed)
    copy.env_obj = {}
    for _, obj in ipairs(parsed.env_obj or {}) do copy.env_obj[#copy.env_obj + 1] = obj end
    for _, p in ipairs(plan.objects) do copy.env_obj[#copy.env_obj + 1] = poolObject(p.id, p.group) end
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
    MGE.Atmo.appendHidden(out, atmoText)
    return table.concat(out, "\n"), plan
end

---The working copy: the playable text without atmo lines (MGE draws the atmo; the header keeps the
---pool out of the data on reload)
---@param parsed FileParserResult
---@return string
function Playable.workingText(parsed)
    Playable.loadedKey = Playable.poolSplitKey(parsed.atmo)
    return (Playable.text(parsed, "", Playable.colliders(parsed.atmo))) -- passes both colliders and props
end

---------------------------------------------------------------------------------------------------- the switch

local function refreshRow()
    if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "playable" }) end
end

---Playable: convertible objects into the atmo and the mod marked playable (one undo step)
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
    -- set before moveIn commits, so one undo takes both back
    ModData.parsed.playable = { rule = Playable.DEFAULT_RULE, radius = Playable.DEFAULT_RADIUS }
    if count > 0 then
        AtmoLayer.moveIn(true) -- marked for Default; commits and applies
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

---Default: not playable, and objects Playable moved return as far as ids allow. One undo step
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
    MGE.apply()
    local note = ""
    if back > 0 then note = ", " .. back .. " objects back" end
    MGE.say("atmo: Default (drawn only)" .. note)
    if back < #marked then
        MGE.say(string.format("%d moved objects stay in the atmo: no free ids (To objects once there are)",
            #marked - back))
    end
end

---The World tab's Atmo switch (Playable / Default), one undo step
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

-- editor test settings (Settings, config.cfg), not part of the mod
Playable.flightLevel = Dynamics.DEFAULT_LEVEL -- how drawn props fly (Dynamics.LEVELS)
Playable.ghosts = true -- flying props' move predictions
Playable.pauseFar = false -- props far from every player pause

local PLAY_HOOKS = MGE.hookname .. "_playable"
---@type AtmoPlayDriver?
local driver = nil
---@type table? the props in fights (Atmo Play's dynamics.lua), nil without props
local dynamics = nil
---@type number? the player's replaycache while props have it off (cached replays misplace them)
local cacheBefore = nil

---Settings > Ghosts
---@param on boolean
function Playable.setGhosts(on)
    Playable.ghosts = on and true or false
    if not Playable.ghosts and dynamics then Dynamics.dropPrediction(dynamics) end
end

---Settings > Distant; current props take it from the next fight
---@param on boolean
function Playable.setPauseFar(on)
    Playable.pauseFar = on and true or false
    if dynamics then Dynamics.setPauseFar(dynamics, Playable.pauseFar) end
end

---Settings > Detail; current props take it from the next fight
---@param level string
function Playable.setFlightLevel(level)
    Playable.flightLevel = Dynamics.level(level)
    if dynamics then Dynamics.setLevel(dynamics, Playable.flightLevel) end
end

---The player's replaycache while props have it off (config.cfg keeps it in case the game closes first)
---@return number?
function Playable.cacheBefore() return cacheBefore end

---Gives a replaycache back, unless the player changed it meanwhile (not 0 any more)
---@param before number?
function Playable.giveCacheBack(before)
    if before == nil then return end
    local ok, value = pcall(get_option, "replaycache")
    if ok and tonumber(value) == 0 then pcall(set_option, "replaycache", before) end
end

local function saveCache()
    if not MGE.Config then return end
    MGE.Config.values.replayCache = cacheBefore -- nil clears it (save keeps a value only a getter gives)
    MGE.Config.save()
end

local function setReplayCache(withProps)
    if withProps and cacheBefore == nil and Dynamics.CACHE_OFF then
        local ok, value = pcall(get_option, "replaycache")
        if ok and tonumber(value) and tonumber(value) ~= 0 then
            cacheBefore = tonumber(value)
            set_option("replaycache", 0)
            saveCache()
            MGE.say("replay cache off while props are loaded")
        end
    elseif not withProps and cacheBefore ~= nil then
        Playable.giveCacheBack(cacheBefore)
        cacheBefore = nil
        saveCache()
    end
end

---Runs a Dynamics call; an error stops the props, not the static pool
local function runDynamics(fn, ws)
    if not dynamics then return end
    local ok, err = pcall(fn, dynamics, ws)
    if not ok then
        dynamics = nil
        if driver then driver.moreCenters = nil end
        MGE.say("playable: props stopped: " .. tostring(err))
    end
end

---After every reload: a driver for the loaded file's pool (and props), placed for this fight
function Playable.onMatchBegin()
    driver, dynamics = nil, nil
    Dynamics.release() -- the last props' buffers
    -- every exit without props restores the replay cache
    if not Playable.isOn() then
        setReplayCache(false)
        return
    end
    local loaded = ModData.loadedPlayable
    if not (loaded and loaded.poolObjects) then
        setReplayCache(false)
        return
    end
    -- an opened mod's pools were planned for its atmo
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
    if #props > 0 then
        -- the mod's dynamic objects push props too
        local params = { dradius = ModData.parsed.playable.dradius, follow = driver.follow,
            statics = colliders, level = Playable.flightLevel, pauseFar = Playable.pauseFar }
        dynamics = Dynamics.new(loaded.dynamicObjects or {}, props, params)
        local d = dynamics
        driver.moreCenters = function() return Dynamics.centers(d) end
    end
    setReplayCache(dynamics ~= nil and #dynamics.entries > 0)
    local ws = get_world_state()
    runDynamics(Dynamics.matchBegin, ws) -- first: the static pool covers the props
    Driver.matchBegin(driver, ws)
end

-- one reused ghost per moved prop (a copy a frame was most of MGE's garbage)
local movedGhosts = {}

---A prop's ghost where the prop is now, else g. nil for a carried prop (its pool object shows it)
---@param index integer the atmo list index
---@param g AtmoGhost
---@return AtmoGhost?
function Playable.movedGhost(index, g)
    if not dynamics then return g end
    if Dynamics.isCarried(dynamics, index) then return nil end
    local pos, rot = Dynamics.movedPose(dynamics, index)
    if not pos then return g end
    local ghost = movedGhosts[index]
    if not ghost or ghost.from ~= g then
        ghost = ModData.copy(g)
        ghost.from = g
        movedGhosts[index] = ghost
    end
    -- rotTB: drawn as is, no frame built
    ghost.pos, ghost.rotTB = pos, rot
    return ghost
end

---draw3d: the flying props' move predictions, like the game's own objects'
---@param onScreen (fun(x: number, y: number, z: number, r: number): boolean)? highlight.lua's view check
function Playable.drawGhosts(onScreen)
    if not dynamics or not Playable.ghosts then return end
    local ok, err = pcall(Dynamics.drawGhosts, dynamics, get_world_state(), onScreen)
    if not ok and not Playable.ghostError then
        Playable.ghostError = true -- once a session
        MGE.say("playable: prop ghosts failed: " .. tostring(err))
    end
end

---draw2d: the pools follow the players once per new match frame; replays move nothing
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
-- Replays are watched in pre_draw, before draw3d draws the atmo: in draw2d a released prop vanished for a
-- frame and a taken one showed twice
local function watchReplay()
    if not dynamics then return end
    local ws = get_world_state()
    if ws.replay_mode > 0 then runDynamics(Dynamics.draw, ws) end
end
add_hook("pre_draw", PLAY_HOOKS, watchReplay)
-- and every physics frame, so no take or release falls between drawn frames; also samples players for
-- far props' pauses (same in fights and replays)
add_hook("enter_frame", PLAY_HOOKS, function()
    watchReplay()
    if dynamics and dynamics.pauseFar then runDynamics(Dynamics.sample, get_world_state()) end
end)
table.insert(MGE.onQuit, function()
    remove_hooks(PLAY_HOOKS)
    driver, dynamics = nil, nil
    setReplayCache(false)
end)

MGE.Playable = Playable
return Playable
