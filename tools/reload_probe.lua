-- In-game probe: does /lm of the same mod file load what was just written into it? MGE writes its working copy to
-- two files in turn (mge-modmaker.tbm / mge-modmaker1.tbm, until 2026-11-22) because /lm of the loaded mod's name once didn't show
-- the new file. This checks that, and other spellings of the same file, with a probe mod in data/mod/modmaker/.
-- Each step writes the mod with its one object at z = the step's number, loads it with /lm <spelling> and reads the
-- object's z a few frames after match_begin: z equal to the step = the new file was loaded.
-- Run it WITHOUT MGE: /ls mgeDev/tools/reload_probe.lua (or wherever tools/ is)
-- The results go to chat and to data/script/reload_probe.log. At the end the mod from before is loaded again.
-- Dev only: tools/ isn't in the release zip.

local HOOKS = "mge_reload_probe"
remove_hooks(HOOKS)

local FILE = "mge_reload_probe" -- data/mod/modmaker/<FILE>.tbm
-- the /lm spellings, in order. The first loads the file fresh, every later one reloads the same file
local STEPS = {
    { lm = "modmaker/" .. FILE .. ".tbm", note = "first load" },
    { lm = "modmaker/" .. FILE .. ".tbm", note = "same name again (the case MGE's two files avoid)" },
    { lm = "modmaker/" .. FILE .. ".tbm", note = "same name a third time" },
    { lm = "modmaker/" .. FILE, note = "without .tbm" },
    { lm = "modmaker/" .. FILE:upper() .. ".tbm", note = "other letter case" },
    { lm = "modmaker//" .. FILE .. ".tbm", note = "double slash" },
    { lm = "modmaker/" .. FILE .. ".tbm", note = "back to the first spelling" },
}
local LATER_FRAMES = 10 -- frames after match_begin before reading the object
local TIMEOUT_FRAMES = 300 -- no match_begin this long after /lm: the load did nothing, go on

-- files through the game's Files class (system/iofiles.lua) like MGE: paths from data/script, "../" from the
-- Toribash folder. The game's io.open doesn't reach data/mod
if not Files then require("system.iofiles") end
local LOG = "reload_probe.log"
local MOD = "../data/mod/modmaker/" .. FILE .. ".tbm"

---Appends a line to the log (opened per line: a crash keeps what came before)
---@param text string
local function logLine(text)
    local file = Files.Open(LOG, FILES_MODE_APPEND)
    if file.data then
        file:writeLine(text)
        file:close()
    end
end
do -- a new log each run
    local file = Files.Open(LOG, FILES_MODE_WRITE)
    if file.data then file:close() end
end

local function say(text)
    echo("^04[probe] " .. text)
    logLine(text)
end

---Writes the probe mod: one static box at x 0, y 0, z
---@param z number
---@return boolean written
local function writeMod(z)
    local file = Files.Open(MOD, FILES_MODE_WRITE)
    if not file.data then return false end
    for _, line in ipairs({ "version 15", "env_obj 1", "   shape box", string.format("   pos 0 0 %d", z),
        "   sides 0.5 0.5 0.5", "   color 1 0 0 1", "   flag 8" }) do
        file:writeLine(line)
    end
    file:close()
    return true
end

local before = get_game_rules().mod
local index = 0
local state = nil -- { step, frames, begun, laterIn }
local results = {}

local function finish()
    remove_hooks(HOOKS)
    say("")
    say("=== summary (z = step: loaded the new file)")
    for _, line in ipairs(results) do say(line) end
    say("done, loading the mod from before: " .. tostring(before))
    run_cmd("lm " .. tostring(before))
end

local function nextStep()
    index = index + 1
    local step = STEPS[index]
    if not step then return finish() end
    say("")
    say(string.format("=== step %d: /lm %s (%s)", index, step.lm, step.note))
    if not writeMod(index) then
        say("couldn't write data/mod/modmaker/" .. FILE .. ".tbm, stopping")
        return finish()
    end
    state = { step = step, frames = 0, begun = false }
    run_cmd("lm " .. step.lm)
end

add_hook("match_begin", HOOKS, function()
    if not state or state.begun then return end
    state.begun = true
    say("match_begin after " .. state.frames .. " frames, mod rule " .. string.format("%q", tostring(get_game_rules().mod)))
    state.laterIn = LATER_FRAMES
end)

add_hook("draw2d", HOOKS, function()
    if not state then return end
    state.frames = state.frames + 1
    if state.begun then
        state.laterIn = state.laterIn - 1
        if state.laterIn <= 0 then
            local ok, _, _, z = pcall(get_obj_pos, 0)
            local zText = ok and z and string.format("%.2f", z) or "no object"
            local fresh = ok and z and math.abs(z - index) < 0.5
            say("object z " .. zText .. (fresh and ": the new file" or ": NOT the new file"))
            results[#results + 1] = string.format("%d %-45s z %s %s", index, state.step.lm, zText,
                fresh and "new" or "OLD")
            state = nil
            nextStep()
        end
    elseif state.frames > TIMEOUT_FRAMES then
        say("no match_begin after " .. TIMEOUT_FRAMES .. " frames: /lm did nothing")
        results[#results + 1] = string.format("%d %-45s no match_begin", index, state.step.lm)
        state = nil
        nextStep()
    end
end)

say("mod before: " .. string.format("%q", tostring(before)) .. ", " .. #STEPS .. " steps")
nextStep()
