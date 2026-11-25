-- Dev probe: where a frame's time goes. Load it first, then the script to measure:
--   /ls mgeDev/tools/frame_timing.lua
--   /ls mgeDev/mge.lua          (hooks added after the probe are timed)
-- Every 2 s chat shows the frame time and the biggest costs in ms a frame: each hook (event:set) added after the
-- probe, UI drawing by globalid (UIElement / UIElement3D drawVisuals). /ftime stops it.
if FRAME_TIMING and FRAME_TIMING.stop then FRAME_TIMING.stop() end

local clock = os.clock
local probe = { sums = {}, frames = 0, last = nil, frameSum = 0, started = clock() }
FRAME_TIMING = probe
local HOOKS = "frame_timing"

local function add(name, ms)
    probe.sums[name] = (probe.sums[name] or 0) + ms
end

local function timed(name, fn)
    return function(...)
        local t = clock()
        local a, b, c = fn(...)
        add(name, (clock() - t) * 1000)
        return a, b, c
    end
end

-- hooks added from now on
probe.addHook = add_hook
add_hook = function(event, set, fn)
    if type(fn) == "function" and set ~= HOOKS then fn = timed(event .. ":" .. tostring(set), fn) end
    return probe.addHook(event, set, fn)
end

-- UI drawing, by globalid
local wrapped = {}
for _, cls in ipairs({ "UIElement", "UIElement3D" }) do
    local C = rawget(_G, cls)
    if C and C.drawVisuals then
        local orig = C.drawVisuals
        wrapped[cls] = orig
        C.drawVisuals = function(object, globalid)
            local gid = type(object) == "table" and (object.globalid or globalid) or object
            local t = clock()
            orig(object, globalid)
            add(cls .. " " .. tostring(gid), (clock() - t) * 1000)
        end
    end
end

local function report()
    local n = probe.frames
    if n == 0 then return end
    local list = {}
    for name, ms in pairs(probe.sums) do list[#list + 1] = { name = name, ms = ms / n } end
    table.sort(list, function(a, b) return a.ms > b.ms end)
    local parts = {}
    for i = 1, math.min(6, #list) do parts[#parts + 1] = string.format("%s %.2f", list[i].name, list[i].ms) end
    echo(string.format("^04[ftime] ^07%.1f ms a frame (%.0f fps): %s", probe.frameSum / n, 1000 / (probe.frameSum / n),
        table.concat(parts, ", ")))
    probe.sums, probe.frames, probe.frameSum = {}, 0, 0
end

probe.addHook("draw2d", HOOKS, function()
    local now = clock()
    if probe.last then
        probe.frames = probe.frames + 1
        probe.frameSum = probe.frameSum + (now - probe.last) * 1000
    end
    probe.last = now
    if now - probe.started >= 2 then
        probe.started = now
        report()
    end
end)

function probe.stop()
    remove_hooks(HOOKS)
    if probe.addHook then add_hook = probe.addHook end
    for cls, orig in pairs(wrapped) do rawget(_G, cls).drawVisuals = orig end
    FRAME_TIMING = nil
    echo("^04[ftime] ^07stopped (hooks added meanwhile stay wrapped until their script reloads)")
end

probe.addHook("command", HOOKS, function(text)
    if text == "ftime" then
        probe.stop()
        return 1
    end
end)

echo("^04[ftime] ^07timing: now /ls the script to measure; /ftime stops")
