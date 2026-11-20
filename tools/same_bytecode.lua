-- Compares two Lua 5.1 bytecode files (luac -s output) ignoring where the functions are in the source:
--
--   lua5.1 tools/same_bytecode.lua a.luac b.luac      exit 0 when the code is the same, 1 when it isn't
--
-- tools/package.ps1 checks stripped files with it (tools/strip_comments.lua). `luac -s` drops the debug
-- info (line numbers per instruction, local names), but every function's header still holds the source
-- lines it starts and ends at (linedefined, lastlinedefined). Removing comment lines moves those, so the
-- files' bytes differ although the code doesn't. This reads both chunks (the Lua 5.1 format, lundump.c)
-- and compares everything but those two numbers: instructions, constants, nested functions, sizes.
local pathA, pathB = arg[1], arg[2]
if not pathA or not pathB then
    io.stderr:write("usage: lua5.1 tools/same_bytecode.lua a.luac b.luac\n")
    os.exit(2)
end

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

---A Lua 5.1 chunk with its functions' line fields zeroed: what's left is the code
---@param s string the chunk's bytes
---@return string
local function normalized(s)
    local pos = 1
    local out = {}
    local function take(count)
        local bytes = s:sub(pos, pos + count - 1)
        if #bytes < count then error("truncated chunk") end
        pos = pos + count
        return bytes
    end
    -- header: ESC "Lua" version format endianness sizeof(int) sizeof(size_t) sizeof(Instruction)
    -- sizeof(lua_Number) integral flag
    local header = take(12)
    if header:sub(1, 4) ~= "\27Lua" or header:byte(5) ~= 0x51 then error("not a Lua 5.1 chunk") end
    local little = header:byte(7) == 1
    local sizeInt, sizeSize, sizeInstr, sizeNumber = header:byte(8), header:byte(9), header:byte(10), header:byte(11)
    out[#out + 1] = header

    local function readInt(size)
        local bytes = take(size)
        local value, mult = 0, 1
        for k = 1, size do
            local b = little and bytes:byte(k) or bytes:byte(size - k + 1)
            value = value + b * mult
            mult = mult * 256
        end
        return value, bytes
    end
    local function copyInt(size)
        local value, bytes = readInt(size)
        out[#out + 1] = bytes
        return value
    end
    local function copyString()
        local size = copyInt(sizeSize)
        if size > 0 then out[#out + 1] = take(size) end
    end

    local function func()
        copyString() -- source name ("=?" with -s)
        readInt(sizeInt) -- linedefined: ignored
        readInt(sizeInt) -- lastlinedefined: ignored
        out[#out + 1] = take(4) -- nups, numparams, is_vararg, maxstacksize
        local code = copyInt(sizeInt)
        out[#out + 1] = take(code * sizeInstr)
        local constants = copyInt(sizeInt)
        for _ = 1, constants do
            local kind = take(1)
            out[#out + 1] = kind
            local t = kind:byte()
            if t == 1 then
                out[#out + 1] = take(1) -- boolean
            elseif t == 3 then
                out[#out + 1] = take(sizeNumber) -- number
            elseif t == 4 then
                copyString()
            elseif t ~= 0 then
                error("unknown constant type " .. t)
            end
        end
        local protos = copyInt(sizeInt)
        for _ = 1, protos do func() end
        -- debug info (empty after -s, compared all the same): line info, locals, upvalue names
        local lines = copyInt(sizeInt)
        out[#out + 1] = take(lines * sizeInt)
        local locals = copyInt(sizeInt)
        for _ = 1, locals do
            copyString()
            copyInt(sizeInt)
            copyInt(sizeInt)
        end
        local upvalues = copyInt(sizeInt)
        for _ = 1, upvalues do copyString() end
    end
    func()
    if pos <= #s then error("bytes after the chunk") end
    return table.concat(out)
end

local ok, a = pcall(normalized, read(pathA))
local okB, b = pcall(normalized, read(pathB))
if not ok or not okB then
    io.stderr:write("can't read bytecode: " .. tostring(ok and b or a) .. "\n")
    os.exit(2)
end
os.exit(a == b and 0 or 1)
