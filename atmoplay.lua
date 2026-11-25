-- Atmo Play: makes big atmo maps solid. Load it once (/ls atmoplay/atmoplay.lua), then load playable mods (/lm,
-- made by MGE's World > Playable): their atmo is drawn and pools of hidden objects follow the players. Its window has
-- the options and Quit. Developed in MGE's repo (docs/atmo-play-plan.md).

---@class ATMOPLAY
---@field scriptPath string the modules' folder under data/script
---@field running boolean
---@field Mat3 AtmoPlayMat3
---@field Format AtmoPlayFormat
---@field Colliders AtmoPlayColliders
---@field Pool AtmoPlayPool
---@field Driver AtmoPlayDriverModule
---@field Runtime AtmoPlayRuntime
---@field quit fun()

-- a /ls while it runs restarts it: the old one puts things back and hands on the player's atmo
local playerAtmo = nil
if ATMOPLAY then
    local runtime = ATMOPLAY.Runtime
    if runtime and runtime.playerAtmo then
        local ok, name = pcall(runtime.playerAtmo)
        if ok then playerAtmo = name end
    end
    if ATMOPLAY.quit then pcall(ATMOPLAY.quit) end
end

-- the folder this file is in, under data/script; the modules are in its atmoplay/ subfolder
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

-- modules register on ATMOPLAY_LOADING while they load (MGE loads the same ones into its own table)
local ok, err = pcall(function()
    for _, module in ipairs({ "mat3.lua", "format.lua", "colliders.lua", "pool.lua", "driver.lua", "flight.lua", "dynamics.lua", "drawer.lua", "runtime.lua", "ui.lua" }) do
        ATMOPLAY_LOADING = ATMOPLAY
        dofile(ATMOPLAY.scriptPath .. module)
    end
    -- dev builds only: the release zip has no debuglog.lua
    local file = io.open(ATMOPLAY.scriptPath .. "debuglog.lua", "r")
    if file then
        file:close()
        ATMOPLAY_LOADING = ATMOPLAY
        dofile(ATMOPLAY.scriptPath .. "debuglog.lua")
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
    ATMOPLAY = nil
end

local started, startErr = pcall(ATMOPLAY.Runtime.start, playerAtmo)
if not started then
    echo("^04[Atmo Play] ^07couldn't start: " .. tostring(startErr))
    ATMOPLAY.quit()
    return
end
ATMOPLAY.running = true
