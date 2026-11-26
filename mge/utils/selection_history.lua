-- Selection back / forward (Ctrl + Shift + Z / Y): a misclick replaces a selection, and undo keeps the
-- current selection. Objects, atmo objects and body parts each keep their own steps, recorded on every
-- selection change (Main.onSelectionChanged) when they differ from the current step. Object steps hold each
-- object's `selKey` (ModData.keyObjects), which survives renumbering (delete, reindex, To atmo) and undo's
-- copies; part steps hold Main.selectedParts' keys ("<player>:<part>", ui/part_list.lua)

local ModData = MGE.ModData

---@class SelectionHistory
local SelectionHistory = {
    limit = 50,
    ---@type table<string, { states: any[][], index: integer }> by layer ("objects", "atmo", "parts")
    layers = {},
}

---@param layer string
---@return FileParserEnvObj[]
local function listOf(layer)
    local parsed = ModData.parsed or {}
    return (layer == "atmo" and parsed.atmo or parsed.env_obj) or {}
end

---@param layer string
---@return any[] keys of the selected, in list order (parts: sorted)
local function current(layer)
    if layer == "parts" then
        local keys = {}
        for k in pairs(MGE.Main.selectedParts or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        return keys
    end
    ModData.keyObjects(listOf(layer))
    local keys = {}
    for _, obj in ipairs(listOf(layer)) do
        if obj.selected then keys[#keys + 1] = obj.selKey end
    end
    return keys
end

---@param a integer[]
---@param b integer[]
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

---@param layer string
local function recordLayer(layer)
    local h = SelectionHistory.layers[layer]
    if not h then
        h = { states = {}, index = 0 }
        SelectionHistory.layers[layer] = h
    end
    local now = current(layer)
    local top = h.states[h.index]
    if top and same(top, now) then return end
    for i = #h.states, h.index + 1, -1 do h.states[i] = nil end -- a new step drops the forward ones
    h.states[#h.states + 1] = now
    if #h.states > SelectionHistory.limit then table.remove(h.states, 1) end
    h.index = #h.states
end

---Stores the layers' selections as new steps where they changed
function SelectionHistory.record()
    recordLayer("objects")
    recordLayer("atmo")
    if MGE.Main and MGE.Main.selectedParts then recordLayer("parts") end
end

---Forgets every step (another mod: its ids aren't these)
function SelectionHistory.reset()
    SelectionHistory.layers = {}
end

---Selects a stored step's objects (ones gone since are skipped)
---@param layer string
---@param keys any[]
local function apply(layer, keys)
    local wanted = {}
    for _, key in ipairs(keys) do wanted[key] = true end
    if layer == "parts" then -- players gone since: PartList.selected leaves them out
        MGE.Main.selectedParts = wanted
        return
    end
    for _, obj in ipairs(listOf(layer)) do
        obj.selected = wanted[obj.selKey] or nil
    end
end

---Moves one step back (-1) or forward (1) on a layer
---@param layer string "objects", "atmo" or "parts"
---@param step integer
---@return boolean moved, integer? count selected after the move
function SelectionHistory.move(layer, step)
    recordLayer(layer) -- a change no hook saw yet becomes the step to come back to
    local h = SelectionHistory.layers[layer]
    local target = h.index + step
    if not h.states[target] then return false end
    h.index = target
    apply(layer, h.states[target])
    return true, #h.states[target]
end

---Ctrl + Shift + Z / Y on the shown list
---@param step integer -1 back, 1 forward
function SelectionHistory.step(step)
    local Main = MGE.Main
    local tab = Main.listTab
    local layer = (tab == "atmo" or tab == "objects" or tab == "parts") and tab or nil
    if not layer then
        MGE.say("selection back / forward: on the Objects, Atmo and Parts lists")
        return
    end
    local moved, count = SelectionHistory.move(layer, step)
    if not moved then
        MGE.say(step < 0 and "no earlier selection" or "no later selection")
        return
    end
    Main.updateWindow() -- records nothing: the selection is the current step
    if count > 0 and layer ~= "parts" then Main.selectionMade() end -- Generate back to Core, camera follow
    MGE.say(string.format("selection %s: %d selected", step < 0 and "back" or "forward", count))
end

MGE.SelectionHistory = SelectionHistory
