-- Atmo Play: makes big atmo maps solid. Load it once (/ls atmoplay/atmoplay.lua, or the folder it's in),
-- then load playable mods (/lm). Their atmo is drawn and a pool of hidden objects follows the players, in
-- fights and replays. /atmoplay shows the status, /atmoplay quit stops it. Made by MGE (World tab: Playable),
-- developed in MGE's repo: docs/atmo-play-plan.md there.

---@class ATMOPLAY
---@field scriptPath string the modules' folder under data/script ("atmoplay/atmoplay/" released, "mgeDev/atmoplay/",
---"mge/atmoplay/" with MGE)
---@field running boolean
---@field Mat3 AtmoPlayMat3
---@field Format AtmoPlayFormat
---@field Colliders AtmoPlayColliders
---@field Pool AtmoPlayPool
---@field Driver AtmoPlayDriverModule
---@field Runtime AtmoPlayRuntime
---@field quit fun()

-- a /ls while it runs restarts it (also picks up changed code): the old one puts the player's things back
if ATMOPLAY and ATMOPLAY.quit then pcall(ATMOPLAY.quit) end

-- the folder this file is in, under data/script ("atmoplay/" released, "mge/" with MGE, "mgeDev/"); the
-- modules are in its atmoplay/ subfolder
local function isRoot(dir)
    local file = io.open(dir .. "atmoplay/runtime.lua", "r")
    if file then file:close() end
    return file ~= nil
end

local function findRoot()
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local source = (info and info.source or ""):gsub("^@", ""):gsub("\\", "/")
    source = source:match("data/script/(.*)$") or source:gsub("^%./", "")
    local dir = source:match("^(.*)atmoplay%.lua$")
    if dir and isRoot(dir) then return dir end
    for _, name in ipairs(get_folders and get_folders("data/script") or {}) do
        if isRoot(name .. "/") then return name .. "/" end
    end
    return "atmoplay/"
end

ATMOPLAY = { scriptPath = findRoot() .. "atmoplay/", running = false }

-- the modules register on the namespace they're given (ATMOPLAY_LOADING while they load), so MGE can load
-- the same ones into its own table while Atmo Play runs
local ok, err = pcall(function()
    for _, module in ipairs({ "mat3.lua", "format.lua", "colliders.lua", "pool.lua", "driver.lua", "runtime.lua" }) do
        ATMOPLAY_LOADING = ATMOPLAY
        dofile(ATMOPLAY.scriptPath .. module)
    end
end)
ATMOPLAY_LOADING = nil
if not ok then
    echo("^04[Atmo Play] ^07couldn't start: " .. tostring(err))
    ATMOPLAY = nil
    return
end

function ATMOPLAY.quit()
    if not ATMOPLAY then return end
    ATMOPLAY.running = false
    pcall(ATMOPLAY.Runtime.quit)
    echo("^04[Atmo Play] ^07stopped: the player's atmo is back")
    ATMOPLAY = nil
end

local started, startErr = pcall(ATMOPLAY.Runtime.start)
if not started then
    echo("^04[Atmo Play] ^07couldn't start: " .. tostring(startErr))
    ATMOPLAY.quit()
    return
end
ATMOPLAY.running = true
