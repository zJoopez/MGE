-- Makes a playable mod (docs/atmo-play-plan.md, part 1) from a base mod's lines and an atmo's lines. Plain text
-- work, no game needed: a developer tool (tools/atmoplay/build_playable.lua). MGE makes playable mods in the
-- editor with its own code (mge/utils/playable.lua) and the same Pool.plan.
--   1. The base mod's lines stay as they are, except its static objects that the pool can stand in for:
--      those move into the atmo part (drawn and collided like the rest, their ids freed). Dynamic
--      objects (no static flag), objects linked by env_obj_joint and model objects (use_model 1) stay
--      real env objects.
--   2. Every free static id (above MAX_NONSTATIC, the range static objects need) gets a pool object: a
--      hidden static object with the pool marker, parked far below the map. No more pool objects than
--      collidable atmo objects.
--   3. The pool is split by group (shape, friction and hardness: the game can't change those on an object), in
--      proportion to how many of each group a player can have in reach at once (sampled over the map),
--      at least one per group while ids last.
--   4. The header and the atmo (the given atmo's lines, then the converted objects), every line behind
--      "#@ ".
-- Lines Atmo Play wrote before (note, header, pool objects, "#@ " lines) are dropped first, so building
-- from a playable mod replaces its pool and atmo.

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Format = NS.Format
local Colliders = NS.Colliders
local Pool = NS.Pool

---@class AtmoPlayBuildOptions
---@field rule integer? pool rule written to the header (Pool.DEFAULT_RULE)
---@field radius number? pool reach written to the header (Pool.DEFAULT_RADIUS)
---@field maxId integer? highest env_obj id (256)
---@field maxNonStatic integer? highest id outside the static range (48)
---@field lowIds boolean? also use free ids 1..maxNonStatic for the pool

---@class AtmoPlayBuildStats
---@field kept integer the base mod's objects that stay real env objects
---@field converted integer the base mod's static objects moved into the atmo
---@field pool integer pool objects
---@field freeIds integer free ids the pool could use
---@field collidable integer collidable atmo objects (converted ones included)
---@field atmoObjects integer all atmo objects
---@field skipped table<string, integer> atmo objects drawn but not collidable, by reason
---@field groups { group: string, colliders: integer, peak: integer, pool: integer }[]

---@class AtmoPlayBuilder
local Builder = {
    MAX_ID = 256,
    MAX_NONSTATIC = 48,
    STATIC_FLAG = 8,
    PARK_Z = -100000,
    INDENT = "   ",
}

---@param line string
---@return string
local function stripCR(line)
    return (line:gsub("\r$", ""))
end

---The base mod in pieces: text lines, env_obj blocks and env_obj_joint blocks, in order
---@param lines string[]
---@return table[] items { kind = "text", line } | { kind = "env_obj" | "env_obj_joint", id, header, body, props }
local function readBase(lines)
    local items, i = {}, 1
    while i <= #lines do
        local line = stripCR(lines[i])
        local objectId = line:match("^%s*env_obj%s+(%d+)")
        local jointId, obj1, obj2 = line:match("^%s*env_obj_joint%s+(%d+)%s+(%d+)%s+(%d+)")
        if objectId or jointId then
            local item = {
                kind = objectId and "env_obj" or "env_obj_joint",
                id = tonumber(objectId or jointId),
                obj1 = tonumber(obj1), obj2 = tonumber(obj2),
                header = line, body = {}, props = {}, pool = false,
            }
            i = i + 1
            while i <= #lines and not Format.isSectionStart(stripCR(lines[i])) do
                local bodyLine = stripCR(lines[i])
                local trimmed = bodyLine:match("^%s*(.-)%s*$")
                if trimmed == Format.POOL_MARKER then
                    item.pool = true
                elseif Format.isOwnLine(bodyLine) then -- the header or atmo lines after a pool block
                    break
                else
                    item.body[#item.body + 1] = bodyLine
                    local key, value = trimmed:match("^([%a_]+)%s+(.-)$")
                    if key then item.props[key] = value end
                end
                i = i + 1
            end
            if not item.pool then items[#items + 1] = item end
        else
            if not Format.isOwnLine(line) then items[#items + 1] = { kind = "text", line = line } end
            i = i + 1
        end
    end
    -- trailing blank lines (the pool follows them)
    while #items > 0 and items[#items].kind == "text" and items[#items].line:match("^%s*$") do
        table.remove(items)
    end
    return items
end

---@param props table<string, string>
---@return boolean
local function isStatic(props)
    local flag = tonumber(props.flag)
    if not flag then return false end -- no flag line: 0, a dynamic object
    return math.floor(flag / Builder.STATIC_FLAG) % 2 == 1
end

---@param props table<string, string>
---@return boolean
local function isModel(props)
    return props.use_model == "1" or tostring(props.shape or ""):match("^%s*custom") ~= nil
end

---A base mod's env_obj as atmo lines: its property lines under "env_obj atmoplay_mod_<id>"
local function asAtmoEntity(item)
    local out = { "env_obj atmoplay_mod_" .. item.id }
    for _, line in ipairs(item.body) do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:match("^[%a_]+%s") then out[#out + 1] = Builder.INDENT .. trimmed end
    end
    return out
end

---A pool object's lines
---@param id integer
---@param group string Colliders.groupKey: shape|friction|hardness|bounce|flag bits, empty ones at the end left out
---@return string[]
local function poolBlock(id, group)
    local shape, friction, hardness, bounce, flagBits = Colliders.splitGroup(group)
    local lines = {
        "env_obj " .. id,
        Builder.INDENT .. Format.POOL_MARKER,
        Builder.INDENT .. "shape " .. shape,
        Builder.INDENT .. "pos " .. id .. " 0 " .. Builder.PARK_Z,
        Builder.INDENT .. "rot 0 0 0",
        Builder.INDENT .. "sides 1 1 1",
        Builder.INDENT .. "color 1 1 1 1",
        Builder.INDENT .. "flag " .. (Builder.STATIC_FLAG + (tonumber(flagBits) or 0)),
    }
    if friction ~= "" then lines[#lines + 1] = Builder.INDENT .. "friction " .. friction end
    if hardness ~= "" then lines[#lines + 1] = Builder.INDENT .. "hardness " .. hardness end
    if bounce ~= "" then lines[#lines + 1] = Builder.INDENT .. "bounce " .. bounce end
    lines[#lines + 1] = Builder.INDENT .. "visible 0"
    return lines
end

---Makes the playable mod
---@param baseLines string[] the base mod's lines ({} for the built-in classic, which has no file)
---@param atmoLines string[] the atmo's lines
---@param options AtmoPlayBuildOptions?
---@return string[]? lines, AtmoPlayBuildStats|string stats or the error
function Builder.build(baseLines, atmoLines, options)
    options = options or {}
    local maxId = options.maxId or Builder.MAX_ID
    local maxNonStatic = options.maxNonStatic or Builder.MAX_NONSTATIC
    local rule = options.rule or Pool.DEFAULT_RULE
    local radius = options.radius or Pool.DEFAULT_RADIUS

    local items = readBase(baseLines)
    local linked = {}
    for _, item in ipairs(items) do
        if item.kind == "env_obj_joint" then
            if item.obj1 then linked[item.obj1] = true end
            if item.obj2 then linked[item.obj2] = true end
        end
    end

    -- the atmo: the given lines, then the base mod's convertible static objects
    local atmo = {}
    for _, line in ipairs(atmoLines) do atmo[#atmo + 1] = stripCR(line) end
    local used, kept, converted = {}, 0, 0
    local keptItems = {}
    for _, item in ipairs(items) do
        if item.kind == "env_obj" then
            if isStatic(item.props) and not linked[item.id] and not isModel(item.props) then
                for _, line in ipairs(asAtmoEntity(item)) do atmo[#atmo + 1] = line end
                converted = converted + 1
            else
                used[item.id] = true
                kept = kept + 1
                keptItems[#keptItems + 1] = item
            end
        else
            keptItems[#keptItems + 1] = item
        end
    end

    local colliders, colliderStats = Colliders.build(atmo)
    if #colliders == 0 then return nil, "the atmo has no collidable objects (positioned boxes, spheres, cylinders)" end

    local free = {}
    for id = maxNonStatic + 1, maxId do
        if not used[id] then free[#free + 1] = id end
    end
    if options.lowIds then
        for id = 1, maxNonStatic do
            if not used[id] then free[#free + 1] = id end
        end
    end
    if #free == 0 then return nil, "no free object ids for the pool" end
    local plan = Pool.plan(colliders, free, radius)

    local out = { Format.NOTE }
    for _, item in ipairs(keptItems) do
        if item.kind == "text" then
            out[#out + 1] = item.line
        else
            out[#out + 1] = item.header
            for _, line in ipairs(item.body) do out[#out + 1] = line end
        end
    end
    for _, p in ipairs(plan.objects) do
        out[#out + 1] = ""
        for _, line in ipairs(poolBlock(p.id, p.group)) do out[#out + 1] = line end
    end
    out[#out + 1] = ""
    out[#out + 1] = Format.headerLine({ rule = rule, radius = radius })
    for _, line in ipairs(atmo) do
        out[#out + 1] = line == "" and "#@" or (Format.ATMO_PREFIX .. line)
    end

    return out, {
        kept = kept,
        converted = converted,
        pool = #plan.objects,
        freeIds = #free,
        collidable = #colliders,
        atmoObjects = colliderStats.total,
        skipped = colliderStats.skipped,
        groups = plan.groups,
    }
end

NS.Builder = Builder
return Builder
