-- atmoplay/drawer.lua: which atmo shapes Atmo Play draws itself, the game keeps the rest; the on-screen test
local T = ...
local Drawer = ATMOPLAY.Drawer

T.test("drawer: plain shapes Atmo Play's, the rest the game's (with the header), visible 0 nowhere", function()
    local split = Drawer.split(T.lines([[
shader night
env_obj box
   shape box
   pos 1 2 3
   size 2 4 6
   color 255 128 0 1
   no_depth 1
   min_level 1
env_obj ball
   shape sphere
   pos 0 0 5
   sides 0.5 0 0
env_obj pill
   shape capsule
   pos 0 0 0
   sides 0.2 1 0
env_obj model
   shape custom tree
   pos 0 0 0
env_obj spinner
   shape box
   pos 0 0 0
   rotate 0 0 1
env_obj child
   shape box
   pos 1 0 0
   parent mom
env_obj mom
   shape box
   pos 0 0 0
env_obj hidden
   shape box
   pos 0 0 0
   visible 0
env_obj many
   shape box
   pos 0 0 0
   count 5]]))
    T.eq(split.own, 3, "box, ball, pill")
    T.eq(split.game, 5, "model, spinner, child, its parent, count")
    T.eq(split.hidden, 1, "visible 0")
    local game = table.concat(split.gameLines, "\n")
    T.ok(game:find("shader night", 1, true) ~= nil, "the header stays the game's")
    T.ok(game:find("env_obj mom", 1, true) ~= nil, "a parent stays with its child")
    T.ok(not game:find("env_obj box", 1, true), "a plain box isn't")
    local box = split.items[1]
    T.eq(box.shape, "box", "box")
    T.nearList(box.size, { 2, 4, 6 }, 1e-12, "size is sides")
    T.nearList(box.color, { 255 / 256, 128 / 256, 0, 1 }, 1e-12, "a 0-256 color as the game reads it")
    T.eq(box.noDepth, true, "no_depth")
    T.eq(box.minLevel, 1, "min_level")
    T.eq(split.items[3].shape, "capsule", "capsule")
    T.eq(split.items[1].index, 1, "atmo index (props match by it)")
end)

T.test("drawer: cells and shapes off screen are skipped; props drawn where they are, not while carried", function()
    local split = Drawer.split(T.lines([[
env_obj ahead
   shape box
   pos 10 0 0
env_obj behind
   shape box
   pos -10 0 0
env_obj prop
   shape box
   pos 5 0 0
   flag 0]]))
    local prop = { pos = { 20, 0, 0 }, rot = split.items[3].rot }
    local d = Drawer.new(split, { [3] = prop })
    -- a camera at the origin looking along +x, 1000 pixels a unit of sideways / depth, 1000 x 1000 screen
    local view = { eye = { 0, 0, 0 }, forward = { 1, 0, 0 }, right = { 0, -1, 0 }, up = { 0, 0, 1 }, cx = 500, cy = 500,
        m11 = 1000, m12 = 0, m21 = 0, m22 = -1000, w = 1000, h = 1000 }
    local drawn = {}
    local saved = { set_color, draw_box_m }
    set_color = function() end
    draw_box_m = function(x) drawn[#drawn + 1] = x end
    local ok, err = pcall(function()
        T.eq(Drawer.draw(d, view, 2), 2, "ahead and the prop, not behind")
        T.nearList(drawn, { 10, 20 }, 1e-12, "the prop where it is now")
        prop.entry = {}
        drawn = {}
        T.eq(Drawer.draw(d, view, 2), 1, "a carried prop isn't drawn (its object shows)")
        T.eq(Drawer.draw(d, nil, 2), 2, "no view: every static one")
        T.ok(not Drawer.onScreen(view, 10, 30, 0, 0.5), "far to the side: off screen")
        T.ok(Drawer.onScreen(view, 0.2, 30, 0, 0.5), "level with the camera: drawn (around it)")
    end)
    set_color, draw_box_m = saved[1], saved[2]
    assert(ok, err)
end)

T.test("drawer: shapes on screen drawn nearest first, props among them", function()
    local split = Drawer.split(T.lines([[
env_obj far
   shape box
   pos 90 0 0
env_obj near
   shape box
   pos 3 0 0
env_obj mid
   shape box
   pos 40 0 0
env_obj prop
   shape box
   pos 5 0 0
   flag 0]]))
    local prop = { pos = { 20, 0, 0 }, rot = split.items[4].rot }
    local d = Drawer.new(split, { [4] = prop })
    local view = { eye = { 0, 0, 0 }, forward = { 1, 0, 0 }, right = { 0, -1, 0 }, up = { 0, 0, 1 }, cx = 500, cy = 500,
        m11 = 1000, m12 = 0, m21 = 0, m22 = -1000, w = 1000, h = 1000 }
    local drawn = {}
    local saved = { set_color, draw_box_m }
    set_color = function() end
    draw_box_m = function(x) drawn[#drawn + 1] = x end
    local ok, err = pcall(function()
        Drawer.draw(d, view, 2)
        T.nearList(drawn, { 3, 20, 40, 90 }, 1e-12, "near to far, the prop where it is")
        drawn = {}
        T.eq(Drawer.draw(d, view, 2, 2), 2, "max draws: two")
        T.nearList(drawn, { 3, 20 }, 1e-12, "the nearest two")
        drawn = {}
        T.eq(Drawer.draw(d, view, 2, 0), 4, "0: all")
    end)
    set_color, draw_box_m = saved[1], saved[2]
    assert(ok, err)
end)

T.test("drawer: max draws over many cells: the nearest ones, as sorting every shape on screen gives", function()
    local lines = {}
    for i = 0, 29 do
        for j = 0, 29 do
            lines[#lines + 1] = "env_obj b" .. i .. "_" .. j
            lines[#lines + 1] = string.format("   pos %d %d %d", 5 + i * 7, j * 7 - 100, (i * 13 + j * 7) % 5)
        end
    end
    local d = Drawer.new(Drawer.split(lines))
    local view = { eye = { 0, 0, 2 }, forward = { 1, 0, 0 }, right = { 0, -1, 0 }, up = { 0, 0, 1 }, cx = 500, cy = 500,
        m11 = 1000, m12 = 0, m21 = 0, m22 = -1000, w = 1000, h = 1000 }
    local saved = { set_color, draw_box_m }
    local drawn = {}
    set_color = function() end
    draw_box_m = function(x, y, z) drawn[#drawn + 1] = (x * x + y * y + (z - 2) ^ 2) end
    local ok, err = pcall(function()
        local all = Drawer.draw(d, view, 2)
        local every = {}
        for i, v in ipairs(drawn) do every[i] = v end
        table.sort(every)
        for _, cap in ipairs({ 1, 37, 200, all, all + 50 }) do
            drawn = {}
            local n = Drawer.draw(d, view, 2, cap)
            T.eq(n, math.min(cap, all), "max " .. cap .. ": how many")
            -- the same ones as the nearest of all (the order is near to far by buckets, not exact)
            local got = {}
            for i, v in ipairs(drawn) do got[i] = v end
            table.sort(got)
            local ok2 = true
            for i = 1, n do
                if math.abs(got[i] - every[i]) > 1e-9 then ok2 = false end
            end
            T.ok(ok2, "max " .. cap .. ": the nearest ones")
            T.ok(n == 0 or drawn[1] <= every[1] * 4 + 1, "max " .. cap .. ": a near one first")
        end
    end)
    set_color, draw_box_m = saved[1], saved[2]
    assert(ok, err)
end)

T.test("drawer: props always Atmo Play's (even with rcolor); alpha 0 drawn by nobody", function()
    local split = Drawer.split(T.lines([[
env_obj prop
   shape box
   pos 0 0 1
   rcolor 1 0 0 1
   flag 0
env_obj ghost
   shape box
   pos 0 0 0
   color 1 1 1 0
env_obj plain
   shape box
   pos 2 0 0]]), { [1] = {} })
    T.eq(split.own, 2, "the prop and the plain box")
    T.eq(split.items[1].index, 1, "the prop is Atmo Play's")
    T.eq(split.hidden, 1, "alpha 0: not drawn")
    T.ok(not table.concat(split.gameLines, "\n"):find("env_obj prop", 1, true), "not left to the game")
    local alone = Drawer.split(T.lines("env_obj prop\n   shape box\n   pos 0 0 1\n   rcolor 1 0 0 1\n   flag 0"))
    T.eq(alone.game, 1, "without props given: rcolor stays the game's")
end)
