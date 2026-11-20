-- The in-game part (docs/atmo-play-plan.md, part 2): on every match_begin it looks at the loaded mod; a playable
-- mod's atmo is drawn through the game's atmosphere manager, and in fights its pool is moved onto the
-- atmo objects nearest the players. Replays need nothing from it but the drawing: the game records every
-- env object change (EOBJ lines) and replays them. Facts it relies on (measured, see the plan):
--   * /lm and open_replay are synchronous: match_begin runs inside them, the world already exists
--   * object changes made in match_begin are recorded under FRAME 0, changes made between physics steps
--     (draw2d) under the step they affect: their replay is exact, cached or not. Changes made in
--     enter_frame are recorded one step late, so the pool is never moved there
--   * moving objects during a replay crashed the game at the replay's end: in replays nothing is moved
--   * the game's io.open handles lack :lines() and fail on "../" paths: files go through Files
--   * Atmospheres.LoadAtmo of 5k objects takes ~0.3 s: the atmo is loaded only when the mod changes

local NS = ATMOPLAY_LOADING -- the namespace the loader gives (Atmo Play's ATMOPLAY, MGE's MGE.AtmoPlay)

local Format = NS.Format
local Colliders = NS.Colliders
local Pool = NS.Pool
local Driver = NS.Driver

---@class AtmoPlayRuntime
local Runtime = {
    HOOKS = "atmoplay",
    MOD_FOLDER = "../data/mod/",
    ATMO_FOLDER = "../data/atmospheres/",
    CACHE_ATMO = "Atmo Play.atmo", -- the drawn part of the loaded playable mod's atmo
    LOG_PATH = "atmoplay_debug.log", -- data/script, /atmoplay log
}

---@class AtmoPlayLoaded
---@field path string the mod file under data/mod
---@field name string shown in messages
---@field file AtmoPlayModFile
---@field colliders AtmoPlayCollider[]
---@field stats table Colliders.build's
---@field pool AtmoPlayPoolState
---@field driver AtmoPlayDriver moves the pool (driver.lua)
---@field missing integer pool objects not in the world (the mod file changed since /lm?)

local state = {
    modName = nil, ---@type string? the mod gamerule last seen at match_begin
    loaded = nil, ---@type AtmoPlayLoaded?
    drawnByUs = false, -- the cache atmo is loaded (the player's atmo comes back when a normal mod loads)
    ourLoad = false, -- Atmospheres.LoadAtmo is called by Atmo Play right now (not the player's pick)
    playerAtmo = nil, ---@type string? the player's atmo: the last one loaded by others, or atmo.cfg's
    show = false, -- debug: pool objects visible (/atmoplay show), kept for the next mod
    log = false, -- debug: hooks and object calls to Runtime.LOG_PATH (/atmoplay log)
    hold = false, -- debug: the pool isn't moved at all (/atmoplay hold), kept for the next mod
}
Runtime.state = state

local function say(text)
    echo("^04[Atmo Play] ^07" .. text)
end
Runtime.say = say

local clock = os and os.clock or function() return 0 end

---@param path string Files path ("../" = the Toribash folder)
---@return string[]?
local function readLines(path)
    local file = Files.Open(path, FILES_MODE_READONLY)
    if not file.data then return nil end
    local lines = file:readAll()
    file:close()
    return lines
end

---@param path string
---@param lines string[]
---@return boolean
local function writeLines(path, lines)
    local file = Files.Open(path, FILES_MODE_WRITE)
    if not file.data then return false end
    file:writeLine(table.concat(lines, "\n"))
    file:close()
    return true
end

---The mod gamerule as a file under data/mod: it keeps the /lm folder ("modmaker/x.tbm"); find_mod for
---names the game found elsewhere. nil for the built-in classic (no .tbm, no file)
---@param name string?
---@return string?
local function resolveModPath(name)
    name = tostring(name or "")
    if not name:match("%.tbm$") then return nil end
    if Files.Exists(Runtime.MOD_FOLDER .. name) then return name end
    local found = find_mod and find_mod(name)
    if type(found) == "string" and found ~= "" then return found end
    return nil
end

---------------------------------------------------------------------------------------------------- atmo

local function manager()
    local m = rawget(_G, "Atmospheres")
    if type(m) == "table" and type(m.LoadAtmo) == "function" then return m end
    return nil
end

---Load an atmo through the game's manager, as Atmo Play (not remembered as the player's choice)
---@param name string? nil unloads
local function loadAtmo(name)
    local m = manager()
    if not m then return false end
    state.ourLoad = true
    local ok, err
    if name then ok, err = pcall(m.LoadAtmo, name) else ok, err = pcall(m.Unload) end
    state.ourLoad = false
    if not ok then say("couldn't load the atmo " .. tostring(name) .. ": " .. tostring(err)) end
    return ok
end

---Remembers the atmos others load (the main menu's Atmos list, other scripts): that's what comes back
---when a normal mod loads. The original is kept in a global so a reload doesn't wrap the wrapper
local function wrapAtmoLoading()
    local m = manager()
    if not m then return end
    ATMOPLAY_LOADATMO = ATMOPLAY_LOADATMO or m.LoadAtmo
    local original = ATMOPLAY_LOADATMO
    m.LoadAtmo = function(filename, ...)
        if not state.ourLoad then
            state.playerAtmo = filename
            if state.drawnByUs then state.drawnByUs = false end -- the player replaced ours
        end
        return original(filename, ...)
    end
end

local function unwrapAtmoLoading()
    local m = manager()
    if m and ATMOPLAY_LOADATMO then m.LoadAtmo = ATMOPLAY_LOADATMO end
    ATMOPLAY_LOADATMO = nil
end

---The player's default atmo (data/atmospheres/atmo.cfg's first line), what the game loaded at start
---@return string?
local function defaultAtmo()
    local lines = readLines(Runtime.ATMO_FOLDER .. "atmo.cfg")
    local name = lines and lines[1]
    if name and name ~= "" then return name end
    return nil
end

local function restorePlayerAtmo()
    if not state.drawnByUs then return end
    state.drawnByUs = false
    local name = state.playerAtmo
    if name and name:lower() ~= "default.atmo" then loadAtmo(name) else loadAtmo(nil) end
end

---------------------------------------------------------------------------------------------------- pool

---Start the loaded pool over (driver.lua)
local function resetPool()
    if state.loaded then Driver.reset(state.loaded.driver) end
end

---------------------------------------------------------------------------------------------------- debug log

---/atmoplay log: every hook and every frame's planned object calls go to data/script/atmoplay_debug.log,
---written (and closed) before the calls run, so after a crash the file ends at what was happening
local function debugLog(lines)
    if not state.log then return end
    local file = Files.Open(Runtime.LOG_PATH, FILES_MODE_APPEND)
    if not file.data then return end
    for _, line in ipairs(lines) do file:writeLine(line) end
    file:close()
end

---@param ws table get_world_state()
---@return string
local function worldLine(ws)
    return string.format("frame %s replay %s game_frame %s gameover %s paused %s winner %s", tostring(ws.match_frame),
        tostring(ws.replay_mode), tostring(ws.game_frame), tostring(ws.gameover_frame), tostring(ws.game_paused),
        tostring(ws.winner))
end

---@param event string
local function logEvent(event)
    if not state.log then return end
    debugLog({ string.format("%.3f %s: %s mod %s", clock(), event, worldLine(get_world_state()),
        tostring(get_game_rules().mod)) })
end

---@param changes AtmoPlayPoolChange[]
---@param ws table
local function logFrame(changes, ws)
    if not state.log then return end
    local lines = { string.format("%.3f drive: %s, %d changes%s", clock(), worldLine(ws), #changes,
        state.hold and " (held: not applied)" or "") }
    for _, change in ipairs(changes) do
        local c = change.collider
        if c then
            lines[#lines + 1] = string.format("  place %d -> %s %s at %.2f %.2f %.2f", change.entry.id - 1, c.name,
                c.shape, c.pos[1], c.pos[2], c.pos[3])
        else
            lines[#lines + 1] = string.format("  park %d", change.entry.id - 1)
        end
    end
    debugLog(lines)
end

---------------------------------------------------------------------------------------------------- mods

---Reads a playable mod and draws its atmo. nil when the mod isn't playable (or can't be read)
---@param path string
---@return AtmoPlayLoaded?
local function loadPlayable(path)
    local start = clock()
    local lines = readLines(Runtime.MOD_FOLDER .. path)
    if not lines then return nil end
    local file = Format.read(lines)
    if not file.header then return nil end
    local name = path:match("([^/]+)%.tbm$") or path
    -- MGE open: it draws the atmo itself and moves a playable mod's pool (the same driver.lua); two drivers
    -- would move the same objects
    local mge = rawget(_G, "MGE")
    if type(mge) == "table" and mge.running then
        say(name .. ": MGE is open, it plays playable mods itself (Atmo list > Advanced > Playable On)")
        return nil
    end
    local colliders, stats = Colliders.build(file.atmo)
    local pool, err = Pool.new(file.pool, colliders, file.header)
    if not pool then
        say(name .. ": " .. tostring(err))
        return nil
    end
    local missing = 0
    for _, object in ipairs(file.pool) do
        if get_obj_pos(object.id - 1) == nil then missing = missing + 1 end
    end
    -- the pool objects are in the world right after /lm: the driver reads their own flag and bounce
    local driver = Driver.new(pool)
    driver.show, driver.hold, driver.onDrive = state.show, state.hold, logFrame
    local parsed = clock()

    local drawn = false
    if manager() then
        if writeLines(Runtime.ATMO_FOLDER .. Runtime.CACHE_ATMO, Format.drawnLines(file.atmo)) then
            drawn = loadAtmo(Runtime.CACHE_ATMO)
            state.drawnByUs = drawn
        else
            say("couldn't write data/atmospheres/" .. Runtime.CACHE_ATMO .. ", the atmo isn't drawn")
        end
    else
        say("the game's atmosphere manager isn't loaded, the atmo isn't drawn")
    end

    local skipped = 0
    for _, n in pairs(stats.skipped) do skipped = skipped + n end
    say(string.format("%s: %d atmo objects, %d solid%s, %d pool objects (rule %d, radius %s); read %.0f ms, drawn %.0f ms",
        name, stats.total, stats.collidable, skipped > 0 and (", " .. skipped .. " drawn only") or "", #file.pool,
        pool.rule, tostring(pool.radius), (parsed - start) * 1000, (clock() - parsed) * 1000))
    if missing > 0 then
        say(missing .. " pool objects aren't in the world: reload the mod (/lm) after changing it")
    end
    return { path = path, name = name, file = file, colliders = colliders, stats = stats, pool = pool,
        driver = driver, missing = missing, drawn = drawn }
end

local function leavePlayable()
    state.loaded = nil
    restorePlayerAtmo()
end

---The mod changed (or a forced reload): leave the old playable mod, read the new one
local function switchMod(name)
    state.modName = name
    if state.loaded then leavePlayable() end
    local path = resolveModPath(name)
    if path then state.loaded = loadPlayable(path) end
end

---------------------------------------------------------------------------------------------------- hooks

local function onMatchBegin()
    logEvent("match_begin")
    local name = get_game_rules().mod
    if name ~= state.modName then switchMod(name) end
    -- a fight: the pool is placed now (recorded under FRAME 0); a replay has it in its own FRAME 0
    if state.loaded then Driver.matchBegin(state.loaded.driver, get_world_state()) end
end

---Between physics steps: in a fight, the pool follows the players once per new frame (driver.lua)
local function onDraw2d()
    if state.loaded then Driver.draw(state.loaded.driver, get_world_state()) end
end

local function onLeaveGame()
    logEvent("leave_game")
    resetPool()
end

---------------------------------------------------------------------------------------------------- commands

function Runtime.status()
    local loaded = state.loaded
    if not loaded then
        say("running; the loaded mod (" .. tostring(state.modName) .. ") isn't a playable mod")
        return
    end
    local d = loaded.driver
    say(string.format("%s: %d/%d pool objects in use, %d solid atmo objects; pool step %.2f ms average, %.2f ms worst (%d frames)",
        loaded.name, Driver.active(d), #loaded.pool.entries, loaded.stats.collidable,
        d.steps > 0 and d.stepTime / d.steps or 0, d.worstStep, d.steps))
end

---Debug: pool objects visible (green) where they stand in for an atmo object
function Runtime.toggleShow()
    state.show = not state.show
    if state.loaded then Driver.setShow(state.loaded.driver, state.show) end
    say("pool objects " .. (state.show and "shown in green" or "hidden"))
end

local function onCommand(text)
    local word, rest = tostring(text or ""):match("^%s*(%S+)%s*(.-)%s*$")
    if word ~= "atmoplay" then return end
    if rest == "" or rest == "status" then
        Runtime.status()
    elseif rest == "show" then
        Runtime.toggleShow()
    elseif rest == "reload" then
        switchMod(get_game_rules().mod)
        resetPool()
    elseif rest == "log" then
        state.log = not state.log
        if state.log then
            local file = Files.Open(Runtime.LOG_PATH, FILES_MODE_WRITE)
            if file.data then
                file:writeLine("Atmo Play debug log; " .. tostring(state.loaded and state.loaded.name or "no playable mod"))
                file:close()
            end
            say("logging every frame to data/script/" .. Runtime.LOG_PATH .. " (slow; /atmoplay log again stops it)")
        else
            say("log stopped")
        end
    elseif rest == "hold" then
        state.hold = not state.hold
        say(state.hold and "pool held: not moved at all (nothing is solid)" or "pool moving again")
        if state.loaded then
            state.loaded.driver.hold = state.hold
            if not state.hold then resetPool() end
        end
    elseif rest == "quit" then
        if ATMOPLAY and ATMOPLAY.quit then ATMOPLAY.quit() end
    else
        say("/atmoplay [status | show | reload | log | hold | quit]")
    end
    return 1
end

---------------------------------------------------------------------------------------------------- start / quit

function Runtime.start()
    remove_hooks(Runtime.HOOKS)
    state.playerAtmo = defaultAtmo() -- a restart quits first, which gives the player's atmo back
    wrapAtmoLoading()

    add_hook("match_begin", Runtime.HOOKS, onMatchBegin)
    add_hook("draw2d", Runtime.HOOKS, onDraw2d)
    add_hook("leave_game", Runtime.HOOKS, onLeaveGame)
    add_hook("command", Runtime.HOOKS, onCommand)
    add_hook("end_game", Runtime.HOOKS, function() logEvent("end_game") end)
    add_hook("new_game", Runtime.HOOKS, function() logEvent("new_game") end)
    -- "unload" isn't an end: the game fires it when it loads its own scripts too (opening the menu, the
    -- replay save overlay ('f') when the menu isn't loaded), and hooks stay. The game's chat scripts only
    -- rebuild their UI on it. Atmo Play keeps running; /atmoplay quit (or /ls again) stops it
    add_hook("unload", Runtime.HOOKS, function() logEvent("unload") end)

    -- the mod that's loaded now
    switchMod(get_game_rules().mod)
    say("running" .. (state.loaded and "" or ": load a playable mod (/lm)") .. ". /atmoplay for status")
end

function Runtime.quit()
    remove_hooks(Runtime.HOOKS)
    if state.loaded then
        leavePlayable() -- pool objects stay where they are until the next /lm; the atmo goes back
    end
    unwrapAtmoLoading()
end

NS.Runtime = Runtime
return Runtime
