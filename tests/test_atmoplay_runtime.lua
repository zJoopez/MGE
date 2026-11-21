-- atmoplay/runtime.lua against a fake game: mod detection, drawing through the cache atmo, the pool placed
-- in match_begin and moved between physics steps (draw2d) in fights, nothing moved in replays, giving the
-- player's atmo back
local T = ...
local Builder = ATMOPLAY.Builder

local ATMO = {
    "shader dark",
    "env_obj wall", "   shape box", "   pos 1 0 1", "   sides 0.5 4 2",
    "env_obj floor", "   shape box", "   pos 0 0 -0.1", "   sides 6 6 0.2", "   bounce 0.5",
    "env_obj ball", "   shape sphere", "   pos 0 2 1", "   sides 0.3 0 0",
    "env_obj clip", "   shape box", "   pos -1 0 1", "   sides 0.2 4 2", "   visible 0",
    "env_obj far", "   shape box", "   pos 50 0 0", "   sides 1 1 1",
}

---A fake game: files by path, hooks, world, a log of every object call
local function fakeGame()
    local game = {
        files = {}, hooks = {}, log = {}, options = { replaycache = 2 }, loads = {},
        mod = "classic", frame = 0, replay = 0, bodies = { { 0, 0, 1 }, { 0, 3, 1 } }, objects = {}, said = {},
    }
    local playable = assert(Builder.build({}, ATMO, { maxId = 56 })) -- pool ids 49..56 (5 colliders: 5 used)
    game.files["../data/mod/arena.tbm"] = table.concat(playable, "\n")
    game.files["../data/mod/plain.tbm"] = "gamerule\n    matchframes 500\nenv_obj 1\n    shape box\n    flag 8"
    game.files["../data/atmospheres/atmo.cfg"] = "sunset.atmo"
    for _, line in ipairs(playable) do
        local id = line:match("^env_obj (%d+)$")
        if id then game.objects[tonumber(id) - 1] = true end
    end

    local saved = {}
    local names = { "Files", "FILES_MODE_READONLY", "FILES_MODE_WRITE", "FILES_MODE_APPEND", "get_game_rules", "get_world_state",
        "get_body_info", "BODYPARTS", "get_obj_pos", "set_obj_pos", "set_obj_sides", "set_obj_rot_m",
        "set_obj_flag", "set_obj_bounce", "set_obj_color", "set_obj_vis", "get_option", "set_option",
        "Atmospheres", "add_hook", "remove_hooks", "find_mod", "echo", "ATMOPLAY_LOADATMO",
        "get_obj_flag", "get_obj_bounce" }
    for _, name in ipairs(names) do saved[name] = rawget(_G, name) end
    function game.restore()
        for _, name in ipairs(names) do rawset(_G, name, saved[name]) end
    end

    FILES_MODE_READONLY, FILES_MODE_WRITE, FILES_MODE_APPEND = "r", "w+", "a"
    Files = {
        Open = function(path, mode)
            local file = { data = (mode == FILES_MODE_WRITE or game.files[path]) and true or nil }
            if mode == FILES_MODE_WRITE then game.files[path] = "" end
            function file:readAll() return T.lines(game.files[path]) end
            function file:writeLine(line) game.files[path] = game.files[path] .. line .. "\n" end
            function file:close() end
            return file
        end,
        Exists = function(path) return game.files[path] ~= nil end,
    }
    get_game_rules = function() return { mod = game.mod } end
    get_world_state = function() return { match_frame = game.frame, replay_mode = game.replay, num_players = 2 } end
    BODYPARTS = { HEAD = 0, CHEST = 1 }
    get_body_info = function(player, part)
        local b = game.bodies[player + 1]
        return { pos = { x = b[1], y = b[2], z = b[3] + part * 0.1 } }
    end
    get_obj_pos = function(id) if game.objects[id] then return 0, 0, 0 end end
    get_obj_flag = function() return 8 end
    get_obj_bounce = function() return 0.2 end
    local function logger(name)
        return function(id, ...)
            local args = { ... }
            for i, v in ipairs(args) do
                if type(v) == "table" then args[i] = "m" elseif type(v) == "number" then args[i] = string.format("%.3f", v) end
            end
            game.log[#game.log + 1] = name .. " " .. id .. " " .. table.concat(args, " ")
        end
    end
    set_obj_pos, set_obj_sides, set_obj_rot_m = logger("pos"), logger("sides"), logger("rot")
    set_obj_flag, set_obj_bounce, set_obj_color, set_obj_vis = logger("flag"), logger("bounce"), logger("color"), logger("vis")
    get_option = function(name) return game.options[name] end
    set_option = function(name, value) game.options[name] = value end
    Atmospheres = {
        LoadAtmo = function(name) game.loads[#game.loads + 1] = name end,
        Unload = function() game.loads[#game.loads + 1] = "(unload)" end,
    }
    game.originalLoadAtmo = Atmospheres.LoadAtmo
    ATMOPLAY_LOADATMO = nil
    add_hook = function(event, set, fn) game.hooks[event .. "/" .. set] = fn end
    remove_hooks = function(set)
        for key in pairs(game.hooks) do
            if key:sub(-#set - 1) == "/" .. set then game.hooks[key] = nil end
        end
    end
    find_mod = function() return nil end
    echo = function(text) game.said[#game.said + 1] = text end

    function game.fire(event, ...)
        local fn = game.hooks[event .. "/atmoplay"]
        if fn then return fn(...) end
    end
    ---/lm: the gamerule changes and match_begin runs inside it
    function game.lm(mod)
        game.mod, game.frame, game.replay = mod, 0, 0
        game.bodies[1] = { 0, 0, 1 } -- a new fight starts at the spawn
        game.fire("match_begin")
    end
    ---Frames 0..n-1 with tori walking along x: each fires enter_frame (inside the physics step) and then
    ---draw2d (between steps), like the game. Returns the object calls they made
    function game.play(n, replay, from)
        game.replay = replay and 1 or 0
        local first = #game.log
        for f = from or 0, (from or 0) + n - 1 do
            game.frame = f
            game.bodies[1] = { -2 + f * 0.1, 0, 1 }
            game.fire("enter_frame")
            game.fire("draw2d")
        end
        local calls = {}
        for i = first + 1, #game.log do calls[#calls + 1] = game.log[i] end
        return calls
    end
    ---Calls logged since index `from`
    function game.since(from)
        local calls = {}
        for i = from + 1, #game.log do calls[#calls + 1] = game.log[i] end
        return calls
    end
    return game
end

local function startRuntime()
    ATMOPLAY_LOADING = ATMOPLAY -- a fresh module state per test, loaded like atmoplay.lua does
    dofile(ATMOPLAY.scriptPath .. "runtime.lua")
    ATMOPLAY_LOADING = nil
    ATMOPLAY.Runtime.start()
    return ATMOPLAY.Runtime
end

local function run(name, fn)
    T.test(name, function()
        local game = fakeGame()
        local ok, err = pcall(fn, game)
        game.restore()
        if not ok then error(err) end
    end)
end

run("start: options untouched, normal mod left alone, playable mod drawn", function(game)
    local Runtime = startRuntime()
    T.eq(game.options.replaycache, 2, "replaycache isn't touched")
    T.eq(Runtime.state.loaded, nil, "classic isn't playable")
    game.lm("plain.tbm")
    T.eq(Runtime.state.loaded, nil, "a mod without header isn't playable")
    game.lm("arena.tbm")
    T.ok(Runtime.state.loaded ~= nil, "arena is playable")
    T.eq(game.loads[#game.loads], "Atmo Play.atmo", "the cache atmo is loaded")
    local cache = game.files["../data/atmospheres/Atmo Play.atmo"]
    T.ok(cache:find("env_obj wall", 1, true) ~= nil, "cache holds the atmo")
    T.ok(cache:find("#@", 1, true) == nil, "without the prefix")
    T.ok(cache:find("env_obj clip", 1, true) == nil, "invisible objects aren't drawn")
    T.eq(#Runtime.state.loaded.pool.entries, 5, "pool objects")
    T.eq(Runtime.state.loaded.missing, 0, "all pool objects exist")
end)

run("a fight places the pool from frame 1 and moves it from draw2d only", function(game)
    startRuntime()
    local before = #game.log
    game.lm("arena.tbm")
    T.eq(#game.since(before), 0, "match_begin moves nothing (Driver.FIRST_FRAME: R before a move crashed)")
    game.fire("enter_frame")
    game.fire("draw2d")
    T.eq(#game.since(before), 0, "nor frame 0's draw2d")
    local atStart = game.play(1, false, 1)
    T.ok(T.find(atStart, "^pos ", true) ~= nil, "pool placed at frame 1")
    T.ok(T.find(atStart, "^rot %d+ m$", true) ~= nil, "rotations set")
    T.eq(T.find(atStart, "^bounce ", true), nil, "no bounce set live (replays don't record it)")
    T.ok(game.files["../data/mod/arena.tbm"]:find("\n%s*bounce 0.5", 1) ~= nil,
        "the floor's bounce written on its group's pool object")
    -- tori walks to x 46: the far box (x 50) comes into reach and takes the parked pool object (uke stays
    -- near the start, so the near ones stay wanted)
    local fight = game.play(479, false, 2)
    T.ok(T.find(fight, "^pos %d+ 50.000 0.000 0.000$", true) ~= nil, "the pool follows tori to the far box")
    local enterOnly = #game.log
    game.frame = 481
    game.fire("enter_frame")
    T.eq(#game.log, enterOnly, "enter_frame moves nothing")
end)

run("opened replays move nothing; back in the fight everything is set again", function(game)
    startRuntime()
    game.lm("arena.tbm")
    game.play(20, false, 1)
    -- a replay opened (its match_begin, measured): all of it is recorded
    game.fire("leave_game")
    game.replay, game.frame = 1, 0
    local before = #game.log
    game.fire("match_begin")
    T.eq(#game.log, before, "replay start: no calls (the replay has the pool's moves)")
    local replay = game.play(40, true)
    T.eq(#replay, 0, "no object calls during an opened replay, also past the last fight's frames")
    -- back to the fight (the replay view left at frame 20)
    game.frame, game.replay = 20, 0
    before = #game.log
    game.fire("draw2d")
    local positions = 0
    for _, call in ipairs(game.since(before)) do
        if call:match("^pos ") then positions = positions + 1 end
    end
    T.eq(positions, 5, "all five pool objects set again")
end)

run("a fight that goes back to an earlier frame starts the assignment over", function(game)
    local Runtime = startRuntime()
    game.lm("arena.tbm")
    game.play(30, false, 1)
    local before = #game.log
    game.frame = 5 -- a replay edited and played on from frame 5
    game.fire("draw2d")
    local positions = 0
    for _, call in ipairs(game.since(before)) do
        if call:match("^pos ") then positions = positions + 1 end
    end
    T.eq(positions, 5, "all five pool objects set again")
    T.eq(Runtime.state.loaded.driver.lastFrame, 5, "driving from frame 5 on")
end)

run("the same frames give the same calls (a fight restarted)", function(game)
    startRuntime()
    local before = #game.log
    game.lm("arena.tbm")
    local first = game.since(before)
    for _, call in ipairs(game.play(30, false, 1)) do first[#first + 1] = call end
    before = #game.log
    game.lm("arena.tbm") -- restart: match_begin again, same mod (no reload)
    local second = game.since(before)
    for _, call in ipairs(game.play(30, false, 1)) do second[#second + 1] = call end
    T.eq(table.concat(second, "\n"), table.concat(first, "\n"), "identical object calls")
end)

run("the player's atmo comes back; quit unwraps the manager", function(game)
    local Runtime = startRuntime()
    game.lm("arena.tbm")
    game.lm("plain.tbm")
    T.eq(game.loads[#game.loads], "sunset.atmo", "atmo.cfg's atmo loaded again")
    Atmospheres.LoadAtmo("night.atmo") -- the player picks another one
    game.lm("arena.tbm")
    game.lm("classic")
    T.eq(game.loads[#game.loads], "night.atmo", "the player's latest pick comes back")
    game.lm("arena.tbm")
    Runtime.quit()
    T.eq(game.loads[#game.loads], "night.atmo", "quit gives the atmo back too")
    T.eq(game.options.replaycache, 2, "replaycache never touched")
    T.eq(Atmospheres.LoadAtmo, game.originalLoadAtmo, "the manager's LoadAtmo unwrapped")
    T.eq(next(game.hooks), nil, "no hooks left")
end)

run("commands, show, debug log and hold", function(game)
    startRuntime()
    T.eq(game.fire("command", "atmoplay"), 1, "/atmoplay handled")
    T.eq(game.fire("command", "ping"), nil, "other commands left alone")
    game.lm("arena.tbm")
    game.fire("command", "atmoplay show")
    game.play(2, false, 1)
    T.ok(T.find(game.log, "^vis %d+ ", true) ~= nil, "show sets visibility")
    game.fire("command", "atmoplay log")
    game.play(3, false, 3)
    local log = game.files["atmoplay_debug.log"]
    T.ok(log and log:find("drive: frame 3", 1, true) ~= nil, "frames logged")
    game.fire("leave_game")
    T.ok(game.files["atmoplay_debug.log"]:find("leave_game", 1, true) ~= nil, "hooks logged")
    game.fire("command", "atmoplay hold")
    T.eq(#game.play(5, false, 10), 0, "held: no object calls")
    game.fire("command", "atmoplay hold")
    T.ok(#game.play(5, false, 15) > 0, "moving again")
end)

run("unload (the menu, the save overlay, other scripts) doesn't stop it", function(game)
    local Runtime = startRuntime()
    game.lm("arena.tbm")
    game.fire("unload")
    T.ok(game.hooks["draw2d/atmoplay"] ~= nil, "hooks still in")
    T.ok(Runtime.state.loaded ~= nil, "the playable mod still loaded")
    T.ok(#game.play(480, false, 1) > 0, "the pool still moves")
    -- a replay opened from the menu afterwards: its mod is read and drawn
    game.mod, game.replay, game.frame = "plain.tbm", 1, 0
    game.fire("match_begin")
    game.mod = "arena.tbm"
    local loads = #game.loads
    game.fire("match_begin")
    T.eq(game.loads[loads + 1], "Atmo Play.atmo", "the replay's atmo is drawn")
end)

---------------------------------------------------------------------------------------------------- replays entered from a fight

run("R mid-fight: the replay moves nothing, also past the fight's frames (no tail)", function(game)
    startRuntime()
    game.lm("arena.tbm")
    game.play(20, false, 1) -- the fight reaches frame 20
    -- R: leave_game only, no match_begin (measured in game), then the replay draws
    game.fire("leave_game")
    T.eq(#game.play(40, true), 0, "the recorded frames and the unplayed ones after them: nothing moved")
    T.eq(#game.play(40, true), 0, "looped: nothing again")
end)

run("back in a fight after a replay: positions set again, no flag or bounce set live", function(game)
    startRuntime()
    game.lm("arena.tbm")
    local fight = game.play(20, false, 1)
    T.eq(T.find(fight, "^bounce ", true), nil, "no bounce set live (the mod has each group's)")
    game.fire("leave_game")
    game.play(21, true)
    game.frame, game.replay = 20, 0 -- the replay view left (or an edit) at frame 20
    local before = #game.log
    game.fire("draw2d")
    local back = game.since(before)
    T.ok(T.find(back, "^pos ", true) ~= nil, "every pool object set again")
    local beforeNextMatch = #game.log
    T.eq(T.find(back, "^flag ", true), nil, "no flag set again (replays don't record flags: what's set stays)")
    local last = {}
    for i = 1, beforeNextMatch do -- the fight, its replay and the way back (the next match sets them again)
        local id, value = game.log[i]:match("^bounce (%d+) (%S+)")
        if id then
            T.ok(last[id] ~= value, "bounce " .. value .. " on " .. id .. " is a change")
            last[id] = value
        end
    end
    game.lm("arena.tbm") -- a new match loads the objects from the mod: flags and bounces are the file's again
    T.eq(T.find(game.play(1, false, 1), "^bounce ", true), nil, "nor in a new fight")
end)

run("R before any move: nothing moved, in the fight or the replay", function(game)
    startRuntime()
    game.lm("arena.tbm")
    game.fire("draw2d") -- frame 0, waiting for the first move
    T.eq(#game.log, 0, "nothing moved yet (no pool for that replay to put at 0,0,0)")
    game.fire("leave_game")
    T.eq(#game.play(40, true), 0, "the replay moves nothing")
end)

run("debug log: every object call and a summary per frame, the setters back after", function(game)
    startRuntime()
    local original = set_obj_pos
    game.fire("command", "atmoplay log")
    T.ok(set_obj_pos ~= original, "traced while logging")
    game.lm("arena.tbm")
    game.play(2, false, 1)
    local text = game.files["atmoplay_debug.log"] or ""
    T.ok(text:find("  set_obj_pos ", 1, true) ~= nil, "object calls logged")
    T.ok(text:find("objects: frame 1 replay 0", 1, true) ~= nil, "a summary per frame")
    T.ok(text:find("pool objects at 0,0,0", 1, true) ~= nil, "with the objects at the origin")
    T.ok(#game.log > 0, "the calls still reach the game")
    game.fire("command", "atmoplay log")
    T.eq(set_obj_pos, original, "the engine's setter back")
    T.eq(ATMOPLAY_TRACED, nil, "nothing kept")
end)
