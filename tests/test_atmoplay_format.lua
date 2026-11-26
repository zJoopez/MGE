-- atmoplay/format.lua: header, pool objects, atmo lines, the drawn part of the atmo
local T = ...
local Format = ATMOPLAY.Format

T.test("header line round trip", function()
    local line = Format.headerLine({ rule = 1, radius = 4 })
    T.eq(line, "#atmoplay v1 rule=1 radius=4", "written")
    local h = Format.parseHeader(line)
    T.eq(h.version, 1, "version")
    T.eq(h.rule, 1, "rule")
    T.eq(h.radius, 4, "radius")
    T.eq(Format.parseHeader("#atmoplay v1 radius=2.5").radius, 2.5, "fractional radius")
    T.eq(Format.parseHeader(Format.POOL_MARKER), nil, "the pool marker isn't a header")
    T.eq(Format.parseHeader(Format.NOTE), nil, "the note isn't a header")
    T.eq(Format.parseHeader("env_obj 1"), nil, "an object isn't a header")
end)

T.test("reads pool objects, header and atmo of a playable mod", function()
    local file = Format.read(T.lines([[
#atmoplay note: something
gamerule
    matchframes 500
env_obj 1
    shape box
    flag 0
env_obj 49
   #atmoplay pool
   shape sphere
   flag 8
env_obj 50
   shape cylinder
   friction 10000
   #atmoplay pool
player 0
#atmoplay v1 rule=1 radius=4
#@ shader dark
#@ env_obj a
#@    shape box
#@
#@ env_obj b]]))
    T.eq(file.header and file.header.radius, 4, "header found")
    T.eq(#file.pool, 2, "two pool objects (env_obj 1 has no marker)")
    T.eq(file.pool[1].id, 49, "first pool id")
    T.eq(file.pool[1].shape, "sphere", "first pool shape")
    T.eq(file.pool[1].friction, nil, "no friction line")
    T.eq(file.pool[2].id, 50, "marker after the props still counts")
    T.eq(file.pool[2].friction, "10000", "friction as written")
    T.eq(#file.atmo, 5, "atmo lines")
    T.eq(file.atmo[1], "shader dark", "prefix removed")
    T.eq(file.atmo[3], "   shape box", "indentation after the prefix kept")
    T.eq(file.atmo[4], "", "an empty atmo line")
end)

T.test("a mod without header isn't playable", function()
    local file = Format.read(T.lines("env_obj 1\n    shape box\n#@ env_obj stray"))
    T.eq(file.header, nil, "no header")
    T.eq(#file.atmo, 0, "#@ lines before a header aren't atmo")
end)

