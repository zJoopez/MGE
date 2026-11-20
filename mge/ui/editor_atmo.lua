-- Advanced tab of the Atmo list (the atmo objects, utils/atmo_layer.lua and utils/atmo.lua; panel id "atmo"):
-- the lines atmos have and objects don't, and the lines MGE keeps without editing them:
--   Depth:    drawn over everything (no_depth 1), or normally
--   Graphics: the game's graphics levels it's drawn at, min and max (0 lowest - 2 highest)
--   Kept:     how many other lines the selected ones keep (count, randompos, rotate, parent...): written
--             back as they are, MGE draws such objects as their plain shape
--   Playable: Off / On for the whole mod, not the selection: a playable atmo mod (utils/playable.lua), saved
--             as one and solid in fights in the editor
-- The Atmo list's Core tab is the objects' Core (ui/editor_core.lua), on the selected atmo objects, with To objects
-- and Save atmo in its last row.
-- Atmo objects aren't in the .tbm: changes here are an undo step, no reload.
local Rows = MGE.EditorRows
local ModData = MGE.ModData
local History = MGE.History
local inputs = Rows.inputs
local sharedChoice = Rows.sharedChoice

-- the lines atmo objects use that MGE edits (the Core tab and this one): every other one is kept as it is
local EDITED = { shape = true, pos = true, rot = true, sides = true, color = true, no_depth = true,
    min_level = true, max_level = true }

---Writes a line on the selected atmo objects (nil: removes it), one undo step when one changed
---@param key string
---@param value string?
local function setLine(key, value)
    local changed = false
    for _, obj in ipairs(ModData.getSelectedAtmo()) do
        if obj.props[key] ~= value then
            obj.props[key] = value
            changed = true
        end
    end
    if not changed then return end
    History.commit()
    Rows.refreshProperties()
end

---Graphics row: the typed min / max levels (0-2), an empty field keeps each object's own. The game's
---defaults (0 and 2) aren't written
local function setLevels()
    local typed = Rows.readInputs(inputs.atmoLevels)
    local changed = false
    for _, obj in ipairs(ModData.getSelectedAtmo()) do
        for i, key in ipairs({ "min_level", "max_level" }) do
            local value = typed[i]
            if value then
                value = math.max(0, math.min(2, math.floor(value + 0.5)))
                local line = (value ~= (i == 1 and 0 or 2)) and tostring(value) or nil
                if obj.props[key] ~= line then
                    obj.props[key] = line
                    changed = true
                end
            end
        end
    end
    if not changed then return end
    History.commit()
    Rows.refreshProperties()
end

---Depth, Graphics and Kept rows, rebuilt with the selection
---@param holder UIElement
---@param selected FileParserEnvObj[] the selected atmo objects (ModData.getEditSelection on the Atmo list)
local function buildAtmoProps(holder, selected)
    Rows.begin()
    Rows.createChoiceRow("Depth", holder, {
        { label = "Normal", value = false },
        { label = "On top", value = true },
    }, sharedChoice(selected, function(obj) return obj.props.no_depth == "1" end),
        function(onTop) setLine("no_depth", onTop and "1" or nil) end,
        "On top: drawn over everything, even what's in front\n(no_depth 1).")
    local function level(key, default)
        return sharedChoice(selected, function(obj) return tostring(tonumber(obj.props[key]) or default) end)
            or tostring(default)
    end
    inputs.atmoLevels = Rows.createInputRow("Graphics", holder, setLevels, { level("min_level", 0), level("max_level", 2) },
        "Lowest and highest graphics level it's drawn at\n(0-2): keeps detail off slower computers.", nil, { whole = true })
    -- the other lines (count, randompos, rotate, parent...): kept, not edited, not drawn as the game does
    local kept, keys = 0, {}
    for _, obj in ipairs(selected) do
        for key in pairs(obj.props) do
            if not EDITED[key] then
                kept = kept + 1
                keys[key] = true
            end
        end
    end
    local names = {}
    for key in pairs(keys) do names[#names + 1] = key end
    table.sort(names)
    Rows.createToggleButtonRow("Kept", holder, {
        { label = kept == 0 and "no other lines" or (kept .. " lines: " .. table.concat(names, ", ")), active = false,
            onClick = function() end },
    }, "Lines MGE doesn't edit (count, randompos, parent...),\nsaved as they are.")
end

---Playable row (utils/playable.lua): Off / On, about the whole mod. On makes the mod a playable atmo mod (its
---static objects move into the atmo), saved as one and solid in fights in the editor; Off makes it ordinary
---again. A block: the switch, undo and opening a mod rebuild it (MGE.EditorRows.refreshBlocks({ "playable" }))
---@param holder UIElement
local function buildPlayableRow(holder)
    Rows.begin()
    local Playable = MGE.Playable
    local on = Playable.isOn()
    Rows.createToggleButtonRow("Playable", holder, {
        { label = "Off", active = not on, onClick = function() Playable.setPlayable(false) end },
        { label = "On", active = on, onClick = function() Playable.setPlayable(true) end },
    }, "On: the atmo is solid in fights (Atmo Play for\nplayers, MGE itself while editing). Static\n" ..
        "objects move to the atmo; Save writes the atmo\nand hidden objects that follow the players into\n" ..
        "the mod. Off: an ordinary mod and .atmo file.")
end

---@type EditorPanelModule
return {
    blocks = {
        { name = "atmoProps", build = buildAtmoProps, panel = "atmo", row = 0, rows = 3 },
        -- the whole mod, right after the selection's rows
        { name = "playable", build = buildPlayableRow, panel = "atmo", row = 3, rows = 1 },
    },
    inputs = { rebuilt = { "atmoLevels" } },
}
