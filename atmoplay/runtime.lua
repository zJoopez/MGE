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
local Dynamics = NS.Dynamics

---@class AtmoPlayRuntime
local Runtime = {
    HOOKS = "atmoplay",
    MOD_FOLDER = "../data/mod/",
    ATMO_FOLDER = "../data/atmospheres/",
    CACHE_ATMO = "Atmo Play.atmo", -- the drawn part of the loaded playable mod's atmo
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
---@field dynamics table? the props and their pool (dynamics.lua), nil without props

local state = {
    modName = nil, ---@type string? the mod gamerule last seen at match_begin
    loaded = nil, ---@type AtmoPlayLoaded?
    drawnByUs = false, -- the cache atmo is loaded (the player's atmo comes back when a normal mod loads)
    ourLoad = false, -- Atmospheres.LoadAtmo is called by Atmo Play right now (not the player's pick)
    playerAtmo = nil, ---@type string? the player's atmo: the last one loaded by others, or atmo.cfg's
    cacheBefore = nil, ---@type number? the player's replaycache, while a mod with props has it off
}
Runtime.state = state

local function say(text)
    echo("^04[Atmo Play] ^07" .. text)
end
Runtime.say = say

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
    if state.loaded and state.loaded.driver then Driver.reset(state.loaded.driver) end
end

---------------------------------------------------------------------------------------------------- debug log

-- the dev-only debug log (debuglog.lua, /atmoplay log): not in the releases, where NS.DebugLog is nil and these do
-- nothing
local function debugCall(name, ...)
    local log = NS.DebugLog
    if log then log[name](...) end
end

---------------------------------------------------------------------------------------------------- mods

---Draws a mod's atmo: the drawn part written as the cache atmo and loaded through the game's manager
---@param atmoLines string[]
---@return boolean drawn
local function drawModAtmo(atmoLines)
    if not manager() then
        say("the game's atmosphere manager isn't loaded, the atmo isn't drawn")
        return false
    end
    if not writeLines(Runtime.ATMO_FOLDER .. Runtime.CACHE_ATMO, Format.drawnLines(atmoLines)) then
        say("couldn't write data/atmospheres/" .. Runtime.CACHE_ATMO .. ", the atmo isn't drawn")
        return false
    end
    local drawn = loadAtmo(Runtime.CACHE_ATMO)
    state.drawnByUs = drawn
    return drawn
end

---Reads a playable mod and draws its atmo. nil when the mod isn't playable (or can't be read)
---@param path string
---@return AtmoPlayLoaded?
local function loadPlayable(path)
    local lines = readLines(Runtime.MOD_FOLDER .. path)
    if not lines then return nil end
    local file = Format.read(lines)
    if not file.header then return nil end
    local name = path:match("([^/]+)%.tbm$") or path
    -- MGE open: it draws the atmo itself and moves a playable mod's pool (the same driver.lua); two drivers
    -- would move the same objects
    if Runtime.mgeRunning() then
        say(name .. ": MGE is open, it plays this mod")
        return nil
    end
    -- a drawn mod (MGE's Default): its atmo is only drawn, there are no pools (driver nil: the hooks skip it)
    if Format.isDrawOnly(file.header) then
        local drawn = drawModAtmo(file.atmo)
        say(name .. ": atmo drawn (a drawn mod, not solid)")
        return { path = path, name = name, file = file, drawn = drawn, drawOnly = true }
    end
    local colliders, stats, props = Colliders.build(file.atmo)
    local pool, err = Pool.new(file.pool, colliders, file.header)
    if not pool then
        say(name .. ": " .. tostring(err))
        return nil
    end
    local missing = 0
    for _, object in ipairs(file.pool) do
        if get_obj_pos(object.id - 1) == nil then missing = missing + 1 end
    end
    for _, object in ipairs(file.dynamic) do
        if get_obj_pos(object.id - 1) == nil then missing = missing + 1 end
    end
    -- the pool objects are in the world right after /lm (each written with its group's flag and bounce)
    local driver = Driver.new(pool)
    driver.onDrive = NS.DebugLog and NS.DebugLog.onDrive
    -- the mod's own dynamic objects: the static pool keeps a floor under them too
    local skip = {}
    for _, object in ipairs(file.dynamic) do skip[object.id] = true end
    driver.follow = Driver.dynamicIds(skip)
    -- props (proof of concept): their own pool, and the static pool covers the carried ones
    local dynamics
    if #file.dynamic > 0 and #props > 0 then
        -- follow: the mod's own dynamic objects push props too
        dynamics = Dynamics.new(file.dynamic, props, { dradius = file.header.dradius, follow = driver.follow })
        driver.moreCenters = function() return Dynamics.centers(dynamics) end
    elseif #props > 0 then
        say(name .. ": " .. #props .. " props without a dynamic pool (not solid)")
    end
    local drawn = drawModAtmo(file.atmo)

    local skipped = 0
    for _, n in pairs(stats.skipped) do skipped = skipped + n end
    say(string.format("%s: %d atmo objects, %d solid%s, %d pool objects", name, stats.total, stats.collidable,
        skipped > 0 and (", " .. skipped .. " drawn only") or "", #file.pool))
    if dynamics then
        say(string.format("%d props (pushable), %d dynamic pool objects", #props, #file.dynamic))
    end
    if missing > 0 then
        say(missing .. " pool objects missing: load the mod again (/lm)")
    end
    return { path = path, name = name, file = file, colliders = colliders, stats = stats, pool = pool,
        driver = driver, missing = missing, drawn = drawn, dynamics = dynamics }
end

---Props are followed in replays by watching their pool objects, and cached replays misplace teleported
---dynamic objects (measured: 33-88 units off), so a mod with props has the replay cache off while it's
---loaded; the player's setting comes back when it leaves
local function replayCacheOff()
    local ok, value = pcall(get_option, "replaycache")
    if not ok or tonumber(value) == 0 then return end
    state.cacheBefore = tonumber(value)
    set_option("replaycache", 0)
    say("replay cache off while this mod is loaded")
end

local function restoreReplayCache()
    if state.cacheBefore == nil then return end
    pcall(set_option, "replaycache", state.cacheBefore)
    state.cacheBefore = nil
end

local function leavePlayable()
    if state.loaded and state.loaded.dynamics then pcall(Dynamics.restoreCopies, state.loaded.dynamics) end
    state.loaded = nil
    restoreReplayCache()
    restorePlayerAtmo()
end

---The mod changed (or a forced reload): leave the old playable mod, read the new one
local function switchMod(name)
    state.modName = name
    if state.loaded then leavePlayable() end
    local path = resolveModPath(name)
    if path then state.loaded = loadPlayable(path) end
    if state.loaded and state.loaded.dynamics then replayCacheOff() end
end

---------------------------------------------------------------------------------------------------- hooks

---MGE is open: it draws and plays playable mods itself (the same driver.lua), so Atmo Play moves nothing then. A
---mod Atmo Play had loaded before MGE started stays loaded, untouched, until MGE closes (two drivers would move the
---same objects)
---@return boolean
function Runtime.mgeRunning()
    local mge = rawget(_G, "MGE")
    return type(mge) == "table" and mge.running == true
end

---Runs a dynamics.lua call; an error stops the props (proof of concept), not the static pool
local function runDynamics(fn, ws)
    local loaded = state.loaded
    if not (loaded and loaded.dynamics) then return end
    local ok, err = pcall(fn, loaded.dynamics, ws)
    if not ok then
        say("props stopped: " .. tostring(err))
        loaded.driver.moreCenters = nil
        loaded.dynamics = nil
    end
end

local function onMatchBegin()
    debugCall("event", "match_begin")
    if Runtime.mgeRunning() then return end -- MGE plays it (a mod switch is seen after MGE closes)
    local name = get_game_rules().mod
    if name ~= state.modName then switchMod(name) end
    -- a fight: the pool is placed now (recorded under FRAME 0); a replay has it in its own FRAME 0. Props
    -- first: the static pool covers the props they carry
    if state.loaded then
        local ws = get_world_state()
        runDynamics(Dynamics.matchBegin, ws)
        if state.loaded.driver then Driver.matchBegin(state.loaded.driver, ws) end
        -- a replay that opened cached (its mod loaded inside open_replay, after the cache was made)
        if ws.replay_mode > 0 and state.loaded.dynamics and get_replay_cache and (get_replay_cache() or 0) > 0 then
            say("replay opened cached: props may be off, open it again")
        end
    end
    debugCall("flush")
end

---Between physics steps: in a fight, the pools follow the players once per new frame (driver.lua,
---dynamics.lua); in replays the props' drawn copies follow their objects
local function onDraw2d()
    if state.loaded and not Runtime.mgeRunning() then
        local ws = get_world_state()
        debugCall("frame", ws)
        runDynamics(Dynamics.draw, ws)
        if state.loaded.driver then Driver.draw(state.loaded.driver, ws) end
        debugCall("flush")
    end
end

local function onLeaveGame()
    debugCall("event", "leave_game")
    resetPool()
    debugCall("flush")
end

---------------------------------------------------------------------------------------------------- commands

function Runtime.status()
    local loaded = state.loaded
    if not loaded then
        say("running; " .. tostring(state.modName) .. " isn't a playable mod")
        return
    end
    if loaded.drawOnly then
        say(loaded.name .. ": a drawn mod, its atmo " .. (loaded.drawn and "drawn" or "not drawn") .. " (no pools)")
        return
    end
    say(string.format("%s: %d/%d pool objects in use, %d solid atmo objects", loaded.name,
        Driver.active(loaded.driver), #loaded.pool.entries, loaded.stats.collidable))
    if loaded.dynamics then
        local carried, props = Dynamics.counts(loaded.dynamics)
        say(string.format("props: %d of %d carried by %d dynamic pool objects", carried, props,
            #loaded.dynamics.entries))
    end
end

local function onCommand(text)
    local word, rest = tostring(text or ""):match("^%s*(%S+)%s*(.-)%s*$")
    if word ~= "atmoplay" then return end
    if rest == "" or rest == "status" then
        Runtime.status()
    elseif rest == "reload" then
        switchMod(get_game_rules().mod)
        resetPool()
    elseif rest == "log" and NS.DebugLog then
        NS.DebugLog.toggle()
    elseif rest == "quit" then
        if ATMOPLAY and ATMOPLAY.quit then ATMOPLAY.quit() end
    else
        say("/atmoplay [status | reload | quit" .. (NS.DebugLog and " | log" or "") .. "]")
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
    if NS.DebugLog then -- only logged
        add_hook("end_game", Runtime.HOOKS, function() debugCall("event", "end_game") end)
        add_hook("new_game", Runtime.HOOKS, function() debugCall("event", "new_game") end)
    end
    -- "unload" isn't an end: the game fires it when it loads its own scripts too (opening the menu, the
    -- replay save overlay ('f') when the menu isn't loaded), and hooks stay. The game's chat scripts only
    -- rebuild their UI on it. Atmo Play keeps running; /atmoplay quit (or /ls again) stops it
    if NS.DebugLog then add_hook("unload", Runtime.HOOKS, function() debugCall("event", "unload") end) end

    -- the mod that's loaded now
    switchMod(get_game_rules().mod)
    say("running" .. (state.loaded and "" or ": load a playable mod (/lm)") .. ". /atmoplay for status")
end

function Runtime.quit()
    remove_hooks(Runtime.HOOKS)
    debugCall("stop") -- the engine's own setters back
    if state.loaded then
        leavePlayable() -- pool objects stay where they are until the next /lm; the atmo goes back
    end
    unwrapAtmoLoading()
end

NS.Runtime = Runtime
return Runtime
