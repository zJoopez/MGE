-- Removes the comments from a Lua 5.1 file for the release zip (tools/package.ps1):
--
--   lua5.1 tools/strip_comments.lua in.lua out.lua
--
-- Lines that only held comments go, and so do the lines inside long comments: no gaps where the comments
-- were. Blank lines the source had are kept, at most one in a row (the gaps between functions). So the
-- release's line numbers aren't the source's: an error from a release names a line of the stripped file.
-- Strings and long strings are copied as they are, their lines untouched (a "--" inside one isn't a
-- comment, a blank line inside one is part of it). Trailing spaces go, outside strings.
-- package.ps1 checks the result: `luac -s` (no line info) of both must give the same bytes, which only
-- holds when nothing but comments and spacing changed.
local inPath, outPath = arg[1], arg[2]
if not inPath or not outPath then
    io.stderr:write("usage: lua5.1 tools/strip_comments.lua in.lua out.lua\n")
    os.exit(2)
end

local f = assert(io.open(inPath, "rb"))
local src = f:read("*a"):gsub("\r\n", "\n")
f:close()

local out = {}
local i, n = 1, #src
local line = 1 -- the source line at i
local inString = {} -- lines whose content belongs to a string spanning lines: copied untouched
local inComment = {} -- lines a comment took up (empty after stripping: they go)

---Level of a long bracket opening at position p ("[[" 0, "[=[" 1...), nil when there's none
local function longOpen(p)
    local eq = src:match("^%[(=*)%[", p)
    return eq and #eq or nil
end

---Position just after the long bracket of `level` closing from p on, or the end
local function longClose(p, level)
    local close = "]" .. string.rep("=", level) .. "]"
    local s, e = src:find(close, p, true)
    if not s then error(inPath .. ": unfinished long string or comment") end
    return e + 1
end

---Counts the newlines of src from a to b, marks the lines after the first in `marks`, moves `line` on
local function span(a, b, marks)
    local first = line
    for _ in src:sub(a, b):gmatch("\n") do line = line + 1 end
    if marks then
        for l = first + 1, line do marks[l] = true end
    end
    return first
end

while i <= n do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i + 1, i + 1) == "-" then
        -- a comment: long ("--[[", "--[==[") keeps only its newlines, a line comment goes up to its newline
        local level = longOpen(i + 2)
        local after
        if level then
            after = longClose(i + 2 + level + 2, level)
            local _, newlines = src:sub(i, after - 1):gsub("\n", "")
            out[#out + 1] = string.rep("\n", newlines)
        else
            after = src:find("\n", i, true) or n + 1 -- the newline itself is copied by the next pass
        end
        inComment[span(i, after - 1, inComment)] = true
        i = after
    elseif c == '"' or c == "'" then
        -- a quoted string, escapes skipped over (\" doesn't end it, a \ before a newline continues it)
        local j = i + 1
        while j <= n do
            local d = src:sub(j, j)
            if d == "\\" then
                j = j + 2
            elseif d == c then
                break
            elseif d == "\n" then
                error(inPath .. ": unfinished string")
            else
                j = j + 1
            end
        end
        out[#out + 1] = src:sub(i, j)
        span(i, j, inString)
        i = j + 1
    elseif c == "[" and longOpen(i) then
        local level = longOpen(i)
        local after = longClose(i + level + 2, level)
        out[#out + 1] = src:sub(i, after - 1)
        span(i, after - 1, inString)
        i = after
    else
        -- plain code up to the next character that could start a comment or a string
        local j = src:find("[%-\"'%[]", i + 1) or n + 1
        out[#out + 1] = src:sub(i, j - 1)
        span(i, j - 1)
        i = j
    end
end

-- line by line: the stripped text has the source's lines (comments kept their newlines)
local kept, blank = {}, true -- blank: the last kept line is empty (also at the start: no leading blanks)
local number = 0
for text in (table.concat(out) .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    if inString[number] then
        kept[#kept + 1] = text
        blank = false
    else
        text = text:gsub("[ \t]+$", "")
        if text ~= "" then
            kept[#kept + 1] = text
            blank = false
        elseif not inComment[number] and not blank then
            kept[#kept + 1] = "" -- a blank line of the source, one in a row
            blank = true
        end
    end
end
while kept[#kept] == "" do kept[#kept] = nil end

local o = assert(io.open(outPath, "wb"))
o:write(table.concat(kept, "\n") .. "\n")
o:close()
