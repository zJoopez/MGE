-- Shared editor panel pieces: rows (label, inputs or buttons, "?" help), value helpers and the single
-- value property rows. Builders call Rows.begin(), then rows stack from the holder's top

---@class EditorRows
local Rows = {}
MGE.EditorRows = Rows

local Widgets = MGE.Widgets
local History = MGE.History
local ModData = MGE.ModData

---@type table<string, UIElement[]> input fields by list name (pos, color, thrust...)
Rows.inputs = {}

-- set by ui/editor.lua: rebuild the rows that show current values
Rows.refreshProperties = function() end
Rows.refreshMeasured = function() end
---@type fun(names: string[]) rebuilds the named blocks (EditorBlock.name)
Rows.refreshBlocks = function() end
local function refreshProperties() Rows.refreshProperties() end

---@return boolean the Atmo list shows (the panels edit atmo objects' lines)
function Rows.atmoShown() return MGE.Main ~= nil and MGE.Main.listTab == "atmo" end

---After committed atmo line edits: refresh the rows, or reload if a playable mod's pools no longer fit
function Rows.afterAtmoEdit()
    if not (MGE.Playable and MGE.Playable.reloadIfSplitChanged()) then Rows.refreshProperties() end
end

local totalHeight = 0

---Starts a block of rows at the top of its holder
function Rows.begin()
    totalHeight = 0
end

local function updateContentHeight(height)
    totalHeight = totalHeight + height
end

---Numbers typed in a row's inputs, nil for empty ones. With `only`, just that input (Enter's field)
---@param inputs UIElement[]
---@param only integer?
---@return (number?)[]
local function readInputs(inputs, only)
    local values = {}
    for i, input in ipairs(inputs) do
        if not only or i == only then values[i] = tonumber(input.textfieldstr[1]) end
    end
    return values
end

---@param input UIElement
---@param x number
---@param y number
---@return boolean the screen point is on the input
local function isOver(input, x, y)
    return x >= input.pos.x and x <= input.pos.x + input.size.w and y >= input.pos.y and y <= input.pos.y + input.size.h
end

---Sets a text field's text, cursor at the end
---@param input UIElement
---@param text string
function Rows.setText(input, text)
    input.textfieldstr[1] = text
    input.textfieldindex = #text
end

---Value shared by the objects, "mixed" when they differ, nil for no objects
---@param objects FileParserEnvObj[]
---@param read fun(obj: FileParserEnvObj): any never nil
local function sharedChoice(objects, read)
    local value
    for _, obj in ipairs(objects) do
        local v = read(obj)
        if value == nil then
            value = v
        elseif value ~= v then
            return "mixed"
        end
    end
    return value
end


---Placeholder text: two decimals, never "-0.00"
---@param value number
---@return string
local function formatHint(value)
    local s = string.format("%.2f", value)
    if s == "-0.00" then s = "0.00" end
    return s
end

---@param values number[]
---@return string[]
local function formatHints(values)
    local hints = {}
    for i = 1, 3 do hints[i] = formatHint(values[i]) end
    return hints
end

---A number as field text: no trailing zeros, "-0" as "0"
---@param value number
---@param decimals integer? at most this many, default 4
---@return string
local function formatStep(value, decimals)
    local s = string.format("%." .. (decimals or 4) .. "f", value):gsub("0+$", ""):gsub("%.$", "")
    if s == "-0" then s = "0" end
    return s
end
Rows.formatNumberText = formatStep

---Where a wheel step starts: the typed number, else the placeholder's leading number, else 0
---@param text string?
---@param placeholder string?
---@return number
function Rows.wheelBase(text, placeholder)
    -- "8 obj" (Generate's Amount) is 8
    return tonumber(text) or tonumber(tostring(placeholder or ""):match("^%s*(-?%d*%.?%d+)")) or 0
end

---@alias InputMode
---| "live" # editor rows: wheel / leaving applies, then the field empties to show the value. Esc drops typing
---| "keep" # Settings: wheel / leaving applies, the value stays
---| "form" # Generate, Convert Map: an action reads the fields (Enter runs it); the wheel only edits text

---@type UIElement? the field being applied: a rebuild doesn't restore its text
Rows.applying = nil

---Applies a field the way its mode says
---@param input UIElement
---@param onInputFunc fun()
---@param mode InputMode
---@param mergeKey string? History.mergeKey: wheel steps on one field are one undo step
local function applyField(input, onInputFunc, mode, mergeKey)
    if mode ~= "live" then
        onInputFunc()
        return
    end
    local text = input.textfieldstr[1]
    if text == "" then return end
    if tonumber(text) then
        Rows.applying = input
        History.mergeKey = mergeKey
        local ok, err = pcall(onInputFunc)
        History.mergeKey = nil
        Rows.applying = nil
        if not ok then MGE.say(tostring(err)) end
    end
    -- empty again: the placeholder shows the new value
    if not input.destroyed then input:clearTextfield() end
end

---Mouse wheel over a number field steps the value by the Config steps (Shift: fine / 1 degree). toriui
---sends the wheel to every scrollEnabled element, so the field checks the cursor (MOUSE_X / Y) itself
---@param input UIElement
---@param placeholder string the field's placeholder text (toriui's text field doesn't keep it)
---@param exact number? the value the placeholder shows rounded: an empty field steps from this
---@param apply fun(mergeKey: string?)? applies the field (applyField with its mode), nil for form fields
---@param opts InputOptions
local function addWheelStep(input, placeholder, exact, apply, opts)
    local whole, angle = opts.whole, opts.angle
    local press = input.btnDown
    input.scrollEnabled = true
    input.btnDown = function(btn, x, y)
        if btn ~= 4 and btn ~= 5 then return press(btn, x, y) end
        if not input:isDisplayed() or not isOver(input, MOUSE_X or x, MOUSE_Y or y) then
            return false -- not this field: pass it on
        end
        local typed = input.textfieldstr[1]
        local value = (tonumber(typed) == nil and exact) or Rows.wheelBase(typed, placeholder)
        local Config, shift = MGE.Config, get_keyboard_shift() ~= 0
        local step ---@type number
        if angle then
            step = shift and 1 or Config.rotateStep
        elseif whole then
            step = 1
        else
            step = shift and Config.wheelFineStep or Config.wheelStep
        end
        local after = value + (btn == 4 and step or -step) -- 4: up
        if whole then after = math.floor(after + 0.5) end
        local text = formatStep(after)
        Rows.setText(input, text)
        if apply then apply(Rows.fieldKey(input)) end -- merged while the mouse stays on the field
        return true
    end
end

---A field's merge key: its screen position (stable across rebuilds)
---@param input UIElement
---@return string
function Rows.fieldKey(input)
    return "field " .. math.floor(input.pos.x) .. "," .. math.floor(input.pos.y)
end

-- Fields left by a click are applied in draw3d, outside toriui's drawing: applying mid-draw rebuilt the
-- panel while it drew and every tab's rows flashed
---@type fun()[]
local leftFields = {}
local LEAVE_HOOK = MGE.hookname .. "_rows"
add_hook("draw3d", LEAVE_HOOK, function()
    if #leftFields == 0 then return end
    local queue = leftFields
    leftFields = {}
    for _, apply in ipairs(queue) do
        local ok, err = pcall(apply)
        if not ok then MGE.say(tostring(err)) end
    end
end)
table.insert(MGE.onQuit, function() remove_hooks(LEAVE_HOOK) end)

---Leaving a field applies what's typed (queued to leftFields); the mouse leaving ends its merged undo
---step. Polled each frame: toriui has no focus-lost callback
---@param input UIElement
---@param apply fun()
local function applyOnLeave(input, apply)
    local focused = false
    Widgets.addDrawBefore(input, function()
        local now = input.keyboard == true
        if focused and not now and input.textfieldstr[1] ~= "" then leftFields[#leftFields + 1] = apply end
        focused = now
        if History.lastMerge and not isOver(input, MOUSE_X, MOUSE_Y) then
            History.endMerge(Rows.fieldKey(input))
        end
    end)
end

---@class InputOptions
---@field mode InputMode? default "live"
---@field whole boolean? wheel results rounded to whole numbers
---@field angle boolean? degrees: the wheel steps by Config.rotateStep (Shift: 1)

---@alias InputPlaceholder string|number|{ text: string, value: number? }
---A placeholder's shown text and the exact value the wheel steps from. Numbers show rounded; { text,
---value } shows text and steps from value; plain text steps from its leading number
---@param placeholder InputPlaceholder?
---@return string text, number? value
local function resolvePlaceholder(placeholder)
    if type(placeholder) == "number" then return formatHint(placeholder), placeholder end
    if type(placeholder) == "table" then return placeholder.text, placeholder.value end
    return placeholder or "0", nil
end

---@param placeholder InputPlaceholder? shown while empty, defaults to "0" (resolvePlaceholder)
---@param opts InputOptions? default: a live decimal field
local function createInput(container, onInputFunc, placeholder, opts)
    opts = opts or {}
    local mode = opts.mode or "live"
    local text, exact = resolvePlaceholder(placeholder)
    local input = TBMenu:spawnTextField2(container, nil, "",
        text,
        {
            inputType = 2,
            textfield = true,
            returnKeyType = KEYBOARD_RETURN.SEND,
            isNumeric = true,
            allowDecimal = true,
            allowNegative = true,
            textAlign = CENTER,
            fontId = MGE.Widgets.FONT,
            darkerMode = true, -- matches the panel buttons
            textScale = MGE.Widgets.TEXT_SCALE_SMALL,
        })
    ---@param mergeKey string?
    local function apply(mergeKey) applyField(input, onInputFunc, mode, mergeKey) end
    input:addKeyboardHandlers(mode == "live" and function(key)
        if key == 27 then input:clearTextfield() end -- Esc drops the typing
    end or nil, function(key)
        if key ~= 13 then return end --enter
        apply()
    end)
    if mode ~= "form" then applyOnLeave(input, apply) end
    addWheelStep(input, text, exact, mode ~= "form" and apply or nil, opts)
    return input
end

---Row with a label column and an optional "?" icon; returns the space between them
---@param label string
---@param parent UIElement
---@param help string? hover text of the "?" icon
---@param onLabelClick function? makes the label a button
---@return UIElement row, number contentX, number contentW, UIElement labelElement (setHighlighted lights it)
local function createRow(label, parent, help, onLabelClick)
    local row = parent:addChild({
        pos = { 0, totalHeight },
        size = { parent.size.w, MGE.Widgets.ROW_H },
        interactive = true,
    }, true)

    local labelW = MGE.Widgets.px(66)
    local helpSize = MGE.Widgets.ROW_H - 6
    local helpW = help and helpSize + 8 or 0
    local labelButton
    if onLabelClick then
        local inset = Widgets.INSET
        labelButton = Widgets.button(row, { x = inset, y = inset, w = labelW - inset * 2, h = row.size.h - inset * 2 }, label, onLabelClick,
            Widgets.TEXT_SCALE, Widgets.PANEL_STYLE)
    else
        -- see-through until highlighted
        local inset = Widgets.INSET
        labelButton = row:addChild({
            pos = { inset, inset },
            size = { labelW - inset * 2, row.size.h - inset * 2 },
            bgColor = { 0, 0, 0, 0 },
        }, true)
        labelButton.plainLabel = true
        labelButton:addAdaptedText(label, nil, nil, MGE.Widgets.FONT, CENTERMID, MGE.Widgets.TEXT_SCALE, nil, nil)
    end

    if help then
        Widgets.helpIcon(row, -helpSize - 2, (row.size.h - helpSize) / 2, helpSize, help, nil, Widgets.PANEL_STYLE)
    end

    updateContentHeight(row.size.h)
    return row, labelW, row.size.w - labelW - helpW, labelButton
end

---A row of equal inputs
---@param label string
---@param parent UIElement
---@param func fun(inputs: UIElement[], index: integer) applies input `index`
---@param placeholders InputPlaceholder[] one per input
---@param help string?
---@param onLabelClick function? see createRow
---@param opts InputOptions? for every input
---@return UIElement[] inputs, UIElement row, UIElement? labelButton see createRow
local function createInputRow(label, parent, func, placeholders, help, onLabelClick, opts)
    local row, contentX, contentW, labelButton = createRow(label, parent, help, onLabelClick)
    local columnSize = contentW / #placeholders
    local inputs = {}
    for i, placeholder in ipairs(placeholders) do
        local inputContainer = row:addChild({
            pos = { contentX + (i - 1) * columnSize, 0 },
            size = { columnSize, row.size.h },
            interactive = true,
        }, true)
        inputs[i] = createInput(inputContainer, function() func(inputs, i) end, placeholder, opts)
    end
    return inputs, row, labelButton
end

---A row with a wide button (opens a picker) and a square trash icon button
---@param label string
---@param parent UIElement
---@param help string
---@param text string the wide button's text
---@param onPick fun()
---@param onNone fun() the trash icon
---@param noneHelp string the trash icon's hover text
local function createPickRow(label, parent, help, text, onPick, onNone, noneHelp)
    local row, contentX, contentW = createRow(label, parent, help)
    local gap, inset = Widgets.GAP, Widgets.INSET
    local h = row.size.h - inset * 2
    local pickW = contentW - inset * 2 - gap - h
    Widgets.button(row, { x = contentX + inset, y = inset, w = pickW, h = h }, text, onPick, nil, Widgets.PANEL_STYLE)
    local none = Widgets.iconButton(row, { x = contentX + inset + pickW + gap, y = inset, w = h, h = h },
        "../textures/menu/general/buttons/trash.tga", onNone, Widgets.PANEL_STYLE)
    Widgets.popupBelow(none, noneHelp)
end
Rows.createPickRow = createPickRow

---Lights a button as the current choice, or restores its look (plain labels go see-through)
---@param btn UIElement? nil and destroyed buttons are skipped
---@param on boolean
local function setHighlighted(btn, on)
    if btn and not btn.destroyed then
        btn.bgColor = on and Widgets.ACTIVE_COLOR or (btn.plainLabel and { 0, 0, 0, 0 } or Widgets.PANEL_STYLE.bg)
    end
end

---Holder for a row's buttons, lined up with the number fields
---@return UIElement
local function buttonHolder(row, contentX, contentW)
    return row:addChild({
        pos = { contentX + Widgets.INSET, Widgets.INSET },
        size = { contentW - Widgets.INSET * 2, row.size.h - Widgets.INSET * 2 },
    }, true)
end

---A row of choice buttons, the current one lit
---@param label string
---@param parent UIElement
---@param choices { label: string, value: any }[]
---@param current any nil or "mixed" lights nothing
---@param onPick fun(value: any)
---@param help string?
---@return UIElement[] buttons in choice order
local function createChoiceRow(label, parent, choices, current, onPick, help)
    local holder = buttonHolder(createRow(label, parent, help))
    local items = {}
    for i, choice in ipairs(choices) do
        items[i] = { label = choice.label, onClick = function() onPick(choice.value) end }
    end
    local buttons = Widgets.buttonRow(holder, 0, holder.size.h, items, Widgets.GAP, nil, Widgets.PANEL_STYLE)
    for i, btn in ipairs(buttons) do
        if choices[i].value == current then setHighlighted(btn, true) end
    end
    return buttons
end

---A row of on/off buttons (any number on), active ones lit
---@param label string
---@param parent UIElement
---@param toggles { label: string, active: boolean, onClick: function }[]
---@param help string?
local function createToggleButtonRow(label, parent, toggles, help)
    local holder = buttonHolder(createRow(label, parent, help))
    for i, btn in ipairs(Widgets.buttonRow(holder, 0, holder.size.h, toggles, Widgets.GAP, nil, Widgets.PANEL_STYLE)) do
        if toggles[i].active then btn.bgColor = Widgets.ACTIVE_COLOR end
    end
end

-- Single value properties. Without a live setter (friction, hardness) they apply by reloading.
-- default: the game's value without the line; decimals: as the game's modmaker writes them
---@class EditorProperty
---@field min number? the lowest value it takes, nil: any (friction can be negative)
---@field default number
---@field decimals integer
---@field setter (fun(id: integer, value: number))?
---@field getter (fun(id: integer): number?)?

---@type table<string, EditorProperty>
local PROPERTIES = {
    mass = { min = 0.0001, default = 0.1, decimals = 4, -- zero breaks physics
        setter = function(id, v) set_obj_mass(id, v) end, getter = function(id) return get_obj_mass(id) end },
    friction = { default = 10000, decimals = 2 }, -- negative is valid
    bounce = { min = 0, default = 0.1, decimals = 6,
        setter = function(id, v) set_obj_bounce(id, v) end, getter = function(id) return get_obj_bounce(id) end },
    -- points multiplier on player contact, no live API; default 0 (older docs say 1)
    hardness = { min = 0, default = 0, decimals = 6 },
}

---As the game writes it, e.g. mass 0.1 -> "0.1000"
---@param property EditorProperty
---@param value number
---@return string
local function formatProperty(property, value)
    return string.format("%." .. property.decimals .. "f", value)
end

---Sets a property on the edit selection from an input (atmo: lines only)
---@param key "mass"|"friction"|"bounce"|"hardness"
---@param input UIElement
local function setProperty(key, input)
    local value = tonumber(input.textfieldstr[1])
    if not value then return end
    local atmo = Rows.atmoShown()
    local selectedObjects = ModData.getEditSelection()
    if #selectedObjects == 0 then return end

    local property = PROPERTIES[key]
    if property.min then value = math.max(value, property.min) end
    for _, v in ipairs(selectedObjects) do
        v.props[key] = formatProperty(property, value)
        if property.setter and not atmo then property.setter(v.id - 1, value) end
    end
    History.commit()
    if atmo then
        Rows.afterAtmoEdit()
    elseif property.setter then
        refreshProperties()
    else
        MGE.apply()
    end
end

local PROPERTY_HELP = {
    mass = "Applies mass\n\"mixed\": the selected objects differ.",
    friction = "Applied by saving, the game can't change it live.",
    bounce = "Bounciness. \"mixed\": the selected objects differ.",
    hardness = "Points multiplier when it touches a player.\n0 (default): no points, still damages. 0.5: half,\n1: full, 2: double. Applied by saving.",
}

---Single value rows; placeholders show the selection's value
---@param holder UIElement
---@param selected FileParserEnvObj[]
---@param entries string[][] { label, key } pairs
---@return UIElement[] inputs
local function buildPropertyRows(holder, selected, entries)
    local inputs = {}
    for _, entry in ipairs(entries) do
        local label, key = entry[1], entry[2]
        local property = PROPERTIES[key] ---@type EditorProperty
        -- the line, else the live value, else the default ("mixed" when they differ)
        local hint = sharedChoice(selected, function(obj)
            local value = tonumber(obj.props[key])
                or (property.getter and obj.kind ~= "atmo" and property.getter(obj.id - 1))
            return formatProperty(property, value or property.default)
        end) or formatProperty(property, property.default)
        local row = createInputRow(label, holder, function(rowInputs) setProperty(key, rowInputs[1]) end,
            { hint }, PROPERTY_HELP[key])
        table.insert(inputs, row[1])
    end
    return inputs
end

---Writes a prop on the edit selection; commits and applies if anything changed
---@param key string
---@param value string?
local function setSelectedProp(key, value)
    local changed = false
    for _, v in ipairs(ModData.getEditSelection()) do
        if v.props[key] ~= value then
            v.props[key] = value
            changed = true
        end
    end
    if not changed then return end
    History.commit()
    if Rows.atmoShown() then Rows.afterAtmoEdit() else MGE.apply() end
end


Rows.readInputs = readInputs
Rows.sharedChoice = sharedChoice
Rows.formatHints = formatHints
Rows.formatHint = formatHint
Rows.createInput = createInput
Rows.createRow = createRow
Rows.createInputRow = createInputRow
Rows.createChoiceRow = createChoiceRow
Rows.setHighlighted = setHighlighted

---Row names lit for the active gizmo tool: a panel fills labels.move / .rotate / .scale as it builds
---and calls highlight after rebuilds (tool changes call it too). One per panel, at load
---@return table<string, UIElement?> labels, fun() highlight
function Rows.gizmoLabels()
    local labels = {}
    local function highlight()
        for mode, label in pairs(labels) do setHighlighted(label, mode == MGE.Gizmo.mode) end
    end
    table.insert(MGE.Gizmo.modeListeners, highlight)
    return labels, highlight
end
Rows.createToggleButtonRow = createToggleButtonRow
Rows.buildPropertyRows = buildPropertyRows
Rows.setSelectedProp = setSelectedProp

return Rows
