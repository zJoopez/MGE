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
    set_obj_sides = function(id, x, y, z) obj(id).sides = { x, y, z } end
    set_obj_linear_vel = function(id, x, y, z) obj(id).lin = { x, y, z } end
    set_obj_angular_vel = function(id, x, y, z) obj(id).ang = { x, y, z } end
    set_obj_mass = function(id, m) obj(id).mass = m end
    set_obj_bounce = function() end
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
   flag 0
   mass 0.3
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
    local s = Dynamics.new(objects, props, { dradius = 2 })
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
    T.eq(props[1].mass, 0.3, "mass line")
    T.eq(props[2].mass, nil, "no mass line")
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
    T.eq(world.objects[0].mass, 0.3, "crateA's mass")
    T.eq(world.objects[1].mass, 1, "crateB has no mass line: the object's own")
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
    T.ok(world.objects[0].pos[3] < Dynamics.PARK_Z / 2, "object parked")
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

T.test("fight: a crate that fell off the map is released", function()
    local s = setup(1)
    Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
    world.objects[0].pos = { 1, 0, -100 }
    world.objects[0].lin = { 0, 0, -30 }
    world.players[1] = { 1, 0, -100 }
    Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
    T.eq(carried(s), "-", "released though moving and touched")
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
    local s = Dynamics.new(objects, props, { dradius = 2, noGrid = noGrid })
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
    local s = Dynamics.new(objects, props, { dradius = 2, noGrid = noGrid })
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

T.test("drawn copies: only the carried and the just released are redrawn; a new atmo redraws the moved", function()
    local s = setup(2)
    local moves = {}
    local function holder()
        local h = { child = {} }
        for _, prop in ipairs(s.props) do
            local p = prop.home.pos
            local item = { shift = { x = p[1], y = p[2], z = p[3] }, name = prop.name }
            function item:moveTo(x, y, z) moves[#moves + 1] = self.name; self.shift = { x = x, y = y, z = z } end
            h.child[#h.child + 1] = item
        end
        return h
    end
    local savedAtmo, savedUtils = rawget(_G, "Atmospheres"), rawget(_G, "Utils3D")
    Atmospheres = { EntityHolder = holder() }
    Utils3D = { MatrixTBToMatrix = function() return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } end,
        MatrixToMatrixTB = function() return {} end }
    local ok, err = pcall(function()
        Dynamics.matchBegin(s, { replay_mode = 0, match_frame = 0 })
        T.eq(#moves, 0, "taken, not moved: nothing redrawn")
        world.objects[0].pos = { 1.1, 0, 1 }
        Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
        T.eq(table.concat(moves, ","), "crateA", "the moved carried one")
        moves = {}
        Dynamics.draw(s, { replay_mode = 0, match_frame = 1 })
        T.eq(#moves, 0, "a still frame: nothing")
        world.players[1] = { 20, 0, 1 }
        world.objects[1].pos = { 1.6, 0, 1 }
        Dynamics.draw(s, { replay_mode = 0, match_frame = 2 })
        -- both released; crateA's copy already shows where it stays, crateB moved this frame
        T.eq(table.concat(moves, ","), "crateB", "only the one whose pose changed")
        moves = {}
        Dynamics.draw(s, { replay_mode = 0, match_frame = 3 })
        T.eq(#moves, 0, "released ones aren't redrawn again")
        Atmospheres.EntityHolder = holder() -- the atmo loaded again: its copies at the atmo's poses
        Dynamics.draw(s, { replay_mode = 0, match_frame = 4 })
        table.sort(moves)
        T.eq(table.concat(moves, ","), "crateA,crateB", "the moved ones drawn again on the new atmo")
    end)
    Atmospheres, Utils3D = savedAtmo, savedUtils
    if not ok then error(err) end
end)
