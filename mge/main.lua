-- Created by joopez
-- Project: Mod Group Editor v.1.0
-- Built for Toribash v.5.76

-- Everything the script shares lives in the MGE table (modules register themselves on it),
-- so quitting only needs to clear MGE.

---@class MGE
---@field scriptPath string set by mge.lua
---@field modName string
---@field modPath string?
---@field modFolder string
---@field workPath string the working copy, under data/mod
---@field workSpellings string[] the /lm texts MGE.apply takes turns with
---@field hookname string
---@field say fun(text: any) a message: chat and the footer (MGE.onMessage)
---@field onMessage fun(text: string)? set by ui/main.lua: flashes it in the footer
---@field running boolean? true once startup finished, blocks starting a second instance
---@field quitting boolean? set while quitting, makes quit run once
---@field cameraChanged boolean? camera was switched to look-at mode, reset on quit
---@field reloadPending boolean? next match_begin comes from our own save
---@field keptSelection table<integer, boolean>? selected object ids restored after our own save
---@field focusAfterReload boolean? look at the selection after our own save reloads (asset import)
---@field loadedGamerules table<string, string>? gamerules when the mod file was loaded, see syncGamerules
---@field onQuit function[] cleanup callbacks registered by modules, run on quit
---@field Main Main main window, set by ui/main.lua
---@field Editor table editor panels and duplicate/delete, set by ui/editor.lua
---@field Widgets Widgets shared button helpers, ui/widgets.lua
---@field WorldSelect WorldSelect click objects in the world to select them, utils/world_select.lua
---@field Camera Camera frames objects on screen, utils/camera.lua
---@field FileHandler table utils/file_handler.lua
---@field ModData ModData utils/mod_export.lua
---@field History History utils/history.lua
---@field Joints Joints utils/joints.lua
---@field Mat3 Mat3 utils/mat3.lua
---@field Transforms table move / rotate / scale for the selection, utils/transforms.lua
---@field ShapeGen table Generate tab geometry, utils/shape_gen.lua
---@field Gizmo Gizmo drag handles in the world, utils/gizmo.lua
---@field AtmoLayer AtmoLayer objects over the game's limit (the atmo layer), utils/atmo_layer.lua
---@field Atmo Atmo the atmo layer's .atmo file per mod, utils/atmo.lua
---@field Playable Playable playable atmo mods for the Atmo Play script (World tab Convert, Save), utils/playable.lua
---@field AtmoPlay table Atmo Play's modules (../atmoplay/: Mat3, Format, Colliders, Pool), MGE's own copy of them
---@field Players Players players' start positions and rotations (engageplayerpos), utils/players.lua
---@field GizmoMath GizmoMath utils/gizmo_math.lua
---@field Highlight table selection highlight and generate preview, utils/highlight.lua
---@field EditorRows EditorRows shared editor row widgets, ui/editor_rows.lua
---@field POS_ORIGIN number[] dojo center, set by utils/mod_export.lua
---@field ScrollList ScrollList ui/scroll_list.lua
---@field FLAGS table
---@field SHAPE table get_obj_shape values
---@field MAX_ENV_OBJECTS integer
---@field MAX_NONSTATIC_OBJECTS integer
---@field MAX_ENV_JOINTS integer env_obj_joint ids 1-24
---@field MIN_SIDE number smallest object side written, zero sides crash physics
---@field MapConv table map converter (mapconv/*.lua), nil in game until MGE.loadMapConv: Advanced tab's Map row
---@field loadMapConv fun(): table loads the map converter the first time it's needed, returns MGE.MapConv
---@field isPlacing fun(): boolean the map placement view is open (it hides the window, gizmo and camera keep working)
---@field saveOverlay UIElement? open name prompt (ui/save_overlay.lua)
---@field confirmOverlay UIElement? open confirmation popup (TBMenu:showConfirmationWindow, opened by MGE.confirm)
---@field confirm fun(message: string, onConfirm: fun(), onCancel: fun()?): boolean asks first, Enter confirms, Esc cancels
---@field saveOverlayContext table? options for the next name prompt
---@field pickerOverlay UIElement? open file picker: asset import, Model row (ui/file_picker.lua)
---@field colorOverlay UIElement? open color picker: the Core tab's Color name (ui/color_picker.lua)
---@field ColorPicker table ui/color_picker.lua
---@field Config table utils/config.lua: settings and palette kept in config.cfg
---@field settingsOverlay UIElement? open settings: camera follow, world clicking (ui/settings_overlay.lua)
---@field mapOverlay UIElement? open Convert Map overlay (ui/map_overlay.lua)
---@field MapPlace table? map placement view (ui/map_place.lua), loaded by the overlay's Place button
---@field closeTopOverlay fun(): boolean Esc: closes the topmost of the overlays above
---@field overlayOpen fun(): boolean one of the overlays above, or a game overlay, is open
---@field apply fun() writes the working copy and reloads it (shows edits), not a save of the mod
---@field save fun() Save button / Ctrl + S: writes the mod to saveTarget()
---@field renameProject fun() World > Core's Name: asks where Save writes from now on
---@field saveName string? the name set there, until a save or another mod
---@field askExportName fun(title: string, write: fun(name: string)) World > Export's name prompt
---@field EXPORT_PREFIX string every export's name starts with it ("exp_")
---@field DEFAULT_NAME string Save's name without a source ("mge")
---@field setSource fun(path: string?, text: string?) the data belongs to that file now
---@field saveTarget fun(): string where Save writes, under data/mod, always in saveFolder
---@field hasUnsavedChanges fun(): boolean
---@field saveFolder string Save only writes here (under data/mod), "modmaker/" like the game's modmaker
---@field sourcePath string? file the data belongs to (loaded or last written), path under data/mod
---@field savedText string? that file's text, compared for unsaved changes
---@field FilePicker table ui/file_picker.lua
---@field Assets table export / import, ui/assets.lua
MGE = MGE or { scriptPath = "mge/" }
MGE.hookname = "mge"
MGE.onQuit = {}

---A message for the player: in chat (seen with the game's HUD on, and in chat logs) and flashed in the
---footer's middle (ui/main.lua: MGE.onMessage), the HUD is off while MGE's window shows
---@param text any
function MGE.say(text)
    text = tostring(text)
    echo("^04[MGE] " .. text)
    if MGE.onMessage then pcall(MGE.onMessage, text) end
end
-- the working copy (MGE.apply): one file next to the user's mods. The game keeps the loaded mod by the text typed
-- after /lm: the same text again (with or without .tbm) gives the old file, any other spelling reads it again
-- (tools/reload_probe.lua, 2026-11-22: letter case, a double slash, and the first text again once another came
-- between). So apply takes turns with two spellings of the one file; "//" is the same file on every system
MGE.workPath = "modmaker/mge-work.tbm"
MGE.workSpellings = { "modmaker/mge-work.tbm", "modmaker//mge-work.tbm" }
MGE.modName = get_game_rules().mod
MGE.modPath = find_mod(get_game_rules().mod)
MGE.modFolder = "../data/mod/"

local function loadModule(path)
    return dofile(MGE.scriptPath .. path)
end

---True while the map placement view (ui/map_place.lua) is open: it hides MGE's window, but its gizmo,
---the camera and its own drawing keep working
---@return boolean
function MGE.isPlacing()
    return MGE.MapPlace ~= nil and MGE.MapPlace.active == true
end

-- map converter, pure Lua (the tests run it outside the game). Needs mat3 / file_handler / mod_export
local MAPCONV_MODULES = dofile(MGE.scriptPath .. "mapconv/modules.lua")

---Loads the map converter the first time it's needed (Advanced tab > Map), not at startup: the rest of
---MGE starts faster and doesn't depend on it. Throws when a module fails to load, the next call tries again
---@return table MapConv
function MGE.loadMapConv()
    if MGE.MapConv and MGE.MapConv.loaded then return MGE.MapConv end
    MGE.MapConv = nil -- a failed earlier try left it half built
    for _, path in ipairs(MAPCONV_MODULES) do loadModule(path) end
    MGE.MapConv.loaded = true
    return MGE.MapConv
end

runCmd("reset") --Fixes sync if there are unsaved rotations
-- the config file first: the UI size is needed before the window is built, the rest is applied below
loadModule("utils/config.lua")
MGE.Config.load()
loadModule("utils/mat3.lua")
loadModule("utils/file_handler.lua")
loadModule("utils/mod_export.lua")
loadModule("utils/history.lua")
loadModule("utils/atmo_layer.lua") -- objects over the game's limit, after history
loadModule("utils/atmo.lua") -- the atmo layer's .atmo file per mod
-- Atmo Play's modules (../atmoplay/, next to mge/: the player script for playable atmo mods), loaded into
-- MGE's own namespace (ATMOPLAY_LOADING while one loads), so Atmo Play running at the same time keeps its own.
-- MGE writes playable mods with them and the player script reads them with the same code
MGE.AtmoPlay = { scriptPath = MGE.scriptPath .. "../atmoplay/" }
for _, module in ipairs({ "mat3.lua", "format.lua", "colliders.lua", "pool.lua", "driver.lua", "dynamics.lua" }) do
    ATMOPLAY_LOADING = MGE.AtmoPlay
    local ok, err = pcall(dofile, MGE.AtmoPlay.scriptPath .. module)
    ATMOPLAY_LOADING = nil
    if not ok then error(err, 0) end
end
loadModule("utils/playable.lua") -- playable atmo mods (Atmo Play): after atmo_layer, history and MGE.AtmoPlay
loadModule("utils/joints.lua")
loadModule("utils/highlight.lua")
loadModule("utils/world_select.lua")
loadModule("utils/camera.lua")
loadModule("utils/transforms.lua")
loadModule("utils/shape_gen.lua")
loadModule("utils/players.lua") -- players' start positions (engageplayerpos), after highlight and history
loadModule("utils/gizmo_math.lua")
loadModule("utils/gizmo.lua") -- after world_select, highlight and transforms
MGE.Config.apply() -- the saved settings over the modules' defaults

local FileHandler = MGE.FileHandler
local ModData = MGE.ModData
local History = MGE.History
local Atmo = MGE.Atmo

---The loaded mod's path under data/mod, nil for the game's built-in classic (no file). The mod gamerule is
---the path the game loaded, as typed after /lm with .tbm added, measured in game (mge/tools/modpath_probe.lua):
---  /lm modmaker/katana -> "modmaker/katana.tbm"     /lm katana -> "katana.tbm"
---  /lm classic         -> "classic" (no .tbm: the built-in mod, also with classic.tbm files around)
---With a file at that path under data/mod it's that one (a bare "modmaker.tbm" is data/mod/modmaker.tbm,
---the game's modmaker's file), otherwise the game searched the folders like find_mod does (katana.tbm:
---Combat/Weapons/katana.tbm). find_mod ignores the folder: it gave Combat/Weapons/katana.tbm for
---modmaker/katana.tbm and downloads/classic.tbm for modmaker/classic.tbm, so it's only the fallback
---@param name string? the mod gamerule
---@return string?
local function resolveModPath(name)
    name = tostring(name or "")
    if name == "" or not name:match("%.tbm$") then return nil end -- the built-in classic (or nothing)
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

---@return table<string, string> current gamerule values by name, as the game would write them
local function readGamerules()
    local values = {}
    for name in pairs(get_game_rules()) do
        if name ~= "mod" then values[name] = tostring(get_gamerule(name)) end -- mod is the file itself
    end
    return values
end

---Remembers the gamerules a mod file loaded with, later differences were made in the game's menu
function MGE.snapshotGamerules()
    MGE.loadedGamerules = readGamerules()
end

---Puts gamerules changed in the game's menu (Rules button) into the mod data, so saves keep them.
---Only changed rules are written, rules the mod leaves at their default stay out of the file
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
    table.sort(names)
    MGE.say("gamerules saved: " .. table.concat(names, ", "))
end

-- Saving. Edits are applied to a working copy that the game loads (MGE.apply: modmaker/mge-work.tbm,
-- loaded with two spellings in turn so lm reads it again), many edits do that to show their result. The
-- mod itself is only written by Save, always into data/mod/modmaker/ (MGE.saveFolder) so
-- other mods are never replaced.
--   MGE.sourcePath: the file the data belongs to, the loaded mod or the last one written
--   MGE.savedText:  that file's text, the footer compares it with the data for "unsaved changes"
--   Save (MGE.save, Ctrl + S): writes MGE.saveTarget(): the name typed on World > Core (MGE.saveName), else
--                   the source itself when it's in modmaker/, otherwise a copy there with its name, and
--                   modmaker/mge.tbm without a source (the classic mod). Always possible: replacing a file
--                   that isn't ours asks first. The written file becomes the source
-- A file counts as ours (overwritten without asking) only when it's the source.

---@type { path: string, text: string }? the source, kept over a script restart (MGE is rebuilt, this
---isn't): the working copy loaded then doesn't say which mod it is
MGE_SOURCE = MGE_SOURCE

---@type { objects: fun(): FileParserEnvObj[], state: fun(): table, playable: (fun(): PlayableParams?)? }? the atmo layer and its file's state
---(utils/atmo.lua), kept over a script restart like MGE_SOURCE: the working copy doesn't carry the layer.
---Functions over the old instance's data, so they give its latest, however that instance ended
MGE_ATMO = MGE_ATMO

---The opened mod's atmo: from inside it (a playable mod, utils/playable.lua, or a drawn one, Default's Save: both
---read by ModData.reloadObjects), otherwise from its MGE - <mod>.atmo (mods saved before atmos went inside them);
---and whether it's playable
local function loadSourceAtmo()
    local loaded = ModData.loadedPlayable
    ModData.parsed.playable = loaded and {
        rule = tonumber(loaded.header.rule) or MGE.Playable.DEFAULT_RULE,
        radius = tonumber(loaded.header.radius) or MGE.Playable.DEFAULT_RADIUS,
    } or nil
    MGE.savedPlayable = loaded ~= nil -- the file as it is: playable or not
    Atmo.load(MGE.modPath, loaded and loaded.atmo or ModData.loadedAtmo)
    if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "playable" }) end -- the World tab's Atmo row (Playable / Default)
end

---@param path string?
---@return boolean
local function isSaveOutput(path)
    local name = tostring(path):gsub("^.*[/\\]", "")
    return name == (MGE.workPath:gsub("^.*[/\\]", ""))
end

---Writes the working copy and reloads it, so the game shows the edits. Not a save of the mod (MGE.save)
function MGE.apply()
    -- the other spelling than the loaded one: /lm reads the file again (MGE.workSpellings)
    local spelling = MGE.modName == MGE.workSpellings[1] and MGE.workSpellings[2] or MGE.workSpellings[1]
    MGE.syncGamerules()
    local parsed = ModData.parsedFor(MGE.workPath) -- models from modmaker/ (the data has them for data/mod)
    if MGE.Playable.isOn() then
        -- a playable mod: the working copy carries the pool, MGE moves it in fights (utils/playable.lua)
        local file = Files.Open(MGE.modFolder .. MGE.workPath, FILES_MODE_WRITE)
        if file and file.data then
            file:writeLine(MGE.Playable.workingText(parsed))
            file:close()
        end
    else
        FileHandler.WriteMod(parsed, MGE.modFolder .. MGE.workPath)
    end
    MGE.reloadPending = true -- keeps undo history and selection over the reload caused by our own save
    MGE.keptSelection = {}
    for _, obj in ipairs(ModData.parsed.env_obj) do
        if obj.selected then MGE.keptSelection[obj.id] = true end
    end
    for i, obj in ipairs(ModData.parsed.atmo) do -- atmo objects by their place in the list, negative
        if obj.selected then MGE.keptSelection[-i] = true end
    end
    MGE.loadMod(spelling)
end

---Folder part of a path under data/mod ("" or "folder/") and the file name without .tbm
---@param path string?
---@return string folder, string name
local function splitModPath(path)
    local folder, file = tostring(path or ""):match("^(.-)([^/\\]*)$")
    return folder or "", ((file or ""):gsub("%.tbm$", ""))
end

-- Save only writes into data/mod/modmaker/, like the game's own modmaker: mods elsewhere (the game's,
-- downloaded ones) are never replaced, saving one makes a copy there
MGE.saveFolder = "modmaker/"

-- Save's name without a source (the built-in classic mod): saving is always possible, and the exports have a name
MGE.DEFAULT_NAME = "mge"

-- every export's name starts with it (World > Export: exp_<name>.tbm, MGE - exp_<name>.atmo), and a project's name
-- never does (MGE.projectName): an export only ever replaces an earlier export, so it overwrites without asking
MGE.EXPORT_PREFIX = "exp_"

---A name as a project's: without EXPORT_PREFIX at its start (a loaded export saves as <name>.tbm)
---@param name string
---@return string
function MGE.projectName(name)
    local prefix = MGE.EXPORT_PREFIX
    while name:sub(1, #prefix) == prefix do name = name:sub(#prefix + 1) end
    return name
end

---Where Save writes: the name set on World > Core, else the source itself when it's in the save folder, otherwise
---a file with its name there; modmaker/mge.tbm without a source. Never an export's name (MGE.projectName)
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

---The name Save writes (World > Core's Name), without folder and .tbm
---@return string
function MGE.saveTargetName()
    local _, name = splitModPath(MGE.saveTarget())
    return name
end

---A typed name as the name prompts take it: no spaces around it, no .tbm, no EXPORT_PREFIX (exports add it)
---@param name string
---@return string
function MGE.cleanModName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.tbm$", "")
    return (MGE.projectName(name):gsub("^%s+", ""))
end

---Checks a cleaned name (MGE.cleanModName): letters, digits, spaces, dashes and underscores, at least one letter
---or digit
---@param name string
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

---Opens the name prompt (ui/save_overlay.lua) shared by the project's name and World > Export: typed names are
---cleaned (MGE.cleanModName) and checked (MGE.checkModName) there, onName gets the result
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
            return true -- the prompt closes (a confirmation may follow)
        end,
    }
    dofile(MGE.scriptPath .. "ui/save_overlay.lua")
end

---World > Core's Name: asks the project's name, Save writes modmaker/<name>.tbm from then on (nothing is written
---yet). Loading another mod drops it
function MGE.renameProject()
    askName("Mod name (" .. MGE.saveFolder .. "<name>)", "Mod name", MGE.saveTargetName(), function(name)
        if name ~= MGE.saveTargetName() then
            MGE.saveName = name
            MGE.say("Save writes " .. MGE.saveTarget() ..
                (Files.Exists(MGE.modFolder .. MGE.saveTarget()) and " (it exists: Save asks before replacing it)" or ""))
        end
        if MGE.EditorRows then MGE.EditorRows.refreshBlocks({ "miscFile" }) end -- the Name row shows it
    end)
end

---The data belongs to the file at path now (loaded, or just written): Save goes there (or to its copy
---in modmaker/), and the data counts as saved
---@param path string? under data/mod, nil: no file (Save writes MGE.DEFAULT_NAME)
---@param text string? the file's text, default the current data's
function MGE.setSource(path, text)
    MGE.sourcePath = path
    MGE.savedText = path and (text or FileHandler.modText(ModData.parsed)) or nil
    MGE_SOURCE = path and { path = path, text = MGE.savedText } or nil -- global: kept over a script restart
end

---True when the data differs from the source file (always, without one), or the atmo layer from its
---.atmo file
---@return boolean
function MGE.hasUnsavedChanges()
    return MGE.savedText == nil or MGE.savedText ~= FileHandler.modText(ModData.parsed) or Atmo.hasChanges()
        or (ModData.parsed.playable ~= nil) ~= (MGE.savedPlayable == true) -- Convert / Ordinary (utils/playable.lua)
end

---Writes the mod to path (in the save folder), which becomes the source, then applies (reload)
---@param path string
local function writeMod(path)
    MGE.syncGamerules() -- rules changed in the game's menu
    -- models written for the file's folder, the data keeps them for data/mod (ModData.parsedFor)
    local parsed = ModData.parsedFor(path)
    local written, plan
    if parsed.playable then
        -- a playable atmo mod (utils/playable.lua): the mod, its pool and its atmo in one file
        local text
        text, plan = MGE.Playable.text(parsed, Atmo.currentText())
        local file = Files.Open(MGE.modFolder .. path, FILES_MODE_WRITE)
        if file and file.data then
            file:writeLine(text)
            file:close()
            written = true
        end
    else
        -- Default: the mod with its atmo inside (a drawn mod, utils/atmo.lua): one file to share, Atmo Play
        -- draws the atmo; World > Export writes a separate .atmo and a mod without it
        local file = Files.Open(MGE.modFolder .. path, FILES_MODE_WRITE)
        if file and file.data then
            file:writeLine(Atmo.bundledText(FileHandler.modText(parsed)))
            file:close()
            written = true
        end
    end
    if not written then
        MGE.say("couldn't save " .. path)
        return
    end
    MGE.setSource(path)
    MGE.saveName = nil -- the source is that file now
    MGE.savedPlayable = plan ~= nil
    if plan then
        MGE.say(string.format("saved %s: playable, %d atmo objects (%d solid), %d pool objects", path, plan.atmo,
            plan.solid, #plan.objects))
    else
        local count = #(ModData.parsed.atmo or {})
        MGE.say("saved " .. path .. (count > 0 and (" with its atmo (" .. count .. " objects, drawn)") or ""))
    end
    Atmo.markSaved() -- the atmo is in the mod file
    -- the saved mod is what gets shared, say so if dynamic objects won't fully work in it
    local warning = MGE.Main and MGE.Main.dynamicWarning()
    if warning then MGE.say("saved with " .. warning) end
    MGE.apply()
end

---World > Export's name prompt, shared by both exports: prefilled with the mod's name, the typed name (cleaned and
---checked like the project's) gets EXPORT_PREFIX, then write runs with it. Doesn't change the mod's name: a wip or
---final copy under any name, replacing only an earlier export of that name
---@param title string
---@param write fun(name: string) name with the prefix
function MGE.askExportName(title, write)
    askName(title, "File name (" .. MGE.EXPORT_PREFIX .. " is added)", MGE.saveTargetName(), function(name)
        write(MGE.EXPORT_PREFIX .. name)
    end)
end

---World > Export > Mod: the mod as the game reads it, without its atmo and pools (what Save puts inside it for
---Atmo Play), written as modmaker/exp_<name>.tbm (MGE.askExportName). A playable mod's static objects are in its
---atmo, so its clean copy has only what stayed objects
function MGE.exportCleanMod()
    local function pathOf(name) return MGE.saveFolder .. name .. ".tbm" end
    MGE.askExportName("Export mod without atmo (" .. MGE.saveFolder .. MGE.EXPORT_PREFIX .. "<name>)",
        function(name)
            local path = pathOf(name)
            MGE.syncGamerules()
            if FileHandler.WriteMod(ModData.parsedFor(path), MGE.modFolder .. path) then
                MGE.say("exported " .. path .. ": the mod without its atmo" ..
                    (MGE.Playable.isOn() and " (playable: its static objects are in the atmo, not in this copy)" or ""))
            else
                MGE.say("couldn't write " .. path)
            end
        end)
end

---True when writing path would replace a file that isn't ours (the source): an earlier copy or
---another mod
---@param path string
---@return boolean
local function wouldReplace(path)
    return path ~= MGE.sourcePath and Files.Exists(MGE.modFolder .. path)
end

---@type { confirm: fun(), cancel: fun()?, frame: integer? }? the open confirmation's actions (MGE.confirm)
local confirmActions = nil

---Asks with Toribash's own popup (TBMenu:showConfirmationWindow): Continue / Enter runs onConfirm,
---Cancel / Esc onCancel. Kept in MGE.confirmOverlay (quit closes it, shortcuts wait for it). Does
---nothing while one is open already
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
    -- the frame it opened in: the Enter that opened it (the name prompt's) doesn't also confirm it
    actions = { confirm = finish(onConfirm), cancel = finish(onCancel), frame = UIElement and UIElement.frameIndex }
    confirmActions = actions
    MGE.confirmOverlay = TBMenu:showConfirmationWindow(message, actions.confirm, actions.cancel)
    return true
end

---Save button / Ctrl + S: writes the mod where MGE.saveTarget says. Asks first when that would replace a file that
---isn't ours (another mod, an earlier copy): World > Core's Name gives it another name
function MGE.save()
    local target = MGE.saveTarget()
    if wouldReplace(target) then
        local _, name = splitModPath(target)
        local _, sourceName = splitModPath(MGE.sourcePath)
        -- a loaded export (exp_<name>) saves as <name>: most likely its own project, which has the atmo the export
        -- doesn't (an Export > Mod copy)
        local fromExport = sourceName ~= MGE.projectName(sourceName)
        MGE.confirm(name .. ".tbm already exists in " .. MGE.saveFolder .. ". Overwrite it?\n" ..
            (fromExport and ("You loaded the export " .. sourceName .. ".tbm: this replaces the project " ..
                "with it.\n") or "") ..
            "(World > Core > Name saves under another name)", function() writeMod(target) end)
    else
        writeMod(target)
    end
end

-- MGE's overlays (fields holding an open UIElement), topmost first: Esc closes them in this order
-- (the picker can be open over the map overlay, the confirmation over anything). A new overlay only
-- needs adding here for quit, Esc and overlayOpen to handle it
local OVERLAY_KEYS = { "confirmOverlay", "colorOverlay", "saveOverlay", "pickerOverlay", "settingsOverlay", "mapOverlay" }

---The topmost open overlay
---@return string? key its MGE field
---@return UIElement? overlay
local function topOverlay()
    for _, key in ipairs(OVERLAY_KEYS) do
        local overlay = MGE[key]
        if overlay and not overlay.destroyed then return key, overlay end
    end
    return nil, nil
end

---Removes hooks, UI and the MGE global. Safe to call more than once and on a partially started script
---@param fromWindow boolean? true when called by the main window's killAction (window is already closing)
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
    -- our text fields and toggles would otherwise stay in toriui's keyboard list after quitting
    if window and MGE.Widgets then pcall(MGE.Widgets.releaseKeyboard, window) end
    if not fromWindow and window and not window.destroyed then
        window.killAction = nil
        pcall(function() window:kill() end)
    end
    if MGE.cameraChanged then set_camera_mode(0) end -- look-at camera set by editor/object list

    MGE = nil
    MGE.say("closed")
end

add_hook("match_begin", MGE.hookname, function()
    local path = MGE.modPath
    MGE.updateSource()
    -- saves alternate between the two output files, that isn't a mod switch
    local switchedMod = path ~= MGE.modPath and not (isSaveOutput(path) and isSaveOutput(MGE.modPath))
    if switchedMod then
        set_camera_mode(0)
        MGE.Playable.loadedKey = nil -- its pools are its own (Playable.onMatchBegin reads them)
        -- a mod file was loaded (not our working copy): the data belongs to it now, with its atmo
        if not isSaveOutput(MGE.modPath) then
            MGE.saveName = nil -- Save writes the new mod's name
            MGE.setSource(MGE.modPath)
            loadSourceAtmo()
            Atmo.applyShader() -- the new mod's atmo shader, or the player's own
        end
    end
    -- a mod file was loaded: its rules are the new baseline. Applying gamerules in the game's menu
    -- also starts a new match, that one keeps the old baseline so the change is saved later
    if switchedMod or MGE.reloadPending then MGE.snapshotGamerules() end

    if MGE.reloadPending then
        -- our own save: same objects, restore selection and keep the list page
        for _, obj in ipairs(ModData.parsed.env_obj) do
            obj.selected = MGE.keptSelection and MGE.keptSelection[obj.id] or nil
        end
        for i, obj in ipairs(ModData.parsed.atmo) do
            obj.selected = MGE.keptSelection and MGE.keptSelection[-i] or nil
        end
        MGE.Main.updateWindow()
        -- e.g. an asset import: the new objects are selected and only exist in the world now
        if MGE.focusAfterReload then MGE.Camera.followSelection() end
    else
        -- other reloads (new mod, game restart) re-read the file, older states no longer match
        History.reset()
        MGE.Main.resetWindow()
    end
    MGE.reloadPending = false
    MGE.keptSelection = nil
    MGE.focusAfterReload = nil -- only for the reload it was set for
    MGE.AtmoLayer.reapplySeeThrough() -- the reload gave the objects their file colors again (the Atmo list)
    MGE.Playable.onMatchBegin() -- a playable mod: its pool placed for this fight
end)

-- Alt + Q / W / E: Move / Rotate / Scale gizmo on / off, same as the toolbar toggles (ui/main.lua).
-- Alt, not Shift: the game has its own Shift binds on some of these keys
local TOOL_KEYS = {
    [string.byte("q")] = "move",
    [string.byte("w")] = "rotate",
    [string.byte("e")] = "scale",
}

local KEY_DELETE = 127 -- SDLK_DELETE (toriui's text fields use the same code)

-- Ctrl + N / D and Delete: the shown list's New, Duplicate and Delete buttons: objects, or the
-- Players / Joints list's own (ui/player_list.lua, ui/joint_list.lua)
---@param action "new"|"duplicate"|"delete"
local function listAction(action)
    local tab, actions = MGE.Main.listTab, nil
    if tab == "misc" then return end -- nothing to pick there: the hidden objects stay as they are
    if tab == "players" then
        local L = MGE.PlayerList
        actions = { new = L.newPlayer, duplicate = L.duplicate, delete = L.deleteSelected }
    elseif tab == "joints" then
        local L = MGE.JointList
        actions = { new = L.newJoint, duplicate = L.duplicate, delete = L.deleteSelected }
    elseif tab == "atmo" then -- Duplicate and Delete work on the shown list (ui/editor.lua)
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

---True while a prompt, popup or picker of MGE's is open, or one of the game's overlays
---(TBMenu:spawnWindowOverlay sets TB_MENU_POPUPS_DISABLED while it's up): object shortcuts wait
---until it's closed, so a key doesn't change the list behind it, and the gizmo isn't drawn over it
---@return boolean
local function overlayOpen()
    if topOverlay() then return true end
    return TB_MENU_POPUPS_DISABLED == true
end
MGE.overlayOpen = overlayOpen

local KEY_ESCAPE = 27
local KEY_RETURN, KEY_KEYPAD_ENTER = 13, 271 -- toriui's text fields use the same codes
local escFrame = nil -- UIElement.frameIndex of the last Esc close

---Closes MGE's topmost overlay, for Esc: the delete confirmation (like its Cancel), else the name
---prompt, the file picker, the settings. Esc reaches both this module's key hook and the overlay's
---focused text field (Widgets.closeOnEscape), so one press closes only one overlay: a second call in
---the same frame does nothing
---@return boolean handled an overlay was open (and is closed now)
function MGE.closeTopOverlay()
    local frame = UIElement and UIElement.frameIndex
    if frame and frame == escFrame then return true end
    local key, overlay = topOverlay()
    if overlay then
        overlay:kill() -- their killActions clean up (keyboard, MGE.*Overlay, camera movement)
        -- killing the confirmation doesn't call its Cancel: Esc is Cancel
        if key == "confirmOverlay" then
            local actions = confirmActions
            MGE.confirmOverlay = nil
            if actions then actions.cancel() end
        end
        escFrame = frame
        return true
    end
    -- a pick in progress (the Core tab's color picker)
    if MGE.WorldSelect and MGE.WorldSelect.cancelPick() then
        MGE.say("pick cancelled")
        escFrame = frame
        return true
    end
    -- the map placement view isn't an overlay (the gizmo works under it), Esc goes back to its settings
    if MGE.isPlacing() then
        MGE.MapPlace.cancel()
        escFrame = frame
        return true
    end
    return false
end

-- Shift+Z undo, Shift+Y redo (Ctrl+Z/Y are taken by the game), Ctrl+S saves the mod (MGE.save),
-- Ctrl+A selects / deselects all objects, Alt + Q / W / E toggles a gizmo tool,
-- Ctrl + N / D new / duplicate, Delete deletes the selection (asks first), Esc closes MGE's overlays,
-- Enter confirms MGE's confirmation popup (Esc cancels it).
add_hook("key_down", MGE.hookname, function(key)
    -- before the text field check: the name prompt focuses its field
    if key == KEY_ESCAPE then
        if MGE.closeTopOverlay() then return 1 end -- consumed, the game doesn't open its menu too
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
        if MGE.ColorPicker.confirm then MGE.ColorPicker.confirm() end -- Apply
        return 1
    end
    if TB_MENU_INPUT_ISACTIVE then return end -- typing in a text field
    local shift, ctrl = get_keyboard_shift() ~= 0, get_keyboard_ctrl() ~= 0
    if get_keyboard_alt() ~= 0 then
        -- Alt + Q / W / E: the gizmo tools, also in the map placement view (it hides the window)
        if not shift and not ctrl and TOOL_KEYS[key] and (MGE.isPlacing() or MGE.Main.window.displayed) then
            MGE.Gizmo.toggle(TOOL_KEYS[key])
            return 1
        end
        return
    end
    -- the map placement view: only its gizmo tools work (above), the rest acts on objects
    if MGE.isPlacing() then return end
    if not MGE.Main.window.displayed then return end
    if key == KEY_DELETE and not shift and not ctrl then
        if not overlayOpen() then listAction("delete") end -- confirmation popup
        return 1
    elseif ctrl and not shift and OBJECT_KEYS[key] then
        if not overlayOpen() then OBJECT_KEYS[key]() end
        return 1
    end
    if shift and not ctrl then
        if key == string.byte("z") then
            History.undo()
            return 1 -- consume so the game doesn't also handle the key
        elseif key == string.byte("y") then
            History.redo()
            return 1
        end
    elseif ctrl and not shift and key == string.byte("s") then
        MGE.save() -- writes the mod into modmaker/, then reloads
        return 1
    elseif ctrl and not shift and key == string.byte("a") then
        -- same as the list's select all icon. On the Players / Joints list: those, not the objects
        local tab = MGE.Main.listTab
        if tab == "players" then
            MGE.Main.toggleSelectAllPlayers()
        elseif tab == "joints" then
            MGE.Main.toggleSelectAllJoints()
        elseif tab == "atmo" then
            MGE.Main.toggleSelectAllAtmo()
        elseif tab ~= "misc" then -- the World list has nothing to select
            MGE.Main.toggleSelectAll()
        end
        return 1
    end
end)

-- The game's HUD is hidden while MGE's window shows (the top bar and panel cover where it is), back as it
-- was when F1 hides the window or MGE closes. The setting from before MGE is kept in a global, so a
-- script restart while the HUD is hidden doesn't take "hidden" for the player's own setting
MGE_HUD_BEFORE = MGE_HUD_BEFORE or get_option("hud")

---@param hidden boolean
function MGE.hideGameHud(hidden)
    set_option("hud", hidden and 0 or (MGE_HUD_BEFORE or 1))
end
table.insert(MGE.onQuit, function()
    MGE.hideGameHud(false)
    MGE_HUD_BEFORE = nil
end)
-- another script loaded (/ls) ends MGE without its quit: the HUD comes back then too. (A game closed with
-- MGE open keeps it off: the option is saved by the game, Settings > HUD or /opt hud 1 brings it back)
add_hook("unload", MGE.hookname, function() MGE.hideGameHud(false) end)
-- Hidden on the next frame, not right away: a /ls of MGE (starting it, or showing the running one) fires
-- "unload" after MGE's code ran, and the hook above (already MGE's, it replaced the old one) put the HUD
-- back at once. A hook set of its own, removed once it ran (and by quit, when MGE closes before a frame)
local HUD_START_HOOK = MGE.hookname .. "_hudStart"
function MGE.hideGameHudNextFrame()
    add_hook("draw2d", HUD_START_HOOK, function()
        remove_hooks(HUD_START_HOOK)
        if MGE and MGE.Main and MGE.Main.window and MGE.Main.window.displayed then MGE.hideGameHud(true) end
    end)
end
table.insert(MGE.onQuit, function() remove_hooks(HUD_START_HOOK) end)
MGE.hideGameHudNextFrame()

-- The game's main menu (Esc) puts the HUD back while it's open (opt hud 1), and leaves it on when it
-- closes. When it closes with MGE's window shown, the HUD is hidden again. Only on that change, not every
-- frame: a /opt hud 1 typed with MGE shown stays. TB_MENU_MAIN_ISOPEN is the game's own flag (system/menu_*)
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
    if key ~= 282 then return end --F1
    if MGE.isPlacing() then return end -- the placement view shows it again when it ends
    local Main = MGE.Main
    -- hidden is the play view: the mod's objects in their own colors, not see-through as the Atmo list has them
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
-- source: the loaded mod. Started on a working copy (script restarted after editing): the source from
-- before the restart, compared with its text
if MGE.modPath and not isSaveOutput(MGE.modPath) then
    MGE.setSource(MGE.modPath)
    loadSourceAtmo()
else
    if MGE_SOURCE then MGE.setSource(MGE_SOURCE.path, MGE_SOURCE.text) end
    -- the working copy: the atmo layer as the last instance had it
    if MGE_ATMO then
        local ok, objects = pcall(MGE_ATMO.objects)
        local okState, state = pcall(MGE_ATMO.state)
        if ok and type(objects) == "table" then ModData.parsed.atmo = objects end
        if okState and type(state) == "table" then Atmo.state = state end
        -- a playable mod's params (utils/playable.lua): the working copy doesn't say it's playable
        local okPlayable, playable = pcall(MGE_ATMO.playable or function() end)
        if okPlayable and type(playable) == "table" then ModData.parsed.playable = playable end
    end
end
-- the first undo state: after the atmo is read, or undoing back to it would empty the atmo
History.reset()
MGE_ATMO = {
    objects = function() return ModData.parsed.atmo end,
    state = function() return Atmo.state end,
    playable = function() return ModData.parsed.playable end,
}
MGE.AtmoLayer.unloadGameAtmo() -- MGE draws the atmo itself, a loaded one would show it twice
MGE.Playable.onMatchBegin() -- started on a playable mod: its pool (in the world now) follows the players
-- the player's shader (the unload put it back), then the mod's atmo shader shown live (Atmo.applyShader)
Atmo.rememberShader()
Atmo.applyShader()
table.insert(MGE.onQuit, function()
    Atmo.applyShader(true) -- the player's own shader back
    MGE_SHADER_BEFORE = nil
end)
loadModule("ui/main.lua")
MGE.running = true -- set last so a failed start isn't treated as running
