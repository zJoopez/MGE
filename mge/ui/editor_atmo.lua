-- The Atmo list's own row on its Advanced tab (the objects' Advanced panel, ui/editor_advanced.lua: Friction,
-- Bounce, Hardness and Flags first; row 4 here, where the objects have Model and Ids): how a prop (Static off) meets
-- things in Atmo Play, `prop_collide <player> <dynamic> <atmo>` (the game's atmo skips the line):
--   Collision: Player / Dynamic: it becomes real (a pool object carries it) near players / near real dynamic objects
--              (a real one collides with everything real); both off: never real, needs no pool object.
--              Atmo: flying drawn, it hits the other props (else passes through them)
-- and how a prop moves, `prop_motion <start>` (no line: the default):
--   Motion:    Active: it moves from the fight's first frame (falls, tumbles and settles under gravity, flies its
--              thrust) before anything comes near; off: it sits still until something reaches it (a player or
--              dynamic object takes it, a flying prop hits it). Default: active with a thrust, else waiting.
--              The player's Far props: Pause still pauses it far from everyone (their choice, for their computer)
-- Other atmo lines (no_depth, min_level, count, rotate, parent...) aren't edited here: kept as they are.
-- Playable (the whole mod) is on the World tab (ui/editor_misc.lua).
-- Atmo objects aren't in the .tbm: changes here are an undo step, no reload.
local Rows = MGE.EditorRows
local ModData = MGE.ModData
local History = MGE.History
local sharedChoice = Rows.sharedChoice

local Colliders = MGE.AtmoPlay.Colliders
local Flight = MGE.AtmoPlay.Flight

---Turns one Collision toggle (1 player, 2 dynamic, 3 atmo) on or off on the selected atmo objects: one
---prop_collide line (none when all are on; the older prop_hits / prop_real lines go), one undo step
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

---Whether an atmo object's thrust pushes (Flight.parseThrust: a zero force or step is none)
local function hasThrust(obj)
    return Flight.parseThrust(obj.props.thrust) ~= nil
end

---Whether an atmo object starts active (its prop_motion, else whether it has a thrust)
local function startsActive(obj)
    return Colliders.startsActive(obj.props, hasThrust(obj))
end

---Turns Motion's Active on or off on the selected atmo objects: one prop_motion line (none for the default), one
---undo step
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

---Collision and Motion rows, rebuilt with the selection; nothing on the Objects list (Model and Ids there)
---@param holder UIElement
---@param selected FileParserEnvObj[] the selected atmo objects (ModData.getEditSelection on the Atmo list)
local function buildAtmoRows(holder, selected)
    Rows.begin()
    if not Rows.atmoShown() then return end
    -- each toggle lit when every selected one has it on; a click sets it for all of them (on when it wasn't lit)
    local items = {}
    for which, label in ipairs({ "Player", "Dynamic", "Atmo" }) do
        local lit = sharedChoice(selected, function(obj) return (select(which, Colliders.collision(obj.props))) end)
            == true
        items[which] = { label = label, active = lit, onClick = function() setCollision(which, not lit) end }
    end
    Rows.createToggleButtonRow("Collision", holder, items,
        "Props (Static off) in Atmo Play. Player / Dynamic:\nbecomes real near players / real dynamic objects\n" ..
        "(real, it collides with everything real). Both off:\nnever real, needs no pool object. Atmo: flying\n" ..
        "drawn, it hits other props. Overlapping ones\nnever push each other apart.")
    -- Motion: Active lit when every selected one starts active
    local active = sharedChoice(selected, startsActive) == true
    Rows.createToggleButtonRow("Motion", holder, {
        { label = "Active", active = active, onClick = function() setActive(not active) end },
    }, "Props in Atmo Play. Active: moves from the first\nframe (falls, tumbles, flies its thrust) before\n" ..
        "anything comes near. Off: still until a player,\na dynamic object or a flying prop reaches it.\n" ..
        "Default: on with thrust. The player's Far props\n(Pause) still pauses it far from everyone.")
end

---@type EditorPanelModule
return {
    blocks = {
        { name = "atmoRows", build = buildAtmoRows, panel = "advanced", row = 4, rows = 2 },
    },
}
