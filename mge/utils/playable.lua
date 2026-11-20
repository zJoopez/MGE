-- Playable atmo mods: a big atmo made solid in game by the Atmo Play script (its own repo, atmoplayDev/,
-- docs/plan.md there). MGE makes them; Atmo Play only reads them. A playable mod is an ordinary .tbm with:
--   * a note line first (what the file needs), then the mod's own lines and its real objects
--   * the pool: hidden static env_obj blocks on every free static id, marked with POOL_MARKER. Atmo Play
--     moves them onto the atmo objects nearest the players, every frame of a fight
--   * a header line ("#atmoplay v1 rule=1 radius=4"), then the atmo: every line of the atmo file behind
--     "#@ ". The game skips "#" lines, so neither its mod loader nor its atmo loader sees them
-- These strings must stay as Atmo Play's atmoplay/format.lua reads them (tests/test_playable.lua checks).
--
-- In MGE a playable mod is edited like any other: its atmo is the Atmo list (read from the "#@ " lines
-- instead of MGE - <mod>.atmo), the pool isn't shown (it's made again on every save from the free ids),
-- and Save writes the playable form into modmaker/. The working copy (MGE.apply) stays an ordinary mod:
-- MGE draws the atmo itself while editing.
-- Convert (the World tab): the mod's static objects move into the atmo (MGE's To atmo: ids freed, one undo
-- step) and the mod is marked playable. Objects that stay real: dynamic ones, joint-linked ones, models.
local ModData = MGE.ModData
local FileHandler = MGE.FileHandler
local AtmoLayer = MGE.AtmoLayer
local History = MGE.History

---@class PlayableParams
---@field rule integer pool rule (Atmo Play's pool.lua)
---@field radius number pool reach from a player's center

---@class PlayableSplit
---@field lines string[] the mod without Atmo Play's lines and without the pool blocks
---@field header PlayableParams|{ version: integer }? nil: not a playable mod
---@field atmo string[] the atmo lines, "#@ " removed
---@field pool integer[] the pool blocks' env_obj ids (file ids, 1-based)

---@class Playable
local Playable = {
    VERSION = 1,
    DEFAULT_RULE = 1,
    DEFAULT_RADIUS = 4,
    POOL_MARKER = "#atmoplay pool",
    NOTE = "#atmoplay note: a playable atmo map, needs the Atmo Play script (without it nothing in the atmo is solid)",
    ATMO_PREFIX = "#@ ",
    PARK_Z = -100000,
    STATIC_FLAG = 8,
}

-- keys that keep an atmo object out of collision (Atmo Play's colliders.lua): placed differently on each
-- load or moved while drawn (its collision wouldn't be where it's drawn), or parented (pos relative)
local NOT_SOLID_KEYS = {
    count = true, rpos = true, randompos = true, rsize = true, randomsize = true,
    move = true, rotate = true, drawfunc = true, framefunc = true, parent = true,
}

-- words that start a new section of a mod file (as in file_handler.lua): a block ends at the next one
local SECTION_WORDS = { gamerule = true, body = true, joint = true, player = true, env_obj = true, env_obj_joint = true }

---@param line string
---@return boolean
local function isSectionStart(line)
    local word = line:match("^%s*(%S+)")
    return word ~= nil and SECTION_WORDS[word] == true
end

---@param line string
---@return PlayableParams|{ version: integer }?
function Playable.parseHeader(line)
    local version, rest = line:match("^#atmoplay v(%d+)(.*)$")
    if not version then return nil end
    local header = { version = tonumber(version) }
    for key, value in rest:gmatch("(%w+)=(%S+)") do header[key] = tonumber(value) or value end
    return header
end

---@param params PlayableParams
---@return string
function Playable.headerLine(params)
    return "#atmoplay v" .. Playable.VERSION .. " rule=" .. (params.rule or Playable.DEFAULT_RULE) ..
        " radius=" .. (params.radius or Playable.DEFAULT_RADIUS)
end

---A mod file's lines in parts. Lines Atmo Play's format adds (the note, the header, "#@ " lines) and the
---pool blocks are left out of `lines`, so parsing those gives the mod as MGE edits it
---@param lines string[]
---@return PlayableSplit
function Playable.split(lines)
    local result = { lines = {}, header = nil, atmo = {}, pool = {} }
    local i = 1
    while i <= #lines do
        local line = lines[i]:gsub("\r$", "")
        if result.header then
            local atmoLine = line:match("^#@ ?(.*)$")
            if atmoLine then result.atmo[#result.atmo + 1] = atmoLine end
            i = i + 1
        else
            local header = Playable.parseHeader(line)
            local id = line:match("^%s*env_obj%s+(%d+)")
            if header then
                result.header = header
                i = i + 1
            elseif id then
                local block, marked = { line }, false
                i = i + 1
                while i <= #lines do
                    local bodyLine = lines[i]:gsub("\r$", "")
                    if isSectionStart(bodyLine) or Playable.parseHeader(bodyLine) or bodyLine:match("^#@") then break end
                    if bodyLine:match("^%s*(.-)%s*$") == Playable.POOL_MARKER then marked = true end
                    block[#block + 1] = bodyLine
                    i = i + 1
                end
                if marked then
                    result.pool[#result.pool + 1] = tonumber(id)
                else
                    for _, blockLine in ipairs(block) do result.lines[#result.lines + 1] = blockLine end
                end
            else
                if not (line:match("^%s*#atmoplay") or line:match("^#@")) then result.lines[#result.lines + 1] = line end
                i = i + 1
            end
        end
    end
    return result
end

---The mod's objects Convert moves into the atmo: static, not linked by a joint, not a model
---@param obj FileParserEnvObj
---@return boolean
function Playable.convertible(obj)
    if not ModData.isStatic(obj, true) or ModData.jointIds[obj.id] then return false end
    if obj.props.use_model == "1" then return false end
    return not tostring(obj.props.shape or ""):match("^%s*custom")
end

---An atmo object's collision shape, as Atmo Play will see it: nil when it isn't solid (drawn only)
---@param obj FileParserEnvObj an atmo object
---@return AtmoGhost?
function Playable.solidShape(obj)
    for key in pairs(obj.props) do
        if NOT_SOLID_KEYS[key] then return nil end
    end
    if tostring(obj.props.shape or ""):match("^%s*custom") then return nil end
    return AtmoLayer.ghost(obj) -- nil without a pos line
end

---A friction line as Atmo Play's group key part (colliders.lua frictionKey): the same text every time
---@param value string|number|nil
---@return string
function Playable.frictionKey(value)
    local n = tonumber(value)
    return n and tostring(n) or ""
end

---Per group, the most solid atmo objects a player can have in reach at once (sampled at every one's
---position; a 2D grid keeps it fast): what the pool has to cover. As Atmo Play's builder.lua
---@param solids { pos: number[], radius: number, group: string }[]
---@param reach number
---@return table<string, integer>
local function demandPeaks(solids, reach)
    local size = math.max(reach * 2, 1)
    local grid = {}
    local function cell(v) return math.floor(v / size) end
    local function key(x, y) return (x + 32768) * 65536 + (y + 32768) end
    for _, s in ipairs(solids) do
        local r = s.radius + reach
        for x = cell(s.pos[1] - r), cell(s.pos[1] + r) do
            for y = cell(s.pos[2] - r), cell(s.pos[2] + r) do
                local k = key(x, y)
                local list = grid[k]
                if not list then
                    list = {}
                    grid[k] = list
                end
                list[#list + 1] = s
            end
        end
    end
    local peaks = {}
    for _, sample in ipairs(solids) do
        local p, counts = sample.pos, {}
        for _, s in ipairs(grid[key(cell(p[1]), cell(p[2]))] or {}) do
            local dx, dy, dz = p[1] - s.pos[1], p[2] - s.pos[2], p[3] - s.pos[3]
            local r = s.radius + reach
            if dx * dx + dy * dy + dz * dz <= r * r then counts[s.group] = (counts[s.group] or 0) + 1 end
        end
        for group, n in pairs(counts) do
            if n > (peaks[group] or 0) then peaks[group] = n end
        end
    end
    return peaks
end

---Pool objects per group: one per group first (most needed first), then in proportion to the peaks
---(always to the group with the highest peak / (pool + 1)), never more than a group has objects
---@return { group: string, solids: integer, peak: integer, pool: integer }[] in the order ids are handed out
local function splitPool(counts, peaks, slots)
    local groups = {}
    for group, count in pairs(counts) do
        groups[#groups + 1] = { group = group, solids = count, peak = math.max(peaks[group] or 1, 1), pool = 0 }
    end
    table.sort(groups, function(a, b)
        if a.peak ~= b.peak then return a.peak > b.peak end
        if a.solids ~= b.solids then return a.solids > b.solids end
        return a.group < b.group
    end)
    for _, g in ipairs(groups) do
        if slots > 0 then
            g.pool = 1
            slots = slots - 1
        end
    end
    while slots > 0 do
        local best, bestScore
        for _, g in ipairs(groups) do
            if g.pool < g.solids then
                local score = g.peak / (g.pool + 1)
                if not best or score > bestScore then best, bestScore = g, score end
            end
        end
        if not best then break end
        best.pool = best.pool + 1
        slots = slots - 1
    end
    return groups
end

---@class PlayablePlan
---@field objects { id: integer, group: string }[] the pool, by id
---@field groups { group: string, solids: integer, peak: integer, pool: integer }[]
---@field freeIds integer static ids the mod doesn't use
---@field solid integer solid atmo objects
---@field atmo integer all atmo objects

---The pool a save would write for this data: every free static id (above MAX_NONSTATIC_OBJECTS), split by
---group (shape and friction: the game can't change an object's friction), no more than solid objects
---@param parsed FileParserResult
---@return PlayablePlan
function Playable.poolPlan(parsed)
    local params = parsed.playable or {}
    local reach = tonumber(params.radius) or Playable.DEFAULT_RADIUS
    local used = {}
    for _, obj in ipairs(parsed.env_obj or {}) do used[obj.id] = true end
    local free = {}
    for id = MGE.MAX_NONSTATIC_OBJECTS + 1, MGE.MAX_ENV_OBJECTS do
        if not used[id] then free[#free + 1] = id end
    end
    local solids, counts = {}, {}
    for _, obj in ipairs(parsed.atmo or {}) do
        local ghost = Playable.solidShape(obj)
        if ghost then
            local group = ghost.shape .. "|" .. Playable.frictionKey(obj.props.friction)
            solids[#solids + 1] = { pos = ghost.pos, radius = ghost.radius, group = group }
            counts[group] = (counts[group] or 0) + 1
        end
    end
    local groups = splitPool(counts, demandPeaks(solids, reach), math.min(#free, #solids))
    local objects, nextFree = {}, 1
    for _, g in ipairs(groups) do
        for _ = 1, g.pool do
            objects[#objects + 1] = { id = free[nextFree], group = g.group }
            nextFree = nextFree + 1
        end
    end
    table.sort(objects, function(a, b) return a.id < b.id end)
    return { objects = objects, groups = groups, freeIds = #free, solid = #solids, atmo = #(parsed.atmo or {}) }
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
        lines = { { raw = Playable.POOL_MARKER } },
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
---@return string text, PlayablePlan plan
function Playable.text(parsed, atmoText)
    local plan = Playable.poolPlan(parsed)
    local copy = {}
    for k, v in pairs(parsed) do copy[k] = v end
    copy.env_obj = {}
    for _, obj in ipairs(parsed.env_obj or {}) do copy.env_obj[#copy.env_obj + 1] = obj end
    for _, p in ipairs(plan.objects) do copy.env_obj[#copy.env_obj + 1] = poolObject(p.id, p.group) end
    table.sort(copy.env_obj, function(a, b) return a.id < b.id end)
    local out = { Playable.NOTE, FileHandler.modText(copy), "", Playable.headerLine(parsed.playable) }
    for line in (atmoText .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line == "" and "#@" or (Playable.ATMO_PREFIX .. line)
    end
    return table.concat(out, "\n"), plan
end

---World tab's Convert: the mod's convertible static objects into the atmo (To atmo: one undo step, the
---working copy reloads) and the mod marked playable; Save then writes it in the playable form. Again on a
---playable mod: objects added since are moved too
function Playable.convert()
    ModData.refreshJointIds()
    local count = 0
    for _, obj in ipairs(ModData.parsed.env_obj) do
        obj.selected = Playable.convertible(obj) or nil
        if obj.selected then count = count + 1 end
    end
    for _, obj in ipairs(ModData.parsed.atmo or {}) do obj.selected = nil end
    local solid = 0
    for _, obj in ipairs(ModData.parsed.atmo or {}) do
        if Playable.solidShape(obj) then solid = solid + 1 end
    end
    if count == 0 and solid == 0 then
        MGE.say("nothing to make solid: no static objects and no solid atmo objects (boxes, spheres, capsules)")
        return false
    end
    local wasPlayable = ModData.parsed.playable ~= nil
    -- set before the step To atmo commits, so undo takes it back with the moved objects
    ModData.parsed.playable = ModData.parsed.playable or { rule = Playable.DEFAULT_RULE, radius = Playable.DEFAULT_RADIUS }
    if count > 0 then
        AtmoLayer.moveIn() -- History.commit, MGE.apply
    elseif not wasPlayable then
        History.commit()
    end
    local plan = Playable.poolPlan(ModData.parsed)
    MGE.say(string.format("playable: %d solid atmo objects, %d pool objects (%d free ids)%s. Save writes it",
        plan.solid, #plan.objects, plan.freeIds, count > 0 and (", " .. count .. " objects moved to the atmo") or ""))
    if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "playable" }) end
    return true
end

---Makes a playable mod ordinary again (its atmo goes back to MGE - <mod>.atmo on the next save). One
---undo step; the atmo objects stay in the atmo
function Playable.makeOrdinary()
    if not ModData.parsed.playable then return end
    ModData.parsed.playable = nil
    History.commit()
    MGE.say("not playable any more: Save writes an ordinary mod and its atmo file again")
    if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "playable" }) end
end

MGE.Playable = Playable
return Playable
