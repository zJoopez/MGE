-- Core tab: Pos, Rot, Scale, Color, Mass, Shape, Visible and To atmo / To objects. On the Atmo list the
-- same rows edit atmo lines only; Mass and Visible act in Atmo Play (the game's atmo ignores them)
local Rows = MGE.EditorRows
local ModData = MGE.ModData
local History = MGE.History
local SHAPE = MGE.SHAPE
local getSelected = ModData.getEditSelection
local atmoShown = Rows.atmoShown
local inwuts = Rows.inputs
local readInputs = Rows.readInputs
local sharedChoice = Rows.sharedChoice
local createInputRow = Rows.createInputRow
local createChoiceRow = Rows.createChoiceRow
local function refreshProperties() Rows.refreshProperties() end

local Transforms = MGE.Transforms

-- a transform field applies only itself (only = its index)
local function positionSelected(only) Transforms.positionTo(readInputs(inwuts.position, only)) end
local function angleSelected(only) Transforms.angleTo(readInputs(inwuts.angle, only)) end
local function sizeSelected(only) Transforms.sizeTo(readInputs(inwuts.size, only)) end
local shownPosition, groupAngles, groupExtents = Transforms.shownPosition, Transforms.groupAngles, Transforms.groupExtents

-- the Pos / Rot / Scale names, lit for the active gizmo tool
local transformLabels, highlightTransformLabels = Rows.gizmoLabels()

---Pos / Rot / Scale rows; placeholders show the selection's center, angles (degrees) and size
---@param holder UIElement
---@param selected FileParserEnvObj[]
local function buildMeasuredRows(holder, selected)
    Rows.begin()
    local zeros = { 0, 0, 0 }
    local any = #selected > 0
    local _
    inwuts.position, _, transformLabels.move = createInputRow("Pos", holder, function(_, i) positionSelected(i) end,
        any and shownPosition(selected) or zeros,
        "Moves the selection's center to X, Y, Z.")
    local angles = any and groupAngles(selected) or { 0, 0, 0 }
    for i = 1, 3 do angles[i] = math.deg(angles[i]) end
    inwuts.angle, _, transformLabels.rotate = createInputRow("Rot", holder, function(_, i) angleSelected(i) end,
        angles, "Turns the selection to the angles (degrees).", nil, { angle = true })
    inwuts.size, _, transformLabels.scale = createInputRow("Scale", holder, function(_, i) sizeSelected(i) end,
        any and groupExtents(selected) or zeros,
        "Sets the selection's size along its axes.")
    highlightTransformLabels()
end

-- color without a line or live value, and placeholders without a selection (0-255)
local COLOR_DEFAULTS = { 0, 0, 0, 255 }

---An object's color r g b a (1 is 255): its line, else the live color, else COLOR_DEFAULTS
---@param obj FileParserEnvObj
---@return number[]
local function colorUnits(obj)
    local c = {}
    for n in (obj.props.color or ""):gmatch("%S+") do c[#c + 1] = tonumber(n) end
    if #c < 4 and obj.kind ~= "atmo" then -- atmo objects only have their line
        local r, g, b, a = MGE.AtmoLayer.liveColor(obj.id - 1)
        if r then c = { tonumber(r), tonumber(g), tonumber(b), tonumber(a) } end
    end
    local out = {}
    for i = 1, 4 do out[i] = c[i] or COLOR_DEFAULTS[i] / 255 end
    return out
end

---@return integer[] the color as 0-255 r g b a (the fields)
---@param obj FileParserEnvObj
---@return integer[]
local function colorOf(obj)
    local out = colorUnits(obj)
    for i = 1, 4 do out[i] = math.floor(out[i] * 255 + 0.5) end
    return out
end

---Sets each object's color (1 is 255) live and in its line, one undo step
---@param objects FileParserEnvObj[]
---@param colorFor fun(obj: FileParserEnvObj): number[]
local function setColors(objects, colorFor)
    for _, v in ipairs(objects) do
        local color = colorFor(v)
        if v.kind ~= "atmo" then set_obj_color(v.id - 1, color[1], color[2], color[3], color[4]) end
        Transforms.writeVector(v, "color", color)
    end
    History.commit()
    refreshProperties()
end

---Sets the typed channels (0-255) on the selection; empty fields keep each object's own
local function adjustColor()
    local selectedObjects = getSelected()
    if #selectedObjects == 0 then return end
    local typed = readInputs(inwuts.color)
    if not (typed[1] or typed[2] or typed[3] or typed[4]) then return end
    setColors(selectedObjects, function(v)
        local current, color = colorOf(v), {}
        for i = 1, 4 do
            -- the game accepts up to 500 (brighter)
            color[i] = math.max(0, math.min(500, typed[i] or current[i])) / 255
        end
        return color
    end)
end

---@type UIElement? the Color row's name button, lit while picking (rebuilt with the panel)
local colorLabel = nil

---Pick from world: the next clicked object gives the selection its color. Color name or Esc cancels
local function pickFromWorld()
    MGE.WorldSelect.startPick(function(source)
        local color = colorUnits(source)
        local now = getSelected() -- may have changed meanwhile
        if #now == 0 then return end
        setColors(now, function() return color end)
        MGE.say(string.format("%d objects got object %d's color", #now, source.id))
    end, function()
        Rows.setHighlighted(colorLabel, false)
    end)
    Rows.setHighlighted(colorLabel, true)
    MGE.say("click an object: the selection gets its color (Esc cancels)")
end

---The Color name: opens the color picker on the first selected color (or cancels a running pick)
local function pickColor()
    local WorldSelect = MGE.WorldSelect
    if WorldSelect.picking then
        WorldSelect.cancelPick()
        return
    end
    local targets = getSelected()
    if #targets == 0 then
        MGE.say("select the objects to color first")
        return
    end
    MGE.ColorPicker.open({
        color = colorUnits(targets[1]),
        onApply = function(color)
            local now = getSelected()
            if #now == 0 then return end
            setColors(now, function() return color end)
        end,
        onPickWorld = pickFromWorld,
    })
end

---Color and Mass rows (placeholders per channel, "mixed" where objects differ)
---@param holder UIElement
---@param selected FileParserEnvObj[]
local function buildCoreProps(holder, selected)
    Rows.begin()
    local colors = {}
    for _, obj in ipairs(selected) do colors[obj] = colorOf(obj) end
    local colorHints = {}
    for i = 1, 4 do
        colorHints[i] = sharedChoice(selected, function(obj) return tostring(colors[obj][i]) end)
            or tostring(COLOR_DEFAULTS[i])
    end
    local _
    inwuts.color, _, colorLabel = createInputRow("Color", holder, function() adjustColor() end, colorHints,
        "RGBA 0-255 (up to 500: brighter), empty fields\nkeep each object's own. Click the name: color picker.",
        pickColor)
    Rows.setHighlighted(colorLabel, MGE.WorldSelect.picking ~= nil)
    inwuts.coreProps = Rows.buildPropertyRows(holder, selected, { { "Mass", "mass" } })
end

-- Shape applies by reloading; visibility live

-- mod file names by get_obj_shape
local SHAPE_FILE_NAMES = { [SHAPE.SPHERE] = "sphere", [SHAPE.BOX] = "box", [SHAPE.CAPSULE] = "cylinder" }

---@param obj FileParserEnvObj
---@return string
local function getShape(obj)
    local shape = obj.props.shape and obj.props.shape:lower()
    if shape == "capsule" then shape = "cylinder" end -- atmos write either
    return shape or obj.kind ~= "atmo" and SHAPE_FILE_NAMES[get_obj_shape(obj.id - 1)] or "box"
end

---@param obj FileParserEnvObj
---@return boolean
local function isVisible(obj)
    local vis = tonumber(obj.props.visible)
    if vis == nil and obj.kind == "atmo" then return true end
    if vis == nil then
        local live = get_obj_vis(obj.id - 1)
        if type(live) == "boolean" then return live end
        vis = tonumber(live) or 1
    end
    return vis ~= 0
end

---Shows or hides the selection live (atmo: the line only)
---@param visible boolean
local function setVisible(visible)
    local value = visible and "1" or "0"
    local atmo = atmoShown()
    local changed = false
    for _, v in ipairs(getSelected()) do
        if v.props.visible ~= value then
            v.props.visible = value
            if not atmo then set_obj_vis(v.id - 1, visible and 1 or 0) end
            changed = true
        end
    end
    if not changed then return end
    History.commit()
    if atmo then Rows.afterAtmoEdit() else refreshProperties() end
end

---Shape and Visible rows
---@param holder UIElement
---@param selected FileParserEnvObj[]
local function buildLooks(holder, selected)
    createChoiceRow("Shape", holder, {
        { label = "Box", value = "box" },
        { label = "Sphere", value = "sphere" },
        { label = "Pill", value = "cylinder" },
    }, sharedChoice(selected, getShape), function(shape) Rows.setSelectedProp("shape", shape) end,
        "Sides are kept, so the size may look different.")
    createChoiceRow("Visible", holder, {
        { label = "Shown", value = true },
        { label = "Hidden", value = false },
    }, sharedChoice(selected, isVisible), setVisible,
        atmoShown() and "Hidden: solid in Atmo Play but not drawn\n(invisible walls). The game's atmo ignores it."
            or "Hidden objects still collide.")
end


---Atmo row: To atmo on the Objects list, To objects on the Atmo list
---@param holder UIElement
local function buildLayerRow(holder)
    if atmoShown() then
        Rows.createToggleButtonRow("Atmo", holder, {
            { label = "To objects", active = false, onClick = function() MGE.AtmoLayer.toObjects() end },
        }, "To objects: back into the game (free ids allowing).\nSave keeps the atmo inside the mod.")
    else
        Rows.createToggleButtonRow("Atmo", holder, {
            { label = "To atmo", active = false, onClick = function() MGE.AtmoLayer.toAtmo() end },
        }, "Moves the selection to the atmo: drawn only, no\ncollisions, ids freed. Objects with joints stay.")
    end
end

---Color, Mass, Shape, Visible and Atmo as one block
---@param holder UIElement
---@param selected FileParserEnvObj[]
local function buildCoreRest(holder, selected)
    buildCoreProps(holder, selected) -- calls Rows.begin
    buildLooks(holder, selected)
    buildLayerRow(holder)
end

---@type EditorPanelModule
return {
    blocks = {
        { name = "measured", build = buildMeasuredRows, panel = "core", row = 0, rows = 3 },
        { name = "coreProps", build = buildCoreRest, panel = "core", row = 3, rows = 5 },
    },
    inputs = { rebuilt = { "position", "angle", "size", "color", "coreProps" } },
}
