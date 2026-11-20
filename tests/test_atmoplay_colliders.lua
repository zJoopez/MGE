-- atmoplay/colliders.lua: atmo entities to collision shapes, skip reasons, distances
local T = ...
local Colliders = ATMOPLAY.Colliders

T.test("entities are read like the game's atmo parser", function()
    local entities, header = Colliders.entities({
        "shader dark",
        "env_obj a",
        "   shape box",
        "   size 1 2 3",
        "   pos 0 0 0",
        "   pos 1 1 1",
        "player 0",
        "   pos 9 9 9",
        "env_obj b",
        "   shape sphere",
    })
    T.eq(#header, 1, "header line")
    T.eq(#entities, 2, "two entities")
    T.eq(entities[1].props.sides, "1 2 3", "size is sides")
    T.eq(entities[1].props.pos, "1 1 1", "the later line wins, the player section is ignored")
    T.eq(entities[2].props.shape, "sphere", "second entity")
end)

T.test("collidable shapes and skip reasons", function()
    local colliders, stats = Colliders.build(T.lines([[
env_obj box
   shape box
   pos 1 2 3
   sides 2 4 -6
   friction 10000.00
   flag 8
   bounce 0.1
env_obj ball
   shape sphere
   pos 0 0 0
   sides 0.5 0 0
env_obj pill
   shape capsule
   pos 0 0 0
   sides 0.2 1 0
env_obj model
   shape custom tree
   pos 0 0 0
env_obj randomized
   shape box
   pos 0 0 0
   rpos 1 1 1
env_obj counted
   pos 0 0 0
   count 5
env_obj spinning
   pos 0 0 0
   rotate 0 0 1
env_obj child
   pos 0 0 0
   parent box
env_obj nowhere
   shape box
env_obj hidden
   pos 5 5 5
   visible 0
env_obj leveled
   pos 6 6 6
   min_level 2]]))
    T.eq(stats.total, 11, "entities")
    T.eq(stats.collidable, 5, "box, ball, pill, hidden, leveled")
    T.eq(#colliders, 5, "collider list")
    T.eq(stats.skipped.model, 1, "custom model")
    T.eq(stats.skipped.random, 2, "rpos and count")
    T.eq(stats.skipped.animated, 1, "rotate")
    T.eq(stats.skipped.parented, 1, "parent")
    T.eq(stats.skipped.unplaced, 1, "no pos")
    local box, ball, pill, hidden, leveled = colliders[1], colliders[2], colliders[3], colliders[4], colliders[5]
    T.eq(box.index, 1, "index is the entity's place")
    T.eq(box.sides[3], 6, "sides are made positive")
    T.eq(box.group, "box|10000", "friction written as a number")
    T.eq(box.flag, 8, "flag")
    T.near(box.bounce, 0.1, 1e-9, "bounce")
    T.eq(ball.shape, "sphere", "sphere")
    T.eq(ball.group, "sphere|", "no friction line")
    T.eq(ball.sides[2], Colliders.MIN_SIDE, "zero sides become the minimum")
    T.eq(pill.shape, "cylinder", "capsule is a cylinder")
    T.eq(hidden.visible, false, "visible 0: solid, not drawn")
    T.eq(hidden.index, 10, "index counts the skipped ones too")
    T.eq(leveled.visible, true, "graphics level doesn't change collision")
    T.eq(Colliders.build({ "env_obj x", "   pos 0 0 0" })[1].shape, "box", "no shape line: a box")
end)

T.test("distance to boxes, spheres and cylinders", function()
    local colliders = Colliders.build({
        "env_obj box", "   shape box", "   pos 0 0 0", "   sides 2 2 2",
        "env_obj ball", "   shape sphere", "   pos 10 0 0", "   sides 1 0 0",
        "env_obj pill", "   shape cylinder", "   pos 20 0 0", "   sides 1 4 0",
        "env_obj turned", "   shape box", "   pos 30 0 0", "   sides 4 1 1", "   rot 0 0 90",
    })
    local box, ball, pill, turned = colliders[1], colliders[2], colliders[3], colliders[4]
    T.near(Colliders.distance(box, { 0.5, 0, 0 }), 0, 1e-9, "inside the box")
    T.near(Colliders.distance(box, { 4, 0, 0 }), 3, 1e-9, "from a face")
    T.near(Colliders.distance(box, { 4, 5, 0 }), 5, 1e-9, "from an edge: 3-4-5")
    T.near(Colliders.distance(ball, { 13, 0, 0 }), 2, 1e-9, "sphere")
    -- a capsule: radius 1, length 4 along local z, rounded ends: from (20,0,5) the end cap's centre is 3
    -- away, minus the radius
    T.near(Colliders.distance(pill, { 20, 0, 5 }), 2, 1e-9, "cylinder end: length along local z")
    T.near(Colliders.distance(pill, { 23, 0, 0 }), 2, 1e-9, "cylinder side")
    -- 4 long along x, turned 90 degrees around z: long along y
    T.near(Colliders.distance(turned, { 30, 1.9, 0 }), 0, 1e-9, "turned box reaches along y")
    T.near(Colliders.distance(turned, { 31.5, 0, 0 }), 1, 1e-9, "turned box is thin along x")
    T.near(box.radius, math.sqrt(12) / 2, 1e-9, "bounding radius")
end)

T.test("frameOf matches MGE's (rotX(-x) rotY(-y) rotZ(-z))", function()
    local f = Colliders.frameOf({ 0, 0, 90 })
    -- rotZ(-90): local x goes to world -y
    T.near(f[1][1], 0, 1e-9, "f11")
    T.near(f[2][1], -1, 1e-9, "f21")
    T.near(f[1][2], 1, 1e-9, "f12")
end)
