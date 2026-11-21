-- Makes a playable mod outside the game (plain Lua 5.1), with tools/atmoplay/builder.lua (MGE's World tab
-- does it in the editor: World > Atmo: Playable):
--
--   lua5.1 mgeDev/tools/atmoplay/build_playable.lua <base.tbm | classic> <atmo.atmo> <out.tbm> [radius]
--
-- "classic" means the game's built-in classic, which has no file (only the pool and the atmo are written).
-- Paths are ordinary file paths. Prints what was kept, converted and pooled.
if not arg then
    echo("^04[Atmo Play] this tool runs outside the game: lua5.1 mgeDev/tools/atmoplay/build_playable.lua")
    return
end

local base, atmo, out, radius = arg[1], arg[2], arg[3], tonumber(arg[4])
if not (base and atmo and out) then
    print("usage: lua5.1 build_playable.lua <base.tbm | classic> <atmo.atmo> <out.tbm> [radius]")
    os.exit(2)
end

local toolDir = arg[0]:match("^(.*[/\\])") or "./"
ATMOPLAY = { scriptPath = toolDir .. "../../atmoplay/" }
for _, path in ipairs({ ATMOPLAY.scriptPath .. "mat3.lua", ATMOPLAY.scriptPath .. "format.lua",
    ATMOPLAY.scriptPath .. "colliders.lua", ATMOPLAY.scriptPath .. "pool.lua", toolDir .. "builder.lua" }) do
    ATMOPLAY_LOADING = ATMOPLAY
    dofile(path)
end
ATMOPLAY_LOADING = nil

local function readLines(path)
    local file = assert(io.open(path, "rb"), "can't read " .. path)
    local text = file:read("*a")
    file:close()
    local lines = {}
    for line in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if lines[#lines] == "" then lines[#lines] = nil end
    return lines
end

local baseLines = base == "classic" and {} or readLines(base)
local lines, stats = ATMOPLAY.Builder.build(baseLines, readLines(atmo), { radius = radius })
if not lines then
    print("not built: " .. tostring(stats))
    os.exit(1)
end
local file = assert(io.open(out, "wb"), "can't write " .. out)
file:write(table.concat(lines, "\n"), "\n")
file:close()

print(string.format("wrote %s: %d lines", out, #lines))
print(string.format("base objects: %d kept as env objects, %d moved into the atmo", stats.kept, stats.converted))
print(string.format("atmo objects: %d, collidable %d", stats.atmoObjects, stats.collidable))
for reason, count in pairs(stats.skipped) do print(string.format("  drawn only (%s): %d", reason, count)) end
print(string.format("pool: %d objects (%d free ids)", stats.pool, stats.freeIds))
for _, g in ipairs(stats.groups) do
    print(string.format("  %-16s %5d colliders, at most %4d in reach at once, %3d pool objects", g.group, g.colliders,
        g.peak, g.pool))
end
