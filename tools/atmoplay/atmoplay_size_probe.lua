-- In-game probe for the Atmo Play plan (docs/atmo-play-plan.md, R3/R4): can a mod carry a big atmo as
-- "#@ " comment lines, and what does it cost?
-- It writes test mods to data/mod/ and loads each with /lm, one after another:
--   atmoplay_probe_pool.tbm  the pool only: POOL hidden static boxes (the baseline)
--   atmoplay_probe_5k.tbm    the pool + the source atmo as "#@ " lines
--   atmoplay_probe_20k.tbm   the pool + the source atmo 4 times (to find a size limit; last on purpose)
-- For each it records: file size and lines, how long /lm took (os.clock around run_cmd and until
-- match_begin), how many objects exist at match_begin (must be POOL: the "#@ " lines must not become
-- objects), and how long the runtime's own read takes (read the file, collect the "#@ " lines).
-- Then it writes the 5k atmo lines to data/atmospheres/Atmo Play probe.atmo, times Atmospheres.LoadAtmo on
-- it (the per-match_begin cost, R4), loads the player's default atmo again and the mod from before.
-- Run it WITHOUT MGE (MGE reloads on every mod change): /ls mgeDev/tools/atmoplay/atmoplay_size_probe.lua
-- Results go to chat and to data/script/atmoplay_size_probe.log. Dev only: tools/ isn't in the release.

local HOOKS = "atmoplay_size_probe"
remove_hooks(HOOKS)

-- File access goes through the game's Files class (system/iofiles.lua), like MGE's utils/atmo.lua: plain
-- io.open handles in game lack :lines() and failed with "../" paths. A leading "../" starts from the
-- Toribash folder, other paths from data/script
local SOURCE_ATMO = "../data/atmospheres/MGE - dust2-5k.atmo"
local MOD_FOLDER = "../data/mod/"
local ATMO_FOLDER = "../data/atmospheres/"
local CACHE_ATMO = "Atmo Play probe.atmo" -- in ATMO_FOLDER
local LOG_PATH = "atmoplay_size_probe.log" -- data/script
local POOL = 200 -- pool objects, static ids 49-248
local PARK_Z = -100000
local TIMEOUT_FRAMES = 600 -- no match_begin this long after /lm: the load failed, go on
local LATER_FRAMES = 15

---Writes `text` as the whole file (one write)
---@return boolean
local function writeFile(path, text)
    local file = Files.Open(path, FILES_MODE_WRITE)
    if not file.data then return false end
    file:writeLine(text)
    file:close()
    return true
end

writeFile(LOG_PATH, "")
local function say(text)
    echo("^04[probe] " .. text)
    -- reopened per line, so the log survives if a big mod crashes the game
    local file = Files.Open(LOG_PATH, FILES_MODE_APPEND)
    if file.data then
        file:writeLine(text)
        file:close()
    end
end

local clock = os and os.clock or function() return 0 end
local function ms(seconds) return string.format("%.0f ms", seconds * 1000) end

---Reads the whole file and splits it on LF, like Files:readAll
---@return string[]? lines of the file
local function readLines(path)
    local file = Files.Open(path, FILES_MODE_READONLY)
    if not file.data then return nil end
    local text = file:readAll(true) or ""
    file:close()
    local lines = {}
    for line in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if lines[#lines] == "" then table.remove(lines) end
    return lines
end

local function poolText()
    local out = {}
    for i = 1, POOL do
        local id = 48 + i
        out[#out + 1] = "env_obj " .. id
        out[#out + 1] = "    #atmoplay pool"
        out[#out + 1] = "    shape box"
        out[#out + 1] = "    pos " .. id .. " 0 " .. PARK_Z
        out[#out + 1] = "    rot 0 0 0"
        out[#out + 1] = "    sides 1 1 1"
        out[#out + 1] = "    color 1 1 1 1"
        out[#out + 1] = "    flag 8"
        out[#out + 1] = "    visible 0"
        out[#out + 1] = ""
    end
    return out
end

---Writes a test mod: the pool, then `copies` times the atmo as "#@ " lines
---@return integer? bytes nil when the file can't be written
---@return integer? lines
local function writeMod(name, atmoLines, copies)
    local out = poolText()
    if copies > 0 then out[#out + 1] = "#atmoplay v1" end
    for _ = 1, copies do
        for _, line in ipairs(atmoLines) do out[#out + 1] = "#@ " .. line end
    end
    local text = table.concat(out, "\n")
    if not writeFile(MOD_FOLDER .. name .. ".tbm", text) then return nil end
    return #text + 1, #out
end

---The runtime's own read: the "#@ " lines of a mod file, and how many atmo objects they hold
local function runtimeRead(name)
    local start = clock()
    local lines = readLines(MOD_FOLDER .. name .. ".tbm")
    if not lines then return nil end
    local atmo, objects = {}, 0
    for _, line in ipairs(lines) do
        local rest = line:match("^#@ (.*)$")
        if rest then
            atmo[#atmo + 1] = rest
            if rest:match("^%s*env_obj%s") then objects = objects + 1 end
        end
    end
    return clock() - start, atmo, objects
end

local function countObjects()
    local count = 0
    for i = 0, 255 do
        local ok, x = pcall(get_obj_pos, i)
        if ok and x ~= nil then count = count + 1 end
    end
    return count
end

local source = readLines(SOURCE_ATMO)
if not source then
    say("can't read " .. SOURCE_ATMO .. ", set SOURCE_ATMO at the top")
    return
end

local TARGETS = {
    { name = "atmoplay_probe_pool", copies = 0 },
    { name = "atmoplay_probe_5k", copies = 1 },
    { name = "atmoplay_probe_20k", copies = 4 },
}

local before = get_game_rules().mod
local index, state = 0, nil
local cacheLines -- the 5k mod's atmo lines, for the LoadAtmo timing

local function loadAtmoTiming()
    local manager = rawget(_G, "Atmospheres")
    if not cacheLines or type(manager) ~= "table" or type(manager.LoadAtmo) ~= "function" then
        say("LoadAtmo timing skipped: no atmo lines or no Atmospheres manager")
        return
    end
    local start = clock()
    if not writeFile(ATMO_FOLDER .. CACHE_ATMO, table.concat(cacheLines, "\n")) then
        say("can't write " .. ATMO_FOLDER .. CACHE_ATMO)
        return
    end
    local wrote = clock() - start
    start = clock()
    local ok, err = pcall(manager.LoadAtmo, CACHE_ATMO)
    local loaded = clock() - start
    say("")
    say("=== cache atmo: write " .. ms(wrote) .. ", Atmospheres.LoadAtmo " .. ms(loaded) ..
        (ok and "" or (", error: " .. tostring(err))))
    start = clock()
    pcall(manager.LoadAtmo, CACHE_ATMO)
    say("LoadAtmo again (same file)   " .. ms(clock() - start))
    if type(manager.LoadDefaultAtmo) == "function" then
        pcall(manager.LoadDefaultAtmo)
        say("the default atmo (atmo.cfg) is loaded again")
    end
end

local function finish()
    remove_hooks(HOOKS)
    loadAtmoTiming()
    say("done, loading the mod from before: " .. tostring(before))
    run_cmd("lm " .. tostring(before))
end

local function nextTarget()
    index = index + 1
    local target = TARGETS[index]
    if not target then return finish() end
    local bytes, lines = writeMod(target.name, source, target.copies)
    say("")
    if not bytes then
        say("=== can't write " .. MOD_FOLDER .. target.name .. ".tbm, skipped")
        return nextTarget()
    end
    say(string.format("=== /lm %s: %.1f MB, %d lines", target.name, bytes / 1048576, lines))
    local readTime, atmo, objects = runtimeRead(target.name)
    if readTime then
        say("runtime read of #@ lines     " .. ms(readTime) .. ", " .. #atmo .. " lines, " .. objects ..
            " atmo objects")
        if target.copies == 1 then cacheLines = atmo end
    end
    local current = { frames = 0, begun = false, laterIn = LATER_FRAMES, start = clock() }
    state = current
    run_cmd("lm " .. target.name)
    -- match_begin can run inside run_cmd (then /lm is synchronous and this is the whole load)
    say("run_cmd lm returned after    " .. ms(clock() - current.start) ..
        (current.begun and " (match_begin ran inside it)" or " (match_begin not yet)"))
end

add_hook("match_begin", HOOKS, function()
    if not state or state.begun then return end
    state.begun = true
    say("match_begin after            " .. ms(clock() - state.start))
    say("mod gamerule                 " .. tostring(get_game_rules().mod))
    say("objects at match_begin       " .. countObjects() .. " (expected " .. POOL .. ")")
end)

add_hook("draw2d", HOOKS, function()
    if not state then return end
    state.frames = state.frames + 1
    if state.begun then
        state.laterIn = state.laterIn - 1
        if state.laterIn <= 0 then
            say(LATER_FRAMES .. " frames later, objects    " .. countObjects())
            state = nil
            nextTarget()
        end
    elseif state.frames > TIMEOUT_FRAMES then
        say("no match_begin after " .. TIMEOUT_FRAMES .. " frames: the load failed or is still going")
        state = nil
        nextTarget()
    end
end)

say("source atmo: " .. SOURCE_ATMO .. ", " .. #source .. " lines. Mod before: " .. tostring(before))
nextTarget()
