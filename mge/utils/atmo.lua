-- Atmo files: MGE's atmo layer (the atmo objects, ModData.parsed.atmo, utils/atmo_layer.lua) is saved INSIDE the
-- mod (2026-11-21): a Default mod's Save writes it behind Atmo Play's draw-only header (Atmo.bundledText), a
-- playable mod's behind its playable one (utils/playable.lua); the game skips both, Atmo Play draws the atmo.
-- One file to share. Plan: docs/atmo-tab-plan.md.
--   Opening a mod reads its atmo from inside it, or from data/atmospheres/MGE - <mod>.atmo for a mod saved
--     before atmos went inside mods (Atmo.load).
--   World > Export writes that separate .atmo file (Atmo.export) for the game's own atmo menu, no script needed.
--   The working copy (MGE.apply) carries no atmo: reloads keep the layer in memory (ModData.reloadObjects),
--     a script restart takes it from MGE_ATMO.
-- The reader keeps every line of an object in order, also the ones MGE doesn't edit (count, randompos,
-- rotate, parent, no_depth, min_level, drawfunc...), its name (parent lines refer to it) and the file's
-- own lines (shader, shaderopt, opt), so a game atmo read and written again loses nothing. Inside MGE an
-- object's size is its sides line, like objects; files get size, like the game's atmos. rot is the same
-- in both: the game reads an atmo's rot the way it reads a mod file's (measured 2026-11-14)
local FileHandler = MGE.FileHandler
local ModData = MGE.ModData

---@class Atmo
local Atmo = {
    folder = "../data/atmospheres/", -- from the Toribash folder (Files.Open's ../ root)
    prefix = "MGE - ", -- MGE only ever writes files with it: never one of the game's own atmos
    ---@type { name: string?, text: string?, header: string[] } the source's atmo file: its name, its text
    ---as last read or written (Atmo.text: nil when there is none), its own lines (shader, opt...)
    state = { header = {} },
    ---counts changes to state.header made in place (the World list's shader): the footer's file row compares
    ---it to know the atmo changed
    headerVersion = 0,
}
MGE.Atmo = Atmo

local indent = "   "

---@class AtmoFile
---@field header string[] lines before the first object: shader, shaderopt, opt, comments
---@field objects FileParserEnvObj[] ids are their place in the list; atmoName is the name the file gave
---@field trailer string[] lines after the objects that belong to none (a player section, ignored by the game)

---@param lines string[]
---@return AtmoFile
function Atmo.parse(lines)
    local file = { header = {}, objects = {}, trailer = {} }
    local i = 1
    while i <= #lines and not lines[i]:match("^%s*env_obj%s") do
        file.header[#file.header + 1] = lines[i]
        i = i + 1
    end
    while i <= #lines do
        local name = lines[i]:match("^%s*env_obj%s+(.-)%s*$")
        if name then
            local block = { kind = "env_obj", header = "env_obj 0", lines = {} }
            i = i + 1
            while i <= #lines and not lines[i]:match("^%s*env_obj%s") and not lines[i]:match("^%s*player%s") do
                if not lines[i]:match("^%s*$") then block.lines[#block.lines + 1] = lines[i] end
                i = i + 1
            end
            local obj = FileHandler.parseBlock(block)
            -- size and sides are the same line to the game: MGE keeps it as sides
            if obj.props.size ~= nil then
                obj.props.sides = obj.props.sides or obj.props.size
                obj.props.size = nil
                for _, entry in ipairs(obj.lines) do
                    if entry.key == "size" then entry.key = "sides" end
                end
            end
            obj.atmoName, obj.kind = name, "atmo"
            file.objects[#file.objects + 1] = obj
            obj.id = #file.objects
        else
            -- a player section: the game skips it up to the next env_obj, kept as it is
            file.trailer[#file.trailer + 1] = lines[i]
            i = i + 1
        end
    end
    while #file.header > 0 and file.header[#file.header]:match("^%s*$") do table.remove(file.header) end
    while #file.trailer > 0 and file.trailer[#file.trailer]:match("^%s*$") do table.remove(file.trailer) end
    return file
end

-- the order of lines an object doesn't have yet (new objects, added props)
local KEY_ORDER = { "shape", "pos", "rot", "sides", "color" }
local KEY_RANK = {}
for i, key in ipairs(KEY_ORDER) do KEY_RANK[key] = i end

---@param key string MGE's key
---@return string the file's
local function fileKey(key) return key == "sides" and "size" or key end

---The file's text
---@param file AtmoFile|{ objects: FileParserEnvObj[], header: string[]?, trailer: string[]? }
---@return string
function Atmo.text(file)
    local lines = {}
    for _, line in ipairs(file.header or {}) do lines[#lines + 1] = line end
    if #lines > 0 then lines[#lines + 1] = "" end
    -- names: the file's own, the others mge_1, mge_2... skipping names in use
    local used = {}
    for _, obj in ipairs(file.objects) do
        if obj.atmoName then used[obj.atmoName] = true end
    end
    local next = 0
    for _, obj in ipairs(file.objects) do
        local name = obj.atmoName
        if not name then
            repeat
                next = next + 1
                name = "mge_" .. next
            until not used[name]
            used[name] = true
        end
        lines[#lines + 1] = "env_obj " .. name
        local props, written = obj.props or {}, {}
        for _, entry in ipairs(obj.lines or {}) do
            if entry.raw then
                lines[#lines + 1] = indent .. entry.raw
            elseif props[entry.key] ~= nil and not written[entry.key] then
                written[entry.key] = true
                lines[#lines + 1] = indent .. fileKey(entry.key) .. " " .. props[entry.key]
            end
        end
        local rest = {}
        for key in pairs(props) do
            if not written[key] then rest[#rest + 1] = key end
        end
        table.sort(rest, function(a, b)
            local ra, rb = KEY_RANK[a] or math.huge, KEY_RANK[b] or math.huge
            if ra ~= rb then return ra < rb end
            return a < b
        end)
        for _, key in ipairs(rest) do lines[#lines + 1] = indent .. fileKey(key) .. " " .. props[key] end
        lines[#lines + 1] = ""
    end
    for _, line in ipairs(file.trailer or {}) do lines[#lines + 1] = line end
    return table.concat(lines, "\n")
end

---An object of the mod made an atmo object (To atmo, an import's or conversion's objects over the free ids):
---its color in the range atmos read (above 2 the game reads 0-256).
---Its other lines stay: the game skips the ones atmos don't have (flag, mass...), and To objects
---gets them back
---@param obj FileParserEnvObj
function Atmo.fromMod(obj)
    local c = obj.props.color
    if not c then return end
    local n = {}
    for v in c:gmatch("%S+") do n[#n + 1] = tonumber(v) or 1 end
    local over = false
    for k = 1, 4 do
        local v = n[k] or 1
        local clamped = math.min(math.max(v, 0), k == 4 and 1 or 2)
        if clamped ~= v then over = true end
        n[k] = clamped
    end
    if over then obj.props.color = FileHandler.formatNumbers(n[1], n[2], n[3], n[4]) end
end

---The atmo file that goes with a mod
---@param modPath string? under data/mod, e.g. "modmaker/stairs.tbm"
---@return string? file name in data/atmospheres, nil without a mod name
function Atmo.fileName(modPath)
    local name = tostring(modPath or ""):gsub("^.*[/\\]", ""):gsub("%.tbm$", "")
    if name == "" then return nil end
    return Atmo.prefix .. name .. ".atmo"
end

---What the atmo file would hold: its objects, and its shader line counts as one (an atmo with just a
---shader, set on the World list, is still worth a file)
---@return integer
function Atmo.contentCount()
    local count = #(ModData.parsed.atmo or {})
    for _, line in ipairs(Atmo.state.header) do
        if line:match("^%s*shader%s+%S") then return count + 1 end
    end
    return count
end

---The layer's text as Save would write it now
---@return string
function Atmo.currentText()
    return Atmo.text({ header = Atmo.state.header, objects = ModData.parsed.atmo or {} })
end

---The atmo layer differs from its file (or has objects and no file)
---@return boolean
function Atmo.hasChanges()
    if Atmo.state.text == nil then return Atmo.contentCount() > 0 end
    return Atmo.currentText() ~= Atmo.state.text
end

---@param name string file name in data/atmospheres
---@return string[]? lines, nil when it isn't there
local function readLines(name)
    local file = Files.Open(Atmo.folder .. name, FILES_MODE_READONLY)
    if not file or not file.data then return nil end
    local lines = file:readAll()
    file:close()
    return lines
end

---The layer from the mod's atmo file, replacing what's there (opening a mod). No file: an empty layer
---@param modPath string? under data/mod
-- The atmo's shader shown live: the game loads a world shader with `lws <name>.inc` (its Shaders & Atmos
-- menu does the same). The mod's atmo shader (a `shader` line) is loaded when the mod opens and when the World
-- list sets it; without one, and when MGE closes, the player's own shader comes back: the one loaded when MGE
-- started (after the game's atmo was unloaded), kept in a global over a restart
---@type string? data/shader file the game had when MGE started, "" for none
MGE_SHADER_BEFORE = MGE_SHADER_BEFORE

---Remembers the player's shader, once (MGE's start, after AtmoLayer.unloadGameAtmo put it back)
function Atmo.rememberShader()
    if MGE_SHADER_BEFORE or not get_shader_name then return end
    MGE_SHADER_BEFORE = (tostring(get_shader_name() or ""):gsub("^data/shader/", ""))
end

---@return string? the atmo's shader line's name, nil without one
function Atmo.shaderName()
    for _, line in ipairs(Atmo.state.header or {}) do
        local name = line:match("^%s*shader%s+(.-)%s*$")
        if name and name ~= "" then return name end
    end
    return nil
end

---Loads the atmo's shader in the game, or the player's own without one. Only when it changes
---@param restore boolean? the player's own whatever the atmo has (MGE closing)
function Atmo.applyShader(restore)
    if not runCmd then return end
    local name = not restore and Atmo.shaderName() or nil
    local file
    if name then
        file = name:find("%.inc$") and name or (name .. ".inc")
    else
        file = (MGE_SHADER_BEFORE and MGE_SHADER_BEFORE ~= "") and MGE_SHADER_BEFORE or "default.inc"
    end
    if file == Atmo.appliedShader then return end
    Atmo.appliedShader = file
    runCmd("lws " .. file)
end

---@param embedded string[]? the atmo lines inside the mod (a playable or a drawn mod): read instead of the file
function Atmo.load(modPath, embedded)
    local name = Atmo.fileName(modPath)
    local lines = embedded or (name and readLines(name))
    if not lines then
        ModData.parsed.atmo = {}
        Atmo.state = { name = name, text = nil, header = {} }
        return
    end
    local file = Atmo.parse(lines)
    ModData.parsed.atmo = file.objects
    Atmo.state = { name = name, header = file.header }
    Atmo.state.text = Atmo.currentText()
    MGE.say("atmo: " .. #file.objects .. " objects from " .. (embedded and "the mod file" or ("data/atmospheres/" .. name)))
end

---A Default mod's file: the mod with its atmo inside, as Atmo Play reads it (a drawn mod: header
---"#atmoplay v1 mode=draw", the atmo behind "#@ ", the game skips both). Without an atmo (no objects, no
---shader): the mod as it is. Export (the World tab) still writes a separate .atmo and a mod without it
---@param modText string FileHandler.modText of the mod
---@return string
function Atmo.bundledText(modText)
    if Atmo.contentCount() == 0 then return modText end
    local Format = MGE.AtmoPlay.Format
    local out = { Format.DRAW_NOTE, modText, "", Format.headerLine({ mode = Format.DRAW_MODE }) }
    for line in (Atmo.currentText() .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line == "" and "#@" or (Format.ATMO_PREFIX .. line)
    end
    return table.concat(out, "\n")
end

---Writes data/atmospheres/MGE - <name>.atmo now: the atmo for the game's own atmo menu, no script needed (World >
---Export). It doesn't change what Save does
---@param modPath string a name, or a mod path under data/mod (its name is used)
---@return string? name the file written, nil when it couldn't be
function Atmo.export(modPath)
    local name = Atmo.fileName(modPath)
    if not name then return nil end
    local file = Files.Open(Atmo.folder .. name, FILES_MODE_WRITE)
    if not file or not file.data then return nil end
    for line in (Atmo.currentText() .. "\n"):gmatch("(.-)\n") do file:writeLine(line) end
    file:close()
    return name
end

---The layer counts as saved as it is now (a playable mod's Save: the atmo went into the mod file)
function Atmo.markSaved()
    Atmo.state.text = Atmo.currentText()
end

return Atmo
