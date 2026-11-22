-- atmoplay/flight.lua: drawn flight against the numbers measured in game (tools/atmoplay/probe_thrust.lua,
-- docs/atmo-play-plan.md section 7: data/mod/mge_tests/atmoplay_probe.tbm and atmoplay_probe_friction.tbm)
local T = ...
local Flight = ATMOPLAY.Flight
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
    T.ok(Flight.advance(w, p, 100), "still flying")
    T.near(p.pos[3], 148.21472, 1e-5, "z at frame 100")
    T.near(p.flight.vel[3], -5.892, 1e-9, "vz at frame 100")
    Flight.advance(w, p, 600)
    T.near(p.pos[3], 86.26035, 1e-5, "z at frame 600")
    T.near(p.flight.vel[3], -35.352, 1e-9, "vz at frame 600")
end)

T.test("flight: thrust is a one-step force on its push frames (probe objs 2, 3, 4)", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local every1 = prop({ 0, 34, 150 }, { thrust = Flight.parseThrust("1 0.1 0 0") })
    local heavy = prop({ 0, 38, 150 }, { thrust = Flight.parseThrust("1 0.1 0 0"), mass = 2 })
    local every5 = prop({ 0, 42, 150 }, { thrust = Flight.parseThrust("5 0.1 0 0") })
    Flight.advance(w, every1, 1)
    T.near(every1.flight.vel[1], 0.0006, 1e-12, "first push into frame 1")
    Flight.advance(w, every5, 5)
    T.near(every5.flight.vel[1], 0.0006, 1e-12, "thrust 5: one push by frame 5")
    Flight.advance(w, every5, 6)
    T.near(every5.flight.vel[1], 0.0012, 1e-12, "the second into frame 6")
    for _, p in ipairs({ every1, heavy, every5 }) do Flight.advance(w, p, 600) end
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
    Flight.advance(w, p, 600)
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
    T.eq(Flight.frictionLoss(5, -10000, nil, 1), 0, "-10000 frictionless")
    T.eq(Flight.frictionLoss(5, 10000, -10000, 1), 0, "the lower side wins")
    T.near(Flight.frictionLoss(5, -9999, nil, 1), 0.012, 1e-12, "-9999: 0.012 a frame")
    T.near(Flight.frictionLoss(5, nil, nil, 1), 0.55, 1e-12, "grip: 11% a frame")
    T.near(Flight.frictionLoss(0.01, -9999, nil, 1), 0.0011, 1e-12, "never more than grip")
    T.near(Flight.parseGravity("0.00 0.00 -30.00")[3], -30, 1e-12, "gravity line")
    T.eq(Flight.parseGravity("x"), nil, "not a gravity")
end)

T.test("flight: bounces off the ground, comes to rest and ends", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local p = prop({ 0, 0, 8 }, { bounce = 10 })
    local vin, vout
    for f = 1, 400 do
        local before = p.flight.vel[3]
        Flight.advance(w, p, f)
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
        flying = Flight.advance(w, plain, f)
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
    Flight.advance(w, p, 200)
    T.ok(p.pos[1] < 4.5 - 0.24, "stopped at the wall's face")
    local slippery = box({ 0, 0, 1 }, { 40, 2, 1 }, { friction = -10000 })
    local grippy = box({ 0, 10, 1 }, { 40, 2, 1 })
    w = Flight.newWorld({ slippery, grippy }, { 0, 0, -9.82 })
    local a, b = prop({ -15, 0, 1.75 }), prop({ -15, 10, 1.75 })
    a.flight.vel, b.flight.vel = { 5, 0, 0 }, { 5, 0, 0 }
    Flight.advance(w, a, 100)
    Flight.advance(w, b, 100)
    T.near(a.flight.vel[1], 5, 1e-9, "frictionless: as fast")
    T.ok(b.flight == nil or b.flight.vel[1] < 0.01, "grip: stopped")
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
    Flight.advance(w, p, 100)
    -- 1.2 rad about +z: its own x axis (the matrix's first column) points at cos, sin
    T.near(p.rot.r0, math.cos(1.2), 1e-9, "x axis, x")
    T.near(p.rot.r4, math.sin(1.2), 1e-9, "x axis, y")
    T.near(p.rot.r10, 1, 1e-9, "z axis kept")
    T.eq(Flight.start(nil, 0, { 0, 0, 0 }).ang, nil, "no spin: none kept")
end)

T.test("flight: a thrust on its own axes turns with the spin", function()
    local w = Flight.newWorld({}, { 0, 0, 0 })
    local p = prop({ 0, 0, 50 }, { thrust = Flight.parseThrust("1 1 0 0 1") })
    p.flight = Flight.start(nil, 0, { 0, 0, math.pi / 2 / (100 * Flight.DT) }) -- a quarter turn in 100 frames
    Flight.advance(w, p, 200)
    T.ok(p.flight.vel[2] > 0.1, "pushed along y too once turned")
    local still = prop({ 0, 0, 50 }, { thrust = Flight.parseThrust("1 1 0 0 1") })
    Flight.advance(w, still, 200)
    T.near(still.flight.vel[2], 0, 1e-12, "not spinning: along x only")
end)

T.test("flight: spin slows on a gripping contact, then the flight rests", function()
    local w = Flight.newWorld({}, { 0, 0, -9.82 })
    local p = prop({ 0, 0, 0.25 })
    p.flight = Flight.start(nil, 0, { 0, 0, 10 })
    Flight.advance(w, p, 5)
    T.ok(p.flight.ang[3] < 10 * 0.9 ^ 4, "slowed on the ground")
    local flying = true
    for f = 6, 400 do
        flying = Flight.advance(w, p, f)
        if not flying then break end
    end
    T.ok(not flying, "at rest once the spin died down")
    local slick = prop({ 0, 0, 0.25 }, { friction = -10000 })
    slick.flight = Flight.start(nil, 0, { 0, 0, 10 })
    Flight.advance(w, slick, 50)
    T.near(slick.flight.ang[3], 10, 1e-12, "frictionless: spins on")
end)
