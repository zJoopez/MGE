-- Joints list's Properties tab: each value applies to every selected joint in one undo step and a
-- reload (no live setters). Pos without a line ("none") means the game locks the objects together; a
-- typed value or Recenter makes a hinge. Axis is world-space and its length matters (0 0 90 is
-- unstable). Placeholders: "mixed" when joints differ, DEFAULTS for missing lines

local Rows = MGE.EditorRows
local Joints = MGE.Joints
local inwuts = Rows.inputs

local ROWS = MGE.Widgets.PANEL_ROWS

local INPUT_LISTS = { "jointPos", "jointAxis", "jointRange", "jointStrength", "jointVelocity", "jointType" }

---@return FileParserEnvObjJoint[] read at apply time: reloads replace the joint tables
local function selectedJoints()
    return MGE.Main.selectedJointList()
end

---Full width text line, for the hints without a selection
---@param holder UIElement
---@param text string
---@param row integer 0-based
local function addLine(holder, text, row)
    local line = holder:addChild({
        pos = { 8, row * (holder.size.h / ROWS) },
        size = { holder.size.w - 16, holder.size.h / ROWS },
    })
    line:addAdaptedText(text, nil, nil, MGE.Widgets.FONT, LEFTMID, MGE.Widgets.TEXT_SCALE, nil, nil)
end

-- values for missing lines: the game modmaker's (and nearly every mod's); env joints have no getters
local DEFAULTS = { axis = "0 0 0", range = "0 0", strength = "0", velocity = "0", visible = "0", jointtype = "0" }

---@param joint FileParserEnvObjJoint|FileParserEnvObj
---@param key string
---@return string? the line's value, or its default (nil for pos: no default anchor)
local function valueOf(joint, key)
    return joint.props[key] or DEFAULTS[key]
end

---Placeholder for number `index` of a `count`-number prop: the shared number, or "mixed"
---@param joints FileParserEnvObjJoint[]
---@param key string
---@param index integer
---@param count integer
---@return InputPlaceholder
local function hintOf(joints, key, index, count)
    return Rows.sharedChoice(joints, function(joint)
        local value = valueOf(joint, key)
        if value == nil then return "-" end
        return Joints.parseNumbers(value, count)[index]
    end) or "-"
end

---A row of one prop's numbers; each field sets its number on every selected joint
---@param holder UIElement
---@param joints FileParserEnvObjJoint[]
---@param label string
---@param name string inwuts list
---@param key string prop
---@param count integer numbers in the prop
---@param help string
local function numberRow(holder, joints, label, name, key, count, help)
    local hints = {}
    for i = 1, count do hints[i] = hintOf(joints, key, i, count) end
    inwuts[name] = Rows.createInputRow(label, holder, function(inputs, index)
        local value = tonumber(inputs[index].textfieldstr[1])
        if value then Joints.setComponent(selectedJoints(), key, index, count, value) end
    end, hints, help)
end

---Sets a whole prop to one value on the selected joints
---@param key string
---@param value string
local function setAll(key, value)
    Joints.setProps(selectedJoints(), key, function() return value end)
end

---Pos row: the anchors' center; a typed axis moves them together
---@param holder UIElement
---@param joints FileParserEnvObjJoint[]
local function buildPos(holder, joints)
    -- only locked joints: "none", the wheel steps from their objects' midpoint
    local target = Joints.target(joints)
    local hints = target and target.pivot() ---@type InputPlaceholder[]?
    if not hints then
        local sum, n = { 0, 0, 0 }, 0
        for _, joint in ipairs(joints) do
            local m = Joints.jointMidpoint(joint)
            if m then
                for k = 1, 3 do sum[k] = sum[k] + m[k] end
                n = n + 1
            end
        end
        hints = {}
        for k = 1, 3 do hints[k] = { text = "none", value = n > 0 and sum[k] / n or nil } end
    end
    inwuts.jointPos = Rows.createInputRow("Pos", holder, function(inputs, index)
        local value = tonumber(inputs[index].textfieldstr[1])
        if value then Joints.setPosAxis(selectedJoints(), index, value) end
    end, hints,
        "The point it turns around (world coordinates).\n" ..
        "None: the game locks the two objects together,\n" ..
        "a typed value makes it a hinge there.")
end

---Type row: jointtype, a whole number
---@param holder UIElement
---@param joints FileParserEnvObjJoint[]
local function buildType(holder, joints)
    local hint = Rows.sharedChoice(joints, function(joint) return valueOf(joint, "jointtype") end) or "-"
    inwuts.jointType = Rows.createInputRow("Type", holder, function(inputs)
        local value = tonumber(inputs[1].textfieldstr[1])
        if value then setAll("jointtype", tostring(math.floor(value))) end
    end, { hint }, "The jointtype line, a number (most mods write 0).", nil, { whole = true })
end

---Visible row
---@param holder UIElement
---@param joints FileParserEnvObjJoint[]
local function buildVisible(holder, joints)
    local visible = Rows.sharedChoice(joints, function(joint) return valueOf(joint, "visible") end)
    Rows.createChoiceRow("Visible", holder, {
        { label = "Visible", value = "1" },
        { label = "Hidden", value = "0" },
    }, visible, function(value) setAll("visible", value) end,
        "The visible line, lit when all selected joints\nhave it. Without the line: hidden.")
end

---@param holder UIElement
local function buildJoints(holder)
    Rows.begin()
    for _, name in ipairs(INPUT_LISTS) do inwuts[name] = {} end -- unbuilt rows have none
    local joints = selectedJoints()
    if #joints == 0 then -- the selected slot can be empty
        addLine(holder, "The selected slot is empty: link two objects on the", 0)
        addLine(holder, "Link tab first, then set the values here.", 1)
        return
    end

    buildPos(holder, joints)
    numberRow(holder, joints, "Axis", "jointAxis", "axis", 3,
        "Turning direction in world space, any numbers\n" ..
        "(0 0 1, 0.5 0 1...), negative reverses it. Very\n" ..
        "big ones like 0 0 90 can make it unstable.")
    numberRow(holder, joints, "Range", "jointRange", "range", 2,
        "Limits, high then low (1.5: 90 degrees, 3: 180).\n" ..
        "4 -4 with a motor: keeps turning.")
    numberRow(holder, joints, "Strength", "jointStrength", "strength", 1,
        "The joint's strength (its motor force).")
    numberRow(holder, joints, "Velocity", "jointVelocity", "velocity", 1,
        "The joint's motor velocity.")
    buildType(holder, joints)
    buildVisible(holder, joints)
    Rows.createToggleButtonRow("", holder, {
        { label = "Recenter", active = false, onClick = function() Joints.centerPos(selectedJoints()) end },
    }, "Puts each selected joint's anchor halfway\nbetween its two objects (a locked one: a hinge).")
end

---@type EditorPanelModule
return {
    blocks = { { name = "joint", build = buildJoints, panel = "joint", row = 0, rows = ROWS } },
    inputs = { rebuilt = INPUT_LISTS },
}
