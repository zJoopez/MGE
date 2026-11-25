-- Editor area: one panel per tab (Main.applyTab -> editor.applyPanel), each tab's rows in ui/editor_*.lua.
-- The Atmo list reuses the object panels on atmo objects, plus ui/editor_atmo.lua's rows.
-- Fixed blocks are built once; the others rebuild with the selection so placeholders show current
-- values (typed text is carried over)

local editor = {}
local ModData = MGE.ModData
local History = MGE.History
local Joints = MGE.Joints
local Widgets = MGE.Widgets
local getSelected = ModData.getSelected
-- atmo objects on the Atmo list
local getEditSelection = ModData.getEditSelection

local Rows = dofile(MGE.scriptPath .. "ui/editor_rows.lua")
local inwuts = Rows.inputs

---@class EditorBlock
---@field name string? rebuilt blocks only, used by Rows.refreshBlocks
---@field build fun(holder: UIElement, selected: FileParserEnvObj[])
---@field panel string
---@field row integer first row in the panel
---@field rows integer

---@class EditorPanel
---@field height number

---@class EditorPanelModule
---@field fixed EditorBlock[]? built once
---@field blocks EditorBlock[]? rebuilt with the selection, in this order
---@field inputs { rebuilt: string[]? }? Rows.inputs lists that keep typed text over a rebuild

local Core = dofile(MGE.scriptPath .. "ui/editor_core.lua") ---@type EditorPanelModule
local MODULES = {
    Core,
    dofile(MGE.scriptPath .. "ui/editor_advanced.lua"),
    dofile(MGE.scriptPath .. "ui/editor_thrust.lua"),
    dofile(MGE.scriptPath .. "ui/editor_generate.lua"),
    dofile(MGE.scriptPath .. "ui/editor_player.lua"),
    dofile(MGE.scriptPath .. "ui/editor_link.lua"),
    dofile(MGE.scriptPath .. "ui/editor_joint.lua"),
    dofile(MGE.scriptPath .. "ui/editor_atmo.lua"),
    dofile(MGE.scriptPath .. "ui/editor_misc.lua"),
}

local ROW_H = MGE.Widgets.ROW_H
-- every panel is as tall as the tallest (Generate)
local PANEL_H = MGE.Widgets.PANEL_ROWS * ROW_H
---@type table<string, EditorPanel> by panel id (TAB_SETS in ui/main.lua)
local PANELS = {}
for _, id in ipairs({ "core", "advanced", "thrust", "generate", "player", "jointLink", "joint", "misc" }) do
    PANELS[id] = { height = PANEL_H }
end

-- collected from the modules
---@type EditorBlock[]
local FIXED = {}
---@type table<string, EditorBlock>
local BLOCKS = {}
---@type string[]
local BLOCK_ORDER = {}
-- the rebuilt input lists keep typed text over a rebuild
local REBUILT_INPUTS = {}
for _, module in ipairs(MODULES) do
    for _, block in ipairs(module.fixed or {}) do table.insert(FIXED, block) end
    for _, block in ipairs(module.blocks or {}) do
        BLOCKS[block.name] = block
        table.insert(BLOCK_ORDER, block.name)
    end
    local inputs = module.inputs or {}
    for _, key in ipairs(inputs.rebuilt or {}) do table.insert(REBUILT_INPUTS, key) end
end

---@type table<string, UIElement>
local panels = {}
---@type table<string, UIElement> holders of the rebuilt blocks by name
local blocks = {}
-- Only the shown panel's blocks rebuild; others are marked dirty until shown (rebuilding every panel
-- froze with thousands selected)
---@type string? the shown panel's id, nil until the first is shown (everything is built then)
local shownPanel = nil
---@type table<string, boolean> rebuilt blocks out of date, by name
local dirty = {}
---@type fun(names: string[])
local rebuildBlocks

---Shows one editor panel, called by Main.applyTab
---@param id string a PANELS id
function editor.applyPanel(id)
    local panel = PANELS[id]
    if not panel then return end
    shownPanel = id
    for panelId, element in pairs(panels) do
        if not element.destroyed then
            if panelId == id then element:show(true) else element:hide(true) end
        end
    end
    -- blocks that changed while hidden (the reentrant call via reapplyTabs finds none)
    local stale = {}
    for _, name in ipairs(BLOCK_ORDER) do
        if dirty[name] and BLOCKS[name].panel == id then stale[#stale + 1] = name end
    end
    if #stale > 0 then rebuildBlocks(stale) end
end

---Rebuilt children are shown by default: let the window re-apply which panel shows
local function reapplyTabs()
    if MGE.Main and MGE.Main.applyTab then MGE.Main.applyTab() end
end

---Text typed in the rebuilt input rows, kept over a rebuild
---@return table<string, string[]>
local function saveTypedProperties()
    local saved = {}
    for _, key in ipairs(REBUILT_INPUTS) do
        saved[key] = {}
        for i, input in ipairs(inwuts[key] or {}) do
            -- the field being applied comes back empty, showing the new value
            saved[key][i] = input ~= Rows.applying and input.textfieldstr[1] or nil
        end
    end
    return saved
end

---@param saved table<string, string[]>
local function restoreTypedProperties(saved)
    for key, texts in pairs(saved) do
        for i, input in ipairs(inwuts[key] or {}) do
            local text = texts[i]
            if text and text ~= "" then
                Rows.setText(input, text)
            end
        end
    end
end

---Focused rebuilt input, as its Rows.inputs key and index
---@return string? key, integer? index
local function findFocusedInput()
    for _, key in ipairs(REBUILT_INPUTS) do
        for i, input in ipairs(inwuts[key] or {}) do
            -- hide() doesn't clear keyboard
            if input.keyboard and input.displayed and not input.destroyed then return key, i end
        end
    end
    return nil, nil
end

---Focuses a text field like a click does
---@param input UIElement
local function focusInput(input)
    for _, v in ipairs(UIKeyboardHandler) do v.keyboard = v.permanentListener end
    input.keyboard = true
    input:enableMenuKeyboard()
    disable_camera_movement()
end

---Rebuilds the named blocks, keeping typed text and focus (so Enter can be pressed again and again)
---@param names string[]
rebuildBlocks = function(names)
    if not blocks.measured or blocks.measured.destroyed then return end
    local now = {}
    for _, name in ipairs(names) do
        if shownPanel and BLOCKS[name].panel ~= shownPanel then
            dirty[name] = true
        else
            dirty[name] = nil
            now[#now + 1] = name
        end
    end
    if #now == 0 then return end
    names = now
    local selected = getEditSelection() -- once for all rows
    local typed = saveTypedProperties()
    local focusKey, focusIndex = findFocusedInput()
    for _, name in ipairs(names) do
        Widgets.clearChildren(blocks[name])
        -- a failing block mustn't stop the rest (or reapplyTabs, leaving panels stacked)
        local ok, err = pcall(BLOCKS[name].build, blocks[name], selected)
        if not ok then MGE.say("editor panel error (" .. name .. "): " .. tostring(err)) end
    end
    restoreTypedProperties(typed)
    reapplyTabs()

    ---@type UIElement?
    local refocus = focusKey and focusIndex and (inwuts[focusKey] or {})[focusIndex] or nil
    if refocus and not refocus.destroyed and refocus.displayed then focusInput(refocus) end
end

Rows.refreshBlocks = rebuildBlocks
Rows.refreshProperties = function() rebuildBlocks(BLOCK_ORDER) end
-- after a move / rotate / scale only the measured values change
Rows.refreshMeasured = function() rebuildBlocks({ "measured" }) end
MGE.Transforms.onChanged = Rows.refreshMeasured

function editor.onSelectionChanged()
    Rows.refreshProperties()
end

---Duplicate on the Atmo list: selected copies with all their lines, new names
local function duplicateAtmo()
    local selected = ModData.getSelectedAtmo()
    if #selected == 0 then return end
    local atmoObjs = ModData.parsed.atmo
    for _, obj in ipairs(selected) do
        local copy = { kind = "atmo", props = ModData.copy(obj.props), lines = obj.lines, selected = true }
        obj.selected = nil -- selection moves to the copies
        atmoObjs[#atmoObjs + 1] = copy
        copy.id = #atmoObjs
    end
    History.commit()
    -- a playable mod reloads for new pools (refreshing the window)
    if not MGE.Playable.reloadIfSplitChanged() then MGE.Main.updateWindow() end
end

local function duplicate()
    if MGE.Main.listTab == "atmo" then return duplicateAtmo() end
    local selected = getSelected()
    if #selected == 0 then return end
    -- only joints between selected objects are copied
    local linkedJoints = Joints.getLinked(Joints.idSet(selected))
    if not Joints.haveRoom(#linkedJoints) then return end
    local linkedIds = Joints.getObjectIds(linkedJoints)
    local plans = {}
    for i, obj in ipairs(selected) do
        plans[i] = { pool = ModData.isStatic(obj, true) and "static" or "nonStatic", linked = linkedIds[obj.id] or false }
    end
    local ids = ModData.allocateIds(plans) -- all or nothing
    if not ids then return end

    local idMap = {} -- original id -> copy id
    for i, obj in ipairs(selected) do
        local copy = ModData.copy(obj)
        copy.id = ids[i]
        copy.props = ModData.copy(obj.props)
        -- the game's flag is read by id: write it, or the copy may get another default
        copy.props.flag = copy.props.flag or tostring(get_obj_flag(obj.id - 1) or 0)
        table.insert(ModData.parsed.env_obj, copy)
        idMap[obj.id] = copy.id
        obj.selected = false -- selection moves to the copies
    end
    Joints.copyLinked(Joints.getLinked(idMap), idMap)
    ModData.sortObjects()
    History.commit()
    MGE.apply()
end

local function delete()
    if MGE.Main.listTab == "atmo" then -- not in the .tbm: no reload
        MGE.AtmoLayer.removeSelected()
        History.commit()
        if not MGE.Playable.reloadIfSplitChanged() then MGE.Main.updateWindow() end
        return
    end
    local deleted = {}
    for i = #ModData.parsed.env_obj, 1, -1 do
        local obj = ModData.parsed.env_obj[i]
        if obj.selected then
            deleted[obj.id] = true
            table.remove(ModData.parsed.env_obj, i)
            ModData.releaseId(obj.id)
        end
    end
    Joints.removeLinkedToAny(deleted)
    History.commit()
    MGE.apply()
end

---Delete: asks first, then deletes the shown list's selection
local function onDeleteClick()
    local atmo = MGE.Main.listTab == "atmo"
    local count = #getEditSelection()
    if count == 0 or (MGE.confirmOverlay and not MGE.confirmOverlay.destroyed) then return end
    local message = "Delete " .. count .. " selected " .. (atmo and "atmo " or "") .. "object" .. (count == 1 and "" or "s") ..
        "?\nUndo can bring them back."
    MGE.confirm(message, delete)
end

---@param parent UIElement
---@param block EditorBlock
---@return UIElement holder
local function addHolder(parent, block)
    return panels[block.panel]:addChild({
        pos = { 0, block.row * ROW_H },
        size = { parent.size.w, block.rows * ROW_H },
    })
end

---@param parent UIElement editor container from ui/main.lua
function editor.create(parent)
    dirty = {}
    panels = {}
    for id, panel in pairs(PANELS) do
        panels[id] = parent:addChild({
            pos = { 0, 0 },
            size = { parent.size.w, panel.height },
        })
    end
    local selected = getEditSelection()
    for _, block in ipairs(FIXED) do
        block.build(addHolder(parent, block), selected)
    end
    blocks = {}
    for _, name in ipairs(BLOCK_ORDER) do
        local block = BLOCKS[name]
        blocks[name] = addHolder(parent, block)
        block.build(blocks[name], selected)
    end

    -- Main.applyTab sets visibility after create
end

editor.duplicate = duplicate
editor.deleteSelected = onDeleteClick

MGE.Editor = editor
return editor
