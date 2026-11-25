-- Atmo files. Save writes the atmo layer inside the mod, behind Atmo Play's header (the game skips it).
-- Older mods keep it in data/atmospheres/MGE - <mod>.atmo; World > Export still writes that file.
-- The working copy carries no atmo: reloads keep it in memory, restarts take it from MGE_ATMO.
-- Parsing keeps every line, object name and header line, so a game atmo round-trips losslessly.
-- MGE calls size "sides" like objects; files get size. rot reads the same as in mod files.
local FileHandler = MGE.FileHandler
local ModData = MGE.ModData

---@class Atmo
local Atmo = {
    folder = "../data/atmospheres/",
    prefix = "MGE - ", -- MGE only writes files with it, never the game's own atmos
    ---@type { name: string?, text: string?, header: string[] } file name, text as last read or written
    ---(nil: no file), header lines (shader, opt...)
    state = { header = {} },
    ---bumped on in-place state.header edits, so the footer notices
    headerVersion = 0,
}
MGE.Atmo = Atmo

---@class AtmoFile
---@field header string[] lines before the first object: shader, shaderopt, opt, comments
---@field objects FileParserEnvObj[] ids are list indexes; atmoName is the file's name for it
---@field trailer string[] lines after the objects outside any (a player section)

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
            -- the game reads size and sides alike: MGE keeps sides
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
            -- a player section, kept as is
            file.trailer[#file.trailer + 1] = lines[i]
            i = i + 1
        end
    end
    while #file.header > 0 and file.header[#file.header]:match("^%s*$") do table.remove(file.header) end
    while #file.trailer > 0 and file.trailer[#file.trailer]:match("^%s*$") do table.remove(file.trailer) end
    return file
end

-- order of lines an object doesn't have yet
local KEY_ORDER = { "shape", "pos", "rot", "sides", "color" }
local KEY_RANK = {}
for i, key in ipairs(KEY_ORDER) do KEY_RANK[key] = i end

---@param key string MGE's key
---@return string the file's
local function fileKey(key) return key == "sides" and "size" or key end

---@param file AtmoFile|{ objects: FileParserEnvObj[], header: string[]?, trailer: string[]? }
---@return string the file's text
function Atmo.text(file)
    local lines = {}
    for _, line in ipairs(file.header or {}) do lines[#lines + 1] = line end
    if #lines > 0 then lines[#lines + 1] = "" end
    -- unnamed objects get mge_1, mge_2... skipping names in use
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
        FileHandler.appendObjectLines(lines, obj, KEY_RANK, fileKey)
        lines[#lines + 1] = ""
    end
    for _, line in ipairs(file.trailer or {}) do lines[#lines + 1] = line end
    return table.concat(lines, "\n")
end

---Makes a mod object an atmo object: clamps its color to the atmo range (above 2 the game reads 0-256).
---Other lines stay: the game skips them in atmos, and To objects gets them back
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

---@param modPath string? under data/mod, e.g. "modmaker/stairs.tbm"
---@return string? its atmo file name in data/atmospheres, nil without a mod name
function Atmo.fileName(modPath)
    local name = tostring(modPath or ""):gsub("^.*[/\\]", ""):gsub("%.tbm$", "")
    if name == "" then return nil end
    return Atmo.prefix .. name .. ".atmo"
end

---Object count, +1 for a shader line (a shader alone is worth a file)
---@return integer
function Atmo.contentCount()
    local count = #(ModData.parsed.atmo or {})
    for _, line in ipairs(Atmo.state.header) do
        if line:match("^%s*shader%s+%S") then return count + 1 end
    end
    return count
end

---The layer's text as Save would write it
---@return string
function Atmo.currentText()
    return Atmo.text({ header = Atmo.state.header, objects = ModData.parsed.atmo or {} })
end

---The layer differs from its file (or has content and no file)
---@return boolean
function Atmo.hasChanges()
    if Atmo.state.text == nil then return Atmo.contentCount() > 0 end
    return Atmo.currentText() ~= Atmo.state.text
end

-- The atmo's shader is shown live with `lws <name>.inc`. Without one, and on quit, the player's own
-- shader (from MGE's start, kept over restarts) comes back
---@type string? data/shader file the game had when MGE started, "" for none
MGE_SHADER_BEFORE = MGE_SHADER_BEFORE

---Remembers the player's shader, once (after AtmoLayer.unloadGameAtmo)
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

---Loads the atmo's shader, or the player's own without one. Only on change
---@param restore boolean? the player's own regardless (quit)
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

---Replaces the layer with the mod's atmo (empty without one)
---@param modPath string? under data/mod
---@param embedded string[]? atmo lines from inside the mod, read instead of the file
function Atmo.load(modPath, embedded)
    local name = Atmo.fileName(modPath)
    local lines = embedded or (name and FileHandler.readLines(Atmo.folder .. name))
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

---A Default mod's file: the mod plus its atmo behind Atmo Play's draw header and "#@ " lines (the game
---skips both). Without an atmo: the mod as is
---@param modText string FileHandler.modText of the mod
---@return string
function Atmo.bundledText(modText)
    if Atmo.contentCount() == 0 then return modText end
    local Format = MGE.AtmoPlay.Format
    local out = { Format.DRAW_NOTE, modText, "", Format.headerLine({ mode = Format.DRAW_MODE }) }
    Atmo.appendHidden(out, Atmo.currentText())
    return table.concat(out, "\n")
end

---Appends an atmo text's lines as Atmo Play's "#@ " comment lines (the game skips them)
---@param out string[]
---@param text string
function Atmo.appendHidden(out, text)
    local prefix = MGE.AtmoPlay.Format.ATMO_PREFIX
    for line in (text .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line == "" and "#@" or (prefix .. line)
    end
end

---World > Export: writes data/atmospheres/MGE - <name>.atmo for the game's own atmo menu
---@param modPath string a name, or a mod path under data/mod (its name is used)
---@return string? name the file written, nil on failure
function Atmo.export(modPath)
    local name = Atmo.fileName(modPath)
    if not name or not FileHandler.writeText(Atmo.folder .. name, Atmo.currentText()) then return nil end
    return name
end

---The layer counts as saved (it went into the mod file)
function Atmo.markSaved()
    Atmo.state.text = Atmo.currentText()
end

return Atmo
