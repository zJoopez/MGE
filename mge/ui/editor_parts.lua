-- Parts panels: Core and Advanced act on the selected body parts' lines, Joints on the selected joints', in
-- the player frame (as the mod file has them); Mirror adds the twins (ui/part_list.lua). Every edit is one
-- undo step and a reload
local Rows = MGE.EditorRows
local inwuts = Rows.inputs
local readInputs = Rows.readInputs
local createInputRow = Rows.createInputRow
local BodyParts = MGE.BodyParts

local NOT_SET = { "-", "-", "-" }

---A placeholder showing up to 4 decimals, trailing zeros dropped (float noise like 0.059999999 or 0.00000842
---reads 0.06 and 0; small body values like 0.0274 stay readable). The exact value stays for wheel steps
---@param v number
---@return { text: string, value: number }
local function hint(v)
    local s = (string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", ""))
    if s == "-0" then s = "0" end
    return { text = s, value = v }
end

---@param values number[]
---@return { text: string, value: number }[]
local function hints(values) return { hint(values[1]), hint(values[2]), hint(values[3]) } end

-- Gizmo rows (Pos, Rot, Sides) as the Player tab's: 2 decimals (plain numbers: the rows' own format), Rot in
-- whole degrees. The exact values stay for wheel steps

---@param values number[]
---@return number[]
local function gizmoHints(values) return { values[1], values[2], values[3] } end

---@param values number[] degrees
---@return { text: string, value: number }[]
local function degreeHints(values)
    local out = {}
    for i = 1, 3 do
        local whole = math.floor(values[i] + 0.5)
        out[i] = { text = tostring(whole == 0 and 0 or whole), value = values[i] } -- no "-0"
    end
    return out
end

---@param edit fun(section: BodySection, player: integer, names: string[], mirrorX: number?)
local function editSelected(edit) MGE.PartList.edit(edit) end

---The selected bodies' (or joints') lines read once per build
---@param kind "body"|"joint"? default body
---@return { player: integer, name: string, section: BodySection }[]
local function selectedParts(kind)
    local sections, out = {}, {}
    for _, part in ipairs(MGE.PartList.selected(kind or "body")) do
        sections[part.player] = sections[part.player] or BodyParts.section(MGE.ModData.parsed, part.player)
        out[#out + 1] = { player = part.player, name = part.name, section = sections[part.player] }
    end
    return out
end

-- Pos / Rot / Sides (Parts) and Pos (Joints) names, lit for the active gizmo tool
local partLabels, highlightPartLabels = Rows.gizmoLabels()
local jointLabels, highlightJointLabels = Rows.gizmoLabels()

---Pos / Rot / Sides / Shape rows
---@param holder UIElement
local function buildParts(holder)
    Rows.begin()
    local parts = selectedParts()
    local any = #parts > 0
    local first = parts[1]

    -- Pos: the selection's center (player frame); a typed axis moves them all by the difference
    local center = { 0, 0, 0 }
    for _, p in ipairs(parts) do
        local v = BodyParts.placed(p.section, p.name) or { 0, 0, 0 }
        for k = 1, 3 do center[k] = center[k] + v[k] / #parts end
    end
    local _
    inwuts.partPos, _, partLabels.move = createInputRow("Pos", holder, function(_, i)
        local typed = readInputs(inwuts.partPos, i)[i]
        if not typed or not any then return end
        local delta = typed - center[i]
        editSelected(function(section, player, names, mirrorX)
            BodyParts.transform(section, player, names, { pos = function(p)
                local q = { p[1], p[2], p[3] }
                q[i] = q[i] + delta
                return q
            end }, mirrorX)
        end)
    end, any and gizmoHints(center) or NOT_SET,
        "Center of the selected parts in the player's\nlayout (as the mod file). Joints between two\nselected parts move too.")

    -- Rot / Sides: the first part's line; a typed axis is set on all of them
    ---@return UIElement? label the row's name
    local function setAxisRow(label, key, help, opts)
        local shown = first and BodyParts.vector(first.section, "body", first.name, key) or nil
        local name = key == "rot" and "partRot" or "partSides"
        local inputs, _, labelButton = createInputRow(label, holder, function(_, i)
            local typed = readInputs(inwuts[name], i)[i]
            if not typed or not any or (key == "sides" and typed <= 0) then return end
            editSelected(function(section, player, names, mirrorX)
                BodyParts.transform(section, player, names, { [key] = function(v)
                    local q = { v[1], v[2], v[3] }
                    q[i] = typed
                    return q
                end }, mirrorX)
            end)
        end, shown and (key == "rot" and degreeHints(shown) or gizmoHints(shown))
            or (key == "rot" and { "0", "0", "0" } or NOT_SET), help, nil, opts)
        inwuts[name] = inputs
        return labelButton
    end
    partLabels.rotate = setAxisRow("Rot", "rot", "Rotation in degrees (the first part's shown),\nset on all selected.",
        { angle = true })
    partLabels.scale = setAxisRow("Sides", "sides",
        "Size (the first part's shown), set on all:\nbox X Y Z, sphere X radius,\npill X radius Y length.")
    highlightPartLabels()

    -- Shape: lit when the selection shares one
    local shared = nil
    for i, p in ipairs(parts) do
        local s = BodyParts.shape(p.section, p.name)
        if i == 1 then shared = s elseif s ~= shared then shared = nil end
    end
    Rows.createChoiceRow("Shape", holder, {
        { label = "Box", value = "box" },
        { label = "Sphere", value = "sphere" },
        { label = "Pill", value = "cylinder" },
    }, shared, function(shape)
        local skipped = false
        editSelected(function(section, _, names, mirrorX)
            for _, n in ipairs(BodyParts.withTwins(names, mirrorX ~= nil)) do
                if not BodyParts.canChangeShape(n) then skipped = true end
                BodyParts.setShape(section, n, shape)
            end
        end)
        if skipped then MGE.say("the head stays a sphere (another shape crashes the game)") end
    end, "Sides are converted to keep about the same size.\nThe head stays a sphere.")
end

-- Advanced rows: input name, label, line, smallest value (nil: any), help
local NUMBER_ROWS = {
    { "partDensity", "Density", "density", 0.0001, "Mass per size (classic 0.25)." },
    { "partFriction", "Friction", "friction", nil, "Grip (classic 0.3)." },
    { "partBounce", "Bounce", "bounce", nil, "Bounciness (classic 0.1)." },
    { "partHardness", "Hardness", "hardness", 0, "Classic 1." },
    { "partFlag", "Flag", "flag", 0, "The line's number as the mod writes it\n(classic 0, hands 1)." },
}

---Density / Friction / Bounce / Hardness / Flag: the first part's value shown, a typed one set on all
---@param holder UIElement
local function buildAdvanced(holder)
    Rows.begin()
    local parts = selectedParts()
    local first = parts[1]
    for _, row in ipairs(NUMBER_ROWS) do
        local name, key, min = row[1], row[3], row[4]
        local shown = first and BodyParts.number(first.section, first.name, key)
        inwuts[name] = createInputRow(row[2], holder, function()
            local typed = readInputs(inwuts[name], 1)[1]
            if not typed or not first or (min and typed < min) then return end
            editSelected(function(section, _, names, mirrorX)
                BodyParts.setNumber(section, names, key, typed, mirrorX ~= nil)
            end)
        end, { shown and hint(shown) or "-" }, row[5] .. "\nSet on all selected.", nil,
            key == "flag" and { whole = true } or nil)
    end
end

---Edits the selected joints (Mirror: their twins too), one undo step and a reload
---@param fn fun(section: BodySection, joints: string[], mirrorX: number?)
local function editJoints(fn)
    MGE.PartList.edit(function(section, _, _, mirrorX, joints)
        if #joints > 0 then fn(section, joints, mirrorX) end
    end)
end

---Pos / Radius / Strength / Velocity / Axis / Range rows for the selected joints (player frame). Mirror: twins'
---pos mirrored, their other lines the same (as the classic body's twins have them)
---@param holder UIElement
local function buildJoints(holder)
    Rows.begin()
    local joints = selectedParts("joint")
    local any = #joints > 0
    local first = joints[1]
    local fmt = MGE.FileHandler.formatNumbers

    local center = { 0, 0, 0 }
    for _, j in ipairs(joints) do
        local v = BodyParts.jointPlaced(j.section, j.name) or { 0, 0, 0 }
        for k = 1, 3 do center[k] = center[k] + v[k] / #joints end
    end
    local _
    inwuts.jointPartPos, _, jointLabels.move = createInputRow("Pos", holder, function(_, i)
        local typed = readInputs(inwuts.jointPartPos, i)[i]
        if not typed or not any then return end
        local delta = typed - center[i]
        editJoints(function(section, names, mirrorX)
            BodyParts.transformJoints(section, names, function(p)
                local q = { p[1], p[2], p[3] }
                q[i] = q[i] + delta
                return q
            end, mirrorX)
        end)
    end, any and gizmoHints(center) or NOT_SET, "Center of the selected joints in the player's\nlayout (as the mod file).")

    -- one number each: the first joint's shown, a typed one set on all
    local NUMBERS = {
        { "jointPartRadius", "Radius", "radius", 0.0001, "Joint ball size (classic 0.11-0.18)." },
        { "jointPartStrength", "Strength", "strength", 0, "Muscle strength (classic 1-4)." },
        { "jointPartVelocity", "Velocity", "velocity", 0, "Muscle speed (classic 5-60)." },
    }
    for _, row in ipairs(NUMBERS) do
        local name, key, min = row[1], row[3], row[4]
        local shown = first and BodyParts.jointNumber(first.section, first.name, key)
        inwuts[name] = createInputRow(row[2], holder, function()
            local typed = readInputs(inwuts[name], 1)[1]
            if not typed or not any or typed < min then return end
            editJoints(function(section, names, mirrorX)
                BodyParts.setJointLine(section, names, key, MGE.FileHandler.formatNumber(typed), mirrorX ~= nil)
            end)
        end, { shown and hint(shown) or "-" }, row[5] .. "\nSet on all selected.")
    end

    -- Axis / Range: the first joint's; a typed number set on all (each keeps its other numbers)
    local axis = first and BodyParts.vector(first.section, "joint", first.name, "axis")
    inwuts.jointPartAxis = createInputRow("Axis", holder, function(_, i)
        local typed = readInputs(inwuts.jointPartAxis, i)[i]
        if not typed or not any then return end
        editJoints(function(section, names, mirrorX)
            for _, n in ipairs(names) do
                local a = BodyParts.vector(section, "joint", n, "axis") or { 0, 0, 0 }
                a[i] = typed
                BodyParts.setJointLine(section, { n }, "axis", fmt(a[1], a[2], a[3]), mirrorX ~= nil)
            end
        end)
    end, axis and hints(axis) or NOT_SET, "The hinge's axis in the player's layout.\nSet on all selected.")
    local range = first and BodyParts.range(first.section, first.name)
    inwuts.jointPartRange = createInputRow("Range", holder, function(_, i)
        local typed = readInputs(inwuts.jointPartRange, i)[i]
        if not typed or not any then return end
        editJoints(function(section, names, mirrorX)
            for _, n in ipairs(names) do
                local r = BodyParts.range(section, n) or { 0, 0 }
                r[i] = typed
                BodyParts.setJointLine(section, { n }, "range", fmt(r[1], r[2]), mirrorX ~= nil)
            end
        end)
    end, range and { hint(range[1]), hint(range[2]) } or { "-", "-" },
        "How far it bends: its two limits as the mod\nwrites them (classic elbow 2.3, 0.05).\nSet on all selected.")
    highlightJointLabels()
end

---@type EditorPanelModule
return {
    blocks = {
        { name = "parts", build = buildParts, panel = "parts", row = 0, rows = 4 },
        { name = "partsAdvanced", build = buildAdvanced, panel = "partsAdvanced", row = 0, rows = #NUMBER_ROWS },
        { name = "partsJoints", build = buildJoints, panel = "partsJoints", row = 0, rows = 6 },
    },
    inputs = {
        rebuilt = { "partPos", "partRot", "partSides", "partDensity", "partFriction", "partBounce", "partHardness",
            "partFlag", "jointPartPos", "jointPartRadius", "jointPartStrength", "jointPartVelocity", "jointPartAxis",
            "jointPartRange" },
    },
}
