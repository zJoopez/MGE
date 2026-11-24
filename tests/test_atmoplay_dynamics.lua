-- atmoplay/dynamics.lua (props, proof of concept), plus the parts of format.lua and colliders.lua it adds:
-- props apart from static colliders, the dynamic pool's markers, taking / releasing in fights, watching
-- replays, rebuilding from events. The engine is a small fake world (objects and two players' body parts)
local T = ...
local Format = ATMOPLAY.Format
local Colliders = ATMOPLAY.Colliders
local Dynamics = ATMOPLAY.Dynamics

---------------------------------------------------------------------------------------------------- fake world

local world -- objects[id] = { pos, rot, lin, ang, sides, mass, bounce }, players[p] = point
local calls

local function stubEngine()
    world = { objects = {}, players = { { 0, 0, 1 }, { 50, 50, 1 } } }
    calls = {}
    BODYPARTS = { HEAD = 0 }
    get_world_state = function() return { num_players = 2 } end
    get_body_info = function(player, _)
        local p = world.players[player + 1]
        return { pos = { x = p[1], y = p[2], z = p[3] } }
    end
    local function obj(id)
        world.objects[id] = world.objects[id] or { pos = { 0, 0, 0 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, mass = 1 }
        return world.objects[id]
    end
    get_obj_pos = function(id) local o = obj(id) return o.pos[1], o.pos[2], o.pos[3] end
    get_obj_rot = function(id) return obj(id).rot or { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 } end
    get_obj_linear_vel = function(id) local v = obj(id).lin return v[1], v[2], v[3] end
    get_obj_angular_vel = function(id) local v = obj(id).ang return v[1], v[2], v[3] end
    get_obj_mass = function(id) return obj(id).mass end
    get_obj_bounce = function() return 0.1 end
    set_obj_pos = function(id, x, y, z) obj(id).pos = { x, y, z }; calls[#calls + 1] = "pos " .. id end
    set_obj_rot_m = function(id, m) obj(id).rot = m end
    set_obj_sides = function(id, x, y, z) obj(id).sides = { x, y, z }; calls[#calls + 1] = "sides " .. id end
    get_obj_sides = function(id) local v = obj(id).sides or { 1, 1, 1 } return v[1], v[2], v[3] end
    get_obj_shape = function() return 1 end -- every object a box
    set_obj_color = function(id, r, g, b, a) obj(id).color = { r, g, b, a } end
    set_obj_flag = function(id, flag) obj(id).flag = flag end
    get_body_linear_vel = function() return 0, 0, 0 end -- players stand still
    set_obj_linear_vel = function(id, x, y, z) obj(id).lin = { x, y, z } end
    set_obj_angular_vel = function(id, x, y, z) obj(id).ang = { x, y, z } end
    set_obj_mass = function(id, m) obj(id).mass = m; calls[#calls + 1] = "mass " .. id end
    set_obj_bounce = function() end
    set_obj_force = function(id, x, y, z) obj(id).force = { x, y, z }; calls[#calls + 1] = "force " .. id end
end

local ATMO = [[
env_obj floor
   shape box
   pos 0 0 0
   sides 20 20 1
   flag 8
env_obj crateA
   shape box
   pos 1 0 1
   sides 0.4 0.4 0.4
   color 0.2 0.4 0.6 1
   flag 0
env_obj crateB
   shape box
   pos 1.5 0 1
   sides 0.4 0.4 0.4
   flag 0
env_obj far
   shape box
   pos 30 30 1
   sides 0.4 0.4 0.4
   flag 0
env_obj plain
   shape box
   pos 5 5 5]]

local function setup(poolSize)
    stubEngine()
    local colliders, stats, props = Colliders.build(T.lines(ATMO))
    local objects = {}
    for i = 1, poolSize do objects[i] = { id = i, shape = "box" } end
    local s = Dynamics.new(objects, props, { dradius = 2, fromFrame = 0 }) -- the rules, not the timing (FIRST_FRAME: own test)
    -- the pool parked, as the file puts it
    for i = 1, poolSize do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    return s, colliders, stats, props
end

local function carried(s)
    local names = {}
    for _, e in ipairs(s.entries) do names[#names + 1] = e.prop and e.prop.name or "-" end
    return table.concat(names, " ")
end

---------------------------------------------------------------------------------------------------- format, colliders

T.test("props: a flag without the static bit, apart from the static colliders", function()
    local _, colliders, stats, props = setup(2)
    T.eq(#colliders, 2, "floor and plain (no flag line) are static colliders")
    T.eq(#props, 3, "three props")
    T.eq(stats.props, 3, "counted")
    T.eq(props[1].name, "crateA", "atmo order")
    T.eq(props[1].mass, nil, "no mass line (a prop's mass makes its own group: see the mass test)")
    T.ok(Colliders.isDynamicFlag("0") and Colliders.isDynamicFlag("4"), "flags without 8")
    T.ok(not Colliders.isDynamicFlag("8") and not Colliders.isDynamicFlag("12") and not Colliders.isDynamicFlag(nil),
        "static flags and no flag")
end)

T.test("format: dynamic pool and parking platform markers, dradius", function()
    local h = Format.parseHeader(Format.headerLine({ rule = 1, radius = 4, dradius = 2.5 }))
    T.eq(h.dradius, 2.5, "dradius round trip")
    local lines = T.lines([[
env_obj 1
   #atmoplay dynamic
   shape box
   flag 0
env_obj 2
   shape sphere
   friction 5
   #atmoplay dynamic
env_obj 3
   shape box
env_obj 49
   #atmoplay park
   shape box
env_obj 50
   #atmoplay pool
   shape box
#atmoplay v1 rule=1 radius=4 dradius=2
#@ env_obj a]])
    local file = Format.read(lines)
    T.eq(#file.dynamic, 2, "two dynamic pool objects")
    T.eq(file.dynamic[2].shape, "sphere", "shape")
    T.eq(file.dynamic[2].friction, "5", "friction")
    T.eq(file.park, 49, "park id")
    T.eq(#file.pool, 1, "the static pool apart")
    local split = Format.split(lines)
    T.eq(table.concat(split.pool, ","), "1,2,49,50", "every marked block leaves the mod's lines")
    T.ok(T.find(split.lines, "env_obj 3"), "the mod's own object stays")
    T.ok(not T.find(split.lines, "env_obj 49"), "the park block left")
end)

---------------------------------------------------------------------------------------------------- fights

T.test("fight: props near a player are taken, a far one isn't", function()
    local s = setup(3)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crateA crateB -", "nearest first; the far crate stays")
    T.near(world.objects[0].pos[1], 1, 1e-9, "object 0 at crateA")
    T.eq(world.objects[0].mass, 1, "no mass line: the object's own")
    T.near(world.objects[0].sides[1], 0.4, 1e-9, "the crate's size")
    T.eq(world.objects[0].flag, nil, "crateA: flag 0, as the pool object is written: no call")
    T.eq(world.objects[1].flag, nil, "crateB: flag 0 as well")
    T.eq(#s.events, 2, "two takes")
    T.eq(s.events[1].frame, 0, "match_begin's moves are tagged frame 0")
    local centers = Dynamics.centers(s)
    T.eq(#centers, 2, "carried props for the static pool")
end)

T.test("fight: release only when unwanted, at rest and untouched; free from the next frame", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crateA", "taken")
    -- the player walks away, the crate still moving
    world.players[1] = { 20, 0, 1 }
    world.objects[0].lin = { 1, 0, 0 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "crateA", "moving: kept")
    -- at rest, pushed to 1.2
    world.objects[0].lin = { 0, 0, 0 }
    world.objects[0].pos = { 1.2, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "-", "released")
    T.near(s.props[1].pos[1], 1.2, 1e-9, "the prop stays where it was pushed")
    T.ok(math.abs(world.objects[0].pos[3] - Dynamics.PARK_Z) < Dynamics.PARKED, "object parked (above the map)")
    -- the player near crateB now: the freed object takes it on a later frame, not the release frame
    world.players[1] = { 1.5, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 3 })
    T.eq(carried(s), "crateB", "taken next frame")
end)

T.test("fight: a body part near a resting crate keeps it", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    world.players[2] = { 1, 0, 1.2 } -- the other player standing on it, out of reach of player 1's center
    world.players[1] = { 20, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "crateA", "wanted by player 2 anyway")
    world.players[2] = { 1, 0, 3.6 } -- above: out of reach and not touching
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "-", "released once nothing is near")
end)

T.test("default timing: no takes before frame 1; replays watch, past the fight's frames too", function()
    local s = setup(1)
    s.fromFrame = ATMOPLAY.Driver.FIRST_FRAME -- as Dynamics.new sets it without the tests' 0
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    Dynamics.draw(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "-", "frame 0: nothing taken (an R now replays nothing moved)")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "crateA", "frame 1: taken")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 5 })
    -- R (no match_begin): every frame is watched, the unplayed ones after the fight's too (no tail)
    world.players[1] = { 20, 0, 1 }
    local n = #calls
    for f = 0, 12 do Dynamics.draw(s, { replay_mode = 1, match_frame = f }) end
    T.eq(#calls, n, "an R replay sets nothing")
    T.eq(carried(s), "crateA", "nothing released by a rule: the object is watched")
    -- an opened replay (match_begin in a replay): all recorded, never stepped
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    world.players[1] = { 1, 0, 1 }
    n = #calls
    for f = 0, 10 do Dynamics.draw(s, { replay_mode = 1, match_frame = f }) end
    T.eq(#calls, n, "an opened replay sets nothing")
end)

---Calls of a kind ("sides", "mass", "pos") since index n, for object id
local function callsOf(kind, id, n)
    local count = 0
    for i = (n or 0) + 1, #calls do
        if calls[i] == kind .. " " .. id then count = count + 1 end
    end
    return count
end

T.test("a prop's mass: its own group, carried by a pool object written with that mass (no mass call)", function()
    stubEngine()
    local _, _, props = Colliders.build(T.lines([[
env_obj light
   shape box
   pos 1 0 1
   sides 0.4 0.4 0.4
   flag 0
env_obj heavy
   shape box
   pos 1.5 0 1
   sides 0.4 0.4 0.4
   flag 0
   mass 30]]))
    T.eq(props[1].group, "box|", "no mass line")
    T.eq(props[2].group, "box|||||30", "its mass in its group (replays don't record set_obj_mass)")
    local objects = { { id = 1, shape = "box" }, { id = 2, shape = "box", mass = "30" } }
    local s = Dynamics.new(objects, props, { dradius = 2, fromFrame = 0 })
    for i = 1, 2 do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    world.objects[1].mass = 30
    local n = #calls
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "light heavy", "each by its own group's object")
    T.eq(callsOf("mass", 1, n), 0, "the heavy one's object has the mass from the mod: no set_obj_mass")
    T.eq(Colliders.groupKey("box", { mass = "30" }), "box|", "a static object's mass doesn't count (it doesn't move)")
end)

T.test("a pool written at the props' size: taking and releasing resizes and re-masses nothing", function()
    stubEngine()
    local _, _, props = Colliders.build(T.lines(ATMO))
    -- as MGE writes it: crateA's size, parked at its own spot
    local objects = { { id = 1, shape = "box", sides = "0.4 0.4 0.4", pos = "-3 0 49999" } }
    local s = Dynamics.new(objects, props, { dradius = 2, fromFrame = 0 })
    world.objects[0] = { pos = { -3, 0, 49999 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, sides = { 0.4, 0.4, 0.4 }, mass = 0.3 }
    local n = #calls
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crateA", "taken")
    T.eq(callsOf("sides", 0, n), 0, "its size already: no set_obj_sides")
    T.eq(callsOf("mass", 0, n), 0, "no set_obj_mass")
    world.players[1] = { 20, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "-", "released")
    T.eq(callsOf("sides", 0, n), 0, "parked at its own size: still no resize")
    T.near(world.objects[0].pos[1], -3, 1e-9, "on its own spot (the file's pos)")
    -- crateB: another size
    world.players[1] = { 1.6, 0, 1 }
    world.objects[0].lin = { 0, 0, 0 }
    s.props[1].pos = { 30, 0, 1 } -- crateA out of reach
    n = #calls
    s.props[2].sides = { 0.6, 0.6, 0.6 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "crateB", "the other crate")
    T.eq(callsOf("sides", 0, n), 1, "resized once for it")
    world.players[1] = { 20, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 3 })
    T.eq(callsOf("sides", 0, n), 2, "and back to its own size when parked")
end)

T.test("a pool object of another size than its prop: resized for it, and back to its own when parked", function()
    local s = setup(1) -- pool objects without size lines: PARK_SIDE
    local n = #calls
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(callsOf("sides", 0, n), 1, "PARK_SIDE to the crate's size")
    world.players[1] = { 20, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(world.objects[0].sides[1], Dynamics.PARK_SIDE, "back to its own size")
end)

T.test("props park above the map", function()
    T.ok(Dynamics.PARK_Z > 0, "the parking height is above the map (below z = 0 the ground pushes dynamic bodies out)")
    local s = setup(1)
    T.ok(s.entries[1].home.pos[3] > 0, "a spot from the formula is up there")
end)

T.test("back in a fight from a replay: a carried prop in place and moving is left alone", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crateA", "taken")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 10 })
    world.objects[0].lin = { 1, 0, 0 } -- pushed
    Dynamics.draw(s, { replay_mode = 1, match_frame = 4 }) -- watched: the prop's pose from its object
    world.objects[0].pos = { world.objects[0].pos[1] + 0.2, 0, 1 } -- moved on since
    local n = #calls
    Dynamics.draw(s, { replay_mode = 0, match_frame = 5 }) -- an edit: the fight goes on from here
    T.eq(world.objects[0].lin[1], 1, "still moving: not stopped")
    T.eq(callsOf("pos", 0, n), 0, "not put back")
    T.near(s.props[1].pos[1], world.objects[0].pos[1], 1e-9, "the prop's pose follows its object")
end)

T.test("back in a fight from a replay: objects the game left at 0,0,0 are set again", function()
    local s = setup(2)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crateA crateB", "both taken")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 10 })
    -- R: the recorded frames, then the game puts everything a script touched at the origin
    Dynamics.draw(s, { replay_mode = 1, match_frame = 5 })
    for id = 0, 1 do world.objects[id].pos, world.objects[id].sides = { 0, 0, 0 }, { 9, 9, 9 } end
    Dynamics.draw(s, { replay_mode = 0, match_frame = 11 }) -- an edit there: the fight goes on
    for id = 0, 1 do
        local p = world.objects[id].pos
        T.ok(math.abs(p[1]) + math.abs(p[2]) + math.abs(p[3]) > 0.01, "object " .. id .. " off the origin")
        T.ok(world.objects[id].sides[1] < 9, "object " .. id .. " at a real size again")
    end
end)

T.test("fight: a crate that fell off the map is released", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    world.objects[0].pos = { 1, 0, -100 }
    world.objects[0].lin = { 0, 0, -30 }
    world.players[1] = { 1, 0, -100 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "-", "released though moving and touched")
end)

T.test("fight: a full pool lets a far moving prop go for a near waiting one: it flies on drawn", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crateA", "taken")
    -- crateA kicked away, still flying; crateB next to the player has no object
    world.objects[0].pos = { 10, 0, 1 }
    world.objects[0].lin = { 5, 0, 0 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "-", "crateA let go though moving")
    T.near(s.props[1].pos[1], 10, 1e-9, "where its object was")
    T.ok(s.props[1].flight ~= nil, "flying on drawn")
    T.nearList(s.props[1].flight.vel, { 5, 0, 0 }, 1e-9, "at its object's velocity")
    T.ok(math.abs(world.objects[0].pos[3] - Dynamics.PARK_Z) < Dynamics.PARKED, "its object parked (above the map)")
    T.eq(s.events[#s.events].kind, "release", "a release event: replays see the object park")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "crateB", "the near one gets the object the next frame")
    T.near(s.props[1].pos[1], 10 + 5 * ATMOPLAY.Flight.DT, 1e-9, "crateA flew one frame on")
end)

T.test("fight: a full pool keeps a moving prop about as near as the waiting one", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    -- crateA rolling just behind crateB: farther from the player, but by less than EVICT_MARGIN
    world.players[1] = { 3.6, 0, 1 }
    world.objects[0].pos = { 1.4, 0, 1 }
    world.objects[0].lin = { 1, 0, 0 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "crateA", "kept: no swapping back and forth")
    -- it rolls the other way, out of reach: frozen now
    world.objects[0].pos = { -5, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "-", "frozen")
end)

T.test("fight: the mod's own dynamic objects want props too", function()
    local s = setup(1)
    world.players[1] = { 20, 0, 1 }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "-", "no player near anything")
    -- a ball of the mod (id 10) rolling up to the far crate
    s.follow = { 10 }
    world.objects[10] = { pos = { 30, 28, 1 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, sides = { 1, 1, 1 }, mass = 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "far", "taken for the ball")
end)

---Crates on the y axis (atmo order as given), a pool of `poolSize`, the players far away and a cube of the
---mod (id 20, sides 1) at the origin moving at `vy`, as modmaker/test2.tbm's thrust cubes
local function lineSetup(ys, poolSize, vy)
    stubEngine()
    local lines = {}
    for i, y in ipairs(ys) do
        lines[#lines + 1] = "env_obj c" .. i
        lines[#lines + 1] = "   shape box"
        lines[#lines + 1] = "   pos 0 " .. y .. " 1"
        lines[#lines + 1] = "   sides 0.4 0.4 0.4"
        lines[#lines + 1] = "   flag 0"
    end
    local _, _, props = Colliders.build(lines)
    local objects = {}
    for i = 1, poolSize do objects[i] = { id = i, shape = "box" } end
    local s = Dynamics.new(objects, props, { dradius = 2, follow = { 20 }, fromFrame = 0 })
    for i = 1, poolSize do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    world.players = { { 100, 0, 1 }, { 100, 50, 1 } }
    world.objects[20] = { pos = { 0, 0, 1 }, lin = { 0, vy, 0 }, ang = { 0, 0, 0 }, sides = { 1, 1, 1 }, mass = 20 }
    return s
end

T.test("lookahead: the crate ahead of a fast cube before the one as near behind it", function()
    local s = lineSetup({ -1.5, 1.5 }, 1, 0)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "c1", "a still cube: as near, the lower atmo index")
    s = lineSetup({ -1.5, 1.5 }, 1, 20)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "c2", "moving +y: the one ahead")
end)

T.test("lookahead: a full pool freezes the crate the cube left behind for the one ahead", function()
    local s = lineSetup({ -2, 3 }, 1, 0)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "c1", "the cube standing: the nearer one, behind")
    -- the cube flies +y, the crate behind follows slower: nearer by distance, but falling back
    world.objects[20].lin = { 0, 20, 0 }
    world.objects[0].lin = { 0, 5, 0 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "-", "the crate behind frozen though moving")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "c2", "the crate ahead gets the object")
end)

T.test("tiers: a crate near a player before one the cube is about to hit", function()
    local s = lineSetup({ -1.5, 1.5 }, 1, 20)
    world.players[1] = { 0, -2.6, 1 } -- near c1 (not touching it), far from c2
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "c1", "the player's crate, though the cube's is nearer")
end)

T.test("tiers: a full pool freezes the cube's crate for a player's, however near", function()
    local s = lineSetup({ -1.5, 1.5 }, 1, 20)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "c2", "players far: the cube's crate")
    -- c2 pushed along with the cube (nearer to it than c1 will be to the player), the player walks up to c1
    world.objects[0].lin = { 0, 20, 0 }
    world.players[1] = { 0, -2.6, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "-", "the cube's crate frozen")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "c1", "the player's crate gets the object")
end)

---------------------------------------------------------------------------------------------------- replays

T.test("replay: watching the objects finds takes and releases", function()
    local s = setup(2)
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    T.eq(carried(s), "- -", "a replay moves nothing at its start")
    T.eq(#calls, 2, "no object calls (only the setup's two parks)")
    -- the replay's FRAME 0: object 1 appears at crateB
    world.objects[1].pos = { 1.5, 0, 1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 0 })
    T.eq(carried(s), "- crateB", "object 1 took crateB")
    world.objects[1].pos = { 2, 0, 1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 1 })
    T.near(s.props[2].pos[1], 2, 1e-9, "the prop follows its object")
    world.objects[1].pos = { Dynamics.parkPos(2) }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 2 })
    T.eq(carried(s), "- -", "released")
    T.near(s.props[2].pos[1], 2, 1e-9, "left where last seen")
    T.eq(#calls, 2, "still no object calls in the replay")
    -- rewind to frame 1 (the object where it was then): rebuilt from the events, then watched
    world.objects[1].pos = { 2, 0, 1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 1 })
    T.eq(carried(s), "- crateB", "carried again at frame 1")
    -- back to frame 0 and further: before the take
    Dynamics.rebuild(s, -1)
    T.eq(carried(s), "- -", "nothing before frame 0")
    T.near(s.props[2].pos[1], 1.5, 1e-9, "at the atmo's pose")
end)

T.test("fight after a replay: the props as they were at that frame", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    world.players[1] = { 20, 0, 1 }
    world.objects[0].pos = { 1.3, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 }) -- released at 1.3, tagged frame 2
    T.eq(carried(s), "-", "released")
    -- replay view of the fight so far, then back to the fight at frame 1 (before the release showed)
    Dynamics.draw(s, { replay_mode = 1, match_frame = 1 })
    world.objects[0].pos = { 1.3, 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "crateA", "at frame 1 the crate was still carried")
end)

---------------------------------------------------------------------------------------------------- the mod's own dynamic objects, MGE's drawing

T.test("the static pool follows the mod's own dynamic objects (not the dynamic pool)", function()
    stubEngine()
    local Driver = ATMOPLAY.Driver
    local Pool = ATMOPLAY.Pool
    -- ids 0, 1: dynamic (0 is the dynamic pool's, file id 1), 2: static, 3: a static pool object
    world.objects[0] = { pos = { 0, 0, -50000 }, flag = 0 }
    world.objects[1] = { pos = { 30, 0, 1 }, flag = 0 }
    world.objects[2] = { pos = { 5, 5, 0 }, flag = 8 }
    world.objects[3] = { pos = { 3, 0, -100000 }, flag = 8 }
    get_obj_pos = function(id)
        local o = world.objects[id]
        if not o then return nil end
        return o.pos[1], o.pos[2], o.pos[3]
    end
    get_obj_flag = function(id) return world.objects[id] and world.objects[id].flag end
    local ids = Driver.dynamicIds({ [1] = true })
    T.eq(table.concat(ids, ","), "1", "only the mod's dynamic object")
    -- a floor far from the players, under that object: the pool covers it
    local colliders = Colliders.build(T.lines([[
env_obj floorFar
   shape box
   pos 30 0 0
   sides 4 4 1]]))
    local pool = Pool.new({ { id = 4, shape = "box" } }, colliders, { radius = 4 })
    get_obj_bounce = function() return nil end
    set_obj_flag = function() end
    local d = Driver.new(pool)
    Driver.drive(d, { match_frame = 0 })
    T.eq(pool.entries[1].target, nil, "players far away: no floor")
    d.follow = ids
    Driver.drive(d, { match_frame = 1 })
    T.eq(pool.entries[1].target and pool.entries[1].target.name, "floorFar", "the floor under the object")
end)

T.test("movedProp: a moved prop's pose by atmo index, nothing for one at home", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(Dynamics.movedProp(s, 2), nil, "crateA (atmo entity 2) taken but not moved yet: at home")
    world.objects[0].pos = { 1.4, 0, 1 }
    world.objects[0].rot = { 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 } -- turned about z
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    local m = Dynamics.movedProp(s, 2)
    T.ok(m ~= nil, "moved")
    T.near(m.pos[1], 1.4, 1e-9, "where it is")
    T.eq(m.frame[1][2], -1, "rotation rows from the matrix")
    T.eq(m.frame[2][1], 1, "rotation rows from the matrix")
    T.eq(Dynamics.movedProp(s, 2), m, "the same result while the pose holds")
    T.eq(Dynamics.movedProp(s, 1), nil, "the floor isn't a prop")
end)

---------------------------------------------------------------------------------------------------- the grid

---A field of crates (some scattered, two groups), players walking through it; carried crates drift while
---"moving" (deterministic from the takes). Returns the fight's events and the pool objects' positions per frame
local function gridField()
    local lines = {}
    math.randomseed(7)
    for i = 0, 299 do
        local x, y = (i % 20) * 0.9 + math.random() * 0.3, math.floor(i / 20) * 0.9 + math.random() * 0.3
        lines[#lines + 1] = "env_obj c" .. i
        lines[#lines + 1] = "   shape " .. (i % 7 == 0 and "sphere" or "box")
        lines[#lines + 1] = string.format("   pos %.3f %.3f 0.2", x, y)
        lines[#lines + 1] = i % 7 == 0 and "   sides 0.25 0 0" or "   sides 0.4 0.4 0.4"
        lines[#lines + 1] = "   flag 0"
    end
    return lines
end

local function runFight(noGrid)
    stubEngine()
    local _, _, props = Colliders.build(gridField())
    local objects = {}
    for i = 1, 12 do objects[i] = { id = i, shape = i <= 3 and "sphere" or "box" } end
    local s = Dynamics.new(objects, props, { dradius = 2, noGrid = noGrid, fromFrame = 0 })
    for i = 1, 12 do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    local track = {}
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    for f = 1, 160 do
        world.players[1] = { f * 0.12, f * 0.09, 1 }
        world.players[2] = { 18 - f * 0.1, f * 0.11, 1 }
        -- carried crates drift and move for a while after each take, then rest
        for _, e in ipairs(s.entries) do
            local o = world.objects[e.id - 1]
            if e.prop then
                local moving = (f + e.id) % 12 < 6
                o.lin = moving and { 0.5, 0.2, 0 } or { 0, 0, 0 }
                if moving then o.pos = { o.pos[1] + 0.05, o.pos[2] + 0.02, o.pos[3] } end
            end
        end
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        local frameTrack = {}
        for i = 1, 12 do
            local p = world.objects[i - 1].pos
            frameTrack[i] = { p[1], p[2], p[3] }
        end
        track[f + 1] = frameTrack -- shows from the next frame, as the moves are tagged
    end
    local log = {}
    for _, ev in ipairs(s.events) do
        log[#log + 1] = string.format("%d %s %d %d", ev.frame, ev.kind, ev.entry.id, ev.prop.index)
    end
    return log, track
end

local function runWatch(noGrid, track)
    stubEngine()
    local _, _, props = Colliders.build(gridField())
    local objects = {}
    for i = 1, 12 do objects[i] = { id = i, shape = i <= 3 and "sphere" or "box" } end
    local s = Dynamics.new(objects, props, { dradius = 2, noGrid = noGrid, fromFrame = 0 })
    for i = 1, 12 do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    for f = 1, 161 do
        if track[f] then
            for i = 1, 12 do world.objects[i - 1].pos = track[f][i] end
        end
        Dynamics.draw(s, { replay_mode = 1, match_frame = f })
    end
    local log = {}
    for _, ev in ipairs(s.events) do
        log[#log + 1] = string.format("%s %d %d", ev.kind, ev.entry.id, ev.prop.index)
    end
    return log
end

T.test("the grid finds the same props as looking at every one (fights and replays)", function()
    local gridLog, track = runFight(false)
    local fullLog = runFight(true)
    T.ok(#gridLog > 20, "a busy fight: " .. #gridLog .. " events")
    T.eq(table.concat(gridLog, "\n"), table.concat(fullLog, "\n"), "the same takes and releases")
    local watchGrid, watchFull = runWatch(false, track), runWatch(true, track)
    T.ok(#watchGrid > 20, "the replay watched them: " .. #watchGrid .. " events")
    T.eq(table.concat(watchGrid, "\n"), table.concat(watchFull, "\n"), "the same in the replay")
end)

T.test("drawn copies: hidden while carried (the object shows), back where they stay when released", function()
    local s = setup(2)
    local moves, items = {}, {}
    local function holder()
        local h = { child = {} }
        for _, prop in ipairs(s.props) do
            local p = prop.home.pos
            local item = { shift = { x = p[1], y = p[2], z = p[3] }, name = prop.name, displayed = true }
            function item:moveTo(x, y, z) moves[#moves + 1] = self.name; self.shift = { x = x, y = y, z = z } end
            function item:hide() self.displayed = false end
            function item:show() self.displayed = true end
            h.child[#h.child + 1] = item
            items[prop.name] = item
        end
        return h
    end
    local savedAtmo, savedUtils = rawget(_G, "Atmospheres"), rawget(_G, "Utils3D")
    Atmospheres = { EntityHolder = holder() }
    Utils3D = { MatrixTBToMatrix = function() return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } end,
        MatrixToMatrixTB = function() return {} end }
    local ok, err = pcall(function()
        Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
        T.eq(carried(s), "crateA crateB", "both taken")
        T.ok(not items.crateA.displayed and not items.crateB.displayed, "their copies hidden")
        T.ok(items.far.displayed, "the far one's copy shows")
        T.eq(table.concat(world.objects[0].color, " "), "0.2 0.4 0.6 1", "crateA's object in crateA's color")
        T.eq(table.concat(world.objects[1].color, " "), "1 1 1 1", "no color line: white")
        world.objects[0].pos = { 1.1, 0, 1 }
        Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
        T.eq(#moves, 0, "a carried copy isn't moved: hidden")
        world.players[1] = { 20, 0, 1 }
        world.objects[1].pos = { 1.6, 0, 1 }
        Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
        T.eq(carried(s), "- -", "both released")
        table.sort(moves)
        T.eq(table.concat(moves, ","), "crateA,crateB", "drawn where they stay")
        T.ok(items.crateA.displayed and items.crateB.displayed, "and shown")
        moves = {}
        Dynamics.draw(s, { replay_mode = 0, match_frame = 3 })
        T.eq(#moves, 0, "released ones aren't redrawn again")
        Atmospheres.EntityHolder = holder() -- the atmo loaded again: its copies at the atmo's poses
        Dynamics.draw(s, { replay_mode = 0, match_frame = 4 })
        table.sort(moves)
        T.eq(table.concat(moves, ","), "crateA,crateB", "the moved ones drawn again on the new atmo")
        -- taken again, then Atmo Play leaves the mod: every copy shown at the atmo's pose
        world.players[1] = { 1.1, 0, 1 }
        Dynamics.draw(s, { replay_mode = 0, match_frame = 5 })
        T.ok(not items.crateA.displayed, "carried again: hidden")
        Dynamics.restoreCopies(s)
        T.ok(items.crateA.displayed, "restored: shown")
    end)
    Atmospheres, Utils3D = savedAtmo, savedUtils
    if not ok then error(err) end
end)

T.test("replay: an object that took a prop is painted its color, the copy hidden", function()
    local s = setup(2)
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    world.objects[0].pos = { 1, 0, 1 } -- object 0 appears at crateA
    Dynamics.draw(s, { replay_mode = 1, match_frame = 0 })
    T.eq(carried(s), "crateA -", "watched")
    T.eq(table.concat(world.objects[0].color, " "), "0.2 0.4 0.6 1", "painted")
    T.ok(Dynamics.isCarried(s, s.props[1].index), "carried: MGE leaves it to the object")
    T.ok(not Dynamics.isCarried(s, s.props[2].index), "crateB isn't")
    world.objects[1].pos = { 1.5, 0, 1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 1 })
    T.eq(carried(s), "crateA crateB", "object 1 took crateB")
    T.eq(world.objects[1].flag, nil, "no set_obj_flag in a replay")
    T.ok(world.objects[1].color ~= nil, "painted though")
    -- the game puts the file's color back (suspected at the end of an R replay's recorded frames): painted again
    local saved = get_obj_color
    get_obj_color = function(id)
        local c = world.objects[id].color or { 1, 1, 1, 0.1 }
        return c[1], c[2], c[3], c[4]
    end
    world.objects[0].color = { 1, 1, 1, 0.1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 2 })
    T.eq(table.concat(world.objects[0].color, " "), "0.2 0.4 0.6 1", "painted again")
    world.objects[0].color = { 1, 1, 1, 0.1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 2 }) -- the same frame drawn again (no new frame to watch)
    T.eq(table.concat(world.objects[0].color, " "), "0.2 0.4 0.6 1", "painted again on the same frame")
    local sets = 0
    local setColor = set_obj_color
    set_obj_color = function(...) sets = sets + 1 setColor(...) end
    Dynamics.draw(s, { replay_mode = 1, match_frame = 3 })
    T.eq(sets, 0, "still its color: nothing set")
    set_obj_color, get_obj_color = setColor, saved
end)

T.test("a weapon prop: its own group, carried by a pool object written with that flag (no flag call)", function()
    stubEngine()
    local _, _, props = Colliders.build(T.lines([[
env_obj crate
   shape box
   pos 1 0 1
   sides 0.4 0.4 0.4
   flag 0
env_obj blade
   shape box
   pos 1.5 0 1
   sides 0.4 0.4 0.4
   flag 6]]))
    T.eq(props[1].group, "box|", "a plain crate")
    T.eq(props[2].group, "box||||6", "the weapon's own group (its flag bits)")
    -- as MGE writes them: one pool object per group, the weapon's with flag 6
    local objects = { { id = 1, shape = "box", flag = "0" }, { id = 2, shape = "box", flag = "6" } }
    local s = Dynamics.new(objects, props, { dradius = 2, fromFrame = 0 })
    for i = 1, 2 do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crate blade", "each taken by its own group's object")
    T.eq(world.objects[1].flag, nil, "the weapon object has the flag from the mod: no set_obj_flag")
end)

---------------------------------------------------------------------------------------------------- flight

-- a rocket prop (thrust 200 along x: 1.2 m/s more each frame) 6 left of player 1, on a static floor
local ROCKET_ATMO = [[
env_obj floor
   shape box
   pos 0 0 0
   sides 200 60 1
   flag 8
env_obj rocket
   shape box
   pos -6 0 1
   sides 0.4 0.4 0.4
   flag 0
   thrust 1 200 0 0]]

local function setupRocket()
    stubEngine()
    local colliders, _, props = Colliders.build(T.lines(ROCKET_ATMO))
    local s = Dynamics.new({ { id = 1, shape = "box" } }, props,
        { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 } })
    set_obj_pos(0, Dynamics.parkPos(1))
    return s
end

T.test("flight: a thrust prop flies drawn from frame 0", function()
    local s = setupRocket()
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "-", "too far to be wanted")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.near(s.props[1].pos[1], -6 + 1.2 * ATMOPLAY.Flight.DT, 1e-9, "one push, one step")
    local _, _, flying = Dynamics.counts(s)
    T.eq(flying, 1, "counted as flying")
end)

T.test("flight: taken moving when it comes near; its object pushed on the thrust's frames", function()
    local s = setupRocket()
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local f = 0
    while carried(s) == "-" and f < 60 do
        f = f + 1
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
    end
    T.eq(carried(s), "rocket", "taken")
    T.ok(world.objects[0].lin[1] > 10, "its object moving on at the flight's speed")
    T.nearList(world.objects[0].force, { 200, 0, 0 }, 1e-9, "pushed as its thrust")
    T.eq(s.props[1].flight, nil, "no longer flying drawn")
    local _, _, flying = Dynamics.counts(s)
    T.eq(flying, 0, "not counted as flying")
end)

---A fight with the rocket: flies in, taken, then the players leave and it's let go moving. The fake world steps
---the carried object by its velocity and pushes. Returns each frame's object state (before the frame's draw) and
---the rocket's pose after it
local function rocketFight(frames)
    local s = setupRocket()
    local dt = ATMOPLAY.Flight.DT
    local rec, poses = {}, {}
    local function snapshot(f)
        local o = world.objects[0]
        rec[f] = { pos = { o.pos[1], o.pos[2], o.pos[3] }, lin = { o.lin[1], o.lin[2], o.lin[3] },
            ang = { o.ang[1], o.ang[2], o.ang[3] } }
    end
    snapshot(0)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    poses[0] = s.props[1].pos
    local takenAt
    for f = 1, frames do
        -- the physics step from f - 1: the carried object moves (and takes its push)
        local o = world.objects[0]
        if o.force then
            o.lin = { o.lin[1] + o.force[1] * dt, o.lin[2] + o.force[2] * dt, o.lin[3] + o.force[3] * dt }
            o.force = nil
        end
        o.pos = { o.pos[1] + o.lin[1] * dt, o.pos[2] + o.lin[2] * dt, o.pos[3] + o.lin[3] * dt }
        if takenAt and f == takenAt + 2 then o.ang = { 0, 1, 3 } end -- it starts spinning
        if takenAt and f == takenAt + 5 then world.players = { { 100, 100, 1 }, { 120, 120, 1 } } end
        snapshot(f)
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        if not takenAt and carried(s) == "rocket" then takenAt = f end
        -- the rotation's numbers: a flying prop's rotation is one table written in place (flight.lua)
        local r, rot = s.props[1].rot, {}
        for k = 0, 11 do rot["r" .. k] = r["r" .. k] or 0 end
        local p = s.props[1].pos -- its numbers too: a flight moves its position table in place
        poses[f] = { pos = { p[1], p[2], p[3] }, rot = rot }
    end
    poses[0] = { pos = poses[0], rot = s.props[1].home.rot }
    return s, rec, poses, takenAt
end

T.test("flight: a thrust prop nobody wants is let go moving and flies on drawn", function()
    local s, _, poses, takenAt = rocketFight(60)
    T.ok(takenAt ~= nil, "taken on the way")
    T.eq(carried(s), "-", "let go once the players left")
    T.ok(s.props[1].flight ~= nil, "flying on")
    T.ok(poses[60].pos[1] > poses[59].pos[1], "still moving along x")
    T.ok(s.props[1].flight.ang ~= nil, "and spinning")
    local turned = 0
    for k = 0, 10 do turned = turned + math.abs(poses[60].rot["r" .. k] - poses[59].rot["r" .. k]) end
    T.ok(turned > 1e-6, "its drawn copy turns")
end)

T.test("flight: a flying prop's rotation is one table written in place; an event keeps its own copy", function()
    local s = setupRocket()
    world.players = { { 100, 100, 1 }, { 120, 120, 1 } }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local prop = s.props[1]
    prop.flight.ang = { 0, 0, 3 } -- spinning: its rotation changes every frame
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    local rot, r4 = prop.rot, prop.rot.r4
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.ok(prop.rot == rot, "the same table")
    T.ok(prop.rot.r4 ~= r4, "turned on")
    -- a take keeps the pose of its moment, not the flight's table
    local events = #s.events
    world.players = { { prop.pos[1], 0, 1 }, { 120, 120, 1 } }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 3 })
    T.eq(#s.events, events + 1, "taken")
    T.ok(s.events[#s.events].rot ~= rot, "its own copy")
end)

T.test("flight: its replay flies the same, rewinds too", function()
    local fight, rec, poses = rocketFight(60)
    local s = setupRocket()
    world.players = { { 0, 0, 1 }, { 50, 50, 1 } }
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    local function watch(f)
        world.objects[0].pos, world.objects[0].lin, world.objects[0].ang = rec[f].pos, rec[f].lin, rec[f].ang
        Dynamics.draw(s, { replay_mode = 1, match_frame = f })
    end
    ---how far the prop is from the fight's pose at f (position and rotation)
    local function off(f)
        local a, b = s.props[1], poses[f]
        local d = math.abs(a.pos[1] - b.pos[1]) + math.abs(a.pos[2] - b.pos[2]) + math.abs(a.pos[3] - b.pos[3])
        for k = 0, 10 do d = d + math.abs(a.rot["r" .. k] - b.rot["r" .. k]) end
        return d
    end
    local worst = 0
    for f = 0, 60 do
        watch(f)
        worst = math.max(worst, off(f))
    end
    T.near(worst, 0, 1e-9, "every frame as in the fight")
    T.eq(#s.events, #fight.events, "the same takes and releases")
    -- back to frame 30 and on again
    worst = 0
    for f = 30, 60 do
        watch(f)
        worst = math.max(worst, off(f))
    end
    T.near(worst, 0, 1e-9, "a rewind flies the same again")
end)

T.test("flight: a prop let go spinning spins on drawn; taken again, its object gets the spin", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    -- crateA kicked away spinning; crateB next to the player has no object (as the full pool test)
    world.objects[0].pos = { 10, 0, 1 }
    world.objects[0].lin = { 5, 0, 0 }
    world.objects[0].ang = { 0, 0, 4 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.nearList(s.props[1].flight.ang, { 0, 0, 4 }, 1e-9, "let go with its spin")
    local rot = s.props[1].rot
    Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
    T.eq(carried(s), "crateB", "the object went to crateB")
    T.ok(s.props[1].rot ~= rot, "crateA's drawn copy turns")
    T.near(s.props[1].rot.r4, math.sin(4 * ATMOPLAY.Flight.DT), 1e-9, "by its spin")
    -- the player goes over to crateA: crateB rests and is let go, crateA gets the object back
    world.players[1] = { s.props[1].pos[1], 0, 1 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 3 })
    Dynamics.draw(s, { replay_mode = 0, match_frame = 4 })
    T.eq(carried(s), "crateA", "taken again")
    T.nearList(world.objects[0].ang, { 0, 0, 4 }, 1e-9, "its object spins on")
    T.ok(world.objects[0].lin[1] > 4.9, "and moves on")
end)

T.test("collide: the rocket wakes a crate in its way; a rewind and the replay fly them the same", function()
    local atmo = ROCKET_ATMO .. [[

env_obj crate
   shape box
   pos -2 0 0.7
   sides 0.4 0.4 0.4
   flag 0]]
    local function make()
        stubEngine()
        world.players = { { 100, 100, 1 }, { 120, 120, 1 } } -- nobody near: all drawn
        local colliders, _, props = Colliders.build(T.lines(atmo))
        local s = Dynamics.new({ { id = 1, shape = "box" } }, props,
            { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 }, level = "full" })
        set_obj_pos(0, Dynamics.parkPos(1))
        return s
    end
    local s = make()
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local fight = {}
    for f = 1, 160 do
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        local a, b = s.props[1].pos, s.props[2].pos -- numbers: flights move their tables in place
        fight[f] = { { a[1], a[2], a[3] }, { b[1], b[2], b[3] } }
    end
    T.ok(fight[160][2][1] > -1.9, "the crate was hit and moved")
    -- a rewind to 40, then on again
    local worst = 0
    for f = 120, 160 do -- past the snapshots at 50 and 100
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        for k = 1, 2 do
            local a, b = s.props[k].pos, fight[f][k]
            worst = math.max(worst, math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]))
        end
    end
    T.near(worst, 0, 1e-9, "the rewind flies the same")
    -- its replay
    local r = make()
    Dynamics.matchBegin(r, { replay_mode = 1, match_frame = 0 })
    worst = 0
    for f = 0, 160 do
        Dynamics.draw(r, { replay_mode = 1, match_frame = f })
        if f > 0 then
            for k = 1, 2 do
                local a, b = r.props[k].pos, fight[f][k]
                worst = math.max(worst, math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]))
            end
        end
    end
    T.near(worst, 0, 1e-9, "the replay flies the same")
end)

T.test("snapshots: a rewind steps on from the nearest one, the same as from frame 0", function()
    local every = Dynamics.SNAPSHOT_EVERY
    Dynamics.SNAPSHOT_EVERY = 10
    local ok, err = pcall(function()
        -- the rocket fight (taken, spun, let go) watched as a replay, then rewound past several snapshots
        local _, rec, poses = rocketFight(60)
        local s = setupRocket()
        world.players = { { 0, 0, 1 }, { 50, 50, 1 } }
        Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
        local function watch(f)
            world.objects[0].pos, world.objects[0].lin, world.objects[0].ang = rec[f].pos, rec[f].lin, rec[f].ang
            Dynamics.draw(s, { replay_mode = 1, match_frame = f })
        end
        for f = 0, 60 do watch(f) end
        T.ok(next(s.snapshots) ~= nil, "snapshots kept")
        local worst = 0
        for _, back in ipairs({ 45, 31, 12 }) do
            for f = back, 60 do
                watch(f)
                local a, b = s.props[1], poses[f]
                local d = math.abs(a.pos[1] - b.pos[1]) + math.abs(a.pos[2] - b.pos[2]) + math.abs(a.pos[3] - b.pos[3])
                for k = 0, 10 do d = d + math.abs(a.rot["r" .. k] - b.rot["r" .. k]) end
                worst = math.max(worst, d)
            end
        end
        T.near(worst, 0, 1e-9, "every rewind flies as the fight did")
    end)
    Dynamics.SNAPSHOT_EVERY = every
    assert(ok, err)
end)

T.test("snapshots: older ones thinned out, rewinds from what's left still fly as the fight did", function()
    local every, recent, old = Dynamics.SNAPSHOT_EVERY, Dynamics.SNAPSHOT_RECENT, Dynamics.SNAPSHOT_OLD
    Dynamics.SNAPSHOT_EVERY, Dynamics.SNAPSHOT_RECENT, Dynamics.SNAPSHOT_OLD = 5, 10, 20
    local ok, err = pcall(function()
        local _, rec, poses = rocketFight(60)
        local s = setupRocket()
        world.players = { { 0, 0, 1 }, { 50, 50, 1 } }
        Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
        local function watch(f)
            world.objects[0].pos, world.objects[0].lin, world.objects[0].ang = rec[f].pos, rec[f].lin, rec[f].ang
            Dynamics.draw(s, { replay_mode = 1, match_frame = f })
        end
        for f = 0, 60 do watch(f) end
        local kept = {}
        for at in pairs(s.snapshots) do kept[#kept + 1] = at end
        table.sort(kept)
        T.eq(table.concat(kept, " "), "20 40 50 55 60", "the last 10 frames' every 5th, older every 20th")
        local worst = 0
        for _, back in ipairs({ 47, 33, 14 }) do -- from 40, 20 and 0
            for f = back, 60 do
                watch(f)
                local a, b = s.props[1], poses[f]
                local d = math.abs(a.pos[1] - b.pos[1]) + math.abs(a.pos[2] - b.pos[2]) + math.abs(a.pos[3] - b.pos[3])
                for k = 0, 10 do d = d + math.abs(a.rot["r" .. k] - b.rot["r" .. k]) end
                worst = math.max(worst, d)
            end
        end
        T.near(worst, 0, 1e-9, "every rewind flies as the fight did")
    end)
    Dynamics.SNAPSHOT_EVERY, Dynamics.SNAPSHOT_RECENT, Dynamics.SNAPSHOT_OLD = every, recent, old
    assert(ok, err)
end)

T.test("levels: a new level waits for the next fight (a fight and its rewinds keep one)", function()
    local s = setupRocket()
    T.eq(s.level, "shapes", "the default")
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    for f = 1, 5 do Dynamics.draw(s, { replay_mode = 0, match_frame = f }) end
    Dynamics.setLevel(s, "simple")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 6 })
    T.eq(s.level, "shapes", "not mid-fight")
    T.ok(s.flightOpts and not s.flightOpts.simple, "still flying with shapes")
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(s.level, "simple", "from the next fight")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.ok(s.flightOpts.simple, "flying simple")
    T.eq(s.props[1].body.shape, "sphere", "as a sphere")
end)

---A fight on one pool object: crateA taken, then kicked away fast (the fake world moves the carried object by its
---velocity each frame); far enough, a full pool lets it go flying and crateB gets the object the frame after.
---Returns the object's state each frame (as a replay shows it), and the frames it was parked in
local function swapFight()
    local s = setup(1)
    local rec, parked, dt = {}, {}, ATMOPLAY.Flight.DT
    local function snapshot(f)
        local o = world.objects[0]
        rec[f] = { pos = { o.pos[1], o.pos[2], o.pos[3] }, lin = { o.lin[1], o.lin[2], o.lin[3] },
            ang = { o.ang[1], o.ang[2], o.ang[3] } }
        if math.abs(o.pos[3] - Dynamics.PARK_Z) < Dynamics.PARKED then parked[#parked + 1] = f end
    end
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 }) -- crateA taken: its object there from frame 0
    snapshot(0)
    local f = 0
    repeat
        f = f + 1
        local o = world.objects[0]
        if f == 2 then o.lin = { 150, 0, 0 } end -- kicked: 0.9 a frame from here
        o.pos = { o.pos[1] + o.lin[1] * dt, o.pos[2] + o.lin[2] * dt, o.pos[3] + o.lin[3] * dt }
        snapshot(f)
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
    until carried(s) == "crateB" or f > 40
    for _ = 1, 2 do
        f = f + 1
        snapshot(f)
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
    end
    return s, rec, parked, f
end

T.test("replay, every frame drawn: the swap is seen as in the fight", function()
    local fight, rec, parked, last = swapFight()
    T.eq(carried(fight), "crateB", "the fight: crateB carried")
    T.ok(#parked > 0, "parked in between")
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    for f = 0, last do
        world.objects[0].pos, world.objects[0].lin, world.objects[0].ang = rec[f].pos, rec[f].lin, rec[f].ang
        Dynamics.draw(s, { replay_mode = 1, match_frame = f })
    end
    T.eq(carried(s), "crateB", "crateB carried")
    T.ok(s.props[1].flight ~= nil and not s.props[1].entry, "crateA flying, drawn")
end)

T.test("replay, frames skipped (a low fps): a park between two drawn frames is still a release", function()
    local _, rec, parked, last = swapFight()
    local skip = {}
    for _, f in ipairs(parked) do skip[f] = true end
    skip[parked[#parked] + 1] = true -- and the first frame at crateB
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    local lastSeenX
    for f = 0, last do
        if not skip[f] then
            world.objects[0].pos, world.objects[0].lin, world.objects[0].ang = rec[f].pos, rec[f].lin, rec[f].ang
            Dynamics.draw(s, { replay_mode = 1, match_frame = f })
            if s.props[1].entry then lastSeenX = rec[f].pos[1] end
        end
    end
    T.eq(carried(s), "crateB", "crateB carried (its object jumped there: a teleport, not a move)")
    T.ok(s.props[1].flight ~= nil and not s.props[1].entry, "crateA flying on, drawn (not hidden at crateB's place)")
    T.ok(lastSeenX and s.props[1].pos[1] > lastSeenX, "from where it was last seen, flown on")
end)

T.test("replay, frames skipped: a rewind gives the props as watched", function()
    local _, rec, parked, last = swapFight()
    local skip = { [parked[#parked]] = true, [parked[#parked] + 1] = true }
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    local function watch(f)
        world.objects[0].pos, world.objects[0].lin, world.objects[0].ang = rec[f].pos, rec[f].lin, rec[f].ang
        Dynamics.draw(s, { replay_mode = 1, match_frame = f })
    end
    local seen = {}
    for f = 0, last do
        if not skip[f] then
            watch(f)
            seen[f] = { carried(s), s.props[1].pos[1], s.props[2].pos[1] }
        end
    end
    watch(1) -- back
    local worst, same = 0, true
    for f = 1, last do
        if not skip[f] then
            watch(f)
            if carried(s) ~= seen[f][1] then same = false end
            worst = math.max(worst, math.abs(s.props[1].pos[1] - seen[f][2]), math.abs(s.props[2].pos[1] - seen[f][3]))
        end
    end
    T.ok(same, "the same carried")
    T.near(worst, 0, 1e-9, "the same poses")
end)

T.test("replay: a hard hit (40 m/s more in a frame) is a move, not a teleport", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    world.objects[0].pos = { 1, 0, 1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 0 })
    T.eq(carried(s), "crateA", "taken")
    world.objects[0].pos, world.objects[0].lin = { 1 + 40 * ATMOPLAY.Flight.DT * 3, 0, 1 }, { 40, 0, 0 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 3 }) -- 3 frames later, hit hard in between
    T.eq(carried(s), "crateA", "still crateA")
    T.eq(#s.events, 1, "no release")
end)

T.test("replay: an object that took a prop none is near takes the nearest of its group within MATCH_FAR", function()
    local s = setup(2)
    Dynamics.matchBegin(s, { replay_mode = 1, match_frame = 0 })
    world.players = { { 100, 100, 1 }, { 120, 120, 1 } }
    -- the replay's props drifted from the fight's: the object shows up 2 from crateA (its prop in the fight)
    world.objects[0].pos = { -1, 0, 1 }
    Dynamics.draw(s, { replay_mode = 1, match_frame = 1 })
    T.eq(carried(s), "crateA -", "crateA taken by the wider search")
    T.eq(s.replayMisses.far, 1, "counted")
    T.near(s.props[1].pos[1], -1, 1e-9, "the prop where its object is")
    world.objects[1].pos = { 30, 0, 1 } -- nothing of its group within MATCH_FAR (far is 30 30 1)
    Dynamics.draw(s, { replay_mode = 1, match_frame = 2 })
    T.eq(carried(s), "crateA -", "nothing taken")
    T.eq(s.replayMisses.none, 1, "counted as not found")
end)

T.test("a carried prop tipping over (spinning, its center slow) makes the props it touches real", function()
    stubEngine()
    world.players = { { -2.2, 0, 1 }, { 50, 50, 1 } }
    local _, _, props = Colliders.build(T.lines([[
env_obj tipping
   shape box
   pos 0 0 1
   sides 0.4 0.4 0.4
   flag 0
env_obj leaned
   shape box
   pos 0.6 0 1
   sides 0.4 0.4 0.4
   flag 0]]))
    local s = Dynamics.new({ { id = 1, shape = "box" }, { id = 2, shape = "box" } }, props, { dradius = 2, fromFrame = 0 })
    for i = 1, 2 do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "tipping -", "only the near one is wanted by the player")
    -- it tips toward the other: its center barely moves, its corners do
    world.objects[0].lin, world.objects[0].ang = { 0.05, 0, 0 }, { 0, 3, 0 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "tipping leaned", "the one it tips onto is real too (else it would sink into it)")
end)

T.test("a prop without a mass line flies with its object's mass in the game (as its real object would)", function()
    stubEngine()
    world.objects[0] = { pos = { 0, 0, 0 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, mass = 0.1 } -- the game's mass
    local colliders, _, props = Colliders.build(T.lines(ROCKET_ATMO))
    local s = Dynamics.new({ { id = 1, shape = "box" } }, props,
        { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 } })
    T.near(s.props[1].flightMass, 0.1, 1e-12, "read from its group's pool object")
    set_obj_pos(0, Dynamics.parkPos(1))
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.near(s.props[1].pos[1], -6 + 200 / 0.1 * ATMOPLAY.Flight.DT ^ 2, 1e-9, "thrust 200 on 0.1: ten times the push of 1")
end)

T.test("props overlapping where they start never push each other apart; prop_hits 0 read", function()
    stubEngine()
    local _, _, props = Colliders.build(T.lines([[
env_obj a
   shape box
   pos 0 0 1
   sides 0.5 0.5 0.5
   flag 0
env_obj b
   shape box
   pos 0.18 0 1
   rot 0 30 0
   sides 0.5 0.5 0.5
   flag 0
env_obj c
   shape box
   pos 3 0 1
   sides 0.5 0.5 0.5
   flag 0
   prop_hits 0]]))
    T.eq(props[3].noHits, true, "prop_hits 0")
    T.eq(props[1].noHits, nil, "hits by default")
    local s = Dynamics.new({ { id = 1, shape = "box" } }, props, { dradius = 2, fromFrame = 0 })
    T.ok(s.props[1].ignore and s.props[1].ignore[s.props[2]], "a and b overlap: they ignore each other")
    T.ok(not (s.props[1].ignore and s.props[1].ignore[s.props[3]]), "c is apart")
end)

T.test("a carried thrust prop gets the pushes of frames not drawn (low fps)", function()
    local s = setupRocket()
    world.players = { { -6, 0, 1 }, { 50, 50, 1 } } -- next to the rocket: taken at once
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "rocket", "taken")
    T.nearList(world.objects[0].force, { 200, 0, 0 }, 1e-9, "frame 0: one push")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 3 }) -- frames 1 and 2 not drawn
    T.nearList(world.objects[0].force, { 600, 0, 0 }, 1e-9, "frame 3: the pushes of 1, 2 and 3")
end)

T.test("rewind on Full: a prop put back far from home is found by the flights flown again", function()
    stubEngine()
    world.players = { { -20, 0, 1 }, { 50, 50, 1 } }
    local colliders, _, props = Colliders.build(T.lines(ROCKET_ATMO .. [[

env_obj crate
   shape box
   pos -20 0 0.7
   sides 0.4 0.4 0.4
   flag 0]]))
    local s = Dynamics.new({ { id = 1, shape = "box" } }, props,
        { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 }, level = "full" })
    set_obj_pos(0, Dynamics.parkPos(1))
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(s.props[2].entry ~= nil, true, "the crate taken")
    -- carried over to x 0 (the fake world's physics) and left there at rest; the players leave
    world.objects[0].pos, world.objects[0].lin = { 0, 0, 0.7 }, { 0, 0, 0 }
    world.players = { { 100, 100, 1 }, { 120, 120, 1 } }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(s.props[2].entry, nil, "let go at x 0, far from its home cell")
    local live = {}
    for f = 2, 120 do
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        live[f] = { s.props[1].pos[1], s.props[2].pos[1] }
    end
    T.ok(live[120][2] > 0.1, "the rocket hit it (woken, pushed along)")
    -- rewound to after the hit: the flights flown again must find the crate where it was let go
    local hit
    for f = 2, 120 do
        if not hit and live[f][2] > 0.01 then hit = f end
    end
    local worst = 0
    for f = hit + 3, 120 do
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        worst = math.max(worst, math.abs(s.props[1].pos[1] - live[f][1]), math.abs(s.props[2].pos[1] - live[f][2]))
    end
    T.near(worst, 0, 1e-9, "rewound to after the hit and on: the same")
end)

T.test("prop_real 0: never taken, even next to a player; still listed (woken by flights); replays don't match it", function()
    stubEngine()
    local _, _, props = Colliders.build(T.lines([[
env_obj ghost
   shape box
   pos 1 0 1
   sides 0.4 0.4 0.4
   flag 0
   prop_real 0
env_obj crate
   shape box
   pos 1.5 0 1
   sides 0.4 0.4 0.4
   flag 0]]))
    T.eq(props[1].noReal, true, "read")
    local s = Dynamics.new({ { id = 1, shape = "box" }, { id = 2, shape = "box" } }, props, { dradius = 2, fromFrame = 0 })
    for i = 1, 2 do set_obj_pos(i - 1, Dynamics.parkPos(i)) end
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crate -", "only the crate taken, with an object to spare")
    T.ok(s.props[1].listed and s.props[1].cell ~= nil, "the ghost is in the grid")
    -- a replay: an object appearing on the ghost takes the crate (its group's free prop) or nothing, never the ghost
    local r = Dynamics.new({ { id = 1, shape = "box" }, { id = 2, shape = "box" } }, props, { dradius = 2, fromFrame = 0 })
    Dynamics.matchBegin(r, { replay_mode = 1, match_frame = 0 })
    world.objects[0].pos = { 1, 0, 1 }
    world.objects[1].pos = { Dynamics.parkPos(2) } -- parked
    Dynamics.draw(r, { replay_mode = 1, match_frame = 1 })
    T.ok(r.props[1].entry == nil, "the ghost never carried in a replay")
end)

T.test("Collision lines: prop_collide <player> <dynamic> <atmo>, the older prop_real / prop_hits still read", function()
    local function c(lines) return { Colliders.collision(lines) } end
    T.eq(table.concat({ tostring(c({})[1]), tostring(c({})[2]), tostring(c({})[3]) }, " "), "true true true", "no line: all on")
    local t = c({ prop_collide = "1 0 1" })
    T.ok(t[1] and not t[2] and t[3], "player on, dynamic off, atmo on")
    t = c({ prop_real = "0" })
    T.ok(not t[1] and not t[2] and t[3], "prop_real 0: neither player nor dynamic")
    t = c({ prop_hits = "0" })
    T.ok(t[1] and t[2] and not t[3], "prop_hits 0: no atmo")
end)

T.test("props never real (no dynamic pool at all) still fly their thrust", function()
    stubEngine()
    local colliders, _, props = Colliders.build(T.lines(ROCKET_ATMO:gsub("thrust 1 200 0 0", "thrust 1 200 0 0\n   prop_collide 0 0 1")))
    T.eq(props[1].noReal, true, "never real")
    local s = Dynamics.new({}, props, { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 } })
    world.players = { { -6, 0, 1 }, { 50, 50, 1 } } -- right next to it
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    for f = 1, 10 do Dynamics.draw(s, { replay_mode = 0, match_frame = f }) end
    T.ok(s.props[1].pos[1] > -6 + 0.1, "flying on its thrust")
    T.eq(s.props[1].entry, nil, "never carried")
end)

T.test("Collision Player / Dynamic: what a prop becomes real for", function()
    local function run(line)
        stubEngine()
        local _, _, props = Colliders.build(T.lines([[
env_obj crate
   shape box
   pos 1 0 1
   sides 0.4 0.4 0.4
   flag 0
   prop_collide ]] .. line))
        local s = Dynamics.new({ { id = 1, shape = "box" } }, props, { dradius = 2, fromFrame = 0, follow = { 5 } })
        set_obj_pos(0, Dynamics.parkPos(1))
        return s
    end
    -- a player next to it (no dynamic object near)
    local s = run("0 1 1")
    world.objects[5] = { pos = { 40, 40, 1 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, mass = 1 }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "-", "player off: not real near a player")
    s = run("1 0 1")
    world.objects[5] = { pos = { 40, 40, 1 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, mass = 1 }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crate", "player on: real near a player")
    -- a dynamic object of the mod next to it, the players away
    s = run("1 0 1")
    world.players = { { 40, 0, 1 }, { 50, 50, 1 } }
    world.objects[5] = { pos = { 1.5, 0, 1 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, mass = 1 }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "-", "dynamic off: not real near the mod's dynamic object")
    s = run("0 1 1")
    world.players = { { 40, 0, 1 }, { 50, 50, 1 } }
    world.objects[5] = { pos = { 1.5, 0, 1 }, lin = { 0, 0, 0 }, ang = { 0, 0, 0 }, mass = 1 }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(carried(s), "crate", "dynamic on: real near it")
end)

T.test("Full, a fight drawn every third frame flies as its replay watched every frame (grid each step)", function()
    local atmo = ROCKET_ATMO .. [[

env_obj crate
   shape box
   pos -2 0 0.7
   sides 0.4 0.4 0.4
   flag 0]]
    local function make()
        stubEngine()
        world.players = { { 100, 100, 1 }, { 120, 120, 1 } }
        local colliders, _, props = Colliders.build(T.lines(atmo))
        local s = Dynamics.new({ { id = 1, shape = "box" } }, props,
            { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 }, level = "full" })
        set_obj_pos(0, Dynamics.parkPos(1))
        return s
    end
    local s = make()
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    for f = 3, 120, 3 do Dynamics.draw(s, { replay_mode = 0, match_frame = f }) end -- several frames a call
    local fight = { s.props[1].pos, s.props[2].pos }
    T.ok(fight[2][1] > -1.9, "the crate was hit")
    local r = make()
    Dynamics.matchBegin(r, { replay_mode = 1, match_frame = 0 })
    for f = 1, 120 do Dynamics.draw(r, { replay_mode = 1, match_frame = f }) end -- one frame a call
    local worst = 0
    for k = 1, 2 do
        for a = 1, 3 do worst = math.max(worst, math.abs(r.props[k].pos[a] - fight[k][a])) end
    end
    T.near(worst, 0, 1e-9, "the same poses")
end)

T.test("movedPose: a moved prop's own pos and rotation (nothing made), nothing at home", function()
    local s = setupRocket()
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    T.eq(Dynamics.movedPose(s, s.props[1].index), nil, "at home")
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    local pos, rot = Dynamics.movedPose(s, s.props[1].index)
    T.ok(pos == s.props[1].pos and rot == s.props[1].rot, "its own tables")
    T.eq(Dynamics.movedPose(s, 999), nil, "no such prop")
end)

local Flight = ATMOPLAY.Flight

T.test("ghosts: the prediction is the flights to come (full: a hit and a wake), the props untouched", function()
    stubEngine()
    local colliders, _, props = Colliders.build(T.lines(ROCKET_ATMO .. [[

env_obj crate
   shape box
   pos -2 0 0.7
   sides 0.4 0.4 0.4
   flag 0]]))
    local s = Dynamics.new({ { id = 1, shape = "box" } }, props,
        { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 }, level = "full" })
    set_obj_pos(0, Dynamics.parkPos(1))
    world.players = { { 100, 100, 1 }, { 120, 120, 1 } } -- nobody near: nothing is taken
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local rocket, crate = s.props[1], s.props[2]
    local rocketPos, rocketVx, cratePos = rocket.pos, rocket.flight.vel[1], crate.pos
    local budget = Dynamics.PREDICT_MS
    Dynamics.PREDICT_MS = math.huge -- all of it in one call
    local pr = Dynamics.predict(s, 120)
    Dynamics.PREDICT_MS = budget
    T.eq(pr.steps, 120, "120 frames ahead")
    T.ok(rocket.pos == rocketPos and rocket.flight.vel[1] == rocketVx and crate.pos == cratePos and not crate.flight,
        "predicting moved no prop")
    T.eq(Dynamics.predict(s, 120), pr, "the same frame: the same prediction")
    local worst, compared = 0, 0
    for f = 1, 120 do
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        for _, p in ipairs({ rocket, crate }) do
            local x, y, z = Flight.predictedPose(pr, p, f)
            if x then
                compared = compared + 1
                worst = math.max(worst, math.abs(x - p.pos[1]), math.abs(y - p.pos[2]), math.abs(z - p.pos[3]))
            else
                T.eq(p.pos, cratePos, "no prediction only while still at home (frame " .. f .. ")")
            end
        end
    end
    T.ok(crate.pos[1] > -1.9, "the rocket hit the crate")
    T.ok(compared > 120, "the crate predicted too once woken")
    T.near(worst, 0, 1e-9, "predicted = flown, every frame")
    T.eq(Dynamics.predict(s, 10), pr, "the flights followed it: kept")
    T.eq(pr.base, 120, "from their frame now")
    s.events[#s.events + 1] = { frame = 120, kind = "take" }
    T.eq(Dynamics.predict(s, 10), pr, "a take: kept (the taken prop's ghost is the game's)")
    s.flightStarts = (s.flightStarts or 0) + 1 -- a prop let go flying: a flight the prediction doesn't have
    T.ok(Dynamics.predict(s, 10) ~= pr, "a release that flies: a new prediction")
end)

T.test("ghosts: a prediction carried over turns goes on exactly, its old poses dropped", function()
    stubEngine()
    local colliders, _, props = Colliders.build(T.lines(ROCKET_ATMO .. [[

env_obj crate
   shape box
   pos -2 0 0.7
   sides 0.4 0.4 0.4
   flag 0]]))
    local s = Dynamics.new({ { id = 1, shape = "box" } }, props,
        { dradius = 2, fromFrame = 0, statics = colliders, gravity = { 0, 0, -9.82 }, level = "full" })
    set_obj_pos(0, Dynamics.parkPos(1))
    world.players = { { 100, 100, 1 }, { 120, 120, 1 } }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local budget = Dynamics.PREDICT_MS
    Dynamics.PREDICT_MS = math.huge
    local pr = Dynamics.predict(s, 40) -- turn 1 waits at frame 0
    for f = 1, 30 do Dynamics.draw(s, { replay_mode = 0, match_frame = f }) end -- 30 frames played
    T.eq(Dynamics.predict(s, 40), pr, "turn 2 at frame 30: the same prediction")
    T.eq(pr.steps, 70, "extended to 30 + 40")
    T.eq(pr.poses[s.props[1]].first, 30, "frames already played dropped")
    Dynamics.PREDICT_MS = budget
    local worst, compared = 0, 0
    for f = 31, 70 do
        Dynamics.draw(s, { replay_mode = 0, match_frame = f })
        for _, p in ipairs(s.props) do
            local x, y, z = Flight.predictedPose(pr, p, f)
            if x and pr.poses[p] then
                compared = compared + 1
                worst = math.max(worst, math.abs(x - p.pos[1]), math.abs(y - p.pos[2]), math.abs(z - p.pos[3]))
            end
        end
    end
    T.ok(compared >= 40, "compared every frame")
    T.near(worst, 0, 1e-9, "carried over: still the flights to come")
end)

T.test("ghosts: play along with the game's ghost loop (its frame and fade), from frame 0", function()
    local s = setupRocket()
    world.players = { { 100, 100, 1 }, { 120, 120, 1 } }
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local saved = { get_ghost, get_ghost_length, get_ghost_frame, get_option, set_color, draw_box_m }
    local draws, opts, ghostAt = {}, { ghostenvobj = 1, ghostopacity = 50 }, { 30, 0.5 }
    get_ghost = function() return 2 end
    get_ghost_length = function() return 100 end
    get_ghost_frame = function() return ghostAt[1], ghostAt[2], 99 end
    get_option = function(name) return opts[name] end
    set_color = function(r, g, b, a) draws.alpha = a end
    draw_box_m = function(x) draws[#draws + 1] = x end
    local ws = { replay_mode = 0, match_frame = 0, match_turn_frame = 0 } -- frame 0: no turn frames counted yet
    local still = Dynamics.GHOST_STILL
    Dynamics.GHOST_STILL = -1
    local budget = Dynamics.PREDICT_MS
    Dynamics.PREDICT_MS = math.huge
    T.eq(Dynamics.drawGhosts(s, ws), 1, "the rocket's ghost on frame 0")
    local pr = s.prediction
    T.eq(pr.steps, 99, "the ghost's 100 frames predicted")
    T.near(draws[1], (Flight.predictedPose(pr, s.props[1], 30)), 1e-12, "where the game's ghost is (30 ahead)")
    T.ok(draws[1] > s.props[1].pos[1], "ahead of the rocket")
    T.near(draws.alpha, 0.25, 1e-12, "the ghost opacity, fading with the game's")
    ghostAt = { 70.5, 1 }
    Dynamics.drawGhosts(s, ws)
    T.near(draws[2], (Flight.predictedPose(pr, s.props[1], 70.5)), 1e-12, "on along the loop, between frames")
    T.ok(draws[2] > draws[1], "further on")
    get_ghost_frame = nil
    T.eq(Dynamics.drawGhosts(s, ws), 1, "no game frame: our own loop")
    opts.ghostenvobj = 0
    T.eq(Dynamics.drawGhosts(s, ws), 0, "object ghosts off")
    opts.ghostenvobj = 1
    T.eq(Dynamics.drawGhosts(s, { replay_mode = 1, match_frame = 0 }), 0, "none in replays")
    Dynamics.GHOST_STILL = 1000
    T.eq(Dynamics.drawGhosts(s, { replay_mode = 0, match_frame = 1 }), 0, "frames playing: none")
    local fresh = setupRocket() -- a new state (MGE's reload after an edit): at once, no hold
    Dynamics.matchBegin(fresh, { replay_mode = 0, match_frame = 0 })
    T.eq(Dynamics.drawGhosts(fresh, ws), 1, "a state's first frame shows them at once")
    Dynamics.GHOST_STILL, Dynamics.PREDICT_MS = still, budget
    get_ghost, get_ghost_length, get_ghost_frame, get_option, set_color, draw_box_m =
        saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
end)

T.test("ghosts: only on screen, the nearest the camera past MAX_GHOSTS, colors as MGE draws them", function()
    stubEngine()
    local _, _, props = Colliders.build(T.lines([[
env_obj left
   shape box
   pos -20 0 1
   sides 0.4 0.4 0.4
   color 1.6 0.5 0.25 1
   flag 0
   thrust 1 0 0 50
env_obj right
   shape box
   pos 20 0 1
   sides 0.4 0.4 0.4
   flag 0
   thrust 1 0 0 50]]))
    local s = Dynamics.new({}, props, { dradius = 2, fromFrame = 0, gravity = { 0, 0, -9.82 } })
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local saved = { get_ghost, get_ghost_length, get_ghost_frame, get_option, set_color, draw_box_m, get_camera_info }
    local drawnAt, colors = {}, {}
    get_ghost = function() return 2 end
    get_ghost_length = function() return 20 end
    get_ghost_frame = function() return 10, 1, 19 end
    get_option = function(name) return name == "ghostopacity" and 100 or 1 end
    set_color = function(r, g, b, a) colors[#colors + 1] = { r, g, b, a } end
    draw_box_m = function(x) drawnAt[#drawnAt + 1] = x end
    local camera = { x = 25, y = 0, z = 2 }
    get_camera_info = function() return { pos = camera } end
    local still, budget, cap = Dynamics.GHOST_STILL, Dynamics.PREDICT_MS, Dynamics.MAX_GHOSTS
    Dynamics.GHOST_STILL, Dynamics.PREDICT_MS = -1, math.huge
    local ws = { replay_mode = 0, match_frame = 0 }
    T.eq(Dynamics.drawGhosts(s, ws), 2, "both under the cap")
    Dynamics.MAX_GHOSTS = 1
    drawnAt = {}
    Dynamics.drawGhosts(s, ws)
    T.ok(#drawnAt == 1 and drawnAt[1] > 0, "over the cap: the one nearest the camera (right)")
    camera = { x = -25, y = 0, z = 2 }
    drawnAt, colors = {}, {}
    Dynamics.drawGhosts(s, ws)
    T.ok(#drawnAt == 1 and drawnAt[1] < 0, "the camera moved: the left one")
    T.eq(table.concat(colors[1], " "), "1 0.5 0.25 1", "a color over 1 drawn as 1")
    Dynamics.MAX_GHOSTS = cap
    drawnAt = {}
    T.eq(Dynamics.drawGhosts(s, ws, function(x) return x > 0 end), 1, "off screen: not drawn")
    T.ok(drawnAt[1] > 0, "the one on screen")
    Dynamics.GHOST_STILL, Dynamics.PREDICT_MS = still, budget
    get_ghost, get_ghost_length, get_ghost_frame, get_option, set_color, draw_box_m, get_camera_info =
        saved[1], saved[2], saved[3], saved[4], saved[5], saved[6], saved[7]
end)

T.test("ghosts: past MAX_GHOSTS only the props nearest the camera are predicted, picked again when it moves away", function()
    stubEngine()
    local _, _, props = Colliders.build(T.lines([[
env_obj left
   shape box
   pos -20 0 1
   sides 0.4 0.4 0.4
   flag 0
   thrust 1 0 0 50
env_obj right
   shape box
   pos 20 0 1
   sides 0.4 0.4 0.4
   flag 0
   thrust 1 0 0 50]]))
    local s = Dynamics.new({}, props, { dradius = 2, fromFrame = 0, gravity = { 0, 0, -9.82 } })
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    local cap, budget = Dynamics.MAX_GHOSTS, Dynamics.PREDICT_MS
    Dynamics.MAX_GHOSTS, Dynamics.PREDICT_MS = 1, math.huge
    local pr = Dynamics.predict(s, 20, { 25, 0, 2 })
    T.eq(#pr.props, 1, "one predicted")
    T.eq(pr.props[1], s.props[2], "the one nearest the camera")
    T.eq(Dynamics.predict(s, 20, { 27, 0, 2 }), pr, "the camera moved a little: kept")
    local again = Dynamics.predict(s, 20, { -25, 0, 2 })
    T.ok(again ~= pr, "moved away: picked again")
    T.eq(again.props[1], s.props[1], "the other one now")
    s.prediction = nil -- both as far from the camera: the one on screen first
    local seen = Dynamics.predict(s, 20, { 0, 0, 2 }, function(x) return x > 0 end)
    T.eq(seen.props[1], s.props[2], "on screen first")
    Dynamics.MAX_GHOSTS, Dynamics.PREDICT_MS = cap, budget
end)
