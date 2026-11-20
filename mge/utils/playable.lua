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
local ModData = MGE.ModData
local FileHandler = MGE.FileHandler
local AtmoLayer = MGE.AtmoLayer
local History = MGE.History
local Format = MGE.AtmoPlay.Format
local Colliders = MGE.AtmoPlay.Colliders
local Pool = MGE.AtmoPlay.Pool
local Driver = MGE.AtmoPlay.Driver

---@class PlayableParams
---@field rule integer pool rule (Atmo Play's pool.lua)
---@field radius number pool reach from a player's center

---@class Playable
local Playable = {
    DEFAULT_RULE = Pool.DEFAULT_RULE,
    DEFAULT_RADIUS = Pool.DEFAULT_RADIUS,
    NOTE = Format.NOTE,
    PARK_Z = -100000,
    STATIC_FLAG = 8,
}

---A mod file's lines in parts (Atmo Play's Format.split): `lines` is the mod MGE parses, without the
---pool blocks and Atmo Play's lines; `header` is nil for an ordinary mod. `poolObjects` (Format.read's):
---the pool the file has, what the world has after /lm
---@param lines string[]
---@return AtmoPlaySplit|{ poolObjects: AtmoPlayPoolObject[]? }
function Playable.split(lines)
    local split = Format.split(lines)
    if split.header then split.poolObjects = Format.read(lines).pool end
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
local colliderCache = { text = nil, colliders = nil }

---The atmo's solid objects exactly as Atmo Play will see them: its colliders.lua on the atmo's text
---@param atmo FileParserEnvObj[] the atmo layer
---@return AtmoPlayCollider[]
function Playable.colliders(atmo)
    local text = MGE.Atmo.text({ objects = atmo or {} })
    if colliderCache.text == text then return colliderCache.colliders end
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local colliders = (Colliders.build(lines))
    colliderCache.text, colliderCache.colliders = text, colliders
    return colliders
end

---@class PlayablePlan
---@field objects { id: integer, group: string }[] the pool, by id
---@field groups { group: string, colliders: integer, peak: integer, pool: integer }[]
---@field freeIds integer static ids the mod doesn't use
---@field solid integer solid atmo objects
---@field atmo integer all atmo objects

---The pool a save would write for this data: every free static id (above MAX_NONSTATIC_OBJECTS), split
---by Atmo Play's Pool.plan, no more than solid objects
---@param parsed FileParserResult
---@param colliders AtmoPlayCollider[]? Playable.colliders(parsed.atmo), made when not given
---@return PlayablePlan
function Playable.poolPlan(parsed, colliders)
    local params = parsed.playable or {}
    local used = {}
    for _, obj in ipairs(parsed.env_obj or {}) do used[obj.id] = true end
    local free = {}
    for id = MGE.MAX_NONSTATIC_OBJECTS + 1, MGE.MAX_ENV_OBJECTS do
        if not used[id] then free[#free + 1] = id end
    end
    colliders = colliders or Playable.colliders(parsed.atmo)
    local plan = Pool.plan(colliders, free, tonumber(params.radius) or Playable.DEFAULT_RADIUS)
    return { objects = plan.objects, groups = plan.groups, freeIds = #free, solid = #colliders,
        atmo = #(parsed.atmo or {}) }
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

---The playable mod's text: the note, the mod with its pool (MGE's own writer), the header, the atmo
---@param parsed FileParserResult with .playable set
---@param atmoText string the atmo as its file would hold it (Atmo.text)
---@param colliders AtmoPlayCollider[]? Playable.colliders(parsed.atmo), made when not given
---@return string text, PlayablePlan plan
function Playable.text(parsed, atmoText, colliders)
    local plan = Playable.poolPlan(parsed, colliders)
    local copy = {}
    for k, v in pairs(parsed) do copy[k] = v end
    copy.env_obj = {}
    for _, obj in ipairs(parsed.env_obj or {}) do copy.env_obj[#copy.env_obj + 1] = obj end
    for _, p in ipairs(plan.objects) do copy.env_obj[#copy.env_obj + 1] = poolObject(p.id, p.group) end
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
    return (Playable.text(parsed, "", Playable.colliders(parsed.atmo)))
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
    if count == 0 and #Playable.colliders(ModData.parsed.atmo) == 0 then
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

---After every reload (main.lua's match_begin, inside /lm): for a playable mod, a driver for the pool that's
---in the world now (the loaded file's own pool: MGE's working copy or the opened mod), placed for this fight
function Playable.onMatchBegin()
    driver = nil
    if not Playable.isOn() then return end
    local loaded = ModData.loadedPlayable
    if not (loaded and loaded.poolObjects) then return end -- the world has no pool (e.g. an old working copy)
    local pool, err = Pool.new(loaded.poolObjects, Playable.colliders(ModData.parsed.atmo), ModData.parsed.playable)
    if not pool then
        MGE.say("playable: " .. tostring(err))
        return
    end
    driver = Driver.new(pool)
    Driver.matchBegin(driver, get_world_state())
end

-- between physics steps: the pool follows the players once per new match frame (driver.lua)
remove_hooks(PLAY_HOOKS)
add_hook("draw2d", PLAY_HOOKS, function()
    if not driver then return end
    local ok, err = pcall(Driver.draw, driver, get_world_state())
    if not ok then
        driver = nil
        MGE.say("playable: the pool stopped moving: " .. tostring(err))
    end
end)
table.insert(MGE.onQuit, function()
    remove_hooks(PLAY_HOOKS)
    driver = nil
end)

MGE.Playable = Playable
return Playable
