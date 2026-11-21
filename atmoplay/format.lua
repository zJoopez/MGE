-- The playable-mod format (docs/atmo-play-plan.md). A playable mod is an ordinary .tbm with:
--   * pool objects: hidden static env_obj blocks with a POOL_MARKER comment line
--   * with dynamic props (dynamics.lua, proof of concept): hidden dynamic env_obj blocks on ids 1-48 with a
--     DYNAMIC_MARKER line, and one hidden static parking platform with a PARK_MARKER line
--   * a header line, "#atmoplay v1 rule=1 radius=4": format version and the pool rule's parameters
--     (dradius=2: the props' reach)
--   * after the header, the atmo: every atmo line behind ATMO_PREFIX ("#@ ")
-- The game skips every "#" line of a mod, and its atmo parser only reads lines starting with shader,
-- shaderopt, opt and env_obj, so neither sees the atmo part (measured: a 5k-object atmo as "#@ " lines
-- doesn't slow /lm down and adds no objects).

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

---@class AtmoPlayHeader
---@field version integer format version (the v in "#atmoplay v1")
---@field rule integer? pool rule number (Pool.RULES)
---@field radius number? pool reach from a player's center
---@field dradius number? dynamic props' reach (dynamics.lua)

---@class AtmoPlayPoolObject
---@field id integer the env_obj id as the file writes it (1-based; the game's object id is id - 1)
---@field shape string the shape line's first word, as written
---@field friction string? the friction line as written, nil without one
---@field hardness string? the hardness line as written, nil without one
---@field pos string? the pos line as written (the dynamic pool's parking spot)
---@field sides string? the sides line as written (the dynamic pool's own size: no resize for props of it)
---@field mass string? the mass line as written
---@field bounce string? the bounce line as written

---@class AtmoPlayModFile
---@field header AtmoPlayHeader? nil when the mod isn't playable
---@field atmo string[] the atmo lines, ATMO_PREFIX removed
---@field pool AtmoPlayPoolObject[] pool objects in file order
---@field dynamic AtmoPlayPoolObject[] the dynamic pool (props), in file order
---@field park integer? the parking platform's id

---@class AtmoPlayFormat
local Format = {
    VERSION = 1,
    POOL_MARKER = "#atmoplay pool",
    DYNAMIC_MARKER = "#atmoplay dynamic",
    PARK_MARKER = "#atmoplay park",
    NOTE = "#atmoplay note: a playable atmo map, needs the Atmo Play script (without it nothing in the atmo is solid)",
    ATMO_PREFIX = "#@ ",
}

-- words that start a new section of a mod file (as in MGE's file_handler.lua): a block ends at the next one
local SECTION_WORDS = {
    gamerule = true,
    body = true,
    joint = true,
    player = true,
    env_obj = true,
    env_obj_joint = true,
}

---@param line string
---@return boolean
function Format.isSectionStart(line)
    local word = line:match("^%s*(%S+)")
    return word ~= nil and SECTION_WORDS[word] == true
end

---Lines Atmo Play writes and rebuilds: the header, the note, pool markers and atmo lines
---@param line string
---@return boolean
function Format.isOwnLine(line)
    return line:match("^%s*#atmoplay") ~= nil or line:match("^#@") ~= nil
end

---@param params { rule: integer?, radius: number?, dradius: number? }
---@return string
function Format.headerLine(params)
    local parts = { "#atmoplay v" .. Format.VERSION }
    if params.rule then parts[#parts + 1] = "rule=" .. params.rule end
    if params.radius then parts[#parts + 1] = "radius=" .. params.radius end
    if params.dradius then parts[#parts + 1] = "dradius=" .. params.dradius end
    return table.concat(parts, " ")
end

---@param line string a block's line, trimmed
---@return "pool"|"dynamic"|"park"|nil the marker it is
local function markerOf(line)
    if line == Format.POOL_MARKER then return "pool" end
    if line == Format.DYNAMIC_MARKER then return "dynamic" end
    if line == Format.PARK_MARKER then return "park" end
    return nil
end

---@param line string
---@return AtmoPlayHeader?
function Format.parseHeader(line)
    local version, rest = line:match("^#atmoplay v(%d+)(.*)$")
    if not version then return nil end
    local header = { version = tonumber(version) }
    for key, value in rest:gmatch("(%w+)=(%S+)") do
        header[key] = tonumber(value) or value
    end
    return header
end

---Reads a mod's lines: its header, atmo and pool objects
---@param lines string[]
---@return AtmoPlayModFile
function Format.read(lines)
    local result = { header = nil, atmo = {}, pool = {}, dynamic = {}, park = nil }
    local block = nil -- the env_obj block being read: { id, props, marked = marker kind }
    local function closeBlock()
        if block and block.marked then
            local object = { id = block.id, shape = block.props.shape or "box", friction = block.props.friction,
                hardness = block.props.hardness, pos = block.props.pos, sides = block.props.sides,
                mass = block.props.mass, bounce = block.props.bounce }
            if block.marked == "pool" then
                result.pool[#result.pool + 1] = object
            elseif block.marked == "dynamic" then
                result.dynamic[#result.dynamic + 1] = object
            else
                result.park = block.id
            end
        end
        block = nil
    end
    for _, raw in ipairs(lines) do
        local line = raw:gsub("\r$", "")
        if result.header then
            local atmoLine = line:match("^#@ ?(.*)$")
            if atmoLine then result.atmo[#result.atmo + 1] = atmoLine end
        else
            local header = Format.parseHeader(line)
            if header then
                closeBlock()
                result.header = header
            elseif Format.isSectionStart(line) then
                closeBlock()
                local id = line:match("^%s*env_obj%s+(%d+)")
                if id then block = { id = tonumber(id), props = {}, marked = false } end
            elseif block then
                local trimmed = line:match("^%s*(.-)%s*$")
                local marker = markerOf(trimmed)
                if marker then
                    block.marked = marker
                else
                    local key, value = trimmed:match("^([%a_]+)%s+(.-)$")
                    if key then block.props[key] = value end
                end
            end
        end
    end
    closeBlock()
    return result
end

---@class AtmoPlaySplit
---@field lines string[] the mod without Atmo Play's lines (note, header, "#@ ") and without the pool blocks
---@field header AtmoPlayHeader? nil: not a playable mod
---@field atmo string[] the atmo lines, ATMO_PREFIX removed
---@field pool integer[] every marked block's env_obj id (pool, dynamic pool, park; as the file writes them)
---@field poolObjects AtmoPlayPoolObject[]? the pool with shapes (Format.read's), added by MGE's Playable.split

---A mod file's lines in parts: what MGE parses and edits as the mod (`lines`), and the parts Atmo Play's
---format adds. Building from `lines` again gives the mod without its pool and atmo
---@param lines string[]
---@return AtmoPlaySplit
function Format.split(lines)
    local result = { lines = {}, header = nil, atmo = {}, pool = {} }
    local i = 1
    while i <= #lines do
        local line = lines[i]:gsub("\r$", "")
        if result.header then
            local atmoLine = line:match("^#@ ?(.*)$")
            if atmoLine then result.atmo[#result.atmo + 1] = atmoLine end
            i = i + 1
        else
            local header = Format.parseHeader(line)
            local id = line:match("^%s*env_obj%s+(%d+)")
            if header then
                result.header = header
                i = i + 1
            elseif id then
                local block, marked = { line }, false
                i = i + 1
                while i <= #lines do
                    local bodyLine = lines[i]:gsub("\r$", "")
                    if Format.isSectionStart(bodyLine) or Format.parseHeader(bodyLine) or bodyLine:match("^#@") then break end
                    if markerOf(bodyLine:match("^%s*(.-)%s*$")) then marked = true end
                    block[#block + 1] = bodyLine
                    i = i + 1
                end
                if marked then
                    result.pool[#result.pool + 1] = tonumber(id)
                else
                    for _, blockLine in ipairs(block) do result.lines[#result.lines + 1] = blockLine end
                end
            else
                if not Format.isOwnLine(line) then result.lines[#result.lines + 1] = line end
                i = i + 1
            end
        end
    end
    return result
end

---The atmo lines the game should draw: entities with "visible 0" (invisible walls and clips, solid but not
---drawn) are left out. Lines before the first entity (shader, shaderopt, opt) are kept
---@param atmoLines string[]
---@return string[]
function Format.drawnLines(atmoLines)
    local out, entity = {}, nil
    local function flush()
        if entity and not entity.hidden then
            for _, line in ipairs(entity.lines) do out[#out + 1] = line end
        end
        entity = nil
    end
    for _, line in ipairs(atmoLines) do
        if line:match("^%s*env_obj%s") then
            flush()
            entity = { lines = { line }, hidden = false }
        elseif entity then
            entity.lines[#entity.lines + 1] = line
            if line:match("^%s*visible%s+0%s*$") then entity.hidden = true end
        else
            out[#out + 1] = line
        end
    end
    flush()
    return out
end

NS.Format = Format
return Format
