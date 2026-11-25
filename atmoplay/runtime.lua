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
local Drawer = NS.Drawer

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

---Dev builds only (debuglog.lua's /atmoplay time): told what each drawn frame cost. nil in releases: nothing measured
---@type { frame: fun(poolMs: number, propsMs: number, copiesMs: number), own: fun(ms: number, shapes: integer), stop: fun() }?
Runtime.measure = nil

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

---------------------------------------------------------------------------------------------------- settings

-- The player's settings, kept in atmoplay.cfg next to atmoplay.lua (not in the release zip: an update keeps it).
-- One "key value" a line:
--   flight shapes      how drawn props fly (Dynamics.LEVELS): simple (spheres, cheapest), shapes (their real
--                      shapes), full (real shapes that hit each other: the most work a frame)
--   draw own           who draws the atmo: own (Atmo Play: its plain shapes, only those on screen; drawer.lua),
--                      game (the game's atmo manager draws every one, as before)
--   ghosts on          the flying props' move predictions while a turn waits (Dynamics.drawGhosts): off saves
--                      their work (the prediction runs the props' flights ahead, as much as playing them)
--   farprops move      flying props far from every player: move (all fly) or pause (they wait where they are until
--                      someone comes near, less work)
--   ui on              Atmo Play's window (ui.lua) open when it starts (off: only its small launcher button)
--   uipos 10 120       where the window was dragged to (screen pixels)
Runtime.settings = { flight = Dynamics.DEFAULT_LEVEL, draw = "own", ghosts = true, pauseFar = false, ui = true,
    uiPos = nil }
Runtime.DRAW_MODES = { own = true, game = true }

---@return string the settings file, a data/script path
function Runtime.settingsPath()
    return tostring(NS.scriptPath or "atmoplay/"):gsub("atmoplay/$", "") .. "atmoplay.cfg"
end

function Runtime.loadSettings()
    for _, line in ipairs(readLines(Runtime.settingsPath()) or {}) do
        local key, value = tostring(line):match("^%s*(%S+)%s+(%S+)")
        if key == "flight" then Runtime.settings.flight = Dynamics.level(value) end
        if key == "draw" and Runtime.DRAW_MODES[value] then Runtime.settings.draw = value end
        if key == "ghosts" and (value == "on" or value == "off") then Runtime.settings.ghosts = value == "on" end
        if key == "ui" and (value == "on" or value == "off") then Runtime.settings.ui = value == "on" end
        if key == "farprops" and (value == "move" or value == "pause") then
            Runtime.settings.pauseFar = value == "pause"
        end
        if key == "uipos" then
            local x, y = tostring(line):match("^%s*%S+%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)")
            if x then Runtime.settings.uiPos = { tonumber(x), tonumber(y) } end
        end

    end
end

function Runtime.saveSettings()
    local lines = { "flight " .. Runtime.settings.flight, "draw " .. Runtime.settings.draw,
        "ghosts " .. (Runtime.settings.ghosts and "on" or "off"),
        "farprops " .. (Runtime.settings.pauseFar and "pause" or "move"),
        "ui " .. (Runtime.settings.ui and "on" or "off") }
    local pos = Runtime.settings.uiPos
    if pos then lines[#lines + 1] = string.format("uipos %d %d", pos[1], pos[2]) end
    if not writeLines(Runtime.settingsPath(), lines) then
        say("couldn't save the settings to " .. Runtime.settingsPath())
    end
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
    ---Another atmo (the player's pick, another script) replaced ours: Atmo Play's own drawing of the mod's shapes
    ---stops with it (else they stayed drawn over the new atmo)
    local function replaced()
        if state.drawnByUs then state.drawnByUs = false end
        if state.drawer then
            state.drawer = nil
            local d = state.loaded and state.loaded.dynamics
            if d then d.noCopies, d.holder, d.dirtyAll = false, nil, true end
        end
    end
    m.LoadAtmo = function(filename, ...)
        if not state.ourLoad then
            state.playerAtmo = filename
            replaced()
        end
        return original(filename, ...)
    end
    ATMOPLAY_UNLOAD = ATMOPLAY_UNLOAD or m.Unload
    local originalUnload = ATMOPLAY_UNLOAD
    if originalUnload then
        m.Unload = function(...)
            if not state.ourLoad then replaced() end
            return originalUnload(...)
        end
    end
end

local function unwrapAtmoLoading()
    local m = manager()
    if m and ATMOPLAY_LOADATMO then m.LoadAtmo = ATMOPLAY_LOADATMO end
    if m and ATMOPLAY_UNLOAD then m.Unload = ATMOPLAY_UNLOAD end
    ATMOPLAY_LOADATMO, ATMOPLAY_UNLOAD = nil, nil
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

---Draws a mod's atmo: the drawn part written as the cache atmo and loaded through the game's manager. With
---`draw own` the cache keeps only what the game must draw (and the header: shader lines), Atmo Play draws the
---plain shapes itself (drawer.lua, state.drawer), the props where they are (no copies to move in the game's atmo)
---@param atmoLines string[]
---@param dynamics table? the props (dynamics.lua)
---@return boolean drawn
local function drawModAtmo(atmoLines, dynamics)
    state.drawer = nil
    if not manager() then
        say("the game's atmosphere manager isn't loaded, the atmo isn't drawn")
        return false
    end
    local lines = Format.drawnLines(atmoLines)
    if Runtime.settings.draw == "own" then
        local split = Drawer.split(atmoLines, dynamics and dynamics.byIndex)
        lines = split.gameLines
        state.drawer = Drawer.new(split, dynamics and dynamics.byIndex)
        state.drawer.left = split.game
    end
    if dynamics then
        -- own: no copies in the game's atmo; game: its copies found again (the atmo is loaded again below)
        dynamics.noCopies = state.drawer ~= nil
        dynamics.holder, dynamics.dirtyAll = nil, true
    end
    if not writeLines(Runtime.ATMO_FOLDER .. Runtime.CACHE_ATMO, lines) then
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
    if Runtime.mgeRunning() then return nil end
    -- a drawn mod (MGE's Default): its atmo is only drawn, there are no pools (driver nil: the hooks skip it)
    if Format.isDrawOnly(file.header) then
        local drawn = drawModAtmo(file.atmo)
        return { path = path, name = name, file = file, drawn = drawn, drawOnly = true }
    end
    -- the pool objects that are in the world: one the file names but the world lacks (the file changed since /lm) is
    -- left out, not moved every frame on an id that isn't there
    local missing = 0
    local function present(list)
        local out = {}
        for _, object in ipairs(list) do
            if get_obj_pos(object.id - 1) == nil then missing = missing + 1 else out[#out + 1] = object end
        end
        return out
    end
    local poolObjects, dynamicObjects = present(file.pool), present(file.dynamic)
    local colliders, stats, props = Colliders.build(file.atmo)
    local pool, err = Pool.new(poolObjects, colliders, file.header)
    if not pool then
        say(name .. ": " .. tostring(err))
        return nil
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
    if #props > 0 then
        -- follow: the mod's own dynamic objects push props too. Without a dynamic pool (props that never become
        -- real, or no ids left) they still fly drawn (thrust, hits)
        dynamics = Dynamics.new(dynamicObjects, props, { dradius = file.header.dradius, follow = driver.follow,
            statics = colliders, level = Runtime.settings.flight, noCopies = Runtime.settings.draw == "own",
            pauseFar = Runtime.settings.pauseFar })
        driver.moreCenters = function() return Dynamics.centers(dynamics) end

    end
    local drawn = drawModAtmo(file.atmo, dynamics)

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
end

local function restoreReplayCache()
    if state.cacheBefore == nil then return end
    pcall(set_option, "replaycache", state.cacheBefore)
    state.cacheBefore = nil
end

local function leavePlayable()
    if state.loaded and state.loaded.dynamics then pcall(Dynamics.restoreCopies, state.loaded.dynamics) end
    state.loaded, state.drawer = nil, nil
    if Runtime.measure then Runtime.measure.stop() end -- a measurement doesn't run on into the next mod
    restoreReplayCache()
    restorePlayerAtmo()
end

---A mod file's whole text (nil without one): match_begin compares it with the text last read, so a mod changed and
---loaded again under its name (an MGE edit, a rebuild, "/lm again") is read again. Lua keeps one copy of each string:
---the comparison costs a hash, not a walk through the text
---@param name string? the mod gamerule
---@return string?
local function readRaw(name)
    local path = resolveModPath(name)
    if not path then return nil end
    local file = Files.Open(Runtime.MOD_FOLDER .. path, FILES_MODE_READONLY)
    if not file.data then return nil end
    local raw = file:readAll(true)
    file:close()
    return raw
end

---The mod changed (or a forced reload): leave the old playable mod, read the new one
---@param raw string? its text, if already read (readRaw)
local function switchMod(name, raw)
    state.modName = name
    state.modRaw = raw or readRaw(name)
    if state.loaded then leavePlayable() end
    local path = resolveModPath(name)
    if path then state.loaded = loadPlayable(path) end
    -- the replay cache only misplaces pool objects: without any, nothing to protect
    if state.loaded and state.loaded.dynamics and #state.loaded.dynamics.entries > 0 then replayCacheOff() end
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
    if Runtime.mgeRunning() then
        -- MGE plays it. Forgotten: after MGE closes, the mod is read again (MGE may have changed it, or Atmo Play
        -- started while MGE had it open and never read it)
        state.modName = nil
        return
    end
    local name = get_game_rules().mod
    local raw = readRaw(name)
    if name ~= state.modName or raw ~= state.modRaw then switchMod(name, raw) end
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

-- what the props cost this drawn frame (pre_draw and draw2d both run them), only while Runtime.measure measures
local frameProps, frameCopies = 0, 0

---Dynamics.draw (its cost added to this drawn frame's while measured)
local function drawProps(ws)
    runDynamics(Dynamics.draw, ws)
    if Runtime.measure then
        local d = state.loaded and state.loaded.dynamics
        if d then frameProps, frameCopies = frameProps + (d.lastSimMs or 0), frameCopies + (d.lastCopiesMs or 0) end
    end
end

---pre_draw, before anything is drawn: replays are watched here. The game has moved the pool objects to this frame
---already, and draw3d (where the props and the game's atmo copies are drawn) comes before draw2d: watched in
---draw2d, a prop let go was drawn by nobody for one frame (its object parked, the prop still "carried") and a
---taken one twice. Fights stay in draw2d, between physics steps (the moves are recorded there)
local function onPreDraw()
    if state.loaded and not Runtime.mgeRunning() then
        local ws = get_world_state()
        if ws.replay_mode > 0 then drawProps(ws) end
    end
end

---enter_frame: every physics frame, drawn or not (the probe: draw2d at frame t, then enter_frame at t with the same
---state, then the step to t + 1; a frame the game doesn't draw still has its enter_frame). Replays are watched here
---too, so no let-go or take falls between two drawn frames: each is seen at its own frame, as the fight made it, and
---the drawn flights start exactly as in the fight (watched only when drawn, they started from an older pose and
---drifted: overlaps with the recorded objects, piles flickering while they settled)
local function onEnterFrame()
    if state.loaded and not Runtime.mgeRunning() then
        local ws = get_world_state()
        if ws.replay_mode > 0 then drawProps(ws) end
        -- where the players are this frame, for far props' pauses (fights and replays alike: the same pauses)
        local dynamics = state.loaded.dynamics
        if dynamics and dynamics.pauseFar then runDynamics(Dynamics.sample, ws) end
    end
end

---Between physics steps: in a fight, the pools follow the players once per new frame (driver.lua,
---dynamics.lua); in replays the props' drawn copies follow their objects
local function onDraw2d()
    if state.drawFallback then
        state.drawFallback = nil
        Runtime.settings.draw = "game" -- this session (not saved)
        local loaded = state.loaded
        if loaded and loaded.file then loaded.drawn = drawModAtmo(loaded.file.atmo, loaded.dynamics) end
    end
    if state.loaded and not Runtime.mgeRunning() then
        local ws = get_world_state()
        debugCall("frame", ws)
        drawProps(ws) -- a replay's frame was watched in pre_draw: this only draws the copies
        local measure = Runtime.measure
        local t = measure and os.clock()
        if state.loaded.driver then Driver.draw(state.loaded.driver, ws) end
        if measure then
            measure.frame((os.clock() - t) * 1000, frameProps, frameCopies)
            frameProps, frameCopies = 0, 0
        end
        debugCall("flush")
    end
end

---The game's graphics level (0-2), as the atmo manager reads it for min_level / max_level
local function graphicsLevel()
    local settings = rawget(_G, "Settings")
    if type(settings) == "table" and settings.GetLevel then
        local ok, level = pcall(settings.GetLevel)
        if ok and tonumber(level) then return tonumber(level) end
    end
    return 2
end

---draw3d: Atmo Play's own drawing of the atmo (draw own)
local function onDraw3d()
    -- this frame's view: the ghosts and our atmo drawing skip what's off screen
    local view = (state.drawer or (state.loaded and state.loaded.dynamics)) and Drawer.measureView() or nil
    local drawer = state.drawer
    if drawer and not Runtime.mgeRunning() then
        local t = Runtime.measure and os.clock()
        local ok, drawn = pcall(Drawer.draw, drawer, view, graphicsLevel())
        if not ok then
            -- the game's atmo holds only what it draws: it takes the whole atmo back (in draw2d, not mid-draw)
            say("drawing failed, the game draws the atmo this session: " .. tostring(drawn))
            state.drawer, state.drawFallback = nil, true
        elseif Runtime.measure then
            Runtime.measure.own((os.clock() - t) * 1000, drawn)
        end
    end
    -- the flying props' ghosts while the fight waits for the turn, as the game shows its objects' (either draw mode).
    -- After the atmo: drawn first, a see-through ghost on or in front of its prop hid the prop behind it
    local loaded = state.loaded
    if loaded and loaded.dynamics and Runtime.settings.ghosts and not Runtime.mgeRunning() then
        local onScreen = view and function(x, y, z, r) return Drawer.onScreen(view, x, y, z, r) end or nil
        local ok, err = pcall(Dynamics.drawGhosts, loaded.dynamics, get_world_state(), onScreen)
        if not ok and not state.ghostError then
            state.ghostError = true -- once a session
            say("prop ghosts failed: " .. tostring(err))
        end
    end
end

local function onLeaveGame()
    debugCall("event", "leave_game")
    resetPool()
    debugCall("flush")
end

---------------------------------------------------------------------------------------------------- the player's settings
-- Set from the window (ui.lua), silently: its lit buttons show them. Kept in atmoplay.cfg

---How drawn props fly (Dynamics.LEVELS); a playable mod running takes it from its next fight
---@param level string
function Runtime.setFlight(level)
    level = Dynamics.level(level)
    Runtime.settings.flight = level
    Runtime.saveSettings()
    local loaded = state.loaded
    if loaded and loaded.dynamics then Dynamics.setLevel(loaded.dynamics, level) end
end

---The flying props' move predictions while a turn waits; off frees the prediction's memory at once
---@param on boolean
function Runtime.setGhosts(on)
    Runtime.settings.ghosts = on and true or false
    Runtime.saveSettings()
    local loaded = state.loaded
    if not on and loaded and loaded.dynamics then Dynamics.dropPrediction(loaded.dynamics) end
end

---Flying props far from every player pause (or all move); a playable mod running takes it from its next fight
---@param on boolean
function Runtime.setFarProps(on)
    Runtime.settings.pauseFar = on and true or false
    Runtime.saveSettings()
    local loaded = state.loaded
    if loaded and loaded.dynamics then Dynamics.setPauseFar(loaded.dynamics, Runtime.settings.pauseFar) end
end

---The window open, or hidden behind its launcher button; kept for the next start
---@param open boolean
function Runtime.setWindow(open)
    Runtime.settings.ui = open and true or false
    Runtime.saveSettings()
    if NS.UI then
        if open then NS.UI.show() else NS.UI.hide() end
    end
end

---Where the window was dragged to, kept for the next start
---@param x number
---@param y number
function Runtime.setWindowPos(x, y)
    Runtime.settings.uiPos = { math.floor(x + 0.5), math.floor(y + 0.5) }
    Runtime.saveSettings()
end

---Stops Atmo Play: the player's own atmo back
function Runtime.stop()
    if ATMOPLAY and ATMOPLAY.quit then ATMOPLAY.quit() end
end

---What the dev tools (debuglog.lua: status, /atmoplay reload, draw, time) reach in here
Runtime.dev = {
    state = state,
    reload = function()
        switchMod(get_game_rules().mod)
        resetPool()
    end,
    redraw = function()
        local loaded = state.loaded
        if loaded and loaded.file then loaded.drawn = drawModAtmo(loaded.file.atmo, loaded.dynamics) end
    end,
}

---------------------------------------------------------------------------------------------------- start / quit

---The atmo that's the player's (what Quit gives back): handed on by a restart (atmoplay.lua)
---@return string?
function Runtime.playerAtmo()
    return state.playerAtmo
end

---@param playerAtmo string? a restart's: the player's atmo the old one had (one picked this session isn't in
---atmo.cfg: read from there, a restart and then Quit gave the start's atmo back instead of the player's pick)
function Runtime.start(playerAtmo)
    remove_hooks(Runtime.HOOKS)
    Runtime.loadSettings()
    state.playerAtmo = playerAtmo or defaultAtmo() -- a restart quits first, which gives the player's atmo back
    wrapAtmoLoading()

    add_hook("match_begin", Runtime.HOOKS, onMatchBegin)
    add_hook("pre_draw", Runtime.HOOKS, onPreDraw)
    add_hook("enter_frame", Runtime.HOOKS, onEnterFrame)
    add_hook("draw2d", Runtime.HOOKS, onDraw2d)
    add_hook("draw3d", Runtime.HOOKS, onDraw3d)
    add_hook("leave_game", Runtime.HOOKS, onLeaveGame)
    if NS.DebugLog then -- dev builds: the /atmoplay command (debuglog.lua), and hooks only logged
        add_hook("command", Runtime.HOOKS, NS.DebugLog.command)
        add_hook("end_game", Runtime.HOOKS, function() debugCall("event", "end_game") end)
        add_hook("new_game", Runtime.HOOKS, function() debugCall("event", "new_game") end)
    end
    -- "unload" isn't an end: the game fires it when it loads its own scripts too (opening the menu, the
    -- replay save overlay ('f') when the menu isn't loaded), and hooks stay. The game's chat scripts only
    -- rebuild their UI on it. Atmo Play keeps running; its window's Quit (or /ls again) stops it
    if NS.DebugLog then add_hook("unload", Runtime.HOOKS, function() debugCall("event", "unload") end) end

    -- the mod that's loaded now
    switchMod(get_game_rules().mod)
    if NS.UI then
        if Runtime.settings.ui then NS.UI.show() else NS.UI.hide() end -- hidden by choice: its launcher
    end
end

function Runtime.quit()
    if Runtime.measure then Runtime.measure.stop() end -- the game's UIElement3D.drawVisuals back
    remove_hooks(Runtime.HOOKS)
    debugCall("stop") -- the engine's own setters back
    if state.loaded then
        leavePlayable() -- pool objects stay where they are until the next /lm; the atmo goes back
    end
    unwrapAtmoLoading()
    if NS.UI then NS.UI.close() end
end

---Runs a dev command as if typed (tests; there's none in releases)
---@param text string
function Runtime.command(text)
    if NS.DebugLog then return NS.DebugLog.command(text) end
end

NS.Runtime = Runtime
return Runtime
