-- The in-game part (docs/atmo-play-plan.md, part 2): each match_begin checks the loaded mod; a playable mod's atmo
-- is drawn and in fights its pools follow the players (replays replay the recorded moves). Relies on: /lm and
-- open_replay run match_begin with the world present; draw2d changes record under their step (enter_frame's a
-- step late); the game's io.open can't do "../" (files go through Files); a 5k atmo loads in ~0.3 s (only on change)

local NS = ATMOPLAY_LOADING

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
---@field name string
---@field file AtmoPlayModFile
---@field colliders AtmoPlayCollider[]
---@field stats table Colliders.build's
---@field pool AtmoPlayPoolState
---@field driver AtmoPlayDriver
---@field missing integer pool objects not in the world (the file changed since /lm)
---@field dynamics table? nil without props

local state = {
    modName = nil, ---@type string? the mod gamerule last seen
    loaded = nil, ---@type AtmoPlayLoaded?
    drawnByUs = false, -- the cache atmo is loaded
    ourLoad = false, -- Atmospheres.LoadAtmo is Atmo Play's call right now
    playerAtmo = nil, ---@type string? the player's own atmo (what comes back)
    cacheBefore = nil, ---@type number? the player's replaycache while a mod with props has it off
}
Runtime.state = state

---Dev builds only (debuglog.lua's timing); nil in releases
---@type { frame: fun(poolMs: number, propsMs: number), own: fun(ms: number, shapes: integer), stop: fun() }?
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

---@return boolean
local function writeLines(path, lines)
    local file = Files.Open(path, FILES_MODE_WRITE)
    if not file.data then return false end
    file:writeLine(table.concat(lines, "\n"))
    file:close()
    return true
end

---------------------------------------------------------------------------------------------------- settings

-- atmoplay.cfg next to atmoplay.lua, "key value" lines: flight simple|shapes|full, ghosts on|off,
-- farprops move|pause, maxdraws N, ui on|off (window open at start), uipos X Y
Runtime.settings = { flight = Dynamics.DEFAULT_LEVEL, ghosts = true, pauseFar = false, maxDraws = 1000, ui = true,
    uiPos = nil }

---@return string data/script path
function Runtime.settingsPath()
    return tostring(NS.scriptPath or "atmoplay/"):gsub("atmoplay/$", "") .. "atmoplay.cfg"
end

function Runtime.loadSettings()
    for _, line in ipairs(readLines(Runtime.settingsPath()) or {}) do
        local key, value = tostring(line):match("^%s*(%S+)%s+(%S+)")
        if key == "flight" then Runtime.settings.flight = Dynamics.level(value) end
        if key == "ghosts" and (value == "on" or value == "off") then Runtime.settings.ghosts = value == "on" end
        if key == "ui" and (value == "on" or value == "off") then Runtime.settings.ui = value == "on" end
        if key == "maxdraws" and tonumber(value) and tonumber(value) >= 1 then
            Runtime.settings.maxDraws = math.floor(tonumber(value))
        end
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
    local lines = { "flight " .. Runtime.settings.flight,
        "ghosts " .. (Runtime.settings.ghosts and "on" or "off"),
        "farprops " .. (Runtime.settings.pauseFar and "pause" or "move"),
        "maxdraws " .. Runtime.settings.maxDraws, "ui " .. (Runtime.settings.ui and "on" or "off") }
    local pos = Runtime.settings.uiPos
    if pos then lines[#lines + 1] = string.format("uipos %d %d", pos[1], pos[2]) end
    if not writeLines(Runtime.settingsPath(), lines) then
        say("couldn't save the settings to " .. Runtime.settingsPath())
    end
end

---The mod gamerule as a file under data/mod (it keeps the /lm folder; find_mod for others). nil for built-in classic
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

---Loads an atmo through the game's manager as Atmo Play (not remembered as the player's); nil unloads
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

---Remembers the atmos others load (what comes back when a normal mod loads). The originals are kept in globals so a
---restart doesn't wrap the wrapper
local function wrapAtmoLoading()
    local m = manager()
    if not m then return end
    ATMOPLAY_LOADATMO = ATMOPLAY_LOADATMO or m.LoadAtmo
    local original = ATMOPLAY_LOADATMO
    ---Another atmo replaced ours: our own drawing stops with it
    local function replaced()
        if state.drawnByUs then state.drawnByUs = false end
        state.drawer = nil
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

---The player's default atmo: atmo.cfg's first line
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

local function resetPool()
    if state.loaded and state.loaded.driver then Driver.reset(state.loaded.driver) end
end

---The dev debug log's calls (debuglog.lua); nothing in releases
local function debugCall(name, ...)
    local log = NS.DebugLog
    if log then log[name](...) end
end

---------------------------------------------------------------------------------------------------- mods

---Draws a mod's atmo: Atmo Play draws the plain shapes (state.drawer: on screen, nearest first), the game's atmo
---manager the rest (the cache atmo: models, animated shapes, the header)
---@param atmoLines string[]
---@param dynamics table? the props
---@return boolean drawn
local function drawModAtmo(atmoLines, dynamics)
    state.drawer = nil
    if not manager() then
        say("the game's atmosphere manager isn't loaded, the atmo isn't drawn")
        return false
    end
    local split = Drawer.split(atmoLines, dynamics and dynamics.byIndex)
    state.drawer = Drawer.new(split, dynamics and dynamics.byIndex)
    state.drawer.left = split.game
    if not writeLines(Runtime.ATMO_FOLDER .. Runtime.CACHE_ATMO, split.gameLines) then
        say("couldn't write data/atmospheres/" .. Runtime.CACHE_ATMO .. ", the atmo isn't drawn")
        return false
    end
    local drawn = loadAtmo(Runtime.CACHE_ATMO)
    state.drawnByUs = drawn
    return drawn
end

---Reads a playable mod and draws its atmo; nil when it isn't playable
---@return AtmoPlayLoaded?
local function loadPlayable(path)
    local lines = readLines(Runtime.MOD_FOLDER .. path)
    if not lines then return nil end
    local file = Format.read(lines)
    if not file.header then return nil end
    local name = path:match("([^/]+)%.tbm$") or path
    if Runtime.mgeRunning() then return nil end -- MGE plays it itself (two drivers would move the same objects)
    if Format.isDrawOnly(file.header) then
        local drawn = drawModAtmo(file.atmo)
        return { path = path, name = name, file = file, drawn = drawn, drawOnly = true }
    end
    -- pool objects the world lacks (the file changed since /lm) are left out
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
    local driver = Driver.new(pool)
    driver.onDrive = NS.DebugLog and NS.DebugLog.onDrive
    local skip = {} -- the static pool keeps a floor under the mod's own dynamic objects too
    for _, object in ipairs(file.dynamic) do skip[object.id] = true end
    driver.follow = Driver.dynamicIds(skip)
    local dynamics
    if #props > 0 then
        dynamics = Dynamics.new(dynamicObjects, props, { dradius = file.header.dradius, follow = driver.follow,
            statics = colliders, level = Runtime.settings.flight, pauseFar = Runtime.settings.pauseFar })
        driver.moreCenters = function() return Dynamics.centers(dynamics) end
    end
    local drawn = drawModAtmo(file.atmo, dynamics)
    if missing > 0 then
        say(missing .. " pool objects missing: load the mod again (/lm)")
    end
    return { path = path, name = name, file = file, colliders = colliders, stats = stats, pool = pool,
        driver = driver, missing = missing, drawn = drawn, dynamics = dynamics }
end

---Cached replays misplace teleported dynamic objects: a mod with props has the replay cache off while it's loaded
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
    state.loaded, state.drawer = nil, nil
    if Runtime.measure then Runtime.measure.stop() end
    restoreReplayCache()
    restorePlayerAtmo()
end

---A mod file's whole text, compared with the last (interned: cheap) so a changed mod is read again
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

---Leaves the old playable mod, reads the new one
---@param raw string? its text, if already read
local function switchMod(name, raw)
    state.modName = name
    state.modRaw = raw or readRaw(name)
    if state.loaded then leavePlayable() end
    local path = resolveModPath(name)
    if path then state.loaded = loadPlayable(path) end
    if state.loaded and state.loaded.dynamics and #state.loaded.dynamics.entries > 0 then replayCacheOff() end
end

---------------------------------------------------------------------------------------------------- hooks

---MGE plays playable mods itself while it's open: Atmo Play moves nothing then
---@return boolean
function Runtime.mgeRunning()
    local mge = rawget(_G, "MGE")
    return type(mge) == "table" and mge.running == true
end

---Runs a dynamics.lua call; an error stops the props, not the static pool
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
        state.modName = nil -- read again once MGE closes
        return
    end
    local name = get_game_rules().mod
    local raw = readRaw(name)
    if name ~= state.modName or raw ~= state.modRaw then switchMod(name, raw) end
    if state.loaded then
        local ws = get_world_state()
        runDynamics(Dynamics.matchBegin, ws) -- props first: the static pool covers the carried ones
        if state.loaded.driver then Driver.matchBegin(state.loaded.driver, ws) end
        if ws.replay_mode > 0 and state.loaded.dynamics and get_replay_cache and (get_replay_cache() or 0) > 0 then
            say("replay opened cached: props may be off, open it again")
        end
    end
    debugCall("flush")
end

local frameProps = 0 -- what the props cost this drawn frame, while measured

local function drawProps(ws)
    runDynamics(Dynamics.draw, ws)
    if Runtime.measure then
        local d = state.loaded and state.loaded.dynamics
        if d then frameProps = frameProps + (d.lastSimMs or 0) end
    end
end

---pre_draw: replays are watched here (before draw3d draws the props; in draw2d a swap showed one frame late)
local function onPreDraw()
    if state.loaded and not Runtime.mgeRunning() then
        local ws = get_world_state()
        if ws.replay_mode > 0 then drawProps(ws) end
    end
end

---enter_frame, every physics frame drawn or not: replays watched here too (every take and release at its own frame),
---and far props' samples in fights and replays alike
local function onEnterFrame()
    if state.loaded and not Runtime.mgeRunning() then
        local ws = get_world_state()
        if ws.replay_mode > 0 then drawProps(ws) end
        local dynamics = state.loaded.dynamics
        if dynamics and dynamics.pauseFar then runDynamics(Dynamics.sample, ws) end
    end
end

---draw2d, between physics steps: fights move the pools here
local function onDraw2d()
    if state.loaded and not Runtime.mgeRunning() then
        local ws = get_world_state()
        debugCall("frame", ws)
        drawProps(ws)
        local measure = Runtime.measure
        local t = measure and os.clock()
        if state.loaded.driver then Driver.draw(state.loaded.driver, ws) end
        if measure then
            measure.frame((os.clock() - t) * 1000, frameProps)
            frameProps = 0
        end
        debugCall("flush")
    end
end

---The game's graphics level (0-2), as the atmo manager reads it
local function graphicsLevel()
    local settings = rawget(_G, "Settings")
    if type(settings) == "table" and settings.GetLevel then
        local ok, level = pcall(settings.GetLevel)
        if ok and tonumber(level) then return tonumber(level) end
    end
    return 2
end

---draw3d: our own atmo drawing, then the props' ghosts (after it: a see-through ghost drawn first hid its prop)
local function onDraw3d()
    local view = (state.drawer or (state.loaded and state.loaded.dynamics)) and Drawer.measureView() or nil
    local drawer = state.drawer
    if drawer and not Runtime.mgeRunning() then
        local t = Runtime.measure and os.clock()
        local ok, drawn = pcall(Drawer.draw, drawer, view, graphicsLevel(), Runtime.settings.maxDraws)
        if not ok then
            if not state.drawError then -- once a session; it tries again every frame
                state.drawError = true
                say("drawing failed: " .. tostring(drawn))
            end
        elseif Runtime.measure then
            Runtime.measure.own((os.clock() - t) * 1000, drawn)
        end
    end
    local loaded = state.loaded
    if loaded and loaded.dynamics and Runtime.settings.ghosts and not Runtime.mgeRunning() then
        local onScreen = view and function(x, y, z, r) return Drawer.onScreen(view, x, y, z, r) end or nil
        local ok, err = pcall(Dynamics.drawGhosts, loaded.dynamics, get_world_state(), onScreen)
        if not ok and not state.ghostError then
            state.ghostError = true
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
-- Set from the window (ui.lua), silently, and kept in atmoplay.cfg

---Detail; a running mod takes it from its next fight
function Runtime.setFlight(level)
    level = Dynamics.level(level)
    Runtime.settings.flight = level
    Runtime.saveSettings()
    local loaded = state.loaded
    if loaded and loaded.dynamics then Dynamics.setLevel(loaded.dynamics, level) end
end

---Ghosts; off frees the predictions at once
function Runtime.setGhosts(on)
    Runtime.settings.ghosts = on and true or false
    Runtime.saveSettings()
    local loaded = state.loaded
    if not on and loaded and loaded.dynamics then Dynamics.dropPrediction(loaded.dynamics) end
end

---At most this many atmo shapes drawn a frame, the nearest; from the next frame
function Runtime.setMaxDraws(n)
    Runtime.settings.maxDraws = math.max(1, math.floor(tonumber(n) or 1000))
    Runtime.saveSettings()
end

---Distant (far props) pause; a running mod takes it from its next fight
function Runtime.setFarProps(on)
    Runtime.settings.pauseFar = on and true or false
    Runtime.saveSettings()
    local loaded = state.loaded
    if loaded and loaded.dynamics then Dynamics.setPauseFar(loaded.dynamics, Runtime.settings.pauseFar) end
end

---The window open, or hidden behind its launcher
function Runtime.setWindow(open)
    Runtime.settings.ui = open and true or false
    Runtime.saveSettings()
    if NS.UI then
        if open then NS.UI.show() else NS.UI.hide() end
    end
end

function Runtime.setWindowPos(x, y)
    Runtime.settings.uiPos = { math.floor(x + 0.5), math.floor(y + 0.5) }
    Runtime.saveSettings()
end

---Stops Atmo Play: the player's own atmo back
function Runtime.stop()
    if ATMOPLAY and ATMOPLAY.quit then ATMOPLAY.quit() end
end

---What the dev tools (debuglog.lua) reach in here
Runtime.dev = {
    state = state,
    reload = function()
        switchMod(get_game_rules().mod)
        resetPool()
    end,
}

---------------------------------------------------------------------------------------------------- start / quit

---The player's atmo (handed on by a restart: one picked this session isn't in atmo.cfg)
---@return string?
function Runtime.playerAtmo()
    return state.playerAtmo
end

---@param playerAtmo string? a restart's
function Runtime.start(playerAtmo)
    remove_hooks(Runtime.HOOKS)
    Runtime.loadSettings()
    state.playerAtmo = playerAtmo or defaultAtmo()
    wrapAtmoLoading()

    add_hook("match_begin", Runtime.HOOKS, onMatchBegin)
    add_hook("pre_draw", Runtime.HOOKS, onPreDraw)
    add_hook("enter_frame", Runtime.HOOKS, onEnterFrame)
    add_hook("draw2d", Runtime.HOOKS, onDraw2d)
    add_hook("draw3d", Runtime.HOOKS, onDraw3d)
    add_hook("leave_game", Runtime.HOOKS, onLeaveGame)
    if NS.DebugLog then -- dev builds: the /atmoplay command, and hooks only logged
        add_hook("command", Runtime.HOOKS, NS.DebugLog.command)
        add_hook("end_game", Runtime.HOOKS, function() debugCall("event", "end_game") end)
        add_hook("new_game", Runtime.HOOKS, function() debugCall("event", "new_game") end)
        -- "unload" isn't an end: the game fires it when it loads its own scripts (the menu) too
        add_hook("unload", Runtime.HOOKS, function() debugCall("event", "unload") end)
    end

    switchMod(get_game_rules().mod)
    if NS.UI then
        if Runtime.settings.ui then NS.UI.show() else NS.UI.hide() end
    end
end

function Runtime.quit()
    if Runtime.measure then Runtime.measure.stop() end
    remove_hooks(Runtime.HOOKS)
    debugCall("stop")
    if state.loaded then
        leavePlayable() -- pool objects stay until the next /lm; the atmo goes back
    end
    unwrapAtmoLoading()
    if NS.UI then NS.UI.close() end
end

---Runs a dev command as if typed (tests; none in releases)
function Runtime.command(text)
    if NS.DebugLog then return NS.DebugLog.command(text) end
end

NS.Runtime = Runtime
return Runtime
