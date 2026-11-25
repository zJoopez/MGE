-- Selection back / forward (Ctrl + Shift + Z / Y): a misclick replaces a selection, and undo keeps the
-- current selection. Objects (by id) and atmo objects (by index, like History) each keep their own steps,
-- recorded on every selection change (Main.onSelectionChanged) when they differ from the current step

local ModData = MGE.ModData

---@class SelectionHistory
local SelectionHistory = {
    limit = 50,
    ---@type table<string, { states: integer[][], index: integer }> by layer ("objects", "atmo")
    layers = {},
}

---@param layer string
---@return FileParserEnvObj[]
local function listOf(layer)
    local parsed = ModData.parsed or {}
    return (layer == "atmo" and parsed.atmo or parsed.env_obj) or {}
end

---@param layer string
---@return integer[] ids (atmo: indices) of the selected, in list order
local function current(layer)
    local keys = {}
    for i, obj in ipairs(listOf(layer)) do
        if obj.selected then keys[#keys + 1] = layer == "atmo" and i or obj.id end
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

---Stores both layers' selections as new steps where they changed
function SelectionHistory.record()
    recordLayer("objects")
    recordLayer("atmo")
end

---Forgets every step (another mod: its ids aren't these)
function SelectionHistory.reset()
    SelectionHistory.layers = {}
end

---Selects a stored step's objects (ones gone since are skipped)
---@param layer string
---@param keys integer[]
local function apply(layer, keys)
    local wanted = {}
    for _, key in ipairs(keys) do wanted[key] = true end
    for i, obj in ipairs(listOf(layer)) do
        obj.selected = wanted[layer == "atmo" and i or obj.id] or nil
    end
end

---Moves one step back (-1) or forward (1) on a layer
---@param layer string "objects" or "atmo"
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
    local layer = Main.listTab == "atmo" and "atmo" or Main.listTab == "objects" and "objects" or nil
    if not layer then
        MGE.say("selection back / forward: on the Objects and Atmo lists")
        return
    end
    local moved, count = SelectionHistory.move(layer, step)
    if not moved then
        MGE.say(step < 0 and "no earlier selection" or "no later selection")
        return
    end
    Main.updateWindow() -- records nothing: the selection is the current step
    if count > 0 then Main.selectionMade() end
    MGE.say(string.format("selection %s: %d selected", step < 0 and "back" or "forward", count))
end

MGE.SelectionHistory = SelectionHistory
