-- The Atmo list's rows on its Advanced tab (where objects have Model and Ids): how props behave in
-- Atmo Play. Collision (`prop_collide <player> <dynamic> <atmo>`): Player / Dynamic make a prop real near
-- those (both off: never real, no pool object); Atmo: flying props hit each other. Motion
-- (`prop_motion`): Active moves from the first frame, off waits to be reached; default: active with
-- thrust. Undo steps without reloads
local Rows = MGE.EditorRows
local ModData = MGE.ModData
local History = MGE.History
local sharedChoice = Rows.sharedChoice

local Colliders = MGE.AtmoPlay.Colliders
local Flight = MGE.AtmoPlay.Flight

---Sets one Collision toggle (1 player, 2 dynamic, 3 atmo) on the selected atmo objects, one undo step.
---No line when all are on; legacy prop_hits / prop_real lines go
---@param which integer
---@param on boolean
local function setCollision(which, on)
    local changed = false
    for _, obj in ipairs(ModData.getSelectedAtmo()) do
        local t = { Colliders.collision(obj.props) }
        t[which] = on
        local line = nil -- all on: no line
        if not (t[1] and t[2] and t[3]) then
            line = string.format("%d %d %d", t[1] and 1 or 0, t[2] and 1 or 0, t[3] and 1 or 0)
        end
        if obj.props.prop_collide ~= line or obj.props.prop_hits or obj.props.prop_real then
            obj.props.prop_collide, obj.props.prop_hits, obj.props.prop_real = line, nil, nil
            changed = true
        end
    end
    if not changed then return end
    History.commit()
    Rows.afterAtmoEdit()
end

---Whether an atmo object's thrust pushes (zero force or step: no)
local function hasThrust(obj)
    return Flight.parseThrust(obj.props.thrust) ~= nil
end

---Whether an atmo object starts active (its prop_motion, else whether it has a thrust)
local function startsActive(obj)
    return Colliders.startsActive(obj.props, hasThrust(obj))
end

---Sets Motion's Active on the selected atmo objects (no line for the default), one undo step
---@param on boolean
local function setActive(on)
    local changed = false
    for _, obj in ipairs(ModData.getSelectedAtmo()) do
        local line = nil -- the default: no line
        if on ~= hasThrust(obj) then line = on and "1" or "0" end
        if obj.props.prop_motion ~= line then
            obj.props.prop_motion = line
            changed = true
        end
    end
    if not changed then return end
    History.commit()
    Rows.afterAtmoEdit()
end

---Collision and Motion rows (nothing on the Objects list)
---@param holder UIElement
---@param selected FileParserEnvObj[] the selected atmo objects
local function buildAtmoRows(holder, selected)
    Rows.begin()
    if not Rows.atmoShown() then return end
    -- lit when all selected have it on; a click sets all
    local items = {}
    for which, label in ipairs({ "Player", "Dynamic", "Atmo" }) do
        local lit = sharedChoice(selected, function(obj) return (select(which, Colliders.collision(obj.props))) end)
            == true
        items[which] = { label = label, active = lit, onClick = function() setCollision(which, not lit) end }
    end
    Rows.createToggleButtonRow("Collision", holder, items,
        "Props in Atmo Play. Player / Dynamic: becomes\nreal near players / dynamic objects (both off:\n" ..
        "never real). Atmo: hits other flying props.")
    local active = sharedChoice(selected, startsActive) == true
    Rows.createToggleButtonRow("Motion", holder, {
        { label = "Active", active = active, onClick = function() setActive(not active) end },
    }, "Props in Atmo Play. Active: moves from the first\nframe. Off: still until something reaches it.\n" ..
        "Default: on with thrust.")
end

---@type EditorPanelModule
return {
    blocks = {
        { name = "atmoRows", build = buildAtmoRows, panel = "advanced", row = 4, rows = 2 },
    },
}
