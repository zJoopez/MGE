-- Created by joopez
-- Project: Mod Group Editor v.1.0
-- Built for Toribash v.5.76

-- All shared state lives in MGE (modules register on it), so quitting only clears MGE.

---@class MGE
---@field scriptPath string set by mge.lua
---@field modName string
---@field modPath string?
---@field modFolder string
---@field workPath string the working copy, under data/mod
---@field workSpellings string[] the /lm texts MGE.apply alternates
---@field hookname string
---@field say fun(text: any) chat + footer message
---@field onMessage fun(text: string)? footer flash, set by ui/main.lua
---@field running boolean? startup finished, blocks a second instance
---@field quitting boolean? makes quit run once
---@field cameraChanged boolean? camera set to look-at mode, reset on quit
---@field reloadPending boolean? next match_begin comes from our own apply
---@field keptSelection table<integer, boolean>? selected ids restored after our own apply
---@field focusAfterReload boolean? look at the selection after the reload (asset import)
---@field loadedGamerules table<string, string>? gamerules the mod loaded with, see syncGamerules
---@field onQuit function[] module cleanup callbacks
---@field Main Main ui/main.lua
---@field Editor table ui/editor.lua
---@field Widgets Widgets ui/widgets.lua
---@field WorldSelect WorldSelect utils/world_select.lua
---@field Camera Camera utils/camera.lua
---@field FileHandler table utils/file_handler.lua
---@field ModData ModData utils/mod_export.lua
---@field History History utils/history.lua
---@field Joints Joints utils/joints.lua
---@field Mat3 Mat3 utils/mat3.lua
---@field Transforms table utils/transforms.lua
---@field ShapeGen table utils/shape_gen.lua
---@field Gizmo Gizmo utils/gizmo.lua
---@field AtmoLayer AtmoLayer objects over the game's limit, utils/atmo_layer.lua
---@field Atmo Atmo the atmo layer's file state, utils/atmo.lua
---@field Playable Playable playable atmo mods, utils/playable.lua
---@field AtmoPlay table MGE's own copy of Atmo Play's modules (../atmoplay/)
---@field Players Players start positions (engageplayerpos), utils/players.lua
---@field GizmoMath GizmoMath utils/gizmo_math.lua
---@field Highlight table utils/highlight.lua
---@field EditorRows EditorRows ui/editor_rows.lua
---@field POS_ORIGIN number[] dojo center, set by utils/mod_export.lua
---@field ScrollList ScrollList ui/scroll_list.lua
---@field FLAGS table
---@field SHAPE table get_obj_shape values
---@field MAX_ENV_OBJECTS integer
---@field MAX_NONSTATIC_OBJECTS integer
---@field MAX_ENV_JOINTS integer env_obj_joint ids 1-24
---@field MIN_SIDE number smallest side written, zero sides crash physics
---@field MapConv table map converter, nil until MGE.loadMapConv
---@field loadMapConv fun(): table
---@field isPlacing fun(): boolean
---@field saveOverlay UIElement? ui/save_overlay.lua
---@field confirmOverlay UIElement? opened by MGE.confirm
---@field confirm fun(message: string, onConfirm: fun(), onCancel: fun()?): boolean
---@field saveOverlayContext table? options for the next name prompt
---@field pickerOverlay UIElement? ui/file_picker.lua
---@field colorOverlay UIElement? ui/color_picker.lua
---@field ColorPicker table ui/color_picker.lua
---@field Config table utils/config.lua
---@field settingsOverlay UIElement? ui/settings_overlay.lua
---@field mapOverlay UIElement? ui/map_overlay.lua
---@field MapPlace table? ui/map_place.lua
---@field closeTopOverlay fun(): boolean
---@field overlayOpen fun(): boolean
---@field apply fun() writes and reloads the working copy, not a save
---@field save fun()
---@field renameProject fun()
---@field saveName string? name set on World > Core, until a save or another mod
---@field askExportName fun(title: string, write: fun(name: string))
---@field EXPORT_PREFIX string
---@field DEFAULT_NAME string
---@field setSource fun(path: string?, text: string?)
---@field saveTarget fun(): string
---@field hasUnsavedChanges fun(): boolean
---@field saveFolder string
---@field sourcePath string? file the data belongs to, under data/mod
---@field savedText string? that file's text, for unsaved-changes checks
---@field FilePicker table ui/file_picker.lua
---@field Assets table ui/assets.lua
MGE = MGE or { scriptPath = "mge/" }
MGE.hookname = "mge"
MGE.onQuit = {}

---Chat message, also flashed in the footer (the HUD is off while MGE shows)
---@param text any
function MGE.say(text)
    text = tostring(text)
    echo("^04[MGE] " .. text)
    if MGE.onMessage then pcall(MGE.onMessage, text) end
end
-- The game caches a loaded mod by the text typed after /lm; another spelling of the same file reads it
-- again (tools/reload_probe.lua). So apply alternates two spellings; "//" works on every system
MGE.workPath = "modmaker/mge-work.tbm"
MGE.workSpellings = { "modmaker/mge-work.tbm", "modmaker//mge-work.tbm" }
MGE.modName = get_game_rules().mod
MGE.modPath = find_mod(get_game_rules().mod)
MGE.modFolder = "../data/mod/"

local function loadModule(path)
    return dofile(MGE.scriptPath .. path)
end

---The map placement view hides the window, but its gizmo and camera keep working
---@return boolean
function MGE.isPlacing()
    return MGE.MapPlace ~= nil and MGE.MapPlace.active == true
end

-- map converter: pure Lua, needs mat3 / file_handler / mod_export
local MAPCONV_MODULES = dofile(MGE.scriptPath .. "mapconv/modules.lua")

---Loads the map converter on first use. Throws on a failed module; the next call retries
---@return table MapConv
function MGE.loadMapConv()
    if MGE.MapConv and MGE.MapConv.loaded then return MGE.MapConv end
    MGE.MapConv = nil -- a failed earlier try left it half built
    for _, path in ipairs(MAPCONV_MODULES) do loadModule(path) end
    MGE.MapConv.loaded = true
    return MGE.MapConv
end

runCmd("reset") --Fixes sync if there are unsaved rotations
-- config first: the window needs the UI size
loadModule("utils/config.lua")
MGE.Config.load()
loadModule("utils/mat3.lua")
loadModule("utils/file_handler.lua")
loadModule("utils/mod_export.lua")
loadModule("utils/history.lua")
loadModule("utils/atmo_layer.lua") -- after history
loadModule("utils/atmo.lua")
-- Atmo Play's modules in MGE's own namespace, so a running Atmo Play keeps its own
MGE.AtmoPlay = { scriptPath = MGE.scriptPath .. "../atmoplay/" }
for _, module in ipairs({ "mat3.lua", "format.lua", "colliders.lua", "pool.lua", "driver.lua", "flight.lua", "dynamics.lua" }) do
    ATMOPLAY_LOADING = MGE.AtmoPlay
    local ok, err = pcall(dofile, MGE.AtmoPlay.scriptPath .. module)
    ATMOPLAY_LOADING = nil
    if not ok then error(err, 0) end
end
loadModule("utils/playable.lua") -- after atmo_layer, history and MGE.AtmoPlay
loadModule("utils/joints.lua")
loadModule("utils/highlight.lua")
loadModule("utils/world_select.lua")
loadModule("utils/camera.lua")
loadModule("utils/transforms.lua")
loadModule("utils/shape_gen.lua")
loadModule("utils/players.lua") -- after highlight and history
loadModule("utils/gizmo_math.lua")
loadModule("utils/gizmo.lua") -- after world_select, highlight and transforms
MGE.Config.apply() -- saved settings over the modules' defaults

local FileHandler = MGE.FileHandler
local ModData = MGE.ModData
local History = MGE.History
local Atmo = MGE.Atmo

---The loaded mod's path under data/mod, nil for the built-in classic. The mod gamerule is the /lm text
---with .tbm added ("classic" without .tbm is the built-in one). A file at that path wins; otherwise the
---game searched like find_mod, which ignores the folder, so it's only the fallback (tools/modpath_probe.lua)
---@param name string? the mod gamerule
---@return string?
local function resolveModPath(name)
    name = tostring(name or "")
    if name == "" or not name:match("%.tbm$") then return nil end
    if Files.Exists(MGE.modFolder .. name) then return name end
    return find_mod(name)
end

function MGE.updateSource()
    MGE.modName = get_game_rules().mod
    MGE.modPath = resolveModPath(MGE.modName)
    ModData.reloadObjects()
end

function MGE.loadMod(name)
    runCmd("lm " .. name)
end

---@return table<string, string> gamerule values by name, as the game would write them
local function readGamerules()
    local values = {}
    for name in pairs(get_game_rules()) do
        if name ~= "mod" then values[name] = tostring(get_gamerule(name)) end
    end
    return values
end

function MGE.snapshotGamerules()
    MGE.loadedGamerules = readGamerules()
end

---Puts rules changed in the game's menu into the mod data, so saves keep them. Only changed ones
function MGE.syncGamerules()
    local current = readGamerules()
    local changed, names = {}, {}
    for name, value in pairs(current) do
        if value ~= (MGE.loadedGamerules or {})[name] then
            changed[name] = value
            table.insert(names, name)
        end
    end
    if #names == 0 then return end
    FileHandler.setGamerules(ModData.parsed, changed, current)
    MGE.loadedGamerules = current -- one message per change
    table.sort(names)
    MGE.say("gamerules saved: " .. table.concat(names, ", "))
end

-- Saving: edits go to a working copy the game loads (MGE.apply). Only Save writes the mod, always into
-- data/mod/modmaker/ so other mods are never replaced. Replacing a file that isn't the source asks first.

---@type { path: string, text: string }? the source, kept over a script restart (the working copy doesn't say which mod it is)
MGE_SOURCE = MGE_SOURCE

---@type { objects: fun(): FileParserEnvObj[], state: fun(): table, playable: (fun(): PlayableParams?)? }?
---the atmo layer, kept over a script restart like MGE_SOURCE; functions so they give the old instance's latest
MGE_ATMO = MGE_ATMO

---The mod's atmo: from inside it (playable or drawn mod), else its legacy MGE - <mod>.atmo; and whether it's playable
local function loadSourceAtmo()
    local loaded = ModData.loadedPlayable
    ModData.parsed.playable = loaded and {
        rule = tonumber(loaded.header.rule) or MGE.Playable.DEFAULT_RULE,
        radius = tonumber(loaded.header.radius) or MGE.Playable.DEFAULT_RADIUS,
    } or nil
    MGE.savedPlayable = loaded ~= nil
    Atmo.load(MGE.modPath, loaded and loaded.atmo or ModData.loadedAtmo)
    if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "playable" }) end
end

---@param path string?
---@return boolean
local function isSaveOutput(path)
    local name = tostring(path):gsub("^.*[/\\]", "")
    return name == (MGE.workPath:gsub("^.*[/\\]", ""))
end

---@param path string under data/mod
---@param text string
---@return boolean written
local function writeText(path, text)
    return FileHandler.writeText(MGE.modFolder .. path, text)
end

---Writes the working copy and reloads it, so the game shows the edits
function MGE.apply()
    local spelling = MGE.modName == MGE.workSpellings[1] and MGE.workSpellings[2] or MGE.workSpellings[1]
    MGE.syncGamerules()
    local parsed = ModData.parsedFor(MGE.workPath) -- model paths relative to modmaker/
    if MGE.Playable.isOn() then
        writeText(MGE.workPath, MGE.Playable.workingText(parsed)) -- carries the pool, MGE moves it in fights
    else
        FileHandler.WriteMod(parsed, MGE.modFolder .. MGE.workPath)
    end
    MGE.reloadPending = true -- keeps history and selection over our own reload
    MGE.keptSelection = {}
    for _, obj in ipairs(ModData.parsed.env_obj) do
        if obj.selected then MGE.keptSelection[obj.id] = true end
    end
    for i, obj in ipairs(ModData.parsed.atmo) do -- atmo by list index, negative
        if obj.selected then MGE.keptSelection[-i] = true end
    end
    MGE.loadMod(spelling)
end

---@param path string? under data/mod
---@return string folder "" or "folder/"
---@return string name without .tbm
local function splitModPath(path)
    local folder, file = tostring(path or ""):match("^(.-)([^/\\]*)$")
    return folder or "", ((file or ""):gsub("%.tbm$", ""))
end

MGE.saveFolder = "modmaker/"

-- Save's name without a source (built-in classic)
MGE.DEFAULT_NAME = "mge"

-- Exports are named exp_<name>; project names never start with it, so an export only replaces an export
MGE.EXPORT_PREFIX = "exp_"

---@param name string
---@return string name without EXPORT_PREFIX
function MGE.projectName(name)
    local prefix = MGE.EXPORT_PREFIX
    while name:sub(1, #prefix) == prefix do name = name:sub(#prefix + 1) end
    return name
end

---Where Save writes: the World > Core name, else the source if it's in saveFolder, else a copy there
---@return string
function MGE.saveTarget()
    if MGE.saveName then return MGE.saveFolder .. MGE.saveName .. ".tbm" end
    local path = MGE.sourcePath
    if not path then return MGE.saveFolder .. MGE.DEFAULT_NAME .. ".tbm" end
    local folder, name = splitModPath(path)
    local project = MGE.projectName(name)
    if project == "" then project = MGE.DEFAULT_NAME end
    if folder == MGE.saveFolder and project == name then return path end
    return MGE.saveFolder .. project .. ".tbm"
end

---@return string Save's name without folder and .tbm
function MGE.saveTargetName()
    local _, name = splitModPath(MGE.saveTarget())
    return name
end

---Trimmed, without .tbm and EXPORT_PREFIX
---@param name string
---@return string
function MGE.cleanModName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.tbm$", "")
    return (MGE.projectName(name):gsub("^%s+", ""))
end

---@param name string cleaned (MGE.cleanModName)
---@return boolean ok
---@return string? why not
function MGE.checkModName(name)
    if name:find("[^%w%-_ ]") or not name:find("[%w]") then
        return false, "letters, digits, spaces, dashes and underscores only"
    end
    if (name .. ".tbm"):lower() == (MGE.workPath:gsub("^.*[/\\]", "")):lower() then
        return false, name .. " is MGE's working copy, pick another name"
    end
    return true, nil
end

---Opens the name prompt (ui/save_overlay.lua); onName gets the cleaned, checked name
---@param title string
---@param placeholder string
---@param defaultName string
---@param onName fun(name: string)
local function askName(title, placeholder, defaultName, onName)
    if MGE.overlayOpen() then return end
    MGE.saveOverlayContext = {
        title = title,
        placeholder = placeholder,
        defaultName = defaultName,
        sanitize = MGE.cleanModName,
        validate = MGE.checkModName,
        onSave = function(name)
            onName(name)
            return true -- close the prompt (a confirmation may follow)
        end,
    }
    dofile(MGE.scriptPath .. "ui/save_overlay.lua")
end

---World > Core's Name: Save writes modmaker/<name>.tbm from now on (nothing written yet)
function MGE.renameProject()
    askName("Mod name (" .. MGE.saveFolder .. "<name>)", "Mod name", MGE.saveTargetName(), function(name)
        if name ~= MGE.saveTargetName() then
            MGE.saveName = name
            MGE.say("Save writes " .. MGE.saveTarget() ..
                (Files.Exists(MGE.modFolder .. MGE.saveTarget()) and " (exists: Save asks first)" or ""))
        end
        if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "miscFile" }) end
    end)
end

---The data belongs to path now (loaded or just written) and counts as saved
---@param path string? under data/mod, nil: no file
---@param text string? the file's text, default the current data's
function MGE.setSource(path, text)
    MGE.sourcePath = path
    MGE.savedText = path and (text or FileHandler.modText(ModData.parsed)) or nil
    MGE_SOURCE = path and { path = path, text = MGE.savedText } or nil
end

---@return boolean the data, atmo or playable state differs from the source (always true without one)
function MGE.hasUnsavedChanges()
    return MGE.savedText == nil or MGE.savedText ~= FileHandler.modText(ModData.parsed) or Atmo.hasChanges()
        or (ModData.parsed.playable ~= nil) ~= (MGE.savedPlayable == true)
end

---Writes the mod to path, which becomes the source, then applies
---@param path string
local function writeMod(path)
    MGE.syncGamerules()
    local parsed = ModData.parsedFor(path)
    local text, plan
    if parsed.playable then
        text, plan = MGE.Playable.text(parsed, Atmo.currentText()) -- mod, pool and atmo in one file
    else
        text = Atmo.bundledText(FileHandler.modText(parsed)) -- the mod with its atmo inside
    end
    if not writeText(path, text) then
        MGE.say("couldn't save " .. path)
        return
    end
    MGE.setSource(path)
    MGE.saveName = nil
    MGE.savedPlayable = plan ~= nil
    if plan then
        MGE.say(string.format("saved %s (playable: %d atmo, %d solid, %d pool objects)", path, plan.atmo,
            plan.solid, #plan.objects))
    else
        local count = #(ModData.parsed.atmo or {})
        MGE.say("saved " .. path .. (count > 0 and (" (+" .. count .. " atmo objects)") or ""))
    end
    Atmo.markSaved()
    local warning = MGE.Main and MGE.Main.dynamicWarning()
    if warning then MGE.say("saved with " .. warning) end
    MGE.apply()
end

---World > Export's name prompt: write gets the name with EXPORT_PREFIX. Doesn't rename the project
---@param title string
---@param write fun(name: string) name with the prefix
function MGE.askExportName(title, write)
    askName(title, "File name (" .. MGE.EXPORT_PREFIX .. " is added)", MGE.saveTargetName(), function(name)
        write(MGE.EXPORT_PREFIX .. name)
    end)
end

---World > Export > Mod: the mod without its atmo and pools, as modmaker/exp_<name>.tbm
function MGE.exportCleanMod()
    local function pathOf(name) return MGE.saveFolder .. name .. ".tbm" end
    MGE.askExportName("Export mod without atmo (" .. MGE.saveFolder .. MGE.EXPORT_PREFIX .. "<name>)",
        function(name)
            local path = pathOf(name)
            MGE.syncGamerules()
            if FileHandler.WriteMod(ModData.parsedFor(path), MGE.modFolder .. path) then
                MGE.say("exported " .. path .. ": the mod without its atmo" ..
                    (MGE.Playable.isOn() and " (static objects are in the atmo, not here)" or ""))
            else
                MGE.say("couldn't write " .. path)
            end
        end)
end

---@param path string
---@return boolean writing would replace a file other than the source
local function wouldReplace(path)
    return path ~= MGE.sourcePath and Files.Exists(MGE.modFolder .. path)
end

---@type { confirm: fun(), cancel: fun()?, frame: integer? }? the open confirmation's actions
local confirmActions = nil

---The game's confirmation popup: Continue / Enter confirms, Cancel / Esc cancels. Does nothing while one is open
---@param message string
---@param onConfirm fun()
---@param onCancel fun()?
---@return boolean shown
function MGE.confirm(message, onConfirm, onCancel)
    if MGE.confirmOverlay and not MGE.confirmOverlay.destroyed then return false end
    local actions
    local function finish(action)
        return function()
            if confirmActions == actions then confirmActions = nil end
            MGE.confirmOverlay = nil
            if action then action() end
        end
    end
    -- frame: the Enter that opened it doesn't also confirm it
    actions = { confirm = finish(onConfirm), cancel = finish(onCancel), frame = UIElement and UIElement.frameIndex }
    confirmActions = actions
    MGE.confirmOverlay = TBMenu:showConfirmationWindow(message, actions.confirm, actions.cancel)
    return true
end

---Save / Ctrl + S: writes MGE.saveTarget(), asking first when that replaces a file that isn't the source
function MGE.save()
    local target = MGE.saveTarget()
    if wouldReplace(target) then
        local _, name = splitModPath(target)
        local _, sourceName = splitModPath(MGE.sourcePath)
        -- a loaded export saves over its project, which has the atmo the export lacks
        local fromExport = sourceName ~= MGE.projectName(sourceName)
        MGE.confirm(name .. ".tbm already exists in " .. MGE.saveFolder .. ". Overwrite it?\n" ..
            (fromExport and ("You loaded the export " .. sourceName .. ".tbm: this replaces the project " ..
                "with it.\n") or "") ..
            "(World > Core > Name saves under another name)", function() writeMod(target) end)
    else
        writeMod(target)
    end
end

-- MGE's overlay fields, topmost first (Esc closes in this order). New overlays only need adding here
local OVERLAY_KEYS = { "confirmOverlay", "colorOverlay", "saveOverlay", "pickerOverlay", "settingsOverlay", "mapOverlay" }

---@return string? key its MGE field
---@return UIElement? overlay
local function topOverlay()
    for _, key in ipairs(OVERLAY_KEYS) do
        local overlay = MGE[key]
        if overlay and not overlay.destroyed then return key, overlay end
    end
    return nil, nil
end

---Removes hooks, UI and the MGE global. Safe to call twice and on a partial start
---@param fromWindow boolean? called by the main window's killAction (already closing)
function MGE.quit(fromWindow)
    if MGE.quitting then return end
    MGE.quitting = true

    remove_hooks(MGE.hookname)
    for _, callback in ipairs(MGE.onQuit or {}) do
        pcall(callback)
    end
    for _, key in ipairs(OVERLAY_KEYS) do
        local overlay = MGE[key]
        if overlay and not overlay.destroyed then
            pcall(function() overlay:kill() end)
        end
    end
    local window = MGE.Main and MGE.Main.window
    -- else our inputs stay in toriui's keyboard list
    if window and MGE.Widgets then pcall(MGE.Widgets.releaseKeyboard, window) end
    if not fromWindow and window and not window.destroyed then
        window.killAction = nil
        pcall(function() window:kill() end)
    end
    if MGE.cameraChanged then set_camera_mode(0) end

    MGE.say("closed") -- before MGE goes
    MGE = nil
end

add_hook("match_begin", MGE.hookname, function()
    local path = MGE.modPath
    MGE.updateSource()
    -- switching between the working copy's two spellings isn't a mod switch
    local switchedMod = path ~= MGE.modPath and not (isSaveOutput(path) and isSaveOutput(MGE.modPath))
    if switchedMod then
        set_camera_mode(0)
        MGE.Playable.loadedKey = nil
        -- a real mod file: the data belongs to it now, with its atmo
        if not isSaveOutput(MGE.modPath) then
            MGE.saveName = nil
            MGE.setSource(MGE.modPath)
            loadSourceAtmo()
            Atmo.applyShader()
        end
    end
    -- New baseline on a mod load. Applying rules in the game's menu also starts a match: that one keeps
    -- the old baseline so the change gets saved
    if switchedMod or MGE.reloadPending then MGE.snapshotGamerules() end

    if MGE.reloadPending then
        -- our own apply: same objects, restore selection and list page
        for _, obj in ipairs(ModData.parsed.env_obj) do
            obj.selected = MGE.keptSelection and MGE.keptSelection[obj.id] or nil
        end
        for i, obj in ipairs(ModData.parsed.atmo) do
            obj.selected = MGE.keptSelection and MGE.keptSelection[-i] or nil
        end
        MGE.Main.updateWindow()
        if MGE.focusAfterReload then MGE.Camera.followSelection() end
    else
        -- new mod or game restart: older states no longer match
        History.reset()
        MGE.Main.resetWindow()
    end
    MGE.reloadPending = false
    MGE.keptSelection = nil
    MGE.focusAfterReload = nil
    MGE.AtmoLayer.reapplySeeThrough() -- the reload restored file colors
    MGE.Playable.onMatchBegin()
end)

-- Alt + Q / W / E toggle the gizmo tools. Alt: the game binds Shift on some of these
local TOOL_KEYS = {
    [string.byte("q")] = "move",
    [string.byte("w")] = "rotate",
    [string.byte("e")] = "scale",
}

local KEY_DELETE = 127 -- SDLK_DELETE

-- Ctrl + N / D and Delete: the shown list's New, Duplicate and Delete
---@param action "new"|"duplicate"|"delete"
local function listAction(action)
    local tab, actions = MGE.Main.listTab, nil
    if tab == "misc" then return end
    if tab == "players" then
        local L = MGE.PlayerList
        actions = { new = L.newPlayer, duplicate = L.duplicate, delete = L.deleteSelected }
    elseif tab == "joints" then
        local L = MGE.JointList
        actions = { new = L.newJoint, duplicate = L.duplicate, delete = L.deleteSelected }
    elseif tab == "atmo" then
        actions = { new = MGE.Assets.newAtmo, duplicate = MGE.Editor.duplicate, delete = MGE.Editor.deleteSelected }
    else
        actions = { new = MGE.Assets.newObject, duplicate = MGE.Editor.duplicate, delete = MGE.Editor.deleteSelected }
    end
    actions[action]()
end
local OBJECT_KEYS = {
    [string.byte("n")] = function() listAction("new") end,
    [string.byte("d")] = function() listAction("duplicate") end,
}

---An MGE overlay or a game overlay (TB_MENU_POPUPS_DISABLED) is open: shortcuts wait, gizmo isn't drawn
---@return boolean
local function overlayOpen()
    if topOverlay() then return true end
    return TB_MENU_POPUPS_DISABLED == true
end
MGE.overlayOpen = overlayOpen

local KEY_ESCAPE = 27
local KEY_RETURN, KEY_KEYPAD_ENTER = 13, 271
local escFrame = nil -- frame of the last Esc close

---Esc: closes the topmost overlay, else cancels a pick or the placement view. Esc reaches both the key
---hook and a focused field (Widgets.closeOnEscape), so a second call in the same frame does nothing
---@return boolean handled
function MGE.closeTopOverlay()
    local frame = UIElement and UIElement.frameIndex
    if frame and frame == escFrame then return true end
    local key, overlay = topOverlay()
    if overlay then
        overlay:kill()
        -- kill doesn't call the confirmation's Cancel
        if key == "confirmOverlay" then
            local actions = confirmActions
            MGE.confirmOverlay = nil
            if actions then actions.cancel() end
        end
        escFrame = frame
        return true
    end
    if MGE.WorldSelect and MGE.WorldSelect.cancelPick() then
        MGE.say("pick cancelled")
        escFrame = frame
        return true
    end
    if MGE.isPlacing() then
        MGE.MapPlace.cancel()
        escFrame = frame
        return true
    end
    return false
end

-- Shortcuts: Shift+Z / Y undo / redo (the game owns Ctrl+Z/Y), Ctrl+S save, Ctrl+A select all,
-- Alt+Q/W/E gizmo, Ctrl+N/D new / duplicate, Delete, Esc closes overlays, Enter confirms.
-- Handled keys swallow their key_up too (consumedKeys): the game acts on releases as well
---@type table<integer, boolean>
local consumedKeys = {}
local function onKeyDown(key)
    -- before the text field check: the name prompt focuses its field
    if key == KEY_ESCAPE then
        if MGE.closeTopOverlay() then return 1 end
        return
    end
    if (key == KEY_RETURN or key == KEY_KEYPAD_ENTER) and topOverlay() == "confirmOverlay" then
        local actions = confirmActions
        local frame = UIElement and UIElement.frameIndex
        if actions and not (frame and frame == actions.frame) then
            MGE.confirmOverlay:kill()
            actions.confirm()
        end
        return 1
    end
    if (key == KEY_RETURN or key == KEY_KEYPAD_ENTER) and topOverlay() == "colorOverlay" then
        if MGE.ColorPicker.confirm then MGE.ColorPicker.confirm() end
        return 1
    end
    if TB_MENU_INPUT_ISACTIVE then return end
    local shift, ctrl = get_keyboard_shift() ~= 0, get_keyboard_ctrl() ~= 0
    if get_keyboard_alt() ~= 0 then
        -- also in the placement view (window hidden)
        if not shift and not ctrl and TOOL_KEYS[key] and (MGE.isPlacing() or MGE.Main.window.displayed) then
            MGE.Gizmo.toggle(TOOL_KEYS[key])
            return 1
        end
        return
    end
    if MGE.isPlacing() then return end
    if not MGE.Main.window.displayed then return end
    if key == KEY_DELETE and not shift and not ctrl then
        if not overlayOpen() then listAction("delete") end
        return 1
    elseif ctrl and not shift and OBJECT_KEYS[key] then
        if not overlayOpen() then OBJECT_KEYS[key]() end
        return 1
    end
    if shift and not ctrl then
        if key == string.byte("z") then
            History.undo()
            return 1
        elseif key == string.byte("y") then
            History.redo()
            return 1
        end
    elseif ctrl and not shift and key == string.byte("s") then
        MGE.save()
        return 1
    elseif ctrl and not shift and key == string.byte("a") then
        local tab = MGE.Main.listTab
        if tab == "players" then
            MGE.Main.toggleSelectAllPlayers()
        elseif tab == "joints" then
            MGE.Main.toggleSelectAllJoints()
        elseif tab == "atmo" then
            MGE.Main.toggleSelectAllAtmo()
        elseif tab ~= "misc" then
            MGE.Main.toggleSelectAll()
        end
        return 1
    end
end
add_hook("key_down", MGE.hookname, function(key)
    local result = onKeyDown(key)
    if result == 1 then consumedKeys[key] = true end
    return result
end)

-- The game's HUD is hidden while MGE's window shows. The player's setting is kept in a global so a
-- restart while hidden doesn't take "hidden" as theirs
MGE_HUD_BEFORE = MGE_HUD_BEFORE or get_option("hud")

---@param hidden boolean
function MGE.hideGameHud(hidden)
    set_option("hud", hidden and 0 or (MGE_HUD_BEFORE or 1))
end
table.insert(MGE.onQuit, function()
    MGE.hideGameHud(false)
    MGE_HUD_BEFORE = nil
end)
-- "unload" fires whenever the game loads one of its own scripts (Esc menu, mods window...) and MGE keeps
-- running, so it only re-hides the HUD next frame. Only quit restores it
add_hook("unload", MGE.hookname, function() MGE.hideGameHudNextFrame() end)
local HUD_START_HOOK = MGE.hookname .. "_hudStart"
function MGE.hideGameHudNextFrame()
    add_hook("draw2d", HUD_START_HOOK, function()
        remove_hooks(HUD_START_HOOK)
        if MGE and MGE.Main and MGE.Main.window and MGE.Main.window.displayed then MGE.hideGameHud(true) end
    end)
end
table.insert(MGE.onQuit, function() remove_hooks(HUD_START_HOOK) end)
MGE.hideGameHudNextFrame()

-- The game's Esc menu turns the HUD on; hide it again when the menu closes. Only on that change, so a
-- typed /opt hud 1 stays
local HUD_MENU_HOOK = MGE.hookname .. "_hudMenu"
local menuWasOpen = TB_MENU_MAIN_ISOPEN == 1
add_hook("draw2d", HUD_MENU_HOOK, function()
    local open = TB_MENU_MAIN_ISOPEN == 1
    if menuWasOpen and not open and MGE.Main and MGE.Main.window and MGE.Main.window.displayed then
        MGE.hideGameHud(true)
    end
    menuWasOpen = open
end)
table.insert(MGE.onQuit, function() remove_hooks(HUD_MENU_HOOK) end)

add_hook("key_up", MGE.hookname, function(key)
    if consumedKeys[key] then
        consumedKeys[key] = nil
        return 1
    end
    if key ~= 282 then return end --F1
    if MGE.isPlacing() then return end -- the placement view shows it again when it ends
    local Main = MGE.Main
    -- hidden = play view: objects in their own colors, not see-through
    if Main.window.displayed then
        Main.window:hide(false)
        MGE.hideGameHud(false)
        MGE.AtmoLayer.setObjectsSeeThrough(false)
    else
        Main.window:show(false)
        MGE.hideGameHud(true)
        MGE.AtmoLayer.setObjectsSeeThrough(Main.listTab == "atmo")
        Main.updateWindow()
    end
end)

---start
MGE.updateSource()
MGE.snapshotGamerules()
-- Started on the working copy (script restart after editing): restore the source and atmo from before
if MGE.modPath and not isSaveOutput(MGE.modPath) then
    MGE.setSource(MGE.modPath)
    loadSourceAtmo()
else
    if MGE_SOURCE then MGE.setSource(MGE_SOURCE.path, MGE_SOURCE.text) end
    if MGE_ATMO then
        local ok, objects = pcall(MGE_ATMO.objects)
        local okState, state = pcall(MGE_ATMO.state)
        if ok and type(objects) == "table" then ModData.parsed.atmo = objects end
        if okState and type(state) == "table" then Atmo.state = state end
        local okPlayable, playable = pcall(MGE_ATMO.playable or function() end)
        if okPlayable and type(playable) == "table" then ModData.parsed.playable = playable end
    end
end
-- first undo state after the atmo is read, or undoing to it would empty the atmo
History.reset()
MGE_ATMO = {
    objects = function() return ModData.parsed.atmo end,
    state = function() return Atmo.state end,
    playable = function() return ModData.parsed.playable end,
}
MGE.AtmoLayer.unloadGameAtmo() -- MGE draws the atmo itself
MGE.Playable.onMatchBegin()
-- remember the player's shader, then show the mod's
Atmo.rememberShader()
Atmo.applyShader()
table.insert(MGE.onQuit, function()
    Atmo.applyShader(true)
    MGE_SHADER_BEFORE = nil
end)
loadModule("ui/main.lua")
MGE.running = true -- last, so a failed start isn't treated as running
