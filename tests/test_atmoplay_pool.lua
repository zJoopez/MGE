-- atmoplay/pool.lua: rule 1 (stable nearest), groups, parking, reset, determinism
local T = ...
local Colliders = ATMOPLAY.Colliders
local Pool = ATMOPLAY.Pool

---Unit boxes along x at the given positions (index = place in the list), plus extra lines per box
local function boxesAt(xs, extra)
    local lines = {}
    for i, x in ipairs(xs) do
        lines[#lines + 1] = "env_obj b" .. i
        lines[#lines + 1] = "   shape box"
        lines[#lines + 1] = "   pos " .. x .. " 0 0"
        lines[#lines + 1] = "   sides 1 1 1"
        if extra and extra[i] then lines[#lines + 1] = "   " .. extra[i] end
    end
    return (Colliders.build(lines))
end

local function poolOf(n, shape, firstId, friction)
    local list = {}
    for i = 1, n do list[i] = { id = (firstId or 49) + i - 1, shape = shape or "box", friction = friction } end
    return list
end

---{ [id] = collider name or "parked" } after applying changes, kept across calls in `world`
local function apply(world, changes)
    for _, change in ipairs(changes) do
        world[change.entry.id] = change.collider and change.collider.name or "parked"
    end
    return world
end

T.test("nearest colliders within the radius, nearest first, rest parked", function()
    local colliders = boxesAt({ 3, 1, 10, 2 }) -- b1 at 3, b2 at 1, b3 at 10, b4 at 2
    local state = assert(Pool.new(poolOf(3), colliders, { radius = 4 }))
    local world = apply({}, Pool.step(state, { { 0, 0, 0 } }))
    -- surface distances from 0: b2 0.5, b4 1.5, b1 2.5; b3 9.5 is out of reach
    T.eq(world[49], "b2", "nearest on the lowest id")
    T.eq(world[50], "b4", "second")
    T.eq(world[51], "b1", "third")
    local changes = Pool.step(state, { { 0, 0, 0 } })
    T.eq(#changes, 0, "nothing moves when nothing changed")
end)

T.test("first step reports every pool object, parked ones too", function()
    local state = assert(Pool.new(poolOf(3), boxesAt({ 1 }), { radius = 4 }))
    local changes = Pool.step(state, { { 0, 0, 0 } })
    T.eq(#changes, 3, "all three reported")
    local world = apply({}, changes)
    T.eq(world[50], "parked", "nothing for the second")
end)

T.test("stable: a pool object keeps its collider while it's still wanted", function()
    local colliders = boxesAt({ 1, 2, 3, 4, 5, 6 })
    local state = assert(Pool.new(poolOf(2), colliders, { radius = 1.6 }))
    local world = apply({}, Pool.step(state, { { 0, 0, 0 } }))
    T.eq(world[49], "b1", "start: b1")
    T.eq(world[50], "b2", "start: b2")
    -- player at 2.6 (unit boxes, surfaces at x +- 0.5): b1 1.1, b2 0.1, b3 0 (inside), b4 0.9 away;
    -- the nearest two are b3 and b2, b1 drops out
    local changes = Pool.step(state, { { 2.6, 0, 0 } })
    apply(world, changes)
    T.eq(#changes, 1, "only the freed object moves")
    T.eq(world[50], "b2", "b2 stays on its object although it's now the nearest")
    T.eq(world[49], "b3", "the freed object takes b3")
end)

T.test("groups: shape and friction", function()
    local colliders = Colliders.build({
        "env_obj s", "   shape sphere", "   pos 1 0 0", "   sides 0.5 0 0",
        "env_obj b", "   shape box", "   pos 1 0 0", "   sides 1 1 1",
        "env_obj f", "   shape box", "   pos 0.5 0 0", "   sides 1 1 1", "   friction 5",
    })
    local objects = { { id = 60, shape = "box" }, { id = 61, shape = "sphere" }, { id = 62, shape = "box", friction = "5" } }
    local state = assert(Pool.new(objects, colliders, { radius = 4 }))
    local world = apply({}, Pool.step(state, { { 0, 0, 0 } }))
    T.eq(world[60], "b", "plain box takes the box without friction (f is nearer but in another group)")
    T.eq(world[61], "s", "sphere")
    T.eq(world[62], "f", "friction 5 box")
end)

T.test("several players: nearest to any of them", function()
    local state = assert(Pool.new(poolOf(2), boxesAt({ 1, 20, 40 }), { radius = 2 }))
    local world = apply({}, Pool.step(state, { { 0, 0, 0 }, { 41, 0, 0 } }))
    T.eq(world[49], "b1", "player 1's")
    T.eq(world[50], "b3", "player 2's")
end)

T.test("ties go to the lower collider index", function()
    local state = assert(Pool.new(poolOf(1), boxesAt({ 2, -2 }), { radius = 4 }))
    local world = apply({}, Pool.step(state, { { 0, 0, 0 } }))
    T.eq(world[49], "b1", "same distance: b1")
end)

T.test("reset: the next step assigns from scratch and reports everything", function()
    local colliders = boxesAt({ 1, 2, 3, 4, 5, 6 })
    local a = assert(Pool.new(poolOf(2), colliders, { radius = 1.6 }))
    local b = assert(Pool.new(poolOf(2), colliders, { radius = 1.6 }))
    Pool.step(a, { { 0, 0, 0 } })
    Pool.step(a, { { 2.6, 0, 0 } }) -- a now holds b3 on 49, b2 on 50
    Pool.reset(a)
    local changesA = Pool.step(a, { { 2.6, 0, 0 } })
    local changesB = Pool.step(b, { { 2.6, 0, 0 } }) -- a fresh pool at the same frame
    T.eq(#changesA, 2, "every object reported after a reset")
    local wa, wb = apply({}, changesA), apply({}, changesB)
    T.eq(wa[49], wb[49], "same as a fresh start (49)")
    T.eq(wa[50], wb[50], "same as a fresh start (50)")
    T.eq(wa[49], "b3", "fresh order: nearest first")
    T.eq(wa[50], "b2", "then the second nearest")
end)

T.test("deterministic over a long random walk", function()
    local xs = {}
    for i = 1, 200 do xs[i] = (i * 37) % 101 - 50 + (i % 7) / 10 end
    local colliders = boxesAt(xs)
    local a = assert(Pool.new(poolOf(8), colliders, { radius = 4 }))
    local b = assert(Pool.new(poolOf(8), colliders, { radius = 4 }))
    local wa, wb, moves = {}, {}, 0
    for frame = 1, 500 do
        local p = { { math.sin(frame / 30) * 45, math.cos(frame / 17), 0 }, { -frame / 10, 0, 0 } }
        local ca = Pool.step(a, p)
        moves = moves + #ca
        apply(wa, ca)
        apply(wb, Pool.step(b, p))
    end
    local same = true
    for id = 49, 56 do if wa[id] ~= wb[id] then same = false end end
    T.ok(same, "two pools fed the same frames end the same")
    T.ok(moves < 500 * 8, "stable assignment moves far fewer than every object every frame (" .. moves .. ")")
end)

T.test("unknown rule is refused", function()
    local state, err = Pool.new(poolOf(1), boxesAt({ 1 }), { rule = 99 })
    T.eq(state, nil, "no state")
    T.ok(err and err:find("99") ~= nil, "error names the rule")
end)

T.test("the grid gives exactly the moves of looking at every collider", function()
    -- a fixed pseudo-random map: small and huge boxes (some turned), spheres, capsules
    local seed = 12345
    local function rand()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    local lines = {}
    for i = 1, 400 do
        local shape = i % 7 == 0 and "sphere" or (i % 11 == 0 and "capsule" or "box")
        local big = i % 50 == 0
        lines[#lines + 1] = "env_obj o" .. i
        lines[#lines + 1] = "   shape " .. shape
        lines[#lines + 1] = string.format("   pos %.3f %.3f %.3f", rand() * 80 - 40, rand() * 80 - 40, rand() * 6)
        lines[#lines + 1] = string.format("   sides %.3f %.3f %.3f", big and 40 or rand() * 2 + 0.1,
            big and 1 or rand() * 2 + 0.1, rand() * 2 + 0.1)
        if i % 3 == 0 then lines[#lines + 1] = string.format("   rot %d %d %d", i % 90, (i * 7) % 180, (i * 13) % 360) end
    end
    local colliders = Colliders.build(lines)
    local objects = {}
    for i = 1, 30 do objects[i] = { id = 48 + i, shape = i <= 20 and "box" or (i <= 25 and "sphere" or "cylinder") } end
    local grid = assert(Pool.new(objects, colliders, { radius = 4 }))
    local scan = assert(Pool.new(objects, colliders, { radius = 4 }, { grid = false }))
    T.ok(grid.cells ~= nil and scan.cells == nil, "one with the grid, one without")
    local same, moves = true, 0
    for frame = 1, 600 do
        local t = frame / 40
        local centers = {
            { math.sin(t) * 38, math.cos(t * 0.7) * 38, 1 + math.sin(t * 3) },
            { -40 + frame * 0.13, 5, 2 },
            { 0, -40 + frame * 0.13, 0.5 },
        }
        if frame == 300 then
            Pool.reset(grid)
            Pool.reset(scan)
        end
        local a, b = Pool.step(grid, centers), Pool.step(scan, centers)
        moves = moves + #a
        if #a ~= #b then same = false end
        for k = 1, math.min(#a, #b) do
            if a[k].entry.id ~= b[k].entry.id or (a[k].collider and a[k].collider.index) ~= (b[k].collider and b[k].collider.index) then
                same = false
            end
        end
    end
    T.ok(same, "identical moves every frame")
    T.ok(moves > 100, "the walk moved the pool a lot (" .. moves .. " moves)")
end)
