-- The Atmo list's own rows on its Advanced tab (the objects' Advanced panel, ui/editor_advanced.lua: Friction,
-- Bounce, Hardness and Flags first; rows 4-6 here, where the objects have Model and Ids). The lines atmos have
-- and objects don't, and the lines MGE keeps without editing them:
--   Depth:    drawn over everything (no_depth 1), or normally
--   Graphics: the game's graphics levels it's drawn at, min and max (0 lowest - 2 highest)
--   Kept:     only when the selected ones have such lines: how many other lines they keep (count, randompos,
--             rotate, parent...), written back as they are, MGE draws such objects as their plain shape
-- Playable (the whole mod) is on the World tab (ui/editor_misc.lua).
-- Atmo objects aren't in the .tbm: changes here are an undo step, no reload.
local Rows = MGE.EditorRows
local ModData = MGE.ModData
local History = MGE.History
local inputs = Rows.inputs
local sharedChoice = Rows.sharedChoice

-- the lines atmo objects use that MGE edits (the Core and Advanced tabs): every other one is kept as it is
local EDITED = { shape = true, pos = true, rot = true, sides = true, color = true, no_depth = true,
    min_level = true, max_level = true, mass = true, visible = true, friction = true, bounce = true,
    hardness = true, flag = true }

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
    Rows.afterAtmoEdit(key)
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
    Rows.afterAtmoEdit("min_level")
end

---Depth, Graphics and Kept rows, rebuilt with the selection; nothing on the Objects list (Model and Ids there)
---@param holder UIElement
---@param selected FileParserEnvObj[] the selected atmo objects (ModData.getEditSelection on the Atmo list)
local function buildAtmoRows(holder, selected)
    Rows.begin()
    if not Rows.atmoShown() then
        inputs.atmoLevels = {}
        return
    end
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
    if kept == 0 then return end
    local names = {}
    for key in pairs(keys) do names[#names + 1] = key end
    table.sort(names)
    Rows.createToggleButtonRow("Kept", holder, {
        { label = kept .. " lines: " .. table.concat(names, ", "), active = false, onClick = function() end },
    }, "Lines MGE doesn't edit (count, randompos, parent...),\nsaved as they are.")
end

---@type EditorPanelModule
return {
    blocks = {
        { name = "atmoRows", build = buildAtmoRows, panel = "advanced", row = 4, rows = 3 },
    },
    inputs = { rebuilt = { "atmoLevels" } },
}
