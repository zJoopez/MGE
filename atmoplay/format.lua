-- The playable-mod format (docs/atmo-play-plan.md): an ordinary .tbm with marked pool objects (hidden static
-- POOL_MARKER blocks; with props also dynamic ones on ids 1-48 and a parking platform), a header line
-- ("#atmoplay v1 rule=1 radius=4", or "mode=draw" for drawn-only mods), then the atmo as "#@ " lines,
-- which neither the mod loader nor the atmo parser reads

local NS = ATMOPLAY_LOADING

---@class AtmoPlayHeader
---@field version integer format version (the v in "#atmoplay v1")
---@field rule integer? Pool.RULES
---@field radius number? pool reach from a player's center
---@field dradius number? props' reach
---@field mode string? "draw": the atmo is only drawn

---@class AtmoPlayPoolObject
---@field id integer the env_obj id as written (the game's object id is id - 1)
---@field shape string
---@field friction string? lines as written, nil without them
---@field hardness string?
---@field pos string? the dynamic pool's parking spot
---@field sides string? the dynamic pool's own size
---@field mass string?
---@field bounce string?
---@field flag string?

---@class AtmoPlayModFile
---@field header AtmoPlayHeader? nil when the mod isn't playable
---@field atmo string[] the atmo lines, ATMO_PREFIX removed
---@field pool AtmoPlayPoolObject[] in file order
---@field dynamic AtmoPlayPoolObject[] the props' pool, in file order
---@field park integer? the parking platform's id

---@class AtmoPlayFormat
local Format = {
    VERSION = 1,
    POOL_MARKER = "#atmoplay pool",
    DYNAMIC_MARKER = "#atmoplay dynamic",
    PARK_MARKER = "#atmoplay park",
    NOTE = "#atmoplay note: a playable atmo map, needs the Atmo Play script (without it nothing in the atmo is solid)",
    DRAW_NOTE = "#atmoplay note: this mod's atmo is in its #@ lines, drawn by the Atmo Play script (MGE exports it as an .atmo file)",
    DRAW_MODE = "draw",
    ATMO_PREFIX = "#@ ",
}

-- words that start a section of a mod file: a block ends at the next one
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

---Lines Atmo Play writes: header, note, markers and atmo lines
---@param line string
---@return boolean
function Format.isOwnLine(line)
    return line:match("^%s*#atmoplay") ~= nil or line:match("^#@") ~= nil
end

---@param params { rule: integer?, radius: number?, dradius: number?, mode: string? }
---@return string
function Format.headerLine(params)
    local parts = { "#atmoplay v" .. Format.VERSION }
    if params.mode then parts[#parts + 1] = "mode=" .. params.mode end
    if params.rule then parts[#parts + 1] = "rule=" .. params.rule end
    if params.radius then parts[#parts + 1] = "radius=" .. params.radius end
    if params.dradius then parts[#parts + 1] = "dradius=" .. params.dradius end
    return table.concat(parts, " ")
end

---@param header AtmoPlayHeader?
---@return boolean the atmo only drawn, no pools
function Format.isDrawOnly(header)
    return header ~= nil and header.mode == Format.DRAW_MODE
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
---@return string? an atmo line's text without "#@ ", nil for other lines
local function atmoLineOf(line)
    return line:match("^#@ ?(.*)$")
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
    local block = nil -- { id, props, marked = marker kind }
    local function closeBlock()
        if block and block.marked then
            local object = { id = block.id, shape = block.props.shape or "box", friction = block.props.friction,
                hardness = block.props.hardness, pos = block.props.pos, sides = block.props.sides,
                mass = block.props.mass, bounce = block.props.bounce, flag = block.props.flag }
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
            local atmoLine = atmoLineOf(line)
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
---@field lines string[] the mod without Atmo Play's lines and pool blocks (what MGE edits)
---@field header AtmoPlayHeader? nil: not playable
---@field atmo string[] ATMO_PREFIX removed
---@field pool integer[] every marked block's env_obj id
---@field poolObjects AtmoPlayPoolObject[]? added by MGE's Playable.split

---A mod file's lines in parts: the mod itself and what Atmo Play's format adds
---@param lines string[]
---@return AtmoPlaySplit
function Format.split(lines)
    local result = { lines = {}, header = nil, atmo = {}, pool = {} }
    local i = 1
    while i <= #lines do
        local line = lines[i]:gsub("\r$", "")
        if result.header then
            local atmoLine = atmoLineOf(line)
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

NS.Format = Format
return Format
