-- atmoplay/builder.lua: which objects stay real, pool ids and groups, header and atmo, rebuilding
local T = ...
local Builder = ATMOPLAY.Builder
local Format = ATMOPLAY.Format

local BASE = [[
# my mod
gamerule
    matchframes 500
    numplayers 2

env_obj 1
    shape box
    pos 0 0 5
    flag 0

env_obj 2
    shape box
    pos 0 0 0
    sides 10 10 1
    flag 8
    friction 10000

env_obj 3
    shape box
    pos 0 0 2
    flag 8

env_obj 4
    shape box
    pos 0 0 3
    flag 9

env_obj 50
    shape box
    pos 3 0 0
    flag 8
    use_model 1

env_obj 60
    shape sphere
    pos 4 0 0
    sides 0.5 0 0
    flag 24
    color 1 0 0 1

env_obj_joint 1 3 1
    pos 0 0 1

player 0
    body head
]]

local ATMO = [[
shader dark
env_obj tree
   shape box
   pos 10 0 0
   sides 1 1 1
   friction 10000
env_obj rock
   shape sphere
   pos 12 0 0
   sides 1 0 0
env_obj bush
   shape custom bush
   pos 5 0 0
]]

T.test("which objects stay real and which become atmo", function()
    local lines, stats = Builder.build(T.lines(BASE), T.lines(ATMO))
    T.ok(lines ~= nil, "built")
    -- 1: dynamic, 3: static but joint-linked, 50: model -> real; 2, 4 (flag 9 has the static bit), 60 -> atmo
    T.eq(stats.kept, 3, "kept 1, 3, 50")
    T.eq(stats.converted, 3, "converted 2, 4, 60")
    T.ok(T.find(lines, "env_obj 1") ~= nil, "dynamic object kept")
    T.ok(T.find(lines, "env_obj 3") ~= nil, "joint-linked static kept")
    T.ok(T.find(lines, "env_obj 50") ~= nil, "model kept")
    T.eq(T.find(lines, "env_obj 2"), nil, "static 2 isn't an env object any more")
    T.ok(T.find(lines, "#@ env_obj atmoplay_mod_2") ~= nil, "static 2 is in the atmo")
    T.ok(T.find(lines, "#@    friction 10000") ~= nil, "its physics lines go along")
    T.ok(T.find(lines, "#@ env_obj atmoplay_mod_60") ~= nil, "flag 24 has the static bit too")
    T.ok(T.find(lines, "env_obj_joint 1 3 1") ~= nil, "joint kept")
    T.ok(T.find(lines, "    matchframes 500") ~= nil, "gamerules kept")
    T.ok(T.find(lines, "player 0") ~= nil, "player section kept")
    T.eq(lines[1], Format.NOTE, "the note comes first")
end)

T.test("pool: free static ids, split by group, no more than colliders", function()
    local lines, stats = Builder.build(T.lines(BASE), T.lines(ATMO))
    local file = Format.read(lines)
    -- colliders: tree (box|10000), rock (sphere|), 2 (box|10000), 4 (box|), 60 (sphere|); bush is a model
    T.eq(stats.collidable, 5, "collidable")
    T.eq(stats.skipped.model, 1, "bush skipped")
    T.eq(stats.pool, 5, "pool capped at the collidable count")
    T.eq(stats.freeIds, 256 - 48 - 1, "static ids minus the model on 50")
    T.eq(#file.pool, 5, "pool objects in the file")
    local ids, groups = {}, {}
    for _, p in ipairs(file.pool) do
        ids[#ids + 1] = p.id
        local key = p.shape .. "|" .. (p.friction or "")
        groups[key] = (groups[key] or 0) + 1
    end
    T.eq(table.concat(ids, ","), "49,51,52,53,54", "free static ids in order, 50 is taken")
    T.eq(groups["box|10000"], 2, "box|10000")
    T.eq(groups["sphere|"], 2, "sphere|")
    T.eq(groups["box|"], 1, "box|")
    T.eq(file.header and file.header.rule, 1, "header rule")
    T.eq(file.header and file.header.radius, 4, "header radius")
end)

T.test("few ids: one per group first, biggest groups first", function()
    local atmo = {}
    for i = 1, 30 do
        atmo[#atmo + 1] = "env_obj b" .. i
        atmo[#atmo + 1] = "   pos " .. i .. " 0 0"
    end
    for i = 1, 5 do
        atmo[#atmo + 1] = "env_obj s" .. i
        atmo[#atmo + 1] = "   shape sphere"
        atmo[#atmo + 1] = "   pos " .. i .. " 5 0"
    end
    local _, stats = Builder.build({}, atmo, { maxId = 52 }) -- 4 static ids
    T.eq(stats.pool, 4, "all four ids used")
    local byGroup = {}
    for _, g in ipairs(stats.groups) do byGroup[g.group] = g.pool end
    T.eq(byGroup["box|"], 3, "boxes get the rest")
    T.eq(byGroup["sphere|"], 1, "spheres get one")
end)

T.test("the pool follows what a player can reach, not how many objects a group has", function()
    local atmo = {}
    -- 100 boxes with friction 5, 20 apart: a player is never near more than one
    for i = 1, 100 do
        atmo[#atmo + 1] = "env_obj far" .. i
        atmo[#atmo + 1] = "   pos " .. (i * 20) .. " 100 0"
        atmo[#atmo + 1] = "   friction 5"
    end
    -- 10 boxes without friction, side by side: all ten in reach at once
    for i = 1, 10 do
        atmo[#atmo + 1] = "env_obj near" .. i
        atmo[#atmo + 1] = "   pos " .. i .. " 0 0"
    end
    local _, stats = Builder.build({}, atmo, { maxId = 56 }) -- 8 static ids
    local byGroup = {}
    for _, g in ipairs(stats.groups) do byGroup[g.group] = g end
    T.eq(byGroup["box|5"].peak, 1, "spread group: one in reach at a time")
    -- from the middle box (x 5), boxes 1..9 are within 4 + 0.87 (reach + a unit box's bounding radius)
    T.eq(byGroup["box|"].peak, 9, "clustered group: nine in reach")
    T.eq(byGroup["box|"].pool, 7, "the clustered group gets all but one")
    T.eq(byGroup["box|5"].pool, 1, "the spread group one, although it has ten times the objects")
end)

T.test("classic (no base file) and rebuilding gives the same mod", function()
    local first = Builder.build({}, T.lines(ATMO))
    T.ok(first ~= nil, "built from nothing")
    local again = Builder.build(first, T.lines(ATMO))
    T.eq(table.concat(again, "\n"), table.concat(first, "\n"), "building from the playable mod gives the same")
    local fromBase = Builder.build(T.lines(BASE), T.lines(ATMO))
    -- the converted objects are in the atmo part now: rebuilding converts nothing more and keeps them once
    local rebuilt = Builder.build(fromBase, T.lines(ATMO))
    local count = 0
    for _, line in ipairs(rebuilt) do
        if line == "#@ env_obj atmoplay_mod_2" then count = count + 1 end
    end
    T.eq(count, 0, "a rebuild with the original atmo drops the old atmo part (converted objects gone)")
end)

T.test("errors: nothing collidable, no ids", function()
    local lines, err = Builder.build({}, { "env_obj m", "   shape custom x", "   pos 0 0 0" })
    T.eq(lines, nil, "no collidable objects")
    T.ok(type(err) == "string", "says why")
    local base = {}
    for id = 49, 256 do
        base[#base + 1] = "env_obj " .. id
        base[#base + 1] = "    flag 8"
        base[#base + 1] = "    use_model 1"
    end
    lines, err = Builder.build(base, T.lines(ATMO))
    T.eq(lines, nil, "every static id taken")
    T.ok(tostring(err):find("free") ~= nil, "says no free ids")
end)

T.test("CRLF input and empty atmo lines", function()
    local lines = Builder.build({ "gamerule\r", "    matchframes 100\r" }, { "env_obj a\r", "   pos 0 0 0\r", "" })
    T.ok(T.find(lines, "gamerule") ~= nil, "CR removed from base lines")
    T.ok(T.find(lines, "#@ env_obj a") ~= nil, "CR removed from atmo lines")
    T.eq(lines[#lines], "#@", "an empty atmo line is written as #@")
    local file = Format.read(lines)
    T.eq(#file.atmo, 3, "read back: three atmo lines")
end)
