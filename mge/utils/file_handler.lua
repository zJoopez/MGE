local FileHandler = {}
MGE.FileHandler = FileHandler

-- Decimals written for computed numbers: 6 is finer than the game's single precision holds (~0.00001 at 50
-- units), keeps MIN_SIDE (0.0001), drifts at most ~0.0000005 an edit, and drops float noise (0.0599999999).
-- 10 wrote ~12% more text on a 5k atmo. "%f", never an exponent
local DECIMALS = 6

---Up to DECIMALS decimals, trailing zeros removed (keeps values like 0.0001)
---@param value number
---@return string
local NUMBER_FORMAT = "%." .. DECIMALS .. "f"
function FileHandler.formatNumber(value)
    -- one match: "%f" always writes the dot (hot on big atmo edits)
    local s = string.format(NUMBER_FORMAT, value):match("^(.-)%.?0*$")
    if s == "-0" then s = "0" end
    return s
end

---@param ... number
---@return string space separated numbers
function FileHandler.formatNumbers(...)
    local parts = {}
    for i, v in ipairs({ ... }) do parts[i] = FileHandler.formatNumber(v) end
    return table.concat(parts, " ")
end

---One line in an object block: a property (key, value in props) or a raw line kept as is (comments)
---@class FileParserLine
---@field key string?
---@field raw string?

---@class FileParserEnvObj
---@field id integer
---@field props table<string, string>
---@field lines FileParserLine[]? original line order, nil for objects made in the editor
---@field selected boolean?
---@field kind string
---@field atmoName string? an atmo object's name in its file, kept for parent lines

---@class FileParserEnvObjJoint
---@field id integer
---@field obj1 integer
---@field obj2 integer
---@field props table<string, string>
---@field lines FileParserLine[]?
---@field selected boolean?
---@field kind string

---@class FileParserResult
---@field env_obj FileParserEnvObj[]
---@field env_obj_joint FileParserEnvObjJoint[]
---@field atmo FileParserEnvObj[]? the atmo layer; ParseMod leaves it empty. Ids are list indexes
---@field ignores string[] lines before the first object (comments, gamerule, body, joint...)
---@field trailer string[]? non-object lines after the first object (usually player sections)
---@field sharedPlayers integer? see FileHandler.splitSharedPlayers
---@field playable PlayableParams? a playable atmo mod: Save writes the playable form

local indent = "   "

-- first words that start a section; indentation ignored (some mods indent headers)
local SECTION_WORDS = {
    gamerule = true,
    body = true,
    joint = true,
    player = true,
    env_obj = true,
    env_obj_joint = true,
}

-- write order for props not in an object's original lines
local KEY_ORDER = {
    "shape", "pos", "rot", "sides", "color", "flag", "material", "mass", "bounce", "friction",
    "force", "hardness", "visible", "thrust", "model_name", "use_model",
}
local KEY_RANK = {}
for i, key in ipairs(KEY_ORDER) do KEY_RANK[key] = i end

-- legacy comment line from old MGE versions, dropped on read
local FRAME_TAG = "#mge_frame"

---@param line string
---@return string?
local function firstWord(line)
    return line:match("^%s*(%S+)")
end

---@param line string
---@return "env_obj"|"env_obj_joint"|nil
local function getBlockKind(line)
    local word = firstWord(line)
    if (word == "env_obj" or word == "env_obj_joint") and line:match("^%s*%S+%s+%d") then
        return word
    end
end

---@param line string
---@return boolean
local function isSectionHeader(line)
    return SECTION_WORDS[firstWord(line) or ""] == true
end

---Removes trailing blank lines, else every save adds one (readAll drops the last empty line)
---@param list string[]
local function trimTrailingBlank(list)
    while #list > 0 and list[#list]:match("^%s*$") do
        table.remove(list)
    end
end

---@param path string
---@return string[]? lines, nil when it can't be read
function FileHandler.readLines(path)
    local file = Files.Open(path, FILES_MODE_READONLY)
    if not file or not file.data then return nil end
    local lines = file:readAll()
    file:close()
    return lines
end

---Writes text to a file (a newline added at the end)
---@param path string
---@param text string
---@return boolean written
function FileHandler.writeText(path, text)
    local file = Files.Open(path, FILES_MODE_WRITE)
    if not file or not file.data then return false end
    file:writeLine(text)
    file:close()
    return true
end

---@param path string
---@return FileParserResult
function FileHandler.ParseMod(path)
    return FileHandler.parseLines(FileHandler.readLines(path) or {})
end

---@param lines string[]
---@return FileParserResult
function FileHandler.parseLines(lines)
    ---@type FileParserResult
    local parser = {
        env_obj = {},
        env_obj_joint = {},
        atmo = {},
        ignores = {},
        trailer = {},
    }

    local seenObject = false
    local i = 1
    while i <= #lines do
        local line = lines[i]
        local kind = getBlockKind(line)

        if kind then
            seenObject = true
            local block = { kind = kind, header = line, lines = {} }
            i = i + 1

            while i <= #lines and not isSectionHeader(lines[i]) do
                if not lines[i]:match("^%s*$") then
                    table.insert(block.lines, lines[i])
                end
                i = i + 1
            end

            local obj = FileHandler.parseBlock(block)
            if kind == "env_obj" then
                table.insert(parser.env_obj, obj)
            else
                table.insert(parser.env_obj_joint, obj)
            end
        else
            -- sections after objects (player 0/1...) stay after them
            table.insert(seenObject and parser.trailer or parser.ignores, line)
            i = i + 1
        end
    end

    trimTrailingBlank(parser.trailer)
    if #parser.env_obj == 0 and #parser.env_obj_joint == 0 then
        trimTrailingBlank(parser.ignores)
    end
    return parser
end

function FileHandler.parseBlock(block)
    ---@type FileParserEnvObj|FileParserEnvObjJoint
    local obj = { kind = block.kind, props = {}, lines = {} }

    if block.kind == "env_obj" then
        obj.id = tonumber(block.header:match("env_obj%s+(%d+)")) or 0
    elseif block.kind == "env_obj_joint" then
        local a, b, c = block.header:match("env_obj_joint%s+(%d+)%s+(%d+)%s+(%d+)")
        obj.id = tonumber(a) or 0
        obj.obj1 = tonumber(b) or 0
        obj.obj2 = tonumber(c) or 0
    end

    for _, line in ipairs(block.lines or {}) do
        local key, value = line:match("^%s*(%S+)%s*(.-)%s*$")
        if key and key:match("^[%a_]") then
            -- duplicate keys: later value wins, first position stays
            if obj.props[key] == nil then table.insert(obj.lines, { key = key }) end
            obj.props[key] = value
        elseif key == FRAME_TAG then
            -- dropped
        else
            -- comments and other non-property lines stay in place
            table.insert(obj.lines, { raw = (line:gsub("^%s+", ""):gsub("%s+$", "")) })
        end
    end

    return obj
end

---@param obj FileParserEnvObj|FileParserEnvObjJoint
local function buildHeader(obj)
    if not obj then return "" end
    if obj.kind == "env_obj_joint" then
        return string.format("%s %d %d %d", obj.kind, obj.id or 0, obj.obj1 or 0, obj.obj2 or 0)
    end
    return string.format("%s %d", obj.kind, obj.id or 0)
end

---@type table<table, fun(a: string, b: string): boolean> sort comparators by rank table
local rankOrders = setmetatable({}, { __mode = "k" })

---Appends an object's indented lines to out: props in original order, then the rest by rank, then name
---@param out string[]
---@param obj FileParserEnvObj|FileParserEnvObjJoint
---@param rank table<string, integer>? default KEY_RANK
---@param fileKey (fun(key: string): string)? the name a key is written as
function FileHandler.appendObjectLines(out, obj, rank, fileKey)
    rank = rank or KEY_RANK
    local props = obj.props or {}
    local written = {}
    for _, entry in ipairs(obj.lines or {}) do
        local key = entry.key
        if entry.raw then
            out[#out + 1] = indent .. entry.raw
        elseif key and props[key] ~= nil and not written[key] then
            written[key] = true
            out[#out + 1] = indent .. (fileKey and fileKey(key) or key) .. " " .. props[key]
        end
    end
    local rest = {}
    for key in pairs(props) do
        if not written[key] then rest[#rest + 1] = key end
    end
    if #rest > 1 then
        local order = rankOrders[rank]
        if not order then
            order = function(a, b)
                local ra, rb = rank[a] or math.huge, rank[b] or math.huge
                if ra ~= rb then return ra < rb end
                return a < b
            end
            rankOrders[rank] = order
        end
        table.sort(rest, order)
    end
    for _, key in ipairs(rest) do
        out[#out + 1] = indent .. (fileKey and fileKey(key) or key) .. " " .. props[key]
    end
end

---@param file File
---@param obj FileParserEnvObj|FileParserEnvObjJoint
local function writeObjectLines(file, obj)
    local out = {}
    FileHandler.appendObjectLines(out, obj)
    for _, line in ipairs(out) do file:writeLine(line) end
end

---@param file File
---@param objects FileParserEnvObj[] | FileParserEnvObjJoint[]
local function writeParsedEnvObj(file, objects)
    for _, obj in ipairs(objects or {}) do
        local header = buildHeader(obj)
        if header ~= "" then
            file:writeLine(header)
        end
        writeObjectLines(file, obj)
        file:writeLine("")
    end
end

-- section words that belong inside a player section
local PLAYER_PART_WORDS = { body = true, joint = true }

---Last line of the player section starting at lines[first]
---@param lines string[]
---@param first integer
---@return integer
local function sectionLast(lines, first)
    local last = first
    for j = first + 1, #lines do
        local l = lines[j]
        if not l:match("^%s*$") then
            local word = firstWord(l) or ""
            if not l:match("^%s") or (SECTION_WORDS[word] and not PLAYER_PART_WORDS[word]) then break end
            last = j
        end
    end
    return last
end

---@param line string
---@return integer? N of a `player N` header line
local function playerHeaderId(line)
    return tonumber(line:match("^%s*player%s+(%d+)%s*$"))
end

---Line range of a `player N` section: it ends at an unindented line or another non-part section header
---@param lines string[]
---@param playerId integer? nil finds the first
---@return integer? first header line
---@return integer? last
---@return integer? playerId of the found section
local function findPlayerSection(lines, playerId)
    for i, line in ipairs(lines) do
        local id = playerHeaderId(line)
        if id and (playerId == nil or id == playerId) then
            return i, sectionLast(lines, i), id
        end
    end
    return nil, nil, nil
end

---Player sections can be in ignores or trailer
local PLAYER_LISTS = { "ignores", "trailer" }

---A player section's lines without its header
---@param parser FileParserResult
---@param playerId integer? nil takes the first
---@return string[]? nil without such a section (default body)
---@return integer? playerId of the found section
function FileHandler.getPlayerLines(parser, playerId)
    for _, key in ipairs(PLAYER_LISTS) do
        local list = parser[key] or {}
        local first, last, id = findPlayerSection(list, playerId)
        if first then
            local lines = {}
            for i = first + 1, last do table.insert(lines, list[i]) end
            return lines, id
        end
    end
    return nil, nil
end

---Calls visit(line, part) for each line: part is "head" for a body/joint header outside player sections
---(shared parts, e.g. fatkido.tbm), "body" for the lines under it, nil otherwise
---@param list string[]
---@param visit fun(line: string, part: "head"|"body"|nil)
local function scanSharedParts(list, visit)
    local inPlayer, inPart = false, false
    for _, line in ipairs(list) do
        local word = firstWord(line)
        local part = nil
        if word then
            -- same end rule as sectionLast
            if inPlayer and (not line:match("^%s") or (SECTION_WORDS[word] and not PLAYER_PART_WORDS[word])) then
                inPlayer = false
            end
            if word == "player" then
                inPlayer, inPart = true, false
            elseif not inPlayer and PLAYER_PART_WORDS[word] then
                inPart, part = true, "head"
            elseif SECTION_WORDS[word] or inPlayer then
                inPart = false
            elseif inPart then
                part = "body"
            end
        end
        visit(line, part)
    end
end

---Shared body/joint parts, which apply to all players. Indented like a player section
---@param parser FileParserResult
---@return string[]? nil when there are none
function FileHandler.getSharedPlayerLines(parser)
    local parts = {}
    for _, key in ipairs(PLAYER_LISTS) do
        scanSharedParts(parser[key] or {}, function(line, part)
            if part then
                parts[#parts + 1] = (part == "head" and indent or indent .. indent) .. (line:gsub("^%s+", ""))
            end
        end)
    end
    return #parts > 0 and parts or nil
end

---Replaces a player section's parts, or adds the section after the objects.
---ignores/trailer are replaced, not modified: history states share them
---@param parser FileParserResult
---@param playerId integer
---@param parts string[] lines after the header
function FileHandler.setPlayerLines(parser, playerId, parts)
    for _, key in ipairs(PLAYER_LISTS) do
        local list = parser[key] or {}
        local first, last = findPlayerSection(list, playerId)
        if first then
            local lines = {}
            for i = 1, first do table.insert(lines, list[i]) end
            for _, line in ipairs(parts) do table.insert(lines, line) end
            for i = last + 1, #list do table.insert(lines, list[i]) end
            parser[key] = lines
            return
        end
    end
    local lines = {}
    for _, line in ipairs(parser.trailer or {}) do table.insert(lines, line) end
    if #lines > 0 then table.insert(lines, "") end
    table.insert(lines, "player " .. playerId)
    for _, line in ipairs(parts) do table.insert(lines, line) end
    parser.trailer = lines
end

---Renumbers player sections: map[old] = new id, false removes the section (and a blank before it).
---Shared parts are untouched. ignores/trailer are replaced, not modified
---@param parser FileParserResult
---@param map table<integer, integer|false>
function FileHandler.renumberPlayers(parser, map)
    for _, key in ipairs(PLAYER_LISTS) do
        local list = parser[key]
        if list then
            local lines, i = {}, 1
            while i <= #list do
                local line = list[i]
                local id = playerHeaderId(line)
                if id and map[id] == false then
                    if #lines > 0 and lines[#lines]:match("^%s*$") then table.remove(lines) end
                    i = sectionLast(list, i) + 1
                    if #lines == 0 then -- it was first: drop the blanks after it instead
                        while list[i] and list[i]:match("^%s*$") do i = i + 1 end
                    end
                else
                    if id and map[id] then line = line:gsub("(player%s+)%d+", "%1" .. map[id], 1) end
                    table.insert(lines, line)
                    i = i + 1
                end
            end
            parser[key] = lines
        end
    end
end

---The list without the shared parts getSharedPlayerLines collects
---@param list string[]
---@return string[]
local function withoutSharedParts(list)
    local out = {}
    scanSharedParts(list, function(line, part)
        if not part then out[#out + 1] = line end
    end)
    return out
end

---A player section's lines grouped by body / joint header
---@param lines string[]
---@return { key: string, lines: string[] }[]
local function partsOf(lines)
    local parts = {}
    for _, line in ipairs(lines) do
        local word = firstWord(line)
        if word and PLAYER_PART_WORDS[word] then
            parts[#parts + 1] = { key = line:gsub("^%s+", ""):gsub("%s+$", ""), lines = { line } }
        elseif parts[#parts] then
            table.insert(parts[#parts].lines, line)
        end
    end
    return parts
end

-- the version the game's modmaker writes
FileHandler.MOD_VERSION = 15

---Adds `version MOD_VERSION` (after a "#!" line) to a mod without one: unversioned mods are read the old
---way, where engageplayerrot does nothing. ignores is replaced, not modified
---@param parser FileParserResult
---@return boolean added
function FileHandler.ensureVersion(parser)
    for _, key in ipairs(PLAYER_LISTS) do
        for _, line in ipairs(parser[key] or {}) do
            if line:match("^%s*version%s+%d+") then return false end
        end
    end
    local old, lines = parser.ignores or {}, {}
    local at = (old[1] and old[1]:match("^#!")) and 2 or 1
    for i = 1, at - 1 do lines[#lines + 1] = old[i] end
    lines[#lines + 1] = "version " .. FileHandler.MOD_VERSION
    for i = at, #old do lines[#lines + 1] = old[i] end
    parser.ignores = lines
    return true
end

---Shared body/joint parts (fatkido.tbm) become every player's own section, so each model is edited on its
---own (own parts win per body part / joint). sharedPlayers remembers it: written back shared while all
---models are still the same (collapsedShared)
---@param parser FileParserResult
---@param playerCount integer
function FileHandler.splitSharedPlayers(parser, playerCount)
    local shared = FileHandler.getSharedPlayerLines(parser)
    if not shared then return end
    for _, key in ipairs(PLAYER_LISTS) do
        if parser[key] then parser[key] = withoutSharedParts(parser[key]) end
    end
    for id = 0, playerCount - 1 do
        local own = FileHandler.getPlayerLines(parser, id)
        local lines = {}
        if own then
            local ownParts, taken = partsOf(own), {}
            for _, part in ipairs(ownParts) do taken[part.key] = true end
            for _, part in ipairs(partsOf(shared)) do
                if not taken[part.key] then
                    for _, line in ipairs(part.lines) do lines[#lines + 1] = line end
                end
            end
            for _, part in ipairs(ownParts) do
                for _, line in ipairs(part.lines) do lines[#lines + 1] = line end
            end
        else
            for i, line in ipairs(shared) do lines[i] = line end
        end
        FileHandler.setPlayerLines(parser, id, lines)
    end
    parser.sharedPlayers = playerCount
end

---For a mod that came with shared parts: while every player section is the same, one copy as shared
---parts instead of the sections; else nil
---@param parser FileParserResult
---@return string[]? ignores, string[]? trailer
local function collapsedShared(parser)
    if not parser.sharedPlayers then return nil, nil end
    local first, ids = nil, {}
    for _, key in ipairs(PLAYER_LISTS) do
        for _, line in ipairs(parser[key] or {}) do
            local id = playerHeaderId(line)
            if id then ids[#ids + 1] = id end
        end
    end
    -- every player needs a section: a player reset to the default body would get the model back
    if #ids == 0 or #ids < (tonumber(parser.sharedPlayers) or 0) then return nil, nil end
    for _, id in ipairs(ids) do
        local text = table.concat(FileHandler.getPlayerLines(parser, id) or {}, "\n")
        if first == nil then first = text elseif text ~= first then return nil, nil end
    end
    local model = FileHandler.getPlayerLines(parser, ids[1]) or {}
    local copy = { ignores = parser.ignores, trailer = parser.trailer }
    local map = {}
    for _, id in ipairs(ids) do map[id] = false end
    FileHandler.renumberPlayers(copy, map)
    local trailer = {}
    for _, line in ipairs(copy.trailer or {}) do trailer[#trailer + 1] = line end
    if #trailer > 0 and not trailer[#trailer]:match("^%s*$") then trailer[#trailer + 1] = "" end
    -- indented as in a section, like fatkido.tbm
    for _, line in ipairs(model) do trailer[#trailer + 1] = line end
    return copy.ignores, trailer
end

-- numplayers goes first: the game reads per-player lists (engageplayerpos...) for that many players,
-- so a later numplayers misreads them
local FIRST_RULE = "numplayers"

---Writes gamerule values into the `gamerule` section (adding it if missing): existing lines are updated,
---missing ones appended, numplayers moved first. ignores/trailer are replaced, not modified
---@param parser FileParserResult
---@param values table<string, string> rules to write
---@param ruleNames table<string, any> every gamerule name, tells rule lines from what follows the section
function FileHandler.setGamerules(parser, values, ruleNames)
    local pending = {}
    for name in pairs(values) do table.insert(pending, name) end
    table.sort(pending, function(a, b)
        if (a == FIRST_RULE) ~= (b == FIRST_RULE) then return a == FIRST_RULE end
        return a < b
    end)

    for _, key in ipairs(PLAYER_LISTS) do
        local list = parser[key] or {}
        local header
        for i, line in ipairs(list) do
            if firstWord(line) == "gamerule" then header = i break end
        end
        if header then
            local lines, last = {}, header
            for i = 1, header do table.insert(lines, list[i]) end
            local written = {}
            local firstLine -- the numplayers line, put right after the header at the end
            local i = header + 1
            while i <= #list do
                local line = list[i]
                local word = firstWord(line)
                -- the section ends at another section or an unindented non-rule. Indented unknown words
                -- (engagespace) are still rules, else a duplicate line would shadow the update
                local comment = word and (word:match("^#") or word:match("^//"))
                if word and not comment and (SECTION_WORDS[word] and word ~= "gamerule"
                    or (not ruleNames[word] and not line:match("^%s"))) then break end
                if word and values[word] ~= nil then
                    line = line:match("^(%s*)") .. word .. " " .. values[word]
                    written[word] = true
                end
                if word == FIRST_RULE and not firstLine then
                    firstLine = line
                else
                    table.insert(lines, line)
                    if word then last = #lines end
                end
                i = i + 1
            end
            -- new rules after the last rule line, blanks stay after them
            local added = {}
            for _, name in ipairs(pending) do
                if not written[name] then
                    local line = indent .. name .. " " .. values[name]
                    if name == FIRST_RULE then firstLine = line else table.insert(added, line) end
                end
            end
            for n, line in ipairs(added) do table.insert(lines, last + n, line) end
            if firstLine then table.insert(lines, header + 1, firstLine) end
            for j = i, #list do table.insert(lines, list[j]) end
            parser[key] = lines
            return
        end
    end

    local lines = {}
    for _, line in ipairs(parser.ignores or {}) do table.insert(lines, line) end
    table.insert(lines, "gamerule")
    for _, name in ipairs(pending) do table.insert(lines, indent .. name .. " " .. values[name]) end
    parser.ignores = lines
end

---Writes the mod through file:writeLine (a File, or modText's collector). Atmo objects aren't written
---@param file { writeLine: fun(self, line: string) }
---@param parser FileParserResult
local function writeParser(file, parser)
    local ignores, trailer = collapsedShared(parser)
    if ignores then parser = { ignores = ignores, trailer = trailer, env_obj = parser.env_obj,
        env_obj_joint = parser.env_obj_joint } end
    for _, line in ipairs(parser.ignores or {}) do
        file:writeLine(line)
    end

    writeParsedEnvObj(file, parser.env_obj or {})
    writeParsedEnvObj(file, parser.env_obj_joint or {})

    for _, line in ipairs(parser.trailer or {}) do
        file:writeLine(line)
    end
end

---@param parser FileParserResult
---@param path string
---@return boolean
function FileHandler.WriteMod(parser, path)
    local file = Files.Open(path, FILES_MODE_WRITE)
    if not file or not file.data then return false end
    ---@diagnostic disable-next-line: param-type-mismatch
    writeParser(file, parser)
    file:close()
    return true
end

---The mod as WriteMod would write it (for unsaved-changes checks)
---@param parser FileParserResult
---@return string
function FileHandler.modText(parser)
    local lines = {}
    writeParser({ writeLine = function(_, line) table.insert(lines, line) end }, parser)
    return table.concat(lines, "\n")
end
