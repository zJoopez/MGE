-- atmoplay/flight.lua: drawn flight against the numbers measured in game (docs/atmo-play-plan.md section 7:
-- data/mod/mge_tests/atmoplay_probe.tbm and atmoplay_probe_friction.tbm)
local T = ...
local Flight = ATMOPLAY.Flight

---Steps one prop's flight up to a frame (Flight.step on a list of one); true while it still flies
local function advance(w, prop, toFrame, opts)
    local list = { prop }
    while prop.flight and prop.flight.frame < toFrame do Flight.step(w, list, prop.flight.frame, opts) end
    return prop.flight ~= nil
end
local Colliders = ATMOPLAY.Colliders
local Driver = ATMOPLAY.Driver

local IDENTITY = { r0 = 1, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 0, r9 = 0, r10 = 1, r11 = 0 }

---A 0.5 box prop at pos, flying from frame 0
local function prop(pos, lines)
    local p = { shape = "box", sides = { 0.5, 0.5, 0.5 }, pos = pos, rot = IDENTITY, radius = 0.433 }
    for k, v in pairs(lines or {}) do p[k] = v end
    p.flight = Flight.start(nil, 0)
    return p
end

---A static box collider
local function box(pos, sides, lines)
    local c = { shape = "box", pos = pos, sides = sides, frame = Colliders.frameOf({ 0, 0, 0 }),
        radius = math.sqrt(sides[1] ^ 2 + sides[2] ^ 2 + sides[3] ^ 2) / 2 }
    for k, v in pairs(lines or {}) do c[k] = v end
    return c
end

T.test("flight: free fall as the game steps it (probe obj 1)", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local p = prop({ 0, 30, 150 })
    T.ok(advance(w, p, 100), "still flying")
    T.near(p.pos[3], 148.21472, 1e-5, "z at frame 100")
    T.near(p.flight.vel[3], -5.892, 1e-9, "vz at frame 100")
    advance(w, p, 600)
    T.near(p.pos[3], 86.26035, 1e-5, "z at frame 600")
    T.near(p.flight.vel[3], -35.352, 1e-9, "vz at frame 600")
end)

T.test("flight: thrust is a one-step force on its push frames (probe objs 2, 3, 4)", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local every1 = prop({ 0, 34, 150 }, { thrust = Flight.parseThrust("1 0.1 0 0") })
    local heavy = prop({ 0, 38, 150 }, { thrust = Flight.parseThrust("1 0.1 0 0"), mass = 2 })
    local every5 = prop({ 0, 42, 150 }, { thrust = Flight.parseThrust("5 0.1 0 0") })
    advance(w, every1, 1)
    T.near(every1.flight.vel[1], 0.0006, 1e-12, "first push into frame 1")
    advance(w, every5, 5)
    T.near(every5.flight.vel[1], 0.0006, 1e-12, "thrust 5: one push by frame 5")
    advance(w, every5, 6)
    T.near(every5.flight.vel[1], 0.0012, 1e-12, "the second into frame 6")
    for _, p in ipairs({ every1, heavy, every5 }) do advance(w, p, 600) end
    T.near(every1.pos[1], 0.64908, 1e-5, "thrust 1, x at 600")
    T.near(every1.flight.vel[1], 0.36, 1e-9, "thrust 1, vx at 600")
    T.near(heavy.pos[1], 0.32454, 1e-5, "mass 2: half")
    T.near(every5.pos[1], 0.13068, 1e-5, "thrust 5, x at 600")
    T.near(every5.flight.vel[1], 0.072, 1e-9, "thrust 5, vx at 600")
    T.near(every1.pos[3], 86.26035, 1e-5, "gravity as without thrust")
end)

T.test("flight: thrust on the prop's own axes (probe obj 8: rot 0 0 90 pushes along -y)", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local rot = Driver.matrixTB(Colliders.frameOf({ 0, 0, 90 }))
    local p = prop({ 0, 58, 150 }, { thrust = Flight.parseThrust("1 0.1 0 0 1"), rot = rot })
    advance(w, p, 600)
    T.near(p.pos[1], 0, 1e-9, "no x")
    T.near(p.pos[2], 58 - 0.64908, 1e-5, "y at 600")
end)

T.test("flight: thrust lines", function()
    local t = Flight.parseThrust("5 0.1 0 -2 1")
    T.eq(t.every, 5, "frames")
    T.nearList(t.force, { 0.1, 0, -2 }, 1e-12, "force")
    T.eq(t.space, 1, "object axes")
    T.eq(Flight.parseThrust("1 0 0 0"), nil, "no push")
    T.eq(Flight.parseThrust("0 1 0 0"), nil, "no frames")
    T.eq(Flight.parseThrust(nil), nil, "no line")
    T.eq(Flight.parseThrust("1 1 0 0").space, 0, "world axes by default")
    T.ok(Flight.pushes(t, 0) and Flight.pushes(t, 5) and not Flight.pushes(t, 1), "the steps from frames 0, 5 ...")
end)

T.test("flight: bounce and friction as measured", function()
    T.near(Flight.restitution(10), 0.914, 0.005, "bounce 10")
    T.near(Flight.restitution(20), 1.874, 0.005, "bounce 20")
    T.near(Flight.restitution(5), 0.434, 0.005, "bounce 5")
    T.near(Flight.restitution(50), 4.754, 0.005, "bounce 50")
    T.eq(Flight.restitution(0), 0, "bounce 0: none")
    T.eq(Flight.restitution(nil), 0, "no line")
    T.eq(Flight.frictionLimit(-10000, nil), 0, "-10000 frictionless")
    T.eq(Flight.frictionLimit(10000, -10000), 0, "the lower side wins")
    T.near(Flight.frictionLimit(-9999, nil) * 4 / Flight.DT, 2, 1e-9, "-9999: ~2 N on a flat box's 4 corners")
    T.ok(Flight.frictionLimit(nil, nil) > 10, "grip: no limit to speak of (the cone decides)")
    T.near(Flight.parseGravity("0.00 0.00 -30.00")[3], -30, 1e-12, "gravity line")
    T.eq(Flight.parseGravity("x"), nil, "not a gravity")
end)

T.test("flight: bounces off the ground, comes to rest and ends", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local p = prop({ 0, 0, 8 }, { bounce = 10 })
    local vin, vout
    for f = 1, 400 do
        local before = p.flight.vel[3]
        advance(w, p, f)
        if before < -1 and p.flight.vel[3] > 0 then
            vin, vout = before, p.flight.vel[3]
            break
        end
    end
    T.ok(vin ~= nil, "it bounced")
    T.near(vout / -vin, 0.914, 0.02, "rebound share")
    local plain = prop({ 0, 0, 2 })
    local flying = true
    for f = 1, 1000 do
        flying = advance(w, plain, f)
        if not flying then break end
    end
    T.ok(not flying and plain.flight == nil, "at rest: the flight ended")
    T.near(plain.pos[3], 0.25, 0.01, "resting on the ground (its sphere)")
end)

T.test("flight: hits the static atmo; slides on a frictionless platform, stops on a gripping one", function()
    local wall = box({ 5, 0, 5 }, { 1, 10, 10 })
    local w = Flight.newWorld({ wall }, { 0, 0, 0 })
    local p = prop({ 0, 0, 5 })
    p.flight.vel = { 10, 0, 0 }
    advance(w, p, 200)
    T.ok(p.pos[1] < 4.5 - 0.24, "stopped at the wall's face")
    local slippery = box({ 0, 0, 1 }, { 40, 2, 1 }, { friction = -10000 })
    local grippy = box({ 0, 10, 1 }, { 40, 2, 1 })
    w = Flight.newWorld({ slippery, grippy }, { 0, 0, -9.82 })
    local a, b = prop({ -15, 0, 1.75 }), prop({ -15, 10, 1.75 })
    a.flight.vel, b.flight.vel = { 5, 0, 0 }, { 5, 0, 0 }
    advance(w, a, 100)
    advance(w, b, 400)
    T.near(a.flight.vel[1], 5, 1e-9, "frictionless: as fast")
    T.ok(b.flight == nil, "grip: it tumbled and came to rest (the game's cube tipped and stopped by ~150 too)")
    T.ok(b.pos[1] < -13, "within a short way")
end)

T.test("flight: a point inside a box leaves by the nearest face", function()
    local c = box({ 0, 0, 0 }, { 4, 4, 2 })
    local d, nx, ny, nz = Flight.surface(c, 0.5, 0, 0.8)
    T.near(d, -0.2, 1e-9, "0.2 inside")
    T.nearList({ nx, ny, nz }, { 0, 0, 1 }, 1e-9, "up through the top")
    d, nx = Flight.surface(c, 3, 0, 0)
    T.near(d, 1, 1e-9, "1 outside")
    T.near(nx, 1, 1e-9, "along x")
end)

T.test("flight: a spinning prop turns at its angular velocity (world axes, rad/s)", function()
    local w = Flight.newWorld({}, { 0, 0, 0 })
    local p = prop({ 0, 0, 50 })
    p.flight = Flight.start(nil, 0, { 0, 0, 2 })
    advance(w, p, 100)
    -- 1.2 rad about +z: its own x axis (the matrix's first column) points at cos, sin
    T.near(p.rot.r0, math.cos(1.2), 1e-9, "x axis, x")
    T.near(p.rot.r4, math.sin(1.2), 1e-9, "x axis, y")
    T.near(p.rot.r10, 1, 1e-9, "z axis kept")
    T.nearList(Flight.start(nil, 0).ang, { 0, 0, 0 }, 0, "no spin given: still")
end)

T.test("flight: a thrust on its own axes turns with the spin", function()
    local w = Flight.newWorld({}, { 0, 0, 0 })
    local p = prop({ 0, 0, 50 }, { thrust = Flight.parseThrust("1 1 0 0 1") })
    p.flight = Flight.start(nil, 0, { 0, 0, math.pi / 2 / (100 * Flight.DT) }) -- a quarter turn in 100 frames
    advance(w, p, 200)
    T.ok(p.flight.vel[2] > 0.1, "pushed along y too once turned")
    local still = prop({ 0, 0, 50 }, { thrust = Flight.parseThrust("1 1 0 0 1") })
    advance(w, still, 200)
    T.near(still.flight.vel[2], 0, 1e-12, "not spinning: along x only")
end)

T.test("flight: spin slows on a gripping contact, then the flight rests", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local p = prop({ 0, 0, 0.25 })
    p.flight = Flight.start(nil, 0, { 0, 0, 10 })
    advance(w, p, 5)
    T.ok(p.flight.ang[3] < 10 * 0.9 ^ 4, "slowed on the ground")
    local flying = true
    for f = 6, 400 do
        flying = advance(w, p, f)
        if not flying then break end
    end
    T.ok(not flying, "at rest once the spin died down")
    local slick = prop({ 0, 0, 0.25 }, { friction = -10000 })
    slick.flight = Flight.start(nil, 0, { 0, 0, 10 })
    advance(w, slick, 50)
    T.near(slick.flight.ang[3], 10, 1e-12, "frictionless: spins on")
end)

---------------------------------------------------------------------------------------------------- shapes, each other

---Steps props together (collide: they meet; still: props they may wake) for n frames from frame 0
local function run(w, list, n, collide, still)
    local opts = { collide = collide }
    if still then
        opts.neighbors = function(prop)
            local out = {}
            for _, s in ipairs(still) do
                if s ~= prop and not s.flight then out[#out + 1] = s end
            end
            return out
        end
        opts.wake = function(s, frame)
            s.pos = { s.pos[1], s.pos[2], s.pos[3] }
            s.flight = Flight.start(nil, frame)
            list[#list + 1] = s
        end
    end
    for f = 0, n - 1 do
        local live = {}
        for _, p in ipairs(list) do if p.flight then live[#live + 1] = p end end
        if #live == 0 then break end
        for i = #list, 1, -1 do list[i] = nil end
        for i, p in ipairs(live) do list[i] = p end
        Flight.step(w, list, f, opts)
    end
end

T.test("shapes: a box lands on its face at its half height", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local p = prop({ 0, 0, 3 })
    advance(w, p, 600)
    T.eq(p.flight, nil, "at rest")
    T.near(p.pos[3], 0.25, 0.01, "half its side above the ground")
end)

T.test("shapes: a box dropped turned tips over onto a face", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local rot = Driver.matrixTB(Colliders.frameOf({ 30, 20, 0 }))
    local p = prop({ 0, 0, 2 }, { rot = rot })
    advance(w, p, 1500)
    T.eq(p.flight, nil, "at rest")
    local r = p.rot
    T.ok(math.max(math.abs(r.r8), math.abs(r.r9), math.abs(r.r10)) > 0.99, "one of its axes upright")
    T.near(p.pos[3], 0.25, 0.01, "on a face")
end)

T.test("shapes: a static's corner holds a wide flat prop (its corners miss the post)", function()
    local post = box({ 0, 0, 1 }, { 0.1, 0.1, 2 })
    local w = Flight.newWorld({ post }, { 0, 0, -9.82 })
    local plate = prop({ 0, 0, 2.5 }, { sides = { 2, 2, 0.1 }, radius = 1.42 })
    advance(w, plate, 60)
    T.ok(plate.pos[3] > 2, "resting on the post's top, not through it")
end)

T.test("shapes: a sphere rolling on grip spins", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local ball = prop({ 0, 0, 0.3 }, { shape = "sphere", sides = { 0.3, 0.3, 0.3 }, radius = 0.3 })
    ball.flight.vel = { 3, 0, 0 }
    advance(w, ball, 50)
    T.ok(ball.flight.ang[2] > 1, "rolling about +y while moving along +x")
end)

T.test("collide: two props flying at each other meet; without it they pass", function()
    local w = Flight.newWorld({}, { 0, 0, 0 })
    local a, b = prop({ -2, 0, 5 }), prop({ 2, 0, 5 })
    a.index, b.index = 1, 2
    a.flight.vel, b.flight.vel = { 5, 0, 0 }, { -5, 0, 0 }
    run(w, { a, b }, 200, true)
    T.ok(a.pos[1] < b.pos[1], "they bounced off each other")
    local c, d = prop({ -2, 0, 5 }), prop({ 2, 0, 5 })
    c.flight.vel, d.flight.vel = { 5, 0, 0 }, { -5, 0, 0 }
    run(w, { c, d }, 200, false)
    T.ok(c.pos[1] > d.pos[1], "collide off: through each other")
end)

T.test("solver: an island's rounds don't depend on props elsewhere (each stops on its own)", function()
    -- a light turned box (test2's mass: its own rounds settle under SETTLE) tipping onto the ground, alone and beside
    -- sliding thrust boxes far away (their islands never settle in ITERATIONS rounds): the same numbers to the last bit.
    -- Rounds stopped by the whole world's change gave the box all ITERATIONS whenever the others were busy
    local function tipping()
        local p = prop({ 0, 0, 1 }, { rot = Driver.matrixTB(Colliders.frameOf({ 30, 20, 0 })), mass = 0.0001 })
        p.index = 1
        return p
    end
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local alone = tipping()
    run(w, { alone }, 150, true)
    local beside = tipping()
    local list = { beside }
    for i = 1, 3 do
        local s = prop({ 50, i * 2, 0.25 }, { thrust = Flight.parseThrust("20 3 0 2") })
        s.index = i + 1
        s.flight.vel = { 2, 0, 0 }
        list[#list + 1] = s
    end
    run(w, list, 150, true)
    T.ok(alone.flight ~= nil and alone.flight.contacts > 0, "still settling on the ground at frame 150")
    for k = 1, 3 do T.eq(beside.pos[k], alone.pos[k], "pos " .. k) end
    for _, key in ipairs({ "r0", "r1", "r2", "r4", "r5", "r6", "r8", "r9", "r10" }) do
        T.eq(beside.rot[key], alone.rot[key], "rot " .. key)
    end
end)

T.test("collide: a flying prop wakes the still one it runs into", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local still = { shape = "box", sides = { 0.5, 0.5, 0.5 }, pos = { 2, 0, 0.25 }, rot = IDENTITY, radius = 0.433,
        index = 2 }
    local a = prop({ 1, 0, 0.4 }) -- just above the ground (sliding on it, grip slows it fast)
    a.index = 1
    a.flight.vel = { 6, 0, 0 }
    run(w, { a }, 100, true, { still })
    T.ok(still.body ~= nil, "woken (it got a body)")
    T.ok(still.pos[1] > 2.1, "pushed along")
end)

T.test("simple level: a sphere of its smallest half side, hits don't turn it, its spin slows", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local simple = { simple = true }
    local plate = prop({ 0, 0, 2 }, { sides = { 2, 2, 0.2 }, radius = 1.42,
        rot = Driver.matrixTB(Colliders.frameOf({ 30, 0, 0 })) })
    advance(w, plate, 600, simple)
    T.eq(plate.flight, nil, "at rest")
    T.near(plate.pos[3], 0.1, 0.01, "resting on its sphere (0.1)")
    T.near(plate.rot.r10, math.cos(math.rad(30)), 1e-9, "never turned by the landing")
    local spun = prop({ 0, 0, 0.25 })
    spun.flight = Flight.start(nil, 0, { 0, 0, 10 })
    advance(w, spun, 5, simple)
    T.ok(spun.flight.ang[3] < 10 * 0.9 ^ 4, "its spin slows on a gripping ground")
end)

T.test("levels: known ones kept, anything else the default", function()
    local Dynamics = ATMOPLAY.Dynamics
    T.eq(Dynamics.level("simple"), "simple", "simple")
    T.eq(Dynamics.level("full"), "full", "full")
    T.eq(Dynamics.level("fast"), Dynamics.DEFAULT_LEVEL, "unknown")
    T.eq(Dynamics.level(nil), "shapes", "default: shapes")
end)

T.test("overlap: boxes crossing (no corner inside) overlap, touching faces don't", function()
    local rotated = { shape = "box", sides = { 0.5, 0.5, 0.5 }, pos = { 0.18, 0, 0 }, radius = 0.433,
        frame = Colliders.frameOf({ 0, 30, 0 }) }
    local plain = { shape = "box", sides = { 0.5, 0.5, 0.5 }, pos = { 0, 0, 0 }, radius = 0.433, frame = Colliders.frameOf({ 0, 0, 0 }) }
    T.ok(Flight.overlap(plain, rotated), "crossing")
    local beside = { shape = "box", sides = { 0.5, 0.5, 0.5 }, pos = { 0.5, 0, 0 }, radius = 0.433, frame = Colliders.frameOf({ 0, 0, 0 }) }
    T.ok(not Flight.overlap(plain, beside), "faces touching: not overlapping")
    local ball = { shape = "sphere", sides = { 0.3, 0.3, 0.3 }, pos = { 0.4, 0, 0 }, radius = 0.3, frame = Colliders.frameOf({ 0, 0, 0 }) }
    T.ok(Flight.overlap(plain, ball), "a sphere into a box")
end)

T.test("prop hits off: flying props pass through, still hit the ground", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local a, b = prop({ -2, 0, 5 }), prop({ 2, 0, 5 })
    a.index, b.index, a.noHits = 1, 2, true
    a.flight.vel, b.flight.vel = { 5, 0, 0 }, { -5, 0, 0 }
    run(w, { a, b }, 100, true)
    T.ok(a.pos[1] > b.pos[1], "through each other")
    local c = prop({ 0, 0, 2 }, { noHits = true })
    advance(w, c, 600)
    T.near(c.pos[3], 0.25, 0.01, "on the ground")
end)

T.test("shapes: a pill's inertia is ODE's capsule's (cylinder + two half spheres), not the box around it", function()
    local pill = { shape = "cylinder", sides = { 0.25, 0.25, 0.25 }, mass = 0.1 }
    local b = Flight.bodyOf(pill)
    -- dMassSetCapsuleTotal(0.1, r 0.25, l 0.25): by volume, cylinder 0.0491, the half spheres 0.0654 (of 0.1145)
    local r, l = 0.25, 0.25
    local m1, m2 = math.pi * r * r * l, 4 / 3 * math.pi * r ^ 3
    local k = 0.1 / (m1 + m2)
    local along = k * (m1 * 0.5 * r * r + m2 * 0.4 * r * r)
    local across = k * (m1 * (0.25 * r * r + l * l / 12) + m2 * (0.4 * r * r + 0.375 * r * l + 0.25 * l * l))
    T.near(1 / b.invI[3], along, 1e-12, "about its length")
    T.near(1 / b.invI[1], across, 1e-12, "across")
    T.near(1 / b.invI[1], 0.00455, 2e-5, "~0.00455 (the box around it: 0.00677)")
end)
