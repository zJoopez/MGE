-- World list panel, about the whole mod: Name (Save's target), Message, Shader, Map (Convert map),
-- Mod (Reset all), Atmo (Playable / Default), Export, credits
local Rows = MGE.EditorRows
local Widgets = MGE.Widgets
local ModData = MGE.ModData
local History = MGE.History
local createRow = Rows.createRow
local createToggleButtonRow = Rows.createToggleButtonRow

---The mod's message line
---@return integer? index in ModData.parsed.ignores, nil without one
---@return string? text
local function findMessage()
    for i, line in ipairs(ModData.parsed.ignores or {}) do
        if line:match("^%s*message%s") or line:match("^%s*message$") then
            return i, line:match("^%s*message%s*(.-)%s*$")
        end
    end
    return nil, nil
end

---Sets the message line (empty: removes it), one undo step, the mod reloads with it
---@param text string?
local function setMessage(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not ModData.parsed.ignores then return end
    local i, current = findMessage()
    if (current or "") == text then return end
    -- replaced, not modified: undo states share it
    local ignores = ModData.copy(ModData.parsed.ignores)
    ModData.parsed.ignores = ignores
    if text == "" then
        table.remove(ignores, i)
    elseif i then
        ignores[i] = "message " .. text
    else
        -- after the #! and version lines, like the game's mods
        local at = 1
        while ignores[at] and (ignores[at]:match("^#!") or ignores[at]:match("^%s*version%s")) do at = at + 1 end
        table.insert(ignores, at, "message " .. text)
    end
    History.commit()
    MGE.apply()
end

---The atmo's shader line
---@return integer? index in Atmo.state.header
---@return string? shader name (data/shader/<name>.inc)
local function findShader()
    for i, line in ipairs(MGE.Atmo.state.header) do
        local name = line:match("^%s*shader%s+(.-)%s*$")
        if name then return i, name end
    end
    return nil, nil
end

---Sets the atmo's shader line (nil removes it). Not in the undo history; shown live
---@param name string?
local function setShader(name)
    local header = MGE.Atmo.state.header
    local i = findShader()
    if name and name ~= "" then
        if i then header[i] = "shader " .. name else table.insert(header, 1, "shader " .. name) end
    elseif i then
        table.remove(header, i)
    end
    MGE.Atmo.headerVersion = MGE.Atmo.headerVersion + 1 -- footer: unsaved
    MGE.Atmo.applyShader()
    Rows.refreshBlocks({ "miscFile" })
end

---A free text field (editor fields are numeric); Enter calls onEnter
---@param container UIElement
---@param text string
---@param placeholder string
---@param onEnter fun(text: string)
---@return UIElement
local function createTextInput(container, text, placeholder, onEnter)
    local input = TBMenu:spawnTextField2(container, nil, text, placeholder, {
        inputType = KEYBOARD_INPUT.ASCII,
        textfield = true,
        returnKeyType = KEYBOARD_RETURN.SEND,
        textAlign = CENTER,
        fontId = Widgets.FONT,
        darkerMode = true,
        textScale = Widgets.TEXT_SCALE_SMALL,
    })
    input:addKeyboardHandlers(nil, function(key)
        if key == 13 then onEnter(input.textfieldstr[1] or "") end
    end)
    return input
end

---Name, Message and Shader rows (rebuilt)
---@param holder UIElement
local function buildFileRows(holder)
    Rows.begin()
    local row, contentX, contentW = createRow("Name", holder,
        "Save writes " .. MGE.saveFolder .. "<name>.tbm.\nClick to rename.")
    local inset = Widgets.INSET
    Widgets.button(row, { x = contentX + inset, y = inset, w = contentW - inset * 2, h = row.size.h - inset * 2 },
        MGE.saveTargetName(), function() MGE.renameProject() end, nil, Widgets.PANEL_STYLE)

    row, contentX, contentW = createRow("Message", holder,
        "Shown in chat when the mod loads (its message line).\nEnter applies it, empty removes it.")
    local container = row:addChild({ pos = { contentX, 0 }, size = { contentW, row.size.h } })
    local _, message = findMessage()
    createTextInput(container, message or "", "No message", setMessage)

    local _, shader = findShader()
    Rows.createPickRow("Shader", holder, "The atmo's shader, saved with it.\nTrash icon: no shader.",
        shader or "Pick shader", function()
            MGE.FilePicker.open({
                title = "Pick Shader",
                root = "data/shader",
                rootLabel = "shader",
                extension = "inc",
                selected = shader,
                confirmLabel = "Use shader",
                onConfirm = setShader,
            })
        end, function() setShader(nil) end, "No shader (remove)")
end

---Map row: opens the Convert Map overlay
---@param holder UIElement
local function buildMapRow(holder)
    Rows.begin()
    createToggleButtonRow("Map", holder, {
        { label = "Convert map", active = false, onClick = function()
            if MGE.overlayOpen() then return end
            -- loaded on first use: a broken converter mustn't break the editor
            local ok, err = pcall(MGE.loadMapConv)
            if not ok then
                MGE.say("the map converter didn't load: " .. tostring(err))
                return
            end
            dofile(MGE.scriptPath .. "ui/map_overlay.lua")
        end },
    }, "Turns a .vmf (Hammer) or Source .bsp map (CS:S,\n" ..
        "CS:GO, TF2...) into static boxes, added where\nthe map puts them. Maps go in assets/maps.")
end

---Reset all: loads the classic mod, asking first with unsaved changes
local function resetAll()
    if MGE.overlayOpen() then return end
    local function load()
        MGE.say("loading classic")
        MGE.loadMod("classic")
    end
    if MGE.hasUnsavedChanges() then
        MGE.confirm("Load the classic mod? Unsaved changes to this mod and its atmo are lost.", load)
    else
        load()
    end
end

---Atmo row: Playable / Default (rebuilt by the switch, undo and opening a mod)
---@param holder UIElement
local function buildPlayableRow(holder)
    Rows.begin()
    local Playable = MGE.Playable
    local on = Playable.isOn()
    Rows.createToggleButtonRow("Atmo", holder, {
        { label = "Playable", active = on, onClick = function() Playable.setPlayable(true) end },
        { label = "Default", active = not on, onClick = function() Playable.setPlayable(false) end },
    }, "Playable: static objects move to the atmo,\nsolid in fights (needs Atmo Play).\n" ..
        "Default: atmo only drawn, objects come back.")
end

---Export row: copies for players without Atmo Play (an .atmo, and the mod without its atmo)
---@param holder UIElement
local function buildExportRow(holder)
    Rows.begin()
    createToggleButtonRow("Export", holder, {
        { label = "Atmo", active = false, onClick = function() MGE.AtmoLayer.exportAtmo() end },
        { label = "Mod", active = false, onClick = function() MGE.exportCleanMod() end },
    }, "Copies without Atmo Play, named exp_<name>.\nAtmo: an .atmo file. Mod: the mod without it.")
end

---Mod row: Reset all
---@param holder UIElement
local function buildModRow(holder)
    Rows.begin()
    createToggleButtonRow("Mod", holder, {
        { label = "Reset all", active = false, onClick = resetAll },
    }, "Loads the classic mod (/lm classic): a fresh start.\nAsks first when there are unsaved changes.")
end

---Credits on the panel's last row
---@param holder UIElement
local function buildCredits(holder)
    local line = holder:addChild({ pos = { 0, 0 }, size = { holder.size.w, holder.size.h } })
    line:addAdaptedText("Project Mod Group Editor by joopez", nil, nil, Widgets.FONT, CENTERMID, Widgets.TEXT_SCALE_SMALL)
end

---@type EditorPanelModule
return {
    fixed = {
        { build = buildMapRow, panel = "misc", row = 3, rows = 1 },
        { build = buildExportRow, panel = "misc", row = 4, rows = 1 },
        { build = buildModRow, panel = "misc", row = 6, rows = 1 },
        { build = buildCredits, panel = "misc", row = 8, rows = 1 },
    },
    blocks = {
        { name = "miscFile", build = buildFileRows, panel = "misc", row = 0, rows = 3 },
        { name = "playable", build = buildPlayableRow, panel = "misc", row = 5, rows = 1 },
    },
}
